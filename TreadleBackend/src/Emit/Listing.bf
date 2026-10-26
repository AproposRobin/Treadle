using System;
using System.Collections;
using Treadle.Backend.IR;

namespace Treadle.Backend.Emit
{
	/// The per-unit listings (docs/Compiler.md section 7): one line per node of the unit, Sheets in
	/// member-id order, nodes by id, text `<SheetName> <nodeId> <kind> <subject>`. DWARF locations
	/// point at `<Unit>.lst:<line>`; `<Unit>.nodemap` maps `<sheetKey> <nodeId> <line>`.
	///
	/// Generic instances share their Sheet's lines (every instance of a Sheet maps a node to the same
	/// line, so a breakpoint on the node stops in all of them).
	class Listing
	{
		public class Unit
		{
			public String Name = new .() ~ delete _;
			public String Text = new .() ~ delete _;
			public String NodeMap = new .() ~ delete _;
			/// "sheetKey\x01nodeId" -> line
			public Dictionary<String, int32> Lines = new .() ~ DeleteDictionaryAndKeys!(_);
			public int32 LineCount;
		}

		public List<Unit> Units = new .() ~ DeleteContainerAndItems!(_);

		/// The unit a function's nodes are listed in (its type file), null when it has none.
		public static IRUnit OriginOf(IRFunction f) => f.Unit;

		public static void SheetKeyOf(IRFunction f, String outKey)
		{
			if (!f.SheetKey.IsEmpty)
				outKey.Append(f.SheetKey);
			else
			{
				// no Sheet key: the generic definition's reference (instances share it)
				if (f.Owner != null)
				{
					for (let s in f.Owner.Segs)
					{
						if (@s.Index > 0)
							outKey.Append('.');
						outKey.Append(s.Ident);
					}
					outKey.Append('.');
				}
				outKey.Append(f.Name);
			}
		}

		public Unit Find(StringView name)
		{
			for (let u in Units)
				if (u.Name == name)
					return u;
			return null;
		}

		/// The line of a node in a function's listing (0 when it has none).
		public int32 LineOf(IRFunction f, StringView nodeId)
		{
			if (f.Unit == null || nodeId.IsEmpty)
				return 0;
			let u = Find(f.Unit.Name);
			if (u == null)
				return 0;
			String key = scope .();
			SheetKeyOf(f, key);
			key.Append('\x01');
			key.Append(nodeId);
			if (u.Lines.TryGetValue(key, let line))
				return line;
			return 0;
		}

		/// The line of a function's Entry node (the node record of kind `Entry`), else its first line:
		/// where the function's entry code, its parameters and a Step Into stop.
		public int32 EntryLineOf(IRFunction f)
		{
			for (let n in f.Nodes)
				if (n.Kind == "Entry")
				{
					let l = LineOf(f, n.Id);
					if (l > 0)
						return l;
				}
			return FirstLineOf(f);
		}

		/// The first line of a function's Sheet (its Entry is usually the first node).
		public int32 FirstLineOf(IRFunction f)
		{
			int32 best = 0;
			if (f.Unit == null)
				return 0;
			for (let n in f.Nodes)
			{
				let l = LineOf(f, n.Id);
				if (l > 0 && (best == 0 || l < best))
					best = l;
			}
			if (best == 0)
				for (let b in f.Blocks)
					for (let op in b.Ops)
					{
						let l = LineOf(f, op.NodeId);
						if (l > 0 && (best == 0 || l < best))
							best = l;
					}
			return best;
		}

		class Row
		{
			public String Sheet = new .() ~ delete _;
			public String SheetName = new .() ~ delete _;
			public String Node = new .() ~ delete _;
			public String Kind = new .() ~ delete _;
			public String Subject = new .() ~ delete _;
		}

		public void Build(IRProgram p)
		{
			for (let unit in p.Units)
			{
				Unit u = new .();
				u.Name.Set(unit.Name);
				Units.Add(u);
				List<Row> rows = scope .();
				defer { ClearAndDeleteItems!(rows); }
				HashSet<String> seen = scope .();
				defer { for (let s in seen) delete s; }
				for (let f in p.Functions)
				{
					if (f.Unit != unit || !f.HasBody)
						continue;
					String sheet = scope .();
					SheetKeyOf(f, sheet);
					String display = scope .();
					f.GetDisplay(display);
					void Add(StringView node, StringView kind, StringView subject)
					{
						if (node.IsEmpty)
							return;
						String k = new .();
						k.AppendF("{}\x01{}", sheet, node);
						if (!seen.Add(k))
						{
							// a later definition (node record) fills the kind of an op-only row
							for (let r in rows)
								if (r.Sheet == sheet && r.Node == node && r.Kind == "node" && kind != "node")
								{
									r.Kind.Set(kind);
									r.Subject.Set(subject);
								}
							delete k;
							return;
						}
						Row r = new .();
						r.Sheet.Set(sheet);
						r.SheetName.Set(display);
						r.Node.Set(node);
						r.Kind.Set(kind);
						r.Subject.Set(subject);
						rows.Add(r);
					}
					for (let n in f.Nodes)
						Add(n.Id, n.Kind, n.Subject);
					for (let b in f.Blocks)
						for (let op in b.Ops)
							Add(op.NodeId, "node", "");
				}
				rows.Sort(scope (a, b) =>
					{
						int c = String.Compare(a.Sheet, b.Sheet, false);
						if (c != 0)
							return c;
						return String.Compare(a.Node, b.Node, false);
					});
				int32 line = 0;
				for (let r in rows)
				{
					line++;
					u.Text.AppendF("{} {} {}", r.SheetName, r.Node, r.Kind);
					if (!r.Subject.IsEmpty)
						u.Text.AppendF(" {}", r.Subject);
					u.Text.Append('\n');
					u.NodeMap.AppendF("{} {} {}\n", r.Sheet, r.Node, line);
					u.Lines[new String()..AppendF("{}\x01{}", r.Sheet, r.Node)] = line;
				}
				u.LineCount = line;
			}
		}
	}
}
