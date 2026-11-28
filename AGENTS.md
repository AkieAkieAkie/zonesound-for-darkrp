# Architecture
- Keep Garry's Mod audio and network authority in the Lua addon; this repository is not a web app.
- Validate music administration on the game server with the configured admin predicate and zone membership; client visibility is not authorization.
- Identify queued tracks with server-issued IDs so deletion cannot target another track after a queue change.
- Send per-zone shared volume through queue state and apply it as a multiplier of personal volume to preserve each listener's mute setting.
- Confirm destructive player actions with a native game dialog, not a browser dialog, so embedded HTML cannot suppress confirmation.
- Exercise control regressions with isolated Lua game-API stubs; real audio and game rendering still need in-game verification.