using System;
using System.IO;
using System.Collections;

namespace Treadle.Document
{
	/// Treadle's own version. Bump `HostContract` when the command line changes shape.
	static class TreadleInfo
	{
		public const String Version = "0.1.0";
		/// Release channel of this build; shown by --version and the window title.
		public const String Channel = "alpha";
		public const int HostContract = 1;
		public const String Name = "Treadle";

		/// The `--version` line: "Treadle 0.1.0-alpha (host contract 1)". Version and Channel match VERSION.txt
		/// and the [Platform.Windows] versions of TreadleEditor/BeefProj.toml (scripts/package.ps1 checks all three).
		public static void VersionLine(String outText)
		{
			outText.AppendF("{} {}-{} (host contract {})", Name, Version, Channel, HostContract);
		}
	}

	/// The editor's command line:
	///
	///   Treadle.exe [<folder-or-file>] [--file <path>] [--view]
	///   Treadle.exe --build-run <project folder> [--config <name>]
	///   Treadle.exe --format <project-or-file>... [--check]
	///   Treadle.exe --version | --help
	///
	/// Parsing is separate from acting on it.
	class EditorArgs
	{
		public enum Kind
		{
			/// Open the editor (with or without a project).
			Open,
			PrintVersion,
			PrintHelp,
			/// Bad command line: `Error` says why; the process exits with ExitUsage.
			Usage
		}

		public const int ExitOk = 0;
		/// The editor could not start.
		public const int ExitFailed = 1;
		/// Unknown option, missing value, a path that does not exist.
		public const int ExitUsage = 2;

		public Kind Action = .Open;
		public String Error = new .() ~ delete _;
		/// The positional `<folder-or-file>` as given ("" when none).
		public String Path = new .() ~ delete _;
		/// `--file <path>` as given (absolute, or relative to the project folder).
		public String File = new .() ~ delete _;
		public bool View;
		/// `--build-run <project>`: build and run the project, print the program's output and exit code
		/// to the console, then exit (the path is in `Path`).
		public bool BuildRun;
		/// `--config <name>` for --build-run ("" = the editor's default configuration).
		public String Config = new .() ~ delete _;
		/// Everything after `--`: the command line --build-run gives the program.
		public List<String> ProgramArgs = new .() ~ DeleteContainerAndItems!(_);

		public bool IsEmpty => Action == .Open && Path.IsEmpty && File.IsEmpty && !View && !BuildRun;

		public const String Usage = """
			Usage: Treadle.exe [<folder-or-file>] [--file <path>] [--view]
			       Treadle.exe --build-run <project folder> [--config Debug|Release] [-- <program arguments>]
			       Treadle.exe --format <project-or-file>... [--check]
			       Treadle.exe --version | --help

			  <folder-or-file>     a project folder, or a graph file (opens its folder and that file)
			  --file <path>        the file to focus (absolute, or relative to the project folder)
			  --view               read-only: nothing is ever written to the project
			  --build-run <dir>    build and run the project, print its output and exit code, and exit
			  --config <name>      the configuration --build-run builds (Debug or Release)
			  -- <arguments>       the command line --build-run runs the program with (Args of Main)
			  --format <path>      rewrite the type, project and C import files of a folder (or one file)
			                       in canonical form; --check lists the ones that are not and writes nothing
			  --version            print the Treadle version and the host contract number, and exit

			Exit codes: 0 ok, 1 failed (the window could not be created), 2 bad command line,
			3 --build-run: the build failed or the program could not be started; --format: 1 when a file
			does not read or (--check) is not canonical.
			""";

		static bool TakeValue(Span<String> args, ref int i, StringView name, String outValue, EditorArgs result)
		{
			if (i + 1 >= args.Length || args[i + 1].StartsWith("--"))
			{
				result.Action = .Usage;
				result.Error.Set(scope $"{name} needs a value.");
				return false;
			}
			i++;
			outValue.Set(args[i]);
			return true;
		}

		public static void Parse(Span<String> args, EditorArgs result)
		{
			for (int i = 0; i < args.Length; i++)
			{
				let a = args[i];
				if (a == "--")
				{
					for (int k = i + 1; k < args.Length; k++)
						result.ProgramArgs.Add(new String(args[k]));
					return;
				}
				switch (a)
				{
				case "--help", "-h", "/?":
					result.Action = .PrintHelp;
					return;
				case "--version", "-v":
					result.Action = .PrintVersion;
					return;
				case "--view", "-view":
					result.View = true;
				case "--file":
					if (!TakeValue(args, ref i, a, result.File, result)) return;
				case "--build-run":
					if (!TakeValue(args, ref i, a, result.Path, result)) return;
					result.BuildRun = true;
				case "--config":
					if (!TakeValue(args, ref i, a, result.Config, result)) return;
				default:
					if (a.StartsWith("--"))
					{
						result.Action = .Usage;
						result.Error.Set(scope $"Unknown option '{a}'.");
						return;
					}
					if (!result.Path.IsEmpty)
					{
						result.Action = .Usage;
						result.Error.Set(scope $"Only one <folder-or-file> can be given ('{result.Path}', then '{a}').");
						return;
					}
					result.Path.Set(a);
				}
			}
		}
	}

	/// Turns the command line's path into the project folder to open and the file to focus.
	static class ProjectContract
	{
		/// `path` is a folder (the project) or a file (its folder is the project, the file is
		/// focused); `file` overrides the file to focus (absolute, or relative to the folder).
		/// Both outputs are absolute. False with `outError` when `path` does not exist.
		public static bool ResolveTarget(StringView path, StringView file, String outRoot, String outFile, String outError)
		{
			outRoot.Clear();
			outFile.Clear();
			if (!path.IsEmpty)
			{
				String full = scope .();
				Path.GetAbsolutePath(path, Directory.GetCurrentDirectory(.. scope .()), full);
				if (Directory.Exists(full))
					outRoot.Set(full);
				else if (File.Exists(full))
				{
					Path.GetDirectoryPath(full, outRoot);
					outFile.Set(full);
				}
				else
				{
					outError.Set(scope $"'{path}' does not exist.");
					return false;
				}
			}
			if (!file.IsEmpty)
			{
				outFile.Clear();
				if (Path.IsPathRooted(file))
					outFile.Set(file);
				else if (!outRoot.IsEmpty)
					Path.GetAbsolutePath(file, outRoot, outFile);
				else
					Path.GetAbsolutePath(file, Directory.GetCurrentDirectory(.. scope .()), outFile);
				if (outRoot.IsEmpty)
					Path.GetDirectoryPath(outFile, outRoot);
			}
			return true;
		}
	}
}
