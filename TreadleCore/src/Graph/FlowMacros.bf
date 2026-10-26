using System;
using System.Collections;

namespace Treadle.Graph
{
	/// The flow-control nodes with state or arms (Sequence, Gate, Do Once, Do N, Flip Flop, Multi
	/// Gate and their action nodes, Language.md 5.1). Their state lives in a hidden field the
	/// compiler makes (`set state <field>` names a visible one instead); the format records only
	/// the node.
	static class FlowMacros
	{
		// The Node menu names them by the format's kind words.
		public const String Sequence = "Sequence";
		public const String DoOnce = "DoOnce";
		public const String DoOnceReset = "ResetDoOnce";
		public const String DoN = "DoN";
		public const String DoNReset = "ResetDoN";
		public const String FlipFlop = "FlipFlop";
		public const String Gate = "Gate";
		public const String GateOpen = "GateOpen";
		public const String GateClose = "GateClose";
		public const String GateToggle = "GateToggle";
		public const String MultiGate = "MultiGate";
		public const String MultiGateReset = "ResetMultiGate";

		/// The kind a Node menu macro word names (Sequence when unknown).
		public static NodeKind KindOf(StringView word)
		{
			let k = NodeKinds.Parse(word, false);
			return (k == .Unknown) ? .Sequence : k;
		}

		/// An action node (Open / Close / Toggle Gate, the Resets): it changes another node's state.
		public static bool IsAction(NodeKind k) => k == .GateOpen || k == .GateClose || k == .GateToggle || k == .ResetDoOnce || k == .ResetDoN || k == .ResetMultiGate;

		public static void GetTitle(NodeKind k, String o)
		{
			switch (k)
			{
			case .Sequence: o.Append("Sequence");
			case .DoOnce: o.Append("Do Once");
			case .ResetDoOnce: o.Append("Reset Do Once");
			case .DoN: o.Append("Do N");
			case .ResetDoN: o.Append("Reset Do N");
			case .FlipFlop: o.Append("Flip Flop");
			case .Gate: o.Append("Gate");
			case .GateOpen: o.Append("Open Gate");
			case .GateClose: o.Append("Close Gate");
			case .GateToggle: o.Append("Toggle Gate");
			case .MultiGate: o.Append("Multi Gate");
			case .ResetMultiGate: o.Append("Reset Multi Gate");
			default: o.Append(NodeKinds.Word(k));
			}
		}

		/// One-line description for tooltips and the Properties panel.
		public static void GetSummary(Node n, String o)
		{
			switch (n.Kind)
			{
			case .Sequence: o.Append("Runs each Then output in order, then continues.");
			case .DoOnce: o.Append("Runs the Once output the first time only (until reset).");
			case .DoN: o.Append("Runs the Do output the first N times (until reset).");
			case .FlipFlop: o.Append("Alternates between A and B on every run.");
			case .Gate: o.Append("Runs the Exit output only while the gate is open.");
			case .MultiGate: o.Append("Runs the next output each time; stops after the last (or loops).");
			default:
				if (IsAction(n.Kind))
					o.Append("Changes the state of a flow node in this type.");
			}
		}

		/// Nodes whose arms are exclusive, so arms that all lead to one node merge after the node.
		public static bool HasMerge(Node n)
		{
			switch (n.Kind)
			{
			case .Branch, .Switch, .ResultMatch, .FlipFlop: return true;
			case .MultiGate: return !n.HasSetting("loop");
			default: return false;
			}
		}

		/// Arm outputs of a Sequence (`then0..`) or Multi Gate (`out0..`).
		public static int ArmCount(Node n)
		{
			int c = 0;
			for (let p in n.Outputs)
				if (p.Kind == .Flow && p.Name != "done")
					c++;
			return c;
		}

		/// Adds an arm (the `count` setting grows; existing wires stay).
		public static void AddArm(Graph g, Node n)
		{
			n.SetSetting("count", scope $"{ArmCount(n) + 1}");
			NodeFactory.Reshape(g, n);
			// `done` stays last.
			let done = n.FindOutput("done");
			if (done != null)
			{
				n.Outputs.Remove(done);
				n.Outputs.Add(done);
			}
		}

		/// Removes the last arm (keeps at least one).
		public static void RemoveArm(Graph g, Node n)
		{
			let count = ArmCount(n);
			if (count <= 1)
				return;
			if (count - 1 == 2)
				n.RemoveSetting("count");
			else
				n.SetSetting("count", scope $"{count - 1}");
			NodeFactory.Reshape(g, n);
		}

		/// Removes the arm `arm` (keeps at least one): the arms after it move up one place with their
		/// wires, then the last arm goes. False when `arm` is not an arm of `n` or it is the only one.
		public static bool RemoveArmAt(Graph g, Node n, Pin arm)
		{
			List<Pin> arms = scope .();
			for (let p in n.Outputs)
				if (p.Kind == .Flow && p.Name != "done")
					arms.Add(p);
			int at = arms.IndexOf(arm);
			if (at < 0 || arms.Count <= 1)
				return false;
			// Where each arm from `at` on leads now, then the wires shifted up by one.
			List<List<Pin>> targets = scope .();
			defer { for (let t in targets) delete t; }
			for (int i = at; i < arms.Count; i++)
			{
				List<Pin> to = new .();
				for (int li = g.Links.Count - 1; li >= 0; li--)
				{
					let l = g.Links[li];
					if (l.From == arms[i])
					{
						to.Add(l.To);
						g.Disconnect(l);
					}
				}
				targets.Add(to);
			}
			for (int i = at; i < arms.Count - 1; i++)
				for (let to in targets[i - at + 1])
					g.Connect(arms[i], to);
			RemoveArm(g, n);
			g.Version++;
			return true;
		}
	}
}
