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

namespace Treadle.Editor
{
	/// The `codec` self test's version handling (docs/Format-Stability.md 2-5): the frozen
	/// format-history corpus loads and writes back, a simulated bump migrates a v1 copy (load,
	/// dirty, save with one `.v1.bak`, compare, idempotence, `--format --migrate`), the alias table,
	/// and a file newer than this build opening read-only.
	extension EditorApp
	{
		/// The self test's step 1 -> 2: the property key `doc` of a `field` becomes `summary`.
		static void SelfTestStep2(FormatRecords file, List<String> notes)
		{
			if (file.RenameKey("field", "doc", "summary") > 0)
				notes.Add(new String("self test step 2: field `doc` renamed to `summary`"));
		}

		static bool ReadText(StringView path, String outText) => File.ReadAllText(path, outText, true) case .Ok;

		/// Whether `written` is `onDisk` (the file `path`) with an old header word on line 1 replaced by the
		/// current one: the writer's byte-for-byte result for the frozen corpus, which keeps the old words.
		static bool WritesBack(StringView path, StringView onDisk, StringView written)
		{
			String s = scope .();
			FormatNames.RewriteHeaderWord(onDisk, Migrations.KindOf(path), s);
			return s == written;
		}

		/// `samples` is TreadleCore/samples; `temp` a flat work folder the codec case deletes.
		void SelfTestMigrate(StringView samples, StringView temp)
		{
			let codec = Language.Codec;
			String history = scope $"{samples}/{Canonical.HistoryFolder}/v1";

			// 1. The frozen v1 corpus: every file loads with the current reader and, at the current
			//    version, writes back byte for byte (type files through the document, with their layout).
			{
				int count = 0;
				String bad = scope .();
				for (let e in Directory.EnumerateFiles(history))
				{
					String path = scope .();
					e.GetFilePath(path);
					path.Replace('\\', '/');
					if (!Canonical.Handles(path))
						continue;
					count++;
					String text = scope .();
					String canon = scope .();
					String why = scope .();
					if (!ReadText(path, text) || !Canonical.Normalize(path, text, canon, why) || !WritesBack(path, text, canon))
					{
						bad.AppendF(" {}{}{}", path, why.IsEmpty ? "" : ": ", why);
						continue;
					}
					if (!FormatNames.IsTypeFile(path))
						continue;
					TypeDocument doc = scope .(Language);
					String layout = scope .();
					String backLayout = scope .();
					let loaded = doc.Load(path) case .Ok && doc.LastError.IsEmpty && doc.FormatVersion == 1 && doc.MigratedFrom == 0 && !doc.Modified;
					if (!loaded)
						bad.AppendF(" {} (load: {})", path, doc.LastError);
					else if (ReadText(scope $"{path}.layout", layout) && (!codec.WriteLayout(doc, backLayout, why) || !WritesBack(scope $"{path}.layout", layout, backLayout)))
						bad.AppendF(" {}.layout", path);
				}
				SelfTestCheck(count >= 7 && bad.IsEmpty, scope $"codec: the {count} format-history/v1 files load and write back byte for byte{(bad.IsEmpty ? "" : ", not:")}{bad}");
			}

			// 2. A simulated bump: version 2 with a self-test step (field `doc` -> `summary`).
			String v1Text = scope .();
			String v1Layout = scope .();
			ReadText(scope $"{history}/Player.vtype", v1Text); // the corpus keeps the old names and header words
			ReadText(scope $"{history}/Player.vtype.layout", v1Layout);
			String expected = scope .(v1Text);
			expected.Replace("# vtype 1\n", "# treadle 2\n"); // migrated files are written with the current header word
			expected.Replace("\tdoc \"Hit points", "\tsummary \"Hit points");
			String expectedLayout = scope .(v1Layout);
			expectedLayout.Replace("# vtype-layout 1\n", "# treadle-layout 2\n");
			Migrations.SimulateBump(2, .("treadle", 1, 2, => SelfTestStep2));
			defer Migrations.EndSimulation();
			{
				String path = scope $"{temp}/Player.treadle";
				String layoutPath = scope $"{path}.layout";
				String bak = scope $"{path}.v1.bak";
				File.WriteAllText(path, v1Text).IgnoreError();
				File.WriteAllText(layoutPath, v1Layout).IgnoreError();
				TypeDocument doc = scope .(Language);
				let loaded = doc.Load(path) case .Ok && doc.LastError.IsEmpty;
				SelfTestCheck(loaded && doc.MigratedFrom == 1 && doc.LayoutMigratedFrom == 1 && doc.Modified && doc.UnknownCount == 1 && doc.Sheets.Count >= 4,
					scope $"codec: a v1 file loads under a simulated version 2, migrated and marked dirty (from {doc.MigratedFrom}, layout from {doc.LayoutMigratedFrom}, {doc.UnknownCount} unknown key) {doc.LastError}");
				String why = scope .();
				let saved = loaded && doc.TrySave(why);
				String written = scope .();
				String writtenLayout = scope .();
				String bakText = scope .();
				String layoutBak = scope .();
				SelfTestCheck(saved && ReadText(path, written) && written == expected && ReadText(layoutPath, writtenLayout) && writtenLayout == expectedLayout,
					scope $"codec: the first save writes version 2 (the step's rename, the layout header) {why}");
				if (written != expected)
					Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] wrote:\n{written}");
				SelfTestCheck(ReadText(bak, bakText) && bakText == v1Text && ReadText(scope $"{layoutPath}.v1.bak", layoutBak) && layoutBak == v1Layout && doc.MigratedFrom == 0 && !doc.Modified,
					"codec: the save kept Player.treadle.v1.bak and Player.treadle.layout.v1.bak (the version 1 text)");

				// The backup is written once: a second migration of the same file keeps the first one.
				File.WriteAllText(bak, "first backup\n").IgnoreError();
				File.WriteAllText(path, v1Text).IgnoreError();
				TypeDocument again = scope .(Language);
				why.Clear();
				let saved2 = again.Load(path) case .Ok && again.TrySave(why);
				bakText.Clear();
				SelfTestCheck(saved2 && ReadText(bak, bakText) && bakText == "first backup\n", scope $"codec: the .v1.bak is written once, never overwritten {why}");

				// Reloaded at version 2: current, not dirty, and it writes back byte for byte.
				TypeDocument current = scope .(Language);
				String back = scope .();
				let reloaded = current.Load(path) case .Ok && current.MigratedFrom == 0 && !current.Modified && current.WriteText(back, why) && back == expected;
				SelfTestCheck(reloaded, "codec: the migrated file reloads as current and writes back byte for byte");

				// Idempotent: the step on its own output changes nothing.
				String rerun = scope .(expected);
				rerun.Replace("# treadle 2\n", "# treadle 1\n");
				String twice = scope .();
				SelfTestCheck(Migrations.Run("treadle", rerun, 1, twice) && twice == expected, "codec: the migration step is idempotent (run on its own output, nothing changes)");
			}

			// 3. `--format` over old files: --check and no --migrate report them and write nothing;
			//    --migrate writes them (type file and layout) with the backup; a second run does nothing.
			{
				String path = scope $"{temp}/Batch.treadle";
				String layoutPath = scope $"{path}.layout";
				File.WriteAllText(path, v1Text).IgnoreError();
				File.WriteAllText(layoutPath, v1Layout).IgnoreError();
				String why = scope .();
				let r1 = Canonical.FormatFile(path, true, true, why);
				let r2 = Canonical.FormatFile(path, false, false, why..Clear());
				String still = scope .();
				ReadText(path, still);
				SelfTestCheck(r1 == .Old && r2 == .Old && still == v1Text, scope $"codec: --format --check and --format without --migrate report a version 1 file and leave it ({why})");
				let r3 = Canonical.FormatFile(path, false, true, why..Clear());
				let r4 = Canonical.FormatFile(layoutPath, false, true, why);
				String written = scope .();
				String writtenLayout = scope .();
				SelfTestCheck(r3 == .Migrated && r4 == .Migrated && ReadText(path, written) && written == expected && ReadText(layoutPath, writtenLayout) && writtenLayout == expectedLayout
					&& File.Exists(scope $"{path}.v1.bak") && File.Exists(scope $"{layoutPath}.v1.bak"), scope $"codec: --format --migrate writes version 2 with the .v1.bak files {why}");
				let r5 = Canonical.FormatFile(path, true, true, why..Clear());
				let r6 = Canonical.FormatFile(layoutPath, true, true, why);
				SelfTestCheck(r5 == .Same && r6 == .Same, "codec: --format --migrate --check after the migration: current and canonical");
			}
			Migrations.EndSimulation();

			// 3b. Old extensions (FormatNames): a copy of the corpus under its old names; --format --check lists
			//     the renames, --format --migrate renames every file (the layouts with their types) and writes
			//     the current header words, after which --check finds nothing; a project holding both names is refused.
			{
				String dir = scope $"{temp}/oldnames";
				Directory.CreateDirectory(dir).IgnoreError();
				int copied = 0;
				for (let e in Directory.EnumerateFiles(history))
				{
					let src = e.GetFilePath(.. scope String());
					let name = e.GetFileName(.. scope String());
					if (File.Copy(src, scope $"{dir}/{name}") case .Ok)
						copied++;
				}
				List<String> files = scope .();
				defer { ClearAndDeleteItems!(files); }
				Canonical.Collect(dir, files, true);
				int would = 0, renamed = 0, failed = 0;
				String why = scope .();
				for (let f in files)
					if (Canonical.RenameOldExtension(f, true, scope String(), why..Clear()) == .WouldRename)
						would++;
				for (let f in files)
				{
					String now = scope .();
					switch (Canonical.RenameOldExtension(f, false, now, why..Clear()))
					{
					case .Renamed: renamed++;
					case .Failed: failed++;
					default:
					}
					if (Canonical.FormatFile(now, false, true, why..Clear()) == .Failed)
						failed++;
				}
				List<String> after = scope .();
				defer { ClearAndDeleteItems!(after); }
				Canonical.Collect(dir, after, true);
				int clean = 0, oldLeft = 0;
				for (let f in after)
				{
					if (FormatNames.NewNameOf(f, scope String()))
						oldLeft++;
					else if (Canonical.FormatFile(f, true, true, why..Clear()) == .Same)
						clean++;
				}
				SelfTestCheck(copied >= 9 && would == 7 && renamed == 7 && failed == 0 && oldLeft == 0 && clean == after.Count && File.Exists(scope $"{dir}/Player.treadle.layout") && File.Exists(scope $"{dir}/Shooter.tproj"),
					scope $"codec: --format --check lists the 7 old-extension files ({would}), --format --migrate renames them ({renamed}) and the folder then checks clean ({clean} of {after.Count}, {oldLeft} old left) {why}");
				// Both names of one type: the rename refuses and keeps both.
				File.WriteAllText(scope $"{dir}/Twin.vtype", "# vtype 1\ntype Twin class\n").IgnoreError();
				File.WriteAllText(scope $"{dir}/Twin.treadle", "# treadle 1\ntype Twin class\n").IgnoreError();
				let twin = Canonical.RenameOldExtension(scope $"{dir}/Twin.vtype", false, scope String(), why..Clear());
				SelfTestCheck(twin == .Failed && File.Exists(scope $"{dir}/Twin.vtype") && File.Exists(scope $"{dir}/Twin.treadle"), scope $"codec: --format --migrate keeps both Twin.vtype and Twin.treadle and says so ({why})");
				// A depends line naming an old project file follows the rename.
				String proj = scope .("# vproject 1\nproject App\n\tkind console\ndepends lib/Lib.vproject\n");
				String canonProj = scope .();
				let projOk = Canonical.Normalize("App.vproject", proj, canonProj, why..Clear()) && Canonical.MigrateProjectPaths(canonProj);
				SelfTestCheck(projOk && canonProj.StartsWith("# tproj 1\n") && canonProj.Contains("depends lib/Lib.tproj\n"), scope $"codec: an old project file is written as # tproj with its depends path renamed {why}");
				for (let e in Directory.EnumerateFiles(dir))
					File.Delete(e.GetFilePath(.. scope String())).IgnoreError();
				Directory.Delete(dir).IgnoreError();
			}

			// 4. The alias table: an old node kind and an old pin name read as the current ones and
			//    are written with the new names (the placeholder rows, docs/Graph-Format.md 8).
			{
				String text = scope .();
				text.Append("# treadle 1\ntype T class\n\nfunction f1 Run\nparam c bool\nsheet body\nnode a1 Entry\nnode a2 ExampleBranch\nnode a3 Return\n");
				text.Append("wire a1.c a2.example-condition\nwire a1.then a2.in\nwire a2.true a3.in\n");
				TypeDocument doc = scope .(Language);
				String why = scope .();
				let read = codec.Read(text, doc, why);
				let g = (read && !doc.Sheets.IsEmpty) ? doc.Sheets[0].Graph : null;
				let br = g?.FindNodeByKey("a2");
				let cond = br?.FindInput("condition");
				SelfTestCheck(br != null && br.Kind == .Branch && doc.UnknownCount == 0 && cond != null && g.IsLinked(cond), scope $"codec: alias rows read ExampleBranch as Branch and example-condition as condition {why}");
				String back = scope .();
				doc.WriteText(back, why);
				String want = scope .(text);
				want.Replace("ExampleBranch", "Branch");
				want.Replace("example-condition", "condition");
				SelfTestCheck(back == want, "codec: an aliased file is written with the current names");
				if (back != want)
					Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] wrote:\n{back}");
			}

			// 5. A file newer than this build: the reader's typed refusal; the editor's open is
			//    read-only (notice, no edits, no save, the file untouched); --build-run refuses it.
			{
				String newer = scope .(v1Text);
				newer.Replace("# vtype 1\n", "# vtype 9\n"); // the old header word at a newer version: refused as newer
				List<FormatError> errors = scope .();
				defer { ClearAndDeleteItems!(errors); }
				TypeDocument plain = scope .(Language);
				let refused = !TreadleCodec.ReadAll(newer, plain, errors);
				let typed = TreadleCodec.NewerIn(errors);
				SelfTestCheck(refused && typed != null && typed.FileVersion == 9 && typed.ReaderVersion == 1 && typed.Line == 1,
					scope $"codec: a version 9 file is refused with the typed newer-version result: {(typed != null) ? (StringView)typed.Message : ""}");

				String dir = scope $"{temp}/newer-{(int)Platform.BfpSystem_GetTimeStamp() & 0xFFFF}";
				Directory.CreateDirectory(dir).IgnoreError();
				defer
				{
					for (let e in Directory.EnumerateFiles(dir))
						File.Delete(e.GetFilePath(.. scope String())).IgnoreError();
					Directory.Delete(dir).IgnoreError();
				}
				String path = scope $"{dir}/Player.treadle";
				File.WriteAllText(path, newer).IgnoreError();
				TypeDocument doc = scope .(Language);
				let loaded = doc.Load(path) case .Ok && doc.LastError.IsEmpty;
				bool allReadOnly = !doc.Sheets.IsEmpty;
				for (let s in doc.Sheets)
					allReadOnly &= s.Graph.ReadOnly;
				SelfTestCheck(loaded && doc.IsNewerFormat && doc.NewerVersion == 9 && doc.Members.Count == 7 && allReadOnly,
					scope $"codec: the editor opens a version 9 copy read-only ({doc.Members.Count} members, every Sheet read-only) {doc.LastError}");
				let prev = Doc;
				Doc = doc;
				String notice = scope .();
				let shown = FormatNotice(notice);
				let writable = CheckWritable();
				Doc = prev;
				SelfTestCheck(shown && notice.Contains("saved by a newer version 9; this build reads up to 1; open read-only") && !writable,
					scope $"codec: the notice bar says so and edits are refused: {notice}");
				String why = scope .();
				doc.Modified = true;
				let saved = doc.TrySave(why);
				String disk = scope .();
				SelfTestCheck(!saved && why.Contains("newer version 9") && ReadText(path, disk) && disk == newer && !File.Exists(scope $"{path}.bak"),
					scope $"codec: Save is refused and the file is untouched: {why}");
				doc.Modified = false;
				String found = scope .();
				let refusedBuild = Migrations.FindNewer(dir, found, let foundVersion);
				String fr = scope .();
				let fmt = Canonical.FormatFile(path, true, false, fr);
				SelfTestCheck(refusedBuild && foundVersion == 9 && found.EndsWith("Player.treadle") && fmt == .Newer,
					scope $"codec: --build-run and --format find the newer file (exit code 2): {fr}");
			}
		}
	}
}
#endif
