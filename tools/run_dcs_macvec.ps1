[CmdletBinding()]
param(
    # Vector file from tools/extract_mac_vectors.py: real MAC operands and
    # results captured out of MAME's DCS during the loudest passage of play.
    [Parameter(Mandatory = $true)][string]$Vectors
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path -LiteralPath $Vectors)) { throw "vector file not found: $Vectors" }
$Vectors = (Resolve-Path -LiteralPath $Vectors).Path

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

$build = Join-Path $root 'sim/build/dcs_macvec'
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
        (Join-Path $root 'sim/tb_ki_dcs_macvec.sv')
    )
    if ($LASTEXITCODE -ne 0) { throw "ModelSim compilation failed." }

    Set-Content -LiteralPath (Join-Path $build 'run.do') -Encoding ascii -Value @(
        'onerror {quit -code 1}',
        'run -all',
        'quit -code [coverage attribute -name TESTSTATUS -concise]'
    )

    # Forward slashes: ModelSim treats a backslash in a plusarg as an escape.
    $v = $Vectors.Replace([char]92, [char]47)
    & $vsim -c -do run.do -l sim.log "+VEC=$v" work.tb_ki_dcs_macvec
    $code = $LASTEXITCODE
    Get-Content -LiteralPath (Join-Path $build 'sim.log') | ForEach-Object { Write-Output $_ }
    if ($code -ne 0) { throw "MAC vector replay failed (exit $code)." }
}
finally {
    Pop-Location
}
