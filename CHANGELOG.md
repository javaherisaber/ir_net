# 1.6.0
- [all] add a network quality monitor: ping, jitter, packet loss, real delay and uptime with a 0–100 score, kept per exit IP to compare VPN servers and locations
- [all] estimate voice and video call quality and add an on-demand call test
- [all] export network quality as a PDF report, CSV files in a ZIP or a text summary
- [all] copy a screenshot of the network quality cards to the clipboard
- [all] list the five most recent servers in the quality comparison
- [all] leave system sleep and the reconnect after waking out of network quality
- [macOS][linux][windows][android] show internet usage per app, plus per domain and destination country on macOS and Linux
- [windows][linux] optionally show the flag of the current IP country as the system tray icon
- [all] show the current country flag in the connection card and the header chip
- [all] show app version at the overview title
- [all] fix Kerio requests being sent before credentials are saved
- [iOS] fix the build with CocoaPods and raise the minimum to iOS 13

# 1.5.0
- [all] redesign ui with a modern dark theme

# 1.4.3
- [all] integrate Sentry for error tracking
- [all] use HEAD request for ping and leak detection
- [desktop] refresh content when system awakes from sleep

# 1.4.2
- [all] fix an issue in kerio balance not visible and needs pressing auto checkbox
- [all] refresh kerio balance every 20 seconds in the background
- [all] allow saving kerio credentials when empty input is entered (to reset values)
- [all] verify leaked sites infinitely in the background

# 1.4.1
- [macOS] keep background process when pressing close button

# 1.4.0
- [linux] support linux

# 1.3.0
- [macOS] support macOS

# 1.2.3
- [windows] update app icon

# 1.2.2
- Add Kerio balance views
- Show notification when Kerio balance is less than 1 GB

# 1.2.1
- Open kerio control page in the browser by clicking on end icon

# 1.2.0
- Integrate Kerio-Control login page
- Show leaks on system tray by default

# 1.1.0
- Add speed test box
- Set a fixed height and width when starting the app
- Update window title

# 1.0
First official release