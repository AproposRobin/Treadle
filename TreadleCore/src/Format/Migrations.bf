using System;
using System.Collections;
using System.IO;

namespace Treadle.Format
{
	/// One record of a format file as a migration step sees it: the record line (column 0) and its
	/// property lines (without the leading tab). A comment line or a blank line is a record of its
	/// own with no properties, so a file with no step to run writes back as it was read.
	class FormatRecord
	{
		public String Line = new .() ~ delete _;
		public List<String> Props = new .() ~ DeleteContainerAndItems!(_);

		public bool IsComment => Line.StartsWith('#');
		public bool IsBlank => Line.IsEmpty;

		/// The first word of the line (`node`, `field`, `wire`...); empty for a comment or a blank line.
		public StringView Kind
		{
			get
			{
				if (IsComment || IsBlank)
					return "";
				let sp = Line.IndexOf(' ');
				return (sp < 0) ? (StringView)Line : Line.Substring(0, sp);
			}
		}

		/// The word at `index` of the record line (0 = the kind); empty past the end.
		public StringView Word(int index)
		{
			int i = 0;
			for (let w in Line.Split(' ', .RemoveEmptyEntries))
			{
				if (i++ == index)
					return w;
			}
			return "";
		}

		/// The key of property `i` (its first word).
		public StringView KeyOf(int i)
		{
			let p = Props[i];
			let sp = p.IndexOf(' ');
			return (sp < 0) ? (StringView)p : p.Substring(0, sp);
		}
	}

	/// A whole format file as records, before any binding: what a migration step rewrites.
	class FormatRecords
	{
		/// The header word (current form): `treadle` (type files and `.cdecl`), `treadle-layout`, `tproj`, `cimport`.
		public String FileKind = new .() ~ delete _;
		public int32 Version;
		/// Property lines before the first record (a malformed file; kept as they are).
		public List<String> Leading = new .() ~ DeleteContainerAndItems!(_);
		public List<FormatRecord> Records = new .() ~ DeleteContainerAndItems!(_);

		/// Splits `text` (header included) into records. False when the header is not
		/// `# <kind> <n>`.
		public bool Parse(StringView kind, StringView text)
		{
			FileKind.Set(FormatNames.CurrentWord(kind)); // an old header word is written back as the current one
			List<StringView> lines = scope .();
			RecordText.SplitLines(text, lines);
			let word = lines.IsEmpty ? StringView() : FormatNames.HeaderWordIn(lines[0], kind);
			String expect = scope $"# {word} ";
			if (word.IsEmpty || !lines[0].StartsWith(expect) || !(int32.Parse(lines[0].Substring(expect.Length)) case .Ok(out Version)))
				return false;
			FormatRecord cur = null;
			for (int i = 1; i < lines.Count; i++)
			{
				let line = lines[i];
				if (line.StartsWith('\t'))
				{
					if (cur != null && !cur.IsComment && !cur.IsBlank)
						cur.Props.Add(new String(line.Substring(1)));
					else
						Leading.Add(new String(line));
					continue;
				}
				let r = new FormatRecord();
				r.Line.Set(line);
				Records.Add(r);
				if (!r.IsComment && !r.IsBlank)
					cur = r;
			}
			return true;
		}

		/// The file text: the header at `Version`, then the records.
		public void Write(String outText)
		{
			outText.AppendF("# {} {}\n", FileKind, Version);
			for (let l in Leading)
				outText.AppendF("{}\n", l);
			for (let r in Records)
			{
				outText.AppendF("{}\n", r.Line);
				for (let p in r.Props)
					outText.AppendF("\t{}\n", p);
			}
		}

		/// Renames the property key `oldKey` to `newKey` in every `recordKind` record ("" = any
		/// record). Idempotent: a key already renamed is not matched again. Returns the count.
		public int RenameKey(StringView recordKind, StringView oldKey, StringView newKey)
		{
			int n = 0;
			for (let r in Records)
			{
				if (!recordKind.IsEmpty && r.Kind != recordKind)
					continue;
				for (int i < r.Props.Count)
				{
					if (r.KeyOf(i) != oldKey)
						continue;
					String renamed = scope .(newKey);
					renamed.Append(r.Props[i].Substring(oldKey.Length));
					r.Props[i].Set(renamed);
					n++;
				}
			}
			return n;
		}

		/// Renames record kind `oldKind` to `newKind` (the first word of the line). Returns the count.
		public int RenameRecord(StringView oldKind, StringView newKind)
		{
			int n = 0;
			for (let r in Records)
			{
				if (r.Kind != oldKind)
					continue;
				String renamed = scope .(newKind);
				renamed.Append(r.Line.Substring(oldKind.Length));
				r.Line.Set(renamed);
				n++;
			}
			return n;
		}
	}

	/// One migration step: rewrites a file of `FileKind` from version `From` to `To` (= From + 1).
	/// `Migrate` matches only the old shape (so it is idempotent), never fails (what it cannot map
	/// stays as an unknown record, with a note) and leaves the header to the chain.
	struct MigrationStep
	{
		public StringView FileKind;
		public int32 From;
		public int32 To;
		public function void(FormatRecords file, List<String> notes) Migrate;

		public this(StringView fileKind, int32 from, int32 to, function void(FormatRecords file, List<String> notes) migrate)
		{
			FileKind = fileKind;
			From = from;
			To = to;
			Migrate = migrate;
		}
	}

	/// The migration chain (docs/Format-Stability.md 3): every format version ever written migrates
	/// step by step to the current one, over the records of the file before the reader binds them.
	/// The readers (TreadleCodec.Prepare) run it on load; `--format --migrate` writes the result.
	/// A file whose version is newer than this build's is never migrated: it opens read-only.
	static class Migrations
	{
		/// The shipped steps, in version order. A bump appends its steps here and never removes one.
		/// None yet: every file written so far is version 1. A step is one line in `static this`:
		/// `sSteps.Add(.("treadle", 1, 2, => MigrateType2));` (the current header word: FormatNames)
		static List<MigrationStep> sSteps = new .() ~ delete _;

		static this()
		{
		}

		/// Steps registered by the codec self test, with the version they simulate.
		static List<MigrationStep> sTestSteps = new .() ~ delete _;
		static int32 sSimulated;

		/// The version this build reads and writes: TreadleCodec.Version, or a simulated bump.
		public static int32 Current => (sSimulated != 0) ? sSimulated : TreadleCodec.Version;

		/// The self test's bump: `Current` becomes `version` and `step` joins the chain until
		/// `EndSimulation`.
		public static void SimulateBump(int32 version, MigrationStep step)
		{
			sSimulated = version;
			sTestSteps.Add(step);
		}

		public static void EndSimulation()
		{
			sSimulated = 0;
			sTestSteps.Clear();
		}

		/// The header word (current form) of a format file, from its name, old extensions included:
		/// `treadle` (`.treadle`, `.vtype`, `.cdecl`), `treadle-layout` (`.layout`), `tproj` (`.tproj`,
		/// `.vproject`), `cimport`; empty for anything else.
		public static StringView KindOf(StringView path)
		{
			if (path.EndsWith(".layout"))
				return FormatNames.LayoutWord;
			if (FormatNames.IsTypeFile(path) || path.EndsWith(".cdecl"))
				return FormatNames.TypeWord;
			if (FormatNames.IsProjectFile(path))
				return FormatNames.ProjectWord;
			if (path.EndsWith(".cimport"))
				return "cimport";
			return "";
		}

		/// The version in the header of `text` (`# <kind> <n>`); 0 when there is none.
		public static int32 VersionOf(StringView kind, StringView text)
		{
			var text;
			if (text.StartsWith("\xEF\xBB\xBF"))
				text = text.Substring(3);
			let word = FormatNames.HeaderWordIn(text, kind); // the current word or the old one
			String expect = scope $"# {word} ";
			if (word.IsEmpty)
				return 0;
			var num = text.Substring(expect.Length);
			let nl = num.IndexOf('\n');
			if (nl >= 0)
				num = num.Substring(0, nl);
			num.Trim();
			if (int32.Parse(num) case .Ok(let v) && v > 0)
				return v;
			return 0;
		}

		/// Runs the chain on `text`, a `kind` file at version `from` (< Current): every step from
		/// `from` up, in order, then the header at Current. Notes (what a step could not map) go to
		/// `notes` when given. False when the header does not read (`outText` is then `text`).
		public static bool Run(StringView kind, StringView text, int32 from, String outText, List<String> notes = null)
		{
			FormatRecords file = scope .();
			if (!file.Parse(kind, text) || from >= Current)
			{
				outText.Set(text);
				return false;
			}
			List<String> scratch = scope .();
			defer { ClearAndDeleteItems!(scratch); }
			let into = notes ?? scratch;
			for (var v = from; v < Current; v++)
			{
				for (let s in sSteps)
					if (s.From == v && FormatNames.CurrentWord(s.FileKind) == file.FileKind)
						s.Migrate(file, into);
				for (let s in sTestSteps)
					if (s.From == v && FormatNames.CurrentWord(s.FileKind) == file.FileKind)
						s.Migrate(file, into);
			}
			file.Version = Current;
			outText.Clear();
			file.Write(outText);
			return true;
		}

		/// The backup a migration leaves once: `backup/<relative path>.v<old>.bak` in the project (beside the file with no project).
		public static void BackupPathOf(StringView path, int32 oldVersion, String outPath)
		{
			Treadle.Document.Sidecars.BackupPathOf(path, oldVersion, outPath);
		}

		/// Copies `path` (still at `oldVersion` on disk) to `<file>.v<old>.bak` unless that backup
		/// already exists (one per old version, never overwritten). False when the copy fails.
		public static bool BackupOnce(StringView path, int32 oldVersion)
		{
			if (oldVersion <= 0 || !File.Exists(path))
				return true;
			String bak = scope .();
			BackupPathOf(path, oldVersion, bak);
			Treadle.Document.FileSafety.EnsureParent(bak);
			if (File.Exists(bak))
				return true;
			return File.Copy(path, bak) case .Ok;
		}

		/// The message for a file newer than this build (the reader's error, the editor's notice
		/// bar and `--build-run`'s refusal share it).
		public static void NewerMessage(int32 fileVersion, String outText)
		{
			outText.AppendF("saved by a newer version {}; this build reads up to {}; open read-only", fileVersion, Current);
		}

		/// The first format file under `root` (a folder, recursively, as `--format` collects it)
		/// whose header is newer than this build: true with `outPath` and `outVersion` set.
		public static bool FindNewer(StringView root, String outPath, out int32 outVersion)
		{
			outVersion = 0;
			List<String> files = scope .();
			defer { ClearAndDeleteItems!(files); }
			Canonical.Collect(root, files);
			for (let f in files)
			{
				String text = scope .();
				if (File.ReadAllText(f, text, true) case .Err)
					continue;
				let v = VersionOf(KindOf(f), text);
				if (v > Current)
				{
					outPath.Set(f);
					outVersion = v;
					return true;
				}
			}
			return false;
		}
	}
}
