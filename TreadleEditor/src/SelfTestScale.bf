// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using System.IO;
using ImGui;
using Treadle.Document;
using Treadle.Graph;

namespace Treadle.Editor
{
	/// The editor at scale (docs/Editor-Model.md, "Scale"):
	///
	///  - `scale`: writes a reduced synthetic project (ScaleProject.Reduced: 20 types, 200 Sheets, a big
	///    Sheet of 300 nodes) under %TEMP%, opens it, opens the big Sheet and measures; checks generous
	///    bounds (open <= 5 s, a frame on the big Sheet <= 50 ms at 1:1 and zoomed out, the incremental
	///    Validate, the Node menu search, no leak over a short edit loop); deletes the project.
	///  - `scalegen`: writes a project of `TREADLE_SCALE_SIZE` (`full`, the default, or `reduced`) into
	///    `TREADLE_SCALE_OUT` and logs its totals (the measured project is made this way).
	///  - `scalemeasure`: the same measurements on the project in `TREADLE_SCALE_DIR`, each three times
	///    (medians), plus Build and a longer edit loop (`TREADLE_SCALE_SOAK` steps, default 6000); writes
	///    `[SCALE]` lines and leaves the project as it was (edits are undone or not saved, Save All
	///    rewrites the same text).
	///
	/// Frame times are the CPU time of the editor's frame (Frame() up to the self-test tick: every panel
	/// built and drawn into ImGui's lists), not the GPU's or the display's (vsync).
	extension EditorApp
	{
		class ScaleMetric
		{
			public String Name = new .() ~ delete _;
			public String Unit = new .() ~ delete _;
			public List<double> Runs = new .() ~ delete _;

			public double Median
			{
				get
				{
					if (Runs.IsEmpty)
						return 0;
					List<double> s = scope .();
					s.AddRange(Runs);
					s.Sort();
					return s[(s.Count - 1) / 2];
				}
			}
		}

		int mScPhase;
		int mScRep;
		int mScCount;
		double mScT0;
		double mScAcc;
		bool mScFull;
		bool mScTemp;
		int mScSoak;
		String mScRoot = new .() ~ delete _;
		String mScBig = new .() ~ delete _;
		String mScHuge = new .() ~ delete _;
		List<ScaleMetric> mScMetrics = new .() ~ DeleteContainerAndItems!(_);
		List<double> mScFrames = new .() ~ delete _;
		double[GraphProf.Count] mScProf;
		int mScProfFrames;
		ImVec2 mScFrom;
		ImVec2 mScTo;
		int32 mScNode;
		float mScNodeX;
		int64 mScMemOpen;
		int64 mScMemWarm;
		int64 mScMemEnd;
		int32 mScAdded;
		bool mScMinimap;
		/// When the current frame began (set by TrackFrameTime).
		public double FrameBeganAt;

		double ScNow => Desktop.Now;
		double ScFrameMs => (Desktop.Now - FrameBeganAt) * 1000.0;

		ScaleMetric ScMetric(StringView name, StringView unit = "ms")
		{
			for (let m in mScMetrics)
				if (m.Name == name)
					return m;
			ScaleMetric m = new .();
			m.Name.Set(name);
			m.Unit.Set(unit);
			mScMetrics.Add(m);
			return m;
		}

		void ScAdd(StringView name, double v, StringView unit = "ms")
		{
			ScMetric(name, unit).Runs.Add(v);
			Notify.Log(.Info, "SelfTest", scope $"[SCALE] {name}: {v:0.00} {unit}");
		}

		/// The process's private bytes (Windows; 0 elsewhere).
		static int64 ScPrivateBytes()
		{
#if BF_PLATFORM_WINDOWS
			ProcessMemoryCountersEx c = default;
			c.cb = sizeof(ProcessMemoryCountersEx);
			if (K32GetProcessMemoryInfo(GetCurrentProcess(), &c, (uint32)sizeof(ProcessMemoryCountersEx)) != 0)
				return (int64)c.PrivateUsage;
#endif
			return 0;
		}

#if BF_PLATFORM_WINDOWS
		[CRepr]
		struct ProcessMemoryCountersEx
		{
			public uint32 cb;
			public uint32 PageFaultCount;
			public uint PeakWorkingSetSize;
			public uint WorkingSetSize;
			public uint QuotaPeakPagedPoolUsage;
			public uint QuotaPagedPoolUsage;
			public uint QuotaPeakNonPagedPoolUsage;
			public uint QuotaNonPagedPoolUsage;
			public uint PagefileUsage;
			public uint PeakPagefileUsage;
			public uint PrivateUsage;
		}
		[CLink, CallingConvention(.Stdcall)] static extern int32 K32GetProcessMemoryInfo(void* process, ProcessMemoryCountersEx* counters, uint32 cb);
		[CLink, CallingConvention(.Stdcall)] static extern void* GetCurrentProcess();
#endif

		/// Frames are sampled into mScFrames; true when `n` were taken (the first frame after a change
		/// is not counted).
		bool ScSampleFrames(int n)
		{
			if (mScCount++ == 0)
			{
				mScFrames.Clear();
				GraphProf.Reset();
				for (int i < GraphProf.Count)
					mScProf[i] = 0;
				mScProfFrames = 0;
				GraphProf.Enabled = true;
				return false;
			}
			mScFrames.Add(ScFrameMs);
			for (int i < GraphProf.Count)
				mScProf[i] += GraphProf.Frame[i];
			mScProfFrames++;
			GraphProf.Reset();
			if (mScFrames.Count < n)
				return false;
			GraphProf.Enabled = false;
			mScCount = 0;
			return true;
		}

		double ScFramesMedian()
		{
			List<double> s = scope .();
			s.AddRange(mScFrames);
			s.Sort();
			if (!s.IsEmpty)
				Notify.Log(.Info, "SelfTest", scope $"[SCALE]   frames: {s.Count}, p95 {s[Math.Max(0, (int)(s.Count * 0.95f) - 1)]:0.00} ms, worst {s.Back:0.00} ms");
			return s.IsEmpty ? 0 : s[(s.Count - 1) / 2];
		}

		void ScLogProf(StringView what)
		{
			String line = scope $"[SCALE] {what} sections (mean us):";
			for (int i < GraphProf.Count)
				line.AppendF(" {}={:0}", GraphProf.Name(i), mScProf[i] / Math.Max(1, mScProfFrames));
			Notify.Log(.Info, "SelfTest", line);
		}

		/// `scalegen`: writes the project and logs its totals.
		bool SelfTestScaleGen()
		{
			String outDir = scope .();
			if (Environment.GetEnvironmentVariable("TREADLE_SCALE_OUT", outDir) case .Err || outDir.IsEmpty)
			{
				SelfTestCheck(false, "scalegen: set TREADLE_SCALE_OUT to the folder to write");
				return true;
			}
			String size = scope .();
			Environment.GetEnvironmentVariable("TREADLE_SCALE_SIZE", size).IgnoreError();
			ScaleProject gen = scope .();
			let t0 = ScNow;
			gen.Write(outDir, (size == "reduced") ? ScaleProject.Reduced : ScaleProject.Full);
			Notify.Log(.Info, "SelfTest", scope $"[SCALE] generated {outDir}: {gen.TypesWritten} types, {gen.SheetsWritten} Sheets, {gen.NodesWritten} nodes, {gen.WiresWritten} wires; Huge.treadle {gen.HugeFileBytes} bytes ({(ScNow - t0) * 1000:0} ms)");
			SelfTestCheck(gen.TypesWritten > 0, "scalegen: the project was written");
			return true;
		}

		/// The big Sheet's graph (null when it is not the Sheet in front).
		Graph ScBigGraph => (CurrentMethod != null && CurrentMethod.Doc != null && ProjectIndex.SamePath(CurrentMethod.Doc.FilePath, mScBig)) ? CurrentMethod.Graph : null;

		void ScCloseBig()
		{
			for (int i = mDocs.Count - 1; i >= 0; i--)
				if (ProjectIndex.SamePath(mDocs[i].FilePath, mScBig) || ProjectIndex.SamePath(mDocs[i].FilePath, mScHuge))
				{
					mDocs[i].Modified = false;
					CloseDoc(mDocs[i]);
				}
		}

		/// A literal of a value input changed: an edit of the Sheet's code (not only of its layout).
		bool ScEditLiteral(Graph g, int salt)
		{
			for (let n in g.Nodes)
				for (let p in n.Inputs)
					if (p.Kind == .Value && !p.Default.IsEmpty)
					{
						p.Default.Set(scope $"{(salt % 9) + 1}");
						return true;
					}
			return false;
		}

		void ScMouse(ImVec2 at, int down)
		{
			mGraphPanel.SelfTestMouse = at;
			let io = DragNative.igGetIO_Nil();
			DragNative.ImGuiIO_AddMousePosEvent(io, at.x, at.y);
			if (down >= 0)
				DragNative.ImGuiIO_AddMouseButtonEvent(io, 0, down == 1);
		}

		void ScMouseRelease()
		{
			mGraphPanel.SelfTestMouse = .(-3e38f, -3e38f);
			GraphProf.ForceHover = false;
		}

		/// `scale` (full = false) and `scalemeasure` (full = true). One phase step per frame.
		bool SelfTestScale(bool full)
		{
			let reps = full ? 3 : 1;
			switch (mScPhase)
			{
			case 0:
				mScFull = full;
				mScMinimap = Prefs.ShowMinimap;
				ClearAndDeleteItems!(mScMetrics);
				if (full)
				{
					if (Environment.GetEnvironmentVariable("TREADLE_SCALE_DIR", mScRoot) case .Err || !Directory.Exists(mScRoot))
					{
						SelfTestCheck(false, "scalemeasure: set TREADLE_SCALE_DIR to a project made by scalegen");
						return true;
					}
					String soak = scope .();
					mScSoak = 6000;
					if (Environment.GetEnvironmentVariable("TREADLE_SCALE_SOAK", soak) case .Ok && int.Parse(soak) case .Ok(let s))
						mScSoak = s;
					mScTemp = false;
				}
				else
				{
					String temp = scope .();
					if (!SelfTestTemp.Get(temp))
						temp.Set(".");
					mScRoot.Set(scope $"{temp}/treadle-scale-{(int)Platform.BfpSystem_GetTimeStamp() & 0xFFFFFF}");
					ScaleProject gen = scope .();
					let t0 = ScNow;
					gen.Write(mScRoot, ScaleProject.Reduced);
					Notify.Log(.Info, "SelfTest", scope $"[SCALE] generated {gen.TypesWritten} types, {gen.SheetsWritten} Sheets, {gen.NodesWritten} nodes, {gen.WiresWritten} wires ({(ScNow - t0) * 1000:0} ms)");
					SelfTestCheck(gen.TypesWritten == ScaleProject.Reduced.Types && gen.SheetsWritten >= ScaleProject.Reduced.Sheets - 5, scope $"scale: the reduced project was written ({gen.TypesWritten} types, {gen.SheetsWritten} Sheets, {gen.NodesWritten} nodes)");
					mScSoak = 800; // past the warm-up (400 steps): the undo history is full by then
					mScTemp = true;
				}
				mScBig.Set(scope $"{mScRoot}/Huge/BigSheet.treadle");
				mScHuge.Set(scope $"{mScRoot}/Huge/Huge.treadle");
				for (let d in mDocs)
					d.Modified = false;
				mScRep = 0;
				mScCount = 0;
				mScPhase = 10;
				ScAdd("memory before open", ScPrivateBytes() / 1048576.0, "MB");
				return false;

			// ---- Open the project: the scan, the Project Browser and the first frames.
			case 10:
				OpenProjectNow("", "", false);
				mScPhase = 11;
				mSelfTestWait = 3;
				return false;
			case 11:
				mScT0 = ScNow;
				OpenProjectNow(mScRoot, "", false);
				mScAcc = (ScNow - mScT0) * 1000.0;
				mScCount = 0;
				mScPhase = 12;
				return false;
			case 12:
				// This frame (the Project Browser's first) and the next count with the open.
				mScAcc += ScFrameMs;
				if (++mScCount < 2)
					return false;
				mScCount = 0;
				ScAdd((mScRep == 0) ? "open project" : "open project again", mScAcc);
				mScPhase = (++mScRep < reps) ? 10 : 20;
				if (mScPhase == 20)
					mScRep = 0;
				return false;

			// ---- Open the big Sheet: the file, the tab and its first frames.
			case 20:
				ScCloseBig();
				mScPhase = 21;
				mSelfTestWait = 2;
				return false;
			case 21:
				mScT0 = ScNow;
				if (!OpenSheet(mScBig, "Big"))
				{
					SelfTestCheck(false, "scale: the big Sheet opens");
					mScPhase = 900;
					return false;
				}
				mScAcc = (ScNow - mScT0) * 1000.0;
				mScCount = 0;
				mScPhase = 22;
				return false;
			case 22:
				mScAcc += ScFrameMs;
				if (++mScCount < 2)
					return false;
				mScCount = 0;
				ScAdd((mScRep == 0) ? "open big Sheet" : "open big Sheet again", mScAcc);
				if (FrontEnd != null)
					ScAdd((mScRep == 0) ? "front end on first view" : "front end on view again", FrontEnd.LastMs);
				mScPhase = (++mScRep < reps) ? 20 : 30;
				if (mScPhase == 30)
				{
					mScRep = 0;
					ScAdd("memory after open", ScPrivateBytes() / 1048576.0, "MB");
					mScMemOpen = ScPrivateBytes();
				}
				return false;

			// ---- Frames at 1:1 (the middle of the Sheet), zoomed out (all of it), the minimap.
			case 30:
				let g = ScBigGraph;
				if (g == null || CurrentTab == null)
				{
					SelfTestCheck(false, "scale: the big Sheet is in front");
					mScPhase = 900;
					return false;
				}
				SelfTestCheck(g.Nodes.Count >= (full ? 500 : 250), scope $"scale: the big Sheet has its nodes ({g.Nodes.Count} nodes, {g.Links.Count} wires)");
				float sx = 0;
				float sy = 0;
				for (let n in g.Nodes)
				{
					sx += n.X;
					sy += n.Y;
				}
				CurrentTab.ZoomLevel = Canvas.DefaultZoomLevel;
				CurrentTab.CenterOn(sx / g.Nodes.Count, sy / g.Nodes.Count);
				Prefs.ShowMinimap = false;
				mScCount = 0;
				mScPhase = 31;
				mSelfTestWait = 5;
				return false;
			case 31:
				if (!ScSampleFrames(60))
					return false;
				ScAdd("frame 1:1", ScFramesMedian());
				ScLogProf("frame 1:1");
				Prefs.ShowMinimap = true;
				mScPhase = 32;
				mSelfTestWait = 3;
				return false;
			case 32:
				if (!ScSampleFrames(60))
					return false;
				ScAdd("frame 1:1 with minimap", ScFramesMedian());
				ScLogProf("frame 1:1 with minimap");
				Prefs.ShowMinimap = false;
				mGraphPanel.FrameNodes(CurrentTab, ScBigGraph, false);
				mScPhase = 33;
				mSelfTestWait = 20;
				return false;
			case 33:
				if (!ScSampleFrames(60))
					return false;
				ScAdd("frame zoomed out", ScFramesMedian());
				ScLogProf("frame zoomed out");
				Notify.Log(.Info, "SelfTest", scope $"[SCALE] zoomed out at {CurrentTab.Zoom:0.000}");
				mScPhase = (++mScRep < reps) ? 30 : 40;
				if (mScPhase == 40)
					mScRep = 0;
				return false;

			// ---- Marquee about 300 nodes (zoomed out), drag them, undo the drag.
			case 40:
				let g = ScBigGraph;
				CurrentTab.ClearSelection();
				List<float> ys = scope .();
				float minX = float.MaxValue;
				float minY = float.MaxValue;
				float maxX = float.MinValue;
				for (let n in g.Nodes)
				{
					ys.Add(n.Y);
					minX = Math.Min(minX, n.X);
					minY = Math.Min(minY, n.Y);
					maxX = Math.Max(maxX, n.X);
				}
				ys.Sort();
				let want = Math.Min(full ? 300 : 150, ys.Count - 1);
				let limitY = ys[want] - 1;
				mScFrom = CurrentTab.GridToScreen(minX - 40, minY - 40);
				mScTo = CurrentTab.GridToScreen(maxX + 200, limitY);
				GraphProf.ForceHover = true;
				ScMouse(mScFrom, 1);
				mScCount = 0;
				mScPhase = 41;
				return false;
			case 41:
				if (mScCount == 0 && CurrentTab.Mode != .Marquee)
				{
					// The press did not reach the canvas (the pointer is elsewhere): start it as a press would.
					CurrentTab.Mode = .Marquee;
					CurrentTab.ModeButton = 0;
					CurrentTab.PressPos = mScFrom;
					CurrentTab.MarqueeBase.Clear();
				}
				let step = Math.Min(mScCount + 1, 30) / 30.0f;
				ScMouse(mScFrom + (mScTo - mScFrom) * step, -1);
				if (!ScSampleFrames(30))
					return false;
				ScAdd("marquee frame", ScFramesMedian());
				ScMouse(mScTo, 0);
				mScPhase = 42;
				mSelfTestWait = 2;
				return false;
			case 42:
				let sel = CurrentTab.SelectedNodes.Count;
				Notify.Log(.Info, "SelfTest", scope $"[SCALE] marquee selected {sel} nodes");
				SelfTestCheck(sel >= (full ? 200 : 100), scope $"scale: the marquee selected the nodes ({sel})");
				// Press on a selected node's title and drag.
				let g = ScBigGraph;
				Node pick = null;
				for (let id in CurrentTab.SelectedNodes)
				{
					let n = g.FindNode(id);
					if (n != null && (pick == null || n.Y > pick.Y))
						pick = n;
				}
				if (pick == null)
				{
					mScPhase = 50;
					return false;
				}
				mScNode = pick.Id;
				mScNodeX = pick.X;
				// At 1:1 on that node (the selection stays), so the press lands on its title bar and not on a pin.
				ScMouseRelease();
				CurrentTab.ZoomLevel = Canvas.DefaultZoomLevel;
				CurrentTab.CenterOn(pick.X, pick.Y);
				mScPhase = 48;
				mSelfTestWait = 4;
				return false;
			case 48:
				let pick = ScBigGraph?.FindNode(mScNode);
				if (pick == null)
				{
					mScPhase = 50;
					return false;
				}
				mScFrom = CurrentTab.GridToScreen(pick.X + 60, pick.Y + 6);
				mScTo = mScFrom + ImVec2(160, 90);
				GraphProf.ForceHover = true;
				ScMouse(mScFrom, 1);
				mScCount = 0;
				mScPhase = 43;
				return false;
			case 43:
				if (mScCount == 1 && CurrentTab.Mode != .MoveNodes)
					Notify.Log(.Info, "SelfTest", scope $"[SCALE] drag: the press did not start a move (mode {CurrentTab.Mode})");
				let step = Math.Min(mScCount + 1, 30) / 30.0f;
				ScMouse(mScFrom + (mScTo - mScFrom) * step, -1);
				if (!ScSampleFrames(30))
					return false;
				ScAdd("drag frame", ScFramesMedian());
				ScMouse(mScTo, 0);
				mScPhase = 44;
				mSelfTestWait = 2;
				return false;
			case 44:
				ScMouseRelease();
				CurrentTab.CancelInteraction();
				mNodeMenu.CloseRequested = true;
				let n = ScBigGraph?.FindNode(mScNode);
				let moved = n != null && n.X != mScNodeX;
				Notify.Log(.Info, "SelfTest", scope $"[SCALE] drag moved the nodes: {moved} ({CurrentTab.SelectedNodes.Count} selected)");
				// Undo (the drag, or a code edit when the drag did not happen) and redo, timed.
				if (!moved)
				{
					BeginEdit();
					ScEditLiteral(ScBigGraph, 3);
					EditDoc.Commit(CurrentMethod);
				}
				mScPhase = 45;
				return false;
			case 45:
				mScT0 = ScNow;
				EditDoc.Undo();
				mScAcc = (ScNow - mScT0) * 1000.0;
				mNodeMenu.Catalog.LastBuildMs = 0;
				mScPhase = 46;
				GraphProf.Reset();
				GraphProf.Enabled = true;
				return false;
			case 46:
				ScAdd("undo", mScAcc + ScFrameMs);
				ScAdd("undo (the call)", mScAcc);
				GraphProf.Enabled = false;
				for (int i < GraphProf.Count)
					mScProf[i] = GraphProf.Frame[i];
				mScProfFrames = 1;
				ScLogProf("frame after undo");
				if (FrontEnd != null)
					Notify.Log(.Info, "SelfTest", scope $"[SCALE] after undo: front end {FrontEnd.LastMs:0.0} ms, incremental {FrontEnd.LastWasIncremental}, {FrontEnd.LastSheets} Sheet(s), {FrontEnd.LastTypes} type(s), catalogue build {mNodeMenu.Catalog.LastBuildMs:0.0} ms");
				EditDoc.Redo();
				mScPhase = (++mScRep < reps) ? 45 : 47;
				if (mScPhase == 47)
					mScRep = 0;
				return false;
			case 47:
				EditDoc.Undo();
				CurrentTab.ClearSelection();
				mScPhase = 50;
				mSelfTestWait = 2;
				return false;

			// ---- The Node menu: open, then a three-letter search over the whole catalogue.
			case 50:
				mScT0 = ScNow;
				RefreshProjectTypes();
				ScAdd("project types refresh (nothing changed)", (ScNow - mScT0) * 1000.0);
				mNodeMenu.SelfTestPos = .(380 * Look.Scale, 160 * Look.Scale);
				mNodeMenu.Catalog.LastBuildMs = 0; // stays 0 when the open does not rebuild it
				mScT0 = ScNow;
				OpenNodeMenu(CurrentTab, CurrentTab.ScreenToGrid(CurrentTab.CanvasOrigin + CurrentTab.CanvasSize * 0.5f), 0);
				mScAcc = (ScNow - mScT0) * 1000.0;
				mScPhase = 51;
				return false;
			case 51:
				ScAdd("node menu open", mScAcc + ScFrameMs);
				ScAdd("node menu open (the call)", mScAcc);
				ScAdd("node menu: catalogue build", mNodeMenu.Catalog.LastBuildMs);
				mScPhase = 52;
				mSelfTestWait = 2;
				return false;
			case 52:
				mNodeMenu.SelfTestSetSearch((mScRep % 2 == 0) ? "cou" : "add");
				mScPhase = 53;
				return false;
			case 53:
				// The frame that filtered the catalogue (the search changed at the end of the last one).
				ScAdd("node menu search", ScFrameMs);
				mNodeMenu.CloseRequested = true;
				mScPhase = (++mScRep < reps) ? 50 : 60;
				if (mScPhase == 60)
					mScRep = 0;
				mSelfTestWait = 3;
				return false;

			// ---- Validate: the graph checks and the front end, incremental after a one-Sheet edit, and full.
			case 60:
				let g = ScBigGraph;
				if (g == null || FrontEnd == null)
				{
					mScPhase = 70;
					return false;
				}
				let mg = CurrentMethod;
				FrontEnd.Incremental = true;
				let warm = FrontEnd.Current; // up to date first
				BeginEdit();
				ScEditLiteral(g, mScRep + 5);
				mScT0 = ScNow;
				mg.Doc.Commit(mg);
				let commitMs = (ScNow - mScT0) * 1000.0;
				mScT0 = ScNow;
				let c = FrontEnd.Current;
				let feMs = (ScNow - mScT0) * 1000.0;
				ScAdd("validate incremental (graph checks)", commitMs);
				ScAdd("validate incremental (front end)", feMs);
				Notify.Log(.Info, "SelfTest", scope $"[SCALE] incremental: {FrontEnd.LastWasIncremental}, {FrontEnd.LastSheets} Sheet(s) bound, front end {FrontEnd.LastMs:0.00} ms");
				SelfTestCheck(warm != null && c != null && FrontEnd.LastWasIncremental, "scale: a one-Sheet edit validates incrementally");
				mScT0 = ScNow;
				FrontEnd.Incremental = false;
				ScEditLiteral(g, mScRep + 6);
				mg.Doc.Commit(mg);
				let c2 = FrontEnd.Current;
				FrontEnd.Incremental = true;
				ScAdd("validate full (front end)", (ScNow - mScT0) * 1000.0);
				SelfTestCheck(c2 != null, "scale: the full compile ran");
				mScT0 = ScNow;
				Validate(true);
				ScAdd("Validate command (open Sheets)", (ScNow - mScT0) * 1000.0);
				EditDoc.Undo();
				mScPhase = (++mScRep < reps) ? 60 : 64;
				if (mScPhase == 64)
					mScRep = 0;
				mSelfTestWait = 2;
				return false;
			case 64:
				// A one-Sheet edit with every node selected, as the editor does it: the next frame validates and draws.
				let g = ScBigGraph;
				if (g == null)
				{
					mScPhase = 70;
					return false;
				}
				CurrentTab.ClearSelection();
				for (let n in g.Nodes)
					CurrentTab.SelectedNodes.Add(n.Id);
				BeginEdit();
				ScEditLiteral(g, mScRep + 4);
				CommitCurrent();
				mScPhase = 65;
				return false;
			case 65:
				ScAdd("frame after a one-Sheet edit (all selected)", ScFrameMs);
				EditDoc.Undo();
				CurrentTab.ClearSelection();
				mScPhase = (++mScRep < reps) ? 64 : 70;
				if (mScPhase == 70)
					mScRep = 0;
				mSelfTestWait = 3;
				return false;

			// ---- The 2 MB type file: open it, the Outline of its members, Find in Sheets.
			case 70:
				mScT0 = ScNow;
				let doc = OpenFile(mScHuge, true);
				mScAcc = (ScNow - mScT0) * 1000.0;
				SelfTestCheck(doc != null, "scale: the large type file opens");
				mScPhase = 71;
				return false;
			case 71:
				ScAdd("open 2 MB type file", mScAcc + ScFrameMs);
				mScCount = 0;
				mScPhase = 72;
				mSelfTestWait = 3;
				return false;
			case 72:
				if (!ScSampleFrames(30))
					return false;
				ScAdd("frame with the large type's Outline", ScFramesMedian());
				mScT0 = ScNow;
				RunFind("H12");
				ScAdd("find in Sheets (open types)", (ScNow - mScT0) * 1000.0);
				Notify.Log(.Info, "SelfTest", scope $"[SCALE] find: {mFindHits.Count} hit(s) in {mFindFiles} file(s)");
				ScCloseBig();
				mScPhase = (++mScRep < reps) ? 70 : 80;
				if (mScPhase == 80)
					mScRep = 0;
				mSelfTestWait = 3;
				return false;

			// ---- Build (scalemeasure): lower the whole project and compile it.
			case 80:
				if (!full)
				{
					mScPhase = 90;
					return false;
				}
				FrontEndProgramSource.LastLowerMs = 0;
				mScT0 = ScNow;
				Build(default, true); // Force Build: every unit compiled again
				mScPhase = 81;
				return false;
			case 81:
				if (mBuild != null && mBuild.Running)
					return false;
				ScAdd("build (Debug, whole project)", (ScNow - mScT0) * 1000.0);
				ScAdd("build: front end lower", FrontEndProgramSource.LastLowerMs);
				Notify.Log(.Info, "SelfTest", scope $"[SCALE] build: {((mBuild != null && mBuild.Succeeded) ? "succeeded" : "FAILED")}, {(mBuild != null ? mBuild.Messages.Count : 0)} message(s)");
				if (mBuild != null)
					for (let m in mBuild.Messages)
						if (@m.Index < 5)
							Notify.Log(.Info, "SelfTest", scope $"[SCALE] build message: {m.Text}");
				mScPhase = 90;
				return false;

			// ---- Every type file open: load time, Save All, Find in Sheets across the project.
			case 90:
				mScT0 = ScNow;
				int opened = 0;
				for (let f in Index.Files)
					if (OpenFile(f.Path, false) != null)
						opened++;
				ScAdd("open every type file", (ScNow - mScT0) * 1000.0);
				Notify.Log(.Info, "SelfTest", scope $"[SCALE] {opened} type files open; memory {ScPrivateBytes() / 1048576.0:0} MB");
				mScPhase = 91;
				mSelfTestWait = 2;
				return false;
			case 91:
				for (let d in mDocs)
					if (!d.FilePath.IsEmpty)
						d.Modified = true;
				mScT0 = ScNow;
				let saved = SaveAll();
				ScAdd("save all", (ScNow - mScT0) * 1000.0);
				SelfTestCheck(saved, "scale: Save All");
				mScT0 = ScNow;
				RunFind("F10");
				ScAdd("find in Sheets (whole project)", (ScNow - mScT0) * 1000.0);
				Notify.Log(.Info, "SelfTest", scope $"[SCALE] find: {mFindHits.Count} hit(s) in {mFindFiles} file(s)");
				mScPhase = (++mScRep < reps) ? 91 : 92;
				if (mScPhase == 92)
					mScRep = 0;
				return false;
			case 92:
				// Back to the big Sheet in front for the edit loop.
				OpenSheet(mScBig, "Big");
				mScCount = 0;
				mScPhase = 93;
				mSelfTestWait = 3;
				return false;

			case 93:
				// The incremental Validate again, now with every type file open.
				let g = ScBigGraph;
				if (g != null && FrontEnd != null)
				{
					let mg = CurrentMethod;
					let warm = FrontEnd.Current; // up to date first
					SelfTestCheck(warm != null, "scale: the compilation is there");
					BeginEdit();
					ScEditLiteral(g, mScRep + 2);
					mg.Doc.Commit(mg);
					mScT0 = ScNow;
					let c = FrontEnd.Current;
					ScAdd("validate incremental, every type open (front end)", (ScNow - mScT0) * 1000.0);
					SelfTestCheck(c != null && FrontEnd.LastWasIncremental, "scale: incremental with every type open");
					EditDoc.Undo();
				}
				mScPhase = (++mScRep < reps) ? 93 : 94;
				if (mScPhase == 94)
					mScRep = 0;
				mScCount = 0;
				mSelfTestWait = 2;
				return false;
			case 94:
				if (mScCount == 0)
				{
					mScT0 = ScNow;
					CheckExternalChange();
					ScAdd("disk change check, every type open", (ScNow - mScT0) * 1000.0);
				}
				// Frames with every type file open (two seconds: the once-a-second checks are in it).
				if (!ScSampleFrames(120))
					return false;
				ScAdd("frame 1:1, every type open", ScFramesMedian());
				List<double> s = scope .();
				s.AddRange(mScFrames);
				s.Sort();
				ScAdd("frame 1:1, every type open (worst of 120)", s.Back);
				String slow = scope .();
				for (let f in mScFrames)
					if (f > 5)
						slow.AppendF(" #{}={:0.0}", @f.Index, f);
				Notify.Log(.Info, "SelfTest", scope $"[SCALE]   slow frames:{slow}");
				mScCount = 0;
				mScPhase = 100;
				return false;

			// ---- The edit loop: add, wire, move, delete, undo, redo, Validate, the Node menu, Find.
			case 100:
				let g = ScBigGraph;
				if (g == null)
				{
					mScPhase = 900;
					return false;
				}
				let i = mScCount++;
				// After the warm-up the undo history is full (200 steps): growth from there on is not the history.
				let warmAt = Math.Min(Math.Max(400, mScSoak / 4), mScSoak / 2);
				if (i == warmAt)
				{
					mScMemWarm = ScPrivateBytes();
					ScAdd("memory after the edit loop's warm-up", mScMemWarm / 1048576.0, "MB");
				}
				if (i >= mScSoak)
				{
					mScMemEnd = ScPrivateBytes();
					ScAdd("memory after the edit loop", mScMemEnd / 1048576.0, "MB");
					ScAdd("memory growth (open -> end)", (mScMemEnd - mScMemOpen) / 1048576.0, "MB");
					ScAdd("memory growth (warm-up -> end)", (mScMemEnd - mScMemWarm) / 1048576.0, "MB");
					mScCount = 0;
					mScPhase = 900;
					return false;
				}
				let mg = CurrentMethod;
				switch (i % 8)
				{
				case 0:
					BeginEdit();
					let n = NodeFactory.Branch(g);
					n.X = (i * 37) % 3000;
					n.Y = (i * 53) % 2000;
					n.HasPos = true;
					mScAdded = n.Id;
					CommitCurrent();
				case 1:
					let n = g.FindNode(mScAdded);
					Node from = null;
					for (let o in g.Nodes)
						if (o.Kind == .Operator && from == null)
							from = o;
					if (n != null && from != null && !from.Outputs.IsEmpty && n.FindInput("condition") != null)
					{
						BeginEdit();
						g.Connect(from.Outputs[0], n.FindInput("condition"));
						CommitCurrent();
					}
				case 2:
					let n = g.FindNode(mScAdded);
					if (n != null)
					{
						BeginEdit();
						n.X += 40;
						LayoutChanged();
					}
				case 3:
					EditDoc.Undo();
				case 4:
					EditDoc.Redo();
				case 5:
					BeginEdit();
					ScEditLiteral(g, i);
					CommitCurrent();
				case 6:
					let n = g.FindNode(mScAdded);
					if (n != null)
					{
						BeginEdit();
						g.RemoveNode(n);
						CommitCurrent();
					}
				default:
					switch ((i / 8) % 3)
					{
					case 0: Validate(true);
					case 1: RunFind("F1");
					default:
						OpenNodeMenu(CurrentTab, .(0, 0), 0);
						mNodeMenu.CloseRequested = true;
					}
				}
				if (mg != null && mg.Doc.CanUndo && (i % 400) == 399)
				{
					// Now and then the document is saved and its undo history kept, as in a session.
					mg.Doc.Modified = false;
				}
				return false;

			// ---- The table, the bounds, the project closed (and its folder gone when it was made here).
			case 900:
				ScMouseRelease();
				Prefs.ShowMinimap = mScMinimap;
				GraphProf.Enabled = false;
				Notify.Log(.Info, "SelfTest", "[SCALE] | Measurement | Median | Runs |");
				for (let m in mScMetrics)
				{
					String runs = scope .();
					for (let r in m.Runs)
						runs.AppendF("{}{:0.0}", runs.IsEmpty ? "" : " / ", r);
					Notify.Log(.Info, "SelfTest", scope $"[SCALE] | {m.Name} | {m.Median:0.0} {m.Unit} | {runs} |");
				}
				if (!full)
				{
					SelfTestCheck(ScMetric("open project").Median <= 5000, scope $"scale: open <= 5 s ({ScMetric("open project").Median:0} ms)");
					SelfTestCheck(ScMetric("frame 1:1").Median <= 50, scope $"scale: a frame at 1:1 <= 50 ms ({ScMetric("frame 1:1").Median:0.0} ms)");
					SelfTestCheck(ScMetric("frame zoomed out").Median <= 50, scope $"scale: a frame zoomed out <= 50 ms ({ScMetric("frame zoomed out").Median:0.0} ms)");
					SelfTestCheck(ScMetric("validate incremental (front end)").Median <= 50, scope $"scale: incremental Validate <= 50 ms ({ScMetric("validate incremental (front end)").Median:0.0} ms)");
					SelfTestCheck(ScMetric("node menu search").Median <= 100, scope $"scale: Node menu search <= 100 ms ({ScMetric("node menu search").Median:0.0} ms)");
					SelfTestCheck(ScMetric("memory growth (warm-up -> end)").Median <= 50, scope $"scale: no runaway memory in the edit loop ({ScMetric("memory growth (warm-up -> end)").Median:0.0} MB)");
				}
				for (let d in mDocs)
					d.Modified = false;
				OpenProjectNow("", "", false);
				if (mScTemp)
					Directory.DelTree(mScRoot).IgnoreError();
				mScPhase = 0;
				return true;
			}
			return true;
		}
	}
}
#endif
