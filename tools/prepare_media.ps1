[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('kinst', 'kinst2')]
    [string]$Set,

    [string]$Chdman = 'chdman',

    [switch]$ValidateOnly,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$zipPath = Join-Path $workspace "games/$Set.zip"
$chdPath = Join-Path $workspace "games/$Set/$Set.chd"
$imgPath = Join-Path $workspace "games/$Set/$Set.img"
$expectedBytes = if ($Set -eq 'kinst') { 131076608L } else { 457673216L }

$expected = if ($Set -eq 'kinst') {
    @('ki-l15d.u98', 'u10-l1', 'u11-l1', 'u12-l1', 'u13-l1',
      'u33-l1', 'u34-l1', 'u35-l1', 'u36-l1')
} else {
    @('ki2-l14.u98', 'ki2_l1.u10', 'ki2_l1.u11', 'ki2_l1.u12',
      'ki2_l1.u13', 'ki2_l1.u33', 'ki2_l1.u34', 'ki2_l1.u35',
      'ki2_l1.u36')
}

if (-not (Test-Path -LiteralPath $zipPath)) {
    throw "Missing MAME ROM set: $zipPath"
}
if (-not (Test-Path -LiteralPath $chdPath)) {
    throw "Missing CHD: $chdPath"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $names = @($archive.Entries | ForEach-Object { $_.FullName })
    $missing = @($expected | Where-Object { $_ -notin $names })
    if ($missing.Count -ne 0) {
        throw "ROM set is missing required entries: $($missing -join ', ')"
    }
} finally {
    $archive.Dispose()
}

if ($ValidateOnly) {
    Write-Host "Validated $Set ROM ZIP and CHD paths."
    return
}

if ((Test-Path -LiteralPath $imgPath) -and -not $Force) {
    $actualBytes = (Get-Item -LiteralPath $imgPath).Length
    if ($actualBytes -ne $expectedBytes) {
        throw "Unexpected existing raw image size $actualBytes bytes; expected $expectedBytes. Use -Force to recreate it."
    }
    Write-Host "Raw image already exists and has the expected size: $imgPath ($actualBytes bytes)"
    return
}

$chdmanCommand = Get-Command $Chdman -ErrorAction SilentlyContinue
if (-not $chdmanCommand) {
    throw "chdman was not found. Pass -Chdman with the full path to chdman.exe."
}

if ((Test-Path -LiteralPath $imgPath) -and $Force) {
    Remove-Item -LiteralPath $imgPath
}

& $chdmanCommand.Source extracthd -i $chdPath -o $imgPath
if ($LASTEXITCODE -ne 0) {
    throw "chdman failed while extracting $chdPath"
}

$actualBytes = (Get-Item -LiteralPath $imgPath).Length
if ($actualBytes -ne $expectedBytes) {
    throw "Unexpected raw image size $actualBytes bytes; expected $expectedBytes."
}

Write-Host "Prepared $Set raw ATA image: $imgPath ($actualBytes bytes)"
