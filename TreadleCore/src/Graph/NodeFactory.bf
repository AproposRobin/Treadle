using System;
using System.Collections;
using Treadle.Catalog;
using Treadle.Document;
using Treadle.Language;
using Treadle.Model;

namespace Treadle.Graph
{
	/// Creates nodes with the pins Graph-Format.md 3.2 gives each kind. `Shape` is the one place
	/// that knows a kind's fixed pins; the reader uses it too, then adds the pins that wires and
	/// `in` lines name (arguments, fields, payloads).
	static class NodeFactory
	{
		/// Whether a node of this kind (with its current settings) has flow pins. Calls and
		/// Intrinsics decide by their callee (the reader by their wires). Bind, Lambda and a boxing
		/// Cast allocate when they capture or name an allocation and are flow nodes then
		/// (allocation is a flow node, Language.md 3).
		public static bool HasFlow(Node n)
		{
			switch (n.Kind)
			{
			case .Bind:
				return n.HasSetting("alloc") && n.GetSetting("alloc") != "pointer";
			case .Lambda:
				if (n.HasSetting("alloc"))
					return true;
				for (let s in n.Settings)
					if (s.Key == "capture")
						return true;
				return false;
			case .Cast:
				// A boxing Cast allocates; a checked (class) Cast branches on its result.
				return n.GetSetting("kind") == "box" || n.HasSetting("checked");
			case .Call, .Intrinsic:
				return !n.IsPure;
			default:
				return !NodeKinds.IsValueKind(n.Kind) && n.Kind != .Unknown;
			}
		}

		static Pin Out(Graph g, Node n, StringView name, StringView label, StringView type = "", PinRole role = .Result)
		{
			let p = g.AddDataOut(n, name, label);
			p.SetTypeText(type);
			p.Role = role;
			return p;
		}

		static Pin In(Graph g, Node n, StringView name, StringView label, StringView type = "", PinRole role = .None)
		{
			let p = g.AddDataIn(n, name, label);
			p.SetTypeText(type);
			p.Role = role;
			// An unwired Receiver reads `this` (a static context reports that, not "needs a value").
			if (role == .Receiver)
				p.Optional = true;
			return p;
		}

		static Pin Next(Graph g, Node n, StringView name, StringView label = "")
		{
			let p = g.AddExecOut(n, name, label);
			p.Role = .Next;
			return p;
		}

		static Pin Body(Graph g, Node n, StringView name, StringView label)
		{
			let p = g.AddExecOut(n, name, label);
			p.Role = .Body;
			return p;
		}

		/// Adds the fixed pins of the node's kind (the node has none yet). Arguments, struct
		/// fields, payloads and further outputs are not fixed: they come from the callee, the
		/// type, or (in the reader) from the file.
		public static void Shape(Graph g, Node n)
		{
			n.IsPure = !HasFlow(n);
			if (!n.IsPure && n.Kind != .Entry)
				g.AddExecIn(n);
			switch (n.Kind)
			{
			case .Entry:
				Next(g, n, "then");
			case .Return:
				In(g, n, "value", "Return Value").Optional = true;
			case .Call:
				if (!n.IsPure)
					Next(g, n, "then");
				if (n.Binding == .Instance || n.Text.StartsWith("this."))
					In(g, n, "receiver", "Receiver", ReceiverType(g, n.Text, .. scope String()), .Receiver);
			case .Invoke:
				In(g, n, "delegate", "Delegate");
				Next(g, n, "then");
			case .Intrinsic:
				if (!n.IsPure)
					Next(g, n, "then");
			case .Get:
				if (HasReceiver(n.Text))
					In(g, n, "receiver", "Receiver", ReceiverType(g, n.Text, .. scope String()), .Receiver);
				Out(g, n, "value", "");
			case .Set:
				if (HasReceiver(n.Text))
					In(g, n, "receiver", "Receiver", ReceiverType(g, n.Text, .. scope String()), .Receiver);
				In(g, n, "value", "Value");
				Next(g, n, "then");
				Out(g, n, "result", "");
			case .This:
				Out(g, n, "value", "This");
			case .Base:
				Out(g, n, "value", "Base");
			case .Construct, .Local:
				if (n.HasSetting("count"))
					In(g, n, "count", "Count", "int");
				Next(g, n, "then");
				Out(g, n, "object", "Object", n.Text);
			case .Delete:
				In(g, n, "object", "Object");
				Next(g, n, "then");
			case .Defer:
				Body(g, n, "deferred", "Deferred");
				Next(g, n, "done", "Completed");
			case .DeferDelete:
				In(g, n, "object", "Object");
				Next(g, n, "then");
			case .Branch:
				In(g, n, "condition", "Condition", "bool");
				Next(g, n, "true", "True");
				Next(g, n, "false", "False");
			case .Sequence:
				int count = 2;
				if (int.Parse(n.GetSetting("count")) case .Ok(let c))
					count = Math.Clamp(c, 1, 64);
				for (int i < count)
					Body(g, n, scope $"then{i}", scope $"Then {i}");
			case .While, .DoWhile:
				In(g, n, "condition", "Condition", "bool");
				Body(g, n, "body", "Loop Body");
				Next(g, n, "done", "Completed");
			case .For:
				StringView it = n.GetSetting("index-type");
				if (it.IsEmpty)
					it = "int";
				In(g, n, "start", "Start", it);
				In(g, n, "count", "Count", it);
				In(g, n, "step", "Step", it).Optional = true;
				Body(g, n, "body", "Loop Body");
				Out(g, n, "index", "Index", it);
				Next(g, n, "done", "Completed");
			case .ForEach:
				In(g, n, "collection", "Collection");
				Body(g, n, "body", "Loop Body");
				Out(g, n, "element", "Element", n.GetSetting("element-type"));
				Out(g, n, "index", "Index", "int");
				Next(g, n, "done", "Completed");
			case .Break, .Continue:
			case .Switch:
				In(g, n, "value", "Value", n.GetSetting("on"));
				for (let s in n.Settings)
					if (s.Key == "case")
						Body(g, n, scope $"case:{s.Value}", s.Value);
				Body(g, n, "default", "Default");
				Next(g, n, "done", "Completed");
			case .Scope:
				Body(g, n, "body", "Body");
				Next(g, n, "done", "Completed");
			case .Gate:
				Body(g, n, "exit", "Exit");
				Next(g, n, "done", "Completed");
			case .DoOnce:
				Body(g, n, "once", "Once");
				Next(g, n, "done", "Completed");
			case .DoN:
				In(g, n, "n", "N", "int");
				Body(g, n, "do", "Do");
				Out(g, n, "counter", "Counter", "int");
				Next(g, n, "done", "Completed");
			case .FlipFlop:
				Body(g, n, "a", "A");
				Body(g, n, "b", "B");
				Out(g, n, "isA", "Is A", "bool");
				Next(g, n, "done", "Completed");
			case .MultiGate:
				int count = 2;
				if (int.Parse(n.GetSetting("count")) case .Ok(let c))
					count = Math.Clamp(c, 1, 64);
				for (int i < count)
					Body(g, n, scope $"out{i}", scope $"Out {i}");
				Next(g, n, "done", "Completed");
			case .GateOpen, .GateClose, .GateToggle, .ResetDoOnce, .ResetDoN, .ResetMultiGate:
				Next(g, n, "then");
			case .ResultMatch:
				In(g, n, "result", "Result");
				Body(g, n, "ok", "Ok");
				Out(g, n, "value", "Value");
				Body(g, n, "err", "Err");
				Out(g, n, "error", "Error");
				Next(g, n, "done", "Completed");
			case .Try:
				In(g, n, "result", "Result");
				Next(g, n, "then");
				Out(g, n, "value", "Value");
			case .Fatal:
				In(g, n, "message", "Message", "StringView");
			case .Operator:
				In(g, n, "a", "");
				if (!IsUnary(n.Text))
					In(g, n, "b", "");
				Out(g, n, "result", "", IsComparison(n.Text) ? "bool" : "");
			case .Select:
				In(g, n, "condition", "Condition", "bool");
				In(g, n, "true", "True");
				In(g, n, "false", "False");
				Out(g, n, "result", "");
			case .Cast:
				// A checked Cast is a flow node: `then` runs when the value is a T, `failed` when not.
				In(g, n, "value", "Value");
				bool isChecked = n.HasSetting("checked");
				if (!n.IsPure)
					Next(g, n, "then", isChecked ? "Succeeded" : "");
				if (isChecked)
					Next(g, n, "failed", "Failed");
				Out(g, n, "result", n.Text.IsEmpty ? "" : scope $"As {Node.ShortTypeName(n.Text, .. scope String())}", n.Text);
			case .Make:
				// A vector type's lanes are fixed by its type (`x y z w`, `lane0 ...`); a struct's fields
				// come from the type or the file.
				VectorNodes.AddLanePins(g, n);
				Out(g, n, "value", "", n.Text);
			case .BreakStruct:
				In(g, n, "value", "", n.Text);
				VectorNodes.AddLanePins(g, n);
			case .Swizzle:
				In(g, n, "value", "Value");
				Out(g, n, "result", "");
			case .Shuffle:
				In(g, n, "a", "A");
				In(g, n, "b", "B");
				Out(g, n, "result", "");
			case .MakeCase:
				Out(g, n, "value", "", EnumOfCase(n.Text));
			case .IsCase:
				In(g, n, "value", "", EnumOfCase(n.Text));
				Out(g, n, "result", "", "bool");
			case .Index:
				In(g, n, "collection", "Collection");
				In(g, n, "index", "Index", "int");
				Out(g, n, "value", "");
			case .Literal:
				Out(g, n, "value", "", n.GetSetting("type"));
			case .Bind:
				In(g, n, "receiver", "Receiver", "", .Receiver);
				if (!n.IsPure)
					Next(g, n, "then");
				Out(g, n, "value", "Delegate");
			case .Lambda:
				if (!n.IsPure)
					Next(g, n, "then");
				Out(g, n, "value", "Delegate", n.GetSetting("type"));
			case .Math:
				Out(g, n, "result", "");
			case .ChainCtor, .Unknown:
			}
		}

		/// Get / Set of a member reached through an object: `this.x` and `Type.x` (unwired
		/// `this.x` reads `this`); locals and parameters have none.
		public static bool HasReceiver(StringView subject) => !subject.IsEmpty && !subject.StartsWith("local:") && !subject.StartsWith("param:") && subject.Contains('.');

		/// The enum of a case subject: `Game.Color.Red` -> `Game.Color` ("" without a dot).
		public static StringView EnumOfCase(StringView subject)
		{
			int dot = LastTopLevelDot(subject);
			return (dot > 0) ? subject.Substring(0, dot) : default;
		}

		/// The type a member subject's Receiver holds: `this.x` -> the Sheet's own type,
		/// `Game.Player.TakeDamage(int)` -> `Game.Player`; "" when the subject names none.
		public static void ReceiverType(Graph g, StringView subject, String outType)
		{
			var s = subject;
			int paren = s.IndexOf('(');
			if (paren > 0)
				s = s.Substring(0, paren);
			int dot = LastTopLevelDot(s);
			if (dot <= 0)
				return;
			let owner = s.Substring(0, dot);
			if (owner == "this")
			{
				if (g != null)
					outType.Append(g.SelfType);
				return;
			}
			outType.Append(owner);
		}

		public static bool IsUnary(StringView op) => op == "!" || op == "~" || op == "neg";
		public static bool IsComparison(StringView op) => op == "==" || op == "!=" || op == "<" || op == ">" || op == "<=" || op == ">=" || op == "&&" || op == "||" || op == "!";

		/// A label for a pin the format names (`condition` -> `Condition`, `case:Red` -> `Red`).
		public static void LabelFor(StringView name, String outLabel)
		{
			var name;
			if (name == "in" || name == "then")
				return;
			if (name.StartsWith("case:"))
				name = name.Substring(5);
			outLabel.Append(name);
			if (!outLabel.IsEmpty && outLabel[0].IsLower)
				outLabel[0] = outLabel[0].ToUpper;
		}

		/// A node of `kind` with its fixed pins; `subject` is the format's subject token.
		public static Node Create(Graph g, NodeKind kind, StringView subject = "", bool hasFlow = true)
		{
			Node n = g.AddNode(kind);
			if (NodeKinds.HasTypeSubject(kind))
				n.SetSubjectTypeText(subject);
			else
				n.Text.Set(subject);
			if (kind == .Call || kind == .Intrinsic)
				n.IsPure = !hasFlow;
			if (kind == .Call && HasReceiver(subject) && !subject.StartsWith("this."))
				n.Binding = .Static;
			else if (kind == .Call && subject.StartsWith("this."))
				n.Binding = .Instance;
			Shape(g, n);
			return n;
		}

		/// Gives `n` the subject, constructor setting and pins of `shape`, a node of the same kind
		/// made in `g` for another overload or constructor, then removes `shape`. A pin with the same
		/// name and kind stays (with its literal, and with its wires while they still fit its new
		/// type); the other pins go with their wires. The pins end in `shape`'s order.
		public static void AdoptShape(Graph g, Node n, Node shape)
		{
			n.Text.Set(shape.Text);
			n.Binding = shape.Binding;
			if (shape.OwnerType != null)
				String.NewOrSet!(n.OwnerType, shape.OwnerType);
			else
				DeleteAndNullify!(n.OwnerType);
			n.RemoveSetting("ctor");
			if (shape.HasSetting("ctor"))
				n.SetSetting("ctor", shape.GetSetting("ctor"));
			for (int side < 2)
			{
				let input = side == 0;
				let mine = input ? n.Inputs : n.Outputs;
				let want = input ? shape.Inputs : shape.Outputs;
				List<Pin> order = scope .();
				for (let w in want)
				{
					Pin have = null;
					for (let p in mine)
						if (p.Name == w.Name && p.Kind == w.Kind && !order.Contains(p))
							have = p;
					if (have == null)
					{
						have = g.AddPin(n, input, w.Kind, w.Name, w.Label);
						have.Default.Set(w.Default);
					}
					else
					{
						have.Label.Set(w.Label);
						if (have.Default.IsEmpty)
							have.Default.Set(w.Default);
					}
					have.SetType(TypeRef.CloneOrNull(w.Type));
					have.Role = w.Role;
					have.Optional = w.Optional;
					have.Mode = w.Mode;
					order.Add(have);
				}
				for (int i = mine.Count - 1; i >= 0; i--)
					if (!order.Contains(mine[i]))
						g.RemovePin(mine[i]);
				mine.Clear();
				mine.AddRange(order);
			}
			n.IsPure = shape.IsPure;
			for (int i = g.Links.Count - 1; i >= 0; i--)
			{
				let l = g.Links[i];
				if ((l.From.Owner == n || l.To.Owner == n) && !Graph.CanConnectTyped(g.Language, l.From, l.To))
					g.Disconnect(l);
			}
			g.RemoveNode(shape);
			g.Version++;
		}

		/// Rebuilds a node's fixed pins after a setting changed (Sequence count, Switch cases):
		/// pins of the same name keep their wires and literals.
		public static void Reshape(Graph g, Node n)
		{
			Node probe = scope .();
			probe.Kind = n.Kind;
			probe.Text.Set(n.Text);
			probe.Binding = n.Binding;
			probe.IsPure = n.IsPure;
			for (let s in n.Settings)
				probe.Settings.Add(s.Clone());
			Graph tmp = scope .();
			tmp.Nodes.Add(probe);
			Shape(tmp, probe);
			tmp.Nodes.Remove(probe);
			// Remove fixed pins that are gone (flow pins and the kind's own value pins).
			for (int side < 2)
			{
				let mine = (side == 0) ? n.Inputs : n.Outputs;
				let want = (side == 0) ? probe.Inputs : probe.Outputs;
				for (int i = mine.Count - 1; i >= 0; i--)
				{
					let p = mine[i];
					if (p.Kind != .Flow && p.Role == .None)
						continue;
					// A constructor's arguments are not the kind's fixed pins: they stay (Properties'
					// Constructor row or the editor's refit changes them).
					if (p.Role == .Arg && (n.Kind == .Construct || n.Kind == .Local || n.Kind == .ChainCtor))
						continue;
					bool keep = false;
					for (let w in want)
						if (w.Name == p.Name)
							keep = true;
					if (!keep)
						g.RemovePin(p);
				}
				for (let w in want)
				{
					let have = (side == 0) ? n.FindInput(w.Name) : n.FindOutput(w.Name);
					if (have != null)
						continue;
					let p = g.AddPin(n, side == 0, w.Kind, w.Name, w.Label);
					p.SetType(TypeRef.CloneOrNull(w.Type));
					p.Role = w.Role;
					p.Optional = w.Optional;
				}
			}
			n.IsPure = probe.IsPure;
			g.Version++;
		}

		// ------------------------------------------------------------------ calls

		/// A call of `name` (a member reference; a bare name is a member of the own type).
		/// `hasFlow`: a flow call (in / then), else a value call. Arguments get pins by name.
		public static Node Call(Graph g, StringView name, bool hasFlow, Span<StringView> paramNames, Span<StringView> paramTypes, StringView returnType)
		{
			String subject = scope .(name);
			if (!name.Contains('.') && !name.Contains(':'))
				subject.Set(scope $"this.{name}");
			Node n = Create(g, .Call, subject, hasFlow);
			AddArgs(g, n, paramNames, paramTypes, default);
			AddResult(g, n, returnType);
			return n;
		}

		/// A static function call (no Receiver): `Owner.Name`.
		public static Node StaticCall(Graph g, StringView name, StringView ownerType, bool hasFlow,
			Span<StringView> paramNames, Span<StringView> paramTypes, StringView returnType, Span<StringView> modifiers = default)
		{
			String subject = scope .();
			if (!ownerType.IsEmpty)
				subject.AppendF("{}.", ownerType);
			subject.Append(name);
			Node n = Create(g, .Call, subject, hasFlow);
			n.Binding = .Static;
			if (!ownerType.IsEmpty)
				n.OwnerType = new String(ownerType);
			AddArgs(g, n, paramNames, paramTypes, modifiers);
			AddResult(g, n, returnType);
			return n;
		}

		/// A member function call: a Receiver pin of the owning type; unconnected means `this`.
		public static Node MemberCall(Graph g, StringView name, StringView ownerType, bool hasFlow,
			Span<StringView> paramNames, Span<StringView> paramTypes, StringView returnType, Span<StringView> modifiers = default)
		{
			String subject = scope .();
			subject.AppendF("{}.{}", ownerType.IsEmpty ? "this" : ownerType, name);
			Node n = Create(g, .Call, subject, hasFlow);
			n.Binding = .Instance;
			if (!ownerType.IsEmpty)
				n.OwnerType = new String(ownerType);
			var r = n.FindInput("receiver");
			if (r == null)
			{
				r = g.AddDataIn(n, "receiver", "Receiver");
				r.Role = .Receiver;
				r.Optional = true;
				n.Inputs.Remove(r);
				n.Inputs.Insert((n.ExecIn != null) ? 1 : 0, r);
			}
			if (!ownerType.IsEmpty)
				r.SetTypeText(ownerType);
			AddArgs(g, n, paramNames, paramTypes, modifiers);
			AddResult(g, n, returnType);
			return n;
		}

		public static Node This(Graph g, StringView selfType)
		{
			Node n = Create(g, .This);
			n.Result.SetTypeText(selfType);
			return n;
		}

		public static Node Base(Graph g, StringView baseType)
		{
			Node n = Create(g, .Base);
			n.Result.SetTypeText(baseType);
			return n;
		}

		static void AddResult(Graph g, Node n, StringView returnType)
		{
			if (returnType.IsEmpty || returnType == "void")
				return;
			Out(g, n, "result", "Return Value", returnType);
		}

		/// Splits a leading `ref ` / `out ` / `in ` off a type written with its modifier.
		public static void SplitModifier(StringView typeText, out StringView modifier, out StringView type)
		{
			var t = typeText;
			t.Trim();
			modifier = default;
			for (let m in StringView[?]("ref ", "out ", "params ", "in ", "mut "))
			{
				if (t.StartsWith(m))
				{
					modifier = t.Substring(0, m.Length - 1);
					t = t.Substring(m.Length);
					t.Trim();
					break;
				}
			}
			type = t;
		}

		/// Argument pins named by the parameters; `out` parameters are output pins.
		static void AddArgs(Graph g, Node n, Span<StringView> paramNames, Span<StringView> paramTypes, Span<StringView> modifiers)
		{
			for (int i < paramNames.Length)
			{
				StringView modifier = (i < modifiers.Length) ? modifiers[i] : default;
				StringView type = (i < paramTypes.Length) ? paramTypes[i] : default;
				if (modifier.IsEmpty)
					SplitModifier(type, out modifier, out type);
				StringView name = paramNames[i].IsEmpty ? scope:: $"arg{i}" : paramNames[i];
				if (modifier == "out")
				{
					let p = Out(g, n, name, name, type, .Arg);
					p.Mode = .Out;
					continue;
				}
				let p = In(g, n, name, name, type, .Arg);
				if (modifier == "ref")
					p.Mode = .Ref;
				else if (modifier == "in")
					p.Mode = .In;
			}
		}

		/// A node for a catalog entry: a call with typed, labelled pins and the declared defaults,
		/// or a Get / Set.
		public static Node FromSpec(Graph g, Treadle.Catalog.NodeSpec spec, bool hasFlow)
		{
			if (!spec.KindWord.IsEmpty)
				return FromKindSpec(g, spec);
			switch (spec.Kind)
			{
			case .Get, .Event:
				Node n = Get(g, scope $"{(spec.OwnerType.IsEmpty ? "this" : spec.OwnerType)}.{spec.MemberName}", spec.ReturnType);
				let r = n.FindInput("receiver");
				if (r != null && spec.IsStatic)
					g.RemovePin(r);
				else
					r?.SetTypeText(spec.OwnerType);
				return n;
			case .Set:
				Node n = Set(g, scope $"{(spec.OwnerType.IsEmpty ? "this" : spec.OwnerType)}.{spec.MemberName}", spec.ReturnType);
				let r = n.FindInput("receiver");
				if (r != null && spec.IsStatic)
					g.RemovePin(r);
				else
					r?.SetTypeText(spec.OwnerType);
				return n;
			default:
			}
			bool wantExec = hasFlow && !spec.IsPure;
			List<StringView> names = scope .();
			List<StringView> types = scope .();
			List<StringView> mods = scope .();
			for (let pin in spec.Pins)
			{
				if (pin.Modifier.Contains("params"))
					break;
				names.Add(pin.Name.IsEmpty ? pin.Label : pin.Name);
				types.Add(pin.Type);
				mods.Add(pin.IsOutput ? "out" : (pin.IsRef ? "ref" : ""));
			}
			StringView ret = spec.ReturnType.IsEmpty ? "void" : spec.ReturnType;
			Node n;
			if (spec.IsStatic)
			{
				int dot = LastTopLevelDot(spec.CallName);
				StringView owner = (dot > 0) ? spec.CallName.Substring(0, dot) : spec.OwnerType;
				StringView name = (dot > 0) ? spec.CallName.Substring(dot + 1) : spec.CallName;
				n = StaticCall(g, name, owner, wantExec, names, types, ret, mods);
			}
			else
			{
				// The catalogue names a member call with its owner (`Zoo.Animal.Speak`); MemberCall adds the owner itself.
				StringView name = spec.CallName;
				if (!spec.OwnerType.IsEmpty && name.Length > spec.OwnerType.Length && name.StartsWith(spec.OwnerType) && name[spec.OwnerType.Length] == '.')
					name = name.Substring(spec.OwnerType.Length + 1);
				n = MemberCall(g, name, spec.OwnerType, wantExec, names, types, ret, mods);
			}
			for (int i < names.Count)
			{
				let p = n.FindInput(names[i]);
				if (p == null)
					continue;
				let pin = spec.Pins[i];
				if (!pin.Default.IsEmpty)
					p.Default.Set(pin.Default);
				else if (p.TypeName == "bool" && mods[i].IsEmpty)
					p.Default.Set("false");
			}
			return n;
		}

		/// A catalog entry that names its node kind (`KindWord`, Graph-Format.md 3.2): Construct /
		/// Local with the constructor's arguments, Make / Break with the struct's fields, Make Case /
		/// Is Case with the payload, Cast, Switch on an enum, or any other kind with its fixed pins.
		static Node FromKindSpec(Graph g, Treadle.Catalog.NodeSpec spec)
		{
			StringView subject = spec.Subject.IsEmpty ? (StringView)spec.CallName : (StringView)spec.Subject;
			let kind = NodeKinds.Parse(spec.KindWord, !subject.IsEmpty);
			List<StringView> names = scope .();
			List<StringView> types = scope .();
			for (let pin in spec.Pins)
			{
				names.Add(pin.Name.IsEmpty ? pin.Label : pin.Name);
				types.Add(pin.Type);
			}
			Node n;
			switch (kind)
			{
			case .Construct, .Local:
				n = Construct(g, subject, kind == .Local, false, names, types);
			case .Make:
				n = Make(g, subject, names, types);
			case .BreakStruct:
				n = BreakStruct(g, subject, names, types);
			case .MakeCase:
				n = MakeCase(g, subject, names, types);
			case .IsCase:
				n = IsCase(g, subject, names, types);
			case .Cast:
				n = Cast(g, subject);
			case .Switch:
				List<StringView> labels = scope .();
				for (let c in spec.EnumCases)
					labels.Add(c);
				n = Switch(g, subject, labels);
			case .Unknown:
				n = Create(g, .Unknown);
				n.KindWord = new String(spec.KindWord);
				n.Text.Set(subject);
			case .Swizzle:
				n = Swizzle(g, spec.SettingOf(VectorNodes.LanesKey));
			case .Shuffle:
				n = Shuffle(g, spec.SettingOf(VectorNodes.MaskKey));
			case .Math:
				// A Math Expression with its expression (`set expr "float4(x)"`) and one typed input per name.
				n = Create(g, .Math);
				for (let pin in spec.Pins)
					if (!pin.IsOutput)
						In(g, n, names[@pin.Index], names[@pin.Index], types[@pin.Index]);
				if (!spec.ReturnType.IsEmpty)
					n.FindOutput("result")?.SetTypeText(spec.ReturnType);
			default:
				n = Create(g, kind, subject);
			}
			// The entry's settings (`lanes zyx`, `expr "float4(x)"`), as the file writes them.
			for (var line in spec.Settings.Split('\n'))
			{
				line.Trim();
				let sp = line.IndexOf(' ');
				if (sp > 0)
					n.SetSetting(line.Substring(0, sp), line.Substring(sp + 1));
			}
			for (let pin in spec.Pins)
			{
				if (pin.Default.IsEmpty)
					continue;
				let p = n.FindInput(pin.Name.IsEmpty ? pin.Label : pin.Name);
				if (p != null && !pin.IsOutput)
					p.Default.Set(pin.Default);
			}
			return n;
		}

		/// "Console" -> "Console", "System.Console" -> "Console", "List<int>" -> "List".
		public static void OwnerOfQualifier(StringView qualifier, String outOwner)
		{
			int dot = LastTopLevelDot(qualifier);
			var last = (dot >= 0) ? qualifier.Substring(dot + 1) : qualifier;
			int lt = last.IndexOf('<');
			if (lt > 0)
				last = last.Substring(0, lt);
			last.Trim();
			outOwner.Append(last);
		}

		/// Index of the last '.' outside generic brackets / parentheses, or -1.
		public static int LastTopLevelDot(StringView name)
		{
			int depth = 0;
			int dot = -1;
			for (int i < name.Length)
			{
				let c = name[i];
				if (c == '<' || c == '(' || c == '[')
					depth++;
				else if (c == '>' || c == ')' || c == ']')
					depth--;
				else if (c == '.' && depth == 0)
					dot = i;
			}
			return dot;
		}

		/// Adds one more argument pin to a Call or Math node (named `arg<i>` until it is renamed).
		public static Pin AddArgument(Graph g, Node n)
		{
			int count = n.ArgCount;
			return In(g, n, scope $"arg{count}", scope $"Arg {count}", "", .Arg);
		}

		/// The index of a C variadic call's extra input `va<i>` (Language.md 2.7), or -1.
		public static int VarArgIndex(Pin p)
		{
			if (p == null || !p.IsInput || p.Kind != .Value || p.Name.Length < 3 || !p.Name.StartsWith("va"))
				return -1;
			int v = 0;
			for (int i = 2; i < p.Name.Length; i++)
			{
				let c = p.Name[i];
				if (c < '0' || c > '9')
					return -1;
				v = v * 10 + (c - '0');
			}
			return v;
		}

		/// How many extra inputs (`va0`, `va1`, ...) a C variadic call has.
		public static int VarArgCount(Node n)
		{
			int count = 0;
			for (let p in n.Inputs)
				if (VarArgIndex(p) >= 0)
					count++;
			return count;
		}

		/// One more extra input of a C variadic call: `va<n>`, the first index none has, at the end
		/// (the front end reads them as `va0`, `va1`, ... after the function's own inputs).
		public static Pin AddVarArg(Graph g, Node n)
		{
			int next = 0;
			for (let p in n.Inputs)
				next = Math.Max(next, VarArgIndex(p) + 1);
			return In(g, n, scope $"va{next}", scope $"va{next}", "", .Arg);
		}

		/// Removes the last extra input of a C variadic call (with its wires).
		public static void RemoveLastVarArg(Graph g, Node n)
		{
			Pin last = null;
			for (let p in n.Inputs)
				if (VarArgIndex(p) >= 0 && (last == null || VarArgIndex(p) > VarArgIndex(last)))
					last = p;
			if (last != null)
				g.RemovePin(last);
		}

		public static void RemoveLastArgument(Graph g, Node n)
		{
			int count = n.ArgCount;
			if (count == 0)
				return;
			let p = n.FindArg(count - 1);
			if (p != null)
				g.RemovePin(p);
		}

		// ------------------------------------------------------------------ flow

		public static Node Branch(Graph g)
		{
			Node n = Create(g, .Branch);
			n.FindInput("condition").Default.Set("true");
			return n;
		}

		public static Node Loop(Graph g, NodeKind kind)
		{
			Node n = Create(g, kind);
			switch (kind)
			{
			case .While, .DoWhile:
				n.FindInput("condition").Default.Set("true");
			case .For:
				n.FindInput("start").Default.Set("0");
				n.FindInput("count").Default.Set("10");
			default:
			}
			return n;
		}

		/// A Switch on `valueType` with the given case labels.
		public static Node Switch(Graph g, StringView valueType, Span<StringView> labels)
		{
			Node n = g.AddNode(.Switch);
			if (!valueType.IsEmpty)
				n.SetSetting("on", valueType);
			for (let label in labels)
				AddCaseSetting(n, label);
			Shape(g, n);
			return n;
		}

		static void AddCaseSetting(Node n, StringView label)
		{
			NodeSetting s = new .();
			s.Key.Set("case");
			s.Value.Set(label);
			s.IsSet = false;
			n.Settings.Add(s);
		}

		/// Adds a case (a `case <label>` line and its output, before Default).
		public static Pin AddCase(Graph g, Node n, StringView label)
		{
			AddCaseSetting(n, label);
			Reshape(g, n);
			let p = n.FindOutput(scope $"case:{label}");
			let def = n.FindOutput("default");
			if (p != null && def != null)
			{
				n.Outputs.Remove(p);
				n.Outputs.Insert(n.Outputs.IndexOf(def), p);
			}
			return p;
		}

		public static void RemoveCase(Graph g, Node n, Pin p)
		{
			if (p.Owner != n || !p.Name.StartsWith("case:"))
				return;
			let label = StringView(p.Name, 5);
			for (let s in n.Settings)
				if (!s.IsSet && s.Key == "case" && s.Value == label)
				{
					n.Settings.Remove(s);
					delete s;
					break;
				}
			g.RemovePin(p);
		}

		/// Renames a case: its `case` line, its output and its payload outputs; wires stay on the
		/// renamed pins. False when another case already has the label.
		public static bool RenameCase(Graph g, Node n, Pin p, StringView label)
		{
			if (p.Owner != n || !p.Name.StartsWith("case:"))
				return false;
			let old = scope String(StringView(p.Name, 5));
			if (old == label)
				return true;
			if (n.FindOutput(scope $"case:{label}") != null)
				return false;
			for (let s in n.Settings)
				if (!s.IsSet && s.Key == "case" && s.Value == old)
				{
					s.Value.Set(label);
					break;
				}
			let prefix = scope $"case:{old}.";
			for (let o in n.Outputs)
			{
				if (o == p)
				{
					o.Name.Set(scope $"case:{label}");
					o.Label.Set(label);
				}
				else if (o.Name.StartsWith(prefix))
					o.Name.Set(scope $"case:{label}.{StringView(o.Name, prefix.Length)}");
			}
			g.Version++;
			return true;
		}

		/// The case label a new case of a switch on this kind starts with.
		public static void DefaultCaseLabel(PinValueKind kind, String outLabel)
		{
			switch (kind)
			{
			case .Text: outLabel.Append("\"\"");
			case .Char: outLabel.Append("'a'");
			default: outLabel.Append('0');
			}
		}

		/// The switched type of a Switch node, "" when not known.
		public static StringView SwitchType(Node n)
		{
			let on = n.GetSetting("on");
			if (!on.IsEmpty)
				return on;
			let v = n.FindInput("value");
			return (v == null) ? default : StringView(v.TypeName);
		}

		public static bool CanSwitchOn(PinValueKind kind) => kind == .Enum || kind == .Text || kind == .Number || kind == .Char;

		/// Moves a case up (-1) or down (+1) among the cases.
		public static bool MoveCase(Graph g, Node n, Pin p, int delta)
		{
			let at = n.Outputs.IndexOf(p);
			int to = at + delta;
			if (at < 0 || to < 0 || to >= n.Outputs.Count)
				return false;
			let other = n.Outputs[to];
			if (!other.Name.StartsWith("case:") || !p.Name.StartsWith("case:"))
				return false;
			n.Outputs[at] = other;
			n.Outputs[to] = p;
			// The `case` lines follow the outputs' order.
			List<NodeSetting> cases = scope .();
			for (let s in n.Settings)
				if (!s.IsSet && s.Key == "case")
					cases.Add(s);
			int ci = 0;
			for (let o in n.Outputs)
				if (o.Name.StartsWith("case:") && ci < cases.Count)
					cases[ci++].Value.Set(StringView(o.Name, 5));
			g.Version++;
			return true;
		}

		/// A Sequence, Gate, Do Once, Do N, Flip Flop, Multi Gate or one of their action nodes.
		/// `arms`: outputs of a Sequence / Multi Gate.
		public static Node Flow(Graph g, NodeKind kind, int arms = 2)
		{
			Node n = g.AddNode(kind);
			if ((kind == .Sequence || kind == .MultiGate) && arms != 2)
				n.SetSetting("count", scope $"{arms}");
			Shape(g, n);
			if (kind == .DoN)
				n.FindInput("n").Default.Set("3");
			return n;
		}

		public static Node Jump(Graph g, NodeKind kind) => Create(g, kind);

		// ------------------------------------------------------------------ lifetime

		/// Construct `T` (heap) or, with `local`, Local `T` (the region's).
		/// `ctorNames` / `ctorTypes`: the chosen constructor's parameters (an input each, and
		/// `set ctor (Types)`); none for the default constructor.
		public static Node Construct(Graph g, StringView typeText, bool local = false, bool isArray = false,
			Span<StringView> ctorNames = default, Span<StringView> ctorTypes = default)
		{
			Node n = g.AddNode(local ? .Local : .Construct);
			n.SetSubjectTypeText(typeText);
			if (isArray)
				n.SetSetting("count", "");
			SetCtorSetting(n, ctorNames, ctorTypes);
			Shape(g, n);
			if (isArray)
				n.FindInput("count").Default.Set("1");
			// Constructor arguments go before the flow outputs' rows: after `in` (and `count`).
			for (int i < ctorNames.Length)
				In(g, n, ctorNames[i], ctorNames[i], (i < ctorTypes.Length) ? ctorTypes[i] : default, .Arg);
			return n;
		}

		/// `set ctor (Types)` of the chosen constructor's parameters; none for the default one.
		static void SetCtorSetting(Node n, Span<StringView> ctorNames, Span<StringView> ctorTypes)
		{
			if (ctorNames.Length == 0)
				return;
			String sig = scope .("(");
			for (int i < ctorNames.Length)
			{
				if (i > 0)
					sig.Append(", ");
				sig.Append((i < ctorTypes.Length) ? ctorTypes[i] : "?");
			}
			sig.Append(')');
			n.SetSetting("ctor", sig);
		}

		/// A constructor's Base Constructor (`which` = "base") or This Constructor ("this") node
		/// (Language.md 2.5): no flow pins, an input per parameter of the constructor it runs first
		/// (`set ctor (Types)` names it).
		public static Node ChainCtor(Graph g, StringView which, Span<StringView> ctorNames = default, Span<StringView> ctorTypes = default)
		{
			Node n = g.AddNode(.ChainCtor);
			n.Text.Set(which);
			SetCtorSetting(n, ctorNames, ctorTypes);
			Shape(g, n);
			for (int i < ctorNames.Length)
				In(g, n, ctorNames[i], ctorNames[i], (i < ctorTypes.Length) ? ctorTypes[i] : default, .Arg);
			return n;
		}

		/// A generic type's parameters mapped to the arguments a type text gives them:
		/// `generics` "T,U" with `Pair<int,Point>` gives T -> int, U -> Point. Nothing when the text
		/// has no arguments or their count differs. The caller deletes the keys and values.
		public static void TypeArgMap(StringView generics, StringView typeText, Dictionary<String, String> outMap)
		{
			List<StringView> args = scope .();
			TypeRules.GenericArgs(typeText, args);
			List<StringView> names = scope .();
			for (var gp in generics.Split(','))
			{
				gp.Trim();
				if (!gp.IsEmpty)
					names.Add(gp);
			}
			if (args.IsEmpty || args.Count != names.Count)
				return;
			for (int i < names.Count)
			{
				var a = args[i];
				a.Trim();
				if (a != names[i])
					outMap[new String(names[i])] = new String(a);
			}
		}

		/// A constructor signature `(T, int)` with the generic parameters of `map` replaced.
		public static void SubstituteSignature(StringView sig, Dictionary<String, String> map, String outSig)
		{
			var inner = sig;
			inner.Trim();
			if (inner.StartsWith('('))
				inner = inner.Substring(1);
			if (inner.EndsWith(')'))
				inner.RemoveFromEnd(1);
			inner.Trim();
			outSig.Append('(');
			if (!inner.IsEmpty)
			{
				int depth = 0;
				int start = 0;
				bool first = true;
				for (int i = 0; i <= inner.Length; i++)
				{
					let c = (i < inner.Length) ? inner[i] : ',';
					if (c == '<' || c == '(' || c == '[')
						depth++;
					else if (c == '>' || c == ')' || c == ']')
						depth--;
					else if (c == ',' && depth == 0)
					{
						var part = inner.Substring(start, i - start);
						part.Trim();
						start = i + 1;
						if (!first)
							outSig.Append(", ");
						first = false;
						TypeRules.Substitute(part, map, outSig);
					}
				}
			}
			outSig.Append(')');
		}

		/// A Construct / Local / Base Constructor made for a generic type's declaration (`(T)`, an
		/// input of type T) put to the type's arguments: `set ctor` and the argument pins' types
		/// with the parameters of `map` replaced (`Box<Point>`: `(Point)`, an input of type Point).
		public static void InstantiateCtor(Graph g, Node n, Dictionary<String, String> map)
		{
			if (n == null || map == null || map.IsEmpty)
				return;
			if (n.HasSetting("ctor"))
			{
				String sig = scope .();
				SubstituteSignature(n.GetSetting("ctor"), map, sig);
				n.SetSetting("ctor", sig);
			}
			for (let p in n.Inputs)
			{
				if (p.Role != .Arg || p.Kind != .Value)
					continue;
				String t = scope .();
				TypeRules.Substitute(p.TypeName, map, t);
				if (t != p.TypeName)
					p.SetTypeText(t);
			}
			g.Version++;
		}

		/// Switches a Construct to a Local or back (same node, same id; wires stay).
		public static void SetLifetime(Graph g, Node n, bool local)
		{
			if (n == null || (n.Kind != .Construct && n.Kind != .Local))
				return;
			n.Kind = local ? .Local : .Construct;
			if (!local)
				n.RemoveSetting("function-scope");
			g.Version++;
		}

		/// Changes the type a Construct / Local allocates (the object pin follows).
		public static void SetAllocType(Graph g, Node n, StringView type)
		{
			if (n == null || (n.Kind != .Construct && n.Kind != .Local))
				return;
			n.SetSubjectTypeText(type);
			n.FindOutput("object")?.SetTypeText(type);
			g.Version++;
		}

		public static Node Delete(Graph g) => Create(g, .Delete);
		public static Node Defer(Graph g) => Create(g, .Defer);
		public static Node DeferDelete(Graph g) => Create(g, .DeferDelete);
		public static Node Scope(Graph g) => Create(g, .Scope);
		public static Node Try(Graph g) => Create(g, .Try);
		public static Node Fatal(Graph g) => Create(g, .Fatal);

		public static Node ResultMatch(Graph g, StringView resultType = "")
		{
			Node n = Create(g, .ResultMatch);
			n.FindInput("result").SetTypeText(resultType);
			SetResultPayloadType(n);
			return n;
		}

		/// The Value / Error pins' types from the Result pin's `Result<T, E>`.
		public static void SetResultPayloadType(Node n)
		{
			let r = n.FindInput("result");
			if (r == null || r.Type == null || r.Type.Kind != .Named || r.Type.ShortName != "Result" || r.Type.Args == null)
				return;
			if (r.Type.Args.Count > 0)
				n.FindOutput("value")?.SetType(r.Type.Args[0].Clone());
			if (r.Type.Args.Count > 1)
				n.FindOutput("error")?.SetType(r.Type.Args[1].Clone());
		}

		/// A Return in a function that returns `returnType` starts with that type's default.
		public static Node Return(Graph g, StringView returnType)
		{
			Node n = Create(g, .Return);
			let v = n.FindInput("value");
			// A function that returns nothing: `void` (nothing can be wired in; the pin is hidden).
			v.SetTypeText(returnType.IsEmpty ? "void" : returnType);
			ReturnDefault(g.Language, returnType, v.Default);
			return n;
		}

		public static void ReturnDefault(LanguageContext lang, StringView returnType, String outValue)
		{
			var t = returnType;
			t.Trim();
			if (t.IsEmpty || t == "void")
				return;
			let types = LanguageContext.TypesOf(lang);
			if (types != null)
				types.DefaultValue(t, outValue);
		}

		/// Splits a parameter list `int a, float b` into (name, type) pairs.
		public static void SplitParams(StringView inner, List<(StringView name, StringView type)> outParams)
		{
			int depth = 0;
			int start = 0;
			for (int i = 0; i <= inner.Length; i++)
			{
				bool end = i == inner.Length;
				if (!end)
				{
					let c = inner[i];
					if (c == '<' || c == '(' || c == '[')
						depth++;
					else if (c == '>' || c == ')' || c == ']')
						depth--;
					if (c != ',' || depth != 0)
						continue;
				}
				var part = inner.Substring(start, i - start);
				part.Trim();
				start = i + 1;
				if (part.IsEmpty)
					continue;
				int eq = part.IndexOf('=');
				if (eq >= 0)
				{
					part = part.Substring(0, eq);
					part.Trim();
				}
				int s = part.Length;
				while (s > 0 && (part[s - 1].IsLetterOrDigit || part[s - 1] == '_'))
					s--;
				var name = part.Substring(s);
				var type = part.Substring(0, s);
				type.Trim();
				if (type.IsEmpty)
				{
					type = name;
					name = "";
				}
				outParams.Add((name, type));
			}
		}

		// ------------------------------------------------------------------ variables

		/// A new local variable of the function (a `local` record). Null without a member.
		public static LocalDecl AddLocal(Graph g, StringView name, StringView type, StringView init = "")
		{
			if (g.Member == null)
				return null;
			LocalDecl l = new .();
			l.Name.Set(name);
			l.Type = type.IsEmpty ? null : TypeRef.Parse(type);
			if (!init.IsEmpty)
				l.Init = new String(init);
			g.Member.Locals.Add(l);
			g.Version++;
			return l;
		}

		/// A variable name: a bare name is a field of the own type (`this.name`) unless it is a
		/// local or parameter of the function.
		public static void SubjectOf(Graph g, StringView name, String outSubject)
		{
			if (name.Contains('.') || name.Contains(':'))
			{
				outSubject.Append(name);
				return;
			}
			if (g.FindLocal(name) != null)
				outSubject.AppendF("local:{}", name);
			else if (g.Member != null && g.Member.FindParam(name) != null)
				outSubject.AppendF("param:{}", name);
			else
				outSubject.AppendF("this.{}", name);
		}

		/// Set `<variable>` (`op`: `=` or a compound `+=` ...).
		public static Node Set(Graph g, StringView variable, StringView typeName, StringView op = "=")
		{
			String subject = scope .();
			SubjectOf(g, variable, subject);
			Node n = g.AddNode(.Set);
			n.Text.Set(subject);
			if (!op.IsEmpty && op != "=")
				n.SetSetting("op", op);
			Shape(g, n);
			n.FindInput("value").SetTypeText(typeName);
			n.Result?.SetTypeText(typeName);
			return n;
		}

		public static Node Get(Graph g, StringView variable, StringView typeName)
		{
			String subject = scope .();
			SubjectOf(g, variable, subject);
			Node n = Create(g, .Get, subject);
			n.Result.SetTypeText(typeName);
			return n;
		}

		/// A Get of a member through a wired Receiver (`Type.name`; the type unknown: `?`).
		public static Node GetMember(Graph g, StringView name, StringView ownerType = "")
		{
			String subject = scope $"{(ownerType.IsEmpty ? "this" : ownerType)}.{name}";
			return Create(g, .Get, subject);
		}

		// ------------------------------------------------------------------ values

		public static Node Operator(Graph g, StringView op) => Create(g, .Operator, op);
		public static Node Select(Graph g) => Create(g, .Select);
		public static Node Index(Graph g) => Create(g, .Index);
		/// Make `T`: one input per field (named by the field), the struct out.
		public static Node Make(Graph g, StringView type, Span<StringView> fieldNames = default, Span<StringView> fieldTypes = default)
		{
			Node n = Create(g, .Make, type);
			for (int i < fieldNames.Length)
				if (n.FindInput(fieldNames[i]) == null) // a vector's lanes are there already
					In(g, n, fieldNames[i], fieldNames[i], (i < fieldTypes.Length) ? fieldTypes[i] : default, .Arg);
			return n;
		}

		/// Break `T`: the struct in, one output per field.
		public static Node BreakStruct(Graph g, StringView type, Span<StringView> fieldNames = default, Span<StringView> fieldTypes = default)
		{
			Node n = Create(g, .BreakStruct, type);
			for (int i < fieldNames.Length)
				if (n.FindOutput(fieldNames[i]) == null)
					Out(g, n, fieldNames[i], fieldNames[i], (i < fieldTypes.Length) ? fieldTypes[i] : default, .Result);
			return n;
		}

		/// Swizzle by `lanes` (`zyx`; a default when empty): `value` -> `result`.
		public static Node Swizzle(Graph g, StringView lanes = default)
		{
			Node n = g.AddNode(.Swizzle);
			n.SetSetting(VectorNodes.LanesKey, lanes.IsEmpty ? VectorNodes.DefaultSwizzle(0, .. scope String()) : lanes);
			Shape(g, n);
			return n;
		}

		/// Shuffle by `mask` (`0 4 1 5`; a default when empty): `a`, `b` -> `result`.
		public static Node Shuffle(Graph g, StringView mask = default)
		{
			Node n = g.AddNode(.Shuffle);
			n.SetSetting(VectorNodes.MaskKey, mask.IsEmpty ? VectorNodes.DefaultMask(0, .. scope String()) : mask);
			Shape(g, n);
			return n;
		}

		/// Make Case `Enum.Case`: one input per payload field, the enum value out.
		public static Node MakeCase(Graph g, StringView enumCase, Span<StringView> payloadNames = default, Span<StringView> payloadTypes = default)
		{
			Node n = Create(g, .MakeCase, enumCase);
			for (int i < payloadNames.Length)
				In(g, n, payloadNames[i], payloadNames[i], (i < payloadTypes.Length) ? payloadTypes[i] : default, .Arg);
			return n;
		}

		/// Is Case `Enum.Case`: the enum value in, `bool` and the payload fields out.
		public static Node IsCase(Graph g, StringView enumCase, Span<StringView> payloadNames = default, Span<StringView> payloadTypes = default)
		{
			Node n = Create(g, .IsCase, enumCase);
			for (int i < payloadNames.Length)
				Out(g, n, payloadNames[i], payloadNames[i], (i < payloadTypes.Length) ? payloadTypes[i] : default, .Result);
			return n;
		}

		/// Cast To `type`; `checked`: the class Cast with Succeeded / Failed flow outputs.
		public static Node Cast(Graph g, StringView type, bool isChecked = false)
		{
			Node n = g.AddNode(.Cast);
			n.SetSubjectTypeText(type);
			if (isChecked)
			{
				n.SetSetting("kind", "class");
				n.SetSetting("checked", "");
			}
			Shape(g, n);
			return n;
		}

		/// Makes a Cast cast to `type`: the subject and the Result pin change together.
		public static void SetCastType(Graph g, Node n, StringView type)
		{
			if (n == null || n.Kind != .Cast)
				return;
			n.SetSubjectTypeText(type);
			let r = n.Result;
			if (r != null)
			{
				DeleteAndNullify!(r.WildcardType);
				r.SetTypeText(type);
				r.Label.Clear();
				if (!type.IsEmpty)
				{
					r.Label.Append("As ");
					Node.ShortTypeName(type, r.Label);
				}
			}
			g.Version++;
		}

		public static Node Literal(Graph g, StringView type, StringView value)
		{
			Node n = g.AddNode(.Literal);
			if (!type.IsEmpty)
				n.SetSetting("type", type);
			n.SetSetting("value", value);
			Shape(g, n);
			return n;
		}

		/// A Lambda value (its body is a nested Sheet `lambda:<id>`, made by the document).
		public static Node Lambda(Graph g) => Create(g, .Lambda);

		/// A Lambda's type (`set type`: a delegate type, `delegate:R(A)` or `function:R(A)`); its
		/// Delegate pin takes it too.
		public static void SetLambdaType(Graph g, Node n, StringView type)
		{
			if (type.IsEmpty)
				n.RemoveSetting("type");
			else
				n.SetSetting("type", type);
			n.FindOutput("value")?.SetTypeText(type);
			g.Version++;
		}

		/// A Lambda's input names (`set inputs a b`; none: the line goes).
		public static void SetLambdaInputs(Node n, Span<StringView> names)
		{
			String text = scope .();
			for (let name in names)
			{
				if (!text.IsEmpty)
					text.Append(' ');
				text.Append(name);
			}
			if (text.IsEmpty)
				n.RemoveSetting("inputs");
			else
				n.SetSetting("inputs", text);
		}

		/// A Lambda's Allocation (`set alloc local|construct`; "" or `pointer` = none, a function
		/// pointer, which keeps no capture lines). The flow pins follow (allocation is a flow node).
		public static void SetLambdaAlloc(Graph g, Node n, StringView alloc)
		{
			if (alloc.IsEmpty || alloc == "pointer")
			{
				n.RemoveSetting("alloc");
				for (int i = n.Settings.Count - 1; i >= 0; i--)
					if (n.Settings[i].Key == "capture" && !n.Settings[i].IsSet)
					{
						delete n.Settings[i];
						n.Settings.RemoveAt(i);
					}
			}
			else
				n.SetSetting("alloc", alloc);
			Reshape(g, n);
			FlowPinsFirst(n);
		}

		/// Flow pins above value pins on each side (Reshape adds the flow pins of a node that
		/// becomes a flow node after its value pins).
		static void FlowPinsFirst(Node n)
		{
			for (int side < 2)
			{
				let pins = (side == 0) ? n.Inputs : n.Outputs;
				List<Pin> order = scope .();
				for (let p in pins)
					if (p.Kind == .Flow)
						order.Add(p);
				for (let p in pins)
					if (p.Kind != .Flow)
						order.Add(p);
				pins.Clear();
				pins.AddRange(order);
			}
		}

		/// The `capture <name> ...` line of a Lambda (null when it has none).
		public static NodeSetting FindCapture(Node n, StringView name)
		{
			for (let s in n.Settings)
			{
				if (s.Key != "capture" || s.IsSet)
					continue;
				var parts = s.Value.Split(' ');
				if (parts.GetNext() case .Ok(let capName) && capName == name)
					return s;
			}
			return null;
		}

		/// How a Lambda holds a capture: `capture <name> by-ref`, or by value (the line goes; by
		/// value is what an unnamed capture is).
		public static void SetCaptureByRef(Graph g, Node n, StringView name, bool byRef)
		{
			let have = FindCapture(n, name);
			if (byRef)
			{
				if (have != null)
					have.Value.Set(scope $"{name} by-ref");
				else
				{
					NodeSetting s = new .();
					s.Key.Set("capture");
					s.Value.Set(scope $"{name} by-ref");
					s.IsSet = false;
					n.Settings.Add(s);
				}
			}
			else if (have != null)
			{
				n.Settings.Remove(have);
				delete have;
			}
			Reshape(g, n);
			FlowPinsFirst(n);
		}

		/// Bind Function: a delegate of `member` (a member reference).
		public static Node Bind(Graph g, StringView member) => Create(g, .Bind, member);

		/// A Math Expression: one input per free name, set from the expression by the editor.
		public static Node MathExpression(Graph g, StringView expr)
		{
			Node n = g.AddNode(.Math);
			n.SetSetting("expr", scope $"\"{expr}\"");
			Shape(g, n);
			return n;
		}
	}
}
