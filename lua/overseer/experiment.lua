local store = require("overseer.experiment_store")
local M = {}
local states = {}
local panels = {}
local MARKER = "@@OVERSEER "
local refresh
local action
local select_option
local choose_experiment
local new_experiment
local modify_row
local command
local render

local function display_text(value)
  return tostring(value):gsub("\r", "\\r"):gsub("\n", "\\n")
end

local function root()
  return require("overseer.results").context_project()
end

local function panel_config(state)
  local opts = require("overseer.config").experiment
  local columns, rows = vim.o.columns, math.max(3, vim.o.lines - vim.o.cmdheight)
  local width = math.max(1, math.min(columns - 2, math.floor(columns * opts.width)))
  local height = math.max(1, math.min(rows - 2, math.floor(rows * opts.height)))
  return {
    relative = "editor",
    row = math.max(0, math.floor((rows - height - 2) / 2)),
    col = math.max(0, math.floor((columns - width - 2) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = opts.border,
    title = " " .. display_text(state.config.name or "Experiment") .. " · " .. display_text(
      state.status
    ) .. " ",
    title_pos = "center",
    zindex = 40,
  }
end

local function panel_for(tab)
  local panel = panels[tab or vim.api.nvim_get_current_tabpage()]
  if panel and vim.api.nvim_win_is_valid(panel.win) then
    return panel
  end
end

local function source_window()
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(current).relative == "" then
    return current
  end
  local panel = panel_for()
  if panel and vim.api.nvim_win_is_valid(panel.source) then
    return panel.source
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
end

local function close_panel(panel)
  local focused = vim.api.nvim_get_current_win() == panel.win
  local source = panel.source
  vim.api.nvim_win_close(panel.win, false)
  if focused and source and vim.api.nvim_win_is_valid(source) then
    vim.api.nvim_set_current_win(source)
  end
end

vim.api.nvim_create_autocmd("VimResized", {
  group = vim.api.nvim_create_augroup("OverseerExperimentPanel", { clear = true }),
  callback = function()
    for _, panel in pairs(panels) do
      if vim.api.nvim_win_is_valid(panel.win) then
        vim.api.nvim_win_set_config(panel.win, panel_config(panel.state))
        render(panel.state)
      end
    end
  end,
})

local function helper()
  return assert(
    vim.api.nvim_get_runtime_file("scripts/overseer_experiment.py", false)[1],
    "Experiment runner is missing"
  )
end

local function state_for_file(project, file)
  if not states[file] then
    states[file] = {
      root = project,
      file = file,
      view = "config",
      runs = {},
      logs = {},
      status = "Ready",
      generation = 0,
    }
  end
  return states[file]
end

local function state_for(project)
  return state_for_file(project, store.active(project))
end

local function append_log(state, output)
  vim.list_extend(state.logs, vim.split(output, "\n", { plain = true, trimempty = true }))
end

local function load(state)
  state.config = store.read(state.file)
  assert(
    state.config and state.config.version == 2,
    "Experiment needs parameter-list schema version 2"
  )
  state.config.build = state.config.build or { directory = "build", commands = {} }
  state.config.preset = state.config.preset or ""
  state.config.target = state.config.target or ""
  state.config.binary = state.config.binary or ""
  state.config.parameters = state.config.parameters or {}
  store.ensure_library()
  local result = vim.system(command(state, "resolve", nil, nil), { text = true }):wait()
  assert(result.code == 0, result.stdout or result.stderr)
  state.resolved = vim.json.decode(result.stdout)
end

local function save(state)
  local valid, message = store.validate(state.config, state.root)
  if not valid then
    vim.notify(message, vim.log.levels.ERROR)
    load(state)
    return false
  end
  store.write(state.file, state.config)
  return true
end

local function labels(definition)
  local lookup, values = {}, {}
  for _, item in ipairs(definition.choices or {}) do
    if type(item) == "table" then
      lookup[tostring(item.id)] = item.label or item.id
    end
  end
  for _, value in ipairs(definition.selected or {}) do
    table.insert(values, tostring(lookup[tostring(value)] or value))
  end
  return #values == 0 and "(none selected)" or table.concat(values, ", ")
end

local function count(config)
  local total = #(config.servers and config.servers.selected or {})
  for _, option in ipairs(config.parameters or {}) do
    total = total * #(option.selected or {})
  end
  return total
end

local function status_highlight(value)
  value = value:upper()
  if value:find("FAIL") or value:find("ERROR") then
    return "OverseerExperimentError"
  elseif value:find("CANCEL") or value:find("SKIP") then
    return "OverseerExperimentWarning"
  elseif
    value:find("SUCCESS")
    or value:find("COMPLETED")
    or value:find("SAVED")
    or value:find("EXPORTED")
  then
    return "OverseerExperimentSuccess"
  elseif value == "PENDING" then
    return "OverseerExperimentMuted"
  end
  return "OverseerExperimentInfo"
end

local function footer_cell(control, width)
  if not control then
    return {}
  end
  local rows = {}
  local inline = width >= 52
  local prefix = inline and string.format("%-12s ", control[1]) or "  "
  local available = math.max(1, width - #prefix)
  if not inline then
    for first = 1, #control[1], width do
      table.insert(rows, { text = control[1]:sub(first, first + width - 1), label = true })
    end
  end
  local current = ""
  local function append(item, separator)
    local joined = current == "" and item or current .. separator .. item
    if vim.fn.strdisplaywidth(joined) > available and current ~= "" then
      table.insert(rows, { text = prefix .. current, label = inline and #rows == 0 })
      prefix = inline and string.rep(" ", 13) or "  "
      current = item
    else
      current = joined
    end
  end
  for _, item in ipairs(vim.split(control[2], " · ", { plain = true })) do
    if vim.fn.strdisplaywidth(item) <= available then
      append(item, " · ")
    else
      for word in item:gmatch("%S+") do
        for first = 1, #word, available do
          append(word:sub(first, first + available - 1), " ")
        end
      end
    end
  end
  if current ~= "" then
    table.insert(rows, { text = prefix .. current, label = inline and #rows == 0 })
  end
  return rows
end

render = function(state)
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  local config = state.resolved or state.config
  local job_rows = {}
  state.run_rows, state.rows = {}, {}
  local lines = {
    "EXPERIMENT · " .. (config.name or "Untitled"),
    (state.view == "config" and "[1 Config]" or " 1 Config ")
      .. "  "
      .. (state.view == "runs" and "[2 Runs]" or " 2 Runs ")
      .. "  "
      .. (state.view == "logs" and "[3 Logs]" or " 3 Logs "),
    "",
    "Status: " .. state.status,
    "Progress: "
      .. (state.completed or 0)
      .. "/"
      .. (state.active_plan and state.active_plan.total or count(config))
      .. " · failures: "
      .. (state.failed or 0),
    "",
  }
  local log_end
  if state.view == "config" then
    local function row(text, editor)
      table.insert(lines, text)
      state.rows[#lines] = editor
    end
    row(
      "Experiment: " .. (config.name or "Untitled") .. "   [N new · O choose]",
      { kind = "experiment" }
    )
    row(
      "Preset:  " .. (config.preset ~= "" and config.preset or "(not selected)"),
      { kind = "preset" }
    )
    row(
      "Target:  " .. (config.target ~= "" and config.target or "(not selected)"),
      { kind = "target" }
    )
    row(
      "Binary:  " .. (config.binary ~= "" and config.binary or "(choose a binary)"),
      { kind = "binary" }
    )
    row("Arguments: " .. table.concat(config.args or {}, " "), { kind = "arguments" })
    row("Servers: " .. labels(config.servers), { kind = "servers" })
    table.insert(lines, "")
    table.insert(lines, "OPTIONS · Enter / m modifies the highlighted row")
    for index, option in ipairs(config.parameters or {}) do
      local suffix = "  ["
        .. #option.selected
        .. "/"
        .. #option.choices
        .. " selected]"
        .. (option.preset and "  [preset: " .. option.preset .. "]" or "")
      row(
        (option.label or option.id) .. " (${" .. option.id .. "}): " .. labels(option) .. suffix,
        { kind = "parameter", index = index, id = option.id }
      )
    end
    if #(config.parameters or {}) == 0 then
      table.insert(lines, "No options yet · a adds an option from the library or creates one")
    end
    vim.list_extend(lines, {
      "",
      "Plan: " .. count(config) .. " runs, sequential",
      "Failure policy: "
        .. (config.stop_on_failure and "stop on first failure" or "continue remaining runs"),
      "",
      "SERVER PROFILES",
    })
    local chosen = {}
    for _, id in ipairs(config.servers.selected) do
      chosen[tostring(id)] = true
    end
    for _, server in ipairs(config.servers.choices) do
      local resources = server.slurm or {}
      local details = server.host or server.extends or "local"
      if server.extends then
        details = details .. " · inherits " .. server.extends
      end
      if resources.gpus then
        details = details .. " · GPUs " .. tostring(resources.gpus)
      end
      if resources.constraint then
        details = details .. " · " .. resources.constraint
      end
      if resources.partition then
        details = details .. " · partition " .. resources.partition
      end
      if server.enabled == false then
        details = details .. " · unconfigured"
      end
      table.insert(
        lines,
        (chosen[tostring(server.id)] and "[x] " or "[ ] ") .. server.id .. "  " .. details
      )
    end
    if state.plan then
      table.insert(lines, "")
      table.insert(lines, "SELECTED SERVER SETTINGS")
      for _, profile in ipairs(state.plan.profiles) do
        table.insert(lines, profile.id .. " · " .. (profile.host or "local"))
        table.insert(lines, "  project: " .. profile.project_dir)
        if profile.binary then
          table.insert(lines, "  binary: " .. profile.binary)
        end
        for _, key in ipairs(vim.tbl_keys(profile.slurm or {})) do
          table.insert(lines, "  " .. key .. ": " .. tostring(profile.slurm[key]))
        end
      end
    end
  elseif state.view == "runs" then
    table.insert(lines, "ID   STATE       SERVER / OPTIONS")
    local runs = state.active_plan and state.active_plan.runs
      or state.plan and state.plan.runs
      or {}
    for _, spec in ipairs(runs) do
      local progress = state.runs[spec.id] or {}
      local values = {}
      local definition = state.active_plan or state.plan
      for _, option in ipairs(definition and definition.parameters or {}) do
        table.insert(values, option.id .. "=" .. tostring(spec.choices[option.id]))
      end
      table.insert(
        lines,
        string.format(
          "%04d %-11s %s / %s",
          spec.id,
          progress.status or "PENDING",
          spec.server,
          table.concat(values, " · ")
        )
      )
      state.run_rows[#lines] = spec.id
    end
    for _, job in pairs(state.jobs or {}) do
      table.insert(
        lines,
        "Slurm "
          .. job.job_id
          .. " · "
          .. job.server
          .. (job.slurm and job.slurm.nodes and " · nodes=" .. tostring(job.slurm.nodes) or "")
          .. " · "
          .. (job.status or "SUBMITTED")
      )
      job_rows[#lines] = job.status or "SUBMITTED"
    end
  else
    if not state.inspected_log then
      local running = state.task and state.task:is_running()
      table.insert(
        lines,
        "Output: " .. (state.log_name or "No operation") .. (running and " · live" or "")
      )
      table.insert(lines, "")
    end
    local logs = state.inspected_log or state.logs
    vim.list_extend(lines, logs)
    if #logs == 0 then
      table.insert(lines, "No output yet")
    end
    log_end = #lines
  end
  local footer_start = #lines
  local controls = {
    { "Experiments", "N new · O switch · L load" },
    { "Options", "Enter/m edit row · a add · s settings" },
    { "Build setup", "p preset · T target · b binary" },
    { "Execute", "C configure · B build · r run · x stop" },
    { "Files", "w save · e edit JSON · R reload · E export" },
    { "Slurm", "S submit · u refresh · X cancel" },
    { "View", "1 config · 2 runs · 3 logs · Esc/q close" },
  }
  vim.list_extend(lines, { "", "CONTROLS" })
  local footer_marks = {}
  local gap = 3
  local width = math.max(1, math.floor((panel_config(state).width - gap) / 2))
  local middle = math.ceil(#controls / 2)
  for index = 1, middle do
    local left = footer_cell(controls[index], width)
    local right = footer_cell(controls[index + middle], width)
    for row = 1, math.max(#left, #right) do
      local first, second = left[row] or { text = "" }, right[row] or { text = "" }
      local padding = string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(first.text)) + gap)
      table.insert(lines, first.text .. padding .. second.text)
      if first.label then
        table.insert(
          footer_marks,
          { row = #lines - 1, first = 0, last = math.min(12, #first.text) }
        )
      end
      if second.label then
        local start = #first.text + #padding
        table.insert(
          footer_marks,
          { row = #lines - 1, first = start, last = start + math.min(12, #second.text) }
        )
      end
    end
  end
  lines = vim.tbl_map(display_text, lines)
  local follow_requested = state.follow_logs
  state.follow_logs = nil
  state.log_end = log_end
  vim.bo[state.buf].modifiable = true
  local cursors = {}
  for _, panel in pairs(panels) do
    if panel.state == state and vim.api.nvim_win_is_valid(panel.win) then
      cursors[panel.win] = vim.api.nvim_win_get_cursor(panel.win)
    end
  end
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  for _, panel in pairs(panels) do
    local cursor = cursors[panel.win]
    if cursor then
      local follow = log_end
        and not state.inspected_log
        and (follow_requested or (panel.log_end and cursor[1] >= panel.log_end))
      panel.log_end = log_end
      vim.api.nvim_win_set_cursor(
        panel.win,
        { follow and log_end or math.min(cursor[1], #lines), 0 }
      )
      vim.wo[panel.win].wrap = state.view ~= "logs"
      vim.wo[panel.win].linebreak = true
      vim.api.nvim_win_set_config(panel.win, {
        title = " " .. display_text(config.name or "Experiment") .. " · " .. display_text(
          state.status
        ) .. " ",
        title_pos = "center",
      })
    end
  end
  vim.api.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)
  local function span(row, group, first, last)
    if last <= first then
      return
    end
    vim.api.nvim_buf_set_extmark(state.buf, state.ns, row, first, {
      end_col = last,
      hl_group = group,
    })
  end
  local function highlight(row, group)
    span(row, group, 0, #lines[row + 1])
  end
  local function match(row, text, group)
    local first, last = lines[row + 1]:find(text, 1, true)
    if first then
      span(row, group, first - 1, last)
    end
  end
  local function numbers(row)
    for first, _, last in lines[row + 1]:gmatch("()(%d+)()") do
      span(row, "OverseerExperimentNumber", first - 1, last - 1)
    end
  end
  highlight(0, "OverseerExperimentSection")
  highlight(1, "OverseerExperimentMuted")
  local tab = ({ config = "[1 Config]", runs = "[2 Runs]", logs = "[3 Logs]" })[state.view]
  match(1, tab, "OverseerExperimentActive")
  span(3, "OverseerExperimentLabel", 0, 7)
  span(3, status_highlight(state.status), 8, #lines[4])
  numbers(4)
  match(4, "Progress:", "OverseerExperimentLabel")
  match(4, "failures:", "OverseerExperimentLabel")
  local failure = lines[5]:find("failures: ", 1, true)
  if failure then
    span(
      4,
      (state.failed or 0) == 0 and "OverseerExperimentSuccess" or "OverseerExperimentError",
      failure + 9,
      #lines[5]
    )
  end
  for number, editor in pairs(state.rows) do
    local row, text = number - 1, lines[number]
    local delimiter
    if editor.kind == "parameter" then
      local token = "(${" .. editor.id .. "})"
      local first, last = text:find(token, 1, true)
      delimiter = last + 1
      span(row, "OverseerExperimentLabel", 0, first - 1)
      span(row, "OverseerExperimentMuted", first - 1, last)
    else
      delimiter = text:find(":", 1, true)
      span(row, "OverseerExperimentLabel", 0, delimiter - 1)
    end
    local first = text:find("%S", delimiter + 1)
    local group = (editor.kind == "binary" or editor.kind == "target") and "OverseerExperimentPath"
      or "OverseerExperimentValue"
    if first then
      span(row, group, first - 1, #text)
    end
    if editor.kind == "parameter" then
      numbers(row)
      local choice_count = text:find("  [", 1, true)
      if choice_count then
        span(row, "OverseerExperimentMuted", choice_count - 1, #text)
      end
    end
    if
      text:find("(none selected)", 1, true)
      or text:find("(not selected)", 1, true)
      or text:find("(choose a binary)", 1, true)
    then
      span(row, "OverseerExperimentWarning", first - 1, #text)
    end
    for start, finish in text:gmatch("()%${[%w_]+}()") do
      span(row, "OverseerExperimentMuted", start - 1, finish - 1)
    end
  end
  for number = 7, footer_start do
    local row, text = number - 1, lines[number]
    if
      text:match("^OPTIONS")
      or text == "SERVER PROFILES"
      or text == "SELECTED SERVER SETTINGS"
      or text:match("^ID   STATE")
    then
      highlight(row, "OverseerExperimentSection")
    elseif state.run_rows[number] then
      local value = text:match("^%d+%s+(%S+)")
      match(row, text:match("^%d+"), "OverseerExperimentNumber")
      match(row, value, status_highlight(value))
    elseif job_rows[number] then
      numbers(row)
      span(row, "OverseerExperimentLabel", 0, 5)
      local value = display_text(job_rows[number])
      span(row, status_highlight(value), #text - #value, #text)
    elseif text:match("^%[[x ]%]") then
      local selected = text:sub(2, 2) == "x"
      highlight(row, selected and "OverseerExperimentValue" or "OverseerExperimentMuted")
      span(row, selected and "OverseerExperimentSuccess" or "OverseerExperimentMuted", 0, 3)
      match(row, "unconfigured", "OverseerExperimentWarning")
    elseif text:match("^Plan:") or text:match("^Failure policy:") or text:match("^Output:") then
      highlight(row, "OverseerExperimentInfo")
      numbers(row)
    elseif text:match("^  [%w_]+:") then
      local delimiter = text:find(":", 1, true)
      span(row, "OverseerExperimentLabel", 2, delimiter - 1)
      span(
        row,
        (text:match("^  project:") or text:match("^  binary:")) and "OverseerExperimentPath"
          or "OverseerExperimentValue",
        delimiter + 1,
        #text
      )
    elseif state.view == "logs" then
      local lower = text:lower()
      if
        lower:match("^%s*error")
        or lower:find(": error:", 1, true)
        or lower:find("fatal error", 1, true)
        or lower:find("cmake error", 1, true)
        or lower:match("^failed:")
      then
        highlight(row, "OverseerExperimentError")
      elseif
        lower:match("^%s*warning")
        or lower:find(": warning:", 1, true)
        or lower:find("cmake warning", 1, true)
      then
        highlight(row, "OverseerExperimentWarning")
      elseif lower:match("^%-%- configuring done") or lower:match("^%-%- generating done") then
        highlight(row, "OverseerExperimentSuccess")
      elseif text == "No output yet" or text:match("^Output for run") then
        highlight(row, "OverseerExperimentMuted")
      end
    end
  end
  highlight(footer_start + 1, "OverseerExperimentMuted")
  for _, mark in ipairs(footer_marks) do
    span(mark.row, "OverseerExperimentLabel", mark.first, mark.last)
  end
end

local function run_log(state, id)
  if not state.run_folder then
    return
  end
  state.log_request = (state.log_request or 0) + 1
  local request = state.log_request
  local argv = command(state, "log", state.run_folder)
  vim.list_extend(argv, { "--run-id", tostring(id) })
  vim.system(
    argv,
    { text = true },
    vim.schedule_wrap(function(result)
      if state.log_request ~= request then
        return
      end
      state.view = "logs"
      state.inspected_log = vim.split(
        result.code == 0 and result.stdout or result.stdout .. (result.stderr or ""),
        "\n",
        { plain = true }
      )
      table.insert(state.inspected_log, 1, "Output for run " .. id .. " · snapshot")
      render(state)
    end)
  )
end

command = function(state, mode, folder, file)
  local argv = {
    require("overseer.config").experiment.python,
    helper(),
    mode,
    file or state.file,
    "--library",
    store.library_path(),
    "--project",
    state.root,
  }
  if folder then
    vim.list_extend(argv, { "--output-dir", folder })
  end
  return argv
end

refresh = function(state)
  local generation = state.generation
  vim.system(
    command(state, "describe"),
    { text = true },
    vim.schedule_wrap(function(result)
      if generation ~= state.generation then
        return
      end
      if result.code == 0 then
        local data = vim.json.decode(result.stdout)
        state.plan, state.resolved = data.plan, data.config
      else
        state.status = "CONFIG ERROR"
        append_log(state, (result.stdout or "") .. (result.stderr or ""))
      end
      render(state)
    end)
  )
end

local function changed(state)
  state.generation = state.generation + 1
  if save(state) then
    load(state)
    refresh(state)
  end
  render(state)
end

local function entries(values)
  local ret = {}
  for _, value in ipairs(values) do
    if type(value) ~= "table" then
      value = { id = tostring(value), value = value }
    end
    table.insert(ret, value)
  end
  return ret
end

-- Each selection is a set. Enter applies the entire set; Tab marks multiple values.
local function multi_select(title, items, selection, callback)
  local selected = {}
  for _, id in ipairs(selection) do
    selected[tostring(id)] = true
  end
  local picker
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local finders = require("telescope.finders")
  local function finder()
    return finders.new_table({
      results = items,
      entry_maker = function(item)
        return {
          value = item,
          ordinal = item.label or tostring(item.id),
          display = function()
            return (selected[tostring(item.id)] and "[x] " or "[ ] ")
              .. display_text(item.label or item.id)
          end,
        }
      end,
    })
  end
  picker = require("telescope.pickers").new(
    require("telescope.themes").get_dropdown({ previewer = false }),
    {
      prompt_title = title .. " · Tab marks · Enter applies",
      finder = finder(),
      sorter = require("telescope.config").values.generic_sorter({}),
      selection_strategy = "row",
      attach_mappings = function(buf, map)
        local function toggle()
          local entry = action_state.get_selected_entry()
          if entry then
            local id = tostring(entry.value.id)
            selected[id] = not selected[id]
            picker:refresh(finder(), { reset_prompt = false })
          end
        end
        local function all(value)
          for _, item in ipairs(items) do
            selected[tostring(item.id)] = value
          end
          picker:refresh(finder(), { reset_prompt = false })
        end
        map({ "i", "n" }, "<Tab>", toggle)
        map({ "i", "n" }, "<C-a>", function()
          all(true)
        end)
        map({ "i", "n" }, "<C-u>", function()
          all(false)
        end)
        actions.select_default:replace(function()
          local values = {}
          for _, item in ipairs(items) do
            if selected[tostring(item.id)] then
              table.insert(values, item.id)
            end
          end
          actions.close(buf)
          vim.schedule(function()
            callback(values)
          end)
        end)
        return true
      end,
    }
  )
  picker:find()
end

local function scan_files(state, definition)
  local source = definition.source
  local directory = source.directory
  if not require("overseer.files").is_absolute(directory) then
    directory = state.root .. "/" .. directory
  end
  local old, values = {}, {}
  for _, choice in ipairs(definition.choices or {}) do
    if choice.path then
      local path = require("overseer.files").is_absolute(choice.path) and choice.path
        or state.root .. "/" .. choice.path
      old[vim.fs.normalize(path)] = choice
    end
  end
  for _, path in ipairs(vim.fn.globpath(directory, "**/" .. source.pattern, false, true)) do
    local relative = path:sub(1, #state.root + 1) == state.root .. "/" and path:sub(#state.root + 2)
      or path
    local name = path:sub(#directory + 2):gsub("%.[^%.]+$", "")
    local choice = vim.deepcopy(old[vim.fs.normalize(path)] or { id = name, label = name })
    choice.path = relative
    table.insert(values, choice)
  end
  table.sort(values, function(a, b)
    return a.id < b.id
  end)
  return values
end

select_option = function(state, index)
  local definition = state.resolved.parameters[index]
  local option = state.config.parameters[index]
  local choices = definition.choices
  if definition.source then
    local files = scan_files(state, definition)
    if #files > 0 then
      option.choices, choices = files, files
    end
  end
  multi_select(
    definition.label or definition.id,
    entries(choices),
    definition.selected,
    function(values)
      option.selected, option.preset = values, nil
      changed(state)
    end
  )
end

local function select_servers(state)
  multi_select(
    "Servers / resources",
    entries(state.config.servers.choices),
    state.config.servers.selected,
    function(values)
      state.config.servers.selected = values
      changed(state)
    end
  )
end

local function choose_target(state)
  vim.system(
    command(state, "targets"),
    { text = true },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        vim.notify(result.stdout or result.stderr, vim.log.levels.ERROR)
        return
      end
      local targets = vim.json.decode(result.stdout)
      if #targets == 0 then
        vim.notify(
          "Configure first with C to discover CMake executable targets",
          vim.log.levels.INFO
        )
        return
      end
      vim.ui.select(targets, {
        prompt = "CMake executable target:",
        format_item = function(item)
          return item.id
        end,
      }, function(item)
        if item then
          state.config.target, state.config.binary = item.id, item.binary
          changed(state)
        end
      end)
    end)
  )
end

local function choose_binary(state)
  local actions = require("telescope.actions")
  require("telescope.builtin").find_files({
    cwd = state.root,
    no_ignore = true,
    attach_mappings = function(buf)
      actions.select_default:replace(function()
        local entry = require("telescope.actions.state").get_selected_entry()
        if not entry then
          return
        end
        local path = entry.path or entry.value
        actions.close(buf)
        vim.schedule(function()
          if vim.fn.executable(path) ~= 1 then
            vim.notify("Choose an executable file", vim.log.levels.WARN)
            return
          end
          state.config.binary = path:sub(1, #state.root + 1) == state.root .. "/"
              and path:sub(#state.root + 2)
            or path
          changed(state)
        end)
      end)
      return true
    end,
  })
end

local function preset(state)
  require("overseer.cmake").select(function(selection)
    if not selection then
      return
    end
    local old = state.config.build.directory
    local directory = selection.binary_dir:sub(1, #state.root + 1) == state.root .. "/"
        and selection.binary_dir:sub(#state.root + 2)
      or selection.binary_dir
    state.config.preset = selection.name
    state.config.build.directory = directory
    if state.config.binary:sub(1, #old + 1) == old .. "/" then
      state.config.binary = directory .. state.config.binary:sub(#old + 1)
    end
    changed(state)
  end, state.root)
end

choose_experiment = function(state)
  vim.ui.select(store.list(state.root), {
    prompt = "Experiment:",
    format_item = function(item)
      return item.label
    end,
  }, function(item)
    if item then
      M.open_file(state.root, item.file, true)
    end
  end)
end

new_experiment = function(state)
  vim.ui.input({ prompt = "New experiment name: " }, function(name)
    if not name or name == "" then
      return
    end
    vim.ui.select(
      { "Copy current settings", "Start empty" },
      { prompt = "New experiment:" },
      function(choice)
        if not choice then
          return
        end
        local ok, file = pcall(
          store.create,
          state.root,
          name,
          choice == "Copy current settings" and state.config or nil
        )
        if ok then
          M.open_file(state.root, file, true)
        else
          vim.notify(file, vim.log.levels.ERROR)
        end
      end
    )
  end)
end

modify_row = function(state)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  if state.run_rows[line] then
    run_log(state, state.run_rows[line])
    return
  end
  local row = state.rows[line]
  if not row then
    vim.notify("Move to a configuration or option row and press Enter", vim.log.levels.INFO)
    return
  end
  local editors = {
    parameter = function()
      select_option(state, row.index)
    end,
    preset = function()
      preset(state)
    end,
    target = function()
      choose_target(state)
    end,
    binary = function()
      choose_binary(state)
    end,
    servers = function()
      select_servers(state)
    end,
    experiment = function()
      choose_experiment(state)
    end,
    arguments = function()
      local current = vim.tbl_map(vim.fn.shellescape, state.config.args or {})
      vim.ui.input({
        prompt = "Program arguments (quotes group spaces): ",
        default = table.concat(current, " "),
      }, function(text)
        if not text then
          return
        end
        local argv = command(state, "parse-args", nil, nil)
        table.insert(argv, "--text=" .. text)
        local result = vim.system(argv, { text = true }):wait()
        if result.code ~= 0 then
          vim.notify(result.stdout or result.stderr, vim.log.levels.ERROR)
          return
        end
        state.config.args = vim.json.decode(result.stdout)
        changed(state)
      end)
    end,
  }
  editors[row.kind]()
end

local function process_event(state, event)
  if event.event == "start" then
    state.runs[event.id] = vim.tbl_extend("force", event, { status = "RUNNING" })
    state.status = "Running " .. event.id .. "/" .. event.total .. " · " .. event.server
  elseif event.event == "finish" then
    state.completed = (state.completed or 0) + 1
    state.failed = (state.failed or 0) + (event.exit_code ~= 0 and 1 or 0)
    state.runs[event.id] =
      vim.tbl_extend("force", event, { status = event.exit_code == 0 and "SUCCESS" or "FAILURE" })
  elseif event.event == "complete" then
    state.status = event.exit_code == 0 and "SUCCESS" or "FAILURE"
  elseif event.event == "submitted" or event.event == "job" then
    if event.folder then
      state.job_folder = event.folder
      store.record_jobs(state.root, state.file, event.folder)
    end
    state.jobs = state.jobs or {}
    local key = event.allocation or event.server
    local job = state.jobs[key] or {}
    job.server, job.job_id, job.status = event.server, event.job_id, event.status or "SUBMITTED"
    job.slurm = event.slurm or job.slurm
    state.jobs[key] = job
    state.status = "Slurm " .. (event.status or "SUBMITTED")
  elseif event.event == "exported" then
    state.status = "Exported " .. event.total .. " runs"
  elseif event.event == "allocation" then
    state.status = "Waiting for Slurm allocation · "
      .. event.server
      .. (event.slurm and event.slurm.nodes and " · nodes=" .. tostring(event.slurm.nodes) or "")
  elseif event.event == "build" then
    local configuring = state.task and state.task.metadata.experiment_mode == "configure"
    state.status = (configuring and "Configuring · " or "Building · ") .. event.server
  elseif event.event == "error" or event.event == "build_failed" then
    state.status = "FAILURE"
    append_log(state, event.message or ("Build failed on " .. event.server))
  elseif event.event == "canceled" then
    state.status = "CANCELED"
  end
end

local function on_lines(state, lines)
  if
    not state.active_plan
    and state.run_folder
    and vim.fn.filereadable(state.run_folder .. "/manifest.json") == 1
  then
    state.active_plan =
      require("overseer.files").load_json_file(state.run_folder .. "/manifest.json")
  end
  for _, line in ipairs(lines) do
    if line:sub(1, #MARKER) == MARKER then
      local ok, event = pcall(vim.json.decode, line:sub(#MARKER + 1))
      if ok then
        process_event(state, event)
      end
    elseif line ~= "" then
      table.insert(state.logs, line)
    end
  end
  while #state.logs > 300 do
    table.remove(state.logs, 1)
  end
  render(state)
end

action = function(state, mode, override)
  if state.task and state.task:is_running() then
    vim.notify("This experiment is already running", vim.log.levels.INFO)
    return
  end
  load(state)
  save(state)
  local config = override or state.resolved
  state.generation = state.generation + 1
  if mode ~= "poll" and mode ~= "cancel" then
    local directory = config.output_dir or "results/overseer"
    if not require("overseer.files").is_absolute(directory) then
      directory = state.root .. "/" .. directory
    end
    state.folder = directory .. "/" .. os.date("%Y%m%d-%H%M%S") .. "-" .. vim.uv.hrtime()
  elseif not state.job_folder or vim.fn.filereadable(state.job_folder .. "/jobs.json") == 0 then
    vim.notify("No submitted Slurm jobs for this experiment", vim.log.levels.INFO)
    return
  else
    state.folder = state.job_folder
  end
  if mode == "run" or mode == "submit" then
    state.run_folder = state.folder
    state.active_plan = nil
    state.runs, state.completed, state.failed = {}, 0, 0
  end
  state.log_request = (state.log_request or 0) + 1
  state.inspected_log = nil
  state.follow_logs = true
  state.logs = {}
  state.status = mode .. "…"
  vim.fn.mkdir(state.folder, "p")
  local snapshot = state.folder .. "/launch.json"
  local launch = vim.deepcopy(config)
  launch.project = state.root
  vim.fn.writefile({ vim.json.encode(launch) }, snapshot)
  local names = {
    run = "Run experiment",
    build = "Build experiment",
    configure = "Configure experiment",
    export = "Export experiment",
    submit = "Submit Slurm experiment",
    poll = "Refresh Slurm jobs",
    cancel = "Cancel Slurm jobs",
  }
  state.log_name = names[mode]
  local task = require("overseer").new_task({
    name = names[mode],
    cwd = state.root,
    cmd = command(state, mode, state.folder, snapshot),
    strategy = { "jobstart", use_terminal = false },
    metadata = {
      experiment = true,
      results_output = true,
      experiment_config = snapshot,
      experiment_mode = mode,
      experiment_source = state.file,
    },
  })
  state.task = task
  task:subscribe("on_output_lines", function(_, lines)
    on_lines(state, lines)
  end)
  task:subscribe("on_complete", function(_, status)
    if status == "FAILURE" then
      state.status = "FAILURE"
      state.view = "logs"
    elseif status == "CANCELED" then
      state.status = "CANCELED"
    elseif mode == "build" or mode == "configure" then
      state.status = "Ready"
    end
    if mode == "run" and state.active_plan then
      local first_failed
      for _, spec in ipairs(state.active_plan.runs) do
        local trial = state.runs[spec.id]
        if not trial then
          state.runs[spec.id] = { status = "SKIPPED" }
        elseif trial.status == "RUNNING" and status == "CANCELED" then
          trial.status = "CANCELED"
        elseif trial.status == "FAILURE" and not first_failed then
          first_failed = spec.id
        end
      end
      if status == "FAILURE" and first_failed then
        run_log(state, first_failed)
      end
    end
    refresh(state)
    render(state)
  end)
  refresh(state)
  task:start()
  render(state)
end

local function map_panel(state)
  local function close()
    local panel = panel_for()
    if panel and panel.state == state then
      close_panel(panel)
    end
  end
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, close, {
      buffer = state.buf,
      silent = true,
      desc = "Close experiment panel",
    })
  end
  local function map(key, callback)
    vim.keymap.set("n", key, callback, { buffer = state.buf, silent = true })
  end
  for number, view in ipairs({ "config", "runs", "logs" }) do
    map(tostring(number), function()
      state.view = view
      if view == "logs" then
        state.log_request = (state.log_request or 0) + 1
        state.inspected_log = nil
        state.follow_logs = true
      end
      render(state)
    end)
  end
  map("<CR>", function()
    modify_row(state)
  end)
  map("m", function()
    modify_row(state)
  end)
  map("a", function()
    require("overseer.experiment_options").add(state, changed)
  end)
  map("s", function()
    local row = state.rows[vim.api.nvim_win_get_cursor(0)[1]]
    if row and row.kind == "parameter" then
      require("overseer.experiment_options").settings(state, row.index, changed)
    else
      vim.notify("Place the cursor on an option row first", vim.log.levels.INFO)
    end
  end)
  map("N", function()
    new_experiment(state)
  end)
  map("O", function()
    choose_experiment(state)
  end)
  for key, mode in pairs({
    C = "configure",
    B = "build",
    r = "run",
    E = "export",
    S = "submit",
    u = "poll",
    X = "cancel",
  }) do
    map(key, function()
      action(state, mode)
    end)
  end
  map("p", function()
    preset(state)
  end)
  map("T", function()
    choose_target(state)
  end)
  map("b", function()
    choose_binary(state)
  end)
  map("w", function()
    save(state)
    state.status = "Saved"
    render(state)
  end)
  map("R", function()
    load(state)
    state.generation = state.generation + 1
    refresh(state)
    render(state)
  end)
  map("x", function()
    if state.task and state.task:is_running() then
      state.task:stop()
    end
  end)
  map("e", function()
    local panel = panel_for()
    if panel and panel.state == state then
      close_panel(panel)
    end
    vim.cmd.edit(vim.fn.fnameescape(state.file))
  end)
  map("L", function()
    vim.ui.input({ prompt = "Experiment JSON: ", completion = "file" }, function(path)
      if path and path ~= "" then
        M.open_file(state.root, vim.fn.fnamemodify(path, ":p"), true)
      end
    end)
  end)
end

function M.exists(project)
  return vim.fn.filereadable(store.active(project or root())) == 1
end

local function open_state(state, focus)
  load(state)
  if not state.job_folder then
    state.job_folder = store.session(state.root, state.file).jobs_folder
    if state.job_folder and vim.fn.filereadable(state.job_folder .. "/jobs.json") == 1 then
      state.jobs = {}
      for _, job in
        ipairs(require("overseer.files").load_json_file(state.job_folder .. "/jobs.json"))
      do
        state.jobs[job.allocation] = job
      end
    end
  end
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    state.buf = vim.api.nvim_create_buf(false, true)
    state.ns = vim.api.nvim_create_namespace("overseer-experiment")
    vim.bo[state.buf].bufhidden = "hide"
    vim.bo[state.buf].filetype = "OverseerExperiment"
    map_panel(state)
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local source = source_window()
  local panel = panel_for(tab)
  if not panel then
    panel = { state = state, source = source }
    panel.win = vim.api.nvim_open_win(state.buf, focus ~= false, panel_config(state))
    panels[tab] = panel
    vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(panel.win),
      once = true,
      callback = function()
        if panels[tab] == panel then
          panels[tab] = nil
        end
      end,
    })
  else
    panel.state, panel.source = state, source
    panel.log_end = nil
    vim.api.nvim_win_set_buf(panel.win, state.buf)
    vim.api.nvim_win_set_config(panel.win, panel_config(state))
    if focus ~= false then
      vim.api.nvim_set_current_win(panel.win)
    end
  end
  state.win = panel.win
  vim.b[state.buf].overseer_project = state.root
  vim.wo[panel.win].number = false
  vim.wo[panel.win].relativenumber = false
  vim.wo[panel.win].signcolumn = "no"
  vim.wo[panel.win].foldcolumn = "0"
  vim.wo[panel.win].cursorline = true
  vim.wo[panel.win].winbar = ""
  refresh(state)
  render(state)
  return state
end

function M.open(project, focus)
  return open_state(state_for(project or root()), focus)
end

function M.open_file(project, file, focus)
  store.activate(project, file)
  return open_state(state_for_file(project, file), focus)
end

function M.toggle()
  local state = state_for(root())
  local panel = panel_for()
  if panel and panel.state == state then
    close_panel(panel)
  else
    M.open(state.root, true)
  end
end

function M.show(task, focus, automatic)
  local state = state_for_file(task.cwd, task.metadata.experiment_source)
  local panel = panel_for()
  if automatic and task:is_running() and (not panel or panel.state ~= state) then
    return
  end
  if task.status == "FAILURE" then
    state.view = "logs"
  end
  open_state(state, focus)
end

function M.run()
  local state = M.open(root(), true)
  action(state, "run")
end

function M.rerun(task)
  local state = open_state(state_for_file(task.cwd, task.metadata.experiment_source), true)
  local snapshot = require("overseer.files").load_json_file(task.metadata.experiment_config)
  action(state, task.metadata.experiment_mode or "run", snapshot)
end

function M.init()
  local project = root()
  local state = state_for(project)
  if not M.exists(project) then
    state.config = {
      version = 2,
      name = "Experiment",
      project = "..",
      binary = "",
      args = {},
      parameters = {},
      servers = { choices = { { id = "local", kind = "local" } }, selected = { "local" } },
      output_dir = "results/overseer",
      build = { directory = "build/overseer", commands = {}, before_run = false },
    }
    store.ensure_library()
    save(state)
  end
  M.open(project, true)
end

return M
