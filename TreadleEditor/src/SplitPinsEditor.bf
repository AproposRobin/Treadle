using System;
using System.Collections;
using Treadle.Catalog;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Model;

namespace Treadle.Editor
{
	/// Split Struct Pin / Recombine Struct Pin (the pin menu; SplitPins in TreadleCore): a struct pin drawn
	/// as one pin per field on the same node, kept in the file as the node's `split <pin> <Type>` line.
	/// Each is one undo step.
	extension EditorApp
	{
		/// The fields of a struct pin's type (name and type text), from the Node menu's Make / Break row
		/// of that type; a generic struct's field types take the pin's type arguments (Pair<int,float>:
		/// First int, Second float; Validate gives the exact types). False when the pin is not a struct
		/// the menu knows.
		public bool StructFields(Sheet mg, Pin pin, List<(String name, String type)> outFields)
		{
			String key = scope .();
			String label = scope .();
			if (mg == null || pin == null || !StructRowForPin(mg, pin, key, label))
				return false;
			let item = mNodeMenu.ItemForKey(mg, .(0, 0), 0, key);
			if (item == null)
				return false;
			defer delete item;
			Graph scratch = scope .();
			scratch.Language = Language;
			scratch.SelfType.Set(mg.Graph.SelfType);
			let n = mNodeMenu.CreateNode(mg, scratch, item, false, true);
			if (n == null)
				return false;
			List<StringView> names = scope .();
			List<StringView> types = scope .();
			for (let p in pin.IsInput ? n.Inputs : n.Outputs)
				if (p.Kind == .Value && p.Name != "value" && p.Name != "receiver")
				{
					names.Add(p.Name);
					types.Add(p.TypeName);
				}
			List<String> inst = scope .();
			defer { ClearAndDeleteItems!(inst); }
			SplitPins.InstanceFieldTypes(pin.TypeName, types, inst);
			for (int i < names.Count)
				outFields.Add((new String(names[i]), new String(inst[i])));
			return !outFields.IsEmpty;
		}

		/// Whether the pin menu offers Split Struct Pin for `pin` (a struct value pin, not split, not a field).
		public bool CanSplitPin(Sheet mg, Pin pin)
		{
			if (pin == null || pin.Kind != .Value || SplitPins.IsSplit(pin) || SplitPins.IsSubPin(pin) || pin.Name == "receiver")
				return false;
			String key = scope .();
			String label = scope .();
			return StructRowForPin(mg, pin, key, label);
		}

		/// Split Struct Pin: one pin per field on the node (its wires and literal go). One undo step.
		public bool SplitStructPin(Sheet mg, Pin pin)
		{
			if (mg == null || pin == null || mg.Graph.FindPin(pin.Id) != pin || !CheckWritable())
				return false;
			List<(String name, String type)> fields = scope .();
			defer { for (let f in fields) { delete f.name; delete f.type; } }
			if (!StructFields(mg, pin, fields))
			{
				SetStatus(scope $"{(pin.Label.IsEmpty ? pin.Name : pin.Label)} is not a struct whose fields are known", .Warning);
				return false;
			}
			List<(StringView name, StringView type)> spans = scope .();
			for (let f in fields)
				spans.Add((f.name, f.type));
			String typeText = scope .(pin.TypeName);
			BeginEdit();
			if (!SplitPins.Split(mg.Graph, pin, typeText, spans))
			{
				EditDoc.DropLastUndo();
				return false;
			}
			CommitCurrent();
			SetStatus(scope $"Split {(pin.Label.IsEmpty ? pin.Name : pin.Label)} into {fields.Count} field pins", .Info, false);
			return true;
		}

		/// Recombine Struct Pin (on the split pin or one of its fields): the field pins go with their wires,
		/// the struct pin is shown again. One undo step.
		public bool RecombineStructPin(Sheet mg, Pin pin)
		{
			if (mg == null || pin == null || !CheckWritable())
				return false;
			var parent = pin;
			let parentName = SplitPins.ParentOf(pin);
			if (!parentName.IsEmpty)
				parent = pin.IsInput ? pin.Owner.FindInput(parentName) : pin.Owner.FindOutput(parentName);
			if (parent == null || !SplitPins.IsSplit(parent))
				return false;
			BeginEdit();
			SplitPins.Recombine(mg.Graph, parent);
			CommitCurrent();
			return true;
		}

		/// A split pin whose fields have no pin yet (read from a file where only the wired and literal
		/// fields are written) gets the missing ones; not an edit (the file does not change).
		public void EnsureSplitSubPins(Sheet mg)
		{
			let g = mg.Graph;
			if (!SplitPins.Any(g))
				return;
			for (let n in g.Nodes)
			{
				for (int side < 2)
				{
					List<Pin> parents = scope .();
					for (let p in (side == 0) ? n.Inputs : n.Outputs)
						if (SplitPins.IsSplit(p))
							parents.Add(p);
					for (let parent in parents)
					{
						if (parent.TypeName.IsEmpty)
						{
							let s = SplitPins.Find(n, parent.Name);
							parent.SetTypeText(SplitPins.TypeOf(s));
						}
						List<(String name, String type)> fields = scope .();
						defer { for (let f in fields) { delete f.name; delete f.type; } }
						if (!StructFields(mg, parent, fields))
							continue;
						let list = (side == 0) ? n.Inputs : n.Outputs;
						int at = list.IndexOf(parent) + 1;
						for (let f in fields)
						{
							String name = scope $"{parent.Name}.{f.name}";
							var sub = (side == 0) ? n.FindInput(name) : n.FindOutput(name);
							if (sub == null)
							{
								sub = g.AddPin(n, side == 0, .Value, name, "");
								SplitPins.SubLabel(parent, f.name, sub.Label);
								sub.Role = (side == 0) ? .Arg : .Result;
								sub.Optional = side == 0;
								sub.SetTypeText(f.type);
							}
							else if (sub.TypeName.IsEmpty)
								sub.SetTypeText(f.type);
							list.Remove(sub);
							list.Insert(Math.Min(at++, list.Count), sub);
						}
					}
				}
			}
		}
	}
}
