using System;
using System.Collections;
using Treadle.Model;
using Treadle.Graph;
using Treadle.Document;
using Treadle.Format;

namespace Treadle.Compiler
{
	extension Compilation
	{
		/// Bind (Compiler.md 1, 2): resolves every node's subject and every pin's type in one
		/// Sheet, infers value pin types through wires, picks overloads, records generic
		/// instantiations. Null when the Sheet has no member to bind against.
		public SheetResult BindSheet(SourceUnit u, Sheet s)
		{
			// An extension's Sheet is a member of the extended type (`this` is that type); names
			// resolve in the extension file's scope first; diagnostics name the extension's file.
			let ext = (u.Sym != null && u.Sym.Kind == .Extension) ? u.Sym : null;
			let t = (ext != null) ? ext.Extends : u.Sym;
			let m = MemberOf(t, s.Member);
			if (m == null)
				return null;
			SheetResult r = new .();
			r.Sheet = s;
			r.Unit = u;
			r.Type = t;
			r.Scope = ext;
			r.Member = m;
			// Split struct pins (Graph-Format.md 3.2): bound as the Make / Break they stand for, in a copy.
			r.Source = s.Graph;
			r.Expanded = SplitPins.Expand(s.Graph);
			r.Graph = r.Expanded ?? s.Graph;
			r.SiteType.Set(u.Sym.FullName);
			r.Site = .(r.SiteType, m.Id, s.Key, u.Path);
			Results[s] = r;
			ResultList.Add(r);
			SheetBinder b = scope .(this, r);
			b.Run();
			if (r.Expanded != null)
				SplitPins.CopyTypes(r.Expanded, s.Graph);
			return r;
		}

		/// The closure class of a Lambda node (Compiler.md 4, delegates): `<Owner>.$lambda_<node>`,
		/// a class derived from Core.Delegate whose fields are the captures. Made once per name.
		public TypeSym ClosureType(TypeSym owner, StringView node)
		{
			String name = scope $"{owner.FullName}.$lambda_{node}";
			if (Closures.TryGetValue(name, let have))
				return have;
			TypeSym t = new .();
			t.Name.AppendF("$lambda_{}", node);
			t.Namespace.Set(owner.FullName);
			t.FullName.Set(name);
			t.Kind = .Class;
			t.Project.Set(owner.Project);
			t.Self = Table.Named(t, default);
			Closures[new String(name)] = t;
			return t;
		}
	}

	/// Binds one Sheet.
	class SheetBinder
	{
		Compilation c;
		SheetResult r;
		TypeTable T;

		public this(Compilation comp, SheetResult result)
		{
			c = comp;
			r = result;
			T = c.Table;
		}

		// ------------------------------------------------------------------ reporting

		void Err(BNode n, StringView pin, StringView code, StringView message)
		{
			c.Diags.Add(.Error, .Bind, code, r.Site, (n != null) ? n.Key : "", pin, message);
			r.HasErrors = true;
		}

		void Warn(BNode n, StringView pin, StringView code, StringView message)
		{
			c.Diags.Add(.Warning, .Bind, code, r.Site, (n != null) ? n.Key : "", pin, message);
		}

		NameCtx Ctx(BNode n, StringView pin = "")
		{
			NameCtx nc = .(r.Type, r.Member, r.Site, (n != null) ? n.Key : "", pin);
			nc.Lookup = r.Scope;
			return nc;
		}

		mixin S(KType t)
		{
			TypeTable.Show(t, .. scope:mixin String())
		}

		// ------------------------------------------------------------------ driver

		public void Run()
		{
			let m = r.Member;
			let sheet = r.Sheet;
			r.MustBePure = (m.Pure && sheet.Role == .Body) || sheet.Role == .Get;
			r.UnsafeSheet = m.Unsafe;
			if (!m.Static && !r.Type.Static)
				r.This = r.Type.Self;
			switch (sheet.Role)
			{
			case .Get: r.Returns = m.Type ?? T.Error;
			case .Set: r.Returns = T.Void;
			case .Lambda: SetupLambda();
			case .Body: r.Returns = m.Returns ?? T.Void;
			}
			for (let n in r.Graph.Nodes)
			{
				BNode b = new .();
				b.Node = n;
				r.Nodes.Add(b);
				r.ByNode[n] = b;
				if (n.Kind == .Entry)
				{
					if (r.Entry != null)
						Err(b, "", "T2001", "a Sheet has one Entry node");
					else
						r.Entry = b;
				}
			}
			if (r.Entry == null)
				Err(null, "", "T2002", "the Sheet has no Entry node");
			for (let b in r.Nodes)
				Bind(b);
			if (r.IsLambda)
				NoteThisCapture();
			for (let b in r.Nodes)
				CheckPins(b);
			// The editor draws pin colours from these.
			for (let b in r.Nodes)
				ApplyPinTypes(b);
		}

		// ------------------------------------------------------------------ Lambda Sheets (Language.md 4.2)

		/// A Lambda Sheet: its node in the enclosing Sheet gives the type (`set type`), the inputs'
		/// names (`set inputs`) and how each capture is held (`capture <name> by-value|by-ref`).
		void SetupLambda()
		{
			r.Returns = T.Error;
			r.LambdaType = T.Error;
			for (let s in r.Unit.Doc.Sheets)
			{
				if (s == r.Sheet || s.Member != r.Sheet.Member)
					continue;
				for (let n in s.Graph.Nodes)
					if (n.Kind == .Lambda && n.Key == r.Sheet.LambdaNode)
					{
						r.LambdaNode = n;
						r.LambdaOwner = s;
					}
			}
			if (r.LambdaNode == null)
			{
				Err(null, "", "T2250", "the Lambda node of this Sheet is gone: delete the Sheet (or undo)");
				return;
			}
			let typeText = r.LambdaNode.GetSetting("type");
			if (typeText.IsEmpty)
				return; // the Lambda node reports it
			let tr = TypeRef.Parse(typeText);
			defer delete tr;
			NameCtx nc = Ctx(null);
			nc.Quiet = true;
			let lt = c.Resolve(tr, nc);
			if (lt == null || (lt.Kind != .Delegate && lt.Kind != .Function))
				return;
			r.LambdaType = lt;
			r.Returns = lt.Element;
			List<StringView> names = scope .();
			for (var w in r.LambdaNode.GetSetting("inputs").Split(' '))
			{
				w.Trim();
				if (!w.IsEmpty)
					names.Add(w);
			}
			for (int i < lt.Args.Count)
			{
				ParamSym p = new .();
				if (i < names.Count)
					p.Name.Set(names[i]);
				else
					p.Name.AppendF("p{}", i);
				p.Type = lt.Args[i];
				p.Mode = .Value;
				r.LambdaParams.Add(p);
			}
		}

		/// A variable of the enclosing function the Lambda Sheet reads or writes (node `b`), or with
		/// no node one a Lambda inside this Sheet reads through it (chained, Language.md 4.2).
		Capture AddCapture(BNode b, Capture.Kind what, StringView name, KType type)
		{
			if (b != null)
				b.IsCapture = true;
			let have = r.FindCapture(what, name);
			if (have != null)
			{
				if (b != null)
					have.Chained = false;
				return have;
			}
			Capture cap = new .();
			cap.What = what;
			cap.Name.Set(name);
			cap.Type = type;
			cap.Chained = b == null;
			if (r.LambdaNode != null && what != .This)
				for (let s in r.LambdaNode.Settings)
				{
					if (s.Key != "capture" || s.IsSet)
						continue;
					var parts = s.Value.Split(' ');
					if (parts.GetNext() case .Ok(let capName) && capName == name)
						cap.ByRef = parts.GetNext() case .Ok(let mode) && mode == "by-ref";
				}
			r.Captures.Add(cap);
			return cap;
		}

		/// The Lambda Sheet this Lambda Sheet's node (or `of`'s) is in (null when its node is in a
		/// function's own Sheet): the outer Lambda, whose inputs a nested Lambda captures.
		SheetResult OuterLambda(SheetResult of = null)
		{
			let owner = (of ?? r).LambdaOwner;
			if (owner == null || owner.Role != .Lambda)
				return null;
			return c.ResultOf(owner) ?? c.BindSheet(r.Unit, owner);
		}

		/// `this` is captured when a node of the Lambda Sheet works on it.
		void NoteThisCapture()
		{
			if (r.This == null)
				return;
			for (let b in r.Nodes)
			{
				if (b.Node.Disabled)
					continue;
				let statefulOnThis = (NodeKinds.IsStateful(b.Kind) || b.Kind == .GateOpen || b.Kind == .GateClose || b.Kind == .GateToggle ||
					b.Kind == .ResetDoOnce || b.Kind == .ResetDoN || b.Kind == .ResetMultiGate) && b.Member != null && !b.StateStatic;
				if (b.Kind == .This || b.Kind == .Base || b.ReceiverIsThis || statefulOnThis)
				{
					AddCapture(b, .This, "this", r.This);
					b.IsCapture = false;
				}
			}
		}

		void ApplyPinTypes(BNode b)
		{
			for (let i in b.Ins)
				if (i.Pin != null && i.Type != null && !i.Type.IsError && i.Pin.Kind == .Value)
					i.Pin.SetTypeText(S!(i.Type));
			for (let o in b.Outs)
			{
				let p = b.Node.FindOutput(o.Name);
				if (p != null && o.Type != null && !o.Type.IsError && p.Kind == .Value)
					p.SetTypeText(S!(o.Type));
			}
		}

		// ------------------------------------------------------------------ sources

		BNode Bound(Node n)
		{
			let b = r.Get(n);
			if (b != null)
				Bind(b);
			return b;
		}

		/// The type wired into the node's input `pin` (null when unwired; Error on a cycle).
		KType InType(BNode n, StringView pin)
		{
			let p = n.Node.FindInput(pin);
			if (p == null)
				return null;
			let l = r.Graph.FindLinkTo(p);
			if (l == null)
				return null;
			let src = r.Get(l.From.Owner);
			if (src == null)
				return T.Error;
			if (src.State == 1)
			{
				Err(n, pin, "T2003", "the wires make a loop of values: a value cannot depend on itself (store it in a local)");
				return T.Error;
			}
			Bind(src);
			let o = src.FindOut(l.From.Name);
			if (o == null)
				return T.Error; // reported by CheckPins on the source
			return o.Type ?? T.Error;
		}

		/// The literal set on an unwired input (`in <pin> <token>`), or "".
		StringView Lit(BNode n, StringView pin)
		{
			let p = n.Node.FindInput(pin);
			if (p == null || r.Graph.IsLinked(p))
				return "";
			return PinLiteral(n, p);
		}

		/// An input's literal token; one that names a constant (`in count Rows`, `in step
		/// Game.Speed`) is the constant's folded value (Language.md 4.6).
		StringView PinLiteral(BNode n, Pin p)
		{
			if (p.Default.IsEmpty)
				return "";
			if (n.ConstPins != null && n.ConstPins.TryGetValueAlt(p.Name, let have))
				return have;
			let m = c.PinConst(p.Default, Ctx(n, p.Name), r.Type);
			if (m == null)
				return p.Default;
			if (n.ConstPins == null)
				n.ConstPins = new .();
			let value = new String(m.ConstValue);
			n.ConstPins[new String(p.Name)] = value;
			if (n.ConstRefs == null)
				n.ConstRefs = new .();
			n.ConstRefs.Add(m);
			return value;
		}

		/// What feeds an input: its wired type, else the type its literal has on its own.
		KType InOrLit(BNode n, StringView pin)
		{
			let t = InType(n, pin);
			if (t != null)
				return t;
			let lit = Lit(n, pin);
			if (!lit.IsEmpty)
				return Literals.TypeOf(lit, T);
			return null;
		}

		/// The node wired into an input (null when unwired).
		BNode SourceNode(BNode n, StringView pin)
		{
			let p = n.Node.FindInput(pin);
			if (p == null)
				return null;
			let l = r.Graph.FindLinkTo(p);
			return (l != null) ? r.Get(l.From.Owner) : null;
		}

		bool CanSee(MemberSym m)
		{
			let from = r.Type;
			switch (m.Access)
			{
			case .Unset, .Public: return true;
			case .Private: return m.Owner == from;
			case .Protected: return from.DerivesFrom(m.Owner) || m.Owner == from;
			case .Internal: return m.Project == (r.Scope ?? from).Project;
			}
		}

		void CheckAccess(BNode n, MemberSym m)
		{
			if (!CanSee(m))
			{
				String access = scope .();
				access.Append((m.Access == .Private) ? "private" : ((m.Access == .Protected) ? "protected" : "internal"));
				Err(n, "", "T2004", scope $"{m.Owner.Name}.{m.Name} is {access}: it is not visible from {r.Type.Name}");
			}
			if (m.Obsolete != null)
				Warn(n, "", "T2005", scope $"{m.Owner.Name}.{m.Name} is obsolete{(m.Obsolete.IsEmpty ? "" : ": ")}{m.Obsolete}");
		}

		// ------------------------------------------------------------------ bind

		void Bind(BNode b)
		{
			if (b.State != 0)
				return;
			b.State = 1;
			let n = b.Node;
			b.Flow = !n.IsPure;
			if (n.Disabled)
			{
				b.State = 2;
				return;
			}
			switch (n.Kind)
			{
			case .Entry: BindEntry(b);
			case .Return: BindReturn(b);
			case .ChainCtor: BindChain(b);
			case .Call: BindCall(b);
			case .Get, .Set: BindVariable(b);
			case .This:
				b.Flow = false;
				if (r.This == null)
					Err(b, "value", "T2010", "This: a static function has no `this`");
				b.AddOut("value", r.This ?? T.Error);
			case .Base:
				b.Flow = false;
				KType bt = (r.This != null) ? T.BaseOf(r.This) : null;
				if (r.This == null)
					Err(b, "value", "T2010", "Base: a static function has no `this`");
				else if (bt == null)
					Err(b, "value", "T2011", scope $"Base: {r.Type.Name} has no base class");
				b.AddOut("value", bt ?? T.Error);
			case .Construct, .Local: BindConstruct(b);
			case .Delete, .DeferDelete:
				b.Flow = true;
				b.AddIn("in", null);
				let ot = InType(b, "object");
				let spec = b.AddIn("object", ot ?? T.Error, false, "Object");
				if (ot != null && !ot.IsError && !Deletable(ot) && !NarrowedDeletable(ot))
				{
					Err(b, "object", "T2020", scope $"Object: Delete takes a class object, an array or a delegate, not a {S!(ot)}");
					spec.Type = T.Error;
				}
				if (n.Kind == .Delete)
					BindAllocator(b, ot);
				b.AddFlowOut("then");
			case .Defer:
				b.Flow = true;
				b.AddIn("in", null);
				b.AddFlowOut("deferred");
				b.AddFlowOut("done");
			case .Branch:
				b.Flow = true;
				b.AddIn("in", null);
				b.AddIn("condition", T.Bool, false, "Condition");
				b.AddFlowOut("true");
				b.AddFlowOut("false");
			case .Sequence:
				b.Flow = true;
				b.AddIn("in", null);
				int count = 2;
				if (int.Parse(n.GetSetting("count")) case .Ok(let cnt))
					count = Math.Clamp(cnt, 1, 64);
				for (int i < count)
					b.AddFlowOut(scope $"then{i}");
			case .While, .DoWhile:
				b.Flow = true;
				b.AddIn("in", null);
				b.AddIn("condition", T.Bool, false, "Condition");
				b.AddFlowOut("body");
				b.AddFlowOut("done");
			case .For: BindFor(b);
			case .ForEach: BindForEach(b);
			case .Break, .Continue:
				b.Flow = true;
				b.AddIn("in", null);
			case .Switch: BindSwitch(b);
			case .Scope:
				b.Flow = true;
				b.AddIn("in", null);
				b.AddFlowOut("body");
				b.AddFlowOut("done");
			case .Gate, .DoOnce, .DoN, .FlipFlop, .MultiGate, .GateOpen, .GateClose, .GateToggle, .ResetDoOnce, .ResetDoN, .ResetMultiGate:
				BindStateful(b);
			case .ResultMatch, .Try: BindResult(b);
			case .Fatal:
				b.Flow = true;
				b.AddIn("in", null);
				b.AddIn("message", (T.StringViewSym != null) ? T.StringViewSym.Self : T.Error, false, "Message");
			case .Operator: BindOperator(b);
			case .Select: BindSelect(b);
			case .Cast: BindCast(b);
			case .Make, .BreakStruct: BindMake(b);
			case .MakeCase, .IsCase: BindCase(b);
			case .Index: BindIndex(b);
			case .Literal:
				b.Flow = false;
				let ltr = TypeRef.Parse(n.GetSetting("type"));
				defer delete ltr;
				let lt = c.Resolve(ltr, Ctx(b));
				StringView value = n.GetSetting("value");
				KType vt = lt ?? Literals.TypeOf(value, T) ?? T.Error;
				String why = scope .();
				if (!Literals.Fits(value, vt, T, why))
					Err(b, "value", "T2030", scope $"Literal: {why}");
				b.AddOut("value", vt);
			case .Bind: BindDelegate(b);
			case .Lambda: BindLambda(b);
			case .Invoke: BindInvoke(b);
			case .Math: BindMath(b);
			case .Intrinsic:
				if (!r.Type.IsCore)
					Err(b, "", "T2032", "Intrinsic nodes belong to the core library");
				b.Unsupported = true;
			case .Unknown:
				// Swizzle / Shuffle (BindVector.bf), read as Unknown kinds here; where they are node kinds of
				// their own, their case calls the same two binders
				if (VectorRules.IsSwizzleNode(n))
					BindSwizzle(b);
				else if (VectorRules.IsShuffleNode(n))
					BindShuffle(b);
				else
				{
					Err(b, "", "T2033", scope $"'{n.KindWord}' is a node kind of a newer format: it cannot be compiled");
					b.Unsupported = true;
				}
			case .Swizzle:
				BindSwizzle(b); // the editor's vector nodes (SIMD-and-Vectors.md 1.9; BindVector.bf)
			case .Shuffle:
				BindShuffle(b);
			}
			b.State = 2;
		}

		/// A type parameter the member's own narrowing makes deletable (`generic T delete`).
		bool NarrowedDeletable(KType t)
		{
			if (t.Kind != .Param || r.Member == null)
				return false;
			let n = r.Member.FindNarrowing(t.Param);
			return n != null && (n.IsDelete || n.IsClass);
		}

		static bool Deletable(KType t)
		{
			if (t.IsError)
				return true;
			if (t.Kind == .Param)
				return t.Param.IsDelete || t.Param.IsClass;
			return t.IsReference && t.Kind != .Null;
		}

		// ------------------------------------------------------------------ function boundaries

		void BindEntry(BNode b)
		{
			b.Flow = true;
			b.AddFlowOut("then");
			let m = r.Member;
			if (r.IsLambda)
			{
				for (let p in r.LambdaParams)
					b.AddOut(p.Name, p.Type);
				return;
			}
			for (let p in m.Params)
				b.AddOut(p.Name, p.Type);
			if (r.Sheet.Role == .Set)
				b.AddOut("value", m.Type ?? T.Error);
		}

		void BindReturn(BNode b)
		{
			b.Flow = true;
			b.AddIn("in", null);
			let ret = r.Returns;
			if (ret.IsVoid)
			{
				let vp = b.Node.FindInput("value");
				if (vp != null && (r.Graph.IsLinked(vp) || !vp.Default.IsEmpty))
					Err(b, "value", "T2040", scope $"Return Value: {r.Member.Name} returns nothing");
			}
			else
				b.AddIn("value", ret, false, "Return Value");
			if (r.Sheet.Role == .Body)
				for (let o in r.Member.Outs)
					b.AddIn(o.Name, o.Type, false, o.Name);
		}

		/// Picks a constructor of `inst` by `set ctor (Types)` or by the argument pins' names.
		MemberSym PickCtor(BNode b, KType inst, StringView setting, Dictionary<GenericParamSym, KType> map, bool report = true)
		{
			List<MemberSym> ctors = scope .();
			inst.Sym.GetCtors(ctors);
			if (!setting.IsEmpty)
			{
				let wanted = MemberRef.Parse(scope $"x{setting}");
				defer delete wanted;
				List<KType> types = scope .();
				for (let pt in wanted.ParamTypes)
					types.Add(c.Resolve(pt, Ctx(b)) ?? T.Error);
				for (let k in ctors)
				{
					if (k.Params.Count != types.Count)
						continue;
					bool same = true;
					for (int i < types.Count)
						same &= T.Subst(k.Params[i].Type, map) == types[i] || types[i].IsError;
					if (same)
						return k;
				}
				if (ctors.IsEmpty && types.IsEmpty)
					return null;
				if (report)
					Err(b, "", "T2041", scope $"{S!(inst)} has no constructor {setting}");
				return null;
			}
			if (ctors.IsEmpty)
				return null;
			// By the argument pins the node has.
			List<StringView> args = scope .();
			for (let p in b.Node.Inputs)
				if (p.Kind == .Value && p.Name != "count" && p.Name != "allocator")
					args.Add(p.Name);
			MemberSym best = null;
			int bestScore = int.MinValue;
			bool tie = false;
			for (let k in ctors)
			{
				int score = ScoreArgs(b, k, map, args);
				if (score > bestScore)
				{
					best = k;
					bestScore = score;
					tie = false;
				}
				else if (score == bestScore)
					tie = true;
			}
			if (tie && report)
				Err(b, "", "T2042", scope $"several constructors of {S!(inst)} fit: pick one in Properties (set ctor)");
			if (bestScore < -50 && report)
				Err(b, "", "T2043", scope $"no constructor of {S!(inst)} takes these inputs");
			return best;
		}

		/// The overload score (Compiler.md 2): exact 4, implicit 2, generic 1,
		/// refused -100, an unknown argument name -100, a missing required argument -20.
		int ScoreArgs(BNode b, MemberSym f, Dictionary<GenericParamSym, KType> map, List<StringView> args)
		{
			int score = 0;
			for (let a in args)
			{
				let p = f.FindParam(a);
				if (p == null)
				{
					score -= 100;
					continue;
				}
				if (p.IsOut)
					continue;
				let want = T.Subst(p.Type, map);
				let have = InType(b, a);
				// A generic parameter takes any wired value or literal (its type is inferred after the pick).
				if (TypeTable.IsOpen(want) && (have != null || !Lit(b, a).IsEmpty))
				{
					score += 1;
					continue;
				}
				if (have == null)
				{
					let lit = Lit(b, a);
					if (lit.IsEmpty)
						continue;
					score += Literals.Fits(lit, want, T, scope .()) ? ((Literals.TypeOf(lit, T) == want) ? 4 : 3) : -100;
					continue;
				}
				if (TypeTable.IsOpen(want))
				{
					score += 1;
					continue;
				}
				switch (T.CanConvert(have, want))
				{
				case .Exact: score += 4;
				case .Implicit: score += 2;
				case .Refused: score -= 100;
				}
			}
			for (let p in f.Params)
			{
				if (p.Default != null)
					continue;
				bool given = false;
				for (let a in args)
					if (a == p.Name)
						given = true;
				if (!given)
					score -= 20;
			}
			// Tie-break (Compiler.md 2, Overloads): an integer given to a `float` where a `double` overload
			// fits as well goes to the double one (Math.Sqrt(int) stays double next to Sqrt(float)).
			score *= 2;
			for (let a in args)
			{
				let p = f.FindParam(a);
				if (p == null || p.IsOut || T.Subst(p.Type, map) != T.Float)
					continue;
				let have = InType(b, a);
				let lit = Lit(b, a);
				if ((have != null && have.IsInteger) || (have == null && !lit.IsEmpty && Literals.TypeOf(lit, T)?.IsInteger == true))
					score -= 1;
			}
			return score;
		}

		void BindChain(BNode b)
		{
			b.Flow = false;
			let n = b.Node;
			let m = r.Member;
			if (m.Kind != .Ctor)
			{
				Err(b, "", "T2044", "a Base / This Constructor node belongs in a constructor's Sheet");
				return;
			}
			KType target = null;
			if (n.Text == "base")
			{
				target = T.BaseOf(r.Type.Self);
				if (m.Chain != .Base)
					Warn(b, "", "T2045", "the constructor does not say `chain base`; the node is used anyway");
			}
			else if (n.Text == "this")
				target = r.Type.Self;
			else
				Err(b, "", "T2046", scope $"'{n.Text}': a constructor chains to base or this");
			if (target == null || target.IsError)
				return;
			Dictionary<GenericParamSym, KType> map = scope .();
			T.MapOf(target, map);
			let k = PickCtor(b, target, n.GetSetting("ctor"), map);
			if (k == null)
				return;
			if (k == m)
				Err(b, "", "T2047", "a constructor cannot chain to itself");
			b.Member = k;
			b.Owner = target;
			for (let p in k.Params)
				b.AddIn(p.Name, T.Subst(p.Type, map), p.Default != null).IsRef = p.IsRef;
		}

		// ------------------------------------------------------------------ calls

		/// The functions named `name` of `inst` and its bases (interfaces: and their bases), each
		/// with the instance it was found in.
		void FindFunctions(KType inst, StringView name, List<(MemberSym m, KType inst)> outList, int depth = 0)
		{
			if (inst == null || inst.Kind != .Named || depth > 32)
				return;
			for (let m in inst.Sym.Members)
			{
				if ((m.Kind != .Function && m.Kind != .Operator) || m.Name != name)
					continue;
				// A derived override hides the base's slot.
				bool hidden = false;
				for (let e in outList)
					if (e.m.VSlot >= 0 && e.m.VSlot == m.VSlot && e.m.Name == m.Name)
						hidden = true;
				if (!hidden)
					outList.Add((m, inst));
			}
			if (inst.Sym.Kind == .Interface)
			{
				List<KType> bases = scope .();
				T.InterfacesOf(inst, bases);
				for (let i in bases)
					FindFunctions(i, name, outList, depth + 1);
			}
			else
				FindFunctions(T.BaseOf(inst), name, outList, depth + 1);
		}

		/// The instance of `sym` in the class / interface chain of `t` (Pair<int,float> for a
		/// Receiver of that type when the call names `Core.Pair`).
		KType InstanceIn(KType t, TypeSym sym, int depth = 0)
		{
			if (t == null || t.Kind != .Named || depth > 32)
				return null;
			if (t.Sym == sym)
				return t;
			let b = InstanceIn(T.BaseOf(t), sym, depth + 1);
			if (b != null)
				return b;
			List<KType> ifaces = scope .();
			T.InterfacesOf(t, ifaces);
			for (let i in ifaces)
			{
				let x = InstanceIn(i, sym, depth + 1);
				if (x != null)
					return x;
			}
			return null;
		}

		/// The Receiver of a member node: wired (checked against `owner`) or `this`. Adds the
		/// Receiver input. Returns the owner instance to use (generic arguments from the wired
		/// Receiver when the reference named the type without them).
		KType BindReceiver(BNode b, MemberSym m, KType owner, bool ownerNamedOpen, bool allowThis)
		{
			let recvPin = b.Node.FindInput("receiver");
			let wired = recvPin != null && r.Graph.IsLinked(recvPin);
			if (!m.IsInstance)
			{
				if (wired)
					Err(b, "receiver", "T2050", scope $"Receiver: {m.Owner.Name}.{m.Name} is static: it has no Receiver");
				return owner;
			}
			var owner;
			if (wired)
			{
				let rt = InType(b, "receiver");
				let src = SourceNode(b, "receiver");
				if (src != null && src.Kind == .Base)
					b.ReceiverIsBase = true;
				if (rt != null && !rt.IsError && ownerNamedOpen)
				{
					let inst = InstanceIn(rt, owner.Sym);
					if (inst != null)
						owner = inst;
				}
				b.AddIn("receiver", owner, false, "Receiver").IsReceiver = true;
				return owner;
			}
			if (allowThis && r.This != null && InstanceIn(r.This, m.Owner) != null)
			{
				b.ReceiverIsThis = true;
				let inst = InstanceIn(r.This, owner.Sym);
				let spec = b.AddIn("receiver", inst ?? owner, true, "Receiver");
				spec.IsReceiver = true;
				return inst ?? owner;
			}
			if (allowThis && r.This == null && InstanceIn(r.Type.Self, m.Owner) != null)
				Err(b, "receiver", "T2051", scope $"Receiver: {r.Member.Name} is static, so there is no `this` for {m.Name}: wire a Receiver");
			else
				Err(b, "receiver", "T2052", scope $"Receiver: {m.Name} needs the {m.Owner.Name} object it works on: wire it");
			b.AddIn("receiver", owner, true, "Receiver").IsReceiver = true;
			return owner;
		}

		/// Resolves a member reference's owner: `this.` is the own type, `Type.` a named type.
		/// `open`: the type was named without its generic arguments.
		KType OwnerOf(BNode b, MemberRef mr, out bool open)
		{
			open = false;
			if (mr.Owner == .This)
				return r.Type.Self;
			if (mr.Type == null)
				return null;
			let tr = mr.Type;
			if (tr.Kind == .Named && (tr.Args == null || tr.Args.IsEmpty) && !tr.Name.IsEmpty)
			{
				List<TypeSym> amb = scope .();
				let sym = c.LookupType(tr.Name, Ctx(b), amb);
				if (sym != null && sym.IsGeneric && amb.Count <= 1)
				{
					open = sym != r.Type;
					return sym.Self;
				}
			}
			return c.Resolve(tr, Ctx(b));
		}

		// ------------------------------------------------------------------ events (Language.md 4, Event)

		static EventOp EventOpOf(StringView name)
		{
			switch (name)
			{
			case "Add": return .Add;
			case "Remove": return .Remove;
			case "Invoke": return .Invoke;
			case "Clear": return .Clear;
			case "Count": return .Count;
			default: return .None;
			}
		}

		/// A Call whose subject is `<owner>.<event>.<op>` (`this.OnHit.Add`, `Game.Gun.OnFired.Invoke`):
		/// one of an event's nodes. False when the subject names no event (an ordinary Call).
		bool TryBindEvent(BNode b, MemberRef mr)
		{
			let op = EventOpOf(mr.Name);
			if (op == .None || mr.Owner != .Type || mr.Type == null || mr.Type.Kind != .Named || (mr.Type.Args != null && !mr.Type.Args.IsEmpty))
				return false;
			StringView full = mr.Type.Name;
			let dot = full.LastIndexOf('.');
			if (dot <= 0)
				return false;
			StringView ownerText = full.Substring(0, dot);
			StringView eventName = full.Substring(dot + 1);
			KType owner = null;
			bool open = false;
			let isThis = ownerText == "this";
			if (isThis)
				owner = r.Type.Self;
			else
			{
				var nc = Ctx(b);
				nc.Quiet = true;
				let tr = TypeRef.Parse(ownerText);
				defer delete tr;
				if (tr.Kind == .Named && (tr.Args == null || tr.Args.IsEmpty))
				{
					List<TypeSym> amb = scope .();
					let sym = c.LookupType(tr.Name, nc, amb);
					if (sym != null && sym.IsGeneric && amb.Count <= 1)
					{
						open = sym != r.Type;
						owner = sym.Self;
					}
				}
				if (owner == null)
					owner = c.Resolve(tr, nc);
			}
			if (owner == null || owner.IsError || owner.Kind != .Named)
				return false;
			let (m, inst) = FindVariable(owner, eventName);
			if (m == null || m.EventOf == null)
				return false;
			BindEvent(b, m, inst, op, open, isThis);
			return true;
		}

		/// An event's node: Add / Remove (`handler`: a delegate the event then owns; Remove gives
		/// whether it was there), Invoke (`arg0`, `arg1`, ...: every handler in the order they were
		/// added), Clear (deletes every handler), Count (a value node). The Receiver is the object
		/// that has the event (unwired: `this`).
		void BindEvent(BNode b, MemberSym m, KType inst, EventOp op, bool open, bool isThis)
		{
			b.Member = m;
			b.EventOp = op;
			CheckAccess(b, m);
			let usedInst = BindReceiver(b, m, inst, open, isThis || r.Type.DerivesFrom(m.Owner));
			b.Owner = usedInst;
			b.Map = new .();
			T.MapOf(usedInst, b.Map);
			let d = T.Subst(m.EventOf, b.Map);
			// Every node of an event but Count changes or runs something: a flow node.
			if (op != .Count)
				b.Flow = true;
			if (b.Flow)
			{
				b.AddIn("in", null);
				b.AddFlowOut("then");
			}
			switch (op)
			{
			case .Add, .Remove:
				b.AddIn("handler", d, false, "Handler");
				if (op == .Remove)
					b.AddOut("result", T.Bool);
				InType(b, "handler");
				let src = SourceNode(b, "handler");
				if (op == .Add && src != null && (src.Kind == .Bind || src.Kind == .Lambda) && src.Alloc == .Local)
					Err(b, "handler", "T2216", scope $"Handler: the event owns its handlers and deletes them, but a Local delegate is freed when its region ends: make it with Allocation construct");
			case .Invoke:
				List<StringView> names = scope .();
				for (let p in b.Node.Inputs)
					if (p.Kind == .Value && p.Name != "receiver")
						names.Add(p.Name);
				SortArgNames(names, "arg");
				int i = 0;
				for (let name in names)
				{
					if (i < d.Args.Count)
						b.AddIn(name, d.Args[i], false, name);
					else
						Err(b, name, "T2201", scope $"the handlers of {m.Name} take {d.Args.Count} inputs");
					i++;
				}
				for (int k = i; k < d.Args.Count; k++)
					b.AddIn(scope $"arg{k}", d.Args[k], false, scope $"arg{k}");
			case .Count:
				b.AddOut("result", T.Int);
			default:
			}
		}

		void BindCall(BNode b)
		{
			let n = b.Node;
			let mr = MemberRef.Parse(n.Text);
			defer delete mr;
			if (mr.Owner == .Local || mr.Owner == .Param)
			{
				Err(b, "", "T2060", scope $"'{n.Text}' is a variable, not a function: use Get or Invoke");
				return;
			}
			if (TryBindEvent(b, mr))
				return;
			if (TryBindVectorCall(b, mr)) // BindVector.bf: Core.Vector, Core.Math on vectors
				return;
			bool open = false;
			let owner = OwnerOf(b, mr, out open);
			if (owner == null || owner.IsError)
			{
				if (owner == null)
					Err(b, "", "T2061", scope $"'{n.Text}' names no function");
				AddLooseFlow(b);
				return;
			}
			if (owner.Kind != .Named)
			{
				Err(b, "", "T2062", scope $"{S!(owner)} has no functions");
				AddLooseFlow(b);
				return;
			}
			List<(MemberSym m, KType inst)> cands = scope .();
			FindFunctions(owner, mr.Name, cands);
			if (cands.IsEmpty)
			{
				Err(b, "", "T2063", scope $"{S!(owner)} has no function {mr.Name}");
				AddLooseFlow(b);
				return;
			}
			// Argument pins the node has (inputs other than the flow and the Receiver, outputs
			// that are not the result).
			List<StringView> args = scope .();
			for (let p in n.Inputs)
				if (p.Kind == .Value && p.Name != "receiver")
					args.Add(p.Name);
			(MemberSym m, KType inst) best = (null, null);
			if (mr.HasSignature)
			{
				List<KType> sig = scope .();
				for (let pt in mr.ParamTypes)
					sig.Add(c.Resolve(pt, Ctx(b)) ?? T.Error);
				for (let cand in cands)
				{
					let f = cand.m;
					if (f.Params.Count != sig.Count)
						continue;
					Dictionary<GenericParamSym, KType> map = scope .();
					T.MapOf(cand.inst, map);
					bool same = true;
					for (int i < sig.Count)
					{
						let pt = f.Params[i].Type;
						same &= sig[i].IsError || pt == sig[i] || T.Subst(pt, map) == sig[i] || TypeTable.IsOpen(pt);
					}
					if (same)
					{
						best = cand;
						break;
					}
				}
				if (best.m == null)
				{
					String sigText = scope .();
					mr.ToString(sigText);
					Err(b, "", "T2064", scope $"{S!(owner)} has no function {mr.Name} with the parameters {sigText.Substring(sigText.IndexOf('('))}");
					AddLooseFlow(b);
					return;
				}
			}
			else
			{
				int bestScore = int.MinValue;
				bool tie = false;
				for (let cand in cands)
				{
					Dictionary<GenericParamSym, KType> map = scope .();
					T.MapOf(cand.inst, map);
					let score = ScoreArgs(b, cand.m, map, args);
					if (score > bestScore)
					{
						best = cand;
						bestScore = score;
						tie = false;
					}
					else if (score == bestScore)
						tie = true;
				}
				if (tie)
				{
					String list = scope .();
					for (let cand in cands)
					{
						if (@cand.Index > 0)
							list.Append(", ");
						cand.m.GetSignature(list);
					}
					Err(b, "", "T2065", scope $"several overloads of {mr.Name} fit these inputs ({list}): pick one in Properties");
				}
			}
			let f = best.m;
			b.Member = f;
			CheckAccess(b, f);
			if (f.Unsafe && !f.IsImport)
				b.Unsafe = true;
			var inst = best.inst;
			inst = BindReceiver(b, f, inst, open, true);
			b.Owner = inst;
			b.Map = new .();
			T.MapOf(inst, b.Map);
			if (b.ReceiverIsBase && f.Abstract && !f.HasBody)
				Err(b, "", "T2066", scope $"the base version of {f.Name} is abstract: there is nothing to call");
			// The function's own generic parameters, from the arguments.
			if (f.IsGeneric)
			{
				List<GenericParamSym> infer = scope .();
				for (let g in f.Generics)
					infer.Add(g);
				for (let p in f.Params)
				{
					let have = InOrLit(b, p.Name);
					if (have != null)
						T.Unify(T.Subst(p.Type, b.Map), have, b.Map, infer);
				}
				b.MethodArgs = new .();
				for (let g in f.Generics)
				{
					if (!b.Map.TryGetValue(g, let arg))
					{
						Err(b, "", "T2067", scope $"{f.Name}: what {g.Name} is cannot be told from the inputs: wire an input of type {g.Name}");
						b.Map[g] = T.Error;
						b.MethodArgs.Add(T.Error);
						continue;
					}
					b.MethodArgs.Add(arg);
					String why = scope .();
					if (!c.Satisfies(arg, g, b.Map, r.Member, why))
						Err(b, "", "T1007", scope $"{f.Name}<{arg.Name}>: {arg.Name} does not satisfy the constraint on {g.Name}: {why}");
				}
				c.Instances.AddFunction(f, b.MethodArgs, r.SiteType, b.Key);
			}
			// The member's narrowing of its type's parameters (`generic T delete`): the
			// instance it is called on must satisfy it.
			for (let nar in f.Narrowings)
			{
				KType arg = null;
				b.Map.TryGetValue(nar.Param, out arg);
				if (arg == null || arg.IsError || arg.Kind == .Param)
					continue;
				if ((nar.IsDelete || nar.IsClass) && !Deletable(arg))
					Err(b, "", "T1007", scope $"{f.Name}: {arg.Name} does not satisfy the constraint on {nar.Param.Name}: it must be something Delete takes (a class, an array or a delegate)");
			}
			for (let p in f.Params)
			{
				let spec = b.AddIn(p.Name, T.Subst(p.Type, b.Map), p.Default != null);
				spec.IsRef = p.IsRef;
			}
			if (f.IsImport)
				BindCArgs(b, f);
			if (f.Owner.IsCore && f.Owner.FullName == "Core.Atomic")
				BindAtomic(b, f);
			if (!f.Returns.IsVoid)
				b.AddOut("result", T.Subst(f.Returns, b.Map));
			for (let o in f.Outs)
				b.AddOut(o.Name, T.Subst(o.Type, b.Map));
			// Flow or value call: the file says by its wires (Graph-Format deviation 9).
			if (b.Flow)
			{
				b.AddIn("in", null);
				b.AddFlowOut("then");
				if (f.ExpandAsFlow && f.Returns.IsEnum)
					for (let cs in f.Returns.Sym.Members)
						if (cs.Kind == .Case)
							b.AddFlowOut(scope $"case:{cs.Name}");
			}
			else if (!f.Pure)
			{
				bool anyWire = false;
				for (let l in r.Graph.Links)
					if (l.From.Owner == n || l.To.Owner == n)
						anyWire = true;
				if (anyWire)
					Err(b, "", "T2068", scope $"{f.Name} is not Pure: it has side effects, so it runs in the flow. Wire its flow pins.");
			}
		}

		/// A C function's inputs (Language.md 2.7, C interop): a `T*` input wired from a variable of
		/// type T passes the variable's address (as `ref` does); a variadic function takes extra
		/// inputs `va0`, `va1`, ... after its own, promoted as C does (Lower).
		void BindCArgs(BNode b, MemberSym f)
		{
			for (let spec in b.Ins)
			{
				if (spec.IsReceiver || spec.Type == null || spec.Type.Kind != .Pointer || spec.Type.Element.IsVoid)
					continue;
				let have = InType(b, spec.Name);
				if (have == null || have != spec.Type.Element)
					continue;
				let src = SourceNode(b, spec.Name);
				if (src == null || src.Kind != .Get || src.Var == .Property || src.Var == .None || src.Var == .ArrayLength)
					continue;
				spec.Type = have;
				spec.IsRef = true;
				if (b.AddressArgs == null)
					b.AddressArgs = new .();
				b.AddressArgs.Add(new String(spec.Name));
			}
			if (!f.Variadic)
				return;
			List<StringView> extras = scope .();
			for (let p in b.Node.Inputs)
				if (p.Kind == .Value && p.Name != "receiver" && f.FindParam(p.Name) == null && (r.Graph.IsLinked(p) || !p.Default.IsEmpty))
					extras.Add(p.Name);
			SortArgNames(extras, "va");
			b.VarArgs = new .();
			for (let name in extras)
			{
				if (!name.StartsWith("va"))
				{
					Err(b, name, "T2270", scope $"{f.Name} takes extra inputs named va0, va1, ... (after its own), not '{name}'");
					continue;
				}
				var t = InType(b, name);
				if (t == null)
				{
					let lit = Lit(b, name);
					t = lit.StartsWith('"') ? T.Pointer(T.Char8) : Literals.TypeOf(lit, T);
				}
				t = t ?? T.Error;
				if (!t.IsError && !(t.IsNumeric || t.Kind == .Bool || t.Kind == .Char || t.IsPointer || t.IsEnum || t.Kind == .Function || t.Kind == .Null))
					Err(b, name, "T2271", scope $"{name}: a C variadic input takes numbers, characters, bools and pointers, not {TypeTable.WithArticle(t, .. scope .())} (a String: pass its CStr)");
				b.AddIn(name, t, false, name);
				b.VarArgs.Add(new String(name));
			}
		}

		/// A call of Core.Atomic (Language.md 4.2): its memory order and what it works on.
		void BindAtomic(BNode b, MemberSym f)
		{
			StringView order = b.Node.GetSetting("order");
			if (order.IsEmpty)
				order = "seqcst";
			if (order != "relaxed" && order != "acquire" && order != "release" && order != "acqrel" && order != "seqcst")
				Err(b, "", "T2260", scope $"'{order}' is not a memory order (relaxed, acquire, release, acqrel, seqcst)");
			else if (f.Name == "Load" && (order == "release" || order == "acqrel"))
				Err(b, "", "T2260", scope $"an atomic Load cannot be {order} (it reads: relaxed, acquire or seqcst)");
			else if (f.Name == "Store" && (order == "acquire" || order == "acqrel"))
				Err(b, "", "T2260", scope $"an atomic Store cannot be {order} (it writes: relaxed, release or seqcst)");
			b.Order = new String(order);
			if (b.MethodArgs == null || b.MethodArgs.IsEmpty)
				return;
			let t = b.MethodArgs[0];
			if (t == null || t.IsError)
				return;
			let floatOk = f.Name == "Load" || f.Name == "Store" || f.Name == "Add" || f.Name == "Sub" || f.Name == "Exchange";
			let ok = (t.IsInteger && t.Bits >= 8) || t.IsPointer || t.IsReference || (t.Kind == .Float && floatOk);
			let refOnly = t.IsPointer || t.IsReference;
			let refsOk = f.Name == "Load" || f.Name == "Store" || f.Name == "Exchange" || f.Name == "CompareExchange";
			if (!ok || (refOnly && !refsOk))
			{
				String what = scope .("integers");
				if (floatOk && refsOk)
					what.Append(", floats, pointers and references");
				else if (floatOk)
					what.Append(" and floats");
				else if (refsOk)
					what.Append(", pointers and references");
				Err(b, "location", "T2261", scope $"Atomic {f.Name} works on {what}, not {TypeTable.WithArticle(t, .. scope .())}");
			}
		}

		/// A node that did not bind keeps its flow pins, so the flow checks still see it.
		void AddLooseFlow(BNode b)
		{
			if (!b.Flow)
				return;
			b.AddIn("in", null);
			b.AddFlowOut("then");
			// Keep the wired pins: their types are unknown.
			for (let p in b.Node.Inputs)
				if (p.Kind == .Value && b.FindIn(p.Name) == null)
					b.AddIn(p.Name, T.Error, true);
			for (let p in b.Node.Outputs)
				if (p.Kind == .Value && b.FindOut(p.Name) == null)
					b.AddOut(p.Name, T.Error);
		}

		void AddLooseValues(BNode b)
		{
			for (let p in b.Node.Inputs)
				if (p.Kind == .Value && b.FindIn(p.Name) == null)
					b.AddIn(p.Name, T.Error, true);
			for (let p in b.Node.Outputs)
				if (p.Kind == .Value && b.FindOut(p.Name) == null)
					b.AddOut(p.Name, T.Error);
		}

		// ------------------------------------------------------------------ variables

		/// Field or property `name` of `inst` or its bases, with the instance it was found in.
		(MemberSym m, KType inst) FindVariable(KType inst, StringView name)
		{
			var t = inst;
			int guard = 0;
			while (t != null && t.Kind == .Named && guard++ < 64)
			{
				for (let m in t.Sym.Members)
					if ((m.Kind == .Field || m.Kind == .Property) && m.Name == name)
						return (m, t);
				t = T.BaseOf(t);
			}
			return (null, null);
		}

		void BindVariable(BNode b)
		{
			let n = b.Node;
			let isSet = n.Kind == .Set;
			b.Flow = isSet;
			let mr = MemberRef.Parse(n.Text);
			defer delete mr;
			KType varType = null;
			bool writable = true;
			switch (mr.Owner)
			{
			case .Local:
				let l = r.Member.Decl?.FindLocal(mr.Name);
				if (l == null)
				{
					Err(b, "", "T2070", scope $"{r.Member.Name} has no local variable {mr.Name}");
					varType = T.Error;
					break;
				}
				b.Var = .Local;
				b.LocalVar = l;
				varType = c.Resolve(l.Type, Ctx(b)) ?? T.Error;
				// A Lambda Sheet has no locals of its own: it captures the function's.
				if (r.IsLambda)
					AddCapture(b, .Local, mr.Name, varType);
			case .Param:
				if (r.IsLambda)
				{
					let lp = r.FindLambdaParam(mr.Name);
					if (lp != null)
					{
						b.Var = .Param;
						b.ParamVar = lp;
						varType = lp.Type;
						break;
					}
					// A Lambda inside a Lambda Sheet: an input of an enclosing Lambda (the nearest
					// first) is captured (BindLambda chains it through the Lambdas between).
					ParamSym op = null;
					for (var outer = OuterLambda(); outer != null && op == null; outer = OuterLambda(outer))
						op = outer.FindLambdaParam(mr.Name);
					if (op != null)
					{
						AddCapture(b, .Param, mr.Name, op.Type);
						b.Var = .Param;
						b.ParamVar = op;
						varType = op.Type;
						break;
					}
				}
				var p = r.Member.FindParam(mr.Name);
				if (p != null && r.IsLambda)
				{
					if (p.IsOut || p.IsRef || p.Mode == .In)
					{
						Err(b, "", "T2251", scope $"{mr.Name} is passed by reference to {r.Member.Name}: a Lambda cannot capture it (store it in a local first)");
						varType = T.Error;
						break;
					}
					AddCapture(b, .Param, mr.Name, p.Type);
				}
				if (p == null && r.Sheet.Role == .Set && mr.Name == "value")
				{
					b.Var = .Param;
					varType = r.Member.Type ?? T.Error;
					break;
				}
				if (p == null)
				{
					Err(b, "", "T2071", scope $"{r.Member.Name} has no parameter {mr.Name}");
					varType = T.Error;
					break;
				}
				b.Var = p.IsOut ? .OutParam : .Param;
				b.ParamVar = p;
				varType = p.Type;
				if (p.Mode == .In && isSet)
					Err(b, "", "T2072", scope $"{mr.Name} is an `in` parameter: it cannot be set");
			case .This, .Type:
				bool open = false;
				let owner = OwnerOf(b, mr, out open);
				if (owner == null || owner.IsError)
				{
					varType = T.Error;
					AddLooseValues(b);
					break;
				}
				if (owner.Kind == .Array && mr.Name == "Length")
				{
					b.Var = .ArrayLength;
					writable = false;
					let rp = n.FindInput("receiver");
					if (rp == null || !r.Graph.IsLinked(rp))
						Err(b, "receiver", "T2052", "Receiver: Length needs the array it measures: wire it");
					b.AddIn("receiver", owner, true, "Receiver").IsReceiver = true;
					varType = T.Int;
					break;
				}
				if (owner.Kind != .Named)
				{
					Err(b, "", "T2073", scope $"{S!(owner)} has no member {mr.Name}");
					varType = T.Error;
					break;
				}
				let (m, inst) = FindVariable(owner, mr.Name);
				if (m == null)
				{
					if (owner.Sym.FindCase(mr.Name) != null)
						Err(b, "", "T2074", scope $"{mr.Name} is a case of {S!(owner)}: use Make Case");
					else
						Err(b, "", "T2075", scope $"{S!(owner)} has no field or property {mr.Name}");
					varType = T.Error;
					AddLooseValues(b);
					break;
				}
				b.Member = m;
				CheckAccess(b, m);
				if (m.EventOf != null)
					Err(b, "", "T2215", scope $"{m.Name} is an event: use its Add, Remove, Invoke, Clear and Count nodes (Call {mr.Name}.Add ...)");
				let usedInst = BindReceiver(b, m, inst, open, mr.Owner == .This || r.Type.DerivesFrom(m.Owner));
				b.Owner = usedInst;
				b.Map = new .();
				T.MapOf(usedInst, b.Map);
				varType = T.Subst(m.Type, b.Map);
				if (m.Kind == .Property)
				{
					b.Var = .Property;
					if (isSet && !m.HasSet)
						Err(b, "", "T2076", scope $"the property {m.Name} has no setter");
					if (!isSet && !m.HasGet)
						Err(b, "", "T2077", scope $"the property {m.Name} has no getter");
				}
				else
				{
					b.Var = m.Static ? .StaticField : .Field;
					if (isSet && m.Const)
						Err(b, "", "T2078", scope $"{m.Name} is a constant");
					else if (isSet && m.CVar && m.CVarVia != null && !m.CVarDeref)
						Err(b, "", "T2219", scope $"{m.Name} is read through the C function {m.CVarVia}: it cannot be set");
					else if (isSet && m.Readonly && !(r.Member.Kind == .Ctor && m.Owner == r.Type))
						Err(b, "", "T2079", scope $"{m.Name} is read-only: only {m.Owner.Name}'s constructors set it");
					if (isSet && !m.Static && b.ReceiverIsThis && r.Type.Kind == .Struct && r.Member.Kind != .Ctor && !r.Member.Mutating)
						Err(b, "", "T2080", scope $"{r.Member.Name} is not Mutating: it cannot change the fields of its struct");
				}
			}
			if (varType == null)
				varType = T.Error;
			if (!isSet)
			{
				b.AddOut("value", varType);
				return;
			}
			if (!writable)
				Err(b, "", "T2081", scope $"{mr.Name} cannot be set");
			b.AddIn("in", null);
			b.AddIn("value", varType, false, "Value");
			b.AddFlowOut("then");
			b.AddOut("result", varType);
			StringView op = n.GetSetting("op");
			if (!op.IsEmpty && op != "=")
			{
				if (op.EndsWith('='))
					op = op.Substring(0, op.Length - 1);
				b.SetOp.Set(op);
				b.OperandType = varType;
				if (!c.SupportsOperator(varType, op, r.Member))
					Err(b, "", "T2082", scope $"{S!(varType)} has no operator {op} (set op {op}=)");
				else
					b.OpImpl = (varType.Kind == .Param) ? .Generic : ((c.FindUserOperator(varType, op) != null && !varType.IsNumeric) ? .User : .Builtin);
			}
		}

		// ------------------------------------------------------------------ lifetime

		void BindConstruct(BNode b)
		{
			let n = b.Node;
			b.Flow = true;
			b.AddIn("in", null);
			b.AddFlowOut("then");
			let isLocal = n.Kind == .Local;
			var t = c.Resolve(n.SubjectType, Ctx(b));
			if (t == null)
			{
				Err(b, "", "T2090", scope $"{(isLocal ? "Local" : "Construct")} needs a type");
				t = T.Error;
			}
			let isArray = n.HasSetting("count") || t.Kind == .Array;
			if (isArray && t.Kind != .Array && !t.IsError)
				t = T.Array(t);
			b.Subject = t;
			if (isArray)
			{
				b.AddIn("count", T.Int, false, "Count");
				if (!isLocal)
					BindAllocator(b, t);
				b.AddOut("object", t);
				return;
			}
			if (t.IsError)
			{
				AddLooseValues(b);
				b.AddOut("object", t);
				return;
			}
			KType objType = t;
			switch (t.Kind)
			{
			case .Named:
				let s = t.Sym;
				if (s.Kind == .Interface || s.Abstract)
					Err(b, "", "T2091", scope $"{S!(t)} is abstract: construct a class that implements it");
				else if (s.Static)
					Err(b, "", "T2092", scope $"{S!(t)} is a static class (a node library): it has no objects");
				else if (s.Kind == .Enum)
					Err(b, "", "T2093", scope $"{S!(t)} is an enum: use Make Case or a Literal");
				else if (s.Kind == .Delegate)
					Err(b, "", "T2094", scope $"{S!(t)} is a delegate type: use Bind Function");
				else if (s.Kind == .Struct && !isLocal)
					Err(b, "", "T2095", scope $"{S!(t)} is a struct (a value): use Local {S!(t)} or Make {S!(t)}");
				Dictionary<GenericParamSym, KType> map = scope .();
				T.MapOf(t, map);
				let k = PickCtor(b, t, n.GetSetting("ctor"), map);
				b.Member = k;
				b.Owner = t;
				if (k != null)
				{
					CheckAccess(b, k);
					for (let p in k.Params)
						b.AddIn(p.Name, T.Subst(p.Type, map), p.Default != null).IsRef = p.IsRef;
				}
				else
				{
					List<MemberSym> ctors = scope .();
					s.GetCtors(ctors);
					if (ctors.IsEmpty)
						for (let p in n.Inputs)
							if (p.Kind == .Value && p.Name != "allocator" && r.Graph.IsLinked(p))
								Err(b, p.Name, "T2096", scope $"{S!(t)} has only the default constructor: it takes no '{p.Name}'");
				}
			case .Param:
				// `new T` (Language.md 2.4): the default constructor of whatever T is per instance.
				let gp = t.Param;
				if (!gp.IsNew)
					Err(b, "", "T2097", scope $"{t.Name} is a generic parameter: {(isLocal ? "Local" : "Construct")} {t.Name} needs the `new` constraint on {t.Name}");
				else if (!isLocal && !gp.IsClass)
					Err(b, "", "T2104", scope $"Construct {t.Name} allocates on the heap: {t.Name} needs the `class` constraint too (Local {t.Name} works for structs)");
				for (let p in n.Inputs)
					if (p.Kind == .Value && p.Name != "allocator" && r.Graph.IsLinked(p))
						Err(b, p.Name, "T2096", scope $"{t.Name} is made with its constructor without inputs: it takes no '{p.Name}'");
			default:
				Err(b, "", "T2098", scope $"{S!(t)} is a value: use a local variable or a Literal");
			}
			if (!isLocal)
				BindAllocator(b, t);
			else if (n.FindInput("allocator") != null && r.Graph.IsLinked(n.FindInput("allocator")))
				Err(b, "allocator", "T2099", "Allocator: a Local lives in its region, it takes no allocator (use Construct)");
			b.AddOut("object", objType);
		}

		/// Construct / Delete `allocator` (Language.md 3, "Construct with allocator"): an
		/// optional Core.IAllocator input; the object is allocated / freed through it.
		void BindAllocator(BNode b, KType objType)
		{
			let ap = b.Node.FindInput("allocator");
			if (ap == null || !r.Graph.IsLinked(ap))
				return;
			let ia = c.Table.Find("Core.IAllocator");
			if (ia == null)
				return;
			b.AddIn("allocator", ia.Self, true, "Allocator");
			b.WithAllocator = true;
			// Class objects and arrays (`alloc.array T[] %len %allocator`); T2105 (arrays) is retired.
			if (objType != null && !objType.IsError && !(objType.IsClass || objType.IsInterface || objType.Kind == .Array || (objType.Kind == .Param && objType.Param.IsClass)))
				Err(b, "allocator", "T2106", scope $"Allocator: only class objects and arrays are allocated through an allocator, not {TypeTable.WithArticle(objType, .. scope .())}");
		}

		// ------------------------------------------------------------------ loops

		void BindFor(BNode b)
		{
			b.Flow = true;
			b.AddIn("in", null);
			KType it = T.Int;
			StringView setting = b.Node.GetSetting("index-type");
			if (!setting.IsEmpty)
			{
				let itr = TypeRef.Parse(setting);
				defer delete itr;
				it = c.Resolve(itr, Ctx(b)) ?? T.Int;
				if (!it.IsInteger && !it.IsError)
				{
					Err(b, "", "T2100", scope $"the index of a For is an integer, not {S!(it)}");
					it = T.Int;
				}
			}
			b.AddIn("start", it, false, "Start");
			b.AddIn("count", it, false, "Count");
			b.AddIn("step", it, true, "Step");
			b.AddFlowOut("body");
			b.AddFlowOut("done");
			b.AddOut("index", it, "body");
		}

		/// The element type For Each walks, or null.
		KType ElementOf(KType t)
		{
			if (t == null)
				return null;
			if (t.IsError)
				return T.Error;
			switch (t.Kind)
			{
			case .Array, .FixedArray: return t.Element;
			case .Named:
				if (t.Sym == T.SpanSym && t.Args.Count == 1)
					return t.Args[0];
				if (t.Sym == T.StringSym || t.Sym == T.StringViewSym)
					return T.Char8;
			default:
			}
			return null;
		}

		void BindForEach(BNode b)
		{
			b.Flow = true;
			b.AddIn("in", null);
			let ct = InType(b, "collection");
			KType et = T.Error;
			if (ct != null)
			{
				let e = ElementOf(ct);
				if (e != null)
					et = e;
				else if (!BindEnumerator(b, ct, ref et))
					Err(b, "collection", "T2101", scope $"Collection: For Each walks arrays, spans, strings and types with GetEnumerator(), not a {S!(ct)}");
			}
			b.AddIn("collection", ct ?? T.Error, false, "Collection");
			b.AddFlowOut("body");
			b.AddFlowOut("done");
			b.AddOut("element", et, "body");
			b.AddOut("index", T.Int, "body");
		}

		/// The enumerator protocol (Language.md 5.1): the collection has `GetEnumerator()` giving an
		/// enumerator struct with `MoveNext() -> bool` and a `Current` property. False when the
		/// collection has no GetEnumerator (the caller reports it); other problems are reported here.
		bool BindEnumerator(BNode b, KType ct, ref KType et)
		{
			if (ct.Kind != .Named || ct.Sym.Kind == .Enum)
				return false;
			List<(MemberSym m, KType inst)> cands = scope .();
			FindFunctions(ct, "GetEnumerator", cands);
			(MemberSym m, KType inst) get = (null, null);
			for (let cand in cands)
				if (cand.m.Params.IsEmpty && !cand.m.Static)
					get = cand;
			if (get.m == null)
				return false;
			CheckAccess(b, get.m);
			b.Member = get.m;
			b.Owner = get.inst;
			b.Map = new .();
			T.MapOf(get.inst, b.Map);
			let e = T.Subst(get.m.Returns, b.Map);
			b.EnumType = e;
			if (e.IsError)
				return true;
			if (!e.IsStruct)
			{
				Err(b, "collection", "T2102", scope $"Collection: {S!(ct)}.GetEnumerator() gives {TypeTable.WithArticle(e, .. scope .())}: For Each takes an enumerator struct (an object would be left for no one to delete)");
				return true;
			}
			List<(MemberSym m, KType inst)> moves = scope .();
			FindFunctions(e, "MoveNext", moves);
			for (let mv in moves)
				if (mv.m.Params.IsEmpty && !mv.m.Static && mv.m.Returns == T.Bool)
					b.EnumMove = mv.m;
			let (cur, curInst) = FindVariable(e, "Current");
			if (cur != null && cur.Kind == .Property && cur.HasGet && !cur.Static)
				b.EnumCurrent = cur;
			if (b.EnumMove == null || b.EnumCurrent == null)
			{
				Err(b, "collection", "T2103", scope $"Collection: the enumerator {S!(e)} needs MoveNext() returning bool and a Current property with a getter");
				return true;
			}
			Dictionary<GenericParamSym, KType> em = scope .();
			T.MapOf(curInst ?? e, em);
			et = T.Subst(b.EnumCurrent.Type, em);
			c.Instances.AddType(e, r.SiteType, b.Key);
			return true;
		}

		void BindSwitch(BNode b)
		{
			let n = b.Node;
			b.Flow = true;
			b.AddIn("in", null);
			KType on = null;
			StringView setting = n.GetSetting("on");
			if (!setting.IsEmpty)
			{
				let otr = TypeRef.Parse(setting);
				defer delete otr;
				on = c.Resolve(otr, Ctx(b));
			}
			let wired = InType(b, "value");
			if (on == null)
				on = wired;
			if (on == null)
			{
				Err(b, "value", "T2110", "Value: wire what to switch on (or set Switch On)");
				on = T.Error;
			}
			b.Subject = on;
			b.TextSwitch = on.Kind == .Named && (on.Sym == T.StringSym || on.Sym == T.StringViewSym);
			if (!on.IsError && !(on.IsInteger || on.Kind == .Char || on.IsEnum || b.TextSwitch))
				Err(b, "value", "T2111", scope $"Switch works on integers, chars, enums and strings, not on {S!(on)}");
			b.AddIn("value", on, false, "Value");
			b.Cases = new .();
			for (let s in n.Settings)
			{
				if (s.Key != "case")
					continue;
				let label = s.Value;
				if (b.Cases.Contains(label))
				{
					Err(b, scope $"case:{label}", "T2112", scope $"the case {label} is listed twice");
					continue;
				}
				b.Cases.Add(new String(label));
				b.AddFlowOut(scope $"case:{label}");
				if (on.IsEnum)
				{
					let cs = on.Sym.FindCase(label);
					if (cs == null)
					{
						Err(b, scope $"case:{label}", "T2113", scope $"{S!(on)} has no case {label}");
						continue;
					}
					Dictionary<GenericParamSym, KType> map = scope .();
					T.MapOf(on, map);
					for (let p in cs.Payload)
						b.AddOut(scope $"case:{label}.{p.Name}", T.Subst(p.Type, map), scope $"case:{label}");
				}
				else if (b.TextSwitch)
				{
					// The label is the text (a word of the record format).
				}
				else if (!on.IsError)
				{
					String why = scope .();
					if (Literals.Classify(label, var iv, var fv) == .Bad || !Literals.Fits(label, on, T, why))
						Err(b, scope $"case:{label}", "T2114", scope $"case {label}: {why}");
				}
			}
			b.AddFlowOut("default");
			b.AddFlowOut("done");
		}

		void BindStateful(BNode b)
		{
			let n = b.Node;
			b.Flow = true;
			b.AddIn("in", null);
			switch (n.Kind)
			{
			case .Gate:
				b.AddFlowOut("exit");
			case .DoOnce:
				b.AddFlowOut("once");
			case .DoN:
				b.AddIn("n", T.Int, false, "N");
				b.AddFlowOut("do");
				b.AddOut("counter", T.Int, "do");
			case .FlipFlop:
				b.AddFlowOut("a");
				b.AddFlowOut("b");
				b.AddOut("isA", T.Bool);
			case .MultiGate:
				int count = 2;
				if (int.Parse(n.GetSetting("count")) case .Ok(let cnt))
					count = Math.Clamp(cnt, 1, 64);
				for (int i < count)
					b.AddFlowOut(scope $"out{i}");
			default:
				b.AddFlowOut("then");
			}
			if (n.Kind == .Gate || n.Kind == .DoOnce || n.Kind == .DoN || n.Kind == .FlipFlop || n.Kind == .MultiGate)
				b.AddFlowOut("done");
			if (n.Kind == .MultiGate && n.HasSetting("random"))
				b.StateSeed = r.Type.FindOwnMember(scope $"__multiGateSeed_{n.Key}");
			BindState(b);
		}

		/// The kind of stateful node an action node changes.
		static NodeKind StatefulKindOf(NodeKind k)
		{
			switch (k)
			{
			case .GateOpen, .GateClose, .GateToggle: return .Gate;
			case .ResetDoOnce: return .DoOnce;
			case .ResetDoN: return .DoN;
			case .ResetMultiGate: return .MultiGate;
			default: return k;
			}
		}

		/// The state field of a stateful node or of the node an action changes (Language.md 5.1):
		/// `set state <field>` names a field of the type; otherwise the node's hidden field. An
		/// action without `set state` changes the one node of its kind in this Sheet, else in
		/// the type.
		void BindState(BNode b)
		{
			let n = b.Node;
			let kind = StatefulKindOf(n.Kind);
			let title = FlowMacros.GetTitle(kind, .. scope String());
			StringView setting = n.GetSetting("state");
			String fieldName = scope .(setting);
			if (fieldName.IsEmpty && NodeKinds.IsStateful(n.Kind))
			{
				if (r.Type.Kind == .Struct && r.This != null)
				{
					Err(b, "", "T2241", scope $"{title}: a struct's function keeps no hidden state (the value would carry it): name a field in State Field (a Mutating function) or make the function static");
					return;
				}
				Compilation.StateFieldName(n.Kind, n.Key, fieldName);
			}
			else if (fieldName.IsEmpty)
			{
				// An action node: the one node of its kind in this Sheet, else in the type.
				List<(Sheet s, Node node)> found = scope .();
				for (int pass < 2)
				{
					for (let s in r.Unit.Doc.Sheets)
					{
						if ((pass == 0) != (s == r.Sheet) || s.Member == null)
							continue;
						for (let o in s.Graph.Nodes)
							if (o.Kind == kind && !o.Disabled)
								found.Add((s, o));
					}
					if (!found.IsEmpty)
						break;
				}
				if (found.IsEmpty)
				{
					Err(b, "", "T2243", scope $"there is no {title} in {r.Type.Name} for this node to change");
					return;
				}
				if (found.Count > 1)
				{
					Err(b, "", "T2244", scope $"{found.Count} {title} nodes could be meant: name the one to change in State Field ({(StringView)found[0].node.Key}: __{(StringView)FieldStem(kind)}_{(StringView)found[0].node.Key})");
					return;
				}
				let target = found[0].node;
				if (target.HasSetting("state"))
					fieldName.Set(target.GetSetting("state"));
				else
					Compilation.StateFieldName(kind, target.Key, fieldName);
			}
			let (f, inst) = FindVariable(r.Type.Self, fieldName);
			if (f == null || f.Kind != .Field)
			{
				if (setting.IsEmpty)
					Err(b, "", "T2245", scope $"{title}: the node it changes keeps no hidden state here (a struct's function: name a field in State Field)");
				else
					Err(b, "", "T2240", scope $"State Field: {r.Type.Name} has no field {fieldName}");
				return;
			}
			b.Member = f;
			b.Owner = inst;
			b.Map = new .();
			T.MapOf(inst, b.Map);
			b.StateStatic = f.Static;
			let want = c.StateType(kind);
			if (T.Subst(f.Type, b.Map) != want)
				Err(b, "", "T2242", scope $"State Field: {fieldName} is {TypeTable.WithArticle(f.Type, .. scope .())}: a {title} keeps {TypeTable.WithArticle(want, .. scope .())}");
			if (f.Const || f.Readonly)
				Err(b, "", "T2242", scope $"State Field: {fieldName} cannot be changed (it is {(f.Const ? "constant" : "read-only")})");
			if (!f.Static && r.This == null)
				Err(b, "", "T2246", scope $"{r.Member.Name} is static: the state field {fieldName} belongs to an object (make it static)");
			else if (!f.Static && r.Type.Kind == .Struct && r.Member.Kind != .Ctor && !r.Member.Mutating)
				Err(b, "", "T2080", scope $"{r.Member.Name} is not Mutating: it cannot change the state field {fieldName} of its struct");
		}

		static StringView FieldStem(NodeKind k)
		{
			switch (k)
			{
			case .Gate: return "gate";
			case .DoOnce: return "doOnce";
			case .DoN: return "doN";
			case .FlipFlop: return "flipFlop";
			default: return "multiGate";
			}
		}

		// ------------------------------------------------------------------ errors as values

		void BindResult(BNode b)
		{
			let n = b.Node;
			b.Flow = true;
			b.AddIn("in", null);
			let rt = InType(b, "result");
			KType vt = T.Error;
			KType et = T.Error;
			if (rt != null && !rt.IsError)
			{
				if (rt.Kind == .Named && rt.Sym == T.ResultSym && rt.Args.Count == 2)
				{
					vt = rt.Args[0];
					et = rt.Args[1];
				}
				else
					Err(b, "result", "T2120", scope $"Result: {(n.Kind == .Try ? "Try" : "Result: match")} takes a Result, not a {S!(rt)}");
			}
			b.AddIn("result", rt ?? T.Error, false, "Result");
			if (n.Kind == .ResultMatch)
			{
				b.AddFlowOut("ok");
				b.AddFlowOut("err");
				b.AddFlowOut("done");
				if (!vt.IsVoid)
					b.AddOut("value", vt, "ok");
				if (!et.IsVoid)
					b.AddOut("error", et, "err");
				return;
			}
			b.AddFlowOut("then");
			if (!vt.IsVoid)
				b.AddOut("value", vt);
			// Try returns the error from the enclosing function.
			let ret = r.Returns;
			if (r.Sheet.Role != .Body || ret == null || !(ret.Kind == .Named && ret.Sym == T.ResultSym && ret.Args.Count == 2))
			{
				Err(b, "", "T2121", scope $"Try returns the error from {r.Member.Name}, so {r.Member.Name} must return a Result");
				return;
			}
			if (!et.IsError && ret.Args[1] != et)
				Err(b, "", "T2122", scope $"Try: the error type {S!(et)} is not the one {r.Member.Name} returns ({S!(ret.Args[1])})");
		}

		// ------------------------------------------------------------------ values

		void BindOperator(BNode b)
		{
			let n = b.Node;
			b.Flow = false;
			StringView op = n.Text;
			let unary = op == "!" || op == "~" || op == "neg";
			let logical = op == "&&" || op == "||" || op == "!";
			let compare = op == "==" || op == "!=" || op == "<" || op == ">" || op == "<=" || op == ">=";
			let known = unary || logical || compare || op == "+" || op == "-" || op == "*" || op == "/" || op == "%" ||
				op == "&" || op == "|" || op == "^" || op == "<<" || op == ">>";
			if (!known)
			{
				Err(b, "", "T2130", scope $"'{op}' is not an operator");
				AddLooseValues(b);
				return;
			}
			if (TryBindVectorOperator(b, op, unary, logical, compare)) // BindVector.bf: element-wise, scalars splat
				return;
			if (logical)
			{
				b.OpImpl = .Builtin;
				b.OperandType = T.Bool;
				b.AddIn("a", T.Bool, false, "A");
				if (!unary)
					b.AddIn("b", T.Bool, false, "B");
				b.AddOut("result", T.Bool);
				return;
			}
			if (!unary && TryBindMixedOperator(b, op))
				return;
			var ta = InType(b, "a");
			var tb = unary ? null : InType(b, "b");
			// A literal takes the type of the other side.
			if (ta == null)
				ta = (tb != null) ? tb : Literals.TypeOf(Lit(b, "a"), T);
			if (tb == null && !unary)
				tb = (InType(b, "a") != null) ? ta : Literals.TypeOf(Lit(b, "b"), T);
			KType operand = null;
			if (ta == null || (!unary && tb == null))
				operand = ta ?? tb ?? T.Error;
			else if (unary)
				operand = ta;
			else if (ta.IsError || tb.IsError)
				operand = ta.IsError ? tb : ta;
			else if (ta == tb)
				operand = ta;
			else if (ta.IsNumeric && tb.IsNumeric)
				operand = T.CommonNumeric(ta, tb);
			else if (T.CanConvert(tb, ta) != .Refused)
				operand = ta;
			else if (T.CanConvert(ta, tb) != .Refused)
				operand = tb;
			if (operand == null)
			{
				Err(b, "", "T2131", scope $"{op} cannot combine a {S!(ta)} and a {S!(tb)}: Cast one of them");
				operand = T.Error;
			}
			b.OperandType = operand;
			KType result = compare ? T.Bool : operand;
			if (!operand.IsError)
			{
				let user = (operand.Kind == .Named) ? c.FindUserOperatorFor(operand, op, operand, unary ? null : operand) : null;
				if (user != null && operand.Kind == .Named && !(operand.Sym.Kind == .Enum && !operand.Sym.HasPayload && (op == "==" || op == "!=")))
				{
					b.OpImpl = .User;
					b.Member = user;
					b.Owner = operand;
					b.Map = new .();
					T.MapOf(operand, b.Map);
					result = T.Subst(user.Returns, b.Map);
					if (user.Params.Count != (unary ? 1 : 2))
						Err(b, "", "T2132", scope $"the operator {op} of {S!(operand)} takes {user.Params.Count} inputs");
					else
					{
						for (let nar in user.Narrowings)
						{
							KType arg = null;
							b.Map.TryGetValue(nar.Param, out arg);
							if (arg == null)
								continue;
							for (let o in nar.Operators)
								if (!c.SupportsOperator(arg, o, r.Member))
									Err(b, "", "T1007", scope $"{S!(operand)}: {arg.Name} does not satisfy the constraint on {nar.Param.Name}: it has no operator {o}");
						}
						c.Instances.AddType(operand, r.SiteType, b.Key);
					}
				}
				else if (operand.Kind == .Nullable && (op == "==" || op == "!="))
				{
					// `T?` against null, or against another `T?` / `T` when T has the operator
					// (Language.md 2.2): the has-value flags, then the values
					bool nullSide = false;
					for (let side in StringView[?]("a", "b"))
					{
						let st = InType(b, side) ?? Literals.TypeOf(Lit(b, side), T);
						nullSide |= st != null && st.Kind == .Null;
					}

					if (nullSide || c.SupportsOperator(operand.Element, op, r.Member))
						b.OpImpl = .Builtin;
					else
						Err(b, "", "T2133", scope $"{S!(operand)} has no operator {op} except against null ({S!(operand.Element)} has none)");
				}
				else if (!c.SupportsOperator(operand, op, r.Member))
					Err(b, "", "T2133", scope $"{S!(operand)} has no operator {op}");

				else
					b.OpImpl = (operand.Kind == .Param) ? .Generic : .Builtin;
				if ((op == "<<" || op == ">>") && b.OpImpl == .Builtin && tb != null && !tb.IsInteger && !tb.IsError)
					Err(b, "b", "T2134", "B: a shift count is an integer");
			}
			b.AddIn("a", operand, false, "A");
			if (!unary)
				b.AddIn("b", ((op == "<<" || op == ">>") && tb != null) ? tb : operand, false, "B");
			b.AddOut("result", result);
		}

		/// A user operator whose two inputs have different types (`Vec3 * float`, `float * Vec3`,
		/// `Mat4 * Vec4`; Core-Library.md, the math types), chosen by the wired types and the
		/// literals: a literal beside such a type takes the number type of the operator's input.
		bool TryBindMixedOperator(BNode b, StringView op)
		{
			var ta = InType(b, "a");
			var tb = InType(b, "b");
			if ((ta != null && ta.IsError) || (tb != null && tb.IsError) || (ta == null && tb == null))
				return false;
			if (ta == null)
			{
				let lit = Lit(b, "a");
				ta = c.MixedLiteralSide(op, tb, true, lit);
			}
			else if (tb == null)
			{
				let lit = Lit(b, "b");
				tb = c.MixedLiteralSide(op, ta, false, lit);
			}
			if (ta == null || tb == null || ta == tb)
				return false;
			let user = c.FindMixedOperator(op, ta, tb, let owner);
			if (user == null)
				return false;
			b.OpImpl = .User;
			b.Member = user;
			b.Owner = owner;
			b.OperandType = owner;
			b.Map = new .();
			T.MapOf(owner, b.Map);
			c.Instances.AddType(owner, r.SiteType, b.Key);
			b.AddIn("a", T.Subst(user.Params[0].Type, b.Map), false, "A");
			b.AddIn("b", T.Subst(user.Params[1].Type, b.Map), false, "B");
			b.AddOut("result", T.Subst(user.Returns, b.Map));
			return true;
		}

		void BindSelect(BNode b)
		{
			if (TryBindVectorSelect(b)) // BindVector.bf: a lane mask picks lane by lane
				return;
			b.Flow = false;
			var ta = InOrLit(b, "true");
			var tb = InOrLit(b, "false");
			KType t = ta ?? tb ?? T.Error;
			if (ta != null && tb != null && ta != tb && !ta.IsError && !tb.IsError)
			{
				if (ta.IsNumeric && tb.IsNumeric)
					t = T.CommonNumeric(ta, tb) ?? T.Error;
				else if (T.CanConvert(tb, ta) != .Refused)
					t = ta;
				else if (T.CanConvert(ta, tb) != .Refused)
					t = tb;
				else
				{
					Err(b, "false", "T2140", scope $"Select: True is a {S!(ta)} and False a {S!(tb)}: they need one type");
					t = T.Error;
				}
			}
			if (t.Kind == .Null)
				t = T.Error;
			b.AddIn("condition", T.Bool, false, "Condition");
			b.AddIn("true", t, false, "True");
			b.AddIn("false", t, false, "False");
			b.AddOut("result", t);
		}

		void BindCast(BNode b)
		{
			let n = b.Node;
			let to = c.Resolve(n.SubjectType, Ctx(b)) ?? T.Error;
			b.Subject = to;
			let from = InOrLit(b, "value");
			StringView kind = n.GetSetting("kind");
			if (TryBindVectorCast(b, to, from, kind)) // BindVector.bf
				return;
			b.Checked = n.HasSetting("checked");
			b.Flow = kind == "box" || b.Checked;
			if (b.Flow)
			{
				b.AddIn("in", null);
				b.AddFlowOut("then");
			}
			KType inType = from ?? T.Error;
			if (from != null && !from.IsError && !to.IsError)
			{
				switch (kind)
				{
				case "numeric":
					b.Cast = .Numeric;
				case "class":
					b.Cast = .Class;
				case "unchecked":
					b.Cast = .Unchecked;
					b.Unsafe = true;
				case "box":
					b.Cast = .Box;
				case "unbox":
					b.Cast = .Unbox;
				case "":
					if (from == to)
						b.Cast = .Identity;
					else if (from.Kind == .Array && to.Kind == .Named && to.Sym == T.SpanSym && to.Args.Count == 1 && to.Args[0] == from.Element)
						b.Cast = .Span;
					else if (from.Kind == .Nullable && from.Element == to)
						b.Cast = .Unwrap;
					else if ((from.IsNumeric || from.Kind == .Char) && (to.IsNumeric || to.Kind == .Char))
						b.Cast = .Numeric;
					else if (from.IsEnum && to.IsInteger)
						b.Cast = .EnumToInt;
					else if (from.IsInteger && to.IsEnum)
						b.Cast = .IntToEnum;
					else if (from.IsReference && to.IsReference)
						b.Cast = .Class;
					else if (from.IsValue && to.Kind == .Named && to.Sym == T.ObjectSym)
						b.Cast = .Box;
					else if (from.IsReference && to.IsValue)
						b.Cast = .Unbox;
				default:
					Err(b, "", "T2150", scope $"'{kind}' is not a Cast kind (numeric, class, unchecked, box, unbox)");
				}
				switch (b.Cast)
				{
				case .Numeric:
					if (from.IsEnum && to.IsInteger)
						b.Cast = .EnumToInt;
					else if (from.IsInteger && to.IsEnum)
						b.Cast = .IntToEnum;
					else if (!((from.IsNumeric || from.Kind == .Char) && (to.IsNumeric || to.Kind == .Char)))
						Err(b, "value", "T2151", scope $"a Numeric Cast converts numbers, not a {S!(from)} to {S!(to)}");
				case .Class:
					if (!from.IsReference || !(to.IsClass || to.IsInterface))
						Err(b, "value", "T2152", scope $"a Class Cast converts between classes and interfaces, not a {S!(from)} to {S!(to)}");
				case .Box:
					if (!from.IsValue)
						Err(b, "value", "T2153", "Box takes a value (a struct, an enum, a number)");
					if (!b.Flow)
						Err(b, "", "T2154", "Box allocates: it is a flow node (set kind box)");
				case .Unbox:
					if (!from.IsReference || !to.IsValue)
						Err(b, "value", "T2155", "Unbox takes an Object and gives a value");
				case .None:
					Err(b, "value", "T2156", scope $"there is no Cast from {S!(from)} to {S!(to)}");
				default:
				}
			}
			b.AddIn("value", inType, false, "Value");
			if (b.Checked)
			{
				// Succeeded (`then`) runs with Result, Failed when the object is not a T (or null), or
				// for `T?` to `T` when the value is null.
				if (b.Cast != .Class && b.Cast != .Unwrap && from != null && !from.IsError && !to.IsError)
					Err(b, "", "T2157", scope $"a checked Cast is a Class Cast (classes and interfaces) or a T? to T, not a {S!(from)} to {S!(to)}");
				b.AddFlowOut("failed");
				b.AddOut("result", to, "then");
				return;
			}
			b.AddOut("result", to);
		}

		void BindMake(BNode b)
		{
			let n = b.Node;
			b.Flow = false;
			let t = c.Resolve(n.SubjectType, Ctx(b)) ?? T.Error;
			b.Subject = t;
			if (TryBindVectorMake(b, t)) // BindVector.bf: one pin per lane
				return;
			let isMake = n.Kind == .Make;
			if (t.IsError)
			{
				AddLooseValues(b);
				if (isMake && b.FindOut("value") == null)
					b.AddOut("value", t);
				return;
			}
			if (t.Kind == .Tuple)
			{
				// Tuple elements are pins item0, item1, ... (Language.md 2.1).
				if (isMake)
				{
					for (int i < t.Args.Count)
						b.AddIn(scope $"item{i}", t.Args[i], true, scope $"Item {i}");
					b.AddOut("value", t);
				}
				else
				{
					b.AddIn("value", t, false, "Value");
					for (int i < t.Args.Count)
						b.AddOut(scope $"item{i}", t.Args[i]);
				}
				return;
			}
			if (!t.IsStruct)
			{
				Err(b, "", "T2160", scope $"{(isMake ? "Make" : "Break")} works on structs and tuples, not on {S!(t)}");
				AddLooseValues(b);
				return;
			}
			Dictionary<GenericParamSym, KType> map = scope .();
			T.MapOf(t, map);
			if (isMake)
			{
				for (let f in t.Sym.AllFields)
				{
					if (f.Synthetic)
						continue;
					CheckAccess(b, f);
					b.AddIn(f.Name, T.Subst(f.Type, map), true, f.Name);
				}
				b.AddOut("value", t);
			}
			else
			{
				b.AddIn("value", t, false, "Value");
				for (let f in t.Sym.AllFields)
					if (!f.Synthetic)
						b.AddOut(f.Name, T.Subst(f.Type, map));
			}
		}

		void BindCase(BNode b)
		{
			let n = b.Node;
			b.Flow = false;
			let dot = NodeFactory.LastTopLevelDot(n.Text);
			if (dot <= 0)
			{
				Err(b, "", "T2170", scope $"'{n.Text}' is not Enum.Case");
				AddLooseValues(b);
				return;
			}
			let tr = TypeRef.Parse(n.Text.Substring(0, dot));
			defer delete tr;
			let t = c.Resolve(tr, Ctx(b)) ?? T.Error;
			let caseName = n.Text.Substring(dot + 1);
			b.Subject = t;
			if (t.IsError)
			{
				AddLooseValues(b);
				return;
			}
			if (!t.IsEnum)
			{
				Err(b, "", "T2171", scope $"{S!(t)} is not an enum");
				AddLooseValues(b);
				return;
			}
			if (TypeTable.IsOpen(t) && t.Sym != r.Type)
			{
				Err(b, "", "T2172", scope $"name the generic arguments: {t.Sym.Name}<...>.{caseName}");
			}
			let cs = t.Sym.FindCase(caseName);
			if (cs == null)
			{
				Err(b, "", "T2173", scope $"{S!(t)} has no case {caseName}");
				AddLooseValues(b);
				return;
			}
			b.Case = cs;
			Dictionary<GenericParamSym, KType> map = scope .();
			T.MapOf(t, map);
			if (n.Kind == .MakeCase)
			{
				for (let p in cs.Payload)
					b.AddIn(p.Name, T.Subst(p.Type, map), false, p.Name);
				b.AddOut("value", t);
			}
			else
			{
				b.AddIn("value", t, false, "Value");
				b.AddOut("result", T.Bool);
				for (let p in cs.Payload)
					b.AddOut(p.Name, T.Subst(p.Type, map));
			}
		}

		void BindIndex(BNode b)
		{
			b.Flow = false;
			let ct = InType(b, "collection");
			KType et = T.Error;
			KType it = T.Int;
			if (ct != null && !ct.IsError)
			{
				if (ct.Kind == .Pointer)
				{
					et = ct.Element;
					b.Unsafe = true;
				}
				else
				{
					let e = ElementOf(ct);
					// A type with an operator [] (the core's List and Dictionary): a call of it.
					let user = (e == null) ? c.FindUserOperator(ct, "[]") : null;
					if (user != null && user.Params.Count == 2)
					{
						b.Member = user;
						b.Owner = ct;
						b.Map = new .();
						T.MapOf(ct, b.Map);
						et = T.Subst(user.Returns, b.Map);
						it = T.Subst(user.Params[1].Type, b.Map);
						CheckAccess(b, user);
					}
					else if (e == null)
						Err(b, "collection", "T2180", scope $"Collection: Get [ ] reads arrays, spans, strings, pointers and types with an operator [ ], not a {S!(ct)}");
					else
						et = e;
				}
			}
			b.AddIn("collection", ct ?? T.Error, false, "Collection");
			b.AddIn("index", it, false, "Index");
			b.AddOut("value", et);
		}

		/// `set alloc` of a Bind or Lambda node: Pointer when none is set (or `pointer`).
		DelegateAlloc AllocOf(BNode b)
		{
			StringView alloc = b.Node.GetSetting("alloc");
			switch (alloc)
			{
			case "construct": return .Construct;
			case "local": return .Local;
			case "", "pointer": return .Pointer;
			default:
				Err(b, "", "T2196", scope $"'{alloc}' is not an Allocation (construct, local or pointer)");
				return .Construct;
			}
		}

		/// Bind Function (Language.md 4.2): a function pointer of a static function (a value node),
		/// or a delegate object of any function (static, member, virtual, interface) made on the
		/// heap (Construct) or in the node's region (Local), a flow node then.
		void BindDelegate(BNode b)
		{
			let n = b.Node;
			let mr = MemberRef.Parse(n.Text);
			defer delete mr;
			b.Alloc = AllocOf(b);
			bool open = false;
			let owner = OwnerOf(b, mr, out open);
			if (b.Flow)
			{
				b.AddIn("in", null);
				b.AddFlowOut("then");
			}
			if (owner == null || owner.IsError || owner.Kind != .Named)
			{
				if (owner == null || (!owner.IsError && owner.Kind != .Named))
					Err(b, "", "T2190", scope $"'{n.Text}' names no function");
				b.AddOut("value", T.Error);
				return;
			}
			List<(MemberSym m, KType inst)> cands = scope .();
			FindFunctions(owner, mr.Name, cands);
			if (cands.IsEmpty)
			{
				Err(b, "", "T2191", scope $"{S!(owner)} has no function {mr.Name}");
				b.AddOut("value", T.Error);
				return;
			}
			(MemberSym m, KType inst) best = cands[0];
			if (mr.HasSignature)
			{
				List<KType> sig = scope .();
				for (let pt in mr.ParamTypes)
					sig.Add(c.Resolve(pt, Ctx(b)) ?? T.Error);
				best = (null, null);
				for (let cand in cands)
				{
					if (cand.m.Params.Count != sig.Count)
						continue;
					Dictionary<GenericParamSym, KType> map = scope .();
					T.MapOf(cand.inst, map);
					bool same = true;
					for (int i < sig.Count)
						same &= sig[i].IsError || T.Subst(cand.m.Params[i].Type, map) == sig[i];
					if (same)
					{
						best = cand;
						break;
					}
				}
				if (best.m == null)
				{
					Err(b, "", "T2192", scope $"{S!(owner)} has no function {mr.Name} with these parameters");
					b.AddOut("value", T.Error);
					return;
				}
			}
			else if (cands.Count > 1)
				Err(b, "", "T2192", scope $"{mr.Name} has several overloads: name the parameters ({mr.Name}(int))");
			let f = best.m;
			b.Member = f;
			CheckAccess(b, f);
			b.Map = new .();
			T.MapOf(best.inst, b.Map);
			b.Owner = best.inst;
			List<KType> ps = scope .();
			for (let p in f.Params)
			{
				ps.Add(T.Subst(p.Type, b.Map));
				if (p.Mode != .Value && p.Mode != .Unset)
					Err(b, "", "T2195", scope $"{f.Name} takes {p.Name} by reference: a delegate passes its inputs by value");
			}
			if (!f.Outs.IsEmpty)
				Err(b, "", "T2195", scope $"{f.Name} has further outputs: a delegate gives one result");
			if (f.IsGeneric)
				Err(b, "", "T2195", scope $"{f.Name} is generic: bind one instance through a function that calls it");
			let ret = T.Subst(f.Returns, b.Map);
			if (b.Alloc == .Pointer)
			{
				if (!f.Static)
					Err(b, "", "T2193", scope $"{f.Name} works on an object: set Allocation (construct or local) to make a delegate (a function pointer takes a static function)");
				b.AddOut("value", T.Func(false, ret, ps));
				return;
			}
			if (f.IsImport)
				Err(b, "", "T2195", scope $"{f.Name} is a C function: bind it as a function pointer (no Allocation)");
			if (f.IsInstance)
				b.Owner = BindReceiver(b, f, best.inst, open, true);
			if (f.IsInstance && (f.Owner.Kind == .Struct || f.Owner.Kind == .Enum))
				BindStructTarget(b, f);
			b.AddOut("value", T.Func(true, ret, ps));
		}

		/// Bind Function of a struct's (or an enum's) function (Language.md 4.2): the delegate holds
		/// the struct's address, not a copy, so the function sees and changes the variable itself.
		/// A variable of this function (a local, a parameter, `this` of a struct function) dies with
		/// the function: the delegate must be Local (T2217). A field of an object or a static field
		/// may be held by a heap delegate (it must not outlive the object, as any reference). A value
		/// that is not a variable is copied into a temporary first, which a struct with a destructor
		/// allows only when it is Copyable (T2218); the delegate is then Local too.
		void BindStructTarget(BNode b, MemberSym f)
		{
			b.StructTarget = true;
			let t = b.Owner;
			StringView lives = "";
			if (b.ReceiverIsThis)
				lives = "this (the struct a struct function works on)";
			else
			{
				InType(b, "receiver");
				let src = SourceNode(b, "receiver");
				if (src == null)
					return;
				if (src.Kind == .Get && (src.Var == .Field || src.Var == .StaticField))
					return;
				if (src.Kind == .Get && (src.Var == .Local || src.Var == .Param || src.Var == .OutParam))
					lives = (src.Var == .Local) ? "a local variable" : "a parameter";
				else
				{
					if (t != null && t.Kind == .Named && t.Sym.Dtor != null && !SheetChecker.IsCopyable(t.Sym))
					{
						Err(b, "receiver", "T2218", scope $"Receiver: {t.Sym.Name} has a destructor: binding {f.Name} to a value would copy it bit for bit (destroyed twice or never): wire a variable, or mark {t.Sym.Name} Copyable");
						return;
					}
					lives = "a copy of the value in this function";
				}
			}
			if (b.Alloc != .Local)
				Err(b, "receiver", "T2217", scope $"Receiver: the delegate holds the address of {lives}, which dies with the function: make the delegate Local (Allocation local)");
		}

		/// A Lambda node (Language.md 4.2): its nested Sheet is the delegate's body. A Lambda of a
		/// delegate type is a closure object (heap or Local, a flow node); one of a function type is
		/// a function pointer (a value node, no captures).
		void BindLambda(BNode b)
		{
			let n = b.Node;
			b.Alloc = AllocOf(b);
			if (b.Flow)
			{
				b.AddIn("in", null);
				b.AddFlowOut("then");
				if (b.Alloc == .Pointer)
					b.Alloc = .Construct;
			}
			KType lt = null;
			StringView typeText = n.GetSetting("type");
			if (!typeText.IsEmpty)
			{
				let tr = TypeRef.Parse(typeText);
				defer delete tr;
				lt = c.Resolve(tr, Ctx(b));
			}
			if (lt == null)
			{
				Err(b, "", "T2197", "Lambda: set its Type in Properties: the delegate it gives (delegate:int(int)), or a function pointer type (function:int(int)) for a C callback");
				lt = T.Error;
			}
			else if (!lt.IsError && lt.Kind != .Delegate && lt.Kind != .Function)
			{
				Err(b, "", "T2197", scope $"Lambda: {S!(lt)} is not a delegate or function pointer type");
				lt = T.Error;
			}
			b.AddOut("value", lt);
			Sheet ls = null;
			for (let s in r.Unit.Doc.Sheets)
				if (s.Role == .Lambda && s.LambdaNode == n.Key && s.Member == r.Sheet.Member)
					ls = s;
			if (ls == null)
			{
				Err(b, "", "T2199", "the Lambda has no Sheet (its body): double-click it to make one");
				return;
			}
			b.LambdaSheet = c.ResultOf(ls) ?? c.BindSheet(r.Unit, ls);
			if (b.LambdaSheet == null || lt.IsError)
				return;
			let caps = b.LambdaSheet.Captures;
			if (lt.Kind == .Function)
			{
				if (b.Flow)
					Err(b, "", "T2198", "Lambda: a function pointer allocates nothing: remove its Allocation and capture lines");
				for (let cap in caps)
				{
					Err(b, "", "T2198", scope $"Lambda: a function pointer cannot capture, and its Sheet reads {(cap.What == .This) ? "this" : (StringView)cap.Name}: give it a delegate type");
					break;
				}
				return;
			}
			if (!b.Flow)
			{
				Err(b, "", "T2198", "Lambda: a delegate is an object: set Allocation (construct or local) in Properties");
				return;
			}
			for (let cap in caps)
				if (cap.ByRef && b.Alloc != .Local)
					Err(b, "", "T2198", scope $"Lambda: {cap.Name} is captured by reference: only a Local Lambda (freed with its region) may do that");
			// Inside a Lambda Sheet the function's locals, inputs and `this` (and the inputs of
			// Lambdas further out) are this Sheet's captures too: the inner closure is filled from
			// this one's fields. By reference only through a by-reference capture (or an input of
			// this Lambda), so the variable written is the function's own.
			if (r.IsLambda)
				for (let cap in caps)
				{
					if (cap.What == .Param && r.FindLambdaParam(cap.Name) != null)
						continue;
					let outer = AddCapture(null, cap.What, cap.Name, cap.Type);
					if (cap.ByRef && !outer.ByRef)
						Err(b, "", "T2198", scope $"Lambda: {cap.Name} is captured by reference here but by value by the Lambda around it: capture it by reference there too (a Local Lambda), or by value here");
				}
			b.Closure = c.ClosureType(r.Scope ?? r.Type, n.Key);
		}

		/// Invoke (Language.md 4.2): calls a delegate or a function pointer (the latter is an unsafe
		/// node, Language.md 2.7). The arguments are the inputs `arg0`, `arg1`, ... (other names in
		/// pin order after them).
		void BindInvoke(BNode b)
		{
			let n = b.Node;
			b.Flow = true;
			b.AddIn("in", null);
			b.AddFlowOut("then");
			let dt = InType(b, "delegate");
			b.AddIn("delegate", dt ?? T.Error, false, "Delegate");
			if (dt == null || dt.IsError)
			{
				AddLooseValues(b);
				return;
			}
			let sig = dt;
			if (sig.Kind != .Delegate && sig.Kind != .Function)
			{
				Err(b, "delegate", "T2200", scope $"Delegate: {S!(dt)} is not a delegate or a function pointer");
				AddLooseValues(b);
				return;
			}
			if (sig.Kind == .Function)
				b.Unsafe = true;
			List<StringView> names = scope .();
			for (let p in n.Inputs)
				if (p.Kind == .Value && p.Name != "delegate")
					names.Add(p.Name);
			SortArgNames(names, "arg");
			int i = 0;
			for (let name in names)
			{
				if (i < sig.Args.Count)
					b.AddIn(name, sig.Args[i], false, name);
				else
					Err(b, name, "T2201", scope $"the delegate takes {sig.Args.Count} inputs");
				i++;
			}
			for (int k = i; k < sig.Args.Count; k++)
				b.AddIn(scope $"arg{k}", sig.Args[k], false, scope $"arg{k}");
			if (!sig.Element.IsVoid)
				b.AddOut("result", sig.Element);
		}

		/// Orders pin names `<prefix>0`, `<prefix>1`, ... by their number (the file sorts wires by
		/// name, so `arg10` would come before `arg2`); other names keep their order after them.
		static void SortArgNames(List<StringView> names, StringView prefix)
		{
			List<(int num, int at, StringView name)> keyed = scope .();
			for (let s in names)
			{
				int num = int.MaxValue;
				if (s.StartsWith(prefix) && int.Parse(s.Substring(prefix.Length)) case .Ok(let v))
					num = v;
				keyed.Add((num, @s.Index, s));
			}
			keyed.Sort(scope (a, b) => (a.num != b.num) ? (a.num <=> b.num) : (a.at <=> b.at));
			names.Clear();
			for (let k in keyed)
				names.Add(k.name);
		}

		// ------------------------------------------------------------------ inputs

		/// The node's Receiver is this: unwired in a member Sheet, or wired from a This node.
		bool ReceiverIsThisValue(BNode b)
		{
			if (b.ReceiverIsThis)
				return true;
			let p = b.Node.FindInput("receiver");
			let l = (p != null) ? r.Graph.FindLinkTo(p) : null;
			let src = (l != null) ? r.Get(l.From.Owner) : null;
			return src != null && src.Kind == .This;
		}

		/// After binding: every input's wire or literal against its type, pins the node does not
		/// have, and missing inputs.
		void CheckPins(BNode b)
		{
			let n = b.Node;
			if (n.Disabled || b.Unsupported && n.Kind == .Unknown)
				return;
			for (let p in n.Inputs)
			{
				if (p.Name == "in" && p.Kind == .Flow)
				{
					if (!b.Flow && r.Graph.IsLinked(p))
						Err(b, "in", "T2220", "this node has no flow input: it is a value node");
					continue;
				}
				if (p.Kind == .Flow)
					continue;
				if (b.FindIn(p.Name) == null && (r.Graph.IsLinked(p) || !p.Default.IsEmpty))
					Err(b, p.Name, "T2221", scope $"this node has no input '{p.Name}'");
			}
			for (let p in n.Outputs)
			{
				if (!r.Graph.IsLinked(p))
					continue;
				if (p.Kind == .Flow)
				{
					if (!b.HasFlowOut(p.Name))
						Err(b, p.Name, "T2222", scope $"this node has no flow output '{p.Name}'");
				}
				else if (b.FindOut(p.Name) == null)
					Err(b, p.Name, "T2223", scope $"this node has no output '{p.Name}'");
			}
			if (b.Kind == .Call && b.EventOp == .None && b.Member != null && b.Member.Mutating && !b.Member.Static && b.Owner != null && b.Owner.IsStruct &&
				r.Type.Kind == .Struct && !r.IsLambda && r.Member != null && r.Member.Kind != .Ctor && !r.Member.Mutating && ReceiverIsThisValue(b))
			{
				// Beef refuses it too: this is read-only in a function that is not Mutating
				Err(b, "receiver", "T2273", scope $"Receiver: {r.Member.Name} is not Mutating, so this is read-only: it cannot call {b.Member.Name}, which is Mutating (make {r.Member.Name} Mutating, or Store this in a local and call it on that)");
			}
			for (let spec in b.Ins)
			{
				if (spec.Type == null)
					continue; // the flow input
				let p = spec.Pin;
				let l = (p != null) ? r.Graph.FindLinkTo(p) : null;
				if (l != null)
				{
					let src = r.Get(l.From.Owner);
					let o = src?.FindOut(l.From.Name);
					if (o == null || o.Type == null)
						continue;
					String why = scope .();
					if (T.CanConvert(o.Type, spec.Type, why, true) == .Refused)
						Err(b, spec.Name, "T2230", scope $"{spec.Label}: cannot take {TypeTable.WithArticle(o.Type, .. scope .())}: {why}");
					else if (spec.IsRef && src.Kind == .This && (spec.Type.IsStruct || spec.Type.IsEnum) && (r.Member == null || (!r.Member.Mutating && r.Member.Kind != .Ctor)))
						Err(b, spec.Name, "T2231", scope $"{spec.Label} is passed by ref: this is read-only in a function that is not Mutating (make it Mutating, or Store this in a local first)");
					else if (spec.IsRef && !(src.Kind == .Get && src.Var != .Property && src.Var != .None) && !(src.Kind == .This && (spec.Type.IsStruct || spec.Type.IsEnum)))
						Err(b, spec.Name, "T2231", scope $"{spec.Label} is passed by ref: it needs a variable (Make local variable)");
					else if (spec.IsRef && !b.IsAddressArg(spec.Name) && src.Kind == .Get && src.Member != null && src.Member.Const)
						Err(b, spec.Name, "T2231", scope $"{spec.Label} is passed by ref: {src.Member.Name} is a constant, which nothing changes (Make local variable)");
					else if (spec.IsReceiver && b.Kind == .Call && b.EventOp == .None && b.Member != null && b.Member.Mutating && !b.Member.Static
						&& spec.Type.IsStruct && !r.IsPlace(src, l.From.Name))
						Err(b, spec.Name, "T2272", scope $"Receiver: cannot mutate a temporary: {b.Member.Name} is Mutating and the Receiver is a value, not a variable (the change would be lost); Store in a local first, or wire a variable");
					continue;
				}
				if (p != null && !p.Default.IsEmpty)
				{
					String why = scope .();
					if (spec.IsRef)
						Err(b, spec.Name, "T2231", scope $"{spec.Label} is passed by ref: it needs a variable, not a literal");
					else if (!Literals.Fits(PinLiteral(b, p), spec.Type, T, why))
						Err(b, spec.Name, "T2232", scope $"{spec.Label}: {why}");
					continue;
				}
				if (!spec.Optional)
				{
					// Same words as the generic graph check, so the editor shows it once.
					c.Diags.Add(.Error, .Check, "T3010", r.Site, b.Key, spec.Name, scope $"'{(p != null && !p.Label.IsEmpty) ? (StringView)p.Label : (StringView)spec.Label}' needs a value or a wire.");
					r.HasErrors = true;
				}
			}
		}
	}
}
