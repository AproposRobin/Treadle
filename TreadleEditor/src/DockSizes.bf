using System;
using ImGui;

namespace Treadle.Editor
{
	/// The bottom dock (Project Browser, Output Log, Problems, Find Results): about a fifth of the
	/// window by default, so the Sheet keeps most of a 1280x800 window. The height the user drags it
	/// to is kept in settings.json ("session": bottomDockH, in pixels at 100 % scale, and the dock node
	/// it belongs to) and used again when the default layout is rebuilt. Like the dock itself, the
	/// height stays when the window is resized.
	extension EditorApp
	{
		/// The default height of the bottom dock, as a fraction of the window.
		const float cBottomDockDefault = 0.22f;
		/// The user's bottom dock height in pixels at 100 % scale (0: never resized).
		float mBottomDockH;
		/// The dock node the default layout made for the bottom panels.
		uint32 mBottomDockNode;
		/// The bottom dock's height in pixels as last drawn (0 before a bottom panel has drawn).
		float mBottomDockSeenH;

		[CLink] static extern uint32 igGetWindowDockID();
		[CLink] static extern bool igIsWindowDocked();

		/// The split ratio of the bottom dock when the default layout is built: the user's height, else
		/// 22 % of the window; at least a few rows of the Output Log, at most most of the window.
		float BottomDockRatio()
		{
			let viewport = Gui.igGetMainViewport();
			float workH = Math.Max(viewport.WorkSize.y, 1);
			float h = (mBottomDockH > 0) ? mBottomDockH * Look.Scale : cBottomDockDefault * viewport.Size.y;
			h = Math.Max(h, 150 * Look.Scale);
			return Math.Clamp(h / workH, 0.08f, 0.7f);
		}

		/// The bottom dock's height in pixels as last drawn (the self test).
		public float BottomDockHeight => mBottomDockSeenH;

		/// Called inside each bottom panel's window: remembers the dock's height once the user has let
		/// go of the splitter (a panel moved elsewhere is not the bottom dock and is ignored).
		void NoteBottomDock()
		{
			if (mBottomDockNode == 0 || !igIsWindowDocked() || igGetWindowDockID() != mBottomDockNode)
				return;
			float h = Gui.igGetWindowSize().y;
			float before = mBottomDockSeenH;
			mBottomDockSeenH = h;
			// Only a change made with the mouse (the splitter) is the user's size; a window resize is not.
			if (Gui.igIsMouseDown_Nil(0))
			{
				if (before > 0 && Math.Abs(h - before) > 0.5f)
					mBottomDockDragged = true;
				return;
			}
			if (!mBottomDockDragged)
				return;
			mBottomDockDragged = false;
			float logical = h / Math.Max(Look.Scale, 0.5f);
			if (Math.Abs(logical - mBottomDockH) > 2)
			{
				mBottomDockH = logical;
				SaveSettings();
			}
		}

		/// The bottom dock changed height while the mouse button was down (saved on release).
		bool mBottomDockDragged;
	}
}
