using System.Runtime.InteropServices;
using System; 
using System.Collections.Concurrent; 
using System.Collections.Generic; 
using System.Text.RegularExpressions; 
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Threading;
using System.Threading.Tasks;

public class SearchState {
    public int Scanned;
    public int Matches;
    public volatile bool Cancel;
}

public class DisplayResult {
    public string Name { get; set; }
    public string DateModified { get; set; }
    public string Size { get; set; }
    public string Folder { get; set; }
    public string FullPath { get; set; }
    public string MatchText { get; set; }
    public long RawSize { get; set; }
    public DateTime RawDate { get; set; }
}

public class FastSearcher {
    private static readonly Regex htmlTagRegex = new Regex("<[^>]+>", RegexOptions.Compiled);
    public static Regex GetSearchRegex(string searchStr, bool useRegex, bool wholeWord, bool matchCase) {
        if (string.IsNullOrEmpty(searchStr)) return null;
        RegexOptions rxOpts = matchCase ? RegexOptions.None : RegexOptions.IgnoreCase;
        
        if (useRegex) {
            try { return new Regex(searchStr, rxOpts, TimeSpan.FromSeconds(2)); } catch { return null; }
        } else {
            string escaped = Regex.Escape(searchStr);
            string fuzzy = escaped.Replace(@"\ ", @"[\s\*_~`]+");
            string bound = wholeWord ? @"\b" : "";
            string pat = @"[*_~`]*" + bound + fuzzy + bound + @"[*_~`]*";
            try { return new Regex(pat, rxOpts, TimeSpan.FromSeconds(2)); } catch { return null; }
        }
    }

    public static int[] GetMatchIndices(string[] lines, Regex rx) {
        if (rx == null || lines == null) return new int[0];
        var list = new List<int>();
        for (int i = 0; i < lines.Length; i++) {
            if (lines[i] != null && rx.IsMatch(lines[i])) list.Add(i);
        }
        return list.ToArray();
    }

    public static string[] GetFileLines(string path) {
        var lines = new List<string>();
        if (path.EndsWith(".epub", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".docx", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".xlsx", StringComparison.OrdinalIgnoreCase)) {
            try {
                using (ZipArchive zip = ZipFile.OpenRead(path)) {
                    foreach (ZipArchiveEntry entry in zip.Entries) {
                        if (entry.FullName.EndsWith(".htm", StringComparison.OrdinalIgnoreCase) || entry.FullName.EndsWith(".html", StringComparison.OrdinalIgnoreCase) || entry.FullName.EndsWith(".xhtml", StringComparison.OrdinalIgnoreCase) || entry.FullName.EndsWith(".xml", StringComparison.OrdinalIgnoreCase)) {
                            using (Stream stream = entry.Open())
                            using (StreamReader reader = new StreamReader(stream, System.Text.Encoding.UTF8, true, 65536)) {
                                string rawLine;
                                while ((rawLine = reader.ReadLine()) != null) {
                                    string tempLine = rawLine;
                                    if (path.EndsWith(".docx", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".xlsx", StringComparison.OrdinalIgnoreCase)) {
                                        tempLine = tempLine.Replace("</w:p>", "\n").Replace("</w:tr>", "\n").Replace("<w:tab/>", " ");
                                        tempLine = htmlTagRegex.Replace(tempLine, "");
                                    } else {
                                        tempLine = htmlTagRegex.Replace(tempLine, " ");
                                    }
                                    foreach (var part in tempLine.Split('\n')) {
                                        string trimmed = WebUtility.HtmlDecode(part).Trim();
                                        if (!string.IsNullOrWhiteSpace(trimmed)) {
                                            lines.Add(trimmed);
                                        } else if (lines.Count > 0 && lines[lines.Count - 1] != "") {
                                            lines.Add("");
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } catch {}
        } else {
            try { lines.AddRange(File.ReadAllLines(path, System.Text.Encoding.UTF8)); } catch {}
        }
        return lines.ToArray();
    }

    public static DisplayResult[] SearchFiles(string[] files, string searchStr, bool useRegex, bool wholeWord, bool matchCase, SearchState state) {
        var results = new ConcurrentBag<DisplayResult>();
        Regex regexObj = GetSearchRegex(searchStr, useRegex, wholeWord, matchCase);

        Parallel.ForEach(files, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, Environment.ProcessorCount - 2) }, (path, loopState) => {
            if (state.Cancel) { loopState.Stop(); return; }
            Interlocked.Increment(ref state.Scanned);

            bool isMatch = false;
            string matchLine = null;

            if (string.IsNullOrEmpty(searchStr)) {
                isMatch = true;
            } else {
                if (path.EndsWith(".epub", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".docx", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".xlsx", StringComparison.OrdinalIgnoreCase)) {
                    try {
                        using (ZipArchive zip = ZipFile.OpenRead(path)) {
                            foreach (ZipArchiveEntry entry in zip.Entries) {
                                if (loopState.IsStopped) break;
                                if (entry.FullName.EndsWith(".htm", StringComparison.OrdinalIgnoreCase) || entry.FullName.EndsWith(".html", StringComparison.OrdinalIgnoreCase) || entry.FullName.EndsWith(".xhtml", StringComparison.OrdinalIgnoreCase) || entry.FullName.EndsWith(".xml", StringComparison.OrdinalIgnoreCase)) {
                                    using (Stream stream = entry.Open())
                                    using (StreamReader reader = new StreamReader(stream, System.Text.Encoding.UTF8, true, 65536)) {
                                        string rawLine;
                                        while ((rawLine = reader.ReadLine()) != null) {
                                            if (loopState.IsStopped) break;
                                            string cleanLine = rawLine;
                                            if (path.EndsWith(".docx", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".xlsx", StringComparison.OrdinalIgnoreCase)) {
                                                cleanLine = cleanLine.Replace("</w:p>", "\n").Replace("</w:tr>", "\n").Replace("<w:tab/>", " ");
                                                cleanLine = htmlTagRegex.Replace(cleanLine, "");
                                            } else {
                                                cleanLine = htmlTagRegex.Replace(cleanLine, " ");
                                            }
                                            if (string.IsNullOrWhiteSpace(cleanLine)) continue;
                                            cleanLine = WebUtility.HtmlDecode(cleanLine);
                                            if (regexObj != null) { 
                                                var parts = cleanLine.Split('\n');
                                                foreach(var part in parts) {
                                                    if (string.IsNullOrWhiteSpace(part)) continue;
                                                    if (regexObj.IsMatch(part)) {
                                                        isMatch = true;
                                                        matchLine = part.Trim(); 
                                                        break; 
                                                    }
                                                }
                                            }
                                            if (isMatch) break;
                                        }
                                    }
                                }
                                if (isMatch) break;
                            }
                        }
                    } catch {}
                } else {
                    try {
                        using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 65536, FileOptions.SequentialScan))
                        using (StreamReader reader = new StreamReader(stream, System.Text.Encoding.UTF8, true, 65536)) {
                            string rawLine;
                            while ((rawLine = reader.ReadLine()) != null) {
                                if (loopState.IsStopped) break;
                                if (regexObj != null && regexObj.IsMatch(rawLine)) { 
                                    isMatch = true;
                                    matchLine = rawLine; 
                                    break; 
                                }
                            }
                        }
                    } catch {}
                }
            }

            if (isMatch) {
                if (matchLine == null) matchLine = "[Matched via name or empty search]";
                try {
                    FileInfo fInfo = new FileInfo(path);
                    results.Add(new DisplayResult { 
                        Name = fInfo.Name,
                        DateModified = fInfo.LastWriteTime.ToString("yyyy-MM-dd HH:mm"),
                        Size = string.Format("{0:N0} KB", Math.Ceiling((double)fInfo.Length / 1024)),
                        Folder = fInfo.DirectoryName,
                        FullPath = fInfo.FullName,
                        MatchText = matchLine.Trim(),
                        RawSize = fInfo.Length,
                        RawDate = fInfo.LastWriteTime
                    });
                    Interlocked.Increment(ref state.Matches);
                } catch {}
            }
        });
        return results.ToArray();
    }

    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    public static string[] GetReaderLines(string path, string extractDir) {
        var lines = new List<string>();
        if (path.EndsWith(".epub", StringComparison.OrdinalIgnoreCase)) {
            try {
                if (!Directory.Exists(extractDir)) Directory.CreateDirectory(extractDir);
                ZipFile.ExtractToDirectory(path, extractDir);
                
                HashSet<string> centerClasses = new HashSet<string>();
                HashSet<string> rightClasses = new HashSet<string>();
                foreach (var cssFile in Directory.GetFiles(extractDir, "*.css", SearchOption.AllDirectories)) {
                    try {
                        string css = File.ReadAllText(cssFile, System.Text.Encoding.UTF8);
                        foreach (Match m in Regex.Matches(css, @"\.([a-zA-Z0-9_-]+)\s*\{[^}]*text-align:\s*center")) centerClasses.Add(m.Groups[1].Value);
                        foreach (Match m in Regex.Matches(css, @"\.([a-zA-Z0-9_-]+)\s*\{[^}]*text-align:\s*right")) rightClasses.Add(m.Groups[1].Value);
                    } catch {}
                }
                
                string opfFile = null;
                foreach (var f in Directory.GetFiles(extractDir, "*.opf", SearchOption.AllDirectories)) {
                    opfFile = f; break;
                }
                if (opfFile != null) {
                    string opfContent = File.ReadAllText(opfFile, System.Text.Encoding.UTF8);
                    opfContent = Regex.Replace(opfContent, "xmlns\\s*=\\s*\"[^\"]+\"", "");
                    System.Xml.XmlDocument doc = new System.Xml.XmlDocument();
                    doc.LoadXml(opfContent);
                    
                    var manifest = new Dictionary<string, string>();
                    var manifestNodes = doc.SelectNodes("//manifest/item");
                    if (manifestNodes != null) {
                        foreach (System.Xml.XmlNode node in manifestNodes) {
                            if (node.Attributes["id"] != null && node.Attributes["href"] != null) {
                                manifest[node.Attributes["id"].Value] = Uri.UnescapeDataString(node.Attributes["href"].Value);
                            }
                        }
                    }
                    
                    var spineNodes = doc.SelectNodes("//spine/itemref");
                    if (spineNodes != null) {
                        string opfDir = Path.GetDirectoryName(opfFile);
                        foreach (System.Xml.XmlNode node in spineNodes) {
                            if (node.Attributes["idref"] != null && manifest.ContainsKey(node.Attributes["idref"].Value)) {
                                string href = manifest[node.Attributes["idref"].Value];
                                string fullPath = Path.Combine(opfDir, href);
                                if (File.Exists(fullPath)) {
                                    string htmlText = File.ReadAllText(fullPath, System.Text.Encoding.UTF8);
                                    Match bodyMatch = Regex.Match(htmlText, "(?si)<body[^>]*>(.*?)</body>");
                                    string bodyText = bodyMatch.Success ? bodyMatch.Groups[1].Value : htmlText;
                                    if (string.IsNullOrWhiteSpace(bodyText)) continue;
                                    
                                    string fileDir = Path.GetDirectoryName(fullPath);
                                    string relHtmlDir = "";
                                    if (fileDir.Length > extractDir.Length) {
                                        relHtmlDir = fileDir.Substring(extractDir.Length).Trim(new char[] { '\\', '/' }).Replace('\\', '/') + "/";
                                    }
                                    
                                    bodyText = Regex.Replace(bodyText, "(?i)<(?:img|image)[^>]+(?:src|xlink:href|href)\\s*=\\s*[\'\"]([^\'\"]+)[\'\"][^>]*>", " ![](" + relHtmlDir + "$1) ");
                                    bodyText = Regex.Replace(bodyText, "(?i)<br[^>]*>", "\n");
                                    bodyText = Regex.Replace(bodyText, "(?i)</(?:li|h\\d|tr|blockquote)>", "\n");
                                    bodyText = Regex.Replace(bodyText, "(?i)<h([1-6])[^>]*>", m => "\n" + new string('#', int.Parse(m.Groups[1].Value)) + " ");
                                    bodyText = Regex.Replace(bodyText, "(?i)<blockquote[^>]*>", "\n[BLOCKQUOTE]");
                                    bodyText = Regex.Replace(bodyText, "(?i)<li[^>]*>", "\n* ");
                                    bodyText = Regex.Replace(bodyText, "(?i)</?(?:b|strong)[^>]*>", "**");
                                    bodyText = Regex.Replace(bodyText, "(?i)</?(?:i|em)[^>]*>", "*");
                                    bodyText = Regex.Replace(bodyText, "(?i)</?u[^>]*>", "__");
                                    
                                    Stack<string> blockStack = new Stack<string>();
                                    bodyText = Regex.Replace(bodyText, "(?i)<(?:p|div)[^>]*>|</(?:p|div)>", m => {
                                        string val = m.Value.ToLower();
                                        if (val.StartsWith("</")) {
                                            if (blockStack.Count > 0) {
                                                string format = blockStack.Pop();
                                                if (format == "center") return "\n[/CENTER]\n";
                                                if (format == "right") return "\n[/RIGHT]\n";
                                            }
                                            return "\n";
                                        } else {
                                            if (val.EndsWith("/>")) return "\n";
                                            string format = "none";
                                            Match classMatch = Regex.Match(m.Value, "(?i)class=['\"]?([^'\">]+)['\"]?");
                                            if (classMatch.Success) {
                                                string[] classes = classMatch.Groups[1].Value.Split(new char[]{' '}, StringSplitOptions.RemoveEmptyEntries);
                                                foreach (string c in classes) {
                                                    if (centerClasses.Contains(c)) { format = "center"; break; }
                                                    if (rightClasses.Contains(c)) { format = "right"; break; }
                                                }
                                            }
                                            blockStack.Push(format);
                                            if (format == "center") return "\n[CENTER]\n";
                                            if (format == "right") return "\n[RIGHT]\n";
                                            return "\n";
                                        }
                                    });
                                    
                                    Stack<string> spanStack = new Stack<string>();
                                    bodyText = Regex.Replace(bodyText, "(?i)<span[^>]*>|</span>", m => {
                                        string val = m.Value.ToLower();
                                        if (val == "</span>") {
                                            if (spanStack.Count > 0) {
                                                string format = spanStack.Pop();
                                                if (format == "bold") return "**";
                                                if (format == "italic") return "*";
                                            }
                                            return "";
                                        } else {
                                            if (val.EndsWith("/>")) {
                                                if (Regex.IsMatch(val, "class=['\"]?[^'\"]*\\bbold\\b")) return "****";
                                                if (Regex.IsMatch(val, "class=['\"]?[^'\"]*\\bitalic\\b")) return "**";
                                                return m.Value;
                                            }
                                            if (Regex.IsMatch(val, "class=['\"]?[^'\"]*\\bbold\\b")) { spanStack.Push("bold"); return "**"; }
                                            if (Regex.IsMatch(val, "class=['\"]?[^'\"]*\\bitalic\\b")) { spanStack.Push("italic"); return "*"; }
                                            spanStack.Push("none");
                                            return m.Value;
                                        }
                                    });
                                    
                                    string clean = htmlTagRegex.Replace(bodyText, " ");
                                    if (!string.IsNullOrWhiteSpace(clean)) {
                                        clean = WebUtility.HtmlDecode(clean);
                                        bool inCenter = false;
                                        bool inRight = false;
                                        var fileLines = new List<string>();
                                        foreach (string l in clean.Split(new string[] { "\r\n", "\n" }, StringSplitOptions.None)) {
                                            if (l != null) {
                                                string trimmed = Regex.Replace(l, "\\s+", " ").Trim();
                                                if (trimmed == "[CENTER]") { inCenter = true; continue; }
                                                if (trimmed == "[/CENTER]") { inCenter = false; continue; }
                                                if (trimmed == "[RIGHT]") { inRight = true; continue; }
                                                if (trimmed == "[/RIGHT]") { inRight = false; continue; }
                                                
                                                if (trimmed.StartsWith("- ")) trimmed = "&#45; " + trimmed.Substring(2);
                                                if (Regex.IsMatch(trimmed, "^-{3,}$")) fileLines.Add("---");
                                                else if (!string.IsNullOrWhiteSpace(trimmed)) {
                                                    if (inCenter) trimmed = "[CENTER]" + trimmed;
                                                    else if (inRight) trimmed = "[RIGHT]" + trimmed;
                                                    fileLines.Add(trimmed);
                                                }
                                                else if (fileLines.Count > 0 && fileLines[fileLines.Count - 1] != "" && fileLines[fileLines.Count - 1] != "---") fileLines.Add("");
                                            }
                                        }
                                        if (fileLines.Count > 0) {
                                            lines.AddRange(fileLines);
                                            lines.Add("===PAGE_BREAK_MARKER===");
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } catch (Exception ex) { lines.Add("Error: " + ex.Message); }
            if (lines.Count == 0) lines.Add("Error: Could not extract book content.");
        } else if (path.EndsWith(".docx", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".xlsx", StringComparison.OrdinalIgnoreCase)) {
            try { lines.AddRange(GetFileLines(path)); } catch { lines.Add("Error reading DOCX/XLSX."); }
        } else {
            try { lines.AddRange(File.ReadAllLines(path, System.Text.Encoding.UTF8)); } catch { lines.Add("Error reading file."); }
        }
        return lines.ToArray();
    }

    public static string GenerateHtml(string[] lines, string searchStr, bool useRegex, bool wholeWord, bool matchCase, int activeMatchLine, bool useSmartQuotes, int startLine, int endLine) {
        if (lines == null || lines.Length == 0) return "";
        Regex rxHTML = GetSearchRegex(searchStr, useRegex, wholeWord, matchCase);
        string phStart = "[[[MARK_START]]]";
        string phEnd = "[[[MARK_END]]]";
        
        Regex rxOpenDbl = new Regex("(^|[\\s\\(\\[\\{\\]\\|\\u2502])\"", RegexOptions.Compiled);
        Regex rxCloseDbl = new Regex("\"", RegexOptions.Compiled);
        Regex rxOpenSgl = new Regex("(^|[\\s\\(\\[\\{\\]\\|\\u2502])'", RegexOptions.Compiled);
        Regex rxCloseSgl = new Regex("'", RegexOptions.Compiled);
        Regex rxImage = new Regex("!\\[(.*?)\\]\\((.*?)\\)", RegexOptions.Compiled);
        Regex rxBold = new Regex("(?<!\\\\)\\*\\*(.*?)(?<!\\\\)\\*\\*", RegexOptions.Compiled);
        Regex rxItalic = new Regex("(?<!\\\\)\\*(.*?)(?<!\\\\)\\*", RegexOptions.Compiled);
        Regex rxUnderline = new Regex("(?<!\\\\)__(.*?)(?<!\\\\)__", RegexOptions.Compiled);
        Regex rxStrike = new Regex("~~(.*?)~~", RegexOptions.Compiled);
        Regex rxCode = new Regex("`(.*?)`", RegexOptions.Compiled);
        Regex rxHead = new Regex("(?m)^(#+)\\s+(.*)$", RegexOptions.Compiled);
        Regex rxBullet = new Regex("(?m)^\\s*[-*]\\s+(.*)$", RegexOptions.Compiled);
        Regex rxNumList = new Regex("(?m)^\\s*(\\d+\\.)\\s+(.*)$", RegexOptions.Compiled);
        
        string boxEmpty = "<span style='font-family: \"Segoe Fluent Icons\", \"Segoe MDL2 Assets\", \"Consolas\"; font-size: 1.1em;'>&#xE739;</span>";
        string boxCheck = "<span style='font-family: \"Segoe Fluent Icons\", \"Segoe MDL2 Assets\", \"Consolas\"; font-size: 1.1em;'>&#xE73A;</span>";
        
        System.Text.StringBuilder htmlLinesBuilder = new System.Text.StringBuilder(lines.Length * 100);
        
        bool inTable = false;
        bool inCode = false;
        for (int k = 0; k < startLine; k++) { if (lines[k].StartsWith("```")) inCode = !inCode; }
        
        for (int j = startLine; j <= endLine && j < lines.Length; j++) {
            string rawLine = lines[j];
            if (rawLine == "===PAGE_BREAK_MARKER===") {
                if (inTable) { inTable = false; htmlLinesBuilder.AppendLine("</table>"); }
                htmlLinesBuilder.AppendLine("<div class='page-break'></div>");
                continue;
            }
            
            bool isActive = (activeMatchLine >= 0 && j == activeMatchLine);
            string rawTrim = rawLine.Trim();
            
            bool isCodeBlockBorder = false;
            if (Regex.IsMatch(rawTrim, "^```")) { inCode = !inCode; isCodeBlockBorder = true; }
            
            if (isCodeBlockBorder || inCode) {
                string line = rawLine;
                if (rxHTML != null) { try { line = rxHTML.Replace(line, phStart + "$0" + phEnd); } catch {} }
                line = line.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");
                string divClass = isActive ? "tl active-line code-line" : "tl code-line";
                if (line.Trim() == "") line = "&nbsp;";
                htmlLinesBuilder.AppendLine(string.Format("<div id='line-{0}' class='{1}'>{2}</div>", j, divClass, line));
                continue;
            }
            
            string normalLine = rawLine.TrimStart();
            if (rxHTML != null) { try { normalLine = rxHTML.Replace(normalLine, phStart + "$0" + phEnd); } catch {} }
            normalLine = normalLine.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");
            normalLine = Regex.Replace(normalLine, "^\\s*-\\s*\\[ \\]\\s*", boxEmpty + " ");
            normalLine = Regex.Replace(normalLine, "^\\s*-\\s*\\[[xX]\\]\\s*", boxCheck + " ");
            
            if (useSmartQuotes) {
                normalLine = rxOpenDbl.Replace(normalLine, "$1&ldquo;");
                normalLine = rxCloseDbl.Replace(normalLine, "&rdquo;");
                normalLine = rxOpenSgl.Replace(normalLine, "$1&lsquo;");
                normalLine = rxCloseSgl.Replace(normalLine, "&rsquo;");
            }
            
            if (Regex.IsMatch(normalLine, "^[ \t]*[|\\u2502].*[|\\u2502][ \t]*$")) {
                bool isHeaderRow = false;
                if (!inTable) {
                    inTable = true;
                    htmlLinesBuilder.AppendLine("<table>");
                    isHeaderRow = true;
                }
                if (Regex.IsMatch(normalLine, "^[ \t]*[|\\u2502][- :|\\u2502]+[|\\u2502][ \t]*$")) continue;
                
                string[] cells = normalLine.Trim().Trim(new char[] { '|', '\u2502' }).Split(new char[] { '|', '\u2502' });
                string trClass = isActive ? " class='active-line'" : "";
                htmlLinesBuilder.AppendLine(string.Format("<tr id='line-{0}'{1}>", j, trClass));
                string tag = isHeaderRow ? "th" : "td";
                foreach (string cRaw in cells) {
                    string c = cRaw.Trim();
                    c = rxImage.Replace(c, "<img src='$2' alt='$1' style='max-width:100%; max-height:80vh;'/>");
                    c = rxBold.Replace(c, "<b>$1</b>");
                    c = rxItalic.Replace(c, "<i>$1</i>");
                    c = rxUnderline.Replace(c, "<u>$1</u>");
                    c = rxStrike.Replace(c, "<s>$1</s>");
                    c = rxCode.Replace(c, "<code>$1</code>");
                    c = rxBullet.Replace(c, "<div class='li'><span class='bullet'>&bull;</span><span class='li-text'>$1</span></div>");
                    c = rxNumList.Replace(c, "<div class='li'><span class='bullet'>$1</span><span class='li-text'>$2</span></div>");
                    c = c.Replace("\\*", "*");
                    htmlLinesBuilder.AppendLine(string.Format("<{0}>{1}</{0}>", tag, c));
                }
                htmlLinesBuilder.AppendLine("</tr>");
            } else {
                if (inTable) {
                    inTable = false;
                    htmlLinesBuilder.AppendLine("</table>");
                }
                bool isHR = Regex.IsMatch(rawTrim, "^-{3,}$");
                
                normalLine = rxHead.Replace(normalLine, m => string.Format("<h{0}>{1}</h{0}>", Math.Min(6, m.Groups[1].Value.Length), m.Groups[2].Value));
                normalLine = rxImage.Replace(normalLine, "<div style='text-align:center; margin:15px 0;'><img src='$2' alt='$1' style='max-width:100%; max-height:80vh; border-radius:5px;'/></div>");
                normalLine = rxBold.Replace(normalLine, "<b>$1</b>");
                normalLine = rxItalic.Replace(normalLine, "<i>$1</i>");
                normalLine = rxUnderline.Replace(normalLine, "<u>$1</u>");
                normalLine = rxStrike.Replace(normalLine, "<s>$1</s>");
                normalLine = rxCode.Replace(normalLine, "<code>$1</code>");
                normalLine = rxBullet.Replace(normalLine, "<div class='li'><span class='bullet'>&bull;</span><span class='li-text'>$1</span></div>");
                normalLine = rxNumList.Replace(normalLine, "<div class='li'><span class='bullet'>$1</span><span class='li-text'>$2</span></div>");
                normalLine = normalLine.Replace("\\*", "*");
                
                if (Regex.IsMatch(rawLine, "^[ \t]+") && !normalLine.Contains("<div class='li'>") && !normalLine.StartsWith("<h") && normalLine.Trim() != "") {
                    normalLine = string.Format("<div class='li'><span class='bullet'></span><span class='li-text'>{0}</span></div>", normalLine);
                }
                
                string divClass = isActive ? "tl active-line" : "tl";
                string divStyle = "";
                
                if (normalLine.StartsWith("[CENTER]")) {
                    normalLine = normalLine.Substring(8).TrimStart();
                    divStyle = " style='text-align:center;'";
                } else if (normalLine.StartsWith("[RIGHT]")) {
                    normalLine = normalLine.Substring(7).TrimStart();
                    divStyle = " style='text-align:right;'";
                } else if (normalLine.StartsWith("[BLOCKQUOTE]")) {
                    normalLine = normalLine.Substring(12).TrimStart();
                    divClass += " blockquote-text";
                    divStyle = " style='border-left: 3px solid rgba(128,128,128,0.5); padding-left: 15px; margin: 10px 0; font-style: italic;'";
                }
                
                if (isHR) {
                    htmlLinesBuilder.AppendLine(string.Format("<div id='line-{0}' class='{1}' style='min-height: 0; margin: 0; padding: 0;'><hr style='margin: 0; border: 0; border-top: 1px solid rgba(128,128,128,0.4);' /></div>", j, divClass));
                } else if (normalLine.StartsWith("<h")) {
                    htmlLinesBuilder.AppendLine(string.Format("<div id='line-{0}' class='{1}'{2}>{3}</div>", j, divClass, divStyle, normalLine));
                } else {
                    if (rawTrim == "") normalLine = "&nbsp;";
                    htmlLinesBuilder.AppendLine(string.Format("<div id='line-{0}' class='{1}'{2}>{3}</div>", j, divClass, divStyle, normalLine));
                }
            }
        }
        if (inTable) htmlLinesBuilder.AppendLine("</table>");
        
        return htmlLinesBuilder.ToString().Replace(phStart, "<mark>").Replace(phEnd, "</mark>");
    }

}