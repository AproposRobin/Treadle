using System;
using System.Collections;
using ImGui;
using Treadle.Backend.Driver;

namespace Treadle.Editor
{
	/// Build > Run (Ctrl+F5, the toolbar's Run): the build Run needs, then the program with its
	/// stdout and stderr in the Output Log (category "Run") and its exit code at the end.
	extension EditorApp
	{
		ProgramRun mProgramRun ~ { if (_ != null && !_.Finished) _.Stop(); delete _; };
		List<String> mRunLines = new .() ~ DeleteContainerAndItems!(_);
		/// What the program wrote under Run (the Debug Output panel shows it when no debug session has output).
		public List<String> mRunOutput = new .() ~ DeleteContainerAndItems!(_);
		/// The Output Log came forward for this run's output already.
		bool mRunLogShown;
		int mRunLogLines;

		public bool ProgramRunning => mProgramRun != null && !mProgramRun.Finished;

		/// Ctrl+F5: builds when stale, then runs the program.
		public void RunProgram()
		{
			if (ProgramRunning)
			{
				SetStatus("The program is still running (Build > Stop Program ends it)", .Warning);
				return;
			}
			StartBuild(default, false, false, true);
		}

		public void StopProgram()
		{
			if (ProgramRunning)
				mProgramRun.Stop();
		}

		void DrawRunMenuItems()
		{
			if (Gui.MenuItem(scope $"{Icon.Play}  Run", "Ctrl+F5", false, !ProgramRunning && (mBuild == null || !mBuild.Running)))
				RunProgram();
			if (Gui.igIsItemHovered(1 << 10 /* AllowWhenDisabled */))
				Gui.Tooltip("Run: build if needed, then start the program (without the debugger; F5 runs it under the debugger)");
			if (Gui.MenuItem(scope $"{Icon.Square}  Stop Program", "", false, ProgramRunning))
				StopProgram();
		}

		/// From OnBuildFinished: a Run's build that succeeded starts the program.
		void OnRunBuildFinished()
		{
			let job = mBuild as BackendBuildJob;
			if (job == null || !job.ForRun || !job.Succeeded || job.ExePath.IsEmpty)
				return;
			delete mProgramRun;
			mProgramRun = new .();
			mRunLogShown = false;
			mRunLogLines = 0;
			ClearAndDeleteItems!(mRunOutput);
			mDebug?.ClearOutput();
			// a console project runs in a console window of its own (Preferences > Build); a command-line
			// run and the self tests capture the output
			bool console = Prefs.RunInConsole && !mBuildRun && !Desktop.QuietWindow && Project != null && (Project.Kind.IsEmpty || Project.Kind == "console");
			String why = scope .();
			String tee = scope .();
			if (Prefs.RunLogFile && !console && !mProjectRoot.IsEmpty)
				tee.AppendF("{}{}build{}run.log", mProjectRoot, System.IO.Path.DirectorySeparatorChar, System.IO.Path.DirectorySeparatorChar);
			// --build-run runs the program in the project folder (a relative argument is read from
			// there, as in a terminal); Run Without Debugging in the exe's folder
			if (!mProgramRun.Start(job.ExePath, why, mRunArgs, mBuildRun ? (StringView)mProjectRoot : default, console, tee))
			{
				Notify.Log(.Error, "Run", scope $"Could not start {job.ExePath}: {why}");
				DeleteAndNullify!(mProgramRun);
				return;
			}
			Notify.Log(.Info, "Run", scope $"> {job.ExePath}");
			if (mProgramRun.InConsole)
				Notify.Log(.Info, "Run", "The program runs in its own console window (Preferences > Build)");
			SetStatus(scope $"Running {job.ExePath}", .Info, false);
		}

		/// Once per frame: the running program's output into the Output Log.
		void RunProgramTick()
		{
			if (mProgramRun == null || mProgramRun.Finished)
				return;
			let ended = mProgramRun.Update(mRunLines);
			if (!mRunLines.IsEmpty && !mRunLogShown)
			{
				// The program's first output brings Debug Output forward (once per run).
				mRunLogShown = true;
				ShowDebugOutput = true;
				mFocusDebugOutput = true;
			}
			for (let l in mRunLines)
			{
				mBuildRunOutput?.Add(new String(l));
				bool skipRow = l.StartsWith('\x01'); // "... N lines skipped": the ring dropped lines
				mRunOutput.Add(new String(l.StartsWith('!') ? StringView(l, 1) : (StringView)l));
				// the panel keeps the last 20,000 rows; whole blocks go at once so a flood costs little
				if (mRunOutput.Count > 21000)
				{
					for (int i < 1000)
						delete mRunOutput[i];
					mRunOutput.RemoveRange(0, 1000);
				}
				// the Output Log gets the start of the output only; Debug Output has the rest
				if (skipRow)
					continue;
				if (mRunLogLines < 500)
				{
					mRunLogLines++;
					if (l.StartsWith('!'))
						Notify.Log(.Warning, "Run", StringView(l, 1));
					else
						Notify.Log(.Info, "Run", l);
					if (mRunLogLines == 500)
						Notify.Log(.Info, "Run", "The rest of the program's output is in Debug Output");
				}
			}
			ClearAndDeleteItems!(mRunLines);
			if (ended)
			{
				let code = mProgramRun.ExitCode;
				Notify.Log((code == 0) ? .Info : .Warning, "Run", scope $"The program exited with code {code} after {mProgramRun.ElapsedMs / 1000:0.00} s");
				SetStatus(scope $"Program exited with code {code}", (code == 0) ? .Info : .Warning, false);
			}
		}
	}
}
