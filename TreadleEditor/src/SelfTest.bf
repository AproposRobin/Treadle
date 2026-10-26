// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Format;
using Treadle.Model;
using System.IO;

namespace Treadle.Editor
{
	/// Hidden UI smoke harness: drives the running editor through the same calls its UI makes
	/// (no window messages), selected by the TREADLE_SELFTEST environment variable, a comma list
	/// run in order:
	///
	///  - `smoke`: the shell is up (dock layout, seams installed), an untitled document with a
	///    Sheet, a node added and wired state checked, undo and redo.
	///  - `codec`: the samples in TreadleCore/samples (or TREADLE_SAMPLES) read and write back byte
	///    for byte through a temp file (type files, the layout, the project, the C import set); the
	///    reading-order originals normalise to them; unknown records and keys survive; a
	///    malformed file reports a line-numbered error naming the node; version handling
	///    (SelfTestMigrate.bf): format-history/v1, a simulated bump, the alias table, a newer file.
	///  - `editor`: a copy of the Player sample opens; a node of each kind is placed through the
	///    catalogue (the Node menu's rows); two pins are wired and an incompatible wire is refused with
	///    its reason; the rows offered from a pin are only ones that can be wired to it; Type Settings
	///    adds a field and a function (one undo step each) and the Outline lists them; the document
	///    saves, and reading it back gives the same model; then Help > Report a Problem: the bundle
	///    from a sample project (contents, no build/ files, the 8 MB cap, Save), the summary and issue
	///    link, and the buttons hidden or shown by IssuesUrl / SupportChatUrl (ReportProblem.bf). Before the third
	///    wave, the type context (SelfTestDocTabs.bf): two types open, one Sheet strip per type, header, title.
	///  - `menu`: opens the Node menu dragged off an int output and leaves it open (for captures).
	///  - `reportdialog`: opens Help > Report a Problem with sample texts and leaves it open (for captures).
	///  - `startsamples`: opens the start page's "Open a sample" list, checks it found samples, leaves it open
	///    (for captures; StartPage.bf).
	///  - `backend`: the back end's IR fixtures built, run and compared in Debug and Release, lldb on a
	///    node's listing line, Build / Run through the installed toolchain (SelfTestBackend.bf).
	///  - `frontend`: the compiler front end over the samples (SelfTestFrontEnd.bf).
	///  - `debug`: the debugger on a copy of samples/m1: a breakpoint, the stop, values, steps, the exit, and a
	///    double Delete stopping on its node with the runtime's message (SelfTestDebug.bf).
	///  - `fatal`: child editors started headless with TREADLE_DEBUG_FATAL end with exit code 3 (a fatal
	///    error, a failed assert, an access violation), 4 (a leak, Debug builds) or 5 (the watchdog),
	///    the reason in their log, no dialog (SelfTestFatal.bf).
	///  - `quit`: closes the editor when the earlier cases are done (unsaved changes discarded).
	///
	/// Results go to the Output Log / session log as `[SELFTEST] ok ...` / `[SELFTEST] FAIL ...`
	/// and end with `[SELFTEST] done failures=N`. Cases for the new model are added here as the
	/// model grows (kept to the essential set).
	extension EditorApp
	{
		/// -1: not read yet, -2: no self test (or finished), >= 0: running.
		int mSelfTestStep = -1;
		List<String> mSelfTests = new .() ~ DeleteContainerAndItems!(_);
		int mSelfTestFailures;
		int mSelfTestWait;

		void SelfTestCheck(bool ok, StringView what)
		{
			if (!ok)
				mSelfTestFailures++;
			Notify.Log(ok ? .Info : .Error, "SelfTest", scope $"[SELFTEST] {(ok ? "ok  " : "FAIL")} {what}");
		}

		/// Called once per frame.
		void SelfTestTick()
		{
			if (mSelfTestStep == -2)
				return;
			if (mSelfTestStep == -1)
			{
				String v = scope .();
				if (Environment.GetEnvironmentVariable("TREADLE_SELFTEST", v) case .Err || v.IsEmpty)
				{
					mSelfTestStep = -2;
					return;
				}
				for (var part in v.Split(','))
				{
					part.Trim();
					if (!part.IsEmpty)
						mSelfTests.Add(new String(part));
				}
				mSelfTestStep = 0;
				mSelfTestWait = 30; // let the dock layout settle first
				Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] start: {v}");
			}
			if (mCommitPending)
				return;
			if (mSelfTestWait > 0)
			{
				mSelfTestWait--;
				return;
			}
			if (mSelfTests.IsEmpty)
			{
				Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] done failures={mSelfTestFailures}");
				mSelfTestStep = -2;
				return;
			}
			let test = mSelfTests[0];
			if (CrashHandler.Headless)
				CrashHandler.SetPhase(scope $"self test {test} step {mSelfTestStep}");
			bool finished = true;
			switch (test)
			{
			case "smoke": finished = SelfTestSmoke();
			case "codec": finished = SelfTestCodec();
			case "editor": finished = SelfTestEditor(); if (finished) mSelfTests.Insert(1, new String("entry")); // the first-program case runs after it (SelfTestEntry.bf)
			case "menu": finished = SelfTestMenu();
			case "startsamples": SelfTestStartSamples(ref finished); // captures: StartPage.bf
			case "reportdialog":
				// Captures: Help > Report a Problem open with sample texts (ReportProblem.bf).
				OpenReportProblem();
				mReportDesc.Set("The canvas stops redrawing after a drag");
				mReportSteps.Set("1. Open Player.treadle\n2. Drag a node onto the minimap");
				mReport.Description.Set(mReportDesc.View);
				mReport.Steps.Set(mReportSteps.View);
				mReport.UpdateReportSize();
			case "showcase": finished = SelfTestShowcase();
			case "frame":
				// Captures: the whole Sheet in view.
				if (CurrentTab != null && CurrentMethod != null)
					mGraphPanel.FrameNodes(CurrentTab, CurrentMethod.Graph, false);
			case "typesettings":
				SelectOutline(.TypeSettings);
			case "zoomout":
				if (CurrentTab != null)
					CurrentTab.SetZoomLevel(CurrentTab.ZoomLevel - 2, .(0, 0));
			case "deselect":
				CurrentTab?.ClearSelection();
			case "zoomshow":
				mGraphPanel.PinZoomReadout = true; // captures: the zoom readout stays visible
			case "projecttile":
				// Captures: the project file's tile selected in the Project Browser, its settings in Properties.
				if (!ProjectPath.IsEmpty)
				{
					NavigateCB(mProjectRoot);
					String key = scope .();
					CBItem.MakeKey(.Project, ProjectPath, "", key);
					CBSelectOnly(key);
					SelectProjectSettings();
					Panels.Focus(Panels.ProjectBrowserId);
				}
			case "backend": finished = SelfTestBackend();
			case "frontend": finished = SelfTestFrontEnd();
			case "cimport": finished = SelfTestCImport();
			case "core": finished = SelfTestCore();
			case "update": finished = SelfTestUpdate(); // SelfTestUpdate.bf
			case "fuzzopen": finished = SelfTestFuzzOpen(); // SelfTestSecurity.bf
			case "debug": finished = SelfTestDebug();
			case "debugstop": finished = SelfTestDebugStop();
			case "hood": finished = SelfTestHood(); // SelfTestHood.bf
			case "fatal": finished = SelfTestFatal(); // SelfTestFatal.bf
			case "tutorial": finished = SelfTestTutorial(); // captures: SelfTestTutorial.bf
			case "entry": finished = SelfTestEntry(); // SelfTestEntry.bf
			case "scale": finished = SelfTestScale(false); // SelfTestScale.bf
			case "scalemeasure": finished = SelfTestScale(true);
			case "scalegen": finished = SelfTestScaleGen();
			case "quit":
				// Unsaved test edits are dropped: the harness never writes files.
				Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] done failures={mSelfTestFailures}");
				for (let d in mDocs)
					d.Modified = false;
				QuitNow = true;
			case "menuall":
				// Captures: the Node menu opened on the canvas (no pin), browsing its groups.
				if (CurrentTab != null && CurrentMethod != null)
				{
					mNodeMenu.SelfTestPos = .(380 * Look.Scale, 160 * Look.Scale);
					OpenNodeMenu(CurrentTab, .(0, 0), 0);
				}
			default:
				if (test.StartsWith("menusearch:"))
					mNodeMenu.SelfTestSetSearch(test.Substring(11)); // captures: a search typed into the open menu
				else if (test.StartsWith("select:") && CurrentTab != null && CurrentMethod != null)
				{
					// Captures: the first node whose kind word or subject contains the text, selected.
					let what = test.Substring(7);
					for (let n in CurrentMethod.Graph.Nodes)
						if (StringView(Treadle.Graph.NodeKinds.Word(n.Kind)) == what || n.Text.Contains(what))
						{
							OutlineSel = .None;
							CurrentTab.SelectOnly(n.Id);
							break;
						}
				}
				else if (test.StartsWith("member:") && Doc?.FindMember(test.Substring(7)) != null)
					SelectOutline(.Member, Doc.FindMember(test.Substring(7))); // captures: a member's page
				else if (SelfTestCaptureStep(test, ref finished)) {} // captures: SelfTestLambda.bf
				else if (SelfTestUXCapture(test)) {} // captures: SelfTestUX.bf
				else if (SelfTestUX2Capture(test)) {} // captures: SelfTestUX2.bf
				else if (SelfTestE3Capture(test, ref finished)) {} // captures: SelfTestEditor3.bf
				else if (SelfTestE4Capture(test, ref finished)) {} // captures: SelfTestEditor4.bf
				else if (SelfTestValidateCapture(test)) {} // captures: SelfTestValidate.bf
				else if (SelfTestNTCapture(test)) {} // captures: SelfTestNewType.bf
				else if (SelfTestDocCapture(test, ref finished)) {} // captures: SelfTestDocTabs.bf
				else if (SelfTestUpdateCapture(test)) {} // captures: Updates.bf
				else
					SelfTestCheck(false, scope $"unknown self test '{test}'");
			}
			if (finished)
			{
				delete mSelfTests[0];
				mSelfTests.RemoveAt(0);
				mSelfTestStep = 0;
				mSelfTestWait = 2;
			}
			else
				mSelfTestStep++;
		}

		bool SelfTestSmoke()
		{
			switch (mSelfTestStep)
			{
			case 0:
				SelfTestCheck(mDockBuilt, "dock layout built");
				SelfTestCheck(Language.Types != null && Language.Catalog != null && Language.Codec != null && Language.Rules != null, "language seams installed (null services)");
				SelfTestCheck(Language.Toolchain != null, "toolchain seam installed");
				// An empty project opens on an untitled document with one Sheet (EnsureStartSheet);
				// without a project, make one.
				if (CurrentMethod == null)
					NewUntitledDocument();
				SelfTestCheck(CurrentMethod != null && CurrentMethod.Doc.Sheets.Count == 1 && CurrentMethod.Doc.FilePath.IsEmpty, "untitled document with one Sheet in a tab");
				mSelfTestWait = 3; // the tab bar applies the selection a frame late
				return false;
			case 1:
				let mg = CurrentMethod;
				if (mg == null)
				{
					SelfTestCheck(false, "no Sheet to edit");
					return true;
				}
				let before = mg.Graph.Nodes.Count;
				BeginEdit();
				let n = NodeFactory.Branch(mg.Graph);
				n.X = 300;
				n.Y = 120;
				n.HasPos = true;
				CommitCurrent();
				SelfTestCheck(mg.Graph.Nodes.Count == before + 1, "Branch node added");
				return false;
			case 2:
				let mg = CurrentMethod;
				let count = mg.Graph.Nodes.Count;
				SelfTestCheck(EditDoc.CanUndo, "the edit is an undo step");
				EditDoc.Undo();
				SelfTestCheck(CurrentMethod.Graph.Nodes.Count == count - 1, "undo removes the node");
				EditDoc.Redo();
				SelfTestCheck(CurrentMethod.Graph.Nodes.Count == count, "redo restores it");
				return true;
			}
			return true;
		}
		/// The samples folder: TREADLE_SAMPLES, else TreadleCore/samples above the exe.
		static bool FindSamples(String outDir)
		{
			if (Environment.GetEnvironmentVariable("TREADLE_SAMPLES", outDir) case .Ok && Directory.Exists(outDir))
				return true;
			outDir.Clear();
			String dir = scope .();
			Environment.GetExecutableFilePath(dir);
			for (int up < 8)
			{
				String parent = scope .();
				if (Path.GetDirectoryPath(dir, parent) case .Err)
					break;
				dir.Set(parent);
				String probe = scope $"{dir}/TreadleCore/samples";
				if (Directory.Exists(probe))
				{
					outDir.Set(probe);
					return true;
				}
			}
			return false;
		}

		static bool ReadFile(StringView path, String outText) => File.ReadAllText(path, outText, true) case .Ok;

		bool SelfTestCodec()
		{
			String samples = scope .();
			if (!FindSamples(samples))
			{
				SelfTestCheck(false, "codec: the samples folder was not found (set TREADLE_SAMPLES)");
				return true;
			}
			String temp = scope .();
			if (!SelfTestTemp.Get(temp))
				temp.Set(samples);
			temp.AppendF("/treadle-selftest-{}", (int)Platform.BfpSystem_GetTimeStamp() & 0xFFFFFF);
			Directory.CreateDirectory(temp).IgnoreError();
			defer
			{
				for (let e in Directory.EnumerateFiles(temp))
					File.Delete(e.GetFilePath(.. scope String())).IgnoreError();
				Directory.Delete(temp).IgnoreError();
			}
			let codec = Language.Codec;
			SelfTestCheck(codec.Extension == ".treadle", "codec: the type file codec is installed (.treadle)");
			SelfTestSecurityCodec(); // SelfTestSecurity.bf
			SelfTestSecurityToolDirs();

			// 1. Each sample: load, save under another name, the bytes are the same (layout too).
			for (let name in StringView[?]("Player", "Program", "Pair"))
			{
				String src = scope $"{samples}/{name}.treadle";
				String original = scope .();
				if (!ReadFile(src, original))
				{
					SelfTestCheck(false, scope $"codec: {name}.treadle could not be read");
					continue;
				}
				TypeDocument doc = scope .(Language);
				let loaded = doc.Load(src) case .Ok && doc.LastError.IsEmpty;
				SelfTestCheck(loaded, scope $"codec: {name}.treadle loads ({doc.Sheets.Count} Sheets){(doc.LastError.IsEmpty ? "" : ": ")}{doc.LastError}");
				if (!loaded)
					continue;
				doc.FilePath.Set(scope $"{temp}/{name}.treadle");
				String why = scope .();
				let saved = doc.TrySave(why);
				String written = scope .();
				SelfTestCheck(saved && ReadFile(doc.FilePath, written) && written == original, scope $"codec: {name}.treadle saves byte for byte{(why.IsEmpty ? "" : ": ")}{why}");
				String layoutSrc = scope .();
				TypeDocument.LayoutPathOf(src, layoutSrc);
				if (File.Exists(layoutSrc))
				{
					String a = scope .();
					String b = scope .();
					SelfTestCheck(ReadFile(layoutSrc, a) && ReadFile(TypeDocument.LayoutPathOf(doc.FilePath, .. scope String()), b) && a == b, scope $"codec: {name}.treadle.layout saves byte for byte");
				}
				// The hand-ordered original (the spec's reading order) normalises to the canonical file.
				String ro = scope .();
				if (ReadFile(scope $"{samples}/reading-order/{name}.treadle", ro))
				{
					TypeDocument d2 = scope .(Language);
					String out2 = scope .();
					String err2 = scope .();
					SelfTestCheck(codec.Read(ro, d2, err2) && d2.WriteText(out2, err2) && out2 == original, scope $"codec: reading-order {name}.treadle normalises to the canonical file {err2}");
				}
			}

			// 2. Unknown records, unknown keys and comments survive a round trip in place.
			{
				String text = scope .();
				ReadFile(scope $"{samples}/Player.treadle", text);
				text.Replace("\tdoc \"Hit points; the player dies at 0.\"\n", "\tdoc \"Hit points; the player dies at 0.\"\n\tfuture-key 1 2\n");
				text.Replace("\nfield mName String\n", "\n# kept by hand\nfield mName String\n");
				text.Replace("node a3 Get this.mName\n", "node a3 Get this.mName\n\tglow 3\ngizmo zz9 Spin\n\tspeed \"fast\"\n");
				TypeDocument doc = scope .(Language);
				String why = scope .();
				let read = codec.Read(text, doc, why);
				String back = scope .();
				doc.WriteText(back, why);
				SelfTestCheck(read && back == text, scope $"codec: unknown records, keys and comments survive in place ({doc.UnknownCount} unknown) {why}");
				if (back != text)
					Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] wrote:\n{back}");
			}

			// 3. A malformed file: the error names the line and the node.
			{
				String text = scope .();
				ReadFile(scope $"{samples}/Pair.treadle", text);
				text.Replace("node b3 Get this.First\n", "node b3 Get this.First\n\tcomment \"never closed\n");
				int line = 0;
				for (let l in text.Split('\n'))
				{
					line++;
					if (l.StartsWith("\tcomment \"never"))
						break;
				}
				TypeDocument doc = scope .(Language);
				String why = scope .();
				let read = codec.Read(text, doc, why);
				SelfTestCheck(!read && why.StartsWith(scope $"line {line} (node b3): "), scope $"codec: a malformed file reports 'line {line} (node b3)': {why}");
				text.Set("# treadle 1\ntype T class\n\nfunction f1 Run\nsheet body\nnode a1 Entry\nwire a1.then zz.in\n");
				why.Clear();
				SelfTestCheck(!codec.Read(text, doc, why) && why.Contains("line 7") && why.Contains("'zz'"), scope $"codec: a wire to a missing node reports its line: {why}");
				text.Set("# treadle 9\ntype T class\n");
				why.Clear();
				SelfTestCheck(!codec.Read(text, doc, why) && why.StartsWith("line 1: saved by a newer version 9"), scope $"codec: a newer format version is refused: {why}");
			}

			// 4. The project file and the C import set read and write back unchanged.
			{
				String text = scope .();
				ReadFile(scope $"{samples}/Shooter.tproj", text);
				ProjectFile p = scope .();
				List<FormatError> errors = scope .();
				defer { ClearAndDeleteItems!(errors); }
				let ok = ProjectCodec.ReadProject(text, p, errors);
				String back = scope .();
				ProjectCodec.WriteProject(p, back);
				SelfTestCheck(ok && back == text && p.Configs.Count == 2, "codec: Shooter.tproj reads and writes back unchanged");
				text.Clear();
				ReadFile(scope $"{samples}/libc.cimport", text);
				CImportFile f = scope .();
				let ok2 = ProjectCodec.ReadCImport(text, f, errors);
				back.Clear();
				ProjectCodec.WriteCImport(f, back);
				SelfTestCheck(ok2 && back == text && f.Sets.Count == 1, "codec: libc.cimport reads and writes back unchanged");
			}

			// 4b. Every type, C declarations, project and C import file of the samples and the core
			//     library is canonical (what `--format` writes); reading-order/ is hand-ordered on purpose.
			for (let folder in StringView[?]("samples", "core"))
			{
				List<String> files = scope .();
				defer { ClearAndDeleteItems!(files); }
				Treadle.Format.Canonical.Collect(scope $"{samples}/../{folder}", files);
				int count = 0;
				String bad = scope .();
				for (let f in files)
				{
					if (f.Contains("/reading-order/"))
						continue;
					count++;
					String text = scope .();
					String canon = scope .();
					String why = scope .();
					if (!ReadFile(f, text) || !Treadle.Format.Canonical.Normalize(f, text, canon, why) || canon != text)
						bad.AppendF(" {}{}{}", f, why.IsEmpty ? "" : ": ", why);
				}
				SelfTestCheck(count > 0 && bad.IsEmpty, scope $"codec: the {count} files under {folder}/ are canonical{(bad.IsEmpty ? "" : ", not:")}{bad}");
			}

			// 5. Free text (Graph-Format.md 2): case labels and pin names with spaces, quotes, a
			// backslash and UTF-8; a project name and paths with spaces.
			{
				String text = scope .();
				text.Append("# treadle 1\ntype T class\n\nfunction f1 Run\nsheet body\nnode a1 Entry\nnode a2 Switch\n\tset on String\n");
				text.Append("\tcase \"two words\"\n\tcase \"say \\\"hi\\\"\"\n\tcase back\\slash\n\tcase caf\u{00E9}\n\tcase \"\\\"quoted\\\"\"\n\tcase \"\"\n");
				text.Append("node a3 Return\nwire a1.then a2.in\nwire \"a2.case:say \\\"hi\\\"\" a3.in\nwire \"a2.case:two words\" a3.in\n");
				TypeDocument doc = scope .(Language);
				String why = scope .();
				let read = codec.Read(text, doc, why);
				let sw = (read && !doc.Sheets.IsEmpty) ? doc.Sheets[0].Graph.FindNodeByKey("a2") : null;
				List<StringView> labels = scope .();
				if (sw != null)
					for (let s in sw.Settings)
						if (s.Key == "case")
							labels.Add(s.Value);
				let want = StringView[?]("two words", "say \"hi\"", "back\\slash", "caf\u{00E9}", "\"quoted\"", "");
				bool same = labels.Count == want.Count;
				for (int i < Math.Min(labels.Count, want.Count))
					same &= labels[i] == want[i];
				SelfTestCheck(same, scope $"codec: case labels with spaces, quotes, a backslash and UTF-8 read back as text ({labels.Count} labels) {why}");
				let p = sw?.FindOutput("case:say \"hi\"");
				SelfTestCheck(p != null && doc.Sheets[0].Graph.IsLinked(p) && sw.FindOutput("case:two words") != null, "codec: a quoted wire end names the case pin");
				String back = scope .();
				doc.WriteText(back, why);
				SelfTestCheck(back == text, "codec: free text writes back byte for byte (quoted only when needed)");
				if (back != text)
					Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] wrote:\n{back}");

				ProjectFile pf = scope .();
				pf.Name.Set("My Game \"2\"");
				pf.Sources.Add(new String("Source Files"));
				pf.Sources.Add(new String("Game"));
				String ptext = scope .();
				ProjectCodec.WriteProject(pf, ptext);
				ProjectFile pf2 = scope .();
				List<FormatError> errors = scope .();
				defer { ClearAndDeleteItems!(errors); }
				let ok = ProjectCodec.ReadProject(ptext, pf2, errors);
				SelfTestCheck(ok && pf2.Name == pf.Name && pf2.Sources.Count == 2 && pf2.Sources[0] == "Source Files" && pf2.Sources[1] == "Game"
					&& ptext.Contains("project \"My Game \\\"2\\\"\"\n") && ptext.Contains("source Game\n"), scope $"codec: a project name and a source folder with spaces round-trip ({pf2.Name})");
			}

			// 6. The editor habits' keys (Graph-Format.md 3.1, 3.2, 4): a field's `category`, a node's
			// `split <pin> <Type>` with wires and a literal on the field pins, a `group` with its `node`
			// lines, and the layout's group place and `collapsed`: read, written back byte for byte.
			{
				String text = scope .();
				text.Append("# treadle 1\ntype T class\n\nfield mPos Game.Vec2\n\tcategory \"Movement and Speed\"\n\nfunction f1 Run\nparam x int\nsheet body\n");
				text.Append("node a1 Entry\nnode a2 Set this.mPos\n\tsplit value Game.Vec2\n\tin value.Y 2\nnode a3 Get this.mPos\n\tsplit value Game.Vec2\n");
				text.Append("node a4 Call Console.WriteLine(int)\nnode a5 Return\n");
				text.Append("wire a1.then a2.in\nwire a1.x a2.value.X\nwire a2.then a4.in\nwire a3.value.Y a4.value\nwire a4.then a5.in\n");
				text.Append("group g1 \"Print Y\"\n\tnode a3\n\tnode a4\n");
				String layout = scope .();
				layout.Append("# treadle-layout 1\nsheet f1\n\tnode a1 0 0\n\tnode a2 260 0\n\tnode a3 260 200\n\tnode a4 520 0\n\tnode a5 780 0\n\tnode g1 400 120\n\tcollapsed g1\n");
				TypeDocument doc = scope .(Language);
				String why = scope .();
				let read = codec.Read(text, doc, why) && codec.ReadLayout(layout, doc, why);
				if (read)
					for (let s in doc.Sheets)
						if (s.IsBuilt)
							doc.ApplyLayout(s.Graph);
				let g = (read && !doc.Sheets.IsEmpty) ? doc.Sheets[0].Graph : null;
				let set = g?.FindNodeByKey("a2");
				let gr = g?.FindGroupByKey("g1");
				bool model = g != null && doc.FindMember("mPos")?.Category == "Movement and Speed" && set != null && SplitPins.IsSplit(set.FindInput("value")) &&
					g.DataSource(set.FindInput("value.X")) == g.Entry && set.FindInput("value.Y")?.Default == "2" &&
					gr != null && gr.Title == "Print Y" && gr.Nodes.Count == 2 && gr.X == 400 && gr.Y == 120;
				SelfTestCheck(model, scope $"codec: category, split and group read into the model {why}");
				String back = scope .();
				doc.WriteText(back, why);
				String backLayout = scope .();
				codec.WriteLayout(doc, backLayout, why);
				SelfTestCheck(back == text && backLayout == layout, "codec: category, split, group and the group's layout write back byte for byte");
				if (back != text)
					Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] wrote:\n{back}");
				if (backLayout != layout)
					Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] wrote layout:\n{backLayout}");
			}

			// 7. Version handling: format-history, a simulated bump, aliases, a newer file (SelfTestMigrate.bf).
			SelfTestMigrate(samples, temp);
			SelfTestSidecars(temp);
			return true;
		}

		// ------------------------------------------------------------------ editor

		String mSelfTestDir = new .() ~ delete _;
		int mSelfTestNodesBefore;

		static bool LoadsClean(TypeDocument doc, StringView path) => doc.Load(path) case .Ok && doc.LastError.IsEmpty;

		/// The node menu keys the `editor` case places, and the node kind each one makes.
		static (StringView key, NodeKind kind)[?] sEditorRows = .(
			("Flow Control\tBranch", .Branch),
			("Flow Control\tSequence", .Sequence),
			("Flow Control\tSwitch", .Switch),
			("Flow Control\tFor Loop", .For),
			("Flow Control\tFor Each Loop", .ForEach),
			("Flow Control\tWhile Loop", .While),
			("Flow Control\tDo While Loop", .DoWhile),
			("Flow Control\tBreak", .Break),
			("Flow Control\tContinue", .Continue),
			("Flow Control\tReturn", .Return),
			("Flow Control\tScope", .Scope),
			("Flow Control | Gates\tGate", .Gate),
			("Flow Control | Gates\tDo Once", .DoOnce),
			("Flow Control | Gates\tDo N", .DoN),
			("Flow Control | Gates\tFlip Flop", .FlipFlop),
			("Flow Control | Gates\tMulti Gate", .MultiGate),
			("Flow Control | Errors\tResult: match", .ResultMatch),
			("Flow Control | Errors\tTry", .Try),
			("Flow Control | Errors\tFatal", .Fatal),
			("Lifetime\tConstruct", .Construct),
			("Lifetime\tLocal", .Local),
			("Lifetime | Player\tConstruct Player (String)", .Construct),
			("Lifetime\tDelete", .Delete),
			("Lifetime\tDefer Delete", .DeferDelete),
			("Lifetime\tDefer", .Defer),
			("Math | Operators\t+  Add", .Operator),
			("Math\tMath Expression", .Math),
			("Utilities\tSelect", .Select),
			("Utilities | Collections\tGet [ ] (Index)", .Index),
			("Utilities | Casting\tCast To...", .Cast),
			("Utilities | Casting\tCast To... (checked)", .Cast),
			("Utilities | Literals\tLiteral int", .Literal),
			("Utilities | Functions as values\tBind Function", .Bind),
			("Utilities | Functions as values\tLambda", .Lambda),
			("Utilities | Functions as values\tInvoke", .Invoke),
			("Variables\tThis", .This),
			("Variables\tBase", .Base),
			("Variables | Player\tGet mHealth", .Get),
			("Variables | Player\tSet mName", .Set),
			("Variables | Inputs\tGet amount", .Get),
			("Variables\tLocal Variable", .Set),
			("Functions | Player\tDie", .Call),
			("Core | Pair\tMake Pair", .Make),
			("Core | Pair\tBreak Pair", .BreakStruct));

		/// The first node of `kind` in the graph whose subject is `subject` ("" = any).
		static Node FindNode(Graph g, NodeKind kind, StringView subject = "")
		{
			for (let n in g.Nodes)
				if (n.Kind == kind && (subject.IsEmpty || n.Text == subject))
					return n;
			return null;
		}

		bool SelfTestEditor()
		{
			if (mSelfTestStep >= 23 && mSelfTestStep < 23 + cUX2Phases)
			{
				// The second wave of node habits (SelfTestUX2.bf): one phase per frame.
				SelfTestUX2(mSelfTestStep - 23);
				mSelfTestWait = Math.Max(mSelfTestWait, 2);
				return false;
			}
			if (mSelfTestStep == 23 + cUX2Phases && !mValDone && !(mValDone = SelfTestValidateBefore()))
			{
				// When problems are shown: after Validate / Build only, stale after an edit (SelfTestValidate.bf).
				mSelfTestStep--;
				mSelfTestWait = Math.Max(mSelfTestWait, 2);
				return false;
			}
			if (mSelfTestStep == 23 + cUX2Phases && !mVecDone && !(mVecDone = SelfTestVectorBefore()))
			{
				// The vector types on the editor side (SelfTestVector.bf): one phase per frame.
				mSelfTestStep--;
				mSelfTestWait = Math.Max(mSelfTestWait, 2);
				return false;
			}
			if (mSelfTestStep == 23 + cUX2Phases && !mE4Done && !(mE4Done = SelfTestE4Before()))
			{
				// The fourth wave (SelfTestEditor4.bf): one phase per frame.
				mSelfTestStep--;
				mSelfTestWait = Math.Max(mSelfTestWait, 2);
				return false;
			}
			if (mSelfTestStep == 23 + cUX2Phases && !SelfTestE3Before())
			{
				// The third wave (SelfTestEditor3.bf): one phase per frame, then the save below.
				mSelfTestStep--;
				mSelfTestWait = Math.Max(mSelfTestWait, 2);
				return false;
			}
			switch (mSelfTestStep)
			{
			case 0:
				// A copy of the samples (Player is edited; Pair and Program feed the catalogue).
				String samples = scope .();
				if (!FindSamples(samples))
				{
					SelfTestCheck(false, "editor: the samples folder was not found (set TREADLE_SAMPLES)");
					return true;
				}
				String temp = scope .();
				if (!SelfTestTemp.Get(temp))
					temp.Set(samples);
				mSelfTestDir.Set(scope $"{temp}/treadle-editor-{(int)Platform.BfpSystem_GetTimeStamp() & 0xFFFFFF}");
				Directory.CreateDirectory(mSelfTestDir).IgnoreError();
				for (let name in StringView[?]("Player.treadle", "Pair.treadle", "Program.treadle"))
					File.Copy(scope $"{samples}/{name}", scope $"{mSelfTestDir}/{name}").IgnoreError();
				// The sample's layout lives in the samples' layout folder; the copy has no project, so it sits beside the file.
				File.Copy(TypeDocument.LayoutPathOf(scope $"{samples}/Player.treadle", .. scope String()), scope $"{mSelfTestDir}/Player.treadle.layout").IgnoreError();
				let doc = OpenFile(scope $"{mSelfTestDir}/Player.treadle");
				SelfTestCheck(doc != null && doc.Header.Name == "Player", "editor: Player.treadle opens");
				if (doc == null)
					return true;
				let sheet = doc.FindSheetByName("TakeDamage");
				if (sheet != null)
					OpenTab(sheet);
				mSelfTestWait = 3;
				return false;
			case 1:
				let mg = CurrentMethod;
				SelfTestCheck(mg != null && mg.Name == "TakeDamage", "editor: the TakeDamage Sheet is in front");
				if (mg == null)
					return true;
				RefreshProjectTypes();
				SelfTestCheck(ProjectTypes.Find("Core.Pair") != null && ProjectTypes.Find("Game.Player") != null, scope $"editor: the project's types are known ({ProjectTypes.Types.Count})");
				// A node of each kind, placed through the Node menu's rows (the catalogue API).
				mSelfTestNodesBefore = mg.Graph.Nodes.Count;
				mActionTab = CurrentTab;
				int placed = 0;
				float x = 0;
				for (let row in sEditorRows)
				{
					let item = mNodeMenu.ItemForKey(mg, .(x, 600), 0, row.key);
					if (item == null)
					{
						SelfTestCheck(false, scope $"editor: the Node menu offers '{row.key}'");
						continue;
					}
					let n = ExecuteAction(item);
					delete item;
					if (n == null || n.Kind != row.kind)
					{
						SelfTestCheck(false, scope $"editor: '{row.key}' makes a {row.kind} node");
						continue;
					}
					n.X = (placed % 8) * 280;
					n.Y = 500 + (placed / 8) * 260;
					placed++;
				}
				SelfTestCheck(placed == sEditorRows.Count, scope $"editor: a node of each kind placed from the Node menu ({placed} of {sEditorRows.Count})");
				mSelfTestWait = 2;
				return false;
			case 2:
				// Lambda Sheets (LambdaSheets.bf): the placed Lambda node got its Sheet at the commit;
				// deleting the node removes the Sheet, undo brings both back.
				{
					let lmg = CurrentMethod;
					let doc = EditDoc;
					let lambda = FindNode(lmg.Graph, .Lambda);
					let ls = (lambda != null) ? FindLambdaSheet(doc, lmg, lambda.Key) : null;
					SelfTestCheck(ls != null && LambdaOwner(doc, ls) == lmg && ls.Key.StartsWith("lambda:"), "editor: placing a Lambda node makes its Sheet (lambda:<node>), owned by TakeDamage");
					if (ls != null)
					{
						String lkey = scope .(lambda.Key);
						int sheets = doc.Sheets.Count;
						doc.PushUndo();
						lmg.Graph.RemoveNode(lambda);
						SyncLambdaSheets(doc);
						bool gone = doc.Sheets.Count == sheets - 1 && FindLambdaSheet(doc, lmg, lkey) == null;
						doc.Undo();
						let back = CurrentMethod;
						bool restored = back != null && FindNode(back.Graph, .Lambda) != null && FindLambdaSheet(doc, back, lkey) != null && doc.Sheets.Count == sheets;
						SelfTestCheck(gone && restored, scope $"editor: deleting the Lambda node removes its Sheet ({gone}); undo brings both back ({restored})");
					}
				}
				let mg = CurrentMethod;
				let g = mg.Graph;
				SelfTestCheck(g.Nodes.Count >= mSelfTestNodesBefore + sEditorRows.Count, scope $"editor: the nodes are in the Sheet after the commit ({g.Nodes.Count})");
				SelfTestCheck(EditDoc.CanUndo, "editor: placing nodes is undoable");
				// Typed pins from the catalogue: Make Pair has its fields, the checked Cast its flow outputs.
				let make = FindNode(g, .Make);
				SelfTestCheck(make != null && make.FindInput("First") != null && make.FindInput("Second") != null, "editor: Make Pair has a pin per field");
				Node checkedCast = null;
				for (let n in g.Nodes)
					if (n.Kind == .Cast && n.HasSetting("checked"))
						checkedCast = n;
				SelfTestCheck(checkedCast != null && checkedCast.ExecIn != null && checkedCast.FindOutput("then") != null && checkedCast.FindOutput("failed") != null, "editor: the checked Cast has Succeeded / Failed flow pins");
				let ctor = FindNode(g, .Construct, "Game.Player");
				SelfTestCheck(ctor != null && ctor.FindInput("name") != null && ctor.FindOutput("object")?.TypeName == "Game.Player", "editor: Construct Player has the constructor's input and a Player object");
				// Wire two pins: Get mHealth (int) into the + operator.
				Node getHealth = null;
				for (let n in g.Nodes)
					if (n.Kind == .Get && n.Text == "this.mHealth" && !g.IsLinked(n.Result))
						getHealth = n;
				Node add = null;
				for (let n in g.Nodes)
					if (n.Kind == .Operator && n.Text == "+")
						add = n;
				String why = scope .();
				bool wired = getHealth != null && add != null && mGraphPanel.TryDropWire(mg, getHealth.Result, add.FindInput("a"), why);
				SelfTestCheck(wired, scope $"editor: Get mHealth wires into + ({why})");
				// Refuse an incompatible wire: a String into a Branch's Condition.
				Node getName = null;
				for (let n in g.Nodes)
					if (n.Kind == .Get && n.Text == "this.mName")
						getName = n;
				if (getName == null)
				{
					BeginEdit();
					getName = NodeFactory.Get(g, "mName", "String");
					getName.X = 0;
					getName.Y = 1600;
					getName.HasPos = true;
					CommitCurrent();
				}
				let branch = FindNode(g, .Branch);
				int links = g.Links.Count;
				why.Clear();
				bool refused = !mGraphPanel.TryDropWire(mg, getName.Result, branch.FindInput("condition"), why);
				SelfTestCheck(refused && !why.IsEmpty && g.Links.Count == links, scope $"editor: a String into a bool Condition is refused: {why}");
				mSelfTestWait = 2;
				return false;
			case 3:
				let mg = CurrentMethod;
				let g = mg.Graph;
				Node getHealth = null;
				for (let n in g.Nodes)
					if (n.Kind == .Get && n.Text == "this.mHealth")
						getHealth = n;
				SelfTestCheck(g.IsLinked(getHealth?.Result), "editor: the wire is in the graph after the commit");
				// Drag-to-menu: the rows offered from an int output can all take an int.
				let ctx = getHealth.Result;
				List<NodeItem> rows = scope .();
				defer { ClearAndDeleteItems!(rows); }
				mNodeMenu.ListFor(mg, ctx.Id, "", rows);
				Graph scratch = scope .();
				scratch.Language = Language;
				scratch.Member = mg.Member;
				scratch.SelfType.Set(g.SelfType);
				int bad = 0;
				String badNames = scope .();
				bool hasAdd = false;
				bool hasSet = false;
				bool hasBranch = false;
				bool hasDelete = false;
				for (let item in rows)
				{
					if (item.Label.StartsWith("+  Add"))
						hasAdd = true;
					if (item.Label == "Set mHealth")
						hasSet = true;
					if (item.Label == "Branch")
						hasBranch = true;
					if (item.Label == "Delete")
						hasDelete = true;
					if (item.Kind == .Reroute || item.Kind == .LocalVar)
						continue;
					let n = mNodeMenu.CreateNode(mg, scratch, item, NodeMenu.WantFlow(item, ctx), true);
					bool fits = false;
					if (n != null)
						for (let p in n.Inputs)
							if (Graph.CanConnectTyped(Language, ctx, p))
								fits = true;
					if (!fits)
					{
						bad++;
						badNames.AppendF(" '{}'", item.Label);
					}
					while (!scratch.Nodes.IsEmpty)
						scratch.RemoveNode(scratch.Nodes.Back);
				}
				SelfTestCheck(!rows.IsEmpty && bad == 0, scope $"editor: the {rows.Count} rows offered from an int output can all take the wire{badNames}");
				{
					String labels = scope .();
					for (let item in rows)
						labels.AppendF("{}{}", labels.IsEmpty ? "" : ", ", item.Label);
					Notify.Log(.Verbose, "SelfTest", scope $"[SELFTEST] rows from an int output: {labels}");
				}
				SelfTestCheck(hasAdd && hasSet && !hasBranch && !hasDelete, "editor: from an int: + and Set mHealth are offered, Branch and Delete are not");
				// From a flow output: only rows with a flow input.
				ClearAndDeleteItems!(rows);
				let entryThen = g.Entry.Then;
				mNodeMenu.ListFor(mg, entryThen.Id, "", rows);
				bad = 0;
				for (let item in rows)
					if (item.Kind != .Reroute && !mNodeMenu.RowFits(item, entryThen))
						bad++;
				bool flowOnly = true;
				for (let item in rows)
					if (item.Label == "Select" || item.Label.StartsWith("+  Add"))
						flowOnly = false;
				SelfTestCheck(!rows.IsEmpty && bad == 0 && flowOnly, scope $"editor: the {rows.Count} rows offered from a flow output are flow nodes");
				return false;
			case 4:
				// Type Settings: a field and a function, each one undo step; the Outline lists them.
				int members = Doc.Members.Count;
				let field = AddField("Armor", "int");
				let fn = AddFunctionMember("Heal");
				SelfTestCheck(field != null && fn != null && Doc.Members.Count == members + 2 && Doc.FindSheetByName("Heal") != null, "editor: Type Settings adds the field Armor and the function Heal");
				if (fn != null)
					AddParam(fn, false);
				SelfTestCheck(fn != null && fn.Params.Count == 1 && Doc.FindSheetByName("Heal").Graph.Entry.FindOutput(fn.Params[0].Name) != null, "editor: an input of Heal shows on its Entry");
				Doc.Undo();
				SelfTestCheck(Doc.FindMember("Heal")?.Params.Count == 0, "editor: undo removes the input");
				Doc.Undo();
				SelfTestCheck(Doc.FindMember("Heal") == null && Doc.FindSheetByName("Heal") == null, "editor: undo removes the function and its Sheet");
				Doc.Redo();
				Doc.Redo();
				SelfTestCheck(Doc.FindMember("Heal") != null && Doc.FindSheetByName("Heal") != null && Doc.FindMember("Armor") != null && Doc.FindMember("Heal").Params.Count == 1, "editor: redo brings them back");
				let takeDamage = Doc.FindSheetByName("TakeDamage");
				if (takeDamage != null)
					OpenTab(takeDamage);
				mSelfTestWait = 3; // the Outline lists them on the next frames
				return false;
			case 5:
				bool armor = false;
				bool heal = false;
				for (let m in mMembers)
				{
					if (m.Name == "Armor" && m.MemberKind == .Variable)
						armor = true;
					if (m.Name == "Heal" && m.MemberKind == .Function)
						heal = true;
				}
				SelfTestCheck(armor && heal, "editor: the Outline lists Armor under VARIABLES and Heal under FUNCTIONS");
				// The new function's Call goes through the catalogue too.
				let mg = CurrentMethod;
				mActionTab = CurrentTab;
				let item = mNodeMenu.ItemForKey(mg, .(0, 1400), 0, "Functions | Player\tHeal");
				let call = (item != null) ? ExecuteAction(item) : null;
				delete item;
				SelfTestCheck(call != null && call.Text == "this.Heal(int)" && call.FindInput("input") != null, scope $"editor: the Node menu offers a Call of Heal ({(call != null) ? call.Text : "none"})");
				mSelfTestWait = 2;
				return false;
			case 6:
				// Problems to nodes: Validate reports the unwired inputs on their pins; a Problems row
				// opens the Sheet on its node.
				Validate(true);
				Diagnostic onPin = null;
				if (mValidate != null)
					for (let d in mValidate.Messages)
						if (!d.PinName.IsEmpty && d.MethodKey == CurrentMethod.Key)
							onPin = d;
				SelfTestCheck(onPin != null, "editor: Validate reports a problem on a pin");
				if (onPin != null)
				{
					let node = DiagnosticMap.Resolve(CurrentMethod, onPin);
					let pin = (node != null) ? (node.FindInput(onPin.PinName) ?? node.FindOutput(onPin.PinName)) : null;
					SelfTestCheck(pin != null && CurrentMethod.Graph.FindPinProblem(pin, ?) != null, scope $"editor: the problem is on the pin '{onPin.PinName}' of its node");
					CurrentTab.ClearSelection();
					JumpToDiagnostic(onPin);
					SelfTestCheck(node != null && CurrentTab.SelectedNodes.Count == 1 && CurrentTab.SelectedNodes[0] == node.Id, "editor: a Problems row selects its node");
				}
				SelfTestEditorPolish();
				mSelfTestWait = 3; // the strips are laid out on the next frames
				return false;
			case 7:
				SelfTestEditorStrip();
				SelfTestWave2(0);
				mSelfTestWait = 2;
				return false;
			case 8:
				SelfTestWave2(1);
				mSelfTestWait = 2;
				return false;
			case 9:
				SelfTestWave2(2);
				mSelfTestWait = 2;
				return false;
			case 10:
				SelfTestLambdaUI();
				mSelfTestWait = 2;
				return false;
			case 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22:
				// Node-graph habits (SelfTestUX.bf): one phase per frame, a commit between them.
				SelfTestUX(mSelfTestStep - 11);
				mSelfTestWait = Math.Max(mSelfTestWait, 2);
				return false;
			case 23 + cUX2Phases:
				// Save, read the file back: the same model (the type file as the codec writes it).
				String why = scope .();
				let saved = Doc.TrySave(why);
				SelfTestCheck(saved, scope $"editor: the document saves {why}");
				String ours = scope .();
				Doc.WriteText(ours, why);
				TypeDocument reread = scope .(Language);
				let read = LoadsClean(reread, Doc.FilePath);
				String theirs = scope .();
				reread.WriteText(theirs, why);
				SelfTestCheck(read && ours == theirs && reread.Members.Count == Doc.Members.Count && reread.Sheets.Count == Doc.Sheets.Count, scope $"editor: reading the saved file gives the same model ({reread.Members.Count} members, {reread.Sheets.Count} Sheets)");
				if (ours != theirs)
					Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] in memory:\n{ours}\n[SELFTEST] read back:\n{theirs}");
				let heal = reread.FindMember("Heal");
				SelfTestCheck(heal != null && heal.Params.Count == 1 && reread.FindMember("Armor")?.Type?.ToString(.. scope String()) == "int", "editor: the field and the function with its input are in the file");
				// The copies go; the document stays open until quit.
				for (let e in Directory.EnumerateFiles(mSelfTestDir))
					File.Delete(e.GetFilePath(.. scope String())).IgnoreError();
				Directory.Delete(mSelfTestDir).IgnoreError();
				return false;
			case 24 + cUX2Phases:
				// The type context (SelfTestDocTabs.bf): one phase per frame, before the third wave.
				if (!mDocTabsDone && !(mDocTabsDone = SelfTestDocTabs()))
				{
					mSelfTestStep--;
					mSelfTestWait = Math.Max(mSelfTestWait, 2);
					return false;
				}
				// The third wave on a project of its own (SelfTestEditor3.bf): one phase per frame.
				if (!SelfTestE3After())
				{
					mSelfTestStep--;
					return false;
				}
				return false;
			case 25 + cUX2Phases:
				// Help > Report a Problem (ReportProblem.bf): one phase per frame.
				if (!SelfTestReport())
				{
					mSelfTestStep--;
					return false;
				}
				return true;
			}
			return true;
		}

		/// The node given a long error by SelfTestEditorPolish (its strip is read a few frames later).
		int32 mSelfTestStripNode;
		const String cSelfTestLongError = "This is a deliberately long problem message that cannot fit on one line of a node, so the strip has to shorten it";

		/// Editor polish: Alt-click breaks a wire, the Node menu's Reroute on an empty drop from a flow
		/// output, the bottom dock's default height, New Project's files; and a long error put on a
		/// node for SelfTestEditorStrip.
		void SelfTestEditorPolish()
		{
			let mg = CurrentMethod;
			let tab = CurrentTab;
			let g = mg.Graph;
			// Alt-click on a wired pin breaks its wires, one undo step.
			Node add = null;
			for (let n in g.Nodes)
				if (n.Kind == .Operator && n.Text == "+" && g.IsLinked(n.FindInput("a")))
					add = n;
			let pinA = add?.FindInput("a");
			int links = g.Links.Count;
			bool broke = pinA != null && mGraphPanel.BreakPinLinks(g, pinA);
			SelfTestCheck(broke && !g.IsLinked(pinA) && g.Links.Count == links - 1, "editor: Alt-click on a pin breaks its wire");
			if (broke)
			{
				EditDoc.Undo();
				let back = CurrentMethod.Graph;
				SelfTestCheck(back.Links.Count == links, "editor: undo restores the broken wire");
				EditDoc.Redo();
			}
			// Dragged from a wired flow output, dropped on empty canvas, nothing typed: Enter makes a Reroute knot.
			let g2 = CurrentMethod.Graph;
			Pin flowOut = null;
			for (let n in g2.Nodes)
				for (let p in n.Outputs)
					if (flowOut == null && p.Kind == .Flow && g2.IsLinked(p))
						flowOut = p;
			if (flowOut == null)
				SelfTestCheck(false, "editor: a wired flow output to drop from");
			else
			{
				mActionTab = tab;
				int knots = 0;
				for (let r in tab.Doc.Reroutes)
					knots += r.Points.Count;
				let item = mNodeMenu.DefaultRowFor(CurrentMethod, .(flowOut.Owner.X + 160, flowOut.Owner.Y + 220), flowOut.Id, "");
				SelfTestCheck(item != null && item.Kind == .Reroute, scope $"editor: an empty drop from a flow output offers a Reroute first ({(item != null) ? item.Label : "nothing"})");
				if (item != null && item.Kind == .Reroute)
					ExecuteAction(item);
				delete item;
				int after = 0;
				for (let r in tab.Doc.Reroutes)
					after += r.Points.Count;
				SelfTestCheck(after == knots + 1, scope $"editor: Enter on the empty drop puts a Reroute knot on the wire ({knots} -> {after})");
				let typed = mNodeMenu.DefaultRowFor(CurrentMethod, .(0, 0), flowOut.Id, "Branch");
				SelfTestCheck(typed != null && typed.Kind != .Reroute, "editor: with a search typed, Enter places the best match instead");
				delete typed;
			}
			// The bottom dock: 22 % of the window by default (at least a few log rows), else the user's height.
			let viewport = ImGui.Gui.igGetMainViewport();
			float expected = (mBottomDockH > 0) ? mBottomDockH * Look.Scale : Math.Max(cBottomDockDefault * viewport.Size.y, 150 * Look.Scale);
			float seen = BottomDockHeight;
			SelfTestCheck(seen > 0 && Math.Abs(seen - expected) <= viewport.Size.y * 0.04f + 4, scope $"editor: the bottom dock is {seen:0} px high (expected about {expected:0} of {viewport.Size.y:0})");
			float at800 = cBottomDockDefault * 800;
			SelfTestCheck(at800 >= 160 && at800 <= 190 && mBottomDockNode != 0, scope $"editor: the default bottom dock at 800 px is {at800:0} px");
			// New Project: a .tproj the codec and the front end read, its first type with Main.
			String temp = scope .();
			if (!SelfTestTemp.Get(temp))
				temp.Set(mSelfTestDir);
			String dir = scope $"{temp}/treadle-newproject-{(int)Platform.BfpSystem_GetTimeStamp() & 0xFFFFFF}";
			Directory.CreateDirectory(dir).IgnoreError();
			String typePath = scope .();
			String why = scope .();
			bool made = CreateProjectFiles(dir, "Polish Test", typePath, why);
			SelfTestCheck(made && File.Exists(scope $"{dir}/Polish Test.tproj") && File.Exists(typePath), scope $"editor: New Project writes Polish Test.tproj and {typePath} {why}");
			if (made)
			{
				String text = scope .();
				File.ReadAllText(scope $"{dir}/Polish Test.tproj", text, true).IgnoreError();
				ProjectFile p = scope .();
				List<FormatError> errors = scope .();
				defer { ClearAndDeleteItems!(errors); }
				bool read = ProjectCodec.ReadProject(text, p, errors);
				SelfTestCheck(read && p.Name == "Polish Test" && text.Contains("project \"Polish Test\"\n") && p.Entry?.ToString(.. scope String()) == "Polish_Test.Program" && p.FindConfig("Debug") != null && p.FindConfig("Release") != null && p.Sources.Count == 1,
					scope $"editor: the new .tproj reads back (the typed name quoted, entry, Debug / Release, source)");
				TypeDocument first = scope .(Language);
				SelfTestCheck(LoadsClean(first, typePath) && first.Header.Name == "Program" && first.Header.Namespace == "Polish_Test" && first.FindMember("Main")?.Static == true,
					"editor: the new project's Program type loads with a static Main");
				let project = Treadle.Compiler.ProjectLoader.ReadProject(scope $"{dir}/Polish Test.tproj");
				if (project == null)
					SelfTestCheck(false, "editor: the front end reads the new project file");
				else
				{
					let c = Treadle.Compiler.ProjectLoader.Make(dir, null, null, project);
					c.Run();
					let errorCount = c.Diags.ErrorCount;
					delete c;
					delete project;
					SelfTestCheck(errorCount == 0, scope $"editor: the new project compiles with no errors ({errorCount})");
				}
			}
			for (let e in Directory.EnumerateFiles(scope $"{dir}/Source"))
				File.Delete(e.GetFilePath(.. scope String())).IgnoreError();
			Directory.Delete(scope $"{dir}/Source").IgnoreError();
			for (let e in Directory.EnumerateFiles(dir))
				File.Delete(e.GetFilePath(.. scope String())).IgnoreError();
			Directory.Delete(dir).IgnoreError();
			// A long error on a call node with a header: its strip is checked on a later frame.
			let g3 = CurrentMethod.Graph;
			mSelfTestStripNode = 0;
			for (let n in g3.Nodes)
				if (mSelfTestStripNode == 0 && n.Kind == .Call && n.ExecIn != null)
					mSelfTestStripNode = n.Id;
			mGraphPanel.SelfTestErrorNode = mSelfTestStripNode;
			mGraphPanel.SelfTestError.Set(cSelfTestLongError);
			SelfTestCheck(mSelfTestStripNode != 0, "editor: a call node to put a long problem on");
		}

		int32 mSelfTestGateNode;

		/// Polish wave 2: the State Field row of a Gate, overloads, the Node menu's word search.
		void SelfTestWave2(int phase)
		{
			let mg = CurrentMethod;
			if (mg == null || CurrentTab == null)
			{
				SelfTestCheck(false, "editor: a Sheet for the wave-2 checks");
				return;
			}
			let g = mg.Graph;
			switch (phase)
			{
			case 0:
				// Select the Gate placed from the Node menu; Properties draws its rows on the next frame.
				let gate = FindNode(g, .Gate);
				mSelfTestGateNode = (gate != null) ? gate.Id : 0;
				OutlineSel = .None;
				if (gate != null)
					CurrentTab.SelectOnly(gate.Id);
				mStateRowShown.Clear();
			case 1:
				let gate = g.FindNode(mSelfTestGateNode);
				let hidden = (gate != null) ? scope:: $"State Field: __gate_{gate.Key}  (hidden)" : "";
				SelfTestCheck(gate != null && mStateRowShown == hidden, scope $"editor: a Gate's Properties show its State Field row ({mStateRowShown})");
				let doN = FindNode(g, .DoN);
				List<String> names = scope .();
				List<String> labels = scope .();
				List<String> disabled = scope .();
				defer { ClearAndDeleteItems!(names); ClearAndDeleteItems!(labels); ClearAndDeleteItems!(disabled); }
				if (doN != null)
					StateFieldChoices(mg, doN, names, labels, disabled);
				bool health = false;
				for (let n in names)
					health |= n == "mHealth";
				SelfTestCheck(health && !names.Contains("mName"), scope $"editor: a Do N's State Field offers the type's int fields ({names.Count})");
				SelfTestCheck(GraphPanel.ZoomReadoutAlpha(0.2f) == 1 && GraphPanel.ZoomReadoutAlpha(1.4f) == 1 && GraphPanel.ZoomReadoutAlpha(1.9f) == 0,
					"editor: the zoom readout shows for 1.5 s after a zoom change, then fades out");
			case 2:
				SelfTestOverloads(mg);
				SelfTestMenuSearch(mg);
			default:
			}
		}

		/// A Node menu row whose label starts with `label`, found by searching `search` (a copy, or null).
		NodeItem SelfTestRow(Sheet mg, StringView search, StringView label)
		{
			List<NodeItem> rows = scope .();
			defer { ClearAndDeleteItems!(rows); }
			mNodeMenu.ListFor(mg, 0, search, rows);
			for (let r in rows)
				if (r.Label.StartsWith(label))
				{
					NodeItem copy = new .();
					copy.CopyFrom(r);
					return copy;
				}
			return null;
		}

		/// Overloads: the menu lists WriteLine once per overload; switching a Call to the other
		/// overload and a Construct String to the other constructor keeps the wires that still fit.
		void SelfTestOverloads(Sheet mg)
		{
			let g = mg.Graph;
			BeginEdit();
			let rowText = SelfTestRow(mg, "WriteLine", "WriteLine (StringView");
			let rowInt = SelfTestRow(mg, "WriteLine", "WriteLine (int");
			defer { delete rowText; delete rowInt; }
			SelfTestCheck(rowText != null && rowInt != null, "editor: the Node menu lists each WriteLine overload as its own row with its parameters");
			let call = (rowText != null) ? mNodeMenu.CreateNode(mg, g, rowText, true, false) : null;
			SelfTestCheck(call != null && call.Text.EndsWith("WriteLine(StringView)"), scope $"editor: a Call made from an overload's row names its parameter types ({(call != null) ? call.Text : "none"})");
			if (call == null)
			{
				CommitCurrent();
				return;
			}
			let branch = NodeFactory.Branch(g);
			g.Connect(branch.FindOutput("true"), call.ExecIn);
			List<NodeMenu.OverloadChoice> choices = scope .();
			defer { ClearAndDeleteItems!(choices); }
			let cur = mNodeMenu.OverloadsOf(mg, call, choices);
			int other = -1;
			for (let c in choices)
				if (c.Signature == "(int)")
					other = @c.Index;
			SelfTestCheck(choices.Count >= 2 && cur >= 0 && choices[cur].Signature == "(StringView)" && other >= 0,
				scope $"editor: a WriteLine Call's Overload row offers every signature, (StringView) and (int) among them ({choices.Count}, current {cur})");
			if (other >= 0)
				mNodeMenu.SwitchOverload(mg, call, choices[other]);
			SelfTestCheck(call.Text.EndsWith("WriteLine(int)") && call.FindInput("value") != null && call.FindInput("text") == null && g.IsLinked(call.ExecIn),
				scope $"editor: switching the overload rebuilds the pins and keeps the fitting flow wire ({call.Text})");

			// A Construct String with its object wired into Set mName: the other constructor keeps the wire.
			let rowCtor = SelfTestRow(mg, "Construct String", "Construct String");
			defer { delete rowCtor; }
			Node ctor = null;
			if (rowCtor != null)
				ctor = mNodeMenu.CreateNode(mg, g, rowCtor, true, false);
			let setName = NodeFactory.Set(g, "mName", "String");
			if (ctor != null)
				g.Connect(ctor.FindOutput("object"), setName.FindInput("value"));
			ClearAndDeleteItems!(choices);
			let curCtor = (ctor != null) ? mNodeMenu.OverloadsOf(mg, ctor, choices) : -1;
			int pick = -1;
			for (let c in choices)
				if (@c.Index != curCtor && c.Signature != "()")
					pick = @c.Index;
			if (pick >= 0)
				mNodeMenu.SwitchOverload(mg, ctor, choices[pick]);
			SelfTestCheck(ctor != null && choices.Count >= 2 && pick >= 0 && ctor.HasSetting("ctor") && g.IsLinked(setName.FindInput("value")) && g.IsLinked(ctor.FindOutput("object")),
				scope $"editor: switching a Construct String's constructor keeps its object wire ({choices.Count} constructors, now {(ctor != null) ? ctor.GetSetting("ctor") : ""})");
			CommitCurrent();
		}

		/// The Node menu's word search: "make pair" finds Make Pair first, as do loose spellings.
		void SelfTestMenuSearch(Sheet mg)
		{
			for (let q in StringView[?]("make pair", "pair make", "mk pair"))
			{
				List<NodeItem> rows = scope .();
				defer { ClearAndDeleteItems!(rows); }
				mNodeMenu.ListFor(mg, 0, q, rows);
				StringView first = rows.IsEmpty ? "nothing" : (StringView)rows[0].Label;
				SelfTestCheck(first.StartsWith("Make Pair"), scope $"editor: the Node menu's search for '{q}' finds Make Pair first ({first})");
			}
			// Verb + member of another type's field, the name as one word, parameter types and the
			// Receiver's type name are searchable, in any word order.
			for (let q in StringView[?]("set first", "first set", "get second", "writeline int", "int writeline", "pair swap", "swap pair", "set mhealth"))
			{
				List<NodeItem> rows = scope .();
				defer { ClearAndDeleteItems!(rows); }
				mNodeMenu.ListFor(mg, 0, q, rows);
				StringView want = q.Contains("first") ? "Set First" : (q.Contains("second") ? "Second" : (q.Contains("writeline") ? "WriteLine (int" : (q.Contains("swap") ? "Swap" : "Set mHealth")));
				StringView first = rows.IsEmpty ? "nothing" : (StringView)rows[0].Label;
				SelfTestCheck(first.StartsWith(want), scope $"editor: the Node menu's search for '{q}' finds {want} first ({first})");
			}
			// Groups: rows are shown under Flow, Variables, Functions, Types, C, Math, Comparison, Logic, Strings.
			{
				List<NodeItem> rows = scope .();
				defer { ClearAndDeleteItems!(rows); }
				mNodeMenu.ListFor(mg, 0, "", rows);
				int checkedRows = 0;
				bool ok = true;
				for (let r in rows)
				{
					String path = scope .();
					NodeMenu.DisplayGroup(r, path);
					StringView want = default;
					if (r.Label == "Branch" || r.Label == "Gate")
						want = "Flow";
					else if (r.Label.StartsWith("==") || r.Label.StartsWith("<="))
						want = "Comparison";
					else if (r.Label.StartsWith("&&"))
						want = "Logic";
					else if (r.Label.StartsWith("+  Add"))
						want = "Math";
					else if (r.Label == "Get mHealth")
						want = "Variables";
					else if (r.Label == "Die")
						want = "Functions";
					else if (r.Label.StartsWith("Construct Player"))
						want = "Types";
					if (want.IsEmpty)
						continue;
					checkedRows++;
					if (!path.StartsWith(want))
					{
						ok = false;
						Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] {r.Label} is under {path}, not {want}");
					}
				}
				SelfTestCheck(ok && checkedRows >= 8, scope $"editor: the Node menu groups its rows under Flow, Variables, Functions, Types, Math, Comparison and Logic ({checkedRows} checked)");
			}
			// Recently used rows come first; a pin's context line names the node and the pin.
			{
				mNodeMenu.Prefs.Used("Flow Control\tBranch");
				List<NodeItem> rows = scope .();
				defer { ClearAndDeleteItems!(rows); }
				mNodeMenu.ListFor(mg, 0, "", rows);
				ClearAndDeleteItems!(rows);
				mNodeMenu.SelfTestRows("", rows);
				SelfTestCheck(!rows.IsEmpty && rows[0].Category == "Recently Used" && rows[0].Label == "Branch",
					scope $"editor: the Node menu lists Recently Used first ({(rows.IsEmpty ? "nothing" : (StringView)rows[0].Category)}: {(rows.IsEmpty ? "" : (StringView)rows[0].Label)})");
				Pin intOut = null;
				for (let n in mg.Graph.Nodes)
					for (let p in n.Outputs)
						if (intOut == null && p.Kind == .Value && p.TypeName == "int" && n.Kind == .Get)
							intOut = p;
				ClearAndDeleteItems!(rows);
				if (intOut != null)
					mNodeMenu.ListFor(mg, intOut.Id, "", rows);
				SelfTestCheck(intOut != null && mNodeMenu.ContextLine.StartsWith("From ") && mNodeMenu.ContextLine.EndsWith("(int)"),
					scope $"editor: dragged from a pin, the Node menu's context line names it ({mNodeMenu.ContextLine})");
			}
		}

		/// The long error's strip: one line, shortened with "...", inside the node.
		void SelfTestEditorStrip()
		{
			String line = scope .();
			float textW = 0;
			float stripW = 0;
			float stripH = 0;
			bool has = mSelfTestStripNode != 0 && mGraphPanel.ProblemStripOf(mSelfTestStripNode, line, out textW, out stripW, out stripH);
			SelfTestCheck(has && !line.Contains('\n') && Math.Abs(stripH - mGraphPanel.OneLineStripH) < 0.5f, scope $"editor: a node's problem strip is one line ('{line}', {stripH:0.0} high)");
			SelfTestCheck(has && line.EndsWith("...") && line.Length < cSelfTestLongError.Length && textW <= stripW, scope $"editor: a long problem is shortened to the strip ({textW:0} of {stripW:0})");
			mGraphPanel.SelfTestErrorNode = 0;
		}

		/// Opens the Node menu dragged off the Get mHealth value (or the Entry's flow output) and
		/// leaves it open: what the pixel pass captures.
		bool SelfTestMenu()
		{
			let mg = CurrentMethod;
			let tab = CurrentTab;
			if (mg == null || tab == null)
				return true;
			Pin ctx = null;
			for (let n in mg.Graph.Nodes)
				if (n.Kind == .Get && n.Text == "this.mHealth")
					ctx = n.Result;
			if (ctx == null)
				ctx = mg.Graph.Entry.Then;
			mNodeMenu.SelfTestPos = .(380 * Look.Scale, 160 * Look.Scale);
			OpenNodeMenu(tab, .(ctx.Owner.X + 200, ctx.Owner.Y), ctx.Id);
			return true;
		}

		/// Captures: a Sheet with one node of each family, wired, with a value read by two flow
		/// nodes ("evaluated 2x"), an input with a problem, a collapsed node and a comment box, at
		/// zoom 1 (what the pixel pass looks at). Needs the `editor` case before it.
		bool SelfTestShowcase()
		{
			switch (mSelfTestStep)
			{
			case 0:
				let fnMember = AddFunctionMember("Showcase");
				if (fnMember == null)
					return true;
				let mg = CurrentMethod;
				let g = mg.Graph;
				BeginEdit();
				Node At(Node n, float x, float y)
				{
					n.X = x;
					n.Y = y;
					n.HasPos = true;
					return n;
				}
				let entry = At(g.Entry, 0, 0);
				let ctor = At(NodeFactory.Construct(g, "Game.Player", false, false, StringView[?]("name"), StringView[?]("String")), 220, 0);
				ctor.FindInput("name").Default.Set("\"Hero\"");
				let local = At(NodeFactory.Construct(g, "String", true), 520, 0);
				let cast = At(NodeFactory.Cast(g, "Game.Player", true), 800, 0);
				let branch = At(NodeFactory.Branch(g), 1080, 0);
				let getHealth = At(NodeFactory.Get(g, "mHealth", "int"), 560, 250);
				let gt = At(NodeFactory.Operator(g, ">"), 760, 230);
				gt.FindInput("b").Default.Set("0");
				let call = At(NodeMenu.CallOwn(g, Doc.FindMember("TakeDamage"), "Game.Player", true), 1320, 0);
				At(NodeFactory.Flow(g, .Sequence, 2), 0, 230);
				At(NodeFactory.Switch(g, "int", StringView[?]("0", "1")), 220, 230);
				let del = At(NodeFactory.DeferDelete(g), 1600, 0);
				let make = At(NodeFactory.Make(g, "Core.Pair<int,float>", StringView[?]("First", "Second"), StringView[?]("int", "float")), 0, 460);
				let brk = At(NodeFactory.BreakStruct(g, "Core.Pair<int,float>", StringView[?]("First", "Second"), StringView[?]("int", "float")), 300, 460);
				let lit = At(NodeFactory.Literal(g, "float", "2.5f"), 560, 460);
				let sel = At(NodeFactory.Select(g), 760, 440);
				let fatal = At(NodeFactory.Fatal(g), 1080, 230);
				let setName = At(NodeFactory.Set(g, "mName", "String"), 1080, 440);
				g.Connect(entry.Then, ctor.ExecIn);
				g.Connect(ctor.Then, local.ExecIn);
				g.Connect(local.Then, cast.ExecIn);
				g.Connect(ctor.FindOutput("object"), cast.FindInput("value"));
				g.Connect(cast.FindOutput("then"), branch.ExecIn);
				g.Connect(getHealth.Result, gt.FindInput("a"));
				g.Connect(gt.Result, branch.FindInput("condition"));
				g.Connect(branch.FindOutput("true"), call.ExecIn);
				g.Connect(getHealth.Result, call.FindInput("amount"));
				g.Connect(call.Then, del.ExecIn);
				g.Connect(ctor.FindOutput("object"), del.FindInput("object"));
				g.Connect(cast.FindOutput("failed"), fatal.ExecIn);
				g.Connect(make.Result, brk.FindInput("value"));
				g.Connect(lit.Result, sel.FindInput("true"));
				g.Connect(gt.Result, sel.FindInput("condition"));
				g.Connect(branch.FindOutput("false"), setName.ExecIn);
				CommitCurrent();
				mSelfTestWait = 2;
				return false;
			case 1:
				let tab = CurrentTab;
				let g = CurrentMethod.Graph;
				for (let n in g.Nodes)
					if (n.Kind == .Switch)
						mGraphPanel.SetCollapsed(tab, n, true);
				tab.ClearSelection();
				tab.CenterOn(600, 220);
				tab.SetZoomLevel(Canvas.DefaultZoomLevel, .(0, 0));
				return true;
			}
			return true;
		}
	}

	/// The folder the self tests make their work folders in: TEMP (Windows), else TMPDIR, else
	/// /tmp off Windows. False when there is none (the caller picks a folder of its own).
	static class SelfTestTemp
	{
		public static bool Get(String outDir)
		{
			outDir.Clear();
			for (let name in StringView[?]("TEMP", "TMPDIR"))
			{
				if (Environment.GetEnvironmentVariable(name, outDir) case .Ok && !outDir.IsEmpty)
					return true;
				outDir.Clear();
			}
#if BF_PLATFORM_WINDOWS
			return false;
#else
			outDir.Set("/tmp");
			return true;
#endif
		}
	}
}
#endif
