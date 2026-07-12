param(
    [ValidateSet("patch", "minor", "major")]
    [string]$Part = "patch",
    [switch]$DryRun
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

$projectRoot = Resolve-ProjectRoot
$pubspecPath = Join-Path $projectRoot "pubspec.yaml"

if (-not (Test-Path $pubspecPath)) {
    throw "pubspec.yaml not found at: $pubspecPath"
}

$content = Get-Content -Path $pubspecPath -Raw
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
Set-Content -Path $pubspecPath -Value $updated -Encoding UTF8

Write-Step "Updated $pubspecPath"
