export THEOS ?= $(HOME)/theos

# sdk:deployment-target — build against a real iPhoneOS6.1 SDK, target iOS 6.0.
TARGET := iphone:clang:6.1:6.0
ARCHS := armv7

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = IPadScreen

IPadScreen_FILES = main.m IPSViewController.m IPSSettingsPanel.m IPSDiscovery.m IPSCrypto.m StreamClient.m TurboDecoder.m
IPadScreen_FRAMEWORKS = UIKit CoreGraphics QuartzCore Security
IPadScreen_PRIVATE_FRAMEWORKS =

# No ARC: modern Command Line Tools don't ship `libarclite_iphoneos.a`,
# which clang requires for old deployment targets. Memory is managed by
# hand.
#
# libjpeg-turbo is prebuilt for armv7/NEON (under vendor/) and replaces
# ImageIO for decoding.
IPadScreen_CFLAGS = -fno-objc-arc -Wno-deprecated-declarations -O2 \
                    -Ivendor/libjpeg-turbo/include

# Recent Apple linkers emit a stub format (__picsymbolstub5, no lazy binding)
# that iOS 6's dyld doesn't understand: the app crashes at launch jumping to
# a bad address. The classic linker still produces the old format. Without
# it, the build still works but the app may not start; see the README.
LD_CLASSIC := $(shell xcrun -f ld-classic 2>/dev/null)

IPadScreen_LDFLAGS = -Lvendor/libjpeg-turbo/lib -ljpeg
ifneq ($(LD_CLASSIC),)
IPadScreen_LDFLAGS += -fuse-ld=$(LD_CLASSIC)
endif

include $(THEOS_MAKE_PATH)/application.mk

after-install::
	install.exec "uicache; killall -9 SpringBoard"
