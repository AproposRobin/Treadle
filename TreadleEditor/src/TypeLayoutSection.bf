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
			let l = TypeLayouts.Get(FrontEnd, name);
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
				Gui.igTableSetupColumn("Offset", TableColumnFlags.WidthFixed, Gui.CalcTextSize("Offset").x, 0);
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

		/// One cell per byte (rows of 16 or 32), each field in its type colour with a gap where a field ends;
		/// padding cells are hatched dark. Payload cases overlap, so the payload area is one block.
		void DrawLayoutBar(TypeLayout l)
		{
			if (l.Size <= 0)
				return;
			let avail = Gui.igGetContentRegionAvail().x - 8 * Look.Scale;
			int perRow = (int)Math.Clamp((l.Size + 7) / 8 * 8, 8, 32);
			float cell = Math.Min(Math.Max(avail / perRow, 4 * Look.Scale), 22 * Look.Scale);
			let shown = Math.Min(l.Size, 512);
			int lines = (int)((shown + perRow - 1) / perRow);
			float ch = Math.Max(cell, 10 * Look.Scale);
			let p0 = Gui.igGetCursorScreenPos();
			let dl = Gui.igGetWindowDrawList();
			let mouse = Gui.igGetMousePos();
			LayoutRow hovered = null;
			for (let r in l.Rows)
			{
				if (r.Depth > 0)
					continue;
				let col = RowColor(r);
				for (int64 b = r.Offset; b < Math.Min(r.Offset + r.Size, shown); b++)
				{
					let x = p0.x + (b % perRow) * cell;
					let y = p0.y + (b / perRow) * (ch + 3 * Look.Scale);
					ImVec2 a = .(x + 0.5f, y);
					ImVec2 c = .(x + cell - ((b == r.Offset + r.Size - 1) ? 2.5f * Look.Scale : 0.5f), y + ch);
					Gui.ImDrawList_AddRectFilled(dl, a, c, col, 0, 0);
					if (r.Kind == .Padding)
						Gui.ImDrawList_AddLine(dl, .(a.x, c.y), .(c.x, a.y), Gui.Color(120, 120, 120, 90), 1);
					if (mouse.x >= a.x && mouse.x < c.x && mouse.y >= a.y && mouse.y < c.y)
						hovered = r;
				}
			}
			// byte offsets under the first row's start and every 8 bytes
			Gui.igDummy(.(perRow * cell, lines * (ch + 3 * Look.Scale)));
			if (hovered != null && Gui.igIsWindowHovered(0))
				Gui.Tooltip(RowTip(hovered, .. scope String()));
			if (l.Size > shown)
				Gui.TextDisabled(scope $"(the bar shows the first {shown} of {l.Size} bytes)");
			Gui.igDummy(.(0, 2 * Look.Scale));
		}
	}
}
