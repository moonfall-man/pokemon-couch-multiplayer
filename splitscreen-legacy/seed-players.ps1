<#
.SYNOPSIS
  Copy player 1's ROM-derived cache to the other players.

.DESCRIPTION
  Each player runs under its own LOVE identity (gen1recomp-pN) so their saves,
  settings and mod state can never collide. The cost of that isolation is that
  the ROM import is per-identity: without this, players 2-4 would each be asked
  for the ROM on first boot and each would build their own copy of the cache.

  This copies only ROM-DERIVED and mod data:
      <version>/data/generated
      <version>/assets/generated
      <version>/rom-cache.complete
      mods/

  It deliberately never copies options.lua or any save file, so nobody
  inherits player 1's playthrough or settings.

.EXAMPLE
  .\seed-players.ps1 -Players 2
#>
[CmdletBinding()]
param(
  [ValidateRange(2, 4)]
  [int]$Players = 2,
  [switch]$Force
)

$ErrorActionPreference = "Stop"

$loveRoot = Join-Path $env:APPDATA "LOVE"
$source   = Join-Path $loveRoot "gen1recomp-p1"

if (-not (Test-Path $source)) {
  throw @"
Player 1's data not found at:
  $source

Run .\play.ps1 -Players 1 first, import your ROM, then quit and re-run this.
"@
}

Write-Host "source: $source"
Write-Host ""

# Allowlist, not a denylist: anything not named here is simply not copied, so
# a file this script has never heard of can't leak one player's save into
# another's folder.
$copyDirs  = @("data\generated", "assets\generated")
$versions  = @("red", "blue", "yellow")

for ($i = 2; $i -le $Players; $i++) {
  $dest = Join-Path $loveRoot "gen1recomp-p$i"
  Write-Host "player $i -> $dest"

  $copied = 0

  foreach ($v in $versions) {
    $vSrc = Join-Path $source $v
    if (-not (Test-Path $vSrc)) { continue }

    foreach ($d in $copyDirs) {
      $from = Join-Path $vSrc $d
      if (-not (Test-Path $from)) { continue }
      $to = Join-Path (Join-Path $dest $v) $d
      if ((Test-Path $to) -and -not $Force) {
        Write-Host "    = $v\$d (exists, use -Force to overwrite)"
        continue
      }
      New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force | Out-Null
      Copy-Item -Path $from -Destination $to -Recurse -Force
      Write-Host "    + $v\$d"
      $copied++
    }

    $marker = Join-Path $vSrc "rom-cache.complete"
    if (Test-Path $marker) {
      $to = Join-Path (Join-Path $dest $v) "rom-cache.complete"
      New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force | Out-Null
      Copy-Item -Path $marker -Destination $to -Force
      Write-Host "    + $v\rom-cache.complete"
      $copied++
    }
  }

  $modsSrc = Join-Path $source "mods"
  if (Test-Path $modsSrc) {
    $to = Join-Path $dest "mods"
    if ((Test-Path $to) -and -not $Force) {
      Write-Host "    = mods (exists, use -Force to overwrite)"
    } else {
      New-Item -ItemType Directory -Path $dest -Force | Out-Null
      Copy-Item -Path $modsSrc -Destination $to -Recurse -Force
      Write-Host "    + mods"
      $copied++
    }
  }

  if ($copied -eq 0) {
    Write-Warning "  nothing copied for player $i - did player 1's ROM import finish?"
  }
}

Write-Host ""
Write-Host "Done. Now: .\play.ps1 -Players $Players" -ForegroundColor Green
