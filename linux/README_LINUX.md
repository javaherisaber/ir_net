# IRNet Linux Version

This document explains how to build and run the Linux version of IRNet.

## Prerequisites

- Flutter SDK 3.29.0 or newer
- Linux development tools (build-essential, CMake, Ninja, etc.)
- GTK3 development libraries
- ImageMagick (for icon conversion)

## Building from source

1. Install the required dependencies:

```bash
sudo apt-get update
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev imagemagick
```

2. Convert ICO files to PNG format for Linux:

```bash
mkdir -p assets/linux
convert assets/loading.ico assets/linux/loading.png
convert assets/offline.ico assets/linux/offline.png
convert assets/network_error.ico assets/linux/network_error.png
convert assets/globe.ico assets/linux/globe.png
convert assets/iran.ico assets/linux/iran.png
```

3. Build the application:

```bash
./linux/build_linux.sh
```

The built application will be available in `build/linux/x64/release/bundle/`.

## Creating a Debian package

To create a Debian package for easy installation:

```bash
./linux/create_deb_package.sh
```

The package will be created at `build/linux/irnet_1.2.2_amd64.deb`.

## Running the application

After building, you can run the application directly:

```bash
./build/linux/x64/release/bundle/ir_net
```

Or install the Debian package:

```bash
sudo dpkg -i build/linux/irnet_1.2.2_amd64.deb
```

## System Tray

The Linux version uses the same system tray functionality as the Windows version but with PNG images instead of ICO files. The application will minimize to the system tray and can be controlled from there.

## Known Issues

- Launch at startup functionality might require additional configuration on some Linux distributions
- System tray icon appearance may vary depending on the desktop environment
