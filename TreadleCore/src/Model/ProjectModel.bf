using System;
using System.Collections;
using System.IO;

namespace Treadle.Model
{
	/// One `key tokens...` property kept in file order (build settings of a `config`).
	class Setting
	{
		public String Key = new .() ~ delete _;
		/// The rest of the line after the key (tokens as written).
		public String Value = new .() ~ delete _;

		public this()
		{
		}

		public this(StringView key, StringView value)
		{
			Key.Set(key);
			Value.Set(value);
		}

		public Setting Clone() => new Setting(Key, Value);
	}

	/// `config <Name>` of a project file: build settings (`define`, `checks`, `optimize`, ...)
	/// kept in file order.
	class ProjectConfig
	{
		public String Name = new .() ~ delete _;
		public List<Setting> Settings = new .() ~ DeleteContainerAndItems!(_);
		public RecordExtras Extras = new .() ~ delete _;

		/// `debugFormat dwarf|codeview|both` (docs/Compiler.md 7): the debug info a build of this
		/// config writes; not set = `dwarf`. `codeview` and `both` add a PDB next to the exe (Windows).
		public const String DebugFormatKey = "debugFormat";
		/// `optimize 0|1|2|3|size`: clang's optimisation level for the units and the runtime.
		public const String OptimizeKey = "optimize";
		/// `checks on|off`: the Debug runtime (allocation tracking, the leak report) and the null,
		/// bounds and use-after-free checks, whatever the config's name.
		public const String ChecksKey = "checks";
		/// `define NAME[=value] ...`: names the program reads with `Build.IsDefined` / `Build.Value`.
		public const String DefineKey = "define";
		/// `simd x86-64|x86-64-v2|x86-64-v3|x86-64-v4|native` (SIMD-and-Vectors.md 1.7): the CPU level every
		/// function is compiled for (its `"target-cpu"`, the runtime's `-march`); default `x86-64-v2`.
		public const String SimdKey = "simd";

		/// The first value of `key`, or "" when the config does not set it.
		public StringView Get(StringView key)
		{
			for (let s in Settings)
				if (s.Key == key)
					return s.Value;
			return "";
		}
	}

	/// What a build of one config does (docs/Graph-Format.md 5): the config's keys over the defaults
	/// of its name. A config called `Release` (any case) defaults to `optimize 2` and `checks off`,
	/// any other name (Debug, Profile, ...) to `optimize 0` and `checks on`; `optimize`, `checks`
	/// and `define` lines override that, so the name decides nothing else.
	class BuildSettings
	{
		public String Config = new .() ~ delete _;
		/// `0`, `1`, `2`, `3` or `s` (`optimize size`): the clang `-O` level.
		public String Optimize = new .("0") ~ delete _;
		/// The Debug runtime and the checks.
		public bool Checks = true;
		/// `define` names in file order with their values ("" for a bare name).
		public List<(String name, String value)> Defines = new .() ~ { for (let d in _) { delete d.name; delete d.value; } delete _; };
		/// `debugFormat` as written ("" = dwarf).
		public String DebugFormat = new .() ~ delete _;
		/// `simd` (SIMD-and-Vectors.md 1.7): the x86-64 level every function is compiled for.
		public String Simd = new .(DefaultSimd) ~ delete _;
		public const String DefaultSimd = "x86-64-v2";

		/// Full debug info and no stripping: checks on or no optimisation. A config with an
		/// optimisation level and `checks off` (Release) links stripped, with line tables only.
		public bool DebugInfo => Checks || Optimize == "0";

		/// One line for the build stamps: everything above that changes the code.
		public void Stamp(String outText)
		{
			outText.AppendF("O{} checks {}", Optimize, Checks ? "on" : "off");
			if (Simd != DefaultSimd)
				outText.AppendF(" simd {}", Simd);
			for (let d in Defines)
				outText.AppendF(" -D{}={}", d.name, d.value);
		}

		public bool IsDefined(StringView name)
		{
			for (let d in Defines)
				if (d.name == name)
					return true;
			return false;
		}

		/// The value of `define name=value` ("" for a bare name or an undefined one).
		public StringView Value(StringView name)
		{
			for (let d in Defines)
				if (d.name == name)
					return d.value;
			return "";
		}

		void ClearDefines()
		{
			for (let d in Defines)
			{
				delete d.name;
				delete d.value;
			}
			Defines.Clear();
		}

		/// Fills the settings of config `config` of `project` (null, or a project without that
		/// config: the name's defaults). A value that does not parse is named in `outErrors` (may be
		/// null) and leaves the default.
		public void Resolve(ProjectFile project, StringView config, List<String> outErrors)
		{
			Config.Set(config);
			let release = config.Equals("Release", true);
			Optimize.Set(release ? "2" : "0");
			Checks = !release;
			ClearDefines();
			DebugFormat.Clear();
			Simd.Set(DefaultSimd);
			let c = project?.FindConfig(config);
			if (c == null)
				return;
			for (let s in c.Settings)
			{
				var v = StringView(s.Value);
				v.Trim();
				if (s.Key == ProjectConfig.OptimizeKey)
				{
					if (v == "0" || v == "1" || v == "2" || v == "3")
						Optimize.Set(v);
					else if (v == "size" || v == "s")
						Optimize.Set("s");
					else
						outErrors?.Add(new $"config {config}: optimize '{v}' is not 0, 1, 2, 3 or size");
				}
				else if (s.Key == ProjectConfig.SimdKey)
				{
					if (v == "x86-64" || v == "x86-64-v2" || v == "x86-64-v3" || v == "x86-64-v4" || v == "native")
						Simd.Set(v);
					else
						outErrors?.Add(new $"T1094: config {config}: simd '{v}' is not x86-64, x86-64-v2, x86-64-v3, x86-64-v4 or native");
				}
				else if (s.Key == ProjectConfig.ChecksKey)
				{
					if (v == "on")
						Checks = true;
					else if (v == "off")
						Checks = false;
					else
						outErrors?.Add(new $"config {config}: checks '{v}' is not on or off");
				}
				else if (s.Key == ProjectConfig.DefineKey)
				{
					for (var tok in v.Split(' ', .RemoveEmptyEntries))
					{
						tok.Trim();
						StringView name = tok;
						StringView value = "";
						let eq = tok.IndexOf('=');
						if (eq >= 0)
						{
							name = tok.Substring(0, eq);
							value = tok.Substring(eq + 1);
						}
						bool ident = !name.IsEmpty && !name[0].IsDigit;
						for (let ch in name.RawChars)
							ident &= ch.IsLetterOrDigit || ch == '_';
						if (!ident)
						{
							outErrors?.Add(new $"config {config}: define '{tok}' is not NAME or NAME=value");
							continue;
						}
						bool replaced = false;
						for (let d in Defines)
							if (d.name == name)
							{
								d.value.Set(value);
								replaced = true;
							}
						if (!replaced)
							Defines.Add((new String(name), new String(value)));
					}
				}
				else if (s.Key == ProjectConfig.DebugFormatKey && DebugFormat.IsEmpty)
					DebugFormat.Set(v);
			}
		}
	}

	/// A `.tproj` file (Graph-Format.md 5): the project's name, output kind, entry type,
	/// dependencies, C import sets, configs and source folders.
	class ProjectFile
	{
		/// The format version in the file's header when it was read (older ones are migrated on read).
		public int32 FormatVersion;
		public String Name = new .() ~ delete _;
		/// `console`, `windowed` or `library` ("" = not written: console).
		public String Kind = new .() ~ delete _;

		public const String KindConsole = "console";
		public const String KindWindowed = "windowed";
		public const String KindLibrary = "library";

		/// The project's kind, "" read as `console`; false for a word that is none of the three.
		public bool KindIs(out StringView outKind)
		{
			outKind = Kind.IsEmpty ? KindConsole : (StringView)Kind;
			return outKind == KindConsole || outKind == KindWindowed || outKind == KindLibrary;
		}
		/// The entry type (its static `Main` is Program Start); null = none.
		public TypeRef Entry ~ delete _;
		public String Output = new .() ~ delete _;
		public String Version = new .() ~ delete _;
		/// `namespace A.B`: the project's root namespace, which New Type proposes (with the sub-folder
		/// path under a source folder after it); "" = not written.
		public String Namespace = new .() ~ delete _;
		public RecordExtras Extras = new .() ~ delete _;
		/// `depends <path>`: graph library projects compiled with this one.
		public List<String> Depends = new .() ~ DeleteContainerAndItems!(_);
		/// `cimport <path>`: C import sets.
		public List<String> CImports = new .() ~ DeleteContainerAndItems!(_);
		public List<ProjectConfig> Configs = new .() ~ DeleteContainerAndItems!(_);
		/// `source <folder>`: folders scanned for type files (none = the project folder).
		public List<String> Sources = new .() ~ DeleteContainerAndItems!(_);
		/// Comment lines and unknown records at the end of the file.
		public List<String> Tail = new .() ~ DeleteContainerAndItems!(_);

		public ProjectConfig FindConfig(StringView name)
		{
			for (let c in Configs)
				if (c.Name == name)
					return c;
			return null;
		}

		/// Adds a `cimport <path>` line (a path relative to the project file, forward slashes);
		/// false when the project already names that file.
		public bool AddCImport(StringView path)
		{
			String norm = scope .(path);
			norm.Replace('\\', '/');
			for (let c in CImports)
			{
				String have = scope .(c);
				have.Replace('\\', '/');
				if (StringView.Compare(have, norm, true) == 0)
					return false;
			}
			CImports.Add(new String(norm));
			return true;
		}
	}

	/// `import <set>` of a `.cimport` file (Graph-Format.md 6): C headers made into types and nodes.
	class CImportSet
	{
		public String Name = new .() ~ delete _;
		public List<String> Headers = new .() ~ DeleteContainerAndItems!(_);
		/// `include <path>`: header search paths.
		public List<String> Includes = new .() ~ DeleteContainerAndItems!(_);
		/// `define <macro tokens>`: macros for the parse.
		public List<String> Defines = new .() ~ DeleteContainerAndItems!(_);
		/// `lib <name>`: import libraries for the linker.
		public List<String> Libs = new .() ~ DeleteContainerAndItems!(_);
		/// `pure a b c`: functions callable as value nodes.
		public List<String> Pure = new .() ~ DeleteContainerAndItems!(_);
		/// `hide _*`: symbol patterns not offered.
		public List<String> Hide = new .() ~ DeleteContainerAndItems!(_);
		/// `only a b c`: the symbols offered (empty = all).
		public List<String> Only = new .() ~ DeleteContainerAndItems!(_);
		/// `category "C / libc"`; null = not written.
		public String Category ~ delete _;
		public RecordExtras Extras = new .() ~ delete _;

		/// A path of an `include`, `lib` or `bin` line with its variables expanded (docs/C-Import.md,
		/// "Paths and variables"): `${NAME}` is the environment variable NAME, `${NAME:-fallback}` is
		/// the fallback when NAME is unset or empty. A variable that is unset and has no fallback stays
		/// as written, so the error that follows names it.
		public static void ExpandPath(StringView path, String outPath)
		{
			int i = 0;
			while (i < path.Length)
			{
				if (path[i] == '$' && i + 1 < path.Length && path[i + 1] == '{')
				{
					let close = path.IndexOf('}', i + 2);
					if (close > 0)
					{
						let inner = path.Substring(i + 2, close - i - 2);
						StringView name = inner;
						StringView fallback = default;
						bool hasFallback = false;
						let sep = inner.IndexOf(":-");
						if (sep >= 0)
						{
							name = inner.Substring(0, sep);
							fallback = inner.Substring(sep + 2);
							hasFallback = true;
						}
						String value = scope .();
						if (!name.IsEmpty && (Environment.GetEnvironmentVariable(name, value) case .Ok) && !value.IsEmpty)
							outPath.Append(value);
						else if (hasFallback)
							outPath.Append(fallback);
						else
							outPath.Append(path.Substring(i, close - i + 1));
						i = close + 1;
						continue;
					}
				}
				outPath.Append(path[i]);
				i++;
			}
		}

		/// `ExpandPath`, then a relative result taken relative to `setDir` (the folder of the set's
		/// `.cimport` file), with forward slashes.
		public static void ResolvePath(StringView path, StringView setDir, String outPath)
		{
			String expanded = scope .();
			ExpandPath(path, expanded);
			outPath.Clear();
			if (Path.IsPathRooted(expanded))
				outPath.Set(expanded);
			else
				Path.GetAbsolutePath(expanded, setDir, outPath);
			outPath.Replace('\\', '/');
		}
	}

	/// A `.cimport` file: one or more import sets.
	///
	/// Platform variants (docs/C-Import.md, "Platform variants"): `<name>.linux.cimport` next to
	/// `<name>.cimport` is the file used on Linux, `<name>.windows.cimport` the one used on Windows;
	/// the base file is used where it has no variant. A variant holds the same sets (the same
	/// `import` names, so the same `.cdecl` files) with that platform's `include`, `lib` and `bin`.
	/// Where the headers differ (a macro variable such as errno is spelled through another function),
	/// `<set>.linux.cdecl` / `<set>.windows.cdecl` next to the set file is read before `<set>.cdecl`.
	class CImportFile
	{
		/// The format version in the file's header when it was read (older ones are migrated on read).
		public int32 FormatVersion;
		public List<CImportSet> Sets = new .() ~ DeleteContainerAndItems!(_);
		/// Comment lines before the first set (written after the header line).
		public List<String> Lead = new .() ~ DeleteContainerAndItems!(_);
		public List<String> Tail = new .() ~ DeleteContainerAndItems!(_);

#if BF_PLATFORM_WINDOWS
		public const String PlatformSuffix = ".windows.cimport";
		public const String OtherSuffix = ".linux.cimport";
		public const String PlatformCDeclSuffix = ".windows.cdecl";
#else
		public const String PlatformSuffix = ".linux.cimport";
		public const String OtherSuffix = ".windows.cimport";
		public const String PlatformCDeclSuffix = ".linux.cdecl";
#endif

		/// The file to read for `path` on this platform: its variant when there is one, else `path`.
		public static void ForPlatform(StringView path, String outPath)
		{
			outPath.Set(path);
			if (!path.EndsWith(".cimport", .OrdinalIgnoreCase) || path.EndsWith(PlatformSuffix, .OrdinalIgnoreCase) || path.EndsWith(OtherSuffix, .OrdinalIgnoreCase))
				return;
			let variant = scope String()..Append(path, 0, path.Length - ".cimport".Length)..Append(PlatformSuffix);
			if (File.Exists(variant))
				outPath.Set(variant);
		}

		/// False for a file a folder scan leaves out on this platform: another platform's variant, or
		/// a base file whose variant for this platform is next to it (the scan takes the variant).
		public static bool ScanTakes(StringView path)
		{
			if (path.EndsWith(OtherSuffix, .OrdinalIgnoreCase))
				return false;
			if (path.EndsWith(PlatformSuffix, .OrdinalIgnoreCase))
				return true;
			String chosen = scope .();
			ForPlatform(path, chosen);
			return chosen == path;
		}
	}
}
