TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard
# rootless собирается через: make package THEOS_PACKAGE_SCHEME=rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SamsungCC
SamsungCC_FILES = Tweak.xm SCCView.m
SamsungCC_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
SamsungCC_FRAMEWORKS = UIKit AVFoundation QuartzCore

SUBPROJECTS += samsungccprefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
