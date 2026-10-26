---
audience: user
title: Keyboard and mouse
summary: Every shortcut and mouse gesture of the Treadle editor: everywhere, on the Sheet, in the menus, the Outline, the Project Browser and the Node menu.
order: 11
---

# Keyboard and mouse

Every key and gesture the editor answers to, by where it works. Keys on the Sheet work while the Sheet has the
keyboard (its tab in front, no text field in edit).

## Everywhere

| Keys | Does |
|---|---|
| **Ctrl+S** / **Ctrl+Shift+S** | Save / Save All |
| **Ctrl+O** | Open a type file or a project folder |
| **Ctrl+W** | Close the Sheet tab in front (also middle-click a tab, or its menu: Close, Close Others, Close All, Close to the Right, all among the Sheets of the type in front) |
| **Ctrl+Tab** / **Ctrl+Shift+Tab** | The list of the open Sheets of the type in front, most recently used first, opened on the Sheet used before this one: **Tab** / **Shift+Tab** move while Ctrl is held, releasing **Ctrl** opens the highlighted Sheet, **Esc** closes the list, a click opens a row; a quick tap goes back and forth between the last two |
| **Ctrl+Page Down** / **Ctrl+Page Up** | The next / previous Sheet tab of the type in front, in the tab bar's order |
| **Ctrl+Shift+Page Down** / **Ctrl+Shift+Page Up** | The next / previous open type, in the type tabs' order: its Sheet tabs, Outline and Properties come with it |
| **Ctrl+Z** / **Ctrl+Y** (or **Ctrl+Shift+Z**) | Undo / Redo of the document in front: a placement, a drag, a property edit is one step |
| **Ctrl+B** | Show the open type in the Project Browser |
| **Ctrl+Space** | Project Drawer |
| **Ctrl+Shift+F** | Find in Sheets (the whole project) |
| **Shift+F7** | Validate (the graph checks and the compiler's, nothing written) |
| **F7** / **Ctrl+F7** | Build / Force Build |
| **F5** | Start Debugging; Continue when stopped |
| **Ctrl+F5** | Run: build if needed, then start the program (without the debugger) |
| **Shift+F5** | Stop Debugging |
| **F9** | Breakpoint on the selected node(s) (or click the circle on a node's corner) |
| **F10** / **F11** / **Shift+F11** | Step Over / Into / Out while stopped |
| **F1** | Documentation |

## On the Sheet

| Keys | Does |
|---|---|
| **Right-click** empty canvas | The **Node menu** (type to search: words in any order, Arrows, Page Up / Down, Enter, Esc) |
| Drag from a pin, release on empty canvas | The Node menu for that pin; the chosen node is wired (from a wired flow output, Enter alone puts a **Knot** on that wire) |
| Drag from a pin onto a pin, or onto a node's body | Connect (a node's body: its first pin that takes the wire); a refused wire says why |
| **Alt+click** a pin / a wire / a Knot | Break the pin's wires / that wire / remove the Knot |
| **Ctrl+drag** a wired pin | Move its wires to another pin |
| **Double-click** a wire | Add a Knot (reroute point) |
| **Double-click** a Call | Open the called function's Sheet (its file too) |
| **Double-click** a Lambda | Open its Lambda Sheet |
| **Double-click** a comment box's title | Edit its title |
| **Double-click** a folded node group | Open it: its nodes where they were, in a frame; a double-click on the frame's title bar folds it again (dragging the bar moves the group) |
| Click, **Shift+click**, **Ctrl+click** | Select, add to the selection, toggle (nodes, Knots, comment boxes) |
| Drag on empty canvas | Box selection (Shift / Ctrl keep the old selection) |
| Right-drag or middle-drag | Pan |
| Wheel | Zoom at the pointer ("Zoom 1:1" readout) |
| A node hotkey letter + click | Place that node at the click (defaults: **B** Branch, **S** Sequence, **E** For Each Loop, **O** For Loop, **W** While Loop, **R** Return, **T** This, **P** Result: match, **N** Construct, **D** Defer Delete; set them on the Node menu's rows or in Editor Preferences > Node Hotkeys) |
| A node hotkey letter while dragging a wire | Place that node at the pointer, wired to the pin |
| **Delete** / **Backspace** | Delete the selection (a flow node's flow stays joined; the Entry stays) |
| **Ctrl+C** / **Ctrl+V** / **Ctrl+D** | Copy / Paste at the pointer / Duplicate |
| **Ctrl+A** | Select all (nodes, Knots, comment boxes) |
| **C** | Comment box around the selection (or at the pointer) |
| **Ctrl+Shift+E** | **Extract to Function**: the selection becomes a new function of the type and a Call of it takes its place (its Name in edit) |
| **Ctrl+G** | **Collapse Nodes**: the selection folds into one group node with a pin for each wire in or out |
| **F2** | Rename: a selected comment box in place; a Get / Set / Call of this type's variable or function, a local's Get / Set, the Entry or nothing selected: that page in Properties with the Name in edit |
| **L** | A new Local of the function, its Name in edit |
| **F** | Frame the selection (everything when nothing is selected) |
| **Home** | Frame the whole Sheet (the canvas's house button goes to the Entry node) |
| **Ctrl+F** | Find in this Sheet |
| **1..9** / **Ctrl+1..9** | Go to / save view n of this Sheet |
| **M** | Minimap on / off |
| **Q** | Straighten: one node or Knot made level with its wire; two: the first selected lined up with the second; three or more: each one wired to the last selected lines up with its own pin on it (a node feeding its inputs moves left of it) |
| **Arrow keys** / **Shift+Arrow** | Move the selected nodes one grid step / ten (held: repeats; one undo step per run) |
| **Shift+W** / **Shift+S** / **Shift+A** / **Shift+D** | Align top / bottom / left / right |
| **Alt+Shift+W** / **Alt+Shift+S** | Align middle / center |
| **Alt+Shift+H** / **Alt+Shift+V** | Distribute horizontally / vertically |
| **Esc** | Close the Node menu, the find bar, a comment edit |

## Menus on the Sheet (right-click)

| On | Entries |
|---|---|
| A pin | Break Link(s) (Alt+Click); **Remove Pin** (a Sequence / Multi Gate arm) or **Remove Case** (a Switch case); **Split Struct Pin** (one pin per field on the node) on a struct pin, **Recombine Struct Pin** on a split one or one of its field pins; **Break into Fields (Break T)** on a struct output, **Make from Fields (Make T)** on a struct input; **Create variable** / **Create local variable** on a value output (a Set of it in the flow; the pin's readers read a Get of it) and on an unwired value input (a Get of it wired in); Reset to Default |
| An "evaluated Nx" badge | **Create local variable** (the value is computed once; hover the badge for what it means) |
| A node | Delete, Break All Links, Copy, Duplicate, Create Comment from Selection, **Extract to Function** (Ctrl+Shift+E), **Collapse Nodes** (Ctrl+G), Add / Edit Comment, Go To Sheet (a Call), **Add Argument Pin** (a Call of a C variadic function), **Add Pin** / **Add Case** (Sequence, Multi Gate, Switch), **Rename...** (F2), **Hide Unwired Pins** / Show All Pins, **Disable Node** / Enable Node, Change to Construct / Local |
| A node group (folded, or an open one's title bar) | **Open Group** / **Fold Group** (Double-Click), its title (Enter applies it), Select Nodes, **Ungroup** (the nodes stay), Delete Group and Nodes (Del) |
| A wire | Break This Link (Alt+Click), Add Reroute Knot (Double-Click) |
| A Knot | Remove Knot(s) (Alt+Click), Straighten (Q) |
| A comment box | Rename (Double-Click), Color, Delete Comment (Del) |

On the node itself: **Add pin +** under the outputs of a Sequence, a Multi Gate and a Switch; **+ arg** / **- arg**
on a selected Call of a C variadic function (`printf`): its extra inputs `va0`, `va1`, ... (a Call of any other
function has none).

In Properties, a function's page has stacked **Move Up** / **Move Down** arrows in front of each input and further
output (with two or more): the Entry, the Return and every Call follow the order.

## Outline, Project Browser, Node menu

| Where | Keys | Does |
|---|---|---|
| Outline | **F2** or **double-click** a function, variable or local | Rename it in its row (Enter commits, Esc cancels; Properties > Name shows the same text); a case or another member: its Name in Properties |
| Outline | **Delete** | Delete the selected variable, function, case or local (one undo step; only when the Outline has the focus: the Sheet's selection stays) |
| Outline | **Enter** | Open the selected member: its Sheet, else its page in Properties |
| Outline | **Override...** on FUNCTIONS (a class); **Implement** on a REQUIRED OVERRIDES row, its **+** | Override a base function; implement a required one; implement them all |
| Outline | Right-click the type's header | Make Child Class (a class), Duplicate, Type Settings |
| Outline | Drag a variable (an Inherited one too) onto a pin it fits: a Get wired into an input, a Set fed by an output, no key needed (a pin it does not fit says why); onto the Sheet: **Ctrl** = Get, **Alt** = Set, plain = asks | Get / Set |
| Outline | **+** of FUNCTIONS, VARIABLES, CASES, LOCAL VARIABLES | Add one, its Name in edit |
| Outline | Click a Category header under VARIABLES | Fold / open that Category's variables (a variable's Category is set in its Properties) |
| Project Browser | **F2**, **Del**, **Enter**, **F5**, **Ctrl+A** | Rename, delete (to the Recycle Bin), open, refresh, select all |
| Project Browser | **+ Add** or right-click a folder | New Folder, New Class, New Struct, New Enum, New Interface, New Delegate, New Extension, New C Import Set: each asks for the name in the Create Type dialog (Enter creates, Esc cancels); no shortcuts |
| Project Browser | Right-click a type tile | Make Child Class (a class that is not sealed or static), Duplicate |
| A type picker | Type, **Up** / **Down**, **Enter**, **Esc** | Search (words in any order), move, take the row, close |
| Node menu | Type, Arrows, Page Up / Down, **Enter**, **Esc**; the star; the key box of a favorite | Search, move, place, close; favorite; give it a node hotkey |
| Canvas sheet tabs | Middle-click | Close the tab |
| Type tabs (over the Sheet tabs) | Click; middle-click or the **x**; right-click (Type Settings, Show in Project Browser, Close, Close Other Types, Close All Types); drag along the row | Bring the type to the front; close the type (its Sheet tabs close, the file stays as it is); the menu; reorder |
| Type tabs | Drag a variable or function from the Outline and hold it over another type's tab | That type comes to the front; drop on its Sheet for a Call / Get / Set |

## Breadcrumbs

The upper left of the Sheet shows the type, the function and any Lambda Sheet down to the one in front
(`Program > Main > Lambda a8`; a class with a base reads `Dog : Animal > Speak`). Clicking the type opens Type Settings, clicking a Sheet opens it.
