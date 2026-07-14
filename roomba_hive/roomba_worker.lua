-- Roomba Hive Worker v0.1.0
-- Mining turtle requirements: mining tool + wireless/ender modem.

local VERSION = "0.1.0"
local PROTOCOL = "roomba_hive_v1"
local HOSTNAME = "roomba-hive"
local ROOT = "/roomba"
local STATE_FILE = fs.combine(ROOT, "worker_state.db")
local FUEL_SLOT = 1
local FIRST_STORAGE_SLOT = 2
local LAST_STORAGE_SLOT = 16
local FUEL_MARGIN = 96
local FUEL_TARGET = 2048
local MOVE_RETRY_DELAY = 0.4
local MAX_FALLING_DIGS = 32
local MAX_CALIBRATION_STEPS = 100000
local INVENTORY_CHECK_INTERVAL = 16

if not fs.exists(ROOT) then fs.makeDir(ROOT) end
local modem = peripheral.find("modem", function(_,p) return p.isWireless and p.isWireless() end)
assert(modem, "Worker requires a wireless or ender modem upgrade.")
local modemSide = peripheral.getName(modem)
rednet.open(modemSide)

local NORTH,EAST,SOUTH,WEST=0,1,2,3
local dirs={north=NORTH,east=EAST,south=SOUTH,west=WEST}
local dirNames={[0]="north",[1]="east",[2]="south",[3]="west"}
local vec={[0]={x=0,z=-1},[1]={x=1,z=0},[2]={x=0,z=1},[3]={x=-1,z=0}}
local dockInfo={
 north={x=0,z=-1,out=NORTH,inward=SOUTH},
 east ={x=1,z=0,out=EAST,inward=WEST},
 south={x=0,z=1,out=SOUTH,inward=NORTH},
 west ={x=-1,z=0,out=WEST,inward=EAST},
}
local neighbors={{dx=0,dz=-1,dir=NORTH},{dx=1,dz=0,dir=EAST},{dx=0,dz=1,dir=SOUTH},{dx=-1,dz=0,dir=WEST}}

local function key(x,z) return tostring(x)..","..tostring(z) end
local function parseKey(k) local c=k:find(",",1,true); return tonumber(k:sub(1,c-1)),tonumber(k:sub(c+1)) end
local function saveTable(path,v)
 local tmp=path..".tmp"; local h=assert(fs.open(tmp,"w"));h.write(textutils.serialize(v));h.close();if fs.exists(path) then fs.delete(path) end;fs.move(tmp,path)
end
local function loadTable(path) if not fs.exists(path) then return nil end local h=fs.open(path,"r");local v=textutils.unserialize(h.readAll());h.close();return type(v)=="table" and v or nil end
local state=loadTable(STATE_FILE) or {status="unassigned"}
local controller=state.controller
local dock=state.dock
local pos=state.pos or {x=0,y=0,z=0,dir=NORTH}
local interior,bounds,carved,wall={},nil,{},{}
local paused=false

local function persist()
 state.controller=controller;state.dock=dock;state.pos=pos;saveTable(STATE_FILE,state)
end
local function send(kind,data)
 if not controller then return false end
 data=data or {};data.type=kind;data.version=VERSION
 return rednet.send(controller,data,PROTOCOL)
end
local function reportError(message,extra)
 state.status="error";state.error=message;persist()
 local d=extra or {};d.message=message;d.position={x=pos.x,y=pos.y,z=pos.z,dir=dirNames[pos.dir]};send("worker_error",d)
 term.setTextColor(colors.red);print("\nWORKER STOPPED\n"..message);print(textutils.serialize(d.position));term.setTextColor(colors.white)
 error(message,0)
end
local function fuelLevel() return turtle.getFuelLevel() end
local function refuelFromSlot(target)
 if fuelLevel()=="unlimited" then return true end
 turtle.select(FUEL_SLOT)
 while fuelLevel()<target and turtle.getItemCount(FUEL_SLOT)>0 do
  if not turtle.refuel(1) then return false end
 end
 return fuelLevel()>=target
end
local function ensureFuel(amount)
 if fuelLevel()=="unlimited" then return end
 if fuelLevel()<amount and not refuelFromSlot(math.max(amount,FUEL_TARGET)) then reportError("Insufficient fuel in slot 1.",{fuel=fuelLevel(),required=amount}) end
end
local function turnLeft() turtle.turnLeft();pos.dir=(pos.dir+3)%4;persist() end
local function turnRight() turtle.turnRight();pos.dir=(pos.dir+1)%4;persist() end
local function turnAround() turnRight();turnRight() end
local function turnTo(d) local x=(d-pos.dir)%4;if x==1 then turnRight() elseif x==2 then turnAround() elseif x==3 then turnLeft() end end
local function advancePosition() local v=vec[pos.dir];pos.x=pos.x+v.x;pos.z=pos.z+v.z;persist() end
local function retreatPosition() local v=vec[pos.dir];pos.x=pos.x-v.x;pos.z=pos.z-v.z;persist() end

local function protectedBlock(data)
 local n=data and data.name or ""
 return n:find("computercraft") or n:find("chest") or n:find("barrel") or n:find("shulker")
end
local function entityBlockedMove()
 sleep(5)
 if turtle.forward() then advancePosition();return true end
 local occupied=turtle.inspect()
 if occupied then return false end
 turtle.attack()
 sleep(0.4)
 if turtle.forward() then advancePosition();return true end
 reportError("Entity remained in the path after waiting 5 seconds and attacking once.")
end
local function forwardOpen()
 ensureFuel(1)
 if turtle.forward() then advancePosition();return true end
 local occupied,data=turtle.inspect()
 if occupied then return false,"blocked by "..tostring(data and data.name) end
 return entityBlockedMove(),"entity obstruction"
end
local function forwardMine()
 ensureFuel(1)
 local v=vec[pos.dir];local nx,nz=pos.x+v.x,pos.z+v.z
 if not interior[key(nx,nz)] then return false,"map boundary",false end
 if turtle.forward() then advancePosition();carved[key(pos.x,pos.z)]=true;return true,nil,false end
 for _=1,MAX_FALLING_DIGS do
  local occupied,data=turtle.inspect()
  if occupied then
   if protectedBlock(data) or peripheral.hasType and peripheral.hasType("front","inventory") then reportError("Protected block/inventory in mining route: "..tostring(data and data.name)) end
   local ok,reason=turtle.dig()
   if not ok then reportError("Unable to dig block: "..tostring(reason),{block=data and data.name}) end
   if turtle.forward() then advancePosition();carved[key(pos.x,pos.z)]=true;return true,nil,true end
  else
   return entityBlockedMove(),"entity obstruction",false
  end
  sleep(MOVE_RETRY_DELAY)
 end
 reportError("Too many falling blocks prevented movement.")
end
local function up()
 ensureFuel(1)
 if turtle.up() then pos.y=pos.y+1;persist();return end
 local occupied,data=turtle.inspectUp()
 if occupied then reportError("Vertical shaft blocked above by "..tostring(data and data.name)) end
 sleep(5)
 if turtle.up() then pos.y=pos.y+1;persist();return end
 turtle.attackUp();sleep(.4)
 if turtle.up() then pos.y=pos.y+1;persist();return end
 reportError("Cannot ascend shaft after one attack.")
end
local function downOpen()
 ensureFuel(1)
 if turtle.down() then pos.y=pos.y-1;persist();return end
 local occupied,data=turtle.inspectDown()
 if occupied then reportError("Expected-open route blocked below by "..tostring(data and data.name)) end
 sleep(5)
 if turtle.down() then pos.y=pos.y-1;persist();return end
 turtle.attackDown();sleep(.4)
 if turtle.down() then pos.y=pos.y-1;persist();return end
 reportError("Entity remained below after waiting and attacking once.")
end
local function downDig()
 ensureFuel(1)
 if turtle.down() then pos.y=pos.y-1;persist();return end
 local occupied,data=turtle.inspectDown()
 if occupied then
  if protectedBlock(data) or (peripheral.hasType and peripheral.hasType("bottom","inventory")) then reportError("Protected block below shaft.") end
  local ok,reason=turtle.digDown();if not ok then reportError("Cannot dig shaft downward: "..tostring(reason)) end
  if turtle.down() then pos.y=pos.y-1;persist();return end
 else
  sleep(5);if turtle.down() then pos.y=pos.y-1;persist();return end;turtle.attackDown();sleep(.4);if turtle.down() then pos.y=pos.y-1;persist();return end
 end
 reportError("Cannot descend shaft.")
end

local function findPath(sx,sz,gx,gz,allowed)
 if sx==gx and sz==gz then return {} end
 local sk,gk=key(sx,sz),key(gx,gz);if not allowed[sk] or not allowed[gk] then return nil,"endpoint not allowed" end
 local q={{x=sx,z=sz}};local head=1;local seen={[sk]=true};local from={}
 while head<=#q do local c=q[head];head=head+1
  for _,n in ipairs(neighbors) do local x,z=c.x+n.dx,c.z+n.dz;local k=key(x,z)
   if allowed[k] and not seen[k] then seen[k]=true;from[k]={p=key(c.x,c.z),d=n.dir}
    if k==gk then local r={},{};local cur=k;local rev={};while cur~=sk do rev[#rev+1]=from[cur].d;cur=from[cur].p end;for i=#rev,1,-1 do r[#r+1]=rev[i] end;return r end
    q[#q+1]={x=x,z=z}
   end
  end
 end
 return nil,"no path"
end
local function followOpen(path)
 for _,d in ipairs(path) do turnTo(d);local ok,why=forwardOpen();if not ok then reportError("Known-open path blocked: "..tostring(why)) end end
end
local function countCells(m)local n=0;for _ in pairs(m) do n=n+1 end;return n end

-- Calibration on Y=-1, starting at center facing north.
local function inspectWall(relative)
 local original=pos.dir;if relative==-1 then turnLeft() elseif relative==1 then turnRight() end
 local occupied,data=turtle.inspect();if occupied then local v=vec[pos.dir];local wx,wz=pos.x+v.x,pos.z+v.z;wall[key(wx,wz)]=true end
 turnTo(original);return occupied,data
end
local function driveNorthWall()
 turnTo(NORTH)
 while true do if inspectWall(0) then return end local ok,why=forwardOpen();if not ok then reportError("Calibration could not reach north wall: "..tostring(why)) end end
end
local function tracePerimeter()
 turnRight();local sx,sz,sd=pos.x,pos.z,pos.dir;local moves,it=0,0
 while true do it=it+1;if it>MAX_CALIBRATION_STEPS*4 then reportError("Calibration loop exceeded safety limit.") end
  local lb=inspectWall(-1)
  if not lb then turnLeft();local ok,why=forwardOpen();if not ok then reportError("Calibration changed: "..tostring(why)) end;moves=moves+1
  elseif not inspectWall(0) then local ok,why=forwardOpen();if not ok then reportError("Calibration changed: "..tostring(why)) end;moves=moves+1
  else turnRight() end
  if moves>MAX_CALIBRATION_STEPS then reportError("Perimeter too large.") end
  if moves>0 and pos.x==sx and pos.z==sz and pos.dir==sd then break end
 end
end
local function buildInterior()
 local minX,maxX,minZ,maxZ=0,0,0,0
 for k in pairs(wall) do local x,z=parseKey(k);minX=math.min(minX,x);maxX=math.max(maxX,x);minZ=math.min(minZ,z);maxZ=math.max(maxZ,z) end
 local fminX,fmaxX,fminZ,fmaxZ=minX-1,maxX+1,minZ-1,maxZ+1
 interior={[key(0,0)]=true};local q={{x=0,z=0}};local head=1;local escaped=false
 bounds={minX=0,maxX=0,minZ=0,maxZ=0}
 while head<=#q do local c=q[head];head=head+1
  if c.x==fminX or c.x==fmaxX or c.z==fminZ or c.z==fmaxZ then escaped=true end
  bounds.minX=math.min(bounds.minX,c.x);bounds.maxX=math.max(bounds.maxX,c.x);bounds.minZ=math.min(bounds.minZ,c.z);bounds.maxZ=math.max(bounds.maxZ,c.z)
  for _,n in ipairs(neighbors) do local x,z=c.x+n.dx,c.z+n.dz;local k=key(x,z)
   if x>=fminX and x<=fmaxX and z>=fminZ and z<=fmaxZ and not wall[k] and not interior[k] then interior[k]=true;q[#q+1]={x=x,z=z} end
  end
 end
 if escaped then reportError("Calibration flood-fill escaped the outline.") end
end

local function enterCenterFromDockAtCurrentY()
 local d=dockInfo[dock];turnTo(d.inward);local ok,why=forwardOpen();if not ok then reportError("Cannot enter center from shaft: "..tostring(why)) end
end
local function leaveCenterToShaft()
 local d=dockInfo[dock];turnTo(d.out);local ok,why=forwardOpen();if not ok then reportError("Cannot return to dock shaft: "..tostring(why)) end
end
local function ascendDock()
 local d=dockInfo[dock]
 if pos.x~=d.x or pos.z~=d.z then reportError("Not at assigned shaft before ascent.") end
 while pos.y<0 do up() end
 turnTo(d.out)
end
local function descendDock(layer)
 local d=dockInfo[dock]
 if pos.x~=d.x or pos.z~=d.z or pos.y~=0 then reportError("Not at dock before descent.") end
 while pos.y>-layer do downDig() end
end
local function returnToDockFromCenter()
 leaveCenterToShaft();ascendDock()
end
local function goCenterForLayer(layer)
 descendDock(layer);enterCenterFromDockAtCurrentY();turnTo(NORTH)
end

local function storageFull() for s=FIRST_STORAGE_SLOT,LAST_STORAGE_SLOT do if turtle.getItemCount(s)==0 then return false end end return true end
local function dumpUp()
 for s=FIRST_STORAGE_SLOT,LAST_STORAGE_SLOT do
  while turtle.getItemCount(s)>0 do turtle.select(s);local before=turtle.getItemCount(s);turtle.dropUp();if turtle.getItemCount(s)>=before then state.status="output_full";persist();send("heartbeat",{status="output_full"});sleep(5) else state.status="working" end end
 end
 turtle.select(FUEL_SLOT)
end
local function requestFuelLock()
 while true do send("fuel_lock_request",{});local deadline=os.clock()+5
  while os.clock()<deadline do local id,msg,proto=rednet.receive(PROTOCOL,1);if id==controller and type(msg)=="table" then if msg.type=="fuel_lock_granted" then return elseif msg.type=="pause" then paused=true elseif msg.type=="resume" then paused=false end end end
 end
end
local function refuelAtStation(required)
 if fuelLevel()=="unlimited" then return end
 requestFuelLock();state.status="refueling";persist()
 local d=dockInfo[dock];turnTo(d.out)
 local ok,why=forwardOpen();if not ok then send("fuel_lock_release",{});reportError("Fuel route outward blocked: "..tostring(why)) end
 up();up();up();turnAround();ok,why=forwardOpen();if not ok then send("fuel_lock_release",{});reportError("Fuel chest approach blocked: "..tostring(why)) end
 turtle.select(FUEL_SLOT)
 while fuelLevel()<math.max(required,FUEL_TARGET) do
  if turtle.getItemCount(FUEL_SLOT)==0 then
   if not turtle.suck(64) then state.status="waiting_for_fuel";persist();send("heartbeat",{status="waiting_for_fuel",fuel=fuelLevel()});sleep(5) end
  end
  if turtle.getItemCount(FUEL_SLOT)>0 and not turtle.refuel(1) then send("fuel_lock_release",{});reportError("Fuel chest supplied a non-fuel item. Fuel chest must contain fuel only.") end
 end
 turnAround();forwardOpen();downOpen();downOpen();downOpen();turnAround();forwardOpen();turnTo(d.out)
 send("fuel_lock_release",{});state.status="docked";persist()
end

local function buildTargets()
 local rows={};for k in pairs(interior) do local x,z=parseKey(k);rows[z]=rows[z] or {};rows[z][#rows[z]+1]=x end
 local zs={};for z in pairs(rows) do zs[#zs+1]=z end;table.sort(zs)
 local t={};local lr=true;for _,z in ipairs(zs) do local xs=rows[z];table.sort(xs);if lr then for _,x in ipairs(xs) do t[#t+1]={x=x,z=z} end else for i=#xs,1,-1 do t[#t+1]={x=xs[i],z=z} end end;lr=not lr end;return t
end
local function between(x1,z1,x2,z2) if x2==x1 and z2==z1-1 then return NORTH elseif x2==x1+1 and z2==z1 then return EAST elseif x2==x1 and z2==z1+1 then return SOUTH elseif x2==x1-1 and z2==z1 then return WEST end end
local function buildRoute()
 local route={};local vx,vz=0,0;local moves=0
 local function add(d)local l=route[#route];if l and l.d==d then l.n=l.n+1 else route[#route+1]={d=d,n=1} end;moves=moves+1 end
 for _,t in ipairs(buildTargets()) do if vx~=t.x or vz~=t.z then local d=between(vx,vz,t.x,t.z);if d then add(d) else local p,e=findPath(vx,vz,t.x,t.z,interior);if not p then reportError("Cannot build route: "..tostring(e)) end;for _,pd in ipairs(p) do add(pd) end end;vx,vz=t.x,t.z end end
 return route,moves
end
local function routeCenter()
 if pos.x==0 and pos.z==0 then return end local p,e=findPath(pos.x,pos.z,0,0,carved);if not p then reportError("No carved return path: "..tostring(e)) end;followOpen(p)
end
local function reserveForDock(layer)
 local p=findPath(pos.x,pos.z,0,0,carved);return (p and #p or 0)+1+layer+10+FUEL_MARGIN
end
local function unloadReturn(layer,cx,cz)
 routeCenter();returnToDockFromCenter();dumpUp();if fuelLevel()~="unlimited" and fuelLevel()<FUEL_TARGET/2 then refuelAtStation(layer*2+FUEL_MARGIN) end;goCenterForLayer(layer);carved[key(0,0)]=true
 if cx~=0 or cz~=0 then local p,e=findPath(0,0,cx,cz,carved);if not p then reportError("Cannot return to checkpoint: "..tostring(e)) end;followOpen(p) end
end
local function handleControlNonblocking()
 while true do local ev,a,msg,proto=os.pullEventRaw();if ev=="rednet_message" and a==controller and proto==PROTOCOL and type(msg)=="table" then if msg.type=="pause" then paused=true elseif msg.type=="resume" then paused=false end;return elseif ev=="timer" then return elseif ev=="terminate" then error("Terminated",0) end end
end
local function waitIfPaused()
 while paused do state.status="paused";persist();send("heartbeat",{status="paused",layer=state.layer,fuel=fuelLevel(),position=pos});local id,msg,proto=rednet.receive(PROTOCOL,2);if id==controller and type(msg)=="table" and msg.type=="resume" then paused=false end end
end
local function excavateLayer(layer,route,totalMoves)
 state.layer=layer;state.status="mining";persist();send("layer_started",{layer=layer})
 carved={[key(0,0)]=true};local done=0;local check=0
 for _,run in ipairs(route) do turnTo(run.d);for _=1,run.n do waitIfPaused();local ok,why,dug=forwardMine();if not ok then reportError("Route failed: "..tostring(why)) end;done=done+1;check=check+1
  if dug or check>=INVENTORY_CHECK_INTERVAL then check=0
   local reserve=reserveForDock(layer)
   if fuelLevel()~="unlimited" and fuelLevel()<reserve then local cx,cz=pos.x,pos.z;unloadReturn(layer,cx,cz);if fuelLevel()<reserve then routeCenter();returnToDockFromCenter();refuelAtStation(reserve*2);goCenterForLayer(layer);local p=findPath(0,0,cx,cz,carved);followOpen(p) end;turnTo(run.d) end
   if storageFull() then local cx,cz=pos.x,pos.z;unloadReturn(layer,cx,cz);turnTo(run.d) end
  end
  if done%250==0 then send("heartbeat",{status="mining",layer=layer,fuel=fuelLevel(),position=pos,progress=done,total=totalMoves}) end
 end end
 for k in pairs(interior) do if not carved[k] then reportError("Layer verification failed at "..k) end end
 routeCenter();returnToDockFromCenter();dumpUp();send("layer_complete",{layer=layer});state.layer=nil;persist()
end

local function runCalibration(name)
 state.status="calibrating";persist();local d=dockInfo[dock]
 descendDock(1);enterCenterFromDockAtCurrentY();turnTo(NORTH);wall={};interior={};driveNorthWall();tracePerimeter();buildInterior()
 local p,e=findPath(pos.x,pos.z,0,0,interior);if not p then reportError("Cannot return after calibration: "..tostring(e)) end;followOpen(p);turnTo(NORTH)
 local map={version=3,name=name,interior=interior,bounds=bounds,cellCount=countCells(interior)}
 send("calibration_complete",{map=map});returnToDockFromCenter();state.status="docked";persist()
end
local function runSection(msg)
 interior=msg.map.interior;bounds=msg.map.bounds;state.jobId=msg.jobId;state.firstLayer=msg.firstLayer;state.lastLayer=msg.lastLayer;state.status="starting";persist()
 local route,moves=buildRoute()
 if fuelLevel()~="unlimited" and fuelLevel()<FUEL_TARGET/2 then refuelAtStation(msg.lastLayer*2+FUEL_MARGIN) end
 for layer=msg.firstLayer,msg.lastLayer do goCenterForLayer(layer);excavateLayer(layer,route,moves) end
 state.status="docked";state.jobId=nil;persist();send("section_complete",{firstLayer=msg.firstLayer,lastLayer=msg.lastLayer})
end

local function discoverController()
 while not controller do
  local id=rednet.lookup(PROTOCOL,HOSTNAME)
  if id then controller=id;persist();break end
  rednet.broadcast({type="hello",version=VERSION,status=state.status},PROTOCOL);sleep(2)
 end
 send("hello",{status=state.status,dock=dock,fuel=fuelLevel()})
end

local function dockProbeLoop()
 while true do
  os.pullEvent("redstone")
  if redstone.getInput("back") then
   controller = controller or rednet.lookup(PROTOCOL, HOSTNAME)
   if controller then
    persist()
    rednet.send(controller,{type="dock_probe",controller=controller},PROTOCOL)
   end
  end
 end
end
local function commandLoop()
 discoverController()
 while true do
  local sender,msg,proto=rednet.receive(PROTOCOL,5)
  if not sender then send("heartbeat",{status=state.status,layer=state.layer,fuel=fuelLevel(),position=pos})
  elseif proto==PROTOCOL and type(msg)=="table" then
   if msg.type=="dock_probe_begin" then controller=msg.controller;persist()
   elseif msg.type=="dock_assigned" then
    controller=msg.controller;dock=msg.dock;local d=dockInfo[dock];pos={x=d.x,y=0,z=d.z,dir=d.out};state.status="docked";persist();os.setComputerLabel("Roomba "..dock.." #"..os.getComputerID());send("hello",{status="docked",dock=dock,fuel=fuelLevel()})
   elseif msg.type=="calibrate" then if not dock then reportError("Worker is not dock-assigned.") end;runCalibration(msg.name)
   elseif msg.type=="start_section" then if not dock then reportError("Worker is not dock-assigned.") end;runSection(msg)
   elseif msg.type=="pause" then paused=true
   elseif msg.type=="resume" then paused=false
   end
  end
 end
end

term.clear();term.setCursorPos(1,1);print("Roomba Hive Worker v"..VERSION);print("ID: "..os.getComputerID());print("Modem: "..modemSide);print("Waiting for controller...")
local ok,err=pcall(function() parallel.waitForAny(dockProbeLoop,commandLoop) end)
if not ok then term.setTextColor(colors.red);printError(err);term.setTextColor(colors.white) end
