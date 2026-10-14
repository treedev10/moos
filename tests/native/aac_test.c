// modules: aac
/*
 * aac_test.c - checks src/aac.asm (AAC-LC decoder) against ffmpeg's decoder
 *
 *     python tests/native/aac_make.py         (once: makes build/aac/)
 *     python tests/native/run.py aac [options] [case ...]
 *
 * options:  --dir D       test data directory (default build/aac)
 *           --fuzz N      N corrupted frames per fuzzed case (default 3000)
 *           --nofuzz      skip the robustness tests
 *           --bench       only measure the speed (long_music, 10 runs)
 *           --dump C F    only decode case C and write its PCM to file F
 *           -v            more output
 *
 * For every case in manifest.txt (see aac_make.py) the access units are taken
 * from the .adts file (ADTS headers stripped), the decoder is configured with
 * the AudioSpecificConfig from the .m4a (.asc), and the 16-bit output is
 * compared with ffmpeg's decode (.ref):
 *   snr DB    signal-to-noise ratio over the whole file >= DB
 *   pns DB    the file uses perceptual noise substitution, so its noise bands
 *             are random: energies in 1/3-octave bands (whole file, and per
 *             second for the louder bands) must be within DB of ffmpeg's
 *   exact     identical (silence)
 *   same X    like snr 70 against case X's reference (same frames, other
 *             signalling or extra elements that must be skipped)
 * Then the robustness tests: corrupted frames (bit flips, truncation, random
 * bytes) and corrupted AudioSpecificConfigs, with the input, output and
 * context each followed by an inaccessible page, so any read or write past
 * them crashes the test. A watchdog alarm catches hangs.
 */
#include "moostest.h"
#include <sys/mman.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>

uint32_t aac_ctx_size(void);
int aac_init(void *ctx, const uint8_t *asc, uint32_t asclen);
int aac_info(void *ctx, uint32_t *rate, uint32_t *channels);
int aac_decode(void *ctx, const uint8_t *frame, uint32_t len, int16_t *out);
extern uint32_t aac_stats[64];      /* event counters (NATIVE builds, see AAC_STAT) */

/* names of the counters in aac.asm (AAC_S_*) */
static const char *stat_name[64] = {
    [0] = "frames", [1] = "SCE", [2] = "CPE", [3] = "CCE", [4] = "LFE", [5] = "DSE",
    [6] = "PCE", [7] = "FIL", [8] = "ONLY_LONG", [9] = "LONG_START", [10] = "EIGHT_SHORT",
    [11] = "LONG_STOP", [12] = "KBD shape", [13] = "grouped short", [14] = "common_window",
    [15] = "separate windows", [16] = "ms_mask 1", [17] = "ms_mask 2", [18] = "pulse data",
    [19] = "TNS long", [20] = "TNS short", [21] = "TNS compressed", [22] = "TNS downwards",
    [23] = "TNS order 9-12", [24] = "escapes", [25] = "intensity bands",
    [26] = "intensity inverted", [27] = "noise bands", [28] = "noise pair (M/S)",
    [29] = "M/S bands", [30] = "|q| >= 1024", [31] = "FIL with SBR",
    [32] = "book 0", [33] = "book 1", [34] = "book 2", [35] = "book 3", [36] = "book 4",
    [37] = "book 5", [38] = "book 6", [39] = "book 7", [40] = "book 8", [41] = "book 9",
    [42] = "book 10", [43] = "book 11", [45] = "book 13 (noise)",
    [46] = "book 14 (intensity)", [47] = "book 15 (intensity)", [48] = "DSE aligned",
    [49] = "explicit rate", [50] = "PCE config", [51] = "HE-AAC config",
    [52] = "short, one group", [53] = "short, 8 groups",
};
static uint64_t stat_total[64];

/* add the decoder's counters to the totals (and print them with -v) */
static void take_stats(const char *name, int print)
{
    if (print) {
        printf("     %s:", name);
        for (int i = 0; i < 64; i++)
            if (aac_stats[i] && stat_name[i]) printf(" %s=%u", stat_name[i], aac_stats[i]);
        printf("\n");
    }
    for (int i = 0; i < 64; i++) stat_total[i] += aac_stats[i];
    memset(aac_stats, 0, sizeof aac_stats);
}

static int verbose;
static const char *dir = "build/aac";

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

/* ------------------------------------------------------------ guarded memory */
/* n bytes that end exactly where an inaccessible page begins */
static void *guarded(size_t n, void **base, size_t *maplen)
{
    long pg = sysconf(_SC_PAGESIZE);
    size_t len = ((n + pg - 1) / pg + 2) * pg;
    uint8_t *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) { perror("mmap"); exit(2); }
    mprotect(p, pg, PROT_NONE);                 /* a guard before, too */
    mprotect(p + len - pg, pg, PROT_NONE);
    *base = p;
    *maplen = len;
    return p + len - pg - n;
}

/* ------------------------------------------------------------ ADTS */
typedef struct { const uint8_t *p; uint32_t len; } AU;

static int adts_split(const uint8_t *d, uint32_t n, AU **out, int *sfi, int *chcfg)
{
    int cap = 1024, cnt = 0;
    AU *a = malloc(cap * sizeof(AU));
    uint32_t pos = 0;
    while (pos + 7 <= n) {
        if (d[pos] != 0xFF || (d[pos + 1] & 0xF0) != 0xF0) { fprintf(stderr, "bad ADTS\n"); exit(2); }
        int noprot = d[pos + 1] & 1;
        uint32_t len = ((d[pos + 3] & 3) << 11) | (d[pos + 4] << 3) | (d[pos + 5] >> 5);
        int hl = noprot ? 7 : 9;
        if (cnt == 0) {
            *sfi = (d[pos + 2] >> 2) & 15;
            *chcfg = ((d[pos + 2] & 1) << 2) | (d[pos + 3] >> 6);
        }
        if (cnt == cap) a = realloc(a, (cap *= 2) * sizeof(AU));
        a[cnt].p = d + pos + hl;
        a[cnt].len = len - hl;
        cnt++;
        pos += len;
    }
    *out = a;
    return cnt;
}

static const uint32_t rates[13] = {96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
                                   16000, 12000, 11025, 8000, 7350};

/* ------------------------------------------------------------ metrics */
static double snr_db(const int16_t *a, const int16_t *ref, size_t n)
{
    double s = 0, e = 0;
    for (size_t i = 0; i < n; i++) {
        double d = (double)a[i] - ref[i];
        s += (double)ref[i] * ref[i];
        e += d * d;
    }
    if (e == 0) return 99.0;
    if (s == 0) return -99.0;
    return 10 * log10(s / e);
}

/* in-place radix-2 FFT (test code only) */
static void fft(double *re, double *im, int n)
{
    for (int i = 1, j = 0; i < n; i++) {
        int b = n >> 1;
        for (; j & b; b >>= 1) j ^= b;
        j ^= b;
        if (i < j) {
            double t = re[i]; re[i] = re[j]; re[j] = t;
            t = im[i]; im[i] = im[j]; im[j] = t;
        }
    }
    for (int len = 2; len <= n; len <<= 1) {
        double a = -2 * M_PI / len;
        for (int i = 0; i < n; i += len)
            for (int j = 0; j < len / 2; j++) {
                double wr = cos(a * j), wi = sin(a * j);
                double xr = re[i + j + len / 2], xi = im[i + j + len / 2];
                double tr = xr * wr - xi * wi, ti = xr * wi + xi * wr;
                re[i + j + len / 2] = re[i + j] - tr;
                im[i + j + len / 2] = im[i + j] - ti;
                re[i + j] += tr;
                im[i + j] += ti;
            }
    }
}

#define NBANDS 40
/* energy per 1/3-octave band (from 50 Hz) of channel c, frames [f0, f1) of
   1024 samples, 2048-point Hann windows */
static void band_energy(const int16_t *pcm, int ch, int c, size_t nframes, int f0, int f1,
                        uint32_t rate, double *bands)
{
    static double re[2048], im[2048];
    memset(bands, 0, NBANDS * sizeof(double));
    for (int f = f0; f < f1 && (size_t)(f + 2) <= nframes; f++) {
        for (int i = 0; i < 2048; i++) {
            double w = 0.5 - 0.5 * cos(2 * M_PI * (i + 0.5) / 2048);
            re[i] = pcm[((size_t)f * 1024 + i) * ch + c] * w;
            im[i] = 0;
        }
        fft(re, im, 2048);
        for (int k = 1; k < 1024; k++) {
            double hz = (double)k * rate / 2048;
            int b = hz < 50 ? -1 : (int)(3 * log2(hz / 50));
            if (b >= 0 && b < NBANDS) bands[b] += re[k] * re[k] + im[k] * im[k];
        }
    }
}

/* largest band energy difference (dB) over bands within 40 dB of the
   loudest; whole file, and per second (bands within 20 dB of the loudest
   and at least 8 FFT bins wide, where the random noise averages out) */
static double pns_compare(const int16_t *a, const int16_t *ref, size_t nframes, int ch,
                          uint32_t rate, double *worst_sec)
{
    double ea[NBANDS], er[NBANDS], worst = 0;
    *worst_sec = 0;
    int per_sec = rate / 1024;
    for (int c = 0; c < ch; c++) {
        for (int pass = 0; pass < 2; pass++) {
            int step = pass == 0 ? (int)nframes : per_sec;
            for (int f0 = 0; f0 + 2 <= (int)nframes; f0 += step) {
                band_energy(a, ch, c, nframes, f0, f0 + step, rate, ea);
                band_energy(ref, ch, c, nframes, f0, f0 + step, rate, er);
                double mx = 0;
                for (int b = 0; b < NBANDS; b++) if (er[b] > mx) mx = er[b];
                if (mx == 0) continue;
                for (int b = 0; b < NBANDS; b++) {
                    double lo = 50 * pow(2, b / 3.0), hi = 50 * pow(2, (b + 1) / 3.0);
                    double bins = (hi - lo) * 2048 / rate;
                    if (pass == 0 && er[b] < mx * 1e-4) continue;
                    if (pass == 1 && (er[b] < mx * 1e-2 || bins < 8)) continue;
                    double d = fabs(10 * log10((ea[b] + 1e-9) / (er[b] + 1e-9)));
                    if (pass == 0 && d > worst) worst = d;
                    if (pass == 1 && d > *worst_sec) *worst_sec = d;
                }
            }
        }
    }
    return worst;
}

/* ------------------------------------------------------------ one case */
typedef struct {
    uint8_t *adts, *asc;
    uint32_t adtslen, asclen;
    AU *au;
    int nau, sfi, chcfg;
} Stream;

static void load(const char *name, Stream *s)
{
    char path[512];
    snprintf(path, sizeof path, "%s/%s.adts", dir, name);
    s->adts = mt_read(path, &s->adtslen);
    snprintf(path, sizeof path, "%s/%s.asc", dir, name);
    s->asc = mt_read(path, &s->asclen);
    s->nau = adts_split(s->adts, s->adtslen, &s->au, &s->sfi, &s->chcfg);
}

/* decode a whole stream; returns frames decoded (each 1024 samples), or -1 */
static int decode_all(const Stream *s, int16_t **pcm, uint32_t *rate, uint32_t *ch,
                      double *seconds)
{
    void *ctx = malloc(aac_ctx_size());
    int r = aac_init(ctx, s->asc, s->asclen);
    if (r < 0) { printf("    aac_init failed: %d\n", r); free(ctx); return -1; }
    if (aac_info(ctx, rate, ch) < 0) { printf("    aac_info failed\n"); free(ctx); return -1; }
    int16_t *out = malloc((size_t)s->nau * 1024 * 2 * sizeof(int16_t));
    double t0 = now();
    int n = 0;
    for (int i = 0; i < s->nau; i++) {
        r = aac_decode(ctx, s->au[i].p, s->au[i].len, out + (size_t)n * 1024 * *ch);
        if (r != 1024) {
            printf("    frame %d: aac_decode returned %d\n", i, r);
            free(ctx);
            free(out);
            return -1;
        }
        n++;
    }
    *seconds = now() - t0;
    free(ctx);
    *pcm = out;
    return n;
}

static int run_case(const char *name, const char *mode, const char *arg, uint32_t want_rate,
                    uint32_t want_chans, double *dec_time, double *audio_time)
{
    Stream s;
    load(name, &s);
    const char *refname = strcmp(mode, "same") == 0 ? arg : name;
    char path[512];
    uint32_t reflen;
    snprintf(path, sizeof path, "%s/%s.ref", dir, refname);
    int16_t *ref = (int16_t *)mt_read(path, &reflen);
    int16_t *pcm;
    uint32_t rate, ch;
    double secs;
    int n = decode_all(&s, &pcm, &rate, &ch, &secs);
    int ok = 1;
    if (n < 0) {
        printf("FAIL %-26s decode error\n", name);
        return 0;
    }
    uint32_t want_ch = s.chcfg == 1 ? 1 : 2;
    if (s.chcfg == 0) want_ch = 2;                  /* (PCE cases are stereo or more) */
    if (strstr(name, "_ps29")) want_ch = 1;
    if (want_chans) want_ch = want_chans;           /* (ch= in the manifest) */
    if (!want_rate) want_rate = rates[s.sfi];       /* (rate= in the manifest) */
    if (rate != want_rate || ch != want_ch) {
        printf("FAIL %-26s aac_info: rate %u channels %u, expected %u / %u\n", name, rate, ch,
               want_rate, want_ch);
        ok = 0;
    }
    size_t nsamp = (size_t)n * 1024 * ch;
    if (reflen / 2 != nsamp) {
        printf("FAIL %-26s length %zu samples, reference %u\n", name, nsamp, reflen / 2);
        ok = 0;
        if (reflen / 2 < nsamp) nsamp = reflen / 2;
    }
    double snr = snr_db(pcm, ref, nsamp);
    char detail[200] = "";
    if (!strcmp(mode, "snr") || !strcmp(mode, "same")) {
        double want = !strcmp(mode, "same") ? 70 : atof(arg);
        double worst = 1e9;
        for (uint32_t c = 0; c < ch; c++) {         /* each channel on its own too */
            double se = 0, ee = 0;
            for (size_t i = c; i < nsamp; i += ch) {
                double d = (double)pcm[i] - ref[i];
                se += (double)ref[i] * ref[i];
                ee += d * d;
            }
            double v = ee == 0 ? 99 : se == 0 ? -99 : 10 * log10(se / ee);
            if (v < worst) worst = v;
        }
        snprintf(detail, sizeof detail, "SNR %6.2f dB (worst channel %6.2f)", snr, worst);
        if (snr < want || worst < want) ok = 0;
    } else if (!strcmp(mode, "pns")) {
        double ws, w = pns_compare(pcm, ref, nsamp / ch / 1024, ch, rate, &ws);
        snprintf(detail, sizeof detail, "band energies within %.2f dB (per second %.2f), SNR %.1f",
                 w, ws, snr);
        if (w > atof(arg) || ws > atof(arg)) ok = 0;
    } else if (!strcmp(mode, "exact")) {
        int same = memcmp(pcm, ref, nsamp * 2) == 0;
        snprintf(detail, sizeof detail, "%s", same ? "identical" : "DIFFERENT");
        if (!same) ok = 0;
    }
    double dur = (double)n * 1024 / rate;
    printf("%s %-26s %-6s %s  %4.0fx realtime\n", ok ? "ok  " : "FAIL", name, mode, detail,
           dur / secs);
    take_stats(name, verbose);
    *dec_time += secs;
    *audio_time += dur;
    free(pcm);
    free(ref);
    free(s.adts);
    free(s.asc);
    free(s.au);
    return ok;
}

/* ------------------------------------------------------------ robustness */
static volatile int in_decode;
static void on_alarm(int sig)
{
    (void)sig;
    if (in_decode) {
        fprintf(stderr, "FAIL: decoder hung (watchdog)\n");
        _exit(3);
    }
}

static uint32_t rnd_state = 12345;
static uint32_t rnd(void)
{
    rnd_state = rnd_state * 1103515245u + 12345u;
    return rnd_state >> 8;
}

/* decode corrupted versions of the frames of one case; returns 1 if the
   decoder survived (and still decodes the clean frames afterwards) */
static int fuzz_case(const char *name, int count)
{
    Stream s;
    load(name, &s);
    void *cbase, *obase, *ibase;
    size_t clen, olen, ilen;
    uint32_t csz = aac_ctx_size();
    void *ctx = guarded(csz, &cbase, &clen);
    if (aac_init(ctx, s.asc, s.asclen) < 0) { printf("FAIL fuzz %s: init\n", name); return 0; }
    uint32_t rate, ch;
    aac_info(ctx, &rate, &ch);
    if (ch < 1 || ch > 2) { printf("FAIL fuzz %s: %u channels\n", name, ch); return 0; }
    /* exactly the 1024 frames of output aac_info promises, then the guard */
    int16_t *out = guarded(1024 * ch * sizeof(int16_t), &obase, &olen);
    int errors = 0, oks = 0, kinds[5] = {0};
    uint8_t *buf = malloc(65536);
    for (int i = 0; i < count; i++) {
        const AU *a = &s.au[rnd() % s.nau];
        uint32_t len = a->len;
        memcpy(buf, a->p, len);
        int kind = rnd() % 5;
        kinds[kind]++;
        if (kind == 0) {                            /* a few bit flips */
            int flips = 1 + rnd() % 8;
            for (int f = 0; f < flips; f++) buf[rnd() % len] ^= 1 << (rnd() % 8);
        } else if (kind == 1) {                     /* cut short */
            len = rnd() % (len + 1);
        } else if (kind == 2) {                     /* random bytes after a point */
            for (uint32_t k = rnd() % (len + 1); k < len; k++) buf[k] = rnd();
        } else if (kind == 3) {                     /* entirely random, any length */
            len = rnd() % 3000;
            for (uint32_t k = 0; k < len; k++) buf[k] = rnd();
        } else {                                    /* runs of ones or zeros */
            uint32_t k0 = rnd() % (len + 1), k1 = k0 + rnd() % 64;
            uint8_t v = (rnd() & 1) ? 0xFF : 0x00;
            for (uint32_t k = k0; k < k1 && k < len; k++) buf[k] = v;
        }
        uint8_t *in = guarded(len ? len : 1, &ibase, &ilen);
        in += len ? 0 : 1;
        memcpy(in, buf, len);
        alarm(5);
        in_decode = 1;
        int r = aac_decode(ctx, in, len, out);
        in_decode = 0;
        alarm(0);
        munmap(ibase, ilen);
        if (r < 0) errors++;
        else if (r == 1024) oks++;
        else { printf("FAIL fuzz %s: aac_decode returned %d\n", name, r); return 0; }
    }
    /* clean frames still decode */
    int clean = 0;
    for (int i = 0; i < s.nau && i < 50; i++) {
        uint8_t *in = guarded(s.au[i].len, &ibase, &ilen);
        memcpy(in, s.au[i].p, s.au[i].len);
        if (aac_decode(ctx, in, s.au[i].len, out) == 1024) clean++;
        munmap(ibase, ilen);
    }
    printf("%s fuzz %-22s %d frames: %d rejected, %d decoded; %d/%d clean frames after\n",
           clean == (s.nau < 50 ? s.nau : 50) ? "ok  " : "FAIL", name, count, errors, oks,
           clean, s.nau < 50 ? s.nau : 50);
    munmap(cbase, clen);
    munmap(obase, olen);
    free(buf);
    int good = clean == (s.nau < 50 ? s.nau : 50);
    free(s.adts); free(s.asc); free(s.au);
    return good;
}

/* random and mangled AudioSpecificConfigs (from several real ones: plain,
   explicit rate, HE-AAC, PCE): aac_init must return, and when it accepts
   one, decoding real frames must stay in bounds (the output buffer is
   exactly as big as the channel count aac_info reports) */
static int fuzz_asc(int count)
{
    static const char *bases[] = {"music_44100_s", "speech_64k_m", "multi_pce",
                                  "multi_6ch_pce", "music_44100_s_explicit",
                                  "music_44100_s_sbrsync", "speech_64k_m_ps29",
                                  "music_22050_s_sbr5", "speech_64k_m_lfe", "multi_8ch"};
    enum { NB = sizeof bases / sizeof bases[0] };
    Stream s[NB];
    for (int b = 0; b < NB; b++) load(bases[b], &s[b]);
    void *cbase, *obase, *ibase;
    size_t clen, olen, ilen;
    void *ctx = guarded(aac_ctx_size(), &cbase, &clen);
    int accepted = 0, decoded = 0;
    for (int i = 0; i < count; i++) {
        const Stream *st = &s[rnd() % NB];
        uint8_t asc[64];
        uint32_t n = rnd() % 40;
        if (rnd() % 4) {                            /* a real one, changed */
            uint32_t base = st->asclen < sizeof asc ? st->asclen : sizeof asc;
            memcpy(asc, st->asc, base);
            for (uint32_t k = base; k < sizeof asc; k++) asc[k] = rnd();
            int flips = 1 + rnd() % 3;
            for (int f = 0; f < flips; f++) asc[rnd() % (base + 1)] ^= 1 << (rnd() % 8);
            n = rnd() % 4 ? base : rnd() % (base + 4);  /* (sometimes cut or longer) */
        } else {                                    /* random bytes */
            for (uint32_t k = 0; k < n; k++) asc[k] = rnd();
        }
        uint8_t *a = guarded(n ? n : 1, &ibase, &ilen);
        a += n ? 0 : 1;
        memcpy(a, asc, n);
        alarm(5);
        in_decode = 1;
        int r = aac_init(ctx, a, n);
        in_decode = 0;
        alarm(0);
        munmap(ibase, ilen);
        if (r < 0) continue;
        accepted++;
        uint32_t rate, ch;
        if (aac_info(ctx, &rate, &ch) < 0 || ch < 1 || ch > 2 || rate < 7000 || rate > 100000) {
            printf("FAIL asc fuzz: accepted config gives rate %u channels %u\n", rate, ch);
            return 0;
        }
        int16_t *out = guarded(1024 * ch * sizeof(int16_t), &obase, &olen);
        for (int f = 0; f < 3; f++) {
            const AU *au = &st->au[rnd() % st->nau];
            uint8_t *in = guarded(au->len, &ibase, &ilen);
            memcpy(in, au->p, au->len);
            alarm(5);
            in_decode = 1;
            if (aac_decode(ctx, in, au->len, out) == 1024) decoded++;
            in_decode = 0;
            alarm(0);
            munmap(ibase, ilen);
        }
        munmap(obase, olen);
    }
    printf("ok   fuzz AudioSpecificConfig: %d tried, %d accepted, %d frames decoded with them\n",
           count, accepted, decoded);
    munmap(cbase, clen);
    for (int b = 0; b < NB; b++) { free(s[b].adts); free(s[b].asc); free(s[b].au); }
    return 1;
}

/* ------------------------------------------------------------ main */
int main(int argc, char **argv)
{
    int fuzz = 3000, nofuzz = 0, bench = 0;
    const char *only[64], *dump = NULL, *dump_to = NULL;
    int nonly = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--dir") && i + 1 < argc) dir = argv[++i];
        else if (!strcmp(argv[i], "--fuzz") && i + 1 < argc) fuzz = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--nofuzz")) nofuzz = 1;
        else if (!strcmp(argv[i], "--bench")) bench = 1;
        else if (!strcmp(argv[i], "--dump") && i + 2 < argc) {
            dump = argv[++i];
            dump_to = argv[++i];
        }
        else if (!strcmp(argv[i], "-v")) verbose = 1;
        else if (nonly < 64) only[nonly++] = argv[i];
    }
    signal(SIGALRM, on_alarm);
    printf("aac_ctx_size = %u bytes\n", aac_ctx_size());

    if (dump) {                         /* --dump CASE FILE: just the PCM */
        Stream s;
        load(dump, &s);
        int16_t *pcm;
        uint32_t rate, ch;
        double secs;
        int n = decode_all(&s, &pcm, &rate, &ch, &secs);
        if (n < 0) return 1;
        FILE *f = fopen(dump_to, "wb");
        if (!f || fwrite(pcm, 2, (size_t)n * 1024 * ch, f) != (size_t)n * 1024 * ch) return 2;
        fclose(f);
        printf("%s: %d frames, %u Hz, %u channels -> %s\n", dump, n, rate, ch, dump_to);
        return 0;
    }

    if (bench) {
        Stream s;
        load("long_music", &s);
        double best = 1e9;
        uint32_t rate = 0, ch = 0;
        int n = 0;
        for (int r = 0; r < 10; r++) {
            int16_t *pcm;
            double secs;
            n = decode_all(&s, &pcm, &rate, &ch, &secs);
            if (n < 0) return 1;
            free(pcm);
            if (secs < best) best = secs;
        }
        double dur = (double)n * 1024 / rate;
        printf("long_music: %.1f s of %u Hz %u-channel audio in %.3f s = %.0fx realtime\n", dur,
               rate, ch, best, dur / best);
        return 0;
    }

    char path[512];
    snprintf(path, sizeof path, "%s/manifest.txt", dir);
    FILE *m = fopen(path, "r");
    if (!m) { fprintf(stderr, "no %s - run python tests/native/aac_make.py\n", path); return 2; }
    char line[512];
    int total = 0, passed = 0;
    double dect = 0, audt = 0;
    while (fgets(line, sizeof line, m)) {
        /* NAME MODE [ARG] [rate=R] [ch=C]; # starts a comment line */
        char name[200] = "", mode[32] = "", arg[200] = "";
        uint32_t want_rate = 0, want_ch = 0;
        int ntok = 0;
        for (char *t = strtok(line, " \t\r\n"); t; t = strtok(NULL, " \t\r\n")) {
            if (ntok == 0 && t[0] == '#') break;
            if (!strncmp(t, "rate=", 5)) want_rate = atoi(t + 5);
            else if (!strncmp(t, "ch=", 3)) want_ch = atoi(t + 3);
            else if (ntok == 0) snprintf(name, sizeof name, "%s", t);
            else if (ntok == 1) snprintf(mode, sizeof mode, "%s", t);
            else if (ntok == 2) snprintf(arg, sizeof arg, "%s", t);
            ntok++;
        }
        if (!name[0] || !mode[0]) continue;
        if (nonly) {
            int hit = 0;
            for (int i = 0; i < nonly; i++) if (strstr(name, only[i])) hit = 1;
            if (!hit) continue;
        }
        total++;
        passed += run_case(name, mode, arg, want_rate, want_ch, &dect, &audt);
    }
    fclose(m);
    printf("%d of %d cases passed; %.1f s of audio decoded in %.2f s (%.0fx realtime)\n",
           passed, total, audt, dect, audt / dect);
    if (passed != total) mt_failures++;
    /* what the test data exercised: every tool of the decoder must have
       been reached by some case (when all cases ran) */
    printf("decoder events over all cases:\n");
    int col = 0;
    for (int i = 0; i < 64; i++) {
        if (!stat_name[i]) continue;
        printf("  %-20s %9llu%s", stat_name[i], (unsigned long long)stat_total[i],
               ++col % 3 ? "" : "\n");
    }
    if (col % 3) printf("\n");
    if (!nonly)
        for (int i = 0; i < 64; i++)
            MT_CHECK(!stat_name[i] || stat_total[i] > 0, "no test case reaches: %s",
                     stat_name[i]);
    if (!nofuzz && !nonly) {
        const char *fz[] = {"music_44100_s", "speech_64k_m", "clicks_128k", "is_wide_64k",
                            "pns_pink_64k", "tns_clicks", "music_96000_s", "music_8000_s",
                            "multi_pce", "multi_8ch", "music_44100_s_cce",
                            "music_44100_s_pulses", "pns_music_48k_pnsms",
                            "speech_64k_m_ps29", "music_22050_s_fil", "speech_64k_m_lfe"};
        for (unsigned i = 0; i < sizeof fz / sizeof fz[0]; i++)
            if (!fuzz_case(fz[i], fuzz)) mt_failures++;
        if (!fuzz_asc(fuzz)) mt_failures++;
    }
    MT_DONE();
}
