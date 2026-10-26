using System;
using System.Collections;
using System.IO;
using ImGui;
using Treadle.Document;
using Treadle.Model;

namespace Treadle.Editor
{
	/// Type files in the editor: the namespace a new type proposes (Project Browser > + Add > New Class...), Save As,
	/// and the project file of the open folder.
	extension EditorApp
	{
		bool mOpenSaveAs;
		/// The project file of the open folder (`*.tproj` at its root), null when there is none.
		public ProjectFile Project ~ delete _;

		/// The namespace a new type in `folder` defaults to (Language.md 1: folders do not define
		/// namespaces, they only suggest one): the project's root namespace (the project file's
		/// `namespace`; a project file without one gets it, the project's name made an identifier),
		/// then the folder's path under the source folder that holds it, with dots: `Source` gives
		/// `Zoo`, `Source/Animals` gives `Zoo.Animals`. Without a project file, the folder's path under
		/// the project root.
		public void NamespaceFor(StringView folder, String outNs)
		{
			if (mProjectRoot.IsEmpty || !folder.StartsWith(mProjectRoot, .OrdinalIgnoreCase))
				return;
			var rel = folder.Substring(mProjectRoot.Length);
			rel.TrimStart();
			while (rel.StartsWith('/') || rel.StartsWith('\\'))
				rel = rel.Substring(1);
			if (Project != null)
			{
				if (Project.Namespace.IsEmpty)
				{
					IdentifierOf(Project.Name, Project.Namespace);
					if (!ProjectPath.IsEmpty && SaveProjectFile())
						Notify.Log(.Info, "Editor", scope $"The project file now names the root namespace {Project.Namespace} (Properties of the project to change it)");
				}
				outNs.Append(Project.Namespace);
				// The part of the path under the source folder that holds the folder.
				for (let src in Project.Sources)
				{
					String s = scope .(src);
					s.Replace('\\', '/');
					while (s.EndsWith('/'))
						s.RemoveFromEnd(1);
					if (s.IsEmpty || s == ".")
						continue;
					String r = scope .(rel);
					r.Replace('\\', '/');
					if (r.StartsWith(s, .OrdinalIgnoreCase) && (r.Length == s.Length || r[s.Length] == '/'))
					{
						rel = rel.Substring(s.Length);
						while (rel.StartsWith('/') || rel.StartsWith('\\'))
							rel = rel.Substring(1);
						break;
					}
				}
			}
			for (let part in rel.Split('/', '\\'))
			{
				if (part.IsEmpty)
					continue;
				if (!outNs.IsEmpty)
					outNs.Append('.');
				for (let c in part.RawChars)
					outNs.Append((c.IsLetterOrDigit || c == '_') ? c : '_');
			}
		}

		/// Reads the folder's `.tproj`, if any (nothing consumes it yet beyond the log line).
		void LoadProjectFile()
		{
			DeleteAndNullify!(Project);
			ProjectPath.Clear();
			if (mProjectRoot.IsEmpty || !Directory.Exists(mProjectRoot))
				return;
			for (let pattern in Treadle.Format.FormatNames.ProjectPatterns)
			for (let e in Directory.EnumerateFiles(mProjectRoot, pattern))
			{
				String path = scope .();
				e.GetFilePath(path);
				String text = scope .();
				if (File.ReadAllText(path, text, true) case .Err)
					continue;
				let p = new ProjectFile();
				List<Treadle.Format.FormatError> errors = scope .();
				defer { ClearAndDeleteItems!(errors); }
				if (Treadle.Format.ProjectCodec.ReadProject(text, p, errors))
				{
					Project = p;
					ProjectPath.Set(path);
					Notify.Log(.Info, "Editor", scope $"Project {p.Name} ({(p.Kind.IsEmpty ? "console" : (StringView)p.Kind)}), {p.Sources.Count} source folder(s)");
				}
				else
				{
					String why = scope .();
					Treadle.Format.TreadleCodec.JoinErrors(errors, why);
					Notify.Log(.Warning, "Editor", scope $"{path}: {why}");
					delete p;
				}
				return;
			}
		}

		/// File > Save As: asks for a file name in the document's folder.
		public void StartSaveAs()
		{
			if (Doc == null || Doc == mEmptyDoc || !CheckWritable())
				return;
			String name = scope .();
			Doc.GetName(name);
			mNameBuf.Set(name);
			mOpenSaveAs = true;
		}

		void DrawSaveAsPopup()
		{
			if (mOpenSaveAs)
			{
				mOpenSaveAs = false;
				Gui.OpenPopup("Save As");
			}
			String folder = scope .();
			if (Doc != null && !Doc.FilePath.IsEmpty)
				Path.GetDirectoryPath(Doc.FilePath, folder).IgnoreError();
			else
				folder.Set(mCBFolder.IsEmpty ? (StringView)mProjectRoot : (StringView)mCBFolder);
			String name = scope .();
			if (!NamePopup("Save As", scope $"Save the type as (in {folder}):", name))
				return;
			if (name.EndsWith(GraphExtension, .OrdinalIgnoreCase))
				name.RemoveFromEnd(GraphExtension.Length);
			String path = scope .();
			if (name.Contains('/') || name.Contains('\\'))
				path.AppendF("{}{}", name, GraphExtension);
			else
				path.AppendF("{}{}{}{}", folder, Path.DirectorySeparatorChar, name, GraphExtension);
			SaveAs(path);
		}

		/// Writes the document under a new path (the type keeps its name unless it was named after
		/// its old file, or untitled).
		public bool SaveAs(StringView path)
		{
			if (File.Exists(path))
			{
				SetStatus(scope $"Not saved: {path} exists already", .Warning);
				return false;
			}
			String oldName = scope .();
			Doc.GetName(oldName);
			String newName = scope .();
			Path.GetFileNameWithoutExtension(path, newName);
			if (Doc.Header.Name.IsEmpty || Doc.Header.Name == oldName || Doc.FilePath.IsEmpty)
			{
				Doc.Header.Name.Set(newName);
				for (let s in Doc.Sheets)
					if (s.IsBuilt)
						s.Graph.SelfType.Set(newName);
			}
			String oldPath = scope .(Doc.FilePath);
			Doc.FilePath.Set(path);
			Doc.Modified = true;
			if (!SaveDoc(Doc, true))
			{
				Doc.FilePath.Set(oldPath);
				return false;
			}
			if (mProjectRoot.IsEmpty)
			{
				String dir = scope .();
				Path.GetDirectoryPath(path, dir).IgnoreError();
				mProjectRoot.Set(dir);
			}
			ScanProject();
			SetStatus(scope $"Saved {path}");
			UpdateTitle();
			return true;
		}
	}
}
