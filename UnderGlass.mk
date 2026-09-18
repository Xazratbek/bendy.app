UG_DIR := .dist/UnderGlass.app/Contents
UG_SOURCES := $(wildcard Sources/UnderGlass/*.swift) Sources/BendyLocal/Sensor/LidAngleSensor.swift
.PHONY: build install smoke dmg icon
build: icon
	mkdir -p .build/underglass $(UG_DIR)/MacOS $(UG_DIR)/Resources
	swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -framework AppKit -framework IOKit -framework Carbon $(UG_SOURCES) -o .build/underglass/UnderGlass
	cp .build/underglass/UnderGlass $(UG_DIR)/MacOS/UnderGlass
	cp Resources/UnderGlass-Info.plist $(UG_DIR)/Info.plist
	cp LICENSE $(UG_DIR)/Resources/LICENSE-Clamshell.txt
	cp .build/underglass/UnderGlass.icns $(UG_DIR)/Resources/UnderGlass.icns
	codesign --force --sign - .dist/UnderGlass.app
icon:
	mkdir -p .build/underglass/UnderGlass.iconset
	swiftc -O -framework AppKit Tools/UnderGlassIcon/main.swift -o .build/underglass/IconRender
	.build/underglass/IconRender .build/underglass/icon.png
	for size in 16 32 128 256 512; do sips -z $$size $$size .build/underglass/icon.png --out .build/underglass/UnderGlass.iconset/icon_$${size}x$${size}.png >/dev/null; double=$$((size * 2)); sips -z $$double $$double .build/underglass/icon.png --out .build/underglass/UnderGlass.iconset/icon_$${size}x$${size}@2x.png >/dev/null; done
	iconutil -c icns .build/underglass/UnderGlass.iconset -o .build/underglass/UnderGlass.icns
install: build
	ditto .dist/UnderGlass.app /Applications/UnderGlass.app
smoke: build
	.dist/UnderGlass.app/Contents/MacOS/UnderGlass --smoke-test
dmg: build
	mkdir -p .dist/underglass-dmg
	ditto .dist/UnderGlass.app .dist/underglass-dmg/UnderGlass.app
	ln -sfn /Applications .dist/underglass-dmg/Applications
	hdiutil create -volname UnderGlass -fs HFS+ -srcfolder .dist/underglass-dmg -ov -format UDZO .dist/UnderGlass-0.1.0-preview.dmg
