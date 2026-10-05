// BAR Fight traits companion. Builds with the Windows .NET Framework compiler;
// uses only framework libraries and never uploads gameplay data.
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
using System.Threading.Tasks;
using System.Web.Script.Serialization;

internal static class BarFightBridge
{
    const string MapName = "Supreme Isthmus v2.1";
    const string DefaultEndpoint = "https://bar-fight.com/api/widget/traits";
    const string LegacyEndpoint = "https://replay.164.90.210.36.sslip.io/api/widget/traits";
    const string TimingPath = "/api/widget/timings";
    const string TimingUnitsPath = "/api/widget/timing-units";
    const int MaxRequestBytes = 16384;
    const int MaxResponseBytes = 2 * 1024 * 1024;
    const int FreshSeconds = 300;
    const int RetrySeconds = 30;
    const int ThrottleSeconds = 10;
    static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
    static readonly Regex SafeRequestId = new Regex("\\A[A-Za-z0-9_-]{1,80}\\z", RegexOptions.CultureInvariant);
    static readonly Regex AccountPattern = new Regex("\\A[1-9][0-9]{0,15}\\z", RegexOptions.CultureInvariant);
    static readonly Regex UnitPattern = new Regex("\\A(?:[a-z][a-z0-9_]{0,99}|group:[a-z][a-z0-9-]{0,79})\\z", RegexOptions.CultureInvariant);
    static readonly HashSet<string> ProfileStatuses = new HashSet<string>(new string[] {
        "available", "no_qualifying_traits", "insufficient_evidence", "preparing", "no_data"
    }, StringComparer.Ordinal);

    sealed class Request
    {
        public string Id;
        public string[] Accounts;
        public string Key;
        public DateTime WrittenUtc;
        public string Unit;
        public bool Catalog;
    }

    sealed class FetchResult
    {
        public Dictionary<string, object> Payload;
        public string Error;
        public DateTime FetchedUtc;
        public bool AllowLegacyFallback;
        public string Endpoint;
        public string ErrorCode;
    }

    sealed class Options
    {
        public string DataDir;
        public Uri Endpoint = new Uri(DefaultEndpoint);
        public bool Once;
        public bool Stop;
        public bool SelfTest;
    }

    [STAThread]
    public static int Main(string[] args)
    {
        try
        {
            Options options = ParseOptions(args);
            if (options.SelfTest) return SelfTest();
            string scope = Scope(options.DataDir);
            string stopName = "Local\\BARFightBridgeStop_" + scope;
            if (options.Stop)
            {
                try { using (EventWaitHandle signal = EventWaitHandle.OpenExisting(stopName)) signal.Set(); }
                catch (WaitHandleCannotBeOpenedException) { }
                // Wait for this data directory's instance to finish, so uninstall/upgrade
                // can replace the executable without terminating unrelated processes.
                try
                {
                    using (Mutex running = Mutex.OpenExisting("Local\\BARFightBridge_" + scope))
                    {
                        bool stopped;
                        try { stopped = running.WaitOne(5000); }
                        catch (AbandonedMutexException) { stopped = true; }
                        if (!stopped) return 3;
                        running.ReleaseMutex();
                    }
                }
                catch (WaitHandleCannotBeOpenedException) { }
                return 0;
            }
            if (!Directory.Exists(options.DataDir) || !Directory.Exists(Path.Combine(options.DataDir, "LuaUI")))
                throw new ArgumentException("Choose the BAR data directory containing LuaUI.");
            using (Mutex mutex = new Mutex(false, "Local\\BARFightBridge_" + scope))
            {
                bool ownsMutex;
                try { ownsMutex = mutex.WaitOne(0); }
                catch (AbandonedMutexException) { ownsMutex = true; }
                if (!ownsMutex) return 0;
                try
                {
                    using (EventWaitHandle stop = new EventWaitHandle(false, EventResetMode.ManualReset, stopName))
                    using (CancellationTokenSource cancellation = new CancellationTokenSource())
                    {
                        stop.Reset();
                        try { return Run(options, stop, cancellation.Token); }
                        finally { cancellation.Cancel(); }
                    }
                }
                finally { mutex.ReleaseMutex(); }
            }
        }
        catch (Exception error)
        {
            // WinExe is intentionally windowless. Console builds expose diagnostics for tests.
            Console.Error.WriteLine("BAR Fight companion: " + error.Message);
            return 1;
        }
    }

    static Options ParseOptions(string[] args)
    {
        Options result = new Options();
        HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
        for (int i = 0; i < args.Length; i++)
        {
            string option = args[i];
            if (!seen.Add(option)) throw new ArgumentException("Duplicate option.");
            if (option == "--self-test") result.SelfTest = true;
            else if (option == "--once") result.Once = true;
            else if (option == "--stop") result.Stop = true;
            else if (option == "--data-dir" || option == "--endpoint")
            {
                if (++i >= args.Length) throw new ArgumentException("Missing option value.");
                if (option == "--data-dir") result.DataDir = Path.GetFullPath(args[i]);
                else
                {
                    Uri endpoint;
                    if (!Uri.TryCreate(args[i], UriKind.Absolute, out endpoint) || !AllowedEndpoint(endpoint) || endpoint.Query.Length != 0)
                        throw new ArgumentException("Only the approved BAR Fight HTTPS trait endpoints are allowed.");
                    result.Endpoint = endpoint;
                }
            }
            else throw new ArgumentException("Unknown option: " + option);
        }
        if (result.SelfTest)
        {
            if (args.Length != 1) throw new ArgumentException("Use --self-test on its own.");
        }
        else if (String.IsNullOrEmpty(result.DataDir)) throw new ArgumentException("--data-dir is required.");
        if (result.Once && result.Stop) throw new ArgumentException("--once and --stop cannot be combined.");
        return result;
    }

    static string Scope(string directory)
    {
        string normalized = Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).ToUpperInvariant();
        using (SHA256 sha = SHA256.Create())
            return BitConverter.ToString(sha.ComputeHash(Utf8.GetBytes(normalized))).Replace("-", "").Substring(0, 32);
    }

    static void CheckForUpdates(string dataDir)
    {
        // Installed releases opt in by default. Development, --once and offline
        // test runs do not launch an updater or generate unexpected HTTP traffic.
        try
        {
            string app = Path.GetDirectoryName(Process.GetCurrentProcess().MainModule.FileName);
            string updater = Path.Combine(app, "BarFightUpdater.exe");
            string ini = Path.Combine(app, "bar-fight.ini");
            if (!File.Exists(updater) || !File.Exists(ini) || File.Exists(Path.Combine(app, "update-paused"))) return;
            string section = "", installedData = null, enabled = null;
            foreach (string raw in File.ReadAllLines(ini))
            {
                string line = raw.Trim();
                if (line.StartsWith("[", StringComparison.Ordinal) && line.EndsWith("]", StringComparison.Ordinal)) section = line.Substring(1, line.Length - 2);
                else
                {
                    int equals = line.IndexOf('='); if (equals <= 0) continue;
                    string key = line.Substring(0, equals).Trim(), value = line.Substring(equals + 1).Trim();
                    if (String.Equals(section, "BAR", StringComparison.OrdinalIgnoreCase) && String.Equals(key, "DataDir", StringComparison.OrdinalIgnoreCase)) installedData = value;
                    if (String.Equals(section, "Updates", StringComparison.OrdinalIgnoreCase) && String.Equals(key, "Enabled", StringComparison.OrdinalIgnoreCase)) enabled = value;
                }
            }
            if (installedData == null || !String.Equals(Scope(installedData), Scope(dataDir), StringComparison.Ordinal)) return;
            if (enabled != null && enabled != "1" && !String.Equals(enabled, "true", StringComparison.OrdinalIgnoreCase)) return;
            if (app.IndexOf('"') >= 0 || dataDir.IndexOf('"') >= 0) return;
            using (Process process = Process.Start(new ProcessStartInfo(updater, "--check --app-dir \"" + app + "\" --data-dir \"" + dataDir.TrimEnd('\\', '/') + "\"")
                { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden })) { }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        catch (ArgumentException) { }
        catch (InvalidOperationException) { }
        catch (System.ComponentModel.Win32Exception) { }
    }

    static bool ProfileLookupsEnabled()
    {
        try
        {
            string ini = Path.Combine(Path.GetDirectoryName(Process.GetCurrentProcess().MainModule.FileName), "bar-fight.ini");
            if (!File.Exists(ini)) return true;
            string section = "", setting = null;
            foreach (string raw in File.ReadAllLines(ini))
            {
                string line = raw.Trim();
                if (line.StartsWith("[", StringComparison.Ordinal) && line.EndsWith("]", StringComparison.Ordinal)) section = line.Substring(1, line.Length - 2);
                else if (String.Equals(section, "Privacy", StringComparison.OrdinalIgnoreCase))
                {
                    int equals = line.IndexOf('=');
                    if (equals > 0 && String.Equals(line.Substring(0, equals).Trim(), "FetchProfiles", StringComparison.OrdinalIgnoreCase)) setting = line.Substring(equals + 1).Trim();
                }
            }
            return setting == null || setting == "1" || String.Equals(setting, "true", StringComparison.OrdinalIgnoreCase);
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    static int Run(Options options, EventWaitHandle stop, CancellationToken token,
        Func<Uri, Request, CancellationToken, FetchResult> fetchForTest = null,
        int preparationRetrySeconds = RetrySeconds, int fetchThrottleSeconds = ThrottleSeconds)
    {
        // Each local channel keeps independent requests, cache and responses. HTTP
        // runs on worker threads and cannot block the Spring/Lua game thread.
        if (fetchForTest != null)
            return RunChannel(options, stop, token, fetchForTest, preparationRetrySeconds, fetchThrottleSeconds);
        Task<int> timing = Task.Factory.StartNew(delegate {
            return RunChannel(options, stop, token, null, preparationRetrySeconds, fetchThrottleSeconds, true);
        });
        try
        {
            int traits = RunChannel(options, stop, token, null, preparationRetrySeconds, fetchThrottleSeconds);
            if (!options.Once) stop.Set();
            return Math.Max(traits, timing.Result);
        }
        finally { if (!options.Once) stop.Set(); }
    }

    static int RunChannel(Options options, EventWaitHandle stop, CancellationToken token,
        Func<Uri, Request, CancellationToken, FetchResult> fetchForTest = null,
        int preparationRetrySeconds = RetrySeconds, int fetchThrottleSeconds = ThrottleSeconds, bool timings = false,
        Func<bool> profilesEnabledForTest = null)
    {
        // Do not inherit an obsolete TLS default from the Framework installation.
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
        string config = Path.Combine(options.DataDir, "LuaUI", "Config");
        Directory.CreateDirectory(config);
        string prefix = timings ? "bar_fight_timings" : "bar_fight_traits";
        string requestPath = Path.Combine(config, prefix + "_request.json");
        string responsePath = Path.Combine(config, prefix + "_response.json");
        Dictionary<string, FetchResult> cache = new Dictionary<string, FetchResult>(StringComparer.Ordinal);
        Func<Uri, Request, CancellationToken, FetchResult> fetch = fetchForTest ?? (timings ? (Func<Uri, Request, CancellationToken, FetchResult>)FetchTimings : Fetch);
        Request current = null;
        Request inFlight = null;
        Task<FetchResult> pending = null;
        CancellationTokenSource pendingCancellation = null;
        DateTime nextFetch = DateTime.MinValue;
        DateTime lastStarted = DateTime.MinValue;
        DateTime lastModified = DateTime.MinValue;
        long lastLength = -1;
        string delivered = null;
        bool lastProfilesEnabled = true;
        DateTime nextUpdate = DateTime.MinValue;
        try
        {
        while (!stop.WaitOne(0))
        {
            DateTime now = DateTime.UtcNow;
            if (!timings && !options.Once && fetchForTest == null && now >= nextUpdate)
            {
                nextUpdate = now.AddMinutes(5);
                CheckForUpdates(options.DataDir);
            }
            try
            {
                FileInfo file = new FileInfo(requestPath);
                if (file.Exists && (file.LastWriteTimeUtc != lastModified || file.Length != lastLength))
                {
                    Request incoming = ReadRequest(requestPath, now, timings);
                    // Only remember a successful read: a widget may still be writing the file.
                    lastModified = file.LastWriteTimeUtc;
                    lastLength = file.Length;
                    if (incoming != null && (current == null || incoming.Id != current.Id || incoming.Key != current.Key))
                    {
                        if (current != null && current.Id == incoming.Id && current.Key != incoming.Key)
                            throw new InvalidDataException("A request ID cannot be reused for different players.");
                        current = incoming;
                        delivered = null;
                        nextFetch = DateTime.MinValue;
                    }
                }
                if (!file.Exists || !IsFresh(file.LastWriteTimeUtc, now)) current = null;
            }
            // InvalidDataException inherits SystemException in .NET Framework,
            // not IOException. Incomplete or malformed widget files are retried.
            catch (InvalidDataException) { if (timings) current = null; }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            catch (ArgumentException) { }
            catch (InvalidOperationException) { }

            // Timing selections can change rapidly while a fetch is in progress.
            // Drop obsolete work and never publish it under a new request ID.
            if (timings && pendingCancellation != null && !SameRequest(current, inFlight)) pendingCancellation.Cancel();

            bool profilesEnabled = profilesEnabledForTest != null ? profilesEnabledForTest() : ProfileLookupsEnabled();
            if (profilesEnabled != lastProfilesEnabled) { delivered = null; nextFetch = DateTime.MinValue; lastProfilesEnabled = profilesEnabled; }
            if (!profilesEnabled)
            {
                if (pendingCancellation != null) pendingCancellation.Cancel();
                if (pending != null && pending.IsCompleted)
                {
                    pending = null; inFlight = null;
                    if (pendingCancellation != null) { pendingCancellation.Dispose(); pendingCancellation = null; }
                }
                if (current != null && current.Id != delivered)
                {
                    FetchResult disabled = new FetchResult { Error = "Profile lookups are disabled in BAR Fight privacy settings.", ErrorCode = "privacy-disabled", FetchedUtc = now };
                    if (TryWriteResponse(responsePath, current, disabled, false)) delivered = current.Id;
                }
                if (options.Once) return current == null ? 0 : 2;
                stop.WaitOne(1000);
                continue;
            }

            if (pending != null && pending.IsCompleted)
            {
                FetchResult result;
                try { result = pending.Result; }
                catch (AggregateException) { result = new FetchResult { Error = "The companion could not fetch " + (timings ? "unit timings" : "traits") + ". Retrying shortly.", FetchedUtc = DateTime.UtcNow }; }
                bool retryPreparing = result.Payload != null && NeedsPreparationRetry(result.Payload);
                if (result.Payload != null && !retryPreparing && (!timings || SameRequest(current, inFlight)))
                {
                    if (cache.Count >= 64) cache.Clear();
                    cache[inFlight.Key] = result;
                }
                if (SameRequest(current, inFlight))
                {
                    bool written = TryWriteResponse(responsePath, current, result, false);
                    delivered = result.Payload != null && !retryPreparing && written ? current.Id : null;
                    nextFetch = now.AddSeconds(retryPreparing ? preparationRetrySeconds : result.Payload == null ? RetrySeconds : FreshSeconds);
                    if (options.Once) return result.Payload != null && written ? 0 : 2;
                }
                pending = null;
                inFlight = null;
                if (pendingCancellation != null) { pendingCancellation.Dispose(); pendingCancellation = null; }
            }

            if (current != null && (current.Id != delivered || now >= nextFetch) && IsFresh(current.WrittenUtc, now))
            {
                FetchResult cached;
                if (cache.TryGetValue(current.Key, out cached) && !NeedsPreparationRetry(cached.Payload)
                    && (now - cached.FetchedUtc).TotalSeconds < FreshSeconds)
                {
                    bool written = TryWriteResponse(responsePath, current, cached, true);
                    delivered = written ? current.Id : null;
                    if (written) nextFetch = cached.FetchedUtc.AddSeconds(FreshSeconds);
                    if (options.Once) return written ? 0 : 2;
                }
                else if (pending == null && now >= nextFetch && (now - lastStarted).TotalSeconds >= fetchThrottleSeconds)
                {
                    inFlight = current;
                    Request work = inFlight;
                    lastStarted = now;
                    pendingCancellation = CancellationTokenSource.CreateLinkedTokenSource(token);
                    CancellationToken fetchToken = pendingCancellation.Token;
                    pending = Task.Factory.StartNew(delegate { return fetch(options.Endpoint, work, fetchToken); }, fetchToken, TaskCreationOptions.None, TaskScheduler.Default);
                }
            }
            if (options.Once && pending == null && current == null) return 0;
            stop.WaitOne(1000);
        }
        return 0;
        }
        finally
        {
            if (pendingCancellation != null) { pendingCancellation.Cancel(); pendingCancellation.Dispose(); }
        }
    }

    static bool SameRequest(Request left, Request right)
    {
        return left != null && right != null && left.Id == right.Id && left.Key == right.Key;
    }

    static bool NeedsPreparationRetry(Dictionary<string, object> payload)
    {
        if (payload == null) return false;
        object profilesValue;
        if (!payload.TryGetValue("profiles", out profilesValue)) return false;
        IList profiles = profilesValue as IList;
        if (profiles == null) return false;
        foreach (object rawProfile in profiles)
        {
            Dictionary<string, object> profile = rawProfile as Dictionary<string, object>;
            if (profile == null) continue;
            object state;
            if (profile.TryGetValue("status", out state) && state as string == "preparing") return true;
            if (profile.TryGetValue("preparing", out state) && state is bool && (bool)state) return true;
            if (profile.TryGetValue("stale", out state) && state is bool && (bool)state) return true;
            object positionsValue;
            if (!(profile.TryGetValue("positions", out positionsValue))) continue;
            IList positions = positionsValue as IList;
            if (positions == null) continue;
            foreach (object rawPosition in positions)
            {
                Dictionary<string, object> position = rawPosition as Dictionary<string, object>;
                if (position == null) continue;
                if (position.TryGetValue("status", out state) && state as string == "preparing") return true;
                if (position.TryGetValue("preparing", out state) && state is bool && (bool)state) return true;
            }
        }
        return false;
    }

    static bool IsFresh(DateTime written, DateTime now)
    {
        double age = (now - written).TotalSeconds;
        return age >= -60 && age <= FreshSeconds;
    }

    static Request ReadRequest(string path, DateTime now, bool timings = false)
    {
        FileInfo file = new FileInfo(path);
        if (!file.Exists || !IsFresh(file.LastWriteTimeUtc, now)) return null;
        DateTime written = file.LastWriteTimeUtc;
        using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            return ParseRequest(ReadBounded(stream, MaxRequestBytes), written, timings);
    }

    static Request ParseRequest(string json, DateTime written, bool timings = false)
    {
        Dictionary<string, object> obj = Obj(Serializer(MaxRequestBytes).DeserializeObject(json));
        if (Integer(Field(obj, "schema"), 1, 1) != 1) throw Invalid();
        string id = Text(Field(obj, "request_id"), 80);
        if (!SafeRequestId.IsMatch(id) || Text(Field(obj, "map"), 120) != MapName) throw Invalid();
        object[] values = Array(Field(obj, "accounts"), 16);
        if (values.Length < 1) throw Invalid();
        HashSet<string> unique = new HashSet<string>(StringComparer.Ordinal);
        List<string> accounts = new List<string>();
        foreach (object value in values)
        {
            string account = Account(value);
            if (!unique.Add(account)) throw Invalid();
            accounts.Add(account);
        }
        accounts.Sort(StringComparer.Ordinal);
        string unit = timings ? UnitId(Field(obj, "unit")) : null;
        return new Request { Id = id, Accounts = accounts.ToArray(), Unit = unit,
            Key = MapName + "|" + String.Join(",", accounts.ToArray()) + (timings ? "|" + unit : ""), WrittenUtc = written };
    }

    static Uri RequestUri(Uri endpoint, Request request)
    {
        if (request.Catalog) return endpoint;
        return new Uri(endpoint.AbsoluteUri + "?accounts=" + Uri.EscapeDataString(String.Join(",", request.Accounts)) + "&map=" + Uri.EscapeDataString(MapName)
            + (request.Unit == null ? "" : "&unit=" + Uri.EscapeDataString(request.Unit)));
    }

    static bool AllowedEndpoint(Uri uri)
    {
        return AllowedServiceEndpoint(uri, "/api/widget/traits");
    }

    static bool AllowedServiceEndpoint(Uri uri, string path)
    {
        return uri != null && uri.IsAbsoluteUri && uri.Scheme == Uri.UriSchemeHttps && uri.Port == 443 &&
            uri.UserInfo.Length == 0 && uri.Fragment.Length == 0 && uri.AbsolutePath == path &&
            (String.Equals(uri.Host, "bar-fight.com", StringComparison.OrdinalIgnoreCase) ||
             String.Equals(uri.Host, "replay.164.90.210.36.sslip.io", StringComparison.OrdinalIgnoreCase));
    }

    static Uri RedirectUri(Uri current, string location, Request request)
    {
        Uri target;
        string path = request.Catalog ? TimingUnitsPath : request.Unit != null ? TimingPath : "/api/widget/traits";
        if (String.IsNullOrEmpty(location) || !Uri.TryCreate(current, location, out target) || !AllowedServiceEndpoint(target, path)) throw Invalid();
        // A redirect may only select another approved endpoint, never alter the requested accounts.
        UriBuilder clean = new UriBuilder(target) { Query = "" };
        Uri expected = RequestUri(clean.Uri, request);
        if (target.Query.Length != 0 && target.Query != expected.Query) throw Invalid();
        return expected;
    }

    static FetchResult Fetch(Uri endpoint, Request request, CancellationToken token)
    {
        FetchResult result = FetchOnce(endpoint, request, token);
        if (!token.IsCancellationRequested && ShouldUseLegacy(endpoint, result))
            result = FetchOnce(new Uri(LegacyEndpoint), request, token);
        return result;
    }

    static Dictionary<string, object> timingCatalog;
    static DateTime catalogFetched = DateTime.MinValue;
    static DateTime catalogRetry = DateTime.MinValue;

    static Uri ServiceUri(Uri endpoint, string path)
    {
        return new UriBuilder(endpoint) { Path = path, Query = "", Fragment = "" }.Uri;
    }

    static FetchResult FetchTimings(Uri endpoint, Request request, CancellationToken token)
    {
        Uri timingEndpoint = ServiceUri(endpoint, TimingPath);
        FetchResult result = FetchOnce(timingEndpoint, request, token);
        if (!token.IsCancellationRequested && String.Equals(endpoint.Host, new Uri(DefaultEndpoint).Host, StringComparison.OrdinalIgnoreCase)
            && result.Payload == null && result.AllowLegacyFallback)
            result = FetchOnce(ServiceUri(new Uri(LegacyEndpoint), TimingPath), request, token);
        if (result.Payload == null || token.IsCancellationRequested) return result;
        DateTime now = DateTime.UtcNow;
        // Only the timing worker uses this cache. Catalogue errors never erase a
        // valid player result, and retries are bounded even when the service fails.
        if ((timingCatalog == null || (now - catalogFetched).TotalHours >= 6) && now >= catalogRetry)
        {
            catalogRetry = now.AddMinutes(5);
            FetchResult catalog = FetchOnce(ServiceUri(new Uri(result.Endpoint ?? timingEndpoint.AbsoluteUri), TimingUnitsPath),
                new Request { Catalog = true }, token);
            if (catalog.Payload != null) { timingCatalog = catalog.Payload; catalogFetched = now; }
        }
        if (timingCatalog != null)
        {
            result.Payload["units"] = Field(timingCatalog, "units");
            result.Payload["default_unit"] = Field(timingCatalog, "default_unit");
        }
        return result;
    }

    static bool ShouldUseLegacy(Uri endpoint, FetchResult result)
    {
        return endpoint.AbsoluteUri == DefaultEndpoint && result.Payload == null && result.AllowLegacyFallback;
    }

    static bool RetryableForLegacy(WebExceptionStatus status, int? httpStatus)
    {
        if (status == WebExceptionStatus.ProtocolError) return httpStatus == 503;
        return status == WebExceptionStatus.ConnectFailure || status == WebExceptionStatus.NameResolutionFailure ||
            status == WebExceptionStatus.ProxyNameResolutionFailure || status == WebExceptionStatus.ReceiveFailure ||
            status == WebExceptionStatus.SendFailure || status == WebExceptionStatus.ConnectionClosed ||
            status == WebExceptionStatus.KeepAliveFailure || status == WebExceptionStatus.Timeout ||
            status == WebExceptionStatus.SecureChannelFailure || status == WebExceptionStatus.TrustFailure ||
            status == WebExceptionStatus.RequestCanceled;
    }

    static bool IsCanonicalNonJsonResponse(Uri uri, int status, string contentType)
    {
        string media = (contentType ?? "").Split(';')[0].Trim();
        return AllowedEndpoint(uri) && String.Equals(uri.Host, "bar-fight.com", StringComparison.OrdinalIgnoreCase) &&
            status == 200 && !String.Equals(media, "application/json", StringComparison.OrdinalIgnoreCase);
    }

    static FetchResult FetchOnce(Uri endpoint, Request request, CancellationToken token)
    {
        CancellationToken stopToken = token;
        bool attemptedLegacy = false;
        try
        {
            using (CancellationTokenSource deadline = CancellationTokenSource.CreateLinkedTokenSource(token))
            {
            deadline.CancelAfter(20000);
            token = deadline.Token;
            Uri current = RequestUri(endpoint, request);
            for (int redirects = 0; redirects <= 2; redirects++)
            {
                token.ThrowIfCancellationRequested();
                if (String.Equals(current.Host, new Uri(LegacyEndpoint).Host, StringComparison.OrdinalIgnoreCase)) attemptedLegacy = true;
                HttpWebRequest http = (HttpWebRequest)WebRequest.Create(current);
                http.Method = "GET";
                http.AllowAutoRedirect = false;
                http.Timeout = 12000;
                http.ReadWriteTimeout = 12000;
                http.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
                http.Accept = "application/json";
                http.UserAgent = "BARFightBridge/1.0";
                http.UseDefaultCredentials = false;
                http.CookieContainer = null;
                using (token.Register(delegate { http.Abort(); }))
                using (HttpWebResponse response = (HttpWebResponse)http.GetResponse())
                {
                    int code = (int)response.StatusCode;
                    if (code == 301 || code == 302 || code == 303 || code == 307 || code == 308)
                    {
                        if (redirects == 2) throw Invalid();
                        current = RedirectUri(current, response.Headers[HttpResponseHeader.Location], request);
                        continue;
                    }
                    if (response.StatusCode != HttpStatusCode.OK) throw Invalid();
                    string media = (response.ContentType ?? "").Split(';')[0].Trim();
                    if (!String.Equals(media, "application/json", StringComparison.OrdinalIgnoreCase))
                    {
                        // During DNS migration an old parking host can return valid TLS
                        // with an HTML page. Never consume that body or accept it as data.
                        return new FetchResult { Error = "BAR Fight returned an unsupported response. The companion will retry shortly.",
                            ErrorCode = "unexpected-content-type", FetchedUtc = DateTime.UtcNow,
                            AllowLegacyFallback = !attemptedLegacy && (IsCanonicalNonJsonResponse(current, code, response.ContentType)
                                || request.Unit != null && AllowedServiceEndpoint(current, TimingPath) && String.Equals(current.Host, "bar-fight.com", StringComparison.OrdinalIgnoreCase)) };
                    }
                    if (response.ContentLength > MaxResponseBytes) throw Invalid();
                    using (Stream body = response.GetResponseStream())
                    {
                        string json = ReadBounded(body, MaxResponseBytes);
                        return new FetchResult { Payload = request.Catalog ? ValidateCatalog(json) : request.Unit != null ? ValidateTimingResponse(json, request) : ValidateResponse(json, request), FetchedUtc = DateTime.UtcNow,
                            Endpoint = current.GetLeftPart(UriPartial.Path) };
                    }
                }
            }
            throw Invalid();
            }
        }
        catch (WebException error)
        {
            HttpWebResponse failure = error.Response as HttpWebResponse;
            int? code = failure != null ? (int?)failure.StatusCode : null;
            if (error.Response != null) error.Response.Close();
            return new FetchResult { Error = "BAR Fight is offline or unavailable. The companion will retry shortly.", FetchedUtc = DateTime.UtcNow,
                ErrorCode = "transport-unavailable",
                AllowLegacyFallback = !stopToken.IsCancellationRequested && !attemptedLegacy && RetryableForLegacy(error.Status, code) };
        }
        catch (OperationCanceledException)
        {
            return new FetchResult { Error = stopToken.IsCancellationRequested ? "The companion was stopped." :
                "BAR Fight timed out. The companion will retry shortly.", FetchedUtc = DateTime.UtcNow,
                ErrorCode = stopToken.IsCancellationRequested ? "stopped" : "timeout",
                AllowLegacyFallback = !stopToken.IsCancellationRequested && !attemptedLegacy };
        }
        catch (Exception)
        {
            return new FetchResult { Error = "BAR Fight returned an invalid profile response. The companion will retry shortly.",
                ErrorCode = "invalid-response", FetchedUtc = DateTime.UtcNow };
        }
    }

    static Dictionary<string, object> ValidateResponse(string json, Request request)
    {
        Dictionary<string, object> source = Obj(Serializer(MaxResponseBytes).DeserializeObject(json));
        Integer(Field(source, "schema"), 1, 1);
        if (Text(Field(source, "map"), 120) != MapName) throw Invalid();
        string status = Text(Field(source, "status"), 40);
        if (status != "available" && status != "preparing") throw Invalid();
        object[] rawProfiles = Array(Field(source, "profiles"), 16);
        HashSet<string> wanted = new HashSet<string>(request.Accounts, StringComparer.Ordinal);
        List<object> profiles = new List<object>();
        foreach (object raw in rawProfiles)
        {
            Dictionary<string, object> profile = Obj(raw);
            string account = Account(Field(profile, "account_id"));
            if (!wanted.Remove(account)) throw Invalid();
            List<object> positions = new List<object>();
            HashSet<string> seenPositions = new HashSet<string>(StringComparer.Ordinal);
            foreach (object rawPosition in Array(Field(profile, "positions"), 8))
            {
                Dictionary<string, object> position = Obj(rawPosition);
                string spot = Text(Field(position, "spot"), 2);
                if (spot.Length != 2 || spot[0] != 'P' || spot[1] < '1' || spot[1] > '8' || !seenPositions.Add(spot)) throw Invalid();
                List<object> traits = new List<object>();
                HashSet<string> seenTraits = new HashSet<string>(StringComparer.Ordinal);
                foreach (object rawTrait in Array(Field(position, "traits"), 12))
                {
                    Dictionary<string, object> trait = Obj(rawTrait);
                    string traitId = Text(Field(trait, "id"), 80);
                    if (!SafeRequestId.IsMatch(traitId) || !seenTraits.Add(traitId)) throw Invalid();
                    traits.Add(new Dictionary<string, object> {
                        {"id", traitId}, {"label", Text(Field(trait, "label"), 160)},
                        {"description", Text(Field(trait, "description"), 2000)},
                        {"frequency_percent", Number(Field(trait, "frequency_percent"), 0, 100)},
                        {"samples", Integer(Field(trait, "samples"), 10, Int32.MaxValue)}
                    });
                }
                Dictionary<string, object> cleanPosition = new Dictionary<string, object> {
                    {"spot", spot}, {"position_name", Text(Field(position, "position_name"), 120)},
                    {"games", Integer(Field(position, "games"), 0, Int32.MaxValue)},
                    {"coverage_percent", Number(Field(position, "coverage_percent"), 0, 100)},
                    {"traits", traits}, {"status", Status(Field(position, "status"))}
                };
                object optional;
                if (position.TryGetValue("preparing", out optional)) cleanPosition["preparing"] = Boolean(optional);
                if (position.TryGetValue("preparation_percent", out optional))
                    cleanPosition["preparation_percent"] = Number(optional, 0, 100);
                if (position.TryGetValue("prepared_games", out optional))
                    cleanPosition["prepared_games"] = Integer(optional, 0, Int32.MaxValue);
                if (position.TryGetValue("preparation_note", out optional))
                    cleanPosition["preparation_note"] = Text(optional, 160);
                positions.Add(cleanPosition);
            }
            Dictionary<string, object> cleanProfile = new Dictionary<string, object> {
                {"account_id", account}, {"name", Text(Field(profile, "name"), 120)},
                {"status", Status(Field(profile, "status"))}, {"period", Period(Field(profile, "period"))},
                {"generated_at", Timestamp(Field(profile, "generated_at"))}, {"stale", Boolean(Field(profile, "stale"))},
                {"positions", positions}
            };
            object profilePreparing;
            if (profile.TryGetValue("preparing", out profilePreparing)) cleanProfile["preparing"] = Boolean(profilePreparing);
            object profileNote;
            if (profile.TryGetValue("preparation_note", out profileNote)) cleanProfile["preparation_note"] = Text(profileNote, 160);
            profiles.Add(cleanProfile);
        }
        if (wanted.Count != 0) throw Invalid();
        return new Dictionary<string, object> {
            {"schema", 1}, {"map", MapName}, {"period", Period(Field(source, "period"))},
            {"generated_at", Timestamp(Field(source, "generated_at"))}, {"status", status}, {"profiles", profiles}
        };
    }

    static string UnitId(object value)
    {
        string id = Text(value, 100);
        if (!UnitPattern.IsMatch(id)) throw Invalid();
        return id;
    }

    static Dictionary<string, object> CleanUnit(object value)
    {
        Dictionary<string, object> unit = Obj(value);
        string id = UnitId(Field(unit, "id")), kind = Text(Field(unit, "kind"), 10);
        if (kind != "unit" && kind != "group" || (kind == "group") != id.StartsWith("group:", StringComparison.Ordinal)) throw Invalid();
        return new Dictionary<string, object> { {"id", id}, {"label", SingleLine(Field(unit, "label"), 160)}, {"kind", kind} };
    }

    static Dictionary<string, object> ValidateCatalog(string json)
    {
        Dictionary<string, object> source = Obj(Serializer(MaxResponseBytes).DeserializeObject(json));
        Integer(Field(source, "schema"), 1, 1);
        if (Text(Field(source, "status"), 40) != "available") throw Invalid();
        string defaultUnit = UnitId(Field(source, "default_unit"));
        List<object> units = new List<object>();
        HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (object raw in Array(Field(source, "units"), 1000))
        {
            Dictionary<string, object> unit = CleanUnit(raw);
            if (!seen.Add((string)unit["id"])) throw Invalid();
            units.Add(unit);
        }
        if (!seen.Contains(defaultUnit)) throw Invalid();
        return new Dictionary<string, object> { {"units", units}, {"default_unit", defaultUnit} };
    }

    static Dictionary<string, object> ValidateTimingResponse(string json, Request request)
    {
        Dictionary<string, object> source = Obj(Serializer(MaxResponseBytes).DeserializeObject(json));
        Integer(Field(source, "schema"), 1, 1);
        if (Text(Field(source, "map"), 120) != MapName || Text(Field(source, "method"), 80) != "creator-first-ready-v1") throw Invalid();
        string status = Text(Field(source, "status"), 40);
        if (status != "available" && status != "preparing") throw Invalid();
        Dictionary<string, object> unit = CleanUnit(Field(source, "unit"));
        if ((string)unit["id"] != request.Unit) throw Invalid();
        HashSet<string> wanted = new HashSet<string>(request.Accounts, StringComparer.Ordinal);
        List<object> profiles = new List<object>();
        foreach (object raw in Array(Field(source, "profiles"), 16))
        {
            Dictionary<string, object> profile = Obj(raw);
            string account = Account(Field(profile, "account_id"));
            if (!wanted.Remove(account)) throw Invalid();
            List<object> positions = new List<object>();
            HashSet<string> spots = new HashSet<string>(StringComparer.Ordinal);
            foreach (object rawPosition in Array(Field(profile, "positions"), 8))
            {
                Dictionary<string, object> position = Obj(rawPosition);
                string spot = Text(Field(position, "spot"), 2);
                if (spot.Length != 2 || spot[0] != 'P' || spot[1] < '1' || spot[1] > '8' || !spots.Add(spot)) throw Invalid();
                int games = Integer(Field(position, "games"), 0, Int32.MaxValue);
                int coverage = Integer(Field(position, "coverage_games"), 0, games);
                int samples = Integer(Field(position, "samples"), 0, coverage);
                string positionStatus = TimingStatus(Field(position, "status"));
                object mean = Field(position, "mean_seconds"), median = Field(position, "median_seconds"), occurrence = Field(position, "occurrence_percent");
                if ((samples == 0) != (mean == null) || (samples == 0) != (median == null) || (coverage == 0) != (occurrence == null)) throw Invalid();
                if (positionStatus == "available" && samples == 0 || positionStatus == "not_observed" && samples != 0) throw Invalid();
                if (samples > 0 && (Number(mean, 0, 86400) <= 0 || Number(median, 0, 86400) <= 0)) throw Invalid();
                Dictionary<string, object> cleanPosition = new Dictionary<string, object> {
                    {"spot", spot}, {"position_name", SingleLine(Field(position, "position_name"), 120)}, {"games", games},
                    {"status", positionStatus}, {"samples", samples}, {"coverage_games", coverage},
                    {"coverage_percent", Number(Field(position, "coverage_percent"), 0, 100)},
                    {"occurrence_percent", occurrence == null ? null : (object)Number(occurrence, 0, 100)},
                    {"mean_seconds", mean == null ? null : (object)Number(mean, 0, 86400)},
                    {"median_seconds", median == null ? null : (object)Number(median, 0, 86400)}
                };
                object preparing;
                if (position.TryGetValue("preparing", out preparing)) cleanPosition["preparing"] = Boolean(preparing);
                positions.Add(cleanPosition);
            }
            object reason = Field(profile, "stale_reason");
            profiles.Add(new Dictionary<string, object> {
                {"account_id", account}, {"name", SingleLine(Field(profile, "name"), 120)}, {"status", TimingStatus(Field(profile, "status"))},
                {"period", Period(Field(profile, "period"))}, {"generated_at", Timestamp(Field(profile, "generated_at"))},
                {"checked_at", Timestamp(Field(profile, "checked_at"))}, {"stale", Boolean(Field(profile, "stale"))},
                {"stale_reason", reason == null ? null : (object)Text(reason, 200)}, {"preparing", Boolean(Field(profile, "preparing"))},
                {"positions", positions}
            });
        }
        if (wanted.Count != 0) throw Invalid();
        return new Dictionary<string, object> {
            {"schema", 1}, {"map", MapName}, {"method", "creator-first-ready-v1"}, {"unit", unit}, {"status", status},
            {"period", Period(Field(source, "period"))}, {"generated_at", Timestamp(Field(source, "generated_at"))},
            {"checked_at", Timestamp(Field(source, "checked_at"))}, {"profiles", profiles}
        };
    }

    static string TimingStatus(object value)
    {
        string status = Text(value, 40);
        if (status != "available" && status != "not_observed" && status != "unavailable" && status != "preparing" && status != "no_data") throw Invalid();
        return status;
    }

    static string SingleLine(object value, int limit)
    {
        string text = Text(value, limit);
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (Char.IsControl(c)) throw Invalid();
            if (Char.IsHighSurrogate(c))
            {
                if (++i >= text.Length || !Char.IsLowSurrogate(text[i])) throw Invalid();
            }
            else if (Char.IsLowSurrogate(c)) throw Invalid();
        }
        return text;
    }

    static bool TryWriteResponse(string path, Request request, FetchResult result, bool cached)
    {
        try
        {
            Dictionary<string, object> response = result.Payload != null ? new Dictionary<string, object>(result.Payload) :
                new Dictionary<string, object> { {"schema", 1}, {"profiles", new object[0]}, {"status", "offline"}, {"error", result.Error} };
            response["request_id"] = request.Id;
            response["ok"] = result.Payload != null;
            response["fetched_at"] = result.FetchedUtc.ToString("o", CultureInfo.InvariantCulture);
            response["cached"] = cached;
            if (request.Unit != null) response["requested_unit"] = request.Unit;
            if (result.Endpoint != null) response["service_url"] = result.Endpoint;
            if (result.ErrorCode != null) response["error_code"] = result.ErrorCode;
            AtomicWrite(path, Serializer(MaxResponseBytes).Serialize(response));
            return true;
        }
        catch (InvalidDataException) { return false; }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
        catch (InvalidOperationException) { return false; }
    }

    static void AtomicWrite(string path, string json)
    {
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            byte[] bytes = Utf8.GetBytes(json);
            if (bytes.Length > MaxResponseBytes) throw Invalid();
            using (FileStream file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                file.Write(bytes, 0, bytes.Length);
                file.Flush(true);
            }
            if (File.Exists(path)) File.Replace(temporary, path, null);
            else File.Move(temporary, path);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    static string ReadBounded(Stream stream, int limit)
    {
        if (stream == null) throw Invalid();
        using (MemoryStream data = new MemoryStream())
        {
            byte[] buffer = new byte[8192];
            int read;
            while ((read = stream.Read(buffer, 0, Math.Min(buffer.Length, limit + 1 - (int)data.Length))) > 0)
            {
                data.Write(buffer, 0, read);
                if (data.Length > limit) throw Invalid();
            }
            return Utf8.GetString(data.ToArray());
        }
    }

    static JavaScriptSerializer Serializer(int limit)
    {
        return new JavaScriptSerializer { MaxJsonLength = limit, RecursionLimit = 20 };
    }
    static InvalidDataException Invalid() { return new InvalidDataException("Invalid traits data."); }
    static Dictionary<string, object> Obj(object value) { Dictionary<string, object> result = value as Dictionary<string, object>; if (result == null) throw Invalid(); return result; }
    static object Field(Dictionary<string, object> obj, string name) { object value; if (!obj.TryGetValue(name, out value)) throw Invalid(); return value; }
    static object[] Array(object value, int limit) { object[] result = value as object[]; if (result == null || result.Length > limit) throw Invalid(); return result; }
    static string Text(object value, int limit) { string result = value as string; if (result == null || result.Length > limit) throw Invalid(); foreach (char c in result) if (Char.IsControl(c) && c != '\n' && c != '\t') throw Invalid(); return result; }
    static bool Boolean(object value) { if (!(value is bool)) throw Invalid(); return (bool)value; }
    static double Number(object value, double low, double high)
    {
        if (!(value is int) && !(value is long) && !(value is decimal) && !(value is double)) throw Invalid();
        double number = Convert.ToDouble(value, CultureInfo.InvariantCulture);
        if (Double.IsNaN(number) || Double.IsInfinity(number) || number < low || number > high) throw Invalid();
        return number;
    }
    static int Integer(object value, int low, int high) { double number = Number(value, low, high); if (number != Math.Truncate(number)) throw Invalid(); return (int)number; }
    static string Account(object value)
    {
        string result = Text(value, 16);
        ulong number;
        if (!AccountPattern.IsMatch(result) || !UInt64.TryParse(result, NumberStyles.None, CultureInfo.InvariantCulture, out number) || number > 9007199254740991UL) throw Invalid();
        return result;
    }
    static string Status(object value) { string result = Text(value, 40); if (!ProfileStatuses.Contains(result)) throw Invalid(); return result; }
    static object Timestamp(object value) { return value == null ? null : (object)Number(value, 0, 253402300799); }
    static Dictionary<string, object> Period(object value)
    {
        Dictionary<string, object> period = Obj(value);
        string start = Text(Field(period, "start_date"), 10), end = Text(Field(period, "end_date"), 10);
        DateTime first, last;
        if (!DateTime.TryParseExact(start, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out first) ||
            !DateTime.TryParseExact(end, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out last) || last < first) throw Invalid();
        return new Dictionary<string, object> { {"start_date", start}, {"end_date", end} };
    }

    static int SelfTest()
    {
        int checks = 0;
        Action<bool> check = delegate(bool success) { checks++; if (!success) throw new InvalidOperationException("Self-test failed at check " + checks); };
        Action<Action> rejects = delegate(Action action) { bool rejected = false; try { action(); } catch (Exception) { rejected = true; } check(rejected); };
        DateTime now = DateTime.UtcNow;
        string valid = "{\"schema\":1,\"request_id\":\"bft-1-2-3\",\"map\":\"Supreme Isthmus v2.1\",\"accounts\":[\"21705\",\"42\"]}";
        Request request = ParseRequest(valid, now);
        check(request.Accounts.Length == 2 && request.Id == "bft-1-2-3");
        rejects(delegate { ParseRequest(valid.Replace("21705", "021705"), now); });
        rejects(delegate { ParseRequest(valid.Replace("21705", "9007199254740992"), now); });
        rejects(delegate { ParseRequest(valid.Replace("\"42\"", "\"21705\""), now); });
        rejects(delegate { ParseRequest(valid.Replace("bft-1-2-3", "../file"), now); });
        rejects(delegate { ParseRequest(valid.Replace("Supreme Isthmus v2.1", "Other map"), now); });
        rejects(delegate { ParseRequest(valid.Replace("\"schema\":1", "\"schema\":true"), now); });
        check(IsFresh(now.AddSeconds(-299), now) && !IsFresh(now.AddSeconds(-301), now) && !IsFresh(now.AddSeconds(61), now));
        check(AllowedEndpoint(new Uri(DefaultEndpoint)) && AllowedEndpoint(new Uri("https://replay.164.90.210.36.sslip.io/api/widget/traits")));
        check(!AllowedEndpoint(new Uri("http://bar-fight.com/api/widget/traits")) && !AllowedEndpoint(new Uri("https://bar-fight.com.evil.example/api/widget/traits")));
        check(!AllowedEndpoint(new Uri("https://user@bar-fight.com/api/widget/traits")) && !AllowedEndpoint(new Uri("https://bar-fight.com:444/api/widget/traits")));
        Uri fetch = RequestUri(new Uri(DefaultEndpoint), request);
        check(RedirectUri(fetch, "/api/widget/traits", request).Query == fetch.Query);
        rejects(delegate { RedirectUri(fetch, "https://example.com/api/widget/traits", request); });
        rejects(delegate { RedirectUri(fetch, "http://bar-fight.com/api/widget/traits", request); });
        rejects(delegate { RedirectUri(fetch, "/api/widget/traits?accounts=999", request); });
        check(RetryableForLegacy(WebExceptionStatus.NameResolutionFailure, null));
        check(RetryableForLegacy(WebExceptionStatus.TrustFailure, null));
        check(RetryableForLegacy(WebExceptionStatus.ProtocolError, 503));
        check(!RetryableForLegacy(WebExceptionStatus.ProtocolError, 400) && !RetryableForLegacy(WebExceptionStatus.ProtocolError, 429));
        check(!RetryableForLegacy(WebExceptionStatus.ProtocolError, 500));
        check(ShouldUseLegacy(new Uri(DefaultEndpoint), new FetchResult { AllowLegacyFallback = true }));
        check(!ShouldUseLegacy(new Uri(LegacyEndpoint), new FetchResult { AllowLegacyFallback = true }));
        check(!ShouldUseLegacy(new Uri(DefaultEndpoint), new FetchResult { Error = "Invalid payload" }));
        check(IsCanonicalNonJsonResponse(fetch, 200, "text/html; charset=utf-8"));
        check(!IsCanonicalNonJsonResponse(fetch, 200, "application/json; charset=utf-8"));
        check(!IsCanonicalNonJsonResponse(fetch, 404, "text/html"));
        check(!IsCanonicalNonJsonResponse(new Uri(LegacyEndpoint), 200, "text/html"));
        rejects(delegate { ReadBounded(new MemoryStream(new byte[17]), 16); });
        rejects(delegate { ReadBounded(new MemoryStream(new byte[] { 255 }), 16); });
        string period = "{\"start_date\":\"2026-08-24\",\"end_date\":\"2026-09-23\"}";
        string profile = "{\"account_id\":\"21705\",\"name\":\"Player\",\"status\":\"available\",\"period\":" + period + ",\"generated_at\":1790000000,\"stale\":false,\"positions\":[{\"spot\":\"P1\",\"position_name\":\"Pond\",\"games\":12,\"coverage_percent\":100,\"status\":\"available\",\"traits\":[{\"id\":\"same-opener\",\"label\":\"Consistent opener\",\"description\":\"Plain text only\",\"frequency_percent\":75,\"samples\":12}]}]}";
        string server = "{\"schema\":1,\"map\":\"Supreme Isthmus v2.1\",\"period\":" + period + ",\"generated_at\":1790000000,\"status\":\"available\",\"profiles\":[" + profile + "," + profile.Replace("21705", "42") + "]}";
        check(ValidateResponse(server, request).ContainsKey("profiles"));
        Dictionary<string, object> readyPayload = ValidateResponse(server, request);
        check(!NeedsPreparationRetry(readyPayload));
        check(NeedsPreparationRetry(ValidateResponse(server.Replace("\"status\":\"available\"", "\"status\":\"preparing\""), request)));
        check(NeedsPreparationRetry(ValidateResponse(server.Replace("\"stale\":false", "\"stale\":true"), request)));
        string partial = server.Replace("\"stale\":false", "\"stale\":false,\"preparing\":true")
            .Replace("\"status\":\"available\",\"traits\"", "\"status\":\"available\",\"preparing\":true,\"prepared_games\":5,\"preparation_percent\":50,\"preparation_note\":\"History is being prepared...\",\"traits\"");
        if (partial.IndexOf("prepared_games", StringComparison.Ordinal) < 0) throw new InvalidOperationException("Preparation fields did not enter self-test payload.");
        Dictionary<string, object> partialPayload;
        partialPayload = ValidateResponse(partial, request);
        check(NeedsPreparationRetry(partialPayload));
        Dictionary<string, object> partialProfile = Obj(((IList)Field(partialPayload, "profiles"))[0]);
        Dictionary<string, object> partialPosition = Obj(((IList)Field(partialProfile, "positions"))[0]);
        check(Boolean(Field(partialProfile, "preparing")) && Boolean(Field(partialPosition, "preparing"))
            && Integer(Field(partialPosition, "prepared_games"), 0, Int32.MaxValue) == 5
            && Text(Field(partialPosition, "preparation_note"), 160) == "History is being prepared...");
        check(ValidateResponse(server.Replace("1790000000", "null"), request).ContainsKey("profiles"));
        rejects(delegate { ValidateResponse(server.Replace("\"42\"", "\"21705\""), request); });
        rejects(delegate { ValidateResponse(server.Replace("\"42\"", "\"99\""), request); });
        rejects(delegate { ValidateResponse(server.Replace("\"samples\":12", "\"samples\":9"), request); });
        rejects(delegate { ValidateResponse(server.Replace("\"frequency_percent\":75", "\"frequency_percent\":101"), request); });
        rejects(delegate { ValidateResponse(server.Replace("\"coverage_percent\":100", "\"coverage_percent\":null"), request); });
        rejects(delegate { ValidateResponse(server.Replace("\"P1\"", "\"P9\""), request); });
        rejects(delegate { ValidateResponse(server.Replace("2026-08-24", "2026-09-30"), request); });
        string directory = Path.Combine(Path.GetTempPath(), "BARFightBridge-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            string path = Path.Combine(directory, "response.json");
            AtomicWrite(path, "{\"first\":true}");
            AtomicWrite(path, "{\"second\":true}");
            check(File.ReadAllText(path) == "{\"second\":true}" && Directory.GetFiles(directory).Length == 1);
            string input = Path.Combine(directory, "request.json");
            File.WriteAllText(input, valid, Utf8);
            File.SetLastWriteTimeUtc(input, now.AddMinutes(-6));
            check(ReadRequest(input, now) == null);
            File.Delete(input);
            File.Delete(path);
        }
        finally { Directory.Delete(directory, false); }
        TestMalformedRecovery(check, valid, server);
        TestPreparationRetry(check, valid, server);
        TestCachedDelivery(check, valid, server);
        TestTimings(check, rejects, valid, period);
        Console.WriteLine("BAR Fight companion: " + checks + " offline self-tests passed.");
        return 0;
    }

    static void TestTimings(Action<bool> check, Action<Action> rejects, string traitsRequest, string period)
    {
        DateTime now = DateTime.UtcNow;
        string requestJson = traitsRequest.Replace("\"accounts\":", "\"unit\":\"group:t2-constructor\",\"accounts\":");
        Request request = ParseRequest(requestJson, now, true);
        string unit = "{\"id\":\"group:t2-constructor\",\"label\":\"T2 constructors\",\"kind\":\"group\"}";
        string position = "{\"spot\":\"P2\",\"position_name\":\"Tech\",\"games\":12,\"status\":\"available\",\"samples\":9,\"coverage_games\":10,\"coverage_percent\":83.3,\"occurrence_percent\":90,\"mean_seconds\":302.4,\"median_seconds\":295}";
        string profile = "{\"account_id\":\"21705\",\"name\":\"Player\",\"status\":\"available\",\"period\":" + period + ",\"generated_at\":1790000000,\"checked_at\":1790000000,\"stale\":false,\"stale_reason\":null,\"preparing\":false,\"positions\":[" + position + "]}";
        string server = "{\"schema\":1,\"method\":\"creator-first-ready-v1\",\"unit\":" + unit + ",\"map\":\"Supreme Isthmus v2.1\",\"period\":" + period + ",\"status\":\"available\",\"generated_at\":1790000000,\"checked_at\":1790000000,\"profiles\":[" + profile + "," + profile.Replace("21705", "42") + "]}";
        check(ValidateTimingResponse(server, request).ContainsKey("unit"));
        check(!NeedsPreparationRetry(ValidateTimingResponse(server, request)));
        check(NeedsPreparationRetry(ValidateTimingResponse(server.Replace("\"preparing\":false", "\"preparing\":true"), request)));
        check(NeedsPreparationRetry(ValidateTimingResponse(server.Replace("\"stale\":false", "\"stale\":true"), request)));
        check(ValidateTimingResponse(server.Replace("1790000000", "null"), request).ContainsKey("profiles"));
        string absent = position.Replace("\"status\":\"available\"", "\"status\":\"not_observed\"").Replace("\"samples\":9", "\"samples\":0")
            .Replace("\"mean_seconds\":302.4", "\"mean_seconds\":null").Replace("\"median_seconds\":295", "\"median_seconds\":null").Replace("\"occurrence_percent\":90", "\"occurrence_percent\":0");
        check(ValidateTimingResponse(server.Replace(position, absent), request).ContainsKey("profiles"));
        string uncovered = absent.Replace("\"status\":\"not_observed\"", "\"status\":\"unavailable\"").Replace("\"coverage_games\":10", "\"coverage_games\":0")
            .Replace("\"coverage_percent\":83.3", "\"coverage_percent\":0").Replace("\"occurrence_percent\":0", "\"occurrence_percent\":null");
        check(ValidateTimingResponse(server.Replace(position, uncovered), request).ContainsKey("profiles"));
        rejects(delegate { ParseRequest(requestJson.Replace("group:t2-constructor", "https://example.com"), now, true); });
        rejects(delegate { ParseRequest(requestJson.Replace("group:t2-constructor", "unit:armack"), now, true); });
        rejects(delegate { ValidateTimingResponse(server.Replace("302.4", "null"), request); });
        rejects(delegate { ValidateTimingResponse(server.Replace("302.4", "0"), request); });
        rejects(delegate { ValidateTimingResponse(server.Replace("302.4", "86401"), request); });
        rejects(delegate { ValidateTimingResponse(server.Replace("\"samples\":9", "\"samples\":11"), request); });
        rejects(delegate { ValidateTimingResponse(server.Replace("\"coverage_games\":10", "\"coverage_games\":13"), request); });
        rejects(delegate { ValidateTimingResponse(server.Replace("\"occurrence_percent\":90", "\"occurrence_percent\":null"), request); });
        rejects(delegate { ValidateTimingResponse(server.Replace("\"coverage_percent\":83.3", "\"coverage_percent\":101"), request); });
        rejects(delegate { ValidateTimingResponse(server.Replace("\"42\"", "\"99\""), request); });
        rejects(delegate { ValidateTimingResponse(server.Replace("\"42\"", "\"21705\""), request); });
        rejects(delegate { ValidateTimingResponse(server.Replace("\"T2 constructors\"", "\"T2\\nconstructors\""), request); });
        rejects(delegate { ValidateTimingResponse(server.Replace("\"Tech\"", "\"Tech\\u0000\""), request); });
        rejects(delegate { SingleLine("Tech\uD800", 120); });
        rejects(delegate { ValidateTimingResponse(server.Replace("\"id\":\"group:t2-constructor\"", "\"id\":\"group:t2-air\""), request); });
        string catalog = "{\"schema\":1,\"status\":\"available\",\"default_unit\":\"group:t2-constructor\",\"units\":[" + unit + "]}";
        check(ValidateCatalog(catalog).ContainsKey("units"));
        rejects(delegate { ValidateCatalog(catalog.Replace("[" + unit + "]", "[" + unit + "," + unit + "]")); });
        rejects(delegate { ValidateCatalog(catalog.Replace("\"default_unit\":\"group:t2-constructor\"", "\"default_unit\":\"armack\"")); });
        Uri endpoint = ServiceUri(new Uri(DefaultEndpoint), TimingPath);
        check(RequestUri(endpoint, request).Query.Contains("unit=group%3At2-constructor"));
        check(AllowedServiceEndpoint(endpoint, TimingPath) && !AllowedServiceEndpoint(new Uri("http://bar-fight.com" + TimingPath), TimingPath));
        check(!AllowedServiceEndpoint(new Uri("https://bar-fight.com.evil.example" + TimingPath), TimingPath));
        check(!AllowedServiceEndpoint(new Uri("https://user@bar-fight.com" + TimingPath), TimingPath));
        check(RedirectUri(RequestUri(endpoint, request), TimingPath, request).Query == RequestUri(endpoint, request).Query);
        rejects(delegate { RedirectUri(RequestUri(endpoint, request), TimingPath + "?accounts=999", request); });
        rejects(delegate { RedirectUri(RequestUri(endpoint, request), "/api/widget/traits", request); });
        rejects(delegate { RedirectUri(RequestUri(endpoint, request), "https://example.com" + TimingPath, request); });
        TestTimingChannel(check, requestJson, server);
    }

    static void TestTimingChannel(Action<bool> check, string requestJson, string server)
    {
        string directory = Path.Combine(Path.GetTempPath(), "BARFightBridge-timing-" + Guid.NewGuid().ToString("N"));
        string config = Path.Combine(directory, "LuaUI", "Config");
        string input = Path.Combine(config, "bar_fight_timings_request.json"), output = Path.Combine(config, "bar_fight_timings_response.json");
        string traitsOutput = Path.Combine(config, "bar_fight_traits_response.json");
        Directory.CreateDirectory(config);
        int fetches = 0, cancelled = 0, enabled = 1;
        Task<int> running = null;
        using (EventWaitHandle stop = new EventWaitHandle(false, EventResetMode.ManualReset))
        using (ManualResetEvent entered = new ManualResetEvent(false))
        using (CancellationTokenSource cancel = new CancellationTokenSource())
        {
            try
            {
                File.WriteAllText(input, "{}", Utf8);
                File.WriteAllText(traitsOutput, "{\"traits_sentinel\":true}", Utf8);
                running = Task.Factory.StartNew(delegate {
                    return RunChannel(new Options { DataDir = directory }, stop, cancel.Token,
                        delegate(Uri endpoint, Request request, CancellationToken token) {
                            int attempt = Interlocked.Increment(ref fetches);
                            if (attempt == 1 || attempt == 4)
                            {
                                entered.Set();
                                if (token.WaitHandle.WaitOne(7000)) Interlocked.Increment(ref cancelled);
                            }
                            string payload = server.Replace("group:t2-constructor", request.Unit);
                            if (!request.Unit.StartsWith("group:", StringComparison.Ordinal)) payload = payload.Replace("\"kind\":\"group\"", "\"kind\":\"unit\"");
                            return new FetchResult { Payload = ValidateTimingResponse(payload, request), FetchedUtc = DateTime.UtcNow };
                        }, 1, 1, true, delegate { return Interlocked.CompareExchange(ref enabled, 0, 0) != 0; });
                });
                Thread.Sleep(1100);
                check(!running.IsCompleted && fetches == 0 && !File.Exists(output));
                File.WriteAllText(input, requestJson, Utf8);
                check(entered.WaitOne(5000));
                string second = requestJson.Replace("bft-1-2-3", "timing-second").Replace("group:t2-constructor", "armack");
                File.WriteAllText(input, second, Utf8);
                Dictionary<string, object> response = WaitTestResponse(output, "timing-second", running);
                check(cancelled == 1 && fetches == 2 && response != null && Boolean(Field(response, "ok"))
                    && Text(Field(Obj(Field(response, "unit")), "id"), 100) == "armack" && !Boolean(Field(response, "cached")));
                check(File.ReadAllText(traitsOutput, Utf8) == "{\"traits_sentinel\":true}");
                File.WriteAllText(input, second.Replace("timing-second", "timing-cached"), Utf8);
                response = WaitTestResponse(output, "timing-cached", running);
                check(fetches == 2 && response != null && Boolean(Field(response, "cached")));
                DateTime written = File.GetLastWriteTimeUtc(output);
                Thread.Sleep(1100);
                check(fetches == 2 && File.GetLastWriteTimeUtc(output) == written);
                Interlocked.Exchange(ref enabled, 0);
                response = WaitTestResponse(output, "timing-cached", running, "privacy-disabled");
                check(fetches == 2 && response != null && !Boolean(Field(response, "ok")) && Array(Field(response, "profiles"), 16).Length == 0);
                Interlocked.Exchange(ref enabled, 1);
                response = WaitTestResponse(output, "timing-cached", running, null, true);
                check(fetches == 2 && response != null && Boolean(Field(response, "cached")));
                File.WriteAllText(input, requestJson.Replace("bft-1-2-3", "timing-stale-not-cached"), Utf8);
                response = WaitTestResponse(output, "timing-stale-not-cached", running);
                check(fetches == 3 && response != null && !Boolean(Field(response, "cached")));
                entered.Reset();
                File.WriteAllText(input, requestJson.Replace("bft-1-2-3", "timing-privacy-in-flight").Replace("group:t2-constructor", "armalab"), Utf8);
                check(entered.WaitOne(5000));
                Interlocked.Exchange(ref enabled, 0);
                response = WaitTestResponse(output, "timing-privacy-in-flight", running, "privacy-disabled");
                DateTime cancellationDeadline = DateTime.UtcNow.AddSeconds(2);
                while (cancelled != 2 && DateTime.UtcNow < cancellationDeadline) Thread.Sleep(20);
                check(cancelled == 2 && fetches == 4 && response != null && !Boolean(Field(response, "ok")));
                Thread.Sleep(1100);
                check(fetches == 4 && !Boolean(Field(Obj(Serializer(MaxResponseBytes).DeserializeObject(File.ReadAllText(output, Utf8))), "ok")));
                stop.Set();
                check(running.Wait(3000) && running.Result == 0);
            }
            finally
            {
                stop.Set(); cancel.Cancel();
                if (running != null && !running.IsCompleted) running.Wait(3000);
                if (File.Exists(input)) File.Delete(input);
                if (File.Exists(output)) File.Delete(output);
                if (File.Exists(traitsOutput)) File.Delete(traitsOutput);
                Directory.Delete(config, false);
                Directory.Delete(Path.GetDirectoryName(config), false);
                Directory.Delete(directory, false);
            }
        }
    }

    static Dictionary<string, object> WaitTestResponse(string path, string id, Task<int> running, string errorCode = null, bool requireOk = false)
    {
        DateTime deadline = DateTime.UtcNow.AddSeconds(6);
        while (!running.IsCompleted && DateTime.UtcNow < deadline)
        {
            try
            {
                if (File.Exists(path))
                {
                    Dictionary<string, object> response = Obj(Serializer(MaxResponseBytes).DeserializeObject(File.ReadAllText(path, Utf8)));
                    object code;
                    if (Text(Field(response, "request_id"), 80) == id && (!requireOk || Boolean(Field(response, "ok")))
                        && (errorCode == null || response.TryGetValue("error_code", out code) && Text(code, 80) == errorCode)) return response;
                }
            }
            catch (IOException) { }
            catch (ArgumentException) { }
            Thread.Sleep(50);
        }
        return null;
    }

    static void TestMalformedRecovery(Action<bool> check, string valid, string server)
    {
        string directory = Path.Combine(Path.GetTempPath(), "BARFightBridge-recovery-" + Guid.NewGuid().ToString("N"));
        string lua = Path.Combine(directory, "LuaUI");
        string config = Path.Combine(lua, "Config");
        string requestPath = Path.Combine(config, "bar_fight_traits_request.json");
        string responsePath = Path.Combine(config, "bar_fight_traits_response.json");
        Directory.CreateDirectory(config);
        int fetches = 0;
        Task<int> running = null;
        using (EventWaitHandle stop = new EventWaitHandle(false, EventResetMode.ManualReset))
        using (CancellationTokenSource cancel = new CancellationTokenSource())
        {
            try
            {
                File.WriteAllText(requestPath, "{}", Utf8);
                running = Task.Factory.StartNew(delegate {
                    return Run(new Options { DataDir = directory }, stop, cancel.Token,
                        delegate(Uri endpoint, Request request, CancellationToken token) {
                            Interlocked.Increment(ref fetches);
                            return new FetchResult { Payload = ValidateResponse(server, request), FetchedUtc = DateTime.UtcNow };
                        });
                });
                Thread.Sleep(1200);
                check(!running.IsCompleted && fetches == 0 && !File.Exists(responsePath));
                File.WriteAllText(requestPath, "{\"schema\":", Utf8);
                Thread.Sleep(1200);
                check(!running.IsCompleted && fetches == 0 && !File.Exists(responsePath));
                File.WriteAllText(requestPath, valid, Utf8);
                DateTime deadline = DateTime.UtcNow.AddSeconds(6);
                while (!File.Exists(responsePath) && !running.IsCompleted && DateTime.UtcNow < deadline) Thread.Sleep(50);
                check(!running.IsCompleted && fetches == 1 && File.Exists(responsePath));
                Dictionary<string, object> response = Obj(Serializer(MaxResponseBytes).DeserializeObject(File.ReadAllText(responsePath, Utf8)));
                check(Boolean(Field(response, "ok")) && Text(Field(response, "request_id"), 80) == "bft-1-2-3");
                stop.Set();
                check(running.Wait(3000) && running.Result == 0);
            }
            finally
            {
                stop.Set();
                cancel.Cancel();
                if (running != null && !running.IsCompleted) running.Wait(3000);
                if (File.Exists(requestPath)) File.Delete(requestPath);
                if (File.Exists(responsePath)) File.Delete(responsePath);
                Directory.Delete(config, false);
                Directory.Delete(lua, false);
                Directory.Delete(directory, false);
            }
        }
    }

    static void TestPreparationRetry(Action<bool> check, string valid, string server)
    {
        string directory = Path.Combine(Path.GetTempPath(), "BARFightBridge-preparing-" + Guid.NewGuid().ToString("N"));
        string config = Path.Combine(directory, "LuaUI", "Config");
        string requestPath = Path.Combine(config, "bar_fight_traits_request.json");
        string responsePath = Path.Combine(config, "bar_fight_traits_response.json");
        Directory.CreateDirectory(config);
        int fetches = 0;
        DateTime firstFetch = DateTime.MinValue, secondFetch = DateTime.MinValue;
        Task<int> running = null;
        using (EventWaitHandle stop = new EventWaitHandle(false, EventResetMode.ManualReset))
        using (CancellationTokenSource cancel = new CancellationTokenSource())
        {
            try
            {
                File.WriteAllText(requestPath, valid, Utf8);
                string preparingServer = server.Replace("\"status\":\"available\"", "\"status\":\"preparing\"");
                running = Task.Factory.StartNew(delegate {
                    return Run(new Options { DataDir = directory }, stop, cancel.Token,
                        delegate(Uri endpoint, Request request, CancellationToken token) {
                            int attempt = Interlocked.Increment(ref fetches);
                            if (attempt == 1) firstFetch = DateTime.UtcNow;
                            else if (attempt == 2) secondFetch = DateTime.UtcNow;
                            string responseJson = attempt == 1 ? preparingServer : server;
                            return new FetchResult { Payload = ValidateResponse(responseJson, request), FetchedUtc = DateTime.UtcNow };
                        }, 1, 1);
                });
                DateTime deadline = DateTime.UtcNow.AddSeconds(7);
                Dictionary<string, object> response = null;
                while (!running.IsCompleted && DateTime.UtcNow < deadline)
                {
                    if (File.Exists(responsePath))
                    {
                        try
                        {
                            response = Obj(Serializer(MaxResponseBytes).DeserializeObject(File.ReadAllText(responsePath, Utf8)));
                            object[] profiles = Array(Field(response, "profiles"), 16);
                            if (profiles.Length > 0 && Text(Field(Obj(profiles[0]), "status"), 40) == "available" && fetches >= 2) break;
                        }
                        catch (Exception) { }
                    }
                    Thread.Sleep(50);
                }
                check(!running.IsCompleted && fetches == 2 && secondFetch >= firstFetch.AddMilliseconds(800));
                check(response != null && Boolean(Field(response, "ok"))
                    && Text(Field(Obj(Array(Field(response, "profiles"), 16)[0]), "status"), 40) == "available");
                stop.Set();
                check(running.Wait(3000) && running.Result == 0);
            }
            finally
            {
                stop.Set();
                cancel.Cancel();
                if (running != null && !running.IsCompleted) running.Wait(3000);
                if (File.Exists(requestPath)) File.Delete(requestPath);
                if (File.Exists(responsePath)) File.Delete(responsePath);
                Directory.Delete(config, false);
                Directory.Delete(Path.GetDirectoryName(config), false);
                Directory.Delete(directory, false);
            }
        }
    }

    static void TestCachedDelivery(Action<bool> check, string valid, string server)
    {
        string directory = Path.Combine(Path.GetTempPath(), "BARFightBridge-cache-" + Guid.NewGuid().ToString("N"));
        string config = Path.Combine(directory, "LuaUI", "Config");
        string requestPath = Path.Combine(config, "bar_fight_traits_request.json");
        string responsePath = Path.Combine(config, "bar_fight_traits_response.json");
        Directory.CreateDirectory(config);
        int fetches = 0;
        Task<int> running = null;
        using (EventWaitHandle stop = new EventWaitHandle(false, EventResetMode.ManualReset))
        using (CancellationTokenSource cancel = new CancellationTokenSource())
        {
            try
            {
                File.WriteAllText(requestPath, valid, Utf8);
                running = Task.Factory.StartNew(delegate {
                    return Run(new Options { DataDir = directory }, stop, cancel.Token,
                        delegate(Uri endpoint, Request request, CancellationToken token) {
                            Interlocked.Increment(ref fetches);
                            return new FetchResult { Payload = ValidateResponse(server, request), FetchedUtc = DateTime.UtcNow };
                        });
                });
                DateTime deadline = DateTime.UtcNow.AddSeconds(5);
                while (!File.Exists(responsePath) && !running.IsCompleted && DateTime.UtcNow < deadline) Thread.Sleep(50);
                check(File.Exists(responsePath) && fetches == 1);
                File.WriteAllText(requestPath, valid.Replace("bft-1-2-3", "bft-1-2-4"), Utf8);
                deadline = DateTime.UtcNow.AddSeconds(5);
                Dictionary<string, object> response = null;
                while (!running.IsCompleted && DateTime.UtcNow < deadline)
                {
                    if (File.Exists(responsePath))
                    {
                        try
                        {
                            response = Obj(Serializer(MaxResponseBytes).DeserializeObject(File.ReadAllText(responsePath, Utf8)));
                            if (Text(Field(response, "request_id"), 80) == "bft-1-2-4") break;
                        }
                        catch (Exception) { }
                    }
                    Thread.Sleep(50);
                }
                DateTime deliveredAt = File.GetLastWriteTimeUtc(responsePath);
                Thread.Sleep(1300);
                check(!running.IsCompleted && fetches == 1 && response != null
                    && Text(Field(response, "request_id"), 80) == "bft-1-2-4"
                    && File.GetLastWriteTimeUtc(responsePath) == deliveredAt);
                stop.Set();
                check(running.Wait(3000) && running.Result == 0);
            }
            finally
            {
                stop.Set();
                cancel.Cancel();
                if (running != null && !running.IsCompleted) running.Wait(3000);
                if (File.Exists(requestPath)) File.Delete(requestPath);
                if (File.Exists(responsePath)) File.Delete(responsePath);
                Directory.Delete(config, false);
                Directory.Delete(Path.GetDirectoryName(config), false);
                Directory.Delete(directory, false);
            }
        }
    }
}
