// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using System.IO;
using ImGui;
using Treadle.Debug;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Compiler;
using Treadle.Language;

namespace Treadle.Editor
{
	/// The `editor` case's fourth wave (SelfTestE4Before, one phase per call, before the case saves Player;
	/// every edit is undone):
	///
	///  - Call Stack: the thread order (Main, the workers by name with numbers compared as numbers, then
	///    `Thread <id>`), a long frame row cut in the middle, and the narrow right dock's three tabs
	///    (Properties, Locals, Call Stack) fitting its width without the scroll arrows.
	///  - Split Vector Pin: a Break float4's input and a Make float4's output split into their lanes (`value.x` ...
	///    `value.w`, float), recombined, every edit undone; a file with split float4 and float8 pins expands to one
	///    Make / Break per split whose lane pins carry the literals and wires (no second x), and binds clean.
	///  - Math-type pins: the field table of the core math structs, the struct literal (`1,2,3`) split, joined,
	///    typed and refused; both type systems answer `.Fields` for them (`.Custom` for an expression); a type
	///    file with struct literals reads and writes back byte for byte; the front end binds them and refuses a
	///    literal with the wrong count of values (T2232).
	///
	/// Capture steps (`e4.<verb>`, SelfTestE4Capture): `e4.math` opens a project of its own whose Sheet `Show`
	/// has unwired Vec3, Quat, Color, Color32, Vec2, Rect and Vec4 inputs; `e4.picker:<node>.<pin>` opens the colour
	/// picker of that pin.
	extension EditorApp
	{
		int mE4Phase;
		int mE4Nodes;
		String mE4Break = new .() ~ delete _;
		String mE4Make = new .() ~ delete _;
		bool mE4Done;
		bool mE4ShowLocals;
		bool mE4ShowCallStack;

		/// The capture project's Sheet and the self test's type file: every math pin unwired, holding a literal.
		const String cMathPins = """
			# treadle 1
			type MathPins class
				namespace Demo
				static

			function m1 Show
				static
				returns Mat4
			local c Color32
			local r Rect
			local v Vec4
			local f float4
			sheet body
			node a1 Entry
			node a2 Call Core.Mat4.FromTRS
				in translation 1,2.5,-3
				in rotation 0,0,0,1
				in scale 1,1,1
			node a3 Call Core.Color.FromSrgb
				in srgb 1,0.5,0,1
			node a4 Set local:c
				in value 255,128,0,255
			node a5 Call Core.Rect.FromMinMax
				in min 0,0
				in max 640,480
			node a6 Set local:r
				in value 0,0,640,480
			node a7 Set local:v
				in value 1,2,3,4
			node a8 Return
			node a9 Set local:f
				in value 1,0.5,0,1
			wire a1.then a4.in
			wire a4.then a6.in
			wire a6.then a7.in
			wire a9.then a8.in
			wire a2.result a8.value
			wire a7.then a9.in

			""";

		const String cMathPinsLayout = """
			# treadle-layout 1
			sheet m1
				view -40 -40 1.0
				node a1 0 0
				node a4 220 0
				node a6 560 0
				node a7 900 0
				node a9 1240 0
				node a8 1600 0
				node a2 0 220
				node a3 440 220
				node a5 800 220

			""";

		/// One phase per call; true when all are done.
		bool SelfTestE4Before()
		{
			switch (mE4Phase++)
			{
			case 0: SelfTestE4CallStack(0); return false;
			case 1: SelfTestE4CallStack(1); return false;
			case 2: SelfTestE4MathModel(); return false;
			case 3: SelfTestE4MathFormat(); return false;
			case 4, 5, 6: SelfTestE4SplitVector(mE4Phase - 5); return false;
			case 7: SelfTestE4SplitVectorBind(); return false;
			default:
				mE4Phase = 0;
				return true;
			}
		}

		void SelfTestE4CallStack(int phase)
		{
			if (phase == 0)
			{
				List<DebugThread> list = scope .();
				defer { for (let t in list) delete t; }
				let names = StringView[?]("worker 10", "Thread 9120", "worker 2", "Main", "Pool 1", "Thread 812", "worker 1");
				let ids = int64[?](5, 9, 7, 3, 4, 8, 6);
				for (int i < names.Count)
				{
					DebugThread t = new .();
					t.Name.Set(names[i]);
					t.Id = ids[i];
					list.Add(t);
				}
				DebugSession.SortThreads(list);
				String order = scope .();
				for (let t in list)
					order.AppendF("{}{}", order.IsEmpty ? "" : ", ", t.Name);
				SelfTestCheck(order == "Main, Pool 1, worker 1, worker 2, worker 10, Thread 812, Thread 9120",
					scope $"call stack: the threads in the Call Stack's order: Main first, the workers by name, then the system's ({order})");
				let row = "Cx.ThreadsBasicMain.Main   c4  Call Thread.Join";
				String shown = scope .();
				let w = Gui.CalcTextSize(row).x * 0.6f;
				bool cut = Look.EllipsizeMiddle(row, w, shown);
				SelfTestCheck(cut && shown.StartsWith("Cx.Thr") && shown.EndsWith("Join") && shown.Contains("...") && Gui.CalcTextSize(shown).x <= w,
					scope $"call stack: a long frame row is cut in the middle to the panel's width ({shown})");
				// the narrow right dock with all three tabs (a debug session's layout)
				mE4ShowLocals = ShowLocals;
				mE4ShowCallStack = ShowCallStack;
				ShowLocals = true;
				ShowCallStack = true;
				mSelfTestWait = 4;
				return;
			}
			let style = Gui.igGetStyle();
			let need = Panels.NarrowTabs * Panels.NarrowTabFloor + (Panels.NarrowTabs - 1) * style.ItemInnerSpacing.x;
			let bar = Panels.NarrowDockW - 2 * (style.WindowBorderSize + style.FramePadding.x);
			SelfTestCheck(Panels.NarrowTabs == 3 && need <= bar,
				scope $"call stack: Properties, Locals and Call Stack fit the right dock without the scroll arrows ({Panels.NarrowTabs} tabs of {Panels.NarrowTabFloor:F0} px in a tab bar of {bar:F0} px)");
			ShowLocals = mE4ShowLocals;
			ShowCallStack = mE4ShowCallStack;
		}

		/// The core math structs' fields: the table, the literal, what the type systems answer.
		void SelfTestE4MathModel()
		{
			bool Is(StringView type, int count, StringView hints, MathFieldKind kind) => PinValue.MathInfo(type, let n, let h, let k) && n == count && h == hints && k == kind;
			bool info = Is("Core.Vec3", 3, "xyz", .Float) && Is("Vec2", 2, "xy", .Float) && Is("Core.Quat", 4, "xyzw", .Float) && Is("Core.Color32", 4, "rgba", .Byte) &&
				Is("Core.Rect", 4, "xywh", .Float) && Is("Core.RectI", 4, "xywh", .Int) && Is("Core.Vec4d", 4, "xyzw", .Double) && Is("Core.Color", 4, "rgba", .Float) &&
				!PinValue.MathInfo("Core.Mat4", ?, ?, ?) && !PinValue.MathInfo("Core.Pair<int,float>", ?, ?, ?) && !PinValue.MathInfo("float4", ?, ?, ?) &&
				PinValue.IsColor("Core.Color") && PinValue.IsColor("Core.Color32") && !PinValue.IsColor("Core.Vec4");
			SelfTestCheck(info, "math pins: the core math structs' fields (Vec2 x y, Vec3 x y z, Quat x y z w, Color / Color32 r g b a, Rect x y w h), not Mat4, Pair or float4");
			List<String> parts = scope .();
			defer { ClearAndDeleteItems!(parts); }
			bool split = PinValue.SplitFields("Core.Vec3", "1,2.5,-3", parts) && parts.Count == 3 && parts[1] == "2.5" && parts[2] == "-3" &&
				!PinValue.SplitFields("Core.Vec3", "1,2", null) && !PinValue.SplitFields("Core.Vec3", "1,2,3,4", null) && !PinValue.SplitFields("Core.Vec3", "1, 2, 3", null) &&
				!PinValue.SplitFields("Core.Vec3", "a,b,c", null) && PinValue.SplitFields("Core.Color32", "255,128,0,255", null) &&
				!PinValue.SplitFields("Core.Color32", "256,0,0,255", null) && !PinValue.SplitFields("Core.RectI", "0,0,1.5,2", null) && PinValue.SplitFields("Core.Rect", "0,0,1.5,2", null);
			ClearAndDeleteItems!(parts);
			split &= PinValue.SplitFields("Core.Vec2", "", parts) && parts.Count == 2 && parts[0] == "0";
			String joined = scope .();
			PinValue.JoinFields(parts, joined);
			SelfTestCheck(split && joined == "0,0", "math pins: a struct literal has one value per field, numbers (0 to 255 for a Color32, whole numbers for a RectI); empty is zeros (0,0)");
			String lit = scope .();
			String why = scope .();
			bool typed = PinValue.Write(.Fields, "Core.Vec3", " 1, 2.5 , -3 ", false, lit, why) && lit == "1,2.5,-3";
			String lit2 = scope .();
			String why2 = scope .();
			bool refused = !PinValue.Write(.Fields, "Core.Color32", "300,0,0,255", false, lit2, why2) && why2.Contains("0 to 255");
			SelfTestCheck(typed && refused, scope $"math pins: typed `1, 2.5 , -3` is stored 1,2.5,-3; 300 for a Color32 is refused ({why2})");
			// the editor's type system (the compiler's) and the stand-in over the project's types
			let types = Language.Types;
			bool ts = types.ValueKind("Core.Vec3", "", "to") == .Fields && types.ValueKind("Core.Color", "1,0,0,1", "c") == .Fields &&
				types.ValueKind("Core.Color32", "255,0,0,255", "c") == .Fields && types.ValueKind("Core.Vec3", "a + b", "to") == .Custom &&
				types.ValueKind("Core.Mat4", "", "m") != .Fields && types.ValueKind("Core.Quat", "default", "q") == .Fields;
			RefreshProjectTypes();
			let standIn = scope ProjectTypeSystem(ProjectTypes);
			bool si = ProjectTypes.Find("Core.Vec3") == null || (standIn.ValueKind("Core.Vec3", "", "to") == .Fields && standIn.ValueKind("Core.Vec3", "x", "to") == .Custom);
			SelfTestCheck(ts && si, "math pins: the type systems answer Fields for Vec3, Color, Color32 and Quat (Custom for an expression; not for Mat4)");
		}

		/// A type file with struct literals reads and writes back; the front end binds them and refuses a short one.
		void SelfTestE4MathFormat()
		{
			String text = scope .(cMathPins);
			text.Replace("\r\n", "\n");
			TypeDocument doc = scope .(Language);
			String err = scope .();
			let read = Language.Codec.Read(text, doc, err);
			String back = scope .();
			if (read)
				doc.WriteText(back, err);
			SelfTestCheck(read && back == text, scope $"math pins: a type file with struct literals (in translation 1,2.5,-3) reads and writes back byte for byte {err}");
			if (read && back != text)
				Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] written:\n{back}");
			String bad = scope .(text);
			bad.Replace("\tin translation 1,2.5,-3\n", "\tin translation 1,2\n");
			for (int pass < 2)
			{
				LanguageContext ctx = scope .();
				List<TypeDocument> open = scope .();
				defer { ClearAndDeleteItems!(open); }
				TypeDocument fdoc = new .(ctx);
				open.Add(fdoc);
				if (!ctx.Codec.Read((pass == 0) ? text : bad, fdoc, err))
				{
					SelfTestCheck(false, scope $"math pins: the front end's copy reads: {err}");
					return;
				}
				FrontEndServices fe = scope .(ctx, open);
				let fs = fdoc.FindSheetByName("Show");
				GraphValidator.Validate(fs.Graph);
				int count = 0;
				bool refused = false;
				String msgs = scope .();
				for (let e in fs.Graph.Errors)
				{
					count++;
					msgs.AppendF("{} | ", e.Message);
					if (e.NodeId == fs.Graph.FindNodeByKey("a2")?.Id && e.Message.Contains("2 values for its 3 fields"))
						refused = true;
				}
				if (pass == 0)
					SelfTestCheck(count == 0 && ctx.Types.ValueKind("Core.Vec3", "1,2,3", "to") == .Fields,
						scope $"math pins: the front end binds the struct literals of Vec3, Quat, Color, Color32, Vec2, Rect and Vec4 inputs ({count} problems {msgs})");
				else
					SelfTestCheck(refused, scope $"math pins: a Vec3 literal with two values is refused on its node ({msgs})");
				fe.GetType();
			}
		}

		/// Split Vector Pin on the open Sheet: a Break float4 and a Make float4 placed, their vector pins split into
		/// lanes and recombined; the three edits undone.
		void SelfTestE4SplitVector(int phase)
		{
			let mg = CurrentMethod;
			if (mg == null)
			{
				SelfTestCheck(false, "split vector: no Sheet to edit");
				return;
			}
			let g = mg.Graph;
			switch (phase)
			{
			case 0:
				mE4Nodes = g.Nodes.Count;
				BeginEdit();
				let brk = NodeFactory.BreakStruct(g, "float4");
				brk.X = 900;
				brk.Y = 1000;
				brk.HasPos = true;
				let make = NodeFactory.Make(g, "float4");
				make.X = 600;
				make.Y = 1000;
				make.HasPos = true;
				CommitCurrent();
				mE4Break.Set(brk.Key);
				mE4Make.Set(make.Key);
			case 1:
				let brk = g.FindNodeByKey(mE4Break);
				let make = g.FindNodeByKey(mE4Make);
				let inPin = brk?.FindInput("value");
				let outPin = make?.FindOutput("value");
				bool offered = CanSplitPin(mg, inPin) && CanSplitPin(mg, outPin);
				bool split = offered && SplitStructPin(mg, inPin) && SplitStructPin(mg, outPin);
				String lanes = scope .();
				if (brk != null)
					for (let p in brk.Inputs)
						if (p.Name.StartsWith("value."))
							lanes.AppendF("{}{}:{}", lanes.IsEmpty ? "" : " ", p.Name, p.TypeName);
				let outs = (make != null) ? make.FindOutput("value.w") : null;
				SelfTestCheck(split && lanes == "value.x:float value.y:float value.z:float value.w:float" && outs != null && outs.TypeName == "float" &&
					brk.GetSetting(SplitPins.Key) == "value float4" && SplitPins.IsSplit(inPin),
					scope $"split vector: Split Vector Pin gives a Break float4's input its lanes ({lanes}) and a Make float4's output value.x ... value.w (offered {offered})");
			case 2:
				let brk = g.FindNodeByKey(mE4Break);
				let pin = brk?.FindInput("value.y");
				bool back = pin != null && RecombineStructPin(mg, pin) && brk.FindInput("value.x") == null && !SplitPins.IsSplit(brk.FindInput("value"));
				for (int i < 4)
					if (EditDoc.CanUndo)
						EditDoc.Undo();
				SelfTestCheck(back && CurrentMethod.Graph.Nodes.Count == mE4Nodes && CurrentMethod.Graph.FindNodeByKey(mE4Break) == null,
					scope $"split vector: Recombine Vector Pin takes the lanes back; undo removes the four edits ({CurrentMethod.Graph.Nodes.Count} nodes, {mE4Nodes} before)");
			}
		}

		/// The fixture split-vector as the compiler sees it: one Make / Break per split, the lanes on its own lane pins.
		void SelfTestE4SplitVectorBind()
		{
			String samples = scope .();
			String fixtures = scope .();
			String text = scope .();
			if (!FindSamples(samples) || !FindFixtures(samples, fixtures) || File.ReadAllText(scope $"{fixtures}/core/split-vector.treadle", text) case .Err)
			{
				SelfTestCheck(false, "split vector: the fixture split-vector.treadle was not found");
				return;
			}
			text.Replace("\r\n", "\n");
			LanguageContext ctx = scope .();
			List<TypeDocument> open = scope .();
			defer { ClearAndDeleteItems!(open); }
			TypeDocument doc = new .(ctx);
			open.Add(doc);
			String err = scope .();
			if (!ctx.Codec.Read(text, doc, err))
			{
				SelfTestCheck(false, scope $"split vector: the fixture reads: {err}");
				return;
			}
			let sheet = doc.FindSheetByName("Main");
			let expanded = SplitPins.Expand(sheet.Graph);
			defer delete expanded;
			let mk = expanded?.FindNodeByKey("a2_value");
			let bk = expanded?.FindNodeByKey("a3_value");
			let bk8 = expanded?.FindNodeByKey("a9_value");
			int xs = 0;
			if (mk != null)
				for (let p in mk.Inputs)
					if (p.Name == "x")
						xs++;
			bool shape = mk != null && mk.Kind == .Make && xs == 1 && mk.FindInput("w")?.Default == "4" && mk.FindInput("x")?.Default == "1" &&
				bk != null && bk.Kind == .BreakStruct && expanded.FindLinkFrom(bk.FindOutput("w")) != null && bk8 != null && expanded.FindLinkFrom(bk8.FindOutput("lane7")) != null;
			SelfTestCheck(shape, scope $"split vector: a split float4 expands to Make float4 with one pin per lane holding its literal (x 1, w 4) and Break float4 whose lanes carry the wires; float8 by lane0 ... lane7 (x pins {xs})");
			FrontEndServices fe = scope .(ctx, open);
			GraphValidator.Validate(sheet.Graph);
			String msgs = scope .();
			for (let e in sheet.Graph.Errors)
				msgs.AppendF("{} | ", e.Message);
			SelfTestCheck(sheet.Graph.Errors.Count == 0, scope $"split vector: the front end binds the split lanes ({msgs})");
			fe.GetType();
		}

		/// Capture steps (`e4.<verb>[:<arg>]`); false when `test` is not one.
		bool SelfTestE4Capture(StringView test, ref bool finished)
		{
			if (!test.StartsWith("e4."))
				return false;
			let colon = test.IndexOf(':');
			let verb = (colon > 0) ? test.Substring(3, colon - 3) : test.Substring(3);
			let arg = (colon > 0) ? test.Substring(colon + 1) : "";
			switch (verb)
			{
			case "math":
				E4CaptureProject("MathPins", cMathPins, cMathPinsLayout);
			case "split":
				// the fixture split-vector, laid out
				String samples = scope .();
				String fixtures = scope .();
				String text = scope .();
				if (FindSamples(samples) && FindFixtures(samples, fixtures) && File.ReadAllText(scope $"{fixtures}/core/split-vector.treadle", text) case .Ok)
					E4CaptureProject("SplitVector", text, cSplitVectorLayout);
			case "picker":
				let dot = arg.IndexOf('.');
				let n = (dot > 0) ? CurrentMethod?.Graph.FindNodeByKey(arg.Substring(0, dot)) : null;
				let p = n?.FindInput(arg.Substring(dot + 1));
				if (p != null)
					mGraphPanel.mPinEditor.SelfTestOpenPicker = p.Id;
				mSelfTestWait = 10;
			default:
				SelfTestCheck(false, scope $"unknown capture step '{test}'");
			}
			return true;
		}

		/// A project of its own under %TEMP% (a library: nothing to run) with one type file and its layout, opened.
		void E4CaptureProject(StringView name, StringView typeText, StringView layoutText)
		{
			String temp = scope .();
			SelfTestTemp.Get(temp);
			String dir = scope $"{temp}/treadle-e4-{name}-{(int)Platform.BfpSystem_GetTimeStamp() & 0xFFFFFF}";
			Directory.CreateDirectory(dir).IgnoreError();
			String text = scope .(typeText);
			text.Replace("\r\n", "\n");
			String layout = scope .(layoutText);
			layout.Replace("\r\n", "\n");
			File.WriteAllText(scope $"{dir}/{name}.treadle", text).IgnoreError();
			File.WriteAllText(scope $"{dir}/{name}.treadle.layout", layout).IgnoreError();
			File.WriteAllText(scope $"{dir}/{name}.tproj", scope $"# tproj 1\nproject {name}\n\tkind library\n\tversion 0.1.0\n").IgnoreError();
			for (let d in mDocs)
				d.Modified = false;
			OpenProjectNow(dir, scope $"{dir}/{name}.treadle", true);
			mSelfTestWait = 30;
		}

		const String cSplitVectorLayout = """
			# treadle-layout 1
			sheet m1
				view -40 -40 1.0
				node a1 0 0
				node a2 200 0
				node a4 620 0
				node a5 880 0
				node a7 1140 0
				node a8 1400 0
				node b2 1760 0
				node b3 2020 0
				node a3 240 260
				node a6 620 300
				node a9 1400 440
				node b1 1700 480

			""";
	}
}
#endif
