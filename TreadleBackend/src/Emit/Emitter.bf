using System;
using System.Collections;
using Treadle.Backend.IR;

namespace Treadle.Backend.Emit
{
	class EmitOptions
	{
		/// Debug: `-O0` code with the checks (nullcheck, boundscheck as branches), the debug runtime
		/// entry points (`rt_alloc_dbg` with sites) and full DWARF; Release: plain runtime calls, the
		/// check ops dropped, line tables only.
		public bool Debug = true;
		/// The units are compiled with optimisation (a config's `optimize` above 0): isOptimized in the debug info.
		public bool Optimized;
		/// The debug info formats (a project config's `debugFormat`, docs/Compiler.md 7): DWARF (the
		/// default; lldb and lldb-dap read it) and CodeView (a PDB for Visual Studio, WinDbg and other
		/// PDB readers; Windows only, ignored for an ELF target). Both on: each unit carries both.
		public bool Dwarf = true;
		public bool CodeView;
		/// The folder the listings are written to (DIFile directory; forward slashes are used).
		public String ListingDir = new .() ~ delete _;
		/// The target: the platform the editor runs on (x86-64 Windows through llvm-mingw, or x86-64
		/// Linux with glibc; docs/Linux.md).
#if BF_PLATFORM_WINDOWS
		public String Triple = new .("x86_64-w64-windows-gnu") ~ delete _;
		public String DataLayout = new .("e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128") ~ delete _;
#else
		public String Triple = new .("x86_64-pc-linux-gnu") ~ delete _;
		public String DataLayout = new .("e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128") ~ delete _;
#endif
		/// An ELF target with the System V x86-64 C ABI (Linux); else COFF with the win64 C ABI.
		public bool SysV => Triple.Contains("linux");
		/// The `simd` level of the config (SIMD-and-Vectors.md 1.7): LLVM's CPU name for every function's
		/// `"target-cpu"`, and the features clang gives that CPU (`"target-features"`; "" = from the CPU).
		public String TargetCpu = new .("x86-64-v2") ~ delete _;
		public String TargetFeatures = new .() ~ delete _;
	}

	/// The output of one unit.
	class UnitOutput
	{
		public String Name = new .() ~ delete _;
		public String LL = new .() ~ delete _;
		public String Listing = new .() ~ delete _;
		public String NodeMap = new .() ~ delete _;
	}

	/// Sheet IR -> LLVM IR text, one module per unit (docs/Compiler.md section 5).
	class Emitter
	{
		public IRProgram Program;
		public Layout Layout ~ delete _;
		public Mangler Mangler ~ delete _;
		public Listing Listing = new .() ~ delete _;
		public EmitOptions Options;

		public this(IRProgram program, EmitOptions options)
		{
			Program = program;
			Options = options;
			Layout = new .(program);
			Mangler = new .(program);
		}

		/// Emits every unit. False with messages when the IR cannot be emitted.
		public bool Emit(List<UnitOutput> outUnits, List<String> outErrors)
		{
			Listing.Build(Program);
			// Core.Object's complete destructor is shared by every class chain.
			if (Program.ObjectDecl == null)
				return false;
			for (let u in Program.Units)
			{
				UnitOutput o = new .();
				o.Name.Set(u.Name);
				let lu = Listing.Find(u.Name);
				if (lu != null)
				{
					o.Listing.Set(lu.Text);
					o.NodeMap.Set(lu.NodeMap);
				}
				UnitEmitter ue = scope .(this, u);
				if (!ue.Run(o.LL, outErrors))
				{
					delete o;
					return false;
				}
				outUnits.Add(o);
			}
			return true;
		}
	}

	/// Emits one unit's module.
	class UnitEmitter
	{
		public Emitter E;
		public IRUnit Unit;
		public IRProgram P;
		public Layout L;
		public Mangler M;
		public bool Dbg;
		/// The config optimises (`optimize` above 0): the debug info says so.
		public bool Opt;

		// sections of the module
		String mTypes = new .() ~ delete _;
		String mGlobals = new .() ~ delete _;
		String mDecls = new .() ~ delete _;
		String mFuncs = new .() ~ delete _;
		public List<String> Meta = new .() ~ DeleteContainerAndItems!(_);
		List<String> mUsed = new .() ~ DeleteContainerAndItems!(_);
		List<String> mErrors;

		// what is defined or declared already (symbol names)
		HashSet<String> mDefined = new .() ~ DeleteContainerAndItems!(_);
		HashSet<String> mDeclared = new .() ~ DeleteContainerAndItems!(_);
		// shared functions and type infos still to emit here
		List<IRFunction> mFnQueue = new .() ~ delete _;
		HashSet<IRFunction> mFnQueued = new .() ~ delete _;
		List<IRType> mTypeQueue = new .() ~ delete _;
		HashSet<String> mTypeQueued = new .() ~ DeleteContainerAndItems!(_);
		Dictionary<String, String> mStrings = new .() ~ { for (let kv in _) { delete kv.key; delete kv.value; } delete _; };
		Dictionary<String, String> mSites = new .() ~ { for (let kv in _) { delete kv.key; delete kv.value; } delete _; };
		HashSet<String> mIntrinsics = new .() ~ DeleteContainerAndItems!(_);
		Dictionary<String, int32> mFiles = new .() ~ DeleteDictionaryAndKeys!(_);
		Dictionary<String, int32> mDITypes = new .() ~ DeleteDictionaryAndKeys!(_);
		int mStrCount;
		int32 mSubroutineType;
		List<int32> mGlobalExprs = new .() ~ delete _;
		public int32 CU;

		public this(Emitter e, IRUnit unit)
		{
			E = e;
			Unit = unit;
			P = e.Program;
			L = e.Layout;
			M = e.Mangler;
			Dbg = e.Options.Debug;
			Opt = e.Options.Optimized;
		}

		public void Error(StringView msg) => mErrors.Add(new .(msg));

		public bool Run(String outText, List<String> errors)
		{
			mErrors = errors;
			int before = errors.Count;
			// metadata header: !0 CU, !1 file, flags
			CU = AddMeta("");
			let file = FileMeta(Unit.Name);
			Meta[CU].Set(scope $"distinct !DICompileUnit(language: DW_LANG_C99, file: !{file}, producer: \"Treadle\", isOptimized: {(Opt ? "true" : "false")}, runtimeVersion: 0, emissionKind: {(Dbg ? "FullDebug" : "LineTablesOnly")}, splitDebugInlining: false, nameTableKind: None)");
			mSubroutineType = AddMeta("!DISubroutineType(types: !{})");

			EmitTypeDefinitions();
			RuntimeDeclarations();

			// this unit's own types: type info, vtables, complete destructors (strong)
			for (let d in P.Decls)
				if (d.Unit == Unit && !d.IsShared)
					NeedTypeInfo(d.Type);
			// this unit's globals
			for (let g in P.Globals)
				if (g.Unit == Unit)
					DefineGlobal(g);
			// this unit's functions
			for (let f in P.Functions)
				if (f.Unit == Unit && !f.IsShared && f.HasBody)
					DefineFunction(f);
			if (P.Kind == .Library)
			{
				if (!P.Units.IsEmpty && P.Units[0] == Unit)
					EmitLibraryStart();
			}
			else if (P.Entry != null && P.Entry.Unit == Unit)
				EmitMain();
			Drain();
			if (errors.Count > before)
				return false;

			outText.AppendF("; Treadle unit {} ({})\n", Unit.Name, Dbg ? "Debug" : "Release");
			outText.AppendF("source_filename = \"{}\"\n", Unit.Name);
			outText.AppendF("target datalayout = \"{}\"\n", E.Options.DataLayout);
			outText.AppendF("target triple = \"{}\"\n\n", E.Options.Triple);
			outText.Append(mTypes);
			outText.Append('\n');
			outText.Append(mGlobals);
			outText.Append('\n');
			outText.Append(mDecls);
			outText.Append('\n');
			outText.Append(mFuncs);
			if (!mUsed.IsEmpty)
			{
				outText.AppendF("@llvm.used = appending global [{} x ptr] [", mUsed.Count);
				for (let u in mUsed)
				{
					if (@u.Index > 0)
						outText.Append(", ");
					outText.AppendF("ptr {}", u);
				}
				outText.Append("], section \"llvm.metadata\"\n");
			}
			// frame pointers in Debug only (the debugger's stack walks); Release leaves them to -O2, as C.
			// The CPU attributes are the ones clang gives every C function: without "tune-cpu" the ThinLTO
			// link optimises for no CPU model and LLVM does not unroll small loops (the generics kernel ran
			// 1.2x C for this alone; Compiler.md 6.4, "Target CPU")
			String cpu = scope .(); TargetAttributes(cpu); // EmitVector.bf: the `simd` level (Compiler.md 6.4, "Target CPU")
			if (!Opt)
				outText.AppendF("\nattributes #0 = {{ nounwind uwtable \"frame-pointer\"=\"all\" {} }}\n", cpu);
			else
				outText.AppendF("\nattributes #0 = {{ nounwind uwtable {} }}\n", cpu);
			outText.Append("attributes #1 = { noreturn nounwind }\n");
			// on every call of the runtime's allocate and free entry points: with the CPU attributes the
			// link may inline runtime functions, and calloc / free in sight let LLVM remove a Construct and
			// Delete pair or a second Delete of the same object, which Release relies on reaching the C
			// heap's double-free check (Compiler.md 6.4, "Target CPU")
			outText.Append("attributes #2 = { noinline }\n\n");
			if (!mGlobalExprs.IsEmpty)
			{
				String gl = scope .();
				for (let g in mGlobalExprs)
					gl.AppendF("{}!{}", gl.IsEmpty ? "" : ", ", g);
				let gn = AddMeta(scope $"!{{{gl}}}");
				Meta[CU].Replace(", splitDebugInlining", scope $", globals: !{gn}, splitDebugInlining");
			}
			outText.Append("!llvm.dbg.cu = !{!0}\n");
			// the debug formats: "Dwarf Version" asks for DWARF, "CodeView" for CodeView (COFF only);
			// with both flags LLVM writes both (docs/Compiler.md 7, "Debug formats")
			let codeView = E.Options.CodeView && !E.Options.SysV;
			String flags = scope .();
			if (E.Options.Dwarf || !codeView)
				flags.AppendF("!{}, ", AddMeta("!{i32 7, !\"Dwarf Version\", i32 4}"));
			if (codeView)
				flags.AppendF("!{}, ", AddMeta("!{i32 2, !\"CodeView\", i32 1}"));
			flags.AppendF("!{}, ", AddMeta("!{i32 2, !\"Debug Info Version\", i32 3}"));
			flags.AppendF("!{}", AddMeta("!{i32 7, !\"uwtable\", i32 2}"));
			outText.AppendF("!llvm.module.flags = !{{{}}}\n", flags);
			for (let m in Meta)
				outText.AppendF("!{} = {}\n", @m.Index, m);
			return true;
		}

		// ---------------------------------------------------------------- metadata

		public int32 AddMeta(StringView text)
		{
			Meta.Add(new .(text));
			return (int32)Meta.Count - 1;
		}

		public int32 FileMeta(StringView unitName)
		{
			if (mFiles.TryGetValueAlt(unitName, let id))
				return id;
			String dir = scope .(E.Options.ListingDir);
			dir.Replace('\\', '/');
			let nid = AddMeta(scope $"!DIFile(filename: \"{unitName}.lst\", directory: \"{dir}\")");
			mFiles[new .(unitName)] = nid;
			return nid;
		}

		public int32 SubroutineType => mSubroutineType;

		/// A DWARF type for a variable whose Sheet spells its type differently from the IR's
		/// canonical text: `int64` / `uint64` / `isize` / `usize` of an `int` / `uint` get a typedef of
		/// that name (the same base type), so the debugger tells `int64` from `int`.
		public int32 DIType(IRType t, String spelling)
		{
			if (spelling == null || spelling == t.Text || t.Kind != .Int)
				return DIType(t);
			switch (spelling)
			{
			case "int64", "uint64", "isize", "usize":
			default: return DIType(t);
			}
			String key = scope $"={spelling}";
			if (mDITypes.TryGetValueAlt(key, let id))
				return id;
			let canon = DIType(t);
			// the canonical one is a typedef of the base type: reuse that base
			let line = Meta[canon];
			let at = line.IndexOf("baseType: !");
			String baseRef = scope .();
			if (at >= 0)
			{
				var rest = line.Substring(at + 10);
				let end = rest.IndexOf(')');
				baseRef.Append((end >= 0) ? rest.Substring(0, end) : rest);
			}
			else
				baseRef.AppendF("!{}", canon);
			let nid = AddMeta(scope $"!DIDerivedType(tag: DW_TAG_typedef, name: \"{spelling}\", baseType: {baseRef})");
			mDITypes[new .(key)] = nid;
			return nid;
		}

		/// A DWARF type for an IR type (basic types, pointers, structures with members).
		public int32 DIType(IRType t)
		{
			if (mDITypes.TryGetValueAlt(t.Text, let id))
				return id;
			int32 nid;
			switch (t.Kind)
			{
			case .Void:
				nid = AddMeta("!DIBasicType(name: \"void\", size: 8, encoding: DW_ATE_unsigned)");
			// Basic types: the C type of that size and encoding (lldb builds its own type from the size
			// and encoding and shows the C spelling, so `int` and `int64` both came out as
			// `long long`), behind a typedef with the Treadle name, which lldb shows as is.
			case .Bool:
				nid = AddMeta("!DIBasicType(name: \"bool\", size: 8, encoding: DW_ATE_boolean)");
			case .Int:
				StringView c;
				switch (t.Bits)
				{
				case 8: c = t.Signed ? "signed char" : "unsigned char";
				case 16: c = t.Signed ? "short" : "unsigned short";
				case 32: c = t.Signed ? "int" : "unsigned int";
				default: c = t.Signed ? "long long" : "unsigned long long";
				}
				let b = AddMeta(scope $"!DIBasicType(name: \"{c}\", size: {t.Bits}, encoding: {(t.Signed ? "DW_ATE_signed" : "DW_ATE_unsigned")})");
				nid = AddMeta(scope $"!DIDerivedType(tag: DW_TAG_typedef, name: \"{t.Text}\", baseType: !{b})");
			case .Float:
				nid = AddMeta(scope $"!DIBasicType(name: \"{(t.Bits == 32) ? "float" : "double"}\", size: {t.Bits}, encoding: DW_ATE_float)");
			case .Char8:
				// `char` (a char8* reads as a C string), shown as char8
				let b = AddMeta("!DIBasicType(name: \"char\", size: 8, encoding: DW_ATE_signed_char)");
				nid = AddMeta(scope $"!DIDerivedType(tag: DW_TAG_typedef, name: \"char8\", baseType: !{b})");
			case .Char32:
				let b = AddMeta("!DIBasicType(name: \"char32_t\", size: 32, encoding: DW_ATE_UTF)");
				nid = AddMeta(scope $"!DIDerivedType(tag: DW_TAG_typedef, name: \"char32\", baseType: !{b})");
			case .Pointer, .Ref:
				nid = AddMeta("");
				mDITypes[new .(t.Text)] = nid;
				String baseType = scope .("null");
				if (!t.Elem.IsVoid)
				{
					let inner = DIType(t.Elem);
					baseType.Set(scope $"!{inner}");
				}
				StringView tag = (t.Kind == .Ref) ? "DW_TAG_reference_type" : "DW_TAG_pointer_type";
				Meta[nid].Set(scope $"!DIDerivedType(tag: {tag}, baseType: {baseType}, size: 64)");
				return nid;
			case .StringView:
				// { char8* Ptr, int Length }: the debugger's summary reads Length bytes at Ptr
				let comp = AddMeta("");
				mDITypes[new .(t.Text)] = comp;
				let mp = AddMeta(scope $"!DIDerivedType(tag: DW_TAG_member, name: \"Ptr\", scope: !{comp}, baseType: !{DIType(P.T("char8*"))}, size: 64)");
				let ml = AddMeta(scope $"!DIDerivedType(tag: DW_TAG_member, name: \"Length\", scope: !{comp}, baseType: !{DIType(P.T("int"))}, size: 64, offset: 64)");
				let el = AddMeta(scope $"!{{!{mp}, !{ml}}}");
				Meta[comp].Set(scope $"distinct !DICompositeType(tag: DW_TAG_structure_type, name: \"StringView\", size: 128, elements: !{el})");
				return comp;
			case .FnPtr:
				// a pointer to a subroutine type: lldb prints the symbol the pointer points at
				let sub = AddMeta("!DISubroutineType(types: !{null})");
				nid = AddMeta(scope $"!DIDerivedType(tag: DW_TAG_pointer_type, baseType: !{sub}, size: 64)");
			case .Array:
				// a reference to `{ vtable, length, elements[] }` (the elements an array of unknown
				// bound: `frame variable a->elements[2]` reads one)
				let comp = AddMeta("");
				nid = AddMeta(scope $"!DIDerivedType(tag: DW_TAG_pointer_type, baseType: !{comp}, size: 64)");
				mDITypes[new .(t.Text)] = nid;
				let et = DIType(t.Elem);
				let sr = AddMeta("!DISubrange(count: -1)");
				let arr = AddMeta(scope $"!DICompositeType(tag: DW_TAG_array_type, baseType: !{et}, elements: !{{!{sr}}})");
				let data = L.ArrayDataOffset(t.Elem);
				String elems = scope .();
				elems.AppendF("!{}", Member(comp, "vtable", P.T("void*"), 0));
				elems.AppendF(", !{}", Member(comp, "length", P.T("int"), 8));
				elems.AppendF(", !{}", AddMeta(scope $"!DIDerivedType(tag: DW_TAG_member, name: \"elements\", scope: !{comp}, baseType: !{arr}, offset: {data * 8})"));
				let el = AddMeta(scope $"!{{{elems}}}");
				Meta[comp].Set(scope $"distinct !DICompositeType(tag: DW_TAG_structure_type, name: \"{t.Text}\", size: {data * 8}, elements: !{el})");
				return nid;
			case .Vector:
				// an array type with DIFlagVector: lldb shows (1, 2, 3, 4)
				nid = VectorDIType(t); // EmitVector.bf
			case .FixedArray:
				let et = DIType(t.Elem);
				let sr = AddMeta(scope $"!DISubrange(count: {t.Count})");
				nid = AddMeta(scope $"!DICompositeType(tag: DW_TAG_array_type, baseType: !{et}, size: {L.Size(t) * 8}, elements: !{{!{sr}}})");
			case .Delegate:
				// a reference to the delegate object `{ vtable, target, fn }`; fn a function pointer, so
				// lldb names the function it calls
				let comp = AddMeta("");
				nid = AddMeta(scope $"!DIDerivedType(tag: DW_TAG_pointer_type, baseType: !{comp}, size: 64)");
				mDITypes[new .(t.Text)] = nid;
				let sub = AddMeta("!DISubroutineType(types: !{null})");
				let fnp = AddMeta(scope $"!DIDerivedType(tag: DW_TAG_pointer_type, baseType: !{sub}, size: 64)");
				String elems = scope .();
				elems.AppendF("!{}", Member(comp, "vtable", P.T("void*"), 0));
				elems.AppendF(", !{}", Member(comp, "target", P.T("void*"), 8));
				elems.AppendF(", !{}", AddMeta(scope $"!DIDerivedType(tag: DW_TAG_member, name: \"fn\", scope: !{comp}, baseType: !{fnp}, size: 64, offset: 128)"));
				let el = AddMeta(scope $"!{{{elems}}}");
				Meta[comp].Set(scope $"distinct !DICompositeType(tag: DW_TAG_structure_type, name: \"{t.Text}\", size: 192, elements: !{el})");
				return nid;
			case .Tuple:
				// a structure of item0, item1, ...
				let comp = AddMeta("");
				mDITypes[new .(t.Text)] = comp;
				List<int64> offs = scope .();
				L.Members(t.Items, false, offs, var size, ?);
				String elems = scope .();
				for (let it in t.Items)
				{
					if (!elems.IsEmpty)
						elems.Append(", ");
					elems.AppendF("!{}", Member(comp, scope $"item{@it.Index}", it, offs[@it.Index]));
				}
				let el = AddMeta(scope $"!{{{elems}}}");
				Meta[comp].Set(scope $"distinct !DICompositeType(tag: DW_TAG_structure_type, name: \"{t.Text}\", size: {size * 8}, elements: !{el})");
				return comp;
			case .Nullable:
				// `{ T value, bool hasValue }`, hasValue listed first
				let comp = AddMeta("");
				mDITypes[new .(t.Text)] = comp;
				List<IRType> m = scope .() { t.Elem, P.T("bool") };
				List<int64> offs = scope .();
				L.Members(m, false, offs, var size, ?);
				let hv = Member(comp, "hasValue", P.T("bool"), offs[1]);
				let vv = Member(comp, "value", t.Elem, 0);
				let el = AddMeta(scope $"!{{!{hv}, !{vv}}}");
				Meta[comp].Set(scope $"distinct !DICompositeType(tag: DW_TAG_structure_type, name: \"{t.Text}\", size: {size * 8}, elements: !{el})");
				return comp;
			case .Named:
				let d = L.Decl(t);
				if (d == null || d.Kind == .Interface)
				{
					nid = AddMeta(scope $"!DIDerivedType(tag: DW_TAG_pointer_type, name: \"{t.Text}\", baseType: null, size: 64)");
					break;
				}
				if (d.Kind == .Enum && !d.IsPayloadEnum)
				{
					// an enumeration over the tag type: lldb shows the case name
					let tag = d.TagType ?? P.T("int32");
					let bt = DIType(tag);
					String en = scope .();
					for (let c in d.Cases)
					{
						if (!en.IsEmpty)
							en.Append(", ");
						en.AppendF("!{}", AddMeta(scope $"!DIEnumerator(name: \"{c.Name}\", value: {c.Value}{(tag.Signed ? "" : ", isUnsigned: true")})"));
					}
					let el = AddMeta(scope $"!{{{en}}}");
					nid = AddMeta(scope $"distinct !DICompositeType(tag: DW_TAG_enumeration_type, name: \"{t.Text}\", baseType: !{bt}, size: {L.Size(tag) * 8}, elements: !{el})");
					break;
				}
				if (d.Kind == .Enum)
					return PayloadEnumType(t, d);
				// the structure (a class value is a pointer to it)
				let comp = AddMeta("");
				let ptr = (d.Kind == .Class) ? AddMeta(scope $"!DIDerivedType(tag: DW_TAG_pointer_type, baseType: !{comp}, size: 64)") : comp;
				mDITypes[new .(t.Text)] = ptr;
				L.DeclLayout(d, var size, ?, null);
				String elems = scope .();
				if (d.Kind != .Enum)
				{
					List<IRField> fields = scope .();
					if (d.Kind == .Class)
						L.ClassFields(d, null, fields);
					else
						fields.AddRange(d.Fields);
					if (d.Kind == .Class)
					{
						let vp = AddMeta(scope $"!DIDerivedType(tag: DW_TAG_member, name: \"vtable\", scope: !{comp}, baseType: !{DIType(P.T("void*"))}, size: 64)");
						elems.AppendF("!{}", vp);
					}
					for (let f in fields)
					{
						L.FieldIndex(d, f.Name, ?, var off, ?);
						let ft = DIType(f.Type);
						let m = AddMeta(scope $"!DIDerivedType(tag: DW_TAG_member, name: \"{f.Name}\", scope: !{comp}, baseType: !{ft}, size: {L.Size(f.Type) * 8}, offset: {off * 8})");
						if (!elems.IsEmpty)
							elems.Append(", ");
						elems.AppendF("!{}", m);
					}
				}
				let el = AddMeta(scope $"!{{{elems}}}");
				Meta[comp].Set(scope $"distinct !DICompositeType(tag: DW_TAG_structure_type, name: \"{t.Text}\", size: {size * 8}, elements: !{el})");
				return ptr;
			default:
				nid = AddMeta(scope $"distinct !DICompositeType(tag: DW_TAG_structure_type, name: \"{t.Text}\", size: {L.Size(t) * 8}, elements: !{{}})");
			}
			mDITypes[new .(t.Text)] = nid;
			return nid;
		}

		/// A member of a DWARF structure: `name` of type `t` at byte `offset`.
		int32 Member(int32 scopeId, StringView name, IRType t, int64 offset)
		{
			let ft = DIType(t);
			return AddMeta(scope $"!DIDerivedType(tag: DW_TAG_member, name: \"{name}\", scope: !{scopeId}, baseType: !{ft}, size: {L.Size(t) * 8}, offset: {offset * 8})");
		}

		/// A payload enum: `{ tag, payload }`, the tag an enumeration of the case names, the payload a
		/// union with a member per case that carries one (the payload itself for one value, else a
		/// structure of item0, item1, ...), so lldb shows `tag = Some` and `payload.Some = 5`.
		int32 PayloadEnumType(IRType t, IRTypeDecl d)
		{
			let comp = AddMeta("");
			mDITypes[new .(t.Text)] = comp;
			L.PayloadArea(d, var unit, var count);
			let size = L.Size(t);
			let payOff = (unit <= 4) ? 4 : unit;
			// the tag enumeration
			let i32 = DIType(P.T("int32"));
			String en = scope .();
			for (let c in d.Cases)
			{
				if (!en.IsEmpty)
					en.Append(", ");
				en.AppendF("!{}", AddMeta(scope $"!DIEnumerator(name: \"{c.Name}\", value: {c.Value})"));
			}
			let enl = AddMeta(scope $"!{{{en}}}");
			let tagType = AddMeta(scope $"distinct !DICompositeType(tag: DW_TAG_enumeration_type, name: \"{t.Text}.Tag\", baseType: !{i32}, size: 32, elements: !{enl})");
			let tagM = AddMeta(scope $"!DIDerivedType(tag: DW_TAG_member, name: \"tag\", scope: !{comp}, baseType: !{tagType}, size: 32)");
			// the payload union
			let un = AddMeta("");
			String um = scope .();
			for (let c in d.Cases)
			{
				if (c.Payload.IsEmpty)
					continue;
				int32 ct;
				int64 csize;
				if (c.Payload.Count == 1)
				{
					ct = DIType(c.Payload[0]);
					csize = L.Size(c.Payload[0]);
				}
				else
				{
					ct = AddMeta("");
					List<int64> offs = scope .();
					L.Members(c.Payload, false, offs, out csize, ?);
					String ce = scope .();
					for (let pt in c.Payload)
					{
						if (!ce.IsEmpty)
							ce.Append(", ");
						ce.AppendF("!{}", Member(ct, scope $"item{@pt.Index}", pt, offs[@pt.Index]));
					}
					let cel = AddMeta(scope $"!{{{ce}}}");
					Meta[ct].Set(scope $"distinct !DICompositeType(tag: DW_TAG_structure_type, name: \"{t.Text}.{c.Name}\", size: {csize * 8}, elements: !{cel})");
				}
				if (!um.IsEmpty)
					um.Append(", ");
				um.AppendF("!{}", AddMeta(scope $"!DIDerivedType(tag: DW_TAG_member, name: \"{c.Name}\", scope: !{un}, baseType: !{ct}, size: {csize * 8})"));
			}
			let unl = AddMeta(scope $"!{{{um}}}");
			Meta[un].Set(scope $"distinct !DICompositeType(tag: DW_TAG_union_type, name: \"{t.Text}.Payload\", size: {unit * count * 8}, elements: !{unl})");
			let payM = AddMeta(scope $"!DIDerivedType(tag: DW_TAG_member, name: \"payload\", scope: !{comp}, baseType: !{un}, size: {unit * count * 8}, offset: {payOff * 8})");
			let el = AddMeta(scope $"!{{!{tagM}, !{payM}}}");
			Meta[comp].Set(scope $"distinct !DICompositeType(tag: DW_TAG_structure_type, name: \"{t.Text}\", size: {size * 8}, elements: !{el})");
			return comp;
		}

		// ---------------------------------------------------------------- module pieces

		void EmitTypeDefinitions()
		{
			mTypes.Append("%rt.TypeInfo = type { i32, i32, i64, i32, ptr, ptr, i32, i32, ptr, ptr }\n");
			mTypes.Append("%rt.Site = type { ptr, ptr }\n");
			mTypes.Append("%rt.Iface = type { i32, i32, ptr }\n");
			mTypes.Append("%rt.Field = type { ptr, ptr, i64 }\n");
			for (let d in P.Decls)
			{
				String body = scope .();
				L.DeclBody(d, body);
				if (body.IsEmpty)
					continue;
				Layout.StructName(d.Name, mTypes);
				mTypes.AppendF(" = type {}\n", body);
				if (d.IsPayloadEnum)
					for (let c in d.Cases)
					{
						String cb = scope .();
						L.CaseBody(c, cb);
						Layout.StructName(scope $"{d.Name}.{c.Name}", mTypes);
						mTypes.AppendF(" = type {}\n", cb);
					}
			}
		}

		void RuntimeDeclarations()
		{
			// The allocation entry points (Compiler.md 6, "Allocation attributes"): a new block is
			// `noalias` (no other pointer reaches it, so LLVM keeps two objects' fields apart), its size
			// is the `allocsize` argument, and rt_alloc / rt_alloc_dbg never return null (out of memory
			// ends the program); an allocator's Alloc may, so rt_alloc_with is not `nonnull`.
			mDecls.Append("declare noalias nonnull ptr @rt_alloc(i64, i64) nounwind allocsize(0)\n");
			mDecls.Append("declare void @rt_free(ptr) nounwind\n");
			mDecls.Append("declare noalias nonnull ptr @rt_alloc_dbg(i64, i64, ptr) nounwind allocsize(0)\n");
			mDecls.Append("declare void @rt_free_dbg(ptr, ptr) nounwind\n");
			mDecls.Append("declare noalias ptr @rt_alloc_with(ptr, i64, i64) nounwind allocsize(1)\n");
			mDecls.Append("declare void @rt_free_with(ptr, ptr) nounwind\n");
			mDecls.Append("declare ptr @rt_itable(ptr, i32)\n");
			mDecls.Append("declare ptr @rt_dyncast(ptr, ptr)\n");
			mDecls.Append("declare void @rt_abstract_call()\n");
			mDecls.Append("declare void @rt_fatal(i32, ptr, ptr) #1\n");
			mDecls.Append("declare void @rt_null(ptr) #1\n");
			mDecls.Append("declare void @rt_bounds(ptr, i64, i64) #1\n");
			mDecls.Append("declare void @rt_span_range(ptr, i64, i64, i64) #1\n");
			mDecls.Append("declare void @rt_freed(ptr) #1\n");
			mDecls.Append("declare void @rt_start(i32, ptr)\n");
			mDecls.Append("declare i32 @rt_exit(i32)\n");
			if (P.Kind == .Windowed)
				mDecls.Append("declare void @rt_windowed()\n");
			if (P.Kind == .Library)
				mDecls.Append("declare void @rt_lib_start()\ndeclare i32 @rt_lib_exit()\n");
			mDecls.Append("declare void @rt_console_write(ptr, i64)\n");
			mDecls.Append("declare void @rt_console_write_line(ptr, i64)\n");
			mDecls.Append("declare void @rt_console_error_write(ptr, i64)\n");
			mDecls.Append("declare i32 @rt_memcmp(ptr, ptr, i64)\n");
			mDecls.Append("declare void @rt_local_array_length(ptr, i64) #1\n");
			mDecls.Append("declare ptr @rt_args_make(ptr, ptr, i64, i64, ptr)\n");
			mDecls.Append("declare void @rt_args_free(ptr)\n");
			mDecls.Append("@rt_poison_vtable = external global [258 x ptr]\n");
			mDecls.Append("declare void @llvm.lifetime.start.p0(ptr)\n");
			mDecls.Append("declare void @llvm.lifetime.end.p0(ptr)\n");
			mDecls.Append("declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)\n");
			mDecls.Append("declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)\n");
		}

		// ---------------------------------------------------------------- TBAA

		// Type-based alias metadata (Release only; Compiler.md 6, "Alias metadata"). One root; under it
		// "omnipotent char" (which may alias anything) and "vtable pointer"; under char one scalar node
		// per LLVM access type (i1, i16, i32, i64, i128, float, double, ptr; i8 is char itself, so byte
		// buffers alias everything as in C). A class or struct gets a struct node: its fields at their
		// offsets (a class: its base class's node at offset 0 first, then its own fields), each a scalar
		// node, a struct field's struct node, or char for any other aggregate.
		int32 mTbaaRoot = -1;
		int32 mTbaaChar = -1;
		int32 mTbaaVTable = -1;
		Dictionary<String, int32> mTbaaScalars = new .() ~ DeleteDictionaryAndKeys!(_);
		Dictionary<IRTypeDecl, int32> mTbaaStructs = new .() ~ delete _;
		Dictionary<String, int32> mTbaaTags = new .() ~ DeleteDictionaryAndKeys!(_);

		/// Whether loads and stores carry `!tbaa` (an optimised config; at -O0 it buys nothing).
		public bool Tbaa => Opt;

		void TbaaRoots()
		{
			if (mTbaaRoot >= 0)
				return;
			mTbaaRoot = AddMeta("!{!\"Treadle TBAA\"}");
			mTbaaChar = AddMeta(scope $"!{{!\"omnipotent char\", !{mTbaaRoot}, i64 0}}");
			mTbaaVTable = AddMeta(scope $"!{{!\"vtable pointer\", !{mTbaaRoot}, i64 0}}");
		}

		/// The scalar type node of an LLVM access type; -1 when it has none (aggregates).
		int32 TbaaScalar(StringView ll)
		{
			TbaaRoots();
			switch (ll)
			{
			case "i8": return mTbaaChar;
			case "i1", "i16", "i32", "i64", "i128", "float", "double", "ptr":
			default: return -1;
			}
			if (mTbaaScalars.TryGetValueAlt(ll, let id))
				return id;
			let nid = AddMeta(scope $"!{{!\"{ll}\", !{mTbaaChar}, i64 0}}");
			mTbaaScalars[new .(ll)] = nid;
			return nid;
		}

		/// The node a field of type `t` has inside its struct node.
		int32 TbaaMember(IRType t)
		{
			if (t.IsStruct)
			{
				let s = TbaaStruct(L.Decl(t));
				return (s >= 0) ? s : mTbaaChar;
			}
			if (IsAggregate(t))
				return mTbaaChar;
			let n = TbaaScalar(L.LL(t));
			return (n >= 0) ? n : mTbaaChar;
		}

		/// The struct node of a class or struct; -1 when it has no fields (a node with no members
		/// would read as a root of its own).
		int32 TbaaStruct(IRTypeDecl d)
		{
			if (d == null || (d.Kind != .Class && d.Kind != .Struct))
				return -1;
			if (mTbaaStructs.TryGetValue(d, let known))
				return known;
			TbaaRoots();
			mTbaaStructs[d] = -1; // a struct cannot contain itself by value
			String members = scope .();
			if (d.Kind == .Class && d.Base != null)
			{
				let b = TbaaStruct(d.Base);
				if (b >= 0)
					members.AppendF(", !{}, i64 0", b);
			}
			List<int64> offs = scope .();
			L.DeclLayout(d, ?, ?, offs);
			let first = offs.Count - d.Fields.Count;
			for (let f in d.Fields)
				members.AppendF(", !{}, i64 {}", TbaaMember(f.Type), offs[first + @f.Index]);
			if (members.IsEmpty)
				return -1;
			String name = scope .();
			MetaString(d.Name, name);
			let id = AddMeta(scope $"!{{!\"{name}\"{members}}}");
			mTbaaStructs[d] = id;
			return id;
		}

		int32 TbaaTag(int32 baseNode, int32 access, int64 offset)
		{
			String key = scope $"{baseNode} {access} {offset}";
			if (mTbaaTags.TryGetValueAlt(key, let id))
				return id;
			let nid = AddMeta(scope $"!{{!{baseNode}, !{access}, i64 {offset}}}");
			mTbaaTags[new .(key)] = nid;
			return nid;
		}

		/// The access tag of a field of a class (`!{class node, scalar, offset}`: struct-path, so
		/// fields of unrelated classes do not alias) or of a struct reached through a pointer (the
		/// scalar type only: a struct pointer may have been cast from other memory); -1 for none.
		public int32 TbaaFieldTag(IRTypeDecl d, bool isClass, IRType fieldType, int64 offset)
		{
			if (!Tbaa || IsAggregate(fieldType))
				return -1;
			let access = TbaaScalar(L.LL(fieldType));
			if (access < 0)
				return -1;
			if (isClass)
			{
				let s = TbaaStruct(d);
				if (s >= 0)
					return TbaaTag(s, access, offset);
			}
			return TbaaTag(access, access, 0);
		}

		/// The tag of a scalar access of this type (array elements, array lengths); -1 for none.
		public int32 TbaaScalarTag(IRType t)
		{
			if (!Tbaa || IsAggregate(t))
				return -1;
			let access = TbaaScalar(L.LL(t));
			return (access < 0) ? -1 : TbaaTag(access, access, 0);
		}

		/// `, !tbaa !N` for a load or store of an object's vtable pointer ("" in Debug).
		public void VTableTbaa(String outText)
		{
			if (!Tbaa)
				return;
			TbaaRoots();
			outText.AppendF(", !tbaa !{}", TbaaTag(mTbaaVTable, mTbaaVTable, 0));
		}

		/// A metadata string's text: `"`, `\` and control characters as `\XX`.
		public static void MetaString(StringView text, String outText)
		{
			for (let c in text.RawChars)
			{
				let b = (uint8)c;
				if (b < 0x20 || c == '"' || c == '\\')
					outText.AppendF("\\{:X2}", b);
				else
					outText.Append(c);
			}
		}

		/// Declares an LLVM intrinsic once ("declare double @llvm.sqrt.f64(double)").
		public void NeedIntrinsic(StringView decl)
		{
			if (mIntrinsics.ContainsAlt(decl))
				return;
			mIntrinsics.Add(new .(decl));
			mDecls.AppendF("{}\n", decl);
		}

		/// A private string constant (zero-terminated); returns its symbol.
		public void Str(StringView text, String outSym)
		{
			if (mStrings.TryGetValueAlt(text, let sym))
			{
				outSym.Append(sym);
				return;
			}
			String name = new .();
			name.AppendF("@.str.{}", mStrCount++);
			mGlobals.AppendF("{} = private unnamed_addr constant [{} x i8] c\"", name, text.Length + 1);
			for (let c in text.RawChars)
			{
				let b = (uint8)c;
				if (b < 0x20 || b >= 0x7F || c == '"' || c == '\\')
					mGlobals.AppendF("\\{:X2}", b);
				else
					mGlobals.Append(c);
			}
			mGlobals.Append("\\00\", align 1\n");
			mStrings[new .(text)] = name;
			outSym.Append(name);
		}

		/// The site constant for a node of a function (null when the op has no node and no function).
		public void Site(StringView whereText, StringView node, String outSym)
		{
			String key = scope $"{whereText}\x01{node}";
			if (mSites.TryGetValueAlt(key, let sym))
			{
				outSym.Append(sym);
				return;
			}
			String w = scope .();
			Str(whereText, w);
			String n = scope .();
			Str(node.IsEmpty ? "?" : node, n);
			String name = new .();
			name.AppendF("@.site.{}", mSites.Count);
			mGlobals.AppendF("{} = private unnamed_addr constant %rt.Site {{ ptr {}, ptr {} }}, align 8\n", name, w, n);
			mSites[new .(key)] = name;
			outSym.Append(name);
		}

		// ---------------------------------------------------------------- symbols

		public void FnSym(IRFunction f, String outSym)
		{
			outSym.Append('@');
			String s = scope .();
			M.Function(f, s);
			Quoted(s, outSym);
		}

		public static void Quoted(StringView sym, String outText)
		{
			bool plain = true;
			for (let c in sym.RawChars)
				if (!(c.IsLetterOrDigit || c == '_' || c == '.' || c == '$'))
					plain = false;
			if (plain)
				outText.Append(sym);
			else
				outText.AppendF("\"{}\"", sym);
		}

		/// Whether a Treadle function returns a value of this type through a hidden `sret` pointer (its
		/// first parameter, before `this`) instead of in registers (Compiler.md 6, "Returning
		/// aggregates"): an aggregate over 16 bytes or of more than two scalars. Two doubles, a
		/// StringView or an `int?` still come back in two registers; three doubles would take the
		/// third through x87, and C returns such a struct through memory too.
		public bool SretReturn(IRType t)
		{
			if (t == null || t.IsVoid || !IsAggregate(t))
				return false;
			return L.Size(t) > 16 || ScalarCount(t) > 2;
		}

		/// The scalars an aggregate is made of (a payload enum: its tag and payload units).
		int ScalarCount(IRType t)
		{
			switch (t.Kind)
			{
			case .StringView: return 2;
			case .Nullable: return ScalarCount(t.Elem) + 1;
			case .FixedArray: return (int)t.Count * ScalarCount(t.Elem);
			case .Tuple:
				int n = 0;
				for (let it in t.Items)
					n += ScalarCount(it);
				return n;
			case .Named:
				let d = L.Decl(t);
				if (d != null && d.Kind == .Struct)
				{
					int n = 0;
					for (let f in d.Fields)
						n += ScalarCount(f.Type);
					return Math.Max(n, 1);
				}
				if (d != null && d.IsPayloadEnum)
				{
					L.PayloadArea(d, ?, var count);
					return 1 + (int)count;
				}
				return 1;
			default: return 1;
			}
		}

		/// The hidden result parameter of a function returning `t` through memory.
		public void SretParam(IRType t, String outText)
		{
			outText.AppendF("ptr noalias sret({}) align {}", L.LL(t), L.Align(t));
		}

		/// The LLVM result type of a Treadle function: `void` when it returns through `sret`.
		public StringView RetLL(IRType t) => SretReturn(t) ? "void" : L.LL(t);

		/// The LLVM parameter list of a Treadle function (the sret pointer, then this, first).
		public void ParamTypes(IRFunction f, String outText)
		{
			if (SretReturn(f.Ret))
				SretParam(f.Ret, outText);
			if (f.HasThis)
				outText.Append(outText.IsEmpty ? "ptr" : ", ptr");
			for (let t in f.ParamTypes)
			{
				if (!outText.IsEmpty)
					outText.Append(", ");
				outText.Append(L.LL(t));
			}
		}

		/// Makes a function callable from this unit: defined here, queued (shared), or declared.
		public void UseFunction(IRFunction f)
		{
			if (f.IsImport)
			{
				DeclareImport(f);
				return;
			}
			if (f.IsShared && f.HasBody)
			{
				if (mFnQueued.Add(f))
					mFnQueue.Add(f);
				return;
			}
			if (f.Unit == Unit && f.HasBody)
				return; // defined by Run
			String sym = scope .();
			FnSym(f, sym);
			if (mDeclared.ContainsAlt(sym))
				return;
			mDeclared.Add(new .(sym));
			String ps = scope .();
			ParamTypes(f, ps);
			mDecls.AppendF("declare {} {}({})\n", RetLL(f.Ret), sym, ps);
		}

		/// The C ABI shape of a value: `Direct` (a scalar as it is), `Coerce` (an aggregate passed as
		/// other register types: win64 one integer of its 1/2/4/8 bytes; System V one or two
		/// eightbytes, `CoercePieces`), `Indirect` (win64: a pointer to a copy; System V: `byval`
		/// memory for a parameter; both: an `sret` pointer for a result).
		public enum CAbi { Direct, Coerce, Indirect }

		public bool SysV => E.Options.SysV;

		/// The linker-collected tables the runtime walks at start (treadle_rt.c, "start / exit"): COFF
		/// grouped sections (`$m` between the runtime's `$a` and `$z` markers), or ELF sections with C
		/// identifier names, bounded by the linker's `__start_` / `__stop_` symbols.
		public StringView TypeInfoSection => SysV ? "treadle_ti" : ".tti$m";
		public StringView StaticCtorSection => SysV ? "treadle_sct" : ".tsct$m";

		/// The ABI of a result, or of a parameter on its own (`CAbiList` adds System V's register
		/// count for a whole parameter list).
		public CAbi AbiOf(IRType t)
		{
			if (t.IsVector)
				return VectorAbi(t); // EmitVector.bf: direct, or one double for an 8-byte vector on System V
			if (t.IsVoid || t.IsInteger || t.IsFloat || t.Kind == .Bool || t.IsPointerLike || (t.IsEnum && !t.IsPayloadEnum))
				return .Direct;
			let size = L.Size(t);
			if (!SysV)
			{
				if (size == 1 || size == 2 || size == 4 || size == 8)
					return .Coerce;
				return .Indirect;
			}
			if (size == 0 || size > 16)
				return .Indirect;
			List<String> pieces = scope .();
			defer { ClearAndDeleteItems!(pieces); }
			return SysVClassify(t, pieces) ? .Coerce : .Indirect;
		}

		/// The parameters' ABI for a C call or declaration (`types` in call order; `sretResult`: the
		/// result goes through a hidden pointer). System V passes an aggregate in memory when its
		/// eightbytes do not all fit the integer (6) and SSE (8) registers that are left.
		public void CAbiList(List<IRType> types, bool sretResult, List<CAbi> outAbi)
		{
			int intLeft = sretResult ? 5 : 6;
			int sseLeft = 8;
			for (let t in types)
			{
				var abi = AbiOf(t);
				if (t.IsVector && VectorInMemory(t))
					abi = .Indirect; // System V: a 32- or 64-byte vector argument without AVX / AVX-512 (EmitVector.bf)
				if (SysV)
				{
					if (abi == .Direct)
					{
						if (t.IsFloat || t.IsVector)
							sseLeft--;
						else
							intLeft -= (L.Size(t) > 8) ? 2 : 1;
					}
					else if (abi == .Coerce)
					{
						List<String> pieces = scope .();
						defer { ClearAndDeleteItems!(pieces); }
						SysVClassify(t, pieces);
						int ni = 0;
						int ns = 0;
						for (let p in pieces)
						{
							if (p.StartsWith('i'))
								ni++;
							else
								ns++;
						}
						if (ni <= intLeft && ns <= sseLeft)
						{
							intLeft -= ni;
							sseLeft -= ns;
						}
						else
							abi = .Indirect;
					}
				}
				outAbi.Add(abi);
			}
		}

		/// System V x86-64: the LLVM types of an aggregate's eightbytes (`i64` / `iN` for an INTEGER
		/// eightbyte, `double`, `float` or `<2 x float>` for an SSE one), as clang coerces it. False
		/// when it goes in memory (larger than 16 bytes, or a field that is not naturally aligned).
		public bool SysVClassify(IRType t, List<String> outPieces)
		{
			let size = (int)L.Size(t);
			if (size == 0 || size > 16)
				return false;
			// per eightbyte: 0 = no data, 1 = SSE (floats only), 2 = INTEGER
			int[2] cls = default;
			// per eightbyte: the float leaves (32 or 64 bits) when it is SSE
			int[2] floatBits = default;
			int[2] floatCount = default;
			if (!SysVLeaves(t, 0, ref cls, ref floatBits, ref floatCount))
				return false;
			let n = (size + 7) / 8;
			for (int i < n)
			{
				let rest = Math.Min(8, size - i * 8);
				if (cls[i] == 1)
				{
					if (floatBits[i] == 64)
						outPieces.Add(new .("double"));
					else if (floatCount[i] >= 2 || rest > 4)
						outPieces.Add(new .("<2 x float>"));
					else
						outPieces.Add(new .("float"));
				}
				else
					outPieces.Add(new $"i{rest * 8}");
			}
			return true;
		}

		bool SysVLeaves(IRType t, int64 offset, ref int[2] cls, ref int[2] floatBits, ref int[2] floatCount)
		{
			let size = L.Size(t);
			if (size == 0)
				return true;
			if (offset % Math.Max(L.Align(t), 1) != 0)
				return false; // unaligned (a packed record): memory
			void Mark(int64 at, int64 bytes, bool isFloat, int bits, ref int[2] c, ref int[2] fb, ref int[2] fc)
			{
				let first = (int)(at / 8);
				let last = (int)((at + Math.Max(bytes, 1) - 1) / 8);
				for (int e = first; e <= last && e < 2; e++)
				{
					if (isFloat && c[e] != 2)
					{
						c[e] = 1;
						fb[e] = Math.Max(fb[e], bits);
						fc[e]++;
					}
					else
						c[e] = 2;
				}
			}
			switch (t.Kind)
			{
			case .Vector:
				// a vector is SSE class, whatever its lanes (clang: an 8-byte vector is one double)
				Mark(offset, size, true, 64, ref cls, ref floatBits, ref floatCount);
			case .Float:
				Mark(offset, size, true, t.Bits, ref cls, ref floatBits, ref floatCount);
			case .FixedArray:
				let es = L.Size(t.Elem);
				for (int64 i < t.Count)
					if (!SysVLeaves(t.Elem, offset + i * es, ref cls, ref floatBits, ref floatCount))
						return false;
			case .Nullable, .Tuple:
				List<IRType> m = scope .();
				if (t.Kind == .Nullable)
				{
					m.Add(t.Elem);
					m.Add(P.T("bool"));
				}
				else
					m.AddRange(t.Items);
				List<int64> offs = scope .();
				L.Members(m, false, offs, ?, ?);
				for (let mt in m)
					if (!SysVLeaves(mt, offset + offs[@mt.Index], ref cls, ref floatBits, ref floatCount))
						return false;
			case .Named:
				let d = L.Decl(t);
				if (d != null && d.Kind == .Struct)
				{
					List<IRType> m = scope .();
					L.DeclMembers(d, m);
					List<int64> offs = scope .();
					L.Members(m, d.Packed, offs, ?, ?);
					for (let mt in m)
						if (!SysVLeaves(mt, offset + offs[@mt.Index], ref cls, ref floatBits, ref floatCount))
							return false;
				}
				else
					Mark(offset, size, false, 0, ref cls, ref floatBits, ref floatCount);
			default:
				Mark(offset, size, false, 0, ref cls, ref floatBits, ref floatCount);
			}
			return true;
		}

		/// The coerced LLVM type of a `Coerce` value: win64 `iN`; System V the single eightbyte, or
		/// `{ a, b }` for two.
		public void CoerceLL(IRType t, String outLL)
		{
			if (!SysV)
			{
				outLL.AppendF("i{}", L.Size(t) * 8);
				return;
			}
			List<String> pieces = scope .();
			defer { ClearAndDeleteItems!(pieces); }
			SysVClassify(t, pieces);
			if (pieces.Count == 1)
				outLL.Append(pieces[0]);
			else
				outLL.AppendF("{{ {}, {} }}", pieces[0], pieces[1]);
		}

		/// The parameter types a `Coerce` parameter is passed as (win64: one; System V: one per
		/// eightbyte, as clang flattens them).
		public void CoerceParams(IRType t, List<String> outTypes)
		{
			if (!SysV)
			{
				outTypes.Add(new $"i{L.Size(t) * 8}");
				return;
			}
			SysVClassify(t, outTypes);
		}

		/// The text of an `Indirect` parameter's type in a declaration or call: win64 `ptr` (a copy
		/// the caller made), System V `ptr byval(T) align A` (the callee's own copy in memory).
		public void IndirectParam(IRType t, String outText)
		{
			if (SysV)
				outText.AppendF("ptr byval({}) align {}", L.LL(t), IndirectAlign(t));
			else
				outText.Append("ptr");
		}

		public void DeclareImport(IRFunction f)
		{
			String sym = scope .();
			FnSym(f, sym);
			if (mDeclared.ContainsAlt(sym))
				return;
			mDeclared.Add(new .(sym));
			String ps = scope .();
			String ret = scope .();
			let retAbi = AbiOf(f.Ret);
			switch (retAbi)
			{
			case .Direct: ret.Append(L.LL(f.Ret));
			case .Coerce: CoerceLL(f.Ret, ret);
			case .Indirect: ret.Append("void"); ps.AppendF("ptr sret({})", L.LL(f.Ret));
			}
			List<CAbi> abis = scope .();
			CAbiList(f.ParamTypes, retAbi == .Indirect, abis);
			for (let t in f.ParamTypes)
			{
				if (!ps.IsEmpty)
					ps.Append(", ");
				switch (abis[@t.Index])
				{
				case .Direct: ps.Append(L.LL(t));
				case .Coerce:
					List<String> pieces = scope .();
					defer { ClearAndDeleteItems!(pieces); }
					CoerceParams(t, pieces);
					for (let p in pieces)
					{
						if (@p.Index > 0)
							ps.Append(", ");
						ps.Append(p);
					}
				case .Indirect: IndirectParam(t, ps);
				}
			}
			if (f.Variadic)
				ps.Append(ps.IsEmpty ? "..." : ", ...");
			mDecls.AppendF("declare {} {}({})\n", ret, sym, ps);
		}

		/// The vtable of a class (or array / box type); makes sure it exists in this module.
		public void VTableSym(IRType t, String outSym)
		{
			NeedTypeInfo(t);
			String s = scope .();
			M.VTable(t, s);
			outSym.Append('@');
			Quoted(s, outSym);
		}

		public void TypeInfoSym(IRType t, String outSym)
		{
			NeedTypeInfo(t);
			String s = scope .();
			M.TypeInfo(t, s);
			outSym.Append('@');
			Quoted(s, outSym);
		}

		public void CompleteDtorSym(IRTypeDecl d, String outSym)
		{
			NeedTypeInfo(d.Type);
			String s = scope .();
			M.CompleteDtor(d, s);
			outSym.Append('@');
			Quoted(s, outSym);
		}

		/// The complete destructor of an array type whose elements need destruction (defined
		/// linkonce_odr with the array's type data, its vtable's destructor slot).
		public void ArrayDtorSym(IRType arrayType, String outSym)
		{
			NeedTypeInfo(arrayType);
			String s = scope .();
			M.ArrayDtor(arrayType, s);
			outSym.Append('@');
			Quoted(s, outSym);
		}

		Dictionary<IRTypeDecl, bool> mNeedsDtor = new .() ~ delete _;

		/// True when destroying a value of this type runs code: a struct with a destructor Sheet,
		/// an owned field, or a field (or fixed array element) that needs destruction.
		public bool NeedsDtor(IRType t)
		{
			if (t.Kind == .FixedArray)
				return NeedsDtor(t.Elem);
			if (!t.IsStruct)
				return false;
			let d = t.Decl;
			if (mNeedsDtor.TryGetValue(d, let known))
				return known;
			mNeedsDtor[d] = false; // a struct cannot contain itself by value
			bool needs = d.Dtor != null;
			for (let f in d.Fields)
				if ((f.Owned && f.Type.IsObjectRef) || NeedsDtor(f.Type))
					needs = true;
			mNeedsDtor[d] = needs;
			return needs;
		}

		HashSet<IRTypeDecl> mBases ~ delete _;

		/// True when some class of the program derives from this one (the IR program holds every
		/// class, so a class without one is effectively final: its virtual destructor can be called
		/// directly).
		public bool HasSubclass(IRTypeDecl d)
		{
			if (mBases == null)
			{
				mBases = new .();
				for (let other in P.Decls)
					if (other.Base != null)
						mBases.Add(other.Base);
			}
			return d == null || mBases.Contains(d);
		}

		/// True when destroying an object of this class runs no code: no destructor Sheet in its chain
		/// and no owned object or destructible struct field.
		public bool TrivialDtor(IRTypeDecl d)
		{
			for (var c = d; c != null; c = c.Base)
			{
				if (c.Dtor != null && c.Dtor.HasBody)
					return false;
				for (let f in c.Fields)
					if ((f.Owned && f.Type.IsObjectRef) || NeedsDtor(f.Type))
						return false;
			}
			return true;
		}

		/// The thunk a delegate bound to a static function calls: `fn(target, args)` -> `f(args)`.
		public void DelegateThunkSym(IRFunction f, String outSym)
		{
			UseFunction(f);
			String fs = scope .();
			FnSym(f, fs);
			String s = scope .();
			M.DelegateThunk(f, s);
			outSym.Append('@');
			Quoted(s, outSym);
			if (mDefined.ContainsAlt(outSym))
				return;
			mDefined.Add(new .(outSym));
			Comdat(outSym);
			String ps = scope .("ptr %target");
			String args = scope .();
			// a result through memory: the delegate's sret pointer goes on to the function
			if (SretReturn(f.Ret))
			{
				ps.Clear();
				SretParam(f.Ret, ps);
				ps.Append(" %sret, ptr %target");
				SretParam(f.Ret, args);
				args.Append(" %sret");
			}
			for (let t in f.ParamTypes)
			{
				ps.AppendF(", {} %a{}", L.LL(t), @t.Index);
				if (!args.IsEmpty)
					args.Append(", ");
				args.AppendF("{} %a{}", L.LL(t), @t.Index);
			}
			let ret = L.LL(f.Ret);
			if (f.Ret.IsVoid || SretReturn(f.Ret))
				mFuncs.AppendF("define linkonce_odr void {0}({1}) #0 comdat(${2}) {{\nentry:\n  call void {3}({4})\n  ret void\n}}\n\n", outSym, ps, StringView(outSym, 1), fs, args);
			else
				mFuncs.AppendF("define linkonce_odr {0} {1}({2}) #0 comdat(${3}) {{\nentry:\n  %r = call {0} {4}({5})\n  ret {0} %r\n}}\n\n", ret, outSym, ps, StringView(outSym, 1), fs, args);
		}

		/// Text that destroys the value of type `t` at `ptr` (a struct's complete destructor, or a
		/// loop over a fixed array's elements); for the bodies of complete destructors.
		void DestroyValue(String body, StringView ptr, IRType t, ref int tmp)
		{
			if (t.Kind == .FixedArray)
			{
				// pre -> loop header (phi) -> body (nested blocks) -> latch -> header | end
				let n = ++tmp;
				body.AppendF("  br label %dpre{0}\ndpre{0}:\n  br label %dl{0}\ndl{0}:\n", n);
				body.AppendF("  %di{0} = phi i64 [ 0, %dpre{0} ], [ %dn{0}, %dlatch{0} ]\n", n);
				body.AppendF("  %dc{0} = icmp ult i64 %di{0}, {1}\n  br i1 %dc{0}, label %dbody{0}, label %dend{0}\ndbody{0}:\n", n, t.Count);
				body.AppendF("  %de{0} = getelementptr inbounds {1}, ptr {2}, i64 0, i64 %di{0}\n", n, L.LL(t), ptr);
				DestroyValue(body, scope $"%de{n}", t.Elem, ref tmp);
				body.AppendF("  br label %dlatch{0}\ndlatch{0}:\n  %dn{0} = add i64 %di{0}, 1\n  br label %dl{0}\ndend{0}:\n", n);
				return;
			}
			if (!NeedsDtor(t))
				return;
			String d1 = scope .();
			CompleteDtorSym(t.Decl, d1);
			body.AppendF("  call void {}(ptr {})\n", d1, ptr);
		}

		/// True when a type's runtime data (type info, vtable, complete destructor) is defined by this
		/// module: its own types strongly, shared ones (generic instances, core types, arrays, boxes)
		/// as linkonce_odr.
		bool DefinesTypeData(IRType t, out bool shared)
		{
			shared = true;
			if (t.Kind != .Named || IsBox(t))
				return true;
			let d = L.Decl(t);
			if (d == null)
				return false;
			if (d.IsShared)
				return true;
			shared = false;
			return d.Unit == Unit;
		}

		public void NeedTypeInfo(IRType t)
		{
			if (mTypeQueued.ContainsAlt(t.Text))
				return;
			mTypeQueued.Add(new .(t.Text));
			mTypeQueue.Add(t);
		}

		/// Emits whatever was queued until nothing new is needed.
		void Drain()
		{
			int fi = 0;
			int ti = 0;
			while (fi < mFnQueue.Count || ti < mTypeQueue.Count)
			{
				while (fi < mFnQueue.Count)
					DefineFunction(mFnQueue[fi++]);
				while (ti < mTypeQueue.Count)
					EmitTypeData(mTypeQueue[ti++]);
			}
		}

		/// Declares the COMDAT of a linkonce_odr symbol ("@name" or "@\"name\"").
		public void Comdat(StringView sym)
		{
			mTypes.AppendF("${} = comdat any\n", sym.Substring(1));
		}

		void ComdatTail(bool shared, String sym, String outText)
		{
			if (shared)
				outText.AppendF(", comdat(${})", sym.Substring(1));
		}

		/// Type info, vtable, interface tables and the complete destructor of a type.
		void EmitTypeData(IRType t)
		{
			String tiSym = scope .();
			M.TypeInfo(t, tiSym);
			tiSym.Insert(0, '@');
			String vtSym = scope .();
			M.VTable(t, vtSym);
			vtSym.Insert(0, '@');
			let d = (t.Kind == .Named) ? L.Decl(t) : null;
			let isClassLike = (d != null && d.Kind == .Class) || t.Kind == .Array || IsBox(t);
			if (!DefinesTypeData(t, var shared))
			{
				// defined by its own unit
				mDecls.AppendF("{} = external constant %rt.TypeInfo\n", tiSym);
				if (d != null && d.Kind == .Struct && NeedsDtor(t))
				{
					String dt = scope .();
					M.CompleteDtor(d, dt);
					mDecls.AppendF("declare void @{}(ptr)\n", dt);
				}
				if (isClassLike)
				{
					mDecls.AppendF("{} = external constant [{} x ptr]\n", vtSym, VSlotCount(t) + 2);
					String dt = scope .();
					M.CompleteDtor(d, dt);
					mDecls.AppendF("declare void @{}(ptr)\n", dt);
				}
				return;
			}
			String name = scope .();
			String flags = scope .();
			int64 size = 8;
			int64 align = 8;
			String baseTi = scope .("null");
			String ifaces = scope .("null");
			String fields = scope .("null");
			int ifaceCount = 0;
			int fieldCount = 0;
			int32 flagBits = 0;
			if (t.Kind == .Array)
			{
				name.AppendF("{}", t.Text);
				flagBits = 16;
				size = L.ArrayDataOffset(t.Elem);
				align = Math.Max(8, L.Align(t.Elem));
			}
			else if (IsBox(t))
			{
				let inner = t.Name.Segs.Back.Args[0];
				name.AppendF("Box<{}>", inner.Text);
				flagBits = 32;
				List<IRType> m = scope .();
				m.Add(P.T("void*"));
				m.Add(inner);
				L.Members(m, false, null, out size, out align);
			}
			else if (d != null)
			{
				name.Set(d.Name);
				switch (d.Kind)
				{
				case .Class: flagBits = 1;
				case .Struct: flagBits = 2;
				case .Enum: flagBits = 4;
				case .Interface: flagBits = 8;
				}
				if (d.Abstract)
					flagBits |= 64;
				L.DeclLayout(d, out size, out align, null);
				if (d.Kind == .Class && d.Base != null)
				{
					baseTi.Clear();
					TypeInfoSym(d.Base.Type, baseTi);
				}
				// interface tables
				if (d.Kind == .Class && !d.ITables.IsEmpty)
				{
					String entries = scope .();
					for (let it in d.ITables)
					{
						String itSym = scope $"{tiSym}.it{@it.Index}";
						if (shared)
							Comdat(itSym);
						String body = scope .();
						for (let f in it.Impls)
						{
							if (!body.IsEmpty)
								body.Append(", ");
							String s = scope .();
							SlotTarget(f, s);
							body.AppendF("ptr {}", s);
						}
						String g = scope .();
						g.AppendF("{} = {}constant [{} x ptr] [{}]", itSym, shared ? "linkonce_odr " : "internal ", it.Impls.Count, body);
						ComdatTail(shared, itSym, g);
						mGlobals.AppendF("{}, align 8\n", g);
						if (!entries.IsEmpty)
							entries.Append(", ");
						entries.AppendF("%rt.Iface {{ i32 {}, i32 0, ptr {} }}", M.TypeId(it.Iface.Type), itSym);
					}
					String arr = scope $"{tiSym}.ifaces";
					String g = scope .();
					g.AppendF("{} = {}constant [{} x %rt.Iface] [{}]", arr, shared ? "linkonce_odr " : "internal ", d.ITables.Count, entries);
					if (shared)
						Comdat(arr);
					ComdatTail(shared, arr, g);
					mGlobals.AppendF("{}, align 8\n", g);
					ifaces.Set(arr);
					ifaceCount = d.ITables.Count;
				}
				// field infos
				List<IRField> fl = scope .();
				if (d.Kind == .Class)
					L.ClassFields(d, null, fl);
				else if (d.Kind == .Struct)
					fl.AddRange(d.Fields);
				if (!fl.IsEmpty)
				{
					String entries = scope .();
					for (let f in fl)
					{
						L.FieldIndex(d, f.Name, ?, var off, ?);
						String fn = scope .();
						Str(f.Name, fn);
						String tn = scope .();
						Str(f.Type.Text, tn);
						if (!entries.IsEmpty)
							entries.Append(", ");
						entries.AppendF("%rt.Field {{ ptr {}, ptr {}, i64 {} }}", fn, tn, off);
					}
					String arr = scope $"{tiSym}.fields";
					String g = scope .();
					g.AppendF("{} = {}constant [{} x %rt.Field] [{}]", arr, shared ? "linkonce_odr " : "internal ", fl.Count, entries);
					if (shared)
						Comdat(arr);
					ComdatTail(shared, arr, g);
					mGlobals.AppendF("{}, align 8\n", g);
					fields.Set(arr);
					fieldCount = fl.Count;
				}
			}
			flags.AppendF("{}", flagBits);
			// name string (_ZTS)
			String tsSym = scope .();
			M.TypeNameString(t, tsSym);
			tsSym.Insert(0, '@');
			{
				String g = scope .();
				g.AppendF("{} = {}constant [{} x i8] c\"{}\\00\"", tsSym, shared ? "linkonce_odr " : "", name.Length + 1, name);
				if (shared)
					Comdat(tsSym);
				ComdatTail(shared, tsSym, g);
				mGlobals.AppendF("{}, align 1\n", g);
			}
			{
				String g = scope .();
				g.AppendF("{} = {}constant %rt.TypeInfo {{ i32 {}, i32 {}, i64 {}, i32 {}, ptr {}, ptr {}, i32 {}, i32 {}, ptr {}, ptr {} }}",
					tiSym, shared ? "linkonce_odr " : "", M.TypeId(t), flags, size, align, tsSym, baseTi, ifaceCount, fieldCount, ifaces, fields);
				if (shared)
					Comdat(tiSym);
				ComdatTail(shared, tiSym, g);
				mGlobals.AppendF("{}, align 8\n", g);
			}
			// the registry entry (collision check at start-up)
			{
				String reg = scope $"{tiSym}.reg";
				String g = scope .();
				g.AppendF("{} = {}constant ptr {}, section \"{}\"", reg, shared ? "linkonce_odr " : "internal ", tiSym, TypeInfoSection);
				if (shared)
					Comdat(reg);
				ComdatTail(shared, reg, g);
				mGlobals.AppendF("{}, align 8\n", g);
				mUsed.Add(new .(reg));
			}
			if (!isClassLike)
			{
				// a struct's complete destructor, when destroying it runs code
				if (d != null && d.Kind == .Struct && NeedsDtor(t))
				{
					String dtSym = scope .();
					M.CompleteDtor(d, dtSym);
					dtSym.Insert(0, '@');
					EmitCompleteDtor(d, dtSym, shared);
				}
				return;
			}
			// complete destructor and vtable
			String dtSym = scope .();
			if (d != null)
			{
				M.CompleteDtor(d, dtSym);
				dtSym.Insert(0, '@');
				EmitCompleteDtor(d, dtSym, shared);
			}
			else if (t.Kind == .Array && NeedsDtor(t.Elem))
			{
				// an array of structs that need destruction: each element, first to last
				String s = scope .();
				M.ArrayDtor(t, s);
				dtSym.Append('@');
				Quoted(s, dtSym);
				EmitArrayDtor(t, dtSym);
			}
			else
			{
				// other arrays and boxes own nothing: Core.Object's
				CompleteDtorSym(P.ObjectDecl, dtSym);
			}
			String slots = scope .();
			slots.AppendF("ptr {}, ptr {}", tiSym, dtSym);
			if (d != null)
				for (let s in d.VTable)
				{
					String target = scope .();
					if (s.Impl == null || !s.Impl.HasBody)
						target.Append("@rt_abstract_call");
					else
						SlotTarget(s.Impl, target);
					slots.AppendF(", ptr {}", target);
				}
			String g = scope .();
			g.AppendF("{} = {}constant [{} x ptr] [{}]", vtSym, shared ? "linkonce_odr " : "", VSlotCount(t) + 2, slots);
			if (shared)
				Comdat(vtSym);
			ComdatTail(shared, vtSym, g);
			mGlobals.AppendF("{}, align 8\n", g);
		}

		int VSlotCount(IRType t)
		{
			let d = (t.Kind == .Named) ? L.Decl(t) : null;
			return (d != null) ? d.VTable.Count : 0;
		}

		public bool IsBox(IRType t) => t.Kind == .Named && t.Name.Segs.Count == 2 && t.Name.Segs[0].Ident == "Core" && t.Name.Segs[1].Ident == "Box" && t.Name.Segs[1].Args.Count == 1 && L.Decl(t) == null;

		/// The function pointer a table slot holds (the function made callable here).
		void SlotTarget(IRFunction f, String outSym)
		{
			if (f.Abstract || !f.HasBody)
			{
				outSym.Append("@rt_abstract_call");
				return;
			}
			UseFunction(f);
			FnSym(f, outSym);
		}

		/// The complete destructor of an array whose elements need destruction.
		void EmitArrayDtor(IRType t, StringView sym)
		{
			String key = scope $"dtor:{sym}";
			if (mDefined.ContainsAlt(key))
				return;
			mDefined.Add(new .(key));
			Comdat(sym);
			String ao = scope .();
			L.ArrayObject(t.Elem, ao);
			String body = scope .();
			body.AppendF("  %lp = getelementptr inbounds {0}, ptr %this, i32 0, i32 1\n  %len = load i64, ptr %lp, align 8\n  br label %head\nhead:\n", ao);
			body.Append("  %i = phi i64 [ 0, %entry ], [ %next, %latch ]\n  %more = icmp ult i64 %i, %len\n  br i1 %more, label %elem, label %done\nelem:\n");
			body.AppendF("  %ep = getelementptr inbounds {0}, ptr %this, i32 0, i32 2, i64 %i\n", ao);
			int tmp = 0;
			DestroyValue(body, "%ep", t.Elem, ref tmp);
			body.Append("  br label %latch\nlatch:\n  %next = add i64 %i, 1\n  br label %head\ndone:\n");
			mFuncs.AppendF("define linkonce_odr void {}(ptr %this) #0 comdat(${}) {{\nentry:\n{}  ret void\n}}\n\n", sym, sym.Substring(1), body);
		}

		/// D1: the destructor's Sheet (D2), then the fields last first (owned objects deleted,
		/// structs that need it destroyed), then (classes) the base's D1. A struct's D1 takes a
		/// pointer to the struct.
		void EmitCompleteDtor(IRTypeDecl d, StringView sym, bool shared)
		{
			String key = scope $"dtor:{sym}";
			if (mDefined.ContainsAlt(key))
				return;
			mDefined.Add(new .(key));
			String body = scope .();
			int tmp = 0;
			if (d.Dtor != null && d.Dtor.HasBody)
			{
				UseFunction(d.Dtor);
				String ds = scope .();
				FnSym(d.Dtor, ds);
				body.AppendF("  call void {}(ptr %this)\n", ds);
			}
			String whereText = scope $"{d.Name}.~this";
			for (int i = d.Fields.Count - 1; i >= 0; i--)
			{
				let f = d.Fields[i];
				if (NeedsDtor(f.Type))
				{
					L.FieldIndex(d, f.Name, var sidx, ?, ?);
					String sst = scope .();
					Layout.StructName(d.Name, sst);
					let n = ++tmp;
					body.AppendF("  %sf{0} = getelementptr inbounds {1}, ptr %this, i32 0, i32 {2}\n", n, sst, sidx);
					DestroyValue(body, scope $"%sf{n}", f.Type, ref tmp);
					continue;
				}
				if (!f.Owned || !f.Type.IsObjectRef)
					continue;
				L.FieldIndex(d, f.Name, var idx, ?, ?);
				String st = scope .();
				Layout.StructName(d.Name, st);
				let n = ++tmp;
				body.AppendF("  %fp{0} = getelementptr inbounds {1}, ptr %this, i32 0, i32 {2}\n  %fo{0} = load ptr, ptr %fp{0}, align 8\n", n, st, idx);
				body.AppendF("  %fz{0} = icmp eq ptr %fo{0}, null\n  br i1 %fz{0}, label %fdone{0}, label %fdel{0}\nfdel{0}:\n", n);
				body.AppendF("  %fvt{0} = load ptr, ptr %fo{0}, align 8\n  %fds{0} = getelementptr inbounds ptr, ptr %fvt{0}, i64 1\n  %fd{0} = load ptr, ptr %fds{0}, align 8\n  call void %fd{0}(ptr %fo{0})\n", n);
				if (Dbg)
				{
					String site = scope .();
					Site(whereText, f.Name, site);
					body.AppendF("  call void @rt_free_dbg(ptr %fo{0}, ptr {1}) #2\n", n, site);
				}
				else
					body.AppendF("  call void @rt_free(ptr %fo{0}) #2\n", n);
				body.AppendF("  br label %fdone{0}\nfdone{0}:\n", n);
			}
			if (d.Base != null)
			{
				String bs = scope .();
				CompleteDtorSym(d.Base, bs);
				body.AppendF("  call void {}(ptr %this)\n", bs);
			}
			String cd = scope .();
			if (shared)
			{
				Comdat(sym);
				cd.AppendF(" comdat(${})", sym.Substring(1));
			}
			mFuncs.AppendF("define {}void {}(ptr %this) #0{} {{\nentry:\n{}  ret void\n}}\n\n", shared ? "linkonce_odr " : "", sym, cd, body);
		}

		void DefineGlobal(IRGlobal g)
		{
			if (g.Import != null)
				return;
			String s = scope .();
			M.Global(g, s);
			String sym = scope .("@");
			Quoted(s, sym);
			if (mDefined.ContainsAlt(sym))
				return;
			mDefined.Add(new .(sym));
			String init = scope .();
			if (g.Elements != null)
			{
				// a constant array: `[T e0, T e1, ...]` (a text element is a StringView constant)
				let et = g.Type.Elem;
				init.Append('[');
				for (let e in g.Elements)
				{
					if (@e.Index > 0)
						init.Append(", ");
					if (et.IsVector)
						VectorMemConst(et, e, init, true); // EmitVector.bf: "<memory type> <constant>"
					else if (e.StartsWith('"'))
					{
						init.AppendF("{} ", L.LL(et));
						String unq = scope .();
						IRReader.Unquote(e, unq);
						ConstText(et, unq, true, init);
					}
					else
					{
						init.AppendF("{} ", L.LL(et));
						ConstText(et, e, false, init);
					}
				}
				init.Append(']');
			}
			else if (g.Init.IsEmpty)
				init.Append(g.Type.IsPointerLike ? "null" : (IsAggregate(g.Type) ? "zeroinitializer" : (g.Type.IsFloat ? "0.0" : (g.Type.Kind == .Bool ? "false" : "0"))));
			else if (!g.Type.IsVector)
				ConstText(g.Type, g.Init, false, init);
			String gll = scope .(L.LL(g.Type));
			if (g.Type.IsVector)
			{
				// a vector global holds its memory form (EmitVector.bf)
				gll.Set(L.Mem(g.Type));
				init.Clear();
				VectorMemConst(g.Type, g.Init.IsEmpty ? "zero" : g.Init, init, false);
			}
			mGlobals.AppendF("{} = {} {} {}, align {}", sym, g.Const ? "constant" : "global", gll, init, L.Align(g.Type));
			if (Dbg)
			{
				// a static field is a global variable of its qualified name (`target variable`; no
				// linkage name, which lldb would show demangled as `Game::Player::sCount`)
				let ty = DIType(g.Type);
				let file = FileMeta(Unit.Name);
				let gv = AddMeta(scope $"distinct !DIGlobalVariable(name: \"{g.Text}\", scope: !{CU}, file: !{file}, line: {Math.Max(g.Line, 1)}, type: !{ty}, isLocal: false, isDefinition: true)");
				let gve = AddMeta(scope $"!DIGlobalVariableExpression(var: !{gv}, expr: !DIExpression())");
				mGlobalExprs.Add(gve);
				mGlobals.AppendF(", !dbg !{}", gve);
			}
			mGlobals.Append('\n');
		}

		public void GlobalSym(IRGlobal g, String outSym)
		{
			String s = scope .();
			// an extern C variable (`global ... import "sym"`) is its C symbol, never defined here
			if (g.Import != null)
				s.Set(g.Import);
			else
				M.Global(g, s);
			String sym = scope .("@");
			Quoted(s, sym);
			if (g.Unit == Unit && g.Import == null)
				DefineGlobal(g);
			else if (!mDeclared.ContainsAlt(sym))
			{
				mDeclared.Add(new .(sym));
				mDecls.AppendF("{} = external global {}\n", sym, L.LL(g.Type));
			}
			outSym.Append(sym);
		}

		public bool IsAggregate(IRType t)
		{
			switch (t.Kind)
			{
			case .StringView, .Tuple, .Nullable, .FixedArray: return true;
			case .Named:
				let d = L.Decl(t);
				return d != null && (d.Kind == .Struct || d.IsPayloadEnum);
			default: return false;
			}
		}

		/// The LLVM constant for a literal of a type (strings: a StringView constant or a char8*).
		public void ConstText(IRType t, StringView lit, bool isString, String outText)
		{
			if (isString)
			{
				String sym = scope .();
				String unq = scope .(lit);
				Str(unq, sym);
				if (t.Kind == .StringView)
					outText.AppendF("{{ ptr {}, i64 {} }}", sym, unq.Length);
				else
					outText.Append(sym);
				return;
			}
			if (t.IsVector)
			{
				VectorConstText(t, lit, outText); // EmitVector.bf
				return;
			}
			if (lit == "zero")
			{
				if (IsAggregate(t))
					outText.Append("zeroinitializer");
				else if (t.IsPointerLike)
					outText.Append("null");
				else if (t.IsFloat)
					outText.Append("0.0");
				else if (t.Kind == .Bool)
					outText.Append("false");
				else
					outText.Append("0");
				return;
			}
			if (lit == "null")
			{
				outText.Append(IsAggregate(t) ? "zeroinitializer" : "null");
				return;
			}
			switch (t.Kind)
			{
			case .Bool:
				outText.Append((lit == "true" || lit == "1") ? "true" : "false");
			case .Float:
				double v = 0;
				// `1.25f` / `1.25F` (float), `2.5d` / `2.5D` (double) and the plain form read the same: the
				// op's type decides the width, the suffix only says how the front end classified it.
				StringView num = lit;
				if (num.Length > 1 && !num.StartsWith("0x") && !num.StartsWith("0X") && (num.EndsWith('f') || num.EndsWith('F') || num.EndsWith('d') || num.EndsWith('D')))
					num.RemoveFromEnd(1);
				if (double.Parse(num) case .Ok(let d))
					v = d;
				else
					Error(scope $"'{lit}' is not a number");
				if (t.Bits == 32)
					v = (double)(float)v;
				uint64 bits = *(uint64*)&v;
				outText.AppendF("0x{:X16}", bits);
			case .Named:
				let d = L.Decl(t);
				if (d != null && d.Kind == .Enum && !d.IsPayloadEnum)
				{
					let c = d.FindCase(lit);
					if (c != null)
					{
						outText.AppendF("{}", c.Value);
						return;
					}
				}
				outText.Append(lit);
			case .Char8, .Char32:
				if (lit.Length == 3 && lit[0] == '\'' && lit[2] == '\'')
					outText.AppendF("{}", (int)(uint8)lit[1]);
				else
					outText.Append(lit);
			default:
				if (lit.StartsWith("0x") || lit.StartsWith("0X"))
				{
					if (int64.Parse(lit.Substring(2), .AllowHexSpecifier) case .Ok(let hv))
						outText.AppendF("{}", hv);
					else
						outText.Append(lit);
				}
				else
					outText.Append(lit);
			}
		}

		void DefineFunction(IRFunction f)
		{
			String sym = scope .();
			FnSym(f, sym);
			if (mDefined.ContainsAlt(sym))
				return;
			mDefined.Add(new .(sym));
			FunctionEmitter fe = scope .(this, f, sym);
			fe.Emit(mFuncs);
			if (f.ExportName != null && f.Unit == Unit)
				EmitExport(f, sym);
			if (f.StaticCtor && !f.IsShared)
			{
				String reg = scope $"{sym}.sct";
				mGlobals.AppendF("{} = internal constant ptr {}, section \"{}\", align 8\n", reg, sym, StaticCtorSection);
				mUsed.Add(new .(reg));
			}
		}

		/// `[Export("name")]`: a C-named function with the platform's C ABI (win64: aggregates of
		/// 1/2/4/8 bytes as integers, larger ones through a pointer to the caller's copy; System V:
		/// up to two eightbytes in registers, larger ones `byval`; both: `sret` for a result in
		/// memory) that calls the Treadle one. Exported from the exe (`dllexport`) on Windows; a
		/// global symbol on Linux.
		void EmitExport(IRFunction f, StringView sym)
		{
			String ps = scope .();
			String args = scope .();
			String pre = scope .();
			let retAbi = AbiOf(f.Ret);
			let retLL = L.LL(f.Ret);
			let linkage = SysV ? "" : "dllexport ";
			if (retAbi == .Indirect)
				ps.AppendF("ptr sret({}) %sret", retLL);
			List<IRType> cTypes = scope .();
			if (f.HasThis)
				cTypes.Add(P.T("void*"));
			cTypes.AddRange(f.ParamTypes);
			List<CAbi> abis = scope .();
			CAbiList(cTypes, retAbi == .Indirect, abis);
			int i = 0;
			if (f.HasThis)
			{
				if (!ps.IsEmpty)
					ps.Append(", ");
				ps.Append("ptr %a0");
				args.Append("ptr %a0");
				i++;
			}
			for (let t in f.ParamTypes)
			{
				if (!ps.IsEmpty)
					ps.Append(", ");
				if (!args.IsEmpty)
					args.Append(", ");
				let ll = L.LL(t);
				let align = L.Align(t);
				switch (abis[i])
				{
				case .Direct:
					ps.AppendF("{} %a{}", ll, i);
					args.AppendF("{} %a{}", ll, i);
				case .Coerce:
					// the pieces go into a temporary of the coerced type, read back as the value
					String co = scope .();
					CoerceLL(t, co);
					List<String> pieces = scope .();
					defer { ClearAndDeleteItems!(pieces); }
					CoerceParams(t, pieces);
					let ma = Math.Max(align, 8);
					pre.AppendF("  %m{0} = alloca {1}, align {2}\n", i, co, ma);
					for (let p in pieces)
					{
						if (@p.Index > 0)
							ps.Append(", ");
						ps.AppendF("{} %a{}.{}", p, i, @p.Index);
						if (pieces.Count == 1)
							pre.AppendF("  store {0} %a{1}.0, ptr %m{1}, align {2}\n", p, i, ma);
						else
							pre.AppendF("  %m{0}.{1} = getelementptr inbounds {2}, ptr %m{0}, i32 0, i32 {1}\n  store {3} %a{0}.{1}, ptr %m{0}.{1}\n", i, @p.Index, co, p);
					}
					pre.AppendF("  %v{0} = load {1}, ptr %m{0}, align {2}\n", i, ll, align);
					args.AppendF("{} %v{}", ll, i);
				case .Indirect:
					IndirectParam(t, ps);
					ps.AppendF(" %a{}", i);
					pre.AppendF("  %v{0} = load {1}, ptr %a{0}, align {2}\n", i, ll, align);
					args.AppendF("{} %v{}", ll, i);
				}
				i++;
			}
			String body = scope .(pre);
			switch (retAbi)
			{
			case .Direct:
				if (f.Ret.IsVoid)
					body.AppendF("  call void {}({})\n  ret void\n", sym, args);
				else
					body.AppendF("  %r = call {0} {1}({2})\n  ret {0} %r\n", retLL, sym, args);
				mFuncs.AppendF("define {}{} @{}({}) #0 {{\nentry:\n{}}}\n\n", linkage, f.Ret.IsVoid ? "void" : retLL, f.ExportName, ps, body);
			case .Coerce:
				String co = scope .();
				CoerceLL(f.Ret, co);
				let ra = Math.Max(L.Align(f.Ret), 8);
				ExportCall(f, sym, args, body);
				body.AppendF("  %rm = alloca {2}, align {1}\n  store {0} %r, ptr %rm, align {3}\n  %rc = load {2}, ptr %rm, align {1}\n  ret {2} %rc\n", retLL, ra, co, L.Align(f.Ret));
				mFuncs.AppendF("define {}{} @{}({}) #0 {{\nentry:\n{}}}\n\n", linkage, co, f.ExportName, ps, body);
			case .Indirect:
				if (SretReturn(f.Ret))
				{
					// the Treadle function writes straight into the C caller's result
					String sp = scope .();
					SretParam(f.Ret, sp);
					body.AppendF("  call void {}({} %sret{}{})\n  ret void\n", sym, sp, args.IsEmpty ? "" : ", ", args);
				}
				else
				{
					ExportCall(f, sym, args, body);
					body.AppendF("  store {0} %r, ptr %sret, align {1}\n  ret void\n", retLL, L.Align(f.Ret));
				}
				mFuncs.AppendF("define {}void @{}({}) #0 {{\nentry:\n{}}}\n\n", linkage, f.ExportName, ps, body);
			}
		}

		/// `%r = ` the Treadle function's result, in an export's body (through an sret slot when it
		/// returns through memory).
		void ExportCall(IRFunction f, StringView sym, StringView args, String body)
		{
			let retLL = L.LL(f.Ret);
			if (!SretReturn(f.Ret))
			{
				body.AppendF("  %r = call {} {}({})\n", retLL, sym, args);
				return;
			}
			String sp = scope .();
			SretParam(f.Ret, sp);
			body.AppendF("  %rs = alloca {0}, align {1}\n  call void {2}({3} %rs{4}{5})\n  %r = load {0}, ptr %rs, align {1}\n", retLL, L.Align(f.Ret), sym, sp, args.IsEmpty ? "" : ", ", args);
		}

		/// The function `main` calls: the entry, or (the front end's parameterless shim for
		/// `Main(Core.String[])`) the static `Main(Core.String[])` of the entry's owner, so the
		/// program gets its arguments. `outArgs`: it takes the String[].
		IRFunction MainTarget(out bool outArgs)
		{
			let e = P.Entry;
			outArgs = e.ParamTypes.Count == 1;
			if (outArgs || e.Owner == null)
				return e;
			String owner = scope .();
			e.Owner.ToString(owner);
			for (let f in P.Functions)
			{
				if (f == e || !f.Static || f.Name != "Main" || !f.HasBody || f.Owner == null || f.ParamTypes.Count != 1 || !IRLinker.IsStringArray(f.ParamTypes[0]))
					continue;
				String o = scope .();
				f.Owner.ToString(o);
				if (o == owner && (f.Ret == e.Ret))
				{
					outArgs = true;
					return f;
				}
			}
			return e;
		}

		/// `main`: starts the runtime, builds `args` (a Core.String[] of the UTF-8 command line,
		/// made and freed by the runtime) when Main takes them, runs Main, runs the exit checks.
		void EmitMain()
		{
			let e = MainTarget(let passArgs);
			UseFunction(e);
			String sym = scope .();
			FnSym(e, sym);
			String pre = scope .();
			String post = scope .();
			String argList = scope .();
			if (passArgs)
			{
				let strDecl = P.FindDecl("Core.String");
				let ctor = P.FindFunction("Core.String.this(StringView)");
				if (strDecl == null || ctor == null || !ctor.HasBody)
				{
					Error(scope $"{e.Key} takes Core.String[] but the program has no Core.String with a this(StringView) constructor");
					return;
				}
				UseFunction(ctor);
				String cs = scope .();
				FnSym(ctor, cs);
				mFuncs.AppendF("define internal void @treadle.args.init(ptr %o, ptr %p, i64 %n) #0 {{\nentry:\n  %sv0 = insertvalue {{ ptr, i64 }} poison, ptr %p, 0\n  %sv = insertvalue {{ ptr, i64 }} %sv0, i64 %n, 1\n  call void {}(ptr %o, {{ ptr, i64 }} %sv)\n  ret void\n}}\n\n", cs);
				String avt = scope .();
				VTableSym(e.ParamTypes[0], avt);
				String svt = scope .();
				VTableSym(strDecl.Type, svt);
				L.DeclLayout(strDecl, var size, var align, null);
				pre.AppendF("  %args = call ptr @rt_args_make(ptr {}, ptr {}, i64 {}, i64 {}, ptr @treadle.args.init)\n", avt, svt, size, align);
				post.Append("  call void @rt_args_free(ptr %args)\n");
				argList.Append("ptr %args");
			}
			String call = scope .(pre);
			if (e.Ret.IsVoid)
				call.AppendF("  call void {}({})\n  %code = add i32 0, 0\n", sym, argList);
			else if (e.Ret.Bits == 32)
				call.AppendF("  %code = call i32 {}({})\n", sym, argList);
			else if (e.Ret.Bits > 32)
				call.AppendF("  %r = call {0} {1}({2})\n  %code = trunc {0} %r to i32\n", L.LL(e.Ret), sym, argList);
			else
				call.AppendF("  %r = call {0} {1}({2})\n  %code = {3} {0} %r to i32\n", L.LL(e.Ret), sym, argList, e.Ret.Signed ? "sext" : "zext");
			call.Append(post);
			// a windowed program first finds where its Console output goes (rt_windowed)
			StringView windowed = (P.Kind == .Windowed) ? "  call void @rt_windowed()\n" : "";
			mFuncs.AppendF("define i32 @main(i32 %argc, ptr %argv) #0 {{\nentry:\n{}  call void @rt_start(i32 %argc, ptr %argv)\n{}  %exit = call i32 @rt_exit(i32 %code)\n  ret i32 %exit\n}}\n\n", windowed, call);
		}

		/// A library (kind library) has no `main`: `treadle_init` runs the static constructors
		/// (rt_lib_start) and `treadle_shutdown` the Debug leak report (rt_lib_exit, the number of
		/// leaks), exported next to the `[Export]` functions (Compiler.md 6.3).
		void EmitLibraryStart()
		{
			let linkage = SysV ? "" : "dllexport ";
			mFuncs.AppendF("define {}void @treadle_init() #0 {{\nentry:\n  call void @rt_lib_start()\n  ret void\n}}\n\n", linkage);
			mFuncs.AppendF("define {}i32 @treadle_shutdown() #0 {{\nentry:\n  %r = call i32 @rt_lib_exit()\n  ret i32 %r\n}}\n\n", linkage);
		}
	}
}
