// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using System.IO;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Model;

namespace Treadle.Editor
{
	/// The `editor` case's checks of making types (NewTypes.bf, TypePickers.bf, Overrides.bf), run on the
	/// third wave's own project (SelfTestE3After) one phase per frame:
	///
	///  - The per-kind entries: the names proposed, the name rules, each kind's template and first view
	///    (a class's constructor Sheet, Type Settings for the others, an extension's Extends picker), no
	///    undo history behind a new type.
	///  - The type picker: the Base Class list (Animal, not int / bool / a struct / an interface), the
	///    groups and colours of the value list, "ani" finds Animal first in the open picker.
	///  - Inheritance at creation: base and interfaces written, the interface's function as a Sheet, the
	///    Base Constructor node in the constructor's Sheet, "Dog : Animal, IPet".
	///  - Required overrides and Override...: the abstract Move listed, Implement makes it (Override, one
	///    undo step), Speak offered and overridden; a function's inheritance set and undone.
	///  - Make Child Class (classes only) and Duplicate (fresh ids, the name rewritten, the copy opens).
	///  - The compiler: `base int` is T1012, a class leaving an abstract function is T1053.
	///  - The Outline's Delete: removes the selected member (one undo step), not the canvas's nodes.
	///  - Desktop.ShellOpen never runs in a test and refuses a bare `\`.
	extension EditorApp
	{
		int mNtPhase;
		String mNtDir = new .() ~ delete _;

		TypeDocument NtDoc(StringView name)
		{
			for (let d in mDocs)
				if (d.Header.Name == name)
					return d;
			return null;
		}

		/// One phase per call; true when done.
		bool SelfTestNewTypes()
		{
			switch (mNtPhase++)
			{
			case 0:
				NtKinds();
				return false;
			case 1:
				NtAnimal();
				return false;
			case 2:
				NtPickerLists();
				// The Base Class picker of the Create Type dialog, opened with "ani" typed.
				StartNewType(.Class, mNtDir);
				TypeCombo.TestOpen.Set("##ntbase");
				TypeCombo.TestSearch.Set("ani");
				mSelfTestWait = 4;
				return false;
			case 3:
				NtPickerOpen();
				TypeCombo.TestClose = true;
				mNtCloseRequest = true;
				mSelfTestWait = 3;
				return false;
			case 4:
				NtDog();
				mSelfTestWait = 3;
				return false;
			case 5:
				NtOverrides();
				return false;
			case 6:
				NtChildAndDuplicate();
				mSelfTestWait = 3;
				return false;
			case 7:
				NtCompiler();
				NtOutlineDelete();
				NtShell();
				return false;
			default:
				mNtPhase = 0;
				return true;
			}
		}

		void NtKinds()
		{
			mNtDir.Set(scope $"{mE3Root}/Source");
			if (!Directory.Exists(mNtDir))
				mNtDir.Set(mE3Root);
			// The proposed names, then the name rules.
			StartNewType(.Class, mNtDir);
			SelfTestCheck(mOpenNewType && mNtName.View == "NewClass" && mNtKind == .Class, scope $"editor: newtype: New Class... proposes NewClass ({mNtName.View})");
			mOpenNewType = false;
			StartNewType(.Interface, mNtDir);
			SelfTestCheck(mNtName.View == "INewInterface", scope $"editor: newtype: New Interface... proposes INewInterface ({mNtName.View})");
			mOpenNewType = false;
			String ns = scope .();
			NamespaceFor(mNtDir, ns);
			String err = scope .();
			SelfTestCheck(!ValidateTypeName(mNtDir, "1Bad", ns, err) && !ValidateTypeName(mNtDir, "Has Space", ns, err..Clear()) && ValidateTypeName(mNtDir, "Fine_1", ns, err..Clear()),
				"editor: newtype: a type name is a letter or _ first, then letters, digits and _");
			// Each kind from its template.
			let point = CreateType(.Struct, mNtDir, "Point");
			SelfTestCheck(point != null && point.Header.Kind == .Struct && point.Members.IsEmpty && point.Header.Attrs.IsEmpty && OutlineSel == .TypeSettings,
				"editor: newtype: New Struct: no members, not Copyable, Type Settings first");
			let color = CreateType(.Enum, mNtDir, "Color");
			SelfTestCheck(color != null && color.Members.Count == 1 && color.Members[0].Kind == .Case && color.Members[0].Name == "None", "editor: newtype: New Enum: the case None");
			let pet = CreateType(.Interface, mNtDir, "IPet");
			SelfTestCheck(pet != null && pet.Members.IsEmpty && pet.Sheets.IsEmpty, "editor: newtype: New Interface: no members");
			let sig = AddFunctionSignature("Pet");
			SelfTestCheck(sig != null && !HasSheet(sig), "editor: newtype: an interface's FUNCTIONS + adds a signature without a Sheet");
			String why = scope .();
			pet?.TrySave(why);
			let cb = CreateType(.Delegate, mNtDir, "Callback");
			SelfTestCheck(cb != null && cb.Header.Signature != null && cb.Header.Signature.AppendSignature(.. scope String()) == "void()", scope $"editor: newtype: New Delegate: the signature void() ({cb?.Header.Signature?.AppendSignature(.. scope String())})");
			let ext = CreateType(.Extension, mNtDir, "PointExtras");
			SelfTestCheck(ext != null && ext.Header.Extends == null && mFocusTsId == "##tsextends" && OutlineSel == .TypeSettings, "editor: newtype: New Extension: Type Settings with the Extends picker opening");
			mFocusTsId.Clear();
			let animal = CreateType(.Class, mNtDir, "Animal");
			let mg = CurrentMethod;
			SelfTestCheck(animal != null && animal.Members.Count == 1 && animal.Members[0].Kind == .Ctor && mg != null && mg.Member == animal.Members[0] && Doc == animal,
				"editor: newtype: New Class: a constructor and its Sheet in front");
			SelfTestCheck(animal != null && !animal.CanUndo && File.Exists(animal.FilePath) && animal.Header.Namespace == ns, scope $"editor: newtype: the new class is written, in namespace {ns}, with no undo step behind it");
			SelfTestCheck(File.Exists(scope $"{mNtDir}/Point{GraphExtension}") && FileExists(scope $"{mNtDir}/Color{GraphExtension}"), "editor: newtype: each type is its own file");
		}

		static bool FileExists(StringView p) => File.Exists(p);

		/// Animal gets a constructor input, a virtual Speak and an abstract Move (no Sheet).
		void NtAnimal()
		{
			let animal = NtDoc("Animal");
			if (animal == null)
			{
				SelfTestCheck(false, "editor: newtype: Animal is open");
				return;
			}
			Doc = animal;
			let ctor = animal.Members[0];
			AddParam(ctor, false);
			let speak = AddFunctionMember("Speak");
			SetFunctionInheritance(speak, .Virtual);
			let move = AddFunctionSignature("Move");
			SetFunctionInheritance(move, .Abstract);
			SelfTestCheck(speak.Virtual && move.Abstract && !HasSheet(move), "editor: newtype: Animal has a virtual Speak and an abstract Move");
			SaveAll();
			ScanProject();
		}

		void NtPickerLists()
		{
			RefreshProjectTypes();
			List<String> bases = scope .();
			defer { ClearAndDeleteItems!(bases); }
			TypeChoices(.BaseClass, "Wave.Dog", bases);
			bool animal = false, bad = false;
			for (let b in bases)
			{
				animal |= b.EndsWith("Animal");
				bad |= b == "int" || b == "bool" || b.EndsWith(".Point") || b.EndsWith(".IPet") || b.EndsWith(".Color") || b.EndsWith(".Callback") || b == "float4";
			}
			SelfTestCheck(animal && !bad, scope $"editor: picker: Base Class lists Animal and no primitive, struct, enum, interface or delegate ({bases.Count} classes)");
			List<TypeEntry> values = scope .();
			defer { ClearAndDeleteItems!(values); }
			TypeEntries(.Value, "", values);
			TypeEntry animalE = null, intE = null, f4 = null;
			for (let e in values)
			{
				if (e.Name.EndsWith(".Animal"))
					animalE = e;
				if (e.Name == "int")
					intE = e;
				if (e.Name == "float4")
					f4 = e;
			}
			SelfTestCheck(animalE != null && animalE.Group == "Project types" && Theme.TypeColor(animalE.Name) == Theme.FamilyColor(.Object),
				"editor: picker: Animal is under Project types in the class (object) colour");
			SelfTestCheck(intE != null && intE.Group == "Primitives" && Theme.TypeColor("int") == Theme.FamilyColor(.Int), "editor: picker: int is under Primitives in the int colour");
			SelfTestCheck(f4 != null && f4.Group == "Vectors", "editor: picker: float4 is under Vectors");
			List<TypeEntry> ifaces = scope .();
			defer { ClearAndDeleteItems!(ifaces); }
			TypeEntries(.Interface, "", ifaces);
			bool onlyIfaces = !ifaces.IsEmpty;
			for (let e in ifaces)
				onlyIfaces &= ProjectTypes.Find(e.Name) == null || ProjectTypes.Find(e.Name).Kind == .Interface;
			SelfTestCheck(onlyIfaces, scope $"editor: picker: Interfaces lists interfaces only ({ifaces.Count})");
		}

		void NtPickerOpen()
		{
			bool first = !TypeCombo.TestRows.IsEmpty && TypeCombo.TestRows[0].EndsWith("Animal");
			bool noGroups = true;
			for (let r in TypeCombo.TestRows)
				noGroups &= !r.StartsWith("Primitives|") && !r.StartsWith("Vectors|") && !r.EndsWith("IPet");
			SelfTestCheck(first && noGroups, scope $"editor: picker: \"ani\" in the Base Class picker finds Animal first, no Primitives / Vectors / interfaces ({(TypeCombo.TestRows.IsEmpty ? "no rows" : (StringView)TypeCombo.TestRows[0])})");
		}

		void NtDog()
		{
			List<String> ifaces = scope .();
			defer { ClearAndDeleteItems!(ifaces); }
			ifaces.Add(new String("Wave.IPet"));
			let dog = CreateType(.Class, mNtDir, "Dog", "Wave.Animal", ifaces);
			if (dog == null)
			{
				SelfTestCheck(false, "editor: newtype: Dog is made");
				return;
			}
			SelfTestCheck(dog.Header.Base?.ToString(.. scope String()) == "Wave.Animal" && dog.Header.Implements.Count == 1, "editor: newtype: Base Class and Interfaces are written into Dog's header");
			let pet = dog.FindMember("Pet");
			SelfTestCheck(pet != null && HasSheet(pet) && !pet.Override, "editor: newtype: IPet's Pet is a Sheet to fill");
			Sheet ctor = null;
			for (let s in dog.Sheets)
				if (s.Member != null && s.Member.Kind == .Ctor)
					ctor = s;
			bool chain = false;
			if (ctor != null && ctor.IsBuilt)
				for (let n in ctor.Graph.Nodes)
					chain |= n.Kind == .ChainCtor;
			SelfTestCheck(chain && ctor.Member.Chain == .Base, "editor: newtype: Dog's constructor runs Animal's (a Base Constructor node)");
			SelfTestCheck(!dog.CanUndo && OutlineSel == .TypeSettings, "editor: newtype: Dog has no undo step; Type Settings shows its inheritance");
			String line = scope .();
			InheritanceLine(dog.Header, line);
			SelfTestCheck(line == "Dog : Animal, IPet", scope $"editor: newtype: the header line reads {line}");
		}

		void NtOverrides()
		{
			let dog = NtDoc("Dog");
			if (dog == null)
				return;
			Doc = dog;
			List<InheritedFn> req = scope .();
			List<InheritedFn> ov = scope .();
			defer { ClearAndDeleteItems!(req); ClearAndDeleteItems!(ov); }
			InheritedFunctions(dog.Header, dog.Members, req, ov);
			InheritedFn move = null, speak = null;
			for (let f in req)
				if (f.Fn.Name == "Move")
					move = f;
			for (let f in ov)
				if (f.Fn.Name == "Speak")
					speak = f;
			SelfTestCheck(req.Count == 1 && move != null && !move.FromInterface, scope $"editor: overrides: Required overrides lists Animal's abstract Move only ({req.Count})");
			SelfTestCheck(speak != null, "editor: overrides: Override... offers Animal's virtual Speak");
			SelfTestCheck(RequiredCountAt(dog.FilePath) == 1, "editor: overrides: the badge counts 1 required");
			if (move == null || speak == null)
				return;
			let s = ImplementInherited(move);
			let m = dog.FindMember("Move");
			SelfTestCheck(s != null && m != null && m.Override && CurrentMethod == s, "editor: overrides: Implement makes Move, marked Override, its Sheet in front");
			dog.Undo();
			SelfTestCheck(dog.FindMember("Move") == null, "editor: overrides: one undo removes it");
			ImplementAllRequired();
			SelfTestCheck(dog.FindMember("Move") != null && RequiredCountAt(dog.FilePath) == 0, "editor: overrides: Implement all leaves nothing required");
			ImplementInherited(speak);
			let sp = dog.FindMember("Speak");
			SelfTestCheck(sp != null && sp.Override && HasSheet(sp), "editor: overrides: Override... makes Speak an override with its Sheet");
			let pet = dog.FindMember("Pet");
			SetFunctionInheritance(pet, .Virtual);
			bool set = pet.Virtual;
			dog.Undo();
			SelfTestCheck(set && !dog.FindMember("Pet").Virtual, "editor: overrides: a function's inheritance is set on it, one undo step");
			SaveAll();
			ScanProject();
		}

		void NtChildAndDuplicate()
		{
			let dog = NtDoc("Dog");
			let point = NtDoc("Point");
			if (dog == null || point == null)
				return;
			StartMakeChild(dog.FilePath);
			SelfTestCheck(mOpenNewType && mNtBase == "Wave.Dog" && mNtName.View == "DogChild" && mNtKind == .Class, scope $"editor: newtype: Make Child Class on Dog proposes DogChild : Wave.Dog ({mNtName.View} : {mNtBase})");
			mOpenNewType = false;
			StartMakeChild(point.FilePath);
			SelfTestCheck(!mOpenNewType, "editor: newtype: a struct has no Make Child Class");
			let copy = DuplicateType(dog.FilePath, "Dog2");
			SelfTestCheck(copy != null && copy.Header.Name == "Dog2" && copy.Members.Count == dog.Members.Count && copy.Sheets.Count == dog.Sheets.Count && Doc == copy,
				scope $"editor: newtype: Duplicate makes Dog2 with Dog's members and Sheets, opened ({copy?.Members.Count} members)");
			bool fresh = copy != null;
			if (copy != null)
				for (int i < Math.Min(copy.Members.Count, dog.Members.Count))
					if (!dog.Members[i].Id.IsEmpty && copy.Members[i].Id == dog.Members[i].Id)
						fresh = false;
			SelfTestCheck(fresh && copy.Header.Base?.ToString(.. scope String()) == "Wave.Animal", "editor: newtype: the copy's ids are new, its base kept");
			String text = scope .();
			File.ReadAllText(scope $"{mNtDir}/Dog2{GraphExtension}", text).IgnoreError();
			SelfTestCheck(text.Contains("type Dog2 ") && !text.Contains("type Dog "), "editor: newtype: the copy's file names Dog2");
		}

		void NtCompiler()
		{
			String samples = scope .();
			if (!FindSamples(samples))
				return;
			List<TypeDocument> extra = scope .();
			defer { ClearAndDeleteItems!(extra); }
			let bad = new TypeDocument(Language);
			bad.InitType("BadBase", .Class, "Broken");
			bad.Header.Base = TypeRef.Parse("int");
			bad.FilePath.Set("BadBase.treadle");
			extra.Add(bad);
			let abs = new TypeDocument(Language);
			abs.InitType("Shape", .Class, "Broken");
			MemberDecl area = new .();
			area.Kind = .Function;
			abs.NewId(area.Id);
			area.Name.Set("Area");
			area.Abstract = true;
			area.Returns = TypeRef.Parse("float");
			abs.Members.Add(area);
			abs.FilePath.Set("Shape.treadle");
			extra.Add(abs);
			let child = new TypeDocument(Language);
			child.InitType("Square", .Class, "Broken");
			child.Header.Base = TypeRef.Parse("Broken.Shape");
			child.FilePath.Set("Square.treadle");
			extra.Add(child);
			let c = SelfTestCompile(samples, extra);
			defer delete c;
			bool t1012 = false, t1053 = false;
			for (let d in c.Diags.Items)
			{
				t1012 |= d.Code == "T1012";
				t1053 |= d.Code == "T1053" && d.Message.Contains("Area");
			}
			SelfTestCheck(t1012, "editor: compiler: base int is refused (T1012)");
			SelfTestCheck(t1053, "editor: compiler: a class that leaves an abstract function of its base is refused (T1053)");
		}

		void NtOutlineDelete()
		{
			let dog = NtDoc("Dog");
			if (dog == null)
				return;
			Doc = dog;
			let pet = dog.FindMember("Pet");
			Sheet body = null;
			for (let s in dog.Sheets)
				if (s.Member != null && s.Member.Kind == .Ctor)
					body = s;
			if (body != null)
				OpenTab(body);
			let tab = CurrentTab;
			int nodes = (body != null && body.IsBuilt) ? body.Graph.Nodes.Count : -1;
			if (tab != null && body != null && body.IsBuilt && body.Graph.Entry != null)
				tab.SelectedNodes.Add(body.Graph.Entry.Id);
			SelectOutline(.Member, pet);
			let gone = DeleteOutlineSelection();
			SelfTestCheck(gone && dog.FindMember("Pet") == null && (body == null || !body.IsBuilt || body.Graph.Nodes.Count == nodes),
				"editor: outline: Delete removes the selected function, not the canvas's selected nodes");
			dog.Undo();
			SelfTestCheck(dog.FindMember("Pet") != null, "editor: outline: one undo brings it back");
			tab?.SelectedNodes.Clear();
		}

		void NtShell()
		{
			let before = Desktop.SuppressedOpens;
			let ok = Desktop.ShellOpen("explorer.exe", "\\");
			SelfTestCheck(!ok && Desktop.SuppressedOpens == before + 1 && Desktop.LastSuppressedOpen == "\\", "editor: shell: a bare \\ is refused and nothing is started in a test run");
		}

		/// Capture steps for the pixel pass of making types: `addmenu` (+ Add open), `ntnew:<Class|Struct|...>`
		/// (the Create Type dialog for the Project Browser's folder), `ntchild:<type file>` (Make Child Class),
		/// `pick:<id>` or `pick:<id>|<search>` (a type picker open), `pickclose`, `ntclose`,
		/// `opentype:<type file>` (the type opened, Type Settings in Properties), `outlinemember:<name>`.
		bool SelfTestNTCapture(StringView test)
		{
			if (test == "addmenu")
			{
				mSpAddMenu = true;
				return true;
			}
			if (test.StartsWith("ntnew:"))
			{
				let k = test.Substring(6);
				for (int i < 6)
					if (KindTitle((TypeKind)i) == k)
						StartNewType((TypeKind)i, mCBFolder.IsEmpty ? (StringView)mProjectRoot : (StringView)mCBFolder);
				return true;
			}
			if (test.StartsWith("ntchild:"))
			{
				StartMakeChild(scope $"{mProjectRoot}/{test.Substring(8)}");
				return true;
			}
			if (test.StartsWith("pick:"))
			{
				var arg = test.Substring(5);
				let bar = arg.IndexOf('|');
				if (bar >= 0)
				{
					TypeCombo.TestSearch.Set(arg.Substring(bar + 1));
					arg = arg.Substring(0, bar);
				}
				TypeCombo.TestOpen.Set(arg);
				return true;
			}
			if (test == "pickclose")
			{
				TypeCombo.TestClose = true;
				return true;
			}
			if (test == "ntclose")
			{
				mNtCloseRequest = true;
				return true;
			}
			if (test.StartsWith("opentype:"))
			{
				let doc = OpenFile(scope $"{mProjectRoot}/{test.Substring(9)}");
				if (doc != null)
				{
					Doc = doc;
					SelectOutline(.TypeSettings);
				}
				return true;
			}
			if (test.StartsWith("ntmake:"))
			{
				// ntmake:<Kind>|<Name>|<Base>: Create in the project's Source folder (else its root).
				var parts = test.Substring(7).Split('|');
				StringView kind = parts.GetNext().GetValueOrDefault();
				StringView name = parts.GetNext().GetValueOrDefault();
				StringView baseType = parts.GetNext().GetValueOrDefault();
				String folder = scope $"{mProjectRoot}/Source";
				if (!Directory.Exists(folder))
					folder.Set(mProjectRoot);
				for (int i < 6)
					if (KindTitle((TypeKind)i) == kind)
						CreateType((TypeKind)i, folder, name, baseType);
				return true;
			}
			if (test.StartsWith("ntabstract:"))
			{
				let m = AddFunctionSignature(test.Substring(11));
				if (m != null)
					SetFunctionInheritance(m, .Abstract);
				return true;
			}
			if (test.StartsWith("outlinemember:"))
			{
				let m = Doc?.FindMember(test.Substring(14));
				if (m != null)
				{
					SelectOutline(.Member, m);
					Panels.Focus(Panels.OutlineId);
				}
				return true;
			}
			return false;
		}
	}
}
#endif
