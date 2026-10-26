// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using System.Threading;
using Treadle.Debug;
using Treadle.Debug.Dap;
using Treadle.Document;
using Treadle.Graph;

namespace Treadle.Editor
{
	/// The `debug` self test, second half (docs/Debugging.md, "Windowed programs" and "Libraries"):
	/// a copy of m1 with `kind windowed` debugged by F5 (the stop on b7 with its values, the
	/// program's Console output in Debug Output, exit 0; a second F5 ended by Stop leaves no process);
	/// on Windows the same exe started from a command prompt (output in that console, through a pipe
	/// and in a console of its own) and with no parent output at all (OutputDebugStringA, exit 0);
	/// then the library fixture built in Debug, a C host that loads it, Attach to Process on the host
	/// and a breakpoint in the library's exported function hit.
	extension EditorApp
	{
#if BF_PLATFORM_WINDOWS
		const String WinProgramFile = "Win\\Program.treadle";
		const String LibMathFile = "Lib\\Mathx.treadle";
#else
		const String WinProgramFile = "Win/Program.treadle";
#endif
		/// What m1 writes (its Console lines, in order).
		const String M1Output = "Woof\n4\nTweet\n2\n7\n7\ndone\ngoodbye from Defer\nan animal is freed\nan animal is freed\n";
		Treadle.Backend.Driver.RunningProcess mDbgHost ~ delete _;
		int32 mDbgHostPid;
		bool mDbgWinSecond;

		/// The host of the library test: loads the library by path (argv[1]), treadle_init, says
		/// "ready" and waits for the file argv[2], then calls the exported fl_twice(21) and
		/// treadle_shutdown.
		const String LibHostSource = """
			#include <stdio.h>
			#include <windows.h>
			typedef void (*init_fn)(void);
			typedef int (*shut_fn)(void);
			typedef long long (*twice_fn)(long long);
			int main(int argc, char** argv)
			{
			    HMODULE lib;
			    int i;
			    if (argc < 3) return 2;
			    lib = LoadLibraryA(argv[1]);
			    if (!lib) { puts("no library"); return 2; }
			    ((init_fn)GetProcAddress(lib, "treadle_init"))();
			    puts("ready");
			    fflush(stdout);
			    for (i = 0; i < 3000 && GetFileAttributesA(argv[2]) == INVALID_FILE_ATTRIBUTES; i++)
			        Sleep(20);
			    printf("twice %lld", ((twice_fn)GetProcAddress(lib, "fl_twice"))(21));
			    putchar(10);
			    printf("leaks %d", ((shut_fn)GetProcAddress(lib, "treadle_shutdown"))());
			    putchar(10);
			    fflush(stdout);
			    return 0;
			}
			""";

		/// Copies m1 as `Win` with `kind windowed`, the library fixture as `Lib` and writes the
		/// host's source to `Host` (case 0 of SelfTestDebug).
		void DbgKindsSetup(StringView samples)
		{
			String win = scope $"{mDbgDir}{DbgSep}Win";
			Directory.CreateDirectory(win).IgnoreError();
			for (let e in Directory.EnumerateFiles(scope $"{samples}/m1"))
			{
				String name = scope .();
				e.GetFileName(name);
				File.Copy(e.GetFilePath(.. scope .()), scope $"{win}{DbgSep}{name}").IgnoreError();
			}
			String proj = scope $"{win}{DbgSep}M1.tproj";
			String text = scope .();
			File.ReadAllText(proj, text, true).IgnoreError();
			let changed = text.Contains("\tkind console\n");
			text.Replace("\tkind console\n", "\tkind windowed\n");
			File.WriteAllText(proj, text).IgnoreError();
			SelfTestCheck(changed, "debug: the Win copy of m1 is kind windowed");
#if BF_PLATFORM_WINDOWS
			String fixtures = scope .();
			if (FindFixtures(samples, fixtures))
				CopyTree(scope $"{fixtures}/projects/library", scope $"{mDbgDir}{DbgSep}Lib");
			Directory.CreateDirectory(scope $"{mDbgDir}{DbgSep}Host").IgnoreError();
			File.WriteAllText(scope $"{mDbgDir}{DbgSep}Host{DbgSep}host.c", LibHostSource).IgnoreError();
#endif
		}

		/// The Debug exe of the Win copy.
		void DbgWinExe(String outPath)
		{
#if BF_PLATFORM_WINDOWS
			outPath.Set(scope $"{mDbgDir}{DbgSep}Win{DbgSep}build{DbgSep}Debug{DbgSep}M1.exe");
#else
			outPath.Set(scope $"{mDbgDir}{DbgSep}Win{DbgSep}build{DbgSep}Debug{DbgSep}M1");
#endif
		}

		bool SelfTestDebugKinds()
		{
			switch (mSelfTestStep)
			{
			case 23:
				OpenProjectNow(scope $"{mDbgDir}{DbgSep}Win", scope $"{mDbgDir}{DbgSep}Win{DbgSep}Program.treadle", true);
				mSelfTestWait = 3;
				return false;
			case 24:
				let speak = DbgNode(WinProgramFile, "Main", "b7", let sheet);
				if (speak == null)
				{
					SelfTestCheck(false, "debug: node b7 of the windowed copy was not found");
					return DbgAbort();
				}
				OpenTab(sheet);
				Debug.ClearBreakpoints();
				Debug.AddBreakpoint(sheet.Doc.FilePath, sheet.Key, "b7");
				mDbgLaunchBase = DebugLaunches;
				StartDebugging();
				SelfTestCheck(mBuild != null && mBuild.Running, "debug: F5 builds the windowed copy of m1 in Debug");
				mDbgWatch.Restart();
				return false;
			case 25:
				if (!DbgWaitLaunch("the stop on b7 of the windowed program"))
					return false;
#if BF_PLATFORM_WINDOWS
				{
					String exe = scope .();
					DbgWinExe(exe);
					let sub = PeSubsystem(exe);
					SelfTestCheck(sub == 2, scope $"debug: the program F5 launched is a windowed exe (PE subsystem {sub})");
				}
#endif
				let f = Debug.CurrentFrame;
				DebugVariable pet = null;
				for (let v in Debug.Locals)
					if (v.Label == "pet")
						pet = v;
				SelfTestCheck(Debug.IsStopped && Debug.Reason == .Breakpoint && f != null && f.NodeKey == "b7" && pet != null && pet.Value.StartsWith("Zoo.Dog"),
					scope $"debug: the windowed program stops on b7 with pet = {(pet != null) ? pet.Value : "(missing)"} ({Debug.Reason})");
				if (!Debug.IsStopped)
					return DbgAbort();
				let node = DbgNode(WinProgramFile, "Main", "b7", let s2);
				String pv = scope .();
				Pin recv = null;
				if (node != null)
					for (let p in node.Inputs)
						if (p.Role == .Receiver)
							recv = p;
				SelfTestCheck(recv != null && DebugPinValue(s2, recv, pv) && pv.StartsWith("Zoo.Dog"), scope $"debug: the windowed program's receiver pin of b7 shows {pv}");
				// b7 calls Speak: nothing is written yet
				SelfTestCheck(!DbgOutputHas("Woof"), "debug: at the first stop on b7 the windowed program has not written Woof yet");
				mDbgWinSecond = false;
				Debug.Continue();
				return false;
			case 26:
				if (Debug.IsStopped && !mDbgWinSecond)
				{
					// the second stop on b7: what the first pass wrote is in Debug Output already (the
					// runtime writes stdout unbuffered under a debugger)
					mDbgWinSecond = true;
					DebugVariable pet = null;
					for (let v in Debug.Locals)
						if (v.Label == "pet")
							pet = v;
					SelfTestCheck(Debug.CurrentFrame?.NodeKey == "b7" && pet != null && pet.Value.StartsWith("Zoo.Bird") && DbgOutputHas("Woof") && DbgOutputHas("4"),
						scope $"debug: the windowed program stops on b7 again (pet = {(pet != null) ? pet.Value : "(missing)"}) with the lines written before the stop in Debug Output (Woof, 4)");
					Debug.ClearBreakpoints();
					Debug.Continue();
					mDbgWatch.Restart();
					mSelfTestStep--;
					return false;
				}
				if (!DbgWait(Debug.State == .Exited, "the windowed program to exit"))
					return false;
				SelfTestCheck(mDbgWinSecond, "debug: the windowed program stopped twice on b7");
				SelfTestCheck(Debug.ExitCode == 0 && DbgOutputHas("Tweet") && DbgOutputHas("goodbye from Defer") && DbgOutputHas("an animal is freed"),
					scope $"debug: the windowed program exits with code {Debug.ExitCode} and its output is in Debug Output (Tweet, goodbye from Defer, an animal is freed)");
				// F5 again, then Stop while it is stopped: the program ends
				let speak = DbgNode(WinProgramFile, "Main", "b7", let sheet);
				if (speak == null)
					return DbgAbort();
				Debug.AddBreakpoint(sheet.Doc.FilePath, sheet.Key, "b7");
				mDbgLaunchBase = DebugLaunches;
				StartDebugging();
				mDbgWatch.Restart();
				return false;
			case 27:
				if (!DbgWaitLaunch("the second stop of the windowed program"))
					return false;
				SelfTestCheck(Debug.IsStopped, "debug: the windowed program stopped again");
				Debug.Stop();
				mDbgWatch.Restart();
				return false;
			case 28:
				{
					List<RunningProgram> left = scope .();
					defer { ClearAndDeleteItems!(left); }
					if (!Debug.IsActive)
						ProcessList.FindIn(scope $"{mDbgDir}{DbgSep}Win{DbgSep}build{DbgSep}Debug", left);
					if (!DbgWait(!Debug.IsActive && left.IsEmpty, "Stop to end the windowed program", 20))
						return false;
					SelfTestCheck(true, "debug: Stop ends the windowed program (no process of its build left)");
				}
				Debug.ClearBreakpoints();
#if BF_PLATFORM_WINDOWS
				DbgWindowedStarts();
				if (!Directory.Exists(scope $"{mDbgDir}{DbgSep}Lib"))
				{
					// a package has no fixtures folder: the library part needs TreadleCompiler/fixtures
					Notify.Log(.Info, "SelfTest", "[SELFTEST] debug: the library attach part is skipped (no fixtures folder: a package run)");
					mSelfTestStep = cDbgThreads - 1;
					return false;
				}
				if (!DbgLibraryStart())
					return DbgAbort();
				OpenProjectNow(scope $"{mDbgDir}{DbgSep}Lib", scope $"{mDbgDir}{DbgSep}Lib{DbgSep}Mathx.treadle", true);
				mSelfTestWait = 3;
				mDbgWatch.Restart();
				return false;
#else
				mSelfTestStep = cDbgThreads - 1;
				return false;
#endif
#if BF_PLATFORM_WINDOWS
			case 29:
				{
					String o = scope .();
					mDbgHost.GetOutput(o);
					if (!DbgWait(o.Contains("ready") || mDbgHost.HasExited, "the library's host to load it", 30))
						return false;
					if (!o.Contains("ready"))
					{
						SelfTestCheck(false, scope $"debug: the library's host did not start ({o})");
						return DbgAbort();
					}
				}
				let ret = DbgNode(LibMathFile, "Twice", "a3", let sheet);
				if (ret == null)
				{
					SelfTestCheck(false, "debug: node a3 of Lib.Mathx.Twice was not found");
					return DbgAbort();
				}
				OpenTab(sheet);
				Debug.ClearBreakpoints();
				Debug.AddBreakpoint(sheet.Doc.FilePath, sheet.Key, "a3");
				RefreshAttachList();
				RunningProgram host = null;
				for (let p in mAttachList)
					if (p.Pid == mDbgHostPid)
						host = p;
				SelfTestCheck(host != null && host.Module.EndsWith("MathLib.dll", .OrdinalIgnoreCase),
					scope $"debug: Attach to Process lists the C host that loaded the library ({mAttachList.Count} listed, module {(host != null) ? host.Module : "(not listed)"})");
				if (host == null)
					return DbgAbort();
				mDbgLaunchBase = DebugLaunches;
				SelfTestCheck(AttachDebugger(host.Pid, host.Path, host.Module), "debug: attach to the library's host");
				mDbgWatch.Restart();
				return false;
			case 30:
				if (!DbgWait(Debug.State == .Running || Debug.State == .Exited || Debug.IsStopped, "the attach to the host"))
					return false;
				// the host goes on: it calls fl_twice
				File.WriteAllText(scope $"{mDbgDir}{DbgSep}Host{DbgSep}go.txt", "go").IgnoreError();
				return false;
			case 31:
				if (!DbgWait(Debug.IsStopped || Debug.State == .Exited, "the stop in the library"))
					return false;
				let f = Debug.CurrentFrame;
				DebugVariable x = null;
				for (let v in Debug.Locals)
					if (v.Label == "x")
						x = v;
				SelfTestCheck(Debug.IsStopped && f != null && f.SheetName == "Lib.Mathx.Twice" && f.NodeKey == "a3",
					scope $"debug: the attached host stops in the library's exported function on a3 ({Debug.Reason}, {(f != null) ? f.SheetName : ""} {(f != null) ? f.NodeKey : ""})");
				SelfTestCheck(x != null && x.Value == "21", scope $"debug: Locals of the library's Sheet has x = {(x != null) ? x.Value : "(missing)"}");
				bool hostBelow = false;
				for (let fr in Debug.Frames)
					if (!fr.IsUser && fr.Name.StartsWith("main"))
						hostBelow = true;
				SelfTestCheck(Debug.Frames.Count >= 2 && Debug.Frames[0].IsUser && hostBelow, scope $"debug: the call stack has the library's Sheet over the host's main ({Debug.Frames.Count} frames)");
				Debug.ClearBreakpoints();
				Debug.Continue();
				return false;
			case 32:
				if (!DbgWait(mDbgHost.Done, "the library's host to exit", 30))
					return false;
				{
					String o = scope .();
					mDbgHost.GetOutput(o);
					o.Replace("\r", "");
					SelfTestCheck(mDbgHost.ExitCode == 0 && o.Contains("twice 42\n") && o.Contains("leaks 0\n"),
						scope $"debug: after Continue the host gets fl_twice(21) = 42 and exits with code {mDbgHost.ExitCode} ({o.Length} bytes of output)");
				}
				mDbgWatch.Restart();
				return false;
			case 33:
				if (!DbgWait(!Debug.IsActive, "the attached session to end", 20))
					return false;
				SelfTestCheck(Debug.State == .Exited, scope $"debug: the attached session ends with the host ({Debug.State})");
				mSelfTestStep = cDbgThreads - 1;
				return false;
#endif
			default:
				mSelfTestStep = cDbgThreads - 1;
				return false;
			}
		}

#if BF_PLATFORM_WINDOWS
		/// Compiles the host, builds the library in Debug and starts the host on it (case 28).
		bool DbgLibraryStart()
		{
			String libProj = scope $"{mDbgDir}{DbgSep}Lib";
			Treadle.Backend.Driver.BuildReport rep = scope .();
			String msgs = scope .();
			let built = SelfTestBuildOnce(libProj, "Debug", rep, msgs);
			SelfTestCheck(built && rep.ExePath.EndsWith(".dll"), scope $"debug: the library fixture builds in Debug ({rep.ExePath}){msgs}");
			if (!built)
				return false;
			String clang = scope .();
			Treadle.Language.LlvmRoot.Tool("clang", clang);
			String hostDir = scope $"{mDbgDir}{DbgSep}Host";
			String hostExe = scope $"{hostDir}{DbgSep}host.exe";
			String o = scope .();
			String e = scope .();
			let code = Treadle.Backend.Driver.RunningProcess.Run(clang, scope List<String>() { "-g", "-O0", "-o", hostExe, scope $"{hostDir}{DbgSep}host.c" }, hostDir, o, e, 120000);
			SelfTestCheck(code == 0 && File.Exists(hostExe), scope $"debug: the C host compiles (clang exit {code}{e.IsEmpty ? "" : ": "}{e})");
			if (code != 0)
				return false;
			File.Delete(scope $"{hostDir}{DbgSep}go.txt").IgnoreError();
			String dll = scope .(rep.ExePath);
			dll.Replace('/', '\\');
			DeleteAndNullify!(mDbgHost);
			mDbgHost = new .();
			if (!mDbgHost.Start(hostExe, scope List<String>() { dll, scope $"{hostDir}{DbgSep}go.txt" }, hostDir))
			{
				SelfTestCheck(false, scope $"debug: the C host did not start: {mDbgHost.Error}");
				return false;
			}
			mDbgHostPid = (int32)mDbgHost.ProcessId;
			return true;
		}

		[CRepr]
		struct DbgStartupInfo
		{
			public uint32 cb;
			public char16* lpReserved;
			public char16* lpDesktop;
			public char16* lpTitle;
			public uint32 dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
			public uint16 wShowWindow, cbReserved2;
			public uint8* lpReserved2;
			public void* hStdInput, hStdOutput, hStdError;
		}

		[CRepr]
		struct DbgProcessInfo
		{
			public void* hProcess, hThread;
			public uint32 dwProcessId, dwThreadId;
		}

		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 CreateProcessW(char16* app, char16* cmdLine, void* pa, void* ta, int32 inherit, uint32 flags, void* env, char16* dir, DbgStartupInfo* si, DbgProcessInfo* pi);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern uint32 WaitForSingleObject(void* h, uint32 ms);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 GetExitCodeProcess(void* h, uint32* code);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 CloseHandle(void* h);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern void* CreateEventW(void* sa, int32 manual, int32 initial, char16* name);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 SetEvent(void* h);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern void* CreateFileMappingW(void* file, void* sa, uint32 protect, uint32 sizeHigh, uint32 sizeLow, char16* name);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern void* MapViewOfFile(void* map, uint32 access, uint32 offHigh, uint32 offLow, uint size);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 UnmapViewOfFile(void* view);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern uint32 GetLastError();

		/// The windowed exe started outside the editor (Windows): from a command prompt whose
		/// output is a pipe (cmd /c, read back), from a command prompt in a console of its own (the
		/// console's text read back by PowerShell), and with no parent output at all (no standard
		/// handles, no console: OutputDebugStringA, read as a debug-output listener would).
		void DbgWindowedStarts()
		{
			String exe = scope .();
			DbgWinExe(exe);
			String dir = scope $"{mDbgDir}{DbgSep}Win";
			// 1. cmd /c with its output on a pipe
			{
				String o = scope .();
				String e = scope .();
				let code = Treadle.Backend.Driver.RunningProcess.Run("cmd.exe", scope List<String>() { "/c", exe }, dir, o, e, 30000);
				o.Replace("\r", "");
				SelfTestCheck(code == 0 && o == M1Output, scope $"debug: the windowed exe started by cmd /c writes its output to cmd's pipe (exit {code}, '{o}')");
			}
			// 2. a command prompt with a console (no window): PowerShell starts cmd /c <exe> in its
			//    console and writes the console's text to a file
			{
				String script = scope $"{mDbgDir}{DbgSep}Host{DbgSep}console.ps1";
				String capture = scope $"{mDbgDir}{DbgSep}Host{DbgSep}console-text.txt";
				Directory.CreateDirectory(scope $"{mDbgDir}{DbgSep}Host").IgnoreError();
				File.WriteAllText(script, """
					param($exe, $out)
					Start-Process -FilePath cmd.exe -ArgumentList '/c', "`"$exe`"" -NoNewWindow -Wait
					Start-Sleep -Milliseconds 500
					$w = $host.UI.RawUI.BufferSize.Width
					$r = New-Object System.Management.Automation.Host.Rectangle 0, 0, ($w - 1), 40
					$b = $host.UI.RawUI.GetBufferContents($r)
					$lines = @()
					for ($y = 0; $y -le 40; $y++) { $s = ''; for ($x = 0; $x -lt $w; $x++) { $s += $b[$y, $x].Character }; $s = $s.TrimEnd(); if ($s -ne '') { $lines += $s } }
					$lines | Set-Content $out
					""").IgnoreError();
				File.Delete(capture).IgnoreError();
				ProcessStartInfo psi = scope .();
				psi.SetFileName("powershell.exe");
				String args = scope .();
				args.AppendF("-NoProfile -ExecutionPolicy Bypass -File \"{}\" \"{}\" \"{}\"", script, exe, capture);
				psi.SetArguments(args);
				psi.UseShellExecute = false;
				psi.CreateNoWindow = true;
				SpawnedProcess p = scope .();
				bool ran = false;
				if (p.Start(psi) case .Ok)
					ran = p.WaitFor(60000);
				if (!ran)
					p.Kill();
				String text = scope .();
				File.ReadAllText(capture, text, true).IgnoreError();
				text.Replace("\r", "");
				SelfTestCheck(ran && text.Contains(M1Output), scope $"debug: the windowed exe started from a command prompt writes to that console ('{text}')");
			}
			// 3. no parent output: no standard handles and a parent (the editor) with no console
			{
				// the debug-output buffer (DBWIN_BUFFER); when another listener holds it (DebugView,
				// a debugger) the text is not checked
				void* ready = CreateEventW(null, 0, 0, "DBWIN_BUFFER_READY".ToScopedNativeWChar!());
				let readyTaken = GetLastError() == 183;
				void* data = CreateEventW(null, 0, 0, "DBWIN_DATA_READY".ToScopedNativeWChar!());
				void* map = CreateFileMappingW((void*)(int)(-1), null, 4, 0, 4096, "DBWIN_BUFFER".ToScopedNativeWChar!());
				let mapTaken = GetLastError() == 183;
				uint8* view = (map != null) ? (uint8*)MapViewOfFile(map, 4, 0, 0, 0) : null;
				let listening = ready != null && data != null && view != null && !readyTaken && !mapTaken;
				DbgStartupInfo si = default;
				si.cb = (uint32)sizeof(DbgStartupInfo);
				si.dwFlags = 0x100; // STARTF_USESTDHANDLES, all three null
				DbgProcessInfo pi = default;
				String cmd = scope $"\"{exe}\"";
				String text = scope .();
				uint32 code = 1234;
				bool exited = false;
				if (CreateProcessW(null, cmd.ToScopedNativeWChar!(), null, null, 0, 0, null, dir.ToScopedNativeWChar!(), &si, &pi) != 0)
				{
					let watch = scope Stopwatch(true);
					int afterExit = 0;
					while (watch.ElapsedMilliseconds < 30000 && afterExit < 5)
					{
						if (listening)
						{
							SetEvent(ready);
							if (WaitForSingleObject(data, 50) == 0 && *(uint32*)view == pi.dwProcessId)
								text.Append((char8*)(view + 4));
						}
						else
							Thread.Sleep(50);
						if (WaitForSingleObject(pi.hProcess, 0) == 0)
						{
							exited = true;
							afterExit++;
						}
					}
					if (!exited)
					{
						SelfTestCheck(false, "debug: the windowed exe with no parent output did not end in 30 s");
					}
					GetExitCodeProcess(pi.hProcess, &code);
					CloseHandle(pi.hThread);
					CloseHandle(pi.hProcess);
				}
				if (view != null)
					UnmapViewOfFile(view);
				if (map != null)
					CloseHandle(map);
				if (data != null)
					CloseHandle(data);
				if (ready != null)
					CloseHandle(ready);
				text.Replace("\r", "");
				SelfTestCheck(exited && code == 0, scope $"debug: the windowed exe with no parent output (no handles, no console) runs to its end, exit code {code}");
				if (listening)
					SelfTestCheck(text.Contains(M1Output), scope $"debug: its Console output goes to OutputDebugStringA ('{text}')");
				else
					Notify.Log(.Info, "SelfTest", "debug: another debug-output listener holds DBWIN_BUFFER; the OutputDebugStringA text is not checked");
			}
		}
#endif
	}
}
#endif
