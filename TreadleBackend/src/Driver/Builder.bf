using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using Treadle.Backend.IR;
using Treadle.Backend.Emit;

namespace Treadle.Backend.Driver
{
	/// Where the LLVM toolchain is (docs/Toolchain.md): Treadle.Language.LlvmRoot (Windows:
	/// TREADLE_LLVM, else tools/llvm-mingw of the repository;
	/// Linux: TREADLE_LLVM, else the distribution's LLVM).
	static class ToolchainPaths
	{
		public static void Root(String outRoot)
		{
			Treadle.Language.LlvmRoot.Get(outRoot);
		}

		/// `name` without extension ("clang", "lldb"): the platform's executable suffix is added.
		public static void Tool(StringView name, String outPath)
		{
			Treadle.Language.LlvmRoot.Tool(name, outPath);
		}

		public static bool Found
		{
			get
			{
				String clang = scope .();
				Tool("clang", clang);
				return File.Exists(clang);
			}
		}
	}

	/// The runtime's C source: tools/runtime above the running exe (a source tree) or
	/// TREADLE_RUNTIME (a folder), else the copy compiled into this library.
	static class RuntimeSource
	{
		[Comptime(ConstEval=true)]
		static String Embed(String name)
		{
			String path = scope .();
			path.AppendF("{}/../tools/runtime/{}", Compiler.ProjectDir, name);
			String data = scope .();
			File.ReadAllText(path, data);
			return data;
		}

		public const String EmbeddedC = Embed("treadle_rt.c");
		public const String EmbeddedH = Embed("treadle_rt.h");

		/// Fills the C file and the header; `outFrom` says where they came from.
		public static void Get(String outC, String outH, String outFrom)
		{
			String dir = scope .();
			if (Environment.GetEnvironmentVariable("TREADLE_RUNTIME", dir) case .Ok && File.Exists(scope $"{dir}/treadle_rt.c"))
			{
				if (File.ReadAllText(scope $"{dir}/treadle_rt.c", outC) case .Ok && File.ReadAllText(scope $"{dir}/treadle_rt.h", outH) case .Ok)
				{
					outFrom.Set(dir);
					return;
				}
				outC.Clear();
				outH.Clear();
			}
			// tools/runtime beside the exe (a package), else the source tree of a development build
			// (Treadle.Language.ToolDirs: the fixed build layout, no walk up the parent folders)
			String found = scope .();
			if (Treadle.Language.ToolDirs.Find("tools/runtime", "tools/runtime/treadle_rt.c", found))
			{
				if (File.ReadAllText(scope $"{found}/treadle_rt.c", outC) case .Ok && File.ReadAllText(scope $"{found}/treadle_rt.h", outH) case .Ok)
				{
					outFrom.Set(found);
					return;
				}
				outC.Clear();
				outH.Clear();
			}
			outC.Set(EmbeddedC);
			outH.Set(EmbeddedH);
			outFrom.Set("built in");
		}
	}

	/// The debug info a build writes (a project config's `debugFormat`, docs/Compiler.md 7).
	enum DebugFormat
	{
		/// DWARF only (the default): lldb and lldb-dap.
		case Dwarf;
		/// CodeView only, in `<Name>.pdb` next to the exe (Windows): Visual Studio, WinDbg and other
		/// PDB readers; lldb reads it through `target symbols add` (the debugger does that itself).
		case CodeView;
		/// DWARF in the exe and CodeView in the PDB: lldb keeps working, PDB readers work too.
		case Both;

		/// `dwarf`, `codeview` or `both` (any case); "" is `dwarf`. False for anything else.
		public static bool Parse(StringView text, out DebugFormat outFormat)
		{
			outFormat = .Dwarf;
			if (text.IsEmpty || text.Equals("dwarf", true))
				return true;
			if (text.Equals("codeview", true))
			{
				outFormat = .CodeView;
				return true;
			}
			if (text.Equals("both", true))
			{
				outFormat = .Both;
				return true;
			}
			return false;
		}

		public StringView Text => (this == .CodeView) ? "codeview" : (this == .Both) ? "both" : "dwarf";
	}

	class BuildOptions
	{
		/// The folder of this configuration's outputs: `<project>/build/<Config>`.
		public String OutDir = new .() ~ delete _;
		/// The program's file name without extension.
		public String Name = new .("Program") ~ delete _;
		/// `checks on`: the Debug runtime (`TREADLE_DEBUG`: allocation tracking, the leak report),
		/// the emitted null / bounds / use-after-free checks and full DWARF.
		public bool Checks = true;
		/// clang's `-O` level: `0`, `1`, `2`, `3` or `s`.
		public String Optimize = new .("0") ~ delete _;
		/// `-g` and no stripping (else line tables only and `-s`).
		public bool DebugInfo = true;
		/// What the link makes: a console exe, a windowed exe (the Windows subsystem) or a library.
		public IRProgramKind Kind;
		/// The settings line of the project's config (BuildSettings.Stamp, the `define`s included):
		/// part of the link stamp. "" for a build without a project file.
		public String Settings = new .() ~ delete _;
		/// A library's `[Export]` names (IRFunction.ExportName): the Linux version script, the link stamp.
		public List<String> Exports = new .() ~ DeleteContainerAndItems!(_);

		public bool Optimized => Optimize != "0";
		/// The config's `simd` level (SIMD-and-Vectors.md 1.7): `x86-64`, `x86-64-v2` (the default),
		/// `x86-64-v3`, `x86-64-v4` or `native`; every function's `"target-cpu"` and the runtime's `-march`.
		public String TargetCpu = new .("x86-64-v2") ~ delete _;

		/// Kind and exports from the program.
		public void SetProgram(IRProgram program)
		{
			Kind = program.Kind;
			ClearAndDeleteItems!(Exports);
			for (let f in program.Functions)
				if (f.ExportName != null && f.HasBody)
					Exports.Add(new .(f.ExportName));
			Exports.Sort(scope (a, b) => String.Compare(a, b, false));
		}

		/// The defaults of a config name without a project file: `Release` (any case) is `optimize 2`,
		/// `checks off`, no debug info; any other name `optimize 0`, `checks on`, debug info.
		public void SetConfigDefaults(StringView config)
		{
			let release = config.Equals("Release", true);
			Checks = !release;
			Optimize.Set(release ? "2" : "0");
			DebugInfo = !release;
		}
		/// CodeView needs a COFF target: on Linux `codeview` and `both` build DWARF only.
		public DebugFormat DebugFormat;
#if BF_PLATFORM_WINDOWS
		public DebugFormat EffectiveDebugFormat => DebugFormat;
#else
		public DebugFormat EffectiveDebugFormat => .Dwarf;
#endif
		public bool WritesCodeView => EffectiveDebugFormat != .Dwarf;
		/// Recompile every unit and the runtime.
		public bool Force;
		/// Parallel clang processes (0 = the core count).
		public int Jobs;
		/// Extra link inputs (libraries: a bare name becomes -l<name>).
		public List<String> Libs = new .() ~ DeleteContainerAndItems!(_);
		/// The program's input stamps (IRProgram.InputStamps): part of the link stamp.
		public List<String> Inputs = new .() ~ DeleteContainerAndItems!(_);
		/// Set (by another thread) to stop the build: no new clang starts, running ones are killed,
		/// Build returns false. Null: not cancellable.
		public bool* Cancel;
		public bool Cancelled => Cancel != null && *Cancel;
	}

	/// What a build did, for the Output Log and the timing report.
	class BuildReport
	{
		public bool Succeeded;
		public String ExePath = new .() ~ delete _;
		/// Lines for the Output Log (the commands, tool output, the timing report).
		public List<String> Log = new .() ~ DeleteContainerAndItems!(_);
		/// Errors: IR problems ("line N: ..."), clang / lld messages.
		public List<String> Errors = new .() ~ DeleteContainerAndItems!(_);
		public int UnitsCompiled;
		public int UnitsCached;
		public bool RuntimeCompiled;
		public bool Linked;
		public double EmitMs;
		public double CompileMs;
		public double RuntimeMs;
		public double LinkMs;
		public double TotalMs;

		public void AddLog(StringView line) => Log.Add(new .(line));
		public void AddError(StringView line) => Errors.Add(new .(line));

		/// "12.3": milliseconds with one decimal by integer arithmetic. The report is made on build and
		/// self-test threads; corlib's floating-point formatting (NumberFormatter with the shared
		/// CultureInfo) crashed there once while the UI thread formatted too, so no double is formatted.
		static void Ms(double ms, String outText)
		{
			let tenths = (int64)Math.Round(Math.Max(ms, 0) * 10);
			outText.AppendF("{}.{}", tenths / 10, tenths % 10);
		}

		public void Timing(String outText)
		{
			String emit = scope .(); Ms(EmitMs, emit);
			String comp = scope .(); Ms(CompileMs, comp);
			String rt = scope .(); Ms(RuntimeMs, rt);
			String link = scope .(); Ms(LinkMs, link);
			String total = scope .(); Ms(TotalMs, total);
			StringView plural = (UnitsCompiled == 1) ? "" : "s";
			StringView rtState = RuntimeCompiled ? "compiled" : "cached";
			StringView linkState = Linked ? "ran" : "skipped";
			outText.AppendF("Back end: emit {} ms, clang {} unit{} ({} cached) {} ms, runtime {} {} ms, link {} {} ms, total {} ms",
				emit, UnitsCompiled, plural, UnitsCached, comp, rtState, rt, linkState, link, total);
		}
	}

	/// Emits a program's units, compiles the stale ones with clang (in parallel), the runtime once
	/// per configuration, and links with lld through clang (the flags of scripts\llbuild.ps1).
	static class Builder
	{
		/// Written next to the exe by each link: the debug format it was linked with (`dwarf`,
		/// `codeview` or `both`); the debugger reads it (TreadleDebug, LldbDapAdapter).
		public const String DebugFormatFile = "debug-format.txt";
#if BF_PLATFORM_WINDOWS
		public const String Target = "--target=x86_64-w64-windows-gnu";
		/// The program file's extension.
		public const String ExeExtension = ".exe";
#else
		public const String Target = "--target=x86_64-pc-linux-gnu";
		public const String ExeExtension = "";
#endif

		static bool WriteIfChanged(StringView path, StringView text, out bool changed)
		{
			changed = true;
			String old = scope .();
			if (File.ReadAllText(path, old, true) case .Ok && old == text)
			{
				changed = false;
				return true;
			}
			return File.WriteAllText(path, text) case .Ok;
		}

		/// The file the link writes: `<Name>.exe` / `<Name>` for a program, `<Name>.dll` /
		/// `lib<Name>.so` for a library.
		public static void OutputFile(BuildOptions opts, String outPath)
		{
#if BF_PLATFORM_WINDOWS
			outPath.AppendF("{}/{}{}", opts.OutDir, opts.Name, (opts.Kind == .Library) ? ".dll" : ExeExtension);
#else
			if (opts.Kind == .Library)
				outPath.AppendF("{}/lib{}.so", opts.OutDir, opts.Name);
			else
				outPath.AppendF("{}/{}{}", opts.OutDir, opts.Name, ExeExtension);
#endif
		}

		/// The import library of a Windows library build (`<Name>.dll.a`, what a C program links
		/// against); "" on Linux, where the `.so` itself is linked.
		public static void ImportLibrary(BuildOptions opts, String outPath)
		{
#if BF_PLATFORM_WINDOWS
			if (opts.Kind == .Library)
				outPath.AppendF("{}/{}.dll.a", opts.OutDir, opts.Name);
#endif
		}

		static void CompileFlags(BuildOptions opts, List<String> outArgs)
		{
			outArgs.Add(new .(Target));
			outArgs.Add(new .("-c"));
			outArgs.Add(new $"-O{opts.Optimize}");
			if (opts.DebugInfo)
				outArgs.Add(new .("-g"));
			if (opts.Optimized)
			{
				outArgs.Add(new .("-ffunction-sections"));
				outArgs.Add(new .("-fdata-sections"));
				outArgs.Add(new .("-flto=thin")); // ThinLTO: bitcode objects, lld inlines across units, one thread per core (Compiler.md 6)
			}
#if !BF_PLATFORM_WINDOWS
			// a shared object needs position-independent code (a program links as a PIE)
			if (opts.Kind == .Library)
				outArgs.Add(new .("-fPIC"));
#endif
		}

		static void JoinArgs(List<String> args, String outText)
		{
			for (let a in args)
				outText.AppendF("{} ", a);
		}

		/// Turns clang's "file:line:col: error: text" lines into error messages.
		public static void ParseToolErrors(StringView output, List<String> outErrors)
		{
			for (var line in output.Split('\n'))
			{
				line.Trim();
				if (line.Contains(": error:") || line.Contains("error:") && line.StartsWith("clang") || line.Contains("ld.lld: error") || line.Contains("lld: error"))
					outErrors.Add(new .(line));
			}
		}

		public static bool Build(IRProgram program, BuildOptions opts, BuildReport report)
		{
			let total = scope Stopwatch(true);
			defer { report.TotalMs = total.Elapsed.TotalMilliseconds; }
			String clang = scope .();
			ToolchainPaths.Tool("clang", clang);
			if (!File.Exists(clang))
			{
				String root = scope .();
				ToolchainPaths.Root(root);
#if BF_PLATFORM_WINDOWS
				String env = scope .();
				if (Environment.GetEnvironmentVariable("TREADLE_LLVM", env) case .Ok && !env.IsEmpty)
					report.AddError(scope $"clang was not found at {clang} (TREADLE_LLVM={env}). Set TREADLE_LLVM to the llvm-mingw root (docs/Toolchain.md).");
				else
				{
					String why = scope .();
					Treadle.Language.ToolDirs.Missing("clang", "tools/llvm/bin/clang.exe", "tools/llvm-mingw/bin/clang.exe", "TREADLE_LLVM", why);
					report.AddError(scope $"{why} (the llvm-mingw root; docs/Toolchain.md).");
				}
#else
				report.AddError(scope $"clang was not found at {clang}. Install clang and lld (docs/Linux.md) or set TREADLE_LLVM to an LLVM root.");
#endif
				return false;
			}
			if (Directory.CreateDirectory(opts.OutDir) case .Err && !Directory.Exists(opts.OutDir))
			{
				report.AddError(scope $"cannot create {opts.OutDir}");
				return false;
			}
			String objDir = scope $"{opts.OutDir}/obj";
			Directory.CreateDirectory(objDir).IgnoreError();

			// 1. emit
			let sw = scope Stopwatch(true);
			EmitOptions eo = scope .();
			eo.Debug = opts.Checks;
			eo.Optimized = opts.Optimized;
			eo.Dwarf = opts.EffectiveDebugFormat != .CodeView;
			eo.CodeView = opts.WritesCodeView;
			eo.ListingDir.Set(opts.OutDir);
			if (!SimdTarget.Resolve(clang, opts.TargetCpu, eo.TargetCpu, eo.TargetFeatures, report)) // SimdTarget.bf: `native` asks clang
				return false;
			Emitter emitter = scope .(program, eo);
			List<UnitOutput> units = scope .();
			defer { ClearAndDeleteItems!(units); }
			List<String> emitErrors = scope .();
			defer { ClearAndDeleteItems!(emitErrors); }
			if (!emitter.Emit(units, emitErrors))
			{
				for (let e in emitErrors)
					report.AddError(e);
				return false;
			}
			if (!KernelBuild.AddGpuUnit(program, emitter, clang, opts, units, report)) // EmitKernelBuild.bf: the [Kernel] functions' PTX
				return false;
			List<String> stale = scope .();
			defer { ClearAndDeleteItems!(stale); }
			List<String> objects = scope .();
			defer { ClearAndDeleteItems!(objects); }
			// the units' clang flags (the config's optimize level and debug info): a change, such as
			// `optimize 1` -> `2` in the same config, compiles every unit again
			String unitFlags = scope .();
			{
				List<String> fl = scope .();
				defer { ClearAndDeleteItems!(fl); }
				CompileFlags(opts, fl);
				unitFlags.AppendF("{}\n", clang);
				JoinArgs(fl, unitFlags);
			}
			String oldFlags = scope .();
			let flagsChanged = !(File.ReadAllText(scope $"{objDir}/flags.txt", oldFlags, true) case .Ok) || oldFlags != unitFlags;
			// written again once every unit compiled (a cancelled or failed build leaves none: all stale)
			if (flagsChanged)
				File.Delete(scope $"{objDir}/flags.txt").IgnoreError();
			for (let u in units)
			{
				String ll = scope $"{opts.OutDir}/{u.Name}.ll";
				String o = scope $"{objDir}/{u.Name}.o";
				WriteIfChanged(ll, u.LL, var changed);
				WriteIfChanged(scope $"{opts.OutDir}/{u.Name}.lst", u.Listing, ?);
				WriteIfChanged(scope $"{opts.OutDir}/{u.Name}.nodemap", u.NodeMap, ?);
				if (changed || flagsChanged || opts.Force || !File.Exists(o))
					stale.Add(new .(u.Name));
				else
					report.UnitsCached++;
				objects.Add(new .(o));
			}
			report.EmitMs = sw.Elapsed.TotalMilliseconds;
			if (opts.Cancelled)
			{
				report.AddLog("build cancelled");
				return false;
			}

			// 3a. the runtime, once per configuration: cached by its source and flags in the project
			// and in a per-user cache (so a new project reuses it); when it must be compiled, its
			// clang runs alongside the units' (step 2).
			let rtWatch = scope Stopwatch(true);
			String rtDir = scope $"{opts.OutDir}/runtime";
			Directory.CreateDirectory(rtDir).IgnoreError();
			String rtC = scope .();
			String rtH = scope .();
			String rtFrom = scope .();
			RuntimeSource.Get(rtC, rtH, rtFrom);
			KernelBuild.AppendGpuRuntime(rtC, rtFrom); // EmitKernelBuild.bf: tools/runtime/treadle_gpu.c
			String rtObj = scope $"{rtDir}/treadle_rt.o";
			// the runtime's flags: the config's optimize level and debug info, the Debug runtime
			// (TREADLE_DEBUG) when checks are on; a build with debug info and CodeView compiles the
			// runtime with CodeView too (the PDB covers it)
			let rtCodeView = opts.DebugInfo && opts.WritesCodeView;
			List<String> rtArgs = scope .();
			defer { ClearAndDeleteItems!(rtArgs); }
			CompileFlags(opts, rtArgs);
			if (rtCodeView)
			{
				rtArgs.Add(new .("-gcodeview"));
				if (opts.EffectiveDebugFormat == .Both)
					rtArgs.Add(new .("-gdwarf"));
			}
			rtArgs.Add(new $"-march={opts.TargetCpu}"); // the `simd` level: in the runtime's stamp and cache key
			rtArgs.Add(new .("-std=c11"));
			rtArgs.Add(new .("-Wall"));
			rtArgs.Add(new .(opts.Checks ? "-DTREADLE_DEBUG=1" : "-DNDEBUG"));
			String stamp = scope .();
			stamp.AppendF("{}\n", clang);
			JoinArgs(rtArgs, stamp);
			stamp.AppendF("\n{:X8}\n{:X8}\n", Mangler.Fnv1a(rtC), Mangler.Fnv1a(rtH));
			String oldStamp = scope .();
			let rtStale = opts.Force || !File.Exists(rtObj) || !(File.ReadAllText(scope $"{rtDir}/stamp.txt", oldStamp, true) case .Ok) || oldStamp != stamp;
			String cacheObj = scope .();
			RuntimeCacheObject(stamp, opts.Checks, cacheObj);
			RunningProcess rtProc = null;
			defer { delete rtProc; }
			if (rtStale && !opts.Force && !cacheObj.IsEmpty && File.Exists(cacheObj) && (File.Copy(cacheObj, rtObj) case .Ok))
			{
				File.WriteAllText(scope $"{rtDir}/stamp.txt", stamp).IgnoreError();
				report.AddLog(scope $"runtime ({rtFrom}): from the cache {cacheObj}");
			}
			else if (rtStale)
			{
				File.WriteAllText(scope $"{rtDir}/treadle_rt.c", rtC).IgnoreError();
				File.WriteAllText(scope $"{rtDir}/treadle_rt.h", rtH).IgnoreError();
				List<String> args = scope .();
				defer { ClearAndDeleteItems!(args); }
				for (let a in rtArgs)
					args.Add(new .(a));
				args.Add(new $"{rtDir}/treadle_rt.c");
				args.Add(new .("-o"));
				args.Add(new .(rtObj));
				rtProc = new .();
				if (!rtProc.Start(clang, args, rtDir))
				{
					report.AddError("could not start clang for the runtime");
					return false;
				}
			}
			let rtStartMs = rtWatch.Elapsed.TotalMilliseconds;

			// 2. clang -c per stale unit, in parallel
			sw.Restart();
			int jobs = opts.Jobs;
			if (jobs <= 0)
				jobs = Math.Max(1, (int)Platform.BfpSystem_GetNumLogicalCPUs(null));
			List<RunningProcess> running = scope .();
			defer { ClearAndDeleteItems!(running); }
			List<String> runningUnit = scope .();
			defer { ClearAndDeleteItems!(runningUnit); }
			int next = 0;
			bool failed = false;
			while (next < stale.Count || !running.IsEmpty)
			{
				if (opts.Cancelled)
				{
					// stop: kill the units' clang (their objects are not complete) and the runtime's
					for (let p in running)
					{
						p.Kill();
						p.Wait();
					}
					for (let name in runningUnit)
						File.Delete(scope $"{objDir}/{name}.o").IgnoreError();
					if (rtProc != null)
					{
						rtProc.Kill();
						rtProc.Wait();
						File.Delete(rtObj).IgnoreError();
					}
					report.AddLog("build cancelled");
					return false;
				}
				while (next < stale.Count && running.Count < jobs)
				{
					let name = stale[next++];
					List<String> args = scope .();
					defer { ClearAndDeleteItems!(args); }
					CompileFlags(opts, args);
					args.Add(new $"{opts.OutDir}/{name}.ll");
					args.Add(new .("-o"));
					args.Add(new $"{objDir}/{name}.o");
					RunningProcess p = new .();
					if (!p.Start(clang, args, opts.OutDir))
					{
						report.AddError(scope $"could not start clang for {name}");
						delete p;
						failed = true;
						continue;
					}
					report.AddLog(scope $"> {p.CommandLine}");
					running.Add(p);
					runningUnit.Add(new .(name));
				}
				for (int i = running.Count - 1; i >= 0; i--)
				{
					let p = running[i];
					if (!p.Done)
						continue;
					String err = scope .();
					p.GetErrors(err);
					String outText = scope .();
					p.GetOutput(outText);
					for (var line in outText.Split('\n'))
						if (!line.IsEmpty)
							report.AddLog(line);
					for (var line in err.Split('\n'))
						if (!line.IsEmpty)
							report.AddLog(line);
					if (p.ExitCode != 0)
					{
						failed = true;
						report.AddError(scope $"clang failed on {runningUnit[i]}.ll (exit code {p.ExitCode}); the .ll is kept for inspection:");
						ParseToolErrors(err, report.Errors);
						// a failed unit must not look up to date next time
						File.Delete(scope $"{objDir}/{runningUnit[i]}.o").IgnoreError();
					}
					else
						report.UnitsCompiled++;
					delete p;
					running.RemoveAt(i);
					delete runningUnit[i];
					runningUnit.RemoveAt(i);
				}
				if (!running.IsEmpty)
					System.Threading.Thread.Sleep(1);
			}
			report.CompileMs = sw.Elapsed.TotalMilliseconds;

			// 3b. the runtime's clang (started before the units')
			let rtWaitStart = rtWatch.Elapsed.TotalMilliseconds;
			if (rtProc != null)
			{
				rtProc.Wait();
				String e = scope .();
				rtProc.GetErrors(e);
				let code = rtProc.ExitCode;
				report.AddLog(scope $"> {rtProc.CommandLine}");
				report.AddLog(scope $"runtime ({rtFrom}): clang exit {code}");
				for (var line in e.Split('\n'))
					if (!line.IsEmpty)
						report.AddLog(line);
				if (code != 0)
				{
					report.AddError(scope $"the runtime did not compile (exit code {code})");
					ParseToolErrors(e, report.Errors);
					File.Delete(rtObj).IgnoreError();
					return false;
				}
				File.WriteAllText(scope $"{rtDir}/stamp.txt", stamp).IgnoreError();
				report.RuntimeCompiled = true;
				if (!cacheObj.IsEmpty)
				{
					String cacheDir = scope .();
					Path.GetDirectoryPath(cacheObj, cacheDir).IgnoreError();
					Directory.CreateDirectory(cacheDir).IgnoreError();
					// a whole file or none: another build may be reading the cache
					String tmp = scope $"{cacheObj}.{Platform.BfpSystem_GetTimeStamp()}.tmp";
					if (File.Copy(rtObj, tmp) case .Ok && (File.Move(tmp, cacheObj) case .Err))
						File.Delete(tmp).IgnoreError();
				}
			}
			// what the runtime added to the build: its start, and the wait after the units
			report.RuntimeMs = rtStartMs + (rtWatch.Elapsed.TotalMilliseconds - rtWaitStart);
			if (failed)
				return false;
			if (opts.Cancelled)
			{
				report.AddLog("build cancelled");
				return false;
			}
			if (flagsChanged)
				File.WriteAllText(scope $"{objDir}/flags.txt", unitFlags).IgnoreError();
			sw.Restart();

			// 4. link (when an object changed or the exe is missing)
			sw.Restart();
			OutputFile(opts, report.ExePath..Clear());
			let needLink = opts.Force || report.UnitsCompiled > 0 || rtStale || !File.Exists(report.ExePath) || LinkStampChanged(opts, objects);
			if (needLink)
			{
				List<String> args = scope .();
				defer { ClearAndDeleteItems!(args); }
				args.Add(new .(Target));
#if BF_PLATFORM_WINDOWS
				args.Add(new .("-static"));
				switch (opts.Kind)
				{
				case .Console: args.Add(new .("-mconsole"));
				case .Windowed: args.Add(new .("-mwindows"));
				case .Library:
					// a DLL whose exports are the `dllexport` functions (the [Export] wrappers and
					// treadle_init / treadle_shutdown) and nothing else: with any dllexport in the
					// objects lld exports no other symbol; the import library is for C programs
					args.Add(new .("-shared"));
					String implib = scope .();
					ImportLibrary(opts, implib);
					args.Add(new $"-Wl,--out-implib,{implib}");
				}
				if (!opts.Optimized && opts.Kind != .Library)
					args.Add(new .("-Wl,--stack,8388608")); // 8 MB main stack for -O0 programs (larger frames: Compiler.md, Stack in Debug)
#else
				// a PIE against the system's glibc (dynamically: a static glibc is not supported);
				// the runtime's tables are bounded by __start_ / __stop_ symbols, which must keep
				// their sections under --gc-sections
				args.Add(new .("-fuse-ld=lld"));
				args.Add(new .("-Wl,-z,nostart-stop-gc"));
				if (opts.Kind == .Library)
				{
					// a shared object exporting exactly the [Export] names and treadle_init /
					// treadle_shutdown (a version script hides the rest)
					String map = scope $"{opts.OutDir}/exports.map";
					String text = scope .("{\n  global:\n    treadle_init;\n    treadle_shutdown;\n");
					for (let x in opts.Exports)
						text.AppendF("    {};\n", x);
					text.Append("  local: *;\n};\n");
					File.WriteAllText(map, text).IgnoreError();
					args.Add(new .("-shared"));
					args.Add(new .("-fPIC"));
					args.Add(new $"-Wl,--version-script={map}");
				}
#endif
				if (opts.DebugInfo)
					args.Add(new .("-g"));
				else
					args.Add(new .("-s"));
				if (opts.Optimized)
				{
					args.Add(new $"-O{opts.Optimize}");
					args.Add(new .("-Wl,--gc-sections"));
				}
				args.Add(new $"-march={opts.TargetCpu}"); // the `simd` level for C sources compiled at the link
				// CodeView: lld writes `<Name>.pdb` next to the exe (its path is recorded in the exe). With
				// a PDB lld leaves out the exe's COFF symbol table, where lldb finds the names of
				// functions without debug info (the C `main` the back end emits): Debug keeps it
				// (`-debug:symtab`, which also keeps the DWARF of a `both` build)
				String pdb = scope $"{opts.OutDir}/{opts.Name}.pdb";
				if (opts.WritesCodeView)
				{
					args.Add(new .("-gcodeview"));
					args.Add(new $"-Wl,--pdb={pdb}");
					if (opts.DebugInfo)
						args.Add(new .("-Wl,-Xlink=-debug:symtab"));
				}
				for (let o in objects)
					args.Add(new .(o));
				args.Add(new .(rtObj));
				args.Add(new .("-o"));
				args.Add(new .(report.ExePath));
				for (let l in opts.Libs)
				{
					if (l.EndsWith(".a") || l.EndsWith(".lib") || l.Contains('/') || l.Contains('\\'))
						args.Add(new .(l));
					else
						args.Add(new $"-l{l}");
				}
#if !BF_PLATFORM_WINDOWS
				// libm is a library of its own on Linux (the mingw C runtime has it in msvcrt)
				args.Add(new .("-lm"));
#endif
				String o = scope .();
				String e = scope .();
				RunningProcess p = scope .();
				if (!p.Start(clang, args, opts.OutDir))
				{
					report.AddError("could not start the linker");
					return false;
				}
				report.AddLog(scope $"> {p.CommandLine}");
				p.Wait();
				p.GetOutput(o);
				p.GetErrors(e);
				for (var line in e.Split('\n'))
					if (!line.IsEmpty)
						report.AddLog(line);
				if (p.ExitCode != 0)
				{
					report.AddError(scope $"link failed (exit code {p.ExitCode})");
					ParseToolErrors(e, report.Errors);
					File.Delete(scope $"{opts.OutDir}/link.stamp").IgnoreError();
					return false;
				}
				// a DWARF build leaves no PDB of an earlier CodeView build behind (it would not match)
				if (!opts.WritesCodeView && File.Exists(pdb))
					File.Delete(pdb).IgnoreError();
				WriteLinkStamp(opts, objects);
				File.WriteAllText(scope $"{opts.OutDir}/{DebugFormatFile}", opts.EffectiveDebugFormat.Text).IgnoreError();
				report.Linked = true;
			}
			report.LinkMs = sw.Elapsed.TotalMilliseconds;
			report.Succeeded = true;
			report.TotalMs = total.Elapsed.TotalMilliseconds;
			String timing = scope .();
			report.Timing(timing);
			report.AddLog(timing);
			return true;
		}

		/// The per-user copy of a compiled runtime for this stamp:
		/// `%LOCALAPPDATA%/Treadle/cache/runtime/<Config>-<hash>/treadle_rt.o` ("" without LOCALAPPDATA;
		/// TREADLE_RUNTIME_CACHE=0 turns it off).
		static void RuntimeCacheObject(StringView stamp, bool debug, String outPath)
		{
			String off = scope .();
			if (Environment.GetEnvironmentVariable("TREADLE_RUNTIME_CACHE", off) case .Ok && off == "0")
				return;
			String root = scope .();
#if BF_PLATFORM_WINDOWS
			if (Environment.GetEnvironmentVariable("LOCALAPPDATA", root) case .Err || root.IsEmpty)
				return;
			outPath.AppendF("{}/Treadle/cache/runtime/{}-{:X8}/treadle_rt.o", root, debug ? "Debug" : "Release", Mangler.Fnv1a(stamp));
#else
			// $XDG_CACHE_HOME/treadle (an absolute value only), else ~/.cache/treadle
			if (!(Environment.GetEnvironmentVariable("XDG_CACHE_HOME", root) case .Ok) || !root.StartsWith('/'))
			{
				root.Clear();
				if (Environment.GetEnvironmentVariable("HOME", root) case .Err || root.IsEmpty)
					return;
				root.Append("/.cache");
			}
			outPath.AppendF("{}/treadle/runtime/{}-{:X8}/treadle_rt.o", root, debug ? "Debug" : "Release", Mangler.Fnv1a(stamp));
#endif
		}

		static void LinkStamp(BuildOptions opts, List<String> objects, String outText)
		{
			// the kind, the config's flags (its `define`s too, in Settings) and the exports: a change
			// of any of them links again
			outText.AppendF("{} {} checks {} O{} debuginfo {} {}\n{}\n", opts.Name, opts.Kind, opts.Checks, opts.Optimize, opts.DebugInfo, opts.EffectiveDebugFormat.Text, opts.Settings);
			for (let x in opts.Exports)
				outText.AppendF("export {}\n", x);
			for (let o in objects)
				outText.AppendF("{}\n", o);
			for (let l in opts.Libs)
				outText.AppendF("lib {}\n", l);
			for (let i in opts.Inputs)
				outText.AppendF("input {}\n", i);
		}

		static bool LinkStampChanged(BuildOptions opts, List<String> objects)
		{
			String now = scope .();
			LinkStamp(opts, objects, now);
			String old = scope .();
			if (File.ReadAllText(scope $"{opts.OutDir}/link.stamp", old, true) case .Err)
				return true;
			return old != now;
		}

		static void WriteLinkStamp(BuildOptions opts, List<String> objects)
		{
			String now = scope .();
			LinkStamp(opts, objects, now);
			File.WriteAllText(scope $"{opts.OutDir}/link.stamp", now).IgnoreError();
		}
	}
}
