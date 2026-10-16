local M = {}

local function absolute(project, path)
  path = vim.fs.normalize(path)
  return require("overseer.files").is_absolute(path) and path
    or vim.fs.normalize(project .. "/" .. path)
end

local function directories(source)
  return vim.list_extend({ source.directory }, source.directories or {})
end

local function key(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

function M.scan(project, definition)
  local source = definition.source
  local old, owners, values, seen, roots = {}, {}, {}, {}, {}
  for _, choice in ipairs(definition.choices or {}) do
    if choice.path then
      local path = key(absolute(project, choice.path))
      old[path], owners[choice.id] = choice, path
    end
  end
  local found = 0
  local pattern = vim.regex(vim.fn.glob2regpat(source.pattern))
  for _, folder in ipairs(directories(source)) do
    local directory = absolute(project, folder)
    roots[#roots + 1] = key(directory)
    -- Enumerate literal paths so commas and glob characters in folder names
    -- cannot change which directories are searched.
    for entry, kind in vim.fs.dir(directory, { depth = math.huge }) do
      local path = vim.fs.joinpath(directory, entry)
      local canonical = key(path)
      if
        (kind == "file" or kind == "link")
        and pattern:match_str(vim.fs.basename(entry))
        and not seen[canonical]
        and vim.fn.filereadable(path) == 1
      then
        local relative = path:sub(1, #project + 1) == project .. "/" and path:sub(#project + 2)
          or vim.fs.normalize(folder .. "/" .. path:sub(#directory + 2))
        local name = path:sub(#directory + 2):gsub("%.[^%.]+$", "")
        local choice = vim.deepcopy(old[canonical] or { id = name, label = name })
        if owners[choice.id] and owners[choice.id] ~= canonical then
          local base = relative
          local id, number = base, 2
          while owners[id] and owners[id] ~= canonical do
            id, number = base .. " (" .. number .. ")", number + 1
          end
          choice.id, choice.label = id, relative
        end
        choice.path = relative
        owners[choice.id], seen[canonical] = canonical, true
        values[#values + 1] = choice
        found = found + 1
      end
    end
  end
  -- Explicit inputs outside the scan folders, such as a bundled smoke matrix,
  -- remain available. Deleted files inside a scan folder disappear on rescan.
  for path, choice in pairs(old) do
    local inside = false
    for _, directory in ipairs(roots) do
      inside = inside or vim.startswith(path, directory .. "/")
    end
    if not seen[path] and not inside and vim.fn.filereadable(path) == 1 then
      values[#values + 1] = vim.deepcopy(choice)
    end
  end
  if found == 0 then
    vim.notify(
      "No "
        .. source.pattern
        .. " files found under "
        .. table.concat(directories(source), ", ")
        .. "; use Add folder… to choose another folder",
      vim.log.levels.INFO
    )
  end
  table.sort(values, function(a, b)
    return a.id < b.id
  end)
  return values
end

function M.add_folder(state, index, selected, commit, done)
  vim.ui.input(
    { prompt = "Add dataset folder (relative to project): ", completion = "dir" },
    function(input)
      if not input or vim.trim(input) == "" then
        done()
        return
      end
      local folder = vim.fs.normalize(vim.trim(input))
      local path = absolute(state.root, folder)
      if vim.fn.isdirectory(path) ~= 1 then
        vim.notify("Folder does not exist: " .. folder, vim.log.levels.ERROR)
        done()
        return
      end
      if vim.startswith(path, state.root .. "/") then
        folder = path:sub(#state.root + 2)
      end
      local definition = state.resolved.parameters[index]
      local source = vim.deepcopy(definition.source)
      for _, existing in ipairs(directories(source)) do
        if key(absolute(state.root, existing)) == key(path) then
          vim.notify("Folder is already included: " .. folder, vim.log.levels.INFO)
          done()
          return
        end
      end
      source.directories = source.directories or {}
      table.insert(source.directories, folder)
      local option = state.config.parameters[index]
      option.source = source
      option.choices =
        M.scan(state.root, { source = source, choices = option.choices or definition.choices })
      option.selected, option.preset = selected, nil
      commit(state)
      done()
    end
  )
end

return M
