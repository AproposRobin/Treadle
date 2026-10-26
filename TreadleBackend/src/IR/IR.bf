using System;
using System.Collections;

namespace Treadle.Backend.IR
{
	// The Sheet IR (docs/Compiler.md section 4): what the front end's Lower stage hands to the back
	// end, in memory (these classes) or as text (IRReader / IRWriter, the `.tir` dump form). One
	// IRFunction per lowered Sheet (per instantiation for generics); every op knows its node and pin.
	//
	// Ownership: the IRProgram owns every type, declaration, global, unit and function; a function
	// owns its params, slots, regions, blocks and nodes; a block owns its ops; an op owns its result
	// value. References between them (an op's operands, a slot's region, a call's callee) are plain
	// pointers into that tree.

	/// The kinds of IR type. `Named` covers classes, structs, enums and interfaces (the decl says
	/// which); a Named class or interface value is a reference (a pointer to the object).
	enum IRTypeKind : uint8
	{
		Void,
		Bool,
		/// Bits 8 / 16 / 32 / 64 (/ 128), Signed.
		Int,
		/// Bits 32 / 64.
		Float,
		/// UTF-8 code unit (an unsigned 8-bit integer).
		Char8,
		/// A code point (an unsigned 32-bit integer).
		Char32,
		/// `T*` (Elem); `void*` is the untyped pointer.
		Pointer,
		/// `ref T` (Elem): a pointer the language treats as a reference to a variable.
		Ref,
		/// A class, struct, enum or interface by name (Decl after linking).
		Named,
		/// `T[]` (Elem): a reference to an array object `{ vtable, i64 length, T... }`.
		Array,
		/// `T[N]` (Elem, Count): inline.
		FixedArray,
		/// `T?` (Elem): `{ T, bool }`.
		Nullable,
		/// `(A, B, ...)` (Items).
		Tuple,
		/// `StringView`: `{ char8*, int }`.
		StringView,
		/// `function R(A, B)` (Ret, Items): a raw function pointer.
		FnPtr,
		/// `delegate R(A, B)` (Ret, Items): a reference to a delegate object
		/// `{ vtable, ptr target, ptr fn }` (`Core.Delegate` or a closure class derived from it).
		Delegate,
		/// A vector primitive (`float4`, `int32x4`, `bool4`; Elem the lane type, Count the lanes):
		/// an LLVM `<N x T>` value (IRVector.bf, SIMD-and-Vectors.md 1).
		Vector
	}

	/// A type. Types are interned by their canonical text (IRProgram.Type), so two equal types are
	/// the same object and may be compared by reference.
	class IRType
	{
		public IRTypeKind Kind;
		public int32 Bits;
		public bool Signed;
		public IRType Elem;
		public int64 Count;
		public IRType Ret;
		public List<IRType> Items = new .() ~ delete _;
		/// Named: the qualified name, one segment per dotted part (generic args per segment).
		public IRName Name ~ delete _;
		/// Named: the declaration, set by IRProgram.Link (null for an unknown name: a link error).
		public IRTypeDecl Decl;
		/// The canonical text ("Core.Pair<int,int>", "int32*", "ref Game.Pair", "(int,float)").
		public String Text = new .() ~ delete _;

		// Layout caches (filled by the emitter's Layout).
		public int64 Size = -1;
		public int64 Align;
		public String LLVM ~ delete _;
		/// Vectors: the LLVM type in memory when it differs from the value's (Layout.Mem).
		public String LLVMMem ~ delete _;

		public bool IsVoid => Kind == .Void;
		public bool IsInteger => Kind == .Int || Kind == .Char8 || Kind == .Char32;
		public bool IsFloat => Kind == .Float;
		public bool IsSignedInt => Kind == .Int && Signed;
		/// True for every type whose value is a single pointer.
		public bool IsPointerLike
		{
			get
			{
				switch (Kind)
				{
				case .Pointer, .Ref, .Array, .FnPtr, .Delegate: return true;
				case .Named: return Decl != null && (Decl.Kind == .Class || Decl.Kind == .Interface);
				default: return false;
				}
			}
		}
		/// A reference to an object with a vtable header (class, interface, array).
		public bool IsObjectRef => Kind == .Array || Kind == .Delegate || (Kind == .Named && Decl != null && (Decl.Kind == .Class || Decl.Kind == .Interface));
		public bool IsClass => Kind == .Named && Decl != null && Decl.Kind == .Class;
		public bool IsStruct => Kind == .Named && Decl != null && Decl.Kind == .Struct;
		public bool IsEnum => Kind == .Named && Decl != null && Decl.Kind == .Enum;
		public bool IsPayloadEnum => IsEnum && Decl.IsPayloadEnum;
		public bool IsVector => Kind == .Vector;

		public override void ToString(String strBuffer) => strBuffer.Append(Text);
	}

	/// One dotted part of a qualified name with its generic arguments: `Pair<int,int>`.
	class IRNameSeg
	{
		public String Ident = new .() ~ delete _;
		/// Interned types (owned by the program).
		public List<IRType> Args = new .() ~ delete _;
	}

	/// A qualified name: `Core.Pair<int,int>` is [Core] [Pair<int,int>].
	class IRName
	{
		public List<IRNameSeg> Segs = new .() ~ DeleteContainerAndItems!(_);

		public bool HasGenericArgs
		{
			get
			{
				for (let s in Segs)
					if (!s.Args.IsEmpty)
						return true;
				return false;
			}
		}

		public void ToString(String outText)
		{
			for (let s in Segs)
			{
				if (@s.Index > 0)
					outText.Append('.');
				outText.Append(s.Ident);
				if (!s.Args.IsEmpty)
				{
					outText.Append('<');
					for (let a in s.Args)
					{
						if (@a.Index > 0)
							outText.Append(',');
						outText.Append(a.Text);
					}
					outText.Append('>');
				}
			}
		}

		public IRName Clone()
		{
			IRName n = new .();
			for (let s in Segs)
			{
				IRNameSeg c = new .();
				c.Ident.Set(s.Ident);
				c.Args.AddRange(s.Args);
				n.Segs.Add(c);
			}
			return n;
		}
	}

	enum IRDeclKind : uint8
	{
		Class,
		Struct,
		Enum,
		Interface
	}

	class IRField
	{
		public String Name = new .() ~ delete _;
		public IRType Type;
		/// "Owned, deleted with the object": the class's complete destructor deletes it.
		public bool Owned;
	}

	/// One vtable slot: the function that declares it (the first virtual) and the function this class
	/// runs for it (null: abstract).
	class IRVSlot
	{
		public IRFunction Decl;
		public IRFunction Impl;
		public String DeclKey ~ delete _;
		public String ImplKey ~ delete _;
	}

	/// A class's table for one interface: the implementations in the interface's slot order.
	class IRITable
	{
		public IRTypeDecl Iface;
		public String IfaceName ~ delete _;
		public List<IRFunction> Impls = new .() ~ delete _;
		public List<String> ImplKeys = new .() ~ DeleteContainerAndItems!(_);
	}

	class IREnumCase
	{
		public String Name = new .() ~ delete _;
		/// Simple enums: the case's value. Payload enums: the tag (the case index).
		public int64 Value;
		public List<IRType> Payload = new .() ~ delete _;
	}

	/// A class, struct, enum or interface (one per instantiation for generic types).
	class IRTypeDecl
	{
		public IRDeclKind Kind;
		/// The type this declares (Named; its Text is the declaration's name).
		public IRType Type;
		public IRTypeDecl Base;
		public String BaseName ~ delete _;
		public bool Abstract;
		/// `[Packed]`: no padding.
		public bool Packed;
		public List<IRField> Fields = new .() ~ DeleteContainerAndItems!(_);
		/// Class: every slot, base class slots first (the front end assigns them).
		public List<IRVSlot> VTable = new .() ~ DeleteContainerAndItems!(_);
		/// Class: the interfaces it implements, with their tables.
		public List<IRITable> ITables = new .() ~ DeleteContainerAndItems!(_);
		/// Interface: its functions in slot order (extended interfaces first).
		public List<IRFunction> ISlots = new .() ~ delete _;
		public List<String> ISlotKeys = new .() ~ DeleteContainerAndItems!(_);
		/// Enum: the cases. A payload enum has at least one case with a payload.
		public List<IREnumCase> Cases = new .() ~ DeleteContainerAndItems!(_);
		/// Simple enum: the underlying integer type (int32 when not given).
		public IRType TagType;
		/// The destructor's Sheet (`~this`), null when the type has none. The back end makes the
		/// complete destructor (this Sheet, then owned fields, then the base's).
		public IRFunction Dtor;
		public String DtorKey ~ delete _;
		/// The compile unit that defines it; null (core types, generic instances): emitted
		/// linkonce_odr in every unit that needs it.
		public IRUnit Unit;
		/// Line in the text form (0 in memory).
		public int32 Line;
		/// Declared by the back end, not by the program (`Core.Object`, `Core.Delegate`); not written.
		public bool Implicit;

		public StringView Name => Type.Text;
		public bool IsPayloadEnum
		{
			get
			{
				if (Kind != .Enum)
					return false;
				for (let c in Cases)
					if (!c.Payload.IsEmpty)
						return true;
				return false;
			}
		}
		public bool IsShared => Unit == null || Type.Name.HasGenericArgs;

		public IREnumCase FindCase(StringView name)
		{
			for (let c in Cases)
				if (c.Name == name)
					return c;
			return null;
		}

		/// Finds a field of this type or, for a class, of its bases (the most derived first).
		public IRField FindField(StringView name, out IRTypeDecl owner)
		{
			for (var d = this; d != null; d = d.Base)
				for (let f in d.Fields)
					if (f.Name == name)
					{
						owner = d;
						return f;
					}
			owner = null;
			return null;
		}

		public int FindVSlot(IRFunction decl)
		{
			for (let s in VTable)
				if (s.Decl == decl || s.Impl == decl)
					return @s.Index;
			return -1;
		}
	}

	/// A static field (or any program global).
	class IRGlobal
	{
		/// Qualified name, "Game.Player.sCount".
		public IRName Name ~ delete _;
		public String Text = new .() ~ delete _;
		public IRType Type;
		/// The initial value as a literal ("" = zero).
		public String Init = new .() ~ delete _;
		/// `global <name> T import "<symbol>"`: an extern C variable, defined elsewhere (a C object
		/// linked in, a library) under that symbol; null for the program's own globals.
		public String Import ~ delete _;
		/// `global <name> T const <value>`: a read-only global (a constant whose address is taken);
		/// for a fixed array `T[N]` its N element tokens follow (a constant array).
		public bool Const;
		public List<String> Elements ~ DeleteContainerAndItems!(_);
		public IRUnit Unit;
		public int32 Line;
	}

	enum IRSlotKind : uint8
	{
		/// The storage of a Local node (the object itself for a class, the value for a struct).
		Local,
		/// A local variable of the function.
		Variable,
		/// A hidden temp: a flow node's result, an out pin.
		OutTemp,
		/// A loop's own variable (index, element).
		LoopVar
	}

	/// What a slot's user-facing name names (the `slot` record's `"<name>" local|pin`): a local
	/// variable of the Sheet, or a node's pin value (`b7.result`). None for an unnamed slot.
	enum IRSlotShows : uint8
	{
		None,
		Local,
		Pin
	}

	class IRRegion
	{
		public String Id = new .() ~ delete _;
		public IRRegion Parent;
		/// The function body region (`r0`, made for every function).
		public bool IsBody;
	}

	class IRSlot
	{
		public String Id = new .() ~ delete _;
		public IRType Type;
		public IRSlotKind Kind;
		/// Local slots: the region whose exit destroys the object.
		public IRRegion Region;
		public String RegionId ~ delete _;
		/// The node (and pin) the slot belongs to ("" = none).
		public String NodeId = new .() ~ delete _;
		public String Pin = new .() ~ delete _;
		/// The user-facing name ("pet", "b7.result"; "" = none, the old unnamed form) and what it
		/// names. The DWARF variable and the alloca take it.
		public String Name = new .() ~ delete _;
		public IRSlotShows Shows;
		/// The type as the Sheet spells it when that differs from the IR's canonical text (`int64`
		/// for an `int` slot): the DWARF type shows it, the text form keeps it. Null = Type.Text.
		public String TypeText ~ delete _;

		/// The debugger's name: the slot's name, else `<node>.<pin>`, else the id.
		public void DebugName(String outName)
		{
			if (!Name.IsEmpty)
				outName.Append(Name);
			else if (Kind == .Variable || NodeId.IsEmpty)
				outName.Append(Id);
			else if (Pin.IsEmpty)
				outName.Append(NodeId);
			else
				outName.AppendF("{}.{}", NodeId, Pin);
		}
	}

	/// An SSA value: a parameter or the result of an op.
	class IRValue
	{
		public String Name = new .() ~ delete _;
		public IRType Type;
		/// The op that defines it (null for a parameter).
		public IROp Def;
		/// Parameter index (`this` is 0 for instance functions), -1 for op results.
		public int32 ParamIndex = -1;
		/// Parameters: the type as the Sheet spells it when that differs from Type.Text (`int64`);
		/// null = Type.Text.
		public String TypeText ~ delete _;
	}

	/// One node of the Sheet: what the listing file shows on the node's line.
	class IRNodeInfo
	{
		public String Id = new .() ~ delete _;
		public String Kind = new .() ~ delete _;
		public String Subject = new .() ~ delete _;
	}

	enum IROpKind : uint8
	{
		// values and slots
		Const, Copy, LoadSlot, StoreSlot, SlotAddr,
		// arithmetic
		Binop, Cmp, Cast, Select,
		// memory
		FieldAddr, ElemAddr, Load, Store, NullCheck, BoundsCheck, GlobalAddr, ArrayLen,
		// calls
		Call, VCall, ICall, CCall, FptrCall, FnAddr,
		// allocation and lifetimes
		Alloc, AllocArray, Local, Free, Dtor, Delete, RegionEnter, RegionExit, Defer,
		// objects
		Box, Unbox, DynCast, TypeInfo,
		// aggregates and enums
		Make, Extract, CaseMake, EnumTag, EnumPayload,
		// compile-time facts and intrinsics
		SizeOf, AlignOf, Intrinsic,
		// dynamically sized Local arrays, atomics, delegates
		LocalArray, AtomicLoad, AtomicStore, AtomicRmw, AtomicCas, Fence, Bind, BindLocal, Closure, Invoke,
		// a Span over an array (its whole storage, or a checked range)
		ArraySpan,
		// vector primitives: `vec.<what>` (Sub) and the Debug lane check (IRVector.bf)
		Vec, LaneCheck,
		// terminators
		Br, CondBr, Switch, Ret, EndDefer, Unreachable, Fatal
	}

	class IRSwitchCase
	{
		public int64 Value;
		public IRBlock Target;
		public String TargetId ~ delete _;
	}

	/// One operation. Which fields an op uses depends on its kind (IRWriter.Mnemonic lists the
	/// text form of each): `Args` are its value operands in order; the others name what is not a
	/// value (a slot, a callee, a type, a block, a region, a field or case, a literal).
	class IROp
	{
		public IROpKind Kind;
		/// The result (null for ops without one, and for calls returning void). Owned.
		public IRValue Result ~ delete _;
		/// The op's type: the result type; for calls the return type (void included).
		public IRType Type;
		public List<IRValue> Args = new .() ~ delete _;
		/// Slot ops, `local`.
		public IRSlot Slot;
		/// Calls, `fn.addr`.
		public IRFunction Fn;
		/// `alloc` / `typeinfo` / `sizeof` / `alignof` / `dyncast`: the type operated on.
		public IRType TypeArg;
		/// `global.addr`.
		public IRGlobal Global;
		/// `br`, `defer` (the body's first block); `condbr`: true then false; `switch`: the default.
		public List<IRBlock> Targets = new .() ~ delete _;
		public List<IRSwitchCase> Cases = new .() ~ DeleteContainerAndItems!(_);
		/// `region.enter` / `region.exit` / `defer`.
		public IRRegion Region;
		/// `binop` / `cmp` operator, field name, case name, intrinsic name.
		public String Sub = new .() ~ delete _;
		/// Atomics: the memory order (`relaxed`, `acquire`, `release`, `acqrel`, `seqcst`).
		public String Order = new .() ~ delete _;
		/// `extract` / `enum.payload` index, `fatal` code.
		public int64 Index;
		/// `const` literal ("5", "1.5", "true", "null", "zero", or the text of a string), `fatal` message.
		public String Lit = new .() ~ delete _;
		/// `const`: the literal was a quoted string.
		public bool LitIsString;
		/// The node and pin this op belongs to ("" = made by the back end).
		public String NodeId = new .() ~ delete _;
		public String Pin = new .() ~ delete _;
		/// Line in the text form (0 in memory).
		public int32 Line;

		// names used by the text form until IRProgram.Link resolves them
		public List<String> ArgNames ~ DeleteContainerAndItems!(_);
		public String FnKey ~ delete _;
		public String SlotId ~ delete _;
		public String GlobalName ~ delete _;
		public String RegionId ~ delete _;
		public List<String> TargetIds ~ DeleteContainerAndItems!(_);

		public bool IsTerminator => Kind >= .Br;
	}

	class IRBlock
	{
		public String Id = new .() ~ delete _;
		/// The ops in order; the last one is the terminator.
		public List<IROp> Ops = new .() ~ DeleteContainerAndItems!(_);
		public IRFunction Function;

		public IROp Terminator => Ops.IsEmpty ? null : Ops.Back;

		/// Appends a new op (in-process construction).
		public IROp Add(IROpKind kind, IRType type = null)
		{
			IROp op = new .();
			op.Kind = kind;
			op.Type = type;
			Ops.Add(op);
			return op;
		}
	}

	enum IRCallConv : uint8
	{
		Default,
		CDecl,
		StdCall,
		FastCall
	}

	/// A function: a lowered Sheet, an abstract or interface declaration (no blocks), or an imported C
	/// function (`Import`).
	class IRFunction
	{
		/// The canonical reference text, unique in the program: "Game.Rect.Area()",
		/// "Core.Math.Max<int>(int,int)", "Game.Node.this(int)", "C.libc.printf(char8*,...)".
		public String Key = new .() ~ delete _;
		/// The owner type's name (all but the last segment of the qualified name).
		public IRName Owner ~ delete _;
		/// The member name ("Area", "this" for a constructor, "~this" for the destructor).
		public String Name = new .() ~ delete _;
		public List<IRType> GenericArgs = new .() ~ delete _;
		/// Parameter types, without `this`.
		public List<IRType> ParamTypes = new .() ~ delete _;
		public IRType Ret;
		public bool Static;
		public bool Virtual;
		public bool Abstract;
		public bool Variadic;
		/// Runs before Main (a static constructor).
		public bool StaticCtor;
		/// C linkage: the C symbol it calls (imports have no blocks).
		public String ImportName ~ delete _;
		/// `[Export("name")]`: also defined under this C name.
		public String ExportName ~ delete _;
		public IRCallConv Conv;
		/// The Sheet's key in the type file ("f8d2a", "get:f1", "lambda:a7"; "" = none).
		public String SheetKey = new .() ~ delete _;
		/// The name diagnostics and the runtime show ("Game.Rect.Area"); empty = owner + "." + name.
		public String Display = new .() ~ delete _;
		/// The unit whose type file holds the Sheet. A non-generic function is defined there;
		/// generic instances (and functions with no unit) are emitted linkonce_odr where used.
		public IRUnit Unit;
		/// The owner's declaration (null for C imports and free functions).
		public IRTypeDecl OwnerDecl;

		/// Parameter values in order (`this` first for an instance function). Owned.
		public List<IRValue> Params = new .() ~ DeleteContainerAndItems!(_);
		public List<IRSlot> Slots = new .() ~ DeleteContainerAndItems!(_);
		/// Regions; the first is the body region `r0` (made by the constructor).
		public List<IRRegion> Regions = new .() ~ DeleteContainerAndItems!(_);
		public List<IRBlock> Blocks = new .() ~ DeleteContainerAndItems!(_);
		/// The Sheet's nodes for the listing (Compiler.md section 7).
		public List<IRNodeInfo> Nodes = new .() ~ DeleteContainerAndItems!(_);
		public int32 Line;

		public this()
		{
			IRRegion body = new .();
			body.Id.Set("r0");
			body.IsBody = true;
			Regions.Add(body);
		}

		public bool HasBody => !Blocks.IsEmpty;
		public bool IsImport => ImportName != null;
		public bool IsCtor => Name == "this";
		public bool IsDtor => Name == "~this";
		public bool HasThis => !Static && !IsImport && OwnerDecl != null && OwnerDecl.Kind != .Enum;
		public bool IsInstance => !GenericArgs.IsEmpty || (Owner != null && Owner.HasGenericArgs);
		public bool IsShared => IsInstance || Unit == null;
		public IRRegion BodyRegion => Regions[0];

		public void GetDisplay(String outText)
		{
			if (!Display.IsEmpty)
			{
				outText.Append(Display);
				return;
			}
			if (Owner != null)
			{
				Owner.ToString(outText);
				outText.Append('.');
			}
			outText.Append(Name);
		}

		public IRSlot FindSlot(StringView id)
		{
			for (let s in Slots)
				if (s.Id == id)
					return s;
			return null;
		}

		public IRRegion FindRegion(StringView id)
		{
			for (let r in Regions)
				if (r.Id == id)
					return r;
			return null;
		}

		public IRBlock FindBlock(StringView id)
		{
			for (let b in Blocks)
				if (b.Id == id)
					return b;
			return null;
		}

		public IRValue AddParam(StringView name, IRType type)
		{
			IRValue v = new .();
			v.Name.Set(name);
			v.Type = type;
			v.ParamIndex = (int32)Params.Count;
			Params.Add(v);
			return v;
		}

		public IRSlot AddSlot(StringView id, IRType type, IRSlotKind kind)
		{
			IRSlot s = new .();
			s.Id.Set(id);
			s.Type = type;
			s.Kind = kind;
			Slots.Add(s);
			return s;
		}

		/// A slot with its user-facing name: a local's name (`shows` .Local) or `<node>.<pin>` (.Pin).
		public IRSlot AddSlot(StringView id, IRType type, IRSlotKind kind, StringView name, IRSlotShows shows)
		{
			let s = AddSlot(id, type, kind);
			s.Name.Set(name);
			s.Shows = name.IsEmpty ? .None : shows;
			return s;
		}

		public IRRegion AddRegion(StringView id, IRRegion parent)
		{
			IRRegion r = new .();
			r.Id.Set(id);
			r.Parent = parent;
			Regions.Add(r);
			return r;
		}

		public IRBlock AddBlock(StringView id)
		{
			IRBlock b = new .();
			b.Id.Set(id);
			b.Function = this;
			Blocks.Add(b);
			return b;
		}

		public IRNodeInfo AddNode(StringView id, StringView kind, StringView subject)
		{
			IRNodeInfo n = new .();
			n.Id.Set(id);
			n.Kind.Set(kind);
			n.Subject.Set(subject);
			Nodes.Add(n);
			return n;
		}
	}

	/// A compile unit: one type file. Its functions, types and globals are defined in its `.ll`.
	class IRUnit
	{
		/// The unit's name: the type's full name ("Game.Program"); the `.ll`, `.o`, `.lst` and
		/// `.nodemap` files are named after it.
		public String Name = new .() ~ delete _;
		/// The type file it came from (diagnostics; "" in fixtures).
		public String SourcePath = new .() ~ delete _;
	}

	/// The project's `kind` (Graph-Format.md 5): a console exe, a windowed exe (Windows subsystem), or a
	/// library (a DLL or .so whose `[Export]` functions are its exports; no entry).
	enum IRProgramKind : uint8
	{
		Console,
		Windowed,
		Library
	}

	/// A whole program as the front end lowers it: every unit, type, global and function.
	class IRProgram
	{
		public String Name = new .() ~ delete _;
		public IRProgramKind Kind;
		/// `Main` (static; returns int, int32 or void; no parameters).
		public IRFunction Entry;
		public String EntryKey ~ delete _;
		public List<IRUnit> Units = new .() ~ DeleteContainerAndItems!(_);
		public List<IRTypeDecl> Decls = new .() ~ DeleteContainerAndItems!(_);
		public List<IRGlobal> Globals = new .() ~ DeleteContainerAndItems!(_);
		public List<IRFunction> Functions = new .() ~ DeleteContainerAndItems!(_);
		/// Interned types by canonical text. Owns the types (keys are their Text).
		public Dictionary<String, IRType> Types = new .() ~ { for (let kv in _) delete kv.value; delete _; };
		/// Libraries the link adds (the `lib` keys of the program's C import sets: an import
		/// library's path, or a bare name passed as -l<name>). Not part of the text form.
		public List<String> LinkInputs = new .() ~ DeleteContainerAndItems!(_);
		/// Files the program needs next to its exe at run time (a C import set's `bin` keys, DLLs);
		/// Build copies them there. Not part of the text form.
		public List<String> RunFiles = new .() ~ DeleteContainerAndItems!(_);
		/// What the program is made from besides its text (the front end: the project and C import
		/// set files, the C sources the link compiles, the core library), one line each with a time
		/// or a hash. The link stamp lists them, so a change links again. Not part of the text form.
		public List<String> InputStamps = new .() ~ DeleteContainerAndItems!(_);
		Dictionary<String, IRFunction> mFnByKey = new .() ~ delete _;
		Dictionary<String, IRTypeDecl> mDeclByName = new .() ~ delete _;

		/// The type for `text` (parsed and interned). Err with `outError` when it does not parse.
		public Result<IRType> Type(StringView text, String outError = null)
		{
			if (Types.TryGetValueAlt(text, let found))
				return found;
			TypeParser p = scope .(this, text);
			if (p.ParseType() case .Ok(let t))
			{
				if (!p.AtEnd)
				{
					outError?.AppendF("unexpected '{}' in type '{}'", p.Rest, text);
					return .Err;
				}
				return t;
			}
			outError?.Append(p.Error);
			return .Err;
		}

		/// The type for `text`; fatal for text that does not parse (in-process construction).
		public IRType T(StringView text)
		{
			String err = scope .();
			if (Type(text, err) case .Ok(let t))
				return t;
			Runtime.FatalError(scope $"IR type '{text}': {err}");
		}

		/// Interns a type built by the parser (or returns the equal one already there).
		public IRType Intern(IRType t)
		{
			if (Types.TryGetValue(t.Text, let found))
			{
				if (found != t)
					delete t;
				return found;
			}
			Types[t.Text] = t;
			return t;
		}

		public IRUnit AddUnit(StringView name)
		{
			IRUnit u = new .();
			u.Name.Set(name);
			Units.Add(u);
			return u;
		}

		public IRUnit FindUnit(StringView name)
		{
			for (let u in Units)
				if (u.Name == name)
					return u;
			return null;
		}

		/// Declares a type (`name` is its full name with generic args).
		public IRTypeDecl AddDecl(IRDeclKind kind, StringView name, IRUnit unit)
		{
			IRTypeDecl d = new .();
			d.Kind = kind;
			d.Type = T(name);
			d.Unit = unit;
			d.Type.Decl = d;
			Decls.Add(d);
			mDeclByName[d.Type.Text] = d;
			return d;
		}

		public IRTypeDecl FindDecl(StringView name)
		{
			if (mDeclByName.TryGetValueAlt(name, let d))
				return d;
			return null;
		}

		/// Adds a function from its reference text (`Game.Rect.Area()`); fatal when it does not parse.
		public IRFunction AddFunction(StringView key, IRType ret, IRUnit unit)
		{
			IRFunction f = new .();
			String err = scope .();
			if (!FuncKey.Parse(this, key, f, err))
				Runtime.FatalError(scope $"IR function '{key}': {err}");
			f.Ret = ret;
			f.Unit = unit;
			Functions.Add(f);
			mFnByKey[f.Key] = f;
			return f;
		}

		/// Registers a function built by the reader (key already canonical).
		public bool Register(IRFunction f)
		{
			if (mFnByKey.ContainsKey(f.Key))
				return false;
			Functions.Add(f);
			mFnByKey[f.Key] = f;
			return true;
		}

		public IRFunction FindFunction(StringView key)
		{
			if (mFnByKey.TryGetValueAlt(key, let f))
				return f;
			// Not canonical as written: parse and print it again.
			IRFunction probe = scope .();
			if (FuncKey.Parse(this, key, probe, null) && mFnByKey.TryGetValue(probe.Key, let f2))
				return f2;
			return null;
		}

		public IRGlobal AddGlobal(StringView name, IRType type, IRUnit unit)
		{
			IRGlobal g = new .();
			g.Text.Set(name);
			g.Name = TypeParser.ParseName(this, name);
			g.Type = type;
			g.Unit = unit;
			Globals.Add(g);
			return g;
		}

		public IRGlobal FindGlobal(StringView name)
		{
			for (let g in Globals)
				if (g.Text == name)
					return g;
			return null;
		}

		/// `Core.Object`: the root class, declared by the back end when the program does not.
		public IRTypeDecl ObjectDecl
		{
			get
			{
				var d = FindDecl("Core.Object");
				if (d == null)
				{
					d = AddDecl(.Class, "Core.Object", null);
					d.Implicit = true;
				}
				return d;
			}
		}

		/// `Core.Delegate`: the class of every delegate object (`{ vtable, target, fn }`); closure
		/// classes derive from it. Declared by the back end when the program does not.
		public IRTypeDecl DelegateDecl
		{
			get
			{
				var d = FindDecl("Core.Delegate");
				if (d == null)
				{
					d = AddDecl(.Class, "Core.Delegate", null);
					d.Implicit = true;
					IRField t = new .();
					t.Name.Set("target");
					t.Type = T("void*");
					d.Fields.Add(t);
					IRField f = new .();
					f.Name.Set("fn");
					f.Type = T("void*");
					d.Fields.Add(f);
				}
				return d;
			}
		}

		/// Resolves every name the text form left (types, bases, slots, callees, blocks, values) and
		/// checks the structure the emitter relies on. Appends "line N: ..." messages to `outErrors`
		/// and returns false when anything is wrong.
		public bool Link(List<String> outErrors) => IRLinker.Link(this, outErrors);
	}
}
