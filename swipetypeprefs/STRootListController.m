// SwipeType Settings pane — Settings > SwipeType.
// Everything except the test field and the self-test button is plain Root.plist specifiers
// that Preferences saves for us. SwipeType is loaded into Settings like any UIKit app, so the
// "Type here" field can be swiped in, and the self-test runs the tweak's decoder in-process.

#import <UIKit/UIKit.h>
#import <notify.h>

#define ST_NOTIFY_PREFS "com.mbucc9000.swipetype/prefs"

@interface PSSpecifier : NSObject
@end

@interface PSViewController : UIViewController
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
@end

@interface PSListController : PSViewController {
    NSArray *_specifiers;
}
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

@interface STRootListController : PSListController
@end

@implementation STRootListController

- (id)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    // Root.plist sets PostNotification too; posting here covers any save path that skips it.
    notify_post(ST_NOTIFY_PREFS);
}

// "Type here" row (PSEditTextCell): scratch space only, nothing is saved.
- (NSString *)tryItValue:(PSSpecifier *)specifier {
    return @"";
}

- (void)setTryItValue:(id)value specifier:(PSSpecifier *)specifier {
}

// "Run Self-Test" button: SwipeTypeSelfTest lives in the tweak, which Settings has loaded.
- (void)runSelfTest:(PSSpecifier *)specifier {
    Class test = NSClassFromString(@"SwipeTypeSelfTest");
    NSString *result = nil;
    if ([test respondsToSelector:@selector(run)]) {
        result = [test performSelector:@selector(run)];
    }
    if (!result) {
        result = @"SwipeType isn't loaded in Settings. Respring and try again.";
    }
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"SwipeType Self-Test"
                                                    message:result
                                                   delegate:nil
                                          cancelButtonTitle:@"OK"
                                          otherButtonTitles:nil];
    [alert show];
}

@end
