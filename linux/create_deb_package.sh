#!/bin/bash
# Deployment script for IRNet Linux version

set -e

echo "Preparing IRNet Linux deployment..."

# Ensure we're in the project root
cd "$(dirname "$0")/.."

# Build the application if not already built
if [ ! -d "build/linux/x64/release/bundle" ]; then
  echo "Build not found, building now..."
  ./linux/build_linux.sh
fi

# Create a Debian package structure
echo "Creating Debian package structure..."
PACKAGE_DIR="build/linux/debian_package"
mkdir -p $PACKAGE_DIR/DEBIAN
mkdir -p $PACKAGE_DIR/usr/bin
mkdir -p $PACKAGE_DIR/usr/share/applications
mkdir -p $PACKAGE_DIR/usr/share/icons/hicolor/128x128/apps

# Copy the application files
echo "Copying application files..."
cp -r build/linux/x64/release/bundle/* $PACKAGE_DIR/usr/bin/

# Create a symlink for the binary
ln -sf /usr/bin/ir_net $PACKAGE_DIR/usr/bin/irnet

# Create desktop file
echo "Creating desktop entry..."
cat > $PACKAGE_DIR/usr/share/applications/irnet.desktop << EOF
[Desktop Entry]
Name=IRNet
Comment=Check if connected to Iran internet or VPN
Exec=/usr/bin/irnet
Icon=irnet
Terminal=false
Type=Application
Categories=Network;Utility;
EOF

# Copy icon
echo "Copying application icon..."
cp assets/app_icon.png $PACKAGE_DIR/usr/share/icons/hicolor/128x128/apps/irnet.png

# Create control file
echo "Creating package control file..."
cat > $PACKAGE_DIR/DEBIAN/control << EOF
Package: irnet
Version: 1.2.2
Section: net
Priority: optional
Architecture: amd64
Depends: libgtk-3-0, libblkid1, liblzma5
Maintainer: BuildToApp <info@buildtoapp.com>
Description: IRNet
 A tool to show if user is connected to Iran internet or a VPN
EOF

# Create postinst script
echo "Creating post-installation script..."
cat > $PACKAGE_DIR/DEBIAN/postinst << EOF
#!/bin/bash
chmod +x /usr/bin/ir_net
update-desktop-database
EOF
chmod +x $PACKAGE_DIR/DEBIAN/postinst

# Build the Debian package
echo "Building Debian package..."
dpkg-deb --build $PACKAGE_DIR build/linux/irnet_1.2.2_amd64.deb

echo "Debian package created: build/linux/irnet_1.2.2_amd64.deb"
