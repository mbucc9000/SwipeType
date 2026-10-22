// SwipeType — shared between the keyboard hooks, the trail/preview views and the Settings pane.

#import <UIKit/UIKit.h>
#import "STDecoder.h"

#define ST_PREFS_PATH    @"/var/mobile/Library/Preferences/com.mbucc9000.swipetype.plist"
#define ST_LOG_PATH      "/var/mobile/SwipeType.log"
#define ST_NOTIFY_PREFS  "com.mbucc9000.swipetype/prefs"

// Defaults; keep in sync with swipetypeprefs/Resources/Root.plist.
#define ST_DEFAULT_COLOR        0       // index into STTrailColor
#define ST_DEFAULT_WIDTH        8.0f    // trail thickness, points
#define ST_DEFAULT_SENSITIVITY  0.8f    // key widths the finger must travel before a swipe starts

// Trail colors offered in Settings (same order as the pane's list).
static inline UIColor *STTrailColor(int index) {
    switch (index) {
        case 1:  return [UIColor colorWithRed:1.00f green:1.00f blue:1.00f alpha:1];   // White
        case 2:  return [UIColor colorWithRed:0.20f green:0.80f blue:0.35f alpha:1];   // Green
        case 3:  return [UIColor colorWithRed:1.00f green:0.55f blue:0.10f alpha:1];   // Orange
        case 4:  return [UIColor colorWithRed:1.00f green:0.30f blue:0.60f alpha:1];   // Pink
        case 5:  return [UIColor colorWithRed:0.58f green:0.36f blue:1.00f alpha:1];   // Purple
        default: return [UIColor colorWithRed:0.16f green:0.52f blue:1.00f alpha:1];   // Blue
    }
}

// The letter whose key cell (one pitch wide, one row tall) contains the point, or -1.
static inline int STLetterAtPoint(const STKeyMap *keys, CGPoint p) {
    int best = -1;
    float bestDist = 0;
    for (int c = 0; c < ST_LETTERS; c++) {
        if (!keys->present[c]) {
            continue;
        }
        float dx = (float)p.x - keys->center[c].x;
        float dy = (float)p.y - keys->center[c].y;
        if (fabsf(dx) > keys->pitchX * 0.5f || fabsf(dy) > keys->pitchY * 0.5f) {
            continue;
        }
        float d = dx * dx + dy * dy;
        if (best < 0 || d < bestDist) {
            best = c;
            bestDist = d;
        }
    }
    return best;
}
