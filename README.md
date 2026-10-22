# Fan Control for macOS

A small menu bar app for viewing MacBook fan speed and temperature and setting a manual fan speed. It can return individual fans or all fans to macOS automatic control. Built from the FanControl source already on Yupeng's MacBook.

## Requirements

- macOS 14 or later
- Apple Silicon Mac with writable fan controls exposed by AppleSMC (other Macs may show readings but may not support changes)
- Xcode Command Line Tools to build from source

## Install

Download `FanControl-macOS.zip` from the [latest release](https://github.com/chaoyupeng/fan-control/releases/latest), unzip it, and move `FanControl.app` to Applications. The app is ad-hoc signed and not notarized; macOS may require **System Settings → Privacy & Security → Open Anyway** on first launch.

The app can read fan data without a helper. Changing fan speed requires a one-time administrator approval to install a small root-owned helper. The app only sends this helper `set` and `auto` commands for detected fans. Choose **All Auto** or quit the app to return fans to macOS control.

## Build

```sh
./build.sh
open build/FanControl.app
```

The build produces `build/FanControl.app`. All code is local Swift and C with Apple frameworks; it does not use third-party dependencies or make network requests.

## Safety

Manual fan control can affect cooling. The helper clamps requested speed to each fan's reported minimum and maximum. Use **All Auto** when you no longer need manual control. The app attempts to restore automatic control when it quits normally; a forced termination may prevent that, so reopen it and select **All Auto** if needed.
