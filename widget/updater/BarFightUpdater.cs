// Windows .NET Framework 4.x, framework libraries only. No gameplay data leaves this process.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

internal static class BarFightUpdater
{
    internal const string ManifestUrl = "https://bar-fight.com/updates/widget/stable.json";
    internal static readonly string[] Names = { "BarFightBridge.exe", "BarFightUpdater.exe", "gui_bar_fight_traits.lua", "gui_bar_fight_player_list.lua", "README.md" };
    internal static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
    internal sealed class Entry { public string Name; public string Url; public string Hash; public long Size; }
    internal sealed class Release { public string Version; public List<Entry> Files = new List<Entry>(); }
    internal sealed class Install
    {
        public string App; public string Data;
        public string Work { get { return Path.Combine(App, ".update"); } }
        public string Stage { get { return Path.Combine(Work, "stage"); } }
        public string Backup { get { return Path.Combine(Work, "backup"); } }
        public string Destination(string name) { return name.EndsWith(".lua", StringComparison.Ordinal) ? Path.Combine(Data, "LuaUI", "Widgets", name) : Path.Combine(App, name); }
    }
    static EventWaitHandle Stop;
    internal static Func<bool> GameProbe = GameRunning;
    internal sealed class GameActiveException : Exception { }
    static void RequireGameClosed() { if (GameProbe()) throw new GameActiveException(); }
    static JavaScriptSerializer Json() { return new JavaScriptSerializer { MaxJsonLength = 128 * 1024, RecursionLimit = 12 }; }
    static long UnixNow() { return (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalSeconds; }
    static string Scope(string app)
    {
        using (SHA256 sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(Utf8.GetBytes(Path.GetFullPath(app).TrimEnd('\\', '/').ToUpperInvariant()))).Replace("-", "").Substring(0, 32);
    }
    [STAThread]
    public static int Main(string[] args)
    {
        try
        {
            string app = null, data = null, mode = null;
            HashSet<string> seen = new HashSet<string>();
            for (int i = 0; i < args.Length; i++)
            {
                if (!seen.Add(args[i])) throw new ArgumentException("Duplicate option.");
                if (args[i] == "--app-dir" || args[i] == "--data-dir")
                {
                    string option = args[i];
                    if (++i >= args.Length) throw new ArgumentException("Missing directory.");
                    if (option == "--app-dir") app = Canonical(args[i]); else data = Canonical(args[i]);
                }
                else if (args[i] == "--check" || args[i] == "--apply" || args[i] == "--stop")
                { if (mode != null) throw new ArgumentException("One operation required."); mode = args[i]; }
                else throw new ArgumentException("Unknown option.");
            }
            if (app == null || data == null || mode == null) throw new ArgumentException("Operation and installation directories required.");
            string scope = Scope(app), mutexName = "Local\\BARFightUpdater_" + scope, eventName = "Local\\BARFightUpdaterStop_" + scope;
            if (mode == "--stop")
            {
                try { using (EventWaitHandle signal = EventWaitHandle.OpenExisting(eventName)) signal.Set(); } catch (WaitHandleCannotBeOpenedException) { }
                try
                {
                    using (Mutex running = Mutex.OpenExisting(mutexName))
                    {
                        bool acquired; try { acquired = running.WaitOne(60000); } catch (AbandonedMutexException) { acquired = true; }
                        if (!acquired) return 3;
                        running.ReleaseMutex();
                    }
                }
                catch (WaitHandleCannotBeOpenedException) { }
                return 0;
            }
            Install install = new Install { App = app, Data = data };
            ValidateInstall(install, mode == "--apply");
            using (Mutex mutex = new Mutex(false, mutexName))
            {
                bool acquired;
                try { acquired = mutex.WaitOne(mode == "--apply" ? 30000 : 0); } catch (AbandonedMutexException) { acquired = true; }
                if (!acquired) return 0;
                try
                {
                    using (Stop = new EventWaitHandle(false, EventResetMode.ManualReset, eventName))
                    {
                        Stop.Reset();
                        if (Paused(install)) return 0;
                        Directory.CreateDirectory(install.Work);
                        if (File.Exists(Path.Combine(install.Work, "journal.json")))
                        {
                            if (GameProbe()) return 0;
                            if (mode != "--apply") { LaunchRunner(install); return 0; }
                            StopBridge(install);
                            try { RecoverWhenClosed(install); } finally { StartBridge(install); }
                        }
                        if (!Enabled(install)) return 0;
                        if (mode == "--apply") return ApplyPending(install);
                        return Check(install);
                    }
                }
                finally { mutex.ReleaseMutex(); }
            }
        }
        catch (GameActiveException) { return 0; }
        catch (Exception error) { Console.Error.WriteLine("BAR Fight updater: " + error.Message); return 1; }
    }
    internal static string Canonical(string path) { return Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar); }
    internal static void NoReparse(string path)
    {
        for (string current = Path.GetFullPath(path); !String.IsNullOrEmpty(current); current = Path.GetDirectoryName(current))
            if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException("Reparse points are not supported in update paths.");
    }
    static void ValidateInstall(Install install, bool runner)
    {
        string expectedExe = runner ? Path.Combine(install.Work, "runner.exe") : Path.Combine(install.App, "BarFightUpdater.exe");
        if (!String.Equals(Canonical(Process.GetCurrentProcess().MainModule.FileName), Canonical(expectedExe), StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Updater must run from its installation.");
        if (!Directory.Exists(Path.Combine(install.Data, "LuaUI"))) throw new InvalidDataException("BAR data folder missing.");
        string configured = Ini(Path.Combine(install.App, "bar-fight.ini"), "BAR", "DataDir");
        if (configured == null || !String.Equals(Canonical(configured), install.Data, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("BAR data folder does not match this installation.");
        NoReparse(install.Work); NoReparse(install.Stage); NoReparse(install.Backup);
        foreach (string name in Names) NoReparse(install.Destination(name));
    }
    internal static string Ini(string path, string section, string key)
    {
        if (!File.Exists(path)) return null;
        string current = "", found = null;
        foreach (string raw in File.ReadAllLines(path))
        {
            string line = raw.Trim();
            if (line.StartsWith("[", StringComparison.Ordinal) && line.EndsWith("]", StringComparison.Ordinal)) current = line.Substring(1, line.Length - 2);
            else if (String.Equals(current, section, StringComparison.OrdinalIgnoreCase))
            {
                int equals = line.IndexOf('=');
                if (equals > 0 && String.Equals(line.Substring(0, equals).Trim(), key, StringComparison.OrdinalIgnoreCase)) found = line.Substring(equals + 1).Trim();
            }
        }
        return found;
    }
    static bool Enabled(Install install)
    {
        string enabled = Ini(Path.Combine(install.App, "bar-fight.ini"), "Updates", "Enabled");
        return enabled == null || enabled == "1" || String.Equals(enabled, "true", StringComparison.OrdinalIgnoreCase);
    }
    static bool Paused(Install install) { return File.Exists(Path.Combine(install.App, "update-paused")); }
    internal static Version ParseVersion(string value)
    {
        if (value == null || !Regex.IsMatch(value, "\\A(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})\\z")) throw new InvalidDataException("Unsupported release version.");
        return new Version(value);
    }
    internal static Release Verify(byte[] envelopeBytes, string key, long now)
    {
        if (envelopeBytes.Length > 128 * 1024) throw new InvalidDataException("Manifest too large.");
        Dictionary<string, object> envelope = Json().DeserializeObject(Utf8.GetString(envelopeBytes)) as Dictionary<string, object>;
        if (envelope == null || envelope.Count != 2) throw new InvalidDataException("Invalid signed envelope.");
        byte[] payload = Convert.FromBase64String(StringValue(envelope, "payload"));
        byte[] signature = Convert.FromBase64String(StringValue(envelope, "signature"));
        using (RSACryptoServiceProvider rsa = new RSACryptoServiceProvider())
        {
            rsa.PersistKeyInCsp = false; rsa.FromXmlString(key);
            if (rsa.KeySize < 3072 || !rsa.VerifyData(payload, CryptoConfig.MapNameToOID("SHA256"), signature)) throw new InvalidDataException("Release signature is invalid.");
        }
        // No payload fields influence paths, requests, versions or actions before signature verification.
        Dictionary<string, object> body = Json().DeserializeObject(Utf8.GetString(payload)) as Dictionary<string, object>;
        if (body == null || Number(body, "schema") != 1 || StringValue(body, "product") != "bar-fight-widget" || StringValue(body, "channel") != "stable") throw new InvalidDataException("Unsupported release.");
        long published = Number(body, "published_at"), expires = Number(body, "expires_at");
        if (published > now + 300 || published < 0 || expires <= now || expires <= published || expires - published > 31L * 86400) throw new InvalidDataException("Release is expired or has invalid publication times.");
        Release release = new Release { Version = StringValue(body, "version") }; ParseVersion(release.Version);
        object rawFiles; if (!body.TryGetValue("files", out rawFiles)) throw new InvalidDataException("Missing release files.");
        IList files = rawFiles as IList;
        if (files == null || files.Count != Names.Length) throw new InvalidDataException("Incorrect release file set.");
        HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal); long total = 0;
        foreach (object raw in files)
        {
            Dictionary<string, object> file = raw as Dictionary<string, object>;
            if (file == null) throw new InvalidDataException("Invalid file entry.");
            Entry entry = new Entry { Name = StringValue(file, "name"), Url = StringValue(file, "url"), Hash = StringValue(file, "sha256"), Size = Number(file, "size") };
            if (Array.IndexOf(Names, entry.Name) < 0 || !seen.Add(entry.Name)) throw new InvalidDataException("Unexpected or duplicate release file.");
            string expected = "https://bar-fight.com/updates/widget/" + release.Version + "/" + entry.Name;
            if (entry.Url != expected) throw new InvalidDataException("Unapproved release URL.");
            if (!Regex.IsMatch(entry.Hash, "\\A[0-9a-f]{64}\\z") || entry.Size < 1 || entry.Size > 8 * 1024 * 1024) throw new InvalidDataException("Invalid file digest or size.");
            total += entry.Size; release.Files.Add(entry);
        }
        if (total > 20 * 1024 * 1024) throw new InvalidDataException("Release exceeds size limit.");
        return release;
    }
    static string StringValue(Dictionary<string, object> data, string key)
    {
        object value; if (!data.TryGetValue(key, out value) || !(value is string)) throw new InvalidDataException("Missing string: " + key); return (string)value;
    }
    static long Number(Dictionary<string, object> data, string key)
    {
        object value; if (!data.TryGetValue(key, out value) || !(value is int || value is long)) throw new InvalidDataException("Missing integer: " + key); return Convert.ToInt64(value, CultureInfo.InvariantCulture);
    }
    static void Cancelled() { if (Stop != null && Stop.WaitOne(0)) throw new OperationCanceledException(); }
    internal static void ValidateHttpResponse(HttpStatusCode status, Uri actual, Uri expected)
    {
        if (status != HttpStatusCode.OK || actual.AbsoluteUri != expected.AbsoluteUri) throw new InvalidDataException("Redirects and unsuccessful update responses are forbidden.");
    }
    static byte[] Download(string url, int maximum)
    {
#if UPDATE_TEST
        throw new InvalidOperationException("Offline updater test attempted an unexpected network request.");
#else
        Cancelled(); ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
        Uri uri = new Uri(url);
        HttpWebRequest request = (HttpWebRequest)WebRequest.Create(uri);
        request.AllowAutoRedirect = false; request.Timeout = 15000; request.ReadWriteTimeout = 15000;
        request.UserAgent = "BAR-Fight-Updater/" + WidgetBuild.Version; request.AutomaticDecompression = DecompressionMethods.None;
        RegisteredWaitHandle cancellation = Stop == null ? null : ThreadPool.RegisterWaitForSingleObject(Stop, delegate { request.Abort(); }, null, -1, true);
        try
        {
            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
            {
                ValidateHttpResponse(response.StatusCode, response.ResponseUri, uri);
                if (response.ContentLength > maximum) throw new InvalidDataException("Update response exceeds size limit.");
                using (Stream stream = response.GetResponseStream()) using (MemoryStream output = new MemoryStream())
                {
                    byte[] buffer = new byte[8192]; int count;
                    while ((count = stream.Read(buffer, 0, buffer.Length)) != 0)
                    { Cancelled(); if (output.Length + count > maximum) throw new InvalidDataException("Update response exceeds size limit."); output.Write(buffer, 0, count); }
                    return output.ToArray();
                }
            }
        }
        finally { if (cancellation != null) cancellation.Unregister(null); }
#endif
    }
    internal static void VerifyFile(byte[] bytes, Entry entry)
    {
        using (SHA256 sha = SHA256.Create())
            if (bytes.LongLength != entry.Size || BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant() != entry.Hash) throw new InvalidDataException("Release file failed verification: " + entry.Name);
    }
    internal static void AtomicWrite(string path, byte[] bytes)
    {
        NoReparse(path); NoReparse(path + ".tmp");
        using (FileStream stream = new FileStream(path + ".tmp", FileMode.Create, FileAccess.Write, FileShare.None)) { stream.Write(bytes, 0, bytes.Length); stream.Flush(true); }
        for (int attempt = 0; ; attempt++)
        {
            try { if (File.Exists(path)) File.Replace(path + ".tmp", path, null); else File.Move(path + ".tmp", path); break; }
            catch (IOException error)
            {
                // The checking process may release its mutex just before Windows
                // unmaps its executable. Only retry sharing/lock violations.
                int code = error.HResult & 65535;
                if (attempt >= 30 || (code != 32 && code != 33)) throw;
                Thread.Sleep(100);
            }
        }
    }
    static Version Floor(Install install)
    {
        Version floor = ParseVersion(WidgetBuild.Version);
        string installed = FileVersionInfo.GetVersionInfo(Path.Combine(install.App, "BarFightUpdater.exe")).FileVersion;
        if (!String.IsNullOrEmpty(installed))
        {
            Version fileVersion;
            if (!Version.TryParse(installed, out fileVersion) || fileVersion.Build < 0 || fileVersion.Revision > 0) throw new InvalidDataException("Invalid installed updater version.");
            Version version = new Version(fileVersion.Major, fileVersion.Minor, fileVersion.Build); if (version > floor) floor = version;
        }
        string highest = Path.Combine(install.Work, "highest-version");
        if (File.Exists(highest)) { Version version = ParseVersion(File.ReadAllText(highest).Trim()); if (version > floor) floor = version; }
        return floor;
    }
    internal static void RequireNew(Release release, Version current) { if (ParseVersion(release.Version) <= current) throw new InvalidDataException("Release is not newer than installed version."); }
    static int Check(Install install)
    {
        string pending = Path.Combine(install.Work, "pending.json");
        if (File.Exists(pending))
        {
            bool valid = false;
            try
            {
                Release staged = Verify(ReadBounded(pending, 128 * 1024), UpdateTrust.PublicKeyXml, UnixNow()); RequireNew(staged, Floor(install));
                VerifyStage(install, staged); valid = true;
            }
            catch (InvalidDataException) { }
            catch (FormatException) { }
            catch (ArgumentException) { }
            catch (InvalidOperationException) { }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
            if (valid) { if (!GameProbe()) LaunchRunner(install); return 0; }
            File.Delete(pending);
            // The staged copy can be quarantined or damaged independently of its manifest.
            // Drop the retry timer so this installation can fetch a complete signed copy again.
            string retry = Path.Combine(install.Work, "next-check"); if (File.Exists(retry)) File.Delete(retry);
        }
        string nextFile = Path.Combine(install.Work, "next-check"); long next;
        if (File.Exists(nextFile) && Int64.TryParse(File.ReadAllText(nextFile), out next) && next > UnixNow() && next <= UnixNow() + 21600) return 0;
        AtomicWrite(nextFile, Utf8.GetBytes((UnixNow() + 1800).ToString(CultureInfo.InvariantCulture)));
        byte[] envelope = Download(ManifestUrl, 128 * 1024);
        Release release = Verify(envelope, UpdateTrust.PublicKeyXml, UnixNow());
        if (ParseVersion(release.Version) <= Floor(install)) { AtomicWrite(nextFile, Utf8.GetBytes((UnixNow() + 21600).ToString(CultureInfo.InvariantCulture))); return 0; }
        Directory.CreateDirectory(install.Stage);
        foreach (Entry entry in release.Files)
        {
            byte[] bytes = Download(entry.Url, (int)entry.Size); VerifyFile(bytes, entry);
            AtomicWrite(Path.Combine(install.Stage, entry.Name), bytes);
        }
        AtomicWrite(pending, envelope);
        AtomicWrite(nextFile, Utf8.GetBytes((UnixNow() + 21600).ToString(CultureInfo.InvariantCulture)));
        if (!GameProbe()) LaunchRunner(install);
        return 0;
    }
    static void LaunchRunner(Install install)
    {
        Cancelled(); if (Paused(install)) return;
        string runner = Path.Combine(install.Work, "runner.exe");
        AtomicWrite(runner, File.ReadAllBytes(Path.Combine(install.App, "BarFightUpdater.exe")));
        Launch(runner, "--apply --app-dir " + Quote(install.App) + " --data-dir " + Quote(install.Data), false);
    }
    internal static bool IsGameProcess(string name) { return name.StartsWith("spring", StringComparison.OrdinalIgnoreCase) || name.StartsWith("recoil", StringComparison.OrdinalIgnoreCase); }
    internal static bool GameRunning()
    {
        foreach (Process process in Process.GetProcesses())
            using (process) { try { if (IsGameProcess(process.ProcessName)) return true; } catch (InvalidOperationException) { } catch (System.ComponentModel.Win32Exception) { return true; } }
        return false;
    }
    static string Quote(string value) { if (value.IndexOf('"') >= 0) throw new ArgumentException("Invalid path."); return "\"" + value + "\""; }
    static void Launch(string file, string arguments, bool wait)
    {
        using (Process process = Process.Start(new ProcessStartInfo(file, arguments) { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden }))
            if (wait && (!process.WaitForExit(10000) || process.ExitCode != 0)) throw new IOException("Companion could not be stopped.");
    }
    static void StopBridge(Install install) { Launch(Path.Combine(install.App, "BarFightBridge.exe"), "--stop --data-dir " + Quote(install.Data), true); }
    static void StartBridge(Install install)
    {
        if (!Paused(install) && !File.Exists(Path.Combine(install.Work, "journal.json")) && File.Exists(Path.Combine(install.App, "BarFightBridge.exe")))
            Launch(Path.Combine(install.App, "BarFightBridge.exe"), "--data-dir " + Quote(install.Data), false);
    }
    internal static byte[] ReadBounded(string path, int maximum)
    {
        NoReparse(path);
        using (FileStream input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            if (input.Length > maximum) throw new InvalidDataException("Staged file exceeds size limit.");
            byte[] bytes = new byte[(int)input.Length]; int offset = 0;
            while (offset < bytes.Length) { int count = input.Read(bytes, offset, bytes.Length - offset); if (count == 0) throw new InvalidDataException("Incomplete staged file."); offset += count; }
            return bytes;
        }
    }
    internal static void VerifyStage(Install install, Release release)
    {
        foreach (Entry entry in release.Files) VerifyFile(ReadBounded(Path.Combine(install.Stage, entry.Name), (int)entry.Size), entry);
    }
    static int ApplyPending(Install install)
    {
        string pending = Path.Combine(install.Work, "pending.json");
        if (!File.Exists(pending) || Paused(install) || GameProbe()) return 0;
        Release release = Verify(ReadBounded(pending, 128 * 1024), UpdateTrust.PublicKeyXml, UnixNow()); RequireNew(release, Floor(install));
        VerifyStage(install, release);
        Cancelled(); if (Paused(install) || GameProbe()) return 0;
        StopBridge(install);
        try
        {
            Cancelled(); if (Paused(install) || GameProbe()) return 0;
            ApplyFiles(install, release, null);
            File.Delete(pending);
        }
        catch (GameActiveException)
        {
            // The helper is stopped at this point, so this runner must keep the
            // recovery alive until the newly started engine exits.
            RecoverWhenClosed(install);
        }
        finally { StartBridge(install); }
        return 0;
    }
    static void RecoverWhenClosed(Install install)
    {
        for (;;)
        {
            Cancelled();
            if (!GameProbe())
            {
                try { Recover(install); return; }
                catch (GameActiveException) { }
            }
            if (Stop != null) Stop.WaitOne(1000); else Thread.Sleep(1000);
        }
    }
    // Backups are completely flushed before the write-ahead journal permits the first replacement.
    // Rollback always restores every member, so a crash between replacement and journal update is safe.
    internal static void ApplyFiles(Install install, Release release, Action<int> afterReplace)
    {
        Directory.CreateDirectory(install.Backup);
        Dictionary<string, object> existed = new Dictionary<string, object>();
        foreach (string name in Names)
        {
            string destination = install.Destination(name); NoReparse(destination);
            bool exists = File.Exists(destination); existed.Add(name, exists);
            if (exists) AtomicWrite(Path.Combine(install.Backup, name), File.ReadAllBytes(destination));
        }
        Dictionary<string, object> journal = new Dictionary<string, object>(); journal.Add("existed", existed); journal.Add("version", release.Version); journal.Add("committed", false);
        string journalPath = Path.Combine(install.Work, "journal.json");
        AtomicWrite(journalPath, Utf8.GetBytes(Json().Serialize(journal)));
        try
        {
            int count = 0;
            foreach (Entry entry in release.Files)
            {
                Cancelled(); if (Paused(install)) throw new OperationCanceledException(); string destination = install.Destination(entry.Name);
                RequireGameClosed();
                byte[] bytes = ReadBounded(Path.Combine(install.Stage, entry.Name), (int)entry.Size); VerifyFile(bytes, entry);
                RequireGameClosed();
                Directory.CreateDirectory(Path.GetDirectoryName(destination)); AtomicWrite(destination, bytes);
                if (afterReplace != null) afterReplace(++count);
            }
            journal["committed"] = true; AtomicWrite(journalPath, Utf8.GetBytes(Json().Serialize(journal)));
        }
        // A game starting during the transaction must not cause further live Lua writes,
        // even rollback writes. The next runner resumes recovery after the engine exits.
        catch (GameActiveException) { throw; }
        catch { Recover(install); throw; }
        Recover(install);
    }
    internal static void Recover(Install install)
    {
        string path = Path.Combine(install.Work, "journal.json");
        if (!File.Exists(path)) return;
        Dictionary<string, object> journal = Json().DeserializeObject(File.ReadAllText(path, Utf8)) as Dictionary<string, object>;
        if (journal == null) throw new InvalidDataException("Invalid update journal.");
        object raw; if (!journal.TryGetValue("committed", out raw) || !(raw is bool)) throw new InvalidDataException("Invalid journal state.");
        bool committed = (bool)raw;
        if (committed)
        {
            string version = StringValue(journal, "version"); ParseVersion(version);
            AtomicWrite(Path.Combine(install.Work, "highest-version"), Utf8.GetBytes(version));
        }
        else
        {
            object values; if (!journal.TryGetValue("existed", out values)) throw new InvalidDataException("Invalid journal file set.");
            Dictionary<string, object> existed = values as Dictionary<string, object>;
            if (existed == null || existed.Count != Names.Length) throw new InvalidDataException("Invalid journal file set.");
            foreach (string name in Names)
            {
                if (!existed.TryGetValue(name, out raw) || !(raw is bool)) throw new InvalidDataException("Invalid journal file state.");
                NoReparse(install.Destination(name)); NoReparse(Path.Combine(install.Backup, name));
                RequireGameClosed();
                if ((bool)raw) AtomicWrite(install.Destination(name), File.ReadAllBytes(Path.Combine(install.Backup, name)));
                else if (File.Exists(install.Destination(name))) File.Delete(install.Destination(name));
            }
        }
        File.Delete(path);
        // Only fixed, updater-owned filenames are removed; never recursively delete a supplied path.
        foreach (string name in Names) { string backup = Path.Combine(install.Backup, name); if (File.Exists(backup)) File.Delete(backup); }
    }
}
