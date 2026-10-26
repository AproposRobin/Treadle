// Copyright 2026 AproposRobin. Licensed under the Apache License, Version 2.0 (LICENSE at the repository root).

using System;
using System.Collections;
using System.IO;
using ImGui;
using Treadle.Document;

namespace Treadle.Editor
{
	/// Where Help > Report a Problem points. Both are empty in the code until the public places exist; an empty one
	/// hides its button (FORK-NOTES.md > Reports). Nothing in the report flow uses the network: the editor saves a
	/// bundle to disk and opens a browser page only when the user clicks a button for it.
	static class ReportConfig
	{
		/// The issues page of the public repository, e.g. "https://github.com/<org>/<repo>/issues" (no trailing /).
		/// "Report on GitHub" opens <IssuesUrl>/new with the title and body filled in.
		public const String IssuesUrl = "https://github.com/AproposRobin/Treadle/issues";
		/// The support chat invite (opened by "Open support chat").
		public const String SupportChatUrl = "";
	}

	/// A zip writer for the report bundle: stored entries (no compression), UTF-8 names, CRC-32 checked by readers.
	class ReportZip
	{
		struct CentralEntry
		{
			public uint32 Crc;
			public uint32 Size;
			public uint32 Offset;
			public int NameStart;
			public int NameLength;
		}

		public List<uint8> Bytes = new .() ~ delete _;
		List<CentralEntry> mEntries = new .() ~ delete _;
		String mNames = new .() ~ delete _;
		uint16 mTime;
		uint16 mDate;

		static uint32[256] sCrcTable;
		static bool sCrcReady;

		public this()
		{
			let now = DateTime.Now;
			mTime = (uint16)((now.Hour << 11) | (now.Minute << 5) | (now.Second / 2));
			mDate = (uint16)(((Math.Max(now.Year, 1980) - 1980) << 9) | (now.Month << 5) | now.Day);
		}

		public static uint32 Crc32(Span<uint8> data)
		{
			if (!sCrcReady)
			{
				for (uint32 i < 256)
				{
					uint32 c = i;
					for (int k < 8)
						c = ((c & 1) != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
					sCrcTable[i] = c;
				}
				sCrcReady = true;
			}
			uint32 crc = 0xFFFFFFFF;
			for (let b in data)
				crc = sCrcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
			return crc ^ 0xFFFFFFFF;
		}

		void U16(int v) { Bytes.Add((uint8)(v & 0xFF)); Bytes.Add((uint8)((v >> 8) & 0xFF)); }
		void U32(uint32 v) { for (int i < 4) Bytes.Add((uint8)((v >> (i * 8)) & 0xFF)); }
		void Name(StringView name) { for (let c in name.RawChars) Bytes.Add((uint8)c); }

		public void Add(StringView name, Span<uint8> data)
		{
			CentralEntry e = .();
			e.Crc = Crc32(data);
			e.Size = (uint32)data.Length;
			e.Offset = (uint32)Bytes.Count;
			e.NameStart = mNames.Length;
			e.NameLength = name.Length;
			mNames.Append(name);
			mEntries.Add(e);
			U32(0x04034b50);
			U16(20); U16(0x0800); U16(0); U16(mTime); U16(mDate);
			U32(e.Crc); U32(e.Size); U32(e.Size);
			U16(name.Length); U16(0);
			Name(name);
			Bytes.AddRange(data);
		}

		public void AddText(StringView name, StringView text) => Add(name, .((uint8*)text.Ptr, text.Length));

		public void Finish()
		{
			let cdStart = (uint32)Bytes.Count;
			for (let e in mEntries)
			{
				let name = StringView(mNames, e.NameStart, e.NameLength);
				U32(0x02014b50);
				U16(20); U16(20); U16(0x0800); U16(0); U16(mTime); U16(mDate);
				U32(e.Crc); U32(e.Size); U32(e.Size);
				U16(name.Length); U16(0); U16(0); U16(0); U16(0); U32(0);
				U32(e.Offset);
				Name(name);
			}
			let cdSize = (uint32)Bytes.Count - cdStart;
			U32(0x06054b50);
			U16(0); U16(0); U16(mEntries.Count); U16(mEntries.Count);
			U32((uint32)cdSize); U32(cdStart); U16(0);
		}

		/// Reads the names (and checks the CRC of each entry) of a stored zip this class wrote. False when the data is
		/// not a well-formed zip or a CRC differs. The self test reads the saved bundle back with it.
		public static bool List(Span<uint8> data, List<String> outNames, List<String> outTexts = null)
		{
			int RU16(int at) => data[at] | ((int)data[at + 1] << 8);
			uint32 RU32(int at) => (uint32)data[at] | ((uint32)data[at + 1] << 8) | ((uint32)data[at + 2] << 16) | ((uint32)data[at + 3] << 24);
			if (data.Length < 22)
				return false;
			int eocd = data.Length - 22;
			if (RU32(eocd) != 0x06054b50)
				return false;
			int count = RU16(eocd + 10);
			int at = (int)RU32(eocd + 16);
			for (int i < count)
			{
				if (at + 46 > data.Length || RU32(at) != 0x02014b50)
					return false;
				let crc = RU32(at + 16);
				let size = (int)RU32(at + 20);
				let nameLen = RU16(at + 28);
				let extra = RU16(at + 30);
				let comment = RU16(at + 32);
				let local = (int)RU32(at + 42);
				let name = new String(StringView((char8*)&data[at + 46], nameLen));
				outNames.Add(name);
				if (local + 30 > data.Length || RU32(local) != 0x04034b50)
					return false;
				let body = local + 30 + RU16(local + 26) + RU16(local + 28);
				if (body + size > data.Length || Crc32(data.Slice(body, size)) != crc)
					return false;
				if (outTexts != null)
					outTexts.Add(new String(StringView((char8*)&data[body], size)));
				at += 46 + nameLen + extra + comment;
			}
			return true;
		}
	}

	/// What Help > Report a Problem saves: the plan (each file's name and size, shown in the dialog before anything is
	/// written) and the zip. The bundle holds `report.txt` (the version line, OS, report id, time, the description and
	/// steps the user typed, the options), and on opt-in `output-log.txt` (the last 200 Output Log lines),
	/// `crash/<name>.log` (the newest crash report) and `project/...` (the open project's files, without any `build`
	/// or `.git` folder). Capped at 8 MB.
	class ReportBundle
	{
		public const int MaxBytes = 8 * 1024 * 1024;
		public const int LogLines = 200;

		public class Entry
		{
			public String Name = new .() ~ delete _;
			/// The file it is read from at save time; empty for text made by the editor (Text).
			public String Source = new .() ~ delete _;
			public String Text ~ delete _;
			public int64 Size;
		}

		public String Id = new .() ~ delete _;
		public String VersionLine = new .() ~ delete _;
		public String Os = new .() ~ delete _;
		public String Description = new .() ~ delete _;
		public String Steps = new .() ~ delete _;
		public bool IncludeLog = true;
		public bool IncludeCrash = true;
		public bool IncludeProject;
		/// The project folder (empty: no project open, the project box does nothing).
		public String ProjectRoot = new .() ~ delete _;
		/// The folder crash reports are written to (the self test points it at its own folder).
		public String CrashDir = new .() ~ delete _;
		/// Where Save writes (default <app data>/reports).
		public String SaveDir = new .() ~ delete _;

		public List<Entry> Entries = new .() ~ DeleteContainerAndItems!(_);
		/// The planned zip's size (entries plus headers).
		public int64 Total;
		/// The project scan stopped at the cap (the plan is already too large).
		public bool ProjectCut;
		/// The newest crash report's path ("" when none).
		public String CrashPath = new .() ~ delete _;
		/// The last saved zip ("" until Save).
		public String SavedPath = new .() ~ delete _;

		public this()
		{
			let ts = (int64)Platform.BfpSystem_GetTimeStamp();
			let now = DateTime.Now;
			Random rnd = scope .((int32)(ts ^ (ts >> 32)));
			Id.AppendF("{:D4}{:D2}{:D2}-{:D2}{:D2}{:D2}-{:X4}", now.Year, now.Month, now.Day, now.Hour, now.Minute, now.Second, rnd.Next(0x10000));
			TreadleInfo.VersionLine(VersionLine);
			let os = Environment.OSVersion;
#if BF_PLATFORM_LINUX
			Os.Append(os.PrettyName.IsEmpty ? os.Name : os.PrettyName);
#else
			// Windows 11 reports itself as 10; its builds start at 22000.
			Os.Append((os.Name == "Windows 10" && os.Version.Build >= 22000) ? "Windows 11" : os.Name);
#endif
			Os.AppendF(" ({}.{}.{})", os.Version.Major, os.Version.Minor, os.Version.Build);
#if BF_PLATFORM_WINDOWS
			CrashDir.Set(SessionLog.LogDir);
#else
			CrashDir.Set(CrashHandler.CrashDir);
#endif
			AppPaths.Sub("reports", SaveDir);
		}

		/// report.txt as it is saved now.
		public void ReportText(String outText)
		{
			outText.AppendF("{}\nOS: {}\nReport id: {}\nTime: {}\n", VersionLine, Os, Id, DateTime.Now.ToString(.. scope String()));
			outText.AppendF("Included: output log {}, crash report {}, project files {}\n", IncludeLog ? "yes" : "no", (IncludeCrash && !CrashPath.IsEmpty) ? "yes" : "no", (IncludeProject && !ProjectRoot.IsEmpty) ? "yes" : "no");
			outText.AppendF("\nWhat went wrong:\n{}\n\nSteps:\n{}\n", Description.IsEmpty ? "(not given)" : Description, Steps.IsEmpty ? "(not given)" : Steps);
		}

		/// The last `count` Output Log lines.
		public static void LogTail(String outText, int count)
		{
			Notify.WithEntries(scope [&] (entries) =>
			{
				for (int i = Math.Max(0, entries.Count - count); i < entries.Count; i++)
				{
					let e = entries[i];
					outText.AppendF("[{}] {} {}: {}\n", e.Stamp, e.Level, e.Category, e.Text);
				}
			});
		}

		public static void FindNewestCrash(StringView dir, String outPath)
		{
			outPath.Clear();
			if (dir.IsEmpty || !Directory.Exists(dir))
				return;
			String best = scope .();
			for (let entry in Directory.EnumerateFiles(dir))
			{
				String name = scope .();
				entry.GetFileName(name);
				// Names sort by time (treadle-crash-YYYY-MM-DD-HHMMSS[...].log).
				if (name.StartsWith("treadle-crash-") && name.EndsWith(".log") && String.Compare(name, best, false) > 0)
				{
					best.Set(name);
					outPath.Clear();
					entry.GetFilePath(outPath);
				}
			}
		}

		static bool SkippedFolder(StringView name) => name.Equals("build", true) || name == ".git";

		void ScanProject(StringView dir, StringView rel)
		{
			for (let e in Directory.EnumerateFiles(dir))
			{
				if (Total > MaxBytes)
				{
					ProjectCut = true;
					return;
				}
				String name = scope .();
				e.GetFileName(name);
				let entry = new Entry();
				entry.Name.AppendF("project/{}{}", rel, name);
				e.GetFilePath(entry.Source);
#if BF_PLATFORM_WINDOWS
				entry.Size = e.GetFileSize();
#else
				// the Linux corlib's find entry reports no size: read it from the file
				{
					FileStream fs = scope .();
					if (fs.Open(entry.Source, .Read, .ReadWrite) case .Ok)
						entry.Size = fs.Length;
				}
#endif
				Add(entry);
			}
			for (let d in Directory.EnumerateDirectories(dir))
			{
				String name = scope .();
				d.GetFileName(name);
				if (SkippedFolder(name))
					continue;
				ScanProject(d.GetFilePath(.. scope String()), scope $"{rel}{name}/");
				if (ProjectCut)
					return;
			}
		}

		void Add(Entry e)
		{
			Entries.Add(e);
			Total += e.Size + 30 + 46 + 2 * e.Name.Length;
		}

		/// Rebuilds the list of files (call when a box changes; the texts are read again at save time).
		public void Plan()
		{
			ClearAndDeleteItems!(Entries);
			Total = 22;
			ProjectCut = false;
			let report = new Entry();
			report.Name.Set("report.txt");
			report.Text = new String();
			ReportText(report.Text);
			report.Size = report.Text.Length;
			Add(report);
			if (IncludeLog)
			{
				let log = new Entry();
				log.Name.Set("output-log.txt");
				log.Text = new String();
				LogTail(log.Text, LogLines);
				log.Size = log.Text.Length;
				Add(log);
			}
			FindNewestCrash(CrashDir, CrashPath);
			if (IncludeCrash && !CrashPath.IsEmpty)
			{
				let crash = new Entry();
				crash.Name.AppendF("crash/{}", Path.GetFileName(CrashPath, .. scope String()));
				crash.Source.Set(CrashPath);
				{
					FileStream fs = scope .();
					if (fs.Open(CrashPath, .Read, .ReadWrite) case .Ok)
						crash.Size = fs.Length;
				}
				Add(crash);
			}
			if (IncludeProject && !ProjectRoot.IsEmpty && Directory.Exists(ProjectRoot))
				ScanProject(ProjectRoot, "");
		}

		/// Refreshes report.txt's size after the texts changed (cheap: no file scan).
		public void UpdateReportSize()
		{
			if (Entries.IsEmpty || Entries[0].Name != "report.txt")
				return;
			let e = Entries[0];
			Total -= e.Size;
			e.Text.Clear();
			ReportText(e.Text);
			e.Size = e.Text.Length;
			Total += e.Size;
		}

		public bool OverCap => Total > MaxBytes || ProjectCut;

		public static void FormatSize(int64 n, String outText)
		{
			if (n < 1024)
				outText.AppendF("{} B", n);
			else if (n < 1024 * 1024)
				outText.AppendF("{:0.0} KB", n / 1024.0);
			else
				outText.AppendF("{:0.0} MB", n / (1024.0 * 1024.0));
		}

		/// Writes <SaveDir>/report-<id>.zip from a fresh plan (the log tail and report.txt as they are now).
		public bool Save(String outWhy)
		{
			Plan();
			if (OverCap)
			{
				outWhy.AppendF("The bundle would be over {} MB{}. Untick \"include this project's files\", or attach the project separately.", MaxBytes / (1024 * 1024), ProjectCut ? " (the project alone is larger)" : scope $" ({FormatSize(Total, .. scope String())})");
				return false;
			}
			ReportZip zip = scope .();
			List<uint8> data = scope .();
			for (let e in Entries)
			{
				if (e.Text != null)
				{
					zip.AddText(e.Name, e.Text);
					continue;
				}
				data.Clear();
				if (File.ReadAll(e.Source, data) case .Err)
				{
					outWhy.AppendF("Could not read {}", e.Source);
					return false;
				}
				zip.Add(e.Name, data);
			}
			zip.Finish();
			if (zip.Bytes.Count > MaxBytes)
			{
				outWhy.AppendF("The bundle would be over {} MB.", MaxBytes / (1024 * 1024));
				return false;
			}
			Directory.CreateDirectory(SaveDir).IgnoreError(); // an existing folder is fine; the write below reports a real failure
			String path = scope $"{SaveDir}{Path.DirectorySeparatorChar}report-{Id}.zip";
			if (File.WriteAll(path, zip.Bytes) case .Err)
			{
				outWhy.AppendF("Could not write {}", path);
				return false;
			}
			SavedPath.Set(path);
			return true;
		}

		/// The plain text "Copy summary" puts on the clipboard.
		public void Summary(String outText)
		{
			outText.AppendF("{}\nOS: {}\nReport id: {}\n\nWhat went wrong:\n{}\n\nSteps:\n{}\n\nBundle: {}\n", VersionLine, Os, Id,
				Description.IsEmpty ? "(not given)" : Description, Steps.IsEmpty ? "(not given)" : Steps,
				SavedPath.IsEmpty ? "(not saved)" : SavedPath);
		}

		static void UrlEncode(StringView text, String outText)
		{
			for (let c in text.RawChars)
			{
				if ((c.IsLetterOrDigit && (uint8)c < 0x80) || c == '-' || c == '_' || c == '.' || c == '~')
					outText.Append(c);
				else
					outText.AppendF("%{:X2}", (uint8)c);
			}
		}

		/// The issue body (markdown): the summary, the bundle line, the last 30 log lines and the crash report's head
		/// in collapsed blocks. `logLines` / `crashLines` shrink when the URL is too long.
		public void IssueBody(String outText, int logLines, int crashLines)
		{
			outText.AppendF("**Version:** {}\n**OS:** {}\n**Report id:** {}\n\n### What went wrong\n{}\n\n### Steps\n{}\n\n",
				VersionLine, Os, Id, Description.IsEmpty ? "(not given)" : Description, Steps.IsEmpty ? "(not given)" : Steps);
			if (!SavedPath.IsEmpty)
				outText.AppendF("**Bundle:** attach the zip saved at `{}`\n\n", SavedPath);
			if (logLines > 0)
			{
				String log = scope .();
				LogTail(log, logLines);
				outText.AppendF("<details><summary>Output Log (last {} lines)</summary>\n\n```\n{}```\n</details>\n\n", logLines, log);
			}
			else
				outText.Append("(Output Log left out to keep the link short: it is in the bundle.)\n\n");
			FindNewestCrash(CrashDir, CrashPath);
			if (IncludeCrash && !CrashPath.IsEmpty && crashLines > 0)
			{
				String text = scope .();
				File.ReadAllText(CrashPath, text).IgnoreError(); // unreadable: the block is left empty
				String head = scope .();
				int n = 0;
				for (let line in text.Split('\n'))
				{
					if (n++ >= crashLines)
						break;
					head.Append(line);
					head.Append('\n');
				}
				outText.AppendF("<details><summary>Crash report (first {} lines)</summary>\n\n```\n{}```\n</details>\n", crashLines, head);
			}
		}

		public const int MaxUrl = 6000;

		/// <IssuesUrl>/new?title=...&body=..., under MaxUrl characters (the log block, then the crash block shrink).
		public void IssueUrl(StringView issuesUrl, String outUrl)
		{
			String title = scope .(Description);
			if (title.Length > 80)
			{
				title.RemoveToEnd(77);
				title.Append("...");
			}
			if (title.IsEmpty)
				title.Set("Problem report");
			int logLines = 30;
			int crashLines = 15;
			while (true)
			{
				outUrl.Clear();
				outUrl.AppendF("{}/new?title=", issuesUrl);
				UrlEncode(title, outUrl);
				outUrl.Append("&body=");
				String body = scope .();
				IssueBody(body, logLines, crashLines);
				UrlEncode(body, outUrl);
				if (outUrl.Length <= MaxUrl)
					return;
				if (logLines > 0)
					logLines = (logLines > 5) ? logLines - 5 : 0;
				else if (crashLines > 0)
					crashLines = (crashLines > 5) ? crashLines - 5 : 0;
				else
				{
					// The typed texts alone are too long: cut the URL at a whole escape.
					int cut = MaxUrl;
					if (outUrl[cut - 1] == '%')
						cut -= 1;
					else if (outUrl[cut - 2] == '%')
						cut -= 2;
					outUrl.RemoveToEnd(cut);
					return;
				}
			}
		}
	}

	/// Help > Report a Problem.
	extension EditorApp
	{
		bool mReportOpenRequest;
		bool mReportCloseRequest;
		ReportBundle mReport ~ delete _;
		TextBuffer mReportDesc = new .(512) ~ delete _;
		TextBuffer mReportSteps = new .(4096) ~ delete _;
		String mReportMessage = new .() ~ delete _;
		bool mReportMessageError;
		/// The buttons drawn on the last frame (self test).
		List<String> mReportButtons = new .() ~ DeleteContainerAndItems!(_);
		/// Self test: stands in for the constants (null: use ReportConfig).
		String mReportIssuesOverride ~ delete _;
		String mReportChatOverride ~ delete _;

		StringView ReportIssuesUrl => (mReportIssuesOverride != null) ? (StringView)mReportIssuesOverride : ReportConfig.IssuesUrl;
		StringView ReportChatUrl => (mReportChatOverride != null) ? (StringView)mReportChatOverride : ReportConfig.SupportChatUrl;

		public void OpenReportProblem()
		{
			delete mReport;
			mReport = new .();
			mReport.ProjectRoot.Set(mProjectRoot);
			mReport.Plan();
			mReportDesc.Set("");
			mReportSteps.Set("");
			mReportMessage.Clear();
			mReportOpenRequest = true;
		}

		bool ReportButton(StringView label, StringView tooltip)
		{
			mReportButtons.Add(new String(label));
			bool clicked = Gui.Button(label);
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip(tooltip);
			Gui.SameLine();
			return clicked;
		}

		bool ReportSave()
		{
			mReportMessage.Clear();
			if (mReport.Save(mReportMessage))
			{
				mReportMessageError = false;
				return true;
			}
			mReportMessageError = true;
			return false;
		}

		void DrawReportProblem()
		{
			if (mReportOpenRequest)
			{
				mReportOpenRequest = false;
				Gui.OpenPopup("Report a Problem");
				Gui.igSetNextWindowSize(.(640 * Look.Scale, 0), Cond.Always);
			}
			if (mReport == null || !Gui.igBeginPopupModal("Report a Problem", null, WindowFlags.AlwaysAutoResize))
				return;
			ClearAndDeleteItems!(mReportButtons);
			let r = mReport;
			if (Gui.IsKeyPressed(Key.Escape, false))
				Gui.igCloseCurrentPopup();
			Gui.TextWrappedDim("Nothing is sent from here. Save the bundle, then attach it to a GitHub issue or in the support chat. Below is every file the bundle will hold.");
			Gui.igSpacing();
			Gui.Text("What went wrong");
			Gui.igSetNextItemWidth(-1);
			bool edited = Gui.igInputTextWithHint("##reportdesc", "A short description", mReportDesc.Ptr, (.)mReportDesc.Capacity, 0, null, null);
			Gui.Text("Steps to make it happen");
			edited |= Gui.igInputTextMultiline("##reportsteps", mReportSteps.Ptr, (.)mReportSteps.Capacity, .(-1, 90 * Look.Scale), 0, null, null);
			if (edited)
			{
				r.Description.Set(mReportDesc.View);
				r.Steps.Set(mReportSteps.View);
				r.UpdateReportSize();
			}
			bool replan = false;
			replan |= Gui.Checkbox(scope $"Include Output Log (last {ReportBundle.LogLines} lines)", &r.IncludeLog);
			replan |= Gui.Checkbox(r.CrashPath.IsEmpty ? "Include last crash report (none found)" : "Include last crash report", &r.IncludeCrash);
			if (r.ProjectRoot.IsEmpty)
			{
				Gui.igBeginDisabled(true);
				Gui.Checkbox("Include this project's files (no project open)", &r.IncludeProject);
				Gui.igEndDisabled();
			}
			else
				replan |= Gui.Checkbox("Include this project's files (zipped, excluding build/)", &r.IncludeProject);
			if (replan)
				r.Plan();

			Gui.SeparatorText("In the bundle");
			Gui.TextDisabled(r.VersionLine);
			Gui.igBeginChild_Str("##reportfiles", .(-1, 130 * Look.Scale), ChildFlags.Borders, 0);
			for (let e in r.Entries)
			{
				Gui.Text(e.Name);
				Gui.SameLine(Gui.igGetWindowWidth() - 90 * Look.Scale);
				Gui.TextDisabled(ReportBundle.FormatSize(e.Size, .. scope String()));
			}
			Gui.igEndChild();
			String total = scope $"{r.Entries.Count} files, {ReportBundle.FormatSize(r.Total, .. scope String())} of {ReportBundle.MaxBytes / (1024 * 1024)} MB";
			if (r.OverCap)
				Gui.TextColored(Theme.NodeError, scope $"{total}: too large to save. Untick the project files.");
			else
				Gui.TextDisabled(total);

			if (!r.SavedPath.IsEmpty)
			{
				Gui.igSpacing();
				Gui.TextColored(Theme.Good, "Saved:");
				Gui.SameLine();
				Gui.Text(r.SavedPath);
				Gui.SameLine();
				if (Gui.SmallButton(scope $"{Icon.Copy} Copy##reportpath"))
				{
					Gui.igSetClipboardText(r.SavedPath);
					Notify.Info("Bundle path copied to the clipboard");
				}
			}
			if (!mReportMessage.IsEmpty)
				Gui.TextColored(mReportMessageError ? Theme.NodeError : Theme.Good, mReportMessage);

			Gui.igSpacing();
			if (!ReportIssuesUrl.IsEmpty && ReportButton("Report on GitHub", "Save the bundle, then open a new GitHub issue filled in with this report (attach the zip there)"))
			{
				if (ReportSave())
				{
					String url = scope .();
					r.IssueUrl(ReportIssuesUrl, url);
					OpenUrl(url);
					mReportMessage.Set("The issue page is open in your browser: attach the saved zip there.");
				}
			}
			if (!ReportChatUrl.IsEmpty && ReportButton("Open support chat", "Open the support chat in your browser (paste the summary, attach the zip)"))
				OpenUrl(ReportChatUrl);
			if (ReportButton("Save bundle", "Write the zip shown above to your reports folder"))
			{
				if (ReportSave())
					mReportMessage.Set("Bundle saved.");
			}
			if (ReportButton("Copy summary", "Put a short text (version, OS, description, steps, the bundle path) on the clipboard"))
			{
				String text = scope .();
				r.Summary(text);
				Gui.igSetClipboardText(text);
				mReportMessage.Set("Summary copied to the clipboard.");
				mReportMessageError = false;
			}
			if (ReportButton("Cancel", "Close without saving anything"))
				Gui.igCloseCurrentPopup();
			Gui.igDummy(.(0, 0));
			if (mReportCloseRequest)
			{
				mReportCloseRequest = false;
				Gui.igCloseCurrentPopup();
			}
			Gui.EndPopup();
		}

		// --- self test (the `editor` case's report step) ---

#if TREADLE_SELFTEST
		int mReportTestPhase;
		String mReportTestDir = new .() ~ delete _;

		/// The `editor` case's report step: one phase per call; true when done.
		bool SelfTestReport()
		{
			switch (mReportTestPhase++)
			{
			case 0:
				// A sample project with a build/ folder, a crash report of its own, all boxes on.
				String temp = scope .();
				if (!SelfTestTemp.Get(temp))
					temp.Set(".");
				mReportTestDir.Set(scope $"{temp}/treadle-report-{(int)Platform.BfpSystem_GetTimeStamp() & 0xFFFFFF}");
				let proj = scope $"{mReportTestDir}/project";
				for (let d in StringView[?]("project/Source", "project/build/Debug", "project/Source/build", "crash", "saved"))
					Directory.CreateDirectory(scope $"{mReportTestDir}/{d}").IgnoreError();
				String samples = scope .();
				if (FindSamples(samples))
					for (let name in StringView[?]("Player.treadle", "Pair.treadle", "Program.treadle"))
						File.Copy(scope $"{samples}/{name}", scope $"{proj}/Source/{name}").IgnoreError();
				File.WriteAllText(scope $"{proj}/Report Test.tproj", "project \"Report Test\"\n").IgnoreError();
				File.WriteAllText(scope $"{proj}/build/Debug/app.obj", "object").IgnoreError();
				File.WriteAllText(scope $"{proj}/Source/build/stale.txt", "stale").IgnoreError();
				File.WriteAllText(scope $"{mReportTestDir}/crash/treadle-crash-2026-01-01-000000.log", "old").IgnoreError();
				File.WriteAllText(scope $"{mReportTestDir}/crash/treadle-crash-2026-10-25-101010.log", "Treadle crash report\r\nexception: test\r\n").IgnoreError();
				Notify.Log(.Info, "SelfTest", "[SELFTEST] report: log marker 7f3a");

				ReportBundle b = scope .();
				b.ProjectRoot.Set(proj);
				b.CrashDir.Set(scope $"{mReportTestDir}/crash");
				b.SaveDir.Set(scope $"{mReportTestDir}/saved");
				b.Description.Set("The canvas froze");
				b.Steps.Set("1. Open Player\n2. Drag a node");
				b.IncludeLog = b.IncludeCrash = b.IncludeProject = true;
				b.Plan();
				bool anyBuild = false;
				for (let e in b.Entries)
					if (e.Name.Contains("build/"))
						anyBuild = true;
				SelfTestCheck(!anyBuild && b.Entries.Count >= 6, scope $"editor: report: the plan lists {b.Entries.Count} files, none under build/");
				String why = scope .();
				bool saved = b.Save(why);
				SelfTestCheck(saved && File.Exists(b.SavedPath) && b.SavedPath.EndsWith(scope $"report-{b.Id}.zip"), scope $"editor: report: Save writes report-<id>.zip to the chosen folder {why}");
				List<uint8> data = scope .();
				File.ReadAll(b.SavedPath, data).IgnoreError(); // missing: the checks below fail
				List<String> names = scope .();
				List<String> texts = scope .();
				defer { ClearAndDeleteItems!(names); ClearAndDeleteItems!(texts); }
				bool wellFormed = ReportZip.List(data, names, texts);
				SelfTestCheck(wellFormed && data.Count <= ReportBundle.MaxBytes, scope $"editor: report: the zip reads back with matching CRCs ({names.Count} entries, {data.Count} bytes)");
				int Find(StringView n) { for (int i < names.Count) if (names[i] == n) return i; return -1; }
				let ri = Find("report.txt");
				SelfTestCheck(ri >= 0 && texts[ri].StartsWith(b.VersionLine) && !texts[ri].Contains("boxed") && texts[ri].Contains("The canvas froze") && texts[ri].Contains(b.Id), "editor: report: report.txt starts with the version line and holds the description and id");
				let li = Find("output-log.txt");
				int lines = 0;
				if (li >= 0)
					for (let c in texts[li].RawChars)
						if (c == '\n')
							lines++;
				SelfTestCheck(li >= 0 && texts[li].Contains("log marker 7f3a") && lines <= ReportBundle.LogLines, scope $"editor: report: output-log.txt has the log tail ({lines} lines)");
				let ci = Find("crash/treadle-crash-2026-10-25-101010.log");
				SelfTestCheck(ci >= 0 && Find("crash/treadle-crash-2026-01-01-000000.log") < 0, "editor: report: the newest crash report only");
				bool noBuild = true;
				for (let n in names)
					if (n.Contains("build/"))
						noBuild = false;
				SelfTestCheck(noBuild && Find("project/Report Test.tproj") >= 0 && Find("project/Source/Player.treadle") >= 0, "editor: report: project files in, no build/ files");
				// Summary and issue link.
				String summary = scope .();
				b.Summary(summary);
				SelfTestCheck(summary.StartsWith(b.VersionLine) && summary.Contains(b.SavedPath) && summary.Contains("Drag a node"), "editor: report: the summary has the version line, the steps and the bundle path");
				String url = scope .();
				b.IssueUrl("https://github.com/example/example/issues", url);
				SelfTestCheck(url.StartsWith("https://github.com/example/example/issues/new?title=The%20canvas%20froze&body=") && url.Length <= ReportBundle.MaxUrl && url.Contains("%3Cdetails%3E"), scope $"editor: report: the issue link is pre-filled and short enough ({url.Length} chars)");
				b.Description.Clear();
				for (int i < 600)
					b.Description.Append("long text ");
				String longUrl = scope .();
				b.IssueUrl("https://github.com/example/example/issues", longUrl);
				SelfTestCheck(longUrl.Length <= ReportBundle.MaxUrl, scope $"editor: report: a very long description still gives a link under {ReportBundle.MaxUrl} chars ({longUrl.Length})");
				// The cap: a 9 MB file makes Save refuse.
				{
					FileStream fs = scope .();
					if (fs.Create(scope $"{proj}/big.bin") case .Ok)
					{
						uint8[] chunk = new .[1024 * 1024];
						defer delete chunk;
						for (int i < 9)
							fs.TryWrite(chunk).IgnoreError();
					}
				}
				ReportBundle big = scope .();
				big.ProjectRoot.Set(proj);
				big.SaveDir.Set(scope $"{mReportTestDir}/saved");
				big.IncludeProject = true;
				String bigWhy = scope .();
				bool bigSaved = big.Save(bigWhy);
				SelfTestCheck(!bigSaved && big.OverCap && bigWhy.Contains("8 MB") && !File.Exists(scope $"{mReportTestDir}/saved/report-{big.Id}.zip"), scope $"editor: report: over 8 MB is refused ({bigWhy})");
				// The dialog with the shipped constants (IssuesUrl set, SupportChatUrl empty).
				OpenReportProblem();
				mSelfTestWait = 3;
				return false;
			case 1:
				SelfTestCheck(ReportConfig.IssuesUrl == "https://github.com/AproposRobin/Treadle/issues" && ReportConfig.SupportChatUrl.IsEmpty, "editor: report: IssuesUrl is the public repository's issues page, SupportChatUrl ships empty");
				SelfTestCheck(ReportButtonsAre("Report on GitHub", "Save bundle", "Copy summary", "Cancel"), scope $"editor: report: the dialog shows Report on GitHub first, no support chat button ({ReportButtonList(.. scope String())})");
				mReportIssuesOverride = new .("");
				mReportChatOverride = new .("");
				mSelfTestWait = 2;
				return false;
			case 2:
				SelfTestCheck(ReportButtonsAre("Save bundle", "Copy summary", "Cancel"), scope $"editor: report: with both constants empty, the GitHub and chat buttons are hidden ({ReportButtonList(.. scope String())})");
				DeleteAndNullify!(mReportIssuesOverride);
				mReportChatOverride.Set("https://example.invalid/chat");
				mSelfTestWait = 2;
				return false;
			case 3:
				SelfTestCheck(ReportButtonsAre("Report on GitHub", "Open support chat", "Save bundle", "Copy summary", "Cancel"), scope $"editor: report: with a chat URL, Open support chat comes second ({ReportButtonList(.. scope String())})");
				DeleteAndNullify!(mReportChatOverride);
				mReportCloseRequest = true;
				// The test folder goes.
				DeleteTree(mReportTestDir);
				return true;
			}
			return true;
		}

		void ReportButtonList(String outText)
		{
			for (let l in mReportButtons)
				outText.AppendF("{}{}", outText.IsEmpty ? "" : ", ", l);
		}

		bool ReportButtonsAre(params StringView[] labels)
		{
			if (labels.Count != mReportButtons.Count)
				return false;
			for (int i < labels.Count)
				if (labels[i] != mReportButtons[i])
					return false;
			return true;
		}
#endif
	}
}
