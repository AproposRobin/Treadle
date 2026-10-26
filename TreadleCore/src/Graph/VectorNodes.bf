using System;
using System.Collections;
using Treadle.Model;

namespace Treadle.Graph
{
	/// The vector nodes the graph knows itself (docs/SIMD-and-Vectors.md 1.9): `Swizzle` (`value` ->
	/// `result`, `set lanes zyx`) and `Shuffle` (`a`, `b` -> `result`, `set mask 0 4 1 5`), and the lane pins of
	/// Make / Break of a vector type (`x y z w` up to 4 lanes, `lane0 ... laneN-1` above). Their result types
	/// follow the wired input and the setting (`Sync`, run when a wire comes or goes); the letters and lane
	/// numbers are checked here (T2301), so the editor names a bad one before the compiler knows vectors.
	static class VectorNodes
	{
		public const String LanesKey = "lanes";
		public const String MaskKey = "mask";

		/// The lane a swizzle letter reads: x 0, y 1, z 2, w 3; -1 for any other character.
		public static int32 LetterIndex(char8 c)
		{
			switch (c)
			{
			case 'x': return 0;
			case 'y': return 1;
			case 'z': return 2;
			case 'w': return 3;
			default: return -1;
			}
		}

		/// A swizzle setting: 1 to 4 of the letters `x y z w`, each within an input of `inputLanes` lanes
		/// (0: not known yet). False with the T2301 text in `outWhy`.
		public static bool CheckSwizzle(StringView lanes, int inputLanes, String outWhy)
		{
			var l = lanes;
			l.Trim();
			if (l.IsEmpty || l.Length > 4)
			{
				outWhy.Append("T2301: a swizzle takes 1 to 4 of the letters x y z w");
				return false;
			}
			for (let c in l.RawChars)
			{
				let i = LetterIndex(c);
				if (i < 0)
				{
					outWhy.AppendF("T2301: '{}' is not a lane letter (x y z w)", c);
					return false;
				}
				if (inputLanes > 0 && i >= inputLanes)
				{
					outWhy.AppendF("T2301: '{}' is lane {}, the input has {} lanes ({})", c, i, inputLanes, "xyzw".Substring(0, Math.Min(inputLanes, 4)));
					return false;
				}
			}
			return true;
		}

		/// A shuffle mask (`0 4 1 5`): lane numbers separated by spaces, 0 .. N-1 from `a`, N .. 2N-1 from `b`.
		public static bool ParseMask(StringView mask, List<int32> outLanes)
		{
			for (var part in mask.Split(' '))
			{
				part.Trim();
				if (part.IsEmpty)
					continue;
				if (!(int32.Parse(part) case .Ok(let n)) || n < 0)
					return false;
				outLanes.Add(n);
			}
			return true;
		}

		/// A shuffle mask against inputs of `inputLanes` lanes (0: not known yet): numbers below 2N, as many
		/// as a vector has lanes. False with the T2301 text in `outWhy`.
		public static bool CheckShuffle(StringView mask, int inputLanes, String outWhy)
		{
			List<int32> lanes = scope .();
			if (!ParseMask(mask, lanes) || lanes.IsEmpty)
			{
				outWhy.Append("T2301: a shuffle mask is lane numbers separated by spaces (0 4 1 5)");
				return false;
			}
			if (!VectorTypes.IsLaneCount(lanes.Count))
			{
				outWhy.AppendF("T2301: the mask has {} lanes; a vector has 2, 3, 4, 8, 16, 32 or 64", lanes.Count);
				return false;
			}
			if (inputLanes > 0)
				for (let n in lanes)
					if (n >= 2 * inputLanes)
					{
						outWhy.AppendF("T2301: lane {} is outside a and b (0 to {}: a's lanes, then b's)", n, 2 * inputLanes - 1);
						return false;
					}
			return true;
		}

		/// The type a Swizzle of `input` (a vector type) by `lanes` gives: the element for one letter, else
		/// the vector of that many lanes (`float4` by `zyx`: `float3`). False when either is not known or wrong.
		public static bool SwizzleResult(StringView input, StringView lanes, String outType)
		{
			String e = scope .();
			if (!VectorTypes.Info(input, e, let n) || !CheckSwizzle(lanes, n, scope String()))
				return false;
			var l = lanes;
			l.Trim();
			if (l.Length == 1)
				outType.Append(e);
			else if (VectorTypes.Exists(e, l.Length))
				VectorTypes.Spell(e, l.Length, outType);
			else
				return false;
			return true;
		}

		/// The type a Shuffle of two `input` vectors by `mask` gives: the element x the mask's length.
		public static bool ShuffleResult(StringView input, StringView mask, String outType)
		{
			String e = scope .();
			if (!VectorTypes.Info(input, e, let n) || !CheckShuffle(mask, n, scope String()))
				return false;
			List<int32> lanes = scope .();
			ParseMask(mask, lanes);
			if (!VectorTypes.Exists(e, lanes.Count))
				return false;
			VectorTypes.Spell(e, lanes.Count, outType);
			return true;
		}

		/// A new Swizzle's letters for an input of `lanes` lanes (0: unknown): the lanes reversed, `zyx` by default.
		public static void DefaultSwizzle(int lanes, String outLanes)
		{
			let n = (lanes <= 0) ? 3 : Math.Min(lanes, 4);
			for (int i = n - 1; i >= 0; i--)
				outLanes.Append("xyzw"[i]);
		}

		/// A new Shuffle's mask for inputs of `lanes` lanes (0: unknown, 4): the low halves interleaved,
		/// `0 4 1 5` for 4 lanes.
		public static void DefaultMask(int lanes, String outMask)
		{
			let n = (lanes <= 0) ? 4 : lanes;
			for (int i < n)
			{
				if (i > 0)
					outMask.Append(' ');
				outMask.AppendF("{}", (i % 2 == 0) ? i / 2 : n + i / 2);
			}
		}

		/// The vector type wired into `pin` of `n` ("" when unwired or not a vector).
		public static void WiredType(Graph g, Node n, StringView pin, String outType)
		{
			let p = n.FindInput(pin);
			let link = (p != null) ? g.FindLinkTo(p) : null;
			if (link != null && link.From != null)
				VectorTypes.Canonical(link.From.TypeName, outType);
		}

		/// The input vector type a Swizzle or Shuffle works on ("" when not wired yet).
		public static void InputType(Graph g, Node n, String outType)
		{
			if (n.Kind == .Swizzle)
				WiredType(g, n, "value", outType);
			else if (n.Kind == .Shuffle)
			{
				WiredType(g, n, "a", outType);
				if (outType.IsEmpty)
					WiredType(g, n, "b", outType);
			}
		}

		/// Lane pins of Make / Break `T` for a vector `T`: one per lane, typed by the element. Nothing for any
		/// other type. Pins the node already has are kept.
		public static void AddLanePins(Graph g, Node n)
		{
			if (n.Kind != .Make && n.Kind != .BreakStruct)
				return;
			String e = scope .();
			if (!VectorTypes.Info(n.Text, e, let lanes))
				return;
			let input = n.Kind == .Make;
			for (int i < lanes)
			{
				String name = scope .();
				VectorTypes.LaneName(lanes, i, name);
				if ((input ? n.FindInput(name) : n.FindOutput(name)) != null)
					continue;
				let p = g.AddPin(n, input, .Value, name, name);
				p.SetTypeText(e);
				p.Role = input ? .Arg : .Result;
				// The `value` pin stays last on a Make's inputs side and first on a Break's outputs.
			}
		}

		/// `==` `!=` `<` `<=` `>` `>=`: on vectors a mask (`bool4`), not a bool.
		public static bool IsComparison(StringView op) => op == "==" || op == "!=" || op == "<" || op == ">" || op == "<=" || op == ">=";

		/// Brings a Swizzle's or Shuffle's result type in step with its input and setting, and an Operator's
		/// with a vector wired in (element-wise: the vector, a comparison its mask), then the nodes it feeds.
		/// True when a pin changed.
		public static bool Sync(Graph g, Node n, int depth = 0)
		{
			if (n == null || (n.Kind != .Swizzle && n.Kind != .Shuffle && n.Kind != .Operator) || depth > 64)
				return false;
			let result = n.FindOutput("result");
			if (result == null)
				return false;
			String input = scope .();
			String want = scope .();
			if (n.Kind == .Operator)
			{
				// A vector on either side makes the operator element-wise (a scalar on the other side splats).
				WiredType(g, n, "a", input);
				if (input.IsEmpty)
					WiredType(g, n, "b", input);
				if (input.IsEmpty)
				{
					// No vector (any more): the result the operator has without one, unless something else typed it.
					if (VectorTypes.LanesOf(result.TypeName) == 0)
						return false;
					want.Set(NodeFactory.IsComparison(n.Text) ? "bool" : "");
				}
				else if (IsComparison(n.Text))
					VectorTypes.MaskOf(VectorTypes.LanesOf(input), want);
				else if (n.Text == "&&" || n.Text == "||")
					want.Clear(); // T2300 (Check)
				else
					want.Set(input);
			}
			else
			{
				InputType(g, n, input);
				if (!input.IsEmpty)
				{
					if (n.Kind == .Swizzle)
						SwizzleResult(input, n.GetSetting(LanesKey), want);
					else
						ShuffleResult(input, n.GetSetting(MaskKey), want);
				}
			}
			if (result.TypeName == want)
				return false;
			result.SetTypeText(want);
			g.Version++;
			for (let l in g.Links)
				if (l.From == result && l.To != null)
					Sync(g, l.To.Owner, depth + 1);
			return true;
		}

		/// Every Swizzle and Shuffle of the graph (after a file is read or a setting changed).
		public static bool SyncAll(Graph g)
		{
			bool any = false;
			for (let n in g.Nodes)
				any |= Sync(g, n);
			return any;
		}

		/// The node's title: "Swizzle .zyx", "Shuffle 0 4 1 5".
		public static void Title(Node n, String outTitle)
		{
			if (n.Kind == .Swizzle)
			{
				outTitle.Append("Swizzle");
				let l = n.GetSetting(LanesKey);
				if (!l.IsEmpty)
					outTitle.AppendF(" .{}", l);
			}
			else if (n.Kind == .Shuffle)
			{
				outTitle.Append("Shuffle");
				let m = n.GetSetting(MaskKey);
				if (!m.IsEmpty)
					outTitle.AppendF(" {}", m);
			}
		}

		/// The graph's own vector checks (GraphValidator): a Swizzle's letters and a Shuffle's mask against
		/// the input's lanes (T2301), a scalar wired where a vector belongs.
		public static void Check(Graph g)
		{
			String why = scope .();
			String input = scope .();
			for (let n in g.Nodes)
			{
				if (n.Kind == .Operator && (n.Text == "&&" || n.Text == "||"))
				{
					input.Clear();
					WiredType(g, n, "a", input);
					if (input.IsEmpty)
						WiredType(g, n, "b", input);
					if (!input.IsEmpty)
						g.AddError(n, scope $"T2300: {n.Text} does not take vectors ({input}): use {((n.Text == "&&") ? "&" : "|")} on masks");
					continue;
				}
				if (n.Kind != .Swizzle && n.Kind != .Shuffle)
					continue;
				input.Clear();
				InputType(g, n, input);
				let lanes = VectorTypes.LanesOf(input);
				why.Clear();
				if (n.Kind == .Swizzle && !CheckSwizzle(n.GetSetting(LanesKey), lanes, why))
					g.AddError(n, scope $"Swizzle: {why}");
				else if (n.Kind == .Shuffle && !CheckShuffle(n.GetSetting(MaskKey), lanes, why))
					g.AddError(n, scope $"Shuffle: {why}");
				for (let p in n.Inputs)
				{
					if (p.Kind != .Value)
						continue;
					let link = g.FindLinkTo(p);
					if (link == null || link.From == null || link.From.TypeName.IsEmpty || Treadle.Catalog.TypeRules.IsWildcard(link.From.TypeName))
						continue;
					if (VectorTypes.LanesOf(link.From.TypeName) == 0)
						g.AddPinError(p, scope $"'{p.Label}' takes a vector (float4, int32x4, ...), not a {link.From.TypeName}");
				}
				if (n.Kind == .Shuffle)
				{
					String a = scope .();
					String b = scope .();
					WiredType(g, n, "a", a);
					WiredType(g, n, "b", b);
					if (!a.IsEmpty && !b.IsEmpty && a != b)
						g.AddPinError(n.FindInput("b"), scope $"'B' must be the same vector type as A ({a}), not a {b}");
				}
			}
		}
	}
}
