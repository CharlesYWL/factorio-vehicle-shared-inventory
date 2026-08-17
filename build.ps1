# Packages the mod into a Mod Portal compatible zip.
# Delegates to pack.py so local builds and CI produce the same archive.

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repoRoot
python pack.py
