-- FS25_AssistedTreeFelling by PropaineX
--
-- Switches on the game's own crane auto-aim (AutomaticArmControlHarvester) on the Rottne H21D,
-- using the base-game John Deere 1270G settings (configs/*.xml; the 7000C files use the Logmax head's joint names).
-- Adds a hold key (Q) that does exactly what the game's own auto-aim key (O) does: the crane
-- reaches out to the marked tree. The player cuts it with the normal cut key.

AssistedTreeFelling = {}
AssistedTreeFelling.MOD_DIR = g_currentModDirectory
AssistedTreeFelling.MOD_NAME = g_currentModName

-- Left Shift+Q centre position per vehicle XML (lower case). Angles in degrees, telescope in metres.
-- Joints without an entry go to their start position from the vehicle XML.
-- h21d_706.xml: the user's own position, read from the server save (Downloads/savegame1(3).zip, vehicles.xml) on 2026-11-07
-- (photo pose: head low, arm out in front). Swing kept at 0 (save had -0.32).
AssistedTreeFelling.CENTRE = {
    ["h21d_706.xml"] = {swing = 0, lift = 4.285936, reach = -37.29129, telescope = -1.95, head = 0},
}

-- vehicle XML file name (lower case) -> our settings file
AssistedTreeFelling.CONFIGS = {
    ["h21d_7000c.xml"]    = "configs/h21D_7000C.xml",
    ["h21d_7000c_6w.xml"] = "configs/h21D_7000C_6W.xml",
    ["h21d_706.xml"]      = "configs/h21D_706.xml",
    ["h21d_706_6w.xml"]   = "configs/h21D_706_6W.xml",
}

function AssistedTreeFelling.getConfigFilename(vehicle)
    local filename = vehicle.configFileName
    if filename == nil then
        return nil
    end

    local lower = string.lower(filename)
    if string.find(lower, "rottne", 1, true) == nil then
        return nil
    end

    local baseName = string.match(lower, "([^/\\]+)$")
    local config = baseName ~= nil and AssistedTreeFelling.CONFIGS[baseName] or nil
    if config == nil then
        return nil
    end

    return Utils.getFilename(config, AssistedTreeFelling.MOD_DIR)
end


-- Load the auto-aim spec from our settings file instead of the vehicle XML (which has the block commented out)
local originalOnLoad = AutomaticArmControlHarvester.onLoad
AutomaticArmControlHarvester.onLoad = function(self, savegame)
    local configFilename = AssistedTreeFelling.getConfigFilename(self)
    if configFilename == nil or self.xmlFile:hasProperty("vehicle.automaticArmControlHarvester") then
        return originalOnLoad(self, savegame)
    end

    local configXml = XMLFile.load("assistedTreeFellingConfig", configFilename, Vehicle.xmlSchema)
    if configXml == nil then
        Logging.warning("[AssistedTreeFelling] Could not load '%s'", configFilename)
        return originalOnLoad(self, savegame)
    end
    if not configXml:hasProperty("vehicle.automaticArmControlHarvester") then
        Logging.warning("[AssistedTreeFelling] '%s' has no automaticArmControlHarvester block, auto-aim stays off", configFilename)
        configXml:delete()
        return originalOnLoad(self, savegame)
    end

    local vehicleXml = self.xmlFile
    self.xmlFile = configXml
    originalOnLoad(self, savegame)
    self.xmlFile = vehicleXml
    configXml:delete()

    local spec = self.spec_automaticArmControlHarvester
    if spec ~= nil and spec.treeDetectionNode ~= nil then
        self.assistedTreeFellingActive = true
        local baseName = string.match(string.lower(self.configFileName), "([^/\\]+)$")
        self.atfCentre = AssistedTreeFelling.CENTRE[baseName]
        Logging.info("[AssistedTreeFelling] Auto-aim switched on for '%s'", tostring(self.configFileName))
    else
        Logging.warning("[AssistedTreeFelling] Tree detection node not found on '%s', auto-aim stays off", tostring(self.configFileName))
    end
end


-- Add our hold key next to the game's own auto-aim key
local originalOnRegisterActionEvents = AutomaticArmControlHarvester.onRegisterActionEvents
AutomaticArmControlHarvester.onRegisterActionEvents = function(self, isActiveForInput, isActiveForInputIgnoreSelection)
    originalOnRegisterActionEvents(self, isActiveForInput, isActiveForInputIgnoreSelection)

    if self.isClient and self.assistedTreeFellingActive and isActiveForInputIgnoreSelection then
        local spec = self.spec_automaticArmControlHarvester
        local _, actionEventId = self:addPoweredActionEvent(spec.actionEvents, InputAction.ATF_AUTO_FELL, self, AssistedTreeFelling.actionEventAutoFell, true, false, true, true, nil)
        if actionEventId ~= nil then
            g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_VERY_HIGH)
            g_inputBinding:setActionEventActive(actionEventId, false)
        end

        -- Left Shift+Q: centre the crane (always available)
        _, actionEventId = self:addActionEvent(spec.actionEvents, InputAction.ATF_RETURN, self, AssistedTreeFelling.actionEventReturn, false, true, false, true, nil)
        if actionEventId ~= nil then
            g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_NORMAL)
        end
    end
end


-- Centre the crane: every aim joint back to its start position from the vehicle XML (as when unfolded).
-- First telescope / arms / head, then the swing (so it doesn't sweep round stretched out). Full speed.
AssistedTreeFelling.RETURN_TIMEOUT = 30000      -- ms, give up after this
AssistedTreeFelling.RETURN_IDLE_FRAMES = 10     -- frames with every joint at its target before it counts as done
AssistedTreeFelling.RETURN_ANGLE_TOLERANCE = math.rad(0.5)  -- a turning joint counts as there within half a degree

function AssistedTreeFelling.actionEventReturn(self, actionName, inputValue, callbackState, isAnalog)
    AssistedTreeFelling.startReturn(self)
end

function AssistedTreeFelling.startReturn(self, noEventSend)
    if self.isServer then
        self.atfReturnActive = true
        self.atfReturnStartTime = g_time
        self.atfReturnIdleFrames = 0
        local spec = self.spec_automaticArmControlHarvester
        spec.state = AutomaticArmControlHarvester.STATE_NONE
    elseif not noEventSend then
        g_client:getServerConnection():sendEvent(ATFReturnEvent.new(self))
    end
end

-- returns true while the tool still has to move
-- target: rotation in degrees / translation in metres from AssistedTreeFelling.CENTRE, or nil = start position from the vehicle XML
local function moveToolToStart(self, tool, target)
    if tool == nil then
        return false
    end

    local move = 0
    if tool.rotSpeed ~= nil and tool.rotationAxis ~= nil and tool.curRot ~= nil then
        local targetRot = target ~= nil and math.rad(target) or (tool.startRot or 0)
        if math.abs(tool.curRot[tool.rotationAxis] - targetRot) <= AssistedTreeFelling.RETURN_ANGLE_TOLERANCE then
            return false
        end
        move = AutomaticArmControlHarvester.calculateMovingToolTargetMove(self, tool, targetRot)
        if move == 0 then
            -- not there yet but the game says brake now (still moving): keep waiting, don't count as done
            return true
        end
    elseif tool.transSpeed ~= nil and tool.translationAxis ~= nil and tool.curTrans ~= nil and (target ~= nil or tool.startTrans ~= nil) then
        local offset = (target or tool.startTrans) - tool.curTrans[tool.translationAxis]
        if math.abs(offset) > 0.01 then
            -- full speed, slowing down over the last 25 cm so it doesn't overshoot
            move = math.max(-1, math.min(1, offset * 4))
        end
    end

    if move ~= 0 then
        tool.externalMove = move    -- full speed (only auto-aim is half speed)
        return true
    end
    return false
end

function AssistedTreeFelling.updateReturn(self)
    local spec = self.spec_automaticArmControlHarvester

    local centre = self.atfCentre or {}

    local busy = false
    if moveToolToStart(self, spec.yAlignment.movingTool, centre.lift) then busy = true end
    if moveToolToStart(self, spec.zAlignment.movingTool, centre.reach) then busy = true end
    for i = 1, #spec.alignmentNodes do
        -- head joints from the aim settings: the turning one is the head turn, the sliding one is the telescope
        local tool = spec.alignmentNodes[i].movingTool
        local target = centre.head
        if tool ~= nil and tool.transSpeed ~= nil then
            target = centre.telescope
        end
        if moveToolToStart(self, tool, target) then busy = true end
    end
    if not busy and moveToolToStart(self, spec.xAlignment.movingTool, centre.swing) then
        busy = true
    end

    if busy then
        self.atfReturnIdleFrames = 0
    else
        self.atfReturnIdleFrames = self.atfReturnIdleFrames + 1
    end

    if self.atfReturnIdleFrames >= AssistedTreeFelling.RETURN_IDLE_FRAMES or g_time - self.atfReturnStartTime > AssistedTreeFelling.RETURN_TIMEOUT then
        self.atfReturnActive = false
    end
end

local originalOnUpdate = AutomaticArmControlHarvester.onUpdate
AutomaticArmControlHarvester.onUpdate = function(self, dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    originalOnUpdate(self, dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)

    if self.isServer and self.atfReturnActive then
        AssistedTreeFelling.updateReturn(self)
    end
    -- Q release safety: no Q input for FELL_RELEASE_TIMEOUT -> released (on the player's own machine; a client sends it on)
    if self.atfFellLastInput ~= nil and g_time - self.atfFellLastInput > AssistedTreeFelling.FELL_RELEASE_TIMEOUT then
        self.atfFellLastInput = nil
        AssistedTreeFelling.setFellHeld(self, false)
    end
    if self.isServer and self.assistedTreeFellingActive and self.atfFellHeld then
        AssistedTreeFelling.updateFell(self)
    end
end


-- Left Shift+Q from a client in multiplayer: tell the server to centre the crane
-- Q held/released from a client in multiplayer: tell the server (it does the cut and the lift)
ATFFellEvent = {}
local ATFFellEvent_mt = Class(ATFFellEvent, Event)
InitEventClass(ATFFellEvent, "ATFFellEvent")

function ATFFellEvent.emptyNew()
    return Event.new(ATFFellEvent_mt)
end

function ATFFellEvent.new(vehicle, held)
    local self = ATFFellEvent.emptyNew()
    self.vehicle = vehicle
    self.held = held
    return self
end

function ATFFellEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.held = streamReadBool(streamId)
    self:run(connection)
end

function ATFFellEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteBool(streamId, self.held)
end

function ATFFellEvent:run(connection)
    if not connection:getIsServer() and self.vehicle ~= nil and self.vehicle.assistedTreeFellingActive then
        AssistedTreeFelling.setFellHeld(self.vehicle, self.held, true)
    end
end


ATFReturnEvent = {}
local ATFReturnEvent_mt = Class(ATFReturnEvent, Event)
InitEventClass(ATFReturnEvent, "ATFReturnEvent")

function ATFReturnEvent.emptyNew()
    return Event.new(ATFReturnEvent_mt)
end

function ATFReturnEvent.new(vehicle)
    local self = ATFReturnEvent.emptyNew()
    self.vehicle = vehicle
    return self
end

function ATFReturnEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self:run(connection)
end

function ATFReturnEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
end

function ATFReturnEvent:run(connection)
    if not connection:getIsServer() and self.vehicle ~= nil and self.vehicle.assistedTreeFellingActive then
        AssistedTreeFelling.startReturn(self.vehicle, true)
    end
end


-- Our key is shown only while there is a tree to aim at, same as the game's key
local originalUpdateActionEvents = AutomaticArmControlHarvester.updateActionEvents
AutomaticArmControlHarvester.updateActionEvents = function(self, state)
    originalUpdateActionEvents(self, state)

    local spec = self.spec_automaticArmControlHarvester
    if spec.actionEvents ~= nil then
        local actionEvent = spec.actionEvents[InputAction.ATF_AUTO_FELL]
        if actionEvent ~= nil then
            g_inputBinding:setActionEventActive(actionEvent.actionEventId, state)
        end
    end
end


-- Auto-aim moves the crane at half speed: every joint it drives is capped at half its normal speed
AssistedTreeFelling.SPEED_FACTOR = 0.5

local function limitExternalMove(movingTool)
    if movingTool ~= nil and movingTool.externalMove ~= nil and movingTool.externalMove ~= 0 then
        local limit = AssistedTreeFelling.SPEED_FACTOR
        movingTool.externalMove = math.max(-limit, math.min(limit, movingTool.externalMove))
    end
end

-- Swing (X alignment) done from the live head position, seen from above.
-- The game's own X alignment assumes the swing tool turns about its local Y axis (John Deere);
-- the Rottne's craneYRotDummy turns about its local Z axis, so the game's maths puts the head beside the tree.
function AssistedTreeFelling.doSwingAlignment(self, swingTool, tx, tz, direction)
    local spec = self.spec_automaticArmControlHarvester
    -- Aim with the crane tip (xAlignment referenceNode, above the head's loose joint), NOT the hanging head:
    -- chasing the swaying head made the crane follow the sway and rock the machine over (test run 1.1.0.1, 20 deg).
    local headNode = spec.xAlignment.referenceNode or spec.yAlignment.referenceNode or spec.zAlignment.referenceNode
    if headNode == nil then
        return
    end

    local px, _, pz = getWorldTranslation(swingTool.node)
    local hx, _, hz = getWorldTranslation(headNode)
    local ax, az = hx - px, hz - pz     -- pivot -> head
    local bx, bz = tx - px, tz - pz     -- pivot -> tree

    -- angle (about world up) that turns the head direction onto the tree direction
    local delta = math.atan2(az * bx - ax * bz, ax * bx + az * bz)

    -- which way a positive tool rotation turns the crane, seen from above
    local axis = swingTool.rotationAxis or 2
    local lx, ly, lz = 0, 0, 0
    if axis == 1 then lx = 1 elseif axis == 2 then ly = 1 else lz = 1 end
    local _, upY, _ = localDirectionToWorld(swingTool.node, lx, ly, lz)
    if math.abs(upY) < 0.1 then
        return
    end
    delta = delta * (upY > 0 and 1 or -1)

    local curRot = swingTool.curRot[axis]
    local move = AutomaticArmControlHarvester.calculateMovingToolTargetMove(self, swingTool, curRot + delta)
    if move ~= 0 then
        swingTool.externalMove = move
    elseif math.abs(delta) < spec.xAlignment.threshold and spec.state == AutomaticArmControlHarvester.STATE_ALIGN_X then
        spec.state = AutomaticArmControlHarvester.NEXT_STATE[direction][spec.state]
    end
end

-- the tree in the head counts as the aimed tree when its foot is this close (m, seen from above)
AssistedTreeFelling.TARGET_TREE_DISTANCE = 1.5
-- head counts as stuck when it moves less than this (m) ...
AssistedTreeFelling.STUCK_DISTANCE = 0.02
-- ... for this long (ms) while pulling back, swinging or reaching
AssistedTreeFelling.STUCK_TIME = 1500

-- head counts as down at cut height within this (m)
AssistedTreeFelling.HEIGHT_TOLERANCE = 0.05
-- while reaching: head stays this high (m above the ground under it) until it is within APPROACH_DISTANCE (m) of the trunk
AssistedTreeFelling.APPROACH_HEIGHT = 0.8
AssistedTreeFelling.APPROACH_DISTANCE = 0.6
-- stop the aim if the machine tilts more than this (degrees) beyond its tilt when the aim started
AssistedTreeFelling.TILT_LIMIT = 4
-- once the tree is green: this much tilt rise (degrees) = head is on the ground, stop there
AssistedTreeFelling.GROUND_CONTACT_TILT = 1
-- ... and never let the aim go on above this tilt (degrees)
AssistedTreeFelling.TILT_MAX = 8
-- reaching: stop if the head gets no closer to the trunk by NO_PROGRESS_DISTANCE (m) in NO_PROGRESS_TIME (ms)
-- (the hanging head sways, so the 2 cm stuck rule alone never fired while the arm sat at its end stop)
AssistedTreeFelling.NO_PROGRESS_DISTANCE = 0.05
AssistedTreeFelling.NO_PROGRESS_TIME = 3000

function AssistedTreeFelling.getTilt(self)
    local _, upY, _ = localDirectionToWorld(self.rootNode, 0, 1, 0)
    return math.deg(math.acos(math.max(-1, math.min(1, upY))))
end

-- true when the tree in the head's cut area is the aimed tree (= green ring)
function AssistedTreeFelling.isAimedTreeCuttable(self, tx, tz)
    local woodSpec = self.spec_woodHarvester
    if woodSpec == nil or woodSpec.curSplitShape == nil or not entityExists(woodSpec.curSplitShape) then
        return false
    end
    local sx, _, sz = getWorldTranslation(woodSpec.curSplitShape)
    return MathUtil.vector2Length(sx - tx, sz - tz) <= AssistedTreeFelling.TARGET_TREE_DISTANCE
end

-- true when the aimed tree is cuttable (green ring) AND the head is down at the cut height
-- (the game allows the cut while the head is still high, which would leave a tall stump)
function AssistedTreeFelling.isHeadOnTargetTree(self, tx, ty, tz)
    local woodSpec = self.spec_woodHarvester
    if woodSpec == nil or woodSpec.curSplitShape == nil or not entityExists(woodSpec.curSplitShape) then
        return false
    end
    local sx, _, sz = getWorldTranslation(woodSpec.curSplitShape)
    if MathUtil.vector2Length(sx - tx, sz - tz) > AssistedTreeFelling.TARGET_TREE_DISTANCE then
        return false
    end

    -- same target height as the game's yAlignment (AutomaticArmControlHarvester:doTreeArmAlignment)
    local spec = self.spec_automaticArmControlHarvester
    local heightNode = spec.yAlignment.referenceNode
    if heightNode == nil then
        return true
    end
    local cx, cy, cz = getWorldTranslation(heightNode)
    local terrainY = getTerrainHeightAtWorldPos(g_terrainNode, cx, cy, cz)
    local targetY = math.max(ty - spec.treeDetectionNodeCutHeightSafetyOffset, terrainY + spec.treeDetectionNodeCutHeight)
    return math.abs(cy - targetY) <= AssistedTreeFelling.HEIGHT_TOLERANCE
end

function AssistedTreeFelling.isHeadStuck(self, spec)
    local headNode = spec.yAlignment.referenceNode or spec.zAlignment.referenceNode
    if headNode == nil or (spec.state ~= AutomaticArmControlHarvester.STATE_ALIGN_X and spec.state ~= AutomaticArmControlHarvester.STATE_ALIGN_Z
        and spec.state ~= AutomaticArmControlHarvester.STATE_MOVE_BACK) then
        spec.atfStuckX = nil
        return false
    end

    local x, y, z = getWorldTranslation(headNode)
    if spec.atfStuckX == nil or MathUtil.vector3Length(x - spec.atfStuckX, y - spec.atfStuckY, z - spec.atfStuckZ) > AssistedTreeFelling.STUCK_DISTANCE then
        spec.atfStuckX, spec.atfStuckY, spec.atfStuckZ = x, y, z
        spec.atfStuckTime = g_time
        return false
    end

    return g_time - spec.atfStuckTime > AssistedTreeFelling.STUCK_TIME
end

-- the sliding head joint from the aim settings (telescope), or nil
function AssistedTreeFelling.getTelescopeTool(spec)
    for i = 1, #spec.alignmentNodes do
        local tool = spec.alignmentNodes[i].movingTool
        if tool ~= nil and tool.transSpeed ~= nil and tool.translationAxis ~= nil and tool.curTrans ~= nil then
            return tool
        end
    end
    return nil
end

-- true when the tool is being driven into its end stop (within half a degree / 1 cm of its limit, moving that way)
function AssistedTreeFelling.isToolAtLimit(tool)
    if tool == nil or tool.externalMove == nil or tool.externalMove == 0 then
        return false
    end
    local move = tool.externalMove
    if tool.rotSpeed ~= nil and tool.rotationAxis ~= nil and tool.curRot ~= nil then
        local cur = tool.curRot[tool.rotationAxis]
        local eps = math.rad(0.5)
        if move < 0 and tool.rotMin ~= nil and cur <= tool.rotMin + eps then return true end
        if move > 0 and tool.rotMax ~= nil and cur >= tool.rotMax - eps then return true end
    elseif tool.transSpeed ~= nil and tool.translationAxis ~= nil and tool.curTrans ~= nil then
        local cur = tool.curTrans[tool.translationAxis]
        if move < 0 and tool.transMin ~= nil and cur <= tool.transMin + 0.01 then return true end
        if move > 0 and tool.transMax ~= nil and cur >= tool.transMax - 0.01 then return true end
    end
    return false
end

-- reason: "ground" / "height" (head down at the tree: Q may cut), anything else (or nil): Q must not cut
function AssistedTreeFelling.stopAlignment(self, spec, reason)
    spec.state = AutomaticArmControlHarvester.STATE_FINISHED
    spec.atfStopReason = reason
    spec.atfStuckX = nil
    local tools = {spec.xAlignment.movingTool, spec.yAlignment.movingTool, spec.zAlignment.movingTool}
    for i = 1, #spec.alignmentNodes do
        table.insert(tools, spec.alignmentNodes[i].movingTool)
    end
    for _, tool in pairs(tools) do
        if tool ~= nil then
            tool.externalMove = 0
        end
    end
end

local originalDoTreeArmAlignment = AutomaticArmControlHarvester.doTreeArmAlignment
AutomaticArmControlHarvester.doTreeArmAlignment = function(self, tx, ty, tz, direction)
    if not self.assistedTreeFellingActive then
        return originalDoTreeArmAlignment(self, tx, ty, tz, direction)
    end

    local spec = self.spec_automaticArmControlHarvester

    -- aiming cancels centring the crane
    self.atfReturnActive = false

    -- after the Q cut: no more aiming until Q is let go (the tree is in the head now)
    if self.atfFellHeld and self.atfFellPhase ~= nil and self.atfFellPhase ~= "aim" then
        return
    end

    -- stop rules: the game only finishes when the head is within 3 cm of its target point, which the Rottne's
    -- hanging head never reaches, so the crane kept pushing (and tipped the machine). Stop instead when
    -- 1) the head is in cutting position on the aimed tree (green ring), or 2) the head is stuck.
    if spec.state == AutomaticArmControlHarvester.STATE_FINISHED then
        return
    end
    -- tilt guard. A new aim (no aim call for 1 s) takes the current tilt as its start; during one aim the start
    -- value can only go DOWN (test run 1.1.0.3 took 6.3 deg while the machine was still rocking and allowed 10.9).
    -- Stop if the tilt rises TILT_LIMIT above the start, or goes over TILT_MAX at all (unless parked steeper than that).
    local tilt = AssistedTreeFelling.getTilt(self)
    if spec.atfStartTilt == nil or spec.atfLastAimTime == nil or g_time - spec.atfLastAimTime > 1000 then
        spec.atfStartTilt = tilt
        spec.atfBestToTrunk = nil
        spec.atfStopReason = nil
    else
        spec.atfStartTilt = math.min(spec.atfStartTilt, tilt)
    end
    spec.atfLastAimTime = g_time
    if tilt - spec.atfStartTilt > AssistedTreeFelling.TILT_LIMIT
        or (tilt > AssistedTreeFelling.TILT_MAX and tilt > spec.atfStartTilt + 1) then
        Logging.warning("[AssistedTreeFelling] Auto-aim stopped: machine tilted %.1f deg (started at %.1f)", tilt, spec.atfStartTilt)
        AssistedTreeFelling.stopAlignment(self, spec, "tilt")
        return
    end

    -- ground contact: once the aimed tree is cuttable (green), a tilt rise of GROUND_CONTACT_TILT means the head is on
    -- the ground; that is as low as it can go here, so stop instead of pressing the machine up (test runs 1.1.0.3)
    if tilt - spec.atfStartTilt > AssistedTreeFelling.GROUND_CONTACT_TILT and AssistedTreeFelling.isAimedTreeCuttable(self, tx, tz) then
        Logging.info("[AssistedTreeFelling] Auto-aim done: head on the ground at the tree (tilt %.1f, started at %.1f)", tilt, spec.atfStartTilt)
        AssistedTreeFelling.stopAlignment(self, spec, "ground")
        return
    end

    if AssistedTreeFelling.isHeadOnTargetTree(self, tx, ty, tz) then
        Logging.info("[AssistedTreeFelling] Auto-aim done: head at cut height on the tree")
        AssistedTreeFelling.stopAlignment(self, spec, "height")
        return
    end
    if AssistedTreeFelling.isHeadStuck(self, spec) then
        Logging.info("[AssistedTreeFelling] Auto-aim stopped: head stuck")
        AssistedTreeFelling.stopAlignment(self, spec, "stuck")
        return
    end

    -- let the game do everything except the swing
    local swingTool = spec.xAlignment.movingTool
    spec.xAlignment.movingTool = nil
    originalDoTreeArmAlignment(self, tx, ty, tz, direction)
    spec.xAlignment.movingTool = swingTool

    -- The game's own aim says "finished" as soon as the reach is within 3 cm of its target, which also stops the
    -- lowering, even with the head still high (1.2.1.0: "Not cutting ... (nil)"). Keep going: back to the
    -- reach/lower step until one of our rules ends it (ground, cut height, stuck, no progress, out of reach, tilt).
    if spec.state == AutomaticArmControlHarvester.STATE_FINISHED and spec.atfStopReason == nil then
        spec.state = AutomaticArmControlHarvester.STATE_ALIGN_Z
    end

    -- Pull-back step: for a tree far to the side the game's pull-back point is behind the crane base, so the reach
    -- joint runs into its limit and the step never finishes (test run 1.1.0.2: main arm at -66 deg, swing never started).
    -- Once the reach joint is at its limit, count the pull-back as done and go on to the swing.
    if spec.state == AutomaticArmControlHarvester.STATE_MOVE_BACK and AssistedTreeFelling.isToolAtLimit(spec.zAlignment.movingTool) then
        spec.zAlignment.movingTool.externalMove = 0
        spec.atfStuckX = nil
        spec.state = AutomaticArmControlHarvester.NEXT_STATE[direction][spec.state]
    end

    -- Come in high, drop at the tree: the game lowers the head to cut height while still reaching, so the head hit the
    -- ground ~2 m short of the tree and the crane levered the machine over (test run 1.1.0.2, 20 deg). While the head is
    -- further than APPROACH_DISTANCE from the trunk, hold it APPROACH_HEIGHT above the ground under the head instead.
    if spec.state == AutomaticArmControlHarvester.STATE_ALIGN_Z and spec.yAlignment.movingTool ~= nil and spec.yAlignment.referenceNode ~= nil then
        local hx, hy, hz = getWorldTranslation(spec.yAlignment.referenceNode)
        local toTrunk = MathUtil.vector2Length(hx - tx, hz - tz) - (spec.lastRadius or 0)

        -- no progress towards the trunk -> stop
        if spec.atfBestToTrunk == nil or toTrunk < spec.atfBestToTrunk - AssistedTreeFelling.NO_PROGRESS_DISTANCE then
            spec.atfBestToTrunk = toTrunk
            spec.atfBestToTrunkTime = g_time
        elseif g_time - spec.atfBestToTrunkTime > AssistedTreeFelling.NO_PROGRESS_TIME then
            Logging.info("[AssistedTreeFelling] Auto-aim stopped: head got no closer to the tree (%.2f m from the trunk)", toTrunk)
            AssistedTreeFelling.stopAlignment(self, spec, "noprogress")
            return
        end

        -- telescope: the game's aim only uses the main arm. When the main arm is at its end stop and the head is still
        -- short of the trunk, push the telescope out (test run 1.1.0.3: 7.5 m tree, arm at its stop, telescope never moved).
        if toTrunk > AssistedTreeFelling.APPROACH_DISTANCE and AssistedTreeFelling.isToolAtLimit(spec.zAlignment.movingTool) then
            local telescope = AssistedTreeFelling.getTelescopeTool(spec)
            if telescope ~= nil and telescope.transMax ~= nil and telescope.curTrans[telescope.translationAxis] < telescope.transMax - 0.01 then
                telescope.externalMove = 1
            else
                Logging.info("[AssistedTreeFelling] Auto-aim stopped: tree out of reach (arm and telescope at their limits, head %.2f m from the trunk)", toTrunk)
                AssistedTreeFelling.stopAlignment(self, spec, "reach")
                return
            end
        end

        if toTrunk > AssistedTreeFelling.APPROACH_DISTANCE then
            local terrainY = getTerrainHeightAtWorldPos(g_terrainNode, hx, hy, hz)
            local offset = (terrainY + AssistedTreeFelling.APPROACH_HEIGHT) - hy
            if math.abs(offset) > 0.03 then
                -- same formula and sign as the game's yAlignment, with the higher target
                spec.yAlignment.movingTool.externalMove = (offset + 0.5 * math.sign(offset)) * spec.yAlignment.speedScale
            else
                spec.yAlignment.movingTool.externalMove = 0
            end
        end
    end

    if swingTool ~= nil and spec.state ~= AutomaticArmControlHarvester.STATE_NONE
        and spec.state ~= AutomaticArmControlHarvester.STATE_FINISHED and spec.state ~= AutomaticArmControlHarvester.STATE_MOVE_BACK then
        local prerequisitesDone = true
        for i = 1, #spec.alignmentNodes do
            local node = spec.alignmentNodes[i]
            if node.isPrerequisite and node.movingTool.externalMove ~= 0 then
                prerequisitesDone = false
            end
        end
        if prerequisitesDone then
            AssistedTreeFelling.doSwingAlignment(self, swingTool, tx, tz, direction)
        end
    end

    do
        limitExternalMove(swingTool)
        limitExternalMove(spec.yAlignment.movingTool)
        limitExternalMove(spec.zAlignment.movingTool)
        for i = 1, #spec.alignmentNodes do
            limitExternalMove(spec.alignmentNodes[i].movingTool)
        end
    end
end


function AssistedTreeFelling.actionEventAutoFell(self, actionName, inputValue, callbackState, isAnalog)
    -- aiming: exactly what the game's own auto-aim key does
    self:setTreeArmAlignmentInput(inputValue)
    -- plus (Q only, not O): cut when the head is on the tree at the ground, then lift the tree
    if inputValue > 0 then
        self.atfFellLastInput = g_time
    end
    AssistedTreeFelling.setFellHeld(self, inputValue > 0)
end


-- Q held: after the aim ends with the head on the aimed tree (green), cut it (cutTree(0) keeps it in the head),
-- then lift the head until the saw is LIFT_HEIGHT above the ground, and hold it there. Letting go of Q stops it.
AssistedTreeFelling.LIFT_HEIGHT = 2.25         -- m, saw above the ground after the cut (user set 2.25 m on 2026-11-06 after testing 2.6)
-- Q cuts as soon as the ring is green and the bottom of the HEAD is within HEAD_GROUND_GAP of the ground (user, 2026-11-07:
-- "I don't care where the saw is"). Measured on the head itself: short rays straight up from the ground on a grid under the
-- head; the closest hit on the head's own part = the gap. UNTESTED.
AssistedTreeFelling.HEAD_GROUND_GAP = 0.02      -- m, head bottom to ground
AssistedTreeFelling.HEAD_SCAN_HALF = 0.75       -- m, grid reaches this far each way from the head's centre (head ~1.3 x 1.5 m)
AssistedTreeFelling.HEAD_SCAN_STEP = 0.25       -- m between rays
AssistedTreeFelling.HEAD_SCAN_START = 0.2       -- m, rays start this far BELOW the ground (they only hit vehicles), so a head
                                                -- pressed into the ground is still found (gap 0 or less)
AssistedTreeFelling.HEAD_SCAN_LENGTH = 0.7      -- m, rays look this far up (= 0.5 m above the ground)

-- ray hit: keep it only when it is the head's own part (another part of the machine above the ground doesn't count)
function AssistedTreeFelling.headScanCallback(self, hitObjectId, x, y, z, distance)
    if hitObjectId ~= nil and hitObjectId ~= 0 and self:getParentComponent(hitObjectId) == self.atfScanHead then
        self.atfScanHit = distance
    end
    return false
end

-- smallest gap (m) between the bottom of the harvester head and the ground under it, or nil when the head is higher than
-- HEAD_SCAN_LENGTH (or not found)
function AssistedTreeFelling.getHeadGroundGap(self)
    local woodSpec = self.spec_woodHarvester
    if woodSpec == nil or woodSpec.cutNode == nil or self.getParentComponent == nil then
        return nil
    end
    local head = self:getParentComponent(woodSpec.cutNode)
    if head == nil or head == 0 then   -- Vehicle:getParentComponent returns 0 when not found (game Lua source)
        return nil
    end
    local cx, _, cz = getWorldTranslation(head)
    local best = nil
    self.atfScanHead = head
    self.atfHeadScanCallback = AssistedTreeFelling.headScanCallback
    local half, step = AssistedTreeFelling.HEAD_SCAN_HALF, AssistedTreeFelling.HEAD_SCAN_STEP
    for dx = -half, half + 0.001, step do
        for dz = -half, half + 0.001, step do
            local x, z = cx + dx, cz + dz
            local y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) - AssistedTreeFelling.HEAD_SCAN_START
            self.atfScanHit = nil
            raycastClosest(x, y, z, 0, 1, 0, AssistedTreeFelling.HEAD_SCAN_LENGTH, "atfHeadScanCallback", self, CollisionFlag.VEHICLE)
            if self.atfScanHit ~= nil then
                local gap = self.atfScanHit - AssistedTreeFelling.HEAD_SCAN_START
                if best == nil or gap < best then
                    best = gap
                end
            end
        end
    end
    return best
end

AssistedTreeFelling.CUT_WAIT_TIMEOUT = 5000    -- ms to wait for the cut to take the tree into the head
AssistedTreeFelling.LIFT_TIMEOUT = 10000       -- ms, give up lifting after this
-- Q counts as released when no Q input came for this long (ms). The game deactivates the Q action once the tree is
-- cut (no target any more), so the "released" call can be missed (1.2.2.0: aiming stayed blocked after a felling).
AssistedTreeFelling.FELL_RELEASE_TIMEOUT = 300
AssistedTreeFelling.LIFT_SPEED = 1.0           -- lift after the cut: full speed (aiming stays at SPEED_FACTOR 0.5)
AssistedTreeFelling.LIFT_SLOWDOWN = 0.5        -- m below the target where the lift starts easing off
AssistedTreeFelling.LIFT_MIN_SPEED = 0.15      -- slowest lift speed near the target

-- on-screen message (the game's corner popup). Shown on the machine that runs this code (host / single player).
function AssistedTreeFelling.showMessage(self, text)
    if g_currentMission ~= nil and g_currentMission.addIngameNotification ~= nil then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, text)
    end
end

function AssistedTreeFelling.setFellHeld(self, held, noEventSend)
    if self.isServer then
        if held ~= (self.atfFellHeld == true) then
            self.atfFellHeld = held
            if held then
                self.atfFellPhase = "aim"
            else
                self.atfFellPhase = nil
            end
        end
    elseif not noEventSend and held ~= (self.atfFellHeldSent == true) then
        self.atfFellHeldSent = held
        g_client:getServerConnection():sendEvent(ATFFellEvent.new(self, held))
    end
end

function AssistedTreeFelling.updateFell(self)
    local spec = self.spec_automaticArmControlHarvester
    local woodSpec = self.spec_woodHarvester
    if woodSpec == nil or self.atfFellPhase == nil or self.atfFellPhase == "done" then
        return
    end

    if self.atfFellPhase == "aim" then
        -- user's rule (2026-11-07): ring green + head within 2 cm of the ground = cut, whatever the aim is doing
        -- (on the server the aim stopped as "stuck" with the head on the ground at the tree, and Q never cut).
        if not woodSpec.hasAttachedSplitShape and woodSpec.cutTimer == -1 and self:getIsTurnedOn()
            and AssistedTreeFelling.isAimedTreeCuttable(self, spec.lastTargetTrans[1], spec.lastTargetTrans[3]) then
            local headBottom = AssistedTreeFelling.getHeadGroundGap(self)
            if headBottom ~= nil and headBottom <= AssistedTreeFelling.HEAD_GROUND_GAP then
                AssistedTreeFelling.stopAlignment(self, spec, "ground")
                self:cutTree(0)
                self.atfFellPhase = "cut"
                self.atfFellTime = g_time
                Logging.info("[AssistedTreeFelling] Cutting the tree: head %.2f m above the ground, ring green", headBottom)
                return
            end
        end
        if spec.state == AutomaticArmControlHarvester.STATE_FINISHED
            and spec.atfStopReason ~= "ground" and spec.atfStopReason ~= "height" then
            -- stopped for another reason (stuck, no progress, out of reach, tilt): the head is NOT down at the tree,
            -- so don't cut (1.2.0.0 cut a tree ~1 m up after a stuck stop). Tell the player.
            self.atfFellPhase = "done"
            Logging.info("[AssistedTreeFelling] Not cutting: aim stopped before the head was down at the tree (%s)", tostring(spec.atfStopReason))
            AssistedTreeFelling.showMessage(self, "Assisted felling: head didn't get down to the tree, not cutting. Let go of Q and try again, or cut with X.")
            return
        end
        if spec.state == AutomaticArmControlHarvester.STATE_FINISHED and not woodSpec.hasAttachedSplitShape
            and woodSpec.cutTimer == -1 and self:getIsTurnedOn()
            and AssistedTreeFelling.isAimedTreeCuttable(self, spec.lastTargetTrans[1], spec.lastTargetTrans[3]) then
            self:cutTree(0)
            self.atfFellPhase = "cut"
            self.atfFellTime = g_time
            Logging.info("[AssistedTreeFelling] Cutting the tree")
        end

    elseif self.atfFellPhase == "cut" then
        if woodSpec.hasAttachedSplitShape then
            self.atfFellPhase = "lift"
            self.atfFellTime = g_time
            self.atfLiftStartTilt = AssistedTreeFelling.getTilt(self)
        elseif g_time - self.atfFellTime > AssistedTreeFelling.CUT_WAIT_TIMEOUT then
            Logging.info("[AssistedTreeFelling] Cut did not take the tree into the head, stopping")
            self.atfFellPhase = "done"
        end

    elseif self.atfFellPhase == "lift" then
        local liftTool = spec.yAlignment.movingTool
        if liftTool == nil or woodSpec.cutNode == nil then
            self.atfFellPhase = "done"
            return
        end
        local tilt = AssistedTreeFelling.getTilt(self)
        if tilt - self.atfLiftStartTilt > AssistedTreeFelling.TILT_LIMIT then
            Logging.warning("[AssistedTreeFelling] Lift stopped: machine tilted %.1f deg (lift started at %.1f)", tilt, self.atfLiftStartTilt)
            self.atfFellPhase = "done"
            return
        end
        local x, y, z = getWorldTranslation(woodSpec.cutNode)
        local terrainY = getTerrainHeightAtWorldPos(g_terrainNode, x, y, z)
        local offset = (terrainY + AssistedTreeFelling.LIFT_HEIGHT) - y
        if offset > 0.03 and g_time - self.atfFellTime < AssistedTreeFelling.LIFT_TIMEOUT then
            -- same formula and sign as the game's yAlignment (speedScale -0.5 on the 706: negative move = head up), half speed
            -- full speed (user: lift faster after the cut), easing off over the last ~0.5 m so it doesn't overshoot
            -- speed: full until LIFT_SLOWDOWN m below the target, then proportional down to LIFT_MIN_SPEED.
            -- direction: same sign as the game's yAlignment (speedScale -0.5 on the 706: negative move = head up)
            local speed = math.max(AssistedTreeFelling.LIFT_MIN_SPEED, math.min(AssistedTreeFelling.LIFT_SPEED, offset / AssistedTreeFelling.LIFT_SLOWDOWN))
            liftTool.externalMove = speed * math.sign(spec.yAlignment.speedScale)
        else
            Logging.info("[AssistedTreeFelling] Tree lifted: saw %.2f m above the ground", y - terrainY)
            self.atfFellPhase = "done"
        end
    end
end
