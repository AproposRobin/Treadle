// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Language;
using ImGui;

namespace Treadle.Editor
{
	/// The `editor` case's checks of when problems are shown (docs/Editor-Model.md 7.1, ValidationState.bf), run
	/// before the case saves Player (one phase per frame; the edits are undone):
	///
	///  - After a Validate, an edit that makes a new problem (a Call of Heal with its input unwired) shows nothing
	///    new: the Sheet keeps what it showed, dimmed, Problems says "Not validated since the last change", the
	///    status bar "Not validated" and the Validate button carries its dot.
	///  - Validate shows the new problem on its node and in Problems, undimmed.
	///  - "Validate automatically after edits" on: an edit shows its problem at once and nothing is stale.
	///  - Build after an edit shows the problems as Validate does, and its own result.
	extension EditorApp
	{
		int mValPhase;
		bool mValDone;
		int32 mValNode1;
		int32 mValNode2;
		int mValRows;
		int mValShown;
		int mValWait;
		bool mValPrefWas;

		/// One phase per call; true when all are done.
		bool SelfTestValidateBefore()
		{
			let mg = CurrentMethod;
			let tab = CurrentTab;
			if (mg == null || tab == null)
			{
				SelfTestCheck(false, "editor: validate: no Sheet open");
				return true;
			}
			let g = mg.Graph;
			switch (mValPhase++)
			{
			case 0:
				mValPrefWas = Prefs.ValidateAfterEdits;
				Prefs.ValidateAfterEdits = false;
				Validate(true);
				SelfTestCheck(Validated && !ProblemsStale, "editor: validate: after Validate the workspace is validated, nothing stale");
				mValShown = g.Errors.Count + g.Warnings.Count;
				mValRows = (mValidate != null) ? mValidate.Messages.Count : -1;
				mValNode1 = SelfTestValidateAddHeal(mg, .(640, 1700));
				SelfTestCheck(mValNode1 != 0, "editor: validate: an edit adds a Call of Heal with its input unwired");
				return false;
			case 1:
				// The edit is committed: checked silently, nothing new shown.
				bool newShown = g.FindError(mValNode1) != null || g.FindWarning(mValNode1) != null;
				SelfTestCheck(!newShown && g.Errors.Count + g.Warnings.Count == mValShown,
					scope $"editor: validate: an edit after Validate shows no new problem ({g.Errors.Count + g.Warnings.Count} shown, {mValShown} before)");
				int rows = (mValidate != null) ? mValidate.Messages.Count : -1;
				SelfTestCheck(rows == mValRows, scope $"editor: validate: Problems keeps the rows of the last Validate ({rows}, {mValRows} before)");
				String state = scope .();
				ValidateStateText(state, ?, ?);
				SelfTestCheck(ProblemsStale && state == "Not validated", scope $"editor: validate: after the edit the problems are stale and the status bar says '{state}'");
				SelfTestCheck(mGraphPanel.ProblemsDim, "editor: validate: the Sheet draws the problems it shows dimmed");
				Validate(true);
				return false;
			case 2:
				SelfTestCheck(!ProblemsStale && !mGraphPanel.ProblemsDim, "editor: validate: Validate clears the stale state");
				let err = g.FindError(mValNode1);
				SelfTestCheck(err != null, scope $"editor: validate: Validate shows the new problem on its node ({(err != null) ? err : "none"})");
				bool row = false;
				if (mValidate != null)
					for (let d in mValidate.Messages)
						if (d.NodeId == mValNode1 && d.MethodKey == mg.Key)
							row = true;
				SelfTestCheck(row, "editor: validate: Problems lists it (From: Validate)");
				// The preference on: the old live behaviour.
				Prefs.ValidateAfterEdits = true;
				ValidateAfterEditsChanged();
				mValNode2 = SelfTestValidateAddHeal(mg, .(640, 1900));
				return false;
			case 3:
				SelfTestCheck(mValNode2 != 0 && g.FindError(mValNode2) != null && !ProblemsStale,
					"editor: validate: with 'Validate automatically after edits' on, an edit shows its problem at once");
				Prefs.ValidateAfterEdits = false;
				// An edit, then Build: the problems are shown as Validate shows them, and the build's own.
				let n = g.FindNode(mValNode2);
				if (n != null)
				{
					BeginEdit();
					n.X += 32;
					CommitCurrent();
				}
				return false;
			case 4:
				SelfTestCheck(ProblemsStale, "editor: validate: an edit with the preference off is stale again");
				// Build checks as Validate does, also when it cannot start (here: a read-only copy from the codec
				// case cannot be saved).
				Build();
				SelfTestCheck(!ProblemsStale && g.FindError(mValNode1) != null && g.FindError(mValNode2) != null,
					"editor: validate: Build shows the problems of the Sheet as it is, not stale");
				// A finished build with an error on a node, then an edit: the build's errors are not held back.
				mValBuildWas = mBuild;
				let job = new SelfTestFinishedBuild();
				let d = new Diagnostic();
				d.Severity = .Error;
				d.Origin = .Build;
				d.Text.Set("self test: a build error on the Call");
				d.Path.Set(mg.Doc.FilePath);
				DiagnosticMap.Locate(mg, g.FindNode(mValNode1), d);
				job.Messages.Add(d);
				mBuild = job;
				let n1 = g.FindNode(mValNode1);
				if (n1 != null)
				{
					BeginEdit();
					n1.X += 32;
					CommitCurrent();
				}
				return false;
			case 5:
				Dictionary<int32, String> errors = scope .();
				Dictionary<int32, String> warnings = scope .();
				defer { for (let v in errors.Values) delete v; for (let v in warnings.Values) delete v; }
				GetNodeDiagnostics(mg, errors, warnings);
				String buildErr = null;
				errors.TryGetValue(mValNode1, out buildErr);
				SelfTestCheck(ProblemsStale && buildErr != null && buildErr.StartsWith("self test:"),
					"editor: validate: Build still shows its errors on the nodes after an edit");
				delete mBuild;
				mBuild = mValBuildWas;
				mValBuildWas = null;
				// The two Calls and the two moves go (four undo steps).
				for (int i < 4)
					EditDoc.Undo();
				return false;
			default:
				SelfTestCheck(g.FindNode(mValNode1) == null && g.FindNode(mValNode2) == null, "editor: validate: undo takes the test's nodes back");
				Prefs.ValidateAfterEdits = mValPrefWas;
				mValPhase = 0;
				return true;
			}
		}

		/// A Call of Heal (its int input unwired) placed through the catalogue; its node id (0 when none).
		int32 SelfTestValidateAddHeal(Sheet mg, ImVec2 pos)
		{
			mActionTab = CurrentTab;
			let item = mNodeMenu.ItemForKey(mg, pos, 0, "Functions | Player\tHeal");
			let call = (item != null) ? ExecuteAction(item) : null;
			delete item;
			return (call != null) ? call.Id : 0;
		}

		BuildJob mValBuildWas;
		int mValCapEdits;

		/// Capture steps (the pixel pass of the stale style): `valcap:validate` runs Validate as the toolbar
		/// does; `valcap:open` opens the project's Player on TakeDamage; `valcap:edit` adds a Branch (its Condition unwired) under the Sheet's Entry, an edit that
		/// makes the problems shown stale.
		bool SelfTestValidateCapture(StringView test)
		{
			if (test == "valcap:open")
			{
				// The project's Player type, its TakeDamage Sheet in front.
				let doc = OpenFile(scope $"{mProjectRoot}/Player.treadle");
				let s = doc?.FindSheetByName("TakeDamage");
				if (s != null)
					OpenTab(s);
				return true;
			}
			if (test == "valcap:validate")
			{
				Validate();
				return true;
			}
			if (test == "valcap:edit")
			{
				// A Branch with its Condition unwired, the next one further right.
				let mg = CurrentMethod;
				if (mg != null && mg.Graph.Entry != null)
				{
					mActionTab = CurrentTab;
					let item = mNodeMenu.ItemForKey(mg, .(mg.Graph.Entry.X + 40 + 260 * mValCapEdits++, mg.Graph.Entry.Y + 190), 0, "Flow Control\tBranch");
					if (item != null)
						ExecuteAction(item);
					delete item;
				}
				return true;
			}
			return false;
		}
	}

	/// A build that has ended (the self test puts its messages in place of a real build's).
	class SelfTestFinishedBuild : BuildJob
	{
		public override double ElapsedMs => 0;
		public override int ProcessId => 0;
		public override bool Update() => false;
		public override void Cancel() { }
	}
}
#endif
