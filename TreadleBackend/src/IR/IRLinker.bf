using System;
using System.Collections;

namespace Treadle.Backend.IR
{
	/// Resolves the names of a program (text form, or a partly filled in-memory one) and checks the
	/// structure the emitter relies on. Objects already set (in-process construction) are kept.
	static class IRLinker
	{
		public static bool Link(IRProgram p, List<String> errors)
		{
			int before = errors.Count;
			void Err(int32 line, StringView msg)
			{
				if (line > 0)
					errors.Add(new String()..AppendF("line {}: {}", line, msg));
				else
					errors.Add(new String(msg));
			}
			IRFunction Fn(StringView key, int32 line, StringView what)
			{
				let f = p.FindFunction(key);
				if (f == null)
					Err(line, scope $"{what} '{key}' is not declared");
				return f;
			}

			let obj = p.ObjectDecl;
			// Core.Delegate, when the program has delegates and does not declare it
			bool usesDelegates = false;
			for (let kv in p.Types)
				if (kv.value.Kind == .Delegate || (kv.value.Kind == .Named && kv.value.Text == "Core.Delegate"))
					usesDelegates = true;
			for (let d in p.Decls)
				if (d.BaseName == "Core.Delegate")
					usesDelegates = true;
			if (usesDelegates)
				p.DelegateDecl.Base = obj;
			// 1. named types -> declarations
			for (let kv in p.Types)
			{
				let t = kv.value;
				if (t.Kind == .Named && t.Decl == null)
					t.Decl = p.FindDecl(t.Text);
			}
			for (let kv in p.Types)
			{
				let t = kv.value;
				if (t.Kind == .Named && t.Decl == null)
					Err(0, scope $"type '{t.Text}' is used but not declared");
			}
			if (errors.Count > before)
				return false;

			// 2. declarations
			for (let d in p.Decls)
			{
				if (d.BaseName != null && d.Base == null)
				{
					d.Base = p.FindDecl(d.BaseName);
					if (d.Base == null)
						Err(d.Line, scope $"base '{d.BaseName}' of {d.Name} is not declared");
					else if (d.Base.Kind != .Class || d.Kind != .Class)
						Err(d.Line, scope $"{d.Name}: only a class has a base class");
				}
				if (d.Kind == .Class && d.Base == null && d != obj)
					d.Base = obj;
				if (d.Kind == .Enum && !d.IsPayloadEnum && d.TagType == null)
					d.TagType = p.T("int32");
				if (d.DtorKey != null && d.Dtor == null)
					d.Dtor = Fn(d.DtorKey, d.Line, "destructor");
				for (let s in d.VTable)
				{
					if (s.Decl == null && s.DeclKey != null)
						s.Decl = Fn(s.DeclKey, d.Line, "vslot function");
					if (s.Impl == null && s.ImplKey != null)
						s.Impl = Fn(s.ImplKey, d.Line, "vslot implementation");
					if (s.Decl == null)
						Err(d.Line, scope $"{d.Name}: a vslot has no declaring function");
				}
				for (let k in d.ISlotKeys)
				{
					if (@k.Index < d.ISlots.Count)
						continue;
					let f = Fn(k, d.Line, "islot function");
					if (f != null)
						d.ISlots.Add(f);
				}
				for (let it in d.ITables)
				{
					if (it.Iface == null && it.IfaceName != null)
					{
						it.Iface = p.FindDecl(it.IfaceName);
						if (it.Iface == null || it.Iface.Kind != .Interface)
						{
							Err(d.Line, scope $"{d.Name}: '{it.IfaceName}' is not an interface");
							continue;
						}
					}
					for (let k in it.ImplKeys)
					{
						if (@k.Index < it.Impls.Count)
							continue;
						let f = Fn(k, d.Line, "itable implementation");
						if (f != null)
							it.Impls.Add(f);
					}
				}
			}
			// base vtables are a prefix of derived ones
			for (let d in p.Decls)
			{
				if (d.Kind != .Class || d.Base == null)
					continue;
				let b = d.Base;
				if (d.VTable.Count < b.VTable.Count)
				{
					Err(d.Line, scope $"{d.Name} has {d.VTable.Count} vslots, fewer than its base {b.Name} ({b.VTable.Count})");
					continue;
				}
				for (int i < b.VTable.Count)
					if (b.VTable[i].Decl != d.VTable[i].Decl)
						Err(d.Line, scope $"{d.Name}: vslot {i} is {(d.VTable[i].Decl?.Key)} but the base's is {(b.VTable[i].Decl?.Key)}");
			}
			for (let d in p.Decls)
				for (let it in d.ITables)
					if (it.Iface != null && it.Impls.Count != it.Iface.ISlots.Count)
						Err(d.Line, scope $"{d.Name}: itable {it.Iface.Name} has {it.Impls.Count} functions for {it.Iface.ISlots.Count} slots");
			if (errors.Count > before)
				return false;

			// 3. globals
			for (let g in p.Globals)
				if (g.Name == null)
					Err(g.Line, scope $"global '{g.Text}' has no valid name");

			// 4. functions
			// Owners first, for every function: a body may call or vcall a function defined after it,
			// and the call checks read the callee's owner (`this`, vtable slot).
			for (let f in p.Functions)
			{
				if (f.OwnerDecl == null && f.Owner != null)
				{
					String owner = scope .();
					f.Owner.ToString(owner);
					f.OwnerDecl = p.FindDecl(owner);
				}
			}
			for (let f in p.Functions)
			{
				if (f.Ret == null)
				{
					Err(f.Line, scope $"{f.Key} has no return type");
					continue;
				}
				// `this` first for instance functions
				if (f.HasThis && f.Params.Count == f.ParamTypes.Count)
				{
					IRValue self = new .();
					self.Name.Set("this");
					self.Type = (f.OwnerDecl.Kind == .Struct) ? p.T(scope $"{f.OwnerDecl.Name}*") : f.OwnerDecl.Type;
					f.Params.Insert(0, self);
					for (let v in f.Params)
						v.ParamIndex = (int32)@v.Index;
				}
				let expected = f.ParamTypes.Count + (f.HasThis ? 1 : 0);
				if (f.Params.Count != expected)
				{
					Err(f.Line, scope $"{f.Key} has {f.Params.Count} parameter values for {expected} parameters");
					continue;
				}
				for (let s in f.Slots)
				{
					if (s.Type == null)
						Err(f.Line, scope $"{f.Key}: slot {s.Id} has no type");
					if (s.RegionId != null && s.Region == null)
					{
						s.Region = f.FindRegion(s.RegionId);
						if (s.Region == null)
							Err(f.Line, scope $"{f.Key}: slot {s.Id} names region '{s.RegionId}', which is not declared");
					}
					if (s.Region == null)
						s.Region = f.BodyRegion;
				}
				if (f.HasBody && (f.Abstract || f.IsImport))
					Err(f.Line, scope $"{f.Key} is {f.Abstract ? "abstract" : "imported"} and has blocks");
				LinkBody(p, f, errors);
			}

			// 5. entry
			if (p.Entry == null && p.EntryKey != null)
			{
				p.Entry = p.FindFunction(p.EntryKey);
				if (p.Entry == null)
					Err(0, scope $"entry '{p.EntryKey}' is not declared");
			}
			if (p.Entry != null)
			{
				let e = p.Entry;
				let argsParam = e.ParamTypes.Count == 1 && IsStringArray(e.ParamTypes[0]);
				if (!e.Static || !(e.ParamTypes.IsEmpty || argsParam) || !e.HasBody)
					Err(e.Line, scope $"entry {e.Key} must be a static function with a body and no parameters or one Core.String[]");
				else if (!(e.Ret.IsVoid || e.Ret.Kind == .Int))
					Err(e.Line, scope $"entry {e.Key} must return void or an integer");
			}
			return errors.Count == before;
		}

		/// `Core.String[]`: the parameter of a `Main(String[] args)` entry.
		public static bool IsStringArray(IRType t) => t.Kind == .Array && t.Elem.Kind == .Named && t.Elem.Text == "Core.String";

		/// The memory orders of the atomic ops.
		public static bool IsOrder(StringView o) => o == "relaxed" || o == "acquire" || o == "release" || o == "acqrel" || o == "seqcst";

		/// True when `d` is `Core.Delegate` or derives from it.
		static bool IsDelegateClass(IRTypeDecl d)
		{
			for (var c = d; c != null; c = c.Base)
				if (c.Name == "Core.Delegate")
					return true;
			return false;
		}

		/// How a bound function is reached: its owner's interface table, its vtable slot, or directly.
		public static bool IsDispatched(IRFunction f) => f.OwnerDecl != null && !f.Static &&
			((f.OwnerDecl.Kind == .Interface && f.OwnerDecl.ISlots.IndexOf(f) >= 0) || (f.OwnerDecl.Kind == .Class && f.OwnerDecl.FindVSlot(f) >= 0));

		static void LinkBody(IRProgram p, IRFunction f, List<String> errors)
		{
			if (!f.HasBody)
				return;
			void Err(int32 line, StringView msg)
			{
				errors.Add(new String()..AppendF("line {}: {}: {}", line > 0 ? line : f.Line, f.Key, msg));
			}
			Dictionary<String, IRValue> values = scope .();
			for (let v in f.Params)
				values[v.Name] = v;
			for (let b in f.Blocks)
			{
				b.Function = f;
				for (let op in b.Ops)
					if (op.Result != null)
					{
						if (values.ContainsKey(op.Result.Name))
							Err(op.Line, scope $"%{op.Result.Name} is defined twice");
						else
							values[op.Result.Name] = op.Result;
						op.Result.Def = op;
						if (op.Result.Type == null)
							op.Result.Type = op.Type;
					}
			}
			for (let b in f.Blocks)
			{
				if (b.Ops.IsEmpty || !b.Ops.Back.IsTerminator)
				{
					Err(b.Ops.IsEmpty ? f.Line : b.Ops.Back.Line, scope $"block {b.Id} does not end in a terminator");
					continue;
				}
				for (let op in b.Ops)
				{
					if (op.IsTerminator && op != b.Ops.Back)
						Err(op.Line, scope $"{IRWriter.Mnemonic(op.Kind)} in the middle of block {b.Id}");
					if (op.ArgNames != null && op.Args.IsEmpty)
					{
						for (let n in op.ArgNames)
						{
							if (values.TryGetValue(n, let v))
								op.Args.Add(v);
							else
								Err(op.Line, scope $"%{n} is not defined");
						}
					}
					if (op.FnKey != null && op.Fn == null)
					{
						op.Fn = p.FindFunction(op.FnKey);
						if (op.Fn == null)
							Err(op.Line, scope $"function '{op.FnKey}' is not declared");
					}
					if (op.SlotId != null && op.Slot == null)
					{
						op.Slot = f.FindSlot(op.SlotId);
						if (op.Slot == null)
							Err(op.Line, scope $"slot '{op.SlotId}' is not declared");
					}
					if (op.GlobalName != null && op.Global == null)
					{
						op.Global = p.FindGlobal(op.GlobalName);
						if (op.Global == null)
							Err(op.Line, scope $"global '{op.GlobalName}' is not declared");
					}
					if (op.RegionId != null && op.Region == null)
					{
						op.Region = f.FindRegion(op.RegionId);
						if (op.Region == null)
							Err(op.Line, scope $"region '{op.RegionId}' is not declared");
					}
					if (op.TargetIds != null && op.Targets.IsEmpty)
					{
						for (let id in op.TargetIds)
						{
							let t = f.FindBlock(id);
							if (t == null)
								Err(op.Line, scope $"block '{id}' is not declared");
							else
								op.Targets.Add(t);
						}
					}
					for (let c in op.Cases)
						if (c.Target == null && c.TargetId != null)
						{
							c.Target = f.FindBlock(c.TargetId);
							if (c.Target == null)
								Err(op.Line, scope $"block '{c.TargetId}' is not declared");
						}
					CheckOp(p, f, op, scope (msg) => Err(op.Line, msg));
				}
			}
		}

		/// A span of `elem`: a struct whose fields are a `elem*` and an `int` (`Core.Span<T>`).
		public static bool IsSpanOf(IRType span, IRType elem)
		{
			if (span == null || !span.IsStruct || span.Decl.Fields.Count != 2)
				return false;
			let p = span.Decl.Fields[0].Type;
			let n = span.Decl.Fields[1].Type;
			return p != null && p.Kind == .Pointer && p.Elem == elem && n != null && n.Kind == .Int && n.Bits == 64;
		}

		/// The operand shapes per kind (what the reader cannot check alone).
		static void CheckOp(IRProgram p, IRFunction f, IROp op, delegate void(StringView) err)
		{
			int needArgs = -1;
			switch (op.Kind)
			{
			case .Copy, .Cast, .Load, .NullCheck, .ArrayLen, .Free, .Dtor, .Box, .Unbox, .DynCast, .EnumTag, .StoreSlot, .FieldAddr, .Extract, .EnumPayload, .CondBr, .Switch,
				 .LocalArray, .AtomicLoad, .Closure:
				needArgs = 1;
			case .Binop, .Cmp, .ElemAddr, .Store, .BoundsCheck, .AtomicStore, .AtomicRmw:
				needArgs = 2;
			case .Select, .AtomicCas:
				needArgs = 3;
			case .LoadSlot, .SlotAddr, .Local, .Const, .GlobalAddr, .TypeInfo, .SizeOf, .AlignOf, .Br, .EndDefer, .Unreachable, .Fatal, .RegionEnter, .RegionExit, .Defer, .FnAddr, .Fence:
				needArgs = 0;
			default:
			}
			if (op.Kind == .BoundsCheck && op.Args.Count == 3)
				needArgs = 3; // `boundscheck %span %i %len`: a Span's length given (Compiler.md 4)
			if (needArgs >= 0 && op.Args.Count != needArgs)
				err(scope $"{IRWriter.Mnemonic(op.Kind)} takes {needArgs} value{(needArgs == 1) ? "" : "s"}, has {op.Args.Count}");
			switch (op.Kind)
			{
			case .Call, .CCall:
				if (op.Fn != null)
				{
					let want = op.Fn.ParamTypes.Count + (op.Fn.HasThis ? 1 : 0);
					if (op.Args.Count < want || (!op.Fn.Variadic && op.Args.Count != want))
						err(scope $"call of {op.Fn.Key} has {op.Args.Count} arguments for {want}");
					if (op.Fn.Ret != op.Type)
						err(scope $"call of {op.Fn.Key} is typed {(op.Type?.Text)} but returns {op.Fn.Ret.Text}");
				}
			case .VCall, .ICall:
				if (op.Fn != null)
				{
					if (op.Args.Count != op.Fn.ParamTypes.Count + 1)
						err(scope $"{IRWriter.Mnemonic(op.Kind)} of {op.Fn.Key} needs the object and {op.Fn.ParamTypes.Count} arguments");
					if (op.Fn.Ret != op.Type)
						err(scope $"{IRWriter.Mnemonic(op.Kind)} of {op.Fn.Key} is typed {(op.Type?.Text)} but returns {op.Fn.Ret.Text}");
					let owner = op.Fn.OwnerDecl;
					if (op.Kind == .VCall && (owner == null || owner.FindVSlot(op.Fn) < 0))
						err(scope $"{op.Fn.Key} is not in a vtable of {(owner?.Name ?? "its owner")}");
					if (op.Kind == .ICall && (owner == null || owner.Kind != .Interface || owner.ISlots.IndexOf(op.Fn) < 0))
						err(scope $"{op.Fn.Key} is not a slot of an interface");
				}
			case .Local:
				if (op.Slot != null && op.Slot.Kind != .Local)
					err(scope $"local needs a slot of kind local; {op.Slot.Id} is not");
			case .Defer:
				if (op.Targets.Count != 1)
					err("defer needs a region and the body's first block");
			case .Ret:
				if (f.Ret.IsVoid && op.Args.Count != 0)
					err("ret with a value in a function returning void");
				else if (!f.Ret.IsVoid && (op.Args.Count != 1 || op.Args[0].Type != f.Ret))
					err(scope $"ret needs one value of type {f.Ret.Text}");
			case .Alloc:
				if (op.TypeArg == null || !op.TypeArg.IsClass)
					err("alloc needs a class type");
				else if (op.TypeArg.Decl.Abstract)
					err(scope $"{op.TypeArg.Text} is abstract");
			case .AllocArray:
				if (op.Type == null || op.Type.Kind != .Array)
					err("alloc.array needs an array type (T[])");
				if (op.Args.Count != 1 && op.Args.Count != 2)
					err("alloc.array takes the length and an optional allocator");
			case .ArraySpan:
				if (op.Args.Count != 1 && op.Args.Count != 3)
					err("array.span takes the array and an optional start and count");
				else if (op.Args[0].Type.Kind != .Array)
					err(scope $"array.span needs an array (T[]), not {op.Args[0].Type.Text}");
				else if (!IsSpanOf(op.Type, op.Args[0].Type.Elem))
					err(scope $"array.span is typed {(op.Type?.Text)}, not a span of {op.Args[0].Type.Elem.Text} (a struct of a {op.Args[0].Type.Elem.Text}* and an int)");
			case .CaseMake, .EnumPayload:
				let et =(op.Kind == .CaseMake) ? op.Type : (op.Args.IsEmpty ? null : op.Args[0].Type);
				if (et == null || !et.IsEnum)
					err(scope $"{IRWriter.Mnemonic(op.Kind)} needs an enum");
				else if (et.Decl.FindCase(op.Sub) == null)
					err(scope $"{et.Text} has no case '{op.Sub}'");
			case .Delete:
				if (op.Args.Count != 1 && op.Args.Count != 2)
					err("delete takes the object and an optional allocator");
			case .LocalArray:
				if (op.Type == null || op.Type.Kind != .Array)
					err("local.array needs an array type (T[])");
				else if (op.Slot != null && (op.Slot.Kind != .Local || op.Slot.Type != op.Type))
					err(scope $"local.array needs a slot of kind local typed {op.Type.Text}");
			case .AtomicLoad, .AtomicStore, .AtomicRmw, .AtomicCas, .Fence:
				if (!IsOrder(op.Order))
					err(scope $"'{op.Order}' is not a memory order (relaxed, acquire, release, acqrel, seqcst)");
				if (op.Kind == .Fence && op.Order == "relaxed")
					err("a fence cannot be relaxed");
				if (op.Kind == .AtomicLoad && (op.Order == "release" || op.Order == "acqrel"))
					err(scope $"an atomic load cannot be {op.Order}");
				if (op.Kind == .AtomicStore && (op.Order == "acquire" || op.Order == "acqrel"))
					err(scope $"an atomic store cannot be {op.Order}");
				if (!op.Args.IsEmpty && op.Args[0].Type.Kind != .Pointer && op.Args[0].Type.Kind != .Ref)
					err(scope $"{IRWriter.Mnemonic(op.Kind)} needs a pointer first, not {op.Args[0].Type.Text}");
				if (op.Kind == .AtomicRmw)
				{
					switch (op.Sub)
					{
					case "xchg", "add", "sub", "and", "or", "xor", "min", "max":
					default: err(scope $"unknown atomic.rmw operation '{op.Sub}'");
					}
				}
				if (op.Kind == .AtomicCas && op.Type != null && (op.Type.Kind != .Tuple || op.Type.Items.Count != 2 || op.Type.Items[1].Kind != .Bool))
					err("atomic.cas is typed (T,bool): the old value and whether it was replaced");
			case .Bind, .BindLocal:
				if (op.Type == null || op.Type.Kind != .Delegate)
					err(scope $"{IRWriter.Mnemonic(op.Kind)} needs a delegate type");
				if (op.Fn != null)
				{
					let want = op.Fn.Static ? 0 : 1;
					if (op.Args.Count != want)
						err(scope $"{IRWriter.Mnemonic(op.Kind)} of {op.Fn.Key} needs {(want == 0) ? "no target (a static function)" : "the target object"}");
					if (op.Fn.IsImport)
						err(scope $"{op.Fn.Key} is a C function: take its address (fn.addr) instead");
					// A struct function's target is the struct's address (its `this`): the delegate
					// stores that pointer and passes it back on invoke.
					if (!op.Fn.Static && op.Fn.OwnerDecl != null && op.Fn.OwnerDecl.Kind == .Struct && op.Args.Count == 1 && op.Args[0].Type.Kind != .Pointer)
						err(scope $"{op.Fn.Key} is a struct function: its target is the struct's address ({op.Fn.OwnerDecl.Name}*), not {op.Args[0].Type.Text}");
					if (op.Type != null && op.Type.Kind == .Delegate && (op.Type.Ret != op.Fn.Ret || op.Type.Items.Count != op.Fn.ParamTypes.Count))
						err(scope $"{op.Fn.Key} does not match {op.Type.Text}");
				}
				if (op.Kind == .BindLocal && op.Slot != null && (op.Slot.Kind != .Local || op.Slot.Type.Text != "Core.Delegate"))
					err("bind.local needs a slot of kind local typed Core.Delegate");
			case .Closure:
				if (op.Type == null || op.Type.Kind != .Delegate)
					err("closure needs a delegate type");
				if (!op.Args.IsEmpty && (!op.Args[0].Type.IsClass || !IsDelegateClass(op.Args[0].Type.Decl)))
					err(scope $"closure needs an object of a class derived from Core.Delegate, not {op.Args[0].Type.Text}");
				if (op.Fn != null && (op.Fn.Static || op.Fn.OwnerDecl == null || op.Args.IsEmpty || op.Fn.OwnerDecl != op.Args[0].Type.Decl))
					err(scope $"{op.Fn.Key} must be a function of the closure's class");
			case .Invoke:
				if (op.Args.IsEmpty || op.Args[0].Type.Kind != .Delegate)
					err("invoke needs a delegate first");
				else
				{
					let dt = op.Args[0].Type;
					if (op.Args.Count != dt.Items.Count + 1)
						err(scope $"invoke of {dt.Text} has {op.Args.Count - 1} arguments for {dt.Items.Count}");
					if (op.Type != dt.Ret)
						err(scope $"invoke of {dt.Text} is typed {(op.Type?.Text)}");
				}
			case .Vec, .LaneCheck:
				IRVector.CheckOp(op, err);
			default:
			}
		}
	}
}
