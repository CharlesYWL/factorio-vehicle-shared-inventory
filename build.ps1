# Packages the mod into a Mod Portal compatible zip.
#
# The portal rejects archives containing executable files (exe, bat, ps1, sh, py),
# so this script excludes itself and any repo tooling from the archive.

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$info = Get-Content (Join-Path $repoRoot "info.json") -Raw | ConvertFrom-Json
$modName = $info.name
$version = $info.version
$stem = "${modName}_${version}"

$buildRoot = Join-Path $repoRoot "build"
$stageDir = Join-Path $buildRoot $stem
$zipPath = Join-Path $buildRoot "$stem.zip"

if (Test-Path $buildRoot) { Remove-Item $buildRoot -Recurse -Force }
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

# Only ship what the game and the portal actually need.
$include = @(
    "info.json",
    "control.lua",
    "settings.lua",
    "changelog.txt",
    "thumbnail.png",
    "LICENSE",
    "README.md"
)

foreach ($item in $include) {
    $source = Join-Path $repoRoot $item
    if (Test-Path $source) {
        Copy-Item $source -Destination $stageDir
    } elseif ($item -eq "thumbnail.png") {
        Write-Warning "thumbnail.png is missing: the portal listing will have no icon."
    }
}

foreach ($folder in @("scripts", "locale")) {
    $source = Join-Path $repoRoot $folder
    if (Test-Path $source) {
        Copy-Item $source -Destination $stageDir -Recurse
    }
}

# PowerShell's Compress-Archive writes Windows backslashes into the zip, which
# the Factorio mod portal rejects. ZipArchive with an explicit posix path is fine.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    Get-ChildItem -Path $stageDir -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($buildRoot.Length + 1).Replace('\', '/')
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip,
            $_.FullName,
            $relative,
            [System.IO.Compression.CompressionLevel]::Optimal
        )
    }
} finally {
    $zip.Dispose()
}

Remove-Item $stageDir -Recurse -Force

Write-Host "Built $zipPath"
Write-Host "Entries:"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$check = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $check.Entries | ForEach-Object { Write-Host "  $($_.FullName)" }
} finally {
    $check.Dispose()
}
