for _, path in ipairs({
    "zonemusic/lua/autorun/zonemusic_init.lua",
    "zonemusic/lua/zonemusic/sh_config.lua",
    "zonemusic/lua/zonemusic/sv_zonemusic.lua",
    "zonemusic/lua/zonemusic/cl_zonemusic.lua"
}) do
    local chunk, err = loadfile(path)
    assert(chunk, err)
end
print("ZoneMusic : syntaxe Lua valide")