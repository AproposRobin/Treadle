using System;
using System.Collections;
using Treadle.Backend.IR;

namespace Treadle.Backend.Emit
{
	/// Emits one function's `define`. Slots are allocas in the entry block (mem2reg makes them
	/// registers); every Local and Defer has a flag slot that `region.enter` clears and the op sets;
	/// `region.exit` expands in place to the region's Defer bodies (last first, each a copy of its
	/// blocks with renamed labels and values) and then its Locals' destructors (last first).
	class FunctionEmitter
	{
		UnitEmitter U;
		IRFunction F;
		Layout L;
		StringView mSym;
		String mBody = new .() ~ delete _;
		String mAllocas = new .() ~ delete _;
		int mTmp;
		int mLabel;
		bool mDbg;
		bool mHasSP;
		int32 mSP;
		int32 mFile;
		int32 mCurLine;
		/// The line of the Sheet's Entry node: the entry block's code and the parameters.
		int32 mEntryLine;
		/// The location of the last instruction written, and whether the next one starts an IR
		/// block (Compiler.md 7: every block starts a line row of its own).
		int32 mLastLine = -1;
		int32 mLastCol = 1;
		bool mBlockStart;
		Dictionary<int64, int32> mLocs = new .() ~ delete _;
		String mWhere = new .() ~ delete _;

		// value names: the base map and one overlay per Defer body copy being emitted
		Dictionary<IRValue, String> mValues = new .() ~ { for (let kv in _) delete kv.value; delete _; };
		List<Dictionary<IRValue, String>> mOverlays = new .() ~ delete _;
		List<String> mSuffix = new .() ~ DeleteContainerAndItems!(_);
		/// The label `enddefer` continues at, per copy being emitted.
		List<String> mDeferNext = new .() ~ DeleteContainerAndItems!(_);

		Dictionary<IROp, int> mDeferFlag = new .() ~ delete _;
		Dictionary<IRSlot, int> mLocalFlag = new .() ~ delete _;
		Dictionary<IRRegion, List<IROp>> mRegionDefers = new .() ~ { for (let kv in _) delete kv.value; delete _; };
		HashSet<IRBlock> mDeferBlocks = new .() ~ delete _;
		int mFlags;

		/// Alias metadata (Release): the access tag of an address made by field.addr / elem.addr, and
		/// the LLVM type an access through it must have to carry the tag (UnitEmitter, "TBAA").
		Dictionary<IRValue, (int32 tag, String ll)> mAddrTags = new .() ~ { for (let kv in _) delete kv.value.ll; delete _; };
		String mVtTag ~ delete _;
		String mLenTag ~ delete _;

		/// `, !tbaa` of a vtable pointer load or store ("" in Debug).
		StringView VtTag
		{
			get
			{
				if (mVtTag == null)
				{
					mVtTag = new .();
					U.VTableTbaa(mVtTag);
				}
				return mVtTag;
			}
		}

		/// `, !tbaa` of an array object's length ("" in Debug).
		StringView LenTag
		{
			get
			{
				if (mLenTag == null)
				{
					mLenTag = new .();
					let t = U.TbaaScalarTag(U.P.T("int"));
					if (t >= 0)
						mLenTag.AppendF(", !tbaa !{}", t);
				}
				return mLenTag;
			}
		}

		void AddrTag(IRValue addr, int32 tag, IRType accessType)
		{
			if (tag < 0 || addr == null || mAddrTags.ContainsKey(addr))
				return;
			mAddrTags[addr] = (tag, new String(L.LL(accessType)));
		}

		/// `, !tbaa !N` for a load or store of `ll` through `addr` when its address has a tag.
		void AccessTag(IRValue addr, StringView ll, String outText)
		{
			if (mAddrTags.TryGetValue(addr, let at) && at.ll == ll)
				outText.AppendF(", !tbaa !{}", at.tag);
		}

		/// A dynamically sized Local array (`local.array`) whose object fits this many bytes lives
		/// on the stack (`llvm.stacksave` / `alloca` / `llvm.stackrestore` at its region's exit);
		/// a larger one is allocated on the heap and freed at the region's exit (Compiler.md 4).
		public const int64 LocalArrayStackLimit = 16384;
		/// Debug builds put a 48-byte header with this magic in front of a stack Local array, so a
		/// Delete of it is reported (rt_free_dbg: not made by Construct) instead of reading garbage.
		const String LocalMagic = "5423832913450058060"; // 0x4B45534C4F43414C, "KESLOCAL"

		public this(UnitEmitter u, IRFunction f, StringView sym)
		{
			U = u;
			F = f;
			L = u.L;
			mSym = sym;
			mDbg = u.Dbg;
			mSret = u.SretReturn(f.Ret);
			f.GetDisplay(mWhere);
		}

		/// The function returns its result through the `%sret` pointer (UnitEmitter.SretReturn).
		bool mSret;

		/// A call of a Treadle function (direct, virtual, interface, through a function pointer or a
		/// delegate): `args` without the result pointer. A result that returns through memory goes to
		/// a slot of this function (`sret`, the first argument) and is loaded from there.
		void TreadleCall(StringView callee, IRType ret, StringView args, IRValue result, StringView rIn)
		{
			String r = scope .(rIn);
			if (r.IsEmpty && result != null)
				r.AppendF("%t{}", T());
			if (U.SretReturn(ret))
			{
				String slot = scope .();
				EntryAlloca(L.LL(ret), L.Align(ret), slot);
				String sp = scope .();
				U.SretParam(ret, sp);
				I(scope $"call void {callee}({sp} {slot}{(args.IsEmpty ? "" : ", ")}{args})");
				if (result != null)
				{
					LoadValue(ret, slot, r);
					Def(result, r);
				}
				return;
			}
			if (ret.IsVoid || result == null)
			{
				I(scope $"call {L.LL(ret)} {callee}({args})");
				return;
			}
			I(scope $"{r} = call {L.LL(ret)} {callee}({args})");
			Def(result, r);
		}

		void Error(StringView msg) => U.Error(scope $"{F.Key}: {msg}");

		// ---------------------------------------------------------------- names

		int T() => ++mTmp;

		void Label(String outText)
		{
			outText.AppendF("L{}", ++mLabel);
			if (!mSuffix.IsEmpty)
				outText.Append(mSuffix.Back);
		}

		void BlockLabel(IRBlock b, String outText)
		{
			outText.Append("b.");
			outText.Append(b.Id);
			if (!mSuffix.IsEmpty)
				outText.Append(mSuffix.Back);
		}

		/// A slot's alloca: `%s.<id>`, and `.<name>` for a named slot (`%s.s0.pet`, `%s.s1.b7.result`;
		/// characters LLVM does not take in a name become `_`).
		void SlotPtr(IRSlot s, String outText)
		{
			outText.Append("%s.");
			outText.Append(s.Id);
			if (s.Name.IsEmpty)
				return;
			outText.Append('.');
			for (let c in s.Name.RawChars)
				outText.Append((c.IsLetterOrDigit && c < (char8)0x80) || c == '_' || c == '.' || c == '$' || c == '-' ? c : '_');
		}

		/// The operand text of a value.
		void V(IRValue v, String outText)
		{
			for (int i = mOverlays.Count - 1; i >= 0; i--)
				if (mOverlays[i].TryGetValue(v, let t))
				{
					outText.Append(t);
					return;
				}
			if (mValues.TryGetValue(v, let t2))
			{
				outText.Append(t2);
				return;
			}
			if (v.ParamIndex >= 0)
			{
				outText.AppendF("%p.{}", v.Name);
				return;
			}
			Error(scope $"%{v.Name} is used before its op is emitted (values may not cross into a Defer body; use a slot)");
			outText.Append("poison");
		}

		/// "T %v" for a value.
		void TV(IRValue v, String outText)
		{
			outText.Append(L.LL(v.Type));
			outText.Append(' ');
			V(v, outText);
		}

		/// Sets the operand text of a result (in the current copy).
		void Def(IRValue v, StringView text)
		{
			if (v == null)
				return;
			if (!mOverlays.IsEmpty)
			{
				let ov = mOverlays.Back;
				if (ov.TryGetValue(v, let old))
					delete old;
				ov[v] = new .(text);
				return;
			}
			if (mValues.TryGetValue(v, let old))
				delete old;
			mValues[v] = new .(text);
		}

		/// `r = load T, ptr p`. A payload enum is loaded one field at a time (the i32 tag, then each payload
		/// unit) and put together with insertvalue, see StoreValue.
		void LoadValue(IRType t, StringView p, StringView r, StringView tag = "")
		{
			if (t.IsVector)
			{
				LoadVector(t, p, r, L.Align(t)); // EmitVector.bf
				return;
			}
			let ll = L.LL(t);
			if (!t.IsPayloadEnum)
			{
				I(scope $"{r} = load {ll}, ptr {p}, align {L.Align(t)}{tag}");
				return;
			}
			L.PayloadArea(t.Decl, var unit, var count);
			let tg = T();
			I(scope $"%t{tg} = load i32, ptr {p}, align {L.Align(t)}");
			String cur = scope .();
			cur.Set(count == 0 ? r : scope $"%t{T()}");
			I(scope $"{cur} = insertvalue {ll} poison, i32 %t{tg}, 0");
			for (int k = 0; k < count; k++)
			{
				let gp = T();
				I(scope $"%t{gp} = getelementptr inbounds {ll}, ptr {p}, i32 0, i32 1, i64 {k}");
				let ld = T();
				I(scope $"%t{ld} = load i{unit * 8}, ptr %t{gp}, align {unit}");
				String next = scope .();
				next.Set(k == count - 1 ? r : scope $"%t{T()}");
				I(scope $"{next} = insertvalue {ll} {cur}, i{unit * 8} %t{ld}, 1, {k}");
				cur.Set(next);
			}
		}

		/// `store T v, ptr p`. A payload enum is stored one field at a time: the i32 tag, then each payload
		/// unit, never as one aggregate. LLVM turns a whole-aggregate load and store (a Value copied from one
		/// array element to another) into a memcpy that it copies in 8- or 16-byte pieces, and such a piece
		/// cannot be forwarded from the 4-byte tag store that wrote the value just before: the load waits for
		/// the store to reach the cache (about 12 cycles per copy in an interpreter's stack). Field by field,
		/// every load reads exactly what one store wrote (Compiler.md 6.4, "Payload enums in memory").
		void StoreValue(IRType t, StringView v, StringView p, StringView tag = "")
		{
			if (t.IsVector)
			{
				StoreVector(t, v, p, L.Align(t)); // EmitVector.bf
				return;
			}
			let ll = L.LL(t);
			if (!t.IsPayloadEnum)
			{
				I(scope $"store {ll} {v}, ptr {p}, align {L.Align(t)}{tag}");
				return;
			}
			L.PayloadArea(t.Decl, var unit, var count);
			let tg = T();
			I(scope $"%t{tg} = extractvalue {ll} {v}, 0");
			I(scope $"store i32 %t{tg}, ptr {p}, align {L.Align(t)}");
			for (int k = 0; k < count; k++)
			{
				let ev = T();
				I(scope $"%t{ev} = extractvalue {ll} {v}, 1, {k}");
				let gp = T();
				I(scope $"%t{gp} = getelementptr inbounds {ll}, ptr {p}, i32 0, i32 1, i64 {k}");
				I(scope $"store i{unit * 8} %t{ev}, ptr %t{gp}, align {unit}");
			}
		}

		/// A fresh SSA name for a result ("%v.x" plus the copy suffix).
		void ResultName(IRValue v, String outText)
		{
			outText.Append("%v.");
			outText.Append(v.Name);
			if (!mSuffix.IsEmpty)
				outText.Append(mSuffix.Back);
		}

		// ---------------------------------------------------------------- lines

		int32 Loc(int32 line, int32 col = 1)
		{
			let l = (line > 0) ? line : mCurLine;
			let key = (int64)l * 4 + col;
			if (mLocs.TryGetValue(key, let found))
				return found;
			let id = U.AddMeta(scope $"!DILocation(line: {l}, column: {col}, scope: !{mSP})");
			mLocs[key] = id;
			return id;
		}

		/// One instruction line (with its location when the function has debug info).
		///
		/// The first instruction of an IR block that has the line of the instruction before it gets
		/// the other column (1 / 2), so LLVM starts a new line row there: a block reached by a jump
		/// (a loop's increment and test) then begins a row, and a debugger stepping onto it stops
		/// on its node instead of treating the jump target as the middle of the previous row.
		void I(StringView text)
		{
			mBody.Append("  ");
			mBody.Append(text);
			if (mHasSP)
			{
				var col = (int32)1;
				if (mCurLine == mLastLine)
					col = mBlockStart ? (3 - mLastCol) : mLastCol;
				mBody.AppendF(", !dbg !{}", Loc(mCurLine, col));
				mLastLine = mCurLine;
				mLastCol = col;
			}
			mBlockStart = false;
			mBody.Append('\n');
		}

		void LabelLine(StringView label)
		{
			mBody.Append(label);
			mBody.Append(":\n");
		}

		/// An alloca in the entry block; returns its name.
		void EntryAlloca(StringView llType, int64 align, String outName)
		{
			outName.AppendF("%a{}", T());
			mAllocas.AppendF("  {} = alloca {}, align {}\n", outName, llType, Math.Max(align, 1));
		}

		void Site(IROp op, String outSym)
		{
			U.Site(mWhere, op.NodeId, outSym);
		}

		// ---------------------------------------------------------------- function

		public void Emit(String outText)
		{
			let shared = F.IsShared;
			mCurLine = U.E.Listing.EntryLineOf(F);
			mHasSP = F.Unit != null;
			if (mHasSP)
			{
				mFile = U.FileMeta(F.Unit.Name);
				String linkage = scope .();
				U.M.Function(F, linkage);
				mSP = U.AddMeta("");
				let line = Math.Max(mCurLine, 1);
				if (mCurLine == 0)
					mCurLine = 1;
				mEntryLine = mCurLine;
				String display = scope .();
				F.GetDisplay(display);
				U.Meta[mSP].Set(scope $"distinct !DISubprogram(name: \"{display}\", linkageName: \"{linkage}\", scope: !{mFile}, file: !{mFile}, line: {line}, type: !{U.SubroutineType}, scopeLine: {line}, flags: DIFlagPrototyped, spFlags: {(U.Opt ? "DISPFlagDefinition | DISPFlagOptimized" : "DISPFlagDefinition")}, unit: !{U.CU})");
			}
			Prepare();
			// parameters (a result through memory: the sret pointer first)
			String ps = scope .();
			if (mSret)
			{
				U.SretParam(F.Ret, ps);
				ps.Append(" %sret");
			}
			for (let p in F.Params)
			{
				if (!ps.IsEmpty)
					ps.Append(", ");
				ps.AppendF("{} %p.{}", (p.ParamIndex == 0 && F.HasThis) ? "ptr" : L.LL(p.Type), p.Name);
			}
			// entry: slots, flags, parameters for the debugger
			for (let s in F.Slots)
			{
				String ll = scope .(); if (s.Kind == .Local && s.Type.IsClass) Layout.StructName(s.Type.Text, ll); else ll.Append(L.Mem(s.Type));
				let align = (s.Kind == .Local && s.Type.IsClass) ? ClassAlign(s.Type) : L.Align(s.Type);
				mAllocas.AppendF("  {} = alloca {}, align {}\n", SlotPtr(s, .. scope .()), ll, align);
			}
			for (int i < mFlags)
				mAllocas.AppendF("  %f.{} = alloca i1, align 1\n", i);
			String init = scope .();
			if (mDbg && mHasSP)
			{
				// Debug: one instruction on the Entry node's line after the prologue (the parameter
				// spills have no line), so Step Into and a breakpoint on the Entry stop there even when
				// the function has no slots to set up
				mAllocas.Append("  %entry.mark = alloca i8, align 1\n");
				init.AppendF("  store volatile i8 0, ptr %entry.mark, align 1, !dbg !{}\n", Loc(mCurLine));
			}
			for (int i < mFlags)
				{ String tail = scope .(); DbgTail(tail); init.AppendF("  store i1 false, ptr %f.{}, align 1{}\n", i, tail); }
			// Local arrays: the saved stack pointer and whether the array went to the heap
			for (let s in F.Slots)
			{
				if (s.Kind != .Local || s.Type.Kind != .Array)
					continue;
				mAllocas.AppendF("  %as.{0} = alloca ptr, align 8\n  %ah.{0} = alloca i1, align 1\n", s.Id);
				String tail = scope .(); DbgTail(tail);
				init.AppendF("  store i1 false, ptr %ah.{}, align 1{}\n", s.Id, tail);
			}
			for (let s in F.Slots)
			{
				if (s.Kind == .Local && s.Type.IsClass)
					continue;
				String tail = scope .(); DbgTail(tail); init.AppendF("  store {} {}, ptr {}, align {}{}\n", L.Mem(s.Type), ZeroOf(s.Type), SlotPtr(s, .. scope .()), L.Align(s.Type), tail);
			}
			if (mDbg && mHasSP)
			{
				for (let s in F.Slots)
				{
					String raw = scope .();
					s.DebugName(raw);
					// a metadata string: `"` and `\` as escapes
					String name = scope .();
					for (let c in raw.RawChars)
					{
						if (c == '"')
							name.Append("\\22");
						else if (c == '\\')
							name.Append("\\5C");
						else
							name.Append(c);
					}
					let ty = U.DIType(s.Type, s.TypeText);
					let dv = U.AddMeta(scope $"!DILocalVariable(name: \"{name}\", scope: !{mSP}, file: !{mFile}, line: {mCurLine}, type: !{ty})");
					if (s.Kind == .Local && s.Type.IsClass)
					{
						// the object lives in the slot: show it as a pointer to it
						init.AppendF("    #dbg_value(ptr {}, !{}, !DIExpression(), !{})\n", SlotPtr(s, .. scope .()), dv, Loc(mCurLine));
					}
					else
						init.AppendF("    #dbg_declare(ptr {}, !{}, !DIExpression(), !{})\n", SlotPtr(s, .. scope .()), dv, Loc(mCurLine));
				}
				// Parameters (`this` first) are spilled to their own allocas and described with
				// #dbg_declare, so they stay readable for the whole function: a #dbg_value on the
				// incoming register ends where the register is reused (after the first call). The
				// function itself keeps using the incoming values. A parameter that a `local` slot of its
				// name holds (one a Set writes) is shown by that slot only, so Locals has one entry for it.
				for (let p in F.Params)
				{
					if (F.Slots.FindIndex(scope (s) => s.Shows == .Local && s.Name == p.Name) >= 0)
						continue;
					let ty = U.DIType(p.Type, p.TypeText);
					let dv = U.AddMeta(scope $"!DILocalVariable(name: \"{p.Name}\", arg: {p.ParamIndex + 1}, scope: !{mSP}, file: !{mFile}, line: {mCurLine}, type: !{ty})");
					let isThis = p.ParamIndex == 0 && F.HasThis;
					StringView ll = isThis ? "ptr" : L.LL(p.Type);
					let align = isThis ? 8 : L.Align(p.Type);
					mAllocas.AppendF("  %pa.{} = alloca {}, align {}\n", p.Name, ll, Math.Max(align, 1));
					// no location: the spill is part of the prologue, so a stop on the Entry (the first
					// located instruction) already sees the parameter in its alloca
					mAllocas.AppendF("  store {} %p.{}, ptr %pa.{}, align {}\n", ll, p.Name, p.Name, Math.Max(align, 1));
					init.AppendF("    #dbg_declare(ptr %pa.{}, !{}, !DIExpression(), !{})\n", p.Name, dv, Loc(mCurLine));
				}
			}
			// blocks (Defer bodies are emitted only where their region exits)
			for (let b in F.Blocks)
			{
				if (mDeferBlocks.Contains(b))
					continue;
				EmitBlock(b);
			}
			String first = scope .();
			BlockLabel(F.Blocks[0], first);
			outText.AppendF("define {}{} {}({}) #0", shared ? "linkonce_odr " : "", U.RetLL(F.Ret), mSym, ps);
			if (shared)
			{
				U.Comdat(mSym);
				outText.AppendF(" comdat({})", scope String()..Append('$')..Append(mSym.Substring(1)));
			}
			if (mHasSP)
				outText.AppendF(" !dbg !{}", mSP);
			outText.Append(" {\nentry:\n");
			outText.Append(mAllocas);
			outText.Append(init);
			// the entry block's branch is the Entry node's (not the line the last block ended on)
			String brTail = scope .();
			if (mHasSP)
				brTail.AppendF(", !dbg !{}", Loc(mEntryLine));
			outText.AppendF("  br label %{}{}\n", first, brTail);
			outText.Append(mBody);
			outText.Append("}\n\n");
		}

		void DbgTail(String outText)
		{
			if (mHasSP)
				outText.AppendF(", !dbg !{}", Loc(mCurLine));
		}

		int64 ClassAlign(IRType t)
		{
			L.DeclLayout(t.Decl, ?, var align, null);
			return align;
		}

		StringView ZeroOf(IRType t)
		{
			if (t.IsVector)
				return "zeroinitializer";
			if (U.IsAggregate(t))
				return "zeroinitializer";
			if (t.IsPointerLike)
				return "null";
			if (t.IsFloat)
				return "0.0";
			if (t.Kind == .Bool)
				return "false";
			return "0";
		}

		/// Flags, the Defers and Locals of each region, the blocks that belong to Defer bodies.
		void Prepare()
		{
			for (let s in F.Slots)
				if (s.Kind == .Local)
					mLocalFlag[s] = mFlags++;
			for (let b in F.Blocks)
				for (let op in b.Ops)
					if (op.Kind == .Defer && op.Region != null)
					{
						mDeferFlag[op] = mFlags++;
						if (!mRegionDefers.TryGetValue(op.Region, var list))
						{
							list = new .();
							mRegionDefers[op.Region] = list;
						}
						list.Add(op);
						// the body: every block reachable from its first one without leaving through enddefer
						List<IRBlock> work = scope .();
						work.Add(op.Targets[0]);
						while (!work.IsEmpty)
						{
							let w = work.PopBack();
							if (!mDeferBlocks.Add(w))
								continue;
							let t = w.Terminator;
							if (t == null)
								continue;
							for (let s in t.Targets)
								work.Add(s);
							for (let c in t.Cases)
								work.Add(c.Target);
						}
					}
		}

		void EmitBlock(IRBlock b)
		{
			String label = scope .();
			BlockLabel(b, label);
			LabelLine(label);
			mBlockStart = true;
			for (let op in b.Ops)
			{
				let line = U.E.Listing.LineOf(F, op.NodeId);
				if (line > 0)
					mCurLine = line;
				EmitOp(op);
			}
		}

		// ---------------------------------------------------------------- ops

		void EmitOp(IROp op)
		{
			String s = scope .();
			String r = scope .();
			if (op.Result != null)
				ResultName(op.Result, r);
			switch (op.Kind)
			{
			case .Const:
				String c = scope .();
				U.ConstText(op.Type, op.Lit, op.LitIsString, c);
				Def(op.Result, c);
			case .Copy:
				V(op.Args[0], s);
				Def(op.Result, s);
			case .LoadSlot:
				String p = scope .();
				SlotPtr(op.Slot, p);
				LoadValue(op.Slot.Type, p, r);
				Def(op.Result, r);
			case .StoreSlot:
				String p = scope .();
				SlotPtr(op.Slot, p);
				V(op.Args[0], s);
				StoreValue(op.Slot.Type, s, p);
			case .SlotAddr:
				SlotPtr(op.Slot, s);
				Def(op.Result, s);
			case .Binop:
				EmitBinop(op, r);
			case .Cmp:
				EmitCmp(op, r);
			case .Cast:
				if (op.Args[0].Type.Kind == .Array && op.Type.IsStruct)
				{
					// `cast Core.Span<T> %arr`: the same as `array.span` over the whole array
					EmitArraySpan(op, r);
					return;
				}
				String alias = scope .();
				if (EmitCast(op.Args[0], op.Type, r, alias))
					Def(op.Result, r);
				else
					Def(op.Result, alias);
			case .Select:
				String c = scope .();
				TV(op.Args[0], c); // `i1 %c`, or a lane mask `<N x i1> %m` (a select per lane)
				String a = scope .();
				TV(op.Args[1], a);
				String b = scope .();
				TV(op.Args[2], b);
				I(scope $"{r} = select {c}, {a}, {b}");
				Def(op.Result, r);
			case .FieldAddr:
				EmitFieldAddr(op, r);
			case .ElemAddr:
				EmitElemAddr(op, r);
			case .Load:
				V(op.Args[0], s);
				String tag = scope .();
				AccessTag(op.Args[0], L.LL(op.Type), tag);
				if (op.Type.IsVector)
					LoadVector(op.Type, s, r, VectorAccessAlign(op.Args[0], op.Type)); // EmitVector.bf: a [Packed] field is unaligned
				else
					LoadValue(op.Type, s, r, tag);
				Def(op.Result, r);
			case .Store:
				String p = scope .();
				V(op.Args[0], p);
				V(op.Args[1], s);
				String tag = scope .();
				AccessTag(op.Args[0], L.LL(op.Args[1].Type), tag);
				if (op.Args[1].Type.IsVector)
					StoreVector(op.Args[1].Type, s, p, VectorAccessAlign(op.Args[0], op.Args[1].Type)); // EmitVector.bf
				else
					StoreValue(op.Args[1].Type, s, p, tag);
			case .NullCheck:
				if (mDbg)
					EmitNullCheck(op);
			case .BoundsCheck:
				if (mDbg)
					EmitBoundsCheck(op);
			case .GlobalAddr:
				U.GlobalSym(op.Global, s);
				Def(op.Result, s);
			case .ArrayLen:
				V(op.Args[0], s);
				String arr = scope .();
				L.ArrayObject(op.Args[0].Type.Elem ?? U.P.T("int8"), arr);
				let t = T();
				I(scope $"%t{t} = getelementptr inbounds {arr}, ptr {s}, i32 0, i32 1");
				I(scope $"{r} = load i64, ptr %t{t}, align 8{LenTag}");
				if (op.Type.Bits != 64)
				{
					String r2 = scope .();
					r2.AppendF("%t{}", T());
					I(scope $"{r2} = trunc i64 {r} to {L.LL(op.Type)}");
					Def(op.Result, r2);
				}
				else
					Def(op.Result, r);
			case .ArraySpan:
				EmitArraySpan(op, r);
			case .Call, .CCall:
				EmitCall(op, r);
			case .VCall, .ICall:
				EmitDispatch(op, r);
			case .FptrCall:
				EmitFptrCall(op, r);
			case .FnAddr:
				U.UseFunction(op.Fn);
				U.FnSym(op.Fn, s);
				Def(op.Result, s);
			case .Alloc:
				EmitAlloc(op, r);
			case .AllocArray:
				EmitAllocArray(op, r);
			case .Local:
				EmitLocal(op);
			case .Free:
				V(op.Args[0], s);
				EmitFree(op, s);
			case .Dtor:
				V(op.Args[0], s);
				let dt = op.Args[0].Type;
				if ((dt.Kind == .Pointer || dt.Kind == .Ref) && dt.Elem.IsStruct)
				{
					// a struct's storage: its complete destructor (nothing when it needs none)
					if (U.NeedsDtor(dt.Elem))
					{
						String d1 = scope .();
						U.CompleteDtorSym(dt.Elem.Decl, d1);
						I(scope $"call void {d1}(ptr {s})");
					}
				}
				else
					EmitVirtualDtor(s, dt);
			case .Delete:
				EmitDelete(op);
			case .RegionEnter:
				for (let kv in mLocalFlag)
					if (kv.key.Region == op.Region)
						I(scope $"store i1 false, ptr %f.{kv.value}, align 1");
				if (mRegionDefers.TryGetValue(op.Region, let defers))
					for (let d in defers)
						I(scope $"store i1 false, ptr %f.{mDeferFlag[d]}, align 1");
			case .RegionExit:
				EmitRegionExit(op.Region);
			case .Defer:
				I(scope $"store i1 true, ptr %f.{mDeferFlag[op]}, align 1");
			case .Box:
				EmitBox(op, r);
			case .Unbox:
				V(op.Args[0], s);
				let t = T();
				I(scope $"%t{t} = getelementptr inbounds {{ ptr, {L.Mem(op.Type)} }}, ptr {s}, i32 0, i32 1");
				LoadValue(op.Type, scope $"%t{t}", r);
				Def(op.Result, r);
			case .DynCast:
				V(op.Args[0], s);
				String ti = scope .();
				U.TypeInfoSym(op.TypeArg, ti);
				I(scope $"{r} = call ptr @rt_dyncast(ptr {s}, ptr {ti})");
				Def(op.Result, r);
			case .TypeInfo:
				U.TypeInfoSym(op.TypeArg, s);
				Def(op.Result, s);
			case .Make:
				EmitMake(op, r);
			case .Extract:
				TV(op.Args[0], s);
				if (op.Type.IsVector && L.MemDiffers(op.Type))
				{
					// a vector inside an aggregate is in its memory form (EmitVector.bf)
					let m = T();
					I(scope $"%t{m} = extractvalue {s}, {op.Index}");
					FromMem(op.Type, scope $"%t{m}", r);
				}
				else
					I(scope $"{r} = extractvalue {s}, {op.Index}");
				Def(op.Result, r);
			case .Vec, .LaneCheck:
				EmitVectorOp(op, r); // EmitVector.bf
			case .CaseMake:
				EmitCaseMake(op, r);
			case .EnumTag:
				EmitEnumTag(op, r);
			case .EnumPayload:
				EmitEnumPayload(op, r);
			case .SizeOf:
				Def(op.Result, scope $"{L.Size(op.TypeArg)}");
			case .AlignOf:
				Def(op.Result, scope $"{L.Align(op.TypeArg)}");
			case .Intrinsic:
				EmitIntrinsic(op, r);
			case .LocalArray:
				EmitLocalArray(op, r);
			case .AtomicLoad, .AtomicStore, .AtomicRmw, .AtomicCas, .Fence:
				EmitAtomic(op, r);
			case .Bind, .BindLocal:
				EmitBind(op, r);
			case .Closure:
				EmitClosure(op);
			case .Invoke:
				EmitInvoke(op, r);
			case .Br:
				String t = scope .();
				BlockLabel(op.Targets[0], t);
				I(scope $"br label %{t}");
			case .CondBr:
				V(op.Args[0], s);
				String a = scope .();
				BlockLabel(op.Targets[0], a);
				String b = scope .();
				BlockLabel(op.Targets[1], b);
				I(scope $"br i1 {s}, label %{a}, label %{b}");
			case .Switch:
				TV(op.Args[0], s);
				String d = scope .();
				BlockLabel(op.Targets[0], d);
				String cases = scope .();
				for (let c in op.Cases)
				{
					String t = scope .();
					BlockLabel(c.Target, t);
					cases.AppendF(" {} {}, label %{}", L.LL(op.Args[0].Type), c.Value, t);
				}
				I(scope $"switch {s}, label %{d} [{cases} ]");
			case .Ret:
				if (op.Args.IsEmpty)
					I("ret void");
				else if (mSret)
				{
					V(op.Args[0], s);
					StoreValue(F.Ret, s, "%sret");
					I("ret void");
				}
				else
				{
					TV(op.Args[0], s);
					I(scope $"ret {s}");
				}
			case .EndDefer:
				if (mDeferNext.IsEmpty)
				{
					Error("enddefer outside a Defer body");
					I("unreachable");
				}
				else
					I(scope $"br label %{mDeferNext.Back}");
			case .Unreachable:
				I("unreachable");
			case .Fatal:
				String site = scope .();
				Site(op, site);
				String msg = scope .();
				U.Str(op.Lit, msg);
				I(scope $"call void @rt_fatal(i32 {op.Index}, ptr {site}, ptr {msg})");
				I("unreachable");
			}
		}

		void EmitBinop(IROp op, StringView r)
		{
			if (op.Type.IsVector)
			{
				EmitVectorBinop(op, r); // EmitVector.bf
				return;
			}
			let t = op.Type;
			String a = scope .();
			V(op.Args[0], a);
			String b = scope .();
			V(op.Args[1], b);
			StringView inst = "";
			let f = t.IsFloat;
			let sgn = t.IsSignedInt;
			switch (op.Sub)
			{
			case "add": inst = f ? "fadd" : "add";
			case "sub": inst = f ? "fsub" : "sub";
			case "mul": inst = f ? "fmul" : "mul";
			case "div": inst = f ? "fdiv" : (sgn ? "sdiv" : "udiv");
			case "rem": inst = f ? "frem" : (sgn ? "srem" : "urem");
			case "and": inst = "and";
			case "or": inst = "or";
			case "xor": inst = "xor";
			case "shl": inst = "shl";
			case "shr": inst = sgn ? "ashr" : "lshr";
			default:
				Error(scope $"unknown binop '{op.Sub}'");
				inst = "add";
			}
			I(scope $"{r} = {inst} {L.LL(t)} {a}, {b}");
			Def(op.Result, r);
		}

		void EmitCmp(IROp op, StringView r)
		{
			if (op.Args[0].Type.IsVector)
			{
				EmitVectorCmp(op, r); // EmitVector.bf
				return;
			}
			let t = op.Args[0].Type;
			String a = scope .();
			V(op.Args[0], a);
			String b = scope .();
			V(op.Args[1], b);
			if (t.Kind == .Delegate && (op.Sub == "eq" || op.Sub == "ne"))
			{
				DelegateEquals(a, b, op.Sub == "ne", r);
				Def(op.Result, r);
				return;
			}
			if (t.IsFloat)
			{
				StringView pred = "oeq";
				switch (op.Sub)
				{
				case "eq": pred = "oeq";
				case "ne": pred = "une";
				case "lt": pred = "olt";
				case "le": pred = "ole";
				case "gt": pred = "ogt";
				case "ge": pred = "oge";
				default: Error(scope $"unknown cmp '{op.Sub}'");
				}
				I(scope $"{r} = fcmp {pred} {L.LL(t)} {a}, {b}");
			}
			else
			{
				let sgn = t.IsSignedInt;
				StringView pred = "eq";
				switch (op.Sub)
				{
				case "eq": pred = "eq";
				case "ne": pred = "ne";
				case "lt": pred = sgn ? "slt" : "ult";
				case "le": pred = sgn ? "sle" : "ule";
				case "gt": pred = sgn ? "sgt" : "ugt";
				case "ge": pred = sgn ? "sge" : "uge";
				default: Error(scope $"unknown cmp '{op.Sub}'");
				}
				I(scope $"{r} = icmp {pred} {L.LL(t)} {a}, {b}");
			}
			Def(op.Result, r);
		}

		/// Delegate equality: the same object, or two non-null delegates with the same target and
		/// function. A closure is its own target, so two closures are equal only when they are the
		/// same object; two delegates bound to the same function (and the same object) are equal.
		void DelegateEquals(StringView a, StringView b, bool negate, StringView r)
		{
			String st = scope .();
			Layout.StructName(U.P.DelegateDecl.Name, st);
			String pre = scope .();
			Label(pre);
			String deep = scope .();
			Label(deep);
			String done = scope .();
			Label(done);
			I(scope $"br label %{pre}");
			LabelLine(pre);
			let same = T();
			I(scope $"%t{same} = icmp eq ptr {a}, {b}");
			let an = T();
			I(scope $"%t{an} = icmp eq ptr {a}, null");
			let bn = T();
			I(scope $"%t{bn} = icmp eq ptr {b}, null");
			let nn = T();
			I(scope $"%t{nn} = or i1 %t{an}, %t{bn}");
			let quick = T();
			I(scope $"%t{quick} = or i1 %t{same}, %t{nn}");
			I(scope $"br i1 %t{quick}, label %{done}, label %{deep}");
			LabelLine(deep);
			int32[4] loads = .();
			for (int k < 4)
			{
				let gp = T();
				I(scope $"%t{gp} = getelementptr inbounds {st}, ptr {(k < 2) ? a : b}, i32 0, i32 {1 + (k % 2)}");
				let ld = T();
				I(scope $"%t{ld} = load ptr, ptr %t{gp}, align 8");
				loads[k] = (int32)ld;
			}
			let et = T();
			I(scope $"%t{et} = icmp eq ptr %t{loads[0]}, %t{loads[2]}");
			let ef = T();
			I(scope $"%t{ef} = icmp eq ptr %t{loads[1]}, %t{loads[3]}");
			let both = T();
			I(scope $"%t{both} = and i1 %t{et}, %t{ef}");
			I(scope $"br label %{done}");
			LabelLine(done);
			if (negate)
			{
				let eq = T();
				I(scope $"%t{eq} = phi i1 [ %t{same}, %{pre} ], [ %t{both}, %{deep} ]");
				I(scope $"{r} = xor i1 %t{eq}, true");
			}
			else
				I(scope $"{r} = phi i1 [ %t{same}, %{pre} ], [ %t{both}, %{deep} ]");
		}

		/// Bits of an integer-like type (bool 1, simple enums their tag).
		int32 IntBits(IRType t)
		{
			if (t.Kind == .Bool)
				return 1;
			if (t.IsEnum && !t.IsPayloadEnum)
				return (t.Decl.TagType ?? U.P.T("int32")).Bits;
			return t.Bits;
		}

		bool IsIntLike(IRType t) => t.IsInteger || t.Kind == .Bool || (t.IsEnum && !t.IsPayloadEnum);

		bool IsSigned(IRType t)
		{
			if (t.IsEnum && !t.IsPayloadEnum)
				return (t.Decl.TagType ?? U.P.T("int32")).Signed;
			return t.IsSignedInt;
		}

		/// Converts `v` to `to` into `r`: true when an instruction was emitted, false when the value is
		/// reused as it is (its operand text in `outAlias`).
		bool EmitCast(IRValue v, IRType to, StringView r, String outAlias)
		{
			if (v.Type.IsVector || to.IsVector)
				return EmitVectorCast(v, to, r, outAlias); // EmitVector.bf
			let from = v.Type;
			String a = scope .();
			V(v, a);
			let fromLL = L.LL(from);
			let toLL = L.LL(to);
			StringView inst = "";
			if (fromLL == toLL && from.IsFloat == to.IsFloat)
			{
				// same representation: pointer up / down casts, enum <-> int of the same width
				outAlias.Set(a);
				return false;
			}
			if (IsIntLike(from) && IsIntLike(to))
			{
				let fb = IntBits(from);
				let tb = IntBits(to);
				if (tb == 1)
				{
					I(scope $"{r} = icmp ne {fromLL} {a}, 0");
					return true;
				}
				inst = (tb < fb) ? "trunc" : ((IsSigned(from) && fb > 1) ? "sext" : "zext");
			}
			else if (IsIntLike(from) && to.IsFloat)
				inst = IsSigned(from) ? "sitofp" : "uitofp";
			else if (from.IsFloat && IsIntLike(to))
				inst = IsSigned(to) ? "fptosi" : "fptoui";
			else if (from.IsFloat && to.IsFloat)
				inst = (to.Bits > from.Bits) ? "fpext" : "fptrunc";
			else if (from.IsPointerLike && IsIntLike(to))
				inst = "ptrtoint";
			else if (IsIntLike(from) && to.IsPointerLike)
				inst = "inttoptr";
			else if (from.IsPointerLike && to.IsPointerLike)
			{
				outAlias.Set(a);
				return false;
			}
			else
			{
				Error(scope $"cannot cast {from.Text} to {to.Text}");
				inst = "bitcast";
			}
			I(scope $"{r} = {inst} {fromLL} {a} to {toLL}");
			return true;
		}

		void EmitFieldAddr(IROp op, StringView r)
		{
			let obj = op.Args[0];
			let ot = obj.Type;
			IRTypeDecl d = null;
			if (ot.IsClass)
				d = ot.Decl;
			else if ((ot.Kind == .Pointer || ot.Kind == .Ref) && ot.Elem.Kind == .Named)
				d = L.Decl(ot.Elem);
			if (d == null || (d.Kind != .Class && d.Kind != .Struct))
			{
				Error(scope $"field.addr needs a class or a pointer to a struct, not {ot.Text}");
				return;
			}
			if (!L.FieldIndex(d, op.Sub, var idx, var offset, var field))
			{
				Error(scope $"{d.Name} has no field '{op.Sub}'");
				return;
			}
			String o = scope .();
			V(obj, o);
			String st = scope .();
			Layout.StructName(d.Name, st);
			I(scope $"{r} = getelementptr inbounds {st}, ptr {o}, i32 0, i32 {idx}");
			Def(op.Result, r);
			if (field != null && !d.Packed)
				AddrTag(op.Result, U.TbaaFieldTag(d, d.Kind == .Class, field.Type, offset), field.Type);
		}

		/// An index as an i64 operand.
		void Index64(IRValue v, String outText)
		{
			if (L.LL(v.Type) == "i64")
			{
				V(v, outText);
				return;
			}
			String a = scope .();
			V(v, a);
			let t = T();
			I(scope $"%t{t} = {(IsSigned(v.Type) ? "sext" : "zext")} {L.LL(v.Type)} {a} to i64");
			outText.AppendF("%t{}", t);
		}

		void EmitElemAddr(IROp op, StringView r)
		{
			let arr = op.Args[0];
			let at = arr.Type;
			String a = scope .();
			V(arr, a);
			String i = scope .();
			Index64(op.Args[1], i);
			if (at.Kind == .Array)
			{
				String ao = scope .();
				L.ArrayObject(at.Elem, ao);
				I(scope $"{r} = getelementptr inbounds {ao}, ptr {a}, i32 0, i32 2, i64 {i}");
				// an element of a Treadle array has the element type (a pointer is raw memory: no tag)
				AddrTag(op.Result, U.TbaaScalarTag(at.Elem), at.Elem);
			}
			else if ((at.Kind == .Pointer || at.Kind == .Ref) && at.Elem.Kind == .FixedArray)
				I(scope $"{r} = getelementptr inbounds {L.LL(at.Elem)}, ptr {a}, i64 0, i64 {i}");
			else if (at.Kind == .Pointer || at.Kind == .Ref)
				I(scope $"{r} = getelementptr inbounds {L.Mem(at.Elem.IsVoid ? U.P.T("uint8") : at.Elem)}, ptr {a}, i64 {i}");
			else
			{
				Error(scope $"elem.addr needs an array or a pointer, not {at.Text}");
				return;
			}
			Def(op.Result, r);
		}

		/// `array.span Span<T> %arr [%start %count]`: `{ptr, length}` over the array's elements, or over
		/// `count` of them from `start`. Debug: a null array is fatal (`rt_null`), and so is a range that
		/// leaves the array (`rt_span_range`), each naming the node.
		void EmitArraySpan(IROp op, StringView r)
		{
			let arr = op.Args[0];
			let elem = arr.Type.Elem;
			let st = op.Type;
			if (arr.Type.Kind != .Array || !IRLinker.IsSpanOf(st, elem))
			{
				Error(scope $"cannot make {(st?.Text)} from {arr.Type.Text}");
				return;
			}
			String a = scope .();
			V(arr, a);
			String site = scope .();
			if (mDbg)
			{
				Site(op, site);
				String bad = scope .();
				Label(bad);
				String ok = scope .();
				Label(ok);
				let n = T();
				I(scope $"%t{n} = icmp eq ptr {a}, null");
				I(scope $"br i1 %t{n}, label %{bad}, label %{ok}");
				LabelLine(bad);
				I(scope $"call void @rt_null(ptr {site})");
				I("unreachable");
				LabelLine(ok);
			}
			String ao = scope .();
			L.ArrayObject(elem, ao);
			let lp = T();
			I(scope $"%t{lp} = getelementptr inbounds {ao}, ptr {a}, i32 0, i32 1");
			let len = T();
			I(scope $"%t{len} = load i64, ptr %t{lp}, align 8");
			String start = scope .("0");
			String count = scope .();
			count.AppendF("%t{}", len);
			if (op.Args.Count == 3)
			{
				start.Clear();
				Index64(op.Args[1], start);
				count.Clear();
				Index64(op.Args[2], count);
				if (mDbg)
				{
					// start < 0, count < 0 or count > length - start
					let c1 = T();
					I(scope $"%t{c1} = icmp slt i64 {start}, 0");
					let c2 = T();
					I(scope $"%t{c2} = icmp slt i64 {count}, 0");
					let rest = T();
					I(scope $"%t{rest} = sub i64 %t{len}, {start}");
					let c3 = T();
					I(scope $"%t{c3} = icmp sgt i64 {count}, %t{rest}");
					let o1 = T();
					I(scope $"%t{o1} = or i1 %t{c1}, %t{c2}");
					let o2 = T();
					I(scope $"%t{o2} = or i1 %t{o1}, %t{c3}");
					String bad = scope .();
					Label(bad);
					String ok = scope .();
					Label(ok);
					I(scope $"br i1 %t{o2}, label %{bad}, label %{ok}");
					LabelLine(bad);
					I(scope $"call void @rt_span_range(ptr {site}, i64 {start}, i64 {count}, i64 %t{len})");
					I("unreachable");
					LabelLine(ok);
				}
			}
			let p = T();
			I(scope $"%t{p} = getelementptr inbounds {ao}, ptr {a}, i32 0, i32 2, i64 {start}");
			let s1 = T();
			I(scope $"%t{s1} = insertvalue {L.LL(st)} poison, ptr %t{p}, 0");
			I(scope $"{r} = insertvalue {L.LL(st)} %t{s1}, i64 {count}, 1");
			Def(op.Result, r);
		}

		void EmitNullCheck(IROp op)
		{
			let v = op.Args[0];
			String o = scope .();
			V(v, o);
			String site = scope .();
			Site(op, site);
			String bad = scope .();
			Label(bad);
			String ok = scope .();
			Label(ok);
			let t = T();
			I(scope $"%t{t} = icmp eq ptr {o}, null");
			I(scope $"br i1 %t{t}, label %{bad}, label %{ok}");
			LabelLine(bad);
			I(scope $"call void @rt_null(ptr {site})");
			I("unreachable");
			LabelLine(ok);
			if (!v.Type.IsObjectRef)
				return;
			// a deleted object's vtable is the poison table
			String freed = scope .();
			Label(freed);
			String live = scope .();
			Label(live);
			let vt = T();
			I(scope $"%t{vt} = load ptr, ptr {o}, align 8");
			let pz = T();
			I(scope $"%t{pz} = icmp eq ptr %t{vt}, @rt_poison_vtable");
			I(scope $"br i1 %t{pz}, label %{freed}, label %{live}");
			LabelLine(freed);
			I(scope $"call void @rt_freed(ptr {site})");
			I("unreachable");
			LabelLine(live);
		}

		void EmitBoundsCheck(IROp op)
		{
			let arr = op.Args[0];
			String a = scope .();
			V(arr, a);
			String i = scope .();
			Index64(op.Args[1], i);
			String len = scope .();
			if (op.Args.Count >= 3)
				Index64(op.Args[2], len); // `boundscheck %span %i %len`: a Span's length (Compiler.md 6)
			else if (arr.Type.Kind == .Array)
			{
				String ao = scope .();
				L.ArrayObject(arr.Type.Elem, ao);
				let p = T();
				I(scope $"%t{p} = getelementptr inbounds {ao}, ptr {a}, i32 0, i32 1");
				let l = T();
				I(scope $"%t{l} = load i64, ptr %t{p}, align 8");
				len.AppendF("%t{}", l);
			}
			else if ((arr.Type.Kind == .Pointer || arr.Type.Kind == .Ref) && arr.Type.Elem.Kind == .FixedArray)
				len.AppendF("{}", arr.Type.Elem.Count);
			else
			{
				Error(scope $"boundscheck needs an array, not {arr.Type.Text}");
				return;
			}
			String site = scope .();
			Site(op, site);
			String bad = scope .();
			Label(bad);
			String ok = scope .();
			Label(ok);
			let c = T();
			I(scope $"%t{c} = icmp uge i64 {i}, {len}");
			I(scope $"br i1 %t{c}, label %{bad}, label %{ok}");
			LabelLine(bad);
			I(scope $"call void @rt_bounds(ptr {site}, i64 {i}, i64 {len})");
			I("unreachable");
			LabelLine(ok);
		}

		/// Treadle-to-Treadle calls pass every value as its LLVM type; imported C functions get the
		/// win64 C ABI (aggregates coerced or passed through a copy, the C default promotions for
		/// variadic arguments).
		void EmitCall(IROp op, StringView r)
		{
			let f = op.Fn;
			U.UseFunction(f);
			String sym = scope .();
			U.FnSym(f, sym);
			if (f.IsImport)
			{
				EmitCCall(op, f, sym, r);
				return;
			}
			String args = scope .();
			for (let a in op.Args)
			{
				if (!args.IsEmpty)
					args.Append(", ");
				if (@a.Index == 0 && f.HasThis)
				{
					args.Append("ptr ");
					V(a, args);
				}
				else
					TV(a, args);
			}
			TreadleCall(sym, f.Ret, args, op.Result, r);
		}

		void EmitCCall(IROp op, IRFunction f, StringView sym, StringView r)
		{
			String args = scope .();
			String fixedTypes = scope .();
			String sret = scope .();
			let retAbi = U.AbiOf(f.Ret);
			if (retAbi == .Indirect)
			{
				EntryAlloca(L.LL(f.Ret), L.Align(f.Ret), sret);
				args.AppendF("ptr sret({}) {}", L.LL(f.Ret), sret);
				fixedTypes.Append("ptr");
			}
			List<IRType> argTypes = scope .();
			for (let a in op.Args)
				argTypes.Add(a.Type);
			List<UnitEmitter.CAbi> abis = scope .();
			U.CAbiList(argTypes, retAbi == .Indirect, abis);
			for (let a in op.Args)
			{
				let isFixed = @a.Index < f.ParamTypes.Count;
				var t = a.Type;
				String val = scope .();
				V(a, val);
				String piece = scope .();
				let abi = abis[@a.Index];
				if (abi == .Coerce)
				{
					// stored as the value, read back as the coerced type (win64 `iN`; System V one
					// argument per eightbyte)
					String co = scope .();
					U.CoerceLL(t, co);
					let ca = Math.Max(L.Align(t), 8);
					String tmp = scope .();
					EntryAlloca(co, ca, tmp);
					I(scope $"store {L.LL(t)} {val}, ptr {tmp}, align {L.Align(t)}");
					let n = T();
					I(scope $"%t{n} = load {co}, ptr {tmp}, align {ca}");
					List<String> pieces = scope .();
					defer { ClearAndDeleteItems!(pieces); }
					U.CoerceParams(t, pieces);
					for (let p in pieces)
					{
						if (@p.Index > 0)
							piece.Append(", ");
						if (pieces.Count == 1)
							piece.AppendF("{} %t{}", p, n);
						else
						{
							let x = T();
							I(scope $"%t{x} = extractvalue {co} %t{n}, {@p.Index}");
							piece.AppendF("{} %t{}", p, x);
						}
						if (isFixed)
						{
							if (!fixedTypes.IsEmpty)
								fixedTypes.Append(", ");
							fixedTypes.Append(p);
						}
					}
				}
				else if (abi == .Indirect)
				{
					String tmp = scope .();
					EntryAlloca(L.LL(t), U.IndirectAlign(t), tmp);
					I(scope $"store {L.LL(t)} {val}, ptr {tmp}, align {L.Align(t)}");
					U.IndirectParam(t, piece);
					piece.AppendF(" {}", tmp);
					if (isFixed)
					{
						if (!fixedTypes.IsEmpty)
							fixedTypes.Append(", ");
						fixedTypes.Append("ptr");
					}
				}
				else if (!isFixed && t.IsFloat && t.Bits == 32)
				{
					let n = T();
					I(scope $"%t{n} = fpext float {val} to double");
					piece.AppendF("double %t{}", n);
				}
				else if (!isFixed && IsIntLike(t) && IntBits(t) < 32)
				{
					let n = T();
					I(scope $"%t{n} = {((IsSigned(t) && IntBits(t) > 1) ? "sext" : "zext")} {L.LL(t)} {val} to i32");
					piece.AppendF("i32 %t{}", n);
				}
				else
				{
					piece.AppendF("{} {}", L.LL(t), val);
					if (isFixed)
					{
						if (!fixedTypes.IsEmpty)
							fixedTypes.Append(", ");
						fixedTypes.Append(L.LL(t));
					}
				}
				if (!args.IsEmpty)
					args.Append(", ");
				args.Append(piece);
			}
			String retLL = scope .();
			switch (retAbi)
			{
			case .Direct: retLL.Append(L.LL(f.Ret));
			case .Coerce: U.CoerceLL(f.Ret, retLL);
			case .Indirect: retLL.Append("void");
			}
			String callee = scope .();
			if (f.Variadic)
				callee.AppendF("{} ({}{}...) {}", retLL, fixedTypes, fixedTypes.IsEmpty ? "" : ", ", sym);
			else
				callee.AppendF("{} {}", retLL, sym);
			if (retLL == "void")
			{
				I(scope $"call {callee}({args})");
				if (retAbi == .Indirect && op.Result != null)
				{
					LoadValue(f.Ret, sret, r);
					Def(op.Result, r);
				}
				return;
			}
			if (retAbi == .Coerce)
			{
				let n = T();
				I(scope $"%t{n} = call {callee}({args})");
				String tmp = scope .();
				let ca = Math.Max(L.Align(f.Ret), 8);
				EntryAlloca(retLL, ca, tmp);
				I(scope $"store {retLL} %t{n}, ptr {tmp}, align {ca}");
				I(scope $"{r} = load {L.LL(f.Ret)}, ptr {tmp}, align {L.Align(f.Ret)}");
				Def(op.Result, r);
				return;
			}
			if (op.Result != null)
			{
				I(scope $"{r} = call {callee}({args})");
				Def(op.Result, r);
			}
			else
				I(scope $"call {callee}({args})");
		}

		void EmitDispatch(IROp op, StringView r)
		{
			let f = op.Fn;
			String o = scope .();
			V(op.Args[0], o);
			String fp = scope .();
			if (op.Kind == .VCall)
			{
				let slot = f.OwnerDecl.FindVSlot(f);
				let vt = T();
				I(scope $"%t{vt} = load ptr, ptr {o}, align 8{VtTag}");
				let sp = T();
				I(scope $"%t{sp} = getelementptr inbounds ptr, ptr %t{vt}, i64 {slot + 2}");
				let fn = T();
				I(scope $"%t{fn} = load ptr, ptr %t{sp}, align 8");
				fp.AppendF("%t{}", fn);
			}
			else
			{
				let iface = f.OwnerDecl;
				let slot = iface.ISlots.IndexOf(f);
				let it = T();
				I(scope $"%t{it} = call ptr @rt_itable(ptr {o}, i32 {U.M.TypeId(iface.Type)})");
				let sp = T();
				I(scope $"%t{sp} = getelementptr inbounds ptr, ptr %t{it}, i64 {slot}");
				let fn = T();
				I(scope $"%t{fn} = load ptr, ptr %t{sp}, align 8");
				fp.AppendF("%t{}", fn);
			}
			String args = scope .();
			args.AppendF("ptr {}", o);
			for (int i = 1; i < op.Args.Count; i++)
			{
				args.Append(", ");
				TV(op.Args[i], args);
			}
			TreadleCall(fp, f.Ret, args, op.Result, r);
		}

		void EmitFptrCall(IROp op, StringView r)
		{
			String fp = scope .();
			V(op.Args[0], fp);
			String args = scope .();
			for (int i = 1; i < op.Args.Count; i++)
			{
				if (!args.IsEmpty)
					args.Append(", ");
				TV(op.Args[i], args);
			}
			TreadleCall(fp, op.Type, args, op.Result, r);
		}

		void AllocCall(IROp op, int64 size, int64 align, StringView sizeText, StringView r, IRValue allocator)
		{
			String sz = scope .();
			if (sizeText.IsEmpty)
				sz.AppendF("{}", size);
			else
				sz.Append(sizeText);
			if (allocator != null)
			{
				String a = scope .();
				V(allocator, a);
				I(scope $"{r} = call ptr @rt_alloc_with(ptr {a}, i64 {sz}, i64 {align}) #2");
			}
			else if (mDbg)
			{
				String site = scope .();
				Site(op, site);
				I(scope $"{r} = call ptr @rt_alloc_dbg(i64 {sz}, i64 {align}, ptr {site}) #2");
			}
			else
				I(scope $"{r} = call ptr @rt_alloc(i64 {sz}, i64 {align}) #2");
		}

		void EmitAlloc(IROp op, StringView r)
		{
			let t = op.TypeArg;
			L.DeclLayout(t.Decl, var size, var align, null);
			AllocCall(op, size, align, "", r, op.Args.IsEmpty ? null : op.Args[0]);
			String vt = scope .();
			U.VTableSym(t, vt);
			I(scope $"store ptr {vt}, ptr {r}, align 8{VtTag}");
			Def(op.Result, r);
		}

		void EmitAllocArray(IROp op, StringView r)
		{
			let at = op.Type;
			let elem = at.Elem;
			String len = scope .();
			Index64(op.Args[0], len);
			let es = L.Size(elem);
			let off = L.ArrayDataOffset(elem);
			ArrayLengthCheck(op, len, es, off);
			let m = T();
			I(scope $"%t{m} = mul i64 {len}, {es}");
			let total = T();
			I(scope $"%t{total} = add i64 %t{m}, {off}");
			// `alloc.array T[] %len [%allocator]`: through the allocator's Alloc (rt_alloc_with) when given
			AllocCall(op, 0, Math.Max(8, L.Align(elem)), scope $"%t{total}", r, (op.Args.Count > 1) ? op.Args[1] : null);
			String vt = scope .();
			U.VTableSym(at, vt);
			I(scope $"store ptr {vt}, ptr {r}, align 8{VtTag}");
			String ao = scope .();
			L.ArrayObject(elem, ao);
			let lp = T();
			I(scope $"%t{lp} = getelementptr inbounds {ao}, ptr {r}, i32 0, i32 1");
			I(scope $"store i64 {len}, ptr %t{lp}, align 8{LenTag}");
			Def(op.Result, r);
		}

		/// The length check of `alloc.array` and `local.array` (Security-Review.md finding 2): a
		/// negative length, or one whose `len * es + off` bytes (and the Debug header) do not fit an
		/// int64, is a fatal error naming the node (`rt_array_length`). Debug: `len < 0`, and the
		/// multiplication and the addition through `llvm.umul` / `llvm.uadd.with.overflow`. Release:
		/// one unsigned compare against the largest length that fits, which a negative length (a huge
		/// unsigned one) fails too (Compiler.md, "Array lengths").
		void ArrayLengthCheck(IROp op, StringView len, int64 es, int64 off)
		{
			String site = scope .();
			Site(op, site);
			String bad = scope .();
			Label(bad);
			String ok = scope .();
			Label(ok);
			U.NeedIntrinsic("declare void @rt_array_length(ptr, i64, i64) #1");
			// room for the Debug runtime's header (48 bytes) and a stack array's (48)
			const int64 slack = 128;
			if (mDbg)
			{
				U.NeedIntrinsic("declare { i64, i1 } @llvm.umul.with.overflow.i64(i64, i64)");
				U.NeedIntrinsic("declare { i64, i1 } @llvm.uadd.with.overflow.i64(i64, i64)");
				let neg = T();
				I(scope $"%t{neg} = icmp slt i64 {len}, 0");
				let mo = T();
				I(scope $"%t{mo} = call {{ i64, i1 }} @llvm.umul.with.overflow.i64(i64 {len}, i64 {es})");
				let mv = T();
				I(scope $"%t{mv} = extractvalue {{ i64, i1 }} %t{mo}, 0");
				let mf = T();
				I(scope $"%t{mf} = extractvalue {{ i64, i1 }} %t{mo}, 1");
				let ao = T();
				I(scope $"%t{ao} = call {{ i64, i1 }} @llvm.uadd.with.overflow.i64(i64 %t{mv}, i64 {off + slack})");
				let av = T();
				I(scope $"%t{av} = extractvalue {{ i64, i1 }} %t{ao}, 0");
				let af = T();
				I(scope $"%t{af} = extractvalue {{ i64, i1 }} %t{ao}, 1");
				// the byte count must stay a positive int64 (the runtime's sizes are signed)
				let big = T();
				I(scope $"%t{big} = icmp slt i64 %t{av}, 0");
				let o1 = T();
				I(scope $"%t{o1} = or i1 %t{neg}, %t{mf}");
				let o2 = T();
				I(scope $"%t{o2} = or i1 %t{o1}, %t{af}");
				let o3 = T();
				I(scope $"%t{o3} = or i1 %t{o2}, %t{big}");
				I(scope $"br i1 %t{o3}, label %{bad}, label %{ok}");
			}
			else
			{
				let limit = (Int64.MaxValue - off - slack) / Math.Max(es, 1);
				let c = T();
				I(scope $"%t{c} = icmp ugt i64 {len}, {limit}");
				I(scope $"br i1 %t{c}, label %{bad}, label %{ok}");
			}
			LabelLine(bad);
			I(scope $"call void @rt_array_length(ptr {site}, i64 {len}, i64 {es})");
			I("unreachable");
			LabelLine(ok);
		}

		void EmitLocal(IROp op)
		{
			let s = op.Slot;
			String p = scope .();
			SlotPtr(s, p);
			if (s.Type.IsClass)
			{
				L.DeclLayout(s.Type.Decl, var size, ?, null);
				I(scope $"call void @llvm.lifetime.start.p0(ptr {p})");
				I(scope $"call void @llvm.memset.p0.i64(ptr {p}, i8 0, i64 {size}, i1 false)");
				String vt = scope .();
				U.VTableSym(s.Type, vt);
				I(scope $"store ptr {vt}, ptr {p}, align 8{VtTag}");
			}
			else
				I(scope $"store {L.Mem(s.Type)} {ZeroOf(s.Type)}, ptr {p}, align {L.Align(s.Type)}");
			I(scope $"store i1 true, ptr %f.{mLocalFlag[s]}, align 1");
			Def(op.Result, p);
		}

		void EmitFree(IROp op, StringView obj)
		{
			if (mDbg)
			{
				String site = scope .();
				Site(op, site);
				I(scope $"call void @rt_free_dbg(ptr {obj}, ptr {site}) #2");
			}
			else
				I(scope $"call void @rt_free(ptr {obj}) #2");
		}

		/// The destructor of an object through its vtable (slot 1). Release, when no class of the
		/// program derives from the static type `t` (the IR program is the whole program): a direct call
		/// of its complete destructor, or nothing at all when its chain destroys nothing (no destructor
		/// Sheet, no owned or destructible field). Debug keeps the vtable call: a deleted object's
		/// poisoned vtable is what reports a use after Delete.
		void EmitVirtualDtor(StringView obj, IRType t)
		{
			if (!mDbg && t.IsClass && !U.HasSubclass(t.Decl))
			{
				if (U.TrivialDtor(t.Decl))
					return;
				String d = scope .();
				U.CompleteDtorSym(t.Decl, d);
				I(scope $"call void {d}(ptr {obj})");
				return;
			}
			let vt = T();
			I(scope $"%t{vt} = load ptr, ptr {obj}, align 8{VtTag}");
			let sp = T();
			I(scope $"%t{sp} = getelementptr inbounds ptr, ptr %t{vt}, i64 1");
			let fn = T();
			I(scope $"%t{fn} = load ptr, ptr %t{sp}, align 8");
			I(scope $"call void %t{fn}(ptr {obj})");
		}

		/// Delete: nothing for null; Debug: an object already deleted goes straight to rt_free_dbg
		/// (which names both Delete nodes) instead of through its poisoned destructor.
		void EmitDelete(IROp op)
		{
			String o = scope .();
			V(op.Args[0], o);
			String del = scope .();
			Label(del);
			String done = scope .();
			Label(done);
			let z = T();
			I(scope $"%t{z} = icmp eq ptr {o}, null");
			I(scope $"br i1 %t{z}, label %{done}, label %{del}");
			LabelLine(del);
			if (op.Args.Count > 1)
			{
				// Delete with an allocator: the destructor, then the allocator's Free
				String a = scope .();
				V(op.Args[1], a);
				if (op.Args[0].Type.IsObjectRef)
					EmitVirtualDtor(o, op.Args[0].Type);
				I(scope $"call void @rt_free_with(ptr {a}, ptr {o}) #2");
				I(scope $"br label %{done}");
				LabelLine(done);
				return;
			}
			if (mDbg && op.Args[0].Type.IsObjectRef)
			{
				String live = scope .();
				Label(live);
				String dead = scope .();
				Label(dead);
				let vt = T();
				I(scope $"%t{vt} = load ptr, ptr {o}, align 8");
				let pz = T();
				I(scope $"%t{pz} = icmp eq ptr %t{vt}, @rt_poison_vtable");
				I(scope $"br i1 %t{pz}, label %{dead}, label %{live}");
				LabelLine(dead);
				EmitFree(op, o);
				I(scope $"br label %{done}");
				LabelLine(live);
			}
			if (op.Args[0].Type.IsObjectRef)
				EmitVirtualDtor(o, op.Args[0].Type);
			EmitFree(op, o);
			I(scope $"br label %{done}");
			LabelLine(done);
		}

		void EmitRegionExit(IRRegion region)
		{
			// The exit's code is on the lines of the nodes that own it: a Defer's test on the Defer,
			// a Local's destructor on the Local (the edge's own node line comes back afterwards).
			let exitLine = mCurLine;
			defer { mCurLine = exitLine; }
			// Defers, last first; each body is a copy of its blocks
			if (mRegionDefers.TryGetValue(region, let defers))
			{
				for (int i = defers.Count - 1; i >= 0; i--)
				{
					let d = defers[i];
					let flag = mDeferFlag[d];
					let dl = U.E.Listing.LineOf(F, d.NodeId);
					mCurLine = (dl > 0) ? dl : exitLine;
					String run = scope .();
					Label(run);
					String next = scope .();
					Label(next);
					let c = T();
					I(scope $"%t{c} = load i1, ptr %f.{flag}, align 1");
					I(scope $"br i1 %t{c}, label %{run}, label %{next}");
					LabelLine(run);
					I(scope $"store i1 false, ptr %f.{flag}, align 1");
					// the copy
					String suffix = new .();
					suffix.AppendF(".d{}", ++mLabel);
					mSuffix.Add(suffix);
					mOverlays.Add(scope:: .());
					mDeferNext.Add(new .(next));
					String first = scope .();
					BlockLabel(d.Targets[0], first);
					I(scope $"br label %{first}");
					let saveLine = mCurLine;
					// emit the body's blocks in function order
					for (let b in F.Blocks)
						if (InBody(d, b))
							EmitBlock(b);
					mCurLine = saveLine;
					delete mDeferNext.PopBack();
					let ov = mOverlays.PopBack();
					for (let kv in ov)
						delete kv.value;
					delete mSuffix.PopBack();
					LabelLine(next);
				}
			}
			// Locals, last first
			for (int i = F.Slots.Count - 1; i >= 0; i--)
			{
				let s = F.Slots[i];
				if (s.Kind != .Local || s.Region != region)
					continue;
				let flag = mLocalFlag[s];
				let isArray = s.Type.Kind == .Array;
				let sl = U.E.Listing.LineOf(F, s.NodeId);
				mCurLine = (sl > 0) ? sl : exitLine;
				if (!s.Type.IsClass && !isArray && !U.NeedsDtor(s.Type))
				{
					I(scope $"store i1 false, ptr %f.{flag}, align 1");
					continue;
				}
				String run = scope .();
				Label(run);
				String next = scope .();
				Label(next);
				let c = T();
				I(scope $"%t{c} = load i1, ptr %f.{flag}, align 1");
				I(scope $"br i1 %t{c}, label %{run}, label %{next}");
				LabelLine(run);
				I(scope $"store i1 false, ptr %f.{flag}, align 1");
				String p = scope .();
				SlotPtr(s, p);
				if (isArray)
				{
					EmitLocalArrayExit(s, p, next);
					LabelLine(next);
					continue;
				}
				String dt = scope .();
				U.CompleteDtorSym(s.Type.Decl, dt);
				I(scope $"call void {dt}(ptr {p})");
				if (s.Type.IsClass)
					I(scope $"call void @llvm.lifetime.end.p0(ptr {p})");
				I(scope $"br label %{next}");
				LabelLine(next);
			}
		}

		/// True when `b` belongs to the body of Defer `d` (reachable from its first block without
		/// passing enddefer).
		bool InBody(IROp d, IRBlock b)
		{
			HashSet<IRBlock> seen = scope .();
			List<IRBlock> work = scope .();
			work.Add(d.Targets[0]);
			while (!work.IsEmpty)
			{
				let w = work.PopBack();
				if (!seen.Add(w))
					continue;
				if (w == b)
					return true;
				let t = w.Terminator;
				if (t == null)
					continue;
				for (let s in t.Targets)
					work.Add(s);
				for (let c in t.Cases)
					work.Add(c.Target);
			}
			return false;
		}

		// ---------------------------------------------------------------- Local arrays

		/// `%a = local.array T[] s %len`: the array object on the stack when it fits
		/// LocalArrayStackLimit bytes (the stack pointer saved for the region's exit), else on the
		/// heap; zeroed, its vtable and length set, the slot holding the reference.
		void EmitLocalArray(IROp op, StringView r)
		{
			let s = op.Slot;
			let at = s.Type;
			let elem = at.Elem;
			String len = scope .();
			Index64(op.Args[0], len);
			String site = scope .();
			Site(op, site);
			if (mDbg)
			{
				// the guard's debug check: a negative length is a fatal error naming the node
				String bad = scope .();
				Label(bad);
				String ok = scope .();
				Label(ok);
				let neg = T();
				I(scope $"%t{neg} = icmp slt i64 {len}, 0");
				I(scope $"br i1 %t{neg}, label %{bad}, label %{ok}");
				LabelLine(bad);
				I(scope $"call void @rt_local_array_length(ptr {site}, i64 {len})");
				I("unreachable");
				LabelLine(ok);
			}
			let es = L.Size(elem);
			let off = L.ArrayDataOffset(elem);
			ArrayLengthCheck(op, len, es, off);
			let align = Math.Max(8, L.Align(elem));
			let m = T();
			I(scope $"%t{m} = mul i64 {len}, {es}");
			let total = T();
			I(scope $"%t{total} = add i64 %t{m}, {off}");
			let small = T();
			I(scope $"%t{small} = icmp ule i64 %t{total}, {LocalArrayStackLimit}");
			String onStack = scope .();
			Label(onStack);
			String onHeap = scope .();
			Label(onHeap);
			String join = scope .();
			Label(join);
			I(scope $"br i1 %t{small}, label %{onStack}, label %{onHeap}");
			// stack
			LabelLine(onStack);
			U.NeedIntrinsic("declare ptr @llvm.stacksave.p0()");
			U.NeedIntrinsic("declare void @llvm.stackrestore.p0(ptr)");
			let sp = T();
			I(scope $"%t{sp} = call ptr @llvm.stacksave.p0()");
			I(scope $"store ptr %t{sp}, ptr %as.{s.Id}, align 8");
			let hdr = mDbg ? 48 : 0;
			let bytes = T();
			I(scope $"%t{bytes} = add i64 %t{total}, {hdr}");
			let mem = T();
			I(scope $"%t{mem} = alloca i8, i64 %t{bytes}, align {Math.Max(16, align)}");
			I(scope $"call void @llvm.memset.p0.i64(ptr %t{mem}, i8 0, i64 %t{bytes}, i1 false)");
			String stackObj = scope .();
			if (mDbg)
			{
				I(scope $"store i64 {LocalMagic}, ptr %t{mem}, align 8");
				let o = T();
				I(scope $"%t{o} = getelementptr inbounds i8, ptr %t{mem}, i64 48");
				stackObj.AppendF("%t{}", o);
			}
			else
				stackObj.AppendF("%t{}", mem);
			I(scope $"store i1 false, ptr %ah.{s.Id}, align 1");
			I(scope $"br label %{join}");
			// heap
			LabelLine(onHeap);
			String heapObj = scope .();
			heapObj.AppendF("%t{}", T());
			AllocCall(op, 0, align, scope $"%t{total}", heapObj, null);
			I(scope $"store i1 true, ptr %ah.{s.Id}, align 1");
			I(scope $"br label %{join}");
			LabelLine(join);
			I(scope $"{r} = phi ptr [ {stackObj}, %{onStack} ], [ {heapObj}, %{onHeap} ]");
			String vt = scope .();
			U.VTableSym(at, vt);
			I(scope $"store ptr {vt}, ptr {r}, align 8{VtTag}");
			String ao = scope .();
			L.ArrayObject(elem, ao);
			let lp = T();
			I(scope $"%t{lp} = getelementptr inbounds {ao}, ptr {r}, i32 0, i32 1");
			I(scope $"store i64 {len}, ptr %t{lp}, align 8{LenTag}");
			String slot = scope .();
			SlotPtr(s, slot);
			I(scope $"store ptr {r}, ptr {slot}, align 8");
			I(scope $"store i1 true, ptr %f.{mLocalFlag[s]}, align 1");
			Def(op.Result, r);
		}

		/// The exit of a Local array: its elements' destructors, then the stack pointer restored or
		/// the heap block freed; continues at `next`.
		void EmitLocalArrayExit(IRSlot s, StringView slot, StringView next)
		{
			let obj = T();
			I(scope $"%t{obj} = load ptr, ptr {slot}, align 8");
			if (U.NeedsDtor(s.Type.Elem))
			{
				String d1 = scope .();
				U.ArrayDtorSym(s.Type, d1);
				I(scope $"call void {d1}(ptr %t{obj})");
			}
			String heap = scope .();
			Label(heap);
			String stack = scope .();
			Label(stack);
			let h = T();
			I(scope $"%t{h} = load i1, ptr %ah.{s.Id}, align 1");
			I(scope $"br i1 %t{h}, label %{heap}, label %{stack}");
			LabelLine(heap);
			I(scope $"call void @rt_free(ptr %t{obj}) #2");
			I(scope $"br label %{next}");
			LabelLine(stack);
			let sp = T();
			I(scope $"%t{sp} = load ptr, ptr %as.{s.Id}, align 8");
			I(scope $"call void @llvm.stackrestore.p0(ptr %t{sp})");
			I(scope $"br label %{next}");
		}

		// ---------------------------------------------------------------- atomics

		static StringView LLOrder(StringView o)
		{
			switch (o)
			{
			case "relaxed": return "monotonic";
			case "acquire": return "acquire";
			case "release": return "release";
			case "acqrel": return "acq_rel";
			default: return "seq_cst";
			}
		}

		/// The failure order of a compare-exchange: the success order without its release part.
		static StringView LLFailOrder(StringView o)
		{
			switch (o)
			{
			case "release", "relaxed": return "monotonic";
			case "acqrel", "acquire": return "acquire";
			default: return "seq_cst";
			}
		}

		void EmitAtomic(IROp op, StringView rIn)
		{
			let order = LLOrder(op.Order);
			if (op.Kind == .Fence)
			{
				I(scope $"fence {order}");
				return;
			}
			String r = scope .(rIn);
			if (r.IsEmpty)
				r.AppendF("%t{}", T());
			String p = scope .();
			V(op.Args[0], p);
			let vt = (op.Kind == .AtomicLoad) ? op.Type : ((op.Kind == .AtomicCas) ? op.Type.Items[0] : op.Args[1].Type);
			let ll = L.LL(vt);
			let size = L.Size(vt);
			let floatOk = op.Kind == .AtomicLoad || op.Kind == .AtomicStore || (op.Kind == .AtomicRmw && (op.Sub == "add" || op.Sub == "sub" || op.Sub == "xchg"));
			if (!((vt.IsInteger && vt.Bits >= 8) || vt.IsPointerLike || (vt.IsEnum && !vt.IsPayloadEnum) || (vt.IsFloat && floatOk)))
			{
				Error(scope $"{IRWriter.Mnemonic(op.Kind)} on {vt.Text}: atomics take an integer of 8 to 64 bits, a pointer or a reference (load, store, add, sub, xchg: also a float)");
				return;
			}
			switch (op.Kind)
			{
			case .AtomicLoad:
				I(scope $"{r} = load atomic {ll}, ptr {p} {order}, align {size}");
				Def(op.Result, r);
			case .AtomicStore:
				String v = scope .();
				TV(op.Args[1], v);
				I(scope $"store atomic {v}, ptr {p} {order}, align {size}");
			case .AtomicRmw:
				StringView inst = op.Sub;
				if (vt.IsFloat)
					inst = (op.Sub == "add") ? "fadd" : ((op.Sub == "sub") ? "fsub" : "xchg");
				else if (op.Sub == "min" || op.Sub == "max")
					inst = IsSigned(vt) ? op.Sub : ((op.Sub == "min") ? "umin" : "umax");
				String v = scope .();
				TV(op.Args[1], v);
				I(scope $"{r} = atomicrmw {inst} ptr {p}, {v} {order}, align {size}");
				Def(op.Result, r);
			case .AtomicCas:
				String e = scope .();
				TV(op.Args[1], e);
				String n = scope .();
				TV(op.Args[2], n);
				// cmpxchg gives { T, i1 }: the LLVM type of the (T,bool) tuple
				I(scope $"{r} = cmpxchg ptr {p}, {e}, {n} {order} {LLFailOrder(op.Order)}, align {size}");
				Def(op.Result, r);
			default:
			}
		}

		// ---------------------------------------------------------------- delegates

		/// `bind` / `bind.local`: a Core.Delegate object (heap, or the Local slot's storage) holding
		/// the target and the function: a static function through its thunk (target null), a
		/// virtual or interface function resolved now from the target's tables, any other directly.
		void EmitBind(IROp op, StringView r)
		{
			let f = op.Fn;
			let dd = U.P.DelegateDecl;
			String st = scope .();
			Layout.StructName(dd.Name, st);
			String obj = scope .();
			if (op.Kind == .BindLocal)
			{
				let s = op.Slot;
				SlotPtr(s, obj);
				L.DeclLayout(dd, var size, ?, null);
				I(scope $"call void @llvm.lifetime.start.p0(ptr {obj})");
				I(scope $"call void @llvm.memset.p0.i64(ptr {obj}, i8 0, i64 {size}, i1 false)");
				I(scope $"store i1 true, ptr %f.{mLocalFlag[s]}, align 1");
			}
			else
			{
				L.DeclLayout(dd, var size, var align, null);
				obj.Set(r);
				AllocCall(op, size, align, "", obj, null);
			}
			String vt = scope .();
			U.VTableSym(dd.Type, vt);
			I(scope $"store ptr {vt}, ptr {obj}, align 8{VtTag}");
			String target = scope .("null");
			String fp = scope .();
			if (f.Static)
				U.DelegateThunkSym(f, fp);
			else
			{
				target.Clear();
				V(op.Args[0], target);
				if (IRLinker.IsDispatched(f) && f.OwnerDecl.Kind == .Interface)
				{
					let it = T();
					I(scope $"%t{it} = call ptr @rt_itable(ptr {target}, i32 {U.M.TypeId(f.OwnerDecl.Type)})");
					let sp = T();
					I(scope $"%t{sp} = getelementptr inbounds ptr, ptr %t{it}, i64 {f.OwnerDecl.ISlots.IndexOf(f)}");
					let fn = T();
					I(scope $"%t{fn} = load ptr, ptr %t{sp}, align 8");
					fp.AppendF("%t{}", fn);
				}
				else if (IRLinker.IsDispatched(f))
				{
					let vtp = T();
					I(scope $"%t{vtp} = load ptr, ptr {target}, align 8{VtTag}");
					let sp = T();
					I(scope $"%t{sp} = getelementptr inbounds ptr, ptr %t{vtp}, i64 {f.OwnerDecl.FindVSlot(f) + 2}");
					let fn = T();
					I(scope $"%t{fn} = load ptr, ptr %t{sp}, align 8");
					fp.AppendF("%t{}", fn);
				}
				else
				{
					U.UseFunction(f);
					U.FnSym(f, fp);
				}
			}
			let tp = T();
			I(scope $"%t{tp} = getelementptr inbounds {st}, ptr {obj}, i32 0, i32 1");
			I(scope $"store ptr {target}, ptr %t{tp}, align 8");
			let fpp = T();
			I(scope $"%t{fpp} = getelementptr inbounds {st}, ptr {obj}, i32 0, i32 2");
			I(scope $"store ptr {fp}, ptr %t{fpp}, align 8");
			Def(op.Result, obj);
		}

		/// `closure`: a closure object (a class derived from Core.Delegate, allocated by `alloc` or
		/// `local`, its captures stored by the front end) becomes its own delegate: target = the
		/// closure, fn = the lambda's function on the closure class.
		void EmitClosure(IROp op)
		{
			String c = scope .();
			V(op.Args[0], c);
			String st = scope .();
			Layout.StructName(U.P.DelegateDecl.Name, st);
			U.UseFunction(op.Fn);
			String fp = scope .();
			U.FnSym(op.Fn, fp);
			let tp = T();
			I(scope $"%t{tp} = getelementptr inbounds {st}, ptr {c}, i32 0, i32 1");
			I(scope $"store ptr {c}, ptr %t{tp}, align 8");
			let fpp = T();
			I(scope $"%t{fpp} = getelementptr inbounds {st}, ptr {c}, i32 0, i32 2");
			I(scope $"store ptr {fp}, ptr %t{fpp}, align 8");
			Def(op.Result, c);
		}

		/// `invoke`: `fn(target, args)` of the delegate.
		void EmitInvoke(IROp op, StringView r)
		{
			String d = scope .();
			V(op.Args[0], d);
			String st = scope .();
			Layout.StructName(U.P.DelegateDecl.Name, st);
			let tp = T();
			I(scope $"%t{tp} = getelementptr inbounds {st}, ptr {d}, i32 0, i32 1");
			let t = T();
			I(scope $"%t{t} = load ptr, ptr %t{tp}, align 8");
			let fpp = T();
			I(scope $"%t{fpp} = getelementptr inbounds {st}, ptr {d}, i32 0, i32 2");
			let fn = T();
			I(scope $"%t{fn} = load ptr, ptr %t{fpp}, align 8");
			String args = scope .();
			args.AppendF("ptr %t{}", t);
			for (int i = 1; i < op.Args.Count; i++)
			{
				args.Append(", ");
				TV(op.Args[i], args);
			}
			TreadleCall(scope $"%t{fn}", op.Type, args, op.Result, r);
		}

		void EmitBox(IROp op, StringView r)
		{
			let v = op.Args[0];
			let inner = v.Type;
			let boxType = U.P.T(scope $"Core.Box<{inner.Text}>");
			List<IRType> m = scope .();
			m.Add(U.P.T("void*"));
			m.Add(inner);
			L.Members(m, false, null, var size, var align);
			AllocCall(op, size, align, "", r, null);
			String vt = scope .();
			U.VTableSym(boxType, vt);
			I(scope $"store ptr {vt}, ptr {r}, align 8{VtTag}");
			let fp = T();
			I(scope $"%t{fp} = getelementptr inbounds {{ ptr, {L.Mem(inner)} }}, ptr {r}, i32 0, i32 1");
			String val = scope .();
			TV(v, val);
			{ String vv = scope .(); V(v, vv); StoreValue(inner, vv, scope $"%t{fp}"); }
			Def(op.Result, r);
		}

		void EmitMake(IROp op, StringView r)
		{
			let t = op.Type;
			String cur = scope .("poison");
			for (let a in op.Args)
			{
				String next = scope .();
				if (@a.Index == op.Args.Count - 1)
					next.Append(r);
				else
					next.AppendF("%t{}", T());
				String av = scope .();
				MakeOperand(a, av); // EmitVector.bf: a vector in its memory form
				I(scope $"{next} = insertvalue {L.LL(t)} {cur}, {av}, {@a.Index}");
				cur.Set(next);
			}
			if (op.Args.IsEmpty)
				Def(op.Result, "zeroinitializer");
			else
				Def(op.Result, r);
		}

		void EmitCaseMake(IROp op, StringView r)
		{
			let t = op.Type;
			let d = t.Decl;
			let c = d.FindCase(op.Sub);
			if (!d.IsPayloadEnum)
			{
				Def(op.Result, scope $"{c.Value}");
				return;
			}
			String tmp = scope .();
			EntryAlloca(L.LL(t), L.Align(t), tmp);
			I(scope $"store {L.LL(t)} zeroinitializer, ptr {tmp}, align {L.Align(t)}");
			I(scope $"store i32 {c.Value}, ptr {tmp}, align 4");
			if (!op.Args.IsEmpty)
			{
				let area = T();
				I(scope $"%t{area} = getelementptr inbounds {L.LL(t)}, ptr {tmp}, i32 0, i32 1");
				String cs = scope .();
				Layout.StructName(scope $"{d.Name}.{c.Name}", cs);
				for (let a in op.Args)
				{
					let fp = T();
					I(scope $"%t{fp} = getelementptr inbounds {cs}, ptr %t{area}, i32 0, i32 {@a.Index}");
					String av = scope .();
					TV(a, av);
					{ String vv = scope .(); V(a, vv); StoreValue(a.Type, vv, scope $"%t{fp}"); }
				}
			}
			I(scope $"{r} = load {L.LL(t)}, ptr {tmp}, align {L.Align(t)}");
			Def(op.Result, r);
		}

		void EmitEnumTag(IROp op, StringView r)
		{
			let v = op.Args[0];
			let et = v.Type;
			String tag = scope .();
			StringView tagLL = "i32";
			if (et.IsPayloadEnum)
			{
				String ev = scope .();
				TV(v, ev);
				let t = T();
				I(scope $"%t{t} = extractvalue {ev}, 0");
				tag.AppendF("%t{}", t);
			}
			else
			{
				V(v, tag);
				tagLL = L.LL(et);
			}
			let want = L.LL(op.Type);
			if (want == tagLL)
			{
				Def(op.Result, tag);
				return;
			}
			let fb = IntBits(et.IsPayloadEnum ? U.P.T("int32") : et);
			let tb = IntBits(op.Type);
			I(scope $"{r} = {(tb < fb ? "trunc" : "sext")} {tagLL} {tag} to {want}");
			Def(op.Result, r);
		}

		void EmitEnumPayload(IROp op, StringView r)
		{
			let v = op.Args[0];
			let t = v.Type;
			let d = t.Decl;
			let c = d.FindCase(op.Sub);
			String tmp = scope .();
			EntryAlloca(L.LL(t), L.Align(t), tmp);
			String ev = scope .();
			TV(v, ev);
			I(scope $"store {ev}, ptr {tmp}, align {L.Align(t)}");
			let area = T();
			I(scope $"%t{area} = getelementptr inbounds {L.LL(t)}, ptr {tmp}, i32 0, i32 1");
			String cs = scope .();
			Layout.StructName(scope $"{d.Name}.{c.Name}", cs);
			let fp = T();
			I(scope $"%t{fp} = getelementptr inbounds {cs}, ptr %t{area}, i32 0, i32 {op.Index}");
			LoadValue(op.Type, scope $"%t{fp}", r);
			Def(op.Result, r);
		}

		void EmitIntrinsic(IROp op, StringView r)
		{
			if (op.Sub != null && op.Sub.StartsWith("kernel."))
			{
				EmitKernelIntrinsic(op, r); // EmitKernel.bf: Kernel.Shared (GPU-Compute.md)
				return;
			}
			if (op.Type.IsVector || (!op.Args.IsEmpty && op.Args[0].Type.IsVector))
			{
				EmitVectorIntrinsic(op, r); // EmitVector.bf
				return;
			}
			String args = scope .();
			for (let a in op.Args)
			{
				if (!args.IsEmpty)
					args.Append(", ");
				TV(a, args);
			}
			let ll = L.LL(op.Type);
			let suffix = (op.Type.IsFloat && op.Type.Bits == 32) ? "f32" : "f64";
			switch (op.Sub)
			{
			case "obj.valid":
				// Is Valid: not null; in Debug also not deleted (a Delete leaves the poison vtable and keeps
				// the memory in quarantine, treadle_rt.c).
				String o = scope .();
				V(op.Args[0], o);
				if (!mDbg || !op.Args[0].Type.IsObjectRef)
				{
					I(scope $"{r} = icmp ne ptr {o}, null");
					Def(op.Result, r);
					return;
				}
				String pre = scope .();
				Label(pre);
				String chk = scope .();
				Label(chk);
				String done = scope .();
				Label(done);
				I(scope $"br label %{pre}");
				LabelLine(pre);
				let nn = T();
				I(scope $"%t{nn} = icmp ne ptr {o}, null");
				I(scope $"br i1 %t{nn}, label %{chk}, label %{done}");
				LabelLine(chk);
				let vt = T();
				I(scope $"%t{vt} = load ptr, ptr {o}, align 8");
				let live = T();
				I(scope $"%t{live} = icmp ne ptr %t{vt}, @rt_poison_vtable");
				I(scope $"br label %{done}");
				LabelLine(done);
				I(scope $"{r} = phi i1 [ false, %{pre} ], [ %t{live}, %{chk} ]");
				Def(op.Result, r);
			case "sqrt", "fabs", "floor", "ceil", "sin", "cos", "exp", "log", "trunc", "round", "tan", "asin", "acos", "atan":
				U.NeedIntrinsic(scope $"declare {ll} @llvm.{op.Sub}.{suffix}({ll})");
				I(scope $"{r} = call {ll} @llvm.{op.Sub}.{suffix}({args})");
				Def(op.Result, r);
			case "pow", "minnum", "maxnum", "atan2", "copysign":
				U.NeedIntrinsic(scope $"declare {ll} @llvm.{op.Sub}.{suffix}({ll}, {ll})");
				I(scope $"{r} = call {ll} @llvm.{op.Sub}.{suffix}({args})");
				Def(op.Result, r);
			case "fma":
				U.NeedIntrinsic(scope $"declare {ll} @llvm.fma.{suffix}({ll}, {ll}, {ll})");
				I(scope $"{r} = call {ll} @llvm.fma.{suffix}({args})");
				Def(op.Result, r);
			case "memcpy":
				String a0 = scope .(); V(op.Args[0], a0);
				String a1 = scope .(); V(op.Args[1], a1);
				String n = scope .(); Index64(op.Args[2], n);
				I(scope $"call void @llvm.memcpy.p0.p0.i64(ptr {a0}, ptr {a1}, i64 {n}, i1 false)");
			case "memset":
				String a0 = scope .(); V(op.Args[0], a0);
				String b = scope .(); V(op.Args[1], b);
				String n = scope .(); Index64(op.Args[2], n);
				let bt = T();
				I(scope $"%t{bt} = trunc {L.LL(op.Args[1].Type)} {b} to i8");
				I(scope $"call void @llvm.memset.p0.i64(ptr {a0}, i8 %t{bt}, i64 {n}, i1 false)");
			case "memcmp":
				String a0 = scope .(); V(op.Args[0], a0);
				String a1 = scope .(); V(op.Args[1], a1);
				String n = scope .(); Index64(op.Args[2], n);
				I(scope $"{r} = call i32 @rt_memcmp(ptr {a0}, ptr {a1}, i64 {n})");
				Def(op.Result, r);
			case "console.write", "console.writeline", "console.error":
				// a StringView
				String sv = scope .();
				TV(op.Args[0], sv);
				let p = T();
				I(scope $"%t{p} = extractvalue {sv}, 0");
				let n = T();
				I(scope $"%t{n} = extractvalue {sv}, 1");
				StringView fn = (op.Sub == "console.write") ? "rt_console_write" : ((op.Sub == "console.writeline") ? "rt_console_write_line" : "rt_console_error_write");
				I(scope $"call void @{fn}(ptr %t{p}, i64 %t{n})");
			default:
				Error(scope $"unknown intrinsic '{op.Sub}'");
			}
		}
	}
}
