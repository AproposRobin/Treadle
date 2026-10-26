// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using System.IO;
using System.Threading;
using Treadle.Document;
using Treadle.Language;
using Treadle.Backend.Driver;
using Treadle.Backend.Testing;
using Treadle.Backend.IR;

namespace Treadle.Editor
{
	/// The `backend` self test: every IR fixture (TreadleBackend/fixtures above the exe, or
	/// TREADLE_BACKEND_FIXTURES) built through the driver in Debug and Release, run, and compared with
	/// its `.expected` file; lldb from llvm-mingw stopping on a node's listing line in a Debug build;
	/// and F7 / Ctrl+F5 through the installed toolchain on a project folder holding a `.tir` file.
	/// Work files go to %TEMP%/treadle-backend-<stamp> and are removed afterwards.
	extension EditorApp
	{
		class BackendTestState
		{
			public Thread Worker ~ delete _;
			public Monitor Lock = new .() ~ delete _;
			public List<String> Lines = new .() ~ DeleteContainerAndItems!(_);
			public List<(bool ok, String what)> Checks = new .() ~ { for (let c in _) delete c.what; delete _; };
			public bool Done;
			public String Work = new .() ~ delete _;
			public String Fixtures = new .() ~ delete _;
			public BackendBuildJob Job ~ delete _;
			public ProgramRun Run ~ delete _;
			public List<String> RunLines = new .() ~ DeleteContainerAndItems!(_);
			public int Frames;
			/// Close during a build: the project copy, the project open before, rounds and counts.
			public String CloseProject = new .() ~ delete _;
			public String OldRoot = new .() ~ delete _;
			public System.Diagnostics.Stopwatch CloseWatch = new .() ~ delete _;
			public int CloseRounds;
			public int CloseStarted;
			public int CloseRunning;

			public void Check(bool ok, StringView what)
			{
				using (Lock.Enter())
					Checks.Add((ok, new String(what)));
			}

			public void Line(StringView text)
			{
				using (Lock.Enter())
					Lines.Add(new String(text));
			}
		}

		BackendTestState mBackendTest ~ delete _;

		static bool FindBackendFixtures(String outDir)
		{
			if (Environment.GetEnvironmentVariable("TREADLE_BACKEND_FIXTURES", outDir) case .Ok && Directory.Exists(outDir))
				return true;
			outDir.Clear();
			String dir = scope .();
			Environment.GetExecutableFilePath(dir);
			for (int up < 8)
			{
				String parent = scope .();
				if (Path.GetDirectoryPath(dir, parent) case .Err)
					break;
				dir.Set(parent);
				String probe = scope $"{dir}/TreadleBackend/fixtures";
				if (Directory.Exists(probe))
				{
					outDir.Set(probe);
					return true;
				}
			}
			return false;
		}

		/// True when `text` holds one of the `|`-separated alternatives of `want` (lldb versions spell some
		/// values differently: lldb 23 `U+03BB`, lldb 22 `U+0x000003bb` for a char32).
		static bool AnyIn(StringView text, StringView want)
		{
			for (let alt in want.Split('|'))
				if (text.Contains(alt))
					return true;
			return false;
		}

		static void DeleteTree(StringView dir)
		{
			for (let e in Directory.EnumerateDirectories(dir))
				DeleteTree(e.GetFilePath(.. scope String()));
			for (let e in Directory.EnumerateFiles(dir))
				File.Delete(e.GetFilePath(.. scope String())).IgnoreError();
			Directory.Delete(dir).IgnoreError();
		}

		/// The PE subsystem of an exe (its optional header's Subsystem: 2 GUI, 3 console); -1 when the
		/// file is not a PE image.
		static int PeSubsystem(StringView exe)
		{
			List<uint8> data = scope .();
			if (File.ReadAll(exe, data) case .Err || data.Count < 0x40 || data[0] != 'M' || data[1] != 'Z')
				return -1;
			let lfanew = (int)data[0x3C] | ((int)data[0x3D] << 8) | ((int)data[0x3E] << 16) | ((int)data[0x3F] << 24);
			let at = lfanew + 4 + 20 + 68;
			if (lfanew < 0 || at + 2 > data.Count || data[lfanew] != 'P' || data[lfanew + 1] != 'E')
				return -1;
			return (int)data[at] | ((int)data[at + 1] << 8);
		}

		/// The project kinds (Graph-Format.md 5): a windowed exe has the Windows subsystem (a console exe
		/// the console one) and wrote its file; a library exports its [Export] names and
		/// treadle_init / treadle_shutdown, not its other functions.
		static void KindChecks(BackendTestState st, FixtureResult r, StringView cfg)
		{
			String dir = scope .();
			Path.GetDirectoryPath(r.ExePath, dir);
			if (r.Name == "livepipe")
			{
				// the editor's Run: the program's line is read while the program still runs (about two
				// seconds), not when it ends
				ProgramRun run = scope .();
				List<String> lines = scope .();
				defer { ClearAndDeleteItems!(lines); }
				String why = scope .();
				bool ended = false;
				bool seenRunning = false;
				if (run.Start(r.ExePath, why))
				{
					let watch = scope System.Diagnostics.Stopwatch(true);
					while (!ended && watch.ElapsedMilliseconds < 20000)
					{
						ended = run.Update(lines);
						for (let l in lines)
							if (l.Contains("live line") && !ended)
								seenRunning = true;
						if (!ended)
							Thread.Sleep(5);
					}
					if (!ended)
						run.Stop();
				}
				st.Check(ended && seenRunning && run.ExitCode == 0, scope $"backend: Run of livepipe ({cfg}) shows the program's line while it is still running (ended {ended}, seen before the end {seenRunning}, exit {run.ExitCode}{why})");
				return;
			}
			if (r.Name == "vdispatch" || r.Name == "windowed")
			{
#if BF_PLATFORM_WINDOWS
				let want = (r.Name == "windowed") ? 2 : 3;
				let got = PeSubsystem(r.ExePath);
				st.Check(got == want, scope $"backend: {r.Name} ({cfg}) is a {(want == 2) ? "windowed" : "console"} exe: PE subsystem {got}, want {want}");
#endif
				if (r.Name == "windowed")
				{
					String text = scope .();
					let wrote = File.ReadAllText(scope $"{dir}/windowed.out", text, true) case .Ok;
					st.Check(wrote && text.Contains("written by a windowed program"), scope $"backend: windowed ({cfg}) ran to its end: it wrote windowed.out and its Console line reached the runner's pipe");
					// the editor's Run (ProgramRun: a job object, stdout and stderr through pipes) shows
					// a windowed program's Console output in the Output Log too
					ProgramRun run = scope .();
					List<String> lines = scope .();
					defer { ClearAndDeleteItems!(lines); }
					String why = scope .();
					bool ended = false;
					if (run.Start(r.ExePath, why))
					{
						let watch = scope System.Diagnostics.Stopwatch(true);
						while (!ended && watch.ElapsedMilliseconds < 20000)
						{
							ended = run.Update(lines);
							if (!ended)
								Thread.Sleep(5);
						}
						if (!ended)
							run.Stop();
					}
					bool seen = false;
					for (let l in lines)
						seen |= l.Contains("hello from a windowed program");
					st.Check(ended && run.ExitCode == 0 && seen, scope $"backend: Run of the windowed program ({cfg}) captures its Console line for the Output Log (exit {run.ExitCode}, {lines.Count} lines{why})");
				}
				return;
			}
			// the library's dynamic exports
			List<String> names = scope .();
			defer { ClearAndDeleteItems!(names); }
			let ok = ExportNames(r.ExePath, names);
			String got = scope .();
			for (let n in names)
				got.AppendF("{}{}", got.IsEmpty ? "" : " ", n);
			let want = "kl_add kl_flip kl_keep treadle_init treadle_shutdown"; // sorted, as the export table is
			st.Check(ok && got == want, scope $"backend: library ({cfg}) exports exactly its [Export] functions and treadle_init / treadle_shutdown ({got}; want {want})");
		}

		/// The functions a DLL (llvm-readobj --coff-exports) or a .so (llvm-nm -D --defined-only, the
		/// `T` symbols) exports to its users, sorted. False when the tool failed.
		static bool ExportNames(StringView lib, List<String> outNames)
		{
			String dir = scope .();
			Path.GetDirectoryPath(lib, dir);
			String tool = scope .();
			List<String> args = scope .();
			defer { ClearAndDeleteItems!(args); }
#if BF_PLATFORM_WINDOWS
			ToolchainPaths.Tool("llvm-readobj", tool);
			args.Add(new .("--coff-exports"));
#else
			ToolchainPaths.Tool("llvm-nm", tool);
			args.Add(new .("-D"));
			args.Add(new .("--defined-only"));
#endif
			args.Add(new .(lib));
			String o = scope .();
			String e = scope .();
			let code = RunningProcess.Run(tool, args, dir, o, e, 30000);
			for (var line in o.Split('\n'))
			{
				line.Trim();
#if BF_PLATFORM_WINDOWS
				if (line.StartsWith("Name: "))
				{
					var name = line.Substring(6);
					name.Trim();
					outNames.Add(new .(name));
				}
#else
				// `<address> T <name>`: the functions the .so defines for others
				var parts = line.Split(' ', .RemoveEmptyEntries);
				parts.GetNext().IgnoreError();
				let kind = parts.GetNext().GetValueOrDefault();
				let name = parts.GetNext().GetValueOrDefault();
				if (kind == "T" && !name.IsEmpty)
					outNames.Add(new .(name));
#endif
			}
			outNames.Sort(scope (a, b) => String.Compare(a, b, false));
			return code == 0;
		}

		/// The generated IR of the code generation fixtures (Compiler.md 6): what LLVM is told, read from
		/// the `.ll` files of a passed build.
		static void CodegenIRCheck(BackendTestState st, FixtureResult r)
		{
			if (r.ExePath.IsEmpty)
				return; // skipped in this configuration
			String dir = scope .();
			Path.GetDirectoryPath(r.ExePath, dir).IgnoreError();
			let release = r.Config == "Release";
			String text = scope .();
			if (r.Name == "aliasing")
			{
				File.ReadAllText(scope $"{dir}/Al.Program.ll", text, true).IgnoreError();
				if (release)
					st.Check(text.Contains("declare noalias nonnull ptr @rt_alloc(i64, i64) nounwind allocsize(0)") && text.Contains("declare noalias ptr @rt_alloc_with(ptr, i64, i64) nounwind allocsize(1)")
						&& text.Contains("!{!\"Al.Acc\", !") && text.Contains("i64 8, !") && text.Contains("i64 16}") && text.Contains("!{!\"Al.AccD\", !") && text.Contains("i64 24}")
						&& text.Contains(", !tbaa !") && text.Contains("!\"vtable pointer\""),
						"backend: aliasing (Release) declares rt_alloc noalias nonnull allocsize(0) and tags field, array and vtable accesses (Al.AccD's node holds Al.Acc's at offset 0)");
				else
					st.Check(text.Contains("declare noalias nonnull ptr @rt_alloc_dbg(") && !text.Contains("!tbaa"),
						"backend: aliasing (Debug) declares rt_alloc_dbg noalias nonnull and has no alias tags");
				// ThinLTO in Release: the units' and the runtime's objects are LLVM bitcode ("BC"), and the
				// runtime's stamp names the flag; Debug objects are native
				let unitBC = IsBitcode(scope $"{dir}/obj/Al.Program.o");
				let rtBC = IsBitcode(scope $"{dir}/runtime/treadle_rt.o");
				String stampText = scope .();
				File.ReadAllText(scope $"{dir}/runtime/stamp.txt", stampText, true).IgnoreError();
				if (release)
					st.Check(unitBC && rtBC && stampText.Contains("-flto=thin"), "backend: aliasing (Release) compiles its units and the runtime to ThinLTO bitcode, and the runtime's cache stamp names -flto=thin");
				else
					st.Check(!unitBC && !rtBC && !stampText.Contains("-flto"), "backend: aliasing (Debug) objects are native code (no LTO in Debug)");
			}
			else if (r.Name == "sretret")
			{
				File.ReadAllText(scope $"{dir}/Sr.Lib.ll", text, true).IgnoreError();
				let sret = text.Contains("define void @") && text.Contains("(ptr noalias sret(%\"Sr.V3\") align 8 %sret, %\"Sr.V3\" %p.v, double %p.k)")
					&& text.Contains("(ptr noalias sret(%\"Sr.Big3\") align 8 %sret, i64 %p.n)") && text.Contains("define %\"Sr.V2\" @");
				let fp = text.Contains("\"frame-pointer\"=\"all\"");
				st.Check(sret && (release ? !fp : fp), scope $"backend: sretret ({r.Config}) returns 24-byte structs through sret and two doubles in registers; frame pointers {(release ? "left to -O2" : "kept")}");
			}
			else if (r.Name == "finaldelete")
			{
				File.ReadAllText(scope $"{dir}/Fd.Program.ll", text, true).IgnoreError();
				// destructor slot loads (vtable slot 1): Release only for the Delete through Fd.Base
				int slotLoads = 0;
				for (let line in text.Split('\n'))
					if (line.Contains("getelementptr inbounds ptr, ptr ") && line.Contains(", i64 1"))
						slotLoads++;
				let direct = text.Contains("call void @_ZN2Fd5NoisyD1Ev(") && text.Contains("call void @_ZN2Fd5OwnerD1Ev(") && !text.Contains("call void @_ZN2Fd4LeafD1Ev(");
				st.Check(release ? (slotLoads == 1 && direct) : slotLoads == 4, scope $"backend: finaldelete ({r.Config}): {slotLoads} Delete(s) through the vtable{(release ? "; Noisy and Owner destroyed directly, Leaf not at all" : "")}");
			}
		}

		/// True when a file starts with LLVM's bitcode magic ("BC").
		static bool IsBitcode(StringView path)
		{
			FileStream fs = scope .();
			if (fs.Open(path, .Read, .ReadWrite) case .Err)
				return false;
			uint8[2] head = default;
			if (fs.TryRead(.(&head[0], 2)) case .Ok(let n))
				return n == 2 && head[0] == 'B' && head[1] == 'C';
			return false;
		}

		/// The fixtures and the lldb check, on a worker thread (the frame loop keeps running).
		static void BackendFixtureWork(BackendTestState st)
		{
			List<String> kirs = scope .();
			defer { ClearAndDeleteItems!(kirs); }
			// `<name>.linux.tir` replaces `<name>.tir` on Linux (a fixture that calls the system's
			// API, as atomics' threads); elsewhere it is skipped
			for (let e in Directory.EnumerateFiles(st.Fixtures, "*.tir"))
			{
				let path = e.GetFilePath(.. scope String());
#if BF_PLATFORM_WINDOWS
				if (path.EndsWith(".linux.tir"))
					continue;
#else
				if (!path.EndsWith(".linux.tir") && File.Exists(scope $"{StringView(path, 0, path.Length - 4)}.linux.tir"))
					continue;
#endif
				kirs.Add(new .(path));
			}
			kirs.Sort(scope (a, b) => String.Compare(a, b, false));
			st.Check(kirs.Count >= 5, scope $"backend: {kirs.Count} IR fixtures in {st.Fixtures}");
			String vdispatchExe = scope .();
			String debugInfoExe = scope .();
			String debugTypesExe = scope .();
			String atomicsExe = scope .();
			String attachExe = scope .();
			for (let k in kirs)
			{
				// the text form round trips: read, write, read the written text, write it again
				{
					String text = scope .();
					File.ReadAllText(k, text, true).IgnoreError();
					String name = scope .();
					Path.GetFileNameWithoutExtension(k, name);
					List<String> errs = scope .();
					defer { ClearAndDeleteItems!(errs); }
					IRProgram p1 = scope .();
					String w1 = scope .();
					String w2 = scope .();
					bool ok = IRReader.Read(text, p1, errs);
					if (ok)
					{
						IRWriter.Write(p1, w1);
						IRProgram p2 = scope .();
						ok = IRReader.Read(w1, p2, errs);
						if (ok)
							IRWriter.Write(p2, w2);
					}
					// (no `scope` inside a conditional expression: Beef's cleanup of it crashed in Debug)
					String what = scope $"backend: fixture {name} round trips through IRWriter / IRReader";
					if (!errs.IsEmpty)
						what.AppendF(" ({})", errs[0]);
					st.Check(ok && w1 == w2, what);
					if (ok && name == "debuginfo")
					{
						// the slot record's name and kind, and a spelled type, survive the round trip
						IRProgram p3 = scope .();
						IRReader.Read(w2, p3, errs);
						let main = p3.FindFunction("Dbg.Program.Main()");
						let s0 = main?.FindSlot("s0");
						let s1 = main?.FindSlot("s1");
						let v1 = main?.FindSlot("v1");
						st.Check(s0 != null && s0.Name == "pet" && s0.Shows == .Local && s1 != null && s1.Name == "a3.index" && s1.Shows == .Pin
							&& v1 != null && v1.TypeText == "int64" && w2.Contains("slot s0 Dbg.Bird variable \"pet\" local") && w2.Contains("slot s1 int loopvar \"a3.index\" pin node a3.index"),
							"backend: the slot record keeps its name and kind (\"pet\" local, \"a3.index\" pin) and the spelled type int64 through IRWriter / IRReader");
					}
				}
				for (let cfg in StringView[?]("Debug", "Release"))
				{
					FixtureResult r = scope .();
					FixtureRunner.Run(k, cfg, scope $"{st.Work}/fixtures", r);
					st.Check(r.Passed, scope $"backend: fixture {r.Name} ({cfg}): {r.Detail}");
					if (!r.Passed)
					{
						st.Line(scope $"stdout of {r.Name} ({cfg}):\n{r.Stdout}");
						st.Line(scope $"stderr of {r.Name} ({cfg}):\n{r.Stderr}");
					}
					else if (r.Name == "memory" && cfg == "Debug")
						st.Line(scope $"memory (Debug) stderr, the debug runtime's report:\n{r.Stderr}");
					if (r.Passed && r.Name == "vdispatch" && cfg == "Debug")
						vdispatchExe.Set(r.ExePath);
					if (r.Passed && r.Name == "debuginfo" && cfg == "Debug")
						debugInfoExe.Set(r.ExePath);
					if (r.Passed && r.Name == "debugtypes" && cfg == "Debug")
						debugTypesExe.Set(r.ExePath);
					if (r.Passed && r.Name.StartsWith("atomics") && cfg == "Debug")
						atomicsExe.Set(r.ExePath);
					if (r.Passed && r.Name == "attachwait" && cfg == "Debug")
						attachExe.Set(r.ExePath);
					if (r.Passed && (r.Name == "windowed" || r.Name == "library" || r.Name == "vdispatch" || r.Name == "livepipe"))
						KindChecks(st, r, cfg);
					if (r.Passed)
						CodegenIRCheck(st, r);
				}
			}
			// lldb: a breakpoint on the Multiply node of Shapes.Rect.Area by its listing line
			if (vdispatchExe.IsEmpty)
				st.Check(false, "backend: lldb check skipped (the vdispatch Debug build failed)");
			else
			{
				String dir = scope .();
				Path.GetDirectoryPath(vdispatchExe, dir);
				let line = FixtureRunner.NodeLine(scope $"{dir}/Shapes.Rect.nodemap", "f1", "a4");
				String detail = scope .();
				String transcript = scope .();
				let ok = line > 0 && FixtureRunner.LldbCheck(vdispatchExe, "Shapes.Rect.lst", line, "Shapes::Rect::Area", detail, transcript);
				st.Check(ok, scope $"backend: lldb breaks on Shapes.Rect.lst:{line} (node a4 of Shapes.Rect.Area): {detail}");
				st.Line(scope $"lldb transcript:\n{transcript}");
			}
#if BF_PLATFORM_WINDOWS
			CodeViewCheck(st);
#endif
			if (debugInfoExe.IsEmpty)
				st.Check(false, "backend: the debug info steps skipped (the debuginfo Debug build failed)");
			else
				DebugInfoSteps(st, debugInfoExe);
			if (debugTypesExe.IsEmpty)
				st.Check(false, "backend: the DWARF types check skipped (the debugtypes Debug build failed)");
			else
			{
				DebugTypesCheck(st, debugTypesExe);
				AdapterSummaries(st, debugTypesExe);
			}
			if (attachExe.IsEmpty)
				st.Check(false, "backend: the attach check skipped (the attachwait Debug build failed)");
			else
			{
				AttachCheck(st, attachExe);
				CleanupCheck(st, attachExe);
			}
			if (atomicsExe.IsEmpty)
				st.Check(false, "backend: the atomics steps skipped (the atomics Debug build failed)");
			else
				AtomicsSteps(st, atomicsExe);
			// the editor's Run under a flood: reading is bounded, lines are skipped and counted, Stop ends the program
			{
				FixtureResult fr = scope .();
				FixtureRunner.Run(scope $"{st.Fixtures}/flood.tirx", "Release", scope $"{st.Work}/fixtures", fr);
				if (fr.ExePath.IsEmpty || !File.Exists(fr.ExePath))
					st.Check(false, scope $"backend: the flood program did not build ({fr.Detail})");
				else
					FloodCheck(st, fr.ExePath);
			}
			using (st.Lock.Enter())
				st.Done = true;
		}

		static void FloodCheck(BackendTestState st, StringView exe)
		{
			ProgramRun run = scope .();
			List<String> lines = scope .();
			defer { ClearAndDeleteItems!(lines); }
			String why = scope .();
			if (!run.Start(exe, why))
			{
				st.Check(false, scope $"backend: the flood program did not start ({why})");
				return;
			}
			double worst = 0;
			bool skippedRow = false;
			int total = 0;
			let watch = scope System.Diagnostics.Stopwatch(true);
			let one = scope System.Diagnostics.Stopwatch();
			// about a second of frames at 60 per second while the program floods the pipe
			while (watch.ElapsedMilliseconds < 1000)
			{
				one.Restart();
				run.Update(lines);
				worst = Math.Max(worst, one.Elapsed.TotalMilliseconds);
				for (let l in lines)
				{
					total++;
					if (l.Contains("lines skipped"))
						skippedRow = true;
				}
				ClearAndDeleteItems!(lines);
				Thread.Sleep(16);
			}
			let stopWatch = scope System.Diagnostics.Stopwatch(true);
			run.Stop();
			bool ended = false;
			while (!ended && stopWatch.ElapsedMilliseconds < 5000)
			{
				ended = run.Update(lines);
				ClearAndDeleteItems!(lines);
				if (!ended)
					Thread.Sleep(5);
			}
			st.Check(worst < 50 && skippedRow && total > 0, scope $"backend: a flooding program never blocks the editor's reader (slowest frame {worst:0.0} ms, {total} lines handed over, skipped row {skippedRow})");
			st.Check(ended && stopWatch.ElapsedMilliseconds < 2000, scope $"backend: Stop ends the flooding program within 2 s (ended {ended} after {stopWatch.ElapsedMilliseconds} ms)");
		}

		/// lldb on the debugtypes fixture (Debug), stopped on the Call of puts: each kind of type by
		/// its own DWARF (payload enums by tag and case, a simple enum by name, a tuple's items, a
		/// nullable's hasValue and value, an array's length and an element, a delegate's function, a
		/// generic instance by its name, a static field as a global).
		static void DebugTypesCheck(BackendTestState st, StringView exe)
		{
			String dir = scope .();
			Path.GetDirectoryPath(exe, dir);
			let line = FixtureRunner.NodeLine(scope $"{dir}/Dbg.Program.nodemap", "m1", "b4");
			List<StringView> cmds = scope .();
			String bp = scope $"breakpoint set -f Dbg.Program.lst -l {line}";
			cmds.Add(bp);
			cmds.Add("run");
			cmds.Add("frame variable");
			cmds.Add("frame variable *arr");
			cmds.Add("frame variable arr->elements[1]");
			cmds.Add("frame variable *dg");
			cmds.Add("frame variable *box");
			cmds.Add("target variable");
			cmds.Add("kill");
			String transcript = scope .();
			String missing = scope .();
			for (int attempt < 2)
			{
				transcript.Clear();
				missing.Clear();
				FixtureRunner.LldbScript(exe, cmds, transcript);
				// lldb prints a structure on one line or several: compare without the layout
				String flat = scope .();
				bool space = false;
				for (let c in transcript.RawChars)
				{
					if (c == '\n' || c == '\r' || c == ' ' || c == '\t')
					{
						space = true;
						continue;
					}
					if (space && !flat.IsEmpty)
						flat.Append(' ');
					space = false;
					flat.Append(c);
				}
				for (let w in StringView[?]("(Core.Option<int>) some = { tag = Some payload = (Some = 5) }", "(Core.Option<int>) none = { tag = None",
					"(Core.Result<int,int32>) err = { tag = Err", "Err = 7", "(Dbg.Color) color = Green", "((int,bool)) pair = (item0 = 3, item1 = true)",
					"(int?) maybe = (hasValue = true, value = 9)", "(int?) nothing = (hasValue = false", "(int[] *) arr = 0x", "length = 3, elements =",
					"(int) arr->elements[1] = 20", "(delegate int(int) *) dg = 0x", "Dbg::Program::Twice(", "(Gen.Cell<int>) cell = (Value = 11, Ok = true)",
					"(Gen.Box<double> *) box = 0x", "mItem = 0.5", "(Dbg.Shape) shape = { tag = Rect", "Rect = (item0 = 4, item1 = 6)", "(int) Dbg.Program.sCount = 42"))
					if (!AnyIn(flat, w))
						missing.AppendF("{}[{}]", missing.IsEmpty ? "" : " ", w);
				if (missing.IsEmpty || transcript.Contains("frame variable"))
					break;
			}
			st.Check(missing.IsEmpty, scope $"backend: lldb shows payload enums by case, a simple enum by name, a tuple, a nullable, an array's length and elements, a delegate's function, generic instances and a static field by their DWARF types{(missing.IsEmpty ? "" : " (missing ")}{missing}{(missing.IsEmpty ? "" : ")")}");
			if (!missing.IsEmpty)
				st.Line(scope $"lldb transcript (types):\n{transcript}");
		}

		/// The debugger's summaries (TreadleDebug's LldbDapAdapter over lldb-dap) of the debugtypes
		/// locals, stopped on the Call of puts: the program is described by hand (the fixture has no
		/// type files: a unit per type with a made-up path, the node map of the build).
		/// A debugger's view of a fixture build (it has no type files): `unit` with a made-up type
		/// file `<dir>/Program.treadle` and its Sheet `m1` from the build's node map, other classes
		/// by name.
		static Treadle.Debug.DebugProgram FixtureProgram(StringView exe, StringView unit, Span<StringView> locals, Span<StringView> classes)
		{
			String dir = scope .();
			Path.GetDirectoryPath(exe, dir);
			Treadle.Debug.DebugProgram prog = new .();
			prog.Workspace.Set(dir);
			prog.BuildDir.Set(dir);
			prog.ExePath.Set(exe);
			Treadle.Debug.DebugUnitInfo u = new .();
			u.Name.Set(unit);
			u.Path.AppendF("{}/Program.treadle", dir);
			u.Kind = .Class;
			prog.Units[u.Name] = u;
			for (let name in classes)
			{
				Treadle.Debug.DebugUnitInfo c = new .();
				c.Name.Set(name);
				c.Path.AppendF("{}/{}.treadle", dir, name);
				c.Kind = .Class;
				prog.Units[c.Name] = c;
			}
			Treadle.Debug.DebugSheetInfo sheet = new .();
			sheet.Key.Set("m1");
			sheet.Name.AppendF("{}.Main", unit);
			u.Sheets[sheet.Key] = sheet;
			for (let l in locals)
				sheet.LocalNames.Add(new String(l));
			String map = scope .();
			File.ReadAllText(scope $"{dir}/{unit}.nodemap", map).IgnoreError();
			for (var line in map.Split('\n'))
			{
				line.Trim();
				var parts = line.Split(' ');
				let sk = parts.GetNext().GetValueOrDefault();
				let nk = parts.GetNext().GetValueOrDefault();
				let ln = int32.Parse(parts.GetNext().GetValueOrDefault()).GetValueOrDefault();
				if (sk != "m1" || ln <= 0)
					continue;
				Treadle.Debug.DebugNodeInfo n = new .();
				n.Key.Set(nk);
				n.Line = ln;
				sheet.Nodes[n.Key] = n;
				u.ByLine[ln] = (new String(sk), new String(nk));
			}
			return prog;
		}

		/// Waits up to `seconds` for an event of `kind` from the adapter (the others are dropped).
		static bool WaitFor(Treadle.Debug.Dap.LldbDapAdapter dap, Treadle.Debug.DebugEventKind kind, double seconds, Treadle.Debug.DebugEvent outCopy = null)
		{
			List<Treadle.Debug.DebugEvent> events = scope .();
			defer { ClearAndDeleteItems!(events); }
			let start = Internal.GetTickCountMicro();
			while ((Internal.GetTickCountMicro() - start) / 1000 < (int64)(seconds * 1000))
			{
				ClearAndDeleteItems!(events);
				dap.Poll(events);
				for (let e in events)
					if (e.Kind == kind)
					{
						if (outCopy != null)
						{
							outCopy.ExitCode = e.ExitCode;
							outCopy.Reason = e.Reason;
						}
						return true;
					}
				Thread.Sleep(20);
			}
			return false;
		}

		static void AdapterSummaries(BackendTestState st, StringView exe)
		{
			String dir = scope .();
			Path.GetDirectoryPath(exe, dir);
			let prog = FixtureProgram(exe, "Dbg.Program", StringView[?]("some", "none", "err", "color", "pair", "maybe", "arr", "dg", "cell", "box", "shape", "nothing"), StringView[?]("Gen.Box"));
			defer delete prog;
			String progPath = scope $"{dir}/Program.treadle";
			Treadle.Debug.Dap.LldbDapAdapter dap = new .();
			defer delete dap;
			if (!dap.Available)
			{
				st.Check(false, scope $"backend: the debugger's summaries: {dap.Unavailable}");
				return;
			}
			dap.SetProgram(prog);
			List<Treadle.Debug.DebugBreakpoint> bps = scope .();
			defer { ClearAndDeleteItems!(bps); }
			Treadle.Debug.DebugBreakpoint bp = new .();
			bp.Path.Set(progPath);
			bp.SheetKey.Set("m1");
			bp.NodeKey.Set("b4");
			bps.Add(bp);
			dap.SetBreakpoints(bps);
			String why = scope .();
			if (dap.Launch(exe, "", dir, why) case .Err)
			{
				st.Check(false, scope $"backend: the debugger's summaries: launch failed: {why}");
				return;
			}
			List<Treadle.Debug.DebugEvent> events = scope .();
			defer { ClearAndDeleteItems!(events); }
			bool stopped = false, exited = false;
			let start = Internal.GetTickCountMicro();
			while (!stopped && !exited && (Internal.GetTickCountMicro() - start) / 1000000 < 60)
			{
				ClearAndDeleteItems!(events);
				dap.Poll(events);
				for (let e in events)
				{
					if (e.Kind == .Stopped)
						stopped = true;
					else if (e.Kind == .Exited)
						exited = true;
				}
				Thread.Sleep(20);
			}
			List<Treadle.Debug.DebugVariable> vars = scope .();
			defer { ClearAndDeleteItems!(vars); }
			if (stopped)
				dap.GetVariables(0, vars);
			String got = scope .();
			String missing = scope .();
			for (let v in vars)
				got.AppendF("{}{} = {}", got.IsEmpty ? "" : "; ", v.Label, v.Value);
			for (let w in StringView[?]("some = Some(5)", "none = None", "err = Err(7)", "color = Green", "pair = (3, true)", "maybe = 9", "nothing = null",
				"arr = [10, 20, 30] (3)", "dg = Dbg.Program.Twice", "cell = {Value = 11, Ok = true}", "box = Gen.Box<double> (0x", "shape = Rect(4, 6)"))
				if (!got.Contains(w))
					missing.AppendF("{}[{}]", missing.IsEmpty ? "" : " ", w);
			st.Check(stopped && missing.IsEmpty, scope $"backend: the debugger's Locals summarise Option, Result, a simple enum, a tuple, a nullable, an array, a delegate, a struct, an object and a payload enum{(missing.IsEmpty ? "" : " (missing ")}{missing}{(missing.IsEmpty ? "" : ")")}");
			st.Line(scope $"debugtypes Locals: {got}");
			dap.Stop();
		}

		/// `debugFormat both` and `codeview` (Windows, docs/Compiler.md 7): vdispatch built with each
		/// runs as its `.expected` says; the PDB next to the exe has a line table for Shapes.Rect.lst
		/// with node a4's line (llvm-pdbutil dump -l); lldb breaks on a4 through the exe's DWARF
		/// (`both`) and through the PDB (`codeview`, `target symbols add`); and the debugger (lldb-dap
		/// through LldbDapAdapter, which adds the PDB itself) stops on node a3 of a `codeview` build
		/// of attachwait.
		static void CodeViewCheck(BackendTestState st)
		{
			String pdbutil = scope .();
			ToolchainPaths.Tool("llvm-pdbutil", pdbutil);
			for (let format in DebugFormat[?](.Both, .CodeView))
			{
				FixtureResult r = scope .();
				FixtureRunner.Run(scope $"{st.Fixtures}/vdispatch.tir", "Debug", scope $"{st.Work}/fixtures", r, format);
				st.Check(r.Passed, scope $"backend: vdispatch with debugFormat {format.Text} (Debug) builds and runs: {r.Detail}");
				if (!r.Passed)
					continue;
				String dir = scope .();
				Path.GetDirectoryPath(r.ExePath, dir);
				String pdb = scope .();
				Path.ChangeExtension(r.ExePath, ".pdb", pdb);
				let line = FixtureRunner.NodeLine(scope $"{dir}/Shapes.Rect.nodemap", "f1", "a4");
				// the PDB's line table: the rows after the Shapes.Rect.lst header hold a4's line
				String o = scope .();
				String e = scope .();
				List<String> args = scope .();
				defer { ClearAndDeleteItems!(args); }
				args.Add(new .("dump"));
				args.Add(new .("-l"));
				args.Add(new .(pdb));
				let code = File.Exists(pdb) ? RunningProcess.Run(pdbutil, args, dir, o, e, 60000) : -1;
				bool inFile = false, found = false;
				for (var l in o.Split('\n'))
				{
					if (l.Contains(".lst"))
						inFile = l.Contains("Shapes.Rect.lst");
					else if (inFile && !found)
					{
						// rows: `<line> <address> !` repeated
						var toks = l.Split(' ', .RemoveEmptyEntries);
						StringView prev = "";
						for (let t in toks)
						{
							if (t.Length == 8 && prev == scope $"{line}")
								found = true;
							prev = t;
						}
					}
				}
				st.Check(code == 0 && found, scope $"backend: debugFormat {format.Text}: {r.Name}.pdb maps Shapes.Rect.lst:{line} (node a4) to an address (llvm-pdbutil exit {code})");
				if (!found)
					st.Line(scope $"llvm-pdbutil dump -l:\n{o}{e}");
				String transcript = scope .();
				String detail = scope .();
				bool ok;
				if (format == .Both)
					ok = line > 0 && FixtureRunner.LldbCheck(r.ExePath, "Shapes.Rect.lst", line, "Shapes::Rect::Area", detail, transcript);
				else
				{
					String add = scope $"target symbols add \"{pdb}\"";
					String bp = scope $"breakpoint set -f Shapes.Rect.lst -l {line}";
					FixtureRunner.LldbScript(r.ExePath, StringView[?](add, bp, "run", "bt 1", "kill"), transcript);
					ok = transcript.Contains(scope $"at Shapes.Rect.lst:{line}") && transcript.Contains("stop reason = breakpoint") && transcript.Contains("Shapes::Rect::Area");
				}
				st.Check(ok, scope $"backend: debugFormat {format.Text}: lldb breaks on Shapes.Rect.lst:{line} (node a4) {detail}");
				if (!ok)
					st.Line(scope $"lldb transcript ({format.Text}):\n{transcript}");
			}
			// the debugger on a codeview build: LldbDapAdapter hands lldb-dap the PDB
			FixtureResult r = scope .();
			FixtureRunner.Run(scope $"{st.Fixtures}/attachwait.tir", "Debug", scope $"{st.Work}/fixtures", r, .CodeView);
			if (!r.Passed)
			{
				st.Check(false, scope $"backend: attachwait with debugFormat codeview did not build or run: {r.Detail}");
				return;
			}
			String dir = scope .();
			Path.GetDirectoryPath(r.ExePath, dir);
			let prog = FixtureProgram(r.ExePath, "Aw.Program", .(), .());
			defer delete prog;
			Treadle.Debug.Dap.LldbDapAdapter dap = new .();
			defer delete dap;
			dap.SetProgram(prog);
			List<Treadle.Debug.DebugBreakpoint> bps = scope .();
			defer { ClearAndDeleteItems!(bps); }
			Treadle.Debug.DebugBreakpoint bp = new .();
			bp.Path.AppendF("{}/Program.treadle", dir);
			bp.SheetKey.Set("m1");
			bp.NodeKey.Set("a3");
			bps.Add(bp);
			dap.SetBreakpoints(bps);
			String why = scope .();
			if (dap.Launch(r.ExePath, "", dir, why) case .Err)
			{
				st.Check(false, scope $"backend: debugFormat codeview: the debugger did not launch: {why}");
				return;
			}
			Treadle.Debug.DebugEvent stop = scope .();
			let stopped = WaitFor(dap, .Stopped, 60, stop);
			List<Treadle.Debug.DebugFrame> frames = scope .();
			defer { ClearAndDeleteItems!(frames); }
			if (stopped)
				dap.GetFrames(frames);
			let f = frames.IsEmpty ? null : frames[0];
			st.Check(stopped && f != null && f.NodeKey == "a3" && f.SheetName == "Aw.Program.Main",
				scope $"backend: debugFormat codeview: the debugger (lldb-dap given the PDB) stops on node a3 of attachwait (stopped {stopped}, {(f != null) ? f.SheetName : ""} {(f != null) ? f.NodeKey : ""})");
			dap.Stop();
		}

		/// Waits up to `ms` for the process to end; the milliseconds it took, or -1.
		static int WaitGone(int pid, int ms)
		{
			let watch = scope System.Diagnostics.Stopwatch(true);
			while (watch.ElapsedMilliseconds <= ms)
			{
				if (!ProcessJob.IsAlive(pid))
					return (int)watch.ElapsedMilliseconds;
				Thread.Sleep(10);
			}
			return -1;
		}

		/// Process cleanup (docs/Debugging.md, "Processes"): the attachwait Debug build, held by
		/// `attach.hold`, started through ProgramRun (Run's path) and its handle deleted without Stop
		/// (the editor side going away): the program is gone within 1 s (Windows: the job closes;
		/// Linux: the process group is killed). Linux also: started from a thread that then ends
		/// (what a killed editor looks like to the child), the runtime's parent-death signal ends it.
		static void CleanupCheck(BackendTestState st, StringView exe)
		{
			String dir = scope .();
			Path.GetDirectoryPath(exe, dir);
			String hold = scope $"{dir}/attach.hold";
			File.WriteAllText(hold, "hold").IgnoreError();
			defer { File.Delete(hold).IgnoreError(); }
			ProgramRun run = new .();
			String why = scope .();
			if (!run.Start(exe, why))
			{
				st.Check(false, scope $"backend: cleanup: the program did not start ({why})");
				delete run;
				return;
			}
			let pid = run.ProcessId;
			Thread.Sleep(300);
			let alive = ProcessJob.IsAlive(pid);
			delete run;
			let gone = WaitGone(pid, 1000);
			st.Check(alive && gone >= 0, scope $"backend: cleanup: a program started by Run ends within 1 s when the editor's handle goes (process {pid}, running before {alive}, gone after {gone} ms)");
#if !BF_PLATFORM_WINDOWS
			// the starting thread ends while the program runs: PR_SET_PDEATHSIG (treadle_rt.c)
			ProgramRun orphan = new .();
			int orphanPid = 0;
			Thread starter = new Thread(new [&] () =>
			{
				String w = scope .();
				if (orphan.Start(exe, w))
					orphanPid = orphan.ProcessId;
				Thread.Sleep(500); // the program reaches rt_start's prctl
			});
			starter.Start(false);
			bool joined = false;
			ThreadJoin.Join(starter, ref joined);
			delete starter;
			let orphanGone = WaitGone(orphanPid, 1000);
			st.Check(orphanPid > 0 && orphanGone >= 0, scope $"backend: cleanup: a program whose starting thread ends (a killed editor) gets its parent-death signal and ends within 1 s (process {orphanPid}, gone after {orphanGone} ms)");
			if (orphanGone < 0)
				orphan.Stop();
			delete orphan;
#endif
		}

		/// Attach (Debug > Attach to Process): the attachwait Debug build started with `attach.hold`
		/// in its folder waits; it is found among the running programs of its build folder, the
		/// adapter attaches with a breakpoint on a3, the file goes, the program stops on a3, and runs
		/// to its exit (code 0) on Continue.
		static void AttachCheck(BackendTestState st, StringView exe)
		{
			String dir = scope .();
			Path.GetDirectoryPath(exe, dir);
			String hold = scope $"{dir}/attach.hold";
			File.WriteAllText(hold, "hold").IgnoreError();
			RunningProcess proc = scope .();
			List<String> noArgs = scope .();
			if (!proc.Start(exe, noArgs, dir))
			{
				st.Check(false, scope $"backend: attach: the program did not start ({proc.Error})");
				File.Delete(hold).IgnoreError();
				return;
			}
			defer
			{
				File.Delete(hold).IgnoreError();
				if (!proc.Wait(5000))
					proc.Kill();
			}
			// the program is listed among the running programs of its folder
			List<Treadle.Debug.Dap.RunningProgram> running = scope .();
			defer { ClearAndDeleteItems!(running); }
			bool listed = false;
			for (int tries < 50)
			{
				ClearAndDeleteItems!(running);
				Treadle.Debug.Dap.ProcessList.FindIn(dir, running);
				for (let r in running)
					if (r.Pid == (int32)proc.ProcessId)
						listed = true;
				if (listed)
					break;
				Thread.Sleep(50);
			}
			st.Check(listed, scope $"backend: attach: the running program is listed for its folder (process {proc.ProcessId}, {running.Count} listed)");
			let prog = FixtureProgram(exe, "Aw.Program", .(), .());
			defer delete prog;
			Treadle.Debug.Dap.LldbDapAdapter dap = new .();
			defer delete dap;
			dap.SetProgram(prog);
			List<Treadle.Debug.DebugBreakpoint> bps = scope .();
			defer { ClearAndDeleteItems!(bps); }
			Treadle.Debug.DebugBreakpoint bp = new .();
			bp.Path.AppendF("{}/Program.treadle", dir);
			bp.SheetKey.Set("m1");
			bp.NodeKey.Set("a3");
			bps.Add(bp);
			dap.SetBreakpoints(bps);
			String why = scope .();
			if (dap.Attach((int32)proc.ProcessId, why) case .Err)
			{
				st.Check(false, scope $"backend: attach failed: {why}");
				return;
			}
			let started = WaitFor(dap, .Started, 30);
			// let it go on: the stop comes on a3
			for (int tries < 100)
			{
				if (File.Delete(hold) case .Ok)
					break;
				Thread.Sleep(20);
			}
			Treadle.Debug.DebugEvent stop = scope .();
			let stopped = started && WaitFor(dap, .Stopped, 30, stop);
			List<Treadle.Debug.DebugFrame> frames = scope .();
			defer { ClearAndDeleteItems!(frames); }
			if (stopped)
				dap.GetFrames(frames);
			let f = frames.IsEmpty ? null : frames[0];
			st.Check(stopped && f != null && f.NodeKey == "a3" && f.SheetName == "Aw.Program.Main",
				scope $"backend: attach: lldb-dap attaches to the running program and stops on a3 (started {started}, stopped {stopped}, {(f != null) ? f.SheetName : ""} {(f != null) ? f.NodeKey : ""})");
			if (stopped)
			{
				dap.Continue();
				Treadle.Debug.DebugEvent ex = scope .();
				let exited = WaitFor(dap, .Exited, 30, ex);
				st.Check(exited && ex.ExitCode == 0, scope $"backend: attach: Continue runs the attached program to its exit (code {ex.ExitCode})");
			}
			dap.Stop();
		}

		/// lldb steps through the atomics fixture's Debug build: Step Over from the first Compare
		/// Exchange stops on the next one, the Exchange (with the fence) and the printf, so the
		/// atomic ops and the fence carry their nodes' lines.
		static void AtomicsSteps(BackendTestState st, StringView exe)
		{
			String dir = scope .();
			Path.GetDirectoryPath(exe, dir);
			String pm = scope $"{dir}/At.Program.nodemap";
			let from = FixtureRunner.NodeLine(pm, "m1", "a5");
			List<StringView> cmds = scope .();
			String b = scope $"breakpoint set -f At.Program.lst -l {from}";
			cmds.Add(b);
			cmds.Add("run");
			cmds.Add("breakpoint delete -f");
			cmds.Add("thread step-over");
			cmds.Add("thread step-over");
			cmds.Add("thread step-over");
			cmds.Add("kill");
			String transcript = scope .();
			List<String> stops = scope .();
			defer { ClearAndDeleteItems!(stops); }
			for (int attempt < 2)
			{
				transcript.Clear();
				ClearAndDeleteItems!(stops);
				FixtureRunner.LldbScript(exe, cmds, transcript);
				FixtureRunner.StopLines(transcript, stops);
				if (stops.Count >= 4)
					break;
			}
			String got = scope .();
			for (let s in stops)
				got.AppendF("{}{}", got.IsEmpty ? "" : " ", s);
			String want = scope .();
			for (let n in StringView[?]("a5", "a6", "a7", "a8"))
				want.AppendF("{}At.Program.lst:{}", want.IsEmpty ? "" : " ", FixtureRunner.NodeLine(pm, "m1", n));
			st.Check(got == want, scope $"backend: lldb steps node by node through the atomics Debug build, the fence included ({got}; want {want})");
			if (got != want)
				st.Line(scope $"lldb transcript (atomics):\n{transcript}");
		}

		/// lldb on the debuginfo fixture (Debug): the stops of Step Over from the Call in the For
		/// loop's body (the For's increment is a stop of its own, the Defer's test and body at the
		/// exit on their nodes), Step Into lands on the callee's Entry node.
		static void DebugInfoSteps(BackendTestState st, StringView exe)
		{
			String dir = scope .();
			Path.GetDirectoryPath(exe, dir);
			String pm = scope $"{dir}/Dbg.Program.nodemap";
			String bm = scope $"{dir}/Dbg.Bird.nodemap";
			String Line(StringView map, StringView lst, StringView sheet, StringView node, String outText)
			{
				outText.AppendF("{}:{}", lst, FixtureRunner.NodeLine(map, sheet, node));
				return outText;
			}
			let call = FixtureRunner.NodeLine(pm, "m1", "a4");
			// Step Over without stepping over a call (lldb on Windows now and then spins in a Step Over
			// of a call when the machine is busy): from the Set after the call into the For's increment
			// and on to the next pass's Call, and from the Return through the Defer's test to its puts
			String transcript = scope .();
			List<String> stops = scope .();
			defer { ClearAndDeleteItems!(stops); }
			String got = scope .();
			String want = scope .();
			List<StringView> cmds = scope .();
			for (let from in StringView[?]("a5", "a6"))
			{
				let line = FixtureRunner.NodeLine(pm, "m1", from);
				cmds.Clear();
				String b = scope:: $"breakpoint set -f Dbg.Program.lst -l {line}";
				cmds.Add(b);
				cmds.Add("run");
				cmds.Add("breakpoint delete -f");
				cmds.Add("thread step-over");
				cmds.Add("thread step-over");
				cmds.Add("kill");
				// a hung lldb ends at its 90 s timeout: one more try
				for (int attempt < 2)
				{
					transcript.Clear();
					ClearAndDeleteItems!(stops);
					FixtureRunner.LldbScript(exe, cmds, transcript);
					FixtureRunner.StopLines(transcript, stops);
					if (stops.Count >= 3)
						break;
				}
				for (let s in stops)
					got.AppendF("{}{}", got.IsEmpty ? "" : " ", s);
			}
			for (let n in StringView[?]("a5", "a3", "a4", "a6", "a7", "a8"))
			{
				if (!want.IsEmpty)
					want.Append(' ');
				Line(pm, "Dbg.Program.lst", "m1", n, want);
			}
			st.Check(got == want, scope $"backend: lldb Step Over stops on the For's increment after the loop body and on the Defer at the exit ({got}; want {want})");
			if (got != want)
				st.Line(scope $"lldb transcript (steps):\n{transcript}");
			String bp = scope $"breakpoint set -f Dbg.Program.lst -l {call}";
			// Step Into Speak: its Entry node
			cmds.Clear();
			cmds.Add(bp);
			cmds.Add("run");
			cmds.Add("breakpoint delete -f");
			cmds.Add("thread step-in");
			cmds.Add("frame variable");
			cmds.Add("kill");
			transcript.Clear();
			FixtureRunner.LldbScript(exe, cmds, transcript);
			ClearAndDeleteItems!(stops);
			FixtureRunner.StopLines(transcript, stops);
			String entry = scope .();
			Line(bm, "Dbg.Bird.lst", "f1", "b1", entry);
			StringView into = (stops.Count >= 2) ? (StringView)stops[1] : "";
			// the parameters are already in their allocas there (the spill is in the prologue)
			let atEntry = transcript.Contains("(Dbg.Bird *) this = 0x") && transcript.Contains("(int) mood = 7");
			st.Check(into == entry && transcript.Contains("Dbg::Bird::Speak") && atEntry, scope $"backend: lldb Step Into Speak stops on its Entry node with this and the parameters set ({into}; want {entry}; parameters {(atEntry ? "set" : "not set")})");
			if (into != entry || !atEntry)
				st.Line(scope $"lldb transcript (step into):\n{transcript}");
			// Parameters after a call: Speak's Return runs after puts; `this`, `times` (read before
			// the call) and `mood` (never read) are still there
			let ret = FixtureRunner.NodeLine(bm, "f1", "b4");
			cmds.Clear();
			String bp2 = scope $"breakpoint set -f Dbg.Bird.lst -l {ret}";
			cmds.Add(bp2);
			cmds.Add("run");
			cmds.Add("frame variable");
			cmds.Add("kill");
			transcript.Clear();
			FixtureRunner.LldbScript(exe, cmds, transcript);
			let vars = transcript.Contains(") this = 0x") && transcript.Contains("(int64) times = 0") && transcript.Contains("(int) mood = 7");
			st.Check(vars, scope $"backend: lldb shows this and the parameters after a call (Speak's Return, Dbg.Bird.lst:{ret})");
			if (!vars)
				st.Line(scope $"lldb transcript (parameters):\n{transcript}");
			// Named slots and DWARF types: Main's variables by their names, each type by its own name
			cmds.Clear();
			cmds.Add(bp);
			cmds.Add("run");
			cmds.Add("frame variable");
			cmds.Add("frame variable *text");
			cmds.Add("kill");
			transcript.Clear();
			FixtureRunner.LldbScript(exe, cmds, transcript);
			String missing = scope .();
			for (let w in StringView[?]("(Dbg.Bird *) pet = 0x", "(int) a3.index = 0", "(int) total = 0", "(int) n = 5", "(int64) n64 = -6",
				"(int32) n32 = 7", "(bool) flag = true", "(char8) c8 = 'A'", "(char32) c32 = U+03BB|(char32) c32 = U+0x000003bb", "(float) f = 1.5", "(double) d = 2.25",
				"(int *) pn = 0x", "(Core.String *) text = 0x", "(StringView) view = (Ptr = \"hey\", Length = 3)", "mPtr = \"hi\", mLength = 2"))
				if (!AnyIn(transcript, w))
					missing.AppendF("{}[{}]", missing.IsEmpty ? "" : " ", w);
			st.Check(missing.IsEmpty, scope $"backend: lldb names Main's slots by their slot names and shows int, int64, int32, bool, char8, char32, float, double, a pointer, String and StringView by their own types{(missing.IsEmpty ? "" : " (missing ")}{missing}{(missing.IsEmpty ? "" : ")")}");
			if (!missing.IsEmpty)
				st.Line(scope $"lldb transcript (variables):\n{transcript}");
		}

		bool SelfTestBackend()
		{
			switch (mSelfTestStep)
			{
			case 0:
				SelfTestCheck(Language.Toolchain is BackendToolchain, "backend: the back end's toolchain is installed");
				SelfTestCheck(ToolchainPaths.Found, "backend: llvm-mingw found (TREADLE_LLVM / default)");
				delete mBackendTest;
				mBackendTest = new .();
				if (!FindBackendFixtures(mBackendTest.Fixtures))
				{
					SelfTestCheck(false, "backend: the fixtures folder was not found (set TREADLE_BACKEND_FIXTURES)");
					return true;
				}
				String temp = scope .();
				if (!SelfTestTemp.Get(temp))
					temp.Set(mBackendTest.Fixtures);
				mBackendTest.Work.AppendF("{}/treadle-backend-{}", temp, (int)Platform.BfpSystem_GetTimeStamp() & 0xFFFFFF);
				Directory.CreateDirectory(mBackendTest.Work).IgnoreError();
				let st = mBackendTest;
				st.Worker = new Thread(new () => BackendFixtureWork(st));
				st.Worker.SetName("Treadle backend self test");
				st.Worker.Start(false);
				return false;
			case 1:
				// wait for the fixtures (and lldb), reporting as results come in
				let st = mBackendTest;
				bool done;
				using (st.Lock.Enter())
				{
					for (let l in st.Lines)
						Notify.Log(.Info, "SelfTest", l);
					ClearAndDeleteItems!(st.Lines);
					for (let c in st.Checks)
					{
						SelfTestCheck(c.ok, c.what);
						delete c.what;
					}
					st.Checks.Clear();
					done = st.Done;
				}
				if (!done)
				{
					mSelfTestStep = 0; // stay on this step (the tick adds one)
					return false;
				}
				st.Worker.Join();
				// F7 through the installed toolchain: a project folder with one .tir file
				String proj = scope $"{st.Work}/Shapes";
				Directory.CreateDirectory(proj).IgnoreError();
				File.Copy(scope $"{st.Fixtures}/vdispatch.tir", scope $"{proj}/Shapes.tir").IgnoreError();
				BuildRequest request = .();
				request.Workspace = proj;
				request.Config = "Debug";
				request.Tool = "";
				RunRequest run = .();
				run.Build = request;
				if (Language.Toolchain.Run(run) case .Ok(let job))
				{
					st.Job = job as BackendBuildJob;
					if (st.Job == null)
						delete job;
				}
				SelfTestCheck(st.Job != null, "backend: Run (Ctrl+F5) starts a build through the toolchain");
				return st.Job == null;
			case 2:
				let st = mBackendTest;
				if (!st.Job.Update())
				{
					if (++st.Frames > 20000)
					{
						SelfTestCheck(false, "backend: the toolchain build did not finish");
						return true;
					}
					mSelfTestStep = 1;
					return false;
				}
				for (let l in st.Job.Output)
					Notify.Log(.Verbose, "SelfTest", l);
				SelfTestCheck(st.Job.Succeeded && File.Exists(st.Job.ExePath), scope $"backend: the toolchain built {st.Job.ExePath} in {st.Job.BuildMs:0} ms ({st.Job.Report.UnitsCompiled} units compiled)");
				if (!st.Job.Succeeded)
					return true;
				st.Run = new .();
				String why = scope .();
				SelfTestCheck(st.Run.Start(st.Job.ExePath, why), scope $"backend: the built program starts {why}");
				return false;
			case 3:
				let st = mBackendTest;
				if (!st.Run.Update(st.RunLines))
				{
					mSelfTestStep = 2;
					return false;
				}
				String output = scope .();
				for (let l in st.RunLines)
					output.AppendF("{}\n", l);
				SelfTestCheck(st.Run.ExitCode == 0 && output.Contains("Rect area = 12") && output.Contains("square is a rect: 0"), scope $"backend: Run captures the program's output and exit code ({st.Run.ExitCode}, {st.RunLines.Count} lines)");
				// a second build of the unchanged project compiles nothing
				BuildRequest request = .();
				String proj = scope $"{st.Work}/Shapes";
				request.Workspace = proj;
				request.Config = "Debug";
				request.Tool = "";
				if (Language.Toolchain.Build(request) case .Ok(let job))
				{
					let bj = job as BackendBuildJob;
					bj.WaitDone();
					SelfTestCheck(bj.Succeeded && bj.Report.UnitsCompiled == 0 && !bj.Report.Linked, scope $"backend: an unchanged project rebuilds nothing ({bj.Report.UnitsCached} units cached, {bj.BuildMs:0} ms)");
					delete job;
				}
				else
					SelfTestCheck(false, "backend: the second build did not start");
				// Close Project while a build runs: a copy of m2-frontend, Build, Close 50 ms later, 10 times
				String samples = scope .();
				if (!FindSamples(samples) || !Directory.Exists(scope $"{samples}/m2-frontend"))
				{
					SelfTestCheck(false, "backend: close during a build skipped (TreadleCore/samples/m2-frontend not found)");
					mSelfTestStep = 5;
					return false;
				}
				st.CloseProject.AppendF("{}/m2-close", st.Work);
				CopyTree(scope $"{samples}/m2-frontend", st.CloseProject);
				st.OldRoot.Set(mProjectRoot);
				return false;
			case 4:
				// open the copy and start a build
				let st = mBackendTest;
				OpenProjectNow(st.CloseProject, "", false);
				Build("Debug");
				st.CloseWatch.Restart();
				st.CloseStarted += (mBuild != null && mBuild.Running) ? 1 : 0;
				return false;
			case 5:
				// 50 ms later: close the project with the build still running
				let st = mBackendTest;
				if (st.CloseWatch.ElapsedMilliseconds < 50)
				{
					mSelfTestStep = 4;
					return false;
				}
				st.CloseRunning += (mBuild != null && mBuild.Running) ? 1 : 0;
				OpenProjectNow("", "", true);
				if (++st.CloseRounds < 10)
				{
					mSelfTestStep = 3;
					return false;
				}
				let live = BackendBuildJob.LiveThreads;
				SelfTestCheck(st.CloseRounds == 10 && mBuild == null && st.CloseStarted == 10 && live == 0,
					scope $"backend: Close Project 50 ms into a build of m2-frontend, 10 times: each build stopped with its job ({st.CloseStarted} builds started, {st.CloseRunning} still running at the close, {live} build threads left)");
				return false;
			case 6:
				let st = mBackendTest;
				// back to the project open before (unless its folder is gone: the editor test's copy)
				if (!st.OldRoot.IsEmpty && Directory.Exists(st.OldRoot))
					OpenProjectNow(st.OldRoot, "", false);
				DeleteTree(st.Work);
				SelfTestCheck(!Directory.Exists(st.Work), "backend: the work folder is removed");
				DeleteAndNullify!(mBackendTest);
				return true;
			}
			return true;
		}

		/// Copies a folder (its files and subfolders, without `build`).
		static void CopyTree(StringView from, StringView to)
		{
			Directory.CreateDirectory(to).IgnoreError();
			for (let e in Directory.EnumerateFiles(from))
			{
				String name = scope .();
				e.GetFileName(name);
				File.Copy(e.GetFilePath(.. scope String()), scope $"{to}/{name}").IgnoreError();
			}
			for (let e in Directory.EnumerateDirectories(from))
			{
				String name = scope .();
				e.GetFileName(name);
				if (name != "build")
					CopyTree(e.GetFilePath(.. scope String()), scope $"{to}/{name}");
			}
		}
	}
}
#endif
