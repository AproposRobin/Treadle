; hello.ll - hand-written LLVM IR probe for the Treadle native pipeline.
; Exercises: printf, a struct, a loop, a virtual call through a function-pointer table,
; and the C runtime shim (treadle_alloc / treadle_free / treadle_rt_report).
; The debug metadata at the bottom points at line numbers of THIS file, so a debugger can
; break on "hello.ll:<line>". Build with scripts\llbuild.ps1.
source_filename = "hello.ll"
target datalayout = "e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-w64-windows-gnu"

; struct Shape { ShapeVT* vt; int w; int h; }   struct ShapeVT { int (*area)(Shape*); const char* name; }
%Shape = type { ptr, i32, i32 }
%ShapeVT = type { ptr, ptr }

@.fmt_hello = private unnamed_addr constant [26 x i8] c"Treadle hello from %s %d\0A\00", align 1
@.fmt_loop = private unnamed_addr constant [18 x i8] c"loop sum 0..9=%d\0A\00", align 1
@.fmt_area = private unnamed_addr constant [14 x i8] c"%s area = %d\0A\00", align 1
@.who = private unnamed_addr constant [8 x i8] c"LLVM IR\00", align 1
@.name_rect = private unnamed_addr constant [5 x i8] c"Rect\00", align 1
@.name_square = private unnamed_addr constant [7 x i8] c"Square\00", align 1

; two "classes": the vtables are function-pointer tables
@vt_rect = dso_local constant %ShapeVT { ptr @rect_area, ptr @.name_rect }, align 8
@vt_square = dso_local constant %ShapeVT { ptr @square_area, ptr @.name_square }, align 8

declare dso_local i32 @printf(ptr, ...)
declare dso_local ptr @treadle_alloc(i64)
declare dso_local void @treadle_free(ptr)
declare dso_local i32 @treadle_rt_report()

define dso_local i32 @rect_area(ptr %self) #0 !dbg !20 {
  %wp = getelementptr inbounds %Shape, ptr %self, i32 0, i32 1
  %hp = getelementptr inbounds %Shape, ptr %self, i32 0, i32 2
  %w = load i32, ptr %wp, align 4, !dbg !21
  %h = load i32, ptr %hp, align 4, !dbg !21
  %a = mul nsw i32 %w, %h, !dbg !22
  ret i32 %a, !dbg !23
}

define dso_local i32 @square_area(ptr %self) #0 !dbg !24 {
  %wp = getelementptr inbounds %Shape, ptr %self, i32 0, i32 1
  %w = load i32, ptr %wp, align 4, !dbg !25
  %a = mul nsw i32 %w, %w, !dbg !25
  ret i32 %a, !dbg !26
}

define dso_local ptr @shape_new(ptr %vt, i32 %w, i32 %h) #0 !dbg !27 {
  %p = call ptr @treadle_alloc(i64 16), !dbg !28
  %vtp = getelementptr inbounds %Shape, ptr %p, i32 0, i32 0
  %wp = getelementptr inbounds %Shape, ptr %p, i32 0, i32 1
  %hp = getelementptr inbounds %Shape, ptr %p, i32 0, i32 2
  store ptr %vt, ptr %vtp, align 8, !dbg !29
  store i32 %w, ptr %wp, align 4, !dbg !29
  store i32 %h, ptr %hp, align 4, !dbg !29
  ret ptr %p, !dbg !30
}

; virtual call: load the table from the object, load slot 0, call through the pointer
define dso_local i32 @shape_area(ptr %self) #0 !dbg !31 {
  %vtp = getelementptr inbounds %Shape, ptr %self, i32 0, i32 0
  %vt = load ptr, ptr %vtp, align 8, !dbg !32
  %slot0 = getelementptr inbounds %ShapeVT, ptr %vt, i32 0, i32 0
  %fn = load ptr, ptr %slot0, align 8, !dbg !33
  %r = call i32 %fn(ptr %self), !dbg !34
  ret i32 %r, !dbg !35
}

define dso_local ptr @shape_name(ptr %self) #0 {
  %vtp = getelementptr inbounds %Shape, ptr %self, i32 0, i32 0
  %vt = load ptr, ptr %vtp, align 8
  %slot1 = getelementptr inbounds %ShapeVT, ptr %vt, i32 0, i32 1
  %n = load ptr, ptr %slot1, align 8
  ret ptr %n
}

define dso_local i32 @main() #0 !dbg !40 {
entry:
  %sum.addr = alloca i32, align 4
    #dbg_declare(ptr %sum.addr, !41, !DIExpression(), !42)
  store i32 0, ptr %sum.addr, align 4, !dbg !42
  %c0 = call i32 (ptr, ...) @printf(ptr @.fmt_hello, ptr @.who, i32 42), !dbg !43
  %rect = call ptr @shape_new(ptr @vt_rect, i32 3, i32 4), !dbg !44
  %square = call ptr @shape_new(ptr @vt_square, i32 5, i32 0), !dbg !44
  br label %loop, !dbg !45

loop:
  %i = phi i32 [ 0, %entry ], [ %i.next, %loop ]
    #dbg_value(i32 %i, !46, !DIExpression(), !47)
  %sq = mul nsw i32 %i, %i, !dbg !47
  %sum.old = load i32, ptr %sum.addr, align 4, !dbg !48
  %sum.new = add nsw i32 %sum.old, %sq, !dbg !48
  store i32 %sum.new, ptr %sum.addr, align 4, !dbg !48
  %i.next = add nsw i32 %i, 1, !dbg !49
  %again = icmp slt i32 %i.next, 10, !dbg !49
  br i1 %again, label %loop, label %done, !dbg !49

done:
  %sum = load i32, ptr %sum.addr, align 4, !dbg !50
  %c1 = call i32 (ptr, ...) @printf(ptr @.fmt_loop, i32 %sum), !dbg !50
  %ar = call i32 @shape_area(ptr %rect), !dbg !51
  %nr = call ptr @shape_name(ptr %rect), !dbg !51
  %c2 = call i32 (ptr, ...) @printf(ptr @.fmt_area, ptr %nr, i32 %ar), !dbg !52
  %as = call i32 @shape_area(ptr %square), !dbg !53
  %ns = call ptr @shape_name(ptr %square), !dbg !53
  %c3 = call i32 (ptr, ...) @printf(ptr @.fmt_area, ptr %ns, i32 %as), !dbg !53
  call void @treadle_free(ptr %rect), !dbg !54
  call void @treadle_free(ptr %square), !dbg !54
  %leaks = call i32 @treadle_rt_report(), !dbg !55
  ret i32 %leaks, !dbg !55
}

attributes #0 = { nounwind uwtable "target-cpu"="x86-64" }

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3, !4}
!llvm.ident = !{!5}

!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, producer: "treadle hand-written probe", isOptimized: false, runtimeVersion: 0, emissionKind: FullDebug, splitDebugInlining: false, nameTableKind: None)
!1 = !DIFile(filename: "hello.ll", directory: "C:/src/treadle/tools/probe")
!2 = !{i32 7, !"Dwarf Version", i32 4}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = !{i32 7, !"uwtable", i32 2}
!5 = !{!"treadle hand-written probe"}
!6 = !DIBasicType(name: "int", size: 32, encoding: DW_ATE_signed)
!7 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !8, size: 64)
!8 = distinct !DICompositeType(tag: DW_TAG_structure_type, name: "Shape", file: !1, line: 11, size: 128, elements: !9)
!9 = !{!10, !11, !12}
!10 = !DIDerivedType(tag: DW_TAG_member, name: "vt", scope: !8, file: !1, line: 11, baseType: !13, size: 64)
!11 = !DIDerivedType(tag: DW_TAG_member, name: "w", scope: !8, file: !1, line: 11, baseType: !6, size: 32, offset: 64)
!12 = !DIDerivedType(tag: DW_TAG_member, name: "h", scope: !8, file: !1, line: 11, baseType: !6, size: 32, offset: 96)
!13 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: null, size: 64)
!14 = !DISubroutineType(types: !15)
!15 = !{!6, !7}
!16 = !DISubroutineType(types: !17)
!17 = !{!6}
!18 = !DISubroutineType(types: !19)
!19 = !{!7, !13, !6, !6}
!20 = distinct !DISubprogram(name: "rect_area", scope: !1, file: !1, line: 30, type: !14, scopeLine: 30, flags: DIFlagPrototyped, spFlags: DISPFlagDefinition, unit: !0)
!21 = !DILocation(line: 33, column: 1, scope: !20)
!22 = !DILocation(line: 35, column: 1, scope: !20)
!23 = !DILocation(line: 36, column: 1, scope: !20)
!24 = distinct !DISubprogram(name: "square_area", scope: !1, file: !1, line: 39, type: !14, scopeLine: 39, flags: DIFlagPrototyped, spFlags: DISPFlagDefinition, unit: !0)
!25 = !DILocation(line: 42, column: 1, scope: !24)
!26 = !DILocation(line: 43, column: 1, scope: !24)
!27 = distinct !DISubprogram(name: "shape_new", scope: !1, file: !1, line: 46, type: !18, scopeLine: 46, flags: DIFlagPrototyped, spFlags: DISPFlagDefinition, unit: !0)
!28 = !DILocation(line: 47, column: 1, scope: !27)
!29 = !DILocation(line: 51, column: 1, scope: !27)
!30 = !DILocation(line: 54, column: 1, scope: !27)
!31 = distinct !DISubprogram(name: "shape_area", scope: !1, file: !1, line: 58, type: !14, scopeLine: 58, flags: DIFlagPrototyped, spFlags: DISPFlagDefinition, unit: !0)
!32 = !DILocation(line: 60, column: 1, scope: !31)
!33 = !DILocation(line: 62, column: 1, scope: !31)
!34 = !DILocation(line: 63, column: 1, scope: !31)
!35 = !DILocation(line: 64, column: 1, scope: !31)
!40 = distinct !DISubprogram(name: "main", scope: !1, file: !1, line: 75, type: !16, scopeLine: 75, flags: DIFlagPrototyped, spFlags: DISPFlagDefinition, unit: !0, retainedNodes: !56)
!41 = !DILocalVariable(name: "sum", scope: !40, file: !1, line: 77, type: !6)
!42 = !DILocation(line: 79, column: 1, scope: !40)
!43 = !DILocation(line: 80, column: 1, scope: !40)
!44 = !DILocation(line: 81, column: 1, scope: !40)
!45 = !DILocation(line: 83, column: 1, scope: !40)
!46 = !DILocalVariable(name: "i", scope: !40, file: !1, line: 86, type: !6)
!47 = !DILocation(line: 88, column: 1, scope: !40)
!48 = !DILocation(line: 90, column: 1, scope: !40)
!49 = !DILocation(line: 92, column: 1, scope: !40)
!50 = !DILocation(line: 98, column: 1, scope: !40)
!51 = !DILocation(line: 99, column: 1, scope: !40)
!52 = !DILocation(line: 101, column: 1, scope: !40)
!53 = !DILocation(line: 102, column: 1, scope: !40)
!54 = !DILocation(line: 105, column: 1, scope: !40)
!55 = !DILocation(line: 107, column: 1, scope: !40)
!56 = !{!41, !46}
