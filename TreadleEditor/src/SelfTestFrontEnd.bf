// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using System.IO;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Format;
using Treadle.Model;
using Treadle.Language;
using Treadle.Compiler;

namespace Treadle.Editor
{
	/// The `frontend` self test: the compiler front end over the samples.
	///
	///  1. Every sample validates (Declare + Bind + Check) with no error and no warning.
	///  2. Each broken sample under TreadleCompiler/fixtures/broken gives the diagnostic its
	///     `# expect <node> <pin|-> <code>` lines name, on that node and pin.
	///  3. The Sheet IR dumps of the samples match TreadleCompiler/fixtures/ir/*.tir
	///     (TREADLE_WRITE_FIXTURES=1 writes them instead).
	///  4. The services the editor uses: Validate's per-Sheet checks put a broken sample's error
	///     on its node; the type system and the Node menu answer from the type table.
	extension EditorApp
	{
		static bool FindFixtures(StringView samples, String outDir)
		{
			String dir = scope .();
			if (Path.GetDirectoryPath(samples, dir) case .Err)
				return false;
			String root = scope .();
			if (Path.GetDirectoryPath(dir, root) case .Err)
				return false;
			outDir.Set(scope $"{root}/TreadleCompiler/fixtures");
			return Directory.Exists(outDir);
		}

		static void LogDiags(Compilation c, int max = 30)
		{
			int n = 0;
			for (let d in c.Diags.Items)
			{
				if (n++ >= max)
					break;
				Notify.Log(.Info, "SelfTest", scope $"[SELFTEST]      {d}");
			}
		}

		/// The ops of a function in a `.tir` dump (its block lines without the node / pin each
		/// names), for comparing two functions' Sheet IR.
		static void KirOps(StringView dump, StringView func, String outOps)
		{
			bool inside = false;
			for (let line in dump.Split('\n'))
			{
				if (line.StartsWith("func "))
				{
					inside = line.StartsWith(scope $"func {func}(");
					continue;
				}
				if (!inside)
					continue;
				if (line.IsEmpty)
					break;
				if (line.StartsWith("\tnode ") || line.StartsWith("\tparam ") || line.StartsWith("\tslot "))
					continue;
				var op = line;
				let at = op.IndexOf(" @");
				if (at >= 0)
					op = op.Substring(0, at);
				outOps.Append(op, "\n");
			}
		}

		/// The Math Expression (Language.md 5.6): one parser for the node, the editor's field and
		/// constants, with positions in its messages; its ops are the equivalent nodes' ops.
		void CheckMathExpressions(StringView dump)
		{
			String poly = scope .();
			String nodes = scope .();
			KirOps(dump, "M2.MathExprs.Poly", poly);
			KirOps(dump, "M2.MathExprs.PolyNodes", nodes);
			int lines = 0;
			for (let ch in poly.RawChars)
				if (ch == '\n')
					lines++;
			SelfTestCheck(!poly.IsEmpty && poly == nodes, scope $"frontend: the Math Expression x * x + 2 * x + 1 lowers to the ops of its Operator nodes ({lines} lines)");
			StringView[?] cases = .(
				"a +* b", "unexpected '*' at 4",
				"(a + b", "a ')' is missing at 7",
				"c ? a", "a ':' is missing (c ? a : b) at 6",
				"Max(a, b", "a ')' is missing after the inputs of Max at 9",
				"12ab", "'12a' is not a number at 1",
				"", "the expression is empty");
			let rules = scope TreadleRules(null);
			int good = 0;
			for (int i = 0; i < cases.Count; i += 2)
			{
				String why = scope .();
				let ok = rules.CheckExpression(cases[i], why);
				if (!ok && why == cases[i + 1])
					good++;
				else
					Notify.Log(.Info, "SelfTest", scope $"[SELFTEST]      '{cases[i]}': {why}");
			}
			SelfTestCheck(good == cases.Count / 2, scope $"frontend: CheckExpression says where a Math Expression goes wrong ({good} of {cases.Count / 2})");
			StringView[?] fine = .("a ** -b ** 2", "x > 1 && !(y <= 2) || z != 3", "c ? Sqrt(a.x) : Math.Min(b, 1.5f)", "(m >> 4 & 0xF) | 1 << 8 ^ ~n", "-.5e3d % 2");
			int parsed = 0;
			for (let s in fine)
				if (rules.CheckExpression(s, scope String()))
					parsed++;
			SelfTestCheck(parsed == fine.Count, scope $"frontend: the Math Expression grammar reads powers, logic, ? :, calls, fields, bit operators and suffixes ({parsed} of {fine.Count})");
		}

		/// m2-nestedcapture: the outer Lambda Sheet lists what its inner Lambda reads of the function
		/// as chained captures (Properties shows them), with their kind and how they are held, and
		/// the inner Sheet's value nodes keep their "evaluated Nx" counts.
		void CheckChainedCaptures(Compilation c)
		{
			SheetResult outer = null;
			SheetResult inner = null;
			for (let r in c.ResultList)
				if (r.IsLambda && r.Type.FullName == "M2.NestedCapture")
				{
					if (r.Sheet.LambdaNode == "a3")
						outer = r;
					else if (r.Sheet.LambdaNode == "b2")
						inner = r;
				}
			String rows = scope .();
			if (outer != null)
				for (let cap in outer.Captures)
					rows.AppendF("{}:{}{}{} ", (cap.What == .Local) ? "local" : ((cap.What == .Param) ? "param" : "this"), (cap.What == .This) ? "this" : (StringView)cap.Name,
						cap.ByRef ? " by-ref" : "", cap.Chained ? " chained" : "");
			rows.Trim();
			int evaluated = 0;
			if (inner != null)
				for (let b in inner.Nodes)
					if (!b.Flow && b.EvalCount > 0)
						evaluated++;
			SelfTestCheck(rows == "local:total chained param:k chained local:outv by-ref chained this:this chained" && inner != null && inner.Captures.Count == 5 && evaluated >= 9,
				scope $"frontend: the outer Lambda of m2-nestedcapture holds the inner one's captures ({rows}), the inner Sheet's {evaluated} value nodes are evaluated");
		}

		Compilation SelfTestCompile(StringView samples, List<TypeDocument> extra = null, StringView cimport = "")
		{
			let project = ProjectLoader.ReadProject(scope $"{samples}/Shooter.tproj");
			let c = ProjectLoader.Make(samples, null, null, project, extra);
			if (!cimport.IsEmpty)
				c.AddCImport(cimport, samples);
			c.Run();
			// The project file is only borrowed by the compilation.
			mSelfTestProjects.Add(project);
			return c;
		}

		List<ProjectFile> mSelfTestProjects = new .() ~ DeleteContainerAndItems!(_);

		bool SelfTestFrontEnd()
		{
			String samples = scope .();
			if (!FindSamples(samples))
			{
				SelfTestCheck(false, "frontend: the samples folder was not found (set TREADLE_SAMPLES)");
				return true;
			}
			String fixtures = scope .();
			if (!FindFixtures(samples, fixtures))
			{
				SelfTestCheck(false, "frontend: TreadleCompiler/fixtures was not found next to the samples");
				return true;
			}

			// 1. The samples validate clean. Shooter.tproj is the format's example project file: no
			//    `source` lines (the flat samples folder is scanned), `cimport libc.cimport`, and
			//    `depends ../core/Core.tproj`, the core library's own project (TreadleCore/core,
			//    lower case: Linux file names are case-sensitive), which every program has, so it is
			//    not read twice. Nothing may be reported.
			{
				let sw = scope System.Diagnostics.Stopwatch(true);
				let c = SelfTestCompile(samples);
				defer delete c;
				let errors = c.Diags.ErrorCount;
				let warnings = c.Diags.WarningCount;
				SelfTestCheck(errors == 0 && warnings == 0 && c.ResultList.Count >= 9,
					scope $"frontend: the samples validate with no diagnostics, the project file's lines included ({c.ResultList.Count} Sheets, {c.Table.Types.Count} types, {errors} errors, {warnings} warnings, {sw.Elapsed.TotalMilliseconds:0} ms)");
				if (errors + warnings != 0)
					LogDiags(c);
			}

			// 1b. The milestone-2 sample project (source + depends) validates clean.
			String m2 = scope $"{samples}/m2-frontend";
			{
				let sw = scope System.Diagnostics.Stopwatch(true);
				let project = ProjectLoader.ReadProject(scope $"{m2}/M2.tproj");
				let c = ProjectLoader.Make(m2, null, null, project);
				defer { delete c; delete project; }
				c.Run();
				let word = c.Table.Find("Lib.Word");
				SelfTestCheck(c.Diags.ErrorCount == 0 && c.Diags.WarningCount == 0 && word != null && word.Project == "M2Lib" && c.ResultList.Count >= 25,
					scope $"frontend: m2-frontend validates with no diagnostics through `source src` and `depends lib/M2Lib.tproj` ({c.ResultList.Count} Sheets, Lib.Word from {(word != null) ? (StringView)word.Project : "nowhere"}, {sw.Elapsed.TotalMilliseconds:0} ms)");
				if (c.Diags.Items.Count > 0)
					LogDiags(c);
			}

			// 1b'. The SDL sample (C import sets with structs, a union, enums; Main(String[] args))
			//      validates clean and lowers, with SDL's import library to link and its DLL to copy.
			{
				String sdl = scope $"{samples}/m2-sdl";
				let sw = scope System.Diagnostics.Stopwatch(true);
				let project = ProjectLoader.ReadProject(scope $"{sdl}/SdlDemo.tproj");
				let c = ProjectLoader.Make(sdl, null, null, project);
				defer { delete c; delete project; }
				c.Run();
				String kir = scope .();
				let lowered = c.Diags.ErrorCount == 0 && Lowering.WriteProgram(c, "SdlDemo", "Sdl.Program", kir);
				List<String> libs = scope .();
				List<String> bins = scope .();
				defer { ClearAndDeleteItems!(libs); ClearAndDeleteItems!(bins); }
				FrontEndBuild.LinkInputs(c, libs, bins);
				let ev = c.Table.Find("C.SDL_Event");
				// Windows: the mingw import library and the DLL; Linux (sdl2.linux.cimport): the system's
				// -lSDL2 and nothing to copy
#if BF_PLATFORM_WINDOWS
				let linkOk = libs.Count == 1 && libs[0].EndsWith("libSDL2.dll.a") && bins.Count == 1 && bins[0].EndsWith("SDL2.dll");
#else
				let linkOk = libs.Count == 1 && libs[0] == "SDL2" && bins.Count == 0;
#endif
				SelfTestCheck(lowered && c.Diags.ErrorCount == 0 && c.Diags.WarningCount == 0 && ev != null && ev.CBlob && ev.CSize == 56 && linkOk,
					scope $"frontend: m2-sdl validates and lowers with no diagnostics (SDL_Event a {(ev != null) ? ev.CSize : 0}-byte union reached by offset; {libs.Count} import library, {bins.Count} DLL to copy; {kir.Length} bytes of IR, {sw.Elapsed.TotalMilliseconds:0} ms)");
				if (c.Diags.Items.Count > 0)
					LogDiags(c);
			}

			// 1c. Project files that cannot work: a dependency cycle, a dependency that does not read.
			StringView[?] badProjects = .("cycle/A", "T0014", "baddep", "T0015");
			for (int k = 0; k < badProjects.Count; k += 2)
			{
				let folder = badProjects[k];
				let code = badProjects[k + 1];
				String root = scope $"{fixtures}/projects/{folder}";
				String path = scope .();
				ProjectLoader.FindProjectFile(root, path);
				let project = ProjectLoader.ReadProject(path);
				let c = ProjectLoader.Make(root, null, null, project);
				defer { delete c; delete project; }
				c.Run();
				CDiag hit = null;
				for (let d in c.Diags.Items)
					if (d.Code == code)
						hit = d;
				SelfTestCheck(hit != null && project != null, scope $"frontend: projects/{folder}: {code}{(hit != null) ? ": " : ""}{(hit != null) ? hit.Message : ""}");
				if (hit == null)
					LogDiags(c);
			}

			// 2. Broken samples: the expected diagnostic on the expected node and pin.
			{
				List<String> files = scope .();
				defer { ClearAndDeleteItems!(files); }
				for (let e in Directory.EnumerateFiles(scope $"{fixtures}/broken"))
				{
					let p = e.GetFilePath(.. new String());
					if (FormatNames.IsTypeFile(p))
						files.Add(p);
					else
						delete p;
				}
				files.Sort(scope (a, b) => a.CompareTo(b));
				SelfTestCheck(files.Count >= 6, scope $"frontend: {files.Count} broken samples found");
				for (let path in files)
				{
					String text = scope .();
					ReadFile(path, text);
					TypeDocument doc = scope .(Language);
					List<FormatError> errs = scope .();
					defer { ClearAndDeleteItems!(errs); }
					if (!TreadleCodec.ReadAll(text, doc, errs))
					{
						SelfTestCheck(false, scope $"frontend: {path} does not read");
						continue;
					}
					doc.FilePath.Set(path);
					List<TypeDocument> extra = scope .();
					extra.Add(doc);
					// the m2 cvars set gives the broken samples an extern C variable (T2219)
					let c = SelfTestCompile(samples, extra, scope $"{samples}/m2-frontend/src/cvars.cimport");
					defer delete c;
					String name = scope .();
					Path.GetFileNameWithoutExtension(path, name);
					for (var line in text.Split('\n'))
					{
						if (!line.StartsWith("# expect "))
							continue;
						var parts = line.Substring(9).Split(' ', .RemoveEmptyEntries);
						StringView node = parts.GetNext().GetValueOrDefault();
						StringView pin = parts.GetNext().GetValueOrDefault();
						StringView code = parts.GetNext().GetValueOrDefault();
						if (pin == "-")
							pin = "";
						// A declaration's problem names no node.
						if (node == "-")
							node = "";
						CDiag hit = null;
						for (let d in c.Diags.Items)
							if (d.Node == node && d.Pin == pin && d.Code == code && d.Severity != .Note)
								hit = d;
						SelfTestCheck(hit != null, scope $"frontend: {name}: {code} on node {node}{(pin.IsEmpty ? "" : ".")}{pin}{(hit != null) ? ": " : ""}{(hit != null) ? hit.Message : ""}");
						if (hit == null)
							LogDiags(c);
						// a Local Variable with no type: the message names the variable (the Problems row selects it
						// in the Outline), and the Sheet IR is never written for it: lowering anyway gives the internal
						// error T4003 naming the function and the variable, not an IR the back end cannot read
						if (name == "49-local-no-type" && hit != null)
						{
							SelfTestCheck(hit.Variable == "local:newVar" && hit.Message.StartsWith("newVar needs a type"),
								scope $"frontend: {name}: the T1078 row is on local:newVar ('{hit.Variable}': {hit.Message})");
							String ir = scope .();
							let lowered = Lowering.WriteProgram(c, "Broken", "Broken.Program", ir);
							CDiag internalErr = null;
							for (let d in c.Diags.Items)
								if (d.Code == "T4003")
									internalErr = d;
							SelfTestCheck(!lowered && internalErr != null && internalErr.Message.StartsWith("Broken.Program.Main: newVar has no type"),
								scope $"frontend: {name}: lowering a typeless local stops with T4003 ({(internalErr != null) ? internalErr.Message : "none"})");
							// the Problems row: its click selects newVar in the Outline and focuses the Type field
							let row = Treadle.Compiler.FrontEndBuild.ToDiagnostic(hit, .Validate);
							defer delete row;
							if (row.Path.IsEmpty)
								row.Path.Set(path);
							JumpToDiagnostic(row);
							SelfTestCheck(OutlineSel == .Local && mSelLocalName == "newVar" && mFocusTypeField,
								scope $"frontend: {name}: the Problems row selects newVar in the Outline and focuses its Type field ({OutlineSel}, '{mSelLocalName}')");
							mFocusTypeField = false;
							OutlineSel = .None;
						}
					}
				}
			}

			// 3. Sheet IR dumps against the fixtures.
			{
				String write = scope .();
				let writing = Environment.GetEnvironmentVariable("TREADLE_WRITE_FIXTURES", write) case .Ok && write == "1";
				// (fixture, program name, extra type files under fixtures/programs, entry type)
				StringView[?] progs = .("shooter", "Shooter", "", "App.Program", "pairs", "Pairs", "pairs", "App.PairsMain", "flow", "Flow", "flow", "App.FlowMain",
					"memory", "Memory", "memory", "Mem.MemMain", "results", "Results", "results", "Res.ResMain");
				for (int k = 0; k < progs.Count; k += 4)
				{
					List<TypeDocument> extra = scope .();
					defer { ClearAndDeleteItems!(extra); }
					if (!progs[k + 2].IsEmpty)
					{
						for (let e in Directory.EnumerateFiles(scope $"{fixtures}/programs/{progs[k + 2]}"))
						{
							let path = e.GetFilePath(.. scope String());
							if (!FormatNames.IsTypeFile(path))
								continue;
							String text = scope .();
							ReadFile(path, text);
							TypeDocument doc = new .();
							doc.FilePath.Set(path);
							List<FormatError> errs = scope .();
							defer { ClearAndDeleteItems!(errs); }
							TreadleCodec.ReadAll(text, doc, errs);
							extra.Add(doc);
						}
					}
					let c = SelfTestCompile(samples, extra);
					defer delete c;
					String dump = scope .();
					let lowered = Lowering.WriteProgram(c, progs[k + 1], progs[k + 3], dump);
					let clean = lowered && c.Diags.ErrorCount == 0;
					if (!clean)
						LogDiags(c);
					String file = scope $"{fixtures}/{progs[k]}.tir";
					if (writing)
					{
						File.WriteAllText(file, dump).IgnoreError();
						SelfTestCheck(clean, scope $"frontend: wrote {progs[k]}.tir ({dump.Length} bytes)");
						continue;
					}
					String expected = scope .();
					let have = ReadFile(file, expected);
					SelfTestCheck(have && expected == dump && clean, scope $"frontend: the Sheet IR of the {progs[k + 1]} program matches {progs[k]}.tir");
					if (have && expected != dump)
						Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] got:\n{dump}");
				}
			}

			// 3b. One program per milestone-2 feature: the feature's type files from
			//     samples/m2-frontend with a Main from fixtures/programs/m2, the Sheet IR against
			//     fixtures/<name>.tir, then built and run (Debug) against <name>.expected.
			{
				String write = scope .();
				let writing = Environment.GetEnvironmentVariable("TREADLE_WRITE_FIXTURES", write) case .Ok && write == "1";
				// (fixture, the m2 files it needs, its Main)
				StringView[?] feats = .(
					"m2-gate", "src/Gates.treadle", "Gates",
					"m2-doonce", "src/Once.treadle", "Once",
					"m2-don", "src/Counted.treadle", "Counted",
					"m2-flipflop", "src/Alternate.treadle", "Alternate",
					"m2-multigate", "src/Rotation.treadle", "Rotation",
					"m2-cast", "src/Casting.treadle src/Counter.treadle lib/Word.treadle", "Casting",
					"m2-foreach", "src/Range.treadle src/RangeEnumerator.treadle", "Range",
					"m2-switchtext", "src/Commands.treadle", "Commands",
					"m2-tuples", "src/Tuples.treadle", "Tuples",
					"m2-sctor", "src/Config.treadle", "Config",
					"m2-autoprop", "src/Counter.treadle", "Counter",
					"m2-newt", "src/Factory.treadle lib/Word.treadle", "Factory",
					"m2-allocator", "src/Arena.treadle lib/Word.treadle", "Arena",
					"m2-delegates", "src/Delegates.treadle src/IntFn.treadle src/Tally.treadle src/Animal.treadle src/Dog.treadle src/IScale.treadle", "Delegates",
					"m2-lambdas", "src/Lambdas.treadle src/IntFn.treadle", "Lambdas",
					"m2-nestedlambdas", "src/NestedLambdas.treadle src/IntFn.treadle", "NestedLambdas",
					"m2-nestedcapture", "src/NestedCapture.treadle src/IntFn.treadle", "NestedCapture",
					"m2-genericlambda", "src/Box.treadle", "Box",
					"m2-structdtor", "src/Structs.treadle src/Res.treadle src/ResHolder.treadle", "Structs",
					"m2-localarray", "src/LocalArrays.treadle src/Res.treadle", "LocalArrays",
					"m2-atomics", "src/Atomics.treadle", "Atomics",
					"m2-args", "src/Args.treadle", "Args",
					"m2-cinterop", "src/CInterop.treadle", "CInterop",
					"m2-extensions", "src/Gauge.treadle src/GaugeExt.treadle src/StringExt.treadle src/ListExt.treadle src/DivExt.treadle src/Extensions.treadle", "Extensions",
					"m2-events", "src/ClickHandler.treadle src/Button.treadle src/Meter.treadle src/Events.treadle", "Events",
					"m2-boundstructs", "src/Stepper.treadle src/StepperBox.treadle src/BoundStructs.treadle", "BoundStructs",
					"m2-arrayallocator", "src/ArrayArena.treadle src/Arena.treadle lib/Word.treadle", "ArrayArena",
					"m2-cvars", "src/CVars.treadle", "CVars",
					"m2-pureout", "src/PureOuts.treadle", "PureOuts",
					"m2-spancast", "src/SpanCasts.treadle", "SpanCasts",
					"m2-structmut", "src/Stepper.treadle src/StepperPair.treadle src/StructMut.treadle", "StructMut",
					"m2-mathexpr", "src/MathExprs.treadle src/Vec.treadle", "MathExprs",
					"m2-consts", "src/Consts.treadle src/Shade.treadle src/MathConsts.treadle", "Consts",
					"m2-thisvalue", "src/ThisValue.treadle", "ThisValue",
					"m2-trywiden", "src/TryWiden.treadle", "TryWiden",
					"m2-figure", "src/Figure.treadle", "Figure",
					"m2-int64args", "src/Int64Args.treadle", "Int64Args",
					"m2-controltext", "src/ControlText.treadle", "ControlText",
					"m2-terminating", "src/Terminating.treadle", "Terminating",
					"m2-switchmerge", "src/SwitchMerge.treadle", "SwitchMerge",
					"m2-hexin", "src/HexIn.treadle", "HexIn",
					"m2-reffield", "src/RefFields.treadle src/ThisValue.treadle", "RefFields",
					"m2-ownedlocal", "src/OwnedLocals.treadle src/Tracked.treadle", "OwnedLocals",
					"m2-structlocal", "src/StructLocals.treadle src/Res.treadle", "StructLocals",
					"m2-nullable", "src/Nullables.treadle", "Nullables",
					"m2-nullunwrap", "src/NullUnwrap.treadle", "NullUnwrap",
					"m2-simd", "src/SimdOps.treadle", "SimdOps",
					"m2-vectorfn", "src/VectorFns.treadle", "VectorFns");

				String work = scope .();
				Path.GetTempPath(work).IgnoreError();
				work.AppendF("/treadle-frontend-{}", (int)Platform.BfpSystem_GetTimeStamp() & 0xFFFFFF);
				defer { Directory.DelTree(work).IgnoreError(); }
				for (int k = 0; k < feats.Count; k += 3)
				{
					List<TypeDocument> docs = scope .();
					defer { ClearAndDeleteItems!(docs); }
					List<String> paths = scope .();
					defer { ClearAndDeleteItems!(paths); }
					for (let f in feats[k + 1].Split(' '))
						paths.Add(new String(scope $"{m2}/{f}"));
					paths.Add(new String(scope $"{fixtures}/programs/m2/{feats[k + 2]}Main.treadle"));
					for (let path in paths)
					{
						String text = scope .();
						ReadFile(path, text);
						TypeDocument doc = new .();
						doc.FilePath.Set(path);
						List<FormatError> errs = scope .();
						defer { ClearAndDeleteItems!(errs); }
						TreadleCodec.ReadAll(text, doc, errs);
						docs.Add(doc);
					}
					let c = ProjectLoader.Make("", null, null, null, docs);
					defer delete c;
					c.AddCImport(scope $"{m2}/src/libc.cimport", m2);
					c.AddCImport(scope $"{m2}/src/cstd.cimport", m2);
					// extern C variables (cvar): small.h's treadle_counter (its csource: m2-cvars.c
					// next to the fixture for the runner), errno and stdout through their functions;
					// on Linux cvars.linux.cimport with cvars.linux.cdecl (glibc spells both otherwise)
					String cvarsSet = scope .();
					CImportFile.ForPlatform(scope $"{m2}/src/cvars.cimport", cvarsSet);
					c.AddCImport(cvarsSet, m2);
					c.Run();
					if (feats[k] == "m2-nestedcapture")
						CheckChainedCaptures(c);
					String dump = scope .();
					let lowered = Lowering.WriteProgram(c, feats[k], scope $"Fx.{feats[k + 2]}Main", dump);
					let clean = lowered && c.Diags.ErrorCount == 0 && c.Diags.WarningCount == 0;
					if (!clean)
						LogDiags(c);
					if (feats[k] == "m2-mathexpr")
						CheckMathExpressions(dump);
					String file = scope $"{fixtures}/{feats[k]}.tir";
#if !BF_PLATFORM_WINDOWS
					// `<name>.linux.tir` holds a program whose IR differs on Linux (m2-cvars: errno and
					// stdout); writing makes one only where the Linux IR is not the base file's
					{
						let linuxFile = scope $"{fixtures}/{feats[k]}.linux.tir";
						String baseText = scope .();
						if (File.Exists(linuxFile) || (writing && ReadFile(file, baseText) && baseText != dump))
							file.Set(linuxFile);
					}
#endif
					if (writing)
					{
						File.WriteAllText(file, dump).IgnoreError();
						SelfTestCheck(clean, scope $"frontend: wrote {feats[k]}.tir ({dump.Length} bytes)");
					}
					else
					{
						String expected = scope .();
						let have = ReadFile(file, expected);
						SelfTestCheck(have && expected == dump && clean, scope $"frontend: the Sheet IR of {feats[k]} matches {feats[k]}.tir");
						if (have && expected != dump)
							Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] got:\n{dump}");
					}
					if (!File.Exists(scope $"{fixtures}/{feats[k]}.expected"))
						continue;
					Treadle.Backend.Testing.FixtureResult r = scope .();
					Treadle.Backend.Testing.FixtureRunner.Run(file, "Debug", work, r);
					SelfTestCheck(r.Passed, scope $"frontend: {feats[k]} runs (Debug, {r.BuildMs:0} ms build): {r.Detail}");
					if (!r.Passed)
						Notify.Log(.Info, "SelfTest", scope $"[SELFTEST]      stdout:\n{r.Stdout}\n      stderr:\n{r.Stderr}");
				}
			}

			// 3c. The C records of a `.cdecl` (TreadleCImport/fixtures/small.cdecl): a struct with its
			//     layout, an enum with its values, a function pointer typedef, a constant, a variadic
			//     function.
			{
				String small = scope $"{samples}/../../TreadleCImport/fixtures/small.cimport";
				let c = ProjectLoader.Make("", null, null);
				defer delete c;
				c.AddCImport(small, "");
				c.Run();
				let rect = c.Table.Find("C.small_rect");
				let kind = c.Table.Find("C.small_kind");
				let set = c.Table.Find("C.small");
				let cb = c.Table.Find("C.small_callback");
				let cbType = (cb != null) ? c.AliasTarget(cb) : null;
				bool rectOk = rect != null && rect.Kind == .Struct && !rect.CBlob && rect.CSize == 24 && rect.AllFields.Count == 3 &&
					rect.AllFields[0].COffset == 0 && rect.AllFields[1].COffset == 8 && rect.AllFields[2].COffset == 16 && rect.AllFields[2].Type.IsPointer;
				bool kindOk = kind != null && kind.Kind == .Enum && kind.FindCase("SMALL_RECT")?.CaseValue == 10 && kind.Underlying != null && kind.Underlying.Bits == 32;
				let version = set?.FindOwnMember("SMALL_VERSION");
				let register = set?.FindOwnMember("small_register");
				let printf = set?.FindOwnMember("small_printf");
				bool setOk = version != null && version.Const && version.Init == "3" && register != null && register.Params.Count == 3 &&
					register.Params[1].Type == cbType && printf != null && printf.Variadic;
				let counter = set?.FindOwnMember("treadle_counter");
				bool varOk = counter != null && counter.CVar && counter.Static && counter.Type == c.Table.Int32 && counter.CVarVia == null;
				SelfTestCheck(c.Diags.ErrorCount == 0 && rectOk && kindOk && cbType != null && cbType.Kind == .Function && setOk && varOk,
					scope $"frontend: small.cdecl's records declared: small_rect (24 bytes, fields at 0 8 16) {rectOk}, small_kind (SMALL_RECT = 10) {kindOk}, small_callback = {(cbType != null) ? (StringView)cbType.Name : "?"}, SMALL_VERSION, small_register(cb), small_printf variadic {setOk}, cvar treadle_counter {varOk}");
				if (c.Diags.Items.Count > 0)
					LogDiags(c);
			}

			// 5. The editor's own Validate (Shift+F7) on the samples, when the editor was opened on
			//    them: no problems; an input emptied in memory shows its error on the node.
			if (ProjectIndex.SamePath(mProjectRoot, samples))
			{
				for (let name in StringView[?]("Player", "Program", "Pair", "PairDemo"))
					OpenFile(scope $"{samples}/{name}.treadle");
				Validate(true);
				SelfTestCheck(mValidate != null && mValidate.Sheets > 0 && mValidate.ErrorCount == 0 && mValidate.WarningCount == 0,
					scope $"frontend: Validate in the editor: {mValidate?.ErrorCount} errors, {mValidate?.WarningCount} warnings in {mValidate?.Sheets} Sheets");
				if (mValidate != null)
					for (let m in mValidate.Messages)
						Notify.Log(.Info, "SelfTest", scope $"[SELFTEST]      {m.Where} {m.NodeKey}: {m.Text}");
				Sheet main = null;
				for (let d in mDocs)
					if (d.FilePath.EndsWith("Program.treadle"))
						main = d.FindSheet("m0001");
				let a2 = main?.Graph.FindNodeByKey("a2");
				a2?.FindInput("name")?.Default.Clear();
				if (main != null)
					main.Graph.Version++;
				Validate(true);
				bool onNode = false;
				if (mValidate != null)
					for (let m in mValidate.Messages)
						if (m.NodeKey == "a2" && m.IsError)
							onNode = true;
				SelfTestCheck(onNode, "frontend: Validate in the editor puts the error of an emptied input on its node (Problems row on a2)");
				a2?.FindInput("name")?.Default.Set("\"Hero\"");
			}
			else
				Notify.Log(.Info, "SelfTest", "[SELFTEST] frontend: the editor's Validate case runs when the editor is opened on the samples folder");

			// 4. The services as the editor uses them.
			{
				LanguageContext ctx = scope .();
				ProjectIndex index = scope .();
				index.Build(samples, FormatNames.TypeExt);
				ctx.Index = index;
				List<TypeDocument> open = scope .();
				defer { ClearAndDeleteItems!(open); }
				TypeDocument program = new .(ctx);
				program.Load(scope $"{samples}/Program.treadle").IgnoreError();
				open.Add(program);
				FrontEndServices fe = scope .(ctx, open);
				int problems = 0;
				for (let s in program.Sheets)
				{
					GraphValidator.Validate(s.Graph);
					problems += s.Graph.Errors.Count + s.Graph.Warnings.Count;
					for (let e in s.Graph.Errors)
						Notify.Log(.Info, "SelfTest", scope $"[SELFTEST]      {e.Message}");
				}
				SelfTestCheck(problems == 0, scope $"frontend: Validate's per-Sheet checks pass on Program.treadle ({problems} problems)");
				// Break it in memory: the Construct loses its argument; the error lands on the node.
				let main = program.Sheets[0].Graph;
				let a2 = main.FindNodeByKey("a2");
				a2?.FindInput("name")?.Default.Clear();
				main.Version++;
				GraphValidator.Validate(main);
				bool onNode = false;
				for (let e in main.Errors)
					if (a2 != null && e.NodeId == a2.Id && e.Message.Contains("needs a value"))
						onNode = true;
				SelfTestCheck(onNode, "frontend: an edit that leaves an input empty shows the error on its node");
				let types = fe.Types;
				SelfTestCheck(types.Family("Game.Player") == .Object && types.Family("String") == .String && types.Family("int") == .Int &&
					types.CanConvert("Game.Player", "Game.Core.Actor", null) == .Implicit && types.CanConvert("Game.Core.Actor", "Game.Player", null) == .Refused,
					"frontend: the type system answers from the type table (families, conversions)");
				List<String> cases = scope .();
				defer { ClearAndDeleteItems!(cases); }
				types.EnumMembers("Core.Option<int>", cases);
				SelfTestCheck(cases.Count == 2, scope $"frontend: enum members of Option<int>: {cases.Count}");
				List<Treadle.Catalog.NodeSpec> specs = scope .();
				defer { ClearAndDeleteItems!(specs); }
				fe.Catalog.Entries(specs);
				bool puts = false;
				bool takeDamage = false;
				for (let s in specs)
				{
					puts |= s.CallName == "C.libc.puts";
					takeDamage |= s.CallName == "Game.Player.TakeDamage";
				}
				List<Treadle.Catalog.NodeSpec> fit = scope .();
				defer { ClearAndDeleteItems!(fit); }
				fe.Catalog.EntriesFor("Game.Player", true, fit);
				SelfTestCheck(puts && takeDamage && fit.Count > 0 && fit.Count < specs.Count,
					scope $"frontend: the Node menu catalogue has {specs.Count} entries (puts, TakeDamage); {fit.Count} take a Player");
				SelfTestIncremental(fe, main, "samples");
				SelfTestDeclIncremental(samples, "samples", "Actor.treadle", "IDamageable", "Player.treadle", "");
			}

			// 6. Incremental Validate on m2-frontend (an edit inside a Sheet re-binds that Sheet).
			{
				LanguageContext ctx = scope .();
				ProjectIndex index = scope .();
				index.Build(m2, FormatNames.TypeExt);
				ctx.Index = index;
				List<TypeDocument> open = scope .();
				defer { ClearAndDeleteItems!(open); }
				TypeDocument program = new .(ctx);
				program.Load(scope $"{m2}/src/Program.treadle").IgnoreError();
				open.Add(program);
				FrontEndServices fe = scope .(ctx, open);
				SelfTestIncremental(fe, program.Sheets[0].Graph, "m2-frontend");
				SelfTestDeclIncremental(m2, "m2-frontend", "src/Animal.treadle", "IScale", "src/Dog.treadle;src/GaugeExt.treadle", "src/StringExt.treadle");

				// 7. Build lowers on its thread while Validate compiles on this one (they share the
				//    front end's lock, FrontEndBuild.Lock): 20 builds of m2-frontend, a full Validate
				//    in a loop during each, no crash, every build and every Validate clean.
				if (Treadle.Backend.Driver.ToolchainPaths.Found)
				{
					SelfTestBuildWhileValidate(fe, program.Sheets[0].Graph, m2);
					// 8. What makes a build link again besides the units (Compiler.md 9): a C source
					//    of a C import set (cvars' `csource counter.c`).
					SelfTestBuildInputs(m2, scope $"{m2}/src/counter.c");
					// 9. The project's kind and config flags (Graph-Format.md 5): fixtures/projects/config
					//    and fixtures/projects/library, built through the toolchain from a temp copy.
					SelfTestProjectKinds(fixtures);
				}
			}
			return true;
		}

		/// One build of `project` in `config` through the installed toolchain (Run when `forRun`);
		/// the job's report in `outReport`, its messages in `outMessages`.
		bool SelfTestBuildOnce(StringView project, StringView config, Treadle.Backend.Driver.BuildReport outReport, String outMessages = null, bool forRun = false)
		{
			BuildRequest request = .();
			request.Workspace = project;
			request.Config = config;
			request.Tool = "";
			BuildJob job = null;
			if (forRun)
			{
				RunRequest run = .();
				run.Build = request;
				if (Language.Toolchain.Run(run) case .Ok(let started))
					job = started;
			}
			else if (Language.Toolchain.Build(request) case .Ok(let started))
				job = started;
			if (job == null)
				return false;
			while (!job.Update())
				System.Threading.Thread.Sleep(1);
			let ok = job.Succeeded;
			if (let b = job as Treadle.Backend.Driver.BackendBuildJob)
			{
				outReport.UnitsCompiled = b.Report.UnitsCompiled;
				outReport.Linked = b.Report.Linked;
				outReport.ExePath.Set(b.Report.ExePath);
			}
			if (outMessages != null)
				for (let m in job.Messages)
					outMessages.AppendF("{}\n", m.Text);
			delete job;
			return ok;
		}

		/// `kind` and the config flags: the config fixture in Debug, Release and Profile (optimize 2
		/// with checks on: -O2 with the Debug runtime; its `define`s read by Build.IsDefined and
		/// Build.Value), a changed `optimize` recompiling the units of the same config; the library
		/// fixture builds a DLL / .so exporting its [Export] names, and Run refuses it.
		void SelfTestProjectKinds(StringView fixtures)
		{
			String temp = scope .();
			if (!SelfTestTemp.Get(temp))
			{
				SelfTestCheck(false, "frontend: project kinds: no temp folder");
				return;
			}
			String work = scope $"{temp}/treadle-kinds-{(int)Platform.BfpSystem_GetTimeStamp() & 0xFFFFFF}";
			String cfgProj = scope $"{work}/config";
			String libProj = scope $"{work}/library";
			CopyTree(scope $"{fixtures}/projects/config", cfgProj);
			CopyTree(scope $"{fixtures}/projects/library", libProj);
			defer DeleteTree(work);

			// the defines per config
			for (let cfg in StringView[?]("Debug", "Release", "Profile"))
			{
				Treadle.Backend.Driver.BuildReport rep = scope .();
				String msgs = scope .();
				let built = SelfTestBuildOnce(cfgProj, cfg, rep, msgs);
				String o = scope .();
				String e = scope .();
				int code = -1;
				if (built)
					code = Treadle.Backend.Driver.RunningProcess.Run(rep.ExePath, scope List<String>(), cfgProj, o, e, 30000);
				o.Replace("\r", "");
				let want = (cfg == "Profile") ? "profile build\n3\n" : "not a profile build\n\n";
				SelfTestCheck(built && code == 0 && o == want, scope $"frontend: config {cfg}: Build.IsDefined(\"PROFILE\") and Build.Value(\"LEVEL\") read its defines (exit {code}, output '{o}'{msgs})");
			}
			// Profile = optimize 2 + checks on: the units and the runtime at -O2, the runtime with TREADLE_DEBUG
			{
				String flags = scope .();
				String rt = scope .();
				File.ReadAllText(scope $"{cfgProj}/build/Profile/obj/flags.txt", flags, true).IgnoreError();
				File.ReadAllText(scope $"{cfgProj}/build/Profile/runtime/stamp.txt", rt, true).IgnoreError();
				String relRt = scope .();
				File.ReadAllText(scope $"{cfgProj}/build/Release/runtime/stamp.txt", relRt, true).IgnoreError();
				SelfTestCheck(flags.Contains("-O2") && flags.Contains("-g") && rt.Contains("-O2") && rt.Contains("-DTREADLE_DEBUG=1") && relRt.Contains("-O2") && relRt.Contains("-DNDEBUG"),
					"frontend: config Profile (optimize 2, checks on) compiles the units with -O2 -g and the Debug runtime at -O2; Release the release runtime");
			}
			// the flags are part of the cache keys: unchanged = nothing to do; optimize 2 -> 1 in the
			// same config compiles every unit and links again
			{
				Treadle.Backend.Driver.BuildReport rep = scope .();
				let again = SelfTestBuildOnce(cfgProj, "Profile", rep);
				let noop = again && rep.UnitsCompiled == 0 && !rep.Linked;
				String path = scope $"{cfgProj}/Config.tproj";
				String text = scope .();
				File.ReadAllText(path, text, true).IgnoreError();
				text.Replace("\toptimize 2\n\tchecks on\n\tdefine", "\toptimize 1\n\tchecks on\n\tdefine");
				File.WriteAllText(path, text).IgnoreError();
				Treadle.Backend.Driver.BuildReport rep2 = scope .();
				let rebuilt = SelfTestBuildOnce(cfgProj, "Profile", rep2);
				String flags = scope .();
				File.ReadAllText(scope $"{cfgProj}/build/Profile/obj/flags.txt", flags, true).IgnoreError();
				SelfTestCheck(noop && rebuilt && rep2.UnitsCompiled > 0 && rep2.Linked && flags.Contains("-O1"),
					scope $"frontend: an unchanged Profile build does nothing; optimize 2 -> 1 compiles the units again ({rep2.UnitsCompiled}) at -O1 and links");
			}
			// the library: a DLL / .so with the [Export] names and treadle_init / treadle_shutdown
			{
				Treadle.Backend.Driver.BuildReport rep = scope .();
				String msgs = scope .();
				let built = SelfTestBuildOnce(libProj, "Debug", rep, msgs);
				List<String> names = scope .();
				defer { ClearAndDeleteItems!(names); }
				if (built)
					ExportNames(rep.ExePath, names);
				String got = scope .();
				for (let n in names)
					got.AppendF("{}{}", got.IsEmpty ? "" : " ", n);
#if BF_PLATFORM_WINDOWS
				let ext = ".dll";
#else
				let ext = ".so";
#endif
				SelfTestCheck(built && rep.ExePath.EndsWith(ext) && got == "fl_sum fl_twice treadle_init treadle_shutdown",
					scope $"frontend: kind library builds {rep.ExePath} exporting [Export] functions only ({got}){msgs}");
				Treadle.Backend.Driver.BuildReport runRep = scope .();
				String runMsgs = scope .();
				let ran = SelfTestBuildOnce(libProj, "Debug", runRep, runMsgs, true);
				SelfTestCheck(!ran && runMsgs.Contains("nothing to run"), scope $"frontend: Run of a library project says there is nothing to run ({runMsgs})");
			}
		}

		/// Builds `project` (Debug) until it is up to date, then: a build with nothing changed
		/// compiles and links nothing; `csource` rewritten (the same text, a new time) links again
		/// without compiling a unit; the next build is a no-op again.
		void SelfTestBuildInputs(StringView project, StringView csource)
		{
			Treadle.Backend.Driver.BuildReport last = scope .();
			bool Build()
			{
				BuildRequest request = .();
				request.Workspace = project;
				request.Config = "Debug";
				request.Tool = "";
				BuildJob job = null;
				if (Language.Toolchain.Build(request) case .Ok(let started))
					job = started;
				if (job == null)
					return false;
				while (!job.Update())
					System.Threading.Thread.Sleep(1);
				let ok = job.Succeeded;
				if (let b = job as Treadle.Backend.Driver.BackendBuildJob)
				{
					last.UnitsCompiled = b.Report.UnitsCompiled;
					last.Linked = b.Report.Linked;
					last.TotalMs = b.Report.TotalMs;
				}
				delete job;
				return ok;
			}
			bool ok = Build();
			ok &= Build();
			let noop = !last.Linked && last.UnitsCompiled == 0;
			let noopMs = last.TotalMs;
			String text = scope .();
			ok &= File.ReadAllText(csource, text, true) case .Ok;
			// a later time than the link stamp's (some file systems keep two seconds)
			System.Threading.Thread.Sleep(20);
			ok &= File.WriteAllText(csource, text) case .Ok;
			ok &= Build();
			let relinked = last.Linked && last.UnitsCompiled == 0;
			let relinkMs = last.TotalMs;
			ok &= Build();
			let noopAgain = !last.Linked && last.UnitsCompiled == 0;
			SelfTestCheck(ok && noop && relinked && noopAgain,
				scope $"frontend: build inputs: a build of an up-to-date m2-frontend links nothing ({noopMs:0.0} ms in the back end), after counter.c (a csource) is written again it links without compiling a unit ({relinkMs:0.0} ms), then nothing again ({last.TotalMs:0.0} ms)");
		}

		/// The diagnostics of a compilation as sorted text (incremental and full runs report in a
		/// different order).
		static void DiagText(Compilation c, String outText)
		{
			List<String> lines = scope .();
			defer { ClearAndDeleteItems!(lines); }
			for (let d in c.Diags.Items)
				lines.Add(new String(scope $"{(int)d.Severity}|{(int)d.Stage}|{d.Code}|{d.Type}|{d.Member}|{d.Sheet}|{d.Node}|{d.Pin}|{d.Message}"));
			lines.Sort(scope (a, b) => String.Compare(a, b, false));
			for (let l in lines)
				outText.AppendF("{}\n", l);
		}

		/// Declaration-level incremental Validate (Compiler.md 9) on the project in `root`: each
		/// change is made to an open document (or opens one), Validated incrementally, then compiled
		/// from scratch; both must give the same diagnostics, and again after the change is undone.
		/// Times are the best of 5. `sigFile`: a type with a function taking an input (its signature
		/// changes, a field is added, `iface` is added to its implements lines); `otherFile` is
		/// opened and closed; `extFile` (optional): an extension of a core type that gets a function
		/// without a Sheet.
		void SelfTestDeclIncremental(StringView root, StringView what, StringView sigFile, StringView iface, StringView otherFile, StringView extFile)
		{
			LanguageContext ctx = scope .();
			ProjectIndex index = scope .();
			index.Build(root, FormatNames.TypeExt);
			ctx.Index = index;
			List<TypeDocument> open = scope .();
			defer { ClearAndDeleteItems!(open); }
			TypeDocument sigDoc = new .(ctx);
			sigDoc.Load(scope $"{root}/{sigFile}").IgnoreError();
			open.Add(sigDoc);
			TypeDocument extDoc = null;
			if (!extFile.IsEmpty)
			{
				extDoc = new .(ctx);
				extDoc.Load(scope $"{root}/{extFile}").IgnoreError();
				open.Add(extDoc);
			}
			FrontEndServices fe = scope .(ctx, open);
			fe.Incremental = false;
			let start = fe.Current;
			let startDiags = start.Diags.Items.Count;
			fe.Incremental = true;

			void Run(StringView name, delegate void() change, delegate void() undo)
			{
				double inc = double.MaxValue;
				double full = double.MaxValue;
				bool allIncremental = true;
				bool same = true;
				int types = 0;
				int sheets = 0;
				int fullTypes = 0;
				int fullSheets = 0;
				int diags = 0;
				for (int i < 5)
				{
					change();
					fe.Incremental = true;
					let a = fe.Current;
					inc = Math.Min(inc, fe.LastMs);
					allIncremental &= fe.LastWasIncremental;
					types = fe.LastTypes;
					sheets = fe.LastSheets;
					diags = a.Diags.Items.Count;
					String da = DiagText(a, .. scope .());
					fe.Incremental = false;
					sigDoc.Version++;
					let b = fe.Current;
					full = Math.Min(full, fe.LastMs);
					fullTypes = fe.LastTypes;
					fullSheets = fe.LastSheets;
					same &= da == DiagText(b, .. scope .());
					fe.Incremental = true;
					undo();
					String dc = DiagText(fe.Current, .. scope .());
					fe.Incremental = false;
					sigDoc.Version++;
					same &= dc == DiagText(fe.Current, .. scope .()) && fe.Current.Diags.Items.Count == startDiags;
					fe.Incremental = true;
				}
				SelfTestCheck(allIncremental && same && types < fullTypes,
					scope $"frontend: incremental Validate on {what} after {name}: {inc:0.00} ms ({types} of {fullTypes} types declared, {sheets} of {fullSheets} Sheets bound) against {full:0.00} ms for everything; {diags} diagnostics both ways, the same after undoing it");
			}

			// (b) A signature change: the first input of a function changes type.
			MemberDecl fn = null;
			for (let m in sigDoc.Members)
				if (fn == null && m.Kind == .Function && !m.Params.IsEmpty)
					fn = m;
			if (fn == null)
			{
				SelfTestCheck(false, scope $"frontend: {sigFile} has no function with an input");
				return;
			}
			String oldType = fn.Params[0].Type.ToString(.. scope .());
			Run(scope $"a signature change ({fn.Name} takes a double)", scope [&] () =>
				{
					delete fn.Params[0].Type;
					fn.Params[0].Type = TypeRef.Parse("double");
					sigDoc.Version++;
				}, scope [&] () =>
				{
					delete fn.Params[0].Type;
					fn.Params[0].Type = TypeRef.Parse(oldType);
					sigDoc.Version++;
				});

			// A member added.
			MemberDecl field = null;
			Run(scope $"a field added to {sigDoc.Header.Name}", scope [&] () =>
				{
					field = new .();
					field.Kind = .Field;
					field.Name.Set("mAddedField");
					field.Type = TypeRef.Parse("int");
					sigDoc.Members.Add(field);
					sigDoc.Version++;
				}, scope [&] () =>
				{
					sigDoc.Members.Remove(field);
					DeleteAndNullify!(field);
					sigDoc.Version++;
				});

			// A type header change.
			Run(scope $"{sigDoc.Header.Name} implements {iface}", scope [&] () =>
				{
					sigDoc.Header.Implements.Add(TypeRef.Parse(iface));
					sigDoc.Version++;
				}, scope [&] () =>
				{
					delete sigDoc.Header.Implements.PopBack();
					sigDoc.Version++;
				});

			// Files opened (the document stands for the file) and closed again (`;` between them).
			for (var file in otherFile.Split(';', .RemoveEmptyEntries))
			{
				TypeDocument other = null;
				Run(scope $"opening {file}", scope [&] () =>
					{
						other = new .(ctx);
						other.Load(scope $"{root}/{file}").IgnoreError();
						open.Add(other);
					}, scope [&] () =>
					{
						open.Remove(other);
						DeleteAndNullify!(other);
					});
			}

			// The first function of an extension of a core type returns a float (its members are
			// taken out of the core type and declared again; the core type itself is not).
			MemberDecl extFn = null;
			if (extDoc != null)
				for (let m in extDoc.Members)
					if (extFn == null && m.Kind == .Function && m.Returns != null)
						extFn = m;
			if (extFn != null)
			{
				String oldReturns = extFn.Returns.ToString(.. scope .());
				Run(scope $"{extDoc.Header.Name}.{extFn.Name} (an extension of a core type) returns a float", scope [&] () =>
					{
						delete extFn.Returns;
						extFn.Returns = TypeRef.Parse("float");
						extDoc.Version++;
					}, scope [&] () =>
					{
						delete extFn.Returns;
						extFn.Returns = TypeRef.Parse(oldReturns);
						extDoc.Version++;
					});
			}

			// (c) A new type (an untitled document in the namespace of `sigFile`).
			TypeDocument fresh = null;
			Run("a new type", scope [&] () =>
				{
					fresh = new .(ctx);
					List<FormatError> errors = scope .();
					defer { ClearAndDeleteItems!(errors); }
					TreadleCodec.ReadAll(scope $"# treadle 1\ntype AddedType class\n\tnamespace {sigDoc.Header.Namespace}\n\nfield mCount int\n", fresh, errors);
					open.Add(fresh);
				}, scope [&] () =>
				{
					open.Remove(fresh);
					DeleteAndNullify!(fresh);
				});
		}

		void SelfTestBuildWhileValidate(FrontEndServices fe, Graph g, StringView project)
		{
			int builds = 0;
			int validates = 0;
			int dirty = 0;
			let sw = scope System.Diagnostics.Stopwatch(true);
			fe.Incremental = false;
			for (int i < 20)
			{
				BuildRequest request = .();
				request.Workspace = project;
				request.Config = "Debug";
				request.Tool = "";
				BuildJob job = null;
				if (Language.Toolchain.Build(request) case .Ok(let started))
					job = started;
				if (job == null)
					break;
				while (!job.Update())
				{
					g.Version++;
					if (fe.Current.Diags.Items.Count != 0)
						dirty++;
					validates++;
				}
				if (job.Succeeded)
					builds++;
				delete job;
			}
			fe.Incremental = true;
			SelfTestCheck(builds == 20 && validates >= 20 && dirty == 0,
				scope $"frontend: Build lowering on its thread while Validate runs on the UI thread: {builds} of 20 builds of m2-frontend succeeded, {validates} full Validates during them, {dirty} with diagnostics ({sw.Elapsed.TotalMilliseconds:0} ms)");
		}

		/// Times a full compile of the workspace against the incremental one after an edit inside
		/// `g` (best of 5 each), and checks that both give the same diagnostics.
		void SelfTestIncremental(FrontEndServices fe, Graph g, StringView what)
		{
			double full = double.MaxValue;
			double inc = double.MaxValue;
			int fullDiags = 0;
			int incDiags = 0;
			int sheets = 0;
			int incSheets = 0;
			bool allIncremental = true;
			for (int i < 5)
			{
				fe.Incremental = false;
				g.Version++;
				let a = fe.Current;
				full = Math.Min(full, fe.LastMs);
				fullDiags = a.Diags.Items.Count;
				sheets = fe.LastSheets;
				fe.Incremental = true;
				g.Version++;
				let b = fe.Current;
				inc = Math.Min(inc, fe.LastMs);
				incDiags = b.Diags.Items.Count;
				incSheets = fe.LastSheets;
				allIncremental &= fe.LastWasIncremental;
			}
			fe.Incremental = true;
			SelfTestCheck(allIncremental && fullDiags == incDiags && incSheets == 1,
				scope $"frontend: incremental Validate on {what}: full {full:0.00} ms ({sheets} Sheets), after an edit in one Sheet {inc:0.00} ms ({incSheets} Sheet re-bound), {incDiags} diagnostics both ways");
		}
	}
}
#endif
