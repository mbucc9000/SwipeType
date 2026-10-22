// SwipeType — the swipe trail drawn over the keyboard.
// A tapered "comet" that fades behind the finger, a glow on each key the finger passes, and
// an outline on the key the finger is heading toward.

#import <UIKit/UIKit.h>
#import "STDecoder.h"

@interface SwipeTypeTrailView : UIView

@property (nonatomic, strong) UIColor *trailColor;
@property (nonatomic, assign) CGFloat trailWidth;
@property (nonatomic, assign) BOOL showKeys;

// Letter geometry (layout coordinates) used for key glows; frames are the visible key caps.
- (void)setKeyMap:(const STKeyMap *)keyMap frames:(const CGRect *)frames;

- (void)beginAtPoint:(CGPoint)point;
- (void)addPoint:(CGPoint)point;
- (void)finish;   // finger lifted: fade everything out
- (void)cancel;   // hide immediately

@end
