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
using Treadle.Model;

namespace Treadle.Editor
{
	/// The `tutorial` capture case (docs/Getting-Started.md): performs the tutorial's steps on a fresh
	/// project through the calls the editor's UI makes (New Project, the C import, New Type, Type Settings,
	/// the Outline's "+" rows, the Node menu's search with the row Enter takes, wires dropped
	/// on pins, values typed into pins, Arrange, Build, Run Without Debugging, a breakpoint, Start Debugging,
	/// Step Into) and checks each one. Where the page shows a picture the case logs
	/// `[SELFTEST] hold tutorial-<NN-name>` and waits 4 s so an outside script can capture the window. The
	/// project is made in TREADLE_TUTORIAL_DIR (a folder with no `Zoo` in it), else in the temp folder; the
	/// case leaves it there for the caller.
	extension EditorApp
	{
		[CLink] static extern void igClosePopupToLevel(int32 remaining, bool restore_focus);

		String mTutLocation = new .() ~ delete _;
		String mTutRoot = new .() ~ delete _;
		/// The case's names for the placed nodes -> their node keys (in the Sheet they were placed in).
		Dictionary<String, String> mTutKeys = new .() ~ { for (let kv in _) { delete kv.key; delete kv.value; } delete _; };
		double mTutHoldUntil;
		Stopwatch mTutWatch = new .() ~ delete _;
		bool mTutFailed;
		/// The case made its own folder under %TEMP% (no TREADLE_TUTORIAL_DIR) and deletes it at the end.
		bool mTutOwnDir;
		int32 mTutLaunchBase;
		const int cTutEnd = 90;

		/// Waits 4 s with a `hold` line logged for the capture; false while waiting.
		bool TutHold(StringView name)
		{
			let now = ImGui.Gui.igGetTime();
			if (mTutHoldUntil == 0)
			{
				mTutHoldUntil = now + 4.0;
				Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] hold tutorial-{name}");
			}
			if (now < mTutHoldUntil)
			{
				mSelfTestStep--;
				return false;
			}
			mTutHoldUntil = 0;
			return true;
		}

		/// Waits for `cond`; on timeout the case fails and ends.
		bool TutWait(bool cond, StringView what, double seconds = 120)
		{
			if (cond)
			{
				mTutWatch.Restart();
				return true;
			}
			if (mTutWatch.Elapsed.TotalSeconds > seconds)
			{
				SelfTestCheck(false, scope $"tutorial: timed out waiting for {what}");
				return TutAbort();
			}
			mSelfTestStep--;
			return false;
		}

		bool TutAbort()
		{
			mTutFailed = true;
			mSelfTestStep = cTutEnd - 1;
			return false;
		}

		void TutCheck(bool ok, StringView what)
		{
			SelfTestCheck(ok, scope $"tutorial: {what}");
			if (!ok)
				mTutFailed = true;
		}

		Node TutNode(StringView name)
		{
			if (mTutKeys.TryGetValueAlt(name, let key))
				return CurrentMethod?.Graph.FindNodeByKey(key);
			return null;
		}

		void TutRemember(StringView name, StringView key)
		{
			if (mTutKeys.GetAndRemoveAlt(name) case .Ok(let old))
			{
				delete old.key;
				delete old.value;
			}
			mTutKeys[new String(name)] = new String(key);
		}

		/// A pin of a node by its stored name (`receiver` finds the Receiver whatever its name).
		static Pin TutPin(Node n, StringView name)
		{
			if (n == null)
				return null;
			if (name == "receiver")
				for (let p in n.Inputs)
					if (p.Role == .Receiver)
						return p;
			return n.FindOutput(name) ?? n.FindInput(name);
		}

		/// The name of a node's first value input that is not its Receiver (a Call's first argument).
		static StringView TutFirstValueIn(Node n)
		{
			if (n != null)
				for (let p in n.Inputs)
					if (p.Kind == .Value && p.Role != .Receiver)
						return p.Name;
			return "";
		}

		static StringView TutFirstValueOut(Node n)
		{
			if (n != null)
				for (let p in n.Outputs)
					if (p.Kind == .Value)
						return p.Name;
			return "";
		}

		/// The Node menu dragged from `fromPin` of `from` (or opened on the canvas), `search` typed, Enter:
		/// the row Enter takes must start with `expect`.
		Node TutPlace(StringView name, StringView search, StringView expect, Node from = null, StringView fromPin = "")
		{
			let mg = CurrentMethod;
			if (mg == null)
			{
				TutCheck(false, scope $"no Sheet in front to place '{expect}'");
				return null;
			}
			Pin pin = null;
			if (from != null)
			{
				pin = TutPin(from, fromPin);
				if (pin == null)
				{
					TutCheck(false, scope $"no pin '{fromPin}' on {from.Kind} {from.Text} to drag '{expect}' from");
					return null;
				}
			}
			float x = (from != null) ? from.X + 320 : 400;
			float y = (from != null) ? from.Y : 200;
			mActionTab = CurrentTab;
			let item = mNodeMenu.DefaultRowFor(mg, .(x, y), (pin != null) ? pin.Id : 0, search);
			if (item == null || !item.Label.StartsWith(expect) || (item.Kind == .ConstructCall && !expect.Contains(" + ")))
			{
				List<NodeItem> rows = scope .();
				defer { ClearAndDeleteItems!(rows); }
				mNodeMenu.ListFor(mg, (pin != null) ? pin.Id : 0, search, rows);
				String list = scope .();
				for (let r in rows)
					if (@r.Index < 12)
						list.AppendF("[{}] {}, ", r.Category, r.Label);
				TutCheck(false, scope $"typing '{search}' in the Node menu (dragged from '{fromPin}') gives '{(item != null) ? item.Label : "nothing"}', not '{expect}'; rows: {list}");
				delete item;
				return null;
			}
			String label = scope .(item.Label);
			let n = ExecuteAction(item);
			delete item;
			TutCheck(n != null && (pin == null || mg.Graph.IsLinked(pin)), scope $"'{search}' + Enter places {label} (dragged from '{fromPin}')");
			if (n == null)
				return null;
			CurrentTab?.ClearSelection(); // the placed node is not left selected: docs/Follow-ups.md, the Overload row crash
			TutRemember(name, n.Key);
			return n;
		}

		/// A wire dragged from `a`.`pa` to `b`.`pb`.
		bool TutWire(StringView a, StringView pa, StringView b, StringView pb)
		{
			let from = TutPin(TutNode(a), pa);
			let to = TutPin(TutNode(b), pb);
			String why = scope .();
			let ok = from != null && to != null && mGraphPanel.TryDropWire(CurrentMethod, from, to, why);
			TutCheck(ok, scope $"a wire from {a}.{pa} to {b}.{pb} {why}");
			return ok;
		}

		/// A value typed into an unwired input (on the node or in Properties).
		bool TutValue(StringView node, StringView pinName, StringView typed)
		{
			let p = TutPin(TutNode(node), pinName);
			if (p == null)
			{
				TutCheck(false, scope $"no input {node}.{pinName} to type {typed} into");
				return false;
			}
			let kind = PinValue.KindOf(p.TypeName, p.Default, p.Name, Language.Types);
			String lit = scope .();
			String why = scope .();
			let ok = PinValue.Write(kind, p.TypeName, typed, p.Optional, lit, why);
			TutCheck(ok, scope $"{typed} typed into {node}.{pinName} ({p.TypeName}) {why}");
			if (!ok)
				return false;
			BeginEdit();
			p.Default.Set(lit);
			CommitCurrent();
			return true;
		}

		/// Type Settings > Base Type, as the row writes it.
		void TutBaseType(StringView baseType)
		{
			if (baseType.IsEmpty || !BeginTypeEdit())
				return;
			delete Doc.Header.Base;
			Doc.Header.Base = TypeRef.Parse(baseType);
			EndTypeEdit();
		}

		/// A function's page: Inheritance (0 None, 1 Virtual, 3 Override), Pure and Return Type as the rows write them.
		void TutFunctionPage(MemberDecl m, int inherit, bool pure, StringView returns = "")
		{
			if (m == null || !BeginTypeEdit())
				return;
			m.Virtual = inherit == 1;
			m.Override = inherit == 3;
			m.Pure = pure;
			if (!returns.IsEmpty)
			{
				delete m.Returns;
				m.Returns = TypeRef.Parse(returns);
				SyncSheets(m);
			}
			EndTypeEdit();
		}

		/// The toolbar's Arrange; nothing selected, so Properties shows `m`'s page; the Project Browser in front below.
		void TutTidy(MemberDecl m = null)
		{
			ArrangeCurrentGraph();
			CurrentTab?.ClearSelection();
			if (m != null)
				SelectOutline(.Member, m);
			Panels.Focus(Panels.ProjectBrowserId);
		}

		/// F with nothing selected: the whole Sheet in view.
		void TutFrame()
		{
			if (CurrentTab != null && CurrentMethod != null)
				mGraphPanel.FrameNodes(CurrentTab, CurrentMethod.Graph, false);
		}

		/// F with these nodes selected, then the selection is cleared (on the next step).
		void TutFrameOn(params StringView[] names)
		{
			let tab = CurrentTab;
			if (tab == null || CurrentMethod == null)
				return;
			tab.ClearSelection();
			for (let name in names)
			{
				let n = TutNode(name);
				if (n != null)
					tab.SelectedNodes.Add(n.Id);
			}
			mGraphPanel.FrameNodes(tab, CurrentMethod.Graph, true);
		}

		bool TutSheetInFront(StringView name)
		{
			let ok = CurrentMethod != null && CurrentMethod.Name == name;
			TutCheck(ok, scope $"the {name} Sheet is in front ({(CurrentMethod != null) ? CurrentMethod.Name : "none"})");
			return ok;
		}

		/// + Add > New Class (New Struct...) in the Source folder: the Create Type dialog proposes the
		/// project's namespace, Zoo; Create writes the type from its template.
		TypeDocument TutNewType(StringView name, TypeKind kind)
		{
			String folder = scope $"{mTutRoot}{Path.DirectorySeparatorChar}Source";
			StartNewType(kind, folder);
			TutCheck(mOpenNewType && mNtKind == kind, scope $"+ Add > New {KindTitle(kind)}... opens the Create Type dialog");
			mOpenNewType = false;
			let doc = CreateType(kind, folder, name);
			TutCheck(doc != null && Doc == doc, scope $"New {KindTitle(kind)} makes {name}");
			if (doc == null)
				return null;
			TutCheck(doc.Header.Namespace == "Zoo", scope $"New {KindTitle(kind)} in Source gives {name} the project's namespace ({doc.Header.Namespace})");
			if (kind == .Class)
			{
				let mg = CurrentMethod;
				TutCheck(mg != null && mg.Member != null && mg.Member.Kind == .Ctor && mg.Doc == doc, scope $"New Class opens {name}'s constructor Sheet");
			}
			return doc;
		}

		/// Right-click Animal's tile > Make Child Class...: the dialog proposes AnimalChild with Base Class
		/// Animal; named `name`, Create makes the class with its constructor running Animal's.
		TypeDocument TutMakeChild(StringView name)
		{
			String folder = scope $"{mTutRoot}{Path.DirectorySeparatorChar}Source";
			String animal = scope $"{folder}{Path.DirectorySeparatorChar}Animal{GraphExtension}";
			StartMakeChild(animal);
			TutCheck(mOpenNewType && mNtBase == "Zoo.Animal" && mNtName.View == "AnimalChild", scope $"Make Child Class on Animal proposes AnimalChild : Zoo.Animal ({mNtName.View} : {mNtBase})");
			String baseType = scope .(mNtBase);
			mOpenNewType = false;
			let doc = CreateType(.Class, folder, name, baseType);
			TutCheck(doc != null && Doc == doc && doc.Header.Base?.ToString(.. scope String()) == "Zoo.Animal", scope $"Make Child Class makes {name} : Animal");
			return doc;
		}

		/// FUNCTIONS > Override... > `name`: the base class's function, its Sheet opened, marked Override.
		bool TutOverride(StringView name)
		{
			List<InheritedFn> ov = scope .();
			defer { ClearAndDeleteItems!(ov); }
			InheritedFunctions(Doc.Header, Doc.Members, null, ov);
			for (let f in ov)
				if (f.Fn.Name == name)
				{
					let s = ImplementInherited(f);
					TutCheck(s != null && s.Member.Override && CurrentMethod == s, scope $"Override... > {name} makes the override's Sheet");
					return s != null;
				}
			TutCheck(false, scope $"Override... offers {name} ({ov.Count} functions)");
			return false;
		}

		/// The constructor's row in FUNCTIONS: its Sheet opened.
		void TutOpenCtor()
		{
			for (let s in Doc.Sheets)
				if (s.Member != null && s.Member.Kind == .Ctor)
				{
					OpenTab(s);
					SelectOutline(.Member, s.Member);
					return;
				}
		}

		/// FUNCTIONS + > Constructor has opened its Sheet: `ctor` is its member.
		MemberDecl TutCtorInFront()
		{
			let mg = CurrentMethod;
			let ok = mg != null && mg.Member != null && mg.Member.Kind == .Ctor;
			TutCheck(ok, "FUNCTIONS + > Constructor opens the constructor's Sheet");
			return ok ? mg.Member : null;
		}

		MemberDecl TutMember(StringView name) => Doc?.FindMember(name);

		/// FUNCTIONS + > Function, then an input `name` of `type` (Add Input, its name and type typed in).
		void TutInput(MemberDecl m, StringView name, StringView type)
		{
			AddParam(m, false);
			if (m == null || m.Params.IsEmpty)
				return;
			let p = m.Params.Back;
			RenameParam(m, p, name);
			if (BeginTypeEdit())
			{
				delete p.Type;
				p.Type = TypeRef.Parse(type);
				SyncSheets(m);
				EndTypeEdit();
			}
			TutCheck(p.Name == name && p.Type?.ToString(.. scope String()) == type, scope $"{m.Name} has the input {name} ({type})");
		}

		bool SelfTestTutorial()
		{
			switch (mSelfTestStep)
			{
			// ---------------------------------------------------------------- New Project, the window
			case 0:
				if (!mProjectRoot.IsEmpty)
				{
					// After other cases: their unsaved test edits are dropped and their project closed
					// (File > Close Project), so the tutorial starts from the start page.
					for (let d in mDocs)
						d.Modified = false;
					OpenProjectNow("", "", false);
					mSelfTestWait = 10;
					mSelfTestStep--;
					return false;
				}
				mTutFailed = false;
				for (let kv in mTutKeys)
				{
					delete kv.key;
					delete kv.value;
				}
				mTutKeys.Clear();
				mTutOwnDir = false;
				if (Environment.GetEnvironmentVariable("TREADLE_TUTORIAL_DIR", mTutLocation) case .Err || mTutLocation.IsEmpty)
				{
					String temp = scope .();
					SelfTestTemp.Get(temp);
					mTutOwnDir = true;
					mTutLocation.Set(scope $"{temp}{Path.DirectorySeparatorChar}treadle-tutorial-{(int)Platform.BfpSystem_GetTimeStamp() & 0xFFFFFF}");
				}
				Directory.CreateDirectory(mTutLocation).IgnoreError();
				mTutRoot.Set(scope $"{mTutLocation}{Path.DirectorySeparatorChar}Zoo");
				if (Directory.Exists(mTutRoot))
				{
					TutCheck(false, scope $"{mTutRoot} exists already");
					return true;
				}
				// File > New Project, the name typed.
				StartNewProject(mTutLocation);
				mNPName.Set("Zoo");
				mSelfTestWait = 10;
				return false;
			case 1:
				if (!TutHold("01-new-project"))
					return false;
				// Create: what the dialog's button does.
				igClosePopupToLevel(0, true);
				String typePath = scope .();
				String why = scope .();
				Directory.CreateDirectory(mTutRoot).IgnoreError();
				let made = CreateProjectFiles(mTutRoot, "Zoo", typePath, why);
				TutCheck(made, scope $"New Project writes Zoo.tproj and Source\\Program.treadle {why}");
				if (!made)
					return TutAbort();
				FileSafety.ReadOnlyProject = false;
				RequestOpenProject(mTutRoot, typePath);
				mSelfTestWait = 20;
				return false;
			case 2:
				TutCheck(mProjectRoot == mTutRoot, scope $"the new project is open ({mProjectRoot})");
				if (!TutSheetInFront("Main"))
					return TutAbort();
				CurrentTab?.ClearSelection();
				Panels.Focus(Panels.ProjectBrowserId);
				mStatus.Clear(); // the picture shows no folder of the machine it was made on
				mSelfTestWait = 10;
				return false;

			// ---------------------------------------------------------------- the C import
			case 3:
				if (!TutHold("02-window"))
					return false;
				{
					// File > Import C Headers: the project has no set, so the file dialog asks for a
					// header; the page says to pick stdio.h in the toolchain's include folder.
					String root = scope .();
					Treadle.Language.LlvmRoot.Get(root);
					String header = scope $"{root}{Path.DirectorySeparatorChar}include{Path.DirectorySeparatorChar}stdio.h";
					TutCheck(File.Exists(header), scope $"the toolchain has {header}");
					ImportCHeaders(header);
					String projText = scope .();
					File.ReadAllText(scope $"{mTutRoot}{Path.DirectorySeparatorChar}Zoo.tproj", projText, true).IgnoreError();
					TutCheck(File.Exists(scope $"{mTutRoot}{Path.DirectorySeparatorChar}stdio.cimport") && projText.Contains("cimport stdio.cimport"),
						"File > Import C Headers makes stdio.cimport for the picked header and names it in the project file");
				}
				TutCheck(File.Exists(scope $"{mTutRoot}/build/cimport/stdio.cdecl"), "File > Import C Headers writes build/cimport/stdio.cdecl");
				mLogCategory.Set("C import");
				ShowOutputLog = true;
				mFocusOutputLog = true;
				mSelfTestWait = 10;
				return false;
			case 4:
				{
					List<NodeItem> rows = scope .();
					defer { ClearAndDeleteItems!(rows); }
					mNodeMenu.ListFor(CurrentMethod, 0, "puts", rows);
					bool found = false;
					for (let r in rows)
						if (r.Label.StartsWith("puts"))
							found = true;
					TutCheck(found, "the Node menu offers puts after the import");
				}
				// Right-click on the canvas: the Node menu.
				mNodeMenu.SelfTestPos = .(420 * Look.Scale, 150 * Look.Scale);
				OpenNodeMenu(CurrentTab, .(0, 0), 0);
				mSelfTestWait = 5;
				return false;
			case 5:
				mNodeMenu.SelfTestSetSearch("puts");
				mSelfTestWait = 10;
				return false;
			case 6:
				if (!TutHold("03-c-import"))
					return false;
				mNodeMenu.CloseRequested = true;
				mLogCategory.Clear();
				Panels.Focus(Panels.ProjectBrowserId);
				mSelfTestWait = 5;
				return false;

			// ---------------------------------------------------------------- Animal
			case 7:
				TutNewType("Animal", .Class);
				AddField("mLegs", "int");
				TutCheck(TutMember("mLegs") != null, "VARIABLES + adds mLegs (int)");
				AddFunctionMember("Speak");
				mSelfTestWait = 5;
				return false;
			case 8:
				if (!TutSheetInFront("Speak"))
					return TutAbort();
				TutFunctionPage(TutMember("Speak"), 1, false);
				TutCheck(TutMember("Speak").Virtual, "Speak's Inheritance is Virtual");
				if (TutPlace("puts", "puts", "puts", CurrentMethod.Graph.Entry, "then") != null)
					TutValue("puts", TutFirstValueIn(TutNode("puts")), "...");
				mSelfTestWait = 3;
				return false;
			case 9:
				TutTidy(TutMember("Speak"));
				mSelfTestWait = 5;
				return false;
			case 10:
				TutFrame();
				mSelfTestWait = 5;
				return false;
			case 11:
				if (!TutHold("04-animal-speak"))
					return false;
				AddCtorOrDtor(true);
				mSelfTestWait = 5;
				return false;
			case 12:
				{
					let mg = CurrentMethod;
					TutCheck(mg != null && mg.Member != null && mg.Member.Kind == .Dtor, "FUNCTIONS + > Destructor opens the destructor's Sheet");
					if (mg == null)
						return TutAbort();
					if (TutPlace("puts", "puts", "puts", mg.Graph.Entry, "then") != null)
						TutValue("puts", TutFirstValueIn(TutNode("puts")), "an animal is freed");
					TutTidy();
				}
				mSelfTestWait = 3;
				return false;
			case 13:
				AddFunctionMember("Legs");
				mSelfTestWait = 5;
				return false;
			case 14:
				if (!TutSheetInFront("Legs"))
					return TutAbort();
				TutFunctionPage(TutMember("Legs"), 0, true, "int");
				if (TutPlace("ret", "return", "Return", CurrentMethod.Graph.Entry, "then") != null)
					TutPlace("getlegs", "get mlegs", "Get mLegs", TutNode("ret"), "value");
				mSelfTestWait = 3;
				return false;
			case 15:
				TutTidy(TutMember("Legs"));
				mSelfTestWait = 5;
				return false;
			case 16:
				TutFrame();
				mSelfTestWait = 5;
				return false;
			case 17:
				if (!TutHold("05-animal-legs"))
					return false;
				SaveAll();
				// The constructor New Class made: its row in FUNCTIONS opens it; it gets the input legs.
				TutOpenCtor();
				mSelfTestWait = 5;
				return false;
			case 18:
				{
					let ctor = TutCtorInFront();
					if (ctor == null)
						return TutAbort();
					TutInput(ctor, "legs", "int");
					let mg = CurrentMethod;
					TutRemember("entry", mg.Graph.Entry.Key);
					if (TutPlace("setlegs", "set mlegs", "Set mLegs", mg.Graph.Entry, "then") != null)
						TutWire("entry", "legs", "setlegs", "value");
					TutTidy();
					SaveAll();
				}
				return false;

			// ---------------------------------------------------------------- Dog and Bird
			case 19, 27:
				let dog = mSelfTestStep == 19;
				SaveAll();
				ScanProject();
				TutMakeChild(dog ? "Dog" : "Bird");
				SaveAll();
				mSelfTestWait = 5;
				return false;
			case 20, 28:
				let dog = mSelfTestStep == 20;
				{
					let ctor = TutCtorInFront();
					if (ctor == null)
						return TutAbort();
					let mg = CurrentMethod;
					if (dog)
					{
						// Another type's field from the Node menu: the verb and the member's name find it.
						let set = mNodeMenu.DefaultRowFor(mg, .(400, 200), mg.Graph.Entry.Then.Id, "set mlegs");
						TutCheck(set != null && set.Label == "Set mLegs", scope $"'set mlegs' + Enter from a flow output takes Set mLegs ({(set != null) ? set.Label : "nothing"})");
						delete set;
						let enter = mNodeMenu.DefaultRowFor(mg, .(400, 200), mg.Graph.Entry.Then.Id, "mlegs");
						TutCheck(enter != null && enter.Label == "Set mLegs", scope $"'mlegs' + Enter from a flow output takes Set mLegs ({(enter != null) ? enter.Label : "nothing"})");
						delete enter;
						let get = mNodeMenu.DefaultRowFor(mg, .(400, 200), 0, "get mlegs");
						TutCheck(get != null && get.A == "get" && get.Label == "mLegs", scope $"'get mlegs' + Enter takes the Get of mLegs ({(get != null) ? get.Label : "nothing"})");
						delete get;
					}
					// Make Child Class put Base Constructor (int), Animal's constructor, on the constructor's Sheet.
					Node chainNode = null;
					for (let n in mg.Graph.Nodes)
						if (n.Kind == .ChainCtor)
							chainNode = n;
					TutCheck(chainNode != null, "Make Child Class puts a Base Constructor node on the constructor's Sheet");
					if (chainNode != null)
						TutRemember("base", chainNode.Key);
					if (chainNode != null)
					{
						let chain = TutNode("base");
						TutCheck(chain.Kind == .ChainCtor && chain.Text == "base" && chain.FindInput("legs")?.TypeName == "int" && ctor.Chain == .Base,
							scope $"the Base Constructor node has Animal's input legs (int) and the constructor runs it first ({ctor.Chain})");
						List<NodeMenu.OverloadChoice> choices = scope .();
						defer { ClearAndDeleteItems!(choices); }
						let cur = mNodeMenu.OverloadsOf(mg, chain, choices);
						TutCheck(choices.Count == 1 && cur == 0 && choices[0].Label == "Base Constructor (int legs)", scope $"Properties > Constructor names Animal's constructor ({choices.Count}, {cur})");
						TutValue("base", "legs", dog ? "4" : "2");
					}
					TutTidy();
					if (dog)
						CurrentTab?.SelectOnly(TutNode("base")?.Id ?? 0);
					else
						TutOverride("Speak");
				}
				mSelfTestWait = 5;
				return false;
			case 21:
				// F with the Base Constructor selected: Properties shows it. Validate again: the value typed
				// after Make Child Class saved the type is checked (the Base Constructor had no legs then).
				Validate(true);
				TutFrame();
				mSelfTestWait = 5;
				return false;
			case 22:
				if (!TutHold("06-dog-constructor"))
					return false;
				CurrentTab?.ClearSelection();
				// FUNCTIONS > Override... > Speak (Animal's Speak is virtual).
				TutOverride("Speak");
				mSelfTestWait = 5;
				return false;
			case 23, 29:
				let dog = mSelfTestStep == 23;
				if (!TutSheetInFront("Speak"))
					return TutAbort();
				TutFunctionPage(TutMember("Speak"), 3, false);
				if (TutPlace("puts", "puts", "puts", CurrentMethod.Graph.Entry, "then") != null)
					TutValue("puts", TutFirstValueIn(TutNode("puts")), dog ? "Woof" : "Tweet");
				mSelfTestWait = 3;
				return false;
			case 24, 30:
				TutTidy(TutMember("Speak"));
				mSelfTestWait = 5;
				return false;
			case 25:
				TutFrame();
				mSelfTestWait = 5;
				return false;
			case 26:
				if (!TutHold("06-dog-speak"))
					return false;
				SaveAll();
				return false;

			// ---------------------------------------------------------------- Point
			case 31:
				SaveAll();
				TutNewType("Point", .Struct);
				AddField("X", "int");
				AddField("Y", "int");
				AddFunctionMember("Sum");
				mSelfTestWait = 5;
				return false;
			case 32:
				if (!TutSheetInFront("Sum"))
					return TutAbort();
				TutFunctionPage(TutMember("Sum"), 0, true, "int");
				if (TutPlace("ret", "return", "Return", CurrentMethod.Graph.Entry, "then") != null &&
					TutPlace("add", "+", "+", TutNode("ret"), "value") != null)
				{
					TutPlace("getx", "get x", "Get X", TutNode("add"), "a");
					TutPlace("gety", "get y", "Get Y", TutNode("add"), "b");
				}
				mSelfTestWait = 3;
				return false;
			case 33:
				TutTidy(TutMember("Sum"));
				mSelfTestWait = 5;
				return false;
			case 34:
				TutFrame();
				mSelfTestWait = 5;
				return false;
			case 35:
				if (!TutHold("07-point-sum"))
					return false;
				SaveAll();
				return false;

			// ---------------------------------------------------------------- Box<T>
			case 36:
				TutNewType("Box", .Class);
				// Type Settings > Generic Parameters > Add Generic Parameter.
				if (BeginTypeEdit())
				{
					GenericParam gp = new .();
					gp.Name.Set("T");
					Doc.Header.Generics.Add(gp);
					EndTypeEdit();
				}
				AddField("mValue", "T");
				// The constructor New Class made, with the input value of type T.
				TutOpenCtor();
				mSelfTestWait = 5;
				return false;
			case 37:
				{
					let ctor = TutCtorInFront();
					if (ctor == null)
						return TutAbort();
					TutInput(ctor, "value", "T");
					let mg = CurrentMethod;
					TutRemember("entry", mg.Graph.Entry.Key);
					if (TutPlace("setvalue", "set mvalue", "Set mValue", mg.Graph.Entry, "then") != null)
						TutWire("entry", "value", "setvalue", "value");
					TutTidy();
				}
				AddFunctionMember("Get");
				mSelfTestWait = 5;
				return false;
			case 38:
				if (!TutSheetInFront("Get"))
					return TutAbort();
				TutFunctionPage(TutMember("Get"), 0, true, "T");
				if (TutPlace("ret", "return", "Return", CurrentMethod.Graph.Entry, "then") != null)
					TutPlace("getvalue", "get mvalue", "Get mValue", TutNode("ret"), "value");
				mSelfTestWait = 3;
				return false;
			case 39:
				TutTidy();
				SelectOutline(.TypeSettings);
				mSelfTestWait = 5;
				return false;
			case 40:
				TutFrame();
				mSelfTestWait = 5;
				return false;
			case 41:
				if (!TutHold("08-box-generic"))
					return false;
				SaveAll();
				return false;

			// ---------------------------------------------------------------- Program.Main
			case 42:
				{
					// Double-click Program in the Project Browser, then Main in the Outline.
					let doc = OpenFile(scope $"{mTutRoot}{Path.DirectorySeparatorChar}Source{Path.DirectorySeparatorChar}Program.treadle");
					let main = doc?.FindSheetByName("Main");
					if (main != null)
						OpenTab(main);
				}
				mSelfTestWait = 5;
				return false;
			case 43:
				{
					if (!TutSheetInFront("Main"))
						return TutAbort();
					// The tab's context menu > Close Others.
					TabSlot anchor = default;
					anchor.Graph = CurrentTab;
					RequestCloseTabs(anchor, .Others);
				}
				mSelfTestWait = 5;
				return false;
			case 44:
				{
					if (!TutSheetInFront("Main"))
						return TutAbort();
					let mg = CurrentMethod;
					// LOCAL VARIABLES +, then Name pet and Type Animal in its page.
					AddLocalVariable(mg);
					let local = mg.Graph.Locals.IsEmpty ? null : mg.Graph.Locals.Back;
					if (local != null && BeginTypeEdit())
					{
						local.Name.Set("pet");
						delete local.Type;
						local.Type = TypeRef.Parse("Zoo.Animal");
						mg.Graph.Version++;
						EndTypeEdit();
					}
					TutCheck(mg.Graph.FindLocal("pet") != null, "LOCAL VARIABLES + adds pet (Zoo.Animal)");
					TutPlace("dog", "construct dog", "Construct Dog", mg.Graph.Entry, "then");
					TutPlace("deferdelete", "defer delete", "Defer Delete", TutNode("dog"), "then");
					TutWire("dog", "object", "deferdelete", "object");
					TutPlace("bird", "local bird", "Local Bird", TutNode("deferdelete"), "then");
					TutPlace("defer", "defer", "Defer", TutNode("bird"), "then");
					if (TutPlace("bye", "puts", "puts", TutNode("defer"), "deferred") != null)
						TutValue("bye", TutFirstValueIn(TutNode("bye")), "goodbye from Defer");
				}
				mSelfTestWait = 3;
				return false;
			case 45:
				TutTidy();
				mSelfTestWait = 5;
				return false;
			case 46:
				TutFrame();
				mSelfTestWait = 5;
				return false;
			case 47:
				if (!TutHold("09-main-lifetime"))
					return false;
				// Then 0: the loop.
				TutPlace("seq", "sequence", "Sequence", TutNode("defer"), "done");
				if (TutPlace("for", "for loop", "For Loop", TutNode("seq"), "then0") != null)
				{
					TutValue("for", "start", "0");
					TutValue("for", "count", "2");
				}
				if (TutPlace("eq", "==", "==", TutNode("for"), "index") != null)
					TutValue("eq", "b", "0");
				TutPlace("branch", "branch", "Branch", TutNode("for"), "body");
				TutWire("eq", "result", "branch", "condition");
				TutPlace("setdog", "set pet", "Set pet", TutNode("branch"), "true");
				TutWire("dog", "object", "setdog", "value");
				TutPlace("setbird", "set pet", "Set pet", TutNode("branch"), "false");
				TutWire("bird", "object", "setbird", "value");
				// The Receiver's type name with the function's: Animal's Speak, not Dog's or Bird's.
				if (TutPlace("speak", "animal speak", "Speak", TutNode("setdog"), "then") != null)
					TutCheck(TutNode("speak").Text.Contains("Animal"), scope $"'animal speak' places a Call of Animal's Speak ({TutNode("speak").Text})");
				TutWire("setbird", "then", "speak", "in");
				TutPlace("getpet", "get pet", "Get pet", TutNode("speak"), "receiver");
				// A parameter's type after the name: the WriteLine that takes an int.
				TutPlace("writeline", "writeline int", "WriteLine (int value)", TutNode("speak"), "then");
				TutPlace("legs", "legs", "Legs", TutNode("writeline"), TutFirstValueIn(TutNode("writeline")));
				TutWire("getpet", TutFirstValueOut(TutNode("getpet")), "legs", "receiver");
				mSelfTestWait = 3;
				return false;
			case 48:
				// Then 1: a Box of a Point, made with its constructor, read back, summed; then puts "done".
				if (TutPlace("box", "local box", "Local Box (T)", TutNode("seq"), "then1") != null)
				{
					// Properties > Type: Box<Point>; the constructor follows the type's argument.
					BeginEdit();
					mNodeMenu.RetypeAllocation(CurrentMethod, TutNode("box"), "Box<Point>");
					CommitCurrent();
					let boxNode = TutNode("box");
					TutCheck(boxNode.Text == "Box<Point>" && boxNode.GetSetting("ctor") == "(Point)" && boxNode.FindInput("value")?.TypeName == "Point",
						scope $"the Local's Type is {boxNode.Text}, its constructor {boxNode.GetSetting("ctor")} with the input value ({boxNode.FindInput("value")?.TypeName})");
					List<NodeMenu.OverloadChoice> choices = scope .();
					defer { ClearAndDeleteItems!(choices); }
					let cur = mNodeMenu.OverloadsOf(CurrentMethod, boxNode, choices);
					TutCheck(cur == 0 && choices.Count == 1 && choices[0].Label.EndsWith("(Point value)"), scope $"Properties > Constructor lists Box<Point>'s constructor ({(choices.IsEmpty ? "none" : (StringView)choices[0].Label)})");
					if (TutPlace("make", "make point", "Make Point", boxNode, "value") != null)
					{
						TutValue("make", "X", "3");
						TutValue("make", "Y", "4");
					}
					// Settings > set ctor typed again (as Properties writes it): the pins and the wire stay.
					BeginEdit();
					let switched = SwitchCtorBySignature(CurrentMethod, boxNode, "( Point )");
					NodeFactory.Reshape(CurrentMethod.Graph, boxNode);
					CommitCurrent();
					TutCheck(switched && CurrentMethod.Graph.IsLinked(boxNode.FindInput("value")), "typing set ctor (Point) in Settings keeps the value input and its wire");
				}
				TutPlace("writeline2", "writeline int", "WriteLine (int value)", TutNode("box"), "then");
				TutPlace("sum", "sum", "Sum", TutNode("writeline2"), TutFirstValueIn(TutNode("writeline2")));
				TutPlace("boxget", "box get", "Get", TutNode("sum"), "receiver");
				TutWire("box", "object", "boxget", "receiver");
				if (TutPlace("done", "puts", "puts", TutNode("writeline2"), "then") != null)
					TutValue("done", TutFirstValueIn(TutNode("done")), "done");
				mSelfTestWait = 3;
				return false;
			case 49:
				TutTidy();
				Validate(true);
				mSelfTestWait = 5;
				return false;
			case 50:
				{
					// The evaluated-2x badge: Get pet feeds Speak and, through Legs, WriteLine.
					Dictionary<int32, int32> counts = scope .();
					PinMatch.FanOut(CurrentMethod.Graph, counts);
					int32 fan = 0;
					let getPet = TutNode("getpet");
					if (getPet != null)
						counts.TryGetValue(getPet.Id, out fan);
					TutCheck(fan == 2, scope $"Get pet is evaluated for 2 flow nodes ({fan})");
					int errors = 0;
					if (mValidate != null)
						for (let d in mValidate.Messages)
						{
							if (d.IsError)
								errors++;
							Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] tutorial validate: {d.IsError ? "error" : "warning"} {d.Text} node {d.NodeKey} pin {d.PinName}");
						}
					TutCheck(errors == 0, scope $"Validate finds no error in Main ({errors})");
				}
				TutFrameOn("setdog", "setbird", "speak", "getpet", "legs", "writeline");
				mSelfTestWait = 3;
				return false;
			case 51:
				CurrentTab?.ClearSelection();
				mSelfTestWait = 5;
				return false;
			case 52:
				if (!TutHold("10-main-loop"))
					return false;
				TutFrameOn("box", "make", "boxget", "sum", "writeline2", "done");
				mSelfTestWait = 3;
				return false;
			case 53:
				CurrentTab?.ClearSelection();
				mSelfTestWait = 5;
				return false;
			case 54:
				if (!TutHold("11-main-box"))
					return false;
				// For the pixel pass (no picture on the page): Local Box<Point> selected, its Properties.
				CurrentTab?.SelectOnly(TutNode("box")?.Id ?? 0);
				mSelfTestWait = 5;
				return false;
			case 55:
				if (!TutHold("px-local-box"))
					return false;
				// The Node menu dragged from Local Box's flow output, `writeline int` typed.
				CurrentTab?.ClearSelection();
				mNodeMenu.SelfTestPos = .(700 * Look.Scale, 300 * Look.Scale);
				OpenNodeMenu(CurrentTab, .(0, 0), TutNode("box")?.FindOutput("then")?.Id ?? 0);
				mSelfTestWait = 5;
				return false;
			case 56:
				mNodeMenu.SelfTestSetSearch("writeline int");
				mSelfTestWait = 10;
				return false;
			case 57:
				if (!TutHold("px-menu-writeline-int"))
					return false;
				mNodeMenu.CloseRequested = true;
				// F7: Build.
				Build();
				TutCheck(mBuild != null && mBuild.Running, "F7 starts the build");
				mTutWatch.Restart();
				return false;
			case 58:
				if (!TutWait(mBuild == null || !mBuild.Running, "the build"))
					return false;
				TutCheck(mBuild != null && mBuild.Succeeded, scope $"the build succeeds ({(mBuild != null) ? mBuild.Messages.Count : -1} messages)");
				if (mBuild != null)
					for (let d in mBuild.Messages)
						Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] tutorial build: {d.IsError ? "error" : "warning"} {d.Text} node {d.NodeKey} pin {d.PinName} [{d.Where}]");
				if (mBuild == null || !mBuild.Succeeded)
					return TutAbort();
				// Ctrl+F5: Run Without Debugging; the output goes to the Output Log.
				if (mBuildRunOutput != null)
					DeleteContainerAndItems!(mBuildRunOutput);
				mBuildRunOutput = new .();
				RunProgram();
				mTutWatch.Restart();
				return false;
			case 59:
				if (!TutWait(mProgramRun != null && mProgramRun.Finished, "the program to end"))
					return false;
				{
					String all = scope .();
					for (let l in mBuildRunOutput)
						all.AppendF("{}|", l);
					TutCheck(mProgramRun.ExitCode == 0 && all == "Woof|4|Tweet|2|7|done|goodbye from Defer|an animal is freed|an animal is freed|",
						scope $"Ctrl+F5 runs it: exit code {mProgramRun.ExitCode}, output {all}");
				}
				DeleteContainerAndItems!(mBuildRunOutput); // the lines are owned
				mBuildRunOutput = null;
				mLogCategory.Set("Run");
				ShowOutputLog = true;
				mFocusOutputLog = true;
				mSelfTestWait = 10;
				return false;
			case 60:
				if (!TutHold("12-run"))
					return false;
				mLogCategory.Clear();
				// F9 on the Speak call, then F5.
				{
					let mg = CurrentMethod;
					let speak = TutNode("speak");
					if (speak == null || !Debug.Adapter.Available)
					{
						TutCheck(false, scope $"the debugger is available ({Debug.Adapter.Unavailable})");
						return TutAbort();
					}
					CurrentTab.SelectOnly(speak.Id);
					ToggleBreakpointOnSelection();
					TutCheck(Debug.HasBreakpoint(mg.Doc.FilePath, mg.Key, speak.Key), "F9 sets a breakpoint on the Speak call");
					mTutLaunchBase = DebugLaunches;
					StartDebugging();
					mTutWatch.Restart();
				}
				return false;
			case 61:
				if (!TutWait(DebugLaunches > mTutLaunchBase && (Debug.IsStopped || Debug.State == .Exited), "the stop on Speak"))
					return false;
				{
					let f = Debug.CurrentFrame;
					TutCheck(Debug.IsStopped && f != null && f.NodeKey == TutNode("speak")?.Key, scope $"F5 stops on the Speak call ({(f != null) ? f.NodeKey : "none"})");
					DebugVariable pet = null;
					for (let v in Debug.Locals)
						if (v.Label == "pet")
							pet = v;
					TutCheck(pet != null && pet.Value.StartsWith("Zoo.Dog"), scope $"Locals shows pet = {(pet != null) ? pet.Value : "(missing)"}");
				}
				mSelfTestWait = 30;
				return false;
			case 62:
				if (mTutHoldUntil == 0)
				{
					// Zoomed in on the stop (F with these nodes selected), the stopped node selected again.
					TutFrameOn("setdog", "speak", "getpet", "legs", "writeline");
					let speak = TutNode("speak");
					if (speak != null)
						CurrentTab?.SelectOnly(speak.Id);
				}
				if (!TutHold("13-debug-stop"))
					return false;
				// F11: Step Into, which goes into Dog's Speak.
				Debug.StepInto();
				mTutWatch.Restart();
				return false;
			case 63:
				if (!TutWait(Debug.IsStopped || Debug.State == .Exited, "the step"))
					return false;
				TutCheck(Debug.IsStopped && Debug.CurrentFrame != null && Debug.CurrentFrame.SheetName.Contains("Dog"), scope $"F11 goes into Dog's Speak ({Debug.CurrentFrame?.SheetName})");
				mSelfTestWait = 30;
				return false;
			case 64:
				if (!TutHold("14-step-into"))
					return false;
				mSelfTestStep = cTutEnd - 1;
				return false;
			case cTutEnd:
				// Shift+F5, and the breakpoint goes; the project stays only in a folder the caller chose
				// (TREADLE_TUTORIAL_DIR), and the temp project leaves no settings behind.
				if (Debug.IsActive)
					Debug.Stop();
				Debug.ClearBreakpoints();
				SaveBreakpoints();
				if (mTutOwnDir)
				{
					ForgetRecentProject(mTutRoot);
					String key = scope .(mTutRoot);
					key.ToLower();
					Settings.Root?.Get("projects")?.Remove(key);
					Settings.Save();
				}
				mSelfTestWait = 30; // lldb-dap and the program end
				return false;
			case cTutEnd + 1:
				if (mTutOwnDir)
				{
					for (let d in mDocs)
						d.Modified = false;
					OpenProjectNow("", "", false); // File > Close Project before the folder goes
					Directory.DelTree(mTutLocation).IgnoreError();
				}
				Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] tutorial: {(mTutFailed ? "stopped early or with failures" : "every step done")}; the project {(mTutOwnDir ? "was" : "is")} {mTutRoot}");
				return true;
			default:
				mSelfTestStep = cTutEnd - 1;
				return false;
			}
		}
	}
}
#endif
