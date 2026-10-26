using System;
using System.Collections;
using Treadle.Catalog;
using Treadle.Model;

namespace Treadle.Graph
{
	/// Split struct pins (Graph-Format.md 3.2, `split <pin> <Type>`): a struct-typed pin drawn as one pin
	/// per field on the same node, `<pin>.<field>` (Value.First, Value.Second), instead of a Make / Break
	/// node beside it. The parent pin stays in the model (hidden while split); the sub-pins carry the
	/// wires and literals. For the compiler, `Expand` turns each split into the Make (an input) or Break
	/// (an output) node it stands for, in a copy of the graph.
	static class SplitPins
	{
		/// The node line's key: `split <pin> <Type>` (kept with the node's settings, in file order).
		public const String Key = "split";

		/// The `split` line of `n` for the pin `pin`, or null.
		public static NodeSetting Find(Node n, StringView pin)
		{
			for (let s in n.Settings)
			{
				if (s.Key != Key || s.IsSet)
					continue;
				StringView v = s.Value;
				let sp = v.IndexOf(' ');
				let name = (sp > 0) ? v.Substring(0, sp) : v;
				if (name == pin)
					return s;
			}
			return null;
		}

		/// Whether `p` is split into its fields (hidden; its sub-pins are drawn).
		public static bool IsSplit(Pin p) => p != null && p.Kind == .Value && Find(p.Owner, p.Name) != null;

		/// The struct type a split names (`split value Core.Pair<int,float>`); "" when the line has none.
		public static StringView TypeOf(NodeSetting s)
		{
			StringView v = s.Value;
			let sp = v.IndexOf(' ');
			if (sp < 0)
				return "";
			var t = v.Substring(sp + 1);
			t.Trim();
			return t;
		}

		/// The name of the split pin `p` is a field of (`value` for `value.First`), or "" when `p` is not
		/// a sub-pin. A sub-pin's name is its parent's, a dot, and the field.
		public static StringView ParentOf(Pin p)
		{
			if (p == null || p.Kind != .Value)
				return "";
			let dot = p.Name.LastIndexOf('.');
			if (dot <= 0)
				return "";
			let parent = StringView(p.Name, 0, dot);
			return (Find(p.Owner, parent) != null) ? parent : "";
		}

		public static bool IsSubPin(Pin p) => !ParentOf(p).IsEmpty;

		/// The field a sub-pin stands for (`First` for `value.First`).
		public static StringView FieldOf(Pin p)
		{
			let parent = ParentOf(p);
			return parent.IsEmpty ? "" : StringView(p.Name, parent.Length + 1);
		}

		/// The sub-pins of the split pin `parent`, in the node's order.
		public static void SubPins(Pin parent, List<Pin> outPins)
		{
			let list = parent.IsInput ? parent.Owner.Inputs : parent.Owner.Outputs;
			for (let p in list)
				if (p != parent && p.Name.Length > parent.Name.Length + 1 && p.Name.StartsWith(parent.Name) && p.Name[parent.Name.Length] == '.')
					outPins.Add(p);
		}

		/// Whether any node of the graph has a split pin.
		public static bool Any(Graph g)
		{
			for (let n in g.Nodes)
				for (let s in n.Settings)
					if (s.Key == Key && !s.IsSet)
						return true;
			return false;
		}

		/// Splits `p` (a struct-typed value pin) into one pin per field (`fields`: name and type), right
		/// after it in the node's order. The parent's wires and literal go (a split pin is wired through its
		/// fields). False when `p` is already split or has no fields.
		public static bool Split(Graph g, Pin p, StringView typeText, Span<(StringView name, StringView type)> fields)
		{
			if (p == null || p.Kind != .Value || fields.Length == 0 || IsSplit(p) || IsSubPin(p))
				return false;
			let n = p.Owner;
			g.DisconnectPin(p);
			p.Default.Clear();
			NodeSetting s = new .();
			s.Key.Set(Key);
			s.IsSet = false;
			s.Value.AppendF("{} {}", p.Name, typeText);
			n.Settings.Add(s);
			let list = p.IsInput ? n.Inputs : n.Outputs;
			int at = list.IndexOf(p) + 1;
			for (let f in fields)
			{
				String name = scope $"{p.Name}.{f.name}";
				if ((p.IsInput ? n.FindInput(name) : n.FindOutput(name)) != null)
					continue;
				let sub = g.AddPin(n, p.IsInput, .Value, name, "");
				SubLabel(p, f.name, sub.Label);
				sub.SetTypeText(f.type);
				sub.Role = p.IsInput ? .Arg : .Result;
				sub.Optional = p.IsInput;
				list.Remove(sub);
				list.Insert(at++, sub);
			}
			g.Version++;
			return true;
		}

		/// A sub-pin's label: the parent's label and the field ("Value First"), or the field alone.
		public static void SubLabel(Pin parent, StringView field, String outLabel)
		{
			outLabel.Clear();
			if (!parent.Label.IsEmpty)
				outLabel.AppendF("{} ", parent.Label);
			outLabel.Append(field);
		}

		/// Recombine: the sub-pins go with their wires and literals, the parent pin is shown again.
		public static bool Recombine(Graph g, Pin p)
		{
			let s = (p != null) ? Find(p.Owner, p.Name) : null;
			if (s == null)
				return false;
			List<Pin> subs = scope .();
			SubPins(p, subs);
			for (let sub in subs)
				g.RemovePin(sub);
			p.Owner.Settings.Remove(s);
			delete s;
			g.Version++;
			return true;
		}

		/// After a read: each node's sub-pins right after their parent, labelled and optional (a wire or
		/// an `in` line made them where it was read).
		public static void Normalize(Node n)
		{
			for (int side < 2)
			{
				let list = (side == 0) ? n.Inputs : n.Outputs;
				List<Pin> parents = scope .();
				for (let p in list)
					if (IsSplit(p))
						parents.Add(p);
				for (let parent in parents)
				{
					List<Pin> subs = scope .();
					SubPins(parent, subs);
					for (let sub in subs)
					{
						list.Remove(sub);
						sub.Optional = side == 0;
						sub.Role = (side == 0) ? .Arg : .Result;
						SubLabel(parent, StringView(sub.Name, parent.Name.Length + 1), sub.Label);
					}
					int at = list.IndexOf(parent) + 1;
					for (let sub in subs)
						list.Insert(at++, sub);
				}
			}
		}

		/// The field types of an instance of a generic struct: the generic parameters `declared` names, in
		/// the order they first appear, take `structType`'s arguments (`Core.Pair<int,float>` with `TFirst`,
		/// `TSecond` -> `int`, `float`). Without arguments, or when the counts differ, the declared types.
		public static void InstanceFieldTypes(StringView structType, List<StringView> declared, List<String> outTypes)
		{
			List<StringView> args = scope .();
			TypeRules.GenericArgs(structType, args);
			List<StringView> parms = scope .();
			for (let t in declared)
			{
				int i = 0;
				while (i < t.Length)
				{
					if (t[i].IsLetter || t[i] == '_')
					{
						int s = i;
						while (i < t.Length && (t[i].IsLetterOrDigit || t[i] == '_'))
							i++;
						let id = t.Substring(s, i - s);
						bool qualified = s > 0 && t[s - 1] == '.';
						if (!qualified && TypeRules.IsGenericParam(id) && !parms.Contains(id))
							parms.Add(id);
						continue;
					}
					i++;
				}
			}
			Dictionary<String, String> map = scope .();
			defer { for (let kv in map) { delete kv.key; delete kv.value; } }
			if (!args.IsEmpty && args.Count == parms.Count)
				for (int i < parms.Count)
				{
					var a = args[i];
					a.Trim();
					map[new String(parms[i])] = new String(a);
				}
			for (let t in declared)
			{
				String o = new .();
				TypeRules.Substitute(t, map, o);
				outTypes.Add(o);
			}
		}

		/// A record id plus the split pin: the key of the Make / Break a split stands for (`a1b2c_value`).
		/// Record ids never hold `_`, so the part before the first one names the node.
		public static void SynthKey(StringView nodeKey, StringView pin, String outKey)
		{
			outKey.AppendF("{}_{}", nodeKey, pin);
		}

		/// The node and pin a synthesized key stands for (`a1b2c_value` -> `a1b2c`, `value`); false when
		/// `key` is a plain record id.
		public static bool OwnerOfKey(StringView key, out StringView nodeKey, out StringView pin)
		{
			let us = key.IndexOf('_');
			if (us <= 0)
			{
				nodeKey = key;
				pin = default;
				return false;
			}
			nodeKey = key.Substring(0, us);
			pin = key.Substring(us + 1);
			return true;
		}

		/// For the compiler: a copy of `src` where each split pin is wired to the Make (an input) or the
		/// Break (an output) node it stands for, the sub-pins' wires and literals moved onto that node's
		/// fields (`SynthKey` keys). Null when `src` has no split pins (then `src` is used as it is).
		public static Graph Expand(Graph src)
		{
			if (!Any(src))
				return null;
			let g = src.Clone();
			List<Node> nodes = scope .();
			nodes.AddRange(g.Nodes);
			for (let n in nodes)
			{
				for (int si = 0; si < n.Settings.Count; si++)
				{
					let s = n.Settings[si];
					if (s.Key != Key || s.IsSet)
						continue;
					StringView v = s.Value;
					let sp = v.IndexOf(' ');
					let pinName = (sp > 0) ? v.Substring(0, sp) : v;
					var parent = n.FindInput(pinName);
					bool input = parent != null;
					if (parent == null)
						parent = n.FindOutput(pinName);
					if (parent == null || parent.Kind != .Value)
						continue;
					StringView typeText = TypeOf(s);
					if (typeText.IsEmpty)
						typeText = parent.TypeName;
					// A wire on the parent itself wins (a hand-edited file).
					if (input && g.IsLinked(parent))
						continue;
					List<Pin> subs = scope .();
					SubPins(parent, subs);
					let synth = g.AddNode(input ? .Make : .BreakStruct);
					SynthKey(n.Key, pinName, synth.Key..Clear());
					synth.SetSubjectTypeText(typeText);
					synth.X = n.X + (input ? -200 : 200);
					synth.Y = n.Y;
					synth.Disabled = n.Disabled;
					NodeFactory.Shape(g, synth);
					for (let sub in subs)
					{
						let field = StringView(sub.Name, pinName.Length + 1);
						let fp = input ? g.AddDataIn(synth, field, field) : g.AddDataOut(synth, field, field);
						fp.Role = input ? .Arg : .Result;
						fp.SetType(TypeRef.CloneOrNull(sub.Type));
						if (input)
							fp.Default.Set(sub.Default);
						for (let l in g.Links)
						{
							if (input && l.To == sub)
								l.To = fp;
							else if (!input && l.From == sub)
								l.From = fp;
						}
						(input ? n.Inputs : n.Outputs).Remove(sub);
						delete sub;
					}
					if (input)
						g.AddLinkRaw(synth.FindOutput("value"), parent);
					else
						g.AddLinkRaw(parent, synth.FindInput("value"));
				}
			}
			return g;
		}

		/// After binding the expanded copy: the editor's pins get the types the compiler found (the copy's
		/// pins of the same node and name; a sub-pin from its Make / Break field).
		public static void CopyTypes(Graph expanded, Graph editor)
		{
			for (let c in expanded.Nodes)
			{
				StringView ownerKey;
				StringView pin;
				let synth = OwnerOfKey(c.Key, out ownerKey, out pin);
				let e = editor.FindNodeByKey(ownerKey);
				if (e == null)
					continue;
				for (int side < 2)
					for (let p in (side == 0) ? c.Inputs : c.Outputs)
					{
						if (p.Kind != .Value || p.TypeName.IsEmpty)
							continue;
						Pin to;
						if (!synth)
							to = (side == 0) ? e.FindInput(p.Name) : e.FindOutput(p.Name);
						else if (p.Name == "value")
							to = e.FindInput(pin) ?? e.FindOutput(pin);
						else
						{
							String sub = scope $"{pin}.{p.Name}";
							to = e.FindInput(sub) ?? e.FindOutput(sub);
						}
						if (to != null && to.TypeName != p.TypeName)
							to.SetTypeText(p.TypeName);
					}
			}
		}
	}
}
