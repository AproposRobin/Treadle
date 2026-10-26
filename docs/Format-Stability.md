---
audience: developer
title: Format stability
summary: What in the graph format is frozen at beta and at 1.0, the version header rule, the migration command, the alias table for renamed nodes and pins, the format-history corpus, and the owner decisions needed before beta.
order: 14
---

# Format stability

The graph files are the program ([Graph-Format.md](Graph-Format.md)): a user's project is only as durable
as the format's promise. This page is that promise and the machinery behind it. Graph-Format.md says what the
records are; this page says which of them may still change, how a change is shipped, and how old files keep
loading. The machinery of sections 2-5 is built (2026-10-25, `wt/migrate`): the migration chain, `--format
--migrate`, the alias table, the read-only open of a newer file and the format-history corpus; each section
says what is built and what is still policy. The extension migration of 3.4 is built with the product rename
(2026-10-25).

## 1. What is frozen

### 1.1 Frozen at beta

From the first beta, each item below changes only through the version rule of section 2 (a bump with a
migration step) or, for names, through the alias table of section 4. Never silently.

| Area | Frozen | Graph-Format.md |
|---|---|---|
| Lexical rules | UTF-8, line records at column 0, properties on one tab, `#` comments, word / string tokens with JSON escapes, the free-text quoting rule (quote only when the value would not read back as a word), `<id>.<pin>` wire ends split at the first dot | 2 |
| Header | `# <word> <n>` on line 1 of every file kind; the number is one integer, `1` today | 2, 8 |
| Record kinds | Type file: `type field case property function ctor dtor operator param out local sheet node wire group`. C declarations (`.cdecl`): those plus `cstruct cunion cenum ctypedef cconst cvar`. Layout: `sheet view saved node box route collapsed pinned`. Project: `project depends cimport config source`. C import set: `import` | 3.1, 4, 5, 6 |
| Key names | Every property key in the tables of 3.1, 3.2 (node `set` keys included), 4, 5 and 6, with its documented default | 3-6 |
| Node kind names | The `Kind` words of 3.2 (`Entry` ... `Intrinsic`), case-sensitive | 3.2 |
| Stored pin names | Every pin a wire, `in` or `split` line can name: the fixed names of 3.2 (`in`, `then`, `value`, `result`, `receiver`, `condition`, `body`, `done`, ...), the generated families (`then0..n`, `out0..n`, `case:<label>`, `case:<label>.<field>`, `va0..`, `arg0..`, `p0..`), parameter and field names, split field pins `<pin>.<field>` | 3.2, Language.md 5 |
| Id scheme | Node, member and group ids: a word of 1-8 chars `[a-z0-9]`, unique per file, never reused; the editor writes 5-char Crockford base32 ids | 2, 7 |
| Canonical order | Members in declaration order, fixed key order per record, nodes by id, wires by destination then source, groups by id; one blank line between members | 3.1, 7 |
| Unknown content | Unknown records, keys and comments kept and written back in place (type files, layout); an unknown node kind keeps its word (`Node.KindWord`) | 2 |
| Sidecar separation | Meaning lives only in the type file; positions, knots, boxes, views and fold state only in the layout file (`layout/<path>.layout`, outside the source folders). Deleting a layout never changes a program | 4 |
| Member references | `Type.Member`, `Type.Member(ParamTypes)`, `this.Member`, `local:` / `param:`, `C.<set>.<symbol>` | 2, 3.2 |

### 1.2 Frozen at 1.0

Everything in 1.1, plus:

* **Type text** in tokens (`List<int>`, `int[4]`, `function:int(int)`, `(int,float)`), including the spelling
  of the built-in numeric types (decision 4 in section 6).
* **The file extensions and header words** (`.treadle`, `.layout`, `.tproj`, `.tir`, `.cimport`, `.cdecl`; 3.4), with the old ones read forever.
* **The alias table is append-only** (section 4): a name that ever loaded keeps loading.
* **The migration chain is complete**: every version ever written migrates to the current one (section 5).
* **The `.cdecl` C records** and the `.cimport` keys (`header include define lib pure hide only category`,
  plus `prefix param bin csource` kept as unmodelled properties).

### 1.3 Still open before beta

| Item | State | Why it is open |
|---|---|---|
| File extensions and header words | `.treadle`, `.layout` (in `layout/`), `.tproj`, `.tir`, `.cimport`, `.cdecl`, `# treadle 1` | Settled by the product rename (2026-10-25); the old names are read forever and `--format --migrate` renames them (3.4). Freeze at beta |
| `group` record, node `split`, field `category` | Added 2026-10-25 without a bump | New; no real users yet. Shape fixed at beta |
| Layout `node` / `collapsed` naming a group, `saved`, `pinned` | New | Layout is lenient (3.2), so lower stakes |
| Project `kind`, config `optimize` / `checks` / `define` / `debugFormat` | On master kept and written back; Build reads only `debugFormat`. `wt/kind` makes Build read them with defaults (`kind console`; `optimize` 2 / 0 and `checks` off / on by config name; `debugFormat dwarf`) | The value sets (`optimize size`, `define NAME=value`) are new; freeze after `wt/kind` merges |
| Project file unknown records | Written at the end of the file, not in place (Graph-Format.md 5) | Should follow the type file rule before beta |
| The header number's meaning | One integer; Graph-Format.md 8 said "major version" and now says the single integer | Settled here: one integer (section 2) |

**Not part of the format:** `.tir` (the Sheet IR text of `TreadleBackend` and `TreadleCompiler/fixtures`) is an
internal compiler artifact with no stability promise; `.expected` files, `build/` output, debug info and the
editor's preferences are not the format either.

## 2. Versioning rule

**One integer per header.** Today all four headers share `TreadleCodec.Version = 1`
(`TreadleCore/src/Format/TreadleCodec.bf`). Readers and writers use `TreadleCodec.Current` (=
`Migrations.Current`: the constant, or the `codec` self test's simulated bump). When one file kind bumps, the
constant splits into one per kind; the numbers are independent from then on.

**What bumps it:** any change an older reader would get wrong, rather than merely not understand:

* a record or key whose meaning changes (a different default, unit or token order);
* a renamed or removed record kind or key (node kinds and pins go through the alias table instead, section 4);
* a change to the lexical rules, quoting, id scheme or canonical order;
* a new record or key that is **required** for correct meaning, i.e. dropping it would change the program.

**What does not bump it:** a new optional record or key with a documented default equal to the behaviour of
a file without it. Older readers keep it verbatim (1.1, "Unknown content"); the 2026-10-25 keys (`category`,
`split`, `group`) were added this way. Each such addition gets a dated line in Graph-Format.md 8. A new node
kind is an optional addition: no bump, an older reader keeps it as an unknown kind.

**Compatibility matrix** (reader and writer at version N):

| File version | Read | Write |
|---|---|---|
| older than N | Yes, migrated step by step on load (section 3); the document is marked dirty | Written as N, after a backup |
| N | Yes; unknown records and keys from newer optional additions kept in place | Written as N, byte-identical when unchanged |
| newer than N | Refused for editing (below) | Never |

**A newer version (built).** `TreadleCodec.ReadHeader` classifies the header (`Current`, `Older`, `Newer`,
`Bad`). Every reader that is not the editor's open (the compiler's `ProjectLoader`, `--format`, the C import)
refuses a newer file with a typed `NewerVersionError` on line 1 (`FileVersion`, `ReaderVersion`;
`TreadleCodec.NewerIn(errors)` finds it), message "saved by a newer version V; this build reads up to N; open
read-only". The editor's open (`TypeDocument.Load`) reads it best-effort instead, with the header check
relaxed and unknown lines kept, and sets `TypeDocument.NewerVersion`: every Sheet's graph is read-only, a
notice bar over the graph area repeats the message ("... Save, edits and Build are off for this file";
`Shell.bf`, `DrawFormatNotice`), `CheckWritable` refuses edits, Save is disabled (toolbar, `SaveDoc`,
`TrySave`) and Build is refused while such a document is open. `--build-run` refuses a project holding a newer
file with the same message and exit code 2 (`Migrations.FindNewer`); `--format` lists it as `error` and exits 2.
Not built: naming the editor release that reads version V (no release table yet).

**Unknown content in a current-version file** loads with a message ("N record(s) of a newer format are kept
as they are", `TypeDocument.Load`). Graph-Format.md 2 said such a document is read-only; as built it stays
editable and the unknown lines are written back in place. The policy keeps the built behaviour (edits
round-trip safely), and Graph-Format.md 2 now says so.

## 3. Migration

### 3.1 Step functions in the codec

**Built** in `TreadleCore/src/Format/Migrations.bf`. A bump from N-1 to N ships one step per file kind it
touches: a `MigrationStep(fileKind, N-1, N, Migrate)` added in `Migrations`' static constructor, where
`Migrate(FormatRecords file, List<String> notes)` rewrites the file's records. `FormatRecords` is the file
split into records before the reader binds anything: each `FormatRecord` is a record line and its property
lines (comments and blank lines are records of their own, so a file with no step to run writes back as it was
read), with helpers for the common shapes (`RenameKey(record, old, new)`, `RenameRecord(old, new)`). The
reader only ever knows the current version. Rules:

* **Chained**: `Migrations.Run(kind, text, from)` runs every step of `kind` from the file's version up, in
  version order, then writes the header at the current version. Steps are never deleted.
* **Idempotent**: a step run on its own output changes nothing (it matches only the old shape; the chain
  rewrites the header).
* **Total**: a step never fails on a file the old reader accepted; anything it cannot map stays an unknown
  record (kept in place) plus a note.
* **Run on load**: every reader runs the chain through `TreadleCodec.Prepare` (type file, layout, project, C
  import set), so the compiler, the C import and the editor all read old files. `TypeDocument.Load` keeps
  `MigratedFrom` (and `LayoutMigratedFrom`), marks the document dirty and lists the step notes and a line
  naming the backup in its load messages. The first save writes `backup/<path>.v<old>.bak` (and
  `backup/layout/<path>.layout.v<old>.bak`; one per old version, never overwritten: `Migrations.BackupOnce`), then the
  file at the current version.
* **No step has shipped yet**: every file written so far is version 1. The `codec` self test registers a
  test-only step (`Migrations.SimulateBump(2, ...)`: a field's `doc` key renamed `summary`) and checks the
  whole path on a copy of `format-history/v1/Player.treadle` (section 5).

### 3.2 The layout sidecar

Layout is disposable, so its migration is lenient: an unknown or unmappable layout line is dropped without an
error, and a layout whose header is newer than the reader is ignored (positions fall back to auto-layout)
rather than refused. A layout is never a reason not to open a program. As built: an older layout runs the
chain (`vtype-layout` steps) like any file; a newer one is not read and the document's Sheets are laid out
again, with a load message.

### 3.3 The command (`--format`)

**Built** (`--format` and `--check` on `wt/fix2`, `--migrate` on `wt/migrate`; `Treadle.Format.Canonical`,
the switch in `TreadleEditor/src/BuildRun.bf`):

```
Treadle --format <file|folder>... [--migrate] [--check]
```

* `--format` reads every format file of the target (a file; a folder: recursively, skipping folders starting
  with `.`, `build` folders and `format-history`) and writes the canonical form. Files already canonical are
  not touched.
* `--migrate` also runs the migration chain on files below the current version, layout sidecars included,
  and writes them at the current version after `backup/<path>.v<old>.bak` (3.1). Without it an old-version file is
  reported (`old version <path>: format version V, this build writes N`) and not rewritten (exit 1).
* `--check` writes nothing: exit 0 when every file is canonical and current, 1 with one line per file that is
  not (not canonical, or below the current version), also 1 when a file does not read.
* A file newer than this build is listed as `error <path>: saved by a newer version ...`, never written, and
  the exit code is 2 (also 2 for a bad command line).
* No window opens; output is one line per file and a summary; no prompts, so it is safe in batch runs.
* Not built: `--no-backup` and taking a project file as the target (name its folder).

### 3.4 Extension migration at the rename

* The reader accepts the old extensions and header words **forever**; the writer writes only the new ones
  (**built**, `TreadleCore/src/Format/FormatNames.bf`). The pairs: `.treadle` / `.vtype`, `.treadle.layout` /
  `.vtype.layout`, `.tproj` / `.vproject`, `.tir` / `.kir`; header words `treadle` / `vtype` (type files and
  `.cdecl`), `treadle-layout` / `vtype-layout`, `tproj` / `vproject`, `tir` / `kir`. `.cimport` and `.cdecl`
  keep their names. The format version is not involved (still 1).
* `--format --migrate <project>` renames the old-extension files (a layout together with its type file),
  rewrites the header word and points the project file's `depends` paths at the new names; `--format --check`
  lists the old names and fails (**built**). Each file is a rename plus a one-line header change, so git records
  it as a rename. A folder holding both names of one type file (`Player.vtype` and `Player.treadle`) is error
  T0017, naming both; a `depends` path finds the project under either extension.
* Not built: opening an old-extension project in the editor offering the same migration once. The editor
  reads and saves such files in place (their names are kept), so nobody is forced to migrate mid-branch.
* **Layout and backup folders** (decided 2026-10-25, **built**): the layout file is no longer a sibling of the
  type file. `layout/<relative path, extension dropped>.layout` and `backup/<relative path>.bak` under the project
  folder (project keys `layoutDir` and `backupDir`; [Graph-Format.md 4](Graph-Format.md#4-layout-file-layoutpathtypelayout)),
  so a graph can be run without its layout and the sources stay clean. This is a project-level path change, not a
  change of the text of any file: the format version stays 1 and the `format-history/v1` corpus keeps its
  beside-the-file layouts (it is never moved). Opening a project (and `--format --migrate <project>`) moves old
  `<Type>.treadle.layout` / `.vtype.layout` files and format-file backups from beside the sources into the folders
  once, keeping the newer file when both places have one.
* `format-history/` keeps the old names and header words (the read-old corpus); the `codec` self test also
  migrates a copy of it under its old names and checks the result clean.

### 3.5 The repository's own files stay canonical

The roughly 290 format files in the repository (`TreadleCore/samples/**`, `TreadleCore/core/*.treadle`, the
`TreadleCompiler/fixtures` projects and broken samples, the `.cimport` / `.cdecl` sets) are the first corpus any
change must handle. The `codec` self test checks the three Graph-Format samples byte for byte, the
reading-order originals, and the equivalent of `--format --check` over every format file under
`TreadleCore/samples` (but `reading-order/` and `format-history/`) and `TreadleCore/core`; the `core` self
test checks the core writes back byte for byte. Still policy: the `TreadleCompiler/fixtures` files. A bump
commit runs `--format --migrate` over the repository in the same commit, so master never holds an
old-version file outside `format-history` (section 5).

## 4. Renaming a node kind or pin

Renames of stored names never rewrite files. The codec keeps an **alias table**
(`TreadleCore/src/Format/Aliases.bf`, **built** for node kinds and pins) of old names to current ones, applied
by the type file reader: `Aliases.Kind(word)` before the kind is parsed, `Aliases.Pin(kind, pin)` on every
`in` line and wire end (a split field pin `<pin>.<field>` maps its first part). The table holds one
placeholder row of each, the documented example, which no release ever wrote: `ExampleBranch -> Branch` and
`Branch.example-condition -> condition` (2026-10-25); the `codec` self test reads them. Key aliases (the third
row form below) are not built: a renamed key goes through a migration step (3.1).

```
// kind  <old word>           -> <new word>     since
// pin   <Kind>.<old pin>     -> <new pin>      since
// key   <record>.<old key>   -> <new key>      since
```

* The reader maps on read; the writer writes the new name. An old file loads with no migration step and no
  bump; its next save writes the new names (a normal, reviewable diff).
* Entries are **never removed** (frozen at 1.0). A name may not be reused for another meaning while it is an
  alias.
* A rename that changes meaning (pins added or split, a setting's values changed) is not an alias: it is a
  version bump with a step function.
* Deprecation note: each alias adds one line to Graph-Format.md 8 in this form:

  > **Deprecated 2026-11-02:** node kind `Format` renamed to `FormatString`; old files load unchanged and are
  > saved with the new name. Alias kept forever.

Member renames inside a user's project are not format renames; they stay editor edits over every referencing
line (Graph-Format.md 7).

## 5. Test corpus

Within the existing essential `roundtrip` / `codec` checks (no new suite):

Built in the `codec` self test (`TreadleEditor/src/SelfTestMigrate.bf`, 17 checks):

* **Format history (built).** `TreadleCore/samples/format-history/v1/` holds the version 1 snapshot (its
  `README.md` states the rule): the three Graph-Format examples (`Player.treadle` with its layout,
  `Program.treadle`, `Pair.treadle`), `Shooter.tproj`, `libc.cimport`, `libc.cdecl`, and `Habits.treadle` with its
  layout (`split`, `group`, `category`). Every later bump adds `vN/` with files that exercise what changed. These
  files are never edited or re-saved; `--format`, the canonical check of 3.5 and the project scans skip the
  folder (`Canonical.HistoryFolder`).
* **Per history file:** (1) it loads with the current reader and, at the current version, writes back byte for
  byte (layouts too); once a bump exists, (2) migrated and written it equals the checked-in
  `format-history/vN/<name>.expected` and (3) migrating that again changes nothing. Until then the simulated
  bump covers (2) and (3): a v1 copy loads dirty under version 2, its first save writes the expected text and
  both `.v1.bak` files, the backup is written once, the result reloads as current, the step is idempotent, and
  `--format` reports it without `--migrate`, migrates it with it, and finds it current afterwards.
* **Per alias:** the placeholder rows read as the new names and are written with them.
* **Newer version:** a `# treadle 9` copy is refused with the typed result; the editor's open keeps every member,
  every Sheet is read-only, the notice shows, edits and Save are refused and the file is untouched;
  `--build-run`'s check and `--format` find it.
* **Unknown content:** the existing check (unknown records, keys and comments survive in place) stays.

## 6. Decisions for the owner before beta

| # | Decision | Recommendation |
|---|---|---|
| 1 | **Extensions and header words** | Decided with the product rename (2026-10-25): `.treadle`, `.treadle.layout`, `.tproj`, `.tir`; the old names are read forever; one `--format --migrate` per project |
| 2 | **Id length**: 1-8 chars accepted, the editor writes 5, samples use 2 (`a1`) | Keep 1-8 on read and 5 on write: 32^5 = 33 M ids per file makes collisions between branches negligible. Leave the short sample ids (readability) |
| 3 | **Layout stays a sidecar** | Yes: it keeps semantic diffs clean and lets layout be lenient. The extra file per type is the price of clean diffs |
| 4 | **`int64` vs `int` in type text**: the core writes both (`int` pointer-sized, `int64` fixed) | Keep both as distinct types, freeze the spelling, never normalise one into the other on write; state in Language.md 2 that `int` is pointer-sized |
| 5 | **The `group` record** sits in the type file though the compiler ignores it | Keep it there: membership is structure people review and merge; only fold state and position are layout. Freeze its shape at beta |
| 6 | **Case-sensitivity of names** | Case-sensitive everywhere (kind words, keys, members, pins), as built. Warn on two types of one project whose names differ only in case (their files collide on case-insensitive file systems) |
| 7 | **Line endings** | Write `LF` always, accept `CRLF` on read (as built, `RecordText.SplitLines`), and have New Project write a `.gitattributes` with `eol=lf` for the format extensions so Windows checkouts do not flip files |
| 8 | **File size and performance** | Largest today: `core/String.treadle` 40 KB, `m4-breakout/Game.treadle` 26 KB. Target: a 1 MB type file loads and saves under 100 ms; above 200 KB the editor suggests splitting the type. No hard limit in the format |
