# Emulator toolkit

Run Ink Away on your Mac in KOReader's own desktop emulator, at the exact screen
size and DPI of a chosen device, so you can try changes without a real reader.

KOReader ships an SDL emulator that simulates an e-ink screen (you even see the
fast and flashing refreshes). This toolkit installs the build tools, clones and
builds KOReader once, copies this plugin into it, and launches it on the device
you pick. Mouse is treated as a single finger.

## First time

```
./tools/emulator/koemu.sh setup
```

That installs the Homebrew build packages, clones KOReader to `~/koreader-emulator`,
fetches its third-party sources, and builds the emulator. The first build takes a
while and downloads a couple of gigabytes. Put the checkout elsewhere with
`KOEMU_DIR=/some/path`.

## Run it

```
./tools/emulator/koemu.sh list             # show devices
./tools/emulator/koemu.sh run paperwhite   # a grey Kindle
./tools/emulator/koemu.sh run scribe       # Kindle Scribe (pen work)
./tools/emulator/koemu.sh run libra-colour # a colour Kobo (colour picker shows)
```

Each run copies the current plugin files in first, so just edit and re-run.

## Notes

- **Grey vs colour.** The emulator always reports a colour screen, so on grey
  devices the launcher sets `INKAWAY_FORCE_MONO=1`, which the plugin reads to hide
  the colour picker and preview the plain grey e-ink look. Colour devices leave it
  unset so the colour row appears.
- **Pen / Scribe.** KOReader feeds the Scribe pen in as ordinary touch, so the
  emulator's mouse is a faithful stand-in for the pen. There is no pressure or
  tilt to build on; do not design around it.
- **Sandboxed files.** The desktop emulator is a real app and its file browser
  can see your whole Mac, so each run points its home at `<KOEMU_DIR>/sandbox` and
  opens there. It never shows your real home or desktop. Exported drawings land in
  the KOReader folder under `ink away/drawings`.
- **Rebuild** after pulling a new KOReader: `./tools/emulator/koemu.sh update`.

## Devices

Kindle: `kindle-basic`, `paperwhite`, `paperwhite5`, `oasis`, `scribe`,
`colorsoft` (colour). Kobo: `kobo-clara`, `clara-colour`, `kobo-libra`,
`libra-colour`, `kobo-sage`, `kobo-elipsa`, `kobo-forma`, `kobo-aura-one`. Plus
`hidpi` for DPI-scaling checks.
