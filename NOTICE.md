# Notices

Ink Away is original code, released under the MIT License (see `LICENSE`).

## Runtime

Ink Away runs inside [KOReader](https://github.com/koreader/koreader) and uses
KOReader's own APIs at runtime, including its FFI wrappers around
[lodepng](https://github.com/lvandeve/lodepng) (PNG encoding) and
[libjpeg-turbo](https://github.com/libjpeg-turbo/libjpeg-turbo) (JPEG encoding).
Those libraries are provided by KOReader and are not bundled with this plugin.
