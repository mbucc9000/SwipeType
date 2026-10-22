TARGET = iphone:clang:6.1:6.0
ARCHS = armv7

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SwipeType
SwipeType_FILES = Tweak.x STDecoder.c STLexiconData.c STTrailView.m STPreviewView.m
SwipeType_FRAMEWORKS = UIKit Foundation AudioToolbox QuartzCore CoreGraphics
SwipeType_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/tweak.mk

SUBPROJECTS += swipetypeprefs
include $(THEOS)/makefiles/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard"
