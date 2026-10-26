using System;
using System.Collections;

namespace Treadle.Backend.IR
{
	/// Reads the Sheet IR text dump (`.tir`, format in docs/Compiler.md section 4):
	/// line records, `#` comments, indentation for reading only. Fills an IRProgram and links it.
	class IRReader
	{
		IRProgram mProgram;
		List<String> mErrors;
		int32 mLine;
		IRUnit mUnit;
		IRTypeDecl mDecl;
		IRFunction mFn;
		IRBlock mBlock;
		List<String> mParamNames = new .() ~ DeleteContainerAndItems!(_);
		/// The type spelling of each param line when it differs from the canonical text (else null).
		List<String> mParamSpellings = new .() ~ DeleteContainerAndItems!(_);

		public this(IRProgram program, List<String> errors)
		{
			mProgram = program;
			mErrors = errors;
		}

		/// Reads `text` into `program` and links it. False with "line N: ..." errors.
		public static bool Read(StringView text, IRProgram program, List<String> outErrors)
		{
			IRReader r = scope .(program, outErrors);
			r.ReadAll(text);
			if (!outErrors.IsEmpty)
				return false;
			return program.Link(outErrors);
		}

		void Error(StringView msg)
		{
			mErrors.Add(new String()..AppendF("line {}: {}", mLine, msg));
		}

		/// Splits a line into tokens: whitespace separates, except inside quotes and brackets.
		/// Quoted tokens keep their quotes. A `#` outside a token starts a comment.
		public static void Tokenize(StringView line, List<StringView> outTokens)
		{
			int i = 0;
			let n = line.Length;
			while (i < n)
			{
				let c = line[i];
				if (c == ' ' || c == '\t' || c == '\r')
				{
					i++;
					continue;
				}
				if (c == '#')
					break;
				int start = i;
				if (c == '"')
				{
					i++;
					while (i < n && line[i] != '"')
					{
						if (line[i] == '\\')
							i++;
						i++;
					}
					i = Math.Min(i + 1, n);
					outTokens.Add(line.Substring(start, i - start));
					continue;
				}
				int depth = 0;
				while (i < n)
				{
					let d = line[i];
					if (d == '<' || d == '(' || d == '[')
						depth++;
					else if (d == '>' || d == ')' || d == ']')
						depth--;
					else if ((d == ' ' || d == '\t' || d == '\r') && depth <= 0)
						break;
					i++;
				}
				let tok = line.Substring(start, i - start);
				// "ref T", "function R(A)" and "delegate R(A)" are one type token
				if ((tok == "ref" || tok == "function" || tok == "delegate") && i < n)
				{
					while (i < n && (line[i] == ' ' || line[i] == '\t'))
						i++;
					int depth2 = 0;
					while (i < n)
					{
						let d = line[i];
						if (d == '<' || d == '(' || d == '[')
							depth2++;
						else if (d == '>' || d == ')' || d == ']')
							depth2--;
						else if ((d == ' ' || d == '\t' || d == '\r') && depth2 <= 0)
						{
							// "function R (A)": the parameter list may follow after a space
							break;
						}
						i++;
					}
					outTokens.Add(line.Substring(start, i - start));
					continue;
				}
				outTokens.Add(tok);
			}
		}

		static int HexDigit(char8 c)
		{
			if (c >= '0' && c <= '9')
				return c - '0';
			if (c >= 'a' && c <= 'f')
				return c - 'a' + 10;
			if (c >= 'A' && c <= 'F')
				return c - 'A' + 10;
			return -1;
		}

		/// The text of a quoted token, unescaped (`\" \\ \n \t \r \0 \xHH`).
		public static void Unquote(StringView token, String outText)
		{
			var t = token;
			if (t.StartsWith('"'))
				t.RemoveFromStart(1);
			if (t.EndsWith('"'))
				t.RemoveFromEnd(1);
			for (int i = 0; i < t.Length; i++)
			{
				let c = t[i];
				if (c != '\\' || i + 1 >= t.Length)
				{
					outText.Append(c);
					continue;
				}
				i++;
				switch (t[i])
				{
				case 'n': outText.Append('\n');
				case 't': outText.Append('\t');
				case 'r': outText.Append('\r');
				case '0': outText.Append('\0');
				case 'x':
					// two hexadecimal digits, either case (the writers' `\x{:X2}`); uint8.Parse with
					// AllowHexSpecifier wanted a 0x prefix, so 0B, 0C, 1B... were dropped
					if (i + 2 < t.Length && HexDigit(t[i + 1]) >= 0 && HexDigit(t[i + 2]) >= 0)
					{
						outText.Append((char8)(uint8)(HexDigit(t[i + 1]) * 16 + HexDigit(t[i + 2])));
						i += 2;
					}
					else
						outText.Append('x');
				default: outText.Append(t[i]);
				}
			}
		}

		IRType ParseType(StringView text)
		{
			String err = scope .();
			if (mProgram.Type(text, err) case .Ok(let t))
				return t;
			Error(err);
			return null;
		}

		void ReadAll(StringView text)
		{
			List<StringView> tokens = scope .();
			for (let rawLine in text.Split('\n'))
			{
				mLine++;
				tokens.Clear();
				Tokenize(rawLine, tokens);
				if (tokens.IsEmpty)
					continue;
				let head = tokens[0];
				switch (head)
				{
				case "program":
					EndFunction();
					mDecl = null;
					if (tokens.Count >= 2)
						mProgram.Name.Set(tokens[1]);
					for (int i = 2; i < tokens.Count; i++)
					{
						if (tokens[i] == "windowed")
							mProgram.Kind = .Windowed;
						else if (tokens[i] == "console")
							mProgram.Kind = .Console;
						else if (tokens[i] == "library")
							mProgram.Kind = .Library;
						else
							Error(scope $"unknown program setting '{tokens[i]}'");
					}
				case "entry":
					EndFunction();
					mDecl = null;
					if (tokens.Count != 2)
						Error("entry needs one function reference");
					else
						String.NewOrSet!(mProgram.EntryKey, tokens[1]);
				case "unit":
					EndFunction();
					mDecl = null;
					if (tokens.Count < 2)
					{
						Error("unit needs a name");
						break;
					}
					mUnit = mProgram.FindUnit(tokens[1]);
					if (mUnit == null)
						mUnit = mProgram.AddUnit(tokens[1]);
					if (tokens.Count >= 3)
					{
						mUnit.SourcePath.Clear();
						Unquote(tokens[2], mUnit.SourcePath);
					}
				case "type":
					EndFunction();
					ReadType(tokens);
				case "global":
					EndFunction();
					mDecl = null;
					ReadGlobal(tokens);
				case "func":
					EndFunction();
					mDecl = null;
					ReadFuncHeader(tokens);
				default:
					if (mFn != null)
						ReadFunctionLine(tokens);
					else if (mDecl != null)
						ReadTypeProperty(tokens);
					else
						Error(scope $"unknown record '{head}'");
				}
			}
			EndFunction();
			if (mProgram.EntryKey == null && !mProgram.Functions.IsEmpty && mProgram.Kind != .Library)
				Error("no entry function (an 'entry' line)");
		}

		// ---------------------------------------------------------------- types

		void ReadType(List<StringView> tokens)
		{
			mDecl = null;
			if (tokens.Count < 3)
			{
				Error("type needs a name and a kind (class, struct, enum, interface)");
				return;
			}
			IRDeclKind kind;
			switch (tokens[2])
			{
			case "class": kind = .Class;
			case "struct": kind = .Struct;
			case "enum": kind = .Enum;
			case "interface": kind = .Interface;
			default:
				Error(scope $"unknown type kind '{tokens[2]}'");
				return;
			}
			let t = ParseType(tokens[1]);
			if (t == null)
				return;
			if (t.Kind != .Named)
			{
				Error(scope $"'{tokens[1]}' is not a type name");
				return;
			}
			if (mProgram.FindDecl(t.Text) != null)
			{
				Error(scope $"type '{t.Text}' is declared twice");
				return;
			}
			mDecl = mProgram.AddDecl(kind, t.Text, mUnit);
			mDecl.Line = mLine;
			for (int i = 3; i < tokens.Count; i++)
			{
				switch (tokens[i])
				{
				case "abstract": mDecl.Abstract = true;
				case "packed": mDecl.Packed = true;
				default: Error(scope $"unknown type flag '{tokens[i]}'");
				}
			}
		}

		void ReadTypeProperty(List<StringView> tokens)
		{
			let d = mDecl;
			switch (tokens[0])
			{
			case "base":
				if (tokens.Count != 2)
					Error("base needs one type");
				else
					String.NewOrSet!(d.BaseName, tokens[1]);
			case "field":
				if (tokens.Count < 3)
				{
					Error("field needs a name and a type");
					return;
				}
				IRField f = new .();
				f.Name.Set(tokens[1]);
				f.Type = ParseType(tokens[2]);
				for (int i = 3; i < tokens.Count; i++)
				{
					if (tokens[i] == "owned")
						f.Owned = true;
					else
						Error(scope $"unknown field flag '{tokens[i]}'");
				}
				d.Fields.Add(f);
			case "vslot":
				if (tokens.Count != 3)
				{
					Error("vslot needs the declaring function and the implementation (or 'abstract')");
					return;
				}
				IRVSlot s = new .();
				s.DeclKey = new .(tokens[1]);
				if (tokens[2] != "abstract")
					s.ImplKey = new .(tokens[2]);
				d.VTable.Add(s);
			case "itable":
				if (tokens.Count < 2)
				{
					Error("itable needs an interface");
					return;
				}
				IRITable it = new .();
				it.IfaceName = new .(tokens[1]);
				for (int i = 2; i < tokens.Count; i++)
					it.ImplKeys.Add(new .(tokens[i]));
				d.ITables.Add(it);
			case "islot":
				if (tokens.Count != 2)
					Error("islot needs one function");
				else
					d.ISlotKeys.Add(new .(tokens[1]));
			case "case":
				if (tokens.Count < 2)
				{
					Error("case needs a name");
					return;
				}
				IREnumCase c = new .();
				c.Name.Set(tokens[1]);
				c.Value = d.Cases.IsEmpty ? 0 : d.Cases.Back.Value + 1;
				int i = 2;
				if (i + 1 < tokens.Count && tokens[i] == "=")
				{
					if (int64.Parse(tokens[i + 1]) case .Ok(let v))
						c.Value = v;
					else
						Error(scope $"case value '{tokens[i + 1]}' is not an integer");
					i += 2;
				}
				for (; i < tokens.Count; i++)
				{
					let pt = ParseType(tokens[i]);
					if (pt != null)
						c.Payload.Add(pt);
				}
				d.Cases.Add(c);
			case "tag":
				if (tokens.Count != 2)
					Error("tag needs an integer type");
				else
					d.TagType = ParseType(tokens[1]);
			case "dtor":
				if (tokens.Count != 2)
					Error("dtor needs one function");
				else
					String.NewOrSet!(d.DtorKey, tokens[1]);
			default:
				Error(scope $"unknown type property '{tokens[0]}'");
			}
		}

		// ---------------------------------------------------------------- globals

		void ReadGlobal(List<StringView> tokens)
		{
			if (tokens.Count < 3)
			{
				Error("global needs a name and a type");
				return;
			}
			let t = ParseType(tokens[2]);
			if (t == null)
				return;
			let g = mProgram.AddGlobal(tokens[1], t, mUnit);
			g.Line = mLine;
			if (g.Name == null)
				Error(scope $"'{tokens[1]}' is not a name");
			if (tokens.Count >= 5 && tokens[3] == "import")
			{
				// an extern C variable: `global C.small.counter int32 import "counter"`
				g.Import = new String();
				if (tokens[4].StartsWith('"'))
					Unquote(tokens[4], g.Import);
				else
					g.Import.Set(tokens[4]);
			}
			else if (tokens.Count >= 4 && tokens[3] == "const")
			{
				// read-only: `global A.Pi double const 3.14`, `global A.Widths int[3] const 1 2 3`
				g.Const = true;
				if (t.Kind == .FixedArray)
				{
					g.Elements = new .();
					for (int i = 4; i < tokens.Count; i++)
						g.Elements.Add(new String(tokens[i]));
					if (g.Elements.Count != t.Count)
						Error(scope $"global '{tokens[1]}' has {g.Elements.Count} elements for {t.Count}");
				}
				else if (tokens.Count >= 5)
				{
					if (tokens[4].StartsWith('"'))
						Unquote(tokens[4], g.Init);
					else
						g.Init.Set(tokens[4]);
				}
			}
			else if (tokens.Count >= 4)
			{
				if (tokens[3].StartsWith('"'))
					Unquote(tokens[3], g.Init);
				else
					g.Init.Set(tokens[3]);
			}
		}

		// ---------------------------------------------------------------- functions

		void ReadFuncHeader(List<StringView> tokens)
		{
			if (tokens.Count < 3)
			{
				Error("func needs a reference and a return type");
				return;
			}
			IRFunction f = new .();
			String err = scope .();
			if (!FuncKey.Parse(mProgram, tokens[1], f, err))
			{
				Error(err);
				delete f;
				return;
			}
			f.Ret = ParseType(tokens[2]);
			f.Unit = mUnit;
			f.Line = mLine;
			for (int i = 3; i < tokens.Count; i++)
			{
				let tok = tokens[i];
				switch (tok)
				{
				case "static": f.Static = true;
				case "virtual": f.Virtual = true;
				case "abstract": f.Abstract = true;
				case "sctor": f.StaticCtor = true; f.Static = true;
				case "import", "export", "cconv", "sheet", "display", "kernel":
					if (i + 1 >= tokens.Count)
					{
						Error(scope $"'{tok}' needs a value");
						break;
					}
					let v = tokens[++i];
					String text = scope .();
					if (v.StartsWith('"'))
						Unquote(v, text);
					else
						text.Set(v);
					switch (tok)
					{
					case "import": f.ImportName = new .(text); f.Static = true;
					case "export": f.ExportName = new .(text);
					case "kernel": String.NewOrSet!(f.KernelName, text); // EmitKernel.bf (GPU-Compute.md)
					case "sheet": f.SheetKey.Set(text);
					case "display": f.Display.Set(text);
					case "cconv":
						switch (text)
						{
						case "cdecl": f.Conv = .CDecl;
						case "stdcall": f.Conv = .StdCall;
						case "fastcall": f.Conv = .FastCall;
						default: Error(scope $"unknown calling convention '{text}'");
						}
					}
				default:
					Error(scope $"unknown function flag '{tok}'");
				}
			}
			if (!mProgram.Register(f))
			{
				Error(scope $"function '{f.Key}' is declared twice");
				delete f;
				return;
			}
			mFn = f;
			mBlock = null;
			ClearAndDeleteItems!(mParamSpellings);
			ClearAndDeleteItems!(mParamNames);
		}

		/// Ends the function being read: makes its parameter values.
		void EndFunction()
		{
			if (mFn == null)
				return;
			let f = mFn;
			mFn = null;
			mBlock = null;
			// `this` first for instance functions; the decl is known only after linking, so the
			// linker adds `this` when the owner turns out to be a class or struct. Here: the names.
			for (int i < f.ParamTypes.Count)
			{
				String name = scope .();
				if (i < mParamNames.Count)
					name.Set(mParamNames[i]);
				else
					name.AppendF("p{}", i);
				let pv = f.AddParam(name, f.ParamTypes[i]);
				if (i < mParamSpellings.Count && mParamSpellings[i] != null)
					pv.TypeText = new .(mParamSpellings[i]);
			}
			if (mParamNames.Count > f.ParamTypes.Count)
				mErrors.Add(new String()..AppendF("line {}: {} has {} param lines for {} parameters", f.Line, f.Key, mParamNames.Count, f.ParamTypes.Count));
			ClearAndDeleteItems!(mParamNames);
			ClearAndDeleteItems!(mParamSpellings);
		}

		void ReadFunctionLine(List<StringView> tokens)
		{
			let f = mFn;
			switch (tokens[0])
			{
			case "param":
				if (tokens.Count < 2)
				{
					Error("param needs a name");
					return;
				}
				let idx = mParamNames.Count;
				mParamNames.Add(new .(tokens[1]));
				mParamSpellings.Add(null);
				if (tokens.Count >= 3 && idx < f.ParamTypes.Count)
				{
					let t = ParseType(tokens[2]);
					if (t != null && t != f.ParamTypes[idx])
						Error(scope $"param {tokens[1]} is {t.Text} but the signature says {f.ParamTypes[idx].Text}");
					else if (t != null && tokens[2] != t.Text)
						mParamSpellings[idx] = new .(tokens[2]);
				}
				return;
			case "slot":
				if (tokens.Count < 4)
				{
					Error("slot needs an id, a type and a kind (local, variable, outtemp, loopvar)");
					return;
				}
				if (f.FindSlot(tokens[1]) != null)
				{
					Error(scope $"slot '{tokens[1]}' is declared twice");
					return;
				}
				IRSlotKind kind;
				switch (tokens[3])
				{
				case "local": kind = .Local;
				case "variable": kind = .Variable;
				case "outtemp": kind = .OutTemp;
				case "loopvar": kind = .LoopVar;
				default:
					Error(scope $"unknown slot kind '{tokens[3]}'");
					return;
				}
				let s = f.AddSlot(tokens[1], ParseType(tokens[2]), kind);
				if (s.Type != null && tokens[2] != s.Type.Text)
					s.TypeText = new .(tokens[2]);
				// the user-facing name: `"<name>" local|pin` after the kind (optional, the old form has none)
				int first = 4;
				if (tokens.Count > 4 && tokens[4].StartsWith('"'))
				{
					Unquote(tokens[4], s.Name);
					if (tokens.Count < 6 || (tokens[5] != "local" && tokens[5] != "pin"))
					{
						Error(scope $"slot '{tokens[1]}': the name needs 'local' or 'pin' after it");
						return;
					}
					s.Shows = (tokens[5] == "pin") ? .Pin : .Local;
					if (s.Name.IsEmpty)
						s.Shows = .None;
					first = 6;
				}
				for (int i = first; i + 1 < tokens.Count; i += 2)
				{
					if (tokens[i] == "region")
						String.NewOrSet!(s.RegionId, tokens[i + 1]);
					else if (tokens[i] == "node")
						SplitNode(tokens[i + 1], s.NodeId, s.Pin);
					else
						Error(scope $"unknown slot setting '{tokens[i]}'");
				}
				if ((tokens.Count - first) % 2 != 0)
					Error("slot settings come in pairs (region <id>, node <id>[.<pin>])");
				return;
			case "region":
				if (tokens.Count < 2)
				{
					Error("region needs an id");
					return;
				}
				if (f.FindRegion(tokens[1]) != null)
				{
					Error(scope $"region '{tokens[1]}' is declared twice");
					return;
				}
				var parent = f.BodyRegion;
				if (tokens.Count >= 4 && tokens[2] == "parent")
				{
					parent = f.FindRegion(tokens[3]);
					if (parent == null)
						Error(scope $"parent region '{tokens[3]}' is not declared (declare regions outer first)");
				}
				f.AddRegion(tokens[1], parent ?? f.BodyRegion);
				return;
			case "node":
				if (tokens.Count < 3)
				{
					Error("node needs an id and a kind");
					return;
				}
				String subject = scope .();
				for (int i = 3; i < tokens.Count; i++)
				{
					if (i > 3)
						subject.Append(' ');
					subject.Append(tokens[i]);
				}
				f.AddNode(tokens[1], tokens[2], subject);
				return;
			case "block":
				if (tokens.Count != 2)
				{
					Error("block needs an id");
					return;
				}
				if (f.FindBlock(tokens[1]) != null)
				{
					Error(scope $"block '{tokens[1]}' is declared twice");
					return;
				}
				mBlock = f.AddBlock(tokens[1]);
				return;
			}
			if (mBlock == null)
			{
				Error(scope $"'{tokens[0]}' outside a block");
				return;
			}
			ReadOp(tokens);
		}

		static void SplitNode(StringView text, String outNode, String outPin)
		{
			var t = text;
			if (t.StartsWith('@'))
				t.RemoveFromStart(1);
			let dot = t.IndexOf('.');
			if (dot < 0)
				outNode.Set(t);
			else
			{
				outNode.Set(t.Substring(0, dot));
				outPin.Set(t.Substring(dot + 1));
			}
		}

		void ReadOp(List<StringView> tokensIn)
		{
			List<StringView> tokens = scope .();
			tokens.AddRange(tokensIn);
			IROp op = new .();
			op.Line = mLine;
			mBlock.Ops.Add(op);
			if (tokens.Back.StartsWith('@'))
			{
				SplitNode(tokens.Back, op.NodeId, op.Pin);
				tokens.PopBack();
			}
			int i = 0;
			StringView resultName = default;
			if (tokens.Count >= 3 && tokens[0].StartsWith('%') && tokens[1] == "=")
			{
				resultName = tokens[0].Substring(1);
				i = 2;
			}
			if (i >= tokens.Count)
			{
				Error("an op needs a mnemonic");
				return;
			}
			let mnemonic = tokens[i++];
			if (IRVector.IsMnemonic(mnemonic))
			{
				ReadVectorOp(op, tokens, i, mnemonic, resultName); // IRVector.bf
				return;
			}
			if (IRWriter.KindOf(mnemonic) case .Ok(let kind))
				op.Kind = kind;
			else
			{
				Error(scope $"unknown op '{mnemonic}'");
				return;
			}
			if (IRWriter.HasType(op.Kind))
			{
				if (i >= tokens.Count)
				{
					Error(scope $"'{mnemonic}' needs a type");
					return;
				}
				op.Type = ParseType(tokens[i++]);
				if (op.Type == null)
					return;
			}
			if (!resultName.IsEmpty)
			{
				if (op.Type == null || op.Type.IsVoid)
				{
					Error(scope $"'{mnemonic}' has no result to name %{resultName}");
					return;
				}
				op.Result = new .();
				op.Result.Name.Set(resultName);
				op.Result.Type = op.Type;
				op.Result.Def = op;
			}
			else if (op.Type != null && !op.Type.IsVoid && !IRWriter.MayDiscard(op.Kind))
			{
				Error(scope $"'{mnemonic}' makes a value: name it (%x = {mnemonic} ...)");
				return;
			}
			int rest = i;
			// helpers
			bool Need(int count)
			{
				if (tokens.Count - rest >= count)
					return true;
				Error(scope $"'{mnemonic}' needs {count} more operand{(count == 1) ? "" : "s"}");
				return false;
			}
			void Value(StringView tok)
			{
				if (!tok.StartsWith('%'))
				{
					Error(scope $"expected a value (%name), found '{tok}'");
					return;
				}
				if (op.ArgNames == null)
					op.ArgNames = new .();
				op.ArgNames.Add(new .(tok.Substring(1)));
			}
			void Values(int from)
			{
				for (int k = from; k < tokens.Count; k++)
					Value(tokens[k]);
			}
			void Target(StringView tok)
			{
				if (op.TargetIds == null)
					op.TargetIds = new .();
				op.TargetIds.Add(new .(tok));
			}
			switch (op.Kind)
			{
			case .Const:
				if (!Need(1))
					return;
				if (tokens[rest].StartsWith('"'))
				{
					Unquote(tokens[rest], op.Lit);
					op.LitIsString = true;
				}
				else
					op.Lit.Set(tokens[rest]);
			case .Copy, .Cast, .Load, .NullCheck, .ArrayLen, .Free, .Dtor, .Delete, .Box, .Unbox, .DynCast, .EnumTag:
				if (!Need(1))
					return;
				Values(rest);
			case .LoadSlot, .SlotAddr:
				if (!Need(1))
					return;
				op.SlotId = new .(tokens[rest]);
			case .StoreSlot:
				if (!Need(2))
					return;
				op.SlotId = new .(tokens[rest]);
				Values(rest + 1);
			case .Local:
				if (!Need(1))
					return;
				op.SlotId = new .(tokens[rest]);
			case .Binop, .Cmp, .Intrinsic:
				if (!Need(1))
					return;
				op.Sub.Set(tokens[rest]);
				Values(rest + 1);
			case .Select, .ElemAddr, .Store, .BoundsCheck, .Make, .FptrCall, .AllocArray, .Alloc, .ArraySpan:
				Values(rest);
			case .FieldAddr:
				if (!Need(2))
					return;
				Value(tokens[rest]);
				op.Sub.Set(tokens[rest + 1]);
			case .GlobalAddr:
				if (!Need(1))
					return;
				op.GlobalName = new .(tokens[rest]);
			case .Call, .VCall, .ICall, .CCall, .FnAddr:
				if (!Need(1))
					return;
				op.FnKey = new .(tokens[rest]);
				Values(rest + 1);
			case .RegionEnter, .RegionExit:
				if (!Need(1))
					return;
				op.RegionId = new .(tokens[rest]);
			case .Defer:
				if (!Need(2))
					return;
				op.RegionId = new .(tokens[rest]);
				Target(tokens[rest + 1]);
			case .TypeInfo, .SizeOf, .AlignOf:
				if (!Need(1))
					return;
				op.TypeArg = ParseType(tokens[rest]);
			case .Extract:
				if (!Need(2))
					return;
				Value(tokens[rest]);
				if (int64.Parse(tokens[rest + 1]) case .Ok(let v))
					op.Index = v;
				else
					Error(scope $"extract index '{tokens[rest + 1]}' is not an integer");
			case .CaseMake:
				if (!Need(1))
					return;
				op.Sub.Set(tokens[rest]);
				Values(rest + 1);
			case .EnumPayload:
				if (!Need(3))
					return;
				Value(tokens[rest]);
				op.Sub.Set(tokens[rest + 1]);
				if (int64.Parse(tokens[rest + 2]) case .Ok(let v))
					op.Index = v;
				else
					Error(scope $"payload index '{tokens[rest + 2]}' is not an integer");
			case .Br:
				if (!Need(1))
					return;
				Target(tokens[rest]);
			case .CondBr:
				if (!Need(3))
					return;
				Value(tokens[rest]);
				Target(tokens[rest + 1]);
				Target(tokens[rest + 2]);
			case .Switch:
				if (!Need(2))
					return;
				Value(tokens[rest]);
				Target(tokens[rest + 1]);
				if ((tokens.Count - rest - 2) % 2 != 0)
				{
					Error("switch cases come in pairs: <value> <block>");
					return;
				}
				for (int k = rest + 2; k + 1 < tokens.Count; k += 2)
				{
					IRSwitchCase c = new .();
					if (int64.Parse(tokens[k]) case .Ok(let v))
						c.Value = v;
					else
						Error(scope $"switch value '{tokens[k]}' is not an integer");
					c.TargetId = new .(tokens[k + 1]);
					op.Cases.Add(c);
				}
			case .Ret, .Invoke:
				Values(rest);
			case .LocalArray:
				if (!Need(2))
					return;
				op.SlotId = new .(tokens[rest]);
				Values(rest + 1);
			case .AtomicLoad, .AtomicStore, .AtomicCas, .Fence:
				if (!Need(1))
					return;
				op.Order.Set(tokens[rest]);
				Values(rest + 1);
			case .AtomicRmw:
				if (!Need(2))
					return;
				op.Sub.Set(tokens[rest]);
				op.Order.Set(tokens[rest + 1]);
				Values(rest + 2);
			case .Bind:
				if (!Need(1))
					return;
				op.FnKey = new .(tokens[rest]);
				Values(rest + 1);
			case .BindLocal:
				if (!Need(2))
					return;
				op.SlotId = new .(tokens[rest]);
				op.FnKey = new .(tokens[rest + 1]);
				Values(rest + 2);
			case .Closure:
				if (!Need(2))
					return;
				Value(tokens[rest]);
				op.FnKey = new .(tokens[rest + 1]);
			case .EndDefer, .Unreachable, .Vec, .LaneCheck:
			case .Fatal:
				if (!Need(2))
					return;
				if (int64.Parse(tokens[rest]) case .Ok(let v))
					op.Index = v;
				Unquote(tokens[rest + 1], op.Lit);
			}
			if (op.TypeArg == null && (op.Kind == .Alloc || op.Kind == .DynCast))
				op.TypeArg = op.Type;
		}
	}
}
