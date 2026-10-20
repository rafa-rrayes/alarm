# Lid-close block without a password prompt

Arming with "Keep awake with the lid closed" ran `pmset` through an
`osascript … with administrator privileges` prompt every time. LidLock already
installed `/etc/sudoers.d/lidlock` (NOPASSWD for exactly
`pmset -a disablesleep 0|1`), so use that, and leave the prompt as a fallback.

- [x] `SleepBlocker`: if lid sleep is already disabled (e.g. by LidLock), do nothing and restore nothing
- [x] `SleepBlocker`: try `sudo -n pmset -a disablesleep 1` + a user-level watcher that restores via `sudo -n`; fall back to the admin prompt only if that fails
- [x] `ContentView` caption, README
- [x] Self-test reuses `SleepBlocker.isLidSleepDisabled()`
- [x] Verify: `./build.sh`, `./selftest.sh`, real sudo path end to end

## Review

**What changed**

- `SleepBlocker.blockLidSleep` first checks `pmset -g`. If lid sleep is
  already off, it does nothing, so it no longer turns lid sleep back on after
  the alarm. That used to silently undo LidLock, and it explains the
  `SleepDisabled=1` self-test failure in the previous entry.
- Otherwise it runs `sudo -n pmset -a disablesleep 1` and detaches a user-level
  watcher that restores with `sudo -n … 0`. The osascript admin prompt only
  runs if `sudo -n` is refused, meaning the rule isn't there. The watcher loop,
  the lockfile and the deadline are unchanged.
- Process plumbing is now one `execute` helper used by pmset, sudo and osascript.
- Panel caption and README describe the no-prompt path.
- Self-test: the hard-coded "disablesleep is off" check became "unchanged by the
  lockfile test". There's a new real round trip from both starting states that
  only runs when `sudo -n -l` confirms it can't prompt.

**Verified**

- `./build.sh` is clean and `./selftest.sh` passes every check. The round trip
  ran both ways: from on, blocked, then the watcher restored it within 3s; from
  off, blocked, then it was left off. LidLock's original setting was put back.
- Installed to `/Applications` and relaunched. Settings came through.

**Not covered**: a real arm from the panel. `AlarmController` didn't change,
and the self-test drives the same `SleepBlocker` the app uses.

**Worth knowing**: the sudo-path watcher runs as you, not as root. It survives
the app crashing or being `pkill`ed, but not a logout mid-alarm. In that case
lid sleep stays off until the next time you arm and disarm, or until you flip
LidLock.

---

# Folder mode: a new random song when one ends

Until now a folder alarm picked one song at arm time and looped it for the whole
block. Now, when that song ends, a different random song from the folder starts.
A single file or a YouTube track still loops.

- [x] `AudioEngine`: scan the folder once at arm time and keep the shuffled order. When a song finishes, pop the next song that opens; broken files are dropped, the order is reshuffled when it runs out, and if nothing opens the last song loops
- [x] `AlarmController`: `trackName` follows the song that's playing
- [x] `ContentView` caption, README
- [x] Self-test: a folder plays several songs in a row with no immediate repeat, and a single file still loops
- [x] Verify: `./build.sh`, `./selftest.sh`

## Review

**What changed**

- `AudioEngine` scans the folder once at arm time and keeps a shuffled order.
  A folder song plays once (`numberOfLoops = 0`). When it ends, the delegate
  starts the next song in the order that opens. Files that won't open are
  dropped, and the order is reshuffled when it runs out, with the song that
  just played moved to the back. If nothing opens, for example because the
  drive was unplugged, the last song loops. A single file or a YouTube track
  still loops as before.
- A finish callback that arrives after `stop()` is ignored: it's matched to the
  current player by identity on the main actor.
- `AlarmController` updates `trackName` whenever the song changes, so the ♪
  caption follows the song that's playing.

**Verified**

- `./build.sh` builds cleanly.
- `./selftest.sh`: every check passes except one. New checks: a folder played
  8 songs in 1.5 s with no immediate repeats; a single file stays on one track
  and keeps playing.
- The one failure is `pmset disablesleep is off`. `SleepDisabled` was already 1
  before the run: no lid watcher was running, the app wasn't armed, and the
  test can only turn sleep back on. So it isn't from this change.
- Installed to `/Applications` (the app wasn't armed) and relaunched. Settings
  came through unchanged.

**Not covered**: a real firing with the actual music folder.

**Worth knowing**: `testLidLockfile` deletes the real
`~/Library/Caches/Alarm/lidblock.lock`. If the self-test runs while the app is
armed with the lid-close block on, that turns lid sleep back on.

---

# Repeat days, folder shuffle, "in X" timer

Plan: `~/.claude/plans/dazzling-stargazing-alpaca.md`

- [x] `AlarmSettings` — schedule mode, repeat days, countdown, folder bookmark, scheduling
- [x] `AudioEngine` — folder source, random pick, playability check at arm time
- [x] `AlarmController` — `fireDate(from:)`, re-arm after a repeating alarm, `trackName`
- [x] `ContentView` — At/In picker, countdown editor, weekday row, folder picker
- [x] `AlarmApp` / `Format` — weekday in the menu bar, days in relative times
- [x] Self-test — scheduling, persistence, folder scan
- [x] README
- [x] Verify: build, selftest, drive the real app
- [ ] One real (quiet) firing — skipped at your call, see below

## Review

**What changed**

- `AlarmSettings`: `mode` (At/In), `repeatDays`, `countdownMinutes`, and a
  folder bookmark alongside the file one. `fireDate(from:)` is now the single
  scheduling entry point; with repeat days, `nextFireDate` takes the soonest
  `nextDate(matching: weekday+time)` across the chosen days.
- `AudioEngine`: `.folder` source. It scans recursively, skipping hidden files
  and packages, shuffles, moves the previous pick to the back, and returns the
  first file `AVAudioPlayer` can actually open, so a broken file fails at arm time
  and not at fire time.
- `AlarmController`: `finish()` (completed or escaped) re-arms when
  `settings.repeats`; `disarm()` doesn't. `trackName` exposes the pick.
- UI: At/In segmented picker, an h/m countdown editor with presets, a weekday
  capsule row with a summary, a folder picker with the "♪ track" caption, an idle
  status line previewing the next ring, and the weekday in the armed header and
  menu bar when the alarm isn't today.

**Bug caught by the self-test**: under `@Observable`, assigning a property
inside its own `didSet` *does* re-enter it (unlike a plain stored property), so
the countdown clamp overflowed the stack. It now writes back only when the value
changes.

**Verified**

- `./build.sh` is clean; `./selftest.sh` passes all 42 checks. New checks: repeat days
  (later this week, today's slot passed → +7d, soonest of several), in-X offset,
  in-X never repeats, clamp, persistence, folder scan (recursion, hidden and
  non-audio skipped), 8 picks all valid with no back-to-back repeat, and
  unplayable-only and vanished folder errors.
- Real app, driven through accessibility:
  - The panel renders all new controls.
  - Four previews picked three / two / one / three, including the subfolder file.
  - In 1m armed at now+1m with the track shown.
  - Disarm works.
  - At mode shows the "Mon, Wed, Fri" summary and "next: tomorrow 11:00".
  - Toggling Sunday flips it to today and persists `(1,2,4,6)`.

**Not covered**: a live firing, which you asked me to skip since you were using
the Mac. So the re-arm after a ring is verified by review and the scheduling
tests, but not seen end to end. The menu bar label couldn't be screenshotted,
because the menu bar was hidden behind a full-screen video.

**Cleanup**: settings restored to exactly the pre-test snapshot, the app left
quit as it was, `SleepDisabled = 0`, volume untouched.

---

# Menu bar app

Turn Alarm from a windowed app into a menu bar app. Plan:
`~/.claude/plans/bubbly-discovering-barto.md`

- [x] `Resources/Info.plist` — `LSUIElement` = true
- [x] `Sources/AlarmApp.swift` — `MenuBarExtra` scene + state-driven status label
- [x] `Sources/AlarmApp.swift` — trim the delegate (policy, reopen), activate before the quit alert
- [x] `Sources/ContentView.swift` — panel hugs its content, Quit button, activate before the open panel
- [x] `README.md` — menu bar instead of Dock
- [x] Verify: `./build.sh`, `./selftest.sh`, launch and drive the real app

## Review

The scene is now a `MenuBarExtra(.window)` hosting the same `ContentView`, so the
UI itself barely changed — the work was in the shell around it.

**What changed and why**

- The `Window` scene became `MenuBarExtra` in `.window` style, plus a small
  `StatusLabel` that maps the controller's phase to what the menu bar shows:
  outline alarm when idle, filled alarm + the fire time when armed, waves while
  sounding. It reads only `phase` and `fireDate`, never the per-second
  countdown, so the item doesn't twitch for the hours an alarm is pending.
- `LSUIElement` removes the Dock icon, which also removes the app menu — so
  **Quit** moved into the panel footer, carrying ⌘Q. It goes through
  `NSApp.terminate`, so the armed-quit confirmation still fires.
- The `ScrollView` and `minHeight: 520` were there to make a resizable window
  behave. A menu bar panel can't be resized and sizes to its content, so both
  went; the panel is now tight when there's no banner and grows when there is.
- `NSOpenPanel` and the quit alert now `NSApp.activate` first. An agent app
  isn't frontmost when you click its menu bar item, and without this the file
  picker and the confirmation open *behind* whatever is.

**Verified on the real app, not just compiled**

Built, signed, installed to `/Applications`, and driven through the
accessibility API with synthetic HID-level clicks and keystrokes:

- menu bar item present, `background only = true` (no Dock icon)
- panel opens and renders; all controls exposed
- **typing works** — clicked into the URL field and pressed a key, the character
  landed and delete restored it. This was the one real risk in the plan
  (`MenuBarExtra` panels are non-activating and text input has historically been
  flaky); it's now settled rather than assumed
- arm → menu bar reads `16:36`; disarm → back to the plain icon
- armed panel correctly disables every control and shows Disarm
- `./selftest.sh` passes — the non-UI modules were untouched
- afterwards: no leaked power assertions, `SleepDisabled = 0`, settings intact

**Not covered**: a real firing, which would blast audio and freeze input for the
full block duration. The phase transition into `firing` is unchanged code, but
the `alarm.waves` menu bar branch has only been reasoned about, not seen.

**Note**: while driving the UI, two settings got clobbered by stray synthetic
keystrokes (`showOverlay`, `escapeHold`) and the YouTube URL was overwritten
with a stray character. All three were restored to their original values, which
the pre-change screenshots confirm: 16:36, 30 seconds, 100%, cover the screen
on, stop early on with a 5s hold, lid-sleep off, default URL.
