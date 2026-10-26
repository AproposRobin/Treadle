// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.IO;
using ImGui;

namespace Treadle.Editor
{
	/// `glreset` (chained after `editor`): the drawing context is lost behind the editor's back in four ways (deleted
	/// under it; a driver reset reported; deleted and the next three context creations failing, so a new window is
	/// opened and a retry is needed; deleted and every creation failing, so the rebuild gives up), and each time the
	/// next frames must find it, rebuild it and render again (a pixel of the rendered frame is read back) or, in the
	/// last case, keep the editor running without drawing until Ctrl+Alt+R restores it. Restore Graphics on a healthy
	/// context rebuilds it too.
	///
	/// `soak` (on its own; TREADLE_SOAK_MINUTES, default 45; TREADLE_SOAK_FOCUSED=1 keeps the focus): the editor idles
	/// for that long, without the focus for the last 40 minutes (a FOCUS_LOST from the platform layer), sampling every
	/// 30 s the process memory, the GL objects alive in the host's context, ImGui's textures and font atlas and the GPU
	/// memory the driver reports; after the warm-up none of them may grow by 5 % or more, and at the end the focus comes
	/// back and a click on the File menu must open it.
	extension EditorApp
	{
		int mGlPhase;
		int mGlWait;
		int mGlRebuilds0;
		int mGlRecreates0;
		int mGlRequests0;
		int mGlFrame0;
		double mGlT0;

		/// Asks for a pixel of the next frame; true once it was read (ok = it was read and is opaque).
		bool GlProbeDone(out bool ok, out uint32 pixel)
		{
			pixel = 0;
			let state = Host.th_gl_probe_result(&pixel);
			ok = state == 1 && (pixel >> 24) == 0xFF;
			return state != 0;
		}

		static void SessionLogText(String log)
		{
			FileStream fs = scope .();
			if (fs.Open(SessionLog.LogPath, .Read, .ReadWrite) case .Ok)
			{
				StreamReader rd = scope .(fs);
				rd.ReadToEnd(log).IgnoreError();
			}
		}

		bool SelfTestGlReset()
		{
			let io = FocusNative.igGetIO_Nil();
			if (mGlWait > 0)
			{
				mGlWait--;
				return false;
			}
			switch (mGlPhase)
			{
			case 0:
				SelfTestCheck(Host.th_gl_check() == 0, scope $"glreset: the drawing context is healthy at the start ({StringView(Host.th_gl_check_name(Host.th_gl_check()))})");
				Host.th_gl_probe_request();
				mGlPhase = 1;
				mGlWait = 2;
			case 1:
				if (!GlProbeDone(let ok, let px))
					return false;
				SelfTestCheck(ok, scope $"glreset: a rendered pixel reads back before the loss (0x{px:X8})");
				mGlPhase = 10;
			case 10, 20, 30:
				// lose the context (1 deleted, 2 reset reported, 3 deleted + three failed creations)
				mGlRebuilds0 = Host.th_gl_rebuilds();
				mGlRecreates0 = Host.th_gl_window_recreates();
				Host.th_gl_simulate((int32)(mGlPhase / 10));
				mGlPhase++;
				mGlWait = 3;
			case 11, 21, 31:
				let mode = mGlPhase / 10;
				let rebuilt = Host.th_gl_rebuilds() == mGlRebuilds0 + 1;
				let healthy = Host.th_gl_check() == 0 && Host.th_gl_failed() == 0;
				String what = scope .();
				what.Append(mode == 1 ? "the context deleted behind the editor" : mode == 2 ? "a driver reset reported" : "the context deleted and the next three creations failing");
				SelfTestCheck(rebuilt && healthy, scope $"glreset: {what}: found and rebuilt (rebuilds {Host.th_gl_rebuilds() - mGlRebuilds0}, check {StringView(Host.th_gl_check_name(Host.th_gl_check()))})");
				if (mode == 3)
					SelfTestCheck(Host.th_gl_window_recreates() == mGlRecreates0 + 1, "glreset: no context for the old window: a new window at the same place, then a retry");
				Host.th_gl_probe_request();
				mGlPhase++;
				mGlWait = 2;
			case 12, 22, 32:
				if (!GlProbeDone(let ok, let px))
					return false;
				SelfTestCheck(ok, scope $"glreset: after the rebuild a frame renders and reads back (0x{px:X8})");
				mGlPhase = (mGlPhase / 10 + 1) * 10;
				if (mGlPhase == 40)
				{
					String log = scope .();
					SessionLogText(log);
					SelfTestCheck(log.Contains("[gl] context lost after ") && log.Contains("(context not current): recreating") && log.Contains("[gl] restored: OpenGL"),
						"glreset: the session log has the loss and the restore");
				}
			case 40:
				// every creation fails: the rebuild gives up after three attempts, the editor keeps running
				mGlRebuilds0 = Host.th_gl_rebuilds();
				Host.th_gl_simulate(4);
				mGlFrame0 = mFrame;
				mGlT0 = Desktop.Now;
				mGlPhase = 41;
				mGlWait = 5;
			case 41:
				SelfTestCheck(Host.th_gl_failed() == 1 && Host.th_gl_check() == 7 && Host.th_gl_rebuilds() == mGlRebuilds0,
					scope $"glreset: three failed attempts: the rebuild gives up ({StringView(Host.th_gl_check_name(Host.th_gl_check()))}) after {(int)((Desktop.Now - mGlT0) * 1000)} ms");
				SelfTestCheck(mFrame > mGlFrame0 + 3, "glreset: without a drawing context the frame loop keeps running (autosave and recovery go on)");
				// Ctrl+Alt+R: the escape hatch
				mGlRequests0 = RestoreGraphicsRequests;
				FocusNative.ImGuiIO_AddKeyEvent(io, Key.ModCtrl, true);
				FocusNative.ImGuiIO_AddKeyEvent(io, Key.ModAlt, true);
				FocusNative.ImGuiIO_AddKeyEvent(io, Key.R, true);
				mGlPhase = 42;
				mGlWait = 2;
			case 42:
				FocusNative.ImGuiIO_AddKeyEvent(io, Key.R, false);
				FocusNative.ImGuiIO_AddKeyEvent(io, Key.ModAlt, false);
				FocusNative.ImGuiIO_AddKeyEvent(io, Key.ModCtrl, false);
				mGlPhase = 43;
				mGlWait = 3;
			case 43:
				SelfTestCheck(RestoreGraphicsRequests == mGlRequests0 + 1, "glreset: Ctrl+Alt+R runs Restore Graphics");
				SelfTestCheck(Host.th_gl_failed() == 0 && Host.th_gl_check() == 0 && Host.th_gl_rebuilds() == mGlRebuilds0 + 1,
					scope $"glreset: Restore Graphics after a failed rebuild brings the drawing context back ({StringView(Host.th_gl_check_name(Host.th_gl_check()))})");
				Host.th_gl_probe_request();
				mGlPhase = 44;
				mGlWait = 2;
			case 44:
				if (!GlProbeDone(let ok, let px))
					return false;
				SelfTestCheck(ok, scope $"glreset: and a frame renders again (0x{px:X8})");
				// Restore Graphics on a healthy context (the menu item): a rebuild, nothing lost
				mGlRebuilds0 = Host.th_gl_rebuilds();
				mGlFrame0 = mDocs.Count;
				RestoreGraphics("the glreset self test");
				mGlPhase = 45;
				mGlWait = 3;
			case 45:
				SelfTestCheck(Host.th_gl_rebuilds() == mGlRebuilds0 + 1 && Host.th_gl_check() == 0 && mDocs.Count == mGlFrame0,
					"glreset: Restore Graphics on a healthy context rebuilds it, the open documents stay");
				Host.th_gl_probe_request();
				mGlPhase = 46;
				mGlWait = 2;
			case 46:
				if (!GlProbeDone(let ok, let px))
					return false;
				SelfTestCheck(ok, scope $"glreset: a frame renders after the manual restore (0x{px:X8})");
				mGlPhase = 50;
				mGlT0 = Desktop.Now;
			case 50:
				// the presentation watch: frames drawn but never reaching the front buffer (a silently dead surface)
				if (Host.th_gl_present_armed() == 0)
				{
					if (Desktop.Now - mGlT0 < 4)
						return false;
#if BF_PLATFORM_WINDOWS
					SelfTestCheck(false, "glreset: the presentation watch turns on (the front buffer reads back)");
#else
					Notify.Log(.Info, "SelfTest", "glreset: the presentation watch stays off here (the front buffer does not read back): its cases are skipped");
#endif
					mGlPhase = 0;
					return true;
				}
				mGlRebuilds0 = Host.th_gl_rebuilds();
				mGlRecreates0 = Host.th_gl_window_recreates();
				Host.th_gl_simulate(5);
				mGlT0 = Desktop.Now;
				mGlPhase = 51;
			case 51:
				// three misses about a second apart, then one rebuild (the frames must keep coming meanwhile)
				if (Host.th_gl_rebuilds() == mGlRebuilds0 && Desktop.Now - mGlT0 < 30)
					return false;
				SelfTestCheck(Host.th_gl_rebuilds() == mGlRebuilds0 + 1 && Host.th_gl_window_recreates() == mGlRecreates0,
					scope $"glreset: 3 s of frames not presented: found ({(int)((Desktop.Now - mGlT0) * 1000)} ms) and a new context made");
				mGlPhase = 52;
				mGlFrame0 = (int)Host.th_gl_present_hits();
				mGlT0 = Desktop.Now;
			case 52:
				// presented again first (a hit resets the watch's rebuild count)
				if (Host.th_gl_present_hits() <= mGlFrame0 && Desktop.Now - mGlT0 < 20)
					return false;
				mGlRebuilds0 = Host.th_gl_rebuilds();
				mGlRecreates0 = Host.th_gl_window_recreates();
				Host.th_gl_simulate(6);
				mGlT0 = Desktop.Now;
				mGlPhase = 53;
			case 53:
				if (Host.th_gl_window_recreates() == mGlRecreates0 && Desktop.Now - mGlT0 < 90)
					return false;
				SelfTestCheck(Host.th_gl_rebuilds() == mGlRebuilds0 + 3 && Host.th_gl_window_recreates() == mGlRecreates0 + 1,
					scope $"glreset: when two new contexts do not bring presentation back, the third rebuild opens a new window (rebuilds {Host.th_gl_rebuilds() - mGlRebuilds0}, new windows {Host.th_gl_window_recreates() - mGlRecreates0})");
				Host.th_gl_probe_request();
				mGlT0 = Desktop.Now;
				mGlPhase = 54;
				mGlWait = 2;
			case 54:
				if (!GlProbeDone(let ok, let px))
					return false;
				let hits = Host.th_gl_present_hits();
				SelfTestCheck(ok, scope $"glreset: and frames render in the new window (0x{px:X8})");
				mGlFrame0 = (int)hits;
				mGlPhase = 55;
			case 55:
				// presented again: the watch sees its marker
				if (Host.th_gl_present_hits() <= mGlFrame0 && Desktop.Now - mGlT0 < 20)
					return false;
				SelfTestCheck(Host.th_gl_present_hits() > mGlFrame0, "glreset: the presentation watch sees frames presented again");
				mGlPhase = 0;
				return true;
			}
			return false;
		}

		// ---------------------------------------------------------------- soak

		int mSoakPhase;
		double mSoakStart;
		double mSoakNext;
		double mSoakMinutes;
		double mSoakUnfocusAt;
		double mSoakWarm;
		bool mSoakFocused;
		bool mSoakHaveBase;
		SoakStats mSoakBase;
		SoakStats mSoakMax;
		int mSoakWait;

		static void SoakLine(String s, double t, SoakStats st)
		{
			s.AppendF("[soak] t={}s private={:0.0}MB gpu-process={:0.0}MB gpu-available={}MB tex={} buf={} vao={} prog={} shader={} highest-name={} imgui-tex={} atlas={}x{} baked={} frames={} docimages={}",
				(int)t, st.PrivateBytes / 1048576.0, st.GpuProcessBytes < 0 ? -1.0 : st.GpuProcessBytes / 1048576.0, st.GpuAvailableKb < 0 ? -1 : st.GpuAvailableKb / 1024,
				st.LiveTextures, st.LiveBuffers, st.LiveVertexArrays, st.LivePrograms, st.LiveShaders, st.HighestName, st.ImGuiTextures,
				st.AtlasWidth, st.AtlasHeight, st.BakedFonts, st.Frames, DocImages.CachedCount);
		}

		static void SoakMax(ref SoakStats m, SoakStats s)
		{
			m.PrivateBytes = Math.Max(m.PrivateBytes, s.PrivateBytes);
			m.GpuProcessBytes = Math.Max(m.GpuProcessBytes, s.GpuProcessBytes);
			m.LiveTextures = Math.Max(m.LiveTextures, s.LiveTextures);
			m.LiveBuffers = Math.Max(m.LiveBuffers, s.LiveBuffers);
			m.LiveVertexArrays = Math.Max(m.LiveVertexArrays, s.LiveVertexArrays);
			m.LivePrograms = Math.Max(m.LivePrograms, s.LivePrograms);
			m.LiveShaders = Math.Max(m.LiveShaders, s.LiveShaders);
			m.ImGuiTextures = Math.Max(m.ImGuiTextures, s.ImGuiTextures);
			m.AtlasWidth = Math.Max(m.AtlasWidth, s.AtlasWidth);
			m.AtlasHeight = Math.Max(m.AtlasHeight, s.AtlasHeight);
			m.BakedFonts = Math.Max(m.BakedFonts, s.BakedFonts);
			m.HighestName = Math.Max(m.HighestName, s.HighestName);
		}

		/// Growth of `now` over `base` in percent (counts get one object of slack: 1 -> 2 is not 100 %).
		static double Growth(int64 baseV, int64 nowV, int64 slack)
		{
			if (baseV < 0 || nowV < 0)
				return 0;
			if (nowV <= baseV + slack)
				return 0;
			return (nowV - baseV) * 100.0 / Math.Max(baseV, 1);
		}

		bool SelfTestSoak()
		{
			let io = FocusNative.igGetIO_Nil();
			let now = Desktop.Now;
			switch (mSoakPhase)
			{
			case 0:
				String v = scope .();
				mSoakMinutes = 45;
				if (Environment.GetEnvironmentVariable("TREADLE_SOAK_MINUTES", v) case .Ok && (double.Parse(v) case .Ok(let m)) && m > 0)
					mSoakMinutes = m;
				v.Clear();
				mSoakFocused = Environment.GetEnvironmentVariable("TREADLE_SOAK_FOCUSED", v) case .Ok && v == "1";
				mSoakStart = now;
				mSoakNext = now;
				// unfocused for the last 40 minutes (or the whole run when shorter); the baseline after a warm-up
				mSoakUnfocusAt = Math.Max(0, mSoakMinutes - 40) * 60;
				mSoakWarm = Math.Min(Math.Max(mSoakUnfocusAt, 120), mSoakMinutes * 60 * 0.25);
				mSoakHaveBase = false;
				if (mSoakFocused)
					Notify.Log(.Info, "SelfTest", scope $"[soak] {mSoakMinutes} min, focused throughout, baseline at {(int)mSoakWarm} s");
				else
					Notify.Log(.Info, "SelfTest", scope $"[soak] {mSoakMinutes} min, the focus is lost at {(int)mSoakUnfocusAt} s, baseline at {(int)mSoakWarm} s");
				mSoakPhase = 1;
			case 1:
				let t = now - mSoakStart;
				if (!mSoakFocused && mSoakPhase == 1 && t >= mSoakUnfocusAt && mSoakWait == 0)
				{
					// the platform layer reports the focus gone, the pointer leaves
					FocusNative.ImGuiIO_AddMousePosEvent(io, -float.MaxValue, -float.MaxValue);
					Host.th_push_window_event(13); // SDL_WINDOWEVENT_FOCUS_LOST
					Notify.Log(.Info, "SelfTest", scope $"[soak] t={(int)t}s focus lost");
					mSoakWait = 1;
				}
				if (now >= mSoakNext)
				{
					mSoakNext += 30;
					SoakStats st = .();
					Host.th_soak_stats(&st);
					String line = scope .();
					SoakLine(line, t, st);
					Notify.Log(.Info, "SelfTest", line);
					if (!mSoakHaveBase && t >= mSoakWarm)
					{
						mSoakHaveBase = true;
						mSoakBase = st;
						mSoakMax = st;
					}
					else if (mSoakHaveBase)
						SoakMax(ref mSoakMax, st);
				}
				if (t < mSoakMinutes * 60)
					return false;
				// the end: growth over the baseline
				String r = scope .();
				let b = mSoakBase;
				let m = mSoakMax;
				r.AppendF("private {:0.0}% ({:0.0} -> {:0.0} MB), gpu-process {:0.0}%, tex {:0.0}%, buf {:0.0}%, vao {:0.0}%, prog {:0.0}%, shader {:0.0}%, imgui-tex {:0.0}%, atlas {}x{} -> {}x{}, baked {} -> {}, highest name {} -> {}",
					Growth(b.PrivateBytes, m.PrivateBytes, 0), b.PrivateBytes / 1048576.0, m.PrivateBytes / 1048576.0,
					Growth(b.GpuProcessBytes, m.GpuProcessBytes, 0),
					Growth(b.LiveTextures, m.LiveTextures, 1), Growth(b.LiveBuffers, m.LiveBuffers, 1), Growth(b.LiveVertexArrays, m.LiveVertexArrays, 1),
					Growth(b.LivePrograms, m.LivePrograms, 1), Growth(b.LiveShaders, m.LiveShaders, 1), Growth(b.ImGuiTextures, m.ImGuiTextures, 1),
					b.AtlasWidth, b.AtlasHeight, m.AtlasWidth, m.AtlasHeight, b.BakedFonts, m.BakedFonts, b.HighestName, m.HighestName);
				Notify.Log(.Info, "SelfTest", scope $"[soak] growth after the warm-up (largest sample against the baseline): {r}");
				SelfTestCheck(mSoakHaveBase && Growth(b.PrivateBytes, m.PrivateBytes, 0) < 5, scope $"soak: process memory flat after the warm-up over {mSoakMinutes} min ({r})");
				SelfTestCheck(Growth(b.LiveTextures, m.LiveTextures, 1) < 5 && Growth(b.LiveBuffers, m.LiveBuffers, 1) < 5 && Growth(b.LiveVertexArrays, m.LiveVertexArrays, 1) < 5 &&
					Growth(b.LivePrograms, m.LivePrograms, 1) < 5 && Growth(b.LiveShaders, m.LiveShaders, 1) < 5 && Growth(b.ImGuiTextures, m.ImGuiTextures, 1) < 5 &&
					m.AtlasWidth == b.AtlasWidth && m.AtlasHeight == b.AtlasHeight, "soak: GL objects, ImGui textures and the font atlas flat");
				SelfTestCheck(Growth(b.GpuProcessBytes, m.GpuProcessBytes, 1048576) < 5, scope $"soak: GPU memory of the process flat ({b.GpuProcessBytes / 1048576.0:0.0} -> {m.GpuProcessBytes / 1048576.0:0.0} MB)");
				// the focus comes back, then a click on the File menu
				if (!mSoakFocused)
					Host.th_push_window_event(12); // SDL_WINDOWEVENT_FOCUS_GAINED
				Host.th_gl_probe_request();
				mSoakPhase = 2;
				mSoakWait = 3;
			case 2:
				if (--mSoakWait > 0)
					return false;
				FoMouse(true, 1);
				mSoakPhase = 3;
				mSoakWait = 2;
			case 3:
				if (--mSoakWait > 0)
					return false;
				FoMouse(true, 0);
				mSoakPhase = 4;
				mSoakWait = 40;
			case 4:
				bool open = Gui.igIsPopupOpen_Str("", PopupFlags.AnyPopup);
				if (!open && --mSoakWait > 0)
					return false;
				GlProbeDone(let ok, let px);
				SelfTestCheck(open, "soak: at the end the focus comes back and a click on the File menu opens it");
				SelfTestCheck(ok, scope $"soak: and the editor still renders (0x{px:X8})");
				FocusNative.ImGuiIO_AddKeyEvent(io, Key.Escape, true);
				mSoakPhase = 5;
				mSoakWait = 2;
			case 5:
				if (--mSoakWait > 0)
					return false;
				FocusNative.ImGuiIO_AddKeyEvent(io, Key.Escape, false);
				mSoakPhase = 0;
				mSoakWait = 0;
				return true;
			}
			return false;
		}
	}
}
#endif
