using System;
using System.Collections;

namespace Treadle.Graph
{
	/// A set of nodes copied out of a graph with the links among them: the clipboard, and the
	/// shape of a paste or a duplicate.
	class NodeClip
	{
		public List<Node> Nodes = new .() ~ DeleteContainerAndItems!(_);

		public struct InternalLink
		{
			public int FromNode;
			public String FromPin;
			public int ToNode;
			public String ToPin;
		}

		public List<InternalLink> Internal = new .() ~ { for (let l in _) { delete l.FromPin; delete l.ToPin; } delete _; };

		/// Copies `nodes` and the links among them.
		public static NodeClip Capture(Graph graph, List<Node> nodes)
		{
			NodeClip set = new .();
			Dictionary<Node, int> index = scope .();
			for (let n in nodes)
			{
				index[n] = set.Nodes.Count;
				set.Nodes.Add(Graph.CloneNodeExact(n));
			}
			for (let l in graph.Links)
			{
				if (index.TryGetValue(l.From.Owner, let fromIdx) && index.TryGetValue(l.To.Owner, let toIdx))
				{
					InternalLink il;
					il.FromNode = fromIdx;
					il.FromPin = new .(l.From.Name);
					il.ToNode = toIdx;
					il.ToPin = new .(l.To.Name);
					set.Internal.Add(il);
				}
			}
			return set;
		}

		/// Adds copies of the nodes to `graph`, moved by (dx, dy), with the links among them.
		/// Entry nodes are never pasted. `added` receives the new nodes.
		public void InjectInto(Graph graph, float dx, float dy, List<Node> added)
		{
			List<Node> byIndex = scope .();
			for (let src in Nodes)
			{
				if (src.Kind == .Entry)
				{
					byIndex.Add(null);
					continue;
				}
				Node n = Graph.CloneNodeExact(src);
				n.X += dx;
				n.Y += dy;
				n.HasPos = true;
				n.Key.Clear(); // a fresh record id (KeyAssigner)
				n.Id = graph.NewId();
				for (let p in n.Inputs)
					p.Id = graph.NewId();
				for (let p in n.Outputs)
					p.Id = graph.NewId();
				graph.Nodes.Add(n);
				added.Add(n);
				byIndex.Add(n);
			}
			for (let il in Internal)
			{
				let fromNode = byIndex[il.FromNode];
				let toNode = byIndex[il.ToNode];
				if (fromNode == null || toNode == null)
					continue;
				let from = fromNode.FindOutput(il.FromPin);
				let to = toNode.FindInput(il.ToPin);
				if (from != null && to != null)
					graph.Connect(from, to);
			}
		}
	}
}
