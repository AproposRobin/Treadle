// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using Treadle.Debug;
using Treadle.Document;
using Treadle.Graph;

namespace Treadle.Editor
{
	/// The `debug` self test (docs/Debugging.md): a copy of TreadleCore/samples/m1 opened as the
	/// project, a breakpoint (F9's path) on the node that calls Speak, Start Debugging (F5's path:
	/// build in Debug, lldb-dap), the stop on that node with `pet`'s value read, three Step Overs
	/// (through the For node), Step Into another type's Sheet (its Entry, with `this`) and Step Out, Continue to the exit (code 0,
	/// the program's output in Debug Output); then a copy of m1 with a second Delete of the same
	/// object through a local: the run stops on that Delete node with the runtime's double free
	/// message and exits with code 3 on Continue. Work files go to %TEMP%/treadle-debug-<stamp>.
	extension EditorApp
	{
		/// The path separator of the work files (the debugger matches the listing paths it reports).
		const char8 DbgSep = System.IO.Path.DirectorySeparatorChar;
#if BF_PLATFORM_WINDOWS
		const String M1ProgramFile = "M1\\Program.treadle";
#else
		const String M1ProgramFile = "M1/Program.treadle";
#endif
		String mDbgDir = new .() ~ delete _;
		String mDbgPrevRoot = new .() ~ delete _;
		Stopwatch mDbgWatch = new .() ~ delete _;
		List<String> mDbgSteps = new .() ~ DeleteContainerAndItems!(_);
		bool mDbgFailed;
		int32 mDbgLaunchBase;
		int64 mDbgDictRef;
		int64 mDbgListRef;
		/// The threads part (SelfTestDebugThreads.bf) runs after the windowed and library parts.
		const int cDbgThreads = 40;
		const int cDbgCleanup = 50;

		/// Waits for `cond` (true: go on). On timeout the test fails and goes to the cleanup.
		bool DbgWait(bool cond, StringView what, double seconds = 90)
		{
			if (cond)
			{
				mDbgWatch.Restart();
				return true;
			}
			if (mDbgWatch.Elapsed.TotalSeconds > seconds)
			{
				SelfTestCheck(false, scope $"debug: timed out waiting for {what} (state {Debug.State})");
				for (let l in Debug.Output)
					Notify.Log(.Info, "SelfTest", scope $"debug output: {l}");
				mDbgFailed = true;
				mSelfTestStep = cDbgCleanup - 1;
				return false;
			}
			mSelfTestStep--; // stay on this step (the tick adds one)
			return false;
		}

		/// Waits for the session F5 started to stop or end; fails at once when its build failed.
		bool DbgWaitLaunch(StringView what)
		{
			if (DebugLaunches == mDbgLaunchBase && !mDebugAfterBuild && (mBuild == null || !mBuild.Running))
			{
				SelfTestCheck(false, scope $"debug: the Debug build failed or did not launch ({what})");
				return DbgAbort();
			}
			return DbgWait(DebugLaunches > mDbgLaunchBase && (Debug.IsStopped || Debug.State == .Exited), what);
		}

		/// Ends the test early: straight to the cleanup.
		bool DbgAbort()
		{
			mDbgFailed = true;
			mSelfTestStep = cDbgCleanup - 1;
			return false;
		}

		Node DbgNode(StringView typeFile, StringView sheetName, StringView key, out Sheet outSheet)
		{
			outSheet = null;
			let doc = FindDoc(scope $"{mDbgDir}/{typeFile}") ?? OpenFile(scope $"{mDbgDir}/{typeFile}", false);
			if (doc == null)
				return null;
			outSheet = doc.FindSheetByName(sheetName);
			if (outSheet == null)
				return null;
			for (let n in outSheet.Graph.Nodes)
				if (n.Key == key)
					return n;
			return null;
		}

		bool DbgOutputHas(StringView text)
		{
			for (let l in Debug.Output)
				if (l.Contains(text))
					return true;
			return false;
		}

		bool SelfTestDebug()
		{
			switch (mSelfTestStep)
			{
			case 0:
				mDbgFailed = false;
				ClearAndDeleteItems!(mDbgSteps);
				String samples = scope .();
				if (!FindSamples(samples))
				{
					SelfTestCheck(false, "debug: the samples folder was not found (set TREADLE_SAMPLES)");
					return true;
				}
				if (!Debug.Adapter.Available)
				{
					SelfTestCheck(false, scope $"debug: {Debug.Adapter.Unavailable}");
					return true;
				}
				String temp = scope .();
				if (!SelfTestTemp.Get(temp))
					temp.Set(samples);
				mDbgDir.Set(scope $"{temp}/treadle-debug-{(int)Platform.BfpSystem_GetTimeStamp() & 0xFFFFFF}");
				mDbgDir.Replace('/', DbgSep);
				mDbgDir.Replace('\\', DbgSep);
				// m1 as it is, and m1 with a double Delete of the Box through the local `held`.
				for (let sub in StringView[?]("M1", "M1Fatal"))
				{
					Directory.CreateDirectory(scope $"{mDbgDir}{DbgSep}{sub}").IgnoreError();
					for (let e in Directory.EnumerateFiles(scope $"{samples}/m1"))
					{
						String name = scope .();
						e.GetFileName(name);
						File.Copy(e.GetFilePath(.. scope .()), scope $"{mDbgDir}{DbgSep}{sub}{DbgSep}{name}").IgnoreError();
					}
				}
				{
					String text = scope .();
					String path = scope $"{mDbgDir}{DbgSep}M1Fatal{DbgSep}Program.treadle";
					File.ReadAllText(path, text, true).IgnoreError();
					String outText = scope .();
					bool nodesAdded = false;
					for (let line in text.Split('\n'))
					{
						if (line == "local pet Zoo.Animal")
						{
							outText.Append("local pet Zoo.Animal\nlocal held Zoo.Box<int>\n");
							continue;
						}
						if (line.StartsWith("wire ") && !nodesAdded)
						{
							outText.Append("node e1 Delete\nnode e2 Set local:held\nnode e3 Get local:held\n");
							nodesAdded = true;
						}
						if (line == "wire c5.then c3.in")
						{
							outText.Append("wire c5.then e2.in\nwire c2.object e2.value\nwire e2.then c3.in\n");
							continue;
						}
						if (line == "wire c3.then c6.in")
						{
							outText.Append("wire c3.then e1.in\nwire e3.value e1.object\nwire e1.then c6.in\n");
							continue;
						}
						outText.AppendF("{}\n", line);
					}
					outText.TrimEnd();
					outText.Append('\n');
					File.WriteAllText(path, outText).IgnoreError();
					SelfTestCheck(nodesAdded, "debug: the double-Delete copy of m1 is written");
				}
#if BF_PLATFORM_WINDOWS
				// the M1 copy builds with `debugFormat both` (DWARF for lldb-dap plus a PDB): the session
				// below runs on its DWARF; M1Fatal keeps the default (dwarf)
				{
					String path = scope $"{mDbgDir}{DbgSep}M1{DbgSep}M1.tproj";
					String text = scope .();
					File.ReadAllText(path, text, true).IgnoreError();
					let added = text.Contains("config Debug\n");
					text.Replace("config Debug\n", "config Debug\n\tdebugFormat both\n");
					File.WriteAllText(path, text).IgnoreError();
					SelfTestCheck(added, "debug: the M1 copy's Debug config sets debugFormat both");
				}
#endif
				// m3-core: the summaries of a String, a List<String> and a Dictionary<String,int>
				Directory.CreateDirectory(scope $"{mDbgDir}{DbgSep}M3Core").IgnoreError();
				for (let e in Directory.EnumerateFiles(scope $"{samples}/m3-core"))
				{
					String name = scope .();
					e.GetFileName(name);
					File.Copy(e.GetFilePath(.. scope .()), scope $"{mDbgDir}{DbgSep}M3Core{DbgSep}{name}").IgnoreError();
				}
				DbgKindsSetup(samples);
				mDbgPrevRoot.Set(mProjectRoot);
				OpenProjectNow(scope $"{mDbgDir}{DbgSep}M1",scope $"{mDbgDir}{DbgSep}M1{DbgSep}Program.treadle", true);
				mDbgWatch.Restart();
				mSelfTestWait = 3;
				return false;
			case 1:
				// F9's path: a breakpoint on b7 (Call Zoo.Animal.Speak()); a value node refuses one.
				let speak = DbgNode(M1ProgramFile, "Main", "b7", let sheet);
				if (speak == null)
				{
					SelfTestCheck(false, "debug: node b7 of Zoo.Program.Main was not found");
					return DbgAbort();
				}
				OpenTab(sheet);
				ToggleBreakpoint(sheet, speak);
				SelfTestCheck(Debug.HasBreakpoint(sheet.Doc.FilePath, sheet.Key, "b7"), "debug: F9 sets a breakpoint on node b7 (Call Zoo.Animal.Speak())");
				let getPet = DbgNode(M1ProgramFile, "Main", "b6", ?);
				String why = scope .();
				SelfTestCheck(getPet != null && !CanHaveBreakpoint(getPet, why), scope $"debug: the value node b6 (Get pet) takes no breakpoint: {why}");
				// Saved per project: read back from settings.json.
				let saved = Settings.Project(mProjectRoot).Get("breakpoints");
				SelfTestCheck(saved != null && saved.Type == .Array && saved.Items.Count == 1 && saved.Items[0].GetString("file") == "Program.treadle" && saved.Items[0].GetString("node") == "b7",
					"debug: the breakpoint is kept in the project's settings (file relative to the project)");
				mDbgLaunchBase = DebugLaunches;
				StartDebugging();
				SelfTestCheck(mBuild != null && mBuild.Running, "debug: F5 starts a Debug build through the toolchain");
				mDbgWatch.Restart();
				return false;
			case 2:
				if (!DbgWaitLaunch("the stop on b7"))
					return false;
				let f = Debug.CurrentFrame;
				SelfTestCheck(Debug.IsStopped && Debug.Reason == .Breakpoint && f != null && f.NodeKey == "b7" && f.SheetName == "Zoo.Program.Main",
					scope $"debug: stopped on node b7 of Zoo.Program.Main ({Debug.Reason}, {(f != null) ? f.SheetName : ""} {(f != null) ? f.NodeKey : ""})");
				if (!Debug.IsStopped)
					return DbgAbort();
				SelfTestCheck(CurrentMethod != null && CurrentMethod.Name == "Main" && DebugStopNode(CurrentMethod) != 0, "debug: the Main Sheet is in front with the stopped node marked");
				bool callerDimmed = false;
				for (let fr in Debug.Frames)
					if (!fr.IsUser && fr.Name.StartsWith("main"))
						callerDimmed = true;
				SelfTestCheck(Debug.Frames.Count >= 2 && Debug.Frames[0].IsUser && callerDimmed, scope $"debug: the call stack has the Sheet frame and the C main below it ({Debug.Frames.Count} frames)");
				DebugVariable pet = null;
				for (let v in Debug.Locals)
					if (v.Kind == .Local && v.Label == "pet")
						pet = v;
				// the debug info names the slot after the local (no `s0`)
				bool slotIds = false;
				for (let v in Debug.Locals)
					if (v.Name.Length >= 2 && v.Name[0] == 's' && v.Name[1].IsDigit)
						slotIds = true;
				SelfTestCheck(pet != null && pet.Name == "pet" && !slotIds && pet.Type == "Zoo.Animal" && pet.Value.StartsWith("Zoo.Dog"),
					scope $"debug: Locals has pet by its own name, no slot ids: Zoo.Animal = {(pet != null) ? pet.Value : "(missing)"}");
				// The receiver pin of b7 shows the same value (a bubble on the canvas).
				let node = DbgNode(M1ProgramFile, "Main", "b7", let s2);
				String pv = scope .();
				Pin recv = null;
				if (node != null)
					for (let p in node.Inputs)
						if (p.Role == .Receiver)
							recv = p;
				let hasValue = recv != null && DebugPinValue(s2, recv, pv);
				SelfTestCheck(hasValue && pv.StartsWith("Zoo.Dog"), scope $"debug: the receiver pin of b7 shows {pv}");
				var flowPin = false;
				for (let v in Debug.Locals)
					if (v.Kind == .Pin && v.Name == "a2.object" && v.Value.StartsWith("Zoo.Dog"))
						flowPin = true;
				SelfTestCheck(flowPin, "debug: the pin value a2.object (Construct's object) is listed");
				Debug.Evaluate("pet");
				return false;
			case 3:
				if (!DbgWait(!Debug.EvalPending, "Evaluate pet"))
					return false;
				SelfTestCheck(!Debug.EvalFailed && Debug.EvalResult.StartsWith("Zoo.Dog"), scope $"debug: Evaluate pet = {Debug.EvalResult} ({Debug.EvalType})");
				Debug.StepOver();
				return false;
			case 4, 5, 6:
				if (!DbgWait(Debug.IsStopped || Debug.State == .Exited, "a step to stop"))
					return false;
				let f = Debug.CurrentFrame;
				mDbgSteps.Add(new String((f != null) ? f.NodeKey : "?"));
				if (f == null || Debug.Reason != .Step)
				{
					SelfTestCheck(false, scope $"debug: Step Over {mDbgSteps.Count} stopped ({Debug.Reason}, state {Debug.State})");
					return DbgAbort();
				}
				if (mSelfTestStep < 6)
					Debug.StepOver();
				else
				{
					String steps = scope .();
					for (let s in mDbgSteps)
						steps.AppendF("{}{}", (@s.Index > 0) ? " -> " : "", s);
					bool flowOnly = true;
					for (let s in mDbgSteps)
					{
						let n = Debug.Program?.FindNode("Zoo.Program", "m0001", s);
						if (n == null || !n.Flow)
							flowOnly = false;
					}
					// b9, then the loop's increment and test on the For (b1), then the Branch b3
					let loop = DbgNode(M1ProgramFile, "Main", "b1", ?);
					SelfTestCheck(mDbgSteps.Count == 3 && mDbgSteps[0] == "b9" && mDbgSteps[1] == "b1" && mDbgSteps[2] == "b3" && loop != null && loop.Kind == .For && flowOnly,
						scope $"debug: three Step Overs from b7 go through the For: b7 -> {steps}");
					Debug.Continue();
				}
				return false;
			case 7:
				if (!DbgWait(Debug.IsStopped || Debug.State == .Exited, "the second stop on b7"))
					return false;
				let f = Debug.CurrentFrame;
				DebugVariable pet = null;
				for (let v in Debug.Locals)
					if (v.Label == "pet")
						pet = v;
				SelfTestCheck(f != null && f.NodeKey == "b7" && pet != null && pet.Value.StartsWith("Zoo.Bird"),
					scope $"debug: Continue stops on b7 again with pet = {(pet != null) ? pet.Value : "(missing)"}");
				Debug.StepInto();
				return false;
			case 8, 12:
				if (!DbgWait(Debug.IsStopped || Debug.State == .Exited, "Step Into"))
					return false;
				mSelfTestWait = 3; // the other type's tab comes to the front
				return false;
			case 9:
				let f = Debug.CurrentFrame;
				SelfTestCheck(f != null && f.SheetName == "Zoo.Bird.Speak" && f.NodeKey == "b1" && Doc != null && Doc.FilePath.EndsWith("Bird.treadle"),
					scope $"debug: Step Into on b7 stops on Zoo.Bird.Speak's Entry (node {(f != null) ? f.NodeKey : ""}) and opens Bird's Sheet ({(Doc != null) ? Doc.FilePath : ""})");
				DebugVariable bird = null;
				for (let v in Debug.Locals)
					if (v.Kind == .This)
						bird = v;
				SelfTestCheck(bird != null && bird.Value.StartsWith("Zoo.Bird"), scope $"debug: on Speak's Entry Locals has this = {(bird != null) ? bird.Value : "(missing)"}");
				Debug.StepOut();
				return false;
			case 10:
				if (!DbgWait(Debug.IsStopped || Debug.State == .Exited, "Step Out"))
					return false;
				let f = Debug.CurrentFrame;
				SelfTestCheck(f != null && f.SheetName == "Zoo.Program.Main", scope $"debug: Step Out returns to Zoo.Program.Main (node {(f != null) ? f.NodeKey : ""})");
				Debug.StepOver();
				return false;
			case 11:
				if (!DbgWait(Debug.IsStopped || Debug.State == .Exited, "Step Over to b9"))
					return false;
				let f = Debug.CurrentFrame;
				SelfTestCheck(f != null && f.NodeKey == "b9", scope $"debug: Step Over from b7 stops on b9 ({(f != null) ? f.NodeKey : ""})");
				// b9 reads b8 (Call Legs(), a value node): Step Into goes into Legs.
				Debug.StepInto();
				return false;
			case 13:
				let f = Debug.CurrentFrame;
				DebugVariable self = null;
				for (let v in Debug.Locals)
					if (v.Kind == .This)
						self = v;
				SelfTestCheck(f != null && f.SheetName == "Zoo.Animal.Legs" && Doc != null && Doc.FilePath.EndsWith("Animal.treadle"),
					scope $"debug: Step Into on b9 goes into the value node's call Zoo.Animal.Legs (node {(f != null) ? f.NodeKey : ""}) in Animal's Sheet");
				SelfTestCheck(self != null && self.Value.StartsWith("Zoo.Bird") && self.Type == "Zoo.Animal", scope $"debug: Locals has this (the Receiver): {(self != null) ? self.Type : ""} = {(self != null) ? self.Value : "(missing)"}");
				Debug.StepOut();
				return false;
			case 14:
				if (!DbgWait(Debug.IsStopped || Debug.State == .Exited, "Step Out of Legs"))
					return false;
				let f = Debug.CurrentFrame;
				SelfTestCheck(f != null && f.SheetName == "Zoo.Program.Main", scope $"debug: Step Out of Legs returns to Zoo.Program.Main (node {(f != null) ? f.NodeKey : ""})");
				// The breakpoint off (F9 again), then Continue to the end.
				let speak = DbgNode(M1ProgramFile, "Main", "b7", let sheet);
				if (speak != null)
					ToggleBreakpoint(sheet, speak);
				SelfTestCheck(Debug.Breakpoints.IsEmpty, "debug: F9 again removes the breakpoint");
				Debug.Continue();
				return false;
			case 15:
				if (!DbgWait(Debug.State == .Exited, "the program to exit"))
					return false;
				SelfTestCheck(Debug.ExitCode == 0, scope $"debug: the program exits with code {Debug.ExitCode}");
				SelfTestCheck(DbgOutputHas("Woof") && DbgOutputHas("Tweet") && DbgOutputHas("goodbye from Defer") && DbgOutputHas("an animal is freed"),
					"debug: the program's output is in Debug Output (Woof, Tweet, goodbye from Defer, an animal is freed)");
#if BF_PLATFORM_WINDOWS
				{
					String fmt = scope .();
					File.ReadAllText(scope $"{mDbgDir}{DbgSep}M1{DbgSep}build{DbgSep}Debug{DbgSep}debug-format.txt", fmt, true).IgnoreError();
					SelfTestCheck(fmt == "both" && File.Exists(scope $"{mDbgDir}{DbgSep}M1{DbgSep}build{DbgSep}Debug{DbgSep}M1.pdb"),
						scope $"debug: the session above ran on a debugFormat both build (debug-format.txt '{fmt}', M1.pdb next to the exe)");
				}
#endif
				// The fatal case: no breakpoint, the runtime stops the program.
				OpenProjectNow(scope $"{mDbgDir}{DbgSep}M1Fatal", scope $"{mDbgDir}{DbgSep}M1Fatal{DbgSep}Program.treadle", true);
				mSelfTestWait = 3;
				return false;
			case 16:
				Debug.ClearBreakpoints();
				mDbgLaunchBase = DebugLaunches;
				StartDebugging();
				SelfTestCheck(mBuild != null && mBuild.Running, "debug: F5 builds the double-Delete copy");
				mDbgWatch.Restart();
				return false;
			case 17:
				if (!DbgWaitLaunch("the fatal stop"))
					return false;
				mSelfTestWait = 3;
				return false;
			case 18:
				let f = Debug.CurrentFrame;
				SelfTestCheck(Debug.IsStopped && Debug.Reason == .Fatal && f != null && f.NodeKey == "e1" && f.NodeTitle.StartsWith("Delete"),
					scope $"debug: the double free stops on the Delete node e1 ({Debug.Reason}, {(f != null) ? f.NodeKey : ""} {(f != null) ? f.NodeTitle : ""})");
				SelfTestCheck(Debug.StopMessage.Contains("double free") && Debug.StopMessage.Contains("node e1"), scope $"debug: the runtime's message: {Debug.StopMessage}");
				SelfTestCheck(CurrentMethod != null && DebugStopNode(CurrentMethod) != 0, "debug: the Sheet with the Delete node is in front, the node marked");
				Debug.Continue();
				return false;
			case 19:
				if (!DbgWait(Debug.State == .Exited, "the fatal program to exit"))
					return false;
				SelfTestCheck(Debug.ExitCode == 3, scope $"debug: after the fatal error the program exits with code {Debug.ExitCode}");
				SelfTestCheck(DbgOutputHas("fatal: double free"), "debug: the fatal line is in Debug Output");
				// The summaries: m3-core stopped on d3 (WriteLine of the first line), after the
				// dictionary is filled and the distinct words are sorted.
				OpenProjectNow(scope $"{mDbgDir}{DbgSep}M3Core", scope $"{mDbgDir}{DbgSep}M3Core{DbgSep}Program.treadle", true);
				mSelfTestWait = 3;
				return false;
			case 20:
				let wl = DbgNode(scope $"M3Core{DbgSep}Program.treadle", "Main", "d3", let m3Sheet);
				if (wl == null)
				{
					SelfTestCheck(false, "debug: node d3 of M3.Program.Main was not found");
					return DbgAbort();
				}
				OpenTab(m3Sheet);
				Debug.ClearBreakpoints();
				Debug.AddBreakpoint(m3Sheet.Doc.FilePath, m3Sheet.Key, "d3");
				mDbgLaunchBase = DebugLaunches;
				StartDebugging();
				SelfTestCheck(mBuild != null && mBuild.Running, "debug: F5 builds the copy of m3-core in Debug");
				mDbgWatch.Restart();
				return false;
			case 21:
				if (!DbgWaitLaunch("the stop on d3 of m3-core"))
					return false;
				let f = Debug.CurrentFrame;
				SelfTestCheck(Debug.IsStopped && f != null && f.NodeKey == "d3" && f.SheetName == "M3.Program.Main",
					scope $"debug: m3-core stopped on d3 ({Debug.Reason}, {(f != null) ? f.SheetName : ""} {(f != null) ? f.NodeKey : ""})");
				if (!Debug.IsStopped)
					return DbgAbort();
				for (let v in Debug.Locals)
					Notify.Log(.Info, "SelfTest", scope $"m3-core local {v.Label}: {v.Type} = {v.Value}");
				DebugVariable counts = null, words = null, distinct = null, line = null;
				for (let v in Debug.Locals)
				{
					if (v.Label == "counts")
						counts = v;
					else if (v.Name == "a3.object")
						words = v;
					else if (v.Name == "b7.object")
						distinct = v;
					else if (v.Name == "d1.object")
						line = v;
				}
				StringView cv = (counts != null) ? counts.Value : "(missing)";
				SelfTestCheck(counts != null && counts.Type == "Core.Dictionary<Core.String,int>" && cv.StartsWith('{') && cv.Contains("\"the\": 3") && cv.Contains("\"lazy\": 1") && cv.EndsWith(", ...} (10)") && counts.ChildrenRef != 0,
					scope $"debug: Locals shows the Dictionary<String,int> counts as {{k: v, ...}} (n): {cv}");
				StringView wv = (words != null) ? words.Value : "(missing)";
				SelfTestCheck(words != null && wv.StartsWith("[\"the\", \"quick\", \"brown\", \"fox\", \"jumps\", \"over\", \"the\", \"lazy\", ...] (13)"),
					scope $"debug: Locals shows the List<String> a3.object as [a, b, ...] (n): {wv}");
				StringView dv = (distinct != null) ? distinct.Value : "(missing)";
				SelfTestCheck(distinct != null && dv.StartsWith("[\"the\", \"fox\", ") && dv.EndsWith("] (10)") && distinct.ChildrenRef != 0,
					scope $"debug: Locals shows the sorted List<String> b7.object: {dv}");
				StringView lv = (line != null) ? line.Value : "(missing)";
				SelfTestCheck(line != null && lv == "\"13 words, 10 different\"", scope $"debug: Locals shows the String d1.object as its text: {lv}");
				// the bubble on WriteLine's input shows the same text
				String pv = scope .();
				bool pinShown = false;
				let wl = DbgNode(scope $"M3Core{DbgSep}Program.treadle", "Main", "d3", let m3Sheet);
				if (wl != null)
				for (let p in wl.Inputs)
					if (p.Kind == .Value && DebugPinValue(m3Sheet, p, pv))
						pinShown = pv == "\"13 words, 10 different\"";
				SelfTestCheck(pinShown, scope $"debug: the input pin of d3 shows the String's text ({pv})");
				mDbgDictRef = (counts != null) ? counts.ChildrenRef : 0;
				mDbgListRef = (distinct != null) ? distinct.ChildrenRef : 0;
				if (mDbgDictRef == 0 || mDbgListRef == 0)
					return DbgAbort();
				Debug.GetChildren(mDbgDictRef);
				Debug.GetChildren(mDbgListRef);
				mDbgWatch.Restart();
				return false;
			case 22:
				let dk = Debug.GetChildren(mDbgDictRef);
				let lk = Debug.GetChildren(mDbgListRef);
				if (!DbgWait(dk != null && lk != null, "the elements of counts and b7.object"))
					return false;
				DebugVariable the = null;
				for (let k in dk)
					if (k.Label == "[\"the\"]")
						the = k;
				SelfTestCheck(dk.Count == 10 && the != null && the.Value == "3" && the.Type == "int",
					scope $"debug: counts expands to its 10 entries, [\"the\"] = {(the != null) ? the.Value : "(missing)"} ({dk.Count} entries)");
				SelfTestCheck(lk.Count == 10 && lk[0].Label == "[0]" && lk[0].Value == "\"the\"" && lk[1].Value == "\"fox\"" && lk[0].Type == "Core.String",
					scope $"debug: b7.object expands to its 10 elements, [0] = {(lk.Count > 0) ? lk[0].Value : "(none)"}");
				Debug.Stop();
				mSelfTestWait = 10; // the session closes before the windowed copy (SelfTestDebugKinds.bf)
				return false;
			case 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39:
				return SelfTestDebugKinds();
			case 40, 41, 42, 43, 44:
				return SelfTestDebugThreads();
			case 45, 46, 47, 48, 49:
				return SelfTestDebugVectors(); // SelfTestDebugVectors.bf
			case cDbgCleanup:
				if (mBuild != null && mBuild.Running)
				{
					mSelfTestStep--; // a build is not stopped halfway
					return false;
				}
				if (Debug.IsActive)
					Debug.Stop();
				Debug.ClearBreakpoints();
				SaveBreakpoints();
				// Back to the project that was open; the test's projects leave no settings behind.
				OpenProjectNow(mDbgPrevRoot, "", true);
				if (mDbgHost != null)
				{
					mDbgHost.Kill();
					mDbgHost.Wait(5000);
					DeleteAndNullify!(mDbgHost);
				}
				for (let sub in StringView[?]("M1", "M1Fatal", "M3Core", "Win", "Lib", "Threads"))
				{
					String root = scope $"{mDbgDir}{DbgSep}{sub}";
					ForgetRecentProject(root);
					String key = scope .(root);
					key.ToLower();
					Settings.Root?.Get("projects")?.Remove(key);
				}
				Settings.Save();
				mSelfTestWait = 30; // lldb-dap and the program end
				return false;
			case cDbgCleanup + 1:
				DeleteTree(mDbgDir);
				if (mDbgFailed)
					Notify.Log(.Info, "SelfTest", "[SELFTEST] debug: stopped early (see the failure above)");
				return true;
			default:
				return true;
			}
		}

		/// Captures: `debugstop` starts debugging the open project with a breakpoint on the node
		/// TREADLE_DEBUG_BREAK names (`<type file>,<Sheet name>,<node id>`, not saved) and finishes
		/// once the program stopped there; the editor stays open on the stop.
		bool SelfTestDebugStop()
		{
			switch (mSelfTestStep)
			{
			case 0:
				String spec = scope .();
				Environment.GetEnvironmentVariable("TREADLE_DEBUG_BREAK", spec).IgnoreError();
				var parts = spec.Split(',');
				StringView file = parts.GetNext().GetValueOrDefault();
				StringView sheetName = parts.GetNext().GetValueOrDefault();
				StringView key = parts.GetNext().GetValueOrDefault();
				let doc = OpenFile(scope $"{mProjectRoot}{DbgSep}{file}", false);
				let sheet = doc?.FindSheetByName(sheetName);
				if (sheet == null)
				{
					SelfTestCheck(false, scope $"debugstop: no Sheet {sheetName} in {file} (TREADLE_DEBUG_BREAK)");
					return true;
				}
				OpenTab(sheet);
				mDebugBpRoot.Set(mProjectRoot); // not loaded from (or saved to) settings
				Debug.ClearBreakpoints();
				Debug.AddBreakpoint(doc.FilePath, sheet.Key, key);
				mDbgLaunchBase = DebugLaunches;
				StartDebugging();
				mDbgWatch.Restart();
				return false;
			default:
				if (DebugLaunches > mDbgLaunchBase && Debug.IsStopped)
				{
					SelfTestCheck(true, scope $"debugstop: stopped at {Debug.CurrentFrame?.SheetName} {Debug.CurrentFrame?.NodeKey}");
					return true;
				}
				if (mDbgWatch.Elapsed.TotalSeconds > 90 || Debug.State == .Exited && DebugLaunches > mDbgLaunchBase)
				{
					SelfTestCheck(false, "debugstop: the program did not stop");
					return true;
				}
				mSelfTestStep = 0;
				return false;
			}
		}
	}
}
#endif
