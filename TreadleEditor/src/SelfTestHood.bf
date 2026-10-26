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
	/// The `hood` self test (docs/Debugging.md, "Under the hood"), on a copy of TreadleCore/samples/m1 with a
	/// fixture struct `Zoo.Pad` (bool, int, int16) added:
	///  - Layout: Zoo.Pad's offsets 0 / 8 / 16 with 7 and 6 bytes of padding, size 24; Zoo.Dog's vtable
	///    pointer at 0 and the inherited mLegs at 8 (size 16); Zoo.Box<int>; Core.Option<int>'s tag and
	///    payload; a packed struct from type records;
	///  - the lives-in badges of Main's Construct and Local nodes, the Storage of a field and a local;
	///  - a debug session stopped on c9 of Main: the Disassembly of Main grouped by node (its Sheet IR and
	///    LLVM IR), the live instruction, the Memory of the pin c6.object (a Local Box<Point> followed to the
	///    object: mValue.X = 3, mValue.Y = 4), Hex mode, and an unreadable address reported, not crashed on.
	/// With TREADLE_CAPTURE_DIR set it writes the pictures of docs/Debugging.md itself (`hood-*.bmp`).
	extension EditorApp
	{
		String mHoodDir = new .() ~ delete _;
		String mHoodPrevRoot = new .() ~ delete _;
		Stopwatch mHoodWatch = new .() ~ delete _;
		int32 mHoodLaunchBase;
		int32 mHoodReads;
		double mHoodHoldUntil;
		const int cHoodCleanup = 40;

		const String cHoodPad = "# treadle 1\ntype Pad struct\n\tnamespace Zoo\n\tdoc \"Layout fixture: a bool, an int and an int16, so the layout has padding after the bool and at the end.\"\n\nfield Flag bool\n\nfield Count int\n\nfield Small int16\n";

		bool HoodWait(bool cond, StringView what, double seconds = 120)
		{
			if (cond)
			{
				mHoodWatch.Restart();
				return true;
			}
			if (mHoodWatch.Elapsed.TotalSeconds > seconds)
			{
				SelfTestCheck(false, scope $"hood: timed out waiting for {what}");
				mSelfTestStep = cHoodCleanup - 1;
				return false;
			}
			mSelfTestStep--;
			return false;
		}

		/// With TREADLE_CAPTURE_DIR: asks the host for a picture of the next frame (`<dir>/<name>.bmp`) and
		/// stays on the step about 1.5 s; true at once otherwise.
		bool HoodCapture(StringView name, StringView focus = default)
		{
			String dir = scope .();
			if (!(Environment.GetEnvironmentVariable("TREADLE_CAPTURE_DIR", dir) case .Ok) || dir.IsEmpty)
				return true;
			if (!focus.IsEmpty)
				Panels.Focus(focus);
			let now = ImGui.Gui.igGetTime();
			if (mHoodHoldUntil == 0)
			{
				mHoodHoldUntil = now + 1.5;
				mSelfTestStep--;
				return false;
			}
			if (now < mHoodHoldUntil)
			{
				// the request goes out half way, once the panels have settled
				if (now > mHoodHoldUntil - 0.75 && !File.Exists(scope $"{dir}/{name}.bmp") && !File.Exists(scope $"{dir}/capture.request"))
					File.WriteAllText(scope $"{dir}/capture.request", name).IgnoreError();
				mSelfTestStep--;
				return false;
			}
			if (File.Exists(scope $"{dir}/capture.request"))
			{
				mSelfTestStep--; // not taken yet
				return false;
			}
			mHoodHoldUntil = 0;
			Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] captured {name}");
			return true;
		}

		static LayoutRow HoodRow(TypeLayout l, StringView name)
		{
			for (let r in l.Rows)
				if (r.Name == name)
					return r;
			return null;
		}

		bool SelfTestHood()
		{
			switch (mSelfTestStep)
			{
			case 0:
				String samples = scope .();
				if (!FindSamples(samples))
				{
					SelfTestCheck(false, "hood: the samples folder was not found (set TREADLE_SAMPLES)");
					return true;
				}
				String temp = scope .();
				if (!SelfTestTemp.Get(temp))
					temp.Set(samples);
				mHoodDir.Set(scope $"{temp}/treadle-hood-{(int)Platform.BfpSystem_GetTimeStamp() & 0xFFFFFF}");
				mHoodDir.Replace('\\', '/');
				Directory.CreateDirectory(scope $"{mHoodDir}/M1").IgnoreError();
				for (let e in Directory.EnumerateFiles(scope $"{samples}/m1"))
				{
					String name = scope .();
					e.GetFileName(name);
					File.Copy(e.GetFilePath(.. scope .()), scope $"{mHoodDir}/M1/{name}").IgnoreError();
				}
				String pad = scope .(cHoodPad);
				File.WriteAllText(scope $"{mHoodDir}/M1/Pad.treadle", pad).IgnoreError();
				mHoodPrevRoot.Set(mProjectRoot);
				OpenProjectNow(scope $"{mHoodDir}/M1", scope $"{mHoodDir}/M1/Program.treadle", true);
				mHoodWatch.Restart();
				mSelfTestWait = 5;
				return false;
			case 1:
				// Layout: the fixture struct, a class with a vtable, a generic instance, a payload enum
				let pad = TypeLayouts.Get(FrontEnd, "Zoo.Pad");
				if (pad == null || !pad.Ok)
				{
					SelfTestCheck(false, scope $"hood: no layout for Zoo.Pad: {(pad != null) ? pad.Why : "null"}");
					mSelfTestStep = cHoodCleanup - 1;
					return false;
				}
				String rows = scope .();
				for (let r in pad.Rows)
					rows.AppendF("{}{}@{}+{}", rows.IsEmpty ? "" : " ", (r.Kind == .Padding) ? "pad" : r.Name, r.Offset, r.Size);
				SelfTestCheck(rows == "Flag@0+1 pad@1+7 Count@8+8 Small@16+2 pad@18+6" && pad.Size == 24 && pad.Align == 8 && pad.IsStruct,
					scope $"hood: Zoo.Pad lays out as the build does: {rows}, size {pad.Size}, align {pad.Align}");
				let dog = TypeLayouts.Get(FrontEnd, "Zoo.Dog");
				let vt = (dog != null && dog.Ok && !dog.Rows.IsEmpty) ? dog.Rows[0] : null;
				let legs = (dog != null && dog.Ok) ? HoodRow(dog, "mLegs") : null;
				SelfTestCheck(dog != null && dog.Ok && dog.IsClass && vt != null && vt.Kind == .VTable && vt.Offset == 0 && vt.Size == 8 && legs != null && legs.Offset == 8 && legs.From == "Zoo.Animal" && dog.Size == 16 && dog.VSlots >= 1,
					scope $"hood: Zoo.Dog: vtable pointer at 0, mLegs (from {(legs != null) ? legs.From : "?"}) at {(legs != null) ? legs.Offset : -1}, size {(dog != null) ? dog.Size : -1}, {(dog != null) ? dog.VSlots : -1} vtable slots");
				let boxL = TypeLayouts.Get(FrontEnd, "Zoo.Box<Zoo.Point>");
				let mv = (boxL != null && boxL.Ok) ? HoodRow(boxL, "mValue") : null;
				SelfTestCheck(boxL != null && boxL.Ok && mv != null && mv.Offset == 8 && mv.Size == 16 && boxL.Size == 24 && boxL.Leaves.Count == 3,
					scope $"hood: Zoo.Box<Zoo.Point>: mValue at {(mv != null) ? mv.Offset : -1} ({(mv != null) ? mv.Size : -1} bytes), {(boxL != null) ? boxL.Leaves.Count : -1} leaves (vtable, mValue.X, mValue.Y)");
				let generic = TypeLayouts.Get(FrontEnd, "Zoo.Box");
				SelfTestCheck(generic != null && !generic.Ok && generic.Why.Contains("instantiation"), scope $"hood: the generic definition Zoo.Box asks for an instantiation ({(generic != null) ? generic.Why : ""})");
				let opt = TypeLayouts.Get(FrontEnd, "Core.Option<int>");
				let tag = (opt != null && opt.Ok) ? HoodRow(opt, "tag") : null;
				let payload = (opt != null && opt.Ok) ? HoodRow(opt, "payload") : null;
				SelfTestCheck(opt != null && opt.Ok && opt.IsPayloadEnum && tag != null && tag.Offset == 0 && tag.Size == 4 && payload != null && payload.Offset == 8 && opt.Size == 16,
					scope $"hood: Core.Option<int>: tag at 0 (4 bytes), payload at {(payload != null) ? payload.Offset : -1}, size {(opt != null) ? opt.Size : -1}{(opt != null && !opt.Ok) ? opt.Why : ""}");
				TypeLayout packed = scope .();
				TypeLayouts.FromRecords("# tir 1\nprogram P library\ntype T.P struct packed\n\tfield a bool\n\tfield b int32\n", "T.P", packed);
				SelfTestCheck(packed.Ok && packed.Size == 5 && packed.Rows.Count == 2 && packed.Rows[1].Offset == 1, scope $"hood: a packed struct has no padding (size {packed.Size})");
				// the Layout section in Type Settings
				let doc = OpenFile(scope $"{mHoodDir}/M1/Pad.treadle", true);
				SelfTestCheck(doc != null, "hood: Pad.treadle opens");
				if (doc != null)
				{
					Doc = doc;
					PropertyGrid.ForceOpen.Set("Layout");
					PropertyGrid.ForceClosed.Set("Type;Uses;Inheritance;Generic;Attributes");
					SelectOutline(.TypeSettings);
				}
				mSelfTestWait = 3;
				return false;
			case 2:
				if (!HoodCapture("hood-layout-struct"))
					return false;
				let doc = OpenFile(scope $"{mHoodDir}/M1/Dog.treadle", true);
				if (doc != null)
				{
					Doc = doc;
					SelectOutline(.TypeSettings);
				}
				mSelfTestWait = 3;
				return false;
			case 3:
				if (!HoodCapture("hood-layout-class"))
					return false;
				PropertyGrid.ForceOpen.Clear();
				PropertyGrid.ForceClosed.Clear();
				// Main: the badges on its Construct and Local nodes
				let doc = OpenFile(scope $"{mHoodDir}/M1/Program.treadle", false);
				let main = doc?.FindSheetByName("Main");
				if (main == null)
				{
					SelfTestCheck(false, "hood: Zoo.Program.Main was not found");
					mSelfTestStep = cHoodCleanup - 1;
					return false;
				}
				Doc = doc;
				OpenTab(main);
				OutlineSel = .None;
				mGraphPanel.LivesInBadges = 0;
				mSelfTestWait = 4;
				return false;
			case 4:
				let main = Doc?.FindSheetByName("Main");
				int heap = 0;
				int region = 0;
				if (main != null)
					for (let n in main.Graph.Nodes)
					{
						let s = NodeStorage(n);
						if (s == .Heap)
							heap++;
						if (s == .Region)
							region++;
					}
				// a2 Construct Zoo.Dog and c2 Construct Zoo.Box<int>: heap; a4 Local Zoo.Bird and c6 Local Zoo.Box<Zoo.Point>: region
				SelfTestCheck(heap == 2 && region == 2 && mGraphPanel.LivesInBadges >= 4, scope $"hood: Main's Construct nodes live in the heap ({heap}), its Local nodes in a region ({region}); {mGraphPanel.LivesInBadges} badges drawn");
				String why = scope .();
				let animal = OpenFile(scope $"{mHoodDir}/M1/Animal.treadle", false);
				let legs = animal?.FindMember("mLegs");
				if (animal != null && legs != null)
				{
					let s = FieldStorage(legs, animal.Header.Kind, why);
					SelfTestCheck(s == .Heap && why.Contains("inside each object"), scope $"hood: Zoo.Animal.mLegs lives inside each object: {why}");
				}
				else
					SelfTestCheck(false, "hood: Zoo.Animal.mLegs was not found");
				if (main != null && main.Member != null && !main.Member.Locals.IsEmpty)
				{
					String tip = scope .();
					StorageTip(null, main.Member.Locals[0], tip);
					SelfTestCheck(tip.Contains("Lives in: frame") && tip.Contains("reference"), scope $"hood: the local pet lives in the frame and holds a reference:{tip}");
				}
				// the picture: Main in front with the Local of a Bird selected (its Storage row in Properties)
				let prog = OpenFile(scope $"{mHoodDir}/M1/Program.treadle", false);
				if (prog != null && main != null)
				{
					Doc = prog;
					OpenTab(main);
					OutlineSel = .None;
					for (let n in main.Graph.Nodes)
						if (n.Key == "a4")
							CurrentTab?.SelectOnly(n.Id);
				}
				mSelfTestWait = 3;
				return false;
			case 5:
				if (!HoodCapture("hood-badges"))
					return false;
				// debug: a breakpoint on c9 (WriteLine of Box<Point>.Get().Sum()), F5
				let doc = OpenFile(scope $"{mHoodDir}/M1/Program.treadle", false);
				let main = doc?.FindSheetByName("Main");
				Node c9 = null;
				if (main != null)
					for (let n in main.Graph.Nodes)
						if (n.Key == "c9")
							c9 = n;
				if (c9 == null || !Debug.Adapter.Available)
				{
					SelfTestCheck(false, scope $"hood: no node c9 or no debugger ({Debug.Adapter.Unavailable})");
					mSelfTestStep = cHoodCleanup - 1;
					return false;
				}
				ToggleBreakpoint(main, c9);
				mHoodLaunchBase = DebugLaunches;
				StartDebugging();
				mHoodWatch.Restart();
				return false;
			case 6:
				if (!HoodWait(DebugLaunches > mHoodLaunchBase && (Debug.IsStopped || Debug.State == .Exited) || (DebugLaunches == mHoodLaunchBase && !mDebugAfterBuild && (mBuild == null || !mBuild.Running)), "the stop on c9"))
					return false;
				let f = Debug.CurrentFrame;
				if (!Debug.IsStopped || f == null || f.NodeKey != "c9")
				{
					SelfTestCheck(false, scope $"hood: the debug session did not stop on c9 ({Debug.State}, {(f != null) ? f.NodeKey : ""})");
					mSelfTestStep = cHoodCleanup - 1;
					return false;
				}
				ShowCallStack = true;
				Panels.Focus(Panels.CallStackId);
				mSelfTestWait = 3;
				return false;
			case 7:
				if (!HoodCapture("hood-callstack", Panels.CallStackId))
					return false;
				// Disassembly of Main from the Debug build
				OpenDisassembly("Zoo.Program", "m0001", "Zoo.Program.Main");
				let a = Disassembly;
				String nodes = scope .();
				bool hasA2 = false;
				bool hasB7 = false;
				bool hasC9 = false;
				for (let g in a.Groups)
				{
					hasA2 |= g.Node == "a2" && g.Title.StartsWith("Construct") && g.Count > 0;
					hasB7 |= g.Node == "b7" && g.Count > 0;
					hasC9 |= g.Node == "c9" && g.Count > 0;
					if (nodes.Length < 120)
						nodes.AppendF("{} ", g.Node);
				}
				SelfTestCheck(a.FromExe && a.Symbol == "_ZN3Zoo7Program4MainEv" && a.Lines.Count > 40 && hasA2 && hasB7 && hasC9,
					scope $"hood: Disassembly of Zoo.Program.Main from the exe ({a.Symbol}): {a.Lines.Count} instructions in {a.Groups.Count} node groups ({nodes}...){a.Error}");
				SelfTestCheck(a.SheetIR.Contains("func Zoo.Program.Main") && a.SheetIR.Contains("node a2 Construct") && a.LLVMIR.StartsWith("define") && a.LLVMIR.Contains("@_ZN3Zoo7Program4MainEv("),
					"hood: its Sheet IR is Main's func record and its LLVM IR the define of _ZN3Zoo7Program4MainEv");
				let boxL = OpenDisassemblyInstances("Zoo.Box", "Get");
				SelfTestCheck(boxL >= 2, scope $"hood: Zoo.Box.Get is found built for each type argument ({boxL} instances)");
				OpenDisassembly("Zoo.Program", "m0001", "Zoo.Program.Main");
				mSelfTestWait = 3;
				mHoodWatch.Restart();
				return false;
			case 8:
				// the live instruction: the selected frame's address in the exe
				if (!HoodWait(mAsmLivePc != 0, "the live instruction", 30))
					return false;
				bool found = false;
				for (let l in Disassembly.Lines)
					if (l.Address == mAsmLivePc)
					{
						let g = Disassembly.Groups[l.Group];
						found = g.Node == "c9" || g.Node == "c8" || g.Node == "c7";
					}
				SelfTestCheck(found, scope $"hood: the program's instruction (0x{mAsmLivePc:X}) is marked in the group of the stopped node c9 (or the value nodes it reads)");
				return false;
			case 9:
				if (!HoodCapture("hood-disassembly", HoodPanels.DisassemblyId))
					return false;
				AsmTabRequest = 1;
				return false;
			case 10:
				if (!HoodCapture("hood-sheet-ir", HoodPanels.DisassemblyId))
					return false;
				AsmTabRequest = 0;
				// Memory: the pin c6.object (a Local Box<Point>) followed to its object
				DebugVariable pin = null;
				for (let v in Debug.Locals)
					if (v.Name == "c6.object")
						pin = v;
				if (pin == null)
				{
					SelfTestCheck(false, "hood: the pin value c6.object is not in Locals");
					mSelfTestStep = cHoodCleanup - 1;
					return false;
				}
				MemHex = false;
				mHoodReads = MemReads;
				ShowVariableInMemory(pin);
				mHoodWatch.Restart();
				return false;
			case 11:
				if (!HoodWait(mMemPending == 0 && MemReads > mHoodReads, "the object's bytes", 30))
					return false;
				let l = MemLayout();
				String x = scope .();
				String y = scope .();
				if (l != null)
					for (let r in l.Leaves)
					{
						if (r.Name == "mValue.X")
							MemDecode(r, l, x);
						if (r.Name == "mValue.Y")
							MemDecode(r, l, y);
					}
				SelfTestCheck(l != null && mMemType == "Zoo.Box<Zoo.Point>" && x == "3" && y == "4" && mMemError.IsEmpty,
					scope $"hood: Memory follows c6.object to its Zoo.Box<Zoo.Point> ({mMemType}) and decodes mValue.X = {x}, mValue.Y = {y}{mMemError}");
				Panels.Focus(HoodPanels.MemoryId);
				mSelfTestWait = 3;
				return false;
			case 12:
				if (!HoodCapture("hood-memory", HoodPanels.MemoryId))
					return false;
				MemHex = true;
				MemRead();
				mHoodReads = MemReads;
				mHoodWatch.Restart();
				return false;
			case 13:
				if (!HoodWait(mMemPending == 0 && MemReads > mHoodReads, "the hex bytes", 30))
					return false;
				SelfTestCheck(mMemBytes.Count >= 64 && mMemBytes.Count % 16 == 0, scope $"hood: Hex mode reads whole rows of 16 ({mMemBytes.Count} bytes)");
				mSelfTestWait = 3;
				return false;
			case 14:
				if (!HoodCapture("hood-memory-hex", HoodPanels.MemoryId))
					return false;
				// an address nothing maps: a message, no crash
				mHoodReads = MemReads;
				ShowAddressInMemory(0x10, "", "0x10");
				mHoodWatch.Restart();
				return false;
			case 15:
				if (!HoodWait(mMemPending == 0 && MemReads > mHoodReads, "the unreadable address", 30))
					return false;
				SelfTestCheck(!mMemError.IsEmpty && mMemBytes.IsEmpty, scope $"hood: an unreadable address says so: {mMemError}");
				// the frame of Main
				mHoodReads = MemReads;
				ShowFrameInMemory(0);
				mHoodWatch.Restart();
				return false;
			case 16:
				if (!HoodWait(mMemPending == 0 && MemReads >= mHoodReads + 2, "the frame's bytes", 30))
					return false;
				SelfTestCheck(mMemBytes.Count >= 16 && mMemError.IsEmpty, scope $"hood: Show Frame in Memory reads Main's stack frame ({mMemBytes.Count} bytes from 0x{mMemAddr:X}){mMemError}");
				// Release: the exe is stripped, the unit's .ll is compiled alone for the listing
				Debug.Stop();
				mHoodWatch.Restart();
				return false;
			case 17:
				if (!HoodWait(!Debug.IsActive, "the end of the debug session", 30))
					return false;
				Build("Release");
				mHoodWatch.Restart();
				mSelfTestWait = 2;
				return false;
			case 18:
				if (!HoodWait(mBuild != null && !mBuild.Running, "the Release build", 180))
					return false;
				FunctionListing rel = scope .();
				rel.Produce(scope $"{mHoodDir}/M1", "Release", "Zoo.Program", "m0001", "Zoo.Program.Main");
				bool nodes = false;
				for (let g in rel.Groups)
					nodes |= !g.Node.IsEmpty && g.Count > 0;
				SelfTestCheck(mBuild.Succeeded && !rel.FromExe && rel.Lines.Count > 10 && nodes && !rel.Note.IsEmpty,
					scope $"hood: the Release Disassembly of Main comes from Zoo.Program.ll compiled alone ({rel.Lines.Count} instructions in {rel.Groups.Count} groups){rel.Error}");
				mSelfTestStep = cHoodCleanup - 1;
				return false;
			case cHoodCleanup:
				if (mBuild != null && mBuild.Running)
				{
					mSelfTestStep--;
					return false;
				}
				if (Debug.IsActive)
					Debug.Stop();
				Debug.ClearBreakpoints();
				SaveBreakpoints();
				ShowMemory = false;
				ShowDisassembly = false;
				OpenProjectNow(mHoodPrevRoot, "", true);
				String root = scope $"{mHoodDir}/M1";
				ForgetRecentProject(root);
				String key = scope .(root);
				key.ToLower();
				key.Replace('/', Path.DirectorySeparatorChar);
				Settings.Root?.Get("projects")?.Remove(key);
				Settings.Save();
				mSelfTestWait = 30;
				return false;
			case cHoodCleanup + 1:
				DeleteTree(mHoodDir);
				return true;
			default:
				mSelfTestStep = cHoodCleanup - 1;
				return false;
			}
		}

		/// Opens the Disassembly of `member` of `unit` and returns how many instances it was built into.
		int OpenDisassemblyInstances(StringView unit, StringView member)
		{
			let doc = OpenFile(scope $"{mHoodDir}/M1/{unit.Substring(unit.LastIndexOf('.') + 1)}.treadle", false);
			let sheet = doc?.FindSheetByName(member);
			if (sheet == null)
				return 0;
			OpenDisassembly(unit, sheet.Key, scope $"{unit}.{member}");
			return Disassembly.Symbols.Count;
		}
	}
}
#endif
