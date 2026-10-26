# Treadle 0.1.6-alpha

A small fix release. Existing projects open unchanged. Unpack it into a new folder, or use
**Help > Check for Updates** from 0.1.2-alpha through 0.1.5-alpha.

## Fixes

* **Adding a generic parameter to a type and opening a picker no longer crashes the editor.** On a struct, class or
  interface with a generic parameter, opening **Type Settings > Generic Parameters > Add Constraint** (and, on an
  extension, the **Extends** picker) could close the editor with a memory access error. Both pickers now work, with and
  without a search typed.