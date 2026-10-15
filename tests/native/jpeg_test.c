// modules: jpeg
/* jpeg_test.c - check src/jpeg.asm against Pillow (libjpeg), and fuzz it.

     python3 tests/native/img_data.py jpeg     make build/img/jpeg/
     python3 tests/native/run.py jpeg          every picture: PSNR >= 40 dB
     python3 tests/native/run.py jpeg fuzz [N] [seed]
     python3 tests/native/run.py jpeg bench

   The pictures are baseline, progressive, restart-interval and greyscale
   JPEGs at many sizes, qualities and samplings (Pillow, ImageMagick) and
   real YouTube thumbnails. See imgtest.h for what is checked. */
#include "imgtest.h"

int jpeg_info(const uint8_t *, uint32_t, uint32_t *, uint32_t *, uint32_t *);
int jpeg_decode(const uint8_t *, uint32_t, uint32_t *, uint32_t, uint32_t, uint8_t *, uint32_t);

int main(int argc, char **argv)
{
    return it_main(argc, argv, "jpeg", jpeg_info, jpeg_decode, 0, 40.0);
}
