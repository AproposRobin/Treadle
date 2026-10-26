using System;
using System.Collections;
using Treadle.Catalog;
using Treadle.Language;

namespace Treadle.Graph
{
	/// How well a pin takes a wire from another pin: the one rule the Node menu's context filter,
	/// the auto-wiring of a new node and the drop checks share. A wire is possible exactly when
	/// `Fit` is above 0; the number ranks the candidates.
	static class PinMatch
	{
		/// 0: refused. 1: loose (one side's type is not known, or a generic). 2: an implicit
		/// conversion. 3: the same type (and every flow-to-flow pair).
		public static int32 Fit(LanguageContext lang, Pin ctx, Pin p)
		{
			if (!Graph.CanConnect(ctx, p))
				return 0;
			if (ctx.Kind == .Flow)
				return 3;
			if (!Graph.TypesCompatible(lang, ctx, p))
				return 0;
			Pin from = ctx.IsInput ? p : ctx;
			Pin to = ctx.IsInput ? ctx : p;
			if (!KindAccepts(lang, from, to))
				return 0;
			String a = scope .();
			String b = scope .();
			TypeRules.Normalize(from.TypeName, a);
			TypeRules.Normalize(to.TypeName, b);
			bool aWild = TypeRules.IsWildcard(a);
			bool bWild = TypeRules.IsWildcard(b);
			if (aWild || bWild)
			{
				// An untyped Receiver means "an object of the member's type": not any value.
				if (to.Role == .Receiver && bWild && !aWild && Family(lang, a) != .Object && Family(lang, a) != .Interface && Family(lang, a) != .Struct)
					return 0;
				return 1;
			}
			return (a == b) ? 3 : 2;
		}

		static TypeFamily Family(LanguageContext lang, StringView t) => (lang != null && lang.Types != null) ? lang.Types.Family(t) : TypeRules.Family(t, null);

		/// What an untyped pin of a built-in node can still take: a Delete takes objects, a loop
		/// a collection, an operator what it can compute with, a Switch what it can switch on.
		static bool KindAccepts(LanguageContext lang, Pin from, Pin to)
		{
			let n = to.Owner;
			String t = scope .();
			TypeRules.Normalize(from.TypeName, t);
			if (TypeRules.IsWildcard(t) || !TypeRules.IsWildcard(to.TypeName))
			{
				// A typed input decides by its type; an untyped source fits anything.
				if (n.Kind == .Operator && !TypeRules.IsWildcard(t))
					return OperatorTakes(n.Text, t, lang);
				return true;
			}
			let fam = Family(lang, t);
			switch (n.Kind)
			{
			case .Delete, .DeferDelete:
				return fam == .Object || fam == .Interface || fam == .Delegate || fam == .Pointer || fam == .String || TypeRules.SplitCollection(t, scope String()) != .None;
			case .Index:
				if (to.Name == "collection")
					return TypeRules.SplitCollection(t, scope String()) != .None || fam == .String;
				return true;
			case .ForEach:
				return TypeRules.SplitCollection(t, scope String()) != .None || fam == .String;
			case .Switch:
				return fam == .Enum || fam == .Int || fam == .Char || fam == .String;
			case .Operator:
				return OperatorTakes(n.Text, t, lang);
			case .ResultMatch, .Try:
				return TypeRules.BaseName(t) == "Result";
			case .Invoke:
				return to.Name != "delegate" || fam == .Delegate;
			case .Fatal:
				return fam == .String;
			default:
				return true;
			}
		}

		/// Whether an operator works on values of `t` (a comparison takes anything; arithmetic
		/// numbers, `+` also text; logic bools; bitwise integers).
		public static bool OperatorTakes(StringView op, StringView t, LanguageContext lang)
		{
			let fam = Family(lang, t);
			if (op == "==" || op == "!=")
				return true;
			if (op == "&&" || op == "||" || op == "!")
				return fam == .Bool;
			if (op == "&" || op == "|" || op == "^" || op == "<<" || op == ">>" || op == "~")
				return fam == .Int || fam == .Enum || fam == .Char;
			if (op == "+")
				return fam == .Int || fam == .Float || fam == .Char || fam == .String || fam == .Vector;
			if (op == "<" || op == ">" || op == "<=" || op == ">=")
				return fam == .Int || fam == .Float || fam == .Char;
			return fam == .Int || fam == .Float || fam == .Char || fam == .Vector;
		}

		/// The pin of `n` that best takes a wire from `ctx` (the other direction, the same kind),
		/// or null when none does. `outScore` is its Fit.
		/// `g` (may be null): the graph `n` is in, so pins already wired rank lower.
		public static Pin Best(LanguageContext lang, Graph g, Node n, Pin ctx, out int32 outScore)
		{
			outScore = 0;
			Pin best = null;
			int32 bestRank = int32.MinValue;
			let pins = ctx.IsInput ? n.Outputs : n.Inputs;
			for (let p in pins)
			{
				int32 f = Fit(lang, ctx, p);
				if (f == 0)
					continue;
				// The usual continuation and the main value first: `in` / `then`, `result` / `value`;
				// a Receiver only when nothing else fits as well.
				int32 rank = f * 10;
				if (ctx.Kind == .Flow)
				{
					if (p.Name == "in" || p.Name == "then")
						rank += 5;
				}
				else if (p.Role == .Result || p.Name == "value" || p.Name == "result")
					rank += 2;
				else if (p.Role == .Receiver)
					rank -= 1;
				if (g != null && g.IsLinked(p))
					rank -= 3;
				if (rank > bestRank)
				{
					bestRank = rank;
					best = p;
					outScore = f;
				}
			}
			return best;
		}

		/// How many flow nodes evaluate the value node `n` (Language.md 5.2, rule 2): the flow
		/// nodes its value reaches through other value nodes, each counted once. 0 for a flow node
		/// or a value nothing reads.
		public static int ValueConsumers(Graph g, Node n)
		{
			if (n.IsExecNode)
				return 0;
			HashSet<Node> seen = scope .();
			HashSet<Node> consumers = scope .();
			List<Node> stack = scope .();
			stack.Add(n);
			seen.Add(n);
			while (!stack.IsEmpty)
			{
				let cur = stack.PopBack();
				for (let l in g.Links)
				{
					if (l.From.Owner != cur || l.From.Kind != .Value)
						continue;
					let to = l.To.Owner;
					if (to.IsExecNode)
						consumers.Add(to);
					else if (seen.Add(to))
						stack.Add(to);
				}
			}
			return consumers.Count;
		}

		/// ValueConsumers for every value node of the graph at once (node id -> count, only
		/// counts of 2 and more).
		public static void FanOut(Graph g, Dictionary<int32, int32> outCounts)
		{
			outCounts.Clear();
			for (let n in g.Nodes)
			{
				if (n.IsExecNode)
					continue;
				let c = ValueConsumers(g, n);
				if (c >= 2)
					outCounts[n.Id] = (int32)c;
			}
		}
	}
}
