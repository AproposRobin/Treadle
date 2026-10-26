using System;
using System.Collections;
using ImGui;
using Treadle.Debug;
using Treadle.Debug.Dap;
using Treadle.Backend.IR;

namespace Treadle.Editor
{
	/// The Under the hood panels' names (the part after "###" is the stable ImGui id).
	static class HoodPanels
	{
		public const String Memory = "\u{E0EC}  Memory###Memory";
		public const String MemoryId = "###Memory";
		public const String Disassembly = "\u{E0C7}  Disassembly###Disassembly";
		public const String DisassemblyId = "###Disassembly";
	}

	/// The Memory panel (docs/Debugging.md, "Memory"): while the program is stopped, the bytes behind a
	/// variable or pin value of Locals (its context menu, Show in Memory), a frame of Call Stack (Show
	/// Frame in Memory) or any address typed in. Structured mode lays the type's fields over the bytes
	/// (TypeLayouts: name, offset, decoded value), Hex mode shows 16 bytes per row with the characters.
	/// A reference (a class, a pointer field) is followed to what it points at. Read through DAP
	/// readMemory (InspectRequest); refreshed at every stop; memory that cannot be read says so.
	extension EditorApp
	{
		public bool ShowMemory;
		enum MemTarget { None, Variable, Address, Frame }
		MemTarget mMemKind;
		int mMemFrame;
		String mMemVar = new .() ~ delete _;
		/// The type the bytes are read as (`Zoo.Dog`, `Zoo.Point`, `int`); "" for raw bytes.
		String mMemType = new .() ~ delete _;
		/// What is shown, for the header (`pet`, `a2.object`, `frame of Zoo.Program.Main`).
		String mMemLabel = new .() ~ delete _;
		/// How it was reached (`pet (frame slot at 0x...) holds 0x...`).
		String mMemVia = new .() ~ delete _;
		/// The variable holds a reference: read it, then follow it.
		bool mMemFollow;
		uint64 mMemAddr;
		int mMemCount;
		List<uint8> mMemBytes = new .() ~ delete _;
		String mMemError = new .() ~ delete _;
		int32 mMemPending;
		int32 mMemSerial = -1;
		/// Hex mode (else Structured when there is a type).
		public bool MemHex;
		TextBuffer mMemAddrBuf = new .(64) ~ delete _;
		TextBuffer mMemTypeBuf = new .(128) ~ delete _;
		/// Earlier targets, for Back: address and type.
		List<(uint64 addr, String type, String label)> mMemBack = new .() ~ { for (let b in _) { delete b.type; delete b.label; } delete _; };
		/// The last answer arrived (the `hood` self test waits for it).
		public int32 MemReads;

		/// Locals' Show in Memory: the variable's bytes in the selected frame; a reference is followed to
		/// its object.
		public void ShowVariableInMemory(DebugVariable v)
		{
			if (mDebug == null || !mDebug.IsStopped)
				return;
			mMemKind = .Variable;
			mMemFrame = mDebug.SelectedFrame;
			mMemVar.Set(v.Name);
			mMemLabel.Set(v.Label.IsEmpty ? v.Name : v.Label);
			mMemType.Clear();
			mMemFollow = false;
			// a reference: its value reads `Zoo.Dog (0x...)`, the object's own type first
			let layout = TypeLayouts.Get(FrontEnd, v.Type);
			if (v.Type.EndsWith('*'))
			{
				mMemFollow = true;
				mMemType.Set(v.Type.Substring(0, v.Type.Length - 1));
			}
			else if (layout != null && layout.Ok && layout.IsClass)
			{
				mMemFollow = true;
				let sp = v.Value.IndexOf(" (0x");
				mMemType.Set((sp > 0) ? v.Value.Substring(0, sp) : v.Type);
			}
			else
				mMemType.Set(v.Type);
			mMemTypeBuf.Set(mMemType);
			ShowMemory = true;
			mMemFocus = 2;
			MemRead();
		}

		/// Call Stack's Show Frame in Memory: the frame's stack bytes (from the stack pointer to just above
		/// the frame pointer: the locals and spill slots, the saved frame pointer, the return address).
		public void ShowFrameInMemory(int frameIndex)
		{
			if (mDebug == null || !mDebug.IsStopped || frameIndex < 0 || frameIndex >= mDebug.Frames.Count)
				return;
			mMemKind = .Frame;
			mMemFrame = frameIndex;
			let f = mDebug.Frames[frameIndex];
			mMemLabel.Set(scope $"frame of {(f.SheetName.IsEmpty ? f.Name : f.SheetName)}");
			mMemType.Clear();
			mMemTypeBuf.Set("");
			MemHex = true;
			ShowMemory = true;
			mMemFocus = 2;
			MemRead();
		}

		/// Any address, read as `type` ("" for raw bytes).
		public void ShowAddressInMemory(uint64 addr, StringView type, StringView label)
		{
			if (mMemKind != .None && mMemAddr != 0)
				mMemBack.Add((mMemAddr, new String(mMemType), new String(mMemLabel)));
			mMemKind = .Address;
			mMemAddr = addr;
			mMemType.Set(type);
			mMemTypeBuf.Set(type);
			mMemLabel.Set(label);
			mMemVia.Clear();
			mMemFollow = false;
			ShowMemory = true;
			MemRead();
		}

		int mMemFocus;

		TypeLayout MemLayout()
		{
			if (mMemType.IsEmpty)
				return null;
			let l = TypeLayouts.Get(FrontEnd, mMemType);
			return (l != null && l.Ok) ? l : null;
		}

		int MemWanted()
		{
			let l = MemLayout();
			int n = (l != null) ? (int)Math.Min(l.Size, 4096) : 0;
			n = Math.Max(n, MemHex ? 128 : 16);
			return (n + 15) / 16 * 16;
		}

		void MemRead()
		{
			mMemError.Clear();
			mMemBytes.Clear();
			if (mDebug == null || !mDebug.IsStopped)
			{
				mMemError.Set("Memory can be read only while the program is stopped.");
				return;
			}
			mMemSerial = mDebug.StopSerial;
			InspectRequest r = new .();
			switch (mMemKind)
			{
			case .None:
				delete r;
				return;
			case .Variable:
				r.What = .Variable;
				r.Frame = mMemFrame;
				r.Expression.Set(mMemVar);
				r.Count = MemWanted();
				r.Follow = mMemFollow;
			case .Address:
				r.What = .Memory;
				r.Address = mMemAddr;
				r.Count = MemWanted();
			case .Frame:
				r.What = .Frame;
				r.Frame = mMemFrame;
			}
			mMemPending = mDapAdapter.Inspect(r);
		}

		/// Takes the answer of the pending read (and asks the next one: a reference's object, a frame's bytes).
		void MemPoll()
		{
			if (mMemPending == 0)
			{
				if (mMemKind != .None && mDebug != null && mDebug.IsStopped && mDebug.StopSerial != mMemSerial)
					MemRead(); // a step or a new stop: read again
				return;
			}
			let r = mDapAdapter.TakeInspect(mMemPending);
			if (r == null)
			{
				if (mDebug == null || !mDebug.IsStopped)
				{
					mMemPending = 0;
					mMemError.Set("The program is running: memory is read when it stops.");
				}
				return;
			}
			defer delete r;
			mMemPending = 0;
			MemReads++;
			if (r.Failed)
			{
				mMemError.Set(r.Error);
				return;
			}
			if (r.What == .Frame)
			{
				let sp = r.Result;
				let fp = r.Result2;
				int count = 256;
				if (fp > sp && fp - sp < 8192)
					count = (int)(fp - sp) + 16;
				mMemVia.Set(scope $"stack pointer 0x{sp:X}, frame pointer 0x{fp:X}; the frame pointer's slot holds the caller's, the next 8 bytes the return address");
				mMemAddr = sp;
				InspectRequest m = new .();
				m.What = .Memory;
				m.Address = sp;
				m.Count = (count + 15) / 16 * 16;
				mMemPending = mDapAdapter.Inspect(m);
				return;
			}
			if (r.What == .Variable)
			{
				if (r.Followed)
					mMemVia.Set(scope $"{mMemLabel} holds 0x{r.Address:X}: the bytes below are what it references, not the variable");
				else
					mMemVia.Set(scope $"{mMemLabel} is stored at 0x{r.Address:X}");
			}
			mMemAddr = r.Address;
			mMemBytes.Clear();
			mMemBytes.AddRange(r.Bytes);
			mMemAddrBuf.Set(scope $"0x{mMemAddr:X}");
		}

		void DrawMemoryPanel()
		{
			if (!ShowMemory)
				return;
			MemPoll();
			if (mMemFocus > 0 && --mMemFocus == 0)
				Panels.Focus(HoodPanels.MemoryId);
			if (Gui.Begin(HoodPanels.Memory, &ShowMemory))
			{
				DrawMemoryBody();
			}
			Gui.End();
		}

		void DrawMemoryBody()
		{
			if (mDebug == null || !mDebug.IsStopped)
			{
				Gui.igPushTextWrapPos(0);
				Gui.TextDisabled("Memory shows the bytes behind a variable while the program is stopped: right-click a row of Locals > Show in Memory, a frame of Call Stack > Show Frame in Memory, or type an address here when stopped.");
				Gui.igPopTextWrapPos();
				return;
			}
			// the address and the type to read it as
			Gui.igSetNextItemWidth(150 * Look.Scale);
			if (Gui.igInputTextWithHint("##memaddr", "address (0x...)", mMemAddrBuf.Ptr, (.)mMemAddrBuf.Capacity, InputTextFlags.EnterReturnsTrue, null, null))
			{
				if (LldbDapAdapter.ParseAddress(mMemAddrBuf.View, var a))
					ShowAddressInMemory(a, mMemTypeBuf.View, scope $"0x{a:X}");
				else
					mMemError.Set("Type an address: 0x followed by hex digits, or a decimal number.");
			}
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip("Any address of the program: Enter reads it (with the type on the right, or as bytes)");
			Gui.SameLine();
			Gui.igSetNextItemWidth(150 * Look.Scale);
			if (Gui.igInputTextWithHint("##memtype", "as type (Zoo.Point)", mMemTypeBuf.Ptr, (.)mMemTypeBuf.Capacity, InputTextFlags.EnterReturnsTrue, null, null))
			{
				mMemType.Set(mMemTypeBuf.View);
				mMemType.Trim();
				if (mMemKind == .Address)
					MemRead();
			}
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip("The type whose fields are laid over the bytes (Structured); empty: bytes only");
			Gui.SameLine();
			if (HoodGui.Toggle("##memmode", "Structured", "Hex", ref MemHex, "Structured: the fields of the type over the bytes. Hex: 16 bytes per row with their characters."))
			{
				if (mMemBytes.Count < MemWanted() && mMemKind != .None)
					MemRead();
			}
			if (!mMemBack.IsEmpty)
			{
				Gui.SameLine();
				if (Gui.SmallButton("Back"))
				{
					let b = mMemBack.PopBack();
					mMemKind = .Address;
					mMemAddr = b.addr;
					mMemType.Set(b.type);
					mMemTypeBuf.Set(b.type);
					mMemLabel.Set(b.label);
					mMemVia.Clear();
					delete b.type;
					delete b.label;
					MemRead();
				}
			}
			Gui.SameLine();
			if (Gui.SmallButton("Copy"))
			{
				String all = scope .();
				MemHexText(all);
				Gui.igSetClipboardText(all);
			}
			if (mMemKind == .None)
			{
				Gui.igPushTextWrapPos(0);
				Gui.TextDisabled("Right-click a row of Locals > Show in Memory, or a frame of Call Stack > Show Frame in Memory.");
				Gui.igPopTextWrapPos();
				return;
			}
			// one line: what, as which type, where (how it was reached in the tooltip)
			String head = scope .(mMemLabel);
			if (!mMemVia.IsEmpty && mMemVia.Contains("references"))
				head.Append("  \u{2192}");
			if (!mMemType.IsEmpty)
				head.AppendF("  {}", mMemType);
			if (mMemAddr != 0)
				head.AppendF("  at 0x{:X}", mMemAddr);
			if (mMemPending != 0)
				head.Append("  (reading...)");
			Gui.TextColored(Look.ForegroundDim, head);
			if (Gui.igIsItemHovered(0) && !mMemVia.IsEmpty)
				Gui.Tooltip(mMemVia);
			if (!mMemError.IsEmpty)
			{
				Gui.igPushTextWrapPos(0);
				Gui.TextColored(Look.Warning, mMemError);
				Gui.igPopTextWrapPos();
			}
			if (mMemBytes.IsEmpty)
				return;
			let l = MemLayout();
			if (!MemHex && l == null && !mMemType.IsEmpty)
				Gui.TextDisabled(scope $"No layout for {mMemType}: the bytes are shown in Hex.");
			Gui.igBeginChild_Str("##membytes", .(0, 0), 0, 0);
			if (MemHex || l == null)
				DrawMemoryHex(l);
			else
				DrawMemoryFields(l);
			Gui.igEndChild();
		}

		/// Structured: one row per field down to basic values, the padding between them muted.
		void DrawMemoryFields(TypeLayout l)
		{
			if (!Gui.igBeginTable("##memfields", 4, TableFlags.RowBg | TableFlags.BordersInnerV | TableFlags.Resizable, .(0, 0), 0))
				return;
			Gui.igTableSetupColumn("Offset", TableColumnFlags.WidthFixed, 52 * Look.Scale, 0);
			Gui.igTableSetupColumn("Field", TableColumnFlags.WidthStretch, 1.0f, 0);
			Gui.igTableSetupColumn("Value", TableColumnFlags.WidthStretch, 1.3f, 0);
			Gui.igTableSetupColumn("Bytes", TableColumnFlags.WidthStretch, 1.0f, 0);
			HoodGui.igTableHeadersRow();
			let mono = PropertyGrid.MonoFont;
			// leaves and padding in offset order
			List<LayoutRow> rows = scope .();
			for (let r in l.Leaves)
				rows.Add(r);
			for (let r in l.Rows)
				if (r.Kind == .Padding)
					rows.Add(r);
			rows.Sort(scope (a, b) => (a.Offset != b.Offset) ? (a.Offset <=> b.Offset) : ((a.Kind == .Padding ? 1 : 0) <=> (b.Kind == .Padding ? 1 : 0)));
			for (let r in rows)
			{
				Gui.igTableNextRow(0, 0);
				Gui.PushID((int32)@r.Index);
				bool muted = r.Kind == .Padding;
				let col = muted ? Look.ForegroundDim : Look.Foreground;
				Gui.igTableSetColumnIndex(0);
				Gui.TextColored(col, scope $"{r.Offset}");
				Gui.igTableSetColumnIndex(1);
				let p = Gui.igGetCursorScreenPos();
				let h = Gui.igGetTextLineHeight();
				if (!muted)
				{
					Gui.ImDrawList_AddRectFilled(Gui.igGetWindowDrawList(), .(p.x, p.y + h * 0.2f), .(p.x + 4 * Look.Scale, p.y + h * 0.8f), RowColor(r), 1, 0);
					Gui.igSetCursorScreenPos(.(p.x + 8 * Look.Scale, p.y));
				}
				Gui.TextColored(col, r.Name);
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip(scope $"{r.Name}  {r.Type}\nbytes {r.Offset} to {r.Offset + r.Size - 1} of the {(l.IsClass ? "object" : "value")}{(r.Case.IsEmpty ? "" : "\nmeaningful when the value is ")}{r.Case}");
				Gui.igTableSetColumnIndex(2);
				String val = scope .();
				if (!muted)
					MemDecode(r, l, val);
				Gui.TextColored(col, val);
				if (r.Pointer && !muted)
				{
					let ptr = MemRaw(r.Offset, 8);
					if (ptr != 0 && r.Kind != .VTable)
					{
						Gui.SameLine();
						if (Gui.SmallButton("Follow"))
							ShowAddressInMemory(ptr, r.Target, scope $"{mMemLabel}.{r.Name}");
						if (Gui.igIsItemHovered(0))
							Gui.Tooltip(scope $"Show what {r.Name} points at (0x{ptr:X}){(r.Target.IsEmpty ? "" : " as ")}{r.Target}");
					}
				}
				Gui.igTableSetColumnIndex(3);
				String bytes = scope .();
				for (int64 i = r.Offset; i < Math.Min(r.Offset + Math.Min(r.Size, 16), mMemBytes.Count); i++)
					bytes.AppendF("{:X2} ", mMemBytes[i]);
				if (r.Size > 16)
					bytes.Append("...");
				if (mono != null)
					Gui.igPushFont(mono, Gui.igGetFontSize() / Math.Max(Look.Scale, 0.5f) * 0.92f);
				Gui.TextColored(Look.ForegroundDim, bytes);
				if (mono != null)
					Gui.igPopFont();
				Gui.PopID();
			}
			Gui.igEndTable();
		}

		/// Little-endian bytes at `offset` (at most 8), 0 outside what was read.
		uint64 MemRaw(int64 offset, int64 size)
		{
			uint64 v = 0;
			if (offset < 0 || offset + size > mMemBytes.Count)
				return 0;
			for (int i < Math.Min(size, 8))
				v |= (uint64)mMemBytes[offset + i] << (8 * i);
			return v;
		}

		/// The value of a leaf from the bytes read, as the Locals would write it.
		public void MemDecode(LayoutRow r, TypeLayout l, String o)
		{
			DecodeLeaf(r, l, mMemBytes, 0, o);
		}

		/// Decodes the leaf `r` of layout `l` from `bytes` (the value starting at `start`).
		public static void DecodeLeaf(LayoutRow r, TypeLayout l, List<uint8> bytes, int64 start, String o)
		{
			let off = start + r.Offset;
			if (off < 0 || off + r.Size > bytes.Count)
			{
				o.Append("(outside the bytes read)");
				return;
			}
			uint64 raw = 0;
			for (int i < Math.Min(r.Size, 8))
				raw |= (uint64)bytes[off + i] << (8 * i);
			switch (r.TypeKind)
			{
			case .Bool:
				o.Append((raw == 0) ? "false" : ((raw == 1) ? "true" : scope $"true (0x{raw:X2})"));
			case .Int:
				int64 v;
				if (r.Signed && r.Bits < 64 && r.Bits > 0 && (raw & (1UL << (r.Bits - 1))) != 0)
					v = (int64)(raw | (~0UL << r.Bits));
				else
					v = (int64)raw;
				let name = l.CaseName(r.Type, v);
				if (!name.IsEmpty)
					o.AppendF("{} ({})", name, v);
				else if (r.Signed || r.Bits < 64)
					o.AppendF("{}", v);
				else
					o.AppendF("{}", raw);
			case .Char8:
				if (raw >= 32 && raw < 127)
					o.AppendF("'{}' ({})", (char8)raw, raw);
				else
					o.AppendF("{} (0x{:X2})", raw, raw);
			case .Char32:
				o.AppendF("U+{:X4}", raw);
				if (raw >= 32 && raw < 0x110000 && (raw < 0xD800 || raw > 0xDFFF))
					o.AppendF(" '{}'", (char32)raw);
			case .Float:
				if (r.Bits == 32)
				{
					uint32 b = (uint32)raw;
					o.AppendF("{}", *(float*)&b);
				}
				else
				{
					uint64 b = raw;
					o.AppendF("{}", *(double*)&b);
				}
			default:
				if (r.Pointer || r.TypeKind == .Pointer || r.TypeKind == .Ref || r.TypeKind == .FnPtr)
				{
					if (raw == 0)
						o.Append("null");
					else
						o.AppendF("0x{:X}", raw);
					if (r.Kind == .VTable && raw != 0)
						o.Append("  (the class's vtable)");
				}
				else
				{
					for (int i < Math.Min(r.Size, 16))
						o.AppendF("{:X2}", bytes[off + i]);
				}
			}
		}

		/// Hex: 16 bytes per row, the address, the bytes (in the colours of the fields when the type is
		/// known), the characters.
		void DrawMemoryHex(TypeLayout l)
		{
			let mono = PropertyGrid.MonoFont;
			if (mono != null)
				Gui.igPushFont(mono, Gui.igGetFontSize() / Math.Max(Look.Scale, 0.5f) * 0.92f);
			let dl = Gui.igGetWindowDrawList();
			let charW = Gui.CalcTextSize("0").x;
			let lineH = Gui.igGetTextLineHeight() + 2 * Look.Scale;
			for (int row = 0; row * 16 < mMemBytes.Count; row++)
			{
				let p = Gui.igGetCursorScreenPos();
				String addr = scope $"{mMemAddr + (uint64)(row * 16):X12}";
				Gui.ImDrawList_AddText_Vec2(dl, p, Look.ForegroundDim, addr.Ptr, addr.Ptr + addr.Length);
				float x = p.x + (addr.Length + 2) * charW;
				String ascii = scope .();
				for (int i < 16)
				{
					let at = row * 16 + i;
					if (at >= mMemBytes.Count)
						break;
					let b = mMemBytes[at];
					uint32 col = Look.Foreground;
					String fieldTip = null;
					if (l != null)
					{
						col = Look.ForegroundDim;
						for (let r in l.Leaves)
							if (at >= r.Offset && at < r.Offset + r.Size)
							{
								col = Theme.Mix(RowColor(r), Look.Foreground, 0.35f);
								fieldTip = r.Name;
								break;
							}
					}
					String hx = scope $"{b:X2}";
					let bx = x + i * 3 * charW + ((i >= 8) ? charW : 0);
					Gui.ImDrawList_AddText_Vec2(dl, .(bx, p.y), col, hx.Ptr, hx.Ptr + 2);
					if (fieldTip != null && Gui.igIsMouseHoveringRect(.(bx, p.y), .(bx + 2 * charW, p.y + lineH), true) && Gui.igIsWindowHovered(0))
						Gui.Tooltip(scope $"{fieldTip}: byte {at}");
					ascii.Append((b >= 32 && b < 127) ? (char8)b : '.');
				}
				let ax = x + (16 * 3 + 2) * charW;
				Gui.ImDrawList_AddText_Vec2(dl, .(ax, p.y), Look.ForegroundDim, ascii.Ptr, ascii.Ptr + ascii.Length);
				Gui.igDummy(.(ax - p.x + 17 * charW, lineH));
			}
			if (mono != null)
				Gui.igPopFont();
		}

		/// The bytes as text (Copy): `address  bytes  characters` per 16.
		void MemHexText(String o)
		{
			for (int row = 0; row * 16 < mMemBytes.Count; row++)
			{
				o.AppendF("{:X12}  ", mMemAddr + (uint64)(row * 16));
				String ascii = scope .();
				for (int i < 16)
				{
					let at = row * 16 + i;
					if (at < mMemBytes.Count)
					{
						o.AppendF("{:X2} ", mMemBytes[at]);
						let b = mMemBytes[at];
						ascii.Append((b >= 32 && b < 127) ? (char8)b : '.');
					}
					else
						o.Append("   ");
				}
				o.AppendF(" {}\n", ascii);
			}
		}

		// ---- the hooks in Locals and Call Stack (one line each in Debugger.bf)

		/// The context menu of a Locals row (the last item): Show in Memory, Copy Value.
		void HoodVariableMenu(DebugVariable v)
		{
			if (!Gui.igBeginPopupContextItem(null, 1))
				return;
			if (Gui.MenuItem("Show in Memory"))
				ShowVariableInMemory(v);
			if (Gui.MenuItem("Copy Value"))
				Gui.igSetClipboardText(scope String(v.Value));
			Gui.EndPopup();
		}

		/// The context menu of a Call Stack frame row: Show Frame in Memory, Disassembly.
		void HoodFrameMenu(DebugFrame f, int index)
		{
			if (!Gui.igBeginPopupContextItem(null, 1))
				return;
			if (Gui.MenuItem("Show Frame in Memory"))
			{
				mDebug.SelectFrame(index);
				ShowFrameInMemory(index);
			}
			if (Gui.MenuItem("Disassembly", "", false, f.IsUser))
			{
				mDebug.SelectFrame(index);
				OpenDisassembly(f.Unit, f.SheetKey, f.SheetName);
			}
			Gui.EndPopup();
		}
	}
}
