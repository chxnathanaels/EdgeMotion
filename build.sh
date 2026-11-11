#!/bin/zsh
# Build EdgeMotion.app with the Command Line Tools (no Xcode project needed).
#   ./build.sh              build for this Mac's architecture  -> build/EdgeMotion.app
#   ./build.sh --universal  build for Intel + Apple silicon
#   ./build.sh --install    build and copy to /Applications, then open it
set -e
cd "${0:A:h}"
UNIVERSAL=0; INSTALL=0
for a in "$@"; do
  case $a in --universal) UNIVERSAL=1 ;; --install) INSTALL=1 ;; esac
done
ARCHS=($(uname -m)); [ $UNIVERSAL = 1 ] && ARCHS=(x86_64 arm64)

OUT=build; APP=$OUT/EdgeMotion.app
rm -rf $OUT; mkdir -p $OUT/obj "$APP/Contents/MacOS"
BINS=()
for arch in $ARCHS; do
  clang -O2 -Wall -arch $arch -mmacosx-version-min=13.0 -c Sources/engine.c -o $OUT/obj/engine-$arch.o
  swiftc -O -parse-as-library -target $arch-apple-macos13.0 \
    -import-objc-header Sources/engine.h Sources/App/*.swift Sources/Views/*.swift $OUT/obj/engine-$arch.o \
    -framework SwiftUI -framework AppKit -framework ApplicationServices -framework ServiceManagement \
    -o $OUT/obj/EdgeMotion-$arch
  BINS+=($OUT/obj/EdgeMotion-$arch)
done
lipo -create $BINS -output "$APP/Contents/MacOS/EdgeMotion"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign -s - -f --deep "$APP"
echo "built: $APP ($ARCHS)"

if [ $INSTALL = 1 ]; then
  pkill -x EdgeMotion 2>/dev/null || true
  rm -rf /Applications/EdgeMotion.app
  cp -R "$APP" /Applications/
  open /Applications/EdgeMotion.app
  echo "installed to /Applications"
fi
