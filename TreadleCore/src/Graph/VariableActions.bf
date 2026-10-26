using System;
using System.Collections;

namespace Treadle.Graph
{
	/// Graph edits behind "Make variable" / "Make local variable" and the L hotkey, over the
	/// model only: naming a variable after a pin, unique local names, splicing a Set into the
	/// flow. Kept from the fork (VariableDrop / RefLocal) without their text rules; which names
	/// are reserved and whether a type fits a pin are the language's (LanguageContext).
	static class VariableActions
	{
		/// A variable name made from a pin's label (`Return Value` -> `returnValue`), or `value`.
		public static void VariableBase(Pin pin, String outName)
		{
			bool up = false;
			for (let c in pin.Label.IsEmpty ? pin.Name.RawChars : pin.Label.RawChars)
			{
				if (c.IsLetterOrDigit || c == '_')
				{
					outName.Append((up && !outName.IsEmpty) ? c.ToUpper : c);
					up = false;
				}
				else
					up = true;
			}
			if (outName.IsEmpty || outName[0].IsDigit)
				outName.Set("value");
			else
				outName[0] = outName[0].ToLower;
		}

		/// `baseName`, or `baseName1`, `baseName2`... when the Sheet already has a Local, loop
		/// variable or parameter of that name (the Entry's outputs).
		public static void UniqueName(Graph g, StringView baseName, String outName)
		{
			outName.Set(baseName);
			for (int i = 1; IsUsed(g, outName); i++)
			{
				outName.Set(baseName);
				outName.AppendF("{}", i);
			}
		}

		static bool IsUsed(Graph g, StringView name)
		{
			if (g.FindLocal(name) != null)
				return true;
			for (let n in g.Nodes)
			{
				if (n.Kind == .Entry)
					for (let p in n.Outputs)
						if (p.Kind == .Value && (p.Name == name || p.Label == name))
							return true;
			}
			return false;
		}

		/// Puts `set` (a Set fed by `pin`) in the flow: after the pin's node when that node runs in
		/// the flow (after its Body for a loop's Element / Counter), else before the first statement
		/// that uses the pin's value. Returns that statement in the second case (the caller places
		/// the Set near it), null otherwise. A pin of a node no statement uses leaves the Set
		/// unconnected (written nowhere until it is wired).
		public static Node SpliceSet(Graph g, Node set, Pin pin)
		{
			let owner = pin.Owner;
			if (owner.IsExecNode && owner.Then != null)
			{
				let after = ((pin.Name == "element" || pin.Name == "index") && owner.FindOutput("body") != null) ? owner.FindOutput("body") : owner.Then;
				let oldNext = g.ExecTarget(after);
				g.Connect(after, set.ExecIn);
				if (oldNext != null)
					g.Connect(set.Then, oldNext.ExecIn);
				return null;
			}
			if (owner.IsExecNode)
				return null;
			// A value node: the Set runs right before the first statement that uses the value.
			Node before = null;
			List<Node> stack = scope .();
			HashSet<Node> seen = scope .();
			stack.Add(owner);
			while (!stack.IsEmpty && before == null)
			{
				let cur = stack.PopBack();
				if (!seen.Add(cur))
					continue;
				for (let l in g.Links)
				{
					if (l.From.Owner != cur || l.From.Kind != .Value)
						continue;
					let user = l.To.Owner;
					if (user == set)
						continue;
					if (user.IsExecNode && user != g.Entry && user.ExecIn != null && g.IsLinked(user.ExecIn))
					{
						before = user;
						break;
					}
					stack.Add(user);
				}
			}
			if (before == null)
				return null;
			let inLink = g.FindLinkTo(before.ExecIn);
			let prev = inLink.From;
			g.Connect(prev, set.ExecIn);
			g.Connect(set.Then, before.ExecIn);
			return before;
		}
	}
}
