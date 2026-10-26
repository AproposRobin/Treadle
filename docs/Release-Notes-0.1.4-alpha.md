# Treadle 0.1.4-alpha

A small fix release. Existing projects open unchanged. Unpack it into a new folder, or use
**Help > Check for Updates** from 0.1.2-alpha or 0.1.3-alpha.

## Fixes

* **The Disassembly panel works from the package.** It showed "llvm-objdump is missing" because the package did not
  include the tool. The package now ships `llvm-objdump` and `llvm-cxxfilt` in `tools/llvm`, about 0.9 MB on Windows
  and 0.9 MB on Linux. If the tool is ever missing, the message now reads "Disassembly needs llvm-objdump, which this
  package does not include", with a hint about the `TREADLE_LLVM` environment variable.

## Under investigation: the editor stops responding after it was in the background

On one Windows machine, Treadle stopped accepting clicks and keys after it had been in the background for a while.
The title bar buttons still worked. We could not reproduce it, so this release **does not claim a fix**. It adds
two things:

* When the window gets the focus back, a mouse button the editor still thinks is held down is released (its release
  went to another window), and a mouse capture with no button down is let go. When this happens, the session log
  gets a line "input path reset after ...".
* The session log (`%LOCALAPPDATA%\Treadle\logs\treadle-<date>.log` on Windows) now records when the window loses
  and regains the focus. If the editor stops drawing for more than 5 seconds, it also records
  "frame loop stalled N s" and where the editor was at that moment.

If it happens to you, please attach that log to a bug report.
