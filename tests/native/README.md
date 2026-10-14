# Native module tests

The media and data modules of MOOS (`src/h264.asm`, `src/aac.asm`, `src/mp4.asm`,
`src/jpeg.asm`, `src/png.asm`, `src/gif.asm`, `src/inflate.asm`, `src/json.asm`) are
pure computation. The same source is assembled two ways:

- `%include`d into the **full kernel** (`src/kernel.asm`, built with `-DFULL`), and
- on its own as a **32-bit ELF object** (`nasm -f elf32 -DNATIVE`), linked with a C test
  program and run on Linux, where it is checked against reference decoders (ffmpeg, zlib,
  Pillow).

```
python tests/native/run.py <test> [args]     # builds src/<module>.asm + tests/native/<test>_test.c
```

The first line of a test may list the modules it needs: `// modules: png inflate`.
Needs `nasm`, `gcc` with 32-bit support (`apt install gcc-multilib`), and for making
test data `ffmpeg` and Python with Pillow. Test data is generated into `build/` (never
committed); each test has a script or instructions to regenerate it.

## Rules for a module

1. Start with `%include "src/module.inc"`. Export entry points with `EXPORT(name)`.
2. **Every label starts with the module's prefix** (`h264_`, `aac_`, `mp4_`, `jpeg_`, `png_`,
   `gif_`, `infl_`/`inflate_`, `json_`). The kernel is one big assembly: a global label
   called `table` or `decode` would clash. Use `.local` labels inside functions.
3. **Entry points use the C calling convention**: `CENTER` ... `CLEAVE`, arguments via
   `ARG(n)`, result in EAX; EBX ESI EDI EBP are kept, EAX ECX EDX may change. Local stack
   space: `sub esp, N` after `CENTER` and `add esp, N` before `CLEAVE` (or address locals
   relative to EBP). Internal helpers may use any register convention, documented.
4. **No calls outside the module** (no kernel routines, no libc). Input and working memory
   come from the caller. Small fixed state may live in the module's `.bss` (the kernel is
   single-threaded); the init function must reset everything it relies on (never assume
   `.bss` is zero on a second use). Keep `.bss` under 256 KB and `.data` (tables) under
   64 KB per module; big buffers belong to the caller.
5. **Addresses**: the full kernel is moved by the UEFI loader, which adjusts every 32-bit
   absolute address found by assembling the kernel at two origins. So refer to labels only
   as plain 32-bit values (`mov eax, label`, `[label + ecx*4]`, `dd label`). Never shift,
   truncate or otherwise compute on a label's address at assembly time (`label >> 4`,
   `dw label`, `label & 0xFFF` are all wrong).
6. **CPU**: 32-bit code. x87 and SSE/SSE2 may be used (the UEFI firmware enables SSE;
   these modules are only in the UEFI kernel). No MMX (it shares the x87 registers), no
   AVX. Leave the x87 register stack empty and the control words as found on return.
7. **Robustness**: input comes from the internet. Never read outside the given input or
   write outside the given output/work buffers, whatever the data says. Bad data returns
   an error code (negative), never a crash or a hang (bounded loops).
8. Comment like the rest of MOOS: a header saying what the module does and how, a line
   above each routine giving its inputs and outputs, and comments on non-obvious steps.

## API contracts

Pixels are `uint32_t` `0x00RRGGBB` (the layout the desktop's `gfx_rgb` takes). Sizes and
offsets are `uint32_t`. All functions return `int` (`>= 0` success, `< 0` error) unless
stated.

### inflate.asm
```c
int inflate_buf(const uint8_t *src, uint32_t srclen, uint8_t *dst, uint32_t dstcap,
                uint32_t *outlen, uint32_t format);
/* format: 0 raw DEFLATE, 1 zlib (Adler-32 checked), 2 gzip (CRC-32 checked; header
   fields skipped), 3 auto (gzip if 1F 8B, zlib if a valid zlib header, else raw).
   0 ok; -1 bad data, -2 dst too small (*outlen = bytes written), -3 input ends early,
   -4 checksum wrong. */
```

### png.asm / gif.asm / jpeg.asm (same shape)
```c
int png_info(const uint8_t *data, uint32_t len, uint32_t *w, uint32_t *h, uint32_t *worksize);
int png_decode(const uint8_t *data, uint32_t len, uint32_t *out, uint32_t stride_px,
               uint32_t bg, uint8_t *work, uint32_t worksize);
/* likewise gif_info / gif_decode (first frame) and jpeg_info / jpeg_decode.
   Transparent pixels are blended over bg (0x00RRGGBB). worksize = bytes of scratch the
   decode needs. */
```

### mp4.asm
```c
int mp4_find_moov(const uint8_t *data, uint32_t len, uint32_t *moov_off, uint32_t *moov_len);
/* data = the start of the file. 0: the moov box is at moov_off (whole if
   moov_off + moov_len <= len); 1: not in this part - *moov_off = where the next top-level
   box starts (fetch from there); -1 not an MP4. */
int mp4_parse_moov(const uint8_t *moov, uint32_t len, MP4INFO *info, uint8_t *work,
                   uint32_t worklen);
/* MP4INFO and MP4SAMPLE layouts are in src/mp4.asm (equ offsets) and mp4_test.c.
   0 ok; -1 damaged / no tracks, -2 work too small (MP4I_NEED = bytes needed; a work of
   moov_len * 6 + 1 MB is always enough when sample sizes are listed in stsz, as ffmpeg
   and YouTube write them), -3 fragmented (moof), -4 no H.264 / AAC track. The sample
   arrays and configs are copied into work, so the moov buffer may be freed after. */
int mp4_find_sync(const MP4SAMPLE *samples, uint32_t count, uint32_t time);
/* seeking: index of the last sync sample with pts <= time (track time scale); the first
   sync sample if none is that early; 0 if there are none */
```
Test: `python3 tests/native/mp4_data.py` (ffmpeg makes the files, ffprobe gives the
references), then `run.py mp4`, `run.py mp4 fuzz [N] [seed]`, `run.py mp4 bench`.

### h264.asm
```c
uint32_t h264_ctx_size(void);
uint32_t h264_mem_size(uint32_t max_w, uint32_t max_h);
int h264_init(void *ctx, uint8_t *mem, uint32_t memlen, uint32_t max_w, uint32_t max_h);
int h264_decode_nal(void *ctx, const uint8_t *nal, uint32_t len);
    /* one NAL unit without start code or length prefix: 0 ok, 1 a picture is ready,
       < 0 error (the decoder recovers at the next IDR / slice) */
int h264_decode_avcc(void *ctx, const uint8_t *avcc, uint32_t len);
    /* the SPS / PPS of an MP4 'avcC' record: returns the NAL length size (1, 2, 4), < 0 bad */
int h264_get_frame(void *ctx, H264FRAME *f);   /* 1 = a frame (display order), 0 none */
int h264_flush(void *ctx);                      /* end of stream: release held frames */
/* H264FRAME (44 bytes): H264F_Y, H264F_U, H264F_V plane pointers (cropped top-left),
   H264F_YS luma stride, H264F_CS chroma stride, H264F_W, H264F_H cropped size,
   H264F_POC, H264F_FLAGS (bit 0 concealed, bit 1 IDR), H264F_SARW, H264F_SARH.
   Test: python3 tests/native/h264_make.py --run [--avcc] | --fuzz=N [--seed=S] */
```

### aac.asm
```c
uint32_t aac_ctx_size(void);
int aac_init(void *ctx, const uint8_t *asc, uint32_t asclen);   /* AudioSpecificConfig */
int aac_info(void *ctx, uint32_t *rate, uint32_t *channels);
int aac_decode(void *ctx, const uint8_t *frame, uint32_t len, int16_t *out);
    /* one raw AAC frame (an MP4 sample): 1024 frames of interleaved 16-bit PCM;
       returns frames written (1024) or < 0 */
```

### json.asm
```c
int json_parse(const char *js, uint32_t len, JTOK *toks, uint32_t maxtoks); /* token count */
int json_key(const char *js, const JTOK *toks, int ntoks, int obj, const char *key);
int json_index(const JTOK *toks, int ntoks, int arr, int i);
int json_str(const char *js, const JTOK *tok, char *out, uint32_t cap);
int json_int(const char *js, const JTOK *tok, int32_t *out);
int json_eq(const char *js, const JTOK *tok, const char *s);
/* JTOK layout: see src/json.asm (16 bytes: u8 type 1 object 2 array 3 string 4 primitive,
   pad[3], u32 start, u32 end (strings: without the quotes), u32 next = index of the first
   token after its subtree; a key's value is part of the key's subtree).
   json_parse: toks = NULL only counts. -1 invalid, -2 more than maxtoks tokens, -3 the
   text ends early, -4 nested deeper than 1000.
   json_key / json_index: token index or -1. json_str: decoded length (UTF-8, NUL added),
   -1 bad escape, -2 out too small. json_int: 0 ok, -1 not an integer, -2 out of int32
   range (clamped). json_eq: 1 equal, 0 not. */
```
Test: `python3 tests/native/json_data.py` (references from Python's json module), then
`run.py json`, `run.py json fuzz [N] [seed]`, `run.py json bench`.
