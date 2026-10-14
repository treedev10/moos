// modules: h264
/* h264_test.c - native test of src/h264.asm (the MOOS H.264 decoder)
 *
 *   h264_test FILE.264 [REF.yuv] [options]
 *     Decodes an Annex B stream (start codes) NAL by NAL and compares every
 *     output frame with the reference (raw yuv420p frames, e.g. from
 *     ffmpeg -i FILE.264 -f rawvideo -pix_fmt yuv420p REF.yuv). Prints the
 *     frames that differ (with the first differing pixel), PSNR and the
 *     decoding speed. Exit status 0 = every frame bit-exact and the frame
 *     count matches.
 *   options:
 *     -q          quiet (only the summary line)
 *     -bench N    decode the whole stream N times (speed; no comparison)
 *     -avcc       feed SPS / PPS through h264_decode_avcc (as an MP4 would)
 *                 and drop them from the stream
 *     -max WxH    the size given to h264_mem_size / h264_init (default:
 *                 from the reference size or 1920x1088)
 *     -size WxH   the picture size (to read the reference; default: from
 *                 the first decoded frame)
 *     -fuzz N     robustness: N runs over damaged copies of the stream (bit
 *                 flips, truncated / dropped / duplicated / swapped NAL
 *                 units, random bytes), every buffer placed against
 *                 mprotect()ed guard pages; must never crash or hang
 *     -seed S     random seed for -fuzz
 *     -dump F     write the decoded frames to F (raw yuv420p)
 */
#include "moostest.h"
#include <sys/mman.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>

typedef struct {
    uint8_t *y, *u, *v;
    uint32_t y_stride, c_stride;
    uint32_t width, height;
    int32_t poc;
    uint32_t flags;
    uint32_t sar_w, sar_h;
} H264FRAME;                                    /* H264F_* in h264.asm */

uint32_t h264_ctx_size(void);
uint32_t h264_mem_size(uint32_t max_w, uint32_t max_h);
int h264_init(void *ctx, uint8_t *mem, uint32_t memlen, uint32_t max_w, uint32_t max_h);
int h264_decode_nal(void *ctx, const uint8_t *nal, uint32_t len);
int h264_get_frame(void *ctx, H264FRAME *f);
int h264_flush(void *ctx);
int h264_decode_avcc(void *ctx, const uint8_t *avcc, uint32_t len);
void *h264_dbg_motion(void);

typedef struct { const uint8_t *p; uint32_t len; } NAL;

/* split an Annex B byte stream into NAL units (without start codes and
   trailing zero bytes) */
static NAL *split_nals(const uint8_t *d, uint32_t n, int *count)
{
    int cap = 1024, k = 0;
    NAL *v = malloc(cap * sizeof(NAL));
    uint32_t i = 0, start = 0;
    int in = 0;
    while (i + 3 <= n) {
        if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) {
            if (in) {
                uint32_t e = i;
                while (e > start && d[e - 1] == 0) e--;
                if (k == cap) v = realloc(v, (cap *= 2) * sizeof(NAL));
                v[k].p = d + start; v[k].len = e - start; k++;
            }
            i += 3; start = i; in = 1;
            continue;
        }
        i++;
    }
    if (in && start < n) {
        uint32_t e = n;
        while (e > start && d[e - 1] == 0) e--;
        if (k == cap) v = realloc(v, (cap *= 2) * sizeof(NAL));
        v[k].p = d + start; v[k].len = e - start; k++;
    }
    *count = k;
    return v;
}

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

/* ---- guarded buffers: [guard page][data ... ends at a page edge][guard] -- */
typedef struct { uint8_t *base; size_t total; uint8_t *p; } GBUF;
static GBUF gbuf(size_t len)
{
    GBUF g;
    size_t pg = 4096, body = (len + pg - 1) / pg * pg;
    g.total = body + 2 * pg;
    g.base = mmap(NULL, g.total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (g.base == MAP_FAILED) { perror("mmap"); exit(2); }
    mprotect(g.base, pg, PROT_NONE);
    mprotect(g.base + pg + body, pg, PROT_NONE);
    g.p = g.base + pg + body - len;               /* flush against the end */
    return g;
}
static void gfree(GBUF g) { munmap(g.base, g.total); }

/* ---- comparison state ---------------------------------------------------- */
static int quiet;
static FILE *dumpf;
static uint8_t *ref;
static uint32_t reflen, refw, refh, nframes, bad_frames;
static double psnr_sum, psnr_min = 99;
static uint32_t frame_bytes;
static int mv_frame = -1;                       /* -mv N */

/* trace lines of a decoder assembled with -DH264DEBUG (DBG macro) */
void h264_dbg_print(int tag, int a, int b, int c, int d)
{
    printf("dbg %d: %d %d %d %d (%08x %08x %08x %08x)\n", tag, a, b, c, d, a, b, c, d);
}

/* the decoder's motion data of a frame (MO_* in h264.asm), as ffmv prints
   ffmpeg's: list (-1 / +1), 4 4, block centre, vector (quarter samples) */
static void print_motion(const H264FRAME *f)
{
    const uint8_t *mo = h264_dbg_motion();
    uint32_t mbw = (f->width + 15) / 16, mbh = (f->height + 15) / 16;
    printf("F %u\n", nframes);
    for (uint32_t m = 0; m < mbw * mbh; m++) {
        const uint8_t *d = mo + m * 160;
        if (*(const uint32_t *)(d + 144)) { printf("mb %u intra\n", m); continue; }
        for (int l = 0; l < 2; l++)
            for (int b = 0; b < 16; b++) {
                int8_t r = d[128 + l * 4 + (b >> 3) * 2 + ((b & 3) >> 1)];
                if (r < 0) continue;
                const int16_t *v = (const int16_t *)(d + l * 64 + b * 4);
                printf("%+d  4  4 %4u %4u %5d %5d  ref %d\n", l ? 1 : -1,
                       (m % mbw) * 16 + (b & 3) * 4 + 2, (m / mbw) * 16 + (b >> 2) * 4 + 2,
                       v[0], v[1], r);
            }
    }
}

static void check_frame(const H264FRAME *f)
{
    uint32_t w = f->width, h = f->height;
    if (dumpf) {
        for (uint32_t y = 0; y < h; y++) fwrite(f->y + y * f->y_stride, 1, w, dumpf);
        for (uint32_t y = 0; y < h / 2; y++) fwrite(f->u + y * f->c_stride, 1, w / 2, dumpf);
        for (uint32_t y = 0; y < h / 2; y++) fwrite(f->v + y * f->c_stride, 1, w / 2, dumpf);
    }
    if ((int)nframes == mv_frame) print_motion(f);
    if (!ref) { nframes++; return; }
    if (!refw) { refw = w; refh = h; frame_bytes = w * h * 3 / 2; }
    if (w != refw || h != refh) {
        if (!quiet) printf("frame %u: size %ux%u, expected %ux%u\n", nframes, w, h, refw, refh);
        bad_frames++; nframes++; return;
    }
    if ((size_t)(nframes + 1) * frame_bytes > reflen) {
        if (!quiet) printf("frame %u: more frames than the reference\n", nframes);
        bad_frames++; nframes++; return;
    }
    const uint8_t *r = ref + (size_t)nframes * frame_bytes;
    /* compare plane by plane */
    double se = 0;
    int first = -1, fx = 0, fy = 0, fp = 0;
    uint32_t diffs = 0;
    for (int p = 0; p < 3; p++) {
        uint32_t pw = p ? w / 2 : w, ph = p ? h / 2 : h;
        const uint8_t *src = p == 0 ? f->y : p == 1 ? f->u : f->v;
        uint32_t st = p ? f->c_stride : f->y_stride;
        const uint8_t *rp = r + (p == 0 ? 0 : p == 1 ? w * h : w * h + (w / 2) * (h / 2));
        for (uint32_t y = 0; y < ph; y++)
            for (uint32_t x = 0; x < pw; x++) {
                int d = (int)src[y * st + x] - rp[y * pw + x];
                if (d) {
                    if (first < 0) { first = 1; fx = x; fy = y; fp = p; }
                    diffs++;
                    se += (double)d * d;
                }
            }
    }
    double psnr = se == 0 ? 99.0 : 10.0 * log10(255.0 * 255.0 * frame_bytes / se);
    psnr_sum += psnr;
    if (psnr < psnr_min) psnr_min = psnr;
    if (diffs) {
        bad_frames++;
        if (!quiet)
            printf("frame %u (poc %d%s): %u samples differ, first %s (%d,%d) = mb (%d,%d), PSNR %.2f\n",
                   nframes, f->poc, (f->flags & 1) ? ", concealed" : "", diffs,
                   fp == 0 ? "Y" : fp == 1 ? "U" : "V", fx, fy,
                   fp ? fx / 8 : fx / 16, fp ? fy / 8 : fy / 16, psnr);
    } else if ((f->flags & 1) && !quiet)
        printf("frame %u (poc %d): bit-exact but marked concealed\n", nframes, f->poc);
    nframes++;
}

static int drain(void *ctx)
{
    H264FRAME f;
    int n = 0;
    while (h264_get_frame(ctx, &f) == 1) { check_frame(&f); n++; }
    return n;
}

/* an avcC record from the stream's first SPS and PPS(s) */
static uint32_t make_avcc(NAL *nals, int count, uint8_t *out)
{
    uint32_t n = 0;
    int nsps = 0, npps = 0;
    for (int i = 0; i < count; i++) {
        if ((nals[i].p[0] & 31) == 7) nsps++;
        if ((nals[i].p[0] & 31) == 8) npps++;
    }
    const uint8_t *sps = NULL;
    for (int i = 0; i < count; i++) if ((nals[i].p[0] & 31) == 7) { sps = nals[i].p; break; }
    if (!sps) return 0;
    out[n++] = 1; out[n++] = sps[1]; out[n++] = sps[2]; out[n++] = sps[3];
    out[n++] = 0xFF;                            /* 4-byte lengths */
    out[n++] = 0xE0 | (nsps > 31 ? 31 : nsps);
    for (int i = 0, k = 0; i < count && k < 31; i++)
        if ((nals[i].p[0] & 31) == 7) {
            out[n++] = nals[i].len >> 8; out[n++] = nals[i].len;
            memcpy(out + n, nals[i].p, nals[i].len); n += nals[i].len; k++;
        }
    out[n++] = npps > 255 ? 255 : npps;
    for (int i = 0, k = 0; i < count && k < 255; i++)
        if ((nals[i].p[0] & 31) == 8) {
            out[n++] = nals[i].len >> 8; out[n++] = nals[i].len;
            memcpy(out + n, nals[i].p, nals[i].len); n += nals[i].len; k++;
        }
    return n;
}

/* ---- fuzzing -------------------------------------------------------------- */
static uint64_t rng;
static uint32_t rnd(void)
{
    rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
    return (uint32_t)(rng >> 16);
}
static volatile int fuzz_iter;
static void on_alarm(int sig)
{
    (void)sig;
    fprintf(stderr, "HANG in fuzz run %d (seed above)\n", fuzz_iter);
    _exit(3);
}

static int fuzz(NAL *nals, int count, int runs, uint32_t maxw, uint32_t maxh)
{
    uint32_t csz = h264_ctx_size(), msz = h264_mem_size(maxw, maxh);
    signal(SIGALRM, on_alarm);
    long total_nals = 0;
    for (int it = 0; it < runs; it++) {
        fuzz_iter = it;
        alarm(20);
        GBUF ctxb = gbuf(csz), memb = gbuf(msz);
        if (h264_init(ctxb.p, memb.p, msz, maxw, maxh) != 0) { printf("init failed\n"); return 1; }
        int mode = rnd() % 8;
        uint32_t rate = 1 + rnd() % 2000;      /* bit flips per million bits */
        int skip_ps = 0;
        if (rnd() % 3 == 0) {                   /* parameter sets from a damaged avcC */
            uint8_t *rec = malloc(65536 + 64);
            uint32_t alen = make_avcc(nals, count, rec);
            if (alen) {
                if (rnd() % 2) alen = 1 + rnd() % alen;
                GBUF b = gbuf(alen);
                memcpy(b.p, rec, alen);
                uint32_t flips = rnd() % 4;
                for (uint32_t k = 0; k < flips; k++) b.p[rnd() % alen] ^= 1 << (rnd() % 8);
                h264_decode_avcc(ctxb.p, b.p, alen);
                gfree(b);
                skip_ps = rnd() % 2;
            }
            free(rec);
        }
        for (int i = 0; i < count; i++) {
            NAL n = nals[i];
            int action = rnd() % 100;
            if (skip_ps && ((n.p[0] & 31) == 7 || (n.p[0] & 31) == 8)) continue;
            int reps = 1;
            if (mode == 1 && action < 5) continue;                  /* drop */
            if (mode == 2 && action < 5) reps = 2 + rnd() % 3;      /* duplicate */
            if (mode == 3 && action < 5 && i + 1 < count) {         /* swap */
                NAL t = nals[i + 1]; nals[i + 1] = nals[i]; nals[i] = t; n = nals[i];
            }
            for (int r = 0; r < reps; r++) {
                uint32_t len = n.len;
                if (mode == 4 && action < 20 && len > 1) len = 1 + rnd() % len;   /* truncate */
                if (mode == 6 && action < 3) len = len + rnd() % 64;  /* longer: garbage */
                GBUF b = gbuf(len ? len : 1);
                uint32_t keep = len < n.len ? len : n.len;
                memcpy(b.p, n.p, keep);
                for (uint32_t k = keep; k < len; k++) b.p[k] = rnd();
                if (mode == 0 || mode == 5 || mode == 7) {          /* bit flips */
                    uint64_t bits = (uint64_t)len * 8;
                    uint32_t flips = (uint32_t)(bits * rate / 1000000) + (rnd() % 3 == 0);
                    if (mode == 7) flips = 1;
                    for (uint32_t k = 0; k < flips; k++) {
                        uint32_t bit = rnd() % (uint32_t)bits;
                        if (mode == 5 && (bit >> 3) == 0) continue; /* keep the header */
                        b.p[bit >> 3] ^= 1 << (bit & 7);
                    }
                }
                if (mode == 5 && action < 2)                         /* random bytes */
                    for (uint32_t k = 1; k < len; k++) b.p[k] = rnd();
                int ret = h264_decode_nal(ctxb.p, b.p, len);
                (void)ret;
                H264FRAME f;
                while (h264_get_frame(ctxb.p, &f) == 1) {
                    /* touch every visible pixel: must be inside the memory */
                    volatile uint32_t s = 0;
                    if (f.width > maxw + 16 || f.height > maxh + 16) { printf("bad frame size\n"); return 1; }
                    for (uint32_t y = 0; y < f.height; y++) s += f.y[y * f.y_stride + f.width - 1];
                    for (uint32_t y = 0; y < f.height / 2; y++)
                        s += f.u[y * f.c_stride + f.width / 2 - 1] + f.v[y * f.c_stride];
                }
                gfree(b);
                total_nals++;
            }
        }
        h264_flush(ctxb.p);
        H264FRAME f;
        while (h264_get_frame(ctxb.p, &f) == 1) {}
        gfree(ctxb); gfree(memb);
        alarm(0);
    }
    printf("fuzz: %d runs, %ld NAL units decoded, no crash, no hang\n", runs, total_nals);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: h264_test FILE.264 [REF.yuv] [-q] [-bench N] [-avcc] "
                "[-max WxH] [-fuzz N] [-seed S] [-dump F]\n");
        return 2;
    }
    const char *refname = NULL;
    int bench = 0, use_avcc = 0, fuzz_runs = 0;
    uint32_t maxw = 0, maxh = 0;
    uint64_t seed = 1;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "-q")) quiet = 1;
        else if (!strcmp(argv[i], "-bench") && i + 1 < argc) bench = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-avcc")) use_avcc = 1;
        else if (!strcmp(argv[i], "-fuzz") && i + 1 < argc) fuzz_runs = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-seed") && i + 1 < argc) seed = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "-max") && i + 1 < argc) sscanf(argv[++i], "%ux%u", &maxw, &maxh);
        else if (!strcmp(argv[i], "-size") && i + 1 < argc) sscanf(argv[++i], "%ux%u", &refw, &refh);
        else if (!strcmp(argv[i], "-dump") && i + 1 < argc) dumpf = fopen(argv[++i], "wb");
        else if (!strcmp(argv[i], "-mv") && i + 1 < argc) mv_frame = atoi(argv[++i]);
        else if (argv[i][0] != '-') refname = argv[i];
        else { fprintf(stderr, "unknown option %s\n", argv[i]); return 2; }
    }
    if (refw) frame_bytes = refw * refh * 3 / 2;
    uint32_t len;
    uint8_t *data = mt_read(argv[1], &len);
    int count;
    NAL *nals = split_nals(data, len, &count);
    if (!maxw) { maxw = 1920; maxh = 1088; }
    if (fuzz_runs) {
        rng = seed * 0x9E3779B97F4A7C15ull + 1;
        printf("fuzz seed %llu\n", (unsigned long long)seed);
        return fuzz(nals, count, fuzz_runs, maxw, maxh);
    }
    if (refname && !bench) ref = mt_read(refname, &reflen);

    uint32_t csz = h264_ctx_size(), msz = h264_mem_size(maxw, maxh);
    if (!msz) { printf("h264_mem_size(%u, %u) = 0\n", maxw, maxh); return 1; }
    uint8_t *ctx = malloc(csz), *mem = malloc(msz);
    if (!quiet) printf("%s: %d NAL units, ctx %u bytes, mem %.1f MB for %ux%u\n",
                       argv[1], count, csz, msz / 1048576.0, maxw, maxh);
    if (h264_init(ctx, mem, msz, maxw, maxh) != 0) { printf("h264_init failed\n"); return 1; }

    int runs = bench ? bench : 1;
    uint32_t decoded = 0, errors = 0;
    double t0 = now();
    for (int run = 0; run < runs; run++) {
        if (run) h264_init(ctx, mem, msz, maxw, maxh);
        if (use_avcc) {
            uint8_t *avcc = malloc(len + 64);
            uint32_t alen = make_avcc(nals, count, avcc);
            int ls = h264_decode_avcc(ctx, avcc, alen);
            if (!quiet && run == 0) printf("h264_decode_avcc: %u bytes -> NAL length size %d\n", alen, ls);
            MT_CHECK(ls == 4, "avcC length size %d", ls);
            free(avcc);
        }
        for (int i = 0; i < count; i++) {
            int t = nals[i].p[0] & 31;
            if (use_avcc && (t == 7 || t == 8)) continue;
            int r = h264_decode_nal(ctx, nals[i].p, nals[i].len);
            if (r < 0) errors++;
            if (r == 1) {
                H264FRAME f;
                if (bench) { while (h264_get_frame(ctx, &f) == 1) decoded++; }
                else decoded += drain(ctx);
            }
        }
        h264_flush(ctx);
        H264FRAME f;
        if (bench) { while (h264_get_frame(ctx, &f) == 1) decoded++; }
        else decoded += drain(ctx);
    }
    double t = now() - t0;
    if (bench) {
        printf("%s: %u frames in %.3f s = %.1f fps\n", argv[1], decoded, t, decoded / t);
        return 0;
    }
    uint32_t refframes = (ref && frame_bytes) ? reflen / frame_bytes : 0;
    int ok = 1;
    if (ref) {
        if (refframes != nframes) ok = 0;
        if (bad_frames) ok = 0;
    }
    printf("%s: %u frames (reference %u), %u differ, PSNR avg %.2f min %.2f, %u NAL errors, %.1f fps -> %s\n",
           argv[1], nframes, refframes, bad_frames, nframes ? psnr_sum / nframes : 0, psnr_min,
           errors, nframes / t, !ref ? "decoded" : ok ? "BIT-EXACT" : "MISMATCH");
    if (dumpf) fclose(dumpf);
    if (mt_failures) return 1;
    return ref && !ok;
}
