// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.IO;
using System.Diagnostics;
using System.Collections;

namespace Treadle.Editor
{
	/// `fatal` self test: the headless crash path (CrashHandler.InstallHeadless) in child editors.
	/// Each child is this exe started with `--version` (headless, no window), its own TREADLE_HOME
	/// and TREADLE_DEBUG_FATAL=<kind>; the test waits for it (at most 60 s: a dialog would hold
	/// it open, so an exit in time means none was shown), then checks the exit code and the lines
	/// in the child's session log and its report file.
	///
	///  - fatal, assert, null: exit code 3, `[FATAL] <reason>` in the log, a treadle-crash-*.log.
	///  - leak: exit code 4 and `[LEAK] ... allocated at` in the log, a treadle-leak-*.log (Debug
	///    builds; a Release build has no leak check, the child exits 0).
	///  - hang: TREADLE_WATCHDOG=3, exit code 5, `watchdog: still running` in the log.
	extension EditorApp
	{
		/// A child still running when the editor quits is ended (only ever the one this test started).
		SpawnedProcess mFatalProc ~ { if (_ != null) { if (!_.HasExited) _.Kill(); delete _; } };
		int mFatalCase;
		uint32 mFatalStart;
		String mFatalWork = new .() ~ delete _;

		static StringView[5] cFatalKinds = .("fatal", "assert", "null", "leak", "hang");

		bool SelfTestFatal()
		{
			if (mSelfTestStep == 0)
			{
				mFatalCase = 0;
				mFatalWork.Clear();
				Path.GetTempPath(mFatalWork).IgnoreError();
				if (!mFatalWork.IsEmpty && !mFatalWork.EndsWith(Path.DirectorySeparatorChar))
					mFatalWork.Append(Path.DirectorySeparatorChar);
				mFatalWork.AppendF("treadle-fatal-{}", Win32Raw.GetCurrentProcessId());
				Directory.DelTree(mFatalWork).IgnoreError();
				Directory.CreateDirectory(mFatalWork).IgnoreError();
			}
			if (mFatalCase >= cFatalKinds.Count)
			{
				Directory.DelTree(mFatalWork).IgnoreError();
				return true;
			}
			let kind = cFatalKinds[mFatalCase];
			String home = scope $"{mFatalWork}{Path.DirectorySeparatorChar}{kind}";
			if (mFatalProc == null)
			{
				Directory.CreateDirectory(home).IgnoreError();
				String exe = scope .();
				Environment.GetExecutableFilePath(exe);
				ProcessStartInfo psi = scope .();
				psi.SetFileName(exe);
				psi.SetArguments("--version");
				psi.UseShellExecute = false;
				psi.CreateNoWindow = true;
				psi.AddEnvironmentVariable("TREADLE_HOME", home);
				psi.AddEnvironmentVariable("TREADLE_DEBUG_FATAL", kind);
				psi.AddEnvironmentVariable("TREADLE_SELFTEST", "");
				psi.AddEnvironmentVariable("TREADLE_WATCHDOG", (kind == "hang") ? "3" : "120");
				mFatalProc = new .();
				if (mFatalProc.Start(psi) case .Err)
				{
					SelfTestCheck(false, scope $"fatal/{kind}: the child editor starts");
					DeleteAndNullify!(mFatalProc);
					mFatalCase++;
					return false;
				}
				Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] fatal/{kind}: child editor pid {mFatalProc.ProcessId}");
				mFatalStart = Platform.BfpSystem_TickCount();
				return false;
			}
			if (!mFatalProc.HasExited)
			{
				if (Platform.BfpSystem_TickCount() - mFatalStart < 60000)
					return false;
				mFatalProc.Kill();
				SelfTestCheck(false, scope $"fatal/{kind}: the child editor exits by itself within 60 s (it was ended: a dialog?)");
				DeleteAndNullify!(mFatalProc);
				mFatalCase++;
				return false;
			}
			let code = mFatalProc.ExitCode;
			DeleteAndNullify!(mFatalProc);

			// The child's session log and report files.
			String log = scope .();
			bool crashReport = false;
			bool leakReport = false;
			String logs = scope $"{home}{Path.DirectorySeparatorChar}logs";
			if (Directory.Exists(logs))
			{
				for (let entry in Directory.EnumerateFiles(logs))
				{
					String name = scope .();
					entry.GetFileName(name);
					String path = scope .();
					entry.GetFilePath(path);
					if (name.StartsWith("treadle-crash-") && name.EndsWith(".log"))
						crashReport = true;
					else if (name.StartsWith("treadle-leak-"))
						leakReport = true;
					else if (name.StartsWith("treadle-2"))
						File.ReadAllText(path, log).IgnoreError();
				}
			}
#if !BF_PLATFORM_WINDOWS
			// Linux writes crash reports to $TREADLE_HOME/crashes (PosixCrashReport.ResolveDir), not logs/
			String crashes = scope $"{home}/crashes";
			if (Directory.Exists(crashes))
				for (let entry in Directory.EnumerateFiles(crashes))
				{
					String name = scope .();
					entry.GetFileName(name);
					if (name.StartsWith("treadle-crash-") && name.EndsWith(".log"))
						crashReport = true;
				}
#endif

			int expect = CrashHandler.ExitFatal;
			StringView needle = default;
			switch (kind)
			{
			case "fatal": needle = "[FATAL] TREADLE_DEBUG_FATAL: deliberate fatal error";
			case "assert": needle = "[FATAL] Assert failed: TREADLE_DEBUG_FATAL deliberate assert";
#if BF_PLATFORM_WINDOWS
			case "null": needle = "[FATAL] EXCEPTION_ACCESS_VIOLATION";
#else
			case "null": needle = "[FATAL] signal 11"; // SIGSEGV
#endif
			case "leak":
#if BF_ENABLE_REALTIME_LEAK_CHECK
				expect = CrashHandler.ExitLeak;
				needle = "[LEAK]   System.String at 0x";
#else
				expect = 0;
#endif
			case "hang":
				expect = CrashHandler.ExitWatchdog;
				needle = "watchdog: still running TREADLE_DEBUG_FATAL=hang";
			}
			SelfTestCheck(code == expect, scope $"fatal/{kind}: exit code {code} (expected {expect}), no dialog");
			if (!needle.IsEmpty)
				SelfTestCheck(log.Contains(needle), scope $"fatal/{kind}: the child's session log has '{needle}'");
			if (expect == CrashHandler.ExitFatal)
				SelfTestCheck(crashReport, scope $"fatal/{kind}: a treadle-crash-*.log report was written");
			if (expect == CrashHandler.ExitLeak)
			{
				SelfTestCheck(leakReport, scope $"fatal/{kind}: a treadle-leak-*.log report was written");
				SelfTestCheck(log.Contains("allocated at"), scope $"fatal/{kind}: the leak line names its allocation site");
			}
			// What the report says, for the run log (names and lines need dbghelp and the PDB).
			for (var line in log.Split('\n'))
				if (line.StartsWith("[FATAL]") || line.StartsWith("[LEAK]") || line.StartsWith("watchdog:"))
					Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] fatal/{kind} child: {line..Trim()}");
			mFatalCase++;
			return false;
		}
	}
}
#endif
