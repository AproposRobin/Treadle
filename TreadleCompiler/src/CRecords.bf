using System;
using System.Collections;
using Treadle.Model;
using Treadle.Document;
using Treadle.Format;

namespace Treadle.Compiler
{
	/// The C type records of a `.cdecl` (docs/C-Import.md, "The `.cdecl` file"): `cstruct` /
	/// `cunion` become value types `C.<name>` with the imported layout (fields, Make / Break,
	/// pointers to them), `cenum` an enum with its values, `ctypedef` a name for another type,
	/// `cconst` a constant of the set's type (`C.<set>.<NAME>`). The type-file reader keeps these
	/// records as lines it does not model; Declare reads them here. A record two sets both import
	/// (the same C type, `FILE`) is declared once.
	extension Compilation
	{
		/// Every unknown record line of a type file, in file order (the reader hangs them after the
		/// record before them).
		static void UnknownLines(TypeDocument doc, List<String> outLines)
		{
			void Add(RecordExtras e)
			{
				if (e != null && e.Trailing != null)
					for (let l in e.Trailing)
						outLines.Add(l);
			}
			Add(doc.FileExtras);
			Add(doc.Header.Extras);
			for (let m in doc.Members)
			{
				Add(m.Extras);
				for (let p in m.Params)
					Add(p.Extras);
				for (let p in m.Outs)
					Add(p.Extras);
				for (let l in m.Locals)
					Add(l.Extras);
			}
		}

		/// The functions a `.cdecl`'s `cvar` records are read through (`via <function> ...`).
		static void CVarFunctions(TypeDocument doc, List<String> outNames)
		{
			List<String> lines = scope .();
			UnknownLines(doc, lines);
			for (let line in lines)
			{
				if (!line.StartsWith("\tvia "))
					continue;
				var rest = StringView(line, 5);
				rest.Trim();
				let sp = rest.IndexOf(' ');
				outNames.Add(new String((sp > 0) ? rest.Substring(0, sp) : rest));
			}
		}

		/// Step 1 (names): a type per `cstruct` / `cunion` / `cenum` / `ctypedef` of a C import
		/// set's declarations; `cconst` lines are kept on the set's type for its members.
		void DeclareCRecords(SourceUnit u, TypeSym set)
		{
			List<String> lines = scope .();
			UnknownLines(u.Doc, lines);
			TypeSym cur = null;
			// A `cvar` record's property lines (`via`) stay with it on the set's own lines.
			bool inVar = false;
			List<StringView> tok = scope .();
			for (let line in lines)
			{
				if (line.StartsWith('\t'))
				{
					if (cur != null && cur.CLines != null)
						cur.CLines.Add(new String(line));
					else if (inVar)
						set.CLines.Add(new String(line));
					continue;
				}
				cur = null;
				inVar = false;
				tok.Clear();
				let sp = line.IndexOf(' ');
				StringView kind = (sp > 0) ? line.Substring(0, sp) : line;
				StringView rest = (sp > 0) ? line.Substring(sp + 1) : "";
				switch (kind)
				{
				case "cconst", "cvar":
					if (set.CLines == null)
						set.CLines = new .();
					set.CLines.Add(new String(line));
					inVar = kind == "cvar";
				case "cstruct", "cunion", "cenum", "ctypedef":
					let nameEnd = rest.IndexOf(' ');
					StringView name = (nameEnd > 0) ? rest.Substring(0, nameEnd) : rest;
					name.Trim();
					if (name.IsEmpty)
						continue;
					let full = scope String()..AppendF("C.{}", name);
					if (Table.Find(full) != null)
						continue; // another set declares the same C type
					TypeSym t = new .();
					t.Name.Set(name);
					t.Namespace.Set("C");
					t.FullName.Set(full);
					t.Path.Set(u.Path);
					t.Project.Set("<C>");
					t.IsCRecord = true;
					t.Category = new String(set.Category ?? "C");
					t.Static = false;
					t.CLines = new .();
					t.CLines.Add(new String(line));
					switch (kind)
					{
					case "cenum": t.Kind = .Enum;
					case "ctypedef":
						t.Kind = .Struct;
						StringView target = (nameEnd > 0) ? rest.Substring(nameEnd + 1) : "";
						target.Trim();
						t.AliasRef = TypeRef.Parse(target);
					default:
						t.Kind = .Struct;
						t.IsCUnion = kind == "cunion";
					}
					t.Self = Table.Named(t, default);
					Table.AddType(t);
					CRecords.Add(t);
					cur = t;
				default:
				}
			}
		}

		/// Step 3 (members): fields and their offsets, enum values, the size and alignment; the
		/// set's constants.
		void DeclareCRecordMembers()
		{
			List<StringView> tok = scope .();
			String why = scope .();
			for (let t in CRecords)
			{
				if (t.AliasRef != null)
					continue;
				NameCtx c = .(t, null, .(t.FullName, "", "", t.Path));
				c.Quiet = true;
				for (int i < t.CLines.Count)
				{
					tok.Clear();
					why.Clear();
					let line = t.CLines[i];
					if (!RecordText.Tokenize(line, tok, why) || tok.IsEmpty)
						continue;
					if (i == 0)
					{
						if (t.Kind == .Enum)
						{
							t.Underlying = (tok.Count > 2) ? Table.Prim(tok[2]) : null;
							if (t.Underlying == null || !t.Underlying.IsInteger)
								t.Underlying = Table.Int32;
						}
						continue;
					}
					switch (tok[0])
					{
					case "size": t.CSize = int64.Parse(tok.Count > 1 ? tok[1] : "0").GetValueOrDefault();
					case "align": t.CAlign = Math.Max(1, int64.Parse(tok.Count > 1 ? tok[1] : "1").GetValueOrDefault());
					case "pack": t.CBlob = true;
					case "opaque": t.COpaque = true;
					case "value":
						if (tok.Count < 3)
							continue;
						MemberSym m = new .();
						m.Kind = .Case;
						m.Name.Set(tok[1]);
						m.Owner = t;
						m.Static = true;
						m.CaseValue = int64.Parse(tok[2]).GetValueOrDefault();
						t.Members.Add(m);
					case "field":
						if (tok.Count < 4)
							continue;
						let tr = TypeRef.Parse(tok[2]);
						defer delete tr;
						MemberSym m = new .();
						m.Kind = .Field;
						m.Name.Set(tok[1]);
						m.Owner = t;
						m.Type = Resolve(tr, c) ?? Table.Error;
						if (m.Type.IsError)
							m.Type = Table.FixedArray(Table.UInt8, 0);
						m.COffset = int64.Parse(tok[3]).GetValueOrDefault();
						t.Members.Add(m);
					default:
					}
				}
			}
			// The constants of each set: static constant fields of `C.<set>` with their value.
			for (let u in Units)
			{
				if (!u.IsCDecl || u.Sym == null || u.Sym.CLines == null)
					continue;
				let set = u.Sym;
				NameCtx c = .(set, null, .(set.FullName, "", "", set.Path));
				c.Quiet = true;
				MemberSym lastVar = null;
				for (let line in set.CLines)
				{
					tok.Clear();
					why.Clear();
					if (!RecordText.Tokenize(line, tok, why) || tok.IsEmpty)
						continue;
					// `cvar <name> <Type>` (an extern variable: a static field of the set reached by
					// its C name), then `via <function> [<arg>] [deref]` when a function reads it.
					if (tok[0] == "via")
					{
						if (lastVar != null && tok.Count >= 2)
						{
							lastVar.CVarVia = new String(tok[1]);
							for (int i = 2; i < tok.Count; i++)
							{
								if (tok[i] == "deref")
									lastVar.CVarDeref = true;
								else if (lastVar.CVarArg == null)
									lastVar.CVarArg = new String(tok[i]);
							}
						}
						continue;
					}
					lastVar = null;
					if (tok[0] == "cvar")
					{
						if (tok.Count < 3)
							continue;
						let vr = TypeRef.Parse(tok[2]);
						defer delete vr;
						let vt = Resolve(vr, c);
						if (vt == null || vt.IsError || vt.IsVoid)
							continue;
						MemberSym v = new .();
						v.Kind = .Field;
						v.Name.Set(tok[1]);
						v.Owner = set;
						v.Type = vt;
						v.Static = true;
						v.CVar = true;
						v.ImportName = new String(tok[1]);
						set.Members.Add(v);
						lastVar = v;
						continue;
					}
					if (tok.Count < 4)
						continue;
					let tr = TypeRef.Parse(tok[2]);
					defer delete tr;
					let ct = Resolve(tr, c);
					if (ct == null || ct.IsError)
						continue;
					MemberSym m = new .();
					m.Kind = .Field;
					m.Name.Set(tok[1]);
					m.Owner = set;
					m.Type = ct;
					m.Static = true;
					m.Const = true;
					m.Init = new String(tok[3]);
					set.Members.Add(m);
				}
			}
		}

		/// The x64 size and alignment of a field type (-1 when it is not a C layout type).
		public static int64 CSizeOf(KType t, out int64 align)
		{
			align = 1;
			switch (t.Kind)
			{
			case .Bool:
				return 1;
			case .Int, .Char, .Float:
				let bytes = Math.Max(1, t.Bits / 8);
				align = bytes;
				return bytes;
			case .Pointer, .Function, .Delegate, .Array:
				align = 8;
				return 8;
			case .FixedArray:
				let e = CSizeOf(t.Element, out align);
				return (e < 0) ? -1 : e * t.Length;
			case .Named:
				let s = t.Sym;
				if (s.IsCRecord && s.Kind == .Enum)
					return CSizeOf(s.Underlying ?? t, out align);
				if (s.IsCRecord)
				{
					align = s.CAlign;
					return s.CSize;
				}
				if (s.Kind == .Class || s.Kind == .Interface)
				{
					align = 8;
					return 8;
				}
				return -1;
			default:
				return -1;
			}
		}

		/// Step 4 (layout): the fields' index, and whether the record lays out naturally (else the
		/// back end gets its bytes and Lower reaches the fields by offset).
		void LayoutCRecords()
		{
			for (let t in CRecords)
			{
				if (t.AliasRef != null || t.Kind != .Struct)
					continue;
				int64 cursor = 0;
				int64 maxAlign = 1;
				bool natural = !t.IsCUnion && !t.CBlob;
				for (let m in t.Members)
				{
					if (m.Kind != .Field)
						continue;
					m.FieldIndex = (int32)t.AllFields.Count;
					t.AllFields.Add(m);
					let size = CSizeOf(m.Type, var align);
					if (size < 0)
					{
						natural = false;
						continue;
					}
					maxAlign = Math.Max(maxAlign, align);
					cursor = (cursor + align - 1) / align * align;
					if (cursor != m.COffset)
						natural = false;
					cursor = m.COffset + size;
				}
				cursor = (cursor + maxAlign - 1) / maxAlign * maxAlign;
				if (cursor != t.CSize || (maxAlign != t.CAlign && !t.AllFields.IsEmpty))
					natural = false;
				t.CBlob = !natural && !t.COpaque;
				t.LayoutState = 2;
				if (t.CAlign > 16)
					Error("T1077", .(t.FullName, "", "", t.Path), "", "", scope $"the C record {t.Name} needs {t.CAlign}-byte alignment, above the 16 bytes Treadle allocates and lays out: leave it out of the set (hide or only) and reach it through a pointer from C", .Declare);

			}
		}
	}
}
