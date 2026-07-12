param(
    [string]$Configuration = "Release",
    [string]$OutputRoot = "dist",
    [string]$AppName = "Asset Atlas Native",
    [string]$Publisher = "Asset Atlas",
    [string]$ExecutableName = "asset_atlas_native.exe",
    [switch]$SkipPubGet,
    [switch]$KeepIss
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "[asset_atlas_native] $Message"
}

function Resolve-ProjectRoot {
    if ($PSScriptRoot) {
        return (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    }
    return (Get-Location).Path
}

function Assert-CommandAvailable {
    param([string]$CommandName)
    if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
        throw "Required command '$CommandName' is not available in PATH."
    }
}

function Resolve-InnoCompiler {
    $compiler = Get-Command iscc -ErrorAction SilentlyContinue
    if ($compiler) {
        return $compiler.Source
    }

    $knownPaths = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
    )

    foreach ($path in $knownPaths) {
        if (Test-Path $path) {
            return $path
        }
    }

    $uninstallKeys = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($key in $uninstallKeys) {
        $entries = Get-ItemProperty $key -ErrorAction SilentlyContinue
        foreach ($entry in $entries) {
            if ($entry.DisplayName -notlike "*Inno Setup*") {
                continue
            }
            $candidate = Join-Path ($entry.InstallLocation ?? "") "ISCC.exe"
            if ($entry.InstallLocation -and (Test-Path $candidate)) {
                return $candidate
            }
        }
    }

    return $null
}

function Get-AppVersion {
    param([string]$PubspecPath)

    if (-not (Test-Path $PubspecPath)) {
        return "0.0.0"
    }

    $versionLine = Select-String -Path $PubspecPath -Pattern '^version:\s*(.+)$' | Select-Object -First 1
    if (-not $versionLine) {
        return "0.0.0"
    }

    $raw = $versionLine.Matches[0].Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return "0.0.0"
    }

    return $raw.Split('+')[0]
}

Assert-CommandAvailable -CommandName "flutter"

$projectRoot = Resolve-ProjectRoot
$configurationNormalized = $Configuration.Trim().ToLowerInvariant()

switch ($configurationNormalized) {
    "release" { $buildArg = "--release"; $runnerConfigDir = "Release" }
    "debug"   { $buildArg = "--debug";   $runnerConfigDir = "Debug" }
    default {
        throw "Unsupported Configuration '$Configuration'. Use Release or Debug."
    }
}

$isccPath = Resolve-InnoCompiler
if (-not $isccPath) {
    throw "Inno Setup compiler (ISCC.exe) not found. Install Inno Setup 6 or add iscc to PATH."
}

Push-Location $projectRoot
try {
    Write-Step "Project root: $projectRoot"
    Write-Step "Using Inno Setup compiler: $isccPath"

    if (-not $SkipPubGet) {
        Write-Step "Running flutter pub get"
        flutter pub get
    }

    Write-Step "Building Windows app ($runnerConfigDir)"
    flutter build windows $buildArg

    $runnerDir = Join-Path $projectRoot "build\windows\x64\runner\$runnerConfigDir"
    if (-not (Test-Path $runnerDir)) {
        throw "Expected build output not found: $runnerDir"
    }

    $exePath = Join-Path $runnerDir $ExecutableName
    if (-not (Test-Path $exePath)) {
        throw "Expected executable not found: $exePath"
    }

    $appVersion = Get-AppVersion -PubspecPath (Join-Path $projectRoot "pubspec.yaml")
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

    $outputRootPath = Join-Path $projectRoot $OutputRoot
    $stageName = "asset_atlas_native-windows-x64-$configurationNormalized-$timestamp"
    $stageDir = Join-Path $outputRootPath $stageName

    Write-Step "Preparing staging directory: $stageDir"
    if (Test-Path $stageDir) {
        Remove-Item -Path $stageDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

    Write-Step "Copying build artifacts"
    Copy-Item -Path (Join-Path $runnerDir "*") -Destination $stageDir -Recurse -Force

    $installerOutDir = Join-Path $outputRootPath "installers"
    New-Item -ItemType Directory -Path $installerOutDir -Force | Out-Null

    $safeVersion = $appVersion.Replace(" ", "")
    $installerBaseName = "asset_atlas_native-setup-$safeVersion-$configurationNormalized-$timestamp"
    $issPath = Join-Path $outputRootPath "asset_atlas_native.installer.$timestamp.iss"
    $escapedStage = $stageDir.Replace("\", "\\")
    $escapedOut = $installerOutDir.Replace("\", "\\")

    $iss = @"
[Setup]
AppId={{1A6414B7-47D2-453F-A8B9-A9513A9CBFD6}
AppName=$AppName
AppVersion=$appVersion
AppPublisher=$Publisher
DefaultDirName={autopf}\$AppName
DisableProgramGroupPage=yes
OutputDir=$escapedOut
OutputBaseFilename=$installerBaseName
Compression=lzma
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop icon"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
Source: "$escapedStage\\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{autoprograms}\\$AppName"; Filename: "{app}\\$ExecutableName"
Name: "{autodesktop}\\$AppName"; Filename: "{app}\\$ExecutableName"; Tasks: desktopicon

[Run]
Filename: "{app}\\$ExecutableName"; Description: "Launch $AppName"; Flags: nowait postinstall skipifsilent
"@

    Write-Step "Writing installer config: $issPath"
    Set-Content -Path $issPath -Value $iss -Encoding UTF8

    Write-Step "Compiling installer"
    & "$isccPath" "$issPath"

    if (-not $KeepIss) {
        Remove-Item -Path $issPath -Force -ErrorAction SilentlyContinue
    }

    Write-Step "Done"
    Write-Host ""
    Write-Host "Staged app:        $stageDir"
    Write-Host "Installer output:  $installerOutDir"
    Write-Host "Installer basename: $installerBaseName"
}
finally {
    Pop-Location
}
