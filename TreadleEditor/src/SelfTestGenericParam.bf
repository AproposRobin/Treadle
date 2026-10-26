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
	/// `genericparam` (needs an open project): a new struct, a class and an interface, each given a generic parameter
	/// (T) in Type Settings, then the Add Constraint picker opened on it and kept open for many frames, with and
	/// without a search typed; the picker built its rows from a list that was freed when the call returned, so the
	/// second frame read freed entries. The frames must keep coming. Also the Extends picker of an extension.
	extension EditorApp
	{
		int mGpPhase;
		int mGpWait;
		int mGpFrame0;
		TypeDocument mGpDoc;

		bool SelfTestGenericParam()
		{
			if (mGpWait > 0)
			{
				mGpWait--;
				return false;
			}
			if (mGpPhase == 0 && mProjectRoot.IsEmpty)
			{
				SelfTestCheck(false, "genericparam: needs an open project");
				return true;
			}
			// phases 0..19: three types x (create + parameter, open picker, check + close, open with search, check + close)
			int step = mGpPhase % 5;
			int which = mGpPhase / 5;
			if (which >= 4)
			{
				mGpPhase = 0;
				return true;
			}
			String[4] names = .("GP_Box", "GP_Thing", "GP_Shape", "GP_Ext");
			TypeKind[4] kinds = .(.Struct, .Class, .Interface, .Extension);
			String id = (which == 3) ? "##tsextends" : "##gcadd";
			switch (step)
			{
			case 0:
				mGpDoc = CreateType(kinds[which], mProjectRoot, names[which]);
				SelfTestCheck(mGpDoc != null, scope $"genericparam: a new {kinds[which]} {names[which]}");
				if (mGpDoc == null)
					return true;
				if (which < 3 && BeginTypeEdit())
				{
					GenericParam gp = new .();
					gp.Name.Set("T");
					Doc.Header.Generics.Add(gp);
					EndTypeEdit();
				}
				SelectOutline(.TypeSettings);
				mGpWait = 8;
				mGpPhase++;
			case 1, 3:
				SelectOutline(.TypeSettings);
				PropertyGrid.ForceOpen.Set("Generic Parameters");
				TypeCombo.TestClose = false;
				TypeCombo.TestOpen.Set(id);
				if (step == 3)
					TypeCombo.TestSearch.Set("I");
				mGpFrame0 = mFrame;
				mGpWait = 20;
				mGpPhase++;
			case 2, 4:
				SelfTestCheck(mFrame >= mGpFrame0 + 15 && LastFrameMs < 2000 && Gui.igIsPopupOpen_Str("", PopupFlags.AnyPopup), scope $"genericparam: {names[which]}: the picker stays open ({mFrame - mGpFrame0} frames, front {Doc == mGpDoc}, {Doc.Header.Generics.Count} parameter(s), outline {OutlineSel}, popup {Gui.igIsPopupOpen_Str("", PopupFlags.AnyPopup)})");
				TypeCombo.TestClose = true;
				mGpWait = 3;
				mGpPhase++;
			}
			return false;
		}
	}
}
#endif
