#!/bin/zsh
# Builds build/Capinci.app (and build/capinci-cli) with plain swiftc.
# Usage: ./build.sh            build (universal: Apple Silicon + Intel)
#        ./build.sh install    build, then copy to /Applications
#        ./build.sh dist       build, then make build/Capinci-<version>.dmg to share
set -euo pipefail
cd "${0:A:h}"

BUILD=build
APP=$BUILD/Capinci.app
VERSION=1.0.1
mkdir -p $BUILD

# The Command Line Tools ship a stale include/swift/module.modulemap that
# redefines SwiftBridging and breaks `import Foundation`; hide it from swiftc.
sed "s|@EMPTY@|$PWD/tools/empty.modulemap|" tools/overlay.yaml.in > $BUILD/overlay.yaml

# One binary per architecture, then glued together so it runs on any Mac with macOS 14+.
compile() {  # compile <module name> <output> <sources...>
    local name=$1 out=$2; shift 2
    for arch in arm64 x86_64; do
        swiftc -O -target $arch-apple-macos14.0 \
            -vfsoverlay $BUILD/overlay.yaml -Xcc -ivfsoverlay -Xcc $BUILD/overlay.yaml \
            -module-name $name "$@" -o $out-$arch
    done
    lipo -create $out-arm64 $out-x86_64 -output $out
    rm $out-arm64 $out-x86_64
}

echo "› Compiling Capinci (Apple Silicon + Intel)"
compile Capinci $BUILD/Capinci -parse-as-library Sources/CapinciCore/*.swift Sources/Capinci/*.swift
compile capinci_cli $BUILD/capinci-cli Sources/CapinciCore/*.swift Sources/capinci-cli/main.swift

# App icon: tools/icon-source.png — the generated lime artwork fitted to Apple's squircle grid
# with tools/make-icon.swift (macOS 26 frames any other shape in a white plate).
if [[ ! -f $BUILD/AppIcon.icns || tools/icon-source.png -nt $BUILD/AppIcon.icns ]]; then
    echo "› Icon"
    ICONSET=$BUILD/AppIcon.iconset
    rm -rf $ICONSET && mkdir $ICONSET
    for s in 16 32 128 256 512; do
        sips -z $s $s tools/icon-source.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
        sips -z $((s * 2)) $((s * 2)) tools/icon-source.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
    done
    iconutil -c icns $ICONSET -o $BUILD/AppIcon.icns
fi

echo "› Packaging Capinci.app"
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BUILD/Capinci $APP/Contents/MacOS/Capinci
cp $BUILD/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
cp Resources/* $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Capinci</string>
    <key>CFBundleDisplayName</key><string>Capinci</string>
    <key>CFBundleIdentifier</key><string>com.etherealmoon.capinci</string>
    <key>CFBundleExecutable</key><string>Capinci</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string></array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Ethereal Moon</string>
</dict>
</plist>
EOF
# Ad-hoc signature: enough to run, but not trusted by Gatekeeper on other Macs
# (that needs an Apple Developer ID + notarization; see dist/How to open Capinci.txt).
codesign --force --sign - $APP
echo "✓ $APP"

if [[ ${1:-} == install ]]; then
    rm -rf /Applications/Capinci.app
    cp -R $APP /Applications/
    echo "✓ Installed in /Applications"
fi

if [[ ${1:-} == dist ]]; then
    echo "› Disk image"
    STAGE=$BUILD/dmg
    DMG=$BUILD/Capinci-$VERSION.dmg
    rm -rf $STAGE $DMG
    mkdir -p $STAGE
    cp -R $APP $STAGE/
    ln -s /Applications $STAGE/Applications
    cp "dist/How to open Capinci.txt" $STAGE/
    hdiutil create -volname "Capinci $VERSION" -srcfolder $STAGE -fs HFS+ -format UDZO -ov $DMG >/dev/null
    rm -rf $STAGE
    echo "✓ $DMG ($(du -h $DMG | cut -f1))"
fi
