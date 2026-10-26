using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using Treadle.Model;

namespace Treadle.CImport
{
	/// Where the parse finds its headers: the loaded libclang's builtin headers and the llvm-mingw
	/// sysroot, both as -isystem (Toolchain.md, Probe 3).
	static class CImportPaths
	{
		/// The llvm-mingw root, as the back end finds it (Treadle.Language.LlvmRoot: TREADLE_LLVM, else
		/// tools/llvm-mingw of the repository).
		public static void MingwRoot(String outRoot)
		{
			Treadle.Language.LlvmRoot.Get(outRoot);
		}

		/// The -isystem folders in order: libclang's builtin headers, then the sysroot's (Windows: the
		/// llvm-mingw sysroot; Linux: the system's glibc headers, /usr/include/x86_64-linux-gnu and
		/// /usr/include, as clang orders them).
		public static void SystemIncludes(List<String> outDirs)
		{
			if (!LibClang.ResourceInclude.IsEmpty)
				outDirs.Add(new String(LibClang.ResourceInclude));
#if BF_PLATFORM_WINDOWS
			String root = scope .();
			MingwRoot(root);
			for (let sub in StringView[?]("x86_64-w64-mingw32\\include", "include"))
			{
				let dir = scope String()..AppendF("{}\\{}", root, sub);
				if (Directory.Exists(dir))
					outDirs.Add(new String(dir));
			}
#else
			for (let dir in StringView[?]("/usr/local/include", "/usr/include/x86_64-linux-gnu", "/usr/include"))
				if (Directory.Exists(dir))
					outDirs.Add(new String(dir));
#endif
		}

		/// The target of the parse: the platform the programs are built for (Builder's target).
#if BF_PLATFORM_WINDOWS
		public const String Target = "x86_64-w64-windows-gnu";
#else
		public const String Target = "x86_64-pc-linux-gnu";
#endif
	}

	/// Imports one `import` set of a `.cimport` file with libclang (Compiler.md 8, docs/C-Import.md).
	class SetImporter
	{
		CImportSet mSet;
		String mBaseDir = new .() ~ delete _;
		CDeclSet mOut;
		void* mIndex;
		void* mTU;

		List<CXCursor> mTop = new .() ~ delete _;
		List<void*> mListedFiles = new .() ~ delete _;
		List<String> mOnly = new .() ~ DeleteContainerAndItems!(_);
		List<String> mHide = new .() ~ DeleteContainerAndItems!(_);
		List<String> mPrefixes = new .() ~ DeleteContainerAndItems!(_);

		/// Records, enums and typedefs by USR: their Treadle names, so a type is declared once.
		Dictionary<String, String> mRecordNames = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
		Dictionary<String, String> mEnumNames = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
		HashSet<String> mTypedefsDone = new .() ~ DeleteContainerAndItems!(_);
		/// Anonymous records / enums named by the first typedef that names them (USR -> name).
		Dictionary<String, String> mAnonNames = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
		HashSet<String> mUsedTypeNames = new .() ~ DeleteContainerAndItems!(_);
		HashSet<String> mFunctionNames = new .() ~ DeleteContainerAndItems!(_);
		HashSet<String> mConstNames = new .() ~ DeleteContainerAndItems!(_);
		HashSet<String> mVarNames = new .() ~ DeleteContainerAndItems!(_);
		/// Every function the parse declares, selected or not (a macro variable's function).
		Dictionary<String, CXCursor> mFunctionCursors = new .() ~ DeleteDictionaryAndKeys!(_);
		List<CXCursor> mRecordQueue = new .() ~ delete _;
		List<CXCursor> mEnumQueue = new .() ~ delete _;
		List<CXCursor> mTypedefQueue = new .() ~ delete _;
		MacroEval mMacros = new .() ~ delete _;
		List<CXCursor> mMacroCursors = new .() ~ delete _;
		/// Static (inline) functions of the set: no library exports them, so they are skipped and
		/// reported as one warning.
		List<String> mStaticSkipped = new .() ~ DeleteContainerAndItems!(_);
		CXCursor mFirstStatic;

		public this(CImportSet set, StringView baseDir, CDeclSet output)
		{
			mSet = set;
			mBaseDir.Set(baseDir);
			mOut = output;
			for (let line in set.Only)
				AddWords(line, mOnly, true);
			for (let line in set.Hide)
				AddWords(line, mHide, false);
			// `prefix SDL_ IMG_` and `param puts s`: keys of this importer, which the codec keeps
			// as unknown properties.
			if (set.Extras.Inner != null)
				for (let a in set.Extras.Inner)
				{
					var l = StringView(a.Line)..Trim();
					if (l.StartsWith("prefix "))
						AddWords(l.Substring(7), mPrefixes, false);
					else if (l.StartsWith("param "))
					{
						List<String> words = scope .();
						AddWords(l.Substring(6), words, false);
						if (words.Count >= 2 && !mParamNames.ContainsKey(words[0]))
						{
							List<String> names = new .();
							for (int i = 1; i < words.Count; i++)
								names.Add(new String(words[i]));
							mParamNames[new String(words[0])] = names;
						}
						ClearAndDeleteItems!(words);
					}
				}
		}

		/// `param <function> <name>...`: the set's own names for a function's parameters, in order.
		Dictionary<String, List<String>> mParamNames = new .() ~ { for (let kv in _) { delete kv.key; DeleteContainerAndItems!(kv.value); } delete _; };

		static void AddWords(StringView line, List<String> into, bool stripArity)
		{
			for (var w in line.Split(' ', '\t'))
			{
				w.Trim();
				if (w.IsEmpty)
					continue;
				if (stripArity)
				{
					let slash = w.IndexOf('/');
					if (slash > 0)
						w = w.Substring(0, slash);
				}
				into.Add(new String(w));
			}
		}

		// ------------------------------------------------------------------ libclang helpers

		static int32 CollectVisitor(CXCursor* c, CXCursor* parent, void* data)
		{
			let list = (List<CXCursor>)Internal.UnsafeCastToObject(data);
			list.Add(*c);
			return 1; // CXChildVisit_Continue
		}

		static void Children(CXCursor c, List<CXCursor> outList)
		{
			var c2 = c;
			LibClang.visitChildren(&c2, => CollectVisitor, Internal.UnsafeCastToPtr(outList));
		}

		static int32 Kind(CXCursor c)
		{
			var c2 = c;
			return LibClang.getCursorKind(&c2);
		}

		static void Spelling(CXCursor c, String outText)
		{
			var c2 = c;
			CXString s = default;
			LibClang.getCursorSpelling(&s, &c2);
			LibClang.Take(ref s, outText);
		}

		static void Usr(CXCursor c, String outText)
		{
			var c2 = c;
			CXCursor canon = default;
			LibClang.getCanonicalCursor(&canon, &c2);
			CXString s = default;
			LibClang.getCursorUSR(&s, &canon);
			LibClang.Take(ref s, outText);
		}

		static CXType CursorType(CXCursor c)
		{
			var c2 = c;
			CXType t = default;
			LibClang.getCursorType(&t, &c2);
			return t;
		}

		static CXType Canonical(CXType t)
		{
			var t2 = t;
			CXType r = default;
			LibClang.getCanonicalType(&r, &t2);
			return r;
		}

		static CXType Pointee(CXType t)
		{
			var t2 = t;
			CXType r = default;
			LibClang.getPointeeType(&r, &t2);
			return r;
		}

		static CXCursor TypeDecl(CXType t)
		{
			var t2 = t;
			CXCursor r = default;
			LibClang.getTypeDeclaration(&r, &t2);
			return r;
		}

		static void TypeSpelling(CXType t, String outText)
		{
			var t2 = t;
			CXString s = default;
			LibClang.getTypeSpelling(&s, &t2);
			LibClang.Take(ref s, outText);
		}

		static int64 SizeOf(CXType t)
		{
			var t2 = t;
			return LibClang.Type_getSizeOf(&t2);
		}

		static int64 AlignOf(CXType t)
		{
			var t2 = t;
			return LibClang.Type_getAlignOf(&t2);
		}

		static bool IsNull(CXCursor c)
		{
			var c2 = c;
			return LibClang.Cursor_isNull(&c2) != 0;
		}

		/// The file (a CXFile) and line a cursor is expanded at.
		static void Where(CXCursor c, out void* file, out uint32 line)
		{
			var c2 = c;
			CXSourceLocation loc = default;
			LibClang.getCursorLocation(&loc, &c2);
			file = null;
			line = 0;
			uint32 col = 0, off = 0;
			LibClang.getExpansionLocation(&loc, &file, &line, &col, &off);
		}

		/// `SDL_video.h:1234` for warnings.
		static void WhereText(CXCursor c, String outText)
		{
			Where(c, var file, var line);
			if (file == null)
			{
				outText.Append("<built-in>");
				return;
			}
			CXString s = default;
			LibClang.getFileName(&s, file);
			String path = scope .();
			LibClang.Take(ref s, path);
			String name = scope .();
			Path.GetFileName(path, name);
			outText.AppendF("{}:{}", name, line);
		}

		/// A record or enum without a name of its own (`struct { ... }`).
		static bool IsAnonymous(CXCursor c)
		{
			var c2 = c;
			if (LibClang.Cursor_isAnonymous(&c2) != 0)
				return true;
			String n = scope .();
			Spelling(c, n);
			return n.IsEmpty || n.Contains(' ') || n.Contains('(');
		}

		void Warn(CXCursor c, StringView what)
		{
			String w = new .();
			WhereText(c, w);
			w.AppendF(": {}", what);
			mOut.Warnings.Add(w);
		}

		// ------------------------------------------------------------------ selection

		static bool Glob(StringView pattern, StringView name)
		{
			int p = 0, n = 0, starP = -1, starN = 0;
			while (n < name.Length)
			{
				if (p < pattern.Length && (pattern[p] == '?' || pattern[p] == name[n]))
				{
					p++;
					n++;
				}
				else if (p < pattern.Length && pattern[p] == '*')
				{
					starP = p++;
					starN = n;
				}
				else if (starP >= 0)
				{
					p = starP + 1;
					n = ++starN;
				}
				else
					return false;
			}
			while (p < pattern.Length && pattern[p] == '*')
				p++;
			return p == pattern.Length;
		}

		bool Hidden(StringView name)
		{
			for (let h in mHide)
				if (Glob(h, name))
					return true;
			return false;
		}

		bool InOnly(StringView name)
		{
			for (let o in mOnly)
				if (o == name)
					return true;
			return false;
		}

		/// A declaration belongs to the set when it is in one of the set's `header` files or in a
		/// header that is not a system header (found through the set's `include` paths).
		bool InSetFiles(CXCursor c)
		{
			Where(c, var file, var line);
			if (file == null)
				return false;
			for (let f in mListedFiles)
				if (LibClang.File_isEqual(f, file) != 0)
					return true;
			var c2 = c;
			CXSourceLocation loc = default;
			LibClang.getCursorLocation(&loc, &c2);
			if (LibClang.Location_isFromMainFile(&loc) != 0)
				return false;
			return LibClang.Location_isInSystemHeader(&loc) == 0;
		}

		/// Offered by the set: in `only` when there is one, else in the set's files with one of the
		/// prefixes; never when `hide` matches.
		bool Selected(StringView name, CXCursor c)
		{
			if (name.IsEmpty || Hidden(name))
				return false;
			if (!mOnly.IsEmpty)
				return InOnly(name);
			if (!mPrefixes.IsEmpty)
			{
				bool any = false;
				for (let p in mPrefixes)
					if (name.StartsWith(p))
						any = true;
				if (!any)
					return false;
			}
			return InSetFiles(c);
		}

		// ------------------------------------------------------------------ run

		/// Parses the set's headers and fills the output. False when the parse fails (Errors says why).
		public bool Run()
		{
			let sw = scope Stopwatch(true);
			if (!Parse())
				return false;
			mOut.ParseMs = sw.Elapsed.TotalMilliseconds;
			sw.Restart();
			Children(TranslationUnitCursor(), mTop);
			PrePass();
			for (let c in mTop)
				Top(c);
			Drain();
			if (!mStaticSkipped.IsEmpty)
			{
				String list = scope .();
				for (let n in mStaticSkipped)
				{
					if (@n.Index >= 8)
					{
						list.Append(", ...");
						break;
					}
					if (@n.Index > 0)
						list.Append(", ");
					list.Append(n);
				}
				Warn(mFirstStatic, scope $"{mStaticSkipped.Count} static (inline) functions skipped, no library exports them: {list}");
			}
			mOut.WalkMs = sw.Elapsed.TotalMilliseconds;
			return true;
		}

		public void Dispose()
		{
			if (mTU != null)
				LibClang.disposeTranslationUnit(mTU);
			if (mIndex != null)
				LibClang.disposeIndex(mIndex);
			mTU = null;
			mIndex = null;
		}

		public ~this()
		{
			Dispose();
		}

		CXCursor TranslationUnitCursor()
		{
			CXCursor c = default;
			LibClang.getTranslationUnitCursor(&c, mTU);
			return c;
		}

		void Absolute(StringView path, String outPath)
		{
			CImportSet.ResolvePath(path, mBaseDir, outPath);
#if BF_PLATFORM_WINDOWS
			outPath.Replace('/', '\\');
#endif
		}

		bool Parse()
		{
			List<String> args = scope .();
			defer { ClearAndDeleteItems!(args); }
			args.Add(new String("-x"));
			args.Add(new String("c"));
			args.Add(new String("-std=gnu17"));
			args.Add(new String("-target"));
			args.Add(new String(CImportPaths.Target));
			// Only the folders below: no host compiler's headers leak into the parse.
			args.Add(new String("-nostdinc"));
			List<String> sys = scope .();
			defer { ClearAndDeleteItems!(sys); }
			CImportPaths.SystemIncludes(sys);
			for (let s in sys)
			{
				args.Add(new String("-isystem"));
				args.Add(new String(s));
			}
			for (let inc in mSet.Includes)
			{
				String p = scope .();
				Absolute(inc, p);
				args.Add(new $"-I{p}");
			}
			for (let d in mSet.Defines)
			{
				var t = StringView(d)..Trim();
				let sp = t.IndexOf(' ');
				if (sp > 0)
					args.Add(new $"-D{t.Substring(0, sp)}={t.Substring(sp + 1)..Trim()}");
				else
					args.Add(new $"-D{t}");
			}

			String main = scope .();
			main.AppendF("{}{}__treadle_cimport_{}.c", mBaseDir, Path.DirectorySeparatorChar, mSet.Name);
			String contents = scope .();
			for (let h in mSet.Headers)
			{
				String p = scope .();
				p.Set(h);
				p.Replace('\\', '/');
				contents.AppendF("#include \"{}\"\n", p);
			}

			char8*[] argv = scope char8*[args.Count];
			for (int i < args.Count)
				argv[i] = args[i].CStr();
			CXUnsavedFile unsaved = default;
			unsaved.Filename = main.CStr();
			unsaved.Contents = contents.CStr();
			unsaved.Length = (.)contents.Length;

			mIndex = LibClang.createIndex(0, 0);
			let opts = CXTUFlags.SkipFunctionBodies | CXTUFlags.KeepGoing | CXTUFlags.DetailedPreprocessingRecord;
			let err = LibClang.parseTranslationUnit2(mIndex, main.CStr(), argv.Ptr, (int32)args.Count, &unsaved, 1, opts, &mTU);
			if (err != 0 || mTU == null)
			{
				mOut.Errors.Add(new $"libclang could not parse the set (error {err})");
				return false;
			}
			let n = LibClang.getNumDiagnostics(mTU);
			for (uint32 i < n)
			{
				let d = LibClang.getDiagnostic(mTU, i);
				if (LibClang.getDiagnosticSeverity(d) >= 3)
				{
					CXString s = default;
					LibClang.formatDiagnostic(&s, d, 0x1 | 0x2); // source location + column
					String text = new .();
					LibClang.Take(ref s, text);
					mOut.Errors.Add(text);
				}
				LibClang.disposeDiagnostic(d);
			}
			return mOut.Errors.IsEmpty;
		}

		/// Before the walk: the set's own header files, typedef names of anonymous records and
		/// enums, every enum constant and macro body (macros may use either), and arithmetic
		/// typedefs (for casts in macros).
		void PrePass()
		{
			for (let c in mTop)
			{
				let k = Kind(c);
				switch (k)
				{
				case CXCursorKind.FunctionDecl:
					String name = scope .();
					Spelling(c, name);
					if (!name.IsEmpty && !mFunctionCursors.ContainsKeyAlt(name))
						mFunctionCursors[new String(name)] = c;
				case CXCursorKind.InclusionDirective:
					var c2 = c;
					CXSourceLocation loc = default;
					LibClang.getCursorLocation(&loc, &c2);
					if (LibClang.Location_isFromMainFile(&loc) != 0)
					{
						let f = LibClang.getIncludedFile(&c2);
						if (f != null)
							mListedFiles.Add(f);
					}
				case CXCursorKind.TypedefDecl:
					String name = scope .();
					Spelling(c, name);
					var c2 = c;
					CXType under = default;
					LibClang.getTypedefDeclUnderlyingType(&under, &c2);
					let named = Desugar(under);
					if (named.Kind == CXTypeKind.Record || named.Kind == CXTypeKind.Enum)
					{
						let decl = TypeDecl(named);
						if (!IsNull(decl) && IsAnonymous(decl))
						{
							String usr = scope .();
							Usr(decl, usr);
							if (!mAnonNames.ContainsKey(usr))
								mAnonNames[new String(usr)] = new String(name);
						}
					}
					let canon = Canonical(under);
					int32 width = 0;
					bool uns = false, isFloat = false;
					if (ArithKind(canon.Kind, SizeOf(canon), out width, out uns, out isFloat))
						if (!mMacros.ArithTypedefs.ContainsKeyAlt(name))
							mMacros.ArithTypedefs[new String(name)] = (width, uns, isFloat);
				case CXCursorKind.EnumDecl:
					List<CXCursor> kids = scope .();
					Children(c, kids);
					for (let e in kids)
					{
						if (Kind(e) != CXCursorKind.EnumConstantDecl)
							continue;
						String name = scope .();
						Spelling(e, name);
						var e2 = e;
						if (!mMacros.EnumConsts.ContainsKeyAlt(name))
							mMacros.EnumConsts[new String(name)] = LibClang.getEnumConstantDeclValue(&e2);
					}
				case CXCursorKind.MacroDefinition:
					var c2 = c;
					if (LibClang.Cursor_isMacroBuiltin(&c2) != 0 || LibClang.Cursor_isMacroFunctionLike(&c2) != 0)
						break;
					String name = scope .();
					Spelling(c, name);
					List<MacroEval.Tok> body = new .();
					CXSourceRange range = default;
					LibClang.getCursorExtent(&range, &c2);
					CXToken* toks = null;
					uint32 count = 0;
					LibClang.tokenize(mTU, &range, &toks, &count);
					for (uint32 i = 1; i < count; i++)
					{
						MacroEval.Tok t;
						t.Kind = LibClang.getTokenKind(&toks[i]);
						if (t.Kind == CXTokenKind.Comment)
							continue;
						CXString s = default;
						LibClang.getTokenSpelling(&s, mTU, &toks[i]);
						t.Text = new .();
						LibClang.Take(ref s, t.Text);
						body.Add(t);
					}
					if (toks != null)
						LibClang.disposeTokens(mTU, toks, count);
					mMacros.AddBody(name, body);
					mMacroCursors.Add(c);
				}
			}
		}

		/// Width / signedness / float of an arithmetic builtin type kind.
		static bool ArithKind(int32 kind, int64 size, out int32 width, out bool isUnsigned, out bool isFloat)
		{
			width = (int32)(size * 8);
			isUnsigned = false;
			isFloat = false;
			switch (kind)
			{
			case CXTypeKind.Bool, CXTypeKind.Char_U, CXTypeKind.UChar, CXTypeKind.UShort, CXTypeKind.UInt, CXTypeKind.ULong, CXTypeKind.ULongLong, CXTypeKind.Char16, CXTypeKind.Char32, CXTypeKind.WChar:
				isUnsigned = true;
				return width > 0;
			case CXTypeKind.Char_S, CXTypeKind.SChar, CXTypeKind.Short, CXTypeKind.Int, CXTypeKind.Long, CXTypeKind.LongLong:
				return width > 0;
			case CXTypeKind.Float, CXTypeKind.Double:
				isFloat = true;
				return width > 0;
			case CXTypeKind.Enum:
				return width > 0;
			default:
				return false;
			}
		}

		/// Strips the sugar that does not name anything: `struct X` (elaborated) and attributes.
		static CXType Desugar(CXType t)
		{
			var cur = t;
			for (int guard < 16)
			{
				CXType next = default;
				if (cur.Kind == CXTypeKind.Elaborated)
					LibClang.Type_getNamedType(&next, &cur);
				else if (cur.Kind == CXTypeKind.Attributed || cur.Kind == CXTypeKind.BTFTagAttributed)
					LibClang.Type_getModifiedType(&next, &cur);
				else
					return cur;
				if (next.Kind == CXTypeKind.Invalid)
					return cur;
				cur = next;
			}
			return cur;
		}

		void Top(CXCursor c)
		{
			let k = Kind(c);
			switch (k)
			{
			case CXCursorKind.FunctionDecl:
				String name = scope .();
				Spelling(c, name);
				if (mFunctionNames.ContainsAlt(name) || !Selected(name, c))
					return;
				mFunctionNames.Add(new String(name));
				Function(c, name);
			case CXCursorKind.VarDecl:
				String name = scope .();
				Spelling(c, name);
				var c2 = c;
				if (LibClang.Cursor_getStorageClass(&c2) == CXStorageClass.Static || mVarNames.ContainsAlt(name) || !Selected(name, c))
					return;
				mVarNames.Add(new String(name));
				String why = scope .();
				String t = scope .();
				if (!MapType(CursorType(c), .Field, t, why))
				{
					Warn(c, scope $"variable {name} skipped: {why}");
					return;
				}
				CVar v = new .();
				v.Name.Set(name);
				v.Type.Set(t);
				mOut.Vars.Add(v);
			case CXCursorKind.StructDecl, CXCursorKind.UnionDecl:
				if (IsAnonymous(c))
				{
					// named by a typedef (which selects it) or used as a field's type
					return;
				}
				String name = scope .();
				Spelling(c, name);
				if (Selected(name, c))
					RequestRecord(c);
			case CXCursorKind.EnumDecl:
				if (IsAnonymous(c))
				{
					String usr = scope .();
					Usr(c, usr);
					if (mAnonNames.ContainsKey(usr))
						return; // a typedef names it
					AnonymousEnumConsts(c);
					return;
				}
				String name = scope .();
				Spelling(c, name);
				if (Selected(name, c))
					RequestEnum(c);
			case CXCursorKind.TypedefDecl:
				String name = scope .();
				Spelling(c, name);
				if (Selected(name, c))
					mTypedefQueue.Add(c);
			case CXCursorKind.MacroDefinition:
				var c2 = c;
				if (LibClang.Cursor_isMacroBuiltin(&c2) != 0 || LibClang.Cursor_isMacroFunctionLike(&c2) != 0)
					return;
				String name = scope .();
				Spelling(c, name);
				if (mConstNames.ContainsAlt(name) || !Selected(name, c))
					return;
				Macro(c, name);
			}
		}

		/// The constants of `enum { A, B };` (no name to use as a type).
		void AnonymousEnumConsts(CXCursor c)
		{
			List<CXCursor> kids = scope .();
			Children(c, kids);
			var c2 = c;
			CXType it = default;
			LibClang.getEnumDeclIntegerType(&it, &c2);
			String t = scope .();
			String why = scope .();
			if (!MapType(it, .Field, t, why))
				t.Set("int32");
			let uns = t.StartsWith('u');
			for (let e in kids)
			{
				if (Kind(e) != CXCursorKind.EnumConstantDecl)
					continue;
				String name = scope .();
				Spelling(e, name);
				if (mConstNames.ContainsAlt(name) || !Selected(name, e))
					continue;
				mConstNames.Add(new String(name));
				var e2 = e;
				CConst k = new .();
				k.Name.Set(name);
				k.Type.Set(t);
				if (uns)
					k.Value.AppendF("{}", LibClang.getEnumConstantDeclUnsignedValue(&e2));
				else
					k.Value.AppendF("{}", LibClang.getEnumConstantDeclValue(&e2));
				mOut.Consts.Add(k);
			}
		}

		/// An object-like macro that reads a variable through a function, C's way to reach per-thread
		/// or DLL data: `(*f())` is `cvar <name> T` with `via f deref` (T: what f's result points at;
		/// the variable can be set), `(f(k))` / `f()` is `cvar <name> R` with `via f k` (its value, read
		/// only). The function is imported too (a `function` record), selected or not.
		bool MacroVar(StringView name)
		{
			if (!mMacros.Bodies.TryGetAlt(name, var key, var toks))
				return false;
			int s = 0;
			int e = toks.Count;
			bool Wrapped(int from, int to)
			{
				if (to - from < 2 || toks[from].Text != "(" || toks[to - 1].Text != ")")
					return false;
				int depth = 0;
				for (int i = from; i < to - 1; i++)
				{
					if (toks[i].Text == "(")
						depth++;
					else if (toks[i].Text == ")")
						depth--;
					if (depth == 0)
						return false; // `(a)(b)`: the first parenthesis closes early
				}
				return true;
			}
			while (Wrapped(s, e))
			{
				s++;
				e--;
			}
			bool deref = false;
			if (s < e && toks[s].Text == "*")
			{
				deref = true;
				s++;
				while (Wrapped(s, e))
				{
					s++;
					e--;
				}
			}
			// f ( ) or f ( <integer> )
			if (e - s < 3 || toks[s].Kind != CXTokenKind.Identifier || toks[s + 1].Text != "(" || toks[e - 1].Text != ")")
				return false;
			StringView arg = "";
			if (e - s == 4)
			{
				if (toks[s + 2].Kind != CXTokenKind.Literal || !toks[s + 2].Text[0].IsDigit)
					return false;
				arg = toks[s + 2].Text;
				while (!arg.IsEmpty && (arg[arg.Length - 1] == 'u' || arg[arg.Length - 1] == 'U' || arg[arg.Length - 1] == 'l' || arg[arg.Length - 1] == 'L'))
					arg = arg.Substring(0, arg.Length - 1);
			}
			else if (e - s != 3)
				return false;
			StringView fn = toks[s].Text;
			if (!mFunctionCursors.TryGetAlt(fn, var fkey, var fc))
				return false;
			var fc2 = fc;
			if (LibClang.Cursor_getNumArguments(&fc2) != (arg.IsEmpty ? 0 : 1))
				return false;
			var ft = CursorType(fc);
			CXType res = default;
			LibClang.getResultType(&res, &ft);
			CXType vt = res;
			if (deref)
			{
				let canon = Canonical(res);
				if (canon.Kind != CXTypeKind.Pointer)
					return false;
				var r2 = canon;
				LibClang.getPointeeType(&vt, &r2);
			}
			String t = scope .();
			String why = scope .();
			if (!MapType(vt, deref ? .Field : .Return, t, why) || t == "void")
				return false;
			if (!mFunctionNames.ContainsAlt(fn))
			{
				mFunctionNames.Add(new String(fn));
				Function(fc, fn);
			}
			if (mOut.FindFunction(fn) == null)
				return false;
			mVarNames.Add(new String(name));
			CVar v = new .();
			v.Name.Set(name);
			v.Type.Set(t);
			v.Via.Set(fn);
			v.Arg.Set(arg);
			v.Deref = deref;
			mOut.Vars.Add(v);
			return true;
		}

		void Macro(CXCursor c, StringView name)
		{
			String text = scope .();
			let outcome = mMacros.Evaluate(name, var value, text);
			switch (outcome)
			{
			case .Empty:
				return; // a flag or an include guard
			case .NotConstant:
				if (MacroVar(name))
					return;
				String body = scope .();
				if (mMacros.Bodies.TryGetAlt(name, var key, var toks))
					for (let t in toks)
					{
						if (body.Length > 60)
						{
							body.Append(" ...");
							break;
						}
						if (@t.Index > 0)
							body.Append(' ');
						body.Append(t.Text);
					}
				Warn(c, scope $"macro {name} skipped: '{body}' is not a constant");
				return;
			case .String:
				mConstNames.Add(new String(name));
				CConst k = new .();
				k.Name.Set(name);
				k.Type.Set("char8*");
				Treadle.Format.RecordText.Quote(text, k.Value);
				mOut.Consts.Add(k);
			case .Value:
				if (value.ValueKind == .Float && (value.F.IsNaN || value.F.IsInfinity))
				{
					Warn(c, scope $"macro {name} skipped: not a finite number");
					return;
				}
				mConstNames.Add(new String(name));
				CConst k = new .();
				k.Name.Set(name);
				value.TypeName(k.Type);
				value.ValueText(k.Value);
				mOut.Consts.Add(k);
			}
		}

		// ------------------------------------------------------------------ functions

		static readonly String[] sPinNames = new .("in", "then", "receiver", "result", "done", "body", "default", "deferred", "failed", "value", "object") ~ delete _;

		/// A pin-friendly parameter name: leading underscores dropped and the first letter lower
		/// case (`_Str` -> `str`, `_PtFuncCompare` -> `ptFuncCompare`); `p<i>` when the header
		/// gives none; never a name the node already uses for a pin.
		static void ParamName(StringView raw, int index, List<CParam> before, String outName)
		{
			var s = raw;
			while (s.StartsWith('_'))
				s = s.Substring(1);
			if (s.IsEmpty)
			{
				outName.AppendF("p{}", index);
			}
			else
			{
				outName.Append(s);
				if (outName[0].IsUpper && (outName.Length == 1 || outName[1].IsLower))
					outName[0] = outName[0].ToLower;
			}
			for (let p in sPinNames)
				if (outName == p)
				{
					outName.Append("Value");
					break;
				}
			bool clash = true;
			while (clash)
			{
				clash = false;
				for (let p in before)
					if (p.Name == outName)
						clash = true;
				if (clash)
					outName.AppendF("{}", index);
			}
		}

		void Function(CXCursor c, StringView name)
		{
			var c2 = c;
			if (LibClang.Cursor_getStorageClass(&c2) == CXStorageClass.Static)
			{
				if (InOnly(name))
					Warn(c, scope $"function {name} skipped: it is static (inline) in the header, so no library exports it");
				else
				{
					if (mStaticSkipped.IsEmpty)
						mFirstStatic = c;
					mStaticSkipped.Add(new String(name));
				}
				return;
			}
			var ft = CursorType(c);
			CFunction f = new .();
			f.Name.Set(name);
			String why = scope .();
			CXType res = default;
			LibClang.getResultType(&res, &ft);
			String rt = scope .();
			if (!MapType(res, .Return, rt, why))
			{
				Warn(c, scope $"function {name} skipped: the return type {why}");
				delete f;
				return;
			}
			if (rt != "void")
				f.Returns = new String(rt);
			let n = LibClang.Cursor_getNumArguments(&c2);
			for (int32 i = 0; i < n; i++)
			{
				CXCursor a = default;
				LibClang.Cursor_getArgument(&a, &c2, (uint32)i);
				String pn = scope .();
				Spelling(a, pn);
				String pt = scope .();
				why.Clear();
				if (!MapType(CursorType(a), .Param, pt, why))
				{
					Warn(c, scope $"function {name} skipped: parameter {i + 1} ({pn}) {why}");
					delete f;
					return;
				}
				CParam p = new .();
				if (mParamNames.TryGetValueAlt(name, let renamed) && i < renamed.Count)
					p.Name.Set(renamed[i]);
				else
					ParamName(pn, i, f.Params, p.Name);
				p.Type.Set(pt);
				f.Params.Add(p);
			}
			f.Variadic = LibClang.isFunctionTypeVariadic(&ft) != 0;
			let cc = LibClang.getFunctionTypeCallingConv(&ft);
			if (!CallConvWord(cc, out f.CallConv))
			{
				Warn(c, scope $"function {name} skipped: calling convention {cc} has no Treadle form");
				delete f;
				return;
			}
			mOut.Functions.Add(f);
		}

		/// null for the C convention (and x64's single convention), `stdcall` / `fastcall`; false
		/// for conventions Treadle has no word for.
		static bool CallConvWord(int32 cc, out String word)
		{
			word = null;
			switch (cc)
			{
			case CXCallConv.Default, CXCallConv.C, CXCallConv.Win64, CXCallConv.Invalid:
				return true;
			case CXCallConv.X86StdCall:
				word = new String("stdcall");
				return true;
			case CXCallConv.X86FastCall:
				word = new String("fastcall");
				return true;
			default:
				return false;
			}
		}

		// ------------------------------------------------------------------ types

		public enum Use { Param, Field, Return, Pointee, Typedef }

		/// The Treadle TypeRef of a C type (Compiler.md 8): int -> int32, long -> int32 (LLP64),
		/// long long -> int64, char -> char8, signed / unsigned char -> int8 / uint8, _Bool -> bool,
		/// wchar_t / char16_t -> uint16, size_t / uintptr_t -> uint, ptrdiff_t / intptr_t /
		/// ssize_t -> int, T* -> T*, const dropped, T[N] -> T[N] (fields; a parameter's array is
		/// its pointer), multi-dimensional arrays flattened, R (*)(A) -> function:R(A), structs,
		/// unions and enums by name, typedefs of records / enums / function pointers by their own
		/// name, other typedefs by what they stand for. False with the reason in `outWhy`.
		bool MapType(CXType t0, Use use, String outText, String outWhy)
		{
			var t = Desugar(t0);
			switch (t.Kind)
			{
			case CXTypeKind.Void:
				if (use == .Return || use == .Pointee || use == .Typedef)
				{
					outText.Append("void");
					return true;
				}
				outWhy.Append("is void");
				return false;
			case CXTypeKind.Bool: outText.Append("bool"); return true;
			case CXTypeKind.Char_S, CXTypeKind.Char_U: outText.Append("char8"); return true;
			case CXTypeKind.SChar: outText.Append("int8"); return true;
			case CXTypeKind.UChar: outText.Append("uint8"); return true;
			case CXTypeKind.Short: outText.Append("int16"); return true;
			case CXTypeKind.UShort, CXTypeKind.Char16, CXTypeKind.WChar: outText.Append((SizeOf(t) == 4) ? "uint32" : "uint16"); return true;
			case CXTypeKind.Char32: outText.Append("uint32"); return true;
			case CXTypeKind.Int: outText.Append("int32"); return true;
			case CXTypeKind.UInt: outText.Append("uint32"); return true;
			case CXTypeKind.Long: outText.Append((SizeOf(t) == 8) ? "int64" : "int32"); return true;
			case CXTypeKind.ULong: outText.Append((SizeOf(t) == 8) ? "uint64" : "uint32"); return true;
			case CXTypeKind.LongLong: outText.Append("int64"); return true;
			case CXTypeKind.ULongLong: outText.Append("uint64"); return true;
			case CXTypeKind.Float: outText.Append("float"); return true;
			case CXTypeKind.Double: outText.Append("double"); return true;
			case CXTypeKind.Typedef:
				return MapTypedef(t, use, outText, outWhy);
			case CXTypeKind.Pointer:
				let pointee = Desugar(Pointee(t));
				let pc = Canonical(pointee);
				if (pc.Kind == CXTypeKind.FunctionProto || pc.Kind == CXTypeKind.FunctionNoProto)
					return FunctionPointer(FunctionOf(pointee), outText, outWhy);
				let start = outText.Length;
				if (!MapType(pointee, .Pointee, outText, outWhy))
				{
					// A pointer to something Treadle cannot spell is still a pointer.
					outText.RemoveToEnd(start);
					outWhy.Clear();
					outText.Append("void");
				}
				outText.Append('*');
				return true;
			case CXTypeKind.Record:
				let decl = TypeDecl(t);
				outText.Append(RequestRecord(decl));
				return true;
			case CXTypeKind.Enum:
				let decl = TypeDecl(t);
				outText.Append(RequestEnum(decl));
				return true;
			case CXTypeKind.ConstantArray, CXTypeKind.IncompleteArray:
				var tt = t;
				CXType elem = default;
				LibClang.getArrayElementType(&elem, &tt);
				if (use == .Param)
				{
					if (!MapType(elem, .Pointee, outText, outWhy))
						return false;
					outText.Append('*');
					return true;
				}
				int64 count = (t.Kind == CXTypeKind.ConstantArray) ? LibClang.getArraySize(&tt) : 0;
				// int a[2][3] -> int32[6]: the same bytes, one dimension
				var inner = Desugar(elem);
				while (inner.Kind == CXTypeKind.ConstantArray || (inner.Kind == CXTypeKind.Typedef && Canonical(inner).Kind == CXTypeKind.ConstantArray))
				{
					var it = (inner.Kind == CXTypeKind.Typedef) ? Canonical(inner) : inner;
					count *= LibClang.getArraySize(&it);
					CXType e2 = default;
					LibClang.getArrayElementType(&e2, &it);
					inner = Desugar(e2);
				}
				if (!MapType(inner, .Field, outText, outWhy))
					return false;
				outText.AppendF("[{}]", count);
				return true;
			case CXTypeKind.Vector, CXTypeKind.ExtVector:
				return MapVector(t, outText, outWhy); // ImportVector.bf: __m128 -> float4, vector_size(16) int -> int32x4
			case CXTypeKind.FunctionProto, CXTypeKind.FunctionNoProto:
				// a function type itself (a typedef of one); used through a pointer it is the pointer
				return FunctionPointer(t, outText, outWhy);
			default:
				// Sugar libclang has no kind for (clang 22+ spells size_t's own type `__size_t`):
				// the predefined size types by name, anything else by its canonical type.
				String spelled = scope .();
				TypeSpelling(t, spelled);
				if (spelled.StartsWith("const "))
					spelled.Remove(0, 6);
				if (spelled == "__size_t")
				{
					outText.Append("uint");
					return true;
				}
				if (spelled == "__ptrdiff_t" || spelled == "__signed_size_t")
				{
					outText.Append("int");
					return true;
				}
				let canon = Canonical(t);
				if (canon.Kind != t.Kind && canon.Kind != CXTypeKind.Unexposed && canon.Kind != CXTypeKind.Invalid)
					return MapType(canon, use, outText, outWhy);
				outWhy.Append("has the type '");
				TypeSpelling(t, outWhy);
				outWhy.Append("', which Treadle has no type for");
				return false;
			}
		}

		/// The function type under typedef sugar.
		static CXType FunctionOf(CXType t)
		{
			var cur = Desugar(t);
			for (int guard < 16)
			{
				if (cur.Kind == CXTypeKind.FunctionProto || cur.Kind == CXTypeKind.FunctionNoProto)
					return cur;
				if (cur.Kind == CXTypeKind.Typedef)
				{
					let decl = TypeDecl(cur);
					var d2 = decl;
					CXType under = default;
					LibClang.getTypedefDeclUnderlyingType(&under, &d2);
					cur = Desugar(under);
					continue;
				}
				return Canonical(cur);
			}
			return Canonical(cur);
		}

		bool FunctionPointer(CXType ft0, String outText, String outWhy)
		{
			var ft = ft0;
			if (LibClang.isFunctionTypeVariadic(&ft) != 0)
			{
				outWhy.Append("is a pointer to a variadic function");
				return false;
			}
			outText.Append("function:");
			CXType res = default;
			LibClang.getResultType(&res, &ft);
			if (!MapType(res, .Return, outText, outWhy))
				return false;
			outText.Append('(');
			let n = (ft.Kind == CXTypeKind.FunctionProto) ? LibClang.getNumArgTypes(&ft) : 0;
			for (int32 i = 0; i < n; i++)
			{
				if (i > 0)
					outText.Append(',');
				CXType a = default;
				LibClang.getArgType(&a, &ft, (uint32)i);
				if (!MapType(a, .Param, outText, outWhy))
					return false;
			}
			outText.Append(')');
			return true;
		}

		bool MapTypedef(CXType t, Use use, String outText, String outWhy)
		{
			let decl = TypeDecl(t);
			String name = scope .();
			Spelling(decl, name);
			switch (name)
			{
			case "size_t", "rsize_t", "uintptr_t":
				outText.Append("uint");
				return true;
			case "ptrdiff_t", "intptr_t", "ssize_t":
				outText.Append("int");
				return true;
			}
			let canon = Canonical(t);
			bool keepName = canon.Kind == CXTypeKind.Record || canon.Kind == CXTypeKind.Enum;
			if (canon.Kind == CXTypeKind.Pointer)
			{
				let pc = Canonical(Pointee(canon));
				keepName = pc.Kind == CXTypeKind.FunctionProto || pc.Kind == CXTypeKind.FunctionNoProto;
			}
			if (keepName)
			{
				RequestTypedef(decl, outText);
				return true;
			}
			var d2 = decl;
			CXType under = default;
			LibClang.getTypedefDeclUnderlyingType(&under, &d2);
			return MapType(under, use, outText, outWhy);
		}

		// ------------------------------------------------------------------ records, enums, typedefs

		/// A free type name: `base`, else `base_2`, ... (a record and a typedef may not share one).
		void FreeName(StringView baseName, String outName)
		{
			outName.Set(baseName);
			for (int i = 2; mUsedTypeNames.ContainsAlt(outName); i++)
				outName.Set(scope $"{baseName}_{i}");
			mUsedTypeNames.Add(new String(outName));
		}

		void AnonName(CXCursor c, String outName)
		{
			Where(c, var file, var line);
			String stem = scope .();
			if (file != null)
			{
				CXString s = default;
				LibClang.getFileName(&s, file);
				String path = scope .();
				LibClang.Take(ref s, path);
				Path.GetFileNameWithoutExtension(path, stem);
			}
			else
				stem.Set("builtin");
			for (int i < stem.Length)
				if (!stem[i].IsLetterOrDigit)
					stem[i] = '_';
			outName.AppendF("anon_{}_{}", stem, line);
		}

		/// The Treadle name of a record (queued for declaration on first use).
		StringView RequestRecord(CXCursor decl)
		{
			String usr = scope .();
			Usr(decl, usr);
			if (mRecordNames.TryGetValue(usr, let known))
				return known;
			String name = scope .();
			if (!IsAnonymous(decl))
				Spelling(decl, name);
			else if (mAnonNames.TryGetValue(usr, let byTypedef))
				name.Set(byTypedef);
			else
				AnonName(decl, name);
			String free = new .();
			FreeName(name, free);
			mRecordNames[new String(usr)] = free;
			mRecordQueue.Add(decl);
			return free;
		}

		StringView RequestEnum(CXCursor decl)
		{
			String usr = scope .();
			Usr(decl, usr);
			if (mEnumNames.TryGetValue(usr, let known))
				return known;
			String name = scope .();
			if (!IsAnonymous(decl))
				Spelling(decl, name);
			else if (mAnonNames.TryGetValue(usr, let byTypedef))
				name.Set(byTypedef);
			else
				AnonName(decl, name);
			String free = new .();
			FreeName(name, free);
			mEnumNames[new String(usr)] = free;
			mEnumQueue.Add(decl);
			return free;
		}

		/// A typedef used by name: queued, and its name appended.
		void RequestTypedef(CXCursor decl, String outName)
		{
			let start = outName.Length;
			Spelling(decl, outName);
			if (!mTypedefsDone.ContainsAlt(StringView(outName, start)))
				mTypedefQueue.Add(decl);
		}

		void Drain()
		{
			// Declaring one type may queue others; run until nothing is left.
			int ri = 0, ei = 0, ti = 0;
			while (ri < mRecordQueue.Count || ei < mEnumQueue.Count || ti < mTypedefQueue.Count)
			{
				while (ti < mTypedefQueue.Count)
					DeclareTypedef(mTypedefQueue[ti++]);
				while (ri < mRecordQueue.Count)
					DeclareRecord(mRecordQueue[ri++]);
				while (ei < mEnumQueue.Count)
					DeclareEnum(mEnumQueue[ei++]);
			}
		}

		void DeclareTypedef(CXCursor decl)
		{
			String name = scope .();
			Spelling(decl, name);
			if (mTypedefsDone.ContainsAlt(name))
				return;
			mTypedefsDone.Add(new String(name));
			var d2 = decl;
			CXType under = default;
			LibClang.getTypedefDeclUnderlyingType(&under, &d2);
			String target = scope .();
			String why = scope .();
			if (!MapType(under, .Typedef, target, why))
			{
				Warn(decl, scope $"typedef {name} skipped: it {why}");
				return;
			}
			if (target == name)
				return; // typedef struct X X; / typedef struct { ... } X;
			if (mUsedTypeNames.ContainsAlt(name))
			{
				Warn(decl, scope $"typedef {name} skipped: a struct or enum of the set has that name");
				return;
			}
			mUsedTypeNames.Add(new String(name));
			CTypedef td = new .();
			td.Name.Set(name);
			td.Target.Set(target);
			let canon = Canonical(under);
			if (canon.Kind == CXTypeKind.Pointer)
			{
				var fp = Canonical(Pointee(canon));
				if (fp.Kind == CXTypeKind.FunctionProto || fp.Kind == CXTypeKind.FunctionNoProto)
					CallConvWord(LibClang.getFunctionTypeCallingConv(&fp), out td.CallConv);
			}
			mOut.Typedefs.Add(td);
		}

		struct RawField
		{
			public CXCursor Cursor;
			public String Name;
			public CXType Type;
			public int64 OffsetBits;
			public bool IsBits;
			public int32 Width;
		}

		/// Fields in declaration order; the fields of anonymous struct / union members are
		/// flattened into the record (their offsets are from the outer record).
		void CollectFields(CXCursor rec, CXType outer, bool nested, List<RawField> outFields)
		{
			List<CXCursor> kids = scope .();
			Children(rec, kids);
			for (let k in kids)
			{
				let kind = Kind(k);
				var k2 = k;
				if (kind == CXCursorKind.FieldDecl)
				{
					RawField f = default;
					f.Cursor = k;
					f.Name = new String();
					Spelling(k, f.Name);
					f.Type = CursorType(k);
					var o = outer;
					f.OffsetBits = (nested && !f.Name.IsEmpty) ? LibClang.Type_getOffsetOf(&o, f.Name.CStr()) : LibClang.Cursor_getOffsetOfField(&k2);
					f.IsBits = LibClang.Cursor_isBitField(&k2) != 0;
					f.Width = f.IsBits ? LibClang.getFieldDeclBitWidth(&k2) : 0;
					outFields.Add(f);
				}
				else if ((kind == CXCursorKind.StructDecl || kind == CXCursorKind.UnionDecl) && LibClang.Cursor_isAnonymousRecordDecl(&k2) != 0)
					CollectFields(k, outer, true, outFields);
			}
		}

		void DeclareRecord(CXCursor decl)
		{
			String usr = scope .();
			Usr(decl, usr);
			let name = mRecordNames[usr];
			var d2 = decl;
			CXCursor def = default;
			LibClang.getCursorDefinition(&def, &d2);
			CRecord r = new .();
			r.Name.Set(name);
			r.IsUnion = Kind(decl) == CXCursorKind.UnionDecl;
			mOut.Records.Add(r);
			if (IsNull(def) || Kind(def) >= CXCursorKind.FirstInvalid && Kind(def) <= CXCursorKind.LastInvalid)
			{
				r.Opaque = true;
				return;
			}
			let t = CursorType(def);
			r.Size = SizeOf(t);
			r.Align = AlignOf(t);
			if (r.Size < 0)
			{
				r.Opaque = true;
				return;
			}
			List<RawField> raw = scope .();
			defer { for (let f in raw) delete f.Name; }
			CollectFields(def, t, false, raw);
			int64 natural = 1;
			bool misaligned = false;
			int bitsIndex = 0;
			for (int i = 0; i < raw.Count; i++)
			{
				let f = raw[i];
				if (f.IsBits)
				{
					// a run of bitfields becomes opaque bytes over the storage units it uses
					int j = i;
					int64 first = f.OffsetBits, last = f.OffsetBits;
					String names = scope .();
					int64 unit = Math.Max(1, SizeOf(Canonical(f.Type)));
					while (j < raw.Count && raw[j].IsBits)
					{
						first = Math.Min(first, raw[j].OffsetBits);
						last = Math.Max(last, raw[j].OffsetBits + raw[j].Width);
						unit = Math.Max(unit, SizeOf(Canonical(raw[j].Type)));
						if (!raw[j].Name.IsEmpty)
						{
							if (!names.IsEmpty)
								names.Append(", ");
							names.Append(raw[j].Name);
						}
						j++;
					}
					int64 startByte = (first / (unit * 8)) * unit;
					int64 endByte = ((last + unit * 8 - 1) / (unit * 8)) * unit;
					if (j < raw.Count && !r.IsUnion)
					{
						let next = raw[j].OffsetBits / 8;
						if (next > startByte && next < endByte)
							endByte = next;
					}
					endByte = Math.Min(endByte, r.Size);
					if (endByte <= startByte)
						endByte = Math.Min(startByte + 1, r.Size);
					CField bf = new .();
					bf.Name.AppendF("_bits{}", bitsIndex++);
					bf.Type.AppendF("uint8[{}]", endByte - startByte);
					bf.Offset = startByte;
					r.Fields.Add(bf);
					Warn(f.Cursor, scope $"{name}: the bitfields {names} are kept as the opaque bytes {bf.Name} (offset {startByte}, {endByte - startByte} bytes)");
					i = j - 1;
					continue;
				}
				CField cf = new .();
				cf.Name.Set(f.Name);
				cf.Offset = f.OffsetBits / 8;
				String why = scope .();
				if (!MapType(f.Type, .Field, cf.Type, why))
				{
					let size = SizeOf(f.Type);
					cf.Type.Clear();
					cf.Type.AppendF("uint8[{}]", Math.Max(size, 0));
					Warn(f.Cursor, scope $"{name}.{f.Name} kept as {size} opaque bytes: it {why}");
				}
				let a = AlignOf(f.Type);
				if (a > 0)
				{
					natural = Math.Max(natural, a);
					if (cf.Offset % a != 0)
						misaligned = true;
				}
				r.Fields.Add(cf);
			}
			if (r.Align < natural || misaligned)
				r.Pack = r.Align;
		}

		void DeclareEnum(CXCursor decl)
		{
			String usr = scope .();
			Usr(decl, usr);
			let name = mEnumNames[usr];
			var d2 = decl;
			CXCursor def = default;
			LibClang.getCursorDefinition(&def, &d2);
			CEnum e = new .();
			e.Name.Set(name);
			mOut.Enums.Add(e);
			let src = IsNull(def) ? decl : def;
			var s2 = src;
			CXType it = default;
			LibClang.getEnumDeclIntegerType(&it, &s2);
			String why = scope .();
			if (!MapType(it, .Field, e.Underlying, why))
				e.Underlying.Set("int32");
			let uns = e.Underlying.StartsWith('u');
			List<CXCursor> kids = scope .();
			Children(src, kids);
			for (let k in kids)
			{
				if (Kind(k) != CXCursorKind.EnumConstantDecl)
					continue;
				var k2 = k;
				String n = new .();
				Spelling(k, n);
				String v = new .();
				if (uns)
					v.AppendF("{}", LibClang.getEnumConstantDeclUnsignedValue(&k2));
				else
					v.AppendF("{}", LibClang.getEnumConstantDeclValue(&k2));
				e.Values.Add((n, v));
			}
		}
	}
}
