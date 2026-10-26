// Developer self tests: compiled only with the TREADLE_SELFTEST define (Debug and Release; not the
// ReleasePackage configuration the packages are built from, docs/Releasing.md).
#if TREADLE_SELFTEST
using System;
using System.Collections;
using System.IO;
using Treadle.Debug;
using Treadle.Document;
using Treadle.Graph;

namespace Treadle.Editor
{
	/// The `debug` self test, vectors part (docs/Debugging.md, "Variables"): the core fixture struct-literal
	/// (a float4 local set from `1,2,3,4`, a Vec3 local from the struct literal `1,2.25,-0.5`) copied as a
	/// project, a breakpoint on its first WriteLine (a8), F5: Locals shows `v` as `float4(1, 2, 3, 4)` and `p`
	/// as `Vec3(1, 2.25, -0.5)`, and `p` still expands to X, Y, Z.
	extension EditorApp
	{
		const int cDbgVectors = 45;
#if BF_PLATFORM_WINDOWS
		const String VectorsProgramFile = "Vectors\\struct-literal.treadle";
#else
		const String VectorsProgramFile = "Vectors/struct-literal.treadle";
#endif

		bool SelfTestDebugVectors()
		{
			switch (mSelfTestStep)
			{
			case cDbgVectors:
				{
					String samples = scope .();
					String fixtures = scope .();
					if (!FindSamples(samples) || !FindFixtures(samples, fixtures))
					{
						Notify.Log(.Info, "SelfTest", "[SELFTEST] debug: the vectors part is skipped (no fixtures folder: a package run)");
						mSelfTestStep = cDbgCleanup - 1;
						return false;
					}
					String dir = scope $"{mDbgDir}{DbgSep}Vectors";
					Directory.CreateDirectory(dir).IgnoreError();
					File.Copy(scope $"{fixtures}/core/struct-literal.treadle", scope $"{dir}{DbgSep}struct-literal.treadle").IgnoreError();
					File.WriteAllText(scope $"{dir}{DbgSep}Vectors.tproj",
						"# tproj 1\nproject Vectors\n\tkind console\n\tentry Cx.StructLiteralMain\n\tversion 0.1.0\nconfig Debug\n\tchecks on\n\toptimize 0\nconfig Release\n\toptimize 2\n\tchecks off\n").IgnoreError();
					OpenProjectNow(dir, scope $"{dir}{DbgSep}struct-literal.treadle", true);
					mSelfTestWait = 3;
					mDbgWatch.Restart();
				}
				return false;
			case cDbgVectors + 1:
				{
					let doc = FindDoc(scope $"{mDbgDir}{DbgSep}{VectorsProgramFile}") ?? OpenFile(scope $"{mDbgDir}{DbgSep}{VectorsProgramFile}", false);
					let sheet = doc?.FindSheetByName("Main");
					if (sheet == null || sheet.Graph.FindNodeByKey("a8") == null)
					{
						SelfTestCheck(false, "debug: node a8 of struct-literal's Main was not found");
						return DbgAbort();
					}
					Debug.ClearBreakpoints();
					Debug.AddBreakpoint(doc.FilePath, sheet.Key, "a8");
					mDbgLaunchBase = DebugLaunches;
					StartDebugging();
					SelfTestCheck(mBuild != null && mBuild.Running, "debug: F5 builds struct-literal in Debug");
					mDbgWatch.Restart();
				}
				return false;
			case cDbgVectors + 2:
				{
					if (!DbgWaitLaunch("the stop on a8 of struct-literal"))
						return false;
					if (Debug.IsStopped && !DbgCaptureHold("debug-vectors", true))
						return false;
					let f = Debug.CurrentFrame;
					SelfTestCheck(Debug.IsStopped && f != null && f.NodeKey == "a8",
						scope $"debug: struct-literal stopped on a8 ({Debug.Reason}, {(f != null) ? f.NodeKey : ""})");
					if (!Debug.IsStopped)
						return DbgAbort();
					DebugVariable v = null;
					DebugVariable p = null;
					DebugVariable c = null;
					for (let l in Debug.Locals)
					{
						Notify.Log(.Info, "SelfTest", scope $"[SELFTEST]      local {l.Name}: {l.Type} = {l.Value}");
						if (l.Name == "v")
							v = l;
						else if (l.Name == "p")
							p = l;
						else if (l.Name == "c")
							c = l;
					}
					SelfTestCheck(v != null && v.Value == "float4(1, 2, 3, 4)" && v.Type == "float4",
						scope $"debug: a float4 local reads float4(1, 2, 3, 4), its type float4 ({(v != null) ? v.Type : "missing"}: {(v != null) ? v.Value : ""})");
					SelfTestCheck(p != null && p.Value == "Vec3(1, 2.25, -0.5)" && p.ChildrenRef != 0,
						scope $"debug: a Vec3 local reads Vec3(1, 2.25, -0.5) and expands ({(p != null) ? p.Type : "missing"}: {(p != null) ? p.Value : ""})");
					SelfTestCheck(c != null && c.Value == "Color32(255, 128, 0, 255)",
						scope $"debug: a Color32 local reads its bytes as numbers, Color32(255, 128, 0, 255) ({(c != null) ? c.Value : "missing"})");
					Debug.Stop();
					mSelfTestWait = 10;
					mSelfTestStep = cDbgCleanup - 1;
				}
				return false;
			default:
				mSelfTestStep = cDbgCleanup - 1;
				return false;
			}
		}
	}
}
#endif
