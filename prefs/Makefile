ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = OBDelevenUpdateBypassPrefs

OBDelevenUpdateBypassPrefs_FILES = OBDUBRootListController.m
OBDelevenUpdateBypassPrefs_FRAMEWORKS = Foundation UIKit CoreFoundation
OBDelevenUpdateBypassPrefs_PRIVATE_FRAMEWORKS = Preferences
OBDelevenUpdateBypassPrefs_INSTALL_PATH = /Library/PreferenceBundles
OBDelevenUpdateBypassPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
