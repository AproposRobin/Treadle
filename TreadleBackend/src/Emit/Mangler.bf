using System;
using System.Collections;
using Treadle.Backend.IR;

namespace Treadle.Backend.Emit
{
	/// Itanium C++ ABI mangling (docs/Compiler.md 5.1): Treadle namespaces and types as C++
	/// namespaces and classes, generic arguments as template arguments, with the ABI's substitution
	/// compression, so lldb, llvm-nm, llvm-objdump and crash dumps demangle every symbol.
	///
	///   int x, int32 i, int16 s, int8 a, uint y, uint32 j, uint16 t, uint8 h, float f, double d,
	///   bool b, char8 c, char32 Di, void v; T* P, ref T R; T[] Core::Array<T>; T? Core::Nullable<T>;
	///   (A,B) Core::Tuple<A,B>; T[N] the C++ array A<N>_T; StringView Core::StringView;
	///   function R(A) PFRAE; constructor C1, the destructor's Sheet D2, the complete destructor D1.
	class Mangler
	{
		/// Substitution candidates in order (canonical keys of prefixes and types).
		List<String> mSubs = new .() ~ DeleteContainerAndItems!(_);
		IRProgram mProgram;

		public this(IRProgram program)
		{
			mProgram = program;
		}

		void Reset() => ClearAndDeleteItems!(mSubs);

		bool TrySub(StringView key, String outText)
		{
			for (int i < mSubs.Count)
			{
				if (mSubs[i] == key)
				{
					outText.Append('S');
					if (i > 0)
						SeqId(i - 1, outText);
					outText.Append('_');
					return true;
				}
			}
			return false;
		}

		static void SeqId(int n, String outText)
		{
			// base 36, digits then upper-case letters
			String digits = scope .();
			var v = n;
			repeat
			{
				let d = v % 36;
				digits.Insert(0, (d < 10) ? (char8)('0' + d) : (char8)('A' + d - 10));
				v /= 36;
			}
			while (v > 0);
			outText.Append(digits);
		}

		void AddSub(StringView key)
		{
			for (let s in mSubs)
				if (s == key)
					return;
			mSubs.Add(new .(key));
		}

		static void Source(StringView ident, String outText)
		{
			outText.AppendF("{}{}", ident.Length, ident);
		}

		void TemplateArgs(List<IRType> args, String outText)
		{
			outText.Append('I');
			for (let a in args)
				Type(a, outText);
			outText.Append('E');
		}

		/// `N <prefix> E` for a qualified name. `skipLast`: the last segment is a function's name
		/// (not a substitution candidate); `lastOverride` replaces its source name (C1, D1).
		void Nested(IRName name, String outText, bool isFunction, StringView lastOverride, List<IRType> fnArgs)
		{
			// keys of every prefix: "A", "A.B", "A.B<..>" (template name, then template id)
			int n = name.Segs.Count;
			// find the longest prefix (not counting the function name) that is already a candidate
			int start = 0;
			String body = scope .();
			String key = scope .();
			int limit = isFunction ? n - 1 : n;
			for (int i = limit; i >= 1; i--)
			{
				String k = scope .();
				KeyOf(name, i, true, k);
				if (TrySub(k, body))
				{
					start = i;
					key.Set(k);
					break;
				}
				if (!name.Segs[i - 1].Args.IsEmpty)
				{
					k.Clear();
					KeyOf(name, i, false, k);
					String tmp = scope .();
					if (TrySub(k, tmp))
					{
						body.Append(tmp);
						TemplateArgs(name.Segs[i - 1].Args, body);
						String full = scope .();
						KeyOf(name, i, true, full);
						AddSub(full);
						start = i;
						key.Set(full);
						break;
					}
				}
			}
			for (int i = start; i < n; i++)
			{
				let seg = name.Segs[i];
				let isLast = i == n - 1;
				if (isLast && isFunction)
				{
					if (!lastOverride.IsEmpty)
						body.Append(lastOverride);
					else
						Source(seg.Ident, body);
					if (fnArgs != null && !fnArgs.IsEmpty)
						TemplateArgs(fnArgs, body);
					break;
				}
				Source(seg.Ident, body);
				String k = scope .();
				KeyOf(name, i + 1, false, k);
				AddSub(k);
				if (!seg.Args.IsEmpty)
				{
					TemplateArgs(seg.Args, body);
					k.Clear();
					KeyOf(name, i + 1, true, k);
					AddSub(k);
				}
			}
			// a name of one plain segment (a free function, a global type) needs no N...E
			let components = n;
			if (components == 1 && start == 0 && (fnArgs == null || fnArgs.IsEmpty) && name.Segs[0].Args.IsEmpty)
				outText.Append(body);
			else if (start == n && !isFunction)
				outText.Append(body); // the whole name is one substitution
			else
				outText.AppendF("N{}E", body);
		}

		/// "Game.Player" for the first `count` segments; `withArgs`: the last one's generic args too.
		static void KeyOf(IRName name, int count, bool withArgs, String outKey)
		{
			for (int i < count)
			{
				let s = name.Segs[i];
				if (i > 0)
					outKey.Append('.');
				outKey.Append(s.Ident);
				if (!s.Args.IsEmpty && (i < count - 1 || withArgs))
				{
					outKey.Append('<');
					for (let a in s.Args)
					{
						if (@a.Index > 0)
							outKey.Append(',');
						outKey.Append(a.Text);
					}
					outKey.Append('>');
				}
			}
		}

		void CoreTemplate(StringView ident, List<IRType> args, StringView unusedKey, String outText)
		{
			String key = scope .();
			key.AppendF("Core.{}<", ident);
			for (let a in args)
			{
				if (@a.Index > 0)
					key.Append(',');
				key.Append(a.Text);
			}
			key.Append('>');
			if (TrySub(key, outText))
				return;
			IRName n = scope .();
			IRNameSeg core = new .();
			core.Ident.Set("Core");
			n.Segs.Add(core);
			IRNameSeg seg = new .();
			seg.Ident.Set(ident);
			seg.Args.AddRange(args);
			n.Segs.Add(seg);
			Nested(n, outText, false, "", null);
		}

		/// One type.
		public void Type(IRType t, String outText)
		{
			switch (t.Kind)
			{
			case .Void: outText.Append('v');
			case .Vector:
				// Itanium vendor vectors: Dv4_f (float4), Dv4_i (int32x4), Dv16_h (uint8x16), Dv4_b (bool4)
				outText.AppendF("Dv{}_", t.Count);
				Type(t.Elem, outText);
			case .Bool: outText.Append('b');
			case .Int:
				switch (t.Bits)
				{
				case 8: outText.Append(t.Signed ? 'a' : 'h');
				case 16: outText.Append(t.Signed ? 's' : 't');
				case 32: outText.Append(t.Signed ? 'i' : 'j');
				case 128: outText.Append(t.Signed ? 'n' : 'o');
				default: outText.Append(t.Signed ? 'x' : 'y');
				}
			case .Float: outText.Append(t.Bits == 32 ? 'f' : 'd');
			case .Char8: outText.Append('c');
			case .Char32: outText.Append("Di");
			case .Pointer, .Ref:
				if (TrySub(t.Text, outText))
					return;
				outText.Append(t.Kind == .Pointer ? 'P' : 'R');
				Type(t.Elem, outText);
				AddSub(t.Text);
			case .Array:
				List<IRType> a = scope .();
				a.Add(t.Elem);
				CoreTemplate("Array", a, scope $"Core.Array<{t.Elem.Text}>", outText);
			case .Nullable:
				List<IRType> a = scope .();
				a.Add(t.Elem);
				CoreTemplate("Nullable", a, scope $"Core.Nullable<{t.Elem.Text}>", outText);
			case .Tuple:
				CoreTemplate("Tuple", t.Items, scope $"Core.Tuple<{t.Text}>", outText);
			case .FixedArray:
				// the C++ array type: A<N>_<T>
				if (TrySub(t.Text, outText))
					return;
				outText.AppendF("A{}_", t.Count);
				Type(t.Elem, outText);
				AddSub(t.Text);
			case .StringView:
				if (TrySub("Core.StringView", outText))
					return;
				IRName n = scope .();
				IRNameSeg core = new .();
				core.Ident.Set("Core");
				n.Segs.Add(core);
				IRNameSeg sv = new .();
				sv.Ident.Set("StringView");
				n.Segs.Add(sv);
				Nested(n, outText, false, "", null);
			case .FnPtr:
				if (TrySub(t.Text, outText))
					return;
				outText.Append("PF");
				Type(t.Ret, outText);
				if (t.Items.IsEmpty)
					outText.Append('v');
				for (let p in t.Items)
					Type(p, outText);
				outText.Append('E');
				AddSub(scope $"fn:{t.Text}");
				AddSub(t.Text);
			case .Delegate:
				// Core::Delegate<R, A, B>
				List<IRType> a = scope .();
				a.Add(t.Ret);
				a.AddRange(t.Items);
				CoreTemplate("Delegate", a, "", outText);
			case .Named:
				if (TrySub(t.Text, outText))
					return;
				Nested(t.Name, outText, false, "", null);
			}
		}

		/// The mangled type name without `_Z` ("N4Game6PlayerE"): the FNV input for its type id and
		/// the tail of `_ZTV` / `_ZTI` / `_ZTS`.
		public void TypeName(IRType t, String outText)
		{
			Reset();
			Type(t, outText);
		}

		/// FNV-1a 32 of the mangled type name (TypeInfo.typeId).
		public uint32 TypeId(IRType t)
		{
			String s = scope .();
			TypeName(t, s);
			return Fnv1a(s);
		}

		public static uint32 Fnv1a(StringView s)
		{
			uint32 h = 2166136261;
			for (let c in s.RawChars)
			{
				h ^= (uint8)c;
				h = h &* 16777619;
			}
			return h;
		}

		/// The symbol of a function. Imports: the C name. `variant`: "" (the function itself), "D1"
		/// (the complete destructor of `f`'s owner, `f` may be null with `owner` set).
		public void Function(IRFunction f, String outText)
		{
			if (f.IsImport)
			{
				outText.Append(f.ImportName);
				return;
			}
			Reset();
			outText.Append("_Z");
			IRName name = scope .();
			if (f.Owner != null)
				for (let s in f.Owner.Segs)
				{
					IRNameSeg c = new .();
					c.Ident.Set(s.Ident);
					c.Args.AddRange(s.Args);
					name.Segs.Add(c);
				}
			IRNameSeg last = new .();
			last.Ident.Set(f.Name);
			name.Segs.Add(last);
			StringView over = "";
			if (f.IsCtor && !f.Static)
				over = "C1";
			else if (f.IsDtor)
				over = "D2";
			else if (f.StaticCtor)
				over = "8__sctor";
			if (name.Segs.Count == 1)
			{
				// a free function
				if (!over.IsEmpty)
					outText.Append(over);
				else
					Source(f.Name, outText);
				if (!f.GenericArgs.IsEmpty)
					TemplateArgs(f.GenericArgs, outText);
			}
			else
				Nested(name, outText, true, over, f.GenericArgs);
			// template functions encode the return type first
			if (!f.GenericArgs.IsEmpty)
				Type(f.Ret, outText);
			if (f.ParamTypes.IsEmpty && !f.Variadic)
				outText.Append('v');
			for (let p in f.ParamTypes)
				Type(p, outText);
			if (f.Variadic)
				outText.Append('z');
		}

		/// The complete destructor of a class (`_ZN4Game4NodeD1Ev`).
		public void CompleteDtor(IRTypeDecl d, String outText)
		{
			Reset();
			outText.Append("_Z");
			IRName name = d.Type.Name.Clone();
			defer delete name;
			IRNameSeg last = new .();
			last.Ident.Set("~this");
			name.Segs.Add(last);
			Nested(name, outText, true, "D1", null);
			outText.Append('v');
		}

		/// The complete destructor of an array type whose elements need destruction
		/// (`_ZN4Core5ArrayIN4Game4ItemEED1Ev`).
		public void ArrayDtor(IRType arrayType, String outText)
		{
			Reset();
			outText.Append("_Z");
			IRName name = scope .();
			IRNameSeg core = new .();
			core.Ident.Set("Core");
			name.Segs.Add(core);
			IRNameSeg arr = new .();
			arr.Ident.Set("Array");
			arr.Args.Add(arrayType.Elem);
			name.Segs.Add(arr);
			IRNameSeg last = new .();
			last.Ident.Set("~this");
			name.Segs.Add(last);
			Nested(name, outText, true, "D1", null);
			outText.Append('v');
		}

		/// The thunk a delegate bound to a static function calls (`fn(target, args)` -> `f(args)`).
		public void DelegateThunk(IRFunction f, String outText)
		{
			Function(f, outText);
			outText.Append(".dthunk"); // a clone suffix: demangles as "f(...) (.dthunk)"
		}

		public void VTable(IRType t, String outText)
		{
			outText.Append("_ZTV");
			TypeName(t, outText);
		}

		public void TypeInfo(IRType t, String outText)
		{
			outText.Append("_ZTI");
			TypeName(t, outText);
		}

		public void TypeNameString(IRType t, String outText)
		{
			outText.Append("_ZTS");
			TypeName(t, outText);
		}

		/// A static field: `_ZN4Game6Player6sCountE`.
		public void Global(IRGlobal g, String outText)
		{
			Reset();
			outText.Append("_Z");
			Nested(g.Name, outText, true, "", null);
		}
	}
}
