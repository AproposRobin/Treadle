using System;
using System.Collections;

namespace Treadle.Model
{
	/// The shape of a type reference.
	enum TypeRefKind : uint8
	{
		/// No type (an untyped pin, a missing return type || t.ToString(.. scope String()) != text).
		None,
		/// A named type, possibly qualified and with generic arguments: `int`, `Game.Player`, `List<int>`.
		Named,
		/// `T[]`: an array object.
		Array,
		/// `T[N]`: a fixed array (Size is a number or a const generic parameter).
		FixedArray,
		/// `T?`
		Nullable,
		/// `T*`
		Pointer,
		/// `(A,B)`
		Tuple,
		/// `function:R(A,B)`: a raw function pointer.
		Function,
		/// `delegate:R(A,B)`: a delegate object.
		Delegate,
		/// `float4`, `int32x4`, `bool4`: a vector primitive (SIMD-and-Vectors.md 1.1). Name is the short
		/// spelling, Element the lane type (a Named primitive), Size the lane count. `Vector<float,4>` (the
		/// reserved generic form) reads as the same type and is written short.
		Vector,
		/// Text the type syntax does not cover; kept verbatim so it survives a round trip.
		Raw
	}

	/// A structured type reference (Graph-Format.md 2, "Type syntax"). Pins, members, parameters
	/// and node subjects hold these, never type text; `ToString` gives the format's spelling and
	/// `Parse` reads it. Names are not resolved here: `Name` is what the file says, resolution
	/// through `uses` and namespaces is the compiler's.
	class TypeRef
	{
		public TypeRefKind Kind;
		/// Named: the (dotted) name without generic arguments. Raw: the verbatim text.
		public String Name = new .() ~ delete _;
		/// Named: generic arguments. Tuple: elements. Function / Delegate: parameter types.
		public List<TypeRef> Args ~ DeleteContainerAndItems!(_);
		/// Array / FixedArray / Nullable / Pointer: the element. Function / Delegate: the return type.
		public TypeRef Element ~ delete _;
		/// FixedArray: the length token (`4`, `N`). Vector: the lane count.
		public String Size ~ delete _;
		/// Vector: read as `Vector<T,N>` (only for the reader's round-trip check: it is written short).
		bool mLongForm;

		public this()
		{
		}

		public this(TypeRefKind kind, StringView name = "")
		{
			Kind = kind;
			Name.Set(name);
		}

		public static TypeRef Named(StringView name) => new TypeRef(.Named, name);

		/// The vector type `element` x `lanes` (`float`, 4: `float4`); null when there is no such type.
		public static TypeRef Vector(StringView element, int lanes)
		{
			if (!VectorTypes.Exists(element, lanes))
				return null;
			let t = new TypeRef(.Vector);
			VectorTypes.Spell(element, lanes, t.Name);
			t.Element = Named(element);
			t.Size = new String()..AppendF("{}", lanes);
			return t;
		}

		public bool IsVector => Kind == .Vector;

		/// Vector: the lane count (0 for any other kind).
		public int32 Lanes
		{
			get
			{
				if (Kind == .Vector && Size != null && (int32.Parse(Size) case .Ok(let n)))
					return n;
				return 0;
			}
		}

		public bool IsNone => Kind == .None;
		public bool IsVoid => Kind == .None || (Kind == .Named && Name == "void" && (Args == null || Args.IsEmpty));

		public static readonly String[] Primitives = new .("bool", "int8", "int16", "int32", "int64", "int", "uint8", "uint16",
			"uint32", "uint64", "uint", "float", "double", "char8", "char32", "void", "usize", "isize") ~ delete _;

		/// A primitive type of the language (Language.md 2.1).
		public bool IsPrimitive
		{
			get
			{
				if (Kind != .Named || (Args != null && !Args.IsEmpty))
					return false;
				for (let p in Primitives)
					if (Name == p)
						return true;
				return false;
			}
		}

		/// The last segment of a named type (`Player` for `Game.Player`).
		public StringView ShortName
		{
			get
			{
				StringView n = Name;
				let dot = n.LastIndexOf('.');
				return (dot >= 0) ? n.Substring(dot + 1) : n;
			}
		}

		public void AddArg(TypeRef arg)
		{
			if (Args == null)
				Args = new .();
			Args.Add(arg);
		}

		public TypeRef Clone()
		{
			TypeRef t = new .(Kind, Name);
			if (Args != null)
			{
				t.Args = new .();
				for (let a in Args)
					t.Args.Add(a.Clone());
			}
			if (Element != null)
				t.Element = Element.Clone();
			if (Size != null)
				t.Size = new String(Size);
			return t;
		}

		public static TypeRef CloneOrNull(TypeRef t) => (t != null) ? t.Clone() : null;

		public bool Equals(TypeRef other)
		{
			if (other == null || Kind != other.Kind || Name != other.Name)
				return false;
			if ((Element == null) != (other.Element == null) || (Element != null && !Element.Equals(other.Element)))
				return false;
			if ((Size == null) != (other.Size == null) || (Size != null && Size != other.Size))
				return false;
			int na = (Args != null) ? Args.Count : 0;
			int nb = (other.Args != null) ? other.Args.Count : 0;
			if (na != nb)
				return false;
			for (int i < na)
				if (!Args[i].Equals(other.Args[i]))
					return false;
			return true;
		}

		public static bool Same(TypeRef a, TypeRef b) => (a == null) ? (b == null || b.IsNone) : (b == null ? a.IsNone : a.Equals(b));

		/// The format's spelling (Graph-Format.md 2): no spaces, `,` between arguments.
		public override void ToString(String outText) => Print(outText, false);

		/// `asRead`: a vector read as `Vector<T,N>` prints that way (the reader's lossless check only).
		void Print(String outText, bool asRead)
		{
			switch (Kind)
			{
			case .None:
			case .Raw: outText.Append(Name);
			case .Vector:
				if (asRead && mLongForm)
					outText.AppendF("Vector<{},{}>", Element.Name, Size);
				else
					outText.Append(Name);
			case .Named:
				outText.Append(Name);
				if (Args != null && !Args.IsEmpty)
				{
					outText.Append('<');
					AppendList(outText, asRead);
					outText.Append('>');
				}
			case .Array:
				Element.Print(outText, asRead);
				outText.Append("[]");
			case .FixedArray:
				Element.Print(outText, asRead);
				outText.AppendF("[{}]", Size);
			case .Nullable:
				Element.Print(outText, asRead);
				outText.Append('?');
			case .Pointer:
				Element.Print(outText, asRead);
				outText.Append('*');
			case .Tuple:
				outText.Append('(');
				AppendList(outText, asRead);
				outText.Append(')');
			case .Function, .Delegate:
				outText.Append((Kind == .Function) ? "function:" : "delegate:");
				AppendSignature(outText, asRead);
			}
		}

		/// `R(A,B)` of a Function / Delegate (what a delegate type's `signature` property holds).
		public void AppendSignature(String outText) => AppendSignature(outText, false);

		void AppendSignature(String outText, bool asRead)
		{
			if (Element != null)
				Element.Print(outText, asRead);
			else
				outText.Append("void");
			outText.Append('(');
			AppendList(outText, asRead);
			outText.Append(')');
		}

		void AppendList(String outText, bool asRead)
		{
			if (Args == null)
				return;
			for (let a in Args)
			{
				if (@a.Index > 0)
					outText.Append(',');
				a.Print(outText, asRead);
			}
		}

		// ------------------------------------------------------------------ parse

		/// Reads a type token. Text the syntax does not cover becomes a Raw type (kept verbatim),
		/// so parsing never fails; an empty token is None.
		public static TypeRef Parse(StringView text)
		{
			if (text.IsEmpty)
				return new TypeRef();
			int pos = 0;
			let t = ParseType(text, ref pos);
			// Anything that would not print back the same is kept verbatim (lossless); `Vector<T,N>` is
			// compared as read (it is written short).
			if (t == null || pos != text.Length || t.Print(.. scope String(), true) != text)
			{
				delete t;
				return new TypeRef(.Raw, text);
			}
			return t;
		}

		/// Reads `R(A,B)` (a delegate type's `signature`) as a Function TypeRef.
		public static TypeRef ParseSignature(StringView text, TypeRefKind kind = .Delegate)
		{
			int pos = 0;
			let t = ParseSigTail(text, ref pos, kind);
			if (t == null || pos != text.Length)
			{
				delete t;
				return new TypeRef(.Raw, text);
			}
			return t;
		}

		static bool IsNameChar(char8 c) => c.IsLetterOrDigit || c == '_';

		/// Deepest nesting of type arguments, tuples, signatures and suffixes (`?`, `*`, `[]`) one token
		/// is read into; deeper text stays Raw, so a file cannot drive the parser, ToString or the
		/// destructor (all recursive) into a stack overflow.
		public const int MaxDepth = 64;

		static TypeRef ParseType(StringView s, ref int pos, int depthIn = 0)
		{
			TypeRef t = null;
			var depth = depthIn;
			if (pos >= s.Length || depth > MaxDepth)
				return null;
			if (s[pos] == '(')
			{
				pos++;
				t = new TypeRef(.Tuple);
				if (!ParseList(s, ref pos, t, ')', depth + 1))
				{
					delete t;
					return null;
				}
			}
			else if (StringView(s, pos).StartsWith("function:") || StringView(s, pos).StartsWith("delegate:"))
			{
				let kind = (s[pos] == 'f') ? TypeRefKind.Function : TypeRefKind.Delegate;
				pos += 9;
				t = ParseSigTail(s, ref pos, kind, depth + 1);
				if (t == null)
					return null;
			}
			else
			{
				int start = pos;
				while (pos < s.Length && (IsNameChar(s[pos]) || (s[pos] == '.' && pos > start && pos + 1 < s.Length && IsNameChar(s[pos + 1]))))
					pos++;
				if (pos == start)
					return null;
				let name = StringView(s, start, pos - start);
				if ((pos >= s.Length || s[pos] != '<') && VectorTypes.TryParse(name, let element, let lanes))
					t = Vector(element, lanes);
				else
					t = Named(name);
				if (pos < s.Length && s[pos] == '<')
				{
					pos++;
					t.Args = new .();
					if (!ParseList(s, ref pos, t, '>', depth + 1))
					{
						delete t;
						return null;
					}
					// `Vector<float,4>`: the reserved long form of `float4`.
					if (t.Name == "Vector" && t.Args.Count == 2 && t.Args[0].Kind == .Named && (t.Args[0].Args == null || t.Args[0].Args.IsEmpty) &&
						t.Args[1].Kind == .Named && (int32.Parse(t.Args[1].Name) case .Ok(let n)) && VectorTypes.Exists(t.Args[0].Name, n))
					{
						let v = Vector(t.Args[0].Name, n);
						v.mLongForm = true;
						delete t;
						t = v;
					}
				}
			}
			// Suffixes, left to right: int[]? is a nullable array.
			while (pos < s.Length)
			{
				if (++depth > MaxDepth)
				{
					delete t;
					return null;
				}
				let c = s[pos];
				if (c == '?' || c == '*')
				{
					pos++;
					let w = new TypeRef((c == '?') ? .Nullable : .Pointer);
					w.Element = t;
					t = w;
				}
				else if (c == '[')
				{
					int close = pos + 1;
					while (close < s.Length && s[close] != ']')
						close++;
					if (close >= s.Length)
					{
						delete t;
						return null;
					}
					let inner = StringView(s, pos + 1, close - pos - 1);
					let w = new TypeRef(inner.IsEmpty ? .Array : .FixedArray);
					if (!inner.IsEmpty)
						w.Size = new String(inner);
					w.Element = t;
					t = w;
					pos = close + 1;
				}
				else
					break;
			}
			return t;
		}

		/// `R(A,B)` after `function:` / `delegate:`.
		static TypeRef ParseSigTail(StringView s, ref int pos, TypeRefKind kind, int depth = 0)
		{
			let ret = ParseType(s, ref pos, depth + 1);
			if (ret == null || pos >= s.Length || s[pos] != '(')
			{
				delete ret;
				return null;
			}
			pos++;
			let t = new TypeRef(kind);
			t.Element = ret;
			t.Args = new .();
			if (!ParseList(s, ref pos, t, ')', depth + 1))
			{
				delete t;
				return null;
			}
			return t;
		}

		/// Comma-separated types up to `close` (consumed). An empty list is fine.
		static bool ParseList(StringView s, ref int pos, TypeRef into, char8 close, int depth)
		{
			if (into.Args == null)
				into.Args = new .();
			if (pos < s.Length && s[pos] == close)
			{
				pos++;
				return true;
			}
			while (true)
			{
				let a = ParseType(s, ref pos, depth);
				if (a == null)
					return false;
				into.Args.Add(a);
				if (pos >= s.Length)
					return false;
				if (s[pos] == ',')
				{
					pos++;
					continue;
				}
				if (s[pos] == close)
				{
					pos++;
					return true;
				}
				return false;
			}
		}
	}

	/// What a member reference names its owner by (Graph-Format.md 2, "Member reference").
	enum MemberOwner : uint8
	{
		/// `this.Member`: the own type.
		This,
		/// `Type.Member`: a member of a named type (`C.<set>.<symbol>` for C imports).
		Type,
		/// `local:name`
		Local,
		/// `param:name`
		Param
	}

	/// A parsed member reference (`this.Die()`, `Game.Player.TakeDamage(int)`, `local:total`).
	/// Node subjects stay as the file's token; this is the structured reading of one.
	class MemberRef
	{
		public MemberOwner Owner;
		/// Owner == Type: the type.
		public TypeRef Type ~ delete _;
		public String Name = new .() ~ delete _;
		/// `(...)` was written (an overload pick); ParamTypes holds it.
		public bool HasSignature;
		public List<TypeRef> ParamTypes = new .() ~ DeleteContainerAndItems!(_);

		public bool IsCImport => Owner == .Type && Type != null && Type.Name.StartsWith("C.");

		public static MemberRef Parse(StringView text)
		{
			MemberRef m = new .();
			if (text.StartsWith("local:") || text.StartsWith("param:"))
			{
				m.Owner = text.StartsWith("local:") ? .Local : .Param;
				m.Name.Set(text.Substring(6));
				return m;
			}
			StringView head = text;
			int paren = -1;
			int depth = 0;
			for (int i < text.Length)
			{
				let c = text[i];
				if (c == '<')
					depth++;
				else if (c == '>')
					depth--;
				else if (c == '(' && depth == 0)
				{
					paren = i;
					break;
				}
			}
			if (paren >= 0 && text.EndsWith(")"))
			{
				head = text.Substring(0, paren);
				m.HasSignature = true;
				let inner = text.Substring(paren + 1, text.Length - paren - 2);
				if (!inner.IsEmpty)
				{
					let tuple = TypeRef.Parse(scope $"({inner})");
					if (tuple.Kind == .Tuple && tuple.Args != null)
					{
						m.ParamTypes.AddRange(tuple.Args);
						tuple.Args.Clear();
					}
					else
						m.ParamTypes.Add(new TypeRef(.Raw, inner));
					delete tuple;
				}
			}
			int dot = -1;
			depth = 0;
			for (int i < head.Length)
			{
				let c = head[i];
				if (c == '<')
					depth++;
				else if (c == '>')
					depth--;
				else if (c == '.' && depth == 0)
					dot = i;
			}
			if (dot < 0)
			{
				m.Owner = .This;
				m.Name.Set(head);
				return m;
			}
			let owner = head.Substring(0, dot);
			m.Name.Set(head.Substring(dot + 1));
			if (owner == "this")
				m.Owner = .This;
			else
			{
				m.Owner = .Type;
				m.Type = TypeRef.Parse(owner);
			}
			return m;
		}

		public override void ToString(String outText)
		{
			switch (Owner)
			{
			case .Local: outText.AppendF("local:{}", Name); return;
			case .Param: outText.AppendF("param:{}", Name); return;
			case .This: outText.Append("this.");
			case .Type:
				Type.ToString(outText);
				outText.Append('.');
			}
			outText.Append(Name);
			if (HasSignature)
			{
				outText.Append('(');
				for (let p in ParamTypes)
				{
					if (@p.Index > 0)
						outText.Append(',');
					p.ToString(outText);
				}
				outText.Append(')');
			}
		}
	}
}
