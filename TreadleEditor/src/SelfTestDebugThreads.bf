// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using System.IO;
using Treadle.Debug;
using Treadle.Document;
using Treadle.Graph;

namespace Treadle.Editor
{
	/// The `debug` self test, threads part (docs/Threads.md 6): the core fixture threads-basic (four named
	/// Threads, each running a Lambda) copied as a project, a breakpoint on a node of the Lambda's Sheet, F5:
	/// the program stops on that node on a worker thread; the session lists the threads with that thread's
	/// name (`worker <n>`) current and its call stack is the Lambda's Sheet; selecting another thread reads
	/// its stack without resuming, and the main thread's stack is Main waiting in Join.
	extension EditorApp
	{
#if BF_PLATFORM_WINDOWS
		const String ThreadsProgramFile = "Threads\\threads-basic.treadle";
#else
		const String ThreadsProgramFile = "Threads/threads-basic.treadle";
#endif
		int32 mDbgThreadSerial;
		int mDbgThreadPick;
		double mDbgHoldUntil;

		bool SelfTestDebugThreads()
		{
			switch (mSelfTestStep)
			{
			case cDbgThreads:
				{
					String samples = scope .();
					String fixtures = scope .();
					if (!FindSamples(samples) || !FindFixtures(samples, fixtures))
					{
						Notify.Log(.Info, "SelfTest", "[SELFTEST] debug: the threads part is skipped (no fixtures folder: a package run)");
						mSelfTestStep = cDbgCleanup - 1;
						return false;
					}
					String dir = scope $"{mDbgDir}{DbgSep}Threads";
					Directory.CreateDirectory(dir).IgnoreError();
					File.Copy(scope $"{fixtures}/core/threads-basic.treadle", scope $"{dir}{DbgSep}threads-basic.treadle").IgnoreError();
					File.WriteAllText(scope $"{dir}{DbgSep}Threads.tproj",
						"# tproj 1\nproject Threads\n\tkind console\n\tentry Cx.ThreadsBasicMain\n\tversion 0.1.0\nconfig Debug\n\tchecks on\n\toptimize 0\nconfig Release\n\toptimize 2\n\tchecks off\n").IgnoreError();
					OpenProjectNow(dir, scope $"{dir}{DbgSep}threads-basic.treadle", true);
					mSelfTestWait = 3;
					mDbgWatch.Restart();
				}
				return false;
			case cDbgThreads + 1:
				{
					// the node l5 (Arrays.Set) of the Lambda b6's Sheet: it runs on each worker
					let doc = FindDoc(scope $"{mDbgDir}{DbgSep}{ThreadsProgramFile}") ?? OpenFile(scope $"{mDbgDir}{DbgSep}{ThreadsProgramFile}", false);
					Sheet lambda = null;
					if (doc != null)
						for (let s in doc.Sheets)
							for (let n in s.Graph.Nodes)
								if (n.Key == "l5")
									lambda = s;
					if (lambda == null)
					{
						SelfTestCheck(false, "debug: node l5 of the Lambda Sheet of threads-basic was not found");
						return DbgAbort();
					}
					Debug.ClearBreakpoints();
					Debug.AddBreakpoint(doc.FilePath, lambda.Key, "l5");
					mDbgLaunchBase = DebugLaunches;
					StartDebugging();
					SelfTestCheck(mBuild != null && mBuild.Running, "debug: F5 builds threads-basic in Debug");
					mDbgWatch.Restart();
				}
				return false;
			case cDbgThreads + 2:
				{
					if (!DbgWaitLaunch("the stop on l5 in a worker thread"))
						return false;
					if (!DbgCaptureHold("debug-threads-worker"))
						return false;
					let f = Debug.CurrentFrame;
					DebugThread cur = null;
					String names = scope .();
					for (let t in Debug.Threads)
					{
						if (t.Current)
							cur = t;
						names.AppendF("{}{}{}", names.IsEmpty ? "" : ", ", t.Name, t.Current ? " (current)" : "");
					}
					SelfTestCheck(Debug.IsStopped && f != null && f.NodeKey == "l5",
						scope $"debug: threads-basic stopped on l5 of the Lambda ({Debug.Reason}, {(f != null) ? f.SheetName : ""} {(f != null) ? f.NodeKey : ""})");
					if (!Debug.IsStopped)
						return DbgAbort();
					SelfTestCheck(cur != null && cur.Name.StartsWith("worker "), scope $"debug: the stop is on a worker thread, listed by its name ({names})");
					// the Call Stack's order: Main first, then the workers by name
					bool ordered = !Debug.Threads.IsEmpty && Debug.Threads[0].Name == "Main";
					for (int i = 1; i < Debug.Threads.Count - 1; i++)
						if (DebugSession.NaturalCompare(Debug.Threads[i].Name, Debug.Threads[i + 1].Name) > 0 && (Debug.Threads[i].Name.StartsWith("Thread ") || !Debug.Threads[i + 1].Name.StartsWith("Thread ")))
							ordered = false;
					SelfTestCheck(ordered, scope $"debug: the thread rows are Main first, then the workers by name, then the system's by number ({names})");
					SelfTestCheck(Debug.Threads.Count >= 2, scope $"debug: the session lists the program's threads ({Debug.Threads.Count})");
					// another thread whose stack is not the Lambda's: try them in order (the main thread
					// is the one waiting in Main)
					mDbgThreadPick = 0;
					mDbgThreadSerial = Debug.StopSerial;
					if (!DbgPickThread())
					{
						SelfTestCheck(false, "debug: no other thread to select");
						return DbgAbort();
					}
					mDbgWatch.Restart();
				}
				return false;
			case cDbgThreads + 3:
				{
					if (!DbgWait(Debug.StopSerial != mDbgThreadSerial && Debug.IsStopped, "the stack of the selected thread", 30))
						return false;
					bool main = false;
					for (let f in Debug.Frames)
						if (f.IsUser && f.SheetName == "Cx.ThreadsBasicMain.Main")
							main = true;
					if (!main)
					{
						// not the main thread: the next one
						mDbgThreadSerial = Debug.StopSerial;
						if (DbgPickThread())
						{
							mSelfTestStep--;
							mDbgWatch.Restart();
							return false;
						}
					}
					if (main && !DbgCaptureHold("debug-threads-main"))
						return false;
					DebugThread cur = null;
					for (let t in Debug.Threads)
						if (t.Current)
							cur = t;
					SelfTestCheck(main && cur != null && !cur.Name.StartsWith("worker"),
						scope $"debug: selecting another thread shows its stack without resuming: the main thread ({(cur != null) ? cur.Name : "?"}) is in Cx.ThreadsBasicMain.Main ({Debug.Frames.Count} frames)");
					Debug.Stop();
					mSelfTestWait = 10;
					mSelfTestStep = cDbgVectors - 1; // then the vectors part (SelfTestDebugVectors.bf)
				}
				return false;
			default:
				mSelfTestStep = cDbgCleanup - 1;
				return false;
			}
		}

		/// With TREADLE_CAPTURE_DIR set (a pixel pass): logs `[SELFTEST] hold <name>` and stays on the step about
		/// 4 s by the clock so a capture can be asked for (FORK-NOTES, Build and run 3); true at once otherwise.
		bool DbgCaptureHold(StringView name, bool locals = false)
		{
			String dir = scope .();
			if (!(Environment.GetEnvironmentVariable("TREADLE_CAPTURE_DIR", dir) case .Ok) || dir.IsEmpty)
				return true;
			let now = ImGui.Gui.igGetTime();
			if (mDbgHoldUntil == 0)
			{
				if (locals)
					ShowLocals = true;
				else
					ShowCallStack = true; // the thread rows are what the capture is for
				mDbgHoldUntil = now + 4.0;
				Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] hold {name}");
			}
			if (now < mDbgHoldUntil)
			{
				Panels.Focus(locals ? Panels.LocalsId : Panels.CallStackId);
				mDbgWatch.Restart();
				mSelfTestStep--;
				return false;
			}
			mDbgHoldUntil = 0;
			return true;
		}

		/// Selects the next thread that is not current (mDbgThreadPick walks the list). False when none is left.
		bool DbgPickThread()
		{
			while (mDbgThreadPick < Debug.Threads.Count)
			{
				let t = Debug.Threads[mDbgThreadPick++];
				if (t.Current || t.Name.StartsWith("worker"))
					continue;
				Debug.SelectThread(t.Id);
				return true;
			}
			return false;
		}
	}
}
#endif
