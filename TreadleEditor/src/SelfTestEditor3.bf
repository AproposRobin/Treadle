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

namespace Treadle.Editor
{
	/// The `editor` case's checks of the third editor wave, run before the case saves Player
	/// (SelfTestE3Before, one phase per call, on the open copy of Player; every edit is undone) and
	/// after it (SelfTestE3After, on a project of its own):
	///
	///  - Type Settings rows for `extends`, `signature` and `uses`: each edit one undo step, the codec
	///    writes the lines and reads them back to the same header.
	///  - The ref pin's Fix: a Call of a function with a `ref` input holding a literal shows the Fix chip
	///    when it runs in the flow (not when it does not); the Fix makes a Local, a Set of it before the
	///    Call and a Get into the input, one undo step.
	///  - Deleting a Base / This Constructor node clears the constructor's `chain`; undo brings both back.
	///  - The Node menu's "writeline int": WriteLine (int) first, the other overloads folded into one
	///    "more overloads" row under it, which lists them when picked.
	///  - The project page's config rows (a new project): kind, optimize, checks, define and debugFormat
	///    written to the project file and read back; the active config is Build's.
	///  - The project page's C Imports: a header added makes its set; the whole of stdio.h imports with
	///    warnings, an `only` list written from the rows imports without; a set removed and added again.
	extension EditorApp
	{
		int mE3Phase;
		int32 mE3CallId;
		int32 mE3LooseCallId;
		int mE3Nodes;
		CtorChain mE3Chain;
		int32 mE3ChainId;

		/// One phase per call; true when the phases before the save are done.
		bool SelfTestE3Before()
		{
			switch (mE3Phase++)
			{
			case 0:
				SelfTestE3TypeSettings();
				return false;
			case 1, 2, 3, 4, 5:
				SelfTestE3RefFix(mE3Phase - 2);
				return false;
			case 6, 7, 8:
				SelfTestE3Chain(mE3Phase - 7);
				return false;
			case 9:
				SelfTestE3Overloads();
				return false;
			default:
				mE3Phase = 0;
				return true;
			}
		}

		/// Deleting a Base / This Constructor node: the constructor's `chain` goes with it (one undo step).
		void SelfTestE3Chain(int phase)
		{
			switch (phase)
			{
			case 0:
				Sheet ctor = null;
				for (let s in Doc.Sheets)
					if (s.Member != null && s.Member.Kind == .Ctor && s.Role == .Body)
						ctor = s;
				SelfTestCheck(ctor != null, "editor: chain: Player has a constructor Sheet");
				if (ctor != null)
					OpenTab(ctor);
			case 1:
				let mg = CurrentMethod;
				if (mg == null || mg.Member == null || mg.Member.Kind != .Ctor)
				{
					SelfTestCheck(false, "editor: chain: the constructor's Sheet in front");
					return;
				}
				// Player's constructor runs Actor's first: `chain base` and its Base Constructor node.
				mE3Chain = mg.Member.Chain;
				mE3ChainId = 0;
				for (let n in mg.Graph.Nodes)
					if (n.Kind == .ChainCtor)
						mE3ChainId = n.Id;
				SelfTestCheck(mE3Chain == .Base && mE3ChainId != 0, scope $"editor: chain: Player's constructor has chain base and its Base Constructor node ({mE3Chain})");
			case 2:
				let mg = CurrentMethod;
				let tab = CurrentTab;
				if (mE3ChainId == 0 || mg == null || mg.Member == null)
					return;
				tab.SelectOnly(mE3ChainId);
				DeleteSelection(tab);
				bool gone = mg.Graph.FindNode(mE3ChainId) == null;
				bool cleared = mg.Member.Chain == .None;
				SelfTestCheck(gone && cleared, scope $"editor: chain: deleting the Base Constructor node clears the constructor's Runs First (gone {gone}, {mg.Member.Chain})");
				Doc.Undo();
				let back = CurrentMethod;
				bool restored = back != null && back.Member?.Chain == mE3Chain;
				bool node = false;
				if (back != null)
					for (let n in back.Graph.Nodes)
						node |= n.Kind == .ChainCtor;
				SelfTestCheck(restored && node, "editor: chain: undo brings the node and chain base back (one step)");
				let s = Doc.FindSheetByName("TakeDamage");
				if (s != null)
					OpenTab(s);
			}
		}

		/// "writeline int": the int overload first, the others folded under one row that lists them.
		void SelfTestE3Overloads()
		{
			let mg = CurrentMethod;
			List<NodeItem> rows = scope .();
			defer { ClearAndDeleteItems!(rows); }
			mNodeMenu.ListFor(mg, 0, "writeline int", rows);
			int writeLines = 0;
			NodeItem more = null;
			for (let r in rows)
			{
				if (r.Label.StartsWith("WriteLine ("))
					writeLines++;
				if (r.Kind == .MoreOverloads && more == null)
					more = r;
			}
			StringView first = rows.IsEmpty ? "nothing" : (StringView)rows[0].Label;
			StringView second = (rows.Count > 1) ? (StringView)rows[1].Label : "nothing";
			SelfTestCheck(first.StartsWith("WriteLine (int") && rows.Count > 1 && rows[1].Kind == .MoreOverloads && writeLines == 1,
				scope $"editor: 'writeline int' lists WriteLine (int) first and folds the other overloads into '{second}' ({first}; {writeLines} WriteLine rows)");
			if (more != null)
			{
				mNodeMenu.ExpandOverloads(more);
				List<NodeItem> all = scope .();
				defer { ClearAndDeleteItems!(all); }
				mNodeMenu.SelfTestRows("writeline int", all);
				int shown = 0;
				bool noMore = true;
				for (let r in all)
				{
					if (r.Label.StartsWith("WriteLine ("))
						shown++;
					noMore &= r.Kind != .MoreOverloads;
				}
				SelfTestCheck(shown > 2 && noMore && !all.IsEmpty && all[0].Label.StartsWith("WriteLine (int"),
					scope $"editor: picking the more-overloads row lists every WriteLine overload, the int one still first ({shown})");
			}
			// Plain "writeline": nothing is folded (no parameter type is named).
			ClearAndDeleteItems!(rows);
			mNodeMenu.ListFor(mg, 0, "writeline", rows);
			bool folded = false;
			for (let r in rows)
				folded |= r.Kind == .MoreOverloads;
			SelfTestCheck(!folded, "editor: 'writeline' alone lists the overloads without folding them");
		}

		String mE3Root = new .() ~ delete _;

		/// One phase per call, after the save, on a new project; true when done (the project closed and
		/// its folder gone).
		bool SelfTestE3After()
		{
			switch (mE3Phase++)
			{
			case 0:
				// A new project of its own (File > New Project), opened.
				String temp = scope .();
				if (!SelfTestTemp.Get(temp))
					temp.Set(mSelfTestDir);
				mE3Root.Set(scope $"{temp}/treadle-e3-{(int)Platform.BfpSystem_GetTimeStamp() & 0xFFFFFF}");
				Directory.CreateDirectory(mE3Root).IgnoreError();
				String typePath = scope .();
				String why = scope .();
				let made = CreateProjectFiles(mE3Root, "Wave", typePath, why);
				SelfTestCheck(made, scope $"editor: project page: a new project to edit {why}");
				for (let d in mDocs)
					d.Modified = false;
				RequestOpenProject(mE3Root, typePath);
				mSelfTestWait = 20;
				return false;
			case 1:
				SelfTestE3ProjectRows();
				mSelfTestWait = 3;
				return false;
			case 2, 3:
				SelfTestE3CImports(mE3Phase - 3);
				mSelfTestWait = 3;
				return false;
			case 4:
				// Making types (SelfTestNewType.bf): one phase per frame on this project.
				if (!SelfTestNewTypes())
					mE3Phase--;
				mSelfTestWait = Math.Max(mSelfTestWait, 2);
				return false;
			default:
				// File > Close Project, then the folder goes.
				for (let d in mDocs)
					d.Modified = false;
				OpenProjectNow("", "", false);
				Directory.DelTree(mE3Root).IgnoreError();
				mE3Phase = 0;
				return true;
			}
		}

		/// The project page's config rows through their calls: Kind, Optimize, Checks, Defines, Debug
		/// Format written to the project file and read back (no `lto` line: an optimised config always
		/// uses ThinLTO); the active config is
		/// the one Build uses.
		void SelfTestE3ProjectRows()
		{
			let p = Project;
			SelfTestCheck(p != null && mProjectRoot == mE3Root && !ProjectPath.IsEmpty, scope $"editor: project page: the new project is open ({mProjectRoot})");
			if (p == null)
				return;
			let debug = p.FindConfig("Debug");
			let release = p.FindConfig("Release");
			if (debug == null || release == null)
			{
				SelfTestCheck(false, "editor: project page: New Project's Debug and Release configs");
				return;
			}
			// The rows show the file's values, else the name's defaults.
			SelfTestCheck(ConfigValue(debug, cOptimizeKey) == "0" && ConfigValue(release, cOptimizeKey) == "2" && ConfigValue(release, cChecksKey) == "off" &&
				ConfigValue(debug, cDebugFormatKey) == "dwarf",
				"editor: project page: Optimize, Checks and Debug Format show the file's values or the defaults");
			p.Kind.Set("windowed");
			bool edits = SetConfigValue(debug, cOptimizeKey, "1");
			edits &= SetConfigValue(debug, cChecksKey, "off");
			edits &= SetConfigValue(debug, cDebugFormatKey, "both");
			edits &= !SetConfigValue(release, cDebugFormatKey, "dwarf"); // the default, not written
			List<String> defines = scope .();
			defer { ClearAndDeleteItems!(defines); }
			defines.Add(new String("DEBUG"));
			defines.Add(new String("LEVEL=3"));
			edits &= SetConfigDefines(debug, defines);
			delete defines[0];
			defines.RemoveAt(0);
			edits &= SetConfigDefines(debug, defines);
			edits &= SaveProjectFile();
			String text = scope .();
			File.ReadAllText(ProjectPath, text).IgnoreError();
			bool lines = text.Contains("\tkind windowed\n") && text.Contains("config Debug\n\tchecks off\n\toptimize 1\n\tdebugFormat both\n\tdefine LEVEL=3\n") &&
				text.Contains("config Release\n\toptimize 2\n\tchecks off\n") && !text.Contains("\tlto ") && !text.Contains("define DEBUG");
			ProjectFile back = scope .();
			List<FormatError> errors = scope .();
			defer { ClearAndDeleteItems!(errors); }
			String text2 = scope .();
			if (ProjectCodec.ReadProject(text, back, errors))
				ProjectCodec.WriteProject(back, text2);
			SelfTestCheck(edits && lines && text2 == text, scope $"editor: project page: kind, optimize, checks, define and debugFormat are written to the project file and read back (edits {edits}, lines {lines})");
			if (!lines)
				Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] project file:\n{text}");
			// Build and Run use the active config.
			SetActiveConfig("Release");
			bool rel = ActiveConfig == "Release";
			SetActiveConfig("Debug");
			SelfTestCheck(rel && ActiveConfig == "Debug", "editor: project page: the active config (Build's) follows Make Active / Active Config");
			// Drawn on the next frames.
			SelectProjectSettings();
		}

		/// The stdio.h the C import cases use: the toolchain's on Windows (llvm-mingw ships the mingw headers), the
		/// system's on Linux (the distribution's LLVM include folder has no C library headers).
		static void SelfTestStdioHeader(String outPath)
		{
#if BF_PLATFORM_WINDOWS
			String root = scope .();
			Treadle.Language.LlvmRoot.Get(root);
			outPath.AppendF("{}{}include{}stdio.h", root, Path.DirectorySeparatorChar, Path.DirectorySeparatorChar);
#else
			outPath.Append("/usr/include/stdio.h");
#endif
		}

		int mE3Warnings;
		double mE3HoldUntil;

		/// The project page's C Imports: Add Set with a header, Import Again (warnings), an `only` list,
		/// Import Again (none), Remove and Add Set with the `.cimport` file.
		void SelfTestE3CImports(int phase)
		{
			String setPath = scope $"{mE3Root}/stdio.cimport";
			switch (phase)
			{
			case 0:
				String header = scope .();
				SelfTestStdioHeader(header);
				let added = AddProjectCImport(header);
				String projText = scope .();
				File.ReadAllText(ProjectPath, projText).IgnoreError();
				SelfTestCheck(added && File.Exists(setPath) && projText.Contains("cimport stdio.cimport\n") && Project.CImports.Count == 1,
					scope $"editor: C imports: Add Set with stdio.h makes stdio.cimport and lists it in the project file ({header})");
				// With no set, Import C Headers would ask for a header in a file dialog: never in a self test.
				if (Project.CImports.Count > 0)
					ImportCHeaders();
				mE3Warnings = LastCImportWarnings;
				SelfTestCheck(LastCImportFailed == 0, scope $"editor: C imports: the whole of stdio.h imports ({mE3Warnings} warnings)");
			case 1:
				List<String> only = scope .();
				defer { ClearAndDeleteItems!(only); }
				only.Add(new String("puts"));
				only.Add(new String("printf"));
				let written = SetCImportOnly(setPath, "stdio", only);
				String text = scope .();
				File.ReadAllText(setPath, text).IgnoreError();
				SelfTestCheck(written && text.Contains("\tonly puts printf\n"), "editor: C imports: the Only rows write `only puts printf` to the set");
				if (Project.CImports.Count > 0)
					ImportCHeaders();
				SelfTestCheck(LastCImportFailed == 0 && LastCImportWarnings == 0 && mE3Warnings > 0,
					scope $"editor: C imports: with an only list the set imports without warnings ({mE3Warnings} before, {LastCImportWarnings} after)");
				List<NodeItem> rows = scope .();
				defer { ClearAndDeleteItems!(rows); }
				if (CurrentMethod != null)
					mNodeMenu.ListFor(CurrentMethod, 0, "puts", rows);
				bool puts = false;
				for (let r in rows)
					puts |= r.Label.StartsWith("puts");
				SelfTestCheck(puts, "editor: C imports: the Node menu offers puts after Import Again");
				// Remove (the file stays) and add the set file back.
				let removed = RemoveProjectCImport(0) && Project.CImports.IsEmpty && File.Exists(setPath);
				let back = AddProjectCImport(setPath) && Project.CImports.Count == 1 && Project.CImports[0] == "stdio.cimport";
				SelfTestCheck(removed && back, "editor: C imports: Remove takes the set out of the project (the file stays); Add Set with the .cimport file lists it again");
			}
		}

		/// The ref pin's Fix, one phase per frame: a function Bump(ref int counter), two Calls of it in
		/// TakeDamage with a literal on the ref input (one in the flow, one not), Validate, the chip, the
		/// Fix, its result, then undo back to Player as it was.
		void SelfTestE3RefFix(int phase)
		{
			switch (phase)
			{
			case 0:
				let m = AddFunctionMember("Bump");
				if (m != null)
				{
					AddParam(m, false);
					if (BeginTypeEdit())
					{
						m.Params[0].Name.Set("counter");
						m.Params[0].Mode = .Ref;
						SyncSheets(m);
						EndTypeEdit();
					}
				}
				SelfTestCheck(m != null && m.Params.Count == 1 && m.Params[0].Mode == .Ref, "editor: ref fix: Player gets Bump(ref int counter)");
				let s = Doc.FindSheetByName("TakeDamage");
				if (s != null)
					OpenTab(s);
			case 1:
				let mg = CurrentMethod;
				let m = Doc.FindMember("Bump");
				if (mg == null || mg.Name != "TakeDamage" || m == null)
				{
					SelfTestCheck(false, "editor: ref fix: TakeDamage in front");
					return;
				}
				let g = mg.Graph;
				mE3Nodes = g.Nodes.Count;
				BeginEdit();
				let call = NodeMenu.CallOwn(g, m, "Game.Player", true);
				let next = g.ExecTarget(g.Entry.Then);
				g.Connect(g.Entry.Then, call.ExecIn);
				if (next != null)
					g.Connect(call.Then, next.ExecIn);
				call.FindInput("counter")?.Default.Set("5");
				call.X = g.Entry.X + 300;
				call.Y = g.Entry.Y + 400;
				call.HasPos = true;
				let loose = NodeMenu.CallOwn(g, m, "Game.Player", true);
				loose.FindInput("counter")?.Default.Set("7");
				loose.X = g.Entry.X + 300;
				loose.Y = g.Entry.Y + 700;
				loose.HasPos = true;
				mE3CallId = call.Id;
				mE3LooseCallId = loose.Id;
				CommitCurrent();
			case 2:
				let mg = CurrentMethod;
				let g = mg.Graph;
				let call = g.FindNode(mE3CallId);
				let loose = g.FindNode(mE3LooseCallId);
				let pin = call?.FindInput("counter");
				SelfTestCheck(pin != null && pin.IsRefArg && RefPinNeedingLocal(mg.Doc, g, call) == pin && RefPinNeedingLocal(mg.Doc, g, loose) == null,
					"editor: ref fix: a literal on a ref input needs a Local in the flow; a Call not in the flow gets no Fix");
				Validate(true);
			case 3:
				let mg = CurrentMethod;
				let g = mg.Graph;
				bool chip = mGraphPanel.FixShown(mE3CallId);
				bool noChip = !mGraphPanel.FixShown(mE3LooseCallId);
				String strip = scope .();
				mGraphPanel.ProblemStripOf(mE3CallId, strip, ?, ?, ?);
				SelfTestCheck(chip && noChip, scope $"editor: ref fix: the Call in the flow shows the Fix chip, the other does not ({strip})");
				let call = g.FindNode(mE3CallId);
				let pin = call?.FindInput("counter");
				SelfTestCheck(pin != null && StoreRefInLocal(mg, pin, false, false), "editor: ref fix: Make local variable runs");
			case 4:
				let mg = CurrentMethod;
				let g = mg.Graph;
				let call = g.FindNode(mE3CallId);
				let pin = call?.FindInput("counter");
				let local = g.FindLocal("counter");
				Node set = null, get = null;
				for (let n in g.Nodes)
				{
					if (n.Kind == .Set && n.Text == "local:counter")
						set = n;
					if (n.Kind == .Get && n.Text == "local:counter")
						get = n;
				}
				bool flow = set != null && g.ExecTarget(g.Entry.Then) == set && g.ExecTarget(set.Then) == call;
				bool wired = get != null && pin != null && g.DataSource(pin) == get;
				bool value = set != null && set.FindInput("value")?.Default == "5" && pin != null && pin.Default.IsEmpty;
				SelfTestCheck(local != null && local.Type?.ToString(.. scope String()) == "int" && flow && wired && value && RefPinNeedingLocal(mg.Doc, g, call) == null,
					scope $"editor: ref fix: a Local counter (int), its Set with 5 runs right before the Call, its Get feeds the ref input (flow {flow}, wired {wired}, value {value})");
				// Back: the Fix, the Calls, the input's mode, the input and the function.
				for (int i < 5)
					Doc.Undo();
				let back = CurrentMethod?.Graph;
				SelfTestCheck(Doc.FindMember("Bump") == null && back != null && back.FindLocal("counter") == null && back.Nodes.Count == mE3Nodes,
					scope $"editor: ref fix: undo takes the Fix and the setup back ({(back != null) ? back.Nodes.Count : -1} nodes)");
			}
		}

		/// Type Settings: `uses`, `extends` (an extension) and `signature` (a delegate type) through the
		/// rows' calls, one undo step each; the file writes and reads them back; undo restores Player.
		void SelfTestE3TypeSettings()
		{
			let h = Doc.Header;
			let kind = h.Kind;
			int uses = h.Uses.Count;
			int steps = 0;
			// Uses: add, change, remove (each one undo step).
			steps += SetUses(h.Uses.Count, "Game.Extra") ? 1 : 0;
			steps += SetUses(h.Uses.Count, "Core") ? 1 : 0;
			bool added = h.Uses.Count == uses + 2 && h.Uses[uses] == "Game.Extra" && h.Uses[uses + 1] == "Core";
			steps += SetUses(uses, "Game.Items") ? 1 : 0;
			bool changed = h.Uses[uses] == "Game.Items";
			bool dupRefused = !SetUses(uses + 1, "Game.Items");
			String usesNow = scope .();
			for (let u in h.Uses)
				usesNow.AppendF(" {}", u);
			SelfTestCheck(added && changed && dupRefused && steps == 3, scope $"editor: Type Settings' Uses rows add, change a namespace, refuse a second one of the same name (uses{usesNow}; {added} {changed} {dupRefused} {steps})");
			// An extension: Kind, then Extends from the picker's list.
			if (BeginTypeEdit())
			{
				h.Kind = .Extension;
				EndTypeEdit();
				steps++;
			}
			List<String> ext = scope .();
			defer { ClearAndDeleteItems!(ext); }
			ExtendableTypes(ext);
			bool hasPair = false, hasSelf = false, hasList = false;
			for (let t in ext)
			{
				hasPair |= t == "Core.Pair<A,B>" || t.StartsWith("Core.Pair");
				hasSelf |= t == "Game.Player";
				hasList |= t.StartsWith("Core.List<");
			}
			SelfTestCheck(hasPair && !hasSelf, scope $"editor: the Extends picker lists the project's types, not the type itself ({ext.Count} types{(hasList ? ", Core.List<T> among them" : "")})");
			steps += SetTypeExtends("Core.String") ? 1 : 0;
			bool extOk = h.Extends?.ToString(.. scope String()) == "Core.String";
			steps += SetTypeExtends("Core.List<T>") ? 1 : 0;
			extOk &= h.Extends?.ToString(.. scope String()) == "Core.List<T>";
			String extNow = scope .();
			h.Extends?.ToString(extNow);
			SelfTestCheck(extOk, scope $"editor: Type Settings' Extends row sets the extended type ({extNow})");
			// A delegate type: its signature from the Returns and Input rows.
			if (BeginTypeEdit())
			{
				h.Kind = .Delegate;
				EndTypeEdit();
				steps++;
			}
			steps += SetDelegateSignature("int", StringView[?]("int", "float")) ? 1 : 0;
			String sig = scope .();
			h.Signature?.AppendSignature(sig);
			steps += SetDelegateSignature("bool", StringView[?]("int", "float", "String")) ? 1 : 0;
			String sig2 = scope .();
			h.Signature?.AppendSignature(sig2);
			steps += SetDelegateSignature("void", StringView[?]()) ? 1 : 0;
			String sig3 = scope .();
			h.Signature?.AppendSignature(sig3);
			SelfTestCheck(sig == "int(int,float)" && sig2 == "bool(int,float,String)" && sig3 == "void()" && h.Signature.Kind == .Delegate,
				scope $"editor: Type Settings' Signature rows write the result and the inputs ({sig}, {sig2}, {sig3})");
			SetDelegateSignature("int", StringView[?]("int", "float"));
			steps++;
			// The codec: the lines are written and read back to the same header.
			String text = scope .();
			String why = scope .();
			Doc.WriteText(text, why);
			TypeDocument back = scope .(Language);
			String path = scope $"{mSelfTestDir}/E3Header.treadle";
			File.WriteAllText(path, text).IgnoreError();
			let read = LoadsClean(back, path);
			File.Delete(path).IgnoreError();
			String text2 = scope .();
			back.WriteText(text2, why);
			let bh = back.Header;
			bool lines = text.Contains("\tuses Game.Items\n") && text.Contains("\tuses Core\n") && text.Contains("\textends Core.List<T>\n") && text.Contains("\tsignature int(int,float)\n");
			bool same = read && text == text2 && bh.Uses.Count == h.Uses.Count && bh.Extends?.ToString(.. scope String()) == "Core.List<T>" && bh.Signature?.AppendSignature(.. scope String()) == "int(int,float)";
			SelfTestCheck(lines && same, scope $"editor: uses, extends and signature are written and read back to the same header (lines {lines}, read back {same})");
			if (!lines || !same)
				Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] header written:\n{text}");
			// Undo: Player as it was.
			for (int i < steps)
				Doc.Undo();
			SelfTestCheck(Doc.Header.Kind == kind && Doc.Header.Uses.Count == uses && Doc.Header.Extends == null && Doc.Header.Signature == null,
				scope $"editor: undo takes the {steps} Type Settings edits back one by one ({Doc.Header.Kind}, {Doc.Header.Uses.Count} uses)");
			// The rows are drawn (the next frames show Type Settings).
			SelectOutline(.TypeSettings);
		}

		/// Capture steps for the pixel pass of the third wave (TREADLE_SELFTEST, nothing is saved but the
		/// project they make): `e3.project` (a new project with a stdio set, `only puts printf`, a define,
		/// opened), `e3.page` (its page in Properties), `e3.closed:<A;B>` (sections drawn closed),
		/// `e3.ext` / `e3.delegate` (the type in front made an extension of Core.String using Core / a
		/// delegate type int(int,float), its Type Settings shown), `e3.reffix` (a Call with a literal on a
		/// ref input in Main, validated: the Fix chip), `e3.hold:<name>` (logs `hold <name>` and waits
		/// about 4 s for the capture script), `e3.cleanup` (the project closed, its folder deleted).
		/// False when `test` is none of them.
		bool SelfTestE3Capture(StringView test, ref bool finished)
		{
			if (!test.StartsWith("e3."))
				return false;
			let colon = test.IndexOf(':');
			let verb = (colon > 0) ? test.Substring(3, colon - 3) : test.Substring(3);
			let arg = (colon > 0) ? test.Substring(colon + 1) : "";
			switch (verb)
			{
			case "project":
				String temp = scope .();
				SelfTestTemp.Get(temp);
				mE3Root.Set(scope $"{temp}/treadle-e3-capture-{(int)Platform.BfpSystem_GetTimeStamp() & 0xFFFFFF}");
				Directory.CreateDirectory(mE3Root).IgnoreError();
				String typePath = scope .();
				String why = scope .();
				if (!CreateProjectFiles(mE3Root, "Wave", typePath, why))
				{
					SelfTestCheck(false, scope $"capture: e3.project {why}");
					return true;
				}
				// A stdio set limited to puts and printf, and a define (what the rows show).
				ProjectFile p = scope .();
				String text = scope .();
				File.ReadAllText(scope $"{mE3Root}/Wave.tproj", text).IgnoreError();
				List<FormatError> errors = scope .();
				defer { ClearAndDeleteItems!(errors); }
				ProjectCodec.ReadProject(text, p, errors);
				String header = scope .();
				SelfTestStdioHeader(header);
				String setPath = scope .();
				ImportHeader.CreateSet(mE3Root, p, header, setPath, why);
				let debug = p.FindConfig("Debug");
				if (debug != null)
				{
					List<String> defines = scope .();
					defer { ClearAndDeleteItems!(defines); }
					defines.Add(new String("TRACE"));
					defines.Add(new String("LEVEL=3"));
					SetConfigDefines(debug, defines);
				}
				text.Clear();
				ProjectCodec.WriteProject(p, text);
				File.WriteAllText(scope $"{mE3Root}/Wave.tproj", text).IgnoreError();
				CImportFile f = scope .();
				if (ReadCImportFile(setPath, f, why) && !f.Sets.IsEmpty)
				{
					f.Sets[0].Only.Add(new String("puts"));
					f.Sets[0].Only.Add(new String("printf"));
					text.Clear();
					ProjectCodec.WriteCImport(f, text);
					File.WriteAllText(setPath, text).IgnoreError();
				}
				for (let d in mDocs)
					d.Modified = false;
				RequestOpenProject(mE3Root, typePath);
				mSelfTestWait = 30;
			case "page":
				SelectProjectSettings();
				Panels.Focus(Panels.ProjectBrowserId);
			case "closed":
				PropertyGrid.ForceClosed.Set(arg);
			case "ext", "delegate":
				if (Doc != null && BeginTypeEdit())
				{
					let h = Doc.Header;
					if (verb == "ext")
					{
						h.Kind = .Extension;
						DeleteAndNullify!(h.Extends);
						h.Extends = TypeRef.Parse("Core.String");
						if (!h.Uses.Contains("Core"))
							h.Uses.Add(new String("Core"));
					}
					else
					{
						h.Kind = .Delegate;
						DeleteAndNullify!(h.Signature);
						h.Signature = TypeRef.ParseSignature("int(int,float)");
					}
					h.Static = false;
					EndTypeEdit();
				}
				SelectOutline(.TypeSettings);
			case "bump":
				// A static function Bump(ref int counter); Main in front again.
				let main = Doc?.FindSheetByName("Main");
				MemberDecl m = (main != null) ? AddFunctionMember("Bump") : null;
				if (m == null)
					return true;
				AddParam(m, false);
				if (BeginTypeEdit())
				{
					m.Static = true;
					m.Params[0].Name.Set("counter");
					m.Params[0].Mode = .Ref;
					SyncSheets(m);
					EndTypeEdit();
				}
				OpenTab(main);
				mSelfTestWait = 5;
			case "reffix":
				// A Call of Bump right after Main's Entry with 5 on its ref input.
				let mg = CurrentMethod;
				let m = Doc?.FindMember("Bump");
				if (mg == null || m == null)
					return true;
				let g = mg.Graph;
				BeginEdit();
				let call = NodeMenu.CallOwn(g, m, Doc.Header.GetFullName(.. scope String()), true);
				let next = g.ExecTarget(g.Entry.Then);
				g.Connect(g.Entry.Then, call.ExecIn);
				if (next != null)
					g.Connect(call.Then, next.ExecIn);
				call.FindInput("counter")?.Default.Set("5");
				call.X = g.Entry.X + 320;
				call.Y = g.Entry.Y;
				call.HasPos = true;
				CommitCurrent();
				mSelfTestWait = 5;
			case "validate":
				Validate(true);
			case "closemenu":
				mNodeMenu.CloseRequested = true;
			case "hold":
				// About 4 s by the clock (frames come faster than the screen's rate when nothing waits).
				let now = ImGui.Gui.igGetTime();
				if (mE3HoldUntil == 0)
				{
					mE3HoldUntil = now + 4.0;
					Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] hold {arg}");
				}
				if (now < mE3HoldUntil)
					finished = false;
				else
					mE3HoldUntil = 0;
			case "cleanup":
				PropertyGrid.ForceClosed.Clear();
				for (let d in mDocs)
					d.Modified = false;
				OpenProjectNow("", "", false);
				if (!mE3Root.IsEmpty)
					Directory.DelTree(mE3Root).IgnoreError();
			default:
				SelfTestCheck(false, scope $"capture: unknown step {test}");
			}
			return true;
		}
	}
}
#endif
