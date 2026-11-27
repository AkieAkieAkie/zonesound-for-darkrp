# Architecture
- Keep Garry's Mod audio and network authority in the Lua addon; this repository is not a web app.
- Validate music administration on the game server with the configured admin predicate and zone membership; client visibility is not authorization.
- Identify queued tracks with server-issued IDs so deletion cannot target another track after a queue change.
- Send per-zone shared volume through queue state and apply it as a multiplier of personal volume to preserve each listener's mute setting.