[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$path = Join-Path $root 'rtl\dcs\adsp2105.sv'
$text = Get-Content -Raw $path
$match = [regex]::Match(
    $text,
    '(?s)altsyncram\s*#\(.*?\)\s*pm_ram\s*\(.*?\n\s*\);'
)

if (-not $match.Success) {
    throw "Could not find the consolidated DCS program RAM in $path"
}

$block = $match.Value
$required = @(
    '.intended_device_family("Cyclone V")',
    '.operation_mode("BIDIR_DUAL_PORT")',
    '.ram_block_type("M10K")',
    '.address_reg_b("CLOCK1")',
    '.byteena_reg_b("CLOCK1")',
    '.clock_enable_input_a("NORMAL")',
    '.clock_enable_input_b("NORMAL")',
    '.indata_reg_b("CLOCK1")',
    '.outdata_reg_a("UNREGISTERED")',
    '.outdata_reg_b("UNREGISTERED")',
    '.rdcontrol_reg_b("CLOCK1")',
    '.read_during_write_mode_mixed_ports("OLD_DATA")',
    '.read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ")',
    '.read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ")',
    '.wrcontrol_wraddress_reg_b("CLOCK1")',
    '.clock1(clk)',
    '.clocken0(cpu_ce)',
    '.clocken1(cpu_ce)',
    '.address_a(pm_we ? pm_wa : pmb_addr)',
    '.width_byteena_a(3)',
    '.byteena_a(pm_be)',
    '.wren_a(pm_we)',
    '.q_a(pmb_q)',
    '.address_b(fetch_addr)',
    ".wren_b(1'b0)",
    '.q_b(fetch_q)',
    ".rden_a(1'b1)",
    ".rden_b(1'b1)"
)
$forbidden = @(
    '.address_reg_a("CLOCK0")',
    '.indata_reg_a("CLOCK0")',
    '.address_reg_b("CLOCK0")',
    '.byteena_reg_b("CLOCK0")',
    '.indata_reg_b("CLOCK0")',
    '.rdcontrol_reg_b("CLOCK0")',
    '.wrcontrol_wraddress_reg_a("CLOCK0")',
    '.wrcontrol_wraddress_reg_b("CLOCK0")',
    '.clock_enable_input_a("BYPASS")',
    '.clock_enable_input_b("BYPASS")',
    '.width_byteena_a(1)',
    ".byteena_a(1'b1)",
    ".clocken0(1'b1)",
    ".clock1(1'b1)",
    ".clocken1(1'b1)",
    '.address_a(fetch_addr)',
    '.q_a(fetch_q)',
    '.q_b(pmb_q)',
    '.read_during_write_mode_port_a("OLD_DATA")',
    '.read_during_write_mode_port_b("OLD_DATA")',
    '.read_during_write_mode_port_a("DONT_CARE")',
    '.read_during_write_mode_port_b("DONT_CARE")',
    '.rden_a(!pm_we)'
)

foreach ($setting in $required) {
    if (-not $block.Contains($setting)) {
        throw "DCS program RAM is missing required setting: $setting"
    }
}

foreach ($setting in $forbidden) {
    if ($block.Contains($setting)) {
        throw "DCS program RAM contains unsafe setting: $setting"
    }
}

if ($text -notmatch 'reg\s+\[2:0\]\s+pm_be') {
    throw 'PM RAM byte-enable register is missing.'
}
if ($text -notmatch "pm_be\s*=\s*3'b111") {
    throw 'Full-width PM writes do not enable all three bytes.'
}
if ($text -notmatch "pm_be\s*=\s*3'b110") {
    throw 'Upper-word PM aliases do not use the native upper-byte enables.'
}
if ($text -match 'pm_wd\s*=\s*\{[^\r\n]*pmb_q\[7:0\]') {
    throw 'PM alias write still feeds Port A read data back into write data.'
}

Write-Host 'DCS program RAM timing contract: PASS'
