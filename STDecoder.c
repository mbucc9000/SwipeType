// SwipeType — gesture decoder.
//
// Template matching in the spirit of SHARK2 (Kristensson & Zhai): every candidate word's ideal
// path runs through its key centres; both paths are resampled to ST_N evenly spaced points and
// compared point by point, with extra weight on the start and end. Distances are measured in
// "key units" (x / key pitch, y / row pitch) so portrait and landscape behave the same.
// Score = -(geo^2) / (2 sigma^2) + ln(10) * zipf, i.e. a Gaussian path likelihood times a
// unigram frequency prior. Constants were tuned on simulated iPhone 5 swipes (93% top-1,
// 99% top-3 on clean ones).

#include "STDecoder.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#define ST_N           32       // resampled points per path
#define ST_MAX_KEYS    32       // longest collapsed key sequence considered
#define ST_MAX_POINTS  1024     // gesture points used (longer gestures are subsampled)
#define ST_RADIUS      1.0f     // first/last letter must be this close to the path ends
#define ST_LEN_MAX     1.6f     // template length <= gesture length * this + slack
#define ST_LEN_MIN     0.35f    // template length >= gesture length * this - slack
#define ST_LEN_SLACK   1.0f
#define ST_END_WEIGHT  0.6f
#define ST_SIGMA       0.15f
#define ST_LN10        2.302585093f

struct STLexicon {
    const char *text;         // NUL-separated words (not owned)
    int count;
    uint32_t *wordOffset;     // word start in text
    float *zipf;
    uint32_t *keyOffset;      // start in keys
    uint8_t *keyLen;          // 0 = not swipeable (fewer than 2 distinct keys, odd chars)
    uint8_t *keys;            // collapsed letter indices
    uint32_t bucketStart[ST_LETTERS * ST_LETTERS + 1];
    uint32_t *bucketWords;    // word indices grouped by (first letter, last letter)
};

static inline float STDist(STPoint a, STPoint b) {
    float dx = a.x - b.x, dy = a.y - b.y;
    return sqrtf(dx * dx + dy * dy);
}

// Resamples the polyline v[0..nv) to m evenly spaced points. Returns its length.
static float STResample(const STPoint *v, int nv, STPoint *out, int m) {
    float total = 0;
    for (int i = 1; i < nv; i++) {
        total += STDist(v[i - 1], v[i]);
    }
    if (nv < 2 || total <= 1e-6f) {
        for (int i = 0; i < m; i++) {
            out[i] = v[0];
        }
        return total;
    }
    float step = total / (float)(m - 1);
    int seg = 0;
    float segStart = 0;
    float segLen = STDist(v[0], v[1]);
    for (int i = 0; i < m; i++) {
        float t = (i == m - 1) ? total : step * (float)i;
        while (seg < nv - 2 && segStart + segLen < t) {
            segStart += segLen;
            seg++;
            segLen = STDist(v[seg], v[seg + 1]);
        }
        float f = segLen > 1e-9f ? (t - segStart) / segLen : 0;
        if (f < 0) {
            f = 0;
        } else if (f > 1) {
            f = 1;
        }
        out[i].x = v[seg].x + f * (v[seg + 1].x - v[seg].x);
        out[i].y = v[seg].y + f * (v[seg + 1].y - v[seg].y);
    }
    return total;
}

STLexicon *STLexiconCreate(const char *words, const uint16_t *scores, int count) {
    if (!words || !scores || count <= 0) {
        return NULL;
    }
    STLexicon *lex = (STLexicon *)calloc(1, sizeof(STLexicon));
    if (!lex) {
        return NULL;
    }
    lex->text = words;

    // One pass to size the key pool (never more keys than letters).
    size_t letters = 0;
    const char *p = words;
    for (int w = 0; w < count; w++) {
        size_t len = strlen(p);
        letters += len;
        p += len + 1;
    }
    lex->wordOffset = (uint32_t *)malloc(sizeof(uint32_t) * (size_t)count);
    lex->zipf = (float *)malloc(sizeof(float) * (size_t)count);
    lex->keyOffset = (uint32_t *)malloc(sizeof(uint32_t) * (size_t)count);
    lex->keyLen = (uint8_t *)calloc((size_t)count, 1);
    lex->keys = (uint8_t *)malloc(letters + 1);
    if (!lex->wordOffset || !lex->zipf || !lex->keyOffset || !lex->keyLen || !lex->keys) {
        STLexiconFree(lex);
        return NULL;
    }

    uint32_t keyPool = 0;
    p = words;
    for (int w = 0; w < count; w++) {
        lex->wordOffset[w] = (uint32_t)(p - words);
        lex->zipf[w] = (float)scores[w] / 100.0f;
        lex->keyOffset[w] = keyPool;
        int n = 0;
        int ok = 1;
        const char *c = p;
        for (; *c; c++) {
            if (*c == '\'') {
                continue;
            }
            if (*c < 'a' || *c > 'z') {
                ok = 0;
                continue;
            }
            uint8_t k = (uint8_t)(*c - 'a');
            if (ok && (n == 0 || lex->keys[keyPool + n - 1] != k)) {
                if (n >= ST_MAX_KEYS) {
                    ok = 0;
                    continue;
                }
                lex->keys[keyPool + n++] = k;
            }
        }
        if (ok && n >= 2) {
            lex->keyLen[w] = (uint8_t)n;
            keyPool += (uint32_t)n;
        }
        p = c + 1;
    }
    lex->count = count;

    // Group swipeable words by (first, last) letter; file order (frequency) is kept.
    uint32_t counts[ST_LETTERS * ST_LETTERS];
    memset(counts, 0, sizeof(counts));
    uint32_t total = 0;
    for (int w = 0; w < lex->count; w++) {
        if (lex->keyLen[w]) {
            const uint8_t *k = lex->keys + lex->keyOffset[w];
            counts[k[0] * ST_LETTERS + k[lex->keyLen[w] - 1]]++;
            total++;
        }
    }
    lex->bucketWords = (uint32_t *)malloc(sizeof(uint32_t) * (total ? total : 1));
    if (!lex->bucketWords) {
        STLexiconFree(lex);
        return NULL;
    }
    lex->bucketStart[0] = 0;
    for (int b = 0; b < ST_LETTERS * ST_LETTERS; b++) {
        lex->bucketStart[b + 1] = lex->bucketStart[b] + counts[b];
    }
    uint32_t fill[ST_LETTERS * ST_LETTERS];
    memcpy(fill, lex->bucketStart, sizeof(fill));
    for (int w = 0; w < lex->count; w++) {
        if (lex->keyLen[w]) {
            const uint8_t *k = lex->keys + lex->keyOffset[w];
            lex->bucketWords[fill[k[0] * ST_LETTERS + k[lex->keyLen[w] - 1]]++] = (uint32_t)w;
        }
    }
    return lex;
}

void STLexiconFree(STLexicon *lex) {
    if (!lex) {
        return;
    }
    free(lex->wordOffset);
    free(lex->zipf);
    free(lex->keyOffset);
    free(lex->keyLen);
    free(lex->keys);
    free(lex->bucketWords);
    free(lex);
}

int STLexiconCount(const STLexicon *lex) {
    return lex ? lex->count : 0;
}

const char *STLexiconWord(const STLexicon *lex, int index) {
    if (!lex || index < 0 || index >= lex->count) {
        return NULL;
    }
    return lex->text + lex->wordOffset[index];
}

int STDecode(const STLexicon *lex, const STKeyMap *keys, const STPoint *points, int count,
             STCandidate *out, int maxOut) {
    if (!lex || !keys || !points || count < 2 || !out || maxOut <= 0) {
        return 0;
    }
    if (maxOut > ST_MAX_CANDIDATES) {
        maxOut = ST_MAX_CANDIDATES;
    }
    if (keys->pitchX <= 0 || keys->pitchY <= 0) {
        return 0;
    }
    float sx = 1.0f / keys->pitchX, sy = 1.0f / keys->pitchY;

    // Gesture in key units, without repeated points; very long gestures are subsampled.
    static const int maxPts = ST_MAX_POINTS;
    STPoint g[ST_MAX_POINTS];
    int stride = (count + maxPts - 1) / maxPts;
    int ng = 0;
    for (int i = 0; i < count; i += stride) {
        STPoint q = { points[i].x * sx, points[i].y * sy };
        if (ng == 0 || STDist(q, g[ng - 1]) > 1e-3f) {
            g[ng++] = q;
        }
    }
    STPoint last = { points[count - 1].x * sx, points[count - 1].y * sy };
    if (ng > 0 && STDist(last, g[ng - 1]) > 1e-3f) {
        if (ng < maxPts) {
            g[ng++] = last;
        } else {
            g[ng - 1] = last;
        }
    }
    if (ng < 2) {
        return 0;
    }
    STPoint G[ST_N];
    float gl = STResample(g, ng, G, ST_N);

    STPoint centers[ST_LETTERS];
    int starts[ST_LETTERS], ends[ST_LETTERS];
    int ns = 0, ne = 0;
    for (int c = 0; c < ST_LETTERS; c++) {
        centers[c].x = keys->center[c].x * sx;
        centers[c].y = keys->center[c].y * sy;
        if (!keys->present[c]) {
            continue;
        }
        if (STDist(centers[c], G[0]) <= ST_RADIUS) {
            starts[ns++] = c;
        }
        if (STDist(centers[c], G[ST_N - 1]) <= ST_RADIUS) {
            ends[ne++] = c;
        }
    }

    const float inv2s2 = 1.0f / (2.0f * ST_SIGMA * ST_SIGMA);
    const float lenHi = gl * ST_LEN_MAX + ST_LEN_SLACK;
    const float lenLo = gl * ST_LEN_MIN - ST_LEN_SLACK;
    int found = 0;
    STPoint tv[ST_MAX_KEYS];
    STPoint tr[ST_N];

    for (int a = 0; a < ns; a++) {
        for (int b = 0; b < ne; b++) {
            int bucket = starts[a] * ST_LETTERS + ends[b];
            for (uint32_t bi = lex->bucketStart[bucket]; bi < lex->bucketStart[bucket + 1]; bi++) {
                int w = (int)lex->bucketWords[bi];
                int kl = lex->keyLen[w];
                const uint8_t *k = lex->keys + lex->keyOffset[w];
                int usable = 1;
                float tl = 0;
                for (int j = 0; j < kl; j++) {
                    if (!keys->present[k[j]]) {
                        usable = 0;
                        break;
                    }
                    tv[j] = centers[k[j]];
                    if (j > 0) {
                        tl += STDist(tv[j - 1], tv[j]);
                    }
                }
                if (!usable || tl > lenHi || tl < lenLo) {
                    continue;
                }
                STResample(tv, kl, tr, ST_N);
                float loc = 0;
                for (int i = 0; i < ST_N; i++) {
                    loc += STDist(tr[i], G[i]);
                }
                loc /= (float)ST_N;
                float geo = loc + ST_END_WEIGHT * (STDist(tr[0], G[0]) + STDist(tr[ST_N - 1], G[ST_N - 1]));
                float score = -(geo * geo) * inv2s2 + ST_LN10 * lex->zipf[w];

                if (found == maxOut && score <= out[found - 1].score) {
                    continue;
                }
                int pos = found < maxOut ? found++ : maxOut - 1;
                while (pos > 0 && out[pos - 1].score < score) {
                    out[pos] = out[pos - 1];
                    pos--;
                }
                out[pos].word = w;
                out[pos].score = score;
            }
        }
    }
    return found;
}
