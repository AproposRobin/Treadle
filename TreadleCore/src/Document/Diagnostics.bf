using System;
using System.Collections;
using Treadle.Graph;


namespace Treadle.Document
{
	enum DiagnosticSeverity
	{
		Error,
		Warning
	}

	/// Which operation reported a message (docs/Graph-Architecture.md 2.3 and 4.3); the Problems
	/// panel tags its rows with it.
	enum DiagnosticOrigin
	{
		/// The build tool's output (Build, F7; also the build before Run).
		Build,
		/// Validate: the graph checks and the parse of the text (Level 1).
		Validate
	}

	/// One compiler message with a source location, and where it lands in the graphs.
	class Diagnostic
	{
		public DiagnosticSeverity Severity;
		/// Build (the default) or Validate.
		public DiagnosticOrigin Origin;
		public String Text = new .() ~ delete _;
		/// Source file as the compiler printed it ("" when the message has no location).
		public String Path = new .() ~ delete _;
		/// 1-based; 0 = unknown.
		public int32 Line;
		public int32 Column;

		// Filled by DiagnosticMap.Locate.
		/// Method graph that owns the line ("" = outside every function: a field, a type
		/// declaration, another file: shown at document level).
		public String MethodKey = new .() ~ delete _;
		/// Record id of the node ("" = no node).
		/// Survives edits and graph rebuilds, so the node is found again after the text changed.
		public String NodeKey = new .() ~ delete _;
		/// The pin of that node the message is about (its format name; "" = the whole node).
		public String PinName = new .() ~ delete _;
		/// "Player.Tick" / "Player" for display.
		public String Where = new .() ~ delete _;
		/// Node id in the graph the diagnostic was last resolved against.
		public int32 NodeId = -1;
		/// Graph.Serial of that graph (0 = not resolved yet). A serial, not the object: the
		/// allocator may hand a deleted graph's address to a new one.
		public int32 ResolvedSerial;
		/// The node the message was about was deleted from the live graph after the compile
		/// (the Problems row says so; no other node takes the message over).
		public bool NodeGone;

		public bool IsError => Severity == .Error;
		public bool OnNode => !NodeKey.IsEmpty;
		public bool HasLocation => !Path.IsEmpty && Line > 0;
	}

	/// Finds the node a diagnostic belongs to, by its record id, which
	/// stays the same across edits.
	/// Seam: a language whose build tool reports locations in its own terms (a file position, a
	/// node id in the graph file) fills `Diagnostic.MethodKey` / `NodeKey` itself (`Locate`);
	/// `Resolve` and `FindByKey` then take over.
	static class DiagnosticMap
	{
		/// Fills d.MethodKey / NodeKey / NodeId / Where from a Sheet's node (what a language's
		/// toolchain calls when it knows the node a message is about). Returns true when the node
		/// is in the graph.
		public static bool Locate(Sheet sheet, Node node, Diagnostic d)
		{
			d.MethodKey.Set(sheet.Key);
			d.NodeKey.Clear();
			d.Where.Set(sheet.Name);
			d.NodeId = -1;
			d.ResolvedSerial = 0;
			d.NodeGone = false;
			if (node == null)
				return false;
			d.NodeKey.Append(node.Key);
			d.NodeId = node.Id;
			d.ResolvedSerial = sheet.Graph.Serial;
			return true;
		}

		/// Finds the node a located diagnostic belongs to in the Sheet's current graph. Null when
		/// that node is gone.
		///
		/// While the graph object is the one the message was resolved against (Graph.Serial), the
		/// node is followed by identity: the node id, which the graph never hands out twice. A
		/// node edited in the graph keeps its message until the next compile; a deleted node's
		/// message goes nowhere (no new or neighbouring node inherits it, even one that now sits
		/// at the deleted statement's place). In a different graph object (rebuilt from the file,
		/// an undo step) it is found by its content key: the same statement (exact), or the same
		/// statement moved (same hash, another place). A different statement at the old place
		/// is not the same node, so it is never matched by position alone.
		public static Node Resolve(Sheet mg, Diagnostic d)
		{
			if (d.NodeKey.IsEmpty || mg.Key != d.MethodKey)
				return null;
			let graph = mg.Graph;
			if (d.ResolvedSerial == graph.Serial)
			{
				if (d.NodeId < 0)
					return null;
				for (let n in graph.Nodes)
					if (n.Id == d.NodeId)
						return n;
				d.NodeId = -1;
				d.NodeGone = true;
				return null;
			}
			let node = FindByKey(graph, d.NodeKey, false);
			d.ResolvedSerial = graph.Serial;
			d.NodeId = (node != null) ? node.Id : -1;
			d.NodeGone = node == null;
			return node;
		}

		/// The key a breakpoint or message stores for `n`: its record id.
		public static void KeyOf(Graph graph, Node n, String outKey)
		{
			outKey.Append(n.Key);
		}

		/// The node with record id `nodeKey`, or null. Ids are stable, so no matching is needed. A message
		/// about the Make / Break a split pin stands for (`<id>_<pin>`, SplitPins.SynthKey) is the node's.
		public static Node FindByKey(Graph graph, StringView nodeKey, bool samePlaceEdited = true)
		{
			let n = graph.FindNodeByKey(nodeKey);
			if (n == null && SplitPins.OwnerOfKey(nodeKey, let owner, ?))
				return graph.FindNodeByKey(owner);
			return n;
		}
	}
}
