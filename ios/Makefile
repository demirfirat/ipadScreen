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
# Resolved through xcrun, so `DEVELOPER_DIR="/Applications/Xcode 15.4.app/
# Contents/Developer" make package` picks up the old Xcode's linker without
# changing the system-wide selection. Not searched for with a wildcard: Xcode
# installs usually have a space in the name, and make splits paths on spaces.
LD_CLASSIC := $(shell xcrun -f ld-classic 2>/dev/null)

IPadScreen_LDFLAGS = -Lvendor/libjpeg-turbo/lib -ljpeg
ifneq ($(LD_CLASSIC),)
# Quoted: Xcode installs usually have a space in their name and the linker
# path comes from inside one of them.
IPadScreen_LDFLAGS += -fuse-ld="$(LD_CLASSIC)"
endif

# Xcode 27 removed ld64 altogether: `xcrun -f ld-classic` finds nothing, and
# `-ld_classic` is parsed and ignored. That linker's replacement emits
# __picsymbolstub5 stubs for armv7, which iOS 6's dyld cannot run, so the app
# builds, installs, and then closes the moment its icon is tapped. Refuse to
# produce such a package rather than leave a debug session chasing a crash
# that isn't in the code.
after-IPadScreen-all::
	@BIN=$$(find "$(THEOS_OBJ_DIR)" -type f -name IPadScreen -not -path "*.dSYM/*" | head -1); \
	if [ -n "$$BIN" ] && otool -l "$$BIN" | grep -q __picsymbolstub5; then \
		echo "" >&2; \
		echo "  ✗ Linked with __picsymbolstub5, which iOS 6's dyld cannot run." >&2; \
		echo "    This app would crash as soon as it is opened, so the package is not built." >&2; \
		echo "    Build with Xcode 15 or older (it still has ld-classic), or install" >&2; \
		echo "    the prebuilt .deb from the releases page. See README › iPad app." >&2; \
		echo "    With the old Xcode installed alongside, build it with:" >&2; \
		echo "      DEVELOPER_DIR=\"/Applications/Xcode 15.4.app/Contents/Developer\" make package" >&2; \
		echo "" >&2; \
		exit 1; \
	fi

include $(THEOS_MAKE_PATH)/application.mk

after-install::
	install.exec "uicache; killall -9 SpringBoard"
