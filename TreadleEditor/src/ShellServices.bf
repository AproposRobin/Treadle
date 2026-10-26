using System;
using System.Collections;
using System.IO;
using ImGui;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Language;
using Treadle.Model;

namespace Treadle.Editor
{
	/// Shell services: the recovery prompt, the Build menu and the diagnostics on nodes (Problems
	/// panel).
	extension EditorApp
	{
		// ---------------------------------------------------------------- recovery prompt

		List<RecoveredFile> mRecovered = new .() ~ DeleteContainerAndItems!(_);
		bool mShowRecoveryModal;

		/// At start-up: journal entries of sessions that crashed or were killed.
		public void CheckRecovery()
		{
			Recovery.FindOrphans(mRecovered);
			if (mRecovered.IsEmpty)
				return;
			mShowRecoveryModal = true;
			Notify.Log(.Warning, "Editor", scope $"Found unsaved changes of {mRecovered.Count} file(s) from a session that did not exit cleanly");
		}

		void RecoverAll()
		{
			int restored = 0;
			int kept = 0;
			for (let rf in mRecovered)
			{
				if (!File.Exists(rf.SourcePath))
				{
					Notify.Log(.Warning, "Editor", scope $"Recovery: {rf.SourcePath} no longer exists; the text stays in {rf.JournalPath}");
					kept++;
					continue;
				}
				let doc = OpenFile(rf.SourcePath, false);
				if (doc == null)
				{
					// Locked, no permission, ...: the journal is the only copy of the text, so it stays.
					Notify.Log(.Warning, "Editor", scope $"Recovery: {rf.SourcePath} could not be opened; the text stays in {rf.JournalPath}");
					kept++;
					continue;
				}
				String why = scope .();
				if (!doc.LoadText(rf.Text, why))
				{
					Notify.Log(.Warning, "Editor", scope $"Recovery: {rf.SourcePath}: {why}; the text stays in {rf.JournalPath}");
					kept++;
					continue;
				}
				doc.Modified = true;
				restored++;
				Recovery.DeleteJournal(rf.JournalPath);
				Notify.Log(.Info, "Editor", scope $"Recovered unsaved changes of {rf.SourcePath} (from {rf.Time})");
			}
			// Everything was restored or already on disk: drop the dead sessions. Otherwise only the
			// entries that were handled went; the others are offered again at the next start.
			if (kept == 0)
				Recovery.DeleteOrphans();
			else
				SetStatus(scope $"{kept} recovered file(s) could not be restored; their text is kept (see the Output Log)", .Warning);
			ClearAndDeleteItems!(mRecovered);
			UpdateTitle();
			if (restored > 0)
				Notify.Success(scope $"Recovered {restored} file(s): review and save them (Ctrl+Shift+S)");
		}

		void DrawRecoveryModal()
		{
			if (mShowRecoveryModal)
			{
				Gui.OpenPopup("Recover unsaved changes?##recovery");
				mShowRecoveryModal = false;
			}
			if (!Gui.igBeginPopupModal("Recover unsaved changes?##recovery", null, WindowFlags.AlwaysAutoResize))
				return;
			Gui.Text("Treadle did not exit cleanly last time. These files had unsaved changes:");
			Gui.igSpacing();
			for (let rf in mRecovered)
			{
				Gui.TextColored(Theme.Warning, scope $"   {rf.SourcePath}");
				Gui.SameLine();
				Gui.TextDisabled(scope $"  {rf.Time}, {rf.Text.Length} chars{File.Exists(rf.SourcePath) ? "" : "  (file no longer exists)"}");
			}
			Gui.igSpacing();
			Gui.TextDisabled("Recover opens each file with the recovered text as unsaved changes (undo goes back to the disk version).");
			Gui.igSpacing();
			if (Gui.Button("Recover", .(120 * Look.Scale, 0)))
			{
				RecoverAll();
				Gui.igCloseCurrentPopup();
			}
			Gui.SameLine();
			if (Gui.Button("Discard", .(120 * Look.Scale, 0)))
			{
				Recovery.DeleteOrphans();
				ClearAndDeleteItems!(mRecovered);
				Notify.Log(.Info, "Editor", "Discarded the recovered changes");
				Gui.igCloseCurrentPopup();
			}
			Gui.SameLine();
			if (Gui.Button("Decide Later", .(120 * Look.Scale, 0)))
			{
				ClearAndDeleteItems!(mRecovered);
				Gui.igCloseCurrentPopup();
			}
			Gui.EndPopup();
		}

		// ---------------------------------------------------------------- build menu

		void DrawBuildMenu()
		{
			if (!Gui.BeginMenu("Build"))
				return;
			if (Gui.MenuItem(scope $"{Icon.CircleCheck}  Validate", "Shift+F7"))
				Validate();
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip("Check the open Sheets now: the graph checks and the language's own checks.\nNothing is saved; the results are in Problems, tagged Validate.");
			DrawRunMenuItems(); // Run first: it builds when needed (RunProgram.bf)
			Gui.Separator();
			if (Gui.MenuItem(scope $"{Icon.Compile}  Build", "F7"))
				Build();
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip("Build: produce the exe without starting it (saves every file first)");
			if (Gui.MenuItem(scope $"{Icon.Compile}  Force Build", "Ctrl+F7"))
				Build(default, true);
			if (Gui.MenuItem(scope $"{Icon.CircleX}  Cancel Build", "", false, mBuild != null && mBuild.Running))
				CancelBuild();
			Gui.Separator();
			DrawCreateMainItem(); // EntryPoint.bf
			if (Gui.MenuItem(scope $"{Icon.CircleX}  Problems"))
			{
				ShowCompilerResults = true;
				mFocusCompilerResults = true;
			}
			if (Gui.MenuItem(scope $"{Icon.FolderOpen}  Open Logs Folder"))
			{
				String dir = scope .();
				AppPaths.Sub("logs", dir);
				ShowInExplorer(dir, false);
			}
			Gui.EndMenu();
		}

		// ---------------------------------------------------------------- diagnostics on nodes

		/// Build errors and warnings of this graph, and the messages of the last Validate, by node
		/// id (a node keeps its first message).
		public void GetNodeDiagnostics(Sheet mg, Dictionary<int32, String> outErrors, Dictionary<int32, String> outWarnings)
		{
			void Take(List<Diagnostic> list)
			{
				for (let d in list)
				{
					if (!d.OnNode || d.MethodKey != mg.Key || !ProjectIndex.SamePath(d.Path, mg.Doc.FilePath))
						continue;
					let node = DiagnosticMap.Resolve(mg, d);
					if (node == null)
						continue;
					let target = d.IsError ? outErrors : outWarnings;
					if (!target.ContainsKey(node.Id) && !outErrors.ContainsKey(node.Id))
						target[node.Id] = new String(d.Text);
				}
			}
			if (mValidate != null && mValidate.Level >= 2)
				Take(mValidate.CompilerMessages);
			if (mBuild != null && !mBuild.Running)
				Take(mBuild.Messages);
		}

		/// Opens the graph and selects the node of a diagnostic; falls back to the file.
		void JumpToDiagnostic(Diagnostic d)
		{
			if (d.Path.IsEmpty || !File.Exists(d.Path))
				return;
			if (!d.Variable.IsEmpty && JumpToVariable(d))
				return;
			if (!d.MethodKey.IsEmpty)
			{
				let doc = OpenFile(d.Path, false);
				let mg = doc?.FindSheet(d.MethodKey);
				if (mg != null && mg.Graphable)
				{
					OpenTab(mg);
					let node = DiagnosticMap.Resolve(mg, d);
					if (node != null)
					{
						let tab = CurrentTab;
						tab.SelectOnly(node.Id);
						tab.CenterOn(node.X + 100, node.Y + 40);
						// The pin it is about is badged on the node; the status bar names it.
						if (!d.PinName.IsEmpty)
						{
							let pin = node.FindInput(d.PinName) ?? node.FindOutput(d.PinName);
							SetStatus(scope $"{d.Text}  (pin {(pin != null && !pin.Label.IsEmpty) ? (StringView)pin.Label : (StringView)d.PinName})", d.IsError ? .Error : .Warning, false);
						}
						return;
					}
				}
			}
			JumpToLine(d.Path, d.Line);
		}

		/// A message about a variable (T1078, a missing type): a Local Variable is selected in the Outline of its
		/// function's Sheet, a field, property, input or output shows its member's page; Properties then puts
		/// the keyboard on the Type field.
		bool JumpToVariable(Diagnostic d)
		{
			let colon = d.Variable.IndexOf(':');
			if (colon < 0)
				return false;
			StringView kind = d.Variable.Substring(0, colon);
			StringView name = d.Variable.Substring(colon + 1);
			let doc = OpenFile(d.Path, false);
			if (doc == null)
				return false;
			MemberDecl member = null;
			for (let m in doc.Members)
				if (m.Id == d.MemberKey)
					member = m;
			if (kind == "local")
			{
				let sheet = doc.FindSheet(d.MemberKey);
				if (sheet == null)
					return false;
				OpenTab(sheet);
				mSelLocalActive = true;
				mSelLocalName.Set(name);
				SelectOutline(.Local);
			}
			else if (member != null)
				SelectOutline(.Member, member);
			else
				return false;
			mFocusTypeField = kind == "local" || kind == "field"; // the rows that have a Type field of their own
			SetStatus(d.Text, d.IsError ? .Error : .Warning, false);
			return true;
		}

		/// Opens the document a message points into (its first Sheet); the line is the language's
		/// to interpret, so it is only shown in the status bar.
		void JumpToLine(StringView path, int32 line)
		{
			if (OpenFile(path) == null)
				return;
			if (line > 0)
				SetStatus(scope $"{path}: line {line}", .Info, false);
		}
	}
}
