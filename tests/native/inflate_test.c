// modules: inflate
/* inflate_test.c - check src/inflate.asm against Python's zlib, and fuzz it.

     python3 tests/native/inflate_data.py            make build/inflate/
     python3 tests/native/run.py inflate             check every stream
     python3 tests/native/run.py inflate fuzz [N] [seed]
     python3 tests/native/run.py inflate bench

   Every stream (raw DEFLATE, zlib and gzip; levels 0-9, every zlib strategy,
   small windows, full flushes, gzip header fields) must give exactly the
   original bytes, also with format 3 (auto) for zlib and gzip; with one
   byte less room it must give -2 with dst full; cut short anywhere it must
   give -3; with a wrong checksum -4. Input and output end at guard pages. */
#include "moostest.h"
#include <sys/mman.h>
#include <signal.h>
#include <unistd.h>
#include <time.h>

int inflate_buf(const uint8_t *src, uint32_t srclen, uint8_t *dst, uint32_t dstcap,
                uint32_t *outlen, uint32_t format);

typedef struct { uint8_t *map; size_t maplen; uint8_t *p; } gbuf;
static void *galloc(gbuf *g, size_t n)
{
    size_t pg = 4096, body = (n + pg - 1) / pg * pg;
    if (!body) body = pg;
    g->maplen = body + 2 * pg;
    g->map = mmap(NULL, g->maplen, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (g->map == MAP_FAILED) { perror("mmap"); exit(2); }
    mprotect(g->map, pg, PROT_NONE);
    mprotect(g->map + pg + body, pg, PROT_NONE);
    g->p = g->map + pg + body - n;
    return g->p;
}
static void gfree(gbuf *g) { munmap(g->map, g->maplen); }

/* inflate with guarded buffers; the output is copied to out (if given) */
static int run(const uint8_t *z, uint32_t zl, uint32_t cap, uint32_t fmt, uint8_t *out,
               uint32_t *ol)
{
    gbuf gi, go;
    uint8_t *in = galloc(&gi, zl);
    memcpy(in, z, zl);
    uint8_t *dst = galloc(&go, cap);
    *ol = 0xDEADBEEF;
    int r = inflate_buf(in, zl, dst, cap, ol, fmt);
    if (out && *ol <= cap) memcpy(out, dst, *ol);
    gfree(&gi); gfree(&go);
    return r;
}

static void on_alarm(int s) { (void)s; fprintf(stderr, "FAIL: timeout (hang?)\n"); _exit(3); }

int main(int argc, char **argv)
{
    FILE *f = fopen("build/inflate/index.txt", "r");
    if (!f) { fprintf(stderr, "run tests/native/inflate_data.py first\n"); return 2; }
    char names[400][128];
    int fmts[400], n = 0;
    while (n < 400 && fscanf(f, "%127s %d", names[n], &fmts[n]) == 2) n++;
    fclose(f);
    signal(SIGALRM, on_alarm);
    char path[300];
    if (argc > 1 && !strcmp(argv[1], "bench")) {
        for (int i = 0; i < n; i++) {
            if (strncmp(names[i], "big_l6_def_w15_zlib", 19) && strncmp(names[i], "pixels_l9_def_w15_zlib", 22))
                continue;
            uint32_t zl, rl, ol;
            snprintf(path, sizeof path, "build/inflate/%s.z", names[i]);
            uint8_t *z = mt_read(path, &zl);
            snprintf(path, sizeof path, "build/inflate/%s.raw", names[i]);
            free(mt_read(path, &rl));
            uint8_t *dst = malloc(rl + 1);
            clock_t t0 = clock();
            int reps = 10;
            for (int k = 0; k < reps; k++) inflate_buf(z, zl, dst, rl, &ol, 1);
            double s = (double)(clock() - t0) / CLOCKS_PER_SEC / reps;
            printf("%-30s %8u -> %8u bytes  %7.1f MB/s\n", names[i], zl, rl, rl / s / 1e6);
            free(z); free(dst);
        }
        return 0;
    }
    if (argc > 1 && !strcmp(argv[1], "fuzz")) {
        int iters = argc > 2 ? atoi(argv[2]) : 2000;
        srand(argc > 3 ? atoi(argv[3]) : 1);
        int ok = 0;
        for (int k = 0; k < iters; k++) {
            int i = rand() % n;
            uint32_t zl, rl, ol;
            snprintf(path, sizeof path, "build/inflate/%s.z", names[i]);
            uint8_t *z = mt_read(path, &zl);
            snprintf(path, sizeof path, "build/inflate/%s.raw", names[i]);
            free(mt_read(path, &rl));
            if (zl > 200000) { free(z); k--; continue; }
            int muts = 1 + rand() % 6;
            for (int j = 0; j < muts && zl; j++) {
                uint32_t p = rand() % zl;
                if (rand() % 4 == 0) zl = p + 1; else z[p] = rand();
            }
            alarm(10);
            int r = run(z, zl, rl + rand() % 100, rand() % 4, NULL, &ol);
            alarm(0);
            if (r == 0) ok++;
            free(z);
        }
        printf("fuzz: %d mutated streams, %d decoded without error, no crash or hang\n", iters, ok);
        return 0;
    }
    int checked = 0;
    uint64_t bytes = 0;
    for (int i = 0; i < n; i++) {
        uint32_t zl, rl, ol;
        snprintf(path, sizeof path, "build/inflate/%s.z", names[i]);
        uint8_t *z = mt_read(path, &zl);
        snprintf(path, sizeof path, "build/inflate/%s.raw", names[i]);
        uint8_t *raw = mt_read(path, &rl);
        uint8_t *out = malloc(rl + 16);
        alarm(30);
        int r = run(z, zl, rl, fmts[i], out, &ol);
        MT_CHECK(r == 0 && ol == rl && !memcmp(out, raw, rl), "%s: result %d, %u bytes (want %u)%s",
                 names[i], r, ol, rl, r == 0 && ol == rl ? ", different" : "");
        if (fmts[i]) {
            r = run(z, zl, rl, 3, out, &ol);
            MT_CHECK(r == 0 && ol == rl && !memcmp(out, raw, rl), "%s: auto format gives %d", names[i], r);
        }
        if (rl) {
            r = run(z, zl, rl - 1, fmts[i], out, &ol);
            MT_CHECK(r == -2 && ol == rl - 1 && !memcmp(out, raw, rl - 1),
                     "%s: one byte too little room gives %d, %u bytes", names[i], r, ol);
        }
        for (int c = 0; c < 6; c++) {
            uint32_t cut = c < 3 ? (uint32_t)c : (uint32_t)((uint64_t)zl * c / 6);
            if (c == 5) cut = zl - 1;
            if (cut >= zl) continue;
            r = run(z, cut, rl, fmts[i], NULL, &ol);
            MT_CHECK(r == -3 || (c < 2 && fmts[i] == 2 && r == -3), "%s cut to %u bytes: %d (want -3)",
                     names[i], cut, r);
        }
        if (fmts[i]) {
            uint32_t at = fmts[i] == 1 ? zl - 1 : zl - 6;
            z[at] ^= 0x10;
            r = run(z, zl, rl, fmts[i], NULL, &ol);
            MT_CHECK(r == -4, "%s: wrong checksum gives %d", names[i], r);
            z[at] ^= 0x10;
        }
        alarm(0);
        checked++;
        bytes += rl;
        free(z); free(raw); free(out);
    }
    printf("inflate: %d streams (%llu bytes) checked\n", checked, (unsigned long long)bytes);
    MT_DONE();
}
