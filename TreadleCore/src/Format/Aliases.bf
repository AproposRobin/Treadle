using System;

namespace Treadle.Format
{
	/// Renamed node kinds and pins (docs/Format-Stability.md 4): the reader maps an old name to the
	/// current one, the writer writes only the current one, so an old file loads with no migration
	/// step and no version bump and its next save shows the rename as a normal diff.
	///
	/// Rules: rows are only ever added (the table never shrinks; frozen at 1.0); an old name is
	/// never reused for another meaning; a rename that changes meaning (pins added or split,
	/// setting values changed) is a version bump with a step in Migrations.bf, not an alias. Each
	/// row adds a dated deprecation line to docs/Graph-Format.md 8.
	static class Aliases
	{
		/// `kind <old word> -> <new word>`, with the date the alias was added.
		static (StringView old, StringView now, StringView since)[?] sKinds = .(
			// Placeholder, the documented example: no node kind has been renamed yet. No release
			// ever wrote `ExampleBranch`; the codec self test reads it as a Branch.
			("ExampleBranch", "Branch", "2026-10-25")
		);

		/// `pin <Kind>.<old pin> -> <new pin>` (the Kind is the current word).
		static (StringView kind, StringView old, StringView now, StringView since)[?] sPins = .(
			// Placeholder, the documented example: no stored pin has been renamed yet.
			("Branch", "example-condition", "condition", "2026-10-25")
		);

		/// The current node kind word for `word` (itself when it is not an old name).
		public static StringView Kind(StringView word)
		{
			for (let a in sKinds)
				if (a.old == word)
					return a.now;
			return word;
		}

		/// The current name of pin `pin` on a node of kind `kindWord` (itself when it is not an old
		/// name). A split field pin `<pin>.<field>` maps its first part.
		public static StringView Pin(StringView kindWord, StringView pin, String buffer)
		{
			var head = pin;
			let dot = pin.IndexOf('.');
			if (dot > 0)
				head = pin.Substring(0, dot);
			for (let a in sPins)
			{
				if (a.kind != kindWord || a.old != head)
					continue;
				if (dot < 0)
					return a.now;
				buffer.Set(a.now);
				buffer.Append(pin.Substring(dot));
				return buffer;
			}
			return pin;
		}
	}
}
