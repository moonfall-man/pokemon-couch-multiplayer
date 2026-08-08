<#
.SYNOPSIS
  Launch N copies of the patched game side by side, one controller each.

.DESCRIPTION
  Each player gets:
    * their own save directory  (POKEPORT_IDENTITY=gen1recomp-pN)
    * exactly one controller    (POKEPORT_PAD=N, the Nth pad in SDL order)
    * their own tiled window

  Plug in every controller BEFORE running this. Pad N is the Nth pad as SDL
  enumerates them, which is normally the order they were connected.

.EXAMPLE
  .\play.ps1 -Players 2

.EXAMPLE
  .\play.ps1 -Players 4 -Game yellow
#>
[CmdletBinding()]
param(
  [ValidateRange(1, 4)]
  [int]$Players = 2,

  [ValidateSet("red", "blue", "yellow")]
  [string]$Game = "red",

  [string]$LoveExe = "",
  [string]$LovePackage = "",
  [switch]$NoTile,
  [switch]$KeyboardPlayerOne,

  # Requires the GHOST_LINK mod installed in each player's mods folder.
  # Player 1 hosts; everyone else joins them on localhost.
  [switch]$Ghosts,
  [int]$GhostPort = 7778
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

# ------------------------------------------------------------------ love.exe
if ($LoveExe -eq "") {
  $candidates = @(
    (Join-Path $root "love\love.exe"),
    (Join-Path $root "..\love\love.exe"),
    "C:\Program Files\LOVE\love.exe",
    "C:\Program Files (x86)\LOVE\love.exe"
  )
  foreach ($c in $candidates) {
    if (Test-Path $c) { $LoveExe = (Resolve-Path $c).Path; break }
  }
  if ($LoveExe -eq "") {
    $cmd = Get-Command love -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { $LoveExe = $cmd.Source }
  }
}
if ($LoveExe -eq "" -or -not (Test-Path $LoveExe)) {
  throw @"
Could not find love.exe.

Get it either way:
  * Download gen1recomp-<version>-windows.zip from the project's releases and
    unzip it to $root\love\  (it bundles love.exe and its DLLs), or
  * Install LOVE 11.5 from https://love2d.org

Then re-run, or pass -LoveExe <path to love.exe>.
"@
}

# --------------------------------------------------------------- .love file
if ($LovePackage -eq "") { $LovePackage = Join-Path $root "gen1recomp-splitscreen.love" }
if (-not (Test-Path $LovePackage)) {
  throw "Patched package not found: $LovePackage`nRun .\build.ps1 first."
}
$LovePackage = (Resolve-Path $LovePackage).Path

Write-Host "love    : $LoveExe"
Write-Host "package : $LovePackage"
Write-Host "players : $Players ($Game)"
Write-Host ""

# ------------------------------------------------------------------- launch
$saved = @{
  PAD         = $env:POKEPORT_PAD
  IDENTITY    = $env:POKEPORT_IDENTITY
  KEYBOARD    = $env:POKEPORT_KEYBOARD
  GHOST_HOST  = $env:POKEGHOST_HOST
  GHOST_JOIN  = $env:POKEGHOST_JOIN
  GHOST_PORT  = $env:POKEGHOST_PORT
  GHOST_SPRITE= $env:POKEGHOST_SPRITE
}

# Each player's ghost body, so you can tell each other apart on screen. These
# are ROM sprite ids that exist in every version (verified against the
# engine's own sprites.lua).
$ghostSprites = @("SPRITE_RED", "SPRITE_BLUE", "SPRITE_COOLTRAINER_M", "SPRITE_COOLTRAINER_F")

$procs = @()
try {
  for ($i = 1; $i -le $Players; $i++) {
    $env:POKEPORT_PAD      = "$i"
    $env:POKEPORT_IDENTITY = "gen1recomp-p$i"

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

    $p = Start-Process -FilePath $LoveExe `
                       -ArgumentList @($LovePackage, "--game=$Game") `
                       -PassThru
    $procs += $p
    Write-Host ("  player {0}: pid {1}, pad #{0}, saves in gen1recomp-p{0}{2}" -f $i, $p.Id, $ghostNote)
    Start-Sleep -Milliseconds 700
  }
} finally {
  $env:POKEPORT_PAD      = $saved.PAD
  $env:POKEPORT_IDENTITY = $saved.IDENTITY
  $env:POKEPORT_KEYBOARD = $saved.KEYBOARD
  $env:POKEGHOST_HOST    = $saved.GHOST_HOST
  $env:POKEGHOST_JOIN    = $saved.GHOST_JOIN
  $env:POKEGHOST_PORT    = $saved.GHOST_PORT
  $env:POKEGHOST_SPRITE  = $saved.GHOST_SPRITE
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
