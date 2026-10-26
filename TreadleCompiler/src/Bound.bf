using System;
using System.Collections;
using Treadle.Model;
using Treadle.Graph;
using Treadle.Document;

namespace Treadle.Compiler
{
	/// What a Get / Set node names (Language.md 5.5).
	enum VarKind : uint8
	{
		None,
		Field,
		StaticField,
		Property,
		Local,
		Param,
		/// An `out` parameter: written through its pointer.
		OutParam,
		/// `T[].Length`.
		ArrayLength
	}

	/// How an Operator node is carried out.
	enum OpImpl : uint8
	{
		None,
		/// Numbers, bools, chars, enums, references, pointers.
		Builtin,
		/// An operator record of a type (a static call).
		User,
		/// A generic parameter's operator constraint: decided per instantiation (Lower).
		Generic
	}

	/// A Call on an event (`Call this.OnHit.Add`, Language.md 4, Event).
	enum EventOp : uint8
	{
		None,
		Add,
		Remove,
		Invoke,
		Clear,
		Count
	}

	/// How a Bind or Lambda node makes its value (`set alloc`, Language.md 4.2).
	enum DelegateAlloc : uint8
	{
		/// No allocation: a function pointer (a static function; a Lambda of a `function:` type).
		Pointer,
		/// A delegate object on the heap (Delete frees it).
		Construct,
		/// A delegate object in the node's region (freed when the region ends).
		Local
	}

	/// What a Lambda Sheet reads of its enclosing function (Language.md 4.2): a local variable, a
	/// parameter, or `this`. It becomes a field of the closure.
	class Capture
	{
		public enum Kind : uint8 { Local, Param, This }
		public Kind What;
		public String Name = new .() ~ delete _;
		public KType Type;
		/// `capture <name> by-ref` on the Lambda node: the field is a pointer to the variable.
		public bool ByRef;
		/// Not read by this Sheet's own nodes: a Lambda inside it reads the variable, through this
		/// closure (a nested Lambda's chained capture, Language.md 4.2).
		public bool Chained;

		/// The closure's field: the variable's name, `__this` for `this`.
		public void FieldName(String o)
		{
			if (What == .This)
				o.Append("__this");
			else
				o.Append(Name);
		}
	}

	enum CastKind : uint8
	{
		None,
		Numeric,
		EnumToInt,
		IntToEnum,
		Class,
		Unchecked,
		Box,
		Unbox,
		/// The value already has the type.
		Identity,
		/// An array to a Span over it (Language.md 2.3, the implicit conversion as a node).
		Span,
		/// `T?` to `T` (Language.md 2.3): a null is a fatal error naming the node; the checked Cast
		/// takes Failed instead.
		Unwrap

	}

	/// An input the node takes (whether or not the file has a pin for it).
	class InSpec
	{
		public String Name = new .() ~ delete _;
		/// The label diagnostics use ("Receiver", a parameter name).
		public String Label = new .() ~ delete _;
		public KType Type;
		public bool Optional;
		public bool IsReceiver;
		/// `ref`: the source must be a variable.
		public bool IsRef;
		/// The pin (null when the file has none: then it is neither wired nor set).
		public Pin Pin;
	}

	/// A value output the node gives.
	class OutSpec
	{
		public String Name = new .() ~ delete _;
		public KType Type;
		/// Reads of it are legal only inside this region-opening flow output (`body` for a For's
		/// `index`, `ok` for ResultMatch's `value`); "" = wherever the node dominates.
		public String OnlyIn = new .() ~ delete _;
	}

	/// The bound form of one node: its subject resolved to symbols, its pins typed.
	class BNode
	{
		public Node Node;
		/// 0 not bound, 1 binding (cycle detection), 2 bound.
		public int32 State;
		/// A flow node (flow input, flow outputs).
		public bool Flow;
		public MemberSym Member;
		/// Construct / Local / Cast / Make / Break / Switch / MakeCase / IsCase: the type.
		public KType Subject;
		/// Member nodes: the owner instance the member is reached through.
		public KType Owner;
		/// The Receiver is not wired: `this` (or `base` for a Base receiver).
		public bool ReceiverIsThis;
		/// The Receiver is the Base node: a non-virtual call of the base version.
		public bool ReceiverIsBase;
		/// The generic map: the owner instance's parameters and the function's own.
		public Dictionary<GenericParamSym, KType> Map ~ delete _;
		/// The function's own generic arguments, in order (generic function calls).
		public List<KType> MethodArgs ~ delete _;
		public VarKind Var;
		public LocalDecl LocalVar;
		public ParamSym ParamVar;
		/// Enum case nodes.
		public MemberSym Case;
		/// Set: `set op +=` as the operator symbol ("+"); "" for a plain Set.
		public String SetOp = new .() ~ delete _;
		public OpImpl OpImpl;
		/// Operator / compound Set: the type the operands are converted to.
		public KType OperandType;
		public CastKind Cast;
		/// Switch: the case labels in order (`Red`, `3`).
		public List<String> Cases ~ DeleteContainerAndItems!(_);
		public List<InSpec> Ins = new .() ~ DeleteContainerAndItems!(_);
		public List<OutSpec> Outs = new .() ~ DeleteContainerAndItems!(_);
		/// The flow outputs the node has (format names).
		public List<String> FlowOuts = new .() ~ DeleteContainerAndItems!(_);
		/// The node is an unsafe node (pointer work, an unchecked cast, an unsafe call).
		public bool Unsafe;
		/// Check: the flow nodes that evaluate this value node (Rule 2).
		public List<BNode> Owners = new .() ~ delete _;
		/// Check: the flow node is reached from the Entry.
		public bool Reached;
		/// Check: the flow node's region.
		public Region Region;
		/// Check: index in the flow graph (-1 = not a vertex).
		public int32 Vertex = -1;
		/// Lower: not lowered (a node kind that comes later); Check reported it.
		public bool Unsupported;
		/// For Each over an enumerator: GetEnumerator (Member), MoveNext and the Current
		/// property, and the enumerator type (Language.md 5.1).
		public MemberSym EnumMove;
		public MemberSym EnumCurrent;
		public KType EnumType;
		/// Switch over text (String / StringView): the case labels are texts.
		public bool TextSwitch;
		/// A checked Cast: a flow node with Succeeded (`then`) and Failed.
		public bool Checked;
		/// Construct / Delete with a wired `allocator`.
		public bool WithAllocator;
		/// Gate family (stateful and action nodes): the state field is static.
		public bool StateStatic;
		/// Multi Gate `set random`: the hidden seed field.
		public MemberSym StateSeed;
		/// Bind / Lambda: how the delegate is made (Language.md 4.2).
		public DelegateAlloc Alloc;
		/// A Call on an event: which of its nodes (Member is the event field).
		public EventOp EventOp;
		/// Bind Function of a struct's function: the target is the struct's address (BindStructTarget).
		public bool StructTarget;
		/// Lambda: the nested Sheet's result (its captures) and the closure class Lower makes.
		public SheetResult LambdaSheet;
		public TypeSym Closure;
		/// Get / Set in a Lambda Sheet: the variable is a capture (a field of the closure).
		public bool IsCapture;
		/// Math Expression: the bound expression (Lower makes its ops from it).
		public MathNode MathTree ~ delete _;
		/// Inputs whose literal names a constant (`in count Game.Rows`): pin -> the folded value;
		/// ConstRefs are the constants (incremental Validate binds the Sheet again with them).
		public Dictionary<String, String> ConstPins ~ DeleteDictionaryAndKeysAndValues!(_);
		public List<MemberSym> ConstRefs ~ delete _;
		/// Call of a C function: inputs that pass a variable's address to a `T*` parameter (the
		/// variable is a T), and the extra inputs of a variadic function (`va0`, `va1`, ...).
		public List<String> AddressArgs ~ DeleteContainerAndItems!(_);
		public List<String> VarArgs ~ DeleteContainerAndItems!(_);
		/// Call of `Core.Atomic`: the memory order (`set order`, default seqcst).
		public String Order ~ delete _;

		public bool IsAddressArg(StringView pin)
		{
			if (AddressArgs != null)
				for (let a in AddressArgs)
					if (a == pin)
						return true;
			return false;
		}

		public StringView Key => Node.Key;
		public NodeKind Kind => Node.Kind;

		/// Evaluated N times per run of the Sheet's flow nodes: the number of flow nodes that
		/// consume it (Language.md 5.2, "evaluated Nx").
		public int EvalCount => Owners.Count;

		public InSpec FindIn(StringView name)
		{
			for (let i in Ins)
				if (i.Name == name)
					return i;
			return null;
		}

		public OutSpec FindOut(StringView name)
		{
			for (let o in Outs)
				if (o.Name == name)
					return o;
			return null;
		}

		public bool HasFlowOut(StringView name)
		{
			for (let f in FlowOuts)
				if (f == name)
					return true;
			return false;
		}

		public InSpec AddIn(StringView name, KType type, bool optional = false, StringView label = "")
		{
			InSpec s = new .();
			s.Name.Set(name);
			s.Label.Set(label.IsEmpty ? name : label);
			s.Type = type;
			s.Optional = optional;
			s.Pin = Node.FindInput(name);
			Ins.Add(s);
			return s;
		}

		public OutSpec AddOut(StringView name, KType type, StringView onlyIn = "")
		{
			OutSpec o = new .();
			o.Name.Set(name);
			o.Type = type;
			o.OnlyIn.Set(onlyIn);
			Outs.Add(o);
			return o;
		}

		public void AddFlowOut(StringView name) => FlowOuts.Add(new String(name));
	}

	/// What kind of region a body output opens (Language.md 5.3) and where flow goes when it
	/// ends inside the region without a wire.
	enum RegionKind : uint8
	{
		/// The function body: an unwired end returns.
		Function,
		/// A loop body: an unwired end runs the next pass.
		Loop,
		/// Sequence `then<i>`: an unwired end runs the next output (the last ends the Sequence).
		SequenceArm,
		/// A body that continues at its node's Completed (`done`): Scope, Switch cases,
		/// ResultMatch arms, Gate / Do Once / Do N / Flip Flop / Multi Gate outputs.
		Block,
		/// Branch arms, a checked Cast's Failed: an unwired end continues where the enclosing
		/// region would.
		Arm,
		/// Defer's `deferred`: runs at the region's exit; its end returns there.
		Deferred
	}

	/// A region: the flow nodes dominated by a body output (Language.md 5.3).
	class Region
	{
		public int32 Id;
		public RegionKind Kind;
		public Region Parent;
		/// The node whose output opens it (null for the function region).
		public BNode Owner;
		/// The output pin's format name.
		public String Pin = new .() ~ delete _;
		/// Check: Locals and Defers that belong to it, in dominance (execution) order.
		public List<BNode> Locals = new .() ~ delete _;
		public List<BNode> Defers = new .() ~ delete _;
		/// The Scope is marked unsafe.
		public bool Unsafe;

		public bool IsLoop => Kind == .Loop;

		/// `this` is `r` or inside it.
		public bool Within(Region r)
		{
			var c = this;
			while (c != null)
			{
				if (c == r)
					return true;
				c = c.Parent;
			}
			return false;
		}

		public int Depth
		{
			get
			{
				int d = 0;
				var c = Parent;
				while (c != null)
				{
					d++;
					c = c.Parent;
				}
				return d;
			}
		}
	}

	/// One bound and checked Sheet: what Validate reports and Lower reads.
	class SheetResult
	{
		public Sheet Sheet;
		public SourceUnit Unit;
		/// The type the Sheet's member belongs to (`this`); for an extension's Sheet the extended type.
		public TypeSym Type;
		/// An extension's Sheet: the extension (its file, its namespace and uses lines); else null.
		public TypeSym Scope;
		public MemberSym Member;
		/// The graph Bind, Check and Lower read: the Sheet's own, or `Expanded` when it has split pins.
		public Graph Graph;
		/// The Sheet's graph as the editor holds it (what the services are asked about).
		public Graph Source;
		/// A copy of the Sheet's graph with each split pin's Make / Break made (SplitPins.Expand); owned.
		public Graph Expanded ~ delete _;
		public DiagSite Site;
		public String SiteType = new .() ~ delete _;
		public List<BNode> Nodes = new .() ~ DeleteContainerAndItems!(_);
		public Dictionary<Node, BNode> ByNode = new .() ~ delete _;
		/// `this` (null in a static context).
		public KType This;
		/// What a Return gives back (void for constructors, the property type for a getter).
		public KType Returns;
		/// The Sheet must be pure (a Pure function, a getter).
		public bool MustBePure;
		/// The function is marked Unsafe.
		public bool UnsafeSheet;
		public BNode Entry;
		public List<Region> Regions = new .() ~ DeleteContainerAndItems!(_);
		/// Check: the flow vertices (nodes and flow output pins) and their immediate dominators.
		public FlowGraph Flow ~ delete _;
		/// Errors were reported on this Sheet (Lower skips it).
		public bool HasErrors;
		/// Check ran on it.
		public bool Checked;
		/// A Lambda Sheet: the Lambda node in the enclosing Sheet (null when it is gone), the
		/// delegate or function type it gives, its inputs, and what it captures.
		public Node LambdaNode;
		public Sheet LambdaOwner;
		public KType LambdaType;
		public List<ParamSym> LambdaParams = new .() ~ DeleteContainerAndItems!(_);
		public List<Capture> Captures = new .() ~ DeleteContainerAndItems!(_);

		public bool IsLambda => Sheet.Role == .Lambda;

		public ParamSym FindLambdaParam(StringView name)
		{
			for (let p in LambdaParams)
				if (p.Name == name)
					return p;
			return null;
		}

		public Capture FindCapture(Capture.Kind what, StringView name)
		{
			for (let c in Captures)
				if (c.What == what && (what == .This || c.Name == name))
					return c;
			return null;
		}

		public BNode Get(Node n)
		{
			if (n != null && ByNode.TryGetValue(n, let b))
				return b;
			// A node of the editor's graph when Bind read the expanded copy: the same record id.
			if (n != null && Expanded != null)
				return FindKey(n.Key);
			return null;
		}

		public BNode FindKey(StringView key)
		{
			for (let b in Nodes)
				if (b.Node.Key == key)
					return b;
			return null;
		}

		/// The wire into an input pin (null when none).
		public Link LinkTo(Pin p)
		{
			if (p == null)
				return null;
			return Graph.FindLinkTo(p);
		}

		/// The node and output feeding an input (null when unwired).
		public (BNode node, Pin pin) Source(InSpec s)
		{
			let l = LinkTo(s.Pin);
			if (l == null)
				return (null, null);
			return (Get(l.From.Owner), l.From);
		}

		/// The node and output feeding the input `pin` of `b` (null when unwired).
		public (BNode node, Pin pin) Source(BNode b, StringView pin)
		{
			let s = b.FindIn(pin);
			if (s == null)
				return (null, null);
			return Source(s);
		}

		/// Whether the output `pin` of `src` names a place a Mutating struct call changes in place
		/// (Language.md 2.2): a local, a parameter, a static field, a field of an object, a field of
		/// a place (chained), `this`, a struct Local's object, an element of an array, a span or a
		/// pointer. Anything else (a call's result, a Make, a Cast, a property, a For Each element)
		/// is a temporary.
		public bool IsPlace(BNode src, StringView pin)
		{
			if (src == null)
				return false;
			if (src == Entry)
				return true; // a parameter
			switch (src.Kind)
			{
			case .This:
				return true;
			case .Local:
				return pin == "object";
			case .Get:
				switch (src.Var)
				{
				case .Local, .Param, .OutParam:
					return true;
				case .StaticField:
					let m = src.Member;
					// a constant is a value, not a variable (Language.md 4.6)
					if (m == null || m.Const)
						return false;
					return !m.CVar || m.CVarVia == null || m.CVarDeref;
				case .Field:
					if (src.IsCapture || src.ReceiverIsThis || src.Owner == null || !src.Owner.IsStruct)
						return true;
					let (rn, rp) = Source(src, "receiver");
					if (rp == null)
						return false;
					let rt = rn.FindOut(rp.Name)?.Type;
					return (rt != null && rt.Kind == .Pointer) || IsPlace(rn, rp.Name);
				default:
					return false;
				}
			case .Index:
				if (src.Member != null)
					return false;
				let ct = src.FindIn("collection")?.Type;
				if (ct == null)
					return false;
				return ct.Kind == .Array || ct.Kind == .Pointer || (ct.Kind == .Named && ct.Sym.FullName == "Core.Span");
			default:
				return false;
			}
		}

		/// The node (and its output) a place starts from: through the fields of struct places to the
		/// Get, Entry output, Local, This or Get [ ] at its root; null when a link is missing.
		public (BNode node, StringView pin) PlaceRoot(BNode src, StringView pin)
		{
			var src;
			var pin;
			while (src != null && src.Kind == .Get && src.Var == .Field && !src.IsCapture && !src.ReceiverIsThis && src.Owner != null && src.Owner.IsStruct)
			{
				let (rn, rp) = Source(src, "receiver");
				if (rp == null)
					return (null, "");
				src = rn;
				pin = rp.Name;
				let rt = rn.FindOut(rp.Name)?.Type;
				if (rt != null && rt.Kind == .Pointer)
					break;
			}
			return (src, pin);
		}
	}
}
