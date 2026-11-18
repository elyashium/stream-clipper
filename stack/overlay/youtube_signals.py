"""Cheap "this moment landed" signals for YouTube streams.

OpenShorts ships ``twitch_signals.py``: on a Twitch VOD it asks Helix which
stretches viewers clipped and makes sure the moment picker looks at them. YouTube
has no public clips API, so this module builds the same kind of evidence from
what a YouTube stream *does* leave behind, plus two signals from the recording:

  chat      Live-chat replay of the finished stream (yt-dlp ``live_chat``).
            Messages per 5 s bucket against a rolling baseline; hype messages
            ("LMAO", "CLIP IT", 💀 😂 ...) and Super Chats count extra. A spike
            is shifted back by ``CHAT_DELAY_SECONDS``: chat reacts after the
            moment, not during it.
  heatmap   YouTube's "Most replayed" graph (yt-dlp ``heatmap``). Only exists
            once a video has enough views, so it is usually empty on launch
            night and useful a few days later.
  loudness  1 s RMS of the mic track (``MIC_AUDIO_TRACK``) against a rolling
            median. Screams, laughter and "NO WAY" are loud; a transcript ranks
            them low because they are barely words.
  markers   Chapter markers in a local OBS recording. OBS 30.2+ has an "Add
            Chapter Marker" hotkey for Hybrid MP4: the streamer presses it right
            after something good happens. Strongest signal of all.

Every signal comes out in the shape ``twitch_signals`` uses for viewer clips,
``{"start", "end", "views", "source"}`` in seconds of the file being clipped,
so ``main.get_viral_clips`` treats them exactly like Twitch viewer clips: shown
to both LLM passes and guaranteed shortlist slots (``promote_hot_windows``).
``views`` is a relative weight, not a view count.

Everything is best effort. No chat replay, no heatmap, a yt-dlp failure, a file
with no audio: the job carries on with whatever signals it did get, or none.
The parsing and peak-finding helpers are pure and unit-tested.
"""
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import threading
from typing import Dict, Iterable, List, Optional, Tuple
from urllib.parse import urlparse

YT_HOSTS = {"youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be",
            "music.youtube.com"}


def _env_float(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, "") or default)
    except ValueError:
        return default


def _env_on(name: str, default: str = "1") -> bool:
    return os.environ.get(name, default).strip().lower() not in ("0", "false", "no", "off")


CHAT_BUCKET = 5.0                                     # seconds per chat bucket
CHAT_DELAY = _env_float("CHAT_DELAY_SECONDS", 12.0)   # stream latency + typing
CHAT_TIMEOUT = _env_float("CHAT_TIMEOUT_SECONDS", 900.0)
CHAT_MIN_MSGS = _env_float("CHAT_MIN_MSGS", 4.0)      # weighted msgs in a spike bucket
LOUD_MIN_OVER_DB = _env_float("LOUD_MIN_OVER_DB", 9.0)
LOUD_FLOOR_DB = -40.0                                 # quieter than this is never a peak
MAX_SIGNALS = 40

# Chat that means "something just happened". Whole words, plus phrases and
# emoji matched as substrings.
HYPE_WORDS = {"lmao", "lmfao", "lol", "lul", "omg", "wtf", "clip", "clipit", "bro",
              "holy", "insane", "crazy", "w", "l", "dead", "nooo", "noooo", "yooo",
              "kekw", "pog", "poggers", "sheesh", "bruh"}
HYPE_PHRASES = ("no way", "clip it", "clip that", "💀", "😂", "🤣", "😭", "🔥",
                "😱", "!!!", "???", ":face-with-tears-of-joy:", ":skull:")


def is_hype(text: str) -> bool:
    low = (text or "").lower()
    if any(p in low for p in HYPE_PHRASES):
        return True
    return any(tok in HYPE_WORDS for tok in re.findall(r"[a-z]+", low))


# --------------------------------------------------------------------------- #
# Pure helpers
# --------------------------------------------------------------------------- #
def is_youtube(url) -> bool:
    try:
        host = (urlparse(str(url or "").strip()).hostname or "").lower()
    except ValueError:
        return False
    return host in YT_HOSTS


def _message_text(renderer: dict) -> str:
    parts = []
    for run in ((renderer.get("message") or {}).get("runs") or []):
        if "text" in run:
            parts.append(run["text"])
        elif "emoji" in run:
            emoji = run["emoji"]
            parts.append(emoji.get("emojiId") or "")
            parts.extend(emoji.get("shortcuts") or [])
    return " ".join(parts)


def parse_chat_line(line: str) -> Optional[Tuple[float, float]]:
    """One line of yt-dlp's ``live_chat.json`` → ``(offset_seconds, weight)``.

    Plain message 1, a hype message 2, a Super Chat / sticker 4, a membership
    event 2. Lines that carry no chat item (polls, banners) return None.
    """
    try:
        obj = json.loads(line)
    except (ValueError, TypeError):
        return None
    replay = obj.get("replayChatItemAction") or {}
    try:
        t = float(replay.get("videoOffsetTimeMsec")) / 1000.0
    except (TypeError, ValueError):
        return None
    weight = 0.0
    for action in replay.get("actions") or []:
        item = ((action.get("addChatItemAction") or {}).get("item")) or {}
        if "liveChatTextMessageRenderer" in item:
            text = _message_text(item["liveChatTextMessageRenderer"])
            weight += 2.0 if is_hype(text) else 1.0
        elif "liveChatPaidMessageRenderer" in item or "liveChatPaidStickerRenderer" in item:
            weight += 4.0
        elif "liveChatMembershipItemRenderer" in item:
            weight += 2.0
    if weight <= 0:
        return None
    return t, weight


def chat_series(lines: Iterable[str], bucket: float = CHAT_BUCKET) -> List[float]:
    """Weighted chat activity per ``bucket`` seconds, index 0 = video start."""
    counts: Dict[int, float] = {}
    for line in lines:
        parsed = parse_chat_line(line)
        if not parsed:
            continue
        t, w = parsed
        if t < 0:
            continue  # pre-stream "waiting room" chat
        i = int(t // bucket)
        counts[i] = counts.get(i, 0.0) + w
    if not counts:
        return []
    series = [0.0] * (max(counts) + 1)
    for i, w in counts.items():
        series[i] = w
    return series


def _median(xs: List[float]) -> float:
    s = sorted(xs)
    n = len(s)
    if not n:
        return 0.0
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2.0


def rolling_median(series: List[float], half_window: int, stride: int = 1) -> List[float]:
    """Median of ``series[i-half_window : i+half_window]`` for every i.

    Computed every ``stride`` points and held in between: on a 1 s loudness
    series of an 8 h stream that is the difference between 30 k sorts and 3 k.
    """
    n = len(series)
    if n == 0:
        return []
    stride = max(1, int(stride))
    out = [0.0] * n
    for c in range(0, n, stride):
        lo, hi = max(0, c - half_window), min(n, c + half_window + 1)
        m = _median(series[lo:hi])
        for i in range(c, min(n, c + stride)):
            out[i] = m
    return out


def find_peaks(series: List[float], baseline: List[float], min_over: float,
               min_gap: int, top: int, min_value: float = -math.inf) -> List[Tuple[int, float]]:
    """Indices where ``series`` beats its baseline by ``min_over`` or more.

    Greedy non-maximum suppression: take the biggest excess, drop everything
    within ``min_gap`` of it, repeat. Returns ``[(index, excess)]`` by time.
    """
    cands = [(series[i] - baseline[i], i) for i in range(len(series))
             if series[i] - baseline[i] >= min_over and series[i] >= min_value]
    cands.sort(reverse=True)
    taken: List[Tuple[int, float]] = []
    for excess, i in cands:
        if len(taken) >= top:
            break
        if all(abs(i - j) >= min_gap for j, _ in taken):
            taken.append((i, excess))
    return sorted(taken)


def chat_signals(lines: Iterable[str], delay: float = CHAT_DELAY,
                 min_msgs: float = CHAT_MIN_MSGS, top: int = 20) -> List[dict]:
    series = chat_series(lines)
    if len(series) < 6:
        return []
    base = rolling_median(series, half_window=int(300 / CHAT_BUCKET), stride=6)
    # Robust spread of the residuals, so a busy chat needs a bigger spike than
    # a quiet one to count, and a quiet one still needs ``min_msgs``.
    resid = [abs(s - b) for s, b in zip(series, base)]
    spread = max(1.0, 1.4826 * _median(resid))
    peaks = find_peaks(series, base, min_over=3.0 * spread,
                       min_gap=int(45 / CHAT_BUCKET), top=top, min_value=min_msgs)
    out = []
    for i, excess in peaks:
        moment = (i + 0.5) * CHAT_BUCKET - delay
        out.append({"start": round(max(0.0, moment - 25.0), 3),
                    "end": round(max(1.0, moment + 8.0), 3),
                    "views": int(min(500, 40 * excess / spread)),
                    "source": "chat"})
    return out


def heatmap_signals(heatmap, top: int = 8, min_value: float = 0.55) -> List[dict]:
    """YouTube "Most replayed" segments above ``min_value`` (0-1, 1 = peak).

    The first 3% of the video is skipped: people replay the intro to find
    where the stream actually starts, which says nothing about a moment.
    """
    segs = []
    for seg in heatmap or []:
        try:
            s, e, v = float(seg["start_time"]), float(seg["end_time"]), float(seg["value"])
        except (KeyError, TypeError, ValueError):
            continue
        segs.append((s, e, v))
    if not segs:
        return []
    total = max(e for _, e, _ in segs)
    keep = [x for x in segs if x[0] >= 0.03 * total and x[2] >= min_value]
    keep.sort(key=lambda x: -x[2])
    return sorted(({"start": round(s, 3), "end": round(e, 3), "views": int(300 * v),
                    "source": "heatmap"} for s, e, v in keep[:top]),
                  key=lambda c: c["start"])


_PTS = re.compile(r"pts_time:([0-9.]+)")
_RMS = re.compile(r"RMS_level=(-?[0-9.]+|-?inf|nan)")


def parse_astats(text: str) -> List[float]:
    """ffmpeg ``ametadata=print`` output (1 s frames) → RMS dBFS per second."""
    out: List[float] = []
    for m in _RMS.finditer(text):
        raw = m.group(1)
        try:
            v = float(raw)
        except ValueError:
            v = -90.0
        if math.isnan(v) or math.isinf(v):
            v = -90.0
        out.append(max(-90.0, v))
    return out


def loudness_signals(rms_db: List[float], min_over_db: float = LOUD_MIN_OVER_DB,
                     top: int = 20) -> List[dict]:
    if len(rms_db) < 30:
        return []
    base = rolling_median(rms_db, half_window=150, stride=10)
    peaks = find_peaks(rms_db, base, min_over=min_over_db, min_gap=45, top=top,
                       min_value=LOUD_FLOOR_DB)
    return [{"start": float(max(0, i - 20)), "end": float(i + 6),
             "views": int(min(400, 20 * excess)), "source": "loudness"}
            for i, excess in peaks]


def marker_signals(chapters) -> List[dict]:
    """OBS chapter markers → strong signals.

    The hotkey is pressed *after* the moment, so the span reaches back 35 s.
    OBS writes a chapter at 0 ("Start") on every Hybrid MP4: skipped.
    """
    out = []
    for ch in chapters or []:
        try:
            t = float(ch.get("start_time"))
        except (TypeError, ValueError):
            continue
        if t < 5:
            continue
        out.append({"start": round(max(0.0, t - 35.0), 3), "end": round(t + 5.0, 3),
                    "views": 1000, "source": "marker"})
    return out


def merge(signals: List[dict], duration: float) -> List[dict]:
    """Clamp to the file, drop empties, keep the strongest ``MAX_SIGNALS``."""
    out = []
    for c in signals:
        s = max(0.0, float(c["start"]))
        e = float(c["end"])
        if duration and duration > 0:
            if s >= duration:
                continue
            e = min(e, duration)
        if e - s < 1.0:
            continue
        out.append(dict(c, start=round(s, 3), end=round(e, 3)))
    out.sort(key=lambda c: -c.get("views", 0))
    return sorted(out[:MAX_SIGNALS], key=lambda c: c["start"])


# --------------------------------------------------------------------------- #
# I/O (best effort, never raises)
# --------------------------------------------------------------------------- #
def _yt_dlp(args: List[str], timeout: float) -> Optional[subprocess.CompletedProcess]:
    try:
        return subprocess.run([sys.executable, "-m", "yt_dlp", "--no-playlist",
                               "--no-warnings", *args],
                              capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None
    except Exception as e:  # noqa: BLE001
        print(f"   ℹ️ YouTube signals: yt-dlp unavailable ({type(e).__name__}).")
        return None


def fetch_heatmap(url: str) -> List[dict]:
    res = _yt_dlp(["-J", "--skip-download", url], timeout=120)
    if not res or res.returncode != 0:
        return []
    try:
        info = json.loads(res.stdout)
    except ValueError:
        return []
    return heatmap_signals(info.get("heatmap"))


def fetch_chat(url: str) -> List[dict]:
    with tempfile.TemporaryDirectory(prefix="ytchat_") as tmp:
        _yt_dlp(["--skip-download", "--write-subs", "--sub-langs", "live_chat",
                 "-o", os.path.join(tmp, "chat.%(ext)s"), url], timeout=CHAT_TIMEOUT)
        # A timeout leaves a .part file with the chat up to that point: use it.
        path = None
        for name in sorted(os.listdir(tmp)):
            if "live_chat" in name:
                path = os.path.join(tmp, name)
                if not name.endswith(".part"):
                    break
        if not path:
            return []
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return chat_signals(f)


def _run_ffmpeg(cmd: List[str], timeout: float) -> str:
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return (res.stdout or "") + (res.stderr or "")
    except Exception:  # noqa: BLE001
        return ""


def file_loudness(video_path: str) -> List[dict]:
    track = int(_env_float("MIC_AUDIO_TRACK", 0))
    af = ("aresample=8000,aformat=channel_layouts=mono,asetnsamples=n=8000:p=0,"
          "astats=metadata=1:reset=1,"
          "ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-")
    for t in ([track, 0] if track else [0]):
        text = _run_ffmpeg(["ffmpeg", "-nostdin", "-hide_banner", "-nostats", "-i", video_path,
                            "-map", f"0:a:{t}", "-vn", "-af", af, "-f", "null", "-"],
                           timeout=1800)
        series = parse_astats(text)
        if series:
            return loudness_signals(series)
    return []


def file_markers(video_path: str) -> List[dict]:
    text = _run_ffmpeg(["ffprobe", "-v", "error", "-print_format", "json",
                        "-show_chapters", video_path], timeout=60)
    try:
        chapters = json.loads(text[text.index("{"):]).get("chapters")
    except (ValueError, AttributeError):
        return []
    return marker_signals(chapters)


def _summary(signals: List[dict]) -> str:
    counts: Dict[str, int] = {}
    for c in signals:
        counts[c["source"]] = counts.get(c["source"], 0) + 1
    return ", ".join(f"{n} {k}" for k, n in sorted(counts.items())) or "none"


class Collector:
    """Starts the URL-side fetches (chat, heatmap) in the background so they run
    while the video downloads; ``collect`` adds the file-side signals and
    returns the lot. Never raises."""

    def __init__(self, url: Optional[str]):
        self._url_signals: List[dict] = []
        self._thread = None
        if url and is_youtube(url) and _env_on("YOUTUBE_SIGNALS"):
            self._thread = threading.Thread(target=self._fetch, args=(url,), daemon=True)
            self._thread.start()
            print("   📈 YouTube signals: fetching chat replay + Most-replayed in the background.")

    def _fetch(self, url: str):
        found: List[dict] = []
        for name, fn in (("heatmap", fetch_heatmap), ("chat", fetch_chat)):
            try:
                found.extend(fn(url))
            except Exception as e:  # noqa: BLE001
                print(f"   ℹ️ YouTube signals: {name} skipped ({type(e).__name__}: {e}).")
        self._url_signals = found

    def collect(self, video_path: Optional[str], duration: float, is_url: bool) -> List[dict]:
        if not _env_on("YOUTUBE_SIGNALS"):
            return []
        found: List[dict] = []
        try:
            if video_path and _env_on("LOUDNESS_SIGNAL"):
                found.extend(file_loudness(video_path))
            if video_path and not is_url:
                found.extend(file_markers(video_path))
        except Exception as e:  # noqa: BLE001
            print(f"   ℹ️ YouTube signals: file signals skipped ({type(e).__name__}: {e}).")
        if self._thread is not None:
            self._thread.join(timeout=CHAT_TIMEOUT + 180)
            found.extend(self._url_signals)
        merged = merge(found, duration)
        print(f"   📈 Moment signals: {_summary(merged)}.")
        return merged
