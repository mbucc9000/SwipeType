// SwipeType — the swipe trail drawn over the keyboard.

#import "STTrailView.h"
#import <QuartzCore/QuartzCore.h>
#import "STShared.h"

#define ST_TRAIL_MAX    256     // points kept (older ones have faded anyway)
#define ST_TRAIL_LIFE   0.45    // s a point stays visible while swiping
#define ST_TRAIL_FADE   0.25    // s for everything to fade after the finger lifts
#define ST_GLOW_LIFE    0.35    // s a passed key keeps glowing
#define ST_BANDS        6       // age bands the trail is drawn in (width/alpha step per band)
#define ST_LOOKAHEAD    0.12    // s of travel used to guess the key being headed for
#define ST_MIN_SPEED    120.0f  // pt/s below which no heading is shown

typedef struct {
    CGPoint p;
    CFTimeInterval t;
} STTrailPoint;

@implementation SwipeTypeTrailView {
    STTrailPoint _pts[ST_TRAIL_MAX];
    int _head;                      // ring index of the oldest point
    int _count;
    STKeyMap _keys;
    CGRect _frames[ST_LETTERS];
    BOOL _hasKeys;
    CFTimeInterval _glow[ST_LETTERS];
    int _currentKey;
    int _headingKey;
    BOOL _active;
    CFTimeInterval _endTime;
    CADisplayLink *_link;
}

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        self.contentMode = UIViewContentModeRedraw;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.hidden = YES;
        _trailColor = STTrailColor(ST_DEFAULT_COLOR);
        _trailWidth = ST_DEFAULT_WIDTH;
        _showKeys = YES;
        _currentKey = -1;
        _headingKey = -1;
    }
    return self;
}

- (void)dealloc {
    [_link invalidate];
}

- (void)setKeyMap:(const STKeyMap *)keyMap frames:(const CGRect *)frames {
    _keys = *keyMap;
    memcpy(_frames, frames, sizeof(_frames));
    _hasKeys = YES;
}

#pragma mark - Points

- (STTrailPoint *)pointAt:(int)i {
    return &_pts[(_head + i) % ST_TRAIL_MAX];
}

- (void)pushPoint:(CGPoint)p time:(CFTimeInterval)t {
    if (_count == ST_TRAIL_MAX) {
        _head = (_head + 1) % ST_TRAIL_MAX;
        _count--;
    }
    STTrailPoint *slot = &_pts[(_head + _count) % ST_TRAIL_MAX];
    slot->p = p;
    slot->t = t;
    _count++;
    // Drop points that have fully faded, keeping one so the next segment has a start.
    while (_count > 2 && t - [self pointAt:1]->t > ST_TRAIL_LIFE) {
        _head = (_head + 1) % ST_TRAIL_MAX;
        _count--;
    }
}

- (int)headingKey {
    if (_count < 2) {
        return -1;
    }
    STTrailPoint *last = [self pointAt:_count - 1];
    STTrailPoint *ref = NULL;
    for (int i = _count - 2; i >= 0; i--) {
        ref = [self pointAt:i];
        if (last->t - ref->t >= 0.06) {
            break;
        }
    }
    CFTimeInterval dt = ref ? last->t - ref->t : 0;
    if (dt < 0.015) {
        return -1;
    }
    float vx = (float)((last->p.x - ref->p.x) / dt);
    float vy = (float)((last->p.y - ref->p.y) / dt);
    float speed = sqrtf(vx * vx + vy * vy);
    if (speed < ST_MIN_SPEED) {
        return -1;
    }
    float ahead = speed * (float)ST_LOOKAHEAD;
    float lo = _keys.pitchX * 0.6f, hi = _keys.pitchX * 1.8f;
    ahead = ahead < lo ? lo : (ahead > hi ? hi : ahead);
    CGPoint target = CGPointMake(last->p.x + vx / speed * ahead, last->p.y + vy / speed * ahead);
    return STLetterAtPoint(&_keys, target);
}

- (void)beginAtPoint:(CGPoint)point {
    _head = 0;
    _count = 0;
    memset(_glow, 0, sizeof(_glow));
    _currentKey = -1;
    _headingKey = -1;
    _active = YES;
    self.hidden = NO;
    [self addPoint:point];
}

- (void)addPoint:(CGPoint)point {
    CFTimeInterval now = CACurrentMediaTime();
    [self pushPoint:point time:now];
    if (_hasKeys) {
        _currentKey = STLetterAtPoint(&_keys, point);
        if (_currentKey >= 0) {
            _glow[_currentKey] = now;
        }
        _headingKey = [self headingKey];
    }
    [self startLink];
}

- (void)finish {
    if (!_active) {
        return;
    }
    _active = NO;
    _endTime = CACurrentMediaTime();
    [self startLink];
}

- (void)cancel {
    _active = NO;
    _count = 0;
    [self stopLink];
    self.hidden = YES;
    [self setNeedsDisplay];
}

#pragma mark - Animation

- (void)startLink {
    if (_link) {
        return;
    }
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopLink {
    [_link invalidate];
    _link = nil;
}

- (void)tick:(CADisplayLink *)link {
    if (!_active && CACurrentMediaTime() - _endTime > ST_TRAIL_FADE) {
        [self cancel];
        return;
    }
    [self setNeedsDisplay];
}

#pragma mark - Drawing

- (void)drawRect:(CGRect)rect {
    CFTimeInterval now = CACurrentMediaTime();
    CGFloat fade = 1;
    if (!_active) {
        fade = 1 - (now - _endTime) / ST_TRAIL_FADE;
        if (fade <= 0) {
            return;
        }
    }
    CGFloat r = 0.16f, g = 0.52f, b = 1, a = 1;
    [_trailColor getRed:&r green:&g blue:&b alpha:&a];
    CGContextRef ctx = UIGraphicsGetCurrentContext();

    if (_showKeys && _hasKeys) {
        for (int c = 0; c < ST_LETTERS; c++) {
            if (!_keys.present[c] || _glow[c] <= 0) {
                continue;
            }
            CGFloat level = (_active && c == _currentKey) ? 1 : 1 - (now - _glow[c]) / ST_GLOW_LIFE;
            level *= fade;
            if (level <= 0) {
                continue;
            }
            UIBezierPath *cap = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(_frames[c], 1, 1) cornerRadius:5];
            CGContextSetRGBFillColor(ctx, r, g, b, 0.32f * level);
            CGContextAddPath(ctx, cap.CGPath);
            CGContextFillPath(ctx);
        }
        if (_active && _headingKey >= 0 && _headingKey != _currentKey) {
            UIBezierPath *cap = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(_frames[_headingKey], 1.5f, 1.5f) cornerRadius:5];
            CGContextSetRGBFillColor(ctx, r, g, b, 0.12f);
            CGContextAddPath(ctx, cap.CGPath);
            CGContextFillPath(ctx);
            CGContextSetRGBStrokeColor(ctx, r, g, b, 0.7f);
            CGContextSetLineWidth(ctx, 1.5f);
            CGContextAddPath(ctx, cap.CGPath);
            CGContextStrokePath(ctx);
        }
    }

    if (_count >= 2) {
        // Glow pass under the core pass, each split into age bands so the comet tapers.
        for (int pass = 0; pass < 2; pass++) {
            [self strokeBandsInContext:ctx now:now fade:fade pass:pass red:r green:g blue:b];
        }
    }
    if (_active && _count > 0) {
        CGPoint tip = [self pointAt:_count - 1]->p;
        CGFloat rad = _trailWidth * 0.75f;
        CGContextSetRGBFillColor(ctx, r, g, b, 0.25f);
        CGContextFillEllipseInRect(ctx, CGRectMake(tip.x - rad * 2, tip.y - rad * 2, rad * 4, rad * 4));
        CGContextSetRGBFillColor(ctx, r, g, b, 1);
        CGContextFillEllipseInRect(ctx, CGRectMake(tip.x - rad, tip.y - rad, rad * 2, rad * 2));
    }
}

// Strokes consecutive segments that share an age band as one smoothed path.
- (void)strokeBandsInContext:(CGContextRef)ctx now:(CFTimeInterval)now fade:(CGFloat)fade pass:(int)pass
                         red:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b {
    CFTimeInterval ref = _active ? now : _endTime;
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);

    int i = 1;
    while (i < _count) {
        int band = (int)((ref - [self pointAt:i]->t) / ST_TRAIL_LIFE * ST_BANDS);
        int j = i;
        while (j + 1 < _count && (int)((ref - [self pointAt:j + 1]->t) / ST_TRAIL_LIFE * ST_BANDS) == band) {
            j++;
        }
        if (band < ST_BANDS) {
            CGFloat life = 1 - (band + 0.5f) / ST_BANDS;
            CGFloat width = _trailWidth * (0.3f + 0.7f * life);
            CGFloat alpha = (pass == 0 ? 0.22f : 0.95f) * (0.35f + 0.65f * life) * fade;
            if (pass == 0) {
                width *= 2.4f;
            }
            CGMutablePathRef path = CGPathCreateMutable();
            CGPoint start = [self pointAt:i - 1]->p;
            CGPathMoveToPoint(path, NULL, start.x, start.y);
            for (int k = i; k < j; k++) {
                CGPoint c = [self pointAt:k]->p;
                CGPoint n = [self pointAt:k + 1]->p;
                CGPathAddQuadCurveToPoint(path, NULL, c.x, c.y, (c.x + n.x) / 2, (c.y + n.y) / 2);
            }
            CGPoint end = [self pointAt:j]->p;
            CGPathAddLineToPoint(path, NULL, end.x, end.y);
            CGContextSetRGBStrokeColor(ctx, r, g, b, alpha);
            CGContextSetLineWidth(ctx, width);
            CGContextAddPath(ctx, path);
            CGContextStrokePath(ctx);
            CGPathRelease(path);
        }
        i = j + 1;
    }
}

@end
