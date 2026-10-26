// Copyright 2026 AproposRobin. Licensed under the Apache License, Version 2.0 (LICENSE at the repository root).
// Mirrors an updater by the same owner (GitHub Releases variant; same licence).

using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Threading;

namespace Treadle.Update
{
	/// What kind of copy of the editor is running, and whether it may update itself.
	public class InstallInfo
	{
		public enum Kind
		{
			/// An unpacked package (the Windows zip or the Linux tarball): updates install into its folder.
			Folder,
			/// No VERSION.txt beside the program: a build from source.
			Development,
			/// A copy a host tool installed and keeps up to date (`host-install.json` beside the program,
			/// docs/Host-Integration.md > Installed by a host tool).
			HostManaged
		}

		/// The file a host tool writes beside the program when it installs Treadle.
		public const String HostInstallFile = "host-install.json";

		public Kind Kind;
		public String ExePath = new .() ~ delete _;
		public String Dir = new .() ~ delete _;
		/// The package version (first line of VERSION.txt), "" for a development build.
		public String Version = new .() ~ delete _;
		/// `host` of host-install.json: the tool that installed this copy ("" when none).
		public String HostName = new .() ~ delete _;

		public void Detect()
		{
			Environment.GetExecutableFilePath(ExePath);
			Path.GetDirectoryPath(ExePath, Dir).IgnoreError(); // no folder: stays empty, a development build below
			UpdateApply.ReadVersionFile(Dir, Version);
			Kind = .Folder;
			HostName.Clear();
			if (Version.IsEmpty)
				Kind = .Development;
			else if (IsHostManaged(Dir, HostName))
				Kind = .HostManaged;
		}

		/// A host tool installed this copy and updates it: `host-install.json` in the folder, with
		/// `"updates": "host"` (the default). `"updates": "treadle"` leaves updates to Treadle.
		/// `outHost` is the tool's display name ("a host tool" when the file names none).
		public static bool IsHostManaged(StringView dir, String outHost)
		{
			String path = scope .();
			UpdateApply.Join(path, dir, HostInstallFile);
			String text = scope .();
			if (File.ReadAllText(path, text) case .Err)
				return false;
			StringView body = text;
			if (body.StartsWith("\xEF\xBB\xBF"))
				body.RemoveFromStart(3);
			String host = scope .();
			String updates = scope .();
			if (UpdateJson.Parse(body) case .Ok(let root))
			{
				defer delete root;
				root.GetString("host", host);
				root.GetString("updates", updates);
			}
			if (updates == "treadle")
				return false;
			outHost.Set(host.IsEmpty ? "a host tool" : host);
			return true;
		}

		/// True when a file can be created in the folder.
		public static bool CanWrite(StringView dir)
		{
			if (dir.IsEmpty || !Directory.Exists(dir))
				return false;
			String probe = scope .();
			UpdateApply.Join(probe, dir, scope $".treadle-write-test-{UpdateApply.CurrentPid()}");
			if (File.WriteAllText(probe, "x") case .Err)
				return false;
			File.Delete(probe).IgnoreError(); // a leftover probe is harmless
			return true;
		}
	}

	public enum UpdateState
	{
		Idle,
		/// Checks do not apply to this copy (Message says why).
		Unavailable,
		Checking,
		UpToDate,
		Available,
		Downloading,
		Verifying,
		/// Downloaded and verified: restart to finish.
		Ready,
		Error
	}

	/// A copy of the updater's state for the UI (UpdateService.GetStatus).
	public class UpdateStatus
	{
		public UpdateState State;
		public String Message = new .() ~ delete _;
		public String CurrentVersion = new .() ~ delete _;
		public String LatestVersion = new .() ~ delete _;
		/// The release notes of LatestVersion (plain text).
		public String Notes = new .() ~ delete _;
		/// The release page of LatestVersion (shown as text, never opened by the updater).
		public String NotesUrl = new .() ~ delete _;
		/// The install folder cannot be written to: the update is offered for a download by hand only.
		public bool ReadOnlyInstall;
		public int64 Received;
		public int64 Total;
		/// The last check was asked for by the user (results are reported, not only logged).
		public bool Manual;
		/// The last check reached the release list (UpToDate or Available).
		public bool Reached;
		public int32 Serial;
	}

	/// The updater (docs/Getting-Started.md "Updating" for users, docs/Releasing.md "The update path" for the release
	/// side). Every network and disk step runs on one worker thread; the UI reads GetStatus each frame and calls
	/// StartCheck / StartDownload / Apply.
	///
	/// Check: GET <api>/releases?per_page=20 (one request, ETag-cached), keep the published releases (pre-releases only
	/// on the alpha channel), the newest one above the running version that is not skipped and carries this platform's
	/// package and SHA256SUMS (GitHubReleases.Pick). Download: SHA256SUMS, then the package, into
	/// <install>/update/dl/; the package's SHA-256 must match the SHA256SUMS line (else it is deleted and
	/// refused); then it is unpacked into <install>/update/new/ with the system's tar and its layout, VERSION.txt and file list checked.
	/// Apply: UpdateApply.
	///
	/// TREADLE_UPDATE_INDEX=<folder> (rehearsals and tests, honoured in every build, logged when used): the release
	/// list is read from <folder>/releases.json and every asset from <folder>/<asset name> instead of GitHub.
	public class UpdateService
	{
		public const StringView DefaultRepository = ReleaseChannel.Repository;
		public const int32 CheckTimeoutSeconds = 10;

		/// Where downloads, the helper, the rollback copy and update.log live: <install>/update for a package,
		/// the per-user update folder otherwise.
		public String UpdateDir = new .() ~ delete _;
		public InstallInfo Install = new .() ~ delete _;
		/// "alpha" (default: pre-releases too) or "stable".
		public String Channel = new .("alpha") ~ delete _;
		/// Called from the worker thread with one log line (thread-safe sink expected).
		public delegate void(StringView) OnLog ~ delete _;
		/// TREADLE_UPDATE_INDEX: a local folder that stands in for the GitHub release list ("" = GitHub).
		public String IndexDir = new .() ~ delete _;
		/// The editor's arguments, given back to it when the helper starts the new version.
		public List<String> RestartArgs = new .() ~ DeleteContainerAndItems!(_);

		Monitor mLock = new .() ~ delete _;
		Thread mThread;
		bool mCancel;
		UpdateStatus mStatus = new .() ~ delete _;
		List<String> mSkipped = new .() ~ DeleteContainerAndItems!(_);
		ReleaseInfo mLatest ~ delete _;
		String mStagedDir = new .() ~ delete _;
		/// The helper's process id after Apply (0 before).
		public int HelperPid;

		public this()
		{
		}

		public ~this()
		{
			mCancel = true;
			if (mThread != null)
			{
				mThread.Join();
				delete mThread;
			}
		}

		void Log(StringView line)
		{
			if (OnLog != null)
				OnLog(line);
			if (!UpdateDir.IsEmpty && Directory.Exists(UpdateDir))
				UpdateApply.AppendLog(UpdateDir, line);
		}

		/// `dataUpdateDir`: the per-user update folder, used when this copy is not a package.
		public void Init(StringView dataUpdateDir)
		{
			Install.Detect();
			if (Install.Kind == .Folder)
				UpdateApply.Join(UpdateDir, Install.Dir, "update");
			else
				UpdateDir.Set(dataUpdateDir);
			mStatus.CurrentVersion.Set(Install.Version.IsEmpty ? Treadle.Document.TreadleInfo.FullVersion : Install.Version);
			String env = scope .();
			if (Environment.GetEnvironmentVariable("TREADLE_UPDATE_INDEX", env) case .Ok && !env.IsEmpty)
			{
				env.Trim();
				IndexDir.Set(env);
				Log(scope $"TREADLE_UPDATE_INDEX is set: releases are read from {IndexDir}, not from GitHub");
			}
			// Leftovers of an earlier update (the helper copy, staged packages) are not needed once an editor runs again.
			if (Directory.Exists(UpdateDir))
			{
				StringView[4] leftovers = .("helper", "dl", "new", "staging");
				for (let name in leftovers)
				{
					String p = scope .();
					UpdateApply.Join(p, UpdateDir, name);
					if (Directory.Exists(p))
						UpdateApply.DeletePath(p);
				}
			}
		}

		/// The version this copy reports and compares with.
		public StringView RunningVersion => Install.Version.IsEmpty ? Treadle.Document.TreadleInfo.FullVersion : Install.Version;

		/// Why this copy does not look for updates by itself ("" when it does).
		public void AutomaticBlocker(String outWhy)
		{
			switch (Install.Kind)
			{
			case .Development: outWhy.Set("This is a development build (no VERSION.txt beside the program), so it does not look for updates by itself.");
			case .HostManaged: outWhy.Set(scope $"This copy of Treadle was installed by {Install.HostName}, which keeps it up to date.");
			default:
			}
		}

		public bool Busy
		{
			get
			{
				using (mLock.Enter())
					return mStatus.State == .Checking || mStatus.State == .Downloading || mStatus.State == .Verifying;
			}
		}

		public void GetStatus(UpdateStatus outStatus)
		{
			using (mLock.Enter())
			{
				outStatus.State = mStatus.State;
				outStatus.Message.Set(mStatus.Message);
				outStatus.CurrentVersion.Set(mStatus.CurrentVersion);
				outStatus.LatestVersion.Set(mStatus.LatestVersion);
				outStatus.Notes.Set(mStatus.Notes);
				outStatus.NotesUrl.Set(mStatus.NotesUrl);
				outStatus.ReadOnlyInstall = mStatus.ReadOnlyInstall;
				outStatus.Received = mStatus.Received;
				outStatus.Total = mStatus.Total;
				outStatus.Manual = mStatus.Manual;
				outStatus.Reached = mStatus.Reached;
				outStatus.Serial = mStatus.Serial;
			}
		}

		void SetState(UpdateState state, StringView message = "")
		{
			using (mLock.Enter())
			{
				mStatus.State = state;
				mStatus.Message.Set(message);
				mStatus.Serial++;
			}
		}

		/// The versions the user chose to skip (never offered).
		public void SetSkipped(Span<String> versions)
		{
			using (mLock.Enter())
			{
				ClearAndDeleteItems!(mSkipped);
				for (let v in versions)
					mSkipped.Add(new String(v));
			}
		}

		/// Forgets a shown result (Later / Skip / Dismiss): back to Idle unless something is running or staged.
		public void Dismiss()
		{
			using (mLock.Enter())
			{
				if (mStatus.State == .Error || mStatus.State == .UpToDate || mStatus.State == .Unavailable || mStatus.State == .Available)
				{
					mStatus.State = .Idle;
					mStatus.Message.Clear();
					mStatus.Serial++;
				}
			}
		}

		bool StartWorker(delegate void() work)
		{
			if (mThread != null)
			{
				if (mThread.IsAlive)
				{
					delete work;
					return false;
				}
				mThread.Join();
				DeleteAndNullify!(mThread);
			}
			mCancel = false;
			mThread = new Thread(new () =>
			{
				work();
				delete work;
			});
			mThread.SetName("Treadle updater");
			mThread.Start(false);
			return true;
		}

		/// Starts a check on the worker. `manual` = asked for by the user. False when one is already running.
		public bool StartCheck(bool manual)
		{
			using (mLock.Enter())
			{
				if (mStatus.State == .Checking || mStatus.State == .Downloading || mStatus.State == .Verifying)
					return false;
				if (mStatus.State == .Ready)
					return false;
				mStatus.Manual = manual;
				mStatus.Reached = false;
				mStatus.State = .Checking;
				mStatus.Message.Clear();
				mStatus.Serial++;
			}
			return StartWorker(new () => DoCheck(manual));
		}

		public bool StartDownload()
		{
			using (mLock.Enter())
			{
				if (mStatus.State != .Available && mStatus.State != .Error)
					return false;
				if (mLatest == null || mStatus.ReadOnlyInstall)
					return false;
				mStatus.State = .Downloading;
				mStatus.Received = 0;
				String pkg = scope .();
				ReleaseChannel.PackageName(mLatest.Version, pkg);
				let asset = mLatest.FindAsset(pkg);
				mStatus.Total = (asset != null) ? asset.Size : 0;
				mStatus.Message.Clear();
				mStatus.Serial++;
			}
			return StartWorker(new () => DoDownload());
		}

		/// Waits for the worker (command line and self tests).
		public void WaitIdle()
		{
			if (mThread != null)
				mThread.Join();
		}

		/// Editor self tests only (captures of the notice line): puts the status in a state without the network.
		public void SetTestState(UpdateState state, StringView latest, StringView message, int64 received, int64 total)
		{
			using (mLock.Enter())
			{
				mStatus.State = state;
				mStatus.LatestVersion.Set(latest);
				mStatus.Message.Set(message);
				mStatus.Received = received;
				mStatus.Total = total;
				mStatus.Manual = false;
				mStatus.ReadOnlyInstall = false;
				mStatus.Notes.Set("Test notes for the capture.");
				mStatus.NotesUrl.Set(scope $"{DefaultRepository}/releases");
				mStatus.Serial++;
			}
		}

		public void Cancel()
		{
			mCancel = true;
		}

		// ------------------------------------------------------------------ fetching

		/// GET with the ETag cache: `<update>/cache/<name>` holds the last body, `<name>.etag` its ETag.
		bool FetchCached(StringView url, StringView name, int64 maxBytes, String outBody, String outReason, out UpdateHttp.Outcome outcome)
		{
			String cacheDir = scope .();
			UpdateApply.Join(cacheDir, UpdateDir, "cache");
			UpdateApply.EnsureDir(cacheDir);
			String bodyPath = scope .();
			UpdateApply.Join(bodyPath, cacheDir, name);
			String etagPath = scope .();
			etagPath.AppendF("{}.etag", bodyPath);
			String etag = scope .();
			if (File.Exists(bodyPath))
				File.ReadAllText(etagPath, etag).IgnoreError(); // no ETag: a plain GET
			etag.Trim();
			String tmp = scope .();
			tmp.AppendF("{}.download", bodyPath);
			File.Delete(tmp).IgnoreError(); // stale scratch file
			UpdateHttp.Response r = scope .();
			UpdateHttp.Get(url, tmp, etag, maxBytes, CheckTimeoutSeconds, CheckTimeoutSeconds, true, r, null, &mCancel);
			outcome = r.Outcome;
			defer { File.Delete(tmp).IgnoreError(); } // scratch file
			if (r.Outcome != .Ok)
			{
				Reason(r, outReason);
				return false;
			}
			if (r.Status == 304 && File.ReadAllText(bodyPath, outBody) case .Ok)
				return true;
			if (r.Status != 200)
			{
				outReason.Set(scope $"GitHub answered {r.Status}{(r.Status == 403 || r.Status == 429) ? " (rate limit: try again later)" : ""}");
				return false;
			}
			if (File.ReadAllText(tmp, outBody) case .Err)
			{
				outReason.Set("the answer could not be read");
				return false;
			}
			File.WriteAllText(bodyPath, outBody).IgnoreError(); // cache only
			if (!r.ETag.IsEmpty)
				File.WriteAllText(etagPath, r.ETag).IgnoreError();
			else
				File.Delete(etagPath).IgnoreError();
			return true;
		}

		static void Reason(UpdateHttp.Response r, String outReason)
		{
			switch (r.Outcome)
			{
			case .NoClient: outReason.Set("no curl program was found on this system");
			case .Unreachable: outReason.Set("GitHub could not be reached");
			case .TooLarge: outReason.Set("the answer was larger than expected");
			case .Cancelled: outReason.Set("cancelled");
			case .BadRedirect: outReason.Set("GitHub redirected to a host that is not GitHub's, so the request was stopped");
			default: outReason.Set(scope $"the download tool failed (code {r.CurlExit})");
			}
		}

		/// One asset of the release into `dest`: from GitHub, or copied from TREADLE_UPDATE_INDEX.
		bool FetchAsset(StringView tag, StringView name, StringView dest, int64 maxBytes, bool download, delegate void(int64) progress, String outReason, out UpdateHttp.Outcome outcome)
		{
			outcome = .Ok;
			if (!GitHubReleases.IsSafeSegment(name) || !GitHubReleases.IsSafeSegment(tag))
			{
				outReason.Set("the release names an unsafe file");
				outcome = .Failed;
				return false;
			}
			if (!IndexDir.IsEmpty)
			{
				String src = scope .();
				UpdateApply.Join(src, IndexDir, name);
				if (!File.Exists(src))
				{
					outReason.Set(scope $"{name} is not in the update index");
					outcome = .Failed;
					return false;
				}
				if (!UpdateApply.CopyFile(src, dest))
				{
					outReason.Set(scope $"{name} could not be copied from the update index");
					outcome = .Failed;
					return false;
				}
				if (progress != null)
					progress(FileSize(dest));
				return true;
			}
			String url = scope $"{DefaultRepository}/releases/download/{tag}/{name}";
			Log(scope $"Downloading {url}");
			UpdateHttp.Response r = scope .();
			if (download)
				UpdateHttp.Get(url, dest, "", maxBytes, CheckTimeoutSeconds, 0, false, r, progress, &mCancel);
			else
				UpdateHttp.Get(url, dest, "", maxBytes, CheckTimeoutSeconds, CheckTimeoutSeconds * 3, false, r, null, &mCancel);
			outcome = r.Outcome;
			if (r.Outcome != .Ok)
			{
				Reason(r, outReason);
				return false;
			}
			if (r.Status != 200)
			{
				outReason.Set(scope $"GitHub answered {r.Status} for {name}");
				outcome = .Failed;
				return false;
			}
			return true;
		}

		static int64 FileSize(StringView path)
		{
			FileStream fs = scope .();
			if (fs.Open(path, .Read, .ReadWrite) case .Err)
				return -1;
			return fs.Length;
		}

		// ------------------------------------------------------------------ check

		void Finish(UpdateState state, StringView message)
		{
			SetState(state, message);
			Log(message);
		}

		void DoCheck(bool manual)
		{
			String body = scope .();
			String reason = scope .();
			UpdateHttp.Outcome outcome = .Ok;
			if (!IndexDir.IsEmpty)
			{
				String p = scope .();
				UpdateApply.Join(p, IndexDir, "releases.json");
				if (File.ReadAllText(p, body) case .Err)
				{
					Finish(.Error, scope $"Could not check for updates: {p} could not be read.");
					return;
				}
			}
			else
			{
				String url = scope $"{ReleaseChannel.ApiRepository}/releases?per_page={ReleaseChannel.ListCount}";
				if (!FetchCached(url, "releases.json", 4 * 1024 * 1024, body, reason, out outcome))
				{
					CheckFailed(manual, outcome, reason);
					return;
				}
			}
			List<ReleaseInfo> releases = scope .();
			defer { ClearAndDeleteItems!(releases); }
			if (!GitHubReleases.Parse(body, releases))
			{
				Finish(.Error, "Could not check for updates: the release list could not be read.");
				return;
			}
			List<String> skipped = scope .();
			defer { ClearAndDeleteItems!(skipped); }
			using (mLock.Enter())
				for (let s in mSkipped)
					skipped.Add(new String(s));
			String running = scope .(RunningVersion);
			String note = scope .();
			let best = GitHubReleases.Pick(releases, running, Channel != "stable", skipped, note);
			if (best == null)
			{
				using (mLock.Enter())
					mStatus.Reached = true;
				if (!note.IsEmpty)
					Log(scope $"Newer release passed over: {note}");
				Finish(.UpToDate, scope $"Treadle {running} is up to date.");
				return;
			}
			releases.Remove(best);
			bool readOnly = Install.Kind == .Folder && !InstallInfo.CanWrite(Install.Dir);
			using (mLock.Enter())
			{
				delete mLatest;
				mLatest = best;
				mStatus.Reached = true;
				mStatus.ReadOnlyInstall = readOnly;
				mStatus.LatestVersion.Set(best.Version);
				mStatus.Notes.Set(best.Notes);
				mStatus.NotesUrl.Clear();
				ReleaseChannel.ReleasePage(best.Tag, mStatus.NotesUrl);
			}
			if (readOnly)
				Finish(.Available, scope $"Treadle {best.Version} is available. The install folder is read-only: download and unpack it by hand from {mStatus.NotesUrl}");
			else
				Finish(.Available, scope $"Treadle {best.Version} is available (this is {running}).");
		}

		void CheckFailed(bool manual, UpdateHttp.Outcome outcome, StringView reason)
		{
			// Offline or air-gapped: one log line; a check the user asked for says so, an automatic one stays quiet.
			Log(scope $"Update check failed: {reason}");
			SetState(manual ? .Error : .Idle, manual ? scope $"Could not check for updates: {reason}." : "");
		}

		// ------------------------------------------------------------------ download

		public static bool Sha256OfFile(StringView path, String outHex)
		{
			FileStream fs = scope .();
			if (fs.Open(path, .Read, .Read) case .Err)
				return false;
			SHA256 sha = scope .();
			uint8[65536] buf = ?;
			while (true)
			{
				switch (fs.TryRead(.(&buf[0], buf.Count)))
				{
				case .Ok(let n):
					if (n == 0)
					{
						let hash = sha.Finish();
						for (let b in hash.mHash)
						{
							outHex.Append("0123456789abcdef"[b >> 4]);
							outHex.Append("0123456789abcdef"[b & 15]);
						}
						return true;
					}
					sha.Update(.(&buf[0], n));
				case .Err:
					return false;
				}
			}
		}

		/// Checks a downloaded file against the SHA-256 SHA256SUMS lists for it (and the size the release names, when
		/// known). On a mismatch the file is deleted and false returned with `outReason`.
		public static bool VerifyDownload(StringView path, StringView expectedHex, int64 expectedSize, String outReason)
		{
			let len = FileSize(path);
			if (len < 0)
			{
				outReason.Set("the download could not be read");
				return false;
			}
			if (expectedSize > 0 && len != expectedSize)
			{
				File.Delete(path).IgnoreError(); // refused: never kept
				outReason.Set(scope $"the download has {len} bytes, the release says {expectedSize}");
				return false;
			}
			String hex = scope .();
			if (!Sha256OfFile(path, hex))
			{
				outReason.Set("the download could not be read");
				return false;
			}
			if (hex != expectedHex)
			{
				File.Delete(path).IgnoreError(); // refused: never kept
				outReason.Set("the download's SHA-256 does not match the release's SHA256SUMS (the file was altered or damaged); it was deleted");
				return false;
			}
			return true;
		}

		/// The unpacked package must hold the editor, its host library, the release's VERSION.txt and a file list whose
		/// every entry is present.
		public static bool CheckLayout(StringView dir, StringView version, String outReason)
		{
#if BF_PLATFORM_WINDOWS
			StringView[5] required = .("Treadle.exe", "treadlehost.dll", "VERSION.txt", "LICENSE", UpdateApply.ManifestName);
#else
			StringView[5] required = .("treadle", "libtreadlehost.so", "VERSION.txt", "LICENSE", UpdateApply.ManifestName);
#endif
			for (let name in required)
			{
				String p = scope .();
				UpdateApply.Join(p, dir, name);
				if (!File.Exists(p))
				{
					outReason.Set(scope $"the package has no {name}");
					return false;
				}
			}
			String v = scope .();
			UpdateApply.ReadVersionFile(dir, v);
			if (v != version)
			{
				outReason.Set(scope $"the package says it is {v}, the release says {version}");
				return false;
			}
			List<String> files = scope .();
			defer { ClearAndDeleteItems!(files); }
			if (!UpdateApply.ReadManifest(dir, files, outReason))
				return false;
			for (let rel in files)
			{
				String p = scope .();
				UpdateApply.Below(p, dir, rel);
				if (!File.Exists(p))
				{
					outReason.Set(scope $"the package's file list names {rel}, which it does not contain");
					return false;
				}
			}
			return true;
		}

		/// Unpacks the package with the system's tar (started by absolute path): the Windows zip holds the files at its
		/// root, the Linux tarball one top folder (stripped).
		public static bool Extract(StringView archive, StringView dir, String outReason)
		{
			String tar = scope .();
#if BF_PLATFORM_WINDOWS
			String root = scope .();
			if (Environment.GetEnvironmentVariable("SystemRoot", root) case .Err || root.IsEmpty)
				root.Set("C:\\Windows");
			tar.AppendF("{}\\System32\\tar.exe", root);
#else
			tar.Set(File.Exists("/usr/bin/tar") ? "/usr/bin/tar" : "/bin/tar");
#endif
			if (!File.Exists(tar))
			{
				outReason.Set("this system has no tar program to unpack the update");
				return false;
			}
			UpdateApply.EnsureDir(dir);
			String args = scope .();
#if BF_PLATFORM_WINDOWS
			args.Append("-xf");
			UpdateApply.AppendArg(args, archive);
#else
			args.Append("-xzf");
			UpdateApply.AppendArg(args, archive);
			args.Append(" --strip-components=1 --no-same-owner");
#endif
			args.Append(" -C");
			UpdateApply.AppendArg(args, dir);
			ProcessStartInfo psi = scope .();
			psi.SetFileName(tar);
			psi.SetArguments(args);
			psi.UseShellExecute = false;
			psi.CreateNoWindow = true;
			SpawnedProcess proc = scope .();
			if (proc.Start(psi) case .Err)
			{
				outReason.Set("tar could not be started");
				return false;
			}
			if (!proc.WaitFor(600000) || proc.ExitCode != 0)
			{
				outReason.Set("the update package could not be unpacked");
				return false;
			}
			return true;
		}

		void DoDownload()
		{
			ReleaseInfo rel;
			using (mLock.Enter())
				rel = mLatest;
			String pkg = scope .();
			ReleaseChannel.PackageName(rel.Version, pkg);
			let asset = rel.FindAsset(pkg);
			int64 size = (asset != null) ? asset.Size : 0;
			String dir = scope .();
			// Short folder names: the package's deepest paths must stay under the Windows path limit below <install>/update.
			UpdateApply.Join(dir, UpdateDir, "dl");
			String files = scope .();
			UpdateApply.Join(files, UpdateDir, "new");
			UpdateApply.DeletePath(files);
			UpdateApply.DeletePath(dir);
			UpdateApply.EnsureDir(dir);
			if (!Directory.Exists(dir))
			{
				Finish(.Error, scope $"The update could not be downloaded: {dir} could not be created.");
				return;
			}
			String reason = scope .();
			UpdateHttp.Outcome outcome;

			// SHA256SUMS first: a package it does not list is never downloaded.
			String sumsPath = scope .();
			UpdateApply.Join(sumsPath, dir, ReleaseChannel.SumsAsset);
			String sums = scope .();
			String expected = scope .();
			if (!FetchAsset(rel.Tag, ReleaseChannel.SumsAsset, sumsPath, Sha256Sums.MaxBytes, false, null, reason, out outcome) || (File.ReadAllText(sumsPath, sums) case .Err))
			{
				UpdateApply.DeletePath(dir);
				if (outcome == .Cancelled)
				{
					Cancelled();
					return;
				}
				Finish(.Error, scope $"The download failed: {reason}.");
				return;
			}
			if (!Sha256Sums.Find(sums, pkg, expected))
			{
				UpdateApply.DeletePath(dir);
				Finish(.Error, scope $"The update was refused: the release's SHA256SUMS has no valid line for {pkg}.");
				return;
			}

			String part = scope .();
			UpdateApply.Join(part, dir, scope $"{pkg}.part");
			delegate void(int64) progress = scope (n) =>
			{
				using (mLock.Enter())
				{
					mStatus.Received = n;
					mStatus.Serial++;
				}
			};
			if (!FetchAsset(rel.Tag, pkg, part, (size > 0) ? size : 2L * 1024 * 1024 * 1024, true, progress, reason, out outcome))
			{
				UpdateApply.DeletePath(dir);
				if (outcome == .Cancelled)
				{
					Cancelled();
					return;
				}
				Finish(.Error, scope $"The download failed: {reason}.");
				return;
			}
			SetState(.Verifying, "Checking the download...");
			if (!VerifyDownload(part, expected, size, reason))
			{
				UpdateApply.DeletePath(dir);
				Finish(.Error, scope $"The update was refused: {reason}.");
				return;
			}
			Log(scope $"{pkg}: SHA-256 {expected} matches SHA256SUMS");
			String file = scope .();
			UpdateApply.Join(file, dir, pkg);
			File.Delete(file).IgnoreError(); // a leftover of an earlier run
			if (File.Move(part, file) case .Err)
			{
				UpdateApply.DeletePath(dir);
				Finish(.Error, "The download could not be moved into place.");
				return;
			}
			if (!Extract(file, files, reason) || !CheckLayout(files, rel.Version, reason))
			{
				UpdateApply.DeletePath(dir);
				UpdateApply.DeletePath(files);
				Finish(.Error, scope $"The update was refused: {reason}.");
				return;
			}
			UpdateApply.DeletePath(dir); // unpacked and checked: the archive is no longer needed
			using (mLock.Enter())
				mStagedDir.Set(files);
			Finish(.Ready, scope $"Treadle {rel.Version} is downloaded and verified. Restart to finish.");
		}

		void Cancelled()
		{
			using (mLock.Enter())
			{
				mStatus.State = .Available;
				mStatus.Message.Set("Download cancelled.");
				mStatus.Serial++;
			}
		}

		// ------------------------------------------------------------------ apply

		/// Why installing is refused right now ("" when it can go ahead). `unsaved` = sheets with unsaved changes.
		public void ApplyBlocker(int unsaved, bool busy, String outWhy)
		{
			if (unsaved > 0)
			{
				outWhy.Set(scope $"Save your work first ({unsaved} unsaved {(unsaved == 1) ? "file" : "files"}).");
				return;
			}
			if (busy)
			{
				outWhy.Set("Wait for the build or the debugging session to end first.");
				return;
			}
			switch (Install.Kind)
			{
			case .Development: outWhy.Set("This is a development build; updates install only into a packaged copy.");
			case .HostManaged: outWhy.Set(scope $"This copy was installed by {Install.HostName}, which updates it.");
			case .Folder:
				if (!InstallInfo.CanWrite(Install.Dir))
				{
					String page = scope .();
					using (mLock.Enter())
						page.Set(mStatus.NotesUrl);
					outWhy.Set(scope $"The install folder is read-only: download and unpack the new version by hand from {(page.IsEmpty ? scope $"{DefaultRepository}/releases" : page)}");
				}
			}
		}

		/// Starts the install of the staged update: a copy of this program in <update>/helper is started with the
		/// helper switch. On success the caller closes the editor at once (the helper is waiting for it).
		public bool Apply(String outReason)
		{
			String staged = scope .();
			String version = scope .();
			using (mLock.Enter())
			{
				if (mStatus.State != .Ready || mLatest == null)
				{
					outReason.Set("No verified update is waiting.");
					return false;
				}
				staged.Set(mStagedDir);
				version.Set(mLatest.Version);
			}
			String helperDir = scope .();
			UpdateApply.Join(helperDir, UpdateDir, "helper");
			UpdateApply.DeletePath(helperDir);
			UpdateApply.EnsureDir(helperDir);
			String exeName = scope .();
			Path.GetFileName(Install.ExePath, exeName);
			List<String> names = scope .();
			defer { ClearAndDeleteItems!(names); }
			UpdateApply.HelperFiles(Install.Dir, exeName, names);
			for (let name in names)
			{
				String src = scope .();
				UpdateApply.Join(src, Install.Dir, name);
				String dst = scope .();
				UpdateApply.Join(dst, helperDir, name);
				if (!UpdateApply.CopyFile(src, dst))
				{
					outReason.Set("The update helper could not be prepared.");
					return false;
				}
			}
			String helperExe = scope .();
			UpdateApply.Join(helperExe, helperDir, exeName);
			if (!File.Exists(helperExe))
			{
				outReason.Set("The update helper could not be prepared.");
				return false;
			}
			String args = scope .();
			UpdateApply.AppendArg(args, UpdateApply.HelperSwitch);
			UpdateApply.AppendArg(args, Install.Dir);
			UpdateApply.AppendArg(args, scope $"{UpdateApply.CurrentPid()}");
			UpdateApply.AppendArg(args, staged);
			UpdateApply.AppendArg(args, UpdateDir);
			if (!RestartArgs.IsEmpty)
			{
				UpdateApply.AppendArg(args, "--");
				for (let a in RestartArgs)
					UpdateApply.AppendArg(args, a);
			}
#if BF_PLATFORM_WINDOWS
			ProcessStartInfo psi = scope .();
			psi.SetFileName(helperExe);
			psi.SetArguments(args);
			psi.SetWorkingDirectory(helperDir);
			psi.UseShellExecute = false;
			psi.CreateNoWindow = true;
			SpawnedProcess proc = scope .();
			if (proc.Start(psi) case .Err)
			{
				outReason.Set("The update helper could not be started.");
				return false;
			}
			HelperPid = proc.ProcessId;
#else
			// The runtime's process object waits for its child when released, and this process must exit first: the
			// helper is started detached (fork + execv, the same environment).
			List<String> argv = scope .();
			argv.Add(scope:: String(UpdateApply.HelperSwitch));
			argv.Add(scope:: String(Install.Dir));
			argv.Add(scope:: String()..AppendF("{}", UpdateApply.CurrentPid()));
			argv.Add(scope:: String(staged));
			argv.Add(scope:: String(UpdateDir));
			if (!RestartArgs.IsEmpty)
			{
				argv.Add(scope:: String("--"));
				for (let a in RestartArgs)
					argv.Add(a);
			}
			HelperPid = UpdateApply.SpawnDetached(helperExe, argv);
			if (HelperPid <= 0)
			{
				outReason.Set("The update helper could not be started.");
				return false;
			}
#endif
			Log(scope $"Update helper started (process {HelperPid}) for {version}; closing the editor");
			return true;
		}

		/// The outcome an update left for this start (last-result.json), read once and deleted. False when none.
		public bool TakeLastResult(out bool ok, String outMessage)
		{
			ok = false;
			String p = scope .();
			UpdateApply.Join(p, UpdateDir, "last-result.json");
			String text = scope .();
			if (File.ReadAllText(p, text) case .Err)
				return false;
			File.Delete(p).IgnoreError(); // shown once
			if (!(UpdateJson.Parse(text) case .Ok(let j)))
				return false;
			defer delete j;
			ok = j.GetBool("ok", false);
			j.GetString("message", outMessage);
			return !outMessage.IsEmpty;
		}
	}
}
