using System;
using System.Collections;
using Treadle.Document;
using Treadle.Graph;

namespace Treadle.Language
{
	/// The toolchain the shell runs with until the language installs its own: Validate runs the
	/// graph checks (Level 1) and nothing else; Build and Run say that no build tool is installed.
	class NullToolchain : IToolchain
	{
		public const String NoTool = "No build tool is installed in this build.";

		public bool CanValidate => false;
		public bool SyntaxBusy => false;

		public ValidateJob Validate(in ValidateRequest request)
		{
			let sw = scope System.Diagnostics.Stopwatch(true);
			ValidateJob job = new .();
			if (request.Sheets != null)
			{
				for (let sheet in request.Sheets)
				{
					let g = sheet.Graph;
					GraphValidator.Validate(g);
					for (let e in g.Errors)
						job.Messages.Add(Message(sheet, e, .Error));
					for (let w in g.Warnings)
						job.Messages.Add(Message(sheet, w, .Warning));
					job.Sheets++;
				}
			}
			job.Ms = sw.Elapsed.TotalMilliseconds;
			if (!request.Workspace.IsEmpty)
				job.Note.Set("The language's own checks are not installed in this build.");
			return job;
		}

		static Diagnostic Message(Sheet sheet, GraphError e, DiagnosticSeverity severity)
		{
			Diagnostic d = new .();
			d.Severity = severity;
			d.Origin = .Validate;
			d.Text.Set(e.Message);
			d.Path.Set(sheet.Doc.FilePath);
			d.MethodKey.Set(sheet.Key);
			d.Where.Set(sheet.Name);
			let node = sheet.Graph.FindNode(e.NodeId);
			if (node != null)
			{
				d.NodeKey.Append(node.Key);
				if (e.PinName != null)
					d.PinName.Set(e.PinName);
				d.NodeId = node.Id;
				d.ResolvedSerial = sheet.Graph.Serial;
			}
			return d;
		}

		public SyntaxJob CheckSyntax(in SyntaxRequest request) => null;

		public Result<BuildJob> Build(in BuildRequest request) => .Err;

		public Result<BuildJob> Run(in RunRequest request) => .Err;

		public void Update(double now, List<String> outLog) { }
	}
}
