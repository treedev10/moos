// modules: png inflate
/* png_test.c - check src/png.asm against Pillow, and fuzz it.

     python3 tests/native/img_data.py png      make build/img/png/
     python3 tests/native/run.py png           every picture: exactly Pillow's pixels
     python3 tests/native/run.py png fuzz [N] [seed]
     python3 tests/native/run.py png bench

   The pictures cover every colour type and bit depth, with and without
   Adam7 interlacing and tRNS, random filter types per row and IDAT data
   split into many chunks (written by img_data.py, whose expected pixels
   are checked against Pillow's; for the few cases where Pillow does not
   follow the PNG spec - tRNS keys of 2/4-bit grey and 16-bit RGB, 16-bit
   grey - the spec's pixels are expected), plus pictures saved by Pillow
   and ImageMagick. Transparent pixels are blended over 0x336699. See
   imgtest.h for what else is checked. */
#include "imgtest.h"

int png_info(const uint8_t *, uint32_t, uint32_t *, uint32_t *, uint32_t *);
int png_decode(const uint8_t *, uint32_t, uint32_t *, uint32_t, uint32_t, uint8_t *, uint32_t);

int main(int argc, char **argv)
{
    return it_main(argc, argv, "png", png_info, png_decode, 1, 99.0);
}
