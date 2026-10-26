using System;
using System.IO;
using System.Collections;
using ImGui;
using Treadle.Document;

namespace Treadle.Editor
{
	/// Host asserts (IM_ASSERT in the host's ImGui, SDL's own). The host never aborts and never
	/// shows a dialog: it calls OnAssert once per distinct site and returns. Each one becomes an
	/// `[ASSERT] <expr> at <file>:<line>` Output Log line (and session log line). The self tests
	/// count them as failures (SelfTest.bf). See docs/Architecture.md, "Host asserts".
	static class HostAsserts
	{
		/// `[ASSERT]` lines logged this run.
		public static int32 Count;

		public static void Register()
		{
			Host.th_set_assert_handler((void*)(function void(char8*, char8*, int32))=> OnAssert);
			Host.th_set_log_handler((void*)(function void(char8*))=> OnHostLog);
		}

		/// The host's "[gl] ..." lines (the graphics device: start, checks on window and display events, rebuilds).
		static void OnHostLog(char8* line)
		{
			Notify.Log(.Info, "Graphics", StringView(line));
		}

		static void OnAssert(char8* expr, char8* file, int32 line)
		{
			Count++;
			let e = scope String(expr);
			let f = scope String(file);
			Notify.Log(.Error, "Assert", scope $"[ASSERT] {e} at {f}:{line}");
		}
	}

	class Program
	{
		/// UTF-8 path of the dock layout file, kept alive for ImGui (io.IniFilename) and freed after the
		/// host shuts down (ImGui writes the layout there once more). Sized to the path: no length limit.
		static char8* sLayoutIni;

		/// The dock layout lives in %LOCALAPPDATA%\Treadle\layout.ini (not the working directory).
		static void SetLayoutPath()
		{
			String path = scope .();
			AppPaths.Root(path);
			AppPaths.EnsureDir(path);
			path.AppendF("{}layout.ini", Path.DirectorySeparatorChar);
			sLayoutIni = new char8[path.Length + 1]*;
			Internal.MemCpy(sLayoutIni, path.Ptr, path.Length);
			sLayoutIni[path.Length] = 0;
			Gui.igGetIO_Nil().IniFilename = sLayoutIni;
		}

#if BF_PLATFORM_WINDOWS
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 AttachConsole(uint32 processId);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern void* GetStdHandle(uint32 which);
#else
		// A Linux process keeps the terminal's stdout / stderr: nothing to attach.
		static int32 AttachConsole(uint32 processId) => 1;
		static void* GetStdHandle(uint32 which) => (void*)(int)1;
#endif

		/// A GUI exe has no console: print into the parent's console (a terminal) unless stdout is already
		/// redirected (a pipe or a file, which the process inherits as it is).
		public static void ConsoleOut(StringView text, bool error = false)
		{
			void* handle = GetStdHandle(error ? (uint32)-12 : (uint32)-11);
			if (handle == null || (int)handle == -1)
				AttachConsole((uint32)-1);
			if (error)
				Console.Error.WriteLine(text);
			else
				Console.WriteLine(text);
		}

		/// Command line before any window (docs/Host-Integration.md): --version / --help / usage errors exit here;
		/// --new-from-template writes its files here so a failure is an exit code, not a dialog. -1 = carry on.
		static int PrepareArgs(String[] args, EditorArgs parsed, String root, String file)
		{
			EditorArgs.Parse(args, parsed);
			switch (parsed.Action)
			{
			case .PrintHelp:
				ConsoleOut(EditorArgs.Usage);
				return EditorArgs.ExitOk;
			case .PrintVersion:
				String line = scope .();
				TreadleInfo.VersionLine(line);
				ConsoleOut(line);
				return EditorArgs.ExitOk;
			case .Usage:
				ConsoleOut(scope $"Treadle: {parsed.Error}\n\n{EditorArgs.Usage}", true);
				return EditorArgs.ExitUsage;
			case .Open:
			}
			if (parsed.IsEmpty)
				return -1;
			String error = scope .();
			if (!ProjectContract.ResolveTarget(parsed.Path, parsed.File, root, file, error))
			{
				ConsoleOut(scope $"Treadle: {error}", true);
				return EditorArgs.ExitUsage;
			}
			return -1;
		}

#if !BF_PLATFORM_WINDOWS
		[CLink] static extern int32 setenv(char8* name, char8* value, int32 overwrite);
		[CLink] static extern int32 unsetenv(char8* name);

		/// Started from the AppImage (packaging/linux/AppRun): the bundled SDL2 is loaded by now,
		/// so give programs the editor starts (the build tool, zenity, the compiled program) the
		/// caller's LD_LIBRARY_PATH back instead of the AppImage's.
		static void RestoreAppImageLibraryPath()
		{
			String orig = scope .();
			if (Environment.GetEnvironmentVariable("TREADLE_APPIMAGE_ORIG_LD_LIBRARY_PATH", orig) case .Err)
				return;
			if (orig.IsEmpty)
				unsetenv("LD_LIBRARY_PATH");
			else
				setenv("LD_LIBRARY_PATH", orig.CStr(), 1);
			unsetenv("TREADLE_APPIMAGE_ORIG_LD_LIBRARY_PATH");
		}
#endif

		/// A run with no user at the window: TREADLE_SELFTEST, --build-run, --format, --import-c,
		/// --version / --help. `phase` names it for the watchdog line.
		static bool HeadlessMode(String[] args, String phase)
		{
			for (let a in args)
			{
				if (a == "--")
					break; // the program's own arguments (--build-run ... -- <args>)
				switch (a)
				{
				case "--build-run", "--format", "--import-c", "--version", "-v", "--help", "-h", "/?":
					phase.Set(a);
					return true;
				}
			}
#if TREADLE_SELFTEST
			String v = scope .();
			if (Environment.GetEnvironmentVariable("TREADLE_SELFTEST", v) case .Ok && !v.IsEmpty)
			{
				phase.Set("self test start-up");
				return true;
			}
#endif
			return false;
		}

		public static int Main(String[] args)
		{
			// The update helper (a copy of the editor in <data>/update/helper, started by Restart to finish): it installs
			// the staged version and exits without opening a window (Treadle.Update.UpdateApply).
			if (args.Count > 0 && args[0] == Treadle.Update.UpdateApply.HelperSwitch)
				return Treadle.Update.UpdateApply.RunHelper(args);
			// Command-line updates (UpdateCli.bf); the editor's own arguments are kept for the restart after an update.
			if (args.Count > 0 && args[0] == Treadle.Update.UpdateApply.HealthSwitch)
				return UpdateCli.Health();
			if (args.Count > 0 && args[0] == "--update")
				return UpdateCli.Run(args);
			UpdateCli.Remember(args);
			// Every non-interactive run: fatal errors, failed asserts and leaks go to the log and
			// stderr and end the process with an exit code (3 / 4, 5 for the watchdog), never a dialog.
			String headless = scope .();
			if (HeadlessMode(args, headless))
			{
				CrashHandler.InstallHeadless(headless);
				CrashHandler.MaybeDebugFatal();
			}
			if (ImportHeader.CommandLine(args, var importExit)) return importExit; // --import-c: no window (ImportHeader.bf)
			if (FormatCommand.CommandLine(args, var formatExit)) return formatExit; // --format: no window (BuildRun.bf)
			EditorArgs parsed = scope .();
			String argRoot = scope .();
			String argFile = scope .();
			int early = PrepareArgs(args, parsed, argRoot, argFile);
			if (early >= 0)
				return early;

			// Log file and crash handler first, so a failure anywhere after this is recorded.
			SessionLog.Open();
			CrashHandler.Install();
			Recovery.Start();
			HostAsserts.Register();
			Host.th_set_log_path(SessionLog.LogPath.CStr()); // the host's start-up message names the log
			// TREADLE_WINDOW=<w>x<h> opens the window at that size (captures of the default layout).
			int32 winW = 1600;
			int32 winH = 960;
			{
				String win = scope .();
				if (Environment.GetEnvironmentVariable("TREADLE_WINDOW", win) case .Ok)
				{
					let x = win.IndexOf('x');
					if (x > 0 && int32.Parse(win.Substring(0, x)) case .Ok(let w) && int32.Parse(win.Substring(x + 1)) case .Ok(let h) && w >= 640 && h >= 480)
					{
						winW = w;
						winH = h;
					}
				}
			}
			Desktop.SetQuietWindow(args); // test and capture runs: off-screen, never activated (Desktop.bf)
			if (Host.th_init("Treadle", winW, winH) == 0)
			{
				// The host has already shown a message box with the reason and the log path.
				let why = scope String(Host.th_last_error());
				Console.WriteLine(scope $"Treadle: failed to create the window ({why}). Log: {SessionLog.LogPath}");
				SessionLog.WriteRaw(scope $"th_init failed: could not create the window ({why})\r\n");
				SessionLog.Close();
				return 1;
			}
			Look.HostScale = Math.Clamp(Host.th_get_window_scale(), 0.5f, 3.0f);
#if !BF_PLATFORM_WINDOWS
			RestoreAppImageLibraryPath();
#endif
			SetLayoutPath();

			// Theme and DPI before the first frame; the icon font is merged after it (the UI font
			// pointer is only known once a frame has started).
			Prefs.Load();
			Look.FontSize = Prefs.FontSize;
			Look.Darker = Prefs.Theme == 1;
			Look.Apply(Desktop.WindowDpiScale());

			Notify.Log(.Info, "Editor", "Treadle started");
			Notify.Log(.Info, "Editor", scope $"Session log: {SessionLog.LogPath}");
			if (!AppPaths.CopyNote.IsEmpty)
				Notify.Log(.Info, "Editor", AppPaths.CopyNote); // the first start after the product rename
#if !BF_PLATFORM_WINDOWS
			// A report the last session left (written by its signal handler) is announced once.
			String lastCrash = scope .();
			if (Treadle.Document.PosixCrashReport.FindNewer(CrashHandler.CrashDir, lastCrash))
				Notify.Warn(scope $"The last session crashed. Crash report: {lastCrash}");
			Notify.Log(.Verbose, "Editor", scope $"Crash reports: {CrashHandler.CrashDir}");
#endif
			String settingsPath = scope .();
			Settings.GetPath(settingsPath);
			Notify.Log(.Verbose, "Editor", scope $"Settings: {settingsPath}");
			Desktop.InitPacing();
			Desktop.IdlePacing = Prefs.IdlePacing;
			if (Desktop.IdleDisabledByEnv)
				Notify.Log(.Info, "Editor", "Frame pacing: continuous (TREADLE_NO_IDLE is set)");
			else
				Notify.Log(.Info, "Editor", Prefs.IdlePacing ? "Frame pacing: idle (sleeps when nothing happens; TREADLE_NO_IDLE=1 or Preferences > Graph Editor turns it off)" : "Frame pacing: continuous (Idle frame pacing is off in Preferences)");
			EditorApp app = new .();
			app.HandleArgs(parsed, argRoot, argFile);
			if (parsed.BuildRun)
				app.StartBuildRun(parsed.Config, parsed.ProgramArgs);
			app.CheckRecovery();
			app.InitUpdates();
			bool iconsLoaded = false;

			// A frame loop that stops moving is recorded in the session log (CrashHandler.StartFrameWatch).
			CrashHandler.StartFrameWatch();
			while (!app.QuitNow)
			{
				// Sleep while nothing happens (no input, no build, no animation): idle CPU ~0.
				CrashHandler.LoopStage("waiting for input", true);
				Desktop.PaceFrame(app.WantsContinuousFrames, app.IdleTimeoutMs);
				if (!iconsLoaded && app.UiFont != null)
				{
					iconsLoaded = true;
					Icon.Load(app.UiFont, Host.th_get_mono_font(), 16 * Look.HostScale);
				}
				CrashHandler.LoopStage("window events");
				if (Host.th_begin_frame() == 0)
				{
					// Window close requested: let the app ask about unsaved changes.
					Host.th_cancel_quit();
					app.RequestQuit();
				}
				// Every file dropped since the last frame, oldest first.
				for (var dropped = Host.th_poll_drop(); dropped != null; dropped = Host.th_poll_drop())
					app.OnFileDropped(StringView(dropped));
				CrashHandler.LoopStage("editor frame");
				app.Frame();
				Desktop.NoteActivity();
				CrashHandler.LoopStage("drawing and presenting");
				Host.th_end_frame();
			}

			int exitCode = app.ExitCode;
			app.SaveSettings();
			delete app; // ends a debugging session (the program being debugged is stopped)
			Host.th_shutdown();
			delete sLayoutIni;
			sLayoutIni = null;
			// Clean exit: the recovery journal of this session is no longer needed.
			Recovery.EndSession();
			Notify.Log(.Info, "Editor", "Treadle exited");
			SessionLog.Close();
			return exitCode;
		}
	}
}
