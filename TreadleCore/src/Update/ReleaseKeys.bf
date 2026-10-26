// Copyright 2026 AproposRobin. Licensed under the Apache License, Version 2.0 (LICENSE at the repository root).

using System;

namespace Treadle.Update
{
	/// The release channel this build updates from (docs/Releasing.md, "The update channel"): the GitHub repository whose
	/// Releases carry the packages, and the release signing key(s) this build trusts. Both are EMPTY until Treadle has a
	/// release channel; while either is empty the updater makes no network request at all (automatic or manual) and the
	/// editor says that updates are not set up in this build (a manual download still works).
	///
	/// THE ONE PLACE THE CHANNEL IS CONFIGURED. To set one up: put the repository URL (`https://github.com/<owner>/<repo>`)
	/// in `Repository` and the base64 Ed25519 public key(s) of the release signing key in `ReleaseKeys.Keys` (several keys,
	/// a rotation, separated by ';'), commit, and package. Never put a private key here or anywhere in the repository.
	public static class ReleaseChannel
	{
		/// `https://github.com/<owner>/<repo>`, no trailing slash. Empty: no release channel.
		public const String Repository = "";

		/// True when the channel is set up: a repository and at least one trusted key (`keys` defaults to ReleaseKeys.Keys).
		public static bool IsConfigured(StringView repository, StringView keys) => !repository.IsEmpty && ReleaseDescriptor.HasKeys(keys);
	}

	/// The release signing key(s) this build trusts (base64 Ed25519 public keys separated by ';'). Empty: this build
	/// trusts no key, so the updater refuses every release descriptor (and makes no request, see ReleaseChannel).
	public static class ReleaseKeys
	{
		public const String Keys = ""; // no Treadle signing key yet (the forked editor's key is not trusted)
	}
}
