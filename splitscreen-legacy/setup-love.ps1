<#
.SYNOPSIS
  Produce a standalone love.exe (plus DLLs) in .\love\ from the official
  Windows build.

.DESCRIPTION
  The published gen1recomp-<version>-windows.zip ships a FUSED executable:
  love.exe with the game's .love archive appended to it. A fused binary runs
  its embedded game and ignores a .love passed on the command line, so it
  cannot launch our patched package.

  This splits the appended archive back off, leaving the exact love.exe the
  game shipped with -- the right LOVE version by construction, rather than
  whatever love2d.org is serving today (the game targets 11.5).

  The split point is computed from the zip End Of Central Directory record
  rather than by scanning for a "PK" signature, which can occur by chance
  inside the executable:

      archiveStart = eocdPosition - centralDirectorySize - centralDirectoryOffset

.EXAMPLE
  .\setup-love.ps1 -Zip C:\downloads\gen1recomp-0.1.75-windows.zip
#>
[CmdletBinding()]
param(
  [string]$Zip = "",
  [string]$FusedExe = "",
  [string]$Destination = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($Destination -eq "") { $Destination = Join-Path $root "love" }

$work = $null
try {
  # ------------------------------------------------------- locate the build
  if ($FusedExe -eq "") {
    if ($Zip -eq "") {
      $found = Get-ChildItem -Path $root, (Split-Path -Parent $root) -Filter "*windows*.zip" -ErrorAction SilentlyContinue |
               Select-Object -First 1
      if ($null -eq $found) {
        throw "Pass -Zip <gen1recomp-*-windows.zip> or -FusedExe <gen1recomp.exe>."
      }
      $Zip = $found.FullName
    }
    if (-not (Test-Path $Zip)) { throw "Not found: $Zip" }

    $work = Join-Path $env:TEMP ("unfuse-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $work | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $work)

    $exe = Get-ChildItem -Path $work -Recurse -Filter "*.exe" | Select-Object -First 1
    if ($null -eq $exe) { throw "No .exe inside $Zip" }
    $FusedExe = $exe.FullName
  }
  if (-not (Test-Path $FusedExe)) { throw "Not found: $FusedExe" }

  Write-Host "fused exe : $FusedExe"
  $bytes = [System.IO.File]::ReadAllBytes($FusedExe)
  Write-Host ("            {0:N0} bytes" -f $bytes.Length)

  # ------------------------------------------------------------- find EOCD
  # Signature 'P','K',5,6. Scan backwards; the comment field is at most 64 KB.
  $eocd = -1
  $limit = [Math]::Max(0, $bytes.Length - 65558)
  for ($i = $bytes.Length - 22; $i -ge $limit; $i--) {
    if ($bytes[$i] -eq 0x50 -and $bytes[$i+1] -eq 0x4B -and
        $bytes[$i+2] -eq 0x05 -and $bytes[$i+3] -eq 0x06) { $eocd = $i; break }
  }
  if ($eocd -lt 0) {
    throw "No zip archive appended to $FusedExe - it may not be a fused build. Install LOVE 11.5 from https://love2d.org instead."
  }

  $cdSize   = [System.BitConverter]::ToUInt32($bytes, $eocd + 12)
  $cdOffset = [System.BitConverter]::ToUInt32($bytes, $eocd + 16)
  $start    = $eocd - $cdSize - $cdOffset

  if ($start -le 0 -or $start -ge $bytes.Length) {
    throw "Computed archive start ($start) is out of range - refusing to guess."
  }
  if (-not ($bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A)) {
    throw "Source does not start with an MZ header - not a Windows executable."
  }

  Write-Host ("            love.exe = first {0:N0} bytes, game archive = {1:N0} bytes" -f $start, ($bytes.Length - $start))

  # -------------------------------------------------------------- write out
  New-Item -ItemType Directory -Path $Destination -Force | Out-Null

  $loveExe = New-Object byte[] $start
  [System.Array]::Copy($bytes, 0, $loveExe, 0, $start)
  $outExe = Join-Path $Destination "love.exe"
  [System.IO.File]::WriteAllBytes($outExe, $loveExe)
  Write-Host "  + love.exe"

  # DLLs travel with it.
  $dllSource = Split-Path -Parent $FusedExe
  Get-ChildItem -Path $dllSource -Filter "*.dll" | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $Destination $_.Name) -Force
    Write-Host ("  + " + $_.Name)
  }
  $lic = Join-Path $dllSource "license.txt"
  if (Test-Path $lic) { Copy-Item $lic (Join-Path $Destination "license.txt") -Force }

  Write-Host ""
  Write-Host "LOVE ready: $outExe" -ForegroundColor Green
  Write-Host "Next: .\play.ps1 -Players 2"
} finally {
  if ($null -ne $work -and (Test-Path $work)) {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
  }
}
