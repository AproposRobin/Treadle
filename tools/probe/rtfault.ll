; rtfault.ll - frees a block twice and leaks another on purpose, to show the Debug runtime counters.
; Debug build: two treadle_rt lines on stderr, exit code 2 (1 live block + 1 double free).
; Release build: no bookkeeping, exit code 0.
target datalayout = "e-m:w-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-w64-windows-gnu"

declare dso_local ptr @treadle_alloc(i64)
declare dso_local void @treadle_free(ptr)
declare dso_local i32 @treadle_rt_report()

define dso_local i32 @main() {
  %a = call ptr @treadle_alloc(i64 32)
  %b = call ptr @treadle_alloc(i64 64)
  call void @treadle_free(ptr %a)
  call void @treadle_free(ptr %a)
  %problems = call i32 @treadle_rt_report()
  ret i32 %problems
}
