using System;
using System.Collections;

namespace Treadle.Debug
{
	/// Where a debugging session is.
	enum DebugState
	{
		/// No program is being debugged.
		Idle,
		/// Launch or attach was asked for; the adapter has not reported the program running yet.
		Starting,
		Running,
		/// Stopped at a breakpoint, after a step, on pause or on an exception.
		Stopped,
		/// The program ended (or the session was stopped).
		Exited
	}

	enum StopReason
	{
		None,
		Entry,
		Breakpoint,
		Step,
		Pause,
		Exception,
		/// The runtime reported a fatal error (double free, use of a deleted object, a Fatal
		/// node, a failed check): the message is in DebugEvent.Text / DebugSession.StopMessage.
		Fatal
	}

	/// What a debug adapter reports between two polls.
	enum DebugEventKind
	{
		Started,
		Stopped,
		Continued,
		Exited,
		/// Program or adapter output (Text, one line).
		Output,
		/// The answer to Evaluate (Expression, Text = value or error, Type, Ref, Failed).
		Evaluated,
		/// The answer to RequestChildren (Ref, Vars).
		Children
	}

	class DebugEvent
	{
		public DebugEventKind Kind;
		public StopReason Reason;
		public String Text = new .() ~ delete _;
		public int32 ExitCode;
		public String Expression = new .() ~ delete _;
		public String Type = new .() ~ delete _;
		public int64 Ref;
		public bool Failed;
		/// Output: written by the program (false: the debugger's own messages).
		public bool FromProgram;
		public List<DebugVariable> Vars ~ DeleteContainerAndItems!(_);
	}

	/// One frame of the call stack. `Unit` / `SheetKey` / `NodeKey` locate the node the frame is
	/// stopped on through the build's node map, `Path` is the type file (empty for frames outside
	/// the project: the runtime, the C library, system code).
	class DebugFrame
	{
		/// The debugger's name for the function (`Zoo::Program::Main()`).
		public String Name = new .() ~ delete _;
		public String Path = new .() ~ delete _;
		public String Unit = new .() ~ delete _;
		public String SheetKey = new .() ~ delete _;
		/// `Zoo.Program.Main` for frames of the project.
		public String SheetName = new .() ~ delete _;
		public String NodeKey = new .() ~ delete _;
		/// The node's kind and subject ("Call Zoo.Animal.Speak()").
		public String NodeTitle = new .() ~ delete _;
		public int32 Line;
		/// The frame is on a node of a project type file.
		public bool IsUser;
	}

	enum DebugVarKind
	{
		Local,
		Param,
		/// The Receiver (`this`).
		This,
		/// A pin value: a flow node's output (`<nodeId>.<pin>` in the debug info).
		Pin,
		/// A member of an object or struct, or anything else.
		Other
	}

	/// A value the Locals panel shows: a local, a parameter, `this` or a pin value.
	class DebugVariable
	{
		/// The debug info's name (`pet`, `a2.object`, `this`); members: the field name.
		public String Name = new .() ~ delete _;
		/// What the panel shows ("object  (a2 Construct Zoo.Dog)" for a pin, the name otherwise).
		public String Label = new .() ~ delete _;
		/// The type in Treadle's spelling where it maps (`int`, `Zoo.Animal`).
		public String Type = new .() ~ delete _;
		public String Value = new .() ~ delete _;
		/// The adapter's handle for the children (0 = none).
		public int64 ChildrenRef;
		public DebugVarKind Kind = .Other;
		/// Pin values: the node and the pin name.
		public String NodeKey = new .() ~ delete _;
		public String Pin = new .() ~ delete _;

		public DebugVariable Clone()
		{
			DebugVariable v = new .();
			v.Name.Set(Name);
			v.Label.Set(Label);
			v.Type.Set(Type);
			v.Value.Set(Value);
			v.ChildrenRef = ChildrenRef;
			v.Kind = Kind;
			v.NodeKey.Set(NodeKey);
			v.Pin.Set(Pin);
			return v;
		}
	}

	/// A thread of the stopped program (the debugger's `threads` list; docs/Threads.md 6).
	class DebugThread
	{
		/// The adapter's id for it (lldb-dap's thread id).
		public int64 Id;
		/// Its name (`Main`, `worker 2`, `Pool 1`; the system's name or `Thread <id>` when it has none).
		public String Name = new .() ~ delete _;
		/// The thread the Call Stack and Locals show.
		public bool Current;
	}

	/// A breakpoint on a node of a Sheet.
	class DebugBreakpoint
	{
		public String Path = new .() ~ delete _;
		public String SheetKey = new .() ~ delete _;
		public String NodeKey = new .() ~ delete _;
		public bool Enabled = true;
		/// The adapter bound it to code.
		public bool Verified;
	}

	/// The debugger the session drives (TreadleDebug's LldbDapAdapter: lldb-dap over the Debug
	/// Adapter Protocol), with node <-> location mapping over the build's node map
	/// (DebugProgram). Calls never block the UI thread: requests are queued and results come
	/// back through `Poll`; GetFrames / GetVariables read what the adapter collected at the stop.
	interface IDebugAdapter
	{
		/// False when no debugger is installed (Start Debugging refuses with `Unavailable`).
		bool Available { get; }
		/// Why debugging is not available (shown to the user).
		StringView Unavailable { get; }
		/// The program about to be launched: its node map (not owned; kept until the next call).
		void SetProgram(DebugProgram program);
		Result<void> Launch(StringView exePath, StringView args, StringView workDir, String outError);
		Result<void> Attach(int32 processId, String outError);
		void SetBreakpoints(List<DebugBreakpoint> breakpoints);
		void Continue();
		/// The steps work on nodes: they end on the next flow node of a Sheet (docs/Debugging.md).
		void StepOver();
		void StepInto();
		void StepOut();
		void Pause();
		/// Ends the session (a launched program is stopped, an attached one detached).
		void Stop();
		/// Moves everything that happened since the last call into `outEvents` (the caller owns them).
		void Poll(List<DebugEvent> outEvents);
		/// The call stack while stopped (the caller owns the frames).
		void GetFrames(List<DebugFrame> outFrames);
		/// The variables of a frame while stopped (the caller owns them).
		void GetVariables(int frameIndex, List<DebugVariable> outVars);
		/// Evaluates an expression in a frame (a pin name such as `a2.object`, a local, `pet.mLegs`
		/// or an expression lldb reads); the answer comes as an Evaluated event.
		void Evaluate(int frameIndex, StringView expression);
		/// The members of a value (DebugVariable.ChildrenRef); the answer comes as a Children event.
		void RequestChildren(int64 childrenRef);
		/// The threads while stopped (the caller owns them), the current one marked.
		void GetThreads(List<DebugThread> outThreads);
		/// Makes another thread current while stopped: its stack is read and reported as a new stop.
		void SelectThread(int64 threadId);
	}

	/// No debugger: every request is refused.
	class NullDebugAdapter : IDebugAdapter
	{
		public const String NoDebugger = "No debugger is installed in this build.";

		public bool Available => false;
		public StringView Unavailable => NoDebugger;

		public void SetProgram(DebugProgram program) { }

		public Result<void> Launch(StringView exePath, StringView args, StringView workDir, String outError)
		{
			outError?.Set(NoDebugger);
			return .Err;
		}

		public Result<void> Attach(int32 processId, String outError)
		{
			outError?.Set(NoDebugger);
			return .Err;
		}

		public void SetBreakpoints(List<DebugBreakpoint> breakpoints) { }
		public void Continue() { }
		public void StepOver() { }
		public void StepInto() { }
		public void StepOut() { }
		public void Pause() { }
		public void Stop() { }
		public void Poll(List<DebugEvent> outEvents) { }
		public void GetFrames(List<DebugFrame> outFrames) { }
		public void GetVariables(int frameIndex, List<DebugVariable> outVars) { }
		public void Evaluate(int frameIndex, StringView expression) { }
		public void RequestChildren(int64 childrenRef) { }
		public void GetThreads(List<DebugThread> outThreads) { }
		public void SelectThread(int64 threadId) { }
	}

	/// The session state machine the debug panels and the canvas read: state, breakpoints, the
	/// stopped frames and their variables, and the program's output. It drives an IDebugAdapter
	/// (not owned) and is updated once per frame.
	class DebugSession
	{
		public IDebugAdapter Adapter;
		public DebugState State = .Idle;
		public StopReason Reason;
		public int32 ExitCode;
		public List<DebugBreakpoint> Breakpoints = new .() ~ DeleteContainerAndItems!(_);
		public List<DebugFrame> Frames = new .() ~ DeleteContainerAndItems!(_);
		public List<DebugVariable> Locals = new .() ~ DeleteContainerAndItems!(_);
		/// The threads of the stopped program (the Call Stack panel lists them when there are several).
		public List<DebugThread> Threads = new .() ~ DeleteContainerAndItems!(_);
		/// The selected call-stack frame (Locals and the pin values show its variables).
		public int SelectedFrame;
		/// Program and adapter output (the Debug Output panel), oldest first; a line the
		/// debugger wrote (not the program) starts with '\x01'.
		public List<String> Output = new .() ~ DeleteContainerAndItems!(_);
		const int MaxOutput = 5000;
		/// The program being debugged (its node map), owned.
		public DebugProgram Program ~ delete _;
		/// Why it stopped, for a fatal error or an exception: the runtime's message.
		public String StopMessage = new .() ~ delete _;
		/// Counts the stops; the editor brings the stopped node into view when it changes.
		public int32 StopSerial;
		/// The last Evaluate: the expression, its answer and type.
		public String EvalExpression = new .() ~ delete _;
		public String EvalResult = new .() ~ delete _;
		public String EvalType = new .() ~ delete _;
		public bool EvalPending;
		public bool EvalFailed;
		/// Members of values by their children handle (cleared at each stop).
		public Dictionary<int64, List<DebugVariable>> Children = new .() ~ { for (let v in _.Values) DeleteContainerAndItems!(v); delete _; };
		HashSet<int64> mChildrenAsked = new .() ~ delete _;

		public this(IDebugAdapter adapter)
		{
			Adapter = adapter;
		}

		public bool IsActive => State == .Starting || State == .Running || State == .Stopped;
		public bool IsStopped => State == .Stopped;
		/// An answer from the adapter is due (running, an Evaluate, members asked for).
		public bool Waiting => State == .Starting || State == .Running || EvalPending || mChildrenAsked.Count > Children.Count;

		/// The frame the panels show (null when not stopped).
		public DebugFrame CurrentFrame => (IsStopped && SelectedFrame >= 0 && SelectedFrame < Frames.Count) ? Frames[SelectedFrame] : null;

		/// Takes ownership of `program` (the node map of the exe about to be launched).
		public void SetProgram(DebugProgram program)
		{
			if (program == Program)
				return;
			Adapter.SetProgram(program);
			delete Program;
			Program = program;
		}

		public Result<void> Launch(StringView exePath, StringView args, StringView workDir, String outError)
		{
			if (IsActive)
			{
				outError?.Set("A debugging session is already running.");
				return .Err;
			}
			ClearStopState();
			ExitCode = 0;
			Adapter.SetProgram(Program);
			Adapter.SetBreakpoints(Breakpoints);
			if (Adapter.Launch(exePath, args, workDir, outError) case .Err)
				return .Err;
			State = .Starting;
			return .Ok;
		}

		public Result<void> Attach(int32 processId, String outError)
		{
			if (IsActive)
			{
				outError?.Set("A debugging session is already running.");
				return .Err;
			}
			ClearStopState();
			Adapter.SetProgram(Program);
			Adapter.SetBreakpoints(Breakpoints);
			if (Adapter.Attach(processId, outError) case .Err)
				return .Err;
			State = .Starting;
			return .Ok;
		}

		public void Continue() { if (IsStopped) { ClearStopState(); Adapter.Continue(); State = .Running; } }
		public void StepOver() { if (IsStopped) { ClearStopState(); Adapter.StepOver(); State = .Running; } }
		public void StepInto() { if (IsStopped) { ClearStopState(); Adapter.StepInto(); State = .Running; } }
		public void StepOut() { if (IsStopped) { ClearStopState(); Adapter.StepOut(); State = .Running; } }
		public void Pause() { if (State == .Running) Adapter.Pause(); }

		public void Stop()
		{
			if (!IsActive)
				return;
			Adapter.Stop();
			ClearStopState();
			State = .Exited;
		}

		/// Toggles the breakpoint on a node. True when it is now set.
		public bool ToggleBreakpoint(StringView path, StringView sheetKey, StringView nodeKey)
		{
			for (let bp in Breakpoints)
			{
				if (SamePath(bp.Path, path) && bp.SheetKey == sheetKey && bp.NodeKey == nodeKey)
				{
					Breakpoints.Remove(bp);
					delete bp;
					if (IsActive)
						Adapter.SetBreakpoints(Breakpoints);
					return false;
				}
			}
			AddBreakpoint(path, sheetKey, nodeKey);
			return true;
		}

		/// Adds a breakpoint (no check for a duplicate).
		public DebugBreakpoint AddBreakpoint(StringView path, StringView sheetKey, StringView nodeKey)
		{
			DebugBreakpoint bp = new .();
			bp.Path.Set(path);
			bp.SheetKey.Set(sheetKey);
			bp.NodeKey.Set(nodeKey);
			Breakpoints.Add(bp);
			if (IsActive)
				Adapter.SetBreakpoints(Breakpoints);
			return bp;
		}

		public void ClearBreakpoints()
		{
			ClearAndDeleteItems!(Breakpoints);
			if (IsActive)
				Adapter.SetBreakpoints(Breakpoints);
		}

		public bool HasBreakpoint(StringView path, StringView sheetKey, StringView nodeKey)
		{
			for (let bp in Breakpoints)
				if (SamePath(bp.Path, path) && bp.SheetKey == sheetKey && bp.NodeKey == nodeKey)
					return true;
			return false;
		}

		static bool SamePath(StringView a, StringView b) => Treadle.Document.ProjectIndex.SamePath(a, b);

		/// Selects a frame of the stopped call stack and reads its variables.
		public void SelectFrame(int index)
		{
			if (!IsStopped || index < 0 || index >= Frames.Count)
				return;
			SelectedFrame = index;
			ClearAndDeleteItems!(Locals);
			Adapter.GetVariables(index, Locals);
		}

		/// Makes another thread of the stopped program current: its call stack replaces Frames when the
		/// adapter answers (as a stop on that thread).
		public void SelectThread(int64 threadId)
		{
			if (!IsStopped)
				return;
			for (let t in Threads)
				if (t.Id == threadId && t.Current)
					return;
			Adapter.SelectThread(threadId);
		}

		/// Evaluates in the selected frame; the answer lands in EvalResult.
		public void Evaluate(StringView expression)
		{
			if (!IsStopped)
				return;
			EvalExpression.Set(expression);
			EvalResult.Clear();
			EvalType.Clear();
			EvalPending = true;
			EvalFailed = false;
			Adapter.Evaluate(SelectedFrame, expression);
		}

		/// The members of a value: null until the adapter answered (asked once per stop).
		public List<DebugVariable> GetChildren(int64 childrenRef)
		{
			if (childrenRef == 0 || !IsStopped)
				return null;
			if (Children.TryGetValue(childrenRef, let list))
				return list;
			if (mChildrenAsked.Add(childrenRef))
				Adapter.RequestChildren(childrenRef);
			return null;
		}

		/// A variable of the selected frame by its debug-info name (`pet`, `a2.object`, `this`).
		public DebugVariable FindVariable(StringView name)
		{
			for (let v in Locals)
				if (v.Name == name)
					return v;
			return null;
		}

		/// Call once per frame: applies what the adapter reported.
		public void Update()
		{
			List<DebugEvent> events = scope .();
			defer { ClearAndDeleteItems!(events); }
			Adapter.Poll(events);
			for (let e in events)
			{
				switch (e.Kind)
				{
				case .Started:
					State = .Running;
				case .Continued:
					ClearStopState();
					State = .Running;
				case .Stopped:
					ClearStopState();
					State = .Stopped;
					Reason = e.Reason;
					StopMessage.Set(e.Text);
					Adapter.GetFrames(Frames);
					Adapter.GetThreads(Threads);
					// The panels start on the first frame that is on a node of the project.
					SelectedFrame = 0;
					for (let f in Frames)
						if (f.IsUser)
						{
							SelectedFrame = @f.Index;
							break;
						}
					if (!Frames.IsEmpty)
						Adapter.GetVariables(SelectedFrame, Locals);
					StopSerial++;
				case .Exited:
					ClearStopState();
					ExitCode = e.ExitCode;
					State = .Exited;
				case .Output:
					AddOutput(e.Text, e.FromProgram);
				case .Evaluated:
					if (e.Expression == EvalExpression)
					{
						EvalResult.Set(e.Text);
						EvalType.Set(e.Type);
						EvalFailed = e.Failed;
						EvalPending = false;
					}
				case .Children:
					if (IsStopped && !Children.ContainsKey(e.Ref))
					{
						List<DebugVariable> list = new .();
						if (e.Vars != null)
						{
							list.AddRange(e.Vars);
							e.Vars.Clear();
						}
						Children[e.Ref] = list;
					}
				}
			}
		}

		public void AddOutput(StringView text, bool fromProgram = true)
		{
			if (Output.Count >= MaxOutput)
			{
				delete Output[0];
				Output.RemoveAt(0);
			}
			String line = new .();
			if (!fromProgram)
				line.Append('\x01');
			line.Append(text);
			Output.Add(line);
		}

		public void ClearOutput()
		{
			ClearAndDeleteItems!(Output);
		}

		void ClearStopState()
		{
			Reason = .None;
			StopMessage.Clear();
			ClearAndDeleteItems!(Frames);
			ClearAndDeleteItems!(Threads);
			ClearAndDeleteItems!(Locals);
			for (let v in Children.Values)
				DeleteContainerAndItems!(v);
			Children.Clear();
			mChildrenAsked.Clear();
			EvalPending = false;
			SelectedFrame = 0;
		}
	}
}
