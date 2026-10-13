local progress = require("overseer.experiment_progress")
local store = require("overseer.experiment_store")
local M = {}
local panels = {}
local icons = {
  NONE = "—",
  PENDING = "◌",
  RUNNING = "↻",
  SUCCESS = "✓",
  FAILURE = "✗",
  CANCELED = "■",
  RELEASED = "○",
}
local groups = {
  NONE = "Comment",
  PENDING = "DiagnosticWarn",
  RUNNING = "DiagnosticInfo",
  SUCCESS = "DiagnosticOk",
  FAILURE = "DiagnosticError",
  CANCELED = "DiagnosticWarn",
  RELEASED = "Comment",
}

local function geometry()
  local width = math.max(1, math.min(vim.o.columns - 4, 116))
  local height = math.max(1, math.min(vim.o.lines - 5, 28))
  return {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height - 3) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Oh My Overseer · Experiments ",
    title_pos = "center",
    zindex = 50,
  }
end

local function render(panel)
  if not vim.api.nvim_win_is_valid(panel.win) then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(panel.win)
  local lines = { "  EXPERIMENTS · independent execution and saved progress", "" }
  local spans = {}
  panel.rows = {}
  for _, entry in ipairs(store.list(panel.project)) do
    local config = store.read(entry.file)
    local value = progress.get(panel.project, entry.file)
    local servers = table.concat(config.servers and config.servers.selected or {}, ", ")
    local first = #lines + 1
    table.insert(
      lines,
      "  "
        .. entry.label
        .. "   ·   "
        .. servers
        .. (value.status and "   ·   " .. value.status or "")
    )
    table.insert(spans, { first, 0, -1, "Title" })
    local cells = {}
    local offset = 2
    for _, stage in ipairs(progress.stages) do
      local status = progress.stage(value, stage)
      local text = (icons[status] or "?") .. " " .. stage:gsub("^%l", string.upper)
      text = text .. string.rep(" ", math.max(1, 19 - vim.fn.strdisplaywidth(text)))
      table.insert(cells, text)
      table.insert(spans, { first + 1, offset, offset + #text, groups[status] })
      offset = offset + #text
    end
    table.insert(lines, "  " .. table.concat(cells))
    local jobs = {}
    for _, allocation in pairs(value.allocations) do
      if type(allocation.job_id) == "string" then
        table.insert(
          jobs,
          allocation.server .. " #" .. allocation.job_id .. " " .. (allocation.status or "held")
        )
      end
    end
    table.sort(jobs)
    if #jobs > 0 then
      table.insert(lines, "  " .. table.concat(jobs, " · "))
    end
    if value.status == "DISCONNECTED" then
      table.insert(lines, "  Disconnected · A reconnect; remote work continues")
    end
    table.insert(lines, "")
    for row = first, #lines do
      panel.rows[row] = entry
    end
  end
  if #lines == 2 then
    table.insert(lines, "  No experiments yet. N creates one.")
  end
  vim.list_extend(lines, {
    "  Edit     Enter details / logs       Clone    c copy + choose server · N new",
    "  Execute  C configure · B build      Run      r interactive · S batch",
    "  Remote   Y sync · A reconnect       Control  x cancel command · D release resources",
    "  View     R refresh · q close        Status   ◌ waiting · ↻ active · ✓ done · ✗ failed · ■ canceled",
  })
  vim.bo[panel.buf].modifiable = true
  vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)
  vim.bo[panel.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(panel.buf, panel.ns, 0, -1)
  for _, span in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(
      panel.buf,
      panel.ns,
      span[1] - 1,
      span[2],
      { end_col = span[3] == -1 and #lines[span[1]] or span[3], hl_group = span[4] }
    )
  end
  vim.api.nvim_win_set_cursor(panel.win, { math.min(cursor[1], #lines), cursor[2] })
end

local function close(panel)
  if vim.api.nvim_win_is_valid(panel.win) then
    vim.api.nvim_win_close(panel.win, true)
  end
  if panel.source and vim.api.nvim_win_is_valid(panel.source) then
    vim.api.nvim_set_current_win(panel.source)
  end
end

local function selected(panel)
  return panel.rows[vim.api.nvim_win_get_cursor(panel.win)[1]]
end

local function create(panel, clone)
  local entry = selected(panel)
  if clone and not entry then
    return
  end
  vim.ui.input(
    { prompt = clone and "Copy experiment as: " or "New experiment name: " },
    function(name)
      if not name or name == "" then
        return
      end
      local base = clone and store.read(entry.file) or nil
      local ok, file = pcall(store.create, panel.project, name, base)
      if not ok then
        vim.notify(file, vim.log.levels.ERROR)
        return
      end
      local config = store.read(file)
      if clone then
        vim.ui.select(config.servers.choices, {
          prompt = "Server for copied experiment:",
          format_item = function(item)
            return item.label or item.id
          end,
        }, function(server)
          if server then
            config.servers.selected = { server.id }
            store.write(file, config)
          end
          render(panel)
        end)
      else
        close(panel)
        require("overseer.experiment").open_file(panel.project, file, true)
      end
      render(panel)
    end
  )
end

function M.toggle(project)
  local current = panels[project]
  if current and vim.api.nvim_win_is_valid(current.win) then
    close(current)
    return current
  end
  local panel = { project = project, source = vim.api.nvim_get_current_win() }
  panel.buf = vim.api.nvim_create_buf(false, true)
  panel.ns = vim.api.nvim_create_namespace("overseer-experiment-manager")
  vim.bo[panel.buf].bufhidden = "wipe"
  vim.bo[panel.buf].filetype = "OverseerExperiments"
  vim.b[panel.buf].overseer_project = project
  panel.win = vim.api.nvim_open_win(panel.buf, true, geometry())
  vim.wo[panel.win].cursorline = true
  vim.wo[panel.win].wrap = false
  panels[project] = panel
  local id = "manager:" .. project
  progress.subscribe(id, function(changed_project)
    if changed_project == project then
      render(panel)
    end
  end)
  local timer = assert(vim.uv.new_timer())
  timer:start(
    3000,
    3000,
    vim.schedule_wrap(function()
      if not vim.api.nvim_win_is_valid(panel.win) then
        return
      end
      for _, entry in ipairs(store.list(project)) do
        for _, allocation in pairs(progress.get(project, entry.file).allocations) do
          if allocation.allocation_session and allocation.stages.resources ~= "RELEASED" then
            require("overseer.experiment").poll_resources(project, entry.file)
            break
          end
        end
      end
    end)
  )
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(panel.win),
    once = true,
    callback = function()
      timer:stop()
      timer:close()
      progress.unsubscribe(id)
      panels[project] = nil
    end,
  })
  local function map(key, callback)
    vim.keymap.set("n", key, callback, { buffer = panel.buf, silent = true })
  end
  for _, key in ipairs({ "q", "<Esc>" }) do
    map(key, function()
      close(panel)
    end)
  end
  map("<CR>", function()
    local entry = selected(panel)
    if entry then
      close(panel)
      require("overseer.experiment").open_file(project, entry.file, true)
    end
  end)
  map("c", function()
    create(panel, true)
  end)
  map("N", function()
    create(panel, false)
  end)
  map("R", function()
    render(panel)
  end)
  for key, mode in pairs({
    C = "configure",
    B = "build",
    r = "run",
    S = "submit",
    Y = "sync",
    A = "reconnect",
    x = "cancel",
    D = "release",
  }) do
    map(key, function()
      local entry = selected(panel)
      if entry then
        require("overseer.experiment").execute_file(project, entry.file, mode)
      end
    end)
  end
  render(panel)
  vim.api.nvim_win_set_cursor(panel.win, { 3, 0 })
  for _, entry in ipairs(store.list(project)) do
    require("overseer.experiment").watch_file(project, entry.file)
  end
  return panel
end

vim.api.nvim_create_autocmd("VimResized", {
  group = vim.api.nvim_create_augroup("OverseerExperimentManager", { clear = true }),
  callback = function()
    for _, panel in pairs(panels) do
      if vim.api.nvim_win_is_valid(panel.win) then
        vim.api.nvim_win_set_config(panel.win, geometry())
        render(panel)
      end
    end
  end,
})

return M
