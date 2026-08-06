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

}
