-- =========================================================
-- ZoneMusic - CLIENT
-- Audio 3D mono, fondu interieur/exterieur et occlusion murs
-- =========================================================

local cfg = ZoneMusic.Config
ZoneMusic.Zones = ZoneMusic.Zones or {}
ZoneMusic.Playing = ZoneMusic.Playing or {}

local VOLUME_CVAR = CreateClientConVar(
    "zonemusic_volume",
    tostring(cfg.DefaultVolume or 1),
    true,
    false,
    "Volume de la musique de zone (0 a 2000 pourcent)"
)

local MAX_DISTANCE = cfg.SoundMaxDistance or 2400
local DOOR_DISTANCE = cfg.DoorTransitionDistance or 350
local EXIT_MARGIN = cfg.ExitMargin or 150
local TRANSITION_SPEED = cfg.TransitionSpeed or 4
local CHECK_INTERVAL = cfg.CheckInterval or 0.1
local RESYNC_INTERVAL = cfg.ResyncInterval or 3
local RESYNC_THRESHOLD = cfg.ResyncThreshold or 0.45
local OCCLUDED_MULTIPLIER = cfg.OccludedOutdoorMultiplier or 0.28

local active = {
    id = nil,
    indoor = nil,
    outdoor = nil,
    single = false,
    single3D = false,
    token = 0,
    position = nil,
    indoorVolume = 0,
    outdoorVolume = 0,
    targetIndoor = 0,
    targetOutdoor = 0,
    endSent = false
}

local function validChannel(channel)
    return channel ~= nil and IsValid(channel)
end

local function stopChannel(channel)
    if validChannel(channel) then
        pcall(channel.Stop, channel)
    end
end

local function safeCall(channel, method, ...)
    if not validChannel(channel) or not isfunction(channel[method]) then return false end
    return pcall(channel[method], channel, ...)
end

local function stopActive()
    active.token = active.token + 1
    stopChannel(active.indoor)
    if active.outdoor ~= active.indoor then stopChannel(active.outdoor) end

    active.id = nil
    active.indoor = nil
    active.outdoor = nil
    active.single = false
    active.single3D = false
    active.position = nil
    active.indoorVolume = 0
    active.outdoorVolume = 0
    active.targetIndoor = 0
    active.targetOutdoor = 0
    active.endSent = false
end

local function reportTrackEnded()
    if not active.id or active.endSent then return end
    active.endSent = true
    net.Start("ZoneMusic_TrackEnded")
    net.WriteString(tostring(active.id))
    net.SendToServer()
end

local function smoothStep(value)
    value = math.Clamp(value, 0, 1)
    return value * value * (3 - 2 * value)
end

local function getZoneCenter(zone)
    return Vector(
        (zone.min.x + zone.max.x) * 0.5,
        (zone.min.y + zone.max.y) * 0.5,
        (zone.min.z + zone.max.z) * 0.5
    )
end

local function getClosestPoint(pos, zone)
    return Vector(
        math.Clamp(pos.x, zone.min.x, zone.max.x),
        math.Clamp(pos.y, zone.min.y, zone.max.y),
        math.Clamp(pos.z, zone.min.z, zone.max.z)
    )
end

local function getDistanceToZone(pos, zone)
    return pos:Distance(getClosestPoint(pos, zone))
end

local function findBestZone(pos)
    local bestID, bestDistance
    bestDistance = math.huge

    for id, zone in pairs(ZoneMusic.Zones) do
        if ZoneMusic.Playing[id] and zone.min and zone.max then
            local distance = getDistanceToZone(pos, zone)
            if distance <= MAX_DISTANCE + EXIT_MARGIN and distance < bestDistance then
                bestID, bestDistance = id, distance
            end
        end
    end

    return bestID, bestDistance
end

local function calculateVolumes(distance)
    local transition = smoothStep(distance / math.max(DOOR_DISTANCE, 1))
    local indoor = 1 - transition
    local outdoorFade = 1 - smoothStep(distance / math.max(MAX_DISTANCE, 1))
    local outdoor = transition * outdoorFade
    return indoor, outdoor
end

local function hasOccludingWall(ply, zone)
    if not IsValid(ply) then return false end

    local startPos = ply:EyePos()
    local targetPos = getZoneCenter(zone)
    local trace = util.TraceLine({
        start = startPos,
        endpos = targetPos,
        filter = ply,
        mask = MASK_SOLID
    })

    return trace.Hit and not trace.HitSky
end

local function expectedTrackTime(track)
    local reference = track.paused and (tonumber(track.pausedAt) or CurTime()) or CurTime()
    return math.max(0, reference - (tonumber(track.start) or reference))
end

local function configure3D(channel, position, enabled)
    if not validChannel(channel) then return false end

    enabled = enabled == true
    safeCall(channel, "Set3DEnabled", enabled)

    if not enabled then return true end

    local positioned = safeCall(channel, "SetPos", position)
    safeCall(channel, "Set3DFadeDistance", 0, MAX_DISTANCE * 1.5)
    return positioned
end

local function createChannel(url, token, callback, spatial3D)
    local flags = spatial3D and "3d noblock noplay" or "noblock noplay"
    sound.PlayURL(url, flags, function(channel, errID, errName)
        if token ~= active.token then
            stopChannel(channel)
            return
        end

        if not validChannel(channel) then
            print("[ZoneMusic] Echec du chargement audio : " .. tostring(errName or errID))
            callback(nil)
            return
        end

        callback(channel)
    end)
end

local function startZone(id)
    local track = ZoneMusic.Playing[id]
    local zone = ZoneMusic.Zones[id]

    if not track or not zone then
        stopActive()
        return
    end

    stopActive()
    active.id = id
    local token = active.token

    local indoorURL = track.url
    local outdoorURL = track.outdoor_url or track.url
    local position = getZoneCenter(zone)
    active.position = position

    local single = indoorURL == outdoorURL
    active.single = single

    local pending = single and 1 or 2
    local completed = false
    local indoorFailed = false

    local function finishLoading()
        if completed or pending > 0 then return end
        completed = true
        if token ~= active.token then return end

        if indoorFailed or not validChannel(active.indoor) then
            stopActive()
            chat.AddText(Color(255, 100, 100), "[Musique] Impossible de charger la musique.")
            return
        end

        if not active.single and not validChannel(active.outdoor) then
            active.single = true
            print("[ZoneMusic] Version exterieure indisponible : version interieure conservee.")
        end

        local current = ZoneMusic.Playing[id]
        if not current then
            stopActive()
            return
        end

        local expected = expectedTrackTime(current)
        if current.duration and current.duration > 0 and expected >= current.duration then
            stopActive()
            return
        end

        local channels = { active.indoor }
        if not active.single then table.insert(channels, active.outdoor) end

        for _, channel in ipairs(channels) do
            if validChannel(channel) then
                local length = channel:GetLength()
                if length > 0 and expected >= length then
                    if (tonumber(current.duration) or 0) <= 0 then reportTrackEnded() end
                    stopActive()
                    return
                end

                local ok = pcall(function()
                    channel:SetTime(expected)
                    channel:SetVolume(0)
                    channel:Play()
                    if current.paused and isfunction(channel.Pause) then
                        channel:Pause()
                    end
                end)

                if not ok then
                    stopActive()
                    chat.AddText(Color(255, 100, 100), "[Musique] Impossible de synchroniser la lecture.")
                    return
                end
            end
        end

        chat.AddText(Color(120, 200, 255), "[Musique] ", color_white, current.title or "Lecture en cours")
    end

    local function channelReady(kind, channel)
        if token ~= active.token then
            stopChannel(channel)
            return
        end

        pending = pending - 1

        if not channel then
            if kind == "indoor" then indoorFailed = true else active.single = true end
            finishLoading()
            return
        end

        if kind == "indoor" then active.indoor = channel else active.outdoor = channel end
        configure3D(channel, position, kind == "outdoor")
        finishLoading()
    end

    createChannel(indoorURL, token, function(channel)
        channelReady("indoor", channel)
    end, false)

    if not single then
        createChannel(outdoorURL, token, function(channel)
            channelReady("outdoor", channel)
        end, true)
    end
end

timer.Remove("ZoneMusic_Check")
timer.Create("ZoneMusic_Check", CHECK_INTERVAL, 0, function()
    local ply = LocalPlayer()
    if not IsValid(ply) then return end

    local playerPos = ply:GetPos()
    local id, distance = findBestZone(playerPos)

    if not id then
        if active.id then stopActive() end
        return
    end

    if active.id ~= id then
        startZone(id)
        return
    end

    if not validChannel(active.indoor) then return end

    local zone = ZoneMusic.Zones[id]
    local indoor, outdoor = calculateVolumes(distance)
    local userVolume = math.Clamp(VOLUME_CVAR:GetFloat(), 0, cfg.MaxVolume or 20)

    if active.single then
        -- Une seule URL : 2D a l'interieur, 3D a l'exterieur.
        local shouldBe3D = distance > 1
        if active.single3D ~= shouldBe3D then
            active.single3D = shouldBe3D
            configure3D(active.indoor, active.position, shouldBe3D)
        end

        active.targetIndoor = math.max(indoor, outdoor) * userVolume
        active.targetOutdoor = 0
    else
        if outdoor > 0 and hasOccludingWall(ply, zone) then
            outdoor = outdoor * OCCLUDED_MULTIPLIER
        end

        active.targetIndoor = indoor * userVolume
        active.targetOutdoor = outdoor * userVolume
    end

    local delta = math.Clamp(FrameTime() * TRANSITION_SPEED, 0, 1)
    active.indoorVolume = Lerp(delta, active.indoorVolume, active.targetIndoor)
    active.outdoorVolume = Lerp(delta, active.outdoorVolume, active.targetOutdoor)

    if validChannel(active.indoor) then
        active.indoor:SetVolume(math.Clamp(active.indoorVolume, 0, cfg.MaxVolume or 20))
    end

    if not active.single and validChannel(active.outdoor) then
        active.outdoor:SetVolume(math.Clamp(active.outdoorVolume, 0, cfg.MaxVolume or 20))
    end
end)

timer.Remove("ZoneMusic_Resync")
timer.Create("ZoneMusic_Resync", RESYNC_INTERVAL, 0, function()
    if not active.id then return end

    local track = ZoneMusic.Playing[active.id]
    if not track then
        stopActive()
        return
    end

    local expected = expectedTrackTime(track)
    if track.duration and track.duration > 0 and expected >= track.duration then
        stopActive()
        return
    end

    local channels = { active.indoor }
    if not active.single then table.insert(channels, active.outdoor) end

    for _, channel in ipairs(channels) do
        if validChannel(channel) then
            local length = channel:GetLength()
            if length > 0 and expected >= length then
                if (tonumber(track.duration) or 0) <= 0 then reportTrackEnded() end
                stopActive()
                return
            end

            local actual = channel:GetTime()
            if math.abs(actual - expected) > RESYNC_THRESHOLD then
                pcall(channel.SetTime, channel, expected)
            end
        end
    end
end)

net.Receive("ZoneMusic_Zones", function()
    ZoneMusic.Zones = net.ReadTable() or {}

    if active.id then
        if not ZoneMusic.Zones[active.id] then
            stopActive()
        elseif ZoneMusic.Playing[active.id] then
            startZone(active.id) -- Repositionne les canaux si la zone a ete modifiee.
        end
    end
end)

net.Receive("ZoneMusic_Play", function()
    local id = net.ReadString()
    local url = net.ReadString()
    local outdoorURL = net.ReadString()
    local title = net.ReadString()
    local start = net.ReadFloat()
    local duration = net.ReadFloat()
    local thumbnail = net.ReadString()
    local requester = net.ReadString()
    local paused = net.ReadBool()
    local pausedAt = net.ReadFloat()

    ZoneMusic.Playing[id] = {
        url = url,
        outdoor_url = outdoorURL,
        title = title,
        start = start,
        duration = duration,
        thumbnail = thumbnail,
        requester = requester,
        paused = paused,
        pausedAt = pausedAt > 0 and pausedAt or nil
    }

    if active.id == id then startZone(id) end
end)

ZoneMusic.QueueState = ZoneMusic.QueueState or {}

net.Receive("ZoneMusic_Queue", function()
    local id = net.ReadString()
    ZoneMusic.QueueState[id] = net.ReadTable() or {}
end)

net.Receive("ZoneMusic_Stop", function()
    local id = net.ReadString()
    ZoneMusic.Playing[id] = nil
    if active.id == id then stopActive() end
end)

net.Receive("ZoneMusic_Volume", function()
    local value = math.Clamp(net.ReadUInt(11), 0, 2000)
    RunConsoleCommand("zonemusic_volume", tostring(value / 100))
end)

hook.Remove("ShutDown", "ZoneMusic_Cleanup")
hook.Add("ShutDown", "ZoneMusic_Cleanup", function()
    stopActive()
    timer.Remove("ZoneMusic_Check")
    timer.Remove("ZoneMusic_Resync")
end)


-- =========================================================
-- ZoneMusic - APERCU DES ZONES ET WIDGET HUD
-- =========================================================

local ZoneMusicBoundsPreview = {
    pos1 = nil,
    pos2 = nil
}

net.Receive("ZoneMusic_BoundsPreview", function()
    if not net.ReadBool() then
        ZoneMusicBoundsPreview.pos1 = nil
        ZoneMusicBoundsPreview.pos2 = nil
        return
    end

    ZoneMusicBoundsPreview.pos1 = net.ReadVector()

    if net.ReadBool() then
        ZoneMusicBoundsPreview.pos2 = net.ReadVector()
    else
        ZoneMusicBoundsPreview.pos2 = nil
    end
end)

-- Apercu 3D de la future zone : volume translucide et grille.
hook.Remove("PostDrawTranslucentRenderables", "ZoneMusic_BoundsPreview")
hook.Add("PostDrawTranslucentRenderables", "ZoneMusic_BoundsPreview",
function(depth, skybox)
    if skybox then return end

    local p1 = ZoneMusicBoundsPreview.pos1
    if not p1 then return end

    local p2 = ZoneMusicBoundsPreview.pos2

    if not p2 then
        -- Apres POS1 : petit repere lumineux.
        render.SetColorMaterial()
        render.DrawBox(
            p1,
            angle_zero,
            Vector(-12, -12, 0),
            Vector(12, 12, 24),
            Color(50, 190, 255, 90)
        )
        render.DrawWireframeBox(
            p1,
            angle_zero,
            Vector(-14, -14, -2),
            Vector(14, 14, 26),
            Color(90, 220, 255, 255),
            true
        )
        return
    end

    local mn = Vector(
        math.min(p1.x, p2.x),
        math.min(p1.y, p2.y),
        math.min(p1.z, p2.z)
    )

    local mx = Vector(
        math.max(p1.x, p2.x),
        math.max(p1.y, p2.y),
        math.max(p1.z, p2.z)
    )

    local center = (mn + mx) * 0.5
    local localMin = mn - center
    local localMax = mx - center

    render.SetColorMaterial()

    -- Volume translucide.
    render.DrawBox(
        center,
        angle_zero,
        localMin,
        localMax,
        Color(35, 155, 230, 12)
    )

    -- Contour exterieur.
    render.DrawWireframeBox(
        center,
        angle_zero,
        localMin,
        localMax,
        Color(65, 195, 255, 245),
        true
    )

    -- Grille au sol, style construction Minecraft.
    local sizeX = mx.x - mn.x
    local sizeY = mx.y - mn.y
    local step = math.max(
        128,
        math.ceil(math.max(sizeX, sizeY) / 30 / 128) * 128
    )

    local gridColor = Color(60, 175, 235, 105)
    local floorZ = mn.z + 3

    for x = math.ceil(mn.x / step) * step, mx.x, step do
        render.DrawLine(
            Vector(x, mn.y, floorZ),
            Vector(x, mx.y, floorZ),
            gridColor,
            true
        )
    end

    for y = math.ceil(mn.y / step) * step, mx.y, step do
        render.DrawLine(
            Vector(mn.x, y, floorZ),
            Vector(mx.x, y, floorZ),
            gridColor,
            true
        )
    end

    -- Marqueurs des deux positions.
    render.DrawWireframeBox(
        p1,
        angle_zero,
        Vector(-10, -10, -10),
        Vector(10, 10, 10),
        Color(70, 255, 150, 255),
        true
    )

    render.DrawWireframeBox(
        p2,
        angle_zero,
        Vector(-10, -10, -10),
        Vector(10, 10, 10),
        Color(255, 180, 65, 255),
        true
    )
end)


-- =========================================================
-- ZONEMUSIC V3 - LECTEUR STYLE SPOTIFY (interface HTML)
-- Interface uniquement : le moteur audio au-dessus est inchange.
-- F3 : activer / desactiver la souris sur le lecteur.
-- =========================================================

local ZM_Player
local ZM_HTML
local ZM_Expanded = false
local ZM_CursorEnabled = false
local ZM_F3WasDown = false
local ZM_Alpha = 0
local ZM_HUDZoneID
local ZM_NextPush = 0
local ZM_Ready = false
local ZM_MutedVolume
local ZM_FFT = {}

local MINI_W, MINI_H = 440, 96
local FULL_W, FULL_H = 440, 640

local function ZM_VoteCount(action)
    local state = ZM_HUDZoneID and ZoneMusic.QueueState and ZoneMusic.QueueState[ZM_HUDZoneID]
    local votes = state and state.votes and state.votes[action] or {}
    local n = 0
    for _ in pairs(votes) do n = n + 1 end
    return n
end

local function ZM_Send(action)
    local id = ZM_HUDZoneID or active.id
    if not id then return end
    net.Start("ZoneMusic_Action")
    net.WriteString(action)
    net.WriteString(tostring(id))
    net.SendToServer()
end

local function ZM_Spectrum()
    local channel = validChannel(active.indoor) and active.indoor
        or (validChannel(active.outdoor) and active.outdoor or nil)
    local bars = {}
    if channel and isfunction(channel.FFT) then
        local ok, count = pcall(channel.FFT, channel, ZM_FFT, FFT_256)
        if ok and (tonumber(count) or 0) > 0 then
            for i = 1, 24 do
                local idx = math.floor(1 + (i - 1) ^ 1.6)
                bars[i] = math.Clamp((ZM_FFT[idx] or 0) * 9, 0, 1)
            end
            return bars
        end
    end
    for i = 1, 24 do bars[i] = 0 end
    return bars
end

local function ZM_State()
    local ply = LocalPlayer()
    local id = ZM_HUDZoneID
    local zone = id and ZoneMusic.Zones[id]
    local track = id and ZoneMusic.Playing[id]
    local qs = id and ZoneMusic.QueueState and ZoneMusic.QueueState[id] or {}

    local current, duration = 0, 0
    if track then
        current = expectedTrackTime(track)
        duration = tonumber(track.duration) or 0
        if active.id == id then
            local ch = validChannel(active.indoor) and active.indoor
                or (validChannel(active.outdoor) and active.outdoor or nil)
            if ch then
                local ok, r = pcall(ch.GetTime, ch)
                if ok and tonumber(r) then current = r end
                ok, r = pcall(ch.GetLength, ch)
                if ok and tonumber(r) and r > 0 then duration = r end
            end
        end
    end

    local queue = {}
    for i, item in ipairs(qs.queue or {}) do
        queue[i] = {
            title = tostring(item.title or "Musique"),
            requester = tostring(item.requester or "Inconnu"),
            thumbnail = tostring(item.thumbnail or ""),
            duration = tonumber(item.duration) or 0
        }
    end
    local history = {}
    for i, item in ipairs(qs.history or {}) do
        history[i] = {title = tostring(item.title or ""), requester = tostring(item.requester or "")}
    end

    return {
        zone = zone and zone.name or "",
        expanded = ZM_Expanded,
        cursor = ZM_CursorEnabled,
        superadmin = IsValid(ply) and ply:IsSuperAdmin() or false,
        track = track and {
            title = tostring(track.title or "Musique"),
            requester = tostring(track.requester or "Inconnu"),
            thumbnail = tostring(track.thumbnail or ""),
            paused = track.paused == true,
            current = current,
            duration = duration
        } or false,
        volume = math.floor(VOLUME_CVAR:GetFloat() * 100 + 0.5),
        maxVolume = math.floor((cfg.MaxVolume or 20) * 100),
        votes = {skip = ZM_VoteCount("skip"), previous = ZM_VoteCount("previous")},
        queue = queue,
        history = history,
        spectrum = ZM_Spectrum()
    }
end

local ZM_PAGE = [==[
<!DOCTYPE html><html><head><meta charset="utf-8">
<link href="https://fonts.googleapis.com/css2?family=Montserrat:wght@500;700;800;900&display=swap" rel="stylesheet">
<style>
*{box-sizing:border-box;margin:0;padding:0;user-select:none}
html,body{background:transparent;overflow:hidden;font-family:Montserrat,'Segoe UI',Arial,sans-serif;color:#fff}
:root{--g:#1ed760;--g2:#1db954;--bg:#121212;--card:#181818;--mut:#b3b3b3;--line:rgba(255,255,255,.1)}
#p{position:absolute;inset:0;margin:6px;border-radius:18px;overflow:hidden;background:var(--bg);
 box-shadow:0 18px 40px rgba(0,0,0,.6),0 0 0 1px rgba(255,255,255,.06)}
#bgart{position:absolute;inset:-40px;background-size:cover;background-position:center;filter:blur(40px) saturate(1.6);opacity:.55;transition:background-image .6s}
#shade{position:absolute;inset:0;background:linear-gradient(180deg,rgba(18,18,18,.25) 0%,rgba(18,18,18,.85) 55%,#121212 100%)}
#c{position:relative;height:100%;display:flex;flex-direction:column}
/* mini */
#mini{display:flex;align-items:center;gap:12px;padding:12px 14px;height:84px;flex:none}
.art{background:#282828 center/cover no-repeat;border-radius:8px;box-shadow:0 6px 18px rgba(0,0,0,.5);flex:none;display:flex;align-items:center;justify-content:center;color:#535353;font-size:26px}
#mart{width:60px;height:60px}
.meta{flex:1;min-width:0}
.tag{font-size:10px;font-weight:800;letter-spacing:1.6px;color:var(--g);text-transform:uppercase;display:flex;align-items:center;gap:6px}
.tag .dot{width:6px;height:6px;border-radius:50%;background:var(--g);box-shadow:0 0 8px var(--g);animation:pl 1.4s infinite}
@keyframes pl{50%{opacity:.3}}
.t{font-size:15px;font-weight:800;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:3px}
.s{font-size:12px;color:var(--mut);font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:2px}
#eq{display:flex;align-items:flex-end;gap:2px;height:28px;flex:none}
#eq i{display:block;width:3px;border-radius:2px;background:var(--g);height:3px;transition:height .1s}
.ib{width:34px;height:34px;border-radius:50%;border:none;background:rgba(255,255,255,.07);color:#fff;display:flex;align-items:center;justify-content:center;cursor:pointer;flex:none;transition:.15s}
.ib:hover{background:rgba(255,255,255,.16);transform:scale(1.06)}
.ib svg{width:16px;height:16px;fill:currentColor}
#mbar{position:absolute;left:0;right:0;top:82px;height:2px;background:rgba(255,255,255,.08)}
#mbar div{height:100%;background:var(--g);width:0}
/* full */
#full{flex:1;display:none;flex-direction:column;padding:6px 22px 16px;min-height:0}
.expanded #full{display:flex}
.expanded #mbar{display:none}
#bigart{width:220px;height:220px;margin:6px auto 16px;border-radius:10px;font-size:64px;box-shadow:0 20px 50px rgba(0,0,0,.65)}
#ft{font-size:21px;font-weight:900;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#fs{font-size:13px;color:var(--mut);margin-top:4px}
#prog{margin-top:14px}
#track{position:relative;height:4px;border-radius:4px;background:rgba(255,255,255,.2)}
#fill{position:absolute;left:0;top:0;bottom:0;border-radius:4px;background:#fff;width:0}
#prog:hover #fill{background:var(--g)}
#knob{position:absolute;top:50%;width:12px;height:12px;margin:-6px 0 0 -6px;border-radius:50%;background:#fff;opacity:0;transition:opacity .15s}
#prog:hover #knob{opacity:1}
#times{display:flex;justify-content:space-between;font-size:11px;color:var(--mut);margin-top:6px;font-weight:600}
#ctl{display:flex;align-items:center;justify-content:center;gap:26px;margin-top:6px}
.cb{position:relative;border:none;background:none;color:#b3b3b3;cursor:pointer;display:flex;align-items:center;justify-content:center;transition:.15s}
.cb:hover{color:#fff;transform:scale(1.08)}
.cb svg{width:22px;height:22px;fill:currentColor}
.cb .v{position:absolute;top:-6px;right:-12px;font-size:9px;font-weight:800;background:var(--g);color:#000;border-radius:8px;padding:1px 5px;display:none}
#play{width:54px;height:54px;border-radius:50%;background:#fff;color:#000}
#play:hover{transform:scale(1.07);background:#fff;color:#000}
#play svg{width:24px;height:24px}
#play.dis{opacity:.35;pointer-events:none}
#vol{display:flex;align-items:center;gap:10px;margin-top:14px}
#vol input{flex:1;-webkit-appearance:none;height:4px;border-radius:4px;background:linear-gradient(90deg,var(--g) var(--p,30%),rgba(255,255,255,.2) var(--p,30%));outline:none}
#vol input::-webkit-slider-thumb{-webkit-appearance:none;width:12px;height:12px;border-radius:50%;background:#fff;cursor:pointer}
#vv{font-size:11px;color:var(--mut);width:44px;text-align:right;font-weight:700}
#qh{display:flex;justify-content:space-between;align-items:baseline;margin-top:16px;padding-top:12px;border-top:1px solid var(--line)}
#qh b{font-size:14px;font-weight:800}
#qh span{font-size:11px;color:var(--mut);font-weight:600}
#q{flex:1;overflow-y:auto;margin-top:8px;min-height:0}
#q::-webkit-scrollbar{width:5px}#q::-webkit-scrollbar-thumb{background:#535353;border-radius:4px}
.row{display:flex;align-items:center;gap:10px;padding:6px 8px;border-radius:6px}
.row:hover{background:rgba(255,255,255,.08)}
.row .n{width:16px;font-size:12px;color:var(--mut);text-align:right;font-weight:600}
.row .art{width:40px;height:40px;border-radius:4px;font-size:16px}
.row .meta .t{font-size:13px;margin:0}
.row .d{font-size:11px;color:var(--mut)}
.empty{color:var(--mut);font-size:12px;text-align:center;padding:16px}
.hint{font-size:10px;color:#6a6a6a;text-align:center;margin-top:8px}
.hint b{color:var(--mut)}
</style></head><body>
<div id="p"><div id="bgart"></div><div id="shade"></div><div id="c">
 <div id="mini">
  <div id="mart" class="art">&#9835;</div>
  <div class="meta"><div class="tag"><span class="dot"></span><span id="zn">Zone Music</span></div>
   <div class="t" id="mt">Aucune musique</div><div class="s" id="ms">Tape /music &lt;titre ou lien&gt;</div></div>
  <div id="eq"></div>
  <button class="ib" id="tog" onclick="zm.toggle()"><svg viewBox="0 0 24 24" id="togi"><path d="M7 10l5 5 5-5z"/></svg></button>
 </div>
 <div id="mbar"><div id="mfill"></div></div>
 <div id="full">
  <div id="bigart" class="art">&#9835;</div>
  <div id="ft">Aucune musique</div><div id="fs">&nbsp;</div>
  <div id="prog"><div id="track"><div id="fill"></div><div id="knob"></div></div>
   <div id="times"><span id="tc">0:00</span><span id="td">--:--</span></div></div>
  <div id="ctl">
   <button class="cb" onclick="zm.action('previous')" title="Voter : precedent"><svg viewBox="0 0 24 24"><path d="M6 6h2v12H6zm3.5 6l8.5 6V6z"/></svg><span class="v" id="vp"></span></button>
   <button class="cb" id="play" onclick="zm.action(S.track&&S.track.paused?'resume':'pause')"><svg viewBox="0 0 24 24" id="pi"></svg></button>
   <button class="cb" onclick="zm.action('skip')" title="Voter : passer"><svg viewBox="0 0 24 24"><path d="M6 18l8.5-6L6 6v12zM16 6v12h2V6h-2z"/></svg><span class="v" id="vs"></span></button>
  </div>
  <div id="vol">
   <button class="ib" onclick="zm.mute()" style="width:28px;height:28px;background:none"><svg viewBox="0 0 24 24" id="vi"></svg></button>
   <input type="range" id="vr" min="0" max="2000" step="5" oninput="volIn(this.value)">
   <span id="vv">100%</span>
  </div>
  <div id="qh"><b>File d'attente</b><span id="qc">0 titre</span></div>
  <div id="q"></div>
  <div class="hint"><b>F3</b> pour activer / couper la souris &middot; votes : precedent / passer</div>
 </div>
</div></div>
<script>
var S={},dragging=0,lastArt=null,lastQ=null;
var IC={play:'<path d="M8 5v14l11-7z"/>',pause:'<path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z"/>',
 von:'<path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3A4.5 4.5 0 0014 8v8a4.5 4.5 0 002.5-4zM14 3.2v2.1a7 7 0 010 13.4v2.1a9 9 0 000-17.6z"/>',
 voff:'<path d="M16.5 12A4.5 4.5 0 0014 8v2.2l2.45 2.45c.03-.2.05-.42.05-.65zM19 12c0 .94-.2 1.82-.54 2.64l1.51 1.51A8.8 8.8 0 0021 12a9 9 0 00-7-8.77v2.06A7 7 0 0119 12zM4.27 3L3 4.27 7.73 9H3v6h4l5 5v-6.73l4.25 4.25c-.67.52-1.42.93-2.25 1.18v2.06a9 9 0 003.69-1.81L19.73 21 21 19.73l-9-9L4.27 3zM12 4L9.91 6.09 12 8.18V4z"/>',
 down:'<path d="M7 10l5 5 5-5z"/>',up:'<path d="M7 14l5-5 5 5z"/>'};
var eq=document.getElementById('eq');for(var i=0;i<12;i++)eq.appendChild(document.createElement('i'));
function $(i){return document.getElementById(i)}
function esc(s){return String(s==null?'':s).replace(/[&<>"']/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]})}
function fmt(v){v=Math.max(0,Math.floor(v||0));return Math.floor(v/60)+':'+('0'+v%60).slice(-2)}
function img(el,url){if(/^https?:\/\//.test(url||'')){el.style.backgroundImage='url("'+url.replace(/"/g,'%22')+'")';el.innerHTML=''}else{el.style.backgroundImage='';el.innerHTML='&#9835;'}}
function volIn(v){dragging=Date.now();paintVol(v);zm.volume(Number(v))}
function paintVol(v){var r=$('vr');r.value=v;r.style.setProperty('--p',(v/r.max*100)+'%');$('vv').textContent=v+'%';$('vi').innerHTML=v>0?IC.von:IC.voff}
function U(s){S=s;var t=s.track;
 document.body.className=s.expanded?'expanded':'';
 $('togi').innerHTML=s.expanded?IC.up:IC.down;
 $('zn').textContent=s.zone||'Zone Music';
 var art=t?t.thumbnail:'';
 if(art!==lastArt){lastArt=art;img($('mart'),art);img($('bigart'),art);
  $('bgart').style.backgroundImage=/^https?:/.test(art)?'url("'+art.replace(/"/g,'%22')+'")':'none'}
 $('mt').textContent=t?t.title:'Aucune musique';$('ft').textContent=t?t.title:'Aucune musique en cours';
 $('ms').textContent=t?(t.paused?'En pause \u00b7 ':'')+'Demand\u00e9e par '+t.requester:'Tape /music <titre ou lien>';
 $('fs').textContent=t?'Demand\u00e9e par '+t.requester:'La zone attend sa premi\u00e8re musique';
 var pct=t&&t.duration>0?Math.min(1,t.current/t.duration)*100:0;
 $('fill').style.width=pct+'%';$('knob').style.left=pct+'%';$('mfill').style.width=pct+'%';
 $('tc').textContent=fmt(t?t.current:0);$('td').textContent=t&&t.duration>0?fmt(t.duration):'--:--';
 $('pi').innerHTML=t&&t.paused?IC.play:IC.pause;
 $('play').className='cb'+(s.superadmin&&t?'':' dis');$('play').title=s.superadmin?'Pause / lecture':'R\u00e9serv\u00e9 aux SuperAdmins';
 var vp=$('vp'),vs=$('vs');vp.textContent=s.votes.previous;vp.style.display=s.votes.previous>0?'block':'none';
 vs.textContent=s.votes.skip;vs.style.display=s.votes.skip>0?'block':'none';
 $('vr').max=s.maxVolume;if(Date.now()-dragging>800)paintVol(s.volume);
 var bars=eq.children,sp=s.spectrum||[];for(var i=0;i<bars.length;i++){var v=(sp[i*2]||0)+(sp[i*2+1]||0);bars[i].style.height=(3+Math.min(1,v)*25)+'px'}
 eq.style.opacity=t&&!t.paused?1:.3;
 var qk=JSON.stringify(s.queue);if(qk!==lastQ){lastQ=qk;var h='';
  $('qc').textContent=s.queue.length+(s.queue.length>1?' titres':' titre');
  if(!s.queue.length)h='<div class="empty">Rien \u00e0 suivre. Ajoute un son avec /music</div>';
  s.queue.forEach(function(q,i){var a=/^https?:/.test(q.thumbnail)?' style="background-image:url(&quot;'+esc(q.thumbnail)+'&quot;)">':'>&#9835;';
   h+='<div class="row"><span class="n">'+(i+1)+'</span><div class="art"'+a+'</div><div class="meta"><div class="t">'+esc(q.title)+'</div><div class="s">'+esc(q.requester)+'</div></div><span class="d">'+(q.duration>0?fmt(q.duration):'')+'</span></div>'});
  $('q').innerHTML=h}
}
</script></body></html>
]==]

local function ZM_Push()
    if not ZM_Ready or not IsValid(ZM_HTML) then return end
    local json = util.TableToJSON(ZM_State()) or "{}"
    ZM_HTML:RunJavascript("if(window.U)U(" .. json .. ");")
end

local ZM_InputState = nil
local ZM_ClickerOwned = false

-- Applique l'etat souris uniquement quand il change (evite de casser F4 / autres menus).
local function ZM_SetInput(enabled)
    enabled = enabled == true
    if ZM_InputState == enabled then return end
    ZM_InputState = enabled

    if IsValid(ZM_Player) then
        ZM_Player:SetMouseInputEnabled(enabled)
        ZM_Player:SetKeyboardInputEnabled(false)
    end
    if IsValid(ZM_HTML) then
        ZM_HTML:SetMouseInputEnabled(enabled)
        ZM_HTML:SetKeyboardInputEnabled(false)
    end

    if enabled then
        gui.EnableScreenClicker(true)
        ZM_ClickerOwned = true
        if IsValid(ZM_Player) then ZM_Player:MoveToFront() end
    elseif ZM_ClickerOwned then
        gui.EnableScreenClicker(false)
        ZM_ClickerOwned = false
    end
    ZM_NextPush = 0
end

local function ZM_ToggleCursor()
    if not ZM_HUDZoneID or not IsValid(ZM_Player) then
        ZM_CursorEnabled = false
        ZM_SetInput(false)
        return
    end
    ZM_CursorEnabled = not ZM_CursorEnabled
    ZM_SetInput(ZM_CursorEnabled)
end

local function ZM_CreatePlayer()
    if IsValid(ZM_Player) then ZM_Player:Remove() end
    ZM_Expanded, ZM_CursorEnabled, ZM_Ready, ZM_InputState = false, false, false, nil

    -- Panneau racine (PAS ParentToHUD : un panneau du HUD ne recoit jamais les clics).
    ZM_Player = vgui.Create("DPanel")
    ZM_Player:SetSize(MINI_W, MINI_H)
    ZM_Player:SetPos(ScrW() - MINI_W - 16, 16)
    ZM_Player:SetPaintBackground(false)
    ZM_Player:SetAlpha(0)
    ZM_Player:SetVisible(false)

    ZM_HTML = vgui.Create("DHTML", ZM_Player)
    ZM_HTML:Dock(FILL)
    ZM_HTML:SetAllowLua(false)

    ZM_HTML:AddFunction("zm", "toggle", function()
        ZM_Expanded = not ZM_Expanded
        ZM_NextPush = 0
    end)
    ZM_HTML:AddFunction("zm", "action", function(action)
        action = tostring(action or "")
        if action == "skip" or action == "previous" or action == "pause" or action == "resume" then
            ZM_Send(action)
        end
    end)
    ZM_HTML:AddFunction("zm", "volume", function(value)
        value = math.Clamp((tonumber(value) or 100) / 100, 0, cfg.MaxVolume or 20)
        RunConsoleCommand("zonemusic_volume", tostring(value))
    end)
    ZM_HTML:AddFunction("zm", "mute", function()
        if VOLUME_CVAR:GetFloat() > 0 then
            ZM_MutedVolume = VOLUME_CVAR:GetFloat()
            RunConsoleCommand("zonemusic_volume", "0")
        else
            RunConsoleCommand("zonemusic_volume", tostring(ZM_MutedVolume or cfg.DefaultVolume or 1))
        end
        ZM_NextPush = 0
    end)

    ZM_HTML.OnDocumentReady = function()
        ZM_Ready = true
        ZM_NextPush = 0
    end
    ZM_HTML:SetHTML(ZM_PAGE)
    ZM_SetInput(false)
end

-- Logique dans un hook global : le Think d'un panneau cache ne s'execute plus,
-- ce qui empechait le lecteur de reapparaitre et F3 de fonctionner.
hook.Remove("Think", "ZoneMusic_PlayerThink")
hook.Add("Think", "ZoneMusic_PlayerThink", function()
    if not IsValid(ZM_Player) then return end
    local ply = LocalPlayer()
    if not IsValid(ply) then return end

    -- Zone actuelle (petite marge de sortie pour eviter le clignotement en bordure).
    local pos = ply:GetPos()
    local found
    if ZM_HUDZoneID and ZoneMusic.Zones[ZM_HUDZoneID] then
        local z = ZoneMusic.Zones[ZM_HUDZoneID]
        if pos:WithinAABox(z.min - Vector(24, 24, 24), z.max + Vector(24, 24, 24)) and ply:Alive() then
            found = ZM_HUDZoneID
        end
    end
    if not found and ply:Alive() then
        for id, zone in pairs(ZoneMusic.Zones or {}) do
            if ZoneMusic.IsInZone(pos, zone) then found = id break end
        end
    end
    if found ~= ZM_HUDZoneID then
        ZM_HUDZoneID = found
        ZM_NextPush = 0
    end

    local visible = ZM_HUDZoneID ~= nil

    -- Sortie de zone : on coupe la souris et on referme le lecteur.
    if not visible and (ZM_CursorEnabled or ZM_Expanded) then
        ZM_CursorEnabled = false
        ZM_Expanded = false
        ZM_SetInput(false)
    end

    -- F3 (front montant), ignore si chat / console / menu ouvert.
    local f3 = input.IsKeyDown(KEY_F3)
    if f3 and not ZM_F3WasDown and visible and not gui.IsGameUIVisible()
        and not vgui.GetKeyboardFocus() then
        ZM_ToggleCursor()
    end
    ZM_F3WasDown = f3

    -- Si un autre menu a coupe le curseur, on se resynchronise.
    if ZM_CursorEnabled and not vgui.CursorVisible() then
        ZM_CursorEnabled = false
        ZM_ClickerOwned = false
        ZM_InputState = nil
        ZM_SetInput(false)
    end

    ZM_Alpha = Lerp(math.Clamp(FrameTime() * 8, 0, 1), ZM_Alpha, visible and 255 or 0)
    if visible and ZM_Alpha > 253 then ZM_Alpha = 255 end
    if not visible and ZM_Alpha < 2 then ZM_Alpha = 0 end
    ZM_Player:SetAlpha(ZM_Alpha)
    ZM_Player:SetVisible(ZM_Alpha > 0)

    local w = math.min(ZM_Expanded and FULL_W or MINI_W, ScrW() - 20)
    local targetH = math.min(ZM_Expanded and FULL_H or MINI_H, ScrH() - 40)
    local h = Lerp(math.Clamp(FrameTime() * 12, 0, 1), ZM_Player:GetTall(), targetH)
    if math.abs(h - targetH) < 1 then h = targetH end
    ZM_Player:SetSize(w, math.floor(h))
    ZM_Player:SetPos(ScrW() - w - 16, 16)

    if visible and RealTime() >= ZM_NextPush then
        ZM_NextPush = RealTime() + 0.1
        ZM_Push()
    end
end)

-- Alternative a F3 : bind <touche> zonemusic_cursor
concommand.Add("zonemusic_cursor", function() ZM_ToggleCursor() end)

timer.Remove("ZoneMusic_CreatePlayer")
timer.Create("ZoneMusic_CreatePlayer", 1, 0, function()
    if not IsValid(LocalPlayer()) then return end
    if IsValid(ZM_Player) then timer.Remove("ZoneMusic_CreatePlayer") return end
    local ok, err = pcall(ZM_CreatePlayer)
    if ok and IsValid(ZM_Player) then
        timer.Remove("ZoneMusic_CreatePlayer")
        print("[ZoneMusic] Lecteur initialise.")
    elseif not ok then
        print("[ZoneMusic] Erreur lecteur : " .. tostring(err))
    end
end)

hook.Remove("ShutDown", "ZoneMusic_PlayerCleanup")
hook.Add("ShutDown", "ZoneMusic_PlayerCleanup", function()
    if ZM_ClickerOwned then gui.EnableScreenClicker(false) end
    if IsValid(ZM_Player) then ZM_Player:Remove() end
end)

print("[ZoneMusic] Interface style Spotify chargee.")
