#!/bin/bash
# Build script for IRNet Linux version

set -e

echo "Building IRNet for Linux..."

# Ensure we're in the project root
cd "$(dirname "$0")/.."

# Install dependencies
echo "Installing dependencies..."
flutter pub get

# Convert ICO files to PNG for Linux system tray
echo "Preparing Linux assets..."
mkdir -p assets/linux

# You'll need to manually convert ICO files to PNG format for Linux
# For example, using ImageMagick:
# convert assets/loading.ico assets/linux/loading.png
# convert assets/offline.ico assets/linux/offline.png
# convert assets/network_error.ico assets/linux/network_error.png
# convert assets/globe.ico assets/linux/globe.png
# convert assets/iran.ico assets/linux/iran.png

# Build the Linux application
echo "Building Linux application..."
flutter build linux --release

echo "Build completed successfully!"
echo "The application can be found in: build/linux/x64/release/bundle/"
