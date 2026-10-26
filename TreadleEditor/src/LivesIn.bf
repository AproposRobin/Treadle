using System;
using ImGui;
using Treadle.Graph;
using Treadle.Model;
using Treadle.Catalog;

namespace Treadle.Editor
{
	/// Where a value lives (Language.md, "Where values live").
	enum Storage
	{
		None,
		/// The function's stack frame: a local variable, a parameter, a function-scope Local.
		Frame,
		/// A region of the Sheet: freed when control leaves it (Local nodes).
		Region,
		/// The heap: made by Construct, freed by Delete.
		Heap,
		/// One copy for the program (a static field, a constant).
		Static,
		/// Inside another value: a struct's field, an appended object.
		Inline
	}

	/// The "lives in" badges and Storage rows (docs/Debugging.md, "Under the hood"): the Construct and Local
	/// nodes (and a Bind or Lambda that allocates) carry a small badge above the header, the Outline's
	/// variables say it in their tooltip, Properties has a Storage row with a one-line explanation (the
	/// longer one in its tooltip).
	extension EditorApp
	{
		public static StringView StorageWord(Storage s)
		{
			switch (s)
			{
			case .Frame: return "frame";
			case .Region: return "region";
			case .Heap: return "heap";
			case .Static: return "static";
			case .Inline: return "inline";
			default: return "";
			}
		}

		/// What each place means, for the tooltips.
		public static StringView StorageMeaning(Storage s)
		{
			switch (s)
			{
			case .Frame: return "Frame: the function's own stack memory, there from its Entry until it returns.";
			case .Region: return "Region: stack memory of the part of the Sheet the node is in (a loop body, a branch); freed, destructor first, every time control leaves that part.";
			case .Heap: return "Heap: memory that stays until a Delete frees it (or the owner's destructor). Not freed: a leak, which the Debug build reports at exit.";
			case .Static: return "Static: one copy for the whole program, from start to exit.";
			case .Inline: return "Inline: inside another value's own bytes, so it lives and dies with that value (Type Settings > Layout shows where).";
			default: return "";
			}
		}

		/// Where the object or value a node makes lives; `outWhy` gets a one-line explanation.
		public static Storage NodeStorage(Node n, String outWhy = null)
		{
			switch (n.Kind)
			{
			case .Construct:
				outWhy?.Append((n.FindInput("allocator") != null) ? "allocator memory, freed by a Delete with that allocator" : "heap object, freed by Delete");
				return .Heap;
			case .Local:
				if (n.HasSetting("function-scope"))
				{
					outWhy?.Append("frame object, freed when the function returns");
					return .Frame;
				}
				outWhy?.Append("region object (stack), freed when its region ends");
				return .Region;
			case .Bind, .Lambda:
				let alloc = n.GetSetting("alloc");
				if (alloc == "construct")
				{
					outWhy?.Append("heap delegate, freed by Delete");
					return .Heap;
				}
				if (alloc == "local")
				{
					outWhy?.Append("region delegate (stack), freed when its region ends");
					return .Region;
				}
				return .None;
			default:
				return .None;
			}
		}

		bool IsReferenceType(StringView type)
		{
			if (type.EndsWith("[]") || type == "String" || type == "Core.String" || type == "Object" || type == "Core.Object")
				return true;
			if (Language == null || Language.Types == null)
				return false;
			switch (Language.Types.Family(type))
			{
			case .Object, .Interface, .Delegate, .String: return true;
			default: return false;
			}
		}

		/// A field of a type of kind `ownerKind`: where it lives; `outWhy` gets a one-line explanation.
		Storage FieldStorage(MemberDecl m, TypeKind ownerKind, String outWhy)
		{
			String type = m.Type?.ToString(.. scope String()) ?? "";
			let reference = IsReferenceType(type);
			Storage s;
			if (m.Const)
			{
				outWhy.Append("static constant, read-only, never freed");
				return .Static;
			}
			if (m.Static)
			{
				outWhy.Append("static, one copy for the program");
				s = .Static;
			}
			else if (m.Owner == .Appended)
			{
				outWhy.Append("inside the owner object, freed with it");
				return .Inline;
			}
			else if (ownerKind == .Struct)
			{
				outWhy.Append("inline in each struct value");
				s = .Inline;
			}
			else
			{
				outWhy.Append("inside each object (heap or region)");
				s = .Heap;
			}
			if (reference)
				outWhy.Append((m.Owner == .Owned) ? "; owns its object, deleted with it" : "; holds a reference");
			return s;
		}

		/// A local variable of a Sheet: always the frame; what that means for its type.
		static void LocalStorage(LocalDecl l, bool reference, String outWhy)
		{
			if (reference)
				outWhy.Append((l.Owner == .Owned) ? "frame slot holding a reference; deletes its object on return" : "frame slot holding a reference");
			else
				outWhy.Append("frame, until the function returns");
		}

		// ---- the hooks (one line each in TypeSettings.bf, PropertiesPanel.bf, Outline.bf)

		void StorageRow(Storage s, StringView why, StringView extra)
		{
			String tip = scope .(StorageMeaning(s));
			if (!extra.IsEmpty)
				tip.AppendF("\n{}", extra);
			tip.Append("\nLanguage.md, \"Where values live\".");
			PropertyGrid.InfoRow("Storage", why, tip, 0, StorageColor(s), true);
		}

		/// Properties of a field: the Storage row.
		void StorageRowField(MemberDecl m)
		{
			String why = scope .();
			let s = FieldStorage(m, Doc?.Header.Kind ?? .Class, why);
			StorageRow(s, why, "Type Settings > Layout shows its offset and size.");
		}

		/// Properties of a local variable: the Storage row.
		void StorageRowLocal(LocalDecl l)
		{
			String why = scope .();
			let reference = IsReferenceType(l.GetTypeText(.. scope String()));
			LocalStorage(l, reference, why);
			StorageRow(.Frame, why, reference ? "The variable is the reference; the object lives where it was made: Construct on the heap, Local in a region." : "");
		}

		/// Properties of a Construct or Local node: the Storage row.
		void StorageRowNode(Node n)
		{
			String why = scope .();
			let s = NodeStorage(n, why);
			if (s != .None)
				StorageRow(s, why, "");
		}

		/// The Outline's tooltip line for a field (`m`) or a local (`l`).
		void StorageTip(MemberDecl m, LocalDecl l, String tip)
		{
			String why = scope .();
			Storage s;
			if (m != null)
				s = FieldStorage(m, Doc?.Header.Kind ?? .Class, why);
			else
			{
				LocalStorage(l, IsReferenceType(l.GetTypeText(.. scope String())), why);
				s = .Frame;
			}
			tip.AppendF("\nLives in: {} ({})", StorageWord(s), why);
		}

		public static uint32 StorageColor(Storage s)
		{
			switch (s)
			{
			case .Heap: return Gui.Color(240, 150, 60);
			case .Region: return Gui.Color(120, 200, 110);
			case .Frame: return Gui.Color(90, 170, 240);
			case .Static: return Gui.Color(180, 160, 220);
			case .Inline: return Gui.Color(160, 160, 160);
			default: return Look.ForegroundDim;
			}
		}
	}

	extension GraphPanel
	{
		/// A Construct / Local node (and a Bind or Lambda that allocates): "lives in heap", "lives in region"
		/// or "lives in frame" above the header's top-left corner, in the style of the "evaluated Nx" badge;
		/// the tooltip explains it.
		void DrawLivesInBadge(Node node, ImDrawList* dl, ImVec2 p0, ImVec2 p1, float fh, float z)
		{
			String why = scope .();
			let s = EditorApp.NodeStorage(node, why);
			if (s == .None || z < 0.35f)
				return;
			String badge = scope $"lives in {EditorApp.StorageWord(s)}";
			float bs = fh * 0.8f * z;
			float bw = Gui.CalcTextSize(badge).x * (bs / Math.Max(Gui.igGetFontSize(), 1.0f)) + 10 * z;
			let b0 = ImVec2(p0.x, p0.y - bs - 6 * z);
			let b1 = ImVec2(Math.Min(p0.x + bw, p1.x), p0.y - 2 * z);
			let col = EditorApp.StorageColor(s);
			Gui.ImDrawList_AddRectFilled(dl, b0, b1, Theme.WithAlpha(col, 40), 4 * z, 0);
			Gui.ImDrawList_AddRect(dl, b0, b1, Theme.WithAlpha(col, 190), 4 * z, 1, 0);
			Text(dl, .(b0.x + 5 * z, b0.y + 2 * z), bs, Look.Foreground, badge);
			if (Gui.igIsMouseHoveringRect(b0, b1, true) && Gui.igIsWindowHovered(0))
				Gui.Tooltip(scope $"Storage: {why}\n{EditorApp.StorageMeaning(s)}");
			LivesInBadges++;
		}

		/// Badges drawn since the last reset (the `hood` self test).
		public int LivesInBadges;
	}
}
