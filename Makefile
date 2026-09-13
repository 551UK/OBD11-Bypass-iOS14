ARCHS = arm64
TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = OBDelevenUpdateBypass
OBDelevenUpdateBypass_FILES = Tweak.m LoginDiagnostics.m
OBDelevenUpdateBypass_CFLAGS = -fvisibility=hidden -fobjc-arc
OBDelevenUpdateBypass_FRAMEWORKS = Foundation UIKit CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
