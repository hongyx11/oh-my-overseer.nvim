local config = require("overseer.config")
local STATUS = require("overseer.constants").STATUS

local M = {}
local current = {}
local history = {}
local latest = {}
local windows = {}
local line_counts = {}

local function context_project()
  if vim.b.overseer_project then
    return vim.b.overseer_project
  end
  local file = vim.api.nvim_buf_get_name(0)
  local root = vim.fs.root(vim.fn.getcwd(), { ".overseer", ".vscode", "CMakePresets.json" })
  if not root and vim.bo.buftype == "" and file ~= "" then
    root = vim.fs.root(file, { ".overseer", ".vscode", "CMakePresets.json" })
  end
  root = root or vim.fs.root(vim.fn.getcwd(), { ".git" })
  return vim.fs.normalize(root or vim.fn.getcwd())
end

M.context_project = context_project

local function project(task)
  return vim.fs.normalize(
    vim.fs.root(task.cwd, { ".overseer", ".vscode", "CMakePresets.json", ".git" }) or task.cwd
  )
end

local function root_task(task)
  local tasks = require("overseer.task_list")
  while task.parent_id do
    local parent = tasks.get(task.parent_id)
    if not parent then
      break
    end
    task = parent
  end
  return task
end

local function is_workflow(task)
  return task.strategy.name == "orchestrator"
end

local function is_run(task)
  return not is_workflow(task)
    and (
      task.metadata.results_output == true or vim.tbl_contains(config.results.run_tasks, task.name)
    )
end

local function snapshot(task)
  local buf = task:get_bufnr()
  return {
    name = task.name,
    status = task.status,
    exit_code = task.exit_code,
    project = project(task),
    lines = task.metadata.start_error and {
      "Could not start " .. task.name,
      task.metadata.start_error,
    } or buf and vim.api.nvim_buf_get_lines(buf, 0, -1, false) or {},
  }
end

local function output_window()
  local tab = vim.api.nvim_get_current_tabpage()
  local win = windows[tab]
  if win and vim.api.nvim_win_is_valid(win) then
    return win
  end
end

local function display(buf, name, status, focus, key)
  vim.b[buf].overseer_project = key
  if vim.api.nvim_win_get_config(0).relative ~= "" then
    for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(candidate).relative == "" then
        vim.api.nvim_set_current_win(candidate)
        break
      end
    end
  end
  local source = vim.api.nvim_get_current_win()
  local tab = vim.api.nvim_get_current_tabpage()
  local win = output_window()
  if not win then
    vim.cmd("botright vsplit")
    win = vim.api.nvim_get_current_win()
    windows[tab] = win
    vim.api.nvim_win_set_width(win, math.max(20, math.floor(vim.o.columns * config.results.width)))
  end
  vim.api.nvim_win_set_buf(win, buf)
  for key, value in pairs({
    number = false,
    relativenumber = false,
    signcolumn = "no",
    wrap = false,
    winfixwidth = true,
  }) do
    vim.api.nvim_set_option_value(key, value, { win = win })
  end
  vim.wo[win].winbar = " " .. name:gsub("%%", "%%%%") .. " · " .. status
  vim.api.nvim_win_set_cursor(win, { math.max(1, vim.api.nvim_buf_line_count(buf)), 0 })
  line_counts[win] = vim.api.nvim_buf_line_count(buf)
  vim.keymap.set("n", "q", function()
    vim.cmd.close()
  end, { buffer = buf, silent = true, desc = "Close task results" })
  if focus then
    vim.api.nvim_set_current_win(win)
  elseif vim.api.nvim_win_is_valid(source) then
    vim.api.nvim_set_current_win(source)
  end
  return win
end

M.mount = display

function M.show(task, focus, automatic)
  if task.metadata.experiment then
    require("overseer.experiment").show(task, focus, automatic)
    return
  end
  local buf = task:get_bufnr()
  if task.metadata.start_error then
    if
      not task.metadata.results_error_buf
      or not vim.api.nvim_buf_is_valid(task.metadata.results_error_buf)
    then
      task.metadata.results_error_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(
        task.metadata.results_error_buf,
        0,
        -1,
        false,
        { "Could not start " .. task.name, task.metadata.start_error }
      )
      vim.bo[task.metadata.results_error_buf].filetype = "OverseerOutput"
      vim.bo[task.metadata.results_error_buf].modifiable = false
      vim.bo[task.metadata.results_error_buf].bufhidden = "wipe"
    end
    buf = task.metadata.results_error_buf
  end
  if not buf then
    return
  end
  local record = current[root_task(task).id]
  if record then
    record.viewed = true
  end
  display(buf, task.name, task.status, focus, project(task))
end

local function show_automatically(task, focus, record)
  if record.tab ~= vim.api.nvim_get_current_tabpage() or latest[project(record.task)] ~= record then
    return
  end
  if record.pending_show then
    vim.api.nvim_del_autocmd(record.pending_show)
    record.pending_show = nil
  end
  if vim.api.nvim_win_get_config(0).relative ~= "" and vim.bo.filetype ~= "OverseerExperiment" then
    -- Let a task/preset/file picker finish before focusing failure output.
    record.pending_show = vim.api.nvim_create_autocmd("WinEnter", {
      callback = function()
        if
          record.tab ~= vim.api.nvim_get_current_tabpage()
          or latest[project(record.task)] ~= record
        then
          record.pending_show = nil
          return true
        end
        if
          vim.api.nvim_win_get_config(0).relative == "" or vim.bo.filetype == "OverseerExperiment"
        then
          record.pending_show = nil
          vim.schedule(function()
            if not task:is_disposed() then
              show_automatically(task, focus, record)
            end
          end)
          return true
        end
      end,
    })
  else
    M.show(task, focus, true)
  end
end

local function show_saved(entry)
  if not entry.buf or not vim.api.nvim_buf_is_valid(entry.buf) then
    entry.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(entry.buf, 0, -1, false, entry.lines)
    vim.bo[entry.buf].bufhidden = "wipe"
    vim.bo[entry.buf].modifiable = false
    vim.bo[entry.buf].filetype = "OverseerOutput"
  end
  display(entry.buf, entry.name, entry.status, true, entry.project)
end

function M.toggle()
  local win = output_window()
  if win then
    vim.api.nvim_win_close(win, false)
    return
  end
  local record = latest[context_project()]
  if not record then
    vim.notify(
      "No task output for this project yet",
      vim.log.levels.INFO,
      { title = "Oh My Overseer" }
    )
    return
  end
  M.show(record.output or record.task, true)
end

function M.history()
  local entries = history[context_project()] or {}
  vim.ui.select(entries, {
    prompt = "Recent workflows:",
    format_item = function(record)
      return record.name .. " · " .. record.status
    end,
  }, function(record)
    if not record then
      return
    end
    if not record.saved then
      M.show(record.output or record.task, true)
      return
    end
    vim.ui.select(record.saved, {
      prompt = record.name .. " output:",
      format_item = function(entry)
        return entry.name .. " · " .. entry.status
      end,
    }, function(entry)
      if entry then
        record.viewed = true
        show_saved(entry)
      end
    end)
  end)
end

function M.restart()
  local record = latest[context_project()]
  if not record or record.task:is_disposed() then
    vim.notify(
      "No workflow to repeat for this project",
      vim.log.levels.INFO,
      { title = "Oh My Overseer" }
    )
  elseif record.task:is_running() then
    vim.notify(
      "This project's workflow is already running",
      vim.log.levels.INFO,
      { title = "Oh My Overseer" }
    )
  elseif record.task.metadata.experiment then
    require("overseer.experiment").rerun(record.task)
  else
    record.task:restart()
  end
end

local function visible_record(record)
  for _, entry in ipairs(record.saved or {}) do
    if entry.buf and require("overseer.util").is_bufnr_visible(entry.buf) then
      return true
    end
  end
  if current[record.task.id] == record then
    for _, task in ipairs(record.tasks) do
      local buf = task:get_bufnr()
      if buf and require("overseer.util").is_bufnr_visible(buf) then
        return true
      end
    end
  end
  return false
end

local function trim(key)
  local entries = history[key]
  for index = #entries, config.results.history_limit + 1, -1 do
    local record = entries[index]
    if
      record.complete
      and (record.status ~= STATUS.FAILURE or record.viewed)
      and not visible_record(record)
    then
      if current[record.task.id] == record and not record.task:dispose() then
        -- A visible output buffer still owns the task; keep it until closed.
      else
        table.remove(entries, index)
      end
    end
  end
end

function M.on_start(task)
  local root = root_task(task)
  local record = current[root.id]
  if not record or record.complete then
    local key = project(root)
    record = {
      task = root,
      name = root.name,
      status = STATUS.RUNNING,
      tasks = {},
      tab = vim.api.nvim_get_current_tabpage(),
    }
    current[root.id] = record
    history[key] = history[key] or {}
    table.insert(history[key], 1, record)
    latest[key] = record
    local win = output_window()
    if win and not is_run(root) then
      vim.api.nvim_win_close(win, false)
    end
    trim(key)
  end
  if not vim.tbl_contains(record.tasks, task) then
    table.insert(record.tasks, task)
  end
  if not is_workflow(task) then
    vim.api.nvim_echo({ { task.name .. "…", "ModeMsg" } }, false, {})
  end
  if is_run(task) then
    record.output = task
    vim.schedule(function()
      if
        not task:is_disposed()
        and latest[project(root)] == record
        and record.tab == vim.api.nvim_get_current_tabpage()
      then
        show_automatically(task, false, record)
      end
    end)
  end
end

function M.on_output(task)
  local win = output_window()
  local buf = task:get_bufnr()
  if not win or not buf or vim.api.nvim_win_get_buf(win) ~= buf then
    return
  end
  local at_end = vim.api.nvim_win_get_cursor(win)[1] >= (line_counts[win] or 1)
  line_counts[win] = vim.api.nvim_buf_line_count(buf)
  if at_end then
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
        vim.api.nvim_win_set_cursor(win, { math.max(1, vim.api.nvim_buf_line_count(buf)), 0 })
      end
    end)
  end
end

function M.on_complete(task, status)
  local root = root_task(task)
  local record = current[root.id]
  if not record or task ~= root or record.complete then
    return
  end
  record.complete = true
  record.status = status
  if status == STATUS.FAILURE then
    record.viewed = false
  end
  record.saved = {}
  local failed
  for _, child in ipairs(record.tasks) do
    if not is_workflow(child) then
      table.insert(record.saved, snapshot(child))
      if child.status == STATUS.FAILURE and not failed then
        failed = child
      end
    end
  end
  if failed then
    record.output = failed
  elseif not record.output and not is_workflow(task) then
    record.output = task
  end
  local target = record.output or task
  local outcome = status == STATUS.SUCCESS and "succeeded" or status:lower()
  local message = status == STATUS.FAILURE and target.name .. " failed"
    or target.name .. " " .. outcome
  if target.exit_code and status == STATUS.FAILURE then
    message = message .. " (exit " .. target.exit_code .. ")"
  end
  vim.schedule(function()
    if current[root.id] ~= record then
      return
    end
    vim.notify(
      message,
      status == STATUS.FAILURE and vim.log.levels.ERROR or vim.log.levels.INFO,
      { title = "Oh My Overseer" }
    )
    if
      status == STATUS.FAILURE
      and record.tab == vim.api.nvim_get_current_tabpage()
      and latest[project(root)] == record
    then
      show_automatically(target, config.results.focus_failure, record)
    end
    local win = output_window()
    if win and target:get_bufnr() == vim.api.nvim_win_get_buf(win) then
      vim.wo[win].winbar = " " .. target.name:gsub("%%", "%%%%") .. " · " .. target.status
    end
    trim(project(root))
  end)
end

-- Resolve aliases first so VS Code presentation settings cannot create competing windows.
function M.prepare(components)
  local resolved = require("overseer.component").resolve(components)
  local ret = {}
  local suppressed = {
    "open_output",
    "on_complete_notify",
    "on_output_notify",
    "on_result_notify",
    "on_complete_dispose",
    "on_result_diagnostics_trouble",
  }
  for _, definition in ipairs(resolved) do
    local name = type(definition) == "table" and definition[1] or definition
    if not vim.tbl_contains(suppressed, name) then
      if name == "on_output_quickfix" or name == "on_result_diagnostics_quickfix" then
        definition = type(definition) == "table" and vim.deepcopy(definition) or { name }
        definition.open = false
        if name == "on_output_quickfix" then
          definition.open_on_match = false
          definition.open_on_exit = "never"
          definition.close = false
        end
      end
      table.insert(ret, definition)
    end
  end
  table.insert(ret, "results")
  return ret
end

return M
