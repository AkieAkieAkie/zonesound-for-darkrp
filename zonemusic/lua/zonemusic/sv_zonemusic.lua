-- ZoneMusic SERVER - queue, votes, historique et pause SuperAdmin
util.AddNetworkString("ZoneMusic_Zones")
util.AddNetworkString("ZoneMusic_Play")
util.AddNetworkString("ZoneMusic_Stop")
util.AddNetworkString("ZoneMusic_Volume")
util.AddNetworkString("ZoneMusic_BoundsPreview")
util.AddNetworkString("ZoneMusic_TrackEnded")
util.AddNetworkString("ZoneMusic_Queue")
util.AddNetworkString("ZoneMusic_Action")

local cfg = ZoneMusic.Config
ZoneMusic.Zones = ZoneMusic.Zones or {}
ZoneMusic.Playing = ZoneMusic.Playing or {}
ZoneMusic.Queues = ZoneMusic.Queues or {}
ZoneMusic.History = ZoneMusic.History or {}
ZoneMusic.Votes = ZoneMusic.Votes or {}
ZoneMusic.ZoneVolumes = ZoneMusic.ZoneVolumes or {}
local trackSerial = 0
local MAX_QUEUE, MAX_HISTORY = 20, 10

local function notify(ply, msg)
    if IsValid(ply) then ply:ChatPrint("[Musique] " .. tostring(msg)) end
end

local function resolverKey()
    return string.Trim(file.Read("zonemusic/resolver_key.txt", "DATA") or "")
end

local function dataFile()
    return "zonemusic/" .. game.GetMap() .. ".json"
end

local function zoneAt(pos)
    for id, zone in pairs(ZoneMusic.Zones) do
        if ZoneMusic.IsInZone(pos, zone) then return tostring(id), zone end
    end
end

local function playersInZone(id)
    local result = {}
    local zone = ZoneMusic.Zones[id]
    if not zone then return result end
    for _, ply in ipairs(player.GetAll()) do
        if IsValid(ply) and ply:Alive() and ZoneMusic.IsInZone(ply:GetPos(), zone) then
            result[#result + 1] = ply
        end
    end
    return result
end

local function sendQueue(id, target)
    local current = ZoneMusic.Playing[id]
    local payload = {
        current = current and {
            title = current.title, thumbnail = current.thumbnail or "",
            requester = current.requester or "Inconnu",
            duration = current.duration or 0, start = current.start or CurTime(),
            paused = current.paused == true
        } or nil,
        queue = {}, history = {}, votes = ZoneMusic.Votes[id] or {skip = {}, previous = {}},
        paused = current and current.paused == true or false,
        globalVolume = ZoneMusic.ZoneVolumes[id] or 100
    }
    for i, t in ipairs(ZoneMusic.Queues[id] or {}) do
        if i > MAX_QUEUE then break end
        payload.queue[#payload.queue + 1] = {
            id = t.queueID, title = t.title, thumbnail = t.thumbnail or "",
            requester = t.requester or "Inconnu", duration = t.duration or 0
        }
    end
    for i = math.max(1, #(ZoneMusic.History[id] or {}) - 4), #(ZoneMusic.History[id] or {}) do
        local t = ZoneMusic.History[id][i]
        if t then payload.history[#payload.history + 1] = {title=t.title, requester=t.requester or "Inconnu"} end
    end
    net.Start("ZoneMusic_Queue")
    net.WriteString(id)
    net.WriteTable(payload)
    if IsValid(target) then net.Send(target) else net.Broadcast() end
end

local function sendPlay(id, target)
    local t = ZoneMusic.Playing[id]
    if not t then return end
    net.Start("ZoneMusic_Play")
    net.WriteString(tostring(id))
    net.WriteString(t.url or "")
    net.WriteString(t.outdoor_url or t.url or "")
    net.WriteString(t.title or "Musique")
    net.WriteFloat(t.start or CurTime())
    net.WriteFloat(tonumber(t.duration) or 0)
    net.WriteString(t.thumbnail or "")
    net.WriteString(t.requester or "Inconnu")
    net.WriteBool(t.paused == true)
    net.WriteFloat(t.pausedAt or 0)
    if IsValid(target) then net.Send(target) else net.Broadcast() end
end

local function sendStop(id)
    net.Start("ZoneMusic_Stop")
    net.WriteString(tostring(id))
    net.Broadcast()
end

local function resetVotes(id)
    ZoneMusic.Votes[id] = {skip = {}, previous = {}}
end

local function stopZone(id)
    if not ZoneMusic.Playing[id] then return false end
    ZoneMusic.Playing[id] = nil
    ZoneMusic.Queues[id] = {}
    ZoneMusic.History[id] = {}
    resetVotes(id)
    sendStop(id)
    sendQueue(id)
    return true
end

local function pushHistory(id, track)
    ZoneMusic.History[id] = ZoneMusic.History[id] or {}
    local h = ZoneMusic.History[id]
    h[#h + 1] = track
    while #h > MAX_HISTORY do table.remove(h, 1) end
end

local function startNext(id, previous)
    local queue = ZoneMusic.Queues[id] or {}
    local old = ZoneMusic.Playing[id]
    local nextTrack

    if previous then
        local history = ZoneMusic.History[id] or {}
        if #history < 1 then return false end
        if old then table.insert(queue, 1, old) end
        nextTrack = table.remove(history)
    else
        if old then pushHistory(id, old) end
        nextTrack = table.remove(queue, 1)
    end

    if not nextTrack then
        if old then
            ZoneMusic.Playing[id] = nil
            sendStop(id)
        end
        sendQueue(id)
        return false
    end

    nextTrack.start = CurTime()
    nextTrack.paused = false
    nextTrack.pausedAt = nil
    ZoneMusic.Playing[id] = nextTrack
    resetVotes(id)
    sendPlay(id)
    sendQueue(id)
    return true
end

local function addTrack(ply, id, data)
    if not ZoneMusic.Zones[id] then return end
    trackSerial = trackSerial + 1
    data.queueID = tostring(SysTime()) .. ":" .. tostring(trackSerial)
    data.requester = IsValid(ply) and ply:Nick() or "Console"
    data.owner = IsValid(ply) and ply:SteamID64() or "console"
    data.title = string.sub(tostring(data.title or "Musique"), 1, 160)
    data.thumbnail = string.sub(tostring(data.thumbnail or ""), 1, 1000)
    data.duration = math.max(0, tonumber(data.duration) or 0)
    data.outdoor_url = data.outdoor_url or data.url

    if not ZoneMusic.Playing[id] then
        data.start = CurTime()
        ZoneMusic.Playing[id] = data
        resetVotes(id)
        sendPlay(id)
        sendQueue(id)
        notify(ply, "Lecture : " .. data.title)
        return
    end

    ZoneMusic.Queues[id] = ZoneMusic.Queues[id] or {}
    if #ZoneMusic.Queues[id] >= MAX_QUEUE then
        return notify(ply, "La file d'attente est pleine (20 titres maximum).")
    end
    table.insert(ZoneMusic.Queues[id], data)
    sendQueue(id)
    notify(ply, "Ajouté à la file d'attente : " .. data.title .. " (position " .. #ZoneMusic.Queues[id] .. ").")
end

local function voteAction(ply, id, action)
    if not IsValid(ply) or not ZoneMusic.Zones[id] then return end
    local inZone = zoneAt(ply:GetPos())
    if inZone ~= id then return notify(ply, "Tu dois être dans la zone concernée.") end
    if not ZoneMusic.Playing[id] then return notify(ply, "Aucune musique en cours.") end
    if action ~= "skip" and action ~= "previous" then return end

    local history = ZoneMusic.History[id] or {}
    if action == "previous" and #history == 0 then
        return notify(ply, "Aucun morceau précédent dans l'historique.")
    end

    ZoneMusic.Votes[id] = ZoneMusic.Votes[id] or {skip = {}, previous = {}}
    local votes = ZoneMusic.Votes[id][action]
    local sid = ply:SteamID64()
    if votes[sid] then return notify(ply, "Tu as déjà voté.") end
    votes[sid] = true

    local voters = playersInZone(id)
    local total, count = #voters, 0
    for _, voter in ipairs(voters) do
        if votes[voter:SteamID64()] then count = count + 1 end
    end
    local needed = math.max(1, math.floor(total / 2) + 1)
    sendQueue(id)
    if count >= needed then
        notify(ply, "Vote accepté !")
        startNext(id, action == "previous")
    else
        for _, voter in ipairs(voters) do
            notify(voter, "Vote " .. (action == "skip" and "skip" or "précédent") ..
                " : " .. count .. "/" .. needed)
        end
    end
end

local function sendBoundsPreview(ply)
    if not IsValid(ply) then return end
    net.Start("ZoneMusic_BoundsPreview")
    if not ply.ZM_Pos1 then
        net.WriteBool(false)
    else
        net.WriteBool(true)
        net.WriteVector(ply.ZM_Pos1)
        net.WriteBool(ply.ZM_Pos2 ~= nil)
        if ply.ZM_Pos2 then net.WriteVector(ply.ZM_Pos2) end
    end
    net.Send(ply)
end

function ZoneMusic.Save()
    file.CreateDir("zonemusic")
    file.Write(dataFile(), util.TableToJSON(ZoneMusic.Zones, true) or "{}")
end

function ZoneMusic.Load()
    local raw = file.Read(dataFile(), "DATA")
    if not raw then ZoneMusic.Zones = {} return end
    local saved = util.JSONToTable(raw)
    if not istable(saved) then ZoneMusic.Zones = {} return end
    local loaded = {}
    for id, zone in pairs(saved) do
        if istable(zone) and zone.min and zone.max and isstring(zone.name) then
            local function toVector(v)
                if isvector(v) then return v end
                if not istable(v) then return nil end
                local x,y,z = tonumber(v.x or v[1]), tonumber(v.y or v[2]), tonumber(v.z or v[3])
                if not x or not y or not z then return nil end
                return Vector(x,y,z)
            end
            local mn,mx = toVector(zone.min),toVector(zone.max)
            if mn and mx then
                OrderVectors(mn,mx)
                loaded[tostring(id)] = {name=string.sub(zone.name,1,64),min=mn,max=mx}
            end
        end
    end
    ZoneMusic.Zones = loaded
    print("[ZoneMusic] " .. table.Count(loaded) .. " zone(s) chargée(s).")
end

function ZoneMusic.SendZones(target)
    net.Start("ZoneMusic_Zones")
    net.WriteTable(ZoneMusic.Zones)
    if IsValid(target) then net.Send(target) else net.Broadcast() end
end

local Commands = {}

Commands["/musicpos1"] = function(ply)
    if not cfg.IsAdmin(ply) then return notify(ply,"Réservé aux administrateurs.") end
    ply.ZM_Pos1, ply.ZM_Pos2 = ply:GetPos(), nil
    sendBoundsPreview(ply)
    notify(ply,"Position 1 définie.")
end

Commands["/musicpos2"] = function(ply)
    if not cfg.IsAdmin(ply) then return notify(ply,"Réservé aux administrateurs.") end
    ply.ZM_Pos2 = ply:GetPos()
    sendBoundsPreview(ply)
    notify(ply,"Position 2 définie.")
end

Commands["/musiccreate"] = function(ply,args)
    if not cfg.IsAdmin(ply) then return notify(ply,"Réservé aux administrateurs.") end
    if not ply.ZM_Pos1 or not ply.ZM_Pos2 then return notify(ply,"Utilise /musicpos1 puis /musicpos2.") end
    local mn,mx = Vector(ply.ZM_Pos1),Vector(ply.ZM_Pos2)
    OrderVectors(mn,mx)
    if mx.z-mn.z < cfg.MinHeight then mx.z=mn.z+cfg.MinHeight end
    local name=string.sub(string.Trim(args or ""),1,64)
    if name=="" then name="Zone "..(table.Count(ZoneMusic.Zones)+1) end
    local id=tostring(os.time())..tostring(math.random(100,999))
    ZoneMusic.Zones[id]={name=name,min=mn,max=mx}
    ply.ZM_Pos1,ply.ZM_Pos2=nil,nil
    sendBoundsPreview(ply)
    ZoneMusic.Save()
    ZoneMusic.SendZones()
    notify(ply,'Zone "'..name..'" créée.')
end

Commands["/musicdelete"] = function(ply)
    if not cfg.IsAdmin(ply) then return notify(ply,"Réservé aux administrateurs.") end
    local id,zone=zoneAt(ply:GetPos())
    if not id then return notify(ply,"Tu n'es dans aucune zone.") end
    stopZone(id)
    ZoneMusic.Zones[id]=nil
    ZoneMusic.Save()
    ZoneMusic.SendZones()
    notify(ply,'Zone "'..zone.name..'" supprimée.')
end

Commands["/musiczones"] = function(ply)
    if not cfg.IsAdmin(ply) then return notify(ply,"Réservé aux administrateurs.") end
    local n=0
    for _,z in pairs(ZoneMusic.Zones) do n=n+1 notify(ply,"- "..z.name) end
    if n==0 then notify(ply,"Aucune zone sur cette map.") end
end

Commands["/musicstop"] = function(ply)
    local id=zoneAt(ply:GetPos())
    if not id then return notify(ply,"Tu dois être dans une zone musicale.") end
    if not stopZone(id) then return notify(ply,"Aucune musique en cours.") end
    notify(ply,"Musique et file arrêtées.")
end

Commands["/musicvolume"] = function(ply,args)
    local value=tonumber(args)
    if not value then return notify(ply,"Usage : /musicvolume 0-2000") end
    value=math.Clamp(math.floor(value+0.5),0,2000)
    net.Start("ZoneMusic_Volume")
    net.WriteUInt(value,11)
    net.Send(ply)
    notify(ply,"Volume réglé à "..value.."%.")
end

local function setPaused(ply, paused)
    if not IsValid(ply) or not cfg.IsAdmin(ply) then
        return notify(ply,"Cette commande est réservée aux administrateurs.")
    end
    local id=zoneAt(ply:GetPos())
    if not id or not ZoneMusic.Playing[id] then return notify(ply,"Aucune musique dans ta zone.") end
    local t=ZoneMusic.Playing[id]
    if t.paused == paused then return notify(ply, paused and "Déjà en pause." or "La musique joue déjà.") end
    if paused then
        t.paused=true
        t.pausedAt=CurTime()
    else
        local elapsed=CurTime()-(t.pausedAt or CurTime())
        t.start=(t.start or CurTime())+elapsed
        t.paused=false
        t.pausedAt=nil
    end
    sendPlay(id)
    sendQueue(id)
    notify(ply,paused and "Musique mise en pause." or "Lecture reprise.")
end

Commands["/musicpause"] = function(ply) setPaused(ply,true) end
Commands["/musicresume"] = function(ply) setPaused(ply,false) end

Commands["/music"] = function(ply,args)
    local id,zone=zoneAt(ply:GetPos())
    if not id then return notify(ply,"Tu dois être dans une zone musicale.") end
    if args=="" then return notify(ply,"Usage : /music <lien ou titre>") end
    if (ply.ZM_Next or 0)>CurTime() and not cfg.IsAdmin(ply) then
        return notify(ply,"Attends avant de proposer une autre musique.")
    end
    ply.ZM_Next=CurTime()+(cfg.PlayCooldown or 10)

    local function resolved(data)
        if not IsValid(ply) then return end
        local currentID=zoneAt(ply:GetPos())
        if currentID~=id then return notify(ply,"Recherche annulée : tu as quitté la zone.") end
        if not istable(data) or not isstring(data.url) or data.url=="" then
            return notify(ply,"Réponse du résolveur invalide.")
        end
        addTrack(ply,id,{
            url=data.url,outdoor_url=data.outdoor_url or data.url,
            title=data.title or args,duration=data.duration,
            thumbnail=data.thumbnail or ""
        })
    end

    if ZoneMusic.IsDirectURL(args) then
        return resolved({url=args,outdoor_url=args,title=args,duration=0})
    end

    local key=resolverKey()
    if key=="" then return notify(ply,"Clé du résolveur absente dans data/zonemusic/resolver_key.txt.") end
    local base=string.Trim(cfg.ResolverURL or "")
    if base=="" then return notify(ply,"Résolveur non configuré.") end
    notify(ply,"Recherche et préparation audio en cours...")
    http.Fetch(base.."/resolve?q="..ZoneMusic.URLEncode(args),function(body,_,_,code)
        if not IsValid(ply) then return end
        local data=util.JSONToTable(body or "")
        if code~=200 or not istable(data) then
            return notify(ply,"Recherche impossible : "..tostring(data and data.error or ("HTTP "..code)))
        end
        resolved(data)
    end,function(err)
        if IsValid(ply) then notify(ply,"Résolveur injoignable : "..tostring(err)) end
    end,{["X-ZoneMusic-Key"]=key})
end

hook.Remove("PlayerSay","ZoneMusic_Commands")
hook.Add("PlayerSay","ZoneMusic_Commands",function(ply,message)
    local command,args=string.match(string.Trim(message),"^(%S+)%s*(.*)$")
    local fn=command and Commands[string.lower(command)]
    if fn then fn(ply,string.Trim(args or "")) return "" end
end)

net.Receive("ZoneMusic_Action",function(_,ply)
    local action=net.ReadString()
    local id=net.ReadString()
    if not isstring(id) or #id>64 then return end
    if not IsValid(ply) then return end
    if (ply.ZM_ActionNext or 0) > CurTime() then return end
    ply.ZM_ActionNext = CurTime() + 0.15
    if string.sub(action, 1, 6) == "admin_" then
        if not cfg.IsAdmin(ply) then return notify(ply,"Réservé aux administrateurs.") end
        if not ply:Alive() or zoneAt(ply:GetPos()) ~= id then
            return notify(ply,"Tu dois être dans la zone concernée.")
        end
        if action == "admin_skip" then
            startNext(id,false)
        elseif action == "admin_previous" then
            if not startNext(id,true) then notify(ply,"Aucun morceau précédent.") end
        elseif action == "admin_pause" then
            setPaused(ply,true)
        elseif action == "admin_resume" then
            setPaused(ply,false)
        elseif action == "admin_stop" then
            stopZone(id)
        elseif action == "admin_volume" then
            local value = net.ReadUInt(11)
            ZoneMusic.ZoneVolumes[id] = math.Clamp(value,0,2000)
            sendQueue(id)
        elseif action == "admin_remove" then
            local queueID = net.ReadString()
            if #queueID > 80 then return end
            for i,track in ipairs(ZoneMusic.Queues[id] or {}) do
                if track.queueID == queueID then
                    table.remove(ZoneMusic.Queues[id],i)
                    sendQueue(id)
                    return
                end
            end
            notify(ply,"Ce titre n'est plus dans la file d'attente.")
        end
        return
    end
    if action=="skip" or action=="previous" then
        voteAction(ply,id,action)
    elseif action=="pause" then
        setPaused(ply,true)
    elseif action=="resume" then
        setPaused(ply,false)
    end
end)

net.Receive("ZoneMusic_TrackEnded",function(_,ply)
    local id=net.ReadString()
    local zone=ZoneMusic.Zones[id]
    local track=ZoneMusic.Playing[id]
    if not IsValid(ply) or not zone or not track or (tonumber(track.duration) or 0)>0 or track.paused then return end
    if (track.endReportAt or 0)>CurTime() then return end
    local pos=ply:GetPos()
    local closest=Vector(math.Clamp(pos.x,zone.min.x,zone.max.x),math.Clamp(pos.y,zone.min.y,zone.max.y),math.Clamp(pos.z,zone.min.z,zone.max.z))
    if pos:DistToSqr(closest)>(cfg.SoundMaxDistance+300)^2 then return end
    track.endReportAt=CurTime()+8
    startNext(id,false)
end)

hook.Remove("PlayerInitialSpawn","ZoneMusic_Sync")
hook.Remove("PlayerInitialSpawn","ZoneMusic_InitialSync")
hook.Add("PlayerInitialSpawn","ZoneMusic_Sync",function(ply)
    timer.Simple(4,function()
        if not IsValid(ply) then return end
        ZoneMusic.SendZones(ply)
        for id in pairs(ZoneMusic.Playing) do
            sendPlay(id,ply)
            sendQueue(id,ply)
        end
    end)
end)

timer.Remove("ZoneMusic_AutoStop")
timer.Create("ZoneMusic_AutoStop",1,0,function()
    for id,t in pairs(ZoneMusic.Playing) do
        if not t.paused then
            local duration=tonumber(t.duration) or 0
            if duration>0 and CurTime()-(t.start or CurTime())>=duration then
                startNext(id,false)
            end
        end
    end
end)

timer.Simple(0,function()
    ZoneMusic.Load()
    ZoneMusic.SendZones()
end)

print("[ZoneMusic] Serveur chargé : queue, votes, historique et pause SuperAdmin.")
