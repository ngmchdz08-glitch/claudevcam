export THEOS_PACKAGE_SCHEME = roothide
TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WeatVCamera

WeatVCamera_FILES    = Tweak.x
WeatVCamera_CFLAGS   = -fobjc-arc \
                       -Wno-unused-variable \
                       -Wno-deprecated-declarations \
                       -DTARGET_OS_IPHONE=1
WeatVCamera_FRAMEWORKS = AVFoundation CoreVideo UIKit VideoToolbox \
                         CoreMedia CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += weatcamprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
