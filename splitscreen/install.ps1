<#
.SYNOPSIS
  Install the couch-multiplayer mods into each player's game folder.

.DESCRIPTION
  Nothing is patched and nothing is rebuilt. This copies three mod folders
  into the save directories the official gen1recomp.exe already reads, exactly
  the way you would install the voxel mod by hand:

      %APPDATA%\gen1recomp-p1\mods\PAD_OWNER\
      %APPDATA%\gen1recomp-p1\mods\PAD_HOTKEYS\
      %APPDATA%\gen1recomp-p1\mods\GHOST_LINK\

  It also does the two setup chores nobody should have to do by hand:

    * MIGRATION. Earlier versions of this project ran the game through a
      standalone love.exe, which is not "fused" and therefore saved under
      %APPDATA%\LOVE\<identity>. The official build IS fused and saves under
      %APPDATA%\<identity> -- a different folder, so an existing playthrough
      would look like it had vanished. If the old folder exists and the new
      one does not, its contents are COPIED across. The original is never
      touched, so nothing is at risk if this guesses wrong.

    * ROM CACHE SEEDING. Each player is a separate identity, so each would
      otherwise be asked for the ROM on first boot and each would build its
      own copy of the extracted assets. Player 1's cache is copied to the
      others -- cache and mods only, never a save file and never options.lua,
      so nobody inherits anyone else's playthrough or settings.

  Safe to re-run. Existing data is left alone unless -Force says otherwise.

.EXAMPLE
  .\install.ps1 -Players 2

.EXAMPLE
  .\install.ps1 -Identity pokemon-love2d
  Install into an ordinary single-player copy of the game instead.
#>
[CmdletBinding()]
param(
  [ValidateRange(1, 4)]
  [int]$Players = 2,

  # Install into one named identity instead of gen1recomp-p1..pN.
  # "pokemon-love2d" is what the official build uses when nothing overrides it.
  [string]$Identity = "",

  # Copy every OTHER mod from a source profile out to each player.
  #
  # This is the "install it in the game, then run install" flow: the launcher's
  # own MODS panel installs into whichever profile it is running as -- normally
  # pokemon-love2d -- so a GUI install never reaches the per-player profiles on
  # its own. Rather than teach people to repeat it four times, mirror it.
  [switch]$Mirror,
  [string]$MirrorFrom = "",

  # Mods to leave out of the mirror.
  #
  # Two mods can be perfectly valid on their own and still refuse to coexist:
  # DRAMATIC_SHAPE and BATTLE_ART_VOXEL_FORK are the same mod, original and
  # fork, and both claim the "voxel" render pipeline -- so whichever loads
  # second fails with "render_pipelines already registered". Nothing in a
  # manifest declares that, and no amount of copying files can detect it, so
  # this is the escape hatch.
  [string[]]$Except = @(),

  [switch]$Force
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $root

# The mods, in load order. PAD_OWNER first because PAD_HOTKEYS asks it which
# controller this window owns.
$MODS = @("PAD_OWNER", "PAD_HOTKEYS", "GHOST_LINK")

foreach ($m in $MODS) {
  if (-not (Test-Path (Join-Path $repo $m))) {
    throw "Missing $repo\$m - run this from inside a full checkout."
  }
}

# The official build is fused (the game archive is appended to the executable),
# and LOVE drops the "LOVE\" segment for fused games. Verified against the real
# gen1recomp.exe rather than taken from the docs:
#   saveDirectory: C:/Users/<you>/AppData/Roaming/<identity>
function Get-SaveDir([string]$identity) { Join-Path $env:APPDATA $identity }
function Get-LegacySaveDir([string]$identity) {
  Join-Path (Join-Path $env:APPDATA "LOVE") $identity
}

if ($Identity -ne "") {
  $identities = @($Identity)
} else {
  $identities = 1..$Players | ForEach-Object { "gen1recomp-p$_" }
}

Write-Host "mods from : $repo"
Write-Host "installing: $($MODS -join ', ')"
Write-Host ""

# ------------------------------------------------------------------ migrate
foreach ($id in $identities) {
  $dest = Get-SaveDir $id
  $old  = Get-LegacySaveDir $id

  if ((Test-Path $old) -and -not (Test-Path $dest)) {
    Write-Host "$id : migrating from the old love.exe location" -ForegroundColor Yellow
    Write-Host "    $old"
    Write-Host " -> $dest"
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    # Copy, never move: if this migration is wrong for some reason, the
    # original playthrough is still sitting exactly where it was.
    Get-ChildItem -Path $old -Force | ForEach-Object {
      Copy-Item -Path $_.FullName -Destination $dest -Recurse -Force
    }
    Write-Host "    copied (the old folder is left in place, untouched)"
  } elseif ((Test-Path $old) -and (Test-Path $dest)) {
    Write-Host "$id : both locations exist - leaving the old one alone" -ForegroundColor DarkGray
    Write-Host "    old: $old"
  }
}

# --------------------------------------------------------------------- mods
foreach ($id in $identities) {
  $dest = Get-SaveDir $id
  $modsDir = Join-Path $dest "mods"
  New-Item -ItemType Directory -Path $modsDir -Force | Out-Null

  Write-Host ""
  Write-Host "$id -> $modsDir"

  foreach ($m in $MODS) {
    $to = Join-Path $modsDir $m
    if (Test-Path $to) { Remove-Item $to -Recurse -Force }
    Copy-Item -Path (Join-Path $repo $m) -Destination $to -Recurse -Force

    # Verify rather than assume. A mod folder without its manifest is not a
    # mod -- the loader skips it silently, and for PAD_OWNER that means every
    # controller drives every window with nothing anywhere saying why.
    $manifest = Join-Path $to "manifest.json"
    if (-not (Test-Path $manifest)) {
      throw "Copied $m to $to but manifest.json is not there. Is the game still running, or is something locking that folder?"
    }
    Write-Host "    + $m"
  }
}

# ------------------------------------------------------------------- mirror
#
# Our three always come from the repo above -- that is the copy the scripts
# test against, and letting a stale GUI-installed copy overwrite it would make
# "I updated the mod" quietly untrue. Everything ELSE comes from the source
# profile, which is where the launcher's MODS panel puts things.
#
# MERGE, never prune. A player profile legitimately has mods the source does
# not (the voxel fork lives in the per-player profiles here), and silently
# deleting somebody's mod because it was missing from another folder is not a
# trade worth making. Uninstalling stays a deliberate act.
if ($Mirror -or $MirrorFrom -ne "") {
  if ($MirrorFrom -eq "") { $MirrorFrom = "pokemon-love2d" }
  $srcMods = Join-Path (Get-SaveDir $MirrorFrom) "mods"

  Write-Host ""
  if (-not (Test-Path $srcMods)) {
    Write-Warning "Nothing to mirror: $srcMods does not exist."
  } else {
    $others = Get-ChildItem -Path $srcMods -Directory |
              Where-Object { $MODS -notcontains $_.Name } |
              Where-Object { $Except -notcontains $_.Name } |
              Where-Object { Test-Path (Join-Path $_.FullName "manifest.json") }

    if ($Except.Count -gt 0) {
      Write-Host ("Mirror: skipping {0}" -f ($Except -join ", ")) -ForegroundColor DarkGray
    }

    if ($others.Count -eq 0) {
      Write-Host "Mirror: $MirrorFrom has no other mods to copy."
    } else {
      Write-Host ("Mirroring from {0}: {1}" -f $MirrorFrom,
        (($others | ForEach-Object { $_.Name }) -join ", "))
      foreach ($id in $identities) {
        if ($id -eq $MirrorFrom) { continue }
        $destMods = Join-Path (Get-SaveDir $id) "mods"
        New-Item -ItemType Directory -Path $destMods -Force | Out-Null
        foreach ($o in $others) {
          $to = Join-Path $destMods $o.Name
          if (Test-Path $to) { Remove-Item $to -Recurse -Force }
          Copy-Item -Path $o.FullName -Destination $to -Recurse -Force
          if (-not (Test-Path (Join-Path $to "manifest.json"))) {
            throw "Copied $($o.Name) to $to but manifest.json is not there."
          }
        }
        Write-Host ("    {0} -> {1} mod(s)" -f $id, $others.Count)
      }
    }
  }
}

# --------------------------------------------------------------- ROM cache
#
# Only when there is more than one player, and only from player 1.
if ($Identity -eq "" -and $Players -ge 2) {
  $source = Get-SaveDir "gen1recomp-p1"
  $versions = @("red", "blue", "yellow")
  # An allowlist, not a denylist: anything not named here is simply not
  # copied, so a file this script has never heard of cannot leak one player's
  # save into another's folder.
  $copyDirs = @("data\generated", "assets\generated")

  $anyCache = $false
  foreach ($v in $versions) {
    if (Test-Path (Join-Path $source "$v\rom-cache.complete")) { $anyCache = $true }
  }

  Write-Host ""
  if (-not $anyCache) {
    Write-Host "No ROM cache in gen1recomp-p1 yet." -ForegroundColor Yellow
    Write-Host "Run  .\play.ps1 -Players 1  , import your ROM, quit, then re-run this."
  } else {
    Write-Host "Seeding the ROM cache from player 1..."
    for ($i = 2; $i -le $Players; $i++) {
      $dest = Get-SaveDir "gen1recomp-p$i"
      $copied = 0

      foreach ($v in $versions) {
        $vSrc = Join-Path $source $v
        if (-not (Test-Path $vSrc)) { continue }

        foreach ($d in $copyDirs) {
          $from = Join-Path $vSrc $d
          if (-not (Test-Path $from)) { continue }
          $to = Join-Path (Join-Path $dest $v) $d
          if ((Test-Path $to) -and -not $Force) { continue }
          New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force | Out-Null
          Copy-Item -Path $from -Destination $to -Recurse -Force
          $copied++
        }

        $marker = Join-Path $vSrc "rom-cache.complete"
        $to = Join-Path (Join-Path $dest $v) "rom-cache.complete"
        if ((Test-Path $marker) -and (-not (Test-Path $to) -or $Force)) {
          New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force | Out-Null
          Copy-Item -Path $marker -Destination $to -Force
          $copied++
        }
      }

      if ($copied -gt 0) {
        Write-Host "    player $i : $copied item(s) copied"
      } else {
        Write-Host "    player $i : already has a cache (use -Force to replace)"
      }
    }
  }
}

# ------------------------------------------------------------- discoverable
#
# A mod installed through the game's own MODS panel lands in whichever profile
# the launcher was running as, and nothing about that says "your other players
# did not get this". Say it here, where somebody is already looking.
if (-not $Mirror -and $MirrorFrom -eq "" -and $Identity -eq "") {
  $launcherMods = Join-Path (Get-SaveDir "pokemon-love2d") "mods"
  if (Test-Path $launcherMods) {
    $p1Mods = Join-Path (Get-SaveDir "gen1recomp-p1") "mods"
    $have = @()
    if (Test-Path $p1Mods) {
      $have = (Get-ChildItem $p1Mods -Directory | ForEach-Object { $_.Name })
    }
    $extra = Get-ChildItem $launcherMods -Directory |
             Where-Object { $MODS -notcontains $_.Name -and $have -notcontains $_.Name } |
             ForEach-Object { $_.Name }
    if ($extra.Count -gt 0) {
      Write-Host ""
      Write-Host ("Note: pokemon-love2d has {0} mod(s) your players do not: {1}" `
        -f $extra.Count, ($extra -join ", ")) -ForegroundColor Yellow
      Write-Host "      Copy them across with:  .\install.ps1 -Players $Players -Mirror"
    }
  }
}

Write-Host ""
if ($Identity -ne "") {
  Write-Host "Done. Launch the game as you normally would." -ForegroundColor Green
  Write-Host "PAD_OWNER stays inert unless POKEPORT_PAD is set, so single player is unchanged."
} else {
  Write-Host "Done. Next: .\play.ps1 -Players $Players" -ForegroundColor Green
}
