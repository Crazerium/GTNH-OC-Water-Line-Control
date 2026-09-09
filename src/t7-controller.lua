local sides = require("sides")
local event = require("event")

local stateMachineLib = require("lib.state-machine-lib")
local componentDiscoverLib = require("lib.component-discover-lib")
local gtSensorParserLib = require("lib.gt-sensor-parser")

---@class T7ControllerConfig
---@field inertGasTransposerAddress string
---@field superConductorTransposerAddress string
---@field netroniumTransposerAddress string
---@field coolantTransposerAddress string

local t7controller = {}

---Crate new T7Controller object from config
---@param config T7ControllerConfig
---@return T7Controller
function t7controller:newFormConfig(config)
  return self:new(
    config.inertGasTransposerAddress,
    config.superConductorTransposerAddress,
    config.netroniumTransposerAddress,
    config.coolantTransposerAddress)
end

---Crate new T7Controller object
---@param inertGasTransposerAddress string
---@param superConductorTransposerAddress string
---@param netroniumTransposerAddress string
---@param coolantTransposerAddress string
---@return T7Controller
function t7controller:new(
  inertGasTransposerAddress,
  superConductorTransposerAddress,
  netroniumTransposerAddress,
  coolantTransposerAddress)

  ---@class T7Controller
  local obj = {}

  obj.inertGasTransposerProxy = nil
  obj.superConductorTransposerProxy = nil
  obj.netroniumTransposerProxy = nil
  obj.coolantTransposerProxy = nil
  obj.controllerProxy = nil

  ---@type TransposerFluidStorageDescriptor[]
  obj.transposerLiquids = {}

  obj.stateMachine = stateMachineLib:new()
  obj.gtSensorParser = nil
  obj.currentSuccessChance = nil

  obj.superconductorCount = 1440
  obj.neutroniumCount = 4608
  obj.supercoolantCount = 10000

  -- GTNH 2.9 Degasser accepts Superconductor Base UV and higher only.
  -- These are material/registry-name fragments, not localized display names.
  -- Matching is case-insensitive in component-discover-lib.lua.
  obj.superconductorFluidNames = {
    "longasssuperconductornameforuvwire",  -- Superconductor Base UV
    "longasssuperconductornameforuhvwire", -- Superconductor Base UHV
    "superconductoruevbase",               -- Superconductor Base UEV
    "superconductoruivbase",               -- Superconductor Base UIV
    "superconductorumvbase"                -- Superconductor Base UMV
  }

  ---Init T7Controller
  function obj:init()
    self:findMachineProxy()

    self:findTransposerFluid(self.inertGasTransposerProxy, {"helium", "neon", "krypton", "xenon"})
    self:findTransposerAnyFluid(
      self.superConductorTransposerProxy,
      "superconductor",
      self.superconductorFluidNames,
      "GTNH 2.9 T7 requires Molten Superconductor Base UV/UHV/UEV/UIV/UMV")
    self:findTransposerFluid(self.netroniumTransposerProxy, {"neutronium"})
    self:findTransposerFluid(self.coolantTransposerProxy, {"supercoolant"})

    self.gtSensorParser:getInformation()

    self.stateMachine.states.idle = self.stateMachine:createState("Idle")
    self.stateMachine.states.idle.update = function()
      if self.controllerProxy.hasWork() then
        -- GTNH 2.9 no longer exposes "Success chance:" in the old sensor slot.
        -- If the Degasser already consumed something this cycle (for example after
        -- restarting the OC program mid-cycle), do not inject the requested fluids again.
        if self:hasInsertedFluids() then
          self.currentSuccessChance = nil
          self.stateMachine:setState(self.stateMachine.states.waitEnd)
        else
          self.currentSuccessChance = nil
          self.stateMachine:setState(self.stateMachine.states.work)
        end
      end
    end

    self.stateMachine.states.work = self.stateMachine:createState("Work")
    self.stateMachine.states.work.init = function()
      local bitString = self:getControlSignal()

      -- Never interpret a parser failure as 0000. In GTNH 2.9 that would cause us
      -- to inject 10 kL Super Coolant into an unrelated signal and guarantee failure.
      if bitString == nil then
        self.currentSuccessChance = nil
        event.push("log_warning", "[T7] Can't read Degasser control signal; no fluids were inserted")
        self.stateMachine:setState(self.stateMachine.states.waitEnd)
        return
      end

      local bits = self:bitParser(bitString)
      self.currentSuccessChance = 100

      if bits[1] == false and bits[2] == false and bits[3] == false and bits[4] == false then
        if self:putCoolant() == false then
          self.currentSuccessChance = 0
        end
        self.stateMachine:setState(self.stateMachine.states.waitEnd)
        return
      end

      if bits[4] == true then
        self.stateMachine:setState(self.stateMachine.states.waitEnd)
        return
      end

      if bits[1] == true and self:putInertGas(bits) == false then
        self.currentSuccessChance = 0
      end

      if bits[2] == true and self:putSuperConductor() == false then
        self.currentSuccessChance = 0
      end

      if bits[3] == true and self:putNeutronium() == false then
        self.currentSuccessChance = 0
      end

      self.stateMachine:setState(self.stateMachine.states.waitEnd)
    end

    self.stateMachine.states.waitEnd = self.stateMachine:createState("Wait End")

    event.listen("cycle_end", function ()
      if self.stateMachine.currentState == self.stateMachine.states.waitEnd then
        self.stateMachine:setState(self.stateMachine.states.idle)
      end
    end)

    self.stateMachine:setState(self.stateMachine.states.idle)
  end

  ---Find controller proxy
  function obj:findMachineProxy()
    self.controllerProxy = componentDiscoverLib.discoverGtMachine("multimachine.purificationunitdegasifier")

    if self.controllerProxy == nil then
      error("[T7] Residual Decontaminant Degasser Purification Unit not found")
    end

    self.inertGasTransposerProxy = componentDiscoverLib.discoverProxy(
      inertGasTransposerAddress,
      "[T7] Inert Gas Transposer",
      "transposer")
    self.superConductorTransposerProxy = componentDiscoverLib.discoverProxy(
      superConductorTransposerAddress,
      "[T7] Super Conductor Transposer",
      "transposer")
    self.netroniumTransposerProxy = componentDiscoverLib.discoverProxy(
      netroniumTransposerAddress,
      "[T7] Netronium Transposer",
      "transposer")
    self.coolantTransposerProxy = componentDiscoverLib.discoverProxy(
      coolantTransposerAddress,
      "[T7] Coolant Transposer",
      "transposer")
    self.gtSensorParser = gtSensorParserLib:new(self.controllerProxy)
  end

  ---Get a short list of non-empty fluids visible from a transposer.
  ---@param proxy any
  ---@return string
  function obj:getVisibleFluids(proxy)
    local visible = {}

    for side = 0, 5, 1 do
      if side ~= sides.up then
        local tankCount = proxy.getTankCount(side) or 0

        for tankIndex = 1, tankCount, 1 do
          local fluid = proxy.getFluidInTank(side, tankIndex)

          if fluid ~= nil and fluid.name ~= nil and (fluid.amount or 0) > 0 then
            table.insert(
              visible,
              fluid.name.." ("..tostring(fluid.amount).." mB, side "..tostring(side)..")")
          end
        end
      end
    end

    if #visible == 0 then
      return "none; storage is empty or not connected to this transposer"
    end

    return table.concat(visible, "; ")
  end

  ---Find side of transposer with every requested fluid.
  ---@param proxy any
  ---@param fluidNames string[]
  function obj:findTransposerFluid(proxy, fluidNames)
    local result, skipped = componentDiscoverLib.discoverTransposerFluidStorage(proxy, fluidNames, {sides.up})

    if #skipped ~= 0 then
      error(
        "[T7] Can't find liquid: "..table.concat(skipped, ", ")
        ..". Visible fluids: "..self:getVisibleFluids(proxy))
    end

    for key, value in pairs(result) do
      self.transposerLiquids[key] = value
    end
  end

  ---Find any one fluid matching a list of accepted registry-name fragments.
  ---@param proxy any
  ---@param storageKey string
  ---@param fluidNames string[]
  ---@param hint? string
  function obj:findTransposerAnyFluid(proxy, storageKey, fluidNames, hint)
    for _, fluidName in ipairs(fluidNames) do
      local result, skipped = componentDiscoverLib.discoverTransposerFluidStorage(
        proxy,
        {fluidName},
        {sides.up})

      if #skipped == 0 and result[fluidName] ~= nil then
        self.transposerLiquids[storageKey] = result[fluidName]

        return
      end
    end

    local message = "[T7] Can't find a valid superconductor base. Visible fluids: "..self:getVisibleFluids(proxy)
    if hint ~= nil then
      message = message..". "..hint
    end
    error(message)
  end

  ---Remove Minecraft formatting codes from a sensor line.
  ---@param value string
  ---@return string
  function obj:stripFormatting(value)
    return string.gsub(value or "", "§.", "")
  end

  ---Find a sensor-information line by a literal marker.
  ---GTNH 2.9 returns encoded localization keys such as
  ---GT5U.infodata.purification_unit_degasser.control_signal instead of the old English labels.
  ---@param marker string
  ---@return string|nil
  function obj:findSensorLine(marker)
    for _, line in ipairs(self.gtSensorParser.sensorData or {}) do
      if string.find(line, marker, 1, true) ~= nil then
        return line
      end
    end

    return nil
  end

  ---Read the current 4-bit Degasser control signal.
  ---Supports both GTNH 2.9 encoded sensor data and the old 2.8 English sensor line.
  ---@return string|nil
  function obj:getControlSignal()
    local marker = "GT5U.infodata.purification_unit_degasser.control_signal"
    local line = self:findSensorLine(marker)

    if line ~= nil then
      local data = self:stripFormatting(line)
      local markerStart, markerEnd = string.find(data, marker, 1, true)

      if markerStart ~= nil then
        local tail = string.sub(data, markerEnd + 1)
        -- IGregTechDeviceInformation.encode separates arguments with backslashes.
        -- We only care about the first numeric argument after the localization key.
        local signal = string.match(tail, "(%d+)")
        if signal ~= nil then
          return signal
        end
      end
    end

    -- Backwards-compatible fallback for GTNH 2.8.
    for _, oldLine in ipairs(self.gtSensorParser.sensorData or {}) do
      local clean = self:stripFormatting(oldLine)
      local signal = string.match(clean, "Current control signal %(binary%):%s*0b([01]+)")
      if signal ~= nil then
        return signal
      end
    end

    return nil
  end

  ---Check whether the Degasser already reports a consumed/inserted fluid this cycle.
  ---This protects against duplicating inputs after restarting the OC program mid-cycle.
  ---@return boolean
  function obj:hasInsertedFluids()
    local marker = "GT5U.infodata.purification_unit_degasser.fluid_inserted"

    if self:findSensorLine(marker) ~= nil then
      return true
    end

    -- Old sensor text fallback.
    for _, line in ipairs(self.gtSensorParser.sensorData or {}) do
      local clean = self:stripFormatting(line)
      if string.find(string.lower(clean), "fluid inserted", 1, true) ~= nil then
        return true
      end
    end

    return false
  end

  ---Parse bit string to bits array
  ---@param bitString string|number
  ---@return boolean[]
  function obj:bitParser(bitString)

    bitString = string.rep("0", 4 - #bitString)..bitString

    local bits = {
      tonumber(bitString:sub(4, 4)) == 1,
      tonumber(bitString:sub(3, 3)) == 1,
      tonumber(bitString:sub(2, 2)) == 1,
      tonumber(bitString:sub(1, 1)) == 1,
    }

    return bits
  end

  ---Put inert gas in input hatch
  ---@param bits boolean[]
  function obj:putInertGas(bits)
    local inertGas = ""
    local count = 0

    if bits[2] == false and bits[3] == false then
      inertGas = "helium"
      count = 10000
    elseif bits[2] == true and bits[3] == false then
      inertGas = "neon"
      count = 7500
    elseif bits[2] == false and bits[3] == true then
      inertGas = "krypton"
      count = 5000
    elseif bits[2] == true and bits[3] == true then
      inertGas = "xenon"
      count = 2500
    end

    local _, result = self.inertGasTransposerProxy.transferFluid(
      self.transposerLiquids[inertGas].side,
      sides.up,
      count,
      self.transposerLiquids[inertGas].tank)

    if result ~= count then
      self.controllerProxy.setWorkAllowed(false)
      event.push("log_warning", "[T7] Not enough "..inertGas.." for craft")
      return false
    end

    return true
  end

  ---Put super conductor in input hatch
  function obj:putSuperConductor()
    local _, result = self.superConductorTransposerProxy.transferFluid(
      self.transposerLiquids["superconductor"].side,
      sides.up,
      self.superconductorCount,
      self.transposerLiquids["superconductor"].tank)

    if result ~= self.superconductorCount then
      self.controllerProxy.setWorkAllowed(false)
      event.push("log_warning", "[T7] Not enough superconductor for craft")
      return false
    end

    return true
  end

  ---Put super conductor in input hatch
  function obj:putNeutronium()
    local _, result = self.netroniumTransposerProxy.transferFluid(
      self.transposerLiquids["neutronium"].side,
      sides.up,
      self.neutroniumCount,
      self.transposerLiquids["neutronium"].tank)

    if result ~= self.neutroniumCount then
      self.controllerProxy.setWorkAllowed(false)
      event.push("log_warning", "[T7] Not enough neutronium for craft")
      return false
    end

    return true
  end

  ---Put coolant in input hatch
  function obj:putCoolant()
    local _, result = self.coolantTransposerProxy.transferFluid(
      self.transposerLiquids["supercoolant"].side,
      sides.up,
      self.supercoolantCount,
      self.transposerLiquids["supercoolant"].tank)

    if result ~= self.supercoolantCount then
      self.controllerProxy.setWorkAllowed(false)
      event.push("log_warning", "[T7] Not enough coolant for craft")
      return false
    end

    return true
  end

  ---Loop
  function obj:loop()
    self.gtSensorParser:getInformation()
    self.stateMachine:update()
  end

  ---Get current state
  ---@return string
  function obj:getState()
    if self.controllerProxy.isWorkAllowed() == false then
      return "Controller disabled"
    end

    if self.controllerProxy.hasWork() == false then
      return "Wait cycle"
    end

    local state = self.stateMachine.currentState and self.stateMachine.currentState.name or "nil"
    local successChance = self.currentSuccessChance

    if successChance == nil then
      return "State: ["..state.."] Success: [?%]"
    end

    return "State: ["..state.."] Success: ["..successChance.."%]"
  end

  setmetatable(obj, self)
  self.__index = self
  return obj
end

return t7controller