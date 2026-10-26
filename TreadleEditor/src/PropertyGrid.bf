using System;
using System.Collections;
using ImGui;

namespace Treadle.Editor
{
	/// The one panel layout of every details-style surface (Properties, Project Settings, Type Settings,
	/// Local variables, Editor Preferences, the Add dialogs): labels on the left, values on the right,
	/// one label column per panel, a label or value that does not fit ends in "..." with the whole text
	/// in the tooltip, and every size follows `Look.Scale`.
	///
	///     if (PropertyGrid.Begin("##props")) {
	///         if (PropertyGrid.Section("Node")) {
	///             PropertyGrid.TextRow("Function", "##fn", text, ?, "The function this node calls");
	///             PropertyGrid.CheckRow("Null-conditional (?.)", "##nc", ref on);
	///         }
	///         PropertyGrid.End();
	///     }
	///
	/// This file is the layout and the value widgets; the row kinds (text, checkbox, dropdown, path,
	/// number, lines, read-only, button, note) are in PropertyRows.bf, the rows that need the editor (type
	/// and literal values, parameter lists) in PropertyAppRows.bf. `Row` starts a row of any other kind:
	/// the label is drawn and the value column is ready for whatever the caller puts there.
	static class PropertyGrid
	{
		/// The label column's share of a panel's width (the user can drag it; one column per panel).
		public const float NameWeight = 0.45f;
		/// A label is indented to sit under the text of its section bar.
		const float cLabelIndent = 14;

		static bool sCategoryOpen = true;
		static TextBuffer sText = new .(4096) ~ delete _;

		static String sId = new .() ~ delete _;
		static float sNameWeight;
		static float sWidth;
		static float sIndent;
		/// The table is ended while a full-width row draws (see WideRow); the next row resumes it.
		static bool sSuspended;

		/// The monospace font of `mono` fields (set by the editor once the host has loaded it).
		public static ImFont* MonoFont;

		// ---- Keyboard navigation across rows: Up / Down in a text field moves to the widget of the row above /
		// below (Tab and the arrow keys already do for the other widgets). The widget ids of each panel's last
		// frame are kept, in drawing order.
		[CLink] static extern void igSetFocusID(uint32 id, void* window);
		[CLink] static extern void* igGetCurrentWindow();
		[CLink] static extern void igClearActiveID();
		[CLink] static extern void igSetNavCursorVisible(bool visible);
		/// The widget to focus at the start of the next frame (set while a text field was left with Up / Down).
		static uint32 sPendingFocus;

		static Dictionary<String, List<uint32>> sRowIds = new .() ~ { for (let kv in _) { delete kv.key; delete kv.value; } delete _; };
		static List<uint32> sFrameIds = new .() ~ delete _;
		static bool sTracking;

		/// Remembers the widget just drawn as the focus target of its row.
		static void Track()
		{
			if (!sTracking)
				return;
			let id = Gui.igGetItemID();
			if (id != 0 && (sFrameIds.IsEmpty || sFrameIds.Back != id))
				sFrameIds.Add(id);
		}

		/// Up / Down while a text field is being edited: leaves it (the edit is kept) and puts the keyboard
		/// focus on the widget of the neighbouring row (Enter edits it, the arrows go on).
		static void NavigateFromText()
		{
			if (!sTracking || !Gui.igIsItemActive())
				return;
			bool down = Gui.IsKeyPressed(Key.DownArrow, false);
			if (!down && !Gui.IsKeyPressed(Key.UpArrow, false))
				return;
			if (!sRowIds.TryGetValueAlt(sId, let list))
				return;
			let self = Gui.igGetItemID();
			int at = list.IndexOf(self);
			int to = down ? at + 1 : at - 1;
			if (at < 0 || to < 0 || to >= list.Count)
				return;
			igClearActiveID();
			sPendingFocus = list[to];
		}

		static bool BeginTable()
		{
			int32 flags = TableFlags.Resizable | TableFlags.BordersInnerV | TableFlags.BordersInnerH | TableFlags.SizingStretchProp | TableFlags.NoPadOuterX;
			// Same id on every resume: ImGui keeps the column widths of all instances in sync.
			if (!Gui.igBeginTable(sId, 2, flags, .(sWidth, 0), 0))
				return false;
			Gui.igTableSetupColumn("Name", TableColumnFlags.WidthStretch, sNameWeight, 0);
			Gui.igTableSetupColumn("Value", TableColumnFlags.WidthStretch, 1 - sNameWeight, 0);
			return true;
		}

		static void Resume()
		{
			if (!sSuspended)
				return;
			sSuspended = false;
			BeginTable();
		}

		/// Starts a panel. `id` is the panel's table id: every page of one panel uses the same one, so its
		/// label column stays where the user put it. `width` > 0 is a fixed panel width (a dialog);
		/// `sections` false when the panel has no section bars (the labels then sit nearer the edge).
		public static bool Begin(StringView id, float nameWeight = NameWeight, float width = 0, bool sections = true)
		{
			Gui.igPushStyleVar_Vec2(StyleVar.ItemSpacing, .(6 * Look.Scale, 2 * Look.Scale));
			Gui.igPushStyleColor_U32(ColX.TableBorderLight, Gui.Color(20, 20, 20));
			sId.Set(id);
			sNameWeight = nameWeight;
			sWidth = width;
			sIndent = (sections ? cLabelIndent : 4) * Look.Scale;
			sSuspended = false;
			if (!BeginTable())
			{
				Gui.igPopStyleColor(1);
				Gui.igPopStyleVar(1);
				return false;
			}
			sCategoryOpen = true;
			sTracking = true;
			sFrameIds.Clear();
			if (sPendingFocus != 0)
			{
				// One frame after the key press, so the arrow that left the text field is not also a navigation step.
				igSetFocusID(sPendingFocus, igGetCurrentWindow());
				igSetNavCursorVisible(true);
				sPendingFocus = 0;
			}
			return true;
		}

		public static void End()
		{
			if (!sSuspended)
				Gui.igEndTable();
			sSuspended = false;
			if (sTracking)
			{
				sTracking = false;
				List<uint32> list = null;
				if (!sRowIds.TryGetValueAlt(sId, out list))
				{
					list = new .();
					sRowIds[new String(sId)] = list;
				}
				list.Clear();
				list.AddRange(sFrameIds);
			}
			Gui.igPopStyleColor(1);
			Gui.igPopStyleVar(1);
		}

		/// A collapsible section bar across both columns; ImGui remembers whether it is open (by its name,
		/// in the panel's window). Returns whether it is open; rows of a closed section must be skipped by
		/// the caller. Self-test captures: the section with this name is drawn open.
		public static String ForceOpen = new .() ~ delete _;
		/// Self-test captures: the sections whose names start with one of these (`;` separated) are drawn closed.
		public static String ForceClosed = new .() ~ delete _;

		public static bool Section(StringView name, bool defaultOpen = true, StringView icon = default)
		{
			Resume();
			Gui.igTableNextRow(0, Gui.igGetFrameHeight() + 2 * Look.Scale);
			Gui.igTableSetBgColor(TableBgTarget.RowBg0, Look.Header, -1);
			Gui.igTableSetColumnIndex(0);
			Gui.igPushStyleColor_U32(Col.Header, Gui.Color(0, 0, 0, 0));
			Gui.igPushStyleColor_U32(Col.HeaderHovered, Gui.Color(255, 255, 255, 10));
			Gui.igPushStyleColor_U32(Col.HeaderActive, Gui.Color(255, 255, 255, 18));
			Gui.igPushStyleColor_U32(Col.Text, Gui.Color(220, 220, 220));
			String label = scope .();
			if (!icon.IsEmpty)
				label.AppendF("{}  ", icon);
			label.Append(name);
			int32 flags = TreeNodeFlagsX.SpanAllColumns | TreeNodeFlagsX.LabelSpanAllColumns | TreeNodeFlags.NoTreePushOnOpen | TreeNodeFlagsX.FramePadding;
			if (defaultOpen)
				flags |= TreeNodeFlags.DefaultOpen;
			if (!ForceOpen.IsEmpty && ForceOpen == name)
				Gui.igSetNextItemOpen(true, Cond.Always);
			for (let closed in ForceClosed.Split(';', .RemoveEmptyEntries))
				if (name.StartsWith(closed))
					Gui.igSetNextItemOpen(false, Cond.Always);
			sCategoryOpen = Gui.TreeNode(label, flags);
			Gui.igPopStyleColor(4);
			return sCategoryOpen;
		}

		/// Starts a row of any kind: the label is drawn in the left column (cut with "..." and the whole
		/// text in the tooltip when it does not fit, `tip` below it) and the value column is ready, the
		/// next item sized to fill it. `swatch` puts a type-colour pill in front of the label.
		public static void Row(StringView name, StringView tip = default, uint32 swatch = 0)
		{
			BeginRow();
			Label(name, tip, swatch);
			ValueCell();
		}

		/// A row of custom content: row started, column 0 current (a name box in the label column, say).
		public static void BeginRow()
		{
			Resume();
			Gui.igTableNextRow(0, 0);
			Gui.igTableSetColumnIndex(0);
		}

		/// The indented label of the current row (the caller is in column 0).
		static void Label(StringView name, StringView tip, uint32 swatch)
		{
			Gui.igAlignTextToFramePadding();
			Gui.igIndent(sIndent);
			float avail = Gui.igGetContentRegionAvail().x;
			if (swatch != 0)
			{
				// Type colour pill in front of the name (pins, variables).
				let p = Gui.igGetCursorScreenPos();
				float h = Gui.igGetFrameHeight();
				Gui.ImDrawList_AddRectFilled(Gui.igGetWindowDrawList(), .(p.x, p.y + h * 0.32f), .(p.x + 12 * Look.Scale, p.y + h * 0.68f), swatch, 4 * Look.Scale, 0);
				Gui.igSetCursorScreenPos(.(p.x + 18 * Look.Scale, p.y));
				Gui.igAlignTextToFramePadding();
				avail -= 18 * Look.Scale;
			}
			String shown = scope .();
			// The column clips at its border, not at the cell padding: a label that just fits is not cut.
			bool cut = Look.EllipsizeEnd(name, avail + Gui.igGetStyle().CellPadding.x - 1 * Look.Scale, shown);
			Gui.Text(shown);
			if ((cut || !tip.IsEmpty) && Gui.igIsItemHovered(0))
			{
				if (cut && !tip.IsEmpty)
					Gui.Tooltip(scope $"{name}\n{tip}");
				else
					Gui.Tooltip(cut ? name : tip);
			}
			Gui.igUnindent(sIndent);
		}

		/// Moves to the value column of the current row, the next item sized to fill it.
		public static void ValueCell()
		{
			Gui.igTableSetColumnIndex(1);
			Gui.igSetNextItemWidth(-1);
		}

		/// A full-width row for content such as a code block or buttons: the grid is paused (the
		/// content spans the whole panel, indented) and resumes at the next Row / Section.
		public static void WideRow()
		{
			Resume();
			Gui.igEndTable();
			sSuspended = true;
			Gui.igDummy(.(0, 1));
			Gui.igSetCursorPosX(Gui.igGetCursorPosX() + 6 * Look.Scale);
		}

		// ---- Value widgets (call after Row, or use the row kinds of PropertyRows.bf). Each returns true when the value was committed.

		/// The next Text field takes the keyboard (F2 renames through the Name row).
		public static bool FocusNext;

		/// Text field bound to `value`; `changed` reports live edits, the result the commit.
		public static bool Text(StringView id, String value, out bool changed, bool mono = false, ImFont* monoFont = null, StringView hint = default)
		{
			if (FocusNext)
			{
				FocusNext = false;
				Gui.igSetKeyboardFocusHere(0);
			}
			sText.Set(value);
			let font = (monoFont != null) ? monoFont : MonoFont;
			bool useMono = mono && font != null;
			if (useMono)
				Gui.igPushFont(font, 0);
			if (hint.IsEmpty)
				changed = Gui.igInputText(scope String(id), sText.Ptr, (.)sText.Capacity, 0, null, null);
			else
				changed = Gui.igInputTextWithHint(scope String(id), scope String(hint), sText.Ptr, (.)sText.Capacity, 0, null, null);
			if (useMono)
				Gui.igPopFont();
			Track();
			NavigateFromText();
			if (changed)
				value.Set(sText.View);
			return Gui.igIsItemDeactivatedAfterEdit();
		}

		public static bool Multiline(StringView id, String value, float height, out bool changed, ImFont* monoFont = null)
		{
			sText.Set(value);
			if (monoFont != null)
				Gui.igPushFont(monoFont, 0);
			changed = Gui.igInputTextMultiline(scope String(id), sText.Ptr, (.)sText.Capacity, .(Gui.igGetContentRegionAvail().x - 6 * Look.Scale, height), InputTextFlags.AllowTabInput, null, null);
			if (monoFont != null)
				Gui.igPopFont();
			if (changed)
				value.Set(sText.View);
			return Gui.igIsItemDeactivatedAfterEdit();
		}

		public static bool Bool(StringView id, ref bool value)
		{
			bool clicked = Gui.igCheckbox(scope String(id), &value);
			Track();
			return clicked;
		}

		/// Numeric drag with a unit suffix ("%.0f px"); commits on release.
		public static bool Float(StringView id, ref float value, float speed, float min, float max, StringView format = "%.2f")
		{
			Gui.igDragFloat(scope String(id), &value, speed, min, max, scope String(format), SliderFlags.AlwaysClamp);
			Track();
			return Gui.igIsItemDeactivatedAfterEdit();
		}

		public static bool Int(StringView id, ref int32 value, float speed, int32 min, int32 max, StringView format = "%d")
		{
			Gui.igDragInt(scope String(id), &value, speed, min, max, scope String(format), SliderFlags.AlwaysClamp);
			Track();
			return Gui.igIsItemDeactivatedAfterEdit();
		}

		/// Read-only explanatory text (dimmed) that wraps inside its column instead of being cut.
		public static void WrappedValue(StringView text)
		{
			Gui.igPushTextWrapPos(0);
			Gui.TextColored(Look.ForegroundDim, text);
			Gui.igPopTextWrapPos();
		}

		/// Read-only value text (dimmed).
		public static void Value(StringView text, uint32 color = 0)
		{
			Gui.igAlignTextToFramePadding();
			// A value wider than its column is cut by the column: the whole text is the tooltip.
			// A path is cut in the middle with "..." (its start and its last part stay readable).
			String shown = scope .();
			bool cut = Look.EllipsizeMiddle(text, Gui.igGetContentRegionAvail().x, shown);
			Gui.TextColored(color != 0 ? color : Look.ForegroundDim, shown);
			if (cut && Gui.igIsItemHovered(0))
				Gui.Tooltip(text);
		}
	}
}
