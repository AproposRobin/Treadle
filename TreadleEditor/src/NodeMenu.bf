using System;
using System.Collections;
using System.IO;
using ImGui;
using Treadle.Graph;
using Treadle.Document;

using Treadle.Catalog;
using Treadle.Language;

namespace Treadle.Editor
{
	/// What a Node menu row makes (the built-in nodes of Language.md 5 and the open type's own
	/// members); rows from the language's catalogue are `CatalogId` items made by NodeFactory.FromSpec.
	enum MenuEntryKind
	{
		Catalog,        // an entry of the language's catalogue (CatalogId); B = its value type, C = its return type
		CallOwn,        // a function of the open type: MemberSerial names it; A = name
		GetVar,         // A = variable (field / property / local / parameter name), B = type
		SetVar,         // A = variable, B = type
		LocalVar,       // a new local of the function and a Set of it
		Branch,
		While,
		DoWhile,
		For,
		ForEach,
		Return,
		Break,
		Continue,
		Switch,         // A = value type (int, String, an enum), B = case labels separated by newlines
		Flow,           // A = macro name (FlowMacros), B = number of outputs (Sequence / MultiGate)
		LoopBreak,      // A = "foreach" or "for": a loop with a Branch and a Break already in its body
		Literal,        // A = value token, B = type
		Operator,       // A = op, B = "2" binary / "1" unary
		Select,
		Cast,           // A = type to cast to ("" = chosen in Properties), C = "checked" for the class Cast
		Index,
		Construct,      // A = type ("" = chosen in Properties), B = "local" for Local, C = constructor parameters ("String name")
		ChainCtor,      // a constructor's Base Constructor (A = "base") or This Constructor (A = "this"); C = its parameters
		Delete,
		DeferDelete,
		Defer,
		Scope,          // B = "unsafe" for an Unsafe block
		ResultMatch,
		Try,
		Fatal,
		Make,           // A = struct type, B = fields ("int x, int y")
		BreakStruct,    // A = struct type, B = fields
		MakeCase,       // A = `Enum.Case`, B = payload fields
		IsCase,         // A = `Enum.Case`, B = payload fields
		This,
		Base,
		Lambda,
		Bind,           // A = function name ("" = chosen in Properties)
		Invoke,
		Math,
		Comment,        // a comment box (layout), not a node
		Reroute,        // a knot on the wire the menu was dragged from (layout), not a node
		NewFunction,    // a new function of the type and a Call of it
		MoreOverloads,  // "N more overloads" under the overload the search names: A = the overload key; picking it lists them
		VectorNode,     // a vector row for the context pin's vector type (VectorCatalog.Typed): A = the row's key word, B = the vector type
		ConstructCall   // "Construct T + F": a Construct of T (A, its full name), a Defer Delete and a Call of its function F (B); C = the constructor's parameters, Extra = F's parameter types ("int,float")
	}

	class NodeItem
	{
		public MenuEntryKind Kind;
		public String Category = new .() ~ delete _;
		public String Label = new .() ~ delete _;
		public String A = new .() ~ delete _;
		public String B = new .() ~ delete _;
		public String C = new .() ~ delete _;
		public String Tooltip = new .() ~ delete _;
		/// The type the item is about (a catalogue entry's owner type).
		public String OnType = new .() ~ delete _;
		/// CallOwn: the serial of the member (MemberDecl.Serial) the Call is of.
		public int32 MemberSerial;
		/// Relevance to the context pin (0 = no context, 1 = loose, 2 = good, 3 = exact/target).
		public int32 Relevance;
		/// Search score this frame.
		public float Score;
		/// A copy shown in the Favorites or Recently Used group: the category it really belongs to
		/// (Category holds the group's name).
		public String OrigCategory = new .() ~ delete _;
		/// The node catalog entry this item shows (-1 = a built-in or local item).
		public int32 CatalogId = -1;
		/// Catalog entries without exec pins ([Pure], getters, [NodeLibrary] functions).
		public bool Pure;
		/// CallMethod of the type being edited: a static function (no Target pin). OnType holds
		/// the type, so the node is a member call with self otherwise.
		public bool Static;
		/// ConstructCall: the parameter types of the function it calls ("int,float").
		public String Extra = new .() ~ delete _;

		public void CopyFrom(NodeItem o)
		{
			Kind = o.Kind;
			Extra.Set(o.Extra);
			Category.Set(o.Category);
			Label.Set(o.Label);
			A.Set(o.A);
			B.Set(o.B);
			C.Set(o.C);
			Tooltip.Set(o.Tooltip);
			OnType.Set(o.OnType);
			OrigCategory.Set(o.OrigCategory);
			Relevance = o.Relevance;
			CatalogId = o.CatalogId;
			Pure = o.Pure;
			Static = o.Static;
			MemberSerial = o.MemberSerial;
		}

		/// Does a node made from this item have flow pins?
		public bool IsStatement
		{
			get
			{
				if (Pure)
					return false;
				switch (Kind)
				{
				case .Catalog, .CallOwn, .SetVar, .LocalVar, .Branch, .While, .DoWhile, .For, .ForEach, .Return, .Break, .Continue,
					 .Switch, .Flow, .LoopBreak, .Construct, .Delete, .DeferDelete, .Defer, .Scope, .ResultMatch, .Try, .Fatal,
					 .Invoke, .NewFunction, .ConstructCall:
					return true;
				case .Cast:
					return C == "checked";
				default:
					return false;
				}
			}
		}

		public bool IsCall => Kind == .CallOwn || (Kind == .Catalog && A == "call");

		/// Key for favorites, node hotkeys and recents ("Category\tLabel", the real category for a
		/// copy in the Favorites or Recently Used group).
		public void GetKey(String outKey) => outKey.AppendF("{}\t{}", OrigCategory.IsEmpty ? Category : OrigCategory, Label);
	}

	/// Where the action menu was opened from (UE's "context sensitive" filtering).
	enum NodeMenuContext
	{
		None,
		/// Dragged from an exec output (or input): statements only.
		Flow,
		/// Dragged from a data output: actions that take a value of the pin's type.
		DataOut,
		/// Dragged from a data input: actions that produce a value of the pin's type.
		DataIn
	}

	/// Favorites, node hotkeys and recently used nodes. Favorites and hotkeys are global settings in
	/// settings.json (`editor.favorites`, `editor.nodeHotkeys`; docs/Editor-UI.md, "Node hotkeys and
	/// favorites"), seeded with the default keys on first run. Recents stay in
	/// %LOCALAPPDATA%\Treadle\node_menu.txt (an old action_menu.txt is renamed once); the favorite
	/// lines that file used to hold move to settings.json once.
	class NodeMenuPrefs
	{
		public NodeHotkeys Hotkeys = new .() ~ delete _;
		public List<String> Favorites => Hotkeys.Favorites;
		public List<String> Recents = new .() ~ DeleteContainerAndItems!(_);
		bool mLoaded;

		static void FilePath(String outPath)
		{
			AppPaths.Root(outPath);
			outPath.AppendF("{}node_menu.txt", System.IO.Path.DirectorySeparatorChar);
		}

		public void Load()
		{
			if (mLoaded)
				return;
			mLoaded = true;
			String path = scope .();
			FilePath(path);
			if (!File.Exists(path))
			{
				// One-time migration from the file's old name; the favourites are kept.
				String old = scope .(path);
				old.RemoveFromEnd("node_menu.txt".Length);
				old.Append("action_menu.txt");
				if (File.Exists(old))
					File.Move(old, path).IgnoreError();
			}
			List<String> oldFavorites = scope .();
			defer { ClearAndDeleteItems!(oldFavorites); }
			String text = scope .();
			if (File.ReadAllText(path, text) case .Ok)
			{
				for (var line in text.Split('\n'))
				{
					line.TrimEnd();
					if (line.StartsWith("fav\t"))
						oldFavorites.Add(new String(line.Substring(4)));
					else if (line.StartsWith("recent\t"))
						Recents.Add(new String(line.Substring(7)));
				}
			}
			LoadSettings(oldFavorites);
		}

		/// Favorites and hotkeys from settings.json; on first run the defaults (plus the favorites of
		/// the old node_menu.txt), written back at once.
		void LoadSettings(List<String> oldFavorites)
		{
			Settings.Load();
			let editor = Settings.Root.Get("editor");
			let keys = (editor != null) ? editor.Get("nodeHotkeys") : null;
			if (keys == null || keys.Type != .Object)
			{
				Hotkeys.ResetToDefaults();
				for (let f in oldFavorites)
					Hotkeys.AddFavorite(f);
				SaveSettings();
				if (!oldFavorites.IsEmpty)
					Save(); // node_menu.txt keeps only the recents
				return;
			}
			Hotkeys.Clear();
			let favs = editor.Get("favorites");
			if (favs != null && favs.Type == .Array)
				for (let f in favs.Items)
					if (f.Type == .String)
						Hotkeys.AddFavorite(f.Str);
			for (int i < keys.Keys.Count)
			{
				let letter = keys.Keys[i];
				let node = keys.Items[i];
				if (node.Type != .String)
					continue;
				String owner = scope .();
				let r = (letter.Length == 1) ? Hotkeys.Assign(letter[0], node.Str, owner) : NodeHotkeys.AssignResult.Invalid;
				if (r != .Ok)
				{
					String why = scope .();
					NodeHotkeys.Describe(r, (letter.Length == 1) ? letter[0] : '?', owner, why);
					Notify.Log(.Warning, "Editor", scope $"settings.json: node hotkey '{letter}' for {NodeHotkeys.LabelOf(node.Str)} ignored: {why}");
				}
			}
		}

		/// Writes `editor.favorites` and `editor.nodeHotkeys` to settings.json.
		public void SaveSettings()
		{
			Settings.Load();
			let editor = Settings.Root.Obj("editor");
			let favs = Json.NewArray();
			for (let f in Hotkeys.Favorites)
				favs.Items.Add(Json.NewString(f));
			editor.Set("favorites", favs);
			let keys = Json.NewObject();
			List<(char8 key, StringView nodeKey)> bindings = scope .();
			Hotkeys.GetBindings(bindings);
			for (let b in bindings)
				keys.Set(scope String()..Append(b.key), Json.NewString(b.nodeKey));
			editor.Set("nodeHotkeys", keys);
			Settings.Save();
		}

		public void Save()
		{
			String path = scope .();
			FilePath(path);
			String dir = scope .();
			Path.GetDirectoryPath(path, dir).IgnoreError();
			if (!Directory.Exists(dir))
				Directory.CreateDirectory(dir).IgnoreError();
			String text = scope .();
			for (let r in Recents)
				text.AppendF("recent\t{}\n", r);
			File.WriteAllText(path, text).IgnoreError();
		}

		public bool IsFavorite(StringView key) => Hotkeys.IsFavorite(key);

		/// Adds or removes a favorite (removing one also removes its hotkey). True when it is a
		/// favorite afterwards.
		public bool ToggleFavorite(StringView key)
		{
			let now = Hotkeys.ToggleFavorite(key);
			SaveSettings();
			return now;
		}

		/// Gives a node a hotkey (it becomes a favorite). Refusals (a reserved letter, a letter another
		/// node has) leave everything as it was; `outMessage` says what happened either way.
		public bool AssignHotkey(StringView key, char8 letter, String outMessage)
		{
			String owner = scope .();
			let r = Hotkeys.Assign(letter, key, owner);
			if (r != .Ok)
			{
				NodeHotkeys.Describe(r, letter, owner, outMessage);
				return false;
			}
			SaveSettings();
			outMessage.AppendF("{} is now the hotkey of {}.", letter.ToUpper, NodeHotkeys.LabelOf(key));
			return true;
		}

		/// Removes a node's hotkey (the favorite stays).
		public bool ClearHotkey(StringView key)
		{
			if (!Hotkeys.ClearNode(key))
				return false;
			SaveSettings();
			return true;
		}

		/// The default favorites and keys (Editor Preferences > Node Hotkeys > Reset).
		public void ResetHotkeys()
		{
			Hotkeys.ResetToDefaults();
			SaveSettings();
		}

		public void Used(StringView key)
		{
			for (let r in Recents)
				if (r == key)
				{
					Recents.Remove(r);
					delete r;
					break;
				}
			Recents.Insert(0, new String(key));
			while (Recents.Count > 12)
				delete Recents.PopBack();
			Save();
		}
	}

	/// Blueprint-style "All nodes for this Sheet" menu: search, collapsible categories,
	/// keyboard navigation and context-sensitive filtering when opened by dragging off a pin.
	///
	/// Two sources: the local items built when the menu opens (flow control, operators, the
	/// Sheet's locals, literals) and the NodeCatalog (every node the language's catalog source
	/// offers, a seam). Filtering
	/// runs only when the search text or the context changes, never per frame; catalog entries
	/// become NodeItems only when they are shown.
	class NodeMenu
	{
		EditorApp mApp;
		/// The language's node entries (NodeCatalog over INodeCatalogSource).
		public NodeCatalog Catalog ~ delete _;
		public NodeMenuPrefs Prefs = new .() ~ delete _;
		public List<NodeItem> Items = new .() ~ DeleteContainerAndItems!(_);
		TextBuffer mSearch = new .(256) ~ delete _;
		String mLastSearch = new .() ~ delete _;
		/// Self test (dragvars-live): the Get row of this variable records where it was drawn (screen).
		public String SelfTestRowFor = new .() ~ delete _;
		public ImVec2 SelfTestRowAt;
		public bool IsShown => mShown;
		/// The search text changed and the list has not been filtered for it yet (debounce).
		bool mSearchPending;
		double mSearchChangedAt;
		const double cSearchDebounce = 0.080;
		/// The menu waits for a debounced search: the idle loop must wake soon.
		public bool SearchPending => mSearchPending;
		public ImVec2 SpawnPos;
		/// The sheet's graph the menu was opened for, and whether the popup is up: the canvas draws the
		/// pending wire (source pin to SpawnPos) while a pin-opened menu is showing.
		public Object ContextGraph;
		bool mShown;
		public bool PinMenuActive => ContextPinId != 0 && ContextGraph != null && (OpenRequested || mShown);
		public int32 ContextPinId;

		/// The menu was dragged from a wired flow output: with nothing typed, its first choice is a
		/// Reroute knot on that wire at the drop point.
		public bool ContextIsFlowOutput
		{
			get
			{
				let g = ContextGraph as Treadle.Graph.Graph;
				let ctx = (g != null && ContextPinId != 0) ? g.FindPin(ContextPinId) : null;
				return ctx != null && ctx.Kind == .Flow && !ctx.IsInput && g.IsLinked(ctx);
			}
		}
		/// Self-test captures: the popup opens here (screen pixels) instead of at the mouse.
		public ImVec2 SelfTestPos;
		public bool OpenRequested;
		/// Closes the popup on its next draw (self-test captures: a posted Escape does not reach SDL).
		public bool CloseRequested;
		bool mFocusSearch;
		/// UE's "Context Sensitive" checkbox.
		public bool ContextSensitive = true;
		NodeMenuContext mContext;
		String mContextType = new .() ~ delete _;
		String mContextLabel = new .() ~ delete _;
		/// "From Get mHealth  ·  Value (int)": the pin the menu was dragged from ("" = none).
		String mContextFrom = new .() ~ delete _;
		uint32 mContextColor;
		/// The context line drawn last (the self test reads it).
		public StringView ContextLine => mContextFrom;
		/// Return type of the function being edited (for Return).
		String mReturnType = new .() ~ delete _;
		/// The owner type of the graph (its own members are local items, not catalog ones).
		String mOwnerName = new .() ~ delete _;
		/// The menu was opened from a call's Target pin (Self is the first suggestion).
		bool mContextIsTarget;

		/// Keyboard highlight: an item of `Items` or one of the free-form entries (by label).
		NodeItem mHighlight;
		String mHighlightLabel = new .() ~ delete _;
		bool mScrollToHighlight;
		/// Force categories open/closed for one frame (after the search text changed).
		int mForceOpen = 1;
		/// Items in the order they were drawn last frame (for up/down).
		List<NodeItem> mNavOrder = new .() ~ delete _;

		/// Catalog entries turned into items, by catalog id (cleared when the catalog changes).
		Dictionary<int32, NodeItem> mCatalogItems = new .() ~ DeleteDictionaryAndValues!(_);
		int32 mCatalogGeneration = -1;
		/// The current filter result: categories in display order with their items.
		List<String> mGroupOrder = new .() ~ DeleteContainerAndItems!(_);
		Dictionary<String, List<NodeItem>> mGroups = new .() ~ DeleteDictionaryAndValues!(_);
		int mVisibleCount;
		/// Catalog results are capped while searching (the best ones are kept).
		const int cMaxCatalogHits = 300;
		/// Context-sensitive catalog matches, computed once per open.
		List<int32> mContextIds = new .() ~ delete _;
		bool mContextIdsValid;
		bool mDirty = true;
		bool mHighlightCustom;

		public this(EditorApp app)
		{
			mApp = app;
			Catalog = new NodeCatalog(app.Language);
		}

		/// The type system's generation (the cached catalog items follow it).
		int32 TypesGeneration => (mApp.Language.Types != null) ? mApp.Language.Types.Generation : 0;

		NodeItem Add(MenuEntryKind kind, StringView category, StringView label, StringView a = "", StringView b = "", StringView c = "")
		{
			NodeItem item = new .();
			item.Kind = kind;
			item.Category.Set(category);
			item.Label.Set(label);
			item.A.Set(a);
			item.B.Set(b);
			item.C.Set(c);
			Items.Add(item);
			return item;
		}


		// ------------------------------------------------------------------ types

		/// Strips nullable markers, ref/out modifiers and whitespace.
		public static void NormalizeType(StringView type, String outType)
		{
			var t = type;
			t.Trim();
			for (let mod in StringView[?]("ref ", "out ", "in ", "params ", "mut "))
			{
				if (t.StartsWith(mod))
				{
					t = t.Substring(mod.Length);
					t.Trim();
				}
			}
			if (t.EndsWith('?'))
				t.RemoveFromEnd(1);
			outType.Append(t);
		}

		public static bool IsWild(StringView t) => t.IsEmpty || t == "var" || t == "let" || t == "Object" || t == "Variant" ||
			TypeRules.IsGenericParam(t);

		static bool IsIntType(StringView t) => TypeRules.IsInt(t) || TypeRules.IsChar(t);

		public static bool IsNumeric(StringView t) => TypeRules.IsNumeric(t) || TypeRules.IsChar(t);

		static bool IsStringType(StringView t) => TypeRules.IsStringLike(t);

		public static bool IsCollection(StringView t)
		{
			if (t.EndsWith("[]") || t.EndsWith("]"))
				return true;
			for (let prefix in StringView[?]("List<", "Dictionary<", "HashSet<", "Span<", "Queue<", "IEnumerable<", "SizedArray<", "Array", "TArray<"))
				if (t.StartsWith(prefix))
					return true;
			return t == "String" || t == "StringView";
		}

		/// The type name without generic arguments ("List<int>" -> "List").
		public static StringView BaseTypeName(StringView t)
		{
			int lt = t.IndexOf('<');
			var s = (lt > 0) ? t.Substring(0, lt) : t;
			int dot = s.LastIndexOf('.');
			if (dot >= 0)
				s = s.Substring(dot + 1);
			return s;
		}

		/// 2 = same type, 1 = compatible (wildcards, implicit conversions), 0 = no.
		public static int32 TypeMatch(LanguageContext lang, StringView provided, StringView wanted)
		{
			String a = scope .();
			String b = scope .();
			NormalizeType(provided, a);
			NormalizeType(wanted, b);
			if (a == b && !IsWild(a))
				return 2;
			if (IsWild(a) || IsWild(b))
				return 1;
			switch (TypeRules.CanConvert(a, b, null, LanguageContext.HierarchyOf(lang)))
			{
			case .Exact: return 2;
			case .Implicit, .Unchecked: return 1;
			case .Refused: return 0;
			}
		}

		/// Types of a parameter list ("int a, List<int> b = null" -> ["int", "List<int>"]).
		public static void ParamTypes(StringView paramsText, List<String> outTypes)
		{
			int depth = 0;
			int segStart = 0;
			for (int i = 0; i <= paramsText.Length; i++)
			{
				bool end = i == paramsText.Length;
				char8 c = end ? ',' : paramsText[i];
				if (c == '<' || c == '(' || c == '[')
					depth++;
				else if (c == '>' || c == ')' || c == ']')
					depth--;
				else if (c == ',' && depth == 0)
				{
					var part = paramsText.Substring(segStart, i - segStart);
					segStart = i + 1;
					int eq = part.IndexOf('=');
					if (eq > 0)
						part = part.Substring(0, eq);
					part.Trim();
					if (part.IsEmpty)
						continue;
					int space = part.LastIndexOf(' ');
					String t = new .();
					NormalizeType((space > 0) ? part.Substring(0, space) : "", t);
					outTypes.Add(t);
				}
			}
		}

		// ------------------------------------------------------------------ build

		/// Rebuilds the local rows for the open Sheet (once per open): the built-in nodes
		/// (Language.md 5, Graph-Format.md 3.2), the open type's own members (they may be unsaved,
		/// so they come from the document, not the catalogue), the function's parameters and locals.
		/// Every other type's entries come from the language's catalogue (INodeCatalogSource).
		public void Build(Sheet mg)
		{
			ClearAndDeleteItems!(Items);
			Catalog.Refresh();
			if (mContext == .DataIn)
				AddLiterals();
			AddVectorRows();
			if (mg == null)
				return;
			let doc = mg.Doc;
			let self = doc.Header;
			String selfName = scope .();
			self.GetFullName(selfName);
			AddGenericStructRows();

			// Variables: the function's locals and inputs, the type's fields and properties.
			for (let l in mg.Graph.Locals)
			{
				String t = l.GetTypeText(.. scope String());
				Add(.GetVar, "Variables | Locals", scope $"Get {l.Name}", l.Name, t).Tooltip.AppendF("{} {}  (local of {})", t, l.Name, mg.Name);
				Add(.SetVar, "Variables | Locals", scope $"Set {l.Name}", l.Name, t).Tooltip.AppendF("{} = value  ({})", l.Name, t);
			}
			if (mg.Member != null)
			{
				for (let p in mg.Member.Params)
				{
					String t = p.Type?.ToString(.. scope String()) ?? "";
					Add(.GetVar, "Variables | Inputs", scope $"Get {p.Name}", p.Name, t).Tooltip.AppendF("{} {}  (input of {})", t, p.Name, mg.Name);
				}
				for (let p in mg.Member.Outs)
				{
					String t = p.Type?.ToString(.. scope String()) ?? "";
					Add(.SetVar, "Variables | Outputs", scope $"Set {p.Name}", p.Name, t).Tooltip.AppendF("{} = value  (output of {})", p.Name, mg.Name);
				}
			}
			if (mg.Role == .Set)
				Add(.GetVar, "Variables | Inputs", "Get value", "value", (mg.Member?.Type != null) ? mg.Member.Type.ToString(.. scope String()) : "");
			bool staticSheet = mg.IsStatic;
			for (let m in doc.Members)
			{
				if (m.Kind != .Field && m.Kind != .Property)
					continue;
				if (staticSheet && !m.Static)
					continue;
				String t = m.Type?.ToString(.. scope String()) ?? "";
				// A field with a Category is listed under it (Variables | Combat), like the Outline.
				String cat = scope .();
				cat.AppendF("Variables | {}", (m.Category != null && !m.Category.IsEmpty) ? (StringView)m.Category : (StringView)self.Name);
				Add(.GetVar, cat, scope $"Get {m.Name}", m.Name, t).Tooltip.AppendF("{} {}  ({} of {})", t, m.Name, (m.Kind == .Field) ? "field" : "property", self.Name);
				if (!m.Const)
					Add(.SetVar, cat, scope $"Set {m.Name}", m.Name, t).Tooltip.AppendF("{} = value  ({})", m.Name, t);
			}
			Add(.LocalVar, "Variables", "Local Variable").Tooltip.Set("Adds a local variable to this function and a Set of it");
			if (!staticSheet)
			{
				Add(.This, "Variables", "This").Tooltip.AppendF("The {} this function runs on", self.Name);
				if (self.Base != null)
					Add(.Base, "Variables", "Base").Tooltip.AppendF("This object as its base type {}: calls through it run the base version", self.Base.ToString(.. scope String()));
			}

			// Functions of the open type.
			for (let m in doc.Members)
			{
				if (m.Kind != .Function || (staticSheet && !m.Static))
					continue;
				String sig = scope .();
				for (let p in m.Params)
				{
					if (@p.Index > 0)
						sig.Append(", ");
					sig.AppendF("{} {}", p.Type?.ToString(.. scope String()), p.Name);
				}
				int sameName = 0;
				for (let o in doc.Members)
					if (o.Kind == .Function && o.Name == m.Name)
						sameName++;
				// An overloaded function is one row per overload, its parameters in the label.
				let item = Add(.CallOwn, scope $"Functions | {self.Name}", (sameName > 1) ? scope $"{m.Name} ({sig})" : (StringView)m.Name, m.Name);
				item.MemberSerial = m.Serial;
				item.Pure = m.Pure;
				m.Returns?.ToString(item.C);
				item.B.Set(sig);
				item.Static = m.Static;
				item.Tooltip.AppendF("{}({}){}", m.Name, sig, (m.Returns != null) ? scope $" -> {m.Returns.ToString(.. scope String())}" : "");
				if (m.Doc != null)
					item.Tooltip.AppendF("\n{}", m.Doc);
			}
			Add(.NewFunction, "Functions", "Add Function").Tooltip.Set("Adds a new function to this type and a Call of it here");
			AddConstructCallRows(mg, selfName, staticSheet);

			// A constructor's Sheet: the constructor it runs first (one Base / This Constructor node).
			if (mg.Member != null && mg.Member.Kind == .Ctor && !mg.Key.StartsWith("lambda:"))
			{
				bool hasChain = false;
				for (let n in mg.Graph.Nodes)
					hasChain |= n.Kind == .ChainCtor;
				if (!hasChain)
				{
					List<OverloadChoice> chains = scope .();
					defer { ClearAndDeleteItems!(chains); }
					ChainChoices(mg, "base", chains);
					ChainChoices(mg, "this", chains);
					for (let c in chains)
					{
						let item = Add(.ChainCtor, "Functions | Constructors", c.Item.Label, c.Item.A, "", c.Item.C);
						item.Tooltip.Set(c.Item.Tooltip);
					}
				}
			}

			// The open type's own allocation and value nodes (other types come from the catalogue).
			if ((self.Kind == .Class || self.Kind == .Struct) && !self.Static && !self.Abstract)
			{
				bool anyCtor = false;
				for (let m in doc.Members)
				{
					if (m.Kind != .Ctor || m.Static)
						continue;
					anyCtor = true;
					AddOwnAllocation(self, selfName, m);
				}
				if (!anyCtor)
					AddOwnAllocation(self, selfName, null);
			}
			if (self.Kind == .Struct)
			{
				String fields = scope .();
				for (let m in doc.Members)
					if (m.Kind == .Field && !m.Static && !m.Const)
					{
						if (!fields.IsEmpty)
							fields.Append(", ");
						fields.AppendF("{} {}", m.Type?.ToString(.. scope String()), m.Name);
					}
				Add(.Make, scope $"Structs | {self.Name}", scope $"Make {self.Name}", selfName, fields).Tooltip.AppendF("Builds a {} from its fields", self.Name);
				Add(.BreakStruct, scope $"Structs | {self.Name}", scope $"Break {self.Name}", selfName, fields).Tooltip.AppendF("Splits a {} into its fields", self.Name);
			}
			if (self.Kind == .Enum)
			{
				String cases = scope .();
				for (let m in doc.Members)
				{
					if (m.Kind != .Case)
						continue;
					if (!cases.IsEmpty)
						cases.Append('\n');
					cases.Append(m.Name);
					String payload = scope .();
					for (let p in m.Payload)
					{
						if (!payload.IsEmpty)
							payload.Append(", ");
						payload.AppendF("{} {}", p.Type?.ToString(.. scope String()), p.Name);
					}
					Add(.MakeCase, scope $"Enums | {self.Name}", scope $"Make {self.Name}.{m.Name}", scope $"{selfName}.{m.Name}", payload).Tooltip.AppendF("The {} case {}", self.Name, m.Name);
					Add(.IsCase, scope $"Enums | {self.Name}", scope $"Is {self.Name}.{m.Name}", scope $"{selfName}.{m.Name}", payload).Tooltip.AppendF("True when the value is {}", m.Name);
				}
				Add(.Switch, scope $"Enums | {self.Name}", scope $"Switch on {self.Name}", selfName, cases).Tooltip.AppendF("Runs the output of the {} case the value is", self.Name);
			}

			// Flow Control
			Add(.Branch, "Flow Control", "Branch").Tooltip.Set("Runs True or False by the Condition");
			Add(.Flow, "Flow Control", "Sequence", FlowMacros.Sequence, "2").Tooltip.Set("Runs each Then output in order");
			Add(.Switch, "Flow Control", "Switch", "int", "0\n1").Tooltip.Set("Runs the case whose value matches, else Default; change what it switches on in Properties");
			Add(.ForEach, "Flow Control", "For Each Loop").Tooltip.Set("Runs Loop Body once per element of Collection");
			Add(.For, "Flow Control", "For Loop").Tooltip.Set("Runs Loop Body Count times; the counter is an output pin");
			Add(.While, "Flow Control", "While Loop").Tooltip.Set("Runs Loop Body while Condition holds");
			Add(.DoWhile, "Flow Control", "Do While Loop").Tooltip.Set("Runs Loop Body, then again while Condition holds");
			Add(.LoopBreak, "Flow Control", "For Each Loop with Break", "foreach").Tooltip.Set("A For Each Loop with a Branch and a Break already in its body");
			Add(.LoopBreak, "Flow Control", "For Loop with Break", "for").Tooltip.Set("A For Loop with a Branch and a Break already in its body");
			Add(.Break, "Flow Control", "Break").Tooltip.Set("Leaves the loop");
			Add(.Continue, "Flow Control", "Continue").Tooltip.Set("Goes on with the loop's next turn");
			Add(.Return, "Flow Control", "Return").Tooltip.Set("Leaves the function (with its Return Value when it has one)");
			Add(.Scope, "Flow Control", "Scope").Tooltip.Set("A region of its own: the Locals inside end with Body");
			Add(.Scope, "Flow Control", "Unsafe Scope", "", "unsafe").Tooltip.Set("A region where pointer nodes are allowed");
			Add(.Flow, "Flow Control | Gates", "Do Once", FlowMacros.DoOnce).Tooltip.Set("Runs Once the first time only");
			Add(.Flow, "Flow Control | Gates", "Reset Do Once", FlowMacros.DoOnceReset).Tooltip.Set("Lets a Do Once run again");
			Add(.Flow, "Flow Control | Gates", "Do N", FlowMacros.DoN).Tooltip.Set("Runs Do the first N times");
			Add(.Flow, "Flow Control | Gates", "Reset Do N", FlowMacros.DoNReset).Tooltip.Set("Lets a Do N count again");
			Add(.Flow, "Flow Control | Gates", "Flip Flop", FlowMacros.FlipFlop).Tooltip.Set("Alternates between A and B");
			Add(.Flow, "Flow Control | Gates", "Gate", FlowMacros.Gate).Tooltip.Set("Runs Exit while open (open / close / toggle it with the Gate nodes)");
			Add(.Flow, "Flow Control | Gates", "Open Gate", FlowMacros.GateOpen).Tooltip.Set("Opens a Gate");
			Add(.Flow, "Flow Control | Gates", "Close Gate", FlowMacros.GateClose).Tooltip.Set("Closes a Gate");
			Add(.Flow, "Flow Control | Gates", "Toggle Gate", FlowMacros.GateToggle).Tooltip.Set("Toggles a Gate");
			Add(.Flow, "Flow Control | Gates", "Multi Gate", FlowMacros.MultiGate, "3").Tooltip.Set("Runs the next output each time");
			Add(.Flow, "Flow Control | Gates", "Reset Multi Gate", FlowMacros.MultiGateReset).Tooltip.Set("Starts a Multi Gate over");
			Add(.ResultMatch, "Flow Control | Errors", "Result: match").Tooltip.Set("Runs Ok with the value or Err with the error");
			Add(.Try, "Flow Control | Errors", "Try").Tooltip.Set("Continues with the value; on an error, returns it from this function");
			Add(.Fatal, "Flow Control | Errors", "Fatal").Tooltip.Set("Stops the program with a message");

			// Lifetime
			Add(.Construct, "Lifetime", "Construct").Tooltip.Set("Allocates an object on the heap (choose the type in Properties); you delete it");
			Add(.Construct, "Lifetime", "Local", "", "local").Tooltip.Set("Allocates an object in this region (choose the type in Properties); freed when the region ends");
			Add(.Delete, "Lifetime", "Delete").Tooltip.Set("Runs the object's destructor and frees it");
			Add(.DeferDelete, "Lifetime", "Defer Delete").Tooltip.Set("Deletes the object when this region ends");
			Add(.Defer, "Lifetime", "Defer").Tooltip.Set("Runs Deferred when this region ends");
			if (mContext == .DataIn && !IsWild(mContextType))
			{
				let fam = TypeRules.Family(mContextType, mApp.Language.Hierarchy);
				if (fam == .Object || fam == .Struct)
				{
					Add(.Construct, "Lifetime", scope $"Construct {mContextType}", mContextType).Tooltip.AppendF("Allocates a {} on the heap; you delete it", mContextType);
					Add(.Construct, "Lifetime", scope $"Local {mContextType}", mContextType, "local").Tooltip.AppendF("Allocates a {} in this region", mContextType);
				}
			}

			// Math and utilities
			StringView[?] binaryOps = .("+", "-", "*", "/", "%", "==", "!=", "<", ">", "<=", ">=", "&&", "||", "&", "|", "^", "<<", ">>");
			StringView[?] binaryNames = .("Add", "Subtract", "Multiply", "Divide", "Remainder", "Equal", "Not Equal", "Less", "Greater",
				"Less Or Equal", "Greater Or Equal", "And", "Or", "Bitwise And", "Bitwise Or", "Bitwise Xor", "Shift Left", "Shift Right");
			for (int i < binaryOps.Count)
				Add(.Operator, "Math | Operators", scope $"{binaryOps[i]}  {binaryNames[i]}", binaryOps[i], "2").Tooltip.AppendF("A {} B", binaryOps[i]);
			Add(.Operator, "Math | Operators", "!  Not", "!", "1").Tooltip.Set("Not A (a bool)");
			Add(.Operator, "Math | Operators", "-  Negate", "neg", "1").Tooltip.Set("-A");
			Add(.Operator, "Math | Operators", "~  Bitwise Not", "~", "1").Tooltip.Set("~A");
			Add(.Math, "Math", "Math Expression").Tooltip.Set("A formula with one input per name (a * b + 1)");
			Add(.Select, "Utilities", "Select").Tooltip.Set("True or False by the Condition; only the chosen one is evaluated");
			Add(.Index, "Utilities | Collections", "Get [ ] (Index)").Tooltip.Set("Reads an element of the Collection by Index");
			if (mContext == .DataIn && !IsWild(mContextType))
				Add(.Cast, "Utilities | Casting", scope $"Cast To {mContextType}", mContextType).Tooltip.AppendF("Converts the value to {}", mContextType);
			Add(.Cast, "Utilities | Casting", "Cast To...").Tooltip.Set("Converts the value to the type set in Properties");
			Add(.Cast, "Utilities | Casting", "Cast To... (checked)", "", "", "checked").Tooltip.Set("Runs Succeeded when the object is of the type set in Properties, Failed when not");
			Add(.Bind, "Utilities | Functions as values", "Bind Function").Tooltip.Set("A delegate of a function (choose it in Properties)");
			Add(.Lambda, "Utilities | Functions as values", "Lambda").Tooltip.Set("A delegate whose body is a nested Sheet");
			Add(.Invoke, "Utilities | Functions as values", "Invoke").Tooltip.Set("Calls a delegate");
			if (mContext != .DataIn)
			{
				Add(.Literal, "Utilities | Literals", "Literal int", "0", "int").Tooltip.Set("A whole number fed to several nodes");
				Add(.Literal, "Utilities | Literals", "Literal float", "0.0f", "float").Tooltip.Set("A number with a fraction fed to several nodes");
				Add(.Literal, "Utilities | Literals", "Literal bool", "false", "bool").Tooltip.Set("true or false fed to several nodes");
				Add(.Literal, "Utilities | Literals", "Literal String", "\"\"", "String").Tooltip.Set("A text fed to several nodes");
			}
			if (mContext == .None)
				Add(.Comment, "Utilities", "Add Comment").Tooltip.Set("A comment box around the selected nodes (or here)");
			if (mContext != .None)
				Add(.Reroute, "Utilities", "Add Reroute Knot").Tooltip.Set("Draws the wire through a knot here");
		}

		/// "Construct Engine + Run": for each function of the project's other classes (and of the open
		/// class in a static Sheet, where there is no `this`), one row that places a Construct of the
		/// class, a Defer Delete of the object and the Call with the object as its Receiver. Listed
		/// when the menu opens on the canvas or from a flow pin; a Call needs an object, and this row
		/// brings one.
		void AddConstructCallRows(Sheet mg, StringView selfName, bool staticSheet)
		{
			if (mContext != .None && mContext != .Flow)
				return;
			for (let t in mApp.ProjectTypes.Types)
			{
				if (t.Kind != .Class || t.Static || t.Abstract || !t.Generics.IsEmpty)
					continue;
				bool own = t.FullName == selfName;
				if (own && !staticSheet)
					continue;
				// The constructor the Construct runs: the one without parameters, else the first.
				Treadle.Model.MemberDecl ctor = null;
				bool plain = true;
				for (let m in t.Members)
				{
					if (m.Kind != .Ctor || m.Static || (!own && !ProjectType.Visible(m)))
						continue;
					if (m.Params.IsEmpty)
					{
						ctor = null;
						plain = true;
						break;
					}
					if (ctor == null)
					{
						ctor = m;
						plain = false;
					}
				}
				String ctorParams = scope .();
				if (!plain && ctor != null)
					for (let p in ctor.Params)
					{
						if (!ctorParams.IsEmpty)
							ctorParams.Append(", ");
						ctorParams.AppendF("{} {}", p.Type?.ToString(.. scope String()), p.Name);
					}
				for (let m in t.Members)
				{
					if (m.Kind != .Function || m.Static || (!own && !ProjectType.Visible(m)))
						continue;
					String sig = scope .();
					String label = scope .();
					for (let p in m.Params)
					{
						if (@p.Index > 0)
						{
							sig.Append(',');
							label.Append(", ");
						}
						p.Type?.ToString(sig);
						p.Type?.ToString(label);
					}
					int sameName = 0;
					for (let o in t.Members)
						if (o.Kind == .Function && !o.Static && o.Name == m.Name)
							sameName++;
					let item = Add(.ConstructCall, scope $"Functions | {t.Name}",
						(sameName > 1) ? scope $"Construct {t.Name} + {m.Name} ({label})" : scope $"Construct {t.Name} + {m.Name}",
						t.FullName, m.Name, ctorParams);
					item.Extra.Set(sig);
					item.OnType.Set(t.FullName);
					item.Tooltip.AppendF("Makes a {0} (Construct), deletes it when this region ends (Defer Delete) and calls its {1} on it.\nTo call {1} on a {0} you already have, place {1} and wire the object into its Receiver.", t.Name, m.Name);
				}
			}
		}

		/// The catalogue entry of the instance function `name` of `owner` whose parameter types are
		/// `sig` ("int,float"; the only one by that name when no entry matches exactly), or -1.
		int32 FindMemberEntry(StringView owner, StringView name, StringView sig)
		{
			int32 any = -1;
			for (int32 id < (int32)Catalog.TotalEntries)
			{
				let spec = Catalog.Spec(id);
				if (spec.Label != name || spec.IsStatic || !spec.KindWord.IsEmpty || spec.Kind == .Get || spec.Kind == .Set || spec.Kind == .Event)
					continue;
				if (!NodeCatalog.SameOwner(owner, spec.OwnerType))
					continue;
				String have = scope .();
				for (let p in spec.Pins)
				{
					if (p.IsOutput || p.Name == "receiver" || p.Type.IsEmpty)
						continue;
					if (!have.IsEmpty)
						have.Append(',');
					have.Append(p.Type);
				}
				if (NoSpaces(have, .. scope String()) == NoSpaces(sig, .. scope String()))
					return id;
				if (any < 0)
					any = id;
			}
			return any;
		}

		/// Construct / Local rows of the open type (one per constructor).
		void AddOwnAllocation(Treadle.Model.TypeDecl self, StringView selfName, Treadle.Model.MemberDecl ctor)
		{
			String args = scope .();
			String label = scope .();
			if (ctor != null)
				for (let p in ctor.Params)
				{
					if (!args.IsEmpty)
						args.Append(", ");
					args.AppendF("{} {}", p.Type?.ToString(.. scope String()), p.Name);
					if (!label.IsEmpty)
						label.Append(", ");
					p.Type?.ToString(label);
				}
			String suffix = label.IsEmpty ? scope String() : scope $" ({label})";
			Add(.Construct, scope $"Lifetime | {self.Name}", scope $"Construct {self.Name}{suffix}", selfName, "", args).Tooltip.AppendF("Allocates a {} on the heap; you delete it", self.Name);
			Add(.Construct, scope $"Lifetime | {self.Name}", scope $"Local {self.Name}{suffix}", selfName, "local", args).Tooltip.AppendF("Allocates a {} in this region; freed when the region ends", self.Name);
		}

		/// "Make Literal" rows for a value input of the context type.
		void AddLiterals()
		{
			String t = scope .();
			NormalizeType(mContextType, t);
			void Lit(StringView text, StringView type)
			{
				Add(.Literal, "Utilities | Literals", scope $"Literal {text}", text, type).Tooltip.AppendF("{}  ({})", text, type.IsEmpty ? "any" : type);
			}
			if (t == "bool")
			{
				Lit("true", "bool");
				Lit("false", "bool");
			}
			else if (TypeRules.IsInt(t))
				Lit("0", t);
			else if (t == "float")
				Lit("0.0f", t);
			else if (t == "double")
				Lit("0.0", t);
			else if (TypeRules.IsChar(t))
				Lit("' '", t);
			else if (IsStringType(t))
				Lit("\"\"", t);
			let fam = TypeRules.Family(t, mApp.Language.Hierarchy);
			if (fam == .Object || fam == .Interface || fam == .Pointer || fam == .Delegate || t == "String")
				Lit("null", t);
			if (!IsWild(t))
				Lit("default", t);
		}

		public void Open(Sheet mg, ImVec2 spawnPos, int32 contextPinId)
		{
			Prepare(mg, spawnPos, contextPinId);
			mSearch.Set("");
			// Test hook: typing cannot be posted to SDL, so a scripted run
			// pre-fills the search box; choosing a result is still a real (posted) click.
			String debugSearch = scope .();
			if (Environment.GetEnvironmentVariable("TREADLE_DEBUG_NODE_MENU_SEARCH", debugSearch) case .Ok && !debugSearch.IsEmpty)
				mSearch.Set(debugSearch);
			mLastSearch.Set("\x01"); // force a refresh on the first frame
			mDirty = true;
			OpenRequested = true;
			mFocusSearch = true;
			SetHighlight(null);
			mNavOrder.Clear();
			mCaptureFor.Clear();
			mHotkeyMessage.Clear();
		}

		/// The context (the pin dragged from) and the local items for `mg`: what the menu lists when
		/// it opens there, without opening it.
		void Prepare(Sheet mg, ImVec2 spawnPos, int32 contextPinId)
		{
			SpawnPos = spawnPos;
			ContextPinId = contextPinId;
			ContextGraph = (mg != null) ? mg.Graph : null;
			mContext = .None;
			mContextType.Clear();
			mContextLabel.Clear();
			mContextFrom.Clear();
			mReturnType.Clear();
			mOwnerName.Clear();
			mContextIsTarget = false;
			mContextLambdaSig.Clear();
			ClearAndDeleteItems!(mExpandedOverloads);
			Prefs.Load();
			if (mg != null && mg.Graph.Entry != null)
			{
				// The Sheet's result type: the entry's `value` input when it has one.
				let ret = mg.Graph.Entry.FindInput("value");
				if (ret != null)
					mReturnType.Set(ret.TypeName);
			}
			let pin = (mg != null && contextPinId != 0) ? mg.Graph.FindPin(contextPinId) : null;
			if (pin != null)
			{
				NormalizeType(pin.TypeName, mContextType);
				if (pin.Kind == .Flow)
				{
					mContext = .Flow;
					mContextLabel.Set("Flow nodes");
				}
				else if (!pin.IsInput)
				{
					mContext = .DataOut;
					mContextLabel.AppendF("Nodes taking a{} {}", StartsWithVowel(mContextType) ? "n" : "", IsWild(mContextType) ? "value" : mContextType);
				}
				else
				{
					mContext = .DataIn;
					mContextLabel.AppendF("Nodes returning a{} {}", StartsWithVowel(mContextType) ? "n" : "", IsWild(mContextType) ? "value" : mContextType);
					mContextIsTarget = pin.Name == "receiver" && pin.Owner.Kind == .Call;
					LambdaSignature sig = scope .();
					if (mApp.ResolveDelegateType(pin.TypeName, sig))
						sig.ToText(mContextLambdaSig);
				}
				// The context line: which pin of which node the menu was dragged from.
				String title = scope .();
				pin.Owner.GetTitle(title);
				String pinLabel = scope .(pin.Label);
				if (pinLabel.IsEmpty)
					NodeFactory.LabelFor(pin.Name, pinLabel);
				if (pin.Kind == .Flow)
					mContextFrom.AppendF("From {}  \u{00B7}  {} (flow {})", title, pinLabel.IsEmpty ? "Exec" : pinLabel, pin.IsInput ? "input" : "output");
				else
					mContextFrom.AppendF("From {}  \u{00B7}  {} ({}{})", title, pinLabel, pin.IsInput ? "input, " : "", IsWild(mContextType) ? "any type" : (StringView)mContextType);
				mContextColor = (pin.Kind == .Flow) ? Theme.FlowAccent : Theme.PinColor(pin);
			}
			if (mg != null)
				mg.Doc.Header.GetFullName(mOwnerName);
			mApp.RefreshProjectTypes();
			MakeProbe(mg);
			Build(mg);
			mRelevanceValid = false;
			mContextIdsValid = false;
			mDirty = true;
		}

		/// Node hotkeys: the item a node key names, built for `mg` as the menu would list it there with
		/// the pin `contextPinId` (0 = none) as its context; SpawnPos and ContextPinId are set for the
		/// placement (EditorApp.ExecuteAction). Returns a copy the caller deletes, or null when this
		/// Sheet does not offer the node (Get a reference to this in a static function, a library
		/// node that is no longer indexed).
		public NodeItem ItemForKey(Sheet mg, ImVec2 spawnPos, int32 contextPinId, StringView key)
		{
			Prepare(mg, spawnPos, contextPinId);
			let found = FindItemByKey(key);
			if (found == null)
				return null;
			NodeItem copy = new .();
			copy.CopyFrom(found);
			copy.OrigCategory.Clear();
			return copy;
		}

		/// A local item or catalog entry by its key ("Category\tLabel"), or null.
		NodeItem FindItemByKey(StringView key)
		{
			int tab = key.IndexOf('\t');
			if (tab < 0)
				return null;
			let cat = key.Substring(0, tab);
			let label = key.Substring(tab + 1);
			for (let item in Items)
				if (item.Category == cat && item.Label == label)
					return item;
			// Catalog entry: find it by category and label (search by the label's words).
			List<SearchHit> hits = scope .();
			String q = scope .(label);
			int paren = q.IndexOf('(');
			if (paren > 0)
				q.RemoveToEnd(paren);
			Catalog.Search(q, hits, 50);
			for (let h in hits)
			{
				let ci = CatalogItem(h.Id);
				if (ci.Label == label && ci.Category == cat)
					return ci;
			}
			return null;
		}

		static bool StartsWithVowel(StringView s) => !s.IsEmpty && "aeiouAEIOU".Contains(s[0]) && !IsWild(s);

		// ------------------------------------------------------------------ catalog items

		/// Drops cached catalog items when the type index was rebuilt. Returns true when it did.
		bool SyncCatalogCache()
		{
			let gen = (int32)(TypesGeneration ^ (Catalog.TotalEntries << 8));
			if (mCatalogGeneration == gen)
				return false;
			for (let kv in mCatalogItems)
				delete kv.value;
			mCatalogItems.Clear();
			mCatalogGeneration = gen;
			return true;
		}

		/// The NodeItem for a catalog entry (made on first use).
		NodeItem CatalogItem(int32 id)
		{
			SyncCatalogCache();
			if (mCatalogItems.TryGetValue(id, let existing))
				return existing;
			NodeSpec spec = scope .();
			Catalog.GetSpec(id, spec);
			NodeItem item = new .();
			item.CatalogId = id;
			for (var part in StringView(spec.Category).Split('|'))
			{
				part.Trim();
				if (part.IsEmpty)
					continue;
				if (!item.Category.IsEmpty)
					item.Category.Append(" | ");
				item.Category.Append(part);
			}
			item.Label.Set(spec.Label);
			// An overloaded call is one row per overload, its parameters in the label.
			if (spec.KindWord.IsEmpty && spec.Kind != .Get && spec.Kind != .Set && spec.Kind != .Event)
			{
				let siblings = OverloadsOfSpec(spec);
				if (siblings != null && siblings.Count > 1)
					item.Label.AppendF(" ({})", spec.ParamsText);
			}
			item.Tooltip.Set(spec.Tooltip);
			item.Pure = spec.IsPure || (spec.KindWord.IsEmpty ? false : (spec.Kind == .Pure));
			item.Kind = .Catalog;
			item.OnType.Set(spec.OwnerType);
			item.C.Set(spec.ReturnType);
			if (!spec.KindWord.IsEmpty)
			{
				item.A.Set("node");
				item.B.Set(spec.ReturnType);
			}
			else
			{
				switch (spec.Kind)
				{
				case .Get, .Event:
					item.A.Set("get");
					item.B.Set(spec.ReturnType);
				case .Set:
					item.A.Set("set");
					item.B.Set(spec.ReturnType);
				default:
					item.A.Set("call");
				}
			}
			mCatalogItems[id] = item;
			return item;
		}

		/// Creates the node for a catalog item (typed pins, defaults, pure/exec from attributes).
		/// Returns null for non-catalog items.
		public Node CreateCatalogNode(Treadle.Graph.Graph g, NodeItem item, bool wantExec)
		{
			if (item.CatalogId < 0)
				return null;
			NodeSpec spec = scope .();
			Catalog.GetSpec(item.CatalogId, spec);
			if (!item.Label.StartsWith(spec.Label))
				return null; // the catalog changed since the menu was drawn
			let n = NodeFactory.FromSpec(g, spec, wantExec);
			// A call of an overloaded function names its parameter types (Graph-Format.md 2).
			if (n != null && n.Kind == .Call && !n.Text.Contains('('))
			{
				let siblings = OverloadsOfSpec(spec);
				if (siblings != null && siblings.Count > 1)
					SpecSignature(spec, n.Text);
			}
			return n;
		}

		// ------------------------------------------------------------------ overloads

		/// Catalogue calls and constructors grouped by what they overload ("call|Console|WriteLine",
		/// "Construct|String"), rebuilt with the catalogue. The front end's ITypeSystem does not list
		/// overloads; the catalogue (INodeCatalogSource) has one entry per overload and constructor,
		/// and the open type's own ones come from its document.
		Dictionary<String, List<int32>> mOverloads = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
		int32 mOverloadsGen = -2;

		static bool OverloadKey(NodeSpec spec, String outKey)
		{
			if (spec.KindWord == "Construct" || spec.KindWord == "Local")
			{
				outKey.AppendF("{}|{}", spec.KindWord, BaseTypeName(spec.Subject));
				return true;
			}
			if (!spec.KindWord.IsEmpty || spec.Kind == .Get || spec.Kind == .Set || spec.Kind == .Event || spec.MemberName.IsEmpty)
				return false;
			outKey.AppendF("call|{}|{}", BaseTypeName(spec.OwnerType), spec.MemberName);
			return true;
		}

		void SyncOverloads()
		{
			Catalog.Refresh();
			SyncCatalogCache();
			if (mOverloadsGen == mCatalogGeneration)
				return;
			for (let kv in mOverloads)
			{
				delete kv.key;
				delete kv.value;
			}
			mOverloads.Clear();
			mOverloadsGen = mCatalogGeneration;
			String key = scope .();
			for (int32 id < (int32)Catalog.TotalEntries)
			{
				key.Clear();
				if (!OverloadKey(Catalog.Specs[id], key))
					continue;
				if (!mOverloads.TryGetValue(key, var list))
				{
					list = new List<int32>();
					mOverloads[new String(key)] = list;
				}
				list.Add(id);
			}
		}

		/// The catalogue ids overloading the same function or constructor as `spec` (itself
		/// included), or null.
		List<int32> OverloadsOfSpec(NodeSpec spec)
		{
			String key = scope .();
			if (!OverloadKey(spec, key))
				return null;
			SyncOverloads();
			return mOverloads.TryGetValue(key, let list) ? list : null;
		}

		/// The vector type of the context pin (`float4`; empty when the menu was not opened from a vector pin).
		String mContextVector = new .() ~ delete _;

		/// Dragged from a vector pin (`float4`): its rows first, typed for it (VectorCatalog.Typed), in the
		/// group "Vector": from an output its Break, Swizzle, Shuffle, Get Lane, Set Lane and the reductions
		/// (Any / All of a mask); into an input its Make and Splat. The Operator rows take vectors as they are
		/// and come right after them (GroupRank).
		void AddVectorRows()
		{
			mContextVector.Clear();
			let g = ContextGraph as Treadle.Graph.Graph;
			let pin = (g != null && ContextPinId != 0) ? g.FindPin(ContextPinId) : null;
			if (pin == null || pin.Kind != .Value || !Treadle.Model.VectorTypes.Canonical(pin.TypeName, mContextVector))
				return;
			List<StringView> keys = scope .();
			VectorCatalog.ContextKeys(mContextVector, !pin.IsInput, keys);
			for (let k in keys)
			{
				let spec = scope NodeSpec();
				if (!VectorCatalog.Typed(k, mContextVector, spec))
					continue;
				let item = Add(.VectorNode, scope $"Vector | {mContextVector}", spec.Label, k, mContextVector);
				item.Pure = true;
				item.C.Set(spec.ReturnType);
				item.Tooltip.Set(spec.Tooltip);
			}
		}

		/// Dragged from a pin whose type is an instance of a generic struct (`Core.Pair<int,float>`): the
		/// catalogue's Break (from an output) or Make (into an input) of that struct, for this instance:
		/// "Break Pair<int,float>" with the fields typed by the type's arguments. The catalogue's own row
		/// names the generic struct and does not take the pin.
		void AddGenericStructRows()
		{
			let g = ContextGraph as Treadle.Graph.Graph;
			let pin = (g != null && ContextPinId != 0) ? g.FindPin(ContextPinId) : null;
			if (pin == null || pin.Kind != .Value || !pin.TypeName.Contains('<'))
				return;
			StringView pinType = pin.TypeName;
			let lt = pinType.IndexOf('<');
			let baseName = pinType.Substring(0, lt);
			let word = pin.IsInput ? "Make" : "Break";
			for (int32 id < (int32)Catalog.TotalEntries)
			{
				let spec = Catalog.Specs[id];
				// The pin may name the struct as the compiler shows it (`Pair<int,float>`) or in full.
				if (spec.KindWord != word || !(spec.Subject == baseName || (spec.Subject.EndsWith(baseName) && spec.Subject.Length > baseName.Length && spec.Subject[spec.Subject.Length - baseName.Length - 1] == '.')))
					continue;
				String typeText = scope:: $"{spec.Subject}{pinType.Substring(lt)}";
				List<StringView> types = scope .();
				for (let p in spec.Pins)
					types.Add(p.Type);
				List<String> inst = scope .();
				defer { ClearAndDeleteItems!(inst); }
				SplitPins.InstanceFieldTypes(typeText, types, inst);
				String fields = scope .();
				for (int i < spec.Pins.Count)
				{
					if (!fields.IsEmpty)
						fields.Append(", ");
					fields.AppendF("{} {}", inst[i], spec.Pins[i].Name.IsEmpty ? spec.Pins[i].Label : spec.Pins[i].Name);
				}
				String shortType = Node.ShortTypeName(typeText, .. scope String());
				String cat = scope $"Structs | {Node.ShortTypeName(baseName, .. scope String())}";
				let item = Add(pin.IsInput ? .Make : .BreakStruct, cat, scope $"{word} {shortType}", typeText, fields);
				item.Tooltip.AppendF(pin.IsInput ? "Builds a {} from its fields" : "Splits a {} into its fields", shortType);
				return;
			}
		}

		/// The functions of the catalogue that are C variadic (`IsVariadic`), by call name
		/// (`C.libc.printf`); rebuilt with the catalogue.
		HashSet<String> mVariadic = new .() ~ DeleteContainerAndItems!(_);
		int32 mVariadicGen = -2;

		/// The call names of the variadic functions in `specs`.
		public static void VariadicNames(List<NodeSpec> specs, HashSet<String> outNames)
		{
			for (let s in specs)
				if (s.IsVariadic && !s.CallName.IsEmpty && !outNames.ContainsAlt(StringView(s.CallName)))
					outNames.Add(new String(s.CallName));
		}

		/// Whether the Call node `n` calls a C variadic function (by its subject without a parameter list).
		public static bool IsVariadicIn(HashSet<String> names, Node n)
		{
			if (n == null || n.Kind != .Call || names.IsEmpty)
				return false;
			StringView name = n.Text;
			let paren = name.IndexOf('(');
			if (paren > 0)
				name = name.Substring(0, paren);
			return names.ContainsAlt(name);
		}

		/// Whether the Call node `n` calls a C variadic function of the catalogue: only then does it take
		/// extra inputs (`va0`, `va1`, ..., "+ arg").
		public bool IsVariadicCall(Node n)
		{
			if (n == null || n.Kind != .Call)
				return false;
			SyncOverloads();
			if (mVariadicGen != mCatalogGeneration)
			{
				mVariadicGen = mCatalogGeneration;
				ClearAndDeleteItems!(mVariadic);
				for (int32 id < (int32)Catalog.TotalEntries)
				{
					let s = Catalog.Specs[id];
					if (s.IsVariadic && !s.CallName.IsEmpty && !mVariadic.ContainsAlt(StringView(s.CallName)))
						mVariadic.Add(new String(s.CallName));
				}
			}
			return IsVariadicIn(mVariadic, n);
		}

		/// "(StringView,int)": the types of an entry's inputs (no output parameters).
		static void SpecSignature(NodeSpec spec, String outSig)
		{
			outSig.Append('(');
			bool first = true;
			for (let p in spec.Pins)
			{
				if (p.IsOutput)
					continue;
				if (!first)
					outSig.Append(',');
				first = false;
				outSig.Append(p.Type);
			}
			outSig.Append(')');
		}

		/// "StringView text, int count": an entry's inputs as a parameter list.
		static void SpecParams(NodeSpec spec, String outText)
		{
			for (let p in spec.Pins)
			{
				if (p.IsOutput)
					continue;
				if (!outText.IsEmpty)
					outText.Append(", ");
				outText.AppendF("{} {}", p.Type, p.Name);
			}
		}

		static void NoSpaces(StringView s, String outText)
		{
			for (let c in s.RawChars)
				if (c != ' ')
					outText.Append(c);
		}

		/// One overload or constructor a node can switch to (Properties' Overload / Constructor row).
		public class OverloadChoice
		{
			/// "WriteLine (int value)", "Construct String (StringView text)".
			public String Label = new .() ~ delete _;
			/// "(int)": the parameter types, as a Call subject or a `set ctor` names them.
			public String Signature = new .() ~ delete _;
			/// The row that makes the node of this overload (owned).
			public NodeItem Item ~ delete _;
		}

		/// The overloads a Call can switch between, or the constructors of a Construct / Local's type,
		/// with the index of the one the node uses (-1 = none of them). The open type's own functions
		/// and constructors come from its document (unsaved edits count); every other type's from the
		/// catalogue. Fewer than two choices: there is nothing to switch.
		public int OverloadsOf(Sheet mg, Node n, List<OverloadChoice> outChoices)
		{
			if (mg == null || n == null)
				return -1;
			let doc = mg.Doc;
			String selfName = scope .();
			doc.Header.GetFullName(selfName);
			int current = -1;
			if (n.Kind == .Call)
			{
				StringView text = n.Text;
				StringView sig = default;
				int paren = text.IndexOf('(');
				if (paren > 0)
				{
					sig = text.Substring(paren);
					text = text.Substring(0, paren);
				}
				int dot = NodeFactory.LastTopLevelDot(text);
				StringView owner = (dot > 0) ? text.Substring(0, dot) : "this";
				StringView member = (dot > 0) ? text.Substring(dot + 1) : text;
				if (n.OwnerType != null && !n.OwnerType.IsEmpty)
					owner = n.OwnerType;
				String nodeSig = NoSpaces(sig, .. scope String());
				// The node's arguments, when its subject names no signature.
				List<String> args = scope .();
				defer { ClearAndDeleteItems!(args); }
				for (let p in n.Inputs)
					if (p.Kind == .Value && p.Name != "receiver")
						args.Add(new String(p.Name));
				bool own = owner == "this" || owner == selfName || BaseTypeName(owner) == doc.Header.Name;
				if (own)
				{
					for (let m in doc.Members)
					{
						if (m.Kind != .Function || m.Name != member)
							continue;
						OverloadChoice c = new .();
						String paramsText = scope .();
						c.Signature.Append('(');
						for (let p in m.Params)
						{
							if (@p.Index > 0)
							{
								c.Signature.Append(',');
								paramsText.Append(", ");
							}
							let t = p.Type?.ToString(.. scope String()) ?? "";
							c.Signature.Append(t);
							paramsText.AppendF("{} {}", t, p.Name);
						}
						c.Signature.Append(')');
						c.Label.AppendF("{} ({})", m.Name, paramsText);
						c.Item = new NodeItem();
						c.Item.Kind = .CallOwn;
						c.Item.MemberSerial = m.Serial;
						c.Item.Pure = m.Pure;
						c.Item.Static = m.Static;
						c.Item.A.Set(m.Name);
						m.Returns?.ToString(c.Item.C);
						bool match = nodeSig.IsEmpty ? SameNames(m, args) : (NoSpaces(c.Signature, .. scope String()) == nodeSig);
						if (match && current < 0)
							current = outChoices.Count;
						outChoices.Add(c);
					}
					return current;
				}
				SyncOverloads();
				if (!mOverloads.TryGetValue(scope $"call|{BaseTypeName(owner)}|{member}", let overloadIds))
					return -1;
				// A copy: CatalogItem can refresh the catalogue, which rebuilds mOverloads and the specs.
				List<int32> ids = scope .(overloadIds.Count); ids.AddRange(overloadIds);
				int first = outChoices.Count;
				for (let id in ids)
				{
					let spec = Catalog.Specs[id];
					OverloadChoice c = new .();
					SpecSignature(spec, c.Signature);
					c.Label.AppendF("{} ({})", spec.Label, SpecParams(spec, .. scope String()));
					c.Item = new NodeItem();
					bool match;
					if (!nodeSig.IsEmpty)
						match = NoSpaces(c.Signature, .. scope String()) == nodeSig;
					else
					{
						int count = 0;
						match = true;
						for (let p in spec.Pins)
						{
							if (p.IsOutput)
								continue;
							count++;
							bool found = false;
							for (let a in args)
								found |= a == p.Name;
							match &= found;
						}
						match &= count == args.Count;
					}
					if (match && current < 0)
						current = outChoices.Count;
					outChoices.Add(c);
				}
				FillCatalogItems(outChoices, first, ids);
				return current;
			}
			if (n.Kind == .ChainCtor)
			{
				// A Base / This Constructor: the base class's constructors or the type's others.
				String nodeSig = NoSpaces(n.GetSetting("ctor"), .. scope String());
				if (nodeSig == "()")
					nodeSig.Clear();
				List<String> args = scope .();
				defer { ClearAndDeleteItems!(args); }
				for (let p in n.Inputs)
					if (p.Kind == .Value)
						args.Add(new String(p.Name));
				ChainChoices(mg, (n.Text == "this") ? "this" : "base", outChoices);
				for (let c in outChoices)
				{
					let mine = NoSpaces(c.Signature, .. scope String());
					bool match = !nodeSig.IsEmpty ? mine == nodeSig : (mine == "()" && args.IsEmpty);
					if (nodeSig.IsEmpty && !match && !args.IsEmpty)
					{
						// No `set ctor`: the one whose parameters the node's inputs name.
						List<(StringView name, StringView type)> parts = scope .();
						NodeFactory.SplitParams(c.Item.C, parts);
						match = parts.Count == args.Count;
						for (let p in parts)
							match &= args.Contains(scope String(p.name));
					}
					if (match && current < 0)
						current = @c.Index;
				}
				return current;
			}
			if (n.Kind != .Construct && n.Kind != .Local)
				return -1;
			bool local = n.Kind == .Local;
			String nodeSig = NoSpaces(n.GetSetting("ctor"), .. scope String());
			if (nodeSig == "()")
				nodeSig.Clear();
			let typeName = BaseTypeName(n.Text);
			// A generic type's constructors are listed for the node's instance (`Box<Point>`: (Point)).
			Dictionary<String, String> map = scope .();
			defer { for (let kv in map) { delete kv.key; delete kv.value; } }
			CtorTypeMap(mg, n.Text, map);
			String shownType = scope .();
			if (map.IsEmpty)
				shownType.Set(typeName);
			else
				Node.ShortTypeName(n.Text, shownType);
			if (typeName == doc.Header.Name && !doc.Header.Static)
			{
				for (let m in doc.Members)
				{
					if (m.Kind != .Ctor || m.Static)
						continue;
					OverloadChoice c = new .();
					String args = scope .();
					String types = scope .();
					for (let p in m.Params)
					{
						if (@p.Index > 0)
						{
							args.Append(", ");
							types.Append(", ");
						}
						let t = p.Type?.ToString(.. scope String()) ?? "";
						args.AppendF("{} {}", t, p.Name);
						types.Append(t);
					}
					let raw = NoSpaces(scope $"({types})", .. scope String());
					NodeFactory.SubstituteSignature(scope $"({types})", map, c.Signature);
					c.Label.AppendF("{} {} (", local ? "Local" : "Construct", shownType);
					SubstituteParams(args, map, c.Label);
					c.Label.Append(')');
					c.Item = new NodeItem();
					c.Item.Kind = .Construct;
					c.Item.A.Set(selfName);
					c.Item.B.Set(local ? "local" : "");
					c.Item.C.Set(args);
					let mine = NoSpaces(c.Signature, .. scope String());
					if (current < 0 && (mine == nodeSig || raw == nodeSig || (nodeSig.IsEmpty && m.Params.IsEmpty)))
						current = outChoices.Count;
					outChoices.Add(c);
				}
				return current;
			}
			SyncOverloads();
			if (!mOverloads.TryGetValue(scope $"{local ? "Local" : "Construct"}|{typeName}", let overloadIds))
				return -1;
			List<int32> ids = scope .(overloadIds.Count); ids.AddRange(overloadIds);
			int first = outChoices.Count;
			for (let id in ids)
			{
				let spec = Catalog.Specs[id];
				OverloadChoice c = new .();
				String rawSig = SpecSignature(spec, .. scope String());
				NodeFactory.SubstituteSignature(rawSig, map, c.Signature);
				c.Label.AppendF("{} {} (", local ? "Local" : "Construct", map.IsEmpty ? BaseTypeName(spec.Subject) : (StringView)shownType);
				SubstituteParams(SpecParams(spec, .. scope String()), map, c.Label);
				c.Label.Append(')');
				c.Item = new NodeItem();
				let mine = NoSpaces(c.Signature, .. scope String());
				let raw = NoSpaces(rawSig, .. scope String());
				if (current < 0 && (mine == nodeSig || raw == nodeSig || (nodeSig.IsEmpty && mine == "()")))
					current = outChoices.Count;
				outChoices.Add(c);
			}
			FillCatalogItems(outChoices, first, ids);
			return current;
		}

		/// The rows of the choices from `first` on, one per catalogue id, after every spec was read:
		/// CatalogItem can refresh the catalogue, which deletes the specs (and mOverloads' lists).
		void FillCatalogItems(List<OverloadChoice> choices, int first, List<int32> ids)
		{
			for (int i < ids.Count)
			{
				if (first + i >= choices.Count)
					break;
				let item = CatalogItem(ids[i]);
				if (item != null)
					choices[first + i].Item.CopyFrom(item);
			}
		}

		/// The generic parameters ("T,U") of the type a Construct / Local / Base Constructor makes:
		/// the open type's own, else the catalogue's (its Construct entries name them), else the
		/// project's type files'.
		void CtorGenerics(Sheet mg, StringView typeText, String outGenerics)
		{
			let baseName = BaseTypeName(typeText);
			let doc = mg?.Doc;
			if (doc != null && baseName == doc.Header.Name)
			{
				for (let gp in doc.Header.Generics)
					outGenerics.AppendF("{}{}", outGenerics.IsEmpty ? "" : ",", gp.Name);
				return;
			}
			SyncOverloads();
			if (mOverloads.TryGetValue(scope $"Construct|{baseName}", let ids) && !ids.IsEmpty)
			{
				outGenerics.Append(Catalog.Specs[ids[0]].TypeGenerics);
				return;
			}
			let pt = mApp.ProjectTypes.Find(typeText);
			if (pt != null)
				for (let gp in pt.Generics)
					outGenerics.AppendF("{}{}", outGenerics.IsEmpty ? "" : ",", gp);
		}

		/// The generic parameters of the type `typeText` names mapped to its arguments (`Box<Point>`:
		/// T -> Point); empty without arguments. The caller deletes the keys and values.
		public void CtorTypeMap(Sheet mg, StringView typeText, Dictionary<String, String> outMap)
		{
			if (!typeText.Contains('<'))
				return;
			String generics = scope .();
			CtorGenerics(mg, typeText, generics);
			NodeFactory.TypeArgMap(generics, typeText, outMap);
		}

		/// "int legs, T value" with the generic parameters of `map` replaced.
		static void SubstituteParams(StringView paramsText, Dictionary<String, String> map, String outText)
		{
			List<(StringView name, StringView type)> parts = scope .();
			NodeFactory.SplitParams(paramsText, parts);
			for (let p in parts)
			{
				if (@p.Index > 0)
					outText.Append(", ");
				TypeRules.Substitute(p.type, map, outText);
				outText.AppendF(" {}", p.name);
			}
		}

		/// The constructors a constructor's Sheet can run first (Language.md 2.5): `which` "base",
		/// those of the base class (its arguments put for its generic parameters, `base Box<int>`),
		/// or "this", the type's other constructors. Each choice's row places a Base / This
		/// Constructor node with an input per parameter.
		public void ChainChoices(Sheet mg, StringView which, List<OverloadChoice> outChoices)
		{
			if (mg == null || mg.Member == null || mg.Member.Kind != .Ctor)
				return;
			let doc = mg.Doc;
			bool isBase = which == "base";
			StringView title = isBase ? "Base Constructor" : "This Constructor";
			int first = outChoices.Count;
			void AddChoice(StringView paramsText, StringView why)
			{
				OverloadChoice c = new .();
				List<(StringView name, StringView type)> parts = scope .();
				NodeFactory.SplitParams(paramsText, parts);
				String types = scope .();
				for (let p in parts)
					types.AppendF("{}{}", types.IsEmpty ? "" : ", ", p.type);
				c.Signature.AppendF("({})", types);
				c.Label.AppendF("{} ({})", title, paramsText);
				c.Item = new NodeItem();
				c.Item.Kind = .ChainCtor;
				c.Item.Category.Set("Functions | Constructors");
				c.Item.Label.Set(title);
				if (!types.IsEmpty)
					c.Item.Label.AppendF(" ({})", types);
				c.Item.A.Set(which);
				c.Item.C.Set(paramsText);
				c.Item.Tooltip.AppendF("{}: {}", title, why);
				outChoices.Add(c);
			}
			if (isBase)
			{
				if (doc.Header.Kind != .Class || doc.Header.Base == null)
					return;
				String baseText = doc.Header.Base.ToString(.. scope String());
				let baseName = BaseTypeName(baseText);
				Dictionary<String, String> map = scope .();
				defer { for (let kv in map) { delete kv.key; delete kv.value; } }
				CtorTypeMap(mg, baseText, map);
				String why = scope $"runs a constructor of {baseText} first, then this one's body (constructors are not inherited)";
				SyncOverloads();
				if (mOverloads.TryGetValue(scope $"Construct|{baseName}", let overloadIds))
				{
					List<int32> ids = scope .(overloadIds.Count);
					ids.AddRange(overloadIds);
					for (let id in ids)
					{
						let spec = Catalog.Specs[id];
						String paramsText = scope .();
						SubstituteParams(SpecParams(spec, .. scope String()), map, paramsText);
						AddChoice(paramsText, why);
					}
				}
				else if (mApp.ProjectTypes.Find(baseText) != null)
				{
					for (let m in mApp.ProjectTypes.Find(baseText).Members)
					{
						if (m.Kind != .Ctor || m.Static || m.Access == .Private)
							continue;
						String paramsText = scope .();
						for (let p in m.Params)
						{
							if (!paramsText.IsEmpty)
								paramsText.Append(", ");
							TypeRules.Substitute(p.Type?.ToString(.. scope String()) ?? "", map, paramsText);
							paramsText.AppendF(" {}", p.Name);
						}
						AddChoice(paramsText, why);
					}
				}
				if (outChoices.Count == first)
					AddChoice("", why);
				return;
			}
			for (let m in doc.Members)
			{
				if (m.Kind != .Ctor || m.Static || m == mg.Member)
					continue;
				String paramsText = scope .();
				for (let p in m.Params)
				{
					if (!paramsText.IsEmpty)
						paramsText.Append(", ");
					paramsText.AppendF("{} {}", p.Type?.ToString(.. scope String()) ?? "", p.Name);
				}
				AddChoice(paramsText, scope $"runs another constructor of {doc.Header.Name} first, then this one's body");
			}
		}

		static bool SameNames(Treadle.Model.MemberDecl m, List<String> args)
		{
			if (m.Params.Count != args.Count)
				return false;
			for (let p in m.Params)
				if (!args.Contains(p.Name))
					return false;
			return true;
		}

		/// Switches a Call to another overload or a Construct / Local to another constructor: the
		/// node keeps its id and position; pins of the same name stay, with the wires that still
		/// fit (NodeFactory.AdoptShape).
		public bool SwitchOverload(Sheet mg, Node n, OverloadChoice choice)
		{
			let g = mg.Graph;
			let shape = CreateNode(mg, g, choice.Item, n.ExecIn != null, false);
			if (shape == null)
				return false;
			if (shape.Kind != n.Kind)
			{
				g.RemoveNode(shape);
				return false;
			}
			if (shape.Kind == .Call && !shape.Text.Contains('('))
				shape.Text.Append(choice.Signature);
			if (shape.Kind == .Construct || shape.Kind == .Local)
			{
				// The node keeps the type it makes; a generic one's constructor is put to its arguments.
				String type = scope .(n.Text);
				shape.SetSubjectTypeText(type);
				shape.FindOutput("object")?.SetTypeText(type);
				Dictionary<String, String> map = scope .();
				defer { for (let kv in map) { delete kv.key; delete kv.value; } }
				CtorTypeMap(mg, type, map);
				NodeFactory.InstantiateCtor(g, shape, map);
			}
			NodeFactory.AdoptShape(g, n, shape);
			return true;
		}

		/// Properties > Type of a Construct / Local: the node makes `type` now. Its constructor is
		/// looked up again for that type: the one it had (the same declaration, with a generic
		/// type's new arguments put for its parameters: `Box<T>`'s (T) is (Point) for `Box<Point>`),
		/// or, for another type, the one its inputs name; the pins follow, wires that still fit stay.
		public void RetypeAllocation(Sheet mg, Node n, StringView type)
		{
			if (mg == null || n == null || (n.Kind != .Construct && n.Kind != .Local))
				return;
			let g = mg.Graph;
			List<OverloadChoice> before = scope .();
			defer { ClearAndDeleteItems!(before); }
			let had = OverloadsOf(mg, n, before);
			bool sameType = BaseTypeName(n.Text) == BaseTypeName(type);
			String newType = scope .(type);
			NodeFactory.SetAllocType(g, n, newType);
			List<OverloadChoice> after = scope .();
			defer { ClearAndDeleteItems!(after); }
			OverloadsOf(mg, n, after);
			int pick = -1;
			if (sameType && had >= 0 && had < after.Count)
				pick = had;
			else if (!sameType)
			{
				// Another type: its constructor whose parameters the node's inputs name, else its only one.
				List<String> args = scope .();
				defer { ClearAndDeleteItems!(args); }
				for (let p in n.Inputs)
					if (p.Kind == .Value && p.Role == .Arg)
						args.Add(new String(p.Name));
				for (let c in after)
				{
					List<(StringView name, StringView type)> parts = scope .();
					let paren = c.Label.IndexOf('(');
					if (paren > 0 && c.Label.EndsWith(')'))
						NodeFactory.SplitParams(StringView(c.Label, paren + 1, c.Label.Length - paren - 2), parts);
					bool match = parts.Count == args.Count;
					for (let p in parts)
						match &= args.Contains(scope String(p.name));
					if (match && pick < 0)
						pick = @c.Index;
				}
				if (pick < 0 && after.Count == 1)
					pick = 0;
				if (pick < 0)
					n.RemoveSetting("ctor");
			}
			if (pick >= 0)
				SwitchOverload(mg, n, after[pick]);
			g.Version++;
		}

		/// Remembers the choice in "Recently Used".
		public void NoteUsed(NodeItem item)
		{
			String key = scope .();
			item.GetKey(key);
			Prefs.Used(key);
		}

		// ------------------------------------------------------------------ filtering

		/// How well a local row fits the pin the menu was opened from (0 = hide it): the row's node
		/// is made in a scratch graph and the best of its pins is asked whether it takes the wire
		/// (PinMatch, the rule the wire drop uses), so the list never offers a node that could not
		/// be wired to the pin.
		int32 ContextRelevance(NodeItem item)
		{
			if (mContext == .None)
				return (item.Kind == .Reroute) ? 0 : 1;
			switch (item.Kind)
			{
			case .Comment: return 0;
			case .Reroute: return 1;
			case .NewFunction: return (mContext == .Flow) ? 1 : 0;
			case .Lambda: if (!mContextLambdaSig.IsEmpty) return 3;
			case .VectorNode: return 3; // made for the context pin's own vector type
			default:
			}
			let g = ContextGraph as Treadle.Graph.Graph;
			let ctx = (g != null && ContextPinId != 0) ? g.FindPin(ContextPinId) : null;
			if (ctx == null || mProbe == null)
				return 1;
			return ProbeFit(scope (pg) => CreateNode(mProbeSheet, pg, item, WantFlow(item, ctx), true), ctx);
		}

		/// Makes a node in the scratch graph, scores its best pin against `ctx`, then clears the
		/// scratch graph again.
		int32 ProbeFit(delegate Node(Treadle.Graph.Graph g) make, Pin ctx)
		{
			let n = make(mProbe);
			int32 score = 0;
			if (n != null)
				PinMatch.Best(mApp.Language, mProbe, n, ctx, out score);
			while (!mProbe.Nodes.IsEmpty)
				mProbe.RemoveNode(mProbe.Nodes.Back);
			return score;
		}

		/// Whether a node made for the context pin gets flow pins: calls made for a value input are
		/// value calls; from a value output they are flow calls when they return nothing or follow a
		/// flow node (they are chained after it).
		public static bool WantFlow(NodeItem item, Pin ctx)
		{
			if (ctx == null || ctx.Kind == .Flow)
				return true;
			if (ctx.IsInput)
				return false;
			return item.C.IsEmpty || item.C == "void" || ctx.Owner.IsExecNode;
		}

		/// The scratch graph the context filter makes nodes in (the Sheet's own type, member and
		/// language, so variables and Receivers resolve as they would in the Sheet).
		Treadle.Graph.Graph mProbe ~ delete _;
		Sheet mProbeSheet;

		void MakeProbe(Sheet mg)
		{
			DeleteAndNullify!(mProbe);
			mProbeSheet = mg;
			if (mg == null)
				return;
			mProbe = new .();
			mProbe.Language = mApp.Language;
			mProbe.Member = mg.Member;
			mProbe.Role = mg.Role;
			mProbe.SelfType.Set(mg.Graph.SelfType);
			mProbe.StaticContext = mg.Graph.StaticContext;
			mProbe.MethodKey.Set(mg.Key);
		}

		/// Parameter text ("int x, String name") as names and types (views into `text`).
		static void SplitParamText(StringView text, List<StringView> outNames, List<StringView> outTypes)
		{
			List<(StringView name, StringView type)> parts = scope .();
			NodeFactory.SplitParams(text, parts);
			for (let p in parts)
			{
				outNames.Add(p.name);
				outTypes.Add(p.type);
			}
		}

		/// The node a local row makes, in `g` (the Sheet's graph, or the scratch graph when `probe`).
		/// Rows that change the document (a new local, a new function) make a stand-in in a probe
		/// and are completed by the caller otherwise; layout rows (Comment, Reroute) make none.
		/// Catalogue rows go through NodeFactory.FromSpec.
		public Node CreateNode(Sheet mg, Treadle.Graph.Graph g, NodeItem item, bool wantExec, bool probe)
		{
			if (item.CatalogId >= 0)
				return CreateCatalogNode(g, item, wantExec);
			String selfName = scope .();
			mg?.Doc.Header.GetFullName(selfName);
			List<StringView> names = scope .();
			List<StringView> types = scope .();
			switch (item.Kind)
			{
			case .Catalog:
				return null;
			case .CallOwn:
				Treadle.Model.MemberDecl m = null;
				if (mg != null)
					for (let o in mg.Doc.Members)
						if (o.Serial == item.MemberSerial)
							m = o;
				if (m == null)
					return null;
				return CallOwn(g, m, selfName, wantExec && !m.Pure);
			case .GetVar, .SetVar:
				let member = mg?.Doc.FindMember(item.A);
				bool own = member != null && g.FindLocal(item.A) == null && (g.Member == null || g.Member.FindParam(item.A) == null);
				bool isStatic = own && (member.Static || mg.Doc.Header.Static);
				StringView variable = isStatic ? scope:: $"{selfName}.{item.A}" : (StringView)item.A;
				Node n = (item.Kind == .GetVar) ? NodeFactory.Get(g, variable, item.B) : NodeFactory.Set(g, variable, item.B);
				if (isStatic)
				{
					let r = n.FindInput("receiver");
					if (r != null)
						g.RemovePin(r);
				}
				return n;
			case .LocalVar:
				return probe ? NodeFactory.Set(g, "local:newVar", "") : null;
			case .NewFunction:
				return probe ? NodeFactory.MemberCall(g, "NewFunction()", "", true, default, default, "void") : null;
			case .Comment, .Reroute:
				return null;
			case .Branch:
				return NodeFactory.Branch(g);
			case .While:
				return NodeFactory.Loop(g, .While);
			case .DoWhile:
				return NodeFactory.Loop(g, .DoWhile);
			case .For:
				return NodeFactory.Loop(g, .For);
			case .ForEach:
				return NodeFactory.Loop(g, .ForEach);
			case .Return:
				String ret = scope .();
				mg?.Member?.Returns?.ToString(ret);
				return NodeFactory.Return(g, ret.IsEmpty ? "void" : ret);
			case .Break:
				return NodeFactory.Jump(g, .Break);
			case .Continue:
				return NodeFactory.Jump(g, .Continue);
			case .Switch:
				List<StringView> labels = scope .();
				for (let part in item.B.Split('\n'))
					if (!part.IsEmpty)
						labels.Add(part);
				return NodeFactory.Switch(g, item.A, labels);
			case .Flow:
				int arms = 2;
				if (!item.B.IsEmpty && (int.Parse(item.B) case .Ok(let parsed)))
					arms = parsed;
				return NodeFactory.Flow(g, FlowMacros.KindOf(item.A), arms);
			case .LoopBreak:
				// A loop with a Branch and a Break in its body.
				let loop = NodeFactory.Loop(g, (item.A == "foreach") ? .ForEach : .For);
				let brk = NodeFactory.Branch(g);
				brk.FindInput("condition").Default.Set("false");
				let jump = NodeFactory.Jump(g, .Break);
				g.Connect(loop.FindOutput("body"), brk.ExecIn);
				g.Connect(brk.FindOutput("true"), jump.ExecIn);
				return loop;
			case .Literal:
				return NodeFactory.Literal(g, item.B, item.A);
			case .Operator:
				return NodeFactory.Operator(g, item.A);
			case .Select:
				return NodeFactory.Select(g);
			case .Index:
				return NodeFactory.Index(g);
			case .Cast:
				return NodeFactory.Cast(g, item.A, item.C == "checked");
			case .Construct:
				SplitParamText(item.C, names, types);
				return NodeFactory.Construct(g, item.A, item.B == "local", false, names, types);
			case .ChainCtor:
				SplitParamText(item.C, names, types);
				return NodeFactory.ChainCtor(g, item.A, names, types);
			case .Delete:
				return NodeFactory.Delete(g);
			case .DeferDelete:
				return NodeFactory.DeferDelete(g);
			case .Defer:
				return NodeFactory.Defer(g);
			case .Scope:
				let n = NodeFactory.Scope(g);
				n.Unsafe = item.B == "unsafe";
				return n;
			case .ResultMatch:
				return NodeFactory.ResultMatch(g);
			case .Try:
				return NodeFactory.Try(g);
			case .Fatal:
				return NodeFactory.Fatal(g);
			case .Make:
				SplitParamText(item.B, names, types);
				return NodeFactory.Make(g, item.A, names, types);
			case .BreakStruct:
				SplitParamText(item.B, names, types);
				return NodeFactory.BreakStruct(g, item.A, names, types);
			case .MakeCase:
				SplitParamText(item.B, names, types);
				return NodeFactory.MakeCase(g, item.A, names, types);
			case .IsCase:
				SplitParamText(item.B, names, types);
				return NodeFactory.IsCase(g, item.A, names, types);
			case .This:
				return NodeFactory.This(g, g.SelfType);
			case .Base:
				String b = scope .();
				mg?.Doc.Header.Base?.ToString(b);
				return NodeFactory.Base(g, b);
			case .Lambda:
				return NodeFactory.Lambda(g);
			case .Bind:
				return NodeFactory.Bind(g, item.A);
			case .Invoke:
				return NodeFactory.Create(g, .Invoke);
			case .Math:
				return NodeFactory.MathExpression(g, "a * b");
			case .MoreOverloads:
				return null; // a list row, not a node
			case .ConstructCall:
				// Construct T, Defer Delete, then the Call of T's function on the new object.
				let id = FindMemberEntry(item.A, item.B, item.Extra);
				Node call = null;
				if (id >= 0)
					call = CreateCatalogNode(g, CatalogItem(id), true);
				if (call == null && !probe)
					return null;
				SplitParamText(item.C, names, types);
				return NodeFactory.ConstructDeferCall(g, item.A, call, SpawnPos.x, SpawnPos.y, names, types);
			case .VectorNode:
				let spec = scope NodeSpec();
				if (!VectorCatalog.Typed(item.A, item.B, spec))
					return null;
				return NodeFactory.FromSpec(g, spec, false);
			}
		}

		/// A Call of a function of the open type: `this.Name(Types)` with a Receiver (unwired =
		/// this), or `Type.Name(Types)` for a static one; arguments and further outputs by name.
		public static Node CallOwn(Treadle.Graph.Graph g, Treadle.Model.MemberDecl m, StringView selfName, bool wantExec)
		{
			List<StringView> names = scope .();
			List<StringView> types = scope .();
			List<StringView> mods = scope .();
			String sig = scope .("(");
			for (let p in m.Params)
			{
				if (@p.Index > 0)
					sig.Append(',');
				String t = p.Type?.ToString(.. scope:: String()) ?? "";
				sig.Append(t);
				names.Add(p.Name);
				types.Add(t);
				mods.Add((p.Mode == .Ref) ? "ref" : ((p.Mode == .Out) ? "out" : ((p.Mode == .In) ? "in" : "")));
			}
			sig.Append(')');
			for (let p in m.Outs)
			{
				names.Add(p.Name);
				types.Add(p.Type?.ToString(.. scope:: String()) ?? "");
				mods.Add("out");
			}
			String ret = scope .();
			m.Returns?.ToString(ret);
			if (ret.IsEmpty)
				ret.Set("void");
			Node n;
			if (m.Static)
				n = NodeFactory.StaticCall(g, scope $"{m.Name}{sig}", selfName, wantExec, names, types, ret, mods);
			else
				n = NodeFactory.MemberCall(g, scope $"{m.Name}{sig}", "", wantExec, names, types, ret, mods);
			for (let p in m.Params)
			{
				if (p.Default == null)
					continue;
				n.FindInput(p.Name)?.Default.Set(p.Default);
			}
			return n;
		}

		/// Every word must appear (case-insensitive), or the letters must appear in order.
		static float LocalScore(NodeItem item, StringView search)
		{
			if (search.IsEmpty)
				return 1;
			// The label, its camel-case words ("TakeDamage" -> "Take Damage"), its category and the
			// menu group it is shown in ("comparison" finds ==).
			String key = scope .();
			key.AppendF("{} ", item.Label);
			NodeCatalog.Words(item.Label, key);
			key.AppendF(" {} ", item.Category);
			DisplayGroup(item, key);
			// The name as one word ("mlegs" for Set mLegs) and an own function's parameters ("int value").
			if (item.Kind == .GetVar || item.Kind == .SetVar)
				key.AppendF(" {}", item.A);
			else if (item.Kind == .CallOwn && !item.B.IsEmpty)
				key.AppendF(" {}", item.B);
			key.ToLower();
			String q = scope .(search);
			q.ToLower();
			List<StringView> words = scope .();
			for (let w in q.Split(' '))
				if (!w.IsEmpty)
					words.Add(w);
			var score = NodeCatalog.ScoreKey(key, item.Label, words);
			if (score <= 0)
				return 0;
			if (StringView(item.Label).Equals(search, true))
				score += 30;
			score -= item.Label.Length * 0.05f;
			// "Call <typed text>()" / "Expression: ..." always match exactly; prefer real actions.
			if (item.Category == "Custom")
				score -= 200;
			return score;
		}

		/// Catalogue entries that fit the context pin (once per open): the catalogue's own
		/// relevance first (cheap), then the entry's node is made in the scratch graph and must
		/// take the wire (PinMatch), like the local rows.
		void ComputeContextIds()
		{
			mContextIds.Clear();
			mContextIdsValid = true;
			if (mContext != .DataOut && mContext != .DataIn && mContext != .Flow)
				return;
			let g = ContextGraph as Treadle.Graph.Graph;
			let pin = (g != null && ContextPinId != 0) ? g.FindPin(ContextPinId) : null;
			let ctx = (mContext == .DataOut) ? PinContext.TakesValue : PinContext.GivesValue;
			for (int32 id < (int32)Catalog.TotalEntries)
			{
				if (IsOwnMember(id))
					continue;
				// The vector table's rows for any vector (`T`) never fit a pin by their types; from a
				// vector pin its typed rows are listed instead (AddVectorRows).
				let standIn = Catalog.Spec(id);
				if (standIn.StandIn && (standIn.IsGeneric || !mContextVector.IsEmpty))
					continue;
				// From a scalar pin only the common vectors of exactly that element (a float: Make / Splat
				// float2, float3, float4), not every vector the scalar converts into.
				if (standIn.StandIn && (standIn.IsAdvanced || mContext == .Flow || IsWild(mContextType) || Catalog.ContextRelevance(id, ctx, mContextType) < 3))
					continue;
				if (mContext == .Flow)
				{
					let kind = Catalog.KindOf(id);
					if (kind != .Call && kind != .Set && kind != .Flow)
						continue;
				}
				else if (!IsWild(mContextType) && Catalog.ContextRelevance(id, ctx, mContextType) < 1)
					continue;
				if (pin != null && mProbe != null)
				{
					let spec = Catalog.Spec(id);
					bool flow = pin.Kind == .Flow || (!pin.IsInput && (spec.ReturnType.IsEmpty || spec.ReturnType == "void" || pin.Owner.IsExecNode));
					if (ProbeFit(scope (pg) => NodeFactory.FromSpec(pg, spec, flow), pin) == 0)
						continue;
				}
				mContextIds.Add(id);
			}
		}

		/// Catalogue entries about the open type are left out: its members, Construct / Local and
		/// the like are local rows made from the open document (which may be unsaved).
		bool IsOwnMember(int32 id)
		{
			if (mOwnerName.IsEmpty)
				return false;
			let spec = Catalog.Spec(id);
			if (spec.OwnerType == mOwnerName)
				return true;
			if (spec.KindWord.IsEmpty)
				return false;
			StringView subject = spec.Subject;
			if (spec.KindWord == "MakeCase" || spec.KindWord == "IsCase")
				subject = NodeFactory.EnumOfCase(subject);
			return subject == mOwnerName;
		}

		static bool IsIdentChar(char8 c) => c.IsLetterOrDigit || c == '_' || c == '@';

		void ClearGroups()
		{
			for (let kv in mGroups)
				delete kv.value;
			mGroups.Clear();
			ClearAndDeleteItems!(mGroupOrder);
			mVisibleCount = 0;
		}

		void AddToGroup(NodeItem item)
		{
			// Rows are shown under the menu's groups; their own category stays their key (favorites,
			// hotkeys and recents are stored by it).
			String path = scope .();
			if (!item.OrigCategory.IsEmpty)
				path.Set(item.Category); // a Favorites / Recently Used copy
			else
				DisplayGroup(item, path);
			if (!mGroups.TryGetValue(path, var list))
			{
				list = new List<NodeItem>();
				let key = new String(path);
				mGroupOrder.Add(key);
				mGroups[key] = list;
			}
			list.Add(item);
			mVisibleCount++;
		}

		/// The menu's top-level groups, in the order they are listed when nothing is typed.
		public static StringView[?] sGroupOrder = .("Flow", "Variables", "Functions", "Types", "Core", "C", "Math", "Comparison", "Logic", "Strings", "Sheet");

		static bool IsStringOwner(StringView type)
		{
			let b = BaseTypeName(type);
			return b == "String" || b == "StringView";
		}

		/// Where a row is shown: one of `sGroupOrder` with the row's own subgroup under it
		/// ("Flow | Gates", "Functions | Player", "Types | Pair", "Core | List", "C | libc", "Strings | String").
		public static void DisplayGroup(NodeItem item, String outPath)
		{
			StringView cat = item.Category;
			let top = TopLevel(cat);
			int bar = cat.IndexOf('|');
			var rest = (bar >= 0) ? cat.Substring(bar + 1) : StringView();
			rest.Trim();
			void Put(StringView group, StringView sub)
			{
				outPath.Append(group);
				if (!sub.IsEmpty)
					outPath.AppendF(" | {}", sub);
			}
			if (item.Kind == .Catalog)
			{
				// The last segment of the catalogue's path names the type ("Core | Pair" -> Pair).
				int last = cat.LastIndexOf('|');
				var typeName = (last >= 0) ? cat.Substring(last + 1) : cat;
				typeName.Trim();
				if (cat == VectorCatalog.Category)
					Put("Math", "Vector");
				else if (top == "C")
					Put("C", rest);
				else if (item.A == "node")
					Put("Types", typeName);
				else if (item.A == "get" || item.A == "set")
					Put("Variables", typeName);
				else if (IsStringOwner(item.OnType) || typeName == "String" || typeName == "StringView")
					Put("Strings", typeName);
				else if (typeName == "Math")
					Put("Math", typeName);
				else if (top == "Core")
					Put("Core", typeName);
				else
					Put("Functions", typeName);
				return;
			}
			switch (item.Kind)
			{
			case .Operator:
				switch (item.A)
				{
				case "==", "!=", "<", ">", "<=", ">=": Put("Comparison", "");
				case "&&", "||", "!": Put("Logic", "");
				case "&", "|", "^", "<<", ">>", "~": Put("Math", "Bitwise");
				default: Put("Math", "");
				}
				return;
			case .Select:
				Put("Logic", "");
				return;
			case .Math:
				Put("Math", "");
				return;
			case .Comment, .Reroute:
				Put("Sheet", "");
				return;
			case .Literal:
				if (IsStringType(item.B))
					Put("Strings", "Literals");
				else
					Put("Variables", "Literals");
				return;
			default:
			}
			switch (top)
			{
			case "Flow Control": Put("Flow", rest);
			case "Variables": Put("Variables", rest);
			case "Functions": Put("Functions", rest);
			case "Lifetime": Put("Types", rest.IsEmpty ? "Lifetime" : rest);
			case "Structs", "Enums": Put("Types", rest);
			case "Utilities":
				if (rest == "Functions as values")
					Put("Functions", rest);
				else
					Put("Types", rest);
			default: outPath.Append(cat);
			}
		}

		/// A catalogue row that is a member (call, Get, Set) of the context pin's type or of one of its
		/// base types or interfaces: the pin can be its Receiver.
		bool IsReceiverRow(NodeItem r)
		{
			if (r.Kind != .Catalog || r.CatalogId < 0 || IsWild(mContextType))
				return false;
			let spec = Catalog.Spec(r.CatalogId);
			if (spec == null || spec.IsStatic || spec.OwnerType.IsEmpty || !spec.KindWord.IsEmpty || spec.Kind == .Event)
				return false;
			String pinCore = scope .();
			TypeRules.Normalize(mContextType, pinCore);
			return NodeCatalog.SameOwner(pinCore, spec.OwnerType) || (mApp.Language.Types != null && mApp.Language.Types.IsSubtype(pinCore, spec.OwnerType));
		}

		/// The position of a group path's top level in `sGroupOrder` (others after them). Opened from a
		/// vector pin: the vector's own rows first, then the operators and comparisons (they take vectors).
		int GroupRank(StringView path)
		{
			let top = TopLevel(path);
			if (!mContextVector.IsEmpty)
			{
				if (top == "Vector")
					return -6;
				if (top == "Math")
					return -5;
				if (top == "Comparison")
					return -4;
			}
			// Dragged from an object's output: the functions of its type (and of its base types and
			// interfaces) first, then its variables, then everything else that takes it.
			if (mContext == .DataOut && (top == "Functions" || top == "Variables") && mGroups.TryGetValueAlt(path, let rows))
			{
				for (let r in rows)
					if (IsReceiverRow(r))
						return (top == "Functions") ? -9 : -8;
			}
			if (path == cSuggestedGroup)
				return -3;
			if (path == cRecentGroup)
				return -2;
			if (path == cFavoritesGroup)
				return -1;
			for (int i < sGroupOrder.Count)
				if (sGroupOrder[i] == top)
					return i;
			return sGroupOrder.Count;
		}

		/// The local rows' relevance to the context pin is computed once per open.
		bool mRelevanceValid;

		/// Recomputes what is shown. Runs when the search text, the context checkbox or the
		/// catalog changes, not every frame.
		void Refilter(StringView search)
		{
			ClearGroups();
			bool filterByContext = mContext != .None && ContextSensitive;
			bool catalogContext = filterByContext;
			if (catalogContext && !mContextIdsValid)
				ComputeContextIds();
			if (!mRelevanceValid)
			{
				mRelevanceValid = true;
				for (let item in Items)
					item.Relevance = ContextRelevance(item);
			}

			// Scored candidates: local items and catalog hits together.
			List<NodeItem> scored = scope .();
			void ConsiderLocal(NodeItem item)
			{
				// "Construct T + F" rows are one per function of every class: listed for a search only.
				if (search.IsEmpty && item.Kind == .ConstructCall)
					return;
				if (mContext == .None)
					item.Relevance = 1;
				if (filterByContext && item.Relevance == 0)
					return;
				let s = LocalScore(item, search);
				if (s <= 0)
					return;
				item.Score = s + item.Relevance * 15;
				scored.Add(item);
			}
			for (let item in Items)
				ConsiderLocal(item);
			// Recently used, then favorites, at the top when nothing is typed.
			if (search.IsEmpty)
			{
				AddSuggestedLambda();
				AddPrefGroup(cRecentGroup, Prefs.Recents, scored, filterByContext);
				AddPrefGroup(cFavoritesGroup, Prefs.Favorites, scored, filterByContext);
			}

			List<SearchHit> hits = scope .();
			let ctxKind = (mContext == .DataOut) ? PinContext.TakesValue : ((mContext == .DataIn) ? PinContext.GivesValue : PinContext.None);
			if (!search.IsEmpty)
			{
				HashSet<int32> allowed = null;
				if (catalogContext)
				{
					allowed = scope:: .();
					for (let id in mContextIds)
						allowed.Add(id);
				}
				Catalog.Search(search, hits, cMaxCatalogHits,
					scope (id) => (allowed == null || allowed.Contains(id)) && !IsOwnMember(id),
					scope (id) => (ctxKind != .None && !IsWild(mContextType)) ? Catalog.ContextRelevance(id, ctxKind, mContextType) * 8.0f : 0);
			}
			else if (catalogContext)
			{
				// Context with no search: every matching entry, best relevance first.
				for (let id in mContextIds)
				{
					if (IsOwnMember(id))
						continue;
					float rel = (ctxKind != .None) ? Catalog.ContextRelevance(id, ctxKind, mContextType) : 1;
					hits.Add(.() { Id = id, Score = rel * 10 });
					if (hits.Count >= 2000)
						break;
				}
				hits.Sort(scope (a, b) => b.Score <=> a.Score);
			}
			for (let h in hits)
			{
				let item = CatalogItem(h.Id);
				item.Relevance = (int32)Math.Max(1, (ctxKind != .None) ? Catalog.ContextRelevance(h.Id, ctxKind, mContextType) : 1);
				item.Score = h.Score + (search.IsEmpty ? 0 : 0);
				scored.Add(item);
			}
			// A "Construct T + F" row sits right under the Call of F (unless the search says "construct")
			// and the Construct / Local of T (unless the search names F): Enter places the single node the
			// search names, and the combined row when the search names both.
			String searchLower = scope String(search)..ToLower();
			for (let combo in scored)
			{
				if (combo.Kind != .ConstructCall)
					continue;
				let typeName = Node.ShortTypeName(combo.A, .. scope String());
				bool saysConstruct = searchLower.Contains("construct");
				bool saysFunction = searchLower.Contains(scope String(combo.B)..ToLower());
				for (let other in scored)
				{
					if (other.Kind != .Catalog || other.Score > combo.Score)
						continue;
					bool isCall = !saysConstruct && other.A == "call" && NodeCatalog.SameOwner(combo.A, other.OnType) && other.Label.StartsWith(combo.B) &&
						(other.Label.Length == combo.B.Length || other.Label[combo.B.Length] == ' ');
					bool isAlloc = false;
					for (let word in StringView[?]("Construct ", "Local "))
						if (!saysFunction)
					{
						let lbl = StringView(other.Label);
						if (lbl.StartsWith(word) && lbl.Substring(word.Length).StartsWith(typeName))
						{
							let rest = lbl.Substring(word.Length + typeName.Length);
							isAlloc |= rest.IsEmpty || rest.StartsWith(" (");
						}
					}
					if (isCall || isAlloc)
						combo.Score = other.Score - 0.01f;
				}
			}
			ClearAndDeleteItems!(mMoreRows);
			if (!search.IsEmpty)
				CollapseOverloads(scored, search);

			// Group: categories ordered by their best item (or in the menu's group order when browsing).
			// A recently used row ranks above an equally good match.
			if (!search.IsEmpty)
			{
				String key = scope .();
				for (let item in scored)
				{
					key.Clear();
					item.GetKey(key);
					for (let r in Prefs.Recents)
						if (r == key)
						{
							item.Score += Math.Max(4, 24 - @r.Index * 2);
							break;
						}
				}
				scored.Sort(scope (a, b) => b.Score <=> a.Score);
			}
			for (let item in scored)
				AddToGroup(item);
			if (search.IsEmpty)
			{
				// Recently Used and Favorites first, then the groups in sGroupOrder; a group's
				// subgroups stay in first-appearance order.
				List<String> sorted = scope .();
				sorted.AddRange(mGroupOrder);
				List<String> before = scope .();
				before.AddRange(mGroupOrder);
				sorted.Sort(scope (a, b) =>
					{
						int c = GroupRank(a) <=> GroupRank(b);
						if (c == 0)
							c = before.IndexOf(a) <=> before.IndexOf(b);
						return c;
					});
				mGroupOrder.Clear();
				mGroupOrder.AddRange(sorted);
			}
		}

		/// The "N more overloads" rows of the last Refilter (owned) and the overload keys whose rows are
		/// all listed (a More row was picked; until the menu opens again).
		List<NodeItem> mMoreRows = new .() ~ DeleteContainerAndItems!(_);
		HashSet<String> mExpandedOverloads = new .() ~ DeleteContainerAndItems!(_);

		/// The input types of a catalogue entry, lower case and short (`int`, `stringview`, `list<int>`).
		static void InputTypeWords(NodeSpec s, List<String> outTypes)
		{
			for (let p in s.Pins)
			{
				if (p.IsOutput || p.Type.IsEmpty)
					continue;
				String t = new .();
				StringView full = p.Type;
				let lt = full.IndexOf('<');
				let head = (lt > 0) ? full.Substring(0, lt) : full;
				let dot = head.LastIndexOf('.');
				t.Append((dot >= 0) ? full.Substring(dot + 1) : full);
				t.ToLower();
				outTypes.Add(t);
			}
		}

		/// A search that names parameter types ("writeline int"): of each function whose overloads it
		/// lists, the overload taking exactly those types comes first and the others fold into one
		/// "N more overloads" row under it (picking that row lists them).
		void CollapseOverloads(List<NodeItem> scored, StringView search)
		{
			List<String> words = scope .();
			defer { ClearAndDeleteItems!(words); }
			for (let w in search.Split(' ', .RemoveEmptyEntries))
				words.Add(new String(w)..ToLower());
			if (words.Count < 2)
				return;
			// The listed rows by overload key (catalogue calls only).
			Dictionary<String, List<NodeItem>> families = scope .();
			defer { for (let kv in families) { delete kv.key; delete kv.value; } }
			List<String> order = scope .();
			String key = scope .();
			for (let item in scored)
			{
				if (item.CatalogId < 0 || item.Kind != .Catalog)
					continue;
				key.Clear();
				if (!OverloadKey(Catalog.Specs[item.CatalogId], key) || !key.StartsWith("call|"))
					continue;
				if (!families.TryGetValue(key, var list))
				{
					list = new List<NodeItem>();
					let k = new String(key);
					families[k] = list;
					order.Add(k);
				}
				list.Add(item);
			}
			for (let k in order)
			{
				let list = families[k];
				if (list.Count < 2 || mExpandedOverloads.Contains(k))
					continue;
				// The query words that are input types of one of the overloads.
				HashSet<String> famTypes = scope .();
				List<List<String>> types = scope .();
				defer { for (let t in types) DeleteContainerAndItems!(t); }
				for (let item in list)
				{
					let t = new List<String>();
					InputTypeWords(Catalog.Specs[item.CatalogId], t);
					types.Add(t);
					for (let s in t)
						famTypes.Add(s);
				}
				List<StringView> typed = scope .();
				for (let w in words)
					if (famTypes.ContainsAlt(w))
						typed.Add(w);
				if (typed.IsEmpty)
					continue;
				NodeItem exact = null;
				for (int i < list.Count)
				{
					let t = types[i];
					if (t.Count != typed.Count)
						continue;
					List<StringView> left = scope .();
					left.AddRange(typed);
					bool all = true;
					for (let s in t)
					{
						int at = -1;
						for (int j < left.Count)
							if (left[j] == s)
								at = j;
						if (at < 0)
						{
							all = false;
							break;
						}
						left.RemoveAt(at);
					}
					if (all && (exact == null || list[i].Score > exact.Score))
						exact = list[i];
				}
				if (exact == null)
					continue;
				float top = exact.Score;
				for (let item in list)
					top = Math.Max(top, item.Score);
				exact.Score = top + 50;
				int folded = 0;
				for (let item in list)
					if (item != exact)
					{
						scored.Remove(item);
						folded++;
					}
				let spec = Catalog.Specs[exact.CatalogId];
				NodeItem more = new .();
				more.Kind = .MoreOverloads;
				more.Category.Set(exact.Category);
				more.A.Set(k);
				more.Label.AppendF("{} more overload{} of {}", folded, (folded == 1) ? "" : "s", spec.MemberName);
				more.Tooltip.AppendF("Lists the other {} of {} (the search names the {} one)", (folded == 1) ? "overload" : "overloads", spec.MemberName, exact.Label);
				more.OnType.Set(exact.OnType);
				more.Relevance = exact.Relevance;
				more.Score = exact.Score - 0.01f;
				mMoreRows.Add(more);
				scored.Add(more);
			}
		}

		/// A "more overloads" row was picked: its overloads are listed (the menu stays open).
		public void ExpandOverloads(NodeItem more)
		{
			if (!mExpandedOverloads.ContainsAlt(more.A))
				mExpandedOverloads.Add(new String(more.A));
			mDirty = true;
		}

		const String cFavoritesGroup = "Favorites";
		const String cRecentGroup = "Recently Used";
		/// Dragged from a delegate input: the Lambda of that type, above everything else.
		const String cSuggestedGroup = "Suggested";

		/// Favorite / recent keys turned back into items (local ones, or catalog ones by label).
		void AddPrefGroup(StringView groupName, List<String> keys, List<NodeItem> scored, bool filterByContext)
		{
			if (keys.IsEmpty)
				return;
			for (let key in keys)
			{
				let found = FindItemByKey(key);
				if (found == null)
					continue;
				if (filterByContext)
				{
					int32 rel = (found.CatalogId >= 0) ? 2 : found.Relevance;
					if (found.CatalogId >= 0 && !mContextIds.IsEmpty)
						rel = mContextIds.Contains(found.CatalogId) ? 2 : 0;
					if (rel == 0)
						continue;
				}
				// A copy in the pref group (the original stays in its own category).
				NodeItem copy = new .();
				copy.CopyFrom(found);
				copy.OrigCategory.Set(found.Category);
				copy.Category.Set(groupName);
				mPrefCopies.Add(copy);
				AddToGroup(copy);
			}
		}
		List<NodeItem> mPrefCopies = new .() ~ DeleteContainerAndItems!(_);

		/// Dragged from a delegate or function pointer input: the signature it wants ("" = not one).
		/// The Lambda row then comes first (the Suggested group, Enter's choice) and places a Lambda
		/// of that type with its inputs and Sheet made to match (EditorApp.SetupLambdaFromPin).
		String mContextLambdaSig = new .() ~ delete _;
		public StringView ContextLambdaSignature => mContextLambdaSig;

		void AddSuggestedLambda()
		{
			if (mContextLambdaSig.IsEmpty)
				return;
			for (let item in Items)
			{
				if (item.Kind != .Lambda)
					continue;
				NodeItem copy = new .();
				copy.CopyFrom(item);
				copy.OrigCategory.Set(item.Category);
				copy.Category.Set(cSuggestedGroup);
				copy.Relevance = 3;
				copy.Tooltip.Set(scope $"A Lambda of {mContextType}: {mContextLambdaSig}. Its inputs, its Sheet's Entry and Return and the wire are made for this pin.");
				mPrefCopies.Add(copy);
				AddToGroup(copy);
				return;
			}
		}

		// ------------------------------------------------------------------ draw

		/// Draws the popup. Returns the chosen item (a new copy the caller deletes) or null.
		public NodeItem Draw()
		{
			if (OpenRequested)
			{
				Gui.OpenPopup("##nodes");
				OpenRequested = false;
			}
			// Sized with the display scale, never taller than the window (the list scrolls).
			let vpSize = Gui.igGetMainViewport().Size;
			Gui.igSetNextWindowSize(.(Math.Min(440 * Look.Scale, vpSize.x - 16), Math.Min(500 * Look.Scale, vpSize.y - 48 * Look.Scale)), Cond.Always);
			if (SelfTestPlace)
				Gui.igSetNextWindowPos(SelfTestPopupPos, Cond.Always, .(0, 0));
			else if (SelfTestPos.x > 0)
				Gui.igSetNextWindowPos(SelfTestPos, Cond.Always, .(0, 0));
			if (!Gui.BeginPopup("##nodes"))
			{
				mShown = false;
				CloseRequested = false;
				SelfTestPlace = false;
				return null;
			}
			mShown = true;
			if (CloseRequested)
			{
				CloseRequested = false;
				mShown = false;
				Gui.igCloseCurrentPopup();
				Gui.EndPopup();
				return null;
			}

			NodeItem chosen = null;
			Gui.TextColored(Gui.Color(220, 220, 220), "All nodes for this Sheet");
			{
				// Always drawn, right-aligned from its measured width (box + label), so no scale or
				// window width can push it out of view. Disabled when the menu has no pin context.
				const String cLabel = "Context Sensitive";
				float boxW = Gui.igGetFrameHeight() + Gui.CalcTextSize(cLabel).x + 8 * Look.Scale;
				Gui.SameLine(Math.Max(Gui.igGetCursorPosX() + 8 * Look.Scale, Gui.igGetWindowSize().x - boxW - 16 * Look.Scale), -1);
				bool hasPin = mContext != .None;
				Gui.igBeginDisabled(!hasPin);
				if (Gui.Checkbox(cLabel, &ContextSensitive))
					mDirty = true;
				Gui.igEndDisabled();
				if (Gui.igIsItemHovered(1024)) // AllowWhenDisabled
					Gui.Tooltip(hasPin ? "Only show nodes that can connect to the pin you dragged from" : "Drag from a pin to filter by what can connect");
			}
			if (!mContextFrom.IsEmpty)
			{
				// The pin dragged from: a dot in its colour, the node and the pin; what is listed under it.
				let dl = Gui.igGetWindowDrawList();
				let cp = Gui.igGetCursorScreenPos();
				float fh = Gui.igGetFontSize();
				Gui.ImDrawList_AddCircleFilled(dl, .(cp.x + 5 * Look.Scale, cp.y + fh * 0.5f + 1), 4 * Look.Scale, mContextColor, 0);
				Gui.igSetCursorScreenPos(.(cp.x + 14 * Look.Scale, cp.y));
				Gui.TextColored(Look.Foreground, mContextFrom);
				if (ContextSensitive)
					Gui.TextColored(Theme.TextDim, mContextLabel);
			}
			if (!mContextLambdaSig.IsEmpty && mSearch.View.IsEmpty)
				Gui.TextColored(Theme.TextDim, scope $"Enter: a Lambda {mContextLambdaSig}");
			if (ContextIsFlowOutput && mSearch.View.IsEmpty)
				Gui.TextColored(Theme.TextDim, "Enter: a Reroute knot here");
			if (!mHotkeyMessage.IsEmpty)
				Gui.TextColored(mHotkeyMessageError ? Look.Error : Theme.TextDim, mHotkeyMessage);
			if (mFocusSearch)
			{
				Gui.igSetKeyboardFocusHere(0);
				mFocusSearch = false;
			}
			Gui.igSetNextItemWidth(-1);
			// A capture typed into the box: a new id makes the box read the text set from outside.
			Gui.PushID(mSelfTestSearchGen);
			bool enter = Gui.igInputTextWithHint("##search", "Search", mSearch.Ptr, (.)mSearch.Capacity, InputTextFlags.EnterReturnsTrue, null, null);
			Gui.PopID();
			// Keep typing going to the search box, like UE. Never while a mouse button is down:
			// clicking a row deactivates the search box, and grabbing focus back on the next frame
			// would steal the active id from the row being pressed, so a click held longer than
			// a frame or two never registered (only Enter could place a node).
			// While a hotkey is being captured the letter goes to the key-capture control, not the search box.
			if (!mCaptureFor.IsEmpty && Gui.igIsItemActive())
				igClearActiveID();
			if (!Gui.igIsItemActive() && !Gui.igIsAnyItemActive() && !Gui.igIsAnyMouseDown() && mCaptureFor.IsEmpty)
				mFocusSearch = true;
			var search = mSearch.View;
			search.Trim();
			bool searchChanged = search != mLastSearch;
			if (searchChanged)
			{
				// Debounce: while keys keep coming, the list waits until typing pauses for
				// cSearchDebounce (Enter, an emptied box and the first frame filter at once).
				bool first = mLastSearch == "\x01";
				mLastSearch.Set(search);
				mSearchPending = true;
				mSearchChangedAt = Desktop.Now;
				if (first)
					mSearchChangedAt = 0;
			}
			searchChanged = mSearchPending && (enter || search.IsEmpty || Desktop.Now - mSearchChangedAt >= cSearchDebounce);
			if (searchChanged)
				mSearchPending = false;
			// The index was rebuilt: drop the cached catalog items and filter again. (This used to
			// compare without syncing, and browsing with an empty search never touches a catalog
			// item, so the menu re-filtered, re-forced its category open state and re-scrolled to
			// the highlight on every frame: categories could not be clicked open and the list
			// fought the mouse wheel.)
			if (SyncCatalogCache())
			{
				mNavOrder.Clear();
				SetHighlight(null);
				mDirty = true;
			}
			if (searchChanged || mDirty)
			{
				// Refilter frees the free-form and preference rows last frame's list points at:
				// the arrow keys below must not walk that list.
				mNavOrder.Clear();
				ClearAndDeleteItems!(mPrefCopies);
				Refilter(search);
				mDirty = false;
				searchChanged = true;
			}
			bool browsing = search.IsEmpty && !(mContext != .None && ContextSensitive);

			// Best match: re-picked whenever the results change.
			if (searchChanged)
			{
				mForceOpen = (!search.IsEmpty || mVisibleCount <= 40) ? 1 : -1;
				SetHighlight(null);
				let best = PickBest(search);
				if (best != null)
					SetHighlight(best);
				mScrollToHighlight = true;
			}

			// Arrow keys move the highlight through what was drawn last frame.
			int navDelta = 0;
			if (Gui.igIsKeyPressed_Bool(Key.DownArrow, true))
				navDelta = 1;
			if (Gui.igIsKeyPressed_Bool(Key.UpArrow, true))
				navDelta = -1;
			if (Gui.igIsKeyPressed_Bool(Key.PageDown, true))
				navDelta = 10;
			if (Gui.igIsKeyPressed_Bool(Key.PageUp, true))
				navDelta = -10;
			if (navDelta != 0 && !mNavOrder.IsEmpty)
			{
				int cur = -1;
				for (let it in mNavOrder)
					if (IsHighlighted(it))
						cur = @it.Index;
				int next = (cur < 0) ? 0 : Math.Clamp(cur + navDelta, 0, mNavOrder.Count - 1);
				SetHighlight(mNavOrder[next]);
				mScrollToHighlight = true;
			}
			if (!mCaptureFor.IsEmpty)
				UpdateCapture();
			else if (Gui.IsKeyPressed(Key.Escape))
				Gui.igCloseCurrentPopup();

			if (Gui.igBeginChild_Str("##list", .(0, 0), 0, 0))
			{
				mNavOrder.Clear();
				mAuditSeen.Clear();
				if (mVisibleCount == 0 && !browsing)
					Gui.TextDisabled((mContext != .None && ContextSensitive) ? "No matching nodes for this pin.\nUntick Context Sensitive to see everything." : "No matching nodes.");
				if (DrawGroups())
					chosen = mClicked;
				// Browsing with nothing typed: the whole catalog as UE's "All Actions" tree.
				if (browsing && chosen == null)
				{
					let tree = Catalog.Tree;
					if (tree.Total > 0)
					{
						Gui.Separator();
						Gui.TextColored(Theme.TextDim, scope $"Library  ({tree.Total} nodes)");
						for (let child in tree.Children)
						{
							if (DrawCatalogNode(child, 0))
							{
								chosen = mClicked;
								break;
							}
						}
					}
				}
				mForceOpen = 0;
				Gui.igEndChild();
			}
			if (enter && chosen == null)
			{
				for (let it in mNavOrder)
					if (IsHighlighted(it))
						chosen = it;
				if (chosen == null && !mNavOrder.IsEmpty)
					chosen = mNavOrder[0];
			}

			if (chosen != null && chosen.Kind == .MoreOverloads)
			{
				// Not a node: the folded overloads are listed and the menu stays open.
				ExpandOverloads(chosen);
				chosen = null;
			}
			if (chosen != null)
			{
				// Copy out: free-form and catalog items belong to the menu.
				NodeItem copy = new .();
				copy.CopyFrom(chosen);
				if (!copy.OrigCategory.IsEmpty)
				{
					// A Favorites / Recently Used copy: back to its real category, so it is found again.
					copy.Category.Set(copy.OrigCategory);
					copy.OrigCategory.Clear();
				}
				mCaptureFor.Clear();
				if (copy.Category != "Custom")
					NoteUsed(copy);
				Gui.igCloseCurrentPopup();
				Gui.EndPopup();
				return copy;
			}
			Gui.EndPopup();
			return null;
		}

		NodeItem mClicked;

		/// Self-test hook (`TREADLE_SELFTEST=ids`): when on, every tree row and item row drawn in a frame has its
		/// ImGui ID recorded and a repeat counts in IdDuplicates (ImGui shows these as "conflicting ID").
		public bool AuditIds;
		/// With AuditIds: the Library tree is drawn fully open (to the given depth).
		public int AuditOpenDepth;
		/// Self-test captures: the Library tree node with this path (and its parents) is drawn open.
		public String OpenPath = new .() ~ delete _;
		public int IdDuplicates;
		public int IdsSeen;
		HashSet<uint32> mAuditSeen = new .() ~ delete _;

		void AuditNote()
		{
			if (!AuditIds)
				return;
			IdsSeen++;
			if (!mAuditSeen.Add(Gui.igGetItemID()))
				IdDuplicates++;
		}

		/// Self test: how many rows the menu would list for an empty search with Context Sensitive
		/// on or off (leaves the setting as asked).
		public int SelfTestVisibleCount(bool contextSensitive)
		{
			ContextSensitive = contextSensitive;
			Refilter("");
			return mVisibleCount;
		}

		public bool SelfTestHasContext => mContext != .None;

		/// The catalogue API: the rows the Node menu lists for `mg` when opened from the pin
		/// `contextPinId` (0 = the canvas) for `search`, context-filtered, without opening it
		/// (copies the caller deletes; the Favorites and Recently Used copies are left out).
		/// The row Enter takes: the best score (relevance with nothing typed). Dragged from a flow
		/// output with nothing typed it is the Reroute row: Enter draws the wire through a knot
		/// here, the quickest way to route a long flow wire.
		NodeItem PickBest(StringView search)
		{
			NodeItem best = null;
			float bestScore = float.MinValue;
			for (let c in mGroupOrder)
			{
				for (let item in mGroups[c])
				{
					if (search.IsEmpty && ((ContextIsFlowOutput && item.Kind == .Reroute) || (!mContextLambdaSig.IsEmpty && item.Kind == .Lambda)))
						return item;
					if (item.Kind == .MoreOverloads)
						continue;
					float sc = search.IsEmpty ? (item.Relevance * 10.0f) : item.Score;
					if (best == null || sc > bestScore)
					{
						best = item;
						bestScore = sc;
					}
				}
			}
			return best;
		}

		/// What Enter places when the menu opens from `contextPinId` and `search` is typed (a
		/// copy, or null): the self test's way to the default row.
		public NodeItem DefaultRowFor(Sheet mg, ImVec2 spawnPos, int32 contextPinId, StringView search)
		{
			Prepare(mg, spawnPos, contextPinId);
			ContextSensitive = true;
			Refilter(search);
			let best = PickBest(search);
			if (best == null)
				return null;
			NodeItem copy = new .();
			copy.CopyFrom(best);
			copy.OrigCategory.Clear();
			return copy;
		}

		public void ListFor(Sheet mg, int32 contextPinId, StringView search, List<NodeItem> outItems)
		{
			Prepare(mg, default, contextPinId);
			ContextSensitive = true;
			Refilter(search);
			for (let key in mGroupOrder)
			{
				if (key == cFavoritesGroup || key == cRecentGroup || key == cSuggestedGroup)
					continue;
				if (mGroups.TryGetValue(key, let list))
					for (let it in list)
					{
						NodeItem copy = new .();
						copy.CopyFrom(it);
						outItems.Add(copy);
					}
			}
		}

		/// Whether the node a row makes has a pin that takes a wire from `ctx` (the context
		/// filter's rule), made in the scratch graph of the last ListFor / open.
		public bool RowFits(NodeItem item, Pin ctx)
		{
			if (mProbe == null || ctx == null)
				return false;
			if (item.CatalogId >= 0)
			{
				let spec = Catalog.Spec(item.CatalogId);
				return ProbeFit(scope (pg) => NodeFactory.FromSpec(pg, spec, WantFlow(item, ctx)), ctx) > 0;
			}
			return ProbeFit(scope (pg) => CreateNode(mProbeSheet, pg, item, WantFlow(item, ctx), true), ctx) > 0;
		}

		/// Self test: the rows the menu lists for `search` (Context Sensitive as set), in the order
		/// shown, copied into `outItems` (the caller deletes them).
		public void SelfTestRows(StringView search, List<NodeItem> outItems)
		{
			Refilter(search);
			for (let key in mGroupOrder)
				if (mGroups.TryGetValue(key, let list))
					for (let it in list)
					{
						NodeItem copy = new .();
						copy.CopyFrom(it);
						outItems.Add(copy);
					}
		}

		int32 mSelfTestSearchGen;

#if TREADLE_SELFTEST
		/// Self-test: logs the paths of the Library tree down to `depth` (to pick a `menu-open:` path).
		public void SelfTestDumpTree(int depth)
		{
			void Walk(CategoryNode n, int d)
			{
				Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] tree {n.Path} ({n.Total})");
				if (d < depth)
					for (let c in n.Children)
						Walk(c, d + 1);
			}
			for (let c in Catalog.Tree.Children)
				Walk(c, 1);
		}
#endif

		/// Self-test hook (captures): the popup's top-left corner while it is open (else it opens at the mouse).
		public ImVec2 SelfTestPopupPos;
		public bool SelfTestPlace;

		/// Self-test hook: the item whose label starts with `label` is found by `search`.
		public bool SelfTestFinds(StringView label, StringView search)
		{
			for (let it in Items)
				if (it.Label.StartsWith(label))
					return LocalScore(it, search) > 0;
			return false;
		}

		/// Self-test hook: types into the search box.
		public void SelfTestSetSearch(StringView text)
		{
			mSearch.Set(text);
			mSelfTestSearchGen++;
		}

		// ------------------------------------------------------------------ favorites and node hotkeys

		/// The node key whose hotkey the key-capture control is waiting for ("" = none).
		String mCaptureFor = new .() ~ delete _;
		/// The last hotkey assignment's outcome, under the search box (a refusal names the owner).
		String mHotkeyMessage = new .() ~ delete _;
		bool mHotkeyMessageError;

		/// The key-capture control of a favorite's row: "Press a key" until a letter (assigned, or
		/// refused with the reason), Esc (the hotkey is cleared) or a click elsewhere.
		public void StartCapture(StringView key)
		{
			mCaptureFor.Set(key);
			mFocusSearch = false;
			mHotkeyMessage.Set("Press a letter for the hotkey of ");
			mHotkeyMessage.Append(NodeHotkeys.LabelOf(key));
			mHotkeyMessage.Append(". Esc clears it.");
			mHotkeyMessageError = false;
		}

		public bool IsCapturing => !mCaptureFor.IsEmpty;
		public StringView HotkeyMessage => mHotkeyMessage;

		/// The capture's keys, before the rows are drawn.
		void UpdateCapture()
		{
			if (Gui.IsKeyPressed(Key.Escape, false))
				CaptureEscape();
			else if (Gui.igIsMouseClicked_Bool(0, false) || Gui.igIsMouseClicked_Bool(1, false))
			{
				// A click elsewhere ends the capture (a click on the control starts it again).
				mCaptureFor.Clear();
				mHotkeyMessage.Clear();
			}
			else if (!Gui.IsCtrlDown && !Gui.IsAltDown)
			{
				for (int i < 26)
				{
					if (Gui.IsKeyPressed(cKeyA + (int32)i, false))
					{
						CaptureKey((char8)('A' + i));
						break;
					}
				}
			}
		}

		/// Esc in the key-capture control: the node's hotkey is cleared.
		public void CaptureEscape()
		{
			let label = scope String(NodeHotkeys.LabelOf(mCaptureFor));
			mHotkeyMessage.Clear();
			mHotkeyMessage.AppendF(Prefs.ClearHotkey(mCaptureFor) ? "Hotkey of {} cleared." : "{} has no hotkey.", label);
			mHotkeyMessageError = false;
			mCaptureFor.Clear();
			mFocusSearch = true;
			mDirty = true;
		}

		/// A letter typed into the key-capture control (also the session self test's path). A refusal
		/// keeps the control waiting and names the reason.
		public bool CaptureKey(char8 letter)
		{
			let key = scope String(mCaptureFor);
			mHotkeyMessage.Clear();
			let ok = Prefs.AssignHotkey(key, letter, mHotkeyMessage);
			mHotkeyMessageError = !ok;
			if (ok)
			{
				mCaptureFor.Clear();
				mFocusSearch = true;
				mDirty = true;
			}
			return ok;
		}

		[CLink] static extern void igClearActiveID();

		/// ImGuiKey_A; the letters follow in order.
		public const int32 cKeyA = 546;

		/// One selectable row: the type dot, the label, the hotkey badge (favorites and nodes with a
		/// key; on a favorite it is the key-capture control) and the favorite star. Returns true when
		/// the row was clicked.
		bool DrawItem(NodeItem item)
		{
			mNavOrder.Add(item);
			Gui.PushID((int32)mNavOrder.Count);
			bool highlighted = IsHighlighted(item);
			// Type-coloured dot like the variable entries.
			uint32 dot = ItemColor(item);
			let dl = Gui.igGetWindowDrawList();
			let cp = Gui.igGetCursorScreenPos();
			float fh = Gui.igGetFontSize();
			Gui.ImDrawList_AddCircleFilled(dl, .(cp.x + 5, cp.y + fh * 0.5f + 1), 3.5f, dot, 0);
			Gui.igSetCursorScreenPos(.(cp.x + 14, cp.y));
			String key = scope .();
			item.GetKey(key);
			bool custom = item.Category == "Custom" || item.Kind == .MoreOverloads; // no star, no hotkey
			bool fav = !custom && Prefs.IsFavorite(key);
			char8 hotkey = custom ? '\0' : Prefs.Hotkeys.KeyOf(key);
			bool capturing = !custom && mCaptureFor == key;
			Gui.igSetNextItemAllowOverlap();
			// A "more overloads" row reads as a list row, not a node.
			bool dim = item.Kind == .MoreOverloads;
			if (dim)
				Gui.igPushStyleColor_U32(Col.Text, Look.ForegroundDim);
			bool clicked = Gui.Selectable(item.Label, highlighted);
			if (dim)
				Gui.igPopStyleColor(1);
			AuditNote();
			let rMin = Gui.igGetItemRectMin();
			let rMax = Gui.igGetItemRectMax();
			bool rowHovered = Gui.igIsItemHovered(0);
			// A variable row can be dragged out onto a pin (or the Sheet): the menu closes and the
			// variable follows the cursor like an Outline row (DragGhost.bf).
			if (item.Kind == .GetVar && item.A == SelfTestRowFor)
				SelfTestRowAt = .(rMin.x + 40 * Look.Scale, (rMin.y + rMax.y) * 0.5f);
			if ((item.Kind == .GetVar || item.Kind == .SetVar) && Gui.igBeginDragDropSource(DragNative.SourceNoPreviewTooltip))
			{
				mApp.BeginMenuDrag(item.A, item.B, item.Kind == .SetVar);
				int32 idx = EditorApp.cMenuDragIndex;
				Gui.igSetDragDropPayload("TREADLE_MEMBER", &idx, sizeof(int32), 0);
				Gui.igEndDragDropSource();
				CloseRequested = true;
				rowHovered = false;
			}
			if (highlighted && mScrollToHighlight)
			{
				Gui.igSetScrollHereY(0.5f);
				mScrollToHighlight = false;
			}
			if (rowHovered)
			{
				String tip = scope .();
				tip.Append(item.Tooltip.IsEmpty ? item.Label : item.Tooltip);
				if (item.Relevance >= 2 && mContext != .None)
					tip.Append(item.Relevance >= 3 ? "\n(exact type match)" : "\n(converts implicitly)");
				if (hotkey != '\0')
					tip.AppendF("\nNode hotkey {0}: hold {0} and click the Sheet, or press {0} while dragging a wire", hotkey);
				Gui.Tooltip(tip);
			}
			if (Gui.igBeginPopupContextItem("##fav", 1))
			{
				if (!custom)
				{
					if (Gui.MenuItem(fav ? "Remove from Favorites" : "Add to Favorites"))
					{
						Prefs.ToggleFavorite(key);
						mDirty = true;
					}
					if (Gui.MenuItem((hotkey != '\0') ? scope $"Change Hotkey ({hotkey})..." : "Set Hotkey..."))
						StartCapture(key);
					if (hotkey != '\0' && Gui.MenuItem("Clear Hotkey"))
					{
						Prefs.ClearHotkey(key);
						mDirty = true;
					}
				}
				Gui.EndPopup();
			}
			if (!custom)
			{
				float h = rMax.y - rMin.y;
				float starW = fh * 1.4f;
				bool showKey = fav || hotkey != '\0' || capturing;
				float keyW = capturing ? Gui.CalcTextSize("Press a key").x + 12 * Look.Scale : fh * 1.5f;
				float x = rMax.x - starW - (showKey ? keyW + 4 : 0);
				if (showKey)
				{
					Gui.SameLine();
					Gui.igSetCursorScreenPos(.(x, rMin.y));
					if (Gui.igInvisibleButton("##hotkey", .(keyW, h), 0))
					{
						if (capturing)
							mCaptureFor.Clear();
						else
							StartCapture(key);
						capturing = !mCaptureFor.IsEmpty;
					}
					bool keyHovered = Gui.igIsItemHovered(0);
					let b0 = ImVec2(x, rMin.y + 1);
					let b1 = ImVec2(x + keyW, rMax.y - 1);
					if (capturing)
					{
						Gui.ImDrawList_AddRectFilled(dl, b0, b1, Look.Primary, 3, 0);
						StringView t = "Press a key";
						let ts = Gui.CalcTextSize(t);
						Gui.ImDrawList_AddText_Vec2(dl, .(x + (keyW - ts.x) * 0.5f, rMin.y + (h - ts.y) * 0.5f), Gui.Color(255, 255, 255), t.Ptr, t.Ptr + t.Length);
					}
					else
					{
						bool on = hotkey != '\0';
						Gui.ImDrawList_AddRectFilled(dl, b0, b1, on ? Look.Dropdown : Theme.WithAlpha(Look.Dropdown, keyHovered ? 255 : 90), 3, 0);
						Gui.ImDrawList_AddRect(dl, b0, b1, keyHovered ? Look.Hover2 : Look.DropdownOutline, 3, 1, 0);
						String t = scope .();
						if (on)
							t.Append(hotkey);
						else if (keyHovered || rowHovered)
							t.Append("+");
						if (!t.IsEmpty)
						{
							let ts = Gui.CalcTextSize(t);
							Gui.ImDrawList_AddText_Vec2(dl, .(x + (keyW - ts.x) * 0.5f, rMin.y + (h - ts.y) * 0.5f), on ? Look.ForegroundHover : Look.ForegroundDim, t.Ptr, t.Ptr + t.Length);
						}
					}
					if (keyHovered)
					{
						if (capturing)
							Gui.Tooltip("Press a letter for this node's hotkey. Esc clears it.");
						else if (hotkey != '\0')
							Gui.Tooltip(scope $"Node hotkey {hotkey}: hold {hotkey} and click the Sheet, or press {hotkey} while dragging a wire.\nClick to change it.");
						else
							Gui.Tooltip("Give this favorite a node hotkey");
					}
					x += keyW + 4;
				}
				Gui.SameLine();
				Gui.igSetCursorScreenPos(.(x, rMin.y));
				if (Gui.igInvisibleButton("##star", .(starW, h), 0))
				{
					fav = Prefs.ToggleFavorite(key);
					if (!fav && capturing)
						mCaptureFor.Clear();
					mDirty = true;
				}
				bool starHovered = Gui.igIsItemHovered(0);
				if (fav || starHovered || rowHovered)
				{
					StringView star = Icon.Loaded ? Icon.Star : "*";
					let ts = Gui.CalcTextSize(star);
					uint32 col = fav ? Look.AccentYellow : (starHovered ? Look.ForegroundHover : Look.ForegroundDim);
					Gui.ImDrawList_AddText_Vec2(dl, .(x + (starW - ts.x) * 0.5f, rMin.y + (h - ts.y) * 0.5f), col, star.Ptr, star.Ptr + star.Length);
				}
				if (starHovered)
					Gui.Tooltip(fav ? "Remove from Favorites" : "Add to Favorites");
			}
			Gui.PopID();
			if (clicked)
				mClicked = item;
			return clicked;
		}

		/// The filtered result as a category tree ("A | B" is the subcategory B of A). Rows that share
		/// a path are one row, whichever source or order they arrive in.
		bool DrawGroups()
		{
			let root = MergedCategory.Build(mGroupOrder);
			defer delete root;
			// The first group after Recently Used and Favorites starts open too.
			StringView firstTop = default;
			for (let g in mGroupOrder)
				if (g != cRecentGroup && g != cFavoritesGroup && g != cSuggestedGroup)
				{
					firstTop = TopLevel(g);
					break;
				}
			bool clicked = false;
			for (let child in root.Children)
			{
				if (DrawGroupNode(child, firstTop))
				{
					clicked = true;
					break;
				}
			}
			return clicked;
		}

		bool DrawGroupNode(MergedCategory node, StringView firstTop)
		{
			// Many results: only the first (most relevant) category starts open.
			if (mForceOpen != 0)
			{
				bool pref = node.Path == cFavoritesGroup || node.Path == cRecentGroup || node.Path == cSuggestedGroup;
				Gui.igSetNextItemOpen(mForceOpen > 0 || pref || (TopOf(node.Path) == firstTop), Cond.Always);
			}
			else if (node.Path == node.Name)
				Gui.igSetNextItemOpen(true, Cond.Once);
			Gui.igPushStyleColor_U32(Col.Text, Gui.Color(235, 235, 235));
			bool open = Gui.TreeNode(scope $"{node.Name}##grp|{node.Path}", TreeNodeFlags.SpanAvailWidth);
			Gui.igPopStyleColor(1);
			AuditNote();
			if (!open)
				return false;
			bool clicked = false;
			for (let cat in node.Cats)
			{
				for (let item in mGroups[cat])
				{
					if (DrawItem(item))
					{
						clicked = true;
						break;
					}
				}
				if (clicked)
					break;
			}
			if (!clicked)
			{
				for (let child in node.Children)
				{
					if (DrawGroupNode(child, firstTop))
					{
						clicked = true;
						break;
					}
				}
			}
			Gui.TreePop();
			return clicked;
		}

		static StringView TopOf(StringView path)
		{
			int bar = path.IndexOf('|');
			return (bar >= 0) ? path.Substring(0, bar) : path;
		}

		/// A catalog category in browse mode: children and items are only visited when open.
		bool DrawCatalogNode(CategoryNode node, int depth)
		{
			if (node.Total == 0)
				return false;
			if (AuditIds && depth < AuditOpenDepth)
				Gui.igSetNextItemOpen(true, Cond.Always);
			else if (!OpenPath.IsEmpty && (OpenPath == node.Path || (OpenPath.Length > node.Path.Length && OpenPath.StartsWith(node.Path) && OpenPath[node.Path.Length] == '|')))
				Gui.igSetNextItemOpen(true, Cond.Always);
			else if (mForceOpen != 0)
				Gui.igSetNextItemOpen(false, Cond.Always);
			Gui.igPushStyleColor_U32(Col.Text, Gui.Color(235, 235, 235));
			bool open = Gui.TreeNode(scope $"{node.Name}##{node.Path}", TreeNodeFlags.SpanAvailWidth);
			Gui.igPopStyleColor(1);
			AuditNote();
			if (!OpenPath.IsEmpty && OpenPath == node.Path)
				Gui.igSetScrollHereY(0.1f); // self-test captures: bring the opened node into view
			if (!open)
				return false;
			bool clicked = false;
			for (let child in node.Children)
			{
				if (DrawCatalogNode(child, depth + 1))
				{
					clicked = true;
					break;
				}
			}
			if (!clicked)
			{
				const int cMaxShown = 400;
				int shown = 0;
				for (let id in node.Entries)
				{
					if (IsOwnMember(id))
						continue;
					if (shown++ >= cMaxShown)
					{
						Gui.TextDisabled(scope $"... {node.Entries.Count - cMaxShown} more: type to search");
						break;
					}
					let item = CatalogItem(id);
					item.Relevance = 1;
					if (DrawItem(item))
					{
						clicked = true;
						break;
					}
				}
			}
			Gui.TreePop();
			return clicked;
		}

		static StringView TopLevel(StringView cat)
		{
			int bar = cat.IndexOf('|');
			var s = (bar >= 0) ? cat.Substring(0, bar) : cat;
			s.Trim();
			return s;
		}

		void SetHighlight(NodeItem item)
		{
			// Free-form items are rebuilt with the search text: remember those by label.
			mHighlightCustom = item != null && item.Category == "Custom";
			mHighlight = mHighlightCustom ? null : item;
			mHighlightLabel.Set((item != null) ? item.Label : "");
		}

		/// Free-form items are matched by label.
		bool IsHighlighted(NodeItem item) => (mHighlight != null && item == mHighlight) ||
			(mHighlightCustom && item.Category == "Custom" && item.Label == mHighlightLabel);

		uint32 ItemColor(NodeItem item)
		{
			switch (item.Kind)
			{
			case .MoreOverloads: return Theme.WithAlpha(Look.ForegroundDim, 120);
			case .GetVar, .SetVar: return Theme.TypeColor(item.B);
			case .Catalog:
				if (item.A == "get" || item.A == "set")
					return Theme.TypeColor(item.B);
				return item.Pure ? Theme.HeaderPure : Theme.HeaderCall;
			case .CallOwn: return item.Pure ? Theme.HeaderPure : Theme.HeaderCall;
			case .Branch, .While, .DoWhile, .For, .ForEach, .Break, .Continue, .Return, .Switch, .Flow, .LoopBreak,
				 .Defer, .ResultMatch, .Scope, .Try: return Theme.FlowAccent;
			case .Construct: return (item.B == "local") ? Theme.HeaderLocal : Theme.HeaderConstruct;
			case .Delete, .DeferDelete: return Theme.HeaderCall;
			case .Fatal: return Theme.ErrorHeader;
			case .Literal: return Theme.TypeColor(item.B);
			case .This, .Base: return Theme.ObjectPin;
			case .Comment, .Reroute: return Theme.TextDim;
			default: return Theme.HeaderPure;
			}
		}

		// ------------------------------------------------------------------ auto-wiring

		/// Connects a node just made from the menu to the pin the menu was dragged from, on the
		/// pin of the node that takes the wire best (PinMatch: the same rule as the context filter).
		/// A flow node keeps the flow going: dragged from a flow output it goes in between that
		/// output and what followed it; dragged from a value of a flow node it runs right after it.
		public static void WireToContext(Treadle.Graph.Graph g, Node n, Pin ctx, NodeItem item)
		{
			if (ctx == null || n == null)
				return;
			let best = PinMatch.Best(g.Language, g, n, ctx, ?);
			if (best == null)
				return;
			if (ctx.Kind == .Flow)
			{
				if (!ctx.IsInput)
				{
					let oldNext = g.ExecTarget(ctx);
					g.Connect(ctx, best);
					if (oldNext != null && n.Then != null && oldNext != n)
						g.Connect(n.Then, oldNext.ExecIn);
				}
				else
				{
					// Dragged from a flow input: the new node runs before it.
					let prevLink = g.FindLinkTo(ctx);
					let prev = prevLink?.From;
					g.Connect(best, ctx);
					if (prev != null && n.ExecIn != null && prev.Owner != n)
						g.Connect(prev, n.ExecIn);
				}
				return;
			}
			if (ctx.IsInput)
			{
				g.Connect(best, ctx);
				return;
			}
			g.Connect(ctx, best);
			// A flow node made from a value of another flow node runs right after it (or at the
			// start of its loop body for a loop's element).
			let src = ctx.Owner;
			if (n.ExecIn != null && !g.IsLinked(n.ExecIn) && src.IsExecNode)
			{
				Pin after = src.FindOutput("body");
				if (after == null || (ctx.Name != "element" && ctx.Name != "index" && ctx.Name != "counter"))
					after = src.Then;
				if (after != null)
				{
					let oldNext = g.ExecTarget(after);
					g.Connect(after, n.ExecIn);
					if (oldNext != null && n.Then != null && oldNext != n)
						g.Connect(n.Then, oldNext.ExecIn);
				}
			}
		}
	}
}
