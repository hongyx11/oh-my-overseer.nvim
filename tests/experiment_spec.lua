local config = require("overseer.config")
local experiment = require("overseer.experiment")
local overseer = require("overseer")
vim.opt.rtp:append(vim.fn.getcwd())

describe("experiment panel", function()
  local cwd, root, source, source_buf, state, notify
  local function settle()
    vim.wait(60, function()
      return false
    end, 5)
  end
  local function panel_key(key)
    vim.api.nvim_set_current_win(state.win)
    local mapping = vim.fn.maparg(key, "n", false, true)
    assert.is_not_nil(mapping.callback, key)
    mapping.callback()
  end
  local function picker()
    local value
    assert.is_true(vim.wait(3000, function()
      if vim.bo.filetype ~= "TelescopePrompt" then
        return false
      end
      value = require("telescope.actions.state").get_current_picker(vim.api.nvim_get_current_buf())
      return value.manager and value.manager:num_results() > 0
    end, 10))
    return value
  end
  before_each(function()
    cwd = vim.fn.getcwd()
    root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/.overseer", "p")
    vim.fn.mkdir(root .. "/dataset/output", "p")
    vim.fn.writefile(
      { "%%MatrixMarket matrix coordinate real general", "1 1 1", "1 1 2" },
      root .. "/dataset/output/d1.mtx"
    )
    vim.fn.writefile(
      { "%%MatrixMarket matrix coordinate real general", "1 1 1", "1 1 3" },
      root .. "/dataset/output/d2.mtx"
    )
    vim.fn.writefile({
      "#!/usr/bin/env bash",
      'printf "DATASET=%s THREADS=%s METHOD=%s\\n" "$1" "$2" "$3"',
      'printf "{}\\n" > "$4"',
    }, root .. "/probe.sh")
    vim.uv.fs_chmod(root .. "/probe.sh", 493)
    local cfg = {
      version = 1,
      name = "Panel test",
      project = "..",
      preset = "",
      target = "",
      binary = "probe.sh",
      args = { "${dataset}", "${threads}", "${method}", "${result}" },
      datasets = {
        directory = "dataset/output",
        choices = {
          { id = "d1", path = "dataset/output/d1.mtx" },
          { id = "d2", path = "dataset/output/d2.mtx" },
        },
        selected = { "d1" },
      },
      threads = { choices = { 1, 2, 4 }, selected = { 1, 2 } },
      methods = {
        choices = {
          { id = "a", value = "algorithm-a" },
          { id = "b", value = "algorithm-b" },
          { id = "c", value = "algorithm-c" },
        },
        selected = { "a" },
      },
      servers = { choices = { { id = "local", kind = "local" } }, selected = { "local" } },
      output_dir = "results",
      build = { directory = "build", commands = {}, before_run = false },
    }
    vim.fn.writefile({ vim.json.encode(cfg) }, root .. "/.overseer/experiment.json")
    vim.cmd.cd(root)
    source, source_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    notify = vim.notify
    vim.notify = function() end
    overseer.setup({ dap = false, results = { enabled = true }, cmake = { enabled = false } })
    state = experiment.open(root, true)
    assert.is_true(vim.wait(3000, function()
      return state.plan ~= nil
    end, 10))
  end)
  after_each(function()
    if state.task and not state.task:is_disposed() then
      state.task:dispose(true)
    end
    settle()
    vim.api.nvim_set_current_win(source)
    vim.api.nvim_win_set_buf(source, source_buf)
    vim.cmd.only({ bang = true })
    vim.cmd.cd(cwd)
    vim.fn.delete(root, "rf")
    vim.notify = notify
    config.setup({ results = { enabled = false } })
  end)

  it("toggles one full-height right panel while preserving the source window", function()
    assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
    assert.are.equal(source_buf, vim.api.nvim_win_get_buf(source))
    assert.are.equal(vim.api.nvim_win_get_height(source), vim.api.nvim_win_get_height(state.win))
    assert.is_true(
      vim.api.nvim_win_get_position(state.win)[2] > vim.api.nvim_win_get_position(source)[2]
    )
    experiment.toggle()
    assert.are.equal(1, #vim.api.nvim_tabpage_list_wins(0))
    experiment.toggle()
    assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
    assert.are.equal(state.buf, vim.api.nvim_get_current_buf())
  end)

  it("marks multiple datasets with Tab and persists the entire selection", function()
    panel_key("d")
    local current = picker()
    current:set_prompt("d2")
    assert.is_true(vim.wait(3000, function()
      local entry = require("telescope.actions.state").get_selected_entry()
      return entry and entry.value.id == "d2"
    end, 10))
    local buf = current.prompt_bufnr
    vim.fn.maparg("<Tab>", "i", false, true).callback()
    settle()
    require("telescope.actions").select_default(buf)
    assert.is_true(vim.wait(3000, function()
      return #state.config.datasets.selected == 2
    end, 10))
    assert.are.same({ "d1", "d2" }, state.config.datasets.selected)
    local saved = require("overseer.files").load_json_file(state.file)
    assert.are.same({ "d1", "d2" }, saved.datasets.selected)
  end)

  it("selects all methods by stable IDs rather than their command-line values", function()
    panel_key("m")
    local current = picker()
    vim.fn.maparg("<C-a>", "i", false, true).callback()
    settle()
    require("telescope.actions").select_default(current.prompt_bufnr)
    assert.is_true(vim.wait(3000, function()
      return #state.config.methods.selected == 3
    end, 10))
    assert.are.same({ "a", "b", "c" }, state.config.methods.selected)
    assert.is_true(vim.wait(3000, function()
      return state.plan.total == 6
    end, 10))
  end)

  it("runs sequentially and keeps configuration and progress in the same panel", function()
    panel_key("r")
    assert.is_true(vim.wait(8000, function()
      return state.task and state.task:is_complete()
    end, 10))
    settle()
    assert.are.equal(overseer.STATUS.SUCCESS, state.task.status)
    assert.are.equal(2, state.completed)
    assert.are.equal(0, state.failed)
    assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
    assert.are.equal(state.buf, vim.api.nvim_win_get_buf(state.win))
    assert.are.equal(source_buf, vim.api.nvim_win_get_buf(source))
    assert.are.equal("config", state.view)
    panel_key("2")
    assert.are.equal("runs", state.view)
    local lines = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
    assert.is_truthy(lines:find("SUCCESS", 1, true))
    panel_key("1")
    assert.are.equal("config", state.view)
    panel_key("q")
    assert.is_true(vim.api.nvim_win_is_valid(source))
  end)

  it("captures immutable launch configuration and exports a portable bundle", function()
    panel_key("r")
    assert.is_true(vim.wait(8000, function()
      return state.task and state.task:is_complete()
    end, 10))
    local snapshot = require("overseer.files").load_json_file(state.task.metadata.experiment_config)
    assert.are.same({ "a" }, snapshot.methods.selected)
    state.config.methods.selected = { "b" }
    panel_key("w")
    assert.are.same(
      { "a" },
      require("overseer.files").load_json_file(state.task.metadata.experiment_config).methods.selected
    )
    panel_key("E")
    assert.is_true(vim.wait(8000, function()
      return state.task and state.task:is_complete()
    end, 10))
    assert.are.equal(overseer.STATUS.SUCCESS, state.task.status)
    assert.are.equal(1, vim.fn.filereadable(state.folder .. "/runner.py"))
    assert.are.equal(1, vim.fn.filereadable(state.folder .. "/local.sbatch"))
    assert.are.same(
      { "b" },
      require("overseer.files").load_json_file(state.folder .. "/experiment.json").methods.selected
    )
  end)
  it("opens failed run output automatically and retrieves a selected run log", function()
    state.config.binary = "/usr/bin/false"
    state.config.stop_on_failure = true
    panel_key("w")
    panel_key("r")
    assert.is_true(vim.wait(8000, function()
      return state.task and state.task:is_complete() and state.inspected_log ~= nil
    end, 10))
    assert.are.equal(overseer.STATUS.FAILURE, state.task.status)
    assert.are.equal("logs", state.view)
    assert.are.equal("FAILURE", state.runs[1].status)
    assert.are.equal("SKIPPED", state.runs[2].status)
    assert.are.equal(source_buf, vim.api.nvim_win_get_buf(source))
    panel_key("2")
    for row, id in pairs(state.run_rows) do
      if id == 1 then
        vim.api.nvim_win_set_cursor(state.win, { row, 0 })
      end
    end
    state.inspected_log = nil
    panel_key("<CR>")
    assert.is_true(vim.wait(3000, function()
      return state.inspected_log ~= nil
    end, 10))
    assert.is_truthy(state.inspected_log[1]:find("run 1", 1, true))
  end)
end)
