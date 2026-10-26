using System;
using System.Collections;
using Treadle.Backend.IR;

namespace Treadle.Backend.IR
{
	extension IRFunction
	{
		/// `kernel "<entry>"` (GPU compute, experimental; docs/GPU-Compute.md): the function is also
		/// compiled for the GPU, as the PTX entry of this name (EmitKernel.bf).
		public String KernelName ~ delete _;
	}
}

namespace Treadle.Backend.Emit
{
	// GPU compute, experimental (docs/GPU-Compute.md): the program's [Kernel] functions emitted a
	// second time, as one NVPTX module (`target triple nvptx64-nvidia-cuda`). The same FunctionEmitter
	// writes their bodies (and the bodies of every function they call: in kernel mode a call defines
	// the callee in the module instead of declaring it); the module adds
	//   * per kernel an entry `ptx_kernel void @<entry>(i64 %count, <inputs>)` that runs the kernel
	//     when the thread's global index is below `count`; a Span<T> input is two PTX parameters, a
	//     global-memory pointer (`ptr addrspace(1)`, cast to a generic one) and the count;
	//   * Core.Kernel.Index() as ctaid.x * ntid.x + tid.x (`llvm.nvvm.read.ptx.sreg.*`);
	//   * the runtime's check entry points (rt_bounds, rt_fatal, ...) as traps: a failed check stops
	//     the dispatch, and the next driver call reports it.
	// Debug info is left out (the debugger works on the CPU path: Kernel.RunCpu), as are COMDATs.

	extension UnitEmitter
	{
		/// Emitting the NVPTX module of the program's kernels (EmitKernel.bf).
		public bool KernelMode;

		public const String NvptxTriple = "nvptx64-nvidia-cuda";
		public const String NvptxDataLayout = "e-p6:32:32-i64:64-i128:128-i256:256-v16:16-v32:32-n16:32:64";

		/// Kernel mode, UseFunction: a function a kernel calls is defined in the module (true when
		/// handled).
		public bool KernelUse(IRFunction f)
		{
			if (!KernelMode)
				return false;
			if (f.IsImport)
			{
				Error(scope $"a kernel reaches the C function {f.ImportName}: the GPU has no C library");
				return true;
			}
			if (!f.HasBody)
			{
				Error(scope $"a kernel reaches {f.Key}, which has no body here");
				return true;
			}
			if (mFnQueued.Add(f))
				mFnQueue.Add(f);
			return true;
		}

		/// The CPU path's per-thread state: the index Kernel.Index() gives and the dispatch's block
		/// size, thread-locals defined by the program (linkonce_odr in every unit that uses them), so
		/// LTO sees that nothing else reaches them and keeps the chunk loop vectorisable. The chunk
		/// function sets them (Kernel.SetIndex per index, Kernel.SetBlockSize per chunk); the runtime
		/// never touches them (a Barrier keeps its fiber's index on the fiber's own stack).
		void KernelTls(StringView name)
		{
			String sym = scope $"@{name}";
			if (mDeclared.ContainsAlt(sym))
				return;
			mDeclared.Add(new .(sym));
			Comdat(sym);
			mGlobals.AppendF("{} = linkonce_odr thread_local global i64 0, comdat, align 8\n", sym);
		}

		/// The CPU form of a Core.Kernel function over the thread-locals (true when written): a load,
		/// a store or a little arithmetic, inlined into the kernel (ThinLTO in Release).
		bool KernelCpuBuiltin(IRFunction f, StringView sym)
		{
			String body = scope .();
			String ret = scope .("i64");
			String ps = scope .();
			switch (f.Key)
			{
			case "Core.Kernel.Index()":
				body.Append("  %i = load i64, ptr %ip, align 8\n  ret i64 %i\n");
			case "Core.Kernel.SetIndex(int)":
				ret.Set("void");
				ps.Set("i64 %i");
				body.Append("  store i64 %i, ptr %ip, align 8\n  ret void\n");
			case "Core.Kernel.SetBlockSize(int)":
				ret.Set("void");
				ps.Set("i64 %b");
				body.Append("  store i64 %b, ptr %bp, align 8\n  ret void\n");
			case "Core.Kernel.BlockSize()":
				body.Append("  %b = load i64, ptr %bp, align 8\n  ret i64 %b\n");
			case "Core.Kernel.BlockIndex()":
				body.Append("  %i = load i64, ptr %ip, align 8\n  %b = load i64, ptr %bp, align 8\n");
				body.Append("  %q = sdiv i64 %i, %b\n  ret i64 %q\n");
			case "Core.Kernel.ThreadInBlock()":
				body.Append("  %i = load i64, ptr %ip, align 8\n  %b = load i64, ptr %bp, align 8\n");
				body.Append("  %r = srem i64 %i, %b\n  ret i64 %r\n");
			case "Core.Kernel.Barrier()":
				// the other threads of the block (fibers on this thread) run up to it; this one's
				// index stays on its own stack meanwhile
				NeedIntrinsic("declare void @rt_kernel_barrier()");
				ret.Set("void");
				body.Append("  %i = load i64, ptr %ip, align 8\n  call void @rt_kernel_barrier()\n");
				body.Append("  store i64 %i, ptr %ip, align 8\n  ret void\n");
			default:
				return false;
			}
			KernelTls("treadle.kernel.index");
			KernelTls("treadle.kernel.block");
			// the thread-locals' addresses through llvm.threadlocal.address, which LICM hoists out of the
			// chunk loop (a plain use reloads the TLS index after every store the loop makes)
			NeedIntrinsic("declare ptr @llvm.threadlocal.address.p0(ptr)");
			body.Insert(0, "  %ip = call ptr @llvm.threadlocal.address.p0(ptr @treadle.kernel.index)\n  %bp = call ptr @llvm.threadlocal.address.p0(ptr @treadle.kernel.block)\n");
			String cd = scope .();
			if (f.IsShared)
			{
				Comdat(sym);
				cd.AppendF(" comdat(${})", StringView(sym, 1));
			}
			mFuncs.AppendF("{} {} {}({}) #0{} {{\n{}}}\n\n", f.IsShared ? "define linkonce_odr" : "define", ret, sym, ps, cd, body);
			return true;
		}

		/// The GPU form of a Core.Kernel function (kernel mode; true when written): the PTX special
		/// registers and the block barrier.
		bool KernelGpuBuiltin(IRFunction f, StringView sym)
		{
			String body = scope .();
			String ret = scope .("i64");
			switch (f.Key)
			{
			case "Core.Kernel.Index()":
				body.Append("  %t = call i32 @llvm.nvvm.read.ptx.sreg.tid.x()\n");
				body.Append("  %b = call i32 @llvm.nvvm.read.ptx.sreg.ctaid.x()\n");
				body.Append("  %d = call i32 @llvm.nvvm.read.ptx.sreg.ntid.x()\n");
				body.Append("  %t64 = zext i32 %t to i64\n  %b64 = zext i32 %b to i64\n  %d64 = zext i32 %d to i64\n");
				body.Append("  %bd = mul i64 %b64, %d64\n  %i = add i64 %bd, %t64\n  ret i64 %i\n");
			case "Core.Kernel.BlockIndex()":
				body.Append("  %b = call i32 @llvm.nvvm.read.ptx.sreg.ctaid.x()\n  %b64 = zext i32 %b to i64\n  ret i64 %b64\n");
			case "Core.Kernel.ThreadInBlock()":
				body.Append("  %t = call i32 @llvm.nvvm.read.ptx.sreg.tid.x()\n  %t64 = zext i32 %t to i64\n  ret i64 %t64\n");
			case "Core.Kernel.BlockSize()":
				body.Append("  %d = call i32 @llvm.nvvm.read.ptx.sreg.ntid.x()\n  %d64 = zext i32 %d to i64\n  ret i64 %d64\n");
			case "Core.Kernel.Barrier()":
				ret.Set("void");
				body.Append("  call void @llvm.nvvm.barrier0()\n  ret void\n");
			default:
				return false;
			}
			mFuncs.AppendF("define internal {} {}() #0 {{\n{}}}\n\n", ret, sym, body);
			return true;
		}

		/// DefineFunction: the Core.Kernel functions with a form of their own, on the GPU (kernel
		/// mode) or on the CPU (true when written).
		public bool KernelBuiltin(IRFunction f, StringView sym)
		{
			if (!f.Key.StartsWith("Core.Kernel."))
				return false;
			return KernelMode ? KernelGpuBuiltin(f, sym) : KernelCpuBuiltin(f, sym);
		}

		static bool IsSpanType(IRType t) => t.Kind == .Named && t.Text.StartsWith("Core.Span<");

		/// The entry of one kernel.
		void KernelEntry(IRFunction k)
		{
			String sym = scope .();
			FnSym(k, sym);
			String ps = scope .("i64 %count");
			String body = scope .();
			String args = scope .();
			for (let p in k.Params)
			{
				let ll = L.LL(p.Type);
				if (!args.IsEmpty)
					args.Append(", ");
				if (IsSpanType(p.Type))
				{
					ps.AppendF(", ptr addrspace(1) %{0}.p, i64 %{0}.n", p.Name);
					body.AppendF("  %{0}.g = addrspacecast ptr addrspace(1) %{0}.p to ptr\n", p.Name);
					body.AppendF("  %{0}.s0 = insertvalue {1} undef, ptr %{0}.g, 0\n", p.Name, ll);
					body.AppendF("  %{0}.s = insertvalue {1} %{0}.s0, i64 %{0}.n, 1\n", p.Name, ll);
					args.AppendF("{} %{}.s", ll, p.Name);
				}
				else
				{
					ps.AppendF(", {} %{}", ll, p.Name);
					args.AppendF("{} %{}", ll, p.Name);
				}
			}
			mFuncs.AppendF("define ptx_kernel void @{}({}) #0 {{\nentry:\n", k.KernelName, ps);
			mFuncs.Append("  %tid = call i32 @llvm.nvvm.read.ptx.sreg.tid.x()\n");
			mFuncs.Append("  %ctaid = call i32 @llvm.nvvm.read.ptx.sreg.ctaid.x()\n");
			mFuncs.Append("  %ntid = call i32 @llvm.nvvm.read.ptx.sreg.ntid.x()\n");
			mFuncs.Append("  %tid64 = zext i32 %tid to i64\n  %ctaid64 = zext i32 %ctaid to i64\n  %ntid64 = zext i32 %ntid to i64\n");
			mFuncs.Append("  %base = mul i64 %ctaid64, %ntid64\n  %index = add i64 %base, %tid64\n");
			mFuncs.Append("  %inside = icmp ult i64 %index, %count\n  br i1 %inside, label %run, label %done\nrun:\n");
			mFuncs.Append(body);
			mFuncs.AppendF("  call void {}({})\n  br label %done\ndone:\n  ret void\n}}\n\n", sym, args);
		}

		/// The NVPTX module of `kernels` (functions with KernelName) as LLVM IR text, and the host's
		/// table of its check sites (`outSites[N]` for `@.site.N`: "<where>\x01<node>\x01<the Fatal
		/// node's message, when the site is one>").
		public bool RunKernelModule(List<IRFunction> kernels, String outText, List<String> errors, List<String> outSites)
		{
			KernelMode = true;
			mErrors = errors;
			int before = errors.Count;
			CU = AddMeta("");
			let file = FileMeta(Unit.Name);
			Meta[CU].Set(scope $"distinct !DICompileUnit(language: DW_LANG_C99, file: !{file}, producer: \"Treadle\", isOptimized: true, runtimeVersion: 0, emissionKind: NoDebug)");
			mSubroutineType = AddMeta("!DISubroutineType(types: !{})");
			EmitTypeDefinitions();
			// The runtime's check and fatal entry points: the device-side error record. The first
			// failed check of the program writes {kind, site, a, b} to @treadle_gpu_error (the host
			// reads it after every wait, treadle_gpu.c) and the thread exits (PTX `exit`, not a trap:
			// a trap would make the context unusable, record included). A site is the number of the
			// `@.site.N` the CPU code would pass (StripForGpu makes each one that i32); kinds: 1 null,
			// 2 index (a index, b length), 3 span range (a start, b length), 4 deleted object, 5 a
			// Fatal node (a its code), 6 a local array's length (a), 7 an abstract call.
			mDecls.Append("declare void @llvm.trap()\n");
			mDecls.Append("declare i32 @llvm.nvvm.read.ptx.sreg.tid.x()\ndeclare i32 @llvm.nvvm.read.ptx.sreg.ctaid.x()\ndeclare i32 @llvm.nvvm.read.ptx.sreg.ntid.x()\ndeclare void @llvm.nvvm.barrier0()\n");
			mGlobals.Append("@treadle_gpu_error = addrspace(1) externally_initialized global [4 x i32] zeroinitializer, align 16\n");
			mDecls.Append("define internal void @treadle.gpu.fail(i32 %kind, ptr %s, i64 %a, i64 %b) #1 {\nentry:\n");
			mDecls.Append("  %none = icmp eq ptr %s, null\n  br i1 %none, label %record, label %site\nsite:\n  %sid = load i32, ptr %s, align 4\n  br label %record\n");
			mDecls.Append("record:\n  %id = phi i32 [ -1, %entry ], [ %sid, %site ]\n");
			mDecls.Append("  %old = cmpxchg ptr addrspace(1) @treadle_gpu_error, i32 0, i32 %kind seq_cst seq_cst, align 16\n");
			mDecls.Append("  %won = extractvalue { i32, i1 } %old, 1\n  br i1 %won, label %write, label %out\nwrite:\n");
			mDecls.Append("  %p1 = getelementptr inbounds [4 x i32], ptr addrspace(1) @treadle_gpu_error, i64 0, i64 1\n  store volatile i32 %id, ptr addrspace(1) %p1, align 4\n");
			mDecls.Append("  %a32 = trunc i64 %a to i32\n  %p2 = getelementptr inbounds [4 x i32], ptr addrspace(1) @treadle_gpu_error, i64 0, i64 2\n  store volatile i32 %a32, ptr addrspace(1) %p2, align 4\n");
			mDecls.Append("  %b32 = trunc i64 %b to i32\n  %p3 = getelementptr inbounds [4 x i32], ptr addrspace(1) @treadle_gpu_error, i64 0, i64 3\n  store volatile i32 %b32, ptr addrspace(1) %p3, align 4\n");
			mDecls.Append("  fence seq_cst\n  br label %out\nout:\n  call void asm sideeffect \"exit;\", \"\"()\n  unreachable\n}\n");
			mDecls.Append("define internal void @rt_null(ptr %s) #1 {\n  call void @treadle.gpu.fail(i32 1, ptr %s, i64 0, i64 0)\n  unreachable\n}\n");
			mDecls.Append("define internal void @rt_bounds(ptr %s, i64 %i, i64 %n) #1 {\n  call void @treadle.gpu.fail(i32 2, ptr %s, i64 %i, i64 %n)\n  unreachable\n}\n");
			mDecls.Append("define internal void @rt_span_range(ptr %s, i64 %a, i64 %b, i64 %c) #1 {\n  call void @treadle.gpu.fail(i32 3, ptr %s, i64 %a, i64 %c)\n  unreachable\n}\n");
			mDecls.Append("define internal void @rt_freed(ptr %s) #1 {\n  call void @treadle.gpu.fail(i32 4, ptr %s, i64 0, i64 0)\n  unreachable\n}\n");
			mDecls.Append("define internal void @rt_fatal(i32 %c, ptr %s, ptr %m) #1 {\n  %c64 = sext i32 %c to i64\n  call void @treadle.gpu.fail(i32 5, ptr %s, i64 %c64, i64 0)\n  unreachable\n}\n");
			mDecls.Append("define internal void @rt_local_array_length(ptr %s, i64 %n) #1 {\n  call void @treadle.gpu.fail(i32 6, ptr %s, i64 %n, i64 0)\n  unreachable\n}\n");
			mDecls.Append("define internal void @rt_abstract_call() #1 {\n  call void @treadle.gpu.fail(i32 7, ptr null, i64 0, i64 0)\n  unreachable\n}\n");
			// a Fatal node's message: nowhere to write it on the GPU (its record names the node)
			mDecls.Append("define internal void @rt_console_error_write(ptr %p, i64 %n) {\n  ret void\n}\n");
			mDecls.Append("declare void @llvm.lifetime.start.p0(ptr)\ndeclare void @llvm.lifetime.end.p0(ptr)\n");
			mDecls.Append("declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)\ndeclare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)\n");
			for (let k in kernels)
				DefineFunction(k);
			Drain();
			for (let k in kernels)
				KernelEntry(k);
			if (errors.Count > before)
				return false;

			String text = scope .();
			text.AppendF("; Treadle GPU kernels (NVPTX, docs/GPU-Compute.md)\n");
			text.AppendF("source_filename = \"{}\"\n", Unit.Name);
			text.AppendF("target datalayout = \"{}\"\n", NvptxDataLayout);
			text.AppendF("target triple = \"{}\"\n\n", NvptxTriple);
			text.Append(mTypes);
			text.Append('\n');
			text.Append(mGlobals);
			text.Append('\n');
			text.Append(mDecls);
			text.Append('\n');
			text.Append(mFuncs);
			// convergent: no transform may make a Kernel.Barrier depend on more control flow than it had
			text.Append("\nattributes #0 = { convergent nounwind }\nattributes #1 = { noreturn nounwind }\nattributes #2 = { noinline }\n\n");
			// metadata: the alias tags stay; debug info nodes become empty tuples (the numbering stays)
			for (let m in Meta)
			{
				if (m.StartsWith("!DI") || m.StartsWith("distinct !DI") || m.IsEmpty)
					text.AppendF("!{} = !{{}}\n", @m.Index);
				else
					text.AppendF("!{} = {}\n", @m.Index, m);
			}
			KernelSites(text, outSites);
			StripForGpu(text, outText);
			return true;
		}

		/// The site table of the module (RunKernelModule): each site's place, and for the sites of
		/// Fatal nodes (`call void @rt_fatal(i32 c, ptr @.site.N, ptr @.str.M)`) the message.
		void KernelSites(StringView text, List<String> outSites)
		{
			for (int i < mSites.Count)
				outSites.Add(new String());
			for (let kv in mSites)
			{
				if (!(int.Parse(StringView(kv.value, "@.site.".Length)) case .Ok(let n)) || n < 0 || n >= outSites.Count)
					continue;
				let sep = kv.key.IndexOf('\x01');
				StringView place = (sep < 0) ? kv.key : StringView(kv.key, 0, sep);
				StringView node = (sep < 0) ? "?" : StringView(kv.key, sep + 1);
				outSites[n].AppendF("{}\x01{}\x01", place, node);
			}
			Dictionary<StringView, StringView> strings = scope .();
			for (let kv in mStrings)
				strings[kv.value] = kv.key;
			// a Fatal node writes its message (rt_console_error_write of a constant) before rt_fatal
			StringView lastText = default;
			for (let line in text.Split('\n'))
			{
				if (line.StartsWith("define "))
					lastText = default;
				// `%t = extractvalue { ptr, i64 } { ptr @.str.N, i64 n }, 0` before the console write
				let ev = line.Contains("extractvalue") ? line.IndexOf("{ ptr @.str.") : -1;
				if (ev >= 0)
				{
					int ee = ev + 12;
					while (ee < line.Length && line[ee].IsDigit)
						ee++;
					if (strings.TryGetValue(line.Substring(ev + 6, ee - ev - 6), let said))
						lastText = said;
				}
				let call = line.IndexOf("call void @rt_fatal(i32 ");
				if (call < 0)
					continue;
				let s = line.IndexOf("ptr @.site.", call);
				let m = line.IndexOf("ptr @.str.", call);
				if (s < 0 || m < 0)
					continue;
				int se = s + 11;
				while (se < line.Length && line[se].IsDigit)
					se++;
				int me = m + 10;
				while (me < line.Length && line[me].IsDigit)
					me++;
				if (!(int.Parse(line.Substring(s + 11, se - s - 11)) case .Ok(let n)) || n < 0 || n >= outSites.Count)
					continue;
				if (!outSites[n].EndsWith('\x01'))
					continue;
				if (!lastText.IsEmpty)
					outSites[n].Append(lastText);
				else if (strings.TryGetValue(line.Substring(m + 4, me - m - 4), let msg))
					outSites[n].Append(msg);
			}
		}

		/// Takes out what NVPTX does not take or the GPU module does not want: debug records and
		/// attachments, COMDATs (a linkonce_odr function becomes internal).
		static void StripForGpu(StringView text, String outText)
		{
			for (var line in text.Split('\n'))
			{
				StringView trimmed = line;
				trimmed.TrimStart();
				if (trimmed.StartsWith("#dbg_"))
					continue;
				if (trimmed.StartsWith("$") && trimmed.EndsWith("= comdat any"))
					continue;
				// a check site is its number on the GPU (the error record holds it; KernelSites)
				if (line.StartsWith("@.site.") && line.Contains("%rt.Site"))
				{
					let eq = line.IndexOf(' ');
					outText.AppendF("{} = private unnamed_addr constant i32 {}, align 4\n", line.Substring(0, eq), line.Substring(7, eq - 7));
					continue;
				}
				String l = scope .(line);
				GpuMath(l);
				Remove(l, ", !dbg !");
				Remove(l, " !dbg !");
				RemoveComdat(l);
				if (l.StartsWith("define linkonce_odr "))
					l.Replace("define linkonce_odr ", "define internal ");
				outText.Append(l);
				outText.Append('\n');
			}
		}

		/// The Math functions NVPTX has no instructions for: llvm.<name>.f32 / .f64 become calls of
		/// treadle_gpu_<name>f / treadle_gpu_<name> (tools/runtime/treadle_gpu_math.c, linked by
		/// KernelBuild when the module calls one).
		public static StringView[?] GpuMathNames = .("sin", "cos", "tan", "asin", "acos", "atan2", "atan", "exp", "log", "pow");

		/// True when the module text calls one of treadle_gpu_math.c's functions.
		public static bool CallsGpuMath(StringView ll)
		{
			for (let name in GpuMathNames)
				if (ll.Contains(scope $"@treadle_gpu_{name}f(") || ll.Contains(scope $"@treadle_gpu_{name}("))
					return true;
			return false;
		}

		static void GpuMath(String l)
		{
			if (!l.Contains("@llvm."))
				return;
			for (let name in GpuMathNames)
			{
				l.Replace(scope $"@llvm.{name}.f32(", scope $"@treadle_gpu_{name}f(");
				l.Replace(scope $"@llvm.{name}.f64(", scope $"@treadle_gpu_{name}(");
			}
		}

		/// Removes `<what><digits>` everywhere in `l`.
		static void Remove(String l, StringView what)
		{
			while (true)
			{
				let at = l.IndexOf(what);
				if (at < 0)
					return;
				int end = at + what.Length;
				while (end < l.Length && l[end].IsDigit)
					end++;
				l.Remove(at, end - at);
			}
		}

		/// Removes ` comdat(...)` and `, comdat(...)` / `, comdat` from a line.
		static void RemoveComdat(String l)
		{
			while (true)
			{
				let at = l.IndexOf(" comdat(");
				if (at < 0)
					break;
				let close = l.IndexOf(')', at);
				if (close < 0)
					break;
				int from = (at > 0 && l[at - 1] == ',') ? at - 1 : at;
				l.Remove(from, close + 1 - from);
			}
			if (l.EndsWith(", comdat"))
				l.RemoveFromEnd(8);
		}
	}
}

namespace Treadle.Backend.Emit
{
	extension UnitEmitter
	{
		/// Kernel.Shared call sites emitted in this unit (their globals' numbers).
		public int KernelSharedCount;

		/// A global definition line of the kernel code (its own text).
		public void KernelGlobal(StringView line) => mGlobals.Append(line);
	}

	extension FunctionEmitter
	{
		/// `kernel.shared T* <count>` (Kernel.Shared): the call site's block memory. On the GPU a
		/// static `addrspace(3)` array of `count` elements (CUDA's __shared__), as a generic pointer;
		/// on the CPU rt_kernel_shared(<the site's key>, <bytes>), the runtime's per-block arena.
		void EmitKernelIntrinsic(IROp op, StringView r)
		{
			if (op.Sub != "kernel.shared" || op.Args.Count != 1 || op.Type.Kind != .Pointer)
			{
				Error(scope $"unknown kernel intrinsic '{op.Sub}'");
				return;
			}
			String n = scope .();
			V(op.Args[0], n);
			let elem = op.Type.Elem;
			String arr = scope $"[{n} x {L.Mem(elem)}]";
			let id = U.KernelSharedCount++;
			if (U.KernelMode)
			{
				U.KernelGlobal(scope $"@treadle.shared.{id} = internal addrspace(3) global {arr} undef, align 16\n");
				I(scope $"{r} = addrspacecast ptr addrspace(3) @treadle.shared.{id} to ptr");
			}
			else
			{
				U.KernelGlobal(scope $"@treadle.shared.key.{id} = private global i8 0, align 1\n");
				U.NeedIntrinsic("declare ptr @rt_kernel_shared(ptr, i64)");
				I(scope $"{r} = call ptr @rt_kernel_shared(ptr @treadle.shared.key.{id}, i64 ptrtoint (ptr getelementptr ({arr}, ptr null, i32 1) to i64))");
			}
			Def(op.Result, r);
		}
	}
}
