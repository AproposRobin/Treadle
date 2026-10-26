// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Model;

namespace Treadle.Editor
{
	/// The `entry` case (run after `editor`): a new user's first program. New Project opens Program.Main with
	/// the start comment and the status bar's entry; a class Engine (base BaseEngine) with a function Run that
	/// writes a line and a static Helper; in Program.Main (unsaved) the Node menu finds Engine's Run on the
	/// canvas and from an Engine pin (its functions first, the base class's too), a Run placed alone asks for
	/// its Receiver, "Construct Engine + Run" places the three nodes wired in one undo step, the static Helper
	/// places with no Receiver; Run builds the modified project first and shows the output, a second Run is up to
	/// date; a project without an entry fails the build with Create Main offered, Create Main mends it; Set as
	/// entry point moves the entry and Ctrl+Z / Ctrl+Y undo and redo it.
	extension EditorApp
	{
		String mEntryRoot = new .() ~ delete _;
		String mEntryLocation = new .() ~ delete _;
		String mEntryCallKey = new .() ~ delete _;
		String mEntryHelperKey = new .() ~ delete _;
		Stopwatch mEntryWatch = new .() ~ delete _;

		static void EntryRowList(List<NodeItem> rows, String outList)
		{
			for (let r in rows)
				if (@r.Index < 10)
					outList.AppendF("[{}] {}, ", r.Category, r.Label);
		}

		/// The rows the Node menu lists for `search` from pin `pinId` (0: on the canvas), in order.
		void EntryRows(StringView search, int32 pinId, List<NodeItem> outRows)
		{
			mNodeMenu.ListFor(CurrentMethod, pinId, search, outRows);
		}

		/// The index of the first row whose label is `label` and whose category ends with `type`, or -1.
		static int EntryRowIndex(List<NodeItem> rows, StringView label, StringView type)
		{
			for (let r in rows)
				if (r.Label == label && r.Category.EndsWith(type))
					return @r.Index;
			return -1;
		}

		/// Places the row Enter takes for `search` from `pin` (null: the canvas at x, y); checks its label.
		Node EntryPlace(StringView search, StringView expect, Pin pin, float x = 400, float y = 200)
		{
			mActionTab = CurrentTab;
			let item = mNodeMenu.DefaultRowFor(CurrentMethod, .(x, y), (pin != null) ? pin.Id : 0, search);
			if (item == null || item.Label != expect)
			{
				List<NodeItem> rows = scope .();
				defer { ClearAndDeleteItems!(rows); }
				EntryRows(search, (pin != null) ? pin.Id : 0, rows);
				SelfTestCheck(false, scope $"entry: '{search}' + Enter places {expect} (the row is {(item != null) ? item.Label : "none"}; rows {EntryRowList(rows, .. scope String())})");
				delete item;
				return null;
			}
			let n = ExecuteAction(item);
			delete item;
			SelfTestCheck(n != null, scope $"entry: '{search}' + Enter places {expect}");
			CurrentTab?.ClearSelection();
			return n;
		}

		/// A WriteLine (String) after `from`'s `then`, with `text` typed into it.
		void EntryWriteLine(Node from, StringView text)
		{
			let n = EntryPlace("writeline string", "WriteLine (String value)", from?.FindOutput("then"), (from != null) ? from.X + 320 : 400, (from != null) ? from.Y : 200);
			if (n == null)
				return;
			for (let p in n.Inputs)
				if (p.Kind == .Value && p.Role != .Receiver)
				{
					BeginEdit();
					p.Default.Set(scope $"\"{text}\"");
					CommitCurrent();
					break;
				}
		}

		TypeDocument EntryDoc(StringView name)
		{
			for (let d in mDocs)
				if (d.Header.Name == name)
					return d;
			return null;
		}

		Pin EntryReceiver(Node n)
		{
			if (n != null)
				for (let p in n.Inputs)
					if (p.Role == .Receiver)
						return p;
			return null;
		}

		bool EntryWaitBuild()
		{
			if (mBuild != null && mBuild.Running && mEntryWatch.Elapsed.TotalSeconds < 120)
			{
				mSelfTestStep--;
				return false;
			}
			return true;
		}

		bool EntryWaitRun()
		{
			if (((mBuild != null && mBuild.Running) || mProgramRun == null || !mProgramRun.Finished) && mEntryWatch.Elapsed.TotalSeconds < 120)
			{
				// A Run whose build failed starts nothing: stop waiting then.
				if (mBuild != null && !mBuild.Running && !mBuild.Succeeded)
					return true;
				mSelfTestStep--;
				return false;
			}
			return true;
		}

		void EntryStartRun()
		{
			if (mBuildRunOutput != null)
				DeleteContainerAndItems!(mBuildRunOutput);
			mBuildRunOutput = new .();
			DeleteAndNullify!(mProgramRun);
			mEntryWatch.Restart();
			RunProgram();
		}

		bool SelfTestEntry()
		{
			switch (mSelfTestStep)
			{
			case 0:
				if (!mProjectRoot.IsEmpty)
				{
					for (let d in mDocs)
						d.Modified = false;
					OpenProjectNow("", "", false);
					mSelfTestWait = 10;
					mSelfTestStep--;
					return false;
				}
				String temp = scope .();
				SelfTestTemp.Get(temp);
				mEntryLocation.Set(scope $"{temp}{Path.DirectorySeparatorChar}treadle-entry-{(int)Platform.BfpSystem_GetTimeStamp() & 0xFFFFFF}");
				mEntryRoot.Set(scope $"{mEntryLocation}{Path.DirectorySeparatorChar}Test");
				Directory.CreateDirectory(mEntryRoot).IgnoreError();
				String typePath = scope .();
				String why = scope .();
				let made = CreateProjectFiles(mEntryRoot, "Test", typePath, why);
				SelfTestCheck(made, scope $"entry: New Project writes Test {why}");
				if (!made)
					return true;
				FileSafety.ReadOnlyProject = false;
				RequestOpenProject(mEntryRoot, typePath);
				mSelfTestWait = 20;
				return false;
			case 1:
			{
				// New Project: Main in front, the start comment over its Entry, the status bar's entry.
				let mg = CurrentMethod;
				SelfTestCheck(mg != null && mg.Name == "Main", "entry: New Project opens Program.Main");
				if (mg == null)
					return true;
				GraphComment hint = null;
				for (let c in mg.Doc.Comments)
					if (c.MethodKey == mg.Key)
						hint = c;
				SelfTestCheck(hint != null && hint.Text == StartHint && hint.Y + hint.H <= mg.Graph.Entry.Y, scope $"entry: Main has the comment '{StartHint}' above its Entry node");
				String label = scope .();
				EntryLabel(label);
				SelfTestCheck(label == "Program.Main", scope $"entry: the status bar says Entry: {label}");
				SelfTestCheck(IsEntryFunction(mg.Doc, mg.Member) && HasEntryMain(), "entry: the Outline marks Main as the entry point");
				// BaseEngine with Init, then Engine (base BaseEngine) with Run and a static Helper.
				let b = NewDocument(scope $"{mEntryRoot}{Path.DirectorySeparatorChar}Source{Path.DirectorySeparatorChar}BaseEngine.treadle");
				SelfTestCheck(b != null, "entry: New Type makes BaseEngine");
				AddFunctionMember("Init");
				mSelfTestWait = 5;
				return false;
			}
			case 2:
				EntryWriteLine(CurrentMethod?.Graph.Entry, "init from the base");
				let e = NewDocument(scope $"{mEntryRoot}{Path.DirectorySeparatorChar}Source{Path.DirectorySeparatorChar}Engine.treadle");
				SelfTestCheck(e != null, "entry: New Type makes Engine");
				if (e == null)
					return true;
				if (BeginTypeEdit())
				{
					delete Doc.Header.Base;
					Doc.Header.Base = TypeRef.Parse("Test.BaseEngine");
					EndTypeEdit();
				}
				AddFunctionMember("Run");
				mSelfTestWait = 5;
				return false;
			case 3:
				SelfTestCheck(CurrentMethod != null && CurrentMethod.Name == "Run", "entry: the Run Sheet is in front");
				EntryWriteLine(CurrentMethod?.Graph.Entry, "hello from Engine");
				AddFunctionMember("Helper");
				mSelfTestWait = 5;
				return false;
			case 4:
			{
				let m = Doc.FindMember("Helper");
				if (m != null && BeginTypeEdit())
				{
					m.Static = true;
					EndTypeEdit();
				}
				EntryWriteLine(CurrentMethod?.Graph.Entry, "static helper");
				SaveAll();
				// Back to Program.Main, as a new user would (Program stays unsaved from here).
				let prog = EntryDoc("Program");
				if (prog != null)
					OpenTab(prog.FindSheetByName("Main"));
				mSelfTestWait = 5;
				return false;
			}
			case 5:
			{
				let mg = CurrentMethod;
				SelfTestCheck(mg != null && mg.Name == "Main", "entry: Main in front again");
				if (mg == null)
					return true;
				// The canvas: "run" and "engine run" find Engine's Run, near the top.
				List<NodeItem> rows = scope .();
				defer { ClearAndDeleteItems!(rows); }
				EntryRows("run", 0, rows);
				let at = EntryRowIndex(rows, "Run", "Engine");
				SelfTestCheck(at >= 0 && at < 3, scope $"entry: 'run' on the canvas lists Engine's Run near the top ({at}: {EntryRowList(rows, .. scope String())})");
				ClearAndDeleteItems!(rows);
				EntryRows("engine run", 0, rows);
				SelfTestCheck(!rows.IsEmpty && rows[0].Label == "Run" && rows[0].Category.EndsWith("Engine"), scope $"entry: 'engine run' lists Engine's Run first ({EntryRowList(rows, .. scope String())})");
				SelfTestCheck(EntryRowIndex(rows, "Construct Engine + Run", "Engine") >= 0, "entry: 'engine run' offers Construct Engine + Run");
				// From Entry's flow output Enter still takes the plain node: the Call, the Construct.
				for (let pair in StringView[?]("engine run|Run", "construct engine|Construct Engine", "local engine|Local Engine"))
				{
					let bar = pair.IndexOf('|');
					let row = mNodeMenu.DefaultRowFor(mg, .(0, 0), mg.Graph.Entry.FindOutput("then").Id, pair.Substring(0, bar));
					SelfTestCheck(row != null && row.Label == pair.Substring(bar + 1), scope $"entry: '{pair.Substring(0, bar)}' + Enter from Entry takes {pair.Substring(bar + 1)} ({(row != null) ? row.Label : "none"})");
					delete row;
				}
				// The call placed first: its Receiver asks for an Engine; dragging from it offers one.
				let call = EntryPlace("engine run", "Run", null, 400, 200);
				let recv = EntryReceiver(call);
				SelfTestCheck(recv != null && !mg.Graph.IsLinked(recv) && mGraphPanel.NeedsReceiver(mg.Graph, call, recv, call.OwnerType ?? recv.TypeName),
					"entry: a Run placed alone shows its Receiver with 'needs an Engine'");
				if (recv != null)
				{
					ClearAndDeleteItems!(rows);
					EntryRows("engine", recv.Id, rows);
					SelfTestCheck(EntryRowIndex(rows, "Construct Engine", "Engine") >= 0 && EntryRowIndex(rows, "Local Engine", "Engine") >= 0,
						scope $"entry: dragging from Run's Receiver offers Construct Engine and Local Engine ({EntryRowList(rows, .. scope String())})");
				}
				if (call != null)
				{
					BeginEdit();
					mg.Graph.RemoveNode(call);
					CommitCurrent();
				}
				mSelfTestWait = 3;
				return false;
			}
			case 6:
			{
				// The combined row: Construct Engine, Defer Delete and Run, wired, one undo step.
				let mg = CurrentMethod;
				let then = mg.Graph.Entry.FindOutput("then");
				int before = mg.Graph.Nodes.Count;
				let make = EntryPlace("construct engine run", "Construct Engine + Run", then, 320, 0);
				if (make == null)
					return true;
				Node dd = null;
				Node call = null;
				let obj = make.Result ?? make.FindOutput("object");
				for (let l in mg.Graph.Links)
				{
					if (l.From == make.FindOutput("then") && l.To.Owner.Kind == .DeferDelete)
						dd = l.To.Owner;
					if (l.From == obj && l.To.Role == .Receiver)
						call = l.To.Owner;
				}
				SelfTestCheck(make.Kind == .Construct && mg.Graph.Nodes.Count == before + 3 && dd != null && call != null && mg.Graph.IsLinked(then) &&
					mg.Graph.IsLinked(dd.FindInput("object")) && dd.FindOutput("then") != null && call.ExecIn != null && mg.Graph.IsLinked(call.ExecIn),
					scope $"entry: Construct Engine + Run places Construct, Defer Delete and Run wired ({mg.Graph.Nodes.Count - before} nodes)");
				if (call == null)
					return true;
				mEntryCallKey.Set(call.Key);
				EditDoc.Undo();
				SelfTestCheck(mg.Graph.Nodes.Count == before, scope $"entry: one Ctrl+Z removes the three ({mg.Graph.Nodes.Count - before} left)");
				EditDoc.Redo();
				SelfTestCheck(mg.Graph.Nodes.Count == before + 3, "entry: Ctrl+Y puts them back");
				mSelfTestWait = 3;
				return false;
			}
			case 7:
			{
				let mg = CurrentMethod;
				let call = mg.Graph.FindNodeByKey(mEntryCallKey);
				SelfTestCheck(call != null, "entry: the Run call is there after the redo");
				if (call == null)
					return true;
				// From an Engine pin (the Construct's Object): Engine's functions first, the base's too.
				Node make = null;
				for (let l in mg.Graph.Links)
					if (l.To == EntryReceiver(call))
						make = l.From.Owner;
				let obj = make?.Result ?? make?.FindOutput("object");
				if (obj != null)
				{
					List<NodeItem> rows = scope .();
					defer { ClearAndDeleteItems!(rows); }
					EntryRows("Run", obj.Id, rows);
					SelfTestCheck(!rows.IsEmpty && rows[0].Label == "Run" && rows[0].Category.EndsWith("Engine"), scope $"entry: 'Run' from an Engine's Object lists Engine's Run first ({EntryRowList(rows, .. scope String())})");
					ClearAndDeleteItems!(rows);
					EntryRows("", obj.Id, rows);
					SelfTestCheck(!rows.IsEmpty && rows[0].Category.EndsWith("Engine") && EntryRowIndex(rows, "Run", "Engine") >= 0,
						scope $"entry: from an Engine's Object with nothing typed, Engine's members come first ({EntryRowList(rows, .. scope String())})");
					SelfTestCheck(EntryRowIndex(rows, "Init", "BaseEngine") >= 0, "entry: from an Engine's Object, the base class's Init is listed");
					ClearAndDeleteItems!(rows);
					EntryRows("init", obj.Id, rows);
					SelfTestCheck(EntryRowIndex(rows, "Init", "BaseEngine") == 0, scope $"entry: 'init' from an Engine's Object finds BaseEngine's Init ({EntryRowList(rows, .. scope String())})");
				}
				// The static Helper after Run: no Receiver.
				let helper = EntryPlace("engine helper", "Helper", call.FindOutput("then"), call.X + 320, call.Y);
				SelfTestCheck(helper != null && EntryReceiver(helper) == null, "entry: the static Helper places with no Receiver");
				if (helper != null)
					mEntryHelperKey.Set(helper.Key);
				mSelfTestWait = 3;
				return false;
			}
			case 8:
				SelfTestCheck(EntryDoc("Program") != null && EntryDoc("Program").Modified, "entry: Program has unsaved changes before Run");
				// Run on the modified project: it builds first, then starts the program.
				EntryStartRun();
				SelfTestCheck(mBuild != null && mBuild.Running, "entry: Run on a modified project starts a build first");
				mSelfTestStep = 19;
				return false;
			case 20:
				if (!EntryWaitRun())
					return false;
				{
					SelfTestCheck(mBuild != null && mBuild.Succeeded && !EntryDoc("Program").Modified, scope $"entry: Run saved Program and its build succeeded ({(mBuild != null) ? mBuild.Messages.Count : -1} messages)");
					if (mBuild != null)
						for (let d in mBuild.Messages)
							Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] entry build: {d.Text} node {d.NodeKey}");
					String all = scope .();
					for (let l in mBuildRunOutput)
						all.AppendF("{}|", l);
					SelfTestCheck(mProgramRun != null && mProgramRun.ExitCode == 0 && all == "hello from Engine|static helper|", scope $"entry: Run shows the program's output ({all})");
				}
				EntryStartRun();
				return false;
			case 21:
				if (!EntryWaitRun())
					return false;
				SelfTestCheck(mBuild != null && mBuild.Succeeded && mProgramRun != null && mProgramRun.Finished && mProgramRun.ExitCode == 0, "entry: a second Run with nothing changed runs again");
				DeleteContainerAndItems!(mBuildRunOutput);
				mBuildRunOutput = null;
				// No entry: the build fails and Problems offers Create Main.
				Project.SetEntryType("");
				SaveProjectFile();
				mEntryWatch.Restart();
				Build();
				return false;
			case 22:
				if (!EntryWaitBuild())
					return false;
				SelfTestCheck(mBuild != null && !mBuild.Succeeded && BuildMissesEntry(), "entry: a build with no entry fails and Problems offers Create Main");
				CreateMain();
				SelfTestCheck(HasEntryMain() && CurrentMethod != null && CurrentMethod.Name == "Main" && IsEntryType(CurrentMethod.Doc) && CurrentMethod.Doc.Header.Name == "Program",
					"entry: Create Main names Program again and opens its Main");
				{
					String text = scope .();
					File.ReadAllText(ProjectPath, text).IgnoreError();
					SelfTestCheck(text.Contains("entry Test.Program"), "entry: the project file has `entry Test.Program` again");
				}
				// Set as entry point on another type's static Main, undone and redone.
				let tool = NewDocument(scope $"{mEntryRoot}{Path.DirectorySeparatorChar}Source{Path.DirectorySeparatorChar}Tool.treadle");
				if (tool != null && BeginTypeEdit())
				{
					tool.Header.Static = true;
					EndTypeEdit();
				}
				AddFunctionMember("Main");
				mSelfTestWait = 5;
				return false;
			case 23:
			{
				let tool = EntryDoc("Tool");
				let main = tool?.FindMember("Main");
				if (main != null && BeginTypeEdit())
				{
					main.Static = true;
					EndTypeEdit();
				}
				SelfTestCheck(main != null && !IsEntryFunction(tool, main), "entry: Tool.Main is not the entry point yet");
				if (main == null)
					return true;
				SetEntryPoint(tool, main);
				String label = scope .();
				EntryLabel(label);
				SelfTestCheck(label == "Tool.Main" && IsEntryFunction(tool, main), scope $"entry: Set as entry point makes Tool.Main the entry ({label})");
				SelfTestCheck(UndoEntryChange(), "entry: Ctrl+Z undoes Set as entry point");
				label.Clear();
				EntryLabel(label);
				SelfTestCheck(label == "Program.Main", scope $"entry: after Ctrl+Z the entry is Program.Main again ({label})");
				SelfTestCheck(RedoEntryChange(), "entry: Ctrl+Y redoes it");
				label.Clear();
				EntryLabel(label);
				SelfTestCheck(label == "Tool.Main", scope $"entry: after Ctrl+Y the entry is Tool.Main ({label})");
				UndoEntryChange();
				mSelfTestWait = 3;
				return false;
			}
			default:
				for (let d in mDocs)
					d.Modified = false;
				DeleteAndNullify!(mEntryChange);
				DeleteAndNullify!(mProgramRun); // a later case waits for its own run
				OpenProjectNow("", "", false);
				ForgetRecentProject(mEntryRoot);
				{
					String key = scope .(mEntryRoot);
					key.ToLower();
					Settings.Root?.Get("projects")?.Remove(key);
					Settings.Save();
				}
				Directory.DelTree(mEntryLocation).IgnoreError();
				return true;
			}
		}
	}
}
#endif
