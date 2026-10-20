"""Fully block keyboard + trackpad while blasting YouTube audio, at a set time.

Must run as root so the tap sits at the HID layer, below everything.
    sudo .venv/bin/python main.py --at 07:30 [youtube-url]
    sudo .venv/bin/python main.py --in 90m [youtube-url]
    sudo .venv/bin/python main.py [youtube-url]          # fire immediately
"""

import argparse
import atexit
import datetime
import os
import re
import shutil
import subprocess
import tempfile
import time

import Quartz

DURATION = 180
DEFAULT_URL = "https://www.youtube.com/watch?v=zAfrHPeHZeg"

# Every event type, including NSSystemDefined (volume/media/brightness keys)
# and trackpad gestures -- these are NOT key events and are missed by a
# keyboard+mouse mask.
ALL_EVENTS = Quartz.kCGEventMaskForAllEvents

TAP = None


def parse_clock_time(text):
    """'7:30', '07:30', '7:30am', '10pm' -> the next datetime matching it."""
    match = re.fullmatch(
        r"(\d{1,2})(?::(\d{2}))?\s*(am|pm)?", text.strip(), re.IGNORECASE
    )
    if not match:
        raise ValueError(f"Could not read a time from {text!r}")

    hour = int(match.group(1))
    minute = int(match.group(2) or 0)
    meridiem = (match.group(3) or "").lower()
    if meridiem:
        if not 1 <= hour <= 12:
            raise ValueError(f"Hour out of range in {text!r}")
        hour = hour % 12 + (12 if meridiem == "pm" else 0)
    if not (0 <= hour <= 23 and 0 <= minute <= 59):
        raise ValueError(f"Time out of range in {text!r}")

    now = datetime.datetime.now()
    when = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if when <= now:  # already gone today -> tomorrow
        when += datetime.timedelta(days=1)
    return when


def parse_delay(text):
    """'45s', '30m', '1h30m', '2h' -> the datetime that far from now."""
    parts = re.findall(r"(\d+)\s*([hms])", text.strip(), re.IGNORECASE)
    if not parts or re.sub(r"\d+\s*[hms]\s*", "", text.strip(), flags=re.IGNORECASE):
        raise ValueError(f"Could not read a duration from {text!r}")

    units = {"h": 3600, "m": 60, "s": 1}
    seconds = sum(int(n) * units[u.lower()] for n, u in parts)
    return datetime.datetime.now() + datetime.timedelta(seconds=seconds)


def wait_until(when):
    """Sleep until `when`, showing a live countdown."""
    print(f"Alarm set for {when:%a %H:%M:%S}. Ctrl-C to cancel.", flush=True)
    while (remaining := (when - datetime.datetime.now()).total_seconds()) > 0:
        print(f"\r  {int(remaining) // 3600:02d}:"
              f"{int(remaining) // 60 % 60:02d}:"
              f"{int(remaining) % 60:02d} to go ", end="", flush=True)
        time.sleep(min(1.0, remaining))
    print("\r" + " " * 30 + "\r", end="", flush=True)


def set_sleep_disabled(on):
    """Block/unblock clamshell (lid-close) sleep. Root only.

    Lid close is handled by power management, not the event stream, so an
    event tap cannot stop it -- this is the only lever.
    """
    subprocess.run(
        ["pmset", "-a", "disablesleep", "1" if on else "0"],
        check=False,
        capture_output=True,
    )


def get_volume():
    out = subprocess.run(
        ["osascript", "-e", "output volume of (get volume settings)"],
        capture_output=True, text=True, check=False,
    ).stdout.strip()
    return int(out) if out.isdigit() else None


def set_volume(level):
    subprocess.run(
        ["osascript", "-e",
         f"set volume output volume {level} without output muted"],
        check=False, capture_output=True,
    )


def fetch_audio(url, workdir):
    """Download the audio track up front, so the blocked window is all playback."""
    if not shutil.which("yt-dlp"):
        raise SystemExit("yt-dlp not found. Install it: brew install yt-dlp")

    out = os.path.join(workdir, "audio.m4a")
    print("Fetching audio...", flush=True)
    result = subprocess.run(
        ["yt-dlp", "-q", "--no-playlist",
         "-f", "bestaudio[ext=m4a]/bestaudio",
         "-o", out, url],
        check=False,
    )
    if result.returncode != 0 or not os.path.exists(out):
        raise SystemExit(f"Could not download audio from {url}")
    return out


def swallow(proxy, event_type, event, refcon):
    if event_type in (Quartz.kCGEventTapDisabledByTimeout,
                      Quartz.kCGEventTapDisabledByUserInput):
        Quartz.CGEventTapEnable(TAP, True)
        return event
    return None  # drop it


def parse_args():
    parser = argparse.ArgumentParser(
        description="Block keyboard + trackpad while blasting audio, at a set time."
    )
    parser.add_argument("url", nargs="?", default=DEFAULT_URL,
                        help="YouTube URL to play (default: %(default)s)")
    when = parser.add_mutually_exclusive_group()
    when.add_argument("--at", metavar="TIME",
                      help="clock time to fire at, e.g. 07:30 or 7:30am "
                           "(next occurrence)")
    when.add_argument("--in", dest="delay", metavar="DURATION",
                      help="fire after a delay, e.g. 45s, 30m, 1h30m")
    parser.add_argument("--duration", type=int, default=DURATION, metavar="SECONDS",
                        help="how long to stay blocked (default: %(default)s)")

    args = parser.parse_args()
    try:
        if args.at:
            args.when = parse_clock_time(args.at)
        elif args.delay:
            args.when = parse_delay(args.delay)
        else:
            args.when = None
    except ValueError as exc:
        parser.error(str(exc))
    if args.duration <= 0:
        parser.error("--duration must be positive")
    return args


def main():
    global TAP

    args = parse_args()
    url = args.url

    if os.geteuid() != 0:
        raise SystemExit(
            "Must run as root to block at the HID layer:\n"
            "    sudo .venv/bin/python main.py --at 07:30 [youtube-url]"
        )

    TAP = tap = Quartz.CGEventTapCreate(
        Quartz.kCGHIDEventTap,          # lowest level, before window server
        Quartz.kCGHeadInsertEventTap,   # first in line
        Quartz.kCGEventTapOptionDefault,  # not listen-only: we can suppress
        ALL_EVENTS,
        swallow,
        None,
    )
    if tap is None:
        raise SystemExit(
            "Could not create event tap. Grant Accessibility permission to your "
            "terminal (System Settings > Privacy & Security > Accessibility)."
        )

    source = Quartz.CFMachPortCreateRunLoopSource(None, tap, 0)
    loop = Quartz.CFRunLoopGetCurrent()
    Quartz.CFRunLoopAddSource(loop, source, Quartz.kCFRunLoopCommonModes)

    workdir = tempfile.mkdtemp(prefix="alarm-")
    atexit.register(shutil.rmtree, workdir, True)
    track = fetch_audio(url, workdir)

    # Both survive the process, so restore them even on a crash.
    atexit.register(set_sleep_disabled, False)
    # Held through the wait too -- a sleeping machine would never reach the alarm.
    set_sleep_disabled(True)

    if args.when is not None:
        try:
            wait_until(args.when)
        except KeyboardInterrupt:
            raise SystemExit("\nAlarm cancelled.")

    prior_volume = get_volume()
    if prior_volume is not None:
        atexit.register(set_volume, prior_volume)

    set_volume(100)
    player = subprocess.Popen(["afplay", track])
    Quartz.CGEventTapEnable(tap, True)
    try:
        print(f"Blocked for {args.duration}s...", flush=True)
        deadline = time.monotonic() + args.duration
        while (remaining := deadline - time.monotonic()) > 0:
            Quartz.CFRunLoopRunInMode(
                Quartz.kCFRunLoopDefaultMode, remaining, False
            )
    finally:
        Quartz.CGEventTapEnable(tap, False)
        Quartz.CFRunLoopRemoveSource(loop, source, Quartz.kCFRunLoopCommonModes)
        player.terminate()
        player.wait(timeout=2)
        if prior_volume is not None:
            set_volume(prior_volume)
        set_sleep_disabled(False)

    print("Unblocked.")


if __name__ == "__main__":
    main()
