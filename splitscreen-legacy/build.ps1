<#
.SYNOPSIS
  Build a split-screen-capable gen1recomp .love from an existing build.

.DESCRIPTION
  Takes the stock game (from the Android APK you already have, or any
  gen1recomp .love), injects src/core/PadOwner.lua, and guards main.lua's
  joystick callbacks so each running copy answers to exactly one controller.

  The patch is anchored to specific lines of main.lua and every anchor is
  verified. If the upstream file changes shape, this fails loudly with the
  anchor that no longer matches rather than producing a silently broken build.

.EXAMPLE
  .\build.ps1
  Patches ..\gen1recomp-0.1.75-android.apk -> .\gen1recomp-splitscreen.love

.EXAMPLE
  .\build.ps1 -Source C:\downloads\gen1recomp-0.1.75.love
#>
[CmdletBinding()]
param(
  [string]$Source = "",
  [string]$Output = ""
)

$ErrorActionPreference = "Stop"
# Both assemblies: FileSystem carries ZipFile/ZipFileExtensions, but
# ZipArchiveMode lives in System.IO.Compression and is not pulled in on its
# own -- ::Open then fails with "Unable to find type [ZipArchiveMode]".
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($Output -eq "") { $Output = Join-Path $root "gen1recomp-splitscreen.love" }

# ---------------------------------------------------------------- source
if ($Source -eq "") {
  $apk = Get-ChildItem -Path (Split-Path -Parent $root) -Filter "*.apk" -ErrorAction SilentlyContinue |
         Sort-Object Name -Descending | Select-Object -First 1
  if ($null -eq $apk) {
    throw "No -Source given and no .apk found in $(Split-Path -Parent $root). Pass -Source <file.love|file.apk>."
  }
  $Source = $apk.FullName
}
if (-not (Test-Path $Source)) { throw "Source not found: $Source" }

$work = Join-Path $env:TEMP ("gen1recomp-splitscreen-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null

try {
  # An APK is a zip containing assets/game.love; a .love is the archive itself.
  $lovePath = $Source
  if ([System.IO.Path]::GetExtension($Source).ToLower() -eq ".apk") {
    Write-Host "Source APK : $Source"
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Source)
    try {
      $entry = $zip.Entries | Where-Object { $_.FullName -eq "assets/game.love" }
      if ($null -eq $entry) { throw "assets/game.love not found inside $Source" }
      $lovePath = Join-Path $work "game.love"
      [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $lovePath, $true)
    } finally {
      $zip.Dispose()
    }
  } else {
    Write-Host "Source love: $Source"
  }

  $tree = Join-Path $work "tree"
  [System.IO.Compression.ZipFile]::ExtractToDirectory($lovePath, $tree)

  $mainPath = Join-Path $tree "main.lua"
  if (-not (Test-Path $mainPath)) { throw "main.lua not found at archive root - is this a gen1recomp .love?" }

  # ------------------------------------------------------------ new module
  $padOwnerSrc = Join-Path $root "patch\PadOwner.lua"
  if (-not (Test-Path $padOwnerSrc)) { throw "Missing $padOwnerSrc" }
  Copy-Item $padOwnerSrc (Join-Path $tree "src\core\PadOwner.lua") -Force
  Write-Host "  + src/core/PadOwner.lua"

  # ------------------------------------------------------------ patch main
  $text = [System.IO.File]::ReadAllText($mainPath)
  $applied = 0

  function Add-After {
    param([string]$Anchor, [string]$Insert, [string]$Label)
    # Idempotency is checked against anchor+insert TOGETHER, not the insert
    # alone: the same guard line is used at seven different anchors, so a
    # bare "does the file contain this line" test would patch the first and
    # silently skip the other six.
    $combined = $Anchor + "`n" + $Insert
    if ($script:text.Contains($combined)) {
      Write-Host "  = $Label (already patched)"
      return
    }
    $count = ([regex]::Matches($script:text, [regex]::Escape($Anchor))).Count
    if ($count -ne 1) {
      throw "Anchor matched $count times (expected 1): $Label`n  anchor: $Anchor"
    }
    $script:text = $script:text.Replace($Anchor, $combined)
    $script:applied++
    Write-Host "  + $Label"
  }

  Add-After 'local NxDisplay = require("src.core.NxDisplay")' `
            "local PadOwner = require(`"src.core.PadOwner`")`nPadOwner.allowBackgroundEvents()" `
            "require PadOwner + enable background pad events"

  # Every pad/stick event entry point. Guarding here rather than inside
  # src/core/Input.lua is deliberate: Game:gamepadpressed cycles GAME SPEED
  # and routes menu input BEFORE it delegates to Input, so a filter placed in
  # Input would still let player 2's pad drive player 1's menus.
  $padGuard = "  if not PadOwner.owns(joystick) then return end"
  $padEntry = @(
    @{ sig = "function love.gamepadpressed(joystick, button)";   label = "love.gamepadpressed" },
    @{ sig = "function love.gamepadreleased(joystick, button)";  label = "love.gamepadreleased" },
    @{ sig = "function love.gamepadaxis(joystick, axis, value)"; label = "love.gamepadaxis" },
    @{ sig = "function love.joystickpressed(joystick, button)";  label = "love.joystickpressed" },
    @{ sig = "function love.joystickreleased(joystick, button)"; label = "love.joystickreleased" },
    @{ sig = "function love.joystickaxis(joystick, axis, value)";label = "love.joystickaxis" },
    @{ sig = "function love.joystickhat(joystick, hat, direction)"; label = "love.joystickhat" }
  )
  foreach ($e in $padEntry) { Add-After $e.sig $padGuard $e.label }

  # Hotplug changes SDL's enumeration order, so the binding must be retaken.
  Add-After "function love.joystickadded(joystick)"   "  PadOwner.refresh()" "love.joystickadded -> refresh"
  Add-After "function love.joystickremoved(joystick)" "  PadOwner.refresh()" "love.joystickremoved -> refresh"

  # Optional keyboard mute (POKEPORT_KEYBOARD=0).
  $kbGuard = "  if not PadOwner.keyboardEnabled then return end"
  Add-After "function love.keypressed(key, scancode, isrepeat)" $kbGuard "love.keypressed"
  Add-After "function love.keyreleased(key)"                    $kbGuard "love.keyreleased"

  [System.IO.File]::WriteAllText($mainPath, $text)

  # ------------------------------------------------------------ repack
  # Entries are written by hand with '/' separators. CreateFromDirectory has
  # historically emitted '\' on Windows, which PhysFS (and therefore LÖVE)
  # will not resolve -- the build would look fine and then boot to a black
  # screen with "main.lua not found".
  if (Test-Path $Output) { Remove-Item $Output -Force }
  $base = (Resolve-Path $tree).Path.TrimEnd('\') + '\'
  $zipOut = [System.IO.Compression.ZipFile]::Open($Output, [System.IO.Compression.ZipArchiveMode]::Create)
  try {
    Get-ChildItem -Path $tree -Recurse -File | ForEach-Object {
      $rel = $_.FullName.Substring($base.Length).Replace('\', '/')
      [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zipOut, $_.FullName, $rel) | Out-Null
    }
  } finally {
    $zipOut.Dispose()
  }

  $size = [math]::Round((Get-Item $Output).Length / 1MB, 2)
  Write-Host ""
  Write-Host "Built: $Output ($size MB, $applied edits)" -ForegroundColor Green
  Write-Host "Next:  .\play.ps1 -Players 2"
} finally {
  if (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
}
