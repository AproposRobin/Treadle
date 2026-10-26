// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.IO;
using ImGui;
using Treadle.Document;
using Treadle.Model;

namespace Treadle.Editor
{
	/// `enumunder` (needs an open project): an enum with three cases in Type Settings with the Layout section open, its
	/// Underlying Type set to uint8, int32 and uint8 again, then a case value above 255, each change a few frames apart;
	/// the frames must keep coming (no frame over 2 s), the layout must follow the underlying type, and a rendered
	/// pixel must read back.
	extension EditorApp
	{
		int mEuPhase;
		int mEuWait;
		double mEuT0;
		int mEuFrame0;
		TypeDocument mEuDoc;
		int mEuIter;
		int mEuBad;
		int mEuSlow;
		int mEuGarbage;
		int mEuMaxVtx;
		TypeDocument mEuBig;
		TypeDocument mEuHolder;

		void EuSetUnderlying(StringView v)
		{
			if (mEuDoc != null && Doc != mEuDoc)
				ActivateType(mEuDoc); // Validate can bring another type to the front
			if (mEuDoc == null || Doc != mEuDoc || !BeginTypeEdit())
			{
				Notify.Log(.Warning, "SelfTest", scope $"enumunder: the enum is not the document in front ({(Doc == mEuDoc)})");
				return;
			}
			let h = Doc.Header;
			delete h.Underlying;
			h.Underlying = v.IsEmpty ? null : TypeRef.Parse(v);
			EndTypeEdit();
			SelectOutline(.TypeSettings);
		}

		bool EuLayoutSize(out int64 size)
		{
			size = -1;
			let l = TypeLayouts.Get(FrontEnd, "E_LogVerbosity");
			if (l == null || !l.Ok)
				return false;
			size = l.Size;
			return true;
		}

		bool SelfTestEnumUnder()
		{
			if (mEuWait > 0)
			{
				mEuWait--;
				return false;
			}
			switch (mEuPhase)
			{
			case 0:
				if (mProjectRoot.IsEmpty)
				{
					SelfTestCheck(false, "enumunder: needs an open project");
					return true;
				}
				PropertyGrid.ForceOpen.Set("Layout");
				mEuDoc = CreateType(.Enum, mProjectRoot, "E_LogVerbosity");
				SelfTestCheck(mEuDoc != null, "enumunder: a new enum E_LogVerbosity");
				if (mEuDoc == null)
					return true;
				AddCase("Verbose");
				AddCase("Warning");
				AddCase("Error");
				SelectOutline(.TypeSettings);
				mEuPhase = 1;
				mEuWait = 10;
			case 1, 3, 5:
				// the change
				let v = mEuPhase == 3 ? "int32" : "uint8";
				Notify.Log(.Info, "SelfTest", scope $"enumunder: Underlying Type {v}");
				mEuT0 = Desktop.Now;
				mEuFrame0 = mFrame;
				EuSetUnderlying(v);
				mEuPhase++;
				mEuWait = 10;
			case 2, 4, 6:
				let v = mEuPhase == 4 ? "int32" : "uint8";
				let expect = mEuPhase == 4 ? 4 : 1;
				let ok = EuLayoutSize(let size);
				SelfTestCheck(mFrame >= mEuFrame0 + 10 && LastFrameMs < 2000, scope $"enumunder: after Underlying Type {v} the frames keep coming ({mFrame - mEuFrame0} frames in {(int)((Desktop.Now - mEuT0) * 1000)} ms)");
				SelfTestCheck(ok && size == expect, scope $"enumunder: the layout follows: {expect} byte(s) (ok {ok}, size {size})");
				mEuPhase++;
			case 7:
				// a case value above 255 with uint8 underneath
				if (Doc == mEuDoc && BeginTypeEdit())
				{
					for (let m in Doc.Members)
						if (m.Kind == .Case && m.Name == "Error")
						{
							delete m.CaseValue;
							m.CaseValue = new String("300");
						}
					EndTypeEdit();
				}
				SelectOutline(.TypeSettings);
				mEuT0 = Desktop.Now;
				mEuFrame0 = mFrame;
				mEuPhase = 8;
				mEuWait = 10;
			case 8:
				SelfTestCheck(mFrame >= mEuFrame0 + 10 && LastFrameMs < 2000, scope $"enumunder: a case value of 300 on uint8: the frames keep coming ({mFrame - mEuFrame0} frames in {(int)((Desktop.Now - mEuT0) * 1000)} ms)");
				Host.th_gl_probe_request();
				mEuPhase = 9;
				mEuWait = 2;
			case 9:
				if (!GlProbeDone(let ok, let px))
					return false;
				SelfTestCheck(ok, scope $"enumunder: and a frame renders (0x{px:X8})");
				mEuPhase = 20;
			case 20, 24, 28:
				// the same through the picker, as the owner did: open it, type the name, Enter
				let v = mEuPhase == 24 ? "int32" : "uint8";
				Notify.Log(.Info, "SelfTest", scope $"enumunder: the Underlying Type picker: {v}");
				SelectOutline(.TypeSettings);
				TypeCombo.TestOpen.Set("##tsunder");
				TypeCombo.TestSearch.Set(v); // the search text as the picker opens
				mEuT0 = Desktop.Now;
				mEuFrame0 = mFrame;
				mEuPhase++;
				mEuWait = 12;
			case 21, 25, 29:
				let io = FocusNative.igGetIO_Nil();
				FocusNative.ImGuiIO_AddKeyEvent(io, Key.Enter, true);
				mEuPhase++;
				mEuWait = 2;
			case 22, 26, 30:
				let io = FocusNative.igGetIO_Nil();
				FocusNative.ImGuiIO_AddKeyEvent(io, Key.Enter, false);
				mEuPhase++;
				mEuWait = 10;
			case 23, 27, 31:
				let v = mEuPhase == 27 ? "int32" : "uint8";
				let under = (mEuDoc != null && mEuDoc.Header.Underlying != null) ? mEuDoc.Header.Underlying.ToString(.. scope String()) : scope:: String("(none)");
				SelfTestCheck(under == v && mFrame >= mEuFrame0 + 20 && LastFrameMs < 2000,
					scope $"enumunder: the picker sets {v} (now {under}) and the frames keep coming ({mFrame - mEuFrame0} frames in {(int)((Desktop.Now - mEuT0) * 1000)} ms)");
				if (Gui.igIsPopupOpen_Str("", PopupFlags.AnyPopup))
					TypeCombo.TestClose = true;
				mEuPhase = (mEuPhase == 31) ? 50 : mEuPhase + 1;
				mEuWait = 3;
			case 50:
				// the owner's sequence, many times: int <-> uint8, Validate, Save (both orders), the Layout section open
				// and closed; Validate's checks run in the background while the next change comes
				mEuIter = 0;
				mEuBad = 0;
				mEuGarbage = 0;
				mEuSlow = 0;
				mEuPhase = 51;
			case 51:
				let open = (mEuIter / 10) % 2 == 0;
				PropertyGrid.ForceOpen.Set(open ? "Layout" : "");
				PropertyGrid.ForceClosed.Set(open ? "" : "Layout");
				EuSetUnderlying((mEuIter % 2 == 0) ? "uint8" : "int");
				if (mEuIter % 4 < 2)
				{
					Validate(true);
					Save();
				}
				else
				{
					Save();
					Validate(true);
				}
				mEuFrame0 = mFrame;
				mEuT0 = Desktop.Now;
				mEuPhase = 52;
				mEuWait = 2;
			case 52:
				if (LastFrameMs > 2000)
					mEuSlow++;
				let ok = EuLayoutSize(let size);
				let expect = (mEuIter % 2 == 0) ? 1 : 8; // int is 64-bit
				if (ok && size != expect && size != 1 && size != 8)
				{
					mEuGarbage++; // never a size of neither type: no layout read mid-rebuild
					Notify.Log(.Warning, "SelfTest", scope $"enumunder: iteration {mEuIter}: layout size {size}");
				}
				// the front end takes the change in the background: the layout follows within a few seconds
				if ((!ok || size != expect) && Desktop.Now - mEuT0 < 5)
					return false;
				if (!ok || size != expect)
				{
					mEuBad++;
					if (mEuBad <= 5)
						Notify.Log(.Warning, "SelfTest", scope $"enumunder: iteration {mEuIter}: layout size {size} (ok {ok}), expected {expect}");
				}
				if (++mEuIter < 200)
				{
					mEuPhase = 51;
					return false;
				}
				SelfTestCheck(mEuBad == 0 && mEuSlow == 0 && mEuGarbage == 0, scope $"enumunder: 200 rounds of int <-> uint8 with Validate and Save, Layout open and closed: the layout follows every change within 5 s ({mEuBad} did not), never a wrong size ({mEuGarbage}), no frame over 2 s ({mEuSlow})");
				PropertyGrid.ForceClosed.Clear();
				mEuPhase = 60;
			case 60:
				// a class with a StringView and a List, and a struct of 1 MB, each with Layout open, switched quickly
				PropertyGrid.ForceOpen.Set("Layout");
				let holder = CreateType(.Class, mProjectRoot, "LayoutHolder");
				if (holder != null)
				{
					AddField("Name", "StringView");
					AddField("Items", "List<int>");
				}
				let big = CreateType(.Struct, mProjectRoot, "LayoutBig");
				if (big != null)
					AddField("Data", "uint8[1048576]");
				mEuBig = big;
				mEuHolder = holder;
				mEuIter = 0;
				mEuMaxVtx = 0;
				mEuPhase = 61;
				mEuWait = 5;
			case 61:
				mEuMaxVtx = Math.Max(mEuMaxVtx, Host.th_last_vtx_count());
				if (mEuIter < 60)
				{
					let d = (mEuIter % 3 == 0) ? mEuHolder : (mEuIter % 3 == 1) ? mEuBig : mEuDoc;
					if (d != null)
						ActivateType(d);
					SelectOutline(.TypeSettings);
					mEuIter++;
					return false;
				}
				let lb = TypeLayouts.Get(FrontEnd, "LayoutBig");
				let okBig = lb != null && lb.Ok && lb.Size >= 1048576;
				SelfTestCheck(mEuHolder != null && mEuBig != null && LastFrameMs < 2000, scope $"enumunder: a class with StringView and List fields and a 1 MB struct, Layout open, switched 60 times: the frames keep coming");
				SelfTestCheck(mEuMaxVtx < 200000, scope $"enumunder: the draw lists stay small with the 1 MB struct's Layout open (largest frame {mEuMaxVtx} vertices; the 1 MB layout {(okBig ? "computed" : "not computed")})");
				ActivateType(mEuBig);
				SelectOutline(.TypeSettings);
				Host.th_gl_probe_request();
				mEuPhase = 62;
				mEuWait = 3;
			case 62:
				if (!GlProbeDone(let ok, let px))
					return false;
				SelfTestCheck(ok, scope $"enumunder: with the 1 MB struct's Layout shown a frame renders (0x{px:X8})");
				for (let d in mDocs)
					d.Modified = false;
				mEuPhase = 40;
			case 40:
				PropertyGrid.ForceOpen.Clear();
				if (mEuDoc != null)
					mEuDoc.Modified = false;
				mEuPhase = 0;
				return true;
			}
			return false;
		}
	}
}
#endif
