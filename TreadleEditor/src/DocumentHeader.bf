using System;
using System.Collections;
using System.IO;
using ImGui;
using Treadle.Document;
using Treadle.Graph;
using Treadle.Model;

namespace Treadle.Editor
{
	/// The kinds of types as the editor shows them: the icon and the accent colour of the type strip, the header
	/// strip and the canvas watermark (class blue as the Project Browser's type tiles, struct teal, enum amber,
	/// interface violet, delegate rose, extension steel).
	static class TypeStyle
	{
		public static uint32 KindColor(TypeKind k)
		{
			switch (k)
			{
			case .Class: return Gui.Color(45, 115, 225);
			case .Struct: return Gui.Color(38, 166, 140);
			case .Enum: return Gui.Color(214, 158, 46);
			case .Interface: return Gui.Color(150, 104, 220);
			case .Delegate: return Gui.Color(206, 86, 120);
			case .Extension: return Gui.Color(112, 150, 190);
			}
		}

		public static StringView KindIcon(TypeKind k)
		{
			switch (k)
			{
			case .Class: return Icon.Class;
			case .Struct: return Icon.Struct;
			case .Enum: return Icon.Enum;
			case .Interface: return Icon.Interface;
			case .Delegate: return Icon.Function;
			case .Extension: return Icon.Plus;
			}
		}

		public static StringView KindWord(TypeKind k)
		{
			switch (k)
			{
			case .Class: return "class";
			case .Struct: return "struct";
			case .Enum: return "enum";
			case .Interface: return "interface";
			case .Delegate: return "delegate";
			case .Extension: return "extension";
			}
		}
	}

	/// The header strip over the canvas (docs/Editor-Model.md, "Type context"): the type in front with its kind
	/// icon, "Dog : Animal" (base and interfaces), namespace and file, Type Settings and Validate, and on the right
	/// the signature of the Sheet in front. Also the window title's type and Sheet, and the per-project layout of
	/// the open types (settings.json, projects.<folder>.typeLayout).
	extension EditorApp
	{
		/// What the header strip showed last frame (the self test): "Dog : Animal", the signature.
		public String HeaderTypeText = new .() ~ delete _;
		public String HeaderSignatureText = new .() ~ delete _;

		/// "Dog : Animal, IDamageable" (an extension: "extension of String"; a delegate: its signature).
		public static void TypeTitle(TypeDocument doc, String outText)
		{
			let h = doc.Header;
			doc.GetName(outText);
			if (h.Kind == .Extension && h.Extends != null)
			{
				outText.Append(" : extends ");
				h.Extends.ToString(outText);
				return;
			}
			bool first = true;
			if (h.Base != null)
			{
				outText.Append(" : ");
				h.Base.ToString(outText);
				first = false;
			}
			for (let i in h.Implements)
			{
				outText.Append(first ? " : " : ", ");
				i.ToString(outText);
				first = false;
			}
		}

		/// "TakeDamage(amount: int) -> bool", "get Name -> String", "Lambda b12(x: int)".
		public void SheetSignature(Sheet mg, String outName, String outRest)
		{
			let m = mg.Member;
			if (mg.Role == .Lambda)
			{
				outName.AppendF("Lambda {}", mg.LambdaNode);
				let g = mg.Graph;
				List<Pin> ins = scope .();
				List<Pin> outs = scope .();
				if (g.Entry != null)
					for (let p in g.Entry.Outputs)
						if (p.Kind == .Value)
							ins.Add(p);
				for (let n in g.Nodes)
					if (n.Kind == .Return)
					{
						for (let p in n.Inputs)
							if (p.Kind == .Value)
								outs.Add(p);
						break;
					}
				outRest.Append("(");
				for (let p in ins)
					outRest.AppendF("{}{}: {}", (@p.Index > 0) ? ", " : "", p.Label.IsEmpty ? p.Name : p.Label, p.TypeName.IsEmpty ? "?" : p.TypeName);
				outRest.Append(")");
				if (outs.Count == 1)
					outRest.AppendF(" -> {}", outs[0].TypeName.IsEmpty ? "?" : outs[0].TypeName);
				return;
			}
			if (m == null)
			{
				outName.Append(mg.Name);
				return;
			}
			switch (m.Kind)
			{
			case .Property:
				outName.AppendF("{} {}", (mg.Role == .Set) ? "set" : "get", m.Name);
				String t = scope .();
				m.Type?.ToString(t);
				if (mg.Role == .Set)
					outRest.AppendF("(value: {})", t);
				else
					outRest.AppendF(" -> {}", t);
				return;
			case .Ctor:
				outName.Append(m.Static ? "Static Constructor" : "Constructor");
			case .Dtor:
				outName.Append("Destructor");
			default:
				outName.Append(m.Name);
			}
			outRest.Append("(");
			for (let p in m.Params)
			{
				if (@p.Index > 0)
					outRest.Append(", ");
				switch (p.Mode)
				{
				case .Ref: outRest.Append("ref ");
				case .Out: outRest.Append("out ");
				case .In: outRest.Append("in ");
				default:
				}
				outRest.AppendF("{}: ", p.Name);
				if (p.Type != null)
					p.Type.ToString(outRest);
				else
					outRest.Append("?");
			}
			outRest.Append(")");
			if (m.Returns != null || !m.Outs.IsEmpty)
			{
				outRest.Append(" -> ");
				if (m.Outs.IsEmpty)
					m.Returns.ToString(outRest);
				else
				{
					outRest.Append("(");
					if (m.Returns != null)
					{
						m.Returns.ToString(outRest);
						outRest.Append(", ");
					}
					for (let o in m.Outs)
					{
						outRest.AppendF("{}{}: ", (@o.Index > 0) ? ", " : "", o.Name);
						o.Type?.ToString(outRest);
					}
					outRest.Append(")");
				}
			}
		}

		/// The strip between the Sheet tabs and the canvas (or, with no Sheet open, at the top of the type's area).
		void DrawDocumentHeader(GraphTab tab, Sheet mg)
		{
			HeaderTypeText.Clear();
			HeaderSignatureText.Clear();
			let doc = Doc;
			if (doc == null || doc == mEmptyDoc)
				return;
			float s = Look.Scale;
			float fs = Gui.igGetFontSize();
			float h = Math.Round(fs * 2.0f);
			let p0 = Gui.igGetCursorScreenPos();
			float w = Gui.igGetContentRegionAvail().x;
			let dl = Gui.igGetWindowDrawList();
			let kind = doc.Header.Kind;
			let accent = TypeStyle.KindColor(kind);
			Gui.ImDrawList_AddRectFilled(dl, p0, .(p0.x + w, p0.y + h), Theme.Mix(Look.Panel, accent, 0.07f), 0, 0);
			Gui.ImDrawList_AddRectFilled(dl, p0, .(p0.x + 3 * s, p0.y + h), accent, 0, 0);
			Gui.ImDrawList_AddLine(dl, .(p0.x, p0.y + h - 1), .(p0.x + w, p0.y + h - 1), Look.WindowBorder, 1);
			float ty = p0.y + (h - fs) * 0.5f;

			// Right: the Sheet's signature, at most about 45% of the strip.
			String sigName = scope .();
			String sigRest = scope .();
			if (mg != null)
				SheetSignature(mg, sigName, sigRest);
			HeaderSignatureText.AppendF("{}{}", sigName, sigRest);
			float sigFull = Gui.CalcTextSize(HeaderSignatureText).x;
			float sigMax = Math.Max(0, w * 0.45f);
			float sigW = Math.Min(sigFull, sigMax);
			float right = p0.x + w - 12 * s;
			if (mg != null && sigW > 0 && sigW >= Math.Min(sigFull, fs * 3))
			{
				float x = right - sigW;
				Icon.DrawCentered(dl, .(x - fs * 0.9f, p0.y + h * 0.5f), fs * 0.9f, Theme.TextDim, (mg.Role == .Lambda) ? Icon.SquareFunction : Icon.Function);
				if (sigFull <= sigMax)
				{
					Gui.DrawText(dl, .(x, ty), Look.ForegroundHover, sigName);
					Gui.DrawText(dl, .(x + Gui.CalcTextSize(sigName).x, ty), Look.ForegroundDim, sigRest);
				}
				else
				{
					String fit = scope .();
					FitText(HeaderSignatureText, sigW, fit);
					Gui.DrawText(dl, .(x, ty), Look.Foreground, fit);
				}
				right = x - fs * 2.2f;
			}

			// Left: kind icon, "Dog : Animal", then the buttons, then namespace and file while they fit.
			float x = p0.x + 12 * s;
			Gui.DrawText(dl, .(x, ty), accent, TypeStyle.KindIcon(kind));
			x += Gui.CalcTextSize(TypeStyle.KindIcon(kind)).x + 8 * s;
			TypeTitle(doc, HeaderTypeText);
			String name = scope .();
			doc.GetName(name);
			StringView bases = HeaderTypeText.Substring(name.Length);
			float nameW = Gui.CalcTextSize(name).x;
			Gui.DrawText(dl, .(x, ty), Look.ForegroundHover, name);
			x += nameW;
			if (!bases.IsEmpty)
			{
				float room = Math.Max(0, right - x - 200 * s);
				String fit = scope .();
				FitText(bases, room, fit);
				Gui.DrawText(dl, .(x, ty), Look.Foreground, fit);
				x += Gui.CalcTextSize(fit).x;
			}
			if (doc.Modified)
			{
				Gui.DrawText(dl, .(x + 4 * s, ty), Look.ForegroundDim, "*");
				x += Gui.CalcTextSize("*").x + 4 * s;
			}
			x += 14 * s;

			// The buttons: full labels when there is room, icons only when not.
			StringView tsIcon = Icon.Settings;
			StringView vIcon = Icon.CircleCheck;
			bool compact = right - x < 260 * s;
			String tsLabel = scope .();
			String vLabel = scope .();
			if (compact)
			{
				tsLabel.AppendF("{}##hdrts", tsIcon);
				vLabel.AppendF("{}##hdrval", vIcon);
			}
			else
			{
				tsLabel.AppendF("{}  Type Settings##hdrts", tsIcon);
				vLabel.AppendF("{}  Validate##hdrval", vIcon);
			}
			let bh = fs + 4 * s;
			Gui.igPushStyleVar_Vec2(StyleVar.FramePadding, .(7 * s, 2 * s));
			Gui.igPushStyleColor_U32(Col.Button, Theme.Mix(Look.Header, accent, 0.10f));
			Gui.igPushStyleColor_U32(Col.ButtonHovered, Theme.Mix(Look.Hover, accent, 0.25f));
			float bw1 = Gui.CalcTextSize(StringView(tsLabel, 0, tsLabel.IndexOf("##"))).x + 14 * s;
			float bw2 = Gui.CalcTextSize(StringView(vLabel, 0, vLabel.IndexOf("##"))).x + 14 * s;
			if (x + bw1 + bw2 + 6 * s < right)
			{
				Gui.igSetCursorScreenPos(.(x, p0.y + (h - bh) * 0.5f));
				if (Gui.Button(tsLabel))
				{
					SelectOutline(.TypeSettings);
					Panels.Focus(Panels.PropertiesId);
				}
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip("Type Settings: name, kind, namespace, base type, interfaces and generic parameters (in Properties)");
				Gui.SameLine(0, 6 * s);
				if (Gui.Button(vLabel))
					Validate();
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip("Validate (Shift+F7): checks this type and the open Sheets; the results go to Problems");
				x = Gui.igGetItemRectMax().x + 16 * s;
			}
			Gui.igPopStyleColor(2);
			Gui.igPopStyleVar(1);

			// Namespace and file, dimmed, while they fit.
			String ns = scope .();
			ns.Append(doc.Header.Namespace.IsEmpty ? "(no namespace)" : (StringView)doc.Header.Namespace);
			float nsW = Gui.CalcTextSize(ns).x + fs * 1.4f;
			if (x + nsW < right)
			{
				Gui.DrawText(dl, .(x, ty), Theme.TextDim, Icon.Braces);
				Gui.DrawText(dl, .(x + fs * 1.4f, ty), Look.ForegroundDim, ns);
				x += nsW + 14 * s;
				String file = scope .();
				if (!doc.FilePath.IsEmpty)
					Path.GetFileName(doc.FilePath, file);
				else
					file.Append("not saved yet");
				float fileW = Gui.CalcTextSize(file).x + fs * 1.4f;
				if (x + fileW < right)
				{
					Gui.DrawText(dl, .(x, ty), Theme.TextDim, Icon.FileCode);
					Gui.DrawText(dl, .(x + fs * 1.4f, ty), Look.ForegroundDim, file);
				}
			}
			Gui.igSetCursorScreenPos(.(p0.x, p0.y + h));
		}

		// ------------------------------------------------------------------ window title

		/// "<Type> - <Sheet>" of the front (the window title's tail); empty with no type open.
		void FrontTypeAndSheet(String outText)
		{
			if (Doc == null || Doc == mEmptyDoc)
				return;
			Doc.GetName(outText);
			let tab = CurrentTab;
			if (tab != null && tab.Doc == Doc)
				outText.AppendF(" - {}", tab.Title);
		}

		// ------------------------------------------------------------------ the layout per project

		/// The project the open types were restored for, and the layout last written to settings.json.
		String mTypeLayoutProject = new .() ~ delete _;
		String mTypeLayoutSaved = new .() ~ delete _;

		/// `path` relative to the project folder when it is inside it (persisted paths are relative: the
		/// project can move).
		void ProjectRelative(StringView path, String outRel)
		{
			outRel.Set(path);
			if (outRel.Length > mProjectRoot.Length && ProjectIndex.SamePath(outRel.Substring(0, mProjectRoot.Length), mProjectRoot))
			{
				outRel.Remove(0, mProjectRoot.Length);
				while (outRel.StartsWith('\\') || outRel.StartsWith('/'))
					outRel.Remove(0, 1);
			}
		}

		/// A project was opened or switched: its open types come back (once per project).
		void SyncTypeLayoutProject()
		{
			if (mTypeLayoutProject == mProjectRoot)
				return;
			mTypeLayoutProject.Set(mProjectRoot);
			mTypeLayoutSaved.Clear();
			if (!mProjectRoot.IsEmpty && Settings.Root != null)
				RestoreTypeLayout();
		}

		/// Opens the types of the saved layout with their Sheet tabs; the saved type comes to the front unless a
		/// file outside the layout was asked for (the command line, a recent file).
		void RestoreTypeLayout()
		{
			let projects = Settings.Root.Get("projects");
			if (projects == null)
				return;
			String key = scope .(mProjectRoot);
			key.Replace('/', '\\');
			while (key.EndsWith('\\'))
				key.RemoveFromEnd(1);
			key.ToLower();
			let proj = projects.Get(key);
			let layout = (proj != null) ? proj.Get("typeLayout") : null;
			let types = (layout != null) ? layout.Get("types") : null;
			if (types == null || types.Type != .Array)
				return;
			let focus = IsLoadedDoc(Doc) ? Doc : null;
			bool focusInLayout = false;
			TypeDocument front = null;
			let activeRel = layout.GetString("active");
			int count = 0;
			for (let t in types.Items)
			{
				let file = t.GetString("file");
				if (file.IsEmpty)
					continue;
				String path = scope .();
				if (Path.IsPathRooted(file))
					path.Set(file);
				else
					path.AppendF("{}{}{}", mProjectRoot, Path.DirectorySeparatorChar, file);
				if (!File.Exists(path))
					continue;
				var doc = FindDoc(path);
				if (doc == null)
					doc = OpenFile(path, false);
				if (doc == null)
					continue;
				count++;
				if (doc == focus)
					focusInLayout = true;
				if (file == activeRel)
					front = doc;
				let ctx = EnsureTypeContext(doc);
				let sheets = t.Get("sheets");
				if (sheets != null && sheets.Type == .Array)
				{
					for (let k in sheets.Items)
					{
						if (k.Type != .String)
							continue;
						let mg = doc.FindSheet(k.Str);
						if (mg != null && mg.Graphable)
							OpenTab(mg);
					}
				}
				let activeKey = t.GetString("sheet");
				for (let tab in Tabs)
					if (tab.Doc == doc && tab.MethodKey == activeKey)
						ctx.ActiveTabUid = tab.Uid;
			}
			if (count == 0)
				return;
			let pick = (focus != null && !focusInLayout) ? focus : (front ?? focus);
			// Each type shows the Sheet that was in front there (not the one opened last).
			ActiveTab = -1;
			if (pick != null)
				ActivateType(pick);
			else
				SyncTypeContexts();
			Notify.Log(.Info, "Editor", scope $"Restored {count} open type(s) of the project");
		}

		/// Writes the open types (strip order), their Sheet tabs, the Sheet in front of each and the type in
		/// front to the project's settings when they changed.
		void SaveTypeLayoutIfChanged()
		{
			if (mProjectRoot.IsEmpty || mTypeLayoutProject != mProjectRoot || Settings.Root == null)
				return;
			List<TypeContext> order = scope .();
			CollectTypeSlots(order);
			String sig = scope .();
			String rel = scope .();
			for (let ctx in order)
			{
				if (ctx.Doc.FilePath.IsEmpty)
					continue;
				ProjectRelative(ctx.Doc.FilePath, rel);
				sig.AppendF("{}|", rel);
				List<GraphTab> tabs = scope .();
				for (let t in Tabs)
					if (t.Doc == ctx.Doc)
						tabs.Add(t);
				tabs.Sort(scope (a, b) => (a.BarX == b.BarX) ? (a.Uid <=> b.Uid) : (a.BarX <=> b.BarX));
				for (let t in tabs)
					sig.AppendF("{};", t.MethodKey);
				let front = TabByUid(ctx.ActiveTabUid);
				sig.AppendF("|{}\n", (front != null && front.Doc == ctx.Doc) ? front.MethodKey : "");
			}
			if (IsLoadedDoc(Doc) && !Doc.FilePath.IsEmpty)
			{
				ProjectRelative(Doc.FilePath, rel);
				sig.AppendF("active={}", rel);
			}
			if (sig == mTypeLayoutSaved)
				return;
			mTypeLayoutSaved.Set(sig);
			let layout = Json.NewObject();
			let types = layout.Set("types", Json.NewArray());
			for (var line in sig.Split('\n'))
			{
				if (line.StartsWith("active="))
				{
					layout.Set("active", Json.NewString(line.Substring(7)));
					continue;
				}
				let parts = line.Split('|');
				let o = Json.NewObject();
				int i = 0;
				for (let part in parts)
				{
					switch (i)
					{
					case 0: o.Set("file", Json.NewString(part));
					case 1:
						let arr = o.Set("sheets", Json.NewArray());
						for (let k in part.Split(';', .RemoveEmptyEntries))
							arr.Items.Add(Json.NewString(k));
					case 2: o.Set("sheet", Json.NewString(part));
					}
					i++;
				}
				if (i >= 3)
					types.Items.Add(o);
				else
					delete o;
			}
			Settings.Project(mProjectRoot).Set("typeLayout", layout);
			Settings.Save();
		}
	}
}
