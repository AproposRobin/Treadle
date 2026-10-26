using System;
using System.Collections;
using ImGui;

namespace Treadle.Editor
{
	/// One option of a dropdown: its label, what it means (shown as a tooltip while the pointer is on it)
	/// and, when it cannot be picked now, why (the option is greyed and the reason is its tooltip).
	struct DropItem
	{
		public StringView Label;
		public StringView Tip;
		public StringView Disabled;
		public StringView Icon;

		public this(StringView label, StringView tip = default, StringView disabled = default, StringView icon = default)
		{
			Label = label;
			Tip = tip;
			Disabled = disabled;
			Icon = icon;
		}
	}

	/// One entry of a list of checkboxes (dependencies, modifiers).
	struct CheckItem
	{
		public StringView Label;
		public StringView Tip;
		public bool On;

		public this(StringView label, bool on, StringView tip = default)
		{
			Label = label;
			On = on;
			Tip = tip;
		}
	}

	/// The row kinds of the property grid. Every one draws its label in the left column and its value in
	/// the right one (see PropertyGrid.bf), takes an optional tooltip for the label and an optional
	/// `problem` (the validation hint: the field gets a red frame and the reason sits under it), and
	/// returns true when the user committed a change. Rows that need the editor (types, literal values,
	/// parameter lists) are in PropertyAppRows.bf.
	extension PropertyGrid
	{
		/// Self test: the dropdown with this id opens on its next draw / closes while open; how many options
		/// the last open list had.
		public static String TestOpen = new .() ~ delete _;
		public static bool TestClose;
		public static int TestRows;

		// ------------------------------------------------------------------ boxes and dropdowns

		/// The closed box of a dropdown or picker, at the cursor: a text (cut with "..." when it is wider
		/// than the box), an optional type-colour pill or icon in front and the chevron behind. Returns true
		/// when it was clicked. The caller has pushed an ID. The tooltip is `tip`, with the whole text
		/// first when it was cut (or when `textInTip`).
		public static bool Box(StringView text, float width, uint32 pill = 0, StringView icon = default, StringView tip = default, bool textInTip = false, uint32 fill = 0)
		{
			float h = Gui.igGetFrameHeight();
			let start = Gui.igGetCursorScreenPos();
			Gui.igPushStyleColor_U32(Col.Button, (fill != 0) ? fill : Look.Input);
			Gui.igPushStyleColor_U32(Col.ButtonHovered, Gui.Color(30, 30, 30));
			Gui.igPushStyleVar_Vec2(StyleVarX.ButtonTextAlign, .(0, 0.5f));
			String lead = scope .();
			if (pill != 0)
				lead.Set("      ");
			else if (!icon.IsEmpty)
				lead.AppendF("  {}  ", icon);
			// The text takes what the pill on the left and the chevron on the right leave.
			float textW = width - Gui.CalcTextSize(lead).x - Gui.igGetFontSize() * 1.6f - 10 * Look.Scale;
			String shown = scope .();
			bool cut = Look.EllipsizeEnd(text, Math.Max(textW, 8 * Look.Scale), shown);
			bool clicked = Gui.Button(scope $"{lead}{shown}##box", .(width, h));
			Track();
			Gui.igPopStyleVar(1);
			Gui.igPopStyleColor(2);
			// Pill + chevron drawn over the button.
			let dl = Gui.igGetWindowDrawList();
			if (pill != 0)
				Gui.ImDrawList_AddRectFilled(dl, .(start.x + 8 * Look.Scale, start.y + h * 0.3f), .(start.x + 22 * Look.Scale, start.y + h * 0.7f), pill, 4 * Look.Scale, 0);
			Gui.DrawText(dl, .(start.x + width - Gui.igGetFontSize() * 1.3f, start.y + (h - Gui.igGetFontSize()) * 0.5f), Look.ForegroundDim, Icon.ChevronDown);
			if ((cut || textInTip || !tip.IsEmpty) && Gui.igIsItemHovered(0))
			{
				if ((cut || textInTip) && !tip.IsEmpty)
					Gui.Tooltip(scope $"{text}\n{tip}");
				else
					Gui.Tooltip((cut || textInTip) ? text : tip);
			}
			return clicked;
		}

		/// A dropdown: the box showing `preview` and a list of `items` under it (above it when there is no
		/// room, kept inside the window, as wide as its longest option). Returns the index of the option
		/// picked this frame, else -1. A greyed option shows its reason as the tooltip; a described one its
		/// description. `fill` colours the box (the node canvas uses its field colour).
		public static int Dropdown(StringView id, StringView preview, Span<DropItem> items, int selected, float width = -1, StringView previewTip = default, uint32 fill = 0, bool disabled = false, StringView disabledTip = default)
		{
			int picked = -1;
			Gui.PushID(id);
			float h = Gui.igGetFrameHeight();
			let start = Gui.igGetCursorScreenPos();
			float w = (width < 0) ? Gui.igGetContentRegionAvail().x : width;
			Gui.igBeginDisabled(disabled);
			bool open = Box(preview, w, 0, default, previewTip, false, fill);
			Gui.igEndDisabled();
			if (disabled && !disabledTip.IsEmpty && Gui.igIsItemHovered(1 << 10 /* AllowWhenDisabled */))
				Gui.Tooltip(disabledTip);
			if (!TestOpen.IsEmpty && TestOpen == id)
			{
				TestOpen.Clear();
				open = true;
			}
			if (open && !disabled)
				Gui.OpenPopup("##list");
			// The list opens under the box (above it when there is no room below), inside the window.
			let display = Gui.igGetIO_Nil().DisplaySize;
			float listW = w;
			String text = scope .();
			for (let it in items)
			{
				text.Clear();
				if (!it.Icon.IsEmpty)
					text.AppendF("{}  ", it.Icon);
				text.Append(it.Label);
				listW = Math.Max(listW, Gui.CalcTextSize(text).x + 60 * Look.Scale);
			}
			float listH = items.Length * (Gui.igGetFontSize() + 8 * Look.Scale) + 16 * Look.Scale;
			float listX = Math.Max(0, Math.Min(start.x, display.x - listW - 4 * Look.Scale));
			bool above = start.y + h + listH > display.y && start.y - listH > 0;
			Gui.igSetNextWindowPos(.(listX, above ? start.y : start.y + h), Cond.Always, .(0, above ? 1 : 0));
			Gui.igSetNextWindowSize(.(listW, 0), Cond.Always);
			if (Look.BeginPopupSpaced("##list"))
			{
				if (TestClose)
				{
					TestClose = false;
					Gui.igCloseCurrentPopup();
				}
				TestRows = items.Length;
				for (int i < items.Length)
				{
					let it = items[i];
					Gui.PushID((int32)i); // two options may read the same
					text.Clear();
					if (!it.Icon.IsEmpty)
						text.AppendF("{}  ", it.Icon);
					text.Append(it.Label);
					bool off = !it.Disabled.IsEmpty;
					Gui.igBeginDisabled(off);
					if (Gui.Selectable(text, i == selected) && !off)
						picked = i;
					Gui.igEndDisabled();
					if (Gui.igIsItemHovered(1 << 10 /* AllowWhenDisabled */))
					{
						if (off)
							Gui.Tooltip(it.Disabled);
						else if (!it.Tip.IsEmpty)
							Gui.Tooltip(it.Tip);
					}
					Gui.PopID();
				}
				Look.EndPopupSpaced();
			}
			Gui.PopID();
			return picked;
		}

		/// A dropdown over plain texts; true when an option was picked (the index is then in `index`).
		public static bool Combo(StringView id, ref int32 index, Span<StringView> items, float width = -1)
		{
			List<DropItem> list = scope .();
			for (let s in items)
				list.Add(.(s));
			StringView preview = (index >= 0 && index < items.Length) ? items[index] : "";
			let picked = Dropdown(id, preview, list, index, width);
			if (picked < 0)
				return false;
			index = (int32)picked;
			return true;
		}

		/// A dropdown row: the option picked this frame, else -1. `preview` is what the closed box shows.
		public static int DropdownRow(StringView label, StringView id, StringView preview, Span<DropItem> items, int selected, StringView tip = default,
			StringView previewTip = default, bool disabled = false, StringView disabledTip = default, uint32 swatch = 0, StringView problem = default)
		{
			Row(label, tip, swatch);
			let picked = Dropdown(id, preview, items, selected, -1, previewTip, 0, disabled, disabledTip);
			Hint(problem);
			return picked;
		}

		/// A dropdown row over plain texts; true when an option was picked.
		public static bool ComboRow(StringView label, StringView id, ref int32 index, Span<StringView> items, StringView tip = default, bool disabled = false, StringView disabledTip = default)
		{
			Row(label, tip);
			List<DropItem> list = scope .();
			for (let s in items)
				list.Add(.(s));
			StringView preview = (index >= 0 && index < items.Length) ? items[index] : "";
			let picked = Dropdown(id, preview, list, index, -1, default, 0, disabled, disabledTip);
			if (picked < 0)
				return false;
			index = (int32)picked;
			return true;
		}

		// ------------------------------------------------------------------ checkboxes

		/// A checkbox (with an optional caption after it) in the value column; greyed, with the reason as its
		/// tooltip, when `disabled`. True when it was toggled.
		public static bool Check(StringView id, ref bool value, StringView caption = default, bool disabled = false, StringView disabledTip = default)
		{
			Gui.igBeginDisabled(disabled);
			if (disabled)
			{
				// A locked box is drawn grey (not the blue of one you can change).
				Gui.igPushStyleColor_U32(ColX.CheckboxSelectedBg, Look.Dropdown);
				Gui.igPushStyleColor_U32(ColX.CheckMark, Look.ForegroundDim);
			}
			bool clicked = Gui.igCheckbox(scope $"{caption}{id}", &value);
			if (!disabled)
				Track();
			if (disabled)
				Gui.igPopStyleColor(2);
			Gui.igEndDisabled();
			if (disabled && !disabledTip.IsEmpty && Gui.igIsItemHovered(1 << 10 /* AllowWhenDisabled */))
				Gui.Tooltip(disabledTip);
			return clicked;
		}

		public static bool CheckRow(StringView label, StringView id, ref bool value, StringView tip = default, StringView caption = default,
			bool disabled = false, StringView disabledTip = default, uint32 swatch = 0)
		{
			Row(label, tip, swatch);
			return Check(id, ref value, caption, disabled, disabledTip);
		}

		/// A list of checkboxes, one row each (a project's dependencies): the index of the one toggled this
		/// frame (its `On` is already changed), else -1.
		public static int CheckList(StringView idPrefix, Span<CheckItem> items)
		{
			int toggled = -1;
			for (int i < items.Length)
			{
				Gui.PushID((int32)i);
				bool on = items[i].On;
				if (CheckRow(items[i].Label, idPrefix, ref on, items[i].Tip))
				{
					items[i].On = on;
					toggled = i;
				}
				Gui.PopID();
			}
			return toggled;
		}

		// ------------------------------------------------------------------ text, lines, paths, numbers

		/// A text field row bound to `value`. True when the edit is committed (Enter or the field left);
		/// `changed` reports every keystroke. `problem` non-empty: a red frame and the reason under it.
		public static bool TextRow(StringView label, StringView id, String value, out bool changed, StringView tip = default, StringView hint = default,
			bool mono = false, uint32 swatch = 0, StringView problem = default, bool disabled = false)
		{
			Row(label, tip, swatch);
			Gui.igBeginDisabled(disabled);
			bool done = Text(id, value, out changed, mono, null, hint);
			Gui.igEndDisabled();
			Hint(problem);
			return done;
		}

		/// A row whose label column holds a text field (a parameter's name): the field fills the column and the
		/// value column is current when it returns. True when the edit was committed.
		public static bool NameBoxRow(StringView id, String value, StringView hint = default, bool focus = false)
		{
			BeginRow();
			Gui.igIndent(sIndent);
			Gui.igSetNextItemWidth(-1);
			if (focus)
				Gui.igSetKeyboardFocusHere(0);
			bool done = Text(id, value, ?, false, null, hint);
			Gui.igUnindent(sIndent);
			Gui.igTableSetColumnIndex(1);
			return done;
		}

		/// NameBoxRow with a pair of stacked arrows in front of the name (Move Up above, Move Down below):
		/// `move` is -1 / +1 when one was clicked (a disabled arrow is drawn faint and does nothing).
		public static bool NameBoxRowMove(StringView id, String value, StringView hint, bool canUp, bool canDown, out int move)
		{
			move = 0;
			BeginRow();
			Gui.igIndent(sIndent);
			float h = Gui.igGetFrameHeight();
			float w = 14 * Look.Scale;
			let p = Gui.igGetCursorScreenPos();
			let dl = Gui.igGetWindowDrawList();
			for (int i < 2)
			{
				Gui.igSetCursorScreenPos(.(p.x, p.y + i * h * 0.5f));
				Gui.PushID((int32)(9100 + i));
				bool can = (i == 0) ? canUp : canDown;
				bool hit = Gui.igInvisibleButton("##mv", .(w, h * 0.5f), ButtonFlags.MouseButtonLeft);
				bool hot = can && Gui.igIsItemHovered(0);
				if (hot)
					Gui.Tooltip((i == 0) ? "Move Up" : "Move Down");
				if (hit && can)
					move = (i == 0) ? -1 : 1;
				Gui.PopID();
				uint32 col = !can ? Theme.WithAlpha(Look.ForegroundDim, 70) : (hot ? Look.ForegroundHover : Look.Foreground);
				float cx = p.x + w * 0.5f;
				float cy = p.y + i * h * 0.5f + h * 0.25f;
				float s = 3.5f * Look.Scale;
				if (i == 0)
					Gui.ImDrawList_AddTriangleFilled(dl, .(cx - s, cy + s * 0.6f), .(cx + s, cy + s * 0.6f), .(cx, cy - s * 0.7f), col);
				else
					Gui.ImDrawList_AddTriangleFilled(dl, .(cx - s, cy - s * 0.6f), .(cx, cy + s * 0.7f), .(cx + s, cy - s * 0.6f), col);
			}
			Gui.igSetCursorScreenPos(.(p.x + w + 2 * Look.Scale, p.y));
			Gui.igSetNextItemWidth(-1);
			bool done = Text(id, value, ?, false, null, hint);
			Gui.igUnindent(sIndent);
			Gui.igTableSetColumnIndex(1);
			return done;
		}

		/// A multi-line text row (pre-build commands): `lines` is the height in text lines.
		public static bool LinesRow(StringView label, StringView id, String value, out bool changed, StringView tip = default, float lines = 3.4f, bool mono = false)
		{
			Row(label, tip);
			float h = Gui.igGetTextLineHeight() * lines + 8 * Look.Scale;
			return Multiline(id, value, h, out changed, mono ? MonoFont : null);
		}

		/// A one-line text field across the whole panel (an expression): its own row, no label.
		public static bool TextWide(StringView id, String value, out bool changed, bool mono = false, StringView hint = default)
		{
			WideRow();
			Gui.igSetNextItemWidth(-6 * Look.Scale);
			return Text(id, value, out changed, mono, null, hint);
		}

		/// A multi-line text field across the whole panel (a comment, a code block): its own row, no label.
		public static bool LinesWide(StringView id, String value, float height, out bool changed, bool mono = false, bool focus = false)
		{
			WideRow();
			if (focus)
				Gui.igSetKeyboardFocusHere(0);
			return Multiline(id, value, height, out changed, mono ? MonoFont : null);
		}

		/// A path: the text field and a Browse button that opens the system's file or folder dialog.
		/// True when the text was committed or a path was picked (`value` then holds it).
		public static bool PathRow(StringView label, StringView id, String value, out bool changed, bool folder = false, StringView tip = default, StringView hint = default)
		{
			Row(label, tip);
			Gui.PushID(id);
			float b = Gui.igGetFrameHeight();
			Gui.igSetNextItemWidth(Gui.igGetContentRegionAvail().x - b - 4 * Look.Scale);
			bool done = Text("##path", value, out changed, false, null, hint);
			Gui.SameLine(0, 4 * Look.Scale);
			// The icon is drawn on the glyph's own pixels (Icon.DrawCentered), not centred as text: the button's
			// label is hidden behind an ID, so the picture sits in the middle of the square like the other icons.
			bool browse = Gui.Button("##browse", .(b, b));
			{
				let bmin = Gui.igGetItemRectMin();
				let bmax = Gui.igGetItemRectMax();
				uint32 iconCol = Gui.igIsItemHovered(0) ? Look.ForegroundHover : Look.Foreground;
				Icon.DrawCentered(Gui.igGetWindowDrawList(), .((bmin.x + bmax.x) * 0.5f, (bmin.y + bmax.y) * 0.5f), Gui.igGetFontSize(), iconCol, Icon.FolderOpen);
			}
			if (browse)
			{
				String start = scope .(value);
				if (!folder)
					System.IO.Path.GetDirectoryPath(value, start).IgnoreError();
				char8[4096] buf = default;
				if (Host.th_native_dialog(folder ? 1 : 3, start, &buf, 4096) == 1)
				{
					value.Set(StringView(&buf));
					changed = true;
					done = true;
				}
			}
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip(folder ? "Browse for a folder" : "Browse for a file");
			Gui.PopID();
			return done;
		}

		/// A numeric drag row with a unit suffix in `format` ("%.0f px"); true on release.
		public static bool FloatRow(StringView label, StringView id, ref float value, float speed, float min, float max, StringView format = "%.2f", StringView tip = default)
		{
			Row(label, tip);
			return Float(id, ref value, speed, min, max, format);
		}

		public static bool IntRow(StringView label, StringView id, ref int32 value, float speed, int32 min, int32 max, StringView format = "%d", StringView tip = default)
		{
			Row(label, tip);
			return Int(id, ref value, speed, min, max, format);
		}

		// ------------------------------------------------------------------ read-only, buttons, notes

		/// Read-only text in the value column, cut with "..." (the whole text in the tooltip), or wrapped; an
		/// optional colour dot in front.
		public static void Info(StringView text, uint32 color = 0, uint32 dot = 0, bool wrap = false)
		{
			if (dot != 0)
			{
				let p = Gui.igGetCursorScreenPos();
				float h = Gui.igGetFrameHeight();
				Gui.ImDrawList_AddRectFilled(Gui.igGetWindowDrawList(), .(p.x, p.y + h * 0.32f), .(p.x + 12 * Look.Scale, p.y + h * 0.68f), dot, 4 * Look.Scale, 0);
				Gui.igSetCursorScreenPos(.(p.x + 18 * Look.Scale, p.y));
			}
			if (wrap)
				WrappedValue(text);
			else
				Value(text, color);
		}

		public static void InfoRow(StringView label, StringView text, StringView tip = default, uint32 color = 0, uint32 dot = 0, bool wrap = false, uint32 swatch = 0)
		{
			Row(label, tip, swatch);
			Info(text, color, dot, wrap);
		}

		/// A button at the cursor: `width` 0 is its natural width, -1 the whole value column. `danger` is the
		/// red of a delete, `primary` the blue of the main action; greyed, with the reason as tooltip, when
		/// `disabled`. True when clicked.
		public static bool Button(StringView text, float width = 0, bool danger = false, bool primary = false, bool disabled = false, StringView tip = default)
		{
			int colors = 0;
			if (danger)
			{
				Gui.igPushStyleColor_U32(Col.Button, Gui.Color(120, 30, 30));
				Gui.igPushStyleColor_U32(Col.ButtonHovered, Gui.Color(160, 40, 40));
				colors = 2;
			}
			else if (primary)
			{
				Gui.igPushStyleColor_U32(Col.Button, Look.Primary);
				Gui.igPushStyleColor_U32(Col.ButtonHovered, Look.PrimaryHover);
				Gui.igPushStyleColor_U32(Col.ButtonActive, Look.PrimaryPress);
				colors = 3;
			}
			Gui.igBeginDisabled(disabled);
			bool clicked = Gui.Button(text, .(width, 0));
			Gui.igEndDisabled();
			if (colors > 0)
				Gui.igPopStyleColor((int32)colors);
			if (!tip.IsEmpty && Gui.igIsItemHovered(1 << 10 /* AllowWhenDisabled */))
				Gui.Tooltip(tip);
			return clicked && !disabled;
		}

		/// An action row: the label and a button across the value column.
		public static bool ButtonRow(StringView label, StringView text, StringView tip = default, bool danger = false, bool disabled = false, StringView buttonTip = default)
		{
			Row(label, tip);
			return Button(text, -1, danger, false, disabled, buttonTip);
		}

		/// A read-only line of program text across the panel, in the monospace font.
		public static void CodeLine(StringView code)
		{
			WideRow();
			float pad = 8 * Look.Scale;
			Gui.igSetCursorPosX(Gui.igGetCursorPosX() + pad);
			float wrapAt = Gui.igGetCursorPosX() + Gui.igGetContentRegionAvail().x - pad;
			if (MonoFont != null)
				Gui.igPushFont(MonoFont, Gui.igGetFontSize() / Math.Max(Look.Scale, 0.5f) * 0.85f);
			Gui.igPushTextWrapPos(wrapAt);
			Gui.TextColored(Theme.TextCode, code);
			Gui.igPopTextWrapPos();
			if (MonoFont != null)
				Gui.igPopFont();
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip("What this writes (read only)");
			Gui.igDummy(.(0, 2 * Look.Scale));
		}

		/// A paragraph across the panel (an explanation, an error): wrapped, in `color` (0: dim).
		public static void Note(StringView text, uint32 color = 0, bool mono = false)
		{
			WideRow();
			bool useMono = mono && MonoFont != null;
			if (useMono)
				Gui.igPushFont(MonoFont, 0);
			Gui.igPushTextWrapPos(0);
			Gui.TextColored((color != 0) ? color : Look.ForegroundDim, text);
			Gui.igPopTextWrapPos();
			if (useMono)
				Gui.igPopFont();
		}

		/// The reason a value is refused, in red with the error icon, wrapped inside the value column (call it
		/// under the field it is about).
		public static void Problem(StringView msg)
		{
			Gui.igPushTextWrapPos(0);
			Gui.TextColored(Theme.NodeError, scope $"{Icon.Error}  {msg}");
			Gui.igPopTextWrapPos();
		}

		/// A red frame round the item just drawn.
		public static void MarkInvalid()
		{
			let dl = Gui.igGetWindowDrawList();
			Gui.ImDrawList_AddRect(dl, Gui.igGetItemRectMin() - .(1, 1), Gui.igGetItemRectMax() + .(1, 1), Theme.NodeError, 3, 1.5f, 0);
		}

		/// The validation hint of the item just drawn: nothing for an empty `problem`, else the red frame and
		/// the reason under it.
		public static void Hint(StringView problem)
		{
			if (problem.IsEmpty)
				return;
			MarkInvalid();
			Problem(problem);
		}
	}
}
