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
		Extendable
	}

	/// One row of the type picker: the type as it is written, its group and its kind's glyph.
	class TypeEntry
	{
		public String Name = new .() ~ delete _;
		public StringView Group;
		public StringView Glyph;
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

		/// A pin in `col` and the kind's glyph at `pos` (the row's text starts after them).
		static float DrawLead(ImDrawList* dl, ImVec2 pos, float h, uint32 col, StringView glyph)
		{
			float r = h * 0.22f;
			Gui.ImDrawList_AddCircleFilled(dl, .(pos.x + r + 2 * Look.Scale, pos.y + h * 0.5f), r, col, 12);
			float x = pos.x + r * 2 + 8 * Look.Scale;
			if (!glyph.IsEmpty)
			{
				let gs = Gui.CalcTextSize(glyph);
				Gui.DrawText(dl, .(x, pos.y + (h - gs.y) * 0.5f), Theme.Mix(col, Look.Foreground, 0.5f), glyph);
			}
			return x + Gui.igGetFontSize() * 1.4f;
		}

		/// True (with the choice in `outValue`, empty for `noneLabel`) when a row was picked that differs
		/// from `current`. `containers`: the slot takes T[], List<T>, Span<T> and T?; `spelled`: a typed
		/// text may be used as it is; `spellPrefixes`: only a typed `Name<...>` whose `Name` is one of these.
		public static bool Draw(StringView id, StringView current, List<TypeEntry> entries, String outValue, StringView noneLabel = default,
			float width = -1, StringView tip = default, bool spelled = false, List<String> spellPrefixes = null, bool containers = false, StringView placeholder = default)
		{
			bool picked = false;
			Gui.PushID(id);
			float h = Gui.igGetFrameHeight();
			let start = Gui.igGetCursorScreenPos();
			float w = (width < 0) ? Gui.igGetContentRegionAvail().x : width;
			// The closed control: pin + glyph + name (namespace dimmed), chevron.
			String elem = scope .();
			int curContainer = containers ? SplitContainer(current, elem) : 0;
			if (!containers)
				elem.Set(current);
			StringView glyph = default;
			for (let e in entries)
				if (e.Name == elem)
					glyph = e.Glyph;
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
					float x = DrawLead(dl, .(start.x + 6 * Look.Scale, start.y), h, Theme.TypeColor(current), glyph);
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
				bool enter = Gui.igInputTextWithHint("##search", scope $"{Icon.Search}  Search types", sSearch.Ptr, (.)sSearch.Capacity, InputTextFlags.EnterReturnsTrue, null, null);
				var s = sSearch.View;
				s.Trim();
				// The rows, in the order they are drawn: none, recent, then the groups.
				List<(StringView group, StringView name, StringView glyph)> rows = scope .();
				if (!noneLabel.IsEmpty && (s.IsEmpty || Matches(noneLabel, s)))
					rows.Add(("", noneLabel, ""));
				if (s.IsEmpty)
					for (let r in sRecent)
						for (let e in entries)
							if (e.Name == r)
								rows.Add(("Recently used", e.Name, e.Glyph));
				bool exact = false;
				for (let e in entries)
				{
					exact |= e.Name == s;
					if (s.IsEmpty || Matches(e.Name, s))
						rows.Add((e.Group, e.Name, e.Glyph));
				}
				// Searching: the rows whose short name starts with the text come first ("ani" finds Animal).
				if (!s.IsEmpty)
				{
					List<(StringView group, StringView name, StringView glyph)> first = scope .();
					List<(StringView group, StringView name, StringView glyph)> rest = scope .();
					for (let r in rows)
					{
						let dot = r.name.LastIndexOf('.');
						let shortName = (dot >= 0) ? r.name.Substring(dot + 1) : r.name;
						if (shortName.StartsWith(s, .OrdinalIgnoreCase))
							first.Add(r);
						else
							rest.Add(r);
					}
					rows.Clear();
					rows.AddRange(first);
					rows.AddRange(rest);
				}
				String use = scope .();
				if (!s.IsEmpty && !exact && SpellAllowed(s, spelled, spellPrefixes))
					use.AppendF("Use {}", s);
				ClearAndDeleteItems!(TestRows);
				for (let r in rows)
					TestRows.Add(new String(scope $"{r.group}|{r.name}"));
				int total = rows.Count + (use.IsEmpty ? 0 : 1);
				if (Gui.IsKeyPressed(Key.DownArrow, true))
					sCursor = Math.Min(sCursor + 1, Math.Max(0, total - 1));
				if (Gui.IsKeyPressed(Key.UpArrow, true))
					sCursor = Math.Max(sCursor - 1, 0);
				sCursor = Math.Clamp(sCursor, 0, Math.Max(0, total - 1));
				float rowH = Gui.igGetFontSize() + 8 * Look.Scale;
				int groups = 0;
				StringView lastGroup = "\u{1}";
				for (let r in rows)
					if (r.group != lastGroup)
					{
						lastGroup = r.group;
						groups++;
					}
				float listH = Math.Clamp((total + groups) * rowH + 6 * Look.Scale, rowH * 2, maxH - h * 3);
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
					for (let r in rows)
					{
						if (r.group != group)
						{
							group = r.group;
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
						Gui.PushID((int32)mine);
						let p = Gui.igGetCursorScreenPos();
						bool sel = mine == sCursor;
						bool hit = Gui.Selectable("##row", sel, 0, .(0, rowH - 4 * Look.Scale));
						if (sel && (Gui.IsKeyPressed(Key.DownArrow, true) || Gui.IsKeyPressed(Key.UpArrow, true)))
							Gui.igSetScrollHereY(0.5f);
						bool isNone = !noneLabel.IsEmpty && r.group.IsEmpty && r.name == noneLabel;
						float x = isNone ? p.x + 8 * Look.Scale : DrawLead(dl, .(p.x + 4 * Look.Scale, p.y), rowH - 4 * Look.Scale, Theme.TypeColor(r.name), r.glyph);
						float ty = p.y + (rowH - 4 * Look.Scale - Gui.igGetFontSize()) * 0.5f;
						let dot = r.name.LastIndexOf('.');
						let lt = r.name.IndexOf('<');
						bool hasNs = dot > 0 && (lt < 0 || dot < lt);
						StringView shortName = hasNs ? r.name.Substring(dot + 1) : r.name;
						Gui.DrawText(dl, .(x, ty), (r.name == elem) ? Look.ForegroundHover : Look.Foreground, shortName);
						if (hasNs)
						{
							float sw = Gui.CalcTextSize(shortName).x;
							Gui.DrawText(dl, .(x + sw + 8 * Look.Scale, ty), Gui.Color(120, 120, 120), r.name.Substring(0, dot));
						}
						if (r.name == elem && !isNone)
							Gui.DrawText(dl, .(p.x + Gui.igGetContentRegionAvail().x - 16 * Look.Scale, ty), Look.ForegroundDim, Icon.CircleCheck);
						Gui.PopID();
						if (hit || (enter && sel))
						{
							chosen = r.name;
							chose = true;
						}
					}
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

		static StringView GlyphOf(TypeKind kind)
		{
			switch (kind)
			{
			case .Class: return Icon.Class;
			case .Struct: return Icon.Struct;
			case .Enum: return Icon.Enum;
			case .Interface: return Icon.Interface;
			case .Delegate: return Icon.Link;
			case .Extension: return Icon.Plug;
			}
		}

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
			for (let t in ProjectTypes.Types)
				if (Fits(t.Kind, t.Static, t.Abstract, t.Sealed, !t.Generics.IsEmpty, t.FullName) && !seen.ContainsAlt(t.FullName))
				{
					seen.Add(new String(t.FullName));
					TypeEntry e = new .();
					e.Group = "Project types";
					e.Name.Set(t.FullName);
					e.Glyph = GlyphOf(t.Kind);
					project.Add(e);
				}
			project.Sort(scope (a, b) => a.Name.CompareTo(b.Name, true));
			for (let e in project)
				outEntries.Add(e);
			project.Clear();
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
						e.Glyph = Icon.FileCode;
						cimports.Add(e);
					}
					else if (s.IsCore)
					{
						e.Group = "Core";
						e.Glyph = GlyphOf(s.Kind);
						core.Add(e);
					}
					else
					{
						e.Group = "Libraries";
						e.Glyph = GlyphOf(s.Kind);
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
				outTypes.Add(new String(e.Name));
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
			List<TypeEntry> entries = scope .();
			List<String> generic = scope .();
			defer { ClearAndDeleteItems!(entries); ClearAndDeleteItems!(generic); }
			String me = scope .(self);
			if (me.IsEmpty && Doc != null && Doc != mEmptyDoc)
				Doc.Header.GetFullName(me);
			TypeEntries(slot, me, entries, generic);
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
