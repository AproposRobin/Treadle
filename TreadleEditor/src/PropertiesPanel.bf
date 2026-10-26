using System;
using System.Collections;
using ImGui;
using Treadle.Graph;
using Treadle.Document;

namespace Treadle.Editor
{
	/// The Properties panel: a property grid (categories with collapsible bars, names on the left,
	/// widgets on the right) for what is selected: one node, a comment box, several nodes, or the
	/// front Sheet when nothing is selected. Edits go through BeginEdit / CommitCurrent.
	///
	/// Seam: the kind-specific rows of a node (overload, receiver, constructor, switch cases...)
	/// and the function / variable / type pages come from the language; until it is installed a
	/// node shows its unwired inputs as text values, its outputs and its comment.
	extension EditorApp
	{
		void DrawPropertiesPanel()
		{
			Gui.igPushStyleVar_Vec2(StyleVar.WindowPadding, .(0, 4 * Look.Scale));
			bool visible = Gui.Begin(Panels.Properties);
			Gui.igPopStyleVar(1);
			if (visible)
			{
				let tab = CurrentTab;
				let mg = CurrentMethod;
				// The Outline's choice (Type Settings, a member, a local) until the canvas selection changes.
				if (OutlineSel == .Project && Project != null && OutlineSelectionShown())
					DrawProjectSettings(); // the Project Browser's project tile
				else if (Doc != null && Doc != mEmptyDoc && OutlineSelectionShown())
				{
					switch (OutlineSel)
					{
					case .Project:
						OutlineSel = .None; // the project file is gone
					case .TypeSettings:
						DrawTypeSettings();
					case .Member:
						DrawMemberPage(SelectedMember);
					case .Local:
						let lg = OpenLocalsGraph();
						let local = (lg != null) ? lg.Graph.FindLocal(mSelLocalName) : null;
						if (local != null)
							DrawLocalPage(lg, local);
						else
							OutlineSel = .None;
					case .None:
					}
				}
				else if (tab == null || mg == null)
				{
					Gui.igIndent(10 * Look.Scale);
					Gui.igPushTextWrapPos(0);
					Gui.TextDisabled("Open a Sheet and select a node to see its properties.");
					Gui.igPopTextWrapPos();
					Gui.igUnindent(10 * Look.Scale);
				}
				else if (tab.SelectedNodes.Count == 1 && mg.Graph.FindNode(tab.SelectedNodes[0]) != null &&
					mg.Graph.FindNode(tab.SelectedNodes[0]) != mg.Graph.Entry)
					DrawNodeDetails(mg, mg.Graph.FindNode(tab.SelectedNodes[0]));
				else if (mGraphPanel.DrawCommentDetails(tab)) {} // comment box selected (text, colour)
				else if (tab.SelectedNodes.Count > 1)
					DrawMultiSelectDetails(tab, mg);
				else if (mg.Member != null && mg.Doc == Doc && mg.Role == .Body)
					DrawMemberPage(mg.Member); // nothing selected: the function's own page (signature, flags)
				else
					DrawSheetDetails(mg);
			}
			Panels.NoteNarrow();
			Gui.End();
		}

		/// The header strip at the top of Properties: icon + title (+ subtitle).
		void DetailsHeader(StringView icon, uint32 iconColor, StringView title, StringView subtitle = default)
		{
			Gui.igIndent(10 * Look.Scale);
			let p = Gui.igGetCursorScreenPos();
			float fs = Gui.igGetFontSize();
			let dl = Gui.igGetWindowDrawList();
			Gui.DrawText(dl, .(p.x, p.y + 2 * Look.Scale), iconColor, icon, fs * 1.3f);
			Gui.igSetCursorScreenPos(.(p.x + fs * 1.8f, p.y));
			Gui.TextColored(Look.ForegroundHover, title);
			if (!subtitle.IsEmpty)
			{
				Gui.igSetCursorScreenPos(.(p.x + fs * 1.8f, Gui.igGetCursorScreenPos().y));
				Gui.TextColored(Look.ForegroundDim, subtitle);
			}
			Gui.igUnindent(10 * Look.Scale);
			Gui.igSpacing();
		}

		/// A text property bound to `value`: the first keystroke records an undo step, the edit is
		/// committed when the field is left. Returns true on commit.
		bool GridText(StringView name, StringView id, String value, StringView tip = default, bool mono = false, StringView hint = default, uint32 swatch = 0)
		{
			String before = scope .(value);
			bool done = PropertyGrid.TextRow(name, id, value, let changed, tip, hint, mono, swatch);
			if (changed && !mDetailsEditPushed)
				BeginEditBefore(value, before);
			return done;
		}

		/// The grid widgets write into the model's own string as you type, so the undo step (a copy
		/// of the graph) must see the value from before the change: put it back for the snapshot,
		/// then the new one again.
		void BeginEditBefore(String value, StringView before)
		{
			String now = scope .(value);
			value.Set(before);
			BeginEdit();
			value.Set(now);
			mDetailsEditPushed = true;
		}

		static void PinLabel(Pin p, String outLabel)
		{
			outLabel.Set(p.Label.IsEmpty ? p.Name : p.Label);
			if (outLabel.IsEmpty)
				outLabel.Set("(unnamed)");
		}

		static StringView[?] sCastKinds = .("numeric", "class", "unchecked", "box", "unbox");
		static StringView[?] sOperators = .("+", "-", "*", "/", "%", "==", "!=", "<", ">", "<=", ">=", "&&", "||", "!", "&", "|", "^", "<<", ">>", "~", "neg");

		/// A node's page: what it is about (its subject and kind-specific settings), every
		/// setting as written, the value of each unwired input (a typed control per type), the
		/// outputs, the comment, the disabled / unsafe flags and the node's problems.
		void DrawNodeDetails(Sheet mg, Node node)
		{
			let g = mg.Graph;
			String title = scope .();
			node.GetTitle(title);
			String kindWord = scope .(Treadle.Graph.NodeKinds.Word(node.Kind));
			if (kindWord.IsEmpty && node.KindWord != null)
				kindWord.Set(node.KindWord);
			DetailsHeader(node.IsExecNode ? Icon.SquareFunction : Icon.Sigma, Theme.HeaderColor(node), title, scope $"{kindWord} node  \u{00B7}  {node.Key}");
			if (!PropertyGrid.Begin("##nodegrid"))
				return;
			String v = scope .();
			String id = scope $"{node.Key}";
			bool readOnly = g.ReadOnly;
			if (PropertyGrid.Section("Node", true))
			{
				switch (node.Kind)
				{
				case .ChainCtor:
					{
						// What runs before this constructor's body: a constructor of the base class or of this type.
						String target = scope .();
						if (node.Text == "this")
							target.AppendF("{}'s other", mg.Doc.Header.Name);
						else
							target.AppendF("{}'s", (mg.Doc.Header.Base != null) ? mg.Doc.Header.Base.ToString(.. scope String()) : "the base class");
						target.Append(" constructor");
						PropertyGrid.InfoRow("Runs First", target, (node.Text == "this") ? "This Constructor: another constructor of this type runs first, then this one's body" : "Base Constructor: a constructor of the base class runs first, then this one's body (constructors are not inherited)");
					}
					DrawOverloadRow(mg, node, readOnly);
				case .Construct, .Local:
					if (TsType("Type", scope $"##ntype{id}", node.Text, v, "What the node allocates: a class or a struct that is not abstract or static", .Allocatable) && !readOnly)
					{
						// The constructor is looked up again for the new type (a generic one's with its arguments).
						BeginEdit();
						mNodeMenu.RetypeAllocation(mg, node, v);
						CommitCurrent();
					}
					int32 life = (node.Kind == .Local) ? 1 : 0;
					StringView[?] lifes = .("Construct (heap: you delete it)", "Local (freed when the region ends)");
					if (PropertyGrid.ComboRow("Lifetime", scope $"##nlife{id}", ref life, lifes) && !readOnly)
					{
						BeginEdit();
						NodeFactory.SetLifetime(g, node, life == 1);
						CommitCurrent();
					}
					if (node.Kind == .Local)
					{
						bool fs = node.HasSetting("function-scope");
						if (PropertyGrid.CheckRow("Until Return", scope $"##nfs{id}", ref fs, "Lives until the function returns instead of the end of its region") && !readOnly)
						{
							BeginEdit();
							if (fs)
								node.SetSetting("function-scope", "");
							else
								node.RemoveSetting("function-scope");
							CommitCurrent();
						}
					}
					StorageRowNode(node); // LivesIn.bf
					DrawOverloadRow(mg, node, readOnly);
				case .Cast:
					if (TsType("Cast To", scope $"##ncast{id}", node.Text, v) && !readOnly)
					{
						BeginEdit();
						NodeFactory.SetCastType(g, node, v);
						CommitCurrent();
					}
					int32 ck = 0;
					for (int i < sCastKinds.Count)
						if (node.GetSetting("kind") == sCastKinds[i])
							ck = (int32)i;
					if (PropertyGrid.ComboRow("Kind", scope $"##nck{id}", ref ck, sCastKinds, "numeric: converts numbers. class: checks the object's type. box / unbox: a struct as an object.") && !readOnly)
					{
						BeginEdit();
						node.SetSetting("kind", sCastKinds[ck]);
						NodeFactory.Reshape(g, node);
						CommitCurrent();
					}
					bool chk = node.HasSetting("checked");
					if (PropertyGrid.CheckRow("Checked", scope $"##nchk{id}", ref chk, "Succeeded / Failed flow outputs: Failed runs when the object is not of the type") && !readOnly)
					{
						BeginEdit();
						if (chk)
							node.SetSetting("checked", "");
						else
							node.RemoveSetting("checked");
						NodeFactory.Reshape(g, node);
						CommitCurrent();
					}
				case .Get, .Set, .Call, .Bind, .Intrinsic:
					if (TsText("Subject", scope $"##nsub{id}", node.Text, v, "What the node reads, writes or calls: this.field, Type.Function(int), local:name, param:name") && !readOnly)
					{
						BeginEdit();
						node.Text.Set(v);
						NodeFactory.Reshape(g, node);
						CommitCurrent();
					}
					if (node.Kind == .Call)
						DrawOverloadRow(mg, node, readOnly);
					if (node.Kind == .Set)
					{
						StringView[?] ops = .("=", "+=", "-=", "*=", "/=");
						int32 op = 0;
						for (int i < ops.Count)
							if (node.GetSetting("op") == ops[i])
								op = (int32)i;
						if (PropertyGrid.ComboRow("Assignment", scope $"##nop{id}", ref op, ops) && !readOnly)
						{
							BeginEdit();
							if (op == 0)
								node.RemoveSetting("op");
							else
								node.SetSetting("op", ops[op]);
							CommitCurrent();
						}
					}
				case .Operator:
					int32 op = 0;
					for (int i < sOperators.Count)
						if (node.Text == sOperators[i])
							op = (int32)i;
					if (PropertyGrid.ComboRow("Operator", scope $"##noper{id}", ref op, sOperators) && !readOnly)
					{
						BeginEdit();
						node.Text.Set(sOperators[op]);
						NodeFactory.Reshape(g, node);
						CommitCurrent();
					}
				case .Sequence, .MultiGate:
					int32 count = 2;
					if (int32.Parse(node.GetSetting("count")) case .Ok(let c))
						count = c;
					if (PropertyGrid.IntRow("Outputs", scope $"##ncount{id}", ref count, 0.05f, 1, 64) && !readOnly)
					{
						BeginEdit();
						node.SetSetting("count", scope $"{count}");
						NodeFactory.Reshape(g, node);
						CommitCurrent();
					}
					if (node.Kind == .MultiGate)
						DrawStateFieldRow(mg, node, readOnly);
				case .Switch:
					if (TsType("Switch On", scope $"##non{id}", node.GetSetting("on"), v, "The type of the value: an integer, a char, a String or an enum", .SwitchOn) && !readOnly)
					{
						BeginEdit();
						node.SetSetting("on", v);
						node.FindInput("value")?.SetTypeText(v);
						CommitCurrent();
					}
					for (let p in node.Outputs)
					{
						if (!p.Name.StartsWith("case:"))
							continue;
						Gui.PushID(p.Id);
						PropertyGrid.Row("Case", "The case's label: any text for a String switch (spaces and quotes too), a number, a 'c' char or an enum case");
						// The label is free text; the file quotes it when it needs it (Graph-Format.md 2).
						let caseId = scope String()..AppendF("##ncase{}", p.Id);
						let label = StringView(p.Name, 5);
						let buf = TsBuf(caseId, label);
						Gui.igSetNextItemWidth(Math.Max(40 * Look.Scale, Gui.igGetContentRegionAvail().x - Gui.igGetFrameHeight() - 8 * Look.Scale));
						bool renamed = PropertyGrid.Text(caseId, buf, ?, false, null, "label");
						if (!renamed && !Gui.igIsItemActive() && buf != label)
							buf.Set(label);
						if (renamed && buf != label && !readOnly)
						{
							BeginEdit();
							if (!NodeFactory.RenameCase(g, node, p, buf))
							{
								SetStatus(scope $"The Switch already has a case '{buf}'", .Warning);
								buf.Set(label);
							}
							CommitCurrent();
							Gui.PopID();
							break;
						}
						Gui.SameLine(0, 8 * Look.Scale);
						if (Gui.SmallButton(Icon.X) && !readOnly)
						{
							BeginEdit();
							NodeFactory.RemoveCase(g, node, p);
							CommitCurrent();
							Gui.PopID();
							break;
						}
						Gui.PopID();
					}
					if (PropertyGrid.ButtonRow("", scope $"{Icon.Plus} Add Case") && !readOnly)
					{
						if (!AddExecPin(node))
							SetStatus("Every case of the enum has its output already", .Info, false);
					}
				case .For:
					StringView indexType = node.GetSetting("index-type").IsEmpty ? "int" : node.GetSetting("index-type");
					if (TsType("Index Type", scope $"##nfor{id}", indexType, v, "An integer type", .Integer) && !readOnly)
					{
						BeginEdit();
						node.SetSetting("index-type", v);
						for (let p in node.Inputs)
							if (p.Kind == .Value)
								p.SetTypeText(v);
						node.FindOutput("index")?.SetTypeText(v);
						CommitCurrent();
					}
				case .Literal:
					if (TsType("Type", scope $"##nlt{id}", node.GetSetting("type"), v) && !readOnly)
					{
						BeginEdit();
						node.SetSetting("type", v);
						node.Result?.SetTypeText(v);
						CommitCurrent();
					}
					v.Clear();
					if (TsText("Value", scope $"##nlv{id}", node.GetSetting("value"), v, "The literal as the type file writes it: 1, 2.5f, \"text\", true, .Case") && !readOnly)
					{
						BeginEdit();
						node.SetSetting("value", v);
						CommitCurrent();
					}
				case .Lambda:
					DrawLambdaDetails(mg, node, readOnly);
				case .Gate, .DoOnce, .DoN, .FlipFlop:
					DrawStateFieldRow(mg, node, readOnly);
				case .GateOpen, .GateClose, .GateToggle, .ResetDoOnce, .ResetDoN, .ResetMultiGate:
					DrawStateTargetRow(mg, node, readOnly);
				case .Swizzle, .Shuffle:
					DrawVectorNodeRows(mg, node, readOnly); // VectorProperties.bf
				case .Make, .BreakStruct:
					// A vector's Make / Break: its vector type (the lanes follow); a struct's: the subject.
					if (Treadle.Model.VectorTypes.LanesOf(node.Text) > 0)
						DrawVectorTypeRow(mg, node, readOnly);
					else if (!node.Text.IsEmpty)
						PropertyGrid.InfoRow("Subject", node.Text);
				default:
					if (!node.Text.IsEmpty)
						PropertyGrid.InfoRow("Subject", node.Text);
				}
				bool disabled = node.Disabled;
				if (node != g.Entry && PropertyGrid.CheckRow("Disabled", scope $"##ndis{id}", ref disabled, "Kept in the file, skipped when compiling") && !readOnly)
				{
					BeginEdit();
					node.Disabled = disabled;
					CommitCurrent();
				}
				if (node.Kind == .Scope)
				{
					bool unsafe = node.Unsafe;
					if (PropertyGrid.CheckRow("Unsafe", scope $"##nunsafe{id}", ref unsafe, "Pointer nodes are allowed inside") && !readOnly)
					{
						BeginEdit();
						node.Unsafe = unsafe;
						CommitCurrent();
					}
				}
				v.Clear();
				if (TsText("Comment", scope $"##ncomment{id}", (node.Comment != null) ? (StringView)node.Comment : "", v, "A note shown in a bubble over the node") && !readOnly)
				{
					BeginEdit();
					if (v.IsEmpty)
						DeleteAndNullify!(node.Comment);
					else
						String.NewOrSet!(node.Comment, v);
					CommitCurrent();
				}
			}
			String label = scope .();
			if (PropertyGrid.Section("Inputs", true, Icon.ArrowRight))
			{
				int shown = 0;
				for (let p in node.Inputs)
				{
					if (p.Kind != .Value || SplitPins.IsSplit(p))
						continue; // a split pin is hidden: its field or lane pins are the rows
					PinLabel(p, label);
					uint32 swatch = Theme.PinColor(p);
					String tip = scope $"{(p.TypeName.IsEmpty ? "any type" : p.TypeName)}  \u{00B7}  pin '{p.Name}'";
					if (g.IsLinked(p))
					{
						let link = g.FindLinkTo(p);
						String from = scope .();
						if (link != null && link.From?.Owner != null)
							link.From.Owner.GetTitle(from);
						PropertyGrid.InfoRow(label, scope $"connected: {from}", tip, 0, 0, false, swatch);
					}
					else
					{
						let vk = PinValue.KindOf(p.TypeName, p.Default, p.Name, Language.Types);
						if (PinValueEditor.Handles(vk) && !readOnly)
						{
							PropertyGrid.Row(label, tip, swatch);
							mGraphPanel.mPinEditor.ButtonColor = 0;
							if (mGraphPanel.mPinEditor.Draw(this, node, p, vk, Gui.igGetContentRegionAvail().x))
								CommitCurrent();
						}
						else if (GridText(label, scope $"##in{p.Id}", p.Default, tip, false, p.Optional ? "(optional)" : "default", swatch))
							CommitCurrent();
					}
					shown++;
				}
				if (shown == 0)
					PropertyGrid.InfoRow("", "No value inputs");
			}
			if (PropertyGrid.Section("Outputs", true, Icon.ArrowLeft))
			{
				int shown = 0;
				for (let p in node.Outputs)
				{
					if (p.Kind != .Value || SplitPins.IsSplit(p))
						continue; // a split pin is hidden: its field or lane pins are the rows
					PinLabel(p, label);
					PropertyGrid.InfoRow(label, p.TypeName.IsEmpty ? "(any)" : (StringView)p.TypeName, scope $"pin '{p.Name}'", 0, 0, false, Theme.PinColor(p));
					shown++;
				}
				if (shown == 0)
					PropertyGrid.InfoRow("", "No value outputs");
			}
			let err = g.FindError(node.Id);
			let warn = g.FindWarning(node.Id);
			if ((err != null || warn != null) && PropertyGrid.Section("Problems", true, Icon.Warning))
			{
				PropertyGrid.WideRow(); // the messages span the panel, not the name column
				Gui.igIndent(10 * Look.Scale);
				for (let e in g.Errors)
					if (e.NodeId == node.Id)
						PropertyGrid.Problem((e.PinName != null) ? scope:: $"{e.Message}  (pin '{e.PinName}')" : scope:: String(e.Message));
				for (let w in g.Warnings)
					if (w.NodeId == node.Id)
						PropertyGrid.Info(scope:: $"{Icon.Warning}  {w.Message}", Look.Warning, 0, true); // whole, wrapped: the node shows one line
				Gui.igUnindent(10 * Look.Scale);
			}
			if (PropertyGrid.Section("Settings", false, Icon.Info))
			{
				if (node.Settings.IsEmpty)
					PropertyGrid.Info("No settings (the node is as its kind makes it).");
				for (let s in node.Settings)
				{
					Gui.PushID((int32)@s.Index);
					v.Clear();
					if (TsText(s.IsSet ? scope $"set {s.Key}" : scope $"{s.Key}", scope $"##nset{id}_{@s.Index}", s.Value, v, "The setting as the type file writes it") && !readOnly)
					{
						BeginEdit();
						if (!s.IsSet || s.Key != "ctor" || !SwitchCtorBySignature(mg, node, v))
						{
							s.Value.Set(v);
							NodeFactory.Reshape(g, node);
						}
						CommitCurrent();
						Gui.PopID();
						break;
					}
					Gui.PopID();
				}
				PropertyGrid.InfoRow("Pure", node.IsPure ? "yes (a value node)" : "no (a flow node)");
			}
			PropertyGrid.End();
		}

		// ------------------------------------------------------------------ overloads and constructors

		/// The Overload row of a Call / the Constructor row of a Construct or Local: a dropdown of the
		/// signatures (NodeMenu.OverloadsOf); picking one rebuilds the node's pins, keeping the wires
		/// that still fit. One choice (or none known) shows as text.
		void DrawOverloadRow(Sheet mg, Node node, bool readOnly)
		{
			bool isCall = node.Kind == .Call;
			StringView rowName = isCall ? "Overload" : "Constructor";
			List<NodeMenu.OverloadChoice> choices = scope .();
			defer { ClearAndDeleteItems!(choices); }
			let current = mNodeMenu.OverloadsOf(mg, node, choices);
			if (choices.Count < 2)
			{
				if (!isCall)
				{
					// The one constructor with its parameters' names ("(Point value)"), else as the node names it.
					StringView shown = node.HasSetting("ctor") ? node.GetSetting("ctor") : "(the default one)";
					if (choices.Count == 1 && current == 0)
					{
						let paren = choices[0].Label.IndexOf('(');
						if (paren >= 0)
							shown = StringView(choices[0].Label, paren);
						if (shown == "()")
							shown = "(no inputs)";
					}
					PropertyGrid.InfoRow(rowName, shown, choices.IsEmpty ? default : (StringView)choices[0].Label);
				}
				return;
			}
			List<DropItem> items = scope .();
			for (let c in choices)
				items.Add(.(c.Label, "Switch to this one: the pins follow, wires that still fit stay"));
			// The row names the function (the header does too): the box shows the parameters.
			StringView preview = "(by the wired arguments)";
			if (current >= 0)
			{
				preview = choices[current].Label;
				let paren = preview.IndexOf('(');
				if (paren > 0)
					preview = preview.Substring(paren);
			}
			let picked = PropertyGrid.DropdownRow(rowName, scope $"##noverload{node.Key}", preview, items, current,
				isCall ? "Which function of this name the node calls" : ((node.Kind == .ChainCtor) ? "Which constructor runs first" : "Which constructor makes the object"), default, readOnly);
			if (picked >= 0 && picked != current && !readOnly)
			{
				BeginEdit();
				mNodeMenu.SwitchOverload(mg, node, choices[picked]);
				CommitCurrent();
			}
		}

		/// Settings > `set ctor` typed on a Construct, Local or Base / This Constructor: when it names one
		/// of the constructors the Constructor row lists (`(Point)`, spaces ignored), the node switches to
		/// it as that row does (the pins follow, wires that still fit stay). False when it names none.
		public bool SwitchCtorBySignature(Sheet mg, Node node, StringView sig)
		{
			if (node.Kind != .Construct && node.Kind != .Local && node.Kind != .ChainCtor)
				return false;
			String want = scope .();
			for (let c in sig.RawChars)
				if (c != ' ')
					want.Append(c);
			List<NodeMenu.OverloadChoice> choices = scope .();
			defer { ClearAndDeleteItems!(choices); }
			mNodeMenu.OverloadsOf(mg, node, choices);
			for (let c in choices)
			{
				String have = scope .();
				for (let ch in c.Signature.RawChars)
					if (ch != ' ')
						have.Append(ch);
				if (have == want)
					return mNodeMenu.SwitchOverload(mg, node, c);
			}
			return false;
		}

		// ------------------------------------------------------------------ flow-node state (Language.md 5.1)

		/// What the State Field / Changes row showed last (the self test reads it).
		public String mStateRowShown = new .() ~ delete _;

		/// The stateful kind an Open / Close / Toggle Gate or Reset node changes.
		static NodeKind StatefulKindOf(NodeKind k)
		{
			switch (k)
			{
			case .GateOpen, .GateClose, .GateToggle: return .Gate;
			case .ResetDoOnce: return .DoOnce;
			case .ResetDoN: return .DoN;
			case .ResetMultiGate: return .MultiGate;
			default: return k;
			}
		}

		/// The type a node of this kind keeps its state in: an int (Do N: runs so far; Multi Gate: the
		/// next output) or a bool (Gate: open; Do Once: done; Flip Flop: A ran last).
		static StringView StateTypeOf(NodeKind k) => (k == .DoN || k == .MultiGate) ? "int" : "bool";

		static StringView StateMeaning(NodeKind k)
		{
			switch (k)
			{
			case .Gate: return "bool (open)";
			case .DoOnce: return "bool (done)";
			case .DoN: return "int (runs so far)";
			case .FlipFlop: return "bool (A ran last)";
			default: return "int (next output)";
			}
		}

		/// The field a stateful node keeps its state in: its `set state` field, else its hidden one.
		static void StateFieldOf(Node n, String outName)
		{
			if (n.HasSetting("state"))
				outName.Append(n.GetSetting("state"));
			else
				Treadle.Compiler.Compilation.StateFieldName(n.Kind, n.Key, outName);
		}

		/// The fields of the Sheet's type a stateful node can keep its state in (its state type,
		/// changeable); an object's field is greyed in a static function. `outNames` holds the
		/// field names, `outLabels` the row texts.
		public void StateFieldChoices(Sheet mg, Node node, List<String> outNames, List<String> outLabels, List<String> outDisabled)
		{
			let want = StateTypeOf(StatefulKindOf(node.Kind));
			bool staticFn = mg.IsStatic;
			for (let m in mg.Doc.Members)
			{
				if (m.Kind != .Field || m.Type == null || m.Const || m.Readonly)
					continue;
				if (m.Type.ToString(.. scope String()) != want)
					continue;
				outNames.Add(new String(m.Name));
				outLabels.Add(new String(scope $"{m.Name}  ({want}{(m.Static ? ", static" : "")})"));
				outDisabled.Add(new String((staticFn && !m.Static) ? "An object's field: this function is static (make the field static)" : ""));
			}
		}

		/// The State Field row of a Gate / Do Once / Do N / Flip Flop / Multi Gate: the hidden field it
		/// uses by default (read-only, named as Language.md 5.1 says) or the visible field `set state`
		/// names, with a picker of the type's fields that fit and "Hidden (default)".
		void DrawStateFieldRow(Sheet mg, Node node, bool readOnly)
		{
			let hidden = Treadle.Compiler.Compilation.StateFieldName(node.Kind, node.Key, .. scope String());
			bool structObject = mg.Doc.Header.Kind == .Struct && !mg.IsStatic;
			StringView current = node.GetSetting("state");
			List<String> names = scope .();
			List<String> labels = scope .();
			List<String> disabled = scope .();
			defer { ClearAndDeleteItems!(names); ClearAndDeleteItems!(labels); ClearAndDeleteItems!(disabled); }
			StateFieldChoices(mg, node, names, labels, disabled);
			List<DropItem> items = scope .();
			let hiddenLabel = scope String()..AppendF("Hidden (default): {}", hidden);
			items.Add(.(hiddenLabel, "A private field the compiler adds to the type for this node",
				structObject ? "A struct's function keeps no hidden state (the value would carry it): pick a field, the function must be Mutating" : default));
			int selected = current.IsEmpty ? 0 : -1;
			for (int i < names.Count)
			{
				items.Add(.(labels[i], "Keep the state in this field (set state)", disabled[i]));
				if (names[i] == current)
					selected = i + 1;
			}
			String missing = scope .();
			if (!current.IsEmpty && selected < 0)
			{
				missing.AppendF("{}  (not a {} field of this type)", current, StateTypeOf(node.Kind));
				items.Add(.(missing, "The field `set state` names; Validate reports it"));
				selected = items.Count - 1;
			}
			String preview = scope .();
			if (current.IsEmpty)
				preview.Append(structObject ? "(pick a field)" : (StringView)hidden);
			else
				preview.Append(current);
			mStateRowShown.Set(scope $"State Field: {preview}{current.IsEmpty ? "  (hidden)" : ""}");
			let picked = PropertyGrid.DropdownRow("State Field", scope $"##nstate{node.Key}", preview, items, selected,
				scope $"The field that keeps this node's state ({StateMeaning(node.Kind)}). By default a hidden field named after the node; pick a field of the type to see or reset the state yourself.",
				default, readOnly);
			if (picked >= 0 && picked != selected && !readOnly)
			{
				BeginEdit();
				if (picked == 0)
					node.RemoveSetting("state");
				else if (picked - 1 < names.Count)
					node.SetSetting("state", names[picked - 1]);
				CommitCurrent();
			}
			PropertyGrid.InfoRow("Keeps", scope $"{StateMeaning(node.Kind)}{(current.IsEmpty && !structObject) ? ", hidden" : ""}", "What the state is, and whether it is in a hidden field");
		}

		/// The Changes row of an Open / Close / Toggle Gate or Reset node: which node it targets
		/// (Language.md 5.1: the node whose state field `set state` names; without it the only node
		/// of its kind in the Sheet, else in the type), with a picker of the candidates.
		void DrawStateTargetRow(Sheet mg, Node node, bool readOnly)
		{
			let kind = StatefulKindOf(node.Kind);
			List<(Sheet s, Node n)> all = scope .();
			for (let s in mg.Doc.Sheets)
				if (s.Graph != null)
					for (let o in s.Graph.Nodes)
						if (o.Kind == kind && !o.Disabled)
							all.Add((s, o));
			StringView current = node.GetSetting("state");
			// Resolve as the compiler does.
			(Sheet s, Node n) target = (null, null);
			String problem = scope .();
			if (!current.IsEmpty)
			{
				for (let c in all)
					if (StateFieldOf(c.n, .. scope String()) == current)
						target = c;
			}
			else
			{
				List<(Sheet s, Node n)> found = scope .();
				for (let c in all)
					if (c.s == mg)
						found.Add(c);
				if (found.IsEmpty)
					found.AddRange(all);
				if (found.Count == 1)
					target = found[0];
				else if (found.IsEmpty)
					problem.Set("none in this type");
				else
					problem.AppendF("{} could be meant: pick one", found.Count);
			}
			String kindTitle = scope .();
			Treadle.Graph.FlowMacros.GetTitle(kind, kindTitle);
			List<String> labels = scope .();
			defer { ClearAndDeleteItems!(labels); }
			List<DropItem> items = scope .();
			items.Add(.("Automatic", scope:: $"The only {kindTitle} in this Sheet, else in the type"));
			int selected = current.IsEmpty ? 0 : -1;
			for (let c in all)
			{
				let field = StateFieldOf(c.n, .. scope String());
				labels.Add(new String(scope $"{kindTitle} {c.n.Key}  \u{00B7}  {c.s.Name}  ({field})"));
				items.Add(.(labels.Back, "Change this node's state (set state names its field)"));
				if (!current.IsEmpty && target.n == c.n)
					selected = items.Count - 1;
			}
			String preview = scope .();
			if (target.n != null)
				preview.AppendF("{}{} {}  \u{00B7}  {}", current.IsEmpty ? "Automatic: " : "", kindTitle, target.n.Key, target.s.Name);
			else if (!current.IsEmpty)
				preview.AppendF("field {}", current);
			else
				preview.AppendF("Automatic: {}", problem);
			mStateRowShown.Set(scope $"Changes: {preview}");
			let picked = PropertyGrid.DropdownRow("Changes", scope $"##ntarget{node.Key}", preview, items, selected,
				scope $"The {kindTitle} this node changes", default, readOnly, default, 0, (target.n == null && current.IsEmpty) ? (StringView)problem : default);
			if (picked >= 0 && picked != selected && !readOnly)
			{
				BeginEdit();
				if (picked == 0)
					node.RemoveSetting("state");
				else
					node.SetSetting("state", StateFieldOf(all[picked - 1].n, .. scope String()));
				CommitCurrent();
			}
			if (target.n != null)
				PropertyGrid.InfoRow("State Field", StateFieldOf(target.n, .. scope String()));
		}

		void DrawMultiSelectDetails(GraphTab tab, Sheet mg)
		{
			DetailsHeader(Icon.Boxes, Look.Foreground, scope $"{tab.SelectedNodes.Count} nodes selected");
			if (!PropertyGrid.Begin("##multigrid"))
				return;
			if (PropertyGrid.Section("Selection", true))
			{
				int flow = 0;
				for (let id in tab.SelectedNodes)
				{
					let n = mg.Graph.FindNode(id);
					if (n != null && n.IsExecNode)
						flow++;
				}
				PropertyGrid.InfoRow("Flow nodes", scope $"{flow}");
				PropertyGrid.InfoRow("Value nodes", scope $"{tab.SelectedNodes.Count - flow}");
				if (PropertyGrid.ButtonRow("Comment", "Create Comment from Selection"))
					mGraphPanel.CreateComment(tab, mg.Graph);
			}
			PropertyGrid.End();
		}

		String mSheetNameEdit = new .() ~ delete _;
		String mSheetNameFor = new .() ~ delete _;

		void DrawSheetDetails(Sheet mg)
		{
			if (mg.Role == .Lambda)
			{
				DrawLambdaSheetDetails(mg);
				return;
			}
			DetailsHeader(Icon.Workflow, Look.AccentBlue, mg.Name, "Sheet");
			if (!PropertyGrid.Begin("##sheetgrid"))
				return;
			if (PropertyGrid.Section("Sheet", true))
			{
				if (mSheetNameFor != mg.Key)
				{
					mSheetNameFor.Set(mg.Key);
					mSheetNameEdit.Set(mg.Name);
				}
				if (PropertyGrid.TextRow("Name", "##sheetname", mSheetNameEdit, ?, "The Sheet's name (tab and Outline)") && mSheetNameEdit != mg.Name)
				{
					if (RenameSheet(mg, mSheetNameEdit))
						mSheetNameFor.Set(mg.Key);
					else
						mSheetNameEdit.Set(mg.Name);
				}
				String docName = scope .();
				mg.Doc.GetName(docName);
				PropertyGrid.InfoRow("Document", docName, mg.Doc.FilePath);
				PropertyGrid.InfoRow("Nodes", scope $"{mg.Graph.Nodes.Count}");
				PropertyGrid.InfoRow("Wires", scope $"{mg.Graph.Links.Count}");
			}
			if (!mg.Graph.Errors.IsEmpty || !mg.Graph.Warnings.IsEmpty)
			{
				if (PropertyGrid.Section("Problems", true, Icon.Warning))
				{
					PropertyGrid.WideRow(); // the messages span the panel, not the name column
					Gui.igIndent(10 * Look.Scale);
					for (let e in mg.Graph.Errors)
						PropertyGrid.Problem(e.Message);
					for (let w in mg.Graph.Warnings)
						PropertyGrid.Info(scope:: $"{Icon.Warning}  {w.Message}", Look.Warning, 0, true); // whole, wrapped: the node shows one line
					Gui.igUnindent(10 * Look.Scale);
				}
			}
			PropertyGrid.End();
		}
	}
}
