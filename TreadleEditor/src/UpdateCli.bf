using System;
using System.Collections;
using System.IO;
using Treadle.Update;

namespace Treadle.Editor
{
	/// The updater's command-line modes (docs/Building.md, "Command-line modes"):
	///
	///   Treadle.exe --update [--check-only]   check GitHub Releases; when a newer version is offered, download it, check
	///                                         it against SHA256SUMS and start the helper that installs it (no window)
	///   Treadle.exe --update-health           what the helper starts after a command-line update: answers its health
	///                                         request, prints the version and exits
	///
	/// They use the same settings as the editor (channel, skipped versions, Work offline) and the same update folder.
	static class UpdateCli
	{
		/// The editor's own arguments, given back to it when an update restarts it.
		public static List<String> EditorArgs = new .() ~ DeleteContainerAndItems!(_);

		public static void Remember(String[] args)
		{
			for (let a in args)
				EditorArgs.Add(new String(a));
		}

		static void Out(StringView line, bool error = false) => Program.ConsoleOut(line, error);

		public static int Health()
		{
			String exe = scope .();
			Environment.GetExecutableFilePath(exe);
			String dir = scope .();
			Path.GetDirectoryPath(exe, dir).IgnoreError(); // empty: no request found below
			String updateDir = scope .();
			UpdateApply.Join(updateDir, dir, "update");
			bool answered = UpdateApply.ReportHealthy(updateDir);
			String v = scope .();
			UpdateApply.ReadVersionFile(dir, v);
			Out(scope $"Treadle {(v.IsEmpty ? Treadle.Document.TreadleInfo.FullVersion : v)}{(answered ? " started after an update" : "")}");
			return 0;
		}

		public static int Run(String[] args)
		{
			bool checkOnly = false;
			for (int i = 1; i < args.Count; i++)
			{
				if (args[i] == "--check-only")
					checkOnly = true;
				else
				{
					Out(scope $"Treadle: unknown --update option '{args[i]}' (only --check-only)", true);
					return 64;
				}
			}
			UpdatePrefs.Load();
			if (UpdatePrefs.WorkOffline)
			{
				Out("Treadle: Work offline is on (Editor Preferences > Updates); no update check was made.", true);
				return 1;
			}
			UpdateService svc = scope .();
			String dataDir = scope .();
			AppPaths.Root(dataDir);
			dataDir.AppendF("{}update", Path.DirectorySeparatorChar);
			svc.Init(dataDir);
			svc.Channel.Set(UpdatePrefs.ChannelName);
			svc.SetSkipped(UpdatePrefs.Skipped);
			String why = scope .();
			svc.AutomaticBlocker(why);
			if (!why.IsEmpty)
			{
				Out(scope $"Treadle: {why}", true);
				return 1;
			}
			UpdateStatus s = scope .();
			svc.StartCheck(true);
			svc.WaitIdle();
			svc.GetStatus(s);
			if (s.Reached)
			{
				UpdatePrefs.LastCheck = UpdatePrefs.NowUnix;
				UpdatePrefs.Save();
			}
			Out(s.Message);
			if (s.State == .UpToDate)
				return 0;
			if (s.State != .Available)
				return 1;
			if (checkOnly)
			{
				Out(scope $"Release page: {s.NotesUrl}");
				return 0;
			}
			if (s.ReadOnlyInstall)
				return 1;
			svc.StartDownload();
			svc.WaitIdle();
			svc.GetStatus(s);
			Out(s.Message);
			if (s.State != .Ready)
				return 1;
			svc.RestartArgs.Add(new String(UpdateApply.HealthSwitch));
			String reason = scope .();
			if (!svc.Apply(reason))
			{
				Out(scope $"Treadle: {reason}", true);
				return 1;
			}
			Out(scope $"Update helper started (process {svc.HelperPid}); it installs Treadle {s.LatestVersion} once this program has exited. Its log: {svc.UpdateDir}{Path.DirectorySeparatorChar}update.log");
			return 0;
		}
	}
}
