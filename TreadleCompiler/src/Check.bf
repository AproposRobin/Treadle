using System;
using System.Collections;
using Treadle.Model;
using Treadle.Graph;
using Treadle.Document;

namespace Treadle.Compiler
{
	/// A vertex of a Sheet's flow graph: a flow node, or one flow output of a flow node (so a
	/// body output can dominate the nodes of its region, Language.md 5.3).
	class FlowVertex
	{
		public int32 Index;
		public BNode Node;
		/// A flow output vertex: its pin name; null for a node vertex.
		public String Pin ~ delete _;
		public List<int32> Succ = new .() ~ delete _;
		public List<int32> Pred = new .() ~ delete _;
		public int32 Idom = -1;
		public int32 Rpo = -1;
		public Region Region;
		/// The output opens this region.
		public Region Opens;
		public bool IsPin => Pin != null;
	}

	/// The flow graph of one Sheet and its dominator tree (Cooper-Harvey-Kennedy).
	class FlowGraph
	{
		public List<FlowVertex> V = new .() ~ DeleteContainerAndItems!(_);
		public List<int32> Order = new .() ~ delete _;
		Dictionary<String, int32> mPins = new .() ~ DeleteDictionaryAndKeys!(_);

		public FlowVertex Add(BNode n, StringView pin)
		{
			FlowVertex v = new .();
			v.Index = (int32)V.Count;
			v.Node = n;
			if (!pin.IsNull)
			{
				v.Pin = new String(pin);
				mPins[new String(scope $"{n.Key}.{pin}")] = v.Index;
			}
			V.Add(v);
			return v;
		}

		public FlowVertex PinVertex(BNode n, StringView pin)
		{
			if (mPins.TryGetValueAlt(scope String()..AppendF("{}.{}", n.Key, pin), let i))
				return V[i];
			return null;
		}

		public void Edge(FlowVertex a, FlowVertex b)
		{
			if (!a.Succ.Contains(b.Index))
			{
				a.Succ.Add(b.Index);
				b.Pred.Add(a.Index);
			}
		}

		/// `a` dominates `b` (every path from the Entry to `b` passes `a`).
		public bool Dominates(FlowVertex a, FlowVertex b)
		{
			if (a == null || b == null || b.Rpo < 0 || a.Rpo < 0)
				return false;
			var x = b.Index;
			int guard = 0;
			while (guard++ < 100000)
			{
				if (x == a.Index)
					return true;
				let up = V[x].Idom;
				if (up == x || up < 0)
					return false;
				x = up;
			}
			return false;
		}

		public void ComputeDominators()
		{
			if (V.IsEmpty)
				return;
			// Reverse postorder from the root (vertex 0).
			List<int32> post = scope .();
			bool[] seen = scope bool[V.Count];
			List<(int32 v, int32 next)> stack = scope .();
			stack.Add((0, 0));
			seen[0] = true;
			while (!stack.IsEmpty)
			{
				var top = ref stack.Back;
				let v = V[top.v];
				if (top.next < v.Succ.Count)
				{
					let s = v.Succ[top.next++];
					if (!seen[s])
					{
						seen[s] = true;
						stack.Add((s, 0));
					}
					continue;
				}
				post.Add(top.v);
				stack.PopBack();
			}
			for (int i = post.Count - 1; i >= 0; i--)
			{
				V[post[i]].Rpo = (int32)Order.Count;
				Order.Add(post[i]);
			}
			V[0].Idom = 0;
			bool changed = true;
			while (changed)
			{
				changed = false;
				for (int k = 1; k < Order.Count; k++)
				{
					let v = V[Order[k]];
					int32 newIdom = -1;
					for (let p in v.Pred)
					{
						if (V[p].Idom < 0)
							continue;
						newIdom = (newIdom < 0) ? p : Intersect(p, newIdom);
					}
					if (newIdom >= 0 && v.Idom != newIdom)
					{
						v.Idom = newIdom;
						changed = true;
					}
				}
			}
		}

		int32 Intersect(int32 a, int32 b)
		{
			var a;
			var b;
			while (a != b)
			{
				while (V[a].Rpo > V[b].Rpo)
					a = V[a].Idom;
				while (V[b].Rpo > V[a].Rpo)
					b = V[b].Idom;
			}
			return a;
		}
	}

	extension Compilation
	{
		/// Check (Compiler.md 3): flow graph, dominators, regions, value reads, loops, purity,
		/// unsafe, Local lifetimes, evaluation counts.
		public void CheckSheet(SheetResult r)
		{
			SheetChecker k = scope .(this, r);
			k.Run();
			KernelRules.Check(this, r); // Kernel.bf: a [Kernel] Sheet's rules (GPU-Compute.md)
		}
	}

	class SheetChecker
	{
		Compilation c;
		SheetResult r;
		FlowGraph F;

		public this(Compilation comp, SheetResult result)
		{
			c = comp;
			r = result;
		}

		void Err(BNode n, StringView pin, StringView code, StringView message)
		{
			c.Diags.Add(.Error, .Check, code, r.Site, (n != null) ? n.Key : "", pin, message);
			r.HasErrors = true;
		}

		CDiag ErrD(BNode n, StringView pin, StringView code, StringView message)
		{
			r.HasErrors = true;
			return c.Diags.Add(.Error, .Check, code, r.Site, (n != null) ? n.Key : "", pin, message);
		}

		void Warn(BNode n, StringView pin, StringView code, StringView message)
		{
			c.Diags.Add(.Warning, .Check, code, r.Site, (n != null) ? n.Key : "", pin, message);
		}

		static void Title(BNode n, String outText) => n.Node.GetTitle(outText);

		FlowVertex VOf(BNode n) => (n != null && n.Vertex >= 0) ? F.V[n.Vertex] : null;

		/// The node a flow output leads to (null when unwired or not a flow node).
		BNode Target(BNode n, StringView pin)
		{
			let p = n.Node.FindOutput(pin);
			if (p == null)
				return null;
			let l = r.Graph.FindLinkFrom(p);
			if (l == null || l.To.Kind != .Flow)
				return null;
			let t = r.Get(l.To.Owner);
			return (t != null && t.Flow && !t.Node.Disabled) ? t : null;
		}

		static RegionKind? OpensRegion(BNode n, StringView pin)
		{
			switch (n.Kind)
			{
			case .For, .ForEach, .While, .DoWhile: if (pin == "body") return .Loop;
			case .Sequence: if (pin.StartsWith("then")) return .SequenceArm;
			case .Scope: if (pin == "body") return .Block;
			case .Switch: if (pin.StartsWith("case:") || pin == "default") return .Block;
			case .ResultMatch: if (pin == "ok" || pin == "err") return .Block;
			case .Gate, .DoOnce, .DoN, .FlipFlop, .MultiGate: if (pin != "done") return .Block;
			case .Branch: if (pin == "true" || pin == "false") return .Arm;
			case .Cast: if (pin == "failed") return .Arm;
			case .Defer: if (pin == "deferred") return .Deferred;
			default:
			}
			return null;
		}

		public void Run()
		{
			r.Checked = true;
			if (r.Entry == null)
				return;
			F = new .();
			r.Flow = F;
			BuildGraph();
			F.ComputeDominators();
			BuildRegions();
			for (let b in r.Nodes)
			{
				if (b.Node.Disabled)
					continue;
				if (b.Flow && !b.Reached && b.Kind != .Entry)
				{
					String t = scope .();
					Title(b, t);
					Warn(b, "", "T3001", scope $"not reached: nothing runs {t} (wire its flow input or delete it)");
				}
			}
			ComputeOwnersAndReads();
			CheckLoopsAndReturns();
			CheckDanglingEnds();
			if (r.MustBePure)
				CheckPurity();
			CheckUnsafe();
			CheckLocals();
			CheckRegionItems();
			for (let b in r.Nodes)
				if (b.Unsupported && (b.Reached || (!b.Flow && !b.Owners.IsEmpty)) && b.Kind != .Unknown && b.Kind != .Intrinsic && b.Kind != .Lambda)
				{
					String t = scope .();
					Title(b, t);
					Warn(b, "", "T3070", scope $"{t} is checked but not compiled yet (a later milestone)");
				}
		}

		// ------------------------------------------------------------------ graph

		void BuildGraph()
		{
			List<BNode> work = scope .();
			let root = F.Add(r.Entry, default);
			r.Entry.Vertex = root.Index;
			r.Entry.Reached = true;
			work.Add(r.Entry);
			while (!work.IsEmpty)
			{
				let n = work.PopFront();
				let nv = F.V[n.Vertex];
				for (let pin in n.FlowOuts)
				{
					let pv = F.Add(n, pin);
					F.Edge(nv, pv);
					let t = Target(n, pin);
					if (t == null)
						continue;
					if (t.Vertex < 0)
					{
						let tv = F.Add(t, default);
						t.Vertex = tv.Index;
						t.Reached = true;
						work.Add(t);
					}
					F.Edge(pv, F.V[t.Vertex]);
				}
			}
		}

		void BuildRegions()
		{
			Dictionary<BNode, Region> merges = scope .();
			Region fn = new .();
			fn.Id = 0;
			fn.Kind = .Function;
			r.Regions.Add(fn);
			if (r.UnsafeSheet)
				fn.Unsafe = true;
			for (let idx in F.Order)
			{
				let v = F.V[idx];
				if (idx == 0)
				{
					v.Region = fn;
					continue;
				}
				if (v.IsPin)
				{
					let owner = F.V[v.Node.Vertex].Region ?? fn;
					let kind = OpensRegion(v.Node, v.Pin);
					if (kind != null)
					{
						Region reg = new .();
						reg.Id = (int32)r.Regions.Count;
						reg.Kind = kind.Value;
						reg.Parent = owner;
						reg.Owner = v.Node;
						reg.Pin.Set(v.Pin);
						reg.Unsafe = v.Node.Kind == .Scope && v.Node.Node.Unsafe;
						r.Regions.Add(reg);
						v.Opens = reg;
						v.Region = reg;
					}
					else
						v.Region = owner;
					continue;
				}
				v.Region = (v.Idom >= 0) ? F.V[v.Idom].Region : fn;
				if (v.Idom >= 0 && !F.V[v.Idom].IsPin)
				{
					let merged = MergeRegion(v, F.V[v.Idom].Node, merges);
					if (merged != null)
						v.Region = merged;
				}
				v.Node.Region = v.Region;
			}
			r.Entry.Region = fn;
		}

		/// A node that several arms of a Switch or a Result: match (or of a Gate) flow into, and
		/// nothing outside them: it stays inside the node (Language.md 5.3), in a region of its
		/// own below the node's (pin `merge`, entered when the flow reaches it), so the flow that
		/// ends after it continues to the node's `done`, as each arm's would.
		Region MergeRegion(FlowVertex v, BNode n, Dictionary<BNode, Region> merges)
		{
			if (!n.HasFlowOut("done"))
				return null;
			for (let p in v.Pred)
			{
				var reg = F.V[p].Region;
				if (reg == null)
					return null; // a loop's way back: not a merge of the arms
				while (reg != null && !(reg.Owner == n && reg.Kind == .Block))
					reg = reg.Parent;
				if (reg == null)
					return null;
			}
			if (merges.TryGetValue(n, let have))
				return have;
			Region reg = new .();
			reg.Id = (int32)r.Regions.Count;
			reg.Kind = .Block;
			reg.Parent = F.V[n.Vertex].Region;
			reg.Owner = n;
			reg.Pin.Set("merge");
			reg.Unsafe = reg.Parent != null && reg.Parent.Unsafe;
			r.Regions.Add(reg);
			merges[n] = reg;
			return reg;
		}

		// ------------------------------------------------------------------ value reads (Rules 2, 3)

		void ComputeOwnersAndReads()
		{
			for (let idx in F.Order)
			{
				let v = F.V[idx];
				if (v.IsPin)
					continue;
				HashSet<BNode> seen = scope .();
				WalkInputs(v.Node, v.Node, seen);
			}
			// A Base / This Constructor runs before the body: it reads only the parameters.
			for (let b in r.Nodes)
			{
				if (b.Kind != .ChainCtor || b.Node.Disabled)
					continue;
				HashSet<BNode> seen = scope .();
				WalkInputs(r.Entry, b, seen);
			}
		}

		/// Walks the value inputs of `node` (owned by the flow node `owner`): value nodes get the
		/// owner, reads of flow node outputs are checked against dominance.
		void WalkInputs(BNode owner, BNode node, HashSet<BNode> seen)
		{
			for (let spec in node.Ins)
			{
				if (spec.Type == null || spec.Pin == null)
					continue;
				let l = r.Graph.FindLinkTo(spec.Pin);
				if (l == null)
					continue;
				let src = r.Get(l.From.Owner);
				if (src == null || src.Node.Disabled)
					continue;
				if (src.Flow)
				{
					CheckRead(owner, node, spec, src, l.From.Name);
					continue;
				}
				if (src.Kind == .ChainCtor)
					continue;
				if (!src.Owners.Contains(owner))
					src.Owners.Add(owner);
				if (seen.Add(src))
					WalkInputs(owner, src, seen);
			}
		}

		void CheckRead(BNode owner, BNode consumer, InSpec spec, BNode producer, StringView outPin)
		{
			if (producer == r.Entry)
				return;
			String what = scope .();
			Title(producer, what);
			if (consumer.Kind == .ChainCtor)
			{
				Err(consumer, spec.Name, "T3019", scope $"{spec.Label}: the Base Constructor runs before the body: it reads only the Entry's parameters");
				return;
			}
			if (!producer.Reached)
			{
				Err(consumer, spec.Name, "T3020", scope $"{spec.Label}: may not have run: nothing runs {what}");
				return;
			}
			let fv = VOf(owner);
			if (fv == null)
				return;
			if (producer == owner)
			{
				Err(consumer, spec.Name, "T3021", scope $"{spec.Label}: {what} reads its own output before it has made it");
				return;
			}
			let pv = VOf(producer);
			if (!F.Dominates(pv, fv))
			{
				if (IsLocalObject(producer, outPin))
				{
					let d = ErrD(consumer, spec.Name, "T3022", scope $"{spec.Label}: reads the object of {what} outside its region: the object is freed when its region ends");
					d.AddRelated(producer.Key, "the Local");
				}
				else
					Err(consumer, spec.Name, "T3022", scope $"{spec.Label}: may not have run: {what} does not run on every path to here (Store in a local)");
				return;
			}
			let o = producer.FindOut(outPin);
			if (o != null && !o.OnlyIn.IsEmpty)
			{
				let bodyV = F.PinVertex(producer, o.OnlyIn);
				if (!F.Dominates(bodyV, fv))
				{
					if (producer.Kind == .For || producer.Kind == .ForEach)
						Err(consumer, spec.Name, "T3023", scope $"{spec.Label}: {(StringView)o.Name} is not valid after the loop; store it in a local");
					else
						Err(consumer, spec.Name, "T3023", scope $"{spec.Label}: {(StringView)o.Name} is valid only in the {(StringView)o.OnlyIn} output of {what}");
				}
			}
		}

		// ------------------------------------------------------------------ flow rules

		static bool IsReached(BNode b) => b.Reached && !b.Node.Disabled;

		void CheckLoopsAndReturns()
		{
			for (let b in r.Nodes)
			{
				if (!IsReached(b))
					continue;
				if (b.Kind == .Break || b.Kind == .Continue)
				{
					var reg = b.Region;
					bool ok = false;
					while (reg != null)
					{
						if (reg.Kind == .Loop)
						{
							ok = true;
							break;
						}
						if (reg.Kind == .Deferred)
							break;
						reg = reg.Parent;
					}
					if (!ok)
						Err(b, "", "T3030", scope $"{(b.Kind == .Break) ? "Break" : "Continue"} is outside a loop body");
				}
				if (b.Kind == .Return || b.Kind == .Try)
				{
					var reg = b.Region;
					while (reg != null)
					{
						if (reg.Kind == .Deferred)
						{
							Err(b, "", "T3031", scope $"{(b.Kind == .Return) ? "Return" : "Try"} cannot leave the function from a Deferred body");
							break;
						}
						reg = reg.Parent;
					}
				}
			}
		}

		/// A Switch or a Result: match continues to `done` only when one of its arms (or the
		/// flow merged below them) ends without a wire; a Scope's `done` after its body.
		static bool DoneAfterArms(BNode n) => n.Kind == .Switch || n.Kind == .ResultMatch || n.Kind == .Scope;

		/// A While / Do While whose condition is the literal `true`: it ends only by a Break.
		bool EndlessLoop(BNode n)
		{
			if (n.Kind != .While && n.Kind != .DoWhile)
				return false;
			let p = n.Node.FindInput("condition");
			return p != null && r.Graph.FindLinkTo(p) == null && p.Default == "true";
		}

		/// Reachability on the flow graph (Language.md 5.3): which flow outputs can run. A Return,
		/// a Try's return and a Fatal end the flow; the `done` of a Switch, a Result: match or a
		/// Scope runs only when an arm ends without a wire; a Sequence's next output only when the
		/// previous one ends; an endless While's `done` only after a Break. An output that can run
		/// and ends without a wire where that ends the function is T3032 in a function that returns
		/// a value.
		void CheckDanglingEnds()
		{
			let needsValue = !r.Returns.IsVoid && !r.Returns.IsError;
			if (!needsValue || F.V.IsEmpty)
				return;
			bool[] live = scope bool[F.V.Count];
			List<int32> work = scope .();
			List<FlowVertex> ends = scope .();
			void Mark(FlowVertex v)
			{
				if (v == null || live[v.Index])
					return;
				live[v.Index] = true;
				work.Add(v.Index);
			}
			Mark(F.V[0]);
			while (!work.IsEmpty)
			{
				let v = F.V[work.PopBack()];
				if (!v.IsPin)
				{
					let n = v.Node;
					if (n.Kind == .Break)
					{
						var reg = n.Region;
						while (reg != null && reg.Kind != .Loop && reg.Kind != .Deferred)
							reg = reg.Parent;
						if (reg != null && reg.Kind == .Loop)
							Mark(F.PinVertex(reg.Owner, "done"));
					}
					for (let s in v.Succ)
					{
						let pv = F.V[s];
						if (!pv.IsPin)
						{
							Mark(pv);
							continue;
						}
						if (pv.Pin == "done" && (DoneAfterArms(n) || EndlessLoop(n)))
							continue;
						if (n.Kind == .Sequence && n.FlowOuts.Count > 0 && pv.Pin != n.FlowOuts[0])
							continue;
						Mark(pv);
					}
					continue;
				}
				if (!v.Succ.IsEmpty)
				{
					for (let s in v.Succ)
						Mark(F.V[s]);
					continue;
				}
				// An output without a wire: the flow continues where its region does.
				var reg = v.Opens ?? v.Region ?? v.Node.Region;
				int guard = 0;
				while (guard++ < 256)
				{
					if (reg == null || reg.Kind == .Function)
					{
						ends.Add(v);
						break;
					}
					if (reg.Kind == .Loop || reg.Kind == .Deferred)
						break;
					let owner = reg.Owner;
					if (reg.Kind == .SequenceArm)
					{
						int idx = owner.FlowOuts.IndexOf(scope String(reg.Pin));
						if (idx >= 0 && idx + 1 < owner.FlowOuts.Count)
						{
							Mark(F.PinVertex(owner, owner.FlowOuts[idx + 1]));
							break;
						}
						reg = reg.Parent;
					}
					else if (reg.Kind == .Block && owner != null && owner.HasFlowOut("done"))
					{
						Mark(F.PinVertex(owner, "done"));
						break;
					}
					else
						reg = reg.Parent;
				}
			}
			for (let v in ends)
			{
				String t = scope .();
				Title(v.Node, t);
				Err(v.Node, v.Pin, "T3032", scope $"the flow ends after {t} without a Return: {r.Member.Name} returns {TypeTable.Show(r.Returns, .. scope .())}");
			}
		}

		// ------------------------------------------------------------------ purity (Language.md 4.1)

		void CheckPurity()
		{
			StringView what = (r.Sheet.Role == .Get) ? "a getter" : "a Pure function";
			for (let b in r.Nodes)
			{
				if (b.Node.Disabled || (!b.Reached && b.Owners.IsEmpty))
					continue;
				switch (b.Kind)
				{
				case .Set:
					if (b.Var != .Local && b.Var != .Param)
						Err(b, "", "T3040", scope $"{what} may not change {(b.Member != null) ? (StringView)b.Member.Name : (StringView)b.Node.Text}: only its local variables");
				case .Construct:
					Err(b, "", "T3041", scope $"{what} may not Construct (a Local is fine)");
				case .Delete, .DeferDelete:
					Err(b, "", "T3041", scope $"{what} may not delete objects");
				case .Invoke:
					Err(b, "", "T3041", scope $"{what} may not Invoke a delegate (it may have side effects)");
				case .Call:
					if (b.EventOp != .None)
					{
						if (b.EventOp != .Count)
							Err(b, "", "T3041", scope $"{what} may not change or Invoke the event {b.Member.Name} (its handlers may have side effects)");
					}
					else if (b.Member != null && !b.Member.Pure)
						Err(b, "", "T3042", scope $"{what} may only call Pure functions: {b.Member.Name} has side effects");
					else if (b.VecFn != .None && VectorRules.Of(b.VecFn).Flow)
						Err(b, "", "T3042", scope $"{what} may only call Pure functions: Vector.{VectorRules.Of(b.VecFn).Name} writes memory");
				case .Cast:
					if (b.Cast == .Box)
						Err(b, "", "T3041", scope $"{what} may not Box (it allocates)");
				case .Bind, .Lambda:
					if (b.Node.GetSetting("alloc") == "construct")
						Err(b, "", "T3041", scope $"{what} may not allocate a delegate on the heap");
				case .Gate, .DoOnce, .DoN, .FlipFlop, .MultiGate, .GateOpen, .GateClose, .GateToggle, .ResetDoOnce, .ResetDoN, .ResetMultiGate:
					Err(b, "", "T3044", scope $"{what} may not keep state (Gate, Do Once...)");
				default:
				}
				if (b.Unsafe)
					Err(b, "", "T3043", scope $"{what} may not use unsafe nodes");
			}
		}

		// ------------------------------------------------------------------ unsafe (Language.md 2.7)

		static bool UnsafeAllowed(Region reg)
		{
			var reg;
			while (reg != null)
			{
				if (reg.Unsafe)
					return true;
				reg = reg.Parent;
			}
			return false;
		}

		void CheckUnsafe()
		{
			for (let b in r.Nodes)
			{
				if (!b.Unsafe || b.Node.Disabled)
					continue;
				bool ok = r.UnsafeSheet;
				if (!ok)
				{
					if (b.Flow)
						ok = b.Reached && UnsafeAllowed(b.Region);
					else
					{
						ok = !b.Owners.IsEmpty;
						for (let o in b.Owners)
							ok &= UnsafeAllowed(o.Region);
					}
				}
				if (!ok)
					Err(b, "", "T3050", "an unsafe node: mark the function Unsafe in Properties or wrap the nodes in an Unsafe block (Wrap in Unsafe)");
			}
		}

		// ------------------------------------------------------------------ Local rules (Compiler.md 3.7)

		/// The flow node and output a value input comes from, through Casts and Selects.
		(BNode node, String pin) Origin(BNode n, StringView pin, int depth = 0)
		{
			if (depth > 32)
				return (null, null);
			let p = n.Node.FindInput(pin);
			let l = (p != null) ? r.Graph.FindLinkTo(p) : null;
			if (l == null)
				return (null, null);
			let src = r.Get(l.From.Owner);
			if (src == null)
				return (null, null);
			if (!src.Flow && src.Kind == .Cast)
				return Origin(src, "value", depth + 1);
			return (src, l.From.Name);
		}

		/// The object a Local node made, or the delegate of a Local Bind / Lambda: freed when the
		/// node's region ends (Language.md 3, 4.2).
		static bool IsLocalObject(BNode src, StringView pin)
		{
			if (src == null)
				return false;
			if (src.Kind == .Local)
				return pin == "object";
			return (src.Kind == .Bind || src.Kind == .Lambda) && src.Flow && src.Alloc == .Local && pin == "value";
		}

		void CheckLocals()
		{
			List<BNode> deletes = scope .();
			for (let b in r.Nodes)
			{
				if (!IsReached(b))
					continue;
				if (b.Kind == .Delete || b.Kind == .DeferDelete)
				{
					deletes.Add(b);
					let (src, pin) = Origin(b, "object");
					if (IsLocalObject(src, pin))
					{
						let d = ErrD(b, "object", "T3062", "Object: this object is a Local's: it is freed when its region ends, so deleting it frees it twice");
						d.AddRelated(src.Key, "the Local that owns the object");
					}
				}
				CheckStructCopy(b);
				for (let spec in b.Ins)
				{
					if (spec.Type == null)
						continue;
					let (src, pin) = Origin(b, spec.Name);
					if (!IsLocalObject(src, pin))
						continue;
					if (b.Kind == .Return && spec.Name == "value")
					{
						let d = ErrD(b, "value", "T3061", "Return Value: returns a Local's object, which is freed when the function returns");
						d.AddRelated(src.Key, "the Local");
					}
					else if (b.Kind == .Set && spec.Name == "value" && (b.Var == .Field || b.Var == .StaticField || b.Var == .Property))
						Warn(b, "value", "T3060", "Value: stores a Local's object in a field: the object is freed when its region ends");
				}
			}
			// The same object deleted twice on one path.
			for (int i < deletes.Count)
			{
				for (int j < deletes.Count)
				{
					if (i == j)
						continue;
					let a = deletes[i];
					let b = deletes[j];
					let (sa, pa) = Origin(a, "object");
					let (sb, pb) = Origin(b, "object");
					if (sa == null || sa != sb || pa != pb)
						continue;
					if (F.Dominates(VOf(a), VOf(b)))
					{
						let d = ErrD(b, "object", "T3063", "Object: the object is already deleted on every path to here (deleted twice)");
						d.AddRelated(a.Key, "the first Delete");
					}
				}
			}
		}

		/// A struct whose type has a destructor is copied bit for bit (Compiler.md 4, "Regions"):
		/// both copies would be destroyed, or the copy never. A Set or a call input that takes such a
		/// struct from a variable warns, unless the struct says copies are fine (`attr Copyable`).
		void CheckStructCopy(BNode b)
		{
			if (b.Kind != .Set && b.Kind != .Call && b.Kind != .Return)
				return;
			for (let spec in b.Ins)
			{
				if (spec.Type == null || spec.IsReceiver || spec.IsRef || spec.Pin == null)
					continue;
				let t = spec.Type;
				if (!t.IsStruct || t.Sym.Dtor == null || HasAttr(t.Sym, "Copyable"))
					continue;
				let l = r.Graph.FindLinkTo(spec.Pin);
				let src = (l != null) ? r.Get(l.From.Owner) : null;
				if (src == null || (src.Kind != .This && (src.Kind != .Get || src.Var == .Property || src.Var == .None)))
					continue;
				Warn(b, spec.Name, "T3064", scope $"{spec.Label}: copies a {t.Sym.Name}, which has a destructor, bit for bit: both copies would be destroyed (or the copy never); pass it by ref, or mark {t.Sym.Name} Copyable");
			}
		}

		/// A struct whose bit-for-bit copies are fine (`attr Copyable`, Language.md 2.5).
		public static bool IsCopyable(TypeSym s) => HasAttr(s, "Copyable");

		static bool HasAttr(TypeSym s, StringView name)
		{
			if (s.Decl != null)
				for (let a in s.Decl.Attrs)
					if (a.Name == name)
						return true;
			return false;
		}

		/// Region items: the Locals and Defers of each region in dominance order (the back end
		/// tracks at run time which of them ran, so a region exit unwinds exactly those).
		void CheckRegionItems()
		{
			for (let idx in F.Order)
			{
				let v = F.V[idx];
				if (v.IsPin)
					continue;
				let b = v.Node;
				if (b.Kind == .Local && b.Subject != null && !b.Subject.IsError)
				{
					let reg = b.Node.HasSetting("function-scope") ? r.Regions[0] : b.Region;
					reg.Locals.Add(b);
				}
				else if (b.Kind == .Defer || b.Kind == .DeferDelete)
					b.Region.Defers.Add(b);
			}
		}
	}
}
