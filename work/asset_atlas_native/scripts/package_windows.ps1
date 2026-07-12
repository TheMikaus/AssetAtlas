param(
    [string]$Configuration = "Release",
    [string]$OutputRoot = "dist",
    [switch]$NoZip,
    [switch]$SkipPubGet
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

Push-Location $projectRoot
try {
    Write-Step "Project root: $projectRoot"

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

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $packageName = "asset_atlas_native-windows-x64-$configurationNormalized-$timestamp"
    $outputRootPath = Join-Path $projectRoot $OutputRoot
    $stageDir = Join-Path $outputRootPath $packageName

    Write-Step "Preparing output directory: $stageDir"
    if (Test-Path $stageDir) {
        Remove-Item -Path $stageDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

    Write-Step "Copying build artifacts"
    Copy-Item -Path (Join-Path $runnerDir "*") -Destination $stageDir -Recurse -Force

    $zipPath = "$stageDir.zip"
    if (-not $NoZip) {
        if (Test-Path $zipPath) {
            Remove-Item -Path $zipPath -Force
        }
        Write-Step "Creating zip package: $zipPath"
        Compress-Archive -Path (Join-Path $stageDir "*") -DestinationPath $zipPath -Force
    }

    Write-Step "Done"
    Write-Host ""
    Write-Host "Package folder: $stageDir"
    if (-not $NoZip) {
        Write-Host "Zip archive:   $zipPath"
    }
}
finally {
    Pop-Location
}
