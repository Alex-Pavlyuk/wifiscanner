#!/bin/sh
# Builds the SwiftUI app bundle and the CLI tool with the command-line Swift toolchain (no Xcode project needed).
set -e
cd "$(dirname "$0")"

swiftc -O -parse-as-library \
  -framework CoreWLAN -framework CoreLocation -framework SwiftUI -framework AppKit \
  -o WiFiScannerApp.app/Contents/MacOS/WiFiScannerApp WiFiScannerApp.swift
# Re-sign so Info.plist (Location usage description) is bound to the bundle.
codesign --force --deep --sign - WiFiScannerApp.app

swiftc -O -framework CoreWLAN -framework Foundation -o wifiscanner wifiscanner.swift

echo "Built: WiFiScannerApp.app and ./wifiscanner"
