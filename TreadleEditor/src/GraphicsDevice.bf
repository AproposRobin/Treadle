using System;
using ImGui;

namespace Treadle.Editor
{
	/// The graphics device seen from the editor. The host finds a lost or no longer current drawing context by itself and
	/// rebuilds it (Native/host/treadlehost.cpp, "the graphics device"); the editor adds the manual way back, Window >
	/// Restore Graphics (Ctrl+Alt+R), which runs the same rebuild on demand, also after the automatic one gave up, and
	/// tells the user once when it did give up. Documents, undo and autosave are not part of it: they never touch the GPU.
	extension EditorApp
	{
		bool mGlFailedNoted;
		/// Restore Graphics requests (menu and shortcut) so far: the self test checks the shortcut reaches it.
		public int RestoreGraphicsRequests;

		/// Rebuilds the drawing context at the start of the next frame.
		public void RestoreGraphics(StringView why)
		{
			RestoreGraphicsRequests++;
			Notify.Log(.Info, "Graphics", scope $"Restore Graphics ({why})");
			Host.th_gl_request_restore(scope String(why));
			mGlFailedNoted = false;
		}

		/// Every frame (ShellBeginFrame): Ctrl+Alt+R, and one note when the host gave up.
		void GraphicsTick()
		{
			if (Gui.IsCtrlDown && Gui.IsAltDown && !Gui.IsShiftDown && Gui.IsKeyPressed(Key.R, false))
				RestoreGraphics("Ctrl+Alt+R");
			if (Host.th_gl_failed() != 0)
			{
				if (!mGlFailedNoted)
				{
					mGlFailedNoted = true;
					Notify.Warn("The graphics device was lost and could not be restored. Save All and restart (Window > Restore Graphics tries again).");
				}
			}
			else
				mGlFailedNoted = false;
		}
	}
}
