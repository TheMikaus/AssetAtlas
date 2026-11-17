param(
    [ValidateSet("patch", "minor", "major")]
    [string]$Part = "patch",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# Read and write UTF-8 explicitly, whichever PowerShell is running this.
#
# The defaults differ: PowerShell 7 reads and writes UTF-8, but Windows
# PowerShell 5.1 reads the ANSI code page and its `-Encoding UTF8` adds a BOM.
# Run under 5.1 this script read lib/main.dart as cp1252 and wrote it back as
# UTF-8, so every non-ASCII character in it was double-encoded -- the middle
# dot in the window title, ten times over -- and both files gained a BOM.
# Nothing notices until a widget test fails with "Found 0 widgets" and says
# nothing about encoding.
#
# UTF8Encoding($false) is UTF-8 without a BOM; Set-Content cannot express that
# in 5.1, so the writes go through .NET instead.
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Read-Utf8Text {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, $Utf8NoBom)
}

function Write-Utf8Text {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

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

$projectRoot = Resolve-ProjectRoot
$pubspecPath = Join-Path $projectRoot "pubspec.yaml"
$mainDartPath = Join-Path $projectRoot "lib\main.dart"

if (-not (Test-Path $pubspecPath)) {
    throw "pubspec.yaml not found at: $pubspecPath"
}
if (-not (Test-Path $mainDartPath)) {
    throw "lib/main.dart not found at: $mainDartPath"
}

$content = Read-Utf8Text -Path $pubspecPath
$pattern = '(?m)^version:\s*([0-9]+)\.([0-9]+)\.([0-9]+)\+([0-9]+)\s*$'
$match = [regex]::Match($content, $pattern)

if (-not $match.Success) {
    throw "Could not parse version from pubspec.yaml. Expected format like: version: 1.2.3+4"
}

$major = [int]$match.Groups[1].Value
$minor = [int]$match.Groups[2].Value
$patch = [int]$match.Groups[3].Value
$build = [int]$match.Groups[4].Value

switch ($Part) {
    "major" {
        $major += 1
        $minor = 0
        $patch = 0
    }
    "minor" {
        $minor += 1
        $patch = 0
    }
    "patch" {
        $patch += 1
    }
}

$build += 1

$oldVersion = "$($match.Groups[1].Value).$($match.Groups[2].Value).$($match.Groups[3].Value)+$($match.Groups[4].Value)"
$newVersion = "$major.$minor.$patch+$build"
$newLine = "version: $newVersion"

Write-Step "Current version: $oldVersion"
Write-Step "Next version:    $newVersion"

if ($DryRun) {
    Write-Step "Dry run enabled. No files changed."
    return
}

$updated = [regex]::Replace($content, $pattern, $newLine)
Write-Utf8Text -Path $pubspecPath -Text $updated

Write-Step "Updated $pubspecPath"

$mainContent = Read-Utf8Text -Path $mainDartPath
$appVersionPattern = "(?m)^const appVersion = '[0-9]+\.[0-9]+\.[0-9]+';\s*$"
if (-not [regex]::IsMatch($mainContent, $appVersionPattern)) {
    throw "Could not find appVersion constant in: $mainDartPath"
}
$visibleVersion = "$major.$minor.$patch"
$updatedMain = [regex]::Replace(
    $mainContent,
    $appVersionPattern,
    "const appVersion = '$visibleVersion';"
)
Write-Utf8Text -Path $mainDartPath -Text $updatedMain

Write-Step "Updated visible app version in $mainDartPath"
