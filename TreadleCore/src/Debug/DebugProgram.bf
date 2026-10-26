using System;
using System.Collections;
using System.IO;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Language;
using Treadle.Model;

namespace Treadle.Debug
{
	/// A node of a built program as the debugger sees it: its listing line and whether a step
	/// stops on it (flow nodes; value nodes are evaluated inside the flow node that reads them).
	class DebugNodeInfo
	{
		public String Key = new .() ~ delete _;
		/// The node's kind and subject as the Sheet shows them ("Call Zoo.Animal.Speak()").
		public String Title = new .() ~ delete _;
		public bool Flow = true;
		/// Value nodes: the one flow node that reads the value (directly or through other value nodes),
		/// "" when several do. A stop on the value node's code is a stop before that flow node runs.
		public String Consumer = new .() ~ delete _;
		public int32 Line;
	}

	/// One Sheet of a unit: its key (`m0001`, `get:p0002`, ...), the name a stack frame shows and
	/// which debug-info names are the function's local variables.
	class DebugSheetInfo
	{
		public String Key = new .() ~ delete _;
		/// `Zoo.Program.Main`.
		public String Name = new .() ~ delete _;
		public Dictionary<String, DebugNodeInfo> Nodes = new .() ~ DeleteDictionaryAndValues!(_);
		/// The names of the Sheet's variables (its locals and the parameters a Set writes): the debug
		/// info names their slots after them (Compiler.md 4, the slot record).
		public HashSet<String> LocalNames = new .() ~ DeleteContainerAndItems!(_);

		public DebugNodeInfo FindNode(StringView key)
		{
			if (Nodes.TryGetAlt(key, ?, let n))
				return n;
			return null;
		}
	}

	/// One unit of the program: a type file, its listing (`<Unit>.lst`) and node map.
	class DebugUnitInfo
	{
		public String Name = new .() ~ delete _;
		/// The type file ("" for units the project has no file for, such as the core library's).
		public String Path = new .() ~ delete _;
		public TypeKind Kind;
		public Dictionary<String, DebugSheetInfo> Sheets = new .() ~ DeleteDictionaryAndValues!(_);
		/// Listing line -> (Sheet key, node id).
		public Dictionary<int32, (String sheet, String node)> ByLine = new .() ~ { for (let v in _.Values) { delete v.sheet; delete v.node; } delete _; };

		public DebugSheetInfo FindSheet(StringView key)
		{
			if (Sheets.TryGetAlt(key, ?, let s))
				return s;
			return null;
		}
	}

	/// What the debugger knows about a built program (docs/Compiler.md section 7, docs/Debugging.md):
	/// the project's type files (unit name <-> file), each unit's `.nodemap` (Sheet, node <-> listing
	/// line), which nodes are flow nodes and the names of each Sheet's local variables. Made
	/// on the UI thread before a launch and not changed afterwards, so an adapter's thread can read
	/// it.
	class DebugProgram
	{
		public String Workspace = new .() ~ delete _;
		/// `<project>/build/<Config>`: the exe, the listings and the node maps.
		public String BuildDir = new .() ~ delete _;
		public String ExePath = new .() ~ delete _;
		public Dictionary<String, DebugUnitInfo> Units = new .() ~ DeleteDictionaryAndValues!(_);
		/// Problems met while reading (files that did not read); for the log.
		public List<String> Notes = new .() ~ DeleteContainerAndItems!(_);

		public DebugUnitInfo FindUnit(StringView name)
		{
			if (Units.TryGetAlt(name, ?, let u))
				return u;
			return null;
		}

		DebugUnitInfo GetUnit(StringView name)
		{
			var u = FindUnit(name);
			if (u == null)
			{
				u = new .();
				u.Name.Set(name);
				Units[u.Name] = u;
			}
			return u;
		}

		/// The unit of a type file ("" when none).
		public bool UnitOfPath(StringView path, String outUnit)
		{
			for (let u in Units.Values)
				if (!u.Path.IsEmpty && ProjectIndex.SamePath(u.Path, path))
				{
					outUnit.Set(u.Name);
					return true;
				}
			return false;
		}

		/// The unit of a listing file (`.../Zoo.Program.lst` -> `Zoo.Program`).
		public static void UnitOfListing(StringView listingPath, String outUnit)
		{
			String name = scope .();
			Path.GetFileName(listingPath, name);
			if (name.EndsWith(".lst", .OrdinalIgnoreCase))
				name.RemoveFromEnd(4);
			outUnit.Set(name);
		}

		/// The listing line of a node (0 when the build has none: a node that lowered to nothing).
		public int32 LineOf(StringView unit, StringView sheet, StringView node)
		{
			let u = FindUnit(unit);
			if (u == null)
				return 0;
			let s = u.FindSheet(sheet);
			if (s == null)
				return 0;
			let n = s.FindNode(node);
			return (n != null) ? n.Line : 0;
		}

		/// The Sheet and node of a listing line.
		public bool NodeAt(StringView unit, int32 line, String outSheet, String outNode)
		{
			let u = FindUnit(unit);
			if (u == null)
				return false;
			if (!u.ByLine.TryGetValue(line, let at))
				return false;
			outSheet.Set(at.sheet);
			outNode.Set(at.node);
			return true;
		}

		public DebugNodeInfo FindNode(StringView unit, StringView sheet, StringView node)
		{
			let u = FindUnit(unit);
			let s = u?.FindSheet(sheet);
			return s?.FindNode(node);
		}

		/// A class type of the project (a reference: the debug info shows it as a pointer).
		public bool IsClass(StringView typeName)
		{
			var name = typeName;
			let lt = name.IndexOf('<');
			if (lt > 0)
				name = name.Substring(0, lt);
			if (name.EndsWith("[]") || name == "Core.String" || name == "Core.Object" || name == "Object" || name == "String")
				return true;
			let u = FindUnit(name);
			return u != null && !u.Path.IsEmpty && (u.Kind == .Class || u.Kind == .Interface || u.Kind == .Delegate);
		}

		/// Reads the project's type files and the node maps of `buildDir`. False with `outError`
		/// when the build has no node maps (not a Debug build of this project).
		public bool Load(StringView workspace, StringView buildDir, StringView exePath, String outError)
		{
			Workspace.Set(workspace);
			BuildDir.Set(buildDir);
			ExePath.Set(exePath);
			// The type files: unit names, Sheets, flow nodes, locals.
			LanguageContext lang = scope .();
			ProjectIndex index = scope .();
			index.Build(workspace, lang.Codec.Extension);
			for (let f in index.Files)
			{
				TypeDocument doc = scope .(lang);
				if (doc.Load(f.Path) case .Err || !doc.LastError.IsEmpty)
				{
					Notes.Add(new String(scope $"{f.Path}: {doc.LastError}"));
					continue;
				}
				String full = scope .();
				doc.Header.GetFullName(full);
				if (full.IsEmpty)
					continue;
				let u = GetUnit(full);
				u.Path.Set(f.Path);
				u.Kind = doc.Header.Kind;
				for (let sheet in doc.Sheets)
					AddSheet(u, full, sheet);
			}
			// The node maps.
			int maps = 0;
			if (Directory.Exists(buildDir))
			{
				for (let e in Directory.EnumerateFiles(buildDir, "*.nodemap"))
				{
					String path = scope .();
					e.GetFilePath(path);
					String unit = scope .();
					Path.GetFileNameWithoutExtension(path, unit);
					String text = scope .();
					if (File.ReadAllText(path, text) case .Err)
						continue;
					maps++;
					ReadNodeMap(GetUnit(unit), text);
				}
			}
			if (maps == 0)
			{
				outError.AppendF("The build folder {} has no node maps (.nodemap): build the project in Debug first.", buildDir);
				return false;
			}
			return true;
		}

		void AddSheet(DebugUnitInfo u, StringView typeName, Sheet sheet)
		{
			DebugSheetInfo s = new .();
			s.Key.Set(sheet.Key);
			s.Name.AppendF("{}.{}", typeName, sheet.Name);
			u.Sheets[s.Key] = s;
			let graph = sheet.Graph;
			for (let n in graph.Nodes)
			{
				if (n.Key.IsEmpty || s.Nodes.ContainsKeyAlt(n.Key))
					continue;
				DebugNodeInfo info = new .();
				info.Key.Set(n.Key);
				info.Flow = n.IsExecNode || n.Kind == .Entry;
				info.Title.Append(NodeKinds.Word(n.Kind));
				if (!n.Text.IsEmpty)
					info.Title.AppendF(" {}", n.Text);
				s.Nodes[info.Key] = info;
			}
			// The flow node each value node is evaluated for.
			for (let n in graph.Nodes)
			{
				if (n.IsExecNode || n.Kind == .Entry || n.Key.IsEmpty)
					continue;
				HashSet<Node> seen = scope .();
				HashSet<Node> flows = scope .();
				FlowConsumers(graph, n, seen, flows);
				if (flows.Count == 1)
				{
					let info = s.FindNode(n.Key);
					for (let f in flows)
						info?.Consumer.Set(f.Key);
				}
			}
			// Variables (Compiler.md 4 and 7): the function's locals and each parameter a Set writes;
			// the debug info carries their names (the slot record's `"<name>" local`).
			if (sheet.Member != null && sheet.Role == .Body)
			{
				for (let l in sheet.Member.Locals)
					if (!s.LocalNames.ContainsAlt(l.Name))
						s.LocalNames.Add(new String(l.Name));
				HashSet<String> seen = scope .();
				defer { for (let k in seen) delete k; }
				for (let n in graph.Nodes)
				{
					if (n.Kind != .Set || !n.Text.StartsWith("param:"))
						continue;
					let name = n.Text.Substring(6);
					if (seen.ContainsAlt(name))
						continue;
					seen.Add(new String(name));
					if (!s.LocalNames.ContainsAlt(name))
						s.LocalNames.Add(new String(name));
				}
			}
		}

		static void FlowConsumers(Graph graph, Node n, HashSet<Node> seen, HashSet<Node> outFlows)
		{
			if (!seen.Add(n))
				return;
			for (let l in graph.Links)
			{
				if (l.From == null || l.From.Owner != n || l.To == null || l.From.Kind != .Value)
					continue;
				let to = l.To.Owner;
				if (to.IsExecNode || to.Kind == .Entry)
					outFlows.Add(to);
				else
					FlowConsumers(graph, to, seen, outFlows);
			}
		}

		void ReadNodeMap(DebugUnitInfo u, StringView text)
		{
			for (var line in text.Split('\n'))
			{
				line.Trim();
				if (line.IsEmpty)
					continue;
				var parts = line.Split(' ');
				StringView sheet = default, node = default, num = default;
				if (!(parts.GetNext() case .Ok(out sheet)) || !(parts.GetNext() case .Ok(out node)) || !(parts.GetNext() case .Ok(out num)))
					continue;
				let l = int32.Parse(num).GetValueOrDefault();
				if (l <= 0)
					continue;
				var s = u.FindSheet(sheet);
				if (s == null)
				{
					// A Sheet the project has no file for (the core library): known by its line only.
					s = new .();
					s.Key.Set(sheet);
					s.Name.AppendF("{}.{}", u.Name, sheet);
					u.Sheets[s.Key] = s;
				}
				var n = s.FindNode(node);
				if (n == null)
				{
					n = new .();
					n.Key.Set(node);
					s.Nodes[n.Key] = n;
				}
				n.Line = l;
				if (!u.ByLine.ContainsKey(l))
					u.ByLine[l] = (new String(sheet), new String(node));
			}
		}
	}
}
