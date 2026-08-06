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

function Show-Reader($directFilePath = $null) {
    $p = if ($directFilePath) { $directFilePath } else { if (-not $lstResults.SelectedItem) { return }; $lstResults.SelectedItem.FullPath }
    if ([string]::IsNullOrWhiteSpace($p) -or -Not (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue)) { return }
    $str = $cmbStr.Text
    $typoZenPath = Join-Path (Split-Path $global:appBaseDir) "TypoZen\bin\Debug\TypoZen.exe"
    if (-not (Test-Path $typoZenPath)) {
        $typoZenPath = Join-Path (Split-Path $global:appBaseDir) "TypoZen\TypoZen.exe"
    }
    if (-not (Test-Path $typoZenPath)) {
        [System.Windows.Forms.MessageBox]::Show("TypoZen.exe not found. Please compile it first.", "Error", 0, 'Error') | Out-Null
        return
    }
    $argsList = @("--reader", "$p")
    if (-not [string]::IsNullOrWhiteSpace($str)) {
        $argsList += "--search"
        $argsList += "$str"
    }
    Start-Process -FilePath $typoZenPath -ArgumentList $argsList
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

$window.ShowDialog() | Out-Null
