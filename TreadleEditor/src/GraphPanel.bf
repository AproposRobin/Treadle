using System;
using System.Collections;
using ImGui;
using Treadle.Graph;
using Treadle.Document;

using Treadle.Catalog;

namespace Treadle.Editor
{
	/// What a mouse drag on the canvas is doing.
	enum CanvasMode
	{
		None,
		/// Right button pressed, not moved yet: becomes Pan on drag, a context menu on release.
		RightPending,
		Pan,
		Marquee,
		/// Moving the selection: nodes, comments and reroute nodes together.
		MoveNodes,
		/// Dragging a new wire out of `DragPin`.
		Wire,
		/// Ctrl+drag: moving the links of `DragPin` (ids in `DragLinks`) to another pin.
		Relink,
		/// Dragging the bottom-right corner of comment `DragComment`.
		ResizeComment
	}

	/// A reroute knot: the link (by its pins) and the knot's index along it.
	struct KnotRef : IEquatable<KnotRef>
	{
		public int32 FromPin;
		public int32 ToPin;
		public int32 Index;

		public this(int32 fromPin, int32 toPin, int32 index)
		{
			FromPin = fromPin;
			ToPin = toPin;
			Index = index;
		}

		public bool IsValid => FromPin != 0;
		public bool Equals(KnotRef o) => FromPin == o.FromPin && ToPin == o.ToPin && Index == o.Index;
	}

	/// One open function graph (a tab in the graph area) and its canvas view state.
	class GraphTab
	{
		static int32 sNextUid;
		/// The tab's identity in the tab bar: its method key changes with the parameter types
		/// (an input added), and the tab must stay the one in front.
		public int32 Uid = ++sNextUid;
		public TypeDocument Doc;
		public String MethodKey = new .() ~ delete _;
		public String Title = new .() ~ delete _;
		public Graph LastGraph;
		/// Graph.Serial of the graph last drawn: a freed graph's address can be reused, so identity
		/// is checked by serial.
		public int32 LastGraphSerial = -1;
		/// Frame the entry node on the next draw.
		public bool NeedsFocus = true;
		/// Keys of nodes to re-select after a regeneration.
		public List<String> ReselectKeys = new .() ~ DeleteContainerAndItems!(_);
		public List<int32> SelectedNodes = new .() ~ delete _;
		public List<int32> SelectedLinks = new .() ~ delete _;
		/// Selected comment boxes (GraphComment.Id).
		public List<int32> SelectedComments = new .() ~ delete _;
		/// Selected reroute nodes. They select, move and delete with the nodes and comments.
		public List<KnotRef> SelectedKnots = new .() ~ delete _;
		/// The selection started with a reroute node, not a node: the order Q alignment uses (first, second).
		public bool KnotsFirst;
		/// Comment whose title is being edited inline (0 = none).
		public int32 EditingComment;
		/// Top-left of the canvas on screen, and its size (updated every draw).
		public ImVec2 CanvasOrigin;
		public ImVec2 CanvasSize;
		public bool Open = true;
		/// Left edge of the tab in the tab bar the last time it was drawn (tabs can be dragged into another order).
		public float BarX;

		// ---- View: screen = CanvasOrigin + (grid + Pan) * Zoom
		public ImVec2 Pan;
		public int32 ZoomLevel = Canvas.DefaultZoomLevel;
		public float Zoom => Canvas.ZoomLevels[ZoomLevel];
		public double ZoomChangedTime = -100;
		bool mHasPendingCenter;
		ImVec2 mPendingCenter;

		// ---- Drag state
		public CanvasMode Mode;
		public int32 ModeButton;
		public ImVec2 PressPos;
		public ImVec2 LastMouse;
		public bool Moved;
		public int32 DragPin;
		public List<int32> DragLinks = new .() ~ delete _;
		public Dictionary<int32, ImVec2> DragStart = new .() ~ delete _;
		public List<int32> MarqueeBase = new .() ~ delete _;
		public List<int32> MarqueeCommentBase = new .() ~ delete _;
		public List<KnotRef> MarqueeKnotBase = new .() ~ delete _;
		/// Comments moving with a MoveNodes drag (id -> start position) and the one being resized.
		public Dictionary<int32, ImVec2> DragCommentStart = new .() ~ delete _;
		/// Node groups moving with a MoveNodes drag (group id -> start position of the folded group).
		public Dictionary<int32, ImVec2> DragGroupStart = new .() ~ delete _;
		/// Reroute nodes moving with a MoveNodes drag, with their start positions.
		public List<(KnotRef knot, ImVec2 start)> DragKnotStart = new .() ~ delete _;
		public int32 DragComment;
		/// Start size of a comment resize.
		public ImVec2 DragVec;
		public KnotRef PressKnot;
		public bool PressKnotWasSelected;
		public int32 PressComment;
		public bool PressCommentWasSelected;
		/// Ctrl+F "Find in Sheets" box.
		public bool FindOpen;
		public bool FindFocus;
		public int32 PressNode;
		public bool PressNodeWasSelected;
		/// Pin / link a right-click menu is open for.
		public int32 CtxPin;
		public int32 CtxLink;

		public this(TypeDocument doc, StringView methodKey, StringView title)
		{
			Doc = doc;
			MethodKey.Set(methodKey);
			Title.Set(title);
		}

		public bool IsSelected(int32 nodeId) => SelectedNodes.Contains(nodeId);

		public bool IsKnotSelected(KnotRef k)
		{
			for (let s in SelectedKnots)
				if (s.Equals(k))
					return true;
			return false;
		}

		public void ToggleKnot(KnotRef k)
		{
			for (int i = 0; i < SelectedKnots.Count; i++)
				if (SelectedKnots[i].Equals(k))
				{
					SelectedKnots.RemoveAt(i);
					return;
				}
			AddKnot(k);
		}

		public void AddKnot(KnotRef k)
		{
			if (IsKnotSelected(k))
				return;
			if (SelectedNodes.IsEmpty && SelectedKnots.IsEmpty)
				KnotsFirst = true;
			SelectedKnots.Add(k);
		}

		public void ClearSelection()
		{
			SelectedNodes.Clear();
			SelectedLinks.Clear();
			SelectedComments.Clear();
			SelectedKnots.Clear();
			KnotsFirst = false;
		}

		public bool IsCommentSelected(int32 id) => SelectedComments.Contains(id);

		public void SelectOnly(int32 nodeId)
		{
			ClearSelection();
			SelectedNodes.Add(nodeId);
		}

		public void AddToSelection(int32 nodeId)
		{
			if (SelectedNodes.Contains(nodeId))
				return;
			if (SelectedNodes.IsEmpty && SelectedKnots.IsEmpty)
				KnotsFirst = false;
			SelectedNodes.Add(nodeId);
		}

		public void ToggleSelection(int32 nodeId)
		{
			if (!SelectedNodes.Remove(nodeId))
				AddToSelection(nodeId);
		}

		/// Scrolls so grid point (x, y) is in the middle of the canvas (applied on the next draw).
		public void CenterOn(float x, float y)
		{
			mHasPendingCenter = true;
			mPendingCenter = .(x, y);
			NeedsFocus = false;
		}

		public void ApplyPendingCenter()
		{
			if (!mHasPendingCenter || CanvasSize.x <= 0)
				return;
			mHasPendingCenter = false;
			Pan = .(CanvasSize.x * 0.5f / Zoom - mPendingCenter.x, CanvasSize.y * 0.5f / Zoom - mPendingCenter.y);
		}

		// ---- Eased view jumps (saved views, Home): the middle of the canvas moves from one grid point
		// to another over about 150 ms.
		public const double ViewAnimSeconds = 0.15;
		/// The frame loop keeps drawing until this time (GraphTab.Animating).
		public static double sAnimUntil;
		public static bool Animating => Gui.igGetTime() < sAnimUntil;
		public bool ViewAnim;
		double mAnimStart;
		ImVec2 mAnimFrom;
		ImVec2 mAnimTo;

		/// The grid point in the middle of the canvas.
		public ImVec2 ViewCenter => .(CanvasSize.x * 0.5f / Zoom - Pan.x, CanvasSize.y * 0.5f / Zoom - Pan.y);

		/// Eases the view to a zoom level and a grid point in the middle. The zoom changes at once
		/// (about the current middle), the pan eases.
		public void AnimateTo(float cx, float cy, int32 levelIn)
		{
			NeedsFocus = false;
			mHasPendingCenter = false;
			let level = Math.Clamp(levelIn, 0, (int32)Canvas.ZoomLevels.Count - 1);
			if (CanvasSize.x <= 0)
			{
				ZoomLevel = level;
				CenterOn(cx, cy);
				return;
			}
			let c = ViewCenter;
			if (level != ZoomLevel)
			{
				ZoomLevel = level;
				ZoomChangedTime = Gui.igGetTime();
				Pan = .(CanvasSize.x * 0.5f / Zoom - c.x, CanvasSize.y * 0.5f / Zoom - c.y);
			}
			mAnimFrom = c;
			mAnimTo = .(cx, cy);
			mAnimStart = Gui.igGetTime();
			ViewAnim = true;
			sAnimUntil = mAnimStart + ViewAnimSeconds + 0.1;
		}

		/// Moves the view one step along the ease (called once per frame before drawing).
		public void StepViewAnim()
		{
			if (!ViewAnim || CanvasSize.x <= 0)
				return;
			float t = (float)((Gui.igGetTime() - mAnimStart) / ViewAnimSeconds);
			if (t >= 1)
			{
				t = 1;
				ViewAnim = false;
			}
			float e = 1 - (1 - t) * (1 - t) * (1 - t);
			float cx = mAnimFrom.x + (mAnimTo.x - mAnimFrom.x) * e;
			float cy = mAnimFrom.y + (mAnimTo.y - mAnimFrom.y) * e;
			Pan = .(CanvasSize.x * 0.5f / Zoom - cx, CanvasSize.y * 0.5f / Zoom - cy);
		}

		/// Ends an ease at once (a drag of the view or the minimap takes over).
		public void CancelViewAnim() { ViewAnim = false; }

		public ImVec2 GridToScreen(float x, float y) => .(CanvasOrigin.x + (x + Pan.x) * Zoom, CanvasOrigin.y + (y + Pan.y) * Zoom);
		public ImVec2 ScreenToGrid(ImVec2 s) => .((s.x - CanvasOrigin.x) / Zoom - Pan.x, (s.y - CanvasOrigin.y) / Zoom - Pan.y);

		/// Changes the zoom level keeping the grid point under `anchor` (screen) fixed.
		public void SetZoomLevel(int32 level, ImVec2 anchor)
		{
			let clamped = Math.Clamp(level, 0, (int32)Canvas.ZoomLevels.Count - 1);
			if (clamped == ZoomLevel)
				return;
			let g = ScreenToGrid(anchor);
			ZoomLevel = clamped;
			Pan = .((anchor.x - CanvasOrigin.x) / Zoom - g.x, (anchor.y - CanvasOrigin.y) / Zoom - g.y);
			ZoomChangedTime = Gui.igGetTime();
		}

		public void CancelInteraction()
		{
			Mode = .None;
			DragLinks.Clear();
			DragStart.Clear();
			MarqueeBase.Clear();
			MarqueeCommentBase.Clear();
			DragCommentStart.Clear();
			DragGroupStart.Clear();
			DragKnotStart.Clear();
			MarqueeKnotBase.Clear();
			DragComment = 0;
			DragPin = 0;
			PressNode = 0;
			PressKnot = default;
			PressComment = 0;
		}
	}

	enum NodeShape
	{
		Normal,
		/// A pill: a variable getter, `this`, and a member read on a wired receiver (`Count`), with its
		/// Receiver pin on the left and its value on the right.
		Getter,
		/// Headerless math node with a big symbol (also UE's compact pure calls with no inputs).
		Operator
	}

	/// Per-frame layout of one visible pin, in grid units relative to its node.
	struct PinLay
	{
		public Pin Pin;
		public NodeLay Node;
		/// Text shown next to the pin (usually Pin.Label; a Set's value row shows the variable).
		public StringView LabelText;
		/// Pin centre.
		public ImVec2 Off;
		public float RowY;
		/// Inputs: label left edge. Outputs: label right edge.
		public float LabelX;
		public float LabelW;
		public float FieldX;
		/// 0 = no inline value field.
		public float FieldW;
		public bool Check;
		/// The typed control of an unwired input (PinValue.KindOf); Expr when untyped.
		public PinValueKind VKind;
		public bool Visible;
		/// An unconnected Target of a member call: drawn as a greyed "self", like UE.
		public bool SelfHint;
	}

	/// Per-frame layout of one node, in grid units (zoom 1, base font size).
	class NodeLay
	{
		public Node Node;
		public NodeShape Shape;
		public float W;
		public float H;
		/// A getter pill: where its title starts (past the Receiver pin when it has one).
		public float TitleX;
		public float HeaderH;
		public String Title = new .() ~ delete _;
		public String Subtitle = new .() ~ delete _;
		public List<String> CodeLines = new .() ~ DeleteContainerAndItems!(_);
		public float CodeY;
		public float CodeH;
		/// A Math Expression: its expression is a field in the body (at CodeY, CodeH high).
		public bool MathField;
		public bool ShowArgs;
		public float ArgsY;
		/// The "Add pin" button of a Sequence, Multi Gate or Switch (at AddPinY, right-aligned).
		public bool ShowAddPin;
		public float AddPinY;
		/// An exec node nothing runs into (no code yet). The "Not connected" line shows only with Verbose node warnings.
		public bool Orphan;
		public float OrphanY;
		/// Drawn faded: not wired into the flow (Orphan, or the code generator's "not connected" warning), no error, and
		/// Verbose node warnings is off. The warning text stays in the hover tooltip.
		public bool Faded;
		public String Error;
		/// The error has a quick fix (a "Fix" chip at the end of its strip): Make local variable.
		public bool CanFix;
		/// Warning (amber strip: compiler or GraphValidator warning) when the node has no error.
		public String Warning;
		/// The problem strip (grid units from the node's top-left): under the header of a normal node,
		/// under the body of a headerless one. Its one line is `StripText` (shortened with "...").
		public float StripY;
		public float StripH;
		public float StripW;
		public String StripText = new .() ~ delete _;
		/// The node's error is about its Target pin: the pin is drawn red.
		public bool TargetBad;
		public float SymbolSize;
		/// Title scale for headerless nodes (operators 1.8, compact calls ~1.2).
		public float SymbolScale = 1.8f;
		/// Header colour (UE colours per node kind / variable type).
		public uint32 Header;
		public bool Selected;
		public bool Visible;
		/// Pointer pins or an Unsafe Scope: a hatched stripe on the header.
		public bool Unsafe;
		/// How many flow nodes evaluate this value node (2+ shows "evaluated Nx").
		public int32 Evaluated;
		/// Drawn compact (the layout file's `collapsed`): unwired pins hidden.
		public bool Collapsed;
		/// A member of a folded node group: not drawn or hit (its group node stands in for it).
		public bool Hidden;

		public void Reset()
		{
			Title.Clear();
			Subtitle.Clear();
			ClearAndDeleteItems!(CodeLines);
			MathField = false;
			ShowArgs = false;
			ShowAddPin = false;
			Orphan = false;
			Faded = false;
			Error = null;
			CanFix = false;
			Warning = null;
			StripY = 0;
			StripH = 0;
			StripW = 0;
			StripText.Clear();
			TargetBad = false;
			Unsafe = false;
			Evaluated = 0;
			Collapsed = false;
			Hidden = false;
			CodeH = 0;
		}
	}

	/// Draws a graph on a zoomable, pannable canvas (UE5 Blueprint look and feel) and turns
	/// user interaction into graph edits.
	class GraphPanel
	{
		EditorApp mApp;
		TextBuffer mScratch = new .(1024) ~ delete _;
		/// The typed value controls of unwired inputs (also driven by the self test).
		public PinValueEditor mPinEditor = new .() ~ delete _;
		List<Pin> mLeft = new .() ~ delete _;
		List<Pin> mRight = new .() ~ delete _;
		/// The inline value being typed into already pushed an undo step (commit on deactivate).
		bool mInlineEditPushedUndo;
		/// "+ arg" / "- arg" clicked inside a node (positive = add, negative = remove); applied
		/// after drawing so the node list isn't modified mid-iteration.
		int32 mPendingArgNode;
		/// The node whose "Add pin" was clicked this frame (applied after drawing).
		int32 mPendingAddPin;
		const String cAddPinLabel = "Add pin \u{E141}";
		/// A "TREADLE_MEMBER" payload dropped on the canvas this frame (applied after drawing): an Outline
		/// row's index, or EditorApp.cMenuDragIndex for a Node menu row.
		int32 mPendingDrop;
		bool mHasPendingDrop;
		/// Drops the Sheet took (the dragvars-live self test checks the drop arrived).
		public int DropsSeen;
		/// The pin under the cursor when the drop arrived: the last frame's hover, the pin whose ring
		/// the user saw (on the frame the button comes up the payload is no longer reported as dragged).
		int32 mPendingDropPin;
		ImVec2 mPendingDropPos;
		/// Something called mApp.CommitCurrent() this frame: stop touching the graph.
		bool mCommitted;
		/// Compile errors mapped onto nodes for the graph being drawn (node id -> message).
		Dictionary<int32, String> mNodeErrors = new .() ~ DeleteDictionaryAndValues!(_);
		/// Compiler / GraphValidator / generator warnings by node id (yellow badge, never block a commit; an error on the same node wins).
		Dictionary<int32, String> mNodeWarnings = new .() ~ DeleteDictionaryAndValues!(_);

		/// Ids of the pins that have a wire, built once per frame: Graph.IsLinked scans every wire, and the layout asks for
		/// every pin of every node.
		HashSet<int32> mLinked = new .() ~ delete _;

		bool Linked(Pin p) => mLinked.Contains(p.Id);

		/// The selected node ids as a set for this frame (Selected is asked for every node).
		HashSet<int32> mSelectedNow = new .() ~ delete _;

		void BuildLinked(Graph graph)
		{
			mLinked.Clear();
			for (let l in graph.Links)
			{
				mLinked.Add(l.From.Id);
				mLinked.Add(l.To.Id);
			}
		}

		// Per-frame layout
		List<NodeLay> mLayPool = new .() ~ DeleteContainerAndItems!(_);
		Dictionary<int32, NodeLay> mLayById = new .() ~ delete _;
		/// The half length of the + / - strokes an Operator node drew in the last frame, in graph units
		/// (the self test).
		Dictionary<int32, float> mSymbolArm = new .() ~ delete _;

		/// The width (graph units) node `nodeId` was laid out at in the last frame; 0 when not drawn.
		public float LaidOutWidth(int32 nodeId) => (mLayById.TryGetValue(nodeId, let L) && L.Node != null && L.Node.Id == nodeId) ? L.W : 0;

		/// The half length of the strokes node `nodeId` drew for + or - in the last frame (0: none).
		public float SymbolArm(int32 nodeId) => mSymbolArm.TryGetValue(nodeId, let a) ? a : 0;

		/// The width (graph units) a Math Expression's text needs in its field at zoom 1.
		public float MathTextWidth(StringView text)
		{
			if (mMono != null)
				Gui.igPushFont(mMono, MathFieldFont(1));
			let w = Gui.CalcTextSize(text).x;
			if (mMono != null)
				Gui.igPopFont();
			return w;
		}
		List<NodeLay> mOrder = new .() ~ delete _;
		List<PinLay> mPins = new .() ~ delete _;
		Dictionary<int32, int> mPinIndex = new .() ~ delete _;

		// Per-frame hover results
		int32 mHoverPin;
		int32 mHoverNode;
		int32 mHoverLink;
		/// Segment of the hovered link (0 = before the first reroute knot).
		int32 mHoverLinkSegment;
		KnotRef mHoverKnot;
		/// Comment whose title bar / resize corner is hovered.
		int32 mHoverComment;
		int32 mHoverCommentResize;

		// Comment boxes and reroutes of the graph being drawn (owned by the document).
		List<GraphComment> mComments = new .() ~ delete _;
		Dictionary<int64, GraphReroute> mRoutes = new .() ~ delete _;
		TextBuffer mCommentBuf = new .(512) ~ delete _;
		bool mFocusCommentEdit;
		int32 mFocusedCommentEdit;
		int32 mCtxComment;
		TextBuffer mFindBuf = new .(256) ~ delete _;

		// Hover tooltip for nodes (UE shows it after a short delay).
		int32 mTipNode;
		double mTipSince;

		// "Get X / Set X" menu after dropping a variable without Ctrl / Alt.
		bool mVarDropOpen;
		String mVarDropName = new .() ~ delete _;
		String mVarDropType = new .() ~ delete _;
		ImVec2 mVarDropPos;

		// Fonts / metrics (base size, zoom 1)
		ImFont* mFont;
		ImFont* mMono;
		float mFontSize = 16;
		float RowH => mFontSize + 10;

		public this(EditorApp app)
		{
			mApp = app;
		}

		/// The node being laid out is drawn collapsed: HidePin hides its unwired pins.
		bool mLayCollapsed;
		/// "evaluated Nx" counts of the graph drawn (node id -> count), with the graph and version
		/// they were computed for.
		Dictionary<int32, int32> mFanOut = new .() ~ delete _;
		int32 mFanOutSerial = -1;
		int32 mFanOutVersion = -1;
		int32 mFanOutGeneration = -1;
		/// The Validate generation, stale state and preference the counts were taken for.
		int32 mFanOutShown = -1;
		/// This frame: the problems shown are from before the last edit (strips, outlines, pin badges and
		/// "evaluated Nx" drawn faint until the next Validate).
		bool mProblemsDim;
		/// The last frame drew the problems dimmed (the self test).
		public bool ProblemsDim => mProblemsDim;
		/// `c` with its alpha scaled down when the problems shown are stale.
		uint32 ProblemColor(uint32 c) => mProblemsDim ? ((c & 0x00FFFFFF) | ((((c >> 24) * 40) / 100) << 24)) : c;

		/// Whether the layout file draws this node collapsed (`collapsed <id>`).
		public bool IsCollapsed(GraphTab tab, Node node)
		{
			if (tab == null || tab.Doc == null || tab.Doc.Collapsed.IsEmpty)
				return false;
			String key = scope $"{tab.MethodKey}|{node.Key}";
			for (let c in tab.Doc.Collapsed)
				if (c == key)
					return true;
			return false;
		}

		/// Collapses or expands a node (layout only: the type file does not change).
		public void SetCollapsed(GraphTab tab, Node node, bool collapsed)
		{
			if (tab == null || node == null || IsCollapsed(tab, node) == collapsed)
				return;
			String key = scope $"{tab.MethodKey}|{node.Key}";
			if (collapsed)
				tab.Doc.Collapsed.Add(new String(key));
			else
			{
				for (let c in tab.Doc.Collapsed)
					if (c == key)
					{
						tab.Doc.Collapsed.Remove(c);
						delete c;
						break;
					}
			}
			mApp.LayoutChanged();
		}

		bool HidePin(Graph g, Pin p)
		{
			// A variable of this type: no Receiver row while nothing is wired into it (it reads `this`).
			if (p.Role == .Receiver && p.IsInput && (p.Owner.Kind == .Get || p.Owner.Kind == .Set) && p.Owner.Text.StartsWith("this.") && !Linked(p))
				return true;
			// A collapsed node shows only its wired pins.
			if (mLayCollapsed && !Linked(p))
				return true;
			// A split struct pin is drawn as its field pins (SplitPins).
			if (p.Kind == .Value && SplitPins.IsSplit(p))
				return true;
			// UE's SET node: the variable is the row label, not a pin, unless something is wired
			// into it (a computed object) or there is no value row to carry the name.
			if (IsSetVariableLabel(g, p))
				return true;
			// Static calls (Console.WriteLine, Math.Max, MyType.Make): UE shows no Target pin, just
			// "Receiver is X" under the title. The type stays editable in Properties.
			if (IsStaticTarget(g, p))
				return true;
			// A void function's Return has no value (UE shows no pin then).
			if (p.IsInput && p.Name == "value" && p.Owner.Kind == .Return && (p.TypeName.IsEmpty || p.TypeName == "void") &&
				p.Default.IsEmpty && !Linked(p))
				return true;
			// Statements after a return/break are legal but unusual: only show that pin if used.
			if (!p.IsInput && p.Kind == .Flow && p.Name == "then" &&
				(p.Owner.Kind == .Return || p.Owner.Kind == .Break || p.Owner.Kind == .Continue))
				return !Linked(p);
			return false;
		}

		static StringView[?] sStaticClasses = .("Console", "Math", "Runtime", "String", "Environment", "File", "Directory",
			"Path", "Debug", "Platform", "Internal", "Enum", "Char8", "Char16", "Char32", "Int", "Float", "Double");

		/// An unlinked call target naming a type rather than an object.
		bool IsStaticTarget(Graph g, Pin p)
		{
			if (p.Owner.Kind != .Call || p.Name != "receiver" || !p.IsInput || Linked(p))
				return false;
			StringView t = p.Default;
			t.Trim();
			if (t.IsEmpty || !t[0].IsUpper)
				return false;
			for (let c in t.RawChars)
				if (!c.IsLetterOrDigit && c != '_' && c != '.')
					return false;
			for (let sc in sStaticClasses)
				if (t == sc)
					return true;
			// Seam: the language's type table says which names are types.
			String kind = scope .();
			mApp.Language.Types.KindOf(t, kind);
			return !kind.IsEmpty;
		}

		static bool IsBoolLiteral(Pin p) => p.Default == "true" || p.Default == "false";

		/// A member call's Target with nothing wired or typed in: it means `this`.
		bool IsSelfTarget(Graph g, Pin p)
		{
			return p.IsInput && p.Name == "receiver" && p.Owner.Kind == .Call && p.Owner.Binding == .Instance &&
				p.Default.IsEmpty && !Linked(p);
		}

		/// An instance Call whose Receiver is not wired, has no value and cannot be `this` (a static
		/// Sheet, or a Sheet of a type that is not `owner` nor derived from it).
		public bool NeedsReceiver(Graph g, Node node, Pin target, StringView owner)
		{
			if (node.Binding != .Instance || Linked(target) || !target.Default.IsEmpty)
				return false;
			if (g.StaticContext || g.SelfType.IsEmpty)
				return true;
			String self = scope .();
			Treadle.Catalog.TypeRules.Normalize(g.SelfType, self);
			if (Treadle.Catalog.NodeCatalog.SameOwner(self, owner))
				return false;
			let types = mApp.Language.Types;
			return types == null || !types.IsSubtype(self, owner);
		}

		/// A Set node's unlinked "receiver" pin that is shown as the label of its value row.
		bool IsSetVariableLabel(Graph g, Pin p)
		{
			// Set nodes name their variable in the subject (Graph-Format.md 3.2), not in a pin.
			return false;
		}


		float InlineFieldWidth(Pin p)
		{
			float tw = Gui.CalcTextSize(p.Default).x;
			return Math.Clamp(tw + 18, 44, 260);
		}

		void GetDisplayTitle(Graph g, Node node, String title)
		{
			switch (node.Kind)
			{
			case .Entry:
				title.Append(g.MethodName.IsEmpty ? "Entry" : (StringView)g.MethodName);
			default:
				node.GetTitle(title);
			}
		}

		/// The grey line under a node's title: "Receiver is X", the lifetime of an allocation.
		void GetSubtitle(Graph g, Node node, String sub)
		{
			if (FlowMacros.IsAction(node.Kind) || NodeKinds.IsStateful(node.Kind))
			{
				let state = node.GetSetting("state");
				if (!state.IsEmpty)
					sub.Append(state);
				return;
			}
			if (node.Kind == .ChainCtor)
			{
				// Whose constructor runs first (the title says Base / This Constructor).
				let doc = mApp.EditDoc;
				if (node.Text == "this")
					sub.AppendF("runs first: another of {}", Node.ShortTypeName(g.SelfType, .. scope String()));
				else if (doc != null && doc.Header.Base != null)
					sub.AppendF("runs first: {}", doc.Header.Base.ToString(.. scope String()));
				else
					sub.Append("runs first: the base class");
				return;
			}
			if (node.Kind == .Literal)
			{
				sub.Append(node.GetSetting("value"));
				return;
			}
			if (node.Kind == .Lambda)
			{
				// Its signature with the input names, and where it lives: "int(int a, int b)  ·  local".
				mApp.LambdaSubtitle(node, sub);
				if (sub.IsEmpty)
				{
					sub.Append(node.GetSetting("type").IsEmpty ? "no type: set it in Properties" : "type not known");
					return;
				}
				let alloc = node.GetSetting("alloc");
				sub.AppendF("  \u{00B7}  {}", (alloc == "local") ? "local" : ((alloc == "construct") ? "heap" : "function pointer"));
				return;
			}
			sCaptureGraph = g;
			if (LifetimeSubtitle(node, sub))
				return;
			if (node.Kind != .Call)
				return;
			defer AppendOverload(g, node, sub);
			if (node.Binding == .Static)
			{
				// "Receiver is Console": static, so the type is the fixed receiver and there is no Receiver pin.
				let m = Treadle.Model.MemberRef.Parse(node.Text);
				defer delete m;
				if (m.Type != null)
					sub.AppendF("Receiver is {}", m.Type.ToString(.. scope String()));
				return;
			}
			let target = node.FindInput("receiver");
			if (target == null)
				return;
			StringView name = (node.Binding == .Instance && node.OwnerType != null) ? (StringView)node.OwnerType : (StringView)target.TypeName;
			if (!name.IsEmpty && NeedsReceiver(g, node, target, name))
			{
				// Nothing wired and no `this` of that type here: say where the object comes from.
				let shortName = Node.ShortTypeName(name, .. scope String());
				sub.AppendF("needs a{} {}: drag from a Construct {} or a variable", (!shortName.IsEmpty && "AEIOUaeiou".Contains(shortName[0])) ? "n" : "", shortName, shortName);
			}
			else if (!name.IsEmpty)
				sub.AppendF("Receiver is {}", name);
		}

		/// A function with several overloads names the one the node calls: "WriteLine(StringView)"
		/// (docs/Calls-and-Receivers.md#overloads; Properties > Call > Overload switches it).
		void AppendOverload(Graph g, Node node, String sub)
		{
			// Seam: overloads are bind results of the language; nothing to name until it is installed.
			if (!node.Ambiguous)
				return;
			if (!sub.IsEmpty)
				sub.Append("  \u{00B7}  ");
			sub.Append("several overloads");
		}

		/// The graph whose lambdas LifetimeSubtitle lists captures for.
		static Graph sCaptureGraph;

		/// The allocation / lifetime line under a lifetime node's title (docs/Lifetime-Nodes.md):
		/// how long the object lives, when the deferred code runs, which case a Result node tests.
		public static bool LifetimeSubtitle(Node node, String sub)
		{
			switch (node.Kind)
			{
			case .Construct:
				sub.Append(node.HasSetting("count") ? "heap array: you delete it" : "heap: you delete it");
				return true;
			case .Local:
				sub.Append(node.HasSetting("function-scope") ? "freed when the function returns" : "freed when this region ends");
				return true;
			case .Defer:
				sub.Append("Deferred runs when this region ends");
				return true;
			case .DeferDelete:
				sub.Append("deleted when this region ends");
				return true;
			case .ResultMatch:
				sub.Append("branches on Ok / Err");
				return true;
			case .Try:
				sub.Append("returns early on error");
				return true;
			case .Scope:
				sub.Append(node.Unsafe ? "pointer nodes allowed inside" : "Locals inside end with Body");
				return true;
			case .DoWhile:
				sub.Append("Body runs once, then while Condition");
				return true;
			case .Lambda, .Bind:
				let alloc = node.GetSetting("alloc");
				if (alloc == "construct")
					sub.Append("heap: you delete it");
				else if (alloc == "local")
					sub.Append("freed when this region ends");
				else
					return false;
				return true;
			default:
				return false;
			}
		}

		// ------------------------------------------------------------------ layout

		/// Drawn as a pill: a variable (`Count`, `mName.Length`), `this` / `base`, and a member read whose
		/// Receiver is wired or empty. A Receiver typed in as text keeps the full node, which has the field.
		bool IsGetterShaped(Graph g, Node node)
		{
			if (node.Kind == .This || node.Kind == .Base)
				return true;
			if (node.Kind != .Get)
				return false;
			// A Get whose value is split shows its field pins: a full node.
			if (SplitPins.IsSplit(node.FindOutput("value")))
				return false;
			let target = node.FindInput("receiver");
			return target == null || Linked(target) || target.Default.IsEmpty;
		}

		NodeLay LayoutNode(GraphTab tab, Graph graph, Node node, int index)
		{
			while (mLayPool.Count <= index)
				mLayPool.Add(new NodeLay());
			let L = mLayPool[index];
			L.Reset();
			L.Node = node;
			L.Selected = mSelectedNow.Contains(node.Id);
			mLayById[node.Id] = L;

			float fh = mFontSize;
			float rowH = RowH;
			GetDisplayTitle(graph, node, L.Title);
			L.Header = HeaderFor(graph, node);
			L.Collapsed = IsCollapsed(tab, node);
			mLayCollapsed = L.Collapsed;
			L.Evaluated = mFanOut.TryGetValue(node.Id, let fanOut) ? fanOut : 0;

			mLeft.Clear();
			mRight.Clear();
			for (let p in node.Inputs)
				if (!HidePin(graph, p))
					mLeft.Add(p);
			for (let p in node.Outputs)
				if (!HidePin(graph, p))
					mRight.Add(p);

			mLayCollapsed = false;
			// Error (red) or warning (amber) on the node; an error wins. Shown as a one-line strip.
			if (mNodeErrors.TryGetValue(node.Id, let err))
			{
				L.Error = err;
				L.TargetBad = node.Kind == .Call && err.StartsWith("Receiver must be");
				// The ref pin's Fix: a ref input fed by a value gets a Local (PinVariables.bf); hidden when it cannot.
				L.CanFix = mApp.RefPinNeedingLocal(tab.Doc, graph, node) != null;
			}
			else if (mNodeWarnings.TryGetValue(node.Id, let warn))
			{
				if (!Prefs.VerboseNodeWarnings && GraphError.IsConnectivity(warn))
					L.Faded = true; // a quiet cue instead of the strip; the tooltip has the text
				else
					L.Warning = warn;
			}
			L.SymbolScale = 1.8f;
			for (int side < 2)
				for (let p in (side == 0) ? node.Inputs : node.Outputs)
					if (p.Kind == .Value && mApp.Language.Types.Family(p.TypeName) == .Pointer)
						L.Unsafe = true;
			if (node.Unsafe)
				L.Unsafe = true;
			if (IsGetterShaped(graph, node))
				L.Shape = .Getter;
			else if (node.Kind == .Operator)
				L.Shape = .Operator;
			else if (node.Kind == .Call && node.IsPure && mLeft.IsEmpty)
			{
				// UE's compact pure node: no header, the name in the middle, output on the right.
				L.Shape = .Operator;
				L.SymbolScale = 1.15f;
			}
			else
				L.Shape = .Normal;
			bool compact = L.Shape == .Operator && node.Kind != .Operator;
			Pin setTarget = (node.Kind == .Set) ? node.FindInput("receiver") : null;
			bool setLabel = setTarget != null && IsSetVariableLabel(graph, setTarget);

			float titleW = Gui.CalcTextSize(L.Title).x;

			if (L.Shape == .Getter)
			{
				// The Receiver pin of a member read sits in the rounded left end, the value pin in the right end.
				bool hasIn = !mLeft.IsEmpty;
				L.HeaderH = 0;
				L.TitleX = hasIn ? 28 : 14;
				L.W = Math.Max(L.TitleX + titleW + 34, hasIn ? 86 : 70);
				L.H = rowH + 4;
				for (let p in node.Outputs)
				{
					PinLay pl = default;
					pl.Pin = p;
					pl.Node = L;
					pl.Visible = (p == node.Result) || (node.Result == null && @p.Index == 0);
					pl.Off = .(L.W - 12, L.H * 0.5f);
					AddPin(pl);
				}
				for (let p in node.Inputs)
				{
					PinLay pl = default;
					pl.Pin = p;
					pl.Node = L;
					pl.Visible = mLeft.Contains(p);
					pl.Off = .(12, L.H * 0.5f);
					AddPin(pl);
				}
			}
			else
			{
				if (L.Shape == .Normal)
				{
					GetSubtitle(graph, node, L.Subtitle);
					L.HeaderH = fh + 10;
					if (!L.Subtitle.IsEmpty)
						L.HeaderH += fh * 0.85f + 2;
				}
				else
					L.HeaderH = 0;
				if (L.Shape == .Normal && (L.Error != null || L.Warning != null))
				{
					// The problem strip sits right under the header; the pins move down by its height.
					L.StripY = L.HeaderH;
					L.StripH = StripH();
				}
				float startY = L.HeaderH + L.StripH + 6;

				// Input rows
				float leftMax = 0;
				for (let p in mLeft)
				{
					PinLay pl = default;
					pl.Pin = p;
					pl.Node = L;
					pl.Visible = true;
					pl.RowY = startY + @p.Index * rowH;
					pl.Off = .(12, pl.RowY + rowH * 0.5f);
					pl.LabelX = 24;
					pl.LabelText = (setLabel && p.Name == "value") ? StringView(setTarget.Default) : StringView(p.Label);
					pl.LabelW = pl.LabelText.IsEmpty ? 0 : Gui.CalcTextSize(pl.LabelText).x;
					float w = 24 + pl.LabelW;
					if (IsSelfTarget(graph, p))
					{
						// UE: an unconnected Target reads "self"; there is nothing to type.
						pl.SelfHint = true;
						pl.FieldX = 24 + ((pl.LabelW > 0) ? pl.LabelW + 6 : 0);
						w = pl.FieldX + Gui.CalcTextSize("this").x;
					}
					else if (p.Kind == .Value && !Linked(p))
					{
						pl.VKind = PinValue.KindOf(p.TypeName, p.Default, p.Name, mApp.Language.Types);
						pl.Check = (pl.VKind == .Bool) || (pl.VKind == .Expr && IsBoolLiteral(p));
						if (pl.Check)
							pl.FieldW = fh + 6;
						else if (PinValueEditor.Handles(pl.VKind))
							pl.FieldW = PinValueEditor.Width(pl.VKind, p, mApp.Language.Types);
						else if (pl.VKind == .None)
							pl.FieldW = p.Default.IsEmpty ? 0 : (Gui.CalcTextSize(p.Default).x + 4);
						else if (pl.VKind == .Custom)
						{
							// Grid units at scale 1 (the layout font); DrawPin draws at the zoomed size and
							// shortens the value with an ellipsis before the badge.
							float valueW = Math.Min(Gui.CalcTextSize(p.Default).x, cExpressionValueMaxW);
							pl.FieldW = valueW + Gui.CalcTextSize(cExpressionBadge).x + 22;
						}
						else
							pl.FieldW = InlineFieldWidth(p);
						pl.FieldX = 24 + ((pl.LabelW > 0) ? pl.LabelW + 6 : 0);
						w = pl.FieldX + pl.FieldW;
					}
					leftMax = Math.Max(leftMax, w + 10);
					AddPin(pl);
				}
				// Output rows (x filled in once the width is known)
				float rightMax = 0;
				int firstRight = mPins.Count;
				for (let p in mRight)
				{
					PinLay pl = default;
					pl.Pin = p;
					pl.Node = L;
					pl.Visible = true;
					pl.RowY = startY + @p.Index * rowH;
					pl.LabelText = compact ? "" : StringView(p.Label);
					// A Switch on an enum keeps its cases as `.Name` for the generated code; the pin shows the plain name.
					if (!compact && node.Kind == .Switch && p.Kind == .Flow && pl.LabelText.Length > 1 && pl.LabelText[0] == '.')
						pl.LabelText = pl.LabelText.Substring(1);
					pl.LabelW = pl.LabelText.IsEmpty ? 0 : Gui.CalcTextSize(pl.LabelText).x;
					rightMax = Math.Max(rightMax, 24 + pl.LabelW + 10);
					AddPin(pl);
				}
				int rows = Math.Max(mLeft.Count, mRight.Count);
				float y = startY + rows * rowH;

				if (L.Shape == .Operator)
				{
					L.SymbolSize = fh * L.SymbolScale;
					float symW = Gui.CalcTextSize(L.Title).x * L.SymbolScale + 20;
					L.W = Math.Max(leftMax + symW + rightMax, 90);
					L.H = Math.Max(y + 6, L.SymbolSize + 20);
					if (compact)
						L.H = Math.Max(L.H, rowH + 14);
				}
				else
				{
					float iconW = HeaderIconW(node);
					L.W = Math.Max(leftMax + rightMax + 16, titleW + 40 + iconW);
					if (!L.Subtitle.IsEmpty)
						L.W = Math.Max(L.W, Gui.CalcTextSize(L.Subtitle).x * 0.85f + 40 + iconW);
					L.W = Math.Max(L.W, 110);

					// Body text for code-like nodes (below the pins).
					if (false) // no text bodies in Treadle (the Math field is below)
					{
						BuildCodeLines(node, L.CodeLines);
						if (mMono != null)
							Gui.igPushFont(mMono, 0);
						float codeW = 0;
						for (let line in L.CodeLines)
							codeW = Math.Max(codeW, Gui.CalcTextSize(line).x);
						if (mMono != null)
							Gui.igPopFont();
						L.CodeY = y + 2;
						L.CodeH = L.CodeLines.Count * fh + 8;
						y += L.CodeH + 4;
						L.W = Math.Max(L.W, codeW + 24);
					}

					// A Math Expression: the expression is a field in the body (also in Properties).
					if (node.Kind == .Math)
					{
						L.MathField = true;
						L.CodeY = y + 2;
						L.CodeH = fh + 8;
						y += L.CodeH + 6;
						if (mMono != null)
							Gui.igPushFont(mMono, MathFieldFont(1)); // the size the field is drawn at
						// the expression the field shows (`set expr`; a node read from a file has no title
						// text), else the hint
						let expr = MathText(node, .. scope String());
						float textW = Gui.CalcTextSize(expr.IsEmpty ? "a * b + 1" : expr).x;
						if (mMono != null)
							Gui.igPopFont();
						L.W = Math.Max(L.W, Math.Min(textW + 32, 720 * Look.Scale)); // a long formula makes a wide node
						L.W = Math.Max(L.W, 170);
					}

					// "Add pin" affordance like Blueprint's variadic nodes, shown when selected.
					// A Call only when it calls a C variadic function (its extra inputs are `va0`, `va1`, ...).
					if (((node.Kind == .Call && mApp.IsVariadicCall(node)) || node.Kind == .Index) && L.Selected)
					{
						L.ShowArgs = true;
						L.ArgsY = y + 2;
						y += fh + 8;
					}

					// "Add pin" of a Sequence / Multi Gate / Switch, under the outputs on the right.
					if (!L.Collapsed && (node.Kind == .Sequence || node.Kind == .MultiGate || node.Kind == .Switch) && mApp.CanAddExecPin(node))
					{
						L.ShowAddPin = true;
						L.AddPinY = y;
						y += fh + 8;
						L.W = Math.Max(L.W, Gui.CalcTextSize(cAddPinLabel).x + 40);
					}

					if (!node.IsPure && node != graph.Entry && node.ExecIn != null && !Linked(node.ExecIn))
					{
						L.Orphan = true;
						if (Prefs.VerboseNodeWarnings)
						{
							L.OrphanY = y + 2;
							y += fh * 0.85f + 8;
							L.W = Math.Max(L.W, Gui.CalcTextSize("Not connected: no code yet").x * 0.85f + 24);
						}
					}
					L.H = y + 6;
				}

				for (int i = firstRight; i < mPins.Count; i++)
				{
					var pl = ref mPins[i];
					pl.Off = .(L.W - 12, pl.RowY + rowH * 0.5f);
					pl.LabelX = L.W - 24;
				}
				// Hidden pins still need an anchor for any wire.
				for (let p in node.Inputs)
					if (!mPinIndex.ContainsKey(p.Id))
					{
						PinLay pl = default;
						pl.Pin = p;
						pl.Node = L;
						pl.Off = .(0, L.HeaderH * 0.5f);
						AddPin(pl);
					}
				for (let p in node.Outputs)
					if (!mPinIndex.ContainsKey(p.Id))
					{
						PinLay pl = default;
						pl.Pin = p;
						pl.Node = L;
						pl.Off = .(L.W, L.HeaderH * 0.5f);
						AddPin(pl);
					}
			}

			// The problem strip's one line: shortened to the node's width (the full text is its tooltip,
			// the Problems panel and Properties). Headerless nodes carry the strip under their body.
			if (L.Error != null || L.Warning != null)
			{
				if (L.Shape != .Normal)
				{
					L.StripY = L.H + 2;
					L.StripH = StripH();
					L.StripW = Math.Max(L.W, 140);
				}
				else
					L.StripW = L.W;
				float fixW = L.CanFix ? Gui.CalcTextSize("Fix").x * cStripScale + 14 : 0;
				Ellipsize((L.Error != null) ? L.Error : L.Warning, L.StripW - 14 - fixW, cStripScale, L.StripText);
			}
			if (L.Orphan && !Prefs.VerboseNodeWarnings && L.Error == null && L.Warning == null)
				L.Faded = true;
			return L;
		}

		void AddPin(PinLay pl)
		{
			mPinIndex[pl.Pin.Id] = mPins.Count;
			mPins.Add(pl);
		}

		/// Splits a code node's text into display lines, removing the common indentation of
		/// continuation lines (the first line has none). At most 14 lines plus "...".
		static void BuildCodeLines(Node node, List<String> outLines)
		{
			int minIndent = int.MaxValue;
			int lineNo = 0;
			for (let line in node.Text.Split('\n'))
			{
				if (lineNo++ == 0)
					continue;
				int col = 0;
				bool blank = true;
				for (let c in line.RawChars)
				{
					if (c == '\t') { col += 4; continue; }
					if (c == ' ') { col++; continue; }
					if (c == '\r') continue;
					blank = false;
					break;
				}
				if (!blank)
					minIndent = Math.Min(minIndent, col);
			}
			if (minIndent == int.MaxValue)
				minIndent = 0;
			lineNo = 0;
			for (let line in node.Text.Split('\n'))
			{
				if (outLines.Count == 14)
				{
					outLines.Add(new String("..."));
					break;
				}
				String disp = new String(line);
				disp.TrimEnd();
				disp.Replace("\t", "    ");
				if (lineNo > 0)
				{
					int remove = 0;
					while (remove < minIndent && remove < disp.Length && disp[remove] == ' ')
						remove++;
					disp.Remove(0, remove);
				}
				outLines.Add(disp);
				lineNo++;
			}
		}

		bool TryGetPin(int32 pinId, out PinLay pl)
		{
			if (mPinIndex.TryGetValue(pinId, let idx))
			{
				pl = mPins[idx];
				return true;
			}
			pl = default;
			return false;
		}

		ImVec2 PinScreen(GraphTab tab, PinLay pl) => tab.GridToScreen(pl.Node.Node.X + pl.Off.x, pl.Node.Node.Y + pl.Off.y);

		// ------------------------------------------------------------------ draw

		/// How many times a graph was drawn (the openall self test checks every tab got drawn).
		public static int DrawCount;

		public void Draw(GraphTab tab, Sheet mg)
		{
			GraphProf.Begin(GraphProf.Total);
			DrawSheet(tab, mg);
			GraphProf.End(GraphProf.Total);
		}

		void DrawSheet(GraphTab tab, Sheet mg)
		{
			GraphProf.Begin(GraphProf.Prepare);
			DrawCount++;
			let graph = mg.Graph;
			// The code as read gets checked once (GraphValidator + the generator's checks), so its
			// problems show on the nodes before any edit.
			mApp.EnsureChecked(mg);
			mCommitted = false;
			mPendingArgNode = 0;
			mPendingAddPin = 0;
			mHasPendingDrop = false;

			if (graph.Serial != tab.LastGraphSerial)
			{
				tab.LastGraph = graph;
				tab.LastGraphSerial = graph.Serial;
				tab.CancelInteraction();
			}

			mFont = Gui.igGetFont();
			mFontSize = Gui.igGetFontSize();
			mMono = Host.th_get_mono_font();

			tab.CanvasOrigin = Gui.igGetCursorScreenPos();
			var avail = Gui.igGetContentRegionAvail();
			avail.x = Math.Max(avail.x, 1);
			avail.y = Math.Max(avail.y, 1);
			tab.CanvasSize = avail;
			let origin = tab.CanvasOrigin;
			var mouse = Gui.igGetMousePos();
			if (SelfTestMouse.x > -1e30f)
				mouse = SelfTestMouse; // a capture holds the pointer on a spot (the real pointer cannot be moved)

			// Re-select nodes after a regeneration; drop selections of nodes that are gone.
			if (!tab.ReselectKeys.IsEmpty)
			{
				KeyAssigner.Assign(graph);
				tab.ClearSelection();
				for (let key in tab.ReselectKeys)
				{
					for (let n in graph.Nodes)
						if (n.Key == key)
							tab.AddToSelection(n.Id);
					for (let gr in graph.Groups)
						if (gr.Key == key)
							tab.AddToSelection(gr.Id);
				}
				ClearAndDeleteItems!(tab.ReselectKeys);
			}
			// (A node group is selected by its negative id: GroupView.bf.)
			for (int i = tab.SelectedNodes.Count - 1; i >= 0; i--)
				if (graph.FindNode(tab.SelectedNodes[i]) == null && (tab.SelectedNodes[i] >= 0 || graph.FindGroup(tab.SelectedNodes[i]) == null))
					tab.SelectedNodes.RemoveAt(i);
			for (int i = tab.SelectedLinks.Count - 1; i >= 0; i--)
				if (graph.FindLink(tab.SelectedLinks[i]) == null)
					tab.SelectedLinks.RemoveAt(i);

			// Comment boxes and reroute knots of this graph (layout only, owned by the document).
			GatherComments(tab);
			ResolveReroutes(tab, graph);
			for (int i = tab.SelectedComments.Count - 1; i >= 0; i--)
				if (FindComment(tab.SelectedComments[i]) == null)
					tab.SelectedComments.RemoveAt(i);
			for (int i = tab.SelectedKnots.Count - 1; i >= 0; i--)
				if (FindKnot(tab.SelectedKnots[i]) == null)
					tab.SelectedKnots.RemoveAt(i);

			// The canvas item: gives ImGui an id, hover state and a drag-drop target. Widgets
			// drawn inside nodes later overlap it and win the hover.
			uint32 canvasId = Gui.igGetID_Str("##vbcanvas");
			Gui.igSetNextItemAllowOverlap();
			Gui.igInvisibleButton("##vbcanvas", avail, ButtonFlags.MouseButtonLeft | ButtonFlags.MouseButtonRight | ButtonFlags.MouseButtonMiddle);
			bool canvasHovered = Gui.igIsItemHovered(0);
			bool canvasActivated = Gui.igIsItemActivated();
			// Node hotkeys are plain letters: only while this Sheet has the keyboard (no text field active).
			mCanvasKeys = Gui.igIsWindowFocused(FocusedFlags.RootAndChildWindows) && (!Gui.igIsAnyItemActive() || Gui.igIsItemActive());
			if (canvasHovered)
				Gui.igSetItemKeyOwner_Nil(Key.MouseWheelY);
			HandleDragDrop(tab);
			// Keep keyboard navigation from also acting on the canvas shortcuts (Home would
			// otherwise move the nav cursor to the tab bar).
			if (Gui.igIsWindowFocused(FocusedFlags.RootAndChildWindows) && !Gui.igIsAnyItemActive())
			{
				Gui.igSetKeyOwner(Key.Home, canvasId, 0);
				Gui.igSetKeyOwner(Key.Delete, canvasId, 0);
				Gui.igSetKeyOwner(Key.Backspace, canvasId, 0);
			}

			bool mouseInCanvas = Canvas.RectContains(origin, origin + avail, mouse);
			bool windowHovered = Gui.igIsWindowHovered(HoveredFlags.ChildWindows | HoveredFlags.AllowWhenBlockedByActiveItem);

			// ---- Zoom (wheel, anchored on the cursor)
			if (mouseInCanvas && windowHovered)
			{
				let keyData = Gui.igGetKeyData_Key(Key.MouseWheelY);
				float wheel = (keyData != null) ? keyData.AnalogValue : 0;
				if (wheel > 0)
					tab.SetZoomLevel(tab.ZoomLevel + 1, mouse);
				else if (wheel < 0)
					tab.SetZoomLevel(tab.ZoomLevel - 1, mouse);
			}

			// ---- Continuous drags that move the view or nodes (before layout, so this frame shows them)
			UpdateDrag(tab, graph, mouse);
			tab.LastMouse = mouse;

			BuildLinked(graph);
			let frontEnd = mApp.FrontEnd;
			let generation = (frontEnd != null) ? frontEnd.Generation : 0;
			// Problems shown from an earlier Validate are drawn dimmed after an edit (ValidationState.bf).
			mProblemsDim = mApp.ProblemsStale;
			let shownKey = mApp.ValidateGeneration * 4 + (mProblemsDim ? 1 : 0) + (Prefs.ValidateAfterEdits ? 2 : 0);
			if (graph.Serial != mFanOutSerial || graph.Version != mFanOutVersion || generation != mFanOutGeneration || shownKey != mFanOutShown)
			{
				mFanOutSerial = graph.Serial;
				mFanOutVersion = graph.Version;
				mFanOutGeneration = generation;
				mFanOutShown = shownKey;
				// "evaluated Nx": the front end's counts after a Validate (kept, dimmed, after an edit); none before.
				mApp.ShownEvaluationCounts(graph, mFanOut);
			}
			mSelectedNow.Clear();
			for (let id in tab.SelectedNodes)
				mSelectedNow.Add(id);
			GraphProf.End(GraphProf.Prepare);
			// ---- Layout
			GraphProf.Begin(GraphProf.Diagnostics);
			for (let v in mNodeErrors.Values)
				delete v;
			mNodeErrors.Clear();
			for (let v in mNodeWarnings.Values)
				delete v;
			mNodeWarnings.Clear();
			// Graphs the code generator or GraphValidator refused (nothing was written): reasons on the nodes.
			for (let e in graph.Errors)
				if (!mNodeErrors.ContainsKey(e.NodeId))
					mNodeErrors[e.NodeId] = new String(e.Message);
			for (let e in graph.Warnings)
				if (!mNodeWarnings.ContainsKey(e.NodeId))
					mNodeWarnings[e.NodeId] = new String(e.Message);
			mApp.GetNodeDiagnostics(mg, mNodeErrors, mNodeWarnings);
			// The self test's long error (it outlives the checks each edit runs).
			if (SelfTestErrorNode != 0 && graph.FindNode(SelfTestErrorNode) != null)
			{
				if (mNodeErrors.TryGetValue(SelfTestErrorNode, let old))
					delete old;
				mNodeErrors[SelfTestErrorNode] = new String(SelfTestError);
			}
			// Math Expressions: pin types follow the wires, and what is wrong shows on the node
			// whether or not it is connected yet.
			for (let n in graph.Nodes)
			{
				if (n.Kind != .Math)
					continue;
				if (mNodeErrors.ContainsKey(n.Id))
					continue;
				String why = scope .();
				mApp.Language.Rules.CheckExpression(Treadle.Format.RecordText.Unquote(n.GetSetting("expr"), .. scope String()), why);
				if (!why.IsEmpty)
					mNodeErrors[n.Id] = new String(why);
			}
			GraphProf.End(GraphProf.Diagnostics);
			GraphProf.Begin(GraphProf.Layout);
			mLayById.Clear();
			mPins.Clear();
			mPinIndex.Clear();
			for (let node in graph.Nodes)
				LayoutNode(tab, graph, node, @node.Index);

			// Auto-layout used estimated sizes; now that every node is measured, redo it with
			// real sizes so nothing overlaps.
			if (graph.AutoLaidOut)
			{
				AutoLayout.Measured.Clear();
				for (let n in graph.Nodes)
				{
					let L = mLayById[n.Id];
					AutoLayout.Measured[n.Id] = (L.W, L.H);
				}
				AutoLayout.LayoutAll(graph);
				AutoLayout.Measured.Clear();
				graph.AutoLaidOut = false;
				tab.NeedsFocus = true;
				// (Not a user layout change: merely viewing a file must not write a side file.)
			}

			// First frame for this tab (or Home): bring the entry node into view at 1:1.
			if (tab.NeedsFocus && graph.Entry != null)
			{
				tab.ZoomLevel = Canvas.DefaultZoomLevel;
				tab.Pan = .(-graph.Entry.X + 60, -graph.Entry.Y + avail.y * 0.25f);
				tab.NeedsFocus = false;
			}
			tab.ApplyPendingCenter();
			tab.StepViewAnim();

			GraphProf.End(GraphProf.Layout);
			GraphProf.Begin(GraphProf.Visibility);
			// Folded node groups: their members hidden, one node each in their place (GroupView.bf).
			LayoutGroups(tab, graph);
			// Draw order: selected nodes on top.
			mOrder.Clear();
			for (int pass < 2)
			{
				for (let node in graph.Nodes)
				{
					let L = mLayById[node.Id];
					if (L.Selected == (pass == 1) && !L.Hidden)
						mOrder.Add(L);
				}
				for (let L in mGroupLays)
					if (L.Selected == (pass == 1))
						mOrder.Add(L);
			}
			float z = tab.Zoom;
			for (let L in mOrder)
			{
				let p0 = tab.GridToScreen(L.Node.X, L.Node.Y);
				var a = p0;
				var b = p0 + ImVec2(L.W, L.H) * z;
				if (L.StripH > 0)
				{
					b.x = Math.Max(b.x, p0.x + L.StripW * z);
					b.y = Math.Max(b.y, p0.y + (L.StripY + L.StripH) * z);
				}
				L.Visible = Canvas.RectsOverlap(a - .(20, 20), b + .(20, 20), origin, origin + avail);
			}

			GraphProf.End(GraphProf.Visibility);
			// ---- Hover (also while a variable from the Outline or the Node menu is dragged over the Sheet)
			GraphProf.Begin(GraphProf.Hover);
			bool memberDrag = mApp.ActiveDrag() != null;
			ComputeHover(tab, graph, mouse, mouseInCanvas && (canvasHovered || tab.Mode != .None || (memberDrag && windowHovered) || GraphProf.ForceHover));
			if (memberDrag && mApp.SelfTestDragPin != 0 && TryGetPin(mApp.SelfTestDragPin, let stPin))
			{
				// The dragvars self test shows a drag without the mouse: its pin is the one under the ghost.
				mHoverPin = stPin.Pin.Id;
				mApp.SelfTestDragOver(PinScreen(tab, stPin));
			}

			GraphProf.End(GraphProf.Hover);
			// ---- Draw
			let dl = Gui.igGetWindowDrawList();
			Gui.igPushClipRect(origin, origin + avail, true);
			Canvas.Background(dl, origin, avail, tab.Pan, z);
			DrawWatermark(tab, mg, dl);
			DrawComments(tab, dl);
			DrawGroupFrames(tab, graph, dl);
			GraphProf.Begin(GraphProf.Wires);
			DrawWires(tab, graph, dl, mouse);
			DrawKnots(tab, graph, dl);
			GraphProf.End(GraphProf.Wires);
			GraphProf.Begin(GraphProf.Nodes);
			DrawNodes(tab, graph, dl);
			GraphProf.End(GraphProf.Nodes);
			GraphProf.Begin(GraphProf.Overlays);
			DrawBubbles(tab, mg, graph, dl, mouse);
			DrawOverlay(tab, graph, dl, mouse);
			DrawDebugOverlay(tab, mg, dl); // breakpoints, the stopped node, values (DebugCanvas.bf)
			Gui.igPopClipRect();
			DrawNavToast(tab, dl);
			DrawNavButtons(tab, mg, graph);
			DrawBreadcrumbs(tab, mg);
			DrawFindBox(tab, graph);
			// Minimap in a child window so it sits above the nodes' inline widgets.
			if (Prefs.ShowMinimap)
				DrawMinimapWindow(tab, graph, mouse, mouseInCanvas);
			else
				mMinimapDrag = false;
			GraphProf.End(GraphProf.Overlays);

			if (mCommitted)
				return;
			GraphProf.Begin(GraphProf.Input);

			// ---- Mouse buttons, keyboard, context popups (graph mutations happen here)
			if (!mMinimapDrag && !(mNavOver && tab.Mode == .None))
				HandleMouse(tab, mg, mouse, canvasActivated, mouseInCanvas);
			if (mCommitted)
				return;
			HandleKeyboard(tab, mg);
			if (mCommitted)
				return;
			if (SelfTestGroupMenu != 0 && graph.FindGroup(SelfTestGroupMenu) != null)
			{
				mCtxGroup = SelfTestGroupMenu;
				Gui.OpenPopup("##vbgroupctx");
			}
			SelfTestGroupMenu = 0;
			if (SelfTestPinMenu != 0 && graph.FindPin(SelfTestPinMenu) != null)
			{
				// Captures: the pin menu opened as a right-click on the pin would.
				tab.CtxPin = SelfTestPinMenu;
				mApp.StructRowForPin(mg, graph.FindPin(SelfTestPinMenu), mCtxStructKey, mCtxStructLabel);
				Gui.OpenPopup("##vbpinctx");
			}
			SelfTestPinMenu = 0;
			DrawContextPopups(tab, mg);
			GraphProf.End(GraphProf.Input);
			if (mCommitted)
				return;

			if (mHasPendingDrop)
			{
				mHasPendingDrop = false;
				mApp.DropMember(tab, mPendingDrop, mPendingDropPos, mPendingDropPin);
				return;
			}

			if (mPendingArgNode != 0)
			{
				let n = graph.FindNode(Math.Abs(mPendingArgNode));
				int32 pending = mPendingArgNode;
				mPendingArgNode = 0;
				if (n != null)
				{
					if (pending > 0)
						mApp.AddArgument(n);
					else
						mApp.RemoveArgument(n);
					return;
				}
			}

			if (mPendingAddPin != 0)
			{
				let n = graph.FindNode(mPendingAddPin);
				mPendingAddPin = 0;
				if (n != null)
					mApp.AddExecPin(n);
			}
		}

		void UpdateDrag(GraphTab tab, Graph graph, ImVec2 mouse)
		{
			let delta = mouse - tab.LastMouse;
			switch (tab.Mode)
			{
			case .RightPending:
				let d = mouse - tab.PressPos;
				if (d.x * d.x + d.y * d.y > 16)
				{
					tab.Mode = .Pan;
					tab.Pan = tab.Pan + (mouse - tab.PressPos) * (1.0f / tab.Zoom);
				}
			case .Pan:
				tab.Pan = tab.Pan + delta * (1.0f / tab.Zoom);
				Gui.igSetMouseCursor(MouseCursor.ResizeAll);
			case .MoveNodes:
				let d = mouse - tab.PressPos;
				if (!tab.Moved && d.x * d.x + d.y * d.y < 9)
					break;
				if (!tab.Moved)
					mApp.BeginEdit(); // one undo step per drag
				tab.Moved = true;
				float dx = d.x / tab.Zoom;
				float dy = d.y / tab.Zoom;
				// One snapped offset for the whole selection: the grabbed item lands on the grid and every other item
				// keeps its distance to it, whatever its own position or size (nodes straightened with Q sit off the
				// grid, and snapping each one on its own moved some of them and left others behind).
				if (Prefs.GridSnap)
				{
					bool found = false;
					ImVec2 anchor = default;
					if (tab.DragStart.TryGetValue(tab.PressNode, let a))
					{
						anchor = a;
						found = true;
					}
					else if (tab.DragCommentStart.TryGetValue(tab.PressComment, let c))
					{
						anchor = c;
						found = true;
					}
					else
					{
						for (let kv in tab.DragStart)
						{
							anchor = kv.value;
							found = true;
							break;
						}
						if (!found)
							for (let kv in tab.DragCommentStart)
							{
								anchor = kv.value;
								found = true;
								break;
							}
					}
					if (found)
					{
						dx = Canvas.Snap(anchor.x + dx) - anchor.x;
						dy = Canvas.Snap(anchor.y + dy) - anchor.y;
					}
				}
				for (let kv in tab.DragStart)
				{
					let n = graph.FindNode(kv.key);
					if (n == null)
						continue;
					n.X = kv.value.x + dx;
					n.Y = kv.value.y + dy;
					n.HasPos = true;
				}
				for (let kv in tab.DragCommentStart)
				{
					let c = FindComment(kv.key);
					if (c == null)
						continue;
					c.X = kv.value.x + dx;
					c.Y = kv.value.y + dy;
				}
				for (let kv in tab.DragGroupStart)
				{
					let gr = graph.FindGroup(kv.key);
					if (gr == null)
						continue;
					gr.X = kv.value.x + dx;
					gr.Y = kv.value.y + dy;
				}
				for (let k in tab.DragKnotStart)
				{
					let route = FindKnot(k.knot);
					if (route == null)
						continue;
					var pt = ref route.Points[k.knot.Index];
					pt.X = k.start.x + dx;
					pt.Y = k.start.y + dy;
				}
			case .ResizeComment:
				let c = FindComment(tab.DragComment);
				if (c != null)
				{
					let d = mouse - tab.PressPos;
					if (!tab.Moved && d.x * d.x + d.y * d.y >= 9)
					{
						tab.Moved = true;
						mApp.BeginEdit(); // one undo step per resize
					}
					c.W = Math.Max(Canvas.Snap(tab.DragVec.x + d.x / tab.Zoom), 96);
					c.H = Math.Max(Canvas.Snap(tab.DragVec.y + d.y / tab.Zoom), CommentTitleH + 32);
				}
				Gui.igSetMouseCursor(8 /* ResizeNWSE */);
			default:
			}
		}

		void ComputeHover(GraphTab tab, Graph graph, ImVec2 mouse, bool enabled)
		{
			mHoverPin = 0;
			mHoverNode = 0;
			mHoverLink = 0;
			mHoverLinkSegment = 0;
			mHoverKnot = default;
			mHoverComment = 0;
			mHoverCommentResize = 0;
			mHoverGroupFrame = 0;
			if (!enabled)
				return;
			float z = tab.Zoom;
			float pinRadius = Math.Max(8, 9 * z);
			// Topmost first.
			for (int oi = mOrder.Count - 1; oi >= 0; oi--)
			{
				let L = mOrder[oi];
				if (!L.Visible)
					continue;
				let p0 = tab.GridToScreen(L.Node.X, L.Node.Y);
				let p1 = p0 + ImVec2(L.W, L.H) * z;
				if (!Canvas.RectContains(p0 - .(pinRadius, 0), p1 + .(pinRadius, 0), mouse))
					continue;
				// Pins (the circle with a generous radius, or the pin's label row)
				for (let n in L.Node.Inputs)
					if (HitPin(tab, n, mouse, pinRadius, p0, z))
						return;
				for (let n in L.Node.Outputs)
					if (HitPin(tab, n, mouse, pinRadius, p0, z))
						return;
				if (Canvas.RectContains(p0, p1, mouse))
				{
					mHoverNode = L.Node.Id;
					return;
				}
			}
			// Reroute knots
			float knotR = Math.Max(7, 8 * z);
			for (let route in mRoutes.Values)
			{
				for (let pt in route.Points)
				{
					let c = tab.GridToScreen(pt.X, pt.Y);
					let d = mouse - c;
					if (d.x * d.x + d.y * d.y <= knotR * knotR)
					{
						mHoverKnot = .(route.FromPinId, route.ToPinId, (int32)@pt.Index);
						return;
					}
				}
			}
			// Comment resize corners (topmost comment first)
			for (int ci = mComments.Count - 1; ci >= 0; ci--)
			{
				let c = mComments[ci];
				let p1 = tab.GridToScreen(c.X + c.W, c.Y + c.H);
				float hs = Math.Max(10, 16 * z);
				if (Canvas.RectContains(p1 - .(hs, hs), p1, mouse))
				{
					mHoverComment = c.Id;
					mHoverCommentResize = c.Id;
					return;
				}
			}
			// Wires
			float best = 6;
			ImVec2[64] pts = ?;
			for (let link in graph.Links)
			{
				if (!TryGetPin(link.From.Id, var a))
					continue;
				if (!TryGetPin(link.To.Id, var b))
					continue;
				// A wire inside a folded group is not drawn.
				if (a.Node.Hidden || b.Node.Hidden)
					continue;
				int count = WirePoints(tab, link, PinScreen(tab, a), PinScreen(tab, b), &pts[0], 64);
				for (int seg < count - 1)
				{
					float d = Canvas.DistToWire(mouse, pts[seg], pts[seg + 1], z);
					if (d < best)
					{
						best = d;
						mHoverLink = link.Id;
						mHoverLinkSegment = (int32)seg;
					}
				}
			}
			if (mHoverLink != 0)
				return;
			// The title bar of an unfolded node group.
			if (HitGroupFrame(tab, mouse))
				return;
			// Comment title bars
			for (int ci = mComments.Count - 1; ci >= 0; ci--)
			{
				let c = mComments[ci];
				let p0 = tab.GridToScreen(c.X, c.Y);
				let p1 = tab.GridToScreen(c.X + c.W, c.Y + CommentTitleH);
				if (Canvas.RectContains(p0, p1, mouse))
				{
					mHoverComment = c.Id;
					return;
				}
			}
		}

		bool HitPin(GraphTab tab, Pin p, ImVec2 mouse, float radius, ImVec2 nodePos, float z)
		{
			if (!TryGetPin(p.Id, let pl) || !pl.Visible)
				return false;
			let c = PinScreen(tab, pl);
			let d = mouse - c;
			if (d.x * d.x + d.y * d.y <= radius * radius)
			{
				mHoverPin = p.Id;
				return true;
			}
			if (pl.Node.Shape == .Getter)
				return false;
			float rowTop = nodePos.y + pl.RowY * z;
			float rowBot = rowTop + RowH * z;
			if (mouse.y < rowTop || mouse.y >= rowBot)
				return false;
			float x0;
			float x1;
			if (p.IsInput)
			{
				x0 = nodePos.x;
				x1 = nodePos.x + (pl.LabelX + pl.LabelW + 4) * z;
			}
			else
			{
				x0 = nodePos.x + (pl.LabelX - pl.LabelW - 4) * z;
				x1 = nodePos.x + pl.Node.W * z;
			}
			if (mouse.x >= x0 && mouse.x < x1)
			{
				mHoverPin = p.Id;
				return true;
			}
			return false;
		}

		void Text(ImDrawList* dl, ImVec2 pos, float size, uint32 col, StringView text, ImFont* font = null, float wrap = 0)
		{
			if (size < 3.5f || text.IsEmpty)
				return;
			Gui.ImDrawList_AddText_FontPtr(dl, (font != null) ? font : mFont, size, pos, col, text.Ptr, text.Ptr + text.Length, wrap, null);
		}

		uint32 WireColor(Pin from) => (from.Kind == .Flow) ? Theme.WireExec : Theme.PinColor(from);

		/// A value pin's hover text: its name, its type, the value typed into it (an unwired input) or,
		/// while the program is stopped in the debugger, the value it has now; then what ref / out /
		/// an unwired Receiver mean.
		public void PinTooltip(Graph graph, Pin p, String tip)
		{
			if (!p.Label.IsEmpty)
				tip.AppendF("{}\n", p.Label);
			if (p.TypeName.IsEmpty)
				tip.Append("(type unknown)");
			else if (PinStyle.LaneCount(p) > 0)
				Treadle.Model.VectorTypes.Describe(p.TypeName, tip); // float4 (4 x float, 16 bytes)
			else
				tip.Append(p.TypeName);
			String now = scope .();
			// Stopped: DebugPinValue gives the debugger's text for the value (TreadleDebug Summaries.bf),
			// the same text Locals, Evaluate and the pin bubbles show.
			bool stoppedHere = mApp.IsDebugStopped && mApp.CurrentMethod != null;
			if (stoppedHere && mApp.DebugPinValue(mApp.CurrentMethod, p, now))
				tip.AppendF("\nValue now: {}", now);
			else if (stoppedHere && !now.IsEmpty && (!p.IsInput || graph.IsLinked(p)))
				tip.AppendF("\nNo value now: {}", now);
			else if (p.IsInput && !graph.IsLinked(p) && !IsSelfTarget(graph, p))
			{
				// What the unwired input is given: its literal, else the type's default (false, 0, "").
				String value = scope .(p.Default);
				if (value.IsEmpty)
					PinDefaultValue(p, value);
				// As the inline field shows it: a float literal without its `f`.
				if (value.Length > 1 && value.EndsWith('f') && value[value.Length - 2].IsDigit)
					value.RemoveFromEnd(1);
				if (!value.IsEmpty && value != "default")
					tip.AppendF("\nValue: {}", value);
			}
			if (p.IsRefArg)
				tip.Append("\nref: passed by reference, wire a variable, field or element");
			else if (p.IsOutArg)
				tip.Append("\nout: a further output of the call");
			else if (IsSelfTarget(graph, p))
				tip.AppendF("\nNot connected: this{}", graph.StaticContext ? ", but this function is static" : "");
		}

		/// The pin under the pointer (0: none), as last computed.
		public int32 HoverPinId => mHoverPin;

		/// A wire of the pin under the pointer: drawn like a selected node's wires (brighter, thicker).
		public bool HoverPinWire(Link link) => mHoverPin != 0 && (link.From.Id == mHoverPin || link.To.Id == mHoverPin);

		void DrawWires(GraphTab tab, Graph graph, ImDrawList* dl, ImVec2 mouse)
		{
			float z = tab.Zoom;
			for (let link in graph.Links)
			{
				if (!TryGetPin(link.From.Id, var a))
					continue;
				if (!TryGetPin(link.To.Id, var b))
					continue;
				// Links being moved with Ctrl+drag are drawn to the mouse instead.
				if (tab.Mode == .Relink && tab.DragLinks.Contains(link.Id))
					continue;
				// A wire inside a folded group is not drawn (one crossing its edge ends on the group's node).
				if (a.Node.Hidden || b.Node.Hidden)
					continue;
				let from = PinScreen(tab, a);
				let to = PinScreen(tab, b);
				// A wire wholly outside the canvas costs nothing (a reroute node can pull it back in: those wires are kept).
				if (!mRoutes.ContainsKey(RouteKey(link.From.Id, link.To.Id)) && !Canvas.WireTouches(from, to, z, tab.CanvasOrigin, tab.CanvasOrigin + tab.CanvasSize, 16 * z + 8))
					continue;
				uint32 col = WireColor(link.From);
				float th = ((link.From.Kind == .Flow) ? 3.0f : 2.0f) * z;
				th = Math.Max(th, 1.0f);
				bool hot = a.Node.Selected || b.Node.Selected || HoverPinWire(link);
				if (!hot)
					col = Theme.WithAlpha(Theme.Mix(col, Gui.Color(0, 0, 0), 0.12f), 220);
				else
				{
					col = Theme.Lighten(col, 1.25f);
					th *= 1.35f;
				}
				if (tab.SelectedLinks.Contains(link.Id))
				{
					col = Theme.Mix(col, Theme.NodeSelected, 0.65f);
					th *= 1.3f;
				}
				if (link.Id == mHoverLink)
				{
					col = Theme.Lighten(Theme.WithAlpha(col, 255), 1.5f);
					th *= 1.5f;
				}
				ImVec2[64] pts = ?;
				int count = WirePoints(tab, link, from, to, &pts[0], 64);
				for (int seg < count - 1)
					Canvas.Wire(dl, pts[seg], pts[seg + 1], z, col, th);
			}
		}

		static int64 RouteKey(int32 fromPin, int32 toPin) => ((int64)fromPin << 32) | (int64)(uint32)toPin;

		/// The screen points a link passes through: its pins with any reroute knots in between.
		int WirePoints(GraphTab tab, Link link, ImVec2 from, ImVec2 to, ImVec2* outPts, int max)
		{
			int count = 0;
			outPts[count++] = from;
			if (mRoutes.TryGetValue(RouteKey(link.From.Id, link.To.Id), let route))
			{
				for (let pt in route.Points)
				{
					if (count >= max - 1)
						break;
					outPts[count++] = tab.GridToScreen(pt.X, pt.Y);
				}
			}
			outPts[count++] = to;
			return count;
		}

		/// The problem strip's text scale (of the node font) and height in grid units: one line.
		const float cStripScale = 0.85f;
		float StripH() => mFontSize * cStripScale + 6;

		/// The quick fix chips drawn this frame (node id and screen rectangle), for the click.
		List<BubbleHit> mFixHits = new .() ~ delete _;

		/// The problem strip of a node: a thin red (error) or amber (warning) band with its message in
		/// one line, shortened with "..."; hovering it shows the whole text. A quick fix is a "Fix" chip
		/// at its right end.
		void DrawProblemStrip(ImDrawList* dl, NodeLay L, ImVec2 p0, float z, bool details)
		{
			if (L.StripH <= 0)
				return;
			bool isError = L.Error != null;
			float fh = mFontSize;
			let s0 = ImVec2(p0.x + ((L.Shape == .Normal) ? 1 : 0), p0.y + L.StripY * z);
			let s1 = ImVec2(p0.x + L.StripW * z - ((L.Shape == .Normal) ? 1 : 0), s0.y + L.StripH * z);
			uint32 fill = ProblemColor(isError ? Theme.WithAlpha(Theme.ErrorHeader, 235) : Theme.WithAlpha(Theme.ProblemWarningFill, 235));
			uint32 ink = isError ? Gui.Color(255, 235, 235) : Gui.Color(30, 24, 4);
			// Stale (an edit since the last Validate): a faint band, its text in the problem's colour, dimmed.
			if (mProblemsDim)
				ink = isError ? Gui.Color(255, 170, 170, 190) : Gui.Color(240, 210, 120, 190);
			float r = (L.Shape == .Normal) ? 0 : 3 * z;
			Gui.ImDrawList_AddRectFilled(dl, s0, s1, fill, r, 0);
			if (L.Shape != .Normal)
				Gui.ImDrawList_AddRect(dl, s0, s1, ProblemColor(isError ? Theme.NodeError : Theme.Warning), r, 1, 0);
			if (!details)
				return;
			Text(dl, .(s0.x + 7 * z, s0.y + 3 * z), fh * cStripScale * z, ink, L.StripText);
			let mouse = Gui.igGetMousePos();
			bool overStrip = mouse.x >= s0.x && mouse.x <= s1.x && mouse.y >= s0.y && mouse.y <= s1.y;
			if (L.CanFix)
			{
				float cw = (Gui.CalcTextSize("Fix").x * cStripScale + 10) * z;
				let b0 = ImVec2(s1.x - cw - 3 * z, s0.y + 2 * z);
				let b1 = ImVec2(s1.x - 3 * z, s1.y - 2 * z);
				bool hot = mouse.x >= b0.x && mouse.x <= b1.x && mouse.y >= b0.y && mouse.y <= b1.y;
				Gui.ImDrawList_AddRectFilled(dl, b0, b1, hot ? Theme.WithAlpha(Theme.Good, 140) : Theme.WithAlpha(Theme.Good, 90), 3 * z, 0);
				Text(dl, .(b0.x + 5 * z, b0.y + 1 * z), fh * cStripScale * z, Gui.Color(235, 250, 230), "Fix");
				BubbleHit fh2 = default;
				fh2.Id = L.Node.Id;
				fh2.Min = b0;
				fh2.Max = b1;
				mFixHits.Add(fh2);
				if (hot)
				{
					Gui.Tooltip("Make local variable: a new Local holding the value, set in the flow right before this node, and its Get wired into the ref input (a ref input takes a variable, not a value).");
					overStrip = false;
				}
			}
			if (overStrip && mHoverPin == 0)
			{
				mStripHover = L.Node.Id; // the node tooltip waits its turn
				Gui.Tooltip(scope $"{isError ? "Error" : "Warning"}: {isError ? L.Error : L.Warning}{mProblemsDim ? "\n\nFrom the last Validate; the Sheet changed since: press Validate (Shift+F7)." : ""}");
			}
		}

		/// The node whose problem strip the mouse is over this frame (its own tooltip shows instead of the node's).
		int32 mStripHover;
		/// The self test: an error shown on node `SelfTestErrorNode` whatever the checks say (0: none).
		public int32 SelfTestErrorNode;
		public String SelfTestError = new .() ~ delete _;

		/// The problem strip node `nodeId` showed in the last frame (the self test): its one line, the
		/// line's width and the strip's width and height (grid units). False when it has none.
		public bool ProblemStripOf(int32 nodeId, String outText, out float textW, out float stripW, out float stripH)
		{
			textW = 0;
			stripW = 0;
			stripH = 0;
			if (!mLayById.TryGetValue(nodeId, let L) || L.Node == null || L.Node.Id != nodeId || L.StripH <= 0)
				return false;
			outText.Set(L.StripText);
			textW = Gui.CalcTextSize(L.StripText).x * cStripScale;
			stripW = L.StripW;
			stripH = L.StripH;
			return true;
		}

		/// Whether node `nodeId` drew its "+ arg" row in the last frame (the self test).
		public bool ShowsArgs(int32 nodeId) => mLayById.TryGetValue(nodeId, let L) && L.Node != null && L.Node.Id == nodeId && L.ShowArgs;

		/// Whether node `nodeId`'s problem strip offered the Fix chip in the last frame (the self test).
		public bool FixShown(int32 nodeId) => mLayById.TryGetValue(nodeId, let L) && L.Node != null && L.Node.Id == nodeId && L.CanFix;

		/// The height of a one-line problem strip (grid units).
		public float OneLineStripH => StripH();

		/// Alt+click on a pin: breaks every wire of `pin` (one undo step). False when it had none.
		public bool BreakPinLinks(Graph graph, Pin pin)
		{
			if (pin == null || !graph.IsLinked(pin))
				return false;
			mApp.BeginEdit();
			graph.DisconnectPin(pin);
			mApp.CommitCurrent();
			return true;
		}

		void DrawNodes(GraphTab tab, Graph graph, ImDrawList* dl)
		{
			mHoverExprPin = 0;
			mStripHover = 0;
			float z = tab.Zoom;
			bool widgets = z >= 0.45f;
			if (widgets)
			{
				// PushFont takes the size before the display scale (FontScaleDpi): without the division the
				// inline fields drew their text 125% too large at a 125% display and cut it off.
				Gui.igPushFont(mFont, MathFieldFont(z));
				Gui.igPushStyleVar_Vec2(StyleVar.FramePadding, .(4 * z, 3 * z));
				Gui.igPushStyleVar_Vec2(StyleVar.ItemSpacing, .(4 * z, 2 * z));
				Gui.igPushStyleVar_Vec2(StyleVar.ItemInnerSpacing, .(4 * z, 4 * z));
				Gui.igPushStyleVar_Float(StyleVar.FrameRounding, 3 * z);
				Gui.igPushStyleColor_U32(Col.FrameBg, Theme.InlineFieldBg);
			}
			mFixHits.Clear();
			for (let L in mOrder)
			{
				if (!L.Visible)
					continue;
				Gui.PushID(L.Node.Id);
				DrawNode(tab, graph, dl, L, widgets);
				if (L.Node.Disabled)
					DrawDisabled(tab, dl, L);
				else if (L.Faded && !L.Selected && mHoverNode != L.Node.Id)
					DrawFade(tab, dl, L);
				Gui.PopID();
			}
			if (widgets)
			{
				Gui.igPopStyleColor(1);
				Gui.igPopStyleVar(4);
				Gui.igPopFont();
			}
		}

		/// A disabled node (kept in the file, skipped when compiling): dimmed even when selected, with a
		/// "Disabled" band along its bottom edge.
		void DrawDisabled(GraphTab tab, ImDrawList* dl, NodeLay L)
		{
			float z = tab.Zoom;
			let p0 = tab.GridToScreen(L.Node.X, L.Node.Y);
			let p1 = p0 + ImVec2(L.W, L.H) * z;
			float r = (L.Shape == .Getter) ? Math.Max(1, L.H * z * 0.5f - 1) : 6 * z;
			Gui.ImDrawList_AddRectFilled(dl, p0, p1 + .(3 * z, 4 * z), Theme.WithAlpha(Theme.CanvasBg, L.Selected ? 110 : 150), r, 0);
			float fs = mFontSize * 0.8f * z;
			if (fs < 4)
				return;
			let tw = Gui.CalcTextSize(cDisabledLabel).x * (fs / mFontSize);
			let a = ImVec2(p0.x + (p1.x - p0.x - tw) * 0.5f - 6 * z, p1.y + 3 * z);
			let b = ImVec2(a.x + tw + 12 * z, a.y + fs + 4 * z);
			Gui.ImDrawList_AddRectFilled(dl, a, b, Theme.WithAlpha(Theme.CanvasBg, 230), 3 * z, 0);
			Gui.ImDrawList_AddRect(dl, a, b, Theme.WithAlpha(Theme.TextDim, 160), 3 * z, 1, 0);
			Text(dl, .(a.x + 6 * z, a.y + 2 * z), fs, Theme.TextDim, cDisabledLabel);
		}
		const String cDisabledLabel = "Disabled";

		/// Reduced opacity for a node that is not wired into the flow: the canvas colour laid over it, and a thin warm edge.
		void DrawFade(GraphTab tab, ImDrawList* dl, NodeLay L)
		{
			float z = tab.Zoom;
			let p0 = tab.GridToScreen(L.Node.X, L.Node.Y);
			let p1 = p0 + ImVec2(L.W, L.H) * z;
			float r = (L.Shape == .Getter) ? Math.Max(1, L.H * z * 0.5f - 1) : 6 * z;
			Gui.ImDrawList_AddRectFilled(dl, p0, p1 + .(3 * z, 4 * z), Theme.WithAlpha(Theme.CanvasBg, 135), r, 0);
			Gui.ImDrawList_AddRect(dl, p0, p1, Theme.WithAlpha(Theme.Warning, 70), r, 1, 0);
		}

		/// The self test: node `SelfTestHeaderNode`'s header as drawn in the last frame (screen pixels): the
		/// transparent outer edge of its mesh, the node's rectangle, the header's lower right
		/// corner and its corner radius. 0: none recorded.
		public int32 SelfTestHeaderNode;
		public List<ImVec2> SelfTestHeader = new .() ~ delete _;
		public ImVec2 SelfTestNodeMin;
		public ImVec2 SelfTestNodeMax;
		public ImVec2 SelfTestHeaderMax;
		public float SelfTestHeaderR;
		/// The self test: node `SelfTestStripeNode`'s Unsafe hatch as drawn in the last frame (screen pixels):
		/// every vertex of its clipped strips, the band's rectangle and the corner radius. 0: none recorded.
		public int32 SelfTestStripeNode;
		public List<ImVec2> SelfTestStripe = new .() ~ delete _;
		public ImVec2 SelfTestStripeMin;
		public ImVec2 SelfTestStripeMax;
		public float SelfTestStripeR;

		/// The colour a node header fades to at its right edge: the body colour laid over the header at 235 / 255.
		static uint32 HeaderFadeEnd(uint32 header) => Theme.WithAlpha(Theme.Mix(header, Theme.NodeBody, 235 / 255.0f), 255);

		void DrawNode(GraphTab tab, Graph graph, ImDrawList* dl, NodeLay L, bool widgets)
		{
			let node = L.Node;
			float z = tab.Zoom;
			float fh = mFontSize;
			let p0 = tab.GridToScreen(node.X, node.Y);
			let p1 = p0 + ImVec2(L.W, L.H) * z;
			// A pill is as round as its height allows, less the pixel the draw list's own rounding keeps back, so the
			// body, the tint and the outline all use the same radius and meet exactly.
			float r = (L.Shape == .Getter) ? Math.Max(1, L.H * z * 0.5f - 1) : 6 * z;
			bool hovered = mHoverNode == node.Id;

			// Soft drop shadow + body
			Gui.ImDrawList_AddRectFilled(dl, p0 + .(1 * z, 2 * z), p1 + .(6 * z, 8 * z), Gui.Color(0, 0, 0, 35), r + 4 * z, 0);
			Gui.ImDrawList_AddRectFilled(dl, p0 + .(2 * z, 3 * z), p1 + .(3 * z, 4 * z), Theme.NodeShadow, r, 0);
			Gui.ImDrawList_AddRectFilled(dl, p0, p1, Theme.NodeBody, r, 0);

			uint32 header = L.Header;
			if (L.Shape == .Normal)
			{
				// Header: solid on the left, fading into the body on the right, as ONE mesh (bottom corners square).
				// Pieced from rects, every join is a vertical seam line that shimmers while zooming: a solid cap and a
				// gradient quad left one at x = p0.x + r, and the fade quad with a rounded top-right cap (its
				// anti-aliased left edge let the header colour through) left one at x = p1.x - r.
				float hh = L.HeaderH * z;
				bool record = node.Id == SelfTestHeaderNode;
				if (record)
				{
					SelfTestHeader.Clear();
					Canvas.SelfTestFringe = SelfTestHeader;
				}
				Canvas.FillRoundedGradient(dl, p0, .(p1.x, p0.y + hh), r, header, HeaderFadeEnd(header), true);
				if (record)
				{
					Canvas.SelfTestFringe = null;
					SelfTestNodeMin = p0;
					SelfTestNodeMax = p1;
					SelfTestHeaderMax = .(p1.x, p0.y + hh);
					SelfTestHeaderR = r;
				}
				Gui.ImDrawList_AddLine(dl, .(p0.x + 1, p0.y + hh), .(p1.x - 1, p0.y + hh), Gui.Color(0, 0, 0, 120), Math.Max(1, z));
				// UE: a small kind icon left of the title.
				float iconW = HeaderIconW(node);
				if (iconW > 0)
					Text(dl, .(p0.x + 8 * z, p0.y + 5 * z), fh * z, Theme.WithAlpha(Theme.NodeTitle, 225), PinStyle.HeaderIcon(node));
				Text(dl, .(p0.x + (10 + iconW) * z, p0.y + 5 * z), fh * z, Theme.NodeTitle, L.Title);
				if (!L.Subtitle.IsEmpty)
					Text(dl, .(p0.x + (10 + iconW) * z, p0.y + (5 + fh + 1) * z), fh * 0.85f * z, Theme.NodeSubtitle, L.Subtitle);
			}
			else if (L.Shape == .Getter)
			{
				uint32 pc = (node.Result != null) ? Theme.PinColor(node.Result) : Theme.WildPin;
				// A faint tint in the value's colour, strongest at the left end and fading to the right: one mesh
				// over the whole pill, so there is no seam where an end cap would meet a gradient.
				Canvas.FillRoundedGradient(dl, p0, p1, r, Theme.WithAlpha(pc, 55), Theme.WithAlpha(pc, 0));
				Text(dl, .(p0.x + L.TitleX * z, p0.y + (L.H - fh) * 0.5f * z), fh * z, Gui.Color(235, 235, 235), L.Title);
			}
			else if (L.Shape == .Operator)
			{
				float ss = L.SymbolSize * z;
				float tw = Gui.CalcTextSize(L.Title).x * L.SymbolScale * z;
				if (node.Kind != .Operator)
				{
					// Compact pure call: a faint green wash in the pure-call colour, one mesh over the whole node.
					Canvas.FillRoundedGradient(dl, p0, p1, r, Theme.WithAlpha(Theme.HeaderPure, 70), Theme.WithAlpha(Theme.HeaderPure, 0));
				}
				if (node.Kind == .Operator && (L.Title == "+" || L.Title == "-"))
				{
					// + and - as strokes: the UI font's glyphs are small and thin at symbol size and sit low in
					// their box, so the node showed a tiny mark off its middle
					let c = ImVec2(Math.Round((p0.x + p1.x) * 0.5f), Math.Round((p0.y + p1.y) * 0.5f));
					float arm = Math.Max(3, ss * 0.3f);
					float th = Math.Max(1.5f, ss * 0.09f);
					let col = Gui.Color(215, 215, 215);
					Gui.ImDrawList_AddLine(dl, .(c.x - arm, c.y), .(c.x + arm, c.y), col, th);
					if (L.Title == "+")
						Gui.ImDrawList_AddLine(dl, .(c.x, c.y - arm), .(c.x, c.y + arm), col, th);
					mSymbolArm[node.Id] = arm / Math.Max(z, 0.01f);
				}
				else
					Text(dl, .((p0.x + p1.x) * 0.5f - tw * 0.5f, (p0.y + p1.y) * 0.5f - ss * 0.5f), ss, Gui.Color(215, 215, 215), L.Title);
			}

			// Unsafe: a hatched stripe along the top edge (pointer nodes, an Unsafe Scope), clipped to the header's
			// rounded outline so it runs into the corners; under the outlines, the Disabled dimming over it.
			if (L.Unsafe && L.Shape == .Normal)
			{
				bool record = node.Id == SelfTestStripeNode;
				if (record)
				{
					SelfTestStripe.Clear();
					SelfTestStripeMin = p0;
					SelfTestStripeMax = .(p1.x, p0.y + Math.Min(L.HeaderH, 6) * z);
					SelfTestStripeR = r;
				}
				Canvas.HatchRoundedTop(dl, p0, .(p1.x, p0.y + L.HeaderH * z), r, Math.Min(L.HeaderH, 6) * z, 7 * z, Math.Max(1, 1.5f * z),
					Theme.WithAlpha(Theme.Warning, 200), record ? SelfTestStripe : null);
			}

			// Outline
			if (L.Error != null)
				Gui.ImDrawList_AddRect(dl, p0, p1, ProblemColor(Theme.NodeError), r, Math.Max(1.5f, 2 * z), 0);
			else if (L.Warning != null)
				Gui.ImDrawList_AddRect(dl, p0, p1, ProblemColor(Theme.WithAlpha(Theme.Warning, 200)), r, Math.Max(1.2f, 1.5f * z), 0);
			else
				Gui.ImDrawList_AddRect(dl, p0, p1, hovered ? Gui.Color(90, 90, 90, 220) : Theme.NodeOutline, r, 1, 0);
			if (L.Selected)
			{
				float o = 1.5f * z;
				Gui.ImDrawList_AddRect(dl, p0 - .(o, o), p1 + .(o, o), Theme.NodeSelected, r + o, Math.Max(1.5f, 2.5f * z), 0);
			}
			// A value node read by several flow nodes runs once for each (Language.md 5.2): "evaluated Nx".
			if (L.Evaluated >= 2)
			{
				String badge = scope $"evaluated {L.Evaluated}x";
				float bs = fh * 0.8f * z;
				// Measured at the size it is drawn (the text is drawn at `bs` pixels whatever font is pushed).
				float bw = Gui.CalcTextSize(badge).x * (bs / Math.Max(Gui.igGetFontSize(), 1.0f)) + 10 * z;
				let b0 = ImVec2(p1.x - bw, p0.y - bs - 6 * z);
				let b1 = ImVec2(p1.x, p0.y - 2 * z);
				Gui.ImDrawList_AddRectFilled(dl, b0, b1, ProblemColor(Gui.Color(60, 48, 10, 230)), 4 * z, 0);
				Gui.ImDrawList_AddRect(dl, b0, b1, ProblemColor(Theme.WithAlpha(Theme.Warning, 180)), 4 * z, 1, 0);
				Text(dl, .(b0.x + 5 * z, b0.y + 2 * z), bs, mProblemsDim ? Gui.Color(250, 220, 130, 150) : Gui.Color(250, 220, 130), badge);
			}
			// A Lambda that captures: "captures N" (the list is in Properties).
			if (node.Kind == .Lambda && L.Shape == .Normal && L.Evaluated < 2)
			{
				let res = mApp.LambdaResult(tab.Doc?.FindSheet(tab.MethodKey), node);
				let count = (res != null) ? res.Captures.Count : 0;
				if (count > 0)
				{
					String badge = scope $"captures {count}";
					float bs = fh * 0.8f * z;
					float bw = Gui.CalcTextSize(badge).x * (bs / Math.Max(Gui.igGetFontSize(), 1.0f)) + 10 * z;
					let b0 = ImVec2(p1.x - bw, p0.y - bs - 6 * z);
					let b1 = ImVec2(p1.x, p0.y - 2 * z);
					Gui.ImDrawList_AddRectFilled(dl, b0, b1, Theme.WithAlpha(Look.AccentBlue, 40), 4 * z, 0);
					Gui.ImDrawList_AddRect(dl, b0, b1, Theme.WithAlpha(Look.AccentBlue, 190), 4 * z, 1, 0);
					Text(dl, .(b0.x + 5 * z, b0.y + 2 * z), bs, Look.Foreground, badge);
				}
			}
			if (L.Shape == .Normal) DrawLivesInBadge(node, dl, p0, p1, fh, z); // "lives in heap / region": LivesIn.bf
			// Collapsed: unwired pins are hidden; a small mark says there is more.
			if (L.Collapsed && L.Shape == .Normal)
				Text(dl, .(p1.x - 18 * z, p0.y + 5 * z), fh * z, Theme.WithAlpha(Theme.NodeTitle, 160), Icon.ChevronDown);

			// Pins
			bool details = z >= 0.3f;
			for (let p in node.Inputs)
				DrawPin(tab, graph, dl, node, p, p0, details, widgets);
			for (let p in node.Outputs)
				DrawPin(tab, graph, dl, node, p, p0, details, widgets);

			// Code body
			if (!L.CodeLines.IsEmpty && details)
			{
				let b0 = ImVec2(p0.x + 6 * z, p0.y + L.CodeY * z);
				let b1 = ImVec2(p1.x - 6 * z, p0.y + (L.CodeY + L.CodeH) * z);
				Gui.ImDrawList_AddRectFilled(dl, b0, b1, Gui.Color(0, 0, 0, 90), 3 * z, 0);
				float y = L.CodeY + 4;
				for (let line in L.CodeLines)
				{
					Text(dl, .(p0.x + 12 * z, p0.y + y * z), fh * z, (@line.Index == 14) ? Theme.TextDim : Theme.TextCode, line, mMono);
					y += fh;
				}
			}

			if (L.MathField && details)
				DrawMathField(graph, dl, node, L, p0, z, widgets);

			// "+ arg" / "- arg"
			if (L.ShowArgs && widgets)
			{
				Gui.igSetCursorScreenPos(.(p0.x + 10 * z, p0.y + L.ArgsY * z));
				if (Gui.SmallButton("+ arg"))
					mPendingArgNode = node.Id;
				if (((node.Kind == .Call) ? NodeFactory.VarArgCount(node) : node.ArgCount) > 0)
				{
					Gui.SameLine();
					if (Gui.SmallButton("- arg"))
						mPendingArgNode = -node.Id;
				}
			}

			// "Add pin +" at the bottom right, under the outputs it adds to.
			if (L.ShowAddPin && widgets)
			{
				let label = cAddPinLabel;
				float bw = Gui.CalcTextSize(label).x + 8 * z;
				Gui.igSetCursorScreenPos(.(p0.x + L.W * z - bw - 12 * z, p0.y + L.AddPinY * z));
				Gui.igPushStyleColor_U32(Col.Button, Theme.WithAlpha(Theme.InlineFieldBg, 0));
				Gui.igPushStyleColor_U32(Col.Text, Theme.TextDim);
				if (Gui.SmallButton(label))
					mPendingAddPin = node.Id;
				Gui.igPopStyleColor(2);
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip((node.Kind == .Switch) ? "Add a case output" : "Add an output (it runs after the others)");
			}
			else if (L.ShowAddPin && details)
				Text(dl, .(p0.x + L.W * z - Gui.CalcTextSize(cAddPinLabel).x * z - 16 * z, p0.y + (L.AddPinY + 2) * z), mFontSize * z, Theme.TextDim, cAddPinLabel);

			if (L.Orphan && details && Prefs.VerboseNodeWarnings)
				Text(dl, .(p0.x + 10 * z, p0.y + L.OrphanY * z), fh * 0.85f * z, Theme.Warning, "Not connected: no code yet");

			// The problem strip (under the header, or under a headerless body).
			DrawProblemStrip(dl, L, p0, z, details);
		}

		void DrawPin(GraphTab tab, Graph graph, ImDrawList* dl, Node node, Pin p, ImVec2 nodePos, bool details, bool widgets)
		{
			if (!TryGetPin(p.Id, let pl) || !pl.Visible)
				return;
			float z = tab.Zoom;
			float fh = mFontSize;
			let c = PinScreen(tab, pl);
			bool linked = Linked(p);
			bool hovered = mHoverPin == p.Id;
			uint32 col = Theme.PinColor(p);
			uint32 col2 = (p.Kind == .Flow) ? col : Theme.ValueColor(p.TypeName);
			bool badTarget = pl.Node.TargetBad && p.Name == "receiver" && p.IsInput;
			if (badTarget)
			{
				col = Theme.NodeError;
				col2 = col;
			}
			if (hovered)
			{
				col = Theme.Lighten(col, 1.35f);
				col2 = Theme.Lighten(col2, 1.35f);
			}
			float th = Math.Max(1.0f, 1.6f * z);
			if (p.Kind == .Flow)
				Canvas.ExecPin(dl, c, 6 * z, col, linked, th);
			else
			{
				float rr = 5 * z;
				float arrowX = p.IsInput ? (c.x - rr - 4 * z) : (c.x + rr + 4 * z);
				PinStyle.DrawData(dl, PinStyle.ShapeFor(p), c, rr, col, col2, linked, arrowX, th, PinStyle.LaneCount(p));
			}
			if (hovered)
				Gui.ImDrawList_AddCircle(dl, c, 9 * z, Theme.WithAlpha(col, 90), 0, Math.Max(1, z));
			// A problem about this pin (ILanguageRules or the graph checks named it): a ring in the
			// problem's colour and a small badge beside the pin; the text is in the node's badge.
			let pinProblem = graph.FindPinProblem(p, let pinIsError);
			if (pinProblem != null)
			{
				uint32 pc = ProblemColor(pinIsError ? Theme.NodeError : Theme.Warning);
				Gui.ImDrawList_AddCircle(dl, c, 8.5f * z, pc, 0, Math.Max(1.5f, 2 * z));
				let bc = ImVec2(c.x + (p.IsInput ? -13 : 13) * z, c.y - 9 * z);
				Gui.ImDrawList_AddCircleFilled(dl, bc, 5.5f * z, pc, 0);
				if (details)
					Text(dl, .(bc.x - 2 * z, bc.y - 6 * z), 11 * z, Gui.Color(20, 20, 20), "!");
			}

			if (!details || pl.Node.Shape == .Getter)
				return;
			float rowTop = nodePos.y + pl.RowY * z;
			uint32 labelCol = hovered ? Gui.Color(255, 255, 255) : (badTarget ? Gui.Color(255, 120, 120) : Theme.PinLabel);
			if (pinProblem != null && !hovered)
				labelCol = pinIsError ? Gui.Color(255, 120, 120) : Gui.Color(240, 210, 120);
			if (pl.LabelW > 0)
			{
				float ty = rowTop + (RowH - fh) * 0.5f * z;
				if (p.IsInput)
					Text(dl, .(nodePos.x + pl.LabelX * z, ty), fh * z, labelCol, pl.LabelText);
				else
					Text(dl, .(nodePos.x + (pl.LabelX - pl.LabelW) * z, ty), fh * z, labelCol, pl.LabelText);
			}
			if (pl.SelfHint)
			{
				float ty = rowTop + (RowH - fh) * 0.5f * z;
				Text(dl, .(nodePos.x + pl.FieldX * z, ty), fh * z, badTarget ? Gui.Color(255, 120, 120) : Theme.TextDim, "this");
			}
			if (pl.FieldW > 0)
			{
				let fpos = ImVec2(nodePos.x + pl.FieldX * z, rowTop + 2 * z);
				if (pl.VKind == .None)
					Text(dl, fpos + ImVec2(2 * z, 3 * z), fh * z, Theme.TextDim, p.Default);
				else if (pl.VKind == .Custom)
				{
					// Not a plain literal of the pin's type (an expression): read-only, edited in Properties.
					// Widths are measured at the size drawn (fh * z) whatever font size is pushed, so the
					// value never runs under the badge.
					let f1 = fpos + ImVec2(pl.FieldW * z, (fh + 6) * z);
					Gui.ImDrawList_AddRectFilled(dl, fpos, f1, Theme.InlineFieldBg, 3 * z, 0);
					float drawScale = (fh * z) / Math.Max(Gui.igGetFontSize(), 1.0f);
					float bw = Gui.CalcTextSize(cExpressionBadge).x * drawScale;
					float bx = f1.x - bw - 4 * z;
					String shown = scope .();
					Ellipsize(p.Default, bx - (fpos.x + 4 * z) - 6 * z, drawScale, shown);
					Text(dl, fpos + ImVec2(4 * z, 3 * z), fh * z, Gui.Color(200, 200, 200), shown);
					Text(dl, ImVec2(bx, fpos.y + 3 * z), fh * z, Theme.Warning, cExpressionBadge);
					let mouse = Gui.igGetMousePos();
					if (mouse.x >= fpos.x && mouse.x <= f1.x && mouse.y >= fpos.y && mouse.y <= f1.y)
						mHoverExprPin = p.Id;
				}
				else if (widgets && PinValueEditor.Handles(pl.VKind) && !pl.Check)
				{
					mPinEditor.ButtonColor = Theme.InlineFieldBg;
					Gui.igSetCursorScreenPos(fpos);
					if (mPinEditor.Draw(mApp, node, p, pl.VKind, pl.FieldW * z))
					{
						// A typed value can choose another overload (`$"..."` stays a text; a typed text
						// into an Object pin is shown by the text overload).
						mApp.RefitCall(graph, node);
						mApp.CommitCurrent();
						mCommitted = true;
					}
				}
				else if (widgets)
					DrawInlineValue(node, p, fpos, pl.FieldW * z, pl.Check);
				else
				{
					// Too small for live widgets: draw the value like UE's low-detail mode.
					let f1 = fpos + ImVec2(pl.FieldW * z, (fh + 6) * z);
					Gui.ImDrawList_AddRectFilled(dl, fpos, f1, Theme.InlineFieldBg, 3 * z, 0);
					Text(dl, fpos + ImVec2(4 * z, 3 * z), fh * z, Gui.Color(200, 200, 200), p.Default);
				}
			}
		}

		/// The badge of a pin value that is not a plain literal of the pin's type (PinValueKind.Custom).
		public const String cExpressionBadge = "Expression";
		public const String cExpressionTip = "Not a plain value of this pin's type (a name, a call, an interpolated or verbatim string, ...), so it is kept as written. Edit it in Properties > Inputs.";
		/// The longest an expression value is drawn on the node (grid units); longer ones end in "...".
		const float cExpressionValueMaxW = 220;
		/// The pin whose expression field the mouse is over this frame (its tooltip explains the badge).
		int32 mHoverExprPin;

		/// `text` (its first line) shortened with "..." to fit `maxW` screen units, measured with the
		/// current font scaled by `scale`.
		public static void Ellipsize(StringView text, float maxW, float scale, String outText)
		{
			var t = text;
			bool cut = false;
			let nl = t.IndexOf('\n');
			if (nl >= 0)
			{
				t = t.Substring(0, nl);
				cut = true;
			}
			if (t.Length > 240)
			{
				t = t.Substring(0, 240);
				cut = true;
			}
			if (!cut && Gui.CalcTextSize(t).x * scale <= maxW)
			{
				outText.Append(t);
				return;
			}
			const String cDots = "...";
			float dotsW = Gui.CalcTextSize(cDots).x * scale;
			int len = t.Length;
			while (len > 0 && Gui.CalcTextSize(t.Substring(0, len)).x * scale + dotsW > maxW)
			{
				len--;
				while (len > 0 && ((uint8)t[len] & 0xC0) == 0x80)
					len--;
			}
			outText.Append(t.Substring(0, len));
			outText.Append(cDots);
		}

		/// The Math Expression being typed on a node (0: none) and what is typed; a refused one
		/// keeps its frame red for a moment.
		int32 mMathEditNode;
		String mMathEditText = new .() ~ delete _;
		int32 mMathRejectNode;
		int32 mMathRejectFrames;
		/// Self test: the last expression refused on a node, and how many were.
		public String MathRefusal = new .() ~ delete _;
		public int MathRefusals;

		/// Self test: the node's field looks as if `text` were being typed into it.
		public void SelfTestMathType(int32 nodeId, StringView text)
		{
			mMathEditNode = nodeId;
			mMathEditText.Set(text);
		}

		/// The input pins were changed for what is being typed (one undo step from the first change).
		bool mMathPinsEdited;

		/// The expression a Math Expression node holds: `set expr` (its text when the setting is
		/// missing, as the compiler reads it).
		public static void MathText(Node node, String outText)
		{
			let s = node.GetSetting("expr");
			if (!s.IsEmpty)
				Treadle.Format.RecordText.Unquote(s, outText);
			else
				outText.Append(node.Text);
		}

		/// One value input per name `text` reads, in order of first use: a name that stays keeps
		/// its pin and its wire, a new name gets a pin, a pin whose name is gone goes with its wire.
		/// Nothing changes when the text does not parse. True when a pin was added, removed or moved.
		public bool SyncMathPins(Graph graph, Node node, StringView text)
		{
			List<String> names = scope .();
			defer { ClearAndDeleteItems!(names); }
			if (!Treadle.Compiler.MathExpr.Parse(text, names, scope String()))
				return false;
			bool changed = false;
			for (int i = node.Inputs.Count - 1; i >= 0; i--)
			{
				let p = node.Inputs[i];
				if (p.Kind != .Value)
					continue;
				bool keep = false;
				for (let n in names)
					if (n == p.Name)
						keep = true;
				if (!keep)
				{
					graph.RemovePin(p);
					changed = true;
				}
			}
			for (let n in names)
				if (node.FindInput(n) == null)
				{
					graph.AddDataIn(node, n, n);
					changed = true;
				}
			// value inputs in the order the expression names them
			List<Pin> values = scope .();
			for (let n in names)
				values.Add(node.FindInput(n));
			int k = 0;
			for (int i < node.Inputs.Count)
			{
				if (node.Inputs[i].Kind != .Value)
					continue;
				if (node.Inputs[i] != values[k])
				{
					node.Inputs[i] = values[k];
					changed = true;
				}
				k++;
			}
			if (changed)
				graph.Version++;
			return changed;
		}

		/// What is typed in a Math Expression's field: while it parses, the inputs follow it (one
		/// undo step from the first change); `final` (Enter, focus left) stores it in `set expr`, or
		/// refuses it (the inputs go back to the stored expression). False when refused.
		public bool ApplyMathText(Graph graph, Node node, StringView typed, bool final)
		{
			String current = scope .();
			MathText(node, current);
			if (!final)
			{
				if (!mApp.Language.Rules.CheckExpression(typed, null))
					return true;
				if (!mMathPinsEdited)
				{
					// only an edit that changes pins opens the undo step
					List<String> names = scope .();
					defer { ClearAndDeleteItems!(names); }
					Treadle.Compiler.MathExpr.Parse(typed, names, scope String());
					int values = 0;
					for (let p in node.Inputs)
						if (p.Kind == .Value)
							values++;
					bool differs = names.Count != values;
					for (let n in names)
						if (node.FindInput(n) == null)
							differs = true;
					if (!differs)
						return true;
					mApp.BeginEdit();
					mMathPinsEdited = true;
				}
				SyncMathPins(graph, node, typed);
				return true;
			}
			let edited = mMathPinsEdited;
			mMathPinsEdited = false;
			String why = scope .();
			if (typed == current || !mApp.Language.Rules.CheckExpression(typed, why))
			{
				if (edited)
				{
					SyncMathPins(graph, node, current);
					mApp.CommitCurrent();
					mCommitted = true;
				}
				if (typed == current)
					return true;
				mMathRejectNode = node.Id;
				mMathRejectFrames = 120;
				MathRefusal.Set(why);
				MathRefusals++;
				Notify.Warn(why);
				return false;
			}
			if (!edited)
				mApp.BeginEdit();
			node.SetSetting("expr", Treadle.Format.RecordText.Quote(typed, .. scope String()));
			SyncMathPins(graph, node, typed);
			mApp.CommitCurrent();
			mCommitted = true;
			return true;
		}

		/// The font size of the expression field at zoom `z`: the node's text size (widgets get the
		/// UI scale on top of the size they are given, the node's drawn text does not).
		float MathFieldFont(float z) => mFontSize * z / Math.Max(Look.Scale, 0.5f);

		/// The expression field in a Math Expression's body: typed here or in Properties. While
		/// the language refuses what is typed the frame is red, and it is not taken.
		void DrawMathField(Graph graph, ImDrawList* dl, Node node, NodeLay L, ImVec2 p0, float z, bool widgets)
		{
			float fh = mFontSize;
			let f0 = ImVec2(p0.x + 8 * z, p0.y + L.CodeY * z);
			float w = (L.W - 16) * z;
			let f1 = ImVec2(f0.x + w, f0.y + (fh + 6) * z);
			bool mine = mMathEditNode == node.Id;
			bool bad = false;
			if (mine)
				bad = !mApp.Language.Rules.CheckExpression(mMathEditText, scope String());
			if (widgets)
			{
				Gui.igSetCursorScreenPos(f0);
				Gui.PushID(node.Id);
				if (mine)
					mScratch.Set(mMathEditText);
				else
					mScratch.Set(MathText(node, .. scope String()));
				Gui.igSetNextItemWidth(w);
				if (mMono != null)
					Gui.igPushFont(mMono, MathFieldFont(z));
				bool changed = Gui.igInputTextWithHint("##mx", "a * b + 1", mScratch.Ptr, (.)mScratch.Capacity, 0, null, null);
				if (mMono != null)
					Gui.igPopFont();
				if (changed)
				{
					mMathEditNode = node.Id;
					mMathEditText.Set(mScratch.View);
					// the inputs follow the names as they are typed
					var typing = StringView(mMathEditText);
					typing.Trim();
					ApplyMathText(graph, node, typing, false);
				}
				if (Gui.igIsItemDeactivated() && mMathEditNode == node.Id)
				{
					var typed = StringView(mMathEditText);
					typed.Trim();
					ApplyMathText(graph, node, typed, true);
					mMathEditNode = 0;
				}
				if (Gui.igIsItemHovered(0) && !Gui.igIsItemActive())
					Gui.Tooltip("The expression: every name in it is an input. Press Enter or click away to apply it.");
				Gui.PopID();
			}
			else
			{
				Gui.ImDrawList_AddRectFilled(dl, f0, f1, Theme.InlineFieldBg, 3 * z, 0);
				Text(dl, f0 + ImVec2(4 * z, 3 * z), fh * z, Theme.TextCode, MathText(node, .. scope String()), mMono);
			}
			if (bad || (mMathRejectNode == node.Id && mMathRejectFrames > 0))
			{
				if (!bad)
					mMathRejectFrames--;
				Gui.ImDrawList_AddRect(dl, f0 - .(1, 1), f1 + .(1, 1), Theme.NodeError, 3 * z, Math.Max(1.5f, 1.5f * z), 0);
			}
		}

		void DrawInlineValue(Node node, Pin p, ImVec2 pos, float width, bool check)
		{
			Gui.igSetCursorScreenPos(pos);
			Gui.PushID(p.Id);
			if (check)
			{
				bool v = p.Default == "true";
				if (Gui.Checkbox("##b", &v))
				{
					mApp.BeginEdit();
					p.Default.Set(v ? "true" : "false");
					mApp.CommitCurrent();
					mCommitted = true;
				}
			}
			else
			{
				mScratch.Set(p.Default);
				Gui.igSetNextItemWidth(width);
				StringView hint = (p.Name == "receiver") ? "this" : "";
				bool changed = Gui.igInputTextWithHint("##v", scope String(hint), mScratch.Ptr, (.)mScratch.Capacity, 0, null, null);
				if (changed)
				{
					if (!mInlineEditPushedUndo)
					{
						mApp.BeginEdit();
						mInlineEditPushedUndo = true;
					}
					p.Default.Set(mScratch.View);
				}
				if (Gui.igIsItemDeactivatedAfterEdit())
				{
					mInlineEditPushedUndo = false;
					mApp.CommitCurrent();
					mCommitted = true;
				}
				else if (Gui.igIsItemDeactivated())
					mInlineEditPushedUndo = false;
				if (Gui.igIsItemHovered(0) && !p.Default.IsEmpty && p.Default.Length > 30)
					Gui.Tooltip(p.Default);
			}
			Gui.PopID();
		}

		// ------------------------------------------------------------------ comment bubbles

		struct BubbleHit
		{
			public int32 Id;
			/// 0 = node bubble (edit), 1 = node "add comment" chip, 2 = node bubble pin toggle,
			/// 3 = comment box pin toggle.
			public int32 Kind;
			public ImVec2 Min;
			public ImVec2 Max;
		}

		List<BubbleHit> mBubbleHits = new .() ~ delete _;
		/// The node whose bubble is being edited in place (0 = none), its text and focus request.
		int32 mBubbleEdit;
		bool mBubbleFocus;
		bool mBubbleActive;
		TextBuffer mBubbleBuf = new .(1024) ~ delete _;

		/// The comment of a node without its `//` markers (what Properties > Comment shows).
		public static void CommentText(Node node, String outText)
		{
			if (node.Comment == null)
				return;
			for (let line in node.Comment.Split('\n'))
			{
				var l = line;
				l.Trim();
				if (!outText.IsEmpty || !l.IsEmpty)
				{
					outText.Append(l);
					outText.Append('\n');
				}
			}
			while (outText.EndsWith('\n'))
				outText.RemoveFromEnd(1);
		}

		static void NormalizeComment(StringView text, String outText)
		{
			for (let line in text.Split('\n'))
			{
				var l = line;
				l.Trim();
				if (!l.IsEmpty)
				{
					outText.Append(l);
					outText.Append('\n');
				}
			}
			while (outText.EndsWith('\n'))
				outText.RemoveFromEnd(1);
		}

		/// Sets a node's comment from plain text, the same write as Properties > Comment (comment lines
		/// above the statement). One undo step. False when nothing changed.
		bool WriteComment(Node node, StringView text)
		{
			String before = scope .();
			CommentText(node, before);
			String beforeNorm = scope .();
			NormalizeComment(before, beforeNorm);
			String now = scope .();
			NormalizeComment(text, now);
			if (now == beforeNorm)
				return false;
			mApp.BeginEdit();
			DeleteAndNullify!(node.Comment);
			if (!now.IsEmpty)
				node.Comment = new String(now);
			mApp.CommitCurrent();
			mCommitted = true;
			return true;
		}

		/// F2 / Rename on a comment box: its title is edited in place on the canvas.
		public void BeginCommentRename(GraphTab tab, int32 commentId)
		{
			tab.EditingComment = commentId;
			mFocusCommentEdit = true;
		}

		/// Opens the in-place comment editor on a node (the node menu's Add / Edit Comment, a click on
		/// its bubble or chip).
		public void BeginBubbleEdit(int32 nodeId)
		{
			let tab = mApp.CurrentTab;
			let mg = mApp.CurrentMethod;
			let node = (mg != null) ? mg.Graph.FindNode(nodeId) : null;
			if (node == null || !node.IsExecNode)
				return;
			String t = scope .();
			CommentText(node, t);
			mBubbleBuf.Set(t);
			mBubbleEdit = nodeId;
			mBubbleFocus = true;
			mBubbleActive = false;
			if (tab != null)
				tab.SelectOnly(nodeId);
		}

		public bool BubbleEditing => mBubbleEdit != 0;
		public void CancelBubbleEdit() { mBubbleEdit = 0; }

		/// Self test: types `text` into the open editor and commits it (what Enter does).
		public bool SelfTestCommitBubble(StringView text)
		{
			let mg = mApp.CurrentMethod;
			let node = (mg != null && mBubbleEdit != 0) ? mg.Graph.FindNode(mBubbleEdit) : null;
			if (node == null)
				return false;
			WriteComment(node, text);
			mBubbleEdit = 0;
			return true;
		}

		/// Self test: the bubble hits of the last frame (count by kind).
		public int SelfTestBubbleHits(int32 kind)
		{
			int n = 0;
			for (let h in mBubbleHits)
				if (h.Kind == kind)
					n++;
			return n;
		}

		void DrawPinIcon(ImDrawList* dl, ImVec2 c, float s, uint32 col, bool filled)
		{
			let head = ImVec2(c.x, c.y - s * 0.2f);
			if (filled)
				Gui.ImDrawList_AddCircleFilled(dl, head, s * 0.3f, col, 12);
			else
				Gui.ImDrawList_AddCircle(dl, head, s * 0.3f, col, 12, Math.Max(1.2f, s * 0.12f));
			Gui.ImDrawList_AddLine(dl, .(c.x - s * 0.38f, c.y + s * 0.12f), .(c.x + s * 0.38f, c.y + s * 0.12f), col, Math.Max(1.2f, s * 0.14f));
			Gui.ImDrawList_AddLine(dl, .(c.x, c.y + s * 0.12f), .(c.x, c.y + s * 0.5f), col, Math.Max(1.2f, s * 0.12f));
		}

		ImVec2 MeasureText(StringView t, float fs, float wrap)
		{
			Gui.igPushFont(mFont, fs);
			let sz = Gui.igCalcTextSize(t.Ptr, t.Ptr + t.Length, false, wrap);
			Gui.igPopFont();
			return sz;
		}

		bool BubbleHitAt(ImVec2 mouse, out BubbleHit hit)
		{
			hit = default;
			for (var i = mBubbleHits.Count - 1; i >= 0; i--)
			{
				let h = mBubbleHits[i];
				if (mouse.x >= h.Min.x && mouse.x <= h.Max.x && mouse.y >= h.Min.y && mouse.y <= h.Max.y)
				{
					hit = h;
					return true;
				}
			}
			return false;
		}

		/// A click on a bubble, chip or pin toggle (before the canvas press). True when it was used.
		bool BubblePress(GraphTab tab, Sheet mg, ImVec2 mouse)
		{
			// The quick fix button of an error badge.
			for (let h in mFixHits)
				if (mouse.x >= h.Min.x && mouse.x <= h.Max.x && mouse.y >= h.Min.y && mouse.y <= h.Max.y)
				{
					let n = mg.Graph.FindNode(h.Id);
					let pin = (n != null) ? mApp.RefPinNeedingLocal(mg.Doc, mg.Graph, n) : null;
					if (pin != null && mApp.StoreRefInLocal(mg, pin, false, false))
						mCommitted = true;
					return true;
				}
			if (mBubbleEdit != 0)
				return false;
			if (!BubbleHitAt(mouse, let hit))
				return false;
			switch (hit.Kind)
			{
			case 0, 1:
				if (mg.Graph.ReadOnly)
					return false;
				BeginBubbleEdit(hit.Id);
			case 2:
				let n = mg.Graph.FindNode(hit.Id);
				if (n != null)
				{
					tab.Doc.SetBubblePinned(mg.Key, n.Key, !tab.Doc.IsBubblePinned(mg.Key, n.Key));
					mApp.LayoutChanged();
				}
			case 3:
				for (let c in mComments)
					if (c.Id == hit.Id)
					{
						c.Pinned = !c.Pinned;
						mApp.LayoutChanged();
					}
			default:
			}
			return true;
		}

		/// Node comment bubbles, the "add comment" chip on hover, the in-place editor, and the pinned
		/// labels of comment boxes. Canvas layer: bubbles scale with the graph unless pinned.
		void DrawBubbles(GraphTab tab, Sheet mg, Graph graph, ImDrawList* dl, ImVec2 mouse)
		{
			mBubbleHits.Clear();
			float z = tab.Zoom;
			let origin = tab.CanvasOrigin;
			let cmax = origin + tab.CanvasSize;
			bool wiring = tab.Mode == .Wire;
			bool idle = tab.Mode == .None;
			for (let L in mOrder)
			{
				let node = L.Node;
				if (!L.Visible || !node.IsExecNode || node == graph.Entry)
					continue;
				bool editing = mBubbleEdit == node.Id;
				String text = scope .();
				CommentText(node, text);
				bool has = !text.IsEmpty;
				bool pinned = tab.Doc.IsBubblePinned(mg.Key, node.Key);
				let p0 = tab.GridToScreen(node.X, node.Y);
				let p1 = p0 + ImVec2(L.W, L.H) * z;
				float s = pinned ? 1.0f : z;
				float fade = 1;
				if (!pinned)
				{
					if (z < 0.35f && !editing)
						continue;
					fade = Math.Clamp((z - 0.35f) / 0.25f, 0, 1);
				}
				if (editing)
					s = Math.Max(s, 0.8f);
				float sm = Math.Max(s, 0.8f);
				bool inRegion = idle && mouse.x >= p0.x && mouse.x <= p1.x && mouse.y >= p0.y - 34 * sm && mouse.y <= p1.y && (mHoverNode == 0 || mHoverNode == node.Id);
				if (!has && !editing)
				{
					// Hover affordance: a small chip above the title.
					if (!inRegion || graph.ReadOnly || mBubbleEdit != 0)
						continue;
					float fsC = mFontSize * 0.85f * sm;
					StringView label = "+ comment";
					let sz = MeasureText(label, fsC, 0);
					float cpad = 5 * sm;
					let cw = sz.x + 2 * cpad;
					let chh = sz.y + 2 * cpad * 0.6f;
					let cmn = ImVec2(p0.x, p0.y - chh - 4 * sm);
					let cmx = cmn + ImVec2(cw, chh);
					bool hot = mouse.x >= cmn.x && mouse.x <= cmx.x && mouse.y >= cmn.y && mouse.y <= cmx.y;
					Gui.ImDrawList_AddRectFilled(dl, cmn, cmx, hot ? Gui.Color(78, 84, 98, 240) : Gui.Color(52, 56, 66, 225), 5 * sm, 0);
					Gui.ImDrawList_AddRect(dl, cmn, cmx, Gui.Color(120, 128, 146, 200), 5 * sm, 1, 0);
					Text(dl, .(cmn.x + cpad, cmn.y + cpad * 0.6f), fsC, Gui.Color(215, 220, 230), label);
					BubbleHit ch = default;
					ch.Id = node.Id;
					ch.Kind = 1;
					ch.Min = cmn;
					ch.Max = cmx;
					mBubbleHits.Add(ch);
					continue;
				}
				float fs = mFontSize * 0.9f * s;
				float pad = 6 * s;
				float iconW = 16 * s;
				float wrapW = 240 * s;
				let tsz = MeasureText(text, fs, wrapW);
				float bw = Math.Min(tsz.x, wrapW) + 2 * pad + iconW;
				float bh = tsz.y + 2 * pad;
				if (editing)
				{
					bw = Math.Max(bw, 220 * s);
					bh = Math.Max(bh, 64 * s);
				}
				var bp = ImVec2(p0.x, p0.y - bh - 8 * s);
				if (pinned)
				{
					bp.x = Math.Clamp(bp.x, origin.x + 4, Math.Max(origin.x + 4, cmax.x - bw - 4));
					bp.y = Math.Max(bp.y, origin.y + 4);
					// Stay near the node: never farther than a bubble's height above it.
					bp.y = Math.Min(bp.y, p1.y - bh);
				}
				let bmax = bp + ImVec2(bw, bh);
				if (!Canvas.RectsOverlap(bp, bmax, origin, cmax))
					continue;
				if (wiring)
				{
					// Dragging a wire: a bubble over another node would hide its pins (the drop targets).
					bool over = false;
					for (let O in mOrder)
					{
						if (O == L || !O.Visible)
							continue;
						let o0 = tab.GridToScreen(O.Node.X, O.Node.Y);
						if (Canvas.RectsOverlap(bp, bmax, o0, o0 + ImVec2(O.W, O.H) * z))
						{
							over = true;
							break;
						}
					}
					if (over)
						continue;
				}
				uint8 a = (uint8)(fade * 255);
				bool hotB = idle && mouse.x >= bp.x && mouse.x <= bmax.x && mouse.y >= bp.y && mouse.y <= bmax.y;
				if (editing)
				{
					Gui.ImDrawList_AddRectFilled(dl, bp, bmax, Gui.Color(40, 44, 54, 250), 7 * s, 0);
					Gui.ImDrawList_AddRect(dl, bp, bmax, Theme.NodeSelected, 7 * s, Math.Max(1.5f, 1.5f * s), 0);
					Gui.igPushFont(mFont, fs);
					Gui.igPushStyleVar_Vec2(StyleVar.FramePadding, .(pad, pad * 0.7f));
					Gui.igPushStyleColor_U32(Col.FrameBg, Gui.Color(0, 0, 0, 0));
					Gui.igSetCursorScreenPos(bp);
					if (mBubbleFocus)
					{
						Gui.igSetKeyboardFocusHere(0);
						mBubbleFocus = false;
					}
					bool esc = Gui.IsKeyPressed(Key.Escape, false);
					Gui.PushID(node.Id);
					bool entered = Gui.igInputTextMultiline("##vbbubble", mBubbleBuf.Ptr, (.)mBubbleBuf.Capacity, .(bw, bh), InputTextFlags.EnterReturnsTrue | InputTextFlags.CtrlEnterForNewLine, null, null);
					if (Gui.igIsItemActive())
						mBubbleActive = true;
					bool deact = Gui.igIsItemDeactivated();
					Gui.PopID();
					Gui.igPopStyleColor(1);
					Gui.igPopStyleVar(1);
					Gui.igPopFont();
					if (esc)
						mBubbleEdit = 0; // cancel
					else if ((entered || deact) && mBubbleActive)
					{
						WriteComment(node, mBubbleBuf.View);
						mBubbleEdit = 0;
					}
					continue;
				}
				Gui.ImDrawList_AddRectFilled(dl, bp + .(1, 2 * s), bmax + .(1, 2 * s), Gui.Color(0, 0, 0, (uint8)(40 * fade)), 7 * s, 0);
				Gui.ImDrawList_AddRectFilled(dl, bp, bmax, Theme.WithAlpha(hotB ? Gui.Color(70, 76, 90) : Gui.Color(56, 60, 72), (uint8)(238 * fade)), 7 * s, 0);
				Gui.ImDrawList_AddRect(dl, bp, bmax, Theme.WithAlpha(pinned ? Theme.NodeSelected : Gui.Color(112, 120, 138), a), 7 * s, 1, 0);
				// Pointer to the node.
				Gui.ImDrawList_AddTriangleFilled(dl, .(bp.x + 14 * s, bmax.y - 0.5f), .(bp.x + 24 * s, bmax.y - 0.5f), .(bp.x + 16 * s, bmax.y + 6 * s), Theme.WithAlpha(Gui.Color(56, 60, 72), (uint8)(238 * fade)));
				Gui.ImDrawList_PushClipRect(dl, bp, bmax, true);
				Text(dl, .(bp.x + pad, bp.y + pad), fs, Theme.WithAlpha(Gui.Color(230, 233, 240), a), text, null, wrapW);
				Gui.ImDrawList_PopClipRect(dl);
				BubbleHit h = default;
				h.Id = node.Id;
				h.Kind = 0;
				h.Min = bp;
				h.Max = bmax;
				mBubbleHits.Add(h);
				if (hotB || pinned)
				{
					let ic = ImVec2(bmax.x - iconW * 0.5f - 2 * s, bp.y + pad + fs * 0.5f);
					float isz = 13 * s;
					bool hotI = mouse.x >= ic.x - isz && mouse.x <= ic.x + isz && mouse.y >= ic.y - isz && mouse.y <= ic.y + isz;
					DrawPinIcon(dl, ic, isz, Theme.WithAlpha(pinned ? Theme.NodeSelected : (hotI ? Gui.Color(255, 255, 255) : Gui.Color(170, 178, 196)), a), pinned);
					BubbleHit ph = default;
					ph.Id = node.Id;
					ph.Kind = 2;
					ph.Min = ic - ImVec2(isz, isz);
					ph.Max = ic + ImVec2(isz, isz);
					mBubbleHits.Add(ph);
					if (hotI)
						Gui.Tooltip(pinned ? "Pinned: keeps a readable size when zoomed out. Click to unpin." : "Pin: keep this comment readable when zoomed out.");
				}
			}

			// Comment boxes: a pin toggle on the title bar, and for a pinned box zoomed out a readable label.
			for (let c in mComments)
			{
				let p0 = tab.GridToScreen(c.X, c.Y);
				let p1 = tab.GridToScreen(c.X + c.W, c.Y + c.H);
				if (!Canvas.RectsOverlap(p0, p1, origin, cmax) || tab.EditingComment == c.Id)
					continue;
				bool hotBox = idle && mHoverComment == c.Id;
				bool chip = c.Pinned && z < 1.0f;
				float isz = 11 * Math.Max(Math.Min(z, 1.0f), 0.8f);
				if (chip)
				{
					float fs = mFontSize * 1.25f;
					let sz = MeasureText(c.Text, fs, 0);
					float pad = 6;
					float cw = Math.Min(sz.x, 420) + 2 * pad + 22;
					float chh = sz.y + 8;
					var cp = ImVec2(p0.x, p0.y - chh);
					cp.x = Math.Clamp(cp.x, origin.x + 4, Math.Max(origin.x + 4, cmax.x - cw - 4));
					cp.y = Math.Max(cp.y, origin.y + 4);
					let cmx = cp + ImVec2(cw, chh);
					Gui.ImDrawList_AddRectFilled(dl, cp, cmx, Theme.WithAlpha(Theme.Mix(c.Color, Gui.Color(0, 0, 0), 0.5f), 245), 5, 0);
					Gui.ImDrawList_AddRect(dl, cp, cmx, Theme.WithAlpha(c.Color, 230), 5, 1, 0);
					Gui.ImDrawList_PushClipRect(dl, cp, .(cmx.x - 22, cmx.y), true);
					Text(dl, .(cp.x + pad, cp.y + 4), fs, Gui.Color(255, 255, 255), c.Text);
					Gui.ImDrawList_PopClipRect(dl);
					let ic = ImVec2(cmx.x - 13, cp.y + chh * 0.5f);
					DrawPinIcon(dl, ic, 12, Theme.NodeSelected, true);
					BubbleHit ph = default;
					ph.Id = c.Id;
					ph.Kind = 3;
					ph.Min = ic - ImVec2(isz, isz);
					ph.Max = ic + ImVec2(isz, isz);
					mBubbleHits.Add(ph);
				}
				else if ((hotBox || c.Pinned) && z >= 0.3f)
				{
					let ic = ImVec2(p1.x - 14 * Math.Min(z, 1.0f) - 6, p0.y + CommentTitleH * z * 0.5f);
					DrawPinIcon(dl, ic, isz, c.Pinned ? Theme.NodeSelected : Gui.Color(200, 205, 215), c.Pinned);
					BubbleHit ph = default;
					ph.Id = c.Id;
					ph.Kind = 3;
					ph.Min = ic - ImVec2(isz, isz);
					ph.Max = ic + ImVec2(isz, isz);
					mBubbleHits.Add(ph);
				}
			}
		}

		/// The pending wire of an open pin-opened Node menu: the source pin's layout and the screen end.
		public bool PendingWireEnds(GraphTab tab, Graph graph, out PinLay src, out ImVec2 end)
		{
			src = default;
			end = default;
			if (!mApp.PendingWire(tab, graph, let pinId, let grid) || !TryGetPin(pinId, out src))
				return false;
			end = tab.GridToScreen(grid.x, grid.y);
			return true;
		}

		/// Dragged wire, marquee, zoom label, pin tooltip.
		void DrawOverlay(GraphTab tab, Graph graph, ImDrawList* dl, ImVec2 mouse)
		{
			float z = tab.Zoom;
			if (tab.Mode == .Wire && TryGetPin(tab.DragPin, let src))
			{
				let sp = PinScreen(tab, src);
				uint32 col = WireColor(src.Pin);
				Pin target = DropTarget(graph, src.Pin);
				bool bad = mHoverPin != 0 && mHoverPin != src.Pin.Id && target == null;
				if (bad)
					col = Theme.Mix(col, Theme.WireBad, 0.75f);
				float th = Math.Max(1.0f, ((src.Pin.Kind == .Flow) ? 3.0f : 2.0f) * z);
				// Snap the loose end onto the target pin.
				ImVec2 end = mouse;
				if (target != null && TryGetPin(target.Id, let tpl))
					end = PinScreen(tab, tpl);
				if (src.Pin.IsInput)
					Canvas.Wire(dl, end, sp, z, col, th);
				else
					Canvas.Wire(dl, sp, end, z, col, th);
				if (bad)
				{
					// Say why, like UE: "float to int needs a cast: it can lose data".
					String why = scope .();
					Graph.CanConnectTyped(mApp.Language, src.Pin, graph.FindPin(mHoverPin), why);
					Gui.Tooltip(why.IsEmpty ? "Incompatible pins" : why);
				}
				else if (target != null && target.IsInput && target.Kind == .Value && graph.IsLinked(target))
					Gui.Tooltip("Replace existing input connection");
			}
			else if (tab.Mode == .None && PendingWireEnds(tab, graph, let pw, let pwEnd))
			{
				// The Node menu is up for a wire dragged off a pin: keep that wire drawn, from the pin to
				// where the new node will go, until the menu closes.
				let sp = PinScreen(tab, pw);
				float th = Math.Max(1.0f, ((pw.Pin.Kind == .Flow) ? 3.0f : 2.0f) * z);
				if (pw.Pin.IsInput)
					Canvas.Wire(dl, pwEnd, sp, z, WireColor(pw.Pin), th);
				else
					Canvas.Wire(dl, sp, pwEnd, z, WireColor(pw.Pin), th);
			}
			else if (tab.Mode == .Relink)
			{
				Pin target = (mHoverPin != 0) ? graph.FindPin(mHoverPin) : null;
				for (let id in tab.DragLinks)
				{
					let link = graph.FindLink(id);
					if (link == null)
						continue;
					let other = (link.From.Id == tab.DragPin) ? link.To : link.From;
					if (!TryGetPin(other.Id, let opl))
						continue;
					let op = PinScreen(tab, opl);
					uint32 col = WireColor(link.From);
					if (target != null && !Graph.CanConnectTyped(mApp.Language, other, target))
						col = Theme.Mix(col, Theme.WireBad, 0.75f);
					float th = Math.Max(1.0f, ((link.From.Kind == .Flow) ? 3.0f : 2.0f) * z);
					if (other.IsInput)
						Canvas.Wire(dl, mouse, op, z, col, th);
					else
						Canvas.Wire(dl, op, mouse, z, col, th);
				}
			}
			else if (tab.Mode == .Marquee)
			{
				let a = ImVec2(Math.Min(tab.PressPos.x, mouse.x), Math.Min(tab.PressPos.y, mouse.y));
				let b = ImVec2(Math.Max(tab.PressPos.x, mouse.x), Math.Max(tab.PressPos.y, mouse.y));
				Gui.ImDrawList_AddRectFilled(dl, a, b, Theme.MarqueeFill, 0, 0);
				Gui.ImDrawList_AddRect(dl, a, b, Theme.MarqueeBorder, 0, 1, 0);
			}
			else if (tab.Mode == .None && mHoverPin != 0 && mApp.ActiveDrag() != null)
				DrawDragPinHighlight(tab, graph, dl, mApp.ActiveDrag());
			else if (tab.Mode == .None && mHoverPin != 0)
			{
				let p = graph.FindPin(mHoverPin);
				if (p != null && p.Kind == .Value)
				{
					String tip = scope .();
					PinTooltip(graph, p, tip);
					Gui.Tooltip(tip);
				}
			}
			else if (tab.Mode == .None && mHoverLink != 0 && mApp.IsDebugStopped)
			{
				// Stopped in the debugger: a wire shows the value it carries (its output pin's).
				let link = graph.FindLink(mHoverLink);
				String v = scope .();
				if (link != null && link.From.Kind == .Value && mApp.CurrentMethod != null && mApp.DebugPinValue(mApp.CurrentMethod, link.From, v))
					Gui.Tooltip(scope $"{(link.From.Label.IsEmpty ? StringView(link.From.Name) : StringView(link.From.Label))}: {v}");
			}
			else if (tab.Mode == .None && mHoverExprPin != 0)
			{
				// The Expression badge: what it means, and the whole value when it is shortened.
				let p = graph.FindPin(mHoverExprPin);
				if (p != null)
					Gui.Tooltip(scope $"{cExpressionBadge}: {p.Default}\n{cExpressionTip}");
			}

			// Node tooltip after hovering ~0.6 s (UE).
			if (tab.Mode == .None && mHoverNode != 0 && mHoverPin == 0 && mHoverExprPin == 0 && mStripHover == 0 && !Gui.igIsPopupOpen_Str("", (1 << 10) | (1 << 11) /* AnyPopupId | AnyPopupLevel */))
			{
				if (mTipNode != mHoverNode)
				{
					mTipNode = mHoverNode;
					mTipSince = Gui.igGetTime();
				}
				else if (Gui.igGetTime() - mTipSince > 0.6)
				{
					let node = graph.FindNode(mHoverNode);
					if (node != null)
					{
						String tip = scope .();
						if (mNodeErrors.TryGetValue(node.Id, let err))
							tip.AppendF("ERROR: {}\n\n", err);
						else if (mNodeWarnings.TryGetValue(node.Id, let warn))
							tip.AppendF("Warning: {}\n\n", warn);
						else if (mLayById.TryGetValue(node.Id, let tipLay) && tipLay.Orphan)
							tip.Append("Warning: Not connected: no code yet\n\n");
						NodeTooltip(tab, graph, node, tip);
						if (!tip.IsEmpty)
							Gui.Tooltip(tip);
					}
				}
			}
			else
				mTipNode = 0;

			DrawZoomReadout(tab, dl);
		}

		/// Where a dragged wire from `src` would connect: the hovered pin, or the first
		/// compatible pin of the hovered node. Null if nothing compatible.
		/// A wire the pin's own type refuses, but another overload of the call takes (an int dropped on
		/// WriteLine's text pin): allowed, and the call switches to that overload once wired.
		static bool OverloadTakes(Graph graph, Pin a, Pin b)
		{
			if (!Graph.CanConnect(a, b) || a.Kind != .Value)
				return false;
			let input = a.IsInput ? a : b;
			let output = a.IsInput ? b : a;
			// Seam: whether another overload of the call takes the type (the language's bind).
			return false;
		}

		Pin DropTarget(Graph graph, Pin src)
		{
			if (src == null)
				return null;
			if (mHoverPin != 0)
			{
				let p = graph.FindPin(mHoverPin);
				return (Graph.CanConnectTyped(mApp.Language, src, p) || OverloadTakes(graph, src, p)) ? p : null;
			}
			if (mHoverNode != 0)
			{
				let n = graph.FindNode(mHoverNode);
				if (n == null)
					return null;
				let list = src.IsInput ? n.Outputs : n.Inputs;
				// Prefer a free pin of the same type, then any free one, then anything compatible.
				for (int pass < 3)
				{
					for (let p in list)
					{
						if (!(Graph.CanConnectTyped(mApp.Language, src, p) || (pass == 2 && OverloadTakes(graph, src, p))) || HidePin(graph, p))
							continue;
						if (!TryGetPin(p.Id, let pl) || !pl.Visible)
							continue;
						bool free = !graph.IsLinked(p) || p.Kind == .Flow;
						if (pass == 0 && (!free || (p.Kind == .Value && p.TypeName != src.TypeName)))
							continue;
						if (pass == 1 && !free)
							continue;
						return p;
					}
				}
			}
			return null;
		}

		// ------------------------------------------------------------------ comments & reroutes

		/// Comment title bar height in grid units.
		float CommentTitleH => mFontSize * 1.25f + 12;

		void GatherComments(GraphTab tab)
		{
			mComments.Clear();
			for (let c in tab.Doc.Comments)
				if (c.MethodKey == tab.MethodKey)
					mComments.Add(c);
			// Bigger boxes behind smaller ones, so nested comments stay clickable.
			mComments.Sort(scope (a, b) => (b.W * b.H <=> a.W * a.H));
		}

		GraphComment FindComment(int32 id)
		{
			for (let c in mComments)
				if (c.Id == id)
					return c;
			return null;
		}

		GraphReroute FindKnot(KnotRef k)
		{
			if (!k.IsValid)
				return null;
			if (mRoutes.TryGetValue(RouteKey(k.FromPin, k.ToPin), let route) && k.Index < route.Points.Count)
				return route;
			return null;
		}

		static Link FindLinkBetween(Graph graph, Pin from, Pin to)
		{
			for (let l in graph.Links)
				if (l.From == from && l.To == to)
					return l;
			return null;
		}

		/// Matches the document's reroute records to this graph's links (by pin id while editing,
		/// by node key + pin name after a reload/rebuild) and drops those whose link is gone.
		void ResolveReroutes(GraphTab tab, Graph graph)
		{
			mRoutes.Clear();
			let list = tab.Doc.Reroutes;
			for (int i = list.Count - 1; i >= 0; i--)
			{
				let r = list[i];
				if (r.MethodKey != tab.MethodKey)
					continue;
				Pin from = null;
				Pin to = null;
				if (r.FromPinId != 0 && r.GraphSerial == graph.Serial)
				{
					from = graph.FindPin(r.FromPinId);
					to = graph.FindPin(r.ToPinId);
				}
				else
				{
					for (let n in graph.Nodes)
					{
						if (n.Key == r.FromNode)
							from = n.FindOutput(r.FromPin);
						if (n.Key == r.ToNode)
							to = n.FindInput(r.ToPin);
					}
				}
				if (from == null || to == null || FindLinkBetween(graph, from, to) == null || r.Points.IsEmpty)
				{
					list.RemoveAt(i);
					delete r;
					mApp.LayoutChanged();
					continue;
				}
				r.FromPinId = from.Id;
				r.ToPinId = to.Id;
				r.GraphSerial = graph.Serial;
				mRoutes[RouteKey(from.Id, to.Id)] = r;
			}
		}

		/// Double-click on a wire: add a reroute knot there (UE). Layout only.
		void AddKnot(GraphTab tab, Graph graph, int32 linkId, int32 segment, ImVec2 mouse)
		{
			let link = graph.FindLink(linkId);
			if (link == null)
				return;
			mApp.BeginEdit();
			let g = tab.ScreenToGrid(mouse);
			NodePos pos = default;
			pos.X = g.x;
			pos.Y = g.y;
			if (mRoutes.TryGetValue(RouteKey(link.From.Id, link.To.Id), var route))
				route.Points.Insert(Math.Clamp(segment, 0, route.Points.Count), pos);
			else
			{
				route = new GraphReroute();
				route.MethodKey.Set(tab.MethodKey);
				route.FromNode.Set(link.From.Owner.Key);
				route.FromPin.Set(link.From.Name);
				route.ToNode.Set(link.To.Owner.Key);
				route.ToPin.Set(link.To.Name);
				route.FromPinId = link.From.Id;
				route.ToPinId = link.To.Id;
				route.GraphSerial = graph.Serial;
				route.Points.Add(pos);
				tab.Doc.Reroutes.Add(route);
				mRoutes[RouteKey(link.From.Id, link.To.Id)] = route;
			}
			tab.ClearSelection();
			tab.AddKnot(.(link.From.Id, link.To.Id, (int32)Math.Clamp(segment, 0, route.Points.Count - 1)));
			mApp.LayoutChanged();
		}

		/// The Node menu's Add Reroute Knot, opened from a pin: a knot at `gridPos` on that pin's
		/// wire (knots are points of a wire, Graph-Format.md 4). A pin with no wire, or with
		/// several, says so instead.
		public void KnotFromPin(GraphTab tab, Graph graph, Pin pin, ImVec2 gridPos)
		{
			List<Link> links = scope .();
			for (let l in graph.Links)
				if (l.From == pin || l.To == pin)
					links.Add(l);
			if (links.Count != 1)
			{
				mApp.SetStatus(links.IsEmpty ? "A knot sits on a wire: wire the pin first, or double-click a wire to add one" :
					"That pin has several wires: double-click the wire that should get the knot", .Info);
				return;
			}
			AddKnot(tab, graph, links[0].Id, int32.MaxValue, tab.GridToScreen(gridPos.x, gridPos.y));
		}

		void RemoveKnot(GraphTab tab, KnotRef k, bool pushUndo)
		{
			let route = FindKnot(k);
			if (route == null)
				return;
			if (pushUndo)
				mApp.BeginEdit();
			route.Points.RemoveAt(k.Index);
			if (route.Points.IsEmpty)
			{
				tab.Doc.Reroutes.Remove(route);
				mRoutes.Remove(RouteKey(k.FromPin, k.ToPin));
				delete route;
			}
			// The selection: this one goes, the later ones of the same wire move up an index.
			for (int i = tab.SelectedKnots.Count - 1; i >= 0; i--)
			{
				var s = ref tab.SelectedKnots[i];
				if (s.FromPin != k.FromPin || s.ToPin != k.ToPin)
					continue;
				if (s.Index == k.Index)
					tab.SelectedKnots.RemoveAt(i);
				else if (s.Index > k.Index)
					s.Index--;
			}
			mApp.LayoutChanged();
		}

		/// Removes reroute nodes together (later ones of a wire first, so the indexes of the rest stay right).
		void RemoveKnots(GraphTab tab, List<KnotRef> knots, bool pushUndo)
		{
			List<KnotRef> sorted = scope .();
			sorted.AddRange(knots);
			sorted.Sort(scope (a, b) =>
			{
				if (a.FromPin != b.FromPin)
					return a.FromPin <=> b.FromPin;
				if (a.ToPin != b.ToPin)
					return a.ToPin <=> b.ToPin;
				return b.Index <=> a.Index;
			});
			bool first = true;
			for (let k in sorted)
			{
				RemoveKnot(tab, k, pushUndo && first);
				first = false;
			}
		}

		void DrawKnots(GraphTab tab, Graph graph, ImDrawList* dl)
		{
			float z = tab.Zoom;
			for (let route in mRoutes.Values)
			{
				let from = graph.FindPin(route.FromPinId);
				if (from == null)
					continue;
				uint32 col = WireColor(from);
				for (let pt in route.Points)
				{
					KnotRef k = .(route.FromPinId, route.ToPinId, (int32)@pt.Index);
					let c = tab.GridToScreen(pt.X, pt.Y);
					bool hot = mHoverKnot.Equals(k);
					bool sel = tab.IsKnotSelected(k);
					float r = Math.Max(3.5f, 6 * z);
					// UE's reroute node: a small dark pill with the wire's colour in the middle.
					Gui.ImDrawList_AddCircleFilled(dl, c, r + 2 * z, Gui.Color(15, 15, 15, 235), 0);
					Gui.ImDrawList_AddCircleFilled(dl, c, r, hot ? Theme.Lighten(col, 1.3f) : col, 0);
					if (sel)
						Gui.ImDrawList_AddCircle(dl, c, r + 4 * z, Theme.NodeSelected, 0, Math.Max(1.5f, 2 * z));
				}
			}
		}

		void DrawComments(GraphTab tab, ImDrawList* dl)
		{
			float z = tab.Zoom;
			let origin = tab.CanvasOrigin;
			let cmax = origin + tab.CanvasSize;
			for (let c in mComments)
			{
				let p0 = tab.GridToScreen(c.X, c.Y);
				let p1 = tab.GridToScreen(c.X + c.W, c.Y + c.H);
				if (!Canvas.RectsOverlap(p0, p1, origin, cmax))
					continue;
				float th = CommentTitleH * z;
				float r = 4 * z;
				uint8 alpha = (uint8)((c.Color >> 24) & 0xFF);
				// Body: the colour, very faint. Title bar: the colour, darker and more opaque.
				Gui.ImDrawList_AddRectFilled(dl, p0, p1, Theme.WithAlpha(c.Color, (uint8)(alpha * 0.22f)), r, 0);
				uint32 bar = Theme.WithAlpha(Theme.Mix(c.Color, Gui.Color(0, 0, 0), 0.38f), (uint8)Math.Max(alpha * 0.9f, 90));
				Gui.ImDrawList_AddRectFilled(dl, p0, .(p1.x, p0.y + th), bar, r, DrawFlags.RoundCornersTop);
				bool sel = tab.IsCommentSelected(c.Id);
				bool hot = mHoverComment == c.Id;
				uint32 border = sel ? Theme.NodeSelected : Theme.WithAlpha(c.Color, hot ? (uint8)200 : (uint8)(alpha * 0.55f));
				Gui.ImDrawList_AddRect(dl, p0, p1, border, r, sel ? Math.Max(1.5f, 2 * z) : 1, 0);
				// Resize grip (bottom-right), like UE.
				float hs = Math.Max(8, 12 * z);
				uint32 grip = Theme.WithAlpha(Gui.Color(255, 255, 255), (mHoverCommentResize == c.Id) ? (uint8)200 : (uint8)70);
				Gui.ImDrawList_AddTriangleFilled(dl, .(p1.x - 2, p1.y - hs), .(p1.x - 2, p1.y - 2), .(p1.x - hs, p1.y - 2), grip);

				float fs = mFontSize * 1.25f * z;
				if (tab.EditingComment == c.Id && z >= 0.3f)
				{
					// Inline rename (double-click the title).
					Gui.igPushFont(mFont, fs);
					Gui.igPushStyleVar_Vec2(StyleVar.FramePadding, .(4 * z, (th - fs) * 0.5f - 1));
					Gui.igSetCursorScreenPos(.(p0.x + 6 * z, p0.y + 1));
					Gui.igSetNextItemWidth(Math.Max(p1.x - p0.x - 12 * z, 40));
					Gui.PushID(c.Id);
					if (mFocusCommentEdit)
					{
						mCommentBuf.Set(c.Text);
						Gui.igSetKeyboardFocusHere(0);
						mFocusCommentEdit = false;
						mFocusedCommentEdit = c.Id;
					}
					if (Gui.igInputText("##ctitle", mCommentBuf.Ptr, (.)mCommentBuf.Capacity, InputTextFlags.AutoSelectAll | InputTextFlags.EnterReturnsTrue, null, null))
						tab.EditingComment = 0;
					if (Gui.igIsItemEdited())
					{
						c.Text.Set(mCommentBuf.View);
						mApp.LayoutChanged();
					}
					if (Gui.igIsItemDeactivated() && mFocusedCommentEdit == c.Id)
					{
						tab.EditingComment = 0;
						mFocusedCommentEdit = 0;
					}
					Gui.PopID();
					Gui.igPopStyleVar(1);
					Gui.igPopFont();
				}
				else if (!(c.Pinned && z < 1.0f))
				{
					let clipMin = ImVec2(p0.x, p0.y);
					let clipMax = ImVec2(p1.x - 4 * z, p0.y + th);
					Gui.ImDrawList_PushClipRect(dl, clipMin, clipMax, true);
					let tp = ImVec2(p0.x + 10 * z, p0.y + (th - fs) * 0.5f);
					Text(dl, tp + .(1, 1), fs, Gui.Color(0, 0, 0, 160), c.Text);
					Text(dl, tp, fs, Gui.Color(255, 255, 255), c.Text);
					Gui.ImDrawList_PopClipRect(dl);
				}
			}
		}

		/// Nodes whose whole rectangle lies inside the comment.
		void NodesInComment(GraphComment c, List<int32> outIds)
		{
			for (let L in mLayById.Values)
			{
				let n = L.Node;
				if (n.X >= c.X && n.Y >= c.Y && n.X + L.W <= c.X + c.W && n.Y + L.H <= c.Y + c.H)
					outIds.Add(n.Id);
			}
		}

		/// C: a comment around the selected nodes, or an empty one at the mouse (UE).
		public void CreateComment(GraphTab tab, Graph graph)
		{
			float minX = float.MaxValue;
			float minY = float.MaxValue;
			float maxX = float.MinValue;
			float maxY = float.MinValue;
			for (let id in tab.SelectedNodes)
			{
				let n = graph.FindNode(id);
				if (n == null)
					continue;
				NodeLay L;
				if (!mLayById.TryGetValue(id, out L))
					continue;
				minX = Math.Min(minX, n.X);
				minY = Math.Min(minY, n.Y);
				maxX = Math.Max(maxX, n.X + L.W);
				maxY = Math.Max(maxY, n.Y + L.H);
			}
			for (let id in tab.SelectedComments)
			{
				let c = FindComment(id);
				if (c == null)
					continue;
				minX = Math.Min(minX, c.X);
				minY = Math.Min(minY, c.Y);
				maxX = Math.Max(maxX, c.X + c.W);
				maxY = Math.Max(maxY, c.Y + c.H);
			}
			mApp.BeginEdit();
			GraphComment c = new .();
			c.MethodKey.Set(tab.MethodKey);
			c.Text.Set("Comment");
			if (minX <= maxX)
			{
				const float Pad = 24;
				c.X = Canvas.Snap(minX - Pad);
				c.Y = Canvas.Snap(minY - Pad - CommentTitleH);
				c.W = Canvas.Snap(maxX - minX + Pad * 2 + 8);
				c.H = Canvas.Snap(maxY - minY + Pad * 2 + CommentTitleH + 8);
			}
			else
			{
				let m = MouseGridPos(tab);
				c.X = Canvas.Snap(m.x);
				c.Y = Canvas.Snap(m.y);
				c.W = 400;
				c.H = 200;
			}
			tab.Doc.Comments.Add(c);
			mComments.Add(c);
			tab.ClearSelection();
			tab.SelectedComments.Add(c.Id);
			// Start renaming it right away, like UE.
			tab.EditingComment = c.Id;
			mFocusCommentEdit = true;
			mApp.LayoutChanged();
		}

		void DeleteComments(GraphTab tab, List<int32> ids)
		{
			for (let id in ids)
			{
				let c = FindComment(id);
				if (c == null)
					continue;
				tab.Doc.Comments.Remove(c);
				mComments.Remove(c);
				delete c;
			}
			tab.SelectedComments.Clear();
			mApp.LayoutChanged();
		}

		/// Comment presets (UE's palette is similar: white, and a few muted colours).
		static uint32[8] sCommentColors = .(
			Gui.Color(255, 255, 255, 180), Gui.Color(255, 90, 90, 190), Gui.Color(255, 170, 60, 190), Gui.Color(250, 230, 80, 190),
			Gui.Color(110, 220, 110, 190), Gui.Color(80, 190, 255, 190), Gui.Color(170, 120, 255, 190), Gui.Color(120, 120, 120, 200));

		/// Colour swatches + a full RGBA picker. Returns true when the colour changed.
		bool CommentColorEditor(GraphComment c)
		{
			bool changed = false;
			for (int i < sCommentColors.Count)
			{
				if (i > 0)
					Gui.SameLine(0, 4);
				Gui.PushID((int32)i);
				if (Gui.igColorButton("##preset", Gui.igColorConvertU32ToFloat4(sCommentColors[i]), ColorEditFlags.AlphaPreviewHalf, .(20, 20)))
				{
					c.Color = sCommentColors[i];
					changed = true;
				}
				Gui.PopID();
			}
			let v = Gui.igColorConvertU32ToFloat4(c.Color);
			float[4] col = .(v.x, v.y, v.z, v.w);
			Gui.igSetNextItemWidth(-1);
			if (Gui.igColorEdit4("##ccolor", &col[0], ColorEditFlags.AlphaBar | ColorEditFlags.AlphaPreviewHalf))
			{
				c.Color = Gui.igColorConvertFloat4ToU32(.(col[0], col[1], col[2], col[3]));
				changed = true;
			}
			if (changed)
				mApp.LayoutChanged();
			return changed;
		}

		/// Properties panel content for a selected comment box. Returns false if no comment is the
		/// selection (then the caller shows something else).
		public bool DrawCommentDetails(GraphTab tab)
		{
			if (tab == null || tab.SelectedComments.Count != 1 || !tab.SelectedNodes.IsEmpty)
				return false;
			GraphComment c = null;
			for (let cc in tab.Doc.Comments)
				if (cc.Id == tab.SelectedComments[0])
					c = cc;
			if (c == null)
				return false;
			if (PropertyGrid.Begin("##props"))
			{
				if (PropertyGrid.Section("Comment", true, Icon.Comment))
				{
					PropertyGrid.LinesRow("Text", "##ctext", c.Text, let changed, "The text of the comment box");
					if (changed)
						mApp.LayoutChanged();
					PropertyGrid.Row("Comment Color", "The box's colour");
					CommentColorEditor(c);
					PropertyGrid.Note("Comment boxes are layout only: they are saved with the layout, not in the program. Drag the title to move it with the nodes inside; drag the corner to resize; double-click the title to rename.");
				}
				PropertyGrid.End();
			}
			return true;
		}

		// ------------------------------------------------------------------ find, watermark, tips

		/// Captures (`zoomshow` self-test step): the zoom readout stays visible.
		public bool PinZoomReadout;

		/// How visible the zoom readout is `age` seconds after the last zoom change: fully for 1.5 s,
		/// then it fades out in a quarter second (0 = not drawn).
		public static float ZoomReadoutAlpha(float age) => Math.Clamp(1.0f - (age - 1.5f) / 0.25f, 0, 1);

		/// The zoom readout ("Zoom 1:1", "Zoom -3") in the canvas's bottom-left corner, over the nodes
		/// on a small backing so it stays readable, only while the zoom has just changed.
		void DrawZoomReadout(GraphTab tab, ImDrawList* dl)
		{
			if (PinZoomReadout)
				tab.ZoomChangedTime = Gui.igGetTime(); // captures: the readout stays
			let a = ZoomReadoutAlpha((float)(Gui.igGetTime() - tab.ZoomChangedTime));
			if (a <= 0)
				return;
			Desktop.Wake(); // frames keep coming until it has faded (idle pacing stops after 1.2 s)
			String label = scope .();
			Canvas.ZoomLabel(tab.ZoomLevel, label);
			float s = Look.Scale;
			float ls = mFontSize * 1.25f;
			let tsz = Gui.CalcTextSize(label);
			let ts = ImVec2(tsz.x * 1.25f, tsz.y * 1.25f);
			let p0 = ImVec2(tab.CanvasOrigin.x + 12 * s, tab.CanvasOrigin.y + tab.CanvasSize.y - ts.y - 22 * s);
			let p1 = p0 + ImVec2(ts.x + 20 * s, ts.y + 10 * s);
			Gui.ImDrawList_AddRectFilled(dl, p0, p1, Theme.WithAlpha(Theme.CanvasBg, (uint8)(215 * a)), 5 * s, 0);
			Text(dl, p0 + ImVec2(10 * s, 5 * s), ls, Theme.WithAlpha(Look.Foreground, (uint8)(240 * a)), label);
		}

		void DrawWatermark(GraphTab tab, Sheet mg, ImDrawList* dl)
		{
			// The faint label in the bottom-right corner: "<Type> · <Sheet>" in the type's kind colour
			// (TypeStyle, DocumentHeader.bf), so the canvas itself says whose graph it is.
			String text = scope .();
			mg.Doc.GetName(text);
			text.AppendF("  \u{00B7}  {}", tab.Title);
			WatermarkText.Set(text);
			float size = mFontSize * 2.6f;
			let tw = Gui.CalcTextSize(text).x * 2.6f;
			let pos = tab.CanvasOrigin + tab.CanvasSize - ImVec2(tw + 28, size + 22);
			Text(dl, pos, size, Theme.WithAlpha(TypeStyle.KindColor(mg.Doc.Header.Kind), 46), text);
		}

		/// The watermark drawn last frame (the self test).
		public String WatermarkText = new .() ~ delete _;

		void DrawFindBox(GraphTab tab, Graph graph)
		{
			if (!tab.FindOpen)
				return;
			let origin = tab.CanvasOrigin;
			Gui.igSetCursorScreenPos(origin + ImVec2(12, 12 + mCrumbsH)); // under the breadcrumbs
			Gui.igPushStyleColor_U32(Col.ChildBg, Gui.Color(24, 24, 24, 240));
			var findText = mFindBuf.View;
			findText.Trim();
			float boxH = findText.IsEmpty ? (Gui.igGetFrameHeight() * 2 + 24) : Math.Min(320, tab.CanvasSize.y - 24);
			if (Gui.igBeginChild_Str("##vbfind", .(400, boxH), ChildFlags.Borders, 0))
			{
				Gui.TextColored(Gui.Color(220, 220, 220), "Find in Sheets");
				Gui.SameLine(Gui.igGetWindowSize().x - 30, -1);
				if (Gui.SmallButton("x"))
					tab.FindOpen = false;
				if (tab.FindFocus)
				{
					Gui.igSetKeyboardFocusHere(0);
					tab.FindFocus = false;
				}
				Gui.igSetNextItemWidth(-1);
				bool enter = Gui.igInputTextWithHint("##find", "Search nodes, names, values...", mFindBuf.Ptr, (.)mFindBuf.Capacity, InputTextFlags.EnterReturnsTrue, null, null);
				if (Gui.igIsItemActive() && Gui.IsKeyPressed(Key.Escape, false))
					tab.FindOpen = false;
				var search = mFindBuf.View;
				search.Trim();
				if (!search.IsEmpty && Gui.igBeginChild_Str("##results", .(0, 0), 0, 0))
				{
					int shown = 0;
					String hay = scope .();
					String title = scope .();
					for (let n in graph.Nodes)
					{
						hay.Clear();
						title.Clear();
						GetDisplayTitle(graph, n, title);
						hay.AppendF("{} {}", title, n.Text);
						for (let p in n.Inputs)
							hay.AppendF(" {} {}", p.Label, p.Default);
						for (let p in n.Outputs)
							hay.AppendF(" {}", p.Label);
						bool match = true;
						for (let word in search.Split(' '))
							if (!word.IsEmpty && hay.IndexOf(word, true) < 0)
								match = false;
						if (!match)
							continue;
						Gui.PushID(n.Id);
						String label = scope .();
						label.Append(title);
						let setTarget = (n.Kind == .Set) ? n.FindInput("receiver") : null;
						if (setTarget != null && !graph.IsLinked(setTarget))
							label.AppendF("  {}", setTarget.Default);
						else if (n.Kind == .Call)
							label.Append(n.IsPure ? "   (value call)" : "   (function call)");
						else if (n.Kind == .Get)
							label.Append("   (variable)");
						if (false)
						{
							label.Append(":  ");
							var first = StringView(n.Text);
							int nl = first.IndexOf('\n');
							if (nl >= 0)
								first = first.Substring(0, nl);
							label.Append(first);
						}
						if (Gui.Selectable(label, tab.IsSelected(n.Id)) || (enter && shown == 0))
						{
							tab.SelectOnly(n.Id);
							float w = 160;
							float h = 60;
							if (mLayById.TryGetValue(n.Id, let L))
							{
								w = L.W;
								h = L.H;
							}
							tab.CenterOn(n.X + w * 0.5f, n.Y + h * 0.5f);
						}
						Gui.PopID();
						if (++shown >= 200)
							break;
					}
					if (shown == 0)
						Gui.TextDisabled("No matching nodes.");
					Gui.igEndChild();
				}
			}
			Gui.igEndChild();
			Gui.igPopStyleColor(1);
		}

		/// UE-style tooltip for a node after hovering it for a moment.
		void NodeTooltip(GraphTab tab, Graph graph, Node node, String tip)
		{
			switch (node.Kind)
			{
			case .Call:
				let target = node.FindInput("receiver");
				// The signature from the node's pins (they follow the callee's declaration): return
				// type, owner and name, inputs, further outputs.
				let res = node.Result;
				let mref = Treadle.Model.MemberRef.Parse(node.Text);
				defer delete mref;
				String callee = scope .();
				if (mref.Owner == .Type && mref.Type != null)
				{
					mref.Type.ToString(callee);
					callee.Append('.');
				}
				callee.Append(mref.Name.IsEmpty ? (StringView)node.Text : (StringView)mref.Name);
				tip.AppendF("{}{} {}(", (target == null && mref.Owner == .Type) ? "static " : "", (res != null && !res.TypeName.IsEmpty) ? StringView(res.TypeName) : "void", callee);
				int i = 0;
				for (let p in node.Inputs)
				{
					if (p.Kind != .Value || p.Name == "receiver")
						continue;
					if (i++ > 0)
						tip.Append(", ");
					tip.AppendF("{}{}{}", p.TypeName, p.TypeName.IsEmpty ? "" : " ", p.Label);
				}
				tip.Append(")");
				int outs = 0;
				for (let p in node.Outputs)
				{
					if (p.Kind != .Value || p == res)
						continue;
					tip.Append((outs++ == 0) ? "\nAlso out: " : ", ");
					tip.AppendF("{}{}{}", p.TypeName, p.TypeName.IsEmpty ? "" : " ", p.Label);
				}
				if (target != null && !target.TypeName.IsEmpty)
					tip.AppendF("\nReceiver is {}{}", target.TypeName, IsSelfTarget(graph, target) ? " (this)" : "");
				else if (target != null && graph.IsLinked(target))
					tip.Append("\nReceiver is the wired object");
				tip.Append(node.IsPure ? "\nValue call (evaluated for each flow node that uses it)" : "");
			case .Get, .Set:
				let v = (node.Kind == .Get) ? node.FindOutput("value") : node.FindInput("value");
				tip.AppendF("{} {}\nType: {}", (node.Kind == .Get) ? "Get" : "Set", node.Text, (v != null && !v.TypeName.IsEmpty) ? StringView(v.TypeName) : "(unknown)");
			case .Branch:
				tip.Append("Branch: runs True when Condition is true, otherwise False");
			case .While:
				tip.Append("While Loop: runs Loop Body while Condition is true");
			case .DoWhile:
				tip.Append("Do While Loop: runs Loop Body, then repeats while Condition is true");
			case .For:
				tip.Append("For Loop: runs Loop Body Count times, Index from Start by Step");
			case .ForEach:
				tip.Append("For Each Loop: runs Loop Body once per element of Collection");
			case .Switch:
				tip.Append("Switch: runs the output of the case that matches Value, or Default");
			case .Sequence, .Gate, .DoOnce, .DoN, .FlipFlop, .MultiGate, .GateOpen, .GateClose, .GateToggle, .ResetDoOnce, .ResetDoN, .ResetMultiGate:
				FlowMacros.GetSummary(node, tip);
			case .Entry:
				tip.AppendF("{}(", graph.MethodName);
				int i = 0;
				for (let p in node.Outputs)
				{
					if (p.Kind != .Value)
						continue;
					if (i++ > 0)
						tip.Append(", ");
					tip.AppendF("{}{}{}", p.TypeName, p.TypeName.IsEmpty ? "" : " ", p.Label);
				}
				tip.Append(")");
			case .Cast:
				tip.AppendF("Cast To {}", node.Text);
			case .This:
				tip.AppendF("This: {}\nWire it into the Receiver to call a function on this object.", graph.SelfType);
			case .Base:
				tip.Append("Base: this object seen as its base class\nWire it into the Receiver to call the base version of a function.");
			case .Construct, .Local, .DeferDelete, .Defer, .Lambda, .Bind, .Scope, .Try:
				String sub = scope .();
				LifetimeSubtitle(node, sub);
				tip.AppendF("{}\n{}", tip.IsEmpty ? node.GetTitle(.. scope String()) : "", sub);
			case .Delete:
				tip.Append("Delete: runs the destructor and frees the object");
			case .ResultMatch:
				tip.Append("Result: match: runs Ok (with Value) or Err (with Error), then Completed");
			case .Math:
				tip.AppendF("Math Expression: {}\nEvery name in it is an input; Result is its value.", MathText(node, .. scope String()));

			case .ChainCtor:
				if (node.Text == "this")
					tip.AppendF("This Constructor\nRuns another constructor of {} first, then this one's body. Choose which in Properties.", graph.SelfType);
				else
					tip.Append("Base Constructor\nRuns a constructor of the base class first, then this one's body. Constructors are not inherited. Choose which in Properties.");
			case .Unknown:
				tip.AppendF("{}: a node kind of a newer format, kept as it is", node.KindWord ?? "");
			default:
			}
			if (node.Comment != null && !node.Comment.IsEmpty)
				tip.AppendF("\n\n{}", node.Comment);
		}

		// ------------------------------------------------------------------ variables

		/// A name for a new local that isn't used yet in this function.
		public static void UniqueLocalName(Sheet mg, StringView baseName, String outName)
		{
			HashSet<String> used = scope .();
			defer { for (let s in used) delete s; }
			if (mg != null)
			{
				if (mg.Graph.Entry != null)
					for (let p in mg.Graph.Entry.Outputs)
						if (p.Kind == .Value)
							used.Add(new String(p.Name));
				for (let l in mg.Graph.Locals)
					used.Add(new String(l.Name));
			}
			outName.Set(baseName);
			for (int i = 1; used.Contains(outName); i++)
			{
				outName.Set(baseName);
				outName.AppendF("{}", i);
			}
		}

		/// A variable dragged over a pin: a green ring when a drop there is taken, the refusal colour
		/// when not; the ghost's second line says what the drop does or why it is refused.
		void DrawDragPinHighlight(GraphTab tab, Graph graph, ImDrawList* dl, MemberRef m)
		{
			if (m.MemberKind != .Variable)
				return;
			let p = graph.FindPin(mHoverPin);
			if (p == null)
				return;
			if (!TryGetPin(p.Id, let pl))
				return;
			String why = scope .();
			bool ok = p.Kind == .Value && (p.TypeName.IsEmpty || m.Type.IsEmpty || mApp.Language.Types.CanConvert(p.IsInput ? m.Type : p.TypeName, p.IsInput ? p.TypeName : m.Type, why) != .Refused);
			float z = tab.Zoom;
			let c = PinScreen(tab, pl);
			uint32 col = ok ? Theme.Good : Theme.WireBad;
			float r = Math.Max(7, 10 * z);
			Gui.ImDrawList_AddCircleFilled(dl, c, r, Theme.WithAlpha(col, 70), 0);
			Gui.ImDrawList_AddCircle(dl, c, r, col, 0, Math.Max(1.5f, 2 * z));
			String hint = scope .();
			StringView label = p.Label.IsEmpty ? (p.IsInput ? "the input" : "the output") : StringView(p.Label);
			if (!ok)
				hint.Append(why.IsEmpty ? "Those pins can't be connected." : scope $"Can't connect: {why}");
			else if (p.IsInput)
				hint.AppendF("Get {} into {}{}", m.Name, label, graph.IsLinked(p) ? " (replaces its wire)" : "");
			else
				hint.AppendF("Set {} from {}", m.Name, label);
			mApp.SetGhostHint(hint, !ok);
		}

		/// Self test: where pin `pinId` was drawn last frame (screen), false when it was not.
		public bool PinScreenPos(GraphTab tab, int32 pinId, out ImVec2 outPos)
		{
			outPos = default;
			if (!TryGetPin(pinId, let pl))
				return false;
			outPos = PinScreen(tab, pl);
			return true;
		}

		/// A node placed for a variable dropped on `pin` goes beside it: a Get to the left of the
		/// input, a Set to the right of the output's node (snapped to the grid when snapping is on).
		public void PlaceBesidePin(GraphTab tab, Graph graph, Node n, Pin pin)
		{
			let owner = pin.Owner;
			// The new node's size before it is laid out: a Get is a pill with the name, a Set a small node.
			float z = Math.Max(0.1f, tab.Zoom);
			float nameW = Gui.CalcTextSize(n.Text.IsEmpty ? "value" : n.Text).x / z;
			float w = (n.Kind == .Get) ? nameW + 60 : Math.Max(180, nameW + 120);
			float h = (n.Kind == .Get) ? 32 : 96;
			if (pin.IsInput)
			{
				float rowY = TryGetPin(pin.Id, let pl) ? pl.Off.y : 40;
				n.X = Canvas.SnapIf(owner.X - w - 50);
				n.Y = Canvas.SnapIf(owner.Y + rowY - h * 0.5f);
			}
			else
			{
				float ow = mLayById.TryGetValue(owner.Id, let L) ? L.W : 200;
				n.X = Canvas.SnapIf(owner.X + ow + 60);
				n.Y = Canvas.SnapIf(owner.Y);
			}
			// Not on top of another node: moved down until it is clear (a few steps at most).
			for (int tries < 12)
			{
				bool hit = false;
				for (let o in graph.Nodes)
				{
					// Sizes from the last frame's layout (nodes it did not lay out yet are skipped).
					if (o == n)
						continue;
					if (!mLayById.TryGetValue(o.Id, let L))
						continue;
					if (n.X < o.X + L.W + 16 && n.X + w + 16 > o.X && n.Y < o.Y + L.H + 16 && n.Y + h + 16 > o.Y)
					{
						n.Y = Canvas.SnapIf(o.Y + L.H + 24);
						hit = true;
						break;
					}
				}
				if (!hit)
					break;
			}
			n.HasPos = true;
		}

		/// Called after a variable was dropped without Ctrl/Alt: offers Get / Set (UE).
		public void ShowVariableDropMenu(StringView name, StringView type, ImVec2 gridPos)
		{
			mVarDropOpen = true;
			mVarDropName.Set(name);
			mVarDropType.Set(type);
			mVarDropPos = gridPos;
		}

		/// Pin context menu: Make variable / Make local variable (an output: the variable and a Set
		/// fed by the pin) and Make variable (Get) (an input: the variable and a Get wired into it).
		/// One undo step; the local plus its Set.
		public void MakeVariableFromPin(GraphTab tab, Sheet mgIn, Pin pinIn, bool member)
		{
			var mg = mgIn;
			String type = scope .();
			String why = scope .();
			if (!mApp.PinVariableType(mg, pinIn, member, type, why))
			{
				Notify.Warn(why);
				return;
			}
			String baseName = scope .();
			PinVariableBase(pinIn, baseName);
			String name = scope .();
			let pinId = pinIn.Id;
			let graph = mg.Graph;
			if (member)
			{
				// The member first (its own text edit), then the nodes, merged into one undo step.
				// The edit reads the file again: the Sheet wrapper is replaced, the graph kept.
				let key = scope String(mg.Key);
				let doc = mg.Doc;
				if (!mApp.MakeMemberForPin(mg, baseName, type, name))
					return;
				mg = doc.FindSheet(key);
				if (mg == null || mg.Graph != graph)
				{
					Notify.Warn("The variable was added; the Sheet was read again, so place its Get / Set from the Node menu.");
					return;
				}
				mApp.BeginEdit();
				mg.Doc.DropLastUndo(); // one undo step with the member
			}
			else
			{
				mApp.BeginEdit();
				EditorApp.UniqueLocalName(mg, baseName, name);
				String value = scope .();
				NodeFactory.ReturnDefault(mApp.Language, type, value);
				NodeFactory.AddLocal(graph, name, type, value);
			}
			let pin = graph.FindPin(pinId);
			if (pin == null)
				return;
			// A static field is named through its type and has no Receiver (as the Node menu's rows make it).
			String variable = scope .(name);
			bool staticField = member && graph.StaticContext;
			if (staticField)
			{
				variable.Clear();
				mg.Doc.Header.GetFullName(variable);
				variable.AppendF(".{}", name);
			}
			if (!pin.IsInput)
			{
				PlaceSetFromPin(tab, mg, pin, variable, type, staticField);
				return;
			}
			let get = NodeFactory.Get(graph, variable, type);
			if (staticField && get.FindInput("receiver") != null)
				graph.RemovePin(get.FindInput("receiver"));
			graph.Connect(get.Result, pin);
			get.X = Canvas.Snap(pin.Owner.X - 220);
			get.Y = Canvas.Snap(pin.Owner.Y + 20);
			get.HasPos = true;
			tab.SelectOnly(get.Id);
			mApp.CommitCurrent();
			mCommitted = true;
		}

		/// A variable name made from a pin's label (`Return Value` -> `returnValue`), or `value`.
		public static void PinVariableBase(Pin pin, String outName) => VariableActions.VariableBase(pin, outName);

		/// The pin context menu's Make variable / Make local variable for a data output: a Set of
		/// `name` fed by the pin, inserted in the flow after the pin's node (or before the first
		/// statement that uses the value). The caller has taken the undo step and made the variable.
		void PlaceSetFromPin(GraphTab tab, Sheet mg, Pin pin, StringView name, StringView type, bool noReceiver = false)
		{
			let graph = mg.Graph;
			let owner = pin.Owner;
			let n = NodeFactory.Set(graph, name, type);
			if (noReceiver && n.FindInput("receiver") != null)
				graph.RemovePin(n.FindInput("receiver"));
			let value = n.FindInput("value");
			if (value != null)
				graph.Connect(pin, value);
			float w = mLayById.TryGetValue(owner.Id, let L) ? L.W : 200;
			n.X = Canvas.Snap(owner.X + w + 60);
			n.Y = Canvas.Snap(owner.Y);
			n.HasPos = true;
			// Where it runs: after an exec owner; for a pure owner, before the statement using it.
			let before = VariableActions.SpliceSet(graph, n, pin);
			if (before != null)
			{
				n.X = Canvas.Snap(before.X - 40);
				n.Y = Canvas.Snap(before.Y - 140);
			}
			tab.SelectOnly(n.Id);
			mApp.CommitCurrent();
			mCommitted = true;
		}

		/// The value an input pin goes back to with "Reset to Default".
		static void PinDefaultValue(Pin p, String outValue)
		{
			String t = scope .();
			NodeMenu.NormalizeType(p.TypeName, t);
			if (p.Owner.Kind == .Branch || p.Owner.Kind == .While || p.Owner.Kind == .DoWhile)
				outValue.Set("true");
			else if (t == "bool")
				outValue.Set("false");
			else if (t == "float")
				outValue.Set("0.0f");
			else if (t == "double")
				outValue.Set("0.0");
			else if (NodeMenu.IsNumeric(t))
				outValue.Set("0");
			else if (t == "String" || t == "StringView")
				outValue.Set("\"\"");
			else if (p.Optional || p.Name == "receiver")
				outValue.Clear();
			else
				outValue.Set("default");
		}

		uint32 HeaderFor(Graph g, Node node)
		{
			// An override's entry reads like UE's red event node (Event Tick).
			if (node == g.Entry && g.Member != null && g.Member.Override)
				return Theme.HeaderOverride;
			switch (node.Kind)
			{
			case .Set:
				let t = node.FindInput("receiver");
				let v = node.FindInput("value");
				StringView type = (t != null && !t.TypeName.IsEmpty) ? t.TypeName : ((v != null) ? v.TypeName : "");
				return Theme.VariableHeader(type);
			case .Get:
				return Theme.VariableHeader(node.Result?.TypeName ?? "");
			default:
				return PinStyle.Header(node);
			}
		}

		/// Width taken by the header icon (grid units at zoom 1); 0 without the icon font.
		float HeaderIconW(Node node) => (Icon.Loaded && !PinStyle.HeaderIcon(node).IsEmpty) ? mFontSize * 1.25f : 0;

		// ------------------------------------------------------------------ input

		void HandleMouse(GraphTab tab, Sheet mg, ImVec2 mouse, bool activated, bool mouseInCanvas)
		{
			let graph = mg.Graph;

			// ---- Press
			if (activated && tab.Mode == .None)
			{
				bool dbl = Gui.igIsMouseDoubleClicked_Nil(0);
				// A folded node group opens on a double-click; an unfolded one folds from its title bar.
				if (dbl && (mHoverNode < 0 || mHoverGroupFrame != 0))
				{
					tab.CancelInteraction();
					let gr = graph.FindGroup((mHoverNode < 0) ? mHoverNode : mHoverGroupFrame);
					if (gr != null)
						SetGroupCollapsed(tab, graph, gr, mHoverNode >= 0);
					return;
				}
				if (dbl && mHoverNode != 0)
				{
					tab.CancelInteraction();
					mApp.NodeDoubleClicked(graph.FindNode(mHoverNode));
					return;
				}
				if (dbl && mHoverLink != 0)
				{
					// UE: double-click a wire to add a reroute knot.
					tab.CancelInteraction();
					AddKnot(tab, graph, mHoverLink, mHoverLinkSegment, mouse);
					return;
				}
				if (dbl && mHoverComment != 0 && mHoverCommentResize == 0)
				{
					tab.CancelInteraction();
					tab.EditingComment = mHoverComment;
					mFocusCommentEdit = true;
					return;
				}
				if (Gui.igIsMouseClicked_Bool(0, false))
				{
					if (!BubblePress(tab, mg, mouse))
						PressLeft(tab, mg, mouse);
				}
				else if (Gui.igIsMouseClicked_Bool(1, false))
				{
					tab.Mode = .RightPending;
					tab.ModeButton = 1;
					tab.PressPos = mouse;
				}
				else if (Gui.igIsMouseClicked_Bool(2, false))
				{
					tab.Mode = .Pan;
					tab.ModeButton = 2;
					tab.PressPos = mouse;
				}
				if (mCommitted)
					return;
			}

			// ---- Marquee selection follows the mouse
			if (tab.Mode == .Marquee)
			{
				let a = ImVec2(Math.Min(tab.PressPos.x, mouse.x), Math.Min(tab.PressPos.y, mouse.y));
				let b = ImVec2(Math.Max(tab.PressPos.x, mouse.x), Math.Max(tab.PressPos.y, mouse.y));
				tab.SelectedNodes.Clear();
				tab.SelectedNodes.AddRange(tab.MarqueeBase);
				for (let L in mOrder)
				{
					let p0 = tab.GridToScreen(L.Node.X, L.Node.Y);
					let p1 = p0 + ImVec2(L.W, L.H) * tab.Zoom;
					if (Canvas.RectsOverlap(a, b, p0, p1))
						tab.AddToSelection(L.Node.Id);
				}
				// Comments are selected when the marquee encloses them completely.
				tab.SelectedComments.Clear();
				tab.SelectedComments.AddRange(tab.MarqueeCommentBase);
				for (let c in mComments)
				{
					let p0 = tab.GridToScreen(c.X, c.Y);
					let p1 = tab.GridToScreen(c.X + c.W, c.Y + c.H);
					if (p0.x >= a.x && p0.y >= a.y && p1.x <= b.x && p1.y <= b.y && !tab.SelectedComments.Contains(c.Id))
						tab.SelectedComments.Add(c.Id);
				}
				// Reroute nodes inside the box.
				tab.SelectedKnots.Clear();
				tab.SelectedKnots.AddRange(tab.MarqueeKnotBase);
				for (let route in mRoutes.Values)
					for (let pt in route.Points)
					{
						let c = tab.GridToScreen(pt.X, pt.Y);
						if (c.x >= a.x && c.x <= b.x && c.y >= a.y && c.y <= b.y)
							tab.AddKnot(.(route.FromPinId, route.ToPinId, (int32)@pt.Index));
					}
			}

			// ---- Node hotkeys while a wire is dragged: the node drops at the cursor, wired to the pin.
			if (tab.Mode == .Wire && mCanvasKeys && mouseInCanvas && WireHotkey(tab, mg, NodeHotkeyLetter(true), mouse))
				return;

			// ---- Release
			if (tab.Mode != .None && !Gui.igIsMouseDown_Nil(tab.ModeButton))
			{
				let mode = tab.Mode;
				let d = mouse - tab.PressPos;
				bool dragged = d.x * d.x + d.y * d.y > 16;
				switch (mode)
				{
				case .RightPending:
					tab.CancelInteraction();
					OpenContextMenu(tab, graph, mouse);
				case .MoveNodes:
					if (tab.Moved)
						mApp.LayoutChanged();
					else if (tab.PressNode != 0 && tab.PressNodeWasSelected && !Gui.IsCtrlDown && !Gui.IsShiftDown)
						tab.SelectOnly(tab.PressNode);
					else if (tab.PressKnot.IsValid && tab.PressKnotWasSelected && !Gui.IsCtrlDown && !Gui.IsShiftDown)
					{
						let k = tab.PressKnot;
						tab.ClearSelection();
						tab.AddKnot(k);
					}
					else if (tab.PressComment != 0 && tab.PressCommentWasSelected && !Gui.IsCtrlDown && !Gui.IsShiftDown)
					{
						tab.ClearSelection();
						tab.SelectedComments.Add(tab.PressComment);
					}
					tab.CancelInteraction();
				case .ResizeComment:
					if (dragged)
						mApp.LayoutChanged();
					tab.CancelInteraction();
				case .Wire:
					let src = graph.FindPin(tab.DragPin);
					let target = DropTarget(graph, src);
					tab.CancelInteraction();
					if (src == null)
						break;
					if (target != null)
						DropWire(mg, src, target);
					else if (mHoverPin != 0 && mHoverPin != src.Id)
					{
						String why = scope .();
						Graph.CanConnectTyped(mApp.Language, src, graph.FindPin(mHoverPin), why);
						mApp.SetStatus(why.IsEmpty ? "Those pins can't be connected." : scope $"Can't connect: {why}");
					}
					else if (dragged && mHoverNode == 0 && mHoverPin == 0 && mouseInCanvas)
						mApp.OpenNodeMenu(tab, tab.ScreenToGrid(mouse), src.Id);
				case .Relink:
					let target = (mHoverPin != 0) ? graph.FindPin(mHoverPin) : null;
					List<int32> ids = scope .();
					ids.AddRange(tab.DragLinks);
					int32 fromPin = tab.DragPin;
					tab.CancelInteraction();
					if (target == null || target.Id == fromPin)
						break;
					bool any = false;
					for (let id in ids)
					{
						let link = graph.FindLink(id);
						if (link == null)
							continue;
						let other = (link.From.Id == fromPin) ? link.To : link.From;
						if (!Graph.CanConnectTyped(mApp.Language, other, target) && !OverloadTakes(graph, other, target))
							continue;
						if (!any)
							mApp.BeginEdit();
						any = true;
						graph.Disconnect(link);
						graph.Connect(other, target);
						mApp.RefitCall(graph, target.IsInput ? target.Owner : other.Owner);
					}
					if (any)
					{
						mApp.CommitCurrent();
						mCommitted = true;
					}
					else
						mApp.SetStatus("Those links can't be moved to that pin.");
				default:
					tab.CancelInteraction();
				}
			}
		}

		/// A wire dropped from `src` on `target` (an output and an input, either way round): connected as one
		/// undo step. A call takes the overload that fits the value; a value that is not a variable dropped on a
		/// `ref` argument is stored in a new Local first (StoreRefInLocal: "Made the local variable value: ...").
		/// A variable still wires directly; with no place for the Local in the flow (the call is not wired in)
		/// the wire stays and the ref error shows; its Fix (Make local variable) appears once the node is in the flow.
		public void DropWire(Sheet mg, Pin src, Pin target)
		{
			let graph = mg.Graph;
			mApp.BeginEdit();
			if (src.IsInput)
				graph.Connect(target, src);
			else
				graph.Connect(src, target);
			// A call takes the overload that fits the value now wired into it.
			mApp.RefitCall(graph, (src.IsInput ? src : target).Owner);
			let refPin = graph.FindPin(src.IsInput ? src.Id : target.Id);
			if (refPin != null && refPin.IsRefArg && graph.IsLinked(refPin))
				mApp.StoreRefInLocal(mg, refPin, true, true);
			mApp.CommitCurrent();
			mCommitted = true;
		}

		/// A wire dropped from `src` on `target`: connected (DropWire) when the pins take it, else
		/// refused with the reason in the status bar and in `outWhy`. What a release over a pin does.
		public bool TryDropWire(Sheet mg, Pin src, Pin target, String outWhy)
		{
			String why = scope .();
			if (src == null || target == null || !(Graph.CanConnectTyped(mApp.Language, src, target, why) || OverloadTakes(mg.Graph, src, target)))
			{
				if (why.IsEmpty)
					why.Set("Those pins can't be connected.");
				outWhy?.Set(why);
				mApp.SetStatus(scope $"Can't connect: {why}");
				return false;
			}
			DropWire(mg, src, target);
			return true;
		}

		/// Starts a MoveNodes drag of the selection, plus everything inside selected comments.
		void BeginMoveSelection(GraphTab tab, Graph graph)
		{
			tab.Mode = .MoveNodes;
			tab.DragStart.Clear();
			tab.DragCommentStart.Clear();
			tab.DragKnotStart.Clear();
			List<int32> ids = scope .();
			ids.AddRange(tab.SelectedNodes);
			List<int32> commentIds = scope .();
			commentIds.AddRange(tab.SelectedComments);
			// Comments carry their contents (nodes and smaller comments inside them).
			for (int i = 0; i < commentIds.Count; i++)
			{
				let c = FindComment(commentIds[i]);
				if (c == null)
					continue;
				NodesInComment(c, ids);
				for (let other in mComments)
				{
					if (other == c || commentIds.Contains(other.Id))
						continue;
					if (other.X >= c.X && other.Y >= c.Y && other.X + other.W <= c.X + c.W && other.Y + other.H <= c.Y + c.H)
						commentIds.Add(other.Id);
				}
			}
			// A selected node group moves with its nodes (and its folded place).
			tab.DragGroupStart.Clear();
			for (let id in tab.SelectedNodes)
			{
				let gr = (id < 0) ? graph.FindGroup(id) : null;
				if (gr == null)
					continue;
				tab.DragGroupStart[id] = .(gr.X, gr.Y);
				for (let k in gr.Nodes)
				{
					let n = graph.FindNodeByKey(k);
					if (n != null && !ids.Contains(n.Id))
						ids.Add(n.Id);
				}
			}
			for (let id in ids)
			{
				let n = graph.FindNode(id);
				if (n != null)
					tab.DragStart[id] = .(n.X, n.Y);
			}
			for (let id in commentIds)
			{
				let c = FindComment(id);
				if (c != null)
					tab.DragCommentStart[id] = .(c.X, c.Y);
			}
			// Reroute nodes: the selected ones, and those inside a comment that moves.
			for (let route in mRoutes.Values)
				for (let pt in route.Points)
				{
					KnotRef k = .(route.FromPinId, route.ToPinId, (int32)@pt.Index);
					bool take = tab.IsKnotSelected(k);
					if (!take)
						for (let cid in commentIds)
						{
							let c = FindComment(cid);
							if (c != null && pt.X >= c.X && pt.Y >= c.Y && pt.X <= c.X + c.W && pt.Y <= c.Y + c.H)
							{
								take = true;
								break;
							}
						}
					if (take)
						tab.DragKnotStart.Add((k, ImVec2(pt.X, pt.Y)));
				}
		}

		/// This Sheet has the keyboard this frame (its window focused, no other item active).
		bool mCanvasKeys;

		/// Node hotkeys (docs/Editor-UI.md, "Node hotkeys and favorites"): the letter of a node hotkey
		/// that is held (`pressed`: pressed this frame) with no modifier key, '\0' when none. Only
		/// letters bound to a node count, so the Sheet's own letters (C, F, M, Q) never match.
		public char8 NodeHotkeyLetter(bool pressed)
		{
			if (Gui.IsCtrlDown || Gui.IsAltDown || Gui.IsShiftDown)
				return '\0';
			let hotkeys = mApp.NodePrefs.Hotkeys;
			for (int i < 26)
			{
				let letter = (char8)('A' + i);
				if (hotkeys.NodeOf(letter).IsEmpty)
					continue;
				let key = NodeMenu.cKeyA + (int32)i;
				if (pressed ? Gui.IsKeyPressed(key, false) : Gui.IsKeyDown(key))
					return letter;
			}
			return '\0';
		}

		/// Node hotkeys: a letter held while clicking empty canvas places its node at the click
		/// (B + click = Branch with the default keys). True when the click was taken.
		public bool HotkeyClick(GraphTab tab, Sheet mg, char8 letter, ImVec2 mouse)
		{
			if (letter == '\0')
				return false;
			if (mApp.PlaceHotkeyNode(tab, letter, tab.ScreenToGrid(mouse), 0))
				mCommitted = true;
			return true;
		}

		/// Node hotkeys: a letter pressed while a wire is dragged from a pin drops its node at
		/// `mouse`, connected to that pin the way the Node menu connects a node chosen there. True
		/// when the key was taken (the wire drag ends either way).
		public bool WireHotkey(GraphTab tab, Sheet mg, char8 letter, ImVec2 mouse)
		{
			if (letter == '\0' || tab.Mode != .Wire)
				return false;
			let src = mg.Graph.FindPin(tab.DragPin);
			tab.CancelInteraction();
			if (src != null && mApp.PlaceHotkeyNode(tab, letter, tab.ScreenToGrid(mouse), src.Id))
				mCommitted = true;
			return true;
		}

		void PressLeft(GraphTab tab, Sheet mg, ImVec2 mouse)
		{
			let graph = mg.Graph;
			tab.PressPos = mouse;
			tab.ModeButton = 0;
			tab.Moved = false;
			bool ctrl = Gui.IsCtrlDown;
			bool shift = Gui.IsShiftDown;
			bool alt = Gui.IsAltDown;

			if (mHoverPin != 0)
			{
				let pin = graph.FindPin(mHoverPin);
				if (pin == null)
					return;
				if (alt)
				{
					// Alt+click: break all of the pin's links.
					if (BreakPinLinks(graph, pin))
						mCommitted = true;
					return;
				}
				if (ctrl && graph.IsLinked(pin))
				{
					// Ctrl+drag: pick up the existing links and move them.
					tab.Mode = .Relink;
					tab.DragPin = pin.Id;
					tab.DragLinks.Clear();
					for (let l in graph.Links)
						if (l.From == pin || l.To == pin)
							tab.DragLinks.Add(l.Id);
					return;
				}
				tab.Mode = .Wire;
				tab.DragPin = pin.Id;
				return;
			}

			if (mHoverNode != 0)
			{
				int32 id = mHoverNode;
				tab.SelectedLinks.Clear();
				tab.PressNode = id;
				tab.PressNodeWasSelected = tab.IsSelected(id);
				if (ctrl)
				{
					tab.ToggleSelection(id);
					return;
				}
				if (shift)
					tab.AddToSelection(id);
				else if (!tab.IsSelected(id))
				{
					tab.SelectOnly(id);
				}
				BeginMoveSelection(tab, graph);
				return;
			}

			if (mHoverKnot.IsValid)
			{
				if (alt)
				{
					RemoveKnot(tab, mHoverKnot, true);
					return;
				}
				if (FindKnot(mHoverKnot) == null)
					return;
				// A reroute node selects and moves like a node: Ctrl toggles it, Shift adds it, and dragging a
				// selected one takes the whole selection along.
				let k = mHoverKnot;
				tab.SelectedLinks.Clear();
				tab.PressKnot = k;
				tab.PressKnotWasSelected = tab.IsKnotSelected(k);
				if (ctrl)
				{
					tab.ToggleKnot(k);
					return;
				}
				if (shift)
					tab.AddKnot(k);
				else if (!tab.IsKnotSelected(k))
				{
					tab.ClearSelection();
					tab.AddKnot(k);
				}
				BeginMoveSelection(tab, graph);
				return;
			}

			if (mHoverGroupFrame != 0)
			{
				// An unfolded group's title bar: selects the group (its nodes come along when it is dragged).
				int32 id = mHoverGroupFrame;
				tab.SelectedLinks.Clear();
				tab.PressNode = id;
				tab.PressNodeWasSelected = tab.IsSelected(id);
				if (ctrl)
				{
					tab.ToggleSelection(id);
					return;
				}
				if (shift)
					tab.AddToSelection(id);
				else if (!tab.IsSelected(id))
					tab.SelectOnly(id);
				BeginMoveSelection(tab, graph);
				return;
			}

			if (mHoverCommentResize != 0)
			{
				let c = FindComment(mHoverCommentResize);
				if (c == null)
					return;
				if (!tab.IsCommentSelected(c.Id))
				{
					tab.ClearSelection();
					tab.SelectedComments.Add(c.Id);
				}
				tab.Mode = .ResizeComment;
				tab.DragComment = c.Id;
				tab.DragVec = .(c.W, c.H);
				return;
			}

			if (mHoverLink != 0)
			{
				let link = graph.FindLink(mHoverLink);
				if (link == null)
					return;
				if (alt)
				{
					mApp.BeginEdit();
					graph.Disconnect(link);
					mApp.CommitCurrent();
					mCommitted = true;
					return;
				}
				// Select the wire (Delete removes it).
				if (!ctrl && !shift)
					tab.ClearSelection();
				if (!tab.SelectedLinks.Contains(link.Id))
					tab.SelectedLinks.Add(link.Id);
				return;
			}

			if (mHoverComment != 0)
			{
				// Comment title: select it; dragging moves it with everything inside.
				int32 id = mHoverComment;
				tab.SelectedLinks.Clear();
				tab.PressComment = id;
				tab.PressCommentWasSelected = tab.IsCommentSelected(id);
				if (ctrl)
				{
					if (!tab.SelectedComments.Remove(id))
						tab.SelectedComments.Add(id);
					return;
				}
				if (!tab.IsCommentSelected(id))
				{
					if (!shift)
						tab.ClearSelection();
					tab.SelectedComments.Add(id);
				}
				BeginMoveSelection(tab, graph);
				return;
			}

			// Empty space: a node hotkey held while clicking places its node, else marquee.
			if (!ctrl && !shift && !alt && HotkeyClick(tab, mg, NodeHotkeyLetter(false), mouse))
				return;
			tab.Mode = .Marquee;
			tab.MarqueeBase.Clear();
			tab.MarqueeCommentBase.Clear();
			tab.MarqueeKnotBase.Clear();
			if (ctrl || shift)
			{
				tab.MarqueeBase.AddRange(tab.SelectedNodes);
				tab.MarqueeCommentBase.AddRange(tab.SelectedComments);
				tab.MarqueeKnotBase.AddRange(tab.SelectedKnots);
			}
			else
				tab.ClearSelection();
		}

		void OpenContextMenu(GraphTab tab, Graph graph, ImVec2 mouse)
		{
			if (mHoverPin != 0)
			{
				tab.CtxPin = mHoverPin;
				// A struct pin's Break / Make row, looked up once while the menu is open.
				mApp.StructRowForPin(mApp.CurrentMethod, graph.FindPin(mHoverPin), mCtxStructKey, mCtxStructLabel);
				Gui.OpenPopup("##vbpinctx");
			}
			else if (mHoverNode < 0 || mHoverGroupFrame != 0)
			{
				// A node group (folded, or an unfolded one's title bar): its own menu.
				mCtxGroup = (mHoverNode < 0) ? mHoverNode : mHoverGroupFrame;
				if (!tab.IsSelected(mCtxGroup))
					tab.SelectOnly(mCtxGroup);
				Gui.OpenPopup("##vbgroupctx");
			}
			else if (mHoverNode != 0)
			{
				if (!tab.IsSelected(mHoverNode))
					tab.SelectOnly(mHoverNode);
				mApp.OpenNodeContext(mHoverNode);
			}
			else if (mHoverKnot.IsValid)
			{
				if (!tab.IsKnotSelected(mHoverKnot))
				{
					tab.ClearSelection();
					tab.AddKnot(mHoverKnot);
				}
				Gui.OpenPopup("##vbknotctx");
			}
			else if (mHoverLink != 0)
			{
				tab.CtxLink = mHoverLink;
				mCtxLinkSegment = mHoverLinkSegment;
				mCtxMouse = mouse;
				Gui.OpenPopup("##vblinkctx");
			}
			else if (mHoverComment != 0)
			{
				mCtxComment = mHoverComment;
				if (!tab.IsCommentSelected(mHoverComment))
				{
					tab.ClearSelection();
					tab.SelectedComments.Add(mHoverComment);
				}
				Gui.OpenPopup("##vbcommentctx");
			}
			else
				mApp.OpenNodeMenu(tab, tab.ScreenToGrid(mouse), 0);
		}
		int32 mCtxLinkSegment;
		ImVec2 mCtxMouse;
		String mCtxStructKey = new .() ~ delete _;
		String mCtxStructLabel = new .() ~ delete _;
		/// Captures: a pin whose menu opens on the next frame, and where the pin and node menus are put
		/// (x < -1e30 = at the pointer, as usual).
		public int32 SelfTestPinMenu;
		/// Captures: a node group whose menu opens on the next frame.
		public int32 SelfTestGroupMenu;
		public ImVec2 SelfTestPopupPos = .(-3e38f, -3e38f);

		void DrawContextPopups(GraphTab tab, Sheet mg)
		{
			let graph = mg.Graph;
			DrawGroupPopup(tab, mg);
			if (mCommitted)
				return;
			if (SelfTestPopupPos.x > -1e30f)
				Gui.igSetNextWindowPos(SelfTestPopupPos, Cond.Appearing, .(0, 0));
			if (Gui.BeginPopup("##vbpinctx"))
			{
				let pin = graph.FindPin(tab.CtxPin);
				if (pin == null)
					Gui.igCloseCurrentPopup();
				else
				{
					String head = scope .();
					head.Append(pin.Label.IsEmpty ? pin.Name : pin.Label);
					if (pin.Kind == .Value && !pin.TypeName.IsEmpty)
						head.AppendF("  ({})", pin.TypeName);
					Gui.TextDisabled(head);
					Gui.Separator();
					if (Gui.MenuItem("Break Link(s)", "Alt+Click", false, graph.IsLinked(pin)))
					{
						mApp.BeginEdit();
						graph.DisconnectPin(pin);
						mApp.CommitCurrent();
						mCommitted = true;
					}
					// Sequence / Multi Gate arms and Switch cases: the counterpart of the node's Add pin.
					if (EditorApp.IsRemovableExecPin(pin) && Gui.MenuItem((pin.Owner.Kind == .Switch) ? "Remove Case" : "Remove Pin"))
					{
						if (mApp.RemoveExecPin(pin))
							mCommitted = true;
					}
					// A struct pin: Split Struct Pin (one pin per field on this node), or Recombine on a split one.
					// A vector pin (float4): the same, its lanes as the fields (`v.x` ... `v.w`).
					if (SplitPins.IsSplit(pin) || SplitPins.IsSubPin(pin))
					{
						let parentName = SplitPins.ParentOf(pin);
						let parent = parentName.IsEmpty ? pin : (pin.IsInput ? pin.Owner.FindInput(parentName) : pin.Owner.FindOutput(parentName));
						let lanes = parent != null && Treadle.Model.VectorTypes.LanesOf(parent.TypeName) > 0;
						if (Gui.MenuItem(lanes ? "Recombine Vector Pin" : "Recombine Struct Pin"))
						{
							if (mApp.RecombineStructPin(mg, pin))
								mCommitted = true;
						}
						if (Gui.igIsItemHovered(0))
							Gui.Tooltip(lanes ? "The lane pins go (with their wires and values); the vector pin is shown again" : "The field pins go (with their wires and values); the struct pin is shown again");
					}
					else if (!mCtxStructKey.IsEmpty && pin.Name != "receiver")
					{
						let lanes = Treadle.Model.VectorTypes.LanesOf(pin.TypeName) > 0;
						if (Gui.MenuItem(lanes ? "Split Vector Pin" : "Split Struct Pin"))
						{
							if (mApp.SplitStructPin(mg, pin))
								mCommitted = true;
						}
						if (Gui.igIsItemHovered(0))
							Gui.Tooltip(lanes ? "One pin per lane on this node (x y z w; no Make / Break node); Recombine puts the vector pin back" : "One pin per field on this node (no Make / Break node); Recombine puts the struct pin back");
					}
					// A struct pin: the Break / Make node of its type, wired to it.
					if (!mCtxStructKey.IsEmpty && !SplitPins.IsSubPin(pin) && !SplitPins.IsSplit(pin))
					{
						if (Gui.MenuItem(pin.IsInput ? scope $"Make from Fields ({mCtxStructLabel})" : scope $"Break into Fields ({mCtxStructLabel})"))
						{
							if (mApp.PlaceRowFromPin(tab, mg, pin, mCtxStructKey) != null)
								mCommitted = true;
						}
						if (Gui.igIsItemHovered(0))
							Gui.Tooltip(pin.IsInput ? "A Make node wired into this pin: one input per field" : "A Break node fed by this pin: one output per field");
					}
					if (pin.Kind == .Value && pin.Owner != graph.Entry)
					{
						String type = scope .();
						String why = scope .();
						bool memberOk = mApp.PinVariableType(mg, pin, true, type, why);
						if (!pin.IsInput)
						{
							if (Gui.MenuItem("Make variable", "", false, memberOk))
								MakeVariableFromPin(tab, mg, pin, true);
							if (Gui.igIsItemHovered(1 << 10 /* AllowWhenDisabled */))
								Gui.Tooltip(memberOk ? scope $"A new {type} variable of this type (Outline > VARIABLES), set from this pin" : why);
							why.Clear();
							type.Clear();
							bool localOk = mApp.PinVariableType(mg, pin, false, type, why);
							if (Gui.MenuItem("Make local variable", "", false, localOk))
								MakeVariableFromPin(tab, mg, pin, false);
							if (Gui.igIsItemHovered(1 << 10 /* AllowWhenDisabled */))
								Gui.Tooltip(localOk ? scope $"A new {type} Local of {mg.Name} (Properties > Locals), set from this pin" : why);
						}
						else
						{
							if (Gui.MenuItem("Make variable (Get)", "", false, memberOk && !graph.IsLinked(pin)))
								MakeVariableFromPin(tab, mg, pin, true);
							if (Gui.igIsItemHovered(1 << 10 /* AllowWhenDisabled */))
								Gui.Tooltip(!memberOk ? why : (graph.IsLinked(pin) ? "This pin is already wired" : scope $"A new {type} variable of this type (Outline > VARIABLES), read into this pin (it starts at its default)"));
						}
					}
					if (pin.Kind == .Value && pin.IsInput)
					{
						String def = scope .();
						PinDefaultValue(pin, def);
						bool can = !graph.IsLinked(pin) && pin.Default != def;
						if (Gui.MenuItem("Reset to Default", def.IsEmpty ? "(empty)" : def, false, can))
						{
							mApp.BeginEdit();
							pin.Default.Set(def);
							mApp.CommitCurrent();
							mCommitted = true;
						}
					}
				}
				Gui.EndPopup();
			}
			if (mCommitted)
				return;
			if (Gui.BeginPopup("##vblinkctx"))
			{
				let link = graph.FindLink(tab.CtxLink);
				if (link == null)
					Gui.igCloseCurrentPopup();
				else
				{
					Gui.TextDisabled("Wire");
					Gui.Separator();
					if (Gui.MenuItem("Break This Link", "Alt+Click"))
					{
						mApp.BeginEdit();
						graph.Disconnect(link);
						mApp.CommitCurrent();
						mCommitted = true;
					}
					else if (Gui.MenuItem("Add Reroute Knot", "Double-Click"))
						AddKnot(tab, graph, link.Id, mCtxLinkSegment, mCtxMouse);
				}
				Gui.EndPopup();
			}
			if (mCommitted)
				return;
			if (Gui.BeginPopup("##vbknotctx"))
			{
				Gui.TextDisabled("Knot");
				Gui.Separator();
				bool many = tab.SelectedKnots.Count > 1;
				if (Gui.MenuItem(many ? "Remove Knots" : "Remove Knot", "Alt+Click", false, !tab.SelectedKnots.IsEmpty))
				{
					List<KnotRef> knots = scope .();
					knots.AddRange(tab.SelectedKnots);
					RemoveKnots(tab, knots, true);
				}
				if (Gui.MenuItem("Straighten", "Q", false, !tab.SelectedKnots.IsEmpty))
					mApp.AlignSelection(tab, .Straighten);
				Gui.EndPopup();
			}
			if (Gui.BeginPopup("##vbcommentctx"))
			{
				let c = FindComment(mCtxComment);
				if (c == null)
					Gui.igCloseCurrentPopup();
				else
				{
					Gui.TextDisabled("Comment");
					Gui.Separator();
					if (Gui.MenuItem("Rename", "Double-Click"))
					{
						tab.EditingComment = c.Id;
						mFocusCommentEdit = true;
					}
					Gui.TextColored(Theme.TextDim, "Color");
					Gui.igSetNextItemWidth(220 * Look.Scale);
					CommentColorEditor(c);
					Gui.Separator();
					if (Gui.MenuItem("Delete Comment", "Del"))
					{
						mApp.BeginEdit();
						List<int32> ids = scope .();
						ids.Add(c.Id);
						DeleteComments(tab, ids);
					}
				}
				Gui.EndPopup();
			}

			// Variable dropped from Outline without Ctrl/Alt: Get or Set?
			if (mVarDropOpen)
			{
				Gui.OpenPopup("##vbvardrop");
				mVarDropOpen = false;
			}
			if (Gui.BeginPopup("##vbvardrop"))
			{
				int choice = 0;
				if (Gui.MenuItem(scope $"Get {mVarDropName}", "Ctrl+Drag"))
					choice = 1;
				if (Gui.MenuItem(scope $"Set {mVarDropName}", "Alt+Drag"))
					choice = 2;
				if (choice != 0)
				{
					mApp.BeginEdit();
					let n = (choice == 1) ? NodeFactory.Get(graph, mVarDropName, mVarDropType) : NodeFactory.Set(graph, mVarDropName, mVarDropType);
					n.X = Canvas.SnapIf(mVarDropPos.x);
					n.Y = Canvas.SnapIf(mVarDropPos.y);
					n.HasPos = true;
					tab.SelectOnly(n.Id);
					mApp.CommitCurrent();
					mCommitted = true;
					Gui.igCloseCurrentPopup();
				}
				Gui.EndPopup();
			}
		}

		void HandleKeyboard(GraphTab tab, Sheet mg)
		{
			bool windowFocused = Gui.igIsWindowFocused(FocusedFlags.RootAndChildWindows);
			if (!windowFocused || Gui.igIsAnyItemActive())
				return;
			if (Gui.IsKeyPressed(Key.Delete, false) || (Gui.IsKeyPressed(Key.Backspace, false) && !Gui.IsCtrlDown))
			{
				// Comments and knots are layout: removed here; nodes and wires by the app.
				List<int32> comments = scope .();
				comments.AddRange(tab.SelectedComments);
				List<KnotRef> knots = scope .();
				knots.AddRange(tab.SelectedKnots);
				bool graphSel = !tab.SelectedNodes.IsEmpty || !tab.SelectedLinks.IsEmpty;
				if (!graphSel && (!comments.IsEmpty || !knots.IsEmpty))
					mApp.BeginEdit();
				if (graphSel)
				{
					mApp.DeleteSelection(tab);
					mCommitted = true;
				}
				if (!comments.IsEmpty)
					DeleteComments(tab, comments);
				if (!knots.IsEmpty)
					RemoveKnots(tab, knots, false);
				return;
			}
			if (Gui.IsCtrlDown && Gui.IsKeyPressed(Key.D, false))
			{
				mApp.DuplicateSelection(tab);
				mCommitted = true;
				return;
			}
			if (Gui.IsCtrlDown && Gui.IsKeyPressed(Key.C, false))
				mApp.CopySelection(tab);
			if (Gui.IsCtrlDown && Gui.IsKeyPressed(Key.V, false))
			{
				let mp = Gui.igGetMousePos();
				bool inCanvas = Canvas.RectContains(tab.CanvasOrigin, tab.CanvasOrigin + tab.CanvasSize, mp);
				mApp.Paste(tab, inCanvas ? MouseGridPos(tab) : mApp.ViewCentre(tab));
				mCommitted = true;
				return;
			}
			if (Gui.IsCtrlDown && Gui.IsKeyPressed(Key.A, false))
			{
				tab.ClearSelection();
				for (let n in mg.Graph.Nodes)
					tab.SelectedNodes.Add(n.Id);
				for (let c in mComments)
					tab.SelectedComments.Add(c.Id);
				for (let route in mRoutes.Values)
					for (let pt in route.Points)
						tab.AddKnot(.(route.FromPinId, route.ToPinId, (int32)@pt.Index));
			}
			// Ctrl+G: Collapse Nodes (the selection folds into one group node; a double-click opens it).
			if (Gui.IsCtrlDown && !Gui.IsShiftDown && !Gui.IsAltDown && Gui.IsKeyPressed(KeyX.G, false))
			{
				if (mApp.CollapseSelectionToGroup(tab))
					mCommitted = true;
				return;
			}
			// Ctrl+Shift+E: Extract to Function (the selection becomes a new function and a Call of it).
			if (Gui.IsCtrlDown && Gui.IsShiftDown && !Gui.IsAltDown && Gui.IsKeyPressed(KeyX.E, false))
			{
				if (mApp.ExtractToFunction(tab))
					mCommitted = true;
				return;
			}
			// UE: C wraps the selection in a comment box (or drops one at the mouse).
			if (!Gui.IsCtrlDown && !Gui.IsAltDown && Gui.IsKeyPressed(Key.C, false))
				CreateComment(tab, mg.Graph);
			// Ctrl+F: find in this Sheet (Ctrl+Shift+F is Find in Sheets, the whole project: EditorApp).
			if (Gui.IsCtrlDown && !Gui.IsShiftDown && Gui.IsKeyPressed(Key.F, false))
			{
				tab.FindOpen = true;
				tab.FindFocus = true;
				return;
			}
			// Home: the whole Sheet in view (the canvas's home button goes to the entry node).
			if (!Gui.IsCtrlDown && Gui.IsKeyPressed(Key.Home, false))
				FitAll(tab, mg.Graph);
			// F2: rename what is selected (a comment box, a variable / function / local node, or this function).
			if (!Gui.IsCtrlDown && !Gui.IsAltDown && !Gui.IsShiftDown && Gui.IsKeyPressed(573 /* F2 */, false))
			{
				mApp.RenameSelection(tab);
				return;
			}
			if (!Gui.IsAltDown && !Gui.IsShiftDown)
				for (int n = 1; n <= 9; n++)
					if (Gui.IsKeyPressed(KeyDigit0 + (int32)n, false))
					{
						if (Gui.IsCtrlDown)
							SaveView(tab, n);
						else
							JumpToView(tab, n);
					}
			// UE alignment shortcuts: Shift+W/S/A/D, Alt+Shift+W/S (middle / center),
			// Alt+Shift+H/V (distribute), Q (straighten). M toggles the minimap.
			bool sh = Gui.IsShiftDown;
			bool alt = Gui.IsAltDown;
			if (!Gui.IsCtrlDown)
			{
				if (sh && !alt && Gui.IsKeyPressed(KeyX.W, false)) mApp.AlignSelection(tab, .Top);
				if (sh && !alt && Gui.IsKeyPressed(Key.S, false)) mApp.AlignSelection(tab, .Bottom);
				if (sh && !alt && Gui.IsKeyPressed(Key.A, false)) mApp.AlignSelection(tab, .Left);
				if (sh && !alt && Gui.IsKeyPressed(Key.D, false)) mApp.AlignSelection(tab, .Right);
				if (sh && alt && Gui.IsKeyPressed(KeyX.W, false)) mApp.AlignSelection(tab, .Middle);
				if (sh && alt && Gui.IsKeyPressed(Key.S, false)) mApp.AlignSelection(tab, .Center);
				if (sh && alt && Gui.IsKeyPressed(KeyX.H, false)) mApp.AlignSelection(tab, .DistributeH);
				if (sh && alt && Gui.IsKeyPressed(Key.V, false)) mApp.AlignSelection(tab, .DistributeV);
				if (!sh && !alt && Gui.IsKeyPressed(KeyX.Q, false)) mApp.AlignSelection(tab, .Straighten);
				// L: a new Local of this function, its name focused in Properties > Locals.
				if (!sh && !alt && Gui.IsKeyPressed(KeyX.L, false))
					mApp.AddLocalFromKey(tab, mg);
				if (!sh && !alt && Gui.IsKeyPressed(KeyX.M, false))
				{
					Prefs.ShowMinimap = !Prefs.ShowMinimap;
					Prefs.Save();
				}
			}
			if (!Gui.IsCtrlDown && Gui.IsKeyPressed(Key.F, false))
				FrameNodes(tab, mg.Graph, !tab.SelectedNodes.IsEmpty);
		}

		/// Zooms (up to 1:1) and pans so the selection, or the whole graph, fits the canvas.
		public void FrameNodes(GraphTab tab, Graph graph, bool selectedOnly)
		{
			float minX = float.MaxValue;
			float minY = float.MaxValue;
			float maxX = float.MinValue;
			float maxY = float.MinValue;
			for (let n in graph.Nodes)
			{
				if (selectedOnly && !tab.IsSelected(n.Id))
					continue;
				if (!mLayById.TryGetValue(n.Id, let L))
					continue;
				minX = Math.Min(minX, n.X);
				minY = Math.Min(minY, n.Y);
				maxX = Math.Max(maxX, n.X + L.W);
				maxY = Math.Max(maxY, n.Y + L.H);
			}
			if (minX > maxX)
				return;
			const float Margin = 60;
			float w = (maxX - minX) + Margin * 2;
			float h = (maxY - minY) + Margin * 2;
			float fit = Math.Min(tab.CanvasSize.x / w, tab.CanvasSize.y / h);
			tab.ZoomLevel = Math.Min(Canvas.LevelAtOrBelow(fit), Canvas.DefaultZoomLevel);
			tab.ZoomChangedTime = Gui.igGetTime();
			tab.CenterOn((minX + maxX) * 0.5f, (minY + maxY) * 0.5f);
			tab.ApplyPendingCenter();
		}

		/// Grid-space position of the mouse in the current editor.
		public ImVec2 MouseGridPos(GraphTab tab)
		{
			return tab.ScreenToGrid(Gui.igGetMousePos());
		}

		/// Must be called right after the canvas item. The drop is applied after drawing.
		void HandleDragDrop(GraphTab tab)
		{
			if (Gui.igBeginDragDropTarget())
			{
				let payload = Gui.igAcceptDragDropPayload("TREADLE_MEMBER", 0);
				if (payload != null)
				{
					DropsSeen++;
					// The pin the ring was on when the button came up (last frame's hover).
					mPendingDropPin = mHoverPin;
					mPendingDrop = *(int32*)payload.Data;
					mHasPendingDrop = true;
					mPendingDropPos = MouseGridPos(tab);
				}
				Gui.igEndDragDropTarget();
			}
		}
	}
}
