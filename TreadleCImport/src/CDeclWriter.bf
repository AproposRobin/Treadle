using System;
using System.Collections;
using Treadle.Format;

namespace Treadle.CImport
{
	/// Writes a CDeclSet as a `.cdecl` file: a type file (Graph-Format.md 3) whose `type <set> class`
	/// in namespace `C` holds the functions, followed by the C type records (`cconst`, `cenum`,
	/// `cstruct` / `cunion`, `ctypedef`, `cvar`) that a type-file reader keeps as records it does
	/// not model. The output is in the codec's canonical form, so reading and writing it back with
	/// TreadleCodec gives the same bytes, and it is a pure function of the declarations: every
	/// group is sorted by name and the function ids are derived from the names.
	static class CDeclWriter
	{
		public const String IdAlphabet = "0123456789abcdefghjkmnpqrstvwxyz";

		public static void Write(CDeclSet s, String outText)
		{
			outText.AppendF("# treadle {}\n", TreadleCodec.Current);
			outText.AppendF("type {} class\n", s.Name);
			outText.Append("\tnamespace C\n");
			outText.Append("\tstatic\n");
			String doc = scope .();
			doc.AppendF("C declarations of the import set {} ({}), written by the C header import. Do not edit: the import rewrites this file.", s.Name, s.SourceFile);
			outText.Append("\tdoc ");
			RecordText.Quote(doc, outText);
			outText.Append('\n');

			HashSet<String> ids = scope .();
			defer { for (let i in ids) delete i; }
			List<CFunction> funcs = scope .();
			funcs.AddRange(s.Functions);
			funcs.Sort(scope (a, b) => RecordText.CompareOrdinal(a.Name, b.Name));
			for (let f in funcs)
			{
				outText.Append('\n');
				String id = scope .();
				MakeId(f.Name, ids, id);
				outText.AppendF("function {} {}\n", id, f.Name);
				outText.Append("\tstatic\n");
				if (f.Returns != null)
					outText.AppendF("\treturns {}\n", f.Returns);
				if (f.CallConv != null)
					outText.AppendF("\tcconv {}\n", f.CallConv);
				if (f.Variadic)
					outText.Append("\tattr Variadic\n");
				for (let p in f.Params)
					outText.AppendF("param {} {}\n", p.Name, p.Type);
			}

			List<CConst> consts = scope .();
			consts.AddRange(s.Consts);
			consts.Sort(scope (a, b) => RecordText.CompareOrdinal(a.Name, b.Name));
			for (let c in consts)
				outText.AppendF("cconst {} {} {}\n", c.Name, c.Type, c.Value);

			List<CEnum> enums = scope .();
			enums.AddRange(s.Enums);
			enums.Sort(scope (a, b) => RecordText.CompareOrdinal(a.Name, b.Name));
			for (let e in enums)
			{
				outText.AppendF("cenum {} {}\n", e.Name, e.Underlying);
				for (let v in e.Values)
					outText.AppendF("\tvalue {} {}\n", v.name, v.value);
			}

			List<CRecord> recs = scope .();
			recs.AddRange(s.Records);
			recs.Sort(scope (a, b) => RecordText.CompareOrdinal(a.Name, b.Name));
			for (let r in recs)
			{
				outText.AppendF("{} {}\n", r.IsUnion ? "cunion" : "cstruct", r.Name);
				if (r.Opaque)
				{
					outText.Append("\topaque\n");
					continue;
				}
				outText.AppendF("\tsize {}\n", r.Size);
				outText.AppendF("\talign {}\n", r.Align);
				if (r.Pack > 0)
					outText.AppendF("\tpack {}\n", r.Pack);
				for (let f in r.Fields)
					outText.AppendF("\tfield {} {} {}\n", f.Name, f.Type, f.Offset);
			}

			List<CTypedef> tds = scope .();
			tds.AddRange(s.Typedefs);
			tds.Sort(scope (a, b) => RecordText.CompareOrdinal(a.Name, b.Name));
			for (let t in tds)
			{
				outText.AppendF("ctypedef {} {}\n", t.Name, t.Target);
				if (t.CallConv != null)
					outText.AppendF("\tcconv {}\n", t.CallConv);
			}

			List<CVar> vars = scope .();
			vars.AddRange(s.Vars);
			vars.Sort(scope (a, b) => RecordText.CompareOrdinal(a.Name, b.Name));
			for (let v in vars)
			{
				outText.AppendF("cvar {} {}\n", v.Name, v.Type);
				// read through a function: `via _errno deref`, `via __acrt_iob_func 1`
				if (!v.Via.IsEmpty)
					outText.AppendF("\tvia {}{}{}{}\n", v.Via, v.Arg.IsEmpty ? "" : " ", v.Arg, v.Deref ? " deref" : "");
			}
		}

		/// A record id from the name (FNV-1a, 5 characters of the id alphabet), salted until it is
		/// unused, so ids stay put when other functions come and go.
		public static void MakeId(StringView name, HashSet<String> used, String outId)
		{
			for (uint32 salt = 0; ; salt++)
			{
				uint32 h = 2166136261;
				for (let c in name.RawChars)
				{
					h ^= (uint8)c;
					h *= 16777619;
				}
				for (uint32 k = salt; k > 0; k >>= 8)
				{
					h ^= (k & 0xFF) + 1;
					h *= 16777619;
				}
				let start = outId.Length;
				// Ids start with a letter, so no id reads as a number.
				outId.Append(IdAlphabet[10 + (int)(h % 22)]);
				h /= 22;
				for (int i < 4)
				{
					outId.Append(IdAlphabet[(int)(h & 31)]);
					h >>= 5;
				}
				let id = StringView(outId, start);
				if (!used.ContainsAlt(id))
				{
					used.Add(new String(id));
					return;
				}
				outId.RemoveToEnd(start);
			}
		}
	}
}
