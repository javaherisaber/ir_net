# ir_net

Utility for power users that want to see VPN connection details

<img src="https://github.com/user-attachments/assets/0146de59-bc97-4232-a7fd-eae9389dd87e" width="626" height="455">

## Features
- Show location of connection in map
- Leak detection on your urls
- SysTray icon without the app being open
- Start by startup
- Ability to minimize and hide from taskbar
- Show details of your ISP
- Update status when there is a network change
- Connect through proxy vpn types (eg. ShadowSocks, VMess, ...)
- Auto Connect to Kerio Network
- Show usage and statistics of Kerio network

## Build windows installer
Run the build script which updates the version, builds the app, and compiles the installer:
```powershell
.\build_windows.ps1
```
Output .exe file will be in the `inno/Output` directory.

## Build macos package
1. Build .app file
```bat
flutter build macos --release
```
3. Put it in a folder named IRNet
2. Create a symbolic link to Applications
```bat
ln -s /Applications Applications
```
3. Open Disk Utils app and go to File -> New Image -> Image from folder
4. Select IRNet folder and press save

## Build linux package
1. Build binaries
```bash
./build_linux.sh
```

Follow the instructions [here](/linux_build.md) for more details (if needed)

## TODO
- Add alternative api service
- Choose default country and show flag based on that
- Option to show all countries flag
- Add statistics eg. (number of times and minutes there was a network error, reasons of network failure)
- Add app launcher icon
- Show error reason in leak detection list
- Show which app occupied a port
- Speed test
- Shortcuts to important screens of windows (eg. Network adapters)
- Retry one more time if there was a leak found during switch to new network
- Reset ip lookup result when there is no network
