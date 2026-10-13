local M = {}

function M.library_path()
  local path = require("overseer.config").experiment.library
  return path ~= "" and path or vim.fn.stdpath("config") .. "/overseer/option_sets.json"
end

function M.read(path)
  return require("overseer.files").load_json_file(path)
end

local function pretty_json(value)
  local encoded = vim.json.encode(value)
  local output, indent, quoted, escaped = {}, 0, false, false
  local function newline()
    table.insert(output, "\n" .. string.rep("  ", indent))
  end
  for char in encoded:gmatch(".") do
    if quoted then
      table.insert(output, char)
      if escaped then
        escaped = false
      elseif char == "\\" then
        escaped = true
      elseif char == '"' then
        quoted = false
      end
    elseif char == '"' then
      quoted = true
      table.insert(output, char)
    elseif char == "{" or char == "[" then
      table.insert(output, char)
      indent = indent + 1
      newline()
    elseif char == "}" or char == "]" then
      indent = indent - 1
      newline()
      table.insert(output, char)
    elseif char == "," then
      table.insert(output, char)
      newline()
    elseif char == ":" then
      table.insert(output, ": ")
    else
      table.insert(output, char)
    end
  end
  return table.concat(output)
end

function M.write(path, value)
  -- Keep metadata transactions synchronous; job callbacks must not interleave
  -- while an external formatter is awaited between reading and replacing state.
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local temporary = path .. ".tmp." .. vim.uv.hrtime()
  vim.fn.writefile(vim.split(pretty_json(value), "\n", { plain = true }), temporary)
  assert(vim.uv.fs_rename(temporary, path))
end

function M.validate(config, project)
  local temporary = vim.fn.tempname()
  vim.fn.writefile({ vim.json.encode(config) }, temporary)
  local helper = assert(vim.api.nvim_get_runtime_file("scripts/overseer_experiment.py", false)[1])
  local result = vim
    .system({
      require("overseer.config").experiment.python,
      helper,
      "resolve",
      temporary,
      "--project",
      project,
      "--library",
      M.library_path(),
    }, { text = true })
    :wait()
  vim.fn.delete(temporary)
  return result.code == 0, (result.stdout or "") .. (result.stderr or "")
end

function M.library()
  local path = M.library_path()
  if vim.fn.filereadable(path) == 1 then
    return M.read(path)
  end
  local example = assert(vim.api.nvim_get_runtime_file("examples/option_sets.json", false)[1])
  return M.read(example)
end

function M.ensure_library()
  local path = M.library_path()
  if vim.fn.filereadable(path) == 0 then
    M.write(path, M.library())
  end
  return path
end

function M.publish(name, definition)
  local value = vim.deepcopy(definition)
  value.id = value.reserved_id or value.id or name
  value.template, value.selected, value.preset = nil, nil, nil
  local candidate = vim.deepcopy(value)
  candidate.id = candidate.reserved_id or name
  candidate.selected = {}
  local valid, message = M.validate({ version = 2, parameters = { candidate } }, vim.fn.getcwd())
  assert(valid, message)
  local library = M.library()
  library.options[name] = value
  M.write(M.library_path(), library)
end

local function metadata(project)
  local path = project .. "/.overseer/state.json"
  return vim.fn.filereadable(path) == 1 and M.read(path) or vim.empty_dict()
end

local function relative(project, path)
  return path:sub(1, #project + 1) == project .. "/" and path:sub(#project + 2) or path
end

local function absolute(project, path)
  return require("overseer.files").is_absolute(path) and path or project .. "/" .. path
end

function M.list(project)
  local files = vim.fn.globpath(project .. "/.overseer/experiments", "*.json", false, true)
  local original = project .. "/.overseer/experiment.json"
  if vim.fn.filereadable(original) == 1 then
    table.insert(files, 1, original)
  end
  local entries = {}
  for _, file in ipairs(files) do
    local config = M.read(file)
    table.insert(entries, { file = file, label = config.name or vim.fs.basename(file) })
  end
  return entries
end

function M.active(project)
  local value = metadata(project).active_experiment
  if value and vim.fn.filereadable(absolute(project, value)) == 1 then
    return absolute(project, value)
  end
  local files = M.list(project)
  return files[1] and files[1].file or project .. "/.overseer/experiment.json"
end

function M.activate(project, file)
  local data = metadata(project)
  data.active_experiment = relative(project, file)
  M.write(project .. "/.overseer/state.json", data)
end

function M.session(project, file)
  return (metadata(project).experiments or {})[relative(project, file)] or {}
end

function M.record_jobs(project, file, folder)
  local data = metadata(project)
  data.experiments = data.experiments or vim.empty_dict()
  local key = relative(project, file)
  data.experiments[key] = { jobs_folder = folder }
  M.write(project .. "/.overseer/state.json", data)
end

function M.create(project, name, base)
  local slug = name:lower():gsub("[^a-z0-9_-]+", "-"):gsub("^-+", ""):gsub("-+$", "")
  assert(slug ~= "", "Give the experiment a name with letters or numbers")
  local file = project .. "/.overseer/experiments/" .. slug .. ".json"
  assert(vim.fn.filereadable(file) == 0, "An experiment with this name already exists")
  local config = base and vim.deepcopy(base)
    or {
      version = 2,
      binary = "",
      args = {},
      parameters = {},
      servers = { choices = { { id = "local", kind = "local" } }, selected = { "local" } },
      output_dir = "results/overseer",
      stop_on_failure = false,
      build = { directory = "build/overseer", commands = {}, before_run = false },
    }
  config.name, config.project = name, "../.."
  M.write(file, config)
  M.activate(project, file)
  return file
end

return M
