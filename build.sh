#!/bin/zsh
# Build LaunchGrid.app with the Command Line Tools (xcode-select --install).
#   ./build.sh              build for this Mac -> build/LaunchGrid.app
#   ./build.sh --universal  Intel + Apple silicon
#   ./build.sh --install    build, copy to /Applications, open
set -e
cd "${0:A:h}"
UNIVERSAL=0; INSTALL=0
for a in "$@"; do case $a in --universal) UNIVERSAL=1 ;; --install) INSTALL=1 ;; esac; done
ARCHS=($(uname -m)); [ $UNIVERSAL = 1 ] && ARCHS=(x86_64 arm64)
OUT=build; APP=$OUT/LaunchGrid.app
rm -rf $OUT; mkdir -p $OUT/obj "$APP/Contents/MacOS" "$APP/Contents/Resources"
BINS=()
for arch in $ARCHS; do
  swiftc -O -parse-as-library -target $arch-apple-macos14.0 Sources/*.swift \
    -framework SwiftUI -framework AppKit -framework Carbon -framework ServiceManagement \
    -o $OUT/obj/LaunchGrid-$arch
  BINS+=($OUT/obj/LaunchGrid-$arch)
done
lipo -create $BINS -output "$APP/Contents/MacOS/LaunchGrid"
cp Resources/Info.plist "$APP/Contents/Info.plist"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
codesign -s - -f --deep "$APP"
echo "built: $APP ($ARCHS)"
if [ $INSTALL = 1 ]; then
  pkill -x LaunchGrid 2>/dev/null || true
  rm -rf /Applications/LaunchGrid.app
  cp -R "$APP" /Applications/
  open /Applications/LaunchGrid.app
  echo "installed to /Applications"
fi
