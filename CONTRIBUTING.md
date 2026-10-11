# Contributing to Ink Away

Thanks for wanting to help. Ink Away is a one person project and there is more
I would like to fix and add than I have time for, so help of any size is
welcome, and you do not need to write code to help.

Please read the [Code of Conduct](CODE_OF_CONDUCT.md) first. Security problems
go through [SECURITY.md](SECURITY.md), never a public issue.

## Ways to help

- **Report a bug.** Use the [bug report form](https://github.com/EmirErtorer/ink-away.koplugin/issues/new/choose).
  Your device, its firmware and your KOReader version matter a lot here, as
  most problems only show up on one kind of screen or pen.
- **Test a prerelease.** Anything I cannot test on my own readers goes out as a
  prerelease first. Trying one on your device and saying how it went is one of
  the most useful things you can do.
- **Share an idea.** Talk it through in
  [Discussions](https://github.com/EmirErtorer/ink-away.koplugin/discussions)
  or open a [feature request](https://github.com/EmirErtorer/ink-away.koplugin/issues/new/choose).
- **Answer questions** in Discussions, or on Reddit when someone asks about Ink Away.
- **Improve the README or the guide** when something was hard to find or explained badly.
- **Send a fix or a feature** as a pull request.

## Before you write code

For a small fix, go ahead and open a pull request.

For anything bigger (a new tool, a change to how something works, a new
setting), please open an issue or a discussion first so we can agree on the
idea. I would hate for you to spend a weekend on something I then have to turn
down. Things I am careful about:

- **It has to work on a plain grey Kindle.** Most readers have slow processors
  and grey screens. A feature can do more on colour or pen readers, but it
  should never make the grey ones worse.
- **Refreshes matter.** Reader screens are slow to redraw. Refresh only the
  part of the screen that changed, and check that drawing and dragging still
  keep up.
- **No new dependencies.** Ink Away uses what KOReader already ships and
  nothing else, so it installs by copying one folder.
- **Fewer settings, better defaults.** A new setting needs a good reason to exist.

## Setting up

You need [LuaJIT](https://luajit.org) and
[luacheck](https://github.com/lunarmodules/luacheck) for the tests and the
linter, and KOReader's desktop emulator to try your change.

```sh
git clone https://github.com/EmirErtorer/ink-away.koplugin.git
cd ink-away.koplugin
./tools/emulator/koemu.sh setup               # builds KOReader's emulator once
./tools/emulator/koemu.sh run paperwhite      # a grey Kindle
./tools/emulator/koemu.sh run libra-colour    # a colour Kobo
```

On macOS, `setup` installs KOReader's build tools with Homebrew. On Linux,
install the prerequisites for your distribution from KOReader's
[build guide](https://github.com/koreader/koreader/blob/master/doc/Building.md)
and rsync first; `setup` checks for them and tells you if any are missing. On
Windows, use WSL and follow the Linux steps, as KOReader's guide suggests; the
tests need it too, as `tests/run.lua` calls a few Unix commands.
[tools/emulator/README.md](tools/emulator/README.md) has more on the emulator.

The emulator is good for most work, but nothing beats a real reader. If you
have one, copy the folder into KOReader's `plugins` folder as the README
describes and try it there too.

## Where things are

| Path | What it holds |
|---|---|
| `main.lua` | The plugin's entry point: menus, gestures and opening the canvas |
| `ink/view.lua` and `ink/view/` | The canvas, split into one file per part (pens, text, selection, export and so on) |
| `ink/reader/` | Writing on books: anchoring ink to words, the book toolbar, book notes |
| `ink/ui/` | Widgets such as the colour wheel and the sheets' controls |
| `ink/update/` | The updater |
| `ink/*.lua` | The core: the document model, text, shapes, export, storage and more |
| `tests/` | The test suite (see [tests/README.md](tests/README.md)) |

Each file starts with a comment that says what it does. Most of the core is
plain Lua with no KOReader code in it, so it runs in the tests on any computer.

**Adding a new kind of thing to the page** (beside ink, shapes, text and
pictures) touches more places than you might expect, because the screen,
thumbnails and exports must draw it the same way. It needs handling in
`composeInto` (ink/view/compose.lua), `replay` and `paintGeom`
(ink/export.lua), `Canvas.opBox`, `scanOps` and `cloneOp` (ink/canvas.lua),
ink/transform.lua, the selection, layers and ink/cut.lua. Please open an issue
before starting one.

## Tests

Run the linter and the tests before you open a pull request:

```sh
luacheck .
luajit tests/run.lua
```

The suites under `tests/realbb/` and `tests/scribe/` need the emulator built
by the setup script; without it they are skipped. GitHub runs the rest on
every pull request.

A fix should come with a test that fails without it, and a feature with tests
for what it does. Look at the suites next to the code you changed and follow
their pattern.

## Code style

- Match the code around you: its naming, its comments and how it is laid out.
- Every function gets a short comment above it saying what it does or why.
  Comments explain, they do not repeat the code.
- No globals. `tests/run.lua` checks for them and `luacheck` must stay clean.
- Use KOReader's APIs and widgets rather than writing your own versions.
- Text people see is in plain English with British spelling (colour, grey,
  centre), short and friendly, and wrapped in `_()` as the rest of the code does.

## Pull requests

- Keep each pull request to one change. Two small ones are easier to review
  than one big one.
- Say what it changes and why, how you tested it and on which devices. If you
  could only try it in the emulator, say so; I may ship it as a prerelease
  first so readers can try it on theirs.
- For anything you can see, add a screenshot from the emulator or your reader.
- Add a line to the `[Unreleased]` section of the [changelog](CHANGELOG.md),
  written for readers rather than developers: what changed for them, not how.
- Write commit messages as plain sentences that say what changed, for example
  "Text boxes turn to any angle", with a short explanation underneath if the
  reason is not obvious.

I try to answer every pull request within a week. I may ask for changes, and
sometimes I will make small edits myself before merging. Every contribution
that ships is credited in the changelog.

## License

Ink Away is released under the [MIT License](LICENSE). By sending a pull
request you agree that your contribution is released under it too.
