#!/usr/bin/env python3
"""Filtre un export Netscape cookies.txt pour yt-dlp sans afficher les valeurs."""
import sys
from pathlib import Path

if len(sys.argv) != 3:
    raise SystemExit("Usage: filter_youtube_cookies.py export-cookies.txt cookies.txt")

source, destination = map(Path, sys.argv[1:])
kept = []
for line in source.read_text(encoding="utf-8", errors="replace").splitlines():
    if not line:
        continue

    # Netscape prefixe special pour les cookies HttpOnly.
    candidate = line[len("#HttpOnly_"):] if line.startswith("#HttpOnly_") else line
    if candidate.startswith("#"):
        kept.append(line)
        continue

    fields = candidate.split("\t")
    if len(fields) < 7:
        continue

    domain = fields[0].lstrip(".").lower()
    allowed = (
        domain == "youtube.com" or domain.endswith(".youtube.com")
        or domain == "google.com" or domain.endswith(".google.com")
    )
    if allowed:
        kept.append(line)

destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text("\n".join(kept).rstrip() + "\n", encoding="utf-8")
destination.chmod(0o600)
count = sum(1 for line in kept if line and not line.startswith("#"))
print(f"Cookie file created: {destination} ({count} entries)")
