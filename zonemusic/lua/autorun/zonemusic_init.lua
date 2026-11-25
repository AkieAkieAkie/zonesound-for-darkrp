-- Zone Music : point d'entree (charge serveur + client)
ZoneMusic = ZoneMusic or {}

if SERVER then
    AddCSLuaFile("zonemusic/sh_config.lua")
    AddCSLuaFile("zonemusic/cl_zonemusic.lua")
    include("zonemusic/sh_config.lua")
    include("zonemusic/sv_zonemusic.lua")
else
    include("zonemusic/sh_config.lua")
    include("zonemusic/cl_zonemusic.lua")
end
