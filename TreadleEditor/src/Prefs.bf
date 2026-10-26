using System;
using System.Collections;
using System.IO;
using ImGui;
using Treadle.Language;

namespace Treadle.Editor
{
	/// Editor Preferences, stored per user in the "preferences" object of
	/// %LOCALAPPDATA%\Treadle\settings.json (see Settings), so they follow the user across
	/// projects. The old %APPDATA%\Treadle\EditorPreferences.ini is read once to migrate.
	static class Prefs
	{
		public static float FontSize = 16;
		/// 0 = Dark, 1 = Darker.
		public static int32 Theme = 0;
		public static bool GridSnap = true;
		public static bool ShowMinimap = false;
		/// Off (default): a node that is not wired into the flow is drawn faded and its warning is in the hover tooltip.
		/// On: it also gets the "Not connected" line and the yellow WARNING badge.
		public static bool VerboseNodeWarnings = false;
		/// Minutes between autosaves of modified files (0 = off).
		public static int32 AutosaveMinutes = 0;
		public static bool ShowToasts = true;
		/// Sleep the frame loop while nothing happens (Desktop.PaceFrame). Off = render every frame.
		public static bool IdlePacing = true;
		/// Seconds between recovery-journal writes of unsaved documents (0 = off). The journal
		/// is restored after a crash ("Recover unsaved changes?" on the next start).
		public static int32 RecoverySeconds = 30;
		/// Compile configuration when a project has no choice of its own: 0 = automatic (the
		/// configuration the project names, else Debug),
		/// 1 = Debug, 2 = Release.
		public static int32 DefaultConfig = 0;

		public static void GetPath(String outPath)
		{
			Settings.GetPath(outPath);
		}

		public static void Load()
		{
			Settings.Load();
			let p = Settings.Root.Get("preferences");
			if (p == null)
			{
				// First start: the defaults are written.
				Save();
				return;
			}
			FontSize = Math.Clamp((float)p.GetNumber("fontSize", FontSize), 11, 26);
			Theme = (int32)Math.Clamp(p.GetNumber("theme", Theme), 0, 1);
			GridSnap = p.GetBool("gridSnap", GridSnap);
			ShowMinimap = p.GetBool("showMinimap", ShowMinimap);
			VerboseNodeWarnings = p.GetBool("verboseNodeWarnings", VerboseNodeWarnings);
			AutosaveMinutes = (int32)Math.Clamp(p.GetNumber("autosaveMinutes", AutosaveMinutes), 0, 120);
			ShowToasts = p.GetBool("showToasts", ShowToasts);
			IdlePacing = p.GetBool("idlePacing", IdlePacing);
			RecoverySeconds = (int32)Math.Clamp(p.GetNumber("recoverySeconds", RecoverySeconds), 0, 3600);
			DefaultConfig = (int32)Math.Clamp(p.GetNumber("defaultConfig", DefaultConfig), 0, 2);
		}

		public static void Save()
		{
			Settings.Load();
			let p = Settings.Preferences;
			p.Set("fontSize", Json.NewNumber((int)FontSize));
			p.Set("theme", Json.NewNumber(Theme));
			p.Set("gridSnap", Json.NewBool(GridSnap));
			p.Set("showMinimap", Json.NewBool(ShowMinimap));
			p.Set("verboseNodeWarnings", Json.NewBool(VerboseNodeWarnings));
			p.Set("autosaveMinutes", Json.NewNumber(AutosaveMinutes));
			p.Set("showToasts", Json.NewBool(ShowToasts));
			p.Set("idlePacing", Json.NewBool(IdlePacing));
			p.Set("recoverySeconds", Json.NewNumber(RecoverySeconds));
			p.Set("defaultConfig", Json.NewNumber(DefaultConfig));
			Settings.Save();
		}

		/// Applies theme + font size at the current DPI.
		public static void ApplyAppearance()
		{
			Look.FontSize = FontSize;
			Look.Darker = Theme == 1;
			Look.Apply(Look.Scale);
		}
	}

	extension EditorApp
	{
		bool mShowPrefs;
		int32 mPrefsCategory;
		double mLastAutosave = -1;

		public void OpenPreferences()
		{
			mShowPrefs = true;
		}

		/// Editor Preferences > Node Hotkeys: every hotkey and favorite (global, settings.json
		/// `editor.nodeHotkeys` / `editor.favorites`), a Clear per key and Reset to Defaults. Keys
		/// are given in the Node menu (the key-capture control on a favorite's row).
		void DrawNodeHotkeyPrefs()
		{
			let prefs = NodePrefs;
			let hotkeys = prefs.Hotkeys;
			if (PropertyGrid.Section("Node Hotkeys", true, Icon.Keyboard))
			{
				PropertyGrid.InfoRow("How to use", "Hold the letter and click the Sheet, or press it while dragging a wire from a pin.", "Node hotkeys are plain letters; they work while the Sheet has the keyboard (no text field active)", 0, 0, true);
				PropertyGrid.InfoRow("Change a key", "Node menu: click the key box of a favorite, press a letter (Esc clears).", "The key-capture control is the small box before the star on a favorite's row", 0, 0, true);
				List<(char8 key, StringView nodeKey)> bindings = scope .();
				hotkeys.GetBindings(bindings);
				char8 clear = '\0';
				for (let b in bindings)
				{
					String cat = scope .(b.nodeKey);
					int tab = cat.IndexOf('\t');
					if (tab >= 0)
						cat.RemoveToEnd(tab);
					PropertyGrid.Row(scope String()..Append(b.key), scope $"Hold {b.key} and click the Sheet, or press {b.key} while dragging a wire");
					Gui.Text(Treadle.Catalog.NodeHotkeys.LabelOf(b.nodeKey));
					Gui.SameLine();
					Gui.TextColored(Look.ForegroundDim, scope $"({cat})");
					Gui.SameLine();
					if (Gui.SmallButton(scope $"Clear##hk{b.key}"))
						clear = b.key;
				}
				if (bindings.IsEmpty)
					PropertyGrid.InfoRow("Keys", "No node hotkeys. Reset to Defaults brings back the default set.");
				if (clear != '\0' && hotkeys.ClearKey(clear))
					prefs.SaveSettings();
				PropertyGrid.InfoRow("Taken by the Sheet", "C comment box, F frame, M minimap, Q straighten wires", "Letters the Sheet uses on their own; they cannot be node hotkeys", 0, 0, true);
			}
			if (PropertyGrid.Section("Favorites", true, Icon.Star))
			{
				for (let f in hotkeys.Favorites)
				{
					if (hotkeys.KeyOf(f) != '\0')
						continue;
					String cat = scope .(f);
					int tab = cat.IndexOf('\t');
					if (tab >= 0)
						cat.RemoveToEnd(tab);
					PropertyGrid.InfoRow(Treadle.Catalog.NodeHotkeys.LabelOf(f), scope $"{cat}  (no hotkey)", "A favorite with no hotkey");
				}
				PropertyGrid.InfoRow("Total", scope $"{hotkeys.Favorites.Count} favorites, {hotkeys.KeyCount} with a hotkey", "Favorites are listed first in the Node menu; the star on a row adds or removes one");
			}
			PropertyGrid.WideRow();
			if (PropertyGrid.Button("Reset to Defaults", 0, false, false, false, "The default favorites and keys (B Branch, S Sequence, E For Each Loop, ...). Your other favorites are removed."))
			{
				prefs.ResetHotkeys();
				Notify.Log(.Info, "Editor", "Node hotkeys and favorites reset to the defaults");
			}
		}

		/// Saves modified files every Prefs.AutosaveMinutes (off by default).
		void Autosave(double now)
		{
			if (mLastAutosave < 0)
				mLastAutosave = now;
			if (Prefs.AutosaveMinutes <= 0 || now - mLastAutosave < Prefs.AutosaveMinutes * 60.0)
				return;
			mLastAutosave = now;
			if (ModifiedCount == 0 || Gui.igIsAnyItemActive())
				return;
			SaveAll();
			Notify.Info("Autosaved modified files");
		}

		void DrawPreferences()
		{
			if (!mShowPrefs)
				return;
			let vp = Gui.igGetMainViewport();
			Gui.igSetNextWindowSize(.(780 * Look.Scale, 520 * Look.Scale), Cond.Appearing);
			Gui.igSetNextWindowPos(.(vp.Pos.x + vp.Size.x * 0.5f, vp.Pos.y + vp.Size.y * 0.5f), Cond.Appearing, .(0.5f, 0.5f));
			if (Gui.Begin(scope $"{Icon.Settings}  Editor Preferences###Editor Preferences", &mShowPrefs, WindowFlags.NoDocking | WindowFlags.NoCollapse | WindowFlags.NoSavedSettings))
			{
				// Category list on the left, like UE's Editor Preferences.
				Gui.igPushStyleColor_U32(Col.ChildBg, Look.Recessed);
				if (Gui.igBeginChild_Str("##prefcats", .(180 * Look.Scale, 0), ChildFlags.Borders, 0))
				{
					Gui.TextDisabled("General");
					StringView[6] cats = .("Appearance", "Graph Editor", "Saving", "Build", "Node Hotkeys", "Updates");
					StringView[6] icons = .(Icon.Palette, Icon.Workflow, Icon.Save, Icon.Compile, Icon.Keyboard, Icon.ArrowDownToLine);
					for (int i < cats.Count)
					{
						if (Gui.Selectable(scope $"  {icons[i]}  {cats[i]}", mPrefsCategory == i))
							mPrefsCategory = (int32)i;
					}
				}
				Gui.igEndChild();
				Gui.igPopStyleColor(1);
				Gui.SameLine();
				if (Gui.igBeginChild_Str("##prefbody", .(0, 0), 0, 0))
				{
					bool changed = false;
					if (PropertyGrid.Begin("##prefs"))
					{
						switch (mPrefsCategory)
						{
						case 0:
							if (PropertyGrid.Section("Appearance", true, Icon.Palette))
							{
								StringView[2] themes = .("Dark", "Darker");
								if (PropertyGrid.ComboRow("Theme", "##theme", ref Prefs.Theme, themes, "Editor colour theme"))
									changed = true;
								if (PropertyGrid.FloatRow("Font Size", "##fontsize", ref Prefs.FontSize, 0.1f, 11, 26, "%.0f px", "UI font size in pixels at 100% display scale (drag or double-click to type)"))
									changed = true;
								PropertyGrid.InfoRow("Display Scale", scope $"{(int)(Look.Scale * 100 + 0.5f)}%  (automatic)", "Follows the monitor the window is on (per-monitor DPI)");
								if (PropertyGrid.CheckRow("Show Notifications", "##toasts", ref Prefs.ShowToasts, "Toasts in the bottom-right corner (everything also goes to the Output Log)"))
									changed = true;
							}
						case 1:
							if (PropertyGrid.Section("Graph Editor", true, Icon.Workflow))
							{
								if (PropertyGrid.CheckRow("Snap to Grid", "##snap", ref Prefs.GridSnap, "Snap dragged and newly placed nodes to the 16-unit grid"))
									changed = true;
								if (PropertyGrid.CheckRow("Show Minimap", "##minimap", ref Prefs.ShowMinimap, "Overview of the whole graph in the bottom-right corner (M)"))
									changed = true;
								if (PropertyGrid.CheckRow("Verbose node warnings", "##verbosewarn", ref Prefs.VerboseNodeWarnings, "Show the \"Not connected\" line and the yellow WARNING badge on nodes that are not wired into the flow. Off: those nodes are only faded, and the hover tooltip still gives the warning text."))
									changed = true;
								if (PropertyGrid.CheckRow("Idle Frame Pacing", "##idlepacing", ref Prefs.IdlePacing, "Sleep the frame loop while nothing happens (near-zero CPU when idle). Turn off to render every frame; the TREADLE_NO_IDLE=1 environment variable also turns it off."))
								{
									Desktop.IdlePacing = Prefs.IdlePacing;
									Notify.Log(.Info, "Editor", Prefs.IdlePacing ? "Frame pacing: idle" : "Frame pacing: continuous");
									changed = true;
								}
							}
						case 2:
							if (PropertyGrid.Section("Saving", true, Icon.Save))
							{
								if (PropertyGrid.IntRow("Autosave Interval", "##autosave", ref Prefs.AutosaveMinutes, 0.2f, 0, 120, (Prefs.AutosaveMinutes == 0) ? "Off" : "%d min", "Save modified files every N minutes (0 = off)"))
									changed = true;
								if (PropertyGrid.IntRow("Recovery Journal", "##recovery", ref Prefs.RecoverySeconds, 0.5f, 0, 3600, (Prefs.RecoverySeconds == 0) ? "Off" : "%d s", "Copy unsaved documents to the recovery folder every N seconds (never into your project). After a crash the next start offers them back. 0 = off."))
									changed = true;
								String recDir = scope .();
								AppPaths.Root(recDir);
								recDir.AppendF("{}recovery", System.IO.Path.DirectorySeparatorChar);
								PropertyGrid.InfoRow("Recovery Folder", recDir, "Where the journal is kept");
								String logDir = scope .();
								AppPaths.Root(logDir);
								logDir.AppendF("{}logs", System.IO.Path.DirectorySeparatorChar);
								PropertyGrid.InfoRow("Logs Folder", logDir, "Session logs (the Output Log of every session) and crash reports");
							}
						case 3:
							if (PropertyGrid.Section("Build", true, Icon.Compile))
							{
								// Seam: the toolchain (compiler, clang / lld paths, versions) shows its rows here.
								bool ok = Language.Toolchain != null && !(Language.Toolchain is NullToolchain);
								PropertyGrid.InfoRow("Toolchain", ok ? scope $"{Icon.Ok}  installed" : scope $"{Icon.Error}  none in this build", "The compiler Validate (Shift+F7), Build (F7) and Run (F5) use", ok ? Look.Success : Look.Error);
								StringView[3] cfgs = .("Automatic", "Debug", "Release");
								if (PropertyGrid.ComboRow("Default Configuration", "##defcfg", ref Prefs.DefaultConfig, cfgs, "Build configuration for projects you have not chosen one for. Automatic: the configuration the project names, else Debug. The toolbar's configuration menu overrides it per project."))
									changed = true;
							}
						case 4:
							DrawNodeHotkeyPrefs();
						case 5:
							DrawUpdatePrefs();
						default:
						}
						PropertyGrid.End();
					}
					if (changed)
					{
						Prefs.ApplyAppearance();
						Prefs.Save();
					}
					Gui.igSpacing();
					String path = scope .();
					Prefs.GetPath(path);
					String savedLine = scope $"Saved to {path}";
					String savedShown = scope .();
					bool savedCut = Look.EllipsizeMiddle(savedLine, Gui.igGetContentRegionAvail().x, savedShown);
					Gui.TextDisabled(savedShown);
					if (savedCut && Gui.igIsItemHovered(0))
						Gui.Tooltip(path);
				}
				Gui.igEndChild();
			}
			Gui.End();
		}
	}
}
