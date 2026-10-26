using System;
using System.Collections;
using Treadle.Document;
using Treadle.Graph;

namespace Treadle.Editor
{
	/// When the editor shows problems (docs/Editor-Model.md 7.1). The errors and warnings of the graph checks
	/// and of the compiler, the "evaluated Nx" counts, the C import and project warnings: all appear after an
	/// explicit Validate (Shift+F7), a Build or a Run, never because of an edit. An edit still runs the checks
	/// and the front end's incremental pass on the edited Sheet (the Node menu, type colours and wire
	/// compatibility follow it), but what a Sheet shows (`Graph.Errors` / `Graph.Warnings`, what every panel
	/// reads) stays as the last Validate left it, drawn dimmed as stale until the next one.
	///
	/// Staleness: every open document has an edit serial that moves whenever its Version does (an edit, an
	/// undo, a reload); Validate records the serials it saw; any difference is "not validated since the last
	/// change". The preference "Validate automatically after edits" (Prefs.ValidateAfterEdits) restores the
	/// earlier live behaviour: each edit shows the edited Sheet's problems at once.
	extension EditorApp
	{
		/// Per open document (by address: a closed one may be deleted, never read through these): the Version
		/// last seen and its edit serial.
		Dictionary<int, (int32 version, int32 serial)> mEditSerials = new .() ~ delete _;
		/// The edit serial of each document at the last Validate / Build / Run.
		Dictionary<int, int32> mValidatedAt = new .() ~ delete _;
		/// A Validate, Build or Run has run in this session.
		bool mEverValidated;
		/// Bumps on each Validate (the Sheet view takes its "evaluated Nx" counts again).
		public int32 ValidateGeneration = 1;
		/// "evaluated Nx" by graph (Graph.Serial), as the front end gave them while the workspace was as validated.
		Dictionary<int32, Dictionary<int32, int32>> mValidatedCounts = new .() ~ DeleteDictionaryAndValues!(_);

		/// The open documents, the front one included.
		void ForEachOpenDoc(delegate void(TypeDocument) fn)
		{
			for (let d in mDocs)
				fn(d);
			if (Doc != null && Doc != mEmptyDoc && !mDocs.Contains(Doc))
				fn(Doc);
		}

		/// Moves the edit serial of every document whose Version changed; forgets closed ones.
		void UpdateEditSerials()
		{
			HashSet<int> open = scope .();
			ForEachOpenDoc(scope [&] (d) =>
			{
				let key = (int)Internal.UnsafeCastToPtr(d);
				open.Add(key);
				if (mEditSerials.TryGetValue(key, var e))
				{
					if (e.version != d.Version)
					{
						e.version = d.Version;
						e.serial++;
						mEditSerials[key] = e;
					}
				}
				else
					mEditSerials[key] = (d.Version, 0);
				if (Prefs.ValidateAfterEdits)
					mValidatedAt[key] = mEditSerials[key].serial;
			});
			if (open.Count != mEditSerials.Count)
			{
				List<int> gone = scope .();
				for (let d in mEditSerials.Keys)
					if (!open.Contains(d))
						gone.Add(d);
				for (let d in gone)
				{
					mEditSerials.Remove(d);
					mValidatedAt.Remove(d);
				}
			}
		}

		/// True when a document changed since the last Validate / Build / Run (before the first one: since it
		/// was opened). Never true with "Validate automatically after edits" on.
		public bool ProblemsStale
		{
			get
			{
				if (Prefs.ValidateAfterEdits)
					return false;
				UpdateEditSerials();
				for (let kv in mEditSerials)
					if (kv.value.serial != (mValidatedAt.TryGetValue(kv.key, let at) ? at : 0))
						return true;
				return false;
			}
		}

		/// The status bar's state: Validate (or Build / Run) ran and nothing changed since.
		public bool Validated => (mEverValidated || Prefs.ValidateAfterEdits) && !ProblemsStale;

		/// Validate, Build or Run just showed the problems of the workspace as it is.
		void MarkValidated()
		{
			UpdateEditSerials();
			for (let kv in mEditSerials)
				mValidatedAt[kv.key] = kv.value.serial;
			mEverValidated = true;
			ValidateGeneration++;
			for (let v in mValidatedCounts.Values)
				delete v;
			mValidatedCounts.Clear();
		}

		/// The graph checks and the front end's incremental pass on `s` (an edit: `commit`, which also marks
		/// the document edited), without changing what the Sheet shows. With "Validate automatically after
		/// edits" on, what the checks found is shown instead.
		void CheckSheet(Sheet s, bool commit)
		{
			if (Prefs.ValidateAfterEdits)
			{
				if (commit)
					s.Doc.Commit(s);
				else
					s.Doc.Validate(s);
				return;
			}
			let g = s.Graph;
			let shownErrors = g.Errors;
			let shownWarnings = g.Warnings;
			g.Errors = new .();
			g.Warnings = new .();
			if (commit)
				s.Doc.Commit(s);
			else
				s.Doc.Validate(s);
			DeleteContainerAndItems!(g.Errors);
			DeleteContainerAndItems!(g.Warnings);
			g.Errors = shownErrors;
			g.Warnings = shownWarnings;
		}

		/// The "evaluated Nx" counts the Sheet view draws for `g`: none before a Validate; the front end's while
		/// nothing changed since; the counts of the last Validate (drawn dimmed) after an edit. With
		/// "Validate automatically after edits" on: the front end's when they are of the graph as it is, else
		/// the editor's own estimate.
		public void ShownEvaluationCounts(Graph g, Dictionary<int32, int32> outCounts)
		{
			outCounts.Clear();
			let frontEnd = FrontEnd;
			if (Prefs.ValidateAfterEdits)
			{
				if (frontEnd == null || !frontEnd.EvaluationCounts(g, outCounts))
					PinMatch.FanOut(g, outCounts);
				return;
			}
			if (!mEverValidated)
				return;
			if (!ProblemsStale)
			{
				if (frontEnd != null && frontEnd.EvaluationCounts(g, outCounts))
				{
					if (mValidatedCounts.TryGetValue(g.Serial, let old))
						delete old;
					let copy = new Dictionary<int32, int32>();
					for (let kv in outCounts)
						copy[kv.key] = kv.value;
					mValidatedCounts[g.Serial] = copy;
				}
				return;
			}
			if (mValidatedCounts.TryGetValue(g.Serial, let kept))
				for (let kv in kept)
					outCounts[kv.key] = kv.value;
		}

		/// The preference was switched: on shows the problems of the workspace as it is now.
		public void ValidateAfterEditsChanged()
		{
			if (Prefs.ValidateAfterEdits)
				Validate(true);
		}

		/// "Validated" / "Not validated" for the status bar, its colour and icon: yellow from any edit (or the
		/// start) until Validate runs; then red when it found errors, green when it found none (a warnings
		/// icon when there are warnings). The build state keeps its own text next to it.
		void ValidateStateText(String outText, out uint32 color, out StringView icon)
		{
			if (Validated)
			{
				if (mValidate != null && mValidate.Running)
				{
					outText.Append("Validating...");
					color = Look.AccentBlue;
					icon = Icon.LoaderCircle;
					return;
				}
				int errors = 0;
				int warnings = 0;
				if (mValidate != null)
				{
					errors = mValidate.ErrorCount;
					warnings = mValidate.WarningCount;
				}
				if (errors > 0)
					outText.AppendF("Validate: {} error{}", errors, (errors == 1) ? "" : "s");
				else
					outText.Append(Prefs.ValidateAfterEdits ? "Validated (after each edit)" : "Validated");
				color = (errors > 0) ? Look.Error : Look.Success;
				icon = (errors > 0) ? Icon.CircleX : ((warnings > 0) ? Icon.TriangleAlert : Icon.CircleCheck);
				return;
			}
			outText.Append("Not validated");
			color = Look.AccentYellow;
			icon = Icon.CircleHelp;
		}

		/// The edit serial of each document when the last build started.
		Dictionary<int, int32> mBuiltAt = new .() ~ delete _;

		/// A build started: what it builds is the workspace as it is now.
		void MarkBuilt()
		{
			UpdateEditSerials();
			mBuiltAt.Clear();
			for (let kv in mEditSerials)
				mBuiltAt[kv.key] = kv.value.serial;
		}

		/// True when a document changed since the last build started (a save does not make it built).
		public bool BuildStale
		{
			get
			{
				UpdateEditSerials();
				for (let kv in mEditSerials)
					if (kv.value.serial != (mBuiltAt.TryGetValue(kv.key, let at) ? at : 0))
						return true;
				return false;
			}
		}
	}
}
