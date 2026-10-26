using System;
using System.Collections;
using Treadle.Model;
using Treadle.Graph;
using Treadle.Document;

namespace Treadle.Compiler
{
	// GPU compute, experimental (docs/GPU-Compute.md): `[Kernel]` functions, the Gpu.Dispatch and
	// Kernel.RunCpu calls that run one, and the rules a kernel's Sheet obeys. Diagnostics T2340-T2349:
	//   T2340  the kernel's own header: static, not generic, returns nothing, inputs by value of the
	//          kinds a GPU takes, at most 8 inputs, no input named `count`, no overloads
	//   T2341  a node that allocates, frees, makes a delegate or keeps hidden static state
	//   T2342  a value of a type the GPU has no form of (objects, arrays, strings, delegates)
	//   T2343  a call the GPU cannot make (C functions, virtual or object calls, core types outside
	//          Math, Kernel, Atomic, Vector, Pointer and the core structs)
	//   T2344  a static field (the GPU has its own copy of the program's globals)
	//   T2345  recursion
	//   T2346  a Math function the GPU has no code for (transcendental functions on vectors; the
	//          ones the core does not have yet)
	//   T2347  Gpu.Dispatch / DispatchAsync / Kernel.RunCpu: no `set kernel`, a name that is no
	//          [Kernel] function, a dispatch inside a kernel, `set block` outside 1-1024
	//   T2348  Kernel.Shared: no `set type`, a type the GPU has no form of, a count not typed on the node
	// A function a kernel calls obeys the same rules (reported at the call, naming the function).

	extension MemberSym
	{
		/// `[Kernel]`: the PTX entry name of the function's GPU form (`tk_<Owner>_<Name>`); null = not a kernel.
		public String KernelEntry ~ delete _;
		/// `[Kernel]` that calls Kernel.Shared or Kernel.Barrier (itself or through a function it
		/// calls): it runs in whole blocks (Check sets it).
		public bool KernelBlocks;
	}

	extension BNode
	{
		/// A Call of Gpu.Dispatch or Kernel.RunCpu: the [Kernel] function its `set kernel` names.
		public MemberSym KernelFn;
		/// Gpu.Dispatch / Gpu.DispatchAsync (true) or Kernel.RunCpu.
		public bool KernelGpu;
		/// Gpu.DispatchAsync: the node takes a GpuStream input `stream`.
		public bool KernelAsync;
		/// `set block <n>`: the threads per block (256 when not set).
		public int32 KernelBlock;
	}

	static class KernelRules
	{
		/// The most inputs a kernel takes (the runtime's launch passes up to 8 argument addresses).
		public const int MaxParams = 8;
		/// The block size of a dispatch without `set block`, and the largest one (CUDA's limit).
		public const int32 DefaultBlock = 256;
		public const int32 MaxBlock = 1024;

		/// A core function that runs a [Kernel] function: Gpu.Dispatch, Gpu.DispatchAsync, Kernel.RunCpu.
		public static bool IsDispatch(String intrinsic) => intrinsic != null && (intrinsic == "Gpu.Dispatch" || intrinsic == "Gpu.DispatchAsync" || intrinsic == "Kernel.RunCpu");

		/// `[Kernel]` on `m` (Declare): its PTX entry name.
		public static void Mark(MemberSym m, TypeSym owner, StringView name)
		{
			String entry = scope .("tk_");
			for (let ch in scope String()..AppendF("{}_{}", owner.FullName, name).RawChars)
				entry.Append((ch.IsLetterOrDigit || ch == '_') ? ch : '_');
			String.NewOrSet!(m.KernelEntry, entry);
		}

		public static bool IsSpan(TypeTable T, KType t) => t != null && t.Kind == .Named && t.Sym == T.SpanSym && t.Args.Count == 1;

		/// A value the GPU has a form of: numbers, bools, characters, vectors, pointers, simple enums,
		/// structs and tuples of those, Span<T> of those. Objects, arrays, strings and delegates are not.
		public static bool GpuValue(TypeTable T, KType t, int depth = 0)
		{
			if (t == null || depth > 8)
				return true;
			switch (t.Kind)
			{
			case .Error, .Void, .Null, .Param, .Bool, .Int, .Float, .Char, .Vector, .Pointer: return true;
			case .Array, .Delegate, .Function: return false;
			case .Nullable, .FixedArray: return GpuValue(T, t.Element, depth + 1);
			case .Tuple:
				for (let a in t.Args)
					if (!GpuValue(T, a, depth + 1))
						return false;
				return true;
			case .Named:
				if (t.Sym == T.StringSym || t.Sym == T.StringViewSym)
					return false;
				if (t.Sym.Kind == .Enum)
					return !t.Sym.HasPayload;
				if (t.Sym.Kind != .Struct)
					return false;
				if (t.Sym == T.SpanSym)
					return t.Args.Count == 1 && !IsSpan(T, t.Args[0]) && GpuValue(T, t.Args[0], depth + 1);
				for (let a in t.Args)
					if (!GpuValue(T, a, depth + 1))
						return false;
				return true;
			default: return true;
			}
		}

		static void Err(Compilation c, SheetResult r, StringView node, StringView pin, StringView code, StringView message)
		{
			c.Diags.Add(.Error, .Check, code, r.Site, node, pin, message);
			r.HasErrors = true;
		}

		/// After the ordinary Check of a Sheet: the kernel rules when it is a [Kernel] function's body.
		public static void Check(Compilation c, SheetResult r)
		{
			let m = r.Member;
			if (m == null || m.KernelEntry == null || r.IsLambda)
				return;
			CheckHeader(c, r, m);
			HashSet<MemberSym> seen = scope .();
			seen.Add(m);
			CheckBody(c, r, r, null, seen, 0);
		}

		static void CheckHeader(Compilation c, SheetResult r, MemberSym m)
		{
			let T = c.Table;
			String why = scope .();
			if (m.Kind != .Function || !(m.Static || m.Owner.Static))
				why.Set("it is not a static function");
			else if (m.IsGeneric || m.Owner.IsGeneric)
				why.Set("it is generic (a kernel is compiled once, for the GPU)");
			else if (m.Returns != null && !m.Returns.IsVoid)
				why.Set("it returns a value (a kernel writes its results into Span inputs)");
			else if (!m.Outs.IsEmpty)
				why.Set("it has out inputs (a kernel writes its results into Span inputs)");
			else if (m.VSlot >= 0 || m.IsImport || m.ExportName != null)
				why.Set("it is virtual, imported or exported");
			else if (m.Params.Count > MaxParams)
				why.AppendF("it has {} inputs (at most {})", m.Params.Count, MaxParams);
			if (why.IsEmpty)
			{
				for (let p in m.Params)
				{
					if (p.Mode == .Ref || p.Mode == .In || p.Mode == .Out)
						why.AppendF("the input {} is ref / in / out (kernel inputs are values)", p.Name);
					else if (p.Name == "count")
						why.Set("an input is named count (the dispatch's own input: rename it)");
					else if (!GpuValue(T, p.Type))
						why.AppendF("the input {} is {} (numbers, bools, vectors, structs of them and Span<T> of them only)", p.Name, TypeTable.WithArticle(p.Type, .. scope .()));
					if (!why.IsEmpty)
						break;
				}
			}
			if (why.IsEmpty)
			{
				for (let other in m.Owner.Members)
					if (other != m && other.KernelEntry != null && other.Name == m.Name)
						why.Set("another [Kernel] function has its name (overloads share one GPU entry)");
			}
			if (!why.IsEmpty)
				Err(c, r, "", "", "T2340", scope $"[Kernel] {m.Name}: {why}");
		}

		/// The Math functions the GPU has no code for yet (the ones the core may add; the core's
		/// Sin, Cos, Tan, Asin, Acos, Atan, Atan2, Exp, Log and Pow are treadle_gpu_math.c's).
		static bool NoGpuMath(StringView name)
		{
			switch (name)
			{
			case "Sinh", "Cosh", "Tanh", "Exp2", "Log2", "Log10", "Cbrt", "Hypot", "SinCos":
				return true;
			default:
				return false;
			}
		}

		/// The transcendental Math functions: the GPU has them for float and double, not for vectors.
		static bool TranscendentalMath(StringView name)
		{
			switch (name)
			{
			case "Sin", "Cos", "Tan", "Asin", "Acos", "Atan", "Atan2", "Exp", "Log", "Pow":
				return true;
			default:
				return NoGpuMath(name);
			}
		}

		/// The rules over one Sheet: the kernel's own (`via` null) or one a kernel calls, reported at
		/// the call `via` in the kernel's Sheet `top`.
		static void Report(Compilation c, SheetResult top, BNode via, BNode n, StringView pin, StringView code, StringView what)
		{
			if (via == null)
				Err(c, top, (n != null) ? n.Key : "", pin, code, what);
			else
				Err(c, top, via.Key, "", code, scope $"{(via.Member != null) ? (StringView)via.Member.Name : "the function"} (called by the kernel): {what}");
		}

		static void CheckBody(Compilation c, SheetResult top, SheetResult r, BNode via, HashSet<MemberSym> seen, int depth)
		{
			let T = c.Table;
			for (let b in r.Nodes)
			{
				if (b.Node.Disabled)
					continue;
				switch (b.Kind)
				{
				case .Construct, .Local, .Delete, .Defer, .DeferDelete:
					Report(c, top, via, b, "", "T2341", "a kernel cannot allocate or free memory (Construct, Local, Delete, Defer)");
					continue;
				case .Lambda, .Bind, .Invoke:
					Report(c, top, via, b, "", "T2341", "a kernel cannot make or call delegates and function pointers");
					continue;
				case .Gate, .DoOnce, .DoN, .FlipFlop, .MultiGate, .GateOpen, .GateClose, .GateToggle, .ResetDoOnce, .ResetDoN, .ResetMultiGate:
					Report(c, top, via, b, "", "T2341", "a kernel cannot use the Gate family (their state is a hidden static field)");
					continue;
				case .Fatal:
					continue; // a trap on the GPU: the dispatch fails with a driver error
				default:
				}
				// the types of what the node takes and gives
				bool typeBad = false;
				for (let i in b.Ins)
				{
					if (!typeBad && !GpuValue(T, i.Type))
					{
						Report(c, top, via, b, i.Name, "T2342", scope $"{i.Label}: a kernel has no {TypeTable.Show(i.Type, .. scope .())} (objects, arrays, strings and delegates stay on the CPU)");
						typeBad = true;
					}
				}
				for (let o in b.Outs)
				{
					if (!typeBad && !GpuValue(T, o.Type))
					{
						Report(c, top, via, b, o.Name, "T2342", scope $"{o.Name}: a kernel has no {TypeTable.Show(o.Type, .. scope .())} (objects, arrays, strings and delegates stay on the CPU)");
						typeBad = true;
					}
				}
				if ((b.Kind == .Get || b.Kind == .Set) && b.Var == .StaticField && b.Member != null && !b.Member.Const)
				{
					Report(c, top, via, b, "", "T2344", scope $"{b.Member.Name} is a static field: the GPU has its own copy of the program's globals (pass the value as an input)");
					continue;
				}
				MemberSym f = null;
				if (b.Kind == .Call)
				{
					if (b.KernelFn != null)
					{
						Report(c, top, via, b, "", "T2347", "a kernel cannot dispatch a kernel");
						continue;
					}
					if (b.VecFn != .None)
					{
						// Core.Vector and Math on vectors: element-wise LLVM ops (the transcendental
						// ones have no GPU code for vectors yet)
						if (b.Member != null && b.Member.Owner.FullName == "Core.Math" && TranscendentalMath(b.Member.Name))
							Report(c, top, via, b, "", "T2346", scope $"Math.{b.Member.Name} on a vector has no GPU code yet (on float and double it has: take the lanes apart)");
						continue;
					}
					f = b.Member;
				}
				else if (b.Kind == .Index && b.Member != null)
					f = b.Member;
				else if (b.Kind == .Operator && b.OpImpl == .User)
					f = b.Member;
				else if (b.Kind == .Get && b.Var == .Property)
					f = b.Member;
				if (f == null)
					continue;
				CheckCall(c, top, via, b, f, seen, depth);
			}
		}

		static void CheckCall(Compilation c, SheetResult top, BNode via, BNode b, MemberSym f, HashSet<MemberSym> seen, int depth)
		{
			let owner = f.Owner;
			if (f.IsImport || owner.IsCImport)
			{
				Report(c, top, via, b, "", "T2343", scope $"{f.Name} is a C function: the GPU has no C library");
				return;
			}
			if (f.VSlot >= 0 || owner.Kind == .Interface)
			{
				Report(c, top, via, b, "", "T2343", scope $"{f.Name} is virtual: a kernel calls only functions it knows when it is built");
				return;
			}
			if (!f.Static && owner.Kind != .Struct && owner.Kind != .Enum && !owner.Static)
			{
				Report(c, top, via, b, "", "T2343", scope $"{owner.Name}.{f.Name} is a function of an object (objects stay on the CPU)");
				return;
			}
			if (seen.Contains(f))
			{
				Report(c, top, via, b, "", "T2345", scope $"{f.Name} calls itself (through the kernel): a kernel has no recursion");
				return;
			}
			if (owner.IsCore)
			{
				let name = owner.FullName;
				if (name == "Core.Math")
				{
					if (NoGpuMath(f.Name))
						Report(c, top, via, b, "", "T2346", scope $"Math.{f.Name} has no GPU code yet (Sin, Cos, Tan, Asin, Acos, Atan, Atan2, Exp, Log, Pow, Sqrt, Abs, Floor, Ceil, Min, Max and arithmetic do)");
					return;
				}
				if (name == "Core.Kernel" && (f.Name == "Barrier" || f.Name == "Shared") && top.Member != null)
					top.Member.KernelBlocks = true;
				if (owner.Kind == .Struct || name == "Core.Kernel" || name == "Core.Atomic" || name == "Core.Vector" || name == "Core.Pointer")
					return;
				Report(c, top, via, b, "", "T2343", scope $"{owner.Name}.{f.Name} is not available in a kernel (Math, Kernel, Atomic, Vector, Pointer and the core structs are)");
				return;
			}
			// a function of the project: the same rules over its Sheet
			if (depth > 16)
				return;
			let home = f.Extension ?? owner;
			if (home.Doc == null)
				return;
			for (let sheet in home.Doc.Sheets)
			{
				if (sheet.Role == .Lambda || sheet.Member == null || sheet.Member != f.Decl)
					continue;
				// bound now when the kernel comes first in the file (Compilation.Run finds it bound)
				var cr = c.ResultOf(sheet);
				if (cr == null)
				{
					let unit = c.FindUnit(home.Doc);
					if (unit != null)
						cr = c.BindSheet(unit, sheet);
				}
				if (cr == null)
					continue;
				seen.Add(f);
				CheckBody(c, top, cr, via ?? b, seen, depth + 1);
				seen.Remove(f);
			}
		}
	}

	extension SheetBinder
	{
		/// A Call of Kernel.Shared: its element type from `set type <T>` (the count is typed on the
		/// node; Lower checks that).
		void BindKernelShared(BNode b, MemberSym f)
		{
			if (f.Generics.IsEmpty)
				return;
			let text = b.Node.GetSetting("type");
			if (text.IsEmpty)
			{
				Err(b, "", "T2348", "Kernel.Shared: name the element type with set type <T> (float, int, a struct of numbers, ...)");
				return;
			}
			let tr = TypeRef.Parse(text);
			defer delete tr;
			let t = c.Resolve(tr, Ctx(b));
			if (t == null || t.IsError)
				return; // Resolve reported it
			if (!KernelRules.GpuValue(T, t) || KernelRules.IsSpan(T, t))
			{
				Err(b, "", "T2348", scope $"Kernel.Shared: shared memory holds numbers, bools, vectors and structs of them, not {TypeTable.WithArticle(t, .. scope .())}");
				return;
			}
			b.Map[f.Generics[0]] = t;
		}

		/// A Call of Gpu.Dispatch or Kernel.RunCpu: `set kernel <Type.Function>` names the [Kernel]
		/// function; the node takes `count` and one input per kernel input (a Span<T> input is a
		/// GpuBuffer<T> at Gpu.Dispatch).
		void BindKernelCall(BNode b, MemberSym f)
		{
			b.KernelGpu = f.Intrinsic.StartsWith("Gpu.");
			b.KernelAsync = f.Intrinsic == "Gpu.DispatchAsync";
			b.KernelBlock = KernelRules.DefaultBlock;
			let blockText = b.Node.GetSetting("block");
			if (!blockText.IsEmpty)
			{
				if ((int32.Parse(blockText) case .Ok(let n)) && n >= 1 && n <= KernelRules.MaxBlock)
					b.KernelBlock = n;
				else
					Err(b, "", "T2347", scope $"set block {blockText}: the block size is a number from 1 to {KernelRules.MaxBlock}");
			}
			let text = b.Node.GetSetting("kernel");
			if (text.IsEmpty)
			{
				Err(b, "", "T2347", scope $"{f.Owner.Name}.{f.Name} runs a [Kernel] function: name it with set kernel <Type.Function>");
				return;
			}
			let mr = MemberRef.Parse(text);
			defer delete mr;
			bool open = false;
			let owner = OwnerOf(b, mr, out open);
			List<(MemberSym m, KType inst)> cands = scope .();
			if (owner != null && !owner.IsError && owner.Kind == .Named)
				FindFunctions(owner, mr.Name, cands);
			MemberSym k = null;
			for (let cand in cands)
				if (cand.m.KernelEntry != null)
					k = cand.m;
			if (k == null)
			{
				Err(b, "", "T2347", scope $"'{text}' names no [Kernel] function");
				return;
			}
			b.KernelFn = k;
			let bufferSym = T.Find("Core.GpuBuffer");
			for (let p in k.Params)
			{
				var pt = p.Type;
				if (b.KernelGpu && KernelRules.IsSpan(T, pt) && bufferSym != null)
					pt = T.Named(bufferSym, scope KType[](pt.Args[0]));
				b.AddIn(p.Name, pt);
			}
		}
	}
}
