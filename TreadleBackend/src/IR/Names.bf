using System;
using System.Collections;

namespace Treadle.Backend.IR
{
	/// Parses type text (`Core.Pair<int,int>`, `int32*`, `ref Game.Pair`, `(int,float)`, `int[]`,
	/// `int[4]`, `int?`, `function int32(int32,char8*)`) into interned IRTypes, and qualified names.
	class TypeParser
	{
		IRProgram mProgram;
		StringView mText;
		int mPos;
		public String Error = new .() ~ delete _;

		public this(IRProgram program, StringView text)
		{
			mProgram = program;
			mText = text;
		}

		public bool AtEnd
		{
			get
			{
				SkipWs();
				return mPos >= mText.Length;
			}
		}

		public StringView Rest => mText.Substring(Math.Min(mPos, mText.Length));
		public int Pos { get => mPos; set => mPos = value; }

		void SkipWs()
		{
			while (mPos < mText.Length && (mText[mPos] == ' ' || mText[mPos] == '\t'))
				mPos++;
		}

		bool Peek(char8 c)
		{
			SkipWs();
			return mPos < mText.Length && mText[mPos] == c;
		}

		bool Eat(char8 c)
		{
			if (!Peek(c))
				return false;
			mPos++;
			return true;
		}

		public static bool IsIdentChar(char8 c) => c.IsLetterOrDigit || c == '_' || c == '~' || c == '$';

		StringView Ident()
		{
			SkipWs();
			int start = mPos;
			while (mPos < mText.Length && IsIdentChar(mText[mPos]))
				mPos++;
			return mText.Substring(start, mPos - start);
		}

		void SetError(StringView why)
		{
			if (Error.IsEmpty)
				Error.AppendF("{} at column {} of '{}'", why, mPos + 1, mText);
		}

		Result<IRType> Fail(StringView why)
		{
			SetError(why);
			return .Err;
		}

		static void Primitive(StringView name, IRType t, out bool known)
		{
			known = true;
			switch (name)
			{
			case "void": t.Kind = .Void;
			case "bool": t.Kind = .Bool;
			case "int", "int64", "isize": t.Kind = .Int; t.Bits = 64; t.Signed = true;
			case "int32": t.Kind = .Int; t.Bits = 32; t.Signed = true;
			case "int16": t.Kind = .Int; t.Bits = 16; t.Signed = true;
			case "int8": t.Kind = .Int; t.Bits = 8; t.Signed = true;
			case "uint", "uint64", "usize": t.Kind = .Int; t.Bits = 64;
			case "uint32": t.Kind = .Int; t.Bits = 32;
			case "uint16": t.Kind = .Int; t.Bits = 16;
			case "uint8": t.Kind = .Int; t.Bits = 8;
			case "float": t.Kind = .Float; t.Bits = 32;
			case "double": t.Kind = .Float; t.Bits = 64;
			case "char8": t.Kind = .Char8; t.Bits = 8;
			case "char32": t.Kind = .Char32; t.Bits = 32;
			case "StringView", "Core.StringView": t.Kind = .StringView;
			default: known = false;
			}
		}

		/// The canonical text of a primitive (int64 prints as int, as the language writes it).
		static void PrimitiveText(IRType t, String outText)
		{
			switch (t.Kind)
			{
			case .Void: outText.Append("void");
			case .Bool: outText.Append("bool");
			case .Int:
				if (t.Signed)
					outText.Append(t.Bits == 64 ? "int" : scope $"int{t.Bits}");
				else
					outText.Append(t.Bits == 64 ? "uint" : scope $"uint{t.Bits}");
			case .Float: outText.Append(t.Bits == 32 ? "float" : "double");
			case .Char8: outText.Append("char8");
			case .Char32: outText.Append("char32");
			case .StringView: outText.Append("StringView");
			default:
			}
		}

		IRType Make(IRTypeKind kind, IRType elem)
		{
			IRType t = new .();
			t.Kind = kind;
			t.Elem = elem;
			switch (kind)
			{
			case .Pointer: t.Text.AppendF("{}*", elem.Text);
			case .Ref: t.Text.AppendF("ref {}", elem.Text);
			case .Array: t.Text.AppendF("{}[]", elem.Text);
			case .Nullable: t.Text.AppendF("{}?", elem.Text);
			default:
			}
			return mProgram.Intern(t);
		}

		/// Parses a qualified name `A.B<x,y>.C` (generic args on any part).
		public Result<IRName> ParseQualified()
		{
			IRName name = new .();
			while (true)
			{
				let id = Ident();
				if (id.IsEmpty)
				{
					delete name;
					SetError("expected a name");
					return .Err;
				}
				IRNameSeg seg = new .();
				seg.Ident.Set(id);
				name.Segs.Add(seg);
				if (Peek('<'))
				{
					mPos++;
					if (!Peek('>'))
					{
						while (true)
						{
							if (ParseType() case .Ok(let a))
								seg.Args.Add(a);
							else
							{
								delete name;
								return .Err;
							}
							if (Eat(','))
								continue;
							break;
						}
					}
					if (!Eat('>'))
					{
						delete name;
						SetError("expected '>'");
						return .Err;
					}
				}
				// A '.' continues the name only when an identifier follows (not "...").
				if (mPos + 1 < mText.Length && mText[mPos] == '.' && IsIdentChar(mText[mPos + 1]))
				{
					mPos++;
					continue;
				}
				break;
			}
			return name;
		}

		public Result<IRType> ParseType()
		{
			SkipWs();
			IRType t = null;
			if (mText.Substring(mPos).StartsWith("ref ") || mText.Substring(mPos).StartsWith("ref\t"))
			{
				mPos += 4;
				if (ParseType() case .Ok(let inner))
					return Make(.Ref, inner);
				return .Err;
			}
			if (Peek('('))
			{
				mPos++;
				IRType tup = new .();
				tup.Kind = .Tuple;
				tup.Text.Append('(');
				while (true)
				{
					if (ParseType() case .Ok(let item))
					{
						if (!tup.Items.IsEmpty)
							tup.Text.Append(',');
						tup.Items.Add(item);
						tup.Text.Append(item.Text);
					}
					else
					{
						delete tup;
						return .Err;
					}
					if (Eat(','))
						continue;
					break;
				}
				if (!Eat(')'))
				{
					delete tup;
					return Fail("expected ')'");
				}
				tup.Text.Append(')');
				t = mProgram.Intern(tup);
			}
			else
			{
				int save = mPos;
				let word = Ident();
				if ((word == "function" || word == "delegate") && !Peek('.') && !Peek('<'))
				{
					IRType fp = new .();
					fp.Kind = (word == "delegate") ? .Delegate : .FnPtr;
					if (ParseType() case .Ok(let ret))
						fp.Ret = ret;
					else
					{
						delete fp;
						return .Err;
					}
					if (!Eat('('))
					{
						delete fp;
						return Fail("expected '(' after the return type of a function type");
					}
					fp.Text.AppendF("{} {}(", word, fp.Ret.Text);
					if (!Peek(')'))
					{
						while (true)
						{
							if (ParseType() case .Ok(let p))
							{
								if (!fp.Items.IsEmpty)
									fp.Text.Append(',');
								fp.Items.Add(p);
								fp.Text.Append(p.Text);
							}
							else
							{
								delete fp;
								return .Err;
							}
							if (Eat(','))
								continue;
							break;
						}
					}
					if (!Eat(')'))
					{
						delete fp;
						return Fail("expected ')'");
					}
					fp.Text.Append(')');
					t = mProgram.Intern(fp);
				}
				else
				{
					mPos = save;
					IRName name;
					if (ParseQualified() case .Ok(let n))
						name = n;
					else
						return .Err;
					IRType nt = new .();
					String plain = scope .();
					name.ToString(plain);
					bool known = false;
					if (name.Segs.Count <= 2 && !name.HasGenericArgs)
						Primitive(plain, nt, out known);
					if (!known && name.Segs.Count == 1 && !name.HasGenericArgs)
						known = IRVector.ParseVectorType(mProgram, plain, nt); // float4, int32x4, bool4 (IRVector.bf)
					if (known && nt.Kind == .Vector)
						delete name;
					else if (known)
					{
						delete name;
						PrimitiveText(nt, nt.Text);
					}
					else
					{
						if (plain == "Object")
						{
							delete name;
							name = ParseName(mProgram, "Core.Object");
							plain.Set("Core.Object");
						}
						nt.Kind = .Named;
						nt.Name = name;
						nt.Text.Set(plain);
					}
					t = mProgram.Intern(nt);
				}
			}
			// suffixes
			while (true)
			{
				if (Eat('*'))
					t = Make(.Pointer, t);
				else if (Eat('?'))
					t = Make(.Nullable, t);
				else if (Peek('['))
				{
					mPos++;
					if (Eat(']'))
					{
						t = Make(.Array, t);
						continue;
					}
					SkipWs();
					int start = mPos;
					while (mPos < mText.Length && mText[mPos].IsDigit)
						mPos++;
					let num = mText.Substring(start, mPos - start);
					if (num.IsEmpty || !Eat(']'))
						return Fail("expected ']' or a length");
					IRType fa = new .();
					fa.Kind = .FixedArray;
					fa.Elem = t;
					fa.Count = int64.Parse(num).GetValueOrDefault();
					fa.Text.AppendF("{}[{}]", t.Text, fa.Count);
					t = mProgram.Intern(fa);
				}
				else
					break;
			}
			return t;
		}

		/// A qualified name from text; null when it does not parse.
		public static IRName ParseName(IRProgram program, StringView text)
		{
			TypeParser p = scope .(program, text);
			if (p.ParseQualified() case .Ok(let n))
				return n;
			return null;
		}
	}

	/// Function reference text: `Owner.Name<gargs>(ptypes[,...])`.
	static class FuncKey
	{
		/// Fills the name parts and `Key` (canonical) of `f` from `text`. False with `outError`.
		public static bool Parse(IRProgram program, StringView text, IRFunction f, String outError)
		{
			TypeParser p = scope .(program, text);
			IRName name;
			if (p.ParseQualified() case .Ok(let n))
				name = n;
			else
			{
				outError?.Append(p.Error);
				return false;
			}
			defer delete name;
			let last = name.Segs.Back;
			f.Name.Set(last.Ident);
			f.GenericArgs.Clear();
			f.GenericArgs.AddRange(last.Args);
			delete f.Owner;
			f.Owner = null;
			if (name.Segs.Count > 1)
			{
				f.Owner = new .();
				for (int i < name.Segs.Count - 1)
				{
					IRNameSeg seg = new .();
					seg.Ident.Set(name.Segs[i].Ident);
					seg.Args.AddRange(name.Segs[i].Args);
					f.Owner.Segs.Add(seg);
				}
			}
			// parameter list
			var rest = p.Rest;
			rest.Trim();
			if (!rest.StartsWith('('))
			{
				outError?.AppendF("expected '(' after the function name in '{}'", text);
				return false;
			}
			p.Pos = text.Length - rest.Length + 1;
			f.ParamTypes.Clear();
			f.Variadic = false;
			var inner = p.Rest;
			inner.TrimStart();
			if (!inner.StartsWith(')'))
			{
				while (true)
				{
					var r = p.Rest;
					r.TrimStart();
					if (r.StartsWith("..."))
					{
						f.Variadic = true;
						p.Pos = text.Length - r.Length + 3;
						break;
					}
					if (p.ParseType() case .Ok(let t))
						f.ParamTypes.Add(t);
					else
					{
						outError?.Append(p.Error);
						return false;
					}
					var r2 = p.Rest;
					r2.TrimStart();
					if (r2.StartsWith(','))
					{
						p.Pos = text.Length - r2.Length + 1;
						continue;
					}
					break;
				}
			}
			var close = p.Rest;
			close.Trim();
			if (close != ")")
			{
				outError?.AppendF("expected ')' at the end of '{}'", text);
				return false;
			}
			f.Key.Clear();
			Print(f, f.Key);
			return true;
		}

		public static void Print(IRFunction f, String outText)
		{
			if (f.Owner != null)
			{
				f.Owner.ToString(outText);
				outText.Append('.');
			}
			outText.Append(f.Name);
			if (!f.GenericArgs.IsEmpty)
			{
				outText.Append('<');
				for (let a in f.GenericArgs)
				{
					if (@a.Index > 0)
						outText.Append(',');
					outText.Append(a.Text);
				}
				outText.Append('>');
			}
			outText.Append('(');
			for (let t in f.ParamTypes)
			{
				if (@t.Index > 0)
					outText.Append(',');
				outText.Append(t.Text);
			}
			if (f.Variadic)
				outText.Append(f.ParamTypes.IsEmpty ? "..." : ",...");
			outText.Append(')');
		}
	}
}
