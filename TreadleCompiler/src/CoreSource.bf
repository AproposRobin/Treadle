using System;
using System.Collections;
using System.IO;
using Treadle.Model;
using Treadle.Document;
using Treadle.Format;

namespace Treadle.Compiler
{
	/// The core library (docs/Core-Library.md): the type files of `TreadleCore/core` and its C
	/// import set `crt` (crt.cimport + crt.cdecl). Every compilation reads it before the project.
	/// Where it comes from: `TREADLE_CORE` (a folder), else `core` next to the running exe (a package), else
	/// `TreadleCore/core` above it (a source tree), else the copy compiled into this library. The documents are read once and
	/// shared by every compilation (they are only read; the front end runs one compilation at a
	/// time, FrontEndBuild.Lock), and read again when a file on disk changes.
	static class CoreSource
	{
		/// The type files of the core, in load order (Object first). The embedded copy holds these;
		/// a folder on disk is scanned instead, so a new file works there before it is listed.
		public static StringView[?] Files = .("Object.treadle", "Attribute.treadle", "String.treadle", "StringView.treadle", "Span.treadle",
			"Result.treadle", "Option.treadle", "Console.treadle", "Math.treadle", "Memory.treadle", "Pointer.treadle", "Hash.treadle", "Runtime.treadle",
			"IDisposable.treadle", "IHashable.treadle", "IEquatable.treadle", "IComparable.treadle", "IAllocator.treadle", "Atomic.treadle",
			"List.treadle", "ListEnumerator.treadle", "Dictionary.treadle", "DictionaryEnumerator.treadle", "Arrays.treadle", "Random.treadle",
			"Time.treadle", "Stopwatch.treadle", "Environment.treadle", "DictionaryKeys.treadle", "DictionaryValues.treadle", "HashSet.treadle",
			"Queue.treadle", "Stack.treadle", "File.treadle", "Path.treadle", "Directory.treadle", "Event.treadle",
			"ParseError.treadle", "Int.treadle", "Double.treadle", "Float.treadle", "Bool.treadle", "FloatStyle.treadle",
			"CodePointEnumerator.treadle", "Utf8.treadle", "Build.treadle", "Sorting.treadle",
			"ProcessError.treadle", "ProcessHandle.treadle", "Process.treadle", "DateTime.treadle",
			"Thread.treadle", "Mutex.treadle", "LockGuard.treadle", "Condition.treadle", "WaitEvent.treadle", "ThreadLocal.treadle",
			"ThreadPool.treadle", "Parallel.treadle",
			// the math library (SIMD-and-Vectors.md 2)
			"Vec2.treadle", "Vec3.treadle", "Vec4.treadle", "Vec2d.treadle", "Vec3d.treadle", "Vec4d.treadle", "Mat3.treadle", "Mat4.treadle",
			"Quat.treadle", "Color.treadle", "Color32.treadle", "Rect.treadle", "RectI.treadle", "AABB.treadle", "Plane.treadle", "Ray.treadle",
			"Transform.treadle", "MathFormat.treadle", "VectorFormat.treadle",
			// GPU compute (experimental, NVIDIA only, GPU-Compute.md)
			"Kernel.treadle", "GpuBuffer.treadle", "Gpu.treadle", "GpuStream.treadle", "PinnedBuffer.treadle");

		[Comptime(ConstEval=true)]
		static String Embed(String name)
		{
			String path = scope .();
			path.AppendF("{}/../TreadleCore/core/{}", Compiler.ProjectDir, name);
			String data = scope .();
			if (File.ReadAllText(path, data) case .Err)
				return "";
			return data;
		}

		[Comptime(ConstEval=true)]
		static String EmbedAll()
		{
			// One text: `\x01<name>\x02<text>` per file.
			String all = scope .();
			for (let f in Files)
			{
				String path = scope .();
				path.AppendF("{}/../TreadleCore/core/{}", Compiler.ProjectDir, f);
				String data = scope .();
				if (File.ReadAllText(path, data) case .Err)
					continue;
				all.AppendF("\x01{}\x02{}", f, data);
			}
			return all;
		}

		public const String EmbeddedTypes = EmbedAll();
		public const String EmbeddedCImport = Embed("crt.cimport");
		public const String EmbeddedCDecl = Embed("crt.cdecl");

		public class Unit
		{
			public String Name = new .() ~ delete _;
			public String Path = new .() ~ delete _;
			public TypeDocument Doc ~ delete _;
			public String Error ~ delete _;
		}

		static List<Unit> sUnits = new .() ~ DeleteContainerAndItems!(_);
		static CImportFile sCImport ~ delete _;
		static TypeDocument sCDecl ~ delete _;
		static String sCDeclPath = new .() ~ delete _;
		static String sCImportError ~ delete _;
		static String sFrom = new .() ~ delete _;
		/// The stamp of what was read (the folder's file names, sizes and times; "built in").
		static String sStamp = new .() ~ delete _;

		/// Where the core was read from: a folder, or "built in".
		public static StringView From => sFrom;

		/// The core folder on disk ("" when the built-in copy is used).
		public static void FindFolder(String outDir)
		{
			String dir = scope .();
			if (Environment.GetEnvironmentVariable("TREADLE_CORE", dir) case .Ok && File.Exists(scope $"{dir}/Object.treadle"))
			{
				outDir.Set(dir);
				return;
			}
			// A package (docs/Releasing.md) ships the core as `core` next to the exe; a development build
			// reads its source tree's TreadleCore/core (Treadle.Language.ToolDirs: no parent folder walk).
			String exeDir = scope .();
			Treadle.Language.ToolDirs.ExeDir(exeDir);
			if (File.Exists(scope $"{exeDir}/core/Object.treadle"))
			{
				outDir.Set(scope $"{exeDir}/core");
				return;
			}
			String tree = scope .();
			if (Treadle.Language.ToolDirs.DevTree(tree) && File.Exists(scope $"{tree}/TreadleCore/core/Object.treadle"))
				outDir.Set(scope $"{tree}/TreadleCore/core");
		}

		static void Stamp(StringView dir, String outStamp)
		{
			List<String> names = scope .();
			defer { ClearAndDeleteItems!(names); }
			for (let e in Directory.EnumerateFiles(dir))
			{
				let p = e.GetFilePath(.. scope String());
				if (!FormatNames.IsTypeFile(p) && !p.EndsWith(".cdecl", .OrdinalIgnoreCase) && !p.EndsWith(".cimport", .OrdinalIgnoreCase))
					continue;
				String line = new .();
				line.AppendF("{}|{}|{}", p, e.GetFileSize(), e.GetLastWriteTimeUtc().Ticks);
				names.Add(line);
			}
			names.Sort(scope (a, b) => a.CompareTo(b));
			for (let n in names)
				outStamp.AppendF("{};", n);
		}

		static TypeDocument Parse(StringView text, StringView path, String outError)
		{
			TypeDocument doc = new .();
			doc.FilePath.Set(path);
			List<FormatError> errors = scope .();
			defer { ClearAndDeleteItems!(errors); }
			if (TreadleCodec.ReadAll(text, doc, errors))
				return doc;
			TreadleCodec.JoinErrors(errors, outError);
			delete doc;
			return null;
		}

		/// Reads the core (again when its folder changed). Call with FrontEndBuild.Lock held or from
		/// the thread that compiles.
		public static void Load()
		{
			String dir = scope .();
			FindFolder(dir);
			String stamp = scope .();
			if (dir.IsEmpty)
				stamp.Set("built in");
			else
				Stamp(dir, stamp);
			if (stamp == sStamp && !sUnits.IsEmpty)
				return;
			sStamp.Set(stamp);
			ClearAndDeleteItems!(sUnits);
			DeleteAndNullify!(sCImport);
			DeleteAndNullify!(sCDecl);
			DeleteAndNullify!(sCImportError);
			sCDeclPath.Clear();
			String cimportText = scope .();
			String cdeclText = scope .();
			List<(String name, String text)> files = scope .();
			defer { for (let f in files) { delete f.name; delete f.text; } }
			if (dir.IsEmpty)
			{
				sFrom.Set("built in");
				for (var part in EmbeddedTypes.Split('\x01', .RemoveEmptyEntries))
				{
					let sep = part.IndexOf('\x02');
					if (sep < 0)
						continue;
					files.Add((new String(part.Substring(0, sep)), new String(part.Substring(sep + 1))));
				}
				cimportText.Set(EmbeddedCImport);
				cdeclText.Set(EmbeddedCDecl);
				sCDeclPath.Set("<core>/crt.cdecl");
			}
			else
			{
				sFrom.Set(dir);
				// The listed files first in their order, then any other type file of the folder.
				List<String> names = scope .();
				defer { ClearAndDeleteItems!(names); }
				for (let f in Files)
					if (File.Exists(scope $"{dir}/{f}"))
						names.Add(new String(f));
				List<String> more = scope .();
				defer { ClearAndDeleteItems!(more); }
				for (let e in Directory.EnumerateFiles(dir))
				{
					let n = e.GetFileName(.. scope String());
					if (!FormatNames.IsTypeFile(n))
						continue;
					bool listed = false;
					for (let f in Files)
						listed |= StringView.Compare(f, n, true) == 0;
					if (!listed)
						more.Add(new String(n));
				}
				more.Sort(scope (a, b) => a.CompareTo(b));
				for (let n in more)
					names.Add(new String(n));
				for (let n in names)
				{
					String text = new .();
					if (File.ReadAllText(scope $"{dir}/{n}", text, true) case .Err)
						text.Clear();
					files.Add((new String(n), text));
				}
				File.ReadAllText(scope $"{dir}/crt.cimport", cimportText, true).IgnoreError();
				File.ReadAllText(scope $"{dir}/crt.cdecl", cdeclText, true).IgnoreError();
				sCDeclPath.AppendF("{}/crt.cdecl", dir);
			}
			for (let f in files)
			{
				Unit u = new .();
				u.Name.Set(f.name);
				if (dir.IsEmpty)
					u.Path.AppendF("<core>/{}", f.name);
				else
					u.Path.AppendF("{}/{}", dir, f.name);
				String why = scope .();
				u.Doc = Parse(f.text, u.Path, why);
				if (u.Doc == null)
					u.Error = new String(why);
				sUnits.Add(u);
			}
			CImportFile cf = new .();
			List<FormatError> errors = scope .();
			defer { ClearAndDeleteItems!(errors); }
			if (ProjectCodec.ReadCImport(cimportText, cf, errors) && !cf.Sets.IsEmpty)
				sCImport = cf;
			else
			{
				delete cf;
				sCImportError = new String("crt.cimport does not read");
			}
			String why = scope .();
			sCDecl = Parse(cdeclText, sCDeclPath, why);
			if (sCDecl == null && sCImportError == null)
				sCImportError = new String(scope $"crt.cdecl does not read: {why}");
		}

		/// Whether the copy compiled into this library is the folder's: every listed file the same
		/// text (line endings aside), every type file of the folder listed. `outWhy` names the first
		/// difference.
		public static bool EmbeddedMatches(StringView dir, String outWhy)
		{
			Dictionary<String, String> embedded = scope .();
			defer { for (let kv in embedded) { delete kv.key; delete kv.value; } }
			for (var part in EmbeddedTypes.Split('\x01', .RemoveEmptyEntries))
			{
				let sep = part.IndexOf('\x02');
				if (sep < 0)
					continue;
				String text = new .(part.Substring(sep + 1));
				text.Replace("\r", "");
				embedded[new String(part.Substring(0, sep))] = text;
			}
			for (let e in Directory.EnumerateFiles(dir))
			{
				let n = e.GetFileName(.. scope String());
				if (!FormatNames.IsTypeFile(n))
					continue;
				String text = scope .();
				File.ReadAllText(scope $"{dir}/{n}", text, true).IgnoreError();
				text.Replace("\r", "");
				if (!embedded.TryGetValueAlt(n, let have))
				{
					outWhy.AppendF("{} is not in CoreSource.Files", n);
					return false;
				}
				if (have != text)
				{
					outWhy.AppendF("{} differs from the built-in copy (rebuild)", n);
					return false;
				}
			}
			for (let f in Files)
				if (!File.Exists(scope $"{dir}/{f}"))
				{
					outWhy.AppendF("{} is listed but not in the folder", f);
					return false;
				}
			for (int k < 2)
			{
				StringView name = (k == 0) ? "crt.cimport" : "crt.cdecl";
				String disk = scope .();
				File.ReadAllText(scope $"{dir}/{name}", disk, true).IgnoreError();
				disk.Replace("\r", "");
				String built = scope .((k == 0) ? EmbeddedCImport : EmbeddedCDecl);
				built.Replace("\r", "");
				if (disk != built)
				{
					outWhy.AppendF("{} differs from the built-in copy (rebuild)", name);
					return false;
				}
			}
			return true;
		}

		public static List<Unit> Units => sUnits;
		public static CImportSet CSet => (sCImport != null) ? sCImport.Sets[0] : null;
		public static TypeDocument CDecl => sCDecl;
		public static StringView CDeclPath => sCDeclPath;
		public static StringView CError => (sCImportError != null) ? (StringView)sCImportError : "";
		/// What the core was read from: "built in", or its folder's file names, sizes and times (Load).
		public static StringView CurrentStamp => sStamp;
	}
}
