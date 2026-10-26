using System;
using System.Collections;
using ImGui;
using Treadle.Debug;
using Treadle.Debug.Dap;
using Treadle.Document;
using Treadle.Model;

namespace Treadle.Editor
{
	/// The Disassembly panel (docs/Debugging.md, "Disassembly"): a function's machine code from the last
	/// build, grouped under the node each instruction was made for, with its Sheet IR and LLVM IR on sibling
	/// tabs. Opened from a function's context menu in the Outline, from the Debug menu (the function of the
	/// selected frame) or from a Call Stack frame. While the program is stopped the instruction it is on is
	/// marked. Read-only, monospace, searchable, Copy puts the tab's text on the clipboard.
	extension EditorApp
	{
		public bool ShowDisassembly;
		FunctionListing mAsm ~ delete _;
		int mAsmPick;
		int mAsmTab;
		/// A tab to bring to the front next frame (-1: none).
		public int AsmTabRequest = -1;
		public bool AsmAddresses = true;
		public bool AsmBytes;
		TextBuffer mAsmFind = new .(128) ~ delete _;
		int mAsmFindHit = -1;
		bool mAsmScrollToHit;
		int mAsmFocus;
		/// The live position: the selected frame's instruction as an address of the exe.
		uint64 mAsmLivePc;
		int32 mAsmLiveId;
		int32 mAsmLiveSerial = -1;
		int mAsmLiveFrame = -1;
		bool mAsmScrollToLive;

		/// Opens the panel on the function of Sheet `sheetKey` of type `unit`, from the build of the active
		/// configuration.
		public void OpenDisassembly(StringView unit, StringView sheetKey, StringView sheetName, int pick = 0)
		{
			if (mProjectRoot.IsEmpty)
			{
				SetStatus("Disassembly needs a project that has been built (F7)", .Info);
				return;
			}
			delete mAsm;
			mAsm = new .();
			mAsmPick = pick;
			mAsm.Produce(mProjectRoot, ActiveConfig, unit, sheetKey, sheetName, pick);
			mAsmFindHit = -1;
			mAsmLiveSerial = -1;
			ShowDisassembly = true;
			mAsmFocus = 2;
		}

		/// The listing shown (the `hood` self test reads it).
		public FunctionListing Disassembly => mAsm;

		/// Opens it on a member's body Sheet (the Outline's context menu).
		public void OpenDisassemblyOf(TypeDocument doc, MemberDecl m)
		{
			if (doc == null || m == null)
				return;
			for (let s in doc.Sheets)
				if (s.Member == m && s.Role == .Body)
				{
					String unit = doc.Header.GetFullName(.. scope .());
					OpenDisassembly(unit, s.Key, scope $"{unit}.{s.Name}");
					return;
				}
			SetStatus("This member has no Sheet of code to disassemble", .Info);
		}

		/// The Debug menu's entry: the function of the selected frame, else of the Sheet in front.
		void OpenDisassemblyHere()
		{
			let f = (mDebug != null) ? mDebug.CurrentFrame : null;
			if (f != null && f.IsUser)
			{
				OpenDisassembly(f.Unit, f.SheetKey, f.SheetName);
				return;
			}
			let mg = CurrentMethod;
			if (mg != null && mg.Doc != null)
			{
				String unit = mg.Doc.Header.GetFullName(.. scope .());
				OpenDisassembly(unit, mg.Key, scope $"{unit}.{mg.Name}");
			}
		}

		/// Window and Debug menu entries (one call in each menu).
		void DrawHoodMenuItems(bool debugMenu)
		{
			if (debugMenu)
			{
				if (Gui.MenuItem("Disassembly", "", false, CurrentMethod != null || IsDebugStopped))
					OpenDisassemblyHere();
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip("The machine code of the function in front (or of the selected frame) from the last build, by node");
				if (Gui.MenuItem("Memory", "", ShowMemory))
					ShowMemory = !ShowMemory;
				return;
			}
			if (Gui.MenuItem("Memory", "", ShowMemory))
				ShowMemory = !ShowMemory;
			if (Gui.MenuItem("Disassembly", "", ShowDisassembly))
			{
				if (!ShowDisassembly && mAsm == null)
					OpenDisassemblyHere();
				else
					ShowDisassembly = !ShowDisassembly;
			}
		}

		/// The Outline's function context menu entry (one call there).
		public void HoodFunctionMenuItem(MemberDecl m)
		{
			if (Gui.MenuItem("Disassembly"))
				OpenDisassemblyOf(Doc, m);
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip("The function's machine code from the last build, grouped by node, with its Sheet IR and LLVM IR");
		}

		/// Called each frame (one call in the frame loop): the Memory and Disassembly panels.
		void DrawHoodPanels()
		{
			DrawMemoryPanel();
			DrawDisassemblyPanel();
		}

		void AsmLiveTick()
		{
			if (mAsm == null || !mAsm.FromExe || mDebug == null || !mDebug.IsStopped)
			{
				mAsmLivePc = 0;
				return;
			}
			if (mAsmLiveId != 0)
			{
				let r = mDapAdapter.TakeInspect(mAsmLiveId);
				if (r != null)
				{
					mAsmLiveId = 0;
					mAsmLivePc = r.Failed ? 0 : r.FileAddress;
					mAsmScrollToLive = true;
					delete r;
				}
				return;
			}
			if (mDebug.StopSerial != mAsmLiveSerial || mDebug.SelectedFrame != mAsmLiveFrame)
			{
				mAsmLiveSerial = mDebug.StopSerial;
				mAsmLiveFrame = mDebug.SelectedFrame;
				InspectRequest r = new .();
				r.What = .Frame;
				r.Frame = mDebug.SelectedFrame;
				mAsmLiveId = mDapAdapter.Inspect(r);
			}
		}

		void DrawDisassemblyPanel()
		{
			if (!ShowDisassembly)
				return;
			AsmLiveTick();
			if (mAsmFocus > 0 && --mAsmFocus == 0)
				Panels.Focus(HoodPanels.DisassemblyId);
			if (Gui.Begin(HoodPanels.Disassembly, &ShowDisassembly))
				DrawDisassemblyBody();
			Gui.End();
		}

		void DrawDisassemblyBody()
		{
			if (mAsm == null)
			{
				Gui.igPushTextWrapPos(0);
				Gui.TextDisabled("Right-click a function in the Outline > Disassembly, or Debug > Disassembly, to see its machine code from the last build.");
				Gui.igPopTextWrapPos();
				return;
			}
			let a = mAsm;
			Gui.Text(a.SheetName.IsEmpty ? a.Unit : a.SheetName);
			Gui.SameLine();
			Gui.TextDisabled(scope $"{a.Config} build");
			if (a.Symbols.Count > 1)
			{
				Gui.SameLine();
				Gui.igSetNextItemWidth(Math.Min(320 * Look.Scale, Gui.igGetContentRegionAvail().x - 80 * Look.Scale));
				if (Gui.igBeginCombo("##asminst", scope String(a.Demangled), 0))
				{
					for (let n in a.SymbolNames)
						if (Gui.Selectable(n, @n.Index == mAsmPick))
						{
							OpenDisassembly(scope String(a.Unit), scope String(a.SheetKey), scope String(a.SheetName), @n.Index);
							Gui.igEndCombo();
							return;
						}
					Gui.igEndCombo();
				}
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip("A generic type's function is built once per type argument: pick the instance");
			}
			Gui.SameLine();
			if (Gui.SmallButton("Refresh"))
			{
				OpenDisassembly(scope String(a.Unit), scope String(a.SheetKey), scope String(a.SheetName), mAsmPick);
				return;
			}
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip("Read the last build again (after F7)");
			if (!a.Demangled.IsEmpty)
				Gui.TextDisabled(scope $"{a.Demangled}   {a.Symbol}");
			if (!Gui.igBeginTabBar("##asmtabs", 0))
				return;
			int tab = -1;
			if (Gui.igBeginTabItem("Disassembly", null, (AsmTabRequest == 0) ? 2 : 0))
			{
				tab = 0;
				Gui.igEndTabItem();
			}
			if (Gui.igBeginTabItem("Sheet IR", null, (AsmTabRequest == 1) ? 2 : 0))
			{
				tab = 1;
				Gui.igEndTabItem();
			}
			if (Gui.igBeginTabItem("LLVM IR", null, (AsmTabRequest == 2) ? 2 : 0))
			{
				tab = 2;
				Gui.igEndTabItem();
			}
			Gui.igEndTabBar();
			AsmTabRequest = -1;
			if (tab != mAsmTab && tab >= 0)
			{
				mAsmTab = tab;
				mAsmFindHit = -1;
			}
			// search, toggles, copy
			Gui.igSetNextItemWidth(160 * Look.Scale);
			if (Gui.igInputTextWithHint("##asmfind", "Find (Enter: next)", mAsmFind.Ptr, (.)mAsmFind.Capacity, InputTextFlags.EnterReturnsTrue, null, null))
			{
				mAsmFindHit++;
				mAsmScrollToHit = true;
			}
			if (mAsmTab == 0)
			{
				Gui.SameLine();
				Gui.Checkbox("Addresses", &AsmAddresses);
				Gui.SameLine();
				Gui.Checkbox("Bytes", &AsmBytes);
			}
			Gui.SameLine();
			if (Gui.SmallButton("Copy"))
			{
				String all = scope .();
				switch (mAsmTab)
				{
				case 0: a.Text(all, AsmAddresses, AsmBytes);
				case 1: all.Set(a.SheetIR);
				default: all.Set(a.LLVMIR);
				}
				Gui.igSetClipboardText(all);
				SetStatus("Copied to the clipboard", .Info);
			}
			Gui.igBeginChild_Str(scope $"##asmbody{mAsmTab}", .(0, 0), 0, WindowFlags.HorizontalScrollbar);
			let mono = PropertyGrid.MonoFont;
			if (mono != null)
				Gui.igPushFont(mono, Gui.igGetFontSize() / Math.Max(Look.Scale, 0.5f) * 0.92f);
			switch (mAsmTab)
			{
			case 0: DrawAsmLines(a);
			case 1: DrawTextLines(a.SheetIR);
			default: DrawTextLines(a.LLVMIR);
			}
			if (mono != null)
				Gui.igPopFont();
			Gui.igEndChild();
		}

		bool AsmMatches(StringView line)
		{
			let find = mAsmFind.View;
			return !find.IsEmpty && line.IndexOf(find, true) >= 0;
		}

		void DrawAsmLines(FunctionListing a)
		{
			if (!a.Error.IsEmpty && a.Lines.IsEmpty)
			{
				Gui.igPushTextWrapPos(0);
				Gui.TextColored(Look.Warning, a.Error);
				Gui.igPopTextWrapPos();
				return;
			}
			if (!a.Note.IsEmpty)
			{
				Gui.igPushTextWrapPos(0);
				Gui.TextDisabled(a.Note);
				Gui.igPopTextWrapPos();
			}
			// the matches, for Enter
			List<int> hits = scope .();
			for (let l in a.Lines)
				if (AsmMatches(l.Text) || (AsmBytes && AsmMatches(l.Bytes)))
					hits.Add(@l.Index);
			if (!a.Groups.IsEmpty)
				for (let g in a.Groups)
					if (AsmMatches(g.Title) || AsmMatches(g.Node))
						hits.Add(-1 - @g.Index);
			int hit = (hits.IsEmpty || mAsmFindHit < 0) ? int.MinValue : hits[mAsmFindHit % hits.Count];
			let dl = Gui.igGetWindowDrawList();
			let lineH = Gui.igGetTextLineHeightWithSpacing();
			for (let g in a.Groups)
			{
				// the node heading: a click shows the node
				String head = scope .();
				if (!g.Node.IsEmpty)
					head.AppendF("{}  ", g.Node);
				head.Append(g.Title);
				let gi = -1 - @g.Index;
				Gui.PushID((int32)@g.Index);
				let hp = Gui.igGetCursorScreenPos();
				if (gi == hit || AsmMatches(head))
					Gui.ImDrawList_AddRectFilled(dl, hp, .(hp.x + Gui.igGetContentRegionAvail().x, hp.y + lineH), Theme.WithAlpha(Look.AccentYellow, (gi == hit) ? 70 : 30), 0, 0);
				Gui.TextColored(Look.AccentBlue, head);
				if (gi == hit && mAsmScrollToHit)
				{
					Gui.igSetScrollHereY(0.3f);
					mAsmScrollToHit = false;
				}
				if (!g.Node.IsEmpty)
				{
					if (Gui.igIsItemHovered(0))
						Gui.Tooltip(scope $"Node {g.Node} of {g.Unit} (listing line {g.Line}): click to show it on its Sheet");
					if (Gui.igIsItemClicked(0))
						AsmShowNode(g);
				}
				Gui.PopID();
				for (int i = g.First; i < g.First + g.Count && i < a.Lines.Count; i++)
				{
					let l = a.Lines[i];
					String text = scope .("    ");
					if (AsmAddresses)
						text.AppendF("{:X}:  ", l.Address);
					if (AsmBytes)
						text.AppendF("{,-24}", l.Bytes);
					text.Append(l.Text);
					let p = Gui.igGetCursorScreenPos();
					let live = mAsmLivePc != 0 && l.Address == mAsmLivePc;
					if (live)
					{
						Gui.ImDrawList_AddRectFilled(dl, p, .(p.x + Gui.igGetContentRegionAvail().x, p.y + lineH), Theme.WithAlpha(Look.AccentYellow, 60), 0, 0);
						if (mAsmScrollToLive)
						{
							Gui.igSetScrollHereY(0.4f);
							mAsmScrollToLive = false;
						}
					}
					else if (i == hit || AsmMatches(text))
						Gui.ImDrawList_AddRectFilled(dl, p, .(p.x + Gui.igGetContentRegionAvail().x, p.y + lineH), Theme.WithAlpha(Look.AccentYellow, (i == hit) ? 70 : 25), 0, 0);
					Gui.TextColored(live ? Look.ForegroundHover : Look.Foreground, text);
					if (live && Gui.igIsItemHovered(0))
						Gui.Tooltip("The program is on this instruction (the selected frame)");
					if (i == hit && mAsmScrollToHit)
					{
						Gui.igSetScrollHereY(0.3f);
						mAsmScrollToHit = false;
					}
				}
			}
			if (hits.IsEmpty && !mAsmFind.View.IsEmpty)
				mAsmFindHit = -1;
		}

		void DrawTextLines(StringView text)
		{
			int n = 0;
			let dl = Gui.igGetWindowDrawList();
			let lineH = Gui.igGetTextLineHeightWithSpacing();
			List<int> hits = scope .();
			for (let l in text.Split('\n'))
			{
				if (AsmMatches(l))
					hits.Add(n);
				n++;
			}
			int hit = (hits.IsEmpty || mAsmFindHit < 0) ? -1 : hits[mAsmFindHit % hits.Count];
			n = 0;
			for (let l in text.Split('\n'))
			{
				let p = Gui.igGetCursorScreenPos();
				if (n == hit || AsmMatches(l))
					Gui.ImDrawList_AddRectFilled(dl, p, .(p.x + Gui.igGetContentRegionAvail().x, p.y + lineH), Theme.WithAlpha(Look.AccentYellow, (n == hit) ? 70 : 25), 0, 0);
				String shown = scope .(l);
				shown.Replace("\t", "    ");
				Gui.Text(shown.IsEmpty ? " " : shown);
				if (n == hit && mAsmScrollToHit)
				{
					Gui.igSetScrollHereY(0.3f);
					mAsmScrollToHit = false;
				}
				n++;
			}
		}

		/// Shows a group's node on its Sheet (its type's file through the front end).
		void AsmShowNode(AsmGroup g)
		{
			let kt = FrontEnd?.Types.Lookup(g.Unit);
			if (kt == null || kt.Kind != .Named || kt.Sym.Path.IsEmpty)
				return;
			DebugFrame f = scope .();
			f.Path.Set(kt.Sym.Path);
			f.SheetKey.Set(g.SheetKey);
			f.NodeKey.Set(g.Node);
			ShowFrameNode(f);
		}
	}
}
