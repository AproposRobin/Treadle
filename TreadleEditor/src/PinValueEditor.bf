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
		public static bool Handles(PinValueKind k) => k == .Bool || k == .Enum || k == .Text || k == .Number || k == .Char || k == .Vector;

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
