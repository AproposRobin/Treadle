using System;
using System.IO;

namespace Treadle.CImport
{
	// The libclang C API (clang-c/Index.h) bound through function pointers that are looked up in
	// libclang.dll (Windows) or libclang.so (Linux, with dlopen) at run time, so the editor starts and
	// runs without it and only the import needs it.
	//
	// ABI note (Windows x64): every libclang struct passed or returned by value is larger than 8
	// bytes, and the Microsoft x64 convention passes such a struct as a pointer to a caller-owned
	// copy and returns it through a hidden pointer given as the first argument (returned again in
	// RAX). The bindings below spell that out (`CXCursor*` for a by-value CXCursor, a leading
	// `CXString* ret` for a CXString result), so nothing depends on how Beef lowers aggregates.
	//
	// Linux (System V x86-64): the C functions are declared with their structs by value (`c_*`
	// function pointers: a CXCursor of 32 bytes goes on the stack, a CXString of 16 bytes comes back
	// in RAX:RDX), which Beef lowers by the System V rules for [CRepr] structs (checked against a
	// clang-built library with the same shapes, including a by-value callback). Methods with the
	// Windows names and shapes wrap them, so the importer's calls are the same on both platforms.

	[CRepr]
	struct CXString
	{
		public void* Data;
		public uint32 PrivateFlags;
	}

	[CRepr]
	struct CXCursor
	{
		public int32 Kind;
		public int32 XData;
		public void*[3] Data;
	}

	[CRepr]
	struct CXType
	{
		public int32 Kind;
		public void*[2] Data;
	}

	[CRepr]
	struct CXSourceLocation
	{
		public void*[2] PtrData;
		public uint32 IntData;
	}

	[CRepr]
	struct CXSourceRange
	{
		public void*[2] PtrData;
		public uint32 BeginIntData;
		public uint32 EndIntData;
	}

	[CRepr]
	struct CXToken
	{
		public uint32[4] IntData;
		public void* PtrData;
	}

	[CRepr]
	struct CXUnsavedFile
	{
		public char8* Filename;
		public char8* Contents;
		/// `unsigned long`: 32 bits on Windows, 64 on Linux.
#if BF_PLATFORM_WINDOWS
		public uint32 Length;
#else
		public uint Length;
#endif
	}

	/// CXCursorKind values the import uses.
	static class CXCursorKind
	{
		public const int32 StructDecl = 2;
		public const int32 UnionDecl = 3;
		public const int32 EnumDecl = 5;
		public const int32 FieldDecl = 6;
		public const int32 EnumConstantDecl = 7;
		public const int32 FunctionDecl = 8;
		public const int32 VarDecl = 9;
		public const int32 ParmDecl = 10;
		public const int32 TypedefDecl = 20;
		public const int32 FirstInvalid = 70;
		public const int32 LastInvalid = 73;
		public const int32 MacroDefinition = 501;
		public const int32 InclusionDirective = 503;
	}

	/// CXTypeKind values the import uses.
	static class CXTypeKind
	{
		public const int32 Invalid = 0;
		public const int32 Unexposed = 1;
		public const int32 Void = 2;
		public const int32 Bool = 3;
		public const int32 Char_U = 4;
		public const int32 UChar = 5;
		public const int32 Char16 = 6;
		public const int32 Char32 = 7;
		public const int32 UShort = 8;
		public const int32 UInt = 9;
		public const int32 ULong = 10;
		public const int32 ULongLong = 11;
		public const int32 UInt128 = 12;
		public const int32 Char_S = 13;
		public const int32 SChar = 14;
		public const int32 WChar = 15;
		public const int32 Short = 16;
		public const int32 Int = 17;
		public const int32 Long = 18;
		public const int32 LongLong = 19;
		public const int32 Int128 = 20;
		public const int32 Float = 21;
		public const int32 Double = 22;
		public const int32 LongDouble = 23;
		public const int32 Pointer = 101;
		public const int32 Record = 105;
		public const int32 Enum = 106;
		public const int32 Typedef = 107;
		public const int32 FunctionNoProto = 110;
		public const int32 FunctionProto = 111;
		public const int32 ConstantArray = 112;
		public const int32 IncompleteArray = 114;
		public const int32 Vector = 113;
		public const int32 Elaborated = 119;
		public const int32 Attributed = 163;
		public const int32 ExtVector = 176;
		public const int32 BTFTagAttributed = 178;
	}

	/// CXCallingConv values.
	static class CXCallConv
	{
		public const int32 Default = 0;
		public const int32 C = 1;
		public const int32 X86StdCall = 2;
		public const int32 X86FastCall = 3;
		public const int32 Win64 = 10;
		public const int32 X86VectorCall = 12;
		public const int32 Invalid = 100;
	}

	/// CX_StorageClass values.
	static class CXStorageClass
	{
		public const int32 None = 1;
		public const int32 Extern = 2;
		public const int32 Static = 3;
	}

	/// CXTranslationUnit_Flags.
	static class CXTUFlags
	{
		public const uint32 DetailedPreprocessingRecord = 0x01;
		public const uint32 SkipFunctionBodies = 0x40;
		public const uint32 KeepGoing = 0x200;
	}

	/// CXTokenKind.
	static class CXTokenKind
	{
		public const int32 Punctuation = 0;
		public const int32 Keyword = 1;
		public const int32 Identifier = 2;
		public const int32 Literal = 3;
		public const int32 Comment = 4;
	}

	/// The libclang functions, loaded once per process by `Load`.
	static class LibClang
	{
		public typealias VisitorFn = function int32(CXCursor* cursor, CXCursor* parent, void* data);

#if BF_PLATFORM_WINDOWS
		public static function void*(int32 excludeDeclsFromPCH, int32 displayDiagnostics) createIndex;
		public static function void(void* index) disposeIndex;
		public static function int32(void* index, char8* file, char8** args, int32 numArgs, CXUnsavedFile* unsaved, uint32 numUnsaved, uint32 options, void** outTU) parseTranslationUnit2;
		public static function void(void* tu) disposeTranslationUnit;
		public static function uint32(void* tu) getNumDiagnostics;
		public static function void*(void* tu, uint32 index) getDiagnostic;
		public static function int32(void* diag) getDiagnosticSeverity;
		public static function CXString*(CXString* ret, void* diag, uint32 options) formatDiagnostic;
		public static function void(void* diag) disposeDiagnostic;
		public static function CXString*(CXString* ret) getClangVersion;

		public static function char8*(CXString* s) getCString;
		public static function void(CXString* s) disposeString;

		public static function CXCursor*(CXCursor* ret, void* tu) getTranslationUnitCursor;
		public static function uint32(CXCursor* parent, VisitorFn visitor, void* data) visitChildren;
		public static function int32(CXCursor* c) getCursorKind;
		public static function CXString*(CXString* ret, CXCursor* c) getCursorSpelling;
		public static function CXString*(CXString* ret, CXCursor* c) getCursorUSR;
		public static function CXType*(CXType* ret, CXCursor* c) getCursorType;
		public static function CXCursor*(CXCursor* ret, CXCursor* c) getCursorDefinition;
		public static function CXCursor*(CXCursor* ret, CXCursor* c) getCanonicalCursor;
		public static function uint32(CXCursor* c) isCursorDefinition;
		public static function uint32(CXCursor* c) Cursor_isAnonymous;
		public static function uint32(CXCursor* c) Cursor_isAnonymousRecordDecl;
		public static function uint32(CXCursor* c) Cursor_isNull;
		public static function int32(CXCursor* c) Cursor_getStorageClass;
		public static function int32(CXCursor* c) Cursor_getNumArguments;
		public static function CXCursor*(CXCursor* ret, CXCursor* c, uint32 index) Cursor_getArgument;
		public static function int64(CXCursor* c) Cursor_getOffsetOfField;
		public static function uint32(CXCursor* c) Cursor_isBitField;
		public static function int32(CXCursor* c) getFieldDeclBitWidth;
		public static function int64(CXCursor* c) getEnumConstantDeclValue;
		public static function uint64(CXCursor* c) getEnumConstantDeclUnsignedValue;
		public static function CXType*(CXType* ret, CXCursor* c) getEnumDeclIntegerType;
		public static function CXType*(CXType* ret, CXCursor* c) getTypedefDeclUnderlyingType;
		public static function uint32(CXCursor* c) Cursor_isMacroFunctionLike;
		public static function uint32(CXCursor* c) Cursor_isMacroBuiltin;
		public static function CXSourceLocation*(CXSourceLocation* ret, CXCursor* c) getCursorLocation;
		public static function CXSourceRange*(CXSourceRange* ret, CXCursor* c) getCursorExtent;
		public static function void*(CXCursor* c) getIncludedFile;

		public static function CXType*(CXType* ret, CXType* t) getCanonicalType;
		public static function CXType*(CXType* ret, CXType* t) getPointeeType;
		public static function CXType*(CXType* ret, CXType* t) getResultType;
		public static function CXType*(CXType* ret, CXType* t) getArrayElementType;
		public static function int64(CXType* t) getArraySize;
		/// Vectors (`__m128`, `vector_size`, `ext_vector_type`): the lane type and the lane count.
		public static function CXType*(CXType* ret, CXType* t) getElementType;
		public static function int64(CXType* t) getNumElements;
		public static function int32(CXType* t) getNumArgTypes;
		public static function CXType*(CXType* ret, CXType* t, uint32 index) getArgType;
		public static function uint32(CXType* t) isFunctionTypeVariadic;
		public static function int32(CXType* t) getFunctionTypeCallingConv;
		public static function int64(CXType* t) Type_getSizeOf;
		public static function int64(CXType* t) Type_getAlignOf;
		public static function int64(CXType* t, char8* field) Type_getOffsetOf;
		public static function CXType*(CXType* ret, CXType* t) Type_getNamedType;
		public static function CXType*(CXType* ret, CXType* t) Type_getModifiedType;
		public static function CXCursor*(CXCursor* ret, CXType* t) getTypeDeclaration;
		public static function CXString*(CXString* ret, CXType* t) getTypeSpelling;
		public static function uint32(CXType* t) isConstQualifiedType;

		public static function void(CXSourceLocation* loc, void** file, uint32* line, uint32* column, uint32* offset) getExpansionLocation;
		public static function int32(CXSourceLocation* loc) Location_isInSystemHeader;
		public static function int32(CXSourceLocation* loc) Location_isFromMainFile;
		public static function CXString*(CXString* ret, void* file) getFileName;
		public static function int32(void* a, void* b) File_isEqual;

		public static function void(void* tu, CXSourceRange* range, CXToken** tokens, uint32* count) tokenize;
		public static function CXString*(CXString* ret, void* tu, CXToken* token) getTokenSpelling;
		public static function int32(CXToken* token) getTokenKind;
		public static function void(void* tu, CXToken* tokens, uint32 count) disposeTokens;
#else
		// The C functions with their System V shapes (structs by value), bound by Load.
		public static function void*(int32 excludeDeclsFromPCH, int32 displayDiagnostics) createIndex;
		public static function void(void* index) disposeIndex;
		public static function int32(void* index, char8* file, char8** args, int32 numArgs, CXUnsavedFile* unsaved, uint32 numUnsaved, uint32 options, void** outTU) parseTranslationUnit2;
		public static function void(void* tu) disposeTranslationUnit;
		public static function uint32(void* tu) getNumDiagnostics;
		public static function void*(void* tu, uint32 index) getDiagnostic;
		public static function int32(void* diag) getDiagnosticSeverity;
		public static function void(void* diag) disposeDiagnostic;
		public static function int32(void* a, void* b) File_isEqual;
		public static function void(void* tu, CXToken* tokens, uint32 count) disposeTokens;

		public typealias CVisitorFn = function int32(CXCursor cursor, CXCursor parent, void* data);
		static function CXString(void* diag, uint32 options) c_formatDiagnostic;
		static function CXString() c_getClangVersion;
		static function char8*(CXString s) c_getCString;
		static function void(CXString s) c_disposeString;
		static function CXCursor(void* tu) c_getTranslationUnitCursor;
		static function uint32(CXCursor parent, CVisitorFn visitor, void* data) c_visitChildren;
		static function int32(CXCursor c) c_getCursorKind;
		static function CXString(CXCursor c) c_getCursorSpelling;
		static function CXString(CXCursor c) c_getCursorUSR;
		static function CXType(CXCursor c) c_getCursorType;
		static function CXCursor(CXCursor c) c_getCursorDefinition;
		static function CXCursor(CXCursor c) c_getCanonicalCursor;
		static function uint32(CXCursor c) c_isCursorDefinition;
		static function uint32(CXCursor c) c_Cursor_isAnonymous;
		static function uint32(CXCursor c) c_Cursor_isAnonymousRecordDecl;
		static function uint32(CXCursor c) c_Cursor_isNull;
		static function int32(CXCursor c) c_Cursor_getStorageClass;
		static function int32(CXCursor c) c_Cursor_getNumArguments;
		static function CXCursor(CXCursor c, uint32 index) c_Cursor_getArgument;
		static function int64(CXCursor c) c_Cursor_getOffsetOfField;
		static function uint32(CXCursor c) c_Cursor_isBitField;
		static function int32(CXCursor c) c_getFieldDeclBitWidth;
		static function int64(CXCursor c) c_getEnumConstantDeclValue;
		static function uint64(CXCursor c) c_getEnumConstantDeclUnsignedValue;
		static function CXType(CXCursor c) c_getEnumDeclIntegerType;
		static function CXType(CXCursor c) c_getTypedefDeclUnderlyingType;
		static function uint32(CXCursor c) c_Cursor_isMacroFunctionLike;
		static function uint32(CXCursor c) c_Cursor_isMacroBuiltin;
		static function CXSourceLocation(CXCursor c) c_getCursorLocation;
		static function CXSourceRange(CXCursor c) c_getCursorExtent;
		static function void*(CXCursor c) c_getIncludedFile;
		static function CXType(CXType t) c_getCanonicalType;
		static function CXType(CXType t) c_getPointeeType;
		static function CXType(CXType t) c_getResultType;
		static function CXType(CXType t) c_getArrayElementType;
		static function int64(CXType t) c_getArraySize;
		static function CXType(CXType t) c_getElementType;
		static function int64(CXType t) c_getNumElements;
		static function int32(CXType t) c_getNumArgTypes;
		static function CXType(CXType t, uint32 index) c_getArgType;
		static function uint32(CXType t) c_isFunctionTypeVariadic;
		static function int32(CXType t) c_getFunctionTypeCallingConv;
		static function int64(CXType t) c_Type_getSizeOf;
		static function int64(CXType t) c_Type_getAlignOf;
		static function int64(CXType t, char8* field) c_Type_getOffsetOf;
		static function CXType(CXType t) c_Type_getNamedType;
		static function CXType(CXType t) c_Type_getModifiedType;
		static function CXCursor(CXType t) c_getTypeDeclaration;
		static function CXString(CXType t) c_getTypeSpelling;
		static function uint32(CXType t) c_isConstQualifiedType;
		static function void(CXSourceLocation loc, void** file, uint32* line, uint32* column, uint32* offset) c_getExpansionLocation;
		static function int32(CXSourceLocation loc) c_Location_isInSystemHeader;
		static function int32(CXSourceLocation loc) c_Location_isFromMainFile;
		static function CXString(void* file) c_getFileName;
		static function void(void* tu, CXSourceRange range, CXToken** tokens, uint32* count) c_tokenize;
		static function CXString(void* tu, CXToken token) c_getTokenSpelling;
		static function int32(CXToken token) c_getTokenKind;

		// The Windows shapes over them (see the ABI note at the top).
		public static CXString* formatDiagnostic(CXString* ret, void* diag, uint32 options) { *ret = c_formatDiagnostic(diag, options); return ret; }
		public static CXString* getClangVersion(CXString* ret) { *ret = c_getClangVersion(); return ret; }
		public static char8* getCString(CXString* s) => c_getCString(*s);
		public static void disposeString(CXString* s) => c_disposeString(*s);
		public static CXCursor* getTranslationUnitCursor(CXCursor* ret, void* tu) { *ret = c_getTranslationUnitCursor(tu); return ret; }

		/// The importer's visitor (pointers) behind the C visitor (by value).
		struct VisitContext
		{
			public VisitorFn Visitor;
			public void* Data;
		}

		[CallingConvention(.Cdecl)]
		static int32 VisitTrampoline(CXCursor cursor, CXCursor parent, void* data)
		{
			var c = cursor;
			var p = parent;
			let ctx = (VisitContext*)data;
			return ctx.Visitor(&c, &p, ctx.Data);
		}

		public static uint32 visitChildren(CXCursor* parent, VisitorFn visitor, void* data)
		{
			VisitContext ctx = .() { Visitor = visitor, Data = data };
			return c_visitChildren(*parent, => VisitTrampoline, &ctx);
		}

		public static int32 getCursorKind(CXCursor* c) => c_getCursorKind(*c);
		public static CXString* getCursorSpelling(CXString* ret, CXCursor* c) { *ret = c_getCursorSpelling(*c); return ret; }
		public static CXString* getCursorUSR(CXString* ret, CXCursor* c) { *ret = c_getCursorUSR(*c); return ret; }
		public static CXType* getCursorType(CXType* ret, CXCursor* c) { *ret = c_getCursorType(*c); return ret; }
		public static CXCursor* getCursorDefinition(CXCursor* ret, CXCursor* c) { *ret = c_getCursorDefinition(*c); return ret; }
		public static CXCursor* getCanonicalCursor(CXCursor* ret, CXCursor* c) { *ret = c_getCanonicalCursor(*c); return ret; }
		public static uint32 isCursorDefinition(CXCursor* c) => c_isCursorDefinition(*c);
		public static uint32 Cursor_isAnonymous(CXCursor* c) => c_Cursor_isAnonymous(*c);
		public static uint32 Cursor_isAnonymousRecordDecl(CXCursor* c) => c_Cursor_isAnonymousRecordDecl(*c);
		public static uint32 Cursor_isNull(CXCursor* c) => c_Cursor_isNull(*c);
		public static int32 Cursor_getStorageClass(CXCursor* c) => c_Cursor_getStorageClass(*c);
		public static int32 Cursor_getNumArguments(CXCursor* c) => c_Cursor_getNumArguments(*c);
		public static CXCursor* Cursor_getArgument(CXCursor* ret, CXCursor* c, uint32 index) { *ret = c_Cursor_getArgument(*c, index); return ret; }
		public static int64 Cursor_getOffsetOfField(CXCursor* c) => c_Cursor_getOffsetOfField(*c);
		public static uint32 Cursor_isBitField(CXCursor* c) => c_Cursor_isBitField(*c);
		public static int32 getFieldDeclBitWidth(CXCursor* c) => c_getFieldDeclBitWidth(*c);
		public static int64 getEnumConstantDeclValue(CXCursor* c) => c_getEnumConstantDeclValue(*c);
		public static uint64 getEnumConstantDeclUnsignedValue(CXCursor* c) => c_getEnumConstantDeclUnsignedValue(*c);
		public static CXType* getEnumDeclIntegerType(CXType* ret, CXCursor* c) { *ret = c_getEnumDeclIntegerType(*c); return ret; }
		public static CXType* getTypedefDeclUnderlyingType(CXType* ret, CXCursor* c) { *ret = c_getTypedefDeclUnderlyingType(*c); return ret; }
		public static uint32 Cursor_isMacroFunctionLike(CXCursor* c) => c_Cursor_isMacroFunctionLike(*c);
		public static uint32 Cursor_isMacroBuiltin(CXCursor* c) => c_Cursor_isMacroBuiltin(*c);
		public static CXSourceLocation* getCursorLocation(CXSourceLocation* ret, CXCursor* c) { *ret = c_getCursorLocation(*c); return ret; }
		public static CXSourceRange* getCursorExtent(CXSourceRange* ret, CXCursor* c) { *ret = c_getCursorExtent(*c); return ret; }
		public static void* getIncludedFile(CXCursor* c) => c_getIncludedFile(*c);

		public static CXType* getCanonicalType(CXType* ret, CXType* t) { *ret = c_getCanonicalType(*t); return ret; }
		public static CXType* getPointeeType(CXType* ret, CXType* t) { *ret = c_getPointeeType(*t); return ret; }
		public static CXType* getResultType(CXType* ret, CXType* t) { *ret = c_getResultType(*t); return ret; }
		public static CXType* getArrayElementType(CXType* ret, CXType* t) { *ret = c_getArrayElementType(*t); return ret; }
		public static int64 getArraySize(CXType* t) => c_getArraySize(*t);
		public static CXType* getElementType(CXType* ret, CXType* t) { *ret = c_getElementType(*t); return ret; }
		public static int64 getNumElements(CXType* t) => c_getNumElements(*t);
		public static int32 getNumArgTypes(CXType* t) => c_getNumArgTypes(*t);
		public static CXType* getArgType(CXType* ret, CXType* t, uint32 index) { *ret = c_getArgType(*t, index); return ret; }
		public static uint32 isFunctionTypeVariadic(CXType* t) => c_isFunctionTypeVariadic(*t);
		public static int32 getFunctionTypeCallingConv(CXType* t) => c_getFunctionTypeCallingConv(*t);
		public static int64 Type_getSizeOf(CXType* t) => c_Type_getSizeOf(*t);
		public static int64 Type_getAlignOf(CXType* t) => c_Type_getAlignOf(*t);
		public static int64 Type_getOffsetOf(CXType* t, char8* field) => c_Type_getOffsetOf(*t, field);
		public static CXType* Type_getNamedType(CXType* ret, CXType* t) { *ret = c_Type_getNamedType(*t); return ret; }
		public static CXType* Type_getModifiedType(CXType* ret, CXType* t) { *ret = c_Type_getModifiedType(*t); return ret; }
		public static CXCursor* getTypeDeclaration(CXCursor* ret, CXType* t) { *ret = c_getTypeDeclaration(*t); return ret; }
		public static CXString* getTypeSpelling(CXString* ret, CXType* t) { *ret = c_getTypeSpelling(*t); return ret; }
		public static uint32 isConstQualifiedType(CXType* t) => c_isConstQualifiedType(*t);

		public static void getExpansionLocation(CXSourceLocation* loc, void** file, uint32* line, uint32* column, uint32* offset) => c_getExpansionLocation(*loc, file, line, column, offset);
		public static int32 Location_isInSystemHeader(CXSourceLocation* loc) => c_Location_isInSystemHeader(*loc);
		public static int32 Location_isFromMainFile(CXSourceLocation* loc) => c_Location_isFromMainFile(*loc);
		public static CXString* getFileName(CXString* ret, void* file) { *ret = c_getFileName(file); return ret; }

		public static void tokenize(void* tu, CXSourceRange* range, CXToken** tokens, uint32* count) => c_tokenize(tu, *range, tokens, count);
		public static CXString* getTokenSpelling(CXString* ret, void* tu, CXToken* token) { *ret = c_getTokenSpelling(tu, *token); return ret; }
		public static int32 getTokenKind(CXToken* token) => c_getTokenKind(*token);
#endif

		static bool sTried;
		static bool sLoaded;
		static String sError = new .() ~ delete _;
		static String sPath = new .() ~ delete _;
		static String sVersion = new .() ~ delete _;
		static String sResourceInclude = new .() ~ delete _;

		/// The DLL that was loaded ("" before a successful Load).
		public static StringView Path => sPath;
		/// `clang version 23.1.3 (...)`.
		public static StringView Version => sVersion;
		/// The builtin header folder that belongs to the loaded DLL (`<dll>\..\lib\clang\<major>\include`).
		public static StringView ResourceInclude => sResourceInclude;
		public static StringView Error => sError;
		public static bool IsLoaded => sLoaded;

#if BF_PLATFORM_WINDOWS
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern void* LoadLibraryExW(char16* name, void* file, uint32 flags);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern void* GetProcAddress(void* module, char8* name);
		const uint32 LOAD_WITH_ALTERED_SEARCH_PATH = 0x00000008;
#endif

		/// Where the library is looked for, in order.
		/// Windows: TREADLE_LIBCLANG (the DLL or a folder holding it or its bin\), tools\libclang\bin next
		/// to the running exe (a package) or of the source tree above it, the exe's own folder, then (unless
		/// TREADLE_NO_FALLBACK) TREADLE_DEV_LIBCLANG (a developer-machine copy outside the checkout, the DLL
		/// or a folder holding it or its bin\) and C:\Program Files\LLVM\bin (the LLVM installer's).
		/// Linux: TREADLE_LIBCLANG (the .so or a folder holding it or its lib/), `lib/libclang.so` of the
		/// LLVM root the back end uses (Treadle.Language.LlvmRoot: tools/llvm next to the exe or
		/// /usr/lib/llvm-22 from the distribution's libclang-22-dev), the distribution's versioned
		/// `libclang-<N>.so.1` names.
		public static void Candidates(System.Collections.List<String> outPaths)
		{
#if !BF_PLATFORM_WINDOWS
			String envL = scope .();
			if (Environment.GetEnvironmentVariable("TREADLE_LIBCLANG", envL) case .Ok && !envL.IsEmpty)
			{
				if (envL.Contains(".so"))
					outPaths.Add(new String(envL));
				else
				{
					outPaths.Add(new $"{envL}/libclang.so");
					outPaths.Add(new $"{envL}/lib/libclang.so");
				}
			}
			String root = scope .();
			Treadle.Language.LlvmRoot.Get(root);
			outPaths.Add(new $"{root}/lib/libclang.so");
			outPaths.Add(new $"/usr/lib/x86_64-linux-gnu/libclang-{Treadle.Language.LlvmRoot.PreferredLinuxVersion}.so.1");
			for (int v = 40; v >= 14; v--)
				outPaths.Add(new $"/usr/lib/x86_64-linux-gnu/libclang-{v}.so.1");
			return;
#else
			String env = scope .();
			if (Environment.GetEnvironmentVariable("TREADLE_LIBCLANG", env) case .Ok && !env.IsEmpty)
			{
				if (env.EndsWith(".dll", .OrdinalIgnoreCase))
					outPaths.Add(new String(env));
				else
				{
					outPaths.Add(new $"{env}\\libclang.dll");
					outPaths.Add(new $"{env}\\bin\\libclang.dll");
				}
			}
			String exe = scope .();
			Environment.GetExecutableFilePath(exe);
			String dir = scope .();
			System.IO.Path.GetDirectoryPath(exe, dir).IgnoreError();
			String up = scope .(dir);
			for (int i < 8)
			{
				let candidate = scope String()..AppendF("{}\\tools\\libclang\\bin\\libclang.dll", up);
				if (File.Exists(candidate))
				{
					outPaths.Add(new String(candidate));
					break;
				}
				String parent = scope .();
				if (System.IO.Path.GetDirectoryPath(up, parent) case .Err || parent.IsEmpty || parent == up)
					break;
				up.Set(parent);
			}
			outPaths.Add(new $"{dir}\\libclang.dll");
			if (Treadle.Language.LlvmRoot.NoFallback)
				return; // TREADLE_NO_FALLBACK: no machine paths (a package is tested with its own copy only)
			String dev = scope .();
			if (Environment.GetEnvironmentVariable("TREADLE_DEV_LIBCLANG", dev) case .Ok && !dev.IsEmpty)
			{
				if (dev.EndsWith(".dll", .OrdinalIgnoreCase))
					outPaths.Add(new String(dev));
				else
				{
					outPaths.Add(new $"{dev}\\libclang.dll");
					outPaths.Add(new $"{dev}\\bin\\libclang.dll");
				}
			}
			outPaths.Add(new String("C:\\Program Files\\LLVM\\bin\\libclang.dll"));
#endif
		}

		/// Loads libclang.dll / libclang.so (once). False with `Error` set when no candidate loads.
		public static bool Load()
		{
			if (sTried)
				return sLoaded;
			sTried = true;
#if !BF_PLATFORM_WINDOWS
			System.Collections.List<String> candidatesL = scope .();
			defer { ClearAndDeleteItems!(candidatesL); }
			Candidates(candidatesL);
			void* lib = null;
			for (let c in candidatesL)
			{
				if (!File.Exists(c))
					continue;
				lib = Internal.LoadSharedLibrary(c.CStr());
				if (lib != null)
				{
					sPath.Set(c);
					break;
				}
			}
			if (lib == null)
			{
				sError.Set("libclang.so was not found (TREADLE_LIBCLANG, or the distribution's libclang-22-dev: docs/Linux.md)");
				return false;
			}
			bool okL = true;
			void* SymL(char8* name)
			{
				let p = Internal.GetSharedProcAddress(lib, name);
				if (p == null)
				{
					if (okL)
						sError.AppendF("{} has no {}", sPath, StringView(name));
					okL = false;
				}
				return p;
			}
			createIndex = (.)SymL("clang_createIndex");
			disposeIndex = (.)SymL("clang_disposeIndex");
			parseTranslationUnit2 = (.)SymL("clang_parseTranslationUnit2");
			disposeTranslationUnit = (.)SymL("clang_disposeTranslationUnit");
			getNumDiagnostics = (.)SymL("clang_getNumDiagnostics");
			getDiagnostic = (.)SymL("clang_getDiagnostic");
			getDiagnosticSeverity = (.)SymL("clang_getDiagnosticSeverity");
			disposeDiagnostic = (.)SymL("clang_disposeDiagnostic");
			File_isEqual = (.)SymL("clang_File_isEqual");
			disposeTokens = (.)SymL("clang_disposeTokens");
			c_formatDiagnostic = (.)SymL("clang_formatDiagnostic");
			c_getClangVersion = (.)SymL("clang_getClangVersion");
			c_getCString = (.)SymL("clang_getCString");
			c_disposeString = (.)SymL("clang_disposeString");
			c_getTranslationUnitCursor = (.)SymL("clang_getTranslationUnitCursor");
			c_visitChildren = (.)SymL("clang_visitChildren");
			c_getCursorKind = (.)SymL("clang_getCursorKind");
			c_getCursorSpelling = (.)SymL("clang_getCursorSpelling");
			c_getCursorUSR = (.)SymL("clang_getCursorUSR");
			c_getCursorType = (.)SymL("clang_getCursorType");
			c_getCursorDefinition = (.)SymL("clang_getCursorDefinition");
			c_getCanonicalCursor = (.)SymL("clang_getCanonicalCursor");
			c_isCursorDefinition = (.)SymL("clang_isCursorDefinition");
			c_Cursor_isAnonymous = (.)SymL("clang_Cursor_isAnonymous");
			c_Cursor_isAnonymousRecordDecl = (.)SymL("clang_Cursor_isAnonymousRecordDecl");
			c_Cursor_isNull = (.)SymL("clang_Cursor_isNull");
			c_Cursor_getStorageClass = (.)SymL("clang_Cursor_getStorageClass");
			c_Cursor_getNumArguments = (.)SymL("clang_Cursor_getNumArguments");
			c_Cursor_getArgument = (.)SymL("clang_Cursor_getArgument");
			c_Cursor_getOffsetOfField = (.)SymL("clang_Cursor_getOffsetOfField");
			c_Cursor_isBitField = (.)SymL("clang_Cursor_isBitField");
			c_getFieldDeclBitWidth = (.)SymL("clang_getFieldDeclBitWidth");
			c_getEnumConstantDeclValue = (.)SymL("clang_getEnumConstantDeclValue");
			c_getEnumConstantDeclUnsignedValue = (.)SymL("clang_getEnumConstantDeclUnsignedValue");
			c_getEnumDeclIntegerType = (.)SymL("clang_getEnumDeclIntegerType");
			c_getTypedefDeclUnderlyingType = (.)SymL("clang_getTypedefDeclUnderlyingType");
			c_Cursor_isMacroFunctionLike = (.)SymL("clang_Cursor_isMacroFunctionLike");
			c_Cursor_isMacroBuiltin = (.)SymL("clang_Cursor_isMacroBuiltin");
			c_getCursorLocation = (.)SymL("clang_getCursorLocation");
			c_getCursorExtent = (.)SymL("clang_getCursorExtent");
			c_getIncludedFile = (.)SymL("clang_getIncludedFile");
			c_getCanonicalType = (.)SymL("clang_getCanonicalType");
			c_getPointeeType = (.)SymL("clang_getPointeeType");
			c_getResultType = (.)SymL("clang_getResultType");
			c_getArrayElementType = (.)SymL("clang_getArrayElementType");
			c_getArraySize = (.)SymL("clang_getArraySize");
			c_getElementType = (.)SymL("clang_getElementType");
			c_getNumElements = (.)SymL("clang_getNumElements");
			c_getNumArgTypes = (.)SymL("clang_getNumArgTypes");
			c_getArgType = (.)SymL("clang_getArgType");
			c_isFunctionTypeVariadic = (.)SymL("clang_isFunctionTypeVariadic");
			c_getFunctionTypeCallingConv = (.)SymL("clang_getFunctionTypeCallingConv");
			c_Type_getSizeOf = (.)SymL("clang_Type_getSizeOf");
			c_Type_getAlignOf = (.)SymL("clang_Type_getAlignOf");
			c_Type_getOffsetOf = (.)SymL("clang_Type_getOffsetOf");
			c_Type_getNamedType = (.)SymL("clang_Type_getNamedType");
			c_Type_getModifiedType = (.)SymL("clang_Type_getModifiedType");
			c_getTypeDeclaration = (.)SymL("clang_getTypeDeclaration");
			c_getTypeSpelling = (.)SymL("clang_getTypeSpelling");
			c_isConstQualifiedType = (.)SymL("clang_isConstQualifiedType");
			c_getExpansionLocation = (.)SymL("clang_getExpansionLocation");
			c_Location_isInSystemHeader = (.)SymL("clang_Location_isInSystemHeader");
			c_Location_isFromMainFile = (.)SymL("clang_Location_isFromMainFile");
			c_getFileName = (.)SymL("clang_getFileName");
			c_tokenize = (.)SymL("clang_tokenize");
			c_getTokenSpelling = (.)SymL("clang_getTokenSpelling");
			c_getTokenKind = (.)SymL("clang_getTokenKind");
			if (!okL)
				return false;
			CXString vL = default;
			getClangVersion(&vL);
			Take(ref vL, sVersion);
			FindResourceInclude();
			sLoaded = true;
			return true;
#else
			System.Collections.List<String> candidates = scope .();
			defer { ClearAndDeleteItems!(candidates); }
			Candidates(candidates);
			void* module = null;
			for (let c in candidates)
			{
				if (!File.Exists(c))
					continue;
				module = LoadLibraryExW(c.ToScopedNativeWChar!(), null, LOAD_WITH_ALTERED_SEARCH_PATH);
				if (module != null)
				{
					sPath.Set(c);
					break;
				}
			}
			if (module == null)
			{
				sError.Set("libclang.dll was not found (TREADLE_LIBCLANG, tools\\libclang\\bin from scripts\\get-libclang.ps1, next to the editor, C:\\Program Files\\LLVM\\bin)");
				return false;
			}
			bool ok = true;
			void* Sym(char8* name)
			{
				let p = GetProcAddress(module, name);
				if (p == null)
				{
					if (ok)
						sError.AppendF("{} has no {}", sPath, StringView(name));
					ok = false;
				}
				return p;
			}
			createIndex = (.)Sym("clang_createIndex");
			disposeIndex = (.)Sym("clang_disposeIndex");
			parseTranslationUnit2 = (.)Sym("clang_parseTranslationUnit2");
			disposeTranslationUnit = (.)Sym("clang_disposeTranslationUnit");
			getNumDiagnostics = (.)Sym("clang_getNumDiagnostics");
			getDiagnostic = (.)Sym("clang_getDiagnostic");
			getDiagnosticSeverity = (.)Sym("clang_getDiagnosticSeverity");
			formatDiagnostic = (.)Sym("clang_formatDiagnostic");
			disposeDiagnostic = (.)Sym("clang_disposeDiagnostic");
			getClangVersion = (.)Sym("clang_getClangVersion");
			getCString = (.)Sym("clang_getCString");
			disposeString = (.)Sym("clang_disposeString");
			getTranslationUnitCursor = (.)Sym("clang_getTranslationUnitCursor");
			visitChildren = (.)Sym("clang_visitChildren");
			getCursorKind = (.)Sym("clang_getCursorKind");
			getCursorSpelling = (.)Sym("clang_getCursorSpelling");
			getCursorUSR = (.)Sym("clang_getCursorUSR");
			getCursorType = (.)Sym("clang_getCursorType");
			getCursorDefinition = (.)Sym("clang_getCursorDefinition");
			getCanonicalCursor = (.)Sym("clang_getCanonicalCursor");
			isCursorDefinition = (.)Sym("clang_isCursorDefinition");
			Cursor_isAnonymous = (.)Sym("clang_Cursor_isAnonymous");
			Cursor_isAnonymousRecordDecl = (.)Sym("clang_Cursor_isAnonymousRecordDecl");
			Cursor_isNull = (.)Sym("clang_Cursor_isNull");
			Cursor_getStorageClass = (.)Sym("clang_Cursor_getStorageClass");
			Cursor_getNumArguments = (.)Sym("clang_Cursor_getNumArguments");
			Cursor_getArgument = (.)Sym("clang_Cursor_getArgument");
			Cursor_getOffsetOfField = (.)Sym("clang_Cursor_getOffsetOfField");
			Cursor_isBitField = (.)Sym("clang_Cursor_isBitField");
			getFieldDeclBitWidth = (.)Sym("clang_getFieldDeclBitWidth");
			getEnumConstantDeclValue = (.)Sym("clang_getEnumConstantDeclValue");
			getEnumConstantDeclUnsignedValue = (.)Sym("clang_getEnumConstantDeclUnsignedValue");
			getEnumDeclIntegerType = (.)Sym("clang_getEnumDeclIntegerType");
			getTypedefDeclUnderlyingType = (.)Sym("clang_getTypedefDeclUnderlyingType");
			Cursor_isMacroFunctionLike = (.)Sym("clang_Cursor_isMacroFunctionLike");
			Cursor_isMacroBuiltin = (.)Sym("clang_Cursor_isMacroBuiltin");
			getCursorLocation = (.)Sym("clang_getCursorLocation");
			getCursorExtent = (.)Sym("clang_getCursorExtent");
			getIncludedFile = (.)Sym("clang_getIncludedFile");
			getCanonicalType = (.)Sym("clang_getCanonicalType");
			getPointeeType = (.)Sym("clang_getPointeeType");
			getResultType = (.)Sym("clang_getResultType");
			getArrayElementType = (.)Sym("clang_getArrayElementType");
			getArraySize = (.)Sym("clang_getArraySize");
			getElementType = (.)Sym("clang_getElementType");
			getNumElements = (.)Sym("clang_getNumElements");
			getNumArgTypes = (.)Sym("clang_getNumArgTypes");
			getArgType = (.)Sym("clang_getArgType");
			isFunctionTypeVariadic = (.)Sym("clang_isFunctionTypeVariadic");
			getFunctionTypeCallingConv = (.)Sym("clang_getFunctionTypeCallingConv");
			Type_getSizeOf = (.)Sym("clang_Type_getSizeOf");
			Type_getAlignOf = (.)Sym("clang_Type_getAlignOf");
			Type_getOffsetOf = (.)Sym("clang_Type_getOffsetOf");
			Type_getNamedType = (.)Sym("clang_Type_getNamedType");
			Type_getModifiedType = (.)Sym("clang_Type_getModifiedType");
			getTypeDeclaration = (.)Sym("clang_getTypeDeclaration");
			getTypeSpelling = (.)Sym("clang_getTypeSpelling");
			isConstQualifiedType = (.)Sym("clang_isConstQualifiedType");
			getExpansionLocation = (.)Sym("clang_getExpansionLocation");
			Location_isInSystemHeader = (.)Sym("clang_Location_isInSystemHeader");
			Location_isFromMainFile = (.)Sym("clang_Location_isFromMainFile");
			getFileName = (.)Sym("clang_getFileName");
			File_isEqual = (.)Sym("clang_File_isEqual");
			tokenize = (.)Sym("clang_tokenize");
			getTokenSpelling = (.)Sym("clang_getTokenSpelling");
			getTokenKind = (.)Sym("clang_getTokenKind");
			disposeTokens = (.)Sym("clang_disposeTokens");
			if (!ok)
				return false;

			CXString v = default;
			getClangVersion(&v);
			Take(ref v, sVersion);
			FindResourceInclude();
			sLoaded = true;
			return true;
#endif
		}

		/// `<dll dir>\..\lib\clang\<major>\include`, else the first `lib\clang\*\include` there.
		static void FindResourceInclude()
		{
			String dllDir = scope .();
			System.IO.Path.GetDirectoryPath(sPath, dllDir).IgnoreError();
			String root = scope .();
			System.IO.Path.GetDirectoryPath(dllDir, root).IgnoreError();
			int major = 0;
			let at = sVersion.IndexOf("version ");
			if (at >= 0)
			{
				int i = at + 8;
				while (i < sVersion.Length && sVersion[i].IsDigit)
				{
					major = major * 10 + (sVersion[i] - '0');
					i++;
				}
			}
			let sep = System.IO.Path.DirectorySeparatorChar;
			let want = scope String()..AppendF("{0}{2}lib{2}clang{2}{1}{2}include", root, major, sep);
			if (Directory.Exists(want))
			{
				sResourceInclude.Set(want);
				return;
			}
			let clangDir = scope String()..AppendF("{0}{1}lib{1}clang", root, sep);
			if (Directory.Exists(clangDir))
				for (let e in Directory.EnumerateDirectories(clangDir))
				{
					let inc = scope String();
					e.GetFilePath(inc);
					inc.Append(sep);
					inc.Append("include");
					if (Directory.Exists(inc))
					{
						sResourceInclude.Set(inc);
						return;
					}
				}
		}

		/// Appends the text of `s` to `outText` and disposes it.
		public static void Take(ref CXString s, String outText)
		{
			let c = getCString(&s);
			if (c != null)
				outText.Append(StringView(c));
			disposeString(&s);
		}
	}
}
