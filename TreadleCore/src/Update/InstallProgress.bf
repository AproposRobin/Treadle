using System;
using System.Threading;
using Treadle.Language;

namespace Treadle.Update
{
	/// The small plain window the update helper shows while it installs ("Installing Treadle 0.1.4-alpha: 120 of
	/// 4100 files" and a progress bar), so a long swap does not look dead. Windows only (the Linux helper has no
	/// window); never in a self test, a quiet run or when TREADLE_UPDATE_NO_WINDOW is set.
	class InstallProgress
	{
#if BF_PLATFORM_WINDOWS
		[Import("user32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern void* CreateWindowExW(uint32 exStyle, char16* cls, char16* title, uint32 style, int32 x, int32 y, int32 w, int32 h, void* parent, void* menu, void* inst, void* param);
		[Import("user32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 PeekMessageW(void* msg, void* hwnd, uint32 min, uint32 max, uint32 remove);
		[Import("user32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 TranslateMessage(void* msg);
		[Import("user32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int DispatchMessageW(void* msg);
		[Import("user32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 DestroyWindow(void* hwnd);
		[Import("user32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int SendMessageW(void* hwnd, uint32 msg, int wParam, int lParam);
		[Import("user32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 SetWindowTextW(void* hwnd, char16* text);
		[Import("user32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 GetSystemMetrics(int32 index);
		[Import("comctl32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern void InitCommonControls();

		String mTitle = new .() ~ delete _;
		String mText = new .() ~ delete _;
		Monitor mLock = new .() ~ delete _;
		int mDone;
		int mTotal;
		bool mStop;
		Thread mThread;
		bool mJoined;

		/// A window for the install of `version`; null when none is wanted (quiet runs, self tests) or possible.
		public static InstallProgress Start(StringView version)
		{
			String v = scope .();
#if TREADLE_SELFTEST
			if ((Environment.GetEnvironmentVariable("TREADLE_SELFTEST", v) case .Ok) && !v.IsEmpty)
				return null;
#endif
			v.Clear();
			if ((Environment.GetEnvironmentVariable("TREADLE_UPDATE_NO_WINDOW", v) case .Ok) && !v.IsEmpty)
				return null;
			v.Clear();
			if ((Environment.GetEnvironmentVariable("TREADLE_WINDOW_HIDDEN", v) case .Ok) && v == "1")
				return null;
			let p = new InstallProgress();
			p.mTitle.AppendF("Installing Treadle {}", version);
			p.mText.AppendF("Installing Treadle {}...", version);
			p.mThread = new Thread(new () => p.Run());
			p.mThread.IsBackground = true;
			p.mThread.Start(false);
			return p;
		}

		/// From the helper's thread: what it is doing and how far (done of total).
		public void Set(StringView phase, int done, int total)
		{
			using (mLock.Enter())
			{
				mText.Clear();
				if (total > 0)
					mText.AppendF("{}: {} of {} files", phase, done, total);
				else
					mText.AppendF("{}...", phase);
				mDone = done;
				mTotal = total;
			}
		}

		/// Closes the window.
		public void Close()
		{
			using (mLock.Enter())
				mStop = true;
			if (mThread != null)
				ThreadJoin.Join(mThread, ref mJoined, 3000);
		}

		public ~this()
		{
			Close();
			if (mThread != null && mJoined)
				delete mThread;
		}

		void Run()
		{
			InitCommonControls();
			int32 w = 440;
			int32 h = 120;
			int32 x = (GetSystemMetrics(0) - w) / 2;
			int32 y = (GetSystemMetrics(1) - h) / 2;
			// WS_CAPTION | WS_VISIBLE, topmost; the predefined STATIC class gives a plain window with no code of ours
			void* win = CreateWindowExW(0x8, "STATIC".ToScopedNativeWChar!(), mTitle.ToScopedNativeWChar!(), 0x00C00000 | 0x10000000, x, y, w, h, null, null, null, null);
			if (win == null)
				return;
			void* label = CreateWindowExW(0, "STATIC".ToScopedNativeWChar!(), "".ToScopedNativeWChar!(), 0x50000000, 16, 14, w - 48, 22, win, null, null, null);
			void* bar = CreateWindowExW(0, "msctls_progress32".ToScopedNativeWChar!(), "".ToScopedNativeWChar!(), 0x50000000, 16, 44, w - 48, 18, win, null, null, null);
			String shown = scope .();
			int shownDone = -1;
			int shownTotal = -1;
			uint8[64] msg = default;
			while (true)
			{
				String text = scope .();
				int done;
				int total;
				bool stop;
				using (mLock.Enter())
				{
					text.Set(mText);
					done = mDone;
					total = mTotal;
					stop = mStop;
				}
				if (stop)
					break;
				if (text != shown)
				{
					shown.Set(text);
					SetWindowTextW(label, text.ToScopedNativeWChar!());
				}
				if (done != shownDone || total != shownTotal)
				{
					shownDone = done;
					shownTotal = total;
					SendMessageW(bar, 0x0406 /* PBM_SETRANGE32 */, 0, (total > 0) ? total : 1);
					SendMessageW(bar, 0x0402 /* PBM_SETPOS */, (total > 0) ? done : 0, 0);
				}
				while (PeekMessageW(&msg[0], null, 0, 0, 1) != 0)
				{
					TranslateMessage(&msg[0]);
					DispatchMessageW(&msg[0]);
				}
				Thread.Sleep(40);
			}
			DestroyWindow(win);
		}
#else
		public static InstallProgress Start(StringView version) => null;
		public void Set(StringView phase, int done, int total) {}
		public void Close() {}
#endif
	}
}
