using System;
using System.Collections;

namespace Treadle.Compiler
{
	enum Severity : uint8
	{
		Error,
		Warning,
		Note
	}

	/// The stage that reported a diagnostic (Compiler.md 11).
	enum Stage : uint8
	{
		Load,
		Declare,
		Bind,
		Check,
		Lower,
		Toolchain
	}

	/// One compiler message (Compiler.md 11): from Declare onwards it names a type, from Bind
	/// onwards a member (its record id) and a node (its record id), and a pin when the problem is
	/// one input or output.
	class CDiag
	{
		public Severity Severity;
		/// `K` + four digits (the prefix is provisional, like the product name).
		public String Code = new .() ~ delete _;
		public String Message = new .() ~ delete _;
		public Stage Stage;
		/// The type's full name ("Game.Player"); "" for project-level messages.
		public String Type = new .() ~ delete _;
		/// The member's record id ("f8d2a"); "" when the message is about the type.
		public String Member = new .() ~ delete _;
		/// The Sheet key (`<id>`, `get:<id>`, `set:<id>`, `lambda:<node>`); "" outside Sheets.
		public String Sheet = new .() ~ delete _;
		/// The node's record id; "" when not on a node.
		public String Node = new .() ~ delete _;
		/// The pin's format name; "" when the message is about the whole node.
		public String Pin = new .() ~ delete _;
		public String File = new .() ~ delete _;
		public int32 Line;
		/// Chains: instantiation sites, the other Delete of a double free, the Local and its reader.
		public List<CDiag> Related ~ DeleteContainerAndItems!(_);

		public bool IsError => Severity == .Error;

		public CDiag AddRelated(StringView node, StringView message)
		{
			if (Related == null)
				Related = new .();
			CDiag r = new .();
			r.Severity = .Note;
			r.Stage = Stage;
			r.Type.Set(Type);
			r.Member.Set(Member);
			r.Sheet.Set(Sheet);
			r.Node.Set(node);
			r.Message.Set(message);
			r.File.Set(File);
			Related.Add(r);
			return r;
		}

		/// `Game.Player f8d2a node d4 pin b: error T2001: message` (the command line's form).
		public override void ToString(String outText)
		{
			outText.Append(Type.IsEmpty ? "(project)" : Type);
			if (!Sheet.IsEmpty)
				outText.AppendF(" {}", Sheet);
			else if (!Member.IsEmpty)
				outText.AppendF(" {}", Member);
			if (!Node.IsEmpty)
				outText.AppendF(" node {}", Node);
			if (!Pin.IsEmpty)
				outText.AppendF(" pin {}", Pin);
			outText.AppendF(": {} {}: {}", (Severity == .Error) ? "error" : ((Severity == .Warning) ? "warning" : "note"), Code, Message);
		}
	}

	/// Where a diagnostic is being reported (the context the stages pass down).
	struct DiagSite
	{
		public StringView Type;
		public StringView Member;
		public StringView Sheet;
		public StringView File;

		public this(StringView type, StringView member = "", StringView sheet = "", StringView file = "")
		{
			Type = type;
			Member = member;
			Sheet = sheet;
			File = file;
		}
	}

	/// The diagnostics of one compilation, in the order they were reported.
	class DiagBag
	{
		public List<CDiag> Items = new .() ~ DeleteContainerAndItems!(_);

		public int ErrorCount
		{
			get
			{
				int n = 0;
				for (let d in Items)
					if (d.Severity == .Error)
						n++;
				return n;
			}
		}

		public int WarningCount
		{
			get
			{
				int n = 0;
				for (let d in Items)
					if (d.Severity == .Warning)
						n++;
				return n;
			}
		}

		public CDiag Add(Severity sev, Stage stage, StringView code, in DiagSite site, StringView node, StringView pin, StringView message)
		{
			// One message per node, pin and text: the stages may reach a node twice.
			for (let d in Items)
				if (d.Severity == sev && d.Node == node && d.Pin == pin && d.Message == message && d.Type == site.Type && d.Sheet == site.Sheet)
					return d;
			CDiag d = new .();
			d.Severity = sev;
			d.Stage = stage;
			d.Code.Set(code);
			d.Type.Set(site.Type);
			d.Member.Set(site.Member);
			d.Sheet.Set(site.Sheet);
			d.File.Set(site.File);
			d.Node.Set(node);
			d.Pin.Set(pin);
			d.Message.Set(message);
			Items.Add(d);
			return d;
		}

		public void Clear() => ClearAndDeleteItems!(Items);
	}
}
