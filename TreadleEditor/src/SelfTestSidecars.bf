// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using System.IO;
using Treadle.Document;
using Treadle.Format;
using Treadle.Graph;
using Treadle.Model;
using System.Threading;

namespace Treadle.Editor
{
	/// The `codec` self test's layout and backup folders (docs/Graph-Format.md 4 and 5): the path
	/// mapping, a save into them, a missing layout, custom folder keys, the backup beside nothing,
	/// and the move of old beside-the-source sidecars.
	extension EditorApp
	{
		static bool SameFile(StringView a, StringView b)
		{
			String x = scope .(a), y = scope .(b);
			x.Replace('\\', '/');
			y.Replace('\\', '/');
			return ProjectIndex.SamePath(x, y);
		}

		static bool ReadAll(StringView path, String outText) => File.ReadAllText(path, outText, true) case .Ok;

		void SelfTestSidecars(StringView temp)
		{
			String root = scope $"{temp}/sidecars";
			Directory.DelTree(root).IgnoreError();
			Directory.CreateDirectory(root).IgnoreError();
			defer Directory.DelTree(root).IgnoreError();
			Sidecars.Forget();

			// 1. The mapping: layout/<relative path without extension>.layout, backup/<relative path>.bak.
			{
				String proj = scope $"{root}/p1";
				Directory.CreateDirectory(scope $"{proj}/src/Game").IgnoreError();
				File.WriteAllText(scope $"{proj}/P1.tproj", "# tproj 1\nproject P1\n").IgnoreError();
				String src = scope $"{proj}/src/Game/Engine.treadle";
				String layout = scope .();
				String bak = scope .();
				String vbak = scope .();
				String lbak = scope .();
				Sidecars.LayoutPathOf(src, layout);
				Sidecars.BackupPathOf(src, bak);
				Sidecars.BackupPathOf(src, 1, vbak);
				Sidecars.BackupPathOf(layout, lbak);
				SelfTestCheck(SameFile(layout, scope $"{proj}/layout/src/Game/Engine.layout") && SameFile(bak, scope $"{proj}/backup/src/Game/Engine.treadle.bak")
					&& SameFile(vbak, scope $"{proj}/backup/src/Game/Engine.treadle.v1.bak") && SameFile(lbak, scope $"{proj}/backup/layout/src/Game/Engine.layout.bak"),
					scope $"codec: layout\\ and backup\\ mirror the source path ({layout}; {bak}; {vbak}; {lbak})");
			}

			// 2. Save writes the layout into layout\, backs up into backup\, and nothing lands beside the source;
			//    a graph without a layout file opens auto-arranged, and saving it then writes the layout.
			{
				String proj = scope $"{root}/p2";
				Directory.CreateDirectory(scope $"{proj}/src").IgnoreError();
				File.WriteAllText(scope $"{proj}/P2.tproj", "# tproj 1\nproject P2\n").IgnoreError();
				String path = scope $"{proj}/src/Thing.treadle";
				{
					let doc = scope TypeDocument(Language);
					doc.FilePath.Set(path);
					doc.InitType("Thing", .Class, "P2");
					let fn = doc.AddFunction("Run");
					doc.SetView(fn.Key, 1, 40, 20, 1.5f);
					String why = scope .();
					let saved = doc.TrySave(why);
					SelfTestCheck(saved && File.Exists(path) && File.Exists(scope $"{proj}/layout/src/Thing.layout") && !File.Exists(scope $"{path}.layout") && !File.Exists(scope $"{path}.bak"),
						scope $"codec: a save writes the layout to layout\\src\\Thing.layout and no sidecar beside the source {why}");
				}
				// A second save over the changed type keeps the old file in backup\.
				{
					let doc = scope TypeDocument(Language);
					let loaded = doc.Load(path) case .Ok;
					doc.AddFunction("Walk");
					doc.SetView(doc.Sheets[0].Key, 1, 80, 10, 1.0f);
					String why = scope .();
					var saved = loaded && doc.TrySave(why);
					SelfTestCheck(saved && File.Exists(scope $"{proj}/backup/src/Thing.treadle.bak") && File.Exists(scope $"{proj}/backup/layout/src/Thing.layout.bak")
						&& !File.Exists(scope $"{path}.bak") && !File.Exists(scope $"{proj}/layout/src/Thing.layout.bak"),
						scope $"codec: the second save keeps Thing.treadle.bak and Thing.layout.bak in backup\\ {why}");
					// The backup is one file that the next save replaces (the rotation is a single .bak).
					String before = scope .();
					ReadAll(scope $"{proj}/backup/src/Thing.treadle.bak", before);
					doc.AddFunction("Jump");
					saved = doc.TrySave(why..Clear());
					String after = scope .();
					ReadAll(scope $"{proj}/backup/src/Thing.treadle.bak", after);
					SelfTestCheck(saved && !before.IsEmpty && before != after, "codec: the next save replaces the one .bak in backup\\ with the previous version");
				}
				// No layout file: the type opens, with every node placed (auto-arranged), and a save then writes the layout.
				File.Delete(scope $"{proj}/layout/src/Thing.layout").IgnoreError();
				{
					let doc = scope TypeDocument(Language);
					let loaded = doc.Load(path) case .Ok && doc.LastError.IsEmpty && doc.Sheets.Count >= 2;
					bool placed = loaded;
					if (loaded)
						for (let s in doc.Sheets)
							if (s.IsBuilt && s.Graph.Nodes.Count > 1)
							{
								bool allSame = true;
								for (let n in s.Graph.Nodes)
									if (n.X != s.Graph.Nodes[0].X || n.Y != s.Graph.Nodes[0].Y)
										allSame = false;
								if (allSame)
									placed = false;
							}
					SelfTestCheck(loaded && placed && doc.Messages.IsEmpty, scope $"codec: a type with no layout file opens auto-arranged, with no message ({doc.LastError})");
					doc.SetView(doc.Sheets[0].Key, 1, 5, 5, 1.0f);
					String why = scope .();
					SelfTestCheck(doc.TrySave(why) && File.Exists(scope $"{proj}/layout/src/Thing.layout"), scope $"codec: saving it writes the layout into layout\\ {why}");
				}
			}

			// 3. Custom folders: layoutDir and backupDir in the project file (read and written back, used for the paths).
			{
				String proj = scope $"{root}/p3";
				Directory.CreateDirectory(proj).IgnoreError();
				String text = "# tproj 1\nproject P3\n\tlayoutDir positions/graphs\n\tbackupDir \"old copies\"\n";
				File.WriteAllText(scope $"{proj}/P3.tproj", text).IgnoreError();
				ProjectFile p = scope .();
				List<FormatError> errors = scope .();
				defer { ClearAndDeleteItems!(errors); }
				String back = scope .();
				let ok = ProjectCodec.ReadProject(text, p, errors);
				if (ok)
					ProjectCodec.WriteProject(p, back);
				SelfTestCheck(ok && p.LayoutDir == "positions/graphs" && p.BackupDir == "old copies" && back == text, "codec: layoutDir and backupDir read from the project file and write back unchanged");
				String path = scope $"{proj}/T.treadle";
				String layout = scope .();
				String bak = scope .();
				Sidecars.LayoutPathOf(path, layout);
				Sidecars.BackupPathOf(path, bak);
				SelfTestCheck(SameFile(layout, scope $"{proj}/positions/graphs/T.layout") && SameFile(bak, scope $"{proj}/old copies/T.treadle.bak"), scope $"codec: custom layoutDir and backupDir decide the paths ({layout}; {bak})");
				let doc = scope TypeDocument(Language);
				doc.FilePath.Set(path);
				doc.InitType("T", .Class, "P3");
				let fn = doc.AddFunction("Run");
				doc.SetView(fn.Key, 1, 1, 2, 1.0f);
				String why = scope .();
				SelfTestCheck(doc.TrySave(why) && File.Exists(scope $"{proj}/positions/graphs/T.layout") && !Directory.Exists(scope $"{proj}/layout"), scope $"codec: a save with custom folders writes there {why}");
			}

			// 4. Migration: sidecars beside the sources move once on the first sight of the project; the newer file wins a conflict.
			{
				String proj = scope $"{root}/p4";
				Directory.CreateDirectory(scope $"{proj}/src").IgnoreError();
				File.WriteAllText(scope $"{proj}/P4.tproj", "# tproj 1\nproject P4\n").IgnoreError();
				// A conflict: the new place holds an older file than the one beside the source.
				Directory.CreateDirectory(scope $"{proj}/layout/src").IgnoreError();
				File.WriteAllText(scope $"{proj}/layout/src/A.layout", "# treadle-layout 1\n\t\n").IgnoreError();
				Thread.Sleep(80);
				File.WriteAllText(scope $"{proj}/P4.tproj.bak", "# tproj 1\nproject Old\n").IgnoreError();
				File.WriteAllText(scope $"{proj}/src/A.treadle", "# treadle 1\ntype A class\n").IgnoreError();
				File.WriteAllText(scope $"{proj}/src/A.treadle.layout", "# treadle-layout 1\n").IgnoreError();
				File.WriteAllText(scope $"{proj}/src/A.treadle.bak", "# treadle 1\ntype A class\n").IgnoreError();
				File.WriteAllText(scope $"{proj}/src/A.treadle.layout.bak", "# treadle-layout 1\n").IgnoreError();
				File.WriteAllText(scope $"{proj}/src/A.treadle.v1.bak", "# treadle 1\ntype A class\n").IgnoreError();
				File.WriteAllText(scope $"{proj}/src/notes.bak", "not ours\n").IgnoreError();
				Sidecars.Forget();
				let doc = scope TypeDocument(Language);
				let loaded = doc.Load(scope $"{proj}/src/A.treadle") case .Ok;
				bool moved = !File.Exists(scope $"{proj}/src/A.treadle.layout") && !File.Exists(scope $"{proj}/src/A.treadle.bak") && !File.Exists(scope $"{proj}/src/A.treadle.layout.bak")
					&& !File.Exists(scope $"{proj}/src/A.treadle.v1.bak") && !File.Exists(scope $"{proj}/P4.tproj.bak");
				bool there = File.Exists(scope $"{proj}/layout/src/A.layout") && File.Exists(scope $"{proj}/backup/src/A.treadle.bak") && File.Exists(scope $"{proj}/backup/layout/src/A.layout.bak")
					&& File.Exists(scope $"{proj}/backup/src/A.treadle.v1.bak") && File.Exists(scope $"{proj}/backup/P4.tproj.bak");
				String note = scope .();
				for (let m in doc.Messages)
					note.AppendF("{} | ", m);
				SelfTestCheck(loaded && moved && there && File.Exists(scope $"{proj}/src/notes.bak"), scope $"codec: loading a project moves the sidecars beside its sources into layout\\ and backup\\ ({note})");
				SelfTestCheck(note.Contains("moved 1 layout files and 4 backups to layout/ and backup/"), scope $"codec: one line says how many were moved ({note})");
				// A second run (a fresh process, simulated) finds nothing more.
				Sidecars.Forget();
				List<String> lines = scope .();
				defer { ClearAndDeleteItems!(lines); }
				Sidecars.MigrateAt(proj, lines);
				SelfTestCheck(lines.IsEmpty, "codec: a second migration finds nothing to move");
				// --format --migrate on a project given on the command line does the same.
				File.WriteAllText(scope $"{proj}/src/B.treadle.layout", "# treadle-layout 1\n").IgnoreError();
				lines.Clear();
				Sidecars.MigrateAt(proj, lines);
				SelfTestCheck(lines.Count == 1 && lines[0].Contains("moved 1 layout files and 0 backups") && File.Exists(scope $"{proj}/layout/src/B.layout"), scope $"codec: --format --migrate moves the sidecars of a project ({lines.Count} lines)");
			}

			// 5. A file with no project above it keeps its sidecars beside it.
			{
				String dir = scope $"{root}/loose";
				Directory.CreateDirectory(dir).IgnoreError();
				String layout = scope .();
				Sidecars.LayoutPathOf(scope $"{dir}/L.treadle", layout);
				SelfTestCheck(SameFile(layout, scope $"{dir}/L.treadle.layout"), "codec: with no project file above, the layout stays beside the type file");
			}
			Sidecars.Forget();
		}
	}
}
#endif
