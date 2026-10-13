local store = require("overseer.experiment_store")
local M = {}
local states = {}
local listeners = {}
M.stages = { "resources", "configure", "build", "run" }

local function key(project, file)
  return project .. "\n" .. file
end

function M.get(project, file)
  local id = key(project, file)
  if not states[id] then
    states[id] = store.session(project, file).progress or { allocations = {} }
  end
  return states[id]
end

local function publish(project, file)
  store.update_session(project, file, { progress = M.get(project, file) })
  for _, callback in pairs(listeners) do
    callback(project, file)
  end
end

function M.subscribe(id, callback)
  listeners[id] = callback
end

function M.unsubscribe(id)
  listeners[id] = nil
end

function M.begin(project, file, mode, config)
  if mode ~= "configure" and mode ~= "build" and mode ~= "run" and mode ~= "submit" then
    return
  end
  local progress = M.get(project, file)
  local selected = {}
  for _, server in ipairs(config.servers.selected or {}) do
    selected[server] = true
  end
  for id, allocation in pairs(progress.allocations) do
    if not selected[allocation.server] then
      progress.allocations[id] = nil
    else
      allocation.stages.resources = "PENDING"
      allocation.status, allocation.job_id = nil, nil
      allocation.allocation_session = nil
      if mode == "configure" or mode == "build" or config.build.before_run then
        allocation.stages.configure = "PENDING"
        allocation.stages.build = mode == "configure" and "NONE" or "PENDING"
        allocation.stages.run = "NONE"
      end
      if mode == "run" or mode == "submit" then
        allocation.stages.run = "PENDING"
      end
    end
  end
  progress.mode, progress.status = mode, "PENDING"
  publish(project, file)
end

function M.event(project, file, event)
  local progress = M.get(project, file)
  if event.event == "session" and event.allocations then
    local current = {}
    for _, entry in ipairs(event.allocations) do
      local allocation = progress.allocations[entry.id] or { server = entry.server, stages = {} }
      for _, stage in ipairs(entry.stages) do
        allocation.stages[stage] = allocation.stages[stage] or "PENDING"
      end
      current[entry.id] = allocation
    end
    progress.allocations = current
  elseif event.event == "stage" then
    local id = event.allocation or event.server
    local allocation = progress.allocations[id] or { server = event.server, stages = {} }
    progress.allocations[id] = allocation
    allocation.stages[event.stage] = event.status
    allocation.job_id = type(event.job_id) == "string" and event.job_id or allocation.job_id
    allocation.allocation_session = type(event.allocation_session) == "string"
        and event.allocation_session
      or allocation.allocation_session
  elseif event.event == "remote_job" then
    local id = event.allocation
    local allocation = progress.allocations[id] or { server = event.server, stages = {} }
    progress.allocations[id] = allocation
    allocation.status = event.status
    allocation.job_id = type(event.job_id) == "string" and event.job_id or nil
    allocation.allocation_session = type(event.allocation_session) == "string"
        and event.allocation_session
      or nil
    if not allocation.stages.resources then
      allocation.stages.resources = event.status == "RUNNING" and "SUCCESS" or "PENDING"
    end
    if event.terminal and event.status ~= "SUCCESS" then
      local status = event.status == "CANCELED" and "CANCELED" or "FAILURE"
      local active, failed
      for stage, value in pairs(allocation.stages) do
        if value == "RUNNING" then
          active = stage
        end
        if value == "FAILURE" then
          failed = true
        end
      end
      if not active and not failed then
        for _, stage in ipairs(M.stages) do
          if allocation.stages[stage] == "PENDING" then
            active = stage
            break
          end
        end
      end
      for stage, value in pairs(allocation.stages) do
        if stage == active then
          allocation.stages[stage] = status
        elseif value == "PENDING" then
          allocation.stages[stage] = "NONE"
        end
      end
    end
  elseif event.event == "allocation_state" then
    for _, allocation in pairs(progress.allocations) do
      if allocation.allocation_session == event.id then
        allocation.stages.resources = event.status == "READY" and "SUCCESS"
          or (event.terminal and "RELEASED" or "PENDING")
        allocation.allocation_status = event.status
      end
    end
  elseif event.event == "released" then
    for _, allocation in pairs(progress.allocations) do
      if allocation.server == event.server and allocation.allocation_session then
        allocation.stages.resources = "RELEASED"
      end
    end
  elseif event.event == "disconnected" then
    progress.status = "DISCONNECTED"
  else
    return
  end
  publish(project, file)
end

function M.complete(project, file, status)
  local progress = M.get(project, file)
  progress.status = status
  for _, allocation in pairs(progress.allocations) do
    if not allocation.status and (status == "FAILURE" or status == "CANCELED") then
      for stage, value in pairs(allocation.stages) do
        if value == "PENDING" then
          allocation.stages[stage] = "NONE"
        end
      end
    end
    if status == "SUCCESS" and allocation.status == "CANCELED" then
      progress.status = "CANCELED"
    elseif status == "SUCCESS" and allocation.status == "FAILURE" then
      progress.status = "FAILURE"
    end
  end
  publish(project, file)
end

-- Aggregation is independent of event order and preserves any failed allocation.
function M.stage(progress, name)
  local rank =
    { NONE = 0, RELEASED = 1, SUCCESS = 2, PENDING = 3, RUNNING = 4, CANCELED = 5, FAILURE = 6 }
  local status = "NONE"
  for _, allocation in pairs(progress.allocations) do
    local value = allocation.stages[name] or "NONE"
    if (rank[value] or 0) > rank[status] then
      status = value
    end
  end
  return status
end

return M
