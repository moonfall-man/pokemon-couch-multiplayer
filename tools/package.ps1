<#
.SYNOPSIS
  Build the release .zip for each mod, ready for the in-game installer.

.DESCRIPTION
  The engine installs mods from a .zip through LauncherMods.installZip -- the
  same path whether it came from "Import mod .zip", the "Find mods" tab, or an
  auto-update. It locates the folder containing manifest.json, so the mod
  folder sits at the archive root:

      PAD_OWNER/manifest.json
      PAD_OWNER/main.lua
      PAD_OWNER/lib/PadOwner.lua

  Names follow ModUpdate.pickZipAsset's preference order, which looks for
  "<id>-<version>.zip" first. Matching it exactly means auto-update picks the
  right asset even if a release carries several.

.EXAMPLE
  .\tools\package.ps1
  Writes dist\PAD_OWNER-0.1.0.zip and friends.
#>
[CmdletBinding()]
param(
  [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if ($OutDir -eq "") { $OutDir = Join-Path $root "dist" }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$MODS = @("COUCH_MULTIPLAYER", "POKEMON_FOLLOWERS")

# Files that are ours to develop with but not to ship. tools/ is Python for
# regenerating data tables; nobody installing the mod runs it.
$SKIP_DIRS  = @("tools", "__pycache__")
$SKIP_EXT   = @(".pyc")

$built = @()

foreach ($m in $MODS) {
  $src = Join-Path $root $m
  if (-not (Test-Path (Join-Path $src "manifest.json"))) {
    throw "No manifest.json in $src"
  }
  $manifest = Get-Content (Join-Path $src "manifest.json") -Raw | ConvertFrom-Json
  $version = $manifest.version
  if (-not $version) { throw "$m has no version in its manifest" }

  $zipPath = Join-Path $OutDir ("{0}-{1}.zip" -f $manifest.id, $version)
  if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

  # Entries are written by hand with '/' separators and the mod folder as the
  # prefix. CreateFromDirectory has historically emitted '\' on Windows, which
  # PhysFS will not resolve -- the zip would look fine and then install as an
  # empty folder.
  $base = (Resolve-Path $src).Path.TrimEnd('\') + '\'
  $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
  $count = 0
  try {
    Get-ChildItem -Path $src -Recurse -File | ForEach-Object {
      $rel = $_.FullName.Substring($base.Length).Replace('\', '/')
      $top = $rel.Split('/')[0]
      if ($SKIP_DIRS -contains $top) { return }
      if ($SKIP_EXT -contains $_.Extension) { return }
      [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
        $zip, $_.FullName, "$($manifest.id)/$rel") | Out-Null
      $count++
    }
  } finally {
    $zip.Dispose()
  }

  # Verify rather than assume: open it back up and confirm the installer's
  # entry point is actually in there under the folder it expects.
  $check = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
  try {
    $wanted = "$($manifest.id)/manifest.json"
    $has = $check.Entries | Where-Object { $_.FullName -eq $wanted }
    if (-not $has) { throw "$zipPath is missing $wanted" }
    $backslash = $check.Entries | Where-Object { $_.FullName.Contains('\') }
    if ($backslash) { throw "$zipPath has backslash entries; PhysFS will not read it" }
  } finally {
    $check.Dispose()
  }

  $kb = [math]::Round((Get-Item $zipPath).Length / 1KB)
  Write-Host ("  + {0}  ({1} files, {2} KB)" -f (Split-Path -Leaf $zipPath), $count, $kb)
  $built += [pscustomobject]@{ id = $manifest.id; version = $version; zip = $zipPath }
}

Write-Host ""
Write-Host "Built $($built.Count) mod archive(s) in $OutDir" -ForegroundColor Green
Write-Host ""
Write-Host "Attach these to a GitHub release. The in-game 'Find mods' tab and"
Write-Host "auto-update both read release assets, and the names match what"
Write-Host "ModUpdate.pickZipAsset looks for first."
$built | ForEach-Object { Write-Host ("  {0} {1}" -f $_.id, $_.version) }
