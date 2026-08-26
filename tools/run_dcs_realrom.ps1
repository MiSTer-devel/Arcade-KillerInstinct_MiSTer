[CmdletBinding()]
param(
    # 4 MiB packed DCS image: the eight 512 KiB devices concatenated in the
    # order MAME's region offsets give (u10, u11, u12, u13, u33, u34, u35, u36).
    # Build it with tools/build_dcs_rom.py. Not committed - it is game data.
    [string]$Rom,
    # Simulated DCS milliseconds. KI1's boot chime sounds 2823 ms after reset,
    # which is hours of wall time; the default is a smoke test that only asks
    # whether the real program boots and executes.
    [int]$RunMs = 5,
    [switch]$AckResp,
    # Dump the first N retired PCs to ourtrace.txt for diffing against MAME.
    [int]$Trace = 0,
    # DCS FSM enable rate. 32 MHz (the RTL default) measures 8.95 MIPS against
    # the real board's 10.0; 35750000 matches it.
    [int]$EngineHz = 0,
    # Cycles the bench takes to answer a ROM beat. 3 is the optimistic default
    # and is nothing like DDR through the memory bridge.
    [int]$RomLatency = 0,
    # Sound command pair to trigger after boot. 0d/7d is the pair that precedes
    # the loudest moment in MAME's max-volume gameplay - peak 32768, the rail.
    [string]$CmdA = "",
    [string]$CmdB = "",
    [int]$CmdMs = 300,
    [string]$Tag = "",
    # File of 16-bit hex commands, one per line, replayed after CmdMs.
    [string]$CmdList = ""
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

if (-not $Rom) { throw "-Rom <packed 4 MiB DCS image> is required. See tools/build_dcs_rom.py." }
if (-not (Test-Path -LiteralPath $Rom)) { throw "ROM image not found: $Rom" }
$Rom = (Resolve-Path -LiteralPath $Rom).Path

function Find-Tool([string]$name) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($base in @('C:\intelFPGA_lite\17.0\modelsim_ase\win32aloem',
                        'C:\intelFPGA_lite\17.0\modelsim_ase\win64')) {
        $c = Join-Path $base "$name.exe"
        if (Test-Path $c) { return $c }
    }
    throw "$name was not found on PATH or in the ModelSim install."
}

$vlib = Find-Tool 'vlib'
$vlog = Find-Tool 'vlog'
$vsim = Find-Tool 'vsim'

$build = Join-Path $root ('sim/build/dcs_realrom' + $(if ($Tag) { "_$Tag" } else { "" }))
New-Item -ItemType Directory -Force -Path $build | Out-Null
Push-Location $build
try {
    if (-not (Test-Path work)) {
        & $vlib work
        if ($LASTEXITCODE -ne 0) { throw "ModelSim library creation failed." }
    }

    & $vlog -sv "+define+KI_DCS_SIMULATION" "+incdir+$(Join-Path $root 'rtl/dcs')" -work work @(
        (Join-Path $root 'rtl/dcs/adsp2105.sv'),
        (Join-Path $root 'rtl/ki_dcs_audio.sv'),
        (Join-Path $root 'sim/tb_ki_dcs_realrom.sv')
    )
    if ($LASTEXITCODE -ne 0) { throw "ModelSim compilation failed." }

    $doFile = Join-Path $build 'run.do'
    Set-Content -LiteralPath $doFile -Encoding ascii -Value @(
        'onerror {quit -code 1}',
        'run -all',
        'quit -code [coverage attribute -name TESTSTATUS -concise]'
    )

    # Forward slashes: ModelSim treats a backslash in a plusarg as an escape.
    $romArg = $Rom -replace '\\', '/'
    Write-Host "Booting the DCS from $romArg for $RunMs ms of simulated time..."
    $extra = @()
    if ($AckResp) { $extra += '+ACKRESP' }
    if ($Trace -gt 0) { $extra += "+TRACE=$Trace" }
    if ($EngineHz -gt 0) { $extra += "-gENGINE_HZ=$EngineHz" }
    if ($RomLatency -gt 0) { $extra += "-gROM_LATENCY=$RomLatency" }
    if ($CmdA) { $extra += "+CMDA=$CmdA" }
    if ($CmdB) { $extra += "+CMDB=$CmdB" }
    if ($CmdList) {
        # Forward slashes: ModelSim treats a backslash in a plusarg as an escape.
        $cl = $CmdList.Replace([char]92, [char]47)
        $extra += "+CMDLIST=$cl"
    }
    if ($CmdA -or $CmdB -or $CmdList) { $extra += "+CMDMS=$CmdMs" }
    & $vsim -c -do run.do -l sim.log "+ROM=$romArg" "+RUNMS=$RunMs" @extra work.tb_ki_dcs_realrom
    $code = $LASTEXITCODE
    Get-Content -LiteralPath (Join-Path $build 'sim.log') | ForEach-Object { Write-Output $_ }
    if ($code -ne 0) { throw "ModelSim did not report a clean run (exit $code)." }
}
finally {
    Pop-Location
}
