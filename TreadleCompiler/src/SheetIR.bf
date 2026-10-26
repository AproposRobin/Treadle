using System;
using System.Collections;

namespace Treadle.Compiler
{
	// The Sheet IR (Compiler.md 4) as the back end takes it: one function per lowered Sheet (per
	// instantiation for generics), blocks of ops in SSA style, slots for locals and flow-node
	// results, every op carrying its node id and pin. The text form is the back end's `.tir`
	// (TreadleBackend/src/IR, docs/Follow-ups.md "Back end -> front end"): `KirWriter` writes it,
	// the back end's IRReader reads it, so a front-end program runs through the back end's
	// FixtureRunner unchanged.

	/// The ops, in the back end's order and with its mnemonics (terminators are on the block).
	enum OpKind : uint8
	{
		Const, Copy, LoadSlot, StoreSlot, SlotAddr,
		Binop, Cmp, Cast, Select,
		FieldAddr, ElemAddr, Load, Store, NullCheck, BoundsCheck, GlobalAddr, ArrayLen,
		Call, VCall, ICall, CCall, FptrCall, FnAddr,
		Alloc, AllocArray, Local, Free, Dtor, Delete, RegionEnter, RegionExit, Defer,
		Box, Unbox, DynCast, TypeInfo,
		Make, Extract, CaseMake, EnumTag, EnumPayload,
		SizeOf, AlignOf, Intrinsic,
		LocalArray, AtomicLoad, AtomicStore, AtomicRmw, AtomicCas, Fence, Bind, BindLocal, Closure, Invoke,
		ArraySpan,
		// vector primitives: `vec.<what>` (Sub: make, splat, get, set, shuffle, reduce, any, all, bitmask,
		// bitcast, load, store, spancheck) and the Debug lane check (LowerVector.bf)
		Vec, LaneCheck
	}

	enum SlotKind : uint8
	{
		/// A Local node's storage (the object itself for a class, the value for a struct).
		Local,
		/// A `local` record (a function's local variable) or a parameter that a Set writes.
		Variable,
		/// A flow node's result (Rule 3 reads load it) or a hidden temporary.
		OutTemp,
		/// A loop's own variable (index, count).
		LoopVar
	}

	enum TermKind : uint8
	{
		None,
		Br,
		CondBr,
		Switch,
		Ret,
		/// The end of a Defer body (`defer r <block>`).
		EndDefer,
		Unreachable,
		/// `fatal <code> "<message>"`.
		Fatal
	}

	/// A value: an op's result or a parameter.
	class IRValue
	{
		public int32 Id = -1;
		public KType Type;
		/// Parameters: the name (`this`, `amount`).
		public String Param ~ delete _;

		public void Ref(String outText)
		{
			if (Param != null)
				outText.AppendF("%{}", Param);
			else
				outText.AppendF("%_{}", Id);
		}
	}

	class IRSlot
	{
		public int32 Id;
		public KType Type;
		public SlotKind Kind;
		public String Node = new .() ~ delete _;
		public String Pin = new .() ~ delete _;
		/// Variables: the local's or parameter's name.
		public String Name = new .() ~ delete _;
		/// Local slots: the region whose exit destroys the object.
		public IRRegion Region;
		/// A type the front end has no KType for (`Core.Delegate`, the back end's); null = Type.
		public String TypeText ~ delete _;
	}

	class IRRegion
	{
		public int32 Id;
		public RegionKind Kind;
		public IRRegion Parent;
		public String Node = new .() ~ delete _;
		public String Pin = new .() ~ delete _;
	}

	class IROp : IRValue
	{
		public OpKind Kind;
		public List<IRValue> Operands = new .() ~ delete _;
		/// `binop` / `cmp` operator, field name, case name, intrinsic name.
		public String Sub ~ delete _;
		/// `extract` / `enum.payload` index.
		public int32 Index = -1;
		public IRSlot Slot;
		public IRRegion Region;
		/// Calls, `fn.addr`: the callee's funcref (`Game.Player.TakeDamage(int)`).
		public String Callee ~ delete _;
		/// `global.addr`: the global (`Game.Player.sCount`).
		public String Global ~ delete _;
		/// `typeinfo` / `sizeof` / `alignof`: the type.
		public KType TypeArg;
		/// `const`: the literal (a number, true / false, null, zero, a case name, or a string's
		/// text when LitIsString).
		public String Lit ~ delete _;
		public bool LitIsString;
		/// Atomics and `fence`: the memory order (`relaxed`, `acquire`, `release`, `acqrel`, `seqcst`).
		public String Order ~ delete _;
		/// `defer`: the first block of the body.
		public IRBlock Target;
		/// The node and pin the op comes from.
		public String Node = new .() ~ delete _;
		public String Pin = new .() ~ delete _;

		public static bool IsCall(OpKind k) => k == .Call || k == .VCall || k == .ICall || k == .CCall || k == .FptrCall;
		public bool HasResult => Type != null && !Type.IsVoid;
	}

	class IRBlock
	{
		public int32 Id;
		public List<IROp> Ops = new .() ~ DeleteContainerAndItems!(_);
		public TermKind Term;
		public IRValue Cond;
		public List<IRBlock> Targets = new .() ~ delete _;
		public List<int64> Cases = new .() ~ delete _;
		public IRValue RetVal;
		public int32 FatalCode;
		public String FatalMessage ~ delete _;
		/// The node and pin of the terminator.
		public String TermNode = new .() ~ delete _;
		/// The node the block starts (for reading the dump).
		public String Node = new .() ~ delete _;

		public bool Terminated => Term != .None;
	}

	class IRFunction
	{
		/// The funcref: `Owner.Name<args>(param types)` (`Game.Player.this(Core.String)`,
		/// `Game.Player.~this()`).
		public String Key = new .() ~ delete _;
		/// `Game.Player.TakeDamage` (diagnostics and the runtime).
		public String Display = new .() ~ delete _;
		/// The Sheet key; "" for functions the compiler makes.
		public String Sheet = new .() ~ delete _;
		public KType Ret;
		public bool Static;
		/// A static constructor (`sctor`: run once before Program Start).
		public bool StaticCtor;
		public bool Virtual;
		public bool Abstract;
		/// C imports: the C symbol.
		public String Import ~ delete _;
		public String Export ~ delete _;
		/// `this` first for an instance function (not written: the back end adds it).
		public List<IRValue> Params = new .() ~ DeleteContainerAndItems!(_);
		public List<IRBlock> Blocks = new .() ~ DeleteContainerAndItems!(_);
		public List<IRSlot> Slots = new .() ~ DeleteContainerAndItems!(_);
		/// The regions; the first is the body region `r0`.
		public List<IRRegion> Regions = new .() ~ DeleteContainerAndItems!(_);
		/// The Sheet's nodes for the listing: id, kind word, subject.
		public List<(String id, String kind, String subject)> Nodes = new .() ~ { for (let n in _) { delete n.id; delete n.kind; delete n.subject; } delete _; };
		public int32 NextValue;

		public bool HasBody => !Blocks.IsEmpty;

		public IRBlock NewBlock(StringView node = "")
		{
			IRBlock b = new .();
			b.Id = (int32)Blocks.Count;
			b.Node.Set(node);
			Blocks.Add(b);
			return b;
		}

		public IRSlot NewSlot(KType t, SlotKind kind, StringView node, StringView pin = "", StringView name = "")
		{
			IRSlot s = new .();
			s.Id = (int32)Slots.Count;
			s.Type = t;
			s.Kind = kind;
			s.Node.Set(node);
			s.Pin.Set(pin);
			s.Name.Set(name);
			Slots.Add(s);
			return s;
		}
	}

	/// Writes the `.tir` text (the back end's IRWriter form).
	static class KirWriter
	{
		static StringView[?] sMnemonics = .(
			"const", "copy", "load.slot", "store.slot", "slot.addr",
			"binop", "cmp", "cast", "select",
			"field.addr", "elem.addr", "load", "store", "nullcheck", "boundscheck", "global.addr", "array.len",
			"call", "vcall", "icall", "ccall", "fptr.call", "fn.addr",
			"alloc", "alloc.array", "local", "free", "dtor", "delete", "region.enter", "region.exit", "defer",
			"box", "unbox", "dyncast", "typeinfo",
			"make", "extract", "case.make", "enum.tag", "enum.payload",
			"sizeof", "alignof", "intrinsic",
			"local.array", "atomic.load", "atomic.store", "atomic.rmw", "atomic.cas", "fence", "bind", "bind.local", "closure", "invoke",
			"array.span", "vec", "lanecheck");

		/// True when the op's line carries a type after the mnemonic (calls: the return type).
		static bool HasType(OpKind k)
		{
			switch (k)
			{
			case .StoreSlot, .Store, .NullCheck, .BoundsCheck, .Free, .Dtor, .Delete, .RegionEnter, .RegionExit, .Defer, .AtomicStore, .Fence: return false;
			default: return true;
			}
		}

		public static void Quote(StringView text, String o)
		{
			o.Append('"');
			for (let c in text.RawChars)
			{
				switch (c)
				{
				case '"': o.Append("\\\"");
				case '\\': o.Append("\\\\");
				case '\n': o.Append("\\n");
				case '\t': o.Append("\\t");
				case '\r': o.Append("\\r");
				default:
					if ((uint8)c < 0x20 || (uint8)c == 0x7F)
						o.AppendF("\\x{:X2}", (uint8)c);
					else
						o.Append(c);
				}
			}
			o.Append('"');
		}

		/// A type as the back end spells it: `StringView` for the core's view, full names,
		/// `T*`, `ref T`, `T[]`, `T[N]`, `T?`, `(A,B)`, `function R(A,B)`.
		public static void Type(KType t, String o)
		{
			if (t == null)
			{
				o.Append("void");
				return;
			}
			switch (t.Kind)
			{
			case .Error, .Null: o.Append("void");
			case .Void, .Bool, .Int, .Float, .Char: o.Append(t.Prim ?? t.Name);
			case .Vector: o.Append(t.Name); // float4, int64x2 (the back end reads the same names)
			case .Pointer:
				Type(t.Element, o);
				o.Append('*');
			case .Array:
				Type(t.Element, o);
				o.Append("[]");
			case .FixedArray:
				Type(t.Element, o);
				o.AppendF("[{}]", t.Length);
			case .Nullable:
				Type(t.Element, o);
				o.Append('?');
			case .Tuple:
				o.Append('(');
				for (let a in t.Args)
				{
					if (@a.Index > 0)
						o.Append(',');
					Type(a, o);
				}
				o.Append(')');
			case .Function, .Delegate:
				o.Append((t.Kind == .Delegate) ? "delegate " : "function ");
				Type(t.Element, o);
				o.Append('(');
				for (let a in t.Args)
				{
					if (@a.Index > 0)
						o.Append(',');
					Type(a, o);
				}
				o.Append(')');
			case .Param:
				o.Append(t.Name);
			case .Named:
				if (t.Sym.FullName == "Core.StringView")
				{
					o.Append("StringView");
					return;
				}
				o.Append(t.Sym.FullName);
				if (!t.Args.IsEmpty)
				{
					o.Append('<');
					for (let a in t.Args)
					{
						if (@a.Index > 0)
							o.Append(',');
						Type(a, o);
					}
					o.Append('>');
				}
			}
		}

		static void Values(IROp op, int from, String o)
		{
			for (int i = from; i < op.Operands.Count; i++)
			{
				o.Append(' ');
				op.Operands[i].Ref(o);
			}
		}

		public static void Op(IROp op, String o)
		{
			o.Append("\t\t");
			if (op.HasResult)
			{
				op.Ref(o);
				o.Append(" = ");
			}
			if (op.Kind == .Vec || op.Kind == .LaneCheck)
			{
				VectorOp(op, o); // LowerVector.bf: `vec.<what> ...`, `lanecheck`
				return;
			}
			o.Append(sMnemonics[(int)op.Kind]);
			if (HasType(op.Kind))
			{
				o.Append(' ');
				Type(op.Type, o);
			}
			switch (op.Kind)
			{
			case .Const:
				o.Append(' ');
				if (op.LitIsString)
					Quote(op.Lit, o);
				else
					o.Append(op.Lit);
			case .LoadSlot, .SlotAddr, .Local:
				o.AppendF(" s{}", op.Slot.Id);
			case .StoreSlot:
				o.AppendF(" s{}", op.Slot.Id);
				Values(op, 0, o);
			case .Binop, .Cmp, .Intrinsic, .CaseMake:
				o.AppendF(" {}", op.Sub);
				Values(op, 0, o);
			case .FieldAddr:
				Values(op, 0, o);
				o.AppendF(" {}", op.Sub);
			case .GlobalAddr:
				o.AppendF(" {}", op.Global);
			case .Call, .VCall, .ICall, .CCall, .FnAddr:
				o.AppendF(" {}", op.Callee);
				Values(op, 0, o);
			case .RegionEnter, .RegionExit:
				o.AppendF(" r{}", op.Region.Id);
			case .Defer:
				o.AppendF(" r{} b{}", op.Region.Id, op.Target.Id);
			case .TypeInfo, .SizeOf, .AlignOf:
				o.Append(' ');
				Type(op.TypeArg, o);
			case .Extract:
				Values(op, 0, o);
				o.AppendF(" {}", op.Index);
			case .EnumPayload:
				Values(op, 0, o);
				o.AppendF(" {} {}", op.Sub, op.Index);
			case .LocalArray:
				o.AppendF(" s{}", op.Slot.Id);
				Values(op, 0, o);
			case .AtomicLoad, .AtomicStore, .AtomicCas, .Fence:
				o.AppendF(" {}", op.Order);
				Values(op, 0, o);
			case .AtomicRmw:
				o.AppendF(" {} {}", op.Sub, op.Order);
				Values(op, 0, o);
			case .Bind:
				o.AppendF(" {}", op.Callee);
				Values(op, 0, o);
			case .BindLocal:
				o.AppendF(" s{} {}", op.Slot.Id, op.Callee);
				Values(op, 0, o);
			case .Closure:
				Values(op, 0, o);
				o.AppendF(" {}", op.Callee);
			default:
				Values(op, 0, o);
			}
			if (!op.Node.IsEmpty)
			{
				o.AppendF(" @{}", op.Node);
				if (!op.Pin.IsEmpty)
					o.AppendF(".{}", op.Pin);
			}
			o.Append('\n');
		}

		static void Term(IRBlock b, String o)
		{
			o.Append("\t\t");
			switch (b.Term)
			{
			case .None, .Unreachable: o.Append("unreachable");
			case .Br: o.AppendF("br b{}", b.Targets[0].Id);
			case .CondBr:
				o.Append("condbr ");
				b.Cond.Ref(o);
				o.AppendF(" b{} b{}", b.Targets[0].Id, b.Targets[1].Id);
			case .Switch:
				o.Append("switch ");
				b.Cond.Ref(o);
				o.AppendF(" b{}", b.Targets[b.Cases.Count].Id);
				for (int i < b.Cases.Count)
					o.AppendF(" {} b{}", b.Cases[i], b.Targets[i].Id);
			case .Ret:
				o.Append("ret");
				if (b.RetVal != null)
				{
					o.Append(' ');
					b.RetVal.Ref(o);
				}
			case .EndDefer: o.Append("enddefer");
			case .Fatal:
				o.AppendF("fatal {} ", b.FatalCode);
				Quote(b.FatalMessage ?? "", o);
			}
			if (!b.TermNode.IsEmpty)
				o.AppendF(" @{}", b.TermNode);
			o.Append('\n');
		}

		static StringView SlotWord(SlotKind k)
		{
			switch (k)
			{
			case .Local: return "local";
			case .Variable: return "variable";
			case .OutTemp: return "outtemp";
			case .LoopVar: return "loopvar";
			}
		}

		public static void Function(IRFunction f, String o)
		{
			o.AppendF("\nfunc {} ", f.Key);
			Type(f.Ret, o);
			if (f.StaticCtor)
				o.Append(" sctor");
			else if (f.Static && f.Import == null)
				o.Append(" static");
			if (f.Virtual)
				o.Append(" virtual");
			if (f.Abstract)
				o.Append(" abstract");
			if (f.Import != null)
			{
				o.Append(" import ");
				Quote(f.Import, o);
			}
			if (f.Export != null)
			{
				o.Append(" export ");
				Quote(f.Export, o);
			}
			if (!f.Sheet.IsEmpty)
			{
				o.Append(" sheet ");
				Quote(f.Sheet, o);
			}
			if (!f.Display.IsEmpty)
			{
				o.Append(" display ");
				Quote(f.Display, o);
			}
			o.Append('\n');
			if (!f.HasBody)
				return;
			for (let p in f.Params)
			{
				if (p.Param == "this" && @p.Index == 0 && !f.Static)
					continue;
				o.AppendF("\tparam {} ", p.Param);
				Type(p.Type, o);
				o.Append('\n');
			}
			for (let r in f.Regions)
			{
				if (r.Id == 0)
					continue;
				o.AppendF("\tregion r{}", r.Id);
				if (r.Parent != null && r.Parent.Id != 0)
					o.AppendF(" parent r{}", r.Parent.Id);
				o.Append('\n');
			}
			for (let s in f.Slots)
			{
				o.AppendF("\tslot s{} ", s.Id);
				if (s.TypeText != null)
					o.Append(s.TypeText);
				else
					Type(s.Type, o);
				o.AppendF(" {}", SlotWord(s.Kind));
				// the user-facing name (Follow-ups "Back end -> front end"): a variable by its name,
				// anything else as the pin value it holds (`b7.result`)
				if (s.Kind == .Variable && !s.Name.IsEmpty)
				{
					o.Append(' ');
					Quote(s.Name, o);
					o.Append(" local");
				}
				else if (!s.Node.IsEmpty)
				{
					o.Append(' ');
					Quote(s.Pin.IsEmpty ? s.Node : scope String()..AppendF("{}.{}", s.Node, s.Pin), o);
					o.Append(" pin");
				}
				if (s.Region != null && s.Region.Id != 0)
					o.AppendF(" region r{}", s.Region.Id);
				if (!s.Node.IsEmpty)
				{
					o.AppendF(" node {}", s.Node);
					if (!s.Pin.IsEmpty)
						o.AppendF(".{}", s.Pin);
				}
				o.Append('\n');
			}
			for (let n in f.Nodes)
			{
				o.AppendF("\tnode {} {}", n.id, n.kind);
				if (!n.subject.IsEmpty)
					o.AppendF(" {}", n.subject);
				o.Append('\n');
			}
			for (let b in f.Blocks)
			{
				o.AppendF("\tblock b{}\n", b.Id);
				for (let op in b.Ops)
					Op(op, o);
				Term(b, o);
			}
		}
	}
}
