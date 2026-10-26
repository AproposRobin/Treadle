using System;
using System.Collections;
using System.IO;

namespace Treadle.Document
{
	/// Just enough TOML for project and settings files (kept from the fork): `[Table]` headers, `key = "string"`,
	/// and inline tables `key = {A = "*", B = {Path = "x"}}`. Values are flattened to dotted keys:
	/// "Projects.GameKit.Path" = "GameKit", "Dependencies.corlib" = "*".
	class MiniToml
	{
		public List<(String key, String value)> Entries = new .() ~ { for (let e in _) { delete e.key; delete e.value; } delete _; };

		public static bool Load(StringView path, MiniToml outToml)
		{
			String text = scope .();
			if (File.ReadAllText(path, text, true) case .Err)
				return false;
			outToml.Parse(text);
			return true;
		}

		public void Parse(StringView text)
		{
			String table = scope .();
			for (var line in text.Split('\n'))
			{
				line.Trim();
				if (line.IsEmpty || line.StartsWith('#'))
					continue;
				if (line.StartsWith('[') && !line.StartsWith("[["))
				{
					int close = line.IndexOf(']');
					table.Set((close > 0) ? line.Substring(1, close - 1) : line.Substring(1));
					table.Trim();
					continue;
				}
				int eq = line.IndexOf('=');
				if (eq <= 0)
					continue;
				var key = line.Substring(0, eq);
				key.Trim();
				key = Unquote(key);
				var value = line.Substring(eq + 1);
				value.Trim();
				String prefix = scope .(table);
				if (!prefix.IsEmpty)
					prefix.Append('.');
				prefix.Append(key);
				ParseValue(prefix, value);
			}
		}

		static StringView Unquote(StringView s)
		{
			var s;
			s.Trim();
			if (s.Length >= 2 && (s[0] == '"' || s[0] == '\'') && s[s.Length - 1] == s[0])
				return s.Substring(1, s.Length - 2);
			return s;
		}

		void ParseValue(StringView key, StringView value)
		{
			var value;
			value.Trim();
			if (value.StartsWith('{'))
			{
				// Inline table: split on top-level commas.
				int end = value.LastIndexOf('}');
				var inner = (end > 0) ? value.Substring(1, end - 1) : value.Substring(1);
				int depth = 0;
				bool inStr = false;
				int segStart = 0;
				for (int i = 0; i <= inner.Length; i++)
				{
					bool atEnd = i == inner.Length;
					char8 c = atEnd ? ',' : inner[i];
					if (c == '"' && !atEnd)
						inStr = !inStr;
					if (inStr)
						continue;
					if (c == '{' || c == '[')
						depth++;
					else if (c == '}' || c == ']')
						depth--;
					else if (c == ',' && depth == 0)
					{
						var part = inner.Substring(segStart, i - segStart);
						segStart = i + 1;
						int eq = part.IndexOf('=');
						if (eq <= 0)
							continue;
						var k = Unquote(part.Substring(0, eq));
						String sub = scope .(key);
						sub.AppendF(".{}", k);
						ParseValue(sub, part.Substring(eq + 1));
					}
				}
				return;
			}
			if (value.StartsWith('"'))
			{
				int close = value.Substring(1).IndexOf('"');
				value = (close >= 0) ? value.Substring(1, close) : value.Substring(1);
			}
			else
			{
				int hash = value.IndexOf('#');
				if (hash >= 0)
					value = value.Substring(0, hash);
				value.Trim();
			}
			Entries.Add((new String(key), new String(value)));
		}

		public StringView Get(StringView key)
		{
			for (let e in Entries)
				if (e.key == key)
					return e.value;
			return default;
		}

		/// Names directly under a table: Children("Projects") -> ["GameKit", "JsonKit", ...].
		public void Children(StringView table, List<StringView> outNames)
		{
			for (let e in Entries)
			{
				if (e.key.Length <= table.Length + 1 || !e.key.StartsWith(table) || e.key[table.Length] != '.')
					continue;
				var rest = e.key.Substring(table.Length + 1);
				int dot = rest.IndexOf('.');
				if (dot >= 0)
					rest = rest.Substring(0, dot);
				if (!outNames.Contains(rest))
					outNames.Add(rest);
			}
		}
	}
}
