"""Submit a stream to the local OpenShorts API, follow it, collect the clips.

Runs INSIDE the backend container (``clipper run`` calls it through
``docker compose exec``), so the host needs nothing but Docker: Python, ffmpeg
and yt-dlp all live in the image. Standard library only.

  run_job.py process <youtube-url | /recordings/file.mp4> [--clips N] [--min S] [--max S]
  run_job.py post <job_id> <clip_index> [--platforms tiktok,youtube,instagram] [--title T] [--schedule ISO]
  run_job.py jobs        (lists the clip folders)
"""
import argparse
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.request

API = os.environ.get("CLIPPER_API", "http://localhost:8000").rstrip("/")
CLIPS_DIR = "/clips"          # ./clips on the host
OUTPUT_DIR = "/app/output"    # where OpenShorts writes each job
POLL = 5


def _request(method, path, body=None, data=None, headers=None, timeout=120):
    hdrs = {"Accept": "application/json"}
    hdrs.update(headers or {})
    if body is not None:
        data = json.dumps(body).encode()
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(API + path, data=data, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        try:
            payload = json.loads(e.read().decode() or "{}")
        except Exception:  # noqa: BLE001
            payload = {"detail": str(e.reason)}
        return e.code, payload
    except urllib.error.URLError as e:
        sys.exit(f"error: the OpenShorts API is not answering at {API} ({e.reason}). "
                 f"Is it running? Try: clipper start")


def _check(status, payload, what):
    if status >= 400:
        detail = payload.get("detail", payload) if isinstance(payload, dict) else payload
        sys.exit(f"error: {what} failed ({status}): {detail if isinstance(detail, str) else json.dumps(detail)}")
    return payload


def _upload(path):
    size = os.path.getsize(path)
    print(f"Uploading {os.path.basename(path)} ({size / 1e9:.2f} GB) to the local pipeline...")
    slot = _check(*_request("POST", "/api/uploads", {"filename": os.path.basename(path)}),
                  "reserving an upload")
    with open(path, "rb") as f:
        status, payload = _request("PUT", f"/api/uploads/{slot['upload_id']}", data=f,
                                   headers={"Content-Type": "application/octet-stream",
                                            "Content-Length": str(size)},
                                   timeout=3600)
    _check(status, payload, "uploading")
    return slot["upload_id"]


def _slug(text, limit=48):
    s = re.sub(r"[^A-Za-z0-9]+", "-", str(text or "")).strip("-").lower()
    return s[:limit].strip("-") or "stream"


def _collect(job_id, result, source_name):
    clips = (result or {}).get("clips") or []
    folder = f"{time.strftime('%Y-%m-%d')}_{_slug(source_name)}_{job_id[:8]}"
    dest = os.path.join(CLIPS_DIR, folder)
    os.makedirs(dest, exist_ok=True)
    lines = []
    for i, clip in enumerate(clips):
        name = os.path.basename((clip.get("video_url") or "").split("?")[0])
        src = os.path.join(OUTPUT_DIR, job_id, name) if name else ""
        title = clip.get("title") or clip.get("video_title_for_youtube_short") or f"clip {i}"
        score = clip.get("predicted_score", clip.get("score"))
        out_name = f"{i:02d}_{_slug(title)}.mp4"
        if src and os.path.exists(src):
            shutil.copy2(src, os.path.join(dest, out_name))
        lines.append(f"[{i}] {title}" + (f"  (score {score})" if score is not None else ""))
        lines.append(f"    file: {out_name}")
        for key in ("video_title_for_youtube_short", "video_description_for_tiktok",
                    "video_description_for_instagram"):
            if clip.get(key):
                lines.append(f"    {key}: {clip[key]}")
    with open(os.path.join(dest, "clips.txt"), "w", encoding="utf-8") as f:
        f.write(f"job {job_id}\nsource {source_name}\n\n" + "\n".join(lines) + "\n")
    with open(os.path.join(dest, "result.json"), "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2, ensure_ascii=False)
    print("\n".join(lines))
    print(f"\n{len(clips)} clip(s) saved to clips/{folder}/")
    print(f"Review them in the dashboard (http://localhost:5175) or post one with:\n"
          f"  clipper post {job_id} <clip_index> --platforms tiktok,youtube,instagram")


def cmd_process(args):
    body = {"acknowledged": True,
            "layouts": args.layouts or os.environ.get("CLIPPER_LAYOUTS", "auto,screencast")}
    if args.clips:
        body["target_clips"] = args.clips
    if args.min:
        body["clip_min_seconds"] = args.min
    if args.max:
        body["clip_max_seconds"] = args.max

    src = args.source
    if re.match(r"^https?://", src):
        body["url"] = src
        name = src
    else:
        if not os.path.isfile(src):
            sys.exit(f"error: {src} is not a file inside the container. Put recordings in the "
                     f"recordings/ folder (OBS can record straight into it).")
        body["upload_id"] = _upload(src)
        name = os.path.splitext(os.path.basename(src))[0]

    payload = _check(*_request("POST", "/api/process", body), "starting the job")
    job_id = payload.get("job_id")
    print(f"Job {job_id} queued. Following its log (Ctrl+C stops following, not the job)...\n")
    seen = 0
    while True:
        status, st = _request("GET", f"/api/status/{job_id}")
        _check(status, st, "reading job status")
        logs = st.get("logs") or []
        for line in logs[seen:]:
            print(f"  {line}")
        seen = len(logs)
        state = st.get("status")
        if state == "completed":
            print("\nDone.\n")
            _collect(job_id, st.get("result"), name)
            return
        if state == "failed":
            sys.exit("\nThe job failed; the last log lines above say why.")
        time.sleep(POLL)


def cmd_post(args):
    key = os.environ.get("UPLOAD_POST_API_KEY", "").strip()
    user = os.environ.get("UPLOAD_POST_USER", "").strip()
    if not key or not user:
        sys.exit("error: set UPLOAD_POST_API_KEY and UPLOAD_POST_USER in .env first "
                 "(free key + profile at https://www.upload-post.com).")
    body = {"job_id": args.job_id, "clip_index": args.clip_index, "user_id": user,
            "platforms": [p.strip() for p in args.platforms.split(",") if p.strip()]}
    if args.title:
        body["title"] = args.title
    if args.schedule:
        body["scheduled_date"] = args.schedule
        body["timezone"] = args.timezone
    payload = _check(*_request("POST", "/api/social/post", body,
                               headers={"X-Upload-Post-Key": key}, timeout=600), "posting")
    print(json.dumps(payload, indent=2))


def _already_collected(job_id):
    tag = f"_{job_id[:8]}"
    return os.path.isdir(CLIPS_DIR) and any(n.endswith(tag) for n in os.listdir(CLIPS_DIR))


def cmd_sync(_args):
    """Copy clips of jobs started from the dashboard into clips/ (once each)."""
    jobs = sorted(os.listdir(OUTPUT_DIR)) if os.path.isdir(OUTPUT_DIR) else []
    copied = 0
    for job_id in jobs:
        if job_id.startswith(".") or not os.path.isdir(os.path.join(OUTPUT_DIR, job_id)):
            continue
        if _already_collected(job_id):
            continue
        status, st = _request("GET", f"/api/status/{job_id}", timeout=30)
        if status != 200 or (st or {}).get("status") != "completed":
            continue
        result = st.get("result") or {}
        clips = result.get("clips") or []
        if not clips:
            continue
        meta = [n for n in os.listdir(os.path.join(OUTPUT_DIR, job_id))
                if n.endswith("_metadata.json")]
        name = meta[0][:-len("_metadata.json")] if meta else job_id
        if name.startswith(job_id + "_"):
            name = name[len(job_id) + 1:]
        print(f"--- {job_id}")
        _collect(job_id, result, name)
        copied += 1
    print(f"{copied} new job(s) copied to clips/." if copied else "clips/ is up to date.")


def cmd_jobs(_args):
    names = sorted(os.listdir(CLIPS_DIR)) if os.path.isdir(CLIPS_DIR) else []
    print("\n".join(names) or "no clip folders yet")


def main():
    p = argparse.ArgumentParser(prog="clipper")
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("process")
    a.add_argument("source")
    a.add_argument("--clips", type=int)
    a.add_argument("--min", type=int, help="shortest clip, seconds")
    a.add_argument("--max", type=int, help="longest clip, seconds")
    a.add_argument("--layouts")
    a.set_defaults(fn=cmd_process)
    b = sub.add_parser("post")
    b.add_argument("job_id")
    b.add_argument("clip_index", type=int)
    b.add_argument("--platforms", default="tiktok,youtube,instagram")
    b.add_argument("--title")
    b.add_argument("--schedule", help="ISO time, e.g. 2026-11-20T18:00:00")
    b.add_argument("--timezone", default=os.environ.get("TZ", "UTC"))
    b.set_defaults(fn=cmd_post)
    c = sub.add_parser("jobs")
    c.set_defaults(fn=cmd_jobs)
    d = sub.add_parser("sync")
    d.set_defaults(fn=cmd_sync)
    args = p.parse_args()
    try:
        args.fn(args)
    except KeyboardInterrupt:
        print("\nStopped following. The job keeps running; see the dashboard.")


if __name__ == "__main__":
    main()
