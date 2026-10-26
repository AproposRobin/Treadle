using System;
using System.Collections;
using Treadle.Model;
using Treadle.Graph;
using Treadle.Document;

namespace Treadle.Compiler
{
	/// Lowering of the milestone-2 flow nodes: the stateful nodes and their actions (Gate, Do
	/// Once, Do N, Flip Flop, Multi Gate; Language.md 5.1), For Each over an enumerator, Switch on
	/// text, Delete with an allocator.
	extension FnLowerer
	{
		/// A conditional branch from the current block: (taken when true, taken when false).
		(IRBlock yes, IRBlock no) Split(BNode n, IRValue cond)
		{
			let a = F.NewBlock(n.Key);
			let b = F.NewBlock(n.Key);
			E.Block.Term = .CondBr;
			E.Block.Cond = cond;
			E.Block.Targets.Add(a);
			E.Block.Targets.Add(b);
			E.Block.TermNode.Set(n.Key);
			return (a, b);
		}

		IROp Bin(StringView op, KType t, IRValue a, IRValue b, StringView node, StringView pin)
		{
			let r = E.Op(.Binop, t, node, pin);
			r.Sub = new String(op);
			r.Operands.Add(a);
			r.Operands.Add(b);
			return r;
		}

		IROp CmpOp(StringView op, IRValue a, IRValue b, StringView node, StringView pin)
		{
			let r = E.Op(.Cmp, T.Bool, node, pin);
			r.Sub = new String(op);
			r.Operands.Add(a);
			r.Operands.Add(b);
			return r;
		}

		IROp LoadAt(IRValue addr, KType t, StringView node, StringView pin)
		{
			let ld = E.Op(.Load, t, node, pin);
			ld.Operands.Add(addr);
			return ld;
		}

		void StoreAt(IRValue addr, IRValue v, StringView node, StringView pin)
		{
			let st = E.Op(.Store, T.Void, node, pin);
			st.Operands.Add(addr);
			st.Operands.Add(v);
		}

		/// The address of a state field: a global (static) or a field of `this`.
		IRValue StateAddr(BNode n, MemberSym f, KType owner)
		{
			let inst = (owner != null) ? Sub(owner, n) : Inst;
			Dictionary<GenericParamSym, KType> map = scope .();
			T.MapOf(inst, map);
			let t = T.Subst(f.Type, map);
			if (f.Static)
			{
				let a = E.Op(.GlobalAddr, T.Pointer(t), n.Key, "state");
				a.Global = new String();
				KirWriter.Type(inst, a.Global);
				a.Global.AppendF(".{}", f.Name);
				return a;
			}
			let a = E.Op(.FieldAddr, T.Pointer(t), n.Key, "state");
			a.Operands.Add(ThisAs(inst));
			a.Sub = new String(f.Name);
			return a;
		}

		/// The flow outputs of a Multi Gate (`out0..`), in order.
		static void Arms(BNode n, List<String> outArms)
		{
			for (let f in n.FlowOuts)
				if (f != "done")
					outArms.Add(f);
		}

		/// Jumps through a `switch` on `index` (an int) to the Multi Gate's outputs; out of range
		/// goes to Completed.
		void SwitchArms(BNode n, IRValue index)
		{
			List<String> arms = scope .();
			Arms(n, arms);
			let sw = E.Block;
			sw.Term = .Switch;
			sw.Cond = index;
			sw.TermNode.Set(n.Key);
			List<IRBlock> blocks = scope .();
			for (int i < arms.Count)
			{
				let b = F.NewBlock(n.Key);
				sw.Cases.Add(i);
				sw.Targets.Add(b);
				blocks.Add(b);
			}
			let def = F.NewBlock(n.Key);
			sw.Targets.Add(def);
			for (int i < arms.Count)
			{
				E.Block = blocks[i];
				Goto(n, arms[i]);
			}
			E.Block = def;
			Goto(n, "done");
		}

		void EmitStateful(BNode n)
		{
			let key = n.Key;
			let f = n.Member;
			if (f == null)
			{
				Fatal(n, 2, "the node's state field is missing");
				return;
			}
			let addr = StateAddr(n, f, n.Owner);
			let st = Sub(f.Type, n);
			switch (n.Kind)
			{
			case .Gate:
				// Exit while open, then Completed.
				Fork(n, LoadAt(addr, T.Bool, key, "state"), "exit", "done");
			case .DoOnce:
				let (skip, once) = Split(n, LoadAt(addr, T.Bool, key, "state"));
				E.Block = once;
				StoreAt(addr, E.Const("true", T.Bool, key, "state"), key, "state");
				Goto(n, "once");
				E.Block = skip;
				Goto(n, "done");
			case .DoN:
				// Do the first N times; Counter is this run's number (1..N).
				let count = LoadAt(addr, st, key, "state");
				let limit = EvalIn(n, "n");
				let (yes, no) = Split(n, CmpOp("lt", count, limit, key, "n"));
				E.Block = yes;
				let next = Bin("add", st, count, E.Const("1", st, key, "state"), key, "state");
				StoreAt(addr, next, key, "state");
				StoreSlot(OutSlot(n, "counter"), next, key, "counter");
				Goto(n, "do");
				E.Block = no;
				Goto(n, "done");
			case .FlipFlop:
				// A first; the state says A ran last.
				let (runB, runA) = Split(n, LoadAt(addr, T.Bool, key, "state"));
				E.Block = runA;
				StoreAt(addr, E.Const("true", T.Bool, key, "state"), key, "state");
				StoreSlot(OutSlot(n, "isA"), E.Const("true", T.Bool, key, "isA"), key, "isA");
				Goto(n, "a");
				E.Block = runB;
				StoreAt(addr, E.Const("false", T.Bool, key, "state"), key, "state");
				StoreSlot(OutSlot(n, "isA"), E.Const("false", T.Bool, key, "isA"), key, "isA");
				Goto(n, "b");
			case .MultiGate:
				EmitMultiGate(n, addr, st);
			case .GateOpen, .GateClose:
				StoreAt(addr, E.Const((n.Kind == .GateOpen) ? "true" : "false", T.Bool, key, "state"), key, "state");
				Goto(n, "then");
			case .GateToggle:
				let v = LoadAt(addr, T.Bool, key, "state");
				StoreAt(addr, Bin("xor", T.Bool, v, E.Const("true", T.Bool, key, "state"), key, "state"), key, "state");
				Goto(n, "then");
			case .ResetDoOnce:
				StoreAt(addr, E.Const("false", T.Bool, key, "state"), key, "state");
				Goto(n, "then");
			case .ResetDoN, .ResetMultiGate:
				StoreAt(addr, E.Const("0", st, key, "state"), key, "state");
				Goto(n, "then");
			default:
			}
		}

		/// Multi Gate: sequential (the state is the next output) or `set random` (the state holds
		/// the outputs run so far as bits; a linear congruential generator in a hidden static
		/// field picks among the rest); `set loop` starts over after the last.
		void EmitMultiGate(BNode n, IRValue addr, KType st)
		{
			let key = n.Key;
			List<String> arms = scope .();
			Arms(n, arms);
			let k = arms.Count;
			let loops = n.Node.HasSetting("loop");
			if (n.StateSeed == null)
			{
				var i = LoadAt(addr, st, key, "state");
				let kc = E.Const(scope $"{k}", st, key, "state");
				if (loops)
				{
					let over = CmpOp("ge", i, kc, key, "state");
					let zero = E.Const("0", st, key, "state");
					let sel = E.Op(.Select, st, key, "state");
					sel.Operands.Add(over);
					sel.Operands.Add(zero);
					sel.Operands.Add(i);
					i = sel;
				}
				let (pick, none) = Split(n, CmpOp("lt", i, kc, key, "state"));
				E.Block = pick;
				StoreAt(addr, Bin("add", st, i, E.Const("1", st, key, "state"), key, "state"), key, "state");
				SwitchArms(n, i);
				E.Block = none;
				Goto(n, "done");
				return;
			}
			var mask = LoadAt(addr, st, key, "state");
			let full = E.Const(scope $"{(k >= 63) ? -1 : (((int64)1 << k) - 1)}", st, key, "state");
			if (loops)
			{
				let all = CmpOp("eq", mask, full, key, "state");
				let zero = E.Const("0", st, key, "state");
				let sel = E.Op(.Select, st, key, "state");
				sel.Operands.Add(all);
				sel.Operands.Add(zero);
				sel.Operands.Add(mask);
				mask = sel;
			}
			let (none, pick) = Split(n, CmpOp("eq", mask, full, key, "state"));
			E.Block = pick;
			let ut = T.Prim("uint");
			let seedAddr = StateAddr(n, n.StateSeed, null);
			let seed = LoadAt(seedAddr, ut, key, "state");
			let s1 = Bin("add", ut, Bin("mul", ut, seed, E.Const("6364136223846793005", ut, key, "state"), key, "state"),
				E.Const("1442695040888963407", ut, key, "state"), key, "state");
			StoreAt(seedAddr, s1, key, "state");
			let hi = Bin("shr", ut, s1, E.Const("33", ut, key, "state"), key, "state");
			let r0 = Bin("rem", ut, hi, E.Const(scope $"{k}", ut, key, "state"), key, "state");
			let pickSlot = F.NewSlot(st, .OutTemp, key, "pick");
			let rc = E.Op(.Cast, st, key, "state");
			rc.Operands.Add(r0);
			StoreSlot(pickSlot, rc, key, "state");
			let head = F.NewBlock(key);
			let next = F.NewBlock(key);
			let found = F.NewBlock(key);
			E.Br(head);
			// The first output from the picked one on that has not run yet.
			E.Block = head;
			let r = LoadSlot(pickSlot, key, "state");
			let bit = Bin("and", st, Bin("shr", st, mask, r, key, "state"), E.Const("1", st, key, "state"), key, "state");
			E.Block.Term = .CondBr;
			E.Block.Cond = CmpOp("eq", bit, E.Const("0", st, key, "state"), key, "state");
			E.Block.Targets.Add(found);
			E.Block.Targets.Add(next);
			E.Block.TermNode.Set(key);
			E.Block = next;
			let r1 = Bin("rem", st, Bin("add", st, LoadSlot(pickSlot, key, "state"), E.Const("1", st, key, "state"), key, "state"),
				E.Const(scope $"{k}", st, key, "state"), key, "state");
			StoreSlot(pickSlot, r1, key, "state");
			E.Br(head);
			E.Block = found;
			let chosen = LoadSlot(pickSlot, key, "state");
			StoreAt(addr, Bin("or", st, mask, Bin("shl", st, E.Const("1", st, key, "state"), chosen, key, "state"), key, "state"), key, "state");
			SwitchArms(n, chosen);
			E.Block = none;
			Goto(n, "done");
		}

		/// Delete with an allocator: `delete %o %allocator` (nothing for null; else the destructor,
		/// then the allocator's Free, the back end's rt_free_with).
		void DeleteWith(BNode n, IRValue obj)
		{
			let key = n.Key;
			let alloc = EvalIn(n, "allocator");
			M.Need(alloc.Type);
			E.Op(.NullCheck, T.Void, key, "allocator").Operands.Add(alloc);
			let op = E.Op(.Delete, T.Void, key, "object");
			op.Operands.Add(obj);
			op.Operands.Add(alloc);
		}

		/// For Each over an enumerator (Language.md 5.1): GetEnumerator once, then MoveNext before
		/// each pass; Element reads Current.
		void EnumeratorLoop(BNode n, IRBlock header, IRBlock body, IRBlock latch, IRBlock done)
		{
			let key = n.Key;
			let owner = Sub(n.Owner, n);
			var coll = EvalIn(n, "collection");
			List<IRValue> args = scope .();
			if (owner.Kind == .Named && owner.Sym.Kind == .Struct && coll.Type.Kind != .Pointer)
			{
				let cslot = OutSlot(n, "collection");
				StoreSlot(cslot, coll, key, "collection");
				coll = SlotAddr(cslot, key, "collection");
			}
			else if (coll.Type.IsReference)
				E.Op(.NullCheck, T.Void, key, "collection").Operands.Add(coll);
			args.Add(coll);
			let et = Sub(n.EnumType, n);
			let eslot = OutSlot(n, "enumerator");
			let e = Invoke(n.Member, owner, null, .Body, args, et, key, "collection", false);
			StoreSlot(eslot, e, key, "collection");
			let idx = OutSlot(n, "index");
			StoreSlot(idx, E.Const("0", T.Int, key, "index"), key, "index");
			E.Br(header);
			E.Block = header;
			List<IRValue> margs = scope .();
			margs.Add(SlotAddr(eslot, key, "collection"));
			let more = Invoke(n.EnumMove, et, null, .Body, margs, T.Bool, key, "collection", false);
			E.Block.Term = .CondBr;
			E.Block.Cond = more;
			E.Block.Targets.Add(body);
			E.Block.Targets.Add(done);
			E.Block.TermNode.Set(key);
			E.Block = latch;
			let i1 = Bin("add", T.Int, LoadSlot(idx, key, "index"), E.Const("1", T.Int, key, "index"), key, "index");
			StoreSlot(idx, i1, key, "index");
			E.Br(header);
		}

		/// Switch on a String or StringView: compares the length, then the bytes, case by case in
		/// the listed order.
		void TextSwitch(BNode n, IRValue v, KType on)
		{
			let key = n.Key;
			let svt = T.StringViewSym.Self;
			let sv = Convert(v, on, svt, key, "value");
			let cp = T.Pointer(T.Char8);
			let ptr = E.Op(.Extract, cp, key, "value");
			ptr.Operands.Add(sv);
			ptr.Index = 0;
			let len = E.Op(.Extract, T.Int, key, "value");
			len.Operands.Add(sv);
			len.Index = 1;
			List<IRBlock> arms = scope .();
			for (let label in n.Cases)
			{
				String text = scope .();
				if (label.StartsWith('"'))
					Treadle.Format.RecordText.Unquote(label, text);
				else
					text.Set(label);
				let (cmpB, next1) = Split(n, CmpOp("eq", len, E.Const(scope $"{text.Length}", T.Int, key, "value"), key, "value"));
				E.Block = cmpB;
				let lit = E.Op(.Const, svt, key, "value");
				lit.Lit = new String(text);
				lit.LitIsString = true;
				let lp = E.Op(.Extract, cp, key, "value");
				lp.Operands.Add(lit);
				lp.Index = 0;
				let mc = E.Op(.Intrinsic, T.Int32, key, "value");
				mc.Sub = new String("memcmp");
				mc.Operands.Add(ptr);
				mc.Operands.Add(lp);
				mc.Operands.Add(len);
				let same = CmpOp("eq", mc, E.Const("0", T.Int32, key, "value"), key, "value");
				let arm = F.NewBlock(key);
				E.Block.Term = .CondBr;
				E.Block.Cond = same;
				E.Block.Targets.Add(arm);
				E.Block.Targets.Add(next1);
				E.Block.TermNode.Set(key);
				arms.Add(arm);
				E.Block = next1;
			}
			let def = E.Block;
			for (int i < arms.Count)
			{
				E.Block = arms[i];
				Goto(n, scope $"case:{n.Cases[i]}");
			}
			E.Block = def;
			Goto(n, "default");
		}
	}
}
