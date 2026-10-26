using System;
using System.Collections;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Language;
using Treadle.Model;

namespace Treadle.Format
{
	/// The record format of Graph-Format.md: type files (`.treadle`) and their layout sidecars
	/// (`.treadle.layout`). Reading keeps unknown records, unknown keys and comments in place;
	/// writing is canonical (members in declaration order, properties in a fixed key order,
	/// nodes by id, wires by destination), so a canonical file reads and writes back byte for
	/// byte. The canonical form is docs/Graph-Format.md 3.1 and 7.
	class TreadleCodec : IGraphCodec
	{
		public const int32 Version = 1;
		public const int MaxErrorsShown = 12;

		public StringView Extension => FormatNames.TypeExt;

		public bool Read(StringView text, TypeDocument doc, String outError)
		{
			TypeFileReader r = scope .(doc);
			if (r.Run(text))
				return true;
			JoinErrors(r.Errors, outError);
			return false;
		}

		/// Reads `text` and returns every problem found (the self test and the Problems panel).
		public static bool ReadAll(StringView text, TypeDocument doc, List<FormatError> outErrors)
		{
			TypeFileReader r = scope .(doc);
			let ok = r.Run(text);
			for (let e in r.Errors)
				outErrors.Add(e);
			r.Errors.Clear();
			return ok;
		}

		public static void JoinErrors(List<FormatError> errors, String outError)
		{
			if (outError == null)
				return;
			for (let e in errors)
			{
				if (@e.Index >= MaxErrorsShown)
				{
					outError.AppendF("\n... and {} more", errors.Count - MaxErrorsShown);
					break;
				}
				if (@e.Index > 0)
					outError.Append('\n');
				e.ToString(outError);
			}
		}

		public bool Write(TypeDocument doc, String outText, String outError)
		{
			TypeFileWriter.Write(doc, outText);
			return true;
		}

		public bool ReadLayout(StringView text, TypeDocument doc, String outError)
		{
			List<FormatError> errors = scope .();
			defer { ClearAndDeleteItems!(errors); }
			if (LayoutCodec.Read(text, doc, errors))
				return true;
			JoinErrors(errors, outError);
			return false;
		}

		public bool WriteLayout(TypeDocument doc, String outText, String outError)
		{
			LayoutCodec.Write(doc, outText);
			return true;
		}

		/// The version this build reads and writes (Version, or the self test's simulated bump).
		public static int32 Current => Migrations.Current;

		/// What a file's header says against this build (docs/Format-Stability.md 2).
		public enum HeaderState
		{
			Current,
			/// Migrated on load (Migrations).
			Older,
			/// Refused for editing: the editor opens it read-only.
			Newer,
			/// No header, or not a number (the error is added).
			Bad
		}

		/// Reads the `# <kind> <n>` header; `version` is the number on disk (0 when Bad).
		public static HeaderState ReadHeader(List<StringView> lines, StringView kind, out int32 version, List<FormatError> errors)
		{
			version = 0;
			// Readers and the front end copy tokens into `scope` strings (stack memory): a line past
			// RecordText.MaxLineLength (the longest real one is under 1 KB) refuses the whole file, so
			// a hostile file cannot overflow the stack (docs/Security-Review.md, finding 25).
			for (let line in lines)
				if (line.Length > RecordText.MaxLineLength)
				{
					AddError(errors, @line.Index + 1, "", scope $"the line is longer than {RecordText.MaxLineLength / 1024} KB");
					return .Bad;
				}
			// The current header word or its old one (FormatNames: read old forever).
			let word = lines.IsEmpty ? StringView() : FormatNames.HeaderWordIn(lines[0], kind);
			String expect = scope $"# {word} ";
			if (word.IsEmpty)
			{
				AddError(errors, 1, "", scope $"not a {FormatNames.CurrentWord(kind)} file: the first line must be '# {FormatNames.CurrentWord(kind)} {Current}'");
				return .Bad;
			}
			let num = lines[0].Substring(expect.Length);
			if (!(int32.Parse(num) case .Ok(let v)) || v < 1)
			{
				AddError(errors, 1, "", scope $"the format version '{num}' is not a number");
				return .Bad;
			}
			version = v;
			if (v > Current)
				return .Newer;
			return (v < Current) ? .Older : .Current;
		}

		/// Splits `text` into the lines a reader parses. An older file runs the migration chain
		/// first (`migrated` holds the result and the lines point into it); a newer one is refused
		/// with a `NewerVersionError` on line 1 unless `allowNewer` (the editor's read-only open).
		/// `outVersion` is the version on disk. Notes from the migration steps go to `notes`.
		public static bool Prepare(StringView text, StringView kind, List<StringView> outLines, String migrated, out int32 outVersion, bool allowNewer,
			List<FormatError> errors, List<String> notes = null)
		{
			RecordText.SplitLines(text, outLines);
			switch (ReadHeader(outLines, kind, out outVersion, errors))
			{
			case .Bad:
				return false;
			case .Newer:
				if (allowNewer)
					return true;
				let e = new NewerVersionError();
				e.Line = 1;
				e.FileVersion = outVersion;
				e.ReaderVersion = Current;
				Migrations.NewerMessage(outVersion, e.Message);
				errors.Add(e);
				return false;
			case .Older:
				if (Migrations.Run(kind, text, outVersion, migrated, notes))
				{
					outLines.Clear();
					RecordText.SplitLines(migrated, outLines);
				}
				return true;
			case .Current:
				return true;
			}
		}

		/// The newer-version refusal among `errors`, if that is why a read failed.
		public static NewerVersionError NewerIn(List<FormatError> errors)
		{
			for (let e in errors)
				if (let n = e as NewerVersionError)
					return n;
			return null;
		}

		public static void AddError(List<FormatError> errors, int line, StringView nodeKey, StringView message)
		{
			FormatError e = new .();
			e.Line = (.)line;
			e.NodeKey.Set(nodeKey);
			e.Message.Set(message);
			errors.Add(e);
		}

		public static bool ParseAccess(StringView w, out Access a)
		{
			switch (w)
			{
			case "public": a = .Public;
			case "protected": a = .Protected;
			case "private": a = .Private;
			case "internal": a = .Internal;
			default: a = .Unset; return false;
			}
			return true;
		}

		public static StringView AccessWord(Access a)
		{
			switch (a)
			{
			case .Public: return "public";
			case .Protected: return "protected";
			case .Private: return "private";
			case .Internal: return "internal";
			default: return "";
			}
		}

		public static bool ParseOwner(StringView w, out Ownership o)
		{
			switch (w)
			{
			case "owned": o = .Owned;
			case "ref": o = .Ref;
			case "appended": o = .Appended;
			case "pointer": o = .Pointer;
			case "custom": o = .Custom;
			default: o = .Unset; return false;
			}
			return true;
		}

		public static StringView OwnerWord(Ownership o)
		{
			switch (o)
			{
			case .Owned: return "owned";
			case .Ref: return "ref";
			case .Appended: return "appended";
			case .Pointer: return "pointer";
			case .Custom: return "custom";
			default: return "";
			}
		}

		public static bool ParseMode(StringView w, out ParamMode m)
		{
			switch (w)
			{
			case "value": m = .Value;
			case "ref": m = .Ref;
			case "out": m = .Out;
			case "in": m = .In;
			default: m = .Unset; return false;
			}
			return true;
		}

		public static StringView ModeWord(ParamMode m)
		{
			switch (m)
			{
			case .Value: return "value";
			case .Ref: return "ref";
			case .Out: return "out";
			case .In: return "in";
			default: return "";
			}
		}

		public static bool ParseTypeKind(StringView w, out TypeKind k)
		{
			switch (w)
			{
			case "class": k = .Class;
			case "struct": k = .Struct;
			case "interface": k = .Interface;
			case "enum": k = .Enum;
			case "delegate": k = .Delegate;
			case "extension": k = .Extension;
			default: k = .Class; return false;
			}
			return true;
		}

		public static StringView TypeKindWord(TypeKind k)
		{
			switch (k)
			{
			case .Class: return "class";
			case .Struct: return "struct";
			case .Interface: return "interface";
			case .Enum: return "enum";
			case .Delegate: return "delegate";
			case .Extension: return "extension";
			}
		}
	}

	/// Reads one type file into a TypeDocument.
	class TypeFileReader
	{
		enum Rec
		{
			None,
			Type,
			Member,
			Param,
			Out,
			Local,
			Sheet,
			Node,
			Wire,
			Group,
			Unknown
		}

		struct PendingWire
		{
			public int32 Line;
			public String FromNode;
			public String FromPin;
			public String ToNode;
			public String ToPin;
			public RecordExtras Extras;
		}

		struct PendingIn
		{
			public Node Node;
			public String Pin;
			public String Token;
		}

		class SheetState
		{
			public Sheet Sheet;
			public Graph Graph;
			public List<PendingWire> Wires = new .() ~ { for (let w in _) { delete w.FromNode; delete w.FromPin; delete w.ToNode; delete w.ToPin; delete w.Extras; } delete _; };
			public List<PendingIn> Ins = new .() ~ { for (let i in _) { delete i.Pin; delete i.Token; } delete _; };
		}

		TypeDocument mDoc;
		public List<FormatError> Errors = new .() ~ DeleteContainerAndItems!(_);
		List<StringView> mLines = new .() ~ delete _;
		/// The migrated text of an older file (mLines point into it).
		String mMigrated = new .() ~ delete _;
		List<StringView> mTok = new .() ~ delete _;
		List<StringView> mPendingComments = new .() ~ delete _;
		Dictionary<String, int32> mIds = new .() ~ DeleteDictionaryAndKeys!(_);
		List<SheetState> mSheets = new .() ~ DeleteContainerAndItems!(_);

		Rec mRec = .None;
		RecordExtras mExtras;
		String mLastKey = new .() ~ delete _;
		/// The extras of the last known record: unknown records go to its Trailing.
		RecordExtras mLastExtras;
		/// The unknown record being read (its index in mLastExtras.Trailing / the file's Leading).
		List<String> mUnknownList;
		bool mTypeSeen;
		MemberDecl mMember;
		ParamDecl mParam;
		LocalDecl mLocal;
		SheetState mSheet;
		Node mNode;
		int mLine;

		public this(TypeDocument doc)
		{
			mDoc = doc;
		}

		void Error(StringView message, StringView nodeKey = "")
		{
			TreadleCodec.AddError(Errors, mLine, nodeKey, message);
		}

		StringView CurNodeKey => (mRec == .Node && mNode != null) ? (StringView)mNode.Key : "";

		public bool Run(StringView text)
		{
			mDoc.ClearContent();
			// An older file is migrated first; a newer one reads only for the editor's read-only open.
			List<String> notes = scope .();
			defer { ClearAndDeleteItems!(notes); }
			if (!TreadleCodec.Prepare(text, FormatNames.TypeWord, mLines, mMigrated, let version, mDoc.OpenNewerReadOnly, Errors, notes))
				return false;
			mDoc.FormatVersion = version;
			mDoc.MigratedFrom = (version < TreadleCodec.Current) ? version : 0;
			for (let n in notes)
				mDoc.Messages.Add(new String(n));
			for (int i = 1; i < mLines.Count; i++)
			{
				mLine = i + 1;
				let line = mLines[i];
				if (line.IsEmpty)
					continue;
				if (line.StartsWith('#'))
				{
					mPendingComments.Add(line);
					continue;
				}
				if (line.StartsWith('\t'))
				{
					Property(line);
					continue;
				}
				if (line.StartsWith(' '))
				{
					Error("a line starts with a space (properties start with one tab)");
					continue;
				}
				Record(line);
			}
			for (let c in mPendingComments)
				mDoc.FileExtras.AddTrailing(c);
			mPendingComments.Clear();
			if (!mTypeSeen && Errors.IsEmpty)
			{
				mLine = mLines.Count;
				Error("the file has no `type` record");
			}
			for (let s in mSheets)
				FinishSheet(s);
			TypePins();
			if (!Errors.IsEmpty)
			{
				mDoc.ClearContent();
				return false;
			}
			return true;
		}

		/// Comments read since the last line that was not one go before the next known record.
		void FlushLeading(RecordExtras into)
		{
			for (let c in mPendingComments)
				into.AddLeading(c);
			mPendingComments.Clear();
		}

		void Begin(Rec rec, RecordExtras extras)
		{
			mRec = rec;
			mExtras = extras;
			mLastExtras = extras;
			mLastKey.Clear();
			FlushLeading(extras);
		}

		bool CheckId(StringView id)
		{
			if (!RecordIds.IsValid(id))
			{
				Error(scope $"'{id}' is not a valid id (1-8 characters from a-z and 0-9)");
				return false;
			}
			if (mIds.TryGetAlt(id, var key, var first))
			{
				Error(scope $"the id '{id}' is used twice (first on line {first})", id);
				return false;
			}
			mIds[new String(id)] = (.)mLine;
			return true;
		}

		bool Need(int count, StringView form)
		{
			if (mTok.Count >= count)
				return true;
			Error(scope $"expected `{form}`");
			return false;
		}

		void Record(StringView line)
		{
			mTok.Clear();
			String why = scope .();
			if (!RecordText.Tokenize(line, mTok, why))
			{
				Error(why);
				mRec = .None;
				return;
			}
			let kind = mTok[0];
			switch (kind)
			{
			case "type":
				if (mTypeSeen)
				{
					Error("a type file holds one type: a second `type` record");
					return;
				}
				if (!mDoc.Members.IsEmpty)
				{
					Error("the `type` record must come before the members");
					return;
				}
				if (!Need(3, "type <Name> <kind>"))
					return;
				mTypeSeen = true;
				let h = mDoc.Header;
				RecordText.Unquote(mTok[1], h.Name);
				if (!TreadleCodec.ParseTypeKind(mTok[2], out h.Kind))
					Error(scope $"'{mTok[2]}' is not a type kind (class, struct, interface, enum, delegate, extension)");
				Begin(.Type, h.Extras);
			case "field", "case", "property", "function", "ctor", "dtor", "operator":
				MemberRecord(kind);
			case "param", "out":
				if (mMember == null || !(mMember.IsCallable || mMember.Kind == .Property))
				{
					Error(scope $"`{kind}` outside a function");
					return;
				}
				if (!Need(3, scope $"{kind} <name> <Type>"))
					return;
				ParamDecl p = new .();
				RecordText.Unquote(mTok[1], p.Name);
				p.Type = TypeRef.Parse(mTok[2]);
				(kind == "param" ? mMember.Params : mMember.Outs).Add(p);
				mParam = p;
				Begin((kind == "param") ? .Param : .Out, p.Extras);
			case "local":
				if (mMember == null || !mMember.IsCallable && mMember.Kind != .Property)
				{
					Error("`local` outside a function");
					return;
				}
				if (!Need(3, "local <name> <Type>"))
					return;
				LocalDecl l = new .();
				RecordText.Unquote(mTok[1], l.Name);
				l.Type = TypeRef.Parse(mTok[2]);
				mMember.Locals.Add(l);
				mLocal = l;
				Begin(.Local, l.Extras);
			case "sheet":
				SheetRecord();
			case "node":
				NodeRecord(line);
			case "wire":
				WireRecord();
			case "group":
				GroupRecord();
			default:
				UnknownRecord(line);
			}
		}

		NodeGroup mGroup;

		/// `group <id> ["title"]`: a collapsed node group of the Sheet; its `node <id>` lines follow.
		void GroupRecord()
		{
			if (mSheet == null)
			{
				Error("`group` outside a Sheet");
				return;
			}
			if (!Need(2, "group <id> [\"title\"]") || !CheckId(mTok[1]))
			{
				mRec = .None;
				return;
			}
			NodeGroup gr = new .();
			gr.Key.Set(mTok[1]);
			if (mTok.Count > 2)
				RecordText.Unquote(mTok[2], gr.Title);
			mSheet.Graph.Groups.Add(gr);
			mGroup = gr;
			Begin(.Group, gr.Extras);
		}

		void UnknownRecord(StringView line)
		{
			mDoc.UnknownCount++;
			List<String> into;
			if (mLastExtras != null)
			{
				if (mLastExtras.Trailing == null)
					mLastExtras.Trailing = new .();
				into = mLastExtras.Trailing;
			}
			else
			{
				if (mDoc.FileExtras.Leading == null)
					mDoc.FileExtras.Leading = new .();
				into = mDoc.FileExtras.Leading;
			}
			for (let c in mPendingComments)
				into.Add(new String(c));
			mPendingComments.Clear();
			into.Add(new String(line));
			mUnknownList = into;
			mRec = .Unknown;
		}

		void MemberRecord(StringView kind)
		{
			if (!mTypeSeen)
			{
				Error("a member before the `type` record");
				return;
			}
			MemberDecl m = new .();
			switch (kind)
			{
			case "field":
				m.Kind = .Field;
				if (!Need(3, "field <name> <Type>")) { delete m; return; }
				RecordText.Unquote(mTok[1], m.Name);
				m.Type = TypeRef.Parse(mTok[2]);
			case "case":
				m.Kind = .Case;
				if (!Need(2, "case <Name> [= value]")) { delete m; return; }
				RecordText.Unquote(mTok[1], m.Name);
				if (mTok.Count >= 4 && mTok[2] == "=")
					m.CaseValue = new String(mTok[3]);
				else if (mTok.Count > 2)
				{
					Error("expected `case <Name> = <value>`");
					delete m;
					return;
				}
			case "property":
				m.Kind = .Property;
				if (!Need(4, "property <id> <name> <Type>") || !CheckId(mTok[1])) { delete m; return; }
				m.Id.Set(mTok[1]);
				RecordText.Unquote(mTok[2], m.Name);
				m.Type = TypeRef.Parse(mTok[3]);
			case "function", "operator":
				m.Kind = (kind == "function") ? .Function : .Operator;
				if (!Need(3, scope $"{kind} <id> <name>") || !CheckId(mTok[1])) { delete m; return; }
				m.Id.Set(mTok[1]);
				RecordText.Unquote(mTok[2], m.Name);
			case "ctor", "dtor":
				m.Kind = (kind == "ctor") ? .Ctor : .Dtor;
				if (!Need(2, scope $"{kind} <id>") || !CheckId(mTok[1])) { delete m; return; }
				m.Id.Set(mTok[1]);
			}
			mDoc.Members.Add(m);
			mMember = m;
			mSheet = null;
			Begin(.Member, m.Extras);
		}

		void SheetRecord()
		{
			if (mMember == null || !(mMember.IsCallable || mMember.Kind == .Property))
			{
				Error("`sheet` outside a function or property");
				return;
			}
			if (!Need(2, "sheet get|set|body|lambda:<nodeid>"))
				return;
			let w = mTok[1];
			SheetRole role;
			StringView lambda = "";
			if (w == "body")
				role = .Body;
			else if (w == "get")
				role = .Get;
			else if (w == "set")
				role = .Set;
			else if (w.StartsWith("lambda:"))
			{
				role = .Lambda;
				lambda = w.Substring(7);
			}
			else
			{
				Error(scope $"'{w}' is not a Sheet kind (body, get, set, lambda:<nodeid>)");
				return;
			}
			let s = mDoc.NewSheet(mMember, role, lambda);
			for (let o in mSheets)
				if (o.Sheet.Key == s.Key)
					Error(scope $"the Sheet '{w}' appears twice in this member");
			SheetState st = new .();
			st.Sheet = s;
			st.Graph = new Graph();
			s.AttachGraph(st.Graph);
			mSheets.Add(st);
			mSheet = st;
			mNode = null;
			Begin(.Sheet, s.Extras);
		}

		void NodeRecord(StringView line)
		{
			if (mSheet == null)
			{
				Error("`node` outside a Sheet (a `sheet` record must come first)");
				return;
			}
			if (!Need(3, "node <id> <Kind> [subject]") || !CheckId(mTok[1]))
			{
				mRec = .None;
				return;
			}
			let subject = RecordText.RestAfter(line, 3);
			let kind = NodeKinds.Parse(Aliases.Kind(mTok[2]), !subject.IsEmpty); // a renamed kind reads as its current word
			let g = mSheet.Graph;
			Node n = g.AddNode(kind);
			n.Key.Set(mTok[1]);
			n.Line = (.)mLine;
			if (kind == .Unknown)
			{
				n.KindWord = new String(mTok[2]);
				mDoc.UnknownCount++;
				n.Text.Set(subject);
			}
			else if (NodeKinds.HasTypeSubject(kind))
				n.SetSubjectTypeText(subject);
			else
				n.Text.Set(subject);
			if (kind == .Entry && g.Entry == null)
				g.Entry = n;
			mNode = n;
			Begin(.Node, n.Extras);
		}

		static bool SplitEnd(StringView s, out StringView node, out StringView pin)
		{
			let dot = s.IndexOf('.');
			if (dot <= 0 || dot == s.Length - 1)
			{
				node = default;
				pin = default;
				return false;
			}
			node = s.Substring(0, dot);
			pin = s.Substring(dot + 1);
			return true;
		}

		void WireRecord()
		{
			if (mSheet == null)
			{
				Error("`wire` outside a Sheet");
				return;
			}
			if (!Need(3, "wire <from>.<pin> <to>.<pin>"))
				return;
			StringView fn, fp, tn, tp;
			// An end whose pin name needs quoting is one string token (Graph-Format.md 2).
			let fromText = RecordText.Unquote(mTok[1], .. scope String());
			let toText = RecordText.Unquote(mTok[2], .. scope String());
			let okFrom = SplitEnd(fromText, out fn, out fp);
			let okTo = SplitEnd(toText, out tn, out tp);
			if (!okFrom || !okTo)
			{
				Error("expected `wire <fromId>.<pin> <toId>.<pin>`");
				return;
			}
			PendingWire w;
			w.Line = (.)mLine;
			w.FromNode = new .(fn);
			w.FromPin = new .(fp);
			w.ToNode = new .(tn);
			w.ToPin = new .(tp);
			w.Extras = new .();
			mSheet.Wires.Add(w);
			Begin(.Wire, w.Extras);
		}

		/// A property line of the current record.
		void Property(StringView line)
		{
			if (mRec == .Unknown)
			{
				mUnknownList.Add(new String(line));
				return;
			}
			if (mRec == .None)
			{
				Error("a property line (it starts with a tab) outside a record");
				return;
			}
			// Comments inside the record stay after the property they followed.
			for (let c in mPendingComments)
				mExtras.AddInner(mLastKey, c);
			mPendingComments.Clear();
			mTok.Clear();
			String why = scope .();
			if (!RecordText.Tokenize(line.Substring(1), mTok, why))
			{
				Error(why, CurNodeKey);
				return;
			}
			if (mTok.IsEmpty)
				return;
			let key = mTok[0];
			bool known;
			switch (mRec)
			{
			case .Type: known = TypeProp(line);
			case .Member: known = MemberProp(line);
			case .Param, .Out: known = ParamProp();
			case .Local: known = LocalProp();
			case .Node: known = NodeProp(line);
			case .Group:
				known = key == "node" && mTok.Count >= 2;
				if (known)
					mGroup.Nodes.Add(new String(mTok[1]));
			default: known = false;
			}
			if (!known)
			{
				mExtras.AddInner(mLastKey, line);
				mDoc.UnknownCount++;
				return;
			}
			mLastKey.Set((mRec == .Node && key != "in" && key != "comment" && key != "disabled" && key != "unsafe" && key != "set") ? "set" : key);
		}

		String Str(StringView token) => RecordText.Unquote(token, .. new String());

		bool AttrProp(List<AttrDecl> into)
		{
			if (!Need(2, "attr <Name> [args...]"))
				return true;
			AttrDecl a = new .();
			a.Name.Set(mTok[1]);
			for (int i = 2; i < mTok.Count; i++)
				a.Args.Add(new String(mTok[i]));
			into.Add(a);
			return true;
		}

		bool GenericProp(List<GenericParam> into)
		{
			if (!Need(2, "generic <T> [constraints...]"))
				return true;
			GenericParam g = new .();
			int i = 1;
			if (mTok[1] == "const" && mTok.Count >= 4)
			{
				g.IsConst = true;
				g.Name.Set(mTok[2]);
				g.ConstType = TypeRef.Parse(mTok[3]);
				i = 4;
			}
			else
			{
				g.Name.Set(mTok[1]);
				i = 2;
			}
			for (; i < mTok.Count; i++)
				g.AddConstraint(mTok[i]);
			into.Add(g);
			return true;
		}

		bool Flag(ref bool flag)
		{
			flag = true;
			return true;
		}

		bool TypeProp(StringView line)
		{
			let h = mDoc.Header;
			let key = mTok[0];
			StringView arg = (mTok.Count > 1) ? mTok[1] : "";
			switch (key)
			{
			case "namespace": h.Namespace.Set(arg);
			case "uses": h.Uses.Add(new String(arg));
			case "base": DeleteAndNullify!(h.Base); h.Base = TypeRef.Parse(arg);
			case "implements": h.Implements.Add(TypeRef.Parse(arg));
			case "generic": return GenericProp(h.Generics);
			case "access":
				if (!TreadleCodec.ParseAccess(arg, out h.Access))
					Error(scope $"'{arg}' is not an access level (public, protected, private, internal)");
			case "abstract": h.Abstract = true;
			case "sealed": h.Sealed = true;
			case "static": h.Static = true;
			case "underlying": DeleteAndNullify!(h.Underlying); h.Underlying = TypeRef.Parse(arg);
			case "extends": DeleteAndNullify!(h.Extends); h.Extends = TypeRef.Parse(arg);
			case "signature": DeleteAndNullify!(h.Signature); h.Signature = TypeRef.ParseSignature(arg);
			case "attr": return AttrProp(h.Attrs);
			case "doc": DeleteAndNullify!(h.Doc); h.Doc = Str(arg);
			default: return false;
			}
			return true;
		}

		bool MemberProp(StringView line)
		{
			let m = mMember;
			let key = mTok[0];
			StringView arg = (mTok.Count > 1) ? mTok[1] : "";
			switch (key)
			{
			case "access":
				if (!TreadleCodec.ParseAccess(arg, out m.Access))
					Error(scope $"'{arg}' is not an access level (public, protected, private, internal)");
				return true;
			case "static": return Flag(ref m.Static);
			case "attr": return AttrProp(m.Attrs);
			case "doc": DeleteAndNullify!(m.Doc); m.Doc = Str(arg); return true;
			default:
			}
			switch (m.Kind)
			{
			case .Field:
				switch (key)
				{
				case "const": return Flag(ref m.Const);
				case "readonly": return Flag(ref m.Readonly);
				case "init": DeleteAndNullify!(m.Init); m.Init = new String(RecordText.RestAfter(line.Substring(1), 1)); return true;
				case "elements": DeleteAndNullify!(m.Elements); m.Elements = new String(RecordText.RestAfter(line.Substring(1), 1)); return true;
				case "owner":
					if (!TreadleCodec.ParseOwner(arg, out m.Owner))
						Error(scope $"'{arg}' is not an ownership (owned, ref, appended, pointer, custom)");
					return true;
				case "category": DeleteAndNullify!(m.Category); m.Category = Str(arg); return true;
				default: return false;
				}
			case .Case:
				if (key == "payload")
				{
					if (!Need(3, "payload <name> <Type>"))
						return true;
					ParamDecl p = new .();
					RecordText.Unquote(mTok[1], p.Name);
					p.Type = TypeRef.Parse(mTok[2]);
					m.Payload.Add(p);
					return true;
				}
				return false;
			case .Property:
				if (key == "auto")
					return Flag(ref m.Auto);
				return false;
			case .Ctor, .Dtor:
				if (key == "chain")
				{
					if (arg == "base")
						m.Chain = .Base;
					else if (arg == "this")
						m.Chain = .This;
					else
						Error("expected `chain base` or `chain this`");
					return true;
				}
				return false;
			case .Function, .Operator:
				switch (key)
				{
				case "returns": DeleteAndNullify!(m.Returns); m.Returns = TypeRef.Parse(arg); return true;
				case "virtual": return Flag(ref m.Virtual);
				case "abstract": return Flag(ref m.Abstract);
				case "override": return Flag(ref m.Override);
				case "sealed": return Flag(ref m.Sealed);
				case "pure": return Flag(ref m.Pure);
				case "unsafe": return Flag(ref m.Unsafe);
				case "mutating": return Flag(ref m.Mutating);
				case "inline": return Flag(ref m.Inline);
				case "generic": return GenericProp(m.Generics);
				case "cconv": DeleteAndNullify!(m.CallConv); m.CallConv = new String(arg); return true;
				default: return false;
				}
			}
		}

		bool ParamProp()
		{
			if (mRec == .Out)
				return false;
			StringView arg = (mTok.Count > 1) ? mTok[1] : "";
			switch (mTok[0])
			{
			case "mode":
				if (!TreadleCodec.ParseMode(arg, out mParam.Mode))
					Error(scope $"'{arg}' is not a passing mode (value, ref, out, in)");
			case "default": DeleteAndNullify!(mParam.Default); mParam.Default = new String(arg);
			default: return false;
			}
			return true;
		}

		bool LocalProp()
		{
			StringView arg = (mTok.Count > 1) ? mTok[1] : "";
			switch (mTok[0])
			{
			case "init": DeleteAndNullify!(mLocal.Init); mLocal.Init = new String(arg);
			case "owner":
				if (!TreadleCodec.ParseOwner(arg, out mLocal.Owner))
					Error(scope $"'{arg}' is not an ownership (owned, ref)");
			default: return false;
			}
			return true;
		}

		bool NodeProp(StringView line)
		{
			let n = mNode;
			let key = mTok[0];
			let body = line.Substring(1);
			switch (key)
			{
			case "in":
				if (!Need(3, "in <pin> <token>"))
				{
					Errors.Back.NodeKey.Set(n.Key);
					return true;
				}
				PendingIn p;
				p.Node = n;
				p.Pin = RecordText.TextOf(mTok[1]);
				p.Token = new .(RecordText.RestAfter(body, 2));
				mSheet.Ins.Add(p);
			case "set":
				if (!Need(2, "set <key> [tokens...]"))
				{
					Errors.Back.NodeKey.Set(n.Key);
					return true;
				}
				NodeSetting s = new .();
				s.Key.Set(mTok[1]);
				s.Value.Set(RecordText.RestAfter(body, 2));
				n.Settings.Add(s);
			case "comment":
				DeleteAndNullify!(n.Comment);
				n.Comment = Str((mTok.Count > 1) ? mTok[1] : "");
			case "disabled": n.Disabled = true;
			case "unsafe": n.Unsafe = true;
			default:
				// Kind-specific lines (`case <label>`, `capture <name> by-ref`) and keys of a newer
				// format: kept in order with the settings.
				NodeSetting s = new .();
				s.Key.Set(key);
				// A Switch's `case <label>` holds free text: one string token is unquoted.
				if (key == "case" && mTok.Count == 2)
					RecordText.Unquote(mTok[1], s.Value);
				else
					s.Value.Set(RecordText.RestAfter(body, 1));
				s.IsSet = false;
				n.Settings.Add(s);
			}
			return true;
		}

		// ------------------------------------------------------------------ pins and wires

		static bool IsFlowName(StringView name)
		{
			if (name == "in" || name == "then" || name == "done" || name == "body" || name == "default" || name == "deferred" || name == "failed")
				return true;
			return name.StartsWith("case:") && !name.Contains('.');
		}

		static bool TakesArgs(NodeKind k)
		{
			switch (k)
			{
			case .Call, .Invoke, .Intrinsic, .Construct, .Local, .ChainCtor, .Make, .MakeCase, .Math, .Lambda, .Bind:
				return true;
			default:
				return false;
			}
		}

		static Pin AddPinFor(Graph g, Node n, bool input, PinKind kind, StringView name)
		{
			String label = scope .();
			if (n.Kind == .Entry)
				label.Set(name);
			else
				NodeFactory.LabelFor(name, label);
			let p = g.AddPin(n, input, kind, name, label);
			if (kind == .Value && TakesArgs(n.Kind))
				p.Role = input ? .Arg : .Result;
			if (kind == .Flow && !input && name != "then" && name != "done")
				p.Role = .Body;
			if (input && name == "receiver")
			{
				p.Role = .Receiver;
				p.Optional = true;
			}
			return p;
		}

		void FinishSheet(SheetState st)
		{
			let g = st.Graph;
			let s = st.Sheet;
			// A Call or Intrinsic is a flow call when a wire uses its `in` or `then`.
			for (let n in g.Nodes)
			{
				if (n.Kind != .Call && n.Kind != .Intrinsic)
					continue;
				bool flow = false;
				for (let w in st.Wires)
					if ((w.ToNode == n.Key && w.ToPin == "in") || (w.FromNode == n.Key && w.FromPin == "then"))
						flow = true;
				n.IsPure = !flow;
				if (n.Text.StartsWith("this."))
					n.Binding = .Instance;
			}
			for (let n in g.Nodes)
			{
				NodeFactory.Shape(g, n);
				if (n.Kind == .Entry)
					mDoc.AddEntryParams(s, g, n);
				else if (n.Kind == .Return && s.Member != null)
				{
					for (let o in s.Member.Outs)
						if (n.FindInput(o.Name) == null)
							AddPinFor(g, n, true, .Value, o.Name).SetType(TypeRef.CloneOrNull(o.Type));
				}
			}
			// Renamed pins (Aliases) read as their current names.
			for (let i in st.Ins)
			{
				let m = Aliases.Pin(NodeKinds.Word(i.Node.Kind), i.Pin, scope String());
				if (m != i.Pin)
					i.Pin.Set(m);
			}
			for (let i in st.Ins)
			{
				var p = i.Node.FindInput(i.Pin);
				if (p == null)
					p = AddPinFor(g, i.Node, true, .Value, i.Pin);
				p.Default.Set(i.Token);
			}
			for (let w in st.Wires)
			{
				mLine = w.Line;
				let from = g.FindNodeByKey(w.FromNode);
				let to = g.FindNodeByKey(w.ToNode);
				if (from == null || to == null)
				{
					Error(scope $"the wire names node '{(from == null) ? w.FromNode : w.ToNode}', which is not in this Sheet",
						(from == null) ? w.ToNode : w.FromNode);
					continue;
				}
				let fm = Aliases.Pin(NodeKinds.Word(from.Kind), w.FromPin, scope String());
				if (fm != w.FromPin)
					w.FromPin.Set(fm);
				let tm = Aliases.Pin(NodeKinds.Word(to.Kind), w.ToPin, scope String());
				if (tm != w.ToPin)
					w.ToPin.Set(tm);
				var fp = from.FindOutput(w.FromPin);
				var tp = to.FindInput(w.ToPin);
				if (fp == null && tp == null)
				{
					let kind = (IsFlowName(w.FromPin) || IsFlowName(w.ToPin)) ? PinKind.Flow : PinKind.Value;
					fp = AddPinFor(g, from, false, kind, w.FromPin);
					tp = AddPinFor(g, to, true, kind, w.ToPin);
				}
				else if (fp == null)
					fp = AddPinFor(g, from, false, tp.Kind, w.FromPin);
				else if (tp == null)
					tp = AddPinFor(g, to, true, fp.Kind, w.ToPin);
				if (fp.Kind != tp.Kind)
				{
					Error(scope $"the wire joins a flow pin and a value pin ({w.FromNode}.{w.FromPin} -> {w.ToNode}.{w.ToPin})", w.ToNode);
					continue;
				}
				let link = g.AddLinkRaw(fp, tp);
				if (!w.Extras.IsEmpty)
				{
					link.Extras = w.Extras;
					// The pending list no longer owns it.
					st.Wires[@w.Index].Extras = null;
				}
			}
			// Split struct pins: the sub-pins the wires and `in` lines made go right after their pin.
			for (let n in g.Nodes)
				if (n.FindSetting(SplitPins.Key) != null)
					SplitPins.Normalize(n);
			// Collapsed node groups: their canvas handles.
			for (let gr in g.Groups)
				gr.Id = -g.NewId();
		}

		/// Types of pins the file itself declares: Entry parameters (done), Return values, Get /
		/// Set of the type's own fields and properties.
		void TypePins()
		{
			for (let st in mSheets)
			{
				let s = st.Sheet;
				for (let n in st.Graph.Nodes)
				{
					if (n.Kind == .Return && s.Member != null)
					{
						let v = n.FindInput("value");
						TypeRef t = (s.Role == .Get) ? s.Member.Type : s.Member.Returns;
						if (v != null && t != null && !t.IsVoid)
							v.SetType(t.Clone());
					}
					else if ((n.Kind == .Get || n.Kind == .Set) && n.Text.StartsWith("this."))
					{
						let m = mDoc.FindMember(StringView(n.Text, 5));
						if (m != null && m.Type != null && (m.Kind == .Field || m.Kind == .Property))
						{
							n.FindOutput("value")?.SetType(m.Type.Clone());
							n.FindInput("value")?.SetType(m.Type.Clone());
							if (n.Kind == .Set)
								n.FindOutput("result")?.SetType(m.Type.Clone());
						}
					}
				}
			}
		}
	}

	/// Writes a TypeDocument in canonical form.
	static class TypeFileWriter
	{
		static void Lines(List<String> lines, String outText)
		{
			if (lines != null)
				for (let l in lines)
					outText.AppendF("{}\n", l);
		}

		static void Open(RecordExtras e, StringView recordLine, String outText)
		{
			if (e != null)
				Lines(e.Leading, outText);
			outText.AppendF("{}\n", recordLine);
		}

		static void Close(PropWriter pw, RecordExtras e, String outText)
		{
			pw.Emit(e, outText);
			if (e != null)
				Lines(e.Trailing, outText);
		}

		static void TypeText(TypeRef t, String outText)
		{
			if (t != null)
				t.ToString(outText);
		}

		static void Attrs(PropWriter pw, List<AttrDecl> attrs)
		{
			for (let a in attrs)
			{
				String v = scope .(a.Name);
				for (let arg in a.Args)
					v.AppendF(" {}", arg);
				pw.Add("attr", v);
			}
		}

		static void Generics(PropWriter pw, List<GenericParam> gens)
		{
			for (let g in gens)
			{
				String v = scope .();
				if (g.IsConst)
				{
					v.AppendF("const {} ", g.Name);
					TypeText(g.ConstType, v);
				}
				else
					v.Append(g.Name);
				for (let c in g.Constraints)
				{
					v.Append(' ');
					if (c.Kind == .Type)
						TypeText(c.Type, v);
					else
						v.Append(c.Word);
				}
				pw.Add("generic", v);
			}
		}

		static void Doc(PropWriter pw, String doc)
		{
			if (doc != null)
				pw.AddString("doc", doc);
		}

		public static void Write(TypeDocument doc, String outText)
		{
			outText.AppendF("# treadle {}\n", TreadleCodec.Current);
			Lines(doc.FileExtras.Leading, outText);
			WriteHeader(doc.Header, outText);
			for (let m in doc.Members)
			{
				outText.Append('\n');
				WriteMember(doc, m, outText);
			}
			Lines(doc.FileExtras.Trailing, outText);
		}

		static void WriteHeader(TypeDecl h, String outText)
		{
			Open(h.Extras, scope $"type {RecordText.Text(h.Name, .. scope String())} {TreadleCodec.TypeKindWord(h.Kind)}", outText);
			PropWriter pw = scope .();
			if (!h.Namespace.IsEmpty)
				pw.Add("namespace", h.Namespace);
			for (let u in h.Uses)
				pw.Add("uses", u);
			if (h.Base != null)
				pw.Add("base", h.Base.ToString(.. scope String()));
			for (let i in h.Implements)
				pw.Add("implements", i.ToString(.. scope String()));
			Generics(pw, h.Generics);
			if (h.Access != .Unset)
				pw.Add("access", TreadleCodec.AccessWord(h.Access));
			if (h.Abstract)
				pw.Add("abstract");
			if (h.Sealed)
				pw.Add("sealed");
			if (h.Static)
				pw.Add("static");
			if (h.Underlying != null)
				pw.Add("underlying", h.Underlying.ToString(.. scope String()));
			if (h.Extends != null)
				pw.Add("extends", h.Extends.ToString(.. scope String()));
			if (h.Signature != null)
			{
				String sig = scope .();
				if (h.Signature.Kind == .Raw)
					sig.Append(h.Signature.Name);
				else
					h.Signature.AppendSignature(sig);
				pw.Add("signature", sig);
			}
			Attrs(pw, h.Attrs);
			Doc(pw, h.Doc);
			Close(pw, h.Extras, outText);
		}

		static void WriteMember(TypeDocument doc, MemberDecl m, String outText)
		{
			String line = scope .();
			line.Append(MemberDecl.KindWord(m.Kind));
			switch (m.Kind)
			{
			case .Field:
				line.AppendF(" {} ", RecordText.Text(m.Name, .. scope String()));
				TypeText(m.Type, line);
			case .Case:
				line.AppendF(" {}", RecordText.Text(m.Name, .. scope String()));
				if (m.CaseValue != null)
					line.AppendF(" = {}", m.CaseValue);
			case .Property:
				line.AppendF(" {} {} ", m.Id, RecordText.Text(m.Name, .. scope String()));
				TypeText(m.Type, line);
			case .Function, .Operator:
				line.AppendF(" {} {}", m.Id, RecordText.Text(m.Name, .. scope String()));
			case .Ctor, .Dtor:
				line.AppendF(" {}", m.Id);
			}
			Open(m.Extras, line, outText);
			PropWriter pw = scope .();
			// Fixed key order: modifiers, access, the kind's own keys, attributes, doc.
			if (m.Static)
				pw.Add("static");
			switch (m.Kind)
			{
			case .Field:
				if (m.Const)
					pw.Add("const");
				if (m.Readonly)
					pw.Add("readonly");
			case .Property:
				if (m.Auto)
					pw.Add("auto");
			case .Function, .Operator:
				if (m.Virtual) pw.Add("virtual");
				if (m.Abstract) pw.Add("abstract");
				if (m.Override) pw.Add("override");
				if (m.Sealed) pw.Add("sealed");
				if (m.Pure) pw.Add("pure");
				if (m.Unsafe) pw.Add("unsafe");
				if (m.Mutating) pw.Add("mutating");
				if (m.Inline) pw.Add("inline");
			default:
			}
			if (m.Access != .Unset)
				pw.Add("access", TreadleCodec.AccessWord(m.Access));
			switch (m.Kind)
			{
			case .Field:
				if (m.Init != null)
					pw.Add("init", m.Init);
				if (m.Elements != null)
					pw.Add("elements", m.Elements);
				if (m.Owner != .Unset)
					pw.Add("owner", TreadleCodec.OwnerWord(m.Owner));
				if (m.Category != null)
					pw.AddString("category", m.Category);
			case .Case:
				for (let p in m.Payload)
					pw.Add("payload", scope $"{RecordText.Text(p.Name, .. scope String())} {p.Type?.ToString(.. scope String())}");
			case .Ctor, .Dtor:
				if (m.Chain != .None)
					pw.Add("chain", (m.Chain == .Base) ? "base" : "this");
			case .Function, .Operator:
				if (m.Returns != null)
					pw.Add("returns", m.Returns.ToString(.. scope String()));
				Generics(pw, m.Generics);
				if (m.CallConv != null)
					pw.Add("cconv", m.CallConv);
			default:
			}
			Attrs(pw, m.Attrs);
			Doc(pw, m.Doc);
			Close(pw, m.Extras, outText);

			for (let p in m.Params)
				WriteParam("param", p, outText);
			for (let p in m.Outs)
				WriteParam("out", p, outText);
			for (let l in m.Locals)
			{
				Open(l.Extras, scope $"local {RecordText.Text(l.Name, .. scope String())} {l.Type?.ToString(.. scope String())}", outText);
				PropWriter lw = scope .();
				if (l.Init != null)
					lw.Add("init", l.Init);
				if (l.Owner != .Unset)
					lw.Add("owner", TreadleCodec.OwnerWord(l.Owner));
				Close(lw, l.Extras, outText);
			}
			// Accessor and body Sheets first, then lambda bodies, each in document order.
			for (int pass < 2)
				for (let s in doc.Sheets)
					if (s.Member == m && ((s.Role == .Lambda) == (pass == 1)))
						WriteSheet(s, outText);
		}

		static void WriteParam(StringView kind, ParamDecl p, String outText)
		{
			Open(p.Extras, scope $"{kind} {RecordText.Text(p.Name, .. scope String())} {p.Type?.ToString(.. scope String())}", outText);
			PropWriter pw = scope .();
			if (p.Mode != .Unset)
				pw.Add("mode", TreadleCodec.ModeWord(p.Mode));
			if (p.Default != null)
				pw.Add("default", p.Default);
			Close(pw, p.Extras, outText);
		}

		static StringView RoleWord(Sheet s, String buf)
		{
			switch (s.Role)
			{
			case .Body: return "body";
			case .Get: return "get";
			case .Set: return "set";
			case .Lambda:
				buf.AppendF("lambda:{}", s.LambdaNode);
				return buf;
			}
		}

		static void WriteSheet(Sheet s, String outText)
		{
			String roleBuf = scope .();
			let role = RoleWord(s, roleBuf);
			Open(s.Extras, scope $"sheet {role}", outText);
			PropWriter sw = scope .();
			Close(sw, s.Extras, outText);
			let g = s.Graph;
			List<Node> nodes = scope .();
			nodes.AddRange(g.Nodes);
			nodes.Sort(scope (a, b) => RecordText.CompareOrdinal(a.Key, b.Key));
			for (let n in nodes)
				WriteNode(n, outText);
			List<Link> wires = scope .();
			wires.AddRange(g.Links);
			wires.Sort(scope (a, b) =>
				{
					int c = RecordText.CompareOrdinal(a.To.Owner.Key, b.To.Owner.Key);
					if (c == 0) c = RecordText.CompareOrdinal(a.To.Name, b.To.Name);
					if (c == 0) c = RecordText.CompareOrdinal(a.From.Owner.Key, b.From.Owner.Key);
					if (c == 0) c = RecordText.CompareOrdinal(a.From.Name, b.From.Name);
					return c;
				});
			for (let l in wires)
			{
				Open(l.Extras, scope $"wire {RecordText.End(l.From.Owner.Key, l.From.Name, .. scope String())} {RecordText.End(l.To.Owner.Key, l.To.Name, .. scope String())}", outText);
				PropWriter ww = scope .();
				Close(ww, l.Extras, outText);
			}
			// Collapsed node groups by id, their members by id (members whose node is gone are left out).
			List<NodeGroup> groups = scope .();
			groups.AddRange(g.Groups);
			groups.Sort(scope (a, b) => RecordText.CompareOrdinal(a.Key, b.Key));
			for (let gr in groups)
			{
				List<StringView> members = scope .();
				for (let k in gr.Nodes)
					if (g.FindNodeByKey(k) != null && !members.Contains(k))
						members.Add(k);
				if (members.IsEmpty)
					continue;
				members.Sort(scope (a, b) => RecordText.CompareOrdinal(a, b));
				String line = scope $"group {gr.Key}";
				if (!gr.Title.IsEmpty)
				{
					line.Append(' ');
					RecordText.Quote(gr.Title, line);
				}
				Open(gr.Extras, line, outText);
				PropWriter gw = scope .();
				for (let k in members)
					gw.Add("node", k);
				Close(gw, gr.Extras, outText);
			}
		}

		static void WriteNode(Node n, String outText)
		{
			String line = scope .();
			line.AppendF("node {} {}", n.Key, (n.Kind == .Unknown && n.KindWord != null) ? (StringView)n.KindWord : NodeKinds.Word(n.Kind));
			if (!n.Text.IsEmpty)
				line.AppendF(" {}", n.Text);
			Open(n.Extras, line, outText);
			PropWriter pw = scope .();
			for (let s in n.Settings)
			{
				if (s.IsSet)
					pw.Add("set", s.Value.IsEmpty ? (StringView)s.Key : scope:: $"{s.Key} {s.Value}");
				else if (s.Key == "case")
					pw.AddGrouped("set", s.Key, RecordText.Text(s.Value, .. scope:: String()));
				else
					pw.AddGrouped("set", s.Key, s.Value);
			}
			for (let p in n.Inputs)
				if (!p.Default.IsEmpty)
					pw.Add("in", scope $"{RecordText.Text(p.Name, .. scope String())} {p.Default}");
			if (n.Comment != null)
				pw.AddString("comment", n.Comment);
			if (n.Disabled)
				pw.Add("disabled");
			if (n.Unsafe)
				pw.Add("unsafe");
			Close(pw, n.Extras, outText);
		}
	}
}
