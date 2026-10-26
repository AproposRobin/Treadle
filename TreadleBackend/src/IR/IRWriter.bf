using System;
using System.Collections;

namespace Treadle.Backend.IR
{
	/// Writes an IRProgram as the `.tir` text dump IRReader reads (the front end's fixtures and
	/// "show the IR" for a Build). Also the one table of op mnemonics.
	static class IRWriter
	{
		static StringView[?] sMnemonics = .(
			"const", "copy", "load.slot", "store.slot", "slot.addr",
			"binop", "cmp", "cast", "select",
			"field.addr", "elem.addr", "load", "store", "nullcheck", "boundscheck", "global.addr", "array.len",
			"call", "vcall", "icall", "ccall", "fptr.call", "fn.addr",
			"alloc", "alloc.array", "local", "free", "dtor", "delete", "region.enter", "region.exit", "defer",
			"box", "unbox", "dyncast", "typeinfo",
			"make", "extract", "case.make", "enum.tag", "enum.payload",
			"sizeof", "alignof", "intrinsic",
			"local.array", "atomic.load", "atomic.store", "atomic.rmw", "atomic.cas", "fence", "bind", "bind.local", "closure", "invoke",
			"array.span",
			"vec", "lanecheck",
			"br", "condbr", "switch", "ret", "enddefer", "unreachable", "fatal");

		public static StringView Mnemonic(IROpKind kind) => sMnemonics[(int)kind];

		public static Result<IROpKind> KindOf(StringView mnemonic)
		{
			for (int i < sMnemonics.Count)
				if (sMnemonics[i] == mnemonic)
					return (IROpKind)i;
			return .Err;
		}

		/// True when the op's line carries a type after the mnemonic (calls: the return type).
		public static bool HasType(IROpKind kind)
		{
			switch (kind)
			{
			case .StoreSlot, .Store, .NullCheck, .BoundsCheck, .Free, .Dtor, .Delete, .RegionEnter, .RegionExit, .Defer,
				 .AtomicStore, .Fence, .Br, .CondBr, .Switch, .Ret, .EndDefer, .Unreachable, .Fatal:
				return false;
			default:
				return true;
			}
		}

		public static bool IsCall(IROpKind kind) => kind == .Call || kind == .VCall || kind == .ICall || kind == .CCall || kind == .FptrCall || kind == .Invoke;

		/// Ops whose result may be left unnamed (calls, and the atomics that also write memory).
		public static bool MayDiscard(IROpKind kind) => IsCall(kind) || kind == .AtomicRmw || kind == .AtomicCas;

		public static void Quote(StringView text, String outText)
		{
			outText.Append('"');
			for (let c in text.RawChars)
			{
				switch (c)
				{
				case '"': outText.Append("\\\"");
				case '\\': outText.Append("\\\\");
				case '\n': outText.Append("\\n");
				case '\t': outText.Append("\\t");
				case '\r': outText.Append("\\r");
				default:
					if ((uint8)c < 0x20)
						outText.AppendF("\\x{:X2}", (uint8)c);
					else
						outText.Append(c);
				}
			}
			outText.Append('"');
		}

		public static void Write(IRProgram p, String outText)
		{
			outText.Append("# tir 1\n");
			outText.AppendF("program {} {}\n", p.Name.IsEmpty ? "Program" : p.Name, (p.Kind == .Windowed) ? "windowed" : ((p.Kind == .Library) ? "library" : "console"));
			if (p.Entry != null)
				outText.AppendF("entry {}\n", p.Entry.Key);
			// unit-less records first, then one section per unit
			WriteSection(p, null, outText);
			for (let u in p.Units)
			{
				outText.AppendF("\nunit {}", u.Name);
				if (!u.SourcePath.IsEmpty)
				{
					outText.Append(' ');
					Quote(u.SourcePath, outText);
				}
				outText.Append('\n');
				WriteSection(p, u, outText);
			}
		}

		static void WriteSection(IRProgram p, IRUnit u, String outText)
		{
			for (let d in p.Decls)
				if (d.Unit == u && !d.Implicit && !(u == null && d.Name == "Core.Object" && d.Fields.IsEmpty && d.VTable.IsEmpty))
					WriteDecl(d, outText);
			for (let g in p.Globals)
			{
				if (g.Unit != u)
					continue;
				outText.AppendF("\nglobal {} {}", g.Text, g.Type.Text);
				if (g.Import != null)
				{
					outText.Append(" import ");
					Quote(g.Import, outText);
				}
				else if (g.Const)
				{
					outText.Append(" const");
					if (g.Elements != null)
						for (let e in g.Elements)
							outText.AppendF(" {}", e);
					else if (!g.Init.IsEmpty)
						outText.AppendF(" {}", g.Init);
				}
				else if (!g.Init.IsEmpty)
					outText.AppendF(" {}", g.Init);
				outText.Append('\n');
			}
			for (let f in p.Functions)
				if (f.Unit == u)
					WriteFunction(f, outText);
		}

		static void WriteDecl(IRTypeDecl d, String outText)
		{
			StringView kind = "class";
			switch (d.Kind)
			{
			case .Struct: kind = "struct";
			case .Enum: kind = "enum";
			case .Interface: kind = "interface";
			default:
			}
			outText.AppendF("\ntype {} {}", d.Name, kind);
			if (d.Abstract)
				outText.Append(" abstract");
			if (d.Packed)
				outText.Append(" packed");
			outText.Append('\n');
			if (d.Base != null && d.Base.Name != "Core.Object")
				outText.AppendF("\tbase {}\n", d.Base.Name);
			if (d.TagType != null)
				outText.AppendF("\ttag {}\n", d.TagType.Text);
			for (let f in d.Fields)
				outText.AppendF("\tfield {} {}{}\n", f.Name, f.Type.Text, f.Owned ? " owned" : "");
			for (let c in d.Cases)
			{
				outText.AppendF("\tcase {} = {}", c.Name, c.Value);
				for (let t in c.Payload)
					outText.AppendF(" {}", t.Text);
				outText.Append('\n');
			}
			for (let s in d.VTable)
				outText.AppendF("\tvslot {} {}\n", s.Decl?.Key ?? s.DeclKey, (s.Impl != null) ? s.Impl.Key : (s.ImplKey ?? "abstract"));
			for (let s in d.ISlots)
				outText.AppendF("\tislot {}\n", s.Key);
			for (let it in d.ITables)
			{
				outText.AppendF("\titable {}", it.Iface?.Name ?? it.IfaceName);
				for (let f in it.Impls)
					outText.AppendF(" {}", f.Key);
				outText.Append('\n');
			}
			if (d.Dtor != null)
				outText.AppendF("\tdtor {}\n", d.Dtor.Key);
		}

		static void WriteFunction(IRFunction f, String outText)
		{
			outText.AppendF("\nfunc {} {}", f.Key, f.Ret.Text);
			if (f.StaticCtor)
				outText.Append(" sctor");
			else if (f.Static && f.ImportName == null)
				outText.Append(" static");
			if (f.Virtual)
				outText.Append(" virtual");
			if (f.Abstract)
				outText.Append(" abstract");
			if (f.ImportName != null)
			{
				outText.Append(" import ");
				Quote(f.ImportName, outText);
			}
			if (f.ExportName != null)
			{
				outText.Append(" export ");
				Quote(f.ExportName, outText);
			}
			switch (f.Conv)
			{
			case .CDecl: outText.Append(" cconv cdecl");
			case .StdCall: outText.Append(" cconv stdcall");
			case .FastCall: outText.Append(" cconv fastcall");
			default:
			}
			if (!f.SheetKey.IsEmpty)
			{
				outText.Append(" sheet ");
				Quote(f.SheetKey, outText);
			}
			if (!f.Display.IsEmpty)
			{
				outText.Append(" display ");
				Quote(f.Display, outText);
			}
			outText.Append('\n');
			for (let v in f.Params)
			{
				if (!f.HasBody || (v.Name == "this" && v.ParamIndex == 0 && f.HasThis))
					continue;
				outText.AppendF("\tparam {} {}\n", v.Name, v.TypeText ?? v.Type.Text);
			}
			for (let r in f.Regions)
			{
				if (r.IsBody)
					continue;
				outText.AppendF("\tregion {}", r.Id);
				if (r.Parent != null && !r.Parent.IsBody)
					outText.AppendF(" parent {}", r.Parent.Id);
				outText.Append('\n');
			}
			for (let s in f.Slots)
			{
				StringView kind = "variable";
				switch (s.Kind)
				{
				case .Local: kind = "local";
				case .OutTemp: kind = "outtemp";
				case .LoopVar: kind = "loopvar";
				default:
				}
				outText.AppendF("\tslot {} {} {}", s.Id, s.TypeText ?? s.Type.Text, kind);
				if (!s.Name.IsEmpty)
				{
					outText.Append(' ');
					Quote(s.Name, outText);
					outText.Append((s.Shows == .Pin) ? " pin" : " local");
				}
				if (s.Region != null && !s.Region.IsBody)
					outText.AppendF(" region {}", s.Region.Id);
				if (!s.NodeId.IsEmpty)
				{
					outText.AppendF(" node {}", s.NodeId);
					if (!s.Pin.IsEmpty)
						outText.AppendF(".{}", s.Pin);
				}
				outText.Append('\n');
			}
			for (let n in f.Nodes)
			{
				outText.AppendF("\tnode {} {}", n.Id, n.Kind);
				if (!n.Subject.IsEmpty)
					outText.AppendF(" {}", n.Subject);
				outText.Append('\n');
			}
			for (let b in f.Blocks)
			{
				outText.AppendF("\tblock {}\n", b.Id);
				for (let op in b.Ops)
				{
					outText.Append("\t\t");
					WriteOp(op, outText);
					outText.Append('\n');
				}
			}
		}

		public static void WriteOp(IROp op, String outText)
		{
			if (op.Result != null)
				outText.AppendF("%{} = ", op.Result.Name);
			if (op.Kind == .Vec || op.Kind == .LaneCheck)
			{
				IRVector.WriteOp(op, outText); // `vec.<what> ...`, `lanecheck` (IRVector.bf)
				return;
			}
			outText.Append(Mnemonic(op.Kind));
			if (HasType(op.Kind) && op.Type != null)
				outText.AppendF(" {}", op.Type.Text);
			void V(int i)
			{
				if (i < op.Args.Count)
					outText.AppendF(" %{}", op.Args[i].Name);
			}
			void AllV(int from)
			{
				for (int i = from; i < op.Args.Count; i++)
					V(i);
			}
			switch (op.Kind)
			{
			case .Const:
				outText.Append(' ');
				if (op.LitIsString)
					Quote(op.Lit, outText);
				else
					outText.Append(op.Lit);
			case .LoadSlot, .SlotAddr, .Local:
				outText.AppendF(" {}", op.Slot.Id);
			case .StoreSlot:
				outText.AppendF(" {}", op.Slot.Id);
				AllV(0);
			case .Binop, .Cmp, .Intrinsic, .CaseMake:
				outText.AppendF(" {}", op.Sub);
				AllV(0);
			case .FieldAddr:
				V(0);
				outText.AppendF(" {}", op.Sub);
			case .GlobalAddr:
				outText.AppendF(" {}", op.Global.Text);
			case .Call, .VCall, .ICall, .CCall, .FnAddr:
				outText.AppendF(" {}", op.Fn.Key);
				AllV(0);
			case .RegionEnter, .RegionExit:
				outText.AppendF(" {}", op.Region.Id);
			case .Defer:
				outText.AppendF(" {} {}", op.Region.Id, op.Targets[0].Id);
			case .TypeInfo, .SizeOf, .AlignOf:
				outText.AppendF(" {}", op.TypeArg.Text);
			case .Extract:
				V(0);
				outText.AppendF(" {}", op.Index);
			case .EnumPayload:
				V(0);
				outText.AppendF(" {} {}", op.Sub, op.Index);
			case .Br:
				outText.AppendF(" {}", op.Targets[0].Id);
			case .CondBr:
				V(0);
				outText.AppendF(" {} {}", op.Targets[0].Id, op.Targets[1].Id);
			case .Switch:
				V(0);
				outText.AppendF(" {}", op.Targets[0].Id);
				for (let c in op.Cases)
					outText.AppendF(" {} {}", c.Value, c.Target.Id);
			case .Fatal:
				outText.AppendF(" {} ", op.Index);
				Quote(op.Lit, outText);
			case .LocalArray:
				outText.AppendF(" {}", op.Slot.Id);
				AllV(0);
			case .AtomicLoad, .AtomicStore, .AtomicCas, .Fence:
				outText.AppendF(" {}", op.Order);
				AllV(0);
			case .AtomicRmw:
				outText.AppendF(" {} {}", op.Sub, op.Order);
				AllV(0);
			case .Bind:
				outText.AppendF(" {}", op.Fn.Key);
				AllV(0);
			case .BindLocal:
				outText.AppendF(" {} {}", op.Slot.Id, op.Fn.Key);
				AllV(0);
			case .Closure:
				V(0);
				outText.AppendF(" {}", op.Fn.Key);
			case .EndDefer, .Unreachable:
			default:
				AllV(0);
			}
			if (!op.NodeId.IsEmpty)
			{
				outText.AppendF(" @{}", op.NodeId);
				if (!op.Pin.IsEmpty)
					outText.AppendF(".{}", op.Pin);
			}
		}
	}
}
