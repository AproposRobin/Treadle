using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using System.Threading;
using Treadle.Document;
using Treadle.Language;
using Treadle.Backend.IR;

namespace Treadle.Backend.Driver
{
	/// The front end's side of Build (Load through Lower, docs/Compiler.md section 1): turns the
	/// project in `workspace` into Sheet IR. Implemented by the compiler's front end and installed
	/// on BackendToolchain.FrontEnd. Runs on the build thread.
	interface IProgramSource
	{
		/// Fills `outProgram` (its Name is the exe name; empty = the project folder's name).
		/// Problems go to `outMessages` (Origin .Build); false when there is nothing to build.
		bool Lower(StringView workspace, StringView config, IRProgram outProgram, List<Diagnostic> outMessages);
	}

	/// IToolchain over the back end: Validate is the graph checks (until the front end's Check is
	/// installed); Build and Run lower the project (through FrontEnd, or a `.tir` IR file in the
	/// project folder when no front end is installed), then emit, compile and link in-process with
	/// clang / lld from llvm-mingw.
	class BackendToolchain : IToolchain
	{
		NullToolchain mChecks = new .() ~ delete _;
		/// The front end (not owned). Null: Build reads a `.tir` file of the project folder.
		public IProgramSource FrontEnd;

		public bool CanValidate => mChecks.CanValidate;
		public bool SyntaxBusy => false;

		public ValidateJob Validate(in ValidateRequest request) => mChecks.Validate(request);

		public SyntaxJob CheckSyntax(in SyntaxRequest request) => null;

		public Result<BuildJob> Build(in BuildRequest request)
		{
			if (!ToolchainPaths.Found)
				return .Err;
			BackendBuildJob job = new .(this, request, false);
			job.Start();
			return job;
		}

		public Result<BuildJob> Run(in RunRequest request)
		{
			if (!ToolchainPaths.Found)
				return .Err;
			BackendBuildJob job = new .(this, request.Build, true);
			job.Start();
			return job;
		}

		public void Update(double now, List<String> outLog) { }

		/// A project folder that is only Sheet IR: a `.tir` file and no project file (`.tproj`).
		/// Build reads it directly even when a front end is installed.
		public static bool IsIRProject(StringView workspace)
		{
			if (!Directory.Exists(workspace))
				return false;
			for (let pattern in Treadle.Format.FormatNames.ProjectPatterns)
				for (let e in Directory.EnumerateFiles(workspace, pattern))
					return false;
			for (let pattern in Treadle.Format.FormatNames.IRPatterns)
				for (let e in Directory.EnumerateFiles(workspace, pattern))
					return true;
			return false;
		}

		/// Finds the IR file of a project folder (no front end installed): `<folder>.tir`, else the
		/// only `.tir` file in the folder.
		public static bool FindIRFile(StringView workspace, String outPath, String outWhy)
		{
			List<String> found = scope .();
			defer { ClearAndDeleteItems!(found); }
			for (let pattern in Treadle.Format.FormatNames.IRPatterns)
				for (let e in Directory.EnumerateFiles(workspace, pattern))
					found.Add(e.GetFilePath(.. new .()));
			if (found.IsEmpty)
			{
				outWhy.Append("No front end is installed in this build and the project folder has no .tir IR file.");
				return false;
			}
			String folder = scope .();
			Path.GetFileName(workspace, folder);
			for (let f in found)
			{
				String name = scope .();
				Path.GetFileNameWithoutExtension(f, name);
				if (name == folder)
				{
					outPath.Set(f);
					return true;
				}
			}
			if (found.Count > 1)
			{
				outWhy.AppendF("The project folder has {} .tir files; name the one to build after the folder ({}.tir).", found.Count, folder);
				return false;
			}
			outPath.Set(found[0]);
			return true;
		}
	}

	/// A Build or Run of the back end, on its own thread.
	class BackendBuildJob : BuildJob
	{
		BackendToolchain mOwner;
		Thread mThread ~ delete _;
		/// mThread was joined (ThreadJoin: once only).
		bool mJoined;
		Monitor mLock = new .() ~ delete _;
		List<String> mPendingLines = new .() ~ DeleteContainerAndItems!(_);
		List<Diagnostic> mPendingMessages = new .() ~ DeleteContainerAndItems!(_);
		bool mFinished;
		bool mReported;
		bool mCancelRequested;
		Stopwatch mWatch = new .() ~ delete _;
		/// The program that was built (empty when the build failed).
		public String ExePath = new .() ~ delete _;
		/// Started by Run: the caller launches ExePath when the job succeeded.
		public bool ForRun;
		public bool Force;
		public BuildReport Report = new .() ~ delete _;
		static int32 sLiveThreads;
		/// Build threads of jobs still running (self tests: none survives its job).
		public static int32 LiveThreads => Interlocked.Load(ref sLiveThreads);

		public this(BackendToolchain owner, BuildRequest request, bool forRun)
		{
			mOwner = owner;
			Workspace.Set(request.Workspace);
			Config.Set(request.Config.IsEmpty ? "Debug" : request.Config);
			LowerPriority = request.LowerPriority;
			ForRun = forRun;
			CommandLine.AppendF("Treadle back end: {} ({})", Workspace, Config);
		}

		public void Start()
		{
			Running = true;
			mWatch.Start();
			Interlocked.Increment(ref sLiveThreads);
			mThread = new Thread(new => Work);
			mThread.SetName("Treadle build");
			mThread.Start(false);
		}

		void Log(StringView line)
		{
			using (mLock.Enter())
				mPendingLines.Add(new .(line));
		}

		void Message(StringView text, StringView path = "", int32 line = 0)
		{
			Diagnostic d = new .();
			d.Severity = .Error;
			d.Origin = .Build;
			d.Text.Set(text);
			d.Path.Set(path);
			d.Line = line;
			using (mLock.Enter())
				mPendingMessages.Add(d);
		}

		/// Deleting a job whose build still runs (Close Project, a new project, the editor closing)
		/// cancels it and waits for its thread: the thread uses the job (its options, report and
		/// lists) to the end, so it must be done before the job's fields are freed.
		public ~this()
		{
			if (mThread != null)
			{
				mCancelRequested = true;
				ThreadJoin.Join(mThread, ref mJoined);
			}
		}

		void Work()
		{
			bool ok = Build();
			using (mLock.Enter())
			{
				Succeeded = ok && !mCancelRequested;
				mFinished = true;
			}
			Interlocked.Decrement(ref sLiveThreads);
		}

		bool Build()
		{
			IRProgram program = scope .();
			String irPath = scope .();
			if (mOwner.FrontEnd != null && !BackendToolchain.IsIRProject(Workspace))
			{
				List<Diagnostic> msgs = scope .();
				let lowered = mOwner.FrontEnd.Lower(Workspace, Config, program, msgs);
				using (mLock.Enter())
				{
					mPendingMessages.AddRange(msgs);
				}
				if (!lowered)
				{
					Log("The front end did not produce a program (see Problems).");
					return false;
				}
				List<String> errors = scope .();
				defer { ClearAndDeleteItems!(errors); }
				if (!program.Link(errors))
				{
					for (let e in errors)
						Message(scope $"IR: {e}");
					return false;
				}
			}
			else
			{
				String why = scope .();
				if (!BackendToolchain.FindIRFile(Workspace, irPath, why))
				{
					Log(why);
					Message(why);
					return false;
				}
				String text = scope .();
				if (File.ReadAllText(irPath, text, true) case .Err)
				{
					Message(scope $"cannot read {irPath}");
					return false;
				}
				Log(scope $"Reading the IR file {irPath}");
				List<String> errors = scope .();
				defer { ClearAndDeleteItems!(errors); }
				if (!IRReader.Read(text, program, errors))
				{
					for (let e in errors)
					{
						int32 line = 0;
						if (e.StartsWith("line "))
						{
							let colon = e.IndexOf(':');
							if (colon > 5)
								line = int32.Parse(e.Substring(5, colon - 5)).GetValueOrDefault();
						}
						Message(e, irPath, line);
						Log(scope $"{irPath}: {e}");
					}
					return false;
				}
			}
			if (mCancelRequested)
				return false;
			BuildOptions opts = scope .();
			opts.OutDir.AppendF("{}/build/{}", Workspace, Config);
			opts.SetProgram(program);
			opts.Force = Force;
			opts.Cancel = &mCancelRequested;
			if (!ProjectSettings(Workspace, Config, opts))
				return false;
			if (!program.Name.IsEmpty)
				opts.Name.Set(program.Name);
			else
				Path.GetFileName(Workspace, opts.Name..Clear());
			// The program's name and the config name become build/<config>/<name>.exe: a project file
			// (`project ../../x`, `config ../x`) cannot make Build write outside the build folder.
			if (!IsPlainName(opts.Name) || !IsPlainName(Config))
			{
				Message(scope $"the project name '{opts.Name}' and the config name '{Config}' must be plain names (no '/', '\\', ':', '..' or control characters): Build writes build/<config>/<name>");
				return false;
			}
			for (let l in program.LinkInputs)
				opts.Libs.Add(new String(l));
			for (let s in program.InputStamps)
				opts.Inputs.Add(new String(s));
			var ok = Builder.Build(program, opts, Report);
			for (let l in Report.Log)
				Log(l);
			for (let e in Report.Errors)
			{
				Message(e);
				Log(scope $"ERROR: {e}");
			}
			if (ok)
				ok = CopyRunFiles(program, Report.ExePath);
			if (ok && ForRun && program.Kind == .Library)
			{
				// built, but there is nothing to start: a library is loaded by a program
				Log(scope $"Built {Report.ExePath}");
				Message(scope $"the project is a library (kind library): it built {Report.ExePath}, which a program loads; there is nothing to run");
				return false;
			}
			if (ok)
			{
				using (mLock.Enter())
					ExePath.Set(Report.ExePath);
				Log(scope $"Built {Report.ExePath}");
			}
			return ok;
		}

		/// The flags of the project file's config `config` (docs/Graph-Format.md 5, BuildSettings):
		/// `optimize`, `checks`, `debugFormat` (docs/Compiler.md 7) and the `define`s (in the link
		/// stamp; the front end reads them too). Without a project file, or for a config it does not
		/// list, the name's defaults (`Release`: optimize 2, checks off; any other: optimize 0,
		/// checks on). False (with a message) for a value that does not parse.
		bool ProjectSettings(StringView workspace, StringView config, BuildOptions opts)
		{
			opts.SetConfigDefaults(config);
			opts.DebugFormat = .Dwarf;
			if (!Directory.Exists(workspace))
				return true;
			String path = scope .();
			for (let pattern in Treadle.Format.FormatNames.ProjectPatterns)
			{
				for (let e in Directory.EnumerateFiles(workspace, pattern))
				{
					e.GetFilePath(path);
					break;
				}
				if (!path.IsEmpty)
					break;
			}
			String text = scope .();
			if (path.IsEmpty || (File.ReadAllText(path, text, true) case .Err))
				return true;
			Treadle.Model.ProjectFile project = scope .();
			List<Treadle.Format.FormatError> errors = scope .();
			defer { ClearAndDeleteItems!(errors); }
			Treadle.Format.ProjectCodec.ReadProject(text, project, errors);
			Treadle.Model.BuildSettings settings = scope .();
			List<String> bad = scope .();
			defer { ClearAndDeleteItems!(bad); }
			settings.Resolve(project, config, bad);
			for (let b in bad)
				Message(b, path);
			if (!bad.IsEmpty)
				return false;
			opts.Checks = settings.Checks;
			opts.Optimize.Set(settings.Optimize);
			opts.TargetCpu.Set(settings.Simd); // the `simd` level (SIMD-and-Vectors.md 1.7)
			opts.DebugInfo = settings.DebugInfo;
			settings.Stamp(opts.Settings..Clear());
			if (!DebugFormat.Parse(settings.DebugFormat, out opts.DebugFormat))
			{
				Message(scope $"config {config}: debugFormat '{settings.DebugFormat}' is not dwarf, codeview or both", path);
				return false;
			}
#if !BF_PLATFORM_WINDOWS
			if (opts.DebugFormat != .Dwarf)
				Log(scope $"config {config}: debugFormat {opts.DebugFormat.Text} needs a Windows build (a PDB); this build writes DWARF");
#endif
			return true;
		}

		/// A name Build may use as one file or folder name under the project's build folder: not
		/// empty, no folder separator, drive colon, `..` or control character.
		public static bool IsPlainName(StringView name)
		{
			if (name.IsEmpty || name.Contains(".."))
				return false;
			for (let c in name.RawChars)
				if (c == '/' || c == '\\' || c == ':' || (uint8)c < 0x20)
					return false;
			return true;
		}

		/// The files the program needs at run time (a C import set's DLLs) next to the exe, copied
		/// when missing or different. A `bin` cannot replace the program Build just made.
		bool CopyRunFiles(IRProgram program, StringView exe)
		{
			String dir = scope .();
			Path.GetDirectoryPath(exe, dir);
			String exeName = scope .();
			Path.GetFileName(exe, exeName);
			for (let f in program.RunFiles)
			{
				String name = scope .();
				Path.GetFileName(f, name);
				if (StringView.Compare(name, exeName, true) == 0)
				{
					Message(scope $"the file {f} (a `bin` of the C imports) has the program's own name, {exeName}: it is not copied over the program");
					return false;
				}
				String to = scope $"{dir}/{name}";
				if (!File.Exists(f))
				{
					Message(scope $"the file {f} the program needs at run time (a `bin` of its C imports) is not there");
					return false;
				}
				let srcTime = File.GetLastWriteTime(f).GetValueOrDefault();
				if (File.Exists(to) && File.GetLastWriteTime(to).GetValueOrDefault() == srcTime)
					continue;
				if (File.Copy(f, to, true) case .Err)
				{
					Message(scope $"cannot copy {f} next to the program");
					return false;
				}
				Log(scope $"Copied {f} next to the program");
			}
			return true;
		}

		public override double ElapsedMs => mWatch.Elapsed.TotalMilliseconds;
		public override int ProcessId => 0;

		public override bool Update()
		{
			bool finished;
			using (mLock.Enter())
			{
				Output.AddRange(mPendingLines);
				mPendingLines.Clear();
				Messages.AddRange(mPendingMessages);
				mPendingMessages.Clear();
				finished = mFinished;
			}
			if (!finished || mReported)
				return false;
			ThreadJoin.Join(mThread, ref mJoined);
			mWatch.Stop();
			BuildMs = mWatch.Elapsed.TotalMilliseconds;
			Running = false;
			Cancelled = mCancelRequested;
			mReported = true;
			return true;
		}

		public override void Cancel()
		{
			mCancelRequested = true;
		}

		/// Waits for the end (self tests and the command line). Update is called once at the end.
		public void WaitDone()
		{
			ThreadJoin.Join(mThread, ref mJoined);
			Update();
		}
	}

	/// The built program running from the editor (Run): stdout and stderr to the Output Log, the
	/// exit code at the end. It ends with the editor: Windows, in a job object (Stop, deleting the
	/// ProgramRun and the editor's death end it and what it started); Linux, in a process group of its
	/// own (Stop and deleting the ProgramRun end the group) and, for a killed editor, the runtime's
	/// parent-death signal (TREADLE_RUN_PARENT, tools/runtime/treadle_rt.c).
	class ProgramRun
	{
		RunningProcess mProcess = new .() { OwnGroup = true } ~ delete _;
		public String ExePath = new .() ~ delete _;
		public bool Finished;
		public int ExitCode;

		/// True when the program runs in a console window of its own (no output is captured).
		public bool InConsole;

		/// Starts the program in `workDir`, or in its own folder. `console`: in a console window of its own
		/// (Windows: the child's new console; Linux: the first terminal emulator found, else the output is
		/// captured as usual); the output is then not read here. False with `outWhy` when it could not start.
		public bool Start(StringView exe, String outWhy, Span<String> arguments = default, StringView workDir = default, bool console = false, StringView teePath = default)
		{
			ExePath.Set(exe);
			mProcess.MaxLines = 20000; // a flood of output drops the oldest unread lines (counted), never stalls the editor
			mProcess.TeePath.Set(teePath);
			String dir = scope .(workDir);
			if (dir.IsEmpty)
				Path.GetDirectoryPath(exe, dir);
			List<String> args = scope .();
			List<String> owned = scope .();
			for (let a in arguments)
				args.Add(a);
			StringView launch = exe;
			if (console)
			{
#if BF_PLATFORM_WINDOWS
				InConsole = true;
#else
				String display = scope .();
				bool hasDisplay = (Environment.GetEnvironmentVariable("DISPLAY", display) case .Ok && !display.IsEmpty);
				if (!hasDisplay)
					hasDisplay = (Environment.GetEnvironmentVariable("WAYLAND_DISPLAY", display) case .Ok && !display.IsEmpty);
				StringView[?] terminals = .("/usr/bin/x-terminal-emulator", "/usr/bin/gnome-terminal", "/usr/bin/konsole", "/usr/bin/xterm");
				if (hasDisplay)
				{
					for (let t in terminals)
					{
						if (!File.Exists(t))
							continue;
						{ let o = new String(exe); owned.Add(o); args.Insert(0, o); }
						if (t.EndsWith("gnome-terminal"))
						{
							{ let o = new String("--"); owned.Add(o); args.Insert(0, o); }
							{ let o = new String("--wait"); owned.Add(o); args.Insert(0, o); }
						}
						else
						{
							if (t.EndsWith("konsole"))
								{ let o = new String("--nofork"); owned.Add(o); args.Insert(0, o); }
							{ let o = new String("-e"); owned.Add(o); args.Insert(0, o); }
						}
						launch = t;
						InConsole = true;
						break;
					}
				}
#endif
			}
			mProcess.Capture = !InConsole;
			if (!mProcess.Start(launch, args, dir))
			{
				outWhy.Append(mProcess.Error);
				InConsole = false;
				ClearAndDeleteItems!(owned);
				return false;
			}
			
				ClearAndDeleteItems!(owned);
			return true;
		}

		/// Call once per frame: new output lines ("!" prefix: stderr). True once when it ended.
		public bool Update(List<String> outLines)
		{
			// at most about a millisecond and 500 lines per call: the editor keeps drawing under a flood
			mProcess.TakeLines(outLines, 1.0, 500);
			if (Finished || !mProcess.Done || mProcess.HasPending)
				return false;
			ExitCode = mProcess.ExitCode;
			Finished = true;
			return true;
		}

		public void Stop() => mProcess.Kill();
		public double ElapsedMs => mProcess.Watch.Elapsed.TotalMilliseconds;
		public int ProcessId => mProcess.ProcessId;
	}
}
