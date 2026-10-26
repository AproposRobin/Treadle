// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.IO;
using ImGui;

namespace Treadle.Editor
{
	static class FocusNative
	{
		[CLink] public static extern void* igGetIO_Nil();
		[CLink] public static extern void ImGuiIO_AddFocusEvent(void* io, bool focused);
		[CLink] public static extern void ImGuiIO_AddMousePosEvent(void* io, float x, float y);
		[CLink] public static extern void ImGuiIO_AddMouseButtonEvent(void* io, int32 button, bool down);
		[CLink] public static extern void ImGuiIO_AddKeyEvent(void* io, int32 key, bool down);
	}

	/// The `focus` case (runs after `entry`, so after a captured Run): the window loses the input focus for a while and
	/// gets it back, many times over, with the pointer leaving and coming back, the click arriving with the focus or
	/// after it, and idle pauses of different lengths (the frame loop sleeps in between). Each time a click on the File
	/// menu must open it and Esc must close it again: the editor takes mouse and keyboard input after a focus loss.
	/// Once with the project open, once on the start page. The input goes into ImGui's queue as the platform layer
	/// adds it (a quiet test window never has the system focus).
	extension EditorApp
	{
		/// The File menu of the menu row, in screen coordinates (while it is closed).
		public ImVec2 mFileMenuMin;
		public ImVec2 mFileMenuMax;

		int mFoPhase;
		int mFoIter;
		int mFoStage;
		int mFoWait;
		double mFoT0;
		int mFoClickFail;
		int mFoKeyFail;
		int mFoRuns;
		String mFoProject = new .() ~ delete _;
		const int cFocusIters = 24;
		static float[?] cFocusPause = .(0, 0.05f, 0.3f, 1.2f, 2.5f, 0.0f);

		void FoMouse(bool move, int down)
		{
			let io = FocusNative.igGetIO_Nil();
			if (move)
				FocusNative.ImGuiIO_AddMousePosEvent(io, (mFileMenuMin.x + mFileMenuMax.x) * 0.5f, (mFileMenuMin.y + mFileMenuMax.y) * 0.5f);
			if (down >= 0)
				FocusNative.ImGuiIO_AddMouseButtonEvent(io, 0, down == 1);
		}

		bool SelfTestFocus()
		{
			let io = FocusNative.igGetIO_Nil();
			bool anyPopup = Gui.igIsPopupOpen_Str("", PopupFlags.AnyPopup);
			switch (mFoPhase)
			{
			case 0:
				// start: settle, nothing open
				if (mFoStage == 0)
				{
					mFoProject.Set(mProjectRoot);
					mFoClickFail = mFoKeyFail = mFoRuns = 0;
				}
				mFoIter = 0;
				mFoPhase = 1;
				mFoWait = 10;
			case 1:
				// one round: the focus goes (the pointer leaves first, as when another window is clicked)
				if (--mFoWait > 0)
					return false;
				if (anyPopup || mFileMenuMax.x <= mFileMenuMin.x)
				{
					FocusNative.ImGuiIO_AddKeyEvent(io, Key.Escape, true);
					FocusNative.ImGuiIO_AddKeyEvent(io, Key.Escape, false);
					mFoWait = 5;
					if (++mFoRuns > 400)
					{
						SelfTestCheck(false, "focus: the File menu could not be found closed");
						mFoPhase = 9;
					}
					return false;
				}
				if (mFoIter > 0) // round 0: no focus change (the harness itself)
				{
					FocusNative.ImGuiIO_AddMousePosEvent(io, -float.MaxValue, -float.MaxValue);
					FocusNative.ImGuiIO_AddFocusEvent(io, false);
				}
				mFoT0 = Desktop.Now;
				mFoPhase = 2;
				mFoWait = 2;
			case 2:
				// away for a while (the idle loop sleeps), then the focus comes back
				mFoWait--;
				if (mFoWait > 0 || Desktop.Now - mFoT0 < cFocusPause[mFoIter % cFocusPause.Count])
					return false;
				if (mFoIter > 0)
					FocusNative.ImGuiIO_AddFocusEvent(io, true);
				// the activating click comes with the focus (every third round) or a moment later
				bool withFocus = mFoIter % 3 == 0;
				FoMouse(true, withFocus ? 1 : -1);
				mFoPhase = withFocus ? 4 : 3;
				mFoWait = 2;
			case 3:
				if (--mFoWait > 0)
					return false;
				FoMouse(true, 1);
				mFoPhase = 4;
				mFoWait = 2;
			case 4:
				if (--mFoWait > 0)
					return false;
				FoMouse(true, 0);
				mFoPhase = 5;
				mFoWait = 40;
			case 5:
				// the click opened the File menu
				if (!anyPopup && --mFoWait > 0)
					return false;
				if (!anyPopup)
				{
					mFoClickFail++;
					Notify.Log(.Warning, "SelfTest", scope $"focus: round {mFoIter} ({(mFoStage == 0 ? "project" : "start page")}): the click after the focus came back was not taken");
				}
				FocusNative.ImGuiIO_AddKeyEvent(io, Key.Escape, true);
				mFoPhase = 6;
				mFoWait = 2;
			case 6:
				if (--mFoWait > 0)
					return false;
				FocusNative.ImGuiIO_AddKeyEvent(io, Key.Escape, false);
				mFoPhase = 7;
				mFoWait = 40;
			case 7:
				// Esc closed it
				if (anyPopup && --mFoWait > 0)
					return false;
				if (anyPopup)
				{
					mFoKeyFail++;
					Notify.Log(.Warning, "SelfTest", scope $"focus: round {mFoIter} ({(mFoStage == 0 ? "project" : "start page")}): Esc after the focus came back was not taken");
				}
				mFoIter++;
				mFoPhase = (mFoIter < cFocusIters) ? 1 : 8;
				mFoWait = 3;
			case 8:
				if (mFoStage == 0 && !mProjectRoot.IsEmpty)
				{
					// the same on the start page
					for (let d in mDocs)
						d.Modified = false;
					RequestCloseProject();
					mFoStage = 1;
					mFoPhase = 1;
					mFoIter = 0;
					mFoWait = 20;
					return false;
				}
				SelfTestCheck(mFoClickFail == 0 && mFoKeyFail == 0, scope $"focus: after {(mFoStage + 1) * (cFocusIters - 1)} focus losses ({(mFoStage == 1 ? "project and start page" : "one view")}, pauses up to 2.5 s) every click and key is taken (clicks missed {mFoClickFail}, keys missed {mFoKeyFail})");
				// a press whose release went elsewhere: ImGui holds the button, the system does not
				FocusNative.ImGuiIO_AddMousePosEvent(io, -float.MaxValue, -float.MaxValue);
				FocusNative.ImGuiIO_AddMouseButtonEvent(io, 0, true);
				mFoPhase = 9;
				mFoWait = 3;
			case 9:
				if (--mFoWait > 0)
					return false;
#if !BF_PLATFORM_WINDOWS
				// the reset and the frame-loop watch are Windows-only (the reported freeze is on Windows)
				FocusNative.ImGuiIO_AddMouseButtonEvent(io, 0, false);
				mFoPhase = 12;
				return false;
#endif
				bool held = Gui.igIsMouseDown_Nil(0);
				bool reset = ResetStaleInput("the focus self test");
				SelfTestCheck(held && reset, scope $"focus: a mouse button held in the editor but up in the system is found (held {held}, reset {reset})");
				mFoPhase = 10;
				mFoWait = 3;
			case 10:
				if (--mFoWait > 0)
					return false;
				SelfTestCheck(!Gui.igIsMouseDown_Nil(0), "focus: after the reset the button is up, so the next click is a click");
				// the frame loop stops for 6.5 s: the watch thread records it with the main thread's stack
				System.Threading.Thread.Sleep(6500);
				mFoPhase = 11;
				mFoT0 = Desktop.Now;
			case 11:
				String log = scope .();
				{
					// the log is open for writing: read it sharing write access
					FileStream fs = scope .();
					if (fs.Open(SessionLog.LogPath, .Read, .ReadWrite) case .Ok)
					{
						StreamReader rd = scope .(fs);
						rd.ReadToEnd(log).IgnoreError();
					}
				}
				bool stalled = log.Contains("[watch] frame loop stalled 5 s (stage: editor frame)") || log.Contains("[watch] frame loop stalled 6 s (stage: editor frame)");
				bool again = log.Contains("[watch] frame loop running again after");
				if ((!stalled || !again) && Desktop.Now - mFoT0 < 5)
					return false;
				SelfTestCheck(stalled && again && log.Contains("SelfTestFocus"), scope $"focus: a frame loop stopped for 6.5 s is recorded in the session log with the main thread's stack (stalled line {stalled}, running-again line {again})");
				mFoPhase = 12;
			default:
				if (mFoStage == 1 && !mFoProject.IsEmpty)
					RequestOpenProject(mFoProject);
				mFoStage = 0;
				mFoPhase = 0;
				return true;
			}
			return false;
		}
	}
}
#endif
