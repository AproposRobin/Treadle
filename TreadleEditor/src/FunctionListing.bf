using System;
using System.Collections;
using System.IO;
using Treadle.Document;
using Treadle.Backend.Driver;

namespace Treadle.Editor
{
	/// One instruction of a function's disassembly.
	class AsmLine
	{
		public uint64 Address;
		/// The encoding (`48 89 e5`).
		public String Bytes = new .() ~ delete _;
		/// `movq	%rsp, %rbp` (a relocation of an object file follows after `  ; `).
		public String Text = new .() ~ delete _;
		/// Index into FunctionListing.Groups.
		public int32 Group;
	}

	/// A run of instructions made for one node (its listing line in the debug line table).
	class AsmGroup
	{
		/// The node (`b7`); "" for code with no node (the prologue).
		public String Node = new .() ~ delete _;
		/// `Call Zoo.Animal.Speak()`.
		public String Title = new .() ~ delete _;
		/// The type the node belongs to (another type's when Release inlined it).
		public String Unit = new .() ~ delete _;
		public String SheetKey = new .() ~ delete _;
		public int32 Line;
		public int32 First;
		public int32 Count;
	}

	/// A function as built (docs/Debugging.md, "Disassembly"): its machine code from llvm-objdump grouped by
	/// the node each instruction belongs to (the line table points at the unit's listing, the `.nodemap`
	/// names the node of each line), its Sheet IR record (`.tir`, as Build lowers the saved project) and its
	/// LLVM IR (the unit's `.ll`). Found by the Sheet: the function whose debug info starts on the Sheet's
	/// Entry line, so generic instances (one per type argument) are all found. Read-only.
	class FunctionListing
	{
		public String Unit = new .() ~ delete _;
		public String SheetKey = new .() ~ delete _;
		public String SheetName = new .() ~ delete _;
		public String Config = new .() ~ delete _;
		/// The Itanium-mangled symbol shown (`_ZN3Zoo7Program4MainEv`) and its demangled form.
		public String Symbol = new .() ~ delete _;
		public String Demangled = new .() ~ delete _;
		/// Every symbol the Sheet was built into (generic instances), mangled and demangled.
		public List<String> Symbols = new .() ~ DeleteContainerAndItems!(_);
		public List<String> SymbolNames = new .() ~ DeleteContainerAndItems!(_);
		public List<AsmGroup> Groups = new .() ~ DeleteContainerAndItems!(_);
		public List<AsmLine> Lines = new .() ~ DeleteContainerAndItems!(_);
		public String SheetIR = new .() ~ delete _;
		public String LLVMIR = new .() ~ delete _;
		/// The file disassembled (the exe, or the object compiled for a stripped Release exe).
		public String Binary = new .() ~ delete _;
		/// The addresses are the exe's (the live position can be marked).
		public bool FromExe;
		/// How it was made, when it is not the exe's own code.
		public String Note = new .() ~ delete _;
		/// Why there is no disassembly.
		public String Error = new .() ~ delete _;

		/// The listing for `sheetKey` of type `unit` in `root`'s build/<config>. `pick`: which instance.
		public bool Produce(StringView root, StringView config, StringView unit, StringView sheetKey, StringView sheetName, int pick = 0)
		{
			Unit.Set(unit);
			SheetKey.Set(sheetKey);
			SheetName.Set(sheetName);
			Config.Set(config);
			String buildDir = scope $"{root}/build/{config}";
			if (!Directory.Exists(buildDir))
			{
				Error.AppendF("No {} build yet: build the project (F7) in the {} configuration first.", config, config);
				return false;
			}
			// the Sheet's lines in the unit's listing, and its Entry's line
			Dictionary<int32, String> nodeOfLine = scope .();
			defer { for (let v in nodeOfLine.Values) delete v; }
			List<String> listing = scope .();
			defer { ClearAndDeleteItems!(listing); }
			ReadLines(scope $"{buildDir}/{unit}.lst", listing);
			int32 entryLine = 0;
			{
				String map = scope .();
				if (File.ReadAllText(scope $"{buildDir}/{unit}.nodemap", map) case .Err)
				{
					Error.AppendF("The {} build has no node map for {}: build the project again.", config, unit);
					return false;
				}
				for (let line in map.Split('\n'))
				{
					var parts = line.Split(' ');
					let s = parts.GetNext();
					let n = parts.GetNext();
					let l = parts.GetNext();
					if (s case .Err || n case .Err || l case .Err || StringView(s) != sheetKey)
						continue;
					var lt = StringView(l);
					lt.Trim();
					if (!(int32.Parse(lt) case .Ok(let ln)))
						continue;
					if (entryLine == 0 || KindOfLine(listing, ln) == "Entry")
						if (entryLine == 0 || KindOfLine(listing, entryLine) != "Entry")
							entryLine = ln;
				}
			}
			if (entryLine == 0)
			{
				Error.AppendF("The {} build has no code for this Sheet (it was added after the build, or it is empty).", config);
				return false;
			}
			// the functions whose debug info starts on that line of this unit's listing (.ll files)
			String llFile = scope .();
			FindSymbols(buildDir, unit, entryLine);
			if (Symbols.IsEmpty)
			{
				Error.AppendF("No function of the {} build starts on this Sheet: nothing calls it (a generic type's function is built only for the type arguments used), or the build is older than the Sheet.", config);
				return false;
			}
			Demangle();
			let which = Math.Clamp(pick, 0, Symbols.Count - 1);
			Symbol.Set(Symbols[which]);
			Demangled.Set(SymbolNames[which]);
			// LLVM IR: the define in the .ll that holds it
			FindDefine(buildDir, Symbol, llFile);
			// the binary
			String exe = scope .();
			FindBinary(root, buildDir, exe);
			bool done = false;
			if (!exe.IsEmpty)
			{
				Binary.Set(exe);
				done = Disassemble(exe, false, Symbol, buildDir) && !Lines.IsEmpty;
				FromExe = done;
			}
			if (!done && !llFile.IsEmpty)
			{
				// a stripped exe (Release): the unit's .ll compiled alone with the build's flags
				String obj = scope .();
				if (CompileAlone(buildDir, llFile, obj))
				{
					Binary.Set(obj);
					done = Disassemble(obj, true, Symbol, buildDir) && !Lines.IsEmpty;
					if (done)
						Note.AppendF("The {} exe carries no symbols (it is stripped), so this is {} compiled again on its own with the build's flags: the same code, except that the exe may have inlined calls between types at the link.", config, Path.GetFileName(llFile, .. scope String()));
				}
			}
			if (!done && Error.IsEmpty)
				Error.AppendF("llvm-objdump found no code for {} in {}.", Symbol, exe.IsEmpty ? "the build" : exe);
			SheetIRText(root, config);
			return done;
		}

		static void ReadLines(StringView path, List<String> outLines)
		{
			String text = scope .();
			if (File.ReadAllText(path, text) case .Err)
				return;
			for (let l in text.Split('\n'))
			{
				var t = l;
				t.TrimEnd();
				outLines.Add(new String(t));
			}
		}

		/// The kind word of a listing line (`Zoo.Program.Main a1 Entry` -> `Entry`).
		static StringView KindOfLine(List<String> listing, int32 line)
		{
			if (line < 1 || line > listing.Count)
				return "";
			var parts = listing[line - 1].Split(' ');
			parts.GetNext();
			parts.GetNext();
			if (parts.GetNext() case .Ok(let k))
				return k;
			return "";
		}

		/// The DISubprograms of `<unit>.lst` starting on `line`, in every .ll of the build.
		void FindSymbols(StringView buildDir, StringView unit, int32 line)
		{
			String lst = scope $"{unit}.lst";
			for (let e in Directory.EnumerateFiles(buildDir, "*.ll"))
			{
				String text = scope .();
				if (File.ReadAllText(e.GetFilePath(.. scope .()), text) case .Err)
					continue;
				HashSet<String> files = scope .();
				defer { for (let f in files) delete f; }
				for (let l in text.Split('\n'))
				{
					if (!l.StartsWith('!') || !l.Contains("!DIFile(") || !l.Contains(scope $"filename: \"{lst}\""))
						continue;
					let eq = l.IndexOf(" = ");
					if (eq > 0)
						files.Add(new String(l.Substring(0, eq)));
				}
				if (files.IsEmpty)
					continue;
				for (let l in text.Split('\n'))
				{
					if (!l.Contains("!DISubprogram(") || !l.Contains("DISPFlagDefinition"))
						continue;
					String file = scope .();
					String lineText = scope .();
					String link = scope .();
					Field(l, "file: ", file);
					Field(l, "line: ", lineText);
					Field(l, "linkageName: ", link);
					if (!files.Contains(file) || lineText != scope $"{line}" || link.IsEmpty)
						continue;
					bool have = false;
					for (let s in Symbols)
						if (s == link)
							have = true;
					if (!have)
						Symbols.Add(new String(link));
				}
			}
			Symbols.Sort(scope (a, b) => a.CompareTo(b));
		}

		/// `key value,` of a metadata line (quotes removed).
		static void Field(StringView line, StringView key, String outValue)
		{
			let at = line.IndexOf(key);
			if (at < 0)
				return;
			var rest = line.Substring(at + key.Length);
			if (rest.StartsWith('"'))
			{
				let end = rest.IndexOf('"', 1);
				if (end > 0)
					outValue.Append(rest.Substring(1, end - 1));
				return;
			}
			int end = 0;
			while (end < rest.Length && rest[end] != ',' && rest[end] != ')')
				end++;
			outValue.Append(rest.Substring(0, end));
		}

		/// SymbolNames: llvm-cxxfilt's names for Symbols.
		void Demangle()
		{
			List<String> args = scope .();
			defer { ClearAndDeleteItems!(args); }
			for (let s in Symbols)
				args.Add(new String(s));
			String outText = scope .();
			RunTool("llvm-cxxfilt", args, outText);
			var lines = outText.Split('\n');
			for (let s in Symbols)
			{
				String name = new .();
				if (lines.GetNext() case .Ok(var l))
				{
					l.Trim();
					name.Append(l);
				}
				if (name.IsEmpty)
					name.Append(s);
				SymbolNames.Add(name);
			}
		}

		/// Runs an llvm-mingw tool and waits (at most 20 s); its stdout in `outText`. False when it did not run.
		public static bool RunTool(StringView tool, List<String> args, String outText, String outError = null)
		{
			String exe = scope .();
			Treadle.Language.LlvmRoot.Tool(tool, exe);
			if (!File.Exists(exe))
			{
				outError?.AppendF("{} is missing ({}): set TREADLE_LLVM to the llvm-mingw folder.", tool, exe);
				return false;
			}
			RunningProcess p = scope .();
			if (!p.Start(exe, args, ""))
			{
				outError?.Append(p.Error);
				return false;
			}
			if (!p.Wait(20000))
			{
				p.Kill();
				outError?.AppendF("{} did not finish in 20 s.", tool);
				return false;
			}
			p.GetOutput(outText);
			return true;
		}

		/// The program the build made: `<Name>.exe` (or `.dll`) in the build folder, the newest one.
		static void FindBinary(StringView root, StringView buildDir, String outPath)
		{
			DateTime best = default;
			for (let e in Directory.EnumerateFiles(buildDir))
			{
				String p = e.GetFilePath(.. scope .());
				bool program = p.EndsWith(".exe", .OrdinalIgnoreCase) || p.EndsWith(".dll", .OrdinalIgnoreCase) || p.EndsWith(".so");
#if !BF_PLATFORM_WINDOWS
				program |= Path.GetExtension(p, .. scope String()).IsEmpty; // Linux: the program has no extension
#endif
				if (!program)
					continue;
				let t = e.GetLastWriteTimeUtc();
				if (outPath.IsEmpty || t > best)
				{
					outPath.Set(p);
					best = t;
				}
			}
		}

		/// llvm-objdump's disassembly of `symbol` with line numbers (`-l`), grouped by node.
		bool Disassemble(StringView binary, bool relocs, StringView symbol, StringView buildDir)
		{
			ClearAndDeleteItems!(Lines);
			ClearAndDeleteItems!(Groups);
			List<String> args = scope .();
			defer { ClearAndDeleteItems!(args); }
			args.Add(new .("-d"));
			args.Add(new .("-l"));
			if (relocs)
				args.Add(new .("-r"));
			args.Add(new $"--disassemble-symbols={symbol}");
			args.Add(new String(binary));
			String text = scope .();
			if (!RunTool("llvm-objdump", args, text, Error))
				return false;
			Parse(text, buildDir);
			return true;
		}

		/// Reads llvm-objdump's text: `; <dir>/<Unit>.lst:<line>` starts a node's code, instruction lines
		/// are `<addr>: <bytes>\t<instruction>`.
		public void Parse(StringView text, StringView buildDir)
		{
			Dictionary<String, List<String>> listings = scope .();
			defer { for (let kv in listings) { delete kv.key; DeleteContainerAndItems!(kv.value); } }
			Dictionary<String, Dictionary<int32, (String sheet, String node)>> maps = scope .();
			defer { for (let kv in maps) { delete kv.key; for (let v in kv.value.Values) { delete v.sheet; delete v.node; } delete kv.value; } }
			bool inside = false;
			int32 group = -1;
			for (var line in text.Split('\n'))
			{
				line.TrimEnd();
				if (line.IsEmpty)
					continue;
				if (!line.StartsWith(' ') && !line.StartsWith('\t') && line.EndsWith(">:"))
				{
					inside = true; // `0000000140001cc0 <_ZN...>:`
					continue;
				}
				if (!inside)
					continue;
				if (line.StartsWith(';'))
				{
					var loc = line.Substring(1);
					loc.Trim();
					let colon = loc.LastIndexOf(':');
					if (colon <= 0 || !loc.Substring(0, colon).EndsWith(".lst"))
						continue;
					if (!(int32.Parse(loc.Substring(colon + 1)) case .Ok(let ln)))
						continue;
					String unit = scope .();
					Path.GetFileNameWithoutExtension(loc.Substring(0, colon), unit);
					if (!maps.ContainsKeyAlt(unit))
					{
						let m = new Dictionary<int32, (String sheet, String node)>();
						String map = scope .();
						if (File.ReadAllText(scope $"{buildDir}/{unit}.nodemap", map) case .Ok)
							for (let ml in map.Split('\n'))
							{
								var parts = ml.Split(' ');
								let s = parts.GetNext();
								let n = parts.GetNext();
								let l = parts.GetNext();
								if (s case .Ok && n case .Ok && l case .Ok)
								{
									var lt = StringView(l);
									lt.Trim();
									if (int32.Parse(lt) case .Ok(let li))
										m[li] = (new String(s), new String(n));
								}
							}
						maps[new String(unit)] = m;
						let lst = new List<String>();
						ReadLines(scope $"{buildDir}/{unit}.lst", lst);
						listings[new String(unit)] = lst;
					}
					// the same line again (a block's new row): the group goes on
					if (group >= 0 && Groups[group].Line == ln && Groups[group].Unit == unit)
						continue;
					// a location with no instructions under it gives way to the next
					if (group >= 0 && Groups[group].Count == 0)
					{
						delete Groups.PopBack();
						group = (int32)Groups.Count - 1;
					}
					let m = maps[scope String(unit)];
					AsmGroup g = new .();
					g.Unit.Set(unit);
					g.Line = ln;
					if (m.TryGetValue(ln, let sn))
					{
						g.SheetKey.Set(sn.sheet);
						g.Node.Set(sn.node);
					}
					let lst = listings[scope String(unit)];
					if (ln >= 1 && ln <= lst.Count)
					{
						// `Zoo.Program.Main a2 Construct Zoo.Dog` -> `Construct Zoo.Dog`
						var t = StringView(lst[ln - 1]);
						for (int skip < 2)
						{
							let sp = t.IndexOf(' ');
							t = (sp >= 0) ? t.Substring(sp + 1) : "";
						}
						g.Title.Set(t);
					}
					if (unit != Unit)
						g.Title.AppendF("   (inlined from {})", unit);
					g.First = (int32)Lines.Count;
					Groups.Add(g);
					group = (int32)Groups.Count - 1;
					continue;
				}
				var t = line;
				t.TrimStart();
				if (t.StartsWith("0000") && t.Contains("IMAGE_REL") || t.Contains("R_X86_64"))
				{
					// a relocation (-r): `0000000000000004:  IMAGE_REL_AMD64_REL32	_ZN...`
					if (!Lines.IsEmpty)
					{
						var rel = t;
						let c = rel.IndexOf(':');
						if (c > 0)
							rel = rel.Substring(c + 1);
						rel.Trim();
						String relText = scope .(rel);
						relText.Replace('\t', ' ');
						Lines.Back.Text.AppendF("    ; {}", relText);
					}
					continue;
				}
				let colon = t.IndexOf(':');
				if (colon <= 0)
					continue;
				uint64 addr = 0;
				bool hex = true;
				for (let c in t.Substring(0, colon).RawChars)
				{
					int d = (c >= '0' && c <= '9') ? c - '0' : ((c >= 'a' && c <= 'f') ? c - 'a' + 10 : -1);
					if (d < 0)
					{
						hex = false;
						break;
					}
					addr = addr * 16 + (uint64)d;
				}
				if (!hex)
					continue;
				var rest = t.Substring(colon + 1);
				let tab = rest.IndexOf('\t');
				AsmLine a = new .();
				a.Address = addr;
				if (tab >= 0)
				{
					var b = rest.Substring(0, tab);
					b.Trim();
					a.Bytes.Set(b);
					var ins = rest.Substring(tab + 1);
					ins.Trim();
					a.Text.Set(ins);
					let t2 = a.Text.IndexOf('\t');
					if (t2 > 0)
					{
						a.Text.Remove(t2, 1);
						a.Text.Insert(t2, scope String(' ', Math.Max(1, 8 - t2)));
					}
				}
				else
				{
					rest.Trim();
					a.Text.Set(rest);
				}
				if (group < 0)
				{
					AsmGroup g = new .();
					g.Title.Set("(set-up before the first node)");
					Groups.Add(g);
					group = 0;
				}
				a.Group = group;
				Groups[group].Count++;
				Lines.Add(a);
			}
		}

		/// The `.ll` defining `symbol`, and its text into LLVMIR.
		void FindDefine(StringView buildDir, StringView symbol, String outFile)
		{
			String key = scope $"@{symbol}(";
			for (let e in Directory.EnumerateFiles(buildDir, "*.ll"))
			{
				String path = e.GetFilePath(.. scope .());
				String text = scope .();
				if (File.ReadAllText(path, text) case .Err)
					continue;
				bool inFn = false;
				for (let l in text.Split('\n'))
				{
					if (!inFn && l.StartsWith("define ") && l.Contains(key))
						inFn = true;
					if (inFn)
					{
						LLVMIR.AppendF("{}\n", l);
						if (l.StartsWith('}'))
						{
							outFile.Set(path);
							return;
						}
					}
				}
			}
		}

		/// Compiles a unit's `.ll` alone (no ThinLTO) with the build's clang flags into `<build>/disasm/`.
		bool CompileAlone(StringView buildDir, StringView llFile, String outObj)
		{
			String flagsText = scope .();
			File.ReadAllText(scope $"{buildDir}/obj/flags.txt", flagsText).IgnoreError();
			var fl = flagsText.Split('\n');
			fl.GetNext();
			String flags = scope .();
			if (fl.GetNext() case .Ok(let f))
				flags.Set(f);
			List<String> args = scope .();
			defer { ClearAndDeleteItems!(args); }
			for (let a in flags.Split(' ', .RemoveEmptyEntries))
			{
				var t = a;
				t.Trim();
				if (t.IsEmpty || t.StartsWith("-flto"))
					continue;
				args.Add(new String(t));
			}
			if (args.IsEmpty)
			{
				args.Add(new .("-c"));
				args.Add(new .("-O2"));
			}
			String dir = scope $"{buildDir}/disasm";
			Directory.CreateDirectory(dir).IgnoreError();
			outObj.AppendF("{}/{}.o", dir, Path.GetFileNameWithoutExtension(llFile, .. scope String()));
			args.Add(new String(llFile));
			args.Add(new .("-o"));
			args.Add(new String(outObj));
			String o = scope .();
			if (!RunTool("clang", args, o, Error))
				return false;
			return File.Exists(outObj);
		}

		/// The Sheet's `func` records of the program Build lowers (the saved files), every instance.
		void SheetIRText(StringView root, StringView config)
		{
			String tir = scope .();
			List<Diagnostic> msgs = scope .();
			defer { ClearAndDeleteItems!(msgs); }
			if (!Treadle.Compiler.FrontEndBuild.WriteProgram(root, config, tir, msgs) && tir.IsEmpty)
			{
				SheetIR.Append("# The project does not lower now (Problems lists why); the Sheet IR is made from the saved files.\n");
				return;
			}
			bool inFn = false;
			String sheetMark = scope $"sheet \"{SheetKey}\"";
			for (let l in tir.Split('\n'))
			{
				if (l.StartsWith("func "))
				{
					var fref = l.Substring(5);
					inFn = l.Contains(sheetMark) && (fref.StartsWith(scope $"{Unit}.") || fref.StartsWith(scope $"{Unit}<"));
					if (inFn && !SheetIR.IsEmpty)
						SheetIR.Append('\n');
				}
				else if (!l.IsEmpty && !l.StartsWith('\t') && !l.StartsWith(' '))
					inFn = false;
				if (inFn)
					SheetIR.AppendF("{}\n", l);
			}
			if (SheetIR.IsEmpty)
				SheetIR.Append("# No function record for this Sheet in the lowered program (nothing calls it, or it has errors).\n");
		}

		/// The disassembly as text (Copy): node headings, then the instructions.
		public void Text(String o, bool addresses, bool bytes)
		{
			for (let g in Groups)
			{
				o.AppendF("; {}{}{}\n", g.Node, g.Node.IsEmpty ? "" : "  ", g.Title);
				for (int i = g.First; i < g.First + g.Count && i < Lines.Count; i++)
				{
					let a = Lines[i];
					o.Append("    ");
					if (addresses)
						o.AppendF("{:X}:  ", a.Address);
					if (bytes)
						o.AppendF("{,-24}", a.Bytes);
					o.AppendF("{}\n", a.Text);
				}
			}
		}
	}
}
