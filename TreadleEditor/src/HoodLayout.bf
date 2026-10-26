using System;
using System.Collections;
using Treadle.Backend.IR;
using Treadle.Backend.Emit;
using Treadle.Compiler;

namespace Treadle.Editor
{
	/// What a row of a type's layout is (the Layout section of Type Settings, the Memory panel).
	enum LayoutRowKind
	{
		/// A field (or the value itself for a basic type, a tuple item, an element).
		Field,
		/// Bytes nothing uses (alignment); shown muted.
		Padding,
		/// The object header of a class: the pointer to its vtable.
		VTable,
		/// A payload enum's case number (or a simple enum's value).
		Tag,
		/// A payload enum's payload area (its cases' fields follow, one level deeper).
		Payload
	}

	class LayoutRow
	{
		public LayoutRowKind Kind;
		/// `mLegs`; nested fields of a struct field in the leaves read `mPos.X`.
		public String Name = new .() ~ delete _;
		/// The type in the Sheet IR's spelling (`int`, `Zoo.Point`, `char8*`).
		public String Type = new .() ~ delete _;
		/// A class field declared by a base class: that class (`Zoo.Animal`).
		public String From = new .() ~ delete _;
		/// Payload rows: the case.
		public String Case = new .() ~ delete _;
		public int64 Offset;
		public int64 Size;
		public int64 Align;
		/// 0 top level, 1 a payload case's field.
		public int32 Depth;
		// How the Memory panel decodes the bytes (leaves only).
		public IRTypeKind TypeKind;
		public int32 Bits;
		public bool Signed;
		/// A reference or pointer: the Memory panel can follow it.
		public bool Pointer;
		/// The referenced type when it has a layout (a class field, `Zoo.Point*`): what Follow shows.
		public String Target = new .() ~ delete _;
	}

	/// A type's memory layout as the back end lays it out (Treadle.Backend.Emit.Layout over the type
	/// records LayoutRecords writes): offset, size and alignment of every field, the padding between them,
	/// a class's vtable pointer, a payload enum's tag and payload area. Needs no build.
	class TypeLayout
	{
		/// The type as asked for (`Zoo.Box<int>`).
		public String Name = new .() ~ delete _;
		public bool Ok;
		/// Why there is no layout (`Ok` false).
		public String Why = new .() ~ delete _;
		public int64 Size;
		public int64 Align;
		public bool IsClass;
		public bool IsStruct;
		public bool IsEnum;
		public bool IsPayloadEnum;
		public bool Packed;
		/// Class: the slots of its vtable (the base's first).
		public int32 VSlots;
		/// Rows in offset order, padding rows included.
		public List<LayoutRow> Rows = new .() ~ DeleteContainerAndItems!(_);
		/// The fields down to basic values (struct fields expanded, `mPos.X`), for decoding bytes.
		public List<LayoutRow> Leaves = new .() ~ DeleteContainerAndItems!(_);
		/// Simple enums met in the leaves: case names by value, per enum type.
		public Dictionary<String, List<(String name, int64 value)>> Cases = new .() ~ {
			for (let kv in _) { delete kv.key; for (let c in kv.value) delete c.name; delete kv.value; } delete _; };

		/// The case of a simple enum value, or "".
		public StringView CaseName(StringView enumType, int64 value)
		{
			if (Cases.TryGetValueAlt(enumType, let list))
				for (let c in list)
					if (c.value == value)
						return c.name;
			return "";
		}
	}

	static class TypeLayouts
	{
		/// Lays out `typeName` with the front end's current compilation. Cached per declaration generation.
		public static TypeLayout Get(FrontEndServices fe, StringView typeName)
		{
			if (fe == null)
				return null;
			let gen = fe.DeclGeneration;
			if (gen != sGeneration)
			{
				for (let kv in sCache)
				{
					delete kv.key;
					delete kv.value;
				}
				sCache.Clear();
				sGeneration = gen;
			}
			if (sCache.TryGetValueAlt(typeName, let found))
				return found;
			TypeLayout l = new .();
			l.Name.Set(typeName);
			Compute(fe, typeName, l);
			sCache[new String(typeName)] = l;
			return l;
		}

		static Dictionary<String, TypeLayout> sCache = new .() ~ { for (let kv in _) { delete kv.key; delete kv.value; } delete _; };
		static int32 sGeneration = -1;

		public static void Compute(FrontEndServices fe, StringView typeName, TypeLayout outLayout)
		{
			let comp = fe.Current;
			let kt = fe.Types.Lookup(typeName);
			if (comp == null || kt == null)
			{
				// a generic definition named without its arguments
				if (comp != null)
					for (let s in comp.Table.Types)
						if (s.IsGeneric && s.FullName == typeName)
						{
							outLayout.Why.AppendF("{} is generic: each instantiation has its own layout. Type one ({}<int>) in Instantiation.", typeName, typeName);
							return;
						}
				outLayout.Why.AppendF("{} is not a type the compiler knows (fix the problems Validate lists first)", typeName);
				return;
			}
			String text = scope .();
			String root = scope .();
			if (!LayoutRecords.Write(comp, kt, text, root, outLayout.Why))
				return;
			if (kt.Kind == .Named && kt.Sym.Kind == .Class)
				outLayout.VSlots = (int32)kt.Sym.VTable.Count;
			FromRecords(text, root, outLayout);
		}

		/// The layout of `root` from the Sheet IR type records in `text` (also what the `hood` self test
		/// feeds directly).
		public static void FromRecords(StringView text, StringView root, TypeLayout l)
		{
			IRProgram prog = scope .();
			List<String> errors = scope .();
			defer { ClearAndDeleteItems!(errors); }
			if (!IRReader.Read(text, prog, errors))
			{
				l.Why.Append("the type records do not read: ");
				l.Why.Append(errors.IsEmpty ? "?" : errors[0]);
				return;
			}
			IRType t;
			if (prog.Type(root) case .Ok(let rt))
				t = rt;
			else
			{
				l.Why.AppendF("{} does not parse as a type", root);
				return;
			}
			Layout L = scope .(prog);
			let d = Layout.DeclOf(prog, t);
			List<LayoutRow> rows = scope .();
			if (d != null && d.Kind == .Class)
			{
				l.IsClass = true;
				L.DeclLayout(d, var size, var align, null);
				l.Size = size;
				l.Align = align;
				List<IRType> types = scope .();
				List<IRField> fields = scope .();
				types.Add(prog.T("void*"));
				fields.Add(null);
				L.ClassFields(d, types, fields);
				List<int64> offs = scope .();
				L.Members(types, d.Packed, offs, ?, ?);
				for (int i < types.Count)
				{
					LayoutRow r = new .();
					if (i == 0)
					{
						r.Kind = .VTable;
						r.Name.Set("vtable");
						r.Type.Set("void*");
						r.TypeKind = .Pointer;
						r.Pointer = true;
					}
					else
					{
						r.Kind = .Field;
						r.Name.Set(fields[i].Name);
						Describe(L, types[i], r);
						let owner = Owner(d, fields[i]);
						if (owner != null && owner != d)
							r.From.Set(owner.Name);
					}
					r.Offset = offs[i];
					r.Size = L.Size(types[i]);
					r.Align = d.Packed ? 1 : L.Align(types[i]);
					rows.Add(r);
				}
			}
			else if (d != null && d.Kind == .Interface)
			{
				l.Why.AppendF("{} is an interface: a value of it is a reference (8 bytes) to an object of a class that implements it", root);
				return;
			}
			else if (d != null && d.Kind == .Enum && d.IsPayloadEnum)
			{
				l.IsEnum = true;
				l.IsPayloadEnum = true;
				l.Size = L.Size(t);
				l.Align = L.Align(t);
				L.PayloadArea(d, var unit, var count);
				let start = (4 + unit - 1) / unit * unit;
				LayoutRow tag = new .();
				tag.Kind = .Tag;
				tag.Name.Set("tag");
				tag.Type.Set("int32");
				tag.TypeKind = .Int;
				tag.Bits = 32;
				tag.Signed = true;
				tag.Size = 4;
				tag.Align = 4;
				rows.Add(tag);
				LayoutRow pay = new .();
				pay.Kind = .Payload;
				pay.Name.Set("payload");
				pay.Type.AppendF("{} x {} bytes", count, unit);
				pay.Offset = start;
				pay.Size = unit * count;
				pay.Align = unit;
				rows.Add(pay);
				for (let c in d.Cases)
				{
					if (c.Payload.IsEmpty)
						continue;
					List<int64> offs = scope .();
					L.Members(c.Payload, false, offs, ?, ?);
					for (int i < c.Payload.Count)
					{
						LayoutRow r = new .();
						r.Kind = .Field;
						r.Depth = 1;
						r.Case.Set(c.Name);
						if (c.Payload.Count == 1)
							r.Name.Set(c.Name);
						else
							r.Name.AppendF("{}.item{}", c.Name, i);
						Describe(L, c.Payload[i], r);
						r.Offset = start + offs[i];
						r.Size = L.Size(c.Payload[i]);
						r.Align = L.Align(c.Payload[i]);
						rows.Add(r);
					}
				}
			}
			else
			{
				l.Size = L.Size(t);
				l.Align = L.Align(t);
				List<IRType> types = scope .();
				List<StringView> names = scope .();
				List<String> owned = scope .();
				defer { ClearAndDeleteItems!(owned); }
				bool packed = false;
				if (d != null && d.Kind == .Struct)
				{
					l.IsStruct = true;
					packed = d.Packed;
					for (let f in d.Fields)
					{
						types.Add(f.Type);
						names.Add(f.Name);
					}
				}
				else if (d != null && d.Kind == .Enum)
				{
					l.IsEnum = true;
					types.Add(t);
					names.Add("value");
				}
				else
					Parts(prog, t, types, names, owned);
				l.Packed = packed;
				List<int64> offs = scope .();
				L.Members(types, packed, offs, ?, ?);
				for (int i < types.Count)
				{
					LayoutRow r = new .();
					r.Kind = (d != null && d.Kind == .Enum) ? .Tag : .Field;
					r.Name.Set(names[i]);
					Describe(L, types[i], r);
					r.Offset = offs[i];
					r.Size = L.Size(types[i]);
					r.Align = packed ? 1 : L.Align(types[i]);
					rows.Add(r);
				}
			}
			l.Packed = (d != null) && d.Packed;
			// Padding: the gaps between the top-level rows and the tail up to the size.
			int64 end = 0;
			for (let r in rows)
			{
				if (r.Depth == 0)
				{
					if (r.Offset > end)
						l.Rows.Add(Padding(end, r.Offset - end));
					end = Math.Max(end, r.Offset + r.Size);
				}
				l.Rows.Add(r);
			}
			if (l.Size > end)
				l.Rows.Add(Padding(end, l.Size - end));
			// The leaves: struct fields expanded to their basic values.
			for (let r in l.Rows)
			{
				if (r.Kind == .Padding || r.Kind == .Payload)
					continue;
				AddLeaves(prog, L, r.Name, r.Type, r.Offset, r.Case, l, 0, (r.Kind == .VTable) ? .VTable : .Field);
			}
			l.Ok = true;
		}

		static IRTypeDecl Owner(IRTypeDecl d, IRField f)
		{
			var c = d;
			while (c != null)
			{
				if (c.Fields.Contains(f))
					return c;
				c = c.Base;
			}
			return null;
		}

		static LayoutRow Padding(int64 offset, int64 size)
		{
			LayoutRow p = new .();
			p.Kind = .Padding;
			p.Name.Set("(padding)");
			p.Offset = offset;
			p.Size = size;
			p.Align = 1;
			return p;
		}

		/// The parts of a type that is not a declaration: a tuple's items, a nullable's value and flag, a
		/// StringView's pointer and length, a fixed array's elements (at most 64), or the value itself.
		static void Parts(IRProgram prog, IRType t, List<IRType> outTypes, List<StringView> outNames, List<String> owned)
		{
			switch (t.Kind)
			{
			case .Tuple:
				for (let it in t.Items)
				{
					outTypes.Add(it);
					outNames.Add(owned.Add(.. new $"item{@it.Index}"));
				}
			case .Nullable:
				outTypes.Add(t.Elem);
				outNames.Add("value");
				outTypes.Add(prog.T("bool"));
				outNames.Add("hasValue");
			case .StringView:
				outTypes.Add(prog.T("char8*"));
				outNames.Add("Ptr");
				outTypes.Add(prog.T("int"));
				outNames.Add("Length");
			case .FixedArray:
				for (int i < Math.Min(t.Count, 64))
				{
					outTypes.Add(t.Elem);
					outNames.Add(owned.Add(.. new $"[{i}]"));
				}
			default:
				outTypes.Add(t);
				outNames.Add("value");
			}
		}

		static void Describe(Layout L, IRType t, LayoutRow r)
		{
			L.Decl(t); // a type interned after the link finds its declaration here
			r.Type.Set(t.Text);
			r.TypeKind = t.Kind;
			r.Bits = t.Bits;
			r.Signed = t.Signed;
			r.Pointer = t.IsPointerLike;
			if (t.Kind == .Pointer || t.Kind == .Ref)
			{
				if (t.Elem != null && !t.Elem.IsVoid)
					r.Target.Set(t.Elem.Text);
			}
			else if (t.Kind == .Named && t.Decl != null && t.Decl.Kind == .Class)
				r.Target.Set(t.Text);
		}

		static void AddLeaves(IRProgram prog, Layout L, StringView name, StringView typeText, int64 offset, StringView caseName, TypeLayout l, int depth, LayoutRowKind kind = .Field)
		{
			IRType t = null;
			if (prog.Type(typeText) case .Ok(let rt))
				t = rt;
			let d = (t != null) ? Layout.DeclOf(prog, t) : null;
			bool expand = depth < 4 && t != null && ((d != null && d.Kind == .Struct) || t.Kind == .Tuple || t.Kind == .Nullable || t.Kind == .StringView || (t.Kind == .FixedArray && t.Count <= 16) || (d != null && d.Kind == .Enum && d.IsPayloadEnum));
			if (!expand)
			{
				LayoutRow r = new .();
				r.Kind = kind;
				r.Name.Set(name);
				r.Case.Set(caseName);
				r.Offset = offset;
				if (t != null)
				{
					Describe(L, t, r);
					r.Size = L.Size(t);
					r.Align = L.Align(t);
					if (d != null && d.Kind == .Enum && !d.IsPayloadEnum && !l.Cases.ContainsKeyAlt(t.Text))
					{
						List<(String name, int64 value)> cases = new .();
						for (let c in d.Cases)
							cases.Add((new String(c.Name), c.Value));
						l.Cases[new String(t.Text)] = cases;
					}
					if (d != null && d.Kind == .Enum && !d.IsPayloadEnum)
					{
						let tag = d.TagType ?? prog.T("int32");
						r.TypeKind = tag.Kind;
						r.Bits = tag.Bits;
						r.Signed = tag.Signed;
					}
				}
				else
					r.Type.Set(typeText);
				l.Leaves.Add(r);
				return;
			}
			if (d != null && d.Kind == .Enum)
			{
				// a payload enum inside a struct: its tag, then each case's fields
				L.PayloadArea(d, var unit, var count);
				let start = (4 + unit - 1) / unit * unit;
				AddLeaves(prog, L, scope $"{name}.tag", "int32", offset, caseName, l, depth + 1);
				for (let c in d.Cases)
				{
					List<int64> offs = scope .();
					L.Members(c.Payload, false, offs, ?, ?);
					for (int i < c.Payload.Count)
						AddLeaves(prog, L, (c.Payload.Count == 1) ? scope $"{name}.{c.Name}" : scope $"{name}.{c.Name}.item{i}", c.Payload[i].Text, offset + start + offs[i], c.Name, l, depth + 1);
				}
				return;
			}
			List<IRType> types = scope .();
			List<StringView> names = scope .();
			List<String> owned = scope .();
			defer { ClearAndDeleteItems!(owned); }
			bool packed = false;
			if (d != null)
			{
				packed = d.Packed;
				for (let f in d.Fields)
				{
					types.Add(f.Type);
					names.Add(f.Name);
				}
			}
			else
				Parts(prog, t, types, names, owned);
			List<int64> offs = scope .();
			L.Members(types, packed, offs, ?, ?);
			for (int i < types.Count)
			{
				String child = scope .();
				if (names[i].StartsWith('['))
					child.AppendF("{}{}", name, names[i]);
				else
					child.AppendF("{}.{}", name, names[i]);
				AddLeaves(prog, L, child, types[i].Text, offset + offs[i], caseName, l, depth + 1);
			}
		}
	}
}
