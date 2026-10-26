# Treadle 0.1.2-alpha

A fix release for the first hours of using Treadle. Everything here comes from a test session of someone writing a
first program: renaming, picking types, filling in values, wiring and tidying a Sheet. Existing projects open
unchanged. Unpack it into a new folder, or use **Help > Check for Updates** from 0.1.1-alpha.

## Naming things

* **Rename a type** in Type Settings (or **Rename** on its file in the Project Browser): the file follows the type
  name, and the other types and the project's entry name follow too. One undo step covers all of it.
* **Rename a function, variable or local variable in place**: double-click or F2 on its row in the Outline, type,
  Enter to commit, Esc to cancel. The Properties Name field shows the same text as you type.
* **Attributes** can be removed again (an X on each row), and **Add Attribute** lists the attributes the compiler
  reads with what each does.

## Types and values

* **Kind icons** are the same everywhere: the Outline header, Project Browser tiles, type pickers and the Create
  Type dialog show a class, struct, enum, interface, delegate or extension with its own glyph and colour.
* **Type pickers are fast** in large projects, and a Construct's picker lists abstract and static classes dimmed,
  with the reason they cannot be constructed.
* **Container switch**: a button left of every value type field changes Plain, Array, List, Span or Nullable.
* **Typed defaults**: a variable's Default Value uses the same control as an unwired pin; an integer field takes
  whole numbers in its type's range, a float a decimal. Inline bool values are a framed checkbox of at least 15
  pixels, and value fields are framed in the pin's colour.
* **Is Type** (a class test that does not cast) and **Is Valid** (not null, and in Debug, not already deleted) are
  new nodes; Is Type is offered as Is <Class> when you drag from an object pin. `==` and `!=` still compare object
  identity.
* **Inherited variables** are listed in the Outline under VARIABLES > Inherited, dimmed with their owner, and drag
  like your own. Giving a child class its own default for one is not built yet (Known Issues).

## Wiring and tidying

* **Create variable** from a pin's menu: on an output, the readers of that pin move onto one Get of the new
  variable placed after its Set. **Create local variable** does the same inside a function, also from the evaluated
  Nx badge.
* **Drag a variable onto a pin** it fits and it wires itself, no Ctrl needed.
* **Arrow keys nudge** the selected nodes one grid step, Shift ten steps; one run is one undo step.
* **Q** with three or more nodes selected aligns each to its own pin on the last selected node.
* A function given a result or an output gets its **Return** node automatically.

## Status bar

* The build state has colours: **Not validated** is yellow from any edit until you validate, red with errors, green
  when clean. A saved file no longer reads as built when it changed after the build started: it says
  **Needs build**.

The new behaviour is described in Keyboard.md, Language.md, Language-Guide.md and Graph-Format.md, and the limits
that remain are in Known-Issues.md.

## Fixes

* **File > Import C Headers** opens a dialog titled "Import C headers" that lists C headers (`*.h`, `*.hpp`,
  `*.hh`), C import sets (`*.cimport`) and all files, and takes several files at once. A chosen `.cimport` is
  added to the project; each chosen header gets a set named after it. Paths are stored relative to the project.
* **Open File** offers Treadle types (`*.treadle`) and projects (`*.tproj`) instead of Beef source files.
