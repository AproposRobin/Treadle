// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using Treadle.Document;
using Treadle.Graph;
using ImGui;

namespace Treadle.Editor
{
	/// The `editor` self test's Lambda part (LambdaEditing.bf, LambdaProperties.bf): a Lambda placed
	/// from a delegate input gets the type, the inputs and the Sheet's Entry / Return pins; renaming
	/// and adding inputs moves the Entry pins (undo brings the old name back); a by-reference
	/// capture is refused on a Construct Lambda and written on a Local one.
	extension EditorApp
	{
		/// The `hold:` step ends at this time (seconds, Gui time; 0 = not holding).
		double mSelfTestHoldUntil;

		/// A pin named `<node id>.<pin>` in the Sheet in front (null when there is none).
		Pin SelfTestPin(StringView spec)
		{
			let dot = spec.IndexOf('.');
			let mg = CurrentMethod;
			if (dot <= 0 || mg == null)
				return null;
			let n = mg.Graph.FindNodeByKey(spec.Substring(0, dot));
			if (n == null)
				return null;
			let name = spec.Substring(dot + 1);
			return n.FindInput(name) ?? n.FindOutput(name);
		}

		/// Capture helpers for the pixel pass (TREADLE_SELFTEST steps; the editor stays open while a
		/// `hold:` runs): `open:<Sheet name>` (of any open document), `openlambda:<node id>` (the
		/// Lambda Sheet of that node in the Sheet in front), `selectkey:<node id>`, `validate`
		/// (compiles now, so the captures are known), `menupin:<node id>.<pin>` (the Node menu
		/// dragged from that pin), `placepin:<node id>.<pin>` (Enter in that menu), `frameselected`,
		/// `opensheet:<file under the project folder>|<Sheet name>`, `arrange` (the
		/// toolbar's Arrange on the Sheet in front, not saved), `menuclose`, `theme:<0|1>`
		/// (Dark / Darker), `hold:<name>` (logs `[SELFTEST] hold <name>`, then waits 3 s for the
		/// capture). False when `test` is none of them.
		bool SelfTestCaptureStep(StringView test, ref bool finished)
		{
			if (test.StartsWith("open:"))
			{
				let name = test.Substring(5);
				for (let d in mDocs)
				{
					let s = d.FindSheetByName(name);
					if (s != null)
					{
						OpenTab(s);
						break;
					}
				}
				return true;
			}
			if (test.StartsWith("openlambda:"))
			{
				let n = CurrentMethod?.Graph.FindNodeByKey(test.Substring(11));
				if (n != null && n.Kind == .Lambda)
					OpenLambdaSheet(n);
				return true;
			}
			if (test.StartsWith("selectkey:"))
			{
				let n = CurrentMethod?.Graph.FindNodeByKey(test.Substring(10));
				if (n != null && CurrentTab != null)
				{
					OutlineSel = .None;
					CurrentTab.SelectOnly(n.Id);
				}
				return true;
			}
			if (test == "validate")
			{
				let _ = FrontEnd?.Current;
				Validate(true);
				return true;
			}
			if (test.StartsWith("menupin:") || test.StartsWith("placepin:"))
			{
				let place = test.StartsWith("placepin:");
				let pin = SelfTestPin(test.Substring(place ? 9 : 8));
				if (pin == null || CurrentTab == null)
				{
					SelfTestCheck(false, scope $"capture: no pin {test}");
					return true;
				}
				mActionTab = CurrentTab;
				let at = ImVec2(pin.Owner.X - 80, pin.Owner.Y + 220);
				if (!place)
				{
					mNodeMenu.SelfTestPos = .(380 * Look.Scale, 160 * Look.Scale);
					OpenNodeMenu(CurrentTab, at, pin.Id);
					return true;
				}
				let row = mNodeMenu.DefaultRowFor(CurrentMethod, at, pin.Id, "");
				if (row != null)
				{
					ExecuteAction(row);
					delete row;
				}
				return true;
			}
			if (test == "frameselected")
			{
				if (CurrentTab != null && CurrentMethod != null)
					mGraphPanel.FrameNodes(CurrentTab, CurrentMethod.Graph, true);
				return true;
			}
			if (test.StartsWith("opensheet:"))
			{
				// `opensheet:<file under the project folder>|<Sheet name>`: opens that type file's Sheet.
				let spec = test.Substring(10);
				let bar = spec.IndexOf('|');
				if (bar > 0)
				{
					String path = scope $"{mProjectRoot}/{spec.Substring(0, bar)}";
					SelfTestCheck(OpenSheet(path, spec.Substring(bar + 1)), scope $"capture: {test} opens");
				}
				return true;
			}
			if (test == "arrange")
			{
				ArrangeCurrentGraph();
				return true;
			}
			if (test == "menuclose")
			{
				mNodeMenu.CloseRequested = true;
				return true;
			}
			if (test.StartsWith("theme:"))
			{
				if (int32.Parse(test.Substring(6)) case .Ok(let t))
				{
					Prefs.Theme = Math.Clamp(t, 0, 1);
					Prefs.ApplyAppearance();
				}
				return true;
			}
			if (test.StartsWith("hold:"))
			{
				let now = ImGui.Gui.igGetTime();
				if (mSelfTestHoldUntil == 0)
				{
					mSelfTestHoldUntil = now + 3.0;
					Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] hold {test.Substring(5)}");
				}
				if (now < mSelfTestHoldUntil)
				{
					finished = false;
					return true;
				}
				mSelfTestHoldUntil = 0;
				return true;
			}
			return false;
		}

		static bool EntryHas(Sheet ls, Span<StringView> names)
		{
			let entry = ls.Graph.Entry;
			if (entry == null)
				return false;
			int i = 0;
			for (let p in entry.Outputs)
			{
				if (p.Kind != .Value)
					continue;
				if (i >= names.Length || p.Name != names[i])
					return false;
				i++;
			}
			return i == names.Length;
		}

		void SelfTestLambdaUI()
		{
			let sheet = EditDoc?.FindSheetByName("TakeDamage");
			if (sheet == null)
			{
				SelfTestCheck(false, "editor: lambda: the TakeDamage Sheet is there");
				return;
			}
			OpenTab(sheet);
			let mg = CurrentMethod;
			let g = mg.Graph;
			let doc = mg.Doc;
			mActionTab = CurrentTab;

			// A flow Call with a delegate input, after a node that runs (so the Lambda is chained in).
			BeginEdit();
			StringView[1] pnames = .("f");
			StringView[1] ptypes = .("delegate:int(int,int)");
			let call = NodeFactory.Call(g, "this.Combine", true, pnames, ptypes, "int");
			call.X = 600;
			call.Y = 2000;
			call.HasPos = true;
			let before = NodeFactory.Create(g, .Sequence);
			before.X = 200;
			before.Y = 2000;
			before.HasPos = true;
			g.Connect(before.FindOutput("then0"), call.ExecIn);
			CommitCurrent();
			let fPin = call.FindInput("f");

			// The Node menu dragged from it: Lambda first, Enter places it.
			let row = mNodeMenu.DefaultRowFor(mg, .(560, 2100), fPin.Id, "");
			SelfTestCheck(row != null && row.Kind == .Lambda && mNodeMenu.ContextLambdaSignature == "int(int, int)",
				scope $"editor: lambda: dragged from a delegate input the Node menu offers Lambda first ({(row != null) ? (StringView)row.Label : "none"}, {mNodeMenu.ContextLambdaSignature})");
			let n = (row != null) ? ExecuteAction(row) : null;
			delete row;
			if (n == null || n.Kind != .Lambda)
			{
				SelfTestCheck(false, "editor: lambda: the Lambda is placed");
				return;
			}
			let ls = FindLambdaSheet(doc, mg, n.Key);
			let ret = (ls != null) ? FindNode(ls.Graph, .Return) : null;
			let wired = g.FindLinkTo(fPin)?.From?.Owner == n;
			let chained = n.ExecIn != null && g.IsLinked(n.ExecIn) && g.ExecTarget(n.Then) == call;
			StringView[2] ab = .("a", "b");
			SelfTestCheck(n.GetSetting("type") == "delegate:int(int,int)" && n.GetSetting("inputs") == "a b" && n.GetSetting("alloc") == "local" && wired && chained,
				scope $"editor: lambda: it gives the pin's type, names its inputs, is Local and runs before the Call (type '{n.GetSetting("type")}', inputs '{n.GetSetting("inputs")}', alloc '{n.GetSetting("alloc")}', wired {wired}, chained {chained})");
			SelfTestCheck(ls != null && EntryHas(ls, ab) && ls.Graph.Entry.FindOutput("a").TypeName == "int" && ret != null && ret.FindInput("value")?.TypeName == "int" && ls.Graph.IsLinked(ret.ExecIn),
				"editor: lambda: its Sheet has the Entry pins a, b (int) and a Return wired after the Entry");
			if (ls == null || ret == null)
				return;

			// Renaming an input moves the Entry pin with its wire; undo brings the old name back.
			ls.Graph.Connect(ls.Graph.Entry.FindOutput("b"), ret.FindInput("value"));
			String key = scope .(n.Key);
			String why = scope .();
			BeginEdit();
			let renamed = RenameLambdaInput(mg, n, 1, "right", why);
			CommitCurrent();
			StringView[2] aRight = .("a", "right");
			let rightPin = ls.Graph.Entry.FindOutput("right");
			SelfTestCheck(renamed && n.GetSetting("inputs") == "a right" && EntryHas(ls, aRight) && rightPin != null && ls.Graph.IsLinked(rightPin),
				scope $"editor: lambda: renaming an input rewrites set inputs and the Entry pin, the wire stays ({n.GetSetting("inputs")}{why})");
			why.Clear();
			SelfTestCheck(!RenameLambdaInput(mg, n, 0, "right", why) && !why.IsEmpty, scope $"editor: lambda: a name another input has is refused ({why})");
			doc.Undo();
			let n2 = CurrentMethod.Graph.FindNodeByKey(key);
			let ls2 = (n2 != null) ? FindLambdaSheet(doc, CurrentMethod, key) : null;
			SelfTestCheck(n2 != null && n2.GetSetting("inputs") == "a b" && ls2 != null && EntryHas(ls2, ab), "editor: lambda: undo brings the old input name and Entry pin back");
			doc.Redo();
			let n3 = CurrentMethod.Graph.FindNodeByKey(key);
			let ls3 = (n3 != null) ? FindLambdaSheet(doc, CurrentMethod, key) : null;
			if (n3 == null || ls3 == null)
			{
				SelfTestCheck(false, "editor: lambda: redo brings the Lambda back");
				return;
			}

			// A custom signature with a third input: the Entry gets it.
			BeginEdit();
			SetLambdaTypeFromProperties(CurrentMethod, n3, "delegate:int(int,int,int)");
			CommitCurrent();
			StringView[3] three = .("a", "right", "c");
			SelfTestCheck(n3.GetSetting("inputs") == "a right c" && EntryHas(ls3, three), scope $"editor: lambda: an input added to the signature is an Entry pin ({n3.GetSetting("inputs")})");

			// By reference: refused on a Construct Lambda, written on a Local one.
			BeginEdit();
			SetLambdaAllocFromProperties(CurrentMethod, n3, "construct");
			CommitCurrent();
			why.Clear();
			let refused = !SetLambdaCaptureByRef(CurrentMethod, n3, "amount", true, why);
			SelfTestCheck(refused && why.Contains("Local") && NodeFactory.FindCapture(n3, "amount") == null,
				scope $"editor: lambda: a by-reference capture is refused on a Construct Lambda ({why})");
			BeginEdit();
			SetLambdaAllocFromProperties(CurrentMethod, n3, "local");
			why.Clear();
			let allowed = SetLambdaCaptureByRef(CurrentMethod, n3, "amount", true, why);
			CommitCurrent();
			let line = NodeFactory.FindCapture(n3, "amount");
			SelfTestCheck(allowed && line != null && line.Value == "amount by-ref" && !line.IsSet, scope $"editor: lambda: on a Local Lambda it writes capture amount by-ref ({why})");
			// Construct again: the by-reference line becomes by value.
			BeginEdit();
			SetLambdaAllocFromProperties(CurrentMethod, n3, "construct");
			CommitCurrent();
			SelfTestCheck(NodeFactory.FindCapture(n3, "amount") == null, "editor: lambda: switching to Construct drops the by-reference capture");
		}
	}
}
#endif
