export THEOS = /opt/theos
export SYSROOT = $(THEOS)/sdks/iPhoneOS16.5.sdk
export TARGET = iphone:clang:16.5:16.0
export ARCHS = arm64 arm64e
export THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SthenoBounds
SthenoBounds_FILES = Tweak.xm
SthenoBounds_CFLAGS = -fobjc-arc
SthenoBounds_FRAMEWORKS = UIKit Foundation
SthenoBounds_LIBRARIES = substrate roothide
SthenoBounds_CODESIGN_FLAGS = -SSthenoBounds.entitlements

include $(THEOS_MAKE_PATH)/tweak.mk
