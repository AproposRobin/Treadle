# Treadle 0.1.5-alpha

A small fix release. Existing projects open unchanged. Unpack it into a new folder, or use
**Help > Check for Updates** from 0.1.2-alpha, 0.1.3-alpha or 0.1.4-alpha.

## Fixes

* **The editor survives a lost graphics device.** After the computer slept or was locked, after a graphics driver
  reset, a monitor or display-scale change, or when a laptop switched graphics chips, the editor window could stop
  drawing: it stayed black or frozen while its title bar buttons still worked. Treadle now notices when its drawing
  context is lost or no longer usable and rebuilds it by itself. Your open files, undo history and autosave are not
  touched.
* **Window > Restore Graphics** (**Ctrl+Alt+R**) runs the same rebuild by hand, for a window that stays black. If the
  graphics device cannot be restored at all, the window says so ("Save All and restart") and the editor keeps
  running underneath, so the autosave goes on and no work is lost.
* **Frames that stop reaching the screen are noticed.** Some drivers and overlays (the Nahimic audio overlay of
  Alienware, Dell and MSI sound software is one) can stop the window from showing new frames without reporting any
  error. Treadle now checks about once a second that its frames are presented and rebuilds the drawing when they are
  not: a new drawing context first, then a new window. The session log names the graphics chip, the driver and any
  such overlay at start-up.
* **Laptops with two graphics chips** now keep Treadle on the faster chip for the whole session, so the driver does
  not move it between chips while it runs. Windows Settings > System > Display > Graphics can still choose the other
  chip for `Treadle.exe`.

* **Type Settings > Layout follows a change at once.** After an enum's Underlying Type was changed (int to uint8 and
  back), the Layout section could keep showing the old size. The byte bar now fits the panel at any width (every
  cell the same width, rows of 16 bytes, a note for very large types), says what it shows ("How this type is stored
  in memory: one cell per byte"), names the byte and field under the pointer, and an enum shows one line ("stored as
  uint8, 1 byte") instead of a bar. The "Offset" column header is no longer cut off in a narrow panel.
* **Typing a type's full name in a type picker and pressing Enter picks that type** ("uint8" picked "uint" before).

## For bug reports

The session log (`%LOCALAPPDATA%\Treadle\logs\treadle-<date>.log` on Windows) now names the graphics chip and driver
at start-up, records the drawing state each time the window gets the focus back, is restored or moves to another
display, and records every rebuild ("[gl] context lost after ...: recreating", "[gl] restored"). If the editor
still stops responding for you, please attach that log to a bug report.
