$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$cpuPath = Join-Path $root 'rtl\cpu\cpu.vhd'
$wrapperPath = Join-Path $root 'rtl\ki_cpu_core.vhd'
$cpu = Get-Content -Raw -LiteralPath $cpuPath
$wrapper = Get-Content -Raw -LiteralPath $wrapperPath

$cpuChecks = [ordered]@{
    'opt-in CPU generic' = 'FRAMEBUFFER_UNCACHED\s*:\s*boolean\s*:=\s*false'
    'framebuffer 0 lower bound' = 'FB0_LOW.*x"00030000"'
    'framebuffer 0 upper bound' = 'FB0_HIGH.*x"00055800"'
    'framebuffer 1 lower bound' = 'FB1_LOW.*x"00058000"'
    'framebuffer 1 upper bound' = 'FB1_HIGH.*x"0007D800"'
    'effective cache enable' = "executeMemUseCacheEffective\s*<=\s*'0'\s+when"
}

foreach ($check in $cpuChecks.GetEnumerator()) {
    if ($cpu -notmatch $check.Value) {
        throw "Missing $($check.Key) in rtl/cpu/cpu.vhd"
    }
}

if ($wrapper -notmatch 'FRAMEBUFFER_UNCACHED\s*=>\s*true') {
    throw 'Killer Instinct CPU wrapper does not enable the framebuffer cache bypass'
}

$effectiveUses = ([regex]::Matches($cpu, 'executeMemUseCacheEffective')).Count
if ($effectiveUses -ne 7) {
    throw "Expected 7 framebuffer-aware cache decisions, found $effectiveUses"
}

Write-Host 'Framebuffer cache-bypass integration check passed.'
exit 0
