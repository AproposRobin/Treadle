using System;
using System.Collections;
using Treadle.Backend.IR;

namespace Treadle.Backend.Emit
{
	/// Sizes, alignments, field offsets and LLVM type text for x86-64 (`x86_64-w64-windows-gnu`,
	/// natural alignment, the same rules clang uses for C structs).
	///
	///  - class / interface / array / pointer / ref / function pointer values: `ptr`
	///  - class instance: `%"Name" = type { ptr, <fields of the bases>, <own fields> }` (flattened)
	///  - struct: `%"Name" = type { fields }` (`<{ }>` when packed)
	///  - simple enum: its tag integer; payload enum: `%"Name" = type { i32, [K x iA] }` where A is
	///    the largest payload alignment and K*A covers the largest payload; each case's payload is
	///    `%"Name.Case" = type { fields }` read through the payload area
	///  - `T?` = `{ T, i1 }`, tuples = `{ ... }`, `T[N]` = `[N x T]`, StringView = `{ ptr, i64 }`
	///  - array object: `{ ptr, i64, [0 x T] }`
	class Layout
	{
		public const int64 PtrSize = 8;

		IRProgram mProgram;

		public this(IRProgram program)
		{
			mProgram = program;
		}

		public static IRTypeDecl DeclOf(IRProgram p, IRType t)
		{
			if (t.Kind != .Named)
				return null;
			if (t.Decl == null)
				t.Decl = p.FindDecl(t.Text);
			return t.Decl;
		}

		public IRTypeDecl Decl(IRType t) => DeclOf(mProgram, t);

		static int64 AlignUp(int64 v, int64 a) => (a <= 1) ? v : (v + a - 1) / a * a;

		/// The LLVM name of a declaration's struct type.
		public static void StructName(StringView name, String outText)
		{
			outText.Append("%\"");
			outText.Append(name);
			outText.Append('"');
		}

		public int64 Size(IRType t)
		{
			Compute(t);
			return t.Size;
		}

		public int64 Align(IRType t)
		{
			Compute(t);
			return t.Align;
		}

		/// The LLVM type of a value of this type.
		public StringView LL(IRType t)
		{
			Compute(t);
			return t.LLVM;
		}

		void Set(IRType t, int64 size, int64 align, StringView ll)
		{
			t.Size = size;
			t.Align = Math.Max(align, 1);
			if (t.LLVM == null)
				t.LLVM = new .(ll);
			else
				t.LLVM.Set(ll);
		}

		/// Lays out a list of member types C-style. Returns size and alignment; fills offsets.
		public void Members(List<IRType> types, bool packed, List<int64> outOffsets, out int64 size, out int64 align)
		{
			int64 off = 0;
			align = 1;
			for (let m in types)
			{
				let a = packed ? 1 : Align(m);
				off = AlignUp(off, a);
				outOffsets?.Add(off);
				off += Size(m);
				align = Math.Max(align, a);
			}
			size = AlignUp(off, align);
		}

		void Compute(IRType t)
		{
			if (t.Size >= 0)
				return;
			switch (t.Kind)
			{
			case .Void: Set(t, 0, 1, "void");
			case .Vector: VectorLayout(t); // EmitVector.bf
			case .Bool: Set(t, 1, 1, "i1");
			case .Int, .Char8, .Char32:
				let bytes = t.Bits / 8;
				Set(t, bytes, Math.Min(bytes, 16), scope $"i{t.Bits}");
			case .Float: Set(t, t.Bits / 8, t.Bits / 8, (t.Bits == 32) ? "float" : "double");
			case .Pointer, .Ref, .Array, .FnPtr, .Delegate: Set(t, 8, 8, "ptr");
			case .StringView: Set(t, 16, 8, "{ ptr, i64 }");
			case .FixedArray:
				let e = t.Elem;
				Set(t, Size(e) * t.Count, Align(e), scope $"[{t.Count} x {Mem(e)}]");
			case .Nullable:
				List<IRType> m = scope .();
				m.Add(t.Elem);
				m.Add(mProgram.T("bool"));
				Members(m, false, null, var size, var align);
				Set(t, size, align, scope $"{{ {Mem(t.Elem)}, i1 }}");
			case .Tuple:
				Members(t.Items, false, null, var size, var align);
				String ll = scope .("{ ");
				for (let it in t.Items)
				{
					if (@it.Index > 0)
						ll.Append(", ");
					ll.Append(Mem(it));
				}
				ll.Append(" }");
				Set(t, size, align, ll);
			case .Named:
				let d = Decl(t);
				if (d == null)
				{
					Set(t, 8, 8, "ptr");
					return;
				}
				switch (d.Kind)
				{
				case .Class, .Interface: Set(t, 8, 8, "ptr");
				case .Struct:
					// mark first: a struct cannot contain itself, but a field may point at it
					t.Size = 0;
					DeclLayout(d, var size, var align, null);
					String ll = scope .();
					StructName(d.Name, ll);
					t.Size = -1;
					Set(t, size, align, ll);
				case .Enum:
					if (!d.IsPayloadEnum)
					{
						let tag = d.TagType ?? mProgram.T("int32");
						Set(t, Size(tag), Align(tag), LL(tag));
					}
					else
					{
						PayloadArea(d, var unit, var count);
						let align = Math.Max(4, unit);
						let size = AlignUp(AlignUp(4, unit) + unit * count, align);
						String ll = scope .();
						StructName(d.Name, ll);
						Set(t, size, align, ll);
					}
				}
			}
		}

		/// The payload area of a payload enum: `count` units of `unit` bytes.
		public void PayloadArea(IRTypeDecl d, out int64 unit, out int64 count)
		{
			int64 maxSize = 0;
			int64 maxAlign = 1;
			for (let c in d.Cases)
			{
				Members(c.Payload, false, null, var size, var align);
				maxSize = Math.Max(maxSize, size);
				maxAlign = Math.Max(maxAlign, align);
			}
			unit = Math.Min(maxAlign, 8);
			count = Math.Max(1, (maxSize + unit - 1) / unit);
		}

		/// The member types of a declaration's LLVM struct (class: vtable pointer + flattened fields).
		public void DeclMembers(IRTypeDecl d, List<IRType> outTypes)
		{
			if (d.Kind == .Class)
			{
				outTypes.Add(mProgram.T("void*"));
				ClassFields(d, outTypes, null);
			}
			else
				for (let f in d.Fields)
					outTypes.Add(f.Type);
		}

		/// The fields of a class and its bases, base first.
		public void ClassFields(IRTypeDecl d, List<IRType> outTypes, List<IRField> outFields)
		{
			if (d.Base != null)
				ClassFields(d.Base, outTypes, outFields);
			for (let f in d.Fields)
			{
				outTypes?.Add(f.Type);
				outFields?.Add(f);
			}
		}

		/// Size and alignment of a declaration's storage (a class: the instance with its header).
		public void DeclLayout(IRTypeDecl d, out int64 size, out int64 align, List<int64> outOffsets)
		{
			if (d.Kind == .Interface)
			{
				size = 8;
				align = 8;
				return;
			}
			if (d.Kind == .Enum)
			{
				size = Size(d.Type);
				align = Align(d.Type);
				return;
			}
			List<IRType> m = scope .();
			DeclMembers(d, m);
			Members(m, d.Packed, outOffsets, out size, out align);
			if (size == 0)
				size = (d.Kind == .Class) ? 8 : 1;
		}

		/// The LLVM struct index and byte offset of a field (class fields count the vtable pointer).
		public bool FieldIndex(IRTypeDecl d, StringView name, out int32 index, out int64 offset, out IRField field)
		{
			index = -1;
			offset = 0;
			field = null;
			List<IRField> fields = scope .();
			List<IRType> types = scope .();
			if (d.Kind == .Class)
			{
				types.Add(mProgram.T("void*"));
				fields.Add(null);
				ClassFields(d, types, fields);
			}
			else
				for (let f in d.Fields)
				{
					types.Add(f.Type);
					fields.Add(f);
				}
			// the most derived field of that name wins
			for (int i = fields.Count - 1; i >= 0; i--)
			{
				if (fields[i] != null && fields[i].Name == name)
				{
					List<int64> offs = scope .();
					Members(types, d.Packed, offs, ?, ?);
					index = (int32)i;
					offset = offs[i];
					field = fields[i];
					return true;
				}
			}
			return false;
		}

		/// The body of a declaration's named LLVM struct type ("{ ptr, i32 }"), "" for none.
		public void DeclBody(IRTypeDecl d, String outText)
		{
			switch (d.Kind)
			{
			case .Interface:
				return;
			case .Enum:
				if (!d.IsPayloadEnum)
					return;
				PayloadArea(d, var unit, var count);
				outText.AppendF("{{ i32, [{} x i{}] }}", count, unit * 8);
			default:
				List<IRType> m = scope .();
				DeclMembers(d, m);
				outText.Append(d.Packed ? "<{ " : "{ ");
				for (let t in m)
				{
					if (@t.Index > 0)
						outText.Append(", ");
					outText.Append(Mem(t));
				}
				outText.Append(d.Packed ? " }>" : " }");
				if (m.IsEmpty)
					outText.Set(d.Kind == .Class ? "{ ptr }" : "{ i8 }");
			}
		}

		/// The LLVM struct of one payload enum case ("{ i64, double }").
		public void CaseBody(IREnumCase c, String outText)
		{
			outText.Append("{ ");
			for (let t in c.Payload)
			{
				if (@t.Index > 0)
					outText.Append(", ");
				outText.Append(Mem(t));
			}
			outText.Append(c.Payload.IsEmpty ? "i8 }" : " }");
		}

		/// The LLVM type of an array object holding `elem`.
		public void ArrayObject(IRType elem, String outText)
		{
			outText.AppendF("{{ ptr, i64, [0 x {}] }}", Mem(elem));
		}

		/// Byte offset of the first element of an array object.
		public int64 ArrayDataOffset(IRType elem) => AlignUp(16, Align(elem));
	}
}
