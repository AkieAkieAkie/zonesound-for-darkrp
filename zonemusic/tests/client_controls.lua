-- Run from repository root: lua zonemusic/tests/client_controls.lua
local hooks, timers, receivers, commands, panels = {}, {}, {}, {}, {}
local now, f3, cursor, focus, lastState = 100, false, false, nil, nil
local sent, channels = {}, {}
function CurTime() return now end
function RealTime() return now end
function FrameTime() return 0.1 end
function IsValid(v) return type(v)=="table" and v.valid==true end
function isfunction(v) return type(v)=="function" end
function Color(...) return {...} end
function Lerp(t,a,b) return a+(b-a)*t end
math.Clamp=function(v,a,b) return math.max(a,math.min(b,v)) end
local vectorMethods = {}
local vectorMeta = {__index=vectorMethods}
function Vector(x,y,z) return setmetatable({x=x,y=y,z=z},vectorMeta) end
vectorMeta.__add=function(a,b) return Vector(a.x+b.x,a.y+b.y,a.z+b.z) end
vectorMeta.__sub=function(a,b) return Vector(a.x-b.x,a.y-b.y,a.z-b.z) end
function vectorMethods:WithinAABox(a,b)
    return self.x>=a.x and self.x<=b.x and self.y>=a.y and self.y<=b.y and self.z>=a.z and self.z<=b.z
end
function vectorMethods:Distance(v) return math.sqrt((self.x-v.x)^2+(self.y-v.y)^2+(self.z-v.z)^2) end
local volume = 1
function CreateClientConVar() return {GetFloat=function() return volume end} end
function RunConsoleCommand(_,value) volume=tonumber(value) end
function ScrW() return 1280 end
function ScrH() return 900 end
local ply={valid=true,alive=true,admin=true,pos=Vector(50,50,50)}
function ply:GetPos() return self.pos end
function ply:EyePos() return self.pos end
function ply:Alive() return self.alive end
function LocalPlayer() return ply end
KEY_F3=3; FILL=1; FFT_256=256; MASK_SOLID=1
input={IsKeyDown=function() return f3 end}
gui={EnableScreenClicker=function(v) cursor=v end,IsGameUIVisible=function() return false end}
util={TableToJSON=function(v) lastState=v; return "{}" end,TraceLine=function() return {Hit=false} end}
chat={AddText=function() end}
hook={Remove=function() end,Add=function(_,name,fn) hooks[name]=fn end}
timer={Remove=function() end,Create=function(name,_,_,fn) timers[name]=fn end}
net={Receive=function(name,fn) receivers[name]=fn end,
    Start=function(name) sent={name=name,values={}} end,
    WriteString=function(v) sent.values[#sent.values+1]=v end,
    WriteUInt=function(v) sent.values[#sent.values+1]=v end,SendToServer=function() end}
concommand={Add=function(name,fn) commands[name]=fn end}
local panelMethods={}
function panelMethods:SetSize(w,h) self.width=w;self.height=h end
function panelMethods:GetTall() return self.height end
function panelMethods:SetVisible(v) self.visible=v end
function panelMethods:SetMouseInputEnabled(v) self.mouse=v end
function panelMethods:SetKeyboardInputEnabled(v) self.keyboard=v end
function panelMethods:SetPaintBackground(v) self.background=v end
function panelMethods:AddFunction(namespace,name,fn) self.functions[name]=fn end
function panelMethods:Remove() self.valid=false end
function panelMethods:SetHTML(v) self.html=v;self.OnDocumentReady() end
for _,name in ipairs({"SetPos","SetAlpha","Dock","SetAllowLua","MoveToFront","RunJavascript"}) do panelMethods[name]=function() end end
vgui={GetKeyboardFocus=function() return focus end,CursorVisible=function() return cursor end,
    Create=function(kind)
        local panel=setmetatable({valid=true,functions={},kind=kind},{__index=panelMethods})
        panels[#panels+1]=panel; return panel
    end}
local confirm
function Derma_Query(_,_,_,fn) confirm=fn end
sound={PlayURL=function(_,_,fn)
    local ch={valid=true,time=0,volume=0}
    function ch:Stop() self.stopped=true end
    function ch:SetTime(v) self.time=v end
    function ch:GetTime() return self.time end
    function ch:GetLength() return 300 end
    function ch:SetVolume(v) self.volume=v end
    function ch:Play() self.paused=false end
    function ch:Pause() self.paused=true end
    function ch:Set3DEnabled() end
    channels[#channels+1]=ch; fn(ch)
end}
ZoneMusic={Config={DefaultVolume=1,MaxVolume=20,IsAdmin=function(p) return p.admin end},
    Zones={a={name="A",min=Vector(0,0,0),max=Vector(100,100,100)}},
    Playing={a={title="test",url="https://example.test/audio.mp3",start=100,duration=300}},
    QueueState={a={globalVolume=2000}}}
ZoneMusic.IsInZone=function(pos,zone) return pos:WithinAABox(zone.min,zone.max) end
assert(loadfile("zonemusic/lua/zonemusic/cl_zonemusic.lua"))()
timers.ZoneMusic_CreatePlayer()
local root, browser=panels[1],panels[2]
local function think() now=now+1;hooks.ZoneMusic_PlayerThink() end
local function test(name,fn) fn();print("PASS "..name) end
test("Entrer dans la zone affiche le lecteur sans activer la souris",function()
    think();assert(root.visible and not cursor and lastState.zone=="A")
end)
test("F3 bascule une seule fois par pression et le bandeau déroule le lecteur",function()
    f3=true;think();assert(cursor and browser.mouse)
    think();assert(cursor)
    browser.functions.toggle();think();assert(lastState.expanded)
    f3=false;think();f3=true;think();assert(not cursor)
    f3=false;think()
end)
test("Quitter la zone ferme le lecteur et libère la souris puis réentrer le réaffiche",function()
    commands.zonemusic_cursor();assert(cursor)
    ply.pos=Vector(5000,0,0);think();assert(not cursor)
    for _=1,8 do think() end
    assert(not root.visible)
    browser.functions.toggle()
    ply.pos=Vector(50,50,50);think();assert(root.visible and not lastState.expanded)
end)
test("Mourir ferme le lecteur et enlève les commandes admin",function()
    commands.zonemusic_cursor();ply.alive=false;think();assert(not cursor)
    ply.alive=true;think();assert(lastState.admin)
    ply.admin=false;think();assert(not lastState.admin);ply.admin=true
end)
test("Arrêt attend la confirmation native et annuler n’envoie rien",function()
    sent={};browser.functions.admin("admin_stop");assert(confirm and sent.name==nil)
    confirm();assert(sent.values[1]=="admin_stop" and sent.values[2]=="a")
end)
test("Une confirmation ouverte avant de quitter la zone ne vise pas une autre zone",function()
    browser.functions.admin("admin_stop");sent={}
    ply.pos=Vector(5000,0,0);think();confirm();assert(sent.name==nil)
    ply.pos=Vector(50,50,50);think()
end)
test("Le volume commun conserve la sourdine et plafonne la sortie à 20",function()
    timers.ZoneMusic_Check();timers.ZoneMusic_Check()
    for _=1,10 do timers.ZoneMusic_Check() end
    local channel=channels[#channels];assert(channel.volume>19 and channel.volume<=20)
    volume=0
    for _=1,100 do timers.ZoneMusic_Check() end
    assert(channel.volume<0.000001 and volume==0)
end)