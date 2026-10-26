// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using System.IO;
using Treadle.Document;
using Treadle.Graph;

namespace Treadle.Editor
{
	/// The type context (GraphTabs.bf, DocumentHeader.bf), part of the `editor` case: Animal and Dog of the m1
	/// sample open; the Sheet tabs are only those of the type in front; switching the type swaps the strip, the
	/// Outline, the header ("Dog : Animal"), the watermark and the window title; Ctrl+Tab's list and
	/// Ctrl+Shift+Page Down stay with the types; a function dragged from Animal's Outline and held over Dog's
	/// tab drops on Dog's Sheet as a Call; the layout lands in the project's settings; closing a type closes its
	/// Sheets and brings the next type to the front.
	///
	/// Capture steps (TREADLE_SELFTEST): `doc.m1` (a copy of samples/m1 opened as the project with Animal, Dog
	/// and Program open, Dog's Speak in front), `doc.front:<Type>` (that open type in front), `doc.sheet:<Sheet>`
	/// (a Sheet of the type in front), `doc.open:<Type>` (another type of the copy opened), `doc.nosheets` (the Sheet
	/// tabs of the type in front closed), `doc.hold:<name>` (logs `hold <name>`, waits about 4 s), `doc.cleanup`.
	extension EditorApp
	{
		int mDocTabsPhase;
		bool mDocTabsDone;
		String mDocTabsDir = new .() ~ delete _;
		int32 mDocTabsLegsIndex = -1;
		TypeDocument mDocTabsPlayer;
		double mDocHoldUntil;

		TypeDocument DocTabsFind(StringView typeName)
		{
			for (let d in mDocs)
				if (d.Header.Name == typeName)
					return d;
			return null;
		}

		bool OutlineHasMember(StringView name)
		{
			for (let m in mMembers)
				if (m.Name == name)
					return true;
			return false;
		}

		/// True when every Sheet tab the strip would show belongs to `doc`, and it drew exactly those.
		bool StripShowsOnly(TypeDocument doc, out int count)
		{
			count = 0;
			for (let t in Tabs)
				if (t.Doc == doc)
					count++;
			List<TabSlot> slots = scope .();
			CollectTabSlots(slots);
			for (let s in slots)
				if (s.Graph.Doc != doc)
					return false;
			return slots.Count == count && DrawnSheetTabs == count;
		}

		/// One phase per call; true when done.
		bool SelfTestDocTabs()
		{
			let phase = mDocTabsPhase++;
			switch (phase)
			{
			case 0:
				mDocTabsPlayer = Doc;
				String samples = scope .();
				if (!FindSamples(samples))
				{
					SelfTestCheck(false, "editor: type context: the samples folder was not found");
					return true;
				}
				String temp = scope .();
				if (!SelfTestTemp.Get(temp))
					temp.Set(samples);
				mDocTabsDir.Set(scope $"{temp}/treadle-doctabs-{(int)Platform.BfpSystem_GetTimeStamp() & 0xFFFFFF}");
				Directory.CreateDirectory(mDocTabsDir).IgnoreError();
				for (let name in StringView[?]("Animal.treadle", "Dog.treadle"))
					File.Copy(scope $"{samples}/m1/{name}", scope $"{mDocTabsDir}/{name}").IgnoreError();
				let animal = OpenFile(scope $"{mDocTabsDir}/Animal.treadle");
				let dog = OpenFile(scope $"{mDocTabsDir}/Dog.treadle");
				SelfTestCheck(animal != null && dog != null, "editor: type context: Animal and Dog open");
				if (animal == null || dog == null)
					return true;
				let speak = dog.FindSheetByName("Speak");
				if (speak != null)
					OpenTab(speak);
				mSelfTestWait = 3;
				return false;
			case 1:
				let dog = DocTabsFind("Dog");
				let animal = DocTabsFind("Animal");
				bool contexts = FindTypeContext(dog) != null && FindTypeContext(animal) != null && FindTypeContext(mDocTabsPlayer) != null;
				SelfTestCheck(contexts && Doc == dog, scope $"editor: type context: Player, Animal and Dog each have a type tab, Dog in front ({TypeContexts.Count} types)");
				bool only = StripShowsOnly(dog, let count);
				SelfTestCheck(only && count >= 2, scope $"editor: type context: the Sheet tabs are Dog's only ({count} of {Tabs.Count} open Sheets, {DrawnSheetTabs} drawn)");
				SelfTestCheck(HeaderTypeText == "Dog : Animal", scope $"editor: type context: the header reads \"Dog : Animal\" ({HeaderTypeText})");
				SelfTestCheck(HeaderSignatureText.StartsWith("Speak"), scope $"editor: type context: the header shows the Sheet's signature ({HeaderSignatureText})");
				SelfTestCheck(mWindowTitle.EndsWith(" - Dog - Speak"), scope $"editor: type context: the window title names the type and the Sheet ({mWindowTitle})");
				SelfTestCheck(mGraphPanel.WatermarkText.StartsWith("Dog"), scope $"editor: type context: the watermark names the type ({mGraphPanel.WatermarkText})");
				SelfTestCheck(OutlineHasMember("Speak") && !OutlineHasMember("Legs"), "editor: type context: the Outline lists Dog's members");
				ActivateType(animal);
				mSelfTestWait = 2;
				return false;
			case 2:
				let dog = DocTabsFind("Dog");
				let animal = DocTabsFind("Animal");
				bool only = StripShowsOnly(animal, let count);
				SelfTestCheck(Doc == animal && only && count >= 1, scope $"editor: type context: switching to Animal swaps the Sheet tabs ({count} Animal Sheets, {DrawnSheetTabs} drawn)");
				SelfTestCheck(HeaderTypeText == "Animal" && mWindowTitle.Contains(" - Animal - "), scope $"editor: type context: the header and the title follow ({HeaderTypeText}; {mWindowTitle})");
				SelfTestCheck(OutlineHasMember("Legs"), "editor: type context: the Outline lists Animal's members");
				List<GraphTab> recent = scope .();
				SheetsByRecentUse(recent);
				bool sameType = true;
				for (let t in recent)
					sameType &= t.Doc == animal;
				SelfTestCheck(sameType, scope $"editor: type context: Ctrl+Tab lists the Sheets of the type in front only ({recent.Count})");
				// Ctrl+Shift+Page Down / Up: the next type and back.
				bool next = CycleType(1);
				let moved = Doc;
				bool prev = CycleType(-1);
				SelfTestCheck(next && prev && moved != animal && Doc == animal, "editor: type context: Ctrl+Shift+Page Down goes to the next type and Ctrl+Shift+Page Up comes back");
				// A function dragged out of Animal's Outline, held over Dog's tab: Dog comes to the front with it.
				mDocTabsLegsIndex = -1;
				for (let m in mMembers)
					if (m.Name == "Legs" && m.MemberKind == .Function)
						mDocTabsLegsIndex = (int32)@m.Index;
				HoldDragAcrossTypes(mDocTabsLegsIndex);
				HeldDragPinned = true;
				ActivateType(dog);
				mSelfTestWait = 2;
				return false;
			case 3:
				let dog = DocTabsFind("Dog");
				SelfTestCheck(Doc == dog && !OutlineHasMember("Legs") && DraggedRef(mDocTabsLegsIndex)?.Name == "Legs",
					"editor: type context: the dragged row of Animal survives Dog coming to the front");
				if (CurrentTab != null && mDocTabsLegsIndex >= 0)
				{
					mDocTabsCalls = 0;
					for (let n in CurrentMethod.Graph.Nodes)
						if (n.Kind == .Call && n.Text.Contains("Legs"))
							mDocTabsCalls++;
					DropMember(CurrentTab, mDocTabsLegsIndex, .(0, 600));
				}
				mSelfTestWait = 2;
				return false;
			case 4:
				int calls = 0;
				String texts = scope .();
				if (CurrentMethod != null)
					for (let n in CurrentMethod.Graph.Nodes)
						if (n.Kind == .Call && n.Text.Contains("Legs"))
						{
							calls++;
							texts.AppendF(" {}", n.Text);
						}
				SelfTestCheck(calls == mDocTabsCalls + 1, scope $"editor: type context: Animal's Legs dropped on Dog's Sheet places a Call ({texts})");
				DeleteAndNullify!(HeldDrag);
				HeldDragPinned = false;
				if (calls > mDocTabsCalls)
					EditDoc.Undo();
				// The layout is in the project's settings (open types, the Sheets, the one in front).
				let layout = (Settings.Root != null && !mProjectRoot.IsEmpty) ? Settings.Project(mProjectRoot).Get("typeLayout") : null;
				String saved = scope .();
				layout?.Write(saved);
				SelfTestCheck(saved.Contains("Dog.treadle") && saved.Contains("Animal.treadle") && saved.Contains("\"active\""),
					scope $"editor: type context: the open types are kept in the project's settings ({saved.Length} chars)");
				// Reopening the project brings them back: Animal and Dog closed, the layout read again.
				{
					let dog = DocTabsFind("Dog");
					let animal = DocTabsFind("Animal");
					CloseType(dog);
					CloseType(animal);
					bool closed = FindTypeContext(dog) == null && FindTypeContext(animal) == null;
					Doc = mEmptyDoc; // as a project opening with no file asked for
					ActiveTab = -1;
					mTypeLayoutProject.Clear();
					SyncTypeLayoutProject();
					let front = CurrentTab;
					SelfTestCheck(closed && FindTypeContext(dog) != null && FindTypeContext(animal) != null && Doc == dog && front != null && front.Doc == dog && front.Title == "Speak",
						scope $"editor: type context: the saved layout reopens Animal and Dog, Dog in front on Speak ({(front != null) ? front.Title : "no Sheet"})");
				}
				RequestCloseType(DocTabsFind("Dog"));
				mSelfTestWait = 2;
				return false;
			case 5:
				let dog = DocTabsFind("Dog");
				bool dogTabs = false;
				for (let t in Tabs)
					dogTabs |= t.Doc == dog;
				SelfTestCheck(dog != null && FindTypeContext(dog) == null && !dogTabs && Doc != dog && FindTypeContext(Doc) != null,
					"editor: type context: closing Dog closes its Sheets and brings the next type to the front");
				// The copies go; Player is in front again for the rest of the case.
				for (let name in StringView[?]("Dog", "Animal"))
				{
					let d = DocTabsFind(name);
					if (d != null)
					{
						d.Modified = false;
						CloseDoc(d);
					}
				}
				for (let e in Directory.EnumerateFiles(mDocTabsDir))
					File.Delete(e.GetFilePath(.. scope String())).IgnoreError();
				Directory.Delete(mDocTabsDir).IgnoreError();
				if (IsLoadedDoc(mDocTabsPlayer))
					ActivateType(mDocTabsPlayer);
				return true;
			}
			return true;
		}
		int mDocTabsCalls;

		/// The capture steps (see above). False when `test` is none of them.
		bool SelfTestDocCapture(StringView test, ref bool finished)
		{
			if (!test.StartsWith("doc."))
				return false;
			let colon = test.IndexOf(':');
			let verb = (colon > 0) ? test.Substring(4, colon - 4) : test.Substring(4);
			let arg = (colon > 0) ? test.Substring(colon + 1) : "";
			switch (verb)
			{
			case "m1":
				if (mSelfTestStep == 0)
				{
					String samples = scope .();
					if (!FindSamples(samples))
					{
						SelfTestCheck(false, "capture: doc.m1: the samples folder was not found");
						return true;
					}
					String temp = scope .();
					SelfTestTemp.Get(temp);
					mDocTabsDir.Set(scope $"{temp}/Zoo-{(int)Platform.BfpSystem_GetTimeStamp() & 0xFFFFFF}");
					Directory.CreateDirectory(mDocTabsDir).IgnoreError();
					for (let e in Directory.EnumerateFiles(scope $"{samples}/m1"))
					{
						let from = e.GetFilePath(.. scope String());
						File.Copy(from, scope $"{mDocTabsDir}/{Path.GetFileName(from, .. scope String())}").IgnoreError();
					}
					RequestOpenProject(mDocTabsDir, scope $"{mDocTabsDir}/Program.treadle");
					mSelfTestWait = 30;
					finished = false;
				}
				else
				{
					OpenFile(scope $"{mDocTabsDir}/Animal.treadle");
					let dog = OpenFile(scope $"{mDocTabsDir}/Dog.treadle");
					let speak = dog?.FindSheetByName("Speak");
					if (speak != null)
						OpenTab(speak);
					mSelfTestWait = 10;
				}
			case "front":
				let d = DocTabsFind(arg);
				if (d != null)
					ActivateType(d);
				else
					SelfTestCheck(false, scope $"capture: doc.front: {arg} is not open");
				mSelfTestWait = 6;
			case "open":
				if (OpenFile(scope $"{mDocTabsDir}/{arg}.treadle") == null)
					SelfTestCheck(false, scope $"capture: doc.open: {arg} did not open");
				mSelfTestWait = 6;
			case "nosheets":
				// The type in front with none of its Sheets open (the header and the hint).
				for (let t in Tabs)
					if (t.Doc == Doc)
						RequestCloseGraphTab(t);
				mSelfTestWait = 6;
			case "sheet":
				let mg = Doc?.FindSheetByName(arg);
				if (mg != null)
					OpenTab(mg);
				mSelfTestWait = 6;
			case "hold":
				let now = ImGui.Gui.igGetTime();
				if (mDocHoldUntil == 0)
				{
					mDocHoldUntil = now + 4.0;
					Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] hold {arg}");
				}
				if (now < mDocHoldUntil)
					finished = false;
				else
					mDocHoldUntil = 0;
			case "cleanup":
				for (let d in mDocs)
					d.Modified = false;
				OpenProjectNow("", "", false);
				if (!mDocTabsDir.IsEmpty)
					Directory.DelTree(mDocTabsDir).IgnoreError();
			default:
				SelfTestCheck(false, scope $"unknown capture step '{test}'");
			}
			return true;
		}
	}
}
#endif
