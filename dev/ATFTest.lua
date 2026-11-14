-- FS25_AssistedTreeFelling: in-game test run (TEST BUILDS ONLY, not for release)
--
-- Left Ctrl + Left Shift + Q in a Rottne with the mod active: finds the trees the auto-aim can reach from where
-- the machine stands, aims at each one in turn through the game's own auto-aim code (with this mod's fixes,
-- exactly the Q path), logs where the saw ends up, centres the crane (Ctrl+Q code) and logs that too.
-- Never cuts. Press the keys again to stop. All lines in log.txt start with "[ATF-TEST]".
-- Single player / host only (runs on the server side).

ATFTest = {}
ATFTest.MAX_TREES = 8
ATFTest.SCAN_TIME = 1000         -- ms to collect overlap results
ATFTest.AIM_TIMEOUT = 25000      -- ms per tree
ATFTest.CENTRE_TIMEOUT = 35000   -- ms
ATFTest.SAMPLE_TIME = 250        -- ms between progress lines
ATFTest.TILT_ABORT = 20          -- degrees: stop everything if the machine tilts more than this

-- on-screen message in the game (the popup in the corner), so the player sees progress without the log
-- kind: "info", "ok" or "critical"
local function notify(kind, fmt, ...)
    local text = "Tree felling test: " .. string.format(fmt, ...)
    local ok = pcall(function()
        local nType = FSBaseMission.INGAME_NOTIFICATION_INFO
        if kind == "ok" then
            nType = FSBaseMission.INGAME_NOTIFICATION_OK
        elseif kind == "critical" then
            nType = FSBaseMission.INGAME_NOTIFICATION_CRITICAL
        end
        g_currentMission:addIngameNotification(nType, text)
    end)
    if not ok then
        Logging.warning("[ATF-TEST] could not show on-screen message: %s", text)
    end
end

local function log(fmt, ...)
    Logging.info("[ATF-TEST] " .. fmt, ...)
end

local STATE_NAMES = {}
local function stateName(state)
    if next(STATE_NAMES) == nil then
        for _, n in ipairs({"STATE_NONE", "STATE_ALIGN_X", "STATE_MOVE_BACK", "STATE_ALIGN_Z", "STATE_FINISHED"}) do
            local v = AutomaticArmControlHarvester[n]
            if v ~= nil then
                STATE_NAMES[v] = string.sub(n, 7)
            end
        end
    end
    return STATE_NAMES[state] or tostring(state)
end

-- machine tilt in degrees (root node up vs world up)
local function getTilt(vehicle)
    local _, upY, _ = localDirectionToWorld(vehicle.rootNode, 0, 1, 0)
    return math.deg(math.acos(math.max(-1, math.min(1, upY))))
end

-- target point exactly as AutomaticArmControlHarvester:onUpdate computes it
local function getTarget(spec, treeId)
    local wx, wy, wz = getWorldTranslation(treeId)
    wy = math.max(wy, getTerrainHeightAtWorldPos(g_terrainNode, wx, wy, wz) + spec.treeDetectionNodeCutHeight + spec.treeDetectionNodeCutHeightSafetyOffset)
    return SplitShapeUtil.getTreeOffsetPosition(treeId, wx, wy, wz, 3)
end

-- where the saw (woodHarvester cutNode) is compared to the trunk
local function measureSaw(vehicle, treeId, tx, tz)
    local spec = vehicle.spec_automaticArmControlHarvester
    local woodSpec = vehicle.spec_woodHarvester
    local sx, sy, sz = getWorldTranslation(woodSpec.cutNode)
    local px, _, pz = getWorldTranslation(spec.xAlignment.movingTool.node)

    -- direction crane pivot -> tree (seen from above)
    local rx, rz = MathUtil.vector2Normalize(tx - px, tz - pz)
    local dx, dz = sx - tx, sz - tz
    local along = dx * rx + dz * rz          -- + = saw beyond the trunk centre (further from the machine)
    local side = dx * rz - dz * rx           -- + / - = saw to one side of the trunk centre
    local flat = MathUtil.vector2Length(dx, dz)

    local bx, by, bz = getWorldTranslation(treeId)
    local terrainY = getTerrainHeightAtWorldPos(g_terrainNode, bx, by, bz)
    local aboveGround = sy - terrainY
    local stump = sy - by

    local cuttable = woodSpec.curSplitShape == treeId
    return along, side, flat, aboveGround, stump, cuttable
end

local function jointReport(vehicle)
    local spec = vehicle.spec_automaticArmControlHarvester
    local tools = {{"swing", spec.xAlignment.movingTool}, {"lift", spec.yAlignment.movingTool}, {"reach", spec.zAlignment.movingTool}}
    for i = 1, #spec.alignmentNodes do
        table.insert(tools, {"align" .. i .. "(" .. getName(spec.alignmentNodes[i].movingTool.node) .. ")", spec.alignmentNodes[i].movingTool})
    end
    local parts = {}
    for _, entry in ipairs(tools) do
        local name, tool = entry[1], entry[2]
        if tool ~= nil then
            if tool.rotSpeed ~= nil and tool.rotationAxis ~= nil then
                table.insert(parts, string.format("%s %.1f deg (xml start %.1f)", name, math.deg(tool.curRot[tool.rotationAxis]), math.deg(tool.startRot or 0)))
            elseif tool.transSpeed ~= nil and tool.translationAxis ~= nil then
                table.insert(parts, string.format("%s %.3f m (xml start %s)", name, tool.curTrans[tool.translationAxis], tool.startTrans ~= nil and string.format("%.3f", tool.startTrans) or "none"))
            end
        end
    end
    return table.concat(parts, ", ")
end


-- what the aim asked each joint to do this frame (externalMove right after doTreeArmAlignment; -1..1, 0 = nothing)
function ATFTest.moveReport(vehicle)
    local spec = vehicle.spec_automaticArmControlHarvester
    local parts = {}
    local function add(name, tool)
        if tool ~= nil then
            table.insert(parts, string.format("%s %+.2f", name, tool.externalMove or 0))
        else
            table.insert(parts, name .. " (no tool)")
        end
    end
    add("swing", spec.xAlignment.movingTool)
    add("lift", spec.yAlignment.movingTool)
    add("reach", spec.zAlignment.movingTool)
    for i = 1, #spec.alignmentNodes do
        add(getName(spec.alignmentNodes[i].movingTool.node), spec.alignmentNodes[i].movingTool)
    end
    return table.concat(parts, ", ")
end


-- tree scan (same filters as AutomaticArmControlHarvester:onTreeAutoOverlapCallback + getBestTreeToAutoAlign)
-- Callback on the vehicle itself, like the game's own onTreeAutoOverlapCallback (target = the vehicle)
function ATFTest.onTestOverlap(vehicle, objectId, ...)
    local test = vehicle.atfTest
    if test == nil then
        return
    end
    test.overlapCalls = test.overlapCalls + 1
    if objectId ~= 0 and getHasClassId(objectId, ClassIds.SHAPE) and getUserAttribute(objectId, "isTreeStump") ~= true then
        local splitType = g_splitShapeManager:getSplitTypeByIndex(getSplitType(objectId))
        if splitType ~= nil then
            if not test.found[objectId] then
                test.fromOwnScan = test.fromOwnScan + 1
            end
            test.found[objectId] = true
        end
    end
end

-- Also take the trees the game's own auto-aim scan has found (spec.foundTrees, filled every frame by its onUpdate)
function ATFTest.collectGameTrees(vehicle, test)
    local spec = vehicle.spec_automaticArmControlHarvester
    if spec.foundTrees ~= nil then
        for _, treeId in ipairs(spec.foundTrees) do
            if treeId ~= nil and not test.found[treeId] then
                test.found[treeId] = true
                test.fromGameScan = test.fromGameScan + 1
            end
        end
    end
end

function ATFTest.start(vehicle)
    local spec = vehicle.spec_automaticArmControlHarvester
    -- clear a leftover Q felling state (the test aims on its own)
    vehicle.atfFellHeld = false
    vehicle.atfFellPhase = nil
    vehicle.atfFellLastInput = nil
    local test = {phase = "scan", found = {}, trees = {}, index = 0, results = {}, startTime = g_time}
    vehicle.atfTest = test

    log("===== START on '%s' =====", tostring(vehicle.configFileName))
    log("machine tilt %.1f deg, settings: detect %.1f-%.1f m, max angle %.0f deg, cutHeight %.2f m, aim speed factor %.2f",
        getTilt(vehicle), spec.treeDetectionNodeMinRadius, spec.treeDetectionNodeMaxRadius, math.deg(spec.treeDetectionNodeMaxAngle),
        spec.treeDetectionNodeCutHeight, AssistedTreeFelling.SPEED_FACTOR)
    log("joints now: %s", jointReport(vehicle))
    local c = vehicle.atfCentre
    if c ~= nil then
        log("Ctrl+Alt+Q centre position (from the mod): swing %s, lift %s, reach %s, telescope %s, head %s",
            tostring(c.swing), tostring(c.lift), tostring(c.reach), tostring(c.telescope), tostring(c.head))
    else
        log("Ctrl+Alt+Q centre position: the start values from the vehicle XML")
    end
    log("harvester turned on: %s, motor on: %s", tostring(vehicle:getIsTurnedOn()), tostring(vehicle.getIsMotorStarted ~= nil and vehicle:getIsMotorStarted()))

    test.overlapCalls, test.fromOwnScan, test.fromGameScan = 0, 0, 0
    vehicle.atfTestOverlapCallback = ATFTest.onTestOverlap
    local x, y, z = getWorldTranslation(spec.treeDetectionNode)
    overlapSphereAsync(x, y, z, spec.treeDetectionNodeMaxRadius + 0.5, "atfTestOverlapCallback", vehicle, CollisionFlag.TREE, false, false, true, false)
end

function ATFTest.stop(vehicle, reason)
    local test = vehicle.atfTest
    if test == nil then
        return
    end
    local spec = vehicle.spec_automaticArmControlHarvester
    AssistedTreeFelling.stopAlignment(vehicle, spec)
    spec.state = AutomaticArmControlHarvester.STATE_NONE
    vehicle.atfReturnActive = false
    vehicle.atfTest = nil

    log("===== END (%s) after %.1f s =====", reason, (g_time - test.startTime) / 1000)
    notify(reason == "all trees done" and "ok" or "critical", "FINISHED (%s). You can move the machine.", reason)
    for _, r in ipairs(test.results) do
        log("SUMMARY %s", r)
    end
end

function ATFTest.pickTrees(vehicle, test)
    local spec = vehicle.spec_automaticArmControlHarvester
    for treeId, _ in pairs(test.found) do
        if entityExists(treeId) and getRigidBodyType(treeId) == RigidBodyType.STATIC and getHasClassId(treeId, ClassIds.MESH_SPLIT_SHAPE)
            and not getIsSplitShapeSplit(treeId) and g_splitShapeManager:getSplitShapeAllowsHarvester(treeId) then
            local x1, _, z1 = getWorldTranslation(spec.treeDetectionNode)
            local x2, _, z2 = getWorldTranslation(treeId)
            local distance = MathUtil.vector2Length(x1 - x2, z1 - z2)
            local lx, _, lz = localToLocal(treeId, spec.treeDetectionNode, 0, 0, 0)
            lx, lz = MathUtil.vector2Normalize(lx, lz)
            local angle = MathUtil.getYRotationFromDirection(lx, lz)
            if distance > spec.treeDetectionNodeMinRadius and distance < spec.treeDetectionNodeMaxRadius and math.abs(angle) < spec.treeDetectionNodeMaxAngle then
                table.insert(test.trees, {id = treeId, distance = distance, angle = math.deg(angle)})
            end
        end
    end
    table.sort(test.trees, function(a, b) return a.angle < b.angle end)

    -- spread the picks over the angle range if there are more than MAX_TREES
    if #test.trees > ATFTest.MAX_TREES then
        local picked = {}
        for i = 1, ATFTest.MAX_TREES do
            local k = math.floor((i - 1) * (#test.trees - 1) / (ATFTest.MAX_TREES - 1) + 0.5) + 1
            table.insert(picked, test.trees[k])
        end
        test.trees = picked
    end

    notify("info", "started, %d tree(s) in reach. Hands off the controls.", #test.trees)
    log("scan: own overlap callbacks %d, trees from own scan %d, from the game's auto-aim scan %d, total %d; reachable and testing %d:",
        test.overlapCalls, test.fromOwnScan, test.fromGameScan, ATFTest.countFound(test), #test.trees)
    for i, t in ipairs(test.trees) do
        local _, _, _, _, _, _, radius = getTarget(spec, t.id)
        log("  tree %d: id %d, %.2f m from detection node, angle %+.0f deg, diameter %s", i, t.id, t.distance, t.angle,
            radius ~= nil and string.format("%.0f cm", radius * 200) or "?")
        t.radius = radius
    end
end

function ATFTest.countFound(test)
    local n = 0
    for _ in pairs(test.found) do n = n + 1 end
    return n
end

function ATFTest.nextTree(vehicle, test)
    test.index = test.index + 1
    local tree = test.trees[test.index]
    if tree == nil then
        ATFTest.stop(vehicle, "all trees done")
        return
    end
    if not entityExists(tree.id) then
        table.insert(test.results, string.format("tree %d: GONE", test.index))
        ATFTest.nextTree(vehicle, test)
        return
    end

    local spec = vehicle.spec_automaticArmControlHarvester
    spec.state = AutomaticArmControlHarvester.STATE_NONE
    spec.atfStuckX = nil
    -- wait for the machine to stop rocking before aiming (test run 1.1.0.3 started a tree at 9.4 deg tilt)
    test.phase = "settle"
    test.phaseStart = g_time
    test.settleTilt = getTilt(vehicle)
    test.settleTime = g_time
    test.nextSample = 0
    test.maxTilt = getTilt(vehicle)
    test.lastStateName = nil
    test.finished = false
    log("--- tree %d/%d (id %d, angle %+.0f deg, %.2f m) aim start", test.index, #test.trees, tree.id, tree.angle, tree.distance)
end

function ATFTest.update(vehicle, dt)
    local test = vehicle.atfTest
    local spec = vehicle.spec_automaticArmControlHarvester

    local tilt = getTilt(vehicle)
    if tilt > ATFTest.TILT_ABORT then
        log("ABORT: machine tilted %.1f deg", tilt)
        notify("critical", "STOPPED, machine tilted %.0f degrees", tilt)
        table.insert(test.results, string.format("tree %d: ABORTED, machine tilted %.1f deg", test.index, tilt))
        ATFTest.stop(vehicle, "tilt")
        return
    end

    -- a tree held in the head (e.g. the player cut one): the game's own aim refuses then (WoodHarvester
    -- getIsAutoTreeAlignmentAllowed); the test calls the aim directly, so check it here (test run 1.1.0.3 tipped like this)
    if (test.phase == "settle" or test.phase == "aim") and vehicle.spec_woodHarvester ~= nil and vehicle.spec_woodHarvester.hasAttachedSplitShape then
        local woodSpec = vehicle.spec_woodHarvester
        local sx, sy, sz = getWorldTranslation(woodSpec.cutNode)
        local sawHeight = sy - getTerrainHeightAtWorldPos(g_terrainNode, sx, sy, sz)
        log("STOP: the head is holding a tree. Saw is %.2f m above the ground (lift height setting %.2f m)", sawHeight, AssistedTreeFelling.LIFT_HEIGHT)
        notify("critical", "head is holding a tree. Saw is %.2f m above the ground. (Test not run.)", sawHeight)
        table.insert(test.results, string.format("tree %d: STOPPED, head holding a tree", test.index))
        ATFTest.stop(vehicle, "head holding a tree")
        return
    end

    if test.phase == "scan" then
        ATFTest.collectGameTrees(vehicle, test)
        if g_time - test.startTime > ATFTest.SCAN_TIME then
            ATFTest.pickTrees(vehicle, test)
            if #test.trees == 0 then
                ATFTest.stop(vehicle, "no reachable trees here")
                return
            end
            ATFTest.nextTree(vehicle, test)
        end

    elseif test.phase == "settle" then
        if math.abs(tilt - test.settleTilt) > 0.2 then
            test.settleTilt = tilt
            test.settleTime = g_time
        end
        if g_time - test.settleTime > 800 or g_time - test.phaseStart > 8000 then
            log("  machine settled at %.1f deg tilt after %.1f s, aiming", tilt, (g_time - test.phaseStart) / 1000)
            test.phase = "aim"
            test.phaseStart = g_time
            test.nextSample = 0
            test.maxTilt = tilt
        end

    elseif test.phase == "aim" then
        local tree = test.trees[test.index]
        if not entityExists(tree.id) then
            table.insert(test.results, string.format("tree %d: GONE during aim", test.index))
            ATFTest.nextTree(vehicle, test)
            return
        end
        test.maxTilt = math.max(test.maxTilt, tilt)

        local tx, ty, tz, _, _, _, radius = getTarget(spec, tree.id)
        if tx == nil then
            table.insert(test.results, string.format("tree %d: no target point (getTreeOffsetPosition nil)", test.index))
            ATFTest.nextTree(vehicle, test)
            return
        end

        local elapsed = g_time - test.phaseStart
        if not test.finished and elapsed <= ATFTest.AIM_TIMEOUT then
            -- exactly what holding Q does on the server, aimed at this tree
            spec.lastRadius = radius
            spec.lastTargetTrans[1], spec.lastTargetTrans[2], spec.lastTargetTrans[3] = tx, ty, tz
            vehicle:doTreeArmAlignment(tx, ty, tz, 1)
            test.lastMoves = ATFTest.moveReport(vehicle)
            -- read the state in the same frame (the game's onUpdate may reset it to NONE at the start of the next one)
            test.finished = spec.state == AutomaticArmControlHarvester.STATE_FINISHED
        end
        local finished = test.finished

        local along, side, flat, aboveGround, stump, cuttable = measureSaw(vehicle, tree.id, tx, tz)
        local sName = stateName(spec.state)
        if g_time >= test.nextSample or sName ~= test.lastStateName then
            test.nextSample = g_time + ATFTest.SAMPLE_TIME
            test.lastStateName = sName
            log("  t=%5.2fs %-9s saw: along %+.2f m, side %+.2f m (flat %.2f), %.2f m above ground, cuttable %s, tilt %.1f",
                elapsed / 1000, sName, along, side, flat, aboveGround, tostring(cuttable), tilt)
            log("           commands: %s", test.lastMoves or "none")
            log("           joints:   %s", jointReport(vehicle))
        end

        if finished or elapsed > ATFTest.AIM_TIMEOUT then
            local outcome
            if not finished then
                AssistedTreeFelling.stopAlignment(vehicle, spec)
                outcome = "TIMEOUT"
            elseif cuttable then
                outcome = "GREEN (cuttable)"
            else
                outcome = "STOPPED not cuttable"
            end
            local result = string.format("tree %d (angle %+.0f deg, %.2f m, diam %.0f cm): %s in %.1f s | saw along %+.2f side %+.2f flat %.2f m | %.2f m above ground, stump %.2f m | max tilt %.1f deg",
                test.index, tree.angle, tree.distance, (radius or 0) * 200, outcome, elapsed / 1000, along, side, flat, aboveGround, stump, test.maxTilt)
            log("RESULT %s", result)
            notify(cuttable and "ok" or "critical", "tree %d/%d: %s, saw %.2f m above ground. Centring crane...",
                test.index, #test.trees, cuttable and "GREEN" or outcome, aboveGround)
            table.insert(test.results, result)

            AssistedTreeFelling.startReturn(vehicle)
            test.phase = "centre"
            test.phaseStart = g_time
        end

    elseif test.phase == "centre" then
        local elapsed = g_time - test.phaseStart
        if not vehicle.atfReturnActive or elapsed > ATFTest.CENTRE_TIMEOUT then
            local result = string.format("tree %d centre: %s in %.1f s | %s", test.index,
                vehicle.atfReturnActive and "TIMEOUT" or "done", elapsed / 1000, jointReport(vehicle))
            vehicle.atfReturnActive = false
            log("CENTRE %s", result)
            table.insert(test.results, result)
            ATFTest.nextTree(vehicle, test)
        end
    end
end


-- hooks (chained on top of AssistedTreeFelling's)
local originalOnUpdate = AutomaticArmControlHarvester.onUpdate
AutomaticArmControlHarvester.onUpdate = function(self, dt, ...)
    originalOnUpdate(self, dt, ...)
    if self.isServer and self.atfTest ~= nil then
        local ok, err = pcall(ATFTest.update, self, dt)
        if not ok then
            log("ERROR in test: %s", tostring(err))
            self.atfTest = nil
            self.atfReturnActive = false
        end
    end
end

local originalOnRegisterActionEvents = AutomaticArmControlHarvester.onRegisterActionEvents
AutomaticArmControlHarvester.onRegisterActionEvents = function(self, isActiveForInput, isActiveForInputIgnoreSelection)
    originalOnRegisterActionEvents(self, isActiveForInput, isActiveForInputIgnoreSelection)
    if self.isClient and self.assistedTreeFellingActive and isActiveForInputIgnoreSelection then
        local spec = self.spec_automaticArmControlHarvester
        self:addActionEvent(spec.actionEvents, InputAction.ATF_TEST, self, ATFTest.actionEvent, false, true, false, true, nil)
    end
end

function ATFTest.actionEvent(self, actionName, inputValue, callbackState, isAnalog)
    if not self.isServer then
        Logging.warning("[ATF-TEST] test only runs in single player / on the host")
        return
    end
    if self.atfTest ~= nil then
        ATFTest.stop(self, "stopped by key")
    else
        ATFTest.start(self)
    end
end
