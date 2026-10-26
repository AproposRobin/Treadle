using System;

namespace Treadle.Format
{
	/// The file extensions and header words of the format files, new and old (docs/Format-Stability.md,
	/// "Extensions"): readers accept both forever, writers write only the new ones, and
	/// `--format --migrate` renames old-extension files. The format version is not involved.
	///
	///   type file      .treadle          # treadle N          (old: .vtype, # vtype N; .cdecl carries the type header)
	///   layout         .treadle.layout   # treadle-layout N   (old: .vtype.layout, # vtype-layout N)
	///   project        .tproj            # tproj N            (old: .vproject, # vproject N)
	///   Sheet IR       .tir              # tir N              (old: .kir, # kir N)
	///   C import set   .cimport          # cimport N          (unchanged)
	static class FormatNames
	{
		public const String TypeExt = ".treadle";
		public const String LayoutExt = ".treadle.layout";
		public const String ProjectExt = ".tproj";
		public const String IRExt = ".tir";

		public const String OldTypeExt = ".vtype";
		public const String OldLayoutExt = ".vtype.layout";
		public const String OldProjectExt = ".vproject";
		public const String OldIRExt = ".kir";

		public const String TypeWord = "treadle";
		public const String LayoutWord = "treadle-layout";
		public const String ProjectWord = "tproj";
		public const String IRWord = "tir";
		public const String CImportWord = "cimport";

		/// `*.treadle` and `*.vtype` (an enumeration takes each pattern in turn).
		public static String[2] TypePatterns = .("*.treadle", "*.vtype");
		public static String[2] ProjectPatterns = .("*.tproj", "*.vproject");
		public static String[2] IRPatterns = .("*.tir", "*.kir");

		/// The (new, old) pairs of extensions, the longer layout pair before the type pair.
		public static (String now, String old)[4] Extensions = .((LayoutExt, OldLayoutExt), (TypeExt, OldTypeExt), (ProjectExt, OldProjectExt), (IRExt, OldIRExt));

		/// The (new, old) pairs of header words.
		public static (String now, String old)[4] Words = .((TypeWord, "vtype"), (LayoutWord, "vtype-layout"), (ProjectWord, "vproject"), (IRWord, "kir"));

		static bool Ends(StringView path, StringView ext) => path.EndsWith(ext, .OrdinalIgnoreCase);

		/// A type file (`.treadle`, `.vtype`; not a layout sidecar).
		public static bool IsTypeFile(StringView path) => Ends(path, TypeExt) || Ends(path, OldTypeExt);
		/// A layout sidecar (`.treadle.layout`, `.vtype.layout`).
		public static bool IsLayoutFile(StringView path) => Ends(path, LayoutExt) || Ends(path, OldLayoutExt);
		/// A project file (`.tproj`, `.vproject`).
		public static bool IsProjectFile(StringView path) => Ends(path, ProjectExt) || Ends(path, OldProjectExt);
		/// A Sheet IR dump (`.tir`, `.kir`).
		public static bool IsIRFile(StringView path) => Ends(path, IRExt) || Ends(path, OldIRExt);

		/// The current header word for `word`, old or new (`vtype` -> `treadle`); `word` itself when it is
		/// neither (`cimport`).
		public static StringView CurrentWord(StringView word)
		{
			for (let w in Words)
				if (word == w.old || word == w.now)
					return w.now;
			return word;
		}

		/// The old header word of a current one (`treadle` -> `vtype`); empty when there is none.
		public static StringView OldWord(StringView word)
		{
			for (let w in Words)
				if (word == w.now)
					return w.old;
			return "";
		}

		/// The header word line 1 of `text` carries when it is `kind` (current word) or its old word: the
		/// word as written, empty when line 1 is neither `# <kind> ` nor `# <old> `.
		public static StringView HeaderWordIn(StringView text, StringView kind)
		{
			var text;
			if (text.StartsWith("\xEF\xBB\xBF"))
				text = text.Substring(3);
			let now = CurrentWord(kind);
			if (text.StartsWith("# ") && text.Substring(2).StartsWith(now) && text.Length > 2 + now.Length && text[2 + now.Length] == ' ')
				return now;
			let old = OldWord(now);
			if (!old.IsEmpty && text.StartsWith("# ") && text.Substring(2).StartsWith(old) && text.Length > 2 + old.Length && text[2 + old.Length] == ' ')
				return old;
			return "";
		}

		/// The new name of an old-extension file (`Player.vtype` -> `Player.treadle`); false when `path`
		/// has no old extension.
		public static bool NewNameOf(StringView path, String outPath)
		{
			for (let e in Extensions)
			{
				if (Ends(path, e.old))
				{
					outPath.Set(path.Substring(0, path.Length - e.old.Length));
					outPath.Append(e.now);
					return true;
				}
			}
			return false;
		}

		/// The same file under the other extension (`Player.treadle` <-> `Player.vtype`); false for any other file.
		public static bool TwinOf(StringView path, String outPath)
		{
			if (NewNameOf(path, outPath))
				return true;
			for (let e in Extensions)
			{
				if (Ends(path, e.now))
				{
					outPath.Set(path.Substring(0, path.Length - e.now.Length));
					outPath.Append(e.old);
					return true;
				}
			}
			return false;
		}

		/// `text` with an old header word on line 1 replaced by the current one (nothing else changes).
		public static void RewriteHeaderWord(StringView text, StringView kind, String outText)
		{
			let found = HeaderWordIn(text, kind);
			let now = CurrentWord(kind);
			if (found.IsEmpty || found == now)
			{
				outText.Set(text);
				return;
			}
			let at = text.IndexOf(found);
			outText.Set(text.Substring(0, at));
			outText.Append(now);
			outText.Append(text.Substring(at + found.Length));
		}
	}
}
