<p align="center">
  <img src="assets/logo.svg" width="160" alt="SlideDial logo">
</p>

<h1 align="center">SlideDial</h1>

<p align="center">
  Turn a Bluetooth dial into a per-app control surface for your Mac.<br>
  Slides, video seeking, smooth scrolling, and music, all from one knob.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS-black" alt="platform: macOS">
  <img src="https://img.shields.io/badge/language-Swift-orange" alt="language: Swift">
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="license: MIT">
</p>

---

SlideDial was built for the **CMF Buds Pro 2**: the charging case has a lovely Smart Dial that, on a Mac, does nothing more than change the volume. SlideDial captures the dial's rotation and presses and routes them to whatever you are actually doing. Any Bluetooth device that sends absolute volume and media-key commands should work the same way.

## What the dial does

Behavior follows the frontmost app, no mode switching:

| Frontmost app | Rotate | Press 1x | Press 2x / 3x |
|---|---|---|---|
| Keynote / PowerPoint | next / previous slide | next slide | previous slide |
| Browser, fullscreen page (presenting slides) | next / previous slide | next slide | previous slide |
| Chrome, tab with a video | seek forward / back | play / pause | seek back |
| Browser, normal page | smooth scroll | next slide | previous slide |
| Everything else | smooth scroll | play/pause Spotify or Music | next / previous track |

Details worth knowing:

- **Video seeking is fine-grained.** In Chrome the seek adjusts the page's `<video>` element directly, so a detent moves exactly `--step` seconds (default 5). Fast rotation coalesces into one smooth jump.
- **Fullscreen means presenting.** A fullscreen page always navigates as slides, even when a slide embeds a video. To control a video with the dial, watch it in a normal window.
- **Scrolling is smooth.** Detents feed a pixel budget that drains with an ease-out curve at 120Hz, posted as trackpad-style events under your pointer.
- **Music keeps working.** In apps that are not a slide context, presses forward to Spotify or Music, so the dial stays a media remote while you work.

## Install

```sh
git clone https://github.com/surajshetty3416/slidedial.git
cd slidedial
make
./slidedial
```

`make install` copies the binary to `/usr/local/bin`.

## Setup

1. **Accessibility.** SlideDial posts keyboard and scroll events, which requires Accessibility for the terminal you launch it from (System Settings > Privacy & Security > Accessibility). The first launch prompts for it.
2. **Automation, Chrome only.** Fine video seeking runs JavaScript in the active tab through Apple Events. macOS asks once for permission to control Chrome.
3. **Chrome JavaScript toggle, once per profile.** In Chrome, enable View > Developer > Allow JavaScript from Apple Events. This setting is per profile, so enable it in the window you actually watch videos in. Without it SlideDial falls back to YouTube's `j`/`l` keys and retries every 15 seconds.

Bud settings: the defaults in the Nothing X app work as is (press for play/pause, double press for next track, triple press for previous track). SlideDial reinterprets those signals per app.

## Usage

```
slidedial [options] [extra-allowed-bundle-ids]
  --step N    seconds per video-seek detent (default 5)
  --any-app   send slide keys to any frontmost app
  --test      post one right-arrow 2s after launch to verify key delivery
```

A ⏭ icon appears in the menu bar with two controls:

- **Re-pin volume (5s window).** Rotation is captured by pinning the output volume, which means the dial cannot change loudness while SlideDial runs. Click this, adjust the volume within 5 seconds, and it re-pins at the new level.
- **Quit SlideDial.** Restores normal dial behavior.

SlideDial logs every gesture it handles to stdout, which makes it easy to see exactly how a gesture was routed:

```
[19:24:28] rotate cw -> scroll down (Code)
[00:09:29] rotate cw -> next slide (Google Chrome)
[15:17:55] rotate -> seek +5s (Chrome video)
```

Run it detached if you prefer: `nohup slidedial > /tmp/slidedial.log 2>&1 &`

## How it works

macOS never exposes Bluetooth media buttons as keyboard events. They travel as AVRCP commands to the system's current "now playing" app, invisible to key remappers. SlideDial therefore plays a silent audio stream and registers itself as the now-playing app, which routes every dial press to it as a media command. It re-asserts that claim every few seconds because video playback in a browser tries to take it.

Rotation is trickier: the dial only sends absolute volume changes. SlideDial pins the output volume at a baseline, listens for changes with CoreAudio, treats each delta as a detent, and instantly resets the volume. The result is a free-spinning input knob.

Chrome control (seek, play/pause, fullscreen detection) runs as JavaScript in the active tab via Apple Events. The page's state (video, fullscreen slides, or plain page) is cached for a sliding 5 seconds so scrolling never waits on a script round trip.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `ignored, frontmost app is ...` in the log | That app is not in the allowed list. Pass its bundle id as an argument or use `--any-app`. |
| `Chrome JS unavailable, retrying in 15s` | The Allow JavaScript from Apple Events toggle is off in that window's profile. It is per profile. |
| Keys never arrive anywhere | Accessibility permission is missing for your terminal. The log says so at launch. |
| Old behavior after rebuilding | An earlier instance is still running: `pkill -x slidedial` and relaunch. |
| Volume seems stuck | That is the pin. Use Re-pin volume in the menu bar. |

## Limitations

- macOS only, and fine video seeking is Chrome only (other browsers fall back to scroll and arrow keys).
- Scroll events land under the mouse pointer, exactly like a physical wheel.
- While running, the dial cannot change volume and SlideDial holds the now-playing slot, so media keys route through it.

## License

[MIT](LICENSE)
