// SwipeType — swipe-to-type on the stock iOS 6 keyboard (armv7).
//
// Loaded into every UIKit app, because the keyboard runs inside each app. A touch that starts
// on a letter key is tracked; once it travels far enough (Settings > SwipeType > Swipe
// Distance) it becomes a swipe: the stock keyboard is told the touch was cancelled (so no
// letter is typed and the key popup goes away), a trail is drawn, the path is decoded against
// the compiled-in word list, and on lift the best word is typed through UIKeyboardImpl's own
// addInputString: path, so autocorrect, shift and double-space behave as if it were tapped.
// Holding still at the end of a swipe opens a picker with alternatives; sliding sideways
// (toward the middle of the keyboard) selects. Delete right after a swipe removes the word.
// Swipe Ticks taps lightly as the picker opens and moves, at KeyTick's strength and length.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dlfcn.h>
#import <AudioToolbox/AudioToolbox.h>
#import "STShared.h"
#import "STDecoder.h"
#import "STLexiconData.h"
#import "STTrailView.h"
#import "STPreviewView.h"

@interface UIKBTree : NSObject
- (NSArray *)keys;
- (NSString *)representedString;
- (CGRect)frame;
@end

@interface UIKeyboardLayout : UIView
@end

@interface UIKeyboardLayoutStar : UIKeyboardLayout
- (UIKBTree *)keyplane;
- (BOOL)didLongPress;
- (NSString *)localizedInputMode;
- (UIKBTree *)keyHitTestWithoutCharging:(CGPoint)point;
@end

@interface UIKeyboardImpl : UIView
+ (id)activeInstance;
- (void)addInputString:(NSString *)string;
- (BOOL)isShifted;
- (BOOL)isShiftLocked;
- (void)setShiftOffIfNeeded;
- (void)clearLongPressTimer;
- (id)inputDelegate;
- (id)privateInputDelegate;
- (id)textInputTraits;
@end

@interface NSObject (SwipeTypeTextInputPrivate)
- (unsigned long)characterBeforeCaretSelection;
@end

#define ST_START_WINDOW   0.45   // s: a touch must start moving within this (else it's a hold)
#define ST_HOLD_DELAY     0.6    // s of stillness at the end of a swipe before the picker opens
#define ST_HOLD_SLOP      6.0f   // pt the finger may drift while holding still
#define ST_LIVE_INTERVAL  0.08   // s between live preview decodes
#define ST_CHOICES        4
#define ST_REJECT_WINDOW  20.0   // s a deleted swipe word is skipped if the next swipe picks it again
#define ST_LOG_SWIPES     5      // log details for the first few swipes per process
#define ST_LOG_MAX_BYTES  (512 * 1024)
#define ST_TICK_GAP       0.03   // s between picker ticks
#define ST_DEFAULT_TICK_INTENSITY  0.35f   // KeyTick's defaults, used when KeyTick isn't set up
#define ST_DEFAULT_TICK_MS         20.0f
#define ST_KEYTICK_PREFS_PATH  @"/var/mobile/Library/Preferences/com.mbucc9000.keytick.plist"
#define ST_KEYTICK_NOTIFY      "com.mbucc9000.keytick/prefs"

typedef enum {
    STIdle = 0,
    STPending,      // finger down on a letter, not yet far enough to be a swipe
    STSwiping,
    STChoosing,     // held still: picker open, sideways movement selects
} STState;

typedef struct {
    BOOL enabled;
    BOOL preview;
    BOOL keys;
    BOOL choose;
    BOOL space;
    BOOL ticks;     // tick when the picker opens and as its highlight moves
    int color;
    float width;
    float sensitivity;
} STPrefs;

// Everything below is main-thread only unless noted.
static STPrefs gPrefs;
static CFTimeInterval gLastPrefsStat;
static struct timespec gPrefsMTime;

static STState gState;
static UITouch *gTouch;
static __weak UIKeyboardLayoutStar *gLayout;
static STPoint *gPts;
static int gCount;
static int gCap;
static CGPoint gStart;
static CFTimeInterval gStartTime;
static BOOL gStartShifted;
static BOOL gStartLocked;
static NSUInteger gSwipeID;
static BOOL gForwardingCancel;

static STKeyMap gKeyMap;
static CGRect gKeyFrames[ST_LETTERS];
static int gKeyLetters;
static __weak id gKeyPlane;
static CGSize gKeySize;

static dispatch_queue_t gLexQueue;     // owns gLexicon creation
static STLexicon *gLexicon;            // written once on gLexQueue, immutable afterwards
static STLexicon *gLex;                // main-thread copy of the pointer once it exists
static dispatch_queue_t gDecodeQueue;
static BOOL gLiveBusy;
static BOOL gLiveScheduled;
static CFTimeInterval gLiveLast;

static SwipeTypeTrailView *gTrail;
static SwipeTypePreviewView *gPreview;

static NSUInteger gHoldGen;
static CGPoint gHoldAnchor;
static NSArray *gChoices;              // lexicon forms, best first
static NSInteger gChoiceIndex;
static BOOL gChoiceReversed;

static BOOL gInserting;
static BOOL gDeleting;
static NSString *gLastInserted;        // exactly what was typed for the last swipe (no space)
static NSString *gLastWord;            // its lexicon form
static NSString *gRejectedWord;
static CFTimeInterval gRejectedTime;

static int gSwipesLogged;
static int gTouchesLogged;
static int gKeymapsLogged;
static BOOL gDeleteHookLogged;

#pragma mark - Log

static void STLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

static void STLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ [%@ %d] %@\n", [NSDate date],
                      [[NSProcessInfo processInfo] processName], getpid(), msg];
    dispatch_async(gDecodeQueue, ^{
        // Sandboxed App Store apps can't write here; open() fails and the line is dropped.
        int fd = open(ST_LOG_PATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0) {
            return;
        }
        struct stat st;
        if (fstat(fd, &st) == 0 && st.st_size > ST_LOG_MAX_BYTES) {
            ftruncate(fd, 0);
        }
        const char *s = [line UTF8String];
        write(fd, s, strlen(s));
        close(fd);
    });
}

#pragma mark - Prefs

static void STLoadPrefs(const char *why) {
    STPrefs p = { YES, YES, YES, YES, YES, YES, ST_DEFAULT_COLOR, ST_DEFAULT_WIDTH, ST_DEFAULT_SENSITIVITY };
    struct stat st;
    if (stat([ST_PREFS_PATH fileSystemRepresentation], &st) == 0) {
        // Read by absolute path: a sandboxed app's CFPreferences points at its own container.
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:ST_PREFS_PATH];
        if (!d && why) {
            return;   // caught mid-write; keep the current values
        }
        gPrefsMTime = st.st_mtimespec;
        id v;
        if ((v = d[@"enabled"])) p.enabled = [v boolValue];
        if ((v = d[@"preview"])) p.preview = [v boolValue];
        if ((v = d[@"keys"])) p.keys = [v boolValue];
        if ((v = d[@"choose"])) p.choose = [v boolValue];
        if ((v = d[@"space"])) p.space = [v boolValue];
        if ((v = d[@"ticks"])) p.ticks = [v boolValue];
        if ((v = d[@"color"])) p.color = [v intValue];
        if ((v = d[@"width"])) p.width = [v floatValue];
        if ((v = d[@"sensitivity"])) p.sensitivity = [v floatValue];
    }
    if (p.width < 2 || p.width > 20) {
        p.width = ST_DEFAULT_WIDTH;
    }
    if (p.sensitivity < 0.3f || p.sensitivity > 2.0f) {
        p.sensitivity = ST_DEFAULT_SENSITIVITY;
    }
    gPrefs = p;
    if (why) {
        STLog(@"prefs (%s): enabled=%d preview=%d keys=%d choose=%d space=%d ticks=%d color=%d width=%.1f sensitivity=%.2f",
              why, p.enabled, p.preview, p.keys, p.choose, p.space, p.ticks, p.color, p.width, p.sensitivity);
    }
}

static void STMaybeReloadPrefs(void) {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - gLastPrefsStat < 1.0) {
        return;
    }
    gLastPrefsStat = now;
    struct stat st;
    if (stat([ST_PREFS_PATH fileSystemRepresentation], &st) == 0 &&
        (st.st_mtimespec.tv_sec != gPrefsMTime.tv_sec || st.st_mtimespec.tv_nsec != gPrefsMTime.tv_nsec)) {
        STLoadPrefs("file changed");
    }
}

static void STPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                           const void *object, CFDictionaryRef userInfo) {
    STLoadPrefs("notification");
}

#pragma mark - Swipe Ticks

// A light tap when the picker opens and each time its highlight moves. Same feel as KeyTick:
// its strength and length when KeyTick is set up, KeyTick's defaults otherwise.
static float gTickIntensity = ST_DEFAULT_TICK_INTENSITY;
static float gTickMs = ST_DEFAULT_TICK_MS;
static CFTimeInterval gLastTick;

static void STLoadTickStrength(void) {
    NSDictionary *kt = [NSDictionary dictionaryWithContentsOfFile:ST_KEYTICK_PREFS_PATH];
    id v;
    float intensity = (v = kt[@"intensity"]) ? [v floatValue] : ST_DEFAULT_TICK_INTENSITY;
    float ms = (v = kt[@"duration"]) ? [v floatValue] : ST_DEFAULT_TICK_MS;
    gTickIntensity = intensity < 0.01f ? 0.01f : (intensity > 1.0f ? 1.0f : intensity);
    gTickMs = ms < 1.0f ? 1.0f : (ms > 200.0f ? 200.0f : ms);
}

static void STKeyTickPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                  const void *object, CFDictionaryRef userInfo) {
    STLoadTickStrength();
}

typedef void (*STVibeFn)(SystemSoundID sound, id unknown, NSDictionary *pattern);

static void STTick(void) {
    static STVibeFn fn;
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (STVibeFn)dlsym(RTLD_DEFAULT, "AudioServicesPlaySystemSoundWithVibration");
        queue = dispatch_queue_create("com.mbucc9000.swipetype.tick", DISPATCH_QUEUE_SERIAL);
    });
    CFTimeInterval now = CACurrentMediaTime();
    if (!gPrefs.ticks || !fn || now - gLastTick < ST_TICK_GAP) {
        return;
    }
    gLastTick = now;
    NSDictionary *pattern = @{ @"VibePattern": @[ @YES, @((int)lroundf(gTickMs)) ], @"Intensity": @(gTickIntensity) };
    dispatch_async(queue, ^{
        fn(kSystemSoundID_Vibrate, nil, pattern);
    });
}

#pragma mark - Lexicon

static STLexicon *STLexiconOnQueue(void) {
    if (!gLexicon) {
        CFTimeInterval t0 = CACurrentMediaTime();
        gLexicon = STLexiconCreate(STLexiconDataWords, STLexiconDataScores, STLexiconDataCount);
        STLog(@"lexicon %@: %d words in %.0f ms", gLexicon ? @"ready" : @"FAILED",
              STLexiconCount(gLexicon), (CACurrentMediaTime() - t0) * 1000);
    }
    return gLexicon;
}

static void STPreloadLexicon(void) {
    if (!gLex) {
        dispatch_async(gLexQueue, ^{
            STLexiconOnQueue();
        });
    }
}

static STLexicon *STGetLexicon(void) {
    if (!gLex) {
        __block STLexicon *lex = NULL;
        dispatch_sync(gLexQueue, ^{
            lex = STLexiconOnQueue();
        });
        gLex = lex;
    }
    return gLex;
}

static NSString *STWordAt(STLexicon *lex, int index) {
    const char *w = STLexiconWord(lex, index);
    return w ? [NSString stringWithUTF8String:w] : nil;
}

#pragma mark - Keyboard geometry

static void STSortFloats(float *v, int n) {
    for (int i = 1; i < n; i++) {
        float x = v[i];
        int j = i - 1;
        while (j >= 0 && v[j] > x) {
            v[j + 1] = v[j];
            j--;
        }
        v[j + 1] = x;
    }
}

// Rebuilds the letter map when the keyplane or keyboard size changes. YES if it's a letters plane.
static BOOL STRefreshKeyMap(UIKeyboardLayoutStar *layout) {
    UIKBTree *plane = [layout respondsToSelector:@selector(keyplane)] ? [layout keyplane] : nil;
    CGSize size = layout.bounds.size;
    if (plane && plane == gKeyPlane && CGSizeEqualToSize(size, gKeySize)) {
        return gKeyLetters >= 20;
    }
    gKeyPlane = plane;
    gKeySize = size;
    memset(&gKeyMap, 0, sizeof(gKeyMap));
    memset(gKeyFrames, 0, sizeof(gKeyFrames));
    gKeyLetters = 0;
    if (!plane) {
        return NO;
    }

    float heights = 0;
    for (UIKBTree *key in [plane keys]) {
        if (![key respondsToSelector:@selector(representedString)] || ![key respondsToSelector:@selector(frame)]) {
            continue;
        }
        NSString *s = [key representedString];
        if (![s isKindOfClass:[NSString class]] || s.length != 1) {
            continue;
        }
        unichar c = [[s lowercaseString] characterAtIndex:0];
        if (c < 'a' || c > 'z' || gKeyMap.present[c - 'a']) {
            continue;
        }
        CGRect f = [key frame];
        if (CGRectIsEmpty(f)) {
            continue;
        }
        int i = c - 'a';
        gKeyMap.present[i] = 1;
        gKeyMap.center[i].x = (float)CGRectGetMidX(f);
        gKeyMap.center[i].y = (float)CGRectGetMidY(f);
        gKeyFrames[i] = f;
        heights += (float)f.size.height;
        gKeyLetters++;
    }
    if (gKeyLetters < 20) {
        return NO;
    }

    // Pitch: median gap to the next key on the right; median distance between row centres.
    float keyH = heights / gKeyLetters;
    float dxs[ST_LETTERS], ys[ST_LETTERS];
    int ndx = 0, ny = 0;
    for (int i = 0; i < ST_LETTERS; i++) {
        if (!gKeyMap.present[i]) {
            continue;
        }
        float best = 0;
        for (int j = 0; j < ST_LETTERS; j++) {
            if (j == i || !gKeyMap.present[j]) {
                continue;
            }
            float dy = fabsf(gKeyMap.center[j].y - gKeyMap.center[i].y);
            float dx = gKeyMap.center[j].x - gKeyMap.center[i].x;
            if (dy < keyH * 0.3f && dx > 1 && (best == 0 || dx < best)) {
                best = dx;
            }
        }
        if (best > 0) {
            dxs[ndx++] = best;
        }
        ys[ny++] = gKeyMap.center[i].y;
    }
    STSortFloats(dxs, ndx);
    STSortFloats(ys, ny);
    float rows[ST_LETTERS];
    int nrows = 0;
    for (int i = 0; i < ny; i++) {
        if (nrows == 0 || ys[i] - rows[nrows - 1] > keyH * 0.3f) {
            rows[nrows++] = ys[i];
        }
    }
    float diffs[ST_LETTERS];
    for (int i = 1; i < nrows; i++) {
        diffs[i - 1] = rows[i] - rows[i - 1];
    }
    STSortFloats(diffs, nrows - 1 > 0 ? nrows - 1 : 0);
    gKeyMap.pitchX = ndx ? dxs[ndx / 2] : (float)size.width / 10;
    gKeyMap.pitchY = nrows > 1 ? diffs[(nrows - 1) / 2] : keyH * 1.35f;

    STKeyMap *m = &gKeyMap;
    if (gKeymapsLogged++ >= 3) {
        return YES;
    }
    STLog(@"keymap: %d letters, %d rows, pitch %.1f x %.1f, layout %.0fx%.0f, q(%.0f,%.0f) p(%.0f,%.0f) a(%.0f,%.0f) m(%.0f,%.0f)",
          gKeyLetters, nrows, m->pitchX, m->pitchY, size.width, size.height,
          m->center['q' - 'a'].x, m->center['q' - 'a'].y, m->center['p' - 'a'].x, m->center['p' - 'a'].y,
          m->center['a' - 'a'].x, m->center['a' - 'a'].y, m->center['m' - 'a'].x, m->center['m' - 'a'].y);
    return YES;
}

#pragma mark - Text field helpers

static UIKeyboardImpl *STImpl(void) {
    return [%c(UIKeyboardImpl) activeInstance];
}

static BOOL STFieldAllowsSwipe(UIKeyboardLayoutStar *layout) {
    UIKeyboardImpl *impl = STImpl();
    if (!impl) {
        return NO;
    }
    id traits = [impl respondsToSelector:@selector(textInputTraits)] ? [impl textInputTraits] : nil;
    if ([traits respondsToSelector:@selector(isSecureTextEntry)] && [(id<UITextInputTraits>)traits isSecureTextEntry]) {
        return NO;   // passwords: never swipe, never draw a trail
    }
    if ([layout respondsToSelector:@selector(localizedInputMode)]) {
        NSString *mode = [layout localizedInputMode];
        if ([mode isKindOfClass:[NSString class]] && mode.length && ![mode hasPrefix:@"en"]) {
            return NO;   // the word list is English
        }
    }
    return YES;
}

// Up to `length` characters before the caret; @"" at the start of the text; nil if unknown.
static NSString *STTextBeforeCaret(UIKeyboardImpl *impl, NSUInteger length) {
    id d = [impl respondsToSelector:@selector(inputDelegate)] ? [impl inputDelegate] : nil;
    if ([d respondsToSelector:@selector(selectedTextRange)] && [d respondsToSelector:@selector(textInRange:)] &&
        [d respondsToSelector:@selector(positionFromPosition:offset:)]) {
        id<UITextInput> input = d;
        UITextRange *sel = [input selectedTextRange];
        if (!sel || ![sel isEmpty]) {
            return nil;
        }
        UITextPosition *end = sel.start;
        UITextPosition *start = [input positionFromPosition:end offset:-(NSInteger)length];
        if (!start) {
            start = [input beginningOfDocument];
        }
        UITextRange *range = start ? [input textRangeFromPosition:start toPosition:end] : nil;
        if (!range) {
            return nil;
        }
        NSString *text = [input textInRange:range];
        return text ?: @"";
    }
    if (length == 1) {
        id pd = [impl respondsToSelector:@selector(privateInputDelegate)] ? [impl privateInputDelegate] : nil;
        if ([pd respondsToSelector:@selector(characterBeforeCaretSelection)]) {
            unichar c = (unichar)[pd characterBeforeCaretSelection];
            return c ? [NSString stringWithCharacters:&c length:1] : @"";
        }
    }
    return nil;
}

static BOOL STNeedsSpaceAfter(NSString *before) {
    if (!before) {
        return gLastInserted != nil;   // unknown context: only right after our own word
    }
    if (!before.length) {
        return NO;
    }
    unichar c = [before characterAtIndex:before.length - 1];
    if ([[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:c]) {
        return NO;
    }
    switch (c) {
        case '(': case '[': case '{': case '"': case '\'': case '/': case '@': case '#':
        case '-': case '_': case 0x201C: case 0x2018:
            return NO;
        default:
            return YES;
    }
}

static BOOL STEndsSentence(NSString *before) {
    for (NSInteger i = (NSInteger)before.length - 1; i >= 0; i--) {
        unichar c = [before characterAtIndex:(NSUInteger)i];
        if (c == '.' || c == '!' || c == '?') {
            return YES;
        }
        if (c != '"' && c != '\'' && c != ')' && c != 0x201D && c != 0x2019) {
            return NO;
        }
    }
    return NO;
}

static NSString *STDisplayWord(NSString *word, BOOL shifted, BOOL locked) {
    if (!word.length) {
        return word;
    }
    NSString *w = word;
    if ([w isEqualToString:@"i"] || [w hasPrefix:@"i'"]) {
        w = [@"I" stringByAppendingString:[w substringFromIndex:1]];
    }
    if (locked) {
        return [w uppercaseString];
    }
    if (shifted) {
        return [[[w substringToIndex:1] uppercaseString] stringByAppendingString:[w substringFromIndex:1]];
    }
    return w;
}

static void STForgetInsert(void) {
    gLastInserted = nil;
    gLastWord = nil;
}

static void STInsertWord(NSString *word) {
    UIKeyboardImpl *impl = STImpl();
    if (!impl || !word.length) {
        return;
    }
    NSString *before = STTextBeforeCaret(impl, 2);
    id traits = [impl respondsToSelector:@selector(textInputTraits)] ? [impl textInputTraits] : nil;
    UIKeyboardType type = [traits respondsToSelector:@selector(keyboardType)]
        ? [(id<UITextInputTraits>)traits keyboardType] : UIKeyboardTypeDefault;
    BOOL spacedField = type != UIKeyboardTypeURL && type != UIKeyboardTypeEmailAddress;
    BOOL space = gPrefs.space && spacedField && STNeedsSpaceAfter(before);
    BOOL shifted = gStartShifted;
    if (space && STEndsSentence(before)) {
        // The space we add starts a new sentence; autocapitalize like the keyboard would.
        if (![traits respondsToSelector:@selector(autocapitalizationType)] ||
            [(id<UITextInputTraits>)traits autocapitalizationType] != UITextAutocapitalizationTypeNone) {
            shifted = YES;
        }
    }
    NSString *text = STDisplayWord(word, shifted, gStartLocked);

    gInserting = YES;
    if (space) {
        [impl addInputString:@" "];
    }
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *ch, NSRange range, NSRange enclosing, BOOL *stop) {
        [impl addInputString:ch];
    }];
    gInserting = NO;

    BOOL stillShifted = [impl respondsToSelector:@selector(isShifted)] && [impl isShifted];
    if (stillShifted && !gStartLocked && [impl respondsToSelector:@selector(setShiftOffIfNeeded)]) {
        [impl setShiftOffIfNeeded];
    }
    gLastInserted = text;
    gLastWord = word;
    gRejectedWord = nil;
    if (gSwipesLogged <= ST_LOG_SWIPES) {
        STLog(@"typed \"%@\" (space=%d, before=\"%@\", shift at start=%d locked=%d, shifted after=%d)",
              text, space, before ?: @"(unknown)", gStartShifted, gStartLocked, stillShifted);
    }
}

// Delete right after a swipe removes the whole word, if the text before the caret is still it.
static BOOL STShouldDeleteWholeWord(UIKeyboardImpl *impl) {
    if (!gLastInserted.length) {
        return NO;
    }
    NSString *before = STTextBeforeCaret(impl, gLastInserted.length);
    if ([before isEqualToString:gLastInserted]) {
        return YES;
    }
    STForgetInsert();
    return NO;
}

static void STRejectLastInsert(void) {
    gRejectedWord = gLastWord;
    gRejectedTime = CACurrentMediaTime();
    STForgetInsert();
}

#pragma mark - Gesture state

static void STAddPoint(CGPoint p) {
    if (gCount == gCap) {
        int cap = gCap ? gCap * 2 : 256;
        STPoint *grown = (STPoint *)realloc(gPts, sizeof(STPoint) * (size_t)cap);
        if (!grown) {
            return;
        }
        gPts = grown;
        gCap = cap;
    }
    gPts[gCount].x = (float)p.x;
    gPts[gCount].y = (float)p.y;
    gCount++;
}

static NSSet *STSetWithout(NSSet *touches, UITouch *touch) {
    NSMutableSet *rest = [touches mutableCopy];
    [rest removeObject:touch];
    return rest;
}

static void STReset(void) {
    gState = STIdle;
    gTouch = nil;
    gLayout = nil;
    gCount = 0;
    gChoices = nil;
    gChoiceIndex = 0;
    gHoldGen++;
}

// Ranked lexicon words for the gesture so far.
static NSArray *STDecodeNow(int maxOut, STCandidate *top) {
    if (!gLex || gCount < 2) {
        return @[];
    }
    STCandidate c[ST_MAX_CANDIDATES];
    int n = STDecode(gLex, &gKeyMap, gPts, gCount, c, maxOut);
    NSMutableArray *words = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
    for (int i = 0; i < n; i++) {
        NSString *w = STWordAt(gLex, c[i].word);
        if (w) {
            [words addObject:w];
        }
    }
    if (top && n > 0) {
        *top = c[0];
    }
    return words;
}

static void STShowPreviewWord(NSString *word) {
    UIKeyboardLayoutStar *layout = gLayout;
    if (gPrefs.preview && layout && gPreview) {
        [gPreview showWord:STDisplayWord(word, gStartShifted, gStartLocked) aboveView:layout];
    }
}

static void STRequestLiveDecode(void);

static void STRunLiveDecode(void) {
    gLiveBusy = YES;
    gLiveLast = CACurrentMediaTime();
    NSUInteger swipe = gSwipeID;
    int n = gCount;
    STPoint *copy = (STPoint *)malloc(sizeof(STPoint) * (size_t)n);
    if (!copy) {
        gLiveBusy = NO;
        return;
    }
    memcpy(copy, gPts, sizeof(STPoint) * (size_t)n);
    STKeyMap keys = gKeyMap;
    STLexicon *lex = gLex;
    dispatch_async(gDecodeQueue, ^{
        STCandidate c[1];
        int found = STDecode(lex, &keys, copy, n, c, 1);
        free(copy);
        NSString *best = found ? STWordAt(lex, c[0].word) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            gLiveBusy = NO;
            if (swipe == gSwipeID && gState == STSwiping) {
                if (best) {
                    STShowPreviewWord(best);
                }
                if (gCount != n) {
                    STRequestLiveDecode();   // the finger moved on while we were decoding
                }
            }
        });
    });
}

static void STRequestLiveDecode(void) {
    if (!gPrefs.preview || !gLex || gState != STSwiping || gLiveBusy || gLiveScheduled) {
        return;
    }
    CFTimeInterval wait = ST_LIVE_INTERVAL - (CACurrentMediaTime() - gLiveLast);
    if (wait <= 0) {
        STRunLiveDecode();
        return;
    }
    gLiveScheduled = YES;
    NSUInteger swipe = gSwipeID;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gLiveScheduled = NO;
        if (swipe == gSwipeID && gState == STSwiping && !gLiveBusy) {
            STRunLiveDecode();
        }
    });
}

#pragma mark - Picker

static void STShowChoices(void) {
    UIKeyboardLayoutStar *layout = gLayout;
    if (!layout || !gPreview) {
        return;
    }
    NSMutableArray *shown = [NSMutableArray array];
    for (NSString *w in gChoices) {
        [shown addObject:STDisplayWord(w, gStartShifted, gStartLocked)];
    }
    NSInteger selected = gChoiceIndex;
    if (gChoiceReversed) {
        shown = [[[shown reverseObjectEnumerator] allObjects] mutableCopy];
        selected = (NSInteger)gChoices.count - 1 - gChoiceIndex;
    }
    [gPreview showChoices:shown selected:selected aboveView:layout];
}

static void STEnterChooser(void) {
    NSArray *words = STDecodeNow(ST_CHOICES, NULL);
    if (words.count < 2) {
        return;
    }
    UIKeyboardLayoutStar *layout = gLayout;
    gState = STChoosing;
    gChoices = words;
    gChoiceIndex = 0;
    // Best word sits on the finger's side; alternatives run toward the middle of the keyboard.
    gChoiceReversed = layout && gHoldAnchor.x > CGRectGetMidX(layout.bounds);
    STShowChoices();
    STTick();
    if (gSwipesLogged <= ST_LOG_SWIPES) {
        STLog(@"picker opened: %@", [words componentsJoinedByString:@", "]);
    }
}

static void STUpdateChoice(CGPoint p) {
    float toward = (float)(gChoiceReversed ? gHoldAnchor.x - p.x : p.x - gHoldAnchor.x);
    float step = gKeyMap.pitchX * 0.9f;
    int index = (int)floorf(toward / step + 0.5f);
    int last = (int)gChoices.count - 1;
    index = index < 0 ? 0 : (index > last ? last : index);
    if (index != gChoiceIndex) {
        gChoiceIndex = index;
        STShowChoices();
        STTick();
    }
}

static void STArmHold(CGPoint p) {
    gHoldAnchor = p;
    NSUInteger gen = ++gHoldGen;
    if (!gPrefs.choose) {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ST_HOLD_DELAY * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen == gHoldGen && gState == STSwiping) {
            STEnterChooser();
        }
    });
}

#pragma mark - Touch handling

static void STCancelStockTouch(UIKeyboardLayout *layout, UITouch *touch, UIEvent *event) {
    gForwardingCancel = YES;
    [layout touchesCancelled:[NSSet setWithObject:touch] withEvent:event];
    gForwardingCancel = NO;
    UIKeyboardImpl *impl = STImpl();
    if ([impl respondsToSelector:@selector(clearLongPressTimer)]) {
        [impl clearLongPressTimer];
    }
}

static void STBeginSwipe(UIKeyboardLayoutStar *layout, CGPoint p, UIEvent *event) {
    gState = STSwiping;
    gSwipeID++;
    STCancelStockTouch(layout, gTouch, event);

    if (!gTrail) {
        gTrail = [[SwipeTypeTrailView alloc] initWithFrame:layout.bounds];
    }
    if (gTrail.superview != layout) {
        [gTrail removeFromSuperview];
        [layout addSubview:gTrail];
    }
    gTrail.frame = layout.bounds;
    [layout bringSubviewToFront:gTrail];
    gTrail.trailColor = STTrailColor(gPrefs.color);
    gTrail.trailWidth = gPrefs.width;
    gTrail.showKeys = gPrefs.keys;
    [gTrail setKeyMap:&gKeyMap frames:gKeyFrames];
    [gTrail beginAtPoint:CGPointMake(gPts[0].x, gPts[0].y)];
    for (int i = 1; i < gCount; i++) {
        [gTrail addPoint:CGPointMake(gPts[i].x, gPts[i].y)];
    }

    if (!gPreview) {
        gPreview = [[SwipeTypePreviewView alloc] initWithFrame:CGRectZero];
    }
    gPreview.accentColor = STTrailColor(gPrefs.color);
    STArmHold(p);
    STRequestLiveDecode();
}

static void STFinish(void) {
    NSString *word = nil;
    NSArray *choices = nil;
    STCandidate top = { -1, 0 };
    CFTimeInterval t0 = CACurrentMediaTime();
    if (gState == STChoosing) {
        choices = gChoices;
        word = gChoices[(NSUInteger)gChoiceIndex];
    } else {
        choices = STDecodeNow(3, &top);
        word = choices.count ? choices[0] : nil;
        // Deleted this word right after swiping it? The same swipe again means the next one.
        if (word && choices.count > 1 && [word isEqualToString:gRejectedWord] &&
            CACurrentMediaTime() - gRejectedTime < ST_REJECT_WINDOW) {
            word = choices[1];
        }
    }
    double ms = (CACurrentMediaTime() - t0) * 1000;
    [gTrail finish];
    [gPreview hide];

    if (gSwipesLogged < ST_LOG_SWIPES) {
        gSwipesLogged++;
        float len = 0;
        for (int i = 1; i < gCount; i++) {
            float dx = gPts[i].x - gPts[i - 1].x, dy = gPts[i].y - gPts[i - 1].y;
            len += sqrtf(dx * dx + dy * dy);
        }
        STLog(@"swipe %d: %d points, %.0f pt long, decode %.1f ms, best score %.1f, candidates [%@], chose \"%@\"%@",
              gSwipesLogged, gCount, len, ms, top.score, [choices componentsJoinedByString:@", "],
              word ?: @"(none)", gState == STChoosing ? @" from picker" : @"");
    }
    STReset();
    if (word) {
        STInsertWord(word);
    }
}

static void STTouchesBegan(UIKeyboardLayout *layout, NSSet *touches) {
    if (gState == STPending) {
        STReset();   // another finger came down: this is fast typing, not a swipe
        return;
    }
    if (gState != STIdle || touches.count != 1 || ![layout isKindOfClass:%c(UIKeyboardLayoutStar)]) {
        return;
    }
    STMaybeReloadPrefs();
    if (!gPrefs.enabled) {
        return;
    }
    UIKeyboardLayoutStar *star = (UIKeyboardLayoutStar *)layout;
    UITouch *touch = [touches anyObject];
    STPreloadLexicon();
    if (!STRefreshKeyMap(star) || !STFieldAllowsSwipe(star)) {
        return;
    }
    CGPoint p = [touch locationInView:layout];
    int letter = STLetterAtPoint(&gKeyMap, p);
    if (gTouchesLogged < 3) {
        gTouchesLogged++;
        NSString *stock = nil;
        if ([star respondsToSelector:@selector(keyHitTestWithoutCharging:)]) {
            UIKBTree *key = [star keyHitTestWithoutCharging:p];
            stock = [key respondsToSelector:@selector(representedString)] ? [key representedString] : nil;
        }
        NSString *ours = letter >= 0 ? [@"abcdefghijklmnopqrstuvwxyz" substringWithRange:NSMakeRange((NSUInteger)letter, 1)] : @"-";
        STLog(@"touch at (%.0f,%.0f): our letter %@, stock key \"%@\"", p.x, p.y, ours, stock ?: @"?");
    }
    if (letter < 0) {
        return;
    }
    UIKeyboardImpl *impl = STImpl();
    gState = STPending;
    gTouch = touch;
    gLayout = star;
    gCount = 0;
    STAddPoint(p);
    gStart = p;
    gStartTime = CACurrentMediaTime();
    gStartShifted = [impl respondsToSelector:@selector(isShifted)] && [impl isShifted];
    gStartLocked = [impl respondsToSelector:@selector(isShiftLocked)] && [impl isShiftLocked];
}

static NSSet *STTouchesMoved(UIKeyboardLayout *layout, NSSet *touches, UIEvent *event) {
    if (gState == STIdle || !gTouch || ![touches containsObject:gTouch] || layout != gLayout) {
        return touches;
    }
    UIKeyboardLayoutStar *star = (UIKeyboardLayoutStar *)layout;
    CGPoint p = [gTouch locationInView:layout];

    if (gState == STPending) {
        STAddPoint(p);
        float dx = (float)(p.x - gStart.x), dy = (float)(p.y - gStart.y);
        float threshold = gPrefs.sensitivity * gKeyMap.pitchX;
        if (dx * dx + dy * dy < threshold * threshold) {
            return touches;
        }
        BOOL longPress = [star respondsToSelector:@selector(didLongPress)] && [star didLongPress];
        if (longPress || CACurrentMediaTime() - gStartTime > ST_START_WINDOW || !STGetLexicon()) {
            STReset();   // a held key (accent popup) or no word list: leave it to the keyboard
            return touches;
        }
        STBeginSwipe(star, p, event);
        return STSetWithout(touches, gTouch);
    }

    if (gState == STChoosing) {
        STUpdateChoice(p);
        return STSetWithout(touches, gTouch);
    }

    STAddPoint(p);
    [gTrail addPoint:p];
    float hx = (float)(p.x - gHoldAnchor.x), hy = (float)(p.y - gHoldAnchor.y);
    if (hx * hx + hy * hy > ST_HOLD_SLOP * ST_HOLD_SLOP) {
        STArmHold(p);
    }
    STRequestLiveDecode();
    return STSetWithout(touches, gTouch);
}

static NSSet *STTouchesEnded(UIKeyboardLayout *layout, NSSet *touches) {
    if (gState == STIdle || !gTouch || ![touches containsObject:gTouch]) {
        return touches;
    }
    if (gState == STPending) {
        STReset();   // just a tap; the keyboard types it
        return touches;
    }
    UITouch *touch = gTouch;
    if (gState == STSwiping && layout == gLayout) {
        STAddPoint([touch locationInView:layout]);
    }
    STFinish();
    return STSetWithout(touches, touch);
}

static NSSet *STTouchesCancelled(NSSet *touches) {
    if (gState == STIdle || !gTouch || ![touches containsObject:gTouch]) {
        return touches;
    }
    if (gState == STPending) {
        STReset();
        return touches;
    }
    UITouch *touch = gTouch;
    [gTrail cancel];
    [gPreview hide];
    STReset();
    return STSetWithout(touches, touch);
}

#pragma mark - Hooks

%hook UIKeyboardLayout

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
    %orig;
    STTouchesBegan(self, touches);
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
    NSSet *rest = STTouchesMoved(self, touches, event);
    if (rest.count) {
        %orig(rest, event);
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
    NSSet *rest = STTouchesEnded(self, touches);
    if (rest.count) {
        %orig(rest, event);
    }
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
    if (gForwardingCancel) {
        %orig;
        return;
    }
    NSSet *rest = STTouchesCancelled(touches);
    if (rest.count) {
        %orig(rest, event);
    }
}

%end

// The swipe's touch was cancelled for the keyboard when it became a swipe. If the keyboard
// still hands it to its per-touch handlers (e.g. by reading the event), ignore it there.
static BOOL STIsSwipeTouch(id touch) {
    return touch && touch == gTouch && (gState == STSwiping || gState == STChoosing);
}

%hook UIKeyboardLayoutStar

- (void)touchDragged:(id)touch
{
    if (STIsSwipeTouch(touch)) {
        return;
    }
    %orig;
}

- (void)touchUp:(id)touch
{
    if (STIsSwipeTouch(touch)) {
        return;
    }
    %orig;
}

// Keep the keyboard's own swipe recognizers out of the way while a word is being swiped.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer
{
    if (gState == STSwiping || gState == STChoosing) {
        return NO;
    }
    return %orig;
}

%end

%hook UIKeyboardImpl

- (void)addInputString:(NSString *)string
{
    if (!gInserting) {
        STForgetInsert();
        gRejectedWord = nil;
    }
    %orig;
}

- (void)addInputString:(NSString *)string fromVariantKey:(BOOL)variant
{
    if (!gInserting) {
        STForgetInsert();
        gRejectedWord = nil;
    }
    %orig;
}

- (void)handleDelete
{
    if (!gDeleteHookLogged) {
        gDeleteHookLogged = YES;
        STLog(@"delete key reached handleDelete");
    }
    if (gDeleting || !STShouldDeleteWholeWord(self)) {
        %orig;
        return;
    }
    NSUInteger n = gLastInserted.length;
    STRejectLastInsert();
    gDeleting = YES;
    for (NSUInteger i = 0; i < n; i++) {
        %orig;
    }
    gDeleting = NO;
}

- (void)handleDeleteAsRepeat:(BOOL)repeat
{
    if (!gDeleteHookLogged) {
        gDeleteHookLogged = YES;
        STLog(@"delete key reached handleDeleteAsRepeat:%d", repeat);
    }
    if (gDeleting || repeat || !STShouldDeleteWholeWord(self)) {
        %orig;
        return;
    }
    NSUInteger n = gLastInserted.length;
    STRejectLastInsert();
    gDeleting = YES;
    for (NSUInteger i = 0; i < n; i++) {
        %orig;
    }
    gDeleting = NO;
}

%end

#pragma mark - Self-test (Settings > SwipeType > Run Self-Test)

// Decodes clean synthetic swipes on a standard iPhone portrait QWERTY layout and reports how
// many come back right. Runs inside Settings, where the pane calls it by class name.
@interface SwipeTypeSelfTest : NSObject
+ (NSString *)run;
@end

@implementation SwipeTypeSelfTest

+ (NSString *)run {
    CFTimeInterval t0 = CACurrentMediaTime();
    STLexicon *lex = STGetLexicon();
    double buildMs = (CACurrentMediaTime() - t0) * 1000;
    if (!lex) {
        return @"Word list failed to load.";
    }
    STKeyMap km;
    memset(&km, 0, sizeof(km));
    const char *rows[3] = { "qwertyuiop", "asdfghjkl", "zxcvbnm" };
    const float rowY[3] = { 27, 81, 135 }, rowX0[3] = { 16, 32, 64 };
    for (int r = 0; r < 3; r++) {
        for (int i = 0; rows[r][i]; i++) {
            int c = rows[r][i] - 'a';
            km.center[c].x = rowX0[r] + 32.0f * i;
            km.center[c].y = rowY[r];
            km.present[c] = 1;
        }
    }
    km.pitchX = 32;
    km.pitchY = 54;

    NSArray *words = @[ @"hello", @"the", @"keyboard", @"swipe", @"typing", @"thanks", @"tomorrow",
                        @"what", @"you", @"going", @"people", @"because", @"really", @"don't",
                        @"iphone", @"message", @"later", @"where", @"good", @"night" ];
    int right = 0;
    double decodeMs = 0;
    NSMutableArray *misses = [NSMutableArray array];
    for (NSString *word in words) {
        // Path through the key centres with a little sideways wobble, sampled every 6 pt.
        STPoint pts[512];
        int n = 0;
        STPoint prev = { -1, -1 };
        for (NSUInteger i = 0; i < word.length; i++) {
            unichar ch = [word characterAtIndex:i];
            if (ch < 'a' || ch > 'z') {
                continue;
            }
            STPoint k = km.center[ch - 'a'];
            k.x += (i % 2 ? 4 : -4);
            if (prev.x >= 0) {
                float dx = k.x - prev.x, dy = k.y - prev.y;
                int steps = (int)(sqrtf(dx * dx + dy * dy) / 6) + 1;
                for (int s = 1; s <= steps && n < 512; s++) {
                    pts[n].x = prev.x + dx * s / steps;
                    pts[n].y = prev.y + dy * s / steps;
                    n++;
                }
            } else if (n < 512) {
                pts[n++] = k;
            }
            prev = k;
        }
        STCandidate c[3];
        CFTimeInterval d0 = CACurrentMediaTime();
        int found = STDecode(lex, &km, pts, n, c, 3);
        decodeMs += (CACurrentMediaTime() - d0) * 1000;
        NSString *got = found ? STWordAt(lex, c[0].word) : @"(none)";
        if ([got isEqualToString:word]) {
            right++;
        } else {
            [misses addObject:[NSString stringWithFormat:@"%@ -> %@", word, got]];
        }
    }
    NSString *live = gKeyLetters >= 20
        ? [NSString stringWithFormat:@"Last keyboard: %d letters, key pitch %.1f x %.1f pt.", gKeyLetters,
           gKeyMap.pitchX, gKeyMap.pitchY]
        : @"No keyboard used in Settings yet.";
    NSString *summary = [NSString stringWithFormat:@"%d/%lu swipes decoded right.\n%d words, ready in %.0f ms.\nAverage decode %.1f ms.\n%@%@%@",
                         right, (unsigned long)words.count, STLexiconCount(lex), buildMs,
                         decodeMs / words.count, live, misses.count ? @"\nMissed: " : @"",
                         [misses componentsJoinedByString:@", "]];
    STLog(@"self-test: %@", [summary stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]);
    return summary;
}

@end

%ctor {
    @autoreleasepool {
        gLexQueue = dispatch_queue_create("com.mbucc9000.swipetype.lexicon", DISPATCH_QUEUE_SERIAL);
        gDecodeQueue = dispatch_queue_create("com.mbucc9000.swipetype.decode", DISPATCH_QUEUE_SERIAL);
        STLoadPrefs(NULL);
        STLoadTickStrength();
        %init;
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, STKeyTickPrefsChanged,
                                        CFSTR(ST_KEYTICK_NOTIFY), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, STPrefsChanged,
                                        CFSTR(ST_NOTIFY_PREFS), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
