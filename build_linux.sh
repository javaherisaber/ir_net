#!/bin/bash

# Script to build a .deb package for IR Net Linux app
# This script automates all steps from linux_build.md

set -e  # Exit on error

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PUBSPEC_FILE="$SCRIPT_DIR/pubspec.yaml"
BUILD_DIR="$SCRIPT_DIR/build/linux/x64/release/bundle"
PKG_NAME="ir_net_pkg"
PKG_DIR="$SCRIPT_DIR/outputs/$PKG_NAME"
ASSET_ICON="$SCRIPT_DIR/assets/app_icon.png"
OUTPUT_DIR="$SCRIPT_DIR/outputs"
MAINTAINER_EMAIL="${MAINTAINER_EMAIL:-m.javaherisaber@gmail.com}"
MAINTAINER_NAME="${MAINTAINER_NAME:-Mehdi Javaheri Saber}"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if pubspec.yaml exists
if [[ ! -f "$PUBSPEC_FILE" ]]; then
    print_error "pubspec.yaml not found at $PUBSPEC_FILE"
    exit 1
fi

# Extract version from pubspec.yaml
print_info "Reading version from pubspec.yaml..."
VERSION=$(grep "^version:" "$PUBSPEC_FILE" | head -1 | sed -E 's/version:\s+([^\s+]+).*/\1/')

if [[ -z "$VERSION" ]]; then
    print_error "Could not find version in $PUBSPEC_FILE"
    exit 1
fi

print_info "Found version: $VERSION"

# Create outputs directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Step 1: Build the app for release
print_info "STEP 1: Building Flutter app for Linux release..."
flutter build linux --release

if [[ ! -d "$BUILD_DIR" ]]; then
    print_error "Build output not found at $BUILD_DIR"
    exit 1
fi

print_info "Build completed successfully"

# Step 2: Create Debian package structure
print_info "STEP 2: Creating Debian package structure..."
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/DEBIAN"
mkdir -p "$PKG_DIR/usr/bin/ir_net"
mkdir -p "$PKG_DIR/usr/share/applications"
mkdir -p "$PKG_DIR/usr/share/icons/hicolor/256x256/apps"

print_info "Package structure created"

# Step 3: Copy build output
print_info "STEP 3: Copying build output..."
cp -r "$BUILD_DIR"/* "$PKG_DIR/usr/bin/ir_net/"
chmod +x "$PKG_DIR/usr/bin/ir_net/ir_net"
# Sentry spawns crashpad_handler as a process, but the bundle install drops its execute bit
if [[ -f "$PKG_DIR/usr/bin/ir_net/lib/crashpad_handler" ]]; then
    chmod +x "$PKG_DIR/usr/bin/ir_net/lib/crashpad_handler"
fi

print_info "Build output copied"

# Step 4: Create control file
print_info "STEP 4: Creating control file..."

# Libraries the binaries link (GTK, appindicator for the tray, libcurl for Sentry, and the
# minimum glibc) are read from the binaries by dpkg-shlibdeps, so package names and versions
# match the distro the app was built on. libdartjni.so is skipped: it links libjvm for the
# Android-only jni plugin and is never loaded on Linux.
if ! command -v dpkg-shlibdeps &> /dev/null; then
    print_error "dpkg-shlibdeps not found. Install it with: sudo apt-get install dpkg-dev"
    exit 1
fi
APP_DIR="$PKG_DIR/usr/bin/ir_net"
SHLIB_BINARIES=("$APP_DIR/ir_net")
for binary in "$APP_DIR"/lib/*.so "$APP_DIR/lib/crashpad_handler"; do
    if [[ -f "$binary" && "$(basename "$binary")" != "libdartjni.so" ]]; then
        SHLIB_BINARIES+=("$binary")
    fi
done
SHLIBDEPS_DIR=$(mktemp -d)
mkdir -p "$SHLIBDEPS_DIR/debian"
printf 'Source: ir-net\n\nPackage: ir-net\nArchitecture: any\n' > "$SHLIBDEPS_DIR/debian/control"
SHLIB_DEPENDS=$(cd "$SHLIBDEPS_DIR" && dpkg-shlibdeps -O -l"$APP_DIR/lib" "${SHLIB_BINARIES[@]}" 2> "$SHLIBDEPS_DIR/errors.log" \
    | sed -n 's/^shlibs:Depends=//p')
if [[ -z "$SHLIB_DEPENDS" ]]; then
    print_error "dpkg-shlibdeps could not work out the shared library dependencies:"
    grep -v 'warning:' "$SHLIBDEPS_DIR/errors.log" >&2 || true
    rm -rf "$SHLIBDEPS_DIR"
    exit 1
fi
rm -rf "$SHLIBDEPS_DIR"

# Loaded or run at runtime, so not visible to dpkg-shlibdeps: SQLite (FFI), ss and ps (data usage)
cat > "$PKG_DIR/DEBIAN/control" << EOF
Package: ir-net
Version: $VERSION
Section: utils
Priority: optional
Architecture: amd64
Depends: $SHLIB_DEPENDS, libsqlite3-0, iproute2, procps
Maintainer: $MAINTAINER_NAME <$MAINTAINER_EMAIL>
Description: IRNet – A Flutter desktop app for Linux.
 IRNet is a tool to show network connection details.
EOF

print_info "Control file created"

# Step 5: Add .desktop launcher
print_info "STEP 5: Creating .desktop launcher..."
cat > "$PKG_DIR/usr/share/applications/ir_net.desktop" << 'EOF'
[Desktop Entry]
Name=IRNet
Comment=IRNet Desktop App
Exec=/usr/bin/ir_net/ir_net
Icon=ir_net
Terminal=false
Type=Application
Categories=Utility;
EOF

print_info ".desktop launcher created"

# Step 6: Add app icon
print_info "STEP 6: Adding app icon..."
if [[ -f "$ASSET_ICON" ]]; then
    cp "$ASSET_ICON" "$PKG_DIR/usr/share/icons/hicolor/256x256/apps/ir_net.png"
    print_info "App icon copied"
else
    print_warning "App icon not found at $ASSET_ICON. Skipping icon installation."
fi

# Step 7: Build the .deb package
print_info "STEP 7: Building .deb package..."
DEB_FILENAME="IRNet_linux_setup_${VERSION}.deb"
dpkg-deb --build "$PKG_DIR" "$OUTPUT_DIR/$DEB_FILENAME"

# Step 8: Cleanup
print_info "STEP 8: Cleaning up..."
print_info "Removing temporary package directory..."
rm -rf "$PKG_DIR"

if [[ -f "$OUTPUT_DIR/$DEB_FILENAME" ]]; then
    print_info "✅ Successfully created: $DEB_FILENAME"
    print_info "Location: $OUTPUT_DIR/$DEB_FILENAME"
    print_info ""
    print_info "To test the package, run:"
    print_info "  sudo dpkg -i $OUTPUT_DIR/$DEB_FILENAME"
    print_info ""
    print_info "To fix missing dependencies, run:"
    print_info "  sudo apt-get install -f"
    print_info ""
    print_info "To launch the app:"
    print_info "  /usr/bin/ir_net/ir_net"
else
    print_error "Failed to create .deb package"
    exit 1
fi