"""Unit tests for the pure helpers in stack/overlay/youtube_signals.py.

Standard library only:  python -m unittest discover -s tests
"""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "stack", "overlay"))
import youtube_signals as ys  # noqa: E402


def chat_line(t_ms, text=None, paid=False):
    if paid:
        item = {"liveChatPaidMessageRenderer": {"purchaseAmountText": {"simpleText": "$5"}}}
    else:
        item = {"liveChatTextMessageRenderer": {"message": {"runs": [{"text": text}]}}}
    return json.dumps({"replayChatItemAction": {
        "actions": [{"addChatItemAction": {"item": item}}],
        "videoOffsetTimeMsec": str(t_ms)}})


class HypeTest(unittest.TestCase):
    def test_words_not_substrings(self):
        self.assertTrue(ys.is_hype("W"))
        self.assertTrue(ys.is_hype("LMAOOO no way"))
        self.assertTrue(ys.is_hype("bro 💀"))
        self.assertFalse(ys.is_hype("all well and good"))   # 'l', 'w' inside words
        self.assertFalse(ys.is_hype("nice drive"))


class ChatTest(unittest.TestCase):
    def test_parse_weights(self):
        self.assertEqual(ys.parse_chat_line(chat_line(5000, "hello")), (5.0, 1.0))
        self.assertEqual(ys.parse_chat_line(chat_line(5000, "LMAO")), (5.0, 2.0))
        self.assertEqual(ys.parse_chat_line(chat_line(5000, paid=True)), (5.0, 4.0))
        self.assertIsNone(ys.parse_chat_line("not json"))
        self.assertIsNone(ys.parse_chat_line(json.dumps({"other": 1})))

    def test_series_skips_prestream(self):
        lines = [chat_line(-3000, "hi"), chat_line(1000, "hi"), chat_line(12000, "hi")]
        self.assertEqual(ys.chat_series(lines), [1.0, 0.0, 1.0])

    def test_spike_found_and_shifted_back(self):
        lines = []
        # 20 minutes of steady chat: one message every 5 s.
        for t in range(0, 1200, 5):
            lines.append(chat_line(t * 1000 + 100, "ok"))
        # Burst at 600-610 s: 25 hype messages.
        for k in range(25):
            lines.append(chat_line(600_000 + k * 400, "LMAO no way"))
        sig = ys.chat_signals(lines, delay=12.0)
        self.assertEqual(len(sig), 1, sig)
        s = sig[0]
        self.assertEqual(s["source"], "chat")
        # Moment ≈ burst bucket centre minus the delay, span reaches back 25 s.
        self.assertTrue(560 <= s["start"] <= 580, s)
        self.assertTrue(s["start"] < 600 - 12 < s["end"], s)

    def test_quiet_chat_no_spike(self):
        lines = [chat_line(t * 1000, "hi") for t in range(0, 600, 7)]
        self.assertEqual(ys.chat_signals(lines), [])


class PeaksTest(unittest.TestCase):
    def test_nms_keeps_biggest(self):
        series = [0.0] * 100
        series[10], series[12], series[60] = 10.0, 8.0, 9.0
        peaks = ys.find_peaks(series, [0.0] * 100, min_over=5, min_gap=5, top=10)
        self.assertEqual([i for i, _ in peaks], [10, 60])

    def test_rolling_median_stride(self):
        out = ys.rolling_median([1, 1, 1, 9, 1, 1, 1], half_window=2, stride=1)
        self.assertEqual(out[3], 1)
        self.assertEqual(len(ys.rolling_median(list(range(50)), 5, stride=7)), 50)


class LoudnessTest(unittest.TestCase):
    def test_parse_astats(self):
        text = ("frame:0    pts:0       pts_time:0\nlavfi.astats.Overall.RMS_level=-30.5\n"
                "frame:1    pts:8000    pts_time:1\nlavfi.astats.Overall.RMS_level=-inf\n")
        self.assertEqual(ys.parse_astats(text), [-30.5, -90.0])

    def test_scream_peak(self):
        db = [-32.0] * 600
        db[300] = -14.0               # 18 dB over the room
        db[450] = -60.0               # a dip is never a peak
        sig = ys.loudness_signals(db)
        self.assertEqual(len(sig), 1)
        self.assertEqual((sig[0]["start"], sig[0]["end"]), (280.0, 306.0))

    def test_silence_floor(self):
        db = [-80.0] * 600
        db[100] = -50.0               # +30 dB, but still below the floor
        self.assertEqual(ys.loudness_signals(db), [])


class OtherSignalsTest(unittest.TestCase):
    def test_heatmap(self):
        hm = [{"start_time": i * 60, "end_time": (i + 1) * 60, "value": 0.1} for i in range(100)]
        hm[1]["value"] = 1.0          # intro replays: skipped
        hm[50]["value"] = 0.9
        sig = ys.heatmap_signals(hm)
        self.assertEqual([(s["start"], s["end"]) for s in sig], [(3000.0, 3060.0)])

    def test_markers(self):
        sig = ys.marker_signals([{"start_time": "0.000000"}, {"start_time": "125.5"}])
        self.assertEqual(sig, [{"start": 90.5, "end": 130.5, "views": 1000, "source": "marker"}])

    def test_merge_clamps_and_caps(self):
        sig = [{"start": 10, "end": 50, "views": 1, "source": "x"},
               {"start": 95, "end": 120, "views": 2, "source": "x"},
               {"start": 200, "end": 230, "views": 3, "source": "x"}]
        out = ys.merge(sig, duration=100)
        self.assertEqual([(c["start"], c["end"]) for c in out], [(10, 50), (95, 100)])

    def test_is_youtube(self):
        self.assertTrue(ys.is_youtube("https://www.youtube.com/watch?v=abc"))
        self.assertTrue(ys.is_youtube("https://youtu.be/abc"))
        self.assertFalse(ys.is_youtube("https://www.twitch.tv/videos/1"))
        self.assertFalse(ys.is_youtube("/recordings/x.mp4"))


if __name__ == "__main__":
    unittest.main()
