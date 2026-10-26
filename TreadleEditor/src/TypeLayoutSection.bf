using System;
using System.Collections;
using ImGui;
using Treadle.Model;

namespace Treadle.Editor
{
	/// The Layout section of Type Settings (docs/Debugging.md, "Under the hood"): where each field of a
	/// class, struct or enum sits in memory, as the compiler lays it out (TypeLayouts): offset, size and
	/// alignment per field, the padding between them in a muted colour, a class's vtable pointer, a payload
	/// enum's tag and cases, the total, and a bar with one cell per byte in the fields' type colours. A
	/// generic type is laid out for an instantiation typed in the section. Works without a build or a run.
	extension EditorApp
	{
		/// The instantiation typed for each generic type (`Zoo.Box` -> `Zoo.Box<int>`).
		Dictionary<String, String> mLayoutInst = new .() ~ DeleteDictionaryAndKeysAndValues!(_);

		/// Called from Type Settings with the type's header (the section is open).
		void DrawLayoutSection(TypeDecl h)
		{
			String full = h.GetFullName(.. scope String());
			String name = scope .(full);
			if (!h.Generics.IsEmpty)
			{
				String inst;
				if (!mLayoutInst.TryGetValueAlt(full, out inst))
				{
					inst = new String(full);
					inst.Append('<');
					for (let g in h.Generics)
						inst.Append((@g.Index > 0) ? ",int" : "int");
					inst.Append('>');
					mLayoutInst[new String(full)] = inst;
				}
				String buf = scope .(inst);
				if (PropertyGrid.TextRow("Instantiation", "##layoutinst", buf, ?, "A generic type is laid out per instantiation: type the arguments (Zoo.Box<int>, Zoo.Box<Zoo.Point>)", default, true))
					inst.Set(buf);
				name.Set(inst);
			}
			// A stall here is named in the session log ("frame loop stalled N s (stage: type layout)").
			CrashHandler.LoopStage("type layout (Type Settings > Layout)");
			let l = TypeLayouts.Get(FrontEnd, name);
			CrashHandler.LoopStage("editor frame");
			if (l == null || !l.Ok)
			{
				PropertyGrid.Note((l != null && !l.Why.IsEmpty) ? l.Why : "No layout: the compiler is not available.", Look.ForegroundDim);
				return;
			}
			DrawLayoutTable(l, "##typelayout");
		}

		/// The rows, the bar and the totals of a layout (also the Memory panel's header for a type).
		public void DrawLayoutTable(TypeLayout l, StringView id)
		{
			// A simple enum is one integer: one line, no bar and no table.
			if (l.IsEnum && !l.IsPayloadEnum)
			{
				StringView under = (!l.Rows.IsEmpty && !l.Rows[0].Type.IsEmpty) ? (StringView)l.Rows[0].Type : "int";
				PropertyGrid.InfoRow("Stored as", scope $"{under}, {l.Size} byte{(l.Size == 1) ? "" : "s"}", "An enum value is its case's number, stored as the Underlying Type (Enum section above)", 0, 0, true);
				return;
			}
			int64 padding = 0;
			for (let r in l.Rows)
				if (r.Kind == .Padding)
					padding += r.Size;
			String total = scope $"{l.Size} byte{(l.Size == 1) ? "" : "s"}, aligned to {l.Align}";
			if (padding > 0)
				total.AppendF(", {} of them padding", padding);
			PropertyGrid.InfoRow("Size", total, "What one value takes in memory, padding included; arrays and fields of this type repeat it", 0, 0, true);
			if (l.IsClass)
				{
				PropertyGrid.InfoRow("Reference", "8 bytes (a pointer to the object)", "A class is a reference type: variables, fields and pins hold the object's address, the object lives on the heap (Construct) or in a region (Local)", 0, 0, true);
				PropertyGrid.InfoRow("Vtable", scope $"{l.VSlots} virtual slot{(l.VSlots == 1) ? "" : "s"}, after the type info and the destructor", "Every object starts with a pointer to its class's table: the type info, the destructor, then the virtual functions, the base class's first (Compiler.md 6.1)", 0, 0, true);
			}
			if (l.Packed)
				PropertyGrid.InfoRow("Packed", "yes: no padding between fields", "The [Packed] attribute");
			PropertyGrid.WideRow();
			DrawLayoutBar(l);
			// narrow (the right dock at 1280 wide): the alignment goes to the tooltips
			let wide = Gui.igGetContentRegionAvail().x > 330 * Look.Scale;
			if (Gui.igBeginTable(scope String(id), wide ? 5 : 4, TableFlags.RowBg | TableFlags.BordersInnerV | TableFlags.SizingStretchProp, .(Gui.igGetContentRegionAvail().x - 6 * Look.Scale, 0), 0))
			{
				// very narrow: a short header, so "Offset" is never clipped
				let offsetHead = (Gui.igGetContentRegionAvail().x > 230 * Look.Scale) ? "Offset" : "Off";
				Gui.igTableSetupColumn(offsetHead, TableColumnFlags.WidthFixed, Gui.CalcTextSize(offsetHead).x + 2 * Look.Scale, 0);
				Gui.igTableSetupColumn("Field", TableColumnFlags.WidthStretch, 1.2f, 0);
				Gui.igTableSetupColumn("Type", TableColumnFlags.WidthStretch, 1.0f, 0);
				Gui.igTableSetupColumn("Size", TableColumnFlags.WidthFixed, Gui.CalcTextSize("Size").x, 0);
				if (wide)
					Gui.igTableSetupColumn("Align", TableColumnFlags.WidthFixed, Gui.CalcTextSize("Align").x, 0);
				HoodGui.igTableHeadersRow();
				for (let r in l.Rows)
				{
					Gui.igTableNextRow(0, 0);
					bool muted = r.Kind == .Padding;
					let col = muted ? Look.ForegroundDim : Look.Foreground;
					Gui.igTableSetColumnIndex(0);
					Gui.TextColored(col, scope $"{r.Offset}");
					Gui.igTableSetColumnIndex(1);
					String label = scope .();
					if (r.Depth > 0)
						label.Append("    ");
					label.Append(r.Name);
					if (muted)
						Gui.TextColored(col, label);
					else
					{
						let p = Gui.igGetCursorScreenPos();
						let h = Gui.igGetTextLineHeight();
						Gui.ImDrawList_AddRectFilled(Gui.igGetWindowDrawList(), .(p.x, p.y + h * 0.2f), .(p.x + 4 * Look.Scale, p.y + h * 0.8f), RowColor(r), 1, 0);
						Gui.igSetCursorScreenPos(.(p.x + 8 * Look.Scale, p.y));
						Gui.TextColored(col, label);
					}
					if (Gui.igIsItemHovered(0))
						Gui.Tooltip(RowTip(r, .. scope String()));
					Gui.igTableSetColumnIndex(2);
					if (!r.Type.IsEmpty)
						Gui.TextColored(muted ? col : Look.ForegroundDim, r.Type);
					Gui.igTableSetColumnIndex(3);
					Gui.TextColored(col, scope $"{r.Size}");
					if (wide && Gui.igTableSetColumnIndex(4) && !muted)
						Gui.TextColored(col, scope $"{r.Align}");
				}
				Gui.igEndTable();
			}
		}

		/// The colour of a row's cells and stripe: the pin colour of its type; the vtable pointer and the tag
		/// in neutral tones, padding dark.
		static uint32 RowColor(LayoutRow r)
		{
			switch (r.Kind)
			{
			case .Padding: return Gui.Color(70, 70, 70, 120);
			case .VTable: return Gui.Color(150, 150, 160);
			case .Tag: return Look.AccentYellow;
			case .Payload: return Gui.Color(110, 110, 130);
			default: return Theme.TypeColor(r.Type);
			}
		}

		static void RowTip(LayoutRow r, String o)
		{
			switch (r.Kind)
			{
			case .Padding:
				o.AppendF("{} byte{} of padding at {}: unused, so the next field (or the next value in an array) starts aligned", r.Size, (r.Size == 1) ? "" : "s", r.Offset);
			case .VTable:
				o.Append("The object header: a pointer to the class's vtable (type info, destructor, virtual functions). Set when the object is made; a virtual call reads it.");
			case .Tag:
				o.AppendF("{}: which case the value holds ({}, {} bytes at {})", r.Name, r.Type, r.Size, r.Offset);
			case .Payload:
				o.AppendF("The payload area ({} bytes at {}): the fields of the case the tag names; the cases share it", r.Size, r.Offset);
			default:
				o.AppendF("{}  {}\nbytes {} to {} ({} byte{}, aligned to {})", r.Name, r.Type, r.Offset, r.Offset + r.Size - 1, r.Size, (r.Size == 1) ? "" : "s", r.Align);
				if (!r.From.IsEmpty)
					o.AppendF("\ndeclared by the base class {}", r.From);
				if (!r.Case.IsEmpty)
					o.AppendF("\nused when the value is {}", r.Case);
			}
		}

		/// The layout sizes the bar refused (0, negative or over 1 MB: a layout bug), logged once per type.
		static System.Collections.HashSet<String> sBadLayoutLogged = new .() ~ DeleteContainerAndItems!(_);

		/// One cell per byte, rows of 16 (8 when the panel is narrow), every cell the same width so the bar fits the
		/// panel; each field in its type's pin colour (one quad per run of a field's bytes on a row), a dark line where
		/// a field ends, padding hatched. Payload cases overlap, so the payload area is one block. At most 512 bytes
		/// are drawn; hovering a cell names its byte and field.
		void DrawLayoutBar(TypeLayout l)
		{
			if (l.Size <= 0 || l.Size > 1 << 20)
			{
				if (!sBadLayoutLogged.ContainsAlt(l.Name))
				{
					sBadLayoutLogged.Add(new String(l.Name));
					Notify.Log(.Warning, "Layout", scope $"The layout of {l.Name} has a size of {l.Size} bytes: the bar is not drawn");
				}
				if (l.Size <= 0)
					return;
			}
			Gui.TextDisabled("How this type is stored in memory: one cell per byte");
			let avail = Math.Max(Gui.igGetContentRegionAvail().x - 4 * Look.Scale, 40 * Look.Scale);
			int perRow = (l.Size <= 8) ? 8 : 16;
			if (perRow == 16 && avail / 16 < 9 * Look.Scale)
				perRow = 8;
			// one width for every cell of every row, from the panel's width
			float pitch = Math.Min(avail / perRow, 22 * Look.Scale);
			let shown = Math.Min(l.Size, 512);
			int lines = (int)((shown + perRow - 1) / perRow);
			float ch = Math.Clamp(pitch, 10 * Look.Scale, 18 * Look.Scale);
			float rowGap = 3 * Look.Scale;
			let p0 = Gui.igGetCursorScreenPos();
			let dl = Gui.igGetWindowDrawList();
			let mouse = Gui.igGetMousePos();
			LayoutRow hovered = null;
			int64 hoveredByte = -1;
			uint32 sep = Gui.Color(0, 0, 0, 140);
			for (let r in l.Rows)
			{
				if (r.Depth > 0 || r.Size <= 0)
					continue;
				let col = RowColor(r);
				let fieldEnd = Math.Min(r.Offset + r.Size, shown);
				int64 b = r.Offset;
				while (b < fieldEnd)
				{
					// one run: the field's bytes on this row
					let line = b / perRow;
					let runEnd = Math.Min(fieldEnd, (line + 1) * perRow);
					let y = p0.y + line * (ch + rowGap);
					ImVec2 a = .(p0.x + (b % perRow) * pitch, y);
					ImVec2 c = .(p0.x + ((runEnd - 1) % perRow + 1) * pitch, y + ch);
					Gui.ImDrawList_AddRectFilled(dl, .(a.x + 0.5f, a.y), .(c.x - 0.5f, c.y), col, 0, 0);
					// thin lines between the bytes of the run
					for (int64 k = b + 1; k < runEnd; k++)
					{
						let x = p0.x + (k % perRow) * pitch;
						Gui.ImDrawList_AddLine(dl, .(x, y), .(x, y + ch), Gui.Color(0, 0, 0, 50), 1);
					}
					if (r.Kind == .Padding)
						Gui.ImDrawList_AddLine(dl, .(a.x, c.y), .(c.x, a.y), Gui.Color(120, 120, 120, 90), 1);
					if (runEnd == r.Offset + r.Size)
						Gui.ImDrawList_AddLine(dl, .(c.x - 1, y), .(c.x - 1, y + ch), sep, 2 * Look.Scale); // the field ends here
					if (mouse.x >= a.x && mouse.x < c.x && mouse.y >= a.y && mouse.y < c.y)
					{
						hovered = r;
						hoveredByte = line * perRow + (int64)((mouse.x - p0.x) / pitch);
					}
					b = runEnd;
				}
			}
			Gui.igDummy(.(perRow * pitch, lines * (ch + rowGap)));
			if (hovered != null && Gui.igIsWindowHovered(0))
			{
				String tip = scope .();
				tip.AppendF("Byte {}\n", hoveredByte);
				RowTip(hovered, tip);
				Gui.Tooltip(tip);
			}
			if (l.Size > shown)
				Gui.TextDisabled(scope $"... {l.Size - shown} more bytes (the bar shows the first {shown})");
			Gui.igDummy(.(0, 2 * Look.Scale));
		}
	}
}
