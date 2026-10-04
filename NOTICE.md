# Notices

Ink Away is original code, released under the MIT License (see `LICENSE`).

## Runtime

Ink Away runs inside [KOReader](https://github.com/koreader/koreader) and uses
KOReader's own APIs at runtime, including its FFI wrappers around
[lodepng](https://github.com/lvandeve/lodepng) (PNG encoding) and
[libjpeg-turbo](https://github.com/libjpeg-turbo/libjpeg-turbo) (JPEG encoding).
Those libraries are provided by KOReader and are not bundled with this plugin.

## Acknowledgements

The pen slot handling in `ink/penbridge.lua` follows the approach of
[Notebook](https://github.com/pierspad/notebook.koplugin) by pierspad (MIT
License), which showed that giving the Wacom pen and the touch panel their own
slot cursors is what keeps palm rejection reliable on the Kindle Scribe. The code
here is written independently.

## Handwriting recognition

`ink/data/hwr_en.bin` is a small neural network trained by the author to read
handwritten characters (the training code is a separate project). It was
trained on:

- EMNIST (Cohen, Afshar, Tapson and van Schaik, 2017), derived from NIST
  Special Database 19, a work of the U.S. government.
- UJI Pen Characters, version 2 (Prat, Castro, Llorens, Marzal and Vilar,
  Universitat Jaume I, 2008), from the UCI Machine Learning Repository,
  licensed under Creative Commons Attribution 4.0
  (https://creativecommons.org/licenses/by/4.0/). `tests/hwr_vectors.lua`
  holds a few of its strokes.

