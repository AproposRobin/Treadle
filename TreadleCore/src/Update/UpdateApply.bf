// Copyright 2026 AproposRobin. Licensed under the Apache License, Version 2.0 (LICENSE at the repository root).
// The swap / backup / health-check flow follows an updater by the same owner (Update/UpdateApply.bf, same licence),
// cut down to what a folder install of the editor needs.

using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using System.Threading;

namespace Treadle.Update
{
	/// Installs a verified, unpacked package over the editor's folder, and the file helpers both platforms use.
	///
	/// The editor copies its own program and native libraries to <install>/update/helper/ and starts that copy as
	///   Treadle --apply-update <installDir> <editorPid> <stagedDir> <updateDir> [-- <editor arguments>...]
	/// then closes. The helper (RunHelper) waits for the editor to exit, then replaces the install's files by the
	/// package's file list (`files.txt`, ManifestName): every file the new list names is copied in, every file the old
	/// list names that the new one does not is removed, and nothing else is touched (projects, settings, layouts, the
	/// update folder, anything the user put there). Each file it overwrites or removes is first copied to
	/// <updateDir>/old/ (the rollback copy). It then starts the new editor with the same arguments and a health
	/// request; the new editor answers once it has drawn its first frames (ReportHealthy). If it exits first or does not
	/// answer within 60 s, the helper puts `old` back and starts the old editor. Every step goes to
	/// <updateDir>/update.log, and the outcome to <updateDir>/last-result.json for the next start to report.
	public static class UpdateApply
	{
		public const StringView HelperSwitch = "--apply-update";
		/// `Treadle --update-health`: answers a pending health request and exits (the restart after `--update`).
		public const StringView HealthSwitch = "--update-health";
		/// The package's file list: one path per line, relative to the package root, `/` separators, files only.
		public const StringView ManifestName = "files.txt";
		public const int32 HealthTimeoutMs = 60000;

#if BF_PLATFORM_WINDOWS
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern uint32 GetCurrentProcessId();
#else
		[CLink] static extern int32 getpid();
		[CLink] static extern int32 chmod(char8* path, uint32 mode);
		[CLink] static extern int32 access(char8* path, int32 mode);
		[CLink] static extern int32 kill(int32 pid, int32 sig);
		[CLink] static extern int readlink(char8* path, char8* buf, int size);
		[CLink] static extern int32 symlink(char8* target, char8* linkPath);
		[CLink] static extern int32 unlink(char8* path);
		[CLink] static extern int32 fork();
		[CLink] static extern int32 execv(char8* path, char8** argv);
		[CLink] static extern void _exit(int32 code);
		[CLink] static extern int32 setsid();

		/// Starts `exe` with `args` as a process this one never waits for (fork + execv: the same environment, the
		/// current folder). Returns its process id, or -1.
		public static int32 SpawnDetached(StringView exe, List<String> args)
		{
			String path = scope .(exe);
			char8*[] argv = scope char8*[args.Count + 2];
			argv[0] = path.CStr();
			for (int i < args.Count)
				argv[i + 1] = args[i].CStr();
			argv[args.Count + 1] = null;
			let pid = fork();
			if (pid == 0)
			{
				setsid(); // its own session: it outlives this process and its terminal
				execv(argv[0], &argv[0]);
				_exit(127);
			}
			return (pid > 0) ? pid : -1;
		}
#endif

		public static int32 CurrentPid()
		{
#if BF_PLATFORM_WINDOWS
			return (int32)GetCurrentProcessId();
#else
			return getpid();
#endif
		}

		/// Marks a file runnable (Linux); nothing on Windows.
		public static bool MakeRunnable(StringView path)
		{
#if BF_PLATFORM_WINDOWS
			return true;
#else
			return chmod(scope String(path).CStr(), 0o755) == 0;
#endif
		}

		static char8 Sep => Path.DirectorySeparatorChar;

		public static void Join(String outPath, StringView a, StringView b)
		{
			outPath.Set(a);
			if (!outPath.EndsWith('\\') && !outPath.EndsWith('/'))
				outPath.Append(Sep);
			outPath.Append(b);
		}

		public static void EnsureDir(StringView dir)
		{
			if (dir.IsEmpty || Directory.Exists(dir))
				return;
			String parent = scope .();
			if (Path.GetDirectoryPath(dir, parent) case .Ok && !parent.IsEmpty && parent != dir)
				EnsureDir(parent);
			Directory.CreateDirectory(dir).IgnoreError(); // callers check for what they need
		}

		/// Deletes a file or a folder tree; true when nothing is left at `path`.
		public static bool DeletePath(StringView path)
		{
#if BF_PLATFORM_WINDOWS
			if (Directory.Exists(path))
				Directory.DelTree(path).IgnoreError(); // checked below
			else if (File.Exists(path))
				File.Delete(path).IgnoreError(); // checked below
			return !Directory.Exists(path) && !File.Exists(path);
#else
			// By hand: the runtime's tree delete stops at symbolic links (the package's tools/llvm/bin/ld.lld).
			String p = scope .(path);
			char8[8] buf = ?;
			if (readlink(p.CStr(), &buf[0], 8) >= 0)
				return unlink(p.CStr()) == 0;
			if (Directory.Exists(path))
			{
				List<String> names = scope .();
				defer { ClearAndDeleteItems!(names); }
				TopLevel(path, names);
				for (let name in names)
				{
					String child = scope .();
					Join(child, path, name);
					DeletePath(child);
				}
				Directory.Delete(path).IgnoreError(); // checked below
			}
			else if (File.Exists(path))
				unlink(p.CStr());
			return !Directory.Exists(path) && !File.Exists(path);
#endif
		}

		/// The names in a folder.
		static void TopLevel(StringView dir, List<String> outNames)
		{
			for (let entry in Directory.Enumerate(dir))
			{
				String name = new .();
				entry.GetFileName(name);
				outNames.Add(name);
			}
		}

		/// Copies a file (overwriting, parent folders created), retrying for up to `retryMs` while the target is
		/// locked. Linux: a runnable source stays runnable.
		public static bool CopyFile(StringView from, StringView to, int retryMs = 0)
		{
			String parent = scope .();
			if (Path.GetDirectoryPath(to, parent) case .Ok)
				EnsureDir(parent);
#if !BF_PLATFORM_WINDOWS
			// A symbolic link (the tarball's tools/llvm/bin/ld.lld -> lld) is copied as a link, not as the file it names.
			char8[4096] target = ?;
			let n = readlink(scope String(from).CStr(), &target[0], 4095);
			if (n > 0)
			{
				target[n] = 0;
				unlink(scope String(to).CStr());
				return symlink(&target[0], scope String(to).CStr()) == 0;
			}
			// The runtime's copy writes over an existing file without truncating it: remove the old one first (a running
			// program stays intact; its inode lives on until it exits).
			unlink(scope String(to).CStr());
#endif
			int waited = 0;
			while (true)
			{
				if (File.Copy(from, to, true) case .Ok)
				{
#if !BF_PLATFORM_WINDOWS
					if (access(scope String(from).CStr(), 1) == 0) // X_OK
						MakeRunnable(to);
#endif
					return true;
				}
				if (waited >= retryMs)
					return false;
				Thread.Sleep(250);
				waited += 250;
			}
		}

		/// Copies every file under `from` to the same place under `to`, never deleting anything at `to`.
		public static bool CopyTreeMerge(StringView from, StringView to, int retryMs = 0)
		{
			if (!Directory.Exists(from))
				return false;
			EnsureDir(to);
			bool ok = true;
			for (let entry in Directory.Enumerate(from))
			{
				String name = scope .();
				entry.GetFileName(name);
				String src = scope .();
				Join(src, from, name);
				String dst = scope .();
				Join(dst, to, name);
				if (entry.IsDirectory)
					{ if (!CopyTreeMerge(src, dst, retryMs)) ok = false; }
				else
					{ if (!CopyFile(src, dst, retryMs)) ok = false; }
			}
			return ok;
		}

		// ------------------------------------------------------------------ the file list

		/// A file list entry: a relative path below the package root with `/` separators, no empty, "." or ".."
		/// segment, no drive, no control characters, and never inside the install's own `update` folder.
		public static bool IsSafeRelative(StringView path)
		{
			if (path.IsEmpty || path.Length > 1024 || path.StartsWith('/'))
				return false;
			for (let c in path.RawChars)
				if (c < ' ' || c == '\\' || c == ':' || c == '*' || c == '?' || c == '"' || c == '<' || c == '>' || c == '|' || c == (char8)0x7F)
					return false;
			for (let seg in path.Split('/'))
				if (seg.IsEmpty || seg == "." || seg == ".." || seg.EndsWith('.') || seg.EndsWith(' '))
					return false;
			if (path.StartsWith("update/", .OrdinalIgnoreCase) || path.Equals("update", true))
				return false;
			return true;
		}

		/// Parses a file list's text. False (with `outReason`) on the first unsafe line.
		public static bool ParseManifest(StringView text, List<String> outPaths, String outReason)
		{
			StringView body = text;
			if (body.StartsWith("\xEF\xBB\xBF"))
				body.RemoveFromStart(3);
			int lineNo = 0;
			for (var line in body.Split('\n'))
			{
				lineNo++;
				line.Trim();
				if (line.IsEmpty)
					continue;
				if (!IsSafeRelative(line))
				{
					outReason.Set(scope $"line {lineNo} of the file list is not a safe path");
					return false;
				}
				if (line == ManifestName)
					continue; // the list itself is handled by the swap
				outPaths.Add(new String(line));
			}
			return true;
		}

		/// Reads `<dir>/files.txt`. False when it is missing or malformed.
		public static bool ReadManifest(StringView dir, List<String> outPaths, String outReason)
		{
			String p = scope .();
			Join(p, dir, ManifestName);
			String text = scope .();
			if (File.ReadAllText(p, text) case .Err)
			{
				outReason.Set(scope $"the folder has no {ManifestName}");
				return false;
			}
			return ParseManifest(text, outPaths, outReason);
		}

		/// `rel` (a file list path) below `root`, with this system's separators.
		public static void Below(String outPath, StringView root, StringView rel)
		{
			String native = scope .(rel);
			native.Replace('/', Sep);
			Join(outPath, root, native);
		}

		static bool ListHas(List<String> list, StringView path)
		{
			for (let p in list)
			{
#if BF_PLATFORM_WINDOWS
				if (p.Equals(path, .OrdinalIgnoreCase))
					return true;
#else
				if (p == path)
					return true;
#endif
			}
			return false;
		}

		/// Replaces the install's files by `staged`'s file list (see the class comment). `previous` receives a copy of
		/// every file overwritten or removed, and `previous/.added` the files that did not exist. On a failure
		/// everything is put back (Restore) and false is returned with `outReason`.
		public static bool Swap(StringView install, StringView staged, StringView previous, String outReason, delegate void(StringView) log)
		{
			List<String> next = scope .();
			defer { ClearAndDeleteItems!(next); }
			if (!ReadManifest(staged, next, outReason))
				return false;
			if (next.IsEmpty)
			{
				outReason.Set("the new version's file list is empty");
				return false;
			}
			next.Add(new String(ManifestName));
			for (let rel in next)
			{
				String src = scope .();
				Below(src, staged, rel);
				if (!File.Exists(src))
				{
					outReason.Set(scope $"the new version lists {rel} but does not contain it");
					return false;
				}
			}
			List<String> old = scope .();
			defer { ClearAndDeleteItems!(old); }
			String oldWhy = scope .();
			if (!ReadManifest(install, old, oldWhy))
			{
				ClearAndDeleteItems!(old);
				if (log != null) log(scope $"no usable file list in the install ({oldWhy}): files are only added or replaced, none removed");
			}
			List<String> removed = scope .();
			defer { ClearAndDeleteItems!(removed); }
			for (let rel in old)
				if (!ListHas(next, rel))
					removed.Add(new String(rel));

			if (!DeletePath(previous))
			{
				outReason.Set(scope $"could not clear the previous copy at {previous}");
				return false;
			}
			EnsureDir(previous);
			String added = scope .();
			int kept = 0;
			for (int pass < 2)
			{
				let list = (pass == 0) ? next : removed;
				for (let rel in list)
				{
					String cur = scope .();
					Below(cur, install, rel);
					if (File.Exists(cur))
					{
						String bak = scope .();
						Below(bak, previous, rel);
						if (!CopyFile(cur, bak))
						{
							outReason.Set(scope $"could not keep a copy of {cur}");
							return false;
						}
						kept++;
					}
					else if (pass == 0)
						added.AppendF("{}\n", rel);
				}
			}
			String addedFile = scope .();
			Join(addedFile, previous, ".added");
			if (File.WriteAllText(addedFile, added) case .Err)
			{
				outReason.Set("could not write the rollback list");
				return false;
			}
			if (log != null) log(scope $"previous copy kept in {previous} ({kept} files); {next.Count} files to install, {removed.Count} to remove");
			for (let rel in next)
			{
				String src = scope .();
				Below(src, staged, rel);
				String dst = scope .();
				Below(dst, install, rel);
				if (!CopyFile(src, dst, 10000))
				{
					outReason.Set(scope $"could not replace {dst} (is another copy of Treadle still open?)");
					if (log != null) log(scope $"replace failed at {dst}; restoring the previous copy");
					String why = scope .();
					Restore(install, previous, why, log);
					return false;
				}
			}
			for (let rel in removed)
			{
				String dst = scope .();
				Below(dst, install, rel);
				if (File.Exists(dst) && (File.Delete(dst) case .Err))
				{
					outReason.Set(scope $"could not remove {dst}");
					if (log != null) log(scope $"remove failed at {dst}; restoring the previous copy");
					String why = scope .();
					Restore(install, previous, why, log);
					return false;
				}
				RemoveEmptyParents(install, rel);
			}
			return true;
		}

		/// Removes the folders of `rel` below `root` that the removal left empty (best effort).
		static void RemoveEmptyParents(StringView root, StringView rel)
		{
			String dir = scope .(rel);
			while (true)
			{
				int slash = dir.LastIndexOf('/');
				if (slash <= 0)
					return;
				dir.RemoveToEnd(slash);
				String full = scope .();
				Below(full, root, dir);
				bool empty = true;
				for (let e in Directory.Enumerate(full))
				{
					empty = false;
					break;
				}
				if (!empty || (Directory.Delete(full) case .Err))
					return;
			}
		}

		/// Puts `previous` back over `install` (file by file, nothing else deleted) and removes the files the update
		/// added (`previous/.added`).
		public static bool Restore(StringView install, StringView previous, String outReason, delegate void(StringView) log)
		{
			bool ok = true;
			String addedFile = scope .();
			Join(addedFile, previous, ".added");
			String added = scope .();
			if (File.ReadAllText(addedFile, added) case .Ok)
			{
				for (var rel in added.Split('\n'))
				{
					rel.Trim();
					if (!IsSafeRelative(rel))
						continue;
					String p = scope .();
					Below(p, install, rel);
					if (File.Exists(p) && (File.Delete(p) case .Err))
						ok = false;
					else
						RemoveEmptyParents(install, rel);
				}
			}
			if (Directory.Exists(previous))
			{
				for (let entry in Directory.Enumerate(previous))
				{
					String name = scope .();
					entry.GetFileName(name);
					if (name == ".added")
						continue;
					String src = scope .();
					Join(src, previous, name);
					String dst = scope .();
					Join(dst, install, name);
					bool one = entry.IsDirectory ? CopyTreeMerge(src, dst, 10000) : CopyFile(src, dst, 10000);
					if (!one)
					{
						ok = false;
						outReason.Set(scope $"could not restore {dst}");
					}
				}
			}
			if (log != null) log(ok ? "previous copy restored" : scope $"restore incomplete: {outReason}");
			return ok;
		}

		// ------------------------------------------------------------------ records

		/// The first line of a VERSION.txt ("" when missing).
		public static void ReadVersionFile(StringView dir, String outVersion)
		{
			String p = scope .();
			Join(p, dir, "VERSION.txt");
			String text = scope .();
			if (File.ReadAllText(p, text) case .Err)
				return;
			int nl = text.IndexOf('\n');
			if (nl >= 0)
				text.RemoveToEnd(nl);
			text.Trim();
			outVersion.Set(text);
		}

		public static void WriteResult(StringView updateDir, bool ok, StringView from, StringView to, StringView message)
		{
			String p = scope .();
			Join(p, updateDir, "last-result.json");
			String text = scope .();
			text.AppendF("{{\"ok\": {}, \"from\": ", ok ? "true" : "false");
			UpdateJson.WriteString(from, text);
			text.Append(", \"to\": ");
			UpdateJson.WriteString(to, text);
			text.Append(", \"message\": ");
			UpdateJson.WriteString(message, text);
			text.Append("}\n");
			File.WriteAllText(p, text).IgnoreError(); // the outcome is also in update.log
		}

		/// One line of <updateDir>/update.log (best effort).
		public static void AppendLog(StringView updateDir, StringView line)
		{
			EnsureDir(updateDir);
			String p = scope .();
			Join(p, updateDir, "update.log");
			let now = DateTime.Now;
			String text = scope .();
			text.AppendF("{0:yyyy-MM-dd HH:mm:ss} {1}\n", now, line);
			File.WriteAllText(p, text, true).IgnoreError(); // logging is best effort
		}

		// ------------------------------------------------------------------ processes

		/// The editor program's file name in a package.
		public static StringView EditorExeName
		{
			get
			{
#if BF_PLATFORM_WINDOWS
				return "Treadle.exe";
#else
				return "treadle";
#endif
			}
		}

		/// The top-level files the helper copy needs: the program and its native libraries.
		public static void HelperFiles(StringView installDir, StringView exeName, List<String> outNames)
		{
			for (let entry in Directory.EnumerateFiles(installDir))
			{
				String name = scope .();
				entry.GetFileName(name);
				bool lib = name.EndsWith(".dll", .OrdinalIgnoreCase) || name.EndsWith(".so") || name.Contains(".so.");
				if (name == exeName || lib)
					outNames.Add(new String(name));
			}
		}

		/// Appends one argument, quoted when needed (the process API splits it again on both systems).
		public static void AppendArg(String args, StringView arg)
		{
			if (!args.IsEmpty)
				args.Append(' ');
			bool quote = arg.IsEmpty;
			for (let c in arg.RawChars)
				if (c == ' ' || c == '\t' || c == '"')
					quote = true;
			if (!quote)
			{
				args.Append(arg);
				return;
			}
			args.Append('"');
			for (let c in arg.RawChars)
			{
				if (c == '"')
					args.Append("\\\"");
				else
					args.Append(c);
			}
			args.Append('"');
		}

		static bool StartEditor(StringView installDir, Span<String> editorArgs, SpawnedProcess proc)
		{
			String exe = scope .();
			Join(exe, installDir, EditorExeName);
			if (!File.Exists(exe))
				return false;
			String args = scope .();
			for (let a in editorArgs)
				AppendArg(args, a);
			ProcessStartInfo psi = scope .();
			psi.SetFileName(exe);
			psi.SetArguments(args);
			psi.SetWorkingDirectory(installDir);
			psi.UseShellExecute = false;
			return proc.Start(psi) case .Ok;
		}

#if BF_PLATFORM_WINDOWS
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern void* OpenProcess(uint32 access, int32 inherit, uint32 pid);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern uint32 WaitForSingleObject(void* h, uint32 ms);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 CloseHandle(void* h);
#endif

		/// True while the process with this id runs.
		public static bool IsRunning(int32 pid)
		{
#if BF_PLATFORM_WINDOWS
			let h = OpenProcess(0x00100000 | 0x1000, 0, (uint32)pid); // SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION
			if (h == null)
				return false;
			let r = WaitForSingleObject(h, 0);
			CloseHandle(h);
			return r == 0x102; // WAIT_TIMEOUT: still running
#else
			return pid > 0 && kill(pid, 0) == 0;
#endif
		}

		static bool WaitForExit(int32 pid, int timeoutMs)
		{
			int waited = 0;
			while (IsRunning(pid))
			{
				if (waited >= timeoutMs)
					return false;
				Thread.Sleep(200);
				waited += 200;
			}
			return true;
		}

		/// The helper process: `--apply-update <installDir> <editorPid> <stagedDir> <updateDir> [-- <args>...]`.
		/// Returns the exit code.
		public static int RunHelper(String[] args)
		{
			if (args.Count < 5 || args[0] != HelperSwitch)
				return 2;
			StringView install = args[1];
			let pid = int32.Parse(args[2]).GetValueOrDefault();
			StringView staged = args[3];
			StringView updateDir = args[4];
			List<String> editorArgs = scope .();
			if (args.Count > 5 && args[5] == "--")
				for (int i = 6; i < args.Count; i++)
					editorArgs.Add(args[i]);
			delegate void(StringView) log = scope (line) => AppendLog(updateDir, line);
			log(scope $"helper started: install {install}, editor pid {pid}, staged {staged}, {editorArgs.Count} editor arguments");

			String from = scope .();
			ReadVersionFile(install, from);
			String to = scope .();
			ReadVersionFile(staged, to);

			if (pid > 0 && !WaitForExit(pid, 60000))
			{
				log("the editor did not close within 60 s; nothing was changed");
				WriteResult(updateDir, false, from, to, "Treadle did not close, so the update was not installed. Nothing was changed.");
				return 1;
			}

			String previous = scope .();
			Join(previous, updateDir, "old");
			String reason = scope .();
			if (!Swap(install, staged, previous, reason, log))
			{
				log(scope $"update failed: {reason}");
				WriteResult(updateDir, false, from, to, scope $"The update to {to} could not be installed: {reason}. {from} was kept.");
				SpawnedProcess old = scope .();
				StartEditor(install, editorArgs, old);
				return 1;
			}
			log(scope $"installed {to} over {from}");

			// Health check: the new editor answers health.request with health.ok once it has drawn its first frames
			// (`--update-health` answers at once and exits).
			String request = scope .();
			Join(request, updateDir, "health.request");
			String answer = scope .();
			Join(answer, updateDir, "health.ok");
			File.Delete(answer).IgnoreError(); // a stale answer must not count
			String token = scope .();
			token.AppendF("{}-{}", CurrentPid(), Internal.GetTickCountMicro());
			File.WriteAllText(request, token).IgnoreError(); // without it the new editor never answers: rolled back below

			int healthMs = HealthTimeoutMs;
			String env = scope .();
			if (Environment.GetEnvironmentVariable("TREADLE_UPDATE_HEALTH_MS", env) case .Ok && int32.Parse(env) case .Ok(let ms) && ms > 0)
				healthMs = ms;

			// Written before the start so the new editor reports it; replaced below when the health check fails.
			WriteResult(updateDir, true, from, to, scope $"Treadle was updated to {to}.");
			SpawnedProcess proc = scope .();
			bool healthy = false;
			String why = scope .();
			delegate bool() answered = scope () =>
			{
				String got = scope .();
				return (File.ReadAllText(answer, got) case .Ok) && got == token;
			};
			if (!StartEditor(install, editorArgs, proc))
				why.Set("it could not be started");
			else
			{
				int waited = 0;
				while (true)
				{
					if (answered())
					{
						healthy = true;
						break;
					}
					if (proc.WaitFor(250))
					{
						if (answered())
							healthy = true;
						else
							why.Set(scope $"it closed with code {proc.ExitCode} before it finished starting");
						break;
					}
					waited += 250;
					if (waited >= healthMs)
					{
						why.Set(scope $"it did not finish starting within {healthMs / 1000} s");
						proc.Kill();
						proc.WaitFor(5000);
						break;
					}
				}
			}
			File.Delete(request).IgnoreError(); // done either way
			File.Delete(answer).IgnoreError();

			if (healthy)
			{
				log(scope $"Treadle {to} started; update complete");
				// Installed and healthy: the rollback copy is no longer needed.
				if (!DeletePath(previous))
					log(scope $"the previous copy at {previous} could not be removed");
				return 0;
			}

			log(scope $"Treadle {to} did not start correctly ({why}); restoring {from}");
			String restoreWhy = scope .();
			Restore(install, previous, restoreWhy, log);
			WriteResult(updateDir, false, from, to, scope $"Treadle {to} did not start correctly ({why}), so {from} was restored.");
			SpawnedProcess old = scope .();
			StartEditor(install, editorArgs, old);
			return 1;
		}

		/// Called by a starting editor once it has drawn its first frames (and by `--update-health`): answers the
		/// helper's health request. True when there was one.
		public static bool ReportHealthy(StringView updateDir)
		{
			String request = scope .();
			Join(request, updateDir, "health.request");
			String token = scope .();
			if (File.ReadAllText(request, token) case .Err)
				return false;
			String answer = scope .();
			Join(answer, updateDir, "health.ok");
			File.WriteAllText(answer, token).IgnoreError(); // the helper times out and restores without it
			return true;
		}
	}
}
