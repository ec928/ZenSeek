@echo off
set "FILE_ARG=%~1"
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "try { Get-Content '%~f0' | Select-Object -Skip 5 | Out-String | Invoke-Expression } catch { Write-Host '--- ERROR CAUGHT ---' -ForegroundColor Red; Write-Host $_.Exception.Message -ForegroundColor Yellow; Write-Host $_.ScriptStackTrace; Write-Host ''; Write-Host 'Press Enter to exit...' -ForegroundColor Cyan; [Console]::ReadLine() }"
exit /b

$global:appBaseDir = (Get-Location).Path
$xamlFile = Join-Path $global:appBaseDir "ZenSeek.xaml"
$themesFile = Join-Path $global:appBaseDir "ZenSeek_Themes.json"
$engineFile = Join-Path $global:appBaseDir "ZenSeek_Engine.cs"
$templateFile = Join-Path $global:appBaseDir "ZenSeek_Template.html"

if (-not (Test-Path $xamlFile) -or -not (Test-Path $themesFile) -or -not (Test-Path $engineFile) -or -not (Test-Path $templateFile)) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show("Missing external resources.`nPlease ensure all 5 files are in the same directory (`.bat`, `.xaml`, `.json`, `.cs`, `.html`).", "Missing Resources", 0, 'Error') | Out-Null
    exit
}

$appDataDir = Join-Path $env:LOCALAPPDATA "ZenSeek_Cache"
if (-not (Test-Path $appDataDir)) { New-Item -ItemType Directory -Path $appDataDir | Out-Null }

# --- CACHE CLEANUP ---
try {
    $cutoff = (Get-Date).AddDays(-1)
    Get-ChildItem -Path $appDataDir -Filter "TextSearch_WebView2*" -Directory | Where-Object { $_.CreationTime -lt $cutoff } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $appDataDir -Filter "EpubTemp_*" -Directory | Where-Object { $_.CreationTime -lt $cutoff } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $appDataDir -Filter "TextSearch_Reader*" -Directory | Where-Object { $_.CreationTime -lt $cutoff } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
} catch {}
# -------------------------

try { 
    Add-Type -AssemblyName System.Security
    Add-Type -AssemblyName System 
} catch {}

# --- LOAD C# SEARCH ENGINE ---
try {
    $csCode = Get-Content $engineFile -Raw
    Add-Type -TypeDefinition $csCode -ReferencedAssemblies "System", "System.IO.Compression", "System.IO.Compression.FileSystem", "System.Core", "System.Xml"
} catch { Write-Warning "C# compile failed: $($_.Exception.Message)" }

# Load Assemblies
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Windows.Forms
try { Add-Type -AssemblyName WindowsFormsIntegration } catch {}
Add-Type -AssemblyName System.Drawing
# Removed DwmApi inline definition

[System.Windows.Forms.Application]::EnableVisualStyles()

$global:webViewReady = $false
$global:webViewError = ""
$dllDir = $global:appBaseDir
$coreDll = Join-Path $dllDir "Microsoft.Web.WebView2.Core.dll"
$wpfDll = Join-Path $dllDir "Microsoft.Web.WebView2.Wpf.dll"
$winFormsDll = Join-Path $dllDir "Microsoft.Web.WebView2.WinForms.dll"
$loaderDll = Join-Path $dllDir "WebView2Loader.dll"

$needsDownload = $false
if (-not (Test-Path $coreDll) -or -not (Test-Path $wpfDll) -or -not (Test-Path $winFormsDll) -or -not (Test-Path $loaderDll)) {
    $needsDownload = $true
} else {
    try {
        $vCore = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($coreDll).FileVersion
        $vWpf = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($wpfDll).FileVersion
        $vWF = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($winFormsDll).FileVersion
        if ($vCore -ne $vWpf -or $vCore -ne $vWF) { $needsDownload = $true }
    } catch { $needsDownload = $true }
}

if ($needsDownload) {
    $res = [System.Windows.MessageBox]::Show("WebView2 wrapper DLLs are missing or versions are mismatched.`nDownload them automatically from NuGet (~8.5MB)?", "Missing Dependencies", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Information)
    if ($res -eq 'Yes') {
        try {
            Remove-Item $coreDll, $wpfDll, $winFormsDll, $loaderDll -Force -ErrorAction SilentlyContinue
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $zip = Join-Path $dllDir "webview2.zip"
            $extractPath = Join-Path $dllDir "webview2_temp"
            Invoke-WebRequest -Uri "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2" -OutFile $zip -UseBasicParsing
            Expand-Archive -Path $zip -DestinationPath $extractPath -Force
            Copy-Item "$extractPath\lib\net462\Microsoft.Web.WebView2.Core.dll" -Destination $dllDir -Force
            Copy-Item "$extractPath\lib\net462\Microsoft.Web.WebView2.Wpf.dll" -Destination $dllDir -Force
            Copy-Item "$extractPath\lib\net462\Microsoft.Web.WebView2.WinForms.dll" -Destination $dllDir -Force
            Copy-Item "$extractPath\runtimes\win-x64\native\WebView2Loader.dll" -Destination $dllDir -Force
            Remove-Item $zip -Force
            Remove-Item $extractPath -Recurse -Force
        } catch { [System.Windows.MessageBox]::Show("Failed to download dependencies: $($_.Exception.Message)", "Error") | Out-Null }
    }
}

try { 
    Add-Type -Path $coreDll
    Add-Type -Path $wpfDll
    Add-Type -Path $winFormsDll
    # Lightweight check that the actual WebView2 runtime is present (not just the .NET wrappers)
    try {
        [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::GetAvailableBrowserVersionString() | Out-Null
        $global:webViewReady = $true 
    } catch {
        $global:webViewError = "WebView2 runtime is not installed or not working on this system."
        $global:webViewReady = $false
    }
} catch { 
    $global:webViewError = $_.Exception.Message
    $global:webViewReady = $false 
}

# --- HELPER FUNCTIONS ---
function New-Ctrl($type, $props, $parent) { 
    $c = New-Object System.Windows.Forms.$type -Property $props
    $parent.Controls.Add($c)
    return $c 
}

function Global:Update-HistoryList($List, $NewItem, $Max) {
    if ([string]::IsNullOrWhiteSpace($NewItem)) { return $List }
    $newList = [System.Collections.ArrayList]::new()
    [void]$newList.Add($NewItem)
    if ($null -ne $List) { foreach ($item in $List) { if ($item -ne $NewItem -and $newList.Count -lt $Max) { [void]$newList.Add($item) } } }
    return $newList.ToArray()
}

function Global:Sync-Combo($cmb, $list, $txt) {
    $cmb.Items.Clear()
    if ($list) { $list | ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) { [void]$cmb.Items.Add($_) } } }
    if ($txt) { $cmb.Text = $txt }
}

function Global:Get-SmartContextBounds($linesArr, $targetIdx, $ctxCount) {
    if ($null -eq $linesArr -or $linesArr.Count -eq 0) { return @($targetIdx, $targetIdx) }
    $ctx = [Math]::Max(0, $ctxCount)
    if ($ctx -eq 0) { return @($targetIdx, $targetIdx) }
    
    $start = $targetIdx; $cnt=0
    for($i=$targetIdx-1; $i-ge0; $i--) {
        if(-not [string]::IsNullOrWhiteSpace($linesArr[$i])) { 
            $start=$i; if(++$cnt -ge $ctx) {break}
        }
    }
    
    $end = $targetIdx; $cnt=0
    for($i=$targetIdx+1; $i -lt $linesArr.Count; $i++) {
        if(-not [string]::IsNullOrWhiteSpace($linesArr[$i])) { 
            $end=$i; if(++$cnt -ge $ctx) {break}
        }
    }
    return @($start, $end)
}

function Global:Show-HexColorDialog($initHex) {
    $cForm = New-Object System.Windows.Forms.Form -Property @{ Text="Set Colour"; Size="330,130"; FormBorderStyle="FixedToolWindow"; StartPosition="CenterParent"; MinimizeBox=$false; MaximizeBox=$false }
    $lbl = New-Object System.Windows.Forms.Label -Property @{Location="10,15"; Size="60,20"; Text="Hex:"}
    $txt = New-Object System.Windows.Forms.TextBox -Property @{Location="75,12"; Size="100,23"; Text=$initHex}
    $pnl = New-Object System.Windows.Forms.Panel -Property @{Location="185,12"; Size="35,23"; BorderStyle="FixedSingle"}
    $btnPick = New-Object System.Windows.Forms.Button -Property @{Location="230,11"; Size="70,25"; Text="Pick..."}
    try { $pnl.BackColor = [System.Drawing.ColorTranslator]::FromHtml($initHex) } catch {}
    $btnOk = New-Object System.Windows.Forms.Button -Property @{Location="70,55"; Size="80,25"; Text="OK"; DialogResult="OK"}
    $btnCancel = New-Object System.Windows.Forms.Button -Property @{Location="160,55"; Size="80,25"; Text="Cancel"; DialogResult="Cancel"}
    $txt.Add_TextChanged({ try { $pnl.BackColor = [System.Drawing.ColorTranslator]::FromHtml($txt.Text) } catch {} })
    $btnPick.Add_Click({
        $vd = New-Object System.Windows.Forms.ColorDialog
        try { $vd.Color = [System.Drawing.ColorTranslator]::FromHtml($txt.Text) } catch {}
        if ($vd.ShowDialog() -eq 'OK') { $hex = "#{0:X2}{1:X2}{2:X2}" -f $vd.Color.R, $vd.Color.G, $vd.Color.B; $txt.Text = $hex; $pnl.BackColor = $vd.Color }
    })
    $cForm.Controls.AddRange(@($lbl, $txt, $pnl, $btnPick, $btnOk, $btnCancel))
    $cForm.AcceptButton = $btnOk
    $cForm.CancelButton = $btnCancel
    if ($cForm.ShowDialog() -eq 'OK') { return $txt.Text }
    return $null
}

# A theme's FN is a CSS stack ("'Literata', 'Georgia', serif"), but the Font combo lists
# bare installed family names - a direct match never succeeds, so every theme fell back to
# Consolas (which also forced the reader's own CSS to Consolas). Walk the stack and return
# the first family actually installed, or $null if none are.
function Global:Resolve-ThemeFontName($cssStack) {
    try {
        if (-not $global:installedFontNames) {
            $global:installedFontNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            [System.Drawing.FontFamily]::Families | ForEach-Object { [void]$global:installedFontNames.Add($_.Name) }
        }
        $generic = @('serif','sans-serif','monospace','cursive','fantasy','system-ui','ui-serif','ui-sans-serif','ui-monospace')
        $wanted = @()
        foreach ($part in ($cssStack -split ',')) {
            $n = $part.Trim().Trim("'").Trim('"').Trim()
            if (-not $n -or ($generic -contains $n.ToLower())) { continue }
            $wanted += $n
        }
        # Stack order wins, as in CSS: take the first entry that is present at all, trying
        # its exact name then its suffixed form. Variable/optical-size fonts are registered
        # under a suffixed family name - "Merriweather" installs as "Merriweather 18pt"
        # (alongside "Merriweather Light 18pt" etc), so shortest match picks the regular.
        foreach ($n in $wanted) {
            if ($global:installedFontNames.Contains($n)) { return $n }
            $hit = $global:installedFontNames | Where-Object { $_ -like "$n *" } | Sort-Object Length | Select-Object -First 1
            if ($hit) { return $hit }
        }
    } catch {}
    return $null
}

$script:applyThemeToReaderForm = {
    param($frm, $theme)
    try {
        $cBg = [System.Drawing.ColorTranslator]::FromHtml($theme.Bg)
        $cTx = [System.Drawing.ColorTranslator]::FromHtml($theme.Tx)
        $cHi = [System.Drawing.ColorTranslator]::FromHtml($theme.Hi)
        $frm.BackColor = $cBg

        $colorRef = [System.Drawing.ColorTranslator]::ToWin32([System.Drawing.ColorTranslator]::FromHtml($theme.Bg))
        [FastSearcher]::DwmSetWindowAttribute($frm.Handle, 35, [ref]$colorRef, 4)
        
        $allCtrls = [System.Collections.ArrayList]::new()
    
        if ($frm.Controls["pnlMenu"]) { 
            $frm.Controls["pnlMenu"].BackColor = $cBg 
            $allCtrls.AddRange($frm.Controls["pnlMenu"].Controls) 
        }
        if ($frm.Controls["pnlSettings"]) { 
            $frm.Controls["pnlSettings"].BackColor = $cBg 
            $allCtrls.AddRange($frm.Controls["pnlSettings"].Controls) 
        }
        $allCtrls.AddRange($frm.Controls)

         foreach ($c in $allCtrls) { 
            if ($c.Name -match "^div") {
                $c.BackColor = $cTx
                continue
            }
            
            $c.ForeColor = $cTx
            $c.BackColor = $cBg
        
            if ($c -is [System.Windows.Forms.Button] -or ($c -is [System.Windows.Forms.CheckBox] -and $c.Appearance -eq 'Button')) { 
                $c.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
                $c.FlatAppearance.BorderColor = $cTx 
                if ($c -is [System.Windows.Forms.CheckBox]) { $c.FlatAppearance.CheckedBackColor = $cBg }
            } 
            elseif ($c -is [System.Windows.Forms.ComboBox] -or $c -is [System.Windows.Forms.NumericUpDown] -or $c -is [System.Windows.Forms.TextBox]) {
                if ($c -is [System.Windows.Forms.ComboBox]) { $c.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat }
                # FixedSingle, not None: a NumericUpDown clamps its height to PreferredHeight,
                # and removing the border drops that by ~4px at 96dpi (more when scaled), which
                # shrinks the value inside the box. FixedSingle keeps the height in line with
                # the combo boxes and leaves the same thin inner line the combos already draw.
                else { try { $c.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle } catch {} }
            }
        }

        # ComboBox/NumericUpDown/TextBox have no settable border colour, so the panel draws
        # one for them. Read from $script: at paint time - a local would be gone by then.
        $script:readerBorderColor = $cTx
        foreach ($pName in @("pnlMenu", "pnlSettings")) {
            $pnl = $frm.Controls[$pName]
            if (-not $pnl) { continue }

            # Dropping the border shrinks a NumericUpDown to ~16px, so its value sits high in
            # the drawn box. Centre it on the combo row (combos keep their designed height, so
            # measuring from them stays stable no matter how often the theme is re-applied).
            $refs = @()
            foreach ($ctl in $pnl.Controls) { if ($ctl -is [System.Windows.Forms.ComboBox]) { $refs += $ctl } }
            if ($refs.Count -gt 0) {
                $rowTop = ($refs | ForEach-Object { $_.Top } | Measure-Object -Minimum).Minimum
                $rowH   = ($refs | ForEach-Object { $_.Height } | Measure-Object -Maximum).Maximum
                foreach ($ctl in $pnl.Controls) {
                    if ($ctl -is [System.Windows.Forms.NumericUpDown] -or $ctl -is [System.Windows.Forms.TextBox]) {
                        if ([Math]::Abs($ctl.Top - $rowTop) -le 10) {   # same row only
                            $ctl.Top = $rowTop + [int](($rowH - $ctl.Height) / 2)
                        }
                    }
                }
            }
            if ($pnl.Tag -ne "themedBorders") {
                $pnl.Tag = "themedBorders"      # attach once, not on every theme change
                $pnl.Add_Paint({
                    $pen = New-Object System.Drawing.Pen($script:readerBorderColor, 1)
                    try {
                        $targets = @()
                        foreach ($ctl in $this.Controls) {
                            if ($ctl -is [System.Windows.Forms.ComboBox] -or $ctl -is [System.Windows.Forms.NumericUpDown] -or $ctl -is [System.Windows.Forms.TextBox]) { $targets += $ctl }
                        }
                        if ($targets.Count -gt 0) {
                            # One row height for every box. Hugging each control instead would
                            # expose the type-to-type height difference (NumericUpDown is 20px
                            # tall, ComboBox 21), which reads as ragged sizing.
                            $top = ($targets | ForEach-Object { $_.Top } | Measure-Object -Minimum).Minimum
                            $bot = ($targets | ForEach-Object { $_.Bottom } | Measure-Object -Maximum).Maximum
                            foreach ($ctl in $targets) {
                                $_.Graphics.DrawRectangle($pen, ($ctl.Left - 1), ($top - 1), ($ctl.Width + 1), ($bot - $top + 1))
                            }
                        }
                    } catch {}
                    $pen.Dispose()
                })
            }
            $pnl.Invalidate()
        }
    } catch {}
}

# --- EXTRACTED XAML, HTML TEMPLATE, AND THEMES INITIALIZATION ---
$mainXaml = Get-Content $xamlFile -Raw
$xmlReader = (New-Object System.Xml.XmlNodeReader ([xml]$mainXaml))
$window = [Windows.Markup.XamlReader]::Load($xmlReader)

# -Encoding UTF8 is required: the themes file has no BOM, so Windows PowerShell would
# otherwise read it as ANSI and mangle accented names (e.g. "Rose Pine Dawn").
$script:themes = Get-Content $themesFile -Raw -Encoding UTF8 | ConvertFrom-Json
$global:htmlTemplate = Get-Content $templateFile -Raw

# Wire Controls
$cmbDir = $window.FindName("cmbDir")
$cmbStr = $window.FindName("cmbStr")
$btnBrowse = $window.FindName("btnBrowse")
$chkSubfolders = $window.FindName("chkSubfolders")
$chkWholeWordMain = $window.FindName("chkWholeWordMain")
$chkCaseMain = $window.FindName("chkCaseMain")
$chkRegex = $window.FindName("chkRegex")
$tglReader = $window.FindName("tglReader")
# Empty means "find TypoZen by convention"; set by right-clicking the reader toggle.
$global:typoZenExePath = $null
$btnSearch = $window.FindName("btnSearch")
$txtFilter = $window.FindName("txtFilter")
$txtExcl = $window.FindName("txtExcl")
$lstResults = $window.FindName("lstResults")
$txtInlinePreview = $window.FindName("txtInlinePreview")
$statusLabel = $window.FindName("statusLabel")

$mOpen = $window.FindName("mOpen")
$mWith = $window.FindName("mWith")
$mLoc = $window.FindName("mLoc")
$mPrev = $window.FindName("mPrev")

$btnInlinePrev = $window.FindName("btnInlinePrev")
$btnInlineNext = $window.FindName("btnInlineNext")
$lblInlineStatus = $window.FindName("lblInlineStatus")
$inlineContextHost = $window.FindName("numInlineContextHost")
$script:numInlineContext = if ($inlineContextHost -and $inlineContextHost.Child) { $inlineContextHost.Child } else { $null }
if ($script:numInlineContext) {
    $script:numInlineContext.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#2F3E51")
    $script:numInlineContext.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#E2E8F0")
}

$script:activeTheme = 10
$script:sortCol = "DateModified"
$script:sortDesc = $true
$script:currentResults = @()

$global:dRecentDirs = @()
$global:dRecentSearches = @()
$global:dRecentFilters = @()
$global:dRecentExcl = @()
$global:epubPositions = @{}
$script:rW = 1208
$script:rH = 1371
$script:rX = -1
$script:rY = -1
$script:rContext = 4
$script:inlineContext = 4
$script:rSmartQuotes = $true
$script:rLineSp = "1.6"
$script:rMargin = "Narrow"
$script:rAlign = $false
$script:inlineAllLines = @()
$script:inlineMatchIndices = @()
$script:inlineCurrentIndex = 0

# --- LOAD UNENCRYPTED CONFIGURATION ---
$configFile = "$global:appBaseDir\ZenSeek.json"
if (Test-Path $configFile) {
    try {
        $jsonStr = Get-Content $configFile -Raw -ErrorAction SilentlyContinue
        $settings = $jsonStr | ConvertFrom-Json
        
        if ($settings.RecentDirectories) { $global:dRecentDirs = @($settings.RecentDirectories) }
        if ($settings.Directory) { $cmbDir.Text = $settings.Directory }
        if ($settings.RecentSearches) { $global:dRecentSearches = @($settings.RecentSearches) }
        if ($settings.SearchString) { $cmbStr.Text = $settings.SearchString }
        if ($settings.RecentFilters) { $global:dRecentFilters = @($settings.RecentFilters) }
        if ($settings.RecentExcl) { $global:dRecentExcl = @($settings.RecentExcl) }
        if ($settings.FileFilter) { $txtFilter.Text = $settings.FileFilter }
        if ($settings.Exclusions) { $txtExcl.Text = $settings.Exclusions }
        
        if ($settings.EpubPositions) { 
            foreach ($prop in $settings.EpubPositions.psobject.properties) {
                $global:epubPositions[$prop.Name] = $prop.Value
            }
        }
    
        if ($null -ne $settings.SearchSubfolders) { $chkSubfolders.IsChecked = [bool]$settings.SearchSubfolders }
        if ($null -ne $settings.UseRegex) { $chkRegex.IsChecked = [bool]$settings.UseRegex }
        # Absent means TypoZen: the default is the new reader, not the old one.
        if ($null -ne $settings.UseTypoZen) { $tglReader.IsChecked = [bool]$settings.UseTypoZen }
        if ($settings.TypoZenExePath) { $global:typoZenExePath = [string]$settings.TypoZenExePath }
        if ($null -ne $settings.WholeWord) { $chkWholeWordMain.IsChecked = [bool]$settings.WholeWord }
        if ($null -ne $settings.MatchCase) { $chkCaseMain.IsChecked = [bool]$settings.MatchCase }
        
        if ($settings.SortColumn) { $script:sortCol = $settings.SortColumn }
        if ($null -ne $settings.SortDesc) { $script:sortDesc = [bool]$settings.SortDesc }
  
        if ($settings.MainWidth -and $settings.MainHeight) {
            $window.Width = $settings.MainWidth
            $window.Height = $settings.MainHeight
            $window.WindowStartupLocation = "Manual"
            $window.Left = $settings.MainX
            $window.Top = $settings.MainY
        }
    
        if ($settings.ReaderWidth) { $script:rW = [int]$settings.ReaderWidth }
        if ($settings.ReaderHeight) { $script:rH = [int]$settings.ReaderHeight }
        if ($settings.ReaderX) { $script:rX = [int]$settings.ReaderX }
        if ($settings.ReaderY) { $script:rY = [int]$settings.ReaderY }
        if ($null -ne $settings.ReaderContext) { $script:rContext = [int]$settings.ReaderContext }
        if ($null -ne $settings.InlineContext) { $script:inlineContext = [int]$settings.InlineContext }
        if ($null -ne $settings.ReaderSmartQuotes) { $script:rSmartQuotes = [bool]$settings.ReaderSmartQuotes }
        if ($null -ne $settings.ReaderLineSp) { $script:rLineSp = $settings.ReaderLineSp }
        if ($null -ne $settings.ReaderMargin) { $script:rMargin = $settings.ReaderMargin }
        if ($null -ne $settings.ReaderAlign) { $script:rAlign = [bool]$settings.ReaderAlign }
        if ($null -ne $settings.ActiveThemeIndex) { $script:activeTheme = [int]$settings.ActiveThemeIndex }
        
        # Apply saved custom theme colors (overrides factory themes.json unless Reset was used)
        if ($settings.Themes -and $settings.Themes.Count -eq $script:themes.Count) {
            for ($i=0; $i -lt $script:themes.Count; $i++) {
                if ($settings.Themes[$i].Bg) { $script:themes[$i].Bg = $settings.Themes[$i].Bg }
                if ($settings.Themes[$i].Tx) { $script:themes[$i].Tx = $settings.Themes[$i].Tx }
                if ($settings.Themes[$i].Hi) { $script:themes[$i].Hi = $settings.Themes[$i].Hi }
                if ($settings.Themes[$i].FN) { $script:themes[$i].FN = $settings.Themes[$i].FN }
                if ($settings.Themes[$i].FS) { $script:themes[$i].FS = [int]$settings.Themes[$i].FS }
            }
        }
    } catch {}
}

# Populate Combobox History Arrays
Global:Sync-Combo $cmbDir $global:dRecentDirs ""
Global:Sync-Combo $cmbStr $global:dRecentSearches ""
Global:Sync-Combo $txtFilter $global:dRecentFilters ""
Global:Sync-Combo $txtExcl $global:dRecentExcl ""
$cmbStr.Items.Insert(0, "")

if ([string]::IsNullOrWhiteSpace($cmbDir.Text)) { 
    $cmbDir.Text = if ($global:dRecentDirs.Count -gt 0) { $global:dRecentDirs[0] } elseif (Test-Path "$env:USERPROFILE\Documents") { "$env:USERPROFILE\Documents" } else { $global:appBaseDir }
}

if ($script:numInlineContext) {
    $script:numInlineContext.Value = $script:inlineContext
}

# Apply active theme to main window context selector (to match reader)
if ($script:numInlineContext -and $script:activeTheme -ge 0 -and $script:activeTheme -lt $script:themes.Count) {
    $t = $script:themes[$script:activeTheme]
    try {
        $cBg = [System.Drawing.ColorTranslator]::FromHtml($t.Bg)
        $cTx = [System.Drawing.ColorTranslator]::FromHtml($t.Tx)
        $script:numInlineContext.BackColor = $cBg
        $script:numInlineContext.ForeColor = $cTx
    } catch {
        # fallback to original dark colors
        $script:numInlineContext.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#2F3E51")
        $script:numInlineContext.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#E2E8F0")
    }
}

# --- SAVE UNENCRYPTED CONFIGURATION ON CLOSE ---
$window.Add_Closing({
    $appState = [ordered]@{ 
        RecentDirectories = $global:dRecentDirs
        Directory = $cmbDir.Text
        RecentSearches = $global:dRecentSearches
        SearchString = $cmbStr.Text
        RecentFilters = $global:dRecentFilters
        RecentExcl = $global:dRecentExcl
        FileFilter = $txtFilter.Text
        Exclusions = $txtExcl.Text
        EpubPositions = $global:epubPositions
        SearchSubfolders = [bool]$chkSubfolders.IsChecked
        UseRegex = [bool]$chkRegex.IsChecked
        UseTypoZen = [bool]$tglReader.IsChecked
        TypoZenExePath = $global:typoZenExePath
        WholeWord = [bool]$chkWholeWordMain.IsChecked
        MatchCase = [bool]$chkCaseMain.IsChecked
        SortColumn = $script:sortCol
        SortDesc = $script:sortDesc
        MainWidth = $window.ActualWidth
        MainHeight = $window.ActualHeight
        MainX = $window.Left
        MainY = $window.Top
        ReaderWidth = $script:rW
        ReaderHeight = $script:rH
        ReaderX = $script:rX
        ReaderY = $script:rY
        ReaderContext = $script:rContext
        InlineContext = if ($script:numInlineContext) { [int]$script:numInlineContext.Value } else { $script:inlineContext }
        ReaderSmartQuotes = $script:rSmartQuotes
        ReaderLineSp = $script:rLineSp
        ReaderMargin = $script:rMargin
        ReaderAlign = $script:rAlign
        ActiveThemeIndex = $script:activeTheme
        Themes = $script:themes
    }
    $json = $appState | ConvertTo-Json -Depth 3
    $json | Out-File $configFile -Encoding utf8
})

function Global:Refresh-ListView {
    if ($null -eq $script:currentResults) { $script:currentResults = @() }
    $prop = $script:sortCol
    if ($prop -eq "Size") { $prop = "RawSize" }
    if ($prop -eq "DateModified") { $prop = "RawDate" }

    # @() is required: with exactly one result the pipeline returns a bare DisplayResult,
    # and ItemsSource needs IEnumerable - assigning the scalar throws.
    $sorted = @($script:currentResults | Sort-Object $prop -Descending:$script:sortDesc)
    $lstResults.ItemsSource = $sorted
    
    # ENCODING FIX FOR SORT INDICATORS
    $gv = $lstResults.View
    if ($gv -and $gv.Columns.Count -eq 4) {
        $arrUp = [string][char]0x25B2
        $arrDn = [string][char]0x25BC
        
        $gv.Columns[0].Header = "Name" + $(if($script:sortCol -eq "Name"){if($script:sortDesc){" $arrDn"}else{" $arrUp"}}else{""})
        $gv.Columns[1].Header = "Date Modified" + $(if($script:sortCol -eq "DateModified"){if($script:sortDesc){" $arrDn"}else{" $arrUp"}}else{""})
        $gv.Columns[2].Header = "Size" + $(if($script:sortCol -eq "Size"){if($script:sortDesc){" $arrDn"}else{" $arrUp"}}else{""})
        $gv.Columns[3].Header = "Folder" + $(if($script:sortCol -eq "Folder"){if($script:sortDesc){" $arrDn"}else{" $arrUp"}}else{""})
    }
}

$lstResults.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
    param($sender, $e)
    if ($e.OriginalSource -is [System.Windows.Controls.GridViewColumnHeader]) {
        $col = $e.OriginalSource.Column
        if ($col) {
            $bindPath = $null
            if ($col.DisplayMemberBinding) { $bindPath = $col.DisplayMemberBinding.Path.Path }
            elseif ($col.Header -match "Size") { $bindPath = "Size" }
            
            if ($bindPath) {
                if ($script:sortCol -eq $bindPath) {
                    $script:sortDesc = -not $script:sortDesc
                } else {
                    $script:sortCol = $bindPath
                    $script:sortDesc = $false
                }
                Global:Refresh-ListView
            }
        }
    }
})

$lstResults.Add_SelectionChanged({
    if ($lstResults.SelectedItem) {
        $path = $lstResults.SelectedItem.FullPath
        $searchStr = $cmbStr.Text
        
        if ([string]::IsNullOrWhiteSpace($searchStr) -or -not (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue)) {
            $txtInlinePreview.Text = $lstResults.SelectedItem.MatchText
            $lblInlineStatus.Text = ""
            return
        }

        try {
            $regexObj = [FastSearcher]::GetSearchRegex($searchStr, [bool]$chkRegex.IsChecked, [bool]$chkWholeWordMain.IsChecked, [bool]$chkCaseMain.IsChecked)
            $allLines = [FastSearcher]::GetFileLines($path)
            
            $matchIndicesArr = [FastSearcher]::GetMatchIndices($allLines, $regexObj)

            if ($matchIndicesArr.Length -gt 0) {
                $script:inlineAllLines = $allLines
                $script:inlineMatchIndices = $matchIndicesArr
                $script:inlineCurrentIndex = 0
                Update-InlinePreview 0
            } else {
                $txtInlinePreview.Text = $lstResults.SelectedItem.MatchText
                $lblInlineStatus.Text = ""
                $script:inlineMatchIndices = @()
             }
        } catch {
            $txtInlinePreview.Text = $lstResults.SelectedItem.MatchText
            $lblInlineStatus.Text = "Preview processing error."
        }
    } else {
        $txtInlinePreview.Text = ""
        $lblInlineStatus.Text = ""
    }
})

function Update-InlinePreview ($direction) {
    if (-not $script:inlineMatchIndices -or $script:inlineMatchIndices.Count -eq 0) { return }
    
    $script:inlineCurrentIndex += $direction
    if ($script:inlineCurrentIndex -lt 0) { $script:inlineCurrentIndex = $script:inlineMatchIndices.Count - 1 }
    if ($script:inlineCurrentIndex -ge $script:inlineMatchIndices.Count) { $script:inlineCurrentIndex = 0 }
    
    $ctx = 0
    if ($script:numInlineContext) {
        $ctx = [int]$script:numInlineContext.Value
    }
    
    $targetLine = $script:inlineMatchIndices[$script:inlineCurrentIndex]
    
    $bounds = Global:Get-SmartContextBounds $script:inlineAllLines $targetLine $ctx
    $startLine = $bounds[0]
    $endLine = $bounds[1]
    
    $displayLines = [System.Collections.Generic.List[string]]::new()
    for ($i = $startLine; $i -le $endLine; $i++) {
        if ($i -eq $targetLine) {
            $displayLines.Add(">> " + $script:inlineAllLines[$i])
        } else {
           $displayLines.Add("   " + $script:inlineAllLines[$i])
        }
    }
    
    $txtInlinePreview.Text = $displayLines -join "`n"
    $lblInlineStatus.Text = "Match $($script:inlineCurrentIndex + 1) of $($script:inlineMatchIndices.Count)"
}

# The value itself is written on close, with every other setting.
$tglReader.Add_Checked({ Global:Sync-ReaderToggle })
$tglReader.Add_Unchecked({ Global:Sync-ReaderToggle })

# Right-click: point at TypoZen.exe wherever it actually is.
#
# The sibling-folder convention covers the normal layout and nothing else, and when it
# fails the only symptom is that results quietly open in the built-in reader. Rather than
# add a settings page for one path, the control that chooses the reader is also the one
# that says which reader -- and the tooltip names the file in use.
$tglReader.Add_MouseRightButtonUp({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "Select TypoZen.exe"
    $dlg.Filter = "TypoZen (TypoZen.exe)|TypoZen.exe|Executables (*.exe)|*.exe"
    $cur = $global:typoZenExePath
    if ([string]::IsNullOrWhiteSpace($cur)) { $cur = $global:typoZenExeResolved }
    if (-not [string]::IsNullOrWhiteSpace($cur)) {
        try { $dlg.InitialDirectory = Split-Path -Parent $cur } catch {}
    }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $picked = $dlg.FileName
        if ([System.IO.Path]::GetFileName($picked) -ine "TypoZen.exe") {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                "That is not called TypoZen.exe:`n`n$picked`n`nUse it anyway?",
                "Select TypoZen.exe", 4, 'Question')
            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        $global:typoZenExePath = $picked
        # Choosing one is also choosing to use it.
        $tglReader.IsChecked = $true
        Global:Sync-ReaderToggle
    }
})

$btnInlinePrev.Add_Click({ Update-InlinePreview -1 })
$btnInlineNext.Add_Click({ Update-InlinePreview 1 })

if ($script:numInlineContext) {
    $script:numInlineContext.Add_ValueChanged({
        if ($script:inlineMatchIndices -and $script:inlineMatchIndices.Count -gt 0) {
            Update-InlinePreview 0
        }
    })
}

$btnBrowse.Add_Click({
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    $fb.SelectedPath = $cmbDir.Text
    if ($fb.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $cmbDir.Text = $fb.SelectedPath }
})

function Exec-File($action, $tFile) {
    if ([string]::IsNullOrWhiteSpace($tFile)) { 
        if (-not $lstResults.SelectedItem) { return }
        $tFile = $lstResults.SelectedItem.FullPath 
    }
    if ([string]::IsNullOrWhiteSpace($tFile) -or -Not (Test-Path -LiteralPath $tFile -ErrorAction SilentlyContinue)) { return }
    try {
        if ($action -eq 'open') { [System.Diagnostics.Process]::Start($tFile) | Out-Null }
        if ($action -eq 'with') { (New-Object -ComObject Shell.Application).Namespace([System.IO.Path]::GetDirectoryName($tFile)).ParseName([System.IO.Path]::GetFileName($tFile)).InvokeVerb("openas") }
        if ($action -eq 'loc')  { [System.Diagnostics.Process]::Start("explorer.exe", "/select,`"$tFile`"") | Out-Null }
    } catch {}
}

# The reader a result opens in. TypoZen unless the user says otherwise.
#
# One function owns the label, the tooltip and the answer, so the button cannot say one
# thing while the code does another. The label names the reader that WILL open -- a toggle
# labelled with the state it would switch to is read backwards by half of everyone.
function Global:Sync-ReaderToggle {
    if (-not $tglReader) { return }
    $useTypo = [bool]$tglReader.IsChecked
    if ($useTypo) {
        $tglReader.Content = "TypoZen"
        $tip = "Opening results in TypoZen." + [Environment]::NewLine +
               "Reader mode, pagination, and the match highlighted where it sits in the book." + [Environment]::NewLine + [Environment]::NewLine +
               "Click to use ZenSeek's built-in reader instead."
        $exe = Global:Resolve-TypoZenExe
        if ($exe) {
            $tip += [Environment]::NewLine + [Environment]::NewLine + "Using:  $exe"
            if (-not [string]::IsNullOrWhiteSpace($global:typoZenExePath)) {
                $tip += "   (set by hand)"
            }
        } else {
            $tip = "TypoZen is selected but TypoZen.exe was not found." + [Environment]::NewLine +
                   "Looked for it as a sibling folder:  <parent>\TypoZen\TypoZen.exe" + [Environment]::NewLine +
                   "The built-in reader will be used until it is found." + [Environment]::NewLine + [Environment]::NewLine +
                   "Click to use ZenSeek's built-in reader instead."
        }
        $tip += [Environment]::NewLine + "Right-click to choose TypoZen.exe yourself."
        $tglReader.ToolTip = $tip
    } else {
        $tglReader.Content = "Native"
        $tglReader.ToolTip = "Opening results in ZenSeek's built-in reader." + [Environment]::NewLine +
                             "Stays in this window; no external process." + [Environment]::NewLine + [Environment]::NewLine +
                             "Click to use TypoZen instead."
    }
}

function Global:Use-TypoZenReader {
    if (-not $tglReader) { return $true }   # no control yet: the default stands
    return [bool]$tglReader.IsChecked
}

# Phase 6: open results in TypoZen (sibling project) when available.
# Fallback: built-in WebView2 reader below (docx/xlsx, or TypoZen missing).
function Global:Resolve-TypoZenExe {
    # An explicit path wins, if one was set and still exists. Everything below is the
    # convention -- TypoZen as a sibling folder -- which is right until someone moves it.
    if (-not [string]::IsNullOrWhiteSpace($global:typoZenExePath)) {
        try {
            if (Test-Path -LiteralPath $global:typoZenExePath -PathType Leaf) {
                $global:typoZenExeResolved = $global:typoZenExePath
                return $global:typoZenExePath
            }
        } catch {}
    }

    # Prefer the folder ZenSeek actually lives in (bat dir), not whatever cwd PowerShell has.
    $roots = @()
    if ($global:appBaseDir) { $roots += $global:appBaseDir }
    try {
        if ($PSScriptRoot) { $roots += $PSScriptRoot }
    } catch {}
    try {
        $mi = $MyInvocation.MyCommand.Path
        if ($mi) { $roots += (Split-Path -Parent $mi) }
    } catch {}
    try { $roots += (Get-Location).Path } catch {}

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $parent = Split-Path $root -Parent
        if ($parent) {
            [void]$candidates.Add((Join-Path $parent "TypoZen\TypoZen.exe"))
            [void]$candidates.Add((Join-Path $parent "TypoZen\bin\Release\TypoZen.exe"))
            [void]$candidates.Add((Join-Path $parent "TypoZen\bin\Debug\TypoZen.exe"))
        }
        [void]$candidates.Add((Join-Path $root "..\TypoZen\TypoZen.exe"))
        [void]$candidates.Add((Join-Path $root "TypoZen\TypoZen.exe"))
    }
    # Absolute fallback for this machine's layout (0-Development\ZenSeek + TypoZen)
    try {
        $dev = Split-Path $global:appBaseDir -Parent
        if ($dev) { [void]$candidates.Add((Join-Path $dev "TypoZen\TypoZen.exe")) }
    } catch {}

    $seen = @{}
    foreach ($c in $candidates) {
        try {
            $full = [System.IO.Path]::GetFullPath($c)
            if ($seen.ContainsKey($full.ToLowerInvariant())) { continue }
            $seen[$full.ToLowerInvariant()] = $true
            if (Test-Path -LiteralPath $full -ErrorAction SilentlyContinue) {
                $global:typoZenExeResolved = $full
                return $full
            }
        } catch {}
    }
    $global:typoZenExeResolved = $null
    return $null
}

function Global:Open-InTypoZen {
    param(
        [string]$Path,
        [string]$Search = $null,
        [int]$MatchIndex = -1,
        [int]$Line = -1
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    # The user's choice comes first: everything below is about whether TypoZen *can* open
    # this, and none of it matters if they asked for the built-in reader.
    if (-not (Global:Use-TypoZenReader)) { return $false }
    $ext = [System.IO.Path]::GetExtension($Path)
    # Types TypoZen opens well. Everything else keeps ZenSeek's built-in reader.
    if ($ext -notmatch '(?i)\.(md|markdown|txt|log|csv|epub)$') { return $false }
    $exe = Global:Resolve-TypoZenExe
    if (-not $exe) {
        # One quiet diagnostic so "falls back to built-in" is not a mystery.
        try {
            if (-not $global:typoZenMissingWarned) {
                $global:typoZenMissingWarned = $true
                [System.Windows.Forms.MessageBox]::Show(
                    "TypoZen.exe was not found next to ZenSeek.`n`n" +
                    "Expected:  <parent>\TypoZen\TypoZen.exe`n" +
                    "ZenSeek folder:  $($global:appBaseDir)`n`n" +
                    "Rebuild TypoZen (Build_TypoZen.ps1) or the built-in reader will be used.",
                    "TypoZen not found", 0, 'Warning') | Out-Null
            }
        } catch {}
        return $false
    }

    # Build a single argument string with proper quoting (paths/spaces/search).
    $quote = {
        param($s)
        if ($null -eq $s) { return '""' }
        $s = [string]$s
        if ($s -match '[\s"]') { return '"' + ($s -replace '"', '\"') + '"' }
        return $s
    }
    $parts = New-Object System.Collections.Generic.List[string]
    [void]$parts.Add('--reader')
    if (-not [string]::IsNullOrWhiteSpace($Search)) {
        [void]$parts.Add('--search')
        [void]$parts.Add((& $quote $Search))
    }
    if ($MatchIndex -ge 0) {
        [void]$parts.Add('--match-index')
        [void]$parts.Add("$MatchIndex")
    }
    if ($Line -ge 0) {
        [void]$parts.Add('--line')
        [void]$parts.Add("$Line")
    }
    [void]$parts.Add((& $quote $Path))
    $argStr = [string]::Join(' ', $parts)
    try {
        Start-Process -FilePath $exe -ArgumentList $argStr | Out-Null
        return $true
    } catch {
        try {
            [System.Windows.Forms.MessageBox]::Show(
                "Could not start TypoZen:`n$exe`n`n$($_.Exception.Message)",
                "TypoZen launch failed", 0, 'Error') | Out-Null
        } catch {}
        return $false
    }
}

function Show-Reader($directFilePath = $null) {
    $p = if ($directFilePath) { $directFilePath } else { if (-not $lstResults.SelectedItem) { return }; $lstResults.SelectedItem.FullPath }
    if ([string]::IsNullOrWhiteSpace($p) -or -Not (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue)) { return }
    
    $initIndex = 0
    if (-not $directFilePath -and $null -ne $lstResults.SelectedItem -and $lstResults.SelectedItem.FullPath -eq $p) {
        $initIndex = $script:inlineCurrentIndex
    }

    $str = $cmbStr.Text
    $lineHint = -1
    if ($script:inlineMatchIndices -and $script:inlineMatchIndices.Count -gt 0) {
        if ($initIndex -ge 0 -and $initIndex -lt $script:inlineMatchIndices.Count) {
            $lineHint = [int]$script:inlineMatchIndices[$initIndex]
        }
    }

    # Prefer TypoZen for markdown / text / epub (Reader mode + jump + highlight).
    if (Global:Open-InTypoZen -Path $p -Search $str -MatchIndex $initIndex -Line $lineHint) {
        return
    }

    if (-not $global:webViewReady) { 
        [System.Windows.Forms.MessageBox]::Show("WebView2 wrapper DLLs could not be loaded.`n`nError: $($global:webViewError)`n`nPlease close the app, delete the DLLs in the folder, and restart.`n`nOr place TypoZen.exe next to this folder for external reading.", "Missing Dependencies", 0, 'Error') | Out-Null
        return 
    }

    $lines = @()
    $ext = [System.IO.Path]::GetExtension($p)
    $epubTemp = $null
    $extractionErrorLog = $null
    
    if ($ext -match "(?i)\.epub$") {
        $epubTemp = Join-Path $appDataDir "EpubTemp_$([guid]::NewGuid().ToString().Substring(0,8))"
        try { $lines = [FastSearcher]::GetReaderLines($p, $epubTemp) } catch { $extractionErrorLog = "Exception: $($_.Exception.Message)" }
        if (-not $lines -or $lines.Count -eq 0) { $lines = @("Error: Could not extract book content.") }
    } elseif ($ext -match "(?i)\.(docx|xlsx)$") {
        try { $lines = [FastSearcher]::GetFileLines($p) } catch { $lines = @("Error reading DOCX/XLSX.") }
    } else { 
        try { $lines = [System.IO.File]::ReadAllLines($p, [System.Text.Encoding]::UTF8) } catch { $lines = @("Error reading file.") } 
    }
    
    if (-not $lines) { return }

    $str = $cmbStr.Text
    $matchIndicesArr = @()
    if (-not [string]::IsNullOrWhiteSpace($str)) { 
        $rx = [FastSearcher]::GetSearchRegex($str, [bool]$chkRegex.IsChecked, [bool]$chkWholeWordMain.IsChecked, [bool]$chkCaseMain.IsChecked)
        $matchIndicesArr = [FastSearcher]::GetMatchIndices($lines, $rx)
    }
    if ($matchIndicesArr.Length -eq 0) { $matchIndicesArr = @(0) }
    if ($initIndex -ge $matchIndicesArr.Length) { $initIndex = 0 }
    
    $rForm = New-Object System.Windows.Forms.Form -Property @{ Text="ZenSeek - $([System.IO.Path]::GetFileName($p))"; Size=New-Object System.Drawing.Size([math]::Max(1020,$script:rW),$script:rH); MinimumSize="1020,550"; FormBorderStyle='Sizable'; MaximizeBox=$true; AutoScaleMode='Dpi'; KeyPreview=$true }
    
    $rForm.Tag = [Ordered]@{ p=$p; epubTemp=$epubTemp; str=$str; lines=$lines; matchIndices=$matchIndicesArr; index=$initIndex; initializing=$true; viewMode="Full"; currentVisibleLine=-1; searchTimer=$null; readerPath=$null; lastContentKey=""; contentLoaded=$false; lastScrollLine=-1; ignoreCmb=$false }

    # [NEW] EPUB Position Restore
    $initLine = -1
    if ($ext -match "(?i)\.epub$" -and $global:epubPositions.Contains($p) -and [string]::IsNullOrWhiteSpace($str)) {
        $initLine = [int]$global:epubPositions[$p]
        $rForm.Tag.currentVisibleLine = $initLine
        $rForm.Tag.lastScrollLine = $initLine
    }

    # 1. The Main HUD Panel
    $pnlMenu = New-Object System.Windows.Forms.Panel -Property @{ 
        Name="pnlMenu"; Dock='None'; Width=$rForm.ClientSize.Width; 
        Height=45; Top=0; Left=0; Anchor='Top, Left, Right';
        BackColor=[System.Drawing.ColorTranslator]::FromHtml("#1E293B"); Visible=$false 
    }

    # 2. The Settings Drop-down Panel 
    $pnlSettings = New-Object System.Windows.Forms.Panel -Property @{
        Name="pnlSettings"; Dock='None'; Width=$rForm.ClientSize.Width; Height=45;
        Top=45; Left=0; Anchor='Top, Left, Right';
        BackColor=[System.Drawing.ColorTranslator]::FromHtml("#1E293B");
        Visible=$false
    }
    
    $rForm.Controls.Add($pnlSettings)
    $rForm.Controls.Add($pnlMenu)

    # --- Zone 1 & 2: Core Action & Navigation ---
    $lblSearchReader = New-Ctrl Label @{Location='10,15'; Size='50,20'; Text="&Search:"} $pnlMenu
    $cmbReaderStr = New-Ctrl ComboBox @{Name="cmbReaderStr"; Location='62,12'; Size='180,23'; Text=$str} $pnlMenu
    $global:dRecentSearches | ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) { [void]$cmbReaderStr.Items.Add($_) } }
    $chkWholeWordReader = New-Ctrl CheckBox @{Name="chkWholeWordReader"; Location='247,11'; Size='30,25'; Text='""'; Appearance='Button'; FlatStyle='Flat'; TextAlign='MiddleCenter'; Checked=[bool]$chkWholeWordMain.IsChecked} $pnlMenu
    $chkCaseReader = New-Ctrl CheckBox @{Name="chkCaseReader"; Location='279,11'; Size='30,25'; Text="Aa"; Appearance='Button'; FlatStyle='Flat'; TextAlign='MiddleCenter'; Checked=[bool]$chkCaseMain.IsChecked} $pnlMenu
    $chkRegexReader = New-Ctrl CheckBox @{Name="chkRegexReader"; Location='311,11'; Size='30,25'; Text=".*"; Appearance='Button'; FlatStyle='Flat'; TextAlign='MiddleCenter'; Checked=[bool]$chkRegex.IsChecked} $pnlMenu
    
    $btnPrevMatch = New-Ctrl Button @{Name="btnPrevMatch"; Location='380,11'; Size='30,25'; Text="<"} $pnlMenu
    $btnNextMatch = New-Ctrl Button @{Name="btnNextMatch"; Location='412,11'; Size='30,25'; Text=">"} $pnlMenu
    
    # [NEW] ComboBox Match List UI - WIDENED
    $cmbMatchList = New-Ctrl ComboBox @{Name="cmbMatchList"; Location='449,12'; Size='400,23'; DropDownStyle='DropDownList'} $pnlMenu
    
    # Initialize list on load if search exists
    if (-not [string]::IsNullOrWhiteSpace($str) -and $matchIndicesArr.Length -gt 0) {
        foreach ($idx in $matchIndicesArr) {
            $snip = $lines[$idx].Trim() -replace '<[^>]+>',''
            if ($snip.Length -gt 85) { $snip = $snip.Substring(0, 85) + "..." }
            [void]$cmbMatchList.Items.Add("Line $($idx + 1): $snip")
        }
        if ($initIndex -lt $cmbMatchList.Items.Count) { $cmbMatchList.SelectedIndex = $initIndex }
    }

    # --- Zone 3: Secondary Actions - SHIFTED RIGHT ---
    $btnToggleView = New-Ctrl Button @{Name="btnToggleView"; Location='860,11'; Size='75,25'; Text="Full Doc"} $pnlMenu
    $numContext = New-Ctrl NumericUpDown @{Name="numContext"; Location='940,12'; Size='45,23'; Minimum=0; Maximum=100; Value=$script:rContext; Enabled=$false} $pnlMenu
    
    $initColText = $(if ($script:rW -gt 1500) { "2 Columns" } else { "1 Column" })
    $btnColToggle = New-Ctrl Button @{Name="btnColToggle"; Location='995,11'; Size='80,25'; Text=$initColText} $pnlMenu

    $btnSettings = New-Ctrl Button @{Name="btnSettings"; Location='1090,11'; Size='35,25'; Text=[string][char]0x2699} $pnlMenu
    $btnSettings.Font = New-Object System.Drawing.Font("Segoe UI", 12)

    # --- Zone 4: Settings ---
    New-Ctrl Label @{Location='10,15'; Size='48,20'; Text="Theme:"} $pnlSettings | Out-Null
    $cmbTheme = New-Ctrl ComboBox @{Name="cmbTheme"; Location='60,12'; Size='130,23'; DropDownStyle='DropDownList'} $pnlSettings
    $script:themes | ForEach-Object { [void]$cmbTheme.Items.Add($_.Name) }
    $cmbTheme.SelectedIndex = $script:activeTheme
    
    New-Ctrl Label @{Location='200,15'; Size='35,20'; Text="Font:"} $pnlSettings | Out-Null
    $cmbFont = New-Ctrl ComboBox @{Name="cmbFont"; Location='235,12'; Size='120,23'; DropDownStyle='DropDownList'} $pnlSettings
    [System.Drawing.FontFamily]::Families | ForEach-Object { [void]$cmbFont.Items.Add($_.Name) }
    
    $numFont = New-Ctrl NumericUpDown @{Name="numFont"; Location='360,12'; Size='45,23'; Minimum=6; Maximum=36} $pnlSettings
    
    $btnBgColor = New-Ctrl Button @{Name="btnBgColor"; Location='415,11'; Size='30,25'; Text=[string][char]0x25A0} $pnlSettings
    $btnTxColor = New-Ctrl Button @{Name="btnTxColor"; Location='447,11'; Size='30,25'; Text="A"} $pnlSettings
    $btnHiColor = New-Ctrl Button @{Name="btnHiColor"; Location='479,11'; Size='30,25'; Text=[string][char]0x270E} $pnlSettings
    $btnReset = New-Ctrl Button @{Name="btnReset"; Location='511,11'; Size='30,25'; Text=[string][char]0x21BA} $pnlSettings

    New-Ctrl Label @{Location='570,15'; Size='35,20'; Text="Line:"} $pnlSettings | Out-Null
    $cmbLineSp = New-Ctrl ComboBox @{Name="cmbLine"; Location='605,12'; Size='50,23'; DropDownStyle='DropDownList'} $pnlSettings
    @("1.2", "1.4", "1.6", "1.8", "2.0") | ForEach-Object { [void]$cmbLineSp.Items.Add($_) }
    $cmbLineSp.Text = $script:rLineSp

    $btnMargin = New-Ctrl Button @{Name="btnMargin"; Location='665,11'; Size='65,25'; Text=$script:rMargin} $pnlSettings
    
    $initAlignTxt = $(if ($script:rAlign) { "Justified" } else { "Left" })
    $chkAlign = New-Ctrl CheckBox @{Name="chkAlign"; Location='735,11'; Size='75,25'; Text=$initAlignTxt; Appearance='Button'; FlatStyle='Flat'; TextAlign='MiddleCenter'; Checked=$script:rAlign} $pnlSettings

    $chkSmartQuotesReader = New-Ctrl CheckBox @{Name="chkSmartQuotesReader"; Location='825,14'; Size='115,20'; Text="Smart Quotes"; Checked=$script:rSmartQuotes} $pnlSettings
    
    $btnOpenFile = New-Ctrl Button @{Name="btnOpenFile"; Location='980,11'; Size='55,25'; Text="Open"} $pnlSettings
    $btnOpenWith = New-Ctrl Button @{Name="btnOpenWith"; Location='1040,11'; Size='85,25'; Text="Open With"} $pnlSettings

    # --- Settings Toggles ---
    $btnSettings.Add_Click({
        $frm = $this.FindForm()
        if ($frm) {
            $s = $frm.Controls["pnlSettings"]
            if ($s) {
                $s.Visible = -not $s.Visible
                if ($s.Visible) { $s.BringToFront() }
            }
        }
    })

    $rToolTip = New-Object System.Windows.Forms.ToolTip
    $rToolTip.SetToolTip($cmbReaderStr, "Search (Alt+S)")
    $rToolTip.SetToolTip($chkWholeWordReader, "Match Whole Word")
    $rToolTip.SetToolTip($chkCaseReader, "Match Case")
    $rToolTip.SetToolTip($chkRegexReader, "Use Regular Expressions")
    $rToolTip.SetToolTip($btnPrevMatch, "Previous Match")
    $rToolTip.SetToolTip($btnNextMatch, "Next Match")
    $rToolTip.SetToolTip($cmbMatchList, "Match Results & Jump List")
    $rToolTip.SetToolTip($btnToggleView, "Toggle document view mode (Full, Context, or Scroll)")
    $rToolTip.SetToolTip($numContext, "Number of context lines to display")
    $rToolTip.SetToolTip($chkAlign, "Toggle Left Alignment or Native Hyphenated Justification")
    $rToolTip.SetToolTip($cmbLineSp, "Adjust line height / spacing")
    $rToolTip.SetToolTip($btnMargin, "Toggle page margins (Narrow, Normal, Wide)")
    $rToolTip.SetToolTip($chkSmartQuotesReader, "Convert straight quotes to curly/smart quotes")
    $rToolTip.SetToolTip($btnOpenFile, "Open original file in default application")
    $rToolTip.SetToolTip($btnOpenWith, "Choose application to open file")
    $rToolTip.SetToolTip($btnBgColor, "Set Background Colour")
    $rToolTip.SetToolTip($btnTxColor, "Set Text Colour")
    $rToolTip.SetToolTip($btnHiColor, "Set Highlight Colour")
    $rToolTip.SetToolTip($btnReset, "Reload Themes and Revert to Default Spacing")
    $rToolTip.SetToolTip($btnColToggle, "Toggle 1 or 2 column layout")

    &$script:applyThemeToReaderForm $rForm $script:themes[$script:activeTheme]
 
    $txtReaderViewer = New-Object Microsoft.Web.WebView2.WinForms.WebView2
    $txtReaderViewer.Name = "txtReaderViewer"
    $txtReaderViewer.Dock = [System.Windows.Forms.DockStyle]::Fill
    $rForm.Controls.Add($txtReaderViewer)
    
    $txtReaderViewer.SendToBack()
    if ($rForm.Controls["pnlSettings"]) { $rForm.Controls["pnlSettings"].BringToFront() }
    if ($rForm.Controls["pnlMenu"]) { $rForm.Controls["pnlMenu"].BringToFront() }
    
    $userDataFolder = Join-Path $appDataDir "TextSearch_WebView2_$([guid]::NewGuid().ToString().Substring(0,8))"
    $readerTempDir = Join-Path $appDataDir "TextSearch_Reader"
    if (-not (Test-Path -LiteralPath $readerTempDir -ErrorAction SilentlyContinue)) { New-Item -ItemType Directory -Path $readerTempDir | Out-Null }
    
    # localapp/readerapp are virtual hosts served from disk by SetVirtualHostNameToFolderMapping,
    # not real names - but Chromium still resolves them as hostnames on every navigation. Where
    # DNS is remote (a VPN, say) that NXDOMAIN round trip costs ~2s PER DOCUMENT OPEN before the
    # mapping is consulted. Pinning them to loopback skips the lookup entirely.
    # Measured: navigation 2,063ms -> 61ms. Nothing else is affected; only these names are mapped.
    # Note: all four constructor arguments must be passed explicitly - PowerShell will not bind
    # a constructor whose parameters are optional.
    # The second group switches off Chromium background services (component updates, Safe
    # Browsing list refreshes, sync) that the browser process would otherwise run on startup
    # even though this app requests no URLs. Page loads are unaffected - a document that
    # references a remote image still fetches it.
    # Not fully silent: the WebView2 browser process still holds two TLS connections to
    # Microsoft-owned addresses from startup, with no page having requested anything. Several
    # flag combinations were tried and none removed them, and the endpoint is not identified
    # (absent from the Windows DNS cache and from --log-net-log output). That is runtime
    # traffic, not this app's - the page issues no requests. Stopping it needs a firewall rule
    # on msedgewebview2.exe or machine-level Edge policy, both outside this script.
    $wvArgs = '--host-resolver-rules="MAP localapp 127.0.0.1, MAP readerapp 127.0.0.1"' +
              ' --disable-background-networking --disable-component-update --disable-sync' +
              ' --no-first-run --no-default-browser-check'
    $wvOpts = New-Object Microsoft.Web.WebView2.Core.CoreWebView2EnvironmentOptions($wvArgs, $null, $null, $false)
    $envTask = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::CreateAsync($null, $userDataFolder, $wvOpts)
    
    while (-not $envTask.IsCompleted) {
        $frame = New-Object System.Windows.Threading.DispatcherFrame
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [System.Action] { $frame.Continue = $false }) | Out-Null
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
        Start-Sleep -Milliseconds 10
    }
    if ($envTask.IsFaulted) { $rForm.Close(); return }
    
    $initTask = $txtReaderViewer.EnsureCoreWebView2Async($envTask.Result)
    
    while (-not $initTask.IsCompleted) {
        $frame = New-Object System.Windows.Threading.DispatcherFrame
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [System.Action] { $frame.Continue = $false }) | Out-Null
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
        Start-Sleep -Milliseconds 10
    }
    if ($initTask.IsFaulted) { $rForm.Close(); return }

    try { 
        $txtReaderViewer.CoreWebView2.SetVirtualHostNameToFolderMapping("readerapp", $readerTempDir, 2)
        if (-not [string]::IsNullOrWhiteSpace($epubTemp) -and (Test-Path -LiteralPath $epubTemp -ErrorAction SilentlyContinue)) { $txtReaderViewer.CoreWebView2.SetVirtualHostNameToFolderMapping("localapp", $epubTemp, 2) } 
        else { $txtReaderViewer.CoreWebView2.SetVirtualHostNameToFolderMapping("localapp", [System.IO.Path]::GetDirectoryName($p), 2) } 
        
        $txtReaderViewer.add_WebMessageReceived({
            param($sender, $e)
            try { 
                $frm = $sender.FindForm()
                if (-not $frm -or $frm.IsDisposed) { return }
                $msg = $e.TryGetWebMessageAsString().Trim('"')
                $pMenu = $frm.Controls["pnlMenu"]
                $pSettings = $frm.Controls["pnlSettings"]

                # [NEW] Intercept scroll position reports
                if ($msg -match '^pos:(\d+)$') {
                    $frm.Tag.lastScrollLine = [int]$matches[1]
                }
                # --- 1. THE COMPACT TIMER ---
                elseif (-not $frm.Tag.hideTimer) {
                    $ht = New-Object System.Windows.Forms.Timer -Property @{ Interval = 3000 }
                    $ht.Tag = $frm
                    $ht.Add_Tick({
                        $f = $this.Tag
                        if (-not $f -or $f.IsDisposed) { $this.Stop(); return }
                        
                        $m = $f.Controls["pnlMenu"]
                        $s = $f.Controls["pnlSettings"]
                        $mousePos = [System.Windows.Forms.Cursor]::Position
                        
                        if ($m -and $m.Visible -and ($m.RectangleToScreen($m.ClientRectangle).Contains($mousePos) -or $m.ContainsFocus)) { return }
                        if ($s -and $s.Visible -and ($s.RectangleToScreen($s.ClientRectangle).Contains($mousePos) -or $s.ContainsFocus)) { return }
                        
                        if ($m) { $m.Visible = $false }
                        if ($s) { $s.Visible = $false }
                        $this.Stop()
                    })
                    $frm.Tag["hideTimer"] = $ht
                }

                if ($msg -eq 'focusSearch') { 
                    if ($pMenu) { 
                        $pMenu.Visible = $true
                        $pMenu.BringToFront()
                    }
                    $pMenu.Controls["cmbReaderStr"].Focus()
                    $pMenu.Controls["cmbReaderStr"].SelectAll() 
                    $frm.Tag.hideTimer.Stop(); $frm.Tag.hideTimer.Start()
                } 
                elseif ($msg -eq 'prevMatch') { if ($frm.Tag.navMatch) { $frm.Tag.navMatch.Invoke($frm, -1) } } 
                elseif ($msg -eq 'nextMatch') { if ($frm.Tag.navMatch) { $frm.Tag.navMatch.Invoke($frm, 1) } } 
                elseif ($msg -eq 'close') { $frm.Close() }
                elseif ($msg -eq 'toggleMenu') { 
                    if ($pMenu) { 
                        $pMenu.Visible = -not $pMenu.Visible
                        if ($pMenu.Visible) { 
                            $pMenu.BringToFront() 
                            $frm.Tag.hideTimer.Stop(); $frm.Tag.hideTimer.Start()
                        }
                        if (-not $pMenu.Visible -and $pSettings) { 
                            $pSettings.Visible = $false 
                            $frm.Tag.hideTimer.Stop()
                        }
                    }
                }
            } catch {}
        })
    } catch {}

    $updateViewer = {
        param($frm)
        if (-not $frm -or -not $frm.Tag -or $frm.Tag.initializing) { return }
        $pMenu = $frm.Controls["pnlMenu"]
        $pSettings = $frm.Controls["pnlSettings"]
        $cmbTheme = $pSettings.Controls["cmbTheme"]
        $numContext = $pMenu.Controls["numContext"]
        $txtReaderViewer = $frm.Controls["txtReaderViewer"]
        $cmbMatch = $pMenu.Controls["cmbMatchList"]
    
        if (-not $cmbTheme -or -not $txtReaderViewer -or -not $txtReaderViewer.CoreWebView2) { return }
        
        $idx = $cmbTheme.SelectedIndex
        if ($idx -lt 0 -or $idx -ge $script:themes.Count) { return }
        $t = $script:themes[$idx]
        $cLines = [int]$numContext.Value
    
        $readerTempDir = Join-Path $appDataDir "TextSearch_Reader"
        
        # With no search term matchIndices holds the sentinel @(0), which is "start at the
        # top", not "line 0 is a match" - shading it highlights the first line for nothing.
        $hasSearch = -not [string]::IsNullOrWhiteSpace($frm.Tag.str)
        $activeMatchLine = -1
        if ($hasSearch -and $frm.Tag.matchIndices.Count -gt 0) { $activeMatchLine = $frm.Tag.matchIndices[$frm.Tag.index] }
        $targetLine = 0
        if ($activeMatchLine -ge 0) { $targetLine = $activeMatchLine }
        
        $isRestoringPosition = $false
        $useSmartQuotes = $pSettings.Controls["chkSmartQuotesReader"].Checked
        if ($frm.Tag.currentVisibleLine -ge 0) { 
            $targetLine = $frm.Tag.currentVisibleLine
            $frm.Tag.currentVisibleLine = -1
            $isRestoringPosition = $true 
        }
        $isMatchJS = "true"
        if ($isRestoringPosition -or -not $hasSearch) { $isMatchJS = "false" }
        
        $selFont = $t.FN
        if ($pSettings.Controls["cmbFont"].SelectedItem) { $selFont = $pSettings.Controls["cmbFont"].SelectedItem.ToString() }
        $fSize = $pSettings.Controls["numFont"].Value
        
        $lineSp = $pSettings.Controls["cmbLine"].Text
        if ([string]::IsNullOrWhiteSpace($lineSp)) { $lineSp = "1.6" }
        
        $isJustified = $pSettings.Controls["chkAlign"].Checked
        $textAlign = if ($isJustified) { "justify" } else { "left" }
        $hyphenRules = if ($isJustified) { "hyphens: auto; -webkit-hyphens: auto;" } else { "hyphens: none; -webkit-hyphens: none;" }
        
        $marginTxt = $pSettings.Controls["btnMargin"].Text
        $marginPx = "15px"
        if ($marginTxt -eq "Wide") { $marginPx = "80px" } elseif ($marginTxt -eq "Normal") { $marginPx = "40px" }

        $viewLayoutCss = ""
        $responsiveCss = ""
        $paddingCss = ""
        $jsBlock = ""
        
        # [NEW] Injected Debounced Position Tracking JS
        if ($frm.Tag.viewMode -eq "Full" -or $frm.Tag.viewMode -eq "Scroll") { 
            $frm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            $startLine = 0
            $endLine = $frm.Tag.lines.Count - 1 
          
            $viewLayoutCss = "margin: 0; padding: 0; height: 100vh; overflow-y: hidden; overflow-x: auto; column-fill: auto;"
           $responsiveCss = "body { column-count: 1 !important; column-gap: 0 !important; } @media (min-width: 1500px) { body { column-count: 2 !important; } }"
            $paddingCss = "body > * { box-sizing: border-box; } @media (max-width: 1499px) { body > * { padding-left: max($marginPx, calc((100vw - 850px) / 2)); padding-right: max($marginPx, calc((100vw - 850px) / 2)); } } @media (min-width: 1500px) { body > * { padding-left: max($marginPx, calc((100vw - 1700px) / 4)); padding-right: max($marginPx, calc((100vw - 1700px) / 4)); } }"
         $jsBlock = "<script>var resizeTimer; var isAutoScrolling = false; var scrollTimer; function getPageWidth() { var cols = window.innerWidth >= 1500 ? 2 : 1; return Math.floor(window.innerWidth / cols) * cols; } function applyEvenWidth() { document.body.style.width = getPageWidth() + 'px'; } function reportPosition() { var els = document.querySelectorAll('[id^=`"line-`"]'); var best = -1; var minTop = 999999; for(var i=0; i<els.length; i++){ var r = els[i].getBoundingClientRect(); if (r.width === 0 && r.height === 0) continue; if (r.right > 0 && r.bottom > 0 && r.left < window.innerWidth && r.top < window.innerHeight){ if (r.top >= 0 && r.top < minTop){ minTop = r.top; best = els[i].id.split('-')[1]; } } } if (best !== -1) window.chrome.webview.postMessage('pos:' + best); } function getMaxPage() { var pw = getPageWidth(); return Math.max(0, Math.ceil((document.body.scrollWidth - pw) / pw)); } function snapToPage(page) { isAutoScrolling = true; var pw = getPageWidth(); var targetScroll = page * pw; window.scrollTo({ left: targetScroll, top: 0, behavior: 'auto' }); setTimeout(function() { isAutoScrolling = false; reportPosition(); }, 250); } function scrollToLine(lineId, isMatch) { if(isMatch) { document.querySelectorAll('.active-line').forEach(function(e) { e.classList.remove('active-line'); }); } var el = document.getElementById('line-' + lineId); if (el) { if(isMatch) el.classList.add('active-line'); var absoluteLeft = el.getBoundingClientRect().left + window.scrollX; var pw = getPageWidth(); var page = Math.floor(absoluteLeft / pw); snapToPage(page); } } window.onload = function() { applyEvenWidth(); if ($targetLine >= 0) { setTimeout(function() { scrollToLine($targetLine, $isMatchJS); }, 150); } }; window.addEventListener('resize', function() { applyEvenWidth(); clearTimeout(resizeTimer); resizeTimer = setTimeout(function() { var pw = getPageWidth(); var page = Math.round(window.scrollX / pw); snapToPage(Math.min(page, getMaxPage())); }, 100); }); function turnPage(dir) { var pw = getPageWidth(); var currentPage = Math.round(window.scrollX / pw); var maxPage = getMaxPage(); var targetPage = Math.max(0, Math.min(currentPage + dir, maxPage)); snapToPage(targetPage); } window.addEventListener('wheel', function(e) { if (e.deltaY !== 0) { e.preventDefault(); turnPage(e.deltaY > 0 ? 1 : -1); } }, { passive: false }); window.addEventListener('scroll', function() { if(!isAutoScrolling) { clearTimeout(scrollTimer); scrollTimer = setTimeout(reportPosition, 500); } }); window.addEventListener('keydown', function(e) { if (e.altKey && (e.key === 's' || e.key === 'S')) { e.preventDefault(); window.chrome.webview.postMessage('focusSearch'); return; } if (e.key === 'Escape') { e.preventDefault(); window.chrome.webview.postMessage('close'); return; } if (e.key === ',' || e.key === '<') { e.preventDefault(); window.chrome.webview.postMessage('prevMatch'); return; } if (e.key === '.' || e.key === '>') { e.preventDefault(); window.chrome.webview.postMessage('nextMatch'); return; } if (e.key === 'ArrowDown' || e.key === 'PageDown' || e.key === 'ArrowRight') { e.preventDefault(); turnPage(1); } else if (e.key === 'ArrowUp' || e.key === 'PageUp' || e.key === 'ArrowLeft') { e.preventDefault(); turnPage(-1); } }); window.addEventListener('click', function(e) { if (e.button === 0 && window.getSelection().toString().length === 0 && e.target.tagName.toLowerCase() !== 'a') { window.chrome.webview.postMessage('toggleMenu'); } });</script>"
        } else {
            $bounds = Global:Get-SmartContextBounds $frm.Tag.lines $targetLine $cLines
            $startLine = $bounds[0]
            $endLine = $bounds[1]
            $scrollOffset = -95
            
            if ($frm.Tag.viewMode -eq "Scroll") { $scrollOffset = -125 }

            $isTbl = { param($linesArr, $lineIdx) if ($lineIdx -lt 0 -or $lineIdx -ge $linesArr.Count) { return $false }; $vEsc = [regex]::Escape([char]0x2502); return ($linesArr[$lineIdx] -match "^[ \t]*[|$vEsc].*[|$vEsc][ \t]*$") }
            if (&$isTbl $frm.Tag.lines $startLine) { while ($startLine -gt 0 -and (&$isTbl $frm.Tag.lines ($startLine - 1))) { $startLine-- } }
            if (&$isTbl $frm.Tag.lines $endLine) { while ($endLine -lt ($frm.Tag.lines.Count - 1) -and (&$isTbl $frm.Tag.lines ($endLine + 1))) { $endLine++ } }
            
            $viewLayoutCss = "margin: 15px $marginPx; padding: 0; overflow-y: auto; overflow-x: hidden;"
            $jsBlock = "<script>var scrollTimer; function reportPosition() { var els = document.querySelectorAll('[id^=`"line-`"]'); var best = -1; var minTop = 999999; for(var i=0; i<els.length; i++){ var r = els[i].getBoundingClientRect(); if (r.width === 0 && r.height === 0) continue; if (r.right > 0 && r.bottom > 0 && r.left < window.innerWidth && r.top < window.innerHeight){ if (r.top >= 0 && r.top < minTop){ minTop = r.top; best = els[i].id.split('-')[1]; } } } if (best !== -1) window.chrome.webview.postMessage('pos:' + best); } function scrollToLine(lineId, isMatch) { if(isMatch) { document.querySelectorAll('.active-line').forEach(function(e) { e.classList.remove('active-line'); }); } var el = document.getElementById('line-' + lineId); if (el) { if(isMatch) el.classList.add('active-line'); el.scrollIntoView(); if(isMatch) window.scrollBy(0, $scrollOffset); } } window.onload = function() { if ($targetLine >= 0) { setTimeout(function() { scrollToLine($targetLine, $isMatchJS); reportPosition(); }, 150); } }; window.addEventListener('scroll', function() { clearTimeout(scrollTimer); scrollTimer = setTimeout(reportPosition, 500); }); window.addEventListener('keydown', function(e) { if (e.altKey && (e.key === 's' || e.key === 'S')) { e.preventDefault(); window.chrome.webview.postMessage('focusSearch'); return; } if (e.key === 'Escape') { e.preventDefault(); window.chrome.webview.postMessage('close'); return; } if (e.key === ',' || e.key === '<') { e.preventDefault(); window.chrome.webview.postMessage('prevMatch'); return; } if (e.key === '.' || e.key === '>') { e.preventDefault(); window.chrome.webview.postMessage('nextMatch'); return; } }); window.addEventListener('click', function(e) { if (e.button === 0 && window.getSelection().toString().length === 0 && e.target.tagName.toLowerCase() !== 'a') { window.chrome.webview.postMessage('toggleMenu'); } });</script>"
        }

        $fullDynamicCss = "body { background-color: $($t.Bg); color: $($t.Tx); font-family: '$selFont', Consolas, monospace; font-size: $($fSize)pt; line-height: $lineSp; text-align: $textAlign; $hyphenRules $viewLayoutCss } th, td { border-color: $($t.Tx); } th { background-color: $($t.Hi); color: $($t.Bg); } mark { background-color: $($t.Hi); color: $($t.Bg); } .code-line { color: $($t.Tx); } $responsiveCss $paddingCss"

        $cacheTarget = -1
        if ($frm.Tag.viewMode -eq "Context") { $cacheTarget = $targetLine }
        
        $contentCacheKey = "$($frm.Tag.viewMode)|$($frm.Tag.str)|$useSmartQuotes|$($pMenu.Controls['chkRegexReader'].Checked)|$($pMenu.Controls['chkWholeWordReader'].Checked)|$($pMenu.Controls['chkCaseReader'].Checked)|$cLines|$cacheTarget"
        
         if ($frm.Tag.lastContentKey -eq $contentCacheKey -and $frm.Tag.contentLoaded) { 
            $jsInject = "var s = document.getElementById('dynamic-theme'); if(!s) { s = document.createElement('style'); s.id = 'dynamic-theme'; document.head.appendChild(s); } s.innerHTML = `"$fullDynamicCss`"; setTimeout(function() { if(typeof scrollToLine === 'function') scrollToLine($targetLine, $isMatchJS); }, 100);"
            $txtReaderViewer.ExecuteScriptAsync($jsInject) | Out-Null
            $frm.Cursor = [System.Windows.Forms.Cursors]::Default
            return 
        }
        $frm.Tag.lastContentKey = $contentCacheKey
        $frm.Tag.contentLoaded = $true
        
        if ($frm.Tag.Contains("htmlCache") -and $frm.Tag.htmlCache.Contains($contentCacheKey)) { 
            $bodyHtml = $frm.Tag.htmlCache[$contentCacheKey] 
        } else {
            $bodyHtml = [FastSearcher]::GenerateHtml($frm.Tag.lines, $frm.Tag.str, [bool]$pMenu.Controls["chkRegexReader"].Checked, [bool]$pMenu.Controls["chkWholeWordReader"].Checked, [bool]$pMenu.Controls["chkCaseReader"].Checked, $activeMatchLine, $useSmartQuotes, $startLine, $endLine)
            if (-not $frm.Tag.Contains("htmlCache")) { $frm.Tag["htmlCache"] = @{} }
            $frm.Tag.htmlCache[$contentCacheKey] = $bodyHtml
        }
        
        $html = $global:htmlTemplate.Replace("{{DYNAMIC_CSS}}", $fullDynamicCss).Replace("{{PAGE_CSS}}", "").Replace("{{RESPONSIVE_CSS}}", "").Replace("{{PADDING_CSS}}", "").Replace("{{JS_BLOCK}}", $jsBlock).Replace("{{BODY_HTML}}", $bodyHtml)
        
        if ($html.Length -lt 1000000) { 
            $txtReaderViewer.CoreWebView2.NavigateToString($html) 
        } else {
            $readerFile = "reader_$([System.Guid]::NewGuid().ToString().Substring(0,8)).html"
            $readerPath = Join-Path $readerTempDir $readerFile
            [System.IO.File]::WriteAllText($readerPath, $html, [System.Text.Encoding]::UTF8)
            if (-not [string]::IsNullOrWhiteSpace($frm.Tag.readerPath) -and (Test-Path -LiteralPath $frm.Tag.readerPath -ErrorAction SilentlyContinue)) { try { Remove-Item $frm.Tag.readerPath -Force -ErrorAction SilentlyContinue } catch {} }
            $frm.Tag.readerPath = $readerPath
            $txtReaderViewer.CoreWebView2.Navigate("https://readerapp/$readerFile")
        }
        
        if ([string]::IsNullOrWhiteSpace($frm.Tag.str)) { 
            $frm.Tag.ignoreCmb = $true
            if ($cmbMatch) { $cmbMatch.Items.Clear(); [void]$cmbMatch.Items.Add("Total lines: $($frm.Tag.lines.Count)"); $cmbMatch.SelectedIndex = 0 }
            $frm.Tag.ignoreCmb = $false
        }
        $frm.Cursor = [System.Windows.Forms.Cursors]::Default
    }
    $rForm.Tag["updateViewer"] = $updateViewer

    # [NEW] Enhanced applySearch to populate ComboBox
    $applySearch = { 
        param($frm, $isManualTrigger) 
        if (-not $frm -or -not $frm.Tag -or $frm.Tag.initializing) { return }
        $nStr = $frm.Controls["pnlMenu"].Controls["cmbReaderStr"].Text 
        $pMenu = $frm.Controls["pnlMenu"]
        $cmbMatch = $pMenu.Controls["cmbMatchList"]
        
        if ([string]::IsNullOrWhiteSpace($nStr)) { 
            $frm.Tag.str = ""
            $frm.Tag.matchIndices = @(0)
            $frm.Tag.index = 0
            $frm.Tag.currentVisibleLine = -1
            $frm.Tag.updateViewer.Invoke($frm)
            $frm.Controls["txtReaderViewer"].Focus()
            return 
        }
        
        $rx = [FastSearcher]::GetSearchRegex($nStr, [bool]$pMenu.Controls["chkRegexReader"].Checked, [bool]$pMenu.Controls["chkWholeWordReader"].Checked, [bool]$pMenu.Controls["chkCaseReader"].Checked)
        
        if ($null -eq $rx) {
            if ($isManualTrigger) { [System.Windows.Forms.MessageBox]::Show("Invalid Regex.", "Regex Error", 0, 16) | Out-Null }
            return 
        }

        $nMatchArr = [FastSearcher]::GetMatchIndices($frm.Tag.lines, $rx)
        
        if ($nMatchArr.Length -eq 0) { 
            if ($isManualTrigger) { [System.Windows.Forms.MessageBox]::Show("No matches found.", "Reader Search", 0, 'Information') | Out-Null }
            return 
        }
        if ($isManualTrigger) { $global:dRecentSearches = Global:Update-HistoryList $global:dRecentSearches $nStr 10 }
        
        $frm.Tag.str = $nStr
        $frm.Tag.matchIndices = $nMatchArr
        $frm.Tag.index = 0
        $frm.Tag.currentVisibleLine = -1

        $frm.Tag.ignoreCmb = $true
        if ($cmbMatch) {
            $cmbMatch.Items.Clear()
            foreach ($idx in $nMatchArr) {
                $snip = $frm.Tag.lines[$idx].Trim() -replace '<[^>]+>',''
                if ($snip.Length -gt 85) { $snip = $snip.Substring(0, 85) + "..." }
                [void]$cmbMatch.Items.Add("Line $($idx + 1): $snip")
            }
            $cmbMatch.SelectedIndex = 0
        }
        $frm.Tag.ignoreCmb = $false

        $frm.Tag.updateViewer.Invoke($frm)
        $frm.Controls["txtReaderViewer"].Focus() 
    }
    $rForm.Tag["applySearch"] = $applySearch

    # [NEW] Sync navMatch with ComboBox
    $navMatch = { 
        param($frm, $dir) 
        if (-not $frm -or $frm.Tag.matchIndices.Count -eq 0 -or [string]::IsNullOrWhiteSpace($frm.Tag.str)) { return }
        $frm.Tag.index += $dir
        if ($frm.Tag.index -lt 0) { $frm.Tag.index = $frm.Tag.matchIndices.Count - 1 }
        if ($frm.Tag.index -ge $frm.Tag.matchIndices.Count) { $frm.Tag.index = 0 }
        
        $cmbMatch = $frm.Controls["pnlMenu"].Controls["cmbMatchList"]
        if ($cmbMatch -and $cmbMatch.Items.Count -gt 0) {
            $frm.Tag.ignoreCmb = $true
            $cmbMatch.SelectedIndex = $frm.Tag.index
            $frm.Tag.ignoreCmb = $false
        }

        # Temp-show the first line of the HUD
        $pMenu = $frm.Controls["pnlMenu"]
        if ($pMenu) {
            $pMenu.Visible = $true
            $pMenu.BringToFront()
            if ($frm.Tag.hideTimer) {
                $frm.Tag.hideTimer.Stop()
                $frm.Tag.hideTimer.Start()
            }
        }

        $frm.Tag.currentVisibleLine = -1
        if ($frm.Tag.viewMode -eq "Full" -or $frm.Tag.viewMode -eq "Scroll") { 
            $frm.Controls["txtReaderViewer"].ExecuteScriptAsync("scrollToLine($($frm.Tag.matchIndices[$frm.Tag.index]), true);") | Out-Null 
        } else { 
            $frm.Tag.updateViewer.Invoke($frm) 
        }
        $frm.Controls["txtReaderViewer"].Focus() 
    }
    $rForm.Tag["navMatch"] = $navMatch

    $rForm.Add_KeyDown({ 
        $frm = $this; 
        $pMenu = $frm.Controls['pnlMenu'];
        if ($_.Alt -and $_.KeyCode -eq 'S') { 
             $pMenu.Visible = $true
             $pMenu.BringToFront()
             $pMenu.Controls['cmbReaderStr'].Focus() 
             $pMenu.Controls['cmbReaderStr'].SelectAll() 
             $_.SuppressKeyPress = $true 
             return 
        } 
        if ($_.KeyCode -eq "Escape") { $frm.Close(); $_.SuppressKeyPress = $true; return } 
        if (-not $pMenu.Controls['cmbReaderStr'].Focused) { 
            if ($_.KeyCode -eq "Oemcomma") { if ($frm.Tag.navMatch) { $frm.Tag.navMatch.Invoke($frm, -1) }; $_.SuppressKeyPress = $true; return } 
            if ($_.KeyCode -eq "OemPeriod") { if ($frm.Tag.navMatch) { $frm.Tag.navMatch.Invoke($frm, 1) }; $_.SuppressKeyPress = $true; return } 
        } 
    })
    $btnPrevMatch.Add_Click({ $frm=$this.FindForm(); if($frm){$frm.Tag.navMatch.Invoke($frm, -1)} })
    $btnNextMatch.Add_Click({ $frm=$this.FindForm(); if($frm){$frm.Tag.navMatch.Invoke($frm, 1)} })
    
    # [NEW] ComboBox Event Handler
    $cmbMatchList.Add_SelectedIndexChanged({
        $frm = $this.FindForm()
        if ($frm -and -not $frm.Tag.ignoreCmb -and $this.SelectedIndex -ge 0) {
            $frm.Tag.index = $this.SelectedIndex
            $frm.Tag.currentVisibleLine = -1
            if ($frm.Tag.viewMode -eq "Full" -or $frm.Tag.viewMode -eq "Scroll") {
                $frm.Controls["txtReaderViewer"].ExecuteScriptAsync("scrollToLine($($frm.Tag.matchIndices[$frm.Tag.index]), true);") | Out-Null
            } else {
                $frm.Tag.updateViewer.Invoke($frm)
            }
            $frm.Controls["txtReaderViewer"].Focus()
        }
    })

    $btnToggleView.Add_Click({ 
        $frm=$this.FindForm()
        if (-not $frm) { return }
        $js = @'
(function(){ 
    var els = document.querySelectorAll('[id^="line-"]');
    var best = -1; var minTop = 999999; 
    for(var i=0; i<els.length; i++){ 
        var r = els[i].getBoundingClientRect();
        if (r.width === 0 && r.height === 0) continue; 
        if (r.right > 0 && r.bottom > 0 && r.left < window.innerWidth && r.top < window.innerHeight){ 
            if (r.top >= 0 && r.top < minTop){ minTop = r.top; best = els[i].id.split('-')[1]; } 
        } 
    } 
    if (best !== -1) return best;
    if (els.length > 0) return els[0].id.split('-')[1]; 
    return "-1"; 
})()
'@
        $task = $frm.Controls["txtReaderViewer"].ExecuteScriptAsync($js)
        while (-not $task.IsCompleted) {
            $frame = New-Object System.Windows.Threading.DispatcherFrame
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [System.Action] { $frame.Continue = $false }) | Out-Null
            [System.Windows.Threading.Dispatcher]::PushFrame($frame)
            Start-Sleep -Milliseconds 10
        }
        $vLine = -1
        $resStr = $task.Result
        if ([string]::IsNullOrWhiteSpace($resStr)) { $resStr = '""' }
        if ([int]::TryParse($resStr.Trim('"'), [ref]$vLine)) { $frm.Tag.currentVisibleLine = $vLine }
        
        $pMenu = $frm.Controls["pnlMenu"]
        if ($frm.Tag.viewMode -eq "Context") { 
            $frm.Tag.viewMode = "Full"
            $this.Text = "Full Doc"
            $pMenu.Controls["numContext"].Enabled = $false 
        } elseif ($frm.Tag.viewMode -eq "Full") { 
            $frm.Tag.viewMode = "Scroll"
            $this.Text = "Scroll"
            $pMenu.Controls["numContext"].Enabled = $false 
        } else { 
            $frm.Tag.viewMode = "Context"
            $this.Text = "Context"
            $pMenu.Controls["numContext"].Enabled = $true 
        }
        $frm.Tag.updateViewer.Invoke($frm) 
    })

    $numContext.Add_ValueChanged({ $frm=$this.FindForm(); if($frm -and -not $frm.Tag.initializing){$frm.Tag.updateViewer.Invoke($frm)} })
    
    $btnOpenFile.Add_Click({ $frm=$this.FindForm(); if($frm -and $frm.Tag.p){ Exec-File 'open' $frm.Tag.p } })
    $btnOpenWith.Add_Click({ $frm=$this.FindForm(); if($frm -and $frm.Tag.p){ Exec-File 'with' $frm.Tag.p } })
    
    $cmbTheme.Add_SelectedIndexChanged({ 
        $frm = $this.FindForm()
        if ($frm -and -not $frm.Tag.initializing) { 
            $pSet = $frm.Controls["pnlSettings"]
            $idx = $pSet.Controls["cmbTheme"].SelectedIndex
            if ($idx -ge 0 -and $idx -lt $script:themes.Count) {
                $t = $script:themes[$idx]
                $cF = $pSet.Controls["cmbFont"]
                $fn = Resolve-ThemeFontName $t.FN
                if ($fn) { $cF.SelectedItem = $fn } elseif ($cF.Items.Contains("Consolas")) { $cF.SelectedItem = "Consolas" }
                $pSet.Controls["numFont"].Value = $t.FS
                &$script:applyThemeToReaderForm $frm $t
                $frm.Tag.currentVisibleLine = $frm.Tag.lastScrollLine
                $frm.Tag.updateViewer.Invoke($frm) 
            }
        } 
    })
    
    $cmbFont.Add_SelectedIndexChanged({ 
        $frm = $this.FindForm()
        if ($frm -and -not $frm.Tag.initializing) { 
            $pSet = $frm.Controls["pnlSettings"]
            $idx = $pSet.Controls["cmbTheme"].SelectedIndex
            if ($idx -ge 0 -and $idx -lt $script:themes.Count) {
                if ($this.SelectedItem) { $script:themes[$idx].FN = $this.SelectedItem.ToString() }
                $frm.Tag.currentVisibleLine = $frm.Tag.lastScrollLine
                $frm.Tag.updateViewer.Invoke($frm) 
            }
        } 
    })
    
    $numFont.Add_ValueChanged({ 
        $frm = $this.FindForm()
        if ($frm -and -not $frm.Tag.initializing) { 
            $pSet = $frm.Controls["pnlSettings"]
            $idx = $pSet.Controls["cmbTheme"].SelectedIndex
            if ($idx -ge 0 -and $idx -lt $script:themes.Count) {
                $script:themes[$idx].FS = [int]$this.Value
                $frm.Tag.currentVisibleLine = $frm.Tag.lastScrollLine
                $frm.Tag.updateViewer.Invoke($frm) 
            }
        } 
    })
    
    $cmbLineSp.Add_SelectedIndexChanged({ 
        $frm = $this.FindForm()
        if ($frm -and -not $frm.Tag.initializing) { 
            $frm.Tag.currentVisibleLine = $frm.Tag.lastScrollLine
            $frm.Tag.updateViewer.Invoke($frm) 
        } 
    })
    
    $btnMargin.Add_Click({
        $frm = $this.FindForm()
        if ($frm -and -not $frm.Tag.initializing) {
            if ($this.Text -eq "Narrow") { $this.Text = "Normal" }
            elseif ($this.Text -eq "Normal") { $this.Text = "Wide" }
            else { $this.Text = "Narrow" }
            $frm.Tag.currentVisibleLine = $frm.Tag.lastScrollLine
            $frm.Tag.updateViewer.Invoke($frm)
        }
    })

    $chkAlign.Add_CheckedChanged({ 
        $frm = $this.FindForm()
        if ($frm -and -not $frm.Tag.initializing) { 
            if ($this.Checked) { $this.Text = "Justified" } else { $this.Text = "Left" }
            $frm.Tag.currentVisibleLine = $frm.Tag.lastScrollLine
            $frm.Tag.updateViewer.Invoke($frm) 
        } 
    })

    $btnBgColor.Add_Click({ 
        $frm = $this.FindForm()
        if ($frm -and -not $frm.Tag.initializing) { 
            $pSet = $frm.Controls["pnlSettings"]
            $idx = $pSet.Controls["cmbTheme"].SelectedIndex
            if ($idx -ge 0 -and $idx -lt $script:themes.Count) {
                $t = $script:themes[$idx]
                $nH = Global:Show-HexColorDialog $t.Bg
                if ($nH) { 
                    $t.Bg = $nH
                    &$script:applyThemeToReaderForm $frm $t
                    $frm.Tag.currentVisibleLine = $frm.Tag.lastScrollLine
                    $frm.Tag.updateViewer.Invoke($frm)
                } 
            }
        } 
    })
    
    $btnTxColor.Add_Click({ 
        $frm = $this.FindForm()
        if ($frm -and -not $frm.Tag.initializing) { 
            $pSet = $frm.Controls["pnlSettings"]
            $idx = $pSet.Controls["cmbTheme"].SelectedIndex
            if ($idx -ge 0 -and $idx -lt $script:themes.Count) {
                $t = $script:themes[$idx]
                $nH = Global:Show-HexColorDialog $t.Tx
                if ($nH) { 
                    $t.Tx = $nH
                    &$script:applyThemeToReaderForm $frm $t
                    $frm.Tag.currentVisibleLine = $frm.Tag.lastScrollLine
                    $frm.Tag.updateViewer.Invoke($frm)
                } 
            }
        } 
    })
    
    $btnHiColor.Add_Click({ 
        $frm = $this.FindForm()
        if ($frm -and -not $frm.Tag.initializing) { 
            $pSet = $frm.Controls["pnlSettings"]
            $idx = $pSet.Controls["cmbTheme"].SelectedIndex
            if ($idx -ge 0 -and $idx -lt $script:themes.Count) {
                $t = $script:themes[$idx]
                $nH = Global:Show-HexColorDialog $t.Hi
                if ($nH) { 
                    $t.Hi = $nH
                    $frm.Tag.currentVisibleLine = $frm.Tag.lastScrollLine
                    $frm.Tag.updateViewer.Invoke($frm)
                } 
            }
        } 
    })

    $btnReset.Add_Click({ 
        $frm = $this.FindForm()
        if ($frm -and -not $frm.Tag.initializing) { 
            $pSet = $frm.Controls["pnlSettings"]
            $idx = $pSet.Controls["cmbTheme"].SelectedIndex
            $tFile = Join-Path $global:appBaseDir "ZenSeek_Themes.json"
            if (Test-Path $tFile) {
                $factory = Get-Content $tFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($idx -ge 0 -and $idx -lt $factory.Count) {
                    $script:themes[$idx].FN = $factory[$idx].FN 
                    $script:themes[$idx].FS = $factory[$idx].FS 
                    $script:themes[$idx].Bg = $factory[$idx].Bg 
                    $script:themes[$idx].Tx = $factory[$idx].Tx 
                    $script:themes[$idx].Hi = $factory[$idx].Hi 
                    $cF = $pSet.Controls["cmbFont"]
                    $fn = Resolve-ThemeFontName $script:themes[$idx].FN
                    if ($fn) { $cF.SelectedItem = $fn } elseif ($cF.Items.Contains("Consolas")) { $cF.SelectedItem = "Consolas" }
                    $pSet.Controls["numFont"].Value = $script:themes[$idx].FS 
                    
                    $pSet.Controls["cmbLine"].Text = "1.6"
                    $pSet.Controls["btnMargin"].Text = "Narrow"
                    $pSet.Controls["chkAlign"].Checked = $false
                    
                    $frm.Size = New-Object System.Drawing.Size(1208, 1371) 
                    &$script:applyThemeToReaderForm $frm $script:themes[$idx] 
                    $frm.Tag.currentVisibleLine = $frm.Tag.lastScrollLine
                    $frm.Tag.updateViewer.Invoke($frm)
                }
            }
        } 
    })
    
    $btnColToggle.Add_Click({ 
        $frm = $this.FindForm()
        if ($frm) { 
            if ($this.Text -eq "1 Column") { 
                $frm.Width = 2399
                $this.Text = "2 Columns" 
            } else { 
                $frm.Width = 1208
                $this.Text = "1 Column" 
            } 
        } 
    })
   
    $searchTimer = New-Object System.Windows.Forms.Timer
    $searchTimer.Interval = 700
    $searchTimer.Add_Tick({ $this.Stop(); $frm=$this.Tag; if($null -ne $frm -and -not $frm.IsDisposed){$frm.Tag.applySearch.Invoke($frm, $false)} })
    $rForm.Tag["searchTimer"] = $searchTimer
    $cmbReaderStr.Add_TextChanged({ $frm=$this.FindForm(); if($frm -and -not $frm.Tag.initializing){$timer=$frm.Tag.searchTimer; $timer.Tag=$frm; $timer.Stop(); $timer.Start()} })
    $cmbReaderStr.Add_KeyDown({ if($_.KeyCode -eq "Enter") { $frm=$this.FindForm(); if($frm){$frm.Tag.searchTimer.Stop(); $frm.Tag.applySearch.Invoke($frm, $true)}; $_.SuppressKeyPress=$true } })
    $chkWholeWordReader.Add_CheckedChanged({ $frm=$this.FindForm(); if($frm -and -not $frm.Tag.initializing){$frm.Tag.searchTimer.Stop(); $frm.Tag.applySearch.Invoke($frm, $false)} })
    $chkRegexReader.Add_CheckedChanged({ $frm=$this.FindForm(); if($frm -and -not $frm.Tag.initializing){$frm.Tag.searchTimer.Stop(); $frm.Tag.applySearch.Invoke($frm, $false)} })

    $pValid = $false
    if ($script:rX -ne -1 -and $script:rY -ne -1) { 
        $pPt = New-Object System.Drawing.Point($script:rX, $script:rY)
        if ([System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Bounds.Contains($pPt) }) { $pValid = $true } 
    }
    if ($pValid) { 
        $rForm.StartPosition="Manual"
        $rForm.Location="$script:rX,$script:rY"
        $rForm.Size="$script:rW,$script:rH" 
    } else { 
        $rForm.StartPosition="CenterParent" 
    }
    
    $rForm.Add_FormClosing({ 
        $frm=$this
        $d=$frm.Tag
        if(-not $d){return}
        
        # [NEW] Persist EPUB Position
        if ($d.p -match "(?i)\.epub$" -and $d.lastScrollLine -ge 0) {
            $global:epubPositions[$d.p] = $d.lastScrollLine
        }

        try { if($d.searchTimer){$d.searchTimer.Stop(); $d.searchTimer.Dispose()} } catch {}
        try { if($d.hideTimer){$d.hideTimer.Stop(); $d.hideTimer.Dispose()} } catch {}
        
        $b = $frm.Bounds
        if ($frm.WindowState -ne 'Normal') { $b = $frm.RestoreBounds }
        
        $script:rW=$b.Width
        $script:rH=$b.Height
        $script:rX=$b.X
        $script:rY=$b.Y
     
        $pMenu=$frm.Controls["pnlMenu"]
        $pSettings=$frm.Controls["pnlSettings"]
        
        if ($pSettings -and $pSettings.Controls["cmbTheme"]) { $script:activeTheme = $pSettings.Controls["cmbTheme"].SelectedIndex }
        if ($pMenu -and $pMenu.Controls["numContext"]) { $script:rContext = [int]$pMenu.Controls["numContext"].Value }
        if ($pSettings -and $pSettings.Controls["chkSmartQuotesReader"]) { $script:rSmartQuotes = $pSettings.Controls["chkSmartQuotesReader"].Checked }
        
        if ($pSettings -and $pSettings.Controls["cmbLine"]) { $script:rLineSp = $pSettings.Controls["cmbLine"].Text }
        if ($pSettings -and $pSettings.Controls["btnMargin"]) { $script:rMargin = $pSettings.Controls["btnMargin"].Text }
        if ($pSettings -and $pSettings.Controls["chkAlign"]) { $script:rAlign = $pSettings.Controls["chkAlign"].Checked }
        
        if ($pMenu -and $pMenu.Controls["cmbReaderStr"]) { $global:dRecentSearches = Global:Update-HistoryList $global:dRecentSearches $pMenu.Controls["cmbReaderStr"].Text 10 }
        
        if ($frm.Controls["txtReaderViewer"]) { $frm.Controls["txtReaderViewer"].Dispose() }
        if (-not [string]::IsNullOrWhiteSpace($d.readerPath) -and (Test-Path -LiteralPath $d.readerPath -ErrorAction SilentlyContinue)) { try { Remove-Item $d.readerPath -Force -ErrorAction SilentlyContinue } catch {} }
        if (-not [string]::IsNullOrWhiteSpace($d.epubTemp) -and (Test-Path -LiteralPath $d.epubTemp -ErrorAction SilentlyContinue)) { try { Remove-Item -Path $d.epubTemp -Recurse -Force -ErrorAction SilentlyContinue } catch {} } 
    })
    
    $t = $script:themes[$script:activeTheme]
    $fn = Resolve-ThemeFontName $t.FN
    if ($fn) { $cmbFont.SelectedItem = $fn } elseif ($cmbFont.Items.Contains("Consolas")) { $cmbFont.SelectedItem = "Consolas" }
    $numFont.Value = $t.FS 
    
    $rForm.Tag.initializing = $false
    $updateViewer.Invoke($rForm)
    $rForm.ActiveControl = $txtReaderViewer
    if ($directFilePath) { [void]$rForm.ShowDialog() } else { $rForm.Show() }
}

$mOpen.Add_Click({ Exec-File 'open' })
$mWith.Add_Click({ Exec-File 'with' })
$mLoc.Add_Click({ Exec-File 'loc' })
$mPrev.Add_Click({ Show-Reader })
$mExport = $window.FindName("mExport")
$mExport.Add_Click({
    if (-not $lstResults.ItemsSource) { return }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = "CSV Files (*.csv)|*.csv|All Files (*.*)|*.*"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $lstResults.ItemsSource | Select-Object Name, DateModified, Size, Folder, MatchText, FullPath | Export-Csv -Path $dlg.FileName -NoTypeInformation -Encoding UTF8
        [System.Windows.MessageBox]::Show("Exported to $($dlg.FileName)", "Export Complete", 0, 'Information') | Out-Null
    }
})
$lstResults.Add_MouseDoubleClick({ Show-Reader })

# [NEW] Safe Dynamic Column Resizing
$lstResults.Add_SizeChanged({
    param($sender, $e)
    # 1. Ignore if minimized or invalid
    if ($e.NewSize.Width -le 0) { return }
    
    $gv = $lstResults.View
    if (-not $gv -or $gv.Columns.Count -lt 4) { return }
    
    # 2. Calculate space taken by the fixed columns
    $usedWidth = $gv.Columns[0].ActualWidth + $gv.Columns[1].ActualWidth + $gv.Columns[2].ActualWidth
    
    # 3. Calculate remaining space MINUS the scrollbar buffer (~30px)
    $availableWidth = $e.NewSize.Width - $usedWidth - 30
    
    # 4. Apply the width only if there is actual space left
    if ($availableWidth -gt 50) {
        $gv.Columns[3].Width = $availableWidth
    }
})

# Event Handler Wrapper for Keyboard Search
$executeSearch = {
    if ($script:searchPS) {
        $script:sharedState.Cancel = $true
        $script:searchTimer.Stop()
        $script:searchPS.Stop()
        $script:searchPS.Dispose()
        $script:searchPS = $null
        $btnSearch.Content = "Search"
        $statusLabel.Text = "Search cancelled."
        return
    }

    # Update Directory History Arrays & Combobox UI
    $dir = $cmbDir.Text
    $str = $cmbStr.Text
    
    $global:dRecentDirs = Global:Update-HistoryList $global:dRecentDirs $dir 5
    Global:Sync-Combo $cmbDir $global:dRecentDirs $dir
    
    $global:dRecentSearches = Global:Update-HistoryList $global:dRecentSearches $str 10
    Global:Sync-Combo $cmbStr $global:dRecentSearches $str
    $cmbStr.Items.Insert(0, "")
    
    $global:dRecentFilters = Global:Update-HistoryList $global:dRecentFilters $txtFilter.Text 10
    Global:Sync-Combo $txtFilter $global:dRecentFilters $txtFilter.Text
    $global:dRecentExcl = Global:Update-HistoryList $global:dRecentExcl $txtExcl.Text 10
    Global:Sync-Combo $txtExcl $global:dRecentExcl $txtExcl.Text

    $lstResults.ItemsSource = $null
    $txtInlinePreview.Text = ""
    $statusLabel.Text = "Searching..."
    $btnSearch.Content = "Cancel"

    $script:sharedState = New-Object SearchState
    $script:searchPS = [powershell]::Create()
    
    $paramSub = [bool]$chkSubfolders.IsChecked
    $paramReg = [bool]$chkRegex.IsChecked
    $paramWW = [bool]$chkWholeWordMain.IsChecked
    $paramCase = [bool]$chkCaseMain.IsChecked
    
    $script:searchPS.AddScript({
        param($dir, $str, $filter, $exclude, $sub, $reg, $ww, $case, $state)
        
        $fArray = $filter -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        $eArray = $exclude -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        $targetFiles = [System.Collections.Generic.List[string]]::new()
        $skippedCount = 0
        
        $foldersToScan = [System.Collections.Generic.Queue[string]]::new()
        $foldersToScan.Enqueue($dir)
        
        while ($foldersToScan.Count -gt 0) {
            if ($state.Cancel) { break }
            $currentDir = $foldersToScan.Dequeue()
    
            if ($sub) { 
                try { foreach ($subDir in [System.IO.Directory]::EnumerateDirectories($currentDir)) { $foldersToScan.Enqueue($subDir) } } catch {} 
            }
            
            foreach ($ext in $fArray) { 
                try { 
                    foreach ($filePath in [System.IO.Directory]::EnumerateFiles($currentDir, $ext, [System.IO.SearchOption]::TopDirectoryOnly)) { 
                        $skip = $false
                        foreach ($ex in $eArray) { 
                            $exPattern = "^" + [regex]::Escape($ex).Replace("\*", ".*").Replace("\?", ".") + "$"
                            if ($filePath -match $exPattern) { $skip = $true; break } 
                        }
                        if (-not $skip) { 
                            $targetFiles.Add($filePath) 
                        } else { 
                            $skippedCount++ 
                        }
                    } 
                } catch { $skippedCount++ } 
            }
        }

        $result = [FastSearcher]::SearchFiles($targetFiles.ToArray(), $str, $reg, $ww, $case, $state)
        $state | Add-Member -NotePropertyName Skipped -NotePropertyValue $skippedCount -Force
        return $result
        
    }).AddArgument($cmbDir.Text).AddArgument($cmbStr.Text).AddArgument($txtFilter.Text).AddArgument($txtExcl.Text).AddArgument($paramSub).AddArgument($paramReg).AddArgument($paramWW).AddArgument($paramCase).AddArgument($script:sharedState) | Out-Null

    $script:asyncRes = $script:searchPS.BeginInvoke()
    $script:searchTimer.Start()
}

$btnSearch.Add_Click($executeSearch)

# WPF KeyDown Event Bindings
$enterBinding = { 
    param($sender, $e) 
    if ($e.Key.ToString() -eq 'Enter' -or $e.Key.ToString() -eq 'Return') { 
        $e.Handled = $true
        &$executeSearch 
    } 
}
$cmbStr.Add_PreviewKeyDown($enterBinding)
$cmbDir.Add_PreviewKeyDown($enterBinding)
$txtFilter.Add_PreviewKeyDown($enterBinding)
$txtExcl.Add_PreviewKeyDown($enterBinding)

$lstResults.Add_PreviewKeyDown({ 
    param($sender, $e) 
    if ($e.Key.ToString() -eq 'Enter' -or $e.Key.ToString() -eq 'Return') { 
        $e.Handled = $true
        Show-Reader 
    } 
})

# Global Timer to prevent GC
$script:searchTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:searchTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$script:searchTimer.Add_Tick({
    if ($script:asyncRes.IsCompleted) {
        $script:searchTimer.Stop()
        try {
            $script:currentResults = @($script:searchPS.EndInvoke($script:asyncRes))
            if ($script:searchPS.HadErrors) {
                $statusLabel.Text = "Search Error: $($script:searchPS.Streams.Error[0].Exception.Message)"
            } else {
                $window.Dispatcher.Invoke([System.Action]{ Global:Refresh-ListView })
                $skipped = if ($script:sharedState.PSObject.Properties['Skipped']) { [int]$script:sharedState.Skipped } else { 0 }
                if ($skipped -gt 0) {
                    $statusLabel.Text = "Ready. Found $($script:currentResults.Count) matches. ($skipped files skipped)"
                } else {
                    $statusLabel.Text = "Ready. Found $($script:currentResults.Count) matches."
                }
            }
        } catch {
            $statusLabel.Text = "Search failed: $($_.Exception.Message)"
        }
        $script:searchPS.Dispose()
        $script:searchPS = $null
        $btnSearch.Content = "Search"
    } else {
        $statusLabel.Text = "Searching... Scanned: $($script:sharedState.Scanned) | Matches: $($script:sharedState.Matches)"
    }
})

# The toggle's label and tooltip come from one function, so set them once from whatever
# the settings restored before the window is ever seen.
try { Global:Sync-ReaderToggle } catch {}

$window.ShowDialog() | Out-Null