[CmdletBinding()]
param(
    # Run the full ROM bitstream-reader sequence instead of the isolated
    # LDL/LDR pair.
    [switch]$BitReader,

    # Run the real ioctl ROM download path end to end.
    [switch]$RomDownload,

    # Verify the video scanout port returns correct pixels under CPU contention.
    [switch]$Scanout,

    # Execute the bitstream field decoder's uncached byte load on the real CPU.
    [switch]$Lbu,

    # Execute the game's uncached I/O poll loop on the real CPU.
    [switch]$IoPoll,

    # The same loop through the real bridge and ki_board_io.
    [switch]$IoPollBridge,

    [string]$ModelSimBin = 'C:\intelFPGA_lite\17.0\modelsim_ase\win32aloem'
)

# Runs sim/tb_ki_ldl_ldr.sv: the boot ROM's unaligned 64-bit load pair executed
# in isolation against the real ROM bytes. Reuses the cpu_build libraries the
# CPU boot test already populates.

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$cpuSource = Join-Path $project 'rtl/cpu'
$simSource = Join-Path $project 'sim'
$buildRoot = Join-Path $simSource 'cpu_build'
$workLibrary = Join-Path $buildRoot 'work'
$memLibrary = Join-Path $buildRoot 'mem'

foreach ($tool in @('vlib.exe', 'vmap.exe', 'vcom.exe', 'vlog.exe', 'vsim.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $ModelSimBin $tool))) {
        throw "ModelSim tool not found: $(Join-Path $ModelSimBin $tool)"
    }
}

Push-Location $project
try {
    & (Join-Path $PSScriptRoot 'prepare_bootrom.ps1') -Set 'kinst'

    New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $workLibrary '_info'))) {
        & (Join-Path $ModelSimBin 'vlib.exe') $workLibrary
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create ModelSim work library.' }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $memLibrary '_info'))) {
        & (Join-Path $ModelSimBin 'vlib.exe') $memLibrary
        if ($LASTEXITCODE -ne 0) { throw 'Failed to create ModelSim mem library.' }
    }

    & (Join-Path $ModelSimBin 'vmap.exe') work $workLibrary
    if ($LASTEXITCODE -ne 0) { throw 'Failed to map ModelSim work library.' }
    & (Join-Path $ModelSimBin 'vmap.exe') mem $memLibrary
    if ($LASTEXITCODE -ne 0) { throw 'Failed to map ModelSim mem library.' }

    foreach ($file in @('RamMLAB.vhd', 'SyncFifoFallThroughMLAB.vhd', 'dpram.vhd')) {
        & (Join-Path $ModelSimBin 'vcom.exe') -2008 -work mem (Join-Path $cpuSource $file)
        if ($LASTEXITCODE -ne 0) { throw "VHDL compile failed: $file (mem)" }
    }

    $workFiles = @(
        'functions.vhd', 'export.vhd', 'dpram.vhd', 'divider.vhd',
        'cpu_instrcache.vhd', 'cpu_datacache.vhd', 'cpu_TLB_instr.vhd',
        'cpu_TLB_data.vhd', 'cpu_mul.vhd', 'cpu_FPU_sqrt.vhd',
        'cpu_FPU.vhd', 'cpu_cop0.vhd', 'cpu.vhd'
    )
    foreach ($file in $workFiles) {
        & (Join-Path $ModelSimBin 'vcom.exe') -2008 -work work (Join-Path $cpuSource $file)
        if ($LASTEXITCODE -ne 0) { throw "VHDL compile failed: $file (work)" }
    }

    & (Join-Path $ModelSimBin 'vcom.exe') -2008 -work work (Join-Path $simSource 'ki_cpu_wrapper.vhd')
    if ($LASTEXITCODE -ne 0) { throw 'VHDL compile failed: ki_cpu_wrapper.vhd' }
    $bench = if ($Scanout) { 'tb_ki_video_scanout' }
             elseif ($IoPollBridge) { 'tb_ki_io_poll_bridge' }
             elseif ($IoPoll) { 'tb_ki_io_poll' }
             elseif ($Lbu) { 'tb_ki_rom_lbu' }
             elseif ($RomDownload) { 'tb_ki_rom_download' }
             elseif ($BitReader) { 'tb_ki_bitreader' }
             else { 'tb_ki_ldl_ldr' }
    if ($RomDownload -or $Scanout -or $IoPollBridge) {
        $extras = @('rtl\ki_board_pkg.sv', 'rtl\ki_fb_ram.sv',
                    'rtl\ki_memory_bridge.sv',
                    'rtl/ki_sdram_adapter.sv',
                    'rtl/ki_sdram_burst.sv',
                    'sim\mt48lc16m16_ki.sv')
        if ($IoPollBridge) { $extras += 'rtl\ki_board_io.sv' }
        foreach ($extra in $extras) {
            & (Join-Path $ModelSimBin 'vlog.exe') -sv -work work (Join-Path $project $extra)
            if ($LASTEXITCODE -ne 0) { throw "SystemVerilog compile failed: $extra" }
        }
    }
    & (Join-Path $ModelSimBin 'vlog.exe') -sv -work work (Join-Path $simSource "$bench.sv")
    if ($LASTEXITCODE -ne 0) { throw "SystemVerilog compile failed: $bench.sv" }

    & (Join-Path $ModelSimBin 'vsim.exe') @(
        '-c', '-t', '1ps',
        '-L', 'altera_mf', '-L', 'lpm', '-L', 'sgate', '-L', 'altera', '-L', 'cyclonev',
        "work.$bench", '-do', 'run -all; quit -f'
    )
    if ($LASTEXITCODE -ne 0) { throw "$bench simulation failed." }
} finally {
    Pop-Location
}
