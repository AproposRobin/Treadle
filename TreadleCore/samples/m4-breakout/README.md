# Breakout

A small Breakout game made entirely of Treadle graphs: a paddle, a ball, a wall of 60 bricks, a score and
three lives, drawn with SDL2 in a 640x480 window.

## Run it

You need the SDL 2.32.10 development package for mingw. Set `TREADLE_SDL2` to the folder that holds
`x86_64-w64-mingw32`, or unpack the package into `tools\SDL2-2.32.10` of the Treadle folder.

```
Treadle.exe --build-run TreadleCore\samples\m4-breakout
```

Or open the folder in the editor and press Ctrl+F5. Add `--config Release` for an optimised build.

What follows `--` goes to the game:

| Argument | Effect |
|---|---|
| `--frames <n>` | Stop after `n` frames |
| `--headless` | No window: run the game steps only (600 steps unless `--frames` says otherwise) |

When it ends, the game prints a summary such as:

```
frames 600 score 130 lives 3 bricks 53
paddle hits 2, flashes 7 from 2 pooled objects
```

A headless run prints the same lines every time: the wall and the ball's angles come from a random
generator with a fixed seed.

## Controls

| Key | Action |
|---|---|
| Left arrow or A | Move the paddle left |
| Right arrow or D | Move the paddle right |
| Escape | Quit |

Until you press a key the paddle plays by itself. A brick with a white outline takes two hits. The top rows
give the most points. The game ends when the wall is cleared or the last life is lost; close the window or
press Escape to quit.

## What is inside

| Type | What it shows |
|---|---|
| `Program` | Reading the command line, a Construct with Defer Delete, a Local struct, Result: match, the summary built with AppendF |
| `Game` | The game itself: a fixed step paced with Time.Ticks, the key state in a Dictionary, the bricks in a List, an event with two handlers, a Lambda filter given to FindIndex |
| `Ball`, `Vec2`, `Vec2Ext` | Structs as values, and an extension that adds arithmetic to Vec2 |
| `Brick`, `BrickHandler` | The brick struct and the event's delegate type |
| `Effects`, `Flash`, `Pool` | The second event handler: a flash where a brick broke, with flashes reused through a generic `Pool<T>` |
| `SdlContext` | A struct with a destructor that closes the window and SDL when its region ends |
| `Hud` | Rectangles, seven-segment digits for the score, and the lives |
