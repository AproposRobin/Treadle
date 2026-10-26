using System;
using System.Collections;

namespace Treadle.Compiler
{
	/// The declarations a type's memory layout needs, in the Sheet IR's text form (Compiler.md 4): the
	/// `type` record of the type and of every type its fields, cases and base class use, as Lower writes
	/// them, without the function records (vslots, interface tables, destructors). The editor reads the
	/// text with the back end's IRReader and asks the back end's Layout for sizes and offsets, so the
	/// Layout section of Type Settings and the Memory panel show the numbers the build uses (docs/Debugging.md,
	/// "Under the hood"). Needs no build.
	static class LayoutRecords
	{
		/// `# tir 1`, a `program` line and the records for `t` (a project, core or C type, a generic
		/// instance). False with the reason in `outWhy` when `t` cannot be laid out (an open generic type,
		/// an unknown type). `outRoot` is `t`'s name in the text (`Zoo.Box<int>`, `int`).
		public static bool Write(Compilation c, KType t, String outText, String outRoot, String outWhy)
		{
			if (c == null || t == null || t.IsError)
			{
				outWhy.Append("the type is not known to the compiler");
				return false;
			}
			if (TypeTable.IsOpen(t))
			{
				outWhy.Append("a generic type has no layout of its own: choose an instantiation");
				return false;
			}
			ProgramLowerer p = scope .(c);
			KirWriter.Type(p.IRCanon(t), outRoot);
			p.WriteLayoutRecords(t, outText);
			return true;
		}
	}

	extension ProgramLowerer
	{
		/// The records of `root` and of everything they name (LayoutRecords.Write).
		public void WriteLayoutRecords(KType root, String o)
		{
			o.Append("# tir 1\nprogram Layout library\n");
			List<KType> queue = scope .();
			HashSet<KType> done = scope .();
			queue.Add(root);
			while (!queue.IsEmpty)
			{
				let t = IRCanon(queue.PopFront());
				if (t == null || !done.Add(t))
					continue;
				switch (t.Kind)
				{
				case .Pointer, .Array, .Nullable, .FixedArray:
					queue.Add(t.Element);
					continue;
				case .Tuple, .Function, .Delegate:
					for (let a in t.Args)
						queue.Add(a);
					if (t.Element != null)
						queue.Add(t.Element);
					continue;
				default:
				}
				if (t.Kind != .Named || TypeTable.IsOpen(t))
					continue;
				let s = t.Sym;
				for (let a in t.Args)
					queue.Add(a);
				if (s == T.ObjectSym || s == T.StringViewSym || s.FullName == "Core.Delegate")
					continue;
				String text = scope .();
				if (s.IsCRecord)
					CRecordDecl(t, text);
				else
					Decl(t, text);
				// Only what lays out: the type line, base, fields, cases and the tag type.
				for (let line in text.Split('\n'))
				{
					if (line.StartsWith("type ") || line.StartsWith("\tbase ") || line.StartsWith("\tfield ") || line.StartsWith("\tcase ") || line.StartsWith("\ttag "))
						o.AppendF("{}\n", line);
				}
				let b = T.BaseOf(t);
				if (b != null)
					queue.Add(b);
				Dictionary<GenericParamSym, KType> map = scope .();
				Map(t, map);
				for (let m in s.Members)
				{
					if (m.Kind == .Field && !m.Static && !m.Const)
						queue.Add(T.Subst(m.Type, map));
					else if (m.Kind == .Case)
						for (let pp in m.Payload)
							queue.Add(T.Subst(pp.Type, map));
				}
				if (s.Underlying != null)
					queue.Add(s.Underlying);
			}
		}
	}
}
