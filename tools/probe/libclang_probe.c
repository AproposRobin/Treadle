/*
 * libclang_probe.c - walks a C header with the libclang C API and prints the declarations a
 * compiler front end would import: functions (result + parameter types), structs/unions (fields),
 * typedefs (underlying type), enums (constants with values), plus global variables and macros
 * (object-like only, with their spelling) when -macros is given.
 *
 * Usage: libclang_probe [-macros] [-all] <header-or-source> [clang args...]
 *   By default only declarations from the main file are printed and the rest counted; -all prints
 *   everything that the translation unit pulls in (system headers included).
 * Output: one line per declaration, tab separated, plus a final "# counts" line.
 *
 * Built by docs\Toolchain.md, section "C header import": llvm-mingw clang against the clang-c
 * headers and libclang.dll of C:\Program Files\LLVM (the llvm-mingw package ships no libclang.dll).
 */
#include <clang-c/Index.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static int g_all = 0, g_macros = 0;
static long g_printed = 0, g_skipped = 0, g_functions = 0, g_structs = 0, g_typedefs = 0, g_enums = 0, g_macroCount = 0;

static void put(CXString s) { const char* c = clang_getCString(s); fputs(c ? c : "", stdout); clang_disposeString(s); }

static int in_main_file(CXCursor c) {
    CXSourceLocation loc = clang_getCursorLocation(c);
    return clang_Location_isFromMainFile(loc);
}

static enum CXChildVisitResult fields(CXCursor c, CXCursor parent, CXClientData d) {
    (void)parent; (void)d;
    enum CXCursorKind k = clang_getCursorKind(c);
    if (k == CXCursor_FieldDecl) {
        fputs("\t  field\t", stdout); put(clang_getCursorSpelling(c)); fputs(" : ", stdout);
        put(clang_getTypeSpelling(clang_getCursorType(c)));
        printf(" @%lld\n", clang_Cursor_getOffsetOfField(c) / 8);
    } else if (k == CXCursor_EnumConstantDecl) {
        fputs("\t  const\t", stdout); put(clang_getCursorSpelling(c));
        printf(" = %lld\n", clang_getEnumConstantDeclValue(c));
    }
    return CXChildVisit_Continue;
}

static enum CXChildVisitResult visit(CXCursor c, CXCursor parent, CXClientData d) {
    (void)parent; (void)d;
    enum CXCursorKind k = clang_getCursorKind(c);
    int interesting = (k == CXCursor_FunctionDecl || k == CXCursor_StructDecl || k == CXCursor_UnionDecl ||
                       k == CXCursor_TypedefDecl || k == CXCursor_EnumDecl || k == CXCursor_VarDecl ||
                       (g_macros && k == CXCursor_MacroDefinition));
    if (!interesting) return CXChildVisit_Continue;
    if (!g_all && !in_main_file(c)) { g_skipped++; return CXChildVisit_Continue; }
    g_printed++;
    switch (k) {
    case CXCursor_FunctionDecl: {
        CXType ft = clang_getCursorType(c);
        int n = clang_Cursor_getNumArguments(c), i;
        g_functions++;
        fputs("function\t", stdout); put(clang_getCursorSpelling(c)); fputs("\t", stdout);
        put(clang_getTypeSpelling(clang_getResultType(ft))); fputs("\t(", stdout);
        for (i = 0; i < n; i++) {
            CXCursor a = clang_Cursor_getArgument(c, (unsigned)i);
            if (i) fputs(", ", stdout);
            put(clang_getTypeSpelling(clang_getCursorType(a))); fputs(" ", stdout); put(clang_getCursorSpelling(a));
        }
        if (clang_isFunctionTypeVariadic(ft)) fputs(n ? ", ..." : "...", stdout);
        fputs(")", stdout);
        if (clang_getFunctionTypeCallingConv(ft) == CXCallingConv_X86StdCall) fputs("\tstdcall", stdout);
        fputs("\n", stdout);
        break; }
    case CXCursor_StructDecl: case CXCursor_UnionDecl: {
        CXType t = clang_getCursorType(c);
        g_structs++;
        fputs(k == CXCursor_StructDecl ? "struct\t" : "union\t", stdout); put(clang_getCursorSpelling(c));
        if (clang_isCursorDefinition(c)) { printf("\tsize=%lld align=%lld\n", clang_Type_getSizeOf(t), clang_Type_getAlignOf(t)); clang_visitChildren(c, fields, NULL); }
        else fputs("\t(opaque)\n", stdout);
        break; }
    case CXCursor_TypedefDecl:
        g_typedefs++;
        fputs("typedef\t", stdout); put(clang_getCursorSpelling(c)); fputs("\t= ", stdout);
        put(clang_getTypeSpelling(clang_getTypedefDeclUnderlyingType(c)));
        { CXType canon = clang_getCanonicalType(clang_getCursorType(c)); fputs("\tcanonical ", stdout); put(clang_getTypeSpelling(canon)); }
        fputs("\n", stdout);
        break;
    case CXCursor_EnumDecl:
        g_enums++;
        fputs("enum\t", stdout); put(clang_getCursorSpelling(c)); fputs("\t: ", stdout);
        put(clang_getTypeSpelling(clang_getEnumDeclIntegerType(c))); fputs("\n", stdout);
        clang_visitChildren(c, fields, NULL);
        break;
    case CXCursor_VarDecl:
        fputs("var\t", stdout); put(clang_getCursorSpelling(c)); fputs("\t: ", stdout);
        put(clang_getTypeSpelling(clang_getCursorType(c))); fputs("\n", stdout);
        break;
    case CXCursor_MacroDefinition: {
        CXSourceRange r = clang_getCursorExtent(c);
        CXToken* toks = NULL; unsigned n = 0, i;
        CXTranslationUnit tu = clang_Cursor_getTranslationUnit(c);
        if (clang_Cursor_isMacroFunctionLike(c)) { g_printed--; return CXChildVisit_Continue; }
        g_macroCount++;
        fputs("macro\t", stdout); put(clang_getCursorSpelling(c)); fputs("\t", stdout);
        clang_tokenize(tu, r, &toks, &n);
        for (i = 1; i < n; i++) { put(clang_getTokenSpelling(tu, toks[i])); fputs(" ", stdout); }
        clang_disposeTokens(tu, toks, n);
        fputs("\n", stdout);
        break; }
    default: break;
    }
    return CXChildVisit_Continue;
}

int main(int argc, char** argv) {
    int i = 1;
    const char* file;
    CXIndex idx; CXTranslationUnit tu = NULL; enum CXErrorCode err; unsigned opts, ndiag, d;
    while (i < argc && argv[i][0] == '-' && argv[i][1] != 'I' && argv[i][1] != 'D') {
        if (!strcmp(argv[i], "-all")) g_all = 1;
        else if (!strcmp(argv[i], "-macros")) g_macros = 1;
        else { fprintf(stderr, "unknown option %s\n", argv[i]); return 2; }
        i++;
    }
    if (i >= argc) { fprintf(stderr, "usage: libclang_probe [-all] [-macros] <file> [clang args...]\n"); return 2; }
    file = argv[i++];
    idx = clang_createIndex(0, 0);
    opts = CXTranslationUnit_SkipFunctionBodies | CXTranslationUnit_KeepGoing;
    if (g_macros) opts |= CXTranslationUnit_DetailedPreprocessingRecord;
    err = clang_parseTranslationUnit2(idx, file, (const char* const*)(argv + i), argc - i, NULL, 0, opts, &tu);
    if (err != CXError_Success || !tu) { fprintf(stderr, "parse failed: error %d\n", (int)err); return 1; }
    ndiag = clang_getNumDiagnostics(tu);
    for (d = 0; d < ndiag; d++) {
        CXDiagnostic dg = clang_getDiagnostic(tu, d);
        if (clang_getDiagnosticSeverity(dg) >= CXDiagnostic_Error) { fputs("diag\t", stderr); CXString s = clang_formatDiagnostic(dg, clang_defaultDiagnosticDisplayOptions()); fputs(clang_getCString(s), stderr); fputs("\n", stderr); clang_disposeString(s); }
        clang_disposeDiagnostic(dg);
    }
    clang_visitChildren(clang_getTranslationUnitCursor(tu), visit, NULL);
    printf("# counts\tprinted=%ld skipped(other files)=%ld functions=%ld structs=%ld typedefs=%ld enums=%ld macros=%ld diagnostics=%u\n",
           g_printed, g_skipped, g_functions, g_structs, g_typedefs, g_enums, g_macroCount, ndiag);
    clang_disposeTranslationUnit(tu);
    clang_disposeIndex(idx);
    return 0;
}
