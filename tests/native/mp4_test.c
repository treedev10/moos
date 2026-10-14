// modules: mp4
/* mp4_test.c - check src/mp4.asm against ffprobe, and fuzz it.

     python3 tests/native/mp4_data.py              make build/mp4/ (files + references)
     python3 tests/native/run.py mp4               check every file in build/mp4/list.txt
     python3 tests/native/run.py mp4 fuzz [N] [seed]   N mutated moov boxes per file
     python3 tests/native/run.py mp4 bench         time mp4_parse_moov on the long file

   For each file: mp4_find_moov is run the way a player fetches a file in
   parts (whole file, 64 KB, 4 KB and 16-byte parts), mp4_parse_moov gets
   the moov box with the work size the player gives (moov * 6 + 1 MB), and
   everything is compared with the reference (ffprobe -show_streams /
   -show_packets, see mp4_data.py): codec, size, time scale, length, avcC,
   SPS, PPS, AudioSpecificConfig, and every sample's file offset, size, pts
   and sync flag. Then: work of exactly MP4I_NEED bytes works and one byte
   less gives -2; mp4_find_sync agrees with a brute-force search.
   Buffers sit against inaccessible guard pages, so any read or write
   outside them crashes the test. */
#include "moostest.h"
#include <sys/mman.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>

int mp4_find_moov(const uint8_t *data, uint32_t len, uint32_t *moov_off, uint32_t *moov_len);
int mp4_parse_moov(const uint8_t *moov, uint32_t len, uint32_t *info, uint8_t *work, uint32_t worklen);
int mp4_find_sync(const uint32_t *samples, uint32_t count, uint32_t time);

/* MP4INFO (src/mp4.asm), in dwords: a track block of 20 for video, one for
   audio, then the movie's numbers */
enum { T_OK, T_CODEC, T_P1, T_P2, T_SCALE, T_DUR, T_CFG, T_CFGLEN, T_P3, T_P4, T_P5,
       T_P6, T_P7, T_N, T_SAMP, T_EDIT, T_ID, T_MDUR, T_NSYNC, T_RES, T_LEN };
#define VB 0
#define AB T_LEN
#define I_MSCALE (2 * T_LEN)
#define I_MDUR (2 * T_LEN + 1)
#define I_NEED (2 * T_LEN + 2)
#define I_NTRAK (2 * T_LEN + 3)
#define INFO_DW (2 * T_LEN + 4)
#define PTR(x) ((uint8_t *)(uintptr_t)(x))

/* ---- buffers against guard pages ---- */
typedef struct { uint8_t *map; size_t maplen; uint8_t *p; size_t n; } gbuf;

static uint8_t *galloc(gbuf *g, size_t n, int at_end)
{
    size_t pg = 4096, body = (n + pg - 1) / pg * pg;
    if (!body) body = pg;
    g->maplen = body + 2 * pg;
    g->map = mmap(NULL, g->maplen, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (g->map == MAP_FAILED) { perror("mmap"); exit(2); }
    mprotect(g->map, pg, PROT_NONE);
    mprotect(g->map + pg + body, pg, PROT_NONE);
    g->p = at_end ? g->map + pg + body - n : g->map + pg;
    g->n = n;
    return g->p;
}
static void gfree(gbuf *g) { munmap(g->map, g->maplen); }

/* ---- the reference file ---- */
typedef struct { uint32_t off, size; long long pts; int key, disc, napts; } refpkt;
typedef struct {
    int expect;
    int has[2], ok[2], idx[2];
    char codec[2][5];
    uint32_t w, h, scale[2], dur[2], nalsz, rate, ch;
    uint8_t cfg[2][256]; int cfglen[2];
    uint8_t sps[256], pps[256]; int spslen, ppslen;
    long long corr[2];
    refpkt *p[2]; int np[2], cap[2];
} ref_t;

static int unhex(const char *s, uint8_t *out, int cap)
{
    if (!strcmp(s, "-")) return 0;
    int n = 0;
    while (s[0] && s[1] && n < cap) {
        unsigned v;
        sscanf(s, "%2x", &v);
        out[n++] = v;
        s += 2;
    }
    return n;
}

static void load_ref(const char *path, ref_t *r)
{
    memset(r, 0, sizeof *r);
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "no reference %s (run tests/native/mp4_data.py)\n", path); exit(2); }
    static char line[4096];
    while (fgets(line, sizeof line, f)) {
        char k[8], a[1024], b[1024], c[1024];
        if (sscanf(line, "%7s", k) != 1) continue;
        if (!strcmp(k, "EXPECT")) sscanf(line, "%*s %d", &r->expect);
        else if (!strcmp(k, "V") || !strcmp(k, "A")) {
            int t = k[0] == 'A';
            if (strstr(line, "none")) continue;
            r->has[t] = 1;
            sscanf(line, "%*s %d %4s %d", &r->ok[t], r->codec[t], &r->idx[t]);
        } else if (!strcmp(k, "VI")) {
            sscanf(line, "%*s %u %u %u %u %u %1023s %1023s %1023s", &r->w, &r->h, &r->scale[0], &r->dur[0],
                   &r->nalsz, a, b, c);
            r->cfglen[0] = unhex(a, r->cfg[0], 256);
            r->spslen = unhex(b, r->sps, 256);
            r->ppslen = unhex(c, r->pps, 256);
        } else if (!strcmp(k, "AI")) {
            sscanf(line, "%*s %u %u %u %u %1023s", &r->rate, &r->ch, &r->scale[1], &r->dur[1], a);
            r->cfglen[1] = unhex(a, r->cfg[1], 256);
        } else if (!strcmp(k, "VO")) sscanf(line, "%*s %lld", &r->corr[0]);
        else if (!strcmp(k, "AO")) sscanf(line, "%*s %lld", &r->corr[1]);
        else if (!strcmp(k, "P")) {
            char kind[4], pts[32], fl[8];
            refpkt q = {0};
            sscanf(line, "%*s %3s %u %u %31s %7s", kind, &q.off, &q.size, pts, fl);
            int t = kind[0] == 'A';
            if (!strcmp(pts, "N/A")) q.napts = 1; else q.pts = atoll(pts);
            q.key = strchr(fl, 'K') != NULL;
            q.disc = strchr(fl, 'D') != NULL;
            if (r->np[t] == r->cap[t]) {
                r->cap[t] = r->cap[t] ? r->cap[t] * 2 : 1024;
                r->p[t] = realloc(r->p[t], r->cap[t] * sizeof(refpkt));
            }
            r->p[t][r->np[t]++] = q;
        }
    }
    fclose(f);
}

static uint32_t fourcc(const char *s) { return s[0] | s[1] << 8 | s[2] << 16 | (uint32_t)s[3] << 24; }

/* brute-force mp4_find_sync */
static uint32_t ref_sync(const uint32_t *s, uint32_t n, uint32_t t)
{
    long best = -1;
    for (uint32_t i = 0; i < n; i++)
        if ((s[i * 4 + 3] & 1) && s[i * 4 + 2] <= t) best = i;
    if (best >= 0) return best;
    for (uint32_t i = 0; i < n; i++)
        if (s[i * 4 + 3] & 1) return i;
    return 0;
}

/* find the moov box as a player would, fetching parts of `chunk` bytes;
   returns 0 and the moov's offset/length in the file, or the error */
static int locate(const uint8_t *file, uint32_t flen, uint32_t chunk, uint32_t *off, uint32_t *len)
{
    uint32_t base = 0;
    for (int iter = 0; iter < 100000; iter++) {
        uint32_t plen = flen - base < chunk ? flen - base : chunk;
        gbuf g;
        uint8_t *b = galloc(&g, plen, 1);
        memcpy(b, file + base, plen);
        uint32_t mo = 0xDEAD, ml = 0xDEAD;
        int r = mp4_find_moov(b, plen, &mo, &ml);
        gfree(&g);
        if (r == 0) { *off = base + mo; *len = ml; return 0; }
        if (r != 1) return r;
        if (mo == 0) return -100;           /* header cut short: only at the very end */
        if ((uint64_t)base + mo >= flen) return -101; /* no moov in the file */
        base += mo;
    }
    return -102;
}

static int check_file(const char *dir, const char *name)
{
    char path[512];
    int fails0 = mt_failures;
    snprintf(path, sizeof path, "%s/%s", dir, name);
    uint32_t flen;
    uint8_t *file = mt_read(path, &flen);
    snprintf(path, sizeof path, "%s/%s.ref", dir, name);
    ref_t *r = calloc(1, sizeof(ref_t));
    load_ref(path, r);

    /* 1. mp4_find_moov, whole file and in parts */
    uint32_t moff = 0, mlen = 0;
    int rr = locate(file, flen, flen, &moff, &mlen);
    MT_CHECK(rr == 0, "%s: find_moov (whole file) = %d", name, rr);
    if (rr) { free(file); free(r); return 1; }
    MT_CHECK((uint64_t)moff + mlen <= flen, "%s: moov past the end", name);
    static const uint32_t chunks[] = { 65536, 4096, 16 };
    for (int c = 0; c < 3; c++) {
        uint32_t o2, l2;
        int r2 = locate(file, flen, chunks[c], &o2, &l2);
        MT_CHECK(r2 == 0 && o2 == moff && l2 == mlen, "%s: find_moov in %u-byte parts: %d %u %u",
                 name, chunks[c], r2, o2, l2);
    }

    /* 2. mp4_parse_moov with the player's work size */
    gbuf gm, gw;
    uint8_t *moov = galloc(&gm, mlen, 1);
    memcpy(moov, file + moff, mlen);
    uint32_t wlen = mlen * 6 + (1 << 20);
    uint8_t *work = galloc(&gw, wlen, 1);
    uint32_t info[INFO_DW + 4];
    memset(info, 0xEE, sizeof info);
    info[INFO_DW] = 0x12345678;
    int pr = mp4_parse_moov(moov, mlen, info, work, wlen);
    MT_CHECK(info[INFO_DW] == 0x12345678, "%s: wrote past MP4INFO", name);
    MT_CHECK(pr == r->expect, "%s: parse_moov = %d, expected %d", name, pr, r->expect);

    for (int t = 0; t < 2; t++) {
        uint32_t *tb = info + (t ? AB : VB);
        const char *tn = t ? "audio" : "video";
        if (!r->has[t]) {
            MT_CHECK(tb[T_OK] == 0 && tb[T_CODEC] == 0, "%s: %s track reported but none", name, tn);
            continue;
        }
        MT_CHECK(tb[T_CODEC] == fourcc(r->codec[t]), "%s: %s codec %.4s, expected %s", name, tn,
                 (char *)&tb[T_CODEC], r->codec[t]);
        MT_CHECK(tb[T_OK] == (uint32_t)r->ok[t], "%s: %s OK %u expected %d", name, tn, tb[T_OK], r->ok[t]);
        if (!r->ok[t] || !tb[T_OK]) {
            MT_CHECK(tb[T_N] == 0 && tb[T_SAMP] == 0, "%s: %s not OK but has samples", name, tn);
            continue;
        }
        MT_CHECK(tb[T_SCALE] == r->scale[t], "%s: %s time scale %u, expected %u", name, tn, tb[T_SCALE], r->scale[t]);
        MT_CHECK(tb[T_DUR] == r->dur[t], "%s: %s duration %u, expected %u", name, tn, tb[T_DUR], r->dur[t]);
        MT_CHECK(tb[T_CFGLEN] == (uint32_t)r->cfglen[t] && !memcmp(PTR(tb[T_CFG]), r->cfg[t], r->cfglen[t]),
                 "%s: %s codec config differs (%u bytes, expected %d)", name, tn, tb[T_CFGLEN], r->cfglen[t]);
        if (t == 0) {
            MT_CHECK(tb[T_P1] == r->w && tb[T_P2] == r->h, "%s: video %ux%u, expected %ux%u", name,
                     tb[T_P1], tb[T_P2], r->w, r->h);
            MT_CHECK(tb[T_P3] == r->nalsz, "%s: NAL length size %u, expected %u", name, tb[T_P3], r->nalsz);
            MT_CHECK(tb[T_P5] == (uint32_t)r->spslen && (!r->spslen || !memcmp(PTR(tb[T_P4]), r->sps, r->spslen)),
                     "%s: SPS differs", name);
            MT_CHECK(tb[T_P7] == (uint32_t)r->ppslen && (!r->ppslen || !memcmp(PTR(tb[T_P6]), r->pps, r->ppslen)),
                     "%s: PPS differs", name);
        } else {
            MT_CHECK(tb[T_P1] == r->rate && tb[T_P2] == r->ch, "%s: audio %u Hz %u ch, expected %u %u", name,
                     tb[T_P1], tb[T_P2], r->rate, r->ch);
        }
        /* the samples */
        const uint32_t *s = (const uint32_t *)PTR(tb[T_SAMP]);
        MT_CHECK(PTR(tb[T_SAMP]) >= work && PTR(tb[T_SAMP]) + tb[T_N] * 16 <= work + wlen,
                 "%s: %s samples outside work", name, tn);
        int bad = 0;
        uint32_t nsync = 0, skip = 0;
        for (uint32_t i = 0; i < tb[T_N]; i++) nsync += s[i * 4 + 3] & 1;
        /* ffmpeg leaves out audio packets more than a second before an edit
           start; MOOS keeps them, flagged PRE (hidden), at pts 0 */
        while (skip < tb[T_N] && r->np[t] && s[skip * 4] != r->p[t][0].off) skip++;
        if (skip == tb[T_N]) skip = 0;
        MT_CHECK(tb[T_N] == (uint32_t)r->np[t] + skip, "%s: %s has %u samples, expected %d", name, tn,
                 tb[T_N], r->np[t]);
        for (uint32_t i = 0; i < skip; i++)
            if ((s[i * 4 + 3] & 2) == 0 || s[i * 4 + 2] != 0) {
                MT_CHECK(0, "%s: %s sample %u (not in ffprobe's list) is not hidden", name, tn, i);
                break;
            }
        uint32_t n = tb[T_N] - skip < (uint32_t)r->np[t] ? tb[T_N] - skip : (uint32_t)r->np[t];
        for (uint32_t j = 0; j < n; j++) {
            refpkt *q = &r->p[t][j];
            uint32_t i = j + skip;
            long long want = q->disc ? 0 : q->pts + r->corr[t];
            if (want < 0) want = 0;
            if (want > 0xFFFFFFFFLL) want = 0xFFFFFFFFLL;
            /* hidden (PRE) = ffprobe's D (discard), except a video frame that
               straddles an edit start in the middle of a frame: ffmpeg drops
               it, MOOS shows it from 0 */
            int pre = (s[i * 4 + 3] >> 1) & 1;
            int preok = pre == q->disc || (q->disc && !pre && r->corr[t] && s[i * 4 + 2] == 0);
            if (s[i * 4] != q->off || s[i * 4 + 1] != q->size || (int)(s[i * 4 + 3] & 1) != q->key ||
                (!q->napts && s[i * 4 + 2] != (uint32_t)want) || !preok) {
                if (bad++ < 5)
                    MT_CHECK(0, "%s: %s sample %u: off %u size %u pts %u flags %u; expected %u %u %lld %d%s",
                             name, tn, i, s[i * 4], s[i * 4 + 1], s[i * 4 + 2], s[i * 4 + 3],
                             q->off, q->size, want, q->key, q->disc ? " D" : "");
            }
        }
        if (bad > 5) MT_CHECK(0, "%s: %s: %d samples differ", name, tn, bad);
        MT_CHECK(tb[T_NSYNC] == nsync, "%s: %s NSYNC %u, counted %u", name, tn, tb[T_NSYNC], nsync);
        /* mp4_find_sync against brute force */
        uint32_t maxpts = 0;
        for (uint32_t i = 0; i < tb[T_N]; i++) if (s[i * 4 + 2] > maxpts) maxpts = s[i * 4 + 2];
        int sbad = 0;
        for (int k = 0; k < 400; k++) {
            uint32_t tm;
            if (k < 100 && k < (int)tb[T_N]) tm = s[(k * 7919u % tb[T_N]) * 4 + 2] - (k & 1);
            else tm = (uint32_t)((uint64_t)(maxpts + 2000) * (k - 100) / 300);
            if (k == 399) tm = 0xFFFFFFFF;
            uint32_t a = mp4_find_sync(s, tb[T_N], tm), b = ref_sync(s, tb[T_N], tm);
            if (a != b && sbad++ < 3) MT_CHECK(0, "%s: %s find_sync(%u) = %u, expected %u", name, tn, tm, a, b);
        }
    }
    if (pr == 0 || pr == -2) {
        /* 3. exactly MP4I_NEED bytes of work work; one less does not */
        uint32_t need = info[I_NEED];
        MT_CHECK(need <= wlen, "%s: needs %u bytes of work, more than moov*6+1MB", name, need);
        gbuf g1, g2;
        uint8_t *w1 = galloc(&g1, need, 1);
        uint32_t info2[INFO_DW];
        int a = mp4_parse_moov(moov, mlen, info2, w1, need);
        MT_CHECK(a == pr, "%s: with %u bytes of work: %d", name, need, a);
        MT_CHECK(info2[VB + T_N] == info[VB + T_N] && info2[AB + T_N] == info[AB + T_N],
                 "%s: different sample counts with the exact work size", name);
        gfree(&g1);
        uint8_t *w2 = galloc(&g2, need - 1, 1);
        a = mp4_parse_moov(moov, mlen, info2, w2, need - 1);
        MT_CHECK(a == -2 && info2[I_NEED] == need, "%s: with one byte too little: %d (need %u)", name, a,
                 info2[I_NEED]);
        gfree(&g2);
        /* the payload alone (without the moov header) gives the same */
        uint32_t hdr = (moov[0] | moov[1] | moov[2]) == 0 && moov[3] == 1 ? 16 : 8;
        gbuf g3;
        uint8_t *w3 = galloc(&g3, wlen, 0);
        a = mp4_parse_moov(moov + hdr, mlen - hdr, info2, w3, wlen);
        MT_CHECK(a == pr && info2[VB + T_N] == info[VB + T_N] && info2[AB + T_N] == info[AB + T_N] &&
                 info2[VB + T_DUR] == info[VB + T_DUR], "%s: payload-only parse differs (%d)", name, a);
        gfree(&g3);
    }
    printf("  %-16s %s  moov %7u @%-8u video %5u samples %ux%u  audio %6u samples %u Hz %u ch\n", name,
           mt_failures == fails0 ? "ok  " : "FAIL", mlen, moff, info[VB + T_N], info[VB + T_P1],
           info[VB + T_P2], info[AB + T_N], info[AB + T_P1], info[AB + T_P2]);
    gfree(&gm);
    gfree(&gw);
    free(r->p[0]);
    free(r->p[1]);
    free(r);
    free(file);
    return 0;
}

static char **read_list(const char *dir, int *n)
{
    char path[512];
    snprintf(path, sizeof path, "%s/list.txt", dir);
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "no %s - run: python3 tests/native/mp4_data.py\n", path); exit(2); }
    char **names = NULL, line[256];
    *n = 0;
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\r\n")] = 0;
        if (!line[0]) continue;
        names = realloc(names, (*n + 1) * sizeof(char *));
        names[(*n)++] = strdup(line);
    }
    fclose(f);
    return names;
}

/* ---- fuzzing ---- */
static uint32_t rng = 1;
static uint32_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }

static void on_alarm(int sig) { (void)sig; fprintf(stderr, "FAIL: hang (alarm)\n"); _exit(3); }

/* check what a successful parse returned stays inside work */
static void fuzz_check(const uint32_t *info, const uint8_t *work, uint32_t wlen, int r)
{
    MT_CHECK(r == 0 || r == -1 || r == -2 || r == -3 || r == -4, "odd result %d", r);
    if (r == -2) MT_CHECK(info[I_NEED] > wlen, "-2 but need %u <= %u", info[I_NEED], wlen);
    if (r != 0) return;
    MT_CHECK(info[VB + T_OK] || info[AB + T_OK], "0 but no track");
    for (int t = 0; t < 2; t++) {
        const uint32_t *tb = info + (t ? AB : VB);
        if (!tb[T_OK]) continue;
        const uint8_t *s = PTR(tb[T_SAMP]), *c = PTR(tb[T_CFG]);
        MT_CHECK(tb[T_N] > 0 && tb[T_N] <= wlen / 16, "N %u", tb[T_N]);
        MT_CHECK(s >= work && s + (uint64_t)tb[T_N] * 16 <= work + wlen, "samples outside work");
        MT_CHECK(c >= work && c + tb[T_CFGLEN] <= work + wlen, "config outside work");
        if (t == 0 && tb[T_P5])
            MT_CHECK(PTR(tb[T_P4]) >= c && PTR(tb[T_P4]) + tb[T_P5] <= c + tb[T_CFGLEN], "SPS outside avcC");
        if (t == 0 && tb[T_P7])
            MT_CHECK(PTR(tb[T_P6]) >= c && PTR(tb[T_P6]) + tb[T_P7] <= c + tb[T_CFGLEN], "PPS outside avcC");
        volatile uint32_t sum = 0;
        for (uint32_t i = 0; i < tb[T_N] * 4; i++) sum += ((const uint32_t *)s)[i];
        uint32_t k = mp4_find_sync((const uint32_t *)s, tb[T_N], rnd());
        MT_CHECK(k < tb[T_N], "find_sync out of range");
    }
}

static const uint32_t interesting[] = { 0, 1, 7, 8, 9, 15, 16, 0x7F, 0x80, 0xFF, 0x100, 0xFFFF, 0x10000,
                                        0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0xFFFFFFFE, 0x0FFFFFFF, 0x10000000 };

static void mutate(uint8_t *m, uint32_t len)
{
    int k = 1 + rnd() % 8;
    for (int j = 0; j < k; j++) {
        uint32_t pos = rnd() % len;
        switch (rnd() % 6) {
        case 0: m[pos] = rnd(); break;
        case 1: m[pos] ^= 1 << (rnd() % 8); break;
        case 2: case 3: {               /* a big-endian dword: often a size or a count */
            /* prefer the size field of a box: 4 bytes before a known type */
            static const char *types[] = { "trak", "mdia", "minf", "stbl", "stsd", "stts", "ctts", "stss",
                "stsc", "stsz", "stco", "co64", "elst", "mdhd", "tkhd", "hdlr", "avcC", "esds", "mp4a",
                "avc1", "edts", "mvhd", "stz2", "wave" };
            if (rnd() & 1) {
                const char *ty = types[rnd() % (sizeof types / sizeof *types)];
                for (uint32_t i = 4 + rnd() % len; i + 4 <= len; i++)
                    if (!memcmp(m + i, ty, 4)) { pos = (rnd() & 1) ? i - 4 : i + 4 + (rnd() % 16); break; }
            }
            uint32_t v = (rnd() & 1) ? interesting[rnd() % (sizeof interesting / 4)] : rnd() % 4096;
            if (pos + 4 <= len) { m[pos] = v >> 24; m[pos + 1] = v >> 16; m[pos + 2] = v >> 8; m[pos + 3] = v; }
            break;
        }
        case 4: memset(m + pos, rnd(), (len - pos) < 8 ? len - pos : 1 + rnd() % 8); break;
        default: m[pos] = 0xFF; break;
        }
    }
}

static int fuzz(const char *dir, int iters, uint32_t seed)
{
    int n;
    char **names = read_list(dir, &n);
    rng = seed ? seed : 1;
    signal(SIGALRM, on_alarm);
    long total = 0, okc = 0, errc[8] = {0};
    for (int f = 0; f < n; f++) {
        char path[512];
        snprintf(path, sizeof path, "%s/%s", dir, names[f]);
        uint32_t flen;
        uint8_t *file = mt_read(path, &flen);
        uint32_t moff, mlen;
        if (locate(file, flen, flen, &moff, &mlen)) { free(file); continue; }
        int it = mlen > 200000 ? iters / 50 + 1 : iters;
        for (int i = 0; i < it; i++) {
            /* the moov, mutated and maybe cut short */
            uint32_t len = mlen;
            if (rnd() % 8 == 0) len = rnd() % (mlen + 1);
            gbuf gm, gw;
            uint8_t *m = galloc(&gm, len, i & 1);
            memcpy(m, file + moff, len);
            if (len) mutate(m, len);
            uint32_t wlen;
            switch (rnd() % 4) {
            case 0: wlen = rnd() % 4096; break;
            case 1: wlen = rnd() % (len * 6 + 1); break;
            default: wlen = len * 6 + (1 << 20); break;
            }
            uint8_t *w = galloc(&gw, wlen, !(i & 2));
            uint32_t info[INFO_DW];
            alarm(10);
            int r = mp4_parse_moov(m, len, info, w, wlen);
            alarm(0);
            fuzz_check(info, w, wlen, r);
            total++;
            if (r == 0) okc++; else if (r >= -4) errc[-r]++;
            gfree(&gw);
            gfree(&gm);
            /* and mp4_find_moov on a mutated start of the file */
            uint32_t plen = flen < 4096 ? flen : 1 + rnd() % 4096;
            uint8_t *b = galloc(&gm, plen, 1);
            memcpy(b, file, plen);
            mutate(b, plen);
            uint32_t mo, ml;
            int fr = mp4_find_moov(b, plen, &mo, &ml);
            MT_CHECK(fr >= -1 && fr <= 1, "find_moov odd result %d", fr);
            if (fr == 0) MT_CHECK(mo < plen, "find_moov: moov at %u past the part (%u)", mo, plen);
            gfree(&gm);
            if (mt_failures > 20) MT_DONE();
        }
        free(file);
    }
    printf("fuzz: %ld parses: %ld ok, %ld bad (-1), %ld work too small (-2), %ld fragmented (-3), %ld codec (-4)\n",
           total, okc, errc[1], errc[2], errc[3], errc[4]);
    MT_DONE();
}

static int bench(const char *dir)
{
    char path[512];
    snprintf(path, sizeof path, "%s/long.mp4", dir);
    uint32_t flen;
    uint8_t *file = mt_read(path, &flen);
    uint32_t moff, mlen;
    if (locate(file, flen, 65536, &moff, &mlen)) { printf("no moov\n"); return 1; }
    uint32_t wlen = mlen * 6 + (1 << 20);
    uint8_t *w = malloc(wlen);
    uint32_t info[INFO_DW];
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    int reps = 50, r = 0;
    for (int i = 0; i < reps; i++) r |= mp4_parse_moov(file + moff, mlen, info, w, wlen);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double ms = ((t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6) / reps;
    printf("long.mp4: moov %u bytes, %u + %u samples: mp4_parse_moov %.2f ms (%.0f MB/s of moov), result %d\n",
           mlen, info[VB + T_N], info[AB + T_N], ms, mlen / ms / 1e3, r);
    clock_gettime(CLOCK_MONOTONIC, &t0);
    volatile uint32_t sink = 0;
    for (int i = 0; i < 1000; i++)
        sink += mp4_find_sync((uint32_t *)PTR(info[VB + T_SAMP]), info[VB + T_N], i * 23040);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    printf("mp4_find_sync over %u samples: %.1f us per call\n", info[VB + T_N],
           ((t1.tv_sec - t0.tv_sec) * 1e6 + (t1.tv_nsec - t0.tv_nsec) / 1e3) / 1000);
    free(w);
    free(file);
    return 0;
}

int main(int argc, char **argv)
{
    const char *dir = "build/mp4";
    if (argc > 1 && !strcmp(argv[1], "fuzz"))
        return fuzz(dir, argc > 2 ? atoi(argv[2]) : 2000, argc > 3 ? strtoul(argv[3], 0, 0) : 1);
    if (argc > 1 && !strcmp(argv[1], "bench")) return bench(dir);
    int n;
    char **names = read_list(dir, &n);
    for (int i = 0; i < n; i++) {
        if (argc > 1 && strcmp(argv[1], names[i])) continue;
        check_file(dir, names[i]);
    }
    /* a few hand-made inputs for mp4_find_moov */
    static const uint8_t html[] = "<!DOCTYPE html><html>";
    uint32_t mo, ml;
    MT_CHECK(mp4_find_moov(html, sizeof html - 1, &mo, &ml) == -1, "HTML taken for an MP4");
    static const uint8_t tiny[] = { 0, 0, 0, 0x18, 'f', 't' };
    MT_CHECK(mp4_find_moov(tiny, sizeof tiny, &mo, &ml) == 1 && mo == 0, "6 bytes: need more");
    static const uint8_t mdat0[] = { 0, 0, 0, 8, 'f', 't', 'y', 'p', 0, 0, 0, 0, 'm', 'd', 'a', 't', 1, 2 };
    MT_CHECK(mp4_find_moov(mdat0, sizeof mdat0, &mo, &ml) == -1, "size-0 mdat before any moov");
    static const uint8_t moov0[] = { 0, 0, 0, 8, 'f', 't', 'y', 'p', 0, 0, 0, 0, 'm', 'o', 'o', 'v', 1, 2 };
    MT_CHECK(mp4_find_moov(moov0, sizeof moov0, &mo, &ml) == 0 && mo == 8 && ml == 10, "size-0 moov");
    static const uint8_t small[] = { 0, 0, 0, 4, 'f', 't', 'y', 'p' };
    MT_CHECK(mp4_find_moov(small, sizeof small, &mo, &ml) == -1, "box size 4");
    static const uint8_t past[] = { 0, 0, 0, 8, 'f', 't', 'y', 'p', 0xFF, 0xFF, 0xFF, 0xFC, 'm', 'd', 'a', 't',
                                    0, 0, 0, 0x20, 'f', 'r', 'e', 'e' };
    MT_CHECK(mp4_find_moov(past, sizeof past, &mo, &ml) == -1, "box past 4 GB");
    uint32_t empty_info[INFO_DW];
    uint8_t wk[64];
    MT_CHECK(mp4_parse_moov(html, 0, empty_info, wk, sizeof wk) == -1, "empty moov");
    MT_CHECK(mp4_find_sync(NULL, 0, 5) == 0, "find_sync on nothing");
    MT_DONE();
}
