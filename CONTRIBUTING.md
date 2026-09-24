# Contributing

Thanks for helping. iPadScreen has only been tested on one iPad (iPad 2,
iOS 6.1.3) and one Mac (M1 Mac mini, macOS 26), so reports from other
hardware are as useful as code.

## Ways to help

- **Try it on other devices** and open an issue with the result, working or
  not. Include:
  - Mac model, macOS version, Intel or Apple Silicon
  - iPad model and iOS version (or the browser, for Safari mode)
  - Wi-Fi or USB, and the numbers from the iPad app's settings panel
    (drawn fps, decode ms, network fps, dropped frames)
  - What went wrong, and the Mac log if relevant: run
    `/Applications/iPadScreen.app/Contents/MacOS/iPadScreen -v` in Terminal
- **Port the host side to Windows or Linux.** The iPad app doesn't care what
  it's talking to, so a new platform only needs a server. See
  [Porting the host](#porting-the-host).
- **Fix bugs** and the issues listed under "Known issues" in the README.

## Building

See the README: [Mac app](README.md#mac-app) and [iPad app](README.md#ipad-app).
Short version:

```bash
./package.sh            # Mac app → build/iPadScreen.app
cd ios && make package  # iPad app → ios/packages/*.deb (needs theos + iOS 6.1 SDK)
```

## Code guidelines

- Match the surrounding code: naming, comment density, structure.
- Comments, log messages and UI text are in English.
- Comments explain *why*, especially for workarounds; a lot of the code
  exists because something simpler didn't work on iOS 6 or over `iproxy`.
- **iPad app (Objective-C):** it has to build for iOS 6 with modern clang.
  - No ARC (`libarclite` isn't available): retain/release by hand.
  - No `@available`, no APIs newer than iOS 6 without a runtime check
    (`respondsToSelector:`).
  - armv7 only.
- **Mac app (Swift):** macOS 14+, no third-party dependencies.
- Keep the Safari viewer JavaScript-free; it has to work in iOS 6 Safari.

## Protocol changes

The wire protocol is documented in the README under
[Wire protocol](README.md#wire-protocol). If you change it:

- Change the 8-byte magic (`IPSCRN03` → `IPSCRN04`) on both sides, so a mixed
  pair fails clearly instead of misbehaving.
- Update the README section in the same pull request.
- Don't weaken the pairing: the key and the PIN must never be sent in the
  clear, and the host must prove itself before the iPad answers.

## Porting the host

A new host (Windows, Linux, …) has to:

1. **Capture a display** and encode frames as baseline JPEG, ideally from a
   virtual display at 4:3 (1024×768 for an iPad 2). On Windows an IddCx
   driver such as [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver)
   plus Windows.Graphics.Capture or DXGI Desktop Duplication; on Linux evdi
   plus PipeWire.
2. **Serve TCP port 8765:** `GET /raw?...` for the native app (see Wire
   protocol) and, optionally, `/` and `/stream` for the Safari viewer
   (MJPEG, `multipart/x-mixed-replace`).
3. **Do the pairing handshake** exactly as documented: HMAC-SHA256, lowercase
   hex, server proof first. Store device keys per device ID. Throttle wrong
   PINs (the Mac app locks an address for 60 s after 5 failures).
4. **Send `ping` every 2 s** and drop native clients silent for 8 s.
5. **Advertise `_ipadscreen._tcp`** over Bonjour/mDNS on port 8765 so the
   iPad finds it without typing an address.
6. **USB (optional):** forward a local port to the iPad's port 8766 with
   `iproxy 8766 8766` (libimobiledevice; on Windows it also needs Apple's
   Mobile Device service, which comes with iTunes), then connect to it and
   speak the USB variant of the protocol.

Keep frames flowing slowly rather than queueing: the iPad 2 decodes about
35–40 frames a second at 1024×768, and anything queued past that is latency.
The Mac app keeps at most 2–3 frames in flight per client and adapts JPEG
quality to what gets through.

Put a new host in its own top-level directory (e.g. `windows/`) with its own
README, and add it to the table in the main README.

## Pull requests

- One topic per pull request.
- Say what you tested it on (devices, OS versions). "Not tested on X" is
  fine; just say so.
- Update the README when behaviour, setup steps or the protocol change.

By contributing you agree that your contribution is licensed under the MIT
license in [LICENSE](LICENSE).
