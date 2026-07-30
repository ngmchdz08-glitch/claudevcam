export THEOS_PACKAGE_SCHEME = roothide
TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = weatcamprefs

weatcamprefs_FILES    = WeatCamRootListController.m
weatcamprefs_CFLAGS   = -fobjc-arc -Wno-deprecated-declarations
weatcamprefs_FRAMEWORKS = UIKit Preferences AVFoundation PhotosUI UniformTypeIdentifiers
weatcamprefs_PRIVATE_FRAMEWORKS = Preferences MobileCoreServices
weatcamprefs_INSTALL_PATH = /Library/PreferenceBundles
weatcamprefs_PRINCIPAL_CLASS = WeatCamRootListController

include $(THEOS_MAKE_PATH)/bundle.mk
