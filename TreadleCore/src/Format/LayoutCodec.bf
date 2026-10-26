using System;
using System.Collections;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Model;

namespace Treadle.Format
{
	/// The layout sidecar `<Type>.treadle.layout` (Graph-Format.md 4): positions, comment boxes,
	/// knots, views, collapsed nodes, grouped per Sheet. Disposable: losing it loses only layout.
	static class LayoutCodec
	{
		/// The comment box colours the `box` colour index names.
		public static uint32[8] Palette = .(0xB4FFFFFF, 0xB46A6AE0, 0xB45ABEF0, 0xB46AD08A, 0xB4E0B45A, 0xB4D07AC8, 0xB4A0A0A0, 0xB4404040);

		public static int32 PaletteIndex(uint32 color)
		{
			for (int i < Palette.Count)
				if (Palette[i] == color)
					return (.)i;
			return -1;
		}

		/// The largest canvas coordinate or size a layout file may give. NaN, infinity and larger
		/// values do not read (the line is reported): a file with `node a1 NaN 0` / `1e309` hung the
		/// editor on open (docs/Security-Review.md, finding 24).
		public const float MaxCoord = 1e7f;

		static bool Num(StringView s, out float v)
		{
			if (float.Parse(s) case .Ok(let f) && f == f && f >= -MaxCoord && f <= MaxCoord)
			{
				v = f;
				return true;
			}
			v = 0;
			return false;
		}

		public static bool Read(StringView text, TypeDocument doc, List<FormatError> errors)
		{
			doc.ClearLayout();
			// Layout is lenient (docs/Format-Stability.md 3.2): an older one is migrated, a newer one
			// is not read (the caller lays the Sheets out again); it never stops a program opening.
			List<StringView> lines = scope .();
			String migrated = scope .();
			if (!TreadleCodec.Prepare(text, FormatNames.LayoutWord, lines, migrated, let version, false, errors))
				return false;
			doc.LayoutMigratedFrom = (version < TreadleCodec.Current) ? version : 0;
			String sheet = scope .();
			bool inSheet = false;
			List<StringView> tok = scope .();
			String why = scope .();
			for (int i = 1; i < lines.Count; i++)
			{
				let line = lines[i];
				int lineNo = i + 1;
				if (line.IsEmpty)
					continue;
				void Keep()
				{
					doc.LayoutUnknown.Add((new String(inSheet ? sheet : ""), new String(line)));
				}
				if (line.StartsWith('#'))
				{
					Keep();
					continue;
				}
				tok.Clear();
				why.Clear();
				let body = line.StartsWith('\t') ? line.Substring(1) : line;
				if (!RecordText.Tokenize(body, tok, why))
				{
					TreadleCodec.AddError(errors, lineNo, "", why);
					continue;
				}
				if (tok.IsEmpty)
					continue;
				if (!line.StartsWith('\t'))
				{
					if (tok[0] == "sheet" && tok.Count >= 2)
					{
						sheet.Set(tok[1]);
						inSheet = true;
					}
					else
					{
						inSheet = false;
						Keep();
					}
					continue;
				}
				if (!inSheet)
				{
					Keep();
					continue;
				}
				bool ok = true;
				switch (tok[0])
				{
				case "node":
					if (tok.Count >= 4 && Num(tok[2], let x) && Num(tok[3], let y))
					{
						NodePos p = default;
						p.X = x;
						p.Y = y;
						p.W = 0;
						if (tok.Count >= 5)
							Num(tok[4], out p.W);
						doc.SetLayout(scope $"{sheet}|{tok[1]}", p);
					}
					else
						ok = false;
				case "view", "saved":
					int n = 0;
					int at = 1;
					if (tok[0] == "saved")
					{
						if (tok.Count < 2 || !(int.Parse(tok[1]) case .Ok(out n)))
						{
							ok = false;
							break;
						}
						at = 2;
					}
					if (tok.Count >= at + 3 && Num(tok[at], let x) && Num(tok[at + 1], let y) && Num(tok[at + 2], let z) && z > 0)
						doc.SetView(sheet, n, x, y, z);
					else
						ok = false;
				case "box":
					if (tok.Count >= 8 && Num(tok[2], let x) && Num(tok[3], let y) && Num(tok[4], let w) && Num(tok[5], let h) &&
						(int32.Parse(tok[7]) case .Ok(let ci)))
					{
						GraphComment c = new .();
						c.Key.Set(tok[1]);
						c.MethodKey.Set(sheet);
						c.X = x;
						c.Y = y;
						c.W = w;
						c.H = h;
						RecordText.Unquote(tok[6], c.Text);
						c.ColorIndex = ci;
						if (ci >= 0 && ci < Palette.Count)
							c.Color = Palette[ci];
						doc.Comments.Add(c);
					}
					else
						ok = false;
				case "route":
					// An end whose pin name needs quoting is one string token (Graph-Format.md 2).
					let e1 = RecordText.Unquote(tok.Count >= 3 ? tok[1] : "", .. scope String());
					let e2 = RecordText.Unquote(tok.Count >= 3 ? tok[2] : "", .. scope String());
					let a = e1.IndexOf('.');
					let b = e2.IndexOf('.');
					if (a <= 0 || b <= 0)
					{
						ok = false;
						break;
					}
					GraphReroute r = new .();
					r.MethodKey.Set(sheet);
					r.FromNode.Set(e1.Substring(0, a));
					r.FromPin.Set(e1.Substring(a + 1));
					r.ToNode.Set(e2.Substring(0, b));
					r.ToPin.Set(e2.Substring(b + 1));
					for (int k = 3; k < tok.Count; k++)
					{
						let comma = tok[k].IndexOf(',');
						if (comma > 0 && Num(tok[k].Substring(0, comma), let x) && Num(tok[k].Substring(comma + 1), let y))
						{
							NodePos p = default;
							p.X = x;
							p.Y = y;
							r.Points.Add(p);
						}
						else
							ok = false;
					}
					doc.Reroutes.Add(r);
				case "collapsed":
					if (tok.Count >= 2)
						doc.Collapsed.Add(new String(scope $"{sheet}|{tok[1]}"));
				case "pinned":
					if (tok.Count >= 2)
						doc.SetBubblePinned(sheet, tok[1], true);
				default:
					Keep();
				}
				if (!ok)
					TreadleCodec.AddError(errors, lineNo, "", scope $"`{tok[0]}` line does not read");
			}
			return errors.IsEmpty;
		}

		static void Int(float v, String outText) => outText.AppendF("{}", (int)Math.Round(v));

		static void Zoom(float z, String outText)
		{
			let r = Math.Round(z * 1000) / 1000;
			if (r == Math.Floor(r))
				outText.AppendF("{}.0", (int)r);
			else
			{
				String s = scope .();
				s.AppendF("{0:0.###}", r);
				outText.Append(s);
			}
		}

		public static void Write(TypeDocument doc, String outText)
		{
			doc.CaptureAllLayouts();
			String body = scope .();
			for (let s in doc.Sheets)
			{
				String block = scope .();
				String key = s.Key;
				for (let v in doc.Views)
				{
					if (v.MethodKey != key)
						continue;
					if (v.N == 0)
						block.Append("\tview ");
					else
						block.AppendF("\tsaved {} ", v.N);
					Int(v.X, block);
					block.Append(' ');
					Int(v.Y, block);
					block.Append(' ');
					Zoom(v.Zoom, block);
					block.Append('\n');
				}
				// Nodes and collapsed node groups by id; ids gone from the type file are pruned.
				List<(StringView key, float x, float y)> places = scope .();
				if (s.IsBuilt)
				{
					for (let n in s.Graph.Nodes)
						if (n.HasPos)
							places.Add((n.Key, n.X, n.Y));
					for (let gr in s.Graph.Groups)
						if (gr.HasPos && !gr.Key.IsEmpty)
							places.Add((gr.Key, gr.X, gr.Y));
				}
				places.Sort(scope (a, b) => RecordText.CompareOrdinal(a.key, b.key));
				for (let p in places)
				{
					block.AppendF("\tnode {} ", p.key);
					Int(p.x, block);
					block.Append(' ');
					Int(p.y, block);
					if (doc.Layout.TryGetValue(scope String()..AppendF("{}|{}", key, p.key), let pos) && pos.W != 0)
					{
						block.Append(' ');
						Int(pos.W, block);
					}
					block.Append('\n');
				}
				for (let c in doc.Comments)
				{
					if (c.MethodKey != key)
						continue;
					if (c.Key.IsEmpty)
						RecordIds.New(c.Key);
					let pi = PaletteIndex(c.Color);
					if (pi >= 0)
						c.ColorIndex = pi;
					block.AppendF("\tbox {} ", c.Key);
					Int(c.X, block);
					block.Append(' ');
					Int(c.Y, block);
					block.Append(' ');
					Int(c.W, block);
					block.Append(' ');
					Int(c.H, block);
					block.Append(' ');
					RecordText.Quote(c.Text, block);
					block.AppendF(" {}\n", c.ColorIndex);
				}
				for (let r in doc.Reroutes)
				{
					if (r.MethodKey != key || r.Points.IsEmpty)
						continue;
					block.AppendF("\troute {} {}", RecordText.End(r.FromNode, r.FromPin, .. scope String()), RecordText.End(r.ToNode, r.ToPin, .. scope String()));
					for (let p in r.Points)
					{
						block.Append(' ');
						Int(p.X, block);
						block.Append(',');
						Int(p.Y, block);
					}
					block.Append('\n');
				}
				List<String> collapsed = scope .();
				for (let c in doc.Collapsed)
					if (c.StartsWith(key) && c.Length > key.Length && c[key.Length] == '|')
					{
						// A node or group that is gone (an undone Collapse Nodes) is left out.
						let id = StringView(c, key.Length + 1);
						if (s.IsBuilt && s.Graph.FindNodeByKey(id) == null && s.Graph.FindGroupByKey(id) == null)
							continue;
						collapsed.Add(c);
					}
				collapsed.Sort(scope (a, b) => RecordText.CompareOrdinal(a, b));
				for (let c in collapsed)
					block.AppendF("\tcollapsed {}\n", StringView(c, key.Length + 1));
				for (let b in doc.BubblePins)
					if (b.MethodKey == key)
						block.AppendF("\tpinned {}\n", b.NodeKey);
				for (let u in doc.LayoutUnknown)
					if (u.sheet == key)
						block.AppendF("{}\n", u.line);
				if (!block.IsEmpty)
					body.AppendF("sheet {}\n{}", key, block);
			}
			for (let u in doc.LayoutUnknown)
				if (u.sheet.IsEmpty)
					body.AppendF("{}\n", u.line);
			if (body.IsEmpty)
				return;
			outText.AppendF("# treadle-layout {}\n{}", TreadleCodec.Current, body);
		}
	}

	/// Project files (`.tproj`, Graph-Format.md 5) and C import sets (`.cimport`, 6): read and
	/// written with the same lexical layer. Nothing consumes them yet beyond the editor's project
	/// detection.
	static class ProjectCodec
	{
		public static bool ReadProject(StringView text, ProjectFile p, List<FormatError> errors)
		{
			List<StringView> lines = scope .();
			String migrated = scope .();
			if (!TreadleCodec.Prepare(text, FormatNames.ProjectWord, lines, migrated, out p.FormatVersion, false, errors))
				return false;
			List<StringView> tok = scope .();
			String why = scope .();
			ProjectConfig config = null;
			bool inProject = false;
			bool keepProps = false;
			for (int i = 1; i < lines.Count; i++)
			{
				let line = lines[i];
				if (line.IsEmpty)
					continue;
				tok.Clear();
				why.Clear();
				let isProp = line.StartsWith('\t');
				if (line.StartsWith('#') || !RecordText.Tokenize(isProp ? line.Substring(1) : line, tok, why) || tok.IsEmpty)
				{
					if (!why.IsEmpty)
						TreadleCodec.AddError(errors, i + 1, "", why);
					else
						p.Tail.Add(new String(line));
					continue;
				}
				StringView arg = (tok.Count > 1) ? tok[1] : "";
				if (isProp)
				{
					if (keepProps)
						p.Tail.Add(new String(line));
					else if (config != null)
						config.Settings.Add(new Setting(tok[0], RecordText.RestAfter(line.Substring(1), 1)));
					else if (inProject)
					{
						switch (tok[0])
						{
						case "kind": p.Kind.Set(arg);
						case "entry": DeleteAndNullify!(p.Entry); p.Entry = TypeRef.Parse(arg);
						case "output": p.Output.Clear(); RecordText.Unquote(arg, p.Output);
						case "version": p.Version.Set(arg);
						case "namespace": p.Namespace.Set(arg);
						default: p.Extras.AddInner("", line);
						}
					}
					else
						TreadleCodec.AddError(errors, i + 1, "", "a property line outside a record");
					continue;
				}
				config = null;
				inProject = false;
				keepProps = false;
				switch (tok[0])
				{
				case "project": p.Name.Clear(); RecordText.Unquote(arg, p.Name); inProject = true;
				case "depends": p.Depends.Add(RecordText.TextOf(arg));
				case "cimport": p.CImports.Add(RecordText.TextOf(arg));
				case "source": p.Sources.Add(RecordText.TextOf(arg));
				case "config":
					config = new .();
					RecordText.Unquote(arg, config.Name);
					p.Configs.Add(config);
				default:
					p.Tail.Add(new String(line));
					keepProps = true;
				}
			}
			return errors.IsEmpty;
		}

		public static void WriteProject(ProjectFile p, String outText)
		{
			outText.AppendF("# tproj {}\n", TreadleCodec.Current);
			outText.AppendF("project {}\n", RecordText.Text(p.Name, .. scope String()));
			PropWriter pw = scope .();
			if (!p.Kind.IsEmpty) pw.Add("kind", p.Kind);
			if (p.Entry != null) pw.Add("entry", p.Entry.ToString(.. scope String()));
			if (!p.Output.IsEmpty) pw.Add("output", RecordText.Text(p.Output, .. scope String()));
			if (!p.Version.IsEmpty) pw.Add("version", p.Version);
			if (!p.Namespace.IsEmpty) pw.Add("namespace", p.Namespace);
			pw.Emit(p.Extras, outText);
			for (let d in p.Depends)
				outText.AppendF("depends {}\n", RecordText.Text(d, .. scope String()));
			for (let c in p.CImports)
				outText.AppendF("cimport {}\n", RecordText.Text(c, .. scope String()));
			for (let c in p.Configs)
			{
				outText.AppendF("config {}\n", RecordText.Text(c.Name, .. scope String()));
				for (let s in c.Settings)
					outText.AppendF("\t{} {}\n", s.Key, s.Value);
			}
			for (let s in p.Sources)
				outText.AppendF("source {}\n", RecordText.Text(s, .. scope String()));
			for (let t in p.Tail)
				outText.AppendF("{}\n", t);
		}

		public static bool ReadCImport(StringView text, CImportFile f, List<FormatError> errors)
		{
			List<StringView> lines = scope .();
			String migrated = scope .();
			if (!TreadleCodec.Prepare(text, "cimport", lines, migrated, out f.FormatVersion, false, errors))
				return false;
			List<StringView> tok = scope .();
			String why = scope .();
			CImportSet set = null;
			// A line the set does not model (`prefix`, `param`, `bin`, a comment) stays after the
			// key group it followed (C-Import.md shows `bin` after `lib`).
			String lastKey = scope .();
			for (int i = 1; i < lines.Count; i++)
			{
				let line = lines[i];
				if (line.IsEmpty)
					continue;
				tok.Clear();
				why.Clear();
				let isProp = line.StartsWith('\t');
				if (line.StartsWith('#') || !RecordText.Tokenize(isProp ? line.Substring(1) : line, tok, why) || tok.IsEmpty)
				{
					if (!why.IsEmpty)
						TreadleCodec.AddError(errors, i + 1, "", why);
					else if (set != null)
						set.Extras.AddInner(lastKey, line);
					else if (f.Sets.IsEmpty && line.StartsWith('#'))
						f.Lead.Add(new String(line));
					else
						f.Tail.Add(new String(line));
					continue;
				}
				if (!isProp)
				{
					if (tok[0] == "import" && tok.Count >= 2)
					{
						lastKey.Clear();
						set = new .();
						RecordText.Unquote(tok[1], set.Name);
						f.Sets.Add(set);
					}
					else
					{
						set = null;
						f.Tail.Add(new String(line));
					}
					continue;
				}
				if (set == null)
				{
					f.Tail.Add(new String(line));
					continue;
				}
				void AddRest(List<String> into)
				{
					for (int k = 1; k < tok.Count; k++)
						into.Add(RecordText.TextOf(tok[k]));
				}
				switch (tok[0])
				{
				case "header": AddRest(set.Headers);
				case "include": AddRest(set.Includes);
				case "define": set.Defines.Add(new String(RecordText.RestAfter(line.Substring(1), 1)));
				case "lib": AddRest(set.Libs);
				case "pure": AddRest(set.Pure);
				case "hide": AddRest(set.Hide);
				case "only": AddRest(set.Only);
				case "category": DeleteAndNullify!(set.Category); set.Category = RecordText.Unquote(tok.Count > 1 ? tok[1] : "", .. new String());
				default:
					set.Extras.AddInner(lastKey, line);
					continue;
				}
				lastKey.Set(tok[0]);
			}
			return errors.IsEmpty;
		}

		public static void WriteCImport(CImportFile f, String outText)
		{
			outText.AppendF("# cimport {}\n", TreadleCodec.Current);
			for (let l in f.Lead)
				outText.AppendF("{}\n", l);
			for (let s in f.Sets)
			{
				outText.AppendF("import {}\n", RecordText.Text(s.Name, .. scope String()));
				PropWriter pw = scope .();
				for (let h in s.Headers) pw.Add("header", RecordText.Text(h, .. scope String()));
				for (let h in s.Includes) pw.Add("include", RecordText.Text(h, .. scope String()));
				for (let h in s.Defines) pw.Add("define", h);
				for (let h in s.Libs) pw.Add("lib", RecordText.Text(h, .. scope String()));
				void List(StringView key, List<String> words)
				{
					if (words.IsEmpty)
						return;
					String v = scope .();
					for (let w in words)
					{
						if (@w.Index > 0)
							v.Append(' ');
						RecordText.Text(w, v);
					}
					pw.Add(key, v);
				}
				List("pure", s.Pure);
				List("hide", s.Hide);
				List("only", s.Only);
				if (s.Category != null)
					pw.AddString("category", s.Category);
				pw.Emit(s.Extras, outText);
			}
			for (let t in f.Tail)
				outText.AppendF("{}\n", t);
		}
	}
}
