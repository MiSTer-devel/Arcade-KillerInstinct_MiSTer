[CmdletBinding()]
param(
    [switch]$AnalysisOnly,
    # The guard below matches the REVISION name on the command line, which is
    # all quartus_fit exposes - it cannot see which directory the flow is
    # running in. Two checkouts of this project share the revision name
    # "KillerInstinct", so a flow in another tree looks identical to one here.
    # Pass this when you have confirmed the other flow is a different tree.
    [switch]$IgnoreOtherFlows
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$quartusBin = 'C:\intelFPGA_lite\17.0\quartus\bin64'

function Find-QuartusTool([string]$name) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    $candidate = Join-Path $quartusBin "$name.exe"
    if (Test-Path $candidate) {
        return $candidate
    }
    throw "$name was not found on PATH or in $quartusBin."
}

function Invoke-QuartusTool([string]$tool, [string[]]$arguments) {
    & $tool @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$(Split-Path -Leaf $tool) exited with code $LASTEXITCODE."
    }
}

$flowTools = @('quartus_map', 'quartus_fit', 'quartus_asm', 'quartus_sta',
               'quartus_cdb', 'quartus_sh')
$running = Get-Process -Name $flowTools -ErrorAction SilentlyContinue
if ($running -and $IgnoreOtherFlows) {
    Write-Host "Note: -IgnoreOtherFlows set; not checking for concurrent Quartus flows."
    $running = $null
}
if ($running) {
    $ours = @()
    foreach ($proc in $running) {
        $commandLine = $null
        try {
            $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)" -ErrorAction Stop).CommandLine
        } catch { }
        if ((-not $commandLine) -or ($commandLine -match '\bKillerInstinct\b')) {
            $ours += $proc
        }
    }
    if ($ours) {
        $ids = ($ours | ForEach-Object { "$($_.Name)($($_.Id))" }) -join ', '
        throw "Quartus is already building this project ($ids). Wait for it to finish, or stop it, before starting another build."
    }
    $others = ($running | ForEach-Object { "$($_.Name)($($_.Id))" }) -join ', '
    Write-Host "Note: Quartus is running for another project ($others). Continuing - it cannot touch this project's directories, but expect both builds to be slower."
}

$quartusMap = Find-QuartusTool 'quartus_map'

Push-Location $root
try {
    if ($AnalysisOnly) {
        Invoke-QuartusTool $quartusMap @(
            'KillerInstinct', '--read_settings_files=on', '--write_settings_files=off'
        )
    } else {
        Invoke-QuartusTool $quartusMap @(
            'KillerInstinct', '--read_settings_files=on', '--write_settings_files=off'
        )
        Invoke-QuartusTool (Find-QuartusTool 'quartus_fit') @(
            'KillerInstinct', '--read_settings_files=off', '--write_settings_files=off'
        )
        Invoke-QuartusTool (Find-QuartusTool 'quartus_asm') @(
            'KillerInstinct', '--read_settings_files=off', '--write_settings_files=off'
        )
        Invoke-QuartusTool (Find-QuartusTool 'quartus_sta') @('KillerInstinct')

        $staReport = Join-Path $root 'output_files/KillerInstinct.sta.rpt'
        $staSummary = Join-Path $root 'output_files/KillerInstinct.sta.summary'
        if (-not (Test-Path $staReport) -or -not (Test-Path $staSummary)) {
            throw 'Quartus did not produce the expected TimeQuest reports.'
        }
        $timingReport = Get-Content -Raw $staReport
        $timingSummary = Get-Content -Raw $staSummary
        if (($timingReport -match 'Timing requirements not met') -or
            ($timingSummary -match '(?m)^Slack\s*:\s*-')) {
            throw 'TimeQuest reports negative timing slack.'
        }
    }

    if (-not $AnalysisOnly) {
        $rbf = Join-Path $root 'output_files/KillerInstinct.rbf'
        if (-not (Test-Path $rbf)) {
            throw "Quartus completed but did not create $rbf."
        }
        Write-Host "Built $rbf"

        $conf = Get-Content -Raw (Join-Path $root 'KillerInstinct.sv')
        $version = 'unknown'
        if ($conf -match '"V,(?<v>[0-9.]+)"') {
            $version = $Matches['v'] -replace '\.', ''
        }
        $releases = Join-Path $root 'releases'
        New-Item -ItemType Directory -Force -Path $releases | Out-Null
        $archive = Join-Path $releases (
            'KillerInstinct_V{0}_{1}.rbf' -f $version, (Get-Date -Format 'yyyyMMdd'))
        Copy-Item -Path $rbf -Destination $archive -Force
        Write-Host "Archived $archive"
    }
} finally {
    Pop-Location
}
