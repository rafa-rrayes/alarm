# Alarm

A wake-up alarm for macOS that you can't just swat away. At the set time it
blasts your audio at full volume and swallows every keyboard and trackpad event
for a few minutes, so silencing it means actually getting up.

It lives in the menu bar — no Dock icon, no window to keep track of. Native
SwiftUI app, no root, no Xcode project. `main.py` is the original CLI this grew
out of and still works if you want it.

## Install

```sh
./build.sh                  # builds and signs build/Alarm.app
cp -R build/Alarm.app /Applications/
open /Applications/Alarm.app
```

An alarm clock appears in the menu bar; click it for everything below.

Building needs the Xcode command line tools and takes a few seconds. Running it
straight out of `build/` works too — `/Applications` is just the tidy home.

### Grant Accessibility (required, once)

Blocking input needs the Accessibility permission. The app shows a banner with a
**Grant…** button until you do:

**System Settings › Privacy & Security › Accessibility** → enable **Alarm**.

The **Arm alarm** button stays disabled until the grant is in place. Because the
app is signed with a stable Developer ID, the grant survives rebuilds — you only
do this once, even if you keep hacking on the source.

> If you move the app after granting (e.g. `build/` → `/Applications`), macOS
> treats it as a new location. Install it where you want it first, then grant.

## Using it

| Control | What it does |
| --- | --- |
| At / In | **At** a clock time, or **In** a set while from when you arm (1 minute to 23h 59m, with 5m–2h presets) |
| Time | Fires at the next occurrence of that time — today if it's still ahead, otherwise tomorrow |
| Repeat | *At* only. Pick weekdays and the alarm re-arms itself after each ring — only **Disarm** ends the series. None picked means once |
| Sound | A local audio file or a YouTube URL (needs `brew install yt-dlp`), which loops, or a folder, which plays random songs one after another, never the same one twice running |
| Block for | How long input stays dead once it fires |
| Volume | Where system volume is pinned while it sounds; your previous level is restored after |
| Cover the screen | Blacks out every display with the time and a countdown |
| Let me stop it early | Adds a hold-⎋ escape hatch, with the hold length you choose |
| Keep awake with the lid closed | Stops a shut lid from skipping the alarm. No prompt with LidLock's sudo rule installed, otherwise asks for your admin password |

Press **Arm alarm** and leave it running. Clicking away closes the panel but
cancels nothing — the app keeps waiting, and the menu bar tells you where it
stands at a glance:

| Menu bar | Meaning |
| --- | --- |
| ⏰ outline | not armed |
| ⏰ filled, with a time | armed, rings then |
| ⏰ with waves | going off right now |

A folder's first song is picked, and checked to actually play, when the alarm
arms, so a broken or DRM-locked file is skipped then rather than discovered as
silence. When a song ends, the next random one starts; the folder is shuffled
once and played through before any song repeats. The panel shows the current
song (♪).

A repeating alarm keeps the Mac from idle-sleeping for as long as the series is
armed. Without the sudo rule, **Keep awake with the lid closed** asks for your
password again each time it re-arms. Arming doesn't survive quitting the app.

**Quit** is in the panel (⌘Q while it's open). Quitting while armed asks for
confirmation.

YouTube audio is downloaded when you arm, never at fire time, so the blocked
window is nothing but playback. Downloads are cached in `~/Library/Caches/Alarm/`.

## Getting out of it

By design there is no escape unless you asked for one. Your options:

- Turn on **Let me stop it early** before arming, then hold ⎋ for the set time.
- Wait out the **Block for** duration — the tap runs on its own thread with its
  own deadline, so it releases on schedule even if the UI hangs.
- From another machine: `ssh you@thismac 'pkill -x Alarm'`. Input comes back the
  instant the process dies.

## Verifying a build

```sh
./selftest.sh
```

Exercises the CoreAudio volume round trip, the next-occurrence rule, repeat days
and the "in X" countdown, the folder scan, random pick and song-after-song playback, settings persistence, the lid-block lockfile handshake and real `pmset` round
trip (only with the passwordless sudo rule, so it never prompts), and the event tap's start/stop and
deadline behaviour. It briefly blocks input for about a second and nudges the
volume, restoring both. Run it from a terminal that itself has Accessibility
permission, otherwise the tap checks skip.

## How it works

| File | Role |
| --- | --- |
| `Sources/AlarmApp.swift` | `MenuBarExtra` scene and the status item that mirrors the phase |
| `Sources/AlarmController.swift` | State machine: idle → arming → armed → firing, and one idempotent teardown |
| `Sources/InputBlocker.swift` | `CGEvent` tap on its own run-loop thread, with a hard deadline |
| `Sources/SystemVolume.swift` | CoreAudio volume get/set/unmute |
| `Sources/SleepBlocker.swift` | IOKit power assertions, plus the `pmset` lid path (sudo rule, else admin prompt) |
| `Sources/AudioEngine.swift` | yt-dlp prefetch, random folder shuffle, and `AVAudioPlayer` playback (looping, or song after song for a folder) |
| `Sources/OverlayWindow.swift` | Shield-level blackout window per display |
| `Sources/AlarmSettings.swift` | `UserDefaults` model and scheduling; sound file and folder kept as bookmarks |

Two details worth knowing:

**The tap tries the HID layer first, then the session layer.** HID sits below the
window server and catches everything, including media keys and trackpad gestures,
but it isn't always available with only an Accessibility grant. A session tap
suppresses keyboard, trackpad and media keys just as thoroughly for the logged-in
user, so the app falls back rather than refusing to work.

**Lid-close sleep takes no prompt, or at most one.** `pmset disablesleep` needs
root. If `/etc/sudoers.d/lidlock` (installed by LidLock) allows exactly
`pmset -a disablesleep 0` and `1` without a password, the app uses `sudo -n` and
never prompts. Without that rule, one admin prompt sets it. Either way the call
also detaches a watcher that puts the setting back as soon as the app's lockfile
disappears — or at a hard deadline, so a crash can't leave your Mac unable to
sleep. If lid sleep is already off when you arm (LidLock, say), the app leaves it
alone and doesn't turn it back on afterwards.

## Requirements

macOS 14+, Xcode command line tools, and `yt-dlp` if you want YouTube audio.
