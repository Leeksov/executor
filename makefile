ARCHS = arm64
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = executor

# === Luau ===
LUAU_BASEDIR := src/3rdparty/luau
LUAU_SUBDIRS := Analysis Ast CodeGen Common Compiler Config EqSat Require VM
LUAU_INCLUDE := $(foreach dir,$(LUAU_SUBDIRS),-I$(LUAU_BASEDIR)/$(dir)/include -I$(LUAU_BASEDIR)/$(dir)/src)

# === Build options ===
$(TWEAK_NAME)_CCFLAGS = -std=c++17 $(LUAU_INCLUDE) -Wno-deprecated-declarations
$(TWEAK_NAME)_CFLAGS  = -fobjc-arc

# === Sources ===
$(TWEAK_NAME)_FILES := $(shell find src -type f \( -iname "*.mm" -o -iname "*.cpp" -o -iname "*.m" -o -iname "*.c" \))

include $(THEOS_MAKE_PATH)/tweak.mk
