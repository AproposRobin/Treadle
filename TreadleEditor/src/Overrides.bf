using System;
using System.Collections;
using ImGui;
using Treadle.Document;
using Treadle.Model;

namespace Treadle.Editor
{
	/// A function a class must or may provide: an abstract one of its base chain or one of its
	/// interfaces' (required), or a virtual one of the base chain (Override...).
	class InheritedFn
	{
		/// The signature (a copy of the declaring member).
		public MemberDecl Fn ~ delete _;
		/// The type that declares it (`Zoo.Animal`, `Zoo.IPet`).
		public String From = new .() ~ delete _;
		/// An interface's function: implemented without Override.
		public bool FromInterface;
	}

	/// Function inheritance (Editor-Model.md, "Overrides"): what the base chain and the interfaces ask
	/// of a class (Required overrides in the Outline, the "N required" badges) and what it may override
	/// (FUNCTIONS > Override...). Implement and Override make the function with the exact signature and
	/// an empty Sheet, one undo step.
	extension EditorApp
	{
		/// `required`: the abstract functions of the base chain and the interface functions that no
		/// class from this one up provides (none for an abstract class or an interface); `overridable`:
		/// the base chain's virtual and abstract functions this type does not declare itself. The caller
		/// deletes the items.
		public void InheritedFunctions(TypeDecl h, List<MemberDecl> own, List<InheritedFn> required, List<InheritedFn> overridable)
		{
			RefreshProjectTypes();
			HashSet<String> ownNames = scope .();
			HashSet<String> provided = scope .();
			HashSet<String> listed = scope .();
			HashSet<String> offered = scope .();
			List<String> ifaces = scope .();
			defer
			{
				for (let s in ownNames) delete s;
				for (let s in provided) delete s;
				for (let s in listed) delete s;
				for (let s in offered) delete s;
				ClearAndDeleteItems!(ifaces);
			}
			void Note(HashSet<String> set, StringView name)
			{
				if (!set.ContainsAlt(name))
					set.Add(new String(name));
			}
			for (let m in own)
				if (m.Kind == .Function && !m.Static)
				{
					Note(ownNames, m.Name);
					if (!m.Abstract)
						Note(provided, m.Name);
				}
			if (h.Kind == .Class || h.Kind == .Struct)
				for (let i in h.Implements)
					ifaces.Add(i.ToString(.. new String()));
			bool wantRequired = (h.Kind == .Class && !h.Abstract) || h.Kind == .Struct;
			void Offer(MemberDecl m, StringView from, bool isAbstract, bool isVirtual)
			{
				if (required != null && isAbstract && wantRequired && !provided.ContainsAlt(m.Name) && !listed.ContainsAlt(m.Name))
				{
					Note(listed, m.Name);
					InheritedFn r = new .();
					r.Fn = m.Clone();
					r.From.Set(from);
					required.Add(r);
				}
				if (overridable != null && (isAbstract || isVirtual) && !ownNames.ContainsAlt(m.Name) && !offered.ContainsAlt(m.Name))
				{
					Note(offered, m.Name);
					InheritedFn r = new .();
					r.Fn = m.Clone();
					r.From.Set(from);
					overridable.Add(r);
				}
			}
			let comp = FrontEnd?.Last;
			String baseName = scope .();
			if (h.Kind == .Class && h.Base != null && !h.Base.IsNone)
				h.Base.ToString(baseName);
			for (int depth = 0; depth < 32 && !baseName.IsEmpty; depth++)
			{
				let pt = ProjectTypes.Find(baseName);
				if (pt != null)
				{
					for (let m in pt.Members)
						if (m.Kind == .Function && !m.Static)
							Offer(m, pt.FullName, m.Abstract, m.Virtual || m.Override);
					for (let m in pt.Members)
						if (m.Kind == .Function && !m.Static && !m.Abstract)
							Note(provided, m.Name);
					for (let i in pt.Implements)
						ifaces.Add(new String(i));
					baseName.Set(pt.Base);
					continue;
				}
				let ts = comp?.Table.Find(baseName);
				if (ts == null)
					break;
				for (let ms in ts.Members)
					if (ms.Kind == .Function && !ms.Static && ms.Decl != null)
						Offer(ms.Decl, ts.FullName, ms.Abstract, ms.Virtual || ms.Override);
				for (let ms in ts.Members)
					if (ms.Kind == .Function && !ms.Static && !ms.Abstract)
						Note(provided, ms.Name);
				for (let i in ts.Interfaces)
					if (i.Sym != null)
						ifaces.Add(new String(i.Sym.FullName));
				baseName.Clear();
				if (ts.BaseSym != null && ts.BaseSym != ts)
					baseName.Set(ts.BaseSym.FullName);
			}
			if (!wantRequired || required == null)
				return;
			for (let i in ifaces)
			{
				List<MemberDecl> fns = scope .();
				defer { ClearAndDeleteItems!(fns); }
				InterfaceFunctions(i, fns);
				for (let f in fns)
				{
					if (provided.ContainsAlt(f.Name) || ownNames.ContainsAlt(f.Name) || listed.ContainsAlt(f.Name))
						continue;
					Note(listed, f.Name);
					InheritedFn r = new .();
					r.Fn = f.Clone();
					r.From.Set(i);
					r.FromInterface = true;
					required.Add(r);
				}
			}
		}

		/// How many required overrides the type in the file at `path` leaves out (its open document's
		/// members when it is open).
		public int RequiredCountAt(StringView path)
		{
			List<InheritedFn> req = scope .();
			defer { ClearAndDeleteItems!(req); }
			let doc = FindDoc(path);
			if (doc != null)
				InheritedFunctions(doc.Header, doc.Members, req, null);
			else
			{
				let t = ProjectTypeAt(path);
				if (t == null || (t.Kind != .Class && t.Kind != .Struct))
					return 0;
				TypeDecl h = scope .();
				h.Name.Set(t.Name);
				h.Kind = t.Kind;
				h.Abstract = t.Abstract;
				if (!t.Base.IsEmpty)
					h.Base = TypeRef.Parse(t.Base);
				for (let i in t.Implements)
					h.Implements.Add(TypeRef.Parse(i));
				InheritedFunctions(h, t.Members, req, null);
			}
			return req.Count;
		}

		/// Implement / Override: the function `f` asks for, with its signature, an empty Sheet and
		/// (a base class's) Override, in the open type; its Sheet opens. One undo step.
		public Sheet ImplementInherited(InheritedFn f)
		{
			if (Doc == null || Doc == mEmptyDoc || !BeginTypeEdit())
				return null;
			let s = Doc.AddFunctionLike(f.Fn, !f.FromInterface);
			EndTypeEdit();
			if (s == null)
			{
				SetStatus(scope $"{Doc.Header.Name} has a member {f.Fn.Name} already", .Info);
				return null;
			}
			OpenTab(s);
			SelectOutline(.Member, s.Member);
			SetStatus(scope $"{(f.FromInterface ? "Implemented" : "Overrode")} {f.From}.{f.Fn.Name}");
			return s;
		}

		/// Implement All: every required override of the open type, one undo step.
		public int ImplementAllRequired()
		{
			if (Doc == null || Doc == mEmptyDoc)
				return 0;
			List<InheritedFn> req = scope .();
			defer { ClearAndDeleteItems!(req); }
			InheritedFunctions(Doc.Header, Doc.Members, req, null);
			if (req.IsEmpty || !BeginTypeEdit())
				return 0;
			int made = 0;
			Sheet last = null;
			for (let f in req)
			{
				let s = Doc.AddFunctionLike(f.Fn, !f.FromInterface);
				if (s != null)
				{
					made++;
					last = s;
				}
			}
			EndTypeEdit();
			if (last != null)
				OpenTab(last);
			SetStatus(scope $"Implemented {made} required function{(made == 1) ? "" : "s"}");
			return made;
		}

		/// "Speak (int legs) : int": a function's name and signature for a row.
		public static void SignatureText(MemberDecl m, String outText)
		{
			outText.Append(m.Name);
			outText.Append(" (");
			for (let p in m.Params)
				outText.AppendF("{}{} {}", (@p.Index > 0) ? ", " : "", p.Type?.ToString(.. scope String()) ?? "", p.Name);
			outText.Append(")");
			if (m.Returns != null && !m.Returns.IsNone)
				outText.AppendF(" : {}", m.Returns.ToString(.. scope String()));
		}

		/// Whether the member has a Sheet (a body, a getter or a setter).
		public bool HasSheet(MemberDecl m)
		{
			for (let s in Doc.Sheets)
				if (s.Member == m)
					return true;
			return false;
		}

		/// An interface's new function: a signature without a Sheet (Language.md 2.5). One undo step.
		public MemberDecl AddFunctionSignature(StringView name)
		{
			if (!BeginTypeEdit())
				return null;
			MemberDecl m = new .();
			m.Kind = .Function;
			Doc.NewId(m.Id);
			UniqueMemberName(Doc, name, m.Name);
			InsertMember(m);
			EndTypeEdit();
			SelectOutline(.Member, m);
			SetStatus(scope $"Added the function signature {m.Name}");
			return m;
		}

		public enum FnInheritance
		{
			Normal,
			Virtual,
			Override,
			Abstract
		}

		public static StringView FnInheritanceName(FnInheritance k)
		{
			switch (k)
			{
			case .Normal: return "Normal";
			case .Virtual: return "Virtual";
			case .Override: return "Override";
			case .Abstract: return "Abstract";
			}
		}

		public static FnInheritance FunctionInheritance(MemberDecl m)
		{
			if (m.Override)
				return .Override;
			if (m.Abstract)
				return .Abstract;
			if (m.Virtual)
				return .Virtual;
			return .Normal;
		}

		/// A class function's inheritance, as the file writes it (`virtual`, `override`, `abstract`;
		/// sealed is kept only with override). One undo step.
		public bool SetFunctionInheritance(MemberDecl m, FnInheritance k)
		{
			if (FunctionInheritance(m) == k || !BeginTypeEdit())
				return false;
			m.Virtual = k == .Virtual;
			m.Abstract = k == .Abstract;
			m.Override = k == .Override;
			if (k != .Override)
				m.Sealed = false;
			EndTypeEdit();
			return true;
		}

		/// The Inheritance row of a class function's page: Normal / Virtual / Override / Abstract as
		/// one segmented control (the Outline row's menu sets the same).
		void DrawInheritanceSegments(MemberDecl m)
		{
			PropertyGrid.Row("Inheritance", "Normal: not overridable. Virtual: derived classes may override it. Override: replaces a base class's function. Abstract: no body here, derived classes must override it.");
			let cur = FunctionInheritance(m);
			float w = Gui.igGetContentRegionAvail().x;
			float seg = Math.Max(30 * Look.Scale, (w - 6 * Look.Scale) / 4);
			// A narrow Properties panel: the same four as a dropdown (the segments would cut their words).
			float need = 0;
			for (int ki < 4)
				need = Math.Max(need, Gui.CalcTextSize(FnInheritanceName((FnInheritance)ki)).x + 14 * Look.Scale);
			if (seg < need)
			{
				int32 idx = (int32)cur;
				StringView[4] names = .("Normal", "Virtual", "Override", "Abstract");
				if (PropertyGrid.Combo(scope $"##inhc{m.Serial}", ref idx, names, -1))
					SetFunctionInheritance(m, (FnInheritance)idx);
				return;
			}
			for (int ki < 4)
			{
				let k = (FnInheritance)ki;
				if (ki > 0)
					Gui.SameLine(0, 2 * Look.Scale);
				bool on = k == cur;
				Gui.igPushStyleColor_U32(Col.Button, on ? Look.Primary : Look.Input);
				Gui.igPushStyleColor_U32(Col.ButtonHovered, on ? Look.Primary : Gui.Color(60, 60, 60));
				if (Gui.Button(scope $"{FnInheritanceName(k)}##inh{m.Serial}", .(seg, 0)))
					SetFunctionInheritance(m, k);
				Gui.igPopStyleColor(2);
			}
		}
	}
}
