using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using System.Threading;
using Treadle.Language;

namespace Treadle.Backend.Driver
{
	/// One child process with its stdout and stderr read on two threads (so neither pipe can fill
	/// and stall it), optionally inside a job object (it dies with the editor and Kill ends its tree).
	class RunningProcess
	{
		class Shared
		{
			public Monitor Lock = new .() ~ delete _;
			public String Out = new .() ~ delete _;
			public String Err = new .() ~ delete _;
			/// Complete lines in arrival order, both pipes ("!" prefix: stderr). Taken by TakeLines.
			public List<String> Lines = new .() ~ DeleteContainerAndItems!(_);
			public int Owners = 3;
			public int Finished;
			/// Lines before this index were taken (their slots are null). Max > 0: the ring keeps at most that many
			/// unread lines; the oldest are dropped and counted in Skipped.
			public int Head;
			public int Max;
			public int Skipped;
			/// Every line is also written here when set (unbounded).
			public FileStream Tee ~ delete _;
			public Monitor TeeLock = new .() ~ delete _;
		}

		SpawnedProcess mProcess ~ delete _;
		ProcessJob mJob ~ delete _;
		Shared mShared;
		Thread mOutThread;
		Thread mErrThread;
		public int ExitCode;
		public bool Started;
		public String Error = new .() ~ delete _;
		public Stopwatch Watch = new .() ~ delete _;
		public String CommandLine = new .() ~ delete _;
		/// Set before Start. Linux: the child runs in a process group of its own, which Kill and
		/// deleting this object (before the child ended) end as a whole (ProcessJob; Windows: the job
		/// does that for every child).
		public bool OwnGroup;
		/// Set before Start, with OwnGroup. Linux: the child also gets SIGKILL when the thread that
		/// started it ends (the editor killed), through `setpriv --pdeathsig`.
		public bool ParentDeath;
		/// Set before Start. False: the child gets a console window of its own (Windows: the new console of a
		/// child of a program without one) and its output is not read here; Done is true when it ended.
		public bool Capture = true;
		/// Set before Start. > 0: at most that many unread lines are kept (the oldest are dropped and counted), so a
		/// program that floods its output cannot grow memory or stall the reader of TakeLines.
		public int MaxLines;
		/// Set before Start. Every line is also written to this file (truncated at the start), none dropped.
		public String TeePath = new .() ~ delete _;

		// each reader thread is joined once (ThreadJoin: a second join is undefined on Linux)
		bool mOutJoined;
		bool mErrJoined;

		public ~this()
		{
			// still running (the handle goes first: Close Project, the editor closing): its job or
			// group ends it now, so its pipes close and the reader threads end
			if (Started && mProcess != null && mJob != null && mJob.Assigned && !mProcess.HasExited)
				mJob.Kill(mProcess);
			if (mOutThread != null && ThreadJoin.Join(mOutThread, ref mOutJoined, 2000))
				delete mOutThread;
			if (mErrThread != null && ThreadJoin.Join(mErrThread, ref mErrJoined, 2000))
				delete mErrThread;
			Release();
		}

		void Release()
		{
			if (mShared == null)
				return;
			bool free;
			using (mShared.Lock.Enter())
				free = --mShared.Owners == 0;
			if (free)
				delete mShared;
			mShared = null;
		}

		/// Quotes one argument for the Windows command line.
		public static void Quote(StringView arg, String outText)
		{
			bool needs = arg.IsEmpty;
			for (let c in arg.RawChars)
				if (c == ' ' || c == '\t' || c == '"')
					needs = true;
			if (!needs)
			{
				outText.Append(arg);
				return;
			}
			outText.Append('"');
			int slashes = 0;
			for (let c in arg.RawChars)
			{
				if (c == '\\')
				{
					slashes++;
					continue;
				}
				if (c == '"')
				{
					for (int i < slashes * 2 + 1)
						outText.Append('\\');
				}
				else
					for (int i < slashes)
						outText.Append('\\');
				slashes = 0;
				outText.Append(c);
			}
			for (int i < slashes * 2)
				outText.Append('\\');
			outText.Append('"');
		}

		/// Starts `exe` with `args`. False with Error when it could not be started.
		public bool Start(StringView exe, List<String> args, StringView workDir, bool inJob = true)
		{
			String argText = scope .();
			for (let a in args)
			{
				if (!argText.IsEmpty)
					argText.Append(' ');
				Quote(a, argText);
			}
			CommandLine.Clear();
			Quote(exe, CommandLine);
			if (!argText.IsEmpty)
				CommandLine.AppendF(" {}", argText);
			ProcessStartInfo psi = scope .();
			if (inJob)
			{
				mJob = new .();
				mJob.PrepareStart(psi, exe, argText, OwnGroup, ParentDeath);
			}
			else
			{
				psi.SetFileName(exe);
				psi.SetArguments(argText);
			}
			if (!workDir.IsEmpty)
				psi.SetWorkingDirectory(workDir);
			psi.UseShellExecute = false;
			psi.RedirectStandardOutput = Capture;
			psi.RedirectStandardError = Capture;
			psi.CreateNoWindow = Capture;
			mProcess = new .();
			Watch.Start();
			if (mProcess.Start(psi) case .Err)
			{
				Error.AppendF("could not start {}", exe);
				return false;
			}
			mJob?.Assign(mProcess);
			mShared = new .();
			mShared.Max = MaxLines;
			if (Capture && !TeePath.IsEmpty)
			{
				String dirPart = scope .();
				if (Path.GetDirectoryPath(TeePath, dirPart) case .Ok)
					Directory.CreateDirectory(dirPart).IgnoreError();
				FileStream tee = new .();
				if (tee.Create(TeePath, .Write, .Read) case .Ok)
					mShared.Tee = tee;
				else
					delete tee;
			}
			if (!Capture)
			{
				mShared.Owners = 1;
				mShared.Finished = 2;
				Started = true;
				return true;
			}
			FileStream outStream = new .();
			FileStream errStream = new .();
			if (mProcess.AttachStandardOutput(outStream) case .Err)
				DeleteAndNullify!(outStream);
			if (mProcess.AttachStandardError(errStream) case .Err)
				DeleteAndNullify!(errStream);
			let shared = mShared;
			mOutThread = new Thread(new () => ReadLoop(outStream, shared, false));
			mOutThread.SetName("Treadle tool output");
			mOutThread.IsBackground = true;
			mOutThread.Start(false);
			mErrThread = new Thread(new () => ReadLoop(errStream, shared, true));
			mErrThread.SetName("Treadle tool errors");
			mErrThread.IsBackground = true;
			mErrThread.Start(false);
			Started = true;
			return true;
		}

		static void ReadLoop(FileStream stream, Shared shared, bool isErr)
		{
			if (stream != null)
			{
				StreamReader reader = scope .(stream, null, false, 4096);
				while (true)
				{
					String line = scope .();
					if (reader.ReadLine(line) case .Err)
						break;
					if (shared.Tee != null)
						using (shared.TeeLock.Enter())
						{
							shared.Tee.Write(Span<uint8>((uint8*)line.Ptr, line.Length)).IgnoreError();
							shared.Tee.Write(Span<uint8>((uint8*)"\n", 1)).IgnoreError();
						}
					using (shared.Lock.Enter())
					{
						// the text kept for GetOutput / GetErrors is bounded too for a program with a ring
						if (shared.Max == 0 || shared.Out.Length + shared.Err.Length < 1048576)
						{
							let target = isErr ? shared.Err : shared.Out;
							target.Append(line);
							target.Append('\n');
						}
						String l = new .();
						if (isErr)
							l.Append('!');
						l.Append(line);
						shared.Lines.Add(l);
						if (shared.Max > 0 && shared.Lines.Count - shared.Head > shared.Max)
						{
							delete shared.Lines[shared.Head];
							shared.Lines[shared.Head] = null;
							shared.Head++;
							shared.Skipped++;
							if (shared.Head >= 4096)
							{
								shared.Lines.RemoveRange(0, shared.Head);
								shared.Head = 0;
							}
						}
					}
				}
			}
			bool free;
			using (shared.Lock.Enter())
			{
				shared.Finished++;
				free = --shared.Owners == 0;
			}
			delete stream;
			if (free)
				delete shared;
		}

		public bool HasExited => !Started || mProcess.HasExited;

		/// Waits for the end (and for both pipes to drain). -1: forever. False on timeout.
		public bool Wait(int timeoutMs = -1)
		{
			if (!Started)
				return true;
			if (!mProcess.WaitFor(timeoutMs))
				return false;
			ExitCode = mProcess.ExitCode;
			ThreadJoin.Join(mOutThread, ref mOutJoined, 5000);
			ThreadJoin.Join(mErrThread, ref mErrJoined, 5000);
			Watch.Stop();
			mJob?.Release();
			return true;
		}

		/// True when the process ended and its pipes are drained.
		public bool Done
		{
			get
			{
				if (!Started)
					return true;
				if (!mProcess.HasExited)
					return false;
				using (mShared.Lock.Enter())
					if (mShared.Finished < 2)
						return false;
				if (Watch.IsRunning)
				{
					ExitCode = mProcess.ExitCode;
					Watch.Stop();
					mJob?.Release();
				}
				return true;
			}
		}

		public void Kill()
		{
			if (!Started || mProcess.HasExited)
				return;
			if (mJob != null)
				mJob.Kill(mProcess);
			else
				mProcess.Kill(1, .KillChildren);
		}

		public int ProcessId => (Started && mProcess != null) ? mProcess.ProcessId : 0;

		public void GetOutput(String outText)
		{
			if (mShared == null)
				return;
			using (mShared.Lock.Enter())
				outText.Append(mShared.Out);
		}

		public void GetErrors(String outText)
		{
			if (mShared == null)
				return;
			using (mShared.Lock.Enter())
				outText.Append(mShared.Err);
		}

		/// Moves the lines read so far into `outLines` ("!" prefix: stderr).
		/// `maxMs` / `maxLines` > 0: stops after that long / that many lines (the rest stays for the next call).
		/// Lines the ring dropped come first as one row, "\x01... N lines skipped".
		public void TakeLines(List<String> outLines, double maxMs = 0, int maxLines = 0)
		{
			if (mShared == null)
				return;
			Stopwatch sw = scope .(true);
			using (mShared.Lock.Enter())
			{
				if (mShared.Skipped > 0)
				{
					outLines.Add(new String()..AppendF("\x01... {} lines skipped", mShared.Skipped));
					mShared.Skipped = 0;
				}
				int n = 0;
				while (mShared.Head < mShared.Lines.Count)
				{
					outLines.Add(mShared.Lines[mShared.Head]);
					mShared.Lines[mShared.Head] = null;
					mShared.Head++;
					n++;
					if (maxLines > 0 && n >= maxLines)
						break;
					if (maxMs > 0 && (n & 15) == 0 && sw.Elapsed.TotalMilliseconds > maxMs)
						break;
				}
				if (mShared.Head >= mShared.Lines.Count)
				{
					mShared.Lines.Clear();
					mShared.Head = 0;
				}
			}
		}

		/// True while lines wait to be taken.
		public bool HasPending
		{
			get
			{
				if (mShared == null)
					return false;
				using (mShared.Lock.Enter())
					return mShared.Head < mShared.Lines.Count || mShared.Skipped > 0;
			}
		}

		/// Runs a tool to the end. Returns the exit code (-1 when it could not start).
		public static int Run(StringView exe, List<String> args, StringView workDir, String outStdout, String outStderr, int timeoutMs = -1)
		{
			RunningProcess p = scope .();
			if (!p.Start(exe, args, workDir))
			{
				outStderr?.Append(p.Error);
				return -1;
			}
			if (!p.Wait(timeoutMs))
			{
				p.Kill();
				p.Wait(5000);
				outStderr?.Append("timed out\n");
			}
			p.GetOutput(outStdout);
			p.GetErrors(outStderr);
			return p.ExitCode;
		}
	}
}
