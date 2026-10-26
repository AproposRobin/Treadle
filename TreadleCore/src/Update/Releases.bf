// Copyright 2026 AproposRobin. Licensed under the Apache License, Version 2.0 (LICENSE at the repository root).

using System;
using System.Collections;

namespace Treadle.Update
{
	/// Where updates come from (docs/Releasing.md, "The update path"): the GitHub Releases of one repository, nothing
	/// else. THE ONE PLACE THE REPOSITORY IS NAMED. The asset names below are a contract with every installed copy:
	/// they must never change.
	public static class ReleaseChannel
	{
		/// `https://github.com/<owner>/<repo>`, no trailing slash.
		public const String Repository = "https://github.com/AproposRobin/Treadle";
		/// The same repository on the GitHub REST API.
		public const String ApiRepository = "https://api.github.com/repos/AproposRobin/Treadle";
		/// The checksum list every release carries (`sha256sum` format: `<64 hex>  <asset name>` per line).
		public const String SumsAsset = "SHA256SUMS";
		/// Newest releases looked at per check (one API request).
		public const int ListCount = 20;

		/// `Treadle-<version>-win64.zip` on Windows, `Treadle-<version>-linux-x64.tar.gz` on Linux.
		public static void PackageName(StringView version, String outName)
		{
#if BF_PLATFORM_WINDOWS
			outName.AppendF("Treadle-{}-win64.zip", version);
#else
			outName.AppendF("Treadle-{}-linux-x64.tar.gz", version);
#endif
		}

		/// The release page of a tag (shown as text; the editor never opens a browser for updates).
		public static void ReleasePage(StringView tag, String outUrl)
		{
			outUrl.AppendF("{}/releases/tag/{}", Repository, tag);
		}

		/// Hosts a GitHub release download may pass through (github.com answers with a redirect to its file host).
		/// Every other host is refused, and so is anything that is not https.
		public static bool IsAllowedHost(StringView host)
		{
			StringView[5] hosts = .("github.com", "api.github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com", "github-releases.githubusercontent.com");
			for (let h in hosts)
				if (host.Equals(h, true))
					return true;
			return false;
		}
	}

	/// One downloadable file of a release.
	public class ReleaseAsset
	{
		public String Name = new .() ~ delete _;
		public int64 Size;
	}

	/// One GitHub release, as the releases API describes it.
	public class ReleaseInfo
	{
		public String Tag = new .() ~ delete _;
		/// The tag without its leading `v`: `v0.1.1-alpha` -> `0.1.1-alpha`.
		public String Version = new .() ~ delete _;
		public bool Prerelease;
		public bool Draft;
		/// The release notes (markdown source, shown as plain text), at most MaxNotes bytes.
		public String Notes = new .() ~ delete _;
		public List<ReleaseAsset> Assets = new .() ~ DeleteContainerAndItems!(_);

		public const int MaxNotes = 64 * 1024;

		public ReleaseAsset FindAsset(StringView name)
		{
			for (let a in Assets)
				if (a.Name == name)
					return a;
			return null;
		}
	}

	public static class GitHubReleases
	{
		/// A tag, version or file name: [A-Za-z0-9._+-], 1..128 characters, not "." or "..".
		public static bool IsSafeSegment(StringView text)
		{
			if (text.IsEmpty || text.Length > 128 || text == "." || text == "..")
				return false;
			for (let c in text.RawChars)
			{
				if (!(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') && c != '.' && c != '_' && c != '-' && c != '+')
					return false;
			}
			return true;
		}

		public static bool IsSha256Hex(StringView text)
		{
			if (text.Length != 64)
				return false;
			for (let c in text.RawChars)
				if (!(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f'))
					return false;
			return true;
		}

		static ReleaseInfo ParseOne(UpdateJson rel)
		{
			if (!rel.IsObject)
				return null;
			let info = new ReleaseInfo();
			rel.GetString("tag_name", info.Tag);
			info.Draft = rel.GetBool("draft", true);
			info.Prerelease = rel.GetBool("prerelease", false);
			StringView v = info.Tag;
			if (v.StartsWith('v') || v.StartsWith('V'))
				v.RemoveFromStart(1);
			info.Version.Set(v);
			rel.GetString("body", info.Notes);
			if (info.Notes.Length > ReleaseInfo.MaxNotes)
			{
				info.Notes.RemoveToEnd(ReleaseInfo.MaxNotes);
				info.Notes.Append("\n...");
			}
			info.Notes.Replace("\r\n", "\n");
			let assets = rel.Get("assets");
			if (assets != null && assets.IsArray)
			{
				for (let a in assets.Items)
				{
					if (!a.IsObject)
						continue;
					let asset = new ReleaseAsset();
					a.GetString("name", asset.Name);
					a.GetInt("size", out asset.Size);
					if (!IsSafeSegment(asset.Name))
					{
						delete asset;
						continue;
					}
					info.Assets.Add(asset);
				}
			}
			if (!IsSafeSegment(info.Tag) || !ReleaseVersion.TryParse(info.Version, ?, ?))
			{
				delete info;
				return null;
			}
			return info;
		}

		/// Reads a releases list (`GET /repos/<o>/<r>/releases`) or one release object. Entries that are not
		/// well-formed (no safe tag, no version in the tag) are left out.
		public static bool Parse(StringView json, List<ReleaseInfo> outReleases)
		{
			if (!(UpdateJson.Parse(json) case .Ok(let root)))
				return false;
			defer delete root;
			if (root.IsArray)
			{
				for (let rel in root.Items)
					if (let info = ParseOne(rel))
						outReleases.Add(info);
				return true;
			}
			if (root.IsObject)
			{
				if (let info = ParseOne(root))
					outReleases.Add(info);
				return true;
			}
			return false;
		}

		/// The newest release this copy should be offered, or null: published (not a draft), a pre-release only when
		/// `includePrerelease` (the alpha channel), newer than `running`, not in `skipped`, and carrying both this
		/// platform's package (ReleaseChannel.PackageName) and SHA256SUMS. `outNote` says why a newer release was
		/// passed over when nothing is offered ("" when there simply is nothing newer).
		public static ReleaseInfo Pick(List<ReleaseInfo> releases, StringView running, bool includePrerelease, List<String> skipped, String outNote)
		{
			ReleaseInfo best = null;
			for (let r in releases)
			{
				if (r.Draft || (r.Prerelease && !includePrerelease))
					continue;
				if (ReleaseVersion.Compare(r.Version, running) <= 0)
					continue;
				bool skip = false;
				if (skipped != null)
					for (let s in skipped)
						if (s == r.Version)
							skip = true;
				if (skip)
				{
					if (outNote.IsEmpty)
						outNote.AppendF("{} is skipped", r.Version);
					continue;
				}
				String pkg = scope .();
				ReleaseChannel.PackageName(r.Version, pkg);
				if (r.FindAsset(pkg) == null || r.FindAsset(ReleaseChannel.SumsAsset) == null)
				{
					outNote.Clear();
					outNote.AppendF("{} has no {} or no {}", r.Version, pkg, ReleaseChannel.SumsAsset);
					continue;
				}
				if (best == null || ReleaseVersion.Compare(r.Version, best.Version) > 0)
					best = r;
			}
			if (best != null)
				outNote.Clear();
			return best;
		}
	}

	/// SHA256SUMS: one `<64 hex>  <name>` (or `<hex> *<name>`) per line, as `sha256sum` writes it.
	public static class Sha256Sums
	{
		public const int MaxBytes = 64 * 1024;

		/// The lower-case hash listed for `name`; false when the name is not listed or its line is malformed.
		public static bool Find(StringView text, StringView name, String outHex)
		{
			for (var line in text.Split('\n'))
			{
				line.Trim();
				if (line.IsEmpty || line.StartsWith('#'))
					continue;
				if (line.Length < 66 || line[64] != ' ')
					continue;
				var hex = line.Substring(0, 64);
				var rest = line.Substring(64);
				rest.TrimStart();
				if (rest.StartsWith('*'))
					rest.RemoveFromStart(1);
				if (rest != name)
					continue;
				String lower = scope .(hex);
				lower.ToLower();
				if (!GitHubReleases.IsSha256Hex(lower))
					return false;
				outHex.Set(lower);
				return true;
			}
			return false;
		}
	}

	/// Versions as the package carries them (VERSION.txt): MAJOR.MINOR.PATCH with an optional -prerelease part
	/// (`0.1.9-alpha`). Compared like semantic versions: numbers first, then a version without a suffix is above one with
	/// a suffix, then the dot-separated suffix parts (numeric parts as numbers, numbers below words). `+build` metadata
	/// is ignored.
	public static class ReleaseVersion
	{
		public static bool TryParse(StringView text, out int64[3] core, out StringView pre)
		{
			core = default;
			pre = default;
			var main = text;
			int plus = main.IndexOf('+');
			if (plus >= 0)
				main = main.Substring(0, plus);
			int dash = main.IndexOf('-');
			if (dash >= 0)
			{
				pre = main.Substring(dash + 1);
				main = main.Substring(0, dash);
				if (pre.IsEmpty)
					return false;
			}
			int n = 0;
			for (let part in main.Split('.'))
			{
				if (n >= 3 || part.IsEmpty || part.Length > 9)
					return false;
				for (let c in part.RawChars)
					if (!c.IsDigit)
						return false;
				core[n++] = int64.Parse(part).GetValueOrDefault();
			}
			return n == 3;
		}

		static bool IsNumeric(StringView s)
		{
			if (s.IsEmpty || s.Length > 9)
				return false;
			for (let c in s.RawChars)
				if (!c.IsDigit)
					return false;
			return true;
		}

		static int CompareOrdinal(StringView a, StringView b)
		{
			int n = Math.Min(a.Length, b.Length);
			for (int i < n)
			{
				if (a[i] != b[i])
					return (uint8)a[i] < (uint8)b[i] ? -1 : 1;
			}
			return a.Length <=> b.Length;
		}

		/// <0 when a is older than b, 0 equal, >0 newer. Unparsable versions compare as equal (never "newer").
		public static int Compare(StringView a, StringView b)
		{
			if (!TryParse(a, let ca, let pa))
				return 0;
			if (!TryParse(b, let cb, let pb))
				return 0;
			for (int i < 3)
				if (ca[i] != cb[i])
					return ca[i] < cb[i] ? -1 : 1;
			if (pa.IsEmpty != pb.IsEmpty)
				return pa.IsEmpty ? 1 : -1;
			if (pa.IsEmpty)
				return 0;
			var ea = pa.Split('.');
			var eb = pb.Split('.');
			while (true)
			{
				let ha = ea.GetNext();
				let hb = eb.GetNext();
				if (ha case .Err)
					return (hb case .Err) ? 0 : -1;
				if (hb case .Err)
					return 1;
				let xa = ha.Value;
				let xb = hb.Value;
				bool na = IsNumeric(xa);
				bool nb = IsNumeric(xb);
				if (na && nb)
				{
					let va = int64.Parse(xa).GetValueOrDefault();
					let vb = int64.Parse(xb).GetValueOrDefault();
					if (va != vb)
						return va < vb ? -1 : 1;
				}
				else if (na != nb)
					return na ? -1 : 1;
				else
				{
					let c = CompareOrdinal(xa, xb);
					if (c != 0)
						return c;
				}
			}
		}
	}
}
