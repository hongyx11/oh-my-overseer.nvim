local M = {}
local selections = {}

local function absolute(path, root)
  local is_absolute = require("overseer.files").is_absolute(path)
  return vim.fs.normalize(is_absolute and path or root .. "/" .. path)
end

function M.root()
  if vim.b.overseer_project then
    return vim.fs.root(vim.b.overseer_project, { "CMakePresets.json", "CMakeUserPresets.json" })
  end
  local root = vim.fs.root(vim.fn.getcwd(), { "CMakePresets.json", "CMakeUserPresets.json" })
  if not root and vim.bo.buftype == "" and vim.api.nvim_buf_get_name(0) ~= "" then
    root =
      vim.fs.root(vim.api.nvim_buf_get_name(0), { "CMakePresets.json", "CMakeUserPresets.json" })
  end
  return root
end

local function json(path)
  return require("overseer.files").load_json_file(path)
end

local function expand(value, root, preset, file, resolving)
  resolving = resolving or {}
  local macros = {
    sourceDir = root,
    sourceParentDir = vim.fs.dirname(root),
    sourceDirName = vim.fs.basename(root),
    presetName = preset.name,
    generator = preset.generator or "",
    hostSystemName = vim.uv.os_uname().sysname,
    fileDir = vim.fs.dirname(file),
    dollar = "$",
    pathListSep = package.config:sub(1, 1) == "\\" and ";" or ":",
  }
  value = value:gsub("%$penv{([^}]+)}", function(key)
    return vim.env[key] or ""
  end)
  value = value:gsub("%$env{([^}]+)}", function(key)
    local env = preset.environment and preset.environment[key]
    if env == vim.NIL then
      return ""
    elseif env then
      assert(not resolving[key], "Cyclic CMake environment variable: " .. key)
      resolving[key] = true
      local result = expand(env, root, preset, file, resolving)
      resolving[key] = nil
      return result
    end
    return vim.env[key] or ""
  end)
  value = value:gsub("%${([^}]+)}", function(key)
    assert(macros[key] ~= nil, "Unsupported CMake preset macro: " .. key)
    return macros[key]
  end)
  return value
end

local function definitions(root)
  local configure, build, seen = {}, {}, {}
  local function load(path)
    path = vim.fs.normalize(path)
    if seen[path] or not vim.uv.fs_stat(path) then
      return
    end
    seen[path] = true
    local data = json(path)
    for _, include in ipairs(data.include or {}) do
      include = expand(include, root, { name = "" }, path)
      load(absolute(include, vim.fs.dirname(path)))
    end
    for _, preset in ipairs(data.configurePresets or {}) do
      preset._file = path
      if preset.binaryDir then
        preset._binary_file = path
      end
      configure[preset.name] = preset
    end
    for _, preset in ipairs(data.buildPresets or {}) do
      build[preset.name] = preset
    end
  end
  load(root .. "/CMakePresets.json")
  load(root .. "/CMakeUserPresets.json")
  return configure, build
end

local function inherit(defs, name, seen)
  local own = assert(defs[name], "Unknown CMake preset: " .. name)
  seen = seen or {}
  assert(not seen[name], "Cyclic CMake preset inheritance: " .. name)
  seen[name] = true
  local ret = {}
  local parents = type(own.inherits) == "string" and { own.inherits } or own.inherits or {}
  for _, parent in ipairs(parents) do
    ret = vim.tbl_deep_extend("keep", ret, inherit(defs, parent, seen))
  end
  ret = vim.tbl_deep_extend("force", ret, own)
  seen[name] = nil
  return ret
end

local function binary_dir(root, name)
  local configure = definitions(root)
  local preset = inherit(configure, name)
  local dir = assert(preset.binaryDir, "Preset '" .. name .. "' has no binaryDir")
  return absolute(expand(dir, root, preset, preset._binary_file or preset._file), root)
end

local function base_binary_dir(root)
  local file = root .. "/.vscode/tasks.json"
  if not vim.uv.fs_stat(file) then
    return nil
  end
  local platform = vim.uv.os_uname().sysname == "Darwin" and "osx" or "linux"
  for _, task in ipairs(json(file).tasks or {}) do
    if task.label == "Build" then
      task = vim.tbl_deep_extend("force", task, task[platform] or {})
      for index, arg in ipairs(task.args or {}) do
        if arg == "--build" and task.args[index + 1] ~= "--preset" then
          return absolute(task.args[index + 1]:gsub("%${workspaceFolder}", root), root)
        elseif arg == "--preset" then
          local configure, build = definitions(root)
          local preset = inherit(build, task.args[index + 1])
          assert(configure[preset.configurePreset], "Build preset has no configure preset")
          return binary_dir(root, preset.configurePreset)
        end
      end
    end
  end
end

local function state_file(root)
  return vim.fn.stdpath("state") .. "/overseer/cmake-" .. vim.fn.sha256(root) .. ".json"
end

function M.get(root)
  root = root or M.root()
  if not root then
    return nil
  end
  local name = selections[root]
  if not name and vim.uv.fs_stat(state_file(root)) then
    name = json(state_file(root)).preset
  end
  if not name then
    return nil
  end
  return {
    root = root,
    name = name,
    binary_dir = binary_dir(root, name),
    base_binary_dir = base_binary_dir(root),
  }
end

function M.select(callback, root)
  root = root or M.root()
  if not root then
    vim.notify(
      "No CMake presets found in this project",
      vim.log.levels.INFO,
      { title = "Oh My Overseer" }
    )
    if callback then
      callback(nil)
    end
    return
  end
  vim.system(
    { "cmake", "--list-presets=configure" },
    { cwd = root, text = true },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        vim.notify(result.stderr, vim.log.levels.ERROR, { title = "CMake presets" })
        if callback then
          callback(nil)
        end
        return
      end
      local choices = {}
      for line in (result.stdout or ""):gmatch("[^\n]+") do
        local name, label = line:match('^%s+"([^"]+)"%s*%-?%s*(.*)$')
        if name then
          table.insert(choices, { name = name, label = label })
        end
      end
      vim.ui.select(choices, {
        prompt = "CMake configure preset:",
        format_item = function(choice)
          return choice.label ~= "" and choice.name .. " · " .. choice.label or choice.name
        end,
      }, function(choice)
        if not choice then
          if callback then
            callback(nil)
          end
          return
        end
        local ok, selection = pcall(function()
          return {
            root = root,
            name = choice.name,
            binary_dir = binary_dir(root, choice.name),
            base_binary_dir = base_binary_dir(root),
          }
        end)
        if not ok then
          vim.notify(selection, vim.log.levels.ERROR, { title = "CMake presets" })
          if callback then
            callback(nil)
          end
          return
        end
        selections[root] = choice.name
        local file = state_file(root)
        vim.fn.mkdir(vim.fs.dirname(file), "p")
        vim.fn.writefile({ vim.json.encode({ preset = choice.name }) }, file)
        vim.notify(
          "CMake preset: " .. choice.name,
          vim.log.levels.INFO,
          { title = "Oh My Overseer" }
        )
        if callback then
          callback(selection)
        end
      end)
    end)
  )
end

function M.ensure(callback)
  local root = M.root()
  if not root then
    callback(true)
    return
  end
  local ok, selected = pcall(M.get, root)
  if ok and selected then
    callback(true)
  else
    M.select(function(choice)
      callback(choice ~= nil)
    end, root)
  end
end

local function artifact(binary, target, configuration_name)
  local reply = binary .. "/.cmake/api/v1/reply/"
  local indexes = vim.fn.glob(reply .. "index-*.json", false, true)
  table.sort(indexes)
  if #indexes == 0 then
    return nil
  end
  for _, object in ipairs(json(indexes[#indexes]).objects or {}) do
    if object.kind == "codemodel" then
      for _, configuration in ipairs(json(reply .. object.jsonFile).configurations or {}) do
        for _, entry in
          ipairs(
            (not configuration_name or configuration.name == configuration_name)
                and configuration.targets
              or {}
          )
        do
          if entry.name == target then
            for _, item in ipairs(json(reply .. entry.jsonFile).artifacts or {}) do
              local path = absolute(item.path, binary)
              if vim.fn.executable(path) == 1 then
                return path
              end
            end
          end
        end
      end
    end
  end
end

function M.refresh_run(task)
  local selection = task.metadata.cmake_preset
  if task.name ~= "Run" or not selection or type(task.cmd) ~= "table" then
    return
  end
  -- Compound tasks create children before configure/build, so resolve the executable at start.
  local prefix = selection.binary_dir .. "/"
  if task.cmd[1]:sub(1, #prefix) == prefix then
    task.cmd[1] = artifact(
      selection.binary_dir,
      vim.fs.basename(task.cmd[1]),
      selection.build_config
    ) or task.cmd[1]
  end
end

-- The parent carries the choice so selecting another preset cannot alter an in-flight workflow.
function M.apply(opts)
  if opts.metadata and opts.metadata.cmake_preserve_command then
    return
  end
  local selection
  if opts.parent_id then
    local parent = require("overseer.task_list").get(opts.parent_id)
    selection = parent and parent.metadata.cmake_preset
  end
  local root =
    vim.fs.root(opts.cwd or vim.fn.getcwd(), { "CMakePresets.json", "CMakeUserPresets.json" })
  selection = selection or root and M.get(root)
  if not selection then
    return
  end
  opts.metadata = vim.tbl_extend("force", opts.metadata or {}, { cmake_preset = selection })
  if type(opts.cmd) ~= "table" then
    return
  end
  local cmd = vim.deepcopy(opts.cmd)
  local executable = vim.fs.basename(cmd[1] or "")
  if executable == "cmake" then
    for index, arg in ipairs(cmd) do
      if arg == "--build" then
        for config_index, value in ipairs(cmd) do
          if value == "--config" then
            selection.build_config = cmd[config_index + 1]
          end
        end
        if cmd[index + 1] == "--preset" then
          table.remove(cmd, index + 1)
        end
        cmd[index + 1] = selection.binary_dir
        opts.cmd = cmd
        return
      elseif arg == "--preset" then
        cmd[index + 1] = selection.name
        local query = selection.binary_dir .. "/.cmake/api/v1/query"
        vim.fn.mkdir(query, "p")
        vim.fn.writefile({}, query .. "/codemodel-v2")
        opts.cmd = cmd
        return
      end
    end
  elseif executable == "ctest" then
    for index, arg in ipairs(cmd) do
      if arg == "--test-dir" then
        cmd[index + 1] = selection.binary_dir
      elseif arg == "--preset" then
        cmd[index] = "--test-dir"
        cmd[index + 1] = selection.binary_dir
      end
    end
    opts.cmd = cmd
  elseif opts.name == "Run" and selection.base_binary_dir then
    local old = selection.base_binary_dir .. "/"
    local path = absolute(cmd[1], opts.cwd or selection.root)
    if path:sub(1, #old) == old then
      cmd[1] = artifact(selection.binary_dir, executable, selection.build_config)
        or selection.binary_dir .. "/" .. path:sub(#old + 1)
      opts.cmd = cmd
    end
  end
end

return M
