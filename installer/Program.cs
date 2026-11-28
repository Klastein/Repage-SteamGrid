using System;
using System.IO;
using System.Net;
using System.Text;
using System.Drawing;
using System.Reflection;
using System.Diagnostics;
using System.Threading;
using System.Globalization;
using System.Windows.Forms;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Runtime.CompilerServices;
using Microsoft.Win32;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace RepageInstaller {
  [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
  class FileOpenDialogRCW {}

  [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IFileOpenDialog {
    [PreserveSig] int Show([In] IntPtr parent);
    void SetFileTypes();
    void SetFileTypeIndex([In] uint iFileType);
    void GetFileTypeIndex(out uint piFileType);
    void Advise();
    void Unadvise();
    void SetOptions([In] uint fos);
    void GetOptions(out uint pfos);
    void SetDefaultFolder([In, MarshalAs(UnmanagedType.Interface)] IShellItem psi);
    void SetFolder([In, MarshalAs(UnmanagedType.Interface)] IShellItem psi);
    void GetFolder([MarshalAs(UnmanagedType.Interface)] out IShellItem ppsi);
    void GetCurrentSelection([MarshalAs(UnmanagedType.Interface)] out IShellItem ppsi);
    void SetFileName([In, MarshalAs(UnmanagedType.LPWStr)] string pszName);
    void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
    void SetTitle([In, MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
    void SetOkButtonLabel([In, MarshalAs(UnmanagedType.LPWStr)] string pszText);
    void SetFileNameLabel([In, MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
    void GetResult([MarshalAs(UnmanagedType.Interface)] out IShellItem ppsi);
  }

  [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IShellItem {
    void BindToHandler();
    void GetParent();
    void GetDisplayName([In] uint sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
  }

  static class Program {
    internal static string HtmlPayload = Encoding.UTF8.GetString(Convert.FromBase64String("__HTML_B64__"));
    internal static byte[] FaviconBytes = string.IsNullOrEmpty("__ICON_B64__") ? new byte[0] : Convert.FromBase64String("__ICON_B64__");
    internal static string RepoOwner = "__REPO_OWNER__";
    internal static string RepoName = "__REPO_NAME__";
    internal static string OsLocale = CultureInfo.CurrentUICulture.Name;
    internal static string SteamDir = "";
    internal static string PluginsDir = "";
    internal static bool HasMillennium = false;
    internal static string InstalledVersion = "";
    internal static string LatestVersion = "";
    internal static string ZipDownloadUrl = "";
    internal static bool IsOnline = true;
    internal static string LastError = "";
    internal static string InstallStatus = "idle";
    internal static int InstallPercent = 0;
    internal static string InstallStepCode = "connecting";
    internal static long DownloadedKb = 0;
    internal static Form MainWindow = null;
    internal static Stopwatch Clock = Stopwatch.StartNew();
    internal static StringBuilder LogBuf = new StringBuilder();
    internal static object LogLock = new object();
    internal const long MaxZipDownloadBytes = 32L * 1024L * 1024L;
    internal const long MaxZipExtractedBytes = 64L * 1024L * 1024L;
    internal const int MaxZipEntries = 64;
    internal static readonly string UserAgentStr = "RepageSteamGrid-Setup/4.8";
    internal static object InstallLock = new object();
    internal static bool PickingFolder = false;
    internal static bool RestartingSteam = false;
    internal static bool AutoEnabledInConfig = false;
    internal static bool DidAutoEnableThisSession = false;
    internal static bool DidUninstallThisSession = false;
    internal static string CustomSelectedPath = "";
    internal static string ExpectedZipSha256 = "";
    internal static string SessionToken = Guid.NewGuid().ToString("N");
    internal static string LogFilePath = Path.Combine(Path.GetTempPath(), "Repage_SteamGrid_Setup.log");

    [DllImport("user32.dll")]
    static extern bool SetProcessDPIAware();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SetDllDirectory(string lpPathName);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName([In] string pszPath, IntPtr pbc, [In, MarshalAs(UnmanagedType.LPStruct)] Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItem ppv);

    internal static void Log(string tag, string msg) {
      string line = string.Format("[{0:000.000}s] [{1}] {2}", Clock.Elapsed.TotalSeconds, tag, msg);
      lock (LogLock) {
        LogBuf.AppendLine(line);
        try { File.AppendAllText(LogFilePath, line + Environment.NewLine, Encoding.UTF8); } catch {}
      }
    }

    [STAThread]
    static void Main(string[] args) {
      if (args != null && args.Length >= 1) {
        if (args[0] == "--elevated-install" && args.Length >= 7) {
          Environment.Exit(ExecuteElevatedInstall(args[1], args[2], args[3], args[4], args[5] == "1", args[6]));
          return;
        }
        if (args[0] == "--elevated-uninstall" && args.Length >= 3) {
          string uSid = args.Length >= 4 ? args[3] : "none";
          Environment.Exit(ExecuteElevatedUninstall(args[1], args[2], uSid));
          return;
        }
      }
      try { SetProcessDPIAware(); } catch {}
      try { File.WriteAllText(LogFilePath, "", Encoding.UTF8); } catch {}
      HtmlPayload = HtmlPayload.Replace("__SESSION_TOKEN__", SessionToken);
      Log("BOOT", "Repage SteamGrid Setup v4.8 starting (OS=" + Environment.OSVersion + ", 64Bit=" + Environment.Is64BitProcess + ", Culture=" + OsLocale + ", Log=" + LogFilePath + ")");
      AppDomain.CurrentDomain.AssemblyResolve += ResolveEmbeddedAssembly;
      try { ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072 | (SecurityProtocolType)12288 | SecurityProtocolType.Tls; }
      catch { try { ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072; } catch {} }
      Application.EnableVisualStyles();
      Application.SetCompatibleTextRenderingDefault(false);

      string loaderDir = ExtractWebView2Loader();
      if (!string.IsNullOrEmpty(loaderDir)) {
        try { SetDllDirectory(loaderDir); Log("WV2", "WebView2Loader extracted to " + loaderDir); } catch (Exception ex) { Log("WV2_ERR", ex.Message); }
      }

      DetectSteamAndMillennium("");
      int port = FindFreePort();
      HttpListener listener = new HttpListener();
      string prefix = "http://127.0.0.1:" + port + "/";
      listener.Prefixes.Add(prefix);
      listener.Start();
      Log("HTTP", "Local bridge listening on " + prefix);

      Thread serverThread = new Thread(() => RunServer(listener));
      serverThread.IsBackground = true;
      serverThread.Start();

      NativeUiRunner.Run(prefix, loaderDir);
      try { listener.Stop(); } catch {}
      Environment.Exit(0);
    }

    static Assembly ResolveEmbeddedAssembly(object sender, ResolveEventArgs args) {
      string simpleName = new AssemblyName(args.Name).Name + ".dll";
      using (Stream st = Assembly.GetExecutingAssembly().GetManifestResourceStream(simpleName)) {
        if (st == null) return null;
        byte[] data = new byte[st.Length];
        st.Read(data, 0, data.Length);
        Log("ASM", "Loaded embedded assembly " + simpleName);
        return Assembly.Load(data);
      }
    }

    static string ExtractWebView2Loader() {
      try {
        string dir = Path.Combine(Path.GetTempPath(), "RepageSetup_WV2_Bin_x64");
        Directory.CreateDirectory(dir);
        string dllPath = Path.Combine(dir, "WebView2Loader.dll");
        using (Stream st = Assembly.GetExecutingAssembly().GetManifestResourceStream("WebView2Loader.dll")) {
          if (st == null) return "";
          if (!File.Exists(dllPath) || new FileInfo(dllPath).Length != st.Length) {
            using (FileStream fs = new FileStream(dllPath, FileMode.Create, FileAccess.Write)) { st.CopyTo(fs); }
          }
        }
        return dir;
      } catch (Exception ex) { Log("WV2_EXTRACT_ERR", ex.Message); return ""; }
    }

    static int FindFreePort() {
      System.Net.Sockets.TcpListener l = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
      l.Start();
      int port = ((IPEndPoint)l.LocalEndpoint).Port;
      l.Stop();
      return port;
    }

    internal static bool IsSteamRunning() {
      try { return Process.GetProcessesByName("steam").Length > 0; } catch { return false; }
    }

    static string FindSteamExe() {
      if (!string.IsNullOrEmpty(SteamDir)) {
        string p = Path.Combine(SteamDir, "steam.exe");
        if (File.Exists(p)) return p;
      }
      try {
        using (RegistryKey k = Registry.CurrentUser.OpenSubKey("Software\\Valve\\Steam")) {
          if (k != null) {
            object v = k.GetValue("SteamExe");
            if (v != null) {
              string p = v.ToString().Replace('/', '\\');
              if (File.Exists(p)) return p;
            }
          }
        }
      } catch {}
      try {
        foreach (Process pr in Process.GetProcessesByName("steam")) {
          try {
            string mp = pr.MainModule != null ? pr.MainModule.FileName : "";
            if (!string.IsNullOrEmpty(mp) && File.Exists(mp)) return mp;
          } catch {}
        }
      } catch {}
      return "";
    }

    static void LaunchSteamOnly() {
      Log("STEAM", "LaunchSteamOnly via explorer.exe steam://open/main");
      try {
        ProcessStartInfo epsi = new ProcessStartInfo("explorer.exe", "steam://open/main");
        epsi.UseShellExecute = false;
        Process.Start(epsi);
        return;
      } catch (Exception ex) { Log("STEAM_EXPLORER_WARN", ex.Message); }
      string exe = FindSteamExe();
      if (!string.IsNullOrEmpty(exe)) {
        try {
          ProcessStartInfo psi = new ProcessStartInfo(exe);
          psi.WorkingDirectory = Path.GetDirectoryName(exe);
          psi.UseShellExecute = true;
          Process.Start(psi);
          return;
        } catch (Exception ex) { Log("STEAM_ERR", ex.Message); }
      }
    }

    static void SafeShutdownSteamCore() {
      string exe = FindSteamExe();
      Log("STEAM", "SafeShutdownSteam starting (exe=" + exe + ")");
      if (!string.IsNullOrEmpty(exe)) {
        try {
          ProcessStartInfo stopPsi = new ProcessStartInfo(exe, "-shutdown");
          stopPsi.UseShellExecute = false;
          stopPsi.CreateNoWindow = true;
          stopPsi.WindowStyle = ProcessWindowStyle.Hidden;
          Process.Start(stopPsi);
        } catch (Exception ex) { Log("STEAM_SHUTDOWN_ERR", ex.Message); }
        for (int i = 0; i < 88 && IsSteamRunning(); i++) Thread.Sleep(250);
      }
      if (IsSteamRunning()) {
        Log("STEAM", "Graceful 22s shutdown timed out; terminating remaining steam processes");
        foreach (string pname in new string[] { "steam", "steamwebhelper" }) {
          try {
            foreach (Process pr in Process.GetProcessesByName(pname)) {
              try { pr.Kill(); pr.WaitForExit(2000); } catch {}
            }
          } catch {}
        }
        Thread.Sleep(900);
      }
    }

    static bool SafeShutdownSteamOnly() {
      if (RestartingSteam) { Log("STEAM", "SafeShutdownSteamOnly ignored (busy)"); return !IsSteamRunning(); }
      RestartingSteam = true;
      try {
        SafeShutdownSteamCore();
        return !IsSteamRunning();
      } finally {
        RestartingSteam = false;
      }
    }

    static void SafeRestartSteam() {
      if (RestartingSteam) { Log("STEAM", "SafeRestartSteam ignored (already running)"); return; }
      RestartingSteam = true;
      try {
        SafeShutdownSteamCore();
        if (DidAutoEnableThisSession && !string.IsNullOrEmpty(InstalledVersion)) {
          Thread.Sleep(250);
          if (!IsPluginEnabledInMillennium() && SetPluginEnabledInMillennium(true)) {
            AutoEnabledInConfig = IsPluginEnabledInMillennium();
            Log("MILL_CFG", "Re-applied enabledPlugins while Steam is closed; verified=" + AutoEnabledInConfig);
          }
        } else if (DidUninstallThisSession && string.IsNullOrEmpty(InstalledVersion)) {
          Thread.Sleep(250);
          if (IsPluginEnabledInMillennium() && SetPluginEnabledInMillennium(false)) {
            Log("MILL_CFG", "Re-cleaned repage-steamgrid from enabledPlugins while Steam is closed");
          }
        }
        LaunchSteamOnly();
      } finally {
        RestartingSteam = false;
      }
    }

    static string NormalizePathCasing(string p) {
      if (string.IsNullOrEmpty(p)) return "";
      try {
        string full = Path.GetFullPath(p).TrimEnd(Path.DirectorySeparatorChar);
        if (full.Length >= 2 && full[1] == ':') full = char.ToUpperInvariant(full[0]) + full.Substring(1);
        string[] segs = full.Split(Path.DirectorySeparatorChar);
        for (int si = 0; si < segs.Length; si++) {
          if (segs[si].Equals("program files (x86)", StringComparison.OrdinalIgnoreCase)) segs[si] = "Program Files (x86)";
          else if (segs[si].Equals("program files", StringComparison.OrdinalIgnoreCase)) segs[si] = "Program Files";
          else if (segs[si].Equals("steam", StringComparison.OrdinalIgnoreCase)) segs[si] = "Steam";
        }
        return string.Join(Path.DirectorySeparatorChar.ToString(), segs);
      } catch { return p; }
    }

    internal static void DetectSteamAndMillennium(string customPath) {
      string forcedPlugins = "";
      if (!string.IsNullOrEmpty(customPath) && Directory.Exists(customPath)) {
        string norm = NormalizePathCasing(customPath);
        string leaf = Path.GetFileName(norm);
        if (string.Equals(leaf, "repage-steamgrid", StringComparison.OrdinalIgnoreCase)) {
          forcedPlugins = Path.GetDirectoryName(norm);
          norm = Path.GetDirectoryName(forcedPlugins);
          if (string.Equals(Path.GetFileName(norm), "millennium", StringComparison.OrdinalIgnoreCase)) norm = Path.GetDirectoryName(norm);
        } else if (string.Equals(leaf, "plugins", StringComparison.OrdinalIgnoreCase)) {
          forcedPlugins = norm;
          norm = Path.GetDirectoryName(norm);
          if (string.Equals(Path.GetFileName(norm), "millennium", StringComparison.OrdinalIgnoreCase)) norm = Path.GetDirectoryName(norm);
        } else if (string.Equals(leaf, "millennium", StringComparison.OrdinalIgnoreCase)) {
          forcedPlugins = Path.Combine(norm, "plugins");
          norm = Path.GetDirectoryName(norm);
        }
        SteamDir = norm;
      }
      if (string.IsNullOrEmpty(SteamDir) || !Directory.Exists(SteamDir)) {
        try {
          using (RegistryKey k = Registry.CurrentUser.OpenSubKey("Software\\Valve\\Steam")) {
            if (k != null) {
              object v = k.GetValue("SteamPath") ?? k.GetValue("SteamExe");
              if (v != null) {
                string p = v.ToString().Replace('/', '\\');
                if (p.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) p = Path.GetDirectoryName(p);
                if (Directory.Exists(p)) SteamDir = NormalizePathCasing(p);
              }
            }
          }
        } catch {}
      }
      if (string.IsNullOrEmpty(SteamDir) || !Directory.Exists(SteamDir)) {
        foreach (string d in new string[] { "C:\\Program Files (x86)\\Steam", "C:\\Program Files\\Steam", "D:\\Steam", "E:\\Steam" }) {
          if (Directory.Exists(d)) { SteamDir = d; break; }
        }
      }
      HasMillennium = false;
      InstalledVersion = "";
      PluginsDir = "";
      if (!string.IsNullOrEmpty(SteamDir) && Directory.Exists(SteamDir)) {
        string pStd = Path.Combine(SteamDir, "plugins");
        string pMill = Path.Combine(SteamDir, "millennium", "plugins");
        string millDir = Path.Combine(SteamDir, "millennium");
        bool hasLoaderDll = File.Exists(Path.Combine(SteamDir, "user32.dll")) || File.Exists(Path.Combine(SteamDir, "wsock32.dll")) || File.Exists(Path.Combine(SteamDir, "version.dll"));
        bool hasPython = File.Exists(Path.Combine(SteamDir, "python311.dll")) || File.Exists(Path.Combine(SteamDir, "python312.dll")) || File.Exists(Path.Combine(millDir, "python311.dll")) || File.Exists(Path.Combine(millDir, "python312.dll"));
        bool hasFramework = File.Exists(Path.Combine(SteamDir, "millennium.dll")) ||
                            File.Exists(Path.Combine(millDir, "millennium.dll")) ||
                            File.Exists(Path.Combine(millDir, "lib", "millennium.dll")) ||
                            File.Exists(Path.Combine(millDir, "bin", "millennium.dll")) ||
                            File.Exists(Path.Combine(millDir, "ext", "millennium.dll")) ||
                            File.Exists(Path.Combine(SteamDir, "ext", "millennium.dll")) ||
                            (hasLoaderDll && hasPython) ||
                            HasAnyPluginJson(pStd) ||
                            HasAnyPluginJson(pMill);

        if (!string.IsNullOrEmpty(forcedPlugins) && Directory.Exists(forcedPlugins)) {
          PluginsDir = forcedPlugins;
          HasMillennium = hasFramework || HasAnyPluginJson(forcedPlugins);
        } else if (hasFramework) {
          HasMillennium = true;
          if (Directory.Exists(Path.Combine(pMill, "repage-steamgrid"))) PluginsDir = pMill;
          else if (Directory.Exists(Path.Combine(pStd, "repage-steamgrid"))) PluginsDir = pStd;
          else if (HasAnyPluginJson(pStd) && !HasAnyPluginJson(pMill)) PluginsDir = pStd;
          else if (HasAnyPluginJson(pMill) && !HasAnyPluginJson(pStd)) PluginsDir = pMill;
          else if (Directory.Exists(pMill) || Directory.Exists(millDir)) PluginsDir = pMill;
          else PluginsDir = pStd;
        } else {
          HasMillennium = false;
          PluginsDir = "";
        }
        if (!string.IsNullOrEmpty(PluginsDir)) {
          string pjson = Path.Combine(PluginsDir, "repage-steamgrid", "plugin.json");
          if (File.Exists(pjson)) {
            try { InstalledVersion = ExtractJsonStr(File.ReadAllText(pjson, Encoding.UTF8), "version"); } catch {}
          }
        }
      }
      Log("DETECT", "SteamDir=" + SteamDir + " | PluginsDir=" + PluginsDir + " | HasMill=" + HasMillennium + " | InstalledVer=" + InstalledVersion);
    }

    static string PickFolderModern(IntPtr ownerHwnd, string initialDir) {
      try {
        IFileOpenDialog dlg = (IFileOpenDialog)new FileOpenDialogRCW();
        dlg.SetOptions(0x20 | 0x40 | 0x800);
        dlg.SetTitle("Selecione a pasta da Steam ou do Millennium (Steam/millennium/plugins)");
        if (!string.IsNullOrEmpty(initialDir) && Directory.Exists(initialDir)) {
          IShellItem item;
          Guid shellItemGuid = new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE");
          SHCreateItemFromParsingName(initialDir, IntPtr.Zero, shellItemGuid, out item);
          if (item != null) dlg.SetFolder(item);
        }
        int hr = dlg.Show(ownerHwnd);
        if (hr == 0) {
          IShellItem resItem;
          dlg.GetResult(out resItem);
          if (resItem != null) {
            string path;
            resItem.GetDisplayName(0x80058000, out path);
            return path ?? "";
          }
        }
        return "";
      } catch (Exception ex) {
        Log("COM_PICKER_FALLBACK", ex.Message);
        using (FolderBrowserDialog fbd = new FolderBrowserDialog()) {
          fbd.Description = "Selecione a pasta da Steam ou do Millennium:";
          if (!string.IsNullOrEmpty(initialDir) && Directory.Exists(initialDir)) fbd.SelectedPath = initialDir;
          return fbd.ShowDialog() == DialogResult.OK ? fbd.SelectedPath : "";
        }
      }
    }

    static string HttpGetString(string url) {
      Log("HTTP_GET", url);
      HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
      req.UserAgent = UserAgentStr;
      req.Accept = "application/vnd.github+json";
      req.AllowAutoRedirect = true;
      req.Timeout = 14000;
      using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
      using (StreamReader sr = new StreamReader(resp.GetResponseStream(), Encoding.UTF8)) {
        string body = sr.ReadToEnd();
        Log("HTTP_OK", "Status=" + (int)resp.StatusCode + " Len=" + body.Length);
        return body;
      }
    }

    static bool HasAnyPluginJson(string dir) {
      if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) return false;
      try {
        foreach (string sub in Directory.GetDirectories(dir)) {
          if (File.Exists(Path.Combine(sub, "plugin.json"))) return true;
        }
      } catch {}
      return false;
    }

    static bool TryGithubWebRedirect(out string outTag, out string outZip, out string outErr) {
      outTag = ""; outZip = ""; outErr = "";
      try {
        string webUrl = "https://github.com/" + RepoOwner + "/" + RepoName + "/releases/latest";
        Log("GITHUB_WEB", "Fallback GET " + webUrl);
        HttpWebRequest req = (HttpWebRequest)WebRequest.Create(webUrl);
        req.UserAgent = UserAgentStr;
        req.AllowAutoRedirect = false;
        req.Timeout = 14000;
        string finalUrl = "";
        using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse()) {
          string loc = resp.Headers["Location"];
          if (!string.IsNullOrEmpty(loc)) finalUrl = loc;
          else if (resp.ResponseUri != null) finalUrl = resp.ResponseUri.AbsoluteUri;
        }
        int tagIdx = finalUrl.IndexOf("/releases/tag/", StringComparison.OrdinalIgnoreCase);
        if (tagIdx < 0) { outErr = "Could not resolve latest release tag from GitHub."; return false; }
        string tag = finalUrl.Substring(tagIdx + "/releases/tag/".Length).Trim().Trim('/');
        int qIdx = tag.IndexOfAny(new char[] { '?', '#' });
        if (qIdx >= 0) tag = tag.Substring(0, qIdx);
        if (string.IsNullOrEmpty(tag)) { outErr = "Empty release tag from GitHub."; return false; }
        string ver = tag.StartsWith("v", StringComparison.OrdinalIgnoreCase) ? tag.Substring(1) : tag;
        string candidateZip = "https://github.com/" + RepoOwner + "/" + RepoName + "/releases/download/" + tag + "/Repage_SteamGrid_" + ver + ".zip";
        HttpWebRequest headReq = (HttpWebRequest)WebRequest.Create(candidateZip);
        headReq.Method = "HEAD";
        headReq.UserAgent = UserAgentStr;
        headReq.AllowAutoRedirect = true;
        headReq.Timeout = 10000;
        using (HttpWebResponse headResp = (HttpWebResponse)headReq.GetResponse()) {
          if ((int)headResp.StatusCode >= 400) { outErr = "Release ZIP asset returned HTTP " + (int)headResp.StatusCode; return false; }
        }
        outTag = tag;
        outZip = candidateZip;
        Log("GITHUB_WEB_OK", "Resolved & verified tag=" + outTag + " zip=" + outZip);
        return true;
      } catch (Exception ex) {
        outErr = ex.Message;
        Log("GITHUB_WEB_ERR", ex.Message);
        return false;
      }
    }

    static string ExtractDigestForUrl(string json, string targetUrl) {
      if (string.IsNullOrEmpty(json) || string.IsNullOrEmpty(targetUrl)) return "";
      int uIdx = json.IndexOf(targetUrl, StringComparison.OrdinalIgnoreCase);
      if (uIdx < 0) return "";
      int winStart = Math.Max(0, uIdx - 600);
      int winLen = Math.Min(json.Length - winStart, 1200);
      string slice = json.Substring(winStart, winLen);
      string raw = ExtractJsonStr(slice, "digest");
      if (raw.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase)) return raw.Substring(7).Trim().ToLowerInvariant();
      return "";
    }

    static void CheckGithubLatest() {
      string tag = "", zip = "", apiErr = "", sha = "";
      try {
        string json = HttpGetString("https://api.github.com/repos/" + RepoOwner + "/" + RepoName + "/releases/latest");
        tag = ExtractJsonStr(json, "tag_name");
        zip = ExtractZipUrl(json);
        sha = ExtractDigestForUrl(json, zip);
        if (string.IsNullOrEmpty(zip)) {
          Log("GITHUB", "No zip in /releases/latest; checking /releases?per_page=10");
          string listJson = HttpGetString("https://api.github.com/repos/" + RepoOwner + "/" + RepoName + "/releases?per_page=10");
          zip = ExtractZipUrl(listJson);
          sha = ExtractDigestForUrl(listJson, zip);
          if (string.IsNullOrEmpty(tag)) tag = ExtractJsonStr(listJson, "tag_name");
        }
      } catch (Exception ex) {
        apiErr = ex.Message;
        Log("GITHUB_API_WARN", "API failed (" + apiErr + "), trying web redirect fallback...");
      }
      ExpectedZipSha256 = sha;
      if (string.IsNullOrEmpty(tag) || string.IsNullOrEmpty(zip)) {
        string wTag, wZip, wErr;
        if (TryGithubWebRedirect(out wTag, out wZip, out wErr)) {
          tag = wTag; zip = wZip; apiErr = "";
          try {
            string tagJson = HttpGetString("https://api.github.com/repos/" + RepoOwner + "/" + RepoName + "/releases/tags/" + Uri.EscapeDataString(wTag));
            string tagSha = ExtractDigestForUrl(tagJson, wZip);
            if (IsValidSha256Hex(tagSha)) ExpectedZipSha256 = tagSha;
          } catch {}
        } else if (string.IsNullOrEmpty(apiErr)) {
          apiErr = wErr;
        }
      }
      LatestVersion = tag.StartsWith("v", StringComparison.OrdinalIgnoreCase) ? tag.Substring(1) : tag;
      ZipDownloadUrl = zip;
      IsOnline = !string.IsNullOrEmpty(LatestVersion) && !string.IsNullOrEmpty(ZipDownloadUrl);
      LastError = IsOnline ? "" : (!string.IsNullOrEmpty(apiErr) ? apiErr : "ZIP asset not found in latest GitHub Release.");
      Log("GITHUB_RES", "Latest=" + LatestVersion + " | Zip=" + ZipDownloadUrl + " | Online=" + IsOnline);
    }

    static string ExtractJsonStr(string json, string key) {
      string pat = "\"" + key + "\"";
      int idx = json.IndexOf(pat, StringComparison.OrdinalIgnoreCase);
      if (idx < 0) return "";
      int colon = json.IndexOf(':', idx + pat.Length);
      if (colon < 0) return "";
      int q1 = json.IndexOf('"', colon + 1);
      int q2 = q1 >= 0 ? json.IndexOf('"', q1 + 1) : -1;
      return (q1 >= 0 && q2 > q1) ? json.Substring(q1 + 1, q2 - q1 - 1) : "";
    }

    static string ExtractZipUrl(string json) {
      int pos = 0;
      string fallback = "";
      string pat = "\"browser_download_url\"";
      while (true) {
        int idx = json.IndexOf(pat, pos, StringComparison.OrdinalIgnoreCase);
        if (idx < 0) break;
        int colon = json.IndexOf(':', idx + pat.Length);
        int q1 = colon >= 0 ? json.IndexOf('"', colon + 1) : -1;
        int q2 = q1 >= 0 ? json.IndexOf('"', q1 + 1) : -1;
        if (q1 >= 0 && q2 > q1) {
          string u = json.Substring(q1 + 1, q2 - q1 - 1);
          if (u.StartsWith("https://", StringComparison.OrdinalIgnoreCase) && u.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) {
            if (u.IndexOf("Repage_SteamGrid_", StringComparison.OrdinalIgnoreCase) >= 0) return u;
            if (string.IsNullOrEmpty(fallback)) fallback = u;
          }
        }
        pos = (q2 > idx) ? (q2 + 1) : (idx + pat.Length);
      }
      return fallback;
    }

    static string EscapeJson(string s) {
      if (string.IsNullOrEmpty(s)) return "";
      return s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "").Replace("\n", "\\n");
    }

    static void ClearReadOnlyRecursive(string dir) {
      if (!Directory.Exists(dir)) return;
      try {
        foreach (string f in Directory.GetFiles(dir, "*", SearchOption.AllDirectories)) {
          try { File.SetAttributes(f, FileAttributes.Normal); } catch {}
        }
        foreach (string d in Directory.GetDirectories(dir, "*", SearchOption.AllDirectories)) {
          try { File.SetAttributes(d, FileAttributes.Normal); } catch {}
        }
      } catch {}
    }

    static void SafeCleanDirectoryContents(string dir) {
      if (!Directory.Exists(dir)) return;
      ClearReadOnlyRecursive(dir);
      foreach (string f in Directory.GetFiles(dir, "*", SearchOption.AllDirectories)) {
        try { File.SetAttributes(f, FileAttributes.Normal); File.Delete(f); }
        catch (Exception ex) { Log("CLEAN_WARN", "Could not delete file " + f + ": " + ex.Message); }
      }
    }

    static void CopyDirectoryRecursive(string srcDir, string dstDir) {
      Directory.CreateDirectory(dstDir);
      foreach (string f in Directory.GetFiles(srcDir)) {
        string destFile = Path.Combine(dstDir, Path.GetFileName(f));
        if (File.Exists(destFile)) { try { File.SetAttributes(destFile, FileAttributes.Normal); } catch {} }
        File.Copy(f, destFile, true);
      }
      foreach (string d in Directory.GetDirectories(srcDir)) {
        CopyDirectoryRecursive(d, Path.Combine(dstDir, Path.GetFileName(d)));
      }
    }

    static bool IsFileLockedException(Exception ex) {
      if (ex == null) return false;
      string m = (ex.Message ?? "").ToLowerInvariant();
      if (m.Contains("err_install_locked") || m.Contains("err_uninstall_locked")) return true;
      int code = Marshal.GetHRForException(ex) & 0xFFFF;
      if (code == 32 || code == 33) return true;
      return m.Contains("being used by another process") || m.Contains("sendo usado por outro processo") || m.Contains("sharing violation");
    }

    static int CheckDirectoryLocks(string dir) {
      int locked = 0;
      if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) return 0;
      foreach (string f in Directory.GetFiles(dir, "*", SearchOption.AllDirectories)) {
        try {
          FileAttributes attrs = File.GetAttributes(f);
          if ((attrs & FileAttributes.ReadOnly) != 0) File.SetAttributes(f, attrs & ~FileAttributes.ReadOnly);
          using (FileStream fs = new FileStream(f, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) {}
        } catch (UnauthorizedAccessException uaEx) {
          if (IsFileLockedException(uaEx)) { locked++; Log("PRECHECK_LOCK", "Locked file: " + f); }
        } catch (Exception ex) {
          if (IsFileLockedException(ex)) {
            locked++;
            Log("PRECHECK_LOCK", "File in use: " + f + " (" + ex.Message + ")");
          }
        }
      }
      return locked;
    }

    static int CleanDirectoryCountFailures(string dir) {
      int failed = 0;
      if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) return 0;
      try { ClearReadOnlyRecursive(dir); } catch {}
      foreach (string f in Directory.GetFiles(dir, "*", SearchOption.AllDirectories)) {
        try { File.SetAttributes(f, FileAttributes.Normal); File.Delete(f); }
        catch (Exception ex) { failed++; Log("CLEAN_LOCK", "Failed to remove " + f + ": " + ex.Message); }
      }
      string[] dirs = Directory.GetDirectories(dir, "*", SearchOption.AllDirectories);
      Array.Sort(dirs, (a, b) => b.Length.CompareTo(a.Length));
      foreach (string d in dirs) {
        try { Directory.Delete(d, false); } catch {}
      }
      return failed;
    }

    static string ComputeFileSha256(string filePath) {
      using (var sha = System.Security.Cryptography.SHA256.Create())
      using (FileStream sfs = new FileStream(filePath, FileMode.Open, FileAccess.Read)) {
        byte[] hash = sha.ComputeHash(sfs);
        StringBuilder hsb = new StringBuilder();
        foreach (byte b in hash) hsb.Append(b.ToString("x2"));
        return hsb.ToString();
      }
    }

    static string FindMillenniumConfigPath() {
      if (string.IsNullOrEmpty(SteamDir) || !Directory.Exists(SteamDir)) return null;
      string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
      string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
      string[] candidates = new string[] {
        Path.Combine(SteamDir, "millennium", "config", "config.json"),
        Path.Combine(SteamDir, "ext", "config.json"),
        Path.Combine(SteamDir, "ext", "data", "config.json"),
        !string.IsNullOrEmpty(appData) ? Path.Combine(appData, "Millennium", "config.json") : "",
        !string.IsNullOrEmpty(localAppData) ? Path.Combine(localAppData, "Millennium", "config.json") : ""
      };
      foreach (string c in candidates) { if (!string.IsNullOrEmpty(c) && File.Exists(c)) return c; }
      return null;
    }

    static string ResolveMillenniumConfigPathForWrite() {
      string existing = FindMillenniumConfigPath();
      if (!string.IsNullOrEmpty(existing)) return existing;
      if (string.IsNullOrEmpty(SteamDir) || !Directory.Exists(SteamDir)) return null;
      string millDir = Path.Combine(SteamDir, "millennium");
      if (Directory.Exists(millDir)) return Path.Combine(millDir, "config", "config.json");
      string extDir = Path.Combine(SteamDir, "ext");
      if (Directory.Exists(extDir)) return Path.Combine(extDir, "config.json");
      if (!string.IsNullOrEmpty(PluginsDir)) {
        string pParent = Path.GetDirectoryName(PluginsDir.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        if (!string.IsNullOrEmpty(pParent) && string.Equals(Path.GetFileName(pParent), "millennium", StringComparison.OrdinalIgnoreCase)) {
          return Path.Combine(pParent, "config", "config.json");
        }
      }
      return null;
    }

    static void GrantConfigAccessLeastPrivilege(string cfgPath, string ownerSid) {
      try {
        if (string.IsNullOrEmpty(cfgPath) || !File.Exists(cfgPath) || IsReparsePoint(cfgPath)) return;
        if (string.IsNullOrEmpty(ownerSid) || ownerSid == "none") return;
        string cfgDir = Path.GetDirectoryName(cfgPath);
        if (!string.IsNullOrEmpty(cfgDir) && !IsReparsePoint(cfgDir) && string.Equals(Path.GetFileName(cfgDir), "config", StringComparison.OrdinalIgnoreCase)) {
          GrantOwnerModifyPermission(cfgDir, ownerSid);
          return;
        }
        var sid = new System.Security.Principal.SecurityIdentifier(ownerSid);
        var fs = File.GetAccessControl(cfgPath);
        fs.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(sid, System.Security.AccessControl.FileSystemRights.Modify, System.Security.AccessControl.AccessControlType.Allow));
        File.SetAccessControl(cfgPath, fs);
        Log("ACL_OK", "Granted file-only Modify permission on " + cfgPath);
      } catch (Exception ex) {
        Log("ACL_WARN", "Could not update config ACL on " + cfgPath + ": " + ex.Message);
      }
    }

    static void SkipJsonWs(string s, ref int i) {
      while (i < s.Length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n')) i++;
    }

    static bool ParseJsonStr(string s, ref int i) {
      if (i >= s.Length || s[i] != '"') return false;
      i++;
      while (i < s.Length) {
        char c = s[i++];
        if (c == '"') return true;
        if (c < 0x20) return false;
        if (c == '\\') {
          if (i >= s.Length) return false;
          char e = s[i++];
          if (e == '"' || e == '\\' || e == '/' || e == 'b' || e == 'f' || e == 'n' || e == 'r' || e == 't') continue;
          if (e == 'u') {
            if (i + 4 > s.Length) return false;
            for (int k = 0; k < 4; k++) {
              char h = s[i++];
              bool ok = (h >= '0' && h <= '9') || (h >= 'a' && h <= 'f') || (h >= 'A' && h <= 'F');
              if (!ok) return false;
            }
            continue;
          }
          return false;
        }
      }
      return false;
    }

    static bool ParseJsonNum(string s, ref int i) {
      if (i < s.Length && s[i] == '-') i++;
      if (i >= s.Length) return false;
      if (s[i] == '0') { i++; } else if (s[i] >= '1' && s[i] <= '9') { while (i < s.Length && s[i] >= '0' && s[i] <= '9') i++; } else return false;
      if (i < s.Length && s[i] == '.') {
        i++; if (i >= s.Length || s[i] < '0' || s[i] > '9') return false;
        while (i < s.Length && s[i] >= '0' && s[i] <= '9') i++;
      }
      if (i < s.Length && (s[i] == 'e' || s[i] == 'E')) {
        i++; if (i < s.Length && (s[i] == '+' || s[i] == '-')) i++;
        if (i >= s.Length || s[i] < '0' || s[i] > '9') return false;
        while (i < s.Length && s[i] >= '0' && s[i] <= '9') i++;
      }
      return true;
    }

    static bool ParseJsonVal(string s, ref int i, int depth) {
      if (depth > 32) return false;
      SkipJsonWs(s, ref i);
      if (i >= s.Length) return false;
      char c = s[i];
      if (c == '{') return ParseJsonObj(s, ref i, depth + 1);
      if (c == '[') return ParseJsonArr(s, ref i, depth + 1);
      if (c == '"') return ParseJsonStr(s, ref i);
      if (c == '-' || (c >= '0' && c <= '9')) return ParseJsonNum(s, ref i);
      if (i + 4 <= s.Length && s.Substring(i, 4) == "true") { i += 4; return true; }
      if (i + 5 <= s.Length && s.Substring(i, 5) == "false") { i += 5; return true; }
      if (i + 4 <= s.Length && s.Substring(i, 4) == "null") { i += 4; return true; }
      return false;
    }

    static bool ParseJsonArr(string s, ref int i, int depth) {
      if (i >= s.Length || s[i] != '[') return false;
      i++; SkipJsonWs(s, ref i);
      if (i < s.Length && s[i] == ']') { i++; return true; }
      while (i < s.Length) {
        if (!ParseJsonVal(s, ref i, depth)) return false;
        SkipJsonWs(s, ref i);
        if (i < s.Length && s[i] == ',') { i++; continue; }
        if (i < s.Length && s[i] == ']') { i++; return true; }
        return false;
      }
      return false;
    }

    static bool ParseJsonObj(string s, ref int i, int depth) {
      if (i >= s.Length || s[i] != '{') return false;
      i++; SkipJsonWs(s, ref i);
      if (i < s.Length && s[i] == '}') { i++; return true; }
      while (i < s.Length) {
        SkipJsonWs(s, ref i);
        if (!ParseJsonStr(s, ref i)) return false;
        SkipJsonWs(s, ref i);
        if (i >= s.Length || s[i] != ':') return false;
        i++;
        if (!ParseJsonVal(s, ref i, depth)) return false;
        SkipJsonWs(s, ref i);
        if (i < s.Length && s[i] == ',') { i++; continue; }
        if (i < s.Length && s[i] == '}') { i++; return true; }
        return false;
      }
      return false;
    }

    static bool IsValidJsonObject(string s) {
      if (string.IsNullOrEmpty(s)) return false;
      int i = 0; SkipJsonWs(s, ref i);
      if (i >= s.Length || s[i] != '{') return false;
      if (!ParseJsonObj(s, ref i, 0)) return false;
      SkipJsonWs(s, ref i);
      return i == s.Length;
    }

    static bool FindJsonKeyInObject(string s, int objStart, string targetKey, out int valStart, out int valEnd) {
      valStart = -1; valEnd = -1;
      int i = objStart;
      SkipJsonWs(s, ref i);
      if (i >= s.Length || s[i] != '{') return false;
      i++; SkipJsonWs(s, ref i);
      if (i < s.Length && s[i] == '}') return false;
      while (i < s.Length) {
        SkipJsonWs(s, ref i);
        int ks = i;
        if (!ParseJsonStr(s, ref i)) return false;
        string keyName = s.Substring(ks + 1, i - ks - 2);
        SkipJsonWs(s, ref i);
        if (i >= s.Length || s[i] != ':') return false;
        i++; SkipJsonWs(s, ref i);
        int vs = i;
        if (!ParseJsonVal(s, ref i, 0)) return false;
        int ve = i;
        if (string.Equals(keyName, targetKey, StringComparison.OrdinalIgnoreCase)) {
          valStart = vs; valEnd = ve; return true;
        }
        SkipJsonWs(s, ref i);
        if (i < s.Length && s[i] == ',') { i++; continue; }
        return false;
      }
      return false;
    }

    static bool BytesEqual(byte[] a, byte[] b) {
      if (a == null || b == null || a.Length != b.Length) return false;
      for (int i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
      return true;
    }

    static bool IsPluginEnabledInMillennium() {
      try {
        string cfgPath = FindMillenniumConfigPath();
        if (string.IsNullOrEmpty(cfgPath)) return false;
        if (new FileInfo(cfgPath).Length > 4 * 1024 * 1024) return false;
        string raw = File.ReadAllText(cfgPath, Encoding.UTF8).TrimStart('\uFEFF');
        if (!IsValidJsonObject(raw)) return false;
        int rootObj = raw.IndexOf('{'), ps, pe, es = -1, ee = -1;
        bool foundArr = false;
        if (FindJsonKeyInObject(raw, rootObj, "plugins", out ps, out pe)) foundArr = FindJsonKeyInObject(raw, ps, "enabledPlugins", out es, out ee);
        if (!foundArr) foundArr = FindJsonKeyInObject(raw, rootObj, "enabledPlugins", out es, out ee);
        if (!foundArr) return false;
        string arrSlice = raw.Substring(es, ee - es);
        var itemRx = new System.Text.RegularExpressions.Regex("\"([^\"]+)\"");
        foreach (System.Text.RegularExpressions.Match im in itemRx.Matches(arrSlice)) {
          if (string.Equals(im.Groups[1].Value, "repage-steamgrid", StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
      } catch { return false; }
    }

    static string MapElevatedInstallExitCode(int exitCode) {
      if (exitCode == -3) return "ERR_ELEVATION_CANCELLED";
      if (exitCode == 3) return "ERR_INSTALL_LOCKED";
      return "ERR_INSTALL_FAILED";
    }

    static bool CanWriteToDirectory(string dirPath) {
      try {
        string probeDir = dirPath;
        while (!string.IsNullOrEmpty(probeDir) && !Directory.Exists(probeDir)) {
          probeDir = Path.GetDirectoryName(probeDir);
        }
        if (string.IsNullOrEmpty(probeDir) || !Directory.Exists(probeDir)) return false;
        string testFile = Path.Combine(probeDir, ".repage_wtest_" + Guid.NewGuid().ToString("N").Substring(0, 6) + ".tmp");
        File.WriteAllText(testFile, "1");
        File.Delete(testFile);
        return true;
      } catch {
        return false;
      }
    }

    static bool IsValidSha256Hex(string sha) {
      if (string.IsNullOrEmpty(sha) || sha.Length != 64) return false;
      for (int i = 0; i < sha.Length; i++) {
        char c = sha[i];
        bool ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
        if (!ok) return false;
      }
      return true;
    }

    static bool IsReparsePoint(string path) {
      try {
        if (string.IsNullOrEmpty(path)) return false;
        if (File.Exists(path) || Directory.Exists(path)) {
          return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
        }
      } catch { return true; }
      return false;
    }

    static bool IsAllowedGithubDownloadUrl(string url, bool allowAssetHost) {
      try {
        Uri u;
        if (!Uri.TryCreate(url, UriKind.Absolute, out u)) return false;
        if (!string.Equals(u.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)) return false;
        string host = (u.Host ?? "").ToLowerInvariant();
        if (host == "github.com") {
          return u.AbsolutePath.StartsWith("/" + RepoOwner + "/" + RepoName + "/releases/download/", StringComparison.OrdinalIgnoreCase);
        }
        if (allowAssetHost && host.EndsWith(".githubusercontent.com", StringComparison.OrdinalIgnoreCase)) return true;
      } catch {}
      return false;
    }

    static bool IsValidElevatedPluginTarget(string dstTarget, string steamRoot, out string reason) {
      reason = "";
      try {
        if (string.IsNullOrEmpty(dstTarget) || string.IsNullOrEmpty(steamRoot)) { reason = "empty_arg"; return false; }
        string fullTarget = Path.GetFullPath(dstTarget).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        string fullSteam = Path.GetFullPath(steamRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        string folderName = Path.GetFileName(fullTarget);
        if (!string.Equals(folderName, "repage-steamgrid", StringComparison.OrdinalIgnoreCase)) { reason = "invalid_folder_name"; return false; }
        string parentDir = Path.GetDirectoryName(fullTarget);
        if (string.IsNullOrEmpty(parentDir) || !string.Equals(Path.GetFileName(parentDir), "plugins", StringComparison.OrdinalIgnoreCase)) { reason = "invalid_parent_dir"; return false; }
        string grandParent = Path.GetDirectoryName(parentDir) ?? "";
        if (string.IsNullOrEmpty(grandParent) || string.Equals(grandParent.TrimEnd(Path.DirectorySeparatorChar), Path.GetPathRoot(fullTarget).TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase)) {
          reason = "drive_root_blocked"; return false;
        }
        string lowTarget = fullTarget.ToLowerInvariant();
        string winDir = (Environment.GetFolderPath(Environment.SpecialFolder.Windows) ?? "").ToLowerInvariant();
        string progData = (Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData) ?? "").ToLowerInvariant();
        if ((!string.IsNullOrEmpty(winDir) && lowTarget.StartsWith(winDir)) || (!string.IsNullOrEmpty(progData) && lowTarget.StartsWith(progData)) || lowTarget.Contains("\\system32\\") || lowTarget.Contains("\\syswow64\\")) {
          reason = "system_dir_blocked"; return false;
        }
        if (IsReparsePoint(fullSteam) || IsReparsePoint(parentDir) || IsReparsePoint(fullTarget)) { reason = "reparse_point_blocked"; return false; }
        if (!Directory.Exists(fullSteam) || !File.Exists(Path.Combine(fullSteam, "steam.exe"))) { reason = "steam_exe_missing"; return false; }
        string allowed1 = Path.GetFullPath(Path.Combine(fullSteam, "plugins")).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        string allowed2 = Path.GetFullPath(Path.Combine(fullSteam, "millennium", "plugins")).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        bool underSteam = string.Equals(parentDir, allowed1, StringComparison.OrdinalIgnoreCase) || string.Equals(parentDir, allowed2, StringComparison.OrdinalIgnoreCase);
        bool hasRealCtx = Directory.Exists(parentDir) && (File.Exists(Path.Combine(grandParent, "steam.exe")) || File.Exists(Path.Combine(grandParent, "millennium.dll")) || File.Exists(Path.Combine(grandParent, "config", "config.json")));
        if (!underSteam && !hasRealCtx) { reason = "outside_steam_plugins"; return false; }
        return true;
      } catch (Exception ex) {
        reason = ex.Message;
        return false;
      }
    }

    static int ExtractAndVerifyZipToDir(string zipPath, string expectedSha256, string destDir, out string outZipSha256) {
      if (!IsValidSha256Hex(expectedSha256)) {
        Log("SHA256_MISSING", "Refusing unverified ZIP extraction: official release SHA-256 digest unavailable.");
        throw new Exception("ERR_SHA256_MISSING");
      }
      if (IsReparsePoint(zipPath)) throw new Exception("ERR_INVALID_ZIP");
      byte[] headBytes = new byte[4];
      using (FileStream pfs = new FileStream(zipPath, FileMode.Open, FileAccess.Read)) {
        if (pfs.Length > MaxZipDownloadBytes) throw new Exception("ERR_DOWNLOAD_TOO_LARGE");
        if (pfs.Length < 10240 || pfs.Read(headBytes, 0, 4) < 4 || headBytes[0] != 0x50 || headBytes[1] != 0x4B || headBytes[2] != 0x03 || headBytes[3] != 0x04) {
          throw new Exception("ERR_INVALID_ZIP");
        }
      }
      outZipSha256 = ComputeFileSha256(zipPath);
      if (!string.Equals(outZipSha256, expectedSha256, StringComparison.OrdinalIgnoreCase)) {
        throw new Exception("ERR_SHA256_MISMATCH");
      }
      Log("SHA256_OK", "Verified SHA-256: " + outZipSha256);
      if (Directory.Exists(destDir)) { SafeCleanDirectoryContents(destDir); try { Directory.Delete(destDir, true); } catch {} }
      Directory.CreateDirectory(destDir);
      string fullPrefix = Path.GetFullPath(destDir).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
      int extractedCount = 0;
      int entryCount = 0;
      long actualExtractedTotal = 0;
      using (ZipArchive za = ZipFile.OpenRead(zipPath)) {
        foreach (ZipArchiveEntry entry in za.Entries) {
          if (++entryCount > MaxZipEntries) throw new Exception("ERR_INVALID_ZIP");
          if (entry.Length < 0 || entry.Length > MaxZipExtractedBytes) throw new Exception("ERR_DOWNLOAD_TOO_LARGE");
          string fullName = entry.FullName.Replace('\\', '/').TrimStart('/');
          if (string.IsNullOrEmpty(fullName) || fullName.EndsWith("/")) continue;
          if (fullName.StartsWith("repage-steamgrid/", StringComparison.OrdinalIgnoreCase)) {
            fullName = fullName.Substring("repage-steamgrid/".Length);
          }
          if (string.IsNullOrEmpty(fullName) || fullName.Contains(":")) continue;
          string destPath = Path.GetFullPath(Path.Combine(destDir, fullName.Replace('/', Path.DirectorySeparatorChar)));
          if (!destPath.StartsWith(fullPrefix, StringComparison.OrdinalIgnoreCase)) {
            throw new Exception("Blocked unsafe path in ZIP archive: " + entry.FullName);
          }
          string destParent = Path.GetDirectoryName(destPath);
          if (!string.IsNullOrEmpty(destParent)) Directory.CreateDirectory(destParent);
          using (Stream es = entry.Open())
          using (FileStream outFs = new FileStream(destPath, FileMode.Create, FileAccess.Write)) {
            byte[] xBuf = new byte[16384];
            int xr;
            while ((xr = es.Read(xBuf, 0, xBuf.Length)) > 0) {
              actualExtractedTotal += xr;
              if (actualExtractedTotal > MaxZipExtractedBytes) throw new Exception("ERR_DOWNLOAD_TOO_LARGE");
              outFs.Write(xBuf, 0, xr);
            }
          }
          extractedCount++;
        }
      }
      if (!File.Exists(Path.Combine(destDir, "plugin.json")) ||
          !File.Exists(Path.Combine(destDir, "backend", "main.lua")) ||
          !File.Exists(Path.Combine(destDir, ".millennium", "dist", "index.js"))) {
        throw new Exception("ERR_MISSING_FILES");
      }
      return extractedCount;
    }

    static void RunInstallWorker(bool cleanFirst) {
      InstallStatus = "running";
      InstallPercent = 6;
      InstallStepCode = "connecting";
      DownloadedKb = 0;
      LastError = "";
      string txId = Guid.NewGuid().ToString("N").Substring(0, 6);
      string tmpZip = Path.Combine(Path.GetTempPath(), "Repage_Install_" + txId + ".zip");
      string stageDir = "";
      string backupDir = "";
      Log("INSTALL", "Starting transactional install worker (cleanFirst=" + cleanFirst + ", tx=" + txId + ")");
      try {
        if (string.IsNullOrEmpty(ZipDownloadUrl) || !IsValidSha256Hex(ExpectedZipSha256)) CheckGithubLatest();
        if (!IsOnline || string.IsNullOrEmpty(ZipDownloadUrl)) throw new Exception("Could not fetch release package URL from GitHub.");
        if (!IsValidSha256Hex(ExpectedZipSha256)) throw new Exception("ERR_SHA256_MISSING");
        if (!IsAllowedGithubDownloadUrl(ZipDownloadUrl, false)) throw new Exception("ERR_UNTRUSTED_TARGET");
        string basePlugins = !string.IsNullOrEmpty(PluginsDir) ? PluginsDir : Path.Combine(SteamDir, "plugins");
        if (string.IsNullOrEmpty(SteamDir) || !Directory.Exists(SteamDir)) throw new Exception("ERR_INVALID_STEAM");

        Log("DOWNLOAD", "Downloading " + ZipDownloadUrl + " -> " + tmpZip);
        HttpWebRequest req = (HttpWebRequest)WebRequest.Create(ZipDownloadUrl);
        req.UserAgent = UserAgentStr;
        req.AllowAutoRedirect = true;
        req.MaximumAutomaticRedirections = 5;
        req.Timeout = 35000;
        using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse()) {
          if (resp.ResponseUri == null || !IsAllowedGithubDownloadUrl(resp.ResponseUri.AbsoluteUri, true)) {
            throw new Exception("ERR_UNTRUSTED_TARGET");
          }
          if (resp.ContentLength > MaxZipDownloadBytes) {
            Log("DOWNLOAD_ERR", "ContentLength exceeds 32 MB limit: " + resp.ContentLength);
            throw new Exception("ERR_DOWNLOAD_TOO_LARGE");
          }
          using (Stream rs = resp.GetResponseStream())
          using (FileStream fs = new FileStream(tmpZip, FileMode.Create, FileAccess.Write)) {
            long total = resp.ContentLength > 0 ? resp.ContentLength : 450000;
            byte[] buf = new byte[16384];
            long readSum = 0;
            int r;
            while ((r = rs.Read(buf, 0, buf.Length)) > 0) {
              if (readSum + r > MaxZipDownloadBytes) {
                Log("DOWNLOAD_ERR", "Streaming download exceeded 32 MB limit.");
                throw new Exception("ERR_DOWNLOAD_TOO_LARGE");
              }
              fs.Write(buf, 0, r);
              readSum += r;
              DownloadedKb = readSum / 1024;
              InstallStepCode = "downloading";
              InstallPercent = 8 + (int)Math.Min(66, (readSum * 66) / Math.Max(1, total));
            }
            Log("DOWNLOAD_OK", "Downloaded " + readSum + " bytes");
          }
        }

        InstallPercent = 82;
        InstallStepCode = "extracting";
        string targetPluginDir = Path.Combine(basePlugins, "repage-steamgrid");
        stageDir = Path.Combine(Path.GetTempPath(), "Repage_Stage_" + txId);
        backupDir = Path.Combine(Path.GetTempPath(), "Repage_Bak_" + txId);

        string verifiedZipSha = "";
        int extractedCount = ExtractAndVerifyZipToDir(tmpZip, ExpectedZipSha256, stageDir, out verifiedZipSha);
        Log("STAGE_OK", "Staged & verified " + extractedCount + " files in " + stageDir);

        bool hadExisting = Directory.Exists(targetPluginDir);
        bool directWritable = hadExisting ? CanWriteToDirectory(targetPluginDir) : CanWriteToDirectory(basePlugins);
        bool usedElevation = false;
        string ownerSid = "";
        try { var id = System.Security.Principal.WindowsIdentity.GetCurrent(); if (id != null && id.User != null) ownerSid = id.User.Value; } catch {}
        string sidArg = string.IsNullOrEmpty(ownerSid) ? "none" : ownerSid;

        if (!directWritable) {
          Log("UAC_ELEVATE", "Target requires administrator access; requesting UAC elevation before modifying files...");
          usedElevation = true;
          string elArgs = "--elevated-install \"" + tmpZip + "\" \"" + verifiedZipSha + "\" \"" + targetPluginDir + "\" \"" + SteamDir + "\" " + (cleanFirst ? "1" : "0") + " \"" + sidArg + "\"";
          int exitCode = RunElevatedSelf(elArgs);
          if (exitCode != 0) throw new Exception(MapElevatedInstallExitCode(exitCode));
          DidUninstallThisSession = false;
          AutoEnabledInConfig = IsPluginEnabledInMillennium();
          if (!hadExisting) DidAutoEnableThisSession = true;
        } else {
          if (hadExisting && CheckDirectoryLocks(targetPluginDir) > 0) {
            throw new Exception("ERR_INSTALL_LOCKED");
          }
          if (hadExisting) {
            if (Directory.Exists(backupDir)) { SafeCleanDirectoryContents(backupDir); try { Directory.Delete(backupDir, true); } catch {} }
            try { CopyDirectoryRecursive(targetPluginDir, backupDir); } catch (Exception bkEx) { Log("BACKUP_WARN", bkEx.Message); }
          }
          try {
            Directory.CreateDirectory(targetPluginDir);
            if (cleanFirst && hadExisting) {
              int lockCount = CleanDirectoryCountFailures(targetPluginDir);
              if (lockCount > 0) throw new IOException("ERR_INSTALL_LOCKED");
            }
            CopyDirectoryRecursive(stageDir, targetPluginDir);
            GrantOwnerModifyPermission(targetPluginDir, ownerSid);
          } catch (UnauthorizedAccessException uaEx) {
            if (IsFileLockedException(uaEx)) {
              Log("INSTALL_LOCKED", "Access denied due to locked file: " + uaEx.Message);
              if (hadExisting && Directory.Exists(backupDir)) {
                try { CopyDirectoryRecursive(backupDir, targetPluginDir); Log("ROLLBACK_OK", "Restored backup after lock"); }
                catch (Exception rbEx) { Log("ROLLBACK_ERR", rbEx.Message); }
              }
              throw new Exception("ERR_INSTALL_LOCKED");
            }
            Log("UAC_ELEVATE", "Direct write denied (" + uaEx.Message + "); requesting UAC elevation...");
            usedElevation = true;
            string elArgs = "--elevated-install \"" + tmpZip + "\" \"" + verifiedZipSha + "\" \"" + targetPluginDir + "\" \"" + SteamDir + "\" " + (cleanFirst ? "1" : "0") + " \"" + sidArg + "\"";
            int exitCode = RunElevatedSelf(elArgs);
            if (exitCode != 0) {
              if (hadExisting && Directory.Exists(backupDir)) {
                try { CopyDirectoryRecursive(backupDir, targetPluginDir); Log("ROLLBACK_OK", "Restored backup after elevation error " + exitCode); }
                catch (Exception rbEx) { Log("ROLLBACK_ERR", rbEx.Message); }
              }
              throw new Exception(MapElevatedInstallExitCode(exitCode));
            }
          } catch (Exception applyEx) {
            Log("ROLLBACK", "Apply failed (" + applyEx.Message + "), restoring from backup...");
            if (hadExisting && Directory.Exists(backupDir)) {
              try { CopyDirectoryRecursive(backupDir, targetPluginDir); Log("ROLLBACK_OK", "Restored backup cleanly"); }
              catch (Exception rbEx) { Log("ROLLBACK_ERR", rbEx.Message); }
            }
            if (IsFileLockedException(applyEx)) throw new Exception("ERR_INSTALL_LOCKED");
            throw new Exception("ERR_INSTALL_FAILED");
          }
          if (hadExisting) {
            AutoEnabledInConfig = IsPluginEnabledInMillennium();
            Log("MILL_CFG", "Update preserved existing Millennium enabledPlugins=" + AutoEnabledInConfig);
          } else {
            DidUninstallThisSession = false;
            DidAutoEnableThisSession = true;
            SetPluginEnabledInMillennium(true);
            AutoEnabledInConfig = IsPluginEnabledInMillennium();
            Log("MILL_CFG", "Verified enabledPlugins in config.json=" + AutoEnabledInConfig);
          }
        }
        Log("EXTRACT_OK", "Promoted " + extractedCount + " files into " + targetPluginDir + " (elevated=" + usedElevation + ", autoEnabled=" + AutoEnabledInConfig + ")");
        DetectSteamAndMillennium(CustomSelectedPath);
        if (string.IsNullOrEmpty(InstalledVersion)) {
          throw new Exception("ERR_MISSING_FILES");
        }
        InstallPercent = 100;
        InstallStepCode = "done";
        InstallStatus = "done";
      } catch (Exception ex) {
        LastError = ex.Message;
        InstallStatus = "error";
        Log("INSTALL_ERR", ex.GetType().Name + ": " + ex.Message + "\n" + ex.StackTrace);
      } finally {
        if (File.Exists(tmpZip)) { try { File.Delete(tmpZip); } catch {} }
        if (!string.IsNullOrEmpty(stageDir) && Directory.Exists(stageDir)) {
          SafeCleanDirectoryContents(stageDir);
          try { Directory.Delete(stageDir, true); } catch {}
        }
        if (!string.IsNullOrEmpty(backupDir) && Directory.Exists(backupDir)) {
          SafeCleanDirectoryContents(backupDir);
          try { Directory.Delete(backupDir, true); } catch {}
        }
      }
    }

    static bool SetPluginEnabledInMillennium(bool enable) {
      try {
        string cfgPath = enable ? ResolveMillenniumConfigPathForWrite() : FindMillenniumConfigPath();
        if (string.IsNullOrEmpty(cfgPath)) return !enable;
        string cfgDir = Path.GetDirectoryName(cfgPath);
        if (IsReparsePoint(SteamDir) || IsReparsePoint(cfgPath) || (!string.IsNullOrEmpty(cfgDir) && IsReparsePoint(cfgDir))) {
          Log("MILL_CFG_ERR", "Blocked reparse point on Millennium config path: " + cfgPath);
          return false;
        }
        try { if (File.Exists(cfgPath + ".repage_bak")) File.Delete(cfgPath + ".repage_bak"); } catch {}

        bool existed = File.Exists(cfgPath);
        byte[] origBytes = null;
        string updated = null;

        if (!existed) {
          if (!enable) return true;
          if (!string.IsNullOrEmpty(cfgDir)) Directory.CreateDirectory(cfgDir);
          updated = "{\n  \"plugins\": {\n    \"enabledPlugins\": [\n      \"repage-steamgrid\"\n    ]\n  }\n}\n";
          Log("MILL_CFG", "Preparing fresh Millennium config.json at " + cfgPath);
        } else {
          if (new FileInfo(cfgPath).Length > 4 * 1024 * 1024) {
            Log("MILL_CFG_ERR", "Refused oversized config.json (>4 MB)");
            return false;
          }
          origBytes = File.ReadAllBytes(cfgPath);
          string raw = File.ReadAllText(cfgPath, Encoding.UTF8).TrimStart('\uFEFF');
          if (!IsValidJsonObject(raw)) {
            Log("MILL_CFG_ERR", "Refused to modify malformed existing config.json");
            return false;
          }
          int rootObj = raw.IndexOf('{'), ps, pe, es = -1, ee = -1;
          bool hasPlugins = FindJsonKeyInObject(raw, rootObj, "plugins", out ps, out pe);
          bool hasEnabled = hasPlugins ? FindJsonKeyInObject(raw, ps, "enabledPlugins", out es, out ee) : FindJsonKeyInObject(raw, rootObj, "enabledPlugins", out es, out ee);
          if (hasEnabled) {
            string arrSlice = raw.Substring(es, ee - es).Trim();
            var items = new System.Collections.Generic.List<string>();
            if (arrSlice.StartsWith("[")) {
              var itemRx = new System.Text.RegularExpressions.Regex("\"([^\"]+)\"");
              foreach (System.Text.RegularExpressions.Match im in itemRx.Matches(arrSlice)) {
                string val = im.Groups[1].Value;
                if (!string.IsNullOrEmpty(val) && !items.Contains(val)) items.Add(val);
              }
            }
            bool has = items.Exists(x => string.Equals(x, "repage-steamgrid", StringComparison.OrdinalIgnoreCase));
            if (enable && has) return true;
            if (!enable && !has) return true;
            if (enable) items.Add("repage-steamgrid");
            else items.RemoveAll(x => string.Equals(x, "repage-steamgrid", StringComparison.OrdinalIgnoreCase));
            StringBuilder arr = new StringBuilder();
            if (items.Count == 0) {
              arr.Append("[]");
            } else {
              arr.Append("[\n");
              for (int i = 0; i < items.Count; i++) {
                arr.Append("      \"").Append(items[i]).Append("\"");
                if (i < items.Count - 1) arr.Append(",");
                arr.Append("\n");
              }
              arr.Append("    ]");
            }
            updated = raw.Substring(0, es) + arr.ToString() + raw.Substring(ee);
          } else if (hasPlugins) {
            string plugVal = raw.Substring(ps, pe - ps).Trim();
            if (!enable) return true;
            if (plugVal == "null") {
              updated = raw.Substring(0, ps) + "{\n    \"enabledPlugins\": [\n      \"repage-steamgrid\"\n    ]\n  }" + raw.Substring(pe);
            } else {
              int pOpen = raw.IndexOf('{', ps);
              if (pOpen < 0 || pOpen >= pe) return false;
              string pRest = raw.Substring(pOpen + 1, pe - (pOpen + 1)).Trim();
              string ins = pRest == "}" ? "\n    \"enabledPlugins\": [\n      \"repage-steamgrid\"\n    ]\n  " : "\n    \"enabledPlugins\": [\n      \"repage-steamgrid\"\n    ],";
              updated = raw.Substring(0, pOpen + 1) + ins + raw.Substring(pOpen + 1);
            }
          } else {
            if (!enable) return true;
            string rRest = raw.Substring(rootObj + 1).Trim();
            if (rRest == "}") {
              updated = "{\n  \"plugins\": {\n    \"enabledPlugins\": [\n      \"repage-steamgrid\"\n    ]\n  }\n}\n";
            } else {
              updated = raw.Substring(0, rootObj + 1) + "\n  \"plugins\": {\n    \"enabledPlugins\": [\n      \"repage-steamgrid\"\n    ]\n  }," + raw.Substring(rootObj + 1);
            }
          }
        }

        if (string.IsNullOrEmpty(updated) || !IsValidJsonObject(updated)) {
          Log("MILL_CFG_ERR", "Aborted write: generated config.json failed strict JSON validation!");
          return false;
        }
        byte[] outBytes = new UTF8Encoding(false).GetBytes(updated);
        string tmp = cfgPath + ".repage_tmp";
        for (int attempt = 0; attempt < 3; attempt++) {
          try {
            try {
              using (FileStream fs = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None)) {
                fs.Write(outBytes, 0, outBytes.Length);
                fs.Flush(true);
              }
              if (!BytesEqual(File.ReadAllBytes(tmp), outBytes)) throw new IOException("tmp_readback_mismatch");
              if (File.Exists(cfgPath)) File.Replace(tmp, cfgPath, null, true);
              else File.Move(tmp, cfgPath);
            } catch (UnauthorizedAccessException) {
              try { if (File.Exists(tmp)) File.Delete(tmp); } catch {}
              if (!existed) throw;
              try {
                using (FileStream fs = new FileStream(cfgPath, FileMode.Open, FileAccess.Write, FileShare.None)) {
                  fs.Seek(0, SeekOrigin.Begin);
                  fs.Write(outBytes, 0, outBytes.Length);
                  fs.SetLength(outBytes.Length);
                  fs.Flush(true);
                }
                if (!BytesEqual(File.ReadAllBytes(cfgPath), outBytes)) throw new IOException("direct_readback_mismatch");
              } catch {
                if (origBytes != null) {
                  try {
                    using (FileStream rfs = new FileStream(cfgPath, FileMode.Open, FileAccess.Write, FileShare.None)) {
                      rfs.Seek(0, SeekOrigin.Begin);
                      rfs.Write(origBytes, 0, origBytes.Length);
                      rfs.SetLength(origBytes.Length);
                      rfs.Flush(true);
                    }
                  } catch {}
                }
                throw;
              }
            }
            if (!BytesEqual(File.ReadAllBytes(cfgPath), outBytes)) throw new IOException("final_readback_mismatch");
            Log("MILL_CFG", "Safely updated & verified " + cfgPath + " (enable=" + enable + ")");
            return true;
          } catch (IOException ioEx) {
            try { if (File.Exists(tmp)) File.Delete(tmp); } catch {}
            if (attempt < 2) { Thread.Sleep(120); continue; }
            Log("MILL_CFG_ERR", "Atomic write failed after retries: " + ioEx.Message);
            return false;
          }
        }
        return false;
      } catch (Exception ex) {
        Log("MILL_CFG_ERR", ex.Message);
        return false;
      }
    }

    static void GrantOwnerModifyPermission(string dirPath, string ownerSid) {
      try {
        if (string.IsNullOrEmpty(dirPath) || !Directory.Exists(dirPath)) return;
        System.Security.Principal.SecurityIdentifier sid = null;
        if (!string.IsNullOrEmpty(ownerSid) && ownerSid != "none") {
          sid = new System.Security.Principal.SecurityIdentifier(ownerSid);
        } else {
          var id = System.Security.Principal.WindowsIdentity.GetCurrent();
          if (id != null) sid = id.User;
        }
        if (sid == null) return;
        var rule = new System.Security.AccessControl.FileSystemAccessRule(
          sid,
          System.Security.AccessControl.FileSystemRights.Modify,
          System.Security.AccessControl.InheritanceFlags.ContainerInherit | System.Security.AccessControl.InheritanceFlags.ObjectInherit,
          System.Security.AccessControl.PropagationFlags.None,
          System.Security.AccessControl.AccessControlType.Allow
        );
        var sec = Directory.GetAccessControl(dirPath);
        sec.AddAccessRule(rule);
        Directory.SetAccessControl(dirPath, sec);
      } catch {}
    }

    static int RunElevatedSelf(string arguments) {
      try {
        ProcessStartInfo psi = new ProcessStartInfo(Application.ExecutablePath, arguments);
        psi.UseShellExecute = true;
        psi.Verb = "runas";
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        using (Process p = Process.Start(psi)) {
          if (p == null) return -1;
          if (!p.WaitForExit(180000)) {
            Log("UAC_TIMEOUT", "Elevated helper did not exit within 180s and may still be running");
            return -2;
          }
          return p.ExitCode;
        }
      } catch (Exception ex) {
        Log("UAC_CANCEL", ex.Message);
        return -3;
      }
    }

    static int ExecuteElevatedInstall(string zipPath, string shaArg, string dstTarget, string steamRoot, bool cleanFirst, string ownerSid) {
      string elevId = Guid.NewGuid().ToString("N").Substring(0, 6);
      string elevStage = Path.Combine(Path.GetTempPath(), "Repage_ElevStage_" + elevId);
      string elevBak = Path.Combine(Path.GetTempPath(), "Repage_ElevBak_" + elevId);
      try {
        if (string.IsNullOrEmpty(zipPath) || !File.Exists(zipPath)) return 2;
        string fullZip = Path.GetFullPath(zipPath);
        string zipName = Path.GetFileName(fullZip);
        if (IsReparsePoint(fullZip) || !zipName.StartsWith("Repage_Install_", StringComparison.OrdinalIgnoreCase) || !zipName.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) {
          Log("ELEVATED_ERR", "Rejected untrusted zipPath: " + fullZip);
          return 2;
        }
        string targetReason;
        if (!IsValidElevatedPluginTarget(dstTarget, steamRoot, out targetReason)) {
          Log("ELEVATED_ERR", "Rejected untrusted dstTarget (" + targetReason + "): " + (dstTarget ?? ""));
          return 2;
        }
        if (!IsValidSha256Hex(shaArg)) {
          Log("ELEVATED_ERR", "Rejected missing or invalid SHA-256 argument in elevated install.");
          return 2;
        }
        SteamDir = Path.GetFullPath(steamRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        string unusedSha = "";
        ExtractAndVerifyZipToDir(fullZip, shaArg, elevStage, out unusedSha);
        bool hadExisting = Directory.Exists(dstTarget);
        if (hadExisting && CheckDirectoryLocks(dstTarget) > 0) {
          Log("ELEVATED_PRECHECK_LOCKED", "Locked files detected before clean/copy in " + dstTarget);
          return 3;
        }
        if (hadExisting) {
          try { CopyDirectoryRecursive(dstTarget, elevBak); } catch (Exception bkEx) { Log("ELEVATED_BACKUP_WARN", bkEx.Message); }
        }
        try {
          Directory.CreateDirectory(dstTarget);
          if (cleanFirst && hadExisting) {
            int lockCount = CleanDirectoryCountFailures(dstTarget);
            if (lockCount > 0) throw new IOException("ERR_INSTALL_LOCKED");
          }
          CopyDirectoryRecursive(elevStage, dstTarget);
          GrantOwnerModifyPermission(dstTarget, ownerSid);
          if (hadExisting) {
            Log("ELEVATED_MILL_CFG", "Update preserved existing Millennium enabledPlugins=" + IsPluginEnabledInMillennium());
          } else {
            bool cfgOk = SetPluginEnabledInMillennium(true);
            try { string cp = FindMillenniumConfigPath(); if (!string.IsNullOrEmpty(cp)) GrantConfigAccessLeastPrivilege(cp, ownerSid); } catch {}
            Log("ELEVATED_MILL_CFG", "Fresh install SetPluginEnabledInMillennium=" + cfgOk + ", verified=" + IsPluginEnabledInMillennium());
          }
          return 0;
        } catch (Exception applyEx) {
          Log("ELEVATED_ROLLBACK", "Elevated apply failed (" + applyEx.Message + "), restoring backup...");
          if (hadExisting && Directory.Exists(elevBak)) {
            try { CopyDirectoryRecursive(elevBak, dstTarget); Log("ELEVATED_ROLLBACK_OK", "Elevated backup restored cleanly"); }
            catch (Exception rbEx) { Log("ELEVATED_ROLLBACK_ERR", rbEx.Message); }
          }
          return IsFileLockedException(applyEx) ? 3 : 1;
        }
      } catch (Exception ex) {
        Log("ELEVATED_INSTALL_ERR", ex.Message);
        return IsFileLockedException(ex) ? 3 : 1;
      } finally {
        if (Directory.Exists(elevStage)) { SafeCleanDirectoryContents(elevStage); try { Directory.Delete(elevStage, true); } catch {} }
        if (Directory.Exists(elevBak)) { SafeCleanDirectoryContents(elevBak); try { Directory.Delete(elevBak, true); } catch {} }
      }
    }

    static int ExecuteElevatedUninstall(string steamRoot, string pluginsRoot, string ownerSid) {
      try {
        if (string.IsNullOrEmpty(steamRoot)) return 2;
        string fullSteam = Path.GetFullPath(steamRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (IsReparsePoint(fullSteam) || !Directory.Exists(fullSteam) || !File.Exists(Path.Combine(fullSteam, "steam.exe"))) {
          Log("ELEVATED_UNINSTALL_ERR", "Rejected untrusted steamRoot: " + fullSteam);
          return 2;
        }
        SteamDir = fullSteam;
        var candidateBases = new System.Collections.Generic.List<string>();
        if (!string.IsNullOrEmpty(pluginsRoot)) {
          string normP = Path.GetFullPath(pluginsRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
          string uninstReason;
          if (IsValidElevatedPluginTarget(Path.Combine(normP, "repage-steamgrid"), SteamDir, out uninstReason)) {
            candidateBases.Add(normP);
          } else {
            Log("ELEVATED_UNINSTALL_ERR", "Rejected untrusted pluginsRoot (" + uninstReason + "): " + normP);
          }
        }
        string p1 = Path.GetFullPath(Path.Combine(SteamDir, "plugins")).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        string p2 = Path.GetFullPath(Path.Combine(SteamDir, "millennium", "plugins")).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (!candidateBases.Contains(p1)) candidateBases.Add(p1);
        if (!candidateBases.Contains(p2)) candidateBases.Add(p2);
        PluginsDir = candidateBases.Count > 0 ? candidateBases[0] : p2;
        foreach (string bDir in candidateBases) {
          if (IsReparsePoint(bDir) || IsReparsePoint(Path.Combine(bDir, "repage-steamgrid"))) continue;
          if (string.IsNullOrEmpty(bDir)) continue;
          string target = Path.Combine(bDir, "repage-steamgrid");
          if (Directory.Exists(target) && CheckDirectoryLocks(target) > 0) {
            Log("ELEVATED_UNINSTALL_PRECHECK_LOCKED", "Locked files in " + target);
            return 3;
          }
        }
        SetPluginEnabledInMillennium(false);
        try { string cp = FindMillenniumConfigPath(); if (!string.IsNullOrEmpty(cp)) GrantConfigAccessLeastPrivilege(cp, ownerSid); } catch {}
        foreach (string bDir in candidateBases) {
          if (string.IsNullOrEmpty(bDir) || IsReparsePoint(bDir) || IsReparsePoint(Path.Combine(bDir, "repage-steamgrid"))) continue;
          string target = Path.Combine(bDir, "repage-steamgrid");
          if (Directory.Exists(target)) {
            int lockCount = CleanDirectoryCountFailures(target);
            try { Directory.Delete(target, true); } catch {}
            if (lockCount > 0 || Directory.Exists(target)) {
              Log("ELEVATED_UNINSTALL_LOCKED", "Remaining locked files in " + target);
              return 3;
            }
          }
        }
        return 0;
      } catch (Exception ex) {
        Log("ELEVATED_UNINSTALL_ERR", ex.Message);
        return IsFileLockedException(ex) ? 3 : 1;
      }
    }

    static string UninstallPlugin() {
      try {
        var candidateBases = new System.Collections.Generic.List<string>();
        if (!string.IsNullOrEmpty(PluginsDir)) candidateBases.Add(PluginsDir);
        if (!string.IsNullOrEmpty(SteamDir)) {
          string p1 = Path.Combine(SteamDir, "plugins");
          string p2 = Path.Combine(SteamDir, "millennium", "plugins");
          if (!candidateBases.Contains(p1)) candidateBases.Add(p1);
          if (!candidateBases.Contains(p2)) candidateBases.Add(p2);
        }
        bool needsElevation = false;
        foreach (string bDir in candidateBases) {
          if (string.IsNullOrEmpty(bDir)) continue;
          string target = Path.Combine(bDir, "repage-steamgrid");
          if (Directory.Exists(target) && string.Equals(Path.GetFileName(target), "repage-steamgrid", StringComparison.OrdinalIgnoreCase)) {
            if (!CanWriteToDirectory(bDir) || !CanWriteToDirectory(target)) {
              needsElevation = true;
            } else if (CheckDirectoryLocks(target) > 0) {
              DetectSteamAndMillennium(CustomSelectedPath);
              return "ERR_UNINSTALL_LOCKED";
            }
          }
        }
        if (!needsElevation) SetPluginEnabledInMillennium(false);
        foreach (string bDir in candidateBases) {
          if (string.IsNullOrEmpty(bDir)) continue;
          string target = Path.Combine(bDir, "repage-steamgrid");
          if (Directory.Exists(target) && string.Equals(Path.GetFileName(target), "repage-steamgrid", StringComparison.OrdinalIgnoreCase)) {
            Log("UNINSTALL", "Removing " + target);
            if (!CanWriteToDirectory(bDir) || !CanWriteToDirectory(target)) {
              needsElevation = true;
              continue;
            }
            try {
              int lockCount = CleanDirectoryCountFailures(target);
              if (lockCount > 0) {
                DetectSteamAndMillennium(CustomSelectedPath);
                return "ERR_UNINSTALL_LOCKED";
              }
              Directory.Delete(target, true);
            } catch (UnauthorizedAccessException) {
              needsElevation = true;
            } catch (Exception delEx) {
              Log("UNINSTALL_DEL_WARN", delEx.Message);
              if (IsFileLockedException(delEx)) {
                DetectSteamAndMillennium(CustomSelectedPath);
                return "ERR_UNINSTALL_LOCKED";
              }
            }
          }
        }
        if (needsElevation) {
          string uSid = "none";
          try { var id = System.Security.Principal.WindowsIdentity.GetCurrent(); if (id != null && id.User != null) uSid = id.User.Value; } catch {}
          Log("UNINSTALL_UAC", "Requesting UAC elevation for uninstall...");
          int code = RunElevatedSelf("--elevated-uninstall \"" + SteamDir + "\" \"" + PluginsDir + "\" \"" + uSid + "\"");
          if (code == -3) {
            DetectSteamAndMillennium(CustomSelectedPath);
            return "ERR_ELEVATION_CANCELLED";
          }
          if (code == 3) {
            DetectSteamAndMillennium(CustomSelectedPath);
            return "ERR_UNINSTALL_LOCKED";
          }
          if (code != 0) {
            DetectSteamAndMillennium(CustomSelectedPath);
            return "ERR_UNINSTALL_FAILED";
          }
        }
        foreach (string bDir in candidateBases) {
          if (string.IsNullOrEmpty(bDir)) continue;
          string target = Path.Combine(bDir, "repage-steamgrid");
          if (Directory.Exists(target)) {
            DetectSteamAndMillennium(CustomSelectedPath);
            return "ERR_UNINSTALL_LOCKED";
          }
        }
        SetPluginEnabledInMillennium(false);
        DidAutoEnableThisSession = false;
        DidUninstallThisSession = true;
        DetectSteamAndMillennium(CustomSelectedPath);
        InstalledVersion = "";
        Log("UNINSTALL_OK", "Removed repage-steamgrid cleanly (Millennium config cleaned)");
        return "";
      } catch (Exception ex) {
        Log("UNINSTALL_ERR", ex.Message);
        DetectSteamAndMillennium(CustomSelectedPath);
        return ex.Message;
      }
    }

    static void SendJson(HttpListenerResponse res, string json) {
      byte[] b = Encoding.UTF8.GetBytes(json);
      res.ContentType = "application/json; charset=utf-8";
      res.ContentLength64 = b.Length;
      res.OutputStream.Write(b, 0, b.Length);
      res.Close();
    }

    static string BuildStatusJson(bool picked) {
      string shownPath = !string.IsNullOrEmpty(PluginsDir) ? PluginsDir : SteamDir;
      return "{" +
        "\"picked\":" + (picked ? "true" : "false") + "," +
        "\"osLocale\":\"" + EscapeJson(OsLocale) + "\"," +
        "\"online\":" + (IsOnline ? "true" : "false") + "," +
        "\"steamRunning\":" + (IsSteamRunning() ? "true" : "false") + "," +
        "\"autoEnabled\":" + (AutoEnabledInConfig ? "true" : "false") + "," +
        "\"customFolder\":" + (!string.IsNullOrEmpty(CustomSelectedPath) ? "true" : "false") + "," +
        "\"steamPath\":\"" + EscapeJson(shownPath) + "\"," +
        "\"hasMillennium\":" + (HasMillennium ? "true" : "false") + "," +
        "\"installedVersion\":\"" + EscapeJson(InstalledVersion) + "\"," +
        "\"latestVersion\":\"" + EscapeJson(LatestVersion) + "\"," +
        "\"error\":\"" + EscapeJson(LastError) + "\"" +
      "}";
    }

    static void HandleHttpRequest(HttpListenerContext ctx) {
      try {
        HttpListenerRequest req = ctx.Request;
        HttpListenerResponse res = ctx.Response;
        string host = req.Url.Host ?? "";
        if (host != "127.0.0.1" && host != "localhost") {
          res.StatusCode = 403; res.Close(); return;
        }
        string p = req.Url.AbsolutePath;

        if (p == "/") {
          byte[] b = Encoding.UTF8.GetBytes(HtmlPayload);
          res.ContentType = "text/html; charset=utf-8";
          res.ContentLength64 = b.Length;
          res.OutputStream.Write(b, 0, b.Length);
          res.Close();
          return;
        }
        if (p == "/favicon.ico") {
          res.ContentType = "image/x-icon";
          res.ContentLength64 = FaviconBytes.Length;
          if (FaviconBytes.Length > 0) res.OutputStream.Write(FaviconBytes, 0, FaviconBytes.Length);
          res.Close();
          return;
        }
        if (p.StartsWith("/api/", StringComparison.OrdinalIgnoreCase)) {
          string tok = req.Headers["X-Repage-Token"] ?? "";
          if (!string.Equals(tok, SessionToken, StringComparison.Ordinal)) {
            Log("AUTH_BLOCK", "Blocked request without valid X-Repage-Token to " + p);
            res.StatusCode = 403; res.Close(); return;
          }
        }
        if (p == "/api/ping") { SendJson(res, "{\"ok\":true}"); return; }
        if (p == "/api/log") {
          string text = "";
          lock (LogLock) {
            try {
              if (File.Exists(LogFilePath)) {
                using (FileStream fs = new FileStream(LogFilePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                using (StreamReader sr = new StreamReader(fs, Encoding.UTF8)) {
                  text = sr.ReadToEnd();
                }
              }
            } catch {}
            if (string.IsNullOrEmpty(text)) text = LogBuf.ToString();
          }
          SendJson(res, "{\"ok\":true,\"log\":\"" + EscapeJson(text) + "\"}");
          return;
        }
        if (p == "/api/check") {
          CheckGithubLatest();
          DetectSteamAndMillennium(CustomSelectedPath);
          SendJson(res, BuildStatusJson(false));
          return;
        }
        if (p == "/api/reset-folder") {
          CustomSelectedPath = "";
          SteamDir = "";
          DetectSteamAndMillennium("");
          SendJson(res, BuildStatusJson(false));
          return;
        }
        if (p == "/api/pick-folder") {
          if (PickingFolder) { SendJson(res, "{\"picked\":false}"); return; }
          PickingFolder = true;
          string chosen = "";
          try {
            string initDir = (!string.IsNullOrEmpty(PluginsDir) && Directory.Exists(PluginsDir)) ? PluginsDir : SteamDir;
            ManualResetEvent done = new ManualResetEvent(false);
            if (MainWindow != null && !MainWindow.IsDisposed) {
              MainWindow.BeginInvoke((MethodInvoker)delegate {
                try { chosen = PickFolderModern(MainWindow.Handle, initDir); }
                finally { done.Set(); }
              });
              done.WaitOne();
            }
          } finally { PickingFolder = false; }
          Log("PICK_FOLDER", "Chosen=" + chosen);
          if (!string.IsNullOrEmpty(chosen)) {
            CustomSelectedPath = chosen;
            DetectSteamAndMillennium(CustomSelectedPath);
            SendJson(res, BuildStatusJson(true));
          } else {
            SendJson(res, "{\"picked\":false}");
          }
          return;
        }
        if (p == "/api/install") {
          bool clean = req.QueryString["clean"] == "1";
          lock (InstallLock) {
            if (InstallStatus == "running") { SendJson(res, "{\"ok\":true}"); return; }
            InstallStatus = "running";
            InstallPercent = 4;
            InstallStepCode = "connecting";
            DownloadedKb = 0;
            LastError = "";
          }
          Thread t = new Thread(() => RunInstallWorker(clean));
          t.IsBackground = true;
          t.Start();
          SendJson(res, "{\"ok\":true}");
          return;
        }
        if (p == "/api/uninstall") {
          string err = UninstallPlugin();
          if (string.IsNullOrEmpty(err)) SendJson(res, "{\"ok\":true,\"steamRunning\":" + (IsSteamRunning() ? "true" : "false") + "}");
          else SendJson(res, "{\"ok\":false,\"error\":\"" + EscapeJson(err) + "\"}");
          return;
        }
        if (p == "/api/shutdown-steam") {
          bool closed = SafeShutdownSteamOnly();
          SendJson(res, "{\"ok\":" + (closed ? "true" : "false") + ",\"steamRunning\":" + (IsSteamRunning() ? "true" : "false") + "}");
          return;
        }

        if (p == "/api/progress") {
          SendJson(res, "{\"status\":\"" + EscapeJson(InstallStatus) + "\",\"percent\":" + InstallPercent + ",\"stepCode\":\"" + EscapeJson(InstallStepCode) + "\",\"kb\":" + DownloadedKb + ",\"steamRunning\":" + (IsSteamRunning() ? "true" : "false") + ",\"error\":\"" + EscapeJson(LastError) + "\"}");
          return;
        }
        if (p == "/api/open-folder") {
          string basePlugins = !string.IsNullOrEmpty(PluginsDir) ? PluginsDir : Path.Combine(SteamDir, "plugins");
          string target = Path.Combine(basePlugins, "repage-steamgrid");
          if (!Directory.Exists(target)) target = Directory.Exists(basePlugins) ? basePlugins : SteamDir;
          if (Directory.Exists(target)) { try { Process.Start("explorer.exe", "\"" + target + "\""); } catch {} }
          SendJson(res, "{\"ok\":true}");
          return;
        }
        if (p == "/api/restart-steam") {
          string mode = req.QueryString["mode"] ?? "restart";
          Thread st = new Thread(() => {
            if (mode == "start") LaunchSteamOnly();
            else SafeRestartSteam();
          });
          st.IsBackground = true;
          st.Start();
          SendJson(res, "{\"ok\":true}");
          return;
        }
        if (p == "/api/quit") {
          Log("QUIT", "Close requested via /api/quit");
          SendJson(res, "{\"ok\":true}");
          new Thread(() => {
            Thread.Sleep(70);
            try {
              if (MainWindow != null && !MainWindow.IsDisposed) {
                MainWindow.BeginInvoke((MethodInvoker)delegate {
                  try { MainWindow.Close(); } catch {}
                  try { Application.Exit(); } catch {}
                });
              }
            } catch {}
            Thread.Sleep(350);
            Environment.Exit(0);
          }).Start();
          return;
        }
        res.StatusCode = 404;
        res.Close();
      } catch (Exception ex) {
        Log("HTTP_ERR", ex.Message);
        try { ctx.Response.Close(); } catch {}
      }
    }

    static void RunServer(HttpListener listener) {
      while (listener.IsListening) {
        HttpListenerContext ctx = null;
        try { ctx = listener.GetContext(); } catch { break; }
        ThreadPool.QueueUserWorkItem(_ => HandleHttpRequest(ctx));
      }
    }
  }

  static class NativeUiRunner {
    [MethodImpl(MethodImplOptions.NoInlining)]
    internal static void Run(string url, string loaderDir) {
      if (!string.IsNullOrEmpty(loaderDir)) {
        try { CoreWebView2Environment.SetLoaderDllFolderPath(loaderDir); } catch (Exception ex) { Program.Log("WV2_LOADER_ERR", ex.Message); }
      }
      NativeSetupForm form = new NativeSetupForm(url);
      Program.MainWindow = form;
      Application.Run(form);
    }
  }

  class NativeSetupForm : Form {
    string appUrl;
    WebView2 webView;
    double initialZoomFactor = 1.0;
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    public NativeSetupForm(string url) {
      appUrl = url;
      Text = "Repage SteamGrid Setup";
      float sx = 1f, sy = 1f;
      try {
        using (Graphics g = CreateGraphics()) {
          sx = Math.Max(1f, g.DpiX / 96f);
          sy = Math.Max(1f, g.DpiY / 96f);
        }
      } catch {}
      Rectangle wa = Screen.PrimaryScreen.WorkingArea;
      int cw = Math.Min((int)Math.Round(780 * sx), Math.Max(520, wa.Width - 40));
      int ch = Math.Min((int)Math.Round(540 * sy), Math.Max(380, wa.Height - 60));
      double fitScale = Math.Min((double)cw / (780.0 * sx), (double)ch / (540.0 * sy));
      if (fitScale > 0.4 && fitScale < 0.995) initialZoomFactor = fitScale;
      ClientSize = new Size(cw, ch);
      FormBorderStyle = FormBorderStyle.FixedSingle;
      MaximizeBox = false;
      StartPosition = FormStartPosition.CenterScreen;
      BackColor = Color.FromArgb(7, 7, 12);
      try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch {}

      webView = new WebView2();
      webView.Dock = DockStyle.Fill;
      webView.DefaultBackgroundColor = Color.FromArgb(7, 7, 12);
      Controls.Add(webView);
      Shown += OnFormShown;
    }

    protected override void OnHandleCreated(EventArgs e) {
      base.OnHandleCreated(e);
      try {
        int dark = 1;
        DwmSetWindowAttribute(Handle, 20, ref dark, 4);
        int capBgr = 0x0010080A;
        DwmSetWindowAttribute(Handle, 35, ref capBgr, 4);
      } catch {}
    }

    async void OnFormShown(object sender, EventArgs e) {
      try {
        string userData = Path.Combine(Path.GetTempPath(), "RepageSetup_WV2_Data");
        Directory.CreateDirectory(userData);
        CoreWebView2EnvironmentOptions opts = new CoreWebView2EnvironmentOptions("--disable-features=Translate,msEdgeTranslate,msEdgeSidebarV2,msAccountSync --no-first-run --no-default-browser-check");
        CoreWebView2Environment env = await CoreWebView2Environment.CreateAsync(null, userData, opts);
        await webView.EnsureCoreWebView2Async(env);
        CoreWebView2Settings s = webView.CoreWebView2.Settings;
        s.AreDefaultContextMenusEnabled = false;
        s.AreDevToolsEnabled = false;
        s.IsStatusBarEnabled = false;
        s.IsZoomControlEnabled = false;
        s.AreBrowserAcceleratorKeysEnabled = false;
        s.IsBuiltInErrorPageEnabled = false;
        s.IsGeneralAutofillEnabled = false;
        s.IsPasswordAutosaveEnabled = false;
        if (initialZoomFactor < 0.995) { try { webView.ZoomFactor = initialZoomFactor; } catch {} }
        webView.CoreWebView2.WindowCloseRequested += (ws, we) => { try { Close(); } catch {} };
        webView.Source = new Uri(appUrl);
        Program.Log("WV2", "Native WebView2 host initialized successfully");
      } catch (Exception ex) {
        Program.Log("WV2_FATAL", ex.Message);
        MessageBox.Show(this, "Microsoft Edge WebView2 Runtime is required: " + ex.Message, "Repage SteamGrid Setup", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        Close();
      }
    }
  }
}