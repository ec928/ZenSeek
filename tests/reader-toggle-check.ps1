# Reader toggle: the control exists, says what it does, and is remembered.
#
# ZenSeek is a PowerShell script that loads its XAML at runtime, so neither the markup nor
# the script is checked by anything until the window is opened -- an illegal XML comment or
# a typo'd control name is a crash on launch and nothing sooner. This is the cheap check:
# it parses both, loads the markup for real, and runs the toggle's own functions against a
# real WPF ToggleButton.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\reader-toggle-check.ps1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase | Out-Null

$root = Split-Path -Parent $PSScriptRoot
$bat = Join-Path $root 'ZenSeek.bat'
$xaml = Join-Path $root 'ZenSeek.xaml'

$script:passed = 0
$script:failed = 0
function Assert($cond, $msg) {
    if ($cond) { $script:passed++; Write-Host "  OK   $msg" }
    else { $script:failed++; Write-Host "  FAIL $msg" -ForegroundColor Red }
}
function Info($msg) { Write-Host "  ..   $msg" }

Write-Host "`n=== the script parses ==="
# The .bat wrapper skips its own first five lines before handing the rest to PowerShell.
$src = (Get-Content $bat | Select-Object -Skip 5 | Out-String)
$errs = $null; $toks = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$toks, [ref]$errs)
Assert (-not $errs -or $errs.Count -eq 0) `
    ("ZenSeek.bat is valid PowerShell" + $(if ($errs -and $errs.Count) { " -- " + $errs[0].Message } else { "" }))

Write-Host "`n=== the markup loads, and the control is there ==="
$window = $null
try {
    $xml = [xml](Get-Content $xaml -Raw)
    $reader = New-Object System.Xml.XmlNodeReader $xml
    $window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlReader]$reader)
    Assert $true "ZenSeek.xaml loads (an XML comment containing '--' would not)"
} catch {
    Assert $false ("ZenSeek.xaml failed to load: " + $_.Exception.Message)
}

$tgl = $null
if ($window) { $tgl = $window.FindName('tglReader') }
Assert ($null -ne $tgl) "the reader toggle is in the markup as tglReader"

if ($tgl) {
    Info ("tglReader is " + $tgl.Width + "x" + $tgl.Height + ", content '" + $tgl.Content +
          "', checked " + $tgl.IsChecked)
    Assert ([bool]$tgl.IsChecked) "and defaults to TypoZen"
    Assert ($tgl.Width -le 120) ("and is small enough for the row it sits on (" + $tgl.Width + "px)")

    Write-Host "`n=== it says which reader will open, and why ==="
    # The real functions, lifted out of the script rather than reimplemented here.
    foreach ($name in @('Sync-ReaderToggle', 'Use-TypoZenReader', 'Resolve-TypoZenExe')) {
        $m = [regex]::Match($src, "(?ms)^function Global:$name \{.*?^\}")
        if (-not $m.Success) { Assert $false "found $name in the script"; continue }
        Invoke-Expression $m.Value
    }
    $global:tglReader = $tgl
    $global:appBaseDir = $root

    $tgl.IsChecked = $true
    Global:Sync-ReaderToggle
    Assert ($tgl.Content -eq 'TypoZen') "checked reads 'TypoZen'"
    Assert ($tgl.ToolTip -and "$($tgl.ToolTip)".Length -gt 40) "and carries a tooltip that explains it"
    Assert ((Global:Use-TypoZenReader) -eq $true) "and the code agrees TypoZen is in use"
    Info ("tooltip: " + ("$($tgl.ToolTip)" -replace "`r?`n", ' / '))

    $tgl.IsChecked = $false
    Global:Sync-ReaderToggle
    Assert ($tgl.Content -eq 'Native') "unchecked reads 'Native'"
    Assert ((Global:Use-TypoZenReader) -eq $false) "and the code agrees the built-in reader is in use"
    Info ("tooltip: " + ("$($tgl.ToolTip)" -replace "`r?`n", ' / '))
}

Write-Host "`n=== the exe location can be set by hand ==="
Assert ($src -match 'Add_MouseRightButtonUp') "right-clicking the toggle opens a picker"
Assert ($src -match 'typoZenExePath') "an explicit path is kept"
Assert ($src -match '(?s)function Global:Resolve-TypoZenExe \{.{0,400}typoZenExePath') `
    "and the resolver tries it before the sibling-folder convention"
Assert ($src -match 'TypoZenExePath = \$global:typoZenExePath') "it is written to settings"
Assert ($src -match '\$settings\.TypoZenExePath') "and read back"
if ($tgl) {
    $tgl.IsChecked = $true
    $global:typoZenExePath = $null
    Global:Sync-ReaderToggle
    Assert ("$($tgl.ToolTip)" -match 'Right-click') "and the tooltip says so"
    Info ("tooltip now: " + ("$($tgl.ToolTip)" -replace "`r?`n", ' / '))
}

Write-Host "`n=== the choice is written and read back ==="
Assert ($src -match 'UseTypoZen\s*=\s*\[bool\]\$tglReader\.IsChecked') `
    "the setting is written on close, with everything else"
Assert ($src -match '\$settings\.UseTypoZen') "and read back on load"
Assert ($src -match 'if \(-not \(Global:Use-TypoZenReader\)\) \{ return \$false \}') `
    "and Open-InTypoZen refuses when the built-in reader was chosen"

Write-Host "`npassed=$($script:passed) failed=$($script:failed)"
if ($script:failed) { Write-Host "READER TOGGLE FAILED" -ForegroundColor Red; exit 1 }
Write-Host "READER TOGGLE PASSED" -ForegroundColor Green
exit 0
