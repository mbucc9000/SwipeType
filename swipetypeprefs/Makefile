TARGET = iphone:clang:6.1:6.0
ARCHS = armv7

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SwipeTypePrefs
SwipeTypePrefs_FILES = STRootListController.m
SwipeTypePrefs_INSTALL_PATH = /Library/PreferenceBundles
SwipeTypePrefs_FRAMEWORKS = UIKit Foundation
SwipeTypePrefs_CFLAGS = -fobjc-arc

# Link Preferences if the SDK ships it; otherwise let dyld resolve PSListController/PSSpecifier
# at load time (Settings already has Preferences.framework loaded).
ifneq ($(wildcard $(THEOS)/sdks/iPhoneOS6.1.sdk/System/Library/PrivateFrameworks/Preferences.framework),)
SwipeTypePrefs_PRIVATE_FRAMEWORKS = Preferences
else
SwipeTypePrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
endif

include $(THEOS)/makefiles/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/SwipeType.plist$(ECHO_END)
