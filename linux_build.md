Publishing a **Linux desktop app made with Flutter** involves packaging it properly and distributing it through a method that fits your audience (e.g. direct download, GitHub, PPA, Snap, Flatpak, etc.).

Here’s a complete **step-by-step guide from scratch** tailored for a Flutter Linux app.

---

## ✅ STEP 0: Prerequisites

Make sure you have:

* Flutter installed and working with desktop support (`flutter doctor`)
* `dpkg-deb`, `cmake`, `make`, `gcc`, and `glib` installed on Ubuntu
* Your Flutter app is already working on Linux (`flutter run -d linux`)

---

## ✅ STEP 1: Build the App for Release

```bash
flutter build linux --release
```

This creates your app in:

```
build/linux/x64/release/bundle/
```

Contents:

* `ir_net` (binary)
* `flutter_assets/` (assets)
* Shared libraries

---

## ✅ STEP 2: Create Debian Package Structure

Structure your `.deb` folder manually:

```bash
mkdir -p ir_net_pkg/DEBIAN
mkdir -p ir_net_pkg/usr/bin/ir_net
mkdir -p ir_net_pkg/usr/share/applications
mkdir -p ir_net_pkg/usr/share/icons/hicolor/256x256/apps
```

---

## ✅ STEP 3: Copy Build Output

```bash
cp -r build/linux/x64/release/bundle/* ir_net_pkg/usr/bin/ir_net/
```

Make sure the binary is executable:

```bash
chmod +x ir_net_pkg/usr/bin/ir_net/ir_net
```

---

## ✅ STEP 4: Create Control File

Create `ir_net_pkg/DEBIAN/control`:

```text
Package: ir-net
Version: 1.0.0
Section: utils
Priority: optional
Architecture: amd64
Depends: libgtk-3-0, libglib2.0-0
Maintainer: Your Name <you@example.com>
Description: IR Net – A Flutter desktop app for Linux.
```

---

## ✅ STEP 5: Add .desktop Launcher

Create `ir_net_pkg/usr/share/applications/ir_net.desktop`:

```desktop
[Desktop Entry]
Name=IR Net
Comment=IR Net Desktop App
Exec=/usr/bin/ir_net/ir_net
Icon=ir_net
Terminal=false
Type=Application
Categories=Utility;
```

---

## ✅ STEP 6: Add App Icon

Put your 256x256 PNG icon in:

```bash
cp linux/assets/icon.png ir_net_pkg/usr/share/icons/hicolor/256x256/apps/ir_net.png
```

---

## ✅ STEP 7: Build the `.deb` Package

```bash
dpkg-deb --build ir_net_pkg
```

This creates:

```
ir_net_pkg.deb
```

Rename it if you like:

```bash
mv ir_net_pkg.deb ir-net_1.0.0_amd64.deb
```

---

## ✅ STEP 8: Test Your Package

```bash
sudo dpkg -i ir-net_1.0.0_amd64.deb
```

To fix missing dependencies:

```bash
sudo apt-get install -f
```

Then launch your app from the system menu or via:

```bash
/usr/bin/ir_net/ir_net
```

---

## ✅ STEP 9: Distribute Your App

Here are common methods to publish:

### 🔹 GitHub Releases (Simple, Direct)

1. Create a GitHub repo (if you haven’t)
2. Upload your `.deb` file in the "Releases" section
3. Share the link (e.g. [https://github.com/you/ir\_net/releases](https://github.com/you/ir_net/releases))

### 🔹 Snapcraft (Canonical)

Use if you want your app in the **Snap Store**. You'll need:

* A Snapcraft.yaml file
* An account at [https://snapcraft.io](https://snapcraft.io)
* Snapcraft CLI

Let me know if you want this path — it's a bit more involved.

### 🔹 Flatpak (Flathub)

Alternative to Snap. Good for wide desktop support.

### 🔹 Personal APT Repo or Launchpad PPA

If you want users to `apt install ir-net`:

* Host your `.deb` files on a web server or Launchpad
* Sign your packages
* Create a repository index

Let me know if you want to go this route.

---

## ✅ Recap Checklist

| ✅ Task                      | Done? |
| --------------------------- | ----- |
| `flutter build linux`       | ✔️    |
| Create `.deb` structure     | ✔️    |
| Add control & desktop files | ✔️    |
| Include icon and binary     | ✔️    |
| Build & test `.deb` package | ✔️    |
| Upload or publish           | ⬜     |

---
