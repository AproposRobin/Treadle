using System;
using System.Collections;
using System.IO;
using Treadle.Graph;
using Treadle.Language;
using Treadle.Model;

namespace Treadle.Document
{
	struct NodePos
	{
		public float X;
		public float Y;
		/// Width the user gave the node (0 = its natural width).
		public float W;
	}

	/// One Sheet of a type: the graph of a function body, a property accessor or a lambda body
	/// (Graph-Format.md 3.1, `sheet`). The graph is made on first use and then kept: the same graph
	/// object stays live across commits and undo / redo.
	class Sheet
	{
		/// `<memberId>`, `get:<id>`, `set:<id>` or `lambda:<nodeId>` (what the layout file and
		/// messages refer to).
		public String Key = new .() ~ delete _;
		/// What the tab and the Outline show.
		public String Name = new .() ~ delete _;
		public TypeDocument Doc;
		/// The member that owns the Sheet (owned by the document).
		public MemberDecl Member;
		public SheetRole Role;
		/// Lambda Sheets: the Lambda node's id.
		public String LambdaNode = new .() ~ delete _;
		/// Comment lines and unknown records around the `sheet` record.
		public RecordExtras Extras = new .() ~ delete _;
		Graph mGraph ~ delete _;

		public bool Graphable => true;
		public bool IsBroken => false;
		public bool IsBuilt => mGraph != null;
		public bool IsStatic => (Member != null && Member.Static) || (Doc != null && Doc.Header.Static);
		public int32 Line => 0;

		public Graph Graph
		{
			get
			{
				if (mGraph == null)
				{
					mGraph = Doc.BuildGraph(this);
					Doc.InitGraph(this, mGraph);
				}
				return mGraph;
			}
		}

		/// Takes the built graph out (caller owns it).
		public Graph DetachGraph()
		{
			let g = mGraph;
			mGraph = null;
			return g;
		}

		/// Installs an existing graph (takes ownership).
		public void AttachGraph(Graph graph)
		{
			if (mGraph == graph)
				return;
			delete mGraph;
			mGraph = graph;
			if (mGraph != null)
				Doc.InitGraph(this, mGraph);
		}

		/// The Sheet key of a member's Sheet.
		public static void MakeKey(MemberDecl m, SheetRole role, StringView lambdaNode, String outKey)
		{
			switch (role)
			{
			case .Body: outKey.Append(m.Id);
			case .Get: outKey.AppendF("get:{}", m.Id);
			case .Set: outKey.AppendF("set:{}", m.Id);
			case .Lambda: outKey.AppendF("lambda:{}", lambdaNode);
			}
		}

		/// Refreshes Key and Name from the member (after a rename or a new id).
		public void UpdateNames()
		{
			if (Member == null)
				return;
			Key.Clear();
			MakeKey(Member, Role, LambdaNode, Key);
			Name.Clear();
			Member.GetDisplayName(Name);
			switch (Role)
			{
			case .Get: Name.Append(" (get)");
			case .Set: Name.Append(" (set)");
			case .Lambda: Name.Append(" > Lambda");
			default:
			}
			if (mGraph != null)
			{
				mGraph.MethodKey.Set(Key);
				mGraph.MethodName.Set(Name);
			}
		}
	}

	/// One undo step: the type header, the members, every built graph and the layout.
	class Snapshot
	{
		public List<(String key, Graph graph)> Graphs = new .() ~ { for (let g in _) { delete g.key; delete g.graph; } delete _; };
		public Dictionary<String, NodePos> Layout = new .() ~ DeleteDictionaryAndKeys!(_);
		public List<GraphComment> Comments = new .() ~ DeleteContainerAndItems!(_);
		public List<GraphReroute> Reroutes = new .() ~ DeleteContainerAndItems!(_);
		public TypeDecl Header ~ delete _;
		public List<MemberDecl> Members = new .() ~ DeleteContainerAndItems!(_);
		/// The Sheet records in order (member serial, role, lambda node): members and Sheets added
		/// or removed since come back to this list on undo.
		public List<(int32 member, SheetRole role, String lambda)> SheetRecs = new .() ~ { for (let r in _) delete r.lambda; delete _; };
		public int32 Version;
	}

	/// A type file (Graph-Format.md 3): the type header, its members, the Sheets of those members,
	/// and the layout sidecar (positions, comment boxes, knots, views). The format is read and
	/// written by the language's codec (`IGraphCodec`); the document owns the model, the undo
	/// history and the dirty / conflict state.
	class TypeDocument
	{
		/// The language context of the document's workspace. Not owned. Null: no services.
		public LanguageContext Language;
		public String FilePath = new .() ~ delete _;

		public this()
		{
		}

		public this(LanguageContext language)
		{
			Language = language;
		}

		/// The `type` record.
		public TypeDecl Header = new .() ~ delete _;
		/// Fields, cases, properties, functions, constructors, destructors, operators in
		/// declaration order.
		public List<MemberDecl> Members = new .() ~ DeleteContainerAndItems!(_);
		/// Lines before the `type` record (Leading) and comment lines at the end of the file (Trailing).
		public RecordExtras FileExtras = new .() ~ delete _;
		/// The format version in the file's header (docs/Format-Stability.md 2).
		public int32 FormatVersion = 1;
		/// The older version the file was migrated from on load (0: none). The first save writes
		/// `<file>.v<old>.bak` once, then the file at the current version.
		public int32 MigratedFrom;
		/// The same for the layout sidecar.
		public int32 LayoutMigratedFrom;
		/// Set by Load (not cleared with the content): the file's header is newer than this build.
		/// The document is read-only: Save, edits and Build are refused (Format-Stability.md 2).
		public int32 NewerVersion;
		/// The reader accepts a newer header (Load sets it: the editor's read-only open).
		public bool OpenNewerReadOnly;
		public bool IsNewerFormat => NewerVersion > 0;
		/// Unknown records and properties kept from the file (a newer format): they are written
		/// back in place; the editor does not know what they mean.
		public int32 UnknownCount;

		public List<Sheet> Sheets = new .() ~ DeleteContainerAndItems!(_);
		/// "SheetKey|NodeId" -> position (the layout file's `node` lines).
		public Dictionary<String, NodePos> Layout = new .() ~ DeleteDictionaryAndKeys!(_);
		/// Comment boxes of every Sheet (layout only).
		public List<GraphComment> Comments = new .() ~ DeleteContainerAndItems!(_);
		/// Knots on wires (layout only).
		public List<GraphReroute> Reroutes = new .() ~ DeleteContainerAndItems!(_);
		/// Node comment bubbles pinned to a readable size (layout only; not part of undo).
		public List<BubblePin> BubblePins = new .() ~ DeleteContainerAndItems!(_);
		/// Views of each Sheet: N = 0 is the last view (`view`), 1-9 the saved ones (layout only).
		public List<SavedView> Views = new .() ~ DeleteContainerAndItems!(_);
		/// "SheetKey|NodeId" of nodes drawn compact (`collapsed`).
		public List<String> Collapsed = new .() ~ DeleteContainerAndItems!(_);
		/// Layout lines this editor does not know, per Sheet key ("" = outside any sheet).
		public List<(String sheet, String line)> LayoutUnknown = new .() ~ { for (let l in _) { delete l.sheet; delete l.line; } delete _; };

		public int32 Version;
		public bool Modified;
		/// Layout changed since the last save.
		public bool LayoutTouched;
		public bool LayoutErrorReported;
		public String LastError = new .() ~ delete _;
		public DateTime DiskTime;
		bool mHasDiskStamp;
		public bool ExternalChange;
		public int32 IndexedVersion = -1;
		public int32 BuildVersion = -1;
		/// Messages the last load left (shown once).
		public List<String> Messages = new .() ~ DeleteContainerAndItems!(_);

		List<Snapshot> mUndo = new .() ~ DeleteContainerAndItems!(_);
		List<Snapshot> mRedo = new .() ~ DeleteContainerAndItems!(_);
		const int MaxUndo = 200;
		public int32 UndoStamp;

		public bool NeedsSave => Modified;
		public bool CanUndo => !mUndo.IsEmpty;
		public bool CanRedo => !mRedo.IsEmpty;

		/// The layout sidecar of a type file: `<file>.layout` (`Player.treadle.layout`).
		public static void LayoutPathOf(StringView path, String outPath)
		{
			outPath.AppendF("{}.layout", path);
		}

		/// The file name without its extension.
		public void GetName(String outName)
		{
			if (FilePath.IsEmpty)
			{
				outName.Append(Header.Name.IsEmpty ? "Untitled" : (StringView)Header.Name);
				return;
			}
			Path.GetFileNameWithoutExtension(FilePath, outName);
		}

		/// Clears everything the file defines (before a read).
		public void ClearContent()
		{
			ClearAndDeleteItems!(Sheets);
			ClearAndDeleteItems!(Members);
			delete Header;
			Header = new .();
			delete FileExtras;
			FileExtras = new .();
			UnknownCount = 0;
			FormatVersion = 1;
			MigratedFrom = 0;
			ClearLayout();
		}

		public void ClearLayout()
		{
			LayoutMigratedFrom = 0;
			DeleteDictionaryAndKeys!(Layout);
			Layout = new .();
			ClearAndDeleteItems!(Comments);
			ClearAndDeleteItems!(Reroutes);
			ClearAndDeleteItems!(BubblePins);
			ClearAndDeleteItems!(Views);
			ClearAndDeleteItems!(Collapsed);
			for (let l in LayoutUnknown)
			{
				delete l.sheet;
				delete l.line;
			}
			LayoutUnknown.Clear();
		}

		// ------------------------------------------------------------------ ids

		/// Every id the file uses (member ids and node ids of built Sheets).
		public void CollectIds(HashSet<String> outIds)
		{
			for (let m in Members)
				if (!m.Id.IsEmpty && !outIds.ContainsAlt(StringView(m.Id)))
					outIds.Add(new String(m.Id));
			for (let s in Sheets)
				if (s.IsBuilt)
				{
					for (let n in s.Graph.Nodes)
						if (!n.Key.IsEmpty && !outIds.ContainsAlt(StringView(n.Key)))
							outIds.Add(new String(n.Key));
					for (let gr in s.Graph.Groups)
						if (!gr.Key.IsEmpty && !outIds.ContainsAlt(StringView(gr.Key)))
							outIds.Add(new String(gr.Key));
				}
		}

		/// A fresh id no record of the file has.
		public void NewId(String outId)
		{
			HashSet<String> used = scope .();
			defer { for (let s in used) delete s; }
			CollectIds(used);
			RecordIds.NewUnique(used, outId);
		}

		/// Node ids unique across the whole file (a paste or a merge can bring a clash): a node
		/// whose id another record has gets a fresh one.
		public void EnsureUniqueKeys()
		{
			HashSet<String> used = scope .();
			defer { for (let s in used) delete s; }
			for (let m in Members)
				if (!m.Id.IsEmpty)
					used.Add(new String(m.Id));
			// Group ids are record ids too (a node never takes one).
			for (let s in Sheets)
				if (s.IsBuilt)
					for (let gr in s.Graph.Groups)
						if (!gr.Key.IsEmpty && !used.ContainsAlt(StringView(gr.Key)))
							used.Add(new String(gr.Key));
			for (let s in Sheets)
				if (s.IsBuilt)
					s.Graph.EnsureKeys(used);
		}

		// ------------------------------------------------------------------ members and sheets

		public Sheet FindSheet(StringView key)
		{
			for (let s in Sheets)
				if (s.Key == key)
					return s;
			return null;
		}

		public Sheet FindSheetByName(StringView name)
		{
			for (let s in Sheets)
				if (s.Name == name)
					return s;
			return null;
		}

		public MemberDecl FindMember(StringView name)
		{
			for (let m in Members)
				if (m.Name == name)
					return m;
			return null;
		}

		public MemberDecl FindMemberById(StringView id)
		{
			for (let m in Members)
				if (m.Id == id)
					return m;
			return null;
		}

		/// A Sheet record of `m` (no graph yet; nothing marked modified). The reader's entry point.
		public Sheet NewSheet(MemberDecl m, SheetRole role, StringView lambdaNode = "")
		{
			Sheet s = new .();
			s.Doc = this;
			s.Member = m;
			s.Role = role;
			s.LambdaNode.Set(lambdaNode);
			s.UpdateNames();
			Sheets.Add(s);
			return s;
		}

		/// Sets what a graph knows about its Sheet: key, name, member, `this`.
		public void InitGraph(Sheet s, Graph g)
		{
			g.MethodKey.Set(s.Key);
			g.MethodName.Set(s.Name);
			g.Member = s.Member;
			g.Role = s.Role;
			g.Language = Language;
			g.SelfType.Set(Header.Name);
			g.StaticContext = s.IsStatic;
			g.InLibrary = Header.Static;
			if (IsNewerFormat)
				g.ReadOnly = true;
		}

		/// Adds a function with an empty body Sheet (`name` made unique among the members).
		public Sheet AddFunction(StringView name)
		{
			MemberDecl m = new .();
			m.Kind = .Function;
			NewId(m.Id);
			String n = scope .(name);
			for (int i = 2; FindMember(n) != null; i++)
				n.Set(scope $"{name}{i}");
			m.Name.Set(n);
			Members.Add(m);
			let s = NewSheet(m, .Body);
			Modified = true;
			Version++;
			return s;
		}

		/// The older name of AddFunction (the Outline's "+").
		public Sheet AddSheet(StringView name) => AddFunction(name);

		public bool RenameSheet(Sheet s, StringView name)
		{
			if (name.IsEmpty || s.Member == null)
				return false;
			let other = FindMember(name);
			if (other != null && other != s.Member)
				return false;
			s.Member.Name.Set(name);
			for (let o in Sheets)
				if (o.Member == s.Member)
				{
					o.UpdateNames();
					if (o.IsBuilt && o.Graph.Entry != null)
						o.Graph.Entry.Text.Clear();
				}
			Modified = true;
			Version++;
			return true;
		}

		/// Removes a Sheet; a member left without Sheets that had one goes with it.
		public void RemoveSheet(Sheet s)
		{
			RemoveSheetLayout(s.Key);
			ClearViews(s.Key);
			let m = s.Member;
			Sheets.Remove(s);
			delete s;
			if (m != null && m.Kind != .Field && m.Kind != .Case)
			{
				bool more = false;
				for (let o in Sheets)
					if (o.Member == m)
						more = true;
				if (!more)
				{
					Members.Remove(m);
					delete m;
				}
			}
			Modified = true;
			Version++;
		}

		/// The graph of a Sheet that has none yet: an Entry with the member's parameters.
		public Graph BuildGraph(Sheet s)
		{
			Graph g = new .();
			InitGraph(s, g);
			let entry = NodeFactory.Create(g, .Entry);
			g.Entry = entry;
			AddEntryParams(s, g, entry);
			ApplyLayout(g);
			return g;
		}

		/// The Entry's outputs: one per parameter (a setter also has `value`). A Lambda Sheet's
		/// inputs are its node's (`set inputs`), not the member's.
		public void AddEntryParams(Sheet s, Graph g, Node entry)
		{
			if (s.Member == null)
				return;
			if (s.Role == .Lambda)
			{
				let ln = LambdaNodeOf(s);
				if (ln == null)
					return;
				for (var name in ln.GetSetting("inputs").Split(' '))
				{
					name.Trim();
					if (!name.IsEmpty && entry.FindOutput(name) == null)
						g.AddDataOut(entry, name, name);
				}
				return;
			}
			for (let p in s.Member.Params)
			{
				if (entry.FindOutput(p.Name) != null)
					continue;
				let pin = g.AddDataOut(entry, p.Name, p.Name);
				pin.SetType(TypeRef.CloneOrNull(p.Type));
			}
			if (s.Role == .Set && entry.FindOutput("value") == null)
				g.AddDataOut(entry, "value", "Value").SetType(TypeRef.CloneOrNull(s.Member.Type));
		}

		// ------------------------------------------------------------------ Lambda Sheets

		/// The Lambda node whose body `ls` is (null when it is gone, or its Sheet is not read yet).
		public Node LambdaNodeOf(Sheet ls)
		{
			if (ls.Role != .Lambda)
				return null;
			for (let s in Sheets)
			{
				if (s == ls || s.Member != ls.Member || !s.IsBuilt)
					continue;
				let n = s.Graph.FindNodeByKey(ls.LambdaNode);
				if (n != null && n.Kind == .Lambda)
					return n;
			}
			return null;
		}

		/// Makes a Lambda Sheet's pins follow its node (Language.md 4.2): the Entry gives exactly
		/// `names` in that order, typed by `types` (an empty type leaves the pin's as it is); a pin
		/// whose name is gone goes with its wires, and `renameFrom` -> `renameTo` keeps its wires
		/// under the new name. Every Return's Return Value takes `returns` ("" = unknown, kept).
		public void SyncLambdaPins(Sheet ls, Span<StringView> names, Span<StringView> types, StringView returns, StringView renameFrom = default, StringView renameTo = default)
		{
			let g = ls.Graph;
			let entry = g.Entry;
			if (entry == null)
				return;
			if (!renameFrom.IsEmpty && !renameTo.IsEmpty && renameFrom != renameTo && entry.FindOutput(renameTo) == null)
			{
				let p = entry.FindOutput(renameFrom);
				if (p != null && p.Kind == .Value)
				{
					p.Name.Set(renameTo);
					p.Label.Set(renameTo);
				}
			}
			for (int i = entry.Outputs.Count - 1; i >= 0; i--)
			{
				let p = entry.Outputs[i];
				if (p.Kind != .Value)
					continue;
				bool keep = false;
				for (let n in names)
					keep |= n == p.Name;
				if (!keep)
					g.RemovePin(p);
			}
			// The flow pin first, then the inputs in the node's order.
			List<Pin> order = scope .();
			for (let p in entry.Outputs)
				if (p.Kind != .Value)
					order.Add(p);
			for (int i < names.Length)
			{
				var p = entry.FindOutput(names[i]);
				if (p == null)
				{
					p = g.AddDataOut(entry, names[i], names[i]);
					entry.Outputs.Remove(p);
				}
				if (i < types.Length && !types[i].IsEmpty)
					p.SetTypeText(types[i]);
				if (!order.Contains(p))
					order.Add(p);
			}
			entry.Outputs.Clear();
			entry.Outputs.AddRange(order);
			if (!returns.IsEmpty)
				for (let n in g.Nodes)
					if (n.Kind == .Return)
						n.FindInput("value")?.SetTypeText(returns);
			g.Version++;
			Modified = true;
			Version++;
		}

		/// A new, empty type: the header only.
		public void InitType(StringView name, TypeKind kind, StringView ns)
		{
			ClearContent();
			Header.Name.Set(name);
			Header.Kind = kind;
			Header.Namespace.Set(ns);
		}

		// ------------------------------------------------------------------ layout

		public void SetLayout(StringView key, NodePos pos)
		{
			String k = scope .(key);
			if (Layout.ContainsKey(k))
			{
				Layout[k] = pos;
				return;
			}
			Layout[new String(key)] = pos;
		}

		void RemoveSheetLayout(StringView sheetKey)
		{
			List<String> gone = scope .();
			for (let kv in Layout)
				if (kv.key.StartsWith(sheetKey) && kv.key.Length > sheetKey.Length && kv.key[sheetKey.Length] == '|')
					gone.Add(kv.key);
			for (let k in gone)
			{
				Layout.Remove(k);
				delete k;
			}
		}

		/// Records every built graph's node positions in `Layout`.
		public void CaptureAllLayouts()
		{
			for (let s in Sheets)
				if (s.IsBuilt)
					CaptureLayout(s.Graph);
		}

		public void CaptureLayout(Graph graph)
		{
			KeyAssigner.Assign(graph);
			// Widths are kept from the file (the canvas does not resize nodes yet).
			Dictionary<String, float> widths = scope .();
			defer { for (let k in widths.Keys) delete k; }
			for (let kv in Layout)
				if (kv.value.W != 0)
					widths[new String(kv.key)] = kv.value.W;
			RemoveSheetLayout(graph.MethodKey);
			String key = scope .();
			for (let n in graph.Nodes)
			{
				if (!n.HasPos)
					continue;
				key.Clear();
				key.AppendF("{}|{}", graph.MethodKey, n.Key);
				NodePos pos = default;
				pos.X = n.X;
				pos.Y = n.Y;
				pos.W = widths.TryGetValue(key, let w) ? w : 0;
				SetLayout(key, pos);
			}
			// Where each collapsed node group is drawn (a `node <groupId> x y` line).
			for (let gr in graph.Groups)
			{
				if (!gr.HasPos || gr.Key.IsEmpty)
					continue;
				key.Clear();
				key.AppendF("{}|{}", graph.MethodKey, gr.Key);
				NodePos pos = default;
				pos.X = gr.X;
				pos.Y = gr.Y;
				SetLayout(key, pos);
			}
			for (let r in Reroutes)
			{
				if (r.MethodKey != graph.MethodKey || r.FromPinId == 0 || r.GraphSerial != graph.Serial)
					continue;
				let from = graph.FindPin(r.FromPinId);
				let to = graph.FindPin(r.ToPinId);
				if (from == null || to == null)
					continue;
				r.FromNode.Set(from.Owner.Key);
				r.FromPin.Set(from.Name);
				r.ToNode.Set(to.Owner.Key);
				r.ToPin.Set(to.Name);
			}
		}

		/// Gives the graph's nodes the positions saved for them; places the rest.
		public void ApplyLayout(Graph graph)
		{
			KeyAssigner.Assign(graph);
			bool anyKnown = false;
			String key = scope .();
			for (let n in graph.Nodes)
			{
				if (n.HasPos)
				{
					anyKnown = true;
					continue;
				}
				key.Clear();
				key.AppendF("{}|{}", graph.MethodKey, n.Key);
				if (Layout.TryGetValue(key, let pos))
				{
					n.X = pos.X;
					n.Y = pos.Y;
					n.HasPos = true;
					anyKnown = true;
				}
			}
			if (!anyKnown)
				AutoLayout.LayoutAll(graph);
			else
				AutoLayout.PlaceUnpositioned(graph);
			// Collapsed node groups: their saved place, else the middle of their members.
			for (let gr in graph.Groups)
			{
				if (gr.HasPos)
					continue;
				key.Clear();
				key.AppendF("{}|{}", graph.MethodKey, gr.Key);
				if (Layout.TryGetValue(key, let pos))
				{
					gr.X = pos.X;
					gr.Y = pos.Y;
				}
				else
				{
					float sx = 0, sy = 0;
					int count = 0;
					for (let k in gr.Nodes)
					{
						let n = graph.FindNodeByKey(k);
						if (n == null)
							continue;
						sx += n.X;
						sy += n.Y;
						count++;
					}
					if (count > 0)
					{
						gr.X = Math.Round(sx / count);
						gr.Y = Math.Round(sy / count);
					}
				}
				gr.HasPos = true;
			}
		}

		// ------------------------------------------------------------------ views, bubbles

		public SavedView FindView(StringView sheetKey, int n)
		{
			for (let v in Views)
				if (v.N == n && v.MethodKey == sheetKey)
					return v;
			return null;
		}

		public void SetView(StringView sheetKey, int n, float x, float y, float zoom)
		{
			var v = FindView(sheetKey, n);
			if (v == null)
			{
				v = new SavedView();
				v.MethodKey.Set(sheetKey);
				v.N = n;
				Views.Add(v);
			}
			v.X = x;
			v.Y = y;
			v.Zoom = zoom;
			LayoutTouched = true;
		}

		public int ClearViews(StringView sheetKey, int n = 0)
		{
			int removed = 0;
			for (var i = Views.Count - 1; i >= 0; i--)
			{
				let v = Views[i];
				if (v.MethodKey == sheetKey && (n == 0 || v.N == n))
				{
					Views.RemoveAt(i);
					delete v;
					removed++;
				}
			}
			if (removed > 0)
				LayoutTouched = true;
			return removed;
		}

		public bool IsBubblePinned(StringView sheetKey, StringView nodeKey)
		{
			for (let b in BubblePins)
				if (b.MethodKey == sheetKey && b.NodeKey == nodeKey)
					return true;
			return false;
		}

		public void SetBubblePinned(StringView sheetKey, StringView nodeKey, bool pinned)
		{
			for (let b in BubblePins)
				if (b.MethodKey == sheetKey && b.NodeKey == nodeKey)
				{
					if (!pinned)
					{
						BubblePins.Remove(b);
						delete b;
					}
					return;
				}
			if (pinned)
			{
				let b = new BubblePin();
				b.MethodKey.Set(sheetKey);
				b.NodeKey.Set(nodeKey);
				BubblePins.Add(b);
			}
		}

		// ------------------------------------------------------------------ load / save

		IGraphCodec Codec => (Language != null) ? Language.Codec : null;

		/// Reads the type file and its layout sidecar through the language's codec. A file the
		/// codec cannot read opens as an empty document with the reason in `LastError` and
		/// `Messages`; a layout that does not read only loses positions.
		public Result<void> Load(StringView path)
		{
			FilePath.Set(path);
			ClearContent();
			ClearAndDeleteItems!(mUndo);
			ClearAndDeleteItems!(mRedo);
			LastError.Clear();
			String text = scope .();
			if (File.ReadAllText(path, text) case .Err)
			{
				LastError.Set(scope $"Could not read {path}.");
				return .Err;
			}
			StampDisk();
			// A header newer than this build: the document opens read-only (best-effort read with
			// the header check relaxed, unknown lines kept), Save and Build are refused.
			let onDisk = Treadle.Format.Migrations.VersionOf(Treadle.Format.FormatNames.TypeWord, text);
			NewerVersion = (onDisk > Treadle.Format.TreadleCodec.Current) ? onDisk : 0;
			String why = scope .();
			OpenNewerReadOnly = true;
			let read = Codec != null && Codec.Read(text, this, why);
			OpenNewerReadOnly = false;
			if (!read)
			{
				ClearContent();
				LastError.Set(why.IsEmpty ? "No graph file format is installed in this build." : why);
				Messages.Add(new String(LastError));
			}
			else
				ReadLayoutFile(path);
			for (let s in Sheets)
				if (s.IsBuilt)
				{
					ApplyLayout(s.Graph);
					if (IsNewerFormat)
						s.Graph.ReadOnly = true;
				}
			if (IsNewerFormat)
				Messages.Add(new String(scope $"{path}: {Treadle.Format.Migrations.NewerMessage(NewerVersion, .. scope String())}"));
			else if (UnknownCount > 0)
				Messages.Add(new String(scope $"{path}: {UnknownCount} record(s) of a newer format are kept as they are."));
			Modified = false;
			LayoutTouched = false;
			ExternalChange = false;
			// Migrated on load: dirty, so the user sees the file will be rewritten (with a backup).
			if (MigratedFrom > 0)
			{
				Modified = true;
				Messages.Add(new String(scope $"{path}: format version {MigratedFrom} migrated to {Treadle.Format.TreadleCodec.Current}; the first save keeps the old file as {Path.GetFileName(path, .. scope String())}.v{MigratedFrom}.bak"));
			}
			Version++;
			return .Ok;
		}

		void ReadLayoutFile(StringView path)
		{
			String layoutPath = scope .();
			LayoutPathOf(path, layoutPath);
			if (!File.Exists(layoutPath))
				return;
			String text = scope .();
			if (File.ReadAllText(layoutPath, text) case .Err)
				return;
			String why = scope .();
			if (!Codec.ReadLayout(text, this, why))
			{
				ClearLayout();
				Messages.Add(new String(scope $"{layoutPath}: {why} (positions are laid out again)"));
			}
		}

		/// Replaces the document's content with what the codec reads from `text` (a recovered
		/// journal). False with `outError` when the text does not read; nothing changes then.
		public bool LoadText(StringView text, String outError)
		{
			if (Codec == null)
			{
				outError?.Set("No graph file format is installed in this build.");
				return false;
			}
			TypeDocument probe = scope .(Language);
			probe.FilePath.Set(FilePath);
			String why = scope .();
			if (!Codec.Read(text, probe, why))
			{
				outError?.Set(why);
				return false;
			}
			PushUndo();
			// Keep this document's layout; take the probe's model.
			ClearAndDeleteItems!(Sheets);
			ClearAndDeleteItems!(Members);
			Swap!(Header, probe.Header);
			Swap!(FileExtras, probe.FileExtras);
			UnknownCount = probe.UnknownCount;
			for (let m in probe.Members)
				Members.Add(m);
			probe.Members.Clear();
			for (let s in probe.Sheets)
			{
				s.Doc = this;
				Sheets.Add(s);
				if (s.IsBuilt)
				{
					InitGraph(s, s.Graph);
					ApplyLayout(s.Graph);
				}
			}
			probe.Sheets.Clear();
			Modified = true;
			Version++;
			return true;
		}

		/// The type file as the codec writes it. False with `outError` when the codec refuses.
		public bool WriteText(String outText, String outError)
		{
			CaptureAllLayouts();
			EnsureUniqueKeys();
			String why = scope .();
			if (Codec == null || !Codec.Write(this, outText, why))
			{
				outError?.Set(why.IsEmpty ? "No graph file format is installed in this build." : why);
				return false;
			}
			return true;
		}

		void StampDisk()
		{
			if (File.GetLastWriteTime(FilePath) case .Ok(let t))
			{
				DiskTime = t;
				mHasDiskStamp = true;
			}
		}

		public bool CheckExternalChange()
		{
			if (!mHasDiskStamp || FilePath.IsEmpty)
				return false;
			if (File.GetLastWriteTime(FilePath) case .Ok(let t))
				ExternalChange = t != DiskTime;
			return ExternalChange;
		}

		/// Writes the type file and its layout sidecar through the codec (atomic, with a backup).
		/// A document with errors saves too: an error is a state of the program, not of the file
		/// (Editor-Model.md 9). The layout file is written only when its text changed.
		public bool TrySave(String outError)
		{
			if (FilePath.IsEmpty)
			{
				outError.Set("The document has no file.");
				return false;
			}
			if (FileSafety.ReadOnlyProject)
			{
				outError.Set(FileSafety.ReadOnlyMessage);
				return false;
			}
			if (IsNewerFormat)
			{
				outError.Set(scope $"Not saved: {Treadle.Format.Migrations.NewerMessage(NewerVersion, .. scope String())}");
				return false;
			}
			String text = scope .();
			if (!WriteText(text, outError))
				return false;
			// A file migrated on load keeps its old text once as `<file>.v<old>.bak` (never overwritten).
			if (MigratedFrom > 0 && !Treadle.Format.Migrations.BackupOnce(FilePath, MigratedFrom))
			{
				outError.Set(scope $"Not saved: the backup {FilePath}.v{MigratedFrom}.bak could not be written");
				return false;
			}
			String layout = scope .();
			String why = scope .();
			if (!Codec.WriteLayout(this, layout, why))
			{
				outError.Set(why);
				return false;
			}
			String current = scope .();
			bool same = File.Exists(FilePath) && (File.ReadAllText(FilePath, current) case .Ok) && current == text;
			if (!same && FileSafety.AtomicWrite(FilePath, text, FileSafety.KeepBackup, why) case .Err)
			{
				outError.Set(why);
				return false;
			}
			String layoutPath = scope .();
			LayoutPathOf(FilePath, layoutPath);
			String currentLayout = scope .();
			bool hasLayout = File.Exists(layoutPath) && (File.ReadAllText(layoutPath, currentLayout) case .Ok);
			if ((hasLayout || !layout.IsEmpty) && currentLayout != layout)
			{
				if (LayoutMigratedFrom > 0)
					Treadle.Format.Migrations.BackupOnce(layoutPath, LayoutMigratedFrom);
				if (FileSafety.AtomicWrite(layoutPath, layout, FileSafety.KeepBackup, why) case .Err)
				{
					outError.Set(scope $"The type file was saved, its layout was not: {why}");
					StampDisk();
					Modified = false;
					return false;
				}
			}
			StampDisk();
			if (MigratedFrom > 0)
				FormatVersion = Treadle.Format.TreadleCodec.Current;
			MigratedFrom = 0;
			LayoutMigratedFrom = 0;
			Modified = false;
			LayoutTouched = false;
			ExternalChange = false;
			return true;
		}

		public void MarkSavedFromDisk()
		{
			StampDisk();
			Modified = false;
			LayoutTouched = false;
			ExternalChange = false;
		}

		public void RefreshModified()
		{
		}

		/// Layout is written with the document (TrySave writes the sidecar when it changed).
		public bool SaveLayout(String outError = null) => true;

		// ------------------------------------------------------------------ commits

		public void Commit(Sheet s)
		{
			let g = s.Graph;
			KeyAssigner.Assign(g);
			GraphValidator.Validate(g);
			g.Version++;
			Modified = true;
			Version++;
		}

		public void Validate(Sheet s)
		{
			GraphValidator.Validate(s.Graph);
		}

		// ------------------------------------------------------------------ undo

		Snapshot MakeSnapshot()
		{
			Snapshot snap = new .();
			CaptureAllLayouts();
			for (let s in Sheets)
				if (s.IsBuilt)
					snap.Graphs.Add((new String(s.Key), s.Graph.Clone()));
			for (let kv in Layout)
				snap.Layout[new String(kv.key)] = kv.value;
			for (let c in Comments)
				snap.Comments.Add(c.Clone());
			for (let r in Reroutes)
				snap.Reroutes.Add(r.Clone());
			snap.Header = Header.Clone();
			for (let m in Members)
				snap.Members.Add(m.Clone());
			for (let s in Sheets)
				if (s.Member != null)
					snap.SheetRecs.Add((s.Member.Serial, s.Role, new String(s.LambdaNode)));
			snap.Version = Version;
			return snap;
		}

		void RestoreSnapshot(Snapshot snap)
		{
			// Members are restored in place (Sheets and graphs keep pointing at them), in the
			// snapshot's order; members added since go, members removed since come back.
			List<MemberDecl> members = scope .();
			for (let saved in snap.Members)
			{
				MemberDecl m = null;
				for (let cur in Members)
					if (cur.Serial == saved.Serial)
						m = cur;
				let copy = saved.Clone();
				if (m != null)
				{
					m.AssignFrom(copy);
					delete copy;
				}
				else
					m = copy;
				members.Add(m);
			}
			List<MemberDecl> gone = scope .();
			for (let cur in Members)
				if (!members.Contains(cur))
					gone.Add(cur);
			Members.Clear();
			Members.AddRange(members);
			// The Sheets of the snapshot, in its order (kept where they exist, made again where not).
			List<Sheet> sheets = scope .();
			for (let rec in snap.SheetRecs)
			{
				Sheet s = null;
				for (let cur in Sheets)
					if (cur.Member != null && cur.Member.Serial == rec.member && cur.Role == rec.role && cur.LambdaNode == rec.lambda)
						s = cur;
				if (s == null)
				{
					for (let m in Members)
						if (m.Serial == rec.member)
						{
							s = new .();
							s.Doc = this;
							s.Member = m;
							s.Role = rec.role;
							s.LambdaNode.Set(rec.lambda);
						}
				}
				if (s != null && !sheets.Contains(s))
					sheets.Add(s);
			}
			for (let cur in Sheets)
				if (cur.Member == null && !sheets.Contains(cur))
					sheets.Add(cur);
			for (let cur in Sheets)
				if (!sheets.Contains(cur))
					delete cur;
			Sheets.Clear();
			Sheets.AddRange(sheets);
			for (let m in gone)
				delete m;
			delete Header;
			Header = snap.Header.Clone();
			for (let s in Sheets)
				s.UpdateNames();
			for (let entry in snap.Graphs)
			{
				let s = FindSheet(entry.key);
				if (s == null)
					continue;
				s.AttachGraph(entry.graph.Clone());
			}
			DeleteDictionaryAndKeys!(Layout);
			Layout = new .();
			for (let kv in snap.Layout)
				Layout[new String(kv.key)] = kv.value;
			ClearAndDeleteItems!(Comments);
			for (let c in snap.Comments)
				Comments.Add(c.Clone());
			ClearAndDeleteItems!(Reroutes);
			for (let r in snap.Reroutes)
				Reroutes.Add(r.Clone());
			Modified = true;
			LayoutTouched = true;
			Version++;
		}

		public void PushUndo()
		{
			UndoStamp++;
			LayoutTouched = true;
			mUndo.Add(MakeSnapshot());
			ClearAndDeleteItems!(mRedo);
			if (mUndo.Count > MaxUndo)
			{
				delete mUndo[0];
				mUndo.RemoveAt(0);
			}
		}

		public void DropLastUndo()
		{
			UndoStamp++;
			if (mUndo.IsEmpty)
				return;
			delete mUndo.PopBack();
		}

		public bool Undo()
		{
			if (mUndo.IsEmpty)
				return false;
			UndoStamp++;
			mRedo.Add(MakeSnapshot());
			let snap = mUndo.PopBack();
			RestoreSnapshot(snap);
			delete snap;
			return true;
		}

		public bool Redo()
		{
			if (mRedo.IsEmpty)
				return false;
			UndoStamp++;
			mUndo.Add(MakeSnapshot());
			let snap = mRedo.PopBack();
			RestoreSnapshot(snap);
			delete snap;
			return true;
		}
	}
}
