using System;
using System.Collections;

namespace Treadle.Graph
{
	/// Gives every node of a graph a record id (Graph-Format.md 2, "Id"). Ids are stable: a node keeps
	/// its id for its whole life; only nodes without one (or sharing one, after a paste) get a fresh
	/// random id. Uniqueness across the Sheets of a file is the document's (EnsureUniqueKeys).
	static class KeyAssigner
	{
		public static void Assign(Graph graph)
		{
			graph.EnsureKeys();
		}
	}

	/// Places nodes that have no saved position. Exec nodes flow left to right; the data nodes
	/// feeding a statement sit below-left of it, like a tidy Blueprint.
	static class AutoLayout
	{
		public const float ExecGap = 70;
		public const float DataColumn = 210;
		public const float DataGap = 50;
		public const float RowGap = 90;

		/// Real node sizes measured by the UI (node id -> size); used instead of estimates.
		public static Dictionary<int32, (float w, float h)> Measured = new .() ~ delete _;

		public static float EstimateWidth(Node node)
		{
			if (Measured.TryGetValue(node.Id, let size))
				return size.w;
			String title = scope .();
			node.GetTitle(title);
			float w = 60 + title.Length * 8;
			for (let p in node.Inputs)
			{
				float pw = 40 + p.Label.Length * 7;
				if (p.Kind == .Value && !p.Default.IsEmpty)
					pw += Math.Min(p.Default.Length * 7 + 20, 220);
				else if (p.Kind == .Value)
					pw += 60;
				w = Math.Max(w, pw + 60);
			}
			if (node.Kind == .Math)
			{
				int longest = 0;
				for (let line in node.Text.Split('\n'))
					longest = Math.Max(longest, line.Length);
				w = Math.Max(w, Math.Min(longest * 7 + 40, 520));
			}
			return Math.Clamp(w, 120, 560);
		}

		public static float EstimateHeight(Node node)
		{
			if (Measured.TryGetValue(node.Id, let size))
				return size.h;
			int rows = Math.Max(node.Inputs.Count, node.Outputs.Count);
			float h = 40 + rows * 24;
			if (node.Kind == .Math)
			{
				int lines = 1;
				for (let c in node.Text.RawChars)
					if (c == '\n')
						lines++;
				h += Math.Min(lines, 14) * 15;
			}
			return h;
		}

		/// Lays out the whole graph from scratch.
		public static void LayoutAll(Graph graph)
		{
			HashSet<Node> placed = scope .();
			if (graph.Entry == null)
				return;
			graph.Entry.X = 0;
			graph.Entry.Y = 0;
			graph.Entry.HasPos = true;
			graph.AutoLaidOut = true;
			placed.Add(graph.Entry);
			float maxX = 0;
			float maxY = 0;
			float firstX = EstimateWidth(graph.Entry) + ExecGap;
			LayoutChain(graph, graph.Entry.Then, firstX, 0, placed, ref maxX, ref maxY);
			PlaceUnpositioned(graph);
		}

		/// A constructor's Parent / This Constructor node: right of the entry, under the flow wire that
		/// leaves it, so the parameter wires run left to right into it; the values feeding it go to its
		/// left. `avoid`: moved down past nodes that have a place already (one added to a laid-out Sheet).
		static void PlaceChain(Graph graph, Node chain, HashSet<Node> placed, bool avoid)
		{
			let entry = graph.Entry;
			chain.X = entry.X + EstimateWidth(entry) + ExecGap;
			chain.Y = entry.Y + EstimateHeight(entry) + 20;
			if (avoid)
			{
				float w = EstimateWidth(chain);
				float h = EstimateHeight(chain);
				for (int pass < 40)
				{
					bool moved = false;
					for (let o in graph.Nodes)
					{
						if (o == chain || !o.HasPos)
							continue;
						float ow = EstimateWidth(o);
						float oh = EstimateHeight(o);
						if (chain.X < o.X + ow && o.X < chain.X + w && chain.Y < o.Y + oh && o.Y < chain.Y + h)
						{
							chain.Y = o.Y + oh + 30;
							moved = true;
						}
					}
					if (!moved)
						break;
				}
			}
			chain.HasPos = true;
			placed.Add(chain);
			float bottom = chain.Y;
			LayoutData(graph, chain, chain.X, chain.Y, placed, ref bottom);
		}

		/// Lays out a chain starting at x,y. Returns the right edge in maxX and bottom in maxY.
		static void LayoutChain(Graph graph, Pin execOut, float startX, float y, HashSet<Node> placed, ref float maxX, ref float maxY)
		{
			var node = graph.ExecTarget(execOut);
			float x = startX;
			while (node != null && !placed.Contains(node))
			{
				// Room for the data tree to the left of this node.
				x += LeftExtent(graph, node, scope .());

				node.X = x;
				node.Y = y;
				node.HasPos = true;
				placed.Add(node);
				float w = EstimateWidth(node);
				float h = EstimateHeight(node);
				maxY = Math.Max(maxY, y + h);

				float dataBottom = y + h;
				LayoutData(graph, node, x, y + h + 30, placed, ref dataBottom);
				maxY = Math.Max(maxY, dataBottom);

				float right = x + w;
				// Nested chains: first one continues on this row, the rest stack below.
				float subY = y;
				bool firstSub = true;
				for (let p in node.Outputs)
				{
					if (p.Kind != .Flow || p.Name == "then")
						continue;
					if (graph.ExecTarget(p) == null)
						continue;
					float subMaxX = right;
					float subMaxY = subY;
					if (!firstSub)
						subY = Math.Max(subY, maxY + RowGap);
					LayoutChain(graph, p, x + w + ExecGap, firstSub ? y + h + 40 : subY, placed, ref subMaxX, ref subMaxY);
					right = Math.Max(right, subMaxX);
					maxY = Math.Max(maxY, subMaxY);
					subY = subMaxY + RowGap;
					firstSub = false;
				}

				maxX = Math.Max(maxX, right);
				x = right + ExecGap;
				node = graph.ExecTarget(node.Then);
			}
		}

		/// Horizontal space needed left of a node for the data nodes feeding it.
		static float LeftExtent(Graph graph, Node node, HashSet<Node> seen)
		{
			if (!seen.Add(node))
				return 0;
			float extent = 0;
			for (let p in node.Inputs)
			{
				if (p.Kind != .Value)
					continue;
				let src = graph.DataSource(p);
				if (src != null && src.IsPure)
					extent = Math.Max(extent, EstimateWidth(src) + DataGap + LeftExtent(graph, src, seen));
			}
			return extent;
		}

		/// Places the data nodes feeding `consumer`, right-aligned to the left of it.
		static void LayoutData(Graph graph, Node consumer, float consumerX, float y, HashSet<Node> placed, ref float bottom)
		{
			float rowY = y;
			for (let p in consumer.Inputs)
			{
				if (p.Kind != .Value)
					continue;
				let src = graph.DataSource(p);
				if (src == null || !src.IsPure || placed.Contains(src))
					continue;
				src.X = consumerX - EstimateWidth(src) - DataGap;
				src.Y = rowY;
				src.HasPos = true;
				placed.Add(src);
				float h = EstimateHeight(src);
				float childBottom = rowY + h;
				LayoutData(graph, src, src.X, rowY, placed, ref childBottom);
				// A lambda's block body: its statements run below the lambda, left to right.
				for (let op in src.Outputs)
				{
					if (op.Kind != .Flow || graph.ExecTarget(op) == null)
						continue;
					float bodyMaxX = 0;
					float bodyMaxY = childBottom;
					LayoutChain(graph, op, src.X, childBottom + 40, placed, ref bodyMaxX, ref bodyMaxY);
					childBottom = Math.Max(childBottom, bodyMaxY);
				}
				rowY = Math.Max(rowY + h + 20, childBottom + 10);
				bottom = Math.Max(bottom, rowY);
			}
		}

		/// Gives a position to every node that still lacks one, near the node it connects to.
		public static void PlaceUnpositioned(Graph graph)
		{
			for (int pass = 0; pass < 4; pass++)
			{
				bool any = false;
				for (let n in graph.Nodes)
				{
					if (n.HasPos)
						continue;
					any = true;
					// Find a positioned neighbor.
					for (let l in graph.Links)
					{
						Node other = null;
						float dx = 0;
						if (l.From.Owner == n && l.To.Owner.HasPos)
						{
							other = l.To.Owner;
							dx = n.IsPure ? -DataColumn : -(EstimateWidth(n) + ExecGap);
						}
						else if (l.To.Owner == n && l.From.Owner.HasPos)
						{
							other = l.From.Owner;
							dx = EstimateWidth(other) + ExecGap;
						}
						if (other != null)
						{
							n.X = other.X + dx;
							n.Y = other.Y + (n.IsPure ? 110 : 0);
							n.HasPos = true;
							break;
						}
					}
				}
				if (!any)
					break;
			}
			// Isolated nodes: park them below everything.
			float maxY = 0;
			for (let n in graph.Nodes)
				if (n.HasPos)
					maxY = Math.Max(maxY, n.Y + EstimateHeight(n));
			float x = 0;
			for (let n in graph.Nodes)
			{
				if (n.HasPos)
					continue;
				n.X = x;
				n.Y = maxY + 120;
				n.HasPos = true;
				x += EstimateWidth(n) + 40;
			}
		}
	}
}
