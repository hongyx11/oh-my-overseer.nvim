local store = require("overseer.experiment_store")
local M = {}

local function values(text)
  local result, seen = {}, {}
  for _, part in ipairs(vim.split(text, ",", { plain = true })) do
    part = vim.trim(part)
    if part ~= "" and not seen[part] then
      seen[part] = true
      table.insert(result, tonumber(part) or part)
    end
  end
  return result
end

local function selection(choices)
  local result = {}
  for _, choice in ipairs(choices) do
    table.insert(result, type(choice) == "table" and choice.id or tostring(choice))
  end
  return result
end

local function input_values(definition, callback)
  local current = {}
  for _, choice in ipairs(definition.choices or {}) do
    table.insert(
      current,
      tostring(type(choice) == "table" and (choice.value or choice.id) or choice)
    )
  end
  vim.ui.input(
    { prompt = "Values (comma separated): ", default = table.concat(current, ", ") },
    function(text)
      if not text then
        return
      end
      local choices = values(text)
      if #choices == 0 then
        vim.notify("Give this option at least one value", vim.log.levels.ERROR)
        return
      end
      callback(choices)
    end
  )
end

local function binding(definition, callback)
  if definition.reserved_id then
    vim.notify("This option's binding is reserved for Slurm", vim.log.levels.INFO)
    callback(definition)
    return
  end
  vim.ui.select({
    "Use a placeholder in experiment arguments",
    "Append a command-line flag",
    "Set an environment variable",
  }, { prompt = "How should this option reach the program?" }, function(choice)
    if not choice then
      return
    end
    definition.args, definition.environment = nil, nil
    if choice == "Use a placeholder in experiment arguments" then
      callback(definition)
      return
    end
    local argument = choice == "Append a command-line flag"
    vim.ui.input(
      { prompt = argument and "Flag (e.g. --block-size): " or "Environment variable: " },
      function(name)
        if not name or name == "" then
          return
        end
        if argument then
          definition.args = { name, "${value}" }
        else
          if not name:match("^[A-Za-z_][A-Za-z0-9_]*$") then
            vim.notify("Use a valid environment variable name", vim.log.levels.ERROR)
            return
          end
          definition.environment = { [name] = "${value}" }
        end
        callback(definition)
      end
    )
  end)
end

local function add_definition(state, definition, commit)
  for _, existing in ipairs(state.config.parameters) do
    if existing.id == definition.id then
      vim.notify("This experiment already has option " .. definition.id, vim.log.levels.WARN)
      return
    end
  end
  table.insert(state.config.parameters, definition)
  commit(state)
end

local function create_option(state, commit)
  vim.ui.input({ prompt = "Option name (e.g. Block size): " }, function(label)
    if not label or label == "" then
      return
    end
    local id = label:lower():gsub("[^a-z0-9_]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    if not id:match("^[a-z_][a-z0-9_]*$") then
      vim.notify("Use an option name beginning with a letter", vim.log.levels.ERROR)
      return
    end
    local reserved = store.library().options[id]
    local definition = reserved and reserved.reserved_id and vim.deepcopy(reserved) or {}
    definition.id, definition.label = id, label
    input_values(definition, function(choices)
      definition.choices, definition.selected = choices, selection(choices)
      binding(definition, function(value)
        add_definition(state, value, commit)
      end)
    end)
  end)
end

local function preset(state, index, commit)
  local definition = state.resolved.parameters[index]
  local names = vim.tbl_keys(definition.presets or {})
  table.sort(names)
  if #names == 0 then
    vim.notify(
      "No saved presets for this option yet. Use Save selection as preset.",
      vim.log.levels.INFO
    )
    return
  end
  vim.ui.select(
    names,
    { prompt = (definition.label or definition.id) .. " preset:" },
    function(name)
      if name then
        state.config.parameters[index].preset = name
        state.config.parameters[index].selected = nil
        commit(state)
      end
    end
  )
end

function M.add(state, commit)
  local library = store.library()
  local entries = { { label = "Create a new option…" } }
  local names = vim.tbl_keys(library.options)
  table.sort(names)
  for _, name in ipairs(names) do
    table.insert(entries, { id = name, label = library.options[name].label or name })
  end
  vim.ui.select(entries, {
    prompt = "Add option:",
    format_item = function(item)
      return item.label
    end,
  }, function(item)
    if not item then
      return
    end
    if not item.id then
      create_option(state, commit)
      return
    end
    local definition = library.options[item.id]
    local id = definition.reserved_id or definition.id or item.id
    local names = vim.tbl_keys(definition.presets or {})
    table.sort(names)
    table.insert(names, 1, "All choices")
    vim.ui.select(names, { prompt = (definition.label or id) .. " initial preset:" }, function(name)
      if not name then
        return
      end
      local option = { id = id, template = item.id }
      if name == "All choices" then
        option.selected = selection(definition.choices)
      else
        option.preset = name
      end
      add_definition(state, option, commit)
    end)
  end)
end

function M.settings(state, index, commit)
  local definition = state.resolved.parameters[index]
  vim.ui.select({
    "Choose selection preset",
    "Save selection as preset",
    "Edit available values",
    "Edit program binding",
    "Save option to shared library",
    "Remove from experiment",
  }, { prompt = (definition.label or definition.id) .. " settings:" }, function(choice)
    if not choice then
      return
    end
    local reference = state.config.parameters[index]
    if choice == "Choose selection preset" then
      preset(state, index, commit)
    elseif choice == "Save selection as preset" then
      vim.ui.input({ prompt = "Selection preset name: " }, function(name)
        if not name or name == "" then
          return
        end
        local value = vim.deepcopy(definition)
        value.presets = value.presets or vim.empty_dict()
        value.presets[name] = vim.deepcopy(definition.selected)
        if reference.template then
          local shared = vim.deepcopy(store.library().options[reference.template])
          shared.presets = shared.presets or vim.empty_dict()
          shared.presets[name] = vim.deepcopy(definition.selected)
          local ok, message = pcall(store.publish, reference.template, shared)
          if not ok then
            vim.notify(message, vim.log.levels.ERROR)
            return
          end
        else
          reference.presets = value.presets
        end
        reference.preset, reference.selected = name, nil
        commit(state)
      end)
    elseif choice == "Edit available values" then
      if definition.source then
        vim.ui.input(
          { prompt = "File directory: ", default = definition.source.directory },
          function(directory)
            if directory and directory ~= "" then
              reference.source =
                vim.tbl_extend("force", definition.source, { directory = directory })
              commit(state)
            end
          end
        )
      else
        input_values(definition, function(choices)
          reference.choices, reference.selected, reference.preset = choices, selection(choices), nil
          reference.presets = vim.empty_dict()
          commit(state)
        end)
      end
    elseif choice == "Edit program binding" then
      local value = vim.deepcopy(definition)
      binding(value, function(updated)
        reference.args = updated.args or {}
        reference.environment = updated.environment or vim.empty_dict()
        commit(state)
      end)
    elseif choice == "Save option to shared library" then
      vim.ui.input({ prompt = "Shared option name: ", default = definition.id }, function(name)
        if not name or name == "" then
          return
        end
        if not name:match("^[A-Za-z_][A-Za-z0-9_]*$") then
          vim.notify("Use letters, numbers, and underscores", vim.log.levels.ERROR)
          return
        end
        local function publish()
          local ok, message = pcall(store.publish, name, definition)
          if not ok then
            vim.notify(message, vim.log.levels.ERROR)
            return
          end
          state.config.parameters[index] =
            { id = definition.id, template = name, selected = vim.deepcopy(definition.selected) }
          commit(state)
        end
        if store.library().options[name] then
          vim.ui.select(
            { "Keep existing option", "Replace shared definition" },
            { prompt = "Shared option already exists:" },
            function(answer)
              if answer == "Replace shared definition" then
                publish()
              end
            end
          )
        else
          publish()
        end
      end)
    elseif choice == "Remove from experiment" then
      table.remove(state.config.parameters, index)
      commit(state)
    end
  end)
end

return M
