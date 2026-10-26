using System;
using System.Collections;
using Treadle.Document;
using Treadle.Backend.IR;
using Treadle.Backend.Driver;

namespace Treadle.Editor
{
	/// The front end as the back end's program source: Build lowers the saved project to the
	/// Sheet IR text (Treadle.Compiler.FrontEndBuild) and reads it into the IRProgram the driver
	/// emits. Installed on
	/// BackendToolchain.FrontEnd by EditorApp.
	class FrontEndProgramSource : IProgramSource
	{
		/// How long the last Lower took (the scale measurements read it).
		public static double LastLowerMs;

		public bool Lower(StringView workspace, StringView config, IRProgram outProgram, List<Diagnostic> outMessages)
		{
			let watch = scope System.Diagnostics.Stopwatch(true);
			defer { LastLowerMs = watch.Elapsed.TotalMilliseconds; }
			String text = scope .();
			if (!Treadle.Compiler.FrontEndBuild.WriteProgram(workspace, config, text, outMessages, outProgram.LinkInputs, outProgram.RunFiles, outProgram.InputStamps))
				return false;
			List<String> errors = scope .();
			defer { ClearAndDeleteItems!(errors); }
			if (IRReader.Read(text, outProgram, errors))
				return true;
			for (let e in errors)
			{
				Diagnostic d = new .();
				d.Severity = .Error;
				d.Origin = .Build;
				d.Text.AppendF("the Sheet IR does not read (a compiler bug): {}", e);
				outMessages.Add(d);
			}
			return false;
		}
	}
}
