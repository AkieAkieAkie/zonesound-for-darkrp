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
-- =========================================================
-- ZONEMUSIC V2 - MODERN CLUB PLAYER
-- Interface uniquement : moteur audio conserve
-- =========================================================

surface.CreateFont("ZM2_Title", {
    font = "Montserrat", size = 21, weight = 900, extended = true
})
surface.CreateFont("ZM2_Sub", {
    font = "Montserrat", size = 12, weight = 700, extended = true
})
surface.CreateFont("ZM2_Text", {
    font = "Montserrat", size = 15, weight = 700, extended = true
})
surface.CreateFont("ZM2_Button", {
    font = "Montserrat", size = 11, weight = 900, extended = true
})
surface.CreateFont("ZM2_Big", {
    font = "Arial", size = 28, weight = 900
})

local ZM_Player
local ZM_PlayerExpanded = false
local ZM_CursorEnabled = false
local ZM_F3WasDown = false
local ZM_PlayerHeight = 92
local ZM_PlayerAlpha = 0
local ZM_HUDZoneID
local ZM_Cover
local ZM_LastCover = ""
local ZM_QueuePanel
local ZM_QueueSignature = ""
local ZM_VolumeSlider
local ZM_MuteButton
local ZM_PreviousButton
local ZM_PauseButton
local ZM_SkipButton
local ZM_MutedVolume = nil

local PURPLE = Color(177, 95, 255)
local WHITE = Color(255, 255, 255)
local MUTED = Color(167, 151, 190)

local function ZM2_Time(value)
    value = math.max(0, math.floor(tonumber(value) or 0))
    return string.format("%02d:%02d", math.floor(value / 60), value % 60)
end

local function ZM2_Track()
    local track = active.id and ZoneMusic.Playing[active.id]
    if not track then return nil end

    local current = expectedTrackTime(track)
    local duration = tonumber(track.duration) or 0

    local channel = validChannel(active.indoor) and active.indoor
        or (validChannel(active.outdoor) and active.outdoor or nil)

    if channel then
        local ok, result = pcall(channel.GetTime, channel)
        if ok and tonumber(result) then current = result end

        ok, result = pcall(channel.GetLength, channel)
        if ok and tonumber(result) and result > 0 then
            duration = result
        end
    end

    return {
        title = track.title or "Musique inconnue",
        requester = track.requester or "Inconnu",
        thumbnail = track.thumbnail or "",
        paused = track.paused == true,
        current = current,
        duration = duration,
        percent = duration > 0 and math.Clamp(current / duration, 0, 1) or 0,
        volume = VOLUME_CVAR:GetFloat()
    }
end

local function ZM2_Send(action)
    local id = ZM_HUDZoneID or active.id
    if not id then return end

    net.Start("ZoneMusic_Action")
    net.WriteString(action)
    net.WriteString(tostring(id))
    net.SendToServer()
end

local function ZM2_VoteCount(action)
    local state = ZM_HUDZoneID and ZoneMusic.QueueState[ZM_HUDZoneID]
    local votes = state and state.votes and state.votes[action] or {}
    local count = 0

    for _ in pairs(votes) do
        count = count + 1
    end

    return count
end

local function ZM2_ImageHTML(url, size)
    if not string.match(url or "", "^https?://") then
        return ""
    end

    url = string.Replace(url, "&", "&amp;")
    url = string.Replace(url, '"', "&quot;")

    return [[
        <html><body style="margin:0;background:#160d25;overflow:hidden">
        <img src="]] .. url .. [[" style="
        width:]] .. size .. [[px;height:]] .. size .. [[px;
        object-fit:cover;border-radius:12px">
        </body></html>
    ]]
end

local function ZM2_Triangle(points, color)
    surface.SetDrawColor(color)
    draw.NoTexture()
    surface.DrawPoly(points)
end

local function ZM2_Button(parent, x, y, w, h, label, callback, accent)
    local btn = vgui.Create("DButton", parent)
    btn:SetPos(x, y)
    btn:SetSize(w, h)
    btn:SetText("")
    btn:SetCursor("hand")
    btn.ZM2Hover = 0

    btn.Paint = function(self, pw, ph)
        local hovered = self:IsHovered()
        self.ZM2Hover = Lerp(FrameTime() * 12,
            self.ZM2Hover or 0, hovered and 1 or 0)

        local hover = self.ZM2Hover
        local cx, cy = pw / 2, ph / 2
        local radius = math.min(pw, ph) / 2 - 2
        local color = accent or Color(190, 135, 255, 255)

        -- Halo lumineux animé
        draw.RoundedBox(100,
            cx - radius - 3 * hover,
            cy - radius - 3 * hover,
            (radius + 3 * hover) * 2,
            (radius + 3 * hover) * 2,
            Color(color.r, color.g, color.b, 20 + hover * 65))

        -- Fond circulaire
        draw.RoundedBox(100,
            cx - radius, cy - radius,
            radius * 2, radius * 2,
            Color(35 + hover * 30, 23 + hover * 18,
                55 + hover * 35, 255))

        -- Anneau
        surface.SetDrawColor(color.r, color.g, color.b,
            75 + hover * 150)
        surface.DrawOutlinedRect(
            cx - radius, cy - radius,
            radius * 2, radius * 2, 1
        )

        local white = Color(245, 239, 255, 255)
        local iconColor = Color(
            Lerp(hover, color.r, 255),
            Lerp(hover, color.g, 255),
            Lerp(hover, color.b, 255), 255
        )

        local function triangle(a, b, c)
            ZM2_Triangle({
                {x = a[1], y = a[2]},
                {x = b[1], y = b[2]},
                {x = c[1], y = c[2]}
            }, iconColor)
        end

        -- PREVIOUS
        if label == "previous" then
            surface.SetDrawColor(iconColor)
            surface.DrawRect(cx - 12, cy - 9, 3, 18)

            triangle({cx - 8, cy}, {cx + 1, cy - 9},
                {cx + 1, cy + 9})
            triangle({cx + 1, cy}, {cx + 10, cy - 9},
                {cx + 10, cy + 9})

        -- NEXT
        elseif label == "next" then
            surface.SetDrawColor(iconColor)
            surface.DrawRect(cx + 9, cy - 9, 3, 18)

            triangle({cx + 8, cy}, {cx - 1, cy - 9},
                {cx - 1, cy + 9})
            triangle({cx - 1, cy}, {cx - 10, cy - 9},
                {cx - 10, cy + 9})

        -- PAUSE / PLAY
        elseif label == "pause" then
            local track = active and active.id
                and ZoneMusic.Playing
                and ZoneMusic.Playing[active.id]

            if track and track.paused then
                triangle({cx - 6, cy - 11},
                    {cx - 6, cy + 11}, {cx + 12, cy})
            else
                draw.RoundedBox(2, cx - 9, cy - 10, 6, 20, white)
                draw.RoundedBox(2, cx + 3, cy - 10, 6, 20, white)
            end

        -- VOLUME / MUTE
        elseif label == "volume" then
            local muted = VOLUME_CVAR:GetFloat() <= 0

            surface.SetDrawColor(iconColor)
            surface.DrawRect(cx - 12, cy - 5, 6, 10)

            triangle({cx - 7, cy - 6},
                {cx + 2, cy - 13}, {cx + 2, cy + 13})

            if muted then
                surface.DrawLine(cx + 7, cy - 6, cx + 15, cy + 6)
                surface.DrawLine(cx + 15, cy - 6, cx + 7, cy + 6)
            else
                surface.DrawLine(cx + 7, cy - 5, cx + 11, cy)
                surface.DrawLine(cx + 11, cy, cx + 7, cy + 5)
                surface.DrawLine(cx + 11, cy - 9, cx + 16, cy)
                surface.DrawLine(cx + 16, cy, cx + 11, cy + 9)
            end
        end
    end

    btn.DoClick = callback
    return btn
end

local function ZM2_SetInput(panel, enabled)
    if not IsValid(panel) then return end

    panel:SetMouseInputEnabled(enabled)

    for _, child in ipairs(panel:GetChildren()) do
        ZM2_SetInput(child, enabled)
    end
end

local function ZM2_RebuildQueue()
    if not IsValid(ZM_QueuePanel) then return end

    local state = ZM_HUDZoneID and ZoneMusic.QueueState[ZM_HUDZoneID]
    local queue = state and state.queue or {}

    local signature = tostring(#queue)

    for _, item in ipairs(queue) do
        signature = signature .. "|" ..
            tostring(item.title) .. "|" ..
            tostring(item.requester) .. "|" ..
            tostring(item.duration) .. "|" ..
            tostring(item.thumbnail)
    end

    if signature == ZM_QueueSignature then return end
    ZM_QueueSignature = signature

    ZM_QueuePanel:Clear()

    if #queue == 0 then
        local empty = vgui.Create("DPanel", ZM_QueuePanel)
        empty:Dock(TOP)
        empty:SetTall(48)
        empty.Paint = function(self, w, h)
            draw.SimpleText("La file d'attente est vide",
                "ZM2_Sub", w / 2, h / 2, MUTED,
                TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
        return
    end

    for i, item in ipairs(queue) do
        local row = vgui.Create("DPanel", ZM_QueuePanel)
        row:Dock(TOP)
        row:DockMargin(0, 0, 0, 5)
        row:SetTall(57)

        row.Paint = function(self, w, h)
            draw.RoundedBox(9, 0, 0, w, h,
                Color(35, 24, 51))

            draw.SimpleText(string.format("%02d", i),
                "ZM2_Sub", 10, h / 2, PURPLE,
                TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

            draw.SimpleText(tostring(item.title or "Musique"),
                "ZM2_Text", 54, 17, WHITE,
                TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

            draw.SimpleText("Par " .. tostring(item.requester or "Inconnu"),
                "ZM2_Sub", 54, 39, MUTED,
                TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

            draw.SimpleText(ZM2_Time(item.duration),
                "ZM2_Sub", w - 12, h / 2, MUTED,
                TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
        end

        local thumb = vgui.Create("DHTML", row)
        thumb:SetPos(29, 5)
        thumb:SetSize(46, 47)
        thumb:SetMouseInputEnabled(false)
        thumb:SetKeyboardInputEnabled(false)

        if item.thumbnail and item.thumbnail ~= "" then
            thumb:SetHTML(ZM2_ImageHTML(item.thumbnail, 46))
        else
            thumb:SetVisible(false)
        end
    end
end

local function ZM_CreatePlayer()
    if IsValid(ZM_Player) then ZM_Player:Remove() end

    ZM_PlayerExpanded = false
    ZM_CursorEnabled = false

    ZM_Player = vgui.Create("DPanel")
    ZM_Player:SetSize(620, 92)
    ZM_Player:SetMouseInputEnabled(false)
    ZM_Player:SetKeyboardInputEnabled(false)
    ZM_Player:SetPaintBackground(false)

    ZM_Player.Paint = function(self, w, h)
        local alpha = self:GetAlpha()
        local t = RealTime()
        local pulse = 0.5 + math.sin(t * 3) * 0.5
        local info = ZM2_Track()

        local function C(r, g, b, a)
            return Color(r, g, b, math.floor(a * alpha))
        end

        draw.RoundedBox(24, 2, 5, w - 4, h - 5,
            C(0, 0, 0, 180))

        draw.RoundedBox(23, 0, 0, w, h,
            C(15, 10, 29, 250))

        draw.RoundedBox(22, 2, 2, w - 4, h - 4,
            C(35, 19, 54, 250))

        draw.RoundedBox(2, 35, 3, w - 70, 2,
            C(190, 100, 255, 160 + pulse * 80))

        -- Logo
        draw.RoundedBox(17, 14, 13, 66, 66,
            C(91, 43, 143, 255))

        draw.SimpleText("♫", "ZM2_Big",
            47, 46, C(255, 235, 255, 255),
            TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

        draw.SimpleText("ZONE MUSIC",
            "ZM2_Sub", 94, 20,
            C(195, 150, 255, 255),
            TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        draw.SimpleText(
            info and info.title or "Aucune musique en cours",
            "ZM2_Title", 94, 44,
            C(255, 255, 255, 255),
            TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER
        )

        draw.SimpleText(
            info and ("Demandée par " .. info.requester) or "En attente d'une musique",
            "ZM2_Sub", 95, 68,
            C(170, 155, 195, 255),
            TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER
        )

        -- Equaliseur
        for i = 1, 8 do
            local wave = math.abs(math.sin(t * 5 + i * 0.8))
            local bh = 6 + wave * 23

            draw.RoundedBox(3,
                w - 110 + i * 9, 74 - bh,
                5, bh,
                C(150 + i * 10, 90 + wave * 100, 255, 240))
        end

        if not ZM_PlayerExpanded then return end

        draw.RoundedBox(1, 18, 98, w - 36, 1,
            C(125, 90, 160, 130))

        -- Now playing
        draw.SimpleText("NOW PLAYING",
            "ZM2_Sub", 125, 119,
            C(190, 135, 255, 255),
            TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        if info then
            draw.SimpleText(
                info.paused and "EN PAUSE" or "EN LECTURE",
                "ZM2_Sub", w - 25, 119,
                info.paused and Color(255, 190, 90) or Color(90, 255, 180),
                TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER
            )

            draw.SimpleText(ZM2_Time(info.current),
                "ZM2_Sub", 125, 176, C(200, 185, 220, 255),
                TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

            draw.SimpleText(ZM2_Time(info.duration),
                "ZM2_Sub", w - 25, 176, C(200, 185, 220, 255),
                TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)

            draw.RoundedBox(5, 125, 190, w - 150, 6,
                C(70, 55, 85, 255))

            draw.RoundedBox(5, 125, 190,
                math.max(0, (w - 150) * info.percent), 6,
                C(190, 100, 255, 255))
        else
            draw.SimpleText("Aucun morceau en cours",
                "ZM2_Text", 125, 155, MUTED,
                TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end

        draw.SimpleText("FILE D'ATTENTE",
            "ZM2_Sub", 23, 330, C(190, 135, 255, 255),
            TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        local state = ZM_HUDZoneID and ZoneMusic.QueueState[ZM_HUDZoneID]
        local queue = state and state.queue or {}

        draw.SimpleText(#queue .. " TITRE(S)",
            "ZM2_Sub", w - 23, 330, MUTED,
            TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)

        draw.SimpleText("VOLUME",
            "ZM2_Sub", 23, 285, C(190, 135, 255, 255),
            TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

        draw.SimpleText(
            math.floor(VOLUME_CVAR:GetFloat() * 100) .. "%",
            "ZM2_Sub", w - 25, 285, WHITE,
            TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER
        )
    end

    -- Pochette principale
    ZM_Cover = vgui.Create("DHTML", ZM_Player)
    ZM_Cover:SetPos(25, 113)
    ZM_Cover:SetSize(82, 82)
    ZM_Cover:SetMouseInputEnabled(false)
    ZM_Cover:SetKeyboardInputEnabled(false)

    -- Boutons DJ
    ZM_PreviousButton = ZM2_Button(
        ZM_Player, 174, 218, 48, 48, "previous",
        function() ZM2_Send("previous") end
    )

    ZM_PauseButton = ZM2_Button(
        ZM_Player, 241, 214, 54, 54, "pause",
        function()
            local track = active.id and ZoneMusic.Playing[active.id]
            ZM2_Send(track and track.paused and "resume" or "pause")
        end
    )

    ZM_SkipButton = ZM2_Button(
        ZM_Player, 313, 218, 48, 48, "next",
        function() ZM2_Send("skip") end
    )

    -- Volume
    ZM_VolumeSlider = vgui.Create("DNumSlider", ZM_Player)
    ZM_VolumeSlider:SetPos(100, 293)
    ZM_VolumeSlider:SetSize(390, 28)
    ZM_VolumeSlider:SetText("")
    ZM_VolumeSlider:SetMinMax(0, (cfg.MaxVolume or 20) * 100)
    ZM_VolumeSlider:SetDecimals(0)
    ZM_VolumeSlider:SetValue(VOLUME_CVAR:GetFloat() * 100)
    ZM_VolumeSlider:SetDark(true)
    ZM_VolumeSlider.OnValueChanged = function(self, value)
        RunConsoleCommand("zonemusic_volume",
            tostring(math.Clamp(value / 100, 0, cfg.MaxVolume or 20)))
    end

    ZM_MuteButton = ZM2_Button(
        ZM_Player, 520, 287, 38, 38, "volume",
        function()
            if VOLUME_CVAR:GetFloat() > 0 then
                ZM_MutedVolume = VOLUME_CVAR:GetFloat()
                RunConsoleCommand("zonemusic_volume", "0")
            else
                RunConsoleCommand("zonemusic_volume",
                    tostring(ZM_MutedVolume or 1))
            end
        end
    )

    -- File d'attente
    ZM_QueuePanel = vgui.Create("DScrollPanel", ZM_Player)
    ZM_QueuePanel:SetPos(20, 345)
    ZM_QueuePanel:SetSize(580, 125)

    local bar = ZM_QueuePanel:GetVBar()
    bar:SetWide(5)
    bar.Paint = function() end
    bar.btnUp.Paint = function() end
    bar.btnDown.Paint = function() end
    bar.btnGrip.Paint = function(self, w, h)
        draw.RoundedBox(4, 0, 0, w, h, PURPLE)
    end

    -- Fleche
    local arrow = vgui.Create("DButton", ZM_Player)
    ZM_PlayerArrow = arrow
    arrow:SetPos(568, 17)
    arrow:SetSize(34, 45)
    arrow:SetText("")
    arrow:SetTooltip("Ouvrir / Fermer le lecteur")

    arrow.Paint = function(self, w, h)
        draw.RoundedBox(12, 0, 0, w, h,
            self:IsHovered() and Color(110, 60, 160) or Color(50, 32, 72))

        draw.SimpleText(ZM_PlayerExpanded and "⌃" or "⌄",
            "ZM2_Big", w / 2, h / 2,
            WHITE, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end

    arrow.DoClick = function()
        ZM_PlayerExpanded = not ZM_PlayerExpanded

        if ZM_PlayerExpanded then
            ZM_VolumeSlider:SetValue(VOLUME_CVAR:GetFloat() * 100)
            ZM2_RebuildQueue()
        end
    end

    ZM_Player.Think = function(self)
        local ply = LocalPlayer()
        local pos = IsValid(ply) and ply:GetPos() or nil

        ZM_HUDZoneID = nil

        if pos then
            for id, zone in pairs(ZoneMusic.Zones or {}) do
                if zone.min and zone.max and pos:WithinAABox(zone.min, zone.max) then
                    ZM_HUDZoneID = id
                    break
                end
            end
        end

        local zone = ZM_HUDZoneID and ZoneMusic.Zones[ZM_HUDZoneID]
        local visible = IsValid(ply) and zone ~= nil

        ZM_PlayerAlpha = Lerp(
            math.Clamp(FrameTime() * 8, 0, 1),
            ZM_PlayerAlpha,
            visible and 255 or 0
        )

        ZM_PlayerHeight = Lerp(
            math.Clamp(FrameTime() * 10, 0, 1),
            ZM_PlayerHeight,
            ZM_PlayerExpanded and 490 or 92
        )

        local width = math.min(620, ScrW() - 24)

        self:SetSize(width, ZM_PlayerHeight)
        self:SetPos((ScrW() - width) / 2, 24 + math.sin(RealTime() * 2) * 2)
        self:SetAlpha(ZM_PlayerAlpha)
        self:SetVisible(true)

        local f3 = input.IsKeyDown(KEY_F3)

        if f3 and not ZM_F3WasDown and visible then
            ZM_CursorEnabled = not ZM_CursorEnabled
        end

        ZM_F3WasDown = f3

        if not visible then
            ZM_CursorEnabled = false
            ZM_PlayerExpanded = false
        end

        local cursor = ZM_CursorEnabled and visible
        ZM2_SetInput(self, cursor)
        gui.EnableScreenClicker(cursor)

        local info = ZM2_Track()

        if IsValid(ZM_Cover) then
            local url = info and info.thumbnail or ""

            if url ~= ZM_LastCover then
                ZM_LastCover = url

                if string.match(url, "^https?://") then
                    ZM_Cover:SetHTML(ZM2_ImageHTML(url, 82))
                else
                    ZM_Cover:SetHTML([[
                        <html><body style="margin:0;background:#26153a;
                        color:white;text-align:center;padding-top:20px">
                        <span style="font-size:30px">♫</span></body></html>
                    ]])
                end
            end

            ZM_Cover:SetVisible(ZM_PlayerExpanded)
        end

        if IsValid(ZM_PauseButton) then
            ZM_PauseButton:SetVisible(IsValid(ply) and ply:IsSuperAdmin())
        end

        if IsValid(ZM_PreviousButton) then
            ZM_PreviousButton:SetText("")
            ZM_PreviousButton:SetTooltip(
                "Voter pour le morceau précédent : " ..
                ZM2_VoteCount("previous") .. " vote(s)"
            )
        end

        if IsValid(ZM_SkipButton) then
            ZM_SkipButton:SetTooltip(
                "Voter pour passer : " ..
                ZM2_VoteCount("skip") .. " vote(s)"
            )
        end

        if ZM_PlayerExpanded then
            ZM2_RebuildQueue()
        end

        if IsValid(ZM_VolumeSlider) then
            ZM_VolumeSlider:SetVisible(ZM_PlayerExpanded)
        end

        if IsValid(ZM_MuteButton) then
            ZM_MuteButton:SetVisible(ZM_PlayerExpanded)
        end

        if IsValid(ZM_QueuePanel) then
            ZM_QueuePanel:SetVisible(ZM_PlayerExpanded)
        end
    end
end

timer.Remove("ZoneMusic_CreatePlayer")

timer.Create("ZoneMusic_CreatePlayer", 1, 0, function()
    if not IsValid(LocalPlayer()) then return end

    if IsValid(ZM_Player) then
        timer.Remove("ZoneMusic_CreatePlayer")
        return
    end

    local ok, err = pcall(ZM_CreatePlayer)

    if ok and IsValid(ZM_Player) then
        timer.Remove("ZoneMusic_CreatePlayer")
        print("[ZoneMusic V2] Lecteur initialise.")
    elseif not ok then
        print("[ZoneMusic V2] Erreur : " .. tostring(err))
    end
end)

hook.Remove("ShutDown", "ZoneMusic_PlayerCleanup")
hook.Add("ShutDown", "ZoneMusic_PlayerCleanup", function()
    gui.EnableScreenClicker(false)
    if IsValid(ZM_Player) then ZM_Player:Remove() end
end)

print("[ZoneMusic V2] Interface moderne chargee.")
