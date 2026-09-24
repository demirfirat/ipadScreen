# iPadScreen

Use an old iPad as a second display for your Mac: a real extended desktop you
drag windows onto, with the mouse and keyboard staying on the Mac.

It was written for an iPad 2 on iOS 6.1.3. Sidecar needs iPadOS 13, and Duet
and Luna need iOS 10 or later, so none of them run on it.

```
virtual display ──► ScreenCaptureKit ──► JPEG ──► TCP (Wi-Fi or USB)
                                                        │
      CALayer ◄── libjpeg-turbo (NEON) ◄────────────────┘
```

There are two ways to view the stream on the iPad:

- **Native app** (jailbroken iPad): decodes with libjpeg-turbo and draws
  straight to a CALayer. Full screen, no browser UI.
- **Safari**: open a URL, no install. The page is a single `<img>` tag fed by
  an MJPEG stream (`multipart/x-mixed-replace`) and runs no JavaScript, so it
  works even in iOS 6 Safari.

## Performance

Measured on an iPad 2 (A5) with a 1024×768 stream:

| Viewer                          | Decode   | Frame rate |
|---------------------------------|----------|------------|
| Safari + MJPEG                  | —        | ~40 fps    |
| Native app + ImageIO            | ~54 ms   | ~23 fps    |
| Native app + libjpeg-turbo NEON | ~20 ms   | ~35 fps    |

Most of the gain comes from decoding with `JCS_EXT_BGRX`, which writes pixels
straight in CoreAnimation's native format and removes a full-frame copy.

Over Wi-Fi the iPad 2's single-antenna 802.11n saturates around 12 Mbps.
Past that point the bottleneck is decode speed, not bandwidth.

## Requirements

**Mac**

- macOS 14 or later, Intel or Apple Silicon (universal binary). Tested on
  an M1 Mac mini with macOS 26; older Intel Macs may encode more slowly.
- [BetterDisplay](https://betterdisplay.pro) to create the virtual display
  (`brew install --cask betterdisplay`). Creating a virtual screen is part of
  the free version.
- For USB mode: `brew install libimobiledevice`

**iPad**

- Safari mode: no jailbreak needed. Any device with a browser that can
  reach the Mac over the network (slower, Wi-Fi only).
- Native app: a jailbroken iPad with OpenSSH, iOS 6 or later, that can run
  32-bit (armv7) apps.

| Device                              | Native app                                         |
|-------------------------------------|----------------------------------------------------|
| iPad 2                              | Tested (iOS 6.1.3)                                 |
| iPad 3, iPad 4, iPad mini (1st gen) | Expected to work, untested. On the iPad 3 keep the virtual display at 1024×768; Retina resolution is heavy for its decoder |
| Same devices on iOS 7–9             | Probably works, untested                           |
| iPad Air, iPad mini 2/3 on iOS ≤ 10 | Should work in theory (32-bit apps still run), untested |
| Any iPad on iOS 11 or later         | No: 32-bit apps don't run                          |
| iPad (1st gen)                      | No: tops out at iOS 5.1.1. Use Safari mode         |
| iPhone / iPod touch                 | No: the app is built for iPad only. Use Safari mode |

## Mac app

```bash
./package.sh
cp -R build/iPadScreen.app /Applications/
```

On first launch right-click the app and choose **Open** to get past
Gatekeeper. Press **Start**, grant Screen Recording permission, and relaunch
when asked. macOS only applies the permission after a relaunch.

### Keeping the permission across rebuilds (optional)

The app is signed ad-hoc by default. macOS ties the Screen Recording
permission to an ad-hoc binary's hash, which changes on every build, so the
permission resets each time you rebuild. If you're developing, run this once:

```bash
./setup-signing.sh
```

It creates a self-signed code signing certificate in your login keychain and
asks for your password once. `package.sh` uses it automatically when it's
present. It only affects your machine; it doesn't help people you hand the
app to.

### Command line

```bash
./install-cli.sh          # links the binary into ~/.local/bin
ipadscreen --list         # list displays
ipadscreen --headless     # mirror without the UI
ipadscreen --help
```

Arguments passed on the command line are saved to the app's settings.

## Virtual display

In BetterDisplay create a new virtual screen with a **4:3** aspect ratio
(the iPad 2 panel is 1024×768), turn on **Connect this virtual screen**, and
set it to **Extended display** in System Settings › Displays, not mirroring.

The app picks the virtual display automatically. Lower resolutions make
everything on the iPad larger and also decode faster.

## iPad app

The app is built with [theos](https://theos.dev) against the iOS 6.1 SDK,
using the stock Apple clang that ships with the Command Line Tools. No old
Xcode or VM is needed.

### One-time setup

```bash
brew install ldid xz
git clone --recursive https://github.com/theos/theos.git ~/theos
echo 'export THEOS=~/theos' >> ~/.zshenv
```

theos's own installer refuses to run without a full Xcode, but theos itself
works fine with just the Command Line Tools, so clone it directly as above.

You also need a real `iPhoneOS6.1.sdk` in `~/theos/sdks/`. The SDKs from
`theos/sdks` start at 9.3, and the 9.3 one only has simulator `.tbd` stubs
that won't link for a device. One source is the `v1.0` release of
[growtopiajaw/iPhoneOS-SDK](https://github.com/growtopiajaw/iPhoneOS-SDK).

### Build and install

```bash
cd ios
make package
scp packages/*.deb root@<ipad-ip>:/tmp/
ssh root@<ipad-ip> 'dpkg -i /tmp/com.george.ipadscreen_*.deb && \
  chown -R mobile:mobile /Applications/IPadScreen.app && \
  su mobile -c uicache && killall -9 SpringBoard'
```

iOS 6's OpenSSH only offers `ssh-rsa` host keys, which modern OpenSSH
refuses. Add `-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa`
or put them in `~/.ssh/config`.

`uicache` has to run as `mobile`; run as root it fails with "cannot open
cache file".

### Notes for iOS 6 builds

- **No ARC.** Modern Command Line Tools don't ship `libarclite_iphoneos.a`,
  which clang needs for old deployment targets, so memory is managed by hand.
- **Don't use `@available`.** It emits a call to
  `__availability_version_check`, which doesn't exist on iOS 6.
- **armv6 doesn't work** with modern clang; armv7 and later do.
- libjpeg-turbo is prebuilt in `ios/vendor/`. Rebuild it with
  `ios/vendor/build-libjpeg-turbo.sh`.

## Using it

1. Start the Mac app. It shows a four-digit **pairing code**.
2. On the iPad, open the native app. With a USB cable attached it connects
   over the cable and pairs itself, no code needed. Without one it falls
   back to Wi-Fi and asks for the code in a popup. Either way this happens
   once: after that the iPad is paired and connects over Wi-Fi on its own.

   Or go to `http://<mac-ip>:8765` in Safari and enter the code there. Use
   **Add to Home Screen** and launch from there to get rid of the toolbars.
3. Drag windows onto the virtual display.

The native app finds the Mac by itself: the Mac app advertises
`_ipadscreen._tcp` over Bonjour and the iPad connects to whatever it finds
on the local network. If the Mac's IP changes, the app follows it.

Connecting is USB first: the app gives the cable a few seconds before
trying Wi-Fi. An iPad that isn't paired yet asks the Mac to switch to USB,
so plugging in the cable is enough to get going even if the Mac was set to
Wi-Fi.

In the native app, tap the handle on the right edge to open the settings
panel: connection mode, Mac address and live stats. Leave the address empty
for automatic discovery, or type one in to override it; a typed address is
remembered across launches.

## USB mode

A `usbmuxd` tunnel can only be opened from the Mac to the device, so over USB
the roles flip: the iPad app listens on port 8766 and the Mac connects to it
through `iproxy`. The wire format is the same as over Wi-Fi.

## Security

- **Pairing.** An iPad pairs once, over USB (the cable already means
  physical access) or with the four-digit code shown on the Mac. Pairing
  gives it a random 256-bit device key, which both sides keep. From then on
  every Wi-Fi connection is a challenge-response handshake: the Mac proves it
  knows the key first, then the iPad does. Neither the key nor the code is
  ever sent in the clear after pairing, so sniffing a connection doesn't let
  anyone log in later, and the iPad refuses a machine that only pretends to
  be your Mac.
- **Wrong codes.** Five failed attempts from one address block it for a
  minute. **New code** on the Mac forgets every paired iPad and disconnects
  all Wi-Fi viewers; they have to pair again.
- **Safari is weaker.** The browser viewer can't do the handshake, so it
  sends the code in the URL on every connection. Prefer the native app.
- **Heartbeat.** Both sides ping every two seconds and drop a connection
  that's been silent for about eight, so a vanished iPad or Mac doesn't hold
  a slot.
- **The stream isn't encrypted.** Someone who can sniff your Wi-Fi can see
  the frames. Use it on networks you trust, or over USB.
- **Only a virtual display is picked automatically.** If none is found the
  app won't start rather than fall back to a physical monitor; you can still
  pick one yourself.
- **At most four viewers** at a time.
- The iPad app's USB port only accepts connections on its loopback address,
  i.e. through the USB tunnel, not from the network.
- **Change your jailbroken iPad's root and mobile passwords** from the
  default `alpine` (`passwd`, `passwd mobile`) if SSH is enabled.

## Known issues

- **Automatic discovery needs Bonjour (mDNS) on your network.** Some guest
  or corporate Wi-Fi networks block it; type the Mac's address in the panel
  there.
- **Screen Recording permission resets on every rebuild** unless you run
  `./setup-signing.sh`.

## Wire protocol

The native app connects to `/raw` (or, over USB, the Mac connects to it) and
receives:

```
[8 bytes]  magic "IPSCRN03"
[4 bytes]  width   (big-endian uint32)
[4 bytes]  height  (big-endian uint32)
then any number of packets:
[4 bytes]  length (big-endian uint32)
[n bytes]  payload
```

If the top bit of the length is set, the payload is a UTF-8 control message
and the other 31 bits are its length; otherwise it's a JPEG frame. The iPad
sends newline-terminated UTF-8 lines back.

**Wi-Fi handshake.** The iPad opens `GET /raw?id=<device id>&cn=<nonce>`,
where both are 32 lowercase hex characters and the nonce is fresh each time.
After the header the Mac sends one of:

| Mac sends        | Meaning                    | iPad answers                          |
|------------------|----------------------------|---------------------------------------|
| `hello=<sn>:<p>` | known device               | `proof=<HMAC(key, "C:cn:sn")>`        |
| `pin=<sn>`       | unknown device, pair       | `pin=<HMAC(code, "P:cn:sn")>`         |
| `auth=locked`    | too many wrong tries       | —                                     |

`sn` is the Mac's nonce and `p` is `HMAC(key, "S:cn:sn")`; the iPad checks it
before answering, so the Mac proves itself first. HMAC is HMAC-SHA256 in
lowercase hex. On success after a `pin`, the Mac sends `key=<64 hex>`, the
new device key. Then frames start. A wrong answer gets `auth=wrong` and the
connection is closed. Nothing but the handshake is accepted before it's
done, and it has to finish within ten seconds.

**USB.** When the iPad accepts the Mac's connection it sends
`hello id=<device id>`, plus ` pair` if it has no key yet; the Mac replies
with `key=...` in that case. No code is involved.

**Afterwards**, both directions carry `mode=wifi` / `mode=usb` whenever the
mode changes (the Mac also sends it right after connecting), and `ping`
every two seconds as a heartbeat.

The Wi-Fi/USB setting is shared: changing it on either side changes it on
both. In USB mode the stream falls back to Wi-Fi while no cable is attached.

## Project layout

| Path                         | What                                        |
|------------------------------|---------------------------------------------|
| `Sources/ipadscreen/`        | Mac app (Swift, SwiftUI)                    |
| `Sources/ipadscreen/web/`    | Safari viewer page                          |
| `ios/`                       | iPad app (Objective-C, theos)               |
| `ios/vendor/libjpeg-turbo/`  | prebuilt libjpeg-turbo for armv7            |
| `assets/`                    | app icons                                   |
| `package.sh`                 | builds `iPadScreen.app`                     |
| `setup-signing.sh`           | optional local signing certificate          |
| `install-cli.sh`             | installs the command-line binary            |

## License

MIT, see [LICENSE](LICENSE). The bundled libjpeg-turbo has its own
licenses; see below.

## Credits

This software is based in part on the work of the Independent JPEG Group.
It uses [libjpeg-turbo](https://libjpeg-turbo.org), distributed under the
IJG and BSD licenses; see `ios/vendor/libjpeg-turbo/LICENSE.md`.
