using System;
using System.Collections;
using Treadle.Language;

namespace Treadle.Graph
{
	/// The checks a Sheet passes before it is written: the structural ones that hold for any
	/// node graph (here), then the language's own (`ILanguageRules`, a seam). Errors and warnings
	/// land on the graph (`Graph.Errors` / `Graph.Warnings`), anchored to nodes; the editor shows
	/// them as badges and refuses to write a graph with errors.
	static class GraphValidator
	{
		/// Clears the graph's messages and runs every check.
		public static void Validate(Graph g)
		{
			g.ClearErrors();
			CheckStructure(g);
			if (g.Language != null && g.Language.Rules != null)
				g.Language.Rules.Check(g);
		}

		/// Required inputs and wire types: the rules that need no language.
		static void CheckStructure(Graph g)
		{
			for (let n in g.Nodes)
			{
				for (let p in n.Inputs)
				{
					// A split struct pin takes its value from its fields' pins.
					if (p.Kind != .Value || p.Optional || SplitPins.IsSplit(p))
						continue;
					if (!g.IsLinked(p) && p.Default.IsEmpty)
						g.AddPinError(p, scope $"'{(p.Label.IsEmpty ? p.Name : p.Label)}' needs a value or a wire.");
				}
			}
			String why = scope .();
			for (let l in g.Links)
			{
				if (l.From == null || l.To == null)
					continue;
				why.Clear();
				if (!Graph.TypesCompatible(g.Language, l.From, l.To, why))
					g.AddPinError(l.To, scope $"'{l.To.Label}' cannot take a {l.From.TypeName}: {why}");
			}
			// Swizzle letters and Shuffle masks against the input's lanes (T2301).
			VectorNodes.Check(g);
		}
	}
}
