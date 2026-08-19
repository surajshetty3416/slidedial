// SlideDial: turns CMF Buds Pro 2 dial gestures into keyboard and media control.
// Owns now-playing so dial presses arrive as media commands, and pins the
// output volume so rotation arrives as volume deltas. Behavior is per frontmost app:
// Rotation: Keynote/PowerPoint = slide nav; Chrome = video seek via Apple
//   Events JS, smooth scroll when the tab has no <video>; elsewhere = smooth
//   scroll under the pointer.
// Press: slide apps and browsers = next slide (1x) / previous slide (2x, 3x);
//   Chrome with a video = play/pause (1x) / seek back (2x, 3x);
//   other apps = forwarded to Spotify or Music.
// Volume stays pinned at the launch level; re-pin from the menu bar item.
//
// build: swiftc -O -o slidedial slidedial.swift
// run:   ./slidedial
//        ./slidedial --step 10   seconds per seek detent (default 5)
//        ./slidedial --any-app   arrow keys go to any frontmost app
//        ./slidedial com.brave.Browser   allow extra bundle ids
//        ./slidedial --test      post one right-arrow 2s after launch to verify setup

import AppKit
import ApplicationServices
import AVFoundation
import CoreAudio
import MediaPlayer

let presentationApps = ["com.apple.iWork.Keynote", "com.microsoft.Powerpoint"]
let browserApps = [
    "com.apple.Safari",
    "com.google.Chrome",
    "company.thebrowser.Browser",
    "company.thebrowser.dia",
    "org.mozilla.firefox",
    "app.zen-browser.zen",
]
let version = "1.0.0"
var allowedApps = presentationApps + browserApps
var gateOnApp = true
var testMode = false
var seekStep = 5.0

var argIter = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIter.next() {
    switch arg {
    case "--help", "-h":
        print("""
        SlideDial \(version): turn a Bluetooth dial into a per-app control surface for your Mac.

        usage: slidedial [options] [extra-allowed-bundle-ids]
          --step N    seconds per video-seek detent (default 5)
          --any-app   send slide keys to any frontmost app
          --test      post one right-arrow 2s after launch to verify key delivery
          --version   print the version
          --help      show this help
        """)
        exit(0)
    case "--version":
        print("slidedial \(version)")
        exit(0)
    case "--any-app": gateOnApp = false
    case "--test": testMode = true
    case "--seek": fputs("note: modes are merged, --seek is the default behavior now\n", stderr)
    case "--step":
        guard let raw = argIter.next(), let value = Double(raw), value > 0 else {
            fputs("--step needs a positive number of seconds\n", stderr)
            exit(1)
        }
        seekStep = value
    case let flag where flag.hasPrefix("--"):
        fputs("unknown flag \(flag), see --help\n", stderr)
        exit(1)
    default: allowedApps.append(arg)
    }
}

let timeFormat: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

func log(_ msg: String) {
    print("[\(timeFormat.string(from: Date()))] \(msg)")
    fflush(stdout)
}

let keyLeft: CGKeyCode = 123
let keyRight: CGKeyCode = 124
let keyJ: CGKeyCode = 38
let keyL: CGKeyCode = 37

func frontmost() -> (name: String, bundle: String, allowed: Bool) {
    guard let app = NSWorkspace.shared.frontmostApplication else { return ("?", "", !gateOnApp) }
    let bundle = app.bundleIdentifier ?? ""
    let allowed = !gateOnApp || allowedApps.contains(bundle)
    return (app.localizedName ?? bundle, bundle, allowed)
}

func frontWindowFullscreen() -> Bool {
    guard let app = NSWorkspace.shared.frontmostApplication else { return false }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var winRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
          let win = winRef else { return false }
    let window = win as! AXUIElement
    var fsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fsRef) == .success else { return false }
    return (fsRef as? Bool) ?? false
}

func press(_ key: CGKeyCode, flags: CGEventFlags = [], gesture: String, action: String) {
    let (name, _, allowed) = frontmost()
    guard allowed else {
        log("\(gesture): ignored, frontmost app is \(name)")
        return
    }
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
    let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
    log("\(gesture) -> \(action) (\(name))")
}

// Chrome control runs as Apple Events JavaScript; per-profile toggle required
// (View > Developer > Allow JavaScript from Apple Events).
var jsRetryAfter = Date.distantPast

func runChromeJS(_ js: String, done: @escaping (String) -> Void) {
    let osa = Process()
    osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    osa.arguments = ["-e", "tell application \"Google Chrome\" to execute active tab of front window javascript \"\(js)\""]
    let out = Pipe()
    let err = Pipe()
    osa.standardOutput = out
    osa.standardError = err
    osa.terminationHandler = { _ in
        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        DispatchQueue.main.async { done(output.isEmpty && !errText.isEmpty ? "error: \(errText)" : output) }
    }
    do {
        try osa.run()
    } catch {
        DispatchQueue.main.async { done("error: \(error)") }
    }
}

// Fullscreen pages navigate as slides even if a slide embeds a video; only a
// video dominating the viewport (fullscreen player) keeps video controls.
func chromeGestureJS(action: String) -> String {
    "(function(){var fs=document.fullscreenElement;var v=document.querySelector('video');"
        + "var dom=false;if(v){var r=v.getBoundingClientRect();dom=r.width*r.height>=innerWidth*innerHeight*0.6};"
        + "if(fs&&!(v&&dom)){return 'fs'};if(!v){return 'novid'};"
        + action
        + "return 'ok'})()"
}

func markChromeJSBroken(_ detail: String) {
    jsRetryAfter = Date().addingTimeInterval(15)
    log("Chrome JS unavailable, retrying in 15s. In that window click View > Developer > Allow JavaScript from Apple Events. (\(detail))")
}

// Cache whether the active Chrome tab has a video so rotation can scroll
// pages without paying osascript latency on every detent.
enum ChromePage { case video, page, slides }
var chromePage = ChromePage.page
var chromePageExpiry = Date.distantPast

func cacheChromePage(_ kind: ChromePage) {
    chromePage = kind
    chromePageExpiry = Date().addingTimeInterval(5)
}

// Smooth scroll: detents feed a pixel budget that a 120Hz timer drains with
// ease-out, posted as continuous (trackpad-style) events under the pointer.
let scrollPixelsPerDetent = 240.0
var scrollRemaining = 0.0
var scrollTimer: Timer?

func scrollTick() {
    if abs(scrollRemaining) < 1 {
        scrollRemaining = 0
        scrollTimer?.invalidate()
        scrollTimer = nil
        return
    }
    var step = scrollRemaining * 0.22
    if abs(step) < 1 { step = step < 0 ? -1 : 1 }
    scrollRemaining -= step
    let src = CGEventSource(stateID: .hidSystemState)
    let ev = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1,
                     wheel1: Int32(step.rounded()), wheel2: 0, wheel3: 0)
    ev?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    ev?.post(tap: .cghidEventTap)
}

func startScrollTimer() {
    guard scrollTimer == nil else { return }
    let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in scrollTick() }
    RunLoop.main.add(timer, forMode: .common)
    scrollTimer = timer
}

func scroll(down: Bool, appName: String) {
    scrollRemaining += down ? -scrollPixelsPerDetent : scrollPixelsPerDetent
    startScrollTimer()
    log("rotate \(down ? "cw" : "ccw") -> scroll \(down ? "down" : "up") (\(appName))")
}

func rotateArrow(forward: Bool) {
    press(forward ? keyRight : keyLeft,
          gesture: forward ? "rotate cw" : "rotate ccw",
          action: forward ? "next slide" : "previous slide")
}

func pageGesture(forward: Bool, appName: String) {
    if frontWindowFullscreen() {
        rotateArrow(forward: forward)
    } else {
        scroll(down: forward, appName: appName)
    }
}

// Video seek: coalesces detents that land while an osascript call is in flight.
var pendingSeek = 0.0
var seekInFlight = false

func drainSeek() {
    guard !seekInFlight, pendingSeek != 0 else { return }
    let delta = pendingSeek
    pendingSeek = 0
    seekInFlight = true
    let js = chromeGestureJS(action: "v.currentTime=Math.max(0,v.currentTime+(\(delta)));")
    runChromeJS(js) { result in
        seekInFlight = false
        switch result {
        case "ok":
            cacheChromePage(.video)
            log(String(format: "rotate -> seek %+.0fs (Chrome video)", delta))
        case "fs":
            cacheChromePage(.slides)
            let detents = max(1, Int((abs(delta) / seekStep).rounded()))
            for _ in 0..<detents { rotateArrow(forward: delta > 0) }
        case "novid":
            cacheChromePage(.page)
            if frontWindowFullscreen() {
                rotateArrow(forward: delta > 0)
            } else {
                scrollRemaining -= delta / seekStep * scrollPixelsPerDetent
                startScrollTimer()
                log("no video in the Chrome tab, scrolling instead")
            }
        default:
            pendingSeek = 0
            press(delta > 0 ? keyL : keyJ,
                  gesture: delta > 0 ? "rotate cw" : "rotate ccw",
                  action: "seek \(delta > 0 ? "+" : "-")10s (fallback)")
            markChromeJSBroken(result)
        }
        drainSeek()
    }
}

func rotationGesture(forward: Bool) {
    let front = frontmost()
    if presentationApps.contains(front.bundle) {
        rotateArrow(forward: forward)
        return
    }
    if front.bundle == "com.google.Chrome" && Date() >= jsRetryAfter {
        if Date() < chromePageExpiry && chromePage != .video {
            chromePageExpiry = Date().addingTimeInterval(5)
            if chromePage == .slides {
                rotateArrow(forward: forward)
            } else {
                pageGesture(forward: forward, appName: front.name)
            }
        } else {
            pendingSeek += forward ? seekStep : -seekStep
            drainSeek()
        }
        return
    }
    if browserApps.contains(front.bundle) {
        pageGesture(forward: forward, appName: front.name)
        return
    }
    scroll(down: forward, appName: front.name)
}

// Presses in non-slide apps forward to a music player, since SlideDial holds
// the now-playing slot those commands would otherwise reach.
enum MediaCommand { case playPause, nextTrack, previousTrack }

func forwardMedia(_ cmd: MediaCommand, gesture: String) {
    let players = [("com.spotify.client", "Spotify"), ("com.apple.Music", "Music")]
    let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
    guard let player = players.first(where: { running.contains($0.0) })?.1 else {
        log("\(gesture): no music player running")
        return
    }
    let verb: String
    switch cmd {
    case .playPause: verb = "playpause"
    case .nextTrack: verb = "next track"
    case .previousTrack: verb = "previous track"
    }
    let osa = Process()
    osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    osa.arguments = ["-e", "tell application \"\(player)\" to \(verb)"]
    try? osa.run()
    log("\(gesture) -> \(verb) (\(player))")
}

func dialPress(gesture: String) {
    let front = frontmost()
    if front.bundle == "com.google.Chrome" && Date() >= jsRetryAfter {
        let js = chromeGestureJS(action: "if(v.paused){v.play()}else{v.pause()};")
        runChromeJS(js) { result in
            switch result {
            case "ok":
                cacheChromePage(.video)
                log("\(gesture) -> play/pause (Chrome video)")
            case "fs", "novid":
                cacheChromePage(result == "fs" ? .slides : .page)
                press(keyRight, gesture: gesture, action: "next slide")
            default:
                press(keyRight, gesture: gesture, action: "next slide")
                markChromeJSBroken(result)
            }
        }
        return
    }
    if front.allowed {
        press(keyRight, gesture: gesture, action: "next slide")
    } else {
        forwardMedia(.playPause, gesture: gesture)
    }
}

func dialSkip(gesture: String, mediaNext: Bool) {
    let front = frontmost()
    if front.bundle == "com.google.Chrome" && Date() >= jsRetryAfter {
        let js = chromeGestureJS(action: "v.currentTime=Math.max(0,v.currentTime-(\(seekStep)));")
        runChromeJS(js) { result in
            switch result {
            case "ok":
                cacheChromePage(.video)
                log(String(format: "\(gesture) -> seek -%gs (Chrome video)", seekStep))
            case "fs", "novid":
                cacheChromePage(result == "fs" ? .slides : .page)
                press(keyLeft, gesture: gesture, action: "previous slide")
            default:
                press(keyLeft, gesture: gesture, action: "previous slide")
                markChromeJSBroken(result)
            }
        }
        return
    }
    if front.allowed {
        press(keyLeft, gesture: gesture, action: "previous slide")
    } else {
        forwardMedia(mediaNext ? .nextTrack : .previousTrack, gesture: gesture)
    }
}

// Silent audio keeps this process eligible as the now-playing target.
let engine = AVAudioEngine()
let silence = AVAudioSourceNode { _, _, _, bufferList -> OSStatus in
    for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
        memset(buffer.mData, 0, Int(buffer.mDataByteSize))
    }
    return noErr
}
engine.attach(silence)
engine.connect(silence, to: engine.mainMixerNode, format: nil)
engine.mainMixerNode.outputVolume = 0

func startEngine() {
    do { try engine.start() } catch { log("audio engine failed to start: \(error)") }
}
startEngine()

NotificationCenter.default.addObserver(
    forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
) { _ in
    log("audio route changed, restarting silent stream")
    startEngine()
}

func assertNowPlaying() {
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = [
        MPMediaItemPropertyTitle: "SlideDial",
        MPMediaItemPropertyArtist: "dial -> slides / seek / scroll",
        MPNowPlayingInfoPropertyPlaybackRate: 1.0,
    ]
    center.playbackState = .playing
}
assertNowPlaying()

// Chrome video playback steals the now-playing slot; keep taking it back.
let nowPlayingTimer = Timer(timeInterval: 5, repeats: true) { _ in assertNowPlaying() }
RunLoop.main.add(nowPlayingTimer, forMode: .common)

let remote = MPRemoteCommandCenter.shared()
remote.nextTrackCommand.addTarget { _ in
    dialSkip(gesture: "double-press (next track)", mediaNext: true)
    assertNowPlaying()
    return .success
}
remote.previousTrackCommand.addTarget { _ in
    dialSkip(gesture: "triple-press (previous track)", mediaNext: false)
    assertNowPlaying()
    return .success
}
for (command, label): (MPRemoteCommand, String) in [
    (remote.togglePlayPauseCommand, "press (toggle)"),
    (remote.playCommand, "press (play)"),
    (remote.pauseCommand, "press (pause)"),
] {
    command.addTarget { _ in
        dialPress(gesture: label)
        assertNowPlaying()
        return .success
    }
}

// Rotation capture: pin the output volume and treat deltas as detents.
let volumeSelector = AudioObjectPropertySelector(0x766D7663) // 'vmvc' virtual main volume
func volumeAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: volumeSelector,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
}

func defaultOutputDevice() -> AudioDeviceID? {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
    return status == noErr && deviceID != 0 ? deviceID : nil
}

func readVolume(_ dev: AudioDeviceID) -> Float32? {
    var vol = Float32(0)
    var size = UInt32(MemoryLayout<Float32>.size)
    var addr = volumeAddress()
    return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &vol) == noErr ? vol : nil
}

func setVolume(_ dev: AudioDeviceID, _ value: Float32) {
    var vol = value
    var addr = volumeAddress()
    AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
}

var seekDevice: AudioDeviceID = 0
var pinnedVolume: Float32 = 0.5
var volumePaused = false

let volumeChanged: AudioObjectPropertyListenerBlock = { _, _ in
    guard seekDevice != 0, let v = readVolume(seekDevice) else { return }
    if volumePaused {
        pinnedVolume = v
        return
    }
    let delta = v - pinnedVolume
    if abs(delta) < 0.015 {
        pinnedVolume = v
        return
    }
    setVolume(seekDevice, pinnedVolume)
    rotationGesture(forward: delta > 0)
}

func attachVolumeListener() {
    var addr = volumeAddress()
    if seekDevice != 0 {
        AudioObjectRemovePropertyListenerBlock(seekDevice, &addr, DispatchQueue.main, volumeChanged)
        seekDevice = 0
    }
    guard let dev = defaultOutputDevice() else {
        log("no default output device found")
        return
    }
    seekDevice = dev
    pinnedVolume = readVolume(dev) ?? 0.5
    AudioObjectAddPropertyListenerBlock(dev, &addr, DispatchQueue.main, volumeChanged)
    log("listening volume pinned at \(Int(pinnedVolume * 100))%")
}

var defaultDeviceAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)

attachVolumeListener()
AudioObjectAddPropertyListenerBlock(
    AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddr, DispatchQueue.main
) { _, _ in
    log("output device changed, re-pinning volume")
    attachVolumeListener()
}

let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
log(trusted
    ? "accessibility: ok"
    : "accessibility: NOT granted. Grant it in System Settings > Privacy & Security > Accessibility, then relaunch")

class MenuActions: NSObject {
    @objc func repin(_ sender: Any?) {
        volumePaused = true
        log("volume capture paused for 5s, adjust volume now")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            volumePaused = false
            log("volume re-pinned at \(Int(pinnedVolume * 100))%")
        }
    }
}
let menuActions = MenuActions()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
statusItem.button?.title = "⏭"
let menu = NSMenu()
menu.autoenablesItems = false
let info = NSMenuItem(title: "SlideDial: dial -> slides / seek / scroll", action: nil, keyEquivalent: "")
info.isEnabled = false
menu.addItem(info)
let repinItem = NSMenuItem(title: "Re-pin volume (5s window)", action: #selector(MenuActions.repin(_:)), keyEquivalent: "")
repinItem.target = menuActions
menu.addItem(repinItem)
menu.addItem(NSMenuItem.separator())
menu.addItem(NSMenuItem(title: "Quit SlideDial", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
statusItem.menu = menu

log("SlideDial running")
log(String(format: "rotate: slide nav in Keynote/PowerPoint, video seek +/-%gs in Chrome, smooth scroll elsewhere", seekStep))
log("press: 1x next slide or video play/pause, 2x/3x previous slide or seek back; forwarded to Spotify/Music in other apps")

if testMode {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        press(keyRight, gesture: "self-test", action: "right arrow")
    }
}

app.run()
