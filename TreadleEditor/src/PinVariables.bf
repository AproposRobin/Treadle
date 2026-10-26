using System;
using System.Collections;
using Treadle.Document;
using Treadle.Graph;

namespace Treadle.Editor
{
	/// Variables made from pins (the pin menu's Make variable / Make local variable), the ref pin's
	/// Fix (Make local variable), and the L hotkey. Locals are model edits on the Sheet; member variables are fields
	/// of the document's type (MakeMemberForPin).
	extension EditorApp
	{
		/// The type a variable made from `pin` gets; false with `outWhy` when none can be made.
		public bool PinVariableType(Sheet mg, Pin pin, bool member, String outType, String outWhy)
		{
			if (pin.Kind != .Value)
			{
				outWhy.Set("Only value pins make variables");
				return false;
			}
			if (member && (mg == null || mg.Doc == null || (mg.Doc.Header.Kind != .Class && mg.Doc.Header.Kind != .Struct)))
			{
				outWhy.Set("Only a class or a struct holds variables");
				return false;
			}
			if (pin.TypeName.IsEmpty || pin.TypeName == "void")
			{
				outWhy.Set("The pin has no type yet: wire it first");
				return false;
			}
			outType.Set(pin.TypeName);
			return true;
		}

		/// The pin menu's Make variable: a new field of the Sheet's type (Outline > VARIABLES), named
		/// after the pin (made unique) and typed like it, static when the Sheet is. One undo step of
		/// the document; the caller merges the Get / Set it places into that step.
		public bool MakeMemberForPin(Sheet mg, StringView baseName, StringView type, String outName)
		{
			if (mg == null || mg.Doc == null)
				return false;
			if (Doc != mg.Doc)
				Doc = mg.Doc;
			let m = AddField(baseName, type);
			if (m == null)
				return false;
			m.Static = mg.Graph.StaticContext;
			outName.Set(m.Name);
			return true;
		}

		public static void UniqueLocalName(Sheet mg, StringView baseName, String outName) => VariableActions.UniqueName(mg.Graph, baseName, outName);

		/// L: a new Local of the front Sheet (untyped until its type is set in Properties), its Name in edit.
		public void AddLocalFromKey(GraphTab tab, Sheet mg)
		{
			if (mg == null || !CheckWritable())
				return;
			String name = scope .();
			UniqueLocalName(mg, "newVar", name);
			BeginEdit();
			NodeFactory.AddLocal(mg.Graph, name, "");
			CommitCurrent();
			SetStatus(scope $"Added the Local {name}", .Info, false);
			// Its page in Properties with the Name field in edit, as a new variable of the Outline.
			mSelLocalActive = true;
			mSelLocalName.Set(name);
			SelectOutline(.Local);
			FocusNameField();
		}

		/// The `ref` input of `n` that needs a variable (T2231): wired from a value that is not a
		/// variable, or holding a literal. Null when there is none, or when `n` does not run in the
		/// flow (a Local's Set needs a place before it): the problem strip then offers no Fix.
		public Pin RefPinNeedingLocal(TypeDocument doc, Graph g, Node n)
		{
			if (g == null || n == null || g.Member == null || n.ExecIn == null || g.FindLinkTo(n.ExecIn) == null)
				return null;
			for (let p in n.Inputs)
			{
				if (!p.IsRefArg)
					continue;
				let l = g.FindLinkTo(p);
				if (l != null)
				{
					if (!IsVariableGet(doc, l.From.Owner))
						return p;
				}
				else if (!p.Default.IsEmpty)
					return p;
			}
			return null;
		}

		/// A Get of a local, an input or a field (what a `ref` input takes); a property's Get is a call.
		bool IsVariableGet(TypeDocument doc, Node src)
		{
			if (src.Kind != .Get)
				return false;
			StringView t = src.Text;
			if (t.StartsWith("local:") || t.StartsWith("param:"))
				return true;
			let dot = t.LastIndexOf('.');
			if (dot <= 0)
				return true;
			let owner = t.Substring(0, dot);
			let name = t.Substring(dot + 1);
			if (owner == "this")
				return doc?.FindMember(name)?.Kind != .Property;
			let pt = ProjectTypes.Find(owner);
			if (pt != null)
				for (let m in pt.Members)
					if (m.Name == name)
						return m.Kind != .Property;
			return true;
		}

		/// The ref pin's Fix (Make local variable): a new Local of the value's type, a Set of it fed by
		/// the value right before the node in the flow, and a Get of the Local wired into `pin` (a `ref`
		/// input takes a variable). `merge`: part of the caller's undo step (else one of its own).
		/// False (with a status line unless `quiet`) when the pin does not need one or the node is not
		/// in the flow.
		public bool StoreRefInLocal(Sheet mg, Pin pinIn, bool quiet, bool merge)
		{
			if (mg == null || pinIn == null)
				return false;
			let g = mg.Graph;
			let call = pinIn.Owner;
			if (RefPinNeedingLocal(mg.Doc, g, call) != pinIn)
			{
				if (!quiet)
					SetStatus("Make local variable: the input is not a ref input fed by a value, or its node is not in the flow", .Info, false);
				return false;
			}
			let link = g.FindLinkTo(pinIn);
			Pin src = link?.From;
			String type = scope .();
			type.Set((src != null && !src.TypeName.IsEmpty && src.TypeName != "void") ? src.TypeName : pinIn.TypeName);
			if (type.IsEmpty || type == "void")
			{
				if (!quiet)
					SetStatus("Make local variable: the value has no type yet", .Info, false);
				return false;
			}
			if (!merge)
			{
				if (!CheckWritable())
					return false;
				mg.Doc.PushUndo();
			}
			String baseName = scope .();
			VariableActions.VariableBase(pinIn, baseName);
			String name = scope .();
			UniqueLocalName(mg, baseName, name);
			String init = scope .();
			NodeFactory.ReturnDefault(Language, type, init);
			NodeFactory.AddLocal(g, name, type, init);
			let set = NodeFactory.Set(g, name, type);
			let value = set.FindInput("value");
			if (src != null)
				g.Connect(src, value);
			else
			{
				value.Default.Set(pinIn.Default);
				pinIn.Default.Clear();
			}
			// Whatever ran into the node runs into the Set; the Set runs into the node.
			List<Pin> before = scope .();
			for (let l in g.Links)
				if (l.To == call.ExecIn)
					before.Add(l.From);
			for (let from in before)
				g.Connect(from, set.ExecIn);
			g.Connect(set.Then, call.ExecIn);
			let get = NodeFactory.Get(g, name, type);
			g.Connect(get.Result, pinIn);
			set.X = Canvas.Snap(call.X - 40);
			set.Y = Canvas.Snap(call.Y - 160);
			set.HasPos = true;
			get.X = Canvas.Snap(call.X - 240);
			get.Y = Canvas.Snap(call.Y + 40);
			get.HasPos = true;
			if (!merge)
				CommitCurrent();
			let label = pinIn.Label.IsEmpty ? (StringView)pinIn.Name : (StringView)pinIn.Label;
			SetStatus(scope $"Made the local variable {name}: {label} is passed by ref, so it takes a variable", .Info, false);
			return true;
		}
	}
}
