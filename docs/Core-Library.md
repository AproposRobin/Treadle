---
audience: user
title: Core library
summary: The types every Treadle program has without importing anything: strings, collections, files, math, console, time, environment and processes, threads, Option / Result; who owns what, the API by type, number formats, UTF-8, and what is not there yet.
order: 9
---

# Core library

The core library is the set of types every program has: String, StringView, List, Dictionary, HashSet, Queue,
Stack, File, Directory, Path, Math, Random, Console, Time, Stopwatch, Environment, Process, Thread, Mutex, ThreadPool,
Parallel, Option, Result and a few more. It is written in Treadle itself (graph files, one type per file) on top of the C
runtime. Its API follows the Beef corlib where a graph has no reason to differ, with Treadle's own words where they exist.

## 1. Where it is

Every program gets the core without a `uses` line or a project setting: `Core.List`, `Core.String` and the rest
are simply there. In the editor the core's types are in the Node menu's **Core** group (`Core | List`,
`Core | Dictionary`, ...; String and StringView under **Strings**, Math under **Math**); internal helpers are not
offered. The core's files are in the package's `core` folder; opening that folder as a project shows them.

## 2. How it is compiled

Only what a program reaches is compiled into it: a List of ints brings the List functions the program calls, for
`int`, and nothing else. Validate checks the project's own Sheets, not the core's. Reads of text are safe Pure
calls (value nodes); the core's own pointer work sits inside its Sheets, so no core function needs an Unsafe
Sheet to call. List and Dictionary keep their elements in arrays, so their storage is checked in Debug and is in
the Debug leak report like any object.

## 3. Who owns what

Beef's rules, unchanged:

| Thing | Owns | Does not own |
|---|---|---|
| `String` | its buffer (freed by its destructor; short text stays inside the object, 4) | - |
| `StringView` | nothing: a pointer and a length | the text; a view of a String is valid while the String lives and is not changed |
| `List<T>` | its storage array and the struct elements in it (3.1) | what elements refer to. A `List<String>` of Strings you made: call `DeleteAll` (needs `T : delete`), then Delete the list |
| `Dictionary<K,V>` | its three storage arrays and the struct keys and values in them (3.1) | what keys and values refer to. `DeleteKeys` / `DeleteValues` delete them (`K : delete` / `V : delete`), then Clear or Delete the dictionary |
| `HashSet<T>`, `Queue<T>`, `Stack<T>` | their storage and the struct values in it (3.1) | what values refer to (`HashSet.DeleteAll` deletes them) |
| `String.Concat(a, b)`, `String.Join(separator, parts)` | - | return a new String the caller owns (Delete it) |
| `File.ReadLines`, `Directory.GetFiles`, `Directory.GetDirectories` | - | add new Strings the caller owns (`List.DeleteAll`) |
| `String.Split`, `StringView.Split`, `Substring`, `Trim`, `Path.GetFileName` / `GetDirectory` / `GetExtension` | - | give views of the same text |
| `Environment.GetArg(i)` | - | a view valid until the program ends |
| `Environment.GetVariable(name)` | - | `Some(a new String)` the caller owns (Unwrap it, then Delete it) |
| `Process.Start(...)` | - | `Ok(a ProcessHandle)` the caller owns (Delete it; deleting does not end the program). The handle owns the runtime's process record and the captured output |
| `Process.Start(path, List<String> args, ...)` | - | reads the list's Strings while starting (copies them for the system); the list and its Strings stay the caller's |
| `ProcessHandle` | the runtime's process record and the captured stdout (freed by its destructor) | the program it started |
| `List.Slice`, `Span.Slice` | - | a `Span<T>`: a pointer and a length into the list's storage, valid until the list grows, shrinks or is deleted |
| `String.CodePoints()`, `StringView.CodePoints()` | - | a `CodePointEnumerator` holding a view of the text: valid while the text lives and is not changed |
| `Thread.Start(body)`, `ThreadPool.Run(work)` | the delegate from then on: deleted after it ran (on that thread), so make it with Allocation construct (Debug stops on a Local one) | - |
| `Thread` | its system thread record (Delete joins a thread still running, unless it was detached) | what the body uses: objects shared between threads are the program's to delete once no thread uses them |
| `Parallel.For` / `ForRange` / `ForEach` | - | the body: it runs only during the call, so a Local Lambda (by-reference captures too) is the usual one |
| `ThreadLocal<T>` | each thread's value (freed with the ThreadLocal, not destroyed) | what the values refer to |

Leaks are reported as before: a Construct whose object nobody deletes is listed at exit in Debug with the node that
made it; a Debug run that exits 0 with leaks returns the leak count. Buffers taken from `realloc`
(String's characters, File's read buffer) are not objects and are not in that report; the objects that own them are.

### 3.1 Moves: structs with a destructor in a collection

A struct is copied bit for bit wherever its value goes (a Set, a Call input, a Return, an element read).
For a struct that needs destroying (its own `~this`, an owned field, or a field of such a struct) a copy is
therefore one of two things:

* a **move**: the bits change place and only one place is ever destroyed (the place moved from is forgotten, or
  overwritten with `default` without a destructor);
* a **second owner**: both places would be destroyed, a double destruction. Check warns where a Set, a Call input
  or a Return copies such a struct out of a variable (T3064).

`[Copyable]` on a struct with a destructor says that second owners are meant: its destructor may run
once per copy (it counts, logs or releases nothing shared), and T3064 is not reported for it. Nothing else changes:
the collections below treat Copyable and other structs alike.

The core collections (List, Dictionary, HashSet, Queue, Stack) only ever move their elements:

| What | Rule |
|---|---|
| Put in: `Add`, `Insert`, `SetAt`, `SetItem`, `Add` / `TryAdd` (Dictionary), `HashSet.Add`, `Enqueue`, `Push` | the collection takes the value over (a move): pass a Make or a call's result straight in, or a variable you then forget |
| Grow (List, Dictionary rehash, Queue, Stack) | the elements move bit for bit into the new storage; the old storage is freed without running destructors (`Arrays.Free`, `Arrays.Grow`) |
| Shift (`Insert`, `RemoveAt`, `Reverse`, `Sort`, a Queue's wrap) | bit moves inside the storage; a slot left behind is set to `default` without a destructor |
| Remove or replace: `RemoveAt`, `Remove`, `SetAt` (the old element), `Dictionary.Remove`, `SetItem` of a key that is there (the old value), `HashSet.Remove`, `Clear` | the element is destroyed (`Arrays.DestroyAt`: the struct's complete destructor) |
| Take out: `Queue.Dequeue`, `Stack.Pop` | the value moves to the caller, who owns it from then on |
| Read: Get [ ], `Find`, `Peek`, For Each's element, `Current` | a bit copy the collection still owns: do not destroy it, do not keep it past the element's removal |
| Not taken: `TryAdd` / `HashSet.Add` of a key that is there (false) | nothing changes; the caller still owns the value it passed |
| Copied: `List.AddRange` | elements are copied, not moved: for a struct with a destructor both lists would own them (add them one by one as moves instead) |
| Delete the collection | the elements it holds (`[0, Count)`, never unused slots) are destroyed, then the storage is freed |

Elements that are numbers, references or plain structs (no destructor) are unaffected: `DestroyAt` is nothing for
them, and a reference element never deletes its object.

## 4. The API by type

Pure functions are value nodes; the others are flow calls. `T` is the element type.

**String** (class, sealed, implements IHashable): `this()`, `this(StringView text)`, `Length()`, `IsEmpty()`,
`View()`, `CStr()` (zero-terminated `char8*`), `Clear()`, `Set(StringView)`, `Append(StringView)`, `Append(char8)`,
`Append(int)`, `Append(float)` (7 significant digits), `Append(double)` (15), `Append(bool)` (`true` / `false`),
`Append(char32)` (the code point in UTF-8, 4.3), `AppendNumber(int / double / float value, format)` (a format spec,
4.2), `AppendF(format, arg0..arg5)` (generic overloads for none to six arguments; placeholders `{index[,width][:spec]}`,
4.2: each argument without a spec is written as its own `Append` writes it: any integer type, float, double, bool,
char8, char16 / char32 (as the character), String, StringView; `{{` / `}}` give a brace; a placeholder past the
arguments writes nothing; a brace that starts no placeholder stays as it is), `Replace(from, to)` (every occurrence,
left to right; an empty `from` changes nothing), `ToUpper()` / `ToLower()` (ASCII letters, in place), `Trim()` (in
place), `Equals(StringView)`, `CompareTo(StringView)`, `IndexOf(char8)`, `IndexOf(char32)` and `IndexOf(StringView)`
(byte positions), `Contains`, `StartsWith`, `EndsWith`, `Substring(start, length)` (a view; byte offsets),
`CodePointCount()`, `CodePoints()` (For Each over char32 code points, 4.3), `Split(separator, List<StringView> into,
skipEmpty = false)`, `GetHashCode()`, static `Concat(a, b)`, static `Join(separator, List<StringView>)` and
`Join(separator, List<String>)` (a new String). A String wires into any StringView input; a text literal on a String
input is a Local String of the function (freed when it returns); For Each over a String walks its bytes (`char8`s), For Each over
`CodePoints()` its characters.

**String's buffer.** A String keeps up to 23 bytes of text inside the object itself, so a short String (a Local
String in a loop, most AppendF results) never allocates. Longer text moves to a heap block that doubles in size each
time it fills (at least to what is needed), so appending is cheap on average; Clear keeps the buffer for reuse.
`Concat` allocates its result once, at the exact size. `GetHashCode` (String and StringView) is FNV-1a over the
bytes; `Equals`, `StartsWith`, `EndsWith` and `IndexOf(StringView)` compare bytes in bulk (`memcmp`), and
`Append(StringView)` copies them in one go.

**StringView** (struct, fields `Ptr`, `Length`; implements IHashable): `IsEmpty`, `Equals`, `EqualsIgnoreCase` (ASCII
letters without their case), `CompareTo`, `StartsWith`, `EndsWith`, `IndexOf(char8)`, `IndexOf(char32)`,
`IndexOf(StringView)`, `Contains`, `Substring(start, length)` (intrinsic, byte offsets, the range is not checked),
`Trim()` (spaces, tabs, line breaks at both ends), `GetHashCode()` (FNV-1a), `Split(separator, into, skipEmpty)`,
`CodePointCount()`, `CodePoints()`.

**List\<T>** (class): `this()`, `Count` (property), `Add`, `Insert(index, value)`, `RemoveAt(index)`,
`Remove(value) -> bool`, `SetAt(index, value)`, Get [ ] (`operator []`; an index out of range is a fatal error),
`Clear`, `IndexOf`, `Contains` (Hash.Equal: same text for strings), `FindIndex(delegate:bool(T) match) -> int`,
`Find(match, out item) -> bool`, `AddRange(List<T> other)`, `Reverse`, `Sort(delegate:int(T,T) comparer)` and
`Sort()` (section 4.4), `BinarySearch(value, comparer) -> int` (on a list sorted by that comparer: the index of an
equal element, any of several, or `-(insertion point) - 1`, so `~result` is where Insert keeps it sorted), `Slice(start, length) ->
Span<T>` (pure; a view of the storage, no copy; a range outside `[0, Count)` is a fatal error), `DeleteAll()` (`T :
delete`), `GetEnumerator()` (For Each, with `ListEnumerator<T>`). Structs with a destructor: section 3.1.

**Span\<T>** (struct, fields `Ptr`, `Length`): a pointer and a length over elements someone else owns (an array
converts to it; `List.Slice` makes one). Get [ ] and For Each read it (built in; in Debug an index outside
`0 .. Length - 1` is a fatal error naming the Index node, as for an array; Release does not check),
`Slice(start, length) -> Span<T>` (a range outside it is a fatal error), `IsEmpty()`, `Sort(comparer)` and `Sort()`
(section 4.4: a Slice of a List sorts that part of the list), `At(index)` and `SetAt(index, value)` (read and write an
element, the index checked in every config). **Kernel** (Index, BlockIndex, ThreadInBlock, BlockSize, Shared,
Barrier, RunCpu), **Gpu** (Upload, Download, Dispatch, DispatchAsync, Sync, IsAvailable, PrintInfo),
**GpuBuffer<T>** (on the GPU until Download; Upload, UploadAsync, DownloadAsync, Count; Construct with a Span or a
count), **GpuStream** (Sync) and **PinnedBuffer<T>** (page-locked host memory: AsSpan, Count) are the experimental,
NVIDIA-only GPU compute types ([GPU-Compute.md](GPU-Compute.md)).

**Dictionary\<K,V>** (class, `K : IHashable`; open addressing, grows at three quarters full): `this()`, `Count`,
`Add(key, value)` (a key already there is a fatal error), `TryAdd` (false when there), `SetItem(key, value)` (add or
replace), Get [ ] (`operator []`, a missing key is a fatal error), `TryGet(key, out item) -> bool`, `ContainsKey`,
`Remove(key) -> bool`, `Clear`, `DeleteKeys`, `DeleteValues`, `GetEnumerator()` (For Each gives `(K,V)` tuples:
Break them for `item0` and `item1`), `Keys()` and `Values()` (For Each over the keys or the values alone:
`DictionaryKeys<K,V>` / `DictionaryValues<K,V>`, structs that are their own enumerators). The dictionary must not
change while it is walked.

**Iteration order (decision): unordered.** A Dictionary (and so a HashSet) walks its entries in slot order:
where the hash put them, which is neither insertion order nor sorted, and which changes when the dictionary grows. It
is the same on every run, configuration and system for the same keys and the same history (the hash has no random
seed). Keeping insertion order would need Beef's layout (an entries array in insertion order plus a bucket array) in
place of the open addressing the core's Dictionary is built on: a rewrite of its Sheets, not done. For an
order, keep the keys in a List as they are added (the m3-files sample keeps first-seen order with a HashSet and a
Queue) or Sort the keys.

**HashSet\<T>** (class, `T : IHashable`; a `Dictionary<T,bool>` underneath): `this()`, `Count`, `Add(value) -> bool`
(false when it is there), `Contains`, `Remove(value) -> bool`, `Clear`, `DeleteAll()` (`T : delete`), For Each over
the values (slot order), and the set operations, which change this set in place: `Union(other)` (adds the values of
`other` it lacks, as copies, the way `List.AddRange` copies), `Intersect(other)` (removes the values not in `other`),
`Except(other)` (removes the values in `other`); a removed struct that has a destructor is destroyed.

**Queue\<T>** (class; a ring that doubles when full): `this()`, `Count`, `Enqueue(value)`, `Dequeue() -> T` (the
front value, now the caller's), `Peek() -> T`, `TryPeek(out item) -> bool` (false on an empty queue), `Clear`.
Dequeue and Peek of an empty queue are fatal errors.
**Stack\<T>** (class): `this()`, `Count`, `Push(value)`, `Pop() -> T`, `Peek() -> T`, `TryPeek(out item) -> bool`,
`Clear`; an empty stack's Pop and Peek are fatal errors. What Peek and TryPeek give is a read (3.1): a copy the
collection still owns.

**IHashable / IEquatable\<T>**: String and StringView implement IHashable; numbers, characters, bools and simple
enums satisfy `IHashable` and `IEquatable` constraints by value, and
a struct that implements an interface satisfies it without a Box. **Hash** (static, intrinsic): `Get<T>(value)`,
`Equal<T>(a, b)`, what the collections hash and compare with.

**Arrays** (static): `Set<T>(array, index, value)` (intrinsic, checked in Debug), `Fill`, `IndexOf`, `Contains`,
`Sort(array, comparer)` and `Sort(array)` (section 4.4; a null array is left alone); for
the collections (`internal`, not in the Node menu): `DestroyAt<T>(array, index)` and `Free<T>(array)` (intrinsic,
section 5), `DestroyRange<T>(array, start, count)`, `Grow<T>(array, count, capacity)`.

**File** (static; the runtime's `rt_fopen` and the C runtime's fread / fwrite / fclose; bytes as they are, no line-break conversion; paths are UTF-8, so non-ASCII names work on Windows too, through the wide calls):

`Exists(path)` (a file, not a directory), `ReadAllText(path, String into) -> bool` (appends), `WriteAllText(path,
text) -> bool` (makes or replaces), `ReadLines(path, List<String> into) -> bool` (one new String per line, without
`\n` or `\r\n`; no empty last line after a final line break), `Delete(path) -> bool`.
**Directory** (static): `Exists(path)`, `Create(path) -> bool` (with the missing folders
above it; true when it is there afterwards), `Delete(path) -> bool` (an empty directory), `GetFiles(path,
List<String> into) -> bool` and `GetDirectories(path, into) -> bool` (names, not paths, in the system's order: Sort
for a fixed one; no `.` and `..`).
**Path** (static, pure but Combine and ChangeExtension, which append to a String; `/` and `\` both separate):
`GetFileName(path)`, `GetDirectory(path)` (`"a/b/c.txt"` gives `"a/b"`, `"/c.txt"` gives `"/"`), `GetExtension(path)`
(with its dot: `".gz"` of `"a.tar.gz"`; empty when the file name has none), `ChangeExtension(path, extension, into)`
(a dot is added when the extension has none; an empty one removes it), `Combine(a, b, into)` (joins with `/` when
neither side has a separator there; `b` is not checked for being absolute). Paths are UTF-8 text relative to the
working folder unless absolute.

**Math** (static): `PI`, `E`, `Min`, `Max`, `Clamp` (generic with `operator<`), `Abs(int)`, `Abs(float)`, `Abs(double)`, `Sqrt`,
`Pow`, `Floor`, `Ceil`, `Round` (halves away from zero), `Truncate`, `Sin`, `Cos`, `Exp`, `Log` (LLVM intrinsics;
libm underneath), `Lerp(a, b, t)` (double and float overloads; `t` is not clamped), `Sign(int)` / `Sign(double)`
(-1, 0, 1; NaN gives 0), `IsNaN(double)`; every function of a `double` also has a `float` overload (`Sign(float)`, `IsNaN(float)`; an int argument picks the double one).
For the math library (4.5): `Tau` (2 PI), `Tan`, `Asin`, `Acos`, `Atan`, `Atan2(y, x)`, `Fma(a, b, c)` (one rounding),
`CopySign(x, sign)` (LLVM intrinsics), `Radians(degrees)`, `Degrees(radians)`, `SmoothStep(e0, e1, x)`, each for float
and double.

**Random** (class, xorshift64\*): `this()` (seeded from the clock), `this(int seed)`, `Seed(int)`, `Next()` (63
bits), `Next(maxExclusive)`, `Next(min, maxExclusive)`, `NextDouble()` in [0, 1), `NextFloat()` in [0, 1) (24
bits), `Range(float min, float max)` in [min, max). The same seed gives the same numbers on every run, configuration
and machine.

**Console** (static): `Write` / `WriteLine` of StringView, String, int, float, double, bool, char8; `WriteLine()`;
`ReadLine(String into) -> bool` (appends one line without its line break, `\r\n` or `\n`; false at the end of the
input when nothing was read); `Error(text)` and `ErrorLine(text)` write to stderr (what Write wrote to stdout is
flushed first).

**Time** (static): `Ticks()` (the high-resolution clock in ticks), `Frequency()`
(ticks per second), `Now()` (a DateTime in local time), `UtcNow()` (a DateTime in UTC), `Sleep(milliseconds)`.
**DateTime** (struct): fields `Year`, `Month` (1-12), `Day`, `Hour`, `Minute`, `Second`, `Millisecond`, `IsUtc`;
`ToString(into)` appends ISO 8601 to the second, `2026-10-25T14:03:07`, with a `Z` for UTC. A DateTime is its parts
only: no arithmetic, no days of the week, no time zones beyond local and UTC, no parsing.
**Stopwatch** (class): `this()`, `this(bool startNow)`, `Start`, `Stop`, `Reset`, `Restart`, `ElapsedTicks`,
`ElapsedMilliseconds`, `ElapsedMicroseconds`.

**Environment** (static): `ArgCount()`, `GetArg(index)` (the arguments after the program's name, as `Main(String[]
args)` gets them; an index out of range gives an empty view), `Exit(code)` (ends the program at once: no Defers, no
destructors, no Debug leak report), `GetVariable(name) -> Option<String>` (`Some(a new String the caller owns)`,
`None` when it is not set), `SetVariable(name, value) -> bool` (for this program and the programs it starts; false
for an empty name or one with a `=`; on Windows an empty value removes the variable, on Linux it stays, empty),
`RemoveVariable(name) -> bool`, `GetCurrentDirectory(into)`, `SetCurrentDirectory(path) -> bool`,
`GetExecutablePath(into)` (the full path), `GetMachineName(into)`, `IsWindows()` (pure). Names, values and paths are
UTF-8 (the runtime converts to and from UTF-16 on Windows).

**Process** (static): `Start(path, args = "", captureOutput = true) -> Result<ProcessHandle, ProcessError>`. `path` is
a path or a name the system finds on the PATH (`cmd`, `echo`). `args` is the command-line text after it: on Windows it
is passed on as it is and the program splits it (quote arguments with spaces, Windows' rules); on Linux `/bin/sh -c`
reads the quoted path and `args`, so the shell's rules apply (and its features: keep untrusted text out of `args`).
With `captureOutput` the program's stdout goes into the handle (its stdin and stderr are this program's); without, it
writes to this program's stdout, after what this program wrote so far (Start flushes it). `ProcessError`:
`NotFound` (no such program; on Linux checked before starting, on the PATH or at the path), `Failed`.
`Start(path, args: List<String>, captureOutput = true)` is the **argument list** form: each String reaches the program
as one argument, exactly as it is, and **no shell reads it** (Linux: `fork` + `execvp` with the list as `argv`;
Windows: each argument quoted for the program's splitter, `CommandLineToArgvW`'s rules, so spaces, quotes and
backslashes arrive unchanged). Use it whenever an argument comes from outside the program (a file name, user text);
the text form above is shell-interpreted on Linux. `Failed` also when an argument holds a zero byte.
**ProcessHandle** (class; the caller owns it): `Wait() -> int` (waits and gives the exit code; with captured output
it reads the output to its end first, so a program that writes a lot never blocks on a full pipe), `HasExited()`
(does not wait), `Kill() -> bool` (ends it at once: exit code 1 on Windows, 137 on Linux, SIGKILL), `ExitCode()`
(waits like Wait), `GetOutput(into)` (waits, then appends the captured stdout: bytes as they came, so lines end in
`\r\n` from most Windows programs). Deleting the handle frees it; a program still running keeps running.

**Event\<T>** (struct, `T : class`; `Event.treadle`): the storage of an event field (a field marked Event),
a List of the handlers made on the first `Add`. `Add(handler)`, `Remove(handler) -> bool` (the handler that is that
object, deleted), `Clear()` (deletes them all), `Count`, `At(index)` (internal: Invoke's loop). It owns the handlers:
its destructor deletes them and the list, and runs with the object that has the event. Programs use it through an
event's nodes, not by name.

**Option\<T>** (`Some(value)`, `None`): `IsSome`, `IsNone`, `Unwrap` (None is a fatal error), `UnwrapOr(fallback)`.
**Result\<T,E>** (`Ok(value)`, `Err(error)`): `IsOk`, `IsErr`, `Unwrap`, `UnwrapOr`, `Map<U>(delegate:U(T) mapper)`.

**Memory** (static): `Copy`, `Set`, `Compare` (unsafe, intrinsic), `ElementSize<T>(T*)` (intrinsic: the size of what
the pointer points at), `Resize<T>(T*, count)` (realloc of `count` elements; 0 frees). **Pointer** (static, unsafe,
intrinsic): `Add<T>(ptr, count)`, `Load<T>(ptr)`, `Store<T>(ptr, value)`.

**Build** (static, Pure, intrinsic): `IsDefined(name)` (bool) and `Value(name)` (StringView): the `define NAME` and
`define NAME=value` lines of the config being built (the project file's `config` section), as constants of the build;
the name is typed on the node, not wired. A Branch on `Build.IsDefined("PROFILE")` takes the same arm in every run.

**Threads** (classes unless it says otherwise):

* **Thread** (sealed): `this()`, `this(name)`, `this(name, stackSize)` (bytes; 0 or none: 1 MB); `Start(body) -> bool`
  runs `body` (a `delegate:void()`, made with Allocation construct: the thread owns it and deletes it when it returns)
  on a new thread, once; `Join()` waits for it; `Detach()` lets it run on by itself; `Name()`, `IsAlive()`, `Id()` (the
  system's thread id). Static: `Current()` (the Thread running this code, null on the main thread and on the pool's
  threads), `CurrentId()`, `CurrentName()` (`Main` on the main thread), `Sleep(milliseconds)`, `Yield()`,
  `HardwareThreads()`. Deleting a Thread joins it first when it is still running and not detached (a `Defer Delete`
  right after Start is a join at the end of the region).
* **Mutex** (sealed): `Lock()`, `Unlock()`, `TryLock() -> bool`. One thread holds it at a time; it is not recursive
  (Debug stops on a second Lock by the same thread, an Unlock by a thread that does not hold it, and a Delete while
  held).
* **LockGuard** (struct): a **Local LockGuard** over a Mutex (`set ctor (Mutex)`) locks it where the Local runs and
  unlocks it when the Local's region ends, by any way out (the end of a loop pass, a Return, a Break). This is the
  usual way to hold a Mutex: the region is the critical section.
* **Condition** (sealed): `Wait(mutex)` (with the Mutex held: lets it go, waits, holds it again), `WaitFor(mutex,
  milliseconds) -> bool` (false: the time ran out), `Signal()` (one waiter), `Broadcast()` (all). A wait can end without
  a Signal: wait in a loop that tests what you wait for.
* **WaitEvent** (sealed): `this()` (manual reset), `this(autoReset)`; `Set()`, `Reset()`, `Wait()`, `WaitFor(milliseconds)
  -> bool`. Manual reset lets every waiter through until Reset; auto reset lets one through and lowers itself.
* **ThreadLocal\<T>**: `Get() -> T` and `Set(value)`: each thread has its own value, `default` until it sets it.
* **ThreadPool** (static): `Run(work)` queues one call of `work` (a `delegate:void()` made with Allocation construct; the
  pool deletes it after it ran) on the pool's threads (one fewer than `HardwareThreads()`, at least one, named `Pool
  <n>`, started on first use); `WaitAll()` waits for everything queued so far; `Size()`. When the program ends, the
  pool finishes the work queued so far first.
* **Parallel** (static): `For(from, to, body)` calls `body(i)` (a `delegate:void(int)`) for every `i` from `from` up to
  `to`, on the pool's threads and the calling thread at once, and returns when all calls returned; `ForRange(from, to,
  body)` calls `body(lo, hi)` once per chunk of the range (for sums and counts: add up the chunk in a local, publish once
  with an Atomic call); `ForEach(span, body)` calls `body(element)` per element (a Lambda over `For`, one per instance
  of the generic function). The calls run in any order and at the
  same time: what they write must be one slot per index, Atomic calls, or under a Mutex.

Ownership across threads: an object may be made on one thread and deleted on another, once no thread uses it any
more (after Join, or under a Mutex); a **Local** stays on its thread (only a Parallel body, which runs during the
call, may use the Locals of the caller). Two threads writing the same variable without a Mutex or an Atomic call is
an error with no defined result in Debug and Release alike (Debug does not detect it). The collections and String are
not safe to change from several threads at once: lock around every use. In Debug, a leak made on a thread other than
the main one names that thread (`leak: ... made at <Sheet> node <id> on thread "worker 2"`), and so does a fatal error
on it (`fatal: ... on thread "worker 2"`).

Unchanged from milestone 2: `Object`, `Attribute`, `Runtime.Fatal`, `IDisposable`, `IComparable<T>`,
`IAllocator`, `Atomic`. There is no Using node, so `IDisposable` is only the interface.

**int64 and float literals.** `int64` stays `int` at the IR level (both 64-bit; the back end interns types by
their text and checks them by identity, so distinct types would need a cast from the front end at every
int / int64 meeting). The core therefore has no `int64` overloads and needs no `WriteLine64`-style names: an `int64`
converts to `int` implicitly and without loss, so `Console.WriteLine(int)`, `Append(int)` and AppendF print it
exactly. A `uint64` above `int`'s range prints negative through those overloads. Float literals take an `f` / `F`
suffix (float) or `d` / `D` (double); the plain form is a double (`1.25f`, `2.5d`, `0.1`).

### 4.1 Parsing

| Function | Gives |
|---|---|
| `Int.Parse(text) -> Result<int, ParseError>` | an optional `-` or `+`, an optional `0x` / `0X` (hex) or `0b` / `0B` (binary) prefix, digits; a `'` after a digit is skipped (`1'000`, Beef's rule). `int` is `int64` (4, "int64 and float literals"), so this is also the int64 parse: the range is int64's, hex and binary included (`0xFFFFFFFFFFFFFFFF` is Overflow, not -1) |
| `Double.Parse(text) -> Result<double, ParseError>` | an optional sign, digits with an optional `.` and fraction (a digit on at least one side: `.5`, `5.`), an optional exponent (`e` / `E`, a sign, digits), or `Infinity`, `Inf`, `NaN` in any case. Only `.` is a decimal separator (no culture). A value past the range is an infinity (Beef's rule), not Overflow |
| `Float.Parse(text) -> Result<float, ParseError>` | read as Double.Parse reads, rounded to a float (past its range: an infinity) |
| `Bool.Parse(text) -> Result<bool, ParseError>` | `true` / `false` in any letter case |
| `Int.TryParse`, `Double.TryParse`, `Float.TryParse`, `Bool.TryParse(text, out parsed) -> bool` | true and the value in `parsed`, or false and 0 / false. (The out is named `parsed`: a Call's own `result` pin is the bool) |

**ParseError** (payload enum): `NoValue` (empty, or no digits: `-`, `0x`), `Overflow` (Int only), `InvalidChar(position)`
(the byte position of the first character that does not belong; Bool gives 0). A Switch on it has a payload pin
`case:InvalidChar.position`. **White space is not skipped** (Beef's rule: `" 5"` is InvalidChar at 0); Trim first.
The parsers are the Treadle runtime's (a grammar check, then `strtod`), so they read the
same on every system and in any C locale.

### 4.2 Number formats and AppendF placeholders

A placeholder is **`{index[,width][:spec]}`**, Beef's and .NET's syntax (chosen over a Treadle one so that format
strings read the same as in Beef code):

| Part | Meaning |
|---|---|
| `index` | the argument, `0` to `5`; past the arguments the placeholder writes nothing |
| `,width` | pads with spaces to `width` characters: positive right-aligns (`{0,8}`), negative left-aligns (`{0,-8}`); a longer value is not cut. Width counts code points, so a non-ASCII character counts one (a character made of several code points, such as a letter with a combining accent, counts each) |
| `:spec` | a letter and an optional precision 0-99, for numbers (other arguments ignore it) |

| Spec | Gives (precision default) | `1234.5` | `255` |
|---|---|---|---|
| `F` / `f` | fixed decimals (2) | `F2`: `1234.50` | `F0`: `255` |
| `E` / `e` | scientific, the letter's case for the exponent (6) | `e2`: `1.23e+03` | `E1`: `2.6E+02` |
| `G` / `g` | general: significant digits, an exponent only when needed (15; a float 7) | `G3`: `1.23E+03` | `255` |
| `N` / `n` | fixed with `,` between thousands (2; an integer 0) | `N2`: `1,234.50` | `N0`: `255` |
| `D` / `d` | decimal with at least that many digits (a float rounded) | `D6`: `001235` | `D5`: `00255` |
| `X` / `x` | hex digits, upper / lower case, at least that many (64-bit two's complement for negatives) | `X`: `4D3` | `x4`: `00ff` |
| `B` / `b` | binary digits, at least that many | | `B`: `11111111`, `B10`: `0011111111` |
| none or unknown | the plain form, as `Append` writes it | `1234.5` | `255` |

**Thousands grouping is off by default**: only `N` groups. `{{` and `}}` are braces. A `{` that does not start a
whole placeholder (`{x}`, `{0`, `{1,}`) is text. The same specs work in `String.AppendNumber(value, spec)`,
`Int.ToString(value, into, spec)` and through `Double.ToString` / `Float.ToString(value, into, precision = -1, style
= FloatStyle.Fixed)` (FloatStyle: `Fixed` = F, `Scientific` = e, `General` = G; precision -1 is the style's default):
`Double.ToString(3.14159, s, 3)` appends `3.142`. Floating-point formatting is the C runtime's `snprintf` (rounding as
the CRT rounds: correctly rounded on both UCRT and glibc); integers in decimal, grouping, binary and padding are the
Treadle runtime's own (no `snprintf` for an integer). AppendF reads its format once, from left to right, and writes
each value straight into the String, so a short AppendF result costs no allocation (section 4, String's buffer).

### 4.3 Text is UTF-8

A String or StringView holds UTF-8 bytes. **Length is in bytes**; `CodePointCount()` counts code points (Unicode
characters; a byte that starts no valid sequence counts as one). Positions are byte offsets everywhere: `IndexOf`
(of a `char8`, a `char32` or a text) gives one, `Substring(start, length)` takes them, and a cut in the middle of a
character is the caller's mistake (the bytes are taken as they are). **For Each over `CodePoints()`** gives `char32`
elements, decoded from UTF-8 (`CodePointEnumerator`, its own enumerator; `Offset` is the byte position after the
current one); a byte that starts no valid sequence gives U+FFFD and the walk goes on with the next byte. For Each over
the String itself still walks its bytes. `Append(char32)` encodes; a surrogate or a value past U+10FFFF appends
U+FFFD. **Utf8** (static): `Validate(text) -> Result<int, int>` (Ok: the code point count; Err: the byte position of
the first byte that starts no valid sequence: overlong forms, surrogates, values past U+10FFFF and cut-off sequences
are invalid), `Decode(text, pos, out codePoint) -> int` (the bytes taken, 0 at the end), `EncodedLength(char32)`.
ToUpper / ToLower still change ASCII letters only, and comparisons are by bytes.

**The console (decision).** On Windows the runtime switches the console's output and input code pages to
UTF-8 (65001) before Main, in Debug and Release alike, and restores the previous ones at exit,
so `Console.WriteLine("Grüße ✓")` shows as written in
a console window and `ReadLine` gets UTF-8. Converting to UTF-16 in Console was the other choice; it was not taken
because the bytes then differ by destination (a console would get WriteConsoleW, a pipe or file the bytes), while
with the code page every destination gets the same UTF-8 bytes, as on Linux, where the runtime just writes bytes.
Without a console (redirected to a pipe or a file, as the fixtures run) nothing is switched. A program ended by
`Environment.Exit` restores the code pages too (atexit); a fatal error does not.

### 4.4 Sorting

`List.Sort`, `Arrays.Sort` and `Span.Sort` share one sort (the internal `Sorting` type): an **introsort**.
Quicksort partitions around the median of the first, middle and last elements (Hoare's scheme: both scans stop on
elements equal to the pivot, so a run of equal values splits in the middle instead of going quadratic); ranges of 16
or fewer elements are finished by insertion sort; a range still partitioning after 2 log2 n rounds is heapsorted.
So it is **O(n log n) in every case** (already sorted, reversed and all-equal inputs included), in place, with no
allocation and a recursion depth of at most log2 n (the smaller side is the recursive call).

| Overload | Order | When to use it |
|---|---|---|
| `Sort(delegate:int(T,T) comparer)` (List, Span), `Arrays.Sort(array, comparer)` | the comparer's: negative puts a before b, 0 is equal, positive puts a after b | any order: descending, by a field of a struct or object, by several keys, Strings (`(a, b) => a.CompareTo(b)`) |
| `Sort()` (List, Span), `Arrays.Sort(array)` | ascending by T's `operator <` (`T : operator<`, like Math.Min) | numbers, characters and types that define `<`: no delegate call per comparison, about 20% faster on ints |

**Not stable (decision).** Elements the comparer (or `<`) calls equal may end in any order. To keep an order
among equals, compare a second key, such as the original index, in the comparer. Reason: a stable merge sort needs
a buffer of n elements; the in-place introsort needs none.

The comparer is called with bit copies of elements the collection still owns (section 3.1: do not destroy them);
it must be consistent (if a is before b, b is not before a), else the order is unspecified, though every element
stays in the list exactly once. Elements move bit for bit, as section 3.1 says for Shift: no destructor runs on a
temporary, so a struct with a destructor is destroyed once, when it is removed or the list goes.

### 4.5 The math library

Vectors, matrices, rotations and shapes for games and graphics ([SIMD-and-Vectors.md 2](SIMD-and-Vectors.md#2-the-core-vector-math-library)),
one type file each in `TreadleCore/core`. They are plain structs laid out as C lays them out (`[CRepr]`; a `Vec3` is
three floats, 12 bytes, as in GLM, raylib and vertex buffers), so they go to C, files and GPU buffers as they are.
Every function is Pure (a value node) but `Mat3` / `Mat4.ToStd430`. Angles are radians; space is right-handed, Y up,
-Z forward; projections give depth 0 to 1 (Vulkan, D3D) with a `GL` form for -1 to 1.

| Type | Fields | What it is |
|---|---|---|
| `Vec2`, `Vec3`, `Vec4` | `X Y (Z W)`, float | A 2D / 3D / 4D vector: a position, a direction, a size |
| `Vec2d`, `Vec3d`, `Vec4d` | `X Y (Z W)`, double | The same in double (large worlds, tools) |
| `Mat3`, `Mat4` | columns `C0..C2: Vec3`, `C0..C3: Vec4` | A 3x3 / 4x4 matrix, column-major as GLSL and Vulkan lay it out: `M * v` transforms a column vector |
| `Quat` | `X Y Z W` (W real) | A rotation as a unit quaternion; `a * b` rotates by `b` first |
| `Color` | `R G B A`, float | A colour in linear light |
| `Color32` | `R G B A`, uint8 | A colour as four bytes, sRGB as images store it |
| `Rect`, `RectI` | `X Y Width Height`, float / int32 | A rectangle (`RectI` has SDL_Rect's layout); it holds X up to but not including X + Width |
| `AABB` | `Min Max: Vec3` | An axis-aligned box; `Empty` holds nothing and grows |
| `Plane` | `Normal: Vec3`, `D` | The points p with Dot(Normal, p) + D = 0; Normal's side is the front |
| `Ray` | `Origin Direction: Vec3` | A half-line; the Intersect functions give the distance `t` (the hit point is `At(t)`) |
| `Transform` | `Translation: Vec3`, `Rotation: Quat`, `Scale: Vec3` | Scale, then rotate, then move; `parent * child` |

| Type | Functions |
|---|---|
| every vector | static `Zero`, `One`, `UnitX`, `UnitY` (`UnitZ`, `UnitW`); `this(all)`; operators `+ - * /` (vector and vector, component by component), `*` and `/` with a number on either side of `*` (`v * 2`, `2 * v`, `v / 2`), unary `-`, `==` `!=` (exact); `Dot`, `Length`, `LengthSquared`, `Distance`, `DistanceSquared`, `Normalized` (zero stays zero), `Lerp(to, t)`, `Min`, `Max`, `Clamp(lo, hi)`, `Abs`, `Floor`, `Ceil`, `Round`, `Reflect(normal)`, `ProjectOnto(b)`, `AngleTo(b)`, `IsFinite`, `ApproxEquals(other, epsilon = 1e-5)` (each component within epsilon), `Scaled(k)`, `ToVector()` / static `FromVector` (the `float2` ... `double4` primitive) |
| `Vec2` | `Perpendicular` (-Y, X), `Cross` (a number), `Angle` (Atan2(Y, X)), static `FromAngle` |
| `Vec3` / `Vec4` | `Vec3.Cross`, `Vec3.XY`; `Vec4.XYZ`, static `Vec4.FromVec3(v, w)` |
| `Mat3`, `Mat4` | static `Identity`, `Zero`; `Get(row, col)`, `Column(i)`, `Row(i)`; operators `*` (matrix, matrix), `*` (matrix, vector), `*` (matrix, number), `+`, `-`, `==`; `Multiply`, `Transform(v)`, `Scaled`, `Transposed`, `Determinant`, `Inverted` (by cofactors; singular gives zeros), `TryInvert(out inverse) -> bool`, `ApproxEquals`, `ToStd430(Span<float>)` (Mat3 as three columns of 4) |
| `Mat4` builders | `Translation(v)`, `Scale(v)`, `RotationX / Y / Z(angle)`, `Rotation(q)`, `FromTRS(t, r, s)`, `LookAt(eye, target, up)`, `Perspective(fovY, aspect, near, far)` and `PerspectiveGL`, `Orthographic(left, right, bottom, top, near, far)` and `OrthographicGL`; `TransformPoint` (W = 1), `TransformVector` (W = 0), `TransformPerspective` (divides by W), `Upper3x3`, `InvertedAffine` (rotation, scale and translation only: faster) |
| `Mat3` builders | `FromQuat(q)`, `Scale(v)`, `RotationZ(angle)` |
| `Quat` | static `Identity`, `FromAxisAngle(axis, angle)`, `FromEuler(pitch, yaw, roll)` (roll about Z, then pitch about X, then yaw about Y), `FromMat3`, `LookRotation(forward, up)` (-Z to `forward`), `FromTo(from, to)`; operators `*` (quat, quat), `*` (quat, Vec3: rotates), `==`; `Multiply`, `Rotate(v)`, `Conjugate`, `Inverse`, `Normalized` (zero gives Identity), `Dot`, `Length`, `Slerp(to, t)` (the shorter arc), `Nlerp`, `AngleTo`, `ToMat3`, `ToMat4`, `ToAxisAngle(out axis) -> angle`, `ToEuler() -> Vec3` (pitch, yaw, roll), `ApproxEquals` (q and -q are equal) |
| `Color` | static `White Black Transparent Red Green Blue Yellow Cyan Magenta Gray`, `FromRGBA8(r, g, b, a = 255)` and `FromHex(0xRRGGBBAA)` (bytes / 255, no decoding), `FromSrgb(c)`; `ToSrgb`, `ToColor32` (encodes to sRGB, rounds to bytes), `WithAlpha`, `Premultiplied`, `Lerp`, `Scaled`; operators `+`, `*` (tint), `*` (colour, number), `==`; `ApproxEquals` |
| `Color32` | static `FromHex(0xRRGGBBAA)`; `ToHex`, `ToColor` (decodes sRGB), `==` |
| `Rect` | static `FromMinMax(min, max)`; `Min`, `Max`, `Center`, `Size`, `Contains(point)`, `Overlaps`, `Intersection` (none: zero size), `Union`, `Expanded(amount)`, `Translated(offset)`, `IsEmpty`, `==` |
| `RectI` | static `FromMinMax(minX, minY, maxX, maxY)`, `FromRect(rect)` (rounded outwards); `Contains(x, y)`, `ContainsPoint(Vec2)`, `Overlaps`, `Intersection`, `Union`, `Expanded`, `Translated(dx, dy)`, `Center` (a Vec2), `ToRect`, `IsEmpty`, `==` |
| `AABB` | static `Empty`, `FromCenterExtents`, `FromPoints(Span<Vec3>)`; `Center`, `Extents` (half the size), `Size`, `IsValid`, `Contains`, `Overlaps` (touching counts), `Union`, `Encapsulate(point)`, `Transformed(Mat4)` (Arvo's method), `ClosestPoint` |
| `Plane` | static `FromPointNormal`, `FromPoints(a, b, c)` (counter-clockwise is the front); `DistanceTo(p)` (signed), `Side(p)` (1, -1, 0), `Normalized`, `Project(p)` |
| `Ray` | `At(t)`, `IntersectAABB(box, out t)` (slabs; 0 when inside), `IntersectPlane(plane, out t)`, `IntersectSphere(center, radius, out t)`, `IntersectTriangle(a, b, c, out t)` (Moller-Trumbore, both faces) |
| `Transform` | static `Identity`; `ToMat4`, `TransformPoint`, `TransformVector`, `Inverse` (exact for a uniform scale; with a non-uniform scale and a rotation the shear is lost), operator `*` and `Compose(child)` (parent * child), `Lerp` (Slerp for the rotation), `ApproxEquals` |

**Operators with a number.** A type may declare an operator more than once with other input types (`Vec3 * Vec3`,
`Vec3 * float`, `float * Vec3`); the Operator node and a Math Expression pick the one that takes both sides' types,
and a literal beside such a type takes the number type (`v * 2` scales a Vec3, as `v * 2.0f` does). A compound Set
picks it the same way: `set op *=` on a Vec3, a Mat4 or a Color with a float (wired or a literal) scales the variable.

**Text.** `String.Append` has an overload for every math type (the extension `MathFormat`): vectors, quaternions,
colours and rectangles as `(1, 2.25, -0.5)`, matrices as their rows `[(1, 0, 0), (0, 1, 0), (0, 0, 1)]`, AABB, Ray
and Transform as their parts in brackets, each number as `Append(float)` writes it (7 significant digits; 15 for the
double vectors). AppendF uses them: `AppendF("at {0}", position)`. The vector primitives have one generic overload
(the extension `VectorFormat`, `Append<T>(value) where T : vector`): `float4(1, 2, 3, 4)` is `(1, 2, 3, 4)`, each lane as
Append writes a value of its type (a lane mask's lanes as `true` and `false`); AppendF takes vectors the same way.

**How they compute.** The Sheets of `Vec2` and `Vec4` (and the double forms) make the vector primitive from the
fields, operate on it and break it back (`float4(a.X, a.Y, a.Z, a.W) + float4(...)`): in Release a `Vec4` addition is
one `addps`, `Dot` a `mulps` and two shuffled adds. `Vec3` computes component by component (its 12 bytes do not
fill a `float4`, and repacking a Vec3 on every pass of a loop cost 15% in the n-body benchmark; per component it runs
as fast as C). For 16-byte aligned SIMD data use `float4` itself; `ToVector()` gives it.

## 5. What is intrinsic

A few functions are built into the compiler rather than written as Sheets: Console's Write / WriteLine / Error of
a StringView, the Math functions (Sqrt, Abs, Floor, Ceil, Round, Truncate, Sin, Cos, Tan, Asin, Acos, Atan, Atan2,
Pow, Exp, Log, Fma, CopySign; Min, Max and Clamp), Memory.Copy / Set / Compare, the unsafe Pointer functions, Arrays.Set, StringView.Substring, and the
hashing and equality the collections use (Hash.Get, Hash.Equal), and Build.IsDefined / Build.Value, which become
constants of the build. They behave like any other call. Everything
else is Sheets over the C runtime.

## 6. Not there yet

* Threads: no race detection (Debug finds a missing lock only by its effects), no reader-writer lock, semaphore,
  thread priority or results from pool work; `Thread.Start` and `ThreadPool.Run` check a Local delegate in Debug when
  they are called, not when the graph is validated; ThreadLocal values are not destroyed (keep plain values); a custom
  `IAllocator` shared by threads must lock by itself; `WaitAll` from queued work waits for itself.
* `IEnumerable` for user types beyond the enumerator protocol; enumerators of Queue and Stack (For Each over them).
* Dictionary and HashSet walk in slot order, not insertion order (4, "Iteration order"); Sort is not stable (4.4).
* Text: case mapping (ToUpper / ToLower) and comparisons are by ASCII letters and bytes, with no culture; AppendF's
  width counts code points, not grapheme clusters (a combining accent counts one); no UTF-16 conversion API (the
  runtime converts at the system's edges).
* Formats: no culture (always `.` and `,`), no custom patterns (`{0:0.00}`, `#`), no `P` (percent) or `C`
  (currency); a precision is at most 99.
* Parsing has no style flags (white space, a hex number without its prefix) and no unsigned parse (`uint64` above
  int64's range).
* DateTime is its parts only: no arithmetic, days of the week, time zones other than local and UTC, or parsing.
* Process: no stdin to write and no stderr to capture; the output is read when waiting (no streaming); the text form's
  `args` is the system's command line (shell-interpreted on Linux): pass a `List<String>` for one argument each.
* `Hash.Get` of a float truncates it to an integer (equal values hash equal; many collide).
* `StringView.Substring` does not check its range; the collections and spans check theirs (fatal errors).
* File has no streaming reads or writes (whole files only), no binary helpers beyond bytes in a String; Directory
  does not delete recursively; Path.Combine does not treat an absolute `b` specially.
* On Linux, File's reads, writes and Delete (`rt_fopen`, `rt_remove`) take a `\` as part of a name; File.Exists and
  Directory (the runtime) read it as a separator there, as on Windows.
* Vectors ([Language.md 2.8](Language.md#28-vectors-simd)): the vector types, their operators and the `Core.Vector`
  functions are the compiler's (intrinsics, no `.treadle` file); a vector primitive (`float4`) prints lane by lane
  (Break, then Console.Write of each lane), or as a math type (`Vec4.FromVector`, then Append).
* The math library (4.5): no `Mat4d` / `Quatd` (double matrices and rotations: on demand), no `Mat2`, no frustum type;
  `Transform.Inverse` loses the shear of a non-uniform scale with a rotation.

## 7. Example

The package's `samples\m3-core` project reads its arguments into a List of words, counts them in a Dictionary,
sorts them with a Lambda comparer, prints with AppendF and times itself with a Stopwatch. Run with the
arguments `"the cat and the hat" "and the bat"` (`Treadle.exe --build-run samples\m3-core -- "the cat and
the hat" "and the bat"`, Debug):

```
8 words, 5 different
  the: 3
  and: 2
  bat: 1
  cat: 1
  hat: 1
counted in 19 microseconds
--- exit code: 0
```

Without arguments it counts a built-in sentence (13 words, 10 different).
