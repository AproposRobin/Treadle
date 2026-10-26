using System;
using System.Collections;
using ImGui;
using Treadle.Graph;
using Treadle.Catalog;

namespace Treadle.Editor
{
	/// The typed control of an unwired input pin (docs/Editor-UI.md > Pin values): a checkbox, a
	/// dropdown of an enum's members, a text / number / character field that writes the literal
	/// (`"text"`, `1.5f`, `'x'`, `.Member`) and refuses what the type cannot hold. Used on the node
	/// canvas and in the Properties panel; the rules are `PinValue` in the core.
	class PinValueEditor
	{
		TextBuffer mBuf = new .(1024) ~ delete _;
		/// The pin being typed into and what is typed (the pin's Default changes only when it is accepted).
		int32 mEditPin;
		int32 mCurrentId;
		String mEditText = new .() ~ delete _;
		/// The pin whose last value was refused: its frame stays red for a moment.
		int32 mRejectPin;
		int32 mRejectFrames;
		/// The last refusal, for the self test.
		public String LastRefusal = new .() ~ delete _;
		public int32 RefusalCount;
		/// Self test: open this enum pin's dropdown on the next draw / keep this pin showing typed text.
		public int32 SelfTestOpenPin;
		public int32 SelfTestHold;
		public bool SelfTestClose;
		/// Self test: open the colour picker of this pin on the next draw (captures).
		public int32 SelfTestOpenPicker;
		/// The dropdown button's colour (0: the Properties input colour); the canvas uses its inline field colour.
		public uint32 ButtonColor;

		/// Self test: the pin looks as if `text` were being typed into it (the frame turns red when the type cannot hold it).
		public void SelfTestType(int32 id, StringView text)
		{
			mEditPin = id;
			mEditText.Set(text);
			SelfTestHold = id;
		}

		public void SelfTestRelease()
		{
			SelfTestHold = 0;
			SelfTestOpenPin = 0;
			mEditPin = 0;
			mRejectFrames = 0;
		}

		/// True for the kinds this editor draws.
		public static bool Handles(PinValueKind k) => k == .Bool || k == .Enum || k == .Text || k == .Number || k == .Char || k == .Vector || k == .Fields;

		public static StringView Hint(PinValueKind k)
		{
			switch (k)
			{
			case .Text: return "text";
			case .Number: return "0";
			case .Char: return "a";
			default: return "";
			}
		}

		/// Width in grid units a field of this kind needs for the pin's current value.
		public static float Width(PinValueKind kind, Pin p, Treadle.Language.ITypeSystem types)
		{
			switch (kind)
			{
			case .Char:
				return 44;
			case .Vector:
				// One field per lane up to 4 (a checkbox for a mask), one splat field above.
				let lanes = Treadle.Model.VectorTypes.LanesOf(p.TypeName);
				if (lanes > 4)
				{
					String s = scope .();
					PinValue.Display(kind, p.TypeName, p.Default, s);
					return Math.Clamp(Gui.CalcTextSize(s).x + 18, 56, 260);
				}
				let mask = p.TypeName.StartsWith("bool");
				return lanes * (mask ? 24 : 40) + (lanes - 1) * 3;
			case .Fields:
				// One field per struct field, a swatch in front for a colour.
				if (!PinValue.MathInfo(p.TypeName, let count, ?, ?))
					return 120;
				return count * 40 + (count - 1) * 3 + (PinValue.IsColor(p.TypeName) ? cSwatchW + 3 : 0);
			case .Enum:
				List<String> members = scope .();
				defer { ClearAndDeleteItems!(members); }
				PinValue.Members(p.TypeName, types, members);
				float w = Gui.CalcTextSize("(choose)").x;
				for (let m in members)
					w = Math.Max(w, Gui.CalcTextSize(m).x);
				return Math.Clamp(w + 38, 70, 240);
			default:
				String s = scope .();
				PinValue.Display(kind, p.TypeName, p.Default, s);
				return Math.Clamp(Gui.CalcTextSize(s).x + 18, (kind == .Number) ? 56 : 64, 260);
			}
		}

		/// Draws the control at the cursor. True when the pin's value was changed: the edit has begun
		/// (`app.BeginEdit()`) and `node.Edited` is set; the caller commits it.
		public bool Draw(EditorApp app, Node node, Pin p, PinValueKind kind, float width)
		{
			return Draw(app, node, p.Id, p.TypeName, p.Default, p.Optional, kind, width);
		}

		/// The same for any value text (a pin's Default, a switch case's label): `id` keeps the
		/// fields apart, `value` is changed in place.
		public bool Draw(EditorApp app, Node node, int32 id, StringView typeName, String value, bool optional, PinValueKind kind, float width)
		{
			Gui.PushID(id);
			defer Gui.PopID();
			mCurrentId = id;
			let start = Gui.igGetCursorScreenPos();
			bool changedValue = false;
			switch (kind)
			{
			case .Bool:
				bool v = value == "true";
				if (Gui.Checkbox("##b", &v))
				{
					app.BeginEdit();
					value.Set(v ? "true" : "false");
					changedValue = true;
				}
			case .Enum:
				changedValue = DrawEnum(app, node, typeName, value, width);
			case .Vector:
				changedValue = DrawVector(app, node, id, typeName, value, optional, width);
			case .Fields:
				changedValue = DrawFields(app, node, id, typeName, value, optional, width);
			default:
				changedValue = DrawTyped(app, node, id, typeName, value, optional, kind, width);
			}
			if (mRejectPin == id && mRejectFrames > 0)
			{
				mRejectFrames--;
				let dl = Gui.igGetWindowDrawList();
				Gui.ImDrawList_AddRect(dl, start - .(1, 1), start + .(width + 1, Gui.igGetFrameHeight() + 1), Theme.NodeError, 3, 1.5f, 0);
			}
			return changedValue;
		}

		bool DrawEnum(EditorApp app, Node node, StringView typeName, String value, float width)
		{
			String shown = scope .();
			PinValue.Display(.Enum, typeName, value, shown);
			List<String> members = scope .();
			defer { ClearAndDeleteItems!(members); }
			PinValue.Members(typeName, app.Language.Types, members);
			bool changed = false;
			List<DropItem> items = scope .();
			int selected = -1;
			for (let m in members)
			{
				items.Add(.(m));
				if (m == shown)
					selected = @m.Index;
			}
			// The self test opens / closes the list through the shared dropdown's hooks.
			if (SelfTestOpenPin != 0 && mCurrentId == SelfTestOpenPin)
			{
				SelfTestOpenPin = 0;
				PropertyGrid.TestOpen.Set("##em");
			}
			if (SelfTestClose)
			{
				SelfTestClose = false;
				PropertyGrid.TestClose = true;
			}
			let picked = PropertyGrid.Dropdown("##em", shown.IsEmpty ? StringView("(choose)") : StringView(shown), items, selected, width, default, ButtonColor);
			if (picked >= 0 && members[picked] != shown)
			{
				app.BeginEdit();
				value.Set(".");
				value.Append(members[picked]);
				changed = true;
			}
			return changed;
		}

		/// A vector's value (SIMD-and-Vectors.md 1.9): up to 4 lanes one field each, `x y z w` as hints (a
		/// checkbox per lane for a mask), the literal joined back into one token (`0,1,0,0`; equal lanes as one
		/// splat value); above 4 lanes one field for the whole literal (one number splats).
		bool DrawVector(EditorApp app, Node node, int32 id, StringView typeName, String value, bool optional, float width)
		{
			let lanes = Treadle.Model.VectorTypes.LanesOf(typeName);
			if (lanes <= 0 || lanes > 4)
				return DrawTyped(app, node, id, typeName, value, optional, .Vector, width);
			let mask = typeName.StartsWith("bool");
			List<String> values = scope .();
			defer { ClearAndDeleteItems!(values); }
			if (!PinValue.SplitLanes(typeName, value, values))
			{
				ClearAndDeleteItems!(values);
				for (int i < lanes)
					values.Add(new String(mask ? "false" : "0"));
			}
			float gap = 3 * Look.Scale;
			float w = Math.Max(16, (width - gap * (lanes - 1)) / lanes);
			bool changed = false;
			for (int i < lanes)
			{
				if (i > 0)
					Gui.SameLine(0, gap);
				Gui.PushID((int32)i);
				defer Gui.PopID();
				// Each lane is its own field: an edit id the pin's id cannot clash with.
				let laneId = (int32)(id * 8 + i + 1) | (int32)0x40000000;
				if (mask)
				{
					bool v = values[i] == "true";
					if (Gui.Checkbox("##l", &v))
					{
						values[i].Set(v ? "true" : "false");
						changed = true;
					}
					if (Gui.igIsItemHovered(0))
						Gui.Tooltip(scope String()..AppendF("Lane {}", "xyzw"[i]));
					continue;
				}
				bool mine = mEditPin == laneId;
				mBuf.Set(mine ? (StringView)mEditText : (StringView)values[i]);
				Gui.igSetNextItemWidth(w);
				if (Gui.igInputTextWithHint("##l", scope String()..Append("xyzw"[i]), mBuf.Ptr, (.)mBuf.Capacity, 0, null, null))
				{
					mEditPin = laneId;
					mEditText.Set(mBuf.View);
					mine = true;
				}
				if (!mine)
					continue;
				String lit = scope .();
				String why = scope .();
				bool ok = PinValue.Write(.Number, "", mEditText, false, lit, why);
				if (Gui.igIsItemDeactivated())
				{
					if (ok && lit != values[i])
					{
						values[i].Set(lit);
						changed = true;
					}
					else if (!ok)
						Refuse(id, why);
					mEditPin = 0;
				}
				else if (!Gui.igIsItemActive() && SelfTestHold != laneId)
					mEditPin = 0;
				else if (!ok)
				{
					mRejectPin = id;
					mRejectFrames = 2;
				}
			}
			if (!changed)
				return false;
			String joined = scope .();
			PinValue.JoinLanes(values, joined);
			if (joined == value)
				return false;
			app.BeginEdit();
			value.Set(joined);
			return true;
		}

		/// The swatch's width in grid units (a square of the field height).
		const float cSwatchW = 22;
		/// The pin whose colour the picker is changing (one undo step for a drag in the picker).
		int32 mColorPin;

		/// A core math struct's value (`PinValue.MathInfo`): one field per struct field with its letter as the
		/// hint (`x y z`, `r g b a`, `x y w h`), the literal joined back into one token (`1,2,3`). `Color` and
		/// `Color32` have a swatch in front that opens a picker: `Color32` shows its bytes, `Color` (linear light)
		/// is shown and picked as sRGB, so the swatch looks like the colour it makes.
		bool DrawFields(EditorApp app, Node node, int32 id, StringView typeName, String value, bool optional, float width)
		{
			if (!PinValue.MathInfo(typeName, let count, let hints, let mk))
				return DrawTyped(app, node, id, typeName, value, optional, .Fields, width);
			List<String> values = scope .();
			defer { ClearAndDeleteItems!(values); }
			if (!PinValue.SplitFields(typeName, value, values))
			{
				ClearAndDeleteItems!(values);
				for (int i < count)
					values.Add(new String("0"));
			}
			float gap = 3 * Look.Scale;
			let fh = Gui.igGetFrameHeight();
			bool color = hints == "rgba";
			float fieldsW = width - (color ? fh + gap : 0);
			float w = Math.Max(16, (fieldsW - gap * (count - 1)) / count);
			bool changed = false;
			bool picked = false;
			if (color)
			{
				float[4] col = default;
				for (int i < 4)
				{
					let f = (float.Parse(values[i]) case .Ok(let v)) ? v : 0;
					col[i] = (mk == .Byte) ? f / 255 : ((i < 3) ? LinearToSrgb(f) : f);
				}
				int32 flags = ColorEditFlags.NoInputs | ColorEditFlags.NoLabel | ColorEditFlags.NoTooltip | ColorEditFlags.AlphaBar | ColorEditFlags.AlphaPreviewHalf |
					((mk == .Byte) ? cColorUint8 : cColorFloat);
				if (SelfTestOpenPicker == id)
				{
					// the popup ColorEdit4 opens on a click, in its own id scope
					SelfTestOpenPicker = 0;
					Gui.PushID("##sw");
					Gui.OpenPopup("picker");
					Gui.igSetNextWindowPos(Gui.igGetCursorScreenPos() + ImVec2(0, fh + gap), 0, .(0, 0)); // where a click opens it
					Gui.PopID();
				}
				if (Gui.igColorEdit4("##sw", &col[0], flags))
				{
					for (int i < 4)
					{
						values[i].Clear();
						if (mk == .Byte)
							values[i].AppendF("{}", (int)Math.Round(Math.Clamp(col[i], 0, 1) * 255));
						else
							FieldNumber((i < 3) ? SrgbToLinear(col[i]) : col[i], values[i]);
					}
					changed = true;
					picked = true;
				}
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip((mk == .Byte) ? "Pick a colour (sRGB bytes)" : "Pick a colour: picked as it looks (sRGB), stored in linear light");
				Gui.SameLine(0, gap);
			}
			// Too narrow for four fields with their numbers (Properties in the narrow dock): two rows of two.
			int perRow = count;
			let style = Gui.igGetStyle();
			if (count == 4 && w < Gui.CalcTextSize("-0.00").x + style.FramePadding.x * 2)
			{
				perRow = 2;
				w = Math.Max(16, (fieldsW - gap) / 2);
			}
			let rowStart = Gui.igGetCursorScreenPos();
			for (int i < count)
			{
				if (i > 0 && i % perRow == 0)
					Gui.igSetCursorScreenPos(.(rowStart.x, rowStart.y + (i / perRow) * (fh + gap)));
				else if (i > 0)
					Gui.SameLine(0, gap);
				Gui.PushID((int32)i);
				defer Gui.PopID();
				// Each field is its own text box: an edit id the pin's id cannot clash with.
				let fieldId = (int32)(id * 8 + i + 1) | (int32)0x40000000;
				bool mine = mEditPin == fieldId;
				mBuf.Set(mine ? (StringView)mEditText : (StringView)values[i]);
				Gui.igSetNextItemWidth(w);
				if (Gui.igInputTextWithHint("##f", scope String()..Append(hints[i]), mBuf.Ptr, (.)mBuf.Capacity, 0, null, null))
				{
					mEditPin = fieldId;
					mEditText.Set(mBuf.View);
					mine = true;
				}
				if (Gui.igIsItemHovered(0) && !mine)
					Gui.Tooltip(scope String()..AppendF("{} {}", FieldName(typeName, i), values[i]));
				if (!mine)
					continue;
				String lit = scope .();
				String why = scope .();
				bool ok = PinValue.Write(.Number, "", mEditText, false, lit, why);
				if (ok && (mk == .Int || mk == .Byte))
				{
					if (!(int64.Parse(lit) case .Ok(let iv)) || (mk == .Byte && (iv < 0 || iv > 255)))
					{
						ok = false;
						why.Set(scope $"'{mEditText}' is not {((mk == .Byte) ? "a whole number from 0 to 255" : "a whole number")}.");
					}
				}
				if (Gui.igIsItemDeactivated())
				{
					if (ok && lit != values[i])
					{
						values[i].Set(lit);
						changed = true;
					}
					else if (!ok)
						Refuse(id, why);
					mEditPin = 0;
				}
				else if (!Gui.igIsItemActive() && SelfTestHold != fieldId)
					mEditPin = 0;
				else if (!ok)
				{
					mRejectPin = id;
					mRejectFrames = 2;
				}
			}
			if (mColorPin == id && !Gui.igIsMouseDown_Nil(0))
				mColorPin = 0;
			if (!changed)
				return false;
			String joined = scope .();
			PinValue.JoinFields(values, joined);
			if (joined == value)
				return false;
			// a drag in the picker is one undo step
			if (!picked || mColorPin != id)
				app.BeginEdit();
			if (picked)
				mColorPin = id;
			value.Set(joined);
			return true;
		}

		const int32 cColorUint8 = 1 << 23; // ImGuiColorEditFlags_Uint8
		const int32 cColorFloat = 1 << 24; // ImGuiColorEditFlags_Float

		/// The struct field a math type's field index stands for (`X`, `Width`, `R`).
		static StringView FieldName(StringView typeName, int i)
		{
			PinValue.MathInfo(typeName, ?, let hints, ?);
			if (hints == "rgba")
				return StringView[?]("R", "G", "B", "A")[i];
			if (hints == "xywh")
				return StringView[?]("X", "Y", "Width", "Height")[i];
			return StringView[?]("X", "Y", "Z", "W")[i];
		}

		/// A picked component as a literal: at most 4 decimals, no trailing zeros (`0.5`, `1`).
		static void FieldNumber(float v, String outText)
		{
			let r = Math.Round(v * 10000) / 10000;
			outText.AppendF("{}", r);
			if (outText.IsEmpty || outText == "-0")
				outText.Set("0");
		}

		public static float LinearToSrgb(float c)
		{
			let x = Math.Clamp(c, 0, 1);
			return (x <= 0.0031308f) ? x * 12.92f : 1.055f * Math.Pow(x, 1 / 2.4f) - 0.055f;
		}

		public static float SrgbToLinear(float c)
		{
			let x = Math.Clamp(c, 0, 1);
			return (x <= 0.04045f) ? x / 12.92f : Math.Pow((x + 0.055f) / 1.055f, 2.4f);
		}

		bool DrawTyped(EditorApp app, Node node, int32 id, StringView typeName, String value, bool optional, PinValueKind kind, float width)
		{
			bool mine = mEditPin == id;
			String shown = scope .();
			if (mine)
				shown.Set(mEditText);
			else
				PinValue.Display(kind, typeName, value, shown);
			mBuf.Set(shown);
			Gui.igSetNextItemWidth(width);
			bool typed = Gui.igInputTextWithHint("##t", scope String(Hint(kind)), mBuf.Ptr, (.)mBuf.Capacity, 0, null, null);
			if (typed)
			{
				mEditPin = id;
				mEditText.Set(mBuf.View);
				mine = true;
			}
			if (!mine)
				return false;
			bool committed = false;
			String lit = scope .();
			String why = scope .();
			bool ok = PinValue.Write(kind, typeName, mEditText, optional, lit, why);
			if (Gui.igIsItemDeactivated())
			{
				String cur = scope .();
				PinValue.Display(kind, typeName, value, cur);
				if (mEditText != cur)
				{
					if (ok)
					{
						if (lit != value)
						{
							app.BeginEdit();
							value.Set(lit);
							committed = true;
						}
					}
					else
						Refuse(id, why);
				}
				mEditPin = 0;
			}
			else if (!Gui.igIsItemActive() && SelfTestHold != id)
				mEditPin = 0;
			else if (!ok)
			{
				// Typing something the type cannot hold: the frame turns red while it stays so.
				mRejectPin = id;
				mRejectFrames = 2;
			}
			return committed;
		}

		void Refuse(int32 id, StringView why)
		{
			mRejectPin = id;
			mRejectFrames = 120;
			LastRefusal.Set(why);
			RefusalCount++;
			Notify.Warn(why);
		}
	}
}
