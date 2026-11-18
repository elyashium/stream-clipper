#!/usr/bin/env bash
# clipper: one command for the whole stream → shorts pipeline (macOS / Linux).
# Windows: use clipper.ps1 (same commands).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_DIR="$ROOT/openshorts"
UPSTREAM_URL="https://github.com/mutonby/openshorts"
UPSTREAM_SHA="$(tr -d '[:space:]' < "$ROOT/stack/UPSTREAM_SHA")"
API="http://localhost:8000"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
env_get() { [ -f "$ROOT/.env" ] && grep -E "^$1=" "$ROOT/.env" | tail -1 | cut -d= -f2- | tr -d '\r' || true; }

compose() {
  local files=(-f "$OS_DIR/docker-compose.yml" -f "$ROOT/stack/docker-compose.override.yml")
  if [ "$(env_get USE_GPU)" = "1" ]; then files+=(-f "$ROOT/stack/docker-compose.gpu.yml"); fi
  docker compose -p clipper --project-directory "$OS_DIR" "${files[@]}" "$@"
}

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is not installed. $2"; }

fetch_upstream() {
  if [ ! -d "$OS_DIR/.git" ]; then
    git init -q "$OS_DIR"
    git -C "$OS_DIR" config core.autocrlf false
    git -C "$OS_DIR" remote add origin "$UPSTREAM_URL"
  fi
  if [ "$(git -C "$OS_DIR" rev-parse HEAD 2>/dev/null || true)" != "$UPSTREAM_SHA" ]; then
    say "Fetching OpenShorts @ ${UPSTREAM_SHA:0:7}..."
    git -C "$OS_DIR" fetch -q --depth 1 origin "$UPSTREAM_SHA"
    git -C "$OS_DIR" checkout -q --force FETCH_HEAD
  fi
}

apply_overlay() {
  cp "$ROOT/stack/overlay/youtube_signals.py" "$OS_DIR/youtube_signals.py"
  local patch="$ROOT/stack/patches/openshorts.patch"
  if git -C "$OS_DIR" apply --reverse --check "$patch" 2>/dev/null; then
    return 0   # already applied
  fi
  git -C "$OS_DIR" apply "$patch" || die "the patch no longer applies to OpenShorts ${UPSTREAM_SHA:0:7}."
  say "Applied the YouTube-signals patch."
}

ensure_env() {
  mkdir -p "$ROOT/clips" "$ROOT/recordings"
  if [ ! -f "$ROOT/.env" ]; then
    cp "$ROOT/stack/env.template" "$ROOT/.env"
    say "Created .env — open it and paste your GEMINI_API_KEY."
  fi
}

check_keys() {
  if [ -z "$(env_get GEMINI_API_KEY)" ] && [ -z "$(env_get LLM_BASE_URL)" ]; then
    die "GEMINI_API_KEY is empty in .env (free key: https://aistudio.google.com/app/apikey)."
  fi
}

wait_healthy() {
  printf 'Waiting for the pipeline to come up'
  for _ in $(seq 1 120); do
    if curl -fsS "$API/health" >/dev/null 2>&1; then echo " ready."; return 0; fi
    printf '.'; sleep 3
  done
  echo; die "the backend did not answer on $API/health. Look at: ./clipper.sh logs"
}

exec_job() {
  local tty=()
  [ -t 0 ] && [ -t 1 ] || tty=(-T)
  compose exec "${tty[@]}" backend python -u /stack/run_job.py "$@"
}

container_path() {   # host file → path the container sees
  local src="$1" abs
  abs="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"
  case "$abs" in
    "$ROOT/recordings/"*) echo "/recordings/${abs#"$ROOT/recordings/"}" ;;
    *)
      say "Copying $(basename "$abs") into recordings/ (record straight into that folder to skip this)..." >&2
      cp -n "$abs" "$ROOT/recordings/" ; echo "/recordings/$(basename "$abs")" ;;
  esac
}

usage() {
  cat <<EOF
clipper — stream → vertical shorts, locally, no watermark.

  ./clipper.sh setup              download OpenShorts, apply the patch, build (first time / after update)
  ./clipper.sh start              start the pipeline + dashboard (http://localhost:5175)
  ./clipper.sh run <url|file> [--clips N] [--min S] [--max S]
                                  clip a YouTube VOD link or a local OBS recording
  ./clipper.sh post <job> <n> [--platforms tiktok,youtube,instagram] [--schedule ISO]
  ./clipper.sh jobs               list the clip folders in clips/
  ./clipper.sh logs               follow the backend log
  ./clipper.sh stop               stop everything
  ./clipper.sh update             pull this repo and rebuild
  ./clipper.sh doctor             check this machine
EOF
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  setup)
    need git "Install git first."; need docker "Install Docker Desktop: https://docs.docker.com/get-docker/"
    docker compose version >/dev/null 2>&1 || die "docker compose v2 is missing."
    docker info >/dev/null 2>&1 || die "Docker is installed but not running. Start Docker Desktop."
    fetch_upstream; apply_overlay; ensure_env
    say "Building the images (the first build downloads several GB, 10-30 min)..."
    compose build
    compose up -d
    wait_healthy
    say "Setup done. Dashboard: http://localhost:5175"
    if [ -z "$(env_get GEMINI_API_KEY)" ]; then say "Next: put GEMINI_API_KEY in .env, then ./clipper.sh start"; fi ;;
  start)
    [ -d "$OS_DIR/.git" ] || die "run ./clipper.sh setup first."
    ensure_env; apply_overlay; compose up -d; wait_healthy
    say "Dashboard: http://localhost:5175" ;;
  stop) compose down ;;
  logs) compose logs -f --tail 200 backend ;;
  run)
    [ $# -ge 1 ] || die "usage: ./clipper.sh run <youtube-url | recording-file> [--clips N]"
    [ -d "$OS_DIR/.git" ] || die "run ./clipper.sh setup first."
    check_keys
    src="$1"; shift
    if [ -f "$src" ]; then src="$(container_path "$src")"
    elif [[ ! "$src" =~ ^https?:// ]]; then die "$src is neither a URL nor a file."; fi
    compose up -d >/dev/null; wait_healthy
    exec_job process "$src" "$@" ;;
  post) exec_job post "$@" ;;
  jobs) exec_job jobs ;;
  update)
    git -C "$ROOT" pull --ff-only
    exec "$ROOT/clipper.sh" setup ;;
  doctor)
    for c in git docker curl; do command -v $c >/dev/null && echo "ok   $c" || echo "MISS $c"; done
    docker info >/dev/null 2>&1 && echo "ok   docker running" || echo "MISS docker is not running"
    command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=name,memory.total --format=csv,noheader | sed 's/^/gpu  /' || echo "info no NVIDIA GPU (CPU mode, slower)"
    [ -f "$ROOT/.env" ] && echo "ok   .env" || echo "MISS .env (run setup)"
    [ -n "$(env_get GEMINI_API_KEY)" ] && echo "ok   GEMINI_API_KEY" || echo "MISS GEMINI_API_KEY"
    [ -n "$(env_get UPLOAD_POST_API_KEY)" ] && echo "ok   UPLOAD_POST_API_KEY" || echo "info no UPLOAD_POST_API_KEY (posting off)"
    curl -fsS "$API/health" >/dev/null 2>&1 && echo "ok   pipeline running" || echo "info pipeline not running (./clipper.sh start)" ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
