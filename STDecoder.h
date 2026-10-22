// SwipeType — gesture decoder (plain C, no UIKit, so it can be tested off-device).
// Turns a swipe path over the keyboard into ranked dictionary words.

#ifndef ST_DECODER_H
#define ST_DECODER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ST_LETTERS        26
#define ST_MAX_CANDIDATES 8

typedef struct {
    float x, y;
} STPoint;

// Letter key geometry in the same coordinate space as the gesture points (points).
typedef struct {
    STPoint center[ST_LETTERS];   // a..z
    uint8_t present[ST_LETTERS];
    float pitchX;                 // distance between neighbouring keys in a row
    float pitchY;                 // distance between rows
} STKeyMap;

typedef struct {
    int word;      // lexicon index
    float score;   // log-probability in nats; higher is better
} STCandidate;

typedef struct STLexicon STLexicon;

// Builds the search index over `count` NUL-separated words (most frequent first) with their
// zipf*100 scores. The word bytes are referenced, not copied, so they must outlive the lexicon
// (the compiled-in STLexiconData arrays do). Returns NULL on failure.
STLexicon *STLexiconCreate(const char *words, const uint16_t *scores, int count);
void STLexiconFree(STLexicon *lex);
int STLexiconCount(const STLexicon *lex);
const char *STLexiconWord(const STLexicon *lex, int index);

// Decodes a gesture. Returns the number of candidates written to `out` (best first).
// Thread-safe: the lexicon is read-only after loading.
int STDecode(const STLexicon *lex, const STKeyMap *keys, const STPoint *points, int count,
             STCandidate *out, int maxOut);

#ifdef __cplusplus
}
#endif

#endif
