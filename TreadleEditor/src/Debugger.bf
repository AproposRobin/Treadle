using System;
using System.Collections;
using System.IO;
using ImGui;
using Treadle.Debug;
using Treadle.Debug.Dap;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Backend.Driver;

namespace Treadle.Editor
{
	/// Debugging in the editor (docs/Debugging.md): the Debug menu and keys (F5 build in Debug and
	/// start, F9 breakpoint, F10 / F11 / Shift+F11 steps, Shift+F5 stop), breakpoints on nodes kept
	/// per project in settings.json, the Locals, Call Stack and Debug Output panels, and the canvas
	/// overlay (breakpoint dots, the stopped node, pin values). All of it reads
	/// Treadle.Debug.DebugSession, which drives TreadleDebug's LldbDapAdapter (lldb-dap).
	extension EditorApp
	{
		LldbDapAdapter mDapAdapter = new .() ~ delete _;
		DebugSession mDebug ~ delete _;
		public bool ShowLocals;
		public bool ShowCallStack;
		public bool ShowDebugOutput;
		/// F5 asked for a build: launch when it succeeds.
		bool mDebugAfterBuild;
		int32 mDebugStopSeen;
		DebugState mDebugLastState;
		/// The project whose breakpoints are loaded.
		String mDebugBpRoot = new .() ~ delete _;
		TextBuffer mEvalBuf = new .(256) ~ delete _;
		/// Counts the launches (the self test waits for a new session).
		public int32 DebugLaunches;
		/// The first stop of a session brings Locals to the front of its dock.
		int mDebugFocusLocals;
		bool mDebugFirstStop;
		int mDebugOutputCount;

		public DebugSession Debug
		{
			get
			{
				if (mDebug == null)
					mDebug = new .(mDapAdapter);
				return mDebug;
			}
		}

		public bool IsDebugging => mDebug != null && mDebug.IsActive;
		public bool IsDebugStopped => mDebug != null && mDebug.IsStopped;

		/// Debug > Start Debugging (F5): builds in Debug, then launches under the debugger.
		public void StartDebugging()
		{
			if (IsDebugging)
				return;
			if (!Debug.Adapter.Available)
			{
				SetStatus(scope $"Can't start debugging: {Debug.Adapter.Unavailable}", .Warning);
				return;
			}
			if (mProjectRoot.IsEmpty)
			{
				SetStatus("Start Debugging: open a project first", .Warning);
				return;
			}
			if (ProgramRunning)
			{
				SetStatus("The program is still running (Build > Stop Program ends it)", .Warning);
				return;
			}
			mDebugAfterBuild = true;
			StartBuild("Debug", false, false, false);
			if (mBuild == null || !mBuild.Running)
				mDebugAfterBuild = false;
		}

		/// From OnBuildFinished: F5's build that succeeded starts the program under the debugger.
		void OnDebugBuildFinished()
		{
			if (!mDebugAfterBuild)
				return;
			mDebugAfterBuild = false;
			let job = mBuild as BackendBuildJob;
			if (job == null || !job.Succeeded || job.ExePath.IsEmpty)
			{
				SetStatus("Start Debugging: the build failed (see Problems)", .Warning);
				return;
			}
			LaunchDebugger(job.ExePath);
		}

		/// Launches a built Debug exe of the open project under the debugger.
		public bool LaunchDebugger(StringView exePath)
		{
			String buildDir = scope .();
			Path.GetDirectoryPath(exePath, buildDir);
			DebugProgram program = new .();
			String why = scope .();
			if (!program.Load(mProjectRoot, buildDir, exePath, why))
			{
				delete program;
				SetStatus(scope $"Can't start debugging: {why}", .Warning);
				return false;
			}
			for (let n in program.Notes)
				Notify.Log(.Warning, "Debug", n);
			Debug.SetProgram(program);
			Debug.ClearOutput();
			mDebugOutputCount = 0;
			if (Debug.Launch(exePath, "", buildDir, why) case .Err)
			{
				SetStatus(scope $"Can't start debugging: {why}", .Warning);
				return false;
			}
			DebugLaunches++;
			mDebugFirstStop = true;
			Notify.Log(.Info, "Debug", scope $"> {exePath} (lldb-dap: {mDapAdapter.DapPath})");
			ShowDebugOutput = true;
			SetStatus(scope $"Debugging {exePath}", .Info, false);
			return true;
		}

		List<RunningProgram> mAttachList = new .() ~ DeleteContainerAndItems!(_);
		bool mAttachPopup;

		/// The project's Debug builds running now (Debug > Attach to Process).
		public void RefreshAttachList()
		{
			ClearAndDeleteItems!(mAttachList);
			if (!mProjectRoot.IsEmpty)
				ProcessList.FindIn(scope $"{mProjectRoot}{Path.DirectorySeparatorChar}build{Path.DirectorySeparatorChar}Debug", mAttachList);
		}

		/// Debug > Attach to Process: the debugger takes over a running Debug build of the open
		/// project (started outside the editor); the node map is that build's. For a `kind library`
		/// project the process is a host that loaded the library: `module` is the library's path in
		/// build/Debug, whose node maps are used (lldb resolves the breakpoints by the listing paths
		/// the library's DWARF names, whatever the host). Stop Debugging detaches and leaves it running.
		public bool AttachDebugger(int32 pid, StringView exePath, StringView module = "")
		{
			StringView built = module.IsEmpty ? exePath : module;
			String buildDir = scope .();
			Path.GetDirectoryPath(built, buildDir);
			DebugProgram program = new .();
			String why = scope .();
			if (!program.Load(mProjectRoot, buildDir, built, why))
			{
				delete program;
				SetStatus(scope $"Can't attach: {why}", .Warning);
				return false;
			}
			for (let n in program.Notes)
				Notify.Log(.Warning, "Debug", n);
			Debug.SetProgram(program);
			Debug.ClearOutput();
			mDebugOutputCount = 0;
			if (Debug.Attach(pid, why) case .Err)
			{
				SetStatus(scope $"Can't attach: {why}", .Warning);
				return false;
			}
			DebugLaunches++;
			mDebugFirstStop = true;
			if (module.IsEmpty)
				Notify.Log(.Info, "Debug", scope $"> attach {pid} {exePath} (lldb-dap: {mDapAdapter.DapPath})");
			else
				Notify.Log(.Info, "Debug", scope $"> attach {pid} {exePath}, library {module} (lldb-dap: {mDapAdapter.DapPath})");
			ShowDebugOutput = true;
			SetStatus(scope $"Debugging {built} (process {pid}, attached)", .Info, false);
			return true;
		}

		void DrawAttachPopup()
		{
			if (mAttachPopup)
			{
				Gui.OpenPopup("Attach to Process");
				mAttachPopup = false;
			}
			if (!Gui.igBeginPopupModal("Attach to Process", null, WindowFlags.AlwaysAutoResize))
				return;
			if (Gui.IsKeyPressed(Key.Escape, false))
				Gui.igCloseCurrentPopup();
			Gui.Text("Debug builds of this project that are running (build/Debug), or programs that loaded its library:");
			if (mAttachList.IsEmpty)
				Gui.TextDisabled("None. Run the Debug build outside the editor, then Refresh.");
			for (let p in mAttachList)
			{
				String name = scope .();
				Path.GetFileName(p.Path, name);
				String label = scope $"{name}   process {p.Pid}";
				if (!p.Module.IsEmpty)
				{
					String lib = scope .();
					Path.GetFileName(p.Module, lib);
					label.AppendF("   (loaded {})", lib);
				}
				if (Gui.Selectable(scope $"{label}##attach{p.Pid}", false, 0))
				{
					AttachDebugger(p.Pid, p.Path, p.Module);
					Gui.igCloseCurrentPopup();
				}
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip(p.Path);
			}
			if (Gui.Button("Refresh", .(100 * Look.Scale, 0)))
				RefreshAttachList();
			Gui.SameLine();
			if (Gui.Button("Cancel", .(100 * Look.Scale, 0)))
				Gui.igCloseCurrentPopup();
			Gui.EndPopup();
		}

		/// F9: a breakpoint on the selected node of the front Sheet.
		public void ToggleBreakpointOnSelection()
		{
			let tab = CurrentTab;
			let mg = CurrentMethod;
			if (tab == null || mg == null || tab.SelectedNodes.Count == 0)
			{
				SetStatus("Toggle Breakpoint: select a node first", .Info, false);
				return;
			}
			for (let id in tab.SelectedNodes)
			{
				let node = mg.Graph.FindNode(id);
				if (node != null)
					ToggleBreakpoint(mg, node);
			}
		}

		public void ToggleBreakpoint(Sheet mg, Node node)
		{
			if (mg.Doc.FilePath.IsEmpty)
			{
				SetStatus("Breakpoints go on nodes of a saved type file", .Info, false);
				return;
			}
			String why = scope .();
			if (!CanHaveBreakpoint(node, why))
			{
				SetStatus(scope $"No breakpoint here: {why}", .Info, false);
				return;
			}
			bool on = Debug.ToggleBreakpoint(mg.Doc.FilePath, mg.Key, node.Key);
			SaveBreakpoints();
			SetStatus(on ? "Breakpoint set" : "Breakpoint removed", .Info, false);
		}

		/// Breakpoints go on flow nodes: a value node runs inside the flow node that reads it.
		static bool CanHaveBreakpoint(Node node, String outWhy)
		{
			if (node.Key.IsEmpty)
			{
				outWhy.Set("the node has no record id yet (save the file)");
				return false;
			}
			if (!node.IsExecNode && node.Kind != .Entry)
			{
				outWhy.Set("a value node runs inside the flow node that reads it; put the breakpoint there");
				return false;
			}
			return true;
		}

		/// Nodes of a Sheet with a breakpoint (by node id).
		public void BreakpointNodes(Sheet mg, List<int32> outIds)
		{
			if (mDebug == null || mDebug.Breakpoints.IsEmpty)
				return;
			for (let n in mg.Graph.Nodes)
				if (mDebug.HasBreakpoint(mg.Doc.FilePath, mg.Key, n.Key))
					outIds.Add(n.Id);
		}

		/// Debug > Remove All Breakpoints (of this project).
		public void RemoveAllBreakpoints()
		{
			Debug.ClearBreakpoints();
			SaveBreakpoints();
			SetStatus("All breakpoints removed", .Info, false);
		}

		// ---- persistence: settings.json, projects.<folder>.breakpoints = [{file, sheet, node}]

		void LoadBreakpoints()
		{
			mDebugBpRoot.Set(mProjectRoot);
			Debug.ClearBreakpoints();
			if (mProjectRoot.IsEmpty || Settings.Root == null)
				return;
			let list = Settings.Project(mProjectRoot).Get("breakpoints");
			if (list == null || list.Type != .Array)
				return;
			for (let b in list.Items)
			{
				let file = b.GetString("file");
				if (file.IsEmpty)
					continue;
				String path = scope .();
				if (Path.IsPathRooted(file))
					path.Set(file);
				else
					path.AppendF("{}{}{}", mProjectRoot, Path.DirectorySeparatorChar, file);
				Debug.AddBreakpoint(path, b.GetString("sheet"), b.GetString("node"));
			}
		}

		void SaveBreakpoints()
		{
			if (mProjectRoot.IsEmpty || Settings.Root == null)
				return;
			if (Debug.Breakpoints.IsEmpty)
			{
				let proj = Settings.Project(mProjectRoot);
				if (proj.Get("breakpoints") != null)
				{
					proj.Remove("breakpoints");
					Settings.Save();
				}
				return;
			}
			let arr = Json.NewArray();
			for (let bp in Debug.Breakpoints)
			{
				let o = Json.NewObject();
				// Relative to the project folder, so the project can move.
				String rel = scope .(bp.Path);
				if (rel.Length > mProjectRoot.Length && ProjectIndex.SamePath(rel.Substring(0, mProjectRoot.Length), mProjectRoot))
				{
					rel.Remove(0, mProjectRoot.Length);
					while (rel.StartsWith('\\') || rel.StartsWith('/'))
						rel.Remove(0, 1);
				}
				o.Set("file", Json.NewString(rel));
				o.Set("sheet", Json.NewString(bp.SheetKey));
				o.Set("node", Json.NewString(bp.NodeKey));
				arr.Items.Add(o);
			}
			Settings.Project(mProjectRoot).Set("breakpoints", arr);
			Settings.Save();
		}

		// ---- per frame

		void UpdateDebugger()
		{
			if (mDebugBpRoot != mProjectRoot)
				LoadBreakpoints();
			if (mDebug == null)
				return;
			mDebug.Update();
			if (mDebug.StopSerial != mDebugStopSeen)
			{
				mDebugStopSeen = mDebug.StopSerial;
				OnDebugStopped();
			}
			if (mDebug.State != mDebugLastState)
			{
				let was = mDebugLastState;
				mDebugLastState = mDebug.State;
				if (mDebug.State == .Exited && was != .Exited && was != .Idle)
				{
					let code = mDebug.ExitCode;
					mDebug.AddOutput(scope $"The program exited with code {code}.", false);
					Notify.Log((code == 0) ? .Info : .Warning, "Debug", scope $"The program exited with code {code}");
					SetStatus(scope $"Not debugging: the program exited with code {code}", (code == 0) ? .Info : .Warning);
				}
				else if (mDebug.State == .Running)
					SetStatus("Running", .Info, false);
			}
			if (!Gui.igIsAnyItemActive())
			{
				if (Gui.IsKeyPressed(580 /* F9 */, false))
					ToggleBreakpointOnSelection();
				if (IsDebugStopped)
				{
					if (Gui.IsKeyPressed(581 /* F10 */, false))
						mDebug.StepOver();
					if (Gui.IsKeyPressed(582 /* F11 */, false))
					{
						if (Gui.IsShiftDown)
							mDebug.StepOut();
						else
							mDebug.StepInto();
					}
				}
			}
		}

		/// The program stopped: the Sheet of the stopped node opens, the node is selected and in
		/// view, the panels come forward.
		void OnDebugStopped()
		{
			ShowLocals = true;
			ShowCallStack = true;
			ShowDebugOutput = true;
			if (mDebugFirstStop)
			{
				mDebugFirstStop = false;
				mDebugFocusLocals = 3; // after the panels that appear with the stop took their place
			}
			let f = mDebug.CurrentFrame;
			if (f != null && f.IsUser)
				ShowFrameNode(f);
			String stopAt = scope .();
			if (f != null)
			{
				stopAt.Append(f.SheetName.IsEmpty ? f.Name : f.SheetName);
				if (!f.NodeKey.IsEmpty)
					stopAt.AppendF(" (node {})", f.NodeKey);
			}
			if (mDebug.Reason == .Fatal || mDebug.Reason == .Exception)
			{
				mDebug.AddOutput(scope $"Stopped on a {(mDebug.Reason == .Fatal) ? "fatal error" : "fault"} at {stopAt}: {mDebug.StopMessage}", false);
				Notify.Error(scope $"The program stopped on {(mDebug.Reason == .Fatal) ? "a fatal error" : "a fault"}: {mDebug.StopMessage}");
				SetStatus(scope $"Stopped at {stopAt} ({(mDebug.Reason == .Fatal) ? "fatal" : "fault"})", .Error, false);
			}
			else
				SetStatus(scope $"Stopped at {stopAt}: F5 Continue, F10 Step Over, F11 Step Into, Shift+F11 Step Out", .Info, false);
			if (mSelfTestStep == -2)
				Desktop.BringToFront();
		}

		/// Opens the Sheet of a frame's node (its type file when needed) and brings the node into view.
		public bool ShowFrameNode(DebugFrame f)
		{
			if (f.Path.IsEmpty)
				return false;
			let doc = FindDoc(f.Path) ?? OpenFile(f.Path, false);
			if (doc == null)
				return false;
			Doc = doc;
			let sheet = doc.FindSheet(f.SheetKey);
			if (sheet == null)
				return false;
			OpenTab(sheet);
			for (let n in sheet.Graph.Nodes)
			{
				if (n.Key != f.NodeKey)
					continue;
				let tab = CurrentTab;
				if (tab != null)
				{
					tab.SelectOnly(n.Id);
					tab.CenterOn(n.X + 100, n.Y + 40);
				}
				return true;
			}
			return false;
		}

		/// The graph node a stop is on, when `mg` is the selected frame's Sheet (0 otherwise).
		public int32 DebugStopNode(Sheet mg)
		{
			let f = mDebug?.CurrentFrame;
			if (f == null || !f.IsUser || f.SheetKey != mg.Key || !ProjectIndex.SamePath(f.Path, mg.Doc.FilePath))
				return 0;
			for (let n in mg.Graph.Nodes)
				if (n.Key == f.NodeKey)
					return n.Id;
			return 0;
		}

		/// The value on a pin while stopped, from the selected frame's variables: a flow node's
		/// output (`<node>.<pin>`), a Get of a local or parameter, the Receiver (`this`). False with
		/// the reason in `outValue` when there is none.
		public bool DebugPinValue(Sheet mg, Pin p, String outValue)
		{
			let f = mDebug?.CurrentFrame;
			if (f == null || f.SheetKey != mg.Key || !ProjectIndex.SamePath(f.Path, mg.Doc.FilePath))
			{
				outValue.Set("not in the selected frame");
				return false;
			}
			if (p.Kind != .Value)
				return false;
			var p;
			if (p.IsInput)
			{
				Pin from = null;
				for (let l in mg.Graph.Links)
					if (l.To == p)
					{
						from = l.From;
						break;
					}
				if (from == null)
				{
					if (p.Role == .Receiver)
					{
						let v = mDebug.FindVariable("this");
						if (v != null)
						{
							outValue.Set(v.Value);
							return true;
						}
					}
					outValue.Set("not wired");
					return false;
				}
				p = from;
			}
			let node = p.Owner;
			// A Get of a local or a parameter: the variable itself.
			if (node.Kind == .Get)
			{
				StringView name = node.Text;
				if (name.StartsWith("local:") || name.StartsWith("param:"))
					name = name.Substring(6);
				for (let v in mDebug.Locals)
					if ((v.Kind == .Local || v.Kind == .Param) && v.Label == name)
					{
						outValue.Set(v.Value);
						return true;
					}
			}
			else if (node.Kind == .This)
			{
				let v = mDebug.FindVariable("this");
				if (v != null)
				{
					outValue.Set(v.Value);
					return true;
				}
			}
			let v = mDebug.FindVariable(scope $"{node.Key}.{p.Name}");
			if (v != null)
			{
				outValue.Set(v.Value);
				return true;
			}
			if (node.IsPure)
				outValue.Set("shown only by running code (a value node keeps no value)");
			else
				outValue.Set("not set yet");
			return false;
		}

		// ---- menu and panels

		void DrawDebugMenu()
		{
			if (!Gui.BeginMenu("Debug"))
				return;
			bool active = IsDebugging;
			if (Gui.MenuItem(scope $"{Icon.Play}  Start Debugging", "F5", false, !active))
				StartDebugging();
			if (Gui.igIsItemHovered(1 << 10 /* AllowWhenDisabled */) && !Debug.Adapter.Available)
				Gui.Tooltip(Debug.Adapter.Unavailable);
			if (Gui.MenuItem(scope $"{Icon.Play}  Continue", "F5", false, IsDebugStopped))
				Debug.Continue();
			if (Gui.MenuItem(scope $"{Icon.Pause}  Pause", "", false, active && !IsDebugStopped))
				Debug.Pause();
			if (Gui.MenuItem(scope $"{Icon.Square}  Stop Debugging", "Shift+F5", false, active))
				Debug.Stop();
			if (Gui.MenuItem("Attach to Process...", "", false, !active && !mProjectRoot.IsEmpty && Debug.Adapter.Available))
			{
				RefreshAttachList();
				mAttachPopup = true;
			}
			Gui.Separator();
			if (Gui.MenuItem(scope $"{Icon.RedoDot}  Step Over", "F10", false, IsDebugStopped))
				Debug.StepOver();
			if (Gui.MenuItem(scope $"{Icon.ArrowDownToLine}  Step Into", "F11", false, IsDebugStopped))
				Debug.StepInto();
			if (Gui.MenuItem(scope $"{Icon.ArrowUpFromLine}  Step Out", "Shift+F11", false, IsDebugStopped))
				Debug.StepOut();
			Gui.Separator();
			if (Gui.MenuItem(scope $"{Icon.CircleDot}  Toggle Breakpoint", "F9", false, CurrentTab != null))
				ToggleBreakpointOnSelection();
			if (Gui.MenuItem("Remove All Breakpoints", "", false, mDebug != null && !mDebug.Breakpoints.IsEmpty))
				RemoveAllBreakpoints();
			Gui.Separator();
			if (Gui.MenuItem("Locals", "", ShowLocals))
				ShowLocals = !ShowLocals;
			if (Gui.MenuItem("Call Stack", "", ShowCallStack))
				ShowCallStack = !ShowCallStack;
			if (Gui.MenuItem("Debug Output", "", ShowDebugOutput))
				ShowDebugOutput = !ShowDebugOutput;
			DrawHoodMenuItems(true); // Disassembly, Memory: DisassemblyPanel.bf
			Gui.EndMenu();
		}

		void DebugIdleText()
		{
			Gui.igPushTextWrapPos(0);
			if (!Debug.Adapter.Available)
				Gui.TextDisabled(Debug.Adapter.Unavailable);
			else if (IsDebugging)
				Gui.TextDisabled("Running. Pause (Debug menu) or a breakpoint stops it.");
			else
				Gui.TextDisabled("Not debugging. Start Debugging (F5) builds in Debug, runs the program and stops on breakpoints (F9 on a node).");
			Gui.igPopTextWrapPos();
		}

		void DrawVariableRow(DebugVariable v, int depth)
		{
			Gui.igTableNextRow(0, 0);
			Gui.igTableSetColumnIndex(0);
			Gui.PushID(scope $"{v.Name}#{depth}");
			bool open = false;
			bool canOpen = v.ChildrenRef != 0 && depth < 6;
			int32 flags = TreeNodeFlags.SpanFullWidth | (canOpen ? TreeNodeFlags.OpenOnArrow : (TreeNodeFlags.Leaf | TreeNodeFlags.NoTreePushOnOpen));
			open = Gui.TreeNode(v.Label.IsEmpty ? v.Name : v.Label, flags);
			if (depth == 0) HoodVariableMenu(v); // Show in Memory: MemoryPanel.bf
			if (Gui.igIsItemHovered(0) && v.Kind == .Pin)
			{
				let f = mDebug.CurrentFrame;
				let n = (f != null) ? mDebug.Program?.FindNode(f.Unit, f.SheetKey, v.NodeKey) : null;
				String tip = scope $"Pin {v.Pin} of node {v.NodeKey}";
				if (n != null && !n.Title.IsEmpty)
					tip.AppendF(" ({})", n.Title);
				tip.Append(": the value on the node's output");
				Gui.Tooltip(tip);
			}
			Gui.igTableSetColumnIndex(1);
			CellText(v.Value);
			if (Gui.igIsItemHovered(0) && !v.Value.IsEmpty)
				Gui.Tooltip(v.Value);
			Gui.igTableSetColumnIndex(2);
			CellText(v.Type, 0, true);
			if (canOpen && open)
			{
				let kids = mDebug.GetChildren(v.ChildrenRef);
				if (kids == null)
				{
					Gui.igTableNextRow(0, 0);
					Gui.igTableSetColumnIndex(0);
					Gui.TextDisabled("reading...");
				}
				else
					for (let k in kids)
						DrawVariableRow(k, depth + 1);
				Gui.TreePop();
			}
			Gui.PopID();
		}

		void DrawDebugPanels()
		{
			DrawAttachPopup();
			if (ShowLocals)
			{
				if (mDebugFocusLocals > 0 && --mDebugFocusLocals == 0)
				{
					Panels.Focus(Panels.LocalsId);
				}
				if (Gui.Begin(Panels.Locals, &ShowLocals))
				{
					if (!IsDebugStopped)
						DebugIdleText();
					else
					{
						// Evaluate: a pin (`a2.object`), a local, a member path (`pet.mLegs`) or an expression.
						Gui.igSetNextItemWidth(-1);
						if (Gui.igInputTextWithHint("##eval", "Evaluate: a pin (a2.object), a local, pet.mLegs", mEvalBuf.Ptr, (.)mEvalBuf.Capacity, InputTextFlags.EnterReturnsTrue, null, null))
							mDebug.Evaluate(mEvalBuf.View);
						if (!mDebug.EvalExpression.IsEmpty)
						{
							Gui.igPushTextWrapPos(0);
							if (mDebug.EvalPending)
								Gui.TextDisabled(scope $"{mDebug.EvalExpression} = ...");
							else if (mDebug.EvalFailed)
								Gui.TextColored(Look.Error, scope $"{mDebug.EvalExpression}: {mDebug.EvalResult}");
							else
								Gui.Text(scope $"{mDebug.EvalExpression} = {mDebug.EvalResult}  ({mDebug.EvalType})");
							Gui.igPopTextWrapPos();
						}
						if (Gui.igBeginTable("##locals", 3, TableFlags.RowBg | TableFlags.Resizable | TableFlags.BordersInnerV, .(0, 0), 0))
						{
							Gui.igTableSetupColumn("Name", TableColumnFlags.WidthStretch, 0.9f, 0);
							Gui.igTableSetupColumn("Value", TableColumnFlags.WidthStretch, 1.5f, 0);
							Gui.igTableSetupColumn("Type", TableColumnFlags.WidthStretch, 0.8f, 0);
							bool pinsOpen = true;
							bool pinsHeader = false;
							for (let v in mDebug.Locals)
							{
								if (v.Kind == .Pin && !pinsHeader)
								{
									pinsHeader = true;
									Gui.igTableNextRow(0, 0);
									Gui.igTableSetColumnIndex(0);
									pinsOpen = Gui.TreeNode("Pin values", TreeNodeFlags.SpanFullWidth | TreeNodeFlags.NoTreePushOnOpen | TreeNodeFlags.DefaultOpen);
								}
								if (v.Kind == .Pin && !pinsOpen)
									continue;
								DrawVariableRow(v, 0);
							}
							Gui.igEndTable();
						}
						if (mDebug.Locals.IsEmpty)
							Gui.TextDisabled("This frame has no variables the debugger can read.");
					}
				}
				Panels.NoteNarrow();
				Gui.End();
			}
			if (ShowCallStack)
			{
				if (Gui.Begin(Panels.CallStack, &ShowCallStack))
				{
					if (!IsDebugStopped)
						DebugIdleText();
					else
					{
						// Threads (docs/Threads.md 6): one row per thread when there are several; a click makes
						// it current, and its stack replaces the frames below.
						if (mDebug.Threads.Count > 1)
						{
							// Main first, then the workers by name (DebugSession.SortThreads); the current thread
							// carries the stop arrow and the selection colour.
							if (Gui.TreeNode(scope $"Threads ({mDebug.Threads.Count})###threads", TreeNodeFlags.SpanFullWidth | TreeNodeFlags.NoTreePushOnOpen | TreeNodeFlags.DefaultOpen))
							{
								for (let t in mDebug.Threads)
								{
									if (CallStackRow(t.Name, scope $"thread{t.Id}", t.Current, t.Current, false,
										t.Current ? "the thread the Call Stack shows" : "click to show its call stack"))
										mDebug.SelectThread(t.Id);
								}
							}
							Gui.Separator();
						}
						for (let f in mDebug.Frames)
						{
							String label = scope .();
							if (f.IsUser)
							{
								label.Append(f.SheetName.IsEmpty ? f.Name : f.SheetName);
								if (!f.NodeKey.IsEmpty)
									label.AppendF("   {}  {}", f.NodeKey, f.NodeTitle);
							}
							else
								label.Append(f.Name.IsEmpty ? "(unknown)" : f.Name);
							String detail = f.IsUser ? scope:: $"{f.Name}: {f.Path}, Sheet {f.SheetKey}, node {f.NodeKey} (listing line {f.Line})" : "Outside the project's Sheets (the runtime, the C library or the system)";
							if (CallStackRow(label, scope $"frame{@f.Index}", @f.Index == mDebug.SelectedFrame, false, !f.IsUser, detail))
							{
								mDebug.SelectFrame(@f.Index);
								if (f.IsUser)
									ShowFrameNode(f);
							}
							HoodFrameMenu(f, @f.Index); // Show Frame in Memory, Disassembly: MemoryPanel.bf
						}
					}
				}
				Panels.NoteNarrow();
				Gui.End();
			}
			if (ShowDebugOutput)
			{
				if (Gui.Begin(Panels.DebugOutput, &ShowDebugOutput))
				{
					if (mDebug == null || mDebug.Output.IsEmpty)
						DebugIdleText();
					else
					{
						if (Gui.SmallButton("Clear"))
							mDebug.ClearOutput();
						Gui.SameLine();
						if (Gui.SmallButton("Copy"))
						{
							String all = scope .();
							for (let line in mDebug.Output)
								all.AppendF("{}\n", line.StartsWith('\x01') ? StringView(line, 1) : line);
							Gui.igSetClipboardText(all);
						}
						Gui.igBeginChild_Str("##dbgout", .(0, 0), 0, 0);
						Gui.igPushTextWrapPos(0);
						for (let line in mDebug.Output)
						{
							if (line.StartsWith('\x01'))
								Gui.TextColored(Look.ForegroundDim, StringView(line, 1));
							else
								Gui.Text(line);
						}
						if (mDebug.Output.Count != mDebugOutputCount)
						{
							mDebugOutputCount = mDebug.Output.Count;
							Gui.igSetScrollHereY(1.0f);
						}
						Gui.igPopTextWrapPos();
						Gui.igEndChild();
					}
				}
				Gui.End();
			}
		}
	}

	extension EditorApp
	{
		/// One Call Stack row (a thread or a frame): a gutter with the stop arrow when `arrow` (the current
		/// thread), the text cut in the middle to the panel's width, dimmed when `dim` (a frame outside the
		/// project). The tooltip has the whole text when it was cut, and `detail`. True when clicked.
		bool CallStackRow(StringView text, StringView id, bool selected, bool arrow, bool dim, StringView detail)
		{
			let lineH = Gui.igGetTextLineHeight();
			let gutter = lineH * 1.1f;
			let pos = Gui.igGetCursorScreenPos();
			let avail = Gui.igGetContentRegionAvail().x;
			bool clicked = Gui.Selectable(scope $"##{id}", selected, 0, .(0, lineH));
			bool hovered = Gui.igIsItemHovered(0);
			String shown = scope .();
			bool cut = Look.EllipsizeMiddle(text, Math.Max(avail - gutter, 8 * Look.Scale), shown);
			let dl = Gui.igGetWindowDrawList();
			if (arrow)
			{
				// the canvas's stop arrow, small: yellow with a thin outline that reads on both themes
				let s = lineH * 0.3f;
				let cy = pos.y + lineH * 0.5f;
				let x0 = pos.x + lineH * 0.2f;
				ImVec2 a = .(x0, cy - s);
				ImVec2 b = .(x0, cy + s);
				ImVec2 c = .(x0 + s * 1.6f, cy);
				Gui.ImDrawList_AddTriangleFilled(dl, a, b, c, cStackArrow);
				Gui.ImDrawList_AddTriangle(dl, a, b, c, Gui.igGetColorU32_Col(0 /* Text */, 0.45f), 1);
			}
			let col = dim ? Look.ForegroundDim : Gui.igGetColorU32_Col(0 /* Text */, 1);
			Gui.ImDrawList_AddText_Vec2(dl, .(pos.x + gutter, pos.y), col, shown.Ptr, shown.Ptr + shown.Length);
			if (hovered)
				Gui.Tooltip(cut ? scope $"{text}\n{detail}" : detail);
			return clicked;
		}

		const uint32 cStackArrow = 0xFF28C8FF; // ABGR: the canvas's stop yellow (255, 200, 40)
	}

	extension GraphPanel
	{
		List<int32> mBpNodes = new .() ~ delete _;

		const uint32 cBreakpointRed = 0xFF3838E0; // ABGR: (224, 56, 56)
		const uint32 cStopYellow = 0xFF28C8FF;    // (255, 200, 40)

		/// The debugger on the canvas: a breakpoint circle on each node's top-left corner (red dot
		/// when set; a faint ring near the corner to set one), the node the program stopped at
		/// (yellow outline and an arrow), the values of the stopped node's pins beside them, and the
		/// value of any pin under the mouse while stopped.
		void DrawDebugOverlay(GraphTab tab, Sheet mg, ImDrawList* dl)
		{
			let graph = mg.Graph;
			float z = tab.Zoom;
			float ui = Look.Scale;
			mBpNodes.Clear();
			mApp.BreakpointNodes(mg, mBpNodes);
			bool stopped = mApp.IsDebugStopped;
			int32 stopNode = stopped ? mApp.DebugStopNode(mg) : 0;
			let mouse = Gui.igGetMousePos();
			for (let L in mOrder)
			{
				if (!L.Visible)
					continue;
				let node = L.Node;
				let p0 = tab.GridToScreen(node.X, node.Y);
				let p1 = p0 + ImVec2(L.W, L.H) * z;

				if (stopNode != 0 && node.Id == stopNode)
				{
					float o = 4 * z * ui;
					float r = ((L.Shape == .Getter) ? L.H * 0.5f : 6) * z;
					Gui.ImDrawList_AddRect(dl, p0 - .(o, o), p1 + .(o, o), cStopYellow, r + o, Math.Max(2, 3 * z), 0);
					// The arrow left of the node, at the header.
					float hy = p0.y + Math.Max(L.HeaderH * 0.5f, 10) * z;
					float ax = p0.x - 8 * z * ui;
					float s = Math.Max(6 * ui, 9 * z * ui);
					Gui.ImDrawList_AddTriangleFilled(dl, .(ax - s * 1.6f, hy - s), .(ax - s * 1.6f, hy + s), .(ax, hy), cStopYellow);
					if (z >= 0.45f)
						DrawStopValues(tab, mg, L, dl);
				}

				// Breakpoint circle on the top-left corner.
				bool hasBp = mBpNodes.Contains(node.Id);
				float rad = Math.Max(5 * ui, 7 * z * ui);
				let c = p0 + ImVec2(rad * 0.4f, rad * 0.4f);
				let d = mouse - c;
				bool near = (d.x * d.x + d.y * d.y) < (rad * 2.2f) * (rad * 2.2f);
				bool show = hasBp || ((mHoverNode == node.Id || near) && tab.Mode == .None && (node.IsExecNode || node.Kind == .Entry));
				if (!show)
					continue;
				Gui.igSetCursorScreenPos(c - .(rad, rad));
				Gui.PushID(node.Id);
				Gui.igInvisibleButton("##bp", .(rad * 2, rad * 2), ButtonFlags.MouseButtonLeft);
				bool clicked = Gui.igIsItemClicked(0);
				bool hovered = Gui.igIsItemHovered(0);
				Gui.PopID();
				if (hasBp)
				{
					Gui.ImDrawList_AddCircleFilled(dl, c, rad, cBreakpointRed, 0);
					Gui.ImDrawList_AddCircle(dl, c, rad, Gui.Color(20, 20, 20, 220), 0, Math.Max(1, z));
				}
				else
					Gui.ImDrawList_AddCircle(dl, c, rad, hovered ? Theme.WithAlpha(cBreakpointRed, 230) : Gui.Color(150, 150, 150, 120), 0, Math.Max(1, 1.5f * z));
				if (hovered)
				{
					if (hasBp)
						Gui.Tooltip("Breakpoint: the program stops here (click or F9 to remove)");
					else
						Gui.Tooltip("Set a breakpoint: the program stops before this node runs (F9)");
				}
				if (clicked)
					mApp.ToggleBreakpoint(mg, node);
			}

			// The value of the pin under the mouse is a line of the pin's hover text (GraphPanel.PinTooltip).
		}

		/// Values of the stopped node's value pins, in small bubbles beside the pins.
		void DrawStopValues(GraphTab tab, Sheet mg, NodeLay L, ImDrawList* dl)
		{
			float z = tab.Zoom;
			float ui = Look.Scale;
			float fs = mFontSize * 0.85f * z;
			let node = L.Node;
			for (int pass < 2)
			{
				let pins = (pass == 0) ? node.Inputs : node.Outputs;
				for (let p in pins)
				{
					if (p.Kind != .Value)
						continue;
					if (!TryGetPin(p.Id, let pl) || !pl.Visible)
						continue;
					String v = scope .();
					if (!mApp.DebugPinValue(mg, p, v))
						continue;
					// A class reference: the object's type is enough beside a pin (Locals has the address).
					let addr = v.IndexOf(" (0x");
					if (addr > 0 && v.EndsWith(')'))
						v.RemoveToEnd(addr);
					if (v.Length > 40)
					{
						v.RemoveToEnd(37);
						v.Append("...");
					}
					let c = PinScreen(tab, pl);
					float tw = Gui.CalcTextSize(v).x * (fs / mFontSize);
					float padX = 4 * z * ui;
					float h = fs + 4 * z;
					ImVec2 a;
					if (p.IsInput)
						a = .(c.x - 12 * z * ui - tw - padX * 2, c.y - h * 0.5f);
					else
						a = .(c.x + 12 * z * ui, c.y - h * 0.5f);
					let b = a + ImVec2(tw + padX * 2, h);
					Gui.ImDrawList_AddRectFilled(dl, a, b, Gui.Color(40, 34, 10, 235), 3 * z, 0);
					Gui.ImDrawList_AddRect(dl, a, b, Theme.WithAlpha(cStopYellow, 200), 3 * z, 1, 0);
					Text(dl, .(a.x + padX, a.y + 2 * z), fs, Gui.Color(255, 230, 150), v);
				}
			}
		}
	}
}
