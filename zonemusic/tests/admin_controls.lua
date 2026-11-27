-- Run from repository root: lua zonemusic/tests/admin_controls.lua
local clock, handler, chat = 100, nil, nil
local incoming, sent = {}, {}
function CurTime() return clock end
function SysTime() return clock end
function IsValid(p) return type(p) == "table" and p.valid == true end
function istable(v) return type(v) == "table" end
function isstring(v) return type(v) == "string" end
function isvector() return false end
function Vector(x,y,z) return {x=x,y=y,z=z} end
function OrderVectors() end
math.Clamp = function(v,a,b) return math.max(a,math.min(b,v)) end
string.Trim = function(v) return v:match("^%s*(.-)%s*$") end
util = {AddNetworkString=function() end, TableToJSON=function() return "{}" end}
file = {Read=function() return nil end, CreateDir=function() end, Write=function() end}
game = {GetMap=function() return "test" end}
timer = {Remove=function() end, Create=function() end, Simple=function() end}
hook = {Remove=function() end, Add=function(event,_,fn) if event=="PlayerSay" then chat=fn end end}
net = {
    Start=function(name) sent.name=name end,
    WriteString=function() end, WriteFloat=function() end, WriteBool=function() end,
    WriteTable=function(v) sent.payload=v end,
    Broadcast=function() end, Send=function() end,
    Receive=function(name,fn) if name=="ZoneMusic_Action" then handler=fn end end,
    ReadString=function() return table.remove(incoming,1) end,
    ReadUInt=function() return table.remove(incoming,1) end
}
local function person(admin, zone)
    return {valid=true, admin=admin, zone=zone, alive=true,
        GetPos=function(p) return p.zone end,
        Alive=function(p) return p.alive end,
        Nick=function() return "test" end, SteamID64=function(p) return tostring(p) end,
        ChatPrint=function() end}
end
local admin, listener, outsider = person(true,"a"), person(false,"a"), person(true,"b")
player = {GetAll=function() return {admin,listener} end}
ZoneMusic = {
    Config={IsAdmin=function(p) return IsValid(p) and p.admin end,PlayCooldown=0},
    Zones={a={},b={}},
    IsInZone=function(pos,zone) return ZoneMusic.Zones[pos]==zone end,
    IsDirectURL=function() return true end
}
assert(loadfile("zonemusic/lua/zonemusic/sv_zonemusic.lua"))()
local function action(p,a,value,id)
    clock=clock+1
    incoming={a,id or "a"}
    if value~=nil then incoming[#incoming+1]=value end
    handler(0,p)
end
local function add(title)
    chat(admin,"/music "..title)
end
local function test(name, fn) fn(); print("PASS "..name) end
add("first"); add("second"); add("third")
test("Un joueur ne peut pas passer immédiatement",function()
    action(listener,"admin_skip"); assert(ZoneMusic.Playing.a.title=="first")
end)
test("Un admin hors zone ne peut pas agir",function()
    action(outsider,"admin_skip"); assert(ZoneMusic.Playing.a.title=="first")
end)
test("Un admin mort ne peut pas agir",function()
    admin.alive=false; action(admin,"admin_skip"); admin.alive=true
    assert(ZoneMusic.Playing.a.title=="first")
end)
test("Suivant immédiat sans vote",function()
    action(admin,"admin_skip"); assert(ZoneMusic.Playing.a.title=="second")
end)
test("Précédent immédiat sans vote",function()
    action(admin,"admin_previous"); assert(ZoneMusic.Playing.a.title=="first")
    assert(ZoneMusic.Queues.a[1].title=="second")
end)
test("Pause admin et reprise sans avancer pendant la pause",function()
    action(admin,"admin_pause"); local t=ZoneMusic.Playing.a
    assert(t.paused==true); local before=t.start
    clock=clock+20; action(admin,"admin_resume")
    assert(t.paused==false and t.start==before+21)
end)
test("Supprimer le titre choisi même après un changement de position",function()
    local id=ZoneMusic.Queues.a[2].queueID
    action(admin,"admin_skip")
    action(admin,"admin_remove",id)
    assert(#ZoneMusic.Queues.a==0 and ZoneMusic.Playing.a.title=="second")
    action(admin,"admin_remove",id)
    assert(ZoneMusic.Playing.a.title=="second")
end)
test("Volume commun par défaut à 100 pourcent",function()
    assert(sent.payload.globalVolume==100)
end)
test("Volume commun plafonné à 2000 pourcent et diffusé",function()
    action(admin,"admin_volume",2047)
    assert(ZoneMusic.ZoneVolumes.a==2000 and sent.payload.globalVolume==2000)
end)
test("Volume commun zéro autorisé",function()
    action(admin,"admin_volume",0); assert(ZoneMusic.ZoneVolumes.a==0)
end)
test("Le volume commun est réservé aux admins dans la bonne zone",function()
    action(listener,"admin_volume",400); action(outsider,"admin_volume",500)
    assert(ZoneMusic.ZoneVolumes.a==0 and ZoneMusic.ZoneVolumes.b==nil)
end)
test("Arrêt admin vide lecture file et historique",function()
    add("fourth"); action(admin,"admin_stop")
    assert(ZoneMusic.Playing.a==nil and #ZoneMusic.Queues.a==0 and #ZoneMusic.History.a==0)
end)