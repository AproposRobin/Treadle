using System;
using System.Collections;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Model;

namespace Treadle.Editor
{
	/// Extract to Function (Editor-Model.md 6; other node editors' "collapse to function"): the selected
	/// nodes move into a new function of the type and a Call of it takes their place, wired as they were.
	/// Values wired into the selection become the function's inputs, values wired out of it its return
	/// value (one) or further outputs (several); the selection needs one flow entry and at most one flow
	/// exit, or no flow nodes at all (a Pure function). A Get of a local or an input of this function in
	/// the selection stays here and feeds the Call; a Set of one is refused (the new function cannot
	/// write this function's variables). One undo step.
	extension EditorApp
	{
		/// Why the last Extract to Function was refused ("" when it was not).
		public String ExtractRefusal = new .() ~ delete _;

		/// The new function's input or output name made from a pin: its label or name in lower camel
		/// case, letters and digits only, unique among `taken`.
		static void ExtractName(Pin p, List<String> taken, String outName)
		{
			ExtractName(p.Label.IsEmpty ? (StringView)p.Name : (StringView)p.Label, taken, outName);
		}

		static bool Taken(List<String> taken, StringView name)
		{
			for (let t in taken)
				if (t == name)
					return true;
			return false;
		}

		/// `text` in lower camel case, letters and digits only, unique among `taken`.
		static void ExtractName(StringView text, List<String> taken, String outName)
		{
			var src = text;
			if (src.StartsWith("case:"))
				src = src.Substring(5);
			bool upper = false;
			for (let c in src.RawChars)
			{
				if (c.IsLetterOrDigit || c == '_')
				{
					if (outName.IsEmpty && c.IsDigit)
						outName.Append('v');
					outName.Append(upper ? c.ToUpper : c);
					upper = false;
				}
				else if (!outName.IsEmpty)
					upper = true;
			}
			if (outName.IsEmpty)
				outName.Append("value");
			if (outName[0].IsUpper)
				outName[0] = outName[0].ToLower;
			if (outName == "in" || outName == "then" || outName == "receiver" || outName == "result")
				outName.Append("Value");
			String baseName = scope .(outName);
			for (int i = 2; Taken(taken, outName); i++)
				outName.Set(scope $"{baseName}{i}");
			taken.Add(new String(outName));
		}

		/// Lambda Sheets of the Lambda nodes in `nodes`, and theirs, in `ownerSheet`'s member.
		void CollectLambdaSheets(TypeDocument doc, Sheet ownerSheet, List<Node> nodes, List<Sheet> outSheets)
		{
			for (let n in nodes)
			{
				if (n.Kind != .Lambda || n.Key.IsEmpty)
					continue;
				let ls = FindLambdaSheet(doc, ownerSheet, n.Key);
				if (ls == null || outSheets.Contains(ls))
					continue;
				outSheets.Add(ls);
				if (ls.IsBuilt)
				{
					List<Node> inner = scope .();
					inner.AddRange(ls.Graph.Nodes);
					CollectLambdaSheets(doc, ls, inner, outSheets);
				}
			}
		}

		bool ExtractRefuse(StringView why)
		{
			ExtractRefusal.Set(why);
			SetStatus(scope $"Extract to Function: {why}", .Warning);
			return false;
		}

		/// Extract to Function on the selection of `tab` (context menu, Ctrl+Shift+E). The new function
		/// is placed after this Sheet's member, its Name in edit. False with the reason (status line and
		/// `ExtractRefusal`) when the selection cannot be extracted.
		public bool ExtractToFunction(GraphTab tab)
		{
			ExtractRefusal.Clear();
			let mg = (tab != null) ? tab.Doc.FindSheet(tab.MethodKey) : null;
			if (mg == null || mg.Member == null)
				return ExtractRefuse("open a function's Sheet first");
			if (!CheckWritable() || mg.Graph.ReadOnly)
				return false;
			if (mg.Role == .Lambda)
				return ExtractRefuse("a Lambda's Sheet keeps its nodes (a new function would not see its inputs and captures)");
			let doc = mg.Doc;
			let g = mg.Graph;
			ExpandGroupsInSelection(tab, g);
			List<Node> sel = scope .();
			for (let id in tab.SelectedNodes)
			{
				let n = g.FindNode(id);
				if (n != null)
					sel.Add(n);
			}
			if (sel.IsEmpty)
				return ExtractRefuse("select the nodes to move into the new function first");
			// A Get of a local or an input stays here and feeds the Call (it becomes an input).
			for (int i = sel.Count - 1; i >= 0; i--)
			{
				let n = sel[i];
				if (n.Kind == .Get && (n.Text.StartsWith("local:") || n.Text.StartsWith("param:")))
					sel.RemoveAt(i);
			}
			if (sel.IsEmpty)
				return ExtractRefuse("only Gets of locals or inputs are selected: they stay with this function");
			for (let n in sel)
			{
				String title = n.GetTitle(.. scope String());
				switch (n.Kind)
				{
				case .Entry: return ExtractRefuse("the Entry node stays: select the nodes after it");
				case .Return: return ExtractRefuse(scope $"{title} ends this function: leave it out of the selection");
				case .ChainCtor: return ExtractRefuse(scope $"{title} belongs to this constructor");
				case .Break, .Continue: return ExtractRefuse(scope $"{title} leaves a loop of this Sheet: leave it out, or select the whole loop");
				case .Unknown: return ExtractRefuse(scope $"{title} is a node this editor does not know");
				case .Set:
					if (n.Text.StartsWith("local:"))
						return ExtractRefuse(scope $"{title} writes '{n.Text.Substring(6)}', a local of {mg.Name}: the new function cannot write it (make it a field, or leave the Set out)");
					if (n.Text.StartsWith("param:"))
						return ExtractRefuse(scope $"{title} writes the input '{n.Text.Substring(6)}' of {mg.Name}: the new function cannot write it");
				default:
				}
			}
			// Lambda nodes take their Sheets along; such a Sheet must not read this function's locals.
			List<Sheet> lambdas = scope .();
			CollectLambdaSheets(doc, mg, sel, lambdas);
			for (let ls in lambdas)
				for (let n in ls.Graph.Nodes)
					if ((n.Kind == .Get || n.Kind == .Set) && n.Text.StartsWith("local:"))
						return ExtractRefuse(scope $"a Lambda in the selection uses the local '{n.Text.Substring(6)}' of {mg.Name}");

			HashSet<Node> inSel = scope .();
			for (let n in sel)
				inSel.Add(n);
			bool pure = true;
			for (let n in sel)
				if (NodeFactory.HasFlow(n))
					pure = false;

			// The wires that cross the selection's edge.
			List<Link> flowIn = scope .();
			List<Link> flowOut = scope .();
			List<Link> valueIn = scope .();
			List<Link> valueOut = scope .();
			for (let l in g.Links)
			{
				bool fromIn = inSel.Contains(l.From.Owner);
				bool toIn = inSel.Contains(l.To.Owner);
				if (fromIn == toIn)
					continue;
				if (l.From.Kind == .Flow)
					(toIn ? flowIn : flowOut).Add(l);
				else
					(toIn ? valueIn : valueOut).Add(l);
			}
			// One flow entry: the flow input the outside wires lead to, else the one flow node of the
			// selection that nothing inside runs.
			Pin head = null;
			for (let l in flowIn)
			{
				if (head != null && head != l.To)
					return ExtractRefuse("the flow enters the selection at more than one node: a function has one entry");
				head = l.To;
			}
			if (head == null && !pure)
			{
				for (let n in sel)
				{
					let pin = n.ExecIn;
					if (pin == null)
						continue;
					bool fromInside = false;
					for (let l in g.Links)
						if (l.To == pin && inSel.Contains(l.From.Owner))
							fromInside = true;
					if (fromInside)
						continue;
					if (head != null)
						return ExtractRefuse("the selection has more than one start of flow: a function has one entry");
					head = pin;
				}
			}
			Pin exit = null;
			for (let l in flowOut)
			{
				if (exit != null && exit != l.From)
					return ExtractRefuse("the flow leaves the selection at more than one pin: a function call continues from one Then");
				exit = l.From;
			}

			// Inputs: one per outside pin feeding the selection; outputs: one per inside pin read outside.
			List<Pin> inSources = scope .();
			for (let l in valueIn)
				if (!inSources.Contains(l.From))
					inSources.Add(l.From);
			List<Pin> outSources = scope .();
			for (let l in valueOut)
				if (!outSources.Contains(l.From))
					outSources.Add(l.From);
			if (pure && outSources.IsEmpty)
				return ExtractRefuse("nothing outside reads the selected value nodes: a Pure function needs an output wired out of the selection");
			if (!pure && exit == null && !outSources.IsEmpty)
				return ExtractRefuse("values leave the selection but its flow does not: wire the selection's last Then onward first");
			Pin TypePin(List<Link> links, Pin source, bool fromSide)
			{
				if (!source.TypeName.IsEmpty)
					return source;
				for (let l in links)
					if (l.From == source && !(fromSide ? l.To : l.From).TypeName.IsEmpty)
						return fromSide ? l.To : l.From;
				return null;
			}
			for (let src in inSources)
			{
				let tp = TypePin(valueIn, src, true);
				if (tp == null)
				{
					String title = src.Owner.GetTitle(.. scope String());
					return ExtractRefuse(scope $"the type of the value from {title} is not known yet: Validate (Shift+F7), then try again");
				}
			}
			for (let src in outSources)
			{
				let tp = TypePin(valueOut, src, true);
				if (tp == null)
				{
					String title = src.Owner.GetTitle(.. scope String());
					return ExtractRefuse(scope $"the type of the value {title} gives out is not known yet: Validate (Shift+F7), then try again");
				}
			}

			// ---- The new function: one undo step from here.
			if (Doc != doc)
				Doc = doc;
			doc.PushUndo();
			MemberDecl m = new .();
			m.Kind = .Function;
			doc.NewId(m.Id);
			UniqueMemberName(doc, "NewFunction", m.Name);
			m.Static = mg.Member.Static;
			m.Pure = pure;
			List<String> taken = scope .();
			defer { ClearAndDeleteItems!(taken); }
			for (let src in inSources)
			{
				ParamDecl p = new .();
				// Named after the pin it feeds when that has a name (an Entry output, a literal has none).
				Pin namePin = src;
				for (let l in valueIn)
					if (l.From == src)
					{
						namePin = (src.Owner.Kind == .Entry || src.Owner.Kind == .Get) ? src : l.To;
						break;
					}
				if (src.Owner.Kind == .Get)
				{
					String vn = scope .();
					src.Owner.GetSubjectName(vn);
					ExtractName(StringView(vn), taken, p.Name);
				}
				else
					// An Entry output is named by its input's name; another pin by its label.
					ExtractName((namePin.Owner.Kind == .Entry) ? (StringView)namePin.Name : (namePin.Label.IsEmpty ? (StringView)namePin.Name : (StringView)namePin.Label), taken, p.Name);
				p.Type = TypeRef.Parse(TypePin(valueIn, src, true).TypeName);
				m.Params.Add(p);
			}
			List<String> outNames = scope .();
			defer { ClearAndDeleteItems!(outNames); }
			for (let src in outSources)
			{
				let typeText = TypePin(valueOut, src, true).TypeName;
				if (outSources.Count == 1)
				{
					m.Returns = TypeRef.Parse(typeText);
					outNames.Add(new String("result"));
					continue;
				}
				ParamDecl o = new .();
				ExtractName(src, taken, o.Name);
				o.Type = TypeRef.Parse(typeText);
				m.Outs.Add(o);
				outNames.Add(new String(o.Name));
			}
			int at = doc.Members.IndexOf(mg.Member);
			doc.Members.Insert((at >= 0) ? at + 1 : doc.Members.Count, m);
			let ns = doc.NewSheet(m, .Body);
			let ng = ns.Graph;

			// Bounds of the selection: the new Sheet keeps the positions, the Call goes in the middle.
			float minX = float.MaxValue, minY = float.MaxValue, maxX = float.MinValue, maxY = float.MinValue;
			for (let n in sel)
			{
				mGraphPanel.GetNodeSize(n.Id, var w, var h);
				if (w <= 0)
					LayeredArrange.Estimate(n, out w, out h);
				minX = Math.Min(minX, n.X);
				minY = Math.Min(minY, n.Y);
				maxX = Math.Max(maxX, n.X + w);
				maxY = Math.Max(maxY, n.Y + h);
			}

			// Move the nodes (keys, settings, pins and positions kept; new runtime ids in the new graph).
			Dictionary<Pin, Pin> pinMap = scope .();
			for (let n in sel)
			{
				let c = Graph.CloneNodeExact(n);
				c.Id = ng.NewId();
				for (int side < 2)
					for (let p in (side == 0) ? c.Inputs : c.Outputs)
					{
						p.Id = ng.NewId();
						let orig = (side == 0) ? n.Inputs[@p.Index] : n.Outputs[@p.Index];
						pinMap[orig] = p;
					}
				c.HasPos = true;
				ng.Nodes.Add(c);
			}
			for (let l in g.Links)
				if (inSel.Contains(l.From.Owner) && inSel.Contains(l.To.Owner))
					ng.AddLinkRaw(pinMap[l.From], pinMap[l.To]);
			let entry = ng.Entry;
			entry.X = minX - 320;
			entry.Y = minY;
			entry.HasPos = true;
			if (head != null)
				ng.AddLinkRaw(entry.Then, pinMap[head]);
			for (let src in inSources)
			{
				let param = m.Params[@src.Index];
				let ep = entry.FindOutput(param.Name);
				for (let l in valueIn)
					if (l.From == src && ep != null)
						ng.AddLinkRaw(ep, pinMap[l.To]);
			}
			if (!outSources.IsEmpty || pure)
			{
				String ret = scope .();
				m.Returns?.ToString(ret);
				let rn = NodeFactory.Return(ng, ret.IsEmpty ? "void" : ret);
				rn.X = maxX + 120;
				rn.Y = minY;
				rn.HasPos = true;
				if (exit != null)
					ng.AddLinkRaw(pinMap[exit], rn.ExecIn);
				else if (pure)
					ng.AddLinkRaw(entry.Then, rn.ExecIn);
			}
			SyncSheets(m); // the Return's further outputs
			Node retNode = null;
			for (let n in ng.Nodes)
				if (n.Kind == .Return)
					retNode = n;
			if (retNode != null)
				for (let src in outSources)
				{
					let name = outNames[@src.Index];
					let into = (name == "result" && outSources.Count == 1) ? retNode.FindInput("value") : retNode.FindInput(name);
					if (into != null)
						ng.AddLinkRaw(pinMap[src], into);
				}
			// The Lambda Sheets go with their nodes.
			for (let ls in lambdas)
			{
				ls.Member = m;
				ls.UpdateNames();
				if (ls.IsBuilt)
					doc.InitGraph(ls, ls.Graph);
			}

			// ---- This Sheet: the Call in the selection's place, wired as the selection was.
			List<(Pin outside, Pin inside, bool flow, bool into)> edges = scope .();
			for (let l in flowIn)
				edges.Add((l.From, l.To, true, true));
			for (let l in flowOut)
				edges.Add((l.To, l.From, true, false));
			for (let l in valueIn)
				edges.Add((l.From, l.To, false, true));
			for (let l in valueOut)
				edges.Add((l.To, l.From, false, false));
			for (let n in sel)
				g.RemoveNode(n);
			let call = NodeMenu.CallOwn(g, m, doc.Header.Name, !pure);
			call.X = Math.Round((minX + maxX) * 0.5f - 90);
			call.Y = Math.Round((minY + maxY) * 0.5f - 40);
			call.HasPos = true;
			List<Pin> wiredIn = scope .();
			for (let e in edges)
			{
				if (e.flow)
				{
					if (e.into && call.ExecIn != null)
						g.AddLinkRaw(e.outside, call.ExecIn);
					else if (!e.into && call.Then != null)
						g.AddLinkRaw(call.Then, e.outside);
					continue;
				}
				if (e.into)
				{
					let idx = inSources.IndexOf(e.outside);
					if (idx < 0 || wiredIn.Contains(e.outside))
						continue;
					wiredIn.Add(e.outside);
					let pin = call.FindInput(m.Params[idx].Name);
					if (pin != null)
						g.AddLinkRaw(e.outside, pin);
				}
				else
				{
					let idx = outSources.IndexOf(e.inside);
					if (idx < 0)
						continue;
					let name = outNames[idx];
					let pin = (outSources.Count == 1) ? call.FindOutput("result") : call.FindOutput(name);
					if (pin != null)
						g.AddLinkRaw(pin, e.outside);
				}
			}
			KeyAssigner.Assign(ng);
			doc.Commit(ns);
			doc.Modified = true;
			doc.Version++;
			for (let s in doc.Sheets)
				if (s.IsBuilt)
					doc.InitGraph(s, s.Graph);
			tab.SelectOnly(call.Id);
			CommitCurrent();
			mLastExtracted = m.Serial;
			SetStatus(scope $"Extracted {sel.Count} node{(sel.Count == 1) ? "" : "s"} into {m.Name}: type its name", .Info, false);
			SelectOutline(.Member, m);
			FocusNameField();
			return true;
		}

		/// The member the last Extract to Function made (its Serial; the self test).
		public int32 mLastExtracted;
	}
}
