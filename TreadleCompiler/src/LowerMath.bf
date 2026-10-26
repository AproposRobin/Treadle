using System;
using System.Collections;

namespace Treadle.Compiler
{
	/// Lowering of a Math Expression (Language.md 5.6) to the ops its equivalent nodes make (an
	/// Operator node per operator, a Select per `? :`, a pure Call per function, a Break per field)
	/// and of a constant's Get (Language.md 4.6).
	extension FnLowerer
	{
		IRValue MathNodeValue(BNode n)
		{
			let tree = n.MathTree;
			let o = n.FindOut("result");
			let want = (o != null && o.Type != null && !o.Type.IsError) ? Sub(o.Type) : T.Int;
			if (tree == null || tree.Type == null || tree.Type.IsError)
				return E.Const("zero", want, n.Key, "result");
			let v = MathValue(n, tree, true);
			return Convert(v, Sub(tree.Type), want, n.Key, "result");
		}

		/// The value of `m` converted to `to` (an operand of its parent).
		IRValue MathAs(BNode n, MathNode m, KType to)
		{
			let v = MathValue(n, m, false);
			return Convert(v, Sub(m.Type), Sub(to), n.Key, "result");
		}

		/// The slot of a `? :` or `&&` / `||`: the node's `result` for the expression itself, `t<pos>`
		/// for one inside it.
		IRSlot MathSlot(BNode n, MathNode m, bool root, KType t)
		{
			if (root)
				return Slot(n, "result", t, .OutTemp);
			return Slot(n, scope String()..AppendF("t{}", m.Pos + 1), t, .OutTemp);
		}

		IRValue MathValue(BNode n, MathNode m, bool root)
		{
			let key = n.Key;
			let t = Sub(m.Type);
			switch (m.Kind)
			{
			case .Number:
				// a hexadecimal integer as its decimal value (the op's literal is decimal)
				if ((m.Text.Contains('x') || m.Text.Contains('X')) && Literals.Classify(m.Text, var i, var f) == .Int)
					return E.Const(scope $"{i}", t, key, "result");
				return E.Const(m.Text, t, key, "result");
			case .Bool:
				return E.Const(m.Text, t, key, "result");
			case .Case:
				return E.Const(scope $".{m.Text}", t, key, "result");
			case .Text:
				return Literal(m.Text, t, key, "result");
			case .Name:
				var v = EvalIn(n, m.Root);
				if (m.Fields != null)
					for (let f in m.Fields)
					{
						Dictionary<GenericParamSym, KType> map = scope .();
						T.MapOf(f.owner, map);
						v = MathField(v, f.field, Sub(f.owner), Sub(T.Subst(f.field.Type, map)), key);
					}
				if (m.Lanes != null && !m.Lanes.IsEmpty)
					v = Pick(v, null, m.Lanes, t, key, "result"); // `v.zyx` (LowerVector.bf)
				return v;
			case .Call:
				if (m.VecMake || m.VecFn != .None)
					return MathVector(n, m); // LowerVector.bf: `float4(...)`, Math functions on vectors
				return MathCall(n, m, m.Args);
			case .Unary:
				let operand = Sub(m.Operand);
				let a = MathAs(n, m.A, m.Operand);
				let op = (m.Text == "-") ? "neg" : (StringView)m.Text;
				return Operate(op, operand, a, null, t, key, "result");
			case .Binary:
				if (m.Text == "**")
					return (m.VecFn != .None) ? MathVector(n, m) : MathCall(n, m, m.Args); // a vector power: LowerVector.bf
				if (m.Text == "&&" || m.Text == "||")
					return MathLogic(n, m, root);
				let operand = Sub(m.Operand);
				if (m.Member != null && m.Member.Kind == .Operator && m.Member.Params.Count == 2 && m.Owner != null)
				{
					// a user operator with inputs of two types (Vec3 * float): each side as its input takes it
					Dictionary<GenericParamSym, KType> map = scope .();
					T.MapOf(m.Owner, map);
					let p0 = T.Subst(m.Member.Params[0].Type, map);
					let p1 = T.Subst(m.Member.Params[1].Type, map);
					if (p0 != p1)
						return Operate(m.Text, operand, MathAs(n, m.A, p0), MathAs(n, m.B, p1), t, key, "result");
				}
				let a = MathAs(n, m.A, m.Operand);
				// a shift count keeps its own type (as the Operator node's `b` does)
				let b = (m.Text == "<<" || m.Text == ">>") ? MathValue(n, m.B, false) : MathAs(n, m.B, m.Operand);
				return Operate(m.Text, operand, a, b, t, key, "result");
			case .Ternary:
				if (m.A.Type != null && m.A.Type.IsMask)
					return MathMaskSelect(n, m); // LowerVector.bf: per lane
				return MathSelect(n, m, root);
			case .Swizzle:
				return Pick(MathValue(n, m.A, false), null, m.Lanes, t, key, "result"); // LowerVector.bf: `(a + b).xy`
			}
		}

		/// `a.x`: a struct's field from the value, a class's through the reference (null-checked).
		IRValue MathField(IRValue recv, MemberSym f, KType owner, KType ft, StringView key)
		{
			if (owner.IsStruct && recv.Type.Kind != .Pointer)
			{
				if (owner.Sym.CBlob)
					return BlobRead(recv, f, key, "result");
				let ex = E.Op(.Extract, ft, key, "result");
				ex.Operands.Add(recv);
				ex.Index = f.FieldIndex;
				return ex;
			}
			let a = FieldAddr(recv, f, ft, key, "result", true);
			let ld = E.Op(.Load, ft, key, "result");
			ld.Operands.Add(a);
			return ld;
		}

		/// A Math function (a pure Call node of it): the inputs converted to its parameters.
		IRValue MathCall(BNode n, MathNode m, List<MathNode> args)
		{
			let f = m.Member;
			if (f == null)
				return E.Const("zero", Sub(m.Type), n.Key, "result");
			Dictionary<GenericParamSym, KType> map = scope .();
			List<KType> margs = null;
			if (m.MethodArgs != null)
			{
				margs = scope:: .();
				for (int i < Math.Min(f.Generics.Count, m.MethodArgs.Count))
				{
					map[f.Generics[i]] = m.MethodArgs[i];
					margs.Add(Sub(m.MethodArgs[i]));
				}
			}
			List<IRValue> values = scope .();
			for (int i < args.Count)
				values.Add(MathAs(n, args[i], T.Subst(f.Params[i].Type, map)));
			return Invoke(f, Sub(m.Owner), margs, .Body, values, Sub(m.Type), n.Key, "result", false);
		}

		/// `a && b`, `a || b` as the And / Or Operator node: B only when A does not decide.
		IRValue MathLogic(BNode n, MathNode m, bool root)
		{
			let key = n.Key;
			let isAnd = m.Text == "&&";
			let a = MathAs(n, m.A, T.Bool);
			let slot = MathSlot(n, m, root, T.Bool);
			StoreSlot(slot, a, key, "result");
			let bB = F.NewBlock(key);
			let join = F.NewBlock(key);
			E.Block.Term = .CondBr;
			E.Block.Cond = a;
			E.Block.Targets.Add(isAnd ? bB : join);
			E.Block.Targets.Add(isAnd ? join : bB);
			E.Block = bB;
			WithFreshMemo(scope [&]() =>
			{
				StoreSlot(slot, MathAs(n, m.B, T.Bool), key, "result");
			});
			E.Br(join);
			E.Block = join;
			return LoadSlot(slot, key, "result");
		}

		/// `c ? a : b` as a Select: only the chosen arm is made.
		IRValue MathSelect(BNode n, MathNode m, bool root)
		{
			let key = n.Key;
			let t = Sub(m.Operand ?? m.Type);
			let c = MathAs(n, m.A, T.Bool);
			let slot = MathSlot(n, m, root, t);
			let bYes = F.NewBlock(key);
			let bNo = F.NewBlock(key);
			let join = F.NewBlock(key);
			E.Block.Term = .CondBr;
			E.Block.Cond = c;
			E.Block.Targets.Add(bYes);
			E.Block.Targets.Add(bNo);
			for (int arm < 2)
			{
				E.Block = (arm == 0) ? bYes : bNo;
				WithFreshMemo(scope [&]() =>
				{
					StoreSlot(slot, MathAs(n, (arm == 0) ? m.B : m.C, m.Operand ?? m.Type), key, "result");
				});
				E.Br(join);
			}
			E.Block = join;
			return LoadSlot(slot, key, "result");
		}

		/// A parameter's value: an `in` or `ref` parameter is passed as its address, so reading it
		/// loads through that.
		IRValue ByRefParamValue(IRValue pv, StringView name, StringView node, StringView pin)
		{
			let p = R.IsLambda ? null : R.Member.FindParam(name);
			if (p == null || (p.Mode != .In && p.Mode != .Ref) || pv.Type.Kind != .Pointer)
				return pv;
			let ld = E.Op(.Load, pv.Type.Element, node, pin);
			ld.Operands.Add(pv);
			return ld;
		}

		// ------------------------------------------------------------------ constants

		/// A constant's Get: its folded value (a text on a String is a Local String, as a text
		/// literal is); a const array: a `Span<T>` over its read-only global.
		IRValue ConstValue(BNode n, KType t)
		{
			let m = n.Member;
			let key = n.Key;
			if (m.ConstElements != null)
			{
				let owner = Sub(n.Owner ?? m.Owner.Self, n);
				let et = Sub(m.ConstElement);
				String name = scope .();
				M.ConstGlobal(m, owner, name);
				let ga = E.Op(.GlobalAddr, T.Pointer(T.FixedArray(et, m.ConstElements.Count)), key, "value");
				ga.Global = new String(name);
				let ptr = E.Op(.Cast, T.Pointer(et), key, "value");
				ptr.Operands.Add(ga);
				M.Need(t);
				let len = E.Const(scope $"{m.ConstElements.Count}", T.Int, key, "value");
				let span = E.Op(.Make, t, key, "value");
				span.Operands.Add(ptr);
				span.Operands.Add(len);
				return span;
			}
			if (m.ConstValue == null)
				return E.Const("zero", t, key, "value");
			return Literal(m.ConstValue, t, key, "value");
		}

		/// The address of a constant wired into an `in` or a C `T*` input: its read-only global
		/// (null for a String constant, which is an object made where it is read).
		IRValue ConstAddr(BNode src, KType t, StringView node, StringView pin)
		{
			if (t.Kind == .Named && t.Sym == T.StringSym)
				return null;
			let owner = Sub(src.Owner ?? src.Member.Owner.Self, src);
			String name = scope .();
			M.ConstGlobal(src.Member, owner, name);
			let ga = E.Op(.GlobalAddr, T.Pointer(t), node, pin);
			ga.Global = new String(name);
			return ga;
		}
	}

	extension ProgramLowerer
	{
		/// The read-only global of a constant (`global <Owner>.<Name> T const <value>`, a const
		/// array's `T[N]` with its elements), declared in its type's unit the first time a Sheet
		/// needs it: a const array's Get, a constant's address.
		public void ConstGlobal(MemberSym m, KType owner, String outName)
		{
			KirWriter.Type(owner, outName);
			outName.AppendF(".{}", m.Name);
			if (mConstGlobalNames.ContainsAlt(outName))
				return;
			mConstGlobalNames.Add(new String(outName));
			String line = scope .();
			line.AppendF("\nglobal {} ", outName);
			if (m.ConstElements != null)
			{
				KirWriter.Type(T.FixedArray(m.ConstElement, m.ConstElements.Count), line);
				line.Append(" const");
				for (let e in m.ConstElements)
					line.AppendF(" {}", e);
			}
			else
			{
				KirWriter.Type(m.Type, line);
				line.AppendF(" const {}", m.ConstValue);
			}
			line.Append('\n');
			let ownerName = m.Owner.FullName;
			if (!mConstGlobals.TryGetValueAlt(ownerName, let text))
			{
				mConstGlobals[new String(ownerName)] = new String(line);
				return;
			}
			text.Append(line);
		}
	}
}
