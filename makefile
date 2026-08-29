ARCHS = arm64
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = executor

# === Luau (only the modules we actually use) ===
LUAU_BASEDIR := src/3rdparty/luau
LUAU_ALL_SUBDIRS := Analysis Ast CodeGen Common Compiler Config EqSat Require VM
LUAU_BUILD_SUBDIRS := Ast Compiler VM
LUAU_INCLUDE := $(foreach dir,$(LUAU_ALL_SUBDIRS),-I$(LUAU_BASEDIR)/$(dir)/include -I$(LUAU_BASEDIR)/$(dir)/src)

# === Build options ===
$(TWEAK_NAME)_CCFLAGS = -std=c++17 $(LUAU_INCLUDE) -Wno-deprecated-declarations -Wno-nontrivial-memcall -Wno-unused-but-set-variable
$(TWEAK_NAME)_CFLAGS  = -fobjc-arc

# === Sources: our code + imgui + only needed Luau modules ===
TWEAK_SOURCES := $(shell find src -maxdepth 1 -type f \( -iname "*.mm" -o -iname "*.cpp" \))
TWEAK_SOURCES += $(shell find src/gestures -type f \( -iname "*.mm" -o -iname "*.cpp" \))
TWEAK_SOURCES += $(shell find src/3rdparty/imgui -type f \( -iname "*.mm" -o -iname "*.cpp" \))
TWEAK_SOURCES += $(foreach dir,$(LUAU_BUILD_SUBDIRS),$(shell find $(LUAU_BASEDIR)/$(dir)/src -type f \( -iname "*.cpp" -o -iname "*.c" \)))

$(TWEAK_NAME)_FILES := $(TWEAK_SOURCES)

include $(THEOS_MAKE_PATH)/tweak.mk
