using System;
using System.Collections;
using ImGui;
using Treadle.Document;
using Treadle.Model;

namespace Treadle.Editor
{
	/// The Outline's Inherited group under VARIABLES: the variables of the base classes this class can use
	/// (public and protected, up the chain of the project's classes), each with its type pill and its owner
	/// dimmed on the right. A row drags like an own variable (onto a pin: a Get or a Set; onto the Sheet: Ctrl
	/// Get, Alt Set, else the Get / Set menu); it cannot be renamed or deleted here (it belongs to the base).
	extension EditorApp
	{
		/// How many inherited rows the Outline drew last frame (the self test).
		public int OutlineInheritedRows;

		/// The base classes' visible fields, nearest base first: (owner's short name, field).
		void InheritedFields(TypeDecl h, List<(StringView owner, MemberDecl field)> outFields)
		{
			if (h.Kind != .Class || h.Base == null || h.Base.IsNone)
				return;
			RefreshProjectTypes();
			HashSet<String> seen = scope .();
			String baseName = scope .();
			h.Base.ToString(baseName);
			var t = ProjectTypes.Find(baseName);
			for (int depth = 0; t != null && depth < 32; depth++)
			{
				if (seen.Contains(t.FullName))
					break;
				seen.Add(t.FullName);
				for (let m in t.Members)
					if (m.Kind == .Field && ProjectType.Visible(m))
						outFields.Add((t.Name, m));
				if (t.Base.IsEmpty)
					break;
				t = ProjectTypes.Find(t.Base);
			}
		}

		/// The Inherited group (collapsible, closed by default when the class has variables of its own).
		void DrawInheritedFields()
		{
			OutlineInheritedRows = 0;
			List<(StringView owner, MemberDecl field)> fields = scope .();
			InheritedFields(Doc.Header, fields);
			if (fields.IsEmpty)
				return;
			if (!CategoryHeader("Inherited", fields.Count))
				return;
			float h = Gui.igGetTextLineHeight();
			for (let f in fields)
			{
				let m = f.field;
				if (!BPMatches(m.Name))
					continue;
				Gui.PushID((int32)(30000 + @f.Index));
				let cur = Gui.igGetCursorScreenPos() + ImVec2(14 * Look.Scale, 0);
				Gui.Selectable("##inherited", false);
				String type = scope .();
				m.Type?.ToString(type);
				let dl = Gui.igGetWindowDrawList();
				Gui.ImDrawList_AddRectFilled(dl, .(cur.x + 14 * Look.Scale, cur.y + h * 0.22f), .(cur.x + 34 * Look.Scale, cur.y + h * 0.78f), Theme.TypeColor(type), h * 0.3f, 0);
				Gui.DrawText(dl, .(cur.x + 42 * Look.Scale, cur.y), Look.Foreground, m.Name);
				{
					let max = Gui.igGetItemRectMax();
					String fit = scope .();
					float nameW = 42 * Look.Scale + Gui.CalcTextSize(m.Name).x + 12 * Look.Scale;
					FitText(f.owner, Math.Max(0, max.x - cur.x - nameW), fit);
					float tw = Gui.CalcTextSize(fit).x;
					Gui.DrawText(dl, .(max.x - tw - 4 * Look.Scale, cur.y), Gui.Color(120, 120, 120), fit);
				}
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip(scope $"{m.Name} : {type}, inherited from {f.owner}{(m.Init != null ? scope $" (starts at {m.Init})" : "")}\nDrag onto a pin to wire it, or onto the Sheet: Ctrl = Get, Alt = Set\nRename or delete it in {f.owner}");
				AddMemberRef(.Variable, m.Name, type, "", Doc.Header.Name, m.Static);
				if (Gui.igBeginDragDropSource(DragNative.SourceNoPreviewTooltip))
				{
					int32 idx = (int32)mMembers.Count - 1;
					Gui.igSetDragDropPayload("TREADLE_MEMBER", &idx, sizeof(int32), 0);
					Gui.igEndDragDropSource();
				}
				OutlineInheritedRows++;
				Gui.PopID();
			}
		}
	}
}
