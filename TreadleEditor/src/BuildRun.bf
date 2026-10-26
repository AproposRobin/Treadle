using System;
using System.Collections;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Backend.Driver;

namespace Treadle.Editor
{
	/// `--build-run <project> [--config <name>]`: the editor opens the project, runs Build and Run
	/// (Ctrl+F5) as the menu does, prints the program's output and exit code (or the build's
	/// problems with the node each one is on) to the console and exits. TREADLE_BUILD_RUN_HOLD=<s>
	/// keeps the window open that many seconds afterwards, with the Output Log in front.
	extension EditorApp
	{
		/// The process exit code (Program.Main returns it).
		public int ExitCode;
		bool mBuildRun;
		String mBuildRunConfig = new .() ~ delete _;
		int mBuildRunStep;
		int mBuildRunFrames;
		double mBuildRunHoldUntil;
		/// The program's output lines while --build-run waits for it (stderr lines start with '!').
		List<String> mBuildRunOutput ~ DeleteContainerAndItems!(_);
		/// The command line Run gives the program (`--build-run ... -- <arguments>`).
		List<String> mRunArgs = new .() ~ DeleteContainerAndItems!(_);

		public void StartBuildRun(StringView config, Span<String> programArgs = default)
		{
			mBuildRun = true;
			mBuildRunConfig.Set(config);
			mBuildRunOutput = new .();
			for (let a in programArgs)
				mRunArgs.Add(new String(a));
		}

		void BuildRunOut(StringView text, bool error = false)
		{
			Program.ConsoleOut(text, error);
			Notify.Log(error ? .Warning : .Info, "BuildRun", text);
		}

		void BuildRunDone(int code)
		{
			ExitCode = code;
			mBuildRunStep = 3;
			String hold = scope .();
			double secs = 0;
			if (Environment.GetEnvironmentVariable("TREADLE_BUILD_RUN_HOLD", hold) case .Ok)
				secs = double.Parse(hold).GetValueOrDefault();
			ShowOutputLog = true;
			mFocusOutputLog = true;
			mBuildRunHoldUntil = ImGui.Gui.igGetTime() + secs;
		}

		/// One row of Problems as text, with the node the row selects (opened from its file).
		void BuildRunProblem(Diagnostic d)
		{
			String line = scope $"problem: {d.IsError ? "error" : "warning"} {d.Text}";
			if (!d.Where.IsEmpty)
				line.AppendF(" [{}]", d.Where);
			if (d.OnNode)
			{
				line.AppendF(" node {}", d.NodeKey);
				if (!d.PinName.IsEmpty)
					line.AppendF(" pin {}", d.PinName);
				TypeDocument doc = null;
				if (!d.Path.IsEmpty)
					doc = FindDoc(d.Path) ?? OpenFile(d.Path, false);
				let sheet = doc?.FindSheet(d.MethodKey);
				let node = (sheet != null) ? DiagnosticMap.Resolve(sheet, d) : null;
				if (node != null)
					line.AppendF(" -> Problems selects {} {} in {}", node.Kind, node.Text, sheet.Name);
				else
					line.Append(" -> the node is not found");
			}
			BuildRunOut(line, true);
		}

		/// Once per frame (after the build and the program are updated).
		void BuildRunTick()
		{
			if (!mBuildRun)
				return;
			switch (mBuildRunStep)
			{
			case 0:
				// let the project load and the first frames settle
				if (++mBuildRunFrames < 10)
					return;
				if (mProjectRoot.IsEmpty)
				{
					BuildRunOut("build-run: no project folder", true);
					BuildRunDone(EditorArgs.ExitUsage);
					return;
				}
				// A file newer than this build: refused with the read-only open's message, exit code 2.
				String newerPath = scope .();
				if (Treadle.Format.Migrations.FindNewer(mProjectRoot, newerPath, let newerVersion))
				{
					BuildRunOut(scope $"build-run: {newerPath}: {Treadle.Format.Migrations.NewerMessage(newerVersion, .. scope String())}", true);
					BuildRunDone(2);
					return;
				}
				BuildRunOut(scope $"build-run: {mProjectRoot} ({(mBuildRunConfig.IsEmpty ? "default configuration" : mBuildRunConfig)})");
				StartBuild(mBuildRunConfig, false, false, true);
				if (mBuild == null || !mBuild.Running)
				{
					BuildRunOut("build-run: the build did not start", true);
					BuildRunDone(3);
					return;
				}
				mBuildRunStep = 1;
			case 1:
				if (mBuild.Running)
					return;
				let job = mBuild as BackendBuildJob;
				if (!mBuild.Succeeded)
				{
					BuildRunOut(scope $"build: failed ({mBuild.Config}), {mBuild.Messages.Count} problem{(mBuild.Messages.Count == 1) ? "" : "s"}", true);
					for (let d in mBuild.Messages)
						BuildRunProblem(d);
					BuildRunDone(3);
					return;
				}
				BuildRunOut(scope $"build: ok ({mBuild.Config}) {job?.ExePath} in {mBuild.BuildMs:0} ms");
				for (let d in mBuild.Messages)
					BuildRunProblem(d);
				if (mProgramRun == null)
				{
					BuildRunOut("build-run: the program did not start", true);
					BuildRunDone(3);
					return;
				}
				mBuildRunStep = 2;
			case 2:
				if (!mProgramRun.Finished)
					return;
				BuildRunOut("--- program output");
				for (let l in mBuildRunOutput)
				{
					if (l.StartsWith('!'))
						BuildRunOut(scope $"stderr: {StringView(l, 1)}", true);
					else
						BuildRunOut(l);
				}
				BuildRunOut(scope $"--- exit code: {mProgramRun.ExitCode}");
				BuildRunDone(0);
			case 3:
				if (ImGui.Gui.igGetTime() < mBuildRunHoldUntil)
					return;
				for (let d in mDocs)
					d.Modified = false;
				QuitNow = true;
				mBuildRun = false;
			}
		}
	}
}

namespace Treadle.Editor
{
	/// `--format <project-or-file>... [--migrate] [--check]`: rewrites the type, C declarations,
	/// project and C import files in canonical form through the codec (Treadle.Format.Canonical),
	/// no window (docs/Format-Stability.md 3.3). A file already canonical is not written. A file
	/// below the current format version is migrated only with `--migrate` (layout sidecars too),
	/// keeping its old text once as `<file>.v<old>.bak`; without it the file is listed and left
	/// alone. With `--check` nothing is written: the files that are not canonical or not current
	/// are listed and the exit code is 1. A file newer than this build is refused (exit code 2).
	static class FormatCommand
	{
		public const String Switch = "--format";

		/// Handles the command line when it has `--format`; `exitCode` is 0 when every file read
		/// (and, with --check, was canonical and current), 1 otherwise, 2 for a bad command line
		/// or a file newer than this build.
		public static bool CommandLine(String[] args, out int exitCode)
		{
			exitCode = 0;
			int at = -1;
			for (int i < args.Count)
				if (args[i] == Switch)
					at = i;
			if (at < 0)
				return false;
			bool check = false;
			bool migrate = false;
			List<String> paths = scope .();
			for (int i = at + 1; i < args.Count; i++)
			{
				if (args[i] == "--check")
					check = true;
				else if (args[i] == "--migrate")
					migrate = true;
				else
					paths.Add(args[i]);
			}
			if (paths.IsEmpty)
			{
				Program.ConsoleOut("Treadle: --format needs a project folder or a file\n\nusage: Treadle --format <project-or-file>... [--migrate] [--check]", true);
				exitCode = 2;
				return true;
			}
			List<String> files = scope .();
			defer { ClearAndDeleteItems!(files); }
			List<String> moveLines = scope .();
			defer { ClearAndDeleteItems!(moveLines); }
			if (migrate && !check)
			{
				for (let p in paths)
					Treadle.Document.Sidecars.MigrateAt(p, moveLines);
				for (let l in moveLines)
					Program.ConsoleOut(l, false);
			}
			for (let p in paths)
			{
				let before = files.Count;
				Treadle.Format.Canonical.Collect(p, files, migrate);
				if (files.Count == before)
				{
					Program.ConsoleOut(scope $"Treadle: --format: '{p}' is not a folder or a file it formats", true);
					exitCode = 2;
					return true;
				}
			}
			int changed = 0, old = 0, migrated = 0, newer = 0, failed = 0, oldNames = 0, renamed = 0;
			String report = scope .();
			for (var f in files)
			{
				String why = scope .();
				// Old extensions (.vtype, .vtype.layout, .vproject, .kir; FormatNames): --migrate renames the
				// file, --check lists it (and fails), a plain --format names it and leaves the name.
				String now = scope .();
				switch (Treadle.Format.Canonical.RenameOldExtension(f, check || !migrate, now, why))
				{
				case .Renamed:
					renamed++;
					report.AppendF("renamed {} -> {}\n", f, now);
					f = now;
				case .WouldRename:
					oldNames++;
					report.AppendF("old extension {} (--format --migrate renames it to {})\n", f, now);
				case .Failed:
					failed++;
					report.AppendF("error {}: {}\n", f, why);
					continue;
				case .None:
				}
				switch (Treadle.Format.Canonical.FormatFile(f, check, migrate, why))
				{
				case .Same:
				case .Changed:
					changed++;
					report.AppendF("{} {}\n", check ? "not canonical" : "formatted", f);
				case .Old:
					old++;
					report.AppendF("old version {}: {}\n", f, why);
				case .Migrated:
					migrated++;
					report.AppendF("migrated {}\n", f);
				case .Newer:
					newer++;
					report.AppendF("error {}: {}\n", f, why);
				case .Failed:
					failed++;
					report.AppendF("error {}: {}\n", f, why);
				}
			}
			report.AppendF("{} files, {} {}, {} {}, {} newer, {} not read", files.Count, changed, check ? "not canonical" : "rewritten",
				old, migrate ? "to migrate" : "old version", newer, failed);
			if (migrate && !check)
				report.AppendF(", {} migrated, {} renamed", migrated, renamed);
			else
				report.AppendF(", {} old extension", oldNames);
			let bad = failed > 0 || newer > 0 || old > 0 || (check && (changed > 0 || oldNames > 0));
			Program.ConsoleOut(report, bad);
			exitCode = (newer > 0) ? 2 : (bad ? 1 : 0);
			return true;
		}
	}
}
