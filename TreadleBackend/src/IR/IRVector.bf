using System;
using System.Collections;
using Treadle.Model;

namespace Treadle.Backend.IR
{
	/// The vector primitives in the Sheet IR (docs/SIMD-and-Vectors.md 1, Compiler.md 4): the vector
	/// type kind (`float4`, `int32x4`, `bool4`: element and lane count, the names of VectorTypes) and
	/// the `vec.*` ops with their text form. The element-wise meaning of `binop`, `cmp`, `select`,
	/// `cast` and `intrinsic` carries over to vector operands unchanged; these are the rest:
	///
	///   %r = vec.make T %e0 %e1 ...         one value per lane
	///   %r = vec.splat T %s                 the scalar in every lane
	///   %r = vec.get E %v <lane>|%i         a lane (a variable index is checked by `lanecheck` first)
	///   %r = vec.set T %v <lane>|%i %s      the vector with one lane replaced
	///   %r = vec.shuffle T %a poison|%b m0 m1 ...   lanes picked from one vector or two (0..N-1 a, N..2N-1 b)
	///   %r = vec.reduce E add|mul|min|max|and|or|xor %v   float add / mul: a fixed pairwise tree
	///   %r = vec.any bool %m, vec.all bool %m, vec.bitmask uint %m   lane masks
	///   %r = vec.bitcast T %v               the same bits as another vector of the same size
	///   %r = vec.load T %p <align>          N lanes from an element pointer (E*)
	///   vec.store %p %v <align>
	///   vec.spancheck %index %length <N>    Debug: index .. index + N - 1 inside the span (rt_span_range)
	///   lanecheck %i <N>                    Debug: 0 <= i < N (rt_bounds); nothing in Release
	static class IRVector
	{
		/// Fills `t` when `name` is a vector spelling (its element interned in `p`).
		public static bool ParseVectorType(IRProgram p, StringView name, IRType t)
		{
			if (!VectorTypes.TryParse(name, let elem, let lanes))
				return false;
			t.Kind = .Vector;
			t.Count = lanes;
			t.Elem = p.T(elem);
			VectorTypes.Spell(elem, lanes, t.Text);
			return true;
		}

		/// The vector type of `lanes` lanes of `elem` (interned).
		public static IRType VectorOf(IRProgram p, IRType elem, int lanes)
		{
			String name = scope .();
			StringView e = elem.Text;
			if (elem.Kind == .Int && elem.Bits == 64)
				e = elem.Signed ? "int64" : "uint64";
			VectorTypes.Spell(e, lanes, name);
			return p.T(name);
		}

		/// The mask type of a vector (`bool4` for `float4`).
		public static IRType MaskOf(IRProgram p, IRType v) => VectorOf(p, p.T("bool"), (int)v.Count);

		public static bool IsMnemonic(StringView m) => m.StartsWith("vec.") || m == "lanecheck";

		public static bool IsWhat(StringView what)
		{
			switch (what)
			{
			case "make", "splat", "get", "set", "shuffle", "reduce", "any", "all", "bitmask", "bitcast", "load", "store", "spancheck":
				return true;
			default:
				return false;
			}
		}

		/// The text of a vec op or lanecheck after the result name.
		public static void WriteOp(IROp op, String outText)
		{
			void V(int i)
			{
				if (i < op.Args.Count)
					outText.AppendF(" %{}", op.Args[i].Name);
			}
			if (op.Kind == .LaneCheck)
			{
				outText.Append("lanecheck");
				V(0);
				outText.AppendF(" {}", op.Index);
			}
			else
			{
				outText.AppendF("vec.{}", op.Sub);
				if (op.Type != null && op.Sub != "store" && op.Sub != "spancheck")
					outText.AppendF(" {}", op.Type.Text);
				switch (op.Sub)
				{
				case "get":
					V(0);
					if (op.Args.Count == 2)
						V(1);
					else
						outText.AppendF(" {}", op.Index);
				case "set":
					V(0);
					if (op.Args.Count == 3)
					{
						V(1);
						V(2);
					}
					else
					{
						outText.AppendF(" {}", op.Index);
						V(1);
					}
				case "shuffle":
					V(0);
					if (op.Args.Count == 2)
						V(1);
					else
						outText.Append(" poison");
					outText.AppendF(" {}", op.Lit);
				case "reduce":
					outText.AppendF(" {}", op.Lit);
					V(0);
				case "load":
					V(0);
					outText.AppendF(" {}", op.Index);
				case "store", "spancheck":
					V(0);
					V(1);
					outText.AppendF(" {}", op.Index);
				default:
					for (int i < op.Args.Count)
						V(i);
				}
			}
			if (!op.NodeId.IsEmpty)
			{
				outText.AppendF(" @{}", op.NodeId);
				if (!op.Pin.IsEmpty)
					outText.AppendF(".{}", op.Pin);
			}
		}

		/// The lane mask of a shuffle (`op.Lit`, numbers separated by spaces).
		public static void Mask(IROp op, List<int> outMask)
		{
			for (var tok in op.Lit.Split(' '))
				if (!tok.IsEmpty)
					outMask.Add((int.Parse(tok) case .Ok(let x)) ? x : -1);
		}

		static bool IsIntLane(IRType e) => e.Kind == .Int;

		/// The operand shapes the linker checks.
		public static void CheckOp(IROp op, delegate void(StringView) err)
		{
			IRType A(int i) => (i < op.Args.Count) ? op.Args[i].Type : null;
			if (op.Kind == .LaneCheck)
			{
				if (op.Args.Count != 1 || !A(0).IsInteger)
					err("lanecheck takes one integer lane index");
				if (op.Index < 1 || op.Index > 64)
					err("lanecheck needs the lane count (1..64)");
				return;
			}
			if (!IsWhat(op.Sub))
			{
				err(scope $"unknown vector op 'vec.{op.Sub}'");
				return;
			}
			let t = op.Type;
			switch (op.Sub)
			{
			case "make":
				if (t == null || !t.IsVector)
					err("vec.make needs a vector type");
				else if (op.Args.Count != t.Count)
					err(scope $"vec.make {t.Text} takes {t.Count} values, has {op.Args.Count}");
				else
					for (let a in op.Args)
						if (a.Type != t.Elem)
							err(scope $"vec.make {t.Text}: lane {@a.Index} is a {a.Type.Text}, not a {t.Elem.Text}");
			case "splat":
				if (t == null || !t.IsVector || op.Args.Count != 1 || A(0) != t.Elem)
					err("vec.splat T takes one value of T's element type");
			case "get":
				if (op.Args.IsEmpty || !A(0).IsVector || A(0).Elem != t)
					err("vec.get E takes a vector of E and a lane");
				else if (op.Args.Count == 2 && !A(1).IsInteger)
					err("vec.get: a variable lane index is an integer");
				else if (op.Args.Count == 1 && (op.Index < 0 || op.Index >= A(0).Count))
					err(scope $"vec.get: lane {op.Index} is outside {A(0).Text}");
			case "set":
				if (op.Args.Count < 2 || A(0) != t || !t.IsVector || A(op.Args.Count - 1) != t.Elem)
					err("vec.set T takes a T, a lane and a value of T's element type");
				else if (op.Args.Count == 3 && !A(1).IsInteger)
					err("vec.set: a variable lane index is an integer");
				else if (op.Args.Count == 2 && (op.Index < 0 || op.Index >= t.Count))
					err(scope $"vec.set: lane {op.Index} is outside {t.Text}");
			case "shuffle":
				if (t == null || !t.IsVector || op.Args.IsEmpty || !A(0).IsVector || A(0).Elem != t.Elem || (op.Args.Count == 2 && A(1) != A(0)))
					err("vec.shuffle T takes one or two vectors of T's element type");
				else
				{
					List<int> m = scope .();
					Mask(op, m);
					let limit = A(0).Count * op.Args.Count;
					if (m.Count != t.Count)
						err(scope $"vec.shuffle {t.Text} needs {t.Count} lane numbers, has {m.Count}");
					for (let i in m)
						if (i < 0 || i >= limit)
							err(scope $"vec.shuffle: lane {i} is outside 0..{limit - 1}");
				}
			case "reduce":
				if (op.Args.Count != 1 || !A(0).IsVector || A(0).Elem != t)
					err("vec.reduce E takes a vector of E");
				else
				{
					switch (op.Lit)
					{
					case "add", "mul", "min", "max":
						if (t.Kind == .Bool)
							err("vec.reduce: a mask has and, or, xor (vec.any, vec.all)");
					case "and", "or", "xor":
						if (!IsIntLane(t) && t.Kind != .Bool)
							err(scope $"vec.reduce {op.Lit} takes integer lanes");
					default:
						err(scope $"unknown reduction '{op.Lit}'");
					}
				}
			case "any", "all", "bitmask":
				if (op.Args.Count != 1 || !A(0).IsVector || A(0).Elem.Kind != .Bool)
					err(scope $"vec.{op.Sub} takes a mask (boolN)");
				else if (op.Sub == "bitmask" ? (t == null || !t.IsInteger) : (t == null || t.Kind != .Bool))
					err(scope $"vec.{op.Sub} is typed {(op.Sub == "bitmask") ? "uint" : "bool"}");
			case "bitcast":
				if (op.Args.Count != 1 || t == null || !t.IsVector || !A(0).IsVector || t.Elem.Kind == .Bool || A(0).Elem.Kind == .Bool)
					err("vec.bitcast takes a vector (not a mask) to another");
				else if (BitsOf(t) != BitsOf(A(0)))
					err(scope $"vec.bitcast: {A(0).Text} and {t.Text} differ in size");
			case "load":
				if (t == null || !t.IsVector || op.Args.Count != 1 || (A(0).Kind != .Pointer && A(0).Kind != .Ref))
					err("vec.load T takes a pointer and the alignment");
			case "store":
				if (op.Args.Count != 2 || (A(0).Kind != .Pointer && A(0).Kind != .Ref) || !A(1).IsVector)
					err("vec.store takes a pointer, a vector and the alignment");
			case "spancheck":
				if (op.Args.Count != 2 || !A(0).IsInteger || !A(1).IsInteger || op.Index < 1)
					err("vec.spancheck takes the index, the span's length and the lane count");
			}
		}

		/// Lanes x element bits (a 3-lane vector counts its 3 lanes).
		public static int64 BitsOf(IRType v)
		{
			let e = v.Elem;
			int64 bits = (e.Kind == .Bool) ? 1 : e.Bits;
			return bits * v.Count;
		}
	}

	extension IRReader
	{
		/// `vec.<what> ...` and `lanecheck` (IRVector's text form).
		void ReadVectorOp(IROp op, List<StringView> tokens, int iIn, StringView mnemonic, StringView resultName)
		{
			var i = iIn;
			if (mnemonic == "lanecheck")
			{
				op.Kind = .LaneCheck;
				if (i + 2 != tokens.Count)
				{
					Error("lanecheck takes %index <lanes>");
					return;
				}
			}
			else
			{
				op.Kind = .Vec;
				op.Sub.Set(mnemonic.Substring(4));
				if (!IRVector.IsWhat(op.Sub))
				{
					Error(scope $"unknown op '{mnemonic}'");
					return;
				}
				if (op.Sub != "store" && op.Sub != "spancheck")
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
			else if (op.Type != null)
			{
				Error(scope $"'{mnemonic}' makes a value: name it (%x = {mnemonic} ...)");
				return;
			}
			void Value(StringView tok)
			{
				if (op.ArgNames == null)
					op.ArgNames = new .();
				op.ArgNames.Add(new .(tok.Substring(1)));
			}
			bool Number(StringView tok, out int64 v)
			{
				v = 0;
				if (int64.Parse(tok) case .Ok(let pv))
				{
					v = pv;
					return true;
				}
				Error(scope $"'{tok}' is not a number");
				return false;
			}
			if (op.Kind == .LaneCheck)
			{
				if (!tokens[i].StartsWith('%'))
				{
					Error("lanecheck takes %index <lanes>");
					return;
				}
				Value(tokens[i]);
				Number(tokens[i + 1], out op.Index);
				return;
			}
			switch (op.Sub)
			{
			case "get", "set":
				// a constant lane is a number, a variable one a value
				for (int k = i; k < tokens.Count; k++)
				{
					if (tokens[k].StartsWith('%'))
						Value(tokens[k]);
					else
						Number(tokens[k], out op.Index);
				}
			case "shuffle":
				if (tokens.Count - i < 3)
				{
					Error("vec.shuffle takes %a, %b or poison, and the lane numbers");
					return;
				}
				Value(tokens[i]);
				if (tokens[i + 1] != "poison")
					Value(tokens[i + 1]);
				for (int k = i + 2; k < tokens.Count; k++)
				{
					if (k > i + 2)
						op.Lit.Append(' ');
					op.Lit.Append(tokens[k]);
				}
			case "reduce":
				if (tokens.Count - i != 2)
				{
					Error("vec.reduce takes the operation and %v");
					return;
				}
				op.Lit.Set(tokens[i]);
				Value(tokens[i + 1]);
			case "load", "store", "spancheck":
				for (int k = i; k < tokens.Count; k++)
				{
					if (tokens[k].StartsWith('%'))
						Value(tokens[k]);
					else
						Number(tokens[k], out op.Index);
				}
			default:
				for (int k = i; k < tokens.Count; k++)
				{
					if (!tokens[k].StartsWith('%'))
					{
						Error(scope $"expected a value (%name), found '{tokens[k]}'");
						return;
					}
					Value(tokens[k]);
				}
			}
		}
	}
}
