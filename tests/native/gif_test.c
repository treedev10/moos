// modules: gif
/* gif_test.c - check src/gif.asm against Pillow, and fuzz it.

     python3 tests/native/img_data.py gif      make build/img/gif/
     python3 tests/native/run.py gif           every picture: exactly Pillow's pixels
     python3 tests/native/run.py gif fuzz [N] [seed]
     python3 tests/native/run.py gif bench

   The pictures: GIFs written by img_data.py (code sizes 2-8, global and
   local colour tables, none at all, transparency, interlacing, frames
   smaller than or beyond the logical screen, odd sub-block sizes, a full
   LZW table without clear codes; the expected pixels are checked against
   Pillow's), plus GIFs saved by Pillow (also animated: the first frame
   counts) and ImageMagick. Transparent pixels get 0x336699. See imgtest.h
   for what else is checked. */
#include "imgtest.h"

int gif_info(const uint8_t *, uint32_t, uint32_t *, uint32_t *, uint32_t *);
int gif_decode(const uint8_t *, uint32_t, uint32_t *, uint32_t, uint32_t, uint8_t *, uint32_t);

int main(int argc, char **argv)
{
    return it_main(argc, argv, "gif", gif_info, gif_decode, 1, 99.0);
}
