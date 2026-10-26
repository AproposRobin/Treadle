using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using ImGui;
using Treadle.Update;

namespace Treadle.Editor
{
	/// Update settings (docs/Getting-Started.md, "Updating"), in settings.json:
	///   "updates": { "checkForUpdates": true, "channel": "alpha" | "stable", "skippedVersions": [...], "lastCheck": <unix s> }
	///   "preferences": { "workOffline": false }
	/// checkForUpdates: look once a day, a few seconds after start (and once a day while open); false = only when asked.
	/// channel alpha (default) also offers GitHub pre-releases. workOffline: no network use at all.
	static class UpdatePrefs
	{
		public static bool CheckForUpdates = true;
		/// 0 = alpha, 1 = stable.
		public static int32 Channel = 0;
		public static bool WorkOffline = false;
		public static List<String> Skipped = new .() ~ DeleteContainerAndItems!(_);
		/// Unix seconds of the last check that reached the release list (0 = never).
		public static int64 LastCheck;

		public static StringView ChannelName => (Channel == 1) ? "stable" : "alpha";

		public static int64 NowUnix => (DateTime.UtcNow.Ticks - DateTime(1970, 1, 1).Ticks) / TimeSpan.TicksPerSecond;

		public static void Load()
		{
			Settings.Load();
			let p = Settings.Root.Get("preferences");
			if (p != null)
				WorkOffline = p.GetBool("workOffline", false);
			let u = Settings.Root.Get("updates");
			if (u == null)
				return;
			CheckForUpdates = u.GetBool("checkForUpdates", u.GetBool("check", true));
			Channel = (u.GetString("channel", "alpha") == "stable") ? 1 : 0;
			LastCheck = (int64)u.GetNumber("lastCheck", 0);
			ClearAndDeleteItems!(Skipped);
			let s = u.Get("skippedVersions");
			if (s != null && s.Items != null)
				for (let item in s.Items)
					if (item.Str != null && GitHubReleases.IsSafeSegment(item.Str))
						Skipped.Add(new String(item.Str));
		}

		public static void Save()
		{
			Settings.Load();
			Settings.Preferences.Set("workOffline", Json.NewBool(WorkOffline));
			let u = Settings.Root.Obj("updates");
			u.Remove("check");
			u.Set("checkForUpdates", Json.NewBool(CheckForUpdates));
			u.Set("channel", Json.NewString(ChannelName));
			u.Set("lastCheck", Json.NewNumber(LastCheck));
			let arr = Json.NewArray();
			for (let v in Skipped)
				arr.Items.Add(Json.NewString(v));
			u.Set("skippedVersions", arr);
			Settings.Save();
		}

		public static void Skip(StringView version)
		{
			for (let v in Skipped)
				if (v == version)
					return;
			Skipped.Add(new String(version));
			Save();
		}
	}

	extension EditorApp
	{
		UpdateService mUpdates ~ delete _;
		UpdateStatus mUpdateView = new .() ~ delete _;
		int32 mUpdateSerialSeen = -1;
		double mUpdateNextAuto = -1;
		/// "Later" (or Skip) hides the notice line for the rest of the session; a different newer version found later
		/// in the session shows it again (mUpdateHiddenVersion: the version it was hidden for).
		bool mUpdateHidden;
		String mUpdateHiddenVersion = new .() ~ delete _;
		/// The reason Restart was refused (shown in the notice line), cleared once it no longer applies.
		String mUpdateBlocked = new .() ~ delete _;
		/// Unsaved files when Restart was refused for them (0: refused for another reason); the reason clears once they are saved.
		int mUpdateBlockedUnsaved;
		int32 mUpdateFrames;
		bool mUpdateAutoRunning;
		/// The "What changed" panel and Help > About.
		bool mShowUpdateNotes;
		bool mShowAbout;
		/// Shown last frame (a panel that just opened is brought to the front once).
		bool mUpdateNotesShown;
		bool mAboutShown;
		const double cUpdateFirstDelay = 8.0;
		const double cUpdateInterval = 24 * 3600.0;

		public void InitUpdates()
		{
			UpdatePrefs.Load();
			mUpdates = new .();
			mUpdates.OnLog = new (line) => Notify.Log(.Info, "Update", line);
			String dir = scope .();
			AppPaths.Root(dir);
			dir.AppendF("{}update", Path.DirectorySeparatorChar);
			mUpdates.Init(dir);
			mUpdates.Channel.Set(UpdatePrefs.ChannelName);
			mUpdates.SetSkipped(UpdatePrefs.Skipped);
			for (let a in UpdateCli.EditorArgs)
				mUpdates.RestartArgs.Add(new String(a));
			String why = scope .();
			mUpdates.AutomaticBlocker(why);
			Notify.Log(.Verbose, "Update", scope $"Treadle {mUpdates.RunningVersion}, updates {(UpdatePrefs.WorkOffline ? "off (Work offline)" : UpdatePrefs.CheckForUpdates ? "checked once a day" : "checked when asked")}, channel {UpdatePrefs.ChannelName}{(why.IsEmpty ? "" : ": ")}{why}");
			String msg = scope .();
			if (mUpdates.TakeLastResult(let ok, msg))
			{
				if (ok)
					Notify.Success(msg);
				else
					Notify.Error(scope $"Update failed: {msg}");
			}
			ScheduleAutoCheck();
		}

		/// The next automatic check: 8 s after start when the last one is a day old, else when the day is up.
		void ScheduleAutoCheck()
		{
			mUpdateNextAuto = -1;
			String why = scope .();
			mUpdates.AutomaticBlocker(why);
			if (!why.IsEmpty || !UpdatePrefs.CheckForUpdates || UpdatePrefs.WorkOffline)
				return;
			let age = (double)(UpdatePrefs.NowUnix - UpdatePrefs.LastCheck);
			let wait = (UpdatePrefs.LastCheck <= 0 || age < 0 || age >= cUpdateInterval) ? cUpdateFirstDelay : Math.Max(cUpdateFirstDelay, cUpdateInterval - age);
			mUpdateNextAuto = Desktop.Now + wait;
		}

		/// Help > Check for Updates and the Preferences button.
		public void CheckForUpdatesNow()
		{
			if (mUpdates == null)
				return;
			if (UpdatePrefs.WorkOffline)
			{
				Notify.Info("Work offline is on (Editor Preferences > Updates), so Treadle makes no network requests.");
				return;
			}
			mUpdateHidden = false;
			mUpdates.Channel.Set(UpdatePrefs.ChannelName);
			mUpdates.SetSkipped(UpdatePrefs.Skipped);
			if (mUpdates.Install.Kind == .HostManaged)
			{
				String why = scope .();
				mUpdates.AutomaticBlocker(why);
				Notify.Info(why);
				return;
			}
			if (mUpdateView.State == .Ready)
			{
				SetStatus(scope $"Treadle {mUpdateView.LatestVersion} is downloaded and verified; Restart to finish is in the notice line.", .Info, false);
				return;
			}
			if (!mUpdates.StartCheck(true))
				Notify.Info("An update check or download is already running.");
			else
				SetStatus("Checking for updates...", .Info, false);
		}

		void UpdateTick()
		{
			if (mUpdates == null)
				return;
			mUpdateFrames++;
			// The helper that installed this version waits for a sign of life before it lets the update stand.
			if (mUpdateFrames == 30)
				UpdateApply.ReportHealthy(mUpdates.UpdateDir);
			let now = Desktop.Now;
			if (mUpdateNextAuto > 0 && now >= mUpdateNextAuto && mSelfTestStep == -2)
			{
				mUpdateNextAuto = now + cUpdateInterval;
				if (UpdatePrefs.CheckForUpdates && !UpdatePrefs.WorkOffline)
				{
					mUpdates.Channel.Set(UpdatePrefs.ChannelName);
					mUpdates.SetSkipped(UpdatePrefs.Skipped);
					mUpdateAutoRunning = mUpdates.StartCheck(false);
				}
			}
			mUpdates.GetStatus(mUpdateView);
			if (mUpdateView.Serial != mUpdateSerialSeen)
			{
				mUpdateSerialSeen = mUpdateView.Serial;
				Desktop.Wake();
				if (mUpdateView.Reached && mUpdateView.State != .Checking && (mUpdateView.State == .UpToDate || mUpdateView.State == .Available))
				{
					UpdatePrefs.LastCheck = UpdatePrefs.NowUnix;
					UpdatePrefs.Save();
				}
				// The answer to a check the user asked for: a toast, also when there is nothing to install.
				if (mUpdateView.Manual && !mUpdateView.Message.IsEmpty)
				{
					switch (mUpdateView.State)
					{
					case .UpToDate: SetStatus(mUpdateView.Message, .Info);
					case .Unavailable: SetStatus(mUpdateView.Message, .Warning);
					case .Available, .Error: mStatus.Set(mUpdateView.Message);
					default:
					}
				}
			}
			// Later hid the line for one version: a different newer version shows it again.
			if (mUpdateHidden && (mUpdateView.State == .Available || mUpdateView.State == .Ready) && mUpdateView.LatestVersion != mUpdateHiddenVersion)
				mUpdateHidden = false;
			if (!mUpdateBlocked.IsEmpty && (mUpdateView.State != .Ready || (mUpdateBlockedUnsaved > 0 && ModifiedCount == 0)))
				mUpdateBlocked.Clear();
		}

		bool UpdateBusyElsewhere => (mBuild != null && mBuild.Running) || IsDebugging;

		void RestartToUpdate()
		{
			mUpdateBlocked.Clear();
			// Save everything first: files with a path are saved, untitled ones block the restart.
			if (ModifiedCount > 0)
				SaveAll();
			mUpdates.ApplyBlocker(ModifiedCount, UpdateBusyElsewhere, mUpdateBlocked);
			mUpdateBlockedUnsaved = ModifiedCount;
			if (!mUpdateBlocked.IsEmpty)
			{
				Notify.Warn(mUpdateBlocked);
				return;
			}
			String why = scope .();
			if (!mUpdates.Apply(why))
			{
				mUpdateBlocked.Set(why);
				Notify.Error(why);
				return;
			}
			SaveSettings();
			QuitNow = true;
		}

		/// One button of the update flow, from the notice line, Editor Preferences > Updates, or Help.
		void RunUpdateAction(StringView action)
		{
			let s = mUpdateView;
			switch (action)
			{
			case "Update now":
				if (!mUpdates.StartDownload())
					Notify.Warn("The download could not be started.");
			case "What changed": mShowUpdateNotes = true;
			case "Later":
				mUpdateHidden = true;
				mUpdateHiddenVersion.Set(s.LatestVersion);
			case "Skip this version":
				UpdatePrefs.Skip(s.LatestVersion);
				mUpdates.SetSkipped(UpdatePrefs.Skipped);
				mUpdates.Dismiss();
				mUpdateHidden = true;
				mUpdateHiddenVersion.Set(s.LatestVersion);
				Notify.Info(scope $"Treadle {s.LatestVersion} will not be offered again (Editor Preferences > Updates can undo it).");
			case "Restart to finish": RestartToUpdate();
			case "Cancel": mUpdates.Cancel();
			case "Dismiss":
				mUpdates.Dismiss();
				mUpdateHidden = true;
			default:
			}
		}

		bool UpdateIsOffered
		{
			get
			{
				if (mUpdates == null || mUpdateView.LatestVersion.IsEmpty)
					return false;
				let st = mUpdateView.State;
				return st == .Available || st == .Downloading || st == .Verifying || st == .Ready;
			}
		}

		/// Opens Editor Preferences on Updates (its category index).
		void OpenUpdatePrefs()
		{
			OpenPreferences();
			mPrefsCategory = 5;
		}

		/// Help > "Update to X..." (shown while a version is known): starts the download when it is available, and
		/// otherwise shows the progress and Restart to finish in Editor Preferences > Updates.
		void UpdateFromMenu()
		{
			mUpdateHidden = false;
			if (mUpdateView.State == .Available && !mUpdateView.ReadOnlyInstall)
				RunUpdateAction("Update now");
			else
				OpenUpdatePrefs();
		}

		/// The status bar item: the download's progress, or (while the notice line is hidden) a waiting update; "" when none.
		void UpdateStatusLabel(String outLabel)
		{
			if (!UpdateIsOffered)
				return;
			let s = mUpdateView;
			switch (s.State)
			{
			case .Downloading:
				if (s.Total > 0)
					outLabel.AppendF("{}  Treadle {}: {}%", Icon.ArrowDownToLine, s.LatestVersion, (int)(Math.Clamp((float)s.Received / (float)s.Total, 0, 1) * 100));
				else
					outLabel.AppendF("{}  Treadle {}: {} MB", Icon.ArrowDownToLine, s.LatestVersion, s.Received / (1024 * 1024));
			case .Verifying: outLabel.AppendF("{}  Checking Treadle {}", Icon.ArrowDownToLine, s.LatestVersion);
			case .Available:
				if (mUpdateHidden)
					outLabel.AppendF("{}  Update available", Icon.ArrowDownToLine);
			case .Ready:
				if (mUpdateHidden)
					outLabel.AppendF("{}  Update ready to finish", Icon.ArrowDownToLine);
			default:
			}
		}

		/// One text of the notice line, cut with "..." to end before `limitX` (window coordinates); the whole text is the
		/// tooltip of a cut one.
		void UpdateBarText(StringView text, uint32 color, float limitX)
		{
			Gui.igAlignTextToFramePadding();
			float avail = limitX - Gui.igGetCursorPosX();
			String shown = scope .(text);
			bool cut = false;
			if (Gui.CalcTextSize(shown).x > avail)
			{
				cut = true;
				while (shown.Length > 0 && Gui.CalcTextSize(scope $"{shown}...").x > avail)
				{
					shown.RemoveFromEnd(1);
					while (shown.Length > 0 && ((uint8)shown[shown.Length - 1] & 0xC0) == 0x80)
						shown.RemoveFromEnd(1);
					if (shown.Length > 0 && (uint8)shown[shown.Length - 1] >= 0xC0)
						shown.RemoveFromEnd(1);
				}
				shown.Append("...");
			}
			if (color == 0)
				Gui.Text(shown);
			else
				Gui.TextColored(color, shown);
			if (cut && Gui.igIsItemHovered(0))
				Gui.Tooltip(text);
		}

		/// The notice line under the toolbar: shown while an update is available, downloading, ready, or failed. Never
		/// modal; Later / Skip hide it for the session.
		void DrawUpdateBar()
		{
			if (mUpdates == null || mUpdateHidden)
				return;
			let s = mUpdateView;
			bool show = s.State == .Available || s.State == .Downloading || s.State == .Verifying || s.State == .Ready ||
				(s.State == .Error && s.Manual) || (s.State == .Error && !s.LatestVersion.IsEmpty);
			if (!show)
				return;
			let vp = Gui.igGetMainViewport();
			float fs = Gui.igGetFontSize();
			float h = Math.Round(fs * 2.0f);
			Gui.igPushStyleVar_Vec2(StyleVar.WindowPadding, .(10 * Look.Scale, 0));
			Gui.igPushStyleVar_Vec2(StyleVar.FramePadding, .(10 * Look.Scale, fs * 0.15f));
			Gui.igPushStyleColor_U32(Col.WindowBg, Look.Header);
			int32 flags = WindowFlags.NoScrollbar | WindowFlags.NoSavedSettings | WindowFlags.NoScrollWithMouse;
			if (Gui.igBeginViewportSideBar("##VBUpdateBar", vp, Dir.Up, h, flags))
			{
				Gui.igSetCursorPosY((h - Gui.igGetFrameHeight()) * 0.5f);
				uint32 iconColor = Look.AccentBlue;
				String icon = Icon.ArrowDownToLine;
				String text = scope .();
				switch (s.State)
				{
				case .Available:
					if (s.ReadOnlyInstall)
						text.AppendF("Treadle {} is available. The install folder is read-only: download and unpack it by hand from {}", s.LatestVersion, s.NotesUrl);
					else
						text.AppendF("Treadle {} is available.", s.LatestVersion);
					if (!s.Message.IsEmpty && s.Message.StartsWith("Download cancelled"))
						text.Append(" Download cancelled.");
				case .Downloading:
					text.AppendF("Downloading Treadle {}...", s.LatestVersion);
				case .Verifying:
					text.AppendF("Checking Treadle {}...", s.LatestVersion);
				case .Ready:
					text.AppendF("Treadle {} is downloaded and verified.", s.LatestVersion);
					icon = Icon.Ok;
					iconColor = Look.Success;
				case .Error:
					text.Set(s.Message);
					icon = Icon.Warning;
					iconColor = Look.Warning;
				default:
				}
				// Buttons on the right; the texts are cut (with the whole text as a tooltip) so they never run under them.
				float spacing = 6 * Look.Scale;
				List<StringView> buttons = scope .();
				switch (s.State)
				{
				case .Available:
					if (!s.ReadOnlyInstall)
						buttons.Add("Update now");
					buttons.Add("What changed"); buttons.Add("Later"); buttons.Add("Skip this version");
				case .Downloading: buttons.Add("Cancel");
				case .Ready: buttons.Add("Restart to finish"); buttons.Add("What changed"); buttons.Add("Later");
				case .Error: buttons.Add("Dismiss");
				default:
				}
				float total = 0;
				for (let b in buttons)
					total += Gui.CalcTextSize(b).x + Gui.igGetStyle().FramePadding.x * 2 + spacing;
				float right = Gui.igGetWindowWidth() - total - 4 * Look.Scale;
				float gap = 12 * Look.Scale;
				bool progress = s.State == .Downloading || s.State == .Verifying;
				String progressText = scope .();
				float f = 0;
				if (progress)
				{
					f = (s.Total > 0) ? Math.Clamp((float)s.Received / (float)s.Total, 0, 1) : 0;
					if (s.State == .Verifying)
						f = 1;
					if (s.State == .Downloading && s.Total > 0)
						progressText.AppendF("{}%  {} / {} MB", (int)(f * 100), s.Received / (1024 * 1024), (s.Total + 1024 * 1024 - 1) / (1024 * 1024));
					else
						progressText.Append("SHA-256");
				}
				float barW = 180 * Look.Scale;
				float reserve = 0;
				if (progress)
					reserve = gap + barW + 8 * Look.Scale + Gui.CalcTextSize(progressText).x;
				bool blocked = !mUpdateBlocked.IsEmpty && s.State == .Ready;
				if (blocked)
					reserve = Math.Min(gap + Gui.CalcTextSize(mUpdateBlocked).x, (right - Gui.igGetCursorPosX()) * 0.55f);

				Gui.igAlignTextToFramePadding();
				Gui.TextColored(iconColor, icon);
				Gui.SameLine(0, 8 * Look.Scale);
				UpdateBarText(text, 0, right - gap - reserve);
				if (progress && Gui.igGetCursorPosX() + reserve < right)
				{
					Gui.SameLine(0, gap);
					let pos = Gui.igGetCursorScreenPos();
					float bh = fs * 0.45f;
					float y = pos.y + (Gui.igGetFrameHeight() - bh) * 0.5f;
					let dl = Gui.igGetWindowDrawList();
					Gui.ImDrawList_AddRectFilled(dl, .(pos.x, y), .(pos.x + barW, y + bh), Look.Recessed, 2, 0);
					Gui.ImDrawList_AddRectFilled(dl, .(pos.x, y), .(pos.x + barW * f, y + bh), Look.Primary, 2, 0);
					Gui.igDummy(.(barW, Gui.igGetFrameHeight()));
					Gui.SameLine(0, 8 * Look.Scale);
					UpdateBarText(progressText, Look.ForegroundDim, right - gap);
				}
				if (blocked)
				{
					Gui.SameLine(0, gap);
					UpdateBarText(mUpdateBlocked, Look.Warning, right - gap);
				}
				Gui.SameLine(Math.Max(right, Gui.igGetCursorPosX() + gap), 0);
				for (let b in buttons)
				{
					bool primary = b == "Update now" || b == "Restart to finish";
					if (primary)
					{
						Gui.igPushStyleColor_U32(Col.Button, Look.Primary);
						Gui.igPushStyleColor_U32(Col.ButtonHovered, Look.PrimaryHover);
						Gui.igPushStyleColor_U32(Col.ButtonActive, Look.PrimaryPress);
					}
					bool clicked = Gui.Button(scope $"{b}##upd");
#if TREADLE_SELFTEST
					if (b == "Update now")
					{
						mUpNowMin = Gui.igGetItemRectMin();
						mUpNowMax = Gui.igGetItemRectMax();
					}
#endif
					if (primary)
						Gui.igPopStyleColor(3);
					if (Gui.igIsItemHovered(0))
					{
						switch (b)
						{
						case "Update now": Gui.Tooltip("Download the new version now; it is checked against the release's SHA256SUMS before anything is installed");
						case "What changed": Gui.Tooltip("The release notes of the new version");
						case "Later": Gui.Tooltip("Hide this until the next start");
						case "Skip this version": Gui.Tooltip("Never offer this version again (a newer one is still offered)");
						case "Restart to finish": Gui.Tooltip("Save everything, close Treadle, install the new version and start it again");
						case "Cancel": Gui.Tooltip("Stop the download");
						default:
						}
					}
					if (clicked)
						RunUpdateAction(b);
					Gui.SameLine(0, spacing);
				}
				Gui.igDummy(.(1, 1));
				// 1 px separator under the notice line, like the toolbar's
				let wp = Gui.igGetWindowPos();
				let ws = Gui.igGetWindowSize();
				Gui.ImDrawList_AddLine(Gui.igGetWindowDrawList(), .(wp.x, wp.y + ws.y - 1), .(wp.x + ws.x, wp.y + ws.y - 1), Look.WindowBorder, 1);
			}
			Gui.End();
			Gui.igPopStyleColor(1);
			Gui.igPopStyleVar(2);
		}

		/// Opens an https:// address in the browser (Report a Problem, the docs' links; the updater never calls it).
		static void OpenUrl(StringView url)
		{
			if (!url.StartsWith("https://"))
			{
				Notify.Log(.Warning, "Shell", scope $"Not opened: '{url}' is not an https:// address");
				return;
			}
#if BF_PLATFORM_WINDOWS
			bool ok = Desktop.ShellOpen("explorer.exe", url);
#else
			bool ok = Desktop.ShellOpen("xdg-open", url);
#endif
			if (!ok)
				Notify.Warn(scope $"Could not open {url}");
		}

		/// The update panels, drawn after the start page and the other windows so they open in front.
		void DrawUpdatePanels()
		{
			DrawUpdateNotes();
			DrawAbout();
		}

		/// A link shown as text with a Copy button (updates never open a browser).
		void LinkRow(StringView url, StringView id)
		{
			Gui.igAlignTextToFramePadding();
			Gui.TextColored(Look.AccentBlue, url);
			Gui.SameLine();
			if (Gui.Button(scope $"Copy##{id}"))
			{
				Gui.igSetClipboardText(scope String(url));
				SetStatus("Link copied", .Info);
			}
		}

		/// "What changed": the release notes of the offered version, in a panel.
		void DrawUpdateNotes()
		{
			if (!mShowUpdateNotes)
			{
				mUpdateNotesShown = false;
				return;
			}
			if (!mUpdateNotesShown)
				Gui.igSetNextWindowFocus();
			mUpdateNotesShown = true;
			let s = mUpdateView;
			let vp = Gui.igGetMainViewport();
			Gui.igSetNextWindowSize(.(640 * Look.Scale, 460 * Look.Scale), Cond.Appearing);
			Gui.igSetNextWindowPos(.(vp.Pos.x + vp.Size.x * 0.5f, vp.Pos.y + vp.Size.y * 0.5f), Cond.Appearing, .(0.5f, 0.5f));
			if (Gui.Begin(scope $"{Icon.ArrowDownToLine}  What changed in Treadle {s.LatestVersion}###WhatChanged", &mShowUpdateNotes, WindowFlags.NoDocking | WindowFlags.NoCollapse | WindowFlags.NoSavedSettings))
			{
				if (!s.NotesUrl.IsEmpty)
					LinkRow(s.NotesUrl, "notesurl");
				Gui.Separator();
				if (Gui.igBeginChild_Str("##notes", .(0, 0), 0, 0))
				{
					Gui.igPushTextWrapPos(0);
					Gui.Text(s.Notes.IsEmpty ? "This release has no notes." : s.Notes);
					Gui.igPopTextWrapPos();
				}
				Gui.igEndChild();
			}
			Gui.End();
		}

		/// Help > About Treadle.
		void DrawAbout()
		{
			if (!mShowAbout)
			{
				mAboutShown = false;
				return;
			}
			if (!mAboutShown)
				Gui.igSetNextWindowFocus();
			mAboutShown = true;
			let vp = Gui.igGetMainViewport();
			Gui.igSetNextWindowPos(.(vp.Pos.x + vp.Size.x * 0.5f, vp.Pos.y + vp.Size.y * 0.5f), Cond.Appearing, .(0.5f, 0.5f));
			if (Gui.Begin("About Treadle###AboutTreadle", &mShowAbout, WindowFlags.NoDocking | WindowFlags.NoCollapse | WindowFlags.NoSavedSettings | WindowFlags.AlwaysAutoResize))
			{
				Gui.Text(scope $"{Treadle.Document.TreadleInfo.Name} {Treadle.Document.TreadleInfo.FullVersion}");
				if (mUpdates != null && !mUpdates.Install.Version.IsEmpty && mUpdates.Install.Version != Treadle.Document.TreadleInfo.FullVersion)
					Gui.TextDisabled(scope $"Package version {mUpdates.Install.Version}");
				else if (mUpdates != null && mUpdates.Install.Kind == .Development)
					Gui.TextDisabled("Development build");
				Gui.TextDisabled(scope $"Host contract {Treadle.Document.TreadleInfo.HostContract}");
				Gui.Text("A visual language compiled through LLVM.");
				Gui.Text("Licensed under the Apache License 2.0 (LICENSE, NOTICE, THIRD_PARTY.md).");
				LinkRow(UpdateService.DefaultRepository, "aboutrepo");
			}
			Gui.End();
		}

		/// Editor Preferences > Updates.
		void DrawUpdatePrefs()
		{
			if (!PropertyGrid.Section("Updates", true, Icon.ArrowDownToLine))
				return;
			let s = mUpdateView;
			PropertyGrid.InfoRow("Version", (mUpdates != null && !mUpdates.Install.Version.IsEmpty) ? mUpdates.Install.Version : scope $"{Treadle.Document.TreadleInfo.FullVersion} (development build)", "The version of this copy (VERSION.txt beside the program)");
			bool changed = PropertyGrid.CheckRow("Work Offline", "##workoffline", ref UpdatePrefs.WorkOffline, "Treadle makes no network requests at all: no update checks, automatic or asked for. Everything else works the same.");
			if (PropertyGrid.CheckRow("Check for Updates", "##updcheck", ref UpdatePrefs.CheckForUpdates, "Look for a new version once a day, a few seconds after Treadle starts (and once a day while it stays open). A failed check is silent (it is logged). Off: only when you use Check Now or Help > Check for Updates."))
				changed = true;
			StringView[2] channels = .("Alpha", "Stable");
			if (PropertyGrid.ComboRow("Channel", "##updchannel", ref UpdatePrefs.Channel, channels, "Alpha: every published release, pre-releases too. Stable: only releases not marked as pre-releases."))
				changed = true;
			if (changed)
			{
				UpdatePrefs.Save();
				if (mUpdates != null)
				{
					mUpdates.Channel.Set(UpdatePrefs.ChannelName);
					ScheduleAutoCheck();
				}
			}
			if (!UpdatePrefs.Skipped.IsEmpty)
			{
				String list = scope .();
				for (let v in UpdatePrefs.Skipped)
					list.AppendF("{}{}", list.IsEmpty ? "" : ", ", v);
				PropertyGrid.InfoRow("Skipped", list, "Versions you chose to skip; they are never offered");
				PropertyGrid.WideRow();
				if (PropertyGrid.Button("Offer Skipped Versions Again##updunskip"))
				{
					ClearAndDeleteItems!(UpdatePrefs.Skipped);
					UpdatePrefs.Save();
					mUpdates?.SetSkipped(UpdatePrefs.Skipped);
				}
			}
			String state = scope .();
			String why = scope .();
			if (mUpdates != null)
				mUpdates.AutomaticBlocker(why);
			switch (s.State)
			{
			case .Idle: state.Set(why.IsEmpty ? "Not checked in this session" : why);
			case .Checking: state.Set("Checking...");
			default:
				if (!s.Message.IsEmpty)
					state.Set(s.Message);
				else if (!s.LatestVersion.IsEmpty)
					state.AppendF("Treadle {} is known from the last check.", s.LatestVersion);
				else
					state.Set("Not checked in this session");
			}
			if (UpdatePrefs.LastCheck > 0)
			{
				let ago = Math.Max(0, UpdatePrefs.NowUnix - UpdatePrefs.LastCheck);
				state.AppendF(" (last check {} ago)", (ago < 3600) ? scope $"{ago / 60} min" : (ago < 172800) ? scope $"{ago / 3600} h" : scope $"{ago / 86400} days");
			}
			PropertyGrid.InfoRow("Status", state, "The last check", 0, 0, true);
			if (UpdateIsOffered)
			{
				String offer = scope .();
				switch (s.State)
				{
				case .Available: offer.Set(s.ReadOnlyInstall ? "The install folder is read-only: download and unpack the new version by hand (the release page is below)." : "Download it, then restart to finish.");
				case .Downloading:
					if (s.Total > 0)
						offer.AppendF("Downloading: {}% ({} / {} MB)", (int)(Math.Clamp((float)s.Received / (float)s.Total, 0, 1) * 100), s.Received / (1024 * 1024), (s.Total + 1024 * 1024 - 1) / (1024 * 1024));
					else
						offer.Set("Downloading...");
				case .Verifying: offer.Set("Checking the download against the release's SHA256SUMS...");
				default: offer.Set("Restart to finish saves everything, closes Treadle, installs the new version and starts it again.");
				}
				PropertyGrid.InfoRow("Install", offer, "The newest version the last check found", 0, 0, true);
				PropertyGrid.WideRow();
				if (!mUpdateBlocked.IsEmpty && s.State == .Ready)
					Gui.TextColored(Look.Warning, mUpdateBlocked);
				switch (s.State)
				{
				case .Available:
					if (!s.ReadOnlyInstall)
					{
						if (PropertyGrid.Button("Update now##updprefsnow"))
							RunUpdateAction("Update now");
						Gui.SameLine();
					}
					if (PropertyGrid.Button("What changed##updprefsnotes"))
						RunUpdateAction("What changed");
					Gui.SameLine();
					if (PropertyGrid.Button("Skip this version##updprefsskip"))
						RunUpdateAction("Skip this version");
				case .Downloading:
					if (PropertyGrid.Button("Cancel##updprefscancel"))
						RunUpdateAction("Cancel");
				case .Ready:
					if (PropertyGrid.Button("Restart to finish##updprefsrestart", 0, false, true, false, "Save everything, close Treadle, install the new version and start it again"))
						RunUpdateAction("Restart to finish");
					Gui.SameLine();
					if (PropertyGrid.Button("What changed##updprefsnotes"))
						RunUpdateAction("What changed");
				default:
				}
			}
			PropertyGrid.InfoRow("Releases", scope $"{UpdateService.DefaultRepository}/releases", "Where new versions are published (GitHub Releases; nothing else is contacted)");
			PropertyGrid.WideRow();
			bool busy = mUpdates == null || mUpdates.Busy;
			if (PropertyGrid.Button("Check Now##updnow", 0, false, false, busy || UpdatePrefs.WorkOffline))
				CheckForUpdatesNow();
			Gui.SameLine();
			if (PropertyGrid.Button("Copy Release Link##updpage"))
			{
				Gui.igSetClipboardText(scope String(scope $"{UpdateService.DefaultRepository}/releases"));
				SetStatus("Link copied", .Info);
			}
		}

#if TREADLE_SELFTEST
		/// Self test steps for captures: `update:<state>` puts the notice line in a state without the network.
		bool SelfTestUpdateCapture(StringView test)
		{
			if (test.StartsWith("updatecap:"))
			{
				// Pixel passes: asks the host for a capture of this frame (TREADLE_CAPTURE_DIR/<name>.bmp).
				String dir = scope .();
				if (Environment.GetEnvironmentVariable("TREADLE_CAPTURE_DIR", dir) case .Ok && !dir.IsEmpty)
					File.WriteAllText(scope $"{dir}{Path.DirectorySeparatorChar}capture.request", test.Substring(10)).IgnoreError(); // no capture: the pass notices
				mSelfTestWait = 10;
				return true;
			}
			if (!test.StartsWith("update:") || mUpdates == null)
				return false;
			mSelfTestWait = 10;
			let state = test.Substring(7);
			mUpdateHidden = false;
			mUpdateBlocked.Clear();
			switch (state)
			{
			case "available": mUpdates.SetTestState(.Available, "0.2.0-alpha", "Treadle 0.2.0-alpha is available (this is 0.1.9-alpha).", 0, 0);
			case "downloading": mUpdates.SetTestState(.Downloading, "0.2.0-alpha", "", 4 * 1024 * 1024 + 300000, 11 * 1024 * 1024);
			case "verifying": mUpdates.SetTestState(.Verifying, "0.2.0-alpha", "Checking the download...", 11 * 1024 * 1024, 11 * 1024 * 1024);
			case "ready": mUpdates.SetTestState(.Ready, "0.2.0-alpha", "Treadle 0.2.0-alpha is downloaded and verified. Restart to finish.", 0, 0);
			case "notes":
				mUpdates.SetTestState(.Available, "0.2.0-alpha", "", 0, 0);
				mShowUpdateNotes = true;
			case "about": mShowAbout = true;
			case "error": mUpdates.SetTestState(.Error, "0.2.0-alpha", "The update was refused: the download's SHA-256 does not match the release's SHA256SUMS (the file was altered or damaged); it was deleted.", 0, 0);
			case "uptodate": mUpdates.SetTestState(.UpToDate, "", "Treadle 0.1.9-alpha is up to date.", 0, 0);
			case "none":
				mUpdates.SetTestState(.Idle, "", "", 0, 0);
				mShowUpdateNotes = false;
				mShowAbout = false;
			default: SelfTestCheck(false, scope $"unknown update state {state}");
			}
			return true;
		}
#endif
	}
}
