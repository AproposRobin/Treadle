using System;
using System.Collections;
using System.IO;
using Treadle.Backend.IR;
using Treadle.Backend.Emit;

namespace Treadle.Backend.Driver
{
	/// GPU compute, experimental (docs/GPU-Compute.md): the build's part. When the program has
	/// [Kernel] functions, Build adds one unit, `__gpu`: the kernels' NVPTX module (EmitKernel.bf)
	/// compiled by the same clang to PTX text (`--target=nvptx64-nvidia-cuda -march=sm_75`, cached by
	/// the module's text), embedded as a constant and registered with the runtime by a static
	/// constructor (`rt_gpu_register`). The runtime's GPU code (tools/runtime/treadle_gpu.c) is
	/// appended to treadle_rt.c, so every program has it and none links a GPU library.
	static class KernelBuild
	{
		/// A zero-terminated string constant `sym` (bytes outside printable ASCII as \XX).
		static void CString(String t, StringView sym, StringView text)
		{
			t.AppendF("{} = private unnamed_addr constant [{} x i8] c\"", sym, text.Length + 1);
			for (let c in text.RawChars)
			{
				let b = (uint8)c;
				if (b < 0x20 || b >= 0x7F || c == '"' || c == '\\')
					t.AppendF("\\{:X2}", b);
				else
					t.Append(c);
			}
			t.Append("\\00\", align 1\n");
		}

		/// The PTX target: Turing and newer (the driver JIT-compiles PTX for the GPU it runs on).
		public const String PtxArch = "sm_75";
		public const String UnitName = "__gpu";
		/// The PTX ISA version, given: clang's default for nvptx follows its version (6.3 for sm_75
		/// in clang 23, 4.2 in the system clang 22 of Linux, which then refuses sm_75).
		public const String PtxVersion = "+ptx63";

		static void AddPtxVersion(List<String> args)
		{
			args.Add(new .("-Xclang"));
			args.Add(new .("-target-feature"));
			args.Add(new .("-Xclang"));
			args.Add(new .(PtxVersion));
		}

		[Comptime(ConstEval=true)]
		static String Embed(String name)
		{
			String path = scope .();
			path.AppendF("{}/../tools/runtime/{}", Compiler.ProjectDir, name);
			String data = scope .();
			File.ReadAllText(path, data);
			return data;
		}

		public const String EmbeddedGpuC = Embed("treadle_gpu.c");
		/// The GPU's transcendental Math functions (compiled for NVPTX, linked when a kernel calls one).
		public const String EmbeddedGpuMath = Embed("treadle_gpu_math.c");

		/// Runs clang for the GPU code; false with the errors in the report (`kept` stays for inspection).
		static bool RunClang(StringView clang, List<String> args, BuildOptions opts, BuildReport report, StringView what, StringView kept)
		{
			RunningProcess p = scope .();
			if (!p.Start(clang, args, opts.OutDir))
			{
				report.AddError(scope $"could not start clang for {what}");
				return false;
			}
			report.AddLog(scope $"> {p.CommandLine}");
			p.Wait();
			String err = scope .();
			p.GetErrors(err);
			for (var line in err.Split('\n'))
				if (!line.IsEmpty)
					report.AddLog(line);
			if (p.ExitCode != 0)
			{
				report.AddError(scope $"clang failed on {what} (exit code {p.ExitCode}); {kept} is kept for inspection:");
				Builder.ParseToolErrors(err, report.Errors);
				return false;
			}
			return true;
		}

		/// Appends the GPU runtime to the runtime's C source: treadle_gpu.c from where treadle_rt.c
		/// came from (`from`, a folder), else the copy compiled into this library.
		public static void AppendGpuRuntime(String rtC, StringView from)
		{
			String gpu = scope .();
			if (!(File.ReadAllText(scope $"{from}/treadle_gpu.c", gpu) case .Ok))
				gpu.Set(EmbeddedGpuC);
			rtC.Append("\n/* ---- treadle_gpu.c (appended by the build driver) ---- */\n");
			rtC.Append(gpu);
		}

		/// Adds the `__gpu` unit to `units` when the program has kernels. False with errors in the
		/// report when the module could not be made or compiled.
		public static bool AddGpuUnit(IRProgram program, Emitter emitter, StringView clang, BuildOptions opts, List<UnitOutput> units, BuildReport report)
		{
			List<IRFunction> kernels = scope .();
			for (let f in program.Functions)
				if (f.KernelName != null && f.HasBody)
					kernels.Add(f);
			if (kernels.IsEmpty)
				return true;
			IRUnit unit = scope .();
			unit.Name.Set("__gpu_kernels");
			UnitEmitter ue = scope .(emitter, unit);
			ue.Dbg = false;
			String ll = scope .();
			List<String> errors = scope .();
			defer { ClearAndDeleteItems!(errors); }
			List<String> sites = scope .();
			defer { ClearAndDeleteItems!(sites); }
			if (!ue.RunKernelModule(kernels, ll, errors, sites))
			{
				for (let e in errors)
					report.AddError(scope $"GPU kernels: {e}");
				return false;
			}
			// the PTX, compiled again only when the module's text (or the math library it links) changed
			String llPath = scope $"{opts.OutDir}/__gpu_kernels.nvptx.ll";
			String ptxPath = scope $"{opts.OutDir}/__gpu_kernels.ptx";
			String mathC = scope $"{opts.OutDir}/__gpu_math.c";
			String mathBc = scope $"{opts.OutDir}/__gpu_math.bc";
			let needMath = UnitEmitter.CallsGpuMath(ll);
			String oldMath = scope .();
			let mathSame = !needMath || ((File.ReadAllText(mathC, oldMath, true) case .Ok) && oldMath == EmbeddedGpuMath && File.Exists(mathBc));
			String old = scope .();
			let same = (File.ReadAllText(llPath, old, true) case .Ok) && old == ll && File.Exists(ptxPath) && mathSame;
			if (!same)
			{
				File.Delete(ptxPath).IgnoreError();
				if (File.WriteAllText(llPath, ll) case .Err)
				{
					report.AddError(scope $"cannot write {llPath}");
					return false;
				}
				// the math library to bitcode (its own cache: the C text next to it)
				if (needMath && !mathSame)
				{
					File.Delete(mathBc).IgnoreError();
					if (File.WriteAllText(mathC, EmbeddedGpuMath) case .Err)
					{
						report.AddError(scope $"cannot write {mathC}");
						return false;
					}
					List<String> margs = scope .();
					defer { ClearAndDeleteItems!(margs); }
					margs.Add(new $"--target={UnitEmitter.NvptxTriple}");
					margs.Add(new $"-march={PtxArch}");
					AddPtxVersion(margs);
					margs.Add(new .("-O3"));
					margs.Add(new .("-ffp-contract=off"));
					margs.Add(new .("-c"));
					margs.Add(new .("-emit-llvm"));
					margs.Add(new .(mathC));
					margs.Add(new .("-o"));
					margs.Add(new .(mathBc));
					if (!RunClang(clang, margs, opts, report, "the GPU math library", mathC))
					{
						File.Delete(mathC).IgnoreError();
						return false;
					}
				}
				List<String> args = scope .();
				defer { ClearAndDeleteItems!(args); }
				args.Add(new $"--target={UnitEmitter.NvptxTriple}");
				args.Add(new $"-march={PtxArch}");
				AddPtxVersion(args);
				args.Add(new .("-O3"));
				args.Add(new .("-S"));
				args.Add(new .(llPath));
				if (needMath)
				{
					// only what the kernels call is kept (and inlined)
					args.Add(new .("-Xclang"));
					args.Add(new .("-mlink-builtin-bitcode"));
					args.Add(new .("-Xclang"));
					args.Add(new .(mathBc));
				}
				args.Add(new .("-o"));
				args.Add(new .(ptxPath));
				if (!RunClang(clang, args, opts, report, "the GPU kernels", llPath))
				{
					File.Delete(ptxPath).IgnoreError();
					return false;
				}
			}
			String ptx = scope .();
			if (!(File.ReadAllText(ptxPath, ptx, true) case .Ok))
			{
				report.AddError(scope $"cannot read {ptxPath}");
				return false;
			}
			// the unit: the PTX as a zero-terminated constant, registered before Main
			UnitOutput o = new .();
			o.Name.Set(UnitName);
			let t = o.LL;
			t.AppendF("; Treadle unit {} (the PTX of the program's [Kernel] functions, docs/GPU-Compute.md)\n", UnitName);
			t.AppendF("source_filename = \"{}\"\n", UnitName);
			t.AppendF("target datalayout = \"{}\"\n", emitter.Options.DataLayout);
			t.AppendF("target triple = \"{}\"\n\n", emitter.Options.Triple);
			t.AppendF("@treadle_gpu_ptx = private unnamed_addr constant [{} x i8] c\"", ptx.Length + 1);
			for (let c in ptx.RawChars)
			{
				let b = (uint8)c;
				if (b < 0x20 || b >= 0x7F || c == '"' || c == '\\')
					t.AppendF("\\{:X2}", b);
				else
					t.Append(c);
			}
			t.Append("\\00\", align 1\n");
			// the check sites (the device-side error record's site numbers) and the kernels' names
			String sitePtrs = scope .();
			for (let s in sites)
			{
				if (!sitePtrs.IsEmpty)
					sitePtrs.Append(", ");
				sitePtrs.AppendF("ptr @treadle_gpu_site.{}", @s.Index);
				CString(t, scope $"@treadle_gpu_site.{@s.Index}", s);
			}
			String kernelPtrs = scope .();
			for (let k in kernels)
			{
				String name = scope .(k.Key);
				let paren = name.IndexOf('(');
				if (paren >= 0)
					name.RemoveToEnd(paren);
				CString(t, scope $"@treadle_gpu_kentry.{@k.Index}", k.KernelName);
				CString(t, scope $"@treadle_gpu_kname.{@k.Index}", name);
				if (!kernelPtrs.IsEmpty)
					kernelPtrs.Append(", ");
				kernelPtrs.AppendF("ptr @treadle_gpu_kentry.{0}, ptr @treadle_gpu_kname.{0}", @k.Index);
			}
			t.AppendF("@treadle_gpu_sites = private constant [{} x ptr] [{}]\n", sites.Count, sitePtrs);
			t.AppendF("@treadle_gpu_kernels = private constant [{} x ptr] [{}]\n", kernels.Count * 2, kernelPtrs);
			t.Append("declare void @rt_gpu_register(ptr, ptr, i32, ptr, i32)\n\n");
			t.AppendF("define internal void @treadle_gpu_init() {{\n  call void @rt_gpu_register(ptr @treadle_gpu_ptx, ptr @treadle_gpu_sites, i32 {}, ptr @treadle_gpu_kernels, i32 {})\n  ret void\n}}\n\n", sites.Count, kernels.Count);
			t.AppendF("@treadle_gpu_init.sct = internal constant ptr @treadle_gpu_init, section \"{}\", align 8\n", ue.StaticCtorSection);
			t.Append("@llvm.used = appending global [1 x ptr] [ptr @treadle_gpu_init.sct], section \"llvm.metadata\"\n");
			units.Add(o);
			report.AddLog(scope $"GPU kernels: {kernels.Count} compiled to PTX ({PtxArch}){(same ? " (cached)" : "")}");
			return true;
		}
	}
}
