using System;
using System.Collections;
using ImGui;
using Treadle.Document;
using Treadle.Model;

namespace Treadle.Editor
{
	/// What a type picker is for: each slot offers only the types that are legal there
	/// (Editor-Model.md, "Type pickers").
	enum TypeSlot
	{
		/// A field, an input or output, a local, a Cast target, a Literal: any type a value can have
		/// (primitives, vectors, the project's, the core library's and the C imports' types, the type's
		/// generic parameters; not an extension or a node library). Takes a container (T[], List<T>,
		/// Span<T>, T?) and a spelled type (`Core.Dictionary<String, int>`).
		Value,
		/// A function's or a delegate's result: a value type or void.
		Result,
		/// What a Construct or Local node allocates: a class or a struct (not abstract, not static).
		Allocatable,
		/// A class's base: a class that is not sealed, static, the class itself or one of its descendants.
		BaseClass,
		/// An interface a type implements (or an interface extends).
		Interface,
		/// An enum's underlying type, a For's index: the integer types.
		Integer,
		/// What a Switch switches on: an integer, a char, a String or an enum.
		SwitchOn,
		/// What an extension extends: a class, a struct or an enum.
		Extendable,
		/// What an Is Type node tests against: a class (abstract ones too) or an interface.
		TypeTest
	}

	/// One row of the type picker: the type as it is written, its group and its kind's glyph.
	class TypeEntry
	{
		public String Name = new .() ~ delete _;
		public StringView Group;
		public StringView Glyph;
		/// The kind's colour for the glyph (TypeStyle); 0: the pin's colour dimmed.
		public uint32 GlyphColor;
		/// The pin colour, worked out the first time the row is drawn (0: not yet).
		public uint32 PinColor;
		/// Listed dim and not choosable (an abstract or static class in a Construct's picker), with why.
		public bool Disabled;
		public String Hint ~ delete _;
		public String HintShort ~ delete _;
	}

	/// The Blueprint-style type picker of Type Settings, Properties and the New Class dialog: the closed
	/// control shows the type's pin colour, its glyph and its name; a click opens a panel with a search
	/// field (focused; every word typed must match, in any order), Recently used, then collapsible
	/// groups (Primitives, Vectors, Generic parameters, Project types, Core, Libraries, C imports), each
	/// row a pin in the type's colour, the kind's glyph, the name and its namespace dimmed. Up / Down move,
	/// Enter takes the row, Esc closes. A slot that takes containers shows Plain / Array / List / Span /
	/// Nullable under the list; a slot that takes spelled types a "Use ..." row for a typed text that is
	/// not in the list.
	static class TypeCombo
	{
		static TextBuffer sSearch = new .(256) ~ delete _;
		static int sCursor;
		static int sContainer;
		static List<String> sRecent = new .() ~ DeleteContainerAndItems!(_);
		/// Self tests: the id of a combo to open on its next frame, the search text to type, the rows
		/// the last open list showed (`Group|Name`, in order) and a request to close it.
		public static String TestOpen = new .() ~ delete _;
		public static String TestSearch = new .() ~ delete _;
		public static List<String> TestRows = new .() ~ DeleteContainerAndItems!(_);
		public static bool TestClose;
		static StringView[?] sContainers = .("Plain", "Array", "List", "Span", "Nullable");

		public static void NoteRecent(StringView name)
		{
			for (let r in sRecent)
				if (r == name)
				{
					sRecent.Remove(r);
					delete r;
					break;
				}
			sRecent.Insert(0, new String(name));
			while (sRecent.Count > 6)
				delete sRecent.PopBack();
		}

		/// Every word of `search` is in `text` (case-insensitive), in any order.
		public static bool Matches(StringView text, StringView search)
		{
			for (var w in search.Split(' ', .RemoveEmptyEntries))
			{
				w.Trim();
				if (!w.IsEmpty && text.IndexOf(w, true) < 0)
					return false;
			}
			return true;
		}

		/// `Core.List<int>` -> element `int`, container 2; `int[]` -> 1; `Core.Span<T>` -> 3; `int?` -> 4.
		public static int SplitContainer(StringView type, String outElement)
		{
			var t = type;
			t.Trim();
			if (t.EndsWith("[]"))
			{
				outElement.Append(t.Substring(0, t.Length - 2));
				return 1;
			}
			if (t.EndsWith('?'))
			{
				outElement.Append(t.Substring(0, t.Length - 1));
				return 4;
			}
			StringView[4] prefixes = .("Core.List<", "List<", "Core.Span<", "Span<");
			for (int i < 4)
			{
				let prefix = prefixes[i];
				if (t.StartsWith(prefix) && t.EndsWith('>') && !t.Substring(prefix.Length, t.Length - prefix.Length - 1).Contains(','))
				{
					outElement.Append(t.Substring(prefix.Length, t.Length - prefix.Length - 1));
					return (i < 2) ? 2 : 3;
				}
			}
			outElement.Append(t);
			return 0;
		}

		static void WithContainer(StringView element, int container, String outType)
		{
			switch (container)
			{
			case 1: outType.AppendF("{}[]", element);
			case 2: outType.AppendF("Core.List<{}>", element);
			case 3: outType.AppendF("Core.Span<{}>", element);
			case 4: outType.AppendF("{}?", element);
			default: outType.Append(element);
			}
		}

		/// A pin in `col` and the kind's glyph at `pos` (the row's text starts after them); the glyph in
		/// `glyphCol` (the kind's colour, TypeStyle), else the pin's colour dimmed.
		static float DrawLead(ImDrawList* dl, ImVec2 pos, float h, uint32 col, StringView glyph, uint32 glyphCol = 0)
		{
			float r = h * 0.22f;
			Gui.ImDrawList_AddCircleFilled(dl, .(pos.x + r + 2 * Look.Scale, pos.y + h * 0.5f), r, col, 12);
			float x = pos.x + r * 2 + 8 * Look.Scale;
			if (!glyph.IsEmpty)
			{
				let gs = Gui.CalcTextSize(glyph);
				Gui.DrawText(dl, .(x, pos.y + (h - gs.y) * 0.5f), (glyphCol != 0) ? glyphCol : Theme.Mix(col, Look.Foreground, 0.5f), glyph);
			}
			return x + Gui.igGetFontSize() * 1.4f;
		}

		/// The glyph of a container: Plain (a dot), Array (a grid), List (rows), Span (a ruler), Nullable (?).
		public static StringView ContainerGlyph(int container)
		{
			switch (container)
			{
			case 1: return Icon.Grid3x3;
			case 2: return Icon.List;
			case 3: return Icon.Ruler;
			case 4: return Icon.CircleHelp;
			default: return Icon.Circle;
			}
		}

		/// Self tests: a container to choose on the container button of the picker `TestContainerId` (its
		/// next frame).
		public static String TestContainerId = new .() ~ delete _;
		public static int TestContainerPick = -1;

		/// The container button left of a type field: the container's glyph in the type's colour; a click
		/// opens Plain / Array / List / Span / Nullable. True (with the type in `outValue`, the element
		/// kept) when another container was chosen.
		public static bool ContainerButton(StringView id, StringView current, String outValue, float size)
		{
			String elem = scope .();
			int cur = SplitContainer(current, elem);
			let p = Gui.igGetCursorScreenPos();
			bool clicked = Gui.igInvisibleButton("##ctbtn", .(size, size), ButtonFlags.MouseButtonLeft);
			bool hovered = Gui.igIsItemHovered(0);
			let dl = Gui.igGetWindowDrawList();
			Gui.ImDrawList_AddRectFilled(dl, p, .(p.x + size, p.y + size), hovered ? Gui.Color(30, 30, 30) : Look.Input, 3 * Look.Scale, 0);
			let g = ContainerGlyph(cur);
			let gs = Gui.CalcTextSize(g);
			uint32 col = current.IsEmpty ? Look.ForegroundDim : Theme.TypeColor(current);
			Gui.DrawText(dl, .(p.x + (size - gs.x) * 0.5f, p.y + (size - gs.y) * 0.5f), col, g);
			if (hovered)
				Gui.Tooltip(scope $"Container: {sContainers[cur]}\nClick to make it Plain, an Array, a List, a Span or Nullable (the element type stays)");
			if (clicked)
				Gui.OpenPopup("##ctmenu");
			int want = -1;
			if (TestContainerId == id && TestContainerPick >= 0)
			{
				want = TestContainerPick;
				TestContainerPick = -1;
				TestContainerId.Clear();
			}
			if (Gui.BeginPopup("##ctmenu"))
			{
				for (int i < 5)
					if (Gui.Selectable(scope $"{ContainerGlyph(i)}  {sContainers[i]}##ct{i}", i == cur))
						want = i;
				Gui.EndPopup();
			}
			if (want < 0 || want == cur || elem.IsEmpty)
				return false;
			outValue.Clear();
			WithContainer(elem, want, outValue);
			return outValue != current;
		}

		/// One row of the open list: its group and entry (null: the none row).
		struct Row
		{
			public StringView Group;
			public TypeEntry Entry;
		}
		/// The rows of the open list, kept while the search text and the entries stay the same: filtering
		/// a catalogue of thousands of types runs once per keystroke, not once per frame.
		static List<Row> sRows = new .() ~ delete _;
		static String sRowsKey = new .() ~ delete _;
		/// Bumped whenever a cached entry list is rebuilt (its entries are deleted): the rows follow.
		public static int EntriesGeneration;
		/// The most rows the open list draws; the search narrows the rest ("N more").
		public const int MaxRows = 250;
		/// Self tests: how long the last rebuild of the rows took (ms) and how many rows it gave.
		public static double LastRowsMs;
		public static int LastRowsCount;
		/// Self tests: characters typed into the open list's search field, one a frame.
		public static String TestType = new .() ~ delete _;

		public static void BuildRows(StringView id, StringView s, List<TypeEntry> entries, StringView noneLabel, out bool exact)
		{
			exact = false;
			String key = scope .();
			key.AppendF("{}|{}|{}|{}|{}|{}", id, s, (int)Internal.UnsafeCastToPtr(entries), entries.Count, EntriesGeneration, noneLabel);
			for (let r in sRecent)
				key.AppendF("|{}", r);
			if (key == sRowsKey)
			{
				for (let r in sRows)
					if (r.Entry != null && r.Entry.Name == s)
						exact = true;
				return;
			}
			let sw = scope System.Diagnostics.Stopwatch(true);
			sRowsKey.Set(key);
			sRows.Clear();
			if (!noneLabel.IsEmpty && (s.IsEmpty || Matches(noneLabel, s)))
				sRows.Add(.() { Group = "", Entry = null });
			if (s.IsEmpty)
			{
				for (let r in sRecent)
					for (let e in entries)
						if (e.Name == r && !e.Disabled)
						{
							sRows.Add(.() { Group = "Recently used", Entry = e });
							break;
						}
				for (let e in entries)
					sRows.Add(.() { Group = e.Group, Entry = e });
			}
			else
			{
				// The rows whose short name starts with the text come first ("ani" finds Animal).
				List<Row> rest = scope .();
				for (let e in entries)
				{
					exact |= e.Name == s;
					if (!Matches(e.Name, s))
						continue;
					let dot = e.Name.LastIndexOf('.');
					let shortName = (dot >= 0) ? e.Name.Substring(dot + 1) : (StringView)e.Name;
					if (shortName.StartsWith(s, .OrdinalIgnoreCase))
						sRows.Add(.() { Group = e.Group, Entry = e });
					else
						rest.Add(.() { Group = e.Group, Entry = e });
				}
				sRows.AddRange(rest);
				// A type typed out in full comes first, so Enter takes it ("uint8" is uint8, not uint; "int32" is
				// not the "int (default)" row).
				for (int i < sRows.Count)
				{
					let e = sRows[i].Entry;
					if (e == null)
						continue;
					let dot = e.Name.LastIndexOf('.');
					let shortName = (dot >= 0) ? e.Name.Substring(dot + 1) : (StringView)e.Name;
					if (e.Name == s || StringView.Compare(shortName, s, true) == 0)
					{
						let row = sRows[i];
						sRows.RemoveAt(i);
						sRows.Insert(0, row);
						break;
					}
				}
			}
			ClearAndDeleteItems!(TestRows);
			for (let r in sRows)
				TestRows.Add(new String(scope $"{r.Group}|{(r.Entry != null) ? (StringView)r.Entry.Name : noneLabel}"));
			LastRowsMs = sw.Elapsed.TotalMilliseconds;
			LastRowsCount = sRows.Count;
		}

		/// True (with the choice in `outValue`, empty for `noneLabel`) when a row was picked that differs
		/// from `current`. `containers`: the slot takes T[], List<T>, Span<T> and T? (a container button
		/// sits left of the field); `spelled`: a typed text may be used as it is; `spellPrefixes`: only a
		/// typed `Name<...>` whose `Name` is one of these.
		public static bool Draw(StringView id, StringView current, List<TypeEntry> entries, String outValue, StringView noneLabel = default,
			float width = -1, StringView tip = default, bool spelled = false, List<String> spellPrefixes = null, bool containers = false, StringView placeholder = default)
		{
			bool picked = false;
			Gui.PushID(id);
			float h = Gui.igGetFrameHeight();
			float w = (width < 0) ? Gui.igGetContentRegionAvail().x : width;
			if (containers)
			{
				// The container button (Plain / Array / List / Span / Nullable), then the field.
				if (ContainerButton(id, current, outValue, h))
					picked = true;
				Gui.SameLine(0, 3 * Look.Scale);
				w = Math.Max(40 * Look.Scale, w - h - 3 * Look.Scale);
			}
			let start = Gui.igGetCursorScreenPos();
			// The closed control: pin + glyph + name (namespace dimmed), chevron.
			String elem = scope .();
			int curContainer = containers ? SplitContainer(current, elem) : 0;
			if (!containers)
				elem.Set(current);
			StringView glyph = default;
			uint32 glyphCol = 0;
			for (let e in entries)
				if (e.Name == elem)
				{
					glyph = e.Glyph;
					glyphCol = e.GlyphColor;
					break;
				}
			bool clicked = Gui.igInvisibleButton("##box", .(w, h), ButtonFlags.MouseButtonLeft);
			bool hovered = Gui.igIsItemHovered(0);
			{
				let dl = Gui.igGetWindowDrawList();
				Gui.ImDrawList_AddRectFilled(dl, start, .(start.x + w, start.y + h), hovered ? Gui.Color(30, 30, 30) : Look.Input, 3 * Look.Scale, 0);
				float fs = Gui.igGetFontSize();
				float ty = start.y + (h - fs) * 0.5f;
				if (current.IsEmpty)
					Gui.DrawText(dl, .(start.x + 8 * Look.Scale, ty), Look.ForegroundDim, !noneLabel.IsEmpty ? noneLabel : (placeholder.IsEmpty ? "Choose a type" : placeholder));
				else
				{
					// Pin, glyph, the short name, then its namespace dimmed while there is room.
					float x = DrawLead(dl, .(start.x + 6 * Look.Scale, start.y), h, Theme.TypeColor(current), glyph, glyphCol);
					float room = Math.Max(8, start.x + w - x - fs * 1.6f);
					let dot = current.LastIndexOf('.');
					bool hasNs = dot > 0 && !current.Contains('<');
					StringView shortName = hasNs ? current.Substring(dot + 1) : current;
					String shown = scope .();
					Look.EllipsizeEnd(shortName, room, shown);
					Gui.DrawText(dl, .(x, ty), Look.Foreground, shown);
					float sw = Gui.CalcTextSize(shown).x;
					if (hasNs && sw + 8 * Look.Scale < room)
					{
						String ns = scope .();
						Look.EllipsizeEnd(current.Substring(0, dot), room - sw - 8 * Look.Scale, ns);
						Gui.DrawText(dl, .(x + sw + 8 * Look.Scale, ty), Gui.Color(120, 120, 120), ns);
					}
				}
				Gui.DrawText(dl, .(start.x + w - fs * 1.3f, ty), Look.ForegroundDim, Icon.ChevronDown);
				if (hovered && (!tip.IsEmpty || !current.IsEmpty))
					Gui.Tooltip(tip.IsEmpty ? current : scope $"{current}\n{tip}");
			}
			if (!TestOpen.IsEmpty && TestOpen == id)
			{
				TestOpen.Clear();
				clicked = true;
			}
			if (clicked)
			{
				sSearch.Set(TestSearch);
				TestSearch.Clear();
				sCursor = 0;
				sContainer = curContainer;
				sRowsKey.Clear();
				Gui.OpenPopup("##typelist");
			}
			let display = Gui.igGetIO_Nil().DisplaySize;
			float listW = Math.Max(w, 320 * Look.Scale);
			float listX = Math.Max(0, Math.Min(start.x, display.x - listW - 4 * Look.Scale));
			float maxH = Math.Min(420 * Look.Scale, display.y * 0.6f);
			bool above = start.y + h + maxH > display.y && start.y - maxH > 0;
			Gui.igSetNextWindowPos(.(listX, above ? start.y : start.y + h), Cond.Appearing, .(0, above ? 1 : 0));
			Gui.igSetNextWindowSize(.(listW, 0), Cond.Appearing);
			// Opaque, in the menus' colour: nothing behind it (a dialog's labels) shows through the list.
			uint32 popupBg = Gui.igGetColorU32_Col(Col.PopupBg, 1) | 0xFF000000;
			Gui.igPushStyleColor_U32(Col.PopupBg, popupBg);
			Gui.igPushStyleColor_U32(Col.ChildBg, popupBg);
			bool listOpen = Look.BeginPopupSpaced("##typelist");
			Gui.igPopStyleColor(2);
			if (listOpen)
			{
				if (TestClose || Gui.IsKeyPressed(Key.Escape, false))
				{
					TestClose = false;
					Gui.igCloseCurrentPopup();
				}
				// The search field keeps the keyboard: typing always goes there.
				if (Gui.igIsWindowAppearing() || !Gui.igIsAnyItemActive())
					Gui.igSetKeyboardFocusHere(0);
				Gui.igSetNextItemWidth(-1);
				if (!TestType.IsEmpty)
				{
					// Self tests: one character a frame, as typed.
					String typed = scope .(sSearch.View);
					typed.Append(TestType[0]);
					sSearch.Set(typed);
					TestType.Remove(0, 1);
				}
				bool enter = Gui.igInputTextWithHint("##search", scope $"{Icon.Search}  Search types", sSearch.Ptr, (.)sSearch.Capacity, InputTextFlags.EnterReturnsTrue, null, null);
				var s = sSearch.View;
				s.Trim();
				BuildRows(id, s, entries, noneLabel, let exact);
				String use = scope .();
				if (!s.IsEmpty && !exact && SpellAllowed(s, spelled, spellPrefixes))
					use.AppendF("Use {}", s);
				int shownRows = Math.Min(sRows.Count, MaxRows);
				int total = shownRows + (use.IsEmpty ? 0 : 1);
				if (Gui.IsKeyPressed(Key.DownArrow, true))
					sCursor = Math.Min(sCursor + 1, Math.Max(0, total - 1));
				if (Gui.IsKeyPressed(Key.UpArrow, true))
					sCursor = Math.Max(sCursor - 1, 0);
				sCursor = Math.Clamp(sCursor, 0, Math.Max(0, total - 1));
				float rowH = Gui.igGetFontSize() + 8 * Look.Scale;
				int groups = 0;
				StringView lastGroup = "\u{1}";
				for (int i < shownRows)
					if (sRows[i].Group != lastGroup)
					{
						lastGroup = sRows[i].Group;
						groups++;
					}
				float listH = Math.Clamp((total + groups + ((sRows.Count > shownRows) ? 1 : 0)) * rowH + 6 * Look.Scale, rowH * 2, maxH - h * 3);
				StringView chosen = default;
				bool chose = false;
				if (Gui.igBeginChild_Str("##rows", .(0, listH), 0, 0))
				{
					let dl = Gui.igGetWindowDrawList();
					int idx = 0;
					StringView group = "\u{1}";
					bool groupOpen = true;
					if (!use.IsEmpty)
					{
						if (Gui.Selectable(scope $"{Icon.Pencil}  {use}##use", sCursor == 0))
						{
							chosen = s;
							chose = true;
						}
						if (enter && sCursor == 0)
						{
							chosen = s;
							chose = true;
						}
						idx++;
					}
					for (int ri < shownRows)
					{
						let r = sRows[ri];
						if (r.Group != group)
						{
							group = r.Group;
							if (group.IsEmpty)
								groupOpen = true;
							else
							{
								if (!s.IsEmpty)
									Gui.igSetNextItemOpen(true, Cond.Always);
								Gui.igPushStyleColor_U32(Col.Text, Look.ForegroundDim);
								groupOpen = Gui.TreeNode(scope String(group), TreeNodeFlags.DefaultOpen | TreeNodeFlags.NoTreePushOnOpen);
								Gui.igPopStyleColor(1);
							}
						}
						let mine = idx++;
						if (!groupOpen)
							continue;
						bool isNone = r.Entry == null;
						StringView name = isNone ? noneLabel : (StringView)r.Entry.Name;
						bool disabled = !isNone && r.Entry.Disabled;
						Gui.PushID((int32)mine);
						let p = Gui.igGetCursorScreenPos();
						bool sel = mine == sCursor;
						bool hit = Gui.Selectable("##row", sel && !disabled, disabled ? SelectableFlags.Disabled : 0, .(0, rowH - 4 * Look.Scale));
						if (disabled && Gui.igIsItemHovered(HoveredFlags.AllowWhenDisabled) && r.Entry.Hint != null)
							Gui.Tooltip(scope $"{name}\n{r.Entry.Hint}");
						if (sel && (Gui.IsKeyPressed(Key.DownArrow, true) || Gui.IsKeyPressed(Key.UpArrow, true)))
							Gui.igSetScrollHereY(0.5f);
						float x = p.x + 8 * Look.Scale;
						if (!isNone)
						{
							// The pin colour is worked out once per entry (the type system's answer).
							if (r.Entry.PinColor == 0)
								r.Entry.PinColor = Theme.TypeColor(name) | 0xFF000000;
							let pin = disabled ? Theme.WithAlpha(r.Entry.PinColor, 90) : r.Entry.PinColor;
							x = DrawLead(dl, .(p.x + 4 * Look.Scale, p.y), rowH - 4 * Look.Scale, pin, r.Entry.Glyph, disabled ? Look.ForegroundDim : r.Entry.GlyphColor);
						}
						float ty = p.y + (rowH - 4 * Look.Scale - Gui.igGetFontSize()) * 0.5f;
						let dot = name.LastIndexOf('.');
						let lt = name.IndexOf('<');
						bool hasNs = dot > 0 && (lt < 0 || dot < lt);
						StringView shortName = hasNs ? name.Substring(dot + 1) : name;
						Gui.DrawText(dl, .(x, ty), disabled ? Look.ForegroundDim : ((name == elem) ? Look.ForegroundHover : Look.Foreground), shortName);
						float tw = Gui.CalcTextSize(shortName).x;
						if (hasNs)
						{
							Gui.DrawText(dl, .(x + tw + 8 * Look.Scale, ty), Gui.Color(120, 120, 120), name.Substring(0, dot));
							tw += Gui.CalcTextSize(name.Substring(0, dot)).x + 8 * Look.Scale;
						}
						if (disabled && r.Entry.HintShort != null)
							Gui.DrawText(dl, .(x + tw + 10 * Look.Scale, ty), Gui.Color(110, 110, 110), r.Entry.HintShort);
						if (name == elem && !isNone)
							Gui.DrawText(dl, .(p.x + Gui.igGetContentRegionAvail().x - 16 * Look.Scale, ty), Look.ForegroundDim, Icon.CircleCheck);
						Gui.PopID();
						if (!disabled && (hit || (enter && sel)))
						{
							chosen = name;
							chose = true;
						}
					}
					if (sRows.Count > shownRows)
						Gui.TextDisabled(scope $"{sRows.Count - shownRows} more: type to narrow the list");
					if (total == 0)
						Gui.TextDisabled("No type of that name fits here");
				}
				Gui.igEndChild();
				if (containers)
				{
					// The container: Plain / Array / List / Span / Nullable, applied to the chosen type.
					float segW = (Gui.igGetContentRegionAvail().x - 8 * Look.Scale) / 5;
					for (int i < 5)
					{
						if (i > 0)
							Gui.SameLine(0, 2 * Look.Scale);
						bool on = sContainer == i;
						Gui.igPushStyleColor_U32(Col.Button, on ? Look.Primary : Look.Input);
						if (Gui.Button(scope $"{sContainers[i]}##ct{i}", .(segW, 0)))
						{
							sContainer = i;
							if (!elem.IsEmpty && s.IsEmpty)
							{
								chosen = elem;
								chose = true;
							}
						}
						Gui.igPopStyleColor(1);
					}
				}
				if (chose)
				{
					bool none = !noneLabel.IsEmpty && chosen == noneLabel;
					outValue.Clear();
					if (none)
						outValue.Clear();
					else if (containers)
						WithContainer(chosen, sContainer, outValue);
					else
						outValue.Set(chosen);
					if (!none)
						NoteRecent(chosen);
					picked = outValue != current;
					Gui.igCloseCurrentPopup();
				}
				Look.EndPopupSpaced();
			}
			Gui.PopID();
			return picked;
		}

		static bool SpellAllowed(StringView text, bool spelled, List<String> prefixes)
		{
			if (spelled)
				return true;
			if (prefixes == null)
				return false;
			let lt = text.IndexOf('<');
			if (lt <= 0 || !text.EndsWith('>'))
				return false;
			let head = text.Substring(0, lt);
			for (let p in prefixes)
				if (p == head)
					return true;
			return false;
		}
	}

	extension EditorApp
	{
		/// The id of a Type Settings picker to open on its next frame (New Extension: Extends).
		String mFocusTsId = new .() ~ delete _;
		static StringView[?] sPrimitiveTypes = .("bool", "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "float", "double", "char8", "char32", "String", "StringView");
		static StringView[?] sIntegerTypes = .("int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64");

		/// True when the project type `name` (full or short) derives from `ancestor` (full or short),
		/// following the project's `base` lines (a cycle stops the walk).
		public bool DerivesFrom(StringView name, StringView ancestor)
		{
			RefreshProjectTypes();
			var t = ProjectTypes.Find(name);
			for (int depth = 0; t != null && depth < 64; depth++)
			{
				if (t.Base.IsEmpty)
					return false;
				let b = ProjectTypes.Find(t.Base);
				if (t.Base == ancestor || (b != null && (b.FullName == ancestor || b.Name == ancestor)))
					return true;
				t = b;
			}
			return false;
		}

		static StringView GlyphOf(TypeKind kind) => TypeStyle.KindIcon(kind);

		/// The types a picker of `slot` offers, grouped (Primitives, Vectors, Generic parameters, Project
		/// types, Core, Libraries, C imports), each group sorted. `self`: the type being edited (left out
		/// of a base or an extends list, with its descendants). `outGenericBases`: the generic classes a
		/// base may be spelled from (`Box` for `Box<int>`).
		public void TypeEntries(TypeSlot slot, StringView self, List<TypeEntry> outEntries, List<String> outGenericBases = null)
		{
			RefreshProjectTypes();
			HashSet<String> seen = scope .();
			defer { for (let s in seen) delete s; }
			void Add(StringView group, StringView name, StringView glyph)
			{
				if (name.IsEmpty || seen.ContainsAlt(name))
					return;
				seen.Add(new String(name));
				TypeEntry e = new .();
				e.Group = group;
				e.Name.Set(name);
				e.Glyph = glyph;
				outEntries.Add(e);
			}
			bool Fits(TypeKind kind, bool isStatic, bool isAbstract, bool isSealed, bool isGeneric, StringView fullName)
			{
				switch (slot)
				{
				case .Value, .Result:
					return kind != .Extension && !isStatic;
				case .Allocatable:
					return (kind == .Class || kind == .Struct) && !isStatic && !isAbstract;
				case .BaseClass:
					if (kind != .Class || isStatic || isSealed || fullName == self || DerivesFrom(fullName, self))
						return false;
					if (isGeneric)
					{
						outGenericBases?.Add(new String(fullName));
						return false;
					}
					return true;
				case .Interface:
					return kind == .Interface && fullName != self;
				case .Integer:
					return false;
				case .SwitchOn:
					return kind == .Enum;
				case .Extendable:
					return (kind == .Class || kind == .Struct || kind == .Enum) && fullName != self;
				case .TypeTest:
					return (kind == .Class && !isStatic) || kind == .Interface;
				}
			}
			switch (slot)
			{
			case .Value, .Result:
				if (slot == .Result)
					Add("Primitives", "void", "");
				for (let t in sPrimitiveTypes)
					Add("Primitives", t, "");
				for (let t in Treadle.Model.VectorTypes.Common)
					Add("Vectors", t, Icon.Layers);
				if (Doc != null && Doc != mEmptyDoc)
					for (let g in Doc.Header.Generics)
						Add("Generic parameters", g.Name, Icon.Braces);
			case .Integer:
				for (let t in sIntegerTypes)
					Add("Primitives", t, "");
			case .SwitchOn:
				for (let t in sIntegerTypes)
					Add("Primitives", t, "");
				for (let t in StringView[?]("char8", "char32", "String"))
					Add("Primitives", t, "");
			default:
			}
			List<TypeEntry> project = scope .();
			defer { ClearAndDeleteItems!(project); }
			List<TypeEntry> dim = scope .();
			defer { ClearAndDeleteItems!(dim); }
			for (let t in ProjectTypes.Types)
			{
				if (seen.ContainsAlt(t.FullName))
					continue;
				bool fits = Fits(t.Kind, t.Static, t.Abstract, t.Sealed, !t.Generics.IsEmpty, t.FullName);
				// A Construct / Local lists the classes it cannot make too, dim, with the reason.
				bool dimmed = !fits && slot == .Allocatable && (t.Kind == .Class || t.Kind == .Struct);
				if (!fits && !dimmed)
					continue;
				seen.Add(new String(t.FullName));
				TypeEntry e = new .();
				e.Group = "Project types";
				e.Name.Set(t.FullName);
				e.Glyph = GlyphOf(t.Kind);
				e.GlyphColor = TypeStyle.KindColor(t.Kind);
				if (dimmed)
				{
					e.Disabled = true;
					e.HintShort = new String(t.Static ? "static" : "abstract");
					e.Hint = new String(t.Static ? "A static class has only static members: there is nothing to construct. Call its functions directly." :
						"An abstract class cannot be constructed: construct a class that derives from it.");
					dim.Add(e);
				}
				else
					project.Add(e);
			}
			project.Sort(scope (a, b) => a.Name.CompareTo(b.Name, true));
			dim.Sort(scope (a, b) => a.Name.CompareTo(b.Name, true));
			for (let e in project)
				outEntries.Add(e);
			for (let e in dim)
				outEntries.Add(e);
			project.Clear();
			dim.Clear();
			List<TypeEntry> core = scope .();
			List<TypeEntry> libs = scope .();
			List<TypeEntry> cimports = scope .();
			defer { ClearAndDeleteItems!(core); ClearAndDeleteItems!(libs); ClearAndDeleteItems!(cimports); }
			let comp = FrontEnd?.Last;
			if (comp != null)
				for (let s in comp.Table.Types)
				{
					if (s.FullName.IsEmpty || s.AliasOf != null || seen.ContainsAlt(s.FullName))
						continue;
					if (!Fits(s.Kind, s.Static, s.Abstract, s.Sealed, s.IsGeneric, s.FullName))
						continue;
					seen.Add(new String(s.FullName));
					TypeEntry e = new .();
					e.Name.Set(s.FullName);
					if (s.IsCImport || s.IsCRecord)
					{
						e.Group = "C imports";
						e.Glyph = TypeStyle.CImportIcon;
						e.GlyphColor = TypeStyle.CImportColor;
						cimports.Add(e);
					}
					else if (s.IsCore)
					{
						e.Group = "Core";
						e.Glyph = GlyphOf(s.Kind);
						e.GlyphColor = TypeStyle.KindColor(s.Kind);
						core.Add(e);
					}
					else
					{
						e.Group = "Libraries";
						e.Glyph = GlyphOf(s.Kind);
						e.GlyphColor = TypeStyle.KindColor(s.Kind);
						libs.Add(e);
					}
				}
			for (let list in List<TypeEntry>[?](core, libs, cimports))
			{
				list.Sort(scope (a, b) => a.Name.CompareTo(b.Name, true));
				for (let e in list)
					outEntries.Add(e);
				list.Clear();
			}
		}

		/// The names alone (the generic constraints' list, the self tests).
		public void TypeChoices(TypeSlot slot, StringView self, List<String> outTypes, List<String> outGenericBases = null)
		{
			List<TypeEntry> entries = scope .();
			defer { ClearAndDeleteItems!(entries); }
			TypeEntries(slot, self, entries, outGenericBases);
			for (let e in entries)
				if (!e.Disabled)
					outTypes.Add(new String(e.Name));
		}

		/// The entry lists of the pickers drawn lately, by slot and self, kept until the project's types,
		/// the front end's table or the open type change: a picker no longer reads the whole catalogue on
		/// every frame it is drawn.
		Dictionary<String, (List<TypeEntry> entries, List<String> generic)> mTypeEntryCache = new .() ~ { ClearTypeEntryCache(); delete _; };
		uint64 mTypeEntryStamp;

		void ClearTypeEntryCache()
		{
			for (let kv in mTypeEntryCache)
			{
				delete kv.key;
				DeleteContainerAndItems!(kv.value.entries);
				DeleteContainerAndItems!(kv.value.generic);
			}
			mTypeEntryCache.Clear();
			TypeCombo.EntriesGeneration++;
		}

		/// The cached entries of `slot` for `self` (TypeEntries).
		List<TypeEntry> CachedTypeEntries(TypeSlot slot, StringView self, out List<String> generic)
		{
			RefreshProjectTypes();
			uint64 stamp = mProjectTypesStamp * 31 + (uint64)(int)Internal.UnsafeCastToPtr(FrontEnd?.Last);
			if (Doc != null)
			{
				stamp = stamp * 31 + (uint64)(int)Internal.UnsafeCastToPtr(Doc);
				for (let g in Doc.Header.Generics)
					stamp = stamp * 31 + (uint64)g.Name.GetHashCode();
			}
			if (stamp != mTypeEntryStamp)
			{
				ClearTypeEntryCache();
				mTypeEntryStamp = stamp;
			}
			String key = scope $"{(int)slot}|{self}";
			if (mTypeEntryCache.TryGetValueAlt(key, let found))
			{
				generic = found.generic;
				return found.entries;
			}
			let entries = new List<TypeEntry>();
			generic = new List<String>();
			TypeEntries(slot, self, entries, generic);
			mTypeEntryCache[new String(key)] = (entries, generic);
			return entries;
		}

		/// A Type Settings / Properties row with the type picker of `slot`. True (with the type in
		/// `outValue`, empty for the none row) when another type was chosen.
		bool TsTypeRow(StringView label, StringView id, StringView current, String outValue, TypeSlot slot, StringView tip = default, StringView noneLabel = default)
		{
			PropertyGrid.Row(label, tip, current.IsEmpty ? 0 : Theme.TypeColor(current));
			return TypeComboFor(id, current, outValue, slot, noneLabel, -1);
		}

		/// The picker alone (the caller placed the cursor).
		bool TypeComboFor(StringView id, StringView current, String outValue, TypeSlot slot, StringView noneLabel = default, float width = -1, StringView self = default, StringView placeholder = default)
		{
			String me = scope .(self);
			if (me.IsEmpty && Doc != null && Doc != mEmptyDoc)
				Doc.Header.GetFullName(me);
			let entries = CachedTypeEntries(slot, me, let generic);
			bool spelled = slot == .Value || slot == .Result || slot == .Allocatable;
			return TypeCombo.Draw(id, current, entries, outValue, noneLabel, width, default, spelled, (slot == .BaseClass) ? generic : null, slot == .Value, placeholder);
		}

		/// A picker over plain names (Extends of an extension, generic constraints).
		bool NameComboFor(StringView id, StringView current, List<String> names, String outValue, float width = -1, StringView placeholder = default)
		{
			List<TypeEntry> entries = scope .();
			defer { ClearAndDeleteItems!(entries); }
			for (let n in names)
			{
				TypeEntry e = new .();
				e.Name.Set(n);
				let pt = ProjectTypes.Find(n);
				e.Group = (pt != null) ? "Project types" : "Types";
				e.Glyph = (pt != null) ? GlyphOf(pt.Kind) : "";
				entries.Add(e);
			}
			return TypeCombo.Draw(id, current, entries, outValue, default, width, default, false, null, false, placeholder);
		}
	}
}
