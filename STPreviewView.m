// SwipeType — the word bubble shown just above the keyboard while swiping.

#import "STPreviewView.h"
#import "STShared.h"

#define ST_BUBBLE_HEIGHT  36.0f
#define ST_BUBBLE_INSET   4.0f     // between the bubble edge and the word cells
#define ST_CELL_PAD       10.0f    // around each word
#define ST_CELL_GAP       4.0f
#define ST_FONT_SIZE      18.0f
#define ST_ABOVE_GAP      6.0f     // between the keyboard's top edge and the bubble

@implementation SwipeTypePreviewView {
    NSArray *_items;
    NSInteger _selected;
    UIFont *_font;
}

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        self.contentMode = UIViewContentModeRedraw;
        self.alpha = 0;
        self.hidden = YES;
        _font = [UIFont boldSystemFontOfSize:ST_FONT_SIZE];
        _accentColor = STTrailColor(ST_DEFAULT_COLOR);
        _selected = -1;
    }
    return self;
}

- (CGFloat)cellWidth:(NSString *)word {
    return ceilf([word sizeWithFont:_font].width) + ST_CELL_PAD * 2;
}

- (void)showItems:(NSArray *)items selected:(NSInteger)selected aboveView:(UIView *)view {
    UIWindow *window = view.window;
    if (!items.count || !window) {
        [self hide];
        return;
    }
    _items = [items copy];
    _selected = selected;

    CGFloat width = ST_BUBBLE_INSET * 2 + ST_CELL_GAP * (items.count - 1);
    for (NSString *word in items) {
        width += [self cellWidth:word];
    }
    CGFloat maxWidth = view.bounds.size.width - 8;
    if (width > maxWidth) {
        width = maxWidth;
    }

    if (self.superview != window) {
        [self removeFromSuperview];
        [window addSubview:self];
    }
    [window bringSubviewToFront:self];

    // Centre the bubble just above the keyboard in the keyboard's own coordinates, then carry
    // that point and the keyboard's rotation over to the window.
    self.transform = CGAffineTransformIdentity;
    self.bounds = CGRectMake(0, 0, width, ST_BUBBLE_HEIGHT);
    CGPoint above = CGPointMake(CGRectGetMidX(view.bounds), -ST_ABOVE_GAP - ST_BUBBLE_HEIGHT / 2);
    self.center = [view convertPoint:above toView:window];
    CGPoint origin = [view convertPoint:CGPointZero toView:window];
    CGPoint unitX = [view convertPoint:CGPointMake(1, 0) toView:window];
    self.transform = CGAffineTransformMakeRotation(atan2f(unitX.y - origin.y, unitX.x - origin.x));

    [self setNeedsDisplay];
    if (self.hidden || self.alpha < 1) {
        self.hidden = NO;
        [UIView animateWithDuration:0.12 animations:^{
            self.alpha = 1;
        }];
    }
}

- (void)showWord:(NSString *)word aboveView:(UIView *)view {
    [self showItems:(word.length ? @[ word ] : nil) selected:-1 aboveView:view];
}

- (void)showChoices:(NSArray *)words selected:(NSInteger)selected aboveView:(UIView *)view {
    [self showItems:words selected:selected aboveView:view];
}

- (void)hide {
    if (self.hidden) {
        return;
    }
    [UIView animateWithDuration:0.15 animations:^{
        self.alpha = 0;
    } completion:^(BOOL finished) {
        if (finished && self.alpha == 0) {
            self.hidden = YES;
        }
    }];
}

- (void)drawRect:(CGRect)rect {
    CGRect bounds = self.bounds;
    [[UIColor colorWithWhite:0.08f alpha:0.88f] setFill];
    [[UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:bounds.size.height / 2] fill];

    CGFloat cellHeight = bounds.size.height - ST_BUBBLE_INSET * 2;
    CGFloat x = ST_BUBBLE_INSET;
    for (NSUInteger i = 0; i < _items.count; i++) {
        NSString *word = _items[i];
        CGFloat w = [self cellWidth:word];
        CGRect cell = CGRectMake(x, ST_BUBBLE_INSET, w, cellHeight);
        if ((NSInteger)i == _selected) {
            [_accentColor setFill];
            [[UIBezierPath bezierPathWithRoundedRect:cell cornerRadius:cellHeight / 2] fill];
        }
        [[UIColor whiteColor] set];
        CGSize size = [word sizeWithFont:_font];
        CGPoint at = CGPointMake(x + (w - size.width) / 2, (bounds.size.height - size.height) / 2);
        [word drawAtPoint:at withFont:_font];
        x += w + ST_CELL_GAP;
    }
}

@end
