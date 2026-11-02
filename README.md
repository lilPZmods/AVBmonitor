# AVB Manager for macOS

Keeps the AVB audio streams between a Mac and other AVB devices (consoles, interfaces, other Macs) connected, lets an admin **lock** routes on a shared AVB network, and walks the admin through recovery when the Mac's audio engine gets stuck.

Built for a studio where a Mac running Pro Tools sends to and returns from a PreSonus StudioLive console through a MOTU AVB switch, with other users on the same switch. It uses only standard IEEE 1722.1 (AVDECC) commands, so it should work with other AVB gear.

## Why

macOS's built-in AVB support often loses two-way audio and doesn't recover. Three failure modes showed up again and again:

1. **The reconnect gives up.** After a link or clock blip, macOS reconnects a fraction of a second before the other device is ready. Every attempt fails and it never retries.
2. **Stale streams.** The Mac's streams restart with new IDs while the console keeps listening for the old ones. Everything reports "connected", but no audio passes.
3. **The audio engine dies.** The Mac stops sending AVB audio entirely. Only restarting `coreaudiod` fixes it.

## What it does

- **Watches every locked route every 5 seconds.** It checks that the route is connected, comes from the right source, uses the stream ID the sender is actually sending, and that the receiver's packet counter is going up.
- **Heals automatically.** Dropped, stale or stalled routes are reconnected after a 10-second grace period, which avoids fighting macOS's own reconnect. Each repair is re-verified.
- **Locks routes.** If anyone on the network unpatches or re-patches a locked input, the change is logged with the controller that made it ("changed by Studio B Mac") and reverted within about a second.
- **Admin-approved recovery** when the Mac's engine stops sending:
  1. You quit your DAW yourself. **The engine is never restarted while it's open, and the manager never quits it for you.**
  2. You approve, and the manager restarts the audio engine.
  3. It reconnects and verifies every route, then runs an optional loop test (a tone out on one channel, checked on the return).
  4. It reopens your session.
- **Alerts** come from the menu-bar app, so they only appear while it's running. Quit it and the background manager keeps protecting routes silently. Clicking an alert opens the app's panel.
- **DAW engine check.** It warns if Pro Tools isn't using the expected audio device, for example when it has fallen back from your aggregate device to the bare AVB device.

## Pieces

| Part | What it is |
|---|---|
| `Sources/` | The background manager (`avbwatch`). Runs as a LaunchAgent, serves a JSON API and web page on port 8077 |
| `App/` | **AVB Manager.app**, a menu-bar app for the admin: status icon, routing window, lock/unlock, recovery approval |
| Web page | `http://<mac>.local:8077/` for other users: view routing, patch unlocked inputs. Admin actions need a password |
| `avbprobe.swift` | Measures AVB input levels and can play a test tone on one channel (used for the loop test) |
| `pthelper.py` | Reads the open Pro Tools session and saves it, through Pro Tools' scripting interface (PTSL) |
| `setup-recovery.sh` | One-time sudoers rule that allows exactly `killall coreaudiod` without a password, so recovery can restart the engine |

## Requirements

- macOS 13 or later on Apple silicon, with AVB enabled for the Ethernet port in Audio MIDI Setup (Network Device Browser)
- Read access to `/dev/bpf*` (the `access_bpf` group, set up by Wireshark's ChmodBPF or similar). It's only used to see *who* changed a route. Everything else works without it.

## Install

Download `AVBManager-macos-arm64.pkg` from the latest GitHub release, then open it and follow the installer. Because this package is unsigned, macOS may block the first open; Control-click the package, choose **Open**, and confirm. The package includes the compiled menu-bar app, background manager, AVB probe, and Pro Tools helper; no Xcode, Python, or terminal commands are needed. The installer asks for your macOS administrator password to install the app, start its login services, and enable the recovery action that can restart only `coreaudiod` after an admin approves recovery.

Open `http://localhost:8077/` on the AVB Manager Mac to set the initial admin password. Then lock your working routes: open the menu-bar app, go to **Routing…**, and click **Lock all current routes** while audio works in both directions.

When a production is done, click **Release network** in the menu-bar app (or on the web page as admin). Your locked routes stay saved but are no longer enforced, so anyone can patch anything, and nothing is disconnected. Click **Lock my routes** to take the network back: the saved routes are restored right away. Patching this Mac's own AVB streams still needs the admin, even when released.

## Configuration

`~/Library/Application Support/AVBWatch/config.json`:

| Key | Default | Meaning |
|---|---|---|
| `interface` | `en0` | Ethernet port AVB runs on |
| `pollSeconds` | `5` | how often to check |
| `graceChecks` | `2` | failed checks before healing |
| `webPort` | `8077` | web page / API port |
| `daw` | `Pro Tools` | DAW process the recovery rule applies to (`""` to disable) |
| `expectedAudioDevice` | `Pro Tools Aggregate I/O` | device the DAW should be running on |
| `loopTestChannel` | `30` | channel used for the recovery loop test (`0` = off) |

The log is in `~/Library/Logs/AVBWatch.log`.

## Notes

- Avoid re-patching the Mac's own AVB streams while a DAW is using them. Adding a stream to the Mac mid-session can stop its audio engine. The web page only lets the admin change the Mac's own streams.
- The web page uses plain HTTP and is meant for a trusted studio network.

## Uninstall

Remove **AVB Manager.app** from Applications and delete `~/Library/Application Support/AVBWatch` and `~/Library/LaunchAgents/ca.arraymusic.avbwatch*.plist`. To remove the optional recovery permission, an administrator can delete `/etc/sudoers.d/avbwatch`.

## License

Copyright (c) 2026 Big Dumb Robot. All rights reserved. The source is published for viewing only; no use, copying, modification or distribution is permitted without written permission. See [LICENSE](LICENSE).
