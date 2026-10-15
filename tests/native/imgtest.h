/* imgtest.h - shared driver of the picture decoder tests (jpeg_test.c,
   png_test.c, gif_test.c).

     python3 tests/native/img_data.py [jpeg|png|gif]     make build/img/<fmt>/
     python3 tests/native/run.py <fmt>                   check every picture
     python3 tests/native/run.py <fmt> fuzz [N] [seed]   N mutated pictures
     python3 tests/native/run.py <fmt> bench             speed

   Every picture of build/img/<fmt>/index.txt is decoded and compared with
   Pillow's pixels (NAME.rgb): exactly, or by PSNR for JPEG. The input, the
   work buffer and the output each sit against an inaccessible guard page
   (input and work end at it, the output's last row too), so any read or
   write outside them crashes the test. Each picture is also decoded cut
   short at several lengths (any result but a crash), with a wider output
   stride, and with one byte too little work (must fail). The fuzzer
   mutates pictures (random bytes, cuts, copies) and decodes them the same
   way, under an alarm so a hang is caught. */
#include "moostest.h"
#include <sys/mman.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>

typedef int (*info_fn)(const uint8_t *, uint32_t, uint32_t *, uint32_t *, uint32_t *);
typedef int (*dec_fn)(const uint8_t *, uint32_t, uint32_t *, uint32_t, uint32_t, uint8_t *, uint32_t);

typedef struct { uint8_t *map; size_t maplen; uint8_t *p; } gbuf;

static void *galloc(gbuf *g, size_t n)      /* n bytes ending at a guard page */
{
    size_t pg = 4096, body = (n + pg - 1) / pg * pg;
    if (!body) body = pg;
    g->maplen = body + 2 * pg;
    g->map = mmap(NULL, g->maplen, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (g->map == MAP_FAILED) { perror("mmap"); exit(2); }
    mprotect(g->map, pg, PROT_NONE);
    mprotect(g->map + pg + body, pg, PROT_NONE);
    g->p = g->map + pg + body - n;
    memset(g->map + pg, 0xA5, body);
    return g->p;
}
static void gfree(gbuf *g) { munmap(g->map, g->maplen); }

/* decode data[0..len) with guarded buffers; out (w*h, stride w) is returned
   in *pix (malloc'd) when it worked. extra = extra stride. */
static int it_decode(info_fn info, dec_fn dec, const uint8_t *data, uint32_t len,
                     uint32_t bg, uint32_t extra, uint32_t less, uint32_t **pix,
                     uint32_t *pw, uint32_t *ph)
{
    gbuf gi, gw, go;
    uint8_t *in = galloc(&gi, len);
    memcpy(in, data, len);
    uint32_t w = 0, h = 0, ws = 0;
    int r = info(in, len, &w, &h, &ws);
    if (pix) *pix = NULL;
    if (r >= 0 && (w == 0 || h == 0 || w > 16384 || h > 16384)) r = -100;
    if (r >= 0 && ((uint64_t)w * h > (64u << 20) / 4 || ws > (256u << 20))) r = -101;
    if (r < 0) { gfree(&gi); return r; }
    if (less && ws == 0) { gfree(&gi); return -102; }
    uint32_t stride = w + extra;
    uint8_t *work = galloc(&gw, ws - less);
    uint32_t *out = galloc(&go, ((size_t)stride * (h - 1) + w) * 4);
    r = dec(in, len, out, stride, bg, work, ws - less);
    if (r >= 0 && pix) {
        *pix = malloc((size_t)w * h * 4);
        for (uint32_t y = 0; y < h; y++)
            memcpy(*pix + (size_t)y * w, out + (size_t)y * stride, w * 4);
    }
    if (pw) *pw = w;
    if (ph) *ph = h;
    gfree(&gi); gfree(&gw); gfree(&go);
    return r;
}

static void it_alarm(int sig) { (void)sig; fprintf(stderr, "FAIL: timeout (hang?)\n"); _exit(3); }

typedef struct { char name[256]; uint32_t w, h, bg; } item;

static item *it_index(const char *fmt, int *n)
{
    char path[512];
    snprintf(path, sizeof path, "build/img/%s/index.txt", fmt);
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "no %s: run tests/native/img_data.py first\n", path); exit(2); }
    item *it = NULL;
    int cnt = 0;
    item t;
    while (fscanf(f, "%255s %u %u %x", t.name, &t.w, &t.h, &t.bg) == 4) {
        it = realloc(it, (cnt + 1) * sizeof *it);
        it[cnt++] = t;
    }
    fclose(f);
    *n = cnt;
    return it;
}

/* run the test: exact = 1 needs equal pixels, else PSNR >= minpsnr */
static int it_main(int argc, char **argv, const char *fmt, info_fn info, dec_fn dec,
                   int exact, double minpsnr)
{
    int n;
    item *it = it_index(fmt, &n);
    char path[600];
    signal(SIGALRM, it_alarm);
    if (argc > 1 && !strcmp(argv[1], "bench")) {
        for (int i = 0; i < n; i++) {
            if (strncmp(it[i].name, "yt_", 3) && strncmp(it[i].name, "b_1280", 6)
                && strncmp(it[i].name, "big", 3)) continue;
            snprintf(path, sizeof path, "build/img/%s/%s", fmt, it[i].name);
            uint32_t len;
            uint8_t *d = mt_read(path, &len);
            uint32_t w, h, ws;
            info(d, len, &w, &h, &ws);
            uint8_t *work = malloc(ws + 1);
            uint32_t *out = malloc((size_t)w * h * 4);
            int reps = 20;
            clock_t t0 = clock();
            for (int k = 0; k < reps; k++) dec(d, len, out, w, it[i].bg, work, ws);
            double ms = (double)(clock() - t0) * 1000 / CLOCKS_PER_SEC / reps;
            printf("%-40s %4ux%-4u %8.2f ms\n", it[i].name, w, h, ms);
            free(work); free(out); free(d);
        }
        return 0;
    }
    if (argc > 1 && !strcmp(argv[1], "fuzz")) {
        int iters = argc > 2 ? atoi(argv[2]) : 2000;
        unsigned seed = argc > 3 ? (unsigned)atoi(argv[3]) : 1;
        srand(seed);
        int ok = 0, bad = 0;
        for (int k = 0; k < iters; k++) {
            item *t = &it[rand() % n];
            snprintf(path, sizeof path, "build/img/%s/%s", fmt, t->name);
            uint32_t len;
            uint8_t *d = mt_read(path, &len);
            uint8_t *m = malloc(len * 2 + 64);
            memcpy(m, d, len);
            uint32_t ml = len;
            int muts = 1 + rand() % 8;
            for (int j = 0; j < muts; j++) {
                int kind = rand() % 6;
                uint32_t p = ml ? rand() % ml : 0;
                if (kind <= 2 && ml) m[p] = rand();                  /* random byte */
                else if (kind == 3 && ml) m[p] ^= 1 << (rand() % 8); /* flip a bit */
                else if (kind == 4) ml = p + 1 <= ml ? p + 1 : ml;  /* cut */
                else if (ml + 16 < len * 2 + 64) {                  /* copy a run */
                    uint32_t q = rand() % ml, c = 1 + rand() % 16;
                    if (q + c > ml) c = ml - q;
                    memmove(m + p + c, m + p, ml - p);
                    memcpy(m + p, m + q + (q >= p ? c : 0), c);
                    ml += c;
                }
            }
            alarm(10);
            int r = it_decode(info, dec, m, ml, t->bg, rand() % 3, 0, NULL, NULL, NULL);
            alarm(0);
            if (r >= 0) ok++; else bad++;
            free(m); free(d);
        }
        printf("fuzz: %d mutated pictures, %d decoded, %d refused, no crash or hang\n",
               iters, ok, bad);
        return 0;
    }
    int nexact = 0, nfail = 0;
    double worst = 99;
    char worstname[256] = "";
    for (int i = 0; i < n; i++) {
        snprintf(path, sizeof path, "build/img/%s/%s", fmt, it[i].name);
        uint32_t len, rl;
        uint8_t *d = mt_read(path, &len);
        snprintf(path, sizeof path, "build/img/%s/%s.rgb", fmt, it[i].name);
        uint8_t *ref = mt_read(path, &rl);
        uint32_t *pix, w, h;
        alarm(20);
        int r = it_decode(info, dec, d, len, it[i].bg, 0, 0, &pix, &w, &h);
        alarm(0);
        if (r < 0 || w != it[i].w || h != it[i].h || rl != w * h * 3) {
            MT_CHECK(0, "%s: result %d, size %ux%u (want %ux%u)", it[i].name, r, w, h,
                     it[i].w, it[i].h);
            nfail++;
            free(d); free(ref);
            continue;
        }
        uint8_t *rgb = malloc((size_t)w * h * 3);
        for (size_t p = 0; p < (size_t)w * h; p++) {
            rgb[p * 3] = pix[p] >> 16; rgb[p * 3 + 1] = pix[p] >> 8; rgb[p * 3 + 2] = pix[p];
            MT_CHECK(!(pix[p] >> 24), "%s: top byte set", it[i].name);
            if (pix[p] >> 24) break;
        }
        double ps = mt_psnr8(rgb, ref, (size_t)w * h * 3);
        if (ps >= 99) nexact++;
        else {
            size_t p = 0;
            while (p < (size_t)w * h * 3 && rgb[p] == ref[p]) p++;
            if (exact || ps < minpsnr) {
                MT_CHECK(0, "%s: PSNR %.2f dB, first difference at pixel (%zu, %zu) channel %zu:"
                         " %d, want %d", it[i].name, ps, p / 3 % w, p / 3 / w, p % 3, rgb[p], ref[p]);
                nfail++;
            }
        }
        if (ps < worst) { worst = ps; snprintf(worstname, sizeof worstname, "%s", it[i].name); }
        /* a wider stride gives the same pixels */
        uint32_t *pix2;
        alarm(20);
        r = it_decode(info, dec, d, len, it[i].bg, 13, 0, &pix2, NULL, NULL);
        MT_CHECK(r >= 0 && pix2 && !memcmp(pix, pix2, (size_t)w * h * 4),
                 "%s: different with a wider stride", it[i].name);
        free(pix2);
        /* too little work must be refused */
        r = it_decode(info, dec, d, len, it[i].bg, 0, 1, NULL, NULL, NULL);
        MT_CHECK(r < 0 || r == -102, "%s: one byte too little work gives %d", it[i].name, r);
        /* cut short: no crash */
        for (int c = 1; c < 8; c++)
            it_decode(info, dec, d, (uint32_t)((uint64_t)len * c / 8), it[i].bg, 0, 0, NULL,
                      NULL, NULL);
        alarm(0);
        free(pix); free(rgb); free(d); free(ref);
    }
    printf("%s: %d pictures, %d identical to Pillow, %d failed; lowest PSNR %.2f dB (%s)\n",
           fmt, n, nexact, nfail, worst, worstname);
    MT_DONE();
}
