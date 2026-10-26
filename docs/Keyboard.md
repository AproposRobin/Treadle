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
| **Ctrl+W** | Close the Sheet tab in front (also middle-click a tab, or its menu: Close, Close Others, Close All, Close to the Right) |
| **Ctrl+Tab** / **Ctrl+Shift+Tab** | The list of open Sheets, most recently used first, opened on the Sheet used before this one: **Tab** / **Shift+Tab** move while Ctrl is held, releasing **Ctrl** opens the highlighted Sheet, **Esc** closes the list, a click opens a row; a quick tap goes back and forth between the last two |
| **Ctrl+Page Down** / **Ctrl+Page Up** | The next / previous Sheet tab, in the tab bar's order |
| **Ctrl+Z** / **Ctrl+Y** (or **Ctrl+Shift+Z**) | Undo / Redo of the document in front: a placement, a drag, a property edit is one step |
| **Ctrl+B** | Show the open type in the Project Browser |
| **Ctrl+Space** | Project Drawer |
| **Ctrl+Shift+F** | Find in Sheets (the whole project) |
| **Shift+F7** | Validate (the graph checks and the compiler's, nothing written) |
| **F7** / **Ctrl+F7** | Build / Force Build |
| **F5** | Start Debugging; Continue when stopped |
| **Ctrl+F5** | Run without debugging |
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
| **Q** | Straighten: one node or Knot made level with its wire; several: the first selected lined up with the second |
| **Shift+W** / **Shift+S** / **Shift+A** / **Shift+D** | Align top / bottom / left / right |
| **Alt+Shift+W** / **Alt+Shift+S** | Align middle / center |
| **Alt+Shift+H** / **Alt+Shift+V** | Distribute horizontally / vertically |
| **Esc** | Close the Node menu, the find bar, a comment edit |

## Menus on the Sheet (right-click)

| On | Entries |
|---|---|
| A pin | Break Link(s) (Alt+Click); **Remove Pin** (a Sequence / Multi Gate arm) or **Remove Case** (a Switch case); **Split Struct Pin** (one pin per field on the node) on a struct pin, **Recombine Struct Pin** on a split one or one of its field pins; **Break into Fields (Break T)** on a struct output, **Make from Fields (Make T)** on a struct input; **Make variable** / **Make local variable** on a value output, **Make variable (Get)** on a value input; Reset to Default |
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
| Outline | **F2** | Rename the selected member or local (its Name in Properties) |
| Outline | Drag a variable onto the Sheet: **Ctrl** = Get, **Alt** = Set, plain = asks; onto a pin: wired to it | Get / Set |
| Outline | **+** of FUNCTIONS, VARIABLES, CASES, LOCAL VARIABLES | Add one, its Name in edit |
| Outline | Click a Category header under VARIABLES | Fold / open that Category's variables (a variable's Category is set in its Properties) |
| Project Browser | **F2**, **Del**, **Enter**, **F5**, **Ctrl+A** | Rename, delete (to the Recycle Bin), open, refresh, select all |
| Node menu | Type, Arrows, Page Up / Down, **Enter**, **Esc**; the star; the key box of a favorite | Search, move, place, close; favorite; give it a node hotkey |
| Canvas sheet tabs | Middle-click | Close the tab |

## Breadcrumbs

The upper left of the Sheet shows the type, the function and any Lambda Sheet down to the one in front
(`Program > Main > Lambda a8`). Clicking the type opens Type Settings, clicking a Sheet opens it.
