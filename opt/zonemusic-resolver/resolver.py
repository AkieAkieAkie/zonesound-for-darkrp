# -*- coding: utf-8 -*-
"""ZoneMusic resolver: recherche yt-dlp, mastering mono et diffusion HTTP."""

import hmac
import json
import os
import re
import subprocess
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import yt_dlp


PORT = int(os.environ.get("PORT", "8765"))
PUBLIC_URL = os.environ.get("PUBLIC_URL", "").rstrip("/")
RESOLVER_KEY = os.environ.get("RESOLVER_KEY", "")
CACHE_DIR = os.environ.get("CACHE_DIR", "/var/cache/zonemusic")
COOKIE_FILE = os.environ.get("COOKIE_FILE", "/etc/zonemusic/cookies.txt")
MAX_DURATION = int(os.environ.get("MAX_DURATION", "900"))
MAX_FILES = max(1, int(os.environ.get("MAX_FILES", "300")))
CACHE_TTL = int(os.environ.get("CACHE_TTL", "604800"))
INDEX_FILE = os.path.join(CACHE_DIR, "index.json")

if not RESOLVER_KEY or RESOLVER_KEY in ("change-moi", "changeme"):
    raise RuntimeError("RESOLVER_KEY doit etre defini dans l'environnement.")
if not PUBLIC_URL:
    raise RuntimeError("PUBLIC_URL doit etre defini avec une URL joignable par le serveur GMod.")

os.makedirs(CACHE_DIR, exist_ok=True)

_state_lock = threading.Lock()
_index_lock = threading.Lock()
_query_locks = {}
_video_locks = {}

try:
    with open(INDEX_FILE, "r", encoding="utf-8") as stream:
        search_cache = json.load(stream)
    if not isinstance(search_cache, dict):
        search_cache = {}
except (OSError, ValueError):
    search_cache = {}


def get_lock(lock_map, key):
    with _state_lock:
        if key not in lock_map:
            lock_map[key] = threading.Lock()
        return lock_map[key]


def normalize_query(query):
    return " ".join(query.strip().lower().split())


def save_index():
    with _index_lock:
        temporary = INDEX_FILE + ".tmp"
        with open(temporary, "w", encoding="utf-8") as stream:
            json.dump(search_cache, stream, ensure_ascii=False)
        os.replace(temporary, INDEX_FILE)


def ytdlp_options():
    options = {
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "socket_timeout": 25,
        "retries": 3,
        "fragment_retries": 3,
        "concurrent_fragment_downloads": 4,
    }

    if os.path.isfile(COOKIE_FILE):
        options["cookiefile"] = COOKIE_FILE

    # yt-dlp utilise un runtime JS pour certaines extractions YouTube recentes.
    # Le runtime doit etre installe sur le VPS (Deno recommande).
    if os.environ.get("YTDLP_USE_DENO", "1") == "1":
        options["js_runtimes"] = {"deno": {}}

    return options


def spotify_to_query(url):
    endpoint = "https://open.spotify.com/oembed?url=" + urllib.parse.quote(url, safe="")
    with urllib.request.urlopen(endpoint, timeout=15) as response:
        data = json.load(response)
    title = data.get("title")
    if not title:
        raise ValueError("Impossible de lire le titre Spotify.")
    return title + " audio"


def extract_info(target):
    with yt_dlp.YoutubeDL(ytdlp_options()) as ydl:
        info = ydl.extract_info(target, download=False)

    if not info:
        raise ValueError("Aucun resultat.")
    if "entries" in info:
        entries = [entry for entry in (info.get("entries") or []) if entry]
        if not entries:
            raise ValueError("Aucun resultat.")
        info = entries[0]

    duration = float(info.get("duration") or 0)
    if duration > MAX_DURATION:
        raise ValueError(f"Morceau trop long (maximum {MAX_DURATION // 60} minutes).")

    video_id = re.sub(r"[^\w-]", "", str(info.get("id") or ""))
    if not video_id:
        raise ValueError("Identifiant audio invalide.")

    thumbnail = info.get("thumbnail")
    if not thumbnail:
        thumbnails = info.get("thumbnails") or []
        for item in reversed(thumbnails):
            if isinstance(item, dict) and item.get("url"):
                thumbnail = item["url"]
                break

    if not thumbnail:
        thumbnail = f"https://i.ytimg.com/vi/{video_id}/hqdefault.jpg"

    return {
        "id": video_id,
        "title": str(info.get("title") or "Titre inconnu")[:160],
        "duration": duration,
        "thumbnail": str(thumbnail)[:1000],
        "webpage_url": info.get("webpage_url") or target,
        "created": int(time.time()),
    }


def master_audio(source, indoor_path, outdoor_path):
    # Mono obligatoire pour une spatialisation fiable via sound.PlayURL("3d").
    filters = (
        "[0:a]asplit=2[club][outside];"
        "[club]"
        "highpass=f=30,"
        "equalizer=f=60:t=q:w=1:g=3,"
        "equalizer=f=100:t=q:w=1:g=2,"
        "equalizer=f=2500:t=q:w=1:g=1.5,"
        "acompressor=threshold=0.25:ratio=3:attack=10:release=100,"
        "loudnorm=I=-14:TP=-1.0:LRA=7:linear=false,"
        "alimiter=limit=0.95:attack=5:release=80"
        "[clubout];"
        "[outside]"
        "highpass=f=45,"
        "lowpass=f=850,"
        "equalizer=f=120:t=q:w=1:g=3,"
        "equalizer=f=350:t=q:w=1:g=1,"
        "equalizer=f=1800:t=q:w=1:g=-8,"
        "equalizer=f=4000:t=q:w=1:g=-15,"
        "acompressor=threshold=0.25:ratio=4:attack=15:release=150,"
        "loudnorm=I=-16:TP=-1.5:LRA=8:linear=false,"
        "alimiter=limit=0.90:attack=5:release=100"
        "[outsideout]"
    )

    command = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-i", source,
        "-filter_complex", filters,
        "-map", "[clubout]", "-ar", "48000", "-ac", "1",
        "-c:a", "libmp3lame", "-b:a", "160k", indoor_path,
        "-map", "[outsideout]", "-ar", "48000", "-ac", "1",
        "-c:a", "libmp3lame", "-b:a", "96k", outdoor_path,
    ]

    result = subprocess.run(command, capture_output=True, text=True, timeout=600)
    if result.returncode != 0:
        raise RuntimeError("FFmpeg a echoue : " + (result.stderr or "")[-1200:])

    for path in (indoor_path, outdoor_path):
        if not os.path.isfile(path) or os.path.getsize(path) < 1024:
            raise RuntimeError("Fichier audio genere absent ou vide.")


def download_audio(info):
    video_id = info["id"]
    indoor = os.path.join(CACHE_DIR, video_id + ".mp3")
    outdoor = os.path.join(CACHE_DIR, video_id + "_outside.mp3")
    indoor_tmp = indoor + ".tmp.mp3"
    outdoor_tmp = outdoor + ".tmp.mp3"

    if os.path.isfile(indoor) and os.path.isfile(outdoor):
        return indoor, outdoor

    options = ytdlp_options()
    options.update({
        "format": "bestaudio/best",
        "outtmpl": os.path.join(CACHE_DIR, video_id + ".%(ext)s"),
        "buffersize": 1024 * 1024,
        "overwrites": True,
    })

    source = None
    try:
        print("[ZoneMusic] Telechargement :", info["title"], flush=True)
        with yt_dlp.YoutubeDL(options) as ydl:
            downloaded = ydl.extract_info(info["webpage_url"], download=True)
            source = ydl.prepare_filename(downloaded)

        if not source or not os.path.isfile(source):
            raise RuntimeError("Source audio telechargee introuvable.")

        print("[ZoneMusic] Mastering interieur/exterieur :", video_id, flush=True)
        master_audio(source, indoor_tmp, outdoor_tmp)

        # Publie les deux pistes uniquement apres traitement complet.
        os.replace(indoor_tmp, indoor)
        os.replace(outdoor_tmp, outdoor)
    finally:
        for path in (source, indoor_tmp, outdoor_tmp):
            if path and os.path.isfile(path):
                try:
                    os.remove(path)
                except OSError:
                    pass

    clean_cache()
    return indoor, outdoor


def clean_cache():
    groups = {}
    for name in os.listdir(CACHE_DIR):
        if not name.endswith(".mp3") or name.endswith(".tmp.mp3"):
            continue
        key = name[:-12] if name.endswith("_outside.mp3") else name[:-4]
        path = os.path.join(CACHE_DIR, name)
        groups.setdefault(key, []).append(path)

    ordered = sorted(
        groups.items(),
        key=lambda item: max(os.path.getmtime(path) for path in item[1]),
        reverse=True,
    )

    for _, paths in ordered[MAX_FILES:]:
        for path in paths:
            try:
                os.remove(path)
            except OSError:
                pass


def resolve(query):
    query = (query or "").strip()
    if not query:
        raise ValueError("Recherche vide.")

    cache_key = normalize_query(query)
    with get_lock(_query_locks, cache_key):
        with _index_lock:
            cached = search_cache.get(cache_key)

        info = None
        if isinstance(cached, dict):
            age = time.time() - float(cached.get("created", 0))
            if age <= CACHE_TTL:
                info = cached

        if info is None:
            target = spotify_to_query(query) if "spotify.com" in query.lower() else query
            if not re.match(r"^https?://", target, flags=re.I):
                target = "ytsearch1:" + target
            info = extract_info(target)
            with _index_lock:
                search_cache[cache_key] = info
            save_index()

        with get_lock(_video_locks, info["id"]):
            download_audio(info)

        return {
            "url": f"{PUBLIC_URL}/audio/{info['id']}.mp3",
            "outdoor_url": f"{PUBLIC_URL}/audio/{info['id']}_outside.mp3",
            "title": info.get("title", query),
            "duration": info.get("duration") or 0,
            "video_id": info.get("id", ""),
            "thumbnail": info.get("thumbnail") or (
                f"https://i.ytimg.com/vi/{info.get('id', '')}/hqdefault.jpg"
            ),
            "webpage_url": info.get("webpage_url", ""),
        }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self):
        self.handle_request()

    def do_HEAD(self):
        self.handle_request()

    def handle_request(self):
        parsed = urllib.parse.urlparse(self.path)

        if parsed.path == "/health":
            return self.send_json(200, {"ok": True, "service": "zonemusic-resolver"})

        if parsed.path == "/resolve":
            supplied = self.headers.get("X-ZoneMusic-Key", "")
            if not hmac.compare_digest(supplied, RESOLVER_KEY):
                return self.send_json(403, {"error": "Acces refuse."})

            query = urllib.parse.parse_qs(parsed.query).get("q", [""])[0]
            try:
                return self.send_json(200, resolve(query))
            except Exception as error:
                print("[ZoneMusic] Erreur resolve :", repr(error), flush=True)
                return self.send_json(500, {"error": "Echec de la recherche ou du traitement audio."})

        match = re.fullmatch(r"/audio/([\w-]+)\.mp3", parsed.path)
        if match:
            return self.serve_audio(match.group(1))

        return self.send_json(404, {"error": "Introuvable."})

    def serve_audio(self, file_id):
        path = os.path.join(CACHE_DIR, file_id + ".mp3")
        if not os.path.isfile(path):
            return self.send_json(404, {"error": "Audio introuvable."})

        size = os.path.getsize(path)
        if size <= 0:
            return self.send_json(404, {"error": "Audio vide."})

        start, end, status = 0, size - 1, 200
        header = self.headers.get("Range")
        if header:
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", header.strip())
            if not match or (not match.group(1) and not match.group(2)):
                return self.range_error(size)

            first, last = match.groups()
            if not first:
                suffix = int(last)
                if suffix <= 0:
                    return self.range_error(size)
                start = max(0, size - suffix)
            else:
                start = int(first)
                if last:
                    end = int(last)

            if start >= size or end < start:
                return self.range_error(size)
            end = min(end, size - 1)
            status = 206

        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", "audio/mpeg")
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "public, max-age=86400")
        self.send_header("Connection", "close")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()

        if self.command == "HEAD":
            return

        try:
            with open(path, "rb") as audio:
                audio.seek(start)
                remaining = length
                while remaining:
                    chunk = audio.read(min(65536, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def range_error(self, size):
        self.send_response(416)
        self.send_header("Content-Range", f"bytes */{size}")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *_args):
        pass


if __name__ == "__main__":
    print(f"[ZoneMusic] Resolver sur le port {PORT}", flush=True)
    print(f"[ZoneMusic] Cache : {CACHE_DIR}", flush=True)
    print(f"[ZoneMusic] Cookies : {'actifs' if os.path.isfile(COOKIE_FILE) else 'absents'}", flush=True)

    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    server.serve_forever()
