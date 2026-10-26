// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using Treadle.Update;

namespace Treadle.Editor
{
	/// The `update` case (TreadleCore/src/Update, Updates.bf), with no network: everything runs in
	/// <TREADLE_HOME or the per-user folder>/selftest-update, which is emptied first and removed at the end.
	///
	///  - Versions: semver order with pre-release parts, build metadata ignored, unparsable never newer.
	///  - The release list: drafts never, pre-releases only on alpha, skipped versions passed over, a release
	///    without this platform's package or SHA256SUMS passed over, unsafe tags dropped.
	///  - SHA256SUMS lines, a download whose SHA-256 does not match refused and deleted.
	///  - The file list: unsafe entries refused; the swap in a temporary install (listed files replaced, files the
	///    new list drops removed, user files kept), the rollback (Restore) puts the old state back.
	///  - A read-only (unwritable) install folder: the blocker names the hand download and the release link.
	///  - The whole check + download + verify + unpack through TREADLE_UPDATE_INDEX's local release index, and a
	///    tampered SHA256SUMS refused with nothing staged; then the helper run in-process on a fake install whose new
	///    editor cannot start: the files are restored and update.log tells the story.
	extension EditorApp
	{
		int mUpPhase;
		String mUpRoot = new .() ~ delete _;

		static void UpWrite(StringView root, StringView rel, StringView text)
		{
			String p = scope .();
			UpdateApply.Below(p, root, rel);
			String dir = scope .();
			Path.GetDirectoryPath(p, dir).IgnoreError();
			UpdateApply.EnsureDir(dir);
			File.WriteAllText(p, text).IgnoreError(); // checked by the reads
		}

		static void UpRead(StringView root, StringView rel, String outText)
		{
			String p = scope .();
			UpdateApply.Below(p, root, rel);
			File.ReadAllText(p, outText).IgnoreError(); // missing: empty
		}

		static bool UpExists(StringView root, StringView rel)
		{
			String p = scope .();
			UpdateApply.Below(p, root, rel);
			return File.Exists(p);
		}

		/// One phase per call; true when done.
		bool SelfTestUpdate()
		{
			switch (mUpPhase++)
			{
			case 0:
				mUpRoot.Clear();
				AppPaths.Root(mUpRoot);
				mUpRoot.AppendF("{}selftest-update", Path.DirectorySeparatorChar);
				UpdateApply.DeletePath(mUpRoot);
				UpdateApply.EnsureDir(mUpRoot);
				UpVersions();
				UpPick();
				UpSums();
				return false;
			case 1:
				UpManifest();
				UpSwap();
				UpReadOnly();
				return false;
			case 2:
				UpIndex();
				return false;
			default:
				UpHelper();
				SelfTestCheck(UpdateApply.DeletePath(mUpRoot), "update: the work folder removed");
				mUpPhase = 0;
				return true;
			}
		}

		void UpVersions()
		{
			SelfTestCheck(ReleaseVersion.Compare("0.1.1-alpha", "0.1.0-alpha") > 0, "update: 0.1.1-alpha is newer than 0.1.0-alpha");
			SelfTestCheck(ReleaseVersion.Compare("0.1.0", "0.1.0-alpha") > 0, "update: 0.1.0 is newer than 0.1.0-alpha");
			SelfTestCheck(ReleaseVersion.Compare("0.1.0-beta", "0.1.0-alpha") > 0 && ReleaseVersion.Compare("0.1.0-alpha.2", "0.1.0-alpha.1") > 0 && ReleaseVersion.Compare("0.1.0-alpha.10", "0.1.0-alpha.9") > 0, "update: pre-release parts in order (beta > alpha, alpha.10 > alpha.9)");
			SelfTestCheck(ReleaseVersion.Compare("0.1.0-alpha.1", "0.1.0-alpha") > 0 && ReleaseVersion.Compare("0.1.0-1", "0.1.0-alpha") < 0, "update: a longer pre-release is newer, numbers sort below words");
			SelfTestCheck(ReleaseVersion.Compare("0.10.0-alpha", "0.9.9") > 0 && ReleaseVersion.Compare("1.0.0", "0.99.99") > 0, "update: numeric parts compare as numbers");
			SelfTestCheck(ReleaseVersion.Compare("0.1.0-alpha+build.7", "0.1.0-alpha") == 0 && ReleaseVersion.Compare("0.1.0-alpha", "0.1.0-alpha") == 0, "update: equal versions, build metadata ignored");
			SelfTestCheck(ReleaseVersion.Compare("banana", "0.1.0") == 0 && ReleaseVersion.Compare("1.2", "0.1.0") == 0 && ReleaseVersion.Compare("0.2.0-", "0.1.0") == 0, "update: an unparsable version is never newer");
		}

		static void UpReleaseJson(String json, StringView tag, bool pre, bool draft, bool withPackage, bool withSums, int64 size = 1234)
		{
			String version = scope .(tag);
			if (version.StartsWith('v'))
				version.Remove(0, 1);
			String pkg = scope .();
			ReleaseChannel.PackageName(version, pkg);
			if (!json.IsEmpty)
				json.Append(",\n");
			json.AppendF("{{\"tag_name\": \"{}\", \"prerelease\": {}, \"draft\": {}, \"body\": \"Notes of {}\\r\\nline two\", \"assets\": [", tag, pre ? "true" : "false", draft ? "true" : "false", tag);
			bool first = true;
			if (withPackage)
			{
				json.AppendF("{{\"name\": \"{}\", \"size\": {}}}", pkg, size);
				first = false;
			}
			if (withSums)
				json.AppendF("{}{{\"name\": \"SHA256SUMS\", \"size\": 200}}", first ? "" : ", ");
			json.Append("]}");
		}

		void UpPick()
		{
			String items = scope .();
			UpReleaseJson(items, "v0.3.0-alpha", false, true, true, true); // draft: never
			UpReleaseJson(items, "v0.2.2-alpha", true, false, true, true); // pre-release
			UpReleaseJson(items, "v0.2.1-alpha", false, false, true, true); // published
			UpReleaseJson(items, "v0.2.5-alpha", false, false, false, true); // no package
			UpReleaseJson(items, "v0.1.0-alpha", false, false, true, true); // the running one
			UpReleaseJson(items, "v../../x", false, false, true, true); // unsafe tag: dropped
			String json = scope $"[{items}]";
			List<ReleaseInfo> rels = scope .();
			defer { ClearAndDeleteItems!(rels); }
			SelfTestCheck(GitHubReleases.Parse(json, rels) && rels.Count == 5, scope $"update: the release list parses, the unsafe tag dropped ({rels.Count} of 6)");
			String note = scope .();
			let alpha = GitHubReleases.Pick(rels, "0.1.0-alpha", true, null, note);
			SelfTestCheck(alpha != null && alpha.Version == "0.2.2-alpha" && alpha.Notes == "Notes of v0.2.2-alpha\nline two", scope $"update: alpha channel picks the pre-release 0.2.2-alpha, not the draft 0.3.0 ({(alpha == null ? "none" : alpha.Version)})");
			let stable = GitHubReleases.Pick(rels, "0.1.0-alpha", false, null, note);
			SelfTestCheck(stable != null && stable.Version == "0.2.1-alpha", scope $"update: stable channel skips the pre-release ({(stable == null ? "none" : stable.Version)})");
			List<String> skipped = scope .() { "0.2.2-alpha" };
			let afterSkip = GitHubReleases.Pick(rels, "0.1.0-alpha", true, skipped, note);
			SelfTestCheck(afterSkip != null && afterSkip.Version == "0.2.1-alpha", "update: a skipped version is passed over, the next newer one offered");
			skipped.Add("0.2.1-alpha");
			note.Clear();
			let none = GitHubReleases.Pick(rels, "0.1.0-alpha", true, skipped, note);
			SelfTestCheck(none == null && !note.IsEmpty, scope $"update: nothing offered when every newer version is skipped or has no package ({note})");
			SelfTestCheck(GitHubReleases.Pick(rels, "0.2.2-alpha", true, null, note) == null, "update: up to date on the newest release");
			String one = scope .();
			UpReleaseJson(one, "v0.4.0-alpha", false, false, true, true);
			List<ReleaseInfo> single = scope .();
			defer { ClearAndDeleteItems!(single); }
			SelfTestCheck(GitHubReleases.Parse(one, single) && single.Count == 1 && single[0].FindAsset("SHA256SUMS") != null, "update: one release object (the /releases/latest shape) parses");
			SelfTestCheck(!GitHubReleases.Parse("{\"tag_name\": ", single), "update: malformed JSON refused");
			SelfTestCheck(UpdateHttp.IsAllowedUrl("https://github.com/AproposRobin/Treadle/releases/download/v1/x.zip") && UpdateHttp.IsAllowedUrl("https://objects.githubusercontent.com/a?b=c&d=e")
				&& !UpdateHttp.IsAllowedUrl("http://github.com/x") && !UpdateHttp.IsAllowedUrl("https://github.com.evil.example/x") && !UpdateHttp.IsAllowedUrl("https://user@github.com/x")
				&& !UpdateHttp.IsAllowedUrl("https://evil.example/github.com") && !UpdateHttp.IsAllowedUrl("https://github.com:8443/x"), "update: redirects only to GitHub's hosts, https only");
		}

		void UpSums()
		{
			let h = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
			String sums = scope $"{h}  Treadle-0.2.0-alpha-win64.zip\nABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789 *Treadle-0.2.0-alpha-linux-x64.tar.gz\nzz  bad\n";
			String got = scope .();
			SelfTestCheck(Sha256Sums.Find(sums, "Treadle-0.2.0-alpha-win64.zip", got) && got == h, "update: SHA256SUMS line found");
			got.Clear();
			SelfTestCheck(Sha256Sums.Find(sums, "Treadle-0.2.0-alpha-linux-x64.tar.gz", got) && got == "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789", "update: binary-mode line, upper-case hex read");
			SelfTestCheck(!Sha256Sums.Find(sums, "Treadle-0.2.0-alpha", got) && !Sha256Sums.Find(sums, "bad", got), "update: unlisted or malformed names not found");

			String file = scope .();
			UpdateApply.Join(file, mUpRoot, "download.bin");
			File.WriteAllText(file, "hello").IgnoreError(); // checked below
			String hex = scope .();
			SelfTestCheck(UpdateService.Sha256OfFile(file, hex) && hex == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", "update: SHA-256 of a file");
			String why = scope .();
			SelfTestCheck(UpdateService.VerifyDownload(file, hex, 5, why), "update: a matching download is accepted");
			SelfTestCheck(!UpdateService.VerifyDownload(file, h, 5, why) && !File.Exists(file) && why.Contains("SHA256SUMS"), scope $"update: a download whose SHA-256 does not match is refused and deleted ({why})");
			File.WriteAllText(file, "hello").IgnoreError();
			why.Clear();
			SelfTestCheck(!UpdateService.VerifyDownload(file, hex, 6, why) && !File.Exists(file), "update: a download of the wrong size is refused and deleted");
		}

		void UpManifest()
		{
			List<String> paths = scope .();
			defer { ClearAndDeleteItems!(paths); }
			String why = scope .();
			SelfTestCheck(UpdateApply.ParseManifest("\xEF\xBB\xBFTreadle.exe\r\ncore/List.treadle\nfiles.txt\n\n", paths, why) && paths.Count == 2 && paths[1] == "core/List.treadle", "update: a file list parses (BOM, CRLF, itself left out)");
			StringView[11] bad = .("../x", "a/../b", "/abs", "C:/x", "a\\b", "update/helper/Treadle.exe", "UPDATE/x", "a//b", "a/./b", "x.", "nul?");
			int refused = 0;
			for (let b in bad)
			{
				ClearAndDeleteItems!(paths);
				why.Clear();
				if (!UpdateApply.ParseManifest(scope $"ok.txt\n{b}\n", paths, why))
					refused++;
			}
			SelfTestCheck(refused == bad.Count, scope $"update: unsafe file list entries refused ({refused} of {bad.Count})");
		}

		void UpSwap()
		{
			String install = scope .();
			UpdateApply.Join(install, mUpRoot, "install");
			String staged = scope .();
			UpdateApply.Join(staged, mUpRoot, "staged");
			String previous = scope .();
			UpdateApply.Join(previous, mUpRoot, "previous");
			UpWrite(install, "Treadle.exe", "old exe");
			UpWrite(install, "core/List.treadle", "old list");
			UpWrite(install, "samples/a/old-only.txt", "dropped by the new version");
			UpWrite(install, "samples/a/my-notes.txt", "the user's own file");
			UpWrite(install, "projects/Game/Game.tproj", "a user project");
			UpWrite(install, "files.txt", "Treadle.exe\ncore/List.treadle\nsamples/a/old-only.txt\n");
			UpWrite(staged, "Treadle.exe", "new exe");
			UpWrite(staged, "core/List.treadle", "new list");
			UpWrite(staged, "core/New.treadle", "added");
			UpWrite(staged, "files.txt", "Treadle.exe\ncore/List.treadle\ncore/New.treadle\n");
			String why = scope .();
			List<String> lines = scope .();
			defer { ClearAndDeleteItems!(lines); }
			delegate void(StringView) log = scope (l) => lines.Add(new String(l));
			bool ok = UpdateApply.Swap(install, staged, previous, why, log);
			String t = scope .();
			UpRead(install, "Treadle.exe", t);
			bool replaced = t == "new exe";
			t.Clear(); UpRead(install, "core/New.treadle", t);
			bool added = t == "added";
			bool removed = !UpExists(install, "samples/a/old-only.txt");
			bool kept = UpExists(install, "samples/a/my-notes.txt") && UpExists(install, "projects/Game/Game.tproj");
			t.Clear(); UpRead(install, "files.txt", t);
			bool list = t.Contains("core/New.treadle");
			SelfTestCheck(ok && replaced && added && removed && kept && list, scope $"update: the swap replaces listed files, adds new ones, removes dropped ones, keeps user files (ok {ok} {why}, replaced {replaced}, added {added}, removed {removed}, kept {kept}, list {list})");
			why.Clear();
			bool restored = UpdateApply.Restore(install, previous, why, log);
			t.Clear(); UpRead(install, "Treadle.exe", t);
			bool oldExe = t == "old exe";
			bool back = UpExists(install, "samples/a/old-only.txt") && !UpExists(install, "core/New.treadle") && UpExists(install, "samples/a/my-notes.txt") && UpExists(install, "projects/Game/Game.tproj");
			t.Clear(); UpRead(install, "files.txt", t);
			SelfTestCheck(restored && oldExe && back && !t.Contains("New.treadle"), scope $"update: the rollback puts the old files back and removes the added ones ({why})");
			// A new version whose list names a file it does not contain is refused before anything changes.
			UpWrite(staged, "files.txt", "Treadle.exe\nmissing.dll\n");
			why.Clear();
			SelfTestCheck(!UpdateApply.Swap(install, staged, previous, why, log) && why.Contains("missing.dll"), scope $"update: a package missing a listed file is refused ({why})");
		}

		void UpReadOnly()
		{
			UpdateService svc = scope .();
			svc.Install.Kind = .Folder;
			UpdateApply.Join(svc.Install.Dir, mUpRoot, "no-such-folder");
			String why = scope .();
			svc.ApplyBlocker(0, false, why);
			SelfTestCheck(!InstallInfo.CanWrite(svc.Install.Dir) && why.Contains("read-only") && why.Contains("by hand") && why.Contains(UpdateService.DefaultRepository), scope $"update: an unwritable install folder offers the hand download with the release link ({why})");
			String install = scope .();
			UpdateApply.Join(install, mUpRoot, "install");
			SelfTestCheck(InstallInfo.CanWrite(install), "update: a writable install folder is updated in place");
			why.Clear();
			svc.ApplyBlocker(2, false, why);
			SelfTestCheck(why.Contains("2 unsaved"), "update: unsaved files block the restart");
		}

		/// A package in `dir` (VERSION.txt, the editor, its host, LICENSE, files.txt) packed into `archive`.
		bool UpPack(StringView dir, StringView version, StringView archive)
		{
			UpWrite(dir, "VERSION.txt", scope $"{version}\n");
			UpWrite(dir, UpdateApply.EditorExeName, "not a program");
#if BF_PLATFORM_WINDOWS
			let host = "treadlehost.dll";
#else
			let host = "libtreadlehost.so";
#endif
			UpWrite(dir, host, "host");
			UpWrite(dir, "LICENSE", "Apache-2.0");
			UpWrite(dir, "core/List.treadle", scope $"list {version}");
			UpWrite(dir, "files.txt", scope $"VERSION.txt\n{UpdateApply.EditorExeName}\nLICENSE\ncore/List.treadle\n{host}\n");
			String tar = scope .();
			String args = scope .();
#if BF_PLATFORM_WINDOWS
			String root = scope .();
			if (Environment.GetEnvironmentVariable("SystemRoot", root) case .Err || root.IsEmpty)
				root.Set("C:\\Windows");
			tar.AppendF("{}\\System32\\tar.exe", root);
			args.Append("-a -cf");
			UpdateApply.AppendArg(args, archive);
			args.Append(" -C");
			UpdateApply.AppendArg(args, dir);
			args.Append(" .");
#else
			tar.Set(File.Exists("/usr/bin/tar") ? "/usr/bin/tar" : "/bin/tar");
			String parent = scope .();
			Path.GetDirectoryPath(dir, parent).IgnoreError();
			String name = scope .();
			Path.GetFileName(dir, name);
			args.Append("-czf");
			UpdateApply.AppendArg(args, archive);
			args.Append(" -C");
			UpdateApply.AppendArg(args, parent);
			UpdateApply.AppendArg(args, name);
#endif
			ProcessStartInfo psi = scope .();
			psi.SetFileName(tar);
			psi.SetArguments(args);
			psi.UseShellExecute = false;
			psi.CreateNoWindow = true;
			SpawnedProcess proc = scope .();
			if (proc.Start(psi) case .Err)
				return false;
			return proc.WaitFor(60000) && proc.ExitCode == 0 && File.Exists(archive);
		}

		void UpIndex()
		{
			let version = "0.9.0-alpha";
			String index = scope .();
			UpdateApply.Join(index, mUpRoot, "index");
			UpdateApply.EnsureDir(index);
			String pkgName = scope .();
			ReleaseChannel.PackageName(version, pkgName);
			String pkgDir = scope .();
			UpdateApply.Join(pkgDir, mUpRoot, scope $"Treadle-{version}-pkg");
			String archive = scope .();
			UpdateApply.Join(archive, index, pkgName);
			if (!UpPack(pkgDir, version, archive))
			{
				SelfTestCheck(false, "update: the test package could not be packed with the system's tar");
				return;
			}
			String hex = scope .();
			UpdateService.Sha256OfFile(archive, hex);
			String sumsPath = scope .();
			UpdateApply.Join(sumsPath, index, "SHA256SUMS");
			File.WriteAllText(sumsPath, scope $"{hex}  {pkgName}\n").IgnoreError();
			String rel = scope .();
			FileStream afs = scope .();
			int64 asize = (afs.Open(archive, .Read, .Read) case .Ok) ? afs.Length : 0;
			afs.Close();
			UpReleaseJson(rel, scope $"v{version}", true, false, true, true, asize);
			String relPath = scope .();
			UpdateApply.Join(relPath, index, "releases.json");
			File.WriteAllText(relPath, scope $"[{rel}]").IgnoreError();

			String install = scope .();
			UpdateApply.Join(install, mUpRoot, "install");
			UpdateService svc = scope .();
			svc.Install.Kind = .Folder;
			svc.Install.Dir.Set(install);
			svc.Install.Version.Set("0.1.0-alpha");
			UpdateApply.Join(svc.UpdateDir, install, "update");
			UpdateApply.EnsureDir(svc.UpdateDir);
			svc.IndexDir.Set(index);
			UpdateStatus s = scope .();
			svc.StartCheck(true);
			svc.WaitIdle();
			svc.GetStatus(s);
			SelfTestCheck(s.State == .Available && s.LatestVersion == version && s.NotesUrl.EndsWith(scope $"/releases/tag/v{version}") && !s.ReadOnlyInstall, scope $"update: the local release index offers {version} ({s.Message})");
			svc.StartDownload();
			svc.WaitIdle();
			svc.GetStatus(s);
			String staged = scope .();
			UpdateApply.Join(staged, svc.UpdateDir, "new");
			String t = scope .();
			UpRead(staged, "core/List.treadle", t);
			SelfTestCheck(s.State == .Ready && t == scope $"list {version}", scope $"update: downloaded, SHA-256 checked against SHA256SUMS, unpacked and its layout checked ({s.Message})");
			String log = scope .();
			UpRead(svc.UpdateDir, "update.log", log);
			SelfTestCheck(log.Contains("matches SHA256SUMS"), "update: update.log records the checksum match");

			// The same release with a SHA256SUMS that does not match: refused, nothing staged.
			UpdateService bad = scope .();
			bad.Install.Kind = .Folder;
			bad.Install.Dir.Set(install);
			bad.Install.Version.Set("0.1.0-alpha");
			UpdateApply.Join(bad.UpdateDir, mUpRoot, "update-bad");
			UpdateApply.EnsureDir(bad.UpdateDir);
			bad.IndexDir.Set(index);
			File.WriteAllText(sumsPath, scope $"0000000000000000000000000000000000000000000000000000000000000000  {pkgName}\n").IgnoreError();
			bad.StartCheck(true);
			bad.WaitIdle();
			bad.StartDownload();
			bad.WaitIdle();
			bad.GetStatus(s);
			String badStage = scope .();
			UpdateApply.Join(badStage, bad.UpdateDir, "dl");
			SelfTestCheck(s.State == .Error && s.Message.Contains("SHA256SUMS") && !Directory.Exists(badStage) && !Directory.Exists(scope String()..AppendF("{}{}new", bad.UpdateDir, Path.DirectorySeparatorChar)), scope $"update: a package that does not match SHA256SUMS is refused and deleted ({s.Message})");
			// Skipped: not offered.
			UpdateService skip = scope .();
			skip.Install.Kind = .Folder;
			skip.Install.Dir.Set(install);
			skip.Install.Version.Set("0.1.0-alpha");
			skip.UpdateDir.Set(bad.UpdateDir);
			skip.IndexDir.Set(index);
			skip.SetSkipped(scope String[](scope String(version)));
			skip.StartCheck(true);
			skip.WaitIdle();
			skip.GetStatus(s);
			SelfTestCheck(s.State == .UpToDate, scope $"update: a skipped version is not offered ({s.Message})");
			// Stable channel: the index's release is a pre-release.
			UpdateService stable = scope .();
			stable.Install.Kind = .Folder;
			stable.Install.Dir.Set(install);
			stable.Install.Version.Set("0.1.0-alpha");
			stable.UpdateDir.Set(bad.UpdateDir);
			stable.IndexDir.Set(index);
			stable.Channel.Set("stable");
			stable.StartCheck(true);
			stable.WaitIdle();
			stable.GetStatus(s);
			SelfTestCheck(s.State == .UpToDate, "update: the stable channel does not offer a pre-release");
		}

		/// The helper in-process on the temporary install with the staged 0.9.0: the new "editor" is not a program, so
		/// it cannot start; the helper must restore the previous files and say so.
		void UpHelper()
		{
			String install = scope .();
			UpdateApply.Join(install, mUpRoot, "install");
			String updateDir = scope .();
			UpdateApply.Join(updateDir, install, "update");
			String staged = scope .();
			UpdateApply.Join(staged, updateDir, "new");
			UpWrite(install, "VERSION.txt", "0.1.0-alpha\n");
			String[] args = scope String[](scope String(UpdateApply.HelperSwitch), install, scope String("0"), staged, updateDir, scope String("--"), scope String("--some-arg"));
			let code = UpdateApply.RunHelper(args);
			String v = scope .();
			UpdateApply.ReadVersionFile(install, v);
			String t = scope .();
			UpRead(install, "core/List.treadle", t);
			String log = scope .();
			UpRead(updateDir, "update.log", log);
			String result = scope .();
			UpRead(updateDir, "last-result.json", result);
			SelfTestCheck(code == 1 && v == "0.1.0-alpha" && t == "old list" && UpExists(install, "projects/Game/Game.tproj"), scope $"update: the helper restores the previous version when the new one cannot start (exit {code}, VERSION {v}, core/List.treadle '{t}', user project {UpExists(install, "projects/Game/Game.tproj")})");
			if (t != "old list")
				Notify.Log(.Info, "SelfTest", log);
			SelfTestCheck(log.Contains("installed 0.9.0-alpha over 0.1.0-alpha") && log.Contains("restoring 0.1.0-alpha") && log.Contains("1 editor arguments") && result.Contains("\"ok\": false"), "update: update.log and last-result.json tell what happened");
		}
	}
}
#endif
