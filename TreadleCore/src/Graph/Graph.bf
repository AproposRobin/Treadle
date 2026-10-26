using System;
using System.Collections;
using Treadle.Catalog;
using Treadle.Language;
using Treadle.Model;

namespace Treadle.Graph
{
	/// Flow pins carry the order nodes run in; value pins carry typed data (Language.md 5).
	enum PinKind : uint8
	{
		Flow,
		Value
	}

	/// How a call argument passes its value (Language.md 4, Function).
	enum ArgMode : uint8
	{
		/// An ordinary value argument (an input pin).
		Value,
		/// `ref`: an input pin whose source must be a variable.
		Ref,
		/// `out`: a further output (an output pin of the call).
		Out,
		/// `in`: passed by read-only reference.
		In
	}

	/// What a pin is for on its node (Editor-Model.md 1); drawing and the Node menu read it.
	enum PinRole : uint8
	{
		None,
		/// The member's object (`receiver`); unconnected reads `this`.
		Receiver,
		/// A call or constructor argument.
		Arg,
		/// The node's value output (`result`, `value`, `object`).
		Result,
		/// A flow output that owns a region (`body`, `then0`, a case).
		Body,
		/// A flow output that continues after the node (`then`, `done`, `true` / `false`).
		Next
	}

	class Pin
	{
		public int32 Id;
		public Node Owner;
		public bool IsInput;
		public PinKind Kind;
		/// The format's pin name, stable within the node (`in`, `then`, `condition`, `receiver`,
		/// a parameter name, `case:<label>`). Wires name pins by it (Graph-Format.md 3.2).
		public String Name = new .() ~ delete _;
		/// Display label ("Condition", a parameter name). Empty for the plain flow pins.
		public String Label = new .() ~ delete _;
		TypeRef mType ~ delete _;
		String mTypeName = new .() ~ delete _;
		/// For unlinked value inputs: the literal, as a format token (`0`, `"Hero"`, `.Case`,
		/// `default`, `null`). Written as `in <pin> <token>`.
		public String Default = new .() ~ delete _;
		/// Inputs such as Return's value may be left empty.
		public bool Optional;
		/// The declared generic type (`T`, `List<T>`) while Type holds what a connection unified
		/// it to; null when the pin was never unified.
		public TypeRef WildcardType ~ delete _;
		/// Call arguments: value, `ref`, `out` (an output pin) or `in`.
		public ArgMode Mode;
		public PinRole Role;

		/// The pin's type (null: not known).
		public TypeRef Type => mType;
		/// The type as the format spells it ("" when not known): what the type system seam, the
		/// pin colour and the tooltips read. Derived from Type; change it with SetType.
		public String TypeName => mTypeName;

		/// Takes ownership of `t` (null: no type).
		public void SetType(TypeRef t)
		{
			if (t == mType)
				return;
			delete mType;
			mType = (t != null && t.IsNone) ? null : t;
			if (t != null && t.IsNone)
				delete t;
			mTypeName.Clear();
			mType?.ToString(mTypeName);
		}

		/// Sets the type from its format spelling ("" clears it).
		public void SetTypeText(StringView text)
		{
			var text;
			text.Trim();
			if (text == mTypeName)
				return;
			SetType(text.IsEmpty ? null : TypeRef.Parse(text));
		}

		public bool IsOutArg => Mode == .Out && !IsInput;
		public bool IsRefArg => Mode == .Ref && IsInput;

		/// Argument index of an `arg<i>` pin (arguments added by hand before they have a name), or -1.
		public int ArgIndex
		{
			get
			{
				if (Kind != .Value || Name.Length < 4 || !Name.StartsWith("arg"))
					return -1;
				int v = 0;
				for (int i = 3; i < Name.Length; i++)
				{
					let c = Name[i];
					if (c < '0' || c > '9')
						return -1;
					v = v * 10 + (c - '0');
				}
				return v;
			}
		}
	}

	/// How a call node binds to its function.
	enum CallBinding : uint8
	{
		/// Not resolved (no type information): never an error by itself.
		Unresolved,
		/// A static function: no Receiver pin.
		Static,
		/// A member function: a Receiver pin; unconnected means `this`.
		Instance
	}

	/// The node kinds of Language.md 5 and Graph-Format.md 3.2. Knots, comment boxes and
	/// collapsed drawing are layout (Graph-Format.md 4), not nodes.
	enum NodeKind : uint8
	{
		// Function boundaries
		Entry,
		Return,
		ChainCtor,
		// Calls
		Call,
		Invoke,
		Intrinsic,
		// Variables
		Get,
		Set,
		This,
		Base,
		// Lifetime
		Construct,
		Local,
		Delete,
		Defer,
		DeferDelete,
		// Flow control
		Branch,
		Sequence,
		While,
		DoWhile,
		For,
		ForEach,
		Break,
		Continue,
		Switch,
		Scope,
		Gate,
		DoOnce,
		DoN,
		FlipFlop,
		MultiGate,
		GateOpen,
		GateClose,
		GateToggle,
		ResetDoOnce,
		ResetDoN,
		ResetMultiGate,
		ResultMatch,
		Try,
		Fatal,
		// Value nodes
		Operator,
		Select,
		Cast,
		Make,
		/// The struct / tuple Break (the format word is `Break` with a subject).
		BreakStruct,
		MakeCase,
		IsCase,
		Index,
		Literal,
		Bind,
		Lambda,
		Math,
		/// `value` -> `result`, `set lanes zyx`: lanes of a vector picked by letter (SIMD-and-Vectors.md 1.9).
		Swizzle,
		/// `a`, `b` -> `result`, `set mask 0 4 1 5`: lanes of two vectors picked by number.
		Shuffle,
		/// A kind this editor does not know (a newer file): kept verbatim, drawn read-only.
		Unknown
	}

	/// The format words of the node kinds and which kinds take a subject.
	static class NodeKinds
	{
		/// Filled once at start-up, not on first use: the build thread and the UI thread both read it.
		static List<String> sWords = MakeWords() ~ DeleteContainerAndItems!(_);

		static List<String> MakeWords()
		{
			let words = new List<String>();
			for (int i <= (int)NodeKind.Unknown)
				words.Add(((NodeKind)i).ToString(.. new String()));
			return words;
		}

		public static StringView Word(NodeKind k)
		{
			if (k == .BreakStruct)
				return "Break";
			if (k == .Unknown)
				return "";
			return sWords[(int)k];
		}

		/// The kind of a format word (`Break` with a subject is the struct Break). Unknown when
		/// the word names no kind.
		public static NodeKind Parse(StringView word, bool hasSubject)
		{
			if (word == "Break")
				return hasSubject ? .BreakStruct : .Break;
			for (let k in Enum.GetValues<NodeKind>())
				if (k != .Unknown && k != .BreakStruct && Word(k) == word)
					return k;
			return .Unknown;
		}

		/// Value nodes: no flow pins (Language.md 5.2). Call and Intrinsic depend on the callee.
		public static bool IsValueKind(NodeKind k)
		{
			switch (k)
			{
			case .Get, .This, .Base, .Operator, .Select, .Cast, .Make, .BreakStruct, .MakeCase, .IsCase, .Index, .Literal, .Bind, .Lambda, .Math, .ChainCtor,
				.Swizzle, .Shuffle:
				return true;
			default:
				return false;
			}
		}

		/// Kinds whose subject is a type (Construct, Local, Cast, Make / Break).
		public static bool HasTypeSubject(NodeKind k) => k == .Construct || k == .Local || k == .Cast || k == .Make || k == .BreakStruct;

		/// Kinds whose state lives in a hidden field (Language.md 5.1).
		public static bool IsStateful(NodeKind k) => k == .Gate || k == .DoOnce || k == .DoN || k == .FlipFlop || k == .MultiGate;
	}

	/// A node setting or kind-specific property line (`set ctor (String)`, `case Red`), kept in
	/// file order.
	class NodeSetting
	{
		/// The key (`ctor`; for a non-`set` line the line's own key, `case`, `capture`).
		public String Key = new .() ~ delete _;
		/// The tokens after the key, as written.
		public String Value = new .() ~ delete _;
		/// Written `set <key> ...` (false: `<key> ...`).
		public bool IsSet = true;

		public NodeSetting Clone()
		{
			NodeSetting s = new .();
			s.Key.Set(Key);
			s.Value.Set(Value);
			s.IsSet = IsSet;
			return s;
		}
	}

	class Node
	{
		/// Runtime handle (pins, links, selection). Not saved; `Key` is the record id.
		public int32 Id;
		public NodeKind Kind;
		/// The subject as the format writes it: a member reference (`this.mHealth`,
		/// `Game.Player.TakeDamage(int)`, `local:total`), an operator symbol, a type (kept equal
		/// to SubjectType), `base` / `this` for ChainCtor. Empty when the kind has none.
		public String Text = new .() ~ delete _;
		/// Kinds with a type subject (Construct, Local, Cast, Make, Break): the type. Set with
		/// SetSubjectType so Text follows.
		public TypeRef SubjectType ~ delete _;
		/// Unknown kinds: the kind word as written.
		public String KindWord ~ delete _;
		/// No flow pins (a value node). Calls take it from the callee.
		public bool IsPure;

		/// Call nodes: static, member (Receiver pin) or unresolved.
		public CallBinding Binding;
		/// Call nodes: the type that declares the function; null when unknown.
		public String OwnerType ~ delete _;
		/// Call nodes: several overloads fit the arguments equally well (a bind result, not saved).
		public bool Ambiguous;
		/// Ambiguous calls: the candidate overloads.
		public List<String> Overloads ~ DeleteContainerAndItems!(_);
		/// Call nodes: how many overloads the function has (-1 = not looked up) and the type
		/// system generation the count is from.
		public int32 OverloadCount = -1;
		public int32 OverloadGen = -1;

		/// `set <key> ...` lines and kind-specific property lines, in file order.
		public List<NodeSetting> Settings = new .() ~ DeleteContainerAndItems!(_);
		/// The node's comment (`comment "text"`); null = none.
		public String Comment ~ delete _;
		/// `disabled`: kept in the file, skipped by the compiler.
		public bool Disabled;
		/// `unsafe` (Scope): an unsafe block.
		public bool Unsafe;
		/// Unknown property lines and comments inside the record, kept in place.
		public RecordExtras Extras = new .() ~ delete _;

		public List<Pin> Inputs = new .() ~ DeleteContainerAndItems!(_);
		public List<Pin> Outputs = new .() ~ DeleteContainerAndItems!(_);

		public float X;
		public float Y;
		public bool HasPos;

		/// The record id (Graph-Format.md 2, "Id"): stable, random, unique in the file. Layout,
		/// diagnostics and wires refer to the node by it.
		public String Key = new .() ~ delete _;
		/// The line of the node record in the file it was read from (1-based; 0 for new nodes).
		public int32 Line;

		public bool IsExecNode => !IsPure;

		public Pin FindInput(StringView name)
		{
			for (let p in Inputs)
				if (p.Name == name)
					return p;
			return null;
		}

		public Pin FindOutput(StringView name)
		{
			for (let p in Outputs)
				if (p.Name == name)
					return p;
			return null;
		}

		/// The flow input.
		public Pin ExecIn => FindInput("in");
		public Pin Then => FindOutput("then");
		/// The node's value output: `result`, else `value`, else `object`.
		public Pin Result
		{
			get
			{
				var p = FindOutput("result");
				if (p == null)
					p = FindOutput("value");
				if (p == null)
					p = FindOutput("object");
				return p;
			}
		}

		public void SetSubjectType(TypeRef t)
		{
			delete SubjectType;
			SubjectType = t;
			Text.Clear();
			t?.ToString(Text);
		}

		public void SetSubjectTypeText(StringView text) => SetSubjectType(text.IsEmpty ? null : TypeRef.Parse(text));

		public NodeSetting FindSetting(StringView key)
		{
			for (let s in Settings)
				if (s.Key == key)
					return s;
			return null;
		}

		/// The value of `set <key>`, or "" when the node does not have it.
		public StringView GetSetting(StringView key)
		{
			let s = FindSetting(key);
			return (s != null) ? s.Value : "";
		}

		public bool HasSetting(StringView key) => FindSetting(key) != null;

		/// Sets (or adds, at the end) `set <key> <value>`.
		public void SetSetting(StringView key, StringView value)
		{
			var s = FindSetting(key);
			if (s == null)
			{
				s = new .();
				s.Key.Set(key);
				Settings.Add(s);
			}
			s.Value.Set(value);
		}

		public void RemoveSetting(StringView key)
		{
			for (let s in Settings)
				if (s.Key == key)
				{
					Settings.Remove(s);
					delete s;
					return;
				}
		}

		/// Number of argument pins named `arg<i>` (arguments added by hand).
		public int ArgCount
		{
			get
			{
				int count = 0;
				for (let p in Inputs)
					if (p.ArgIndex >= 0)
						count++;
				for (let p in Outputs)
					if (p.ArgIndex >= 0)
						count++;
				return count;
			}
		}

		/// The argument pins in order.
		public void GetArgPins(List<Pin> outPins)
		{
			for (let p in Inputs)
				if (p.Role == .Arg || p.ArgIndex >= 0)
					outPins.Add(p);
			for (let p in Outputs)
				if (p.IsOutArg)
					outPins.Add(p);
		}

		/// The argument pin `arg<i>` (input or out pin), or null.
		public Pin FindArg(int index)
		{
			String name = scope $"arg{index}";
			let p = FindInput(name);
			return (p != null) ? p : FindOutput(name);
		}

		public bool HasOutArgs
		{
			get
			{
				for (let p in Outputs)
					if (p.IsOutArg)
						return true;
				return false;
			}
		}

		/// The member name a Call / Get / Set / Bind subject names (`mHealth` for `this.mHealth`,
		/// `total` for `local:total`, `TakeDamage` for `Game.Player.TakeDamage(int)`).
		public void GetSubjectName(String outName)
		{
			let m = MemberRef.Parse(Text);
			outName.Append(m.Name);
			delete m;
		}

		/// A type as a title shows it: without namespaces (`Core.Pair<int,Game.Player>` ->
		/// `Pair<int,Player>`); the full name is in Properties and the tooltip.
		public static void ShortTypeName(StringView type, String outText)
		{
			int start = outText.Length;
			int identStart = outText.Length;
			for (let c in type.RawChars)
			{
				if (c == '.')
				{
					// Drop the qualifier just written (an identifier) and the dot.
					if (identStart >= start && identStart < outText.Length)
					{
						outText.RemoveToEnd(identStart);
						continue;
					}
				}
				if (!c.IsLetterOrDigit && c != '_')
				{
					outText.Append(c);
					identStart = outText.Length;
					continue;
				}
				outText.Append(c);
			}
		}

		/// `Game.Color.Red` -> `Color.Red`.
		public static void ShortCaseName(StringView subject, String outText)
		{
			let enumPart = NodeFactory.EnumOfCase(subject);
			if (enumPart.IsEmpty)
			{
				outText.Append(subject);
				return;
			}
			ShortTypeName(enumPart, outText);
			outText.Append(subject.Substring(enumPart.Length));
		}

		public void GetTitle(String outTitle)
		{
			switch (Kind)
			{
			case .Entry:
				outTitle.Append(Text.IsEmpty ? "Entry" : (StringView)Text);
			case .Call, .Bind, .Intrinsic:
				if (Kind == .Bind)
					outTitle.Append("Bind ");
				GetSubjectName(outTitle);
			case .Invoke: outTitle.Append("Invoke");
			case .Get:
				GetSubjectName(outTitle);
			case .Set:
				outTitle.Append("Set ");
				GetSubjectName(outTitle);
				let op = GetSetting("op");
				if (!op.IsEmpty)
					outTitle.AppendF(" ({})", op);
			case .Construct: outTitle.Append("Construct "); ShortTypeName(Text, outTitle);
			case .Local: outTitle.Append("Local "); ShortTypeName(Text, outTitle);
			case .Delete: outTitle.Append("Delete");
			case .Defer: outTitle.Append("Defer");
			case .DeferDelete: outTitle.Append("Defer Delete");
			case .Branch: outTitle.Append("Branch");
			case .Sequence: outTitle.Append("Sequence");
			case .While: outTitle.Append("While Loop");
			case .DoWhile: outTitle.Append("Do While Loop");
			case .For: outTitle.Append("For Loop");
			case .ForEach: outTitle.Append("For Each Loop");
			case .Break: outTitle.Append("Break");
			case .Continue: outTitle.Append("Continue");
			case .Switch:
				outTitle.Append("Switch");
				let on = GetSetting("on");
				if (!on.IsEmpty)
				{
					outTitle.Append(" on ");
					ShortTypeName(on, outTitle);
				}
			case .Scope: outTitle.Append(Unsafe ? "Unsafe" : "Scope");
			case .Gate, .DoOnce, .DoN, .FlipFlop, .MultiGate, .GateOpen, .GateClose, .GateToggle, .ResetDoOnce, .ResetDoN, .ResetMultiGate:
				FlowMacros.GetTitle(Kind, outTitle);
			case .ResultMatch: outTitle.Append("Result: match");
			case .Try: outTitle.Append("Try");
			case .Fatal: outTitle.Append("Fatal");
			case .Return: outTitle.Append("Return");
			case .ChainCtor: outTitle.Append((Text == "this") ? "This Constructor" : "Base Constructor");
			case .Operator: outTitle.Append((Text == "valid") ? "Is Valid" : (StringView)Text);
			case .Select: outTitle.Append("Select");
			case .Cast:
				if (HasSetting("test"))
				{
					outTitle.Append("Is ");
					if (Text.IsEmpty)
						outTitle.Append("Type");
					else
						ShortTypeName(Text, outTitle);
				}
				else
				{
					outTitle.Append("Cast To ");
					ShortTypeName(Text, outTitle);
				}
			case .Make: outTitle.Append("Make "); ShortTypeName(Text, outTitle);
			case .BreakStruct: outTitle.Append("Break "); ShortTypeName(Text, outTitle);
			case .MakeCase: outTitle.Append("Make "); ShortCaseName(Text, outTitle);
			case .IsCase: outTitle.Append("Is "); ShortCaseName(Text, outTitle);
			case .Index: outTitle.Append("Get [ ]");
			case .This: outTitle.Append("This");
			case .Base: outTitle.Append("Base");
			case .Literal:
				outTitle.Append("Literal");
				let lt = GetSetting("type");
				if (!lt.IsEmpty)
				{
					outTitle.Append(' ');
					ShortTypeName(lt, outTitle);
				}
			case .Lambda: outTitle.Append("Lambda");
			case .Math: outTitle.Append("Math Expression");
			case .Swizzle, .Shuffle: VectorNodes.Title(this, outTitle);
			case .Unknown: outTitle.Append((KindWord != null) ? (StringView)KindWord : "Unknown");
			}
		}
	}

	/// A collapsed node group (Graph-Format.md 3.1, `group <id> "title"` with a `node <id>` line per
	/// member): nodes of one Sheet that the editor can fold behind one node with a pin for each wire
	/// crossing the group's edge. Purely a view of the Sheet: the compiler ignores it. Whether it is
	/// folded is layout (the sidecar's `collapsed <id>`), its place too (`node <id> x y`).
	class NodeGroup
	{
		/// The record id (unique in the file, like a node's).
		public String Key = new .() ~ delete _;
		public String Title = new .() ~ delete _;
		/// The members' record ids.
		public List<String> Nodes = new .() ~ DeleteContainerAndItems!(_);
		/// Where the folded group is drawn (graph units).
		public float X;
		public float Y;
		public bool HasPos;
		/// Runtime handle in the canvas (negative, never a node's id). Not saved.
		public int32 Id;
		/// Comment lines and unknown records around the `group` record.
		public RecordExtras Extras = new .() ~ delete _;

		public bool Contains(StringView nodeKey)
		{
			for (let k in Nodes)
				if (k == nodeKey)
					return true;
			return false;
		}

		public NodeGroup Clone()
		{
			NodeGroup c = new .();
			c.Key.Set(Key);
			c.Title.Set(Title);
			for (let k in Nodes)
				c.Nodes.Add(new String(k));
			c.X = X;
			c.Y = Y;
			c.HasPos = HasPos;
			c.Id = Id;
			Extras.CopyTo(c.Extras);
			return c;
		}
	}

	class Link
	{
		public int32 Id;
		public Pin From; // output
		public Pin To;   // input
		/// Comment lines and unknown records around the `wire` record (null = none).
		public RecordExtras Extras ~ delete _;
	}

	/// A problem attached to a node (errors block a build; warnings never do).
	class GraphError
	{
		public int32 NodeId;
		public String Message = new .() ~ delete _;
		/// The pin the problem is about (its format name); null when it is about the whole node.
		/// The editor badges that pin as well as the node.
		public String PinName ~ delete _;

		/// The warning on a node the flow never reaches.
		public const String NotConnectedWarning = "Not connected to the flow: nothing runs this node. Connect it, or delete it.";
		/// The text a value call outside the flow ends with ("'Name' " + this).
		public const String ValueCallWarning = " is not connected to the flow; it is evaluated where its value is used.";

		/// True for the two warnings about a node that is not wired into the flow.
		public static bool IsConnectivity(StringView message)
		{
			return message == NotConnectedWarning || message.EndsWith(ValueCallWarning);
		}
	}

	/// The graph of one Sheet (a function body, an accessor, a lambda body).
	class Graph
	{
		public List<GraphError> Errors = new .() ~ DeleteContainerAndItems!(_);

		public void AddError(Node node, StringView message, StringView pinName = default)
		{
			int32 id = (node != null) ? node.Id : 0;
			for (let e in Errors)
				if (e.NodeId == id && e.Message == message)
					return;
			GraphError e = new .();
			e.NodeId = id;
			e.Message.Set(message);
			if (!pinName.IsEmpty)
				e.PinName = new String(pinName);
			Errors.Add(e);
		}

		public void ClearErrors()
		{
			ClearAndDeleteItems!(Errors);
			ClearAndDeleteItems!(Warnings);
		}

		public List<GraphError> Warnings = new .() ~ DeleteContainerAndItems!(_);

		public void AddWarning(Node node, StringView message, StringView pinName = default)
		{
			int32 id = (node != null) ? node.Id : 0;
			for (let e in Warnings)
				if (e.NodeId == id && e.Message == message)
					return;
			GraphError e = new .();
			e.NodeId = id;
			e.Message.Set(message);
			if (!pinName.IsEmpty)
				e.PinName = new String(pinName);
			Warnings.Add(e);
		}

		public String FindWarning(int32 nodeId)
		{
			for (let e in Warnings)
				if (e.NodeId == nodeId)
					return e.Message;
			return null;
		}

		public String FindError(int32 nodeId)
		{
			for (let e in Errors)
				if (e.NodeId == nodeId)
					return e.Message;
			return null;
		}

		/// A problem about one pin: the node and the pin are badged.
		public void AddPinError(Pin pin, StringView message) => AddError(pin.Owner, message, pin.Name);
		public void AddPinWarning(Pin pin, StringView message) => AddWarning(pin.Owner, message, pin.Name);

		/// The first error (else warning) about this pin; null when it has none. `isError` says which.
		public String FindPinProblem(Pin pin, out bool isError)
		{
			isError = true;
			for (let e in Errors)
				if (e.NodeId == pin.Owner.Id && e.PinName != null && e.PinName == pin.Name)
					return e.Message;
			isError = false;
			for (let e in Warnings)
				if (e.NodeId == pin.Owner.Id && e.PinName != null && e.PinName == pin.Name)
					return e.Message;
			return null;
		}

		public List<Node> Nodes = new .() ~ DeleteContainerAndItems!(_);
		public List<Link> Links = new .() ~ DeleteContainerAndItems!(_);
		/// Collapsed node groups (NodeGroup): a view of the Sheet, kept in its file.
		public List<NodeGroup> Groups = new .() ~ DeleteContainerAndItems!(_);
		public Node Entry;
		/// The Sheet's key (`<memberId>`, `get:<id>`, `set:<id>`, `lambda:<nodeId>`): what the
		/// layout and messages refer to.
		public String MethodKey = new .() ~ delete _;
		public String MethodName = new .() ~ delete _;
		/// The member whose Sheet this is (not owned; null for a free graph). Params, outs and
		/// locals are the member's.
		public MemberDecl Member;
		public SheetRole Role;
		/// Bumped on every structural change so views can refresh.
		public int32 Version;
		/// Positions came from AutoLayout estimates; the UI may re-run it with measured sizes.
		public bool AutoLaidOut;
		/// The Sheet can be looked at but not edited (unknown records in it, a newer file).
		public bool ReadOnly;
		/// The type whose function this is (what `this` is); empty for none.
		public String SelfType = new .() ~ delete _;
		/// No `this` (a static function or a static type): a member call needs its Receiver.
		public bool StaticContext;
		/// The function belongs to a node library (a static class).
		public bool InLibrary;
		/// The language context of the document (not owned; null: names only).
		public LanguageContext Language;

		static List<LocalDecl> sNoLocals = new .() ~ delete _;
		/// The function's local variables (the member's; empty without one).
		public List<LocalDecl> Locals => (Member != null) ? Member.Locals : sNoLocals;

		int32 mNextId = 1;

		static int32 sNextSerial = 1;
		/// Unique per Graph object (a clone gets a new one).
		public readonly int32 Serial = System.Threading.Interlocked.Increment(ref sNextSerial) - 1;

		public int32 NewId() => mNextId++;

		public static void CopyStr(ref String dst, String src)
		{
			delete dst;
			dst = (src != null) ? new String(src) : null;
		}

		/// Deep copy: nodes, pins and links keep their ids, keys and positions.
		public Graph Clone()
		{
			Graph g = new .();
			g.MethodKey.Set(MethodKey);
			g.MethodName.Set(MethodName);
			g.Member = Member;
			g.Role = Role;
			g.Version = Version;
			g.AutoLaidOut = AutoLaidOut;
			g.ReadOnly = ReadOnly;
			g.SelfType.Set(SelfType);
			g.StaticContext = StaticContext;
			g.InLibrary = InLibrary;
			g.Language = Language;
			g.mNextId = mNextId;

			Dictionary<Pin, Pin> pinMap = scope .();
			for (let src in Nodes)
			{
				let n = CloneNodeExact(src, pinMap);
				g.Nodes.Add(n);
				if (src == Entry)
					g.Entry = n;
			}
			for (let l in Links)
			{
				Link c = new .();
				c.Id = l.Id;
				c.From = pinMap[l.From];
				c.To = pinMap[l.To];
				if (l.Extras != null)
				{
					c.Extras = new .();
					l.Extras.CopyTo(c.Extras);
				}
				g.Links.Add(c);
			}
			for (let e in Errors)
				g.Errors.Add(CloneError(e));
			for (let e in Warnings)
				g.Warnings.Add(CloneError(e));
			for (let gr in Groups)
				g.Groups.Add(gr.Clone());
			return g;
		}

		/// A new group of `nodes` (their record ids), drawn at (x, y); its record id is `key`.
		public NodeGroup AddGroup(StringView key, StringView title, List<Node> nodes, float x, float y)
		{
			NodeGroup gr = new .();
			gr.Key.Set(key);
			gr.Title.Set(title);
			for (let n in nodes)
				if (!n.Key.IsEmpty && !gr.Contains(n.Key))
					gr.Nodes.Add(new String(n.Key));
			gr.X = x;
			gr.Y = y;
			gr.HasPos = true;
			gr.Id = -NewId();
			Groups.Add(gr);
			Version++;
			return gr;
		}

		public NodeGroup FindGroup(int32 id)
		{
			for (let gr in Groups)
				if (gr.Id == id)
					return gr;
			return null;
		}

		public NodeGroup FindGroupByKey(StringView key)
		{
			for (let gr in Groups)
				if (gr.Key == key)
					return gr;
			return null;
		}

		/// The group that holds `n`, or null.
		public NodeGroup GroupOf(Node n)
		{
			if (n == null || n.Key.IsEmpty)
				return null;
			for (let gr in Groups)
				if (gr.Contains(n.Key))
					return gr;
			return null;
		}

		/// Members whose node is gone leave their group; a group left with none goes. Gives every group
		/// its runtime id. True when anything changed.
		public bool PruneGroups()
		{
			bool changed = false;
			for (int i = Groups.Count - 1; i >= 0; i--)
			{
				let gr = Groups[i];
				if (gr.Id == 0)
					gr.Id = -NewId();
				for (int k = gr.Nodes.Count - 1; k >= 0; k--)
					if (FindNodeByKey(gr.Nodes[k]) == null)
					{
						delete gr.Nodes[k];
						gr.Nodes.RemoveAt(k);
						changed = true;
					}
				if (gr.Nodes.IsEmpty)
				{
					Groups.RemoveAt(i);
					delete gr;
					changed = true;
				}
			}
			if (changed)
				Version++;
			return changed;
		}

		public void RemoveGroup(NodeGroup gr)
		{
			if (Groups.Remove(gr))
			{
				delete gr;
				Version++;
			}
		}

		static GraphError CloneError(GraphError e)
		{
			GraphError c = new .();
			c.NodeId = e.NodeId;
			c.Message.Set(e.Message);
			if (e.PinName != null)
				c.PinName = new String(e.PinName);
			return c;
		}

		/// A rough size in bytes of a Clone of this graph (the undo history's byte budget).
		public int64 EstimateBytes()
		{
			int64 bytes = 256 + Links.Count * 48;
			for (let n in Nodes)
			{
				bytes += 320 + n.Text.Length + n.Key.Length + n.Settings.Count * 64;
				for (let p in n.Inputs)
					bytes += 200 + p.Name.Length + p.Label.Length + p.TypeName.Length + p.Default.Length;
				for (let p in n.Outputs)
					bytes += 200 + p.Name.Length + p.Label.Length + p.TypeName.Length;
			}
			return bytes;
		}

		/// Copies a node with its pins (ids included). Links are not copied.
		public static Node CloneNodeExact(Node src, Dictionary<Pin, Pin> pinMap = null)
		{
			Node n = new .();
			n.Id = src.Id;
			n.Kind = src.Kind;
			n.Text.Set(src.Text);
			n.SubjectType = TypeRef.CloneOrNull(src.SubjectType);
			CopyStr(ref n.KindWord, src.KindWord);
			n.IsPure = src.IsPure;
			n.X = src.X;
			n.Y = src.Y;
			n.HasPos = src.HasPos;
			n.Key.Set(src.Key);
			n.Line = src.Line;
			n.Binding = src.Binding;
			CopyStr(ref n.OwnerType, src.OwnerType);
			n.Ambiguous = src.Ambiguous;
			if (src.Overloads != null)
			{
				n.Overloads = new .();
				for (let s in src.Overloads)
					n.Overloads.Add(new String(s));
			}
			n.OverloadCount = src.OverloadCount;
			n.OverloadGen = src.OverloadGen;
			for (let s in src.Settings)
				n.Settings.Add(s.Clone());
			CopyStr(ref n.Comment, src.Comment);
			n.Disabled = src.Disabled;
			n.Unsafe = src.Unsafe;
			src.Extras.CopyTo(n.Extras);
			for (let p in src.Inputs)
			{
				let c = ClonePinExact(p, n);
				n.Inputs.Add(c);
				pinMap?.Add(p, c);
			}
			for (let p in src.Outputs)
			{
				let c = ClonePinExact(p, n);
				n.Outputs.Add(c);
				pinMap?.Add(p, c);
			}
			return n;
		}

		static Pin ClonePinExact(Pin src, Node owner)
		{
			Pin p = new .();
			p.Id = src.Id;
			p.Owner = owner;
			p.IsInput = src.IsInput;
			p.Kind = src.Kind;
			p.Name.Set(src.Name);
			p.Label.Set(src.Label);
			p.SetType(TypeRef.CloneOrNull(src.Type));
			p.Default.Set(src.Default);
			p.Optional = src.Optional;
			p.WildcardType = TypeRef.CloneOrNull(src.WildcardType);
			p.Mode = src.Mode;
			p.Role = src.Role;
			return p;
		}

		public Node AddNode(NodeKind kind)
		{
			Node n = new .();
			n.Id = NewId();
			n.Kind = kind;
			n.IsPure = NodeKinds.IsValueKind(kind);
			RecordIds.New(n.Key);
			Nodes.Add(n);
			Version++;
			return n;
		}

		/// Gives every node a record id that no other node of this graph has (`used`: ids taken
		/// elsewhere in the file; may be null).
		public void EnsureKeys(HashSet<String> used = null)
		{
			HashSet<String> mine = scope .();
			defer { for (let s in mine) delete s; }
			for (let n in Nodes)
			{
				bool clash = n.Key.IsEmpty || !RecordIds.IsValid(n.Key) || mine.ContainsAlt(StringView(n.Key)) ||
					(used != null && used.ContainsAlt(StringView(n.Key)));
				if (clash)
				{
					n.Key.Clear();
					while (true)
					{
						RecordIds.New(n.Key);
						if (!mine.ContainsAlt(StringView(n.Key)) && (used == null || !used.ContainsAlt(StringView(n.Key))))
							break;
						n.Key.Clear();
					}
				}
				mine.Add(new String(n.Key));
			}
			if (used != null)
				for (let s in mine)
					if (!used.ContainsAlt(StringView(s)))
						used.Add(new String(s));
		}

		public Node FindNodeByKey(StringView key)
		{
			for (let n in Nodes)
				if (n.Key == key)
					return n;
			return null;
		}

		public Pin AddPin(Node node, bool isInput, PinKind kind, StringView name, StringView label = "")
		{
			Pin p = new .();
			p.Id = NewId();
			p.Owner = node;
			p.IsInput = isInput;
			p.Kind = kind;
			p.Name.Set(name);
			p.Label.Set(label);
			if (isInput)
				node.Inputs.Add(p);
			else
				node.Outputs.Add(p);
			return p;
		}

		public Pin AddExecIn(Node node) => AddPin(node, true, .Flow, "in");
		public Pin AddExecOut(Node node, StringView name, StringView label = "") => AddPin(node, false, .Flow, name, label);
		public Pin AddDataIn(Node node, StringView name, StringView label) => AddPin(node, true, .Value, name, label);
		public Pin AddDataOut(Node node, StringView name, StringView label) => AddPin(node, false, .Value, name, label);

		/// The local variable named `name`, or null.
		public LocalDecl FindLocal(StringView name)
		{
			for (let l in Locals)
				if (l.Name == name)
					return l;
			return null;
		}

		/// Whether a Get / Set node of this Sheet names the local (`local:<name>`).
		public bool IsLocalUsed(StringView name)
		{
			String subject = scope $"local:{name}";
			for (let n in Nodes)
				if ((n.Kind == .Get || n.Kind == .Set) && n.Text == subject)
					return true;
			return false;
		}

		/// Removes a local of the function. Refused (false, `why` says what still uses it) while a
		/// Get / Set node of this Sheet names it.
		public bool RemoveLocal(LocalDecl local, String why)
		{
			if (local == null || Member == null || !Member.Locals.Contains(local))
				return false;
			if (IsLocalUsed(local.Name))
			{
				why.AppendF("'{}' is still read or written by nodes of this Sheet. Remove those nodes first.", local.Name);
				return false;
			}
			Member.Locals.Remove(local);
			delete local;
			Version++;
			return true;
		}

		public Node FindNode(int id)
		{
			for (let n in Nodes)
				if (n.Id == id)
					return n;
			return null;
		}

		public Pin FindPin(int id)
		{
			for (let n in Nodes)
			{
				for (let p in n.Inputs)
					if (p.Id == id)
						return p;
				for (let p in n.Outputs)
					if (p.Id == id)
						return p;
			}
			return null;
		}

		public Link FindLink(int id)
		{
			for (let l in Links)
				if (l.Id == id)
					return l;
			return null;
		}

		public Link FindLinkTo(Pin input)
		{
			for (let l in Links)
				if (l.To == input)
					return l;
			return null;
		}

		public Link FindLinkFrom(Pin output)
		{
			for (let l in Links)
				if (l.From == output)
					return l;
			return null;
		}

		public void FindLinksFrom(Pin output, List<Link> outLinks)
		{
			for (let l in Links)
				if (l.From == output)
					outLinks.Add(l);
		}

		public bool IsLinked(Pin pin)
		{
			for (let l in Links)
				if (l.From == pin || l.To == pin)
					return true;
			return false;
		}

		/// The node a flow output leads to, if any.
		public Node ExecTarget(Pin execOut)
		{
			if (execOut == null)
				return null;
			let link = FindLinkFrom(execOut);
			return link?.To.Owner;
		}

		/// The node feeding a value input, if any.
		public Node DataSource(Pin input)
		{
			let link = FindLinkTo(input);
			return link?.From.Owner;
		}

		public static bool CanConnect(Pin a, Pin b)
		{
			if (a == null || b == null || a.Owner == b.Owner)
				return false;
			if (a.IsInput == b.IsInput)
				return false;
			return a.Kind == b.Kind;
		}

		/// The wire type check: false (with a reason) when both pin types are known and the value
		/// cannot flow without a Cast. Unknown and generic types always pass.
		public static bool TypesCompatible(LanguageContext lang, Pin a, Pin b, String outReason = null)
		{
			if (a == null || b == null || a.Kind == .Flow || b.Kind == .Flow)
				return true;
			Pin from = a.IsInput ? b : a;
			Pin to = a.IsInput ? a : b;
			if (to.Name == "collection" && to.Owner.Kind == .ForEach)
			{
				String why = scope .();
				if (FlowTypes.NotACollection(from.TypeName, LanguageContext.HierarchyOf(lang), why))
				{
					outReason?.Set(why);
					return false;
				}
			}
			// A Select's condition takes a mask too (`bool4`: a select per lane, SIMD-and-Vectors.md 1.4).
			if (to.Name == "condition" && to.Owner.Kind == .Select && from.TypeName.StartsWith("bool") && Treadle.Model.VectorTypes.LanesOf(from.TypeName) > 0)
				return true;
			// The language decides (ITypeSystem.CanConvert); without a context, the generic rules.
			if (lang != null && lang.Types != null)
				return lang.Types.CanConvert(from.TypeName, to.TypeName, outReason) != .Refused;
			return TypeRules.CanConvert(from.TypeName, to.TypeName, outReason, null) != .Refused;
		}

		/// CanConnect plus the type check: what the editor uses for wires the user drags.
		public static bool CanConnectTyped(LanguageContext lang, Pin a, Pin b, String outReason = null)
		{
			if (!CanConnect(a, b))
			{
				if (outReason != null && a != null && b != null && a.Kind != b.Kind)
					outReason.Set("Flow pins connect to flow pins, value pins to value pins");
				return false;
			}
			return TypesCompatible(lang, a, b, outReason);
		}

		/// Generic pins take the type of what they are wired to: connecting an int to `T` turns
		/// every `T` on that node into int (List<T> into List<int>).
		public static void UnifyWildcards(Pin from, Pin to)
		{
			if (from.Kind != .Value || to.Kind != .Value)
				return;
			let fromWild = TypeRules.IsGenericParam(from.TypeName);
			let toWild = TypeRules.IsGenericParam(to.TypeName);
			if (toWild && !fromWild && !TypeRules.IsWildcard(from.TypeName))
				Bind(to.Owner, to.TypeName, from.TypeName);
			else if (fromWild && !toWild && !TypeRules.IsWildcard(to.TypeName))
				Bind(from.Owner, from.TypeName, to.TypeName);
		}

		static void Bind(Node node, StringView param, StringView concreteType)
		{
			String p = scope .(param);
			p.Trim();
			String c = scope .(concreteType);
			Dictionary<String, String> map = scope .();
			map[p] = c;
			void Apply(Pin pin)
			{
				if (pin.Kind != .Value || pin.TypeName.IsEmpty)
					return;
				String sub = scope .();
				TypeRules.Substitute(pin.TypeName, map, sub);
				if (sub == pin.TypeName)
					return;
				if (pin.WildcardType == null)
					pin.WildcardType = TypeRef.CloneOrNull(pin.Type);
				pin.SetTypeText(sub);
			}
			for (let pin in node.Inputs)
				Apply(pin);
			for (let pin in node.Outputs)
				Apply(pin);
		}

		/// After a disconnect: a node with no wires left on its unified pins gets its generic
		/// types back.
		public void RestoreWildcards(Node node)
		{
			bool any = false;
			for (int side < 2)
				for (let pin in (side == 0) ? node.Inputs : node.Outputs)
					if (pin.WildcardType != null)
					{
						any = true;
						if (IsLinked(pin))
							return;
					}
			if (!any)
				return;
			for (int side < 2)
				for (let pin in (side == 0) ? node.Inputs : node.Outputs)
					if (pin.WildcardType != null)
					{
						pin.SetType(pin.WildcardType);
						pin.WildcardType = null;
					}
		}

		/// Connects two pins (in either order). A flow output and a value input accept a single
		/// wire, so an existing wire there is replaced. Returns null if the pins are incompatible.
		public Link Connect(Pin a, Pin b)
		{
			if (!CanConnect(a, b))
				return null;
			Pin from = a.IsInput ? b : a;
			Pin to = a.IsInput ? a : b;

			for (int i = Links.Count - 1; i >= 0; i--)
			{
				let l = Links[i];
				bool replace = (from.Kind == .Flow && l.From == from) || (to.Kind == .Value && l.To == to);
				if (l.From == from && l.To == to)
					return l;
				if (replace)
				{
					Links.RemoveAt(i);
					delete l;
				}
			}
			return AddLinkRaw(from, to);
		}

		/// Adds a wire as it is, without replacing others (the reader: a file says what is wired).
		public Link AddLinkRaw(Pin from, Pin to)
		{
			Link link = new .();
			link.Id = NewId();
			link.From = from;
			link.To = to;
			Links.Add(link);
			UnifyWildcards(from, to);
			FlowTypes.SyncForEach(this, to.Owner);
			VectorNodes.Sync(this, to.Owner);
			Version++;
			return link;
		}

		public void Disconnect(Link link)
		{
			let a = link.From.Owner;
			let b = link.To.Owner;
			Links.Remove(link);
			delete link;
			RestoreWildcards(a);
			RestoreWildcards(b);
			FlowTypes.SyncForEach(this, b);
			VectorNodes.Sync(this, b);
			Version++;
		}

		public void DisconnectPin(Pin pin)
		{
			List<Node> fed = scope .();
			for (int i = Links.Count - 1; i >= 0; i--)
			{
				let l = Links[i];
				if (l.From == pin || l.To == pin)
				{
					if (l.To != null && (l.To.Owner.Kind == .Swizzle || l.To.Owner.Kind == .Shuffle))
						fed.Add(l.To.Owner);
					Links.RemoveAt(i);
					delete l;
				}
			}
			if (pin.Owner.Kind == .ForEach)
				FlowTypes.SyncForEach(this, pin.Owner);
			for (let n in fed)
				VectorNodes.Sync(this, n);
			Version++;
		}

		public void RemoveNode(Node node)
		{
			if (node == Entry)
				return;
			for (int i = Links.Count - 1; i >= 0; i--)
			{
				let l = Links[i];
				if (l.From.Owner == node || l.To.Owner == node)
				{
					Links.RemoveAt(i);
					delete l;
				}
			}
			Nodes.Remove(node);
			delete node;
			Version++;
		}

		/// Removes a pin (a call argument) along with its wires.
		public void RemovePin(Pin pin)
		{
			DisconnectPin(pin);
			let node = pin.Owner;
			node.Inputs.Remove(pin);
			node.Outputs.Remove(pin);
			delete pin;
			Version++;
		}

		/// Marks every node reachable from the Entry (flow plus the values feeding it).
		public void GetReachable(HashSet<Node> outReachable, bool withChain = true)
		{
			List<Node> stack = scope .();
			if (Entry != null)
				stack.Add(Entry);
			// A constructor's Base / This Constructor node belongs to the declaration.
			if (withChain)
				for (let n in Nodes)
					if (n.Kind == .ChainCtor)
						stack.Add(n);
			while (!stack.IsEmpty)
			{
				let n = stack.PopBack();
				if (!outReachable.Add(n))
					continue;
				for (let p in n.Outputs)
				{
					if (p.Kind == .Flow)
					{
						List<Link> outs = scope .();
						FindLinksFrom(p, outs);
						for (let l in outs)
							stack.Add(l.To.Owner);
					}
				}
				for (let p in n.Inputs)
				{
					if (p.Kind == .Value)
					{
						let src = DataSource(p);
						if (src != null)
							stack.Add(src);
					}
				}
			}
		}
	}
}
