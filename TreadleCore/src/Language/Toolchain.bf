using System;
using System.Collections;
using Treadle.Document;

namespace Treadle.Language
{
	/// Validate, Build and Run: the three operations a language backend offers on a workspace
	/// (docs/Graph-Architecture.md, sections 2.3 and 4.3). The editor reaches the compiler only
	/// through this interface, so a backend for another language plugs in its own checker and
	/// build tool. Until the compiler is installed the shell runs NullToolchain.
	///
	///  - **Validate** asks "is the code right?" and never writes anything: no file is saved, no
	///    output is produced. Level 1 is the graph checks plus the parse of the documents' text,
	///    always available and instant. Level 2 is the compiler's own checks of the whole
	///    workspace, with the open documents' unsaved text, when the backend has a checker
	///    (`CanValidate`); it runs in the background.
	///  - **Build** makes the outputs: the documents are saved by the caller first, then the
	///    build tool runs (or is skipped when nothing it reads changed).
	///  - **Run** builds only when the outputs are stale, then the caller launches or debugs.
	interface IToolchain
	{
		/// True when Validate reaches the compiler's own checks (Level 2): the checker is up.
		/// False before the first Validate of a workspace starts it, and when the backend has none
		/// for this system (then the full type checks need Build).
		bool CanValidate { get; }

		/// Checks the request's documents and Sheets as they are in memory (unsaved text included).
		/// Never saves, never runs the build tool. Level 1 is done when it returns; when the
		/// request names a workspace and the backend has a checker, Level 2 continues in the
		/// background (`ValidateJob.Running`): call `Update` on the job once per frame until it
		/// returns true.
		ValidateJob Validate(in ValidateRequest request);

		/// The compiler's own parse of one file's text (no type checks), for text being typed.
		/// Null when it cannot answer at once (no checker up, or it is busy): the caller goes on
		/// with its own parse.
		SyntaxJob CheckSyntax(in SyntaxRequest request);

		/// True while the checker is up but answering something else (a Validate): CheckSyntax
		/// returns null now and can answer once it is done. The caller may wait a little.
		bool SyntaxBusy { get; }

		/// Starts a build of the workspace. The job runs in the background: call `Update` once per
		/// frame until it returns true. Err when the build tool is not there at all.
		Result<BuildJob> Build(in BuildRequest request);

		/// Starts the build Run needs: like Build, but never forced, so up-to-date outputs are used
		/// as they are. The caller launches (or debugs) the program when the job succeeded.
		Result<BuildJob> Run(in RunRequest request);

		/// Call once per frame (`now` in seconds): background upkeep (a checker unused for a long
		/// time is stopped to give its memory back). Lines for the Output Log are added to `outLog`.
		void Update(double now, List<String> outLog);
	}

	/// What Validate checks.
	struct ValidateRequest
	{
		/// Documents whose text is parsed again (members the editor cannot read, declaration
		/// errors). Usually the current document.
		public List<TypeDocument> Documents;
		/// Function graphs (Sheets) whose graph checks run (GraphValidator and the writer's own
		/// refusals; nothing is written). Usually every open Sheet.
		public List<Sheet> Sheets;
		/// Level 2: the folder with the workspace file (the project file). Empty: Level 1
		/// only.
		public StringView Workspace;
		/// Level 2: the configuration ("Debug" / "Release"; "" = Debug).
		public StringView Config;
		/// Level 2: the build tool (its folder is where the backend finds its compiler).
		public StringView Tool;
		/// Level 2: every open document. The compiler sees their text instead of the saved files.
		public List<TypeDocument> OpenDocuments;
	}

	/// The result of a Validate.
	class ValidateJob
	{
		/// The graph checks' errors and warnings, each on its Sheet and node (`Origin` is
		/// `.Validate`). The editor refreshes a Sheet's rows after each edit of it. Owned.
		public List<Diagnostic> Messages = new .() ~ DeleteContainerAndItems!(_);
		/// The parse's errors: members the editor cannot read, declaration errors (with their file
		/// and line; on the function's node when it has a Sheet). Owned.
		public List<Diagnostic> TextMessages = new .() ~ DeleteContainerAndItems!(_);
		/// Level 2: the compiler's errors and warnings over the whole workspace, in the build tool's
		/// words with file, line and column (`Origin` is `.Validate`). The caller places them on
		/// nodes (DiagnosticMap.Locate) while the documents still have the text that was checked
		/// (SentVersions). Owned.
		public List<Diagnostic> CompilerMessages = new .() ~ DeleteContainerAndItems!(_);
		/// The files whose text was parsed (their parse results replace any older ones).
		public List<String> Files = new .() ~ DeleteContainerAndItems!(_);
		/// Level 2: the open documents' versions as the compiler saw them, by path.
		public Dictionary<String, int32> SentVersions = new .() ~ DeleteDictionaryAndKeys!(_);
		/// 1: graph checks and the parse. 2: the compiler's checks came back too.
		public int32 Level = 1;
		/// Sheets checked.
		public int32 Sheets;
		/// Milliseconds the Level 1 checks took.
		public double Ms;
		/// Level 2 was asked for and is still running.
		public bool Running;
		/// Level 2 was asked for (it may still run, or it was not possible: see Note).
		public bool Level2Asked;
		/// Milliseconds the compiler's checks took, from the request to the answer (Level 2).
		public double CompilerMs;
		/// Why Level 2 did not run or did not finish ("" when it did, or was not asked for).
		public String Note = new .() ~ delete _;

		public int Count => Messages.Count + TextMessages.Count + CompilerMessages.Count;

		public int ErrorCount
		{
			get
			{
				int n = 0;
				for (let m in Messages)
					if (m.IsError)
						n++;
				for (let m in TextMessages)
					if (m.IsError)
						n++;
				for (let m in CompilerMessages)
					if (m.IsError)
						n++;
				return n;
			}
		}

		public int WarningCount => Count - ErrorCount;

		/// True when `path` is one of the files this Validate parsed.
		public bool Parsed(StringView path)
		{
			for (let f in Files)
				if (ProjectIndex.SamePath(f, path))
					return true;
			return false;
		}

		/// The version of `path` the compiler checked (-1 when it was not an open document).
		public int32 SentVersion(StringView path)
		{
			for (let kv in SentVersions)
				if (ProjectIndex.SamePath(kv.key, path))
					return kv.value;
			return -1;
		}

		/// Call once per frame while `Running`. Returns true when Level 2 just finished (or gave
		/// up: Note says why).
		public virtual bool Update() => false;
	}

	/// What CheckSyntax parses.
	struct SyntaxRequest
	{
		/// The folder with the workspace file.
		public StringView Workspace;
		/// The file the text belongs to.
		public StringView Path;
		/// The whole file's text as it would be.
		public StringView Text;
	}

	/// The compiler's parse of one text (CheckSyntax).
	abstract class SyntaxJob
	{
		/// Errors and warnings of that file's parse, with line and column. Owned.
		public List<Diagnostic> Messages = new .() ~ DeleteContainerAndItems!(_);
		public bool Running = true;
		/// The checker ended before it answered: no result (the caller goes on without it).
		public bool Lost;
		/// Milliseconds from the request to the answer.
		public double Ms;

		/// Call once per frame. Returns true when the answer just came (or it was lost).
		public abstract bool Update();
	}

	/// What Build builds.
	struct BuildRequest
	{
		/// The folder with the workspace file (the project file).
		public StringView Workspace;
		/// "Debug" / "Release" ("" = the build tool's default).
		public StringView Config;
		/// The build tool (a path or a bare name looked up on PATH).
		public StringView Tool;
		/// The messages of that build, shown again when nothing changed (copied). May be null.
		public List<Diagnostic> Carried;
		/// The build tool runs at a lower priority (the build before debugging).
		public bool LowerPriority;
	}

	/// What Run needs built first.
	struct RunRequest
	{
		/// The build the program comes from.
		public BuildRequest Build;
	}

	/// A build running in the background (the language-neutral part of BuildRunner).
	abstract class BuildJob
	{
		/// The build tool's output lines, cleaned (shown in the Output Log).
		public List<String> Output = new .() ~ DeleteContainerAndItems!(_);
		/// Errors and warnings parsed from the output; `Origin` is `.Build`.
		public List<Diagnostic> Messages = new .() ~ DeleteContainerAndItems!(_);
		public bool Running;
		public bool Succeeded;
		public String Workspace = new .() ~ delete _;
		/// "Debug" / "Release".
		public String Config = new .() ~ delete _;
		/// The command as run (shown in the Output Log).
		public String CommandLine = new .() ~ delete _;
		/// The build tool runs at a lower priority (the build before debugging).
		public bool LowerPriority;
		/// Fingerprint of the build's inputs when it started (BuildInputs; 0: none taken).
		public uint64 Inputs;
		/// Content hash of the workspace sources when it started (the build indicator).
		public uint64 SourceHash;
		/// Nothing changed since the last successful build of this configuration: the build tool
		/// was not run, the output is the one already built.
		public bool UpToDate;
		/// The build tool could not be started (StartError says why).
		public bool StartFailed;
		public String StartError = new .() ~ delete _;
		/// Milliseconds the build took (from its start until its end was seen; 0 before it ended).
		public double BuildMs;
		/// The build was stopped by Cancel (Succeeded is false).
		public bool Cancelled;

		/// Milliseconds since the start (live while running, BuildMs after).
		public abstract double ElapsedMs { get; }
		/// Process id of the running build tool (0 when none).
		public abstract int ProcessId { get; }
		/// Call once per frame. Returns true when the build just finished.
		public abstract bool Update();
		/// Stops the build tool and everything it started. Update then reports the end (Cancelled
		/// set). Does nothing when no build is running.
		public abstract void Cancel();
	}
}
