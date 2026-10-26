using System;
using System.Collections;

namespace Treadle.Format
{
	/// A problem in a format file: the line (1-based) and, where the line belongs to a node, the
	/// node's id.
	class FormatError
	{
		public int32 Line;
		public String NodeKey = new .() ~ delete _;
		public String Message = new .() ~ delete _;

		public override void ToString(String outText)
		{
			outText.AppendF("line {}", Line);
			if (!NodeKey.IsEmpty)
				outText.AppendF(" (node {})", NodeKey);
			outText.AppendF(": {}", Message);
		}
	}

	/// The typed refusal of a file whose header is newer than this build: the editor opens such a
	/// file read-only, `--build-run` and `--format` refuse it with exit code 2.
	class NewerVersionError : FormatError
	{
		/// The version in the file's header.
		public int32 FileVersion;
		/// The newest version this build reads.
		public int32 ReaderVersion;
	}

	/// The lexical layer shared by every format file (Graph-Format.md 2): lines, tokens (words and
	/// JSON-escaped strings), quoting.
	static class RecordText
	{
		/// The longest line a format file may have (TreadleCodec.ReadHeader refuses the file otherwise).
		public const int MaxLineLength = 64 * 1024;

		/// Splits `text` into lines: LF line ends (a CR before the LF and a byte order mark are
		/// dropped), no trailing empty line for the final LF.
		public static void SplitLines(StringView text, List<StringView> outLines)
		{
			var text;
			if (text.StartsWith("\xEF\xBB\xBF"))
				text = text.Substring(3);
			int start = 0;
			for (int i < text.Length)
			{
				if (text[i] != '\n')
					continue;
				var line = text.Substring(start, i - start);
				if (line.EndsWith('\r'))
					line.RemoveFromEnd(1);
				outLines.Add(line);
				start = i + 1;
			}
			if (start < text.Length)
			{
				var line = text.Substring(start);
				if (line.EndsWith('\r'))
					line.RemoveFromEnd(1);
				outLines.Add(line);
			}
		}

		/// Skips one token starting at `i` (spaces before it included); returns the index after it.
		static int SkipToken(StringView line, int iIn, out int start)
		{
			var i = iIn;
			while (i < line.Length && (line[i] == ' ' || line[i] == '\t'))
				i++;
			start = i;
			if (i >= line.Length)
				return i;
			if (line[i] == '"')
			{
				i++;
				while (i < line.Length && line[i] != '"')
					i += (line[i] == '\\') ? 2 : 1;
				return Math.Min(i + 1, line.Length);
			}
			while (i < line.Length && line[i] != ' ' && line[i] != '\t')
				i++;
			return i;
		}

		/// Whether a token that starts with `"` ends with an unescaped `"`.
		static bool IsClosedString(StringView tok)
		{
			int i = 1;
			while (i < tok.Length)
			{
				if (tok[i] == '\\')
				{
					i += 2;
					continue;
				}
				if (tok[i] == '"')
					return i == tok.Length - 1;
				i++;
			}
			return false;
		}

		/// Splits a record or property line (without its leading tab) into tokens: words separated
		/// by spaces, and strings `"..."` kept with their quotes. False with `outError` on an
		/// unterminated string.
		public static bool Tokenize(StringView line, List<StringView> outTokens, String outError)
		{
			int i = 0;
			while (true)
			{
				int start;
				let end = SkipToken(line, i, out start);
				if (start >= line.Length)
					return true;
				let tok = line.Substring(start, end - start);
				if (tok.StartsWith('"') && !IsClosedString(tok))
				{
					outError?.Set("a string is not closed (missing '\"')");
					return false;
				}
				outTokens.Add(tok);
				i = end;
			}
		}

		/// The text after the first `count` tokens of `line` (as written, trimmed).
		public static StringView RestAfter(StringView line, int count)
		{
			int i = 0;
			for (int k < count)
				i = SkipToken(line, i, ?);
			var rest = line.Substring(Math.Min(i, line.Length));
			rest.Trim();
			return rest;
		}

		/// Byte order of two ids or names (the canonical sort: culture-free).
		public static int CompareOrdinal(StringView a, StringView b)
		{
			let n = Math.Min(a.Length, b.Length);
			for (int i < n)
			{
				let ca = (uint8)a[i];
				let cb = (uint8)b[i];
				if (ca != cb)
					return (ca < cb) ? -1 : 1;
			}
			return a.Length <=> b.Length;
		}

		public static bool IsString(StringView token) => token.Length >= 2 && token.StartsWith('"') && token.EndsWith('"');

		/// The text of a string token (JSON escapes resolved); a word comes back as it is.
		public static void Unquote(StringView token, String outText)
		{
			if (!IsString(token))
			{
				outText.Append(token);
				return;
			}
			let inner = token.Substring(1, token.Length - 2);
			for (int i = 0; i < inner.Length; i++)
			{
				let c = inner[i];
				if (c != '\\' || i + 1 >= inner.Length)
				{
					outText.Append(c);
					continue;
				}
				let e = inner[++i];
				switch (e)
				{
				case 'n': outText.Append('\n');
				case 't': outText.Append('\t');
				case 'r': outText.Append('\r');
				case 'u':
					bool done = false;
					if (i + 4 < inner.Length)
					{
						if (uint32.Parse(inner.Substring(i + 1, 4), .HexNumber) case .Ok(let v))
						{
							outText.Append((char32)v);
							i += 4;
							done = true;
						}
					}
					if (!done)
						outText.Append("\\u");
				default: outText.Append(e);
				}
			}
		}

		/// Whether a free-text value (a name, a label, a path) must be written as a string: it is
		/// empty, holds a space, a tab or another control character, or starts with `"`
		/// (Graph-Format.md 2, "Free text"). Anything else, UTF-8 included, is written as a word.
		public static bool NeedsQuote(StringView text)
		{
			if (text.IsEmpty || text[0] == '"')
				return true;
			for (let c in text.RawChars)
				if ((uint8)c <= 0x20 || (uint8)c == 0x7F)
					return true;
			return false;
		}

		/// Appends a free-text value in canonical form: as a word when it reads back as one, else
		/// as a string (`Quote`).
		public static void Text(StringView text, String outText)
		{
			if (NeedsQuote(text))
				Quote(text, outText);
			else
				outText.Append(text);
		}

		/// A free-text value read back: a string token unquoted, a word as it is.
		public static String TextOf(StringView token) => Unquote(token, .. new String());

		/// A wire or route end `<id>.<pin>` in canonical form: the whole end is one string when the
		/// pin name needs quoting (`"d3.case:two words"`).
		public static void End(StringView nodeId, StringView pin, String outText)
		{
			if (NeedsQuote(pin))
				Quote(scope $"{nodeId}.{pin}", outText);
			else
				outText.AppendF("{}.{}", nodeId, pin);
		}

		/// A string token for `text`: quotes, `\" \\ \n \t \r`, other control characters as
		/// `\uXXXX`; everything else (UTF-8 included) as it is.
		public static void Quote(StringView text, String outText)
		{
			outText.Append('"');
			for (let c in text.RawChars)
			{
				switch (c)
				{
				case '"': outText.Append("\\\"");
				case '\\': outText.Append("\\\\");
				case '\n': outText.Append("\\n");
				case '\t': outText.Append("\\t");
				case '\r': outText.Append("\\r");
				default:
					if ((uint8)c < 0x20)
						outText.AppendF("\\u{0:X4}", (int)(uint8)c);
					else
						outText.Append(c);
				}
			}
			outText.Append('"');
		}
	}

	/// Builds the property lines of one record in the fixed key order, then puts the kept lines
	/// (unknown keys, comments) back after the key that preceded them when they were read.
	class PropWriter
	{
		List<(String key, String line)> mLines = new .() ~ { for (let l in _) { delete l.key; delete l.line; } delete _; };

		/// Adds `\t<key> <value>` (or `\t<key>` when the value is empty).
		public void Add(StringView key, StringView value = "")
		{
			String line = new .();
			line.AppendF("\t{}", key);
			if (!value.IsEmpty)
				line.AppendF(" {}", value);
			mLines.Add((new String(key), line));
		}

		/// Adds `\t<word> <value>` grouped under `key` (node settings and kind-specific lines
		/// share the `set` group).
		public void AddGrouped(StringView key, StringView word, StringView value)
		{
			String line = new .();
			line.AppendF("\t{}", word);
			if (!value.IsEmpty)
				line.AppendF(" {}", value);
			mLines.Add((new String(key), line));
		}

		/// Adds `\t<key> "<text>"`.
		public void AddString(StringView key, StringView text)
		{
			String v = scope .();
			RecordText.Quote(text, v);
			Add(key, v);
		}

		/// Appends the lines, with `extras`' inner lines in place, to `outText`.
		public void Emit(Treadle.Model.RecordExtras extras, String outText)
		{
			let inner = (extras != null) ? extras.Inner : null;
			int n = (inner != null) ? inner.Count : 0;
			bool[] used = scope bool[n];
			for (int pass < mLines.Count + 2)
			{
				// pass 0: lines anchored to the record line; then each key group; last: leftovers.
				StringView key = "";
				if (pass > 0 && pass <= mLines.Count)
				{
					let i = pass - 1;
					outText.AppendF("{}\n", mLines[i].line);
					if (i < mLines.Count - 1 && mLines[i + 1].key == mLines[i].key)
						continue;
					key = mLines[i].key;
				}
				for (int k < n)
				{
					if (used[k] || (pass <= mLines.Count && inner[k].AfterKey != key))
						continue;
					used[k] = true;
					outText.AppendF("{}\n", inner[k].Line);
				}
			}
		}
	}
}
