using System;
using System.Collections;
using ImGui;
using Treadle.Document;
using Treadle.Graph;

namespace Treadle.Editor
{
	/// The Properties rows of a Lambda node (Language.md 4.2): Delegate Type (the delegate types in
	/// scope, or a custom signature), Signature, the Inputs and the result (editable rows that write
	/// `set inputs` / `set type` and move the Sheet's Entry and Return pins), Allocation, the
	/// Captures the front end found (by value or by reference) and the button that opens the Sheet.
	extension EditorApp
	{
		static StringView[?] sLambdaAllocs = .("", "local", "construct");
		static StringView[?] sLambdaAllocNames = .("Function pointer", "Local", "Construct");
		static StringView[?] sLambdaAllocWhy = .(
			"No object: a plain function pointer (a C callback). Captures nothing; a value node.",
			"An object freed when this region ends. May capture by reference; not returned, stored or deleted.",
			"An object on the heap: you delete it (Delete or Defer Delete). Captures by value.");

		/// What the Captures rows showed last (the self test reads it).
		public String mLambdaRowsShown = new .() ~ delete _;

		static bool IsIdentifier(StringView s)
		{
			if (s.IsEmpty || s[0].IsDigit)
				return false;
			for (let c in s.RawChars)
				if (!c.IsLetterOrDigit && c != '_')
					return false;
			return true;
		}

		void DrawLambdaDetails(Sheet mg, Node node, bool readOnly)
		{
			let g = mg.Graph;
			String id = scope .(node.Key);
			LambdaSignature sig = scope .();
			StringView typeText = node.GetSetting("type");
			bool known = LambdaSignatureOf(node, sig);
			bool custom = typeText.StartsWith("delegate:") || typeText.StartsWith("function:");

			// Delegate Type: the delegate types in scope, or a signature of its own.
			List<String> names = scope .();
			defer { ClearAndDeleteItems!(names); }
			DelegateTypesInScope(names);
			List<DropItem> items = scope .();
			int selected = -1;
			for (let n in names)
			{
				items.Add(.(n, "Gives a delegate of this type: its inputs and result follow it"));
				if (n == typeText)
					selected = items.Count - 1;
			}
			let customAt = items.Count;
			items.Add(.("Custom signature (delegate)", "A delegate of a signature you set below (delegate:R(A, B))"));
			items.Add(.("Custom signature (function pointer, C callback)", "A plain function pointer of a signature you set below (function:R(A, B)): no object, no captures"));
			if (custom)
				selected = customAt + (typeText.StartsWith("function:") ? 1 : 0);
			String preview = scope .();
			if (typeText.IsEmpty)
				preview.Append("(choose the delegate it gives)");
			else if (custom)
				preview.Append(typeText.StartsWith("function:") ? "C callback" : "Custom");
			else
				preview.Append(typeText);
			let picked = PropertyGrid.DropdownRow("Type", scope $"##lty{id}", preview, items, selected,
				"What the Lambda gives: a delegate type (its signature decides the inputs and the result) or a function pointer for a C callback",
				default, readOnly, default, Theme.DelegatePin, typeText.IsEmpty ? "A Lambda needs a type: pick one, or drag from a delegate input to place it" : default);
			if (picked >= 0 && picked != selected && !readOnly)
			{
				String newType = scope .();
				if (picked < customAt)
					newType.Set(names[picked]);
				else
				{
					// A custom signature starts from the current one (or void()).
					LambdaSignature start = scope .();
					if (!known)
						start.Returns.Set("void");
					else
					{
						start.Returns.Set(sig.Returns);
						for (let p in sig.Params)
							start.Params.Add(new String(p));
					}
					start.IsFunction = picked == customAt + 1;
					start.ToTypeText(newType);
				}
				BeginEdit();
				SetLambdaTypeFromProperties(mg, node, newType);
				CommitCurrent();
				return;
			}
			if (!typeText.IsEmpty && !known)
				PropertyGrid.InfoRow("Signature", "(not a delegate or function pointer type that is known)", default, Look.Warning);
			else if (known)
			{
				String text = scope .();
				LambdaSubtitle(node, text);
				PropertyGrid.InfoRow("Signature", text, sig.IsFunction ? "A function pointer: inputs and result" : "A delegate: inputs and result");
			}

			// Inputs: names always (they are the Entry's pins in the Sheet), types with a custom signature.
			List<String> inputs = scope .();
			defer { ClearAndDeleteItems!(inputs); }
			LambdaInputNames(node, known ? sig.Params.Count : -1, inputs);
			bool edited = false;
			for (int i < inputs.Count)
			{
				Gui.PushID((int32)i);
				StringView type = (known && i < sig.Params.Count) ? (StringView)sig.Params[i] : "";
				let label = scope String()..AppendF("Input {}", i + 1);
				// The name, and with a custom signature an X that removes the input (as a Switch's cases).
				PropertyGrid.Row(label, scope $"The input's name: the Entry pin of the Lambda Sheet{(type.IsEmpty ? "" : scope $" ({type})")}", type.IsEmpty ? 0 : Theme.TypeColor(type));
				let nameId = scope String()..AppendF("##lin{}_{}", id, i);
				let buf = TsBuf(nameId, inputs[i]);
				bool removable = custom && known && !readOnly;
				Gui.igSetNextItemWidth(Math.Max(40 * Look.Scale, Gui.igGetContentRegionAvail().x - (removable ? Gui.igGetFrameHeight() + 8 * Look.Scale : 0)));
				bool done = PropertyGrid.Text(nameId, buf, ?, false, null, "name");
				if (!done && !Gui.igIsItemActive() && buf != inputs[i])
					buf.Set(inputs[i]);
				if (done && buf != inputs[i] && !readOnly)
				{
					String why = scope .();
					BeginEdit();
					if (RenameLambdaInput(mg, node, i, buf, why))
					{
						CommitCurrent();
						edited = true;
					}
					else
					{
						EditDoc.DropLastUndo();
						SetStatus(why, .Warning);
						buf.Set(inputs[i]);
					}
				}
				if (!edited && removable)
				{
					Gui.SameLine(0, 8 * Look.Scale);
					if (Gui.SmallButton(Icon.X))
					{
						delete sig.Params[i];
						sig.Params.RemoveAt(i);
						delete inputs[i];
						inputs.RemoveAt(i);
						BeginEdit();
						List<StringView> views = scope .();
						for (let s in inputs)
							views.Add(s);
						NodeFactory.SetLambdaInputs(node, views);
						String newType = scope .();
						sig.ToTypeText(newType);
						SetLambdaTypeFromProperties(mg, node, newType);
						CommitCurrent();
						edited = true;
					}
					else if (Gui.igIsItemHovered(0))
						Gui.Tooltip(scope $"Removes the input {inputs[i]} (its wires in the Sheet go)");
				}
				if (!edited && custom && known)
				{
					String t = scope .();
					if (TsType("    Type", scope $"##lit{id}_{i}", type, t, "The input's type") && !readOnly && !t.IsEmpty)
					{
						sig.Params[i].Set(t);
						RewriteCustomSignature(mg, node, sig);
						edited = true;
					}
				}
				Gui.PopID();
				if (edited)
					break;
			}
			if (inputs.IsEmpty && known)
				PropertyGrid.InfoRow("Inputs", "none");
			if (!edited && custom && known && PropertyGrid.ButtonRow("", scope $"{Icon.Plus} Add Input", "A new int input (change its type above)") && !readOnly)
			{
				sig.Params.Add(new String("int"));
				RewriteCustomSignature(mg, node, sig);
				edited = true;
			}
			if (edited)
				return;
			if (custom && known)
			{
				String t = scope .();
				if (TsType("Returns", scope $"##lret{id}", sig.Returns, t, "The result: the Return node's Return Value in the Sheet (void: none)") && !readOnly && !t.IsEmpty)
				{
					sig.Returns.Set(t);
					RewriteCustomSignature(mg, node, sig);
					return;
				}
			}
			else if (known)
				PropertyGrid.InfoRow("Returns", sig.Returns, "The result: the Return node's Return Value in the Sheet", 0, 0, false, Theme.TypeColor(sig.Returns));

			// Allocation, with what each one means.
			StringView alloc = node.GetSetting("alloc");
			int current = (alloc == "local") ? 1 : ((alloc == "construct") ? 2 : 0);
			List<DropItem> allocs = scope .();
			for (int i < 3)
			{
				StringView why = default;
				if (known && sig.IsFunction && i > 0)
					why = "A function pointer allocates nothing: give the Lambda a delegate type for an object";
				else if (known && !sig.IsFunction && i == 0)
					why = scope:: $"{typeText} is a delegate (an object): for a C callback give the Lambda a function pointer type";
				allocs.Add(.(sLambdaAllocNames[i], sLambdaAllocWhy[i], why));
			}
			let pickedAlloc = PropertyGrid.DropdownRow("Allocation", scope $"##lalloc{id}", sLambdaAllocNames[current], allocs, current,
				"Where the delegate lives (allocation is a flow node, Language.md 3)", default, readOnly);
			if (pickedAlloc >= 0 && pickedAlloc != current && !readOnly)
			{
				BeginEdit();
				SetLambdaAllocFromProperties(mg, node, sLambdaAllocs[pickedAlloc]);
				CommitCurrent();
				return;
			}
			PropertyGrid.InfoRow("", sLambdaAllocWhy[current], default, Look.ForegroundDim, 0, true);

			// Captures: what the Sheet reads of the function, as the front end found it.
			mLambdaRowsShown.Clear();
			let res = LambdaResult(mg, node);
			if (res == null)
				PropertyGrid.InfoRow("Captures", "Validate (Shift+F7) lists them", "What the Lambda Sheet reads of the function: its locals, its inputs, this");
			else if (res.Captures.IsEmpty)
				PropertyGrid.InfoRow("Captures", "none", "The Lambda Sheet reads nothing of the function");
			else
			{
				PropertyGrid.InfoRow("Captures", scope $"{res.Captures.Count}: read by the Sheet", "What the Lambda Sheet reads of the function: its locals, its inputs, this. By value: a copy made when the Lambda is made; by reference: the variable itself (Local Lambdas only).");
				for (let cap in res.Captures)
				{
					Gui.PushID(scope $"cap{cap.Name}");
					bool isThis = cap.What == .This;
					StringView capName = isThis ? "this" : (StringView)cap.Name;
					bool byRef = cap.ByRef;
					String disabledWhy = scope .();
					if (isThis)
						disabledWhy.Set("this is held by value: the Lambda keeps the object reference itself");
					else if (alloc != "local")
						disabledWhy.AppendF("Only a Local Lambda captures by reference: a {} Lambda may outlive {}", (alloc == "construct") ? "Construct" : "function pointer", capName);
					else if (!byRef)
						NestedByValueWhy(mg, capName, disabledWhy);
					String what = scope .();
					what.AppendF("{} {}", (cap.What == .Local) ? "local" : ((cap.What == .Param) ? "input" : "the object"), (cap.Type != null) ? (StringView)cap.Type.Name : "");
					// Read only by a Lambda inside this one's Sheet (held here so the inner one can).
					if (cap.Chained)
						what.Append(", for a Lambda inside");
					mLambdaRowsShown.AppendF("{} {}{}; ", capName, byRef ? "by-ref" : "by-value", cap.Chained ? " chained" : "");
					if (PropertyGrid.CheckRow(scope $"    {capName}", scope $"##lcap{id}", ref byRef,
						scope $"{what}: {(byRef ? "by reference (the Lambda writes the variable itself)" : "by value (a copy made when the Lambda is made)")}",
						"by reference", !disabledWhy.IsEmpty || readOnly, disabledWhy, Theme.TypeColor((cap.Type != null) ? (StringView)cap.Type.Name : "")) && !readOnly)
					{
						String why = scope .();
						BeginEdit();
						if (SetLambdaCaptureByRef(mg, node, capName, byRef, why))
							CommitCurrent();
						else
						{
							EditDoc.DropLastUndo();
							SetStatus(why, .Warning);
						}
						Gui.PopID();
						break;
					}
					Gui.PopID();
				}
			}
			// `capture` lines that name nothing the Sheet reads (left from an older Sheet).
			for (let s in node.Settings)
			{
				if (s.Key != "capture" || s.IsSet)
					continue;
				var parts = s.Value.Split(' ');
				let capName = (parts.GetNext() case .Ok(let w)) ? w : StringView();
				if (res == null || res.FindCapture(.Local, capName) != null || res.FindCapture(.Param, capName) != null)
					continue;
				if (PropertyGrid.ButtonRow(capName, scope $"{Icon.X} not read by the Sheet: remove", scope $"capture {s.Value}") && !readOnly)
				{
					BeginEdit();
					NodeFactory.SetCaptureByRef(g, node, capName, false);
					CommitCurrent();
					break;
				}
			}

			// The Sheet.
			if (PropertyGrid.ButtonRow("Sheet", scope $"{Icon.SquareFunction} Open Sheet", "The Lambda's body: a Sheet of its own (double-click the node too)"))
				OpenLambdaSheet(node);
		}

		/// A Lambda Sheet with nothing selected: what it is the body of (its name follows the node,
		/// it is not renamed on its own), the signature, the captures, and the way back to the node.
		void DrawLambdaSheetDetails(Sheet ls)
		{
			let owner = LambdaOwner(ls.Doc, ls);
			let node = (owner != null) ? owner.Graph.FindNodeByKey(ls.LambdaNode) : null;
			String title = scope $"{(owner != null) ? (StringView)owner.Name : "?"} > Lambda {ls.LambdaNode}";
			DetailsHeader(Icon.SquareFunction, Theme.DelegatePin, title, "Lambda Sheet");
			if (!PropertyGrid.Begin("##lambdasheetgrid"))
				return;
			if (PropertyGrid.Section("Lambda Sheet", true))
			{
				PropertyGrid.InfoRow("Body of", (owner != null) ? scope:: $"Lambda {ls.LambdaNode} in {owner.Name}" : "(its node is gone)");
				if (node != null)
				{
					String sigText = scope .();
					LambdaSubtitle(node, sigText);
					PropertyGrid.InfoRow("Signature", sigText.IsEmpty ? "(set the Lambda's type)" : (StringView)sigText, "The Entry gives the inputs, the Return takes the result");
					let res = LambdaResult(owner, node);
					String caps = scope .();
					if (res == null)
						caps.Append("Validate (Shift+F7) lists them");
					else if (res.Captures.IsEmpty)
						caps.Append("none");
					else
						for (let cap in res.Captures)
						{
							if (!caps.IsEmpty)
								caps.Append(", ");
							caps.AppendF("{}{}{}", (cap.What == .This) ? "this" : (StringView)cap.Name, cap.ByRef ? " (by reference)" : "", cap.Chained ? " (for a Lambda inside)" : "");
						}
					PropertyGrid.InfoRow("Captures", caps, "What this Sheet reads of the function (Properties of the Lambda node sets by value / by reference)", 0, 0, true);
					if (PropertyGrid.ButtonRow("Lambda", scope $"{Icon.SquareFunction} Show the node", scope $"Opens {owner.Name} with the Lambda node selected"))
					{
						OpenTab(owner);
						if (CurrentTab != null && CurrentTab.MethodKey == owner.Key)
						{
							CurrentTab.SelectOnly(node.Id);
							mGraphPanel.FrameNodes(CurrentTab, owner.Graph, true);
						}
					}
				}
				PropertyGrid.InfoRow("Nodes", scope $"{ls.Graph.Nodes.Count}");
				PropertyGrid.InfoRow("Wires", scope $"{ls.Graph.Links.Count}");
			}
			if (!ls.Graph.Errors.IsEmpty || !ls.Graph.Warnings.IsEmpty)
			{
				if (PropertyGrid.Section("Problems", true, Icon.Warning))
				{
					PropertyGrid.WideRow();
					Gui.igIndent(10 * Look.Scale);
					for (let e in ls.Graph.Errors)
						PropertyGrid.Problem(e.Message);
					for (let w in ls.Graph.Warnings)
						PropertyGrid.Info(scope:: $"{Icon.Warning}  {w.Message}", Look.Warning, 0, true);
					Gui.igUnindent(10 * Look.Scale);
				}
			}
			PropertyGrid.End();
		}

		/// A custom signature changed (an input's type, an input added, the result): `set type`
		/// is written again and the inputs and Sheet pins follow, one undo step.
		void RewriteCustomSignature(Sheet mg, Node node, LambdaSignature sig)
		{
			String newType = scope .();
			sig.ToTypeText(newType);
			BeginEdit();
			SetLambdaTypeFromProperties(mg, node, newType);
			CommitCurrent();
		}
	}
}
