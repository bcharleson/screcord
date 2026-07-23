PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
# Command Line Tools installs often lack XCBuild; native SPM backend is reliable.
SWIFT_BUILD_FLAGS ?= -c release --build-system native
INFO_PLIST := $(CURDIR)/Resources/Info.plist
BUILD_BIN := $(CURDIR)/.build/release/screcord

.PHONY: all build debug install uninstall clean test-devices help

all: build

build:
	swift build $(SWIFT_BUILD_FLAGS) \
		-Xlinker -sectcreate \
		-Xlinker __TEXT \
		-Xlinker __info_plist \
		-Xlinker "$(INFO_PLIST)"

debug:
	swift build -c debug --build-system native \
		-Xlinker -sectcreate \
		-Xlinker __TEXT \
		-Xlinker __info_plist \
		-Xlinker "$(INFO_PLIST)"

install: build
	install -d "$(BINDIR)"
	install -m 755 "$(BUILD_BIN)" "$(BINDIR)/screcord"
	@echo "Installed $(BINDIR)/screcord"

uninstall:
	rm -f "$(BINDIR)/screcord"

clean:
	rm -rf .build

test-devices: build
	"$(BUILD_BIN)" devices

help:
	@echo "Targets: build debug install uninstall clean test-devices"
