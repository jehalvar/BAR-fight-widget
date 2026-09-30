// Offline tests compile into a separate executable; these are never shipped.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;

internal static class UpdaterTests
{
    static int Checks;
    static void Assert(bool value, string label) { Checks++; if (!value) throw new Exception(label); }
    static void Reject(Action action, string label)
    {
        Checks++; try { action(); } catch (InvalidDataException) { return; }
        throw new Exception("Accepted: " + label);
    }
    static string Hash(byte[] bytes) { using (SHA256 sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant(); }
    static byte[] Sign(Dictionary<string, object> body, RSACryptoServiceProvider rsa)
    {
        byte[] payload = Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(body));
        return Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(new Dictionary<string, object> {
            { "payload", Convert.ToBase64String(payload) }, { "signature", Convert.ToBase64String(rsa.SignData(payload, CryptoConfig.MapNameToOID("SHA256"))) }
        }));
    }
    static BarFightUpdater.Release FixtureRelease()
    {
        byte[] bytes = Encoding.UTF8.GetBytes("new release file");
        BarFightUpdater.Release release = new BarFightUpdater.Release { Version = "0.1.7" };
        foreach (string name in BarFightUpdater.Names) release.Files.Add(new BarFightUpdater.Entry { Name = name, Size = bytes.Length, Hash = Hash(bytes) });
        return release;
    }
    public static int Main(string[] args)
    {
        // This delegate exists only as an internal test seam; the production
        // entrypoint has no CLI flag or setting that can disable game detection.
        BarFightUpdater.GameProbe = delegate { return false; };
        // Isolated integration installations invoke the actual updater CLI and
        // detached runner. Their helper fixture only supplies stop/start exits.
        if (Path.GetFileName(Process.GetCurrentProcess().MainModule.FileName) == "BarFightBridge.exe") return 0;
        if (args.Length > 0 && (args[0] == "--check" || args[0] == "--apply" || args[0] == "--stop")) return BarFightUpdater.Main(args);
        if (args.Length == 1 && args[0] == "--hold") { System.Threading.Thread.Sleep(1500); return 0; }
        if (args.Length == 2 && args[0] == "--crash-apply")
        {
            BarFightUpdater.Install fixture = new BarFightUpdater.Install { App = Path.Combine(args[1], "app"), Data = Path.Combine(args[1], "BAR data") };
            BarFightUpdater.ApplyFiles(fixture, FixtureRelease(), delegate(int count) { if (count == 2) Environment.Exit(93); });
            return 99;
        }
        string root = Path.Combine(Path.GetTempPath(), "BARFightUpdater-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(root);
            byte[] bytes = Encoding.UTF8.GetBytes("new release file"); long now = 1800000000;
            List<Dictionary<string, object>> files = new List<Dictionary<string, object>>();
            foreach (string name in BarFightUpdater.Names) files.Add(new Dictionary<string, object> {
                { "name", name }, { "url", "https://bar-fight.com/updates/widget/0.1.7/" + name }, { "sha256", Hash(bytes) }, { "size", bytes.Length }
            });
            Dictionary<string, object> body = new Dictionary<string, object> { { "schema", 1 }, { "product", "bar-fight-widget" }, { "channel", "stable" }, { "version", "0.1.7" }, { "published_at", now - 60 }, { "expires_at", now + 86400 }, { "files", files } };
            using (RSACryptoServiceProvider rsa = new RSACryptoServiceProvider(3072))
            {
                rsa.PersistKeyInCsp = false; rsa.FromXmlString(FixtureTrust.PrivateKeyXml); string key = rsa.ToXmlString(false);
                byte[] signed = Sign(body, rsa);
                BarFightUpdater.Release release = BarFightUpdater.Verify(signed, key, now);
                Assert(release.Files.Count == 5, "valid signed release");
                Dictionary<string, object> envelope = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(Encoding.UTF8.GetString(signed));
                byte[] payload = Convert.FromBase64String((string)envelope["payload"]); payload[0] ^= 1;
                envelope["payload"] = Convert.ToBase64String(payload);
                Reject(delegate { BarFightUpdater.Verify(Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(envelope)), key, now); }, "tampered signed payload");
                using (RSACryptoServiceProvider wrong = new RSACryptoServiceProvider(3072)) { wrong.PersistKeyInCsp = false; Reject(delegate { BarFightUpdater.Verify(signed, wrong.ToXmlString(false), now); }, "wrong public key"); }
                Reject(delegate { BarFightUpdater.Verify(signed, key, now + 86401); }, "expired manifest");
                Reject(delegate { BarFightUpdater.Verify(signed, key, now - 1000); }, "future manifest");
                Reject(delegate { BarFightUpdater.RequireNew(release, new Version("0.1.8")); }, "downgrade");
                Reject(delegate { BarFightUpdater.RequireNew(release, new Version("0.1.7")); }, "same version replay");
                BarFightUpdater.RequireNew(release, new Version("0.1.6"));
                Reject(delegate { BarFightUpdater.VerifyFile(Encoding.UTF8.GetBytes("bad release file"), release.Files[0]); }, "tampered file digest");
                foreach (string name in new string[] { "../BarFightBridge.exe", "C:\\evil.exe", "gui_bar_fight_traits.lua/evil", "bar-fight.ini" })
                {
                    files[0]["name"] = name;
                    Reject(delegate { BarFightUpdater.Verify(Sign(body, rsa), key, now); }, "unexpected filename");
                }
                files[0]["name"] = BarFightUpdater.Names[0];
                foreach (string url in new string[] { "http://bar-fight.com/updates/widget/0.1.7/BarFightBridge.exe", "https://bar-fight.com/updates/widget/0.1.7/../BarFightBridge.exe", "https://bar-fight.com/updates/widget/0.1.7/%42arFightBridge.exe", "https://bar-fight.com/updates/widget/0.1.7/BarFightBridge.exe?x=1", "https://evil.example/BarFightBridge.exe" })
                { files[0]["url"] = url; Reject(delegate { BarFightUpdater.Verify(Sign(body, rsa), key, now); }, "unapproved URL"); }
                files[0]["url"] = "https://bar-fight.com/updates/widget/0.1.7/BarFightBridge.exe";
                files[1]["name"] = files[0]["name"]; Reject(delegate { BarFightUpdater.Verify(Sign(body, rsa), key, now); }, "duplicate file"); files[1]["name"] = BarFightUpdater.Names[1];
                files[0]["size"] = 8 * 1024 * 1024 + 1; Reject(delegate { BarFightUpdater.Verify(Sign(body, rsa), key, now); }, "oversized file"); files[0]["size"] = bytes.Length;
                body["schema"] = 2; Reject(delegate { BarFightUpdater.Verify(Sign(body, rsa), key, now); }, "unsupported schema"); body["schema"] = 1;
                Uri expected = new Uri(BarFightUpdater.ManifestUrl);
                Reject(delegate { BarFightUpdater.ValidateHttpResponse(HttpStatusCode.Redirect, expected, expected); }, "same-host redirect");
                Reject(delegate { BarFightUpdater.ValidateHttpResponse(HttpStatusCode.OK, new Uri("https://bar-fight.com/other"), expected); }, "changed response URL");
                BarFightUpdater.ValidateHttpResponse(HttpStatusCode.OK, expected, expected);
                Assert(BarFightUpdater.IsGameProcess("spring") && BarFightUpdater.IsGameProcess("recoil") && BarFightUpdater.IsGameProcess("spring-headless") && !BarFightUpdater.IsGameProcess("BarFightBridge"), "game process deferral predicate");
                BarFightUpdater.Install install = new BarFightUpdater.Install { App = Path.Combine(root, "app"), Data = Path.Combine(root, "BAR data") };
                Directory.CreateDirectory(install.Stage); Directory.CreateDirectory(Path.Combine(install.Data, "LuaUI", "Widgets"));
                string settings = Path.Combine(install.Data, "LuaUI", "Widgets", "unrelated.lua"); File.WriteAllText(settings, "keep settings");
                string ini = Path.Combine(install.App, "bar-fight.ini"); File.WriteAllText(ini, "[BAR]\r\nDataDir=" + install.Data + "\r\n[Updates]\r\nEnabled=0\r\n");
                Assert(BarFightUpdater.Ini(ini, "Updates", "Enabled") == "0", "opt-out setting");
                foreach (string name in BarFightUpdater.Names) { File.WriteAllBytes(Path.Combine(install.Stage, name), bytes); if (name != "README.md") File.WriteAllText(install.Destination(name), "old " + name); }
                BarFightUpdater.VerifyStage(install, release);
                File.WriteAllText(Path.Combine(install.Stage, BarFightUpdater.Names[0]), "damaged");
                Reject(delegate { BarFightUpdater.VerifyStage(install, release); }, "damaged stage");
                File.WriteAllBytes(Path.Combine(install.Stage, BarFightUpdater.Names[0]), bytes);
                bool failed = false;
                try { BarFightUpdater.ApplyFiles(install, release, delegate(int count) { if (count == 4) throw new IOException("injected write failure"); }); } catch (IOException) { failed = true; }
                Assert(failed, "partial apply failure injected");
                foreach (string name in BarFightUpdater.Names) Assert(name == "README.md" ? !File.Exists(install.Destination(name)) : File.ReadAllText(install.Destination(name)) == "old " + name, "rollback: " + name);
                // A separate process exits immediately after two actual file replacements,
                // skipping rollback/finally and leaving the durable production journal.
                using (Process child = Process.Start(new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName, "--crash-apply \"" + root + "\"") { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden }))
                { Assert(child.WaitForExit(15000) && child.ExitCode == 93, "child interrupted during transaction"); }
                Assert(File.Exists(Path.Combine(install.Work, "journal.json")), "abrupt child left durable journal");
                BarFightUpdater.Recover(install);
                foreach (string name in BarFightUpdater.Names) Assert(name == "README.md" ? !File.Exists(install.Destination(name)) : File.ReadAllText(install.Destination(name)) == "old " + name, "interrupted recovery: " + name);
                string engine = Path.Combine(root, "spring.exe"); File.Copy(Process.GetCurrentProcess().MainModule.FileName, engine);
                Process startedGame = null;
                bool deferred = false;
                try
                {
                    BarFightUpdater.ApplyFiles(install, release, delegate(int count)
                    {
                        if (count != 1) return;
                        startedGame = Process.Start(new ProcessStartInfo(engine, "--hold") { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden });
                        BarFightUpdater.GameProbe = delegate { startedGame.Refresh(); return !startedGame.HasExited; };
                    });
                }
                catch (BarFightUpdater.GameActiveException) { deferred = true; }
                Assert(deferred && File.Exists(Path.Combine(install.Work, "journal.json")), "engine starting during apply preserves journal");
                Assert(File.ReadAllText(install.Destination(BarFightUpdater.Names[0])) == "new release file" && File.ReadAllText(install.Destination(BarFightUpdater.Names[1])) == "old " + BarFightUpdater.Names[1], "no replacement after engine launch");
                deferred = false;
                try { BarFightUpdater.Recover(install); } catch (BarFightUpdater.GameActiveException) { deferred = true; }
                Assert(deferred && File.ReadAllText(install.Destination(BarFightUpdater.Names[0])) == "new release file", "rollback deferred while engine active");
                Assert(startedGame.WaitForExit(5000), "midtransaction engine fixture exit"); startedGame.Dispose();
                BarFightUpdater.GameProbe = delegate { return false; };
                BarFightUpdater.Recover(install);
                foreach (string name in BarFightUpdater.Names) Assert(name == "README.md" ? !File.Exists(install.Destination(name)) : File.ReadAllText(install.Destination(name)) == "old " + name, "post-game recovery: " + name);
                BarFightUpdater.ApplyFiles(install, release, null);
                foreach (string name in BarFightUpdater.Names) Assert(File.ReadAllText(install.Destination(name)) == "new release file", "successful apply: " + name);
                Assert(File.ReadAllText(Path.Combine(install.Work, "highest-version")) == "0.1.7", "persisted downgrade floor");
                Assert(File.ReadAllText(settings) == "keep settings" && BarFightUpdater.Ini(ini, "Updates", "Enabled") == "0", "settings and unrelated widgets preserved");
                Assert(!File.Exists(Path.Combine(install.Work, "journal.json")), "completed journal removed");
                // Exercise actual Windows sharing violations and bounded replacement retry.
                string locked = Path.Combine(root, "locked-file"); File.WriteAllText(locked, "before");
                System.Threading.ManualResetEvent ready = new System.Threading.ManualResetEvent(false);
                System.Threading.Thread owner = new System.Threading.Thread(delegate() { using (FileStream handle = new FileStream(locked, FileMode.Open, FileAccess.Read, FileShare.Read)) { ready.Set(); System.Threading.Thread.Sleep(300); } });
                owner.Start(); ready.WaitOne(); BarFightUpdater.AtomicWrite(locked, Encoding.UTF8.GetBytes("after")); owner.Join(); ready.Dispose();
                Assert(File.ReadAllText(locked) == "after", "Windows sharing-violation retry");
                using (Process game = Process.Start(new ProcessStartInfo(engine, "--hold") { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden }))
                { Assert(BarFightUpdater.GameRunning(), "actual engine process deferral"); Assert(game.WaitForExit(5000), "engine fixture exit"); }
                // Exercise the real --check -> detached runner -> executable replacement
                // path under a fresh temporary installation with an ephemeral signing key.
                // UPDATE_TEST turns Download into a hard failure, so no HTTP is possible.
                BarFightUpdater.Install live = new BarFightUpdater.Install { App = Path.Combine(root, "live app"), Data = Path.Combine(root, "live BAR") };
                Directory.CreateDirectory(live.Stage); Directory.CreateDirectory(Path.Combine(live.Data, "LuaUI", "Widgets"));
                File.WriteAllText(Path.Combine(live.App, "bar-fight.ini"), "[BAR]\r\nDataDir=" + live.Data + "\r\n[Updates]\r\nEnabled=1\r\n");
                byte[] executable = File.ReadAllBytes(Process.GetCurrentProcess().MainModule.FileName);
                List<Dictionary<string, object>> liveFiles = new List<Dictionary<string, object>>();
                foreach (string name in BarFightUpdater.Names)
                {
                    byte[] content = name.EndsWith(".exe", StringComparison.Ordinal) ? executable : bytes;
                    File.WriteAllBytes(Path.Combine(live.Stage, name), content);
                    File.WriteAllBytes(live.Destination(name), name.EndsWith(".exe", StringComparison.Ordinal) ? executable : Encoding.UTF8.GetBytes("previous"));
                    liveFiles.Add(new Dictionary<string, object> { { "name", name }, { "url", "https://bar-fight.com/updates/widget/0.1.7/" + name }, { "sha256", Hash(content) }, { "size", content.Length } });
                }
                long realNow = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1)).TotalSeconds;
                body["files"] = liveFiles; body["published_at"] = realNow - 60; body["expires_at"] = realNow + 86400;
                File.WriteAllBytes(Path.Combine(live.Work, "pending.json"), Sign(body, rsa));
                File.WriteAllText(Path.Combine(live.Work, "next-check"), (realNow + 21600).ToString());
                using (Process check = Process.Start(new ProcessStartInfo(Path.Combine(live.App, "BarFightUpdater.exe"), "--check --app-dir \"" + live.App + "\" --data-dir \"" + live.Data + "\"") { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden }))
                    Assert(check.WaitForExit(10000) && check.ExitCode == 0, "real checker exits after starting detached runner");
                DateTime deadline = DateTime.UtcNow.AddSeconds(15);
                while (!File.Exists(Path.Combine(live.Work, "highest-version")) && DateTime.UtcNow < deadline) System.Threading.Thread.Sleep(50);
                Assert(File.Exists(Path.Combine(live.Work, "highest-version")), "detached runner committed executable replacement");
                using (Process stop = Process.Start(new ProcessStartInfo(Path.Combine(live.App, "BarFightUpdater.exe"), "--stop --app-dir \"" + live.App + "\" --data-dir \"" + live.Data + "\"") { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden }))
                    Assert(stop.WaitForExit(10000) && stop.ExitCode == 0, "updater stop waits for real runner");
                Assert(File.ReadAllText(live.Destination("gui_bar_fight_traits.lua")) == "new release file" && !File.Exists(Path.Combine(live.Work, "journal.json")), "real runner completed coherent install");
            }
            Console.WriteLine("Updater: " + Checks + " offline security and transaction checks passed."); return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
        finally
        {
            // This freshly generated test root is verified before recursive deletion.
            string expected = Path.GetFullPath(Path.GetTempPath()).TrimEnd('\\') + Path.DirectorySeparatorChar;
            if (Path.GetFullPath(root).StartsWith(expected, StringComparison.OrdinalIgnoreCase) && Path.GetFileName(root).StartsWith("BARFightUpdater-test-", StringComparison.Ordinal) && Directory.Exists(root)) Directory.Delete(root, true);
        }
    }
}
