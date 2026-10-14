/* moostest.h - small helpers for the native module tests */
#ifndef MOOSTEST_H
#define MOOSTEST_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>

/* read a whole file (exits on failure) */
__attribute__((unused)) static unsigned char *mt_read(const char *path, uint32_t *len)
{
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(2); }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *p = malloc(n + 16);
    if (fread(p, 1, n, f) != (size_t)n) { fprintf(stderr, "read %s\n", path); exit(2); }
    fclose(f);
    memset(p + n, 0, 16);
    *len = (uint32_t)n;
    return p;
}

/* PSNR of two 8-bit buffers (99 if equal) */
__attribute__((unused)) static double mt_psnr8(const unsigned char *a, const unsigned char *b, size_t n)
{
    double se = 0;
    for (size_t i = 0; i < n; i++) { double d = (double)a[i] - b[i]; se += d * d; }
    if (se == 0) return 99.0;
    return 10.0 * log10(255.0 * 255.0 * n / se);
}

static int mt_failures;
#define MT_CHECK(cond, ...) do { if (!(cond)) { mt_failures++; \
    fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); \
    fputc('\n', stderr); } } while (0)
#define MT_DONE() do { if (mt_failures) { printf("%d check(s) failed\n", mt_failures); \
    return 1; } printf("all checks passed\n"); return 0; } while (0)
#endif
