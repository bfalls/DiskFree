#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project DiskFree.xcodeproj -scheme DiskFree -configuration Release \
  -derivedDataPath build ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build
printf '\nApplication: %s/build/Build/Products/Release/DiskFree.app\n' "$PWD"
