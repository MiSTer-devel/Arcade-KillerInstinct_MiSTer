[CmdletBinding()]
param(
    [string]$ModelSimBin = "C:\intelFPGA_lite\17.0\modelsim_ase\win32aloem"
)

# Regression for the CPU transaction FIFO's full-queue boundary behavior.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root 'sim/fifo_build'
$workLib = Join-Path $build 'work'

$vlib = Join-Path $ModelSimBin 'vlib.exe'
$vmap = Join-Path $ModelSimBin 'vmap.exe'
$vcom = Join-Path $ModelSimBin 'vcom.exe'
$vsim = Join-Path $ModelSimBin 'vsim.exe'

New-Item -ItemType Directory -Force -Path $build | Out-Null
Push-Location $build
try {
    if (-not (Test-Path (Join-Path $workLib '_info'))) { & $vlib $workLib }
    & $vmap work $workLib

    foreach ($f in @('RamMLAB.vhd', 'SyncFifoFallThroughMLAB.vhd')) {
        & $vcom -quiet -2008 -work work (Join-Path $root "rtl/cpu/$f")
        if ($LASTEXITCODE -ne 0) { throw "vcom failed for $f" }
    }

    & $vcom -quiet -2008 -work work (Join-Path $root 'sim/tb_sync_fifo.vhd')
    if ($LASTEXITCODE -ne 0) { throw 'vcom failed for the FIFO testbench' }

    $out = & $vsim -c -quiet -t 1ps -do 'run -all; quit -f' work.tb_sync_fifo 2>&1
    $out | ForEach-Object { Write-Output $_ }
    if ($LASTEXITCODE -ne 0 -or $out -match '\*\* (Fatal|Error)') {
        throw 'transaction FIFO test failed'
    }
} finally {
    Pop-Location
}
