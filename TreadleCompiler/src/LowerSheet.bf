using System;
using System.Collections;
using Treadle.Model;
using Treadle.Graph;
using Treadle.Document;
using Treadle.Format;

namespace Treadle.Compiler
{
	/// Lowers one Sheet (Compiler.md 4) to the back end's Sheet IR: flow nodes become blocks, value
	/// nodes are made when a flow node runs (Rules 1-2, memoised per flow node), flow-node results
	/// live in slots, merges are blocks with several predecessors, every edge that leaves a region
	/// goes through `region.exit` (innermost first), Locals are `local` ops in a slot of their
	/// region, Defers are `defer r <block>` with bodies ending in `enddefer`.
	class FnLowerer
	{
		ProgramLowerer M;
		Compilation C;
		TypeTable T;
		SheetResult R;
		KType Inst;
		Dictionary<GenericParamSym, KType> Map;
		IRFunction F;
		OpEmitter E ~ delete _;
		IRValue mThis;
		/// A generic function's own arguments (an instance of a core generic function).
		public List<KType> MethodArgs;
		/// A Lambda Sheet: its closure (`this` of the closure class; null for a function pointer).
		bool mLambda;
		IRValue mClosureThis;
		/// The memory order of the atomic call being lowered.
		String mOrder = new .() ~ delete _;
		Dictionary<String, IRValue> mParams = new .() ~ DeleteDictionaryAndKeys!(_);
		/// `local:<name>` / `param:<name>` -> Variable slot.
		Dictionary<String, IRSlot> mVars = new .() ~ DeleteDictionaryAndKeys!(_);
		/// `<node>.<pin>` -> OutTemp / LoopVar slot of a flow node's output.
		Dictionary<String, IRSlot> mOuts = new .() ~ DeleteDictionaryAndKeys!(_);
		Dictionary<BNode, IRSlot> mLocals = new .() ~ delete _;
		Dictionary<Region, IRRegion> mRegions = new .() ~ delete _;
		/// Loops: the block a pass continues at, and the block after the loop.
		Dictionary<BNode, (IRBlock latch, IRBlock done)> mLoops = new .() ~ delete _;
		/// Rule 2: values made for the flow node being lowered.
		Dictionary<String, IRValue> mMemo = new .() ~ DeleteDictionaryAndKeys!(_);

		class Ctx
		{
			public Dictionary<BNode, IRBlock> Blocks = new .() ~ delete _;
			public List<BNode> Work = new .() ~ delete _;
			/// Lowering a Defer body: its end is `enddefer`.
			public bool InDefer;
		}

		List<Ctx> mCtx = new .() ~ DeleteContainerAndItems!(_);

		public this(ProgramLowerer m, SheetResult r, KType inst, Dictionary<GenericParamSym, KType> map)
		{
			M = m;
			C = m.C;
			T = m.T;
			R = r;
			Inst = inst;
			Map = map;
		}

		Ctx CurCtx => mCtx.Back;

		/// A type of the Sheet with the instance's arguments.
		KType Sub(KType t) => T.Subst(t, Map);

		/// A type bound on a node (its own map first, then the instance's).
		KType Sub(KType t, BNode n) => T.Subst((n.Map != null) ? T.Subst(t, n.Map) : t, Map);

		static void Key(StringView node, StringView pin, String outKey) => outKey.AppendF("{}.{}", node, pin);

		/// The function (the caller owns it).
		public IRFunction Run()
		{
			let m = R.Member;
			let role = R.Sheet.Role;
			F = new .();
			F.Sheet.Set(R.Sheet.Key);
			if (R.IsLambda)
				LambdaHeader();
			else
			{
				M.FuncRef(m, Inst, MethodArgs, role, F.Key);
				M.Display(m, Inst, role, F.Display);
				let thisParam = M.ThisAsParam(m, Inst);
				F.Static = m.Static || R.Type.Static || thisParam;
				F.Virtual = m.VSlot >= 0;
				// A static constructor runs once before Program Start (the back end's `sctor`).
				F.StaticCtor = m.Kind == .Ctor && m.Static;
				// `[Export("name")]`: the back end adds the C-named wrapper (Compiler.md 6.3); a
				// library exports it
				if (m.ExportName != null && F.Static && !thisParam)
					F.Export = new String(m.ExportName);
				if (m.KernelEntry != null && !R.IsLambda)
					F.Kernel = new String(m.KernelEntry); // KernelLower.bf: also compiled for the GPU
				if (!F.Static || thisParam)
				{
					IRValue t = new .();
					t.Param = new String("this");
					t.Type = M.ThisType(Inst);
					F.Params.Add(t);
					mThis = t;
				}
				if (m.Kind == .Property)
				{
					if (role == .Set)
						AddParam("value", Sub(m.Type));
				}
				else
				{
					for (let p in m.Params)
						AddParam(p.Name, (p.Mode == .Value || p.Mode == .Unset) ? Sub(p.Type) : T.Pointer(Sub(p.Type)));
					for (let p in m.Outs)
						AddParam(p.Name, T.Pointer(Sub(p.Type)));
				}
				Dictionary<GenericParamSym, KType> none = scope .();
				F.Ret = Sub(M.ReturnOf(m, none, role));
			}
			for (let p in F.Params)
				M.Need(p.Type);
			M.Need(F.Ret);
			for (let reg in R.Regions)
			{
				IRRegion ir = new .();
				ir.Id = reg.Id;
				ir.Kind = reg.Kind;
				if (reg.Parent != null)
					ir.Parent = mRegions[reg.Parent];
				if (reg.Owner != null)
				{
					ir.Node.Set(reg.Owner.Key);
					ir.Pin.Set(reg.Pin);
				}
				F.Regions.Add(ir);
				mRegions[reg] = ir;
			}
			for (let n in R.Graph.Nodes)
			{
				String kind = new .(NodeKinds.Word(n.Kind));
				if (n.Kind == .Unknown && n.KindWord != null)
					kind.Set(n.KindWord);
				F.Nodes.Add((new String(n.Key), kind, new String(n.Text)));
			}
			PrepareSlots();
			mCtx.Add(new Ctx());
			let entry = F.NewBlock(R.Entry.Key);
			E = new OpEmitter(F, entry);
			// Local variables start at their initial value (or default); written parameters
			// start as the parameter.
			for (let slot in F.Slots)
			{
				if (slot.Kind != .Variable)
					continue;
				IRValue init = null;
				if (slot.Pin == "param" && mParams.TryGetValue(slot.Name, let pv))
					init = pv;
				else
				{
					let l = m.Decl?.FindLocal(slot.Name);
					init = E.Const((l != null && l.Init != null) ? (StringView)l.Init : "default", slot.Type, R.Entry.Key, "");
				}
				let st = E.Op(.StoreSlot, T.Void, R.Entry.Key, "");
				st.Slot = slot;
				st.Operands.Add(init);
			}
			if (m.Kind == .Ctor && mThis != null && !mLambda)
				CtorPrologue();
			Goto(R.Entry, "then");
			Drain();
			for (let s in F.Slots)
				M.Need(s.Type);
			// Every type an op names is declared (a C enum's constant, a cast's source).
			for (let b in F.Blocks)
				for (let op in b.Ops)
					M.Need(op.Type);
			return F;
		}

		/// A Lambda Sheet (Language.md 4.2): a function of its closure class (`this` is the closure,
		/// the captures are its fields), or a static function for a function pointer Lambda.
		void LambdaHeader()
		{
			mLambda = true;
			let lt = R.LambdaType;
			M.LambdaKey(Inst, R.Sheet.LambdaNode, Sub(lt), F.Key, MethodArgs);
			F.Display.AppendF("{}.{}.Lambda", R.Type.FullName, R.Member.Name);
			F.Static = lt.Kind == .Function;
			if (!F.Static)
			{
				IRValue t = new .();
				t.Param = new String("this");
				t.Type = M.Closure(Inst, R.Sheet.LambdaNode, MethodArgs).Self;
				F.Params.Add(t);
				mClosureThis = t;
			}
			for (let p in R.LambdaParams)
				AddParam(p.Name, Sub(p.Type));
			F.Ret = Sub(lt.Element);
		}

		/// The address of a captured variable in the closure: its field, or (by-ref) the pointer the
		/// field holds.
		IRValue CaptureAddr(Capture cap, StringView node, StringView pin)
		{
			let t = Sub(cap.Type);
			let fa = E.Op(.FieldAddr, cap.ByRef ? T.Pointer(T.Pointer(t)) : T.Pointer(t), node, pin);
			fa.Operands.Add(mClosureThis);
			fa.Sub = new String();
			cap.FieldName(fa.Sub);
			if (!cap.ByRef)
				return fa;
			let ld = E.Op(.Load, T.Pointer(t), node, pin);
			ld.Operands.Add(fa);
			return ld;
		}

		/// The capture a Get / Set in a Lambda Sheet names.
		Capture CaptureOf(BNode n)
		{
			if (!mLambda || !n.IsCapture)
				return null;
			if (n.Var == .Local && n.LocalVar != null)
				return R.FindCapture(.Local, n.LocalVar.Name);
			if (n.Var == .Param && n.ParamVar != null)
				return R.FindCapture(.Param, n.ParamVar.Name);
			return null;
		}

		/// The address a `ref` parameter of this function holds (its value is the caller's
		/// place); null for any other parameter.
		IRValue RefParamAddr(StringView name)
		{
			if (R.IsLambda)
				return null;
			let p = R.Member.FindParam(name);
			if (p == null || !p.IsRef)
				return null;
			if (!mParams.TryGetValue(scope String(name), let pv) || pv.Type.Kind != .Pointer)
				return null;
			return pv;
		}

		/// `this`: the parameter, or in a Lambda Sheet the enclosing object the closure holds.
		IRValue ThisValue()
		{
			if (!mLambda)
				return mThis;
			let cap = R.FindCapture(.This, "");
			if (cap == null || mClosureThis == null)
				return null;
			let tt = M.ThisType(Inst);
			let fa = E.Op(.FieldAddr, T.Pointer(tt), "", "");
			fa.Operands.Add(mClosureThis);
			fa.Sub = new String("__this");
			let ld = E.Op(.Load, tt, "", "");
			ld.Operands.Add(fa);
			return ld;
		}

		void AddParam(StringView name, KType t)
		{
			IRValue v = new .();
			v.Param = new String(name);
			v.Type = t;
			F.Params.Add(v);
			mParams[new String(name)] = v;
		}

		// ------------------------------------------------------------------ slots

		void PrepareSlots()
		{
			let m = R.Member;
			if (m.Decl != null && R.Sheet.Role == .Body)
				for (let l in m.Decl.Locals)
				{
					NameCtx nc = .(R.Type, m, R.Site);
					nc.Quiet = true;
					var t = Sub(C.Resolve(l.Type, nc) ?? T.Error);
					if (t.IsError)
					{
						// Declare reports a missing type (T1078) and a build stops there; a variable without a
						// type must never reach the IR (a slot of no type is a const with no result the back end
						// cannot read): an internal error naming it and the function instead
						C.Diags.Add(.Error, .Lower, "T4003", R.Site, "", "", scope $"{R.Type.FullName}.{m.Name}: {l.Name} has no type (an internal error: Validate should have stopped the build)").Variable.Set(scope $"local:{l.Name}");
						M.Failed();
						t = T.Int; // a placeholder: the failed lowering is not written
					}
					let s = F.NewSlot(t, .Variable, "", "", l.Name);
					mVars[new String(scope $"local:{l.Name}")] = s;
				}
			// Parameters some Set writes, a by-ref input or a by-ref capture takes the address
			// of, become variables.
			void ParamSlot(ParamSym p)
			{
				let key = scope String()..AppendF("param:{}", p.Name);
				if (mVars.ContainsKey(key) || !mParams.ContainsKey(scope String(p.Name)))
					return;
				if (p.IsRef && !R.IsLambda)
					return; // already an address: Set and by-ref inputs use it (RefParamAddr)
				let s = F.NewSlot(Sub(p.Type), .Variable, "", "param", p.Name);
				mVars[new String(key)] = s;
			}
			for (let b in R.Nodes)
			{
				if (b.Kind == .Set && b.Var == .Param && b.ParamVar != null && !b.IsCapture)
					ParamSlot(b.ParamVar);
				for (let spec in b.Ins)
				{
					// A Mutating struct call's Receiver is a place too (through fields to its root).
					let mutRecv = spec.IsReceiver && b.Kind == .Call && b.Member != null && b.Member.Mutating && !b.ReceiverIsThis;
					if ((!spec.IsRef && !mutRecv) || spec.Pin == null)
						continue;
					let l = R.Graph.FindLinkTo(spec.Pin);
					if (l == null)
						continue;
					let (src, srcPin) = R.PlaceRoot(R.Get(l.From.Owner), l.From.Name);
					if (mutRecv && src != null && src == R.Entry)
					{
						let p = R.IsLambda ? R.FindLambdaParam(srcPin) : R.Member.FindParam(srcPin);
						if (p != null)
							ParamSlot(p);
					}
					if (src != null && src.Kind == .Get && src.Var == .Param && src.ParamVar != null && !src.IsCapture)
						ParamSlot(src.ParamVar);
				}
				if (b.Kind == .Lambda && b.LambdaSheet != null)
					for (let cap in b.LambdaSheet.Captures)
					{
						// In a Lambda Sheet only its own inputs are parameters (the rest are captures).
						let p = (cap.What != .Param || !cap.ByRef) ? null : (R.IsLambda ? R.FindLambdaParam(cap.Name) : R.Member.FindParam(cap.Name));
						if (p != null)
							ParamSlot(p);
					}
			}
			// Flow outputs that something reads, in node order.
			for (let b in R.Nodes)
			{
				if (!b.Flow || !b.Reached || b == R.Entry)
					continue;
				if (b.Kind == .Local && b.Subject != null && !b.Subject.IsError)
				{
					let reg = b.Node.HasSetting("function-scope") ? R.Regions[0] : b.Region;
					let s = F.NewSlot(Sub(b.Subject), .Local, b.Key, "object");
					s.Region = mRegions[reg];
					mLocals[b] = s;
				}
				if ((b.Kind == .Bind || (b.Kind == .Lambda && b.Closure != null)) && b.Alloc == .Local)
				{
					// The delegate object lives in the node's region (`bind.local` / `local` of the closure).
					let s = (b.Kind == .Bind) ? F.NewSlot(Sub(b.FindOut("value").Type, b), .Local, b.Key, "value") : F.NewSlot(M.Closure(Inst, b.Key, MethodArgs).Self, .Local, b.Key, "value");
					if (b.Kind == .Bind)
						s.TypeText = new String("Core.Delegate");
					s.Region = mRegions[b.Region ?? R.Regions[0]];
					mLocals[b] = s;
				}
				switch (b.Kind)
				{
				case .For:
					let it = Sub(b.FindOut("index").Type);
					Slot(b, "index", it, .LoopVar);
					Slot(b, "count", it, .LoopVar);
					continue;
				case .ForEach:
					Slot(b, "index", T.Int, .LoopVar);
					Slot(b, "collection", Sub(b.FindIn("collection").Type), .OutTemp);
					if (b.EnumType != null)
						Slot(b, "enumerator", Sub(b.EnumType, b), .OutTemp);
					continue;
				case .Switch:
					Slot(b, "value", Sub(b.FindIn("value").Type), .OutTemp);
					continue;
				case .ResultMatch, .Try:
					Slot(b, "result", Sub(b.FindIn("result").Type), .OutTemp);
					continue;
				default:
				}
				for (let o in b.Outs)
				{
					if (b.Kind == .Local && o.Name == "object" && mLocals.ContainsKey(b))
						continue;
					let p = b.Node.FindOutput(o.Name);
					if (p == null || !R.Graph.IsLinked(p))
						continue;
					Slot(b, o.Name, Sub(o.Type, b), .OutTemp);
				}
			}
		}

		IRSlot Slot(BNode b, StringView pin, KType t, SlotKind kind)
		{
			let key = scope String();
			Key(b.Key, pin, key);
			if (mOuts.TryGetValue(key, let have))
				return have;
			let s = F.NewSlot(t, kind, b.Key, pin);
			mOuts[new String(key)] = s;
			return s;
		}

		IRSlot OutSlot(BNode b, StringView pin)
		{
			let key = scope String();
			Key(b.Key, pin, key);
			if (mOuts.TryGetValue(key, let s))
				return s;
			return null;
		}

		// ------------------------------------------------------------------ blocks and edges

		IRBlock BlockFor(BNode n)
		{
			let ctx = CurCtx;
			if (ctx.Blocks.TryGetValue(n, let b))
				return b;
			let nb = F.NewBlock(n.Key);
			ctx.Blocks[n] = nb;
			ctx.Work.Add(n);
			return nb;
		}

		void Drain()
		{
			let ctx = CurCtx;
			while (!ctx.Work.IsEmpty)
			{
				let n = ctx.Work.PopFront();
				E.Block = ctx.Blocks[n];
				ClearMemo();
				EmitNode(n);
				if (!E.Block.Terminated)
					E.Block.Term = .Unreachable;
			}
		}

		void ClearMemo()
		{
			for (let kv in mMemo)
				delete kv.key;
			mMemo.Clear();
		}

		/// Runs `body` with an empty memo and puts the old one back after (values made inside a
		/// conditional block or a Defer body are not reused outside it).
		void WithFreshMemo(delegate void() body)
		{
			Dictionary<String, IRValue> saved = scope .();
			for (let kv in mMemo)
				saved[kv.key] = kv.value;
			mMemo.Clear();
			body();
			// Every key the body added is its own string (a value made again inside the body has a
			// key equal to a saved one, but not the same object).
			for (let kv in mMemo)
				delete kv.key;
			mMemo.Clear();
			for (let kv in saved)
				mMemo[kv.key] = kv.value;
		}

		BNode Target(BNode n, StringView pin)
		{
			let p = n.Node.FindOutput(pin);
			if (p == null)
				return null;
			let l = R.Graph.FindLinkFrom(p);
			if (l == null)
				return null;
			let t = R.Get(l.To.Owner);
			return (t != null && t.Flow && t.Reached && !t.Node.Disabled) ? t : null;
		}

		/// The region a flow output belongs to: the one it opens, else its node's.
		Region PinRegion(BNode n, StringView pin)
		{
			let v = R.Flow.PinVertex(n, pin);
			if (v != null && v.Region != null)
				return v.Region;
			return n.Region ?? R.Regions[0];
		}

		/// Follows a flow output: enters the region it opens, leaves the regions the target is
		/// not in, jumps; an unwired output continues where its region does.
		void Goto(BNode from, StringView pin)
		{
			let reg = PinRegion(from, pin);
			let v = R.Flow.PinVertex(from, pin);
			if (v != null && v.Opens != null)
				E.Op(.RegionEnter, T.Void, from.Key, pin).Region = mRegions[v.Opens];
			let t = Target(from, pin);
			if (t == null)
			{
				Continue(reg, from);
				return;
			}
			let to = t.Region ?? R.Regions[0];
			var cur = reg;
			while (cur != null && !to.Within(cur))
			{
				Exit(cur, from);
				cur = cur.Parent;
			}
			// The flow merged below the arms of a Switch / Result: match (Check.MergeRegion): its
			// region is entered by the jump that reaches it, not by an output.
			for (var m = to; m != null && m != cur; m = m.Parent)
				if (m.Pin == "merge" && m.Parent == cur)
					E.Op(.RegionEnter, T.Void, from.Key, pin).Region = mRegions[m];
			E.Br(BlockFor(t));
		}

		void Exit(Region reg, BNode source)
		{
			E.Op(.RegionExit, T.Void, source.Key, "").Region = mRegions[reg];
			if (reg.Kind == .Function && reg.Parent == null)
				DestroyLocals(source);
		}

		/// The function returns (Language.md 5.4): after its region's Defers and Locals, its local
		/// variables of a struct type that has a destructor are destroyed and its Owned locals of a
		/// reference type deleted (Delete of null does nothing), the last declared first.
		void DestroyLocals(BNode source)
		{
			let m = R.Member;
			if (mLambda || m == null || m.Decl == null || R.Sheet.Role != .Body)
				return;
			for (int i = m.Decl.Locals.Count - 1; i >= 0; i--)
			{
				let l = m.Decl.Locals[i];
				if (!mVars.TryGetValue(scope String()..AppendF("local:{}", l.Name), let slot))
					continue;
				let t = slot.Type;
				if (l.Owner == .Owned && t.IsReference)
				{
					let v = LoadSlot(slot, source.Key, "");
					E.Op(.Delete, T.Void, source.Key, "").Operands.Add(v);
				}
				else if (DestroysLocal(l, t))
				{
					let a = SlotAddr(slot, source.Key, "");
					E.Op(.Dtor, T.Void, source.Key, "").Operands.Add(a);
				}
			}
		}

		/// A local variable whose struct value is destroyed at return and when a Set replaces it: its type
		/// needs destroying (NeedsDestroy), and it is not declared as a generic parameter `T`. Generic code
		/// keeps moved values in such locals (the core's Sorting, List and Queue swap through `local t T`:
		/// bitwise moves that someone else destroys), so those stay as they are.
		bool DestroysLocal(LocalDecl l, KType t)
		{
			if (!NeedsDestroy(t))
				return false;
			NameCtx nc = .(R.Type, R.Member, R.Site);
			nc.Quiet = true;
			let declared = C.Resolve(l.Type, nc);
			return declared != null && declared.Kind != .Param;
		}

		/// A struct whose value must be destroyed: it has a destructor, an Owned reference field or a
		/// field of such a struct (the back end's complete destructor runs them all).
		bool NeedsDestroy(KType t, int depth = 0)
		{
			if (t == null || depth > 8 || !t.IsStruct || t.Sym == null)
				return false;
			if (t.Sym.Dtor != null)
				return true;
			Dictionary<GenericParamSym, KType> map = scope .();
			T.MapOf(t, map);
			for (let f in t.Sym.Members)
			{
				if (f.Kind != .Field || f.Static || f.Const)
					continue;
				let ft = T.Subst(f.Type, map);
				if ((f.Ownership == .Owned && ft.IsReference) || NeedsDestroy(ft, depth + 1))
					return true;
			}
			return false;
		}

		/// The flow ends without a wire inside `reg` (Language.md 5.3).
		void Continue(Region reg, BNode source)
		{
			switch (reg.Kind)
			{
			case .Function:
				Exit(reg, source);
				FunctionExit(null, source);
			case .Loop:
				Exit(reg, source);
				E.Br(mLoops[reg.Owner].latch);
			case .SequenceArm:
				Exit(reg, source);
				let owner = reg.Owner;
				int idx = -1;
				for (int i < owner.FlowOuts.Count)
					if (owner.FlowOuts[i] == reg.Pin)
						idx = i;
				if (idx >= 0 && idx + 1 < owner.FlowOuts.Count)
					Goto(owner, owner.FlowOuts[idx + 1]);
				else
					Continue(reg.Parent, source);
			case .Block:
				Exit(reg, source);
				Goto(reg.Owner, "done");
			case .Arm:
				Exit(reg, source);
				Continue(reg.Parent, source);
			case .Deferred:
				Exit(reg, source);
				if (!E.Block.Terminated)
				{
					E.Block.Term = CurCtx.InDefer ? .EndDefer : .Unreachable;
					E.Block.TermNode.Set(source.Key);
				}
			}
		}

		/// `ret` (Check reported a missing Return value).
		void FunctionExit(IRValue value, BNode source)
		{
			if (E.Block.Terminated)
				return;
			E.Block.TermNode.Set(source.Key);
			if (value == null && !F.Ret.IsVoid)
			{
				E.Block.Term = .Unreachable;
				return;
			}
			E.Block.Term = .Ret;
			E.Block.RetVal = value;
		}

		/// Leaves every region from `reg` up to the function's (inclusive).
		void LeaveAll(Region reg, BNode source)
		{
			var cur = reg;
			while (cur != null)
			{
				Exit(cur, source);
				cur = cur.Parent;
			}
		}

		static Region LoopOf(Region reg)
		{
			var cur = reg;
			while (cur != null)
			{
				if (cur.Kind == .Loop)
					return cur;
				if (cur.Kind == .Deferred)
					return null;
				cur = cur.Parent;
			}
			return null;
		}

		/// A Defer body: its own blocks, entered by `defer r <block>` and ended by `enddefer`.
		IRBlock DeferBody(BNode d)
		{
			let body = F.NewBlock(d.Key);
			let saved = E.Block;
			E.Block = body;
			WithFreshMemo(scope [&]() =>
			{
				Ctx ctx = new .();
				ctx.InDefer = true;
				mCtx.Add(ctx);
				if (d.Kind == .DeferDelete)
				{
					let obj = EvalIn(d, "object");
					E.Op(.Delete, T.Void, d.Key, "object").Operands.Add(obj);
					E.Block.Term = .EndDefer;
					E.Block.TermNode.Set(d.Key);
				}
				else
				{
					Goto(d, "deferred");
					Drain();
				}
				mCtx.PopBack();
				delete ctx;
			});
			E.Block = saved;
			return body;
		}

		// ------------------------------------------------------------------ constructors

		void CtorPrologue()
		{
			BNode chain = null;
			for (let b in R.Nodes)
				if (b.Kind == .ChainCtor && !b.Node.Disabled && b.Member != null)
					chain = b;
			if (chain != null)
			{
				let target = Sub(chain.Owner);
				List<IRValue> args = scope .();
				for (let p in chain.Member.Params)
					args.Add(EvalIn(chain, p.Name));
				String name = scope .();
				M.FuncRef(chain.Member, target, null, .Body, name);
				M.Use(chain.Member, target, name);
				IRValue thisArg = mThis;
				if (target != Inst)
				{
					let up = E.Op(.Cast, target, chain.Key, "");
					up.Operands.Add(mThis);
					thisArg = up;
				}
				let call = E.Op(.Call, T.Void, chain.Key, "");
				call.Callee = new String(name);
				call.Operands.Add(thisArg);
				call.Operands.AddRange(args);
				ClearMemo();
				if (chain.Node.Text == "this")
					return;
			}
			else if (R.Type.Kind == .Class)
				M.BaseDefaultCtor(E, Inst, mThis, R.Entry.Key);
			M.FieldInits(E, Inst, mThis, R.Entry.Key);
		}

		// ------------------------------------------------------------------ values

		/// The value an input gets: its wire (converted to the input's type), its literal, or
		/// its default.
		IRValue EvalIn(BNode n, StringView pin)
		{
			let spec = n.FindIn(pin);
			KType want = (spec != null && spec.Type != null) ? Sub(spec.Type, n) : T.Error;
			if (spec != null && spec.IsReceiver && n.ReceiverIsThis)
				return ThisAs(want);
			let p = (spec != null) ? spec.Pin : n.Node.FindInput(pin);
			let l = (p != null) ? R.Graph.FindLinkTo(p) : null;
			if (l != null)
			{
				let src = R.Get(l.From.Owner);
				let o = src.FindOut(l.From.Name);
				var v = EvalOut(src, l.From.Name);
				if ((src.Kind == .This || src.Kind == .Base) && n.Kind != .IsCase && (spec == null || !spec.IsReceiver) && v.Type != null && v.Type.Kind == .Pointer &&
					want != null && !want.IsError && v.Type.Element == want)
				{
					// `this` of a struct or an enum is the receiver's address: an input that takes the
					// type by value gets the value it points to (a copy; Check's T3064 for a destructor).
					let ld = E.Op(.Load, want, n.Key, pin);
					ld.Operands.Add(v);
					v = ld;
				}
				return Convert(v, (o != null) ? Sub(o.Type, src) : v.Type, want, n.Key, pin);
			}
			StringView token = default;
			if (p != null && !p.Default.IsEmpty)
			{
				// a literal that names a constant is its folded value (Bind's PinLiteral)
				token = p.Default;
				if (n.ConstPins != null && n.ConstPins.TryGetValueAlt(p.Name, let folded))
					token = folded;
			}
			else if (n.Member != null && n.Member.IsCallable && n.Member.FindParam(pin)?.Default != null)
				token = n.Member.FindParam(pin).Default;
			else if (pin == "step" && n.Kind == .For)
				token = "1";
			else
				token = "default";
			return Literal(token, want, n.Key, pin);
		}

		/// A literal for a pin of type `want`. A string for a `String` pin is a Local String in the
		/// function's region (made from the text, freed when the function returns).
		IRValue Literal(StringView token, KType want, StringView node, StringView pin)
		{
			if (token.StartsWith('"') && want.Kind == .Named && want.Sym == T.StringSym)
			{
				let s = F.NewSlot(want, .Local, node, pin);
				s.Region = F.Regions[0];
				let obj = E.Op(.Local, want, node, pin);
				obj.Slot = s;
				let sv = E.Const(token, T.StringViewSym.Self, node, pin);
				let call = E.Op(.Call, T.Void, node, pin);
				call.Callee = new String("Core.String.this(StringView)");
				call.Operands.Add(obj);
				call.Operands.Add(sv);
				M.Need(want);
				return obj;
			}
			if (want != null && want.Kind == .Nullable && token != "null" && token != "default")
				return MakeNullable(E.Const(token, want.Element, node, pin), want, node, pin);
			if (Literals.IsStructLiteral(token, want))
				return StructLiteral(token, want, node, pin);
			return E.Const(token, want, node, pin);
		}

		/// A struct literal (`1,2,3` for a Vec3; Literals.IsStructLiteral): the Make of its fields, each value a
		/// constant of its field's type (an auto property's hidden field starts at default).
		IRValue StructLiteral(StringView token, KType t, StringView node, StringView pin)
		{
			M.Need(t);
			List<StringView> parts = scope .();
			for (let part in token.Split(','))
				parts.Add(part);
			Dictionary<GenericParamSym, KType> fmap = scope .();
			T.MapOf(t, fmap);
			List<IRValue> fields = scope .();
			int k = 0;
			for (let f in t.Sym.AllFields)
			{
				let ft = T.Subst(f.Type, fmap);
				fields.Add(E.Const((f.Synthetic || k >= parts.Count) ? "default" : parts[k], ft, node, pin));
				if (!f.Synthetic)
					k++;
			}
			let mk = E.Op(.Make, t, node, pin);
			mk.Operands.AddRange(fields);
			return mk;
		}

		/// A `T?` holding `v` (its has-value flag set).
		IRValue MakeNullable(IRValue v, KType t, StringView node, StringView pin)
		{
			M.Need(t);
			let flag = E.Const("true", T.Bool, node, pin);
			let mk = E.Op(.Make, t, node, pin);
			mk.Operands.Add(v);
			mk.Operands.Add(flag);
			return mk;

		}

		IRValue ThisAs(KType want)
		{
			let th = ThisValue();
			if (th == null)
				return E.Const("null", want, "", "");
			if (want == null || want == th.Type || want.IsError)
				return th;
			if (th.Type.Kind == .Pointer && want == th.Type.Element)
				return th; // a struct receiver: `ref this`
			let up = E.Op(.Cast, want, "", "");
			up.Operands.Add(th);
			return up;
		}

		/// An implicit conversion (Language.md 2.3) as an op; nothing when the types agree.
		IRValue Convert(IRValue v, KType from, KType to, StringView node, StringView pin)
		{
			if (to == null || to.IsError || from == null || from.IsError || from == to || v.Type == to)
				return v;
			if (to.IsVector && !from.IsVector && !from.IsError)
				return Splat(v, from, to, node, pin); // LowerVector.bf: a scalar where a vector is taken
			if (from.Kind == .Named && from.Sym == T.StringSym && to.Kind == .Named && to.Sym == T.StringViewSym)
			{
				let call = E.Op(.Call, to, node, pin);
				call.Callee = new String("Core.String.View()");
				call.Operands.Add(v);
				return call;
			}
			if (from.Kind == .Null)
				return E.Const("null", to, node, pin);
			if (to.Kind == .Nullable && from.Kind != .Nullable)
			{
				// T to T? (a widening first when the value is another number)
				let inner = Convert(v, from, to.Element, node, pin);
				return MakeNullable(inner, to, node, pin);
			}

			if (from.Kind == .Array && to.Kind == .Named && to.Sym == T.SpanSym)
			{
				// T[] to Span<T>: `array.span`, a pointer to the elements and the length
				M.Need(to);
				let sp = E.Op(.ArraySpan, to, node, pin);
				sp.Operands.Add(v);
				return sp;
			}
			let c = E.Op(.Cast, to, node, pin);
			c.Operands.Add(v);
			return c;
		}

		/// The value of a node's output: the parameters (Entry), a flow node's result slot or
		/// loop index, or a value node made now, once per flow node (Rule 2).
		IRValue EvalOut(BNode src, StringView pin)
		{
			if (src == R.Entry)
			{
				let key = scope String()..AppendF("param:{}", pin);
				if (mVars.TryGetValue(key, let slot))
					return LoadSlot(slot, src.Key, pin);
				if (mParams.TryGetValue(scope String(pin), let pv))
					return ByRefParamValue(pv, pin, src.Key, pin);
				return E.Const("default", T.Int, src.Key, pin);
			}
			if (src.Flow)
				return FlowOutput(src, pin);
			let key = scope String();
			Key(src.Key, pin, key);
			if (mMemo.TryGetValue(key, let have))
				return have;
			if (src.Kind == .Call && src.Member != null && src.EventOp == .None && IsOutPin(src.Member, pin))
			{
				// A Pure Call's further output: the call is made once for the flow node (memoised as
				// its `result`), then its out parameter's slot is read after it.
				let callKey = scope String();
				Key(src.Key, "result", callKey);
				if (!mMemo.ContainsKey(callKey))
				{
					let call = Value(src, "result");
					mMemo[new String(callKey)] = call;
				}
				let slot = OutSlot(src, pin);
				let ov = (slot != null) ? LoadSlot(slot, src.Key, pin) : E.Const("default", T.Int, src.Key, pin);
				mMemo[new String(key)] = ov;
				return ov;
			}
			let v = Value(src, pin);
			mMemo[new String(key)] = v;
			return v;
		}

		static bool IsOutPin(MemberSym f, StringView pin)
		{
			for (let p in f.Outs)
				if (p.Name == pin)
					return true;
			return false;
		}

		IRValue LoadSlot(IRSlot slot, StringView node, StringView pin)
		{
			let op = E.Op(.LoadSlot, slot.Type, node, pin);
			op.Slot = slot;
			return op;
		}

		void StoreSlot(IRSlot slot, IRValue v, StringView node, StringView pin)
		{
			if (slot == null || v == null)
				return;
			let op = E.Op(.StoreSlot, T.Void, node, pin);
			op.Slot = slot;
			op.Operands.Add(v);
		}

		IRValue SlotAddr(IRSlot slot, StringView node, StringView pin)
		{
			// A Local's class object: the address is the object itself.
			let isClass = slot.Kind == .Local && slot.Type.Kind == .Named && slot.Type.Sym.Kind == .Class;
			let op = E.Op(.SlotAddr, isClass ? slot.Type : T.Pointer(slot.Type), node, pin);
			op.Slot = slot;
			return op;
		}

		IRValue FlowOutput(BNode src, StringView pin)
		{
			switch (src.Kind)
			{
			case .Local:
				if (pin == "object" && mLocals.TryGetValue(src, let slot))
				{
					if (slot.Type.Kind == .Named && slot.Type.Sym.Kind == .Class)
						return SlotAddr(slot, src.Key, pin);
					return LoadSlot(slot, src.Key, pin);
				}
			case .ForEach:
				if (pin == "element" && src.EnumType != null)
				{
					// The enumerator's Current (a getter call on the enumerator in its slot).
					let et = Sub(src.EnumType, src);
					List<IRValue> args = scope .();
					args.Add(SlotAddr(OutSlot(src, "enumerator"), src.Key, pin));
					return Invoke(src.EnumCurrent, et, null, .Get, args, Sub(src.FindOut("element").Type, src), src.Key, pin, false);
				}
				if (pin == "element")
				{
					let coll = LoadSlot(OutSlot(src, "collection"), src.Key, "collection");
					let idx = LoadSlot(OutSlot(src, "index"), src.Key, "index");
					return Element(coll, idx, Sub(src.FindOut("element").Type), src.Key, pin, false); // the loop keeps the index in range
				}
			case .Switch:
				if (pin.StartsWith("case:"))
				{
					let dot = pin.IndexOf('.');
					let label = pin.Substring(5, dot - 5);
					let field = pin.Substring(dot + 1);
					let v = LoadSlot(OutSlot(src, "value"), src.Key, "value");
					return Payload(v, src.Subject, label, field, Sub(src.FindOut(pin).Type), src.Key, pin);
				}
			case .ResultMatch, .Try:
				let v = LoadSlot(OutSlot(src, "result"), src.Key, "result");
				let rt = Sub(src.FindIn("result").Type);
				let isErr = pin == "error";
				return Payload(v, rt, isErr ? "Err" : "Ok", isErr ? "error" : "value", Sub(src.FindOut(pin).Type), src.Key, pin);
			default:
			}
			let slot = OutSlot(src, pin);
			if (slot == null)
				return E.Const("default", T.Int, src.Key, pin);
			return LoadSlot(slot, src.Key, pin);
		}

		IRValue Payload(IRValue v, KType enumType, StringView caseName, StringView field, KType t, StringView node, StringView pin)
		{
			let et = Sub(enumType);
			int32 index = 0;
			if (et != null && et.IsEnum)
			{
				let cs = et.Sym.FindCase(caseName);
				if (cs != null)
					for (let p in cs.Payload)
					{
						if (p.Name == field)
							break;
						index++;
					}
			}
			let op = E.Op(.EnumPayload, t, node, pin);
			op.Operands.Add(v);
			op.Sub = new String(caseName);
			op.Index = index;
			return op;
		}

		IRValue Element(IRValue coll, IRValue idx, KType elem, StringView node, StringView pin, bool check = true)
		{
			let addr = ElementAddr(coll, idx, elem, node, pin, check);
			let ld = E.Op(.Load, elem, node, pin);
			ld.Operands.Add(addr);
			return ld;
		}

		/// The address of an element of an array, a span, a string or a pointer (Debug: bounds check).
		IRValue ElementAddr(IRValue coll, IRValue idx, KType elem, StringView node, StringView pin, bool check = true)
		{
			if (coll.Type.Kind == .Array)
			{
				let bc = E.Op(.BoundsCheck, T.Void, node, pin);
				bc.Operands.Add(coll);
				bc.Operands.Add(idx);
			}
			var coll;
			if (coll.Type.Kind == .Named && coll.Type.Sym == T.StringSym)
			{
				let view = E.Op(.Call, T.StringViewSym.Self, node, pin);
				view.Callee = new String("Core.String.View()");
				view.Operands.Add(coll);
				coll = view;
			}
			var basePtr = coll;
			if (coll.Type.Kind == .Named && (coll.Type.Sym == T.SpanSym || coll.Type.Sym == T.StringViewSym))
			{
				let ptr = E.Op(.Extract, T.Pointer(elem), node, pin);
				ptr.Operands.Add(coll);
				ptr.Index = 0;
				basePtr = ptr;
				// Debug: a Span's index is checked against its Length as an array's is (the emitter drops the
				// check in Release; Compiler.md 6, "Span indices")
				if (check && coll.Type.Sym == T.SpanSym)
				{
					let len = E.Op(.Extract, T.Int, node, pin);
					len.Operands.Add(coll);
					len.Index = 1;
					let bc = E.Op(.BoundsCheck, T.Void, node, pin);
					bc.Operands.Add(coll);
					bc.Operands.Add(idx);
					bc.Operands.Add(len);
				}
			}
			let addr = E.Op(.ElemAddr, T.Pointer(elem), node, pin);
			addr.Operands.Add(basePtr);
			addr.Operands.Add(idx);
			return addr;
		}

		static StringView BinopWord(StringView op)
		{
			switch (op)
			{
			case "+": return "add";
			case "-": return "sub";
			case "*": return "mul";
			case "/": return "div";
			case "%": return "rem";
			case "&": return "and";
			case "|": return "or";
			case "^": return "xor";
			case "<<": return "shl";
			case ">>": return "shr";
			case "==": return "eq";
			case "!=": return "ne";
			case "<": return "lt";
			case ">": return "gt";
			case "<=": return "le";
			case ">=": return "ge";
			default: return op;
			}
		}

		static bool IsCompare(StringView op) => op == "==" || op == "!=" || op == "<" || op == ">" || op == "<=" || op == ">=";

		/// An operator over values of `operand`: a builtin op, or the type's operator record
		/// (a generic parameter's operator is decided here, per instance).
		IRValue Operate(StringView op, KType operand, IRValue a, IRValue b, KType result, StringView node, StringView pin)
		{
			if (operand.IsVector)
				return VectorOperate(op, operand, a, b, result, node, pin); // LowerVector.bf: element-wise, a scalar splats
			// the operator for the operands' types (a type may declare `*` for Vec3 * Vec3 and Vec3 * float)
			let user = (operand.Kind == .Named && !(operand.Sym.Kind == .Enum && !operand.Sym.HasPayload)) ? C.FindUserOperatorFor(operand, op, a.Type, (b != null) ? b.Type : null) : null;
			if (user != null)
			{
				String name = scope .();
				M.FuncRef(user, operand, null, .Body, name);
				M.Use(user, operand, name);
				Dictionary<GenericParamSym, KType> map = scope .();
				T.MapOf(operand, map);
				let call = E.Op(.Call, T.Subst(user.Returns, map), node, pin);
				call.Callee = new String(name);
				call.Operands.Add(a);
				if (b != null)
					call.Operands.Add(b);
				return call;
			}
			if (op == "neg")
			{
				let zero = E.Const("0", operand, node, pin);
				let r = E.Op(.Binop, operand, node, pin);
				r.Sub = new String("sub");
				r.Operands.Add(zero);
				r.Operands.Add(a);
				return r;
			}
			if (op == "!" || op == "~")
			{
				let ones = E.Const((op == "!") ? "true" : "-1", operand, node, pin);
				let r = E.Op(.Binop, operand, node, pin);
				r.Sub = new String("xor");
				r.Operands.Add(a);
				r.Operands.Add(ones);
				return r;
			}
			let r = E.Op(IsCompare(op) ? .Cmp : .Binop, IsCompare(op) ? T.Bool : result, node, pin);
			r.Sub = new String(BinopWord(op));
			r.Operands.Add(a);
			r.Operands.Add(b);
			return r;
		}

		/// A value node's output.
		IRValue Value(BNode n, StringView pin)
		{
			let key = n.Key;
			if (VectorRules.IsSwizzleNode(n.Node))
				return SwizzleValue(n); // LowerVector.bf
			if (VectorRules.IsShuffleNode(n.Node))
				return ShuffleValue(n);
			switch (n.Kind)
			{
			case .This, .Base:
				return ThisAs(Sub(n.FindOut("value").Type));
			case .Literal:
				return Literal(n.Node.GetSetting("value"), Sub(n.FindOut("value").Type), key, pin);
			case .Get:
				return GetVar(n, pin);
			case .Call:
				return CallNode(n, pin);
			case .Operator:
				return OperatorNode(n);
			case .Select:
				if (IsMaskSelect(n))
					return VectorSelectNode(n); // LowerVector.bf: per lane, both inputs made
				return Lazy(n);
			case .Cast:
				return CastNode(n);
			case .Make:
				if (Sub(n.Subject).IsVector)
					return VectorMakeNode(n, Sub(n.Subject)); // LowerVector.bf
				let t = Sub(n.Subject);
				List<IRValue> fields = scope .();
				if (IsBlob(t))
					return MakeBlob(n, t);
				if (t.Kind == .Named)
				{
					// Every field in layout order; hidden ones (an auto property's) start at default.
					Dictionary<GenericParamSym, KType> fmap = scope .();
					T.MapOf(t, fmap);
					for (let f in t.Sym.AllFields)
						fields.Add(f.Synthetic ? E.Const("default", T.Subst(f.Type, fmap), key, "value") : EvalIn(n, f.Name));
				}
				else
					for (let spec in n.Ins)
						fields.Add(EvalIn(n, spec.Name));
				let op = E.Op(.Make, t, key, "value");
				op.Operands.AddRange(fields);
				return op;
			case .BreakStruct:
				if (Sub(n.Subject).IsVector)
					return VectorBreakValue(n, Sub(n.Subject), pin); // LowerVector.bf
				let v = EvalIn(n, "value");
				let t = Sub(n.Subject);
				if (IsBlob(t))
				{
					for (let f in t.Sym.AllFields)
						if (f.Name == pin)
							return BlobRead(v, f, key, pin);
				}
				int32 index = -1;
				if (t.Kind == .Tuple)
				{
					if (pin.StartsWith("item") && int32.Parse(pin.Substring(4)) case .Ok(let i))
						index = i;
				}
				else
					for (let f in t.Sym.AllFields)
						if (f.Name == pin)
							index = f.FieldIndex;
				let ex = E.Op(.Extract, Sub(n.FindOut(pin).Type, n), key, pin);
				ex.Operands.Add(v);
				ex.Index = index;
				return ex;
			case .MakeCase:
				let t = Sub(n.Subject);
				M.Need(t);
				if (!t.Sym.HasPayload)
					return E.Const(scope $".{n.Case.Name}", t, key, "value");
				List<IRValue> vals = scope .();
				for (let p in n.Case.Payload)
					vals.Add(EvalIn(n, p.Name));
				let op = E.Op(.CaseMake, t, key, "value");
				op.Sub = new String(n.Case.Name);
				op.Operands.AddRange(vals);
				return op;
			case .IsCase:
				var v = EvalIn(n, "value");
				let t = Sub(n.Subject);
				if (v.Type.Kind == .Pointer && v.Type.Element == t)
				{
					// `This` of an enum's own function is its address: the value itself.
					let ld = E.Op(.Load, t, key, pin);
					ld.Operands.Add(v);
					v = ld;
				}
				if (pin != "result")
					return Payload(v, t, n.Case.Name, pin, Sub(n.FindOut(pin).Type, n), key, pin);
				IRValue lhs = v;
				IRValue rhs;
				if (!t.Sym.HasPayload)
					rhs = E.Const(scope $".{n.Case.Name}", t, key, pin);
				else
				{
					let tag = E.Op(.EnumTag, T.Int32, key, pin);
					tag.Operands.Add(v);
					lhs = tag;
					rhs = E.Const(scope $"{n.Case.CaseValue}", T.Int32, key, pin);
				}
				let r = E.Op(.Cmp, T.Bool, key, pin);
				r.Sub = new String("eq");
				r.Operands.Add(lhs);
				r.Operands.Add(rhs);
				return r;
			case .Index:
				let coll = EvalIn(n, "collection");
				let idx = EvalIn(n, "index");
				if (n.Member != null && n.Member.Kind == .Operator)
				{
					// The collection type's operator [] (Bind's BindIndex).
					let owner = Sub(n.Owner, n);
					List<IRValue> args = scope .();
					args.Add(coll);
					args.Add(idx);
					return Invoke(n.Member, owner, null, .Body, args, Sub(n.FindOut("value").Type), key, "value", false);
				}
				return Element(coll, idx, Sub(n.FindOut("value").Type), key, "value");
			case .Math:
				return MathNodeValue(n);
			case .Bind:
				// A function pointer of a static function (or a C function).
				if (n.Member != null && !n.Flow && n.Member.Static)
				{
					String name = scope .();
					let owner = Sub(n.Owner ?? n.Member.Owner.Self, n);
					M.FuncRef(n.Member, owner, null, .Body, name);
					M.Use(n.Member, owner, name);
					let op = E.Op(.FnAddr, Sub(n.FindOut("value").Type, n), key, pin);
					op.Callee = new String(name);
					return op;
				}
			case .Lambda:
				// A function pointer Lambda: its Sheet is a static function of the type.
				let lr = n.LambdaSheet;
				if (lr != null && lr.LambdaType != null && lr.LambdaType.Kind == .Function)
				{
					let op = E.Op(.FnAddr, Sub(lr.LambdaType), key, pin);
					op.Callee = new String();
					M.LambdaKey(Inst, n.Key, Sub(lr.LambdaType), op.Callee, MethodArgs);
					return op;
				}
			default:
			}
			// Not lowered yet (Check warned): a zero of the pin's type.
			let o = n.FindOut(pin);
			return E.Const("zero", (o != null && o.Type != null && !o.Type.IsError) ? Sub(o.Type, n) : T.Int, key, pin);
		}

		/// Select (Rule 4): only the chosen input is made, through a slot.
		IRValue Lazy(BNode n)
		{
			let c = EvalIn(n, "condition");
			let t = Sub(n.FindOut("result").Type);
			let slot = Slot(n, "result", t, .OutTemp);
			let bYes = F.NewBlock(n.Key);
			let bNo = F.NewBlock(n.Key);
			let join = F.NewBlock(n.Key);
			E.Block.Term = .CondBr;
			E.Block.Cond = c;
			E.Block.Targets.Add(bYes);
			E.Block.Targets.Add(bNo);
			for (int arm < 2)
			{
				E.Block = (arm == 0) ? bYes : bNo;
				WithFreshMemo(scope [&]() =>
				{
					StoreSlot(slot, EvalIn(n, (arm == 0) ? "true" : "false"), n.Key, "result");
				});
				E.Br(join);
			}
			E.Block = join;
			return LoadSlot(slot, n.Key, "result");
		}

		IRValue OperatorNode(BNode n)
		{
			StringView op = n.Node.Text;
			let key = n.Key;
			let result = Sub(n.FindOut("result").Type, n);
			if (op == "valid")
			{
				// Is Valid: a `T?`'s has-value flag; an object not null (and in Debug not deleted: the back
				// end's obj.valid reads the poisoned vtable a Delete leaves); anything else not null.
				let a = EvalIn(n, "a");
				let at = Sub(n.OperandType ?? T.Error, n);
				if (at.Kind == .Nullable)
				{
					let has = E.Op(.Extract, T.Bool, key, "result");
					has.Operands.Add(a);
					has.Index = 1;
					return has;
				}
				if (at.IsClass || at.IsInterface)
				{
					let valid = E.Op(.Intrinsic, T.Bool, key, "result");
					valid.Sub = new String("obj.valid");
					valid.Operands.Add(a);
					return valid;
				}
				let nul = E.Const("null", a.Type, key, "result");
				let ne = E.Op(.Cmp, T.Bool, key, "result");
				ne.Sub = new String("ne");
				ne.Operands.Add(a);
				ne.Operands.Add(nul);
				return ne;
			}
			if (op == "&&" || op == "||")
			{
				// Rule 4: B only when A does not decide.
				let a = EvalIn(n, "a");
				let slot = Slot(n, "result", T.Bool, .OutTemp);
				StoreSlot(slot, a, key, "a");
				let bB = F.NewBlock(key);
				let join = F.NewBlock(key);
				E.Block.Term = .CondBr;
				E.Block.Cond = a;
				E.Block.Targets.Add((op == "&&") ? bB : join);
				E.Block.Targets.Add((op == "&&") ? join : bB);
				E.Block = bB;
				WithFreshMemo(scope [&]() =>
				{
					StoreSlot(slot, EvalIn(n, "b"), key, "b");
				});
				E.Br(join);
				E.Block = join;
				return LoadSlot(slot, key, "result");
			}
			let operand = Sub(n.OperandType ?? T.Error, n);
			let a = EvalIn(n, "a");
			let unary = op == "!" || op == "~" || op == "neg";
			let b = unary ? null : EvalIn(n, "b");
			if (operand.Kind == .Nullable && (op == "==" || op == "!="))
				return NullableCompare(op, operand, a, b, IsNullLiteral(n, "a") || IsNullLiteral(n, "b"), key);
			return Operate(op, operand, a, b, result, key, "result");
		}

		/// An input given the literal `null` (not wired).
		bool IsNullLiteral(BNode n, StringView pin)
		{
			let p = n.Node.FindInput(pin);
			return p != null && !R.Graph.IsLinked(p) && p.Default == "null";
		}

		/// `==` / `!=` of two `T?` (Language.md 2.2): equal when both are null, or both have a value
		/// and the values are equal; against the literal null only the has-value flags are compared.
		IRValue NullableCompare(StringView op, KType operand, IRValue a, IRValue b, bool flagsOnly, StringView key)
		{
			IRValue Field(IRValue v, KType t, int32 index)
			{
				let x = E.Op(.Extract, t, key, "result");
				x.Operands.Add(v);
				x.Index = index;
				return x;
			}
			IRValue Bin(StringView word, OpKind kind, IRValue x, IRValue y)
			{
				let r = E.Op(kind, T.Bool, key, "result");
				r.Sub = new String(word);
				r.Operands.Add(x);
				r.Operands.Add(y);
				return r;
			}
			let ha = Field(a, T.Bool, 1);
			let hb = Field(b, T.Bool, 1);
			var eq = Bin("eq", .Cmp, ha, hb);
			if (!flagsOnly)
			{
				let et = operand.Element;
				let ve = Operate("==", et, Field(a, et, 0), Field(b, et, 0), T.Bool, key, "result");
				// both null, or the values equal
				let noA = Bin("xor", .Binop, ha, E.Const("true", T.Bool, key, "result"));
				eq = Bin("and", .Binop, eq, Bin("or", .Binop, noA, ve));
			}
			if (op == "!=")
				eq = Bin("xor", .Binop, eq, E.Const("true", T.Bool, key, "result"));
			return eq;
		}


		IRValue CastNode(BNode n)
		{
			let v = EvalIn(n, "value");
			M.Need(v.Type);
			let to = Sub(n.Subject);
			let key = n.Key;
			if (n.Cast == .Unchecked && v.Type != null && v.Type.IsVector && to.IsVector)
				return VectorBits(v, to, key, "result"); // LowerVector.bf: Reinterpret (`set kind bits`)
			OpKind kind = .Cast;
			switch (n.Cast)
			{
			case .Identity: return v;
			case .Unwrap:
				// `T?` to `T`: a null is a fatal error naming the node (both configs: one branch); the
				// checked Cast tests the flag itself (EmitNode) and takes Failed
				if (!n.Checked)
				{
					let has = E.Op(.Extract, T.Bool, key, "result");
					has.Operands.Add(v);
					has.Index = 1;
					let ok = F.NewBlock(key);
					let bad = F.NewBlock(key);
					E.Block.Term = .CondBr;
					E.Block.Cond = has;
					E.Block.Targets.Add(ok);
					E.Block.Targets.Add(bad);
					E.Block.TermNode.Set(key);
					E.Block = bad;
					Fatal(n, 12, scope $"cast of a null {v.Type.Name} to {to.Name}");
					E.Block = ok;
				}
				let x = E.Op(.Extract, to, key, "result");
				x.Operands.Add(v);
				x.Index = 0;
				return x;
			case .Class: kind = .DynCast;
			case .Box: kind = .Box;
			case .Unbox: kind = .Unbox;
			case .Span: kind = .ArraySpan;
			default:
			}
			let op = E.Op(kind, to, key, "result");
			op.Operands.Add(v);
			M.Need(to);
			if (n.Node.HasSetting("test"))
			{
				// Is Type: whether the class cast gives an object.
				let nul = E.Const("null", to, key, "result");
				let ok = E.Op(.Cmp, T.Bool, key, "result");
				ok.Sub = new String("ne");
				ok.Operands.Add(op);
				ok.Operands.Add(nul);
				return ok;
			}
			return op;
		}

		// ------------------------------------------------------------------ variables

		/// The address of a field reached through `recv` (a class reference or a struct pointer).
		IRValue FieldAddr(IRValue recv, MemberSym f, KType ft, StringView node, StringView pin, bool check)
		{
			if (check && recv.Type.Kind != .Pointer)
				E.Op(.NullCheck, T.Void, node, "receiver").Operands.Add(recv);
			if (f.Owner.CBlob)
				return BlobAddr(recv, f, ft, node, pin);
			let a = E.Op(.FieldAddr, T.Pointer(ft), node, pin);
			a.Operands.Add(recv);
			a.Sub = new String(f.Name);
			return a;
		}

		// ------------------------------------------------------------------ C records by offset

		/// A C record the back end sees as bytes (a union, a packed or gapped struct).
		static bool IsBlob(KType t) => t != null && t.Kind == .Named && t.Sym.CBlob;

		/// A field of a C record reached by its byte offset from a pointer to the record.
		IRValue BlobAddr(IRValue p, MemberSym f, KType ft, StringView node, StringView pin)
		{
			let bytes = E.Op(.Cast, T.Pointer(T.UInt8), node, pin);
			bytes.Operands.Add(p);
			let off = E.Const(scope $"{f.COffset}", T.Int, node, pin);
			let at = E.Op(.ElemAddr, T.Pointer(T.UInt8), node, pin);
			at.Operands.Add(bytes);
			at.Operands.Add(off);
			let fp = E.Op(.Cast, T.Pointer(ft), node, pin);
			fp.Operands.Add(at);
			return fp;
		}

		/// A field of a C record value: the value goes to a temporary, the field is read by offset.
		IRValue BlobRead(IRValue v, MemberSym f, StringView node, StringView pin)
		{
			let t = v.Type;
			let ft = Sub(f.Type);
			let slot = F.NewSlot(t, .OutTemp, node, pin);
			StoreSlot(slot, v, node, pin);
			let addr = BlobAddr(SlotAddr(slot, node, pin), f, ft, node, pin);
			let ld = E.Op(.Load, ft, node, pin);
			ld.Operands.Add(addr);
			return ld;
		}

		/// Make of a C record the back end sees as bytes: zero, then each given field by offset.
		IRValue MakeBlob(BNode n, KType t)
		{
			let key = n.Key;
			let slot = F.NewSlot(t, .OutTemp, key, "value");
			StoreSlot(slot, E.Const("zero", t, key, "value"), key, "value");
			for (let f in t.Sym.AllFields)
			{
				let p = n.Node.FindInput(f.Name);
				if (p == null || (!R.Graph.IsLinked(p) && p.Default.IsEmpty))
					continue;
				let v = EvalIn(n, f.Name);
				let addr = BlobAddr(SlotAddr(slot, key, "value"), f, Sub(f.Type), key, f.Name);
				let st = E.Op(.Store, T.Void, key, f.Name);
				st.Operands.Add(addr);
				st.Operands.Add(v);
			}
			return LoadSlot(slot, key, "value");
		}

		void GlobalName(BNode n, String o)
		{
			// A core type's static fields are declared when the type is used (LowerCore.bf).
			if (n.Member.Owner.IsCore)
				M.Need(Sub(n.Owner, n));
			KirWriter.Type(Sub(n.Owner, n), o);
			o.AppendF(".{}", n.Member.Name);
		}

		IRValue GetVar(BNode n, StringView pin)
		{
			let key = n.Key;
			let t = Sub(n.FindOut("value").Type, n);
			let cap = CaptureOf(n);
			if (cap != null)
			{
				let addr = CaptureAddr(cap, key, "value");
				let ld = E.Op(.Load, t, key, "value");
				ld.Operands.Add(addr);
				return ld;
			}
			switch (n.Var)
			{
			case .Local:
				if (mVars.TryGetValue(scope String()..AppendF("local:{}", n.LocalVar.Name), let slot))
					return LoadSlot(slot, key, "value");
			case .Param:
				StringView name = (n.ParamVar != null) ? (StringView)n.ParamVar.Name : "value";
				if (mVars.TryGetValue(scope String()..AppendF("param:{}", name), let slot))
					return LoadSlot(slot, key, "value");
				if (mParams.TryGetValue(scope String(name), let pv))
					return ByRefParamValue(pv, name, key, "value");
			case .OutParam:
				if (mParams.TryGetValue(scope String(n.ParamVar.Name), let pv))
				{
					let ld = E.Op(.Load, t, key, "value");
					ld.Operands.Add(pv);
					return ld;
				}
			case .Field:
				let recv = EvalIn(n, "receiver");
				let owner = Sub(n.Owner, n);
				if (owner.Kind == .Named && owner.Sym.Kind == .Struct && recv.Type.Kind != .Pointer)
				{
					if (owner.Sym.CBlob)
						return BlobRead(recv, n.Member, key, "value");
					let ex = E.Op(.Extract, t, key, "value");
					ex.Operands.Add(recv);
					ex.Index = n.Member.FieldIndex;
					return ex;
				}
				if (owner.Kind == .Named && owner.Sym == T.StringViewSym && recv.Type.Kind == .Pointer)
				{
					// The built-in StringView has no field.addr: the view, then its field.
					let view = E.Op(.Load, owner, key, "value");
					view.Operands.Add(recv);
					let ex = E.Op(.Extract, t, key, "value");
					ex.Operands.Add(view);
					ex.Index = n.Member.FieldIndex;
					return ex;
				}
				let a = FieldAddr(recv, n.Member, t, key, "value", !n.ReceiverIsThis);
				let ld = E.Op(.Load, t, key, "value");
				ld.Operands.Add(a);
				return ld;
			case .StaticField:
				// A constant (a `cconst` of a C import set too) is its folded value, inlined; a
				// const array a Span over its read-only global (Language.md 4.6).
				if (n.Member.Const)
					return ConstValue(n, t);
				IRValue a;
				if (n.Member.CVar)
				{
					// An extern C variable: its address, or the value its function gives.
					a = CVarAddr(n.Member, key, "value");
					if (a == null)
						return CVarCall(n.Member, key, "value");
				}
				else
				{
					let ga = E.Op(.GlobalAddr, T.Pointer(t), key, "value");
					ga.Global = new String();
					GlobalName(n, ga.Global);
					a = ga;
				}
				let ld = E.Op(.Load, t, key, "value");
				ld.Operands.Add(a);
				return ld;
			case .Property:
				let owner = Sub(n.Owner, n);
				List<IRValue> args = scope .();
				if (!n.Member.Static)
					args.Add(EvalIn(n, "receiver"));
				return Invoke(n.Member, owner, null, .Get, args, t, key, "value", n.ReceiverIsBase);
			case .ArrayLength:
				let arr = EvalIn(n, "receiver");
				E.Op(.NullCheck, T.Void, key, "receiver").Operands.Add(arr);
				let len = E.Op(.ArrayLen, T.Int, key, "value");
				len.Operands.Add(arr);
				return len;
			default:
			}
			return E.Const("default", t, key, pin);
		}

		/// A core library intrinsic the back end has an op for (null: the call is a normal call).
		IRValue IntrinsicCall(MemberSym f, List<IRValue> args, KType result, StringView node, StringView pin)
		{
			StringView name = f.Intrinsic;
			IROp Intr(StringView what, KType type)
			{
				let op = E.Op(.Intrinsic, type, node, pin);
				op.Sub = new String(what);
				op.Operands.AddRange(args);
				return op;
			}
			let core = CoreIntrinsic(name, args, result, node, pin, var handled);
			if (handled)
				return core;
			switch (name)
			{
			case "Console.WriteLine(StringView)": Intr("console.writeline", T.Void); return null;
			case "Console.Write(StringView)": Intr("console.write", T.Void); return null;
			case "Math.Sqrt": return Intr("sqrt", result);
			case "Math.Abs(double)", "Math.Abs(float)": return Intr("fabs", result);
			case "Math.Floor": return Intr("floor", result);
			case "Math.Ceil": return Intr("ceil", result);
			case "Memory.Copy": Intr("memcpy", T.Void); return null;
			case "Memory.Set": Intr("memset", T.Void); return null;
			case "Memory.Compare": return Intr("memcmp", result);
			case "Math.Abs(int)":
				let zero = E.Const("0", result, node, pin);
				let neg = E.Op(.Binop, result, node, pin);
				neg.Sub = new String("sub");
				neg.Operands.Add(zero);
				neg.Operands.Add(args[0]);
				let lt = E.Op(.Cmp, T.Bool, node, pin);
				lt.Sub = new String("lt");
				lt.Operands.Add(args[0]);
				lt.Operands.Add(zero);
				let sel = E.Op(.Select, result, node, pin);
				sel.Operands.Add(lt);
				sel.Operands.Add(neg);
				sel.Operands.Add(args[0]);
				return sel;
			case "Math.Min", "Math.Max":
				let lt = Operate("<", result, args[0], args[1], T.Bool, node, pin);
				let sel = E.Op(.Select, result, node, pin);
				sel.Operands.Add(lt);
				sel.Operands.Add((name == "Math.Min") ? args[0] : args[1]);
				sel.Operands.Add((name == "Math.Min") ? args[1] : args[0]);
				return sel;
			case "Atomic.Load":
				let op = E.Op(.AtomicLoad, result, node, pin);
				op.Order = new String(mOrder);
				op.Operands.Add(args[0]);
				return op;
			case "Atomic.Store":
				let op = E.Op(.AtomicStore, T.Void, node, pin);
				op.Order = new String(mOrder);
				op.Operands.AddRange(args);
				return null;
			case "Atomic.add", "Atomic.sub", "Atomic.and", "Atomic.or", "Atomic.xor", "Atomic.min", "Atomic.max", "Atomic.xchg":
				let op = E.Op(.AtomicRmw, result, node, pin);
				op.Sub = new String(name.Substring(7));
				op.Order = new String(mOrder);
				op.Operands.AddRange(args);
				return op;
			case "Atomic.CompareExchange":
				// (old, replaced): the old value is the result, `replaced` goes to the out input.
				let pair = E.Op(.AtomicCas, T.Tuple(scope KType[](result, T.Bool)), node, pin);
				pair.Order = new String(mOrder);
				pair.Operands.Add(args[0]);
				pair.Operands.Add(args[1]);
				pair.Operands.Add(args[2]);
				let old = E.Op(.Extract, result, node, pin);
				old.Operands.Add(pair);
				old.Index = 0;
				let done = E.Op(.Extract, T.Bool, node, pin);
				done.Operands.Add(pair);
				done.Index = 1;
				if (args.Count > 3)
				{
					let st = E.Op(.Store, T.Void, node, pin);
					st.Operands.Add(args[3]);
					st.Operands.Add(done);
				}
				return old;
			case "Atomic.Fence":
				E.Op(.Fence, T.Void, node, pin).Order = new String(mOrder);
				return null;
			default:
			}
			return null;
		}

		/// C's default promotions for a variadic argument (bool, char and integers below 32 bits
		/// become int32, float becomes double).
		IRValue Promote(IRValue v, StringView node, StringView pin)
		{
			let t = v.Type;
			KType to = null;
			if (t.Kind == .Bool || t.Kind == .Char || (t.Kind == .Int && t.Bits < 32))
				to = T.Int32;
			else if (t.Kind == .Float && t.Bits < 64)
				to = T.Double;
			else if (t.IsEnum)
				to = t.Sym.Underlying ?? T.Int32;
			if (to == null)
				return v;
			let c = E.Op(.Cast, to, node, pin);
			c.Operands.Add(v);
			return c;
		}

		static bool IsIntrinsicOp(MemberSym f) => f.Intrinsic != null && f.Intrinsic != "Runtime.Fatal";

		/// A call of `f` (a member of `owner`), the receiver first when it has one.
		IRValue Invoke(MemberSym f, KType owner, List<KType> methodArgs, SheetRole role, List<IRValue> args, KType result, StringView node, StringView pin, bool baseCall)
		{
			if (IsIntrinsicOp(f))
				return IntrinsicCall(f, args, result, node, pin);
			if (f.Intrinsic == "Runtime.Fatal")
			{
				let op = E.Op(.Intrinsic, T.Void, node, pin);
				op.Sub = new String("console.error");
				op.Operands.AddRange(args);
				return null;
			}
			String name = scope .();
			IROp op;
			if (!f.Static && f.VSlot >= 0 && !baseCall && !f.Sealed)
			{
				let d = M.Declaring(f);
				let dOwner = M.InstanceOf(owner, d.Owner);
				M.FuncRef(d, dOwner, null, role, name);
				M.Use(d, dOwner, name);
				op = E.Op(.VCall, result, node, pin);
			}
			else if (!f.Static && owner.Kind == .Named && owner.Sym.Kind == .Interface && f.ISlot >= 0)
			{
				M.FuncRef(f, (f.Owner == owner.Sym) ? owner : f.Owner.Self, null, role, name);
				M.Use(f, owner, name);
				op = E.Op(.ICall, result, node, pin);
			}
			else
			{
				M.FuncRef(f, owner, methodArgs, role, name);
				M.Use(f, owner, name, methodArgs);
				op = E.Op(f.IsImport ? .CCall : .Call, result, node, pin);
			}
			op.Callee = new String(name);
			op.Operands.AddRange(args);
			return op;
		}

		/// An event's node (Language.md 4, Event): a call of its `Core.Event<D>` storage's Add, Remove,
		/// Clear or Count through the field's address; Invoke is a loop here, `invoke` of each handler
		/// in order (the count is read again each pass, so a handler may Remove itself).
		IRValue EventCall(BNode n, StringView pin)
		{
			let key = n.Key;
			let field = n.Member;
			let et = Sub(field.Type, n);
			let es = et.Sym;
			var recv = EvalIn(n, "receiver");
			let addr = FieldAddr(recv, field, et, key, "receiver", !n.ReceiverIsThis);
			MemberSym Fn(StringView name)
			{
				for (let m in es.Members)
					if (m.Name == name && m.Kind != .Field)
						return m;
				return null;
			}
			List<IRValue> args = scope .();
			args.Add(addr);
			switch (n.EventOp)
			{
			case .Add, .Remove:
				args.Add(EvalIn(n, "handler"));
				return Invoke(Fn((n.EventOp == .Add) ? "Add" : "Remove"), et, null, .Body, args, (n.EventOp == .Add) ? T.Void : T.Bool, key, "", false);
			case .Clear:
				return Invoke(Fn("Clear"), et, null, .Body, args, T.Void, key, "", false);
			case .Count:
				return Invoke(Fn("Count"), et, null, .Get, args, T.Int, key, n.Flow ? "" : pin, false);
			case .Invoke:
				let d = et.Args[0];
				List<IRValue> values = scope .();
				for (int i < d.Args.Count)
					values.Add(EvalIn(n, scope $"arg{i}"));
				let idx = Slot(n, "index", T.Int, .OutTemp);
				StoreSlot(idx, E.Const("0", T.Int, key, "index"), key, "index");
				let header = F.NewBlock(key);
				let body = F.NewBlock(key);
				let done = F.NewBlock(key);
				E.Br(header);
				E.Block = header;
				let count = Invoke(Fn("Count"), et, null, .Get, args, T.Int, key, "", false);
				let cur = LoadSlot(idx, key, "index");
				let more = E.Op(.Cmp, T.Bool, key, "");
				more.Sub = new String("lt");
				more.Operands.Add(cur);
				more.Operands.Add(count);
				E.Block.Term = .CondBr;
				E.Block.Cond = more;
				E.Block.Targets.Add(body);
				E.Block.Targets.Add(done);
				E.Block.TermNode.Set(key);
				E.Block = body;
				List<IRValue> atArgs = scope .();
				atArgs.Add(addr);
				atArgs.Add(LoadSlot(idx, key, "index"));
				let h = Invoke(Fn("At"), et, null, .Body, atArgs, d, key, "", false);
				let call = E.Op(.Invoke, T.Void, key, "");
				call.Operands.Add(h);
				call.Operands.AddRange(values);
				let i0 = LoadSlot(idx, key, "index");
				let one = E.Const("1", T.Int, key, "index");
				let next = E.Op(.Binop, T.Int, key, "index");
				next.Sub = new String("add");
				next.Operands.Add(i0);
				next.Operands.Add(one);
				StoreSlot(idx, next, key, "index");
				E.Br(header);
				E.Block = done;
				return null;
			default:
				return null;
			}
		}

		/// A Call node: the Receiver first, then the arguments in parameter order (Rule 5).
		IRValue CallNode(BNode n, StringView pin)
		{
			let f = n.Member;
			let key = n.Key;
			if (n.VecFn != .None)
				return VectorCallNode(n, pin); // LowerVector.bf: Core.Vector, Core.Math on vectors
			if (f == null)
				return E.Const("zero", T.Int, key, pin);
			if (n.EventOp != .None)
				return EventCall(n, pin);
			if (n.KernelFn != null)
				return KernelCallNode(n, pin); // KernelLower.bf: Gpu.Dispatch, Kernel.RunCpu
			let owner = Sub(n.Owner, n);
			List<IRValue> args = scope .();
			if (!f.Static)
			{
				IRValue recv = null;
				if (f.Mutating && !n.ReceiverIsThis && owner.IsStruct)
				{
					// A Mutating call changes the place its Receiver names (Language.md 2.2): its
					// address; Bind refused a temporary (T2272).
					let (rn, rp) = R.Source(n, "receiver");
					if (rp != null)
						recv = PlaceAddr(rn, rp.Name, owner, key, "receiver");
				}
				if (recv == null)
					recv = EvalIn(n, "receiver");
				if (owner.Kind == .Named && (owner.Sym.Kind == .Struct || owner.Sym.Kind == .Enum) && recv.Type.Kind != .Pointer)
				{
					// `ref this`: a struct receiver needs an address; a copy for a function that
					// does not change it.
					let slot = Slot(n, "receiver", owner, .OutTemp);
					StoreSlot(slot, recv, key, "receiver");
					recv = SlotAddr(slot, key, "receiver");
				}
				else if (!n.ReceiverIsThis && recv.Type.IsReference)
					E.Op(.NullCheck, T.Void, key, "receiver").Operands.Add(recv);
				args.Add(recv);
			}
			for (let p in f.Params)
			{
				if (p.IsRef || p.Mode == .In || n.IsAddressArg(p.Name))
					args.Add(AddressOf(n, p.Name));
				else
					args.Add(EvalIn(n, p.Name));
			}
			for (let p in f.Outs)
			{
				let slot = Slot(n, p.Name, Sub(p.Type, n), .OutTemp);
				args.Add(SlotAddr(slot, key, p.Name));
			}
			if (n.VarArgs != null)
				for (let va in n.VarArgs)
					args.Add(Promote(EvalIn(n, va), key, va));
			mOrder.Set((n.Order != null) ? (StringView)n.Order : "seqcst");
			List<KType> margs = null;
			if (n.MethodArgs != null)
			{
				margs = scope:: .();
				for (let a in n.MethodArgs)
					margs.Add(Sub(a));
			}
			let resOut = n.FindOut("result");
			let result = f.Returns.IsVoid ? T.Void : Sub((resOut != null) ? resOut.Type : f.Returns, n);
			return Invoke(f, owner, margs, .Body, args, result, key, n.Flow ? "" : pin, n.ReceiverIsBase);
		}

		/// The function of a C import set that reads an extern variable (`via`).
		static MemberSym CVarFunction(MemberSym v)
		{
			for (let m in v.Owner.Members)
				if (m.Kind == .Function && m.Name == v.CVarVia)
					return m;
			return null;
		}

		/// The address of an extern C variable (`cvar`, docs/C-Import.md): the imported global
		/// itself, or what its function gives (`via _errno deref`); null for one its function gives
		/// by value (`via __acrt_iob_func 1`).
		IRValue CVarAddr(MemberSym v, StringView node, StringView pin)
		{
			if (v.CVarVia == null)
			{
				M.ImportGlobal(v);
				let a = E.Op(.GlobalAddr, T.Pointer(v.Type), node, pin);
				a.Global = new String();
				a.Global.AppendF("{}.{}", v.Owner.FullName, v.Name);
				return a;
			}
			if (!v.CVarDeref)
				return null;
			return CVarCall(v, node, pin);
		}

		/// The call of a `via` function: its result is the variable's address (deref) or its value.
		IRValue CVarCall(MemberSym v, StringView node, StringView pin)
		{
			let f = CVarFunction(v);
			if (f == null)
				return E.Const("zero", v.CVarDeref ? T.Pointer(v.Type) : v.Type, node, pin);
			List<IRValue> args = scope .();
			if (f.Params.Count == 1)
				args.Add(E.Const((v.CVarArg != null) ? (StringView)v.CVarArg : "0", f.Params[0].Type, node, pin));
			return Invoke(f, v.Owner.Self, null, .Body, args, f.Returns, node, pin, false);
		}

		/// The address of the place the output `outPin` of `src` names (SheetResult.IsPlace): a
		/// variable, a field of an object or of a place, `this`, a struct Local's object, an element
		/// of an array, a span or a pointer; `t` is the type the address points to. Null (and nothing
		/// emitted) when it is not a place, or is a parameter no Set or address made a variable.
		IRValue PlaceAddr(BNode src, StringView outPin, KType t, StringView node, StringView pin)
		{
			if (!R.IsPlace(src, outPin))
				return null;
			if (src == R.Entry)
			{
				// A parameter: the variable it became (ParamSlot).
				if (mVars.TryGetValue(scope String()..AppendF("param:{}", outPin), let slot))
					return SlotAddr(slot, node, pin);
				return RefParamAddr(outPin);
			}
			switch (src.Kind)
			{
			case .This:
				let th = ThisAs(t);
				return (th.Type.Kind == .Pointer || th.Type.IsReference) ? th : null;
			case .Local:
				if (mLocals.TryGetValue(src, let slot))
					return SlotAddr(slot, node, pin);
				return null;
			case .Index:
				let coll = EvalIn(src, "collection");
				let idx = EvalIn(src, "index");
				return ElementAddr(coll, idx, t, node, pin);
			default:
			}
			let cap = CaptureOf(src);
			if (cap != null)
				return CaptureAddr(cap, node, pin);
			switch (src.Var)
			{
			case .Local:
				if (mVars.TryGetValue(scope String()..AppendF("local:{}", src.LocalVar.Name), let slot))
					return SlotAddr(slot, node, pin);
			case .Param:
				if (src.ParamVar != null && mVars.TryGetValue(scope String()..AppendF("param:{}", src.ParamVar.Name), let slot))
					return SlotAddr(slot, node, pin);
				if (src.ParamVar != null && !src.IsCapture)
					return RefParamAddr(src.ParamVar.Name);
			case .OutParam:
				if (src.ParamVar != null && mParams.TryGetValue(scope String(src.ParamVar.Name), let pv))
					return pv;
			case .Field:
				let owner = Sub(src.Owner, src);
				IRValue recv;
				let (rn, rp) = R.Source(src, "receiver");
				let rt = (rp != null) ? rn.FindOut(rp.Name)?.Type : null;
				if (owner.IsStruct && !src.ReceiverIsThis && !(rt != null && rt.Kind == .Pointer))
				{
					// A field of a struct place: the place's address, then the field's.
					if (owner.Sym == T.StringViewSym)
						return null;
					recv = (rp != null) ? PlaceAddr(rn, rp.Name, owner, node, pin) : null;
					if (recv == null)
						return null;
				}
				else
					recv = EvalIn(src, "receiver");
				if (owner.IsStruct && recv.Type.Kind != .Pointer)
					return null;
				return FieldAddr(recv, src.Member, t, node, pin, !src.ReceiverIsThis);
			case .StaticField:
				if (src.Member.CVar)
					return CVarAddr(src.Member, node, pin);
				let a = E.Op(.GlobalAddr, T.Pointer(t), node, pin);
				a.Global = new String();
				GlobalName(src, a.Global);
				return a;
			default:
			}
			return null;
		}

		/// The address of the variable wired into a `ref` / `in` input.
		IRValue AddressOf(BNode n, StringView pin)
		{
			let spec = n.FindIn(pin);
			let t = Sub(spec.Type, n);
			let l = (spec.Pin != null) ? R.Graph.FindLinkTo(spec.Pin) : null;
			let src = (l != null) ? R.Get(l.From.Owner) : null;
			if (src != null && src.Kind == .Get && src.Var == .StaticField && src.Member != null && src.Member.Const && src.Member.ConstElements == null &&
				src.Member.ConstValue != null && Sub(src.Member.Type, src) == t)
			{
				// the address of a constant: its read-only global (only then is there one)
				let ca = ConstAddr(src, t, n.Key, pin);
				if (ca != null)
					return ca;
			}
			if (src != null && (src.Kind == .Get || src.Kind == .This || src == R.Entry))
			{
				let a = PlaceAddr(src, l.From.Name, t, n.Key, pin);
				if (a != null)
					return a;
			}
			// Anything else: a temporary (Check asked for a variable already).
			let slot = Slot(n, pin, t, .OutTemp);
			StoreSlot(slot, EvalIn(n, pin), n.Key, pin);
			return SlotAddr(slot, n.Key, pin);
		}

		// ------------------------------------------------------------------ flow nodes

		void Fatal(BNode n, int32 code, StringView message)
		{
			E.Block.Term = .Fatal;
			E.Block.FatalCode = code;
			E.Block.FatalMessage = new String(message);
			E.Block.TermNode.Set(n.Key);
		}

		void EmitNode(BNode n)
		{
			let key = n.Key;
			switch (n.Kind)
			{
			case .Return:
				IRValue v = null;
				if (n.FindIn("value") != null)
					v = EvalIn(n, "value");
				for (let o in R.Member.Outs)
				{
					if (mLambda)
						break;
					let ov = EvalIn(n, o.Name);
					if (mParams.TryGetValue(scope String(o.Name), let p))
					{
						let st = E.Op(.Store, T.Void, key, o.Name);
						st.Operands.Add(p);
						st.Operands.Add(ov);
					}
				}
				LeaveAll(n.Region, n);
				FunctionExit(v, n);
			case .Set:
				EmitSet(n);
				Goto(n, "then");
			case .Call:
				let r = CallNode(n, "");
				if (n.Member != null && n.Member.Intrinsic == "Runtime.Fatal")
				{
					LeaveAll(n.Region, n);
					Fatal(n, 1, "fatal error");
					return;
				}
				if (r != null && r.Type != null && !r.Type.IsVoid)
					StoreSlot(OutSlot(n, "result"), r, key, "result");
				if (n.Member != null && n.Member.ExpandAsFlow && n.Member.Returns.IsEnum)
				{
					// One flow output per case.
					let sw = E.Block;
					sw.Term = .Switch;
					sw.Cond = r;
					sw.TermNode.Set(key);
					List<(IRBlock b, MemberSym cs)> arms = scope .();
					for (let cs in n.Member.Returns.Sym.Members)
					{
						if (cs.Kind != .Case)
							continue;
						let b = F.NewBlock(key);
						sw.Cases.Add(cs.CaseValue);
						sw.Targets.Add(b);
						arms.Add((b, cs));
					}
					let def = F.NewBlock(key);
					sw.Targets.Add(def);
					for (let a in arms)
					{
						E.Block = a.b;
						Goto(n, scope $"case:{a.cs.Name}");
					}
					E.Block = def;
				}
				Goto(n, "then");
			case .Construct, .Local:
				EmitConstruct(n);
				Goto(n, "then");
			case .Delete:
				let obj = EvalIn(n, "object");
				if (n.WithAllocator)
					DeleteWith(n, obj);
				else
					E.Op(.Delete, T.Void, key, "object").Operands.Add(obj);
				Goto(n, "then");
			case .DeferDelete, .Defer:
				let body = DeferBody(n);
				let op = E.Op(.Defer, T.Void, key, "");
				op.Region = mRegions[n.Region ?? R.Regions[0]];
				op.Target = body;
				Goto(n, (n.Kind == .Defer) ? "done" : "then");
			case .Branch:
				let c = EvalIn(n, "condition");
				Fork(n, c, "true", "false");
			case .Sequence:
				Goto(n, "then0");
			case .While, .DoWhile, .For, .ForEach:
				EmitLoop(n);
			case .Break, .Continue:
				let loop = LoopOf(n.Region);
				if (loop == null)
				{
					E.Block.Term = .Unreachable;
					return;
				}
				var cur = n.Region;
				while (cur != null)
				{
					Exit(cur, n);
					if (cur == loop)
						break;
					cur = cur.Parent;
				}
				let info = mLoops[loop.Owner];
				E.Br((n.Kind == .Break) ? info.done : info.latch);
			case .Switch:
				EmitSwitch(n);
			case .Scope:
				Goto(n, "body");
			case .ResultMatch, .Try:
				let rv = EvalIn(n, "result");
				StoreSlot(OutSlot(n, "result"), rv, key, "result");
				let tag = E.Op(.EnumTag, T.Int32, key, "result");
				tag.Operands.Add(rv);
				let zero = E.Const("0", T.Int32, key, "result");
				let isOk = E.Op(.Cmp, T.Bool, key, "result");
				isOk.Sub = new String("eq");
				isOk.Operands.Add(tag);
				isOk.Operands.Add(zero);
				if (n.Kind == .ResultMatch)
				{
					Fork(n, isOk, "ok", "err");
					return;
				}
				let okB = F.NewBlock(key);
				let errB = F.NewBlock(key);
				E.Block.Term = .CondBr;
				E.Block.Cond = isOk;
				E.Block.Targets.Add(okB);
				E.Block.Targets.Add(errB);
				E.Block.TermNode.Set(key);
				E.Block = errB;
				let rt = Sub(n.FindIn("result").Type);
				IRValue back = rv;
				if (rt != F.Ret)
				{
					// Result<B,E>.Err(e) from the Result<A,E> read: the error is taken out first, so
					// the op that makes the new Result comes after the one it reads.
					IRValue error = null;
					if (rt.Kind == .Named && rt.Args.Count == 2 && !rt.Args[1].IsVoid)
						error = Payload(rv, rt, "Err", "error", rt.Args[1], key, "result");
					let made = E.Op(.CaseMake, F.Ret, key, "");
					made.Sub = new String("Err");
					if (error != null)
						made.Operands.Add(error);
					back = made;
				}
				LeaveAll(n.Region, n);
				FunctionExit(back, n);
				E.Block = okB;
				Goto(n, "then");
			case .Fatal:
				let msg = EvalIn(n, "message");
				let op = E.Op(.Intrinsic, T.Void, key, "message");
				op.Sub = new String("console.error");
				op.Operands.Add(msg);
				LeaveAll(n.Region, n);
				Fatal(n, 1, "Fatal node");
			case .Cast:
				if (n.Checked && n.Cast == .Unwrap)
				{
					// Succeeded with the value when the `T?` has one, Failed when it is null.
					let v = EvalIn(n, "value");
					let has = E.Op(.Extract, T.Bool, key, "result");
					has.Operands.Add(v);
					has.Index = 1;
					let x = E.Op(.Extract, Sub(n.Subject), key, "result");
					x.Operands.Add(v);
					x.Index = 0;
					StoreSlot(OutSlot(n, "result"), x, key, "result");
					Fork(n, has, "then", "failed");
					return;
				}
				let r = CastNode(n);
				StoreSlot(OutSlot(n, "result"), r, key, "result");
				if (n.Checked)
				{

					// Succeeded when the class cast gives an object, Failed otherwise.
					let nul = E.Const("null", r.Type, key, "result");
					let ok = E.Op(.Cmp, T.Bool, key, "result");
					ok.Sub = new String("ne");
					ok.Operands.Add(r);
					ok.Operands.Add(nul);
					Fork(n, ok, "then", "failed");
					return;
				}
				Goto(n, "then");
			case .Gate, .DoOnce, .DoN, .FlipFlop, .MultiGate, .GateOpen, .GateClose, .GateToggle, .ResetDoOnce, .ResetDoN, .ResetMultiGate:
				EmitStateful(n);
			case .Bind:
				EmitBind(n);
				Goto(n, "then");
			case .Lambda:
				EmitLambda(n);
				Goto(n, "then");
			case .Invoke:
				EmitInvoke(n);
				Goto(n, "then");
			default:
				// A node kind not lowered yet (Check warned): the program stops here with the
				// node named.
				String title = scope .();
				n.Node.GetTitle(title);
				Fatal(n, 2, scope $"{title} is not compiled yet");
			}
		}

		// ------------------------------------------------------------------ delegates (Compiler.md 4)

		/// Bind Function as a flow node: `bind` (heap) or `bind.local` (in the node's region) of the
		/// function, with its target for a member function (a virtual or interface function is
		/// named by its declaring slot and resolved from the target when bound).
		void EmitBind(BNode n)
		{
			let f = n.Member;
			let key = n.Key;
			if (f == null)
				return;
			let lt = Sub(n.FindOut("value").Type, n);
			var target = f;
			var owner = Sub(n.Owner ?? f.Owner.Self, n);
			if (!f.Static && f.VSlot >= 0 && !f.Sealed)
			{
				target = M.Declaring(f);
				owner = M.InstanceOf(owner, target.Owner);
			}
			String name = scope .();
			M.FuncRef(target, owner, null, .Body, name);
			M.Use(target, owner, name);
			IRValue recv = null;
			if (n.StructTarget)
			{
				// A struct's function: the target is the struct's address (Bind.BindStructTarget).
				recv = n.ReceiverIsThis ? ThisAs(T.Pointer(owner)) : AddressOf(n, "receiver");
			}
			else if (!f.Static)
			{
				recv = EvalIn(n, "receiver");
				if (!n.ReceiverIsThis)
					E.Op(.NullCheck, T.Void, key, "receiver").Operands.Add(recv);
				recv = Convert(recv, recv.Type, owner, key, "receiver");
			}
			IROp op;
			if (n.Alloc == .Local && mLocals.TryGetValue(n, let slot))
			{
				op = E.Op(.BindLocal, lt, key, "value");
				op.Slot = slot;
			}
			else
				op = E.Op(.Bind, lt, key, "value");
			op.Callee = new String(name);
			if (recv != null)
				op.Operands.Add(recv);
			StoreSlot(OutSlot(n, "value"), op, key, "value");
		}

		/// A delegate Lambda: its closure object (heap or Local), the captures stored in it (the
		/// variable's address for a by-ref capture), then `closure` makes it the delegate.
		void EmitLambda(BNode n)
		{
			let key = n.Key;
			let lr = n.LambdaSheet;
			if (lr == null || n.Closure == null)
				return;
			let cl = M.Closure(Inst, n.Key, MethodArgs).Self;
			IROp c;
			if (n.Alloc == .Local && mLocals.TryGetValue(n, let slot))
			{
				c = E.Op(.Local, cl, key, "value");
				c.Slot = slot;
			}
			else
				c = E.Op(.Alloc, cl, key, "value");
			for (let cap in lr.Captures)
			{
				let t = (cap.What == .This) ? M.ThisType(Inst) : Sub(cap.Type);
				IRValue v = null;
				String varKey = scope .();
				varKey.AppendF("{}:{}", (cap.What == .Local) ? "local" : "param", cap.Name);
				// Inside a Lambda Sheet a variable that is not one of its own inputs is a capture of
				// this Sheet too (Bind chains it): read it from this closure's field (or through the
				// pointer the field holds), and a by-ref capture takes that address.
				let outer = (mLambda && cap.What != .This && !(cap.What == .Param && R.FindLambdaParam(cap.Name) != null)) ? R.FindCapture(cap.What, cap.Name) : null;
				if (cap.What == .This)
					v = ThisAs(t);
				else if (outer != null)
				{
					let addr = CaptureAddr(outer, key, "value");
					if (cap.ByRef)
						v = addr;
					else
					{
						let ld = E.Op(.Load, t, key, "value");
						ld.Operands.Add(addr);
						v = ld;
					}
				}
				else if (cap.ByRef)
				{
					if (mVars.TryGetValue(varKey, let vs))
						v = SlotAddr(vs, key, "value");
				}
				else if (mVars.TryGetValue(varKey, let vs))
					v = LoadSlot(vs, key, "value");
				else if (cap.What == .Param && mParams.TryGetValue(scope String(cap.Name), let pv))
					v = pv;
				if (v == null)
					continue;
				let fa = E.Op(.FieldAddr, T.Pointer(cap.ByRef ? T.Pointer(t) : t), key, "value");
				fa.Operands.Add(c);
				fa.Sub = new String();
				cap.FieldName(fa.Sub);
				let st = E.Op(.Store, T.Void, key, "value");
				st.Operands.Add(fa);
				st.Operands.Add(v);
			}
			let d = E.Op(.Closure, Sub(lr.LambdaType), key, "value");
			d.Operands.Add(c);
			d.Callee = new String();
			M.LambdaKey(Inst, n.Key, Sub(lr.LambdaType), d.Callee, MethodArgs);
			StoreSlot(OutSlot(n, "value"), d, key, "value");
		}

		/// Invoke: `invoke` of a delegate (null-checked), `fptr.call` of a function pointer.
		void EmitInvoke(BNode n)
		{
			let key = n.Key;
			let spec = n.FindIn("delegate");
			if (spec == null || spec.Type == null || spec.Type.IsError)
				return;
			let dt = Sub(spec.Type, n);
			let d = EvalIn(n, "delegate");
			List<IRValue> args = scope .();
			for (let i in n.Ins)
				if (i.Type != null && i.Name != "delegate")
					args.Add(EvalIn(n, i.Name));
			if (dt.Kind == .Delegate)
				E.Op(.NullCheck, T.Void, key, "delegate").Operands.Add(d);
			let r = E.Op((dt.Kind == .Delegate) ? .Invoke : .FptrCall, Sub(dt.Element), key, "");
			r.Operands.Add(d);
			r.Operands.AddRange(args);
			if (r.HasResult)
				StoreSlot(OutSlot(n, "result"), r, key, "result");
		}

		/// A two-way branch to the edges of two flow outputs.
		void Fork(BNode n, IRValue cond, StringView yes, StringView no)
		{
			let from = E.Block;
			let a = F.NewBlock(n.Key);
			let b = F.NewBlock(n.Key);
			from.Term = .CondBr;
			from.Cond = cond;
			from.Targets.Add(a);
			from.Targets.Add(b);
			from.TermNode.Set(n.Key);
			E.Block = a;
			Goto(n, yes);
			E.Block = b;
			Goto(n, no);
		}

		void EmitSet(BNode n)
		{
			let key = n.Key;
			let t = Sub(n.FindIn("value").Type, n);
			IRValue recv = null;
			if (n.Var == .Field && !n.ReceiverIsThis && !n.IsCapture && n.Owner != null && n.Owner.IsStruct)
			{
				// A field of a struct place (a `ref` parameter, a variable, a field of one): the
				// place's address, so the Set lands there (Language.md 2.2); a struct value that is
				// not a place goes to a temporary (the Set changes that copy).
				let (rn, rp) = R.Source(n, "receiver");
				let rt = (rp != null) ? rn.FindOut(rp.Name)?.Type : null;
				if (rp != null && !(rt != null && rt.Kind == .Pointer))
				{
					let owner = Sub(n.Owner, n);
					recv = PlaceAddr(rn, rp.Name, owner, key, "receiver");
					if (recv == null)
					{
						let rv = EvalIn(n, "receiver");
						if (rv.Type.Kind != .Pointer && !rv.Type.IsReference)
						{
							let slot = Slot(n, "receiver", owner, .OutTemp);
							StoreSlot(slot, rv, key, "receiver");
							recv = SlotAddr(slot, key, "receiver");
						}
						else
							recv = rv;
					}
				}
			}
			if (recv == null && (n.Var == .Field || (n.Var == .Property && !n.Member.Static)))
				recv = EvalIn(n, "receiver");
			var v = EvalIn(n, "value");
			IRValue addr = null;
			IRSlot slot = null;
			let cap = CaptureOf(n);
			switch (cap != null ? VarKind.None : n.Var)
			{
			case .None:
				addr = CaptureAddr(cap, key, "value");
			case .Local:
				mVars.TryGetValue(scope String()..AppendF("local:{}", n.LocalVar.Name), out slot);
			case .Param:
				StringView name = (n.ParamVar != null) ? (StringView)n.ParamVar.Name : "value";
				if (!mVars.TryGetValue(scope String()..AppendF("param:{}", name), out slot))
					addr = RefParamAddr(name); // a ref parameter is written through its address
			case .OutParam:
				mParams.TryGetValue(scope String(n.ParamVar.Name), out addr);
			case .Field:
				addr = FieldAddr(recv, n.Member, t, key, "value", !n.ReceiverIsThis);
			case .StaticField:
				if (n.Member.CVar)
					addr = CVarAddr(n.Member, key, "value");
				else
				{
					let a = E.Op(.GlobalAddr, T.Pointer(t), key, "value");
					a.Global = new String();
					GlobalName(n, a.Global);
					addr = a;
				}
			case .Property:
				let owner = Sub(n.Owner, n);
				if (!n.SetOp.IsEmpty)
				{
					List<IRValue> gargs = scope .();
					if (recv != null)
						gargs.Add(recv);
					let old = Invoke(n.Member, owner, null, .Get, gargs, t, key, "value", n.ReceiverIsBase);
					v = Operate(n.SetOp, Sub(n.OperandType ?? t, n), old, v, t, key, "value");
				}
				List<IRValue> args = scope .();
				if (recv != null)
					args.Add(recv);
				args.Add(v);
				Invoke(n.Member, owner, null, .Set, args, T.Void, key, "value", n.ReceiverIsBase);
				StoreSlot(OutSlot(n, "result"), v, key, "result");
				return;
			default:
			}
			if (!n.SetOp.IsEmpty)
			{
				IRValue old;
				if (slot != null)
					old = LoadSlot(slot, key, "value");
				else
				{
					let ld = E.Op(.Load, t, key, "value");
					ld.Operands.Add(addr);
					old = ld;
				}
				v = Operate(n.SetOp, Sub(n.OperandType ?? t, n), old, v, t, key, "value");
			}
			// A local variable of a struct type with a destructor: the old value is destroyed
			// before the new one is stored (Language.md 5.4)
			if (slot != null && cap == null && n.Var == .Local && n.SetOp.IsEmpty && !mLambda && n.LocalVar != null && DestroysLocal(n.LocalVar, slot.Type))

			{
				let a = SlotAddr(slot, key, "value");
				E.Op(.Dtor, T.Void, key, "value").Operands.Add(a);
			}
			if (slot != null)
				StoreSlot(slot, v, key, "value");
			else if (addr != null)
			{
				let st = E.Op(.Store, T.Void, key, "value");
				st.Operands.Add(addr);
				st.Operands.Add(v);
			}
			StoreSlot(OutSlot(n, "result"), v, key, "result");
		}

		void EmitConstruct(BNode n)
		{
			let key = n.Key;
			let t = Sub(n.Subject);
			if (t == null || t.IsError)
				return;
			M.Need(t);
			if (t.Kind == .Array)
			{
				let count = EvalIn(n, "count");
				if (n.Kind == .Local && mLocals.TryGetValue(n, let aslot))
				{
					// A Local array: on the stack up to 16 KiB, freed at the region's exit.
					let op = E.Op(.LocalArray, t, key, "object");
					op.Slot = aslot;
					op.Operands.Add(count);
					return;
				}
				// With an allocator: `alloc.array T[] %len %allocator` (rt_alloc_with).
				IRValue alloc = null;
				if (n.WithAllocator)
				{
					alloc = EvalIn(n, "allocator");
					E.Op(.NullCheck, T.Void, key, "allocator").Operands.Add(alloc);
					M.Need(alloc.Type);
				}
				let op = E.Op(.AllocArray, t, key, "object");
				op.Operands.Add(count);
				if (alloc != null)
					op.Operands.Add(alloc);
				StoreSlot(OutSlot(n, "object"), op, key, "object");
				return;
			}
			// Rule 1: the inputs first.
			List<IRValue> args = scope .();
			if (n.Member != null)
				for (let p in n.Member.Params)
					args.Add((p.IsRef || p.Mode == .In) ? AddressOf(n, p.Name) : EvalIn(n, p.Name));
			let isLocal = n.Kind == .Local;
			let isStruct = t.Kind == .Named && t.Sym.Kind == .Struct;
			IROp obj;
			if (isLocal)
			{
				obj = E.Op(.Local, isStruct ? T.Pointer(t) : t, key, "object");
				mLocals.TryGetValue(n, out obj.Slot);
			}
			else if (n.WithAllocator)
			{
				// Construct with an allocator: `alloc C %allocator` (rt_alloc_with).
				let alloc = EvalIn(n, "allocator");
				E.Op(.NullCheck, T.Void, key, "allocator").Operands.Add(alloc);
				obj = E.Op(.Alloc, t, key, "object");
				obj.Operands.Add(alloc);
				M.Need(alloc.Type);
			}
			else
				obj = E.Op(.Alloc, t, key, "object");
			String name = scope .();
			let ctor = n.Member;
			if (ctor != null)
			{
				M.FuncRef(ctor, t, null, .Body, name);
				M.Use(ctor, t, name);
			}
			else if (t.Kind == .Named && M.DefaultCtor(t.Sym, let declared))
			{
				// The made constructor of a class that declares none, or (Construct of a generic
				// parameter with `new`) the instance type's constructor without inputs.
				if (declared == null)
				{
					KirWriter.Type(t, name);
					name.Append(".this()");
				}
				else
				{
					M.FuncRef(declared, t, null, .Body, name);
					M.Use(declared, t, name);
				}
			}
			if (!name.IsEmpty)
			{
				let call = E.Op(.Call, T.Void, key, "");
				call.Callee = new String(name);
				call.Operands.Add(obj);
				call.Operands.AddRange(args);
			}
			if (!isLocal)
				StoreSlot(OutSlot(n, "object"), obj, key, "object");
		}

		void EmitLoop(BNode n)
		{
			let key = n.Key;
			let header = F.NewBlock(key);
			let latch = F.NewBlock(key);
			let done = F.NewBlock(key);
			mLoops[n] = (latch, done);
			IRBlock body = null;
			switch (n.Kind)
			{
			case .For:
				let start = EvalIn(n, "start");
				let count = EvalIn(n, "count");
				let idx = OutSlot(n, "index");
				let cnt = OutSlot(n, "count");
				StoreSlot(idx, start, key, "start");
				StoreSlot(cnt, count, key, "count");
				E.Br(header);
				E.Block = header;
				let left = LoadSlot(cnt, key, "count");
				let zero = E.Const("0", cnt.Type, key, "count");
				let more = E.Op(.Cmp, T.Bool, key, "count");
				more.Sub = new String("gt");
				more.Operands.Add(left);
				more.Operands.Add(zero);
				body = F.NewBlock(key);
				E.Block.Term = .CondBr;
				E.Block.Cond = more;
				E.Block.Targets.Add(body);
				E.Block.Targets.Add(done);
				E.Block.TermNode.Set(key);
				// Next pass: index += Step, count -= 1 (Step is read each pass).
				E.Block = latch;
				ClearMemo();
				let step = EvalIn(n, "step");
				let i0 = LoadSlot(idx, key, "index");
				let i1 = E.Op(.Binop, idx.Type, key, "index");
				i1.Sub = new String("add");
				i1.Operands.Add(i0);
				i1.Operands.Add(step);
				StoreSlot(idx, i1, key, "index");
				let c0 = LoadSlot(cnt, key, "count");
				let one = E.Const("1", cnt.Type, key, "count");
				let c1 = E.Op(.Binop, cnt.Type, key, "count");
				c1.Sub = new String("sub");
				c1.Operands.Add(c0);
				c1.Operands.Add(one);
				StoreSlot(cnt, c1, key, "count");
				E.Br(header);
			case .ForEach:
				if (n.EnumType != null)
				{
					body = F.NewBlock(key);
					EnumeratorLoop(n, header, body, latch, done);
					break;
				}
				let coll = EvalIn(n, "collection");
				let cslot = OutSlot(n, "collection");
				let idx = OutSlot(n, "index");
				StoreSlot(cslot, coll, key, "collection");
				StoreSlot(idx, E.Const("0", T.Int, key, "index"), key, "index");
				E.Br(header);
				E.Block = header;
				let c = LoadSlot(cslot, key, "collection");
				IRValue len;
				if (c.Type.Kind == .Array)
				{
					let ld = E.Op(.ArrayLen, T.Int, key, "collection");
					ld.Operands.Add(c);
					len = ld;
				}
				else if (c.Type.Kind == .FixedArray)
					len = E.Const(scope $"{c.Type.Length}", T.Int, key, "collection");
				else
				{
					var view = c;
					if (c.Type.Kind == .Named && c.Type.Sym == T.StringSym)
					{
						// A String's characters: its view's length.
						let call = E.Op(.Call, T.StringViewSym.Self, key, "collection");
						call.Callee = new String("Core.String.View()");
						call.Operands.Add(c);
						view = call;
					}
					let ex = E.Op(.Extract, T.Int, key, "collection");
					ex.Operands.Add(view);
					ex.Index = 1;
					len = ex;
				}
				let i = LoadSlot(idx, key, "index");
				let more = E.Op(.Cmp, T.Bool, key, "index");
				more.Sub = new String("lt");
				more.Operands.Add(i);
				more.Operands.Add(len);
				body = F.NewBlock(key);
				E.Block.Term = .CondBr;
				E.Block.Cond = more;
				E.Block.Targets.Add(body);
				E.Block.Targets.Add(done);
				E.Block.TermNode.Set(key);
				E.Block = latch;
				let i0 = LoadSlot(idx, key, "index");
				let one = E.Const("1", T.Int, key, "index");
				let i1 = E.Op(.Binop, T.Int, key, "index");
				i1.Sub = new String("add");
				i1.Operands.Add(i0);
				i1.Operands.Add(one);
				StoreSlot(idx, i1, key, "index");
				E.Br(header);
			case .While, .DoWhile:
				body = F.NewBlock(key);
				E.Br((n.Kind == .While) ? header : body);
				E.Block = header;
				ClearMemo();
				let c = EvalIn(n, "condition");
				E.Block.Term = .CondBr;
				E.Block.Cond = c;
				E.Block.Targets.Add(body);
				E.Block.Targets.Add(done);
				E.Block.TermNode.Set(key);
				E.Block = latch;
				E.Br(header);
			default:
			}
			E.Block = body;
			ClearMemo();
			Goto(n, "body");
			E.Block = done;
			ClearMemo();
			Goto(n, "done");
		}

		void EmitSwitch(BNode n)
		{
			let key = n.Key;
			let v = EvalIn(n, "value");
			StoreSlot(OutSlot(n, "value"), v, key, "value");
			let on = Sub(n.Subject);
			if (n.TextSwitch)
			{
				TextSwitch(n, v, on);
				return;
			}
			IRValue sel = v;
			if (on.IsEnum && on.Sym.HasPayload)
			{
				let tag = E.Op(.EnumTag, T.Int32, key, "value");
				tag.Operands.Add(v);
				sel = tag;
			}
			else if (on.IsEnum)
			{
				let c = E.Op(.Cast, on.Sym.Underlying ?? T.Int, key, "value");
				c.Operands.Add(v);
				sel = c;
			}
			let sw = E.Block;
			sw.Term = .Switch;
			sw.Cond = sel;
			sw.TermNode.Set(key);
			List<IRBlock> arms = scope .();
			for (let label in n.Cases)
			{
				int64 value = 0;
				if (on.IsEnum)
				{
					let cs = on.Sym.FindCase(label);
					value = (cs != null) ? cs.CaseValue : 0;
				}
				else if (label.StartsWith('\'') && label.Length >= 3)
					value = (int64)label[1];
				else
				{
					Literals.Classify(label, var iv, var fv);
					value = iv;
				}
				let b = F.NewBlock(key);
				sw.Cases.Add(value);
				sw.Targets.Add(b);
				arms.Add(b);
			}
			let def = F.NewBlock(key);
			sw.Targets.Add(def);
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
