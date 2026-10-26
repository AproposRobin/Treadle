using System;
using System.Collections;
using ImGui;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Model;

namespace Treadle.Editor
{
	/// Renaming in place in the Outline: a double-click (or F2) on a function, variable or local row turns
	/// its name into a text field, all of it selected; Enter (or clicking away) commits, Esc cancels. The
	/// field and the Properties Name field share one text buffer (TsBuf), so each shows the other's typing
	/// as it happens; the Sheet tabs, the Get / Set / Call nodes and the header follow on commit.
	extension EditorApp
	{
		/// The row being renamed: its Properties Name field's id (`##mname<serial>` for a member, `##lname`
		/// for a local of the Sheet in front), empty when none.
		public String mIrId = new .() ~ delete _;
		int32 mIrSerial = -1;
		String mIrLocal = new .() ~ delete _;
		bool mIrFocus;
		bool mIrSeenActive;
		int mIrFrames;
		/// The id of the Properties Name field being typed in (the Outline row shows its text), else empty.
		String mTsActiveId = new .() ~ delete _;
		/// Self tests: text to put in the open inline field and commit (or cancel, `mIrTestCancel`) on its next frame.
		public String mIrTestText = new .() ~ delete _;
		public bool mIrTestCancel;
		/// How many inline renames began (the self test).
		public int InlineRenamesStarted;

		public void StartInlineRename(MemberDecl m)
		{
			if (m == null || m.Kind == .Ctor || m.Kind == .Dtor || !CheckWritable())
				return;
			mIrId.Set(scope $"##mname{m.Serial}");
			mIrSerial = m.Serial;
			mIrLocal.Clear();
			TsBuf(mIrId, m.Name).Set(m.Name);
			BeginInlineRename();
		}

		public void StartInlineRenameLocal(StringView name)
		{
			if (!CheckWritable())
				return;
			mIrId.Set("##lname");
			mIrSerial = -1;
			mIrLocal.Set(name);
			TsBuf(mIrId, name).Set(name);
			BeginInlineRename();
		}

		/// F2 / Rename... on the Outline: the selected function, variable or local is renamed in its row;
		/// anything else (a case, a constructor's page) in its Properties Name field.
		public void StartOutlineRename()
		{
			if (OutlineSel == .Local && mSelLocalActive)
			{
				StartInlineRenameLocal(mSelLocalName);
				return;
			}
			let m = SelectedMember;
			if (OutlineSel == .Member && m != null && (m.Kind == .Function || m.Kind == .Field))
			{
				bool hasBody = m.Kind == .Field;
				for (let s in Doc.Sheets)
					hasBody |= s.Member == m && s.Role == .Body;
				if (hasBody)
				{
					StartInlineRename(m);
					return;
				}
			}
			FocusNameField();
		}

		void BeginInlineRename()
		{
			mIrFocus = true;
			mIrSeenActive = false;
			mIrFrames = 0;
			InlineRenamesStarted++;
		}

		public void EndInlineRename()
		{
			mIrId.Clear();
			mIrSerial = -1;
			mIrLocal.Clear();
		}

		public bool InlineRenaming(MemberDecl m) => m != null && !mIrId.IsEmpty && mIrSerial == m.Serial;
		public bool InlineRenamingLocal(StringView name) => !mIrId.IsEmpty && mIrSerial < 0 && mIrLocal == name;

		/// The name a row shows: the text being typed for it (its inline field or its Properties Name
		/// field), else `current`.
		StringView LiveName(StringView id, StringView current)
		{
			if ((mTsActiveId == id || mIrId == id) && mTsBufs.TryGetValueAlt(id, let buf))
				return buf;
			return current;
		}

		/// The in-place field over a row's name at `pos`, `width` wide. 1 when committed (the text in
		/// `outValue`), -1 when cancelled, 0 while typing. The cursor is left where it was.
		int InlineRenameField(ImVec2 pos, float width, String outValue)
		{
			let buf = TsBuf(mIrId, "");
			let back = Gui.igGetCursorScreenPos();
			Gui.igSetCursorScreenPos(.(pos.x, pos.y - 2 * Look.Scale));
			Gui.igSetNextItemWidth(Math.Max(40 * Look.Scale, width));
			if (mIrFocus)
			{
				Gui.igSetKeyboardFocusHere(0);
				mIrFocus = false;
			}
			bool esc = Gui.IsKeyPressed(Key.Escape, false);
			// The field's frame in the accent colour: it is plain that the row is being renamed.
			Gui.igPushStyleColor_U32(Col.Border, Look.AccentBlue);
			Gui.igPushStyleVar_Float(StyleVar.FrameBorderSize, 1.5f * Look.Scale);
			bool done = PropertyGrid.Text("##inlinerename", buf, ?);
			Gui.igPopStyleVar(1);
			Gui.igPopStyleColor(1);
			bool active = Gui.igIsItemActive();
			Gui.igSetCursorScreenPos(back);
			Gui.igDummy(.(0, 0));
			mIrSeenActive |= active;
			mIrFrames++;
			if (!mIrTestText.IsEmpty || mIrTestCancel)
			{
				// Self tests: typed and committed (or cancelled) in one go.
				if (mIrTestCancel)
				{
					mIrTestCancel = false;
					mIrTestText.Clear();
					return -1;
				}
				buf.Set(mIrTestText);
				mIrTestText.Clear();
				outValue.Set(buf);
				return 1;
			}
			if (esc)
				return -1;
			if (done)
			{
				outValue.Set(buf);
				return 1;
			}
			// Clicked away without typing, or the field never took the keyboard.
			if ((mIrSeenActive && !active) || (!mIrSeenActive && mIrFrames > 10))
				return -1;
			return 0;
		}

		/// The inline field of a member row (a function or a variable), drawn after the row; commits with
		/// RenameMember.
		void InlineRenameMemberRow(MemberDecl m, ImVec2 namePos, float width)
		{
			String v = scope .();
			let r = InlineRenameField(namePos, width, v);
			if (r == 0)
				return;
			String id = scope .(mIrId);
			EndInlineRename();
			v.Trim();
			if (r > 0 && !v.IsEmpty && v != m.Name)
				RenameMember(m, v);
			if (mTsBufs.TryGetValueAlt(id, let buf))
				buf.Set(m.Name);
		}

		/// The inline field of a local's row; commits with RenameLocal.
		void InlineRenameLocalRow(Sheet mg, LocalDecl l, ImVec2 namePos, float width)
		{
			String v = scope .();
			let r = InlineRenameField(namePos, width, v);
			if (r == 0)
				return;
			EndInlineRename();
			v.Trim();
			if (r > 0 && !v.IsEmpty && v != l.Name)
				RenameLocal(mg, l, v);
			if (mTsBufs.TryGetValueAlt("##lname", let buf))
				buf.Set(l.Name);
		}

		/// Renames a local variable of `mg`: its Get / Set nodes follow. One undo step.
		public bool RenameLocal(Sheet mg, LocalDecl l, StringView newNameIn)
		{
			String v = scope .(newNameIn);
			v.Trim();
			if (v.IsEmpty || v == l.Name)
				return false;
			if (mg.Graph.FindLocal(v) != null)
			{
				SetStatus(scope $"Can't rename to '{v}': the function has a local of that name", .Warning);
				return false;
			}
			if (!BeginTypeEdit())
				return false;
			String old = scope $"local:{l.Name}";
			l.Name.Set(v);
			mSelLocalName.Set(v);
			for (let n in mg.Graph.Nodes)
				if ((n.Kind == .Get || n.Kind == .Set) && n.Text == old)
					n.Text.Set(scope $"local:{v}");
			mg.Graph.Version++;
			EndTypeEdit();
			return true;
		}
	}
}
