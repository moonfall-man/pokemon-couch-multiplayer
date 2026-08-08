<#
.SYNOPSIS
  Generate docs/index.json -- the feed the game's "Find mods" tab reads.

.DESCRIPTION
  An index is metadata only. It lists mods that live in their authors' repos;
  every install still goes through the same LauncherMods.installZip path an
  "Import mod .zip" does, so being listed buys a mod no trust it would not
  otherwise have.

  Fields are generated from each mod's own manifest.json and mod.card, so the
  feed cannot drift from what actually ships.

  downloadURL points at the predictable GitHub release asset path, which means
  this can be generated BEFORE the release exists -- publish the release with
  the matching tag and the links resolve.

.EXAMPLE
  .\tools\make-index.ps1 -Tag v0.1.0
#>
[CmdletBinding()]
param(
  [string]$Tag = "",
  [string]$Repo = "moonfall-man/pokemon-couch-multiplayer",
  [string]$Out = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if ($Out -eq "") { $Out = Join-Path $root "docs\index.json" }
New-Item -ItemType Directory -Path (Split-Path -Parent $Out) -Force | Out-Null

$MODS = @("PAD_OWNER", "PAD_HOTKEYS", "GHOST_LINK")

$entries = @()
foreach ($m in $MODS) {
  $manifestPath = Join-Path $root "$m\manifest.json"
  $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

  # mod.card is Lua, not JSON. Only the summary and tags are wanted here and
  # both are simple literals, so pull them out rather than embedding a Lua
  # interpreter in a packaging script.
  $cardPath = Join-Path $root "$m\mod.card"
  $summary = $manifest.description
  $tags = @()
  if (Test-Path $cardPath) {
    $card = Get-Content $cardPath -Raw
    $mSum = [regex]::Match($card, 'summary\s*=\s*"((?:[^"\\]|\\.)*)"')
    if ($mSum.Success) { $summary = $mSum.Groups[1].Value }
    $mTags = [regex]::Match($card, 'tags\s*=\s*\{([^}]*)\}')
    if ($mTags.Success) {
      $tags = [regex]::Matches($mTags.Groups[1].Value, '"([^"]+)"') |
              ForEach-Object { $_.Groups[1].Value }
    }
  }

  $tagName = if ($Tag -ne "") { $Tag } else { "v" + $manifest.version }
  $asset = "{0}-{1}.zip" -f $manifest.id, $manifest.version

  $entries += [ordered]@{
    id            = $manifest.id
    folder        = $manifest.id
    title         = $manifest.name
    author        = "moonfall-man"
    version       = $manifest.version
    summary       = $summary
    categories    = @($manifest.category)
    tags          = $tags
    license       = "MIT"
    repo          = "https://github.com/$Repo"
    github        = $Repo
    downloadURL   = "https://github.com/$Repo/releases/download/$tagName/$asset"
    api           = $manifest.api
    game_version  = $manifest.game_version
    profile       = $manifest.profile
    affects_link  = [bool]$manifest.affects_link
    permissions   = @($manifest.permissions)
    dependencies  = @($manifest.dependencies)
    conflicts     = @($manifest.conflicts)
    description_url = "https://github.com/$Repo/blob/master/$($manifest.id)/README.md"
  }
}

$doc = [ordered]@{
  schema_version = 1
  generated_at   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  categories     = @("CONTROLS", "MULTIPLAYER")
  mods           = $entries
}

$json = $doc | ConvertTo-Json -Depth 8

# Written to BOTH paths on purpose. ModIndex.resolveSource maps the short
# forms a player is most likely to paste -- "owner/repo", the GitHub repo URL,
# the Pages root -- to <base>/data/index.json, and only an explicit .../index.json
# to itself. Verified against the engine's own resolver:
#
#   moonfall-man/pokemon-couch-multiplayer      -> .../data/index.json
#   https://github.com/moonfall-man/...         -> .../data/index.json
#   https://moonfall-man.github.io/.../         -> .../data/index.json
#   https://moonfall-man.github.io/.../index.json -> itself
#
# Two copies of 6 KB is a cheaper fix than a README telling people which URL
# is the right one.
$targets = @($Out, (Join-Path (Split-Path -Parent $Out) "data\index.json"))
foreach ($t in $targets) {
  New-Item -ItemType Directory -Path (Split-Path -Parent $t) -Force | Out-Null
  [System.IO.File]::WriteAllText($t, $json, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "Wrote $t" -ForegroundColor Green
}

foreach ($e in $entries) { Write-Host ("  {0} {1} -> {2}" -f $e.id, $e.version, $e.downloadURL) }
Write-Host ""
Write-Host "Serve it over HTTPS (GitHub Pages on docs/ is the simplest), then in"
Write-Host "the game: MODS -> Find mods -> add the index URL."
