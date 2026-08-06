# 🔍 ZenSeek — Content Search & Reader for Windows

**ZenSeek** finds text inside files across a folder tree, then opens what it finds in a themed, paginated reader. It searches plain text, Markdown and CSV, and reaches inside `.epub`, `.docx` and `.xlsx` by unzipping them and stripping the markup — so a phrase buried in a Word document or an ebook chapter is as findable as one in a `.txt`.

It ships as a **PowerShell script hosted in a `.bat`**, not an executable. Nothing to install, nothing to build; drop the files in a folder and run it.

---

## What ships

| File | Role |
|------|------|
| `ZenSeek.bat` | The whole application — a `.bat` header followed by ~1,700 lines of PowerShell |
| `ZenSeek.xaml` | WPF markup for the search window |
| `ZenSeek_Engine.cs` | C# search engine, compiled at launch |
| `ZenSeek_Template.html` | Reader page shell — CSS, pagination JS, placeholder slots |
| `ZenSeek_Themes.json` | 27 themes (`Name`, `FN`, `FS`, `Bg`, `Tx`, `Hi`) |
| `Microsoft.Web.WebView2.*.dll`, `WebView2Loader.dll` | WebView2 wrappers; auto-downloaded from NuGet if missing or version-mismatched |
| `ZenSeek.json` | Generated — window geometry, recent searches, active theme, per-theme overrides |

All five source files must sit in the same directory; the script checks and refuses to start otherwise.

---

## Architecture

ZenSeek runs **three UI technologies in one process**. That is the single most important thing to know about the codebase, because almost every quirk follows from it.

### Current stack

| Layer | Search window | Reader window |
|-------|---------------|---------------|
| Runtime | Windows PowerShell 5.1 (.NET Framework 4.x), `.bat` → `Invoke-Expression` | same process |
| UI | **WPF** — `ZenSeek.xaml` via `XamlReader::Load` | **WinForms** — `Form` with absolutely-positioned controls |
| Controls | WPF, plus one WinForms `NumericUpDown` in a `WindowsFormsHost` | WinForms ComboBox / NumericUpDown / Button, floating over a `Dock=Fill` WebView2 |
| Content | Inline preview (WPF `TextBlock`) | **WebView2** (WinForms flavour) — template, CSS columns, JS pager |
| Theming | XAML | Imperative, control by control (`applyThemeToReaderForm`) + panel-painted borders; arrows and spinners unthemeable |
| Engine | `FastSearcher` recompiled every launch via `Add-Type` — **423 ms** | same |

Two seams fall out of that: WinForms↔WPF in the search window, and WinForms↔Chromium in the reader. Compare against [Planned direction](#planned-direction) below, which collapses both.

### Process model

`ZenSeek.bat` is a polyglot file. The `.bat` header launches PowerShell, which reads the file back, skips the first five lines, and pipes the remainder into `Invoke-Expression`:

```
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command
  "Get-Content '%~f0' | Select-Object -Skip 5 | Out-String | Invoke-Expression"
```

Two consequences worth internalising:

- **There is no script scope in the usual sense.** Because the body is evaluated at the top level of `-Command`, `$script:` and `$global:` land in the same place. Handlers created inside functions resolve against *that* scope, not the function's locals.
- **Everything is re-parsed on every launch**, and `ZenSeek_Engine.cs` is recompiled by `csc.exe` each time — **423 ms measured** on a warm run, before PowerShell start-up and WebView2 initialisation are counted.

### Search window — WPF

Loaded from `ZenSeek.xaml` via `XamlReader::Load`. Directory picker, search box, file filter and exclude lists, and a `ListView`/`GridView` of results with sortable columns and an inline context preview.

One control breaks the pattern: the inline-context spinner is a **WinForms `NumericUpDown` inside a `WindowsFormsHost`** ([ZenSeek.xaml:196](ZenSeek.xaml:196)), because WPF has no such control. It has to be reached through `.Child` and coloured by hand, while everything around it is styled by XAML.

Searches run on a background runspace, with a `DispatcherTimer` polling for completion and reporting scanned/matched counts into the status bar.

### Reader window — WinForms + WebView2

A `System.Windows.Forms.Form` with absolutely-positioned controls in two panels (`pnlMenu`, `pnlSettings`) that **float over** a `Dock=Fill` WebView2 rather than docking above it. The HTML compensates with a `body::before` spacer so the first lines aren't hidden under the toolbar.

The document itself is Chromium. Pagination is CSS multi-column (`break-before: column`) driven by a JS pager that snaps by page width and reports the top visible line back to the host.

### Search engine — C#

`FastSearcher` in `ZenSeek_Engine.cs`, compiled at launch via `Add-Type`:

| Member | Role |
|--------|------|
| `SearchFiles` | Parallel scan into a `ConcurrentBag<DisplayResult>`, with a shared `SearchState` for progress |
| `GetFileLines` | Text extraction — for `.epub`/`.docx`/`.xlsx`, opens the zip and pulls text from the `.htm`/`.xhtml`/`.xml` parts |
| `GetReaderLines` | Extraction for display, with an EPUB temp directory |
| `GenerateHtml` | Builds the reader body — line divs, match marks, tables, code fences, headings, smart quotes |
| `GetSearchRegex` / `GetMatchIndices` | Shared regex construction so search and reader agree on what a match is |

### Content pipeline

`GenerateHtml` output is substituted into `ZenSeek_Template.html`:

| Placeholder | Filled with |
|-------------|-------------|
| `{{DYNAMIC_CSS}}` | Theme colours, font family and size, line height, alignment |
| `{{JS_BLOCK}}` | Pager and keyboard handling — a two-column and a single-column variant |
| `{{BODY_HTML}}` | The rendered document |
| `{{PAGE_CSS}}`, `{{RESPONSIVE_CSS}}`, `{{PADDING_CSS}}` | Currently substituted empty; layout CSS is folded into `{{DYNAMIC_CSS}}` |

### Host ↔ page protocol

The page talks to PowerShell over `window.chrome.webview.postMessage`:

| Message | Meaning |
|---------|---------|
| `toggleMenu` | Body clicked — show/hide the toolbars |
| `focusSearch` | `Alt+S` |
| `prevMatch` / `nextMatch` | `,` / `.` |
| `close` | `Esc` |
| `pos:<n>` | Top visible line, for scroll restore across re-renders |

This bus already exists and is extensible — worth remembering, because it is how a themed in-page toolbar would talk to the host if the WinForms one were ever retired.

### Theming

A theme is five fields: `Bg`, `Tx`, `Hi`, `FN` (a **CSS font stack**), `FS`. The document gets them as CSS and renders exactly as specified. The chrome is where it gets awkward:

- The WPF window themes through XAML.
- The WinForms reader is themed **imperatively**, control by control, in `applyThemeToReaderForm` — back colours, fore colours, `FlatAppearance` borders, plus `DwmSetWindowAttribute` for the title bar.
- ComboBox and NumericUpDown expose no border colour, so their owning panel paints one in a `Paint` handler.
- **The dropdown arrows and spinner buttons cannot be themed at all.** They are drawn by Windows, they ignore `BackColor`, and no property reaches them. This is a hard WinForms ceiling, not an oversight.

`FN` is a CSS stack (`'Literata', 'Georgia', serif`), but the Font combo lists installed family names, so a resolver walks the stack and picks the first family actually present — including the suffixed form that variable fonts register under (`Merriweather` installs as `Merriweather 18pt`).

### Reader WebView2 environment

The reader's WebView2 environment is created with browser arguments that matter:

- `--host-resolver-rules="MAP localapp 127.0.0.1, MAP readerapp 127.0.0.1"` — these are virtual hosts served from disk, not real names, but Chromium resolves them as hostnames on every navigation. Where DNS is remote (a VPN, say) that NXDOMAIN round trip cost **~2 s per document open**. Measured with these exact names: 2,103 ms → 96 ms.
- `--disable-background-networking --disable-component-update --disable-sync --no-first-run --no-default-browser-check` — Chromium background services the reader has no use for.

The second group does **not** make the runtime silent: the WebView2 browser process still opens TLS connections to Microsoft-owned addresses at startup. Several further flag combinations were tried without effect, and the endpoint was not identified — it appears in neither the Windows DNS cache nor `--log-net-log`. Nothing document-related is involved; the reader page issues no requests of its own.

Note the PowerShell trap: `CoreWebView2EnvironmentOptions` has optional constructor parameters, and PowerShell will not bind such a constructor. All four arguments must be passed explicitly.

### State and cache

- **Settings** — `ZenSeek.json` beside the script: geometry, recent directories and searches, active theme index, per-theme colour and font overrides.
- **Cache** — `%LOCALAPPDATA%\ZenSeek_Cache`, holding the WebView2 user-data folders, rendered reader HTML and EPUB extractions. Entries older than a day are swept at start-up.

### Language traps

Hard-won, and all of them have caused a real bug in this codebase:

- **Event handlers do not capture function locals.** A scriptblock created inside a function resolves variables when it *runs*, by which time the function has returned and its locals are gone. Resolve from `$this` or `Application::OpenForms`, or use `.GetNewClosure()`. A handler that fires while its function is still on the stack — anything inside a modal `ShowDialog` — is the exception and does see them.
- **`$script:` inside a closure is not the outer script scope.** `.GetNewClosure()` creates a module with its own `$script:`. Use `$global:` for anything a closure must reach.
- **One-element collections unwrap to scalars.** `$x | Sort-Object` returns a bare object when there is one item, which then fails anything expecting `IEnumerable`. Wrap in `@()`. Empty collections returned from a function unwrap to `$null` — return `,$set`.
- **`Get-Content` defaults to ANSI.** A BOM-less UTF-8 file is mangled unless you pass `-Encoding UTF8`.
- **`NumericUpDown` clamps its height** to a border-style-derived `PreferredHeight`, and ignores assignments to `Height`. Removing its border silently shrinks it.

---

## Planned direction

*Not built. Recorded so the reasoning isn't lost.*

The end-state stack is **C# + WPF + WebView2**, compiled to a single executable:

| Layer | Search window | Reader window |
|-------|---------------|---------------|
| Runtime | compiled, one exe — **framework choice open**, see below | same process |
| UI | WPF, no WebView2 | WPF + WebView2 (WPF flavour) |
| Controls | Virtualized `ListView` | WPF, fully templatable |
| Content | Inline preview | Unchanged — template, CSS columns, JS pager |
| Theming | Resource brushes + `ControlTemplate` | same |
| Engine | `FastSearcher`, compiled in | same |

Keeping the search window free of WebView2 is deliberate: it must open instantly, and the browser engine should initialise lazily when a document is actually opened.

**On the framework, deliberately unresolved.** Modern .NET is the obvious default, but it is not clearly right here. TypoZen — the sibling app already on this stack — targets .NET Framework 4.7.2 and ships as a **193 KB** executable that runs on any Windows machine, because 4.8 is preinstalled. A framework-dependent .NET 8 build needs the Desktop Runtime installed, which is not present by default; a self-contained one is ~150 MB. For a utility whose current appeal is zero-install portability, that is a real trade rather than an upgrade. The performance case for modern .NET is also weak in this app, since the document rendering is Chromium's work, not the runtime's. Decide it when the rewrite is actually on the table.

**Why:**

1. **Start-up.** 423 ms of compilation per launch, plus PowerShell start and re-parsing 1,700 lines. Negligible for an app you leave open; it is the entire experience for a utility you invoke, search, and close.
2. **The theming ceiling.** WinForms controls are Win32 wrappers whose arrows, spinners and inner borders are painted by the OS. WPF makes each a template part. `applyThemeToReaderForm` and the border-painting workaround both disappear — a net deletion.
3. **Two bug classes stop existing.** The stale-local crash and the single-element unwrap are PowerShell-specific; C# closures capture properly and a `List<T>` does not decay into its element.
4. **Convergence with TypoZen**, which is already WPF + WebView2. Theme management, font resolution, template rendering and position persistence are currently implemented twice in two languages, and they drift.
5. **Distribution** — single exe, file associations, real icon, no execution-policy friction, no five-files-must-stay-together rule.

**What would be lost:** the ability to open the app in Notepad and change it, and true zero-install portability. Those are real properties of the current design, and giving them up should be a decision rather than a side effect.

**What carries over unchanged:** the search engine, the themes JSON, the HTML template, the column pagination, and the postMessage protocol.
