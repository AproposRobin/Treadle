using System;
using System.Collections;
using System.IO;
using ImGui;
using Treadle.Document;
using Treadle.Model;
using Treadle.Format;

namespace Treadle.Editor
{
	/// The project file (`.tproj`, Graph-Format.md 5) in the editor: New Project writes one with
	/// its first type, the Project Browser shows it as the root's first tile with the active config,
	/// and Properties shows its settings when that tile is selected. The active config (Debug /
	/// Release) is what Build and Run build; it is kept in settings.json ("session": activeConfig).
	extension EditorApp
	{
		/// The `.tproj` file `Project` was read from ("" when the folder has none).
		public String ProjectPath = new .() ~ delete _;
		String mActiveConfig = new .("Debug") ~ delete _;

		/// The config Build and Run use: the one chosen in the Project Browser or Properties, if the
		/// project has it; else the project's first config; else Debug.
		public StringView ActiveConfig
		{
			get
			{
				if (Project == null || Project.Configs.IsEmpty || Project.FindConfig(mActiveConfig) != null)
					return mActiveConfig;
				return Project.Configs[0].Name;
			}
		}

		public void SetActiveConfig(StringView name)
		{
			if (mActiveConfig == name)
				return;
			mActiveConfig.Set(name);
			SaveSettings();
			SetStatus(scope $"Active config: {name}");
		}

		/// The default contents of a new project file: a console program whose entry type is
		/// `<ns>.Program`, Debug and Release configs, types under `Source`.
		public static void DefaultProjectFile(StringView name, StringView ns, ProjectFile outP)
		{
			outP.Name.Set(name);
			outP.Kind.Set("console");
			outP.Entry = TypeRef.Parse(scope $"{ns}.Program");
			outP.Version.Set("0.1.0");
			outP.Namespace.Set(ns);
			ProjectConfig debug = new .();
			debug.Name.Set("Debug");
			debug.Settings.Add(new Setting("checks", "on"));
			debug.Settings.Add(new Setting("optimize", "0"));
			outP.Configs.Add(debug);
			ProjectConfig release = new .();
			release.Name.Set("Release");
			release.Settings.Add(new Setting("optimize", "2"));
			release.Settings.Add(new Setting("checks", "off"));
			outP.Configs.Add(release);
			outP.Sources.Add(new String("Source"));
		}

		/// A name made into an identifier (the namespace of a new project's types).
		static void IdentifierOf(StringView name, String outId)
		{
			for (let c in name.RawChars)
				outId.Append((c.IsLetterOrDigit || c == '_') ? c : '_');
			if (outId.IsEmpty || outId[0].IsDigit)
				outId.Insert(0, '_');
		}

		/// The comment box over Program.Main's Entry node in a new project.
		public const String StartHint = "Your program starts here. Run it with Ctrl+F5 (it builds first); F7 only builds.";

		/// The New Project template's type: a static class Program in `ns` with a static Main (Program
		/// Start) and, over Main's Entry node, the comment box `StartHint`.
		public static void ProgramTemplate(TypeDocument doc, StringView projectName, StringView ns)
		{
			doc.InitType("Program", .Class, ns);
			doc.Header.Static = true;
			doc.Header.Doc = new String(scope $"Program Start of {projectName}: Main runs when the program starts.");
			let main = doc.AddFunction("Main");
			main.Member.Static = true;
			GraphComment hint = new .();
			hint.MethodKey.Set(main.Key);
			hint.Text.Set(StartHint);
			hint.X = -16;
			hint.Y = -88;
			hint.W = 528;
			hint.H = 64;
			doc.Comments.Add(hint);
		}

		/// New Project's files in `folder` (which exists and is empty): `<name>.tproj` and
		/// `Source/Program.treadle` (a static class with an empty static Main: Program Start).
		/// `outTypePath` is the type file to open first.
		public bool CreateProjectFiles(StringView folder, StringView name, String outTypePath, String outError)
		{
			String ns = scope .();
			IdentifierOf(name, ns);
			ProjectFile p = scope .();
			DefaultProjectFile(name, ns, p); // the typed name, quoted by the codec when it needs it; the namespace is its identifier form
			String text = scope .();
			ProjectCodec.WriteProject(p, text);
			String projPath = scope .();
			JoinPath(folder, scope $"{name}.tproj", projPath);
			if (FileSafety.AtomicWrite(projPath, text, false, outError) case .Err)
				return false;
			String src = scope .();
			// Backups are old copies; layouts stay committed (positions are worth sharing: Graph-Format.md 4).
			String ignorePath = scope .();
			JoinPath(folder, ".gitignore", ignorePath);
			if (!File.Exists(ignorePath))
				FileSafety.AtomicWrite(ignorePath, "backup/\n", false, scope String()).IgnoreError();
			JoinPath(folder, "Source", src);
			if (Directory.CreateDirectory(src) case .Err)
			{
				outError.Set(scope $"Could not create {src}");
				return false;
			}
			let doc = scope TypeDocument(Language);
			JoinPath(src, scope $"Program{GraphExtension}", doc.FilePath);
			ProgramTemplate(doc, name, ns);
			if (!doc.TrySave(outError))
				return false;
			outTypePath.Set(doc.FilePath);
			return true;
		}

		/// Writes `Project` back to its file (after an edit in Properties).
		bool SaveProjectFile()
		{
			if (Project == null || ProjectPath.IsEmpty || !CheckWritable())
				return false;
			String text = scope .();
			ProjectCodec.WriteProject(Project, text);
			String why = scope .();
			if (FileSafety.AtomicWrite(ProjectPath, text, true, why) case .Err)
			{
				SetStatus(scope $"Could not save {ProjectPath}: {why}", .Warning);
				return false;
			}
			SetStatus(scope $"Saved {ProjectPath}");
			return true;
		}

		/// Shows the project's settings in Properties (the Project Browser's project tile).
		public void SelectProjectSettings()
		{
			SelectOutline(.Project);
		}

		static StringView[?] sProjectKinds = .("console", "windowed", "library");

		/// Properties for the project file: name, kind, entry type, output, version, the active
		/// config and every config's settings, C import sets, dependencies and source folders.
		void DrawProjectSettings()
		{
			let p = Project;
			DetailsHeader(Icon.Package, Look.AccentOrange, p.Name, "Project");
			if (!PropertyGrid.Begin("##projectsettings"))
				return;
			String v = scope .();
			bool changed = false;
			if (PropertyGrid.Section("Project", true))
			{
				if (TsText("Name", "##pjname", p.Name, v, "The project's name (the file keeps its own name)"))
				{
					p.Name.Set(IdentifierOf(v, .. scope String())); // one token in the file
					changed = true;
				}
				int32 kind = 0;
				for (int32 k = 0; k < sProjectKinds.Count; k++)
					if (p.Kind == sProjectKinds[k])
						kind = k;
				if (PropertyGrid.ComboRow("Kind", "##pjkind", ref kind, sProjectKinds, "console: a program with a console. windowed: a program without one. library: types other projects use."))
				{
					p.Kind.Set(sProjectKinds[kind]);
					changed = true;
				}
				v.Clear();
				String entry = scope .();
				p.Entry?.ToString(entry);
				if (TsText("Entry Type", "##pjentry", entry, v, "The type whose static Main is Program Start", "Namespace.Program"))
				{
					DeleteAndNullify!(p.Entry);
					v.Trim();
					if (!v.IsEmpty)
						p.Entry = TypeRef.Parse(v);
					changed = true;
				}
				v.Clear();
				if (TsText("Output", "##pjout", p.Output, v, "Where Build writes the program, relative to the project folder (empty: build/<config>)", "build/<config>"))
				{
					p.Output.Set(v);
					changed = true;
				}
				v.Clear();
				if (TsText("Version", "##pjver", p.Version, v, "The project's version (major.minor.patch)", "0.1.0"))
				{
					p.Version.Set(v);
					changed = true;
				}
				v.Clear();
				if (TsText("Namespace", "##pjns", p.Namespace, v, "The root namespace New Class, New Struct... propose (a type in a sub-folder of a source folder adds the folder's path); each type can change its own in Type Settings", "the project name"))
				{
					v.Trim();
					p.Namespace.Set(v);
					changed = true;
				}
				PropertyGrid.InfoRow("File", ProjectPath, ProjectPath);
			}
			if (PropertyGrid.Section("Configs", true))
			{
				List<StringView> names = scope .();
				int32 active = 0;
				for (let c in p.Configs)
				{
					if (c.Name == ActiveConfig)
						active = (int32)names.Count;
					names.Add(c.Name);
				}
				if (names.IsEmpty)
					PropertyGrid.Info("No configs: Build uses Debug.");
				else if (PropertyGrid.ComboRow("Active Config", "##pjactive", ref active, names, "The config Build and Run use"))
					SetActiveConfig(names[active]);
			}
			for (let c in p.Configs)
			{
				Gui.PushID((int32)@c.Index);
				if (PropertyGrid.Section(scope $"Config: {c.Name}{(c.Name == ActiveConfig) ? "  (active)" : ""}###pjcfg{@c.Index}", c.Name == ActiveConfig))
					changed |= DrawConfigRows(c, @c.Index);
				Gui.PopID();
			}
			if (PropertyGrid.Section("C Imports", true))
				changed |= DrawCImportRows(p);
			if (PropertyGrid.Section("Files", true))
			{
				if (p.Sources.IsEmpty)
					PropertyGrid.InfoRow("Source", "(the project folder)");
				for (let s in p.Sources)
					PropertyGrid.InfoRow((@s.Index == 0) ? "Source" : "", s, "A folder scanned for type files");
				for (let d in p.Depends)
					PropertyGrid.InfoRow((@d.Index == 0) ? "Depends" : "", d, "A library project built with this one");
			}
			PropertyGrid.End();
			if (changed)
				SaveProjectFile();
		}

		// ------------------------------------------------------------------ config rows

		/// The config keys the project page edits (Graph-Format.md 5): the ones BuildSettings reads. There is no
		/// `lto` key: an optimised config (optimize above 0) always compiles and links with ThinLTO (Compiler.md 6).
		public const String cOptimizeKey = ProjectConfig.OptimizeKey;
		public const String cChecksKey = ProjectConfig.ChecksKey;
		public const String cDefineKey = ProjectConfig.DefineKey;
		public const String cDebugFormatKey = ProjectConfig.DebugFormatKey;

		static StringView[?] sOptimizeValues = .("0", "1", "2", "3", "size");
		static StringView[?] sOptimizeNames = .("0: none", "1: basic", "2: full", "3: aggressive", "size: small code");
		static StringView[?] sDebugFormats = .("dwarf", "codeview", "both");

		/// What `key` is in config `c` when the file does not set it (the name's defaults: a config
		/// called Release optimises at 2 without checks, any other at 0 with them).
		public static StringView ConfigDefault(ProjectConfig c, StringView key)
		{
			bool release = StringView(c.Name).Equals("Release", true);
			switch (key)
			{
			case cOptimizeKey: return release ? "2" : "0";
			case cChecksKey: return release ? "off" : "on";
			case cDebugFormatKey: return "dwarf";
			default: return "";
			}
		}

		/// The value `key` has in `c`: the file's, else the default.
		public static StringView ConfigValue(ProjectConfig c, StringView key)
		{
			for (let s in c.Settings)
				if (s.Key == key)
					return s.Value;
			return ConfigDefault(c, key);
		}

		/// Sets `key` to `value` in `c` (the first line of that key changes, later ones go; a new key is
		/// added at the end). A value equal to the default with no line for it writes nothing. True when
		/// the config changed.
		public static bool SetConfigValue(ProjectConfig c, StringView key, StringView value)
		{
			Setting first = null;
			for (int i = c.Settings.Count - 1; i >= 0; i--)
			{
				let s = c.Settings[i];
				if (s.Key != key)
					continue;
				if (first != null)
				{
					c.Settings.Remove(first);
					delete first;
				}
				first = s;
			}
			if (first != null)
			{
				if (first.Value == value)
					return false;
				first.Value.Set(value);
				return true;
			}
			if (value == ConfigDefault(c, key))
				return false;
			c.Settings.Add(new Setting(key, value));
			return true;
		}

		/// The names of `c`'s `define` lines in file order (`NAME` or `NAME=value`, one per entry).
		public static void ConfigDefines(ProjectConfig c, List<String> outDefines)
		{
			for (let s in c.Settings)
				if (s.Key == cDefineKey)
					for (let tok in StringView(s.Value).Split(' ', .RemoveEmptyEntries))
						outDefines.Add(new String(tok));
		}

		/// `c`'s defines become `defines`, one `define` line each, where the first one was (else at the end).
		public static bool SetConfigDefines(ProjectConfig c, List<String> defines)
		{
			List<String> now = scope .();
			defer { ClearAndDeleteItems!(now); }
			ConfigDefines(c, now);
			bool same = now.Count == defines.Count;
			for (int i < Math.Min(now.Count, defines.Count))
				same &= now[i] == defines[i];
			if (same)
				return false;
			int at = -1;
			for (int i = c.Settings.Count - 1; i >= 0; i--)
				if (c.Settings[i].Key == cDefineKey)
				{
					at = i;
					delete c.Settings[i];
					c.Settings.RemoveAt(i);
				}
			if (at < 0)
				at = c.Settings.Count;
			for (let d in defines)
				c.Settings.Insert(at + @d.Index, new Setting(cDefineKey, d));
			return true;
		}

		/// A define as the build reads it: NAME or NAME=value, NAME an identifier.
		static bool ValidDefine(StringView d)
		{
			let eq = d.IndexOf('=');
			let name = (eq >= 0) ? d.Substring(0, eq) : d;
			if (name.IsEmpty || name[0].IsDigit)
				return false;
			for (let ch in name.RawChars)
				if (!ch.IsLetterOrDigit && ch != '_')
					return false;
			return true;
		}

		/// A combo row over `values` (shown as `names`) bound to `key` of `c`; true when it changed.
		bool ConfigComboRow(ProjectConfig c, int cfgIndex, StringView label, StringView key, Span<StringView> values, Span<StringView> names, StringView tip)
		{
			StringView cur = ConfigValue(c, key);
			int32 index = -1;
			for (int32 i < (int32)values.Length)
				if (values[i] == cur)
					index = i;
			if (index < 0)
			{
				// A value the row does not know: shown as written, picking one replaces it.
				PropertyGrid.InfoRow(label, scope $"{cur} (not one of the choices)", tip, Look.Warning);
				index = 0;
			}
			if (!PropertyGrid.ComboRow(label, scope $"##pj{key}{cfgIndex}", ref index, names, tip))
				return false;
			return SetConfigValue(c, key, values[index]);
		}

		/// The rows of one config: Optimize, Checks, Defines, Debug Format, Link-Time Optimization and any
		/// other key as a text row. True when the config changed (the caller saves the project file).
		bool DrawConfigRows(ProjectConfig c, int cfgIndex)
		{
			bool changed = false;
			if (c.Name != ActiveConfig && PropertyGrid.ButtonRow("", scope $"{Icon.CircleCheck} Make Active", "Build and Run use this config"))
				SetActiveConfig(c.Name);
			changed |= ConfigComboRow(c, cfgIndex, "Optimize", cOptimizeKey, sOptimizeValues, sOptimizeNames,
				"clang's optimisation level for the program and the runtime (optimize). Release defaults to 2, any other config to 0.");
			bool checks = ConfigValue(c, cChecksKey) != "off";
			if (PropertyGrid.CheckRow("Checks", scope $"##pjchecks{cfgIndex}", ref checks,
				"The Debug runtime: null, bounds and use-after-free checks naming the node, the leak report at exit (checks on|off). Release defaults to off."))
				changed |= SetConfigValue(c, cChecksKey, checks ? "on" : "off");
			// Defines: one row each (an X removes it), then a field that adds NAME or NAME=value.
			List<String> defines = scope .();
			defer { ClearAndDeleteItems!(defines); }
			ConfigDefines(c, defines);
			String v = scope .();
			for (int i < defines.Count)
			{
				Gui.PushID((int32)(800 + i));
				let id = scope $"##pjdef{cfgIndex}_{i}";
				PropertyGrid.Row((i == 0) ? "Defines" : "", "A name the program reads with Build.IsDefined(\"NAME\") and Build.Value(\"NAME\") (define NAME or NAME=value)");
				let buf = TsBuf(id, defines[i]);
				float bw = Gui.igGetFrameHeight();
				Gui.igSetNextItemWidth(Math.Max(40 * Look.Scale, Gui.igGetContentRegionAvail().x - bw - 4 * Look.Scale));
				bool done = PropertyGrid.Text(id, buf, ?, false, null, "NAME=value");
				bool active = Gui.igIsItemActive();
				Gui.SameLine(0, 4 * Look.Scale);
				bool remove = Gui.Button(Icon.X, .(bw, 0));
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip(scope $"Remove {defines[i]}");
				Gui.PopID();
				if (remove)
				{
					delete defines[i];
					defines.RemoveAt(i);
					ClearTsBufs();
					return SetConfigDefines(c, defines) | changed;
				}
				if (done && buf != defines[i])
				{
					v.Set(buf);
					v.Trim();
					if (v.IsEmpty)
					{
						delete defines[i];
						defines.RemoveAt(i);
					}
					else if (!ValidDefine(v))
					{
						SetStatus(scope $"'{v}' is not NAME or NAME=value", .Warning);
						buf.Set(defines[i]);
						continue;
					}
					else
						defines[i].Set(v);
					ClearTsBufs();
					return SetConfigDefines(c, defines) | changed;
				}
				if (!done && !active && buf != defines[i])
					buf.Set(defines[i]);
			}
			v.Clear();
			if (TsText(defines.IsEmpty ? "Defines" : "", scope $"##pjdefadd{cfgIndex}", "", v, "Add a define: NAME or NAME=value (several separated by spaces)", "add NAME=value"))
			{
				bool added = false;
				for (let tok in v.Split(' ', .RemoveEmptyEntries))
				{
					if (!ValidDefine(tok))
					{
						SetStatus(scope $"'{tok}' is not NAME or NAME=value", .Warning);
						continue;
					}
					defines.Add(new String(tok));
					added = true;
				}
				ClearTsBufs();
				if (added)
					changed |= SetConfigDefines(c, defines);
			}
			changed |= ConfigComboRow(c, cfgIndex, "Debug Format", cDebugFormatKey, sDebugFormats, sDebugFormats,
				"The debug info a build writes (debugFormat): dwarf for the editor's debugger, codeview for Windows debuggers (a PDB next to the program), both");
			// Keys the rows above do not cover, as written.
			for (let s in c.Settings)
			{
				if (s.Key == cOptimizeKey || s.Key == cChecksKey || s.Key == cDefineKey || s.Key == cDebugFormatKey)
					continue;
				v.Clear();
				if (TsText(s.Key, scope $"##pjset{cfgIndex}_{@s.Index}", s.Value, v, "A setting the rows above do not cover, as the project file writes it"))
				{
					s.Value.Set(v);
					changed = true;
				}
			}
			return changed;
		}
	}
}
