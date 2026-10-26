using System;
using ImGui;

namespace Treadle.Editor
{
	/// Dear ImGui entry points of the host (treadlehost) that the shared bindings in Native do not
	/// declare yet, and small helpers of the Under the hood panels (Layout, Memory, Disassembly).
	static class HoodGui
	{
		[CLink] public static extern void igTableHeadersRow();

		/// The monospace font at the size of the text around it (as Properties' code lines).
		public static bool PushMono(float scale = 0.92f)
		{
			let mono = PropertyGrid.MonoFont;
			if (mono == null)
				return false;
			Gui.igPushFont(mono, Gui.igGetFontSize() / Math.Max(Look.Scale, 0.5f) * scale);
			return true;
		}

		public static void PopMono(bool pushed)
		{
			if (pushed)
				Gui.igPopFont();
		}

		/// Two-state switch drawn as two small buttons, the active one filled. True when `value` changed.
		public static bool Toggle(StringView id, StringView off, StringView on, ref bool value, StringView tip)
		{
			bool changed = false;
			Gui.PushID(id);
			for (int i < 2)
			{
				let active = (i == 1) == value;
				if (active)
					Gui.igPushStyleColor_U32(Col.Button, Theme.WithAlpha(Look.Primary, 200));
				if (i > 0)
					Gui.SameLine(0, 0);
				if (Gui.SmallButton((i == 0) ? off : on) && !active)
				{
					value = (i == 1);
					changed = true;
				}
				if (active)
					Gui.igPopStyleColor(1);
				if (Gui.igIsItemHovered(0) && !tip.IsEmpty)
					Gui.Tooltip(tip);
			}
			Gui.PopID();
			return changed;
		}
	}
}
