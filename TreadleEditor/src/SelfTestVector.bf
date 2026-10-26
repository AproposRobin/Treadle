// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using Treadle.Catalog;
using Treadle.Compiler;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Language;
using Treadle.Model;

namespace Treadle.Editor
{
	/// The `editor` case's checks of the vector types on the editor side (docs/SIMD-and-Vectors.md 1.9), run
	/// before the case saves Player (one phase per frame; the edits on Player are undone):
	///
	///  - Names: the spellings parse to a Vector TypeRef and print back (`Vector<float,4>` reads as float4),
	///    T1090 for `int4` / `double16`, the Vector family and its colour, the conversions (none implicit).
	///  - Nodes: Make / Break lanes, Swizzle and Shuffle result types and their T2301 checks, an Operator
	///    with a vector (element-wise; a comparison gives a mask, && on vectors T2300), a mask into Select.
	///  - Literals: lane lists, splats, the per-lane write.
	///  - The format: a type file with vector fields, parameters and nodes reads and writes back byte for
	///    byte; the compiler's front end binds the vector nodes and reports only the unwired lane of a
	///    Make.
	///  - The Node menu: the stand-in rows and their replacement by a source row; from a float4 output its
	///    rows first (Break, Swizzle, Shuffle, the lanes, the reductions), then the operators; into a float4
	///    input Make and Splat; nodes made from the rows; Split Pin on a vector pin.
	///  - Properties' setters: the swizzle lanes, a refused letter, the vector type of a Make; each one undo step.
	extension EditorApp
	{
		int mVecPhase;
		bool mVecDone;
		int mVecNodesBefore;
		String mVecMake = new .() ~ delete _;
		String mVecSwizzle = new .() ~ delete _;
		String mVecBreak = new .() ~ delete _;

		const String cVectorDemo = """
			# treadle 1
			type VecDemo struct
				namespace Game

			field mDir float4

			field mMask bool4

			field mBytes uint8x16

			function k2b8f Scaled
				pure
				returns float4
			param v float4
			param k int32x4
			sheet body
			node b1 Entry
			node b2 Make float4
				in w 1
			node b3 Break float4
			node b4 Swizzle
				set lanes zyx
			node b5 Shuffle
				set mask 0 4 1 5
			node b6 Return
			node b7 Operator *
				in b 2
			node b8 Operator <
			wire b3.x b2.x
			wire b3.y b2.y
			wire b1.v b3.value
			wire b1.v b4.value
			wire b1.v b5.a
			wire b2.value b5.b
			wire b1.then b6.in
			wire b7.result b6.value
			wire b5.result b7.a
			wire b7.result b8.a
			wire b1.v b8.b

			""";

		/// One phase per call; true when all are done.
		bool SelfTestVectorBefore()
		{
			switch (mVecPhase++)
			{
			case 0: SelfTestVectorNames(); return false;
			case 1: SelfTestVectorNodes(); return false;
			case 2: SelfTestVectorFormat(); return false;
			case 3: SelfTestVectorEdit(0); return false;
			case 4: SelfTestVectorEdit(1); return false;
			case 5: SelfTestVectorEdit(2); return false;
			default:
				mVecPhase = 0;
				return true;
			}
		}

		void SelfTestVectorNames()
		{
			bool Is(StringView text, StringView element, int lanes)
			{
				let t = TypeRef.Parse(text);
				defer delete t;
				return t.Kind == .Vector && t.Element != null && t.Element.Name == element && t.Lanes == lanes && t.ToString(.. scope String()) == text;
			}
			SelfTestCheck(Is("float4", "float", 4) && Is("float2", "float", 2) && Is("float16", "float", 16) && Is("double2", "double", 2) && Is("double8", "double", 8) &&
				Is("int32x4", "int32", 4) && Is("uint8x16", "uint8", 16) && Is("uint8x64", "uint8", 64) && Is("int16x32", "int16", 32) && Is("int64x2", "int64", 2) &&
				Is("bool4", "bool", 4) && Is("bool64", "bool", 64) && Is("float3", "float", 3),
				"vector: the spellings parse to a Vector type and print back (float4, double2, int32x4, uint8x16, bool4, float3)");
			bool Named(StringView text)
			{
				let t = TypeRef.Parse(text);
				defer delete t;
				return t.Kind == .Named && t.ToString(.. scope String()) == text;
			}
			SelfTestCheck(Named("int32") && Named("uint8") && Named("int4") && Named("double16") && Named("int64x16") && Named("float5") && Named("floatx4") &&
				Named("int324") && Named("Vec3") && Named("Player2"),
				"vector: scalars, wrong spellings and sizes over 64 bytes stay plain names (int32, int4, double16, int64x16, float5, floatx4)");
			{
				let longForm = TypeRef.Parse("Vector<float,4>");
				let shortForm = TypeRef.Parse("float4");
				defer { delete longForm; delete shortForm; }
				SelfTestCheck(longForm.Kind == .Vector && longForm.Equals(shortForm) && longForm.ToString(.. scope String()) == "float4",
					"vector: Vector<float,4> (the reserved long form) reads as float4 and is written short");
				let nested = TypeRef.Parse("List<Vector<int32,4>>");
				let bad = TypeRef.Parse("Vector<int,4>");
				defer { delete nested; delete bad; }
				SelfTestCheck(nested.Kind == .Named && nested.Args[0].Kind == .Vector && nested.ToString(.. scope String()) == "List<int32x4>" &&
					bad.Kind == .Named && bad.ToString(.. scope String()) == "Vector<int,4>",
					"vector: the long form inside a generic argument too; Vector<int,4> (no such type) stays as written");
			}
			bool RoundTrip(StringView text)
			{
				let t = TypeRef.Parse(text);
				defer delete t;
				let c = t.Clone();
				defer delete c;
				return t.Kind != .Raw && t.ToString(.. scope String()) == text && c.Equals(t);
			}
			SelfTestCheck(RoundTrip("float4[]") && RoundTrip("float3?") && RoundTrip("List<float4>") && RoundTrip("Dictionary<int,bool4>") && RoundTrip("(float2,int32x4)") &&
				RoundTrip("function:float4(float4,float)") && RoundTrip("float4[4]") && RoundTrip("uint8x16*"),
				"vector: vector types inside arrays, nullables, generics, tuples, functions and pointers round-trip");
			String why = scope .();
			SelfTestCheck(!VectorTypes.Check("int4", why) && why.Contains("T1090") && why.Contains("int32x4 or int64x4"), scope $"vector: int4 is T1090 with the hint int32x4 or int64x4: {why}");
			why.Clear();
			SelfTestCheck(!VectorTypes.Check("double16", why) && why.Contains("T1090") && why.Contains("128 bytes"), scope $"vector: double16 is T1090 (over 64 bytes): {why}");
			why.Clear();
			SelfTestCheck(!VectorTypes.Check("float5", why) && VectorTypes.Check("float4", why) && VectorTypes.Check("Vec3", why) && VectorTypes.Check("int32", why),
				"vector: float5 is T1090; float4, Vec3 and int32 pass the name check");
			SelfTestCheck(VectorTypes.Describe("float4", .. scope String()) == "float4 (4 x float, 16 bytes)" &&
				VectorTypes.Describe("float3", .. scope String()) == "float3 (3 x float, 16 bytes)" &&
				VectorTypes.Describe("uint8x16", .. scope String()) == "uint8x16 (16 x uint8, 16 bytes)",
				"vector: the pin tooltip's description (float4 (4 x float, 16 bytes); a float3 takes 16)");
			SelfTestCheck(TypeRules.Family("float4") == .Vector && TypeRules.Family("int32x4") == .Vector && TypeRules.Family("bool4") == .Vector &&
				TypeRules.Family("Vector<float,4>") == .Vector && TypeRules.Family("float") == .Float && TypeRules.Family("int32") == .Int && TypeRules.Family("bool") == .Bool &&
				Language.Types.Family("float4") == .Vector,
				"vector: the vector types are the Vector family (the type system's answer too)");
			let vc = Theme.TypeColor("float4");
			SelfTestCheck(vc == Theme.VectorPin && vc != Theme.FloatPin && vc != Theme.IntPin && vc != Theme.StructPin && Theme.TypeColor("int32x4") == vc &&
				Theme.ValueColor("float4") == Theme.FloatPin && Theme.ValueColor("int32x4") == Theme.IntPin && Theme.ValueColor("bool4") == Theme.BoolPin,
				"vector: a vector pin is drawn in the vector colour (not float, int or struct), its lane bars in the element's colour");
			SelfTestCheck(TypeRules.CanConvert("float4", "float4") == .Exact && TypeRules.CanConvert("Vector<float,4>", "float4") == .Exact &&
				TypeRules.CanConvert("float", "float4") == .Refused && TypeRules.CanConvert("float4", "float") == .Refused &&
				TypeRules.CanConvert("float4", "int32x4") == .Refused && TypeRules.CanConvert("float4", "double4") == .Refused &&
				TypeRules.CanConvert("float4", "T") == .Unchecked && TypeRules.CanConvert("float4", "Object") == .Implicit &&
				Language.Types.CanConvert("int", "float4", null) == .Refused,
				"vector: no implicit conversions to, from or between vectors (Cast and Make do it), generic pins take them");
			why.Clear();
			TypeRules.CanConvert("float", "float4", why);
			SelfTestCheck(why.Contains("Make float4"), scope $"vector: wiring a float into a float4 says how: {why}");
			// Literals on vector pins.
			List<String> lanes = scope .();
			defer { ClearAndDeleteItems!(lanes); }
			let split4 = PinValue.SplitLanes("float4", "1,2,3,4", lanes) && lanes.Count == 4 && lanes[3] == "4";
			ClearAndDeleteItems!(lanes);
			let splat = PinValue.SplitLanes("float4", "2.5", lanes) && lanes.Count == 4 && lanes[0] == "2.5" && lanes[3] == "2.5";
			ClearAndDeleteItems!(lanes);
			SelfTestCheck(split4 && splat && !PinValue.SplitLanes("float4", "1,2", null) && !PinValue.SplitLanes("float4", "1, 2, 3, 4", null) &&
				PinValue.SplitLanes("bool4", "true,false,true,true", null) && !PinValue.SplitLanes("bool4", "1,0,1,1", null) && !PinValue.SplitLanes("float4", "a,b,c,d", null),
				"vector: a literal is one token of N lanes or one value to splat (true / false for a mask)");
			String lit = scope .();
			why.Clear();
			let wrote = PinValue.Write(.Vector, "float4", "1, 2, 3, 4", false, lit, why);
			String lit2 = scope .();
			let refused = !PinValue.Write(.Vector, "float4", "1, 2", false, lit2, why);
			lanes.Add(new String("0"));
			lanes.Add(new String("0"));
			lanes.Add(new String("0"));
			String joined = scope .();
			PinValue.JoinLanes(lanes, joined);
			SelfTestCheck(wrote && lit == "1,2,3,4" && refused && why.Contains("float4") && joined == "0",
				scope $"vector: typed lanes are written as one token, two lanes for a float4 are refused, equal lanes write one splat value: {lit} / {why}");
			SelfTestCheck(PinValue.KindOf("float4", "", "v", Language.Types) == .Vector && PinValue.KindOf("float8", "1", "v", Language.Types) == .Vector &&
				PinValue.KindOf("float4", "Up * 2", "v", Language.Types) == .Custom && PinValueEditor.Handles(.Vector),
				"vector: an unwired vector input shows lane fields (an expression shows read-only)");
		}

		void SelfTestVectorNodes()
		{
			Graph g = scope .();
			g.Language = Language;
			let make = NodeFactory.Make(g, "float4");
			bool lanesOk = make.Inputs.Count == 4 && make.Inputs[0].Name == "x" && make.Inputs[3].Name == "w" && make.Inputs[1].TypeName == "float" &&
				make.FindOutput("value")?.TypeName == "float4";
			let make8 = NodeFactory.Make(g, "float8");
			lanesOk &= make8.FindInput("lane0") != null && make8.FindInput("lane7") != null && make8.FindInput("x") == null;
			let brk = NodeFactory.BreakStruct(g, "int32x4");
			lanesOk &= brk.FindOutput("x")?.TypeName == "int32" && brk.FindOutput("w") != null && brk.FindInput("value")?.TypeName == "int32x4";
			// The Node menu's Make row names the lanes too: no pin twice.
			let make2 = NodeFactory.Make(g, "float2", StringView[?]("x", "y"), StringView[?]("float", "float"));
			lanesOk &= make2.Inputs.Count == 2;
			String title = scope .();
			brk.GetTitle(title);
			SelfTestCheck(lanesOk && title == "Break int32x4", "vector: Make / Break of a vector have its lanes (x y z w; lane0 ... above 4 lanes) typed by the element");

			let swz = NodeFactory.Swizzle(g, "zyx");
			let shf = NodeFactory.Shuffle(g);
			title.Clear();
			swz.GetTitle(title);
			SelfTestCheck(title == "Swizzle .zyx" && shf.GetSetting("mask") == "0 4 1 5" && swz.FindInput("value") != null && shf.FindInput("b") != null &&
				NodeKinds.Word(.Swizzle) == "Swizzle" && NodeKinds.Parse("Shuffle", false) == .Shuffle && NodeKinds.IsValueKind(.Swizzle),
				"vector: Swizzle (value -> result, set lanes) and Shuffle (a, b -> result, set mask) nodes");
			g.Connect(make.FindOutput("value"), swz.FindInput("value"));
			let r1 = scope String(swz.FindOutput("result").TypeName);
			swz.SetSetting("lanes", "x");
			VectorNodes.Sync(g, swz);
			let r2 = scope String(swz.FindOutput("result").TypeName);
			swz.SetSetting("lanes", "xyzw");
			VectorNodes.Sync(g, swz);
			let r3 = scope String(swz.FindOutput("result").TypeName);
			g.Connect(make.FindOutput("value"), shf.FindInput("a"));
			let r4 = scope String(shf.FindOutput("result").TypeName);
			shf.SetSetting("mask", "0 1 2");
			VectorNodes.Sync(g, shf);
			let r5 = scope String(shf.FindOutput("result").TypeName);
			SelfTestCheck(r1 == "float3" && r2 == "float" && r3 == "float4" && r4 == "float4" && r5 == "float3",
				scope $"vector: the result follows the input and the setting (.zyx {r1}, .x {r2}, .xyzw {r3}; mask 0 4 1 5 {r4}, 0 1 2 {r5})");
			// The chain follows a change upstream: a Swizzle fed by a Swizzle.
			let swz2 = NodeFactory.Swizzle(g, "xy");
			g.Connect(swz.FindOutput("result"), swz2.FindInput("value"));
			let chained = scope String(swz2.FindOutput("result").TypeName);
			g.Disconnect(g.FindLinkTo(swz.FindInput("value")));
			SelfTestCheck(chained == "float2" && swz.FindOutput("result").TypeName.IsEmpty && swz2.FindOutput("result").TypeName.IsEmpty,
				"vector: a Swizzle after a Swizzle follows it; unwired, both lose their type");
			// T2301: a letter beyond the input's lanes.
			let make3 = NodeFactory.Make(g, "float3");
			g.Connect(make3.FindOutput("value"), swz.FindInput("value"));
			swz.SetSetting("lanes", "zyw");
			VectorNodes.Sync(g, swz);
			shf.SetSetting("mask", "0 9");
			GraphValidator.Validate(g);
			bool t2301 = false;
			bool shuffleBad = false;
			for (let e in g.Errors)
			{
				if (e.NodeId == swz.Id && e.Message.Contains("T2301") && e.Message.Contains("'w'"))
					t2301 = true;
				if (e.NodeId == shf.Id && e.Message.Contains("T2301"))
					shuffleBad = true;
			}
			String why = scope .();
			SelfTestCheck(t2301 && shuffleBad && swz.FindOutput("result").TypeName.IsEmpty && !VectorNodes.CheckSwizzle("xq", 4, why) && !VectorNodes.CheckSwizzle("xyzwx", 4, why) &&
				VectorNodes.CheckSwizzle("wwww", 4, why) && !VectorNodes.CheckShuffle("0 1 2 3 4", 4, why),
				"vector: T2301 on the node for .w of a float3 and a mask lane beyond a and b; other letters, five letters and a 5-lane mask refused");
			// Operators take vectors: element-wise, a comparison gives a mask, && is T2300.
			let mul = NodeFactory.Operator(g, "*");
			let lt = NodeFactory.Operator(g, "<");
			let and = NodeFactory.Operator(g, "&&");
			g.Connect(make.FindOutput("value"), mul.FindInput("a"));
			mul.FindInput("b").Default.Set("2");
			g.Connect(make.FindOutput("value"), lt.FindInput("b"));
			g.Connect(lt.FindOutput("result"), and.FindInput("a"));
			let mulT = scope String(mul.FindOutput("result").TypeName);
			let ltT = scope String(lt.FindOutput("result").TypeName);
			GraphValidator.Validate(g);
			bool t2300 = false;
			for (let e in g.Errors)
				if (e.NodeId == and.Id && e.Message.Contains("T2300"))
					t2300 = true;
			g.Disconnect(g.FindLinkTo(lt.FindInput("b")));
			SelfTestCheck(mulT == "float4" && ltT == "bool4" && t2300 && lt.FindOutput("result").TypeName == "bool",
				scope $"vector: an Operator with a vector is element-wise (* {mulT}, < {ltT}); && on masks is T2300; unwired, < gives a bool again");
			// A mask feeds a Select's condition; a float does not go into a float4 pin.
			let sel = NodeFactory.Select(g);
			let maskOut = NodeFactory.Make(g, "bool4").FindOutput("value");
			let brk4 = NodeFactory.BreakStruct(g, "float4");
			let brk4b = NodeFactory.BreakStruct(g, "float4");
			SelfTestCheck(Graph.CanConnectTyped(Language, maskOut, sel.FindInput("condition")) && Graph.CanConnectTyped(Language, brk4.FindOutput("x"), make8.FindInput("lane0")) &&
				!Graph.CanConnectTyped(Language, brk4.FindOutput("x"), brk4b.FindInput("value")) &&
				!Graph.CanConnectTyped(Language, make3.FindOutput("value"), brk4.FindInput("value")),
				"vector: a mask is a Select's condition; a lane takes a float; a float and a float3 are refused on a float4 pin");
		}

		void SelfTestVectorFormat()
		{
			// The file reads and writes back byte for byte.
			String text = scope .(cVectorDemo);
			text.Replace("\r\n", "\n");
			TypeDocument doc = scope .(Language);
			String err = scope .();
			let read = Language.Codec.Read(text, doc, err);
			String back = scope .();
			if (read)
				doc.WriteText(back, err);
			SelfTestCheck(read && back == text, scope $"vector: a type file with vector fields, inputs and nodes reads and writes back byte for byte {err}");
			if (!read)
				return;
			if (back != text)
				Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] written:\n{back}");
			let fd = doc.FindMember("mDir");
			let sheet = doc.FindSheetByName("Scaled");
			SelfTestCheck(fd != null && fd.Type != null && fd.Type.Kind == .Vector && sheet != null, "vector: the field's type is a vector");
			if (sheet == null)
				return;
			let g = sheet.Graph;
			let b2 = g.FindNodeByKey("b2");
			let b3 = g.FindNodeByKey("b3");
			let b4 = g.FindNodeByKey("b4");
			let b5 = g.FindNodeByKey("b5");
			let b7 = g.FindNodeByKey("b7");
			let b8 = g.FindNodeByKey("b8");
			bool shapes = b2 != null && b2.FindInput("z") != null && b2.FindInput("w")?.Default == "1" && b2.FindInput("x")?.TypeName == "float" &&
				b3 != null && b3.FindOutput("w") != null && b4 != null && b4.FindOutput("result")?.TypeName == "float3" &&
				b5 != null && b5.FindOutput("result")?.TypeName == "float4" && b7?.FindOutput("result")?.TypeName == "float4" && b8?.FindOutput("result")?.TypeName == "bool4";
			SelfTestCheck(shapes, "vector: read back, the nodes have their lanes and result types (Swizzle .zyx of a float4: float3; float4 * 2: float4; <: bool4)");
			// The long form reads and is written short.
			String longText = scope .(text);
			longText.Replace("field mDir float4", "field mDir Vector<float,4>");
			TypeDocument doc2 = scope .(Language);
			String back2 = scope .();
			SelfTestCheck(Language.Codec.Read(longText, doc2, err) && doc2.WriteText(back2, err) && back2 == text, "vector: field mDir Vector<float,4> reads and is written float4");

			// The compiler's front end binds the vector nodes (no problem on Break, Swizzle, Shuffle or the
			// Operators) and reports the Make's unwired lane z.
			LanguageContext ctx = scope .();
			List<TypeDocument> open = scope .();
			defer { ClearAndDeleteItems!(open); }
			TypeDocument fdoc = new .(ctx);
			open.Add(fdoc);
			if (!ctx.Codec.Read(text, fdoc, err))
			{
				SelfTestCheck(false, scope $"vector: the front end's copy reads: {err}");
				return;
			}
			FrontEndServices fe = scope .(ctx, open);
			let fs = fdoc.FindSheetByName("Scaled");
			GraphValidator.Validate(fs.Graph);
			let fmake = fs.Graph.FindNodeByKey("b2");
			bool onVectorNode = false;
			bool onMake = false;
			int count = 0;
			for (let e in fs.Graph.Errors)
			{
				count++;
				if (e.NodeId == fmake.Id)
					onMake = true;
				else
					for (let k in StringView[?]("b3", "b4", "b5", "b7", "b8"))
						if (fs.Graph.FindNodeByKey(k)?.Id == e.NodeId)
							onVectorNode = true;
				Notify.Log(.Info, "SelfTest", scope $"[SELFTEST]      {e.Message}");
			}
			SelfTestCheck(onMake && !onVectorNode, scope $"vector: the front end binds the vector nodes and reports the Make's unwired lane ({count} problems)");
			// What the field shows: the compiler's answer or its message, nothing breaks.
			String why = scope .();
			let accepted = fe.Rules.CheckExpression("v.zyx * 2 + float4(a, b, c, 1)", why);
			List<String> names = scope .();
			defer { ClearAndDeleteItems!(names); }
			let parsed = MathExpr.Parse("v.zyx * 2 + float4(a, b, c, 1)", names, scope String());
			SelfTestCheck((accepted || !why.IsEmpty) && parsed && names.Count == 4 && names[0] == "v" && names[1] == "a",
				scope $"vector: a Math Expression with a swizzle and a constructor: the field's check {(accepted ? "accepts it" : "says why not")}, its inputs are v, a, b, c {why}");
		}

		/// On the open Sheet (TakeDamage of the Player copy): vector nodes added, the Node menu from their pins,
		/// Properties' setters, then everything undone.
		void SelfTestVectorEdit(int phase)
		{
			let mg = CurrentMethod;
			if (mg == null)
			{
				SelfTestCheck(false, "vector: no Sheet to edit");
				return;
			}
			switch (phase)
			{
			case 0:
				mVecNodesBefore = mg.Graph.Nodes.Count;
				BeginEdit();
				let make = NodeFactory.Make(mg.Graph, "float4");
				make.X = 900;
				make.Y = 700;
				make.HasPos = true;
				let swz = NodeFactory.Swizzle(mg.Graph, "zyx");
				swz.X = 1150;
				swz.Y = 700;
				swz.HasPos = true;
				let brk = NodeFactory.BreakStruct(mg.Graph, "float4");
				brk.X = 1150;
				brk.Y = 850;
				brk.HasPos = true;
				mg.Graph.Connect(make.FindOutput("value"), swz.FindInput("value"));
				CommitCurrent();
				mVecMake.Set(make.Key);
				mVecSwizzle.Set(swz.Key);
				mVecBreak.Set(brk.Key);
				CurrentTab?.SelectOnly(swz.Id); // Properties draws its rows next frame
			case 1:
				let g = mg.Graph;
				let make = g.FindNodeByKey(mVecMake);
				let swz = g.FindNodeByKey(mVecSwizzle);
				let brk = g.FindNodeByKey(mVecBreak);
				if (make == null || swz == null || brk == null)
				{
					SelfTestCheck(false, "vector: the vector nodes are in the Sheet");
					return;
				}
				// The Node menu from the float4 output: its rows first, then the operators.
				List<NodeItem> rows = scope .();
				defer { ClearAndDeleteItems!(rows); }
				mNodeMenu.ListFor(mg, make.FindOutput("value").Id, "", rows);
				int firstOther = -1;
				for (let r in rows)
					if (r.Kind != .VectorNode)
					{
						firstOther = @r.Index;
						break;
					}
				bool Has(StringView label)
				{
					for (let r in rows)
						if (r.Kind == .VectorNode && r.Label == label)
							return true;
					return false;
				}
				bool genericStandIn = false;
				for (let r in rows)
					if (r.CatalogId >= 0 && mNodeMenu.Catalog.Spec(r.CatalogId).StandIn)
						genericStandIn = true;
				SelfTestCheck(rows.Count > 0 && rows[0].Kind == .VectorNode && rows[0].Label == "Break float4" && Has("Swizzle .wzyx") && Has("Shuffle 0 4 1 5") &&
					Has("Get Lane") && Has("Set Lane") && Has("Reduce Add") && Has("Reduce Min") && Has("Reduce Max") && !Has("Any Lane") && !genericStandIn &&
					firstOther > 0 && (rows[firstOther].Kind == .Operator || rows[firstOther].Kind == .Math),
					scope $"vector: from a float4 output the menu lists its rows first (Break, Swizzle, Shuffle, lanes, reductions; {firstOther} rows), then the operators ({(firstOther >= 0 ? rows[firstOther].Label : "")})");
				// The compiler's catalogue rows (VectorCatalogSource) replace every Core.Vector stand-in: none is left.
				{
					int sourceCalls = 0;
					int standInCalls = 0;
					for (let s in mNodeMenu.Catalog.Specs)
						if (s.CallName.StartsWith("Core.Vector."))
						{
							if (s.StandIn)
								standInCalls++;
							else
								sourceCalls++;
						}
					SelfTestCheck(sourceCalls > 0 && standInCalls == 0,
						scope $"vector: the compiler's Core.Vector rows ({sourceCalls}) replace the menu's stand-ins ({standInCalls} left)");
				}
				// Nodes made from those rows.
				Graph scratch = scope .();
				scratch.Language = Language;
				bool made = true;
				for (let r in rows)
				{
					if (r.Kind != .VectorNode)
						continue;
					let n = mNodeMenu.CreateNode(mg, scratch, r, false, true);
					made &= n != null;
					if (n != null && r.Label == "Get Lane")
						made &= n.Kind == .Call && n.Text == "Core.Vector.GetLane" && n.FindInput("v")?.TypeName == "float4" && n.FindInput("i")?.TypeName == "int" &&
							n.FindOutput("result")?.TypeName == "float";
					if (n != null && r.Label == "Set Lane")
						made &= n.FindInput("s")?.TypeName == "float" && n.FindOutput("result")?.TypeName == "float4";
					if (n != null && r.Label.StartsWith("Swizzle"))
						made &= n.Kind == .Swizzle && n.GetSetting("lanes") == "wzyx";
				}
				SelfTestCheck(made, "vector: the rows make their nodes (Get Lane a value Call of Core.Vector.GetLane: v float4, i int -> float)");
				// Into a float4 input: Make and Splat.
				ClearAndDeleteItems!(rows);
				mNodeMenu.ListFor(mg, brk.FindInput("value").Id, "", rows);
				SelfTestCheck(rows.Count > 1 && rows[0].Label == "Make float4" && rows[1].Label == "Splat float4",
					scope $"vector: into a float4 input the menu lists Make float4 and Splat float4 first ({(rows.Count > 0 ? rows[0].Label : "")})");
				let splatRow = (rows.Count > 1) ? rows[1] : null;
				let splat = (splatRow != null) ? mNodeMenu.CreateNode(mg, scratch, splatRow, false, true) : null;
				String expr = scope .();
				if (splat != null)
					GraphPanel.MathText(splat, expr);
				SelfTestCheck(splat != null && splat.Kind == .Math && expr == "float4(x)" && splat.FindInput("x")?.TypeName == "float" && splat.FindOutput("result")?.TypeName == "float4",
					scope $"vector: Splat float4 is the Math Expression float4(x) with a float input ({expr})");
				// The catalogue's stand-ins, searched without a pin; a source row replaces one.
				ClearAndDeleteItems!(rows);
				mNodeMenu.ListFor(mg, 0, "swizzle", rows);
				bool swzRow = false;
				for (let r in rows)
					if (r.CatalogId >= 0 && r.Label == "Swizzle")
						swzRow = true;
				List<NodeSpec> specs = scope .();
				defer { ClearAndDeleteItems!(specs); }
				let mine = new NodeSpec();
				mine.CallName.Set("Core.Vector.GetLane");
				mine.Label.Set("GetLane");
				specs.Add(mine);
				VectorCatalog.AddStandIns(specs);
				int getLane = 0;
				int standIns = 0;
				for (let s in specs)
				{
					if (s.CallName == "Core.Vector.GetLane")
						getLane++;
					if (s.StandIn)
						standIns++;
				}
				SelfTestCheck(swzRow && getLane == 1 && !mine.StandIn && standIns > 100,
					scope $"vector: the menu's stand-in rows ({standIns}) are found by search; a source row with the same key replaces its stand-in");
				SelfTestCheck(CanSplitPin(mg, make.FindOutput("value")), "vector: Split Pin is offered on a vector pin (its lanes)");
				// Properties' setters: the lanes, a refused letter, the vector type of a Make.
				let logBefore = Notify.Version;
				let ok1 = SetVectorSetting(g, swz, "lanes", "xy", 4);
				let ok2 = !SetVectorSetting(g, swz, "lanes", "xq", 4);
				let sw2 = scope String(swz.FindOutput("result").TypeName);
				SelfTestCheck(ok1 && ok2 && sw2 == "float2" && Notify.Version != logBefore, scope $"vector: Properties sets the lanes (.xy: {sw2}) and refuses a letter that is no lane");
			case 2:
				let g = mg.Graph;
				let make = g.FindNodeByKey(mVecMake);
				let swz = g.FindNodeByKey(mVecSwizzle);
				let ok = make != null && SetVectorType(g, make, "float2");
				SelfTestCheck(ok && make.FindInput("z") == null && make.FindInput("y") != null && make.FindOutput("value")?.TypeName == "float2" &&
					swz != null && swz.FindOutput("result")?.TypeName == "float2" && g.FindLinkTo(swz.FindInput("value")) != null,
					scope $"vector: the Make's vector type changes its lanes (float2: x y) and the Swizzle after it follows (ok {ok}, value {make?.FindOutput("value")?.TypeName}, z {make?.FindInput("z") != null}, swizzle {swz?.FindOutput("result")?.TypeName}, wired {swz != null && g.FindLinkTo(swz.FindInput("value")) != null})");
				// Undo the three edits (the nodes, the lanes, the type): the Sheet is as it was.
				for (int i < 3)
					if (EditDoc.CanUndo)
						EditDoc.Undo();
				SelfTestCheck(CurrentMethod.Graph.Nodes.Count == mVecNodesBefore && CurrentMethod.Graph.FindNodeByKey(mVecMake) == null,
					scope $"vector: undo takes the vector edits back ({CurrentMethod.Graph.Nodes.Count} nodes, {mVecNodesBefore} before)");
			}
		}
	}
}
#endif
