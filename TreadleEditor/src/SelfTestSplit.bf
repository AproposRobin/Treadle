// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using System.IO;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Model;
using Treadle.Format;
using Treadle.Compiler;

namespace Treadle.Editor
{
	/// The `editor` self test's split struct pins (SplitPins, SplitPinsEditor.bf): the Node menu from a
	/// generic struct's pin, Split / Recombine with undo, Validate and the wires to field pins through a
	/// save and a read, and a small program with split pins built and run.
	extension EditorApp
	{
		/// Record ids of SplitDemo's Set mPair, Get mPair and Set mHealth.
		String mSplitKeys = new .() ~ delete _;

		Node SplitKey(int index)
		{
			int i = 0;
			for (let w in mSplitKeys.Split(' '))
				if (i++ == index)
					return CurrentMethod?.Graph.FindNodeByKey(w);
			return null;
		}

		/// Phase 0: SplitDemo(int amount) with Set mPair (a Pair<int,float> field), Get mPair and Set
		/// mHealth; the Node menu from Get mPair's output lists Break Pair<int,float>, from Set mPair's
		/// input Make Pair<int,float>. Phase 1: Split Struct Pin on both (one undo step each), wires and a
		/// literal on the field pins. Phase 2: Validate clean with the field pins typed, the file keeps
		/// `split` and the wires to the field pins through a write and a read, Recombine with undo.
		/// Phase 3: a program with split pins lowers and runs.
		void UX2Split(int phase)
		{
			let doc = Doc;
			switch (phase)
			{
			case 0:
				AddField("mPair", "Core.Pair<int,float>");
				let m = AddFunctionMember("SplitDemo");
				if (m == null)
				{
					SelfTestCheck(false, "editor: a SplitDemo function for the split pins");
					return;
				}
				AddParam(m, false);
				let s = doc.FindSheetByName("SplitDemo");
				OpenTab(s);
				let g = s.Graph;
				let ep = g.Entry.FindOutput(m.Params[0].Name);
				ep?.Name.Set("amount");
				ep?.Label.Set("amount");
				m.Params[0].Name.Set("amount");
				BeginEdit();
				let setP = NodeFactory.Set(g, "mPair", "Core.Pair<int,float>");
				let getP = NodeFactory.Get(g, "mPair", "Core.Pair<int,float>");
				let setH = NodeFactory.Set(g, "mHealth", "int");
				setP.X = 300; setP.Y = 0;
				getP.X = 300; getP.Y = 260;
				setH.X = 820; setH.Y = 0;
				for (let n in Node[?](setP, getP, setH))
					n.HasPos = true;
				g.Connect(g.Entry.Then, setP.ExecIn);
				g.Connect(setP.Then, setH.ExecIn);
				g.AutoLaidOut = false;
				KeyAssigner.Assign(g);
				mSplitKeys.Clear();
				mSplitKeys.AppendF("{} {} {}", setP.Key, getP.Key, setH.Key);
				CommitCurrent();
				List<NodeItem> rows = scope .();
				defer { ClearAndDeleteItems!(rows); }
				mNodeMenu.ListFor(s, getP.FindOutput("value").Id, "", rows);
				bool brk = false;
				for (let r in rows)
					brk |= r.Label == "Break Pair<int,float>";
				ClearAndDeleteItems!(rows);
				mNodeMenu.ListFor(s, setP.FindInput("value").Id, "", rows);
				bool make = false;
				for (let r in rows)
					make |= r.Label == "Make Pair<int,float>";
				SelfTestCheck(brk && make, scope $"editor: the Node menu from a Pair<int,float> output lists Break Pair<int,float> ({brk}), into an input Make Pair<int,float> ({make})");
			case 1:
				let g = CurrentMethod.Graph;
				let setP = SplitKey(0);
				let getP = SplitKey(1);
				let setH = SplitKey(2);
				if (setP == null || getP == null || setH == null)
				{
					SelfTestCheck(false, "editor: the SplitDemo nodes");
					return;
				}
				let pin = setP.FindInput("value");
				bool split = SplitStructPin(CurrentMethod, pin);
				let first = setP.FindInput("value.First");
				let second = setP.FindInput("value.Second");
				SelfTestCheck(split && SplitPins.IsSplit(pin) && first != null && second != null && first.TypeName == "int" && second.TypeName == "float" &&
					setP.Inputs.IndexOf(first) == setP.Inputs.IndexOf(pin) + 1 && setP.GetSetting(SplitPins.Key) == scope String()..AppendF("value {}", pin.TypeName) && pin.TypeName.Contains("Pair<int,float>"),
					scope $"editor: Split Struct Pin gives Set mPair the pins value.First (int) and value.Second (float) after its value pin ({(first != null) ? first.TypeName : "-"}, {(second != null) ? second.TypeName : "-"}, split {setP.GetSetting(SplitPins.Key)}, at {setP.Inputs.IndexOf(first)} after {setP.Inputs.IndexOf(pin)})");
				doc.Undo();
				let setP2 = SplitKey(0);
				SelfTestCheck(setP2 != null && setP2.FindInput("value.First") == null && !SplitPins.IsSplit(setP2.FindInput("value")), "editor: one undo puts the struct pin back");
				doc.Redo();
				let g2 = CurrentMethod.Graph;
				let setP3 = SplitKey(0);
				let getP3 = SplitKey(1);
				let setH3 = SplitKey(2);
				bool splitOut = SplitStructPin(CurrentMethod, getP3.FindOutput("value"));
				BeginEdit();
				g2.Connect(g2.Entry.FindOutput("amount"), setP3.FindInput("value.First"));
				setP3.FindInput("value.Second")?.Default.Set("2.5");
				g2.Connect(getP3.FindOutput("value.First"), setH3.FindInput("value"));
				CommitCurrent();
				SelfTestCheck(splitOut && getP3.FindOutput("value.First") != null && g2.IsLinked(getP3.FindOutput("value.First")),
					"editor: Split Struct Pin on Get mPair's output gives value.First and value.Second outputs, wired on");
				let _ = g;
			case 2:
				let g = CurrentMethod.Graph;
				let setP = SplitKey(0);
				let getP = SplitKey(1);
				let setH = SplitKey(2);
				Validate(true);
				String errs = scope .();
				if (mValidate != null)
					for (let d in mValidate.Messages)
						if (d.IsError && d.MethodKey == CurrentMethod.Key)
							errs.AppendF(" [{}]", d.Text);
				SelfTestCheck(mValidate != null && errs.IsEmpty && g.Errors.IsEmpty, scope $"editor: Validate binds the split pins as a Make and a Break: no error in SplitDemo{errs}");
				SelfTestCheck(getP.FindOutput("value.Second")?.TypeName == "float" && setP.FindInput("value.First")?.TypeName == "int",
					"editor: the field pins have the types the compiler gives them");
				// The file: the `split` lines, the wires to the field pins and the literal, read back.
				String text = scope .();
				String why = scope .();
				doc.WriteText(text, why);
				String wire = scope $"wire {g.Entry.Key}.amount {setP.Key}.value.First\n";
				String wire2 = scope $"wire {getP.Key}.value.First {setH.Key}.value\n";
				String splitLine = scope $"\tsplit {setP.GetSetting(SplitPins.Key)}\n";
				bool written = splitLine.Contains("Pair<int,float>") && text.Contains(splitLine) && text.Contains(wire) && text.Contains(wire2) && text.Contains("\tin value.Second 2.5\n");
				TypeDocument back = scope .(Language);
				back.FilePath.Set(doc.FilePath);
				String err = scope .();
				bool read = back.LoadText(text, err);
				let bs = back.FindSheetByName("SplitDemo");
				let bg = bs?.Graph;
				let bSet = bg?.FindNodeByKey(setP.Key);
				let bGet = bg?.FindNodeByKey(getP.Key);
				// As the editor does when it first shows the Sheet: the field pins in the struct's order.
				if (bs != null)
					EnsureSplitSubPins(bs);
				String why2 = scope .();
				if (bSet == null || bGet == null)
					why2.Append(" nodes");
				else
				{
					if (!SplitPins.IsSplit(bSet.FindInput("value"))) why2.Append(" notsplit");
					if (bg.DataSource(bSet.FindInput("value.First")) != bg.Entry) why2.Append(" firstwire");
					if (bSet.FindInput("value.Second")?.Default != "2.5") why2.Append(" literal");
					if (!bg.IsLinked(bGet.FindOutput("value.First"))) why2.Append(" outwire");
					if (bSet.Inputs.IndexOf(bSet.FindInput("value.First")) != bSet.Inputs.IndexOf(bSet.FindInput("value")) + 1) why2.Append(" order");
				}
				bool kept = why2.IsEmpty;
				err.Append(why2);
				String back2 = scope .();
				back.WriteText(back2, why);
				SelfTestCheck(written && read && kept && back2 == text, scope $"codec: `split value <Type>`, the wires to field pins and a field's literal survive a write and a read ({written} {read} {kept}) {err}");
				if (!written || !kept)
					Notify.Log(.Info, "SelfTest", scope $"[SELFTEST]      written:\n{text}");
				// Recombine from a field pin: the field pins and their wires go; undo brings them back.
				bool recombined = RecombineStructPin(CurrentMethod, getP.FindOutput("value.First"));
				bool gone = getP.FindOutput("value.First") == null && !SplitPins.IsSplit(getP.FindOutput("value")) && !g.IsLinked(setH.FindInput("value"));
				doc.Undo();
				let getP2 = SplitKey(1);
				let setH2 = SplitKey(2);
				SelfTestCheck(recombined && gone && getP2 != null && CurrentMethod.Graph.IsLinked(getP2.FindOutput("value.First")) && CurrentMethod.Graph.IsLinked(setH2.FindInput("value")),
					"editor: Recombine Struct Pin removes the field pins and their wires; undo brings them back");
			case 3:
				UX2SplitProgram();
				let take = doc.FindSheetByName("TakeDamage");
				if (take != null)
					OpenTab(take);
			}
		}

		/// A program whose Set and Get of a local `Vec2` have split pins (X 40, Y 2 in; X + Y out) lowers
		/// and prints 42 in Debug.
		void UX2SplitProgram()
		{
			StringView vec2 = "# treadle 1\ntype Vec2 struct\n\tnamespace Cx\n\nfield X int\n\nfield Y int\n";
			String main = scope .();
			main.Append("# treadle 1\ntype SplitMain class\n\tnamespace Cx\n\tstatic\n\nfunction m1 Main\n\tstatic\n\treturns int\nlocal p Cx.Vec2\nsheet body\n");
			main.Append("node a1 Entry\nnode a2 Set local:p\n\tsplit value Cx.Vec2\n\tin value.X 40\n\tin value.Y 2\nnode a3 Get local:p\n\tsplit value Cx.Vec2\n");
			main.Append("node a4 Operator +\nnode a5 Call Console.WriteLine(int)\nnode a6 Return\n\tin value 0\n");
			main.Append("wire a1.then a2.in\nwire a2.then a5.in\nwire a3.value.X a4.a\nwire a3.value.Y a4.b\nwire a4.result a5.value\nwire a5.then a6.in\n");
			List<TypeDocument> docs = scope .();
			defer { ClearAndDeleteItems!(docs); }
			List<FormatError> errs = scope .();
			defer { ClearAndDeleteItems!(errs); }
			for (let text in StringView[?](vec2, StringView(main)))
			{
				TypeDocument d = new .();
				d.FilePath.Set(scope $"split{docs.Count}.treadle");
				docs.Add(d);
				TreadleCodec.ReadAll(text, d, errs);
			}
			SelfTestCheck(errs.IsEmpty, "codec: a type file with split pins reads");
			let c = ProjectLoader.Make("", null, null, null, docs);
			defer delete c;
			c.Run();
			String kir = scope .();
			let lowered = c.Diags.Items.Count == 0 && Lowering.WriteProgram(c, "splitpins", "Cx.SplitMain", kir);
			SelfTestCheck(lowered, "editor: a program with split pins validates clean and lowers");
			if (!lowered)
				LogDiags(c);
			if (!lowered || !Treadle.Backend.Driver.ToolchainPaths.Found)
				return;
			String temp = scope .();
			if (!SelfTestTemp.Get(temp))
				return;
			String work = scope $"{temp}/treadle-split-{(int)Platform.BfpSystem_GetTimeStamp() & 0xFFFFFF}";
			Directory.CreateDirectory(work).IgnoreError();
			String kirPath = scope $"{work}/splitpins.tir";
			File.WriteAllText(kirPath, kir).IgnoreError();
			File.WriteAllText(scope $"{work}/splitpins.expected", "== exit\n0\n== stdout\n42\n").IgnoreError();
			Treadle.Backend.Testing.FixtureResult r = scope .();
			Treadle.Backend.Testing.FixtureRunner.Run(kirPath, "Debug", work, r);
			SelfTestCheck(r.Passed, scope $"editor: the split-pin program runs and prints 42 (Debug): {r.Detail}");
			if (!r.Passed)
				Notify.Log(.Info, "SelfTest", scope $"[SELFTEST]      stdout:\n{r.Stdout}\n      stderr:\n{r.Stderr}");
			DeleteTree(work);
		}
	}
}
#endif
