using System;
using System.Collections;
using System.IO;

using ImGui;
using Treadle.Graph;
using Treadle.Document;
using Treadle.Language;

namespace Treadle.Editor
{
	/// Dockable panel names. The part after "###" is the stable ImGui id (layouts, focus calls);
	/// the visible part carries the panel's icon. Use `Panels.Focus(Panels.PropertiesId)`.
	static class Panels
	{
		public const String Outline = "\u{E065}  Outline###Outline";
		public const String Graph = "\u{E42A}  Graph###Graph";
		public const String Properties = "\u{E29A}  Properties###Properties";
		public const String ProjectBrowser = "\u{E0DC}  Project Browser###Project Browser";
		public const String OutputLog = "\u{E20A}  Output Log###Output Log";
		/// The Problems panel (errors and warnings of the last Build and the last Validate). The id
		/// stays "Compiler Results" so saved layouts keep its place.
		public const String CompilerResults = "\u{E088}  Problems###Compiler Results";
		public const String FindResults = "\u{E626}  Find Results###Find Results";
		public const String Locals = "\u{E478}  Locals###Locals";
		public const String CallStack = "\u{E104}  Call Stack###Call Stack";
		public const String DebugOutput = "\u{E185}  Debug Output###Debug Output";

		public const String OutlineId = "###Outline";
		public const String GraphId = "###Graph";
		public const String PropertiesId = "###Properties";
		public const String ProjectBrowserId = "###Project Browser";
		public const String OutputLogId = "###Output Log";
		public const String CompilerResultsId = "###Compiler Results";
		public const String FindResultsId = "###Find Results";
		public const String LocalsId = "###Locals";
		public const String CallStackId = "###Call Stack";
		public const String DebugOutputId = "###Debug Output";

		public static void Focus(StringView id) => Gui.igSetWindowFocus_Str(scope String(id));

		/// The titles of the narrow right dock, for `FitTabWidth`.
		public static String[?] Narrow = .(Properties, Locals, CallStack);

		/// Dock tabs shrink to `TabMinWidthShrink` before they scroll; ImGui's 80 px default cut
		/// "Properties" in the narrow right dock (most at 125 %). The floor is the
		/// widest title of that dock at the current font and scale, so they stay whole; a longer
		/// title in the wide bottom dock can still shrink to it (its tooltip shows the full name),
		/// and a dock too narrow for its tabs scrolls them.
		/// When that dock is too narrow for its tabs whole (three tabs at 1280x800: Properties, Locals and Call
		/// Stack during a debug session), the floor drops to an equal share of the dock's width so every tab
		/// stays reachable without the scroll arrows (the arrows hid Call Stack); a cut title shows "..." and
		/// its whole name in the tab's tooltip. Below `cNarrowTabMin` of the scale the tabs scroll again.
		public static void FitTabWidth()
		{
			let style = Gui.igGetStyle();
			float widest = 0;
			for (let title in Narrow)
			{
				int end = title.IndexOf("###");
				let w = Gui.igCalcTextSize(title.Ptr, title.Ptr + ((end < 0) ? title.Length : end), false, -1).x;
				widest = Math.Max(widest, w);
			}
			float whole = widest + style.FramePadding.x * 2 + 1;
			float floor = whole;
			// the dock most narrow panels sat in last frame, and how many tabs it had
			int n = 0;
			float dockW = 0;
			for (int i < sNarrowSeen)
			{
				int same = 0;
				for (int j < sNarrowSeen)
					if (sNarrowDock[j] == sNarrowDock[i])
						same++;
				if (same > n)
				{
					n = same;
					dockW = sNarrowW[i];
				}
			}
			sNarrowSeen = 0;
			if (n >= 2)
			{
				let spacing = style.ItemInnerSpacing.x;
				// the tab bar: the dock less its border and frame padding each side (DockNodeCalcTabBarLayout)
				let room = dockW - 2 * (style.WindowBorderSize + style.FramePadding.x) - (n - 1) * spacing - 2;
				if (n * whole > room)
					floor = Math.Max(room / n, cNarrowTabMin * Look.Scale);
			}
			style.TabMinWidthShrink = floor;
			NarrowTabFloor = floor;
			NarrowTabs = n;
			NarrowDockW = dockW;
		}

		const float cNarrowTabMin = 44;
		static uint32[3] sNarrowDock;
		static float[3] sNarrowW;
		static int sNarrowSeen;
		/// The tab floor `FitTabWidth` chose this frame (the `editor` self test reads it).
		public static float NarrowTabFloor;
		/// The tabs of that dock last frame and its width.
		public static int NarrowTabs;
		public static float NarrowDockW;

		/// Called by each narrow-dock panel between its Begin and End: notes the dock it sits in and its width
		/// for the next frame's `FitTabWidth`.
		public static void NoteNarrow()
		{
			if (sNarrowSeen >= 3 || !Gui.igIsWindowDocked())
				return;
			sNarrowDock[sNarrowSeen] = Gui.igGetWindowDockID();
			sNarrowW[sNarrowSeen] = Gui.igGetWindowWidth();
			sNarrowSeen++;
		}
	}

	/// The Build button states.
	enum CompileState
	{
		NotCompiled,
		/// Needs build: sources changed or unsaved edits.
		Unknown,
		Compiling,
		Good,
		Warnings,
		Error
	}

	/// The editor shell: theme + DPI, the toolbar under the menu bar, the status bar, the window
	/// title, toasts and the frame-pacing hints for the main loop.
	extension EditorApp
	{
		double mDpiCheckTime;
		String mWindowTitle = new .() ~ delete _;
		int mBuildLogged;
		bool mBuildToastPending;
		public ImFont* UiFont;
		float mToolbarH;
		/// The width every button would take with its label this frame, and whether the last frame
		/// found that too wide for the window: then labels are dropped (the tooltip carries them).
		float mToolbarFullW;
		bool mToolbarCompact;
		float mStatusH;
		/// Panels the Window menu can show / hide.
		public bool ShowOutputLog = true;
		public bool ShowFindResults;
		public bool ShowCompilerResults = true;
		bool mFocusCompilerResults;
		bool mFocusOutputLog;

		// ---------------------------------------------------------------- focus record

		[CLink] static extern uint32 igGetActiveID();
		[CLink] static extern void* igGetTopMostAndVisiblePopupModal();
		bool mWasForeground = true;
		double mBackgroundSince;
		int mFocusLogLeft = 200;

		/// The session log records each time the window loses and regains the system focus, with what the editor's
		/// input state is on return (an open modal, an active widget, a held button) and a frame that took over two
		/// seconds: a report of input that stops after switching windows then shows where it stopped.
		void TrackWindowFocus(double now)
		{
			if (mFrame > 2 && LastFrameMs > 2000 && mFocusLogLeft > 0)
			{
				mFocusLogLeft--;
				Notify.Log(.Warning, "Editor", scope $"A frame took {(int)LastFrameMs} ms (foreground: {mWasForeground})");
			}
			if (Desktop.QuietWindow || mFocusLogLeft <= 0)
				return;
			bool fg = Desktop.IsForeground;
			if (fg == mWasForeground)
				return;
			mWasForeground = fg;
			mFocusLogLeft--;
			if (!fg)
			{
				mBackgroundSince = now;
				Notify.Log(.Verbose, "Editor", "Window lost the focus");
				return;
			}
			String modal = scope .("none");
			let m = igGetTopMostAndVisiblePopupModal();
			if (m != null && ((char8**)m)[1] != null)
				modal.Set(StringView(((char8**)m)[1]));
			Notify.Log(.Verbose, "Editor", scope $"Window has the focus again after {(int)(now - mBackgroundSince)} s: popup {Gui.igIsPopupOpen_Str("", PopupFlags.AnyPopup)}, modal {modal}, active widget {igGetActiveID():X}, button held {Gui.igIsAnyMouseDown()}, minimized {Desktop.IsMinimized}, drawing context {(Desktop.GLContextCurrent ? "current" : "LOST")}");
			ResetStaleInput("the window got the focus back");
		}

		/// The input state the editor holds that the system no longer has: a mouse button ImGui still thinks is
		/// down while it is up (its release went to another window, so every later click would be taken as part of
		/// that old press), and a mouse capture the window keeps with no button down (the system would send every
		/// click to it). Called when the window gets the focus back and when the display scale changes; logs one
		/// line "input path reset after <why>: ..." when it changed something. True then.
		public bool ResetStaleInput(StringView why)
		{
			String what = scope .();
#if BF_PLATFORM_WINDOWS
			let io = DragNative.igGetIO_Nil();
			int32[3] vk = .(0x01, 0x02, 0x04); // VK_LBUTTON, VK_RBUTTON, VK_MBUTTON (ImGui buttons 0, 1, 2)
			bool anyPhysical = false;
			for (int32 b < 3)
			{
				bool physical = (GetAsyncKeyState(vk[b]) & 0x8000) != 0;
				anyPhysical |= physical;
				if (Gui.igIsMouseDown_Nil(b) && !physical)
				{
					DragNative.ImGuiIO_AddMouseButtonEvent(io, b, false);
					what.AppendF("{}mouse button {} released", what.IsEmpty ? "" : ", ", b);
				}
			}
			let hwnd = Desktop.MainWindow;
			if (hwnd != null && !anyPhysical && GetCapture() == hwnd)
			{
				ReleaseCapture();
				what.AppendF("{}mouse capture released", what.IsEmpty ? "" : ", ");
			}
#endif
			if (what.IsEmpty)
				return false;
			Notify.Log(.Info, "Editor", scope $"input path reset after {why}: {what}");
			return true;
		}

#if BF_PLATFORM_WINDOWS
		[Import("user32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int16 GetAsyncKeyState(int32 key);
		[Import("user32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern void* GetCapture();
		[Import("user32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 ReleaseCapture();
#endif

		// ---------------------------------------------------------------- frame hooks

		/// First thing every frame (before any window is drawn).
		void ShellBeginFrame()
		{
			if (UiFont == null)
				UiFont = Gui.igGetFont();
			let now = Desktop.Now;
			TrackWindowFocus(now);
			GraphicsTick(); // Ctrl+Alt+R, a failed restore (GraphicsDevice.bf)
			// Per-monitor DPI: follow the monitor the window is on.
			if (now - mDpiCheckTime > 0.5)
			{
				mDpiCheckTime = now;
				float s = Desktop.WindowDpiScale();
				if (Math.Abs(s - Look.Scale) > 0.01f)
				{
					Look.Apply(s);
					Notify.Log(.Info, "Editor", scope $"Display scale {(int)(s * 100 + 0.5f)}% (drawing context {(Desktop.GLContextCurrent ? "current" : "LOST")})");
					ResetStaleInput("a display change");
				}
			}
			Panels.FitTabWidth();
			StreamBuildOutput();
		}

		/// The build command line is logged once the build tool really starts.
		bool mBuildCommandLogged;

		/// Streams the build tool's output into the Output Log as it arrives (category "Build").
		void StreamBuildOutput()
		{
			if (mBuild == null)
			{
				mBuildLogged = 0;
				return;
			}
			if (!mBuildCommandLogged && mBuild.ProcessId != 0)
			{
				mBuildCommandLogged = true;
				Notify.Log(.Info, "Build", scope $"> {mBuild.CommandLine}");
			}
			while (mBuildLogged < mBuild.Output.Count)
			{
				let line = mBuild.Output[mBuildLogged++];
				if (line.IsEmpty)
					continue;
				LogLevel level = .Verbose;
				if (line.Contains("ERROR"))
					level = .Error;
				else if (line.Contains("WARNING"))
					level = .Warning;
				// Compiler messages with a location become links in the log.
				Diagnostic found = null;
				for (let m in mBuild.Messages)
				{
					if (m.Line > 0 && line.Contains(m.Path) && line.Contains(m.Text))
					{
						found = m;
						break;
					}
				}
				if (found != null)
					Notify.LogAt(level, "Build", line, found.Path, found.Line);
				else
					Notify.Log(level, "Build", line);
			}
		}

		/// Called when a build finishes (from Frame).
		void OnBuildFinished(int errors, int warnings)
		{
			StreamBuildOutput();
			String took = scope .();
			FormatSeconds(mBuild.BuildMs, took);
			if (mBuild.Cancelled)
				Notify.Log(.Warning, "Build", scope $"Build cancelled after {took} ({mBuild.Config}); the build tool and the programs it started were stopped");
			else if (mBuild.UpToDate)
				Notify.Log(.Info, "Build", scope $"Up to date ({mBuild.Config}): nothing changed since the last build, so the build tool was not run. Build > Force Build runs it anyway.");
			else
				Notify.Log(mBuild.Succeeded ? .Info : .Error, "Build", scope $"Build {(mBuild.Succeeded ? "finished" : "failed")} in {took} ({mBuild.Config})");
			if (mBuild.Cancelled)
				Notify.Warn("Build cancelled");
			else if (mBuild.Succeeded)
			{
				if (warnings > 0)
					Notify.Warn(scope $"Build complete with {warnings} warning{(warnings == 1) ? "" : "s"}");
				else if (mBuild.UpToDate)
					Notify.Success("Build complete: up to date");
				else
					Notify.Success("Build complete");
			}
			else
			{
				Notify.Error(scope $"Build failed: {errors} error{(errors == 1) ? "" : "s"}, {warnings} warning{(warnings == 1) ? "" : "s"}");
				mFocusCompilerResults = true;
			}
			OnRunBuildFinished();
			OnDebugBuildFinished();
		}

		/// "0.4 s", "12 s", "1 min 5 s".
		static void FormatSeconds(double ms, String outText)
		{
			let secs = ms / 1000.0;
			if (secs < 10)
				outText.AppendF("{:0.0} s", secs);
			else if (secs < 60)
				outText.AppendF("{} s", (int)secs);
			else
				outText.AppendF("{} min {} s", (int)secs / 60, (int)secs % 60);
		}

		/// Last thing every frame.
		void ShellEndFrame()
		{
			Notify.DrawToasts(mStatusH);
			UpdateWindowTitle();
		}

		/// The main loop keeps drawing at full rate while this is true; otherwise it sleeps until
		/// input arrives (see Desktop.PaceFrame).
		public bool WantsContinuousFrames
		{
			get
			{
				// A running compile is not a reason to draw every frame: the loop wakes about 30 times a
				// second for its output and elapsed time (IdleTimeoutMs), and at once on input, so the
				// editor does not take a processor core from the build.
				if (Notify.Animating || mCommitPending || GraphTab.Animating)
					return true;
				// A dialog is queued but not open yet (conflict / error modals open next frame).
				if (!mErrors.IsEmpty || !mConflicts.IsEmpty)
					return true;
				for (int b < 3)
					if (Gui.igIsMouseDown_Nil((int32)b))
						return true;
				// A popup (action menu, context menu, modal) animates, filters and tracks hover
				// every frame, so it must never be left on a stale frame by the idle sleep.
				if (Gui.igIsPopupOpen_Str("", PopupFlags.AnyPopup))
					return true;
				// A text field being edited (caret blink, typed characters, IME).
				if (Gui.igIsAnyItemActive())
					return true;
				return false;
			}
		}

		/// How long the idle loop may sleep: short while a text field is active (caret blink),
		/// shortest while a build or Validate's background checks are pending.
		public int32 IdleTimeoutMs => ((mBuild != null && mBuild.Running) || (mValidate != null && mValidate.Running) || (mDebug != null && mDebug.Waiting) || mDebugFocusLocals > 0) ? 33 : (mUpdates != null && mUpdates.Busy) ? 250 : (mNodeMenu != null && mNodeMenu.SearchPending) ? 20 : (Gui.igIsAnyItemActive() ? 500 : 1000);

		// ---------------------------------------------------------------- frame timing

		/// Start of the previous frame (Desktop.Now) and the length of the last whole frame.
		double mFramePrevAt;
		public double LastFrameMs;

		void TrackFrameTime()
		{
			let now = Desktop.Now;
#if TREADLE_SELFTEST
			FrameBeganAt = now;
#endif
			LastFrameMs = (mFramePrevAt > 0) ? Math.Max(0, now - mFramePrevAt - Desktop.IdleWaitSeconds) * 1000.0 : 0;
			mFramePrevAt = now;
			Desktop.IdleWaitSeconds = 0;
		}

		/// The build tool could not be started (the build ended before it began): say so, drop it.
		bool OnBuildStartFailed()
		{
			if (!mBuild.StartFailed)
				return false;
			SetStatus(mBuild.StartError, .Error);
			Notify.Log(.Error, "Build", mBuild.StartError);
			delete mBuild;
			mBuild = null;
			return true;
		}

		/// The build state: what the last build of this session said. Seam: a toolchain that keeps
		/// a record across sessions (what was built from which sources) reports it here.
		public CompileState GetCompileState()
		{
			if (mBuild == null)
				return .NotCompiled;
			if (mBuild.Running)
				return .Compiling;
			bool unsaved = false;
			for (let d in mDocs)
				if (d.Modified)
					unsaved = true;
			// Saving does not build: an edit since the build started leaves it "Needs build" (yellow).
			if (unsaved || BuildStale)
				return .Unknown;
			if (!mBuild.Succeeded)
				return .Error;
			int warnings = 0;
			for (let m in mBuild.Messages)
				if (!m.IsError)
					warnings++;
			return (warnings > 0) ? .Warnings : .Good;
		}

		static uint32 CompileColor(CompileState s)
		{
			switch (s)
			{
			case .NotCompiled: return Look.ForegroundDim;
			case .Unknown: return Look.AccentYellow;
			case .Compiling: return Look.AccentBlue;
			case .Good: return Look.Success;
			case .Warnings: return Look.Warning;
			case .Error: return Look.Error;
			}
		}

		static StringView CompileBadge(CompileState s)
		{
			switch (s)
			{
			case .NotCompiled: return Icon.CircleHelp;
			case .Unknown: return Icon.CircleHelp;
			case .Compiling: return Icon.LoaderCircle;
			case .Good: return Icon.CircleCheck;
			case .Warnings: return Icon.TriangleAlert;
			case .Error: return Icon.CircleX;
			}
		}

		StringView CompileTip(CompileState s)
		{
			switch (s)
			{
			case .NotCompiled: return "Not built yet (F7)";
			case .Unknown: return "Needs build: the sources changed since the last build (F7)";
			case .Compiling: return "Building...";
			case .Good: return "Up to date: the sources match the last successful build";
			case .Warnings: return "Up to date, with warnings from the last build";
			case .Error: return "The last build failed and the sources have not changed since";
			}
		}

		/// The status bar text for a build state.
		void CompileText(CompileState s, String outText)
		{
			switch (s)
			{
			case .NotCompiled: outText.Append("Not built");
			case .Unknown: outText.Append("Needs build");
			case .Compiling:
				outText.Append("Building...");
				if (mBuild != null)
				{
					outText.Append(' ');
					FormatSeconds(mBuild.ElapsedMs, outText);
				}
			case .Good: outText.Append("Up to date");
			case .Warnings: outText.Append("Up to date, with warnings");
			case .Error:
				int n = 0;
				if (mBuild != null)
					for (let m in mBuild.Messages)
						if (m.IsError)
							n++;
				outText.AppendF("Build failed ({} error{})", n, (n == 1) ? "" : "s");
			}
		}

		// ---------------------------------------------------------------- toolbar

		/// A UE toolbar button: icon + label, flat until hovered. Returns true when clicked.
		bool ToolbarButton(StringView id, StringView icon, StringView labelIn, StringView tipIn, bool enabled = true, uint32 iconColor = 0, bool active = false, StringView badge = default, uint32 badgeColor = 0)
		{
			float fs = Gui.igGetFontSize();
			var label = labelIn;
			var tip = tipIn;
			float iconSize = fs * 1.25f;
			float padX = fs * 0.55f;
			float labelW = label.IsEmpty ? 0 : Gui.CalcTextSize(label).x;
			mToolbarFullW += padX * 2 + iconSize + (label.IsEmpty ? 0 : (fs * 0.4f + labelW)) + 2 * Look.Scale;
			String compactTip = scope .();
			if (mToolbarCompact && !label.IsEmpty && id != "config")
			{
				compactTip.AppendF("{}\n{}", label, tip);
				tip = compactTip;
				label = "";
				labelW = 0;
			}
			float w = padX * 2 + iconSize + (label.IsEmpty ? 0 : (fs * 0.4f + labelW));
			float h = mToolbarH - fs * 0.5f;
			let pos = Gui.igGetCursorScreenPos();
			Gui.PushID(id);
			Gui.igBeginDisabled(!enabled);
			bool clicked = Gui.igInvisibleButton("##tb", .(w, h), ButtonFlags.MouseButtonLeft);
			bool hovered = Gui.igIsItemHovered(0);
			bool held = Gui.igIsItemActive();
			Gui.igEndDisabled();
			let dl = Gui.igGetWindowDrawList();
			if (active || hovered || held)
				Gui.ImDrawList_AddRectFilled(dl, pos, pos + ImVec2(w, h), held ? Look.PrimaryPress : (active ? Look.Header : Look.Dropdown), 4 * Look.Scale, 0);
			uint32 fg = enabled ? (hovered ? Look.ForegroundHover : Look.Foreground) : Gui.Color(90, 90, 90);
			uint32 ic = (iconColor != 0 && enabled) ? iconColor : fg;
			float cy = pos.y + h * 0.5f;
			let iconPos = ImVec2(pos.x + padX, cy - iconSize * 0.5f);
			Gui.DrawText(dl, iconPos, ic, icon, iconSize);
			if (!badge.IsEmpty)
			{
				float bs = fs * 0.8f;
				let bp = ImVec2(iconPos.x + iconSize - bs * 0.55f, iconPos.y + iconSize - bs * 0.8f);
				Gui.ImDrawList_AddCircleFilled(dl, bp + ImVec2(bs * 0.5f, bs * 0.5f), bs * 0.55f, Look.Title, 0);
				Gui.DrawText(dl, bp, badgeColor, badge, bs);
			}
			if (!label.IsEmpty)
				Gui.DrawText(dl, .(iconPos.x + iconSize + fs * 0.4f, cy - fs * 0.5f), fg, label);
			if (hovered && !tip.IsEmpty)
				Gui.Tooltip(tip);
			Gui.PopID();
			Gui.SameLine(0, 2 * Look.Scale);
			return clicked && enabled;
		}

		void ToolbarSeparator()
		{
			let pos = Gui.igGetCursorScreenPos();
			float h = mToolbarH - Gui.igGetFontSize() * 0.5f;
			mToolbarFullW += 12 * Look.Scale;
			let dl = Gui.igGetWindowDrawList();
			float x = pos.x + 5 * Look.Scale;
			Gui.ImDrawList_AddLine(dl, .(x, pos.y + h * 0.18f), .(x, pos.y + h * 0.82f), Look.Dropdown, 1);
			Gui.igDummy(.(10 * Look.Scale, h));
			Gui.SameLine(0, 2 * Look.Scale);
		}

		void DrawToolbar()
		{
			let vp = Gui.igGetMainViewport();
			float fs = Gui.igGetFontSize();
			mToolbarH = Math.Round(fs * 2.5f);
			Gui.igPushStyleVar_Vec2(StyleVar.WindowPadding, .(6 * Look.Scale, fs * 0.25f));
			Gui.igPushStyleColor_U32(Col.WindowBg, Look.Panel);
			int32 flags = WindowFlags.NoScrollbar | WindowFlags.NoSavedSettings | WindowFlags.NoScrollWithMouse;
			if (Gui.igBeginViewportSideBar("##VBToolbar", vp, Dir.Up, mToolbarH, flags))
			{
				Gui.igPopStyleVar(1);
				mToolbarFullW = 0;
				let state = GetCompileState();
				// A small dot on Validate while what is shown is from before the last edit (ValidationState.bf).
				let validateStale = ProblemsStale;
				if (ToolbarButton("validate", Icon.CircleCheck, "Validate",
					validateStale ? "Validate (Shift+F7): check the open Sheets now, without saving or building\nChanged since the last Validate: the problems shown are dimmed until you validate" : "Validate (Shift+F7): check the open Sheets now, without saving or building",
					!Doc.FilePath.IsEmpty || !Tabs.IsEmpty, 0, false, validateStale ? Icon.Circle : default, Look.AccentYellow))
					Validate();
				// Run first: one action that builds when needed and starts the program (RunProgram.bf).
				if (ProgramRunning)
				{
					if (ToolbarButton("stoprun", Icon.Square, "Stop", "Stop the running program", true, Look.Error, true))
						StopProgram();
				}
				else if (ToolbarButton("run", Icon.Play, "Run", "Run (Ctrl+F5): build if needed, then start the program", !mProjectRoot.IsEmpty && (mBuild == null || !mBuild.Running), Look.Success))
					RunProgram();
				if (mBuild != null && mBuild.Running)
				{
					if (ToolbarButton("cancelbuild", Icon.CircleX, "Cancel", "Cancel Build: stop the build tool now\nThe output files may be incomplete; the next Build starts from scratch.", true, 0, true))
						CancelBuild();
				}
				else if (ToolbarButton("compile", Icon.Compile, "Build", scope $"Build (F7): produce the exe without starting it\n{CompileTip(state)}", true, 0, false, CompileBadge(state), CompileColor(state)))
					Build();
				bool canSave = !Doc.FilePath.IsEmpty && !Doc.IsNewerFormat;
				if (ToolbarButton("save", Icon.Save, "Save", "Save the current file (Ctrl+S)", canSave, 0, false,
					(canSave && Doc.Modified) ? Icon.Circle : default, Look.Warning))
					Save();
				if (ToolbarButton("saveall", Icon.SaveAll, "", "Save All (Ctrl+Shift+S)", ModifiedCount > 0))
					SaveAll();
				if (ToolbarButton("browse", Icon.Browse, "Browse", "Show the current document in the Project Browser (Ctrl+B)", !Doc.FilePath.IsEmpty))
					BrowseToCurrent();
				ToolbarSeparator();
				if (ToolbarButton("find", Icon.Find, "Find", "Find in Sheets: search the whole project (Ctrl+Shift+F)", !mProjectRoot.IsEmpty, 0, ShowFindResults))
					OpenFindResults();
				ToolbarSeparator();
				let tab = CurrentTab;
				bool haveGraph = tab != null && CurrentMethod != null;
				if (ToolbarButton("arrange", Icon.Arrange, "Arrange", "Auto-arrange the graph by execution flow (layered)", haveGraph))
					ArrangeCurrentGraph();
				if (ToolbarButton("align", Icon.AlignStartVertical, "Align", "Align and distribute the selected nodes", haveGraph && tab.SelectedNodes.Count > 1))
					Gui.OpenPopup("##alignmenu");
				DrawAlignMenu(tab);
				if (ToolbarButton("minimap", Icon.Minimap, "", "Toggle the graph minimap (M)", haveGraph, 0, Prefs.ShowMinimap))
				{
					Prefs.ShowMinimap = !Prefs.ShowMinimap;
					Prefs.Save();
				}
				if (ToolbarButton("snap", Icon.Magnet, "", scope $"Snap nodes to the grid: {Prefs.GridSnap ? "on" : "off"}", true, 0, Prefs.GridSnap))
				{
					Prefs.GridSnap = !Prefs.GridSnap;
					Prefs.Save();
				}
				ToolbarSeparator();
				if (ToolbarButton("prefs", Icon.Settings, "", "Editor Preferences", true))
					OpenPreferences();

				// Too wide for the window (a big UI scale): drop the labels from the next frame on;
				// room for the asset name is not counted.
				mToolbarCompact = mToolbarFullW > Gui.igGetWindowWidth() - 14 * Look.Scale;

				// Asset name on the right, like UE's tab of the open Blueprint.
				String asset = scope .();
				GetCurrentAssetName(asset);
				if (!asset.IsEmpty)
				{
					String text = scope .();
					text.AppendF("{}{}", asset, (Doc.Modified ? " *" : ""));
					float tw = Gui.CalcTextSize(text).x + fs * 1.6f;
					float avail = Gui.igGetContentRegionAvail().x;
					if (avail > tw + 10)
					{
						Gui.SameLine(Gui.igGetCursorPos().x + avail - tw - 6 * Look.Scale);
						let pos = Gui.igGetCursorScreenPos();
						let dl = Gui.igGetWindowDrawList();
						float cy = pos.y + (mToolbarH - fs * 0.5f) * 0.5f;
						Gui.DrawText(dl, .(pos.x, cy - fs * 0.5f), Look.AccentBlue, Icon.Class);
						Gui.DrawText(dl, .(pos.x + fs * 1.6f, cy - fs * 0.5f), Look.ForegroundDim, text);
					}
				}
				// 1 px separator under the toolbar
				let wp = Gui.igGetWindowPos();
				let ws = Gui.igGetWindowSize();
				Gui.ImDrawList_AddLine(Gui.igGetWindowDrawList(), .(wp.x, wp.y + ws.y - 1), .(wp.x + ws.x, wp.y + ws.y - 1), Look.WindowBorder, 1);
			}
			else
				Gui.igPopStyleVar(1);
			Gui.End();
			Gui.igPopStyleColor(1);
		}

		/// The open document's name.
		void GetCurrentAssetName(String outName)
		{
			if (!Doc.FilePath.IsEmpty)
				Path.GetFileNameWithoutExtension(Doc.FilePath, outName);
		}

		/// Toolbar "Browse": shows the current file's folder in the Project Browser with its tile selected.
		void BrowseToCurrent()
		{
			if (Doc.FilePath.IsEmpty)
				return;
			String dir = scope .();
			Path.GetDirectoryPath(Doc.FilePath, dir).IgnoreError(); // no parent: dir stays empty
			NavigateCB(dir);
			String typeName = scope .();
			GetCurrentAssetName(typeName);
			String key = scope .();
			CBItem.MakeKey(.Document, Doc.FilePath, typeName, key);
			CBSelectOnly(key);
			mCBScrollTo.Set(key);
			Panels.Focus(Panels.ProjectBrowserId);
		}

		// ---------------------------------------------------------------- status bar

		void DrawStatusBar()
		{
			let vp = Gui.igGetMainViewport();
			float fs = Gui.igGetFontSize();
			mStatusH = Math.Round(fs * 1.75f);
			Gui.igPushStyleVar_Vec2(StyleVar.WindowPadding, .(4 * Look.Scale, 0));
			Gui.igPushStyleVar_Vec2(StyleVar.FramePadding, .(8 * Look.Scale, fs * 0.2f));
			Gui.igPushStyleColor_U32(Col.WindowBg, Look.Title);
			int32 flags = WindowFlags.NoScrollbar | WindowFlags.NoSavedSettings | WindowFlags.NoScrollWithMouse;
			if (Gui.igBeginViewportSideBar("##VBStatusBar", vp, Dir.Down, mStatusH, flags))
			{
				Gui.igSetCursorPosY((mStatusH - Gui.igGetFrameHeight()) * 0.5f);
				Gui.igPushStyleColor_U32(Col.Button, Gui.Color(0, 0, 0, 0));
				Gui.igPushStyleColor_U32(Col.Border, Gui.Color(0, 0, 0, 0));
				// UE: Project Drawer + Output Log buttons bottom-left.
				if (Gui.Button(scope $"{Icon.FolderOpen}  Project Drawer"))
					ToggleProjectDrawer();
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip("Open the Project Drawer (Ctrl+Space)");
				Gui.SameLine(0, 2);
				if (Gui.Button(scope $"{Icon.Log}  Output Log"))
				{
					ShowOutputLog = true;
					mFocusOutputLog = true;
				}
				Gui.igPopStyleColor(2);

				// Right side: compile state and save state, like UE's bottom-right corner.
				let state = GetCompileState();
				int modified = ModifiedCount;
				String compileText = scope .();
				CompileText(state, compileText);
				String saveText = scope .();
				if (Doc.FilePath.IsEmpty && mDocs.IsEmpty)
					saveText.Append("No file open");
				else if (modified > 0)
					saveText.AppendF("{} Unsaved", modified);
				else
					saveText.Append("All Saved");
				// Read-only (viewer) mode: a lock badge before the compile / save state.
				bool locked = FileSafety.ReadOnlyProject;
				StringView lockText = "Read-only";
				float w0 = locked ? (Gui.CalcTextSize(lockText).x + fs * 1.6f + 24 * Look.Scale) : 0;
				float w1 = Gui.CalcTextSize(compileText).x + fs * 1.6f;
				float w2 = Gui.CalcTextSize(saveText).x + fs * 1.6f;
				// "Validated" / "Not validated" before the build state (ValidationState.bf).
				String validateText = scope .();
				ValidateStateText(validateText, let validateColor, let validateIcon);
				float wv = Gui.CalcTextSize(validateText).x + fs * 1.6f + 24 * Look.Scale;
				// Update item (only while the notice line is hidden by Later): the far right, after the save state.
				String updLabel = scope .();
				UpdateStatusLabel(updLabel);
				float updW = updLabel.IsEmpty ? 0 : Gui.CalcTextSize(updLabel).x + Gui.igGetStyle().FramePadding.x * 2 + 24 * Look.Scale;
				float total = w0 + wv + w1 + w2 + 24 * Look.Scale + updW + EntryStatusWidth(); // EntryStatusWidth: "Entry: Program.Main" (EntryPoint.bf)
				// The latest status text, cut with "..." where the right side starts (a long path
				// must not run under the compile state); the whole text is the tooltip.
				if (!mStatus.IsEmpty && Gui.igGetTime() - mStatusTime < 8)
				{
					Gui.SameLine(0, 16 * Look.Scale);
					float room = Gui.igGetWindowWidth() - total - 8 * Look.Scale - Gui.igGetCursorPos().x - 16 * Look.Scale;
					if (room > fs * 2)
					{
						String shown = scope .();
						FitText(mStatus, room, shown);
						Gui.igAlignTextToFramePadding();
						Gui.TextColored(Look.ForegroundDim, shown);
						if (shown.Length != mStatus.Length && Gui.igIsItemHovered(0))
							Gui.Tooltip(mStatus);
					}
				}
				Gui.SameLine(Math.Max(Gui.igGetCursorPos().x + 10, Gui.igGetWindowWidth() - total - 8 * Look.Scale));
				let dl = Gui.igGetWindowDrawList();
				var p = Gui.igGetCursorScreenPos();
				float ty = Gui.igGetWindowPos().y + (mStatusH - fs) * 0.5f;
				if (locked)
				{
					Gui.DrawText(dl, .(p.x, ty), Look.Warning, Icon.Lock);
					Gui.DrawText(dl, .(p.x + fs * 1.4f, ty), Look.Warning, lockText);
					p.x += w0;
				}
				Gui.DrawText(dl, .(p.x, ty), validateColor, validateIcon);
				Gui.DrawText(dl, .(p.x + fs * 1.4f, ty), Look.Foreground, validateText);
				if (Gui.igIsMouseHoveringRect(.(p.x, p.y), .(p.x + wv - 24 * Look.Scale, p.y + mStatusH), true))
					Gui.Tooltip(Validated ? "The problems shown are of the Sheets as they are now (Validate, Build or Run)" : "Not validated: press Validate (Shift+F7) to check the open Sheets; problems shown from an earlier Validate are dimmed");
				p.x += wv;
				DrawEntryStatus(dl, ref p, ty); // "Entry: Program.Main" next to the build state; a click opens it (EntryPoint.bf)
				Gui.DrawText(dl, .(p.x, ty), CompileColor(state), CompileBadge(state));
				Gui.DrawText(dl, .(p.x + fs * 1.4f, ty), Look.Foreground, compileText);
				p.x += w1 + 24 * Look.Scale;
				uint32 saveCol = (modified > 0) ? Look.Warning : Look.Foreground;
				Gui.DrawText(dl, .(p.x, ty), saveCol, (modified > 0) ? Icon.Circle : Icon.Save);
				Gui.DrawText(dl, .(p.x + fs * 1.4f, ty), saveCol, saveText);
				if (!updLabel.IsEmpty)
				{
					Gui.igSetCursorPos(.(Gui.igGetWindowWidth() - 8 * Look.Scale - (updW - 24 * Look.Scale), (mStatusH - Gui.igGetFrameHeight()) * 0.5f));
					if (Gui.Button(updLabel))
						OpenUpdatePrefs();
					if (Gui.igIsItemHovered(0))
						Gui.Tooltip("Open Editor Preferences > Updates (install the update there)");
				}
				Gui.igDummy(.(total, fs));
			}
			Gui.End();
			Gui.igPopStyleColor(1);
			Gui.igPopStyleVar(2);
		}

		// ---------------------------------------------------------------- window title

		/// "Treadle alpha - <Project> - <Type> - <Sheet> *", following the type and the Sheet in front.
		void UpdateWindowTitle()
		{
			String title = scope .(scope $"{TreadleInfo.Name} {TreadleInfo.FullVersion}");
			if (!mProjectRoot.IsEmpty)
			{
				String name = scope .();
				Path.GetFileName(mProjectRoot, name);
				title.AppendF(" - {}", name);
			}
			String front = scope .();
			FrontTypeAndSheet(front);
			if (!front.IsEmpty)
			{
				title.AppendF(" - {}", front);
				if (Doc.Modified)
					title.Append(" *");
			}
			if (title != mWindowTitle)
			{
				mWindowTitle.Set(title);
				Desktop.SetTitle(title);
			}
		}
	}
}

namespace Treadle.Editor
{
	/// A document saved by a newer format version (docs/Format-Stability.md 2): it opens read-only
	/// with a notice bar over its Sheets; Save, edits (CheckWritable) and Build are refused.
	extension EditorApp
	{
		/// The notice for the active document when its format is newer than this build; false otherwise.
		public bool FormatNotice(String outText)
		{
			if (Doc == null || !Doc.IsNewerFormat)
				return false;
			String name = scope .();
			Path.GetFileName(Doc.FilePath, name);
			outText.AppendF("{}: ", name);
			Treadle.Format.Migrations.NewerMessage(Doc.NewerVersion, outText);
			outText.Append(". Save, edits and Build are off for this file.");
			return true;
		}

		/// The notice bar at the top of the graph area (DrawGraphArea).
		void DrawFormatNotice()
		{
			String text = scope .();
			if (!FormatNotice(text))
				return;
			let pos = Gui.igGetCursorPos();
			Gui.igSetCursorPos(.(pos.x + 10 * Look.Scale, pos.y + 4 * Look.Scale));
			Gui.igAlignTextToFramePadding();
			Gui.TextColored(Look.Warning, scope $"{Icon.Lock}  {text}");
			Gui.igSetCursorPos(.(pos.x, Gui.igGetCursorPos().y + 2 * Look.Scale));
		}

		/// True (with a status line) when an open document is newer than this build: `action`
		/// (Build) is refused, as `--build-run` refuses with exit code 2.
		bool RefuseNewerFormat(StringView action)
		{
			for (let d in mDocs)
			{
				if (!d.IsNewerFormat)
					continue;
				SetStatus(scope $"{action} refused: {d.FilePath}: {Treadle.Format.Migrations.NewerMessage(d.NewerVersion, .. scope String())}", .Warning);
				return true;
			}
			return false;
		}
	}
}
