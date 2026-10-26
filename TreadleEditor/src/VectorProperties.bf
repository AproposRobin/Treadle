using System;
using System.Collections;
using ImGui;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Model;

namespace Treadle.Editor
{
	/// Properties rows of the vector nodes (docs/SIMD-and-Vectors.md 1.9): a Swizzle's lanes (the letters as
	/// text and a lane picker, one dropdown per output lane), a Shuffle's mask (as text and one dropdown per
	/// output lane, `a.x` ... `b.w`), the vector type of a Make / Break of a vector. Each edit is one undo step;
	/// a setting the input cannot take is refused with the T2301 text.
	extension EditorApp
	{
		static StringView[4] sLaneLetters = .("x", "y", "z", "w");

		/// The rows of a Swizzle or Shuffle (`node.Kind`); true when the node was changed.
		bool DrawVectorNodeRows(Sheet mg, Node node, bool readOnly)
		{
			let g = mg.Graph;
			String input = scope .();
			VectorNodes.InputType(g, node, input);
			let lanes = VectorTypes.LanesOf(input);
			PropertyGrid.InfoRow("Input", input.IsEmpty ? "(wire a vector)" : (StringView)input, "The vector the lanes are picked from: the type wired in");
			if (node.Kind == .Swizzle)
				return DrawSwizzleRows(g, node, lanes, readOnly);
			return DrawShuffleRows(g, node, lanes, readOnly);
		}

		/// Stores a new setting of a vector node (one undo step), or refuses it.
		bool SetVectorSetting(Graph g, Node node, StringView key, StringView value, int lanes)
		{
			String why = scope .();
			bool ok = (key == VectorNodes.LanesKey) ? VectorNodes.CheckSwizzle(value, lanes, why) : VectorNodes.CheckShuffle(value, lanes, why);
			if (!ok)
			{
				Notify.Warn(why);
				return false;
			}
			if (node.GetSetting(key) == value)
				return false;
			BeginEdit();
			node.SetSetting(key, value);
			VectorNodes.Sync(g, node);
			g.Version++;
			CommitCurrent();
			return true;
		}

		bool DrawSwizzleRows(Graph g, Node node, int lanes, bool readOnly)
		{
			String cur = scope .(node.GetSetting(VectorNodes.LanesKey));
			String v = scope .();
			bool changed = false;
			if (TsText("Lanes", scope $"##vswz{node.Key}", cur, v, "1 to 4 of the letters x y z w, each a lane of the input (.zyx reverses a float3, .xxxx repeats x)", "xyz") && !readOnly)
				changed |= SetVectorSetting(g, node, VectorNodes.LanesKey, v, lanes);
			// The lane picker: one dropdown per output lane.
			let available = (lanes > 0) ? Math.Min(lanes, 4) : 4;
			List<DropItem> items = scope .();
			for (int i < 4)
				items.Add(.(sLaneLetters[i], scope:: $"Lane {i} of the input", (i < available) ? StringView() : StringView("The input has fewer lanes")));
			for (int k < cur.Length)
			{
				let at = VectorNodes.LetterIndex(cur[k]);
				let picked = PropertyGrid.DropdownRow(scope $"Lane {k + 1}", scope $"##vswzl{node.Key}{k}", (at >= 0) ? sLaneLetters[at] : "?", items, at,
					"Which lane of the input this output lane takes", default, readOnly);
				if (picked >= 0 && picked != at && !readOnly)
				{
					String next = scope .(cur);
					next[k] = "xyzw"[picked];
					changed |= SetVectorSetting(g, node, VectorNodes.LanesKey, next, lanes);
				}
			}
			if (!readOnly && cur.Length < 4 && PropertyGrid.ButtonRow("", scope $"{Icon.Plus} Add Lane", "One more output lane (the next lane of the input)"))
			{
				String next = scope .(cur);
				next.Append("xyzw"[Math.Min(cur.Length, available - 1)]);
				changed |= SetVectorSetting(g, node, VectorNodes.LanesKey, next, lanes);
			}
			if (!readOnly && cur.Length > 1 && PropertyGrid.ButtonRow("", "Remove Last Lane", "One output lane fewer (one letter gives a single lane, not a vector)"))
				changed |= SetVectorSetting(g, node, VectorNodes.LanesKey, StringView(cur, 0, cur.Length - 1), lanes);
			return changed;
		}

		bool DrawShuffleRows(Graph g, Node node, int lanes, bool readOnly)
		{
			StringView cur = node.GetSetting(VectorNodes.MaskKey);
			String v = scope .();
			bool changed = false;
			let n = (lanes > 0) ? lanes : 4;
			if (TsText("Mask", scope $"##vshm{node.Key}", cur, v, scope $"Lane numbers separated by spaces: 0 to {n - 1} take A's lanes, {n} to {2 * n - 1} B's", "0 4 1 5") && !readOnly)
				changed |= SetVectorSetting(g, node, VectorNodes.MaskKey, v, lanes);
			List<int32> mask = scope .();
			if (!VectorNodes.ParseMask(cur, mask))
				return changed;
			// One dropdown per output lane: A's lanes, then B's.
			List<String> names = scope .();
			defer { ClearAndDeleteItems!(names); }
			List<DropItem> items = scope .();
			for (int i < 2 * n)
			{
				String name = new .();
				name.Append((i < n) ? "a." : "b.");
				VectorTypes.LaneName(n, i % n, name);
				names.Add(name);
			}
			for (let s in names)
				items.Add(.(s));
			for (int k < mask.Count)
			{
				let at = mask[k];
				let picked = PropertyGrid.DropdownRow(scope $"Lane {k + 1}", scope $"##vshl{node.Key}{k}", (at < names.Count) ? (StringView)names[at] : "?", items, at,
					"Which lane of A or B this output lane takes", default, readOnly);
				if (picked >= 0 && picked != at && !readOnly)
				{
					String next = scope .();
					for (int i < mask.Count)
						next.AppendF("{}{}", (i > 0) ? " " : "", (i == k) ? picked : mask[i]);
					changed |= SetVectorSetting(g, node, VectorNodes.MaskKey, next, lanes);
				}
			}
			return changed;
		}

		/// Make / Break of a vector: its type, chosen among the vector types (the lanes follow; wires on
		/// lanes that stay are kept). True when the node was changed.
		bool DrawVectorTypeRow(Sheet mg, Node node, bool readOnly)
		{
			String e = scope .();
			if (!VectorTypes.Info(node.Text, e, let lanes))
				return false;
			List<String> all = scope .();
			defer { ClearAndDeleteItems!(all); }
			VectorTypes.All(all);
			// The shared type picker (TypePickers.bf), its rows the vector types.
			List<TypeEntry> entries = scope .();
			defer { ClearAndDeleteItems!(entries); }
			for (let t in all)
			{
				TypeEntry en = new .();
				en.Name.Set(t);
				en.Group = "Vectors";
				en.Glyph = Icon.Layers;
				entries.Add(en);
			}
			PropertyGrid.Row("Vector Type", "The vector type: one lane pin per lane (x y z w up to 4 lanes, lane0 ... above)", Theme.TypeColor(node.Text));
			Gui.igBeginDisabled(readOnly);
			String picked = scope .();
			let changed = TypeCombo.Draw(scope $"##vtype{node.Key}", node.Text, entries, picked);
			Gui.igEndDisabled();
			if (!changed || readOnly || picked.IsEmpty)
				return false;
			return SetVectorType(mg.Graph, node, picked);
		}

		/// Changes a vector Make / Break to `type` (one undo step): the subject, the `value` pin and the lane
		/// pins; lanes that stay keep their wires and literals while their type still fits.
		public bool SetVectorType(Graph g, Node node, StringView type)
		{
			String e = scope .();
			if (!VectorTypes.Info(type, e, let lanes) || (node.Kind != .Make && node.Kind != .BreakStruct))
				return false;
			BeginEdit();
			node.SetSubjectTypeText(type);
			let input = node.Kind == .Make;
			// Lanes beyond the new count go with their wires.
			let list = input ? node.Inputs : node.Outputs;
			for (int i = list.Count - 1; i >= 0; i--)
			{
				let p = list[i];
				if (p.Kind != .Value || p.Name == "value")
					continue;
				bool keep = false;
				for (int k < lanes)
					if (p.Name == VectorTypes.LaneName(lanes, k, .. scope String()))
						keep = true;
				if (!keep)
					g.RemovePin(p);
			}
			VectorNodes.AddLanePins(g, node);
			for (let p in list)
				if (p.Kind == .Value && p.Name != "value")
					p.SetTypeText(e);
			let value = input ? node.FindOutput("value") : node.FindInput("value");
			value?.SetTypeText(type);
			List<Node> follow = scope .();
			for (int i = g.Links.Count - 1; i >= 0; i--)
			{
				let l = g.Links[i];
				// A Swizzle / Shuffle input takes any vector: its type follows the wire (the front end may
				// have typed it with the old vector), so the wire stays and the node is brought in step.
				if (input && l.From == value && l.To != null && (l.To.Owner.Kind == .Swizzle || l.To.Owner.Kind == .Shuffle))
				{
					l.To.SetTypeText(type);
					follow.Add(l.To.Owner);
					continue;
				}
				if ((l.From.Owner == node || l.To.Owner == node) && !Graph.CanConnectTyped(g.Language, l.From, l.To))
					g.Disconnect(l);
			}
			for (let n in follow)
				VectorNodes.Sync(g, n);
			g.Version++;
			CommitCurrent();
			return true;
		}
	}
}
