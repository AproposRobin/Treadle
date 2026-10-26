using System;
using System.Collections;
using Treadle.Catalog;
using Treadle.Model;

namespace Treadle.Compiler
{
	/// The Node menu's rows of the vector functions (docs/SIMD-and-Vectors.md 1.4, 2.2): every Core.Vector
	/// call and the vector forms of Core.Math, from the compiler's table (VectorRules.Functions), category
	/// `Math | Vector`. A row's key is its call name (`Core.Vector.GetLane`), the key the editor's stand-in
	/// rows have, so these replace them; the rows that make a vector type of their own (Load, LoadPtr,
	/// Splat) are one per common vector type (`Core.Vector.Load<float4>`). Make / Break / Swizzle / Shuffle
	/// and the Splat Math Expression stay the editor's rows (they only name the type).
	static class VectorCatalogSource
	{
		public const String Category = "Math | Vector";

		public static readonly StringView[?] Common = .("float2", "float3", "float4", "float8", "double2", "double3", "double4", "int32x4", "int32x8", "uint8x16", "int16x8");

		/// Menu labels of the rows the editor names its own way.
		static StringView Label(VecFn fn)
		{
			switch (fn)
			{
			case .GetLane: return "Get Lane";
			case .WithLane: return "Set Lane";
			case .Sum: return "Reduce Add";
			case .Product: return "Reduce Multiply";
			case .MinLane: return "Reduce Min";
			case .MaxLane: return "Reduce Max";
			case .Any: return "Any Lane";
			case .All: return "All Lanes";
			default: return "";
			}
		}

		public static void Entries(List<NodeSpec> outSpecs)
		{
			for (var f in ref VectorRules.Functions)
			{
				let owners = (f.Owner == 'B') ? 2 : 1;
				for (int o < owners)
				{
					let owner = (f.Owner == 'M' || (f.Owner == 'B' && o == 1)) ? "Core.Math" : "Core.Vector";
					if (f.NeedsType)
					{
						for (let t in Common)
						{
							if (f.Fn == .Splat)
								continue; // the editor's Splat row is the Math Expression `float4(x)`
							outSpecs.Add(Row(&f, owner, t));
						}
						continue;
					}
					outSpecs.Add(Row(&f, owner, ""));
				}
			}
		}

		static NodeSpec Row(VectorRules.FnInfo* f, StringView owner, StringView typed)
		{
			NodeSpec s = new .();
			s.Kind = f.Flow ? .Call : .Pure;
			let label = Label(f.Fn);
			s.Label.Set(label.IsEmpty ? f.Name : label);
			if (!typed.IsEmpty)
				s.Label.AppendF(" {}", typed);
			s.DisplayName.Set(s.Label);
			s.Category.Set(Category);
			s.Namespace.Set("Core");
			s.CallName.AppendF("{}.{}", owner, f.Name);
			if (!typed.IsEmpty)
				s.CallName.AppendF("<{}>", typed);
			s.MemberName.Set(f.Name);
			s.OwnerType.Set(owner);
			s.IsStatic = true;
			s.IsGeneric = typed.IsEmpty;
			s.Tooltip.Set(f.Doc);
			s.Keywords.AppendF("vector simd {} {}", (owner == "Core.Math") ? "Math" : "Vector", f.Name);
			if (f.Unsafe)
				s.Keywords.Append(" unsafe pointer");
			StringView vec = typed.IsEmpty ? "T" : typed;
			String elem = scope .("E");
			if (!typed.IsEmpty && VectorTypes.TryParse(typed, let e, ?))
				elem.Set(e);
			List<(StringView name, char8 kind)> pins = scope .();
			VectorRules.Pins(f, pins);
			for (let p in pins)
			{
				PinSpec ps = new .();
				ps.Name.Set(p.name);
				ps.Label.Set(p.name);
				switch (p.kind)
				{
				case 'V', 'X': ps.Type.Set(vec);
				case 'M': ps.Type.Set("M");
				case 'E': ps.Type.Set(elem);
				case 'I': ps.Type.Set("int");
				case 'S': ps.Type.AppendF("Span<{}>", elem);
				case 'P': ps.Type.AppendF("{}*", elem);
				default:
				}
				s.Pins.Add(ps);
				if (@p.Index > 0)
					s.ParamsText.Append(", ");
				s.ParamsText.AppendF("{} {}", ps.Type, p.name);
			}
			switch (f.Result)
			{
			case 'V': s.ReturnType.Set(vec);
			case 'E': s.ReturnType.Set(elem);
			case 'B': s.ReturnType.Set("bool");
			case 'U': s.ReturnType.Set("uint");
			default:
			}
			return s;
		}
	}
}
