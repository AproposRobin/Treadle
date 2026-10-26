using System;
using System.Collections;
using System.IO;
using Treadle.Backend.Emit;

namespace Treadle.Backend.Driver
{
	/// The `simd` config key (SIMD-and-Vectors.md 1.7, Compiler.md 6.4): which x86-64 level every
	/// function is compiled for. `x86-64` (SSE2), `x86-64-v2` (SSE4.2, POPCNT; the default),
	/// `x86-64-v3` (AVX2, FMA, BMI2), `x86-64-v4` (AVX-512) or `native` (the CPU of this machine, which
	/// clang names: its CPU and features are asked once per editor session).
	static class SimdTarget
	{
		public static readonly StringView[?] Levels = .("x86-64", "x86-64-v2", "x86-64-v3", "x86-64-v4", "native");

		public static bool IsLevel(StringView level)
		{
			for (let l in Levels)
				if (l == level)
					return true;
			return false;
		}

		static String sNativeCpu ~ delete _;
		static String sNativeFeatures ~ delete _;
		static System.Threading.Monitor sLock = new .() ~ delete _;

		/// The function attributes of `level`: the CPU name and, for `native`, the features clang gives
		/// it. False (with the reason in the report) when clang cannot name the native CPU.
		public static bool Resolve(StringView clang, StringView level, String outCpu, String outFeatures, BuildReport report)
		{
			outFeatures.Clear();
			if (level != "native")
			{
				outCpu.Set(level.IsEmpty ? "x86-64-v2" : level);
				return true;
			}
			using (sLock.Enter())
			{
				if (sNativeCpu == null && !AskClang(clang, report))
					return false;
				outCpu.Set(sNativeCpu);
				outFeatures.Set(sNativeFeatures);
			}
			return true;
		}

		/// `clang -march=native -S -emit-llvm` of an empty function: its `"target-cpu"` and
		/// `"target-features"` attributes.
		static bool AskClang(StringView clang, BuildReport report)
		{
			String tmp = scope .();
			Path.GetTempPath(tmp);
			String src = scope $"{tmp}treadle-native-{Platform.BfpProcess_GetCurrentId()}.c";
			File.WriteAllText(src, "void treadle_native_probe(void) {}\n").IgnoreError();
			defer File.Delete(src).IgnoreError();
			List<String> args = scope .();
			defer { ClearAndDeleteItems!(args); }
			args.Add(new .(Builder.Target));
			args.Add(new .("-march=native"));
			args.Add(new .("-S"));
			args.Add(new .("-emit-llvm"));
			args.Add(new .(src));
			args.Add(new .("-o"));
			args.Add(new .("-"));
			String o = scope .();
			String e = scope .();
			let code = RunningProcess.Run(clang, args, tmp, o, e, 60000);
			StringView Attr(StringView text, StringView name)
			{
				let key = scope $"\"{name}\"=\"";
				let at = text.IndexOf(key);
				if (at < 0)
					return default;
				let from = at + key.Length;
				let end = text.IndexOf('"', from);
				return (end < 0) ? default : text.Substring(from, end - from);
			}
			let cpu = Attr(o, "target-cpu");
			if (code != 0 || cpu.IsEmpty)
			{
				report.AddError(scope $"simd native: clang could not name this machine's CPU (exit {code}): {e}");
				return false;
			}
			sNativeCpu = new .(cpu);
			sNativeFeatures = new .(Attr(o, "target-features"));
			report.AddLog(scope $"simd native: {sNativeCpu}");
			return true;
		}
	}
}
