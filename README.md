# ir_net

Windows tool to show VPN connection details

<img src="screenshot.png" width="626" height="455">

## Features
- Show location of connection in map
- Leak detection on your urls
- SysTray icon without the app being open
- Start by windows startup
- Ability to minimize and hide from taskbar
- Show details of your ISP
- Update status when there is a network change
- Connect through proxy vpn types (eg. ShadowSocks, VMess, ...)

## Commands
Create .msix file:
```bat
flutter pub run msix:create
```

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
