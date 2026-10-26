using System;
using ImGui;
using Treadle.Graph;
using Treadle.Catalog;

namespace Treadle.Editor
{
	/// Every colour of the node graph, in one place: what each kind of value is drawn in (pins, wires, variable
	/// pills, type swatches in the lists and Properties) and what each kind of node is headed with. Nothing else in
	/// the editor holds a node or pin colour of its own: it asks here (`TypeColor`, `PinColor`, `FamilyColor`,
	/// `HeaderColor`). The values follow the familiar visual-scripting conventions, so a bool is red, an int teal,
	/// a float green, a string magenta, an object blue, a struct dark blue, an exec white and an untyped
	/// (wildcard) value grey.
	static class Theme
	{
		// ---- Values: one colour per family of types (see TypeRules.Family) ------------------------
		public static uint32 ExecPin = Gui.Color(240, 240, 240);
		public static uint32 BoolPin = Gui.Color(146, 0, 0);
		public static uint32 IntPin = Gui.Color(31, 227, 175);
		public static uint32 FloatPin = Gui.Color(160, 250, 68);
		public static uint32 StringPin = Gui.Color(251, 0, 209);
		public static uint32 CharPin = Gui.Color(206, 120, 255);
		public static uint32 ObjectPin = Gui.Color(0, 168, 242);
		public static uint32 StructPin = Gui.Color(0, 87, 200);
		/// The Vector family: the vector primitives (`float4`, `int32x4`, `bool4`; their lane bars take the
		/// element's colour) and the vector-like structs (Vec3, Color, Quat): gold, apart from float green,
		/// int teal and struct dark blue on the canvas of both themes.
		public static uint32 VectorPin = Gui.Color(253, 200, 35);
		public static uint32 EnumPin = Gui.Color(0, 109, 99);
		public static uint32 InterfacePin = Gui.Color(238, 252, 168);
		public static uint32 DelegatePin = Gui.Color(255, 56, 56);
		public static uint32 PointerPin = Gui.Color(110, 150, 210);
		public static uint32 VoidPin = Gui.Color(120, 120, 120);
		public static uint32 WildPin = Gui.Color(170, 170, 170);

		// ---- Nodes: the header colour of each kind -------------------------------------------------
		public static uint32 HeaderCall = Gui.Color(50, 90, 150);
		public static uint32 HeaderPure = Gui.Color(78, 117, 38);
		public static uint32 HeaderFlow = Gui.Color(90, 90, 90);
		/// A function's entry and an event: purple-red.
		public static uint32 HeaderEntry = Gui.Color(140, 30, 86);
		/// The entry of a function that overrides one: red.
		public static uint32 HeaderOverride = Gui.Color(140, 26, 26);
		public static uint32 HeaderVar = Gui.Color(40, 110, 120);
		public static uint32 HeaderCode = Gui.Color(130, 80, 30);
		/// A Return: purple.
		public static uint32 HeaderReturn = Gui.Color(104, 52, 150);
		public static uint32 HeaderCast = Gui.Color(30, 110, 140);
		/// Construct (a heap allocation): green.
		public static uint32 HeaderConstruct = Gui.Color(62, 118, 44);
		/// Local (a region allocation): teal.
		public static uint32 HeaderLocal = Gui.Color(24, 112, 112);
		/// The light grey of flow items in the Node menu's list.
		public static uint32 FlowAccent = Gui.Color(200, 200, 200);

		public static uint32 TextDim = Gui.Color(150, 150, 150);
		public static uint32 TextCode = Gui.Color(214, 197, 150);
		public static uint32 Warning = Gui.Color(255, 196, 0);
		public static uint32 Good = Gui.Color(110, 210, 90);

		// ---- Canvas, node bodies and wires ---------------------------------------------------------
		public static uint32 CanvasBg = Gui.Color(38, 38, 38);
		public static uint32 GridMinor = Gui.Color(52, 52, 52);
		public static uint32 GridMajor = Gui.Color(20, 20, 20);
		public static uint32 NodeBody = Gui.Color(15, 15, 15, 230);
		public static uint32 NodeShadow = Gui.Color(0, 0, 0, 90);
		public static uint32 NodeOutline = Gui.Color(0, 0, 0, 200);
		public static uint32 NodeSelected = Gui.Color(255, 170, 0);
		public static uint32 NodeError = Gui.Color(255, 50, 50);
		public static uint32 ErrorHeader = Gui.Color(170, 30, 30);
		/// The amber of a warning strip on a node (an error strip is ErrorHeader).
		public static uint32 ProblemWarningFill = Gui.Color(190, 150, 20);
		public static uint32 NodeTitle = Gui.Color(255, 255, 255);
		public static uint32 NodeSubtitle = Gui.Color(160, 160, 160);
		public static uint32 PinLabel = Gui.Color(205, 205, 205);
		public static uint32 WireExec = Gui.Color(235, 235, 235);
		public static uint32 WireBad = Gui.Color(255, 60, 60);
		public static uint32 MarqueeFill = Gui.Color(255, 170, 0, 30);
		public static uint32 MarqueeBorder = Gui.Color(255, 170, 0, 200);
		public static uint32 InlineFieldBg = Gui.Color(10, 10, 10, 220);

		/// Same color with a different alpha.
		public static uint32 WithAlpha(uint32 c, uint8 a) => (c & 0x00FFFFFF) | ((uint32)a << 24);

		/// Mixes `c` towards `to` by `t` (0..1), alpha included.
		public static uint32 Mix(uint32 c, uint32 to, float t)
		{
			uint32 result = 0;
			for (int32 shift = 0; shift < 32; shift += 8)
			{
				float a = (c >> shift) & 0xFF;
				float b = (to >> shift) & 0xFF;
				uint32 v = (uint32)Math.Clamp((int)(a + (b - a) * t + 0.5f), 0, 255);
				result |= v << shift;
			}
			return result;
		}

		public static uint32 Lighten(uint32 c, float f)
		{
			uint32 r = c & 0xFF;
			uint32 g = (c >> 8) & 0xFF;
			uint32 b = (c >> 16) & 0xFF;
			uint32 a = (c >> 24) & 0xFF;
			r = (uint32)Math.Min(255, (int)(r * f));
			g = (uint32)Math.Min(255, (int)(g * f));
			b = (uint32)Math.Min(255, (int)(b * f));
			return (a << 24) | (b << 16) | (g << 8) | r;
		}

		/// What a pin is drawn in: white for flow, else the colour of its type (`TypeColor`).
		public static uint32 PinColor(Pin pin)
		{
			if (pin.Kind == .Flow)
				return ExecPin;
			// What a Lambda or Bind Function gives is a function as a value: the delegate colour, a
			// function pointer (C callback) too.
			if (!pin.IsInput && pin.Name == "value" && pin.Owner != null && (pin.Owner.Kind == .Lambda || pin.Owner.Kind == .Bind))
				return DelegatePin;
			return TypeColor(pin.TypeName);
		}

		/// The language context of the workspace this window shows (EditorApp sets it): pin colours
		/// ask it what kind a type is (enum, struct, interface). Presentation only: it goes when the
		/// Core hands out type families without asking the editor (docs/Graph-Architecture.md, step 3).
		public static Treadle.Language.LanguageContext Language;

		/// The colour of a family of types: the palette above.
		public static uint32 FamilyColor(TypeFamily family)
		{
			switch (family)
			{
			case .Flow: return ExecPin;
			case .Bool: return BoolPin;
			case .Int: return IntPin;
			case .Float: return FloatPin;
			case .Char: return CharPin;
			case .String: return StringPin;
			case .Object: return ObjectPin;
			case .Struct: return StructPin;
			case .Vector: return VectorPin;
			case .Enum: return EnumPin;
			case .Interface: return InterfacePin;
			case .Delegate: return DelegatePin;
			case .Pointer: return PointerPin;
			case .Void: return VoidPin;
			case .Unknown, .Wildcard: return WildPin;
			}
		}

		/// Pin / variable colour for a type. A collection (`int[]`, `List<float>`, `Span<char8>`, `HashSet<T>`,
		/// the keys of a `Dictionary`) is drawn in the colour of what it holds, so a list of ints is teal like an
		/// int and only its shape (PinStyle) says "many". The family comes from TypeRules.Family, which uses the
		/// workspace's types when there are any (a class is blue, a struct dark blue, an enum teal).
		public static uint32 TypeColor(StringView typeName)
		{
			String element = scope .();
			if (TypeRules.SplitCollection(typeName, element) != .None)
				return TypeColor(element);
			// The family is the language's answer (ITypeSystem.Family), the generic rules without one.
			if (Language != null && Language.Types != null)
				return FamilyColor(Language.Types.Family(typeName));
			return FamilyColor(TypeRules.Family(typeName, null));
		}

		/// The colour of what a map holds as values (`Dictionary<String, int>`: the int's); every other type: its
		/// own colour, so a pin can draw both halves of a map in two colours and the rest in one. A vector
		/// (`float4`): its element's colour, the colour of its lane bars (PinStyle.Lanes).
		public static uint32 ValueColor(StringView typeName)
		{
			String element = scope .();
			String value = scope .();
			if (TypeRules.SplitCollection(typeName, element, value) == .Map)
				return TypeColor(value);
			String lane = scope .();
			if (Treadle.Model.VectorTypes.Info(typeName, lane, ?))
				return TypeColor(lane);
			return TypeColor(typeName);
		}

		/// Header of variable nodes (SET, Local): the variable's type colour, darkened.
		public static uint32 VariableHeader(StringView typeName)
		{
			var t = typeName;
			t.Trim();
			if (t.IsEmpty || t == "var" || t == "let")
				return HeaderVar;
			return Mix(TypeColor(t), Gui.Color(0, 0, 0, 255), 0.45f);
		}

		public static uint32 HeaderColor(Node node)
		{
			switch (node.Kind)
			{
			case .Entry, .ChainCtor: return HeaderEntry;
			case .Return: return HeaderReturn;
			case .Call, .Invoke, .Intrinsic: return node.IsPure ? HeaderPure : HeaderCall;
			case .Branch, .Sequence, .While, .DoWhile, .For, .ForEach, .Break, .Continue, .Switch, .Scope, .Gate, .DoOnce, .DoN, .FlipFlop, .MultiGate,
				.GateOpen, .GateClose, .GateToggle, .ResetDoOnce, .ResetDoN, .ResetMultiGate, .Defer, .ResultMatch, .Try:
				return HeaderFlow;
			case .Delete, .DeferDelete: return HeaderCall;
			case .Construct: return HeaderConstruct;
			case .Local: return HeaderLocal;
			case .Cast: return HeaderCast;
			case .Fatal, .Unknown: return ErrorHeader;
			case .Set: return HeaderVar;
			default: return HeaderPure;
			}
		}
	}
}
