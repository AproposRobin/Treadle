using System;
using System.Collections;
using ImGui;
using Treadle.Backend.Driver;

namespace Treadle.Editor
{
	/// Build > Run Without Debugging (Ctrl+F5): the build Run needs, then the program with its
	/// stdout and stderr in the Output Log (category "Run") and its exit code at the end.
	extension EditorApp
	{
		ProgramRun mProgramRun ~ { if (_ != null && !_.Finished) _.Stop(); delete _; };
		List<String> mRunLines = new .() ~ DeleteContainerAndItems!(_);
		/// The Output Log came forward for this run's output already.
		bool mRunLogShown;

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
			Gui.Separator();
			if (Gui.MenuItem(scope $"{Icon.Play}  Run Without Debugging", "Ctrl+F5", false, !ProgramRunning && (mBuild == null || !mBuild.Running)))
				RunProgram();
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
			String why = scope .();
			// --build-run runs the program in the project folder (a relative argument is read from
			// there, as in a terminal); Run Without Debugging in the exe's folder
			if (!mProgramRun.Start(job.ExePath, why, mRunArgs, mBuildRun ? (StringView)mProjectRoot : default))
			{
				Notify.Log(.Error, "Run", scope $"Could not start {job.ExePath}: {why}");
				DeleteAndNullify!(mProgramRun);
				return;
			}
			Notify.Log(.Info, "Run", scope $"> {job.ExePath}");
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
				// The program's first output brings the Output Log forward (once per run).
				mRunLogShown = true;
				ShowOutputLog = true;
				mFocusOutputLog = true;
			}
			for (let l in mRunLines)
			{
				mBuildRunOutput?.Add(new String(l));
				if (l.StartsWith('!'))
					Notify.Log(.Warning, "Run", StringView(l, 1));
				else
					Notify.Log(.Info, "Run", l);
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
