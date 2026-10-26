using System;
using System.Collections;
using Treadle.Model;
using Treadle.Graph;

namespace Treadle.Catalog
{
	/// The Node menu's vector rows (docs/SIMD-and-Vectors.md 1.4 and 1.9) from a table of the editor's own,
	/// until the language's catalogue source lists them: Swizzle and Shuffle, Make / Break / Splat of the
	/// common vector types, and the `Core.Vector` calls the menu offers from a vector pin (Get Lane, Set Lane,
	/// the reductions, Any / All of a mask) with the spec's names and parameter names.
	///
	/// The rows are stand-ins (`NodeSpec.StandIn`): `AddStandIns` adds each one only when the source has no
	/// row with the same key (`Key`: the call name of a call, the kind word and subject of a node kind), so the
	/// compiler's rows replace them as it learns the types. `Typed` makes a row for one vector type, which is
	/// what the menu lists when a vector pin is dragged.
	static class VectorCatalog
	{
		public const String Category = "Math | Vector";
		public const String Owner = "Core.Vector";

		/// The `Core.Vector` calls: name, menu label, inputs (`name Type`, `T` the vector, `E` its element),
		/// result, which vectors (`a` any, `n` numbers, `m` masks), tooltip.
		static (StringView name, StringView label, StringView pins, StringView ret, char8 on, StringView tip)[8] sCalls = .(
			("GetLane", "Get Lane", "v T,i int", "E", 'a', "Lane i of the vector (Debug checks that i is a lane)"),
			("WithLane", "Set Lane", "v T,i int,s E", "T", 'a', "The vector with lane i replaced by s"),
			("Sum", "Reduce Add", "v T", "E", 'n', "The lanes added (floats in a fixed pairwise order)"),
			("Product", "Reduce Multiply", "v T", "E", 'n', "The lanes multiplied (floats in a fixed pairwise order)"),
			("MinLane", "Reduce Min", "v T", "E", 'n', "The smallest lane"),
			("MaxLane", "Reduce Max", "v T", "E", 'n', "The largest lane"),
			("Any", "Any Lane", "m T", "bool", 'm', "True when any lane of the mask is set"),
			("All", "All Lanes", "m T", "bool", 'm', "True when every lane of the mask is set"));

		/// The rows a vector pin's Node menu lists first, by key word: from an output (`fromOutput`) the
		/// vector's Break, Swizzle, Shuffle and calls; into an input its Make and Splat.
		public static void ContextKeys(StringView vectorType, bool fromOutput, List<StringView> outKeys)
		{
			String e = scope .();
			if (!VectorTypes.Info(vectorType, e, ?))
				return;
			if (!fromOutput)
			{
				outKeys.Add("Make");
				outKeys.Add("Splat");
				return;
			}
			outKeys.Add("Break");
			outKeys.Add("Swizzle");
			outKeys.Add("Shuffle");
			let mask = e == "bool";
			for (let c in sCalls)
				if (c.on == 'a' || (c.on == 'm') == mask)
					outKeys.Add(c.name);
		}

		/// A row's key: the call name of a call (`Core.Vector.GetLane`), else the kind word, the subject and
		/// the settings (`Make float4`, `Swizzle`). A source row with the key of a stand-in replaces it.
		public static void Key(NodeSpec s, String outKey)
		{
			if (s.KindWord.IsEmpty)
				outKey.AppendF("call {}", s.CallName);
			else if (s.KindWord == "Math")
				outKey.AppendF("Math {}", s.Settings);
			else
				outKey.AppendF("{} {}", s.KindWord, s.Subject);
		}

		/// Adds the stand-in rows the source did not give (the source's rows are in `specs`).
		public static void AddStandIns(List<NodeSpec> specs)
		{
			HashSet<String> have = scope .();
			defer { for (let k in have) delete k; }
			for (let s in specs)
			{
				String k = new .();
				Key(s, k);
				if (!have.Add(k))
					delete k;
			}
			List<NodeSpec> mine = scope .();
			Generic(mine);
			// Make / Break of every vector type (Split Pin finds a vector's lanes through them; the
			// uncommon ones are advanced rows), Splat of the common ones.
			List<String> all = scope .();
			defer { ClearAndDeleteItems!(all); }
			VectorTypes.All(all);
			for (let t in all)
			{
				bool common = false;
				for (let c in VectorTypes.Common)
					if (c == t)
						common = true;
				for (let word in StringView[?]("Make", "Break", "Splat"))
				{
					if (word == "Splat" && !common)
						continue;
					let s = new NodeSpec();
					if (Typed(word, t, s))
					{
						s.IsAdvanced = !common;
						mine.Add(s);
					}
					else
						delete s;
				}
			}
			String key = scope .();
			for (let s in mine)
			{
				key.Clear();
				Key(s, key);
				if (have.Contains(key))
				{
					delete s;
					continue;
				}
				s.StandIn = true;
				specs.Add(s);
			}
		}

		/// The rows for any vector (`T` the vector, `E` its element): Swizzle, Shuffle and the calls.
		static void Generic(List<NodeSpec> outSpecs)
		{
			let swz = NewSpec("Swizzle", "Lanes of a vector picked by letter (.zyx, .xxxx): a vector, or one lane for one letter");
			swz.KindWord.Set("Swizzle");
			swz.Settings.Set("lanes zyx");
			swz.IsGeneric = true;
			swz.Keywords.Append(" vector lanes xyzw");
			Pin(swz, "value", "T");
			outSpecs.Add(swz);
			let shf = NewSpec("Shuffle", "Lanes of two vectors picked by number: 0 to N-1 from A, N to 2N-1 from B");
			shf.KindWord.Set("Shuffle");
			shf.Settings.Set("mask 0 4 1 5");
			shf.IsGeneric = true;
			shf.Keywords.Append(" vector lanes mask interleave");
			Pin(shf, "a", "T");
			Pin(shf, "b", "T");
			outSpecs.Add(shf);
			for (let c in sCalls)
			{
				let s = NewSpec(c.label, c.tip);
				Call(s, c.name, c.pins, c.ret, "T", "E");
				s.IsGeneric = true;
				outSpecs.Add(s);
			}
		}

		static NodeSpec NewSpec(StringView label, StringView tip)
		{
			let s = new NodeSpec();
			s.Kind = .Pure;
			s.Label.Set(label);
			s.DisplayName.Set(label);
			s.Category.Set(Category);
			s.Namespace.Set("Core");
			s.Tooltip.Set(tip);
			s.Keywords.Append("vector simd");
			return s;
		}

		static PinSpec Pin(NodeSpec s, StringView name, StringView type, bool output = false)
		{
			let p = new PinSpec();
			p.Name.Set(name);
			p.Label.Set(name);
			p.Type.Set(type);
			if (output)
				p.Modifier.Set("out");
			s.Pins.Add(p);
			return p;
		}

		/// A `Core.Vector` call row: `pins` is `name Type,...` with `T` and `E` replaced by `vec` and `elem`.
		static void Call(NodeSpec s, StringView name, StringView pins, StringView ret, StringView vec, StringView elem)
		{
			StringView Sub(StringView t) => (t == "T") ? vec : ((t == "E") ? elem : t);
			s.CallName.AppendF("{}.{}", Owner, name);
			s.MemberName.Set(name);
			s.OwnerType.Set(Owner);
			s.IsStatic = true;
			s.ReturnType.Set(Sub(ret));
			s.Keywords.AppendF(" Vector {}", name);
			for (var part in pins.Split(','))
			{
				let sp = part.IndexOf(' ');
				let p = Pin(s, part.Substring(0, sp), Sub(part.Substring(sp + 1)));
				if (s.ParamsText.Length > 0)
					s.ParamsText.Append(", ");
				s.ParamsText.AppendF("{} {}", p.Type, p.Name);
			}
		}

		/// The row `word` for the vector type `vectorType` into `outSpec`: `Make`, `Break`, `Splat`, `Swizzle`,
		/// `Shuffle` or a `Core.Vector` call name (`GetLane`). False when the row does not exist for the type.
		public static bool Typed(StringView word, StringView vectorType, NodeSpec outSpec)
		{
			String e = scope .();
			if (!VectorTypes.Info(vectorType, e, let lanes))
				return false;
			String v = scope .();
			VectorTypes.Spell(e, lanes, v);
			let s = outSpec;
			s.Kind = .Pure;
			s.Category.Set(Category);
			s.Namespace.Set("Core");
			s.Keywords.AppendF("vector simd {}", v);
			String lane = scope .();
			switch (word)
			{
			case "Make", "Break":
				let make = word == "Make";
				s.Label.AppendF("{} {}", word, v);
				s.KindWord.Set(word);
				s.Subject.Set(v);
				if (make)
					s.ReturnType.Set(v);
				s.Tooltip.AppendF(make ? "Builds a {} from its {} lanes" : "Splits a {} into its {} lanes", v, lanes);
				for (int i < lanes)
				{
					lane.Clear();
					VectorTypes.LaneName(lanes, i, lane);
					Pin(s, lane, e, !make);
				}
			case "Splat":
				s.Label.AppendF("Splat {}", v);
				s.KindWord.Set("Math");
				s.Settings.AppendF("expr \"{}(x)\"", v);
				s.ReturnType.Set(v);
				s.Tooltip.AppendF("A {} with every lane x (the Math Expression {}(x))", v, v);
				s.Keywords.Append(" splat broadcast fill");
				Pin(s, "x", e);
			case "Swizzle":
				String l = scope .();
				VectorNodes.DefaultSwizzle(lanes, l);
				s.Label.AppendF("Swizzle .{}", l);
				s.KindWord.Set("Swizzle");
				s.Settings.AppendF("lanes {}", l);
				VectorNodes.SwizzleResult(v, l, s.ReturnType);
				s.Tooltip.Set("Lanes picked by letter: change them in Properties");
				Pin(s, "value", v);
			case "Shuffle":
				String m = scope .();
				VectorNodes.DefaultMask(lanes, m);
				s.Label.AppendF("Shuffle {}", m);
				s.KindWord.Set("Shuffle");
				s.Settings.AppendF("mask {}", m);
				s.ReturnType.Set(v);
				s.Tooltip.AppendF("Lanes of A and B picked by number (0 to {} from A, {} to {} from B): change them in Properties", lanes - 1, lanes, 2 * lanes - 1);
				Pin(s, "a", v);
				Pin(s, "b", v);
			default:
				for (let c in sCalls)
				{
					if (c.name != word)
						continue;
					if (c.on == 'n' && e == "bool" || c.on == 'm' && e != "bool")
						return false;
					s.Label.Set(c.label);
					s.Tooltip.Set(c.tip);
					Call(s, c.name, c.pins, c.ret, v, e);
					s.DisplayName.Set(s.Label);
					return true;
				}
				return false;
			}
			s.DisplayName.Set(s.Label);
			return true;
		}
	}
}
