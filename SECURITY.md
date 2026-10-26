# Security policy

## Reporting a vulnerability

Please report security problems privately and do not open a public issue for them.

Use GitHub private vulnerability reporting on this repository, https://github.com/AproposRobin/Treadle (Security tab,
"Report a vulnerability").

Include what you found, the version (`--version` on the editor's command line) and steps to reproduce. A small project
or graph file that shows the problem is the most useful attachment.

## What happens next

You get an acknowledgement within 7 days and a first assessment within 14 days. A fix ships in a new release; the release
notes describe the problem once users have had time to update. Reporters are credited if they want to be. These are
targets for a small volunteer project, not a service-level agreement.

## Supported versions

Only the latest release is supported.

## Scope

In scope: the editor; the readers and writers of project, type, layout and C import files; the compiler and the code it
generates (including the runtime library linked into every program); the C header import; the debugger integration; the
updater and its signature checks; the native host; the build and packaging scripts.

Out of scope: problems in third-party components (LLVM, clang, lld, lldb, libclang, SDL2, Dear ImGui and the others in
THIRD_PARTY.md: report them to their authors), the behaviour of a program you wrote and built yourself, and findings that
need an already-compromised PC.
