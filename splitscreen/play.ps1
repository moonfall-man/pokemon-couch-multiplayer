<#
.SYNOPSIS
  Launch N copies of the official game side by side, one controller each.

.DESCRIPTION
  Runs gen1recomp.exe straight from the release. Nothing is patched, unpacked
  or rebuilt -- the split-screen behaviour comes from the PAD_OWNER mod, which
  .\install.ps1 drops into each player's mods folder.

  Each player gets:
    * their own save directory  (POKEPORT_IDENTITY=gen1recomp-pN)
    * exactly one controller    (POKEPORT_PAD=N, the Nth pad in SDL order)
    * their own tiled window

  Plug in every controller BEFORE running this. Pad N is the Nth pad as SDL
  enumerates them, which is normally the order they were connected.

.EXAMPLE
  .\play.ps1 -Players 2

.EXAMPLE
  .\play.ps1 -Players 2 -Ghosts

.EXAMPLE
  .\play.ps1 -Players 4 -Game yellow
#>
[CmdletBinding()]
param(
  [ValidateRange(1, 4)]
  [int]$Players = 2,

  [ValidateSet("red", "blue", "yellow")]
  [string]$Game = "red",

  [string]$GameExe = "",
  [switch]$NoTile,
  [switch]$KeyboardPlayerOne,

  # Ghost presence: see each other walking around your own world.
  # Player 1 hosts; everyone else joins them on localhost.
  [switch]$Ghosts,
  [int]$GhostPort = 7778
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

# ------------------------------------------------------------ gen1recomp.exe
if ($GameExe -eq "") {
  $candidates = @(
    (Join-Path $root "gen1recomp\gen1recomp.exe"),
    (Join-Path $root "gen1recomp.exe"),
    (Join-Path (Split-Path -Parent $root) "gen1recomp\gen1recomp.exe"),
    (Join-Path (Split-Path -Parent $root) "gen1recomp-win64\gen1recomp.exe"),
    (Join-Path $env:LOCALAPPDATA "Programs\gen1recomp\gen1recomp.exe")
  )
  foreach ($c in $candidates) {
    if (Test-Path $c) { $GameExe = (Resolve-Path $c).Path; break }
  }
}
if ($GameExe -eq "" -or -not (Test-Path $GameExe)) {
  throw @"
Could not find gen1recomp.exe.

Download gen1recomp-<version>-windows.zip from the project's releases, unzip
it, and either put the folder at:

    $root\gen1recomp\

or pass its path directly:

    .\play.ps1 -Players $Players -GameExe "C:\path\to\gen1recomp.exe"
"@
}

Write-Host "game    : $GameExe"
Write-Host "players : $Players ($Game)"

# ------------------------------------------------------------------- checks
#
# Both of these are warnings rather than errors: the game still runs, it just
# will not do what you asked. Saying so up front beats debugging a controller
# that seems to drive both windows.
function Get-MissingMods([int]$n) {
  $missing = @()
  for ($i = 1; $i -le $n; $i++) {
    $dir = Join-Path $env:APPDATA "gen1recomp-p$i"
    foreach ($m in @("PAD_OWNER", "PAD_HOTKEYS", "GHOST_LINK")) {
      if (-not (Test-Path (Join-Path $dir "mods\$m\manifest.json"))) {
        $missing += "p${i}:$m"
      }
    }
  }
  return $missing
}

# INSTALL THE MODS IF THEY ARE NOT THERE, rather than telling you to.
#
# A missing PAD_OWNER is silent in the worst possible way: the game launches,
# both windows work, and every pad drives every window -- which reads as "the
# controller filter is broken" rather than "the controller filter is absent".
# It cost an evening once. Warning about it was not enough; a launcher that
# can see the problem should fix the problem.
$missingMods = Get-MissingMods $Players
if ($missingMods.Count -gt 0) {
  Write-Host ("Mods missing ({0}) - installing them now..." -f ($missingMods -join ", ")) -ForegroundColor Yellow
  & (Join-Path $root "install.ps1") -Players $Players | Out-Null

  $missingMods = Get-MissingMods $Players
  if ($missingMods.Count -gt 0) {
    throw @"
Could not install: $($missingMods -join ', ')

Without PAD_OWNER every controller drives every window, so this stops rather
than launching a session that cannot work. Try running it directly to see why:

    .\install.ps1 -Players $Players
"@
  }
  Write-Host "Mods installed." -ForegroundColor Green
}

$missingCache = @()
for ($i = 1; $i -le $Players; $i++) {
  $dir = Join-Path $env:APPDATA "gen1recomp-p$i"
  if (-not (Test-Path (Join-Path $dir "$Game\rom-cache.complete"))) { $missingCache += $i }
}
if ($missingCache.Count -gt 0) {
  Write-Warning ("No $Game ROM cache for player(s) {0} - they will open the launcher and ask for a ROM instead of booting straight in." -f ($missingCache -join ", "))
}
Write-Host ""

# ------------------------------------------------------------------- launch
$saved = @{
  PAD          = $env:POKEPORT_PAD
  IDENTITY     = $env:POKEPORT_IDENTITY
  KEYBOARD     = $env:POKEPORT_KEYBOARD
  GAME         = $env:POKEPORT_GAME
  GHOST_HOST   = $env:POKEGHOST_HOST
  GHOST_JOIN   = $env:POKEGHOST_JOIN
  GHOST_PORT   = $env:POKEGHOST_PORT
  GHOST_SPRITE = $env:POKEGHOST_SPRITE
  SDL_BG       = $env:SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS
}

# SDL drops joystick events for an UNFOCUSED window unless this is set, which
# in split screen means only whoever clicked last can move.
#
# Set here, in the ENVIRONMENT, rather than from the mod. SDL reads its hints
# from the environment during SDL_Init, so this is in force before the
# joystick subsystem exists. A mod cannot get close to that: by the time any
# Lua runs -- main.lua's own chunk included, which is where this used to live
# -- the joystick module is loaded, both pads are enumerated and the window is
# already open. Measured, not assumed:
#
#     at main.lua chunk level:  joysticks enumerated 2, window open true,
#                               hint (unset)
#     with this variable set:   hint 1
#
# PAD_OWNER still sets it over the FFI as a fallback for anyone launching the
# game by hand, but this is the route that is actually early enough.
$env:SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS = "1"

# Each player's ghost body, so you can tell each other apart on screen. These
# are ROM sprite ids that exist in every version (verified against the
# engine's own sprites.lua).
$ghostSprites = @("SPRITE_RED", "SPRITE_BLUE", "SPRITE_COOLTRAINER_M", "SPRITE_COOLTRAINER_F")

$procs = @()
try {
  for ($i = 1; $i -le $Players; $i++) {
    $env:POKEPORT_PAD      = "$i"
    $env:POKEPORT_IDENTITY = "gen1recomp-p$i"

    # Boot straight into the game rather than the launcher. This is not just
    # convenience: mods do not load until a game boots, so the launcher screen
    # is the one place PAD_OWNER cannot filter anything. Skipping it means
    # every screen a player sees is already one-pad-per-window.
    $env:POKEPORT_GAME = $Game

    # Keys only ever reach the focused window, so the keyboard is already
    # exclusive. -KeyboardPlayerOne makes that explicit: everyone but P1 is
    # pad-only, so a stray keypress can never reach a background player.
    if ($KeyboardPlayerOne -and $i -ne 1) {
      $env:POKEPORT_KEYBOARD = "0"
    } else {
      $env:POKEPORT_KEYBOARD = "1"
    }

    # Ghost presence: player 1 hosts, the rest join them on loopback. The
    # host has to be listening before anyone dials, which the 700ms stagger
    # below already guarantees.
    $ghostNote = ""
    if ($Ghosts) {
      $env:POKEGHOST_PORT = "$GhostPort"
      $env:POKEGHOST_SPRITE = $ghostSprites[($i - 1) % $ghostSprites.Count]
      if ($i -eq 1) {
        $env:POKEGHOST_HOST = "1"
        $env:POKEGHOST_JOIN = ""
        $ghostNote = ", hosting ghosts on :$GhostPort"
      } else {
        $env:POKEGHOST_HOST = ""
        $env:POKEGHOST_JOIN = "127.0.0.1:$GhostPort"
        $ghostNote = ", ghosts -> 127.0.0.1:$GhostPort"
      }
      $ghostNote += " as $($env:POKEGHOST_SPRITE)"
    }

    $p = Start-Process -FilePath $GameExe -PassThru
    $procs += $p
    Write-Host ("  player {0}: pid {1}, pad #{0}, saves in gen1recomp-p{0}{2}" -f $i, $p.Id, $ghostNote)
    Start-Sleep -Milliseconds 700
  }
} finally {
  $env:POKEPORT_PAD      = $saved.PAD
  $env:POKEPORT_IDENTITY = $saved.IDENTITY
  $env:POKEPORT_KEYBOARD = $saved.KEYBOARD
  $env:POKEPORT_GAME     = $saved.GAME
  $env:POKEGHOST_HOST    = $saved.GHOST_HOST
  $env:POKEGHOST_JOIN    = $saved.GHOST_JOIN
  $env:POKEGHOST_PORT    = $saved.GHOST_PORT
  $env:POKEGHOST_SPRITE  = $saved.GHOST_SPRITE
  $env:SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS = $saved.SDL_BG
}

if ($NoTile) { Write-Host "`nLaunched (untiled)."; return }

# --------------------------------------------------------------------- tile
Add-Type -AssemblyName System.Windows.Forms
# Guarded, and deliberately versioned in the name.
#
# Add-Type THROWS if the type already exists, and with ErrorActionPreference
# = Stop that aborts the whole script before a single window moves -- so
# running play.ps1 twice in one PowerShell session silently lost the tiling.
# Worse, a session holding an OLDER definition of this type would satisfy a
# plain existence check while missing members added since, so the version
# suffix changes whenever the shape does.
if (-not ('GhostTile2' -as [type])) {
  Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class GhostTile2 {
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")]
  public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")]
  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
'@
}

$area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea

if ($Players -le 1)     { $cols = 1; $rows = 1 }
elseif ($Players -eq 2) { $cols = 2; $rows = 1 }
else                    { $cols = 2; $rows = 2 }

$w = [int]($area.Width / $cols)
$h = [int]($area.Height / $rows)

Write-Host ""
Write-Host "Tiling ${cols}x${rows} at ${w}x${h}..."

for ($i = 0; $i -lt $procs.Count; $i++) {
  $p = $procs[$i]

  # The window does not exist the instant the process does; wait for it.
  $handle = [IntPtr]::Zero
  for ($t = 0; $t -lt 120; $t++) {
    if ($p.HasExited) { break }
    $p.Refresh()
    if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $handle = $p.MainWindowHandle; break }
    Start-Sleep -Milliseconds 250
  }
  if ($handle -eq [IntPtr]::Zero) {
    Write-Warning ("player {0} (pid {1}): no window found to tile" -f ($i + 1), $p.Id)
    continue
  }

  $x = $area.X + (($i % $cols) * $w)
  $y = $area.Y + ([math]::Floor($i / $cols) * $h)

  # Retry, and verify the move actually took.
  #
  # A window whose process is busy inside love.load -- the mod's first-boot
  # sprite generation is seconds of work -- has a handle but is not pumping
  # messages yet, and MoveWindow against it is silently ignored. One shot at
  # a fixed moment is a race; this waits for the window to actually accept
  # the position.
  $placed = $false
  for ($try = 0; $try -lt 12; $try++) {
    [GhostTile2]::ShowWindow($handle, 9) | Out-Null   # SW_RESTORE: un-maximize
    [GhostTile2]::MoveWindow($handle, $x, $y, $w, $h, $true) | Out-Null
    $r = New-Object GhostTile2+RECT
    if ([GhostTile2]::GetWindowRect($handle, [ref]$r)) {
      if ([math]::Abs($r.Left - $x) -le 8 -and [math]::Abs($r.Top - $y) -le 8) {
        $placed = $true
        break
      }
    }
    Start-Sleep -Milliseconds 500
  }
  if (-not $placed) {
    Write-Warning ("player {0}: window would not move (still busy loading?)" -f ($i + 1))
  }
}

Write-Host ""
Write-Host "Ready. Close each window to quit that player." -ForegroundColor Green
