using System;
using System.Collections;
using System.IO;
using Treadle.Document;
using Treadle.Model;

namespace Treadle.Editor
{
	/// Renaming a type (Type Settings > Name, Project Browser > Rename): the type's name is its file's
	/// name, so the file follows, and every reference to it in the project's other types follows: the
	/// namespace-qualified ones (`Zoo.Dog`) everywhere, the short ones (`Dog`) in types of the same namespace
	/// or that use it. The type's own document changes in one undo step; undoing it (or redoing it) renames
	/// the file and the references again (FollowTypeName).
	extension EditorApp
	{
		/// `text` with the type `ns.oldName` named `newName`: a dotted name whose leading parts are the
		/// namespace and the old name (`Zoo.Dog`, `Zoo.Dog.Speak()`), and with `bare` a name whose first part
		/// is the old name (`Dog`, `Dog.Legs`). Quoted text ("...") is copied as it is.
		public static void RewriteTypeRefs(StringView text, StringView ns, StringView oldName, StringView newName, bool bare, String outText)
		{
			List<StringView> nsParts = scope .();
			for (let p in ns.Split('.', .RemoveEmptyEntries))
				nsParts.Add(p);
			int i = 0;
			while (i < text.Length)
			{
				let c = text[i];
				if (c == '"')
				{
					int j = i + 1;
					while (j < text.Length && text[j] != '"' && text[j] != '\n')
						j += (text[j] == '\\' && j + 1 < text.Length) ? 2 : 1;
					j = Math.Min(j + 1, text.Length);
					outText.Append(text.Substring(i, j - i));
					i = j;
					continue;
				}
				if (c.IsLetterOrDigit || c == '_')
				{
					int j = i;
					while (j < text.Length && (text[j].IsLetterOrDigit || text[j] == '_' || (text[j] == '.' && j + 1 < text.Length && (text[j + 1].IsLetter || text[j + 1] == '_'))))
						j++;
					let token = text.Substring(i, j - i);
					List<StringView> parts = scope .();
					for (let p in token.Split('.'))
						parts.Add(p);
					int at = -1;
					if (!nsParts.IsEmpty && parts.Count > nsParts.Count)
					{
						bool same = true;
						for (int k < nsParts.Count)
							same &= parts[k] == nsParts[k];
						if (same && parts[nsParts.Count] == oldName)
							at = nsParts.Count;
					}
					if (at < 0 && bare && parts[0] == oldName)
						at = 0;
					if (at < 0)
						outText.Append(token);
					else
					{
						for (int k < parts.Count)
						{
							if (k > 0)
								outText.Append('.');
							outText.Append((k == at) ? newName : parts[k]);
						}
					}
					i = j;
					continue;
				}
				outText.Append(c);
				i++;
			}
		}

		/// Whether a type in namespace `docNs` that uses `uses` reaches `ns`'s types by their short names.
		static bool SeesNamespace(StringView docNs, List<String> uses, StringView ns)
		{
			if (docNs == ns)
				return true;
			for (let u in uses)
				if (u == ns)
					return true;
			return false;
		}

		/// Renames the type of `doc` to `newName`: one undo step in `doc`, then the file and the other
		/// types' references (FollowTypeName). False (with the reason in the status line) when the name is
		/// not a type name or is taken.
		public bool RenameType(TypeDocument doc, StringView newNameIn)
		{
			String newName = scope .(newNameIn);
			newName.Trim();
			if (doc == null || doc == mEmptyDoc || newName == doc.Header.Name || !CheckWritable())
				return false;
			String folder = scope .();
			if (!doc.FilePath.IsEmpty)
				Path.GetDirectoryPath(doc.FilePath, folder).IgnoreError();
			String err = scope .();
			bool caseOnly = StringView.Compare(newName, doc.Header.Name, true) == 0;
			if (!ValidateTypeName(folder, newName, doc.Header.Namespace, err) && !(caseOnly && !newName.IsEmpty))
			{
				SetStatus(scope $"Can't rename to '{newName}': {err}", .Warning);
				return false;
			}
			String oldName = scope .(doc.Header.Name);
			String ns = scope .(doc.Header.Namespace);
			String text = scope .();
			String why = scope .();
			if (!doc.WriteText(text, why))
			{
				SetStatus(scope $"Can't rename: {why}", .Warning);
				return false;
			}
			String renamed = scope .();
			RewriteTypeRefs(text, ns, oldName, newName, true, renamed);
			// LoadText keeps the layout and makes this one undo step; its Sheets are new objects, so the next
			// compile reads everything again.
			if (FrontEnd != null)
				FrontEnd.ForceFull = true;
			if (!doc.LoadText(renamed, why))
			{
				SetStatus(scope $"Can't rename: {why}", .Warning);
				return false;
			}
			doc.Header.Name.Set(newName);
			for (let s in doc.Sheets)
				if (s.IsBuilt)
					s.Graph.SelfType.Set(newName);
			FollowTypeName(doc, ns, oldName, newName);
			SetStatus(scope $"Renamed {oldName} to {newName}");
			return true;
		}

		/// After the type of `doc` went from `oldName` to its header's name (a rename, an undo, a redo):
		/// the file takes the name when it was named after the type, the project's other types name it
		/// anew, the project's entry follows, and the tabs, the type strip and the title show it.
		public void FollowTypeName(TypeDocument doc, StringView ns, StringView oldName, StringView newNameIn)
		{
			String newName = scope .(newNameIn);
			if (oldName == newName || newName.IsEmpty)
				return;
			// The file.
			String fileName = scope .();
			doc.GetName(fileName);
			if (!doc.FilePath.IsEmpty && fileName == oldName)
			{
				String dir = scope .();
				Path.GetDirectoryPath(doc.FilePath, dir).IgnoreError();
				String newPath = scope $"{dir}{Path.DirectorySeparatorChar}{newName}{GraphExtension}";
				bool caseOnly = StringView.Compare(oldName, newName, true) == 0;
				if (!caseOnly && File.Exists(newPath))
					SetStatus(scope $"The type is named {newName}, its file keeps its name: {newName}{GraphExtension} exists", .Warning);
				else
				{
					String oldPath = scope .(doc.FilePath);
					bool moved = true;
					if (File.Exists(oldPath))
					{
						String oldLayout = scope .();
						TypeDocument.LayoutPathOf(oldPath, oldLayout);
						moved = !(File.Move(oldPath, newPath) case .Err);
						if (moved && File.Exists(oldLayout))
						{
							String newLayout = scope .();
							TypeDocument.LayoutPathOf(newPath, newLayout);
							File.Move(oldLayout, newLayout).IgnoreError();
						}
					}
					if (moved)
						RemapDocPaths(oldPath, newPath, false);
					else
						SetStatus(scope $"Could not rename {oldPath}", .Warning);
				}
			}
			// The other types' references, open ones in memory (unsaved, an undo step each), the rest on disk.
			if (FrontEnd != null)
				FrontEnd.ForceFull = true;
			String oldFull = scope .();
			String newFull = scope .();
			if (!ns.IsEmpty)
			{
				oldFull.AppendF("{}.", ns);
				newFull.AppendF("{}.", ns);
			}
			oldFull.Append(oldName);
			newFull.Append(newName);
			int changed = 0;
			for (let other in mDocs)
			{
				if (other == doc || other == mEmptyDoc)
					continue;
				String text = scope .();
				if (!other.WriteText(text, null))
					continue;
				String renamed = scope .();
				RewriteTypeRefs(text, ns, oldName, newName, SeesNamespace(other.Header.Namespace, other.Header.Uses, ns), renamed);
				if (renamed != text && other.LoadText(renamed, null))
					changed++;
			}
			for (let f in Index.Files)
			{
				if (FindDoc(f.Path) != null || ProjectIndex.SamePath(f.Path, doc.FilePath))
					continue;
				String text = scope .();
				if (File.ReadAllText(f.Path, text, true) case .Err)
					continue;
				// The namespace and uses lines of the file decide whether short names are rewritten.
				TypeDocument probe = scope .(Language);
				probe.FilePath.Set(f.Path);
				bool bare = probe.LoadText(text, null) && SeesNamespace(probe.Header.Namespace, probe.Header.Uses, ns);
				String renamed = scope .();
				RewriteTypeRefs(text, ns, oldName, newName, bare, renamed);
				if (renamed != text && !(File.WriteAllText(f.Path, renamed) case .Err))
					changed++;
			}
			// The project's entry type.
			if (Project != null && Project.Entry != null && Project.Entry.ToString(.. scope String()) == oldFull)
			{
				delete Project.Entry;
				Project.Entry = TypeRef.Parse(newFull);
				SaveProjectFile();
			}
			if (changed > 0)
				Notify.Log(.Info, "Editor", scope $"{oldFull} is now {newFull}: {changed} other type(s) name it anew");
			ScanProject();
			UpdateTitle();
			doc.Version++;
		}

		/// Undo / Redo of the document in front, following a type name the step changed.
		public void UndoDoc(bool redo)
		{
			let doc = EditDoc;
			if (doc == null)
				return;
			String ns = scope .(doc.Header.Namespace);
			String name = scope .(doc.Header.Name);
			if (redo)
				doc.Redo();
			else
				doc.Undo();
			if (doc.Header.Name != name && doc.Header.Namespace == ns)
			{
				for (let s in doc.Sheets)
					if (s.IsBuilt)
						s.Graph.SelfType.Set(doc.Header.Name);
				FollowTypeName(doc, ns, name, doc.Header.Name);
			}
		}
	}
}
