using System;
using System.Collections;
using Treadle.Graph;

namespace Treadle.Compiler
{
	/// The Math Expression node's typing (Language.md 5.6): every name is an input, typed by its
	/// wire, else by its literal, else by what the expression does with it.
	class MathNodeTyper : ExprTyper
	{
		SheetBinder mB;
		BNode mNode;
		/// The inputs a pass gave a type (unwired ones, by what they meet).
		public Dictionary<String, KType> PinTypes = new .() ~ DeleteDictionaryAndKeys!(_);

		public this(Compilation comp, SheetBinder b, BNode node, MemberSym ctxMember) : base(comp)
		{
			mB = b;
			mNode = node;
			mCtxMember = ctxMember;
		}

		protected override void Problem(MathNode at, ExprProblem kind, StringView message)
		{
			StringView code;
			switch (kind)
			{
			case .Function: code = "T2212";
			case .Name: code = "T2213";
			case .Literal: code = "T2214";
			case .Mask: code = "T2300";
			case .Lanes: code = "T2301";
			case .Vector: code = "T2320";
			default: code = "T2211";
			}
			mB.MathProblem(mNode, code, message);
		}

		protected override void BindName(MathNode n) => mB.MathName(this, mNode, n);

		protected override void TakeType(MathNode n, KType t)
		{
			n.Type = t;
			let root = n.Root;
			if (!PinTypes.ContainsKeyAlt(root))
				PinTypes[new String(root)] = t;
		}

		protected override void UsesFunction(MemberSym f, List<KType> methodArgs) => mB.MathUsesFunction(mNode, f, methodArgs);
		protected override void UsesType(KType t) => mB.MathUsesType(mNode, t);

		public void FailAt(MathNode at, ExprProblem kind, StringView message) => Fail(at, kind, message);
	}

	extension SheetBinder
	{
		public void MathProblem(BNode b, StringView code, StringView message) => Err(b, "", code, scope $"Math Expression: {message}");
		public void MathUsesFunction(BNode b, MemberSym f, List<KType> methodArgs) => c.Instances.AddFunction(f, methodArgs, r.SiteType, b.Key);
		public void MathUsesType(BNode b, KType t) => c.Instances.AddType(t, r.SiteType, b.Key);

		/// A name of the expression: the input it starts with (wired: the wire's type; a literal:
		/// the literal's type, which follows the other side; nothing: free until something types it),
		/// then the fields the path reads (`a.x`, of a struct or a class).
		public void MathName(MathNodeTyper ty, BNode b, MathNode n)
		{
			let root = n.Root;
			DeleteAndNullify!(n.Fields);
			DeleteAndNullify!(n.Lanes);
			n.Member = null;
			KType t = InType(b, root);
			let hasFields = n.Text.Length > root.Length;
			if (t != null)
				n.Adopts = false;
			else
			{
				n.Adopts = !hasFields;
				if (ty.PinTypes.TryGetValueAlt(root, let given))
					t = given;
				else
				{
					let lit = Lit(b, root);
					if (!lit.IsEmpty)
						t = Literals.TypeOf(lit, T);
				}
			}
			if (!hasFields)
			{
				n.Type = t;
				return;
			}
			if (t == null)
			{
				ty.FailAt(n, .Name, scope $"{root}: its fields are read, so it needs a wire");
				n.Type = T.Error;
				return;
			}
			n.Fields = new .();
			var path = n.Text.Substring(root.Length + 1);
			for (let seg in path.Split('.'))
			{
				if (t.IsError)
					break;
				if (t.IsVector)
				{
					// `v.zyx`: the lanes of a vector input (BindVector.bf)
					t = ty.SwizzleOf(n, t, seg);
					continue;
				}
				if (t.Kind != .Named || (t.Sym.Kind != .Struct && t.Sym.Kind != .Class))
				{
					ty.FailAt(n, .Name, scope $"{TypeTable.WithArticle(t, .. scope .())} has no fields ({seg})");
					t = T.Error;
					break;
				}
				MemberSym f = null;
				KType owner = null;
				var at = t;
				int guard = 0;
				while (f == null && at != null && at.Kind == .Named && guard++ < 64)
				{
					for (let m in at.Sym.Members)
						if (m.Kind == .Field && !m.Static && !m.Const && m.Name == seg)
						{
							f = m;
							owner = at;
							break;
						}
					if (f == null)
						at = T.BaseOf(at);
				}
				if (f == null)
				{
					ty.FailAt(n, .Name, scope $"{S!(t)} has no field {seg}");
					t = T.Error;
					break;
				}
				if (!CanSee(f))
				{
					ty.FailAt(n, .Name, scope $"{f.Owner.Name}.{f.Name} is not visible from {r.Type.Name}");
					t = T.Error;
					break;
				}
				n.Fields.Add((f, owner));
				Dictionary<GenericParamSym, KType> map = scope .();
				T.MapOf(owner, map);
				t = T.Subst(f.Type, map);
			}
			n.Type = t;
		}

		void BindMath(BNode b)
		{
			let n = b.Node;
			b.Flow = false;
			String expr = scope .();
			MathExpr.TextOf(n, expr);
			String why = scope .();
			DeleteAndNullify!(b.MathTree);
			let tree = MathExpr.Build(expr, why);
			if (tree == null)
			{
				Err(b, "", "T2210", scope $"Math Expression: {why}");
				// the pins it has keep their wires' types
				for (let p in n.Inputs)
					if (p.Kind == .Value)
						b.AddIn(p.Name, InOrLit(b, p.Name) ?? T.Double, false, p.Name);
				b.AddOut("result", T.Error);
				return;
			}
			List<String> names = scope .();
			defer { ClearAndDeleteItems!(names); }
			MathExpr.Collect(tree, names);
			MathNodeTyper ty = scope .(c, this, b, r.Member);
			// Passes that only find the unwired inputs' types (what they meet), until none is found.
			for (int pass < 8)
			{
				let before = ty.PinTypes.Count;
				ty.Report = false;
				ty.Failed = false;
				ty.Type(tree);
				if (ty.PinTypes.Count == before)
					break;
			}
			// An input still free (nothing types it): a double, as an unwired Operator pin would be.
			for (let name in names)
				if (InType(b, name) == null && !ty.PinTypes.ContainsKeyAlt(name) && Lit(b, name).IsEmpty)
					ty.PinTypes[new String(name)] = T.Double;
			ty.Report = true;
			ty.Failed = false;
			ty.Type(tree);
			for (let name in names)
			{
				var t = InType(b, name);
				if (t == null)
				{
					if (ty.PinTypes.TryGetValueAlt(name, let given))
						t = given;
					else
						t = Literals.TypeOf(Lit(b, name), T) ?? T.Double;
				}
				b.AddIn(name, t, false, name);
			}
			let result = tree.Type ?? T.Double;
			b.OperandType = result;
			b.MathTree = tree;
			b.AddOut("result", result);
		}
	}
}
