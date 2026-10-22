// SwipeType — the word bubble shown just above the keyboard while swiping.
// Shows the current best guess; after a hold it lists alternatives with one highlighted.
// Visual only (no touches): it lives in the keyboard's window, rotated to match the keyboard.

#import <UIKit/UIKit.h>

@interface SwipeTypePreviewView : UIView

@property (nonatomic, strong) UIColor *accentColor;

- (void)showWord:(NSString *)word aboveView:(UIView *)view;
- (void)showChoices:(NSArray *)words selected:(NSInteger)selected aboveView:(UIView *)view;
- (void)hide;

@end
