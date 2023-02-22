function gadget:GetInfo()
    return {
        name = "Zero-Wars Mod",
        desc = "zero-k autobattler",
        author = "petturtle",
        date = "2021",
        layer = 0,
        enabled = true
    }
end

if not gadgetHandler:IsSyncedCode() then
    return false
end

VFS.Include("LuaRules/Configs/customcmds.h.lua")
local Util = VFS.Include("luarules/gadgets/util/util.lua")
local config = VFS.Include("luarules/configs/zwconfig.lua")

local SPAWNFRAME = 1000
local DEPLOYSPEED = 5
local PLATFORMHEIGHT = 128
local MAPCENTER = Game.mapSizeX / 2

local bomberDefIDs = {
    [UnitDefNames["bomberassault"].id] = true,
    [UnitDefNames["bomberdisarm"].id] = true,
    [UnitDefNames["bomberheavy"].id] = true,
    [UnitDefNames["bomberprec"].id] = true,
    [UnitDefNames["bomberriot"].id] = true,
    [UnitDefNames["bomberstrike"].id] = true,
}

local sides = {}

local function InitSide(side, allyTeamID, enemyAllyTeamID)
    sides[allyTeamID] = side
    side.allyTeamID = allyTeamID
    local teams = Spring.GetTeamList(allyTeamID)

    -- set passive income
    GG.Overdrive.AddInnateIncome(allyTeamID, -2, 1000)

    -- create nexus
    local nPos = side.nexus
    local nID = Spring.CreateUnit("nexus", nPos.x, 128, nPos.z, side.faceDir, teams[1])
    GG.EventOnUnitDeath(nID, function ()
        Spring.GameOver({enemyAllyTeamID})
    end)

    -- create center turret
    local tPos = side.nexusTurret
    local tID = Spring.CreateUnit("nexusturret", tPos.x, 128, tPos.z, side.faceDir, teams[1])
    GG.EventOnUnitDeath(tID, function ()
        local teamList = Spring.GetTeamList(enemyAllyTeamID)
        for i = 1, #teamList do
            Spring.AddTeamResource(teamList[i], "metal", 800)
        end
    end)

    -- create extra buildings
    for _, building in pairs(side.extraBuildings) do
        local unitID = Spring.CreateUnit(building.unitName, building.x, 128, building.z, side.faceDir, teams[1])
        Spring.SetUnitNoSelect(unitID, true)
        Spring.SetUnitNeutral(unitID, true)
    end
end

local function GetPlatformID(side, x, z)
    for i = 1, #side.platforms do
        local plat = side.platforms[i]
        if Util.HasRectPoint(plat.x, plat.z, plat.width, plat.height, x, z) then
            return i
        end
    end

    return -1
end

local function AddUpgradeableMex(teamID, platID, side)
    local plat = side.platforms[platID]
    for i = 1, #side.mex do
        local mex = side.mex[i]
        Spring.CreateUnit("upgradeablemex", plat.x + mex.x, 128, plat.z + mex.z, 0, teamID)
    end
end

local function DeployPlayer(builderID, side)
    local teamID = Spring.GetUnitTeam(builderID)
    local x, _, z = Spring.GetUnitPosition(builderID)
    local platID = GetPlatformID(side, x, z)

    if platID == -1 then
        Spring.DestroyUnit(builderID)
        return
    end

    local plat = side.platforms[platID]
    if plat.teamID == nil then
        plat.teamID = teamID
        plat.builderID = builderID
        AddUpgradeableMex(teamID, platID, side)
        Spring.SetUnitRulesParam(builderID, "facplop", 1, {inlos = true})

        -- spawn hero drone
        local dRect = side.deployRect
        local heroX = dRect.x + (dRect.width * math.random(10, 90) / 100)
        local heroZ = dRect.z + (dRect.height * math.random(10, 90) / 100)
        Spring.CreateUnit("chicken_drone_starter", heroX, 128, heroZ, side.faceDir, plat.teamID)
    else
        -- if platform already has builder merge them together
        if plat.teamID ~= teamID then
            Util.MergeTeams(teamID, plat.teamID)
        end

        Spring.DestroyUnit(builderID, false, true)
    end

end

function gadget:GamePreload()
    local allyStarts = Util.GetAllyStarts()
    allyStarts.Left = tonumber(allyStarts.Left or 0)
    allyStarts.Right = tonumber(allyStarts.Right or 0)
    InitSide(config.Left, allyStarts.Left, allyStarts.Right)
    InitSide(config.Right, allyStarts.Right, allyStarts.Left)

    local dRect = config.Left.deployRect
    local width = 125
    GG.ControlPoints.CreateRect(MAPCENTER + 5 - (width * 0.5), dRect.z, width, dRect.height, 4)
end

function gadget:GameStart()
    -- replace commanders with builders and assign them to platforms
    local builders = Util.ReplaceStartUnit("builder")
    for _, builderID in pairs(builders) do
        local allyTeamID = Spring.GetUnitAllyTeam(builderID)
        DeployPlayer(builderID, sides[allyTeamID])
    end

    -- create deploy zones for each platform
    for _, side in pairs(sides) do
        local remainingPlatforms = {}

        for _, plat in pairs(side.platforms) do
            if plat.teamID ~= nil then
                Util.SetBuildMask(plat.x, plat.z, plat.width, plat.height, 2)
                remainingPlatforms[#remainingPlatforms+1] = plat
                plat.DeployZoneID = GG.DeployZones.Create(plat.x, plat.z, side.deployRect.x, side.deployRect.z, plat.width, plat.height, plat.teamID, side.faceDir, DEPLOYSPEED)
                GG.DeployZones.Blacklist(plat.DeployZoneID, plat.builderID)
            end
        end

        side.platforms = remainingPlatforms
        side.platIterator = -1
    end

    local dGunCMD = 105
    local jumpCMD = 38521
    GG.UnitCMDBlocker.AllowCommand(1, 1)
    GG.UnitCMDBlocker.AllowCommand(1, dGunCMD) -- allow dgun cmds
    GG.UnitCMDBlocker.AllowCommand(1, jumpCMD) -- allow jump

    local filter = function(unitID, unitDefID, cmdID, cmdParams, cmdOptions, cmdTag, synced)
        -- allow bombers to rearm
        if cmdID == 1 then
            return bomberDefIDs[unitDefID] == true and synced == -1
        elseif cmdID == dGunCMD or cmdID == jumpCMD then -- remove jump / dgun cmd after use
            return Util.RemoveUnitCmdDesc(unitID, cmdID)
        end

        return true
    end

    GG.UnitCMDBlocker.AppendFilter(1, filter)
end

function gadget:GameFrame(frame)
    -- spawn next wave
    if frame > 0 and frame % SPAWNFRAME == 0 then
        for _, side in pairs(sides) do
            if #side.platforms > 0 then
                side.platIterator = (side.platIterator + 1) % #side.platforms
                local plat = side.platforms[side.platIterator + 1]
                local units = GG.DeployZones.Deploy(plat.DeployZoneID)

                for i = 1, #units do
                    local unitID = units[i]
                    local x, _, z = Spring.GetUnitPosition(unitID)
                    Spring.GiveOrderToUnit(
                        unitID,
                        CMD.INSERT,
                        {-1, CMD.FIGHT, CMD.OPT_SHIFT, MAPCENTER, PLATFORMHEIGHT, z},
                        {"alt"}
                    )
                    Spring.GiveOrderToUnit(
                        unitID,
                        CMD.INSERT,
                        {-1, CMD.FIGHT, CMD.OPT_SHIFT, side.attackPosX, PLATFORMHEIGHT, z},
                        {"alt"}
                    )

                    local cmdDescTable = Spring.GetUnitCmdDescs(unitID)
                    if cmdDescTable then
                        for i = 1, #cmdDescTable do
                            Spring.RemoveUnitCmdDesc(unitID, cmdDescTable[i])
                        end
                    end

                    local onIdle = function()
                        local x,_, z = Spring.GetUnitPosition(unitID)
                        if math.abs(x - side.attackPosX) > 200 then
                            GG.UnitCMDBlocker.Unlock()
                            Spring.GiveOrderToUnit(unitID, CMD.FIGHT, {side.attackPosX, PLATFORMHEIGHT, z}, {"alt"})
                            GG.UnitCMDBlocker.Lock()
                        end
                    end
                    GG.EventOnUnitIdle(unitID, onIdle)
                    GG.UnitCMDBlocker.AppendUnit(unitID, 1)
                end
            end
        end
    end
end

-- disable unit movement built on deploy zones
function gadget:UnitCreated(unitID, unitDefID, unitTeam, builderID)
    if builderID then
        local ud = UnitDefs[unitDefID]
        if not (ud.isBuilding or ud.isBuilder) then
            Spring.SetUnitNeutral(unitID, true)
            GG.BlockUnitMovement.Block(unitID)
            local cmdDescTable = Spring.GetUnitCmdDescs(unitID)
            if cmdDescTable then
                for i = 1, #cmdDescTable do
                    Spring.RemoveUnitCmdDesc(unitID, cmdDescTable[i])
                end
            end
            GG.SpeedGroups.InsertCmd(unitID)
        end
    end
end

function gadget:UnitTaken(unitID, unitDefID, oldTeam, newTeam)
    if not Spring.AreTeamsAllied(oldTeam, newTeam) then
        local x, _, z = Spring.GetUnitPosition(unitID)
        local allyTeam = select(6, Spring.GetTeamInfo(newTeam))
        local side = sides[allyTeam]
        local onIdle = function()
            local x,_, z = Spring.GetUnitPosition(unitID)
            if math.abs(x - side.attackPosX) > 200 then
                GG.UnitCMDBlocker.Unlock()
                Spring.GiveOrderToUnit(unitID, CMD.FIGHT, {side.attackPosX, PLATFORMHEIGHT, z}, {"alt"})
                GG.UnitCMDBlocker.Lock()
            end
        end

        GG.EventOnUnitIdle(unitID, onIdle)

        GG.UnitCMDBlocker.Unlock()
        Spring.GiveOrderToUnit(unitID, CMD.FIGHT, {side.attackPosX, PLATFORMHEIGHT, z}, {"alt"})
        GG.UnitCMDBlocker.Lock()
    end
    return true
end

-- block wreck creation
function gadget:AllowFeatureCreation(featureDefID, teamID, x, y, z)
    return false
end

function gadget:Initialize()
    GG.GetClosestMetalSpot = nil
end

function gadget:GameOver()
    gadgetHandler:RemoveGadget(self)
end
