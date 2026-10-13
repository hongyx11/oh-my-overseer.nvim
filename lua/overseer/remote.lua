local store = require("overseer.experiment_store")
local M = {}
local queues = {}

local function dispatch(project)
  local queue = queues[project]
  if queue.running or not queue.pending then
    return
  end
  queue.pending, queue.running = false, true
  local manual = queue.manual
  queue.manual = false
  local argv = {
    require("overseer.config").experiment.python,
    assert(vim.api.nvim_get_runtime_file("scripts/overseer_experiment.py", false)[1]),
    "sync",
    store.active(project),
    "--project",
    project,
    "--library",
    store.library_path(),
  }
  local function complete(result)
    vim.schedule(function()
      queue.running = false
      if result.code ~= 0 then
        vim.notify(
          "Source sync failed: " .. vim.trim((result.stdout or "") .. (result.stderr or "")),
          vim.log.levels.ERROR,
          { title = "Oh My Overseer" }
        )
      elseif manual then
        vim.notify("Remote source synchronized", vim.log.levels.INFO, { title = "Oh My Overseer" })
      end
      dispatch(project)
    end)
  end
  local ok, error_message = pcall(vim.system, argv, { text = true, cwd = project }, complete)
  if not ok then
    queue.running = false
    vim.notify(tostring(error_message), vim.log.levels.ERROR, { title = "Oh My Overseer" })
  end
end

function M.sync(project, manual)
  queues[project] = queues[project] or { running = false, pending = false, generation = 0 }
  local queue = queues[project]
  queue.pending, queue.manual = true, queue.manual or manual
  dispatch(project)
end

function M.setup()
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = vim.api.nvim_create_augroup("OverseerSourceSync", { clear = true }),
    desc = "Publish saved source as another remote OMO revision",
    callback = function(args)
      if vim.bo[args.buf].buftype ~= "" then
        return
      end
      local path = vim.api.nvim_buf_get_name(args.buf)
      local project = vim.fs.root(path, { ".overseer" })
      if not project or path:sub(1, #project + 11) == project .. "/.overseer/" then
        return
      end
      local file = store.active(project)
      if vim.fn.filereadable(file) == 0 then
        return
      end
      local config = store.read(file)
      if not config or not config.sync or config.sync.on_save ~= true then
        return
      end
      queues[project] = queues[project] or { running = false, pending = false, generation = 0 }
      local queue = queues[project]
      queue.generation = queue.generation + 1
      local generation = queue.generation
      vim.defer_fn(function()
        if generation == queue.generation then
          M.sync(project, false)
        end
      end, 250)
    end,
  })
end

return M
