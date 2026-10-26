using System;
using System.Collections;
using System.IO;
using System.Threading;
using Treadle.Language;
using Treadle.Update;

namespace Treadle.Debug.Dap
{
	/// IDebugAdapter over lldb-dap (the Debug Adapter Protocol server of llvm-mingw's lldb), with
	/// Treadle's node mapping on top (docs/Debugging.md):
	///
	/// * a breakpoint on a node is a source breakpoint on `<Unit>.lst` at the node's line (the build's
	///   `.nodemap`);
	/// * a stop is mapped back from (listing file, line) to (type, Sheet, node);
	/// * a step is repeated line steps until the program is on another flow node of a Sheet (or on the
	///   same one in another call), stepping out of code that has no node (the runtime, the C library);
	/// * variables keep the debug info's names, which are the Sheet's (`pet` a local, `a2.object` the
	///   output `object` of node a2), and its types (the back end's DWARF typedefs carry Treadle's names);
	/// * a stop in the runtime's fatal path is a Fatal stop with the runtime's message, on the node of
	///   the first project frame.
	///
	/// The protocol runs on a worker thread; the UI thread queues commands and polls events, and
	/// reads the frames and variables collected at the stop.
	class LldbDapAdapter : IDebugAdapter
	{
		enum CmdKind
		{
			Continue,
			StepOver,
			StepInto,
			StepOut,
			Pause,
			Stop,
			Breakpoints,
			Evaluate,
			Children,
			/// Make another thread current while stopped (Ref: its id).
			SelectThread
		}

		class Command
		{
			public CmdKind Kind;
			public int Frame;
			public int64 Ref;
			public String Text = new .() ~ delete _;
		}

		class BpSpec
		{
			public String Path = new .() ~ delete _;
			public String Sheet = new .() ~ delete _;
			public String Node = new .() ~ delete _;
		}

		enum StepKind
		{
			None,
			Over,
			Into,
			Out
		}

		// ---- shared with the UI thread (under mLock)
		Monitor mLock = new .() ~ delete _;
		List<Command> mCommands = new .() ~ DeleteContainerAndItems!(_);
		List<DebugEvent> mEvents = new .() ~ DeleteContainerAndItems!(_);
		List<DebugFrame> mFrames = new .() ~ DeleteContainerAndItems!(_);
		List<List<DebugVariable>> mFrameVars = new .() ~ { for (let l in _) DeleteContainerAndItems!(l); delete _; };
		/// The threads at the last stop (docs/Threads.md 6).
		List<DebugThread> mThreads = new .() ~ DeleteContainerAndItems!(_);
		List<BpSpec> mBreakpoints = new .() ~ DeleteContainerAndItems!(_);
		DebugProgram mProgram;
		Thread mWorker;
		/// mWorker was joined (Treadle.Language.ThreadJoin: a thread is joined once only).
		bool mWorkerJoined;
		bool mWorkerRunning;
		String mUnavailable = new .() ~ delete _;
		/// The lldb-dap executable (TREADLE_LLDB_DAP, else llvm-mingw's bin folder).
		public String DapPath = new .() ~ delete _;
		/// Keep the protocol transcript (TREADLE_DEBUG_TRACE=1); written to TracePath at the end.
		public bool Trace;
		public String TracePath = new .() ~ delete _;

		// ---- worker thread only
		DapConnection mDap ~ delete _;
		List<UpdateJson> mDeferred = new .() ~ DeleteContainerAndItems!(_);
		String mExe = new .() ~ delete _;
		String mArgs = new .() ~ delete _;
		String mWorkDir = new .() ~ delete _;
		/// Attach to this process instead of launching mExe (0: launch).
		int32 mAttachPid;
		int64 mThreadId;
		StepKind mStep;
		int mStepCount;
		String mStepUnit = new .() ~ delete _;
		String mStepSheet = new .() ~ delete _;
		String mStepNode = new .() ~ delete _;
		int mStepDepth;
		bool mExitPosted;
		bool mQuit;
		int32 mExitCode = -1;
		bool mHaveExitCode;
		List<int64> mFrameIds = new .() ~ delete _;
		HashSet<String> mBpSources = new .() ~ DeleteContainerAndItems!(_);
		String mOutStdout = new .() ~ delete _;
		String mOutConsole = new .() ~ delete _;
		String mLastFatalLine = new .() ~ delete _;
		/// The last stop's reason and description (a thread switch reports the stop again on that thread).
		String mLastReason = new .() ~ delete _;
		String mLastDescription = new .() ~ delete _;
		/// Type names by vtable and function names by address (Summaries.bf), kept for the session.
		Dictionary<uint64, String> mVtNames = new .() ~ DeleteDictionaryAndValues!(_);
		Dictionary<uint64, String> mFnNames = new .() ~ DeleteDictionaryAndValues!(_);
		/// The children the adapter makes for containers, by ref (from cSynthBase; cleared per stop).
		Dictionary<int64, SynthNode> mSynth = new .() ~ { for (let n in _.Values) delete n; delete _; };
		int64 mNextSynth = cSynthBase;
		/// The frame an lldb variables ref belongs to (evaluate needs it for paths).
		Dictionary<int64, int64> mRefFrame = new .() ~ delete _;
		int64 mCurFrameId;

		public this()
		{
			String path = scope .();
			if (Environment.GetEnvironmentVariable("TREADLE_LLDB_DAP", path) case .Ok && !path.IsEmpty)
				DapPath.Set(path);
			else
			{
				Treadle.Language.LlvmRoot.Tool("lldb-dap", DapPath);
			}
			String trace = scope .();
			if (Environment.GetEnvironmentVariable("TREADLE_DEBUG_TRACE", trace) case .Ok && !trace.IsEmpty)
			{
				// TREADLE_DEBUG_TRACE=<file>: the protocol transcript of each session is written there.
				Trace = true;
				if (trace != "1")
					TracePath.Set(trace);
			}
		}

		public ~this()
		{
			if (mWorker != null)
			{
				bool running;
				using (mLock.Enter())
					running = mWorkerRunning;
				if (running)
					Queue(.Stop);
				if (!ThreadJoin.Join(mWorker, ref mWorkerJoined, 8000))
					mDap?.Kill();
				// The worker uses this object: it must be gone before the fields are.
				ThreadJoin.Join(mWorker, ref mWorkerJoined);
				delete mWorker;
			}
		}

		public bool Available => File.Exists(DapPath);

		public StringView Unavailable
		{
			get
			{
				mUnavailable.Clear();
#if BF_PLATFORM_WINDOWS
				mUnavailable.AppendF("The debugger (lldb-dap) is not installed: {} is missing. Set TREADLE_LLVM to the llvm-mingw folder.", DapPath);
#else
				mUnavailable.AppendF("The debugger (lldb-dap) is not installed: {} is missing. Install lldb-22 (docs/Linux.md) or set TREADLE_LLDB_DAP.", DapPath);
#endif
				return mUnavailable;
			}
		}

		public void SetProgram(DebugProgram program)
		{
			using (mLock.Enter())
				mProgram = program;
		}

		public Result<void> Launch(StringView exePath, StringView args, StringView workDir, String outError)
		{
			return Start(exePath, args, workDir, 0, outError);
		}

		/// Attaches to a running Debug build of the program (DAP attach by process id); the
		/// program's node map is the one SetProgram gave.
		public Result<void> Attach(int32 processId, String outError)
		{
			String exe = scope .();
			String dir = scope .();
			using (mLock.Enter())
			{
				if (mProgram != null)
				{
					exe.Set(mProgram.ExePath);
					dir.Set(mProgram.BuildDir);
				}
			}
			if (processId <= 0)
			{
				outError?.Set("No process to attach to.");
				return .Err;
			}
			return Start(exe, "", dir, processId, outError);
		}

		Result<void> Start(StringView exePath, StringView args, StringView workDir, int32 attachPid, String outError)
		{
			if (mWorker != null)
			{
				bool running;
				using (mLock.Enter())
					running = mWorkerRunning;
				// The last session may still be closing lldb-dap (a few seconds at most).
				if (running && !ThreadJoin.Join(mWorker, ref mWorkerJoined, 10000))
				{
					outError?.Set("A debugging session is already running.");
					return .Err;
				}
				ThreadJoin.Join(mWorker, ref mWorkerJoined);
				DeleteAndNullify!(mWorker);
			}
			if (!Available)
			{
				outError?.Set(Unavailable);
				return .Err;
			}
			if (mProgram == null)
			{
				outError?.Set("No program to debug (build it in Debug first).");
				return .Err;
			}
			delete mDap;
			mDap = new .();
			mDap.Trace = Trace;
			List<String> dapArgs = scope .() { "--no-lldbinit" };
			String why = scope .();
			if (!mDap.Start(DapPath, dapArgs, why))
			{
				outError?.Set(why);
				DeleteAndNullify!(mDap);
				return .Err;
			}
			mExe.Set(exePath);
			mArgs.Set(args);
			mWorkDir.Set(workDir);
			mAttachPid = attachPid;
			ClearAndDeleteItems!(mDeferred);
			mStep = .None;
			mExitPosted = false;
			mQuit = false;
			mExitCode = -1;
			mHaveExitCode = false;
			mThreadId = 0;
			for (let s in mBpSources)
				delete s;
			mBpSources.Clear();
			mOutStdout.Clear();
			mOutConsole.Clear();
			mLastFatalLine.Clear();
			for (let v in mVtNames.Values)
				delete v;
			mVtNames.Clear();
			for (let v in mFnNames.Values)
				delete v;
			mFnNames.Clear();
			ClearSynth();
			using (mLock.Enter())
			{
				ClearSnapshot();
				ClearAndDeleteItems!(mCommands);
				mWorkerRunning = true;
			}
			mWorker = new Thread(new => Work);
			mWorkerJoined = false;
			mWorker.SetName("Treadle debugger");
			mWorker.Start(false);
			return .Ok;
		}


		public void SetBreakpoints(List<DebugBreakpoint> breakpoints)
		{
			using (mLock.Enter())
			{
				ClearAndDeleteItems!(mBreakpoints);
				for (let b in breakpoints)
				{
					if (!b.Enabled)
						continue;
					BpSpec s = new .();
					s.Path.Set(b.Path);
					s.Sheet.Set(b.SheetKey);
					s.Node.Set(b.NodeKey);
					mBreakpoints.Add(s);
				}
				if (mWorkerRunning)
				{
					Command c = new .();
					c.Kind = .Breakpoints;
					mCommands.Add(c);
				}
			}
		}

		void Queue(CmdKind kind, int frame = 0, int64 reference = 0, StringView text = "")
		{
			Command c = new .();
			c.Kind = kind;
			c.Frame = frame;
			c.Ref = reference;
			c.Text.Set(text);
			using (mLock.Enter())
			{
				if (!mWorkerRunning)
				{
					delete c;
					return;
				}
				mCommands.Add(c);
			}
		}

		public void Continue() => Queue(.Continue);
		public void StepOver() => Queue(.StepOver);
		public void StepInto() => Queue(.StepInto);
		public void StepOut() => Queue(.StepOut);
		public void Pause() => Queue(.Pause);
		public void Stop() => Queue(.Stop);
		public void Evaluate(int frameIndex, StringView expression) => Queue(.Evaluate, frameIndex, 0, expression);
		public void RequestChildren(int64 childrenRef) => Queue(.Children, 0, childrenRef);
		public void SelectThread(int64 threadId) => Queue(.SelectThread, 0, threadId);

		public void GetThreads(List<DebugThread> outThreads)
		{
			using (mLock.Enter())
			{
				for (let t in mThreads)
				{
					DebugThread c = new .();
					c.Id = t.Id;
					c.Name.Set(t.Name);
					c.Current = t.Current;
					outThreads.Add(c);
				}
			}
		}

		public void Poll(List<DebugEvent> outEvents)
		{
			using (mLock.Enter())
			{
				outEvents.AddRange(mEvents);
				mEvents.Clear();
			}
		}

		public void GetFrames(List<DebugFrame> outFrames)
		{
			using (mLock.Enter())
			{
				for (let f in mFrames)
					outFrames.Add(CloneFrame(f));
			}
		}

		public void GetVariables(int frameIndex, List<DebugVariable> outVars)
		{
			using (mLock.Enter())
			{
				if (frameIndex < 0 || frameIndex >= mFrameVars.Count)
					return;
				for (let v in mFrameVars[frameIndex])
					outVars.Add(v.Clone());
			}
		}

		static DebugFrame CloneFrame(DebugFrame f)
		{
			DebugFrame c = new .();
			c.Name.Set(f.Name);
			c.Path.Set(f.Path);
			c.Unit.Set(f.Unit);
			c.SheetKey.Set(f.SheetKey);
			c.SheetName.Set(f.SheetName);
			c.NodeKey.Set(f.NodeKey);
			c.NodeTitle.Set(f.NodeTitle);
			c.Line = f.Line;
			c.IsUser = f.IsUser;
			return c;
		}

		void ClearSnapshot()
		{
			ClearAndDeleteItems!(mFrames);
			ClearAndDeleteItems!(mThreads);
			for (let l in mFrameVars)
				DeleteContainerAndItems!(l);
			mFrameVars.Clear();
		}

		void Post(DebugEvent e)
		{
			using (mLock.Enter())
				mEvents.Add(e);
		}

		void PostOutput(StringView text, bool fromProgram)
		{
			DebugEvent e = new .();
			e.Kind = .Output;
			e.Text.Set(text);
			e.FromProgram = fromProgram;
			Post(e);
		}

		// ------------------------------------------------------------------ worker

		void Work()
		{
			if (!Handshake())
			{
				FlushOutput();
				PostExit();
			}
			while (!mQuit)
			{
				bool busy = false;
				while (!mDeferred.IsEmpty && !mQuit)
				{
					let m = mDeferred[0];
					mDeferred.RemoveAt(0);
					Handle(m);
					delete m;
					busy = true;
				}
				while (!mQuit)
				{
					let m = mDap.Take();
					if (m == null)
						break;
					Handle(m);
					delete m;
					busy = true;
				}
				Command cmd = null;
				using (mLock.Enter())
				{
					if (!mCommands.IsEmpty)
					{
						cmd = mCommands[0];
						mCommands.RemoveAt(0);
					}
				}
				if (cmd != null && !mQuit)
				{
					Execute(cmd);
					busy = true;
				}
				delete cmd;
				if (!mQuit && ServiceInspect()) busy = true; // DapInspect.bf: the Memory and Disassembly panels
				if (!mQuit && mDap.Closed && mDeferred.IsEmpty)
				{
					// lldb-dap ended (or crashed) without saying the program ended.
					let m = mDap.Take();
					if (m == null)
					{
						FlushOutput();
						PostExit();
					}
					else
						mDeferred.Add(m);
				}
				if (!busy && !mQuit)
					Thread.Sleep(4);
			}
			// The session is over: the server is told to end the program (a program it attached to
			// is detached from and keeps running), then stopped.
			if (mDap.IsAlive)
			{
				let seq = mDap.Send("disconnect", (mAttachPid != 0) ? "{\"terminateDebuggee\":false}" : "{\"terminateDebuggee\":true}");
				delete Wait(seq, 3000);
				if (!mDap.WaitExit(2000))
					mDap.Kill();
			}
			if (Trace && !TracePath.IsEmpty)
			{
				String text = scope .();
				for (let l in mDap.TraceLines)
					text.AppendF("{}\n", l);
				File.WriteAllText(TracePath, text).IgnoreError();
			}
			using (mLock.Enter())
				mWorkerRunning = false;
		}

		void PostExit()
		{
			if (mExitPosted)
				return;
			mExitPosted = true;
			mQuit = true;
			DebugEvent e = new .();
			e.Kind = .Exited;
			e.ExitCode = mHaveExitCode ? mExitCode : -1;
			Post(e);
		}

		/// Sends a request and waits for its response (other messages are kept for the loop).
		/// The caller owns the response; null on timeout or when the server ended.
		UpdateJson Request(StringView command, StringView args, int timeoutMs = 10000)
		{
			let seq = mDap.Send(command, args);
			return Wait(seq, timeoutMs);
		}

		UpdateJson Wait(int32 seq, int timeoutMs)
		{
			let start = Internal.GetTickCountMicro();
			while (true)
			{
				let m = mDap.Take();
				if (m != null)
				{
					if (Str(m, "type") == "response" && Int(m, "request_seq") == seq)
						return m;
					mDeferred.Add(m);
					continue;
				}
				if (mDap.Closed)
					return null;
				if ((int)(Internal.GetTickCountMicro() - start) / 1000 > timeoutMs)
					return null;
				Thread.Sleep(1);
			}
		}

		/// Waits for an event by name; the event is returned (caller owns it), others are kept.
		UpdateJson WaitEvent(StringView name, int timeoutMs)
		{
			let start = Internal.GetTickCountMicro();
			List<UpdateJson> kept = scope .();
			defer { for (let k in kept) mDeferred.Add(k); }
			while (true)
			{
				let m = mDap.Take();
				if (m != null)
				{
					if (Str(m, "type") == "event" && Str(m, "event") == name)
						return m;
					kept.Add(m);
					continue;
				}
				if (mDap.Closed)
					return null;
				if ((int)(Internal.GetTickCountMicro() - start) / 1000 > timeoutMs)
					return null;
				Thread.Sleep(1);
			}
		}

		/// A program linked with `debugFormat codeview` (the build's `debug-format.txt` says so) has
		/// its symbols in `<exe>.pdb` only, while mingw's CRT objects still bring DWARF that lldb would
		/// pick: lldb is given the PDB explicitly (`target symbols add`, before the program runs).
		/// `dwarf` and `both` builds carry the program's DWARF in the exe: nothing is added.
		void SymbolCommands(String json)
		{
			if (mExe.IsEmpty)
				return;
			String dir = scope .();
			Path.GetDirectoryPath(mExe, dir).IgnoreError();
			String format = scope .();
			if (File.ReadAllText(scope $"{dir}/debug-format.txt", format, true) case .Err)
				return;
			format.Trim();
			if (format != "codeview")
				return;
			String pdb = scope .();
			Path.ChangeExtension(mExe, ".pdb", pdb);
			if (!File.Exists(pdb))
				return;
			json.Append(",\"preRunCommands\":[");
			UpdateJson.WriteString(scope $"target symbols add \"{pdb}\"", json);
			json.Append(']');
		}

		bool Handshake()
		{
			let init = Request("initialize", "{\"clientID\":\"treadle\",\"clientName\":\"Treadle\",\"adapterID\":\"lldb-dap\",\"linesStartAt1\":true,\"columnsStartAt1\":true,\"pathFormat\":\"path\",\"supportsVariableType\":true,\"supportsMemoryReferences\":true}", 15000);
			if (init == null || !init.GetBool("success", false))
			{
				PostOutput("The debugger (lldb-dap) did not start.", false);
				delete init;
				return false;
			}
			delete init;
			String a = scope .();
			int32 launchSeq;
			if (mAttachPid != 0)
			{
				// attach: lldb-dap stops the process, takes the breakpoints and resumes it at
				// configurationDone
				a.AppendF("{{\"pid\":{}", mAttachPid);
				// a library build (the process is its host): no `program`, lldb takes the host's
				// executable from the process and the library's DWARF from the loaded module; the
				// library's path stays in mExe for SymbolCommands (its PDB)
				if (!mExe.IsEmpty && !mExe.EndsWith(".dll", .OrdinalIgnoreCase) && !mExe.EndsWith(".so"))
				{
					a.Append(",\"program\":");
					UpdateJson.WriteString(mExe, a);
				}
				SymbolCommands(a);
				a.Append("}");
				launchSeq = mDap.Send("attach", a);
			}
			else
			{
				a.Append("{\"program\":");
				UpdateJson.WriteString(mExe, a);
				a.Append(",\"cwd\":");
				UpdateJson.WriteString(mWorkDir, a);
				a.Append(",\"args\":[");
				int n = 0;
				for (var part in mArgs.Split(' ', .RemoveEmptyEntries))
				{
					if (n++ > 0)
						a.Append(',');
					UpdateJson.WriteString(part, a);
				}
				a.Append(']');
				SymbolCommands(a);
				a.Append(",\"stopOnEntry\":false}");
				launchSeq = mDap.Send("launch", a);
			}
			let initialized = WaitEvent("initialized", 20000);
			if (initialized == null)
			{
				PostOutput("The debugger did not get ready (no 'initialized' event).", false);
				return false;
			}
			delete initialized;
			SendBreakpoints();
			delete Request("configurationDone", "{}", 15000);
			let launched = Wait(launchSeq, 30000);
			if (launched == null || !launched.GetBool("success", false))
			{
				String msg = scope .();
				if (launched != null)
					launched.GetString("message", msg);
				if (mAttachPid != 0)
					PostOutput(scope $"Could not attach to process {mAttachPid}: {msg}", false);
				else
					PostOutput(scope $"Could not start {mExe}: {msg}", false);
				delete launched;
				return false;
			}
			delete launched;
			DebugEvent e = new .();
			e.Kind = .Started;
			Post(e);
			return true;
		}

		/// Breakpoints by listing file and line, one setBreakpoints per listing.
		void SendBreakpoints()
		{
			Dictionary<String, List<int32>> bySource = scope .();
			defer { for (let kv in bySource) { delete kv.key; delete kv.value; } }
			using (mLock.Enter())
			{
				if (mProgram == null)
					return;
				for (let b in mBreakpoints)
				{
					String unit = scope .();
					if (!mProgram.UnitOfPath(b.Path, unit))
					{
						PostOutput(scope $"Breakpoint skipped: {b.Path} is not part of the program that was built.", false);
						continue;
					}
					let line = mProgram.LineOf(unit, b.Sheet, b.Node);
					if (line <= 0)
					{
						PostOutput(scope $"Breakpoint skipped: node {b.Node} of {unit} has no code in this build (rebuild after editing).", false);
						continue;
					}
					String src = scope .();
					src.AppendF("{}/{}.lst", mProgram.BuildDir, unit);
#if BF_PLATFORM_WINDOWS
					src.Replace('/', '\\');
#endif
					if (!bySource.TryGetValue(src, var lines))
					{
						lines = new .();
						bySource[new String(src)] = lines;
					}
					lines.Add(line);
				}
			}
			// Listings that had breakpoints and have none now are cleared.
			for (let old in mBpSources)
				if (!bySource.ContainsKey(old))
					bySource[new String(old)] = new .();
			for (let s in mBpSources)
				delete s;
			mBpSources.Clear();
			for (let kv in bySource)
			{
				String a = scope .();
				String name = scope .();
				Path.GetFileName(kv.key, name);
				a.Append("{\"source\":{\"name\":");
				UpdateJson.WriteString(name, a);
				a.Append(",\"path\":");
				UpdateJson.WriteString(kv.key, a);
				a.Append("},\"breakpoints\":[");
				for (let l in kv.value)
				{
					if (@l.Index > 0)
						a.Append(',');
					a.AppendF("{{\"line\":{}}}", l);
				}
				a.Append("]}");
				delete Request("setBreakpoints", a);
				if (!kv.value.IsEmpty)
					mBpSources.Add(new String(kv.key));
			}
		}

		void Execute(Command c)
		{
			switch (c.Kind)
			{
			case .Continue:
				mStep = .None;
				delete Request("continue", scope $"{{\"threadId\":{mThreadId}}}");
			case .StepOver, .StepInto, .StepOut:
				BeginStep((c.Kind == .StepOver) ? .Over : (c.Kind == .StepInto) ? .Into : .Out);
			case .Pause:
				delete Request("pause", scope $"{{\"threadId\":{ThreadForRequests()}}}");
			case .Stop:
				mQuit = true;
				FlushOutput();
			case .Breakpoints:
				SendBreakpoints();
			case .Evaluate:
				DoEvaluate(c.Frame, c.Text);
			case .Children:
				DoChildren(c.Ref);
			case .SelectThread:
				if (c.Ref != 0 && c.Ref != mThreadId)
				{
					mThreadId = c.Ref;
					Snapshot(mLastReason, mLastDescription);
				}
			}
		}

		int64 ThreadForRequests()
		{
			if (mThreadId != 0)
				return mThreadId;
			let r = Request("threads", "");
			defer delete r;
			let threads = r?.Get("body")?.Get("threads");
			if (threads != null && threads.IsArray && !threads.Items.IsEmpty)
				mThreadId = Int(threads.Items[0], "id");
			return mThreadId;
		}

		void Handle(UpdateJson m)
		{
			if (Str(m, "type") != "event")
				return;
			let body = m.Get("body");
			switch (Str(m, "event"))
			{
			case "output":
				OnOutput(body);
			case "stopped":
				OnStopped(body);
			case "exited":
				if (body != null)
				{
					mExitCode = (int32)Int(body, "exitCode", -1);
					mHaveExitCode = true;
				}
			case "terminated":
				FlushOutput();
				PostExit();
			case "process":
			default:
			}
		}

		void OnOutput(UpdateJson body)
		{
			if (body == null)
				return;
			let category = Str(body, "category");
			let text = Str(body, "output");
			bool program = category == "stdout" || category == "stderr";
			if (category == "telemetry")
				return;
			let buf = program ? mOutStdout : mOutConsole;
			buf.Append(text);
			while (true)
			{
				let nl = buf.IndexOf('\n');
				if (nl < 0)
					break;
				String line = scope .(buf, 0, nl);
				buf.Remove(0, nl + 1);
				if (line.EndsWith('\r'))
					line.RemoveFromEnd(1);
				if (!program && (line.StartsWith("To get started with the debug console") || line.StartsWith("For more information visit https://lldb.llvm.org")))
					continue;
				if (program && line.StartsWith("fatal: "))
					mLastFatalLine.Set(line);
				PostOutput(line, program);
			}
		}

		void FlushOutput()
		{
			if (!mOutStdout.IsEmpty)
			{
				PostOutput(mOutStdout, true);
				mOutStdout.Clear();
			}
			if (!mOutConsole.IsEmpty)
			{
				PostOutput(mOutConsole, false);
				mOutConsole.Clear();
			}
		}

		// ------------------------------------------------------------------ stops and steps

		/// A DAP stack frame mapped to the program's node map.
		void MapFrame(UpdateJson f, DebugFrame outFrame)
		{
			f.GetString("name", outFrame.Name);
			outFrame.Line = (int32)Int(f, "line");
			let src = f.Get("source");
			if (src == null)
				return;
			String path = scope .();
			if (!src.GetString("path", path) || !path.EndsWith(".lst", .OrdinalIgnoreCase))
				return;
			String unit = scope .();
			DebugProgram.UnitOfListing(path, unit);
			outFrame.Unit.Set(unit);
			using (mLock.Enter())
			{
				if (mProgram == null)
					return;
				let u = mProgram.FindUnit(unit);
				if (u == null)
					return;
				if (!mProgram.NodeAt(unit, outFrame.Line, outFrame.SheetKey, outFrame.NodeKey))
					return;
				let s = u.FindSheet(outFrame.SheetKey);
				if (s != null)
				{
					outFrame.SheetName.Set(s.Name);
					var n = s.FindNode(outFrame.NodeKey);
					// The code of a value node runs for the flow node that reads it: the stop is
					// before that flow node (its inputs are being evaluated).
					if (n != null && !n.Flow && !n.Consumer.IsEmpty)
					{
						let c = s.FindNode(n.Consumer);
						if (c != null)
						{
							outFrame.NodeKey.Set(c.Key);
							n = c;
						}
					}
					if (n != null)
						outFrame.NodeTitle.Set(n.Title);
				}
				outFrame.Path.Set(u.Path);
				outFrame.IsUser = !u.Path.IsEmpty;
			}
		}

		/// The stack of a thread: mapped frames and their protocol ids. Returns the depth.
		int ReadStack(int64 threadId, List<DebugFrame> outFrames, List<int64> outIds, int levels)
		{
			let r = Request("stackTrace", scope $"{{\"threadId\":{threadId},\"startFrame\":0,\"levels\":{levels}}}");
			defer delete r;
			let body = r?.Get("body");
			let frames = body?.Get("stackFrames");
			if (frames == null || !frames.IsArray)
				return 0;
			for (let f in frames.Items)
			{
				DebugFrame df = new .();
				MapFrame(f, df);
				outFrames.Add(df);
				outIds?.Add(Int(f, "id"));
			}
			let total = Int(body, "totalFrames", frames.Items.Count);
			return (int)Math.Max(total, frames.Items.Count);
		}

		bool NodeIsFlow(DebugFrame f)
		{
			using (mLock.Enter())
			{
				let n = mProgram?.FindNode(f.Unit, f.SheetKey, f.NodeKey);
				return n == null || n.Flow;
			}
		}

		void BeginStep(StepKind kind)
		{
			List<DebugFrame> frames = scope .();
			defer { ClearAndDeleteItems!(frames); }
			let depth = ReadStack(mThreadId, frames, null, 64);
			mStepUnit.Clear();
			mStepSheet.Clear();
			mStepNode.Clear();
			mStepDepth = depth;
			mStepCount = 0;
			mStep = kind;
			if (!frames.IsEmpty)
			{
				mStepUnit.Set(frames[0].Unit);
				mStepSheet.Set(frames[0].SheetKey);
				mStepNode.Set(frames[0].NodeKey);
				if (!frames[0].IsUser && kind != .Out)
				{
					// Stopped outside the project (a fault in the runtime): step out to the project.
					bool userBelow = false;
					for (let f in frames)
						if (f.IsUser)
							userBelow = true;
					if (userBelow)
					{
						Primitive("stepOut");
						return;
					}
				}
			}
			switch (kind)
			{
			case .Over: Primitive("next");
			case .Into: Primitive("stepIn");
			case .Out: Primitive("stepOut");
			case .None:
			}
		}

		void Primitive(StringView command)
		{
			delete Request(command, scope $"{{\"threadId\":{mThreadId},\"granularity\":\"line\"}}");
		}

		/// After a line step: true when another one was started (the step is not done yet).
		bool ContinueStep()
		{
			mStepCount++;
			List<DebugFrame> frames = scope .();
			defer { ClearAndDeleteItems!(frames); }
			let depth = ReadStack(mThreadId, frames, null, 64);
			if (frames.IsEmpty)
				return false;
			let top = frames[0];
			bool userBelow = false;
			for (int i = 1; i < frames.Count; i++)
				if (frames[i].IsUser)
					userBelow = true;
			if (top.IsUser)
			{
				bool moved = top.NodeKey != mStepNode || top.SheetKey != mStepSheet || top.Unit != mStepUnit || depth != mStepDepth;
				if ((moved && NodeIsFlow(top)) || mStepCount > 400)
					return false;
				Primitive((mStep == .Into) ? "stepIn" : "next");
				return true;
			}
			if (userBelow && mStepCount <= 400)
			{
				Primitive("stepOut");
				return true;
			}
			// Past the last node of the program (Main returned): run to the end.
			mStep = .None;
			delete Request("continue", scope $"{{\"threadId\":{mThreadId}}}");
			return true;
		}

		void OnStopped(UpdateJson body)
		{
			if (body == null)
				return;
			let reason = Str(body, "reason");
			let tid = Int(body, "threadId");
			if (tid != 0)
				mThreadId = tid;
			if (mStep != .None && reason == "step" && ContinueStep())
				return;
			mStep = .None;
			String description = scope .();
			body.GetString("description", description);
			if (reason == "pause")
				PickThreadWithNode();
			Snapshot(reason, description);
		}

		/// After Pause: the thread that is in project code (the break-in thread is not).
		void PickThreadWithNode()
		{
			let r = Request("threads", "");
			defer delete r;
			let threads = r?.Get("body")?.Get("threads");
			if (threads == null || !threads.IsArray)
				return;
			for (let t in threads.Items)
			{
				let id = Int(t, "id");
				List<DebugFrame> frames = scope .();
				defer { ClearAndDeleteItems!(frames); }
				ReadStack(id, frames, null, 64);
				for (let f in frames)
					if (f.IsUser)
					{
						mThreadId = id;
						return;
					}
			}
		}

		/// The program's threads (lldb-dap `threads`): id and name, the current one (mThreadId) marked.
		/// A thread without a name is `Thread <id>`.
		List<DebugThread> ReadThreads(int64 frameId = 0)
		{
			List<DebugThread> list = new .();
			// Right after a thread started, lldb-dap may list the threads it knew before the stop without the
			// one that stopped: asked again (a few times, 50 ms apart) until it is there.
			UpdateJson r = null;
			UpdateJson threads = null;
			for (int attempt < 4)
			{
				if (r != null)
					delete r;
				r = Request("threads", "");
				threads = r?.Get("body")?.Get("threads");
				bool found = mThreadId == 0;
				if (threads != null && threads.IsArray)
					for (let t in threads.Items)
						if (Int(t, "id") == mThreadId)
							found = true;
				if (found)
					break;
				Thread.Sleep(50);
			}
			defer { if (r != null) delete r; }
			if (threads == null || !threads.IsArray)
				return list;
			// The runtime's table "<system id> <name>" per line (treadle_rt.c, rt_debug_thread_names): lldb's
			// thread id is the system's.
			Dictionary<int64, String> runtimeNames = scope .();
			defer { for (let v in runtimeNames.Values) delete v; }
			{
				// Right after a stop, lldb-dap on Linux may still answer "can't evaluate expressions when the
				// process is running" (the stack was read already): asked again, a few times, 50 ms apart.
				UpdateJson e = null;
				for (int attempt < 6)
				{
					if (e != null)
						delete e;
					e = Request("evaluate", (frameId != 0)
						? scope:: $"{{\"expression\":\"rt_debug_thread_names\",\"frameId\":{frameId},\"context\":\"watch\"}}"
						: "{\"expression\":\"rt_debug_thread_names\",\"context\":\"watch\"}");
					if (e == null || e.GetBool("success", false))
						break;
					String why = scope .();
					e.Get("body")?.Get("error")?.GetString("format", why);
					if (!why.Contains("running"))
						break;
					Thread.Sleep(50);
				}
				String v = scope .();
				e?.Get("body")?.GetString("result", v);
				delete e;
				String text = scope .();
				QuotedText(v, text);
				for (let line in text.Split('\n'))
				{
					let sp = line.IndexOf(' ');
					if (sp <= 0)
						continue;
					if (int64.Parse(line.Substring(0, sp)) case .Ok(let tid))
					{
						if (runtimeNames.TryGetValue(tid, let old))
							old.Set(line.Substring(sp + 1));
						else
							runtimeNames[tid] = new String(line.Substring(sp + 1));
					}
				}
			}
			for (let t in threads.Items)
			{
				DebugThread d = new .();
				d.Id = Int(t, "id");
				if (runtimeNames.TryGetValue(d.Id, let known))
					d.Name.Set(known);
				else
				{
					t.GetString("name", d.Name);
					ThreadName(d.Name, d.Id);
				}
				d.Current = d.Id == mThreadId;
				list.Add(d);
			}
			// still not listed: the stopped thread is added by itself (its stack is read by id)
			bool listed = false;
			for (let d in list)
				listed |= d.Current;
			if (!listed && mThreadId != 0)
			{
				DebugThread d = new .();
				d.Id = mThreadId;
				if (runtimeNames.TryGetValue(d.Id, let known))
					d.Name.Set(known);
				else
					d.Name.AppendF("Thread {}", d.Id);
				d.Current = true;
				list.Add(d);
			}
			return list;
		}

		/// lldb names a thread `Thread <n>` or `<name>` (some versions add ` tid = ...`, `: tid = ...` or a
		/// quoted name): the thread's own name when it has one.
		static void ThreadName(String name, int64 id)
		{
			int q0 = name.IndexOf('\'');
			int q1 = (q0 >= 0) ? name.IndexOf('\'', q0 + 1) : -1;
			if (q0 >= 0 && q1 > q0)
			{
				name.Set(StringView(name, q0 + 1, q1 - q0 - 1));
				return;
			}
			let tid = name.IndexOf(" tid");
			if (tid >= 0)
				name.RemoveToEnd(tid);
			name.Trim();
			if (name.EndsWith(':') || name.EndsWith(','))
				name.RemoveFromEnd(1);
			if (name.IsEmpty)
				name.AppendF("Thread {}", id);
		}

		void Snapshot(StringView reason, StringView description)
		{
			// a thread switch passes the last stop's own fields: copy them first
			String reasonCopy = scope .(reason);
			String descriptionCopy = scope .(description);
			mLastReason.Set(reasonCopy);
			mLastDescription.Set(descriptionCopy);
			var reason;
			reason = reasonCopy;
			var description;
			description = descriptionCopy;
			List<DebugFrame> frames = new .();
			List<int64> ids = scope .();
			ReadStack(mThreadId, frames, ids, 48);
			let threadList = ReadThreads(ids.IsEmpty ? 0 : ids[0]);
			ClearSynth();
			StopReason why = .Breakpoint;
			switch (reason)
			{
			case "step": why = .Step;
			case "pause": why = .Pause;
			case "entry": why = .Entry;
			case "exception": why = .Exception;
			case "breakpoint", "function breakpoint", "data breakpoint", "instruction breakpoint": why = .Breakpoint;
			default: why = .Exception;
			}
			String message = scope .();
			// The runtime's fatal path (rt_fatal -> fatal_text, which breaks into the debugger).
			int fatalFrame = -1;
			for (let f in frames)
				if (f.Name.StartsWith("fatal_text") || f.Name.StartsWith("rt_fatal"))
				{
					fatalFrame = @f.Index;
					if (f.Name.StartsWith("fatal_text"))
						break;
				}
			if (fatalFrame >= 0)
			{
				why = .Fatal;
				if (frames[fatalFrame].Name.StartsWith("fatal_text"))
				{
					let r = Request("evaluate", scope $"{{\"expression\":\"text\",\"frameId\":{ids[fatalFrame]},\"context\":\"watch\"}}");
					String v = scope .();
					r?.Get("body")?.GetString("result", v);
					delete r;
					QuotedText(v, message);
				}
				if (message.IsEmpty)
					message.Set(mLastFatalLine);
				if (message.IsEmpty)
					message.Set("The runtime reported a fatal error.");
			}
			else if (why == .Exception)
				message.Set(description);
			// Variables of the project's frames.
			List<List<DebugVariable>> vars = new .();
			int fetched = 0;
			for (let f in frames)
			{
				List<DebugVariable> list = new .();
				if (f.IsUser && fetched < 16)
				{
					fetched++;
					ReadFrameVariables(ids[@f.Index], f, list);
				}
				vars.Add(list);
			}
			using (mLock.Enter())
			{
				ClearSnapshot();
				for (let f in frames)
					mFrames.Add(f);
				delete frames;
				mThreads.AddRange(threadList);
				delete threadList;
				for (let l in vars)
					mFrameVars.Add(l);
				delete vars;
			}
			mFrameIds.Clear();
			mFrameIds.AddRange(ids);
			DebugEvent e = new .();
			e.Kind = .Stopped;
			e.Reason = why;
			e.Text.Set(message);
			Post(e);
		}

		/// `0x00007ff6... "fatal: double free ..."` -> the text in the quotes.
		static void QuotedText(StringView value, String outText)
		{
			let q0 = value.IndexOf('"');
			let q1 = value.LastIndexOf('"');
			if (q0 < 0 || q1 <= q0)
				return;
			let inner = value.Substring(q0 + 1, q1 - q0 - 1);
			for (int i < inner.Length)
			{
				let c = inner[i];
				if (c == '\\' && i + 1 < inner.Length)
				{
					i++;
					switch (inner[i])
					{
					case 'n': outText.Append('\n');
					case 't': outText.Append('\t');
					default: outText.Append(inner[i]);
					}
				}
				else
					outText.Append(c);
			}
		}

		// ------------------------------------------------------------------ variables

		void ReadFrameVariables(int64 frameId, DebugFrame frame, List<DebugVariable> outVars)
		{
			mCurFrameId = frameId;
			let sr = Request("scopes", scope $"{{\"frameId\":{frameId}}}");
			defer delete sr;
			let scopes = sr?.Get("body")?.Get("scopes");
			if (scopes == null || !scopes.IsArray)
				return;
			for (let s in scopes.Items)
			{
				let name = Str(s, "name");
				let hint = Str(s, "presentationHint");
				if (name != "Locals" && name != "Arguments" && hint != "locals" && hint != "arguments")
					continue;
				let vr = Request("variables", scope $"{{\"variablesReference\":{Int(s, "variablesReference")}}}");
				defer delete vr;
				let list = vr?.Get("body")?.Get("variables");
				if (list == null || !list.IsArray)
					continue;
				for (let v in list.Items)
				{
					DebugVariable dv = new .();
					MapVariable(v, frame, dv);
					outVars.Add(dv);
				}
			}
			// The panel order: this, parameters, locals, then pin values by node.
			outVars.Sort(scope (a, b) =>
				{
					int c = Rank(a.Kind) <=> Rank(b.Kind);
					if (c != 0)
						return c;
					return String.Compare(a.Name, b.Name, false);
				});
		}

		static int Rank(DebugVarKind k)
		{
			switch (k)
			{
			case .This: return 0;
			case .Param: return 1;
			case .Local: return 2;
			case .Pin: return 3;
			case .Other: return 4;
			}
		}

		void MapVariable(UpdateJson v, DebugFrame frame, DebugVariable dv, int depth = 0)
		{
			v.GetString("name", dv.Name);
			// lldb-dap tells two variables of one name apart with ` @ <file>:<line>`
			let at = dv.Name.IndexOf(" @ ");
			if (at > 0)
				dv.Name.RemoveToEnd(at);
			String ctype = scope .();
			v.GetString("type", ctype);
			v.GetString("value", dv.Value);
			dv.ChildrenRef = Int(v, "variablesReference");
			if (dv.ChildrenRef != 0)
				mRefFrame[dv.ChildrenRef] = mCurFrameId;
			bool isClass = false;
			using (mLock.Enter())
			{
				MapType(ctype, dv.Type, out isClass);
				if (frame != null)
				{
					let sheet = mProgram?.FindUnit(frame.Unit)?.FindSheet(frame.SheetKey);
					if (dv.Name == "this")
					{
						dv.Kind = .This;
						dv.Label.Set("this");
					}
					else if (sheet != null && sheet.LocalNames.ContainsAlt(dv.Name))
					{
						dv.Kind = .Local;
						dv.Label.Set(dv.Name);
					}
					else if (dv.Name.Contains('.'))
					{
						let dot = dv.Name.IndexOf('.');
						dv.Kind = .Pin;
						dv.NodeKey.Set(dv.Name.Substring(0, dot));
						dv.Pin.Set(dv.Name.Substring(dot + 1));
						dv.Label.Set(dv.Name);
					}
					else
					{
						dv.Kind = .Param;
						dv.Label.Set(dv.Name);
					}
				}
				else
					dv.Label.Set(dv.Name);
			}
			String path = scope .();
			v.GetString("evaluateName", path);
			Present(dv, isClass, path, depth);
		}

		bool ReadPtr(uint64 addr, out uint64 value)
		{
			value = 0;
			List<uint8> bytes = scope .();
			if (!ReadMemory(addr, 8, bytes) || bytes.Count < 8)
				return false;
			for (int i < 8)
				value |= (uint64)bytes[i] << (8 * i);
			return true;
		}

		bool ReadMemory(uint64 addr, int count, List<uint8> outBytes)
		{
			let r = Request("readMemory", scope $"{{\"memoryReference\":\"0x{addr:X}\",\"offset\":0,\"count\":{count}}}");
			defer delete r;
			if (r == null || !r.GetBool("success", false))
				return false;
			String data = scope .();
			if (!(r.Get("body")?.GetString("data", data) ?? false))
				return false;
			return Base64Decode(data, outBytes);
		}

		static bool Base64Decode(StringView text, List<uint8> outBytes)
		{
			uint32 acc = 0;
			int bits = 0;
			for (let c in text.RawChars)
			{
				int v;
				if (c >= 'A' && c <= 'Z') v = c - 'A';
				else if (c >= 'a' && c <= 'z') v = c - 'a' + 26;
				else if (c >= '0' && c <= '9') v = c - '0' + 52;
				else if (c == '+') v = 62;
				else if (c == '/') v = 63;
				else if (c == '=') break;
				else continue;
				acc = (acc << 6) | (uint32)v;
				bits += 6;
				if (bits >= 8)
				{
					bits -= 8;
					outBytes.Add((uint8)((acc >> bits) & 0xFF));
				}
			}
			return true;
		}

		/// lldb's type name -> Treadle's. The basic types already come with Treadle's names (the back end
		/// describes them as typedefs: `int`, `int64`, `char8`, ...); `Zoo.Animal *` is the class
		/// reference `Zoo.Animal`.
		void MapType(StringView ctype, String outType, out bool isClass)
		{
			isClass = false;
			var t = ctype;
			t.Trim();
			if (t.StartsWith("const "))
				t = t.Substring(6);
			if (t.EndsWith("*"))
			{
				var inner = t.Substring(0, t.Length - 1);
				inner.Trim();
				String it = scope .();
				MapType(inner, it, ?);
				if (IsReference(it))
				{
					isClass = true;
					outType.Append(it);
				}
				else
					outType.AppendF("{}*", it);
				return;
			}
			outType.Append(t);
		}

		void DoChildren(int64 reference)
		{
			DebugEvent e = new .();
			e.Kind = .Children;
			e.Ref = reference;
			e.Vars = new .();
			if (mSynth.TryGetValue(reference, let node))
			{
				SynthChildren(node, e.Vars);
				Post(e);
				return;
			}
			if (mRefFrame.TryGetValue(reference, let frameId))
				mCurFrameId = frameId;
			let vr = Request("variables", scope $"{{\"variablesReference\":{reference}}}");
			let list = vr?.Get("body")?.Get("variables");
			if (list != null && list.IsArray)
				for (let v in list.Items)
				{
					DebugVariable dv = new .();
					MapVariable(v, null, dv);
					e.Vars.Add(dv);
				}
			delete vr;
			Post(e);
		}

		/// A pin or local by name (`a2.object`, `pet`), a member path on one (`pet.mLegs`), else an
		/// expression for lldb.
		void DoEvaluate(int frameIndex, StringView expression)
		{
			DebugEvent e = new .();
			e.Kind = .Evaluated;
			e.Expression.Set(expression);
			defer Post(e);
			var expr = expression;
			expr.Trim();
			List<DebugVariable> vars = scope .();
			defer { ClearAndDeleteItems!(vars); }
			GetVariables(frameIndex, vars);
			// The longest variable name (debug name or label) the expression starts with.
			DebugVariable best = null;
			int bestLen = 0;
			for (let v in vars)
			{
				for (let name in StringView[?](v.Name, v.Kind == .Local ? v.Label : v.Name))
				{
					if (name.IsEmpty || !expr.StartsWith(name))
						continue;
					if (expr.Length > name.Length && expr[name.Length] != '.')
						continue;
					if (name.Length > bestLen)
					{
						best = v;
						bestLen = name.Length;
					}
				}
			}
			if (best != null)
			{
				var rest = expr.Substring(bestLen);
				DebugVariable cur = best.Clone();
				defer delete cur;
				while (rest.StartsWith('.'))
				{
					rest = rest.Substring(1);
					var member = rest;
					let dot = rest.IndexOf('.');
					if (dot >= 0)
					{
						member = rest.Substring(0, dot);
						rest = rest.Substring(dot);
					}
					else
						rest = "";
					if (!FindMember(cur, member))
					{
						e.Failed = true;
						e.Text.AppendF("{} has no member {}", expr.Substring(0, expr.Length - rest.Length - member.Length - 1), member);
						return;
					}
				}
				e.Text.Set(cur.Value);
				e.Type.Set(cur.Type);
				e.Ref = cur.ChildrenRef;
				return;
			}
			if (frameIndex < 0 || frameIndex >= mFrameIds.Count)
			{
				e.Failed = true;
				e.Text.Set("not stopped");
				return;
			}
			// lldb's own expression (the debug info carries the Sheet's names).
			String a = scope .();
			a.Append("{\"expression\":");
			UpdateJson.WriteString(expr, a);
			a.AppendF(",\"frameId\":{},\"context\":\"watch\"}}", mFrameIds[frameIndex]);
			let r = Request("evaluate", a);
			defer delete r;
			if (r == null)
			{
				e.Failed = true;
				e.Text.Set("no answer from the debugger");
				return;
			}
			if (!r.GetBool("success", false))
			{
				e.Failed = true;
				let err = r.Get("body")?.Get("error");
				if (err == null || !err.GetString("format", e.Text))
					r.GetString("message", e.Text);
				return;
			}
			let body = r.Get("body");
			body.GetString("result", e.Text);
			String ctype = scope .();
			body.GetString("type", ctype);
			bool isClass;
			using (mLock.Enter())
				MapType(ctype, e.Type, out isClass);
			e.Ref = Int(body, "variablesReference");
			mCurFrameId = mFrameIds[frameIndex];
			if (e.Ref != 0)
				mRefFrame[e.Ref] = mCurFrameId;
			DebugVariable tmp = scope .();
			tmp.Value.Set(e.Text);
			tmp.Type.Set(e.Type);
			tmp.ChildrenRef = e.Ref;
			Present(tmp, isClass, IsPathRoot(expr) ? expr : "", 0);
			e.Text.Set(tmp.Value);
			e.Ref = tmp.ChildrenRef;
		}

		bool FindMember(DebugVariable cur, StringView member)
		{
			if (cur.ChildrenRef == 0)
				return false;
			let vr = Request("variables", scope $"{{\"variablesReference\":{cur.ChildrenRef}}}");
			defer delete vr;
			let list = vr?.Get("body")?.Get("variables");
			if (list == null || !list.IsArray)
				return false;
			for (let v in list.Items)
			{
				if (Str(v, "name") != member)
					continue;
				DebugVariable dv = scope .();
				MapVariable(v, null, dv);
				cur.Name.Set(dv.Name);
				cur.Label.Set(dv.Label);
				cur.Value.Set(dv.Value);
				cur.Type.Set(dv.Type);
				cur.ChildrenRef = dv.ChildrenRef;
				return true;
			}
			return false;
		}

		// ------------------------------------------------------------------ JSON helpers

		static StringView Str(UpdateJson j, StringView key)
		{
			let v = j?.Get(key);
			if (v == null || v.Type != .String)
				return "";
			return v.Text;
		}

		static int64 Int(UpdateJson j, StringView key, int64 def = 0)
		{
			if (j != null && j.GetInt(key, let v))
				return v;
			return def;
		}
	}
}
