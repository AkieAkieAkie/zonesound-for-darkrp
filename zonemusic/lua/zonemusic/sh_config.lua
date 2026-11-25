--[[
    ZoneMusic - Configuration partagee client/serveur
    Aucun secret ne doit etre place dans ce fichier : il est transmis aux clients.
]]

ZoneMusic = ZoneMusic or {}

ZoneMusic.Config = {
    IsAdmin = function(ply)
        return IsValid(ply) and (ply:IsAdmin() or ply:IsSuperAdmin())
    end,

    MinHeight = 200,
    CheckInterval = 0.10,
    PlayCooldown = 10,

    DefaultVolume = 3.0,
    MaxVolume = 20.0,

    -- Audio spatial : source placee au centre de la zone.
    Sound3D = true,
    SoundMaxDistance = 2400,
    DoorTransitionDistance = 350,
    ExitMargin = 150,
    TransitionSpeed = 4.0,

    -- Occlusion : volume exterieur reduit quand un mur bloque la ligne.
    OccludedOutdoorMultiplier = 0.28,

    ResyncInterval = 3,
    ResyncThreshold = 0.45,

    -- URL publique joignable depuis le serveur Garry's Mod.
    ResolverURL = "http://51.254.203.252:8765",
}

function ZoneMusic.URLEncode(value)
    return string.gsub(tostring(value), "([^%w%-_%.~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end)
end

function ZoneMusic.IsDirectURL(value)
    value = string.Trim(tostring(value or ""))
    if not string.match(value, "^https?://") then return false end

    local lower = string.lower(value)
    if string.find(lower, "youtube%.com")
        or string.find(lower, "youtu%.be")
        or string.find(lower, "spotify%.com")
        or string.find(lower, "soundcloud%.com") then
        return false
    end

    return true
end

function ZoneMusic.IsInZone(pos, zone)
    if not zone or not isvector(zone.min) or not isvector(zone.max) then
        return false
    end
    return pos:WithinAABox(zone.min, zone.max)
end
