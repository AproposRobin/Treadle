using System;
using System.IO;

namespace Treadle.Language
{
	/// Where the LLVM toolchain is (docs/Toolchain.md), for the back end, the C import and the
	/// debugger alike.
	///
	/// Windows (the pinned llvm-mingw): `TREADLE_LLVM`, else `tools/llvm`
	/// next to the running exe (the trimmed copy a package ships, docs/Releasing.md), else
	/// `tools/llvm-mingw` of the source tree of a development build (ToolDirs: the fixed build layout, no
	/// walk up the parent folders; not committed), else
	/// the folder named by `TREADLE_DEV_LLVM` (`DevFallbackVar`: a developer-machine convenience, a
	/// shared llvm-mingw outside the repository, docs/Toolchain.md). `TREADLE_NO_FALLBACK=1` skips that
	/// last one (and the other developer fallbacks: `NoFallback`), so a package can be tested on a
	/// developer machine with only its own contents.
	///
	/// Linux (the distribution's LLVM, docs/Linux.md): `TREADLE_LLVM` (a root holding `bin/clang`),
	/// else `tools/llvm` next to the running exe, else `/usr/lib/llvm-22` (the version Beef is built
	/// against), else the newest `/usr/lib/llvm-<N>` with a `bin/clang`, else `/usr` (the `clang` on
	/// the system path).
	static class LlvmRoot
	{
		/// The environment variable of the developer-machine last fallback (Windows; skipped with
		/// `TREADLE_NO_FALLBACK`).
		public const String DevFallbackVar = "TREADLE_DEV_LLVM";
#if BF_PLATFORM_WINDOWS
		/// The suffix of an executable file name on the platform the editor runs on (and builds for).
		public const String ExeSuffix = ".exe";
#else
		public const String ExeSuffix = "";
#endif
		/// The LLVM major version tried first on Linux.
		public const int PreferredLinuxVersion = 22;

		/// True when `TREADLE_NO_FALLBACK` is set (and not "0"), or in a package (`VERSION.txt` beside the exe):
		/// no machine-specific last fallback is used.
		public static bool NoFallback
		{
			get
			{
				String v = scope .();
				if (ToolDirs.IsPackage())
					return true; // a package uses its own tools only (Security-Review.md finding 8)
				return Environment.GetEnvironmentVariable("TREADLE_NO_FALLBACK", v) case .Ok && !v.IsEmpty && v != "0";
			}
		}

		public static void Get(String outRoot)
		{
			outRoot.Clear();
			for (let name in StringView[?]("TREADLE_LLVM"))
			{
				if (Environment.GetEnvironmentVariable(name, outRoot) case .Ok && !outRoot.IsEmpty)
					return;
				outRoot.Clear();
			}
			String exe = scope .();
			Environment.GetExecutableFilePath(exe);
			String exeDir = scope .();
			Path.GetDirectoryPath(exe, exeDir).IgnoreError();
#if BF_PLATFORM_WINDOWS
			String packaged = scope $"{exeDir}\\tools\\llvm";
			if (File.Exists(scope $"{packaged}\\bin\\clang.exe"))
			{
				outRoot.Set(packaged);
				return;
			}
			// a development build: the source tree's tools\llvm-mingw (ToolDirs: no parent folder walk)
			String tree = scope .();
			if (ToolDirs.DevTree(tree) && File.Exists(scope $"{tree}\\tools\\llvm-mingw\\bin\\clang.exe"))
			{
				outRoot.AppendF("{}\\tools\\llvm-mingw", tree);
				return;
			}
			if (!NoFallback && Environment.GetEnvironmentVariable(DevFallbackVar, outRoot) case .Ok && !outRoot.IsEmpty)
				return;
			// Without a fallback the packaged location is named, so a missing tool says where it was expected.
			outRoot.Set(packaged);
#else
			String packaged = scope $"{exeDir}/tools/llvm";
			if (File.Exists(scope $"{packaged}/bin/clang"))
			{
				outRoot.Set(packaged);
				return;
			}
			if (File.Exists(scope $"/usr/lib/llvm-{PreferredLinuxVersion}/bin/clang"))
			{
				outRoot.AppendF("/usr/lib/llvm-{}", PreferredLinuxVersion);
				return;
			}
			for (int v = 40; v >= 14; v--)
				if (File.Exists(scope $"/usr/lib/llvm-{v}/bin/clang"))
				{
					outRoot.AppendF("/usr/lib/llvm-{}", v);
					return;
				}
			outRoot.Set("/usr");
#endif
		}

		/// `<root>/bin/<name>` with the platform's executable suffix (`clang` -> `clang.exe` on
		/// Windows).
		public static void Tool(StringView name, String outPath)
		{
			String root = scope .();
			Get(root);
#if BF_PLATFORM_WINDOWS
			outPath.AppendF("{}\\bin\\{}{}", root, name, ExeSuffix);
#else
			outPath.AppendF("{}/bin/{}", root, name);
#endif
		}
	}
}
