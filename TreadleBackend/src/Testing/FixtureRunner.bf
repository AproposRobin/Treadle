using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using Treadle.Backend.IR;
using Treadle.Backend.Driver;

namespace Treadle.Backend.Testing
{
	/// One fixture run in one configuration.
	class FixtureResult
	{
		public String Name = new .() ~ delete _;
		public String Config = new .() ~ delete _;
		public bool Passed;
		/// Why it failed, or a short summary when it passed.
		public String Detail = new .() ~ delete _;
		public String Stdout = new .() ~ delete _;
		public String Stderr = new .() ~ delete _;
		public int ExitCode;
		public double BuildMs;
		public String ExePath = new .() ~ delete _;
	}

	/// Builds IR fixtures (`<name>.tir`) through the driver, runs them and compares stdout, stderr and
	/// the exit code with `<name>.expected`:
	///
	///   == exit [Config]           one line: the code, or !0 for "any non-zero"
	///   == stdout [Config]         the whole stdout, line by line
	///   == stdout-prefix [Config]  stdout starts with these lines
	///   == stderr [Config]         each line appears in stderr, in this order
	///   == args [Config]           the program's command-line arguments, one per line
	///   == only Config             the fixture runs in that configuration only (a Debug check)
	///   == simd <level>            the program's `simd` level (x86-64-v3, ...; default x86-64-v2)
	///
	/// A section without a config applies to both. `#` lines before the first section are comments.
	static class FixtureRunner
	{
		class Expect
		{
			public String Exit = new .() ~ delete _;
			public List<String> Stdout ~ DeleteContainerAndItems!(_);
			public List<String> StdoutPrefix ~ DeleteContainerAndItems!(_);
			public List<String> Stderr ~ DeleteContainerAndItems!(_);
			public List<String> Args ~ DeleteContainerAndItems!(_);
			public String Only = new .() ~ delete _;
			public String Simd = new .() ~ delete _;
		}

		static void ReadExpected(StringView text, StringView config, Expect outE)
		{
			List<String> current = null;
			bool skip = true;
			bool inExit = false;
			for (var line in text.Split('\n'))
			{
				if (line.EndsWith('\r'))
					line.RemoveFromEnd(1);
				if (line.StartsWith("== "))
				{
					var parts = line.Substring(3);
					parts.Trim();
					let space = parts.IndexOf(' ');
					StringView kind = (space < 0) ? parts : parts.Substring(0, space);
					StringView cfg = (space < 0) ? "" : parts.Substring(space + 1);
					if (kind == "only")
					{
						outE.Only.Set(cfg);
						skip = true;
						continue;
					}
					if (kind == "simd")
					{
						outE.Simd.Set(cfg);
						skip = true;
						continue;
					}
					skip = !cfg.IsEmpty && cfg != config;
					inExit = false;
					current = null;
					if (skip)
						continue;
					switch (kind)
					{
					case "exit": inExit = true;
					case "stdout": outE.Stdout = new .(); current = outE.Stdout;
					case "stdout-prefix": outE.StdoutPrefix = new .(); current = outE.StdoutPrefix;
					case "stderr": outE.Stderr = new .(); current = outE.Stderr;
					case "args": outE.Args = new .(); current = outE.Args;
					default: skip = true;
					}
					continue;
				}
				if (skip)
					continue;
				if (inExit)
				{
					if (!line.IsEmpty)
						outE.Exit.Set(line);
					continue;
				}
				current?.Add(new .(line));
			}
			// a trailing empty line of a section is the file's last newline
			for (let l in StringView[?]("stdout", "prefix", "stderr", "args"))
			{
				let list = (l == "stdout") ? outE.Stdout : ((l == "prefix") ? outE.StdoutPrefix : ((l == "args") ? outE.Args : outE.Stderr));
				while (list != null && !list.IsEmpty && list.Back.IsEmpty)
					delete list.PopBack();
			}
		}

		static void Lines(StringView text, List<String> outLines)
		{
			for (var line in text.Split('\n'))
			{
				if (line.EndsWith('\r'))
					line.RemoveFromEnd(1);
				outLines.Add(new .(line));
			}
			while (!outLines.IsEmpty && outLines.Back.IsEmpty)
				delete outLines.PopBack();
		}

		/// Builds and runs one fixture. `workRoot` gets `<name>/<config>/`.
		/// `format`: the debug format of the build (a non-default one builds into `<name>-<format>`).
		public static void Run(StringView kirPath, StringView config, StringView workRoot, FixtureResult r, DebugFormat format = .Dwarf)
		{
			Path.GetFileNameWithoutExtension(kirPath, r.Name);
			r.Config.Set(config);
			String text = scope .();
			if (File.ReadAllText(kirPath, text, true) case .Err)
			{
				r.Detail.AppendF("cannot read {}", kirPath);
				return;
			}
			IRProgram program = scope .();
			List<String> errors = scope .();
			defer { ClearAndDeleteItems!(errors); }
			if (!IRReader.Read(text, program, errors))
			{
				r.Detail.Append("IR errors: ");
				for (let e in errors)
					r.Detail.AppendF("{}; ", e);
				return;
			}
			String expText = scope .();
			String expPath = scope .(kirPath);
			expPath.RemoveFromEnd(4);
			expPath.Append(".expected");
			// `<name>.linux.tir` takes `<name>.linux.expected`, else the base fixture's `<name>.expected`
			if (!File.Exists(expPath) && expPath.EndsWith(".linux.expected"))
			{
				expPath.RemoveFromEnd(".linux.expected".Length);
				expPath.Append(".expected");
			}
			if (File.ReadAllText(expPath, expText, true) case .Err)
			{
				r.Detail.AppendF("no expected file {}", expPath);
				return;
			}
			Expect e = scope .();
			ReadExpected(expText, config, e);
			if (!e.Only.IsEmpty && e.Only != config)
			{
				r.Passed = true;
				r.Detail.AppendF("skipped ({} only)", e.Only);
				return;
			}
			BuildOptions opts = scope .();
			opts.OutDir.AppendF("{}/{}{}{}/{}", workRoot, r.Name, (format == .Dwarf) ? "" : "-", (format == .Dwarf) ? "" : format.Text, config);
			opts.DebugFormat = format;
			opts.Name.Set(r.Name);
			opts.SetConfigDefaults(config);
			opts.SetProgram(program);
			if (!e.Simd.IsEmpty)
				opts.TargetCpu.Set(e.Simd);
			// `<name>.c` next to the fixture is compiled into the program (a C import set's
			// `csource`, which the `.tir` text does not carry)
			String cSource = scope .(kirPath);
			cSource.RemoveFromEnd(4);
			cSource.Append(".c");
			if (!File.Exists(cSource) && cSource.EndsWith(".linux.c"))
			{
				cSource.RemoveFromEnd(".linux.c".Length);
				cSource.Append(".c");
			}
			if (File.Exists(cSource))
				opts.Libs.Add(new String(cSource));
			BuildReport report = scope .();
			let built = Builder.Build(program, opts, report);
			r.BuildMs = report.TotalMs;
			if (!built)
			{
				r.Detail.Append("build failed: ");
				for (let err in report.Errors)
					r.Detail.AppendF("{}; ", err);
				return;
			}
			r.ExePath.Set(report.ExePath);
			// a library (kind library) is run by `<name>.host.c`, a C program compiled by the same
			// clang against the import library (Windows) or the .so (Linux), in the library's folder
			String runExe = scope .(report.ExePath);
			if (program.Kind == .Library)
			{
				String host = scope .(kirPath);
				host.RemoveFromEnd(4);
				if (host.EndsWith(".linux"))
					host.RemoveFromEnd(6);
				host.Append(".host.c");
				runExe.Clear();
				if (!BuildHost(host, opts, r.Name, runExe, r.Detail))
					return;
			}
			List<String> args = scope .();
			if (e.Args != null)
				args.AddRange(e.Args);
			r.ExitCode = RunningProcess.Run(runExe, args, opts.OutDir, r.Stdout, r.Stderr, 30000);
			// compare
			List<String> outLines = scope .();
			defer { ClearAndDeleteItems!(outLines); }
			Lines(r.Stdout, outLines);
			if (!e.Exit.IsEmpty)
			{
				if (e.Exit == "!0")
				{
					if (r.ExitCode == 0)
					{
						r.Detail.Append("exit code 0, expected non-zero");
						return;
					}
				}
				else if (int.Parse(e.Exit) case .Ok(let want))
				{
					if (want != r.ExitCode)
					{
						r.Detail.AppendF("exit code {}, expected {}", r.ExitCode, want);
						return;
					}
				}
			}
			if (e.Stdout != null)
			{
				bool same = e.Stdout.Count == outLines.Count;
				for (int i < Math.Min(e.Stdout.Count, outLines.Count))
					if (e.Stdout[i] != outLines[i])
					{
						same = false;
						r.Detail.AppendF("stdout line {}: '{}', expected '{}'", i + 1, outLines[i], e.Stdout[i]);
						return;
					}
				if (!same)
				{
					r.Detail.AppendF("stdout has {} lines, expected {}", outLines.Count, e.Stdout.Count);
					return;
				}
			}
			if (e.StdoutPrefix != null)
			{
				for (int i < e.StdoutPrefix.Count)
					if (i >= outLines.Count || e.StdoutPrefix[i] != outLines[i])
					{
						r.Detail.AppendF("stdout line {}: '{}', expected '{}'", i + 1, (i < outLines.Count) ? outLines[i] : "<missing>", e.StdoutPrefix[i]);
						return;
					}
			}
			if (e.Stderr != null)
			{
				int from = 0;
				String err = scope .(r.Stderr);
				err.Replace("\r", "");
				for (let want in e.Stderr)
				{
					if (want.IsEmpty)
						continue;
					let at = err.IndexOf(want, from);
					if (at < 0)
					{
						r.Detail.AppendF("stderr lacks '{}'", want);
						return;
					}
					from = at + want.Length;
				}
			}
			r.Passed = true;
			r.Detail.AppendF("exit {}, {} stdout lines, built in {} ms", r.ExitCode, outLines.Count, (int64)Math.Round(r.BuildMs)); // no double formatting off the UI thread (Builder.Ms)
		}

		/// Compiles a library fixture's C host `hostSource` into `<OutDir>/<name>-host(.exe)`, linked
		/// against the library just built. False with `outWhy`.
		static bool BuildHost(StringView hostSource, BuildOptions opts, StringView name, String outExe, String outWhy)
		{
			if (!File.Exists(hostSource))
			{
				outWhy.AppendF("a library fixture needs its C host {}", hostSource);
				return false;
			}
			String clang = scope .();
			ToolchainPaths.Tool("clang", clang);
			outExe.AppendF("{}/{}-host{}", opts.OutDir, name, Builder.ExeExtension);
			List<String> args = scope .();
			defer { ClearAndDeleteItems!(args); }
			args.Add(new .(Builder.Target));
			args.Add(new .("-g"));
			args.Add(new .(hostSource));
#if BF_PLATFORM_WINDOWS
			String implib = scope .();
			Builder.ImportLibrary(opts, implib);
			args.Add(new .(implib));
#else
			args.Add(new .("-fuse-ld=lld"));
			String so = scope .();
			Builder.OutputFile(opts, so);
			args.Add(new .(so));
			args.Add(new $"-Wl,-rpath,{opts.OutDir}");
#endif
			args.Add(new .("-o"));
			args.Add(new .(outExe));
			String o = scope .();
			String e = scope .();
			let code = RunningProcess.Run(clang, args, opts.OutDir, o, e, 60000);
			if (code != 0)
			{
				outWhy.AppendF("the C host did not build (clang exit {}): {}", code, e);
				return false;
			}
			return true;
		}

		/// The line of a node in a unit's `.nodemap` (`<sheetKey> <nodeId> <line>`); 0 when absent.
		public static int32 NodeLine(StringView nodemapPath, StringView sheetKey, StringView nodeId)
		{
			String text = scope .();
			if (File.ReadAllText(nodemapPath, text, true) case .Err)
				return 0;
			for (var line in text.Split('\n'))
			{
				line.Trim();
				var parts = line.Split(' ');
				StringView a = parts.GetNext().GetValueOrDefault();
				StringView b = parts.GetNext().GetValueOrDefault();
				StringView c = parts.GetNext().GetValueOrDefault();
				if (a == sheetKey && b == nodeId)
					return int32.Parse(c).GetValueOrDefault();
			}
			return 0;
		}

		/// Runs lldb from llvm-mingw in batch mode (--no-lldbinit) on a Debug build: a breakpoint on
		/// `<lstFile>:<line>`, run, locals, backtrace, kill. True when it stopped there.
		public static bool LldbCheck(StringView exe, StringView lstFile, int32 line, StringView expectFrame, String outDetail, String outTranscript)
		{
			String lldb = scope .();
			ToolchainPaths.Tool("lldb", lldb);
			if (!File.Exists(lldb))
			{
				outDetail.AppendF("lldb not found at {}", lldb);
				return false;
			}
			List<String> args = scope .();
			defer { ClearAndDeleteItems!(args); }
			args.Add(new .("--no-lldbinit"));
			args.Add(new .("-b"));
			args.Add(new .("-o"));
			args.Add(new $"breakpoint set -f {lstFile} -l {line}");
			args.Add(new .("-o"));
			args.Add(new .("run"));
			args.Add(new .("-o"));
			args.Add(new .("frame variable"));
			args.Add(new .("-o"));
			args.Add(new .("bt 2"));
			args.Add(new .("-o"));
			args.Add(new .("kill"));
			args.Add(new .("--"));
			args.Add(new .(exe));
			String dir = scope .();
			Path.GetDirectoryPath(exe, dir);
			String o = scope .();
			String e = scope .();
			let code = RunningProcess.Run(lldb, args, dir, o, e, 90000);
			outTranscript.Append(o);
			outTranscript.Append(e);
			String at = scope $"{lstFile}:{line}";
			let resolved = o.Contains(scope $"at {at}");
			let stopped = o.Contains("stop reason = breakpoint");
			let frame = expectFrame.IsEmpty || o.Contains(expectFrame);
			if (resolved && stopped && frame)
			{
				outDetail.AppendF("lldb stopped at {} in {}", at, expectFrame);
				return true;
			}
			outDetail.AppendF("lldb exit {}: breakpoint resolved {}, stopped {}, frame {}", code, resolved, stopped, frame);
			return false;
		}

		/// Runs lldb in batch mode (--no-lldbinit) on `exe` with the commands in order (`-o` each);
		/// returns lldb's exit code, the transcript in outTranscript.
		public static int LldbScript(StringView exe, Span<StringView> commands, String outTranscript)
		{
			String lldb = scope .();
			ToolchainPaths.Tool("lldb", lldb);
			if (!File.Exists(lldb))
			{
				outTranscript.AppendF("lldb not found at {}", lldb);
				return -1;
			}
			List<String> args = scope .();
			defer { ClearAndDeleteItems!(args); }
			args.Add(new .("--no-lldbinit"));
			args.Add(new .("-b"));
			for (let c in commands)
			{
				args.Add(new .("-o"));
				args.Add(new .(c));
			}
			args.Add(new .("--"));
			args.Add(new .(exe));
			String dir = scope .();
			Path.GetDirectoryPath(exe, dir);
			String o = scope .();
			String e = scope .();
			let code = RunningProcess.Run(lldb, args, dir, o, e, 90000);
			outTranscript.Append(o);
			outTranscript.Append(e);
			return code;
		}

		/// The stop locations of an lldb transcript in order: `<file>:<line>` of every `frame #0` line
		/// lldb prints when the process stops (`... at Dbg.Program.lst:4:1`).
		public static void StopLines(StringView transcript, List<String> outStops)
		{
			for (var line in transcript.Split('\n'))
			{
				if (!line.Contains("frame #0:"))
					continue;
				int at = -1;
				for (int i = line.Length - 4; i >= 0; i--)
					if (line.Substring(i, 4) == " at ")
					{
						at = i;
						break;
					}
				if (at < 0)
					continue;
				var loc = line.Substring(at + 4);
				loc.Trim();
				// file:line:column -> file:line
				let c2 = loc.LastIndexOf(':');
				if (c2 > 0)
				{
					let c1 = loc.Substring(0, c2).LastIndexOf(':');
					if (c1 > 0)
						loc = loc.Substring(0, c2);
				}
				outStops.Add(new .(loc));
			}
		}
	}
}
