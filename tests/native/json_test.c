// modules: json
/* json_test.c - check src/json.asm against Python's json module, and fuzz it.

     python3 tests/native/json_data.py             make build/json/ (documents + references)
     python3 tests/native/run.py json              check everything
     python3 tests/native/run.py json fuzz [N] [seed]   N random / mutated documents
     python3 tests/native/run.py json bench        speed of json_parse

   The references (json_data.py) come from Python's json module. For a valid
   document every token is checked: its type, its "next" index, its place in
   the text (the quotes / brackets at start and end), its decoded content
   (json_str against Python's decoded string, json_eq), json_int against
   Python's reading of the number, and the object / array structure through
   json_key and json_index. json_parse must also count without storing
   (toks = NULL), fit exactly into `tokens` slots and give -2 with one fewer.
   An invalid document must give an error, the same with and without tokens
   (and the exact code where the reference names one: -3 for a cut-off
   text, -4 for nesting deeper than 1000). The documents and token arrays
   sit against inaccessible guard pages, so any read or write outside them
   crashes the test. The YouTube-shaped documents are also looked up by
   path (json_key / json_index down to a value, then json_int / json_str /
   json_eq), the way the player will use them. */
#include "moostest.h"
#include <sys/mman.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>

typedef struct { uint8_t type, pad[3]; uint32_t start, end, next; } jtok;
int json_parse(const char *js, uint32_t len, jtok *toks, uint32_t maxtoks);
int json_key(const char *js, const jtok *toks, int ntoks, int obj, const char *key);
int json_index(const jtok *toks, int ntoks, int arr, int i);
int json_str(const char *js, const jtok *tok, char *out, uint32_t cap);
int json_int(const char *js, const jtok *tok, int32_t *out);
int json_eq(const char *js, const jtok *tok, const char *s);

static const char *DIR = "build/json";

/* ---- buffers against guard pages ---- */
typedef struct { uint8_t *map; size_t maplen; uint8_t *p; } gbuf;

static void *galloc(gbuf *g, size_t n, int at_end)
{
    size_t pg = 4096, body = (n + pg - 1) / pg * pg;
    if (!body) body = pg;
    g->maplen = body + 2 * pg;
    g->map = mmap(NULL, g->maplen, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (g->map == MAP_FAILED) { perror("mmap"); exit(2); }
    mprotect(g->map, pg, PROT_NONE);
    mprotect(g->map + pg + body, pg, PROT_NONE);
    g->p = at_end ? g->map + pg + body - n : g->map + pg;
    return g->p;
}
static void gfree(gbuf *g) { munmap(g->map, g->maplen); }

/* ---- the reference ---- */
typedef struct { char kind; uint32_t next, count; uint8_t *data; uint32_t dlen; int ires; int32_t ival; } rtok;
typedef struct { int ok; int code; uint32_t n; rtok *t; uint8_t *arena; } ref_t;

static int hexval(int c) { return c <= '9' ? c - '0' : (c | 32) - 'a' + 10; }

/* parse a reference text (NUL-terminated, modified in place) */
static void parse_ref(char *s, ref_t *r)
{
    memset(r, 0, sizeof *r);
    char *line = strtok(s, "\n");
    if (!line) { fprintf(stderr, "empty reference\n"); exit(2); }
    if (!strncmp(line, "ERR", 3)) {
        r->code = strstr(line, "any") ? 0 : atoi(line + 4);
        return;
    }
    r->ok = 1;
    r->n = strtoul(line + 3, NULL, 10);
    r->t = calloc(r->n + 1, sizeof(rtok));
    size_t cap = strlen(s + strlen(line) + 1) + 16, used = 0;
    r->arena = malloc(cap);
    for (uint32_t i = 0; i < r->n; i++) {
        line = strtok(NULL, "\n");
        if (!line) { fprintf(stderr, "reference cut short\n"); exit(2); }
        rtok *t = &r->t[i];
        t->kind = line[0];
        char *p = line + 2;
        t->next = strtoul(p, &p, 10);
        p++;
        if (t->kind == 'o' || t->kind == 'a') { t->count = strtoul(p, NULL, 10); continue; }
        char *q = strchr(p, ' ');
        *q = 0;
        t->data = r->arena + used;
        if (t->kind == 's') {
            if (strcmp(p, "-"))
                for (; p[0] && p[1]; p += 2) t->data[t->dlen++] = hexval(p[0]) << 4 | hexval(p[1]);
        } else {
            t->dlen = strlen(p);
            memcpy(t->data, p, t->dlen);
        }
        t->data[t->dlen] = 0;
        used += t->dlen + 1;
        t->ires = strtol(q + 1, &q, 10);
        t->ival = strtol(q, NULL, 10);
    }
}
static void free_ref(ref_t *r) { free(r->t); free(r->arena); }

static uint32_t rng = 1;
static uint32_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }

/* longest prefix of b[0..n) of at most lim bytes that ends on a UTF-8 character boundary */
static uint32_t utf8_prefix(const uint8_t *b, uint32_t n, uint32_t lim)
{
    if (lim >= n) return n;
    while (lim > 0 && (b[lim] & 0xC0) == 0x80) lim--;
    return lim;
}

/* json_str of token t with room for cap bytes: must give the longest whole
   prefix of want and -2, or all of it */
static void check_str_cap(const char *name, uint32_t i, const char *js, const jtok *t, const uint8_t *want,
                          uint32_t wlen, uint32_t cap)
{
    gbuf g;
    char *out = galloc(&g, cap, 1);
    memset(out, 0x55, cap);
    int r = json_str(js, t, out, cap);
    if (cap > wlen) {
        MT_CHECK(r == (int)wlen && !memcmp(out, want, wlen) && out[wlen] == 0,
                 "%s: token %u: json_str (cap %u) = %d, expected %u bytes", name, i, cap, r, wlen);
    } else {
        uint32_t k = cap ? utf8_prefix(want, wlen, cap - 1) : 0;
        MT_CHECK(r == -2, "%s: token %u: json_str (cap %u < %u) = %d", name, i, cap, wlen + 1, r);
        if (cap)
            MT_CHECK(!memcmp(out, want, k) && out[k] == 0, "%s: token %u: json_str cut at cap %u: wrong (want %u bytes)",
                     name, i, cap, k);
    }
    gfree(&g);
}

/* the full check of a valid document against its reference */
static void check_ok(const char *name, const uint8_t *doc0, uint32_t len, const ref_t *ref, int deep)
{
    int f0 = mt_failures;
    gbuf gd, gt, gt2;
    char *js = galloc(&gd, len, 1);
    memcpy(js, doc0, len);
    uint32_t n = ref->n;
    int r = json_parse(js, len, NULL, 0);
    MT_CHECK(r == (int)n, "%s: counting gives %d, expected %u tokens", name, r, n);
    jtok *t = galloc(&gt, (size_t)n * 16, 1);
    memset(t, 0xAB, (size_t)n * 16);
    r = json_parse(js, len, t, n);
    MT_CHECK(r == (int)n, "%s: json_parse = %d, expected %u", name, r, n);
    if (r != (int)n) { gfree(&gt); gfree(&gd); return; }
    jtok *t2 = galloc(&gt2, (size_t)(n - 1) * 16, 1);
    r = json_parse(js, len, t2, n - 1);
    MT_CHECK(r == -2, "%s: with %u token slots: %d (expected -2)", name, n - 1, r);
    gfree(&gt2);

    int bad = 0;
    for (uint32_t i = 0; i < n && bad < 5; i++) {
        const jtok *k = &t[i];
        const rtok *w = &ref->t[i];
        static const char kinds[] = " oasp";
        int kb = mt_failures;
        MT_CHECK(k->type >= 1 && k->type <= 4 && kinds[k->type] == w->kind, "%s: token %u: type %u, expected %c",
                 name, i, k->type, w->kind);
        MT_CHECK(!k->pad[0] && !k->pad[1] && !k->pad[2], "%s: token %u: pad not 0", name, i);
        MT_CHECK(k->next == w->next, "%s: token %u: next %u, expected %u", name, i, k->next, w->next);
        MT_CHECK(k->start <= k->end && k->end <= len, "%s: token %u: start %u end %u (len %u)", name, i,
                 k->start, k->end, len);
        if (mt_failures != kb) { bad++; continue; }
        if (w->kind == 'o' || w->kind == 'a') {
            MT_CHECK(js[k->start] == (w->kind == 'o' ? '{' : '[') && js[k->end - 1] == (w->kind == 'o' ? '}' : ']'),
                     "%s: token %u: container text %u..%u", name, i, k->start, k->end);
        } else if (w->kind == 's') {
            MT_CHECK(k->start > 0 && js[k->start - 1] == '"' && k->end < len && js[k->end] == '"',
                     "%s: token %u: string not between quotes", name, i);
        } else {
            MT_CHECK(k->end - k->start == w->dlen && !memcmp(js + k->start, w->data, w->dlen),
                     "%s: token %u: primitive text differs (expected %s)", name, i, w->data);
        }
        if (w->kind == 's' || w->kind == 'p') {
            /* json_str: everything, then cut off at a few sizes */
            check_str_cap(name, i, js, k, w->data, w->dlen, w->dlen + 1);
            if (!deep || i % 97 == 0) {
                check_str_cap(name, i, js, k, w->data, w->dlen, w->dlen);
                check_str_cap(name, i, js, k, w->data, w->dlen, 0);
                check_str_cap(name, i, js, k, w->data, w->dlen, 1);
                if (w->dlen > 2) check_str_cap(name, i, js, k, w->data, w->dlen, 1 + rnd() % w->dlen);
            }
            /* json_eq: equal to its content; not to a longer or shorter one */
            if (!memchr(w->data, 0, w->dlen)) {
                MT_CHECK(json_eq(js, k, (const char *)w->data) == 1, "%s: token %u: json_eq false", name, i);
                char *x = malloc(w->dlen + 2);
                memcpy(x, w->data, w->dlen);
                x[w->dlen] = 'x';
                x[w->dlen + 1] = 0;
                MT_CHECK(json_eq(js, k, x) == 0, "%s: token %u: json_eq with one more byte", name, i);
                if (w->dlen) {
                    x[w->dlen - 1] = 0;
                    MT_CHECK(json_eq(js, k, x) == 0, "%s: token %u: json_eq with one byte less", name, i);
                }
                free(x);
            }
            /* json_int (strings: only when the text has no escapes, as MOOS
               reads the text as it is) */
            int raw = w->kind == 'p' || (k->end - k->start == w->dlen && !memcmp(js + k->start, w->data, w->dlen));
            if (raw) {
                int32_t v = 0x5A5A5A5A;
                int ir = json_int(js, k, &v);
                MT_CHECK(ir == w->ires && (ir == -1 ? v == 0x5A5A5A5A : v == w->ival),
                         "%s: token %u: json_int = %d (%d), expected %d (%d) for %.40s", name, i, ir, v,
                         w->ires, w->ival, w->data);
            }
        } else {
            int32_t v;
            MT_CHECK(json_int(js, k, &v) == -1, "%s: token %u: json_int on a container", name, i);
        }
    }
    /* structure: members through json_key, elements through json_index */
    uint32_t checks = 0;
    for (uint32_t i = 0; i < n && bad < 5; i++) {
        const rtok *w = &ref->t[i];
        if (w->kind == 'a') {
            uint32_t j = i + 1, m = 0;
            while (j < w->next) {
                if (m < 40 || m + 3 > w->count || rnd() % 64 == 0) {
                    int e = json_index(t, n, i, m);
                    if (e != (int)j && bad++ < 5) MT_CHECK(0, "%s: json_index(%u, %u) = %d, expected %u", name, i, m, e, j);
                    checks++;
                }
                j = ref->t[j].next;
                m++;
            }
            MT_CHECK(m == w->count, "%s: array %u: %u elements, expected %u", name, i, m, w->count);
            MT_CHECK(json_index(t, n, i, m) == -1 && json_index(t, n, i, -1) == -1,
                     "%s: json_index past the end of array %u", name, i);
            MT_CHECK(json_key(js, t, n, i, "a") == -1, "%s: json_key on array %u", name, i);
        } else if (w->kind == 'o') {
            uint32_t j = i + 1, m = 0;
            while (j < w->next) {
                const rtok *key = &ref->t[j];
                if ((m < 40 || rnd() % 64 == 0) && !memchr(key->data, 0, key->dlen)) {
                    /* the value of the last member with this key */
                    uint32_t want = 0, jj = i + 1;
                    while (jj < w->next) {
                        const rtok *k2 = &ref->t[jj];
                        if (k2->dlen == key->dlen && !memcmp(k2->data, key->data, key->dlen)) want = jj + 1;
                        jj = k2->next;
                    }
                    int e = json_key(js, t, n, i, (const char *)key->data);
                    if (e != (int)want && bad++ < 5)
                        MT_CHECK(0, "%s: json_key(%u, \"%s\") = %d, expected %u", name, i, key->data, e, want);
                    checks++;
                }
                j = key->next;
                m++;
            }
            MT_CHECK(m == w->count, "%s: object %u: %u members, expected %u", name, i, m, w->count);
            MT_CHECK(json_key(js, t, n, i, "\x01no such key") == -1, "%s: json_key found a missing key", name);
            MT_CHECK(json_index(t, n, i, 0) == -1, "%s: json_index on object %u", name, i);
        } else if (i % 13 == 0) {
            MT_CHECK(json_key(js, t, n, i, "") == -1 && json_index(t, n, i, 0) == -1,
                     "%s: json_key / json_index on a scalar", name);
        }
    }
    MT_CHECK(json_key(js, t, n, n, "a") == -1 && json_index(t, n, n, 0) == -1 && json_key(js, t, n, -1, "a") == -1,
             "%s: token index out of range accepted", name);
    (void)checks;
    if (mt_failures != f0) fprintf(stderr, "  (%s: %u bytes: %.60s)\n", name, len, js);
    gfree(&gt);
    gfree(&gd);
}

static void check_err(const char *name, const uint8_t *doc0, uint32_t len, const ref_t *ref)
{
    gbuf gd, gt;
    char *js = galloc(&gd, len, 1);
    memcpy(js, doc0, len);
    uint32_t cap = len + 2;
    jtok *t = galloc(&gt, (size_t)cap * 16, 1);
    int a = json_parse(js, len, NULL, 0);
    int b = json_parse(js, len, t, cap);
    MT_CHECK(a < 0 && a != -2 && a >= -4, "%s: invalid document gives %d (counting)", name, a);
    MT_CHECK(a == b, "%s: counting gives %d, storing %d", name, a, b);
    if (ref->code) MT_CHECK(a == ref->code, "%s: gives %d, expected %d", name, a, ref->code);
    if (a >= 0 || (ref->code && a != ref->code)) fprintf(stderr, "  (%s: %u bytes: %.80s)\n", name, len, js);
    gfree(&gt);
    gfree(&gd);
}

/* ---- path lookups (player / search) ---- */
static int lookup(const char *js, const jtok *t, int n, char *path, int *last_ok)
{
    int cur = 0;
    *last_ok = 1;
    if (!strcmp(path, ".")) return 0;
    for (char *seg = strtok(path, "/"); seg; seg = strtok(NULL, "/")) {
        if (!strcmp(seg, ".")) continue;
        if (cur < 0) { *last_ok = 0; return -1; }
        cur = seg[0] == '#' ? json_index(t, n, cur, atoi(seg + 1)) : json_key(js, t, n, cur, seg);
    }
    return cur;
}

static void check_paths(const char *name, const char *js, uint32_t len, const jtok *t, int n)
{
    char path[512];
    snprintf(path, sizeof path, "%s/%s.exp", DIR, name);
    uint32_t elen;
    char *exp = (char *)mt_read(path, &elen);
    int lines = 0, bad = 0;
    for (char *save = NULL, *line = strtok_r(exp, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        char p[2048], op[8], a[1 << 16];
        int ires = 0, ival = 0, cnt = 0;
        a[0] = 0;
        sscanf(line, "%2047s %7s %65535s %d %d", p, op, a, &ires, &ival);
        lines++;
        int ok;
        int f0 = mt_failures;
        int i = lookup(js, t, n, p, &ok);
        if (!strcmp(op, "none")) {
            MT_CHECK(i == -1 && ok, "%s: line %d: %s: found %d, expected nothing", name, lines, line, i);
        } else if (i < 0) {
            MT_CHECK(0, "%s: line %d: path not found: %s", name, lines, line);
        } else if (!strcmp(op, "len")) {
            cnt = atoi(a);
            if (t[i].type == 2) {
                MT_CHECK((cnt == 0 || json_index(t, n, i, cnt - 1) >= 0) && json_index(t, n, i, cnt) == -1,
                         "%s: %s: array length differs", name, line);
            } else {
                int m = 0;
                for (uint32_t j = i + 1; j < t[i].next; j = t[j].next) m++;
                MT_CHECK(t[i].type == 1 && m == cnt, "%s: %s: %d members", name, line, m);
            }
        } else {
            uint8_t want[1 << 15];
            uint32_t wl = 0;
            if (!strcmp(op, "str")) {
                MT_CHECK(t[i].type == 3, "%s: %s: not a string", name, line);
                if (strcmp(a, "-"))
                    for (char *q = a; q[0] && q[1]; q += 2) want[wl++] = hexval(q[0]) << 4 | hexval(q[1]);
            } else {
                MT_CHECK(t[i].type == 4, "%s: %s: not a primitive", name, line);
                wl = strlen(a);
                memcpy(want, a, wl);
            }
            want[wl] = 0;
            static char out[1 << 15];
            int r = json_str(js, &t[i], out, sizeof out);
            MT_CHECK(r == (int)wl && !memcmp(out, want, wl), "%s: %s: json_str = %d: %.60s", name, line, r, out);
            if (!memchr(want, 0, wl)) MT_CHECK(json_eq(js, &t[i], (char *)want) == 1, "%s: %s: json_eq", name, line);
            if (t[i].type == 4 || (t[i].end - t[i].start == wl && !memcmp(js + t[i].start, want, wl))) {
                int32_t v = 0x5A5A5A5A;
                int ir = json_int(js, &t[i], &v);
                MT_CHECK(ir == ires && (ir == -1 || v == ival), "%s: %s: json_int = %d (%d)", name, line, ir, v);
            }
        }
        if (mt_failures != f0 && ++bad > 8) break;
    }
    (void)len;
    printf("  %-20s %d path lookups\n", name, lines);
    free(exp);
}

/* ---- the whole check ---- */
static void check_cases(void)
{
    char path[512];
    snprintf(path, sizeof path, "%s/cases.bin", DIR);
    uint32_t flen;
    uint8_t *f = mt_read(path, &flen);
    uint32_t pos = 0, nc = 0, nok = 0, nerr = 0;
    long toks = 0;
    while (pos + 4 <= flen && mt_failures < 30) {
        uint32_t dl, rl;
        memcpy(&dl, f + pos, 4);
        const uint8_t *doc = f + pos + 4;
        memcpy(&rl, f + pos + 4 + dl, 4);
        char *rt = malloc(rl + 1);
        memcpy(rt, f + pos + 8 + dl, rl);
        rt[rl] = 0;
        pos += 8 + dl + rl;
        ref_t ref;
        parse_ref(rt, &ref);
        char name[32];
        snprintf(name, sizeof name, "case %u", nc);
        if (ref.ok) { check_ok(name, doc, dl, &ref, ref.n > 2000); nok++; toks += ref.n; }
        else { check_err(name, doc, dl, &ref); nerr++; }
        free_ref(&ref);
        free(rt);
        nc++;
    }
    printf("  cases.bin            %u documents: %u valid (%ld tokens), %u invalid\n", nc, nok, toks, nerr);
    free(f);
}

static void check_file(const char *name)
{
    char path[512];
    snprintf(path, sizeof path, "%s/%s", DIR, name);
    uint32_t len, rl;
    uint8_t *doc = mt_read(path, &len);
    snprintf(path, sizeof path, "%s/%.*s.ref", DIR, (int)strlen(name) - 5, name);
    char *rt = (char *)mt_read(path, &rl);
    ref_t ref;
    parse_ref(rt, &ref);
    int f0 = mt_failures;
    check_ok(name, doc, len, &ref, 1);
    printf("  %-20s %s %8u bytes %7u tokens\n", name, mt_failures == f0 ? "ok  " : "FAIL", len, ref.n);
    snprintf(path, sizeof path, "%s/%.*s.exp", DIR, (int)strlen(name) - 5, name);
    if (access(path, R_OK) == 0) {
        jtok *t = malloc((size_t)ref.n * 16);
        int n = json_parse((char *)doc, len, t, ref.n);
        char base[64];
        snprintf(base, sizeof base, "%.*s", (int)strlen(name) - 5, name);
        check_paths(base, (char *)doc, len, t, n);
        free(t);
    }
    free_ref(&ref);
    free(rt);
    free(doc);
}

/* hand-made checks of the API edges */
static void check_api(void)
{
    static const char js[] = "{\"a\":\"x\\u00e9\\ud83d\\ude00\",\"n\":-2147483648,\"big\":2147483648,"
                             "\"f\":-6.83,\"e\":1e3,\"s\":\"12345\",\"neg\":\"-0.9\",\"z\":\"\\u0000\",\"a\":[1,2]}";
    jtok t[32];
    int n = json_parse(js, sizeof js - 1, t, 32);
    MT_CHECK(n == 21, "api: %d tokens", n);
    int a = json_key(js, t, n, 0, "a");
    MT_CHECK(a >= 0 && t[a].type == 2, "api: duplicate key: the last one counts (%d)", a);
    MT_CHECK(json_index(t, n, a, 1) == a + 2 && json_index(t, n, a, 2) == -1, "api: json_index");
    int32_t v = 0;
    MT_CHECK(json_int(js, &t[json_key(js, t, n, 0, "n")], &v) == 0 && v == (int32_t)0x80000000, "api: int32 min");
    MT_CHECK(json_int(js, &t[json_key(js, t, n, 0, "big")], &v) == -2 && v == 0x7FFFFFFF, "api: 2^31");
    MT_CHECK(json_int(js, &t[json_key(js, t, n, 0, "f")], &v) == 0 && v == -6, "api: -6.83");
    v = 77;
    MT_CHECK(json_int(js, &t[json_key(js, t, n, 0, "e")], &v) == -1 && v == 77, "api: 1e3");
    MT_CHECK(json_int(js, &t[json_key(js, t, n, 0, "s")], &v) == 0 && v == 12345, "api: \"12345\"");
    MT_CHECK(json_int(js, &t[json_key(js, t, n, 0, "neg")], &v) == 0 && v == 0, "api: \"-0.9\"");
    char out[16];
    int s1 = 1;                         /* the first "a": x e9 + U+1F600 */
    MT_CHECK(json_str(js, &t[s1 + 1], out, sizeof out) == 7 && !memcmp(out, "x\xc3\xa9\xf0\x9f\x98\x80", 8),
             "api: \\u escapes and a surrogate pair");
    MT_CHECK(json_str(js, &t[s1 + 1], out, 7) == -2 && !strcmp(out, "x\xc3\xa9"), "api: cut before the emoji");
    MT_CHECK(json_str(js, &t[s1 + 1], out, 3) == -2 && !strcmp(out, "x"), "api: cut before e9");
    int z = json_key(js, t, n, 0, "z");
    MT_CHECK(json_str(js, &t[z], out, sizeof out) == 1 && out[0] == 0 && out[1] == 0, "api: \\u0000");
    MT_CHECK(json_eq(js, &t[z], "") == 0, "api: json_eq(\\u0000, \"\")");
    MT_CHECK(json_eq(js, &t[s1], "a") == 1 && json_eq(js, &t[s1], "ab") == 0 && json_eq(js, &t[s1], "") == 0,
             "api: json_eq on a key");
    MT_CHECK(json_key(js, t, n, 0, "x\xc3\xa9") == -1, "api: prefix of a key");
    /* raw UTF-8 cut in the middle */
    static const char u[] = "[\"ab\xe4\xb8\xad\xf0\x9f\x98\x80\"]";
    jtok tu[2];
    MT_CHECK(json_parse(u, sizeof u - 1, tu, 2) == 2, "api: utf8 doc");
    MT_CHECK(json_str(u, &tu[1], out, 5) == -2 && !strcmp(out, "ab"), "api: raw UTF-8 cut (3 of 4)");
    MT_CHECK(json_str(u, &tu[1], out, 6) == -2 && !strcmp(out, "ab\xe4\xb8\xad"), "api: raw UTF-8 cut (whole)");
    MT_CHECK(json_str(u, &tu[1], out, 9) == -2 && !strcmp(out, "ab\xe4\xb8\xad"), "api: raw UTF-8 cut (emoji)");
    MT_CHECK(json_parse(NULL, 0, NULL, 0) == -3, "api: nothing");
    MT_CHECK(json_parse("[1]", 3, t, 0) == -2, "api: no room");
    printf("  API edge cases        done\n");
}

/* ---- fuzzing ---- */
static void on_alarm(int sig) { (void)sig; fprintf(stderr, "FAIL: hang (alarm)\n"); _exit(3); }

/* whatever json_parse returns must be self-consistent; then poke the API */
static void fuzz_one(const uint8_t *src, uint32_t len)
{
    gbuf gd, gt;
    char *js = galloc(&gd, len, rnd() & 1);
    memcpy(js, src, len);
    uint32_t cap = rnd() % 4 ? len + 2 : rnd() % (len + 2);
    jtok *t = galloc(&gt, (size_t)cap * 16, 1);
    alarm(10);
    int n = json_parse(js, len, t, cap);
    int c = json_parse(js, len, NULL, 0);
    alarm(0);
    MT_CHECK(n >= -4 && n != 0, "fuzz: result %d", n);
    MT_CHECK(n == c || (n == -2 && (c > (int)cap || c < 0)), "fuzz: stored %d, counted %d", n, c);
    if (n > 0) {
        MT_CHECK(t[0].next == (uint32_t)n, "fuzz: first token's next %u of %d", t[0].next, n);
        for (int i = 0; i < n; i++) {
            const jtok *k = &t[i];
            MT_CHECK(k->type >= 1 && k->type <= 4 && k->start <= k->end && k->end <= len &&
                     k->next > (uint32_t)i && k->next <= (uint32_t)n, "fuzz: token %d bad", i);
            if (k->type == 3) MT_CHECK(k->start && js[k->start - 1] == '"' && k->end < len && js[k->end] == '"',
                                       "fuzz: string %d", i);
            if (k->type <= 2) {
                uint32_t j = i + 1, m = 0;
                while (j < k->next) {
                    MT_CHECK(t[j].start >= k->start && t[j].end <= k->end, "fuzz: child outside parent");
                    if (k->type == 1) MT_CHECK(t[j].type == 3 && j + 1 < k->next, "fuzz: object member");
                    j = t[j].next;
                    m++;
                    if (mt_failures > 20) break;
                }
                MT_CHECK(j == k->next, "fuzz: children of %d end at %u, not %u", i, j, k->next);
                if (k->type == 2 && m) MT_CHECK(json_index(t, n, i, m - 1) >= 0 && json_index(t, n, i, m) == -1,
                                                "fuzz: json_index");
            }
            if (rnd() % 4 == 0) {
                gbuf go;
                uint32_t oc = rnd() % 64;
                char *o = galloc(&go, oc, 1);
                int r = json_str(js, k, o, oc);
                MT_CHECK(r >= -2 && r < (int)(oc ? oc : 1), "fuzz: json_str %d", r);
                gfree(&go);
                int32_t v;
                json_int(js, k, &v);
                static const char *keys[] = { "", "a", "itag", "\xc3\xa9", "ab", "true", "1" };
                json_eq(js, k, keys[rnd() % 7]);
                json_key(js, t, n, i, keys[rnd() % 7]);
                json_index(t, n, i, rnd() % 8);
            }
            if (mt_failures > 20) break;
        }
    }
    gfree(&gt);
    gfree(&gd);
}

static int fuzz(int iters, uint32_t seed)
{
    rng = seed ? seed : 1;
    signal(SIGALRM, on_alarm);
    char path[512];
    snprintf(path, sizeof path, "%s/cases.bin", DIR);
    uint32_t flen;
    uint8_t *f = mt_read(path, &flen);
    /* the valid documents of cases.bin are the seeds */
    uint32_t *off = NULL, *lens = NULL, nd = 0, pos = 0;
    while (pos + 4 <= flen) {
        uint32_t dl, rl;
        memcpy(&dl, f + pos, 4);
        memcpy(&rl, f + pos + 4 + dl, 4);
        if (!memcmp(f + pos + 8 + dl, "OK", 2) && dl < 20000) {
            off = realloc(off, (nd + 1) * 4);
            lens = realloc(lens, (nd + 1) * 4);
            off[nd] = pos + 4;
            lens[nd++] = dl;
        }
        pos += 8 + dl + rl;
    }
    static const char alpha[] = "{}[],:\"\\0123456789-+.eEtrufalsn \n\t\x01\x80\xff/u";
    uint8_t *buf = malloc(1 << 16);
    long nok = 0, nerr[5] = {0};
    for (int it = 0; it < iters && mt_failures <= 20; it++) {
        uint32_t len;
        int kind = rnd() % 10;
        if (kind < 6) {                 /* a valid document, mutated */
            uint32_t d = rnd() % nd;
            len = lens[d];
            memcpy(buf, f + off[d], len);
            int m = 1 + rnd() % 6;
            for (int j = 0; j < m; j++) {
                uint32_t p = len ? rnd() % len : 0;
                switch (rnd() % 5) {
                case 0: if (len) buf[p] = alpha[rnd() % (sizeof alpha - 1)]; break;
                case 1: if (len) buf[p] = rnd(); break;
                case 2: if (len < 60000) { memmove(buf + p + 1, buf + p, len - p); buf[p] = alpha[rnd() % (sizeof alpha - 1)]; len++; } break;
                case 3: if (len) { memmove(buf + p, buf + p + 1, len - p - 1); len--; } break;
                default: len = len ? rnd() % len : 0; break;
                }
            }
        } else if (kind < 9) {          /* random bytes from JSON's alphabet */
            len = rnd() % 300;
            for (uint32_t j = 0; j < len; j++) buf[j] = alpha[rnd() % (sizeof alpha - 1)];
        } else {                        /* deep nesting */
            uint32_t d = rnd() % 1100;
            len = 0;
            for (uint32_t j = 0; j < d && len < 60000; j++) {
                if (rnd() & 1) buf[len++] = '[';
                else { memcpy(buf + len, "{\"k\":", 5); len += 5; }
            }
            buf[len++] = '0';
            for (uint32_t j = 0; j < d && len < 65000; j++) buf[len++] = rnd() % 3 ? ']' : '}';
        }
        fuzz_one(buf, len);
        int n = json_parse((char *)buf, len, NULL, 0);
        if (n > 0) nok++; else nerr[-n]++;
    }
    printf("fuzz: %d documents: %ld valid, %ld invalid (-1), %ld cut short (-3), %ld too deep (-4)\n", iters,
           nok, nerr[1], nerr[3], nerr[4]);
    free(buf);
    free(f);
    MT_DONE();
}

/* ---- speed ---- */
static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int bench(void)
{
    static const char *files[] = { "big.json", "strings.json", "player.json", "player_compact.json",
                                   "search.json", "search_pretty.json" };
    for (unsigned k = 0; k < sizeof files / sizeof *files; k++) {
        char path[512];
        snprintf(path, sizeof path, "%s/%s", DIR, files[k]);
        uint32_t len;
        char *js = (char *)mt_read(path, &len);
        int n = json_parse(js, len, NULL, 0);
        jtok *t = malloc((size_t)n * 16);
        int reps = 1 + 200000000 / (len + 1);
        if (reps > 2000) reps = 2000;
        double t0 = now();
        for (int i = 0; i < reps; i++) json_parse(js, len, t, n);
        double t1 = now();
        for (int i = 0; i < reps; i++) json_parse(js, len, NULL, 0);
        double t2 = now();
        double s = (t1 - t0) / reps, c = (t2 - t1) / reps;
        printf("%-20s %8u bytes %7d tokens: %7.1f MB/s (%5.1f M tokens/s), counting only %7.1f MB/s, %.2f ms\n",
               files[k], len, n, len / s / 1e6, n / s / 1e6, len / c / 1e6, s * 1e3);
        free(t);
        free(js);
    }
    return 0;
}

int main(int argc, char **argv)
{
    if (argc > 1 && !strcmp(argv[1], "fuzz"))
        return fuzz(argc > 2 ? atoi(argv[2]) : 20000, argc > 3 ? strtoul(argv[3], 0, 0) : 1);
    if (argc > 1 && !strcmp(argv[1], "bench")) return bench();
    check_api();
    check_cases();
    char path[512];
    snprintf(path, sizeof path, "%s/list.txt", DIR);
    FILE *lf = fopen(path, "r");
    if (!lf) { fprintf(stderr, "no %s - run: python3 tests/native/json_data.py\n", path); return 2; }
    char line[256];
    while (fgets(line, sizeof line, lf)) {
        line[strcspn(line, "\r\n")] = 0;
        if (line[0] && (argc < 2 || !strcmp(argv[1], line))) check_file(line);
    }
    fclose(lf);
    MT_DONE();
}
