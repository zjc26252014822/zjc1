export THEOS = /opt/theos
export SYSROOT = $(THEOS)/sdks/iPhoneOS16.5.sdk
export TARGET = iphone:clang:16.5:16.0
export ARCHS = arm64 arm64e
export THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

# ElleKit injects alphabetically. Load before Stheno.dylib so the Swift
# allocator hook sees ReflectManager's initial singleton allocation.
TWEAK_NAME = 000SthenoBounds 000SthenoKeyboardFix

# --- Tweak 1: 边界（小窗跑出屏幕）修复，只 hook Stheno.dylib (SpringBoard)
000SthenoBounds_FILES = Tweak.xm
000SthenoBounds_CFLAGS = -fobjc-arc
000SthenoBounds_FRAMEWORKS = UIKit Foundation
000SthenoBounds_LIBRARIES = substrate roothide
000SthenoBounds_CODESIGN_FLAGS = -SSthenoBounds.entitlements

# --- Tweak 2: 键盘修复，hook 系统键盘类 (UIKit 进程 = app/SpringBoard)
000SthenoKeyboardFix_FILES = KeyboardFix.xm
000SthenoKeyboardFix_CFLAGS = -fobjc-arc
000SthenoKeyboardFix_FRAMEWORKS = UIKit Foundation
000SthenoKeyboardFix_LIBRARIES = substrate roothide
000SthenoKeyboardFix_CODESIGN_FLAGS = -SSthenoKeyboardFix.entitlements

include $(THEOS_MAKE_PATH)/tweak.mk
