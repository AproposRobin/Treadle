# Format history

The frozen corpus of the graph format (docs/Format-Stability.md 5). One folder per format version
ever written: `v1/` holds files exactly as version 1 wrote them, and every bump adds `v<N>/` with files
that exercise what changed.

Rules:

* **Never edit or re-save a file here.** These are what users' old projects look like; they are the
  input the migration chain must keep loading forever. `--format` and the `codec` self test's
  canonical check skip this folder (`Treadle.Format.Canonical.HistoryFolder`), and project scans
  (the compiler's `ProjectLoader`, the editor's `ProjectIndex`) do not read it.
* **A new folder at each bump.** The bump commit copies the files that the new version changes into
  `v<N-1>/` if they are not already there, adds `v<N>/`, and runs `--format --migrate` over the rest of
  the repository in the same commit.
* **Expected output beside the input** once a bump exists: `<name>.expected` is the file migrated to the
  current version and written. Until the first bump, the current version is 1 and each `v1` file must
  load and write back byte for byte.

What the `codec` self test does with this folder:

1. Every type, C declarations, project and C import file of every `v<N>/` loads with the current reader;
   at the current version it writes back byte for byte (layout sidecars too), apart from the header word,
   which the writer gives in its current form (`# treadle` for `# vtype`, FormatNames).
2. A simulated bump (a self-test-only step, version 1 to 2, renaming a key) migrates a copy of
   `v1/Player.vtype` (as `Player.treadle`): it loads, is marked dirty, saves as version 2 with `Player.treadle.v1.bak` written
   once, compares with the expected text, and migrating the result again changes nothing.
3. A copy with its header raised past the current version opens read-only (Save refused, the file
   untouched).
4. A copy of the folder under its old names: `--format --check` lists the renames, `--format --migrate`
   renames every file to the current extension and header word, and the folder then checks clean.

The files keep the extensions and header words from before the product rename (`.vtype`, `.vtype.layout`,
`.vproject`, `# vtype`, `# vproject`): they are the read-old corpus of docs/Format-Stability.md.

`v1/` (2026-10-25): the three type files of docs/Graph-Format.md 3.3-3.5 (`Player.vtype` with its
layout, `Program.vtype`, `Pair.vtype`), `Shooter.vproject` (5), `libc.cimport` (6) and its
`libc.cdecl`, and `Habits.vtype` with its layout (a field `category`, node `split` lines and a `group`,
the 2026-10-25 additions of Graph-Format.md 8).
