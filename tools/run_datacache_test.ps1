[CmdletBinding()]
param(
    [string]$ModelSimBin = "C:\intelFPGA_lite\17.0\modelsim_ase\win32aloem"
)

# Focused test for the data cache's 32-byte dirty-line write-back.
#
# cpu_datacache is VHDL and pulls its memories from the `mem` library, so this
# needs its own two-library setup rather than the plain vlog flow in
# run_tests.ps1.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$build = Join-Path $root 'sim/datacache_build'
$workLib = Join-Path $build 'work'
$memLib = Join-Path $build 'mem'

$vlib = Join-Path $ModelSimBin 'vlib.exe'
$vmap = Join-Path $ModelSimBin 'vmap.exe'
$vcom = Join-Path $ModelSimBin 'vcom.exe'
$vlog = Join-Path $ModelSimBin 'vlog.exe'
$vsim = Join-Path $ModelSimBin 'vsim.exe'

New-Item -ItemType Directory -Force -Path $build | Out-Null
Push-Location $build
try {
    if (-not (Test-Path (Join-Path $workLib '_info'))) { & $vlib $workLib }
    if (-not (Test-Path (Join-Path $memLib '_info')))  { & $vlib $memLib }
    & $vmap work $workLib
    & $vmap mem $memLib

    foreach ($f in @('RamMLAB.vhd', 'SyncFifoFallThroughMLAB.vhd', 'dpram.vhd')) {
        & $vcom -quiet -2008 -work mem (Join-Path $root "rtl/cpu/$f")
        if ($LASTEXITCODE -ne 0) { throw "vcom failed for $f" }
    }

    # Same order run_cpu_boot_test.ps1 uses; cpu_datacache depends on the
    # functions package and on the work-library dpram.
    foreach ($f in @('functions.vhd', 'export.vhd', 'dpram.vhd', 'cpu_datacache.vhd')) {
        & $vcom -quiet -2008 -work work (Join-Path $root "rtl/cpu/$f")
        if ($LASTEXITCODE -ne 0) { throw "vcom failed for $f" }
    }

    & $vlog -sv -quiet -work work (Join-Path $root 'sim/tb_ki_datacache_writeback.sv')
    if ($LASTEXITCODE -ne 0) { throw 'vlog failed for the testbench' }

    $out = & $vsim -c -quiet -t 1ps -L mem -do 'run -all; quit -f' work.tb_ki_datacache_writeback 2>&1
    $out | ForEach-Object { Write-Output $_ }
    if ($out -match '\*\* (Fatal|Error)') { throw 'datacache write-back test failed' }
} finally {
    Pop-Location
}
