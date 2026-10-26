using System;
using System.Collections;
using ImGui;
using Treadle.Graph;
using Treadle.Document;
using Treadle.Model;

namespace Treadle.Editor
{
	/// What the Outline chose for Properties to show (the canvas selection takes Properties back
	/// as soon as it changes).
	enum OutlineSelection
	{
		None,
		/// The type header: Type Settings.
		TypeSettings,
		/// A member of the type (field, property, function, constructor, case).
		Member,
		/// The project file: project settings (the Project Browser's project tile).
		Project,
		/// A local variable of the Sheet in front.
		Local
	}

	/// Type Settings and the member pages: every edit of the type header and of its members goes
	/// through the open TypeDocument as one undo step (the document's snapshot holds the header,
	/// the members and the Sheets). The Outline lists the members (left), Properties shows the
	/// details of the one chosen (right).
	extension EditorApp
	{
		public OutlineSelection OutlineSel;
		int32 mSelMemberSerial;
		/// Problems chose a variable with no type (T1078): the next Type field drawn takes the keyboard.
		bool mFocusTypeField;
		/// The canvas selection when the Outline row was chosen (a different one hands Properties
		/// back to the canvas).
		int32 mSelCanvasStamp;
		/// Text being typed into Type Settings / member rows, by row id (committed on Enter or when
		/// the field is left).
		Dictionary<String, String> mTsBufs = new .() ~ DeleteDictionaryAndKeysAndValues!(_);

		int32 CanvasSelectionStamp()
		{
			let tab = CurrentTab;
			if (tab == null)
				return 0;
			int32 h = (int32)tab.SelectedNodes.Count * 7919 + (int32)tab.SelectedComments.Count * 104729;
			for (let id in tab.SelectedNodes)
				h = h * 31 + id;
			return h;
		}

		/// Shows `sel` in Properties (a member's page for `m`).
		public void SelectOutline(OutlineSelection sel, MemberDecl m = null)
		{
			OutlineSel = sel;
			mSelMemberSerial = (m != null) ? m.Serial : 0;
			mSelCanvasStamp = CanvasSelectionStamp();
			ClearTsBufs();
		}

		/// The rows' text buffers start again from the model.
		void ClearTsBufs()
		{
			for (let kv in mTsBufs)
			{
				delete kv.key;
				delete kv.value;
			}
			mTsBufs.Clear();
		}

		/// The member whose page Properties shows, or null.
		public MemberDecl SelectedMember
		{
			get
			{
				if (OutlineSel != .Member || Doc == null)
					return null;
				for (let m in Doc.Members)
					if (m.Serial == mSelMemberSerial)
						return m;
				return null;
			}
		}

		/// Whether Properties shows the Outline's choice this frame (else the canvas selection).
		bool OutlineSelectionShown()
		{
			if (OutlineSel == .None)
				return false;
			if (CanvasSelectionStamp() != mSelCanvasStamp)
			{
				OutlineSel = .None;
				return false;
			}
			if (OutlineSel == .Member && SelectedMember == null)
			{
				OutlineSel = .None;
				return false;
			}
			return true;
		}

		// ------------------------------------------------------------------ model edits

		bool BeginTypeEdit()
		{
			if (Doc == null || Doc == mEmptyDoc || !CheckWritable())
				return false;
			Doc.PushUndo();
			return true;
		}

		void EndTypeEdit()
		{
			Doc.Modified = true;
			Doc.Version++;
			mDetailsEditPushed = false;
			for (let s in Doc.Sheets)
				if (s.IsBuilt)
					Doc.InitGraph(s, s.Graph);
			UpdateTitle();
		}

		/// `baseName`, or `baseName2`, `baseName3`... whichever no member of the type has.
		static void UniqueMemberName(TypeDocument doc, StringView baseName, String outName)
		{
			outName.Set(baseName);
			for (int i = 2; doc.FindMember(outName) != null; i++)
				outName.Set(scope $"{baseName}{i}");
		}

		/// Inserts `m` after the last member of its kind (fields with the fields, cases with the
		/// cases), else at the end.
		void InsertMember(MemberDecl m)
		{
			int at = -1;
			for (int i < Doc.Members.Count)
				if (Doc.Members[i].Kind == m.Kind)
					at = i;
			if (at >= 0 && (m.Kind == .Field || m.Kind == .Case))
				Doc.Members.Insert(at + 1, m);
			else if (m.Kind == .Field || m.Kind == .Case)
			{
				// Before the first member that owns Sheets.
				int first = Doc.Members.Count;
				for (int i < Doc.Members.Count)
					if (Doc.Members[i].HasId)
					{
						first = i;
						break;
					}
				Doc.Members.Insert(first, m);
			}
			else
				Doc.Members.Add(m);
		}

		/// A new field (`name` made unique) of `type`.
		public MemberDecl AddField(StringView name, StringView type)
		{
			if (!BeginTypeEdit())
				return null;
			MemberDecl m = new .();
			m.Kind = .Field;
			UniqueMemberName(Doc, name, m.Name);
			m.Type = type.IsEmpty ? null : TypeRef.Parse(type);
			InsertMember(m);
			EndTypeEdit();
			SelectOutline(.Member, m);
			SetStatus(scope $"Added the variable {m.Name}");
			return m;
		}

		/// A new function with an empty body Sheet, opened in a tab.
		public MemberDecl AddFunctionMember(StringView name)
		{
			if (!BeginTypeEdit())
				return null;
			String n = scope .();
			UniqueMemberName(Doc, name, n);
			let s = Doc.AddFunction(n);
			EndTypeEdit();
			OpenTab(s);
			SelectOutline(.Member, s.Member);
			SetStatus(scope $"Added the function {s.Member.Name}");
			return s.Member;
		}

		/// A new auto property (a hidden field, no Sheets; untick Auto for get / set Sheets).
		public MemberDecl AddProperty(StringView name, StringView type)
		{
			if (!BeginTypeEdit())
				return null;
			MemberDecl m = new .();
			m.Kind = .Property;
			Doc.NewId(m.Id);
			UniqueMemberName(Doc, name, m.Name);
			m.Type = type.IsEmpty ? null : TypeRef.Parse(type);
			m.Auto = true;
			InsertMember(m);
			EndTypeEdit();
			SelectOutline(.Member, m);
			return m;
		}

		/// A new constructor (or the destructor) with its body Sheet.
		public MemberDecl AddCtorOrDtor(bool dtor)
		{
			if (dtor)
				for (let m in Doc.Members)
					if (m.Kind == .Dtor)
					{
						SetStatus("The type has a destructor already", .Info);
						return null;
					}
			if (!BeginTypeEdit())
				return null;
			MemberDecl m = new .();
			m.Kind = dtor ? .Dtor : .Ctor;
			Doc.NewId(m.Id);
			InsertMember(m);
			let s = Doc.NewSheet(m, .Body);
			EndTypeEdit();
			OpenTab(s);
			SelectOutline(.Member, m);
			return m;
		}

		/// A new enum case.
		public MemberDecl AddCase(StringView name)
		{
			if (!BeginTypeEdit())
				return null;
			MemberDecl m = new .();
			m.Kind = .Case;
			UniqueMemberName(Doc, name, m.Name);
			InsertMember(m);
			EndTypeEdit();
			SelectOutline(.Member, m);
			return m;
		}

		/// Removes a member and its Sheets (their tabs close).
		public void RemoveMember(MemberDecl m)
		{
			if (m == null || !BeginTypeEdit())
				return;
			String name = scope .(m.Name);
			for (int i = Doc.Sheets.Count - 1; i >= 0; i--)
			{
				let s = Doc.Sheets[i];
				if (s.Member != m)
					continue;
				for (int t = Tabs.Count - 1; t >= 0; t--)
				{
					let tab = Tabs[t];
					if (tab.Doc == Doc && tab.MethodKey == s.Key)
					{
						if (mLastActiveTab == tab)
							mLastActiveTab = null;
						if (mSelectTab == tab)
							mSelectTab = null;
						Tabs.RemoveAt(t);
						delete tab;
					}
				}
				Doc.RemoveSheet(s); // deletes the member with its last Sheet
			}
			if (Doc.Members.Contains(m))
			{
				Doc.Members.Remove(m);
				delete m;
			}
			if (ActiveTab >= Tabs.Count)
				ActiveTab = Tabs.Count - 1;
			EndTypeEdit();
			OutlineSel = .None;
			SetStatus(scope $"Removed {name}");
		}

		/// Renames a member; the Get / Set / Call nodes of this type that name it follow.
		public bool RenameMember(MemberDecl m, StringView newName)
		{
			var newName;
			newName.Trim();
			if (m == null || newName.IsEmpty || newName == m.Name)
				return false;
			let other = Doc.FindMember(newName);
			if (other != null && other != m)
			{
				SetStatus(scope $"Can't rename to '{newName}': the type has a member of that name", .Warning);
				return false;
			}
			if (!BeginTypeEdit())
				return false;
			String old = scope .(m.Name);
			m.Name.Set(newName);
			String selfName = Doc.Header.GetFullName(.. scope String());
			for (let s in Doc.Sheets)
			{
				let g = s.Graph;
				for (let n in g.Nodes)
				{
					if (n.Kind != .Get && n.Kind != .Set && n.Kind != .Call && n.Kind != .Bind)
						continue;
					for (let owner in StringView[?]("this", selfName))
					{
						String head = scope $"{owner}.{old}";
						if (n.Text == head || n.Text.StartsWith(scope $"{head}("))
						{
							n.Text.Remove(owner.Length + 1, old.Length);
							n.Text.Insert(owner.Length + 1, newName);
						}
					}
				}
				g.Version++;
			}
			for (let s in Doc.Sheets)
				s.UpdateNames();
			for (let tab in Tabs)
				if (tab.Doc == Doc)
				{
					let s = Doc.FindSheet(tab.MethodKey);
					if (s != null)
					{
						tab.Title.Clear();
						AppendSheetName(tab.Title, s);
					}
				}
			EndTypeEdit();
			return true;
		}

		/// Moves a member up (-1) or down (+1) among the members of its kind.
		public void MoveMember(MemberDecl m, int delta)
		{
			int at = Doc.Members.IndexOf(m);
			if (at < 0)
				return;
			int to = at + delta;
			while (to >= 0 && to < Doc.Members.Count && (Doc.Members[to].Kind == .Field) != (m.Kind == .Field))
				to += delta;
			if (to < 0 || to >= Doc.Members.Count || !BeginTypeEdit())
				return;
			Doc.Members.RemoveAt(at);
			Doc.Members.Insert(to, m);
			EndTypeEdit();
		}

		/// The categories the type's fields use, in the order they first appear ("Combat, Movement").
		void FieldCategories(String outText)
		{
			List<StringView> seen = scope .();
			for (let m in Doc.Members)
				if (m.Kind == .Field && m.Category != null && !seen.Contains(m.Category))
				{
					seen.Add(m.Category);
					if (!outText.IsEmpty)
						outText.Append(", ");
					outText.Append(m.Category);
				}
		}

		/// A field's Category (Outline sub-group, Node menu group); empty = none. One undo step.
		public bool SetFieldCategory(MemberDecl m, StringView category)
		{
			var category;
			category.Trim();
			if (m == null || m.Kind != .Field || category == (m.Category ?? "") || !BeginTypeEdit())
				return false;
			if (category.IsEmpty)
				DeleteAndNullify!(m.Category);
			else
				String.NewOrSet!(m.Category, category);
			EndTypeEdit();
			return true;
		}

		/// Moves an input (or a further output) up (-1) or down (+1): the Entry and Return pins and every
		/// Call of the function in the open documents follow the order (pins keep their names and so their
		/// wires); a Call's parameter types (`this.Heal(int,float)`) are written in the new order. One undo step.
		public bool MoveParam(MemberDecl m, ParamDecl p, int delta)
		{
			if (m == null || p == null)
				return false;
			let list = m.Params.Contains(p) ? m.Params : m.Outs;
			int at = list.IndexOf(p);
			int to = at + delta;
			if (at < 0 || to < 0 || to >= list.Count || !BeginTypeEdit())
				return false;
			String oldSig = ParamTypesOf(m, .. scope String());
			list.RemoveAt(at);
			list.Insert(to, p);
			SyncSheets(m);
			String newSig = ParamTypesOf(m, .. scope String());
			ReorderCalls(m, oldSig, newSig);
			EndTypeEdit();
			return true;
		}

		/// "(int,float)": the types of a function's inputs, as a Call subject names them.
		static void ParamTypesOf(MemberDecl m, String outSig)
		{
			outSig.Append('(');
			for (let p in m.Params)
			{
				if (@p.Index > 0)
					outSig.Append(',');
				p.Type?.ToString(outSig);
			}
			outSig.Append(')');
		}

		/// Calls of `m` in the open documents: the argument pins and further outputs go in the order of
		/// `m`'s inputs and outputs, and a subject naming `oldSig` names `newSig`. Another document that
		/// changes gets its own undo step.
		void ReorderCalls(MemberDecl m, StringView oldSig, StringView newSig)
		{
			String full = Doc.Header.GetFullName(.. scope String());
			for (let d in mDocs)
			{
				bool pushed = d == Doc;
				for (let s in d.Sheets)
				{
					if (!s.IsBuilt)
						continue;
					let g = s.Graph;
					for (let n in g.Nodes)
					{
						if (n.Kind != .Call && n.Kind != .Bind)
							continue;
						StringView subject = n.Text;
						let paren = subject.IndexOf('(');
						let head = (paren > 0) ? subject.Substring(0, paren) : subject;
						let sig = (paren > 0) ? subject.Substring(paren) : "";
						bool own = (d == Doc && head == scope $"this.{m.Name}") || head == scope $"{full}.{m.Name}";
						if (!own || (!sig.IsEmpty && sig != oldSig))
							continue;
						if (!pushed)
						{
							d.PushUndo();
							pushed = true;
						}
						if (!sig.IsEmpty)
						{
							String text = scope $"{head}{newSig}";
							n.Text.Set(text);
						}
						OrderPins(n.Inputs, m.Params);
						OrderPins(n.Outputs, m.Outs);
						g.Version++;
						d.Modified = true;
						d.Version++;
					}
				}
			}
		}

		/// The pins named by `order` take their slots in `pins` in that order; other pins stay put.
		static void OrderPins(List<Pin> pins, List<ParamDecl> order)
		{
			List<int> slots = scope .();
			List<Pin> named = scope .();
			for (int i < pins.Count)
				for (let p in order)
					if (pins[i].Name == p.Name)
					{
						slots.Add(i);
						break;
					}
			for (let p in order)
				for (let pin in pins)
					if (pin.Name == p.Name && !named.Contains(pin))
					{
						named.Add(pin);
						break;
					}
			for (int i < Math.Min(slots.Count, named.Count))
				pins[slots[i]] = named[i];
		}

		/// A new input (or, `isOut`, a further output) of a function or constructor.
		public void AddParam(MemberDecl m, bool isOut)
		{
			if (m == null || !BeginTypeEdit())
				return;
			ParamDecl p = new .();
			String n = scope .(isOut ? "output" : "input");
			for (int i = 2; m.FindParam(n) != null || FindOut(m, n) != null; i++)
				n.Set(scope $"{(isOut ? "output" : "input")}{i}");
			p.Name.Set(n);
			p.Type = TypeRef.Parse("int");
			if (isOut)
				m.Outs.Add(p);
			else
				m.Params.Add(p);
			if (isOut)
				EnsureReturnNode(m);
			SyncSheets(m);
			EndTypeEdit();
		}

		/// A function that returns something (a Return Type or an output) gets one Return node, right of its
		/// Entry and wired from it when the Entry's flow is free, in a Sheet that has none; part of the
		/// caller's undo step. A Sheet with a Return keeps its own; going back to nothing leaves them alone.
		public void EnsureReturnNode(MemberDecl m)
		{
			if (m == null || (m.Kind != .Function && m.Kind != .Operator) || (m.Returns == null && m.Outs.IsEmpty))
				return;
			for (let s in Doc.Sheets)
			{
				if (s.Member != m || s.Role != .Body)
					continue;
				let g = s.Graph;
				if (g == null)
					continue;
				bool has = false;
				for (let n in g.Nodes)
					has |= n.Kind == .Return;
				if (has)
					continue;
				let r = NodeFactory.Return(g, m.Returns?.ToString(.. scope String()) ?? "");
				let entry = g.Entry;
				if (entry != null)
				{
					r.X = Canvas.Snap(entry.X + 420);
					r.Y = Canvas.Snap(entry.Y);
					let then = entry.FindOutput("then");
					let rin = r.FindInput("in");
					if (then != null && rin != null && !g.IsLinked(then))
						g.Connect(then, rin);
				}
				r.HasPos = true;
				g.Version++;
			}
		}

		static ParamDecl FindOut(MemberDecl m, StringView name)
		{
			for (let p in m.Outs)
				if (p.Name == name)
					return p;
			return null;
		}

		public void RemoveParam(MemberDecl m, ParamDecl p)
		{
			if (m == null || p == null || !BeginTypeEdit())
				return;
			if (m.Params.Contains(p))
				m.Params.Remove(p);
			else
				m.Outs.Remove(p);
			delete p;
			SyncSheets(m);
			EndTypeEdit();
		}

		/// Renames an input: the Entry's pin and the `param:` Get / Set nodes follow.
		public void RenameParam(MemberDecl m, ParamDecl p, StringView newName)
		{
			var newName;
			newName.Trim();
			if (newName.IsEmpty || newName == p.Name)
				return;
			if (m.FindParam(newName) != null || FindOut(m, newName) != null)
			{
				SetStatus(scope $"Can't rename to '{newName}': the function has an input or output of that name", .Warning);
				return;
			}
			if (!BeginTypeEdit())
				return;
			String old = scope .(p.Name);
			p.Name.Set(newName);
			for (let s in Doc.Sheets)
			{
				if (s.Member != m)
					continue;
				let g = s.Graph;
				if (g.Entry != null)
				{
					let pin = g.Entry.FindOutput(old);
					if (pin != null)
					{
						pin.Name.Set(newName);
						pin.Label.Set(newName);
					}
				}
				for (let n in g.Nodes)
				{
					if ((n.Kind == .Get || n.Kind == .Set) && n.Text == scope $"param:{old}")
						n.Text.Set(scope $"param:{newName}");
					if (n.Kind == .Return)
						n.FindInput(old)?.Name.Set(newName);
				}
				g.Version++;
			}
			EndTypeEdit();
		}

		/// After the signature changed: every built Sheet of `m` gets Entry outputs for its
		/// inputs (in order, typed) and Return nodes with its result and further outputs.
		public void SyncSheets(MemberDecl m)
		{
			for (let s in Doc.Sheets)
			{
				if (s.Member != m || !s.IsBuilt)
					continue;
				let g = s.Graph;
				let entry = g.Entry;
				if (entry != null)
				{
					for (int i = entry.Outputs.Count - 1; i >= 0; i--)
					{
						let p = entry.Outputs[i];
						if (p.Kind != .Value || (s.Role == .Set && p.Name == "value"))
							continue;
						if (m.FindParam(p.Name) == null)
							g.RemovePin(p);
					}
					Doc.AddEntryParams(s, g, entry);
					// Order and types follow the inputs.
					for (let prm in m.Params)
					{
						let pin = entry.FindOutput(prm.Name);
						if (pin == null)
							continue;
						pin.SetType(TypeRef.CloneOrNull(prm.Type));
						entry.Outputs.Remove(pin);
						entry.Outputs.Add(pin);
					}
				}
				String ret = scope .();
				m.Returns?.ToString(ret);
				for (let n in g.Nodes)
				{
					if (n.Kind != .Return)
						continue;
					n.FindInput("value")?.SetTypeText(ret.IsEmpty ? "void" : ret);
					for (int i = n.Inputs.Count - 1; i >= 0; i--)
					{
						let p = n.Inputs[i];
						if (p.Kind == .Value && p.Name != "value" && FindOut(m, p.Name) == null)
							g.RemovePin(p);
					}
					for (let o in m.Outs)
					{
						var p = n.FindInput(o.Name);
						if (p == null)
						{
							p = g.AddDataIn(n, o.Name, o.Name);
							p.Role = .Arg;
						}
						p.SetType(TypeRef.CloneOrNull(o.Type));
					}
					// The further outputs in the function's order (Move Up / Down).
					OrderPins(n.Inputs, m.Outs);
				}
				g.Version++;
			}
		}

		// ------------------------------------------------------------------ rows

		/// The row's text buffer (follows the model while the field is not being edited).
		String TsBuf(StringView id, StringView current)
		{
			if (mTsBufs.TryGetValueAlt(id, let buf))
				return buf;
			String b = new .(current);
			mTsBufs[new String(id)] = b;
			return b;
		}

		/// A text row over `current`; true (with the text in `outValue`) when an edit is committed.
		bool TsText(StringView label, StringView id, StringView current, String outValue, StringView tip = default, StringView hint = default)
		{
			let buf = TsBuf(id, current);
			// F2 (RenameSelection): the Name row takes the keyboard once.
			if (mFocusNameRow && label == "Name")
			{
				mFocusNameRow = false;
				PropertyGrid.FocusNext = true;
				NameRowsFocused++;
			}
			bool done = PropertyGrid.TextRow(label, id, buf, ?, tip, hint);
			bool active = Gui.igIsItemActive();
			// The Outline row shows what is typed here; while the row is renamed in place, this field
			// shows what is typed there (one buffer).
			if (active)
				mTsActiveId.Set(id);
			else if (mTsActiveId == id)
				mTsActiveId.Clear();
			if (!done && !active && buf != current && mIrId != id)
				buf.Set(current);
			if (done && buf != current)
			{
				outValue.Set(buf);
				return true;
			}
			return false;
		}

		/// A value row in the widget of its type, the same one an unwired pin of that type has on the canvas
		/// (PinValueEditor): a checkbox for a bool, a whole-number field for an integer (its range checked), a
		/// decimal field for a float, the enum's dropdown, a text field for a String, one character for a
		/// char; any other type a text row. True (with the literal in `outValue`) when a value was committed;
		/// the caller makes the undo step.
		bool TsValueRow(StringView label, StringView id, StringView typeName, StringView current, String outValue, StringView tip = default)
		{
			let vk = PinValue.KindOf(typeName, current, "", Language.Types);
			if (typeName.IsEmpty || !PinValueEditor.Handles(vk) || mGraphPanel == null)
				return TsText(label, id, current, outValue, tip);
			PropertyGrid.Row(label, tip, Theme.TypeColor(typeName));
			String value = scope .(current);
			mGraphPanel.mPinEditor.ButtonColor = 0;
			int32 pinId = (int32)((uint32)id.GetHashCode() | 0x40000000);
			let undoBefore = EditDoc?.UndoStamp ?? 0;
			if (!mGraphPanel.mPinEditor.Draw(this, null, pinId, typeName, value, false, vk, Gui.igGetContentRegionAvail().x))
				return false;
			// The editor began an edit of the document in front; the caller's BeginTypeEdit makes the step.
			if (EditDoc != null && EditDoc.UndoStamp != undoBefore)
				EditDoc.DropLastUndo();
			if (value == current)
				return false;
			outValue.Set(value);
			return true;
		}

		/// The types the type picker offers: the primitives, the common vector primitives (`float4`,
		/// `int32x4`; any other vector name can be typed), then the project's types.
		void PickableTypes(List<String> outTypes)
		{
			for (let t in StringView[?]("bool", "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "float", "double", "char8", "char32", "String", "StringView"))
				outTypes.Add(new String(t));
			for (let t in Treadle.Model.VectorTypes.Common)
				outTypes.Add(new String(t));
			for (let t in ProjectTypes.Types)
				outTypes.Add(new String(t.FullName));
		}

		/// A type row: the searchable dropdown of the types legal in `slot` (TypePickers.bf); a value
		/// slot also takes a spelled type (`Core.List<int>`). True (with the type in `outValue`) when
		/// another type was chosen.
		bool TsType(StringView label, StringView id, StringView current, String outValue, StringView tip = default, TypeSlot slot = .Value, StringView noneLabel = default)
		{
			return TsTypeRow(label, id, current, outValue, slot, tip, noneLabel);
		}

		/// A row with a text field and a dropdown of `choices` next to it (and, `removable`, an X that
		/// sets `remove`). True (with the text in `outValue`) when a choice was picked or a text typed.
		bool TsPick(StringView label, StringView id, StringView current, String outValue, List<String> choices, StringView tip, StringView hint,
			StringView pickTip, uint32 swatch, out bool remove, bool removable = false, StringView removeTip = default)
		{
			remove = false;
			PropertyGrid.Row(label, tip, swatch);
			let buf = TsBuf(id, current);
			float bw = Gui.igGetFrameHeight() + 4 * Look.Scale;
			float xw = removable ? bw : 0;
			Gui.igSetNextItemWidth(Math.Max(40 * Look.Scale, Gui.igGetContentRegionAvail().x - bw - xw - (removable ? 8 : 4) * Look.Scale));
			bool done = PropertyGrid.Text(id, buf, ?, false, null, hint);
			bool active = Gui.igIsItemActive();
			Gui.SameLine(0, 4 * Look.Scale);
			List<DropItem> items = scope .();
			for (let t in choices)
				items.Add(.(t));
			let picked = PropertyGrid.Dropdown(scope $"{id}pick", "", items, -1, bw, pickTip);
			if (removable)
			{
				Gui.SameLine(0, 4 * Look.Scale);
				remove = Gui.Button(scope $"{Icon.X}##{id}x", .(bw - 4 * Look.Scale, 0));
				if (Gui.igIsItemHovered(0) && !removeTip.IsEmpty)
					Gui.Tooltip(removeTip);
				if (remove)
					return false;
			}
			if (picked >= 0)
			{
				outValue.Set(choices[picked]);
				buf.Set(choices[picked]);
				return choices[picked] != current;
			}
			if (!done && !active && buf != current)
				buf.Set(current);
			if (done && buf != current)
			{
				outValue.Set(buf);
				return true;
			}
			return false;
		}

		static StringView[?] sAccessNames = .("Public", "Protected", "Private", "Internal");

		static int32 AccessIndex(Access a)
		{
			switch (a)
			{
			case .Protected: return 1;
			case .Private: return 2;
			case .Internal: return 3;
			default: return 0;
			}
		}

		static Access AccessOf(int32 i)
		{
			switch (i)
			{
			case 1: return .Protected;
			case 2: return .Private;
			case 3: return .Internal;
			default: return .Unset;
			}
		}

		/// A checkbox row bound to a model flag (one undo step per toggle).
		bool TsCheck(StringView label, StringView id, ref bool value, StringView tip = default)
		{
			bool v = value;
			if (!PropertyGrid.CheckRow(label, id, ref v, tip))
				return false;
			if (!BeginTypeEdit())
				return false;
			value = v;
			EndTypeEdit();
			return true;
		}

		/// A doc row bound to a model doc string (null = none).
		void TsDoc(StringView id, ref String doc)
		{
			String v = scope .();
			if (TsText("Doc", id, (doc != null) ? (StringView)doc : "", v, "What it is for; shown in tooltips"))
			{
				if (!BeginTypeEdit())
					return;
				if (v.IsEmpty)
					DeleteAndNullify!(doc);
				else
				{
					if (doc == null)
						doc = new String();
					doc.Set(v);
				}
				EndTypeEdit();
			}
		}

		// ------------------------------------------------------------------ Type Settings

		static StringView[?] sKindNames = .("Class", "Struct", "Interface", "Enum", "Delegate", "Extension");

		/// Type Settings: the kind's own section first (a class's or a struct's Inheritance, an enum's
		/// Underlying Type, a delegate's Signature, an extension's Extends), then the Type section, Uses,
		/// Generic Parameters and Attributes.
		void DrawTypeSettings()
		{
			let h = Doc.Header;
			String full = h.GetFullName(.. scope String());
			DetailsHeader(Icon.Settings, Look.AccentBlue, full, "Type Settings");
			if (!PropertyGrid.Begin("##typesettings"))
				return;
			String v = scope .();
			switch (h.Kind)
			{
			case .Class, .Struct, .Interface:
				if (PropertyGrid.Section("Inheritance", true))
					DrawInheritanceRows(h);
			case .Enum:
				if (PropertyGrid.Section("Enum", true))
				{
					v.Clear();
					if (TsTypeRow("Underlying Type", "##tsunder", h.Underlying?.ToString(.. scope String()) ?? "", v, .Integer, "The integer type the cases are stored as", "int (default)") && BeginTypeEdit())
					{
						delete h.Underlying;
						h.Underlying = v.IsEmpty ? null : TypeRef.Parse(v);
						EndTypeEdit();
					}
				}
			case .Extension:
				if (PropertyGrid.Section("Extension", true))
				{
					List<String> types = scope .();
					defer { ClearAndDeleteItems!(types); }
					ExtendableTypes(types);
					String cur = h.Extends?.ToString(.. scope String()) ?? "";
					PropertyGrid.Row("Extends", "The type this extension adds members to: a class, a struct or an enum of the project, a dependency, the core library or a C import. A generic type is extended with its parameters (Core.List<T>).", cur.IsEmpty ? 0 : Theme.TypeColor(cur));
					if (mFocusTsId == "##tsextends")
					{
						// New Extension: the picker opens on its own, its search field focused.
						mFocusTsId.Clear();
						TypeCombo.TestOpen.Set("##tsextends");
					}
					v.Clear();
					if (NameComboFor("##tsextends", cur, types, v))
						SetTypeExtends(v);
					if (cur.IsEmpty)
						PropertyGrid.InfoRow("", "Choose the type it extends", default, Look.Warning, 0, true);
				}
			case .Delegate:
				if (PropertyGrid.Section("Signature", true))
					DrawDelegateSignatureRows(h);
			}
			if (PropertyGrid.Section("Type", true))
			{
				if (TsText("Name", "##tsname", h.Name, v, "The type's name, also its file's name: renaming it renames the file and the references in the project's other types"))
					RenameType(Doc, v);
				int32 kind = (int32)h.Kind;
				if (PropertyGrid.ComboRow("Kind", "##tskind", ref kind, sKindNames, "Class: a reference type with inheritance. Struct: a value type. Enum: named cases. Interface: members a class promises.") && BeginTypeEdit())
				{
					h.Kind = (TypeKind)kind;
					EndTypeEdit();
				}
				v.Clear();
				if (TsText("Namespace", "##tsns", h.Namespace, v, "Dotted name the type is reached by (Game.Core)") && BeginTypeEdit())
				{
					h.Namespace.Set(v);
					EndTypeEdit();
				}
				int32 access = AccessIndex(h.Access);
				if (PropertyGrid.ComboRow("Access", "##tsaccess", ref access, sAccessNames, "Who can use the type") && BeginTypeEdit())
				{
					h.Access = AccessOf(access);
					EndTypeEdit();
				}
				if (h.Kind == .Class)
				{
					TsCheck("Abstract", "##tsabstract", ref h.Abstract, "Cannot be constructed; derived classes can");
					TsCheck("Sealed", "##tssealed", ref h.Sealed, "No class may derive from it");
				}
				if (h.Kind == .Class || h.Kind == .Struct)
					TsCheck("Static", "##tsstatic", ref h.Static, "Only static members: a node library");
				TsDoc("##tsdoc", ref h.Doc);
			}
			if (PropertyGrid.Section("Uses", !h.Uses.IsEmpty))
				DrawUsesRows(h);
			if (h.Kind != .Enum && h.Kind != .Delegate && PropertyGrid.Section("Generic Parameters", !h.Generics.IsEmpty))
				DrawGenericRows(h);
			if (PropertyGrid.Section("Attributes", !h.Attrs.IsEmpty))
				DrawAttrRows(h.Attrs, "type");
			if ((h.Kind == .Class || h.Kind == .Struct || h.Kind == .Enum) && PropertyGrid.Section("Layout", false)) DrawLayoutSection(h); // TypeLayoutSection.bf
			PropertyGrid.End();
		}

		/// `Zoo.Animal` -> `Animal` (a generic one is kept whole: `Core.List<int>`).
		public static void ShortTypeName(StringView name, String outText)
		{
			let dot = name.LastIndexOf('.');
			outText.Append((dot >= 0 && !name.Contains('<')) ? name.Substring(dot + 1) : name);
		}

		/// "Dog : Animal, IPet": the type's name and what it derives from and implements (short names).
		public static void InheritanceLine(TypeDecl h, String outText)
		{
			outText.Append(h.Name);
			bool first = true;
			if (h.Kind == .Class && h.Base != null && !h.Base.IsNone)
			{
				outText.Append(" : ");
				ShortTypeName(h.Base.ToString(.. scope String()), outText);
				first = false;
			}
			if (h.Kind == .Class || h.Kind == .Struct || h.Kind == .Interface)
				for (let i in h.Implements)
				{
					outText.Append(first ? " : " : ", ");
					ShortTypeName(i.ToString(.. scope String()), outText);
					first = false;
				}
		}

		/// Inheritance: a class's Base Class (a dropdown of the classes it may derive from, None first)
		/// with the "Dog : Animal" line under it, then the interfaces (an interface's: the ones it
		/// extends), each a dropdown of interfaces with an X, and Add Interface.
		void DrawInheritanceRows(TypeDecl h)
		{
			String v = scope .();
			if (h.Kind == .Class)
			{
				String cur = h.Base?.ToString(.. scope String()) ?? "";
				if (TsTypeRow("Base Class", "##tsbase", cur, v, .BaseClass, "The class this one derives from: a class of the project, the core library or a dependency that is not sealed or static (none: Object)", "None (Object)"))
					SetTypeBase(v);
			}
			StringView what = (h.Kind == .Interface) ? "Extends" : "Interfaces";
			for (let t in h.Implements)
			{
				Gui.PushID((int32)(200 + @t.Index));
				String cur = t.ToString(.. scope String());
				PropertyGrid.Row((@t.Index == 0) ? what : "", "An interface this type implements", Theme.TypeColor(cur));
				float bw = Gui.igGetFrameHeight() + 4 * Look.Scale;
				v.Clear();
				bool picked = TypeComboFor("##tsimpl", cur, v, .Interface, default, Math.Max(40 * Look.Scale, Gui.igGetContentRegionAvail().x - bw - 4 * Look.Scale));
				Gui.SameLine(0, 4 * Look.Scale);
				bool remove = Gui.Button(scope $"{Icon.X}##rm", .(bw - 4 * Look.Scale, 0));
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip("Remove this interface");
				Gui.PopID();
				if (remove)
				{
					SetTypeInterface(@t.Index, "");
					break;
				}
				if (picked && !v.IsEmpty)
				{
					SetTypeInterface(@t.Index, v);
					break;
				}
			}
			PropertyGrid.Row(h.Implements.IsEmpty ? what : "", "Add an interface this type implements");
			v.Clear();
			if (TypeComboFor("##tsaddimpl", "", v, .Interface, default, -1, default, "Add an interface") && !v.IsEmpty)
				SetTypeInterface(-1, v);
			String line = scope .();
			InheritanceLine(h, line);
			PropertyGrid.InfoRow("", line, default, Look.ForegroundDim, 0, true);
		}

		/// The class's `base` (empty: none, Object). One undo step.
		public bool SetTypeBase(StringView type)
		{
			var type;
			type.Trim();
			let h = Doc.Header;
			if (type == (h.Base?.ToString(.. scope String()) ?? "") || !BeginTypeEdit())
				return false;
			DeleteAndNullify!(h.Base);
			if (!type.IsEmpty)
				h.Base = TypeRef.Parse(type);
			EndTypeEdit();
			return true;
		}

		/// Sets the interface at `index` (empty: removes it; -1: adds `type`, once). One undo step.
		public bool SetTypeInterface(int index, StringView type)
		{
			let h = Doc.Header;
			if (index < 0)
			{
				for (let i in h.Implements)
					if (i.ToString(.. scope String()) == type)
						return false;
				if (type.IsEmpty || !BeginTypeEdit())
					return false;
				h.Implements.Add(TypeRef.Parse(type));
				EndTypeEdit();
				return true;
			}
			if (index >= h.Implements.Count || !BeginTypeEdit())
				return false;
			delete h.Implements[index];
			if (type.IsEmpty)
				h.Implements.RemoveAt(index);
			else
				h.Implements[index] = TypeRef.Parse(type);
			EndTypeEdit();
			return true;
		}

		/// Generic Parameters: each parameter's constraints as removable rows and an Add Constraint
		/// dropdown (class, struct, operator==, the interfaces and the classes), then Add / Remove.
		void DrawGenericRows(TypeDecl h)
		{
			for (let gp in h.Generics)
			{
				Gui.PushID((int32)(100 + @gp.Index));
				int removeAt = -1;
				for (let c in gp.Constraints)
				{
					String text = scope .();
					if (c.Type != null)
						c.Type.ToString(text);
					else if (c.Word != null)
						text.Append(c.Word);
					PropertyGrid.Row((@c.Index == 0) ? gp.Name : "", "A constraint on the type the user chooses");
					float bw = Gui.igGetFrameHeight() + 4 * Look.Scale;
					PropertyGrid.Box(text, Math.Max(40 * Look.Scale, Gui.igGetContentRegionAvail().x - bw - 4 * Look.Scale), (c.Type != null) ? Theme.TypeColor(text) : 0);
					Gui.SameLine(0, 4 * Look.Scale);
					if (Gui.Button(scope $"{Icon.X}##gc{@c.Index}", .(bw - 4 * Look.Scale, 0)))
						removeAt = @c.Index;
				}
				PropertyGrid.Row(gp.Constraints.IsEmpty ? gp.Name : "", "Add a constraint: class, struct, operator==, an interface or a base class");
				List<String> choices = scope .();
				defer { ClearAndDeleteItems!(choices); }
				for (let w in StringView[?]("class", "struct", "operator=="))
					choices.Add(new String(w));
				String self = Doc.Header.GetFullName(.. scope String());
				TypeChoices(.Interface, self, choices);
				TypeChoices(.BaseClass, self, choices);
				String add = scope .();
				bool added = NameComboFor("##gcadd", "", choices, add, -1, "Add a constraint") && !add.IsEmpty;
				Gui.PopID();
				if (removeAt >= 0 && BeginTypeEdit())
				{
					let c = gp.Constraints[removeAt];
					delete c.Type;
					delete c.Word;
					gp.Constraints.RemoveAt(removeAt);
					EndTypeEdit();
					return;
				}
				if (added && BeginTypeEdit())
				{
					gp.AddConstraint(add);
					EndTypeEdit();
					return;
				}
			}
			if (PropertyGrid.ButtonRow("", scope $"{Icon.Plus} Add Generic Parameter", "A type the user of this type chooses (T)") && BeginTypeEdit())
			{
				GenericParam gp = new .();
				gp.Name.Set((h.Generics.Count == 0) ? "T" : scope $"T{h.Generics.Count + 1}");
				h.Generics.Add(gp);
				EndTypeEdit();
			}
			if (!h.Generics.IsEmpty && PropertyGrid.ButtonRow("", scope $"{Icon.Trash2} Remove the Last One") && BeginTypeEdit())
			{
				delete h.Generics.PopBack();
				EndTypeEdit();
			}
		}

		/// The types an extension can extend (Language.md 4.4): the classes, structs and enums of the
		/// project and those the front end knows (a dependency's, the core library's, a C import's),
		/// a generic one with its own parameters (`Core.List<T>`). Not the type itself.
		public void ExtendableTypes(List<String> outTypes)
		{
			RefreshProjectTypes();
			String self = Doc?.Header.GetFullName(.. scope String()) ?? "";
			void Add(StringView name, List<String> generics)
			{
				String t = scope .(name);
				if (generics != null && !generics.IsEmpty)
				{
					t.Append('<');
					for (let g in generics)
						t.AppendF("{}{}", (@g.Index > 0) ? "," : "", g);
					t.Append('>');
				}
				if (name != self && !outTypes.ContainsAlt(t))
					outTypes.Add(new String(t));
			}
			for (let t in ProjectTypes.Types)
				if (t.Kind == .Class || t.Kind == .Struct || t.Kind == .Enum)
					Add(t.FullName, t.Generics);
			let comp = FrontEnd?.Last;
			if (comp != null)
				for (let s in comp.Table.Types)
				{
					if (s.Kind != .Class && s.Kind != .Struct && s.Kind != .Enum)
						continue;
					List<String> generics = scope .();
					defer { ClearAndDeleteItems!(generics); }
					for (let g in s.Generics)
						generics.Add(new String(g.Name));
					Add(s.FullName, generics);
				}
			outTypes.Sort(scope (a, b) => a.CompareTo(b, true));
		}

		/// The extension's `extends` (empty: none). One undo step.
		public bool SetTypeExtends(StringView type)
		{
			var type;
			type.Trim();
			let h = Doc.Header;
			if (type == (h.Extends?.ToString(.. scope String()) ?? "") || !BeginTypeEdit())
				return false;
			DeleteAndNullify!(h.Extends);
			if (!type.IsEmpty)
				h.Extends = TypeRef.Parse(type);
			EndTypeEdit();
			return true;
		}

		/// A delegate type's `signature`: the result (`void` or empty: none) and the input types. One undo step.
		public bool SetDelegateSignature(StringView returns, Span<StringView> inputs)
		{
			String text = scope .();
			text.Append(returns.IsEmpty ? "void" : returns);
			text.Append('(');
			for (let t in inputs)
				text.AppendF("{}{}", (@t.Index > 0) ? "," : "", t);
			text.Append(')');
			return SetDelegateSignatureText(text);
		}

		/// `signature` as the file spells it (`int(int,float)`); text it does not read is kept as written.
		public bool SetDelegateSignatureText(StringView textIn)
		{
			var text = textIn;
			text.Trim();
			let h = Doc.Header;
			String now = scope .();
			if (h.Signature != null)
			{
				if (h.Signature.Kind == .Raw)
					now.Append(h.Signature.Name);
				else
					h.Signature.AppendSignature(now);
			}
			String wanted = scope .();
			for (let c in text.RawChars)
				if (c != ' ')
					wanted.Append(c);
			if (wanted == now || !BeginTypeEdit())
				return false;
			DeleteAndNullify!(h.Signature);
			if (!wanted.IsEmpty)
				h.Signature = TypeRef.ParseSignature(wanted);
			EndTypeEdit();
			return true;
		}

		/// A delegate type's Signature section: Returns, one row per input type (an X removes it) and
		/// Add Input; a signature the rows cannot show is one text row.
		void DrawDelegateSignatureRows(TypeDecl h)
		{
			String v = scope .();
			let sig = h.Signature;
			if (sig != null && sig.Kind == .Raw)
			{
				if (TsText("Signature", "##tssigraw", sig.Name, v, "The result and the input types: int(int,float)", "void()"))
					SetDelegateSignatureText(v);
				PropertyGrid.InfoRow("", "Not read as a signature: write it as Result(Input, Input)", default, Look.Warning, 0, true);
				return;
			}
			String ret = scope .();
			if (sig?.Element != null)
				sig.Element.ToString(ret);
			else
				ret.Append("void");
			List<String> inputs = scope .();
			defer { ClearAndDeleteItems!(inputs); }
			if (sig?.Args != null)
				for (let a in sig.Args)
					inputs.Add(a.ToString(.. new String()));
			void Commit()
			{
				List<StringView> views = scope .();
				for (let s in inputs)
					views.Add(s);
				SetDelegateSignature(ret, views);
			}
			v.Clear();
			if (TsType("Returns", "##tssigret", ret, v, "What a delegate of this type returns (void: nothing)", .Result))
			{
				ret.Set(v.IsEmpty ? "void" : v);
				Commit();
				return;
			}
			for (int i < inputs.Count)
			{
				Gui.PushID((int32)(600 + i));
				v.Clear();
				PropertyGrid.Row(scope $"Input {i + 1}", "The type of this input (a Lambda of this type names it a, b, ...)", Theme.TypeColor(inputs[i]));
				float bw = Gui.igGetFrameHeight() + 4 * Look.Scale;
				let picked = TypeComboFor(scope $"##tssigin{i}", inputs[i], v, .Value, default, Math.Max(40 * Look.Scale, Gui.igGetContentRegionAvail().x - bw - 4 * Look.Scale));
				Gui.SameLine(0, 4 * Look.Scale);
				bool remove = Gui.Button(scope $"{Icon.X}##rmin", .(bw - 4 * Look.Scale, 0));
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip("Remove this input");
				Gui.PopID();
				if (remove)
				{
					delete inputs[i];
					inputs.RemoveAt(i);
					Commit();
					return;
				}
				if (picked && !v.IsEmpty)
				{
					inputs[i].Set(v);
					Commit();
					return;
				}
			}
			if (inputs.IsEmpty)
				PropertyGrid.InfoRow("Inputs", "none");
			if (PropertyGrid.ButtonRow("", scope $"{Icon.Plus} Add Input", "A new int input (change its type above)"))
			{
				inputs.Add(new String("int"));
				Commit();
			}
		}

		/// The namespaces the project and the front end know (for the Uses rows' dropdown).
		void KnownNamespaces(List<String> outNames)
		{
			RefreshProjectTypes();
			for (let t in ProjectTypes.Types)
				if (!t.Namespace.IsEmpty && !outNames.ContainsAlt(t.Namespace))
					outNames.Add(new String(t.Namespace));
			let comp = FrontEnd?.Last;
			if (comp != null)
				for (let s in comp.Table.Types)
					if (!s.Namespace.IsEmpty && !outNames.ContainsAlt(s.Namespace))
						outNames.Add(new String(s.Namespace));
			outNames.Sort(scope (a, b) => a.CompareTo(b, true));
		}

		/// `uses` line `index` set to `ns` (empty removes it); `index` = the count adds one. One undo step.
		public bool SetUses(int index, StringView nsIn)
		{
			var ns = nsIn;
			ns.Trim();
			let h = Doc.Header;
			if (index < 0 || index > h.Uses.Count || (index == h.Uses.Count && ns.IsEmpty) || (index < h.Uses.Count && h.Uses[index] == ns))
				return false;
			for (let u in h.Uses)
				if (@u.Index != index && u == ns)
				{
					SetStatus(scope $"The type uses {ns} already", .Info);
					return false;
				}
			if (!BeginTypeEdit())
				return false;
			if (index == h.Uses.Count)
				h.Uses.Add(new String(ns));
			else if (ns.IsEmpty)
				{ delete h.Uses[index]; h.Uses.RemoveAt(index); }
			else
				h.Uses[index].Set(ns);
			EndTypeEdit();
			return true;
		}

		/// The Uses section: one row per `uses` namespace (an X removes it) and Add Namespace.
		void DrawUsesRows(TypeDecl h)
		{
			List<String> names = scope .();
			defer { ClearAndDeleteItems!(names); }
			KnownNamespaces(names);
			String v = scope .();
			for (int i < h.Uses.Count)
			{
				Gui.PushID((int32)(700 + i));
				v.Clear();
				bool remove;
				let picked = TsPick((i == 0) ? "Namespace" : "", scope $"##tsuses{i}", h.Uses[i], v, names,
					"Names of this namespace's types work without it in this type's Sheets and settings (Language.md 4.4: an extension's names resolve here first)",
					"Game.Core", "Choose a namespace", 0, out remove, true, "Stop using this namespace");
				Gui.PopID();
				if (remove)
				{
					SetUses(i, "");
					return;
				}
				if (picked)
				{
					SetUses(i, v);
					return;
				}
			}
			if (PropertyGrid.ButtonRow("", scope $"{Icon.Plus} Add Namespace", "A namespace whose types this type names without the namespace"))
			{
				String ns = scope .("Core");
				for (let n in names)
					if (!h.Uses.Contains(n))
					{
						ns.Set(n);
						break;
					}
				SetUses(h.Uses.Count, ns);
			}
		}

		/// The attributes the compiler reads (Language-Guide.md, "Attributes"): on a type, then on a member.
		static StringView[?] sTypeAttrs = .("CRepr", "Packed", "Align", "Flags", "Copyable", "Obsolete");
		static StringView[?] sMemberAttrs = .("Export", "Import", "Kernel", "NoDiscard", "Obsolete", "ExpandEnumAsFlow", "Event");
		static StringView[?] sAttrTips = .(
			"CRepr: lay the struct out as C does (C imports, Export)",
			"Packed: no padding between the struct's fields",
			"Align(n): align the struct to n bytes (16 at most)",
			"Flags: an enum of bit flags (Has Flag node)",
			"Copyable: copies of this struct with a destructor are meant (no warning)",
			"Obsolete(\"why\"): a warning wherever it is used");
		static StringView[?] sMemberAttrTips = .(
			"Export(\"name\"): a C symbol of a static function (a library project exports it)",
			"Import(\"lib\", \"name\"): a static function without a Sheet that calls a C symbol",
			"Kernel: a GPU compute kernel (GPU-Compute.md)",
			"NoDiscard: the result is meant to be read",
			"Obsolete(\"why\"): a warning wherever it is used",
			"ExpandEnumAsFlow: one flow output per case of the returned enum at each call",
			"Event: a delegate field with Add / Remove / Invoke nodes");

		/// Attribute rows (`Name arg arg`, one per row, an X removes it) and Add Attribute, a list of the
		/// attributes the compiler reads.
		void DrawAttrRows(List<AttrDecl> attrs, StringView idBase)
		{
			String v = scope .();
			for (let a in attrs)
			{
				Gui.PushID((int32)(200 + @a.Index));
				String text = scope .(a.Name);
				for (let arg in a.Args)
					text.AppendF(" {}", arg);
				v.Clear();
				PropertyGrid.Row("Attribute", "Name and arguments: Export \"name\"");
				String id = scope $"##{idBase}attr{@a.Index}";
				let buf = TsBuf(id, text);
				float bw = Gui.igGetFrameHeight() + 4 * Look.Scale;
				Gui.igSetNextItemWidth(Math.Max(40 * Look.Scale, Gui.igGetContentRegionAvail().x - bw - 4 * Look.Scale));
				bool done = PropertyGrid.Text(id, buf, ?);
				if (!done && !Gui.igIsItemActive() && buf != text)
					buf.Set(text);
				Gui.SameLine(0, 4 * Look.Scale);
				bool remove = Gui.Button(scope $"{Icon.X}##rmattr", .(bw - 4 * Look.Scale, 0));
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip(scope $"Remove [{a.Name}]");
				if (done && buf != text)
					v.Set(buf);
				if ((remove || (done && buf != text)) && BeginTypeEdit())
				{
					if (remove || v.IsEmpty)
					{
						attrs.RemoveAt(@a.Index);
						delete a;
						mTsBufs.TryGetValueAlt(id, let b2);
						b2?.Clear();
					}
					else
					{
						a.Name.Clear();
						ClearAndDeleteItems!(a.Args);
						for (var part in v.Split(' '))
						{
							if (part.IsEmpty)
								continue;
							if (a.Name.IsEmpty)
								a.Name.Set(part);
							else
								a.Args.Add(new String(part));
						}
					}
					EndTypeEdit();
					Gui.PopID();
					break;
				}
				Gui.PopID();
			}
			// Add Attribute: the ones the compiler reads for a type or a member (another can be typed in the row).
			bool onType = idBase == "type";
			List<DropItem> items = scope .();
			if (onType)
				for (int i < sTypeAttrs.Count)
					items.Add(.(sTypeAttrs[i], sAttrTips[i]));
			else
				for (int i < sMemberAttrs.Count)
					items.Add(.(sMemberAttrs[i], sMemberAttrTips[i]));
			PropertyGrid.Row("", "Add an attribute the compiler reads");
			let picked = PropertyGrid.Dropdown("##addattr", scope $"{Icon.Plus} Add Attribute", items, -1);
			if (picked >= 0 && BeginTypeEdit())
			{
				AttrDecl a = new .();
				a.Name.Set(items[picked].Label);
				attrs.Add(a);
				EndTypeEdit();
			}
		}

		// ------------------------------------------------------------------ member pages

		static StringView[?] sOwnerNames = .("(default)", "Owned", "Reference", "Appended", "Pointer", "Custom");
		static StringView[?] sModeNames = .("value", "ref", "out", "in");

		void DrawMemberPage(MemberDecl m)
		{
			String display = m.GetDisplayName(.. scope String());
			StringView what;
			switch (m.Kind)
			{
			case .Field: what = "Variable";
			case .Property: what = "Property";
			case .Function: what = "Function";
			case .Ctor: what = "Constructor";
			case .Dtor: what = "Destructor";
			case .Operator: what = "Operator";
			case .Case: what = "Case";
			}
			DetailsHeader((m.Kind == .Field || m.Kind == .Property) ? Icon.Variable : Icon.SquareFunction,
				(m.Type != null) ? Theme.TypeColor(m.Type.ToString(.. scope String())) : Look.AccentBlue, display, what);
			if (!PropertyGrid.Begin("##memberpage"))
				return;
			String v = scope .();
			String id = scope $"{m.Serial}";
			if (PropertyGrid.Section(what, true))
			{
				if (m.Kind != .Ctor && m.Kind != .Dtor && TsText("Name", scope $"##mname{id}", m.Name, v))
					RenameMember(m, v);
				if (m.Kind == .Field || m.Kind == .Property)
				{
					v.Clear();
					if (mFocusTypeField)
					{
						Gui.igSetKeyboardFocusHere(0);
						mFocusTypeField = false;
					}
					if (TsType("Type", scope $"##mtype{id}", m.Type?.ToString(.. scope String()) ?? "", v) && BeginTypeEdit())
					{
						delete m.Type;
						m.Type = v.IsEmpty ? null : TypeRef.Parse(v);
						EndTypeEdit();
					}
				}
				if (m.Kind == .Field)
				{
					v.Clear();
					if (TsValueRow("Default Value", scope $"##minit{id}", m.Type?.ToString(.. scope String()) ?? "", m.Init ?? "", v, "The value it starts with: a literal (0, \"text\", true), an enum case (.Red), default or null") && BeginTypeEdit())
					{
						if (v.IsEmpty)
							DeleteAndNullify!(m.Init);
						else
							String.NewOrSet!(m.Init, v);
						EndTypeEdit();
					}
				}
				if (m.Kind == .Field) StorageRowField(m); // LivesIn.bf
				if (m.Kind == .Case)
				{
					v.Clear();
					if (TsText("Value", scope $"##mcase{id}", m.CaseValue ?? "", v, "The case's integer value (empty: the next one)") && BeginTypeEdit())
					{
						if (v.IsEmpty)
							DeleteAndNullify!(m.CaseValue);
						else
							String.NewOrSet!(m.CaseValue, v);
						EndTypeEdit();
					}
				}
				if (m.Kind != .Case && m.Kind != .Dtor)
				{
					int32 access = AccessIndex(m.Access);
					if (PropertyGrid.ComboRow("Access", scope $"##maccess{id}", ref access, sAccessNames) && BeginTypeEdit())
					{
						m.Access = AccessOf(access);
						EndTypeEdit();
					}
				}
				if (m.Kind == .Field || m.Kind == .Property || m.Kind == .Function || m.Kind == .Ctor)
					TsCheck("Static", scope $"##mstatic{id}", ref m.Static, "Belongs to the type, not to each object");
				if (m.Kind == .Field)
				{
					v.Clear();
					String cats = scope .();
					FieldCategories(cats);
					if (TsText("Category", scope $"##mcat{id}", m.Category ?? "", v,
						cats.IsEmpty ? "The group the Outline and the Node menu list it under (empty: none)" : scope $"The group the Outline and the Node menu list it under (empty: none). In use: {cats}", "none"))
						SetFieldCategory(m, v);
					TsCheck("Const", scope $"##mconst{id}", ref m.Const, "A compile-time value");
					TsCheck("Read Only", scope $"##mro{id}", ref m.Readonly, "Set only by constructors");
					int32 owner = (int32)m.Owner;
					if (PropertyGrid.ComboRow("Ownership", scope $"##mowner{id}", ref owner, sOwnerNames, "Who deletes the object the field holds") && BeginTypeEdit())
					{
						m.Owner = (Ownership)owner;
						EndTypeEdit();
					}
				}
				if (m.Kind == .Property)
				{
					bool auto = m.Auto;
					if (PropertyGrid.CheckRow("Auto", scope $"##mauto{id}", ref auto, "A hidden field; untick for get / set Sheets") && BeginTypeEdit())
					{
						m.Auto = auto;
						if (!auto && Doc.FindSheet(scope $"get:{m.Id}") == null)
						{
							Doc.NewSheet(m, .Get);
							Doc.NewSheet(m, .Set);
						}
						EndTypeEdit();
					}
				}
				if (m.Kind == .Function)
				{
					// A class function's inheritance (Overrides.bf); a struct's, an interface's or an
					// extension's functions bind statically and have none.
					if (Doc.Header.Kind == .Class && !m.Static)
					{
						DrawInheritanceSegments(m);
						if (m.Override)
							TsCheck("Sealed", scope $"##msealed{id}", ref m.Sealed, "No class below may override it again");
					}
					TsCheck("Pure", scope $"##mpure{id}", ref m.Pure, "No side effects: its Calls are value nodes");
					TsCheck("Unsafe", scope $"##munsafe{id}", ref m.Unsafe, "Pointer nodes allowed in its Sheet");
					if (Doc.Header.Kind == .Struct)
						TsCheck("Mutating", scope $"##mmut{id}", ref m.Mutating, "Changes the struct's own fields");
					TsCheck("Inline", scope $"##minline{id}", ref m.Inline);
				}
				if (m.Kind == .Ctor)
				{
					int32 chain = (int32)m.Chain;
					StringView[?] chains = .("None", "Base Constructor", "This Constructor");
					if (PropertyGrid.ComboRow("Runs First", scope $"##mchain{id}", ref chain, chains, "A constructor this one runs before its own Sheet") && BeginTypeEdit())
					{
						m.Chain = (CtorChain)chain;
						EndTypeEdit();
					}
				}
				TsDoc(scope $"##mdoc{id}", ref m.Doc);
			}
			if (m.Kind == .Function || m.Kind == .Ctor || m.Kind == .Operator)
			{
				if (PropertyGrid.Section("Inputs", true, Icon.ArrowRight))
					DrawParamRows(m, m.Params, false);
				if (m.Kind != .Ctor && PropertyGrid.Section("Outputs", true, Icon.ArrowLeft))
				{
					v.Clear();
					if (TsType("Return Type", scope $"##mret{id}", m.Returns?.ToString(.. scope String()) ?? "", v, "What the function returns (None: nothing)", .Result, "None") && BeginTypeEdit())
					{
						delete m.Returns;
						m.Returns = (v.IsEmpty || v == "void") ? null : TypeRef.Parse(v);
						EnsureReturnNode(m);
						SyncSheets(m);
						EndTypeEdit();
					}
					DrawParamRows(m, m.Outs, true);
				}
			}
			if (m.Kind == .Case && PropertyGrid.Section("Payload", true))
			{
				for (let p in m.Payload)
				{
					Gui.PushID((int32)(300 + @p.Index));
					v.Clear();
					if (TsType(p.Name, scope $"##mpay{id}_{@p.Index}", p.Type?.ToString(.. scope String()) ?? "", v, "The type of this payload field (Remove: the field goes)", .Value, "Remove") && BeginTypeEdit())
					{
						if (v.IsEmpty)
						{
							m.Payload.RemoveAt(@p.Index);
							delete p;
						}
						else
						{
							delete p.Type;
							p.Type = TypeRef.Parse(v);
						}
						EndTypeEdit();
						Gui.PopID();
						break;
					}
					Gui.PopID();
				}
				if (PropertyGrid.ButtonRow("", scope $"{Icon.Plus} Add Payload Field") && BeginTypeEdit())
				{
					ParamDecl p = new .();
					p.Name.Set(scope $"value{m.Payload.Count}");
					p.Type = TypeRef.Parse("int");
					m.Payload.Add(p);
					EndTypeEdit();
				}
			}
			if (m.Kind != .Case && PropertyGrid.Section("Attributes", !m.Attrs.IsEmpty))
				DrawAttrRows(m.Attrs, id);
			if (PropertyGrid.Section("Member", true))
			{
				if (PropertyGrid.ButtonRow("", scope $"{Icon.ChevronUp} Move Up"))
					MoveMember(m, -1);
				if (PropertyGrid.ButtonRow("", scope $"{Icon.ChevronDown} Move Down"))
					MoveMember(m, 1);
				if (PropertyGrid.ButtonRow("", scope $"{Icon.Trash2} Delete {what}", default, true))
					RemoveMember(m);
			}
			PropertyGrid.End();
		}

		/// One row per input / output: its name in the label column, its type (and how it is
		/// passed) in the value column, and a button that removes it; an Add button under them.
		void DrawParamRows(MemberDecl m, List<ParamDecl> list, bool outs)
		{
			String v = scope .();
			for (let p in list)
			{
				Gui.PushID((int32)((outs ? 500 : 400) + @p.Index));
				let nameBuf = TsBuf(scope $"##pn{m.Serial}_{outs}_{@p.Index}", p.Name);
				// Two or more: stacked Move Up / Move Down arrows in front of the name.
				int move = 0;
				bool nameDone = (list.Count > 1) ? PropertyGrid.NameBoxRowMove("##pname", nameBuf, "name", @p.Index > 0, @p.Index < list.Count - 1, out move) :
					PropertyGrid.NameBoxRow("##pname", nameBuf, "name");
				bool nameActive = Gui.igIsItemActive();
				// Value column: type field, passing, remove.
				float bw = Gui.igGetFrameHeight() + 4 * Look.Scale;
				// The passing dropdown gives way first in a narrow panel, so the remove button stays in view.
				float modeW = outs ? 0 : Math.Clamp(Gui.igGetContentRegionAvail().x - bw - 52 * Look.Scale, 44 * Look.Scale, 74 * Look.Scale);
				String typeNow = p.Type?.ToString(.. scope String()) ?? "";
				String typePicked = scope .();
				bool typeDone = TypeComboFor("##ptype", typeNow, typePicked, .Value, default, Math.Max(40 * Look.Scale, Gui.igGetContentRegionAvail().x - bw - modeW - 8 * Look.Scale));
				if (!outs)
				{
					Gui.SameLine(0, 4 * Look.Scale);
					int32 mode = (p.Mode == .Ref) ? 1 : ((p.Mode == .Out) ? 2 : ((p.Mode == .In) ? 3 : 0));
					if (PropertyGrid.Combo("##pmode", ref mode, sModeNames, modeW) && BeginTypeEdit())
					{
						p.Mode = (mode == 1) ? .Ref : ((mode == 2) ? .Out : ((mode == 3) ? .In : .Unset));
						SyncSheets(m);
						EndTypeEdit();
					}
				}
				Gui.SameLine(0, 4 * Look.Scale);
				bool remove = Gui.Button(Icon.X, .(bw - 4 * Look.Scale, 0));
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip(outs ? "Remove this output" : "Remove this input");
				if (remove)
				{
					RemoveParam(m, p);
					Gui.PopID();
					break;
				}
				if (move != 0)
				{
					MoveParam(m, p, move);
					// The rows' text buffers follow the model again (they are keyed by position).
					ClearTsBufs();
					Gui.PopID();
					break;
				}
				if (nameDone && nameBuf != p.Name)
				{
					v.Set(nameBuf);
					if (outs)
					{
						if (BeginTypeEdit())
						{
							String old = scope .(p.Name);
							p.Name.Set(v);
							for (let s in Doc.Sheets)
								if (s.Member == m)
									for (let n in s.Graph.Nodes)
										if (n.Kind == .Return)
											n.FindInput(old)?.Name.Set(v);
							SyncSheets(m);
							EndTypeEdit();
						}
					}
					else
						RenameParam(m, p, v);
				}
				else if (!nameActive && nameBuf != p.Name)
					nameBuf.Set(p.Name);
				if (typeDone && typePicked != typeNow && BeginTypeEdit())
				{
					delete p.Type;
					p.Type = typePicked.IsEmpty ? null : TypeRef.Parse(typePicked);
					SyncSheets(m);
					EndTypeEdit();
				}
				Gui.PopID();
			}
			if (PropertyGrid.ButtonRow("", outs ? scope $"{Icon.Plus} Add Output" : scope $"{Icon.Plus} Add Input"))
				AddParam(m, outs);
		}

		/// The page of a local variable of the Sheet in front.
		void DrawLocalPage(Sheet mg, LocalDecl l)
		{
			String type = l.GetTypeText(.. scope String());
			DetailsHeader(Icon.Variable, Theme.TypeColor(type), l.Name, scope $"Local Variable of {mg.Name}");
			if (!PropertyGrid.Begin("##localpage"))
				return;
			String v = scope .();
			if (PropertyGrid.Section("Local Variable", true))
			{
				if (TsText("Name", "##lname", l.Name, v) && v != l.Name)
					RenameLocal(mg, l, v);
				v.Clear();
				if (mFocusTypeField)
				{
					Gui.igSetKeyboardFocusHere(0);
					mFocusTypeField = false;
				}
				if (TsType("Type", "##ltype", type, v) && BeginTypeEdit())
				{
					delete l.Type;
					l.Type = v.IsEmpty ? null : TypeRef.Parse(v);
					for (let n in mg.Graph.Nodes)
						if ((n.Kind == .Get || n.Kind == .Set) && n.Text == scope $"local:{l.Name}")
						{
							n.Result?.SetTypeText(v);
							n.FindInput("value")?.SetTypeText(v);
						}
					mg.Graph.Version++;
					EndTypeEdit();
				}
				v.Clear();
				if (TsText("Initial Value", "##linit", l.Init ?? "", v, "The value it starts with (empty: the type's default)") && BeginTypeEdit())
				{
					if (v.IsEmpty)
						DeleteAndNullify!(l.Init);
					else
						String.NewOrSet!(l.Init, v);
					EndTypeEdit();
				}
				int32 owner = (int32)l.Owner;
				if (PropertyGrid.ComboRow("Ownership", "##lowner", ref owner, sOwnerNames, "Owned: deleted when the function returns") && BeginTypeEdit())
				{
					l.Owner = (Ownership)owner;
					EndTypeEdit();
				}
				StorageRowLocal(l); // LivesIn.bf
			}
			PropertyGrid.End();
		}
	}
}
