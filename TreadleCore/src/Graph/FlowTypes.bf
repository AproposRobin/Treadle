using System;
using System.Collections;
using Treadle.Catalog;

namespace Treadle.Graph
{
	/// The types the control-flow nodes derive from their connections and settings
	/// (docs/Flow-Nodes.md > Types in control flow): what a For Each loops over and what each element
	/// is, the integer type of a counting For loop's Start, Count and counter, the destination type of
	/// a Cast. Bool conditions and integer bounds are the pins' own types (they refuse what does not
	/// convert, Graph.CanConnectTyped); this keeps the pins that follow another setting in step with it.
	///
	/// Run at the start of every validation (so before anything is written, after any edit that
	/// changed a node's type text) and when a wire into a For Each is made or cut. It never touches a
	/// wire, a value or the text of a node.
	static class FlowTypes
	{
		/// What a For Each over a value of `collType` hands out: `T` for `T[]`, `List<T>`, `HashSet<T>`,
		/// `Queue<T>`, `Span<T>`, `SizedArray<T, N>`, `IEnumerable<T>`, `(K key, V value)` for a
		/// `Dictionary<K, V>`, `char32` for text. False when it cannot be told (a type that is not
		/// known, a user collection).
		public static bool ElementType(StringView collTypeIn, String outElem)
		{
			String t = scope .();
			TypeRules.Normalize(collTypeIn, t);
			while (t.EndsWith('?') || t.EndsWith('&'))
				t.RemoveFromEnd(1);
			t.Trim();
			if (t.IsEmpty || TypeRules.IsWildcard(t))
				return false;
			if (t == "String" || t == "StringView")
			{
				outElem.Set("char32");
				return true;
			}
			if (t.EndsWith(']'))
			{
				// `int[]`, `int[,]`, `int[4]`: the element is what stands before the brackets.
				let part = TypeRules.ArrayPart(t);
				if (part.IsEmpty || part.Length >= t.Length)
					return false;
				outElem.Set(StringView(t, 0, t.Length - part.Length));
				outElem.Trim();
				return !outElem.IsEmpty;
			}
			if (t.EndsWith('*'))
				return false;
			let baseName = TypeRules.BaseName(t);
			List<StringView> args = scope .();
			TypeRules.GenericArgs(t, args);
			switch (baseName)
			{
			case "List", "HashSet", "Queue", "Span", "ReadOnlySpan", "IEnumerable", "SizedArray", "LinkedList", "PriorityQueue":
				if (args.IsEmpty)
					return false;
				outElem.Set(args[0]);
				return true;
			case "Dictionary":
				if (args.Count != 2)
					return false;
				outElem.AppendF("({} key, {} value)", args[0], args[1]);
				return true;
			default:
				return false;
			}
		}

		/// Why a value of this type cannot be looped over (`outWhy`), or false when it can, or when that
		/// is not known: only a type that is certainly not a collection (a number, a character, a bool,
		/// void, an enum) is refused. `h`: the workspace's class hierarchies (what kind a type is); null: names only.
		public static bool NotACollection(StringView typeIn, ITypeHierarchy h, String outWhy)
		{
			String t = scope .();
			TypeRules.Normalize(typeIn, t);
			t.Trim();
			if (t.IsEmpty || TypeRules.IsWildcard(t))
				return false;
			bool scalar = TypeRules.IsPrimitive(t);
			if (!scalar)
			{
				if (h != null)
				{
					String kind = scope .();
					h.KindOf(t, kind);
					scalar = kind == "enum";
				}
			}
			if (!scalar)
				return false;
			outWhy.AppendF("{} is not a collection: a For Each loops over a list, an array, a dictionary or text", t);
			return true;
		}

		static bool IsType(StringView t)
		{
			var s = t;
			s.Trim();
			return !s.IsEmpty && s != "let" && s != "var";
		}

		/// A For Each's element pin: the declared Element Type when there is one, else the element type
		/// of the collection wired into it (nothing when none is, or it is not known).
		public static bool SyncForEach(Graph g, Node n)
		{
			if (n == null || n.Kind != .ForEach)
				return false;
			let element = n.FindOutput("element");
			if (element == null)
				return false;
			String want = scope .();
			if (IsType(n.GetSetting("element-type")))
				want.Set(n.GetSetting("element-type"));
			else
			{
				let coll = n.FindInput("collection");
				let link = (coll != null) ? g.FindLinkTo(coll) : null;
				if (link != null)
					ElementType(link.From.TypeName, want);
			}
			if (element.TypeName == want)
				return false;
			element.SetTypeText(want);
			g.Version++;
			return true;
		}

		/// A counting For loop's pins: the counter, Start and Count take the integer type the loop
		/// declares (Counter Type). A loop that declares none keeps the counter it was read with and
		/// gives Start and Count the same integer type, so a float or a character cannot be wired in.
		public static bool SyncFor(Graph g, Node n)
		{
			if (n == null || n.Kind != .For)
				return false;
			let counter = n.FindOutput("index");
			if (counter == null)
				return false;
			String type = scope .();
			if (IsType(n.GetSetting("index-type")))
				type.Set(n.GetSetting("index-type"));
			else if (TypeRules.IsInt(counter.TypeName))
				type.Set(counter.TypeName);
			if (type.IsEmpty)
				return false;
			bool any = false;
			if (counter.TypeName != type)
			{
				counter.SetTypeText(type);
				any = true;
			}
			for (let p in n.Inputs)
			{
				if (p.Kind != .Value || (p.Name != "start" && p.Name != "count") || p.TypeName == type)
					continue;
				// A wire that no longer fits is kept (the validator names it); the pin takes the type.
				p.SetTypeText(type);
				any = true;
			}
			if (any)
				g.Version++;
			return any;
		}

		/// A Cast's Result: the destination type of the cast, nothing for `.` (the type comes from where
		/// the value goes).
		public static bool SyncCast(Graph g, Node n)
		{
			if (n == null || n.Kind != .Cast)
				return false;
			let r = n.Result;
			if (r == null)
				return false;
			var t = StringView(n.Text);
			t.Trim();
			StringView want = (t == "." || t == "(.)") ? "" : t;
			if (r.TypeName == want)
				return false;
			DeleteAndNullify!(r.WildcardType);
			r.SetTypeText(want);
			g.Version++;
			return true;
		}

		/// Brings every derived pin type of the graph in step with the settings and wires. True when a
		/// pin changed.
		public static bool Sync(Graph g)
		{
			bool any = false;
			for (let n in g.Nodes)
			{
				switch (n.Kind)
				{
				case .ForEach: any |= SyncForEach(g, n);
				case .For: any |= SyncFor(g, n);
				case .Cast: any |= SyncCast(g, n);
				case .Swizzle, .Shuffle, .Operator: any |= VectorNodes.Sync(g, n);
				default:
				}
			}
			return any;
		}
	}
}
