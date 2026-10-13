local M = {}
local states = {}
local panels = {}
local MARKER = "@@OVERSEER "
local refresh
local action
local select_dimension
local command

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
    title = " " .. (state.config.name or "Experiment") .. " · " .. state.status .. " ",
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

local function config_path(project)
  return project .. "/.overseer/experiment.json"
end

local function state_for(project)
  if not states[project] then
    states[project] = {
      root = project,
      file = config_path(project),
      view = "config",
      runs = {},
      logs = {},
      status = "Ready",
      generation = 0,
    }
  end
  return states[project]
end

local function load(state)
  state.config = require("overseer.files").load_json_file(state.file)
  assert(state.config and state.config.version == 1, "Experiment config needs version 1")
  state.config.build = state.config.build or { directory = "build", commands = {} }
  state.config.preset = state.config.preset or ""
  state.config.target = state.config.target or ""
  state.config.binary = state.config.binary or ""
  for _, dimension in ipairs({ "datasets", "threads", "methods", "servers" }) do
    assert(
      type(state.config[dimension]) == "table",
      "Experiment needs " .. dimension .. ".choices and .selected"
    )
    state.config[dimension].choices = state.config[dimension].choices or {}
    state.config[dimension].selected = state.config[dimension].selected or {}
  end
end

local function save(state)
  vim.fn.mkdir(vim.fs.dirname(state.file), "p")
  vim.fn.writefile({ vim.json.encode(state.config) }, state.file)
  vim.fn.system({
    require("overseer.config").experiment.python,
    helper(),
    "format",
    state.file,
    "--project",
    state.root,
  })
end

local function labels(config, dimension)
  local items = config[dimension] or {}
  local selected = items.selected or {}
  local lookup = {}
  for _, value in ipairs(items.choices or {}) do
    if type(value) == "table" then
      lookup[tostring(value.id)] = value.label or value.id
    end
  end
  local values = {}
  for _, value in ipairs(selected) do
    table.insert(values, tostring(lookup[tostring(value)] or value))
  end
  return #values == 0 and "(none selected)" or table.concat(values, ", ")
end

local function count(config)
  local total = 1
  for _, name in ipairs({ "datasets", "threads", "methods", "servers" }) do
    total = total * #(config[name] and config[name].selected or {})
  end
  return total
end

local function render(state)
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  local config = state.config
  state.run_rows = {}
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
    vim.list_extend(lines, {
      "Preset:  " .. (config.preset ~= "" and config.preset or "(not selected)"),
      "Target:  " .. (config.target ~= "" and config.target or "(not selected)"),
      "Binary:  " .. (config.binary ~= "" and config.binary or "(choose a binary)"),
      "",
      "Datasets: " .. labels(config, "datasets"),
      "Threads:  " .. labels(config, "threads"),
      "Methods / variants: " .. labels(config, "methods"),
      "Servers:  " .. labels(config, "servers"),
      "",
      "Plan: " .. count(config) .. " runs, sequential",
      "Failure policy: "
        .. (config.stop_on_failure and "stop on first failure" or "continue remaining runs"),
      "Arguments: " .. table.concat(config.args or {}, " "),
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
    table.insert(lines, "ID   STATE       SERVER / DATASET / THREADS / METHOD")
    local runs = state.active_plan and state.active_plan.runs
      or state.plan and state.plan.runs
      or {}
    for _, spec in ipairs(runs) do
      local progress = state.runs[spec.id] or {}
      table.insert(
        lines,
        string.format(
          "%04d %-11s %s / %s / %s / %s",
          spec.id,
          progress.status or "PENDING",
          spec.server,
          spec.dataset,
          tostring(spec.threads),
          spec.method
        )
      )
      state.run_rows[#lines] = spec.id
    end
    for _, job in pairs(state.jobs or {}) do
      table.insert(
        lines,
        "Slurm " .. job.job_id .. " · " .. job.server .. " · " .. (job.status or "SUBMITTED")
      )
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
  vim.list_extend(lines, {
    "",
    "p preset · T target · b binary · d datasets",
    "t threads · m methods · h hosts / resources",
    "C configure · B build · r run sequentially",
    "w save · e edit JSON · E export · L load",
    "S submit Slurm · u refresh jobs · X cancel jobs",
    "x stop interactive run · Esc / q close · R reload",
  })
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
        title = " " .. (config.name or "Experiment") .. " · " .. state.status .. " ",
        title_pos = "center",
      })
    end
  end
  vim.api.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)
  local function highlight(row, group)
    vim.api.nvim_buf_set_extmark(state.buf, state.ns, row, 0, {
      end_col = #lines[row + 1],
      hl_group = group,
    })
  end
  highlight(0, "Title")
  highlight(1, "Special")
  highlight(3, state.status:find("FAIL") and "DiagnosticError" or "DiagnosticInfo")
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
        state.plan = data.plan
      else
        state.status = "CONFIG ERROR"
        table.insert(state.logs, result.stdout or result.stderr or "Invalid experiment config")
      end
      render(state)
    end)
  )
end

local function changed(state)
  state.generation = state.generation + 1
  save(state)
  refresh(state)
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
              .. (item.label or tostring(item.id))
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

local function scan_datasets(state)
  local directory = state.config.datasets.directory or "dataset/output"
  if not require("overseer.files").is_absolute(directory) then
    directory = state.root .. "/" .. directory
  end
  local values, names, old = {}, {}, {}
  for _, item in ipairs(state.config.datasets.choices or {}) do
    local path = item.path
    if path then
      if not require("overseer.files").is_absolute(path) then
        path = state.root .. "/" .. path
      end
      old[vim.fs.normalize(path)] = item
    end
  end
  local paths = vim.fn.globpath(directory, "**/*.mtx", false, true)
  for _, path in ipairs(paths) do
    local name = vim.fn.fnamemodify(path, ":t:r")
    names[name] = (names[name] or 0) + 1
  end
  for _, path in ipairs(paths) do
    local name = vim.fn.fnamemodify(path, ":t:r")
    local id = names[name] == 1 and name or path:sub(#directory + 2):gsub("%.mtx$", "")
    local relative = path:sub(1, #state.root + 1) == state.root .. "/" and path:sub(#state.root + 2)
      or path
    local item = vim.deepcopy(old[vim.fs.normalize(path)] or { id = id, label = id })
    item.path = relative
    table.insert(values, item)
  end
  table.sort(values, function(a, b)
    return a.id < b.id
  end)
  return values
end

select_dimension = function(state, dimension)
  if dimension == "datasets" then
    local values = scan_datasets(state)
    if #values > 0 then
      local old = {}
      for _, item in ipairs(state.config.datasets.choices or {}) do
        old[tostring(item.id)] = item
      end
      for _, item in ipairs(values) do
        item.paths = old[item.id] and old[item.id].paths or nil
      end
      state.config.datasets.choices = values
    end
  end
  multi_select(
    dimension,
    entries(state.config[dimension].choices),
    state.config[dimension].selected,
    function(values)
      state.config[dimension].selected = values
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
      vim.fn.writefile(
        { vim.json.encode({ jobs_folder = event.folder }) },
        state.root .. "/.overseer/state.json"
      )
    end
    state.jobs = state.jobs or {}
    state.jobs[event.server] =
      { server = event.server, job_id = event.job_id, status = event.status or "SUBMITTED" }
    state.status = "Slurm " .. (event.status or "SUBMITTED")
  elseif event.event == "exported" then
    state.status = "Exported " .. event.total .. " runs"
  elseif event.event == "allocation" then
    state.status = "Waiting for Slurm allocation · " .. event.server
  elseif event.event == "build" then
    local configuring = state.task and state.task.metadata.experiment_mode == "configure"
    state.status = (configuring and "Configuring · " or "Building · ") .. event.server
  elseif event.event == "error" or event.event == "build_failed" then
    state.status = "FAILURE"
    table.insert(state.logs, event.message or ("Build failed on " .. event.server))
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
  local config = override or state.config
  state.generation = state.generation + 1
  if mode ~= "poll" and mode ~= "cancel" then
    state.folder = state.root
      .. "/"
      .. (config.output_dir or "results/overseer")
      .. "/"
      .. os.date("%Y%m%d-%H%M%S")
      .. "-"
      .. vim.uv.hrtime()
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
    local id = state.run_rows[vim.api.nvim_win_get_cursor(0)[1]]
    if id then
      run_log(state, id)
    end
  end)
  for key, dimension in pairs({ d = "datasets", t = "threads", m = "methods", h = "servers" }) do
    map(key, function()
      select_dimension(state, dimension)
    end)
  end
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
        state.file = vim.fn.fnamemodify(path, ":p")
        load(state)
        changed(state)
      end
    end)
  end)
end

function M.exists(project)
  return vim.fn.filereadable(config_path(project or root())) == 1
end

function M.open(project, focus)
  local state = state_for(project or root())
  load(state)
  if not state.job_folder and vim.fn.filereadable(state.root .. "/.overseer/state.json") == 1 then
    state.job_folder =
      require("overseer.files").load_json_file(state.root .. "/.overseer/state.json").jobs_folder
    if state.job_folder and vim.fn.filereadable(state.job_folder .. "/jobs.json") == 1 then
      state.jobs = {}
      for _, job in
        ipairs(require("overseer.files").load_json_file(state.job_folder .. "/jobs.json"))
      do
        state.jobs[job.server] = job
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
  local state = state_for(task.cwd)
  local panel = panel_for()
  if automatic and task:is_running() and (not panel or panel.state ~= state) then
    return
  end
  if task.status == "FAILURE" then
    state.view = "logs"
  end
  M.open(state.root, focus)
end

function M.run()
  local state = M.open(root(), true)
  action(state, "run")
end

function M.rerun(task)
  local state = M.open(task.cwd, true)
  local snapshot = require("overseer.files").load_json_file(task.metadata.experiment_config)
  action(state, task.metadata.experiment_mode or "run", snapshot)
end

function M.init()
  local project = root()
  local state = state_for(project)
  if not M.exists(project) then
    state.config = {
      version = 1,
      name = "Experiment",
      project = "..",
      preset = "",
      target = "",
      binary = "",
      args = { "${dataset}", "${threads}", "${method}" },
      environment = { OMP_NUM_THREADS = "${threads}" },
      datasets = { directory = "dataset/output", choices = {}, selected = {} },
      threads = { choices = { 1, 2, 4, 8 }, selected = { 1, 2, 4 } },
      methods = { choices = { "a", "b", "c" }, selected = { "a" } },
      servers = { choices = { { id = "local", kind = "local" } }, selected = { "local" } },
      output_dir = "results/overseer",
      stop_on_failure = false,
      build = { directory = "build/overseer", commands = {}, before_run = false },
    }
    state.config.datasets.choices = scan_datasets(state)
    save(state)
  end
  M.open(project, true)
end

return M
