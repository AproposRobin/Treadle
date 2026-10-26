using System;
using System.Collections;
using Treadle.Document;
using Treadle.Graph;

namespace Treadle.Editor
{
	/// Editing a Lambda node and its Sheet together (Language.md 4.2): the type a delegate pin wants,
	/// a Lambda placed from such a pin (type, inputs, Allocation, Sheet, wires), the inputs written
	/// to `set inputs` and the Sheet's Entry / Return following them, and the captures' by-reference
	/// lines. Every change runs inside the caller's undo step (BeginEdit ... CommitCurrent).
	extension EditorApp
	{
		/// What a delegate or function pointer type stands for: `delegate:R(A)` / `function:R(A)`
		/// written out, or a type the front end resolves to one (a delegate type of the project or
		/// the core library, a C typedef of a function pointer). False when it is not one.
		public bool ResolveDelegateType(StringView typeText, LambdaSignature outSig)
		{
			outSig.Clear();
			var text = typeText;
			text.Trim();
			if (text.IsEmpty)
				return false;
			let tr = Treadle.Model.TypeRef.Parse(text);
			defer delete tr;
			if (tr.Kind == .Function || tr.Kind == .Delegate)
			{
				outSig.IsFunction = tr.Kind == .Function;
				if (tr.Element != null)
					tr.Element.ToString(outSig.Returns);
				else
					outSig.Returns.Set("void");
				if (tr.Args != null)
					for (let a in tr.Args)
						outSig.Params.Add(a.ToString(.. new String()));
				return true;
			}
			let types = FrontEnd?.Types;
			if (types == null)
				return false;
			var kt = types.Lookup(text);
			if (kt == null)
				return false;
			if (kt.Kind == .Named && kt.Sym != null && kt.Sym.Kind == .Delegate)
			{
				let comp = FrontEnd.Last;
				kt = (comp != null) ? comp.AliasTarget(kt.Sym) : null;
				if (kt == null)
					return false;
			}
			if (kt.Kind != .Delegate && kt.Kind != .Function)
				return false;
			outSig.IsFunction = kt.Kind == .Function;
			if (kt.Element != null)
				outSig.Returns.Set(kt.Element.Name);
			else
				outSig.Returns.Set("void");
			for (let a in kt.Args)
				outSig.Params.Add(new String(a.Name));
			return true;
		}

		/// The delegate types a Lambda can give, by full name: the project's (open documents
		/// first) and those the front end knows (the core library's, a dependency's).
		public void DelegateTypesInScope(List<String> outNames)
		{
			RefreshProjectTypes();
			for (let t in ProjectTypes.Types)
				if (t.Kind == .Delegate && !outNames.ContainsAlt(t.FullName))
					outNames.Add(new String(t.FullName));
			let comp = FrontEnd?.Last;
			if (comp != null)
				for (let s in comp.Table.Types)
					if (s.Kind == .Delegate && !s.IsGeneric && !outNames.ContainsAlt(s.FullName))
						outNames.Add(new String(s.FullName));
			outNames.Sort(scope (a, b) => a.CompareTo(b, true));
		}

		/// The one delegate type in scope whose signature is `sig` into `outName` (left as it is
		/// when there is none, or several).
		void NamedDelegateFor(LambdaSignature sig, String outName)
		{
			String want = scope .();
			sig.ToTypeText(want);
			List<String> names = scope .();
			defer { ClearAndDeleteItems!(names); }
			DelegateTypesInScope(names);
			String found = scope .();
			int count = 0;
			LambdaSignature other = scope .();
			for (let name in names)
			{
				if (!ResolveDelegateType(name, other) || other.IsFunction)
					continue;
				if (other.ToTypeText(.. scope String()) == want)
				{
					found.Set(name);
					count++;
				}
			}
			if (count == 1)
				outName.Set(found);
		}

		/// A fresh input name: a, b, c, ... (p26 and on after z).
		static void LambdaInputName(int i, String outName)
		{
			if (i < 26)
				outName.Append((char8)('a' + i));
			else
				outName.AppendF("p{}", i);
		}

		/// The names of a Lambda's inputs: `set inputs`, cut or filled up (with fresh names) to
		/// `count` (-1: as written).
		public static void LambdaInputNames(Node n, int count, List<String> outNames)
		{
			for (var w in n.GetSetting("inputs").Split(' '))
			{
				w.Trim();
				if (!w.IsEmpty && (count < 0 || outNames.Count < count))
					outNames.Add(new String(w));
			}
			for (int i = outNames.Count; outNames.Count < count; i++)
			{
				String name = scope .();
				LambdaInputName(i, name);
				if (!outNames.ContainsAlt(name))
					outNames.Add(new String(name));
			}
		}

		/// The type of the Lambda and what it stands for (false: no type, or not a delegate).
		public bool LambdaSignatureOf(Node n, LambdaSignature outSig) => ResolveDelegateType(n.GetSetting("type"), outSig);

		/// "int(int a, int b)" for the node's subtitle ("" when its type is not known yet).
		public void LambdaSubtitle(Node n, String outText)
		{
			LambdaSignature sig = scope .();
			if (!LambdaSignatureOf(n, sig))
				return;
			List<String> names = scope .();
			defer { ClearAndDeleteItems!(names); }
			LambdaInputNames(n, sig.Params.Count, names);
			List<StringView> views = scope .();
			for (let s in names)
				views.Add(s);
			sig.ToText(outText, views);
		}

		/// The Sheet that holds `g` (null when no open document has it).
		public Sheet SheetOfGraph(Graph g)
		{
			for (let d in mDocs)
				for (let s in d.Sheets)
					if (s.IsBuilt && s.Graph == g)
						return s;
			if (Doc != null)
				for (let s in Doc.Sheets)
					if (s.IsBuilt && s.Graph == g)
						return s;
			return null;
		}

		/// What the front end found for a Lambda's Sheet (its captures, its inputs), from the last
		/// compilation; null before one, or when it does not have the Sheet.
		public Treadle.Compiler.SheetResult LambdaResult(Sheet owner, Node n)
		{
			let comp = FrontEnd?.Last;
			if (comp == null || owner == null || n.Key.IsEmpty)
				return null;
			let ls = FindLambdaSheet(owner.Doc, owner, n.Key);
			return (ls != null) ? comp.ResultOf(ls) : null;
		}

		/// The Lambda's Sheet, made when it has none (inside the caller's undo step).
		public Sheet EnsureLambdaSheet(Sheet owner, Node n)
		{
			if (n.Key.IsEmpty)
				KeyAssigner.Assign(owner.Graph);
			var ls = FindLambdaSheet(owner.Doc, owner, n.Key);
			if (ls == null)
			{
				ls = owner.Doc.NewSheet(owner.Member, .Lambda, n.Key);
				owner.Doc.Modified = true;
				owner.Doc.Version++;
			}
			return ls;
		}

		/// The node's inputs (`set inputs`) and its Sheet's Entry and Return pins made to follow its
		/// type: as many inputs as the signature has (names kept, fresh ones added), typed by it.
		/// `renameFrom` -> `renameTo`: that input was renamed (its wires stay).
		public void ApplyLambdaSignature(Sheet owner, Node n, StringView renameFrom = default, StringView renameTo = default)
		{
			LambdaSignature sig = scope .();
			bool known = LambdaSignatureOf(n, sig);
			List<String> names = scope .();
			defer { ClearAndDeleteItems!(names); }
			LambdaInputNames(n, known ? sig.Params.Count : -1, names);
			List<StringView> nameViews = scope .();
			for (let s in names)
				nameViews.Add(s);
			NodeFactory.SetLambdaInputs(n, nameViews);
			let ls = FindLambdaSheet(owner.Doc, owner, n.Key);
			if (ls == null)
				return;
			List<StringView> typeViews = scope .();
			if (known)
				for (let t in sig.Params)
					typeViews.Add(t);
			owner.Doc.SyncLambdaPins(ls, nameViews, typeViews, known ? (StringView)sig.Returns : "", renameFrom, renameTo);
			if (!renameFrom.IsEmpty && !renameTo.IsEmpty)
			{
				// A Get / Set of the input by name follows the rename.
				String oldRef = scope $"param:{renameFrom}";
				for (let o in ls.Graph.Nodes)
					if ((o.Kind == .Get || o.Kind == .Set) && o.Text == oldRef)
						o.Text.Set(scope $"param:{renameTo}");
			}
		}

		/// Renames the input `index` of a Lambda: `set inputs`, the Entry pin (its wires stay) and
		/// the Sheet's Get / Set of it. Refused (the reason in `outWhy`) for a name that is not one
		/// or that another input has.
		public bool RenameLambdaInput(Sheet owner, Node n, int index, StringView newName, String outWhy)
		{
			var name = newName;
			name.Trim();
			List<String> inputs = scope .();
			defer { ClearAndDeleteItems!(inputs); }
			LambdaSignature sig = scope .();
			LambdaInputNames(n, LambdaSignatureOf(n, sig) ? sig.Params.Count : -1, inputs);
			if (index < 0 || index >= inputs.Count)
			{
				outWhy.Set("The Lambda has no such input");
				return false;
			}
			if (inputs[index] == name)
				return true;
			if (!IsIdentifier(name))
			{
				outWhy.AppendF("'{}' is not a name (letters, digits and _, not starting with a digit)", name);
				return false;
			}
			if (inputs.ContainsAlt(name))
			{
				outWhy.AppendF("The Lambda already has an input named {}", name);
				return false;
			}
			String old = scope .(inputs[index]);
			inputs[index].Set(name);
			List<StringView> views = scope .();
			for (let s in inputs)
				views.Add(s);
			NodeFactory.SetLambdaInputs(n, views);
			ApplyLambdaSignature(owner, n, old, name);
			return true;
		}

		/// A new Lambda Sheet of a signature with a result gets a Return wired after its Entry (a
		/// Blueprint function with outputs starts the same way).
		void SeedLambdaSheet(Sheet ls, LambdaSignature sig)
		{
			let g = ls.Graph;
			let entry = g.Entry;
			if (entry == null || sig.Returns.IsEmpty || sig.Returns == "void")
				return;
			for (let o in g.Nodes)
				if (o.Kind == .Return)
					return;
			if (!entry.HasPos)
			{
				entry.X = 0;
				entry.Y = 0;
				entry.HasPos = true;
			}
			let r = NodeFactory.Return(g, sig.Returns);
			r.X = entry.X + 480;
			r.Y = entry.Y;
			r.HasPos = true;
			if (entry.Then != null && r.ExecIn != null)
				g.Connect(entry.Then, r.ExecIn);
			KeyAssigner.Assign(g);
		}

		/// The Allocation a delegate Lambda starts with: Local when it is handed to a call (it lives
		/// as long as the call needs it), Construct (heap) otherwise, and Construct for the calls that
		/// keep the delegate after they return (Thread.Start, ThreadPool.Run: docs/Threads.md 2).
		static StringView DefaultLambdaAlloc(Graph g, Node n)
		{
			let v = n.FindOutput("value");
			if (v != null)
				for (let l in g.Links)
					if (l.From == v && (l.To.Owner.Kind == .Call || l.To.Owner.Kind == .Invoke))
						return OwnsDelegate(l.To.Owner) ? "construct" : "local";
			return "construct";
		}

		/// A Call that takes over the delegate it is given (it runs it later, on another thread).
		static bool OwnsDelegate(Node call)
		{
			if (call.Kind != .Call)
				return false;
			StringView s = call.Text;
			let paren = s.IndexOf('(');
			if (paren >= 0)
				s = s.Substring(0, paren);
			return s.EndsWith("Thread.Start") || s.EndsWith("ThreadPool.Run");
		}

		/// A Lambda placed from a delegate or function pointer input (the Node menu dragged from
		/// it, already wired to it): it gives the pin's type, takes its inputs, allocates as that
		/// needs, runs right before the node it feeds, and has its Sheet with the Entry and Return
		/// of the signature. False when the pin is not one.
		public bool SetupLambdaFromPin(Sheet owner, Node n, Pin ctx)
		{
			LambdaSignature sig = scope .();
			if (ctx == null || !ctx.IsInput || !ResolveDelegateType(ctx.TypeName, sig))
				return false;
			let g = owner.Graph;
			// A delegate pin reads as its signature (a delegate type is its signature, Language.md
			// 4.2): the Lambda names the delegate type of that signature when exactly one is in scope.
			String type = scope .(ctx.TypeName);
			if (!sig.IsFunction && type.StartsWith("delegate:"))
				NamedDelegateFor(sig, type);
			NodeFactory.SetLambdaType(g, n, type);
			if (!sig.IsFunction)
			{
				NodeFactory.SetLambdaAlloc(g, n, DefaultLambdaAlloc(g, n));
				ChainBefore(g, n, ctx.Owner);
			}
			let ls = EnsureLambdaSheet(owner, n);
			ApplyLambdaSignature(owner, n);
			SeedLambdaSheet(ls, sig);
			return true;
		}

		/// The Lambda's type set in Properties: Allocation as the type needs (none for a function
		/// pointer; a delegate keeps its own, else gets the default), inputs and Sheet pins follow.
		public void SetLambdaTypeFromProperties(Sheet owner, Node n, StringView type)
		{
			let g = owner.Graph;
			NodeFactory.SetLambdaType(g, n, type);
			LambdaSignature sig = scope .();
			let known = ResolveDelegateType(type, sig);
			if (known && sig.IsFunction)
				NodeFactory.SetLambdaAlloc(g, n, "");
			else if (known && !n.HasSetting("alloc"))
				NodeFactory.SetLambdaAlloc(g, n, DefaultLambdaAlloc(g, n));
			let ls = EnsureLambdaSheet(owner, n);
			ApplyLambdaSignature(owner, n);
			if (known)
				SeedLambdaSheet(ls, sig);
		}

		/// A flow Lambda feeding a flow node runs right before it: the wire into that node's `in`
		/// goes through the Lambda.
		static void ChainBefore(Graph g, Node lambda, Node consumer)
		{
			if (lambda.ExecIn == null || lambda.Then == null || consumer == null || consumer.ExecIn == null || consumer == lambda)
				return;
			if (g.IsLinked(lambda.ExecIn))
				return;
			let into = g.FindLinkTo(consumer.ExecIn);
			if (into == null)
				return;
			let from = into.From;
			g.Connect(from, lambda.ExecIn); // replaces the wire from `from` (a flow output has one)
			g.Connect(lambda.Then, consumer.ExecIn);
		}

		/// A Lambda inside a Lambda Sheet (`owner`) holds a variable of the function by reference
		/// only when the Lambda around it does too (Language.md 4.2; its own inputs always can):
		/// true, with the reason, when the last compilation has the outer one holding `name` by value.
		public bool NestedByValueWhy(Sheet owner, StringView name, String outWhy)
		{
			if (owner == null || owner.Role != .Lambda)
				return false;
			let outer = FrontEnd?.Last?.ResultOf(owner);
			if (outer == null || outer.FindLambdaParam(name) != null)
				return false;
			let held = outer.FindCapture(.Local, name) ?? outer.FindCapture(.Param, name);
			if (held == null || held.ByRef)
				return false;
			outWhy.Set(scope $"The Lambda around this one holds {name} by value: capture it by reference there first (a Local Lambda)");
			return true;
		}

		/// Writes how a Lambda holds a capture (`capture <name> by-ref`, or by value). Refused, with
		/// the reason in `outWhy`, when the Lambda may outlive the variable: by reference needs a
		/// Local Lambda (freed with its region, Language.md 4.2); `this` is always held by value.
		public bool SetLambdaCaptureByRef(Sheet owner, Node n, StringView name, bool byRef, String outWhy)
		{
			if (byRef)
			{
				if (NestedByValueWhy(owner, name, outWhy))
					return false;
				if (name == "this")
				{
					outWhy.Set("this is held by value: the Lambda keeps the object reference itself");
					return false;
				}
				let alloc = n.GetSetting("alloc");
				if (alloc == "construct")
				{
					outWhy.AppendF("A Construct Lambda lives on the heap and may outlive {}: only a Local Lambda (freed when its region ends) captures by reference", name);
					return false;
				}
				if (alloc != "local")
				{
					outWhy.Set("A function pointer captures nothing: give the Lambda a delegate type and the Local Allocation first");
					return false;
				}
			}
			if (owner.Graph.ReadOnly || !CheckWritable())
			{
				outWhy.Set("The Sheet is read-only");
				return false;
			}
			NodeFactory.SetCaptureByRef(owner.Graph, n, name, byRef);
			return true;
		}

		/// The Allocation changed: from Local to Construct the by-reference captures become by
		/// value (a heap Lambda may not hold them); the status line says so.
		public void SetLambdaAllocFromProperties(Sheet owner, Node n, StringView alloc)
		{
			int dropped = 0;
			if (alloc != "local")
				for (int i = n.Settings.Count - 1; i >= 0; i--)
				{
					let s = n.Settings[i];
					if (s.Key == "capture" && !s.IsSet && s.Value.EndsWith(" by-ref"))
					{
						n.Settings.RemoveAt(i);
						delete s;
						dropped++;
					}
				}
			NodeFactory.SetLambdaAlloc(owner.Graph, n, alloc);
			if (dropped > 0 && alloc != "" && alloc != "pointer")
				SetStatus(scope $"{dropped} capture{(dropped == 1) ? "" : "s"} by reference now by value: only a Local Lambda captures by reference", .Info);
		}
	}
}
