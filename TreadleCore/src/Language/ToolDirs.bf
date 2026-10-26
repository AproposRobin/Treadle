using System;
using System.IO;

namespace Treadle.Language
{
	/// The folders the editor looks in for its own tools and files (the LLVM toolchain, libclang, the C
	/// runtime, the core library; docs/Toolchain.md, "Where the tools are found"; Security-Review.md
	/// finding 8). Only two places, never a walk up the parent folders:
	///
	///  * the folder of the running exe (a package: `tools\llvm`, `tools\libclang`, `tools\runtime`,
	///    `core` beside `Treadle.exe`);
	///  * in a development build only (no `VERSION.txt` beside the exe), the source tree the exe was
	///    built in, at the one place BeefBuild puts it: `<tree>\build\<Config>_<Platform>\TreadleEditor\`,
	///    so `<tree>` is three folders up and must hold `BeefSpace.toml`.
	///
	/// The environment variables (`TREADLE_LLVM`, `TREADLE_LIBCLANG`, `TREADLE_RUNTIME`, `TREADLE_CORE`)
	/// come first wherever they are read; `Missing` words the message when nothing was found.
	static class ToolDirs
	{
		/// The folder of the running exe.
		public static void ExeDir(String outDir)
		{
			String exe = scope .();
			Environment.GetExecutableFilePath(exe);
			Path.GetDirectoryPath(exe, outDir).IgnoreError();
		}

		/// A package: `VERSION.txt` beside the exe (docs/Releasing.md).
		public static bool IsPackage()
		{
			String dir = scope .();
			ExeDir(dir);
			return File.Exists(scope $"{dir}/VERSION.txt");
		}

		/// The source tree of a development build (`<tree>\build\<Config>_<Platform>\<Project>\` holds
		/// the exe and `<tree>\BeefSpace.toml` exists); false for a package or any other place.
		public static bool DevTree(String outTree)
		{
			if (IsPackage())
				return false;
			String dir = scope .();
			ExeDir(dir);
			String cfg = scope .();
			String build = scope .();
			String tree = scope .();
			if (Path.GetDirectoryPath(dir, cfg) case .Err || Path.GetDirectoryPath(cfg, build) case .Err || Path.GetDirectoryPath(build, tree) case .Err)
				return false;
			String buildName = scope .();
			Path.GetFileName(build, buildName);
			if (!buildName.Equals("build", .OrdinalIgnoreCase) || tree.IsEmpty || !File.Exists(scope $"{tree}/BeefSpace.toml"))
				return false;
			outTree.Set(tree);
			return true;
		}

		/// `<exe folder>/<rel>` when `<exe folder>/<probe>` exists, else `<dev tree>/<rel>` when
		/// `<dev tree>/<probe>` does (`rel` and `probe` relative, `/` separated).
		public static bool Find(StringView rel, StringView probe, String outPath)
		{
			String dir = scope .();
			ExeDir(dir);
			if (File.Exists(scope $"{dir}/{probe}"))
			{
				outPath.Set(scope $"{dir}/{rel}");
				Fix(outPath);
				return true;
			}
			String tree = scope .();
			if (DevTree(tree) && File.Exists(scope $"{tree}/{probe}"))
			{
				outPath.Set(scope $"{tree}/{rel}");
				Fix(outPath);
				return true;
			}
			return false;
		}

		/// The message for a tool that was not found: where it was looked for and the variable that
		/// names another place.
		public static void Missing(StringView what, StringView packaged, StringView devRel, StringView variable, String outText)
		{
			String dir = scope .();
			ExeDir(dir);
			outText.AppendF("{} was not found: looked in {}", what, scope String()..AppendF("{}/{}", dir, packaged)..Replace('/', Path.DirectorySeparatorChar));
			String tree = scope .();
			if (!devRel.IsEmpty && DevTree(tree))
				outText.AppendF(" and {}", scope String()..AppendF("{}/{}", tree, devRel)..Replace('/', Path.DirectorySeparatorChar));
			outText.AppendF(" (no parent folder is searched); set {} to its folder", variable);
		}

		static void Fix(String path)
		{
#if BF_PLATFORM_WINDOWS
			path.Replace('/', '\\');
#endif
		}
	}
}
