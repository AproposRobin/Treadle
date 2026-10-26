using System;
using System.Collections;

namespace Treadle.Compiler
{
	/// The core library's intrinsics that are not one back-end op (docs/Core-Library.md, "What
	/// is intrinsic"): pointer arithmetic, reads and writes, element sizes, the hashing and
	/// equality the generic collections use, and the Math functions over LLVM intrinsics.
	extension FnLowerer
	{
		IROp Op1(OpKind kind, KType type, IRValue a, StringView node, StringView pin)
		{
			let op = E.Op(kind, type, node, pin);
			op.Operands.Add(a);
			return op;
		}

		IROp Op2(OpKind kind, StringView sub, KType type, IRValue a, IRValue b, StringView node, StringView pin)
		{
			let op = E.Op(kind, type, node, pin);
			if (!sub.IsEmpty)
				op.Sub = new String(sub);
			op.Operands.Add(a);
			op.Operands.Add(b);
			return op;
		}

		/// A call of a core member function named `name` of `t` with no inputs but `this`: the
		/// value for a class, the address of a copy for a struct.
		IRValue CallCoreMember(KType t, StringView name, IRValue v, IRValue arg, KType result, StringView node, StringView pin)
		{
			MemberSym f = null;
			for (let m in t.Sym.Members)
				if (m.Kind == .Function && m.Name == name && !m.Static && m.Params.Count == ((arg != null) ? 1 : 0))
					f = m;
			if (f == null)
				return null;
			IRValue recv = v;
			if (t.Sym.Kind == .Struct || t.Sym.Kind == .Enum)
			{
				let slot = F.NewSlot(t, .OutTemp, node, scope $"{pin}.this{F.Slots.Count}");
				StoreSlot(slot, v, node, pin);
				recv = SlotAddr(slot, node, pin);
			}
			else
				E.Op(.NullCheck, T.Void, node, pin).Operands.Add(v);
			String fname = scope .();
			M.FuncRef(f, t, null, .Body, fname);
			M.Use(f, t, fname);
			let call = E.Op(.Call, result, node, pin);
			call.Callee = new String(fname);
			call.Operands.Add(recv);
			if (arg != null)
				call.Operands.Add(arg);
			return call;
		}

		/// Values the hash and equality intrinsics treat as plain bits.
		bool IsPlain(KType t) => t.IsInteger || t.Kind == .Char || t.Kind == .Bool || (t.IsEnum && !t.Sym.HasPayload);

		/// `Hash.Get<T>`: an integer mix for numbers, characters, bools and simple enums; the
		/// type's own GetHashCode() otherwise (String, StringView, a type implementing IHashable);
		/// a reference's address for a class without one.
		IRValue HashOf(IRValue v, StringView node, StringView pin)
		{
			let t = v.Type;
			if (t.IsVector)
				return VectorHash(v, node, pin); // LowerVector.bf: FNV-1a over the lanes' bytes
			IRValue x = null;
			if (IsPlain(t))
				x = (t == T.Int) ? v : Op1(.Cast, T.Int, v, node, pin);
			else if (t.Kind == .Float)
				x = Op1(.Cast, T.Int, v, node, pin);
			else if (t.Kind == .Named)
			{
				let h = CallCoreMember(t, "GetHashCode", v, null, T.Int, node, pin);
				if (h != null)
					return h;
				if (t.IsReference)
					x = Op1(.Cast, T.Int, Op1(.Cast, T.Pointer(T.Void), v, node, pin), node, pin);
			}
			else if (t.Kind == .Pointer)
				x = Op1(.Cast, T.Int, v, node, pin);
			if (x == null)
				return E.Const("0", T.Int, node, pin);
			// x * 0x9E3779B97F4A7C15, then the high half folded in.
			let k = E.Const("-7046029254386353131", T.Int, node, pin);
			let m = Op2(.Binop, "mul", T.Int, x, k, node, pin);
			let sh = Op2(.Binop, "shr", T.Int, m, E.Const("29", T.Int, node, pin), node, pin);
			return Op2(.Binop, "xor", T.Int, m, sh, node, pin);
		}

		/// `Hash.Equal<T>`: `==` for numbers, characters, bools, simple enums and pointers; the
		/// type's own Equals(T) otherwise (String and StringView compare their text); the same
		/// object for a class without one.
		IRValue EqualOf(IRValue a, IRValue b, StringView node, StringView pin)
		{
			let t = a.Type;
			if (t.IsVector)
				return VectorEqual(a, b, node, pin); // LowerVector.bf: every lane ==
			if (t.Kind == .Named)
			{
				var arg = b;
				if (t.Sym == T.StringSym)
				{
					// String.Equals takes a StringView.
					let view = E.Op(.Call, T.StringViewSym.Self, node, pin);
					view.Callee = new String("Core.String.View()");
					view.Operands.Add(b);
					arg = view;
				}
				let r = CallCoreMember(t, "Equals", a, arg, T.Bool, node, pin);
				if (r != null)
					return r;
			}
			return Op2(.Cmp, "eq", T.Bool, a, b, node, pin);
		}

		/// Whether String has an Append taking `t` itself (an overload an extension adds, as the core's
		/// MathFormat does for Vec3, Mat4, Color...).
		bool HasAppend(KType t)
		{
			if (t.Kind != .Named)
				return false;
			for (let m in T.StringSym.Members)
				if (m.Kind == .Function && m.Name == "Append" && !m.Static && m.Params.Count == 1 && m.Params[0].Type == t)
					return true;
			return false;
		}

		/// `String.AppendValue<T>(into, value)` (AppendF's arguments): the String.Append overload for the
		/// value's type: integers and simple enums as int, float, double, bool, char8, char16 and char32 as a
		/// code point in UTF-8, StringView, a String through its view. Any other type appends its name in
		/// angle brackets.
		void AppendValue(IRValue into, IRValue v, StringView node, StringView pin)
		{
			let t = v.Type;
			KType want = null;
			IRValue arg = v;
			let char32 = T.Prim("char32");
			if (t == T.Int || t == T.Float || t == T.Double || t == T.Bool || t == T.Char8 || t == T.StringViewSym.Self || t == char32)
				want = t;
			else if (t.Kind == .Char)
			{
				want = char32;
				arg = Op1(.Cast, char32, v, node, pin);
			}
			else if (t.IsInteger || (t.IsEnum && !t.Sym.HasPayload))
			{
				want = T.Int;
				arg = Op1(.Cast, T.Int, v, node, pin);
			}
			else if (t.Kind == .Float)
			{
				want = T.Double;
				arg = Op1(.Cast, T.Double, v, node, pin);
			}
			else if (t.Kind == .Named && t.Sym == T.StringSym)
			{
				want = T.StringViewSym.Self;
				let view = E.Op(.Call, T.StringViewSym.Self, node, pin);
				view.Callee = new String("Core.String.View()");
				view.Operands.Add(v);
				arg = view;
			}
			else if (HasAppend(t))
				want = t; // a String.Append overload of its own (the math types: MathFormat)
			else
			{
				want = T.StringViewSym.Self;
				String name = scope .();
				TypeTable.Show(t, name);
				arg = E.Const(scope $"\"<{name}>\"", T.StringViewSym.Self, node, pin);
			}
			let st = T.StringSym.Self;
			MemberSym f = null;
			for (let m in st.Sym.Members)
				if (m.Kind == .Function && m.Name == "Append" && !m.Static && m.Params.Count == 1 && m.Params[0].Type == want)
					f = m;
			if (f == null)
				return;
			String fname = scope .();
			M.FuncRef(f, st, null, .Body, fname);
			M.Use(f, st, fname);
			let call = E.Op(.Call, T.Void, node, pin);
			call.Callee = new String(fname);
			call.Operands.Add(into);
			call.Operands.Add(arg);
		}

		/// `String.AppendFormatted<T>(into, value, format)` (AppendF's placeholders with a spec): a number goes
		/// to the String.AppendNumber overload for it (integers and simple enums as int, float, double; any
		/// other float kind as double) with the spec; any other value is appended as AppendValue appends it, the
		/// spec ignored.
		void AppendFormatted(IRValue into, IRValue v, IRValue format, StringView node, StringView pin)
		{
			let t = v.Type;
			KType want = null;
			IRValue arg = v;
			if (t == T.Int || t == T.Float || t == T.Double)
				want = t;
			else if (t.IsInteger || (t.IsEnum && !t.Sym.HasPayload))
			{
				want = T.Int;
				arg = Op1(.Cast, T.Int, v, node, pin);
			}
			else if (t.Kind == .Float)
			{
				want = T.Double;
				arg = Op1(.Cast, T.Double, v, node, pin);
			}
			if (want == null)
			{
				AppendValue(into, v, node, pin);
				return;
			}
			let st = T.StringSym.Self;
			MemberSym f = null;
			for (let m in st.Sym.Members)
				if (m.Kind == .Function && m.Name == "AppendNumber" && !m.Static && m.Params.Count == 2 && m.Params[0].Type == want)
					f = m;
			if (f == null)
				return;
			String fname = scope .();
			M.FuncRef(f, st, null, .Body, fname);
			M.Use(f, st, fname);
			let call = E.Op(.Call, T.Void, node, pin);
			call.Callee = new String(fname);
			call.Operands.Add(into);
			call.Operands.Add(arg);
			call.Operands.Add(format);
		}

		/// A core intrinsic lowered here (`handled` false: not one of these).
		IRValue CoreIntrinsic(StringView name, List<IRValue> args, KType result, StringView node, StringView pin, out bool handled)
		{
			handled = true;
			IRValue Math1(StringView what)
			{
				let op = E.Op(.Intrinsic, result, node, pin);
				op.Sub = new String(what);
				op.Operands.Add(args[0]);
				if (args.Count > 1)
					op.Operands.Add(args[1]);
				return op;
			}
			switch (name)
			{
			case "Build.IsDefined", "Build.Value":
				// the config's `define`s (Graph-Format.md 5) as constants: the name is the node's
				// typed text; a wired name has no value at build time
				let lit = args[0] as IROp;
				if (lit == null || lit.Kind != .Const || !lit.LitIsString)
				{
					M.C.Diags.Add(.Error, .Lower, "T4002", R.Site, node, "name", scope $"{name}: the name is the text typed on the node, not a wire (a define is known when the program is built)");
					M.Failed();
					return E.Const((name == "Build.Value") ? "\"\"" : "false", result, node, pin);
				}
				let settings = M.C.Settings;
				if (name == "Build.IsDefined")
					return E.Const((settings != null && settings.IsDefined(lit.Lit)) ? "true" : "false", T.Bool, node, pin);
				let v = E.Op(.Const, T.StringViewSym.Self, node, pin);
				v.Lit = new String((settings != null) ? settings.Value(lit.Lit) : "");
				v.LitIsString = true;
				return v;
			case "Pointer.Add":
				return Op2(.ElemAddr, "", result, args[0], args[1], node, pin);
			case "Pointer.Load":
				return Op1(.Load, result, args[0], node, pin);
			case "Pointer.Store":
				Op2(.Store, "", T.Void, args[0], args[1], node, pin);
				return null;
			case "Memory.ElementSize":
				let op = E.Op(.SizeOf, T.Int, node, pin);
				let pt = args[0].Type;
				op.TypeArg = (pt.Kind == .Pointer) ? pt.Element : pt;
				M.Need(op.TypeArg);
				return op;
			case "Arrays.Set":
				// array[index] = value (checked in Debug, as Get [ ] is).
				E.Op(.NullCheck, T.Void, node, pin).Operands.Add(args[0]);
				Op2(.BoundsCheck, "", T.Void, args[0], args[1], node, pin);
				let at = Op2(.ElemAddr, "", T.Pointer(args[0].Type.Element ?? args[2].Type), args[0], args[1], node, pin);
				Op2(.Store, "", T.Void, at, args[2], node, pin);
				return null;
			case "StringView.Substring":
				// this is the view's address: its pointer moved by start, the given length.
				let view = Op1(.Load, T.StringViewSym.Self, args[0], node, pin);
				let ptr = E.Op(.Extract, T.Pointer(T.Char8), node, pin);
				ptr.Operands.Add(view);
				ptr.Index = 0;
				let moved = Op2(.ElemAddr, "", T.Pointer(T.Char8), ptr, args[1], node, pin);
				let mk = E.Op(.Make, T.StringViewSym.Self, node, pin);
				mk.Operands.Add(moved);
				mk.Operands.Add(args[2]);
				return mk;
			case "Arrays.DestroyAt":
				// The element's destructor when it is a struct that has one (Core-Library.md 3, "Moves"); nothing
				// for numbers, references (the element does not own the object), StringView and plain structs (the back end's
				// `dtor` on a struct that needs none is nothing).
				let et = args[0].Type.Element ?? T.Error;
				if (et.IsStruct && et.Sym != T.StringViewSym)
				{
					E.Op(.NullCheck, T.Void, node, pin).Operands.Add(args[0]);
					Op2(.BoundsCheck, "", T.Void, args[0], args[1], node, pin);
					let at = Op2(.ElemAddr, "", T.Pointer(et), args[0], args[1], node, pin);
					Op1(.Dtor, T.Void, at, node, pin);
				}
				return null;
			case "Arrays.Address":
				// &array[index], not checked (List.Slice checks its range first).
				return Op2(.ElemAddr, "", result, args[0], args[1], node, pin);
			case "Arrays.Slice":
				// A Span over `count` elements from `start`: `array.span` (null and the range checked in Debug).
				M.Need(result);
				let sp = E.Op(.ArraySpan, result, node, pin);
				sp.Operands.Add(args[0]);
				sp.Operands.Add(args[1]);
				sp.Operands.Add(args[2]);
				return sp;
			case "Arrays.Free":
				// The array's memory back without running its elements' destructors (they were moved out).
				Op1(.Free, T.Void, args[0], node, pin);
				return null;
			case "String.AppendValue":
				AppendValue(args[0], args[1], node, pin);
				return null;
			case "String.AppendFormatted":
				AppendFormatted(args[0], args[1], args[2], node, pin);
				return null;
			case "String.InlineBuffer":
				// &s.mInline as a char8*: String's first buffer (Core-Library.md 3, "String's buffer").
				for (let m in T.StringSym.Members)
				{
					if (m.Kind != .Field || m.Name != "mInline")
						continue;
					let fa = E.Op(.FieldAddr, T.Pointer(m.Type), node, pin);
					fa.Operands.Add(args[0]);
					fa.Sub = new String(m.Name);
					return Op1(.Cast, result, fa, node, pin);
				}
				return E.Const("null", result, node, pin);
			case "Console.Error(StringView)":
				let err = E.Op(.Intrinsic, T.Void, node, pin);
				err.Sub = new String("console.error");
				err.Operands.Add(args[0]);
				return null;
			case "Hash.Get":
				return HashOf(args[0], node, pin);
			case "Hash.Equal":
				return EqualOf(args[0], args[1], node, pin);
			case "Math.Sin": return Math1("sin");
			case "Math.Cos": return Math1("cos");
			case "Math.Pow": return Math1("pow");
			case "Math.Round": return Math1("round");
			case "Math.Truncate": return Math1("trunc");
			case "Math.Exp": return Math1("exp");
			case "Math.Log": return Math1("log");
			case "Math.Clamp":
				// Max(lo, Min(x, hi)).
				let lt = Operate("<", result, args[2], args[0], T.Bool, node, pin);
				let lo = E.Op(.Select, result, node, pin);
				lo.Operands.Add(lt);
				lo.Operands.Add(args[2]);
				lo.Operands.Add(args[0]);
				let lt2 = Operate("<", result, lo, args[1], T.Bool, node, pin);
				let hi = E.Op(.Select, result, node, pin);
				hi.Operands.Add(lt2);
				hi.Operands.Add(args[1]);
				hi.Operands.Add(lo);
				return hi;
			// ---- Math library (SIMD-and-Vectors.md 2.2, "Scalar Math additions"): LLVM intrinsics on float
			// and double (llvm.tan, llvm.asin, llvm.acos, llvm.atan, llvm.atan2, llvm.fma, llvm.copysign).
			case "Math.Tan": return Math1("tan");
			case "Math.Asin": return Math1("asin");
			case "Math.Acos": return Math1("acos");
			case "Math.Atan": return Math1("atan");
			case "Math.Atan2": return Math1("atan2");
			case "Math.CopySign": return Math1("copysign");
			case "Math.Fma":
				let fma = E.Op(.Intrinsic, result, node, pin);
				fma.Sub = new String("fma");
				fma.Operands.AddRange(args);
				return fma;
			// ---- end of the Math library block
			default:
			}
			handled = false;
			return null;
		}
	}
}
