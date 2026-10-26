// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using System.IO;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Model;

namespace Treadle.Editor
{
	/// The `editor` case's checks of the first-use findings, on the third wave's project after Making types,
	/// one phase per frame: the Construct picker lists every class (another file and namespace too, abstract
	/// dim), the type picker's rows within a frame budget, renaming a type (file, references, undo), the
	/// Outline's in-place rename (function, variable, local), integer and float values, Is Valid / Is Type,
	/// Create local variable on a value read twice, arrow nudges, a variable dropped on a pin, Q onto the
	/// last selected, the Return a result brings, the status bar's validate state.
	extension EditorApp
	{
		int mS1Phase;
		int32 mS1Construct;
		int32 mS1Spin;
		int32 mS1Speed;
		int32 mS1SpeedGet;
		String mS1Local = new .() ~ delete _;

		TypeDocument S1Doc(StringView name)
		{
			for (let d in mDocs)
				if (d.Header.Name == name)
					return d;
			return null;
		}

		Sheet S1Sheet(TypeDocument d, StringView name) => (d != null) ? d.FindSheetByName(name) : null;

		/// One phase per call; true when done.
		bool SelfTestSheet1()
		{
			switch (mS1Phase++)
			{
			case 0: S1Pickers(); mSelfTestWait = 4; return false;
			case 1: S1PickerOpen(); mSelfTestWait = 3; return false;
			case 2: S1Rename(); mSelfTestWait = 3; return false;
			case 3: S1InlineStart(); mSelfTestWait = 3; return false;
			case 4: S1InlineField(); mSelfTestWait = 3; return false;
			case 5: S1InlineLocal(); mSelfTestWait = 3; return false;
			case 6: S1Values(); S1Nodes(); S1Promote(); S1Canvas(); mSelfTestWait = 3; return false;
			case 7: S1CanvasAfter(); S1Status(); return false;
			case 8: S1Inherited(); mSelfTestWait = 3; return false;
			case 9:
				SelfTestCheck(OutlineInheritedRows == 1, scope $"editor: sheet1: the Outline lists the base's public variable under Inherited, not its private one ({OutlineInheritedRows})");
				return false;
			default:
				mS1Phase = 0;
				return true;
			}
		}

		/// Finding 6 (every class in a Construct's picker) and finding 5 (the rows in a frame budget).
		void S1Pickers()
		{
			String parts = scope $"{mNtDir}/Parts";
			Directory.CreateDirectory(parts).IgnoreError();
			let engine = CreateType(.Class, mNtDir, "Engine");
			let motor = CreateType(.Class, parts, "Motor");
			let shape = CreateType(.Class, mNtDir, "Shape");
			if (shape != null)
			{
				shape.Header.Abstract = true;
				shape.Version++;
			}
			SelfTestCheck(engine != null && motor != null && motor.Header.Namespace != engine.Header.Namespace,
				scope $"editor: sheet1: Engine and Motor in two namespaces ({engine?.Header.Namespace} / {motor?.Header.Namespace})");
			// Program.Main (static) is not saved: the Construct node is placed in it.
			let program = S1Doc("Program") ?? OpenFile(scope $"{mE3Root}/Source/Program{GraphExtension}");
			let main = S1Sheet(program, "Main");
			SelfTestCheck(main != null && program.Header.Static, "editor: sheet1: Program.Main is open (a static class)");
			if (main == null)
				return;
			OpenTab(main);
			List<String> types = scope .();
			defer { ClearAndDeleteItems!(types); }
			TypeChoices(.Allocatable, "", types);
			bool hasEngine = false, hasMotor = false, hasShape = false;
			for (let t in types)
			{
				hasEngine |= t.EndsWith(".Engine") || t == "Engine";
				hasMotor |= t.EndsWith(".Motor");
				hasShape |= t.EndsWith(".Shape");
			}
			SelfTestCheck(hasEngine && hasMotor && !hasShape, scope $"editor: sheet1: a Construct in Program.Main can make Engine and Parts.Motor, not the abstract Shape ({types.Count} types)");
			List<TypeEntry> entries = scope .();
			defer { ClearAndDeleteItems!(entries); }
			TypeEntries(.Allocatable, "", entries);
			bool shapeDim = false;
			for (let e in entries)
				shapeDim |= e.Name.EndsWith(".Shape") && e.Disabled && e.HintShort == "abstract";
			SelfTestCheck(shapeDim, "editor: sheet1: the abstract Shape is listed dim with 'abstract'");
			// The picker's rows: twenty characters typed one by one over the whole value catalogue.
			let all = CachedTypeEntries(.Value, "", ?);
			let again = CachedTypeEntries(.Value, "", ?);
			SelfTestCheck(all == again, "editor: sheet1: a type picker's entries are cached between frames");
			StringView typed = "core list of strings";
			double worst = 0;
			for (int i = 1; i <= 20; i++)
			{
				TypeCombo.BuildRows("##s1perf", typed.Substring(0, i), all, "", ?);
				worst = Math.Max(worst, TypeCombo.LastRowsMs);
			}
			SelfTestCheck(worst < 16, scope $"editor: sheet1: 20 characters typed in a type picker over {all.Count} types: each keystroke's rows in {worst:F2} ms (budget 16)");
			// A Construct node in Main, its type picker opened with "Motor" typed one character a frame.
			BeginEdit();
			let n = NodeFactory.Construct(main.Graph, "");
			n.X = 300;
			n.Y = 200;
			n.HasPos = true;
			mS1Construct = n.Id;
			CommitCurrent();
			CurrentTab?.SelectOnly(n.Id);
			TypeCombo.TestOpen.Set(scope $"##ntype{n.Key}");
			TypeCombo.TestType.Set("Motor");
		}

		void S1PickerOpen()
		{
			bool found = false;
			for (let r in TypeCombo.TestRows)
				found |= r.EndsWith(".Motor") && r.StartsWith("Project types|");
			SelfTestCheck(found, scope $"editor: sheet1: typing Motor in the Construct's picker lists Parts.Motor ({TypeCombo.TestRows.Count} rows)");
			TypeCombo.TestClose = true;
		}

		/// Finding 1: renaming a type renames its file and the references to it; undo carries both back.
		void S1Rename()
		{
			let gear = CreateType(.Class, mNtDir, "Gear");
			let program = S1Doc("Program");
			let main = S1Sheet(program, "Main");
			if (gear == null || main == null)
			{
				SelfTestCheck(false, "editor: sheet1: rename: Gear and Program.Main");
				return;
			}
			String full = gear.Header.GetFullName(.. scope String());
			program.PushUndo();
			let c = NodeFactory.Construct(main.Graph, full);
			c.X = 300;
			c.Y = 400;
			c.HasPos = true;
			program.Modified = true;
			program.Version++;
			Doc = gear;
			String err = scope .();
			program.TrySave(err);
			bool renamed = RenameType(gear, "Cog");
			String cogFull = scope .();
			gear.Header.GetFullName(cogFull);
			let mainNow = S1Sheet(program, "Main");
			bool refFollows = false;
			if (mainNow != null)
				for (let node in mainNow.Graph.Nodes)
					refFollows |= node.Kind == .Construct && node.Text == cogFull;
			SelfTestCheck(renamed && gear.Header.Name == "Cog" && File.Exists(scope $"{mNtDir}/Cog{GraphExtension}") && !File.Exists(scope $"{mNtDir}/Gear{GraphExtension}") && gear.GetName(.. scope String()) == "Cog",
				scope $"editor: sheet1: Type Settings > Name renames the type and its file ({gear.Header.Name}, {gear.FilePath})");
			SelfTestCheck(refFollows, scope $"editor: sheet1: a Construct of {full} in another type names {cogFull}");
			UndoDoc(false);
			let mainBack = S1Sheet(program, "Main");
			bool refBack = false;
			if (mainBack != null)
				for (let node in mainBack.Graph.Nodes)
					refBack |= node.Kind == .Construct && node.Text == full;
			SelfTestCheck(gear.Header.Name == "Gear" && File.Exists(scope $"{mNtDir}/Gear{GraphExtension}") && refBack, "editor: sheet1: undo of the rename brings back the name, the file and the reference");
			String bad = scope .(gear.Header.Name);
			RenameType(gear, "1Bad");
			SelfTestCheck(gear.Header.Name == bad, "editor: sheet1: a name that is not a type name is refused");
		}

		/// Finding 3: a function's row renamed in place, its text shared with Properties > Name.
		void S1InlineStart()
		{
			let engine = S1Doc("Engine");
			if (engine == null)
				return;
			Doc = engine;
			let m = AddFunctionMember("Spin");
			if (m == null)
				return;
			mS1Spin = m.Serial;
			let s = S1Sheet(engine, "Spin");
			if (s != null)
				OpenTab(s);
			SelectOutline(.Member, m);
			StartOutlineRename();
			SelfTestCheck(InlineRenaming(m), "editor: sheet1: F2 on a function's row starts renaming it in the row");
			let buf = TsBuf(mIrId, m.Name);
			buf.Set("Whi");
			SelfTestCheck(LiveName(scope $"##mname{m.Serial}", m.Name) == "Whi", "editor: sheet1: the row and Properties > Name show what is typed (one buffer)");
			mIrTestText.Set("Whirl");
		}

		void S1InlineField()
		{
			let engine = S1Doc("Engine");
			let m = (engine != null) ? FindMemberSerial(engine, mS1Spin) : null;
			bool tab = false;
			for (let t in Tabs)
				tab |= t.Title.Contains("Whirl");
			SelfTestCheck(m != null && m.Name == "Whirl" && engine.FindSheetByName("Whirl") != null && tab && mIrId.IsEmpty,
				scope $"editor: sheet1: Enter commits the in-place rename: the function, its Sheet and its tab are Whirl ({m?.Name})");
			// A variable: its Get on the canvas follows.
			let f = AddField("speed", "int");
			let s = (engine != null) ? engine.FindSheetByName("Whirl") : null;
			if (f == null || s == null)
				return;
			mS1Speed = f.Serial;
			BeginEdit();
			let get = NodeFactory.Get(s.Graph, "speed", "int");
			mS1SpeedGet = get.Id;
			CommitCurrent();
			SelectOutline(.Member, f);
			StartInlineRename(f);
			mIrTestText.Set("rpm");
		}

		void S1InlineLocal()
		{
			let engine = S1Doc("Engine");
			let f = (engine != null) ? FindMemberSerial(engine, mS1Speed) : null;
			let s = (engine != null) ? engine.FindSheetByName("Whirl") : null;
			let get = (s != null) ? s.Graph.FindNode(mS1SpeedGet) : null;
			String title = scope .();
			get?.GetTitle(title);
			SelfTestCheck(f != null && f.Name == "rpm" && get != null && get.Text.EndsWith("rpm"), scope $"editor: sheet1: a variable renamed in its row: its Get follows ({get?.Text}, '{title}')");
			if (s == null)
				return;
			AddLocalVariable(s);
			if (s.Graph.Locals.IsEmpty)
				return;
			let l = s.Graph.Locals.Back;
			mS1Local.Set(l.Name);
			mSelLocalActive = true;
			mSelLocalName.Set(l.Name);
			SelectOutline(.Local);
			StartOutlineRename();
			SelfTestCheck(InlineRenamingLocal(l.Name), "editor: sheet1: F2 on a local's row renames it in the row");
			mIrTestText.Set("counter");
		}

		static MemberDecl FindMemberSerial(TypeDocument d, int32 serial)
		{
			for (let m in d.Members)
				if (m.Serial == serial)
					return m;
			return null;
		}

		/// Finding 7: the value fields take what the type holds.
		void S1Values()
		{
			let engine = S1Doc("Engine");
			let s = (engine != null) ? engine.FindSheetByName("Whirl") : null;
			SelfTestCheck(s != null && s.Graph.FindLocal("counter") != null, "editor: sheet1: Enter commits a local's in-place rename");
			String lit = scope .();
			String why = scope .();
			bool okInt = PinValue.Write(.Number, "int", "42", false, lit, why);
			bool noFrac = !PinValue.Write(.Number, "int", "1.5", false, lit..Clear(), why..Clear());
			bool noRange = !PinValue.Write(.Number, "uint8", "300", false, lit..Clear(), why..Clear());
			bool noNeg = !PinValue.Write(.Number, "uint16", "-1", false, lit..Clear(), why..Clear());
			bool okFloat = PinValue.Write(.Number, "float", "1.5", false, lit..Clear(), why..Clear());
			SelfTestCheck(okInt && noFrac && noRange && noNeg && okFloat, "editor: sheet1: an integer value is a whole number in its type's range, a float takes a decimal");
		}

		/// Findings 9, 10, 18: Is Valid, Is Type, the Return a result brings.
		void S1Nodes()
		{
			let engine = S1Doc("Engine");
			let s = (engine != null) ? engine.FindSheetByName("Whirl") : null;
			if (s == null)
				return;
			let g = s.Graph;
			let valid = NodeFactory.Operator(g, "valid");
			let isType = NodeFactory.IsType(g, engine.Header.GetFullName(.. scope String()));
			String t1 = scope .();
			String t2 = scope .();
			valid.GetTitle(t1);
			isType.GetTitle(t2);
			SelfTestCheck(t1 == "Is Valid" && valid.Result?.TypeName == "bool" && valid.FindInput("b") == null && t2 == "Is Engine" && isType.Result?.TypeName == "bool" && isType.FindOutput("then") == null,
				scope $"editor: sheet1: Is Valid and Is Engine are bool value nodes ('{t1}', '{t2}')");
			let thisNode = NodeFactory.Create(g, .This);
			SelfTestCheck(Graph.CanConnectTyped(Language, thisNode.Result, valid.FindInput("a")) && Graph.CanConnectTyped(Language, thisNode.Result, isType.FindInput("value")),
				"editor: sheet1: an Engine wires into Is Valid and Is Type");
			g.RemoveNode(valid);
			g.RemoveNode(isType);
			g.RemoveNode(thisNode);
			// A Return Type on a function without a Return: one Return, with the type's default.
			Doc = engine;
			let m = AddFunctionMember("Compute");
			let cs = engine.FindSheetByName("Compute");
			if (m == null || cs == null)
				return;
			if (BeginTypeEdit())
			{
				m.Returns = TypeRef.Parse("int");
				EnsureReturnNode(m);
				SyncSheets(m);
				EndTypeEdit();
			}
			int returns = 0;
			Node ret = null;
			for (let n in cs.Graph.Nodes)
				if (n.Kind == .Return)
				{
					returns++;
					ret = n;
				}
			SelfTestCheck(returns == 1 && ret?.FindInput("value")?.TypeName == "int", scope $"editor: sheet1: Return Type int brings one Return with an int input ({returns})");
			if (BeginTypeEdit())
			{
				EnsureReturnNode(m);
				EndTypeEdit();
			}
			returns = 0;
			for (let n in cs.Graph.Nodes)
				returns += (n.Kind == .Return) ? 1 : 0;
			SelfTestCheck(returns == 1, "editor: sheet1: a second change does not add a second Return");
		}

		/// Finding 14: Create local variable on a value read by two flow nodes.
		void S1Promote()
		{
			let engine = S1Doc("Engine");
			let s = (engine != null) ? engine.FindSheetByName("Whirl") : null;
			if (s == null || CurrentTab == null)
				return;
			OpenTab(s);
			let g = s.Graph;
			BeginEdit();
			NodeFactory.AddLocal(g, "x", "int", "0");
			NodeFactory.AddLocal(g, "y", "int", "0");
			let plus = NodeFactory.Operator(g, "+");
			plus.FindInput("a")?.Default.Set("1");
			plus.FindInput("b")?.Default.Set("2");
			plus.Result.SetTypeText("int");
			let setX = NodeFactory.Set(g, "x", "int");
			let setY = NodeFactory.Set(g, "y", "int");
			g.Connect(g.Entry.FindOutput("then"), setX.FindInput("in"));
			g.Connect(setX.FindOutput("then"), setY.FindInput("in"));
			g.Connect(plus.Result, setX.FindInput("value"));
			g.Connect(plus.Result, setY.FindInput("value"));
			setX.X = 300; setY.X = 600; plus.X = 100; plus.Y = 200;
			CommitCurrent();
			Dictionary<int32, int32> counts = scope .();
			PinMatch.FanOut(g, counts);
			int before = counts.TryGetValue(plus.Id, let c0) ? c0 : 0;
			mGraphPanel.MakeVariableFromPin(CurrentTab, s, plus.Result, false);
			counts.Clear();
			PinMatch.FanOut(g, counts);
			int after = counts.TryGetValue(plus.Id, let c1) ? c1 : 0;
			let lx = g.FindLinkTo(setX.FindInput("value"));
			let ly = g.FindLinkTo(setY.FindInput("value"));
			bool readersOnGet = lx != null && ly != null && lx.From.Owner == ly.From.Owner && lx.From.Owner.Kind == .Get;
			SelfTestCheck(before == 2 && after <= 1 && readersOnGet, scope $"editor: sheet1: Create local variable on a value read twice: a Set in the flow, both readers on one Get (evaluated {before}x, then {after}x)");
		}

		/// Findings 15, 16, 17: nudges, a variable dropped on a pin, Q onto the last selected.
		void S1Canvas()
		{
			let tab = CurrentTab;
			let mg = CurrentMethod;
			if (tab == null || mg == null)
				return;
			let g = mg.Graph;
			BeginEdit();
			let sel = NodeFactory.Select(g);
			sel.X = 400;
			sel.Y = 400;
			sel.HasPos = true;
			NodeFactory.AddLocal(g, "c", "bool", "false");
			NodeFactory.AddLocal(g, "p", "int", "0");
			NodeFactory.AddLocal(g, "q", "int", "0");
			let gc = NodeFactory.Get(g, "c", "bool");
			let gp = NodeFactory.Get(g, "p", "int");
			let gq = NodeFactory.Get(g, "q", "int");
			int32 i = 0;
			for (let n in Node[?](gc, gp, gq))
			{
				n.X = 700;
				n.Y = 400 + 8 * i++;
				n.HasPos = true;
			}
			g.Connect(gc.Result, sel.FindInput("condition"));
			g.Connect(gp.Result, sel.FindInput("true"));
			g.Connect(gq.Result, sel.FindInput("false"));
			CommitCurrent();
			// Arrow nudges: one grid step, Shift ten.
			tab.SelectOnly(sel.Id);
			float x0 = sel.X;
			mGraphPanel.NudgeSelection(tab, g, 1, 0);
			mGraphPanel.NudgeSelection(tab, g, 1, 0, true);
			SelfTestCheck(Math.Abs(sel.X - (x0 + Canvas.SnapGrid * 11)) < 0.01f, scope $"editor: sheet1: Right moves the selection a grid step, Shift+Right ten ({x0} -> {sel.X})");
			mS1Sel = sel.Id;
			mS1Gets[0] = gc.Id;
			mS1Gets[1] = gp.Id;
			mS1Gets[2] = gq.Id;
		}

		int32 mS1Sel;
		int32[3] mS1Gets;

		/// The nodes are laid out now (pin positions known).
		void S1CanvasAfter()
		{
			let tab = CurrentTab;
			let mg = CurrentMethod;
			if (tab == null || mg == null)
				return;
			let g = mg.Graph;
			let sel = g.FindNode(mS1Sel);
			let gc = g.FindNode(mS1Gets[0]);
			let gp = g.FindNode(mS1Gets[1]);
			let gq = g.FindNode(mS1Gets[2]);
			if (sel == null || gc == null || gp == null || gq == null)
			{
				SelfTestCheck(false, "editor: sheet1: the Select and its Gets are on the Sheet");
				return;
			}
			// Q: the three Gets selected, then the Select: each lines up with its own pin, left of the Select.
			tab.ClearSelection();
			for (let n in Node[?](gc, gp, gq, sel))
				tab.AddToSelection(n.Id);
			AlignSelection(tab, .Straighten);
			bool left = gc.X < sel.X && gp.X < sel.X && gq.X < sel.X;
			bool ordered = gc.Y < gp.Y && gp.Y < gq.Y;
			SelfTestCheck(left && ordered, scope $"editor: sheet1: Q aligns the Gets to the last selected Select, left of it, each at its own pin ({gc.Y}, {gp.Y}, {gq.Y})");
			// A variable dropped on an int input with no key held: a Get wired into it.
			let add = NodeFactory.Operator(g, "+");
			add.X = 900;
			add.Y = 900;
			add.HasPos = true;
			int32 index = -1;
			for (let r in mMembers)
				if (r.Name == "rpm")
					index = (int32)@r.Index;
			let pin = add.FindInput("b");
			pin.SetTypeText("int");
			if (index >= 0)
				DropMember(tab, index, .(700, 900), pin.Id, true);
			let link = g.FindLinkTo(pin);
			SelfTestCheck(index >= 0 && link != null && link.From.Owner.Kind == .Get, scope $"editor: sheet1: a variable dropped on a pin it fits is wired as a Get without Ctrl (row {index})");
		}

		/// Finding 19: a child class sees its base's public and protected variables in the Outline.
		void S1Inherited()
		{
			let b = CreateType(.Class, mNtDir, "Limb");
			if (b == null)
				return;
			Doc = b;
			let legs = AddField("Legs", "int");
			let secret = AddField("Secret", "int");
			if (legs != null)
				legs.Access = .Public;
			if (secret != null)
				secret.Access = .Private;
			b.Version++;
			String why = scope .();
			b.TrySave(why);
			let child = CreateType(.Class, mNtDir, "Arm", b.Header.GetFullName(.. scope String()));
			if (child != null)
			{
				Doc = child;
				SelectOutline(.TypeSettings);
				// The group is open: its header state is per name.
				if (mBPClosed.GetAndRemove("cat:Inherited") case .Ok(let s))
					delete s;
			}
		}

		/// Finding 11: yellow until Validate after an edit.
		void S1Status()
		{
			String text = scope .();
			ValidateStateText(text, let color, ?);
			SelfTestCheck(text == "Not validated" && color == Look.AccentYellow, scope $"editor: sheet1: after an edit the status bar says Not validated in yellow ({text})");
			SelfTestCheck(GetCompileState() != .Good, "editor: sheet1: the build state is not Up to date after an edit");
		}
	}
}
#endif
