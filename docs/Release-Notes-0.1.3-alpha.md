# Treadle 0.1.3-alpha

A fix release for Run and for updating. Existing projects open unchanged. Unpack it into a new folder, or use
**Help > Check for Updates** from 0.1.2-alpha.

## Run

* **Program output appears while the program runs.** A program that prints a line and then keeps going (a loop, a
  server, a game) used to show nothing until it ended. Lines now arrive as the program writes them, in the
  **Debug Output** panel (the Output Log keeps the first 500 lines and the exit code), the same place F5 uses.
* **Console projects run in a console window of their own.** Run on a `console` project opens the program in its own
  window, as a command-line program would. **Editor Preferences > Build > Run console programs in a console window**
  (on by default) turns that off, and the output comes into the editor instead. Windowed and library projects always
  show their output in the editor. **Stop Program** ends the program and what it started in both modes.
* **A program that prints without end no longer freezes the editor.** The editor reads the output on its own thread,
  keeps the last 20,000 lines, shows one row "... N lines skipped" for the ones it dropped, and draws only the rows in
  view. Stop ends the program within a moment. **Also write program output to build/run.log** (Editor Preferences >
  Build, off by default) saves every line to a file in the project, emptied at each Run, so nothing is lost.

## Updating

* **The update notice works on the start page.** Update now, What changed, Later, Skip this version and Restart to
  finish did nothing while no project was open; they work now.
* **The installer shows what it is doing.** While an update is installed a small window shows "Installing Treadle
  <version>: n of N files" with a progress bar, and the installer copies only the files that changed, so an update
  takes a fraction of the time. (The window and the saving come from the installed version: updating *from* 0.1.2-alpha
  still copies every file, and the next update uses the new way.) Linux has no window; the log shows the same counts.
