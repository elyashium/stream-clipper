# stream-clipper

Turn a YouTube live stream into ready-to-post vertical shorts, on your own
machine, with no watermark.

It is [OpenShorts](https://github.com/mutonby/openshorts) (MIT), pinned to a
tested commit, plus one addition: **YouTube moment signals**. OpenShorts already
uses what Twitch viewers clipped to find good moments, but YouTube has no clips
API, so this adds the signals a YouTube stream does have (see
[How moments are found](#how-moments-are-found)).

```
YouTube VOD link ─┐                                   ┌─ clips/<date>_<title>/00_….mp4
                  ├─ download ─ transcribe ─ signals ─ pick ─ reframe 9:16 ─ captions ─┤
OBS recording ────┘   (yt-dlp)   (Whisper)    (chat,    (Gemini) (gameplay +            └─ dashboard → post to
                                              replays,           facecam)                  TikTok / Shorts / Reels
                                              loudness,
                                              markers)
```

## Quick start

You need **Docker Desktop** ([Windows](https://docs.docker.com/desktop/setup/install/windows-install/) /
[Mac](https://docs.docker.com/desktop/setup/install/mac-install/)) running, and **git**.

```powershell
git clone https://github.com/elyashium/stream-clipper.git
cd stream-clipper
.\clipper.ps1 setup          # macOS/Linux: ./clipper.sh setup
```

`setup` downloads OpenShorts, applies the patch and builds everything. The first
build downloads several GB and takes 10–30 minutes. It also creates `.env`.
Open it (`notepad .env`) and paste your key:

| Key | Needed? | Where |
|---|---|---|
| `GEMINI_API_KEY` | **yes** | free at <https://aistudio.google.com/app/apikey> |
| `UPLOAD_POST_API_KEY` + `UPLOAD_POST_USER` | only for posting | free plan (10 uploads/month) at <https://www.upload-post.com>; connect TikTok/YouTube/Instagram there, `UPLOAD_POST_USER` is that profile's name |
| `USE_GPU=1` | if you have an NVIDIA card | then run `setup` again to rebuild |

Then clip a stream:

```powershell
.\clipper.ps1 run "https://www.youtube.com/watch?v=VIDEO_ID"
# or a local OBS recording:
.\clipper.ps1 run .\recordings\2026-11-19_gta6.mp4
```

It prints the pipeline log as it goes and ends with a list of clips, saved to
`clips\<date>_<title>_<job>\` along with a `clips.txt` of titles and captions.
Review them in the dashboard at <http://localhost:5175> (edit cuts, captions,
layout) and post from there, or:

```powershell
.\clipper.ps1 post <job_id> 0 --platforms tiktok,youtube,instagram
.\clipper.ps1 post <job_id> 1 --platforms tiktok --schedule 2026-11-20T18:00:00
```

> **"running scripts is disabled on this system"?** Run this once:
> `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`. Or use `.\clipper.cmd`
> instead of `.\clipper.ps1`. It takes the same commands.

### All commands

| | |
|---|---|
| `setup` | first install, and after changing `USE_GPU` |
| `start` / `stop` | start or stop the pipeline + dashboard |
| `run <url\|file> [--clips N] [--min S] [--max S]` | clip a stream |
| `post <job> <n> [--platforms …] [--schedule ISO]` | post clip `n` of a job |
| `jobs` | list clip folders |
| `logs` | follow the backend log |
| `update` | pull this repo and rebuild |
| `doctor` | check Docker, GPU, keys |

## Set up OBS once (5 minutes, worth it)

1. **Record while you stream.** Settings → Output → Recording:
   - **Recording path** → this repo's `recordings` folder. Then `run` reads the file
     directly with no copying.
   - **Recording format** → **Hybrid MP4** (OBS 30.2+). Needed for markers, and a
     crash doesn't corrupt the file.
2. **Bind the clip hotkey.** Settings → Hotkeys → **Add Chapter Marker**, for example
   `F9`. Press it right after anything good happens. Each press is the strongest
   signal the picker gets, and the clip reaches back about 35 s before the press.
3. **Put the mic on its own audio track** (optional, helps the loudness signal).
   In Output → Recording, tick tracks 1 and 2. In Edit → Advanced Audio
   Properties, put the mic on 1 and 2 and the game only on 1. Then set
   `MIC_AUDIO_TRACK=1` in `.env`.
4. **Turn the in-game radio down or off.** Licensed music in clips is the
   number-one cause of copyright claims and muted audio on Shorts, TikTok and
   Reels.

**VOD link or local recording?**

| | YouTube VOD link | local OBS recording |
|---|---|---|
| chat-replay spikes | ✅ | — |
| "Most replayed" | ✅ (after a few days of views) | — |
| mic loudness spikes | ✅ (mixed audio) | ✅ (clean mic track) |
| hotkey markers | — | ✅ |
| quality | YouTube's re-encode | original |

Use the link if chat was active. Use the recording if you pressed the hotkey
during the stream. YouTube doesn't keep archives of streams longer than 12
hours, so for marathon streams use the recording.

## How moments are found

Picking clips from the transcript alone misses most gaming highlights. A crash
or a chase is often a scream and ten seconds of nobody talking. OpenShorts
handles Twitch by asking which stretches viewers clipped. For YouTube,
[`stack/overlay/youtube_signals.py`](stack/overlay/youtube_signals.py) collects
four cheap signals and passes them through the same path:

| Signal | How | Cost |
|---|---|---|
| **Chat spikes** | yt-dlp downloads the live-chat replay. Messages are counted per 5 s against a rolling 10-minute baseline. Hype messages (`LMAO`, `W`, `CLIP IT`, 💀😂) count double and Super Chats count 4×. Each spike is shifted back 12 s, because chat reacts after the moment. | free, a few minutes on long streams |
| **Most replayed** | the "Most replayed" graph YouTube shows on the timeline (yt-dlp `heatmap`). Empty until the VOD has some views. | free |
| **Loudness spikes** | 1-second loudness of the mic track against a rolling 5-minute median. A jump of 9 dB or more is a scream or a laugh. | ffmpeg reads the audio once |
| **Hotkey markers** | OBS chapter markers in the recording | free |

These run in the background during the download. The pipeline then:

1. Shows them to Gemini alongside the transcript for every ~90 s window.
2. Guarantees the hottest windows a place on the shortlist, even if the
   transcript scores them low.
3. Has Gemini set the exact cut points, captions and titles.

So the LLM still makes the final call, but it can't miss the moments chat went
off on. Every signal is best effort: if chat replay is off or yt-dlp fails, the
job carries on with the others.

Tuning knobs live in `.env` (`CHAT_DELAY_SECONDS`, `MIC_AUDIO_TRACK`,
`LOUDNESS_SIGNAL`, `YOUTUBE_SIGNALS=0` to turn all of it off).

## Speed

On CPU, OpenShorts processes roughly 1 minute of video per minute, so a 3-hour
stream takes about 3 hours. Leave it running overnight. With an NVIDIA GPU
(`USE_GPU=1`), transcription and rendering are several times faster. A 4 GB card
(GTX 1650) works; the GPU config uses `int8_float16` so the model fits.

## Troubleshooting

- **`run` says the API isn't answering**: run `start`, wait for "ready", then
  check `logs`.
- **YouTube: "Sign in to confirm you're not a bot"**: put cookies from a
  **throwaway** account into `YOUTUBE_COOKIES` in `.env`, or use the local
  recording instead.
- **`setup` says the patch no longer applies**: only possible if
  `stack/UPSTREAM_SHA` was changed. Revert it, or regenerate the patch (see below).
- **Out of disk**: delete old folders in `openshorts/output/` and
  `openshorts/uploads/`. Your copies in `clips/` are separate.

## How this repo is built

```
clipper.ps1 / clipper.sh / clipper.cmd   the one command
stack/UPSTREAM_SHA                        OpenShorts commit we pin and test against
stack/patches/openshorts.patch            14-line hook into main.py + configurable upload size in app.py
stack/overlay/youtube_signals.py          the YouTube signals (copied into openshorts/)
stack/run_job.py                          submits a job and collects the clips (runs inside the container)
stack/docker-compose.override.yml         .env, clips/ and recordings/ mounted into the backend
stack/docker-compose.gpu.yml              NVIDIA build + runtime, used when USE_GPU=1
stack/env.template                        becomes .env
tests/                                    python -m unittest discover -s tests
```

`openshorts/` is fetched by `setup` and git-ignored. To move to a newer
OpenShorts: put the new commit in `stack/UPSTREAM_SHA`, run `setup`, fix the
patch if it fails, and regenerate it with
`git -C openshorts diff -- main.py app.py > stack/patches/openshorts.patch`.

OpenShorts is MIT-licensed, © OpenShorts. Its `cloud/` folder is under a
separate commercial license and isn't used here: self-hosted mode never turns it
on, and there is no watermark.
