using System;
using ImGui;
using Treadle.Graph;
using Treadle.Catalog;

namespace Treadle.Editor
{
	/// How pins and node headers look, in one place: the shapes here, the colours in Theme. A pin's colour is
	/// its type's (a collection is drawn in what it holds); its shape says how many it holds.
	static class PinStyle
	{
		public enum Shape
		{
			Flow,
			Single,
			/// `T[]`, `Span<T>`: three upright slots side by side (a fixed number of places).
			Array,
			/// `List<T>`: three rows, each a dot and a bar (a growing list).
			List,
			/// `Dictionary<K, V>`: two squares, the key's colour and the value's.
			Map,
			/// `HashSet<T>`: three separate dots.
			Set,
			/// A vector primitive (`float4`, `int32x4`): a rounded square in the vector colour with one inner
			/// bar per 4 lanes (one bar for 2 to 4 lanes, two for 8, four from 16) in the element's colour.
			Lanes
		}

		public static uint32 Color(Pin p) => Theme.PinColor(p);

		public static Shape ShapeFor(Pin p)
		{
			if (p.Kind == .Flow)
				return .Flow;
			String element = scope .();
			switch (TypeRules.SplitCollection(p.TypeName, element))
			{
			case .Array, .Span: return .Array;
			case .List: return .List;
			case .Map: return .Map;
			case .Set: return .Set;
			default: return (LaneCount(p) > 0) ? .Lanes : .Single;
			}
		}

		/// The lanes of a vector pin (0 for any other pin).
		public static int32 LaneCount(Pin p) => (p.Kind == .Value) ? Treadle.Model.VectorTypes.LanesOf(p.TypeName) : 0;

		/// Header colour by node kind (a call blue, a pure call green, flow grey, an entry purple-red, a
		/// return purple, code orange): Theme.HeaderColor.
		public static uint32 Header(Node node) => Theme.HeaderColor(node);

		/// The small icon at the left of a node's title.
		public static StringView HeaderIcon(Node node)
		{
			switch (node.Kind)
			{
			case .Entry: return Icon.SquareFunction;
			case .ChainCtor: return Icon.ArrowUp;
			case .Call: return Icon.SquareFunction;
			case .Branch: return Icon.GitBranch;
			case .Switch: return Icon.Workflow;
			case .Sequence, .Gate, .DoOnce, .DoN, .FlipFlop, .MultiGate, .GateOpen, .GateClose, .GateToggle, .ResetDoOnce, .ResetDoN, .ResetMultiGate: return Icon.Blocks;
			case .While, .DoWhile, .For, .ForEach: return Icon.Repeat;
			case .Return: return Icon.CornerDownLeft;
			case .Break, .Continue: return Icon.ArrowRight;
			case .Set: return Icon.Variable;
			case .Cast: return Icon.ArrowRightLeft;
			case .Construct, .Local: return Icon.Box;
			case .Delete, .DeferDelete: return Icon.Trash2;
			case .Defer: return Icon.Undo2;
			case .ResultMatch: return Icon.GitBranch;
			case .Scope: return Icon.Braces;
			case .Lambda, .Bind: return Icon.SquareFunction;
			case .Math: return Icon.Sigma;
			// A collapsed node group drawn as one node (GroupView.bf).
			case .Unknown: return (node.KindWord != null && node.KindWord == "Group") ? Icon.Layers : "";
			default: return "";
			}
		}

		/// Draws a data pin of the given shape: a ring (a disc when linked) for a single value, three upright
		/// slots for an array, three dotted rows for a list, two squares for a map (`col` the key's, `col2` the
		/// value's) and three dots for a set. A collection is filled when linked and muted when not. A vector
		/// (`lanes` > 0) is a rounded square in `col`, framed when unlinked and filled when linked, with its
		/// lane bars in `col2` (the element's colour).
		///
		/// The collection symbols are drawn as rectangles on whole pixels, sized from the pin's pixel size with
		/// every gap kept at one pixel or more, so at no zoom do two parts run together (the old 3 x 3 grid of
		/// fractional squares did below about 100%), and a shape too small for its parts shows one solid block.
		public static void DrawData(ImDrawList* dl, Shape shape, ImVec2 c, float r, uint32 col, uint32 col2, bool linked, float arrowX, float thickness, int32 lanes = 4)
		{
			uint32 fill = linked ? col : Theme.WithAlpha(col, 140);
			switch (shape)
			{
			case .Lanes:
				int32 side = (int32)Math.Max(5, Math.Round(r * 2.2f));
				int32 x0 = (int32)Math.Round(c.x - side * 0.5f);
				int32 y0 = (int32)Math.Round(c.y - side * 0.5f);
				float round = Math.Max(1.0f, Math.Round(side * 0.24f));
				// The direction arrow a single value's pin has.
				float a = r * 0.55f;
				Gui.ImDrawList_AddTriangleFilled(dl, .(arrowX - a * 0.6f, c.y - a), .(arrowX + a * 0.6f, c.y), .(arrowX - a * 0.6f, c.y + a), col);
				if (linked)
					Gui.ImDrawList_AddRectFilled(dl, .(x0, y0), .(x0 + side, y0 + side), col, round, 0);
				else
				{
					Gui.ImDrawList_AddRectFilled(dl, .(x0, y0), .(x0 + side, y0 + side), Theme.NodeBody, round, 0);
					Gui.ImDrawList_AddRect(dl, .(x0 + 0.5f, y0 + 0.5f), .(x0 + side - 0.5f, y0 + side - 0.5f), col, round, Math.Max(1.0f, thickness * 0.85f), 0);
				}
				// The lane bars: one per 4 lanes (at most 4), upright, at least a pixel apart.
				int32 inset = (int32)Math.Max(2, Math.Round(side * 0.27f));
				int32 innerW = side - 2 * inset;
				int32 innerH = side - 2 * inset;
				if (innerW < 1 || innerH < 1)
					break;
				int32 bars = Math.Clamp(lanes / 4, 1, 4);
				int32 gap = 1;
				int32 bw = (innerW - (bars - 1) * gap) / bars;
				while (bars > 1 && bw < 1)
				{
					bars--;
					bw = (innerW - (bars - 1) * gap) / bars;
				}
				if (bars == 1)
					bw = Math.Max(1, (int32)Math.Round(innerW * 0.5f));
				int32 used = bars * bw + (bars - 1) * gap;
				int32 bx = x0 + inset + (innerW - used) / 2;
				uint32 barCol = linked ? col2 : Theme.WithAlpha(col2, 170);
				if (linked && col2 == col)
					barCol = Theme.NodeBody;
				for (int32 i < bars)
					Gui.ImDrawList_AddRectFilled(dl, .(bx + i * (bw + gap), y0 + inset), .(bx + i * (bw + gap) + bw, y0 + inset + innerH), barCol, 0, 0);
			case .Array:
				// Three slots side by side: width `s`, gap `g`, height `bh`, all whole pixels.
				int32 g = (int32)Math.Max(1, Math.Round(r * 0.22f));
				int32 total = (int32)Math.Round(r * 2.4f);
				int32 s = (total - 2 * g) / 3;
				int32 bh = (int32)Math.Max(2, Math.Round(r * 1.35f));
				int32 x0 = (int32)Math.Round(c.x - ((s < 1) ? total : 3 * s + 2 * g) * 0.5f);
				int32 y0 = (int32)Math.Round(c.y - bh * 0.5f);
				if (s < 1)
				{
					// Too small for three: one block as wide as the row.
					Gui.ImDrawList_AddRectFilled(dl, .(x0, y0), .(x0 + total, y0 + bh), fill, 0, 0);
					break;
				}
				for (int32 i < 3)
				{
					let a = ImVec2(x0 + i * (s + g), y0);
					Gui.ImDrawList_AddRectFilled(dl, a, a + .(s, bh), fill, 0, 0);
				}
			case .List:
				// Three rows, each a dot and a bar; rows one pixel apart at least.
				int32 g = (int32)Math.Max(1, Math.Round(r * 0.2f));
				int32 bh = (int32)Math.Max(1, Math.Round(r * 0.34f));
				int32 width = (int32)Math.Round(r * 2.2f);
				int32 height = 3 * bh + 2 * g;
				while (height > (int32)Math.Round(r * 2.0f) && (bh > 1 || g > 1))
				{
					if (g > 1)
						g--;
					else
						bh--;
					height = 3 * bh + 2 * g;
				}
				int32 x0 = (int32)Math.Round(c.x - width * 0.5f);
				int32 y0 = (int32)Math.Round(c.y - height * 0.5f);
				bool dots = bh >= 2 && width >= 8;
				for (int32 i < 3)
				{
					int32 y = y0 + i * (bh + g);
					int32 barX = dots ? (x0 + bh + g) : x0;
					if (dots)
						Gui.ImDrawList_AddRectFilled(dl, .(x0, y), .(x0 + bh, y + bh), fill, 0, 0);
					Gui.ImDrawList_AddRectFilled(dl, .(barX, y), .(x0 + width, y + bh), fill, 0, 0);
				}
			case .Map:
				// Two squares on a diagonal: the key's filled, the value's filled when linked, else a frame.
				int32 side = (int32)Math.Max(3, Math.Round(r * 1.05f));
				int32 off = (int32)Math.Max(1, Math.Round(r * 0.5f));
				int32 x0 = (int32)Math.Round(c.x - (side + off) * 0.5f);
				int32 y0 = (int32)Math.Round(c.y - (side + off) * 0.5f);
				Gui.ImDrawList_AddRectFilled(dl, .(x0, y0), .(x0 + side, y0 + side), col, 0, 0);
				let b = ImVec2(x0 + off, y0 + off);
				if (linked)
					Gui.ImDrawList_AddRectFilled(dl, b, b + .(side, side), col2, 0, 0);
				else
				{
					// Clear the key square under it first, so the frame reads as a frame.
					Gui.ImDrawList_AddRectFilled(dl, b, b + .(side, side), Theme.NodeBody, 0, 0);
					Gui.ImDrawList_AddRect(dl, b + .(0.5f, 0.5f), b + .(side - 0.5f, side - 0.5f), col2, 0, 1, 0);
				}
			case .Set:
				// Three separate dots in a triangle: unordered, each one once.
				int32 d = (int32)Math.Max(2, Math.Round(r * 0.62f));
				int32 w = (int32)Math.Max(2 * d + 1, Math.Round(r * 1.9f));
				int32 h = (int32)Math.Max(2 * d + 1, Math.Round(r * 1.9f));
				int32 x0 = (int32)Math.Round(c.x - w * 0.5f);
				int32 y0 = (int32)Math.Round(c.y - h * 0.5f);
				Gui.ImDrawList_AddRectFilled(dl, .(x0, y0 + h - d), .(x0 + d, y0 + h), fill, 0, 0);
				Gui.ImDrawList_AddRectFilled(dl, .(x0 + w - d, y0 + h - d), .(x0 + w, y0 + h), fill, 0, 0);
				int32 tx = (int32)Math.Round(c.x - d * 0.5f);
				Gui.ImDrawList_AddRectFilled(dl, .(tx, y0), .(tx + d, y0 + d), fill, 0, 0);
			default:
				Canvas.DataPin(dl, c, r, col, linked, arrowX, thickness);
			}
		}
	}
}
