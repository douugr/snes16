# SNES16

**Super Nintendo** emulator made for an **old iPad with iOS 8**. Tested on an iPad 3 (A5X, armv7) running iOS 8.4.1 with a jailbreak.

It is the sibling of [MD16](https://github.com/douugr/md16): the same libretro frontend in Objective-C/UIKit, this time with the [Snes9x 2005](https://github.com/libretro/snes9x2005) core built into the app. Snes9x 2005 is an older, lighter Snes9x that fits a 2012 processor best.

## Install

Add the Cydia repository **https://douugr.github.io/repo/** (Cydia or Melder → Sources → Edit → Add) and install **SNES16**. The BTstack package is installed with it.

## Features

- OpenGL ES 2 video (RGB565, up to 512×512 in hi-res modes)
- RemoteIO audio, with game pacing driven by the audio queue
- On-screen controls shaped like the console's pad: D-pad, A/B/X/Y diamond, L/R in the top corners and Select/Start at the bottom
- **Bluetooth controller** (tested with the 8BitDo Pro 2) via BTstack, with a button setup assistant, D-pad and analog stick, and automatic reconnection
- **Upload ROMs from a browser:** the "Upload ROMs" screen shows an address (`http://snes16.local:8716/<code>/`, with the IP version below it and a QR code to upload from a phone). The code at the end is random and changes every time the screen opens, so nobody else on the network can reach the page;; on your computer, just drag the files in
- **Automatic IPS/BPS patching** for a patch with the same name as the ROM. If the ROM has a 512-byte copier header, the patch is applied to the headerless ROM, which is the common case
- 3 manual save-state slots, autosave on exit and "Continue where you left off?"
- SRAM (cartridge saves) written automatically
- Optional 1-frame run-ahead (off by default: the SNES core is heavier)
- Optional performance overlay
- Visuals inspired by the console and cartridges of the era: light grey with ridges, purple and lilac; the library shows games as labelled cartridges. The icon is original

## Requirements (to build)

- Jailbroken iPad on iOS 8 with **OpenSSH** and **BTstack** (Cydia package `ch.ringwald.btstack` 1.1)
- Mac with **Xcode 13.4.1** extracted (only the toolchain is used) and `ldid`
- SSH access to the iPad as root, ideally with a key

The app is installed in `/Applications`, outside the sandbox, so it can talk to BTdaemon.

## Build and install

```bash
export X13=/path/to/Xcode-13.4.1.app/Contents/Developer   # default: ../Xcode-13.4.1.app
export IPAD=192.168.x.x

./build.sh            # builds build/SNES16.app
./build.sh install    # builds and installs on the iPad over SSH
./build.sh roms       # sends the ROMs in ../roms to the iPad
```

The first time, `build.sh` downloads Snes9x 2005 (pinned commit) and builds the core.

## Usage

- ROMs (`.sfc`, `.smc`, `.swc`, `.fig`) live in `Documents/SNES16/roms`. Send them with **Upload ROMs**. You need your own: no ROMs come with this project.
- **Controller:** keep iOS Bluetooth off and Wi-Fi on (on the iPad 3 they share the chip). Then Controller → Search for controllers → tap your controller → Set up buttons.

## Licenses

- The code in this repository is released under the **MIT License** (see [LICENSE](LICENSE)). The icon is original, made for the project.
- **Snes9x 2005** is not included here: it is downloaded at build time and follows the Snes9x license, which is **non-commercial**.
- The packaged app (the `.deb` on the Cydia repo) is linked with Snes9x 2005, so the whole binary is also bound by that non-commercial license.
- The headers in `vendor/btstack` are from BTstack (© BlueKitchen GmbH / Matthias Ringwald) and follow the BTstack license.
