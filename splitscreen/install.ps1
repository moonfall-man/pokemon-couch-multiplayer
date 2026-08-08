<#
.SYNOPSIS
  Make each split-screen player a clone of your normal game.

.DESCRIPTION
  ONE PROFILE IS THE SOURCE OF TRUTH, and it is the one the launcher's PLAY
  button uses: %APPDATA%\pokemon-love2d. Install whatever you like there --
  through the game's own MODS panel, which is the pleasant way to do it -- and
  this copies that exact set out to every player.

      pokemon-love2d\mods\   ---->   gen1recomp-p1\mods\
                                     gen1recomp-p2\mods\
                                     gen1recomp-p3\mods\
                                     gen1recomp-p4\mods\

  Players MATCH the source rather than accumulate. A mod sitting in a player
  profile that is not in the source is removed, and that is the point rather
  than a side effect: an evening went into a split screen that rendered flat
  because BATTLE_ART_VOXEL_FORK had reappeared alongside DRAMATIC_SHAPE. Both
  register the "voxel" render pipeline, so whichever loses the race fails with
  "render_pipelines already registered" -- and which one loses can differ per
  launch. Nothing in a manifest declares that two mods cannot coexist, so the
  only defence is that the players hold exactly the set you actually play.
  Pass -NoPrune to merge instead.

  Settings come across too (-KeepSettings opts out), because the same evening
  ended with the players rendering flat while PLAY rendered fine on identical
  mods -- the difference was in options.lua, not in mods\. Only the display
  and mod-settings blocks are copied. Save slots, the active save and the
  player's name are per player and are never touched.

  Also handled, so nobody does it by hand:

    * OUR THREE MODS come from this checkout, not from the source profile, so
      "I updated the mod" stays true after a pull.
    * ROM CACHE seeding, so only one person imports the cartridge.
    * MIGRATION from %APPDATA%\LOVE\<identity>, where a pre-fused-build setup
      kept its saves. Copied, never moved.

  Safe to re-run, and it backs up any options.lua it edits.

.EXAMPLE
  .\install.ps1
  Set up four players from pokemon-love2d.

.EXAMPLE
  .\install.ps1 -Players 2 -NoPrune
  Two players, and leave mods the source does not have in place.

.EXAMPLE
  .\install.ps1 -Identity pokemon-love2d
  Install only our three mods into an ordinary single-player copy.
#>
[CmdletBinding()]
param(
  [ValidateRange(1, 4)]
  [int]$Players = 4,

  # Where the player profiles are cloned FROM. The launcher's PLAY button uses
  # pokemon-love2d unless POKEPORT_IDENTITY overrides it.
  [string]$Source = "pokemon-love2d",

  # Install only our three mods into one named identity and do nothing else.
  [string]$Identity = "",

  [switch]$NoPrune,
  [switch]$KeepSettings,
  [switch]$Force
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $root

# Ours, in load order. PAD_OWNER first because PAD_HOTKEYS asks it which
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

# Refuse to touch anything while the game is up: it rewrites options.lua when
# it exits, so an edit made now would be silently thrown away.
$running = @(Get-Process gen1recomp -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
  throw "gen1recomp is running ($($running.Count) window(s)). Close it first -- it rewrites options.lua on exit, which would undo everything this does."
}

if ($Identity -ne "") {
  $identities = @($Identity)
} else {
  $identities = 1..$Players | ForEach-Object { "gen1recomp-p$_" }
}

Write-Host "our mods    : $repo"
Write-Host "source      : $Source" -NoNewline
if ($Identity -ne "") { Write-Host " (not used: -Identity given)" } else { Write-Host "" }
Write-Host "players     : $($identities -join ', ')"
Write-Host ""

# ------------------------------------------------------------------ migrate
foreach ($id in $identities) {
  $dest = Get-SaveDir $id
  $old  = Get-LegacySaveDir $id
  if ((Test-Path $old) -and -not (Test-Path $dest)) {
    Write-Host "$id : migrating from the old love.exe location" -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    # Copy, never move: if this migration is wrong the original playthrough is
    # still sitting exactly where it was.
    Get-ChildItem -Path $old -Force | ForEach-Object {
      Copy-Item -Path $_.FullName -Destination $dest -Recurse -Force
    }
    Write-Host "    copied (the old folder is left untouched)"
  }
}

# ------------------------------------------------------------------ our mods
function Install-Mod([string]$from, [string]$toDir, [string]$name) {
  $to = Join-Path $toDir $name
  if (Test-Path $to) { Remove-Item $to -Recurse -Force }
  Copy-Item -Path $from -Destination $to -Recurse -Force
  # Verify rather than assume. A mod folder without its manifest is not a mod:
  # the loader skips it in silence, and for PAD_OWNER that means every
  # controller drives every window with nothing anywhere saying why.
  if (-not (Test-Path (Join-Path $to "manifest.json"))) {
    throw "Copied $name to $to but manifest.json is not there. Is the game still running, or is something locking that folder?"
  }
}

foreach ($id in $identities) {
  $modsDir = Join-Path (Get-SaveDir $id) "mods"
  New-Item -ItemType Directory -Path $modsDir -Force | Out-Null
  Write-Host "$id"
  foreach ($m in $MODS) {
    Install-Mod (Join-Path $repo $m) $modsDir $m
    Write-Host "    + $m"
  }
}

if ($Identity -ne "") {
  Write-Host ""
  Write-Host "Done. PAD_OWNER stays inert unless POKEPORT_PAD is set, so single player is unchanged." -ForegroundColor Green
  return
}

# ------------------------------------------------------------------- mirror
$srcDir  = Get-SaveDir $Source
$srcMods = Join-Path $srcDir "mods"

Write-Host ""
if (-not (Test-Path $srcMods)) {
  Write-Warning "No source profile at $srcMods - install your mods through the game's MODS panel first, then re-run this."
} else {
  $want = @(Get-ChildItem -Path $srcMods -Directory |
            Where-Object { $MODS -notcontains $_.Name } |
            Where-Object { Test-Path (Join-Path $_.FullName "manifest.json") })

  Write-Host ("mirroring from {0}: {1}" -f $Source,
    ($(if ($want.Count) { ($want | ForEach-Object { $_.Name }) -join ", " } else { "(nothing else installed)" })))

  foreach ($id in $identities) {
    if ($id -eq $Source) { continue }
    $modsDir = Join-Path (Get-SaveDir $id) "mods"
    foreach ($o in $want) {
      Install-Mod $o.FullName $modsDir $o.Name
    }

    # Match, do not accumulate. See the header for why this is the default.
    $removed = @()
    if (-not $NoPrune) {
      $keep = @($MODS) + @($want | ForEach-Object { $_.Name })
      Get-ChildItem -Path $modsDir -Directory |
        Where-Object { $keep -notcontains $_.Name } |
        ForEach-Object {
          $removed += $_.Name
          Remove-Item $_.FullName -Recurse -Force
        }
    }

    $line = "    {0} -> {1} mirrored" -f $id, $want.Count
    if ($removed.Count -gt 0) { $line += ", removed " + ($removed -join ", ") }
    Write-Host $line
  }
}

# ----------------------------------------------------------------- settings
#
# Only two blocks, and deliberately not the whole file. options.lua also holds
# saveSlots, the active slot and lastVersion -- per-player state that a
# wholesale copy would clobber, pointing every player at one player's save
# registry.
function Get-LuaBlock([string]$text, [string]$name) {
  $m = [regex]::Match($text, "(?m)^(?<indent>\s*)$name = \{.*?^\k<indent>\},\r?\n", 'Singleline')
  if ($m.Success) { return $m.Value }
  return $null
}

function Set-LuaBlock([string]$text, [string]$name, [string]$block) {
  $existing = Get-LuaBlock $text $name
  if ($existing) { return $text.Replace($existing, $block) }
  # not present: insert before the closing brace of the returned table
  return [regex]::Replace($text, "(?m)^\}\s*$", ($block + "}"), 1)
}

if (-not $KeepSettings -and (Test-Path (Join-Path $srcDir "options.lua"))) {
  $srcText = [System.IO.File]::ReadAllText((Join-Path $srcDir "options.lua"))
  $blocks = @{}
  foreach ($b in @("pipelines", "modOptions")) {
    $blocks[$b] = Get-LuaBlock $srcText $b
  }

  Write-Host ""
  Write-Host "syncing display + mod settings from $Source"
  foreach ($id in $identities) {
    if ($id -eq $Source) { continue }
    $optPath = Join-Path (Get-SaveDir $id) "options.lua"

    # A brand-new profile has no options.lua until its first boot -- and if we
    # skip it here, that first boot writes DEFAULTS and the player starts with
    # the voxel pipeline off while everyone else has it on. So seed the file
    # from the source, minus the per-player bits.
    #
    # saveSlots and lastVersion are the dangerous ones: they are that
    # profile's own save registry, and handing every player one player's copy
    # would point them all at a slot list that is not theirs. A new profile has
    # no saves to lose, so dropping the block entirely is both safe and
    # correct -- the game rebuilds it.
    if (-not (Test-Path $optPath)) {
      $seed = $srcText
      $slots = Get-LuaBlock $seed "saveSlots"
      if ($slots) { $seed = $seed.Replace($slots, "") }
      $seed = [regex]::Replace($seed, '(?m)^\s*lastVersion = .*\r?\n', '')
      [System.IO.File]::WriteAllText($optPath, $seed, (New-Object System.Text.UTF8Encoding($false)))
      Write-Host "    $id : seeded options.lua from $Source (no save registry copied)"
      continue
    }
    Copy-Item $optPath "$optPath.bak-install" -Force
    $t = [System.IO.File]::ReadAllText($optPath)
    $changed = @()
    foreach ($b in @("pipelines", "modOptions")) {
      if ($blocks[$b]) {
        $before = $t
        $t = Set-LuaBlock $t $b $blocks[$b]
        if ($t -ne $before) { $changed += $b }
      }
    }
    [System.IO.File]::WriteAllText($optPath, $t, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("    {0} : {1}" -f $id,
      $(if ($changed.Count) { ($changed -join ", ") + " (backup: options.lua.bak-install)" } else { "already matching" }))
  }
}

# --------------------------------------------------------------- ROM cache
$versions = @("red", "blue", "yellow")
# An allowlist, not a denylist: anything not named here is simply not copied,
# so a file this script has never heard of cannot leak one player's save into
# another's folder.
$copyDirs = @("data\generated", "assets\generated")

$cacheFrom = $srcDir
$anyCache = $false
foreach ($v in $versions) {
  if (Test-Path (Join-Path $cacheFrom "$v\rom-cache.complete")) { $anyCache = $true }
}
if (-not $anyCache) {
  $cacheFrom = Get-SaveDir "gen1recomp-p1"
  foreach ($v in $versions) {
    if (Test-Path (Join-Path $cacheFrom "$v\rom-cache.complete")) { $anyCache = $true }
  }
}

Write-Host ""
if (-not $anyCache) {
  Write-Host "No ROM cache anywhere yet." -ForegroundColor Yellow
  Write-Host "Run the game once, import your ROM, quit, then re-run this."
} else {
  Write-Host "seeding the ROM cache from $(Split-Path -Leaf $cacheFrom)"
  foreach ($id in $identities) {
    $dest = Get-SaveDir $id
    if ($dest -eq $cacheFrom) { continue }
    $copied = 0
    foreach ($v in $versions) {
      $vSrc = Join-Path $cacheFrom $v
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
    Write-Host ("    {0} : {1}" -f $id,
      $(if ($copied -gt 0) { "$copied item(s) copied" } else { "already has a cache (-Force to replace)" }))
  }
}

Write-Host ""
Write-Host "Done. Next: .\play.ps1 -Players $Players" -ForegroundColor Green
Write-Host "Install mods through the game's MODS panel on the PLAY profile, then re-run this."
