# CouchRemote

Turn an old MacBook connected to your TV into a TV box, and your iPhone into its remote.
Netflix, Crunchyroll, YouTube and other streaming sites run in the Mac's default browser,
controlled from the iPhone with a trackpad, player controls and a keyboard.

## Structure

| Folder | Contents |
| --- | --- |
| `RemoteKit/` | Shared Swift package: protocol messages, fast UDP channel, app model, search URLs, icon lookup |
| `HostApp/` | **CouchHost** (macOS): Bonjour/WebSocket server, input injection via `CGEvent`, tvOS-style home screen |
| `RemoteApp/` | **CouchRemote** (iOS): finds the Mac via Bonjour, trackpad, player controls, keyboard, app management |
| `RemoteWidgets/` | Widget extension: the remote as a Live Activity on the lock screen and in the Dynamic Island |
| `Shared/` | Code compiled into both the app and the widget extension (Live Activity attributes, button intent) |
| `Design/` | App icons and the prompt used to generate them |
| `project.yml` | XcodeGen configuration that generates the Xcode project |

```
iPhone (CouchRemote) ──WebSocket/JSON──▶ Mac (CouchHost) ──CGEvent──▶ Browser (Netflix, Crunchyroll, …)
        │  ▲                                  ▲
        │  └──────── Bonjour _couchremote._tcp
        └────── UDP (trackpad, signed) ───────┘
```

## Getting started

```bash
brew install xcodegen
cd CouchRemote
xcodegen generate
open CouchRemote.xcodeproj
```

1. In Xcode, select your team under *Signing & Capabilities* for both targets
   (or set `DEVELOPMENT_TEAM` in `project.yml`).
2. Start **CouchHost** on the Mac. On first launch, click "Berechtigung anfragen" and allow CouchHost under
   *Privacy & Security → Accessibility*. CouchHost is signed with your development certificate, so the
   permission survives rebuilds.
3. Start **CouchRemote** on the iPhone and allow "Local Network". It connects automatically when exactly
   one Mac is found (otherwise pick one via the TV icon), then asks for the 4-digit pairing code shown
   in the CouchHost window.

Protocol tests: `cd RemoteKit && swift test`

### Build by double-click

- `run-host.command`: runs the RemoteKit tests, builds CouchHost (signed with your development
  certificate), refreshes the app icon cache and launches it
- `run-iphone.command`: builds CouchRemote, installs it on the paired iPhone and launches it
- `run-all.command`: both, one after the other
- `make-icons.command`: has Codex generate the app icons and creates the asset catalogs

## Controls

| iPhone | Mac |
| --- | --- |
| Trackpad: 1 finger drag / tap | Move pointer / click (tap twice quickly = double-click) |
| Trackpad: 2 finger drag / tap | Scroll / right-click |
| Scroll strip (right of the trackpad) | Scroll vertically with one finger |
| Rewind / fast-forward (hold = repeat) | Left / right arrow |
| Play/Pause | Space |
| Back: tap / hold | Escape / previous page (⌘[) |
| Home | Open or close the home screen |
| Fullscreen | F |
| Volume down / mute / up | Media keys (Mac volume) |
| Keyboard → "Eintippen" | Types live wherever the Mac's text cursor is (Unicode, autocorrect, dictation) |
| Keyboard → "In App suchen" | Opens the app's search page with your query |
| Power (top bar) | Turns the TV on or off over the network (see below) |

Note: with audio over HDMI, macOS often locks the system volume. Use the TV's own remote in that case.

## Lock screen remote (Live Activity)

As soon as the app is connected to a Mac, a remote appears on the lock screen and in the Dynamic Island,
so you can control the TV without unlocking the iPhone. Turn it off in the TV menu ("Auf dem Sperrbildschirm").

- Lock screen: D-pad with OK (navigates the home screen), fullscreen, home, play/pause, volume down/mute/up,
  and a power button next to the Mac name that switches the TV on (see "TV power").
- Dynamic Island (long press): the same buttons, D-pad in one row, power button next to the Mac name.
- Not available: trackpad and keyboard. Live Activities only support buttons, and text input needs an unlocked phone.
- Each button is a `LiveActivityIntent`. iOS runs it inside the app process (waking the app in the background
  if needed). If the connection fell asleep, the app checks it with a WebSocket ping and otherwise reconnects
  straight to the last Mac using its stored pairing token. Pairing itself still has to happen in the app.
- iOS ends Live Activities after at most 8 hours. Opening the app starts a new one.

## TV power

The Mac's HDMI port has no CEC, so CouchHost switches the TV over the home network instead
(Sony Bravia, see `HostApp/TVController.swift`). The power button asks the TV for its state
(`getPowerStatus`) and toggles:

- Off: `setPowerStatus`, falling back to the IR code "PowerOff" over IRCC.
- On: Wake-on-LAN magic packet to the TV's MAC address, plus `setPowerStatus` if the TV still answers
  in standby. The MAC address is learned from the ARP cache the first time the TV is reachable.

Setup:

1. On the TV, turn on *Remote Start* and allow remote devices (Settings → Network).
2. In the CouchHost window under "Fernseher", enter the TV's IP address (Settings → Network → Network
   status). A fixed address in the router avoids it changing.
3. Click "Mit Fernseher koppeln" and enter the PIN shown on the TV. Models with *IP control* can use a
   pre-shared key instead.
4. Click "Ein/Aus testen" once while the TV is on, so CouchHost learns its MAC address
   (or enter it by hand).

Older Linux-based Bravias such as the KD-49XF7005 have no Sony web API, only a DLNA renderer on
port 2870. There the button can only switch the TV on (Wake-on-LAN); while port 2870 answers,
CouchHost reports that the TV is on and can't be switched off over the network.

## Home screen

- Opens with the Home button on the screen that currently holds the mouse pointer (on the TV: the only one)
  and closes with Home again or with Escape on a real Mac keyboard.
- Background: the current desktop picture, or a custom image chosen in the CouchHost window.
- "Deine Apps": tiles for your apps. Move the pointer over a tile and tap to open it in the default browser.
  Opening an app plays a launch animation: the tile grows to fullscreen, the browser opens behind it,
  then the home screen fades out.
- Quick actions for the selected app (e.g. YouTube subscriptions/history, Crunchyroll watchlist/history,
  Netflix "My List") and in-app search.
- Apps are managed on the iPhone (grid icon): add, edit, reorder, delete, launch, and set a custom logo
  from Photos. Only http(s) URLs are accepted. The list is stored on the Mac in
  `~/Library/Application Support/CouchHost/apps.json`.
- Icons are looked up by `IconResolver`: web app manifest (up to 512 px), `apple-touch-icon` / sized
  `icon` links, `/apple-touch-icon.png`, and finally Google's favicon service for sites that block automated
  requests (only the domain name is sent). Icons smaller than 96 px are ignored.

### Search URLs

Defined in `RemoteKit/Sources/RemoteKit/KnownServices.swift`:

| Service | Search | Quick actions |
| --- | --- | --- |
| YouTube | `/results?search_query=` | Subscriptions, Watch later, History |
| Crunchyroll | `/search?q=` (not verified, Crunchyroll blocks automated checks) | Watchlist, History |
| Netflix | `/search?q=` | My List |

"Continue watching" with real progress isn't possible: these services offer no public API for it.

## Security

- New iPhones must enter the code shown in the CouchHost window (5 attempts; unpaired connections time
  out after 2 minutes). Paired devices can be removed in the CouchHost window.
- The pairing token is stored in the iPhone's keychain; the Mac only keeps a SHA-256 hash.
- The connection is unencrypted (no TLS) and meant for your home network only.

## Fast channel (UDP)

Trackpad movement, scrolling and clicks are sent over UDP instead of the WebSocket. Over TCP, a single
packet lost on Wi-Fi holds back all following movements until it is retransmitted, so the pointer
stalls and then jumps. Each UDP packet carries the last 5 inputs (redundancy) and is resent 3 times
afterwards. Packets are signed with HMAC-SHA256 (one key per connection, only for paired iPhones);
sequence numbers prevent duplicates. The iPhone only switches over after a probe packet has been
confirmed (⚡ next to the status), otherwise everything stays on the WebSocket.
See `RemoteKit/Sources/RemoteKit/FastChannel.swift`.

## Latency and smoothness

- Pointer smoothing on the Mac: incoming movements are played back at a steady 250 Hz with an
  exponential decay (time constant selectable in the CouchHost window: off, 5, 8, 14 ms). This hides
  Wi-Fi's bursty packet delivery at the cost of a few milliseconds of latency.
- The CouchHost window shows packet timing for the last movement (average, 95th percentile, max,
  gaps over 50 ms) to tell app issues from Wi-Fi issues.
- Networking and input injection on the Mac run on a dedicated high-priority queue, not the main thread.
- App Nap is disabled (`NSAppSleepDisabled` + `latencyCritical` activity).
- TCP without Nagle (`noDelay`), keepalive (dead connections dropped after ~11 s), no peer-to-peer Wi-Fi,
  "interactive voice" Wi-Fi QoS.
- UIKit touches with coalesced samples, speed-based pointer acceleration.
- The Mac tracks the pointer position with sub-pixel precision.

## Icons

Generated by Codex (`make-icons.command`, prompt in `Design/icon-prompt.md`); originals in `Design/Icons/`.
