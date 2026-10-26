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
			psi.RedirectStandardOutput = true;
			psi.RedirectStandardError = true;
			psi.CreateNoWindow = true;
			mProcess = new .();
			Watch.Start();
			if (mProcess.Start(psi) case .Err)
			{
				Error.AppendF("could not start {}", exe);
				return false;
			}
			mJob?.Assign(mProcess);
			mShared = new .();
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
					using (shared.Lock.Enter())
					{
						let target = isErr ? shared.Err : shared.Out;
						target.Append(line);
						target.Append('\n');
						String l = new .();
						if (isErr)
							l.Append('!');
						l.Append(line);
						shared.Lines.Add(l);
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
		public void TakeLines(List<String> outLines)
		{
			if (mShared == null)
				return;
			using (mShared.Lock.Enter())
			{
				outLines.AddRange(mShared.Lines);
				mShared.Lines.Clear();
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
