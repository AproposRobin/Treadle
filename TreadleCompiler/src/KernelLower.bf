using System;
using System.Collections;
using Treadle.Model;

namespace Treadle.Compiler
{
	// GPU compute, experimental (docs/GPU-Compute.md): Lower's part of `[Kernel]` functions. The
	// kernel itself is lowered as any static function and marked `kernel "<entry>"` (the back end
	// compiles it a second time, for the GPU, EmitKernel.bf). Next to it, in the same unit, two
	// functions the dispatch calls:
	//
	//   <Owner>.$kcpuR_<Name>(void* args, int lo, int hi, int block)
	//                                    Kernel.SetBlockSize(block); for i in lo ..< hi:
	//                                    Kernel.SetIndex(i); Name(*args[0], ...)
	//   <Owner>.$kcpu_<Name>(int count, int block, <inputs>)
	//                                    rt_kernel_cpu(count, block, flags, $kcpuR_<Name>, &input0, ...):
	//                                    the chunks over the thread pool (whole blocks on fibers
	//                                    when the kernel uses Kernel.Shared / Kernel.Barrier)
	//   <Owner>.$kgpu_<Name>(int count, int block, GpuStream stream, <inputs>) -> bool
	//                                    rt_gpu_launch("<entry>", "<kinds>", count, block, the stream's
	//                                    handle (null: the default stream), flags, &input0, ...); when
	//                                    there is no GPU, the CPU one over the buffers' host memory
	//
	// where a Span<T> input of the GPU function is a GpuBuffer<T> (its `mSpan` is passed: the device
	// pointer and the count) and `kinds` has one letter per input, `S` a span (two PTX parameters) or
	// `v` a value. Gpu.Dispatch lowers to a call of the GPU function, Kernel.RunCpu to the CPU one.

	extension IRFunction
	{
		/// `[Kernel]`: the PTX entry name of the function's GPU form (`kernel "<entry>"` in the text).
		public String Kernel ~ delete _;
	}

	extension ProgramLowerer
	{
		/// The funcref of a kernel's dispatch function: `<Owner>.$kcpu_<Name>(int,<inputs>)` or
		/// `$kgpu_` (whose Span<T> inputs are GpuBuffer<T>).
		public void KernelHelperKey(MemberSym k, bool gpu, String o)
		{
			KirWriter.Type(k.Owner.Self, o);
			o.AppendF(".{}{}(int,int", gpu ? "$kgpu_" : "$kcpu_", k.Name);
			if (gpu)
			{
				o.Append(',');
				KirWriter.Type(IRCanon(KernelStreamType()), o);
			}
			for (let p in k.Params)
			{
				o.Append(',');
				KirWriter.Type(IRCanon(KernelInputType(p.Type, gpu)), o);
			}
			o.Append(')');
		}

		/// Core.GpuStream (the stream input of a GPU dispatch function).
		public KType KernelStreamType()
		{
			let sym = T.Find("Core.GpuStream");
			return (sym != null) ? sym.Self : T.Pointer(T.Void);
		}

		/// A kernel input's type at a dispatch: a Span<T> is a GpuBuffer<T> for the GPU.
		public KType KernelInputType(KType t, bool gpu)
		{
			if (!gpu || !KernelRules.IsSpan(T, t))
				return t;
			let sym = T.Find("Core.GpuBuffer");
			return (sym != null) ? T.Named(sym, scope KType[](t.Args[0])) : t;
		}

		static IRValue KParam(IRFunction f, StringView name, KType t)
		{
			IRValue v = new .();
			v.Param = new String(name);
			v.Type = t;
			f.Params.Add(v);
			return v;
		}

		/// The CPU and the GPU dispatch functions of the kernel `k` (after its own function, in its unit).
		public void KernelHelpers(MemberSym k, KType inst, String o)
		{
			let kernelSym = T.Find("Core.Kernel");
			let gpuSym = T.Find("Core.Gpu");
			if (kernelSym == null || gpuSym == null)
				return;
			Need(kernelSym.Self);
			String kernelKey = scope .();
			FuncRef(k, inst, null, .Body, kernelKey);
			String cpuKey = scope .();
			KernelHelperKey(k, false, cpuKey);
			// the CPU one: the chunk function `$kcpuR_<Name>(void* args, int lo, int hi)` runs the
			// kernel for lo ..< hi (Kernel.SetIndex(i), then the kernel, reading the inputs from the
			// argument addresses); `$kcpu_<Name>` hands it to rt_kernel_cpu, which cuts 0 ..< count
			// into chunks over the thread pool (Parallel.ForRange's), or runs it in whole blocks when
			// the kernel uses Kernel.Shared / Kernel.Barrier
			MemberSym setIndex = null;
			MemberSym setBlock = null;
			MemberSym cpuRun = null;
			for (let m in kernelSym.Members)
			{
				if (m.Name == "SetIndex")
					setIndex = m;
				else if (m.Name == "SetBlockSize")
					setBlock = m;
				else if (m.Name == "rt_kernel_cpu")
					cpuRun = m;
			}
			if (setIndex == null || setBlock == null || cpuRun == null)
				return;
			let voidPtr = T.Pointer(T.Void);
			String chunkKey = scope .();
			KirWriter.Type(k.Owner.Self, chunkKey);
			chunkKey.AppendF(".$kcpuR_{}(", k.Name);
			KirWriter.Type(IRCanon(voidPtr), chunkKey);
			chunkKey.Append(",int,int,int)");
			{
				String setKey = scope .();
				FuncRef(setIndex, kernelSym.Self, null, .Body, setKey);
				Use(setIndex, kernelSym.Self, setKey);
				String setBlockKey = scope .();
				FuncRef(setBlock, kernelSym.Self, null, .Body, setBlockKey);
				Use(setBlock, kernelSym.Self, setBlockKey);
				IRFunction f = scope .();
				f.Key.Set(chunkKey);
				f.Display.AppendF("{}.{} (Kernel.RunCpu, a chunk)", k.Owner.FullName, k.Name);
				f.Static = true;
				f.Ret = T.Void;
				let args = KParam(f, "args", voidPtr);
				let lo = KParam(f, "lo", T.Int);
				let hi = KParam(f, "hi", T.Int);
				let blockIn = KParam(f, "block", T.Int);
				f.Regions.Add(new IRRegion());
				let entry = f.NewBlock();
				let head = f.NewBlock();
				let body = f.NewBlock();
				let done = f.NewBlock();
				let idx = f.NewSlot(T.Int, .LoopVar, "", "", "index");
				OpEmitter e = scope .(f, entry);
				// the inputs, from their addresses
				let argv = e.Op(.Cast, T.Pointer(voidPtr), "", "");
				argv.Operands.Add(args);
				List<IRValue> ins = scope .();
				for (let p in k.Params)
				{
					Need(p.Type);
					let at = e.Const(scope $"{@p.Index}", T.Int, "", "");
					let slotAddr = e.Op(.ElemAddr, T.Pointer(voidPtr), "", "");
					slotAddr.Operands.Add(argv);
					slotAddr.Operands.Add(at);
					let addr = e.Op(.Load, voidPtr, "", "");
					addr.Operands.Add(slotAddr);
					let typed = e.Op(.Cast, T.Pointer(p.Type), "", "");
					typed.Operands.Add(addr);
					let v = e.Op(.Load, p.Type, "", "");
					v.Operands.Add(typed);
					ins.Add(v);
				}
				let sb = e.Op(.Call, T.Void, "", "");
				sb.Callee = new String(setBlockKey);
				sb.Operands.Add(blockIn);
				let st0 = e.Op(.StoreSlot, T.Void, "", "");
				st0.Slot = idx;
				st0.Operands.Add(lo);
				e.Br(head);
				e.Block = head;
				let i0 = e.Op(.LoadSlot, T.Int, "", "");
				i0.Slot = idx;
				let more = e.Op(.Cmp, T.Bool, "", "");
				more.Sub = new String("lt");
				more.Operands.Add(i0);
				more.Operands.Add(hi);
				head.Term = .CondBr;
				head.Cond = more;
				head.Targets.Add(body);
				head.Targets.Add(done);
				e.Block = body;
				let i1 = e.Op(.LoadSlot, T.Int, "", "");
				i1.Slot = idx;
				let set = e.Op(.Call, T.Void, "", "");
				set.Callee = new String(setKey);
				set.Operands.Add(i1);
				let call = e.Op(.Call, T.Void, "", "");
				call.Callee = new String(kernelKey);
				call.Operands.AddRange(ins);
				let i2 = e.Op(.LoadSlot, T.Int, "", "");
				i2.Slot = idx;
				let one = e.Const("1", T.Int, "", "");
				let next = e.Op(.Binop, T.Int, "", "");
				next.Sub = new String("add");
				next.Operands.Add(i2);
				next.Operands.Add(one);
				let st1 = e.Op(.StoreSlot, T.Void, "", "");
				st1.Slot = idx;
				st1.Operands.Add(next);
				e.Br(head);
				done.Term = .Ret;
				KirWriter.Function(f, o);
			}
			{
				String runKey = scope .();
				FuncRef(cpuRun, kernelSym.Self, null, .Body, runKey);
				Use(cpuRun, kernelSym.Self, runKey);
				IRFunction f = scope .();
				f.Key.Set(cpuKey);
				f.Display.AppendF("{}.{} (Kernel.RunCpu)", k.Owner.FullName, k.Name);
				f.Static = true;
				f.Ret = T.Void;
				let count = KParam(f, "count", T.Int);
				let block = KParam(f, "block", T.Int);
				List<IRValue> ins = scope .();
				for (let p in k.Params)
				{
					ins.Add(KParam(f, p.Name, p.Type));
					Need(p.Type);
				}
				f.Regions.Add(new IRRegion());
				let entry = f.NewBlock();
				OpEmitter e = scope .(f, entry);
				List<IRValue> addrs = scope .();
				for (let p in k.Params)
				{
					let s = f.NewSlot(p.Type, .OutTemp, "", "", p.Name);
					let st = e.Op(.StoreSlot, T.Void, "", "");
					st.Slot = s;
					st.Operands.Add(ins[@p.Index]);
					let sa = e.Op(.SlotAddr, T.Pointer(p.Type), "", "");
					sa.Slot = s;
					let c = e.Op(.Cast, voidPtr, "", "");
					c.Operands.Add(sa);
					addrs.Add(c);
				}
				let fn = e.Op(.FnAddr, voidPtr, "", "");
				fn.Callee = new String(chunkKey);
				List<IRValue> runArgs = scope .();
				runArgs.Add(count);
				runArgs.Add(block);
				runArgs.Add(e.Const(scope $"{KernelFlags(k)}", T.Int32, "", ""));
				runArgs.Add(fn);
				for (int i < KernelRules.MaxParams)
					runArgs.Add((i < addrs.Count) ? addrs[i] : e.Const("null", voidPtr, "", ""));
				let run = e.Op(.CCall, T.Void, "", "");
				run.Callee = new String(runKey);
				run.Operands.AddRange(runArgs);
				entry.Term = .Ret;
				KirWriter.Function(f, o);
			}
			// the GPU one
			{
				MemberSym launch = null;
				for (let m in gpuSym.Members)
					if (m.Name == "rt_gpu_launch")
						launch = m;
				if (launch == null)
					return;
				String launchKey = scope .();
				FuncRef(launch, gpuSym.Self, null, .Body, launchKey);
				Use(launch, gpuSym.Self, launchKey);
				IRFunction f = scope .();
				KernelHelperKey(k, true, f.Key);
				f.Display.AppendF("{}.{} (Gpu.Dispatch)", k.Owner.FullName, k.Name);
				f.Static = true;
				f.Ret = T.Bool;
				let count = KParam(f, "count", T.Int);
				let block = KParam(f, "block", T.Int);
				let streamType = KernelStreamType();
				Need(streamType);
				let stream = KParam(f, "stream", streamType);
				List<IRValue> ins = scope .();
				for (let p in k.Params)
				{
					let t = KernelInputType(p.Type, true);
					Need(t);
					ins.Add(KParam(f, p.Name, t));
				}
				f.Regions.Add(new IRRegion());
				let entry = f.NewBlock();
				let hasStream = f.NewBlock();
				let launch = f.NewBlock();
				let onGpu = f.NewBlock();
				let onCpu = f.NewBlock();
				OpEmitter e = scope .(f, entry);
				let voidPtr = T.Pointer(T.Void);
				// the stream's handle, null for none (Gpu.Dispatch: the default stream)
				let handle = f.NewSlot(voidPtr, .OutTemp, "", "", "stream");
				let nullHandle = e.Const("null", voidPtr, "", "");
				let st0 = e.Op(.StoreSlot, T.Void, "", "");
				st0.Slot = handle;
				st0.Operands.Add(nullHandle);
				let nullStream = e.Const("null", streamType, "", "");
				let isSet = e.Op(.Cmp, T.Bool, "", "");
				isSet.Sub = new String("ne");
				isSet.Operands.Add(stream);
				isSet.Operands.Add(nullStream);
				entry.Term = .CondBr;
				entry.Cond = isSet;
				entry.Targets.Add(hasStream);
				entry.Targets.Add(launch);
				e.Block = hasStream;
				let hfa = e.Op(.FieldAddr, T.Pointer(voidPtr), "", "");
				hfa.Operands.Add(stream);
				hfa.Sub = new String("mHandle");
				let hv = e.Op(.Load, voidPtr, "", "");
				hv.Operands.Add(hfa);
				let st1 = e.Op(.StoreSlot, T.Void, "", "");
				st1.Slot = handle;
				st1.Operands.Add(hv);
				e.Br(launch);
				e.Block = launch;
				String kinds = scope .();
				List<IRValue> addrs = scope .();
				for (let p in k.Params)
				{
					let v = ins[@p.Index];
					IRValue addr;
					if (KernelRules.IsSpan(T, p.Type))
					{
						// the buffer's span (device pointer, count) in the object
						kinds.Append('S');
						e.Op(.NullCheck, T.Void, "", "").Operands.Add(v);
						let fa = e.Op(.FieldAddr, T.Pointer(p.Type), "", "");
						fa.Operands.Add(v);
						fa.Sub = new String("mSpan");
						addr = fa;
					}
					else
					{
						kinds.Append('v');
						let s = f.NewSlot(p.Type, .OutTemp, "", "", p.Name);
						let st = e.Op(.StoreSlot, T.Void, "", "");
						st.Slot = s;
						st.Operands.Add(v);
						let sa = e.Op(.SlotAddr, T.Pointer(p.Type), "", "");
						sa.Slot = s;
						addr = sa;
					}
					addrs.Add(addr);
				}
				// every operand is made before the op that reads it
				List<IRValue> launchArgs = scope .();
				launchArgs.Add(e.Const(scope $"\"{k.KernelEntry}\"", T.Pointer(T.Char8), "", ""));
				launchArgs.Add(e.Const(scope $"\"{kinds}\"", T.Pointer(T.Char8), "", ""));
				launchArgs.Add(count);
				launchArgs.Add(block);
				let hl = e.Op(.LoadSlot, voidPtr, "", "");
				hl.Slot = handle;
				launchArgs.Add(hl);
				launchArgs.Add(e.Const(scope $"{KernelFlags(k)}", T.Int32, "", ""));
				for (int i < KernelRules.MaxParams)
				{
					if (i < addrs.Count)
					{
						let c = e.Op(.Cast, voidPtr, "", "");
						c.Operands.Add(addrs[i]);
						launchArgs.Add(c);
					}
					else
						launchArgs.Add(e.Const("null", voidPtr, "", ""));
				}
				let launchOp = e.Op(.CCall, T.Int32, "", "");
				launchOp.Callee = new String(launchKey);
				launchOp.Operands.AddRange(launchArgs);
				let zero32 = e.Const("0", T.Int32, "", "");
				let ran = e.Op(.Cmp, T.Bool, "", "");
				ran.Sub = new String("ne");
				ran.Operands.Add(launchOp);
				ran.Operands.Add(zero32);
				launch.Term = .CondBr;
				launch.Cond = ran;
				launch.Targets.Add(onGpu);
				launch.Targets.Add(onCpu);
				e.Block = onGpu;
				onGpu.Term = .Ret;
				onGpu.RetVal = e.Const("true", T.Bool, "", "");
				// no GPU: the buffers are host memory, the kernel runs on the CPU
				e.Block = onCpu;
				List<IRValue> cpuArgs = scope .();
				cpuArgs.Add(count);
				cpuArgs.Add(block);
				for (let p in k.Params)
				{
					if (KernelRules.IsSpan(T, p.Type))
					{
						let ld = e.Op(.Load, p.Type, "", "");
						ld.Operands.Add(addrs[@p.Index]);
						cpuArgs.Add(ld);
					}
					else
						cpuArgs.Add(ins[@p.Index]);
				}
				let cpuCall = e.Op(.Call, T.Void, "", "");
				cpuCall.Callee = new String(cpuKey);
				cpuCall.Operands.AddRange(cpuArgs);
				onCpu.Term = .Ret;
				onCpu.RetVal = e.Const("false", T.Bool, "", "");
				KirWriter.Function(f, o);
			}
		}
	}

	extension ProgramLowerer
	{
		/// The launch flags of a kernel (rt_gpu_launch, rt_kernel_cpu): 1 = it uses Kernel.Shared or
		/// Kernel.Barrier (it runs in whole blocks).
		public int32 KernelFlags(MemberSym k) => k.KernelBlocks ? 1 : 0;
	}

	extension FnLowerer
	{
		/// Kernel.Shared<T>(count): the block's memory for this node, `kernel.shared` (a T* to the
		/// node's own static block memory: an addrspace(3) array on the GPU, the runtime's per-block
		/// arena on the CPU), made a Span<T> of `count`. The count is typed on the node.
		IRValue KernelShared(List<IRValue> args, KType result, StringView node, StringView pin)
		{
			let lit = (args.Count > 0) ? args[0] as IROp : null;
			int64 n = 0;
			if (lit != null && lit.Kind == .Const && !lit.LitIsString && lit.Lit != null)
			{
				if (int64.Parse(lit.Lit) case .Ok(let parsed))
					n = parsed;
			}
			if (n < 1)
			{
				M.C.Diags.Add(.Error, .Lower, "T2348", R.Site, node, "count", "Kernel.Shared: the count is a number above 0 typed on the node, not a wire (shared memory is laid out when the program is built)");
				M.Failed();
				return E.Const("default", result, node, pin);
			}
			if (result == null || result.Kind != .Named || result.Args.Count != 1)
				return E.Const("default", result, node, pin);
			let elem = result.Args[0];
			M.Need(result);
			M.Need(elem);
			let ptr = E.Op(.Intrinsic, T.Pointer(elem), node, pin);
			ptr.Sub = new String("kernel.shared");
			ptr.Operands.Add(lit);
			let mk = E.Op(.Make, result, node, pin);
			mk.Operands.Add(ptr);
			mk.Operands.Add(lit);
			return mk;
		}

		/// Gpu.Dispatch / Gpu.DispatchAsync / Kernel.RunCpu (Kernel.bf binds them): a call of the
		/// kernel's dispatch function with the count, the block size, the stream (GPU) and the kernel's
		/// inputs.
		IRValue KernelCallNode(BNode n, StringView pin)
		{
			let k = n.KernelFn;
			List<IRValue> args = scope .();
			args.Add(EvalIn(n, "count"));
			args.Add(E.Const(scope $"{n.KernelBlock}", T.Int, n.Key, ""));
			if (n.KernelGpu)
				args.Add(n.KernelAsync ? EvalIn(n, "stream") : E.Const("null", M.KernelStreamType(), n.Key, ""));
			for (let p in k.Params)
				args.Add(EvalIn(n, p.Name));
			String name = scope .();
			M.KernelHelperKey(k, n.KernelGpu, name);
			let op = E.Op(.Call, n.KernelGpu ? T.Bool : T.Void, n.Key, n.Flow ? "" : pin);
			op.Callee = new String(name);
			op.Operands.AddRange(args);
			return op;
		}
	}
}
