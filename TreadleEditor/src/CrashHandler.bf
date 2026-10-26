using System;
using System.IO;
using System.Threading;

namespace Treadle.Editor
{
	/// Win32 calls used by the session log and the crash handler. Declared here (not through
	/// corlib wrappers) so the crash path never allocates.
	static class Win32Raw
	{
		public const uint32 GENERIC_WRITE = 0x40000000;
		public const uint32 FILE_APPEND_DATA = 0x0004;
		public const uint32 FILE_SHARE_READ = 1;
		public const uint32 FILE_SHARE_WRITE = 2;
		public const uint32 FILE_SHARE_DELETE = 4;
		public const uint32 CREATE_ALWAYS = 2;
		public const uint32 OPEN_ALWAYS = 4;
		public const uint32 FILE_ATTRIBUTE_NORMAL = 0x80;
		public const int INVALID_HANDLE = -1;

		[CRepr]
		public struct SystemTime
		{
			public uint16 Year, Month, DayOfWeek, Day, Hour, Minute, Second, Milliseconds;
		}

#if BF_PLATFORM_WINDOWS
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int CreateFileW(char16* name, uint32 access, uint32 share, void* security, uint32 disposition, uint32 flags, int templateFile);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int32 WriteFile(int handle, void* data, uint32 count, uint32* written, void* overlapped);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int32 FlushFileBuffers(int handle);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int32 CloseHandle(int handle);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern void GetLocalTime(SystemTime* time);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern uint32 GetCurrentProcessId();
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern uint32 GetCurrentThreadId();
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int GetCurrentProcess();
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern void* SetUnhandledExceptionFilter(void* filter);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int32 GetModuleHandleExW(uint32 flags, void* address, int* outModule);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern uint32 GetModuleFileNameW(int module, char16* buf, uint32 size);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern void* RtlLookupFunctionEntry(uint64 pc, uint64* imageBase, void* history);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern void* RtlVirtualUnwind(uint32 handlerType, uint64 imageBase, uint64 pc, void* functionEntry, void* context, void** handlerData, uint64* establisherFrame, void* contextPointers);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern void RtlCaptureContext(void* context);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int32 SetThreadStackGuarantee(uint32* size);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int32 WideCharToMultiByte(uint32 codePage, uint32 flags, char16* wide, int32 wideLen, char8* outBytes, int32 outLen, void* defaultChar, void* usedDefault);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int LoadLibraryW(char16* name);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern void* GetProcAddress(int module, char8* name);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int32 IsDebuggerPresent();
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int GetStdHandle(uint32 which);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int32 AttachConsole(uint32 processId);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int32 TerminateProcess(int process, uint32 exitCode);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern uint64 GetTickCount64();
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern void Sleep(uint32 ms);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int CreateThread(void* security, int stackSize, void* start, void* param, uint32 flags, uint32* threadId);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int32 MultiByteToWideChar(uint32 codePage, uint32 flags, char8* bytes, int32 len, char16* wide, int32 wideLen);
		[Import("user32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int32 MessageBoxW(int owner, char16* text, char16* caption, uint32 type);
#endif // the POSIX equivalents are in PosixRaw.bf

		/// Opens a file for appending (created when missing), shared so other tools can read it.
		public static int OpenAppend(char16* path) =>
			CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, null, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);

		public static int Create(char16* path) =>
			CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);

		public static void Write(int handle, StringView text)
		{
			if (handle == 0 || handle == INVALID_HANDLE || text.IsEmpty)
				return;
			uint32 written = 0;
			WriteFile(handle, text.Ptr, (uint32)text.Length, &written, null);
		}
	}

	/// A fixed-size text buffer on the stack: formatting with no allocation (crash path).
	struct RawText
	{
		public char8[2048] Buf;
		public int Len;

		public void Clear() mut { Len = 0; }

		public void Add(StringView s) mut
		{
			for (let c in s.RawChars)
			{
				if (Len >= Buf.Count)
					return;
				Buf[Len++] = c;
			}
		}

		public void Add(char8 c) mut
		{
			if (Len < Buf.Count)
				Buf[Len++] = c;
		}

		public void Hex(uint64 v, int digits = 16) mut
		{
			for (int i = digits - 1; i >= 0; i--)
			{
				let nib = (int)((v >> (i * 4)) & 0xF);
				Add((nib < 10) ? (char8)('0' + nib) : (char8)('A' + nib - 10));
			}
		}

		public void Dec(int64 value, int minDigits = 1) mut
		{
			var v = value;
			if (v < 0)
			{
				Add('-');
				v = -v;
			}
			char8[24] tmp = default;
			int n = 0;
			repeat
			{
				tmp[n++] = (char8)('0' + (v % 10));
				v /= 10;
			}
			while (v > 0 && n < 24);
			while (n < minDigits && n < 24)
				tmp[n++] = '0';
			while (n > 0)
				Add(tmp[--n]);
		}

		/// UTF-16 to UTF-8 without allocating.
		public void Wide(char16* w, int32 len) mut
		{
			if (len <= 0)
				return;
			let room = (int32)(Buf.Count - Len);
			if (room <= 0)
				return;
			let n = Win32Raw.WideCharToMultiByte(65001, 0, w, len, &Buf[Len], room, null, null);
			if (n > 0)
				Len += n;
		}

		public StringView GetView() mut => StringView(&Buf[0], Len);
	}

	/// The always-on session log: %LOCALAPPDATA%\Treadle\logs\treadle-<date>.log, one per
	/// day, appended by every session. Every Output Log line is mirrored into it (Notify), so a
	/// user can send the log of a session that went wrong. Writes go straight to the file (no
	/// buffering), so the lines before a crash are on disk.
	static class SessionLog
	{
		static int sHandle;
		static Monitor sLock = new .() ~ delete _;
		/// Folder for logs and crash reports, with a trailing separator, as UTF-16 (crash path).
		public static char16[520] LogDirW;
		public static int32 LogDirLen;
		public static String LogPath = new .() ~ delete _;
		public static String LogDir = new .() ~ delete _;
		/// LogPath as UTF-16, kept in a static array: the crash path reopens the log with it after
		/// Close (the Debug runtime's leak check runs after Main has returned).
		public static char16[600] LogPathW;
		static bool sPrepared;
		static int sLateHandle;

		/// Works out LogDir / LogPath (creating the folder) without opening the log: the
		/// headless commands that never open it (--format, --import-c, --version) still get
		/// their fatal lines in it (CrashHandle).
		public static void PreparePath()
		{
			if (sPrepared)
				return;
			sPrepared = true;
			AppPaths.Sub("logs", LogDir);
			Win32Raw.SystemTime t = default;
			Win32Raw.GetLocalTime(&t);
			LogPath.AppendF("{}{}treadle-{:D4}-{:D2}-{:D2}.log", LogDir, Path.DirectorySeparatorChar, t.Year, t.Month, t.Day);
			String dirWithSep = scope .(LogDir);
			dirWithSep.Append(Path.DirectorySeparatorChar);
			let w = Utf16Text.Scoped!(dirWithSep);
			LogDirLen = 0;
			while (w[LogDirLen] != 0 && LogDirLen < LogDirW.Count - 1)
			{
				LogDirW[LogDirLen] = w[LogDirLen];
				LogDirLen++;
			}
			LogDirW[LogDirLen] = 0;
			let lw = Utf16Text.Scoped!(LogPath);
			int32 n = 0;
			while (lw[n] != 0 && n < LogPathW.Count - 1)
			{
				LogPathW[n] = lw[n];
				n++;
			}
			LogPathW[n] = 0;
		}

		/// The log for a line written on the crash path: the open session log, or (not opened
		/// yet, or already closed) the same file opened again for appending.
		public static int CrashHandle()
		{
			if (sHandle != 0)
				return sHandle;
			if (sLateHandle == 0 && LogPathW[0] != 0)
			{
				sLateHandle = Win32Raw.OpenAppend(&LogPathW[0]);
				if (sLateHandle == Win32Raw.INVALID_HANDLE)
					sLateHandle = 0;
			}
			return sLateHandle;
		}

		public static void Open()
		{
			PreparePath();
			Win32Raw.SystemTime t = default;
			Win32Raw.GetLocalTime(&t);
			sHandle = Win32Raw.OpenAppend(&LogPathW[0]);
			if (sHandle == Win32Raw.INVALID_HANDLE)
				sHandle = 0;
			String exe = scope .();
			Environment.GetExecutableFilePath(exe);
			String head = scope .();
			head.AppendF("\r\n==== Treadle session {:D4}-{:D2}-{:D2} {:D2}:{:D2}:{:D2}  pid {}  {} ====\r\n", t.Year, t.Month, t.Day, t.Hour, t.Minute, t.Second, Win32Raw.GetCurrentProcessId(), exe);
			WriteRaw(head);
			PruneOld();
		}

		/// Keeps the 30 newest session logs, crash reports and leak reports.
		static void PruneOld()
		{
			for (let prefix in StringView[3]("treadle-crash-", "treadle-leak-", "treadle-2"))
			{
				System.Collections.List<String> files = scope .();
				defer { for (let f in files) delete f; }
				for (let entry in Directory.EnumerateFiles(LogDir))
				{
					String name = scope .();
					entry.GetFileName(name);
					if (name.StartsWith(prefix))
					{
						String p = new .();
						entry.GetFilePath(p);
						files.Add(p);
					}
				}
				if (files.Count <= 30)
					continue;
				files.Sort(scope (a, b) => String.Compare(a, b, true));
				for (int i < files.Count - 30)
					File.Delete(files[i]).IgnoreError(); // a log still open elsewhere stays; next start retries
			}
		}

		public static void Close()
		{
			if (sHandle != 0)
			{
				WriteRaw("==== session end ====\r\n");
				Win32Raw.CloseHandle(sHandle);
				sHandle = 0;
			}
		}

		public static int Handle => sHandle;

		public static void WriteRaw(StringView text)
		{
			Win32Raw.Write(sHandle, text);
		}

		/// One Output Log line ("[hh:mm:ss] Warning Build: text").
		public static void Line(StringView stamp, LogLevel level, StringView category, StringView text)
		{
			if (sHandle == 0)
				return;
			String line = scope .(); // heap-grown: a log text can be any size
			line.Reserve(text.Length + 48);
			line.AppendF("[{}] {,-7} {}: ", stamp, level, category);
			for (let c in text.RawChars)
			{
				if (c == '\n')
					line.Append("\r\n    ");
				else if (c != '\r')
					line.Append(c);
			}
			line.Append("\r\n");
			using (sLock.Enter())
				WriteRaw(line);
		}
	}

	/// Crash reporting. Installs an unhandled-exception filter (in front of the Beef runtime's
	/// own crash catcher), a Beef runtime error handler (FatalError, failed asserts, index out
	/// of range) and a crash-info hook in the runtime's crash catcher (the Debug runtime's leak
	/// report and anything else that reaches it). On a crash it writes
	/// %LOCALAPPDATA%\Treadle\logs\treadle-crash-<date>-<time>.log with the exception, module +
	/// RVA, registers and a best-effort stack (RtlVirtualUnwind, names and lines from dbghelp), a
	/// minidump next to it (dbghelp, when present), a line in the session log, and flushes the
	/// recovery journal (Recovery.CrashFlush). Then the process ends with exit code 3 (ExitFatal)
	/// without the runtime's "Fatal Error!" box: headless runs (InstallHeadless) print the report
	/// to stderr, the interactive editor shows its own message box naming the report file. A leak
	/// report (Debug builds) goes to treadle-leak-<date>-<time>.log and the session log, with each
	/// leaked object's allocation site, and the process ends with exit code 4 (ExitLeak), no box in
	/// either mode. Headless runs also get a watchdog (TREADLE_WATCHDOG seconds, default 900, 0 =
	/// off) that logs `watchdog: still running <phase>` and ends the process with exit code 5.
	/// See docs/Editor-Model.md, "Fatal errors and crash reports".
	///
	/// Everything on the crash path uses stack buffers and raw Win32 writes: it can run on any
	/// thread, including non-Beef threads, in a process whose heap may be corrupt.
	static class CrashHandler
	{
		[CRepr]
		struct ExceptionRecord
		{
			public uint32 Code;
			public uint32 Flags;
			public ExceptionRecord* Inner;
			public void* Address;
			public uint32 NumParams;
			public uint32 Pad;
			public uint64[15] Info;
		}

		[CRepr]
		struct ExceptionPointers
		{
			public ExceptionRecord* Record;
			public uint8* Context;
		}

		[CRepr, Packed]
		struct MiniDumpExceptionInfo
		{
			public uint32 ThreadId;
			public ExceptionPointers* Pointers;
			public int32 ClientPointers;
		}

		function int32 MiniDumpWriteDumpFn(int process, uint32 pid, int file, uint32 type, MiniDumpExceptionInfo* exc, void* user, void* callback);

		static void* sPrevFilter;
		static MiniDumpWriteDumpFn sMiniDump;
		static bool sInstalled;
		static int32 sInCrash;
		/// Set when a crash report was written this session (tests, the exit path).
		public static bool Crashed;

		const int cContextSize = 0x4D0;
		const int cRip = 0xF8;
		const int cRsp = 0x98;

		public static void Install()
		{
			if (sInstalled)
				return;
			sInstalled = true;
			// Leave room for the handler when the crash is a stack overflow.
			uint32 guarantee = 64 * 1024;
			Win32Raw.SetThreadStackGuarantee(&guarantee);
			let dbghelp = Win32Raw.LoadLibraryW(Utf16Text.Scoped!("dbghelp.dll"));
			if (dbghelp != 0)
				sMiniDump = (MiniDumpWriteDumpFn)Win32Raw.GetProcAddress(dbghelp, "MiniDumpWriteDump");
			if (dbghelp != 0)
			{
				sSymSetOptions = (SymSetOptionsFn)Win32Raw.GetProcAddress(dbghelp, "SymSetOptions");
				sSymInitialize = (SymInitializeWFn)Win32Raw.GetProcAddress(dbghelp, "SymInitializeW");
				sSymFromAddr = (SymFromAddrFn)Win32Raw.GetProcAddress(dbghelp, "SymFromAddr");
				sSymGetLine = (SymGetLineFromAddr64Fn)Win32Raw.GetProcAddress(dbghelp, "SymGetLineFromAddr64");
			}
			SessionLog.PreparePath(); // report paths are known before the session log opens
			sPrevFilter = Win32Raw.SetUnhandledExceptionFilter((void*)(function int32(ExceptionPointers*))=> UnhandledFilter);
#if !BF_PLATFORM_WINDOWS
			InstallPosix();
#else
			// Called by the runtime's crash catcher before it shows or prints anything.
			Runtime.[Friend]AddCrashInfoFunc((void*)(function void())=> OnCrashInfo);
#endif
			Runtime.AddErrorHandler(new => OnRuntimeError);
		}

		// ------------------------------------------------------------------ headless runs

		/// Exit codes of the crash path (EditorArgs: 0 ok, 1 failed, 2 usage).
		public const int32 ExitFatal = 3;
		public const int32 ExitLeak = 4;
		public const int32 ExitWatchdog = 5;

		/// A non-interactive run (TREADLE_SELFTEST, --build-run, --format, --import-c, --version,
		/// --help): no dialog ever, reports go to stderr too.
		public static bool Headless;
		static char8[256] sPhase;
		static int32 sPhaseLen;
		static uint64 sWatchdogStart;
		static uint32 sWatchdogSeconds;

		/// What a headless run is doing, for the watchdog line ("self test codec step 3").
		public static void SetPhase(StringView phase)
		{
			let n = (int32)Math.Min(phase.Length, sPhase.Count);
			Internal.MemCpy(&sPhase[0], phase.Ptr, n);
			sPhaseLen = n;
		}

		/// Called first thing in Main for a non-interactive run: the handlers, no runtime dialog
		/// (PrintOnly is the fallback if anything got past the hooks), the watchdog.
		public static void InstallHeadless(StringView phase)
		{
			Headless = true;
			SetPhase(phase);
			Install();
			Runtime.SetCrashReportKind(.PrintOnly);
			uint32 secs = 900;
			String v = scope .();
			if (Environment.GetEnvironmentVariable("TREADLE_WATCHDOG", v) case .Ok && !v.IsEmpty)
			{
				if (uint32.Parse(v) case .Ok(let parsed))
					secs = parsed;
			}
			sWatchdogSeconds = secs;
			sWatchdogStart = Win32Raw.GetTickCount64();
			if (secs > 0)
				Win32Raw.CreateThread(null, 64 * 1024, (void*)(function [CallingConvention(.Stdcall)] uint32(void*))=> WatchdogProc, null, 0, null);
		}

		/// A raw OS thread (no Beef objects): sleeps until the limit, then reports and ends the run.
		[CallingConvention(.Stdcall)]
		static uint32 WatchdogProc(void* param)
		{
			let limitMs = (uint64)sWatchdogSeconds * 1000;
			while (Win32Raw.GetTickCount64() - sWatchdogStart < limitMs)
				Win32Raw.Sleep(500);
			// A crash report being written gets time to finish (it ends the process itself).
			for (int i < 120)
			{
				if (sInCrash == 0)
					break;
				Win32Raw.Sleep(500);
			}
			RawText t = default;
			t.Add("watchdog: still running ");
			t.Add((sPhaseLen > 0) ? StringView(&sPhase[0], sPhaseLen) : "start-up");
			t.Add(" after "); t.Dec(sWatchdogSeconds); t.Add(" s (TREADLE_WATCHDOG); exit code 5\r\n");
			let log = SessionLog.CrashHandle();
			Win32Raw.Write(log, t.GetView());
			if (log != 0)
				Win32Raw.FlushFileBuffers(log);
			Win32Raw.Write(StdErr(), t.GetView());
			Terminate(ExitWatchdog);
			return 0;
		}

		// ------------------------------------------------------------------ frame-loop watch

		/// What the frame loop is doing now (a string literal: "waiting for input", "events", "drawing",
		/// "presenting"), and when it last passed the top of the loop (GetTickCount64).
		public static char8* sLoopStage = "starting";
		static uint64 sLoopBeat;
		static uint32 sMainThreadId;
		static bool sFrameWatchOn;

		/// The frame loop: called at each stage of every frame.
		public static void LoopStage(char8* stage, bool top = false)
		{
			sLoopStage = stage;
#if BF_PLATFORM_WINDOWS
			if (top)
				sLoopBeat = Win32Raw.GetTickCount64();
#endif
		}

		/// The interactive editor: a raw thread that writes "frame loop stalled N s (stage: X)" and the main thread's
		/// stack to the session log when one pass of the frame loop takes over 5 s (the idle wait is at most 1 s), and
		/// "frame loop running again after N s" when it moves on. Nothing else: it never stops or ends anything.
		public static void StartFrameWatch()
		{
#if BF_PLATFORM_WINDOWS
			if (sFrameWatchOn)
				return;
			sFrameWatchOn = true;
			sMainThreadId = Win32Raw.GetCurrentThreadId();
			sLoopBeat = Win32Raw.GetTickCount64();
			Win32Raw.CreateThread(null, 64 * 1024, (void*)(function [CallingConvention(.Stdcall)] uint32(void*))=> FrameWatchProc, null, 0, null);
#endif
		}

#if BF_PLATFORM_WINDOWS
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int OpenThread(uint32 access, int32 inherit, uint32 threadId);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern uint32 SuspendThread(int thread);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern uint32 ResumeThread(int thread);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 GetThreadContext(int thread, void* context);

		[CallingConvention(.Stdcall)]
		static uint32 FrameWatchProc(void* param)
		{
			const uint64 cLimitMs = 5000;
			uint64 stalledAt = 0;
			int reports = 0;
			while (true)
			{
				Win32Raw.Sleep(1000);
				let beat = sLoopBeat;
				let now = Win32Raw.GetTickCount64();
				if (stalledAt != 0)
				{
					if (beat != stalledAt)
					{
						RawText t = default;
						t.Add("[watch] frame loop running again after "); t.Dec((int)((now - stalledAt) / 1000)); t.Add(" s\r\n");
						Win32Raw.Write(SessionLog.CrashHandle(), t.GetView());
						stalledAt = 0;
					}
					continue;
				}
				if (now - beat < cLimitMs || reports >= 20 || sInCrash != 0)
					continue;
				stalledAt = beat;
				reports++;
				ReportStall(now - beat);
			}
		}

		/// The stall line and the main thread's stack: the thread is suspended only while its registers and return
		/// addresses are read (no allocation, no lock), the names are looked up after it runs again.
		static void ReportStall(uint64 ms)
		{
			uint64[32] pcs = default;
			int count = 0;
			let thread = OpenThread(0x0002 | 0x0008 | 0x0040, 0, sMainThreadId); // SUSPEND_RESUME | GET_CONTEXT | QUERY_INFORMATION
			if (thread != 0)
			{
				uint8[cContextSize + 16] raw = ?;
				uint8* ctx = (uint8*)(void*)(((int)(void*)&raw + 15) & ~15);
				Internal.MemSet(ctx, 0, cContextSize);
				*(uint32*)(ctx + 0x30) = 0x10000B; // ContextFlags: CONTEXT_FULL (AMD64)
				if (SuspendThread(thread) != uint32.MaxValue)
				{
					if (GetThreadContext(thread, ctx) != 0)
					{
						while (count < pcs.Count)
						{
							let pc = *(uint64*)(ctx + cRip);
							if (pc == 0)
								break;
							pcs[count++] = pc;
							uint64 imageBase = 0;
							let fe = Win32Raw.RtlLookupFunctionEntry(pc, &imageBase, null);
							if (fe == null)
							{
								let rsp = *(uint64*)(ctx + cRsp);
								if (rsp == 0 || (rsp & 7) != 0)
									break;
								*(uint64*)(ctx + cRip) = *(uint64*)(void*)(int)rsp;
								*(uint64*)(ctx + cRsp) = rsp + 8;
							}
							else
							{
								void* handlerData = null;
								uint64 establisher = 0;
								Win32Raw.RtlVirtualUnwind(0, imageBase, pc, fe, ctx, &handlerData, &establisher, null);
							}
							if (*(uint64*)(ctx + cRip) == pc)
								break;
						}
					}
					ResumeThread(thread);
				}
				Win32Raw.CloseHandle(thread);
			}
			let log = SessionLog.CrashHandle();
			RawText t = default;
			let stage = sLoopStage;
			t.Add("[watch] frame loop stalled "); t.Dec((int)(ms / 1000)); t.Add(" s (stage: "); t.Add(StringView(stage)); t.Add("); main thread:\r\n");
			Win32Raw.Write(log, t.GetView());
			// The graphics device as the host last saw it (plain reads of ints and a static name: no lock, no allocation).
			let glCheck = ImGui.Host.th_gl_check();
			t.Clear();
			t.Add("[watch] graphics: last check "); t.Add(StringView(ImGui.Host.th_gl_check_name(glCheck)));
			t.Add(", last present "); t.Dec(ImGui.Host.th_gl_last_swap_ms()); t.Add(" ms, longest "); t.Dec(ImGui.Host.th_gl_max_swap_ms());
			t.Add(" ms, rebuilds "); t.Dec(ImGui.Host.th_gl_rebuilds());
			t.Add(", swaps "); t.Dec(ImGui.Host.th_gl_swaps());
			t.Add(", presented "); t.Dec(ImGui.Host.th_gl_present_hits()); t.Add(" of "); t.Dec(ImGui.Host.th_gl_present_hits() + ImGui.Host.th_gl_present_misses());
			t.Add(" checks (watch "); t.Add(ImGui.Host.th_gl_present_armed() != 0 ? "on" : "off"); t.Add(")");
			let sdlErr = ImGui.Host.th_gl_last_sdl_error();
			if (sdlErr != null && sdlErr[0] != 0)
			{
				t.Add(", last swap error: "); t.Add(StringView(sdlErr));
			}
			t.Add("\r\n");
			Win32Raw.Write(log, t.GetView());
			EnsureSymbols();
			for (int i < count)
			{
				t.Clear();
				t.Add("    #"); t.Dec(i, 2); t.Add("  0x"); t.Hex(pcs[i]); t.Add("  "); AddSymbol(ref t, pcs[i], i > 0); t.Add("\r\n");
				Win32Raw.Write(log, t.GetView());
			}
			if (log != 0)
				Win32Raw.FlushFileBuffers(log);
		}
#endif

		/// stderr for a headless run (0 when there is none).
		static int StdErr()
		{
			if (!Headless)
				return 0;
			var h = Win32Raw.GetStdHandle((uint32)-12);
			if (h == 0 || h == Win32Raw.INVALID_HANDLE)
			{
				Win32Raw.AttachConsole((uint32)-1); // a GUI exe started from a terminal: print there
				h = Win32Raw.GetStdHandle((uint32)-12);
			}
			return (h == Win32Raw.INVALID_HANDLE) ? 0 : h;
		}

		static void Terminate(int32 code)
		{
			Win32Raw.TerminateProcess(Win32Raw.GetCurrentProcess(), (uint32)code);
		}

		/// After a crash report: the closing lines (session log, stderr when headless), then the
		/// end of the process. Interactive: the editor's own message box first, naming the report.
		static void EndAfterReport(StringView message, int32 code)
		{
			RawText t = default;
			t.Add("[FATAL] ");
			t.Add(message);
			t.Add("\r\n[FATAL] crash report: ");
			if (sReportLen > 0)
				t.Wide(&sReportPath[0], sReportLen);
			else
				t.Add("(see the [CRASH] line above)");
			t.Add("; exit code "); t.Dec(code); t.Add("\r\n");
			let log = SessionLog.CrashHandle();
			Win32Raw.Write(log, t.GetView());
			if (log != 0)
				Win32Raw.FlushFileBuffers(log);
			if (Headless)
				Win32Raw.Write(StdErr(), t.GetView());
#if BF_PLATFORM_WINDOWS
			else
			{
				RawText m = default;
				m.Add("Treadle stopped because of an internal error.\r\n\r\n");
				m.Add(message);
				m.Add("\r\n\r\nThe crash report was written to:\r\n");
				if (sReportLen > 0)
					m.Wide(&sReportPath[0], sReportLen);
				else
					m.Add("(the report could not be written; see the session log)");
				m.Add("\r\n\r\nUnsaved changes are offered for recovery the next time Treadle starts.");
				char16[2100] text = ?;
				let n = Win32Raw.MultiByteToWideChar(65001, 0, &m.Buf[0], (int32)m.Len, &text[0], 2099);
				text[Math.Max(n, 0)] = 0;
				char16[24] caption = ?;
				int32 c = 0;
				for (let ch in "Treadle crashed".RawChars)
					caption[c++] = (char16)ch;
				caption[c] = 0;
				// MB_OK | MB_ICONERROR | MB_TOPMOST | MB_SETFOREGROUND
				Win32Raw.MessageBoxW(0, &text[0], &caption[0], 0x10 | 0x40000 | 0x10000);
			}
#endif
			Terminate(code);
		}

#if BF_PLATFORM_WINDOWS
		/// Corlib's Runtime.BfDebugMessageData (private there): the text the runtime hands its
		/// crash catcher, the leak report among them.
		[CRepr]
		struct DebugMessageData
		{
			public int32 MessageType; // 1 = error
			public int32 StackWindbackCount;
			public int32 BufferParamLen;
			public char8* BufferParam;
			public void* PCOverride;
			public char8* BufferPtr;
			public int StrSize;
		}
		[CLink] static extern DebugMessageData gBfDebugMessageData;

		/// The text the runtime set up for its report (the leak report, ...), or empty.
		static StringView RuntimeMessage()
		{
			if (gBfDebugMessageData.MessageType == 1 && gBfDebugMessageData.BufferParam != null && gBfDebugMessageData.BufferParamLen > 0)
				return StringView(gBfDebugMessageData.BufferParam, gBfDebugMessageData.BufferParamLen);
			return default;
		}

		/// The runtime's crash catcher is about to report (its "Fatal Error!" box in a GUI exe).
		/// The error handler and the exception filter end the process before it gets here; what
		/// still arrives is the Debug runtime's leak report and anything else the runtime reports
		/// itself.
		static void OnCrashInfo()
		{
			if (Win32Raw.IsDebuggerPresent() != 0)
				return;
			let text = RuntimeMessage();
			if (text.Contains("memory leak"))
			{
				WriteLeakReport(text);
				Terminate(ExitLeak);
			}
			if (sInCrash != 0)
				Terminate(ExitFatal); // a report is already being written (or was): just end
			uint8[cContextSize + 16] raw = ?;
			uint8* rawPtr = (uint8*)&raw;
			uint8* ctx = (uint8*)(void*)(((int)(void*)rawPtr + 15) & ~15);
			Win32Raw.RtlCaptureContext(ctx);
			let message = text.IsEmpty ? StringView("the Beef runtime reported a fatal error (no message)") : text;
			WriteReport(null, ctx, message);
			EndAfterReport(message, ExitFatal);
		}

		/// Writes the leak report: treadle-leak-<stamp>.log, the session log, stderr (headless).
		/// The runtime's text lists each leaked object as "(Type)0xADDR"; its allocation site is
		/// read from the object's debug header (the return address the Debug runtime stores, or
		/// its stored stack trace with AllocStackTraceDepth > 1) and named through dbghelp.
		static void WriteLeakReport(StringView text)
		{
			if (Interlocked.Exchange(ref sInCrash, 1) != 0)
				return;
			Win32Raw.SystemTime st = default;
			Win32Raw.GetLocalTime(&st);
			int file = CreateReportFile("treadle-leak-", st);
			let log = SessionLog.CrashHandle();
			let err = StdErr();
			EnsureSymbols();

			// The summary: the first line ("3 object memory leaks detected.").
			var summary = text;
			let nl = summary.IndexOf('\n');
			if (nl >= 0)
				summary = summary.Substring(0, nl);
			summary.Trim();
			RawText t = default;
			t.Add("Treadle leak report\r\n");
			Flush(file, ref t);
			t.Add("[LEAK] ");
			t.Add(summary);
			t.Add(" (Beef Debug runtime leak check); report: ");
			t.Wide(&sReportPath[0], sReportLen);
			t.Add("; exit code 4\r\n");
			Win32Raw.Write(log, t.GetView());
			Win32Raw.Write(err, t.GetView());
			Flush(file, ref t);

			int leaks = 0;
			for (var line in text.Split('\n'))
			{
				// "   (System.String)0xBF0'11009710": the object's own type (the "LEAK\t(System.Object)" line repeats it).
				if (!line.StartsWith("   ("))
					continue;
				let close = line.IndexOf(")0x");
				if (close < 0)
					continue;
				let typeName = line.Substring(4, close - 4);
				uint64 addr = 0;
				for (let c in line.Substring(close + 3).RawChars)
				{
					if (c == '\'')
						continue;
					int d = -1;
					if (c >= '0' && c <= '9') d = c - '0';
					else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
					else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
					if (d < 0)
						break;
					addr = (addr << 4) | (uint64)d;
				}
				leaks++;
				if (leaks > 200)
				{
					t.Add("[LEAK]   ... more leaked objects in the report's runtime text\r\n");
					Win32Raw.Write(log, t.GetView());
					Win32Raw.Write(err, t.GetView());
					Flush(file, ref t);
					break;
				}
				t.Add("[LEAK]   "); t.Add(typeName); t.Add(" at 0x"); t.Hex(addr);
				AddAllocSites(ref t, addr);
				t.Add("\r\n");
				Win32Raw.Write(log, t.GetView());
				Win32Raw.Write(err, t.GetView());
				Flush(file, ref t);
			}

			// The runtime's own text last, as it gave it.
			t.Add("\r\nruntime text:\r\n");
			Flush(file, ref t);
			Win32Raw.Write(file, text);
			t.Add("\r\n");
			Flush(file, ref t);
			if (file != 0)
			{
				Win32Raw.FlushFileBuffers(file);
				Win32Raw.CloseHandle(file);
			}
			if (log != 0)
				Win32Raw.FlushFileBuffers(log);
		}

		/// ", allocated at <site> <- <caller> ..." from a leaked object's Debug header.
		static void AddAllocSites(ref RawText t, uint64 addr)
		{
#if BF_ENABLE_OBJECT_DEBUG_FLAGS
			if (addr == 0 || (addr & 7) != 0)
				return;
			let obj = (uint8*)(void*)(int)addr;
			let flags = *(int*)obj & 0xFF;
			let info = *(int*)(obj + 8);
			uint64* trace = null;
			int count = 0;
			uint64 single = 0;
			if ((flags & 0x40) != 0) // AllocInfo_Short: count in the low byte, size in the high bits
			{
				let size = info >> 16;
				count = info & 0xFF;
				if (size > 0 && size < 0x01000000)
					trace = (uint64*)(void*)(obj + size);
			}
			else if ((flags & 0x20) != 0) // AllocInfo: size; then (count << 8 | flags), then the trace
			{
				let size = info;
				if (size > 0 && size < 0x01000000)
				{
					count = *(int*)(obj + size) >> 8;
					trace = (uint64*)(void*)(obj + size + sizeof(int));
				}
			}
			else
				single = (uint64)info; // the return address of the allocation
			if (trace == null)
			{
				count = 1;
				trace = &single;
			}
			count = Math.Min(count, 6);
			for (int i < count)
			{
				let pc = trace[i];
				if (pc == 0)
					break;
				t.Add((i == 0) ? ", allocated at " : " <- ");
				AddSymbol(ref t, pc, true);
			}
#endif
		}
#endif

		// ------------------------------------------------------------------ symbols (dbghelp)

		function uint32 SymSetOptionsFn(uint32 options);
		function int32 SymInitializeWFn(int process, char16* searchPath, int32 invade);
		function int32 SymFromAddrFn(int process, uint64 address, uint64* displacement, void* symbol);
		function int32 SymGetLineFromAddr64Fn(int process, uint64 address, uint32* displacement, ImagehlpLine64* line);

		[CRepr]
		struct ImagehlpLine64
		{
			public uint32 SizeOfStruct;
			public void* Key;
			public uint32 LineNumber;
			public char8* FileName;
			public uint64 Address;
		}

		static SymSetOptionsFn sSymSetOptions;
		static SymInitializeWFn sSymInitialize;
		static SymFromAddrFn sSymFromAddr;
		static SymGetLineFromAddr64Fn sSymGetLine;
		static bool sSymTried;
		static bool sSymReady;

		static void EnsureSymbols()
		{
			if (sSymTried)
				return;
			sSymTried = true;
			if (sSymInitialize == null || sSymFromAddr == null)
				return;
			// UNDNAME | DEFERRED_LOADS | LOAD_LINES | FAIL_CRITICAL_ERRORS | NO_PROMPTS
			if (sSymSetOptions != null)
				sSymSetOptions(0x2 | 0x4 | 0x10 | 0x200 | 0x80000);
			sSymReady = sSymInitialize(Win32Raw.GetCurrentProcess(), null, 1) != 0;
		}

		/// "module+0xRVA  Function+0x12 at file:line" (the name and line when dbghelp finds them).
		/// `isReturn`: the address is a return address, so the line is looked up one byte earlier.
		static void AddSymbol(ref RawText t, uint64 pc, bool isReturn)
		{
			AddModule(ref t, pc);
			if (!sSymReady)
				return;
			uint64[80] buf = default; // SYMBOL_INFO (88 bytes) + the name
			let info = (uint8*)&buf[0];
			*(uint32*)info = 88; // SizeOfStruct
			*(uint32*)(info + 80) = (uint32)(sizeof(uint64[80]) - 88); // MaxNameLen
			uint64 disp = 0;
			if (sSymFromAddr(Win32Raw.GetCurrentProcess(), pc, &disp, info) != 0)
			{
				let nameLen = Math.Min(*(uint32*)(info + 76), (uint32)(sizeof(uint64[80]) - 88));
				t.Add("  ");
				t.Add(StringView((char8*)(info + 84), (int)nameLen));
				t.Add("+0x");
				AddHex(ref t, disp);
			}
			ImagehlpLine64 line = default;
			line.SizeOfStruct = (uint32)sizeof(ImagehlpLine64);
			uint32 lineDisp = 0;
			if (sSymGetLine != null && sSymGetLine(Win32Raw.GetCurrentProcess(), isReturn ? pc - 1 : pc, &lineDisp, &line) != 0 && line.FileName != null)
			{
				t.Add(" at ");
				t.Add(StringView(line.FileName));
				t.Add(':');
				t.Dec(line.LineNumber);
			}
		}

		static void AddHex(ref RawText t, uint64 v)
		{
			int digits = 1;
			while (digits < 16 && (v >> (digits * 4)) != 0)
				digits++;
			t.Hex(v, digits);
		}

		/// Report file <logs>\<prefix>YYYY-MM-DD-HHMMSS.log, its path kept in sReportPath.
		static int CreateReportFile(StringView prefix, Win32Raw.SystemTime st)
		{
			int32 len = 0;
			for (int32 i < SessionLog.LogDirLen)
				sReportPath[len++] = SessionLog.LogDirW[i];
			RawText name = default;
			name.Add(prefix);
			name.Dec(st.Year, 4); name.Add('-'); name.Dec(st.Month, 2); name.Add('-'); name.Dec(st.Day, 2); name.Add('-');
			name.Dec(st.Hour, 2); name.Dec(st.Minute, 2); name.Dec(st.Second, 2);
			name.Add(".log");
			for (let c in name.GetView().RawChars)
				if (len < sReportPath.Count - 1)
					sReportPath[len++] = (char16)c;
			sReportPath[len] = 0;
			sReportLen = len;
			int file = Win32Raw.Create(&sReportPath[0]);
			if (file == Win32Raw.INVALID_HANDLE)
			{
				sReportLen = 0;
				file = 0;
			}
			return file;
		}

		static char16[600] sReportPath;
		static int32 sReportLen;

		static Runtime.ErrorHandlerResult OnRuntimeError(Runtime.ErrorStage stage, Runtime.Error error)
		{
			if (stage != .PreFail)
				return .ContinueFailure;
			// A failed assert is reported again as a FatalError ("Assert failed: <expr> at line <n>
			// in <file>"), which carries the place: that one is handled.
			StringView message = default;
			if (let fatal = error as Runtime.FatalError)
				message = fatal.mError;
			else
				return .ContinueFailure;
			let underDebugger = Win32Raw.IsDebuggerPresent() != 0;
#if !BF_PLATFORM_WINDOWS
			WritePosixReport(0, 0, null, null, message);
			if (Headless)
				EndAfterReport(message, ExitFatal);
			return .ContinueFailure;
#else
			uint8[cContextSize + 16] raw = ?;
			uint8* rawPtr = (uint8*)&raw;
			uint8* ctx = (uint8*)(void*)(((int)(void*)rawPtr + 15) & ~15);
			Win32Raw.RtlCaptureContext(ctx);
			WriteReport(null, ctx, message);
			// Under a debugger the runtime breaks into it (the report is written first).
			if (!underDebugger)
				EndAfterReport(message, ExitFatal);
			return .ContinueFailure;
#endif
		}

		[CallingConvention(.Stdcall)]
		static int32 UnhandledFilter(ExceptionPointers* ep)
		{
			StringView runtimeText = default;
#if BF_PLATFORM_WINDOWS
			// The Debug runtime raises a breakpoint after setting up its message: the leak check at
			// exit (GC::Shutdown) and its own checks.
			if (ep != null && ep.Record != null && ep.Record.Code == 0x80000003)
				runtimeText = RuntimeMessage();
			if (runtimeText.Contains("memory leak"))
			{
				WriteLeakReport(runtimeText);
				Terminate(ExitLeak);
			}
#endif
			WriteReport(ep, (ep != null) ? ep.Context : null, runtimeText);
			RawText what = default;
			if (ep != null && ep.Record != null)
			{
				let code = ep.Record.Code;
				what.Add(CodeName(code));
				what.Add(" (0x"); what.Hex(code, 8); what.Add(") at ");
				AddSymbol(ref what, (uint64)(int)ep.Record.Address, false);
				if (code == 0x80000003 && !runtimeText.IsEmpty)
				{
					what.Add(": ");
					what.Add(runtimeText);
				}
				else if (code == 0x80000003)
					what.Add(": a Debug runtime check stopped the program (for example a deleted object was used)");
			}
			else
				what.Add("unhandled exception");
			EndAfterReport(what.GetView(), ExitFatal);
			return 0; // not reached
		}

		static StringView CodeName(uint32 code)
		{
			switch (code)
			{
			case 0xC0000005: return "EXCEPTION_ACCESS_VIOLATION";
			case 0xC00000FD: return "EXCEPTION_STACK_OVERFLOW";
			case 0xC0000094: return "EXCEPTION_INT_DIVIDE_BY_ZERO";
			case 0xC000001D: return "EXCEPTION_ILLEGAL_INSTRUCTION";
			case 0xC0000096: return "EXCEPTION_PRIV_INSTRUCTION";
			case 0xC0000006: return "EXCEPTION_IN_PAGE_ERROR";
			case 0xC000008C: return "EXCEPTION_ARRAY_BOUNDS_EXCEEDED";
			case 0xC0000409: return "STATUS_STACK_BUFFER_OVERRUN";
			case 0xC0000374: return "STATUS_HEAP_CORRUPTION";
			case 0x80000003: return "EXCEPTION_BREAKPOINT";
			case 0xE06D7363: return "C++ exception";
			default: return "exception";
			}
		}

		/// "module.dll+0x1234" for an address.
		static void AddModule(ref RawText t, uint64 address)
		{
			int module = 0;
			// FROM_ADDRESS | UNCHANGED_REFCOUNT
			if (Win32Raw.GetModuleHandleExW(4 | 2, (void*)(int)address, &module) == 0 || module == 0)
			{
				t.Add("?");
				return;
			}
			char16[520] name = ?;
			let n = (int32)Win32Raw.GetModuleFileNameW(module, &name[0], 520);
			int32 start = 0;
			for (int32 i < n)
				if (name[i] == '\\' || name[i] == '/')
					start = i + 1;
			t.Wide(&name[start], n - start);
			t.Add("+0x");
			t.Hex(address - (uint64)module, 8);
		}

		/// stderr while a headless crash report is written (each report line is echoed there).
		static int sEchoErr;

		static void Flush(int file, ref RawText t)
		{
			Win32Raw.Write(file, t.GetView());
			Win32Raw.Write(sEchoErr, t.GetView());
			t.Clear();
		}

		static void WriteReport(ExceptionPointers* ep, uint8* context, StringView fatalMessage)
		{
			// One report per process: a second fault inside the handler must not recurse.
			if (Interlocked.Exchange(ref sInCrash, 1) != 0)
				return;
			Crashed = true;
			Win32Raw.SystemTime st = default;
			Win32Raw.GetLocalTime(&st);
			sEchoErr = StdErr();
			EnsureSymbols();

			// Report path: <logs>\treadle-crash-YYYY-MM-DD-HHMMSS.log (and .dmp).
			int file = CreateReportFile("treadle-crash-", st);

			RawText t = default;
			t.Add("Treadle crash report\r\n");
			t.Add("time    "); t.Dec(st.Year, 4); t.Add('-'); t.Dec(st.Month, 2); t.Add('-'); t.Dec(st.Day, 2); t.Add(' ');
			t.Dec(st.Hour, 2); t.Add(':'); t.Dec(st.Minute, 2); t.Add(':'); t.Dec(st.Second, 2); t.Add("\r\n");
			t.Add("process "); t.Dec(Win32Raw.GetCurrentProcessId()); t.Add("  thread "); t.Dec(Win32Raw.GetCurrentThreadId()); t.Add("\r\n");
			if (sPhaseLen > 0)
			{
				t.Add("phase   "); t.Add(StringView(&sPhase[0], sPhaseLen)); t.Add("\r\n");
			}
			if (ep != null && ep.Record != null)
			{
				let rec = ep.Record;
				t.Add("code    0x"); t.Hex(rec.Code, 8); t.Add(' '); t.Add(CodeName(rec.Code)); t.Add("\r\n");
				t.Add("address 0x"); t.Hex((uint64)(int)rec.Address); t.Add("  "); AddSymbol(ref t, (uint64)(int)rec.Address, false); t.Add("\r\n");
				if (rec.Code == 0xC0000005 && rec.NumParams >= 2)
				{
					t.Add((rec.Info[0] == 0) ? "access  read of 0x" : ((rec.Info[0] == 1) ? "access  write to 0x" : "access  execute at 0x"));
					t.Hex(rec.Info[1]);
					t.Add("\r\n");
				}
			}
			if (!fatalMessage.IsEmpty)
			{
				t.Add("fatal   Beef runtime error: ");
				Flush(file, ref t);
				// The message may be long: write it directly.
				Win32Raw.Write(file, fatalMessage);
				Win32Raw.Write(sEchoErr, fatalMessage);
				t.Add("\r\n");
			}
			Flush(file, ref t);

			if (context != null)
			{
				t.Add("\r\nregisters\r\n");
				StringView[17] names = .("RAX", "RCX", "RDX", "RBX", "RSP", "RBP", "RSI", "RDI", "R8 ", "R9 ", "R10", "R11", "R12", "R13", "R14", "R15", "RIP");
				for (int i < 17)
				{
					t.Add("  "); t.Add(names[i]); t.Add(" 0x");
					t.Hex(*(uint64*)(context + 0x78 + i * 8));
					if (i % 3 == 2)
						t.Add("\r\n");
				}
				t.Add("\r\n  EFLAGS 0x"); t.Hex(*(uint32*)(context + 0x44), 8); t.Add("\r\n");
				Flush(file, ref t);

				// Best-effort stack: unwind a copy of the context with the modules' unwind data.
				t.Add("\r\nstack (best effort)\r\n");
				Flush(file, ref t);
				uint8[cContextSize + 16] raw = ?;
				uint8* rawPtr = (uint8*)&raw;
				uint8* ctx = (uint8*)(void*)(((int)(void*)rawPtr + 15) & ~15);
				Internal.MemCpy(ctx, context, cContextSize);
				for (int frame < 64)
				{
					let pc = *(uint64*)(ctx + cRip);
					if (pc == 0)
						break;
					t.Add("  #"); t.Dec(frame, 2); t.Add("  0x"); t.Hex(pc); t.Add("  "); AddSymbol(ref t, pc, frame > 0); t.Add("\r\n");
					Flush(file, ref t);
					uint64 imageBase = 0;
					let fe = Win32Raw.RtlLookupFunctionEntry(pc, &imageBase, null);
					if (fe == null)
					{
						// Leaf function: the return address is at the top of the stack.
						let rsp = *(uint64*)(ctx + cRsp);
						if (rsp == 0 || (rsp & 7) != 0)
							break;
						*(uint64*)(ctx + cRip) = *(uint64*)(void*)(int)rsp;
						*(uint64*)(ctx + cRsp) = rsp + 8;
					}
					else
					{
						void* handlerData = null;
						uint64 establisher = 0;
						Win32Raw.RtlVirtualUnwind(0, imageBase, pc, fe, ctx, &handlerData, &establisher, null);
					}
					if (*(uint64*)(ctx + cRip) == pc && *(uint64*)(ctx + cRsp) == 0)
						break;
				}
			}

			// Unsaved documents first (they matter most), then the minidump.
			t.Add("\r\nrecovery journal: ");
			t.Add(Recovery.CrashFlush() ? "flushed\r\n" : "nothing to flush\r\n");
			Flush(file, ref t);

			if (sMiniDump != null && ep != null && sReportLen > 4)
			{
				char16[600] path = ?;
				Internal.MemCpy(&path[0], &sReportPath[0], (sReportLen + 1) * sizeof(char16));
				let stemLen = sReportLen - 4; // without ".log"
				path[stemLen] = '.'; path[stemLen + 1] = 'd'; path[stemLen + 2] = 'm'; path[stemLen + 3] = 'p'; path[stemLen + 4] = 0;
				let dump = Win32Raw.Create(&path[0]);
				if (dump != Win32Raw.INVALID_HANDLE)
				{
					MiniDumpExceptionInfo info = default;
					info.ThreadId = Win32Raw.GetCurrentThreadId();
					info.Pointers = ep;
					info.ClientPointers = 0;
					// MiniDumpWithThreadInfo | MiniDumpWithUnloadedModules | MiniDumpWithIndirectlyReferencedMemory
					let ok = sMiniDump(Win32Raw.GetCurrentProcess(), Win32Raw.GetCurrentProcessId(), dump, 0x1000 | 0x20 | 0x40, &info, null, null);
					Win32Raw.CloseHandle(dump);
					t.Add((ok != 0) ? "minidump written next to this report (.dmp)\r\n" : "minidump failed\r\n");
					Flush(file, ref t);
				}
			}
			if (file != 0)
			{
				Win32Raw.FlushFileBuffers(file);
				Win32Raw.CloseHandle(file);
			}

			// The session log points at the report.
			RawText line = default;
			line.Add("[CRASH] report written: ");
			line.Wide(&sReportPath[0], sReportLen);
			line.Add("\r\n");
			let log = SessionLog.CrashHandle();
			Win32Raw.Write(log, line.GetView());
			if (log != 0)
				Win32Raw.FlushFileBuffers(log);
		}

		/// Hidden debug switch, to check the crash report and the recovery prompt:
		/// TREADLE_DEBUG_CRASH_TEST=1 (access violation on the UI thread), =thread (on a worker
		/// thread), =fatal (Beef Runtime.FatalError). Adding "dirty" (=dirty, =fatal-dirty, ...)
		/// first appends a comment line to the open document, so it is unsaved when the crash
		/// happens (`markDirty` is called at frame 30, the crash comes at frame 45).
		public static void MaybeCrashForTest(int frame, delegate void() markDirty)
		{
			if (frame != 30 && frame != 45)
				return;
			String v = scope .();
			if (Environment.GetEnvironmentVariable("TREADLE_DEBUG_CRASH_TEST", v) case .Err || v.IsEmpty || v == "0")
				return;
			if (frame == 30)
			{
				if (v.Contains("dirty"))
					markDirty();
				return;
			}
			Notify.Log(.Warning, "Editor", scope $"TREADLE_DEBUG_CRASH_TEST={v}: crashing on purpose");
			if (v.StartsWith("fatal"))
				Runtime.FatalError("TREADLE_DEBUG_CRASH_TEST: deliberate fatal error");
			if (v.StartsWith("thread"))
			{
				Thread t = new .(new () => { CrashNow(); });
				t.Start(true);
				Thread.Sleep(5000);
				return;
			}
			CrashNow();
		}

		/// Hidden debug switch for headless runs (the `fatal` self test starts child editors with
		/// it): TREADLE_DEBUG_FATAL=fatal (Runtime.FatalError), =assert (a failed Runtime.Assert),
		/// =null (an access violation), =leak (an object that is never deleted: the Debug runtime's
		/// leak check at exit), =hang (never finishes: the watchdog). Ignored in interactive runs.
		public static void MaybeDebugFatal()
		{
			if (!Headless)
				return;
			String v = scope .();
			if (Environment.GetEnvironmentVariable("TREADLE_DEBUG_FATAL", v) case .Err || v.IsEmpty)
				return;
			switch (v)
			{
			case "fatal":
				Runtime.FatalError("TREADLE_DEBUG_FATAL: deliberate fatal error");
			case "assert":
				Runtime.Assert(v.Length == 0, "TREADLE_DEBUG_FATAL deliberate assert");
			case "null":
				CrashNow();
			case "leak":
				String leaked = new String("TREADLE_DEBUG_FATAL leak");
				leaked.Append('!');
			case "hang":
				SetPhase("TREADLE_DEBUG_FATAL=hang");
				while (sWatchdogSeconds > 0)
					Thread.Sleep(200);
			}
		}

		static int* sCrashTarget = (int*)(void*)(int)0x10;

		static void CrashNow()
		{
			*sCrashTarget = 0x5EB;
		}
	}
}
