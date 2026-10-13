local config = require("overseer.config")
local experiment = require("overseer.experiment")
local overseer = require("overseer")
vim.opt.rtp:append(vim.fn.getcwd())

describe("experiment panel", function()
  local cwd, root, source, source_buf, state, notify, system, source_size
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
    source_size = { vim.api.nvim_win_get_width(source), vim.api.nvim_win_get_height(source) }
    notify = vim.notify
    system = vim.system
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
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then
        vim.api.nvim_win_close(win, true)
      end
    end
    vim.api.nvim_win_set_buf(source, source_buf)
    vim.cmd.only({ bang = true })
    vim.cmd.cd(cwd)
    vim.fn.delete(root, "rf")
    vim.notify = notify
    vim.system = system
    config.setup({ results = { enabled = false } })
  end)

  it("toggles a centered floating panel without resizing or replacing the source window", function()
    local window = vim.api.nvim_win_get_config(state.win)
    assert.are.equal("editor", window.relative)
    assert.are.equal(math.floor(vim.o.columns * 0.85), window.width)
    assert.are.equal(math.floor((vim.o.lines - vim.o.cmdheight) * 0.85), window.height)
    assert.are.equal(math.floor((vim.o.columns - window.width - 2) / 2), window.col)
    assert.are.equal(
      math.floor((vim.o.lines - vim.o.cmdheight - window.height - 2) / 2),
      window.row
    )
    assert.are.equal(source_buf, vim.api.nvim_win_get_buf(source))
    assert.are.same(
      source_size,
      { vim.api.nvim_win_get_width(source), vim.api.nvim_win_get_height(source) }
    )
    experiment.toggle()
    assert.are.equal(1, #vim.api.nvim_tabpage_list_wins(0))
    assert.are.equal(source, vim.api.nvim_get_current_win())
    experiment.toggle()
    assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
    assert.are.equal(state.buf, vim.api.nvim_get_current_buf())
    local win = state.win
    experiment.open(root, true)
    assert.are.equal(win, state.win)
    assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
    panel_key("<Esc>")
    assert.are.equal(source, vim.api.nvim_get_current_win())
  end)

  it("marks multiple datasets with Tab and persists the entire selection", function()
    panel_key("d")
    local current = picker()
    assert.is_true(
      vim.api.nvim_win_get_config(current.prompt_win).zindex
        > vim.api.nvim_win_get_config(state.win).zindex
    )
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
  for _, operation in ipairs({ { key = "C", label = "configure" }, { key = "B", label = "build" } }) do
    it(
      "streams current " .. operation.label .. " output after inspecting a previous run",
      function()
        panel_key("r")
        assert.is_true(vim.wait(8000, function()
          return state.task and state.task:is_complete()
        end, 10))
        panel_key("2")
        for row, id in pairs(state.run_rows) do
          if id == 1 then
            vim.api.nvim_win_set_cursor(state.win, { row, 0 })
          end
        end
        panel_key("<CR>")
        assert.is_true(vim.wait(3000, function()
          return state.inspected_log ~= nil
        end, 10))
        local gate = root .. "/release-" .. operation.label
        local script = root .. "/slow-" .. operation.label .. ".sh"
        vim.fn.writefile({
          "#!/usr/bin/env bash",
          "echo " .. operation.label .. "-START",
          "echo " .. operation.label .. "-STDERR >&2",
          'while [ ! -e "$1" ]; do sleep 0.02; done',
          "echo " .. operation.label .. "-DONE",
        }, script)
        state.config.build.commands = { { "bash", script, gate } }
        if operation.key == "B" then
          table.insert(state.config.build.commands, 1, { "bash", "-c", "echo configure-for-build" })
        end
        panel_key("w")
        panel_key(operation.key)
        assert.is_nil(state.inspected_log)
        panel_key("3")
        local function output()
          return table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
        end
        assert.is_true(vim.wait(3000, function()
          local text = output()
          return text:find(operation.label .. "-START", 1, true)
            and text:find(operation.label .. "-STDERR", 1, true)
        end, 10))
        assert.is_true(state.task:is_running(), "output must arrive before completion")
        assert.is_falsy(output():find("Output for run 1", 1, true))
        assert.is_falsy(output():find("DATASET=", 1, true))
        assert.are.equal(source_buf, vim.api.nvim_win_get_buf(source))
        vim.fn.writefile({}, gate)
        assert.is_true(vim.wait(5000, function()
          return state.task:is_complete() and output():find(operation.label .. "-DONE", 1, true)
        end, 10))
        assert.are.equal(overseer.STATUS.SUCCESS, state.task.status)
      end
    )
  end
  it("follows live output while allowing scrolling back until Logs is selected again", function()
    local script, first, second = root .. "/scroll.sh", root .. "/first", root .. "/second"
    vim.fn.writefile({
      'for i in {1..20}; do echo "initial-$i"; done',
      'while [ ! -e "$1" ]; do sleep 0.02; done',
      'for i in {1..20}; do echo "middle-$i"; done',
      'while [ ! -e "$2" ]; do sleep 0.02; done',
      "echo final-output",
    }, script)
    state.config.build.commands = { { "bash", script, first, second } }
    panel_key("w")
    panel_key("B")
    panel_key("3")
    local function row(text)
      for number, line in ipairs(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)) do
        if line == text then
          return number
        end
      end
    end
    assert.is_true(vim.wait(3000, function()
      return row("initial-20") ~= nil
    end, 10))
    assert.is_true(state.task:is_running())
    assert.are.equal(row("initial-20"), vim.api.nvim_win_get_cursor(state.win)[1])
    vim.api.nvim_win_set_cursor(state.win, { 3, 0 })
    vim.fn.writefile({}, first)
    assert.is_true(vim.wait(3000, function()
      return row("middle-20") ~= nil
    end, 10))
    assert.are.equal(3, vim.api.nvim_win_get_cursor(state.win)[1])
    panel_key("3")
    assert.are.equal(row("middle-20"), vim.api.nvim_win_get_cursor(state.win)[1])
    vim.fn.writefile({}, second)
    assert.is_true(vim.wait(3000, function()
      return state.task:is_complete() and row("final-output") ~= nil
    end, 10))
    assert.are.equal(row("final-output"), vim.api.nvim_win_get_cursor(state.win)[1])
  end)

  it(
    "ignores an old log response after starting a new operation and switching to live output",
    function()
      panel_key("r")
      assert.is_true(vim.wait(8000, function()
        return state.task and state.task:is_complete()
      end, 10))
      panel_key("2")
      for row, id in pairs(state.run_rows) do
        if id == 1 then
          vim.api.nvim_win_set_cursor(state.win, { row, 0 })
        end
      end
      local old_response
      vim.system = function(argv, opts, callback)
        if argv[3] == "log" then
          old_response = callback
          return {}
        end
        return system(argv, opts, callback)
      end
      panel_key("<CR>")
      assert.is_not_nil(old_response)
      vim.system = system
      state.config.build.commands = { { "bash", "-c", "echo CURRENT-CONFIGURE" } }
      panel_key("w")
      panel_key("C")
      panel_key("3")
      old_response({ code = 0, stdout = "OUTDATED-RUN-SNAPSHOT", stderr = "" })
      assert.is_true(vim.wait(3000, function()
        return state.task:is_complete()
      end, 10))
      settle()
      assert.is_nil(state.inspected_log)
      local output = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
      assert.is_truthy(output:find("CURRENT-CONFIGURE", 1, true))
      assert.is_falsy(output:find("OUTDATED-RUN-SNAPSHOT", 1, true))
    end
  )
  it(
    "keeps a task running when its float is dismissed immediately or during live output",
    function()
      local script, gate = root .. "/hidden.sh", root .. "/release-hidden"
      vim.fn.writefile({
        "echo BACKGROUND-START",
        'while [ ! -e "$1" ]; do sleep 0.02; done',
        "echo BACKGROUND-DONE",
      }, script)
      state.config.build.commands = { { "bash", script, gate } }
      panel_key("w")
      panel_key("C")
      panel_key("<Esc>")
      assert.is_true(vim.wait(3000, function()
        return table.concat(state.logs, "\n"):find("BACKGROUND-START", 1, true) ~= nil
      end, 10))
      assert.is_true(state.task:is_running())
      assert.are.equal(1, #vim.api.nvim_tabpage_list_wins(0))
      assert.are.equal(source, vim.api.nvim_get_current_win())
      experiment.toggle()
      panel_key("3")
      assert.is_truthy(
        table
          .concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
          :find("BACKGROUND-START", 1, true)
      )
      panel_key("q")
      vim.fn.writefile({}, gate)
      assert.is_true(vim.wait(3000, function()
        return state.task:is_complete()
      end, 10))
      settle()
      assert.are.equal(overseer.STATUS.SUCCESS, state.task.status)
      assert.are.equal(1, #vim.api.nvim_tabpage_list_wins(0))
      experiment.toggle()
      panel_key("3")
      assert.is_truthy(
        table
          .concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
          :find("BACKGROUND-DONE", 1, true)
      )
    end
  )

  it("resizes and recenters its float with the editor", function()
    local columns, lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 100, 32
    vim.api.nvim_exec_autocmds("VimResized", {})
    local resized = vim.api.nvim_win_get_config(state.win)
    vim.o.columns, vim.o.lines = columns, lines
    vim.api.nvim_exec_autocmds("VimResized", {})
    assert.are.equal(85, resized.width)
    assert.are.equal(math.floor((32 - vim.o.cmdheight) * 0.85), resized.height)
    assert.are.equal(math.floor((100 - resized.width - 2) / 2), resized.col)
    assert.are.equal(math.floor((32 - vim.o.cmdheight - resized.height - 2) / 2), resized.row)
  end)

  it("reuses one float when switching projects in the same tab", function()
    local project = root .. "/another-project"
    vim.fn.mkdir(project .. "/.overseer", "p")
    local config = vim.deepcopy(state.config)
    config.name = "Another experiment"
    vim.fn.writefile({ vim.json.encode(config) }, project .. "/.overseer/experiment.json")
    local win = state.win
    local another = experiment.open(project, true)
    assert.are.equal(win, another.win)
    assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
    assert.are.equal(another.buf, vim.api.nvim_win_get_buf(win))
    assert.are.equal(project, vim.b[another.buf].overseer_project)
    experiment.open(root, true)
    assert.are.equal(win, state.win)
    assert.are.equal(state.buf, vim.api.nvim_win_get_buf(win))
    assert.are.equal(source_buf, vim.api.nvim_win_get_buf(source))
  end)
  it("keeps panel windows separate across tabs and closes only the current tab's float", function()
    local first = state.win
    vim.cmd.tabnew()
    local another_source = vim.api.nvim_get_current_win()
    experiment.open(root, true)
    local second = state.win
    assert.is_not.equal(first, second)
    assert.are.equal("editor", vim.api.nvim_win_get_config(second).relative)
    experiment.toggle()
    assert.is_true(vim.api.nvim_win_is_valid(first))
    assert.is_false(vim.api.nvim_win_is_valid(second))
    assert.are.equal(another_source, vim.api.nvim_get_current_win())
    vim.cmd.tabclose()
    experiment.open(root, true)
    assert.are.equal(first, state.win)
  end)

  it("closes the float when editing JSON in the original source window", function()
    panel_key("e")
    assert.are.equal(source, vim.api.nvim_get_current_win())
    assert.are.equal(state.file, vim.api.nvim_buf_get_name(0))
    assert.are.equal(1, #vim.api.nvim_tabpage_list_wins(0))
  end)
  it("opens the failing configure output in a float after the panel was closed", function()
    local script, gate = root .. "/fail.sh", root .. "/release-failure"
    vim.fn.writefile({
      "echo CONFIGURE-START",
      'while [ ! -e "$1" ]; do sleep 0.02; done',
      "echo CONFIGURE-FAILED >&2",
      "exit 1",
    }, script)
    state.config.build.commands = { { "bash", script, gate } }
    panel_key("w")
    panel_key("C")
    assert.is_true(vim.wait(3000, function()
      return table.concat(state.logs, "\n"):find("CONFIGURE-START", 1, true) ~= nil
    end, 10))
    panel_key("<Esc>")
    vim.fn.writefile({}, gate)
    assert.is_true(vim.wait(3000, function()
      return state.task:is_complete()
        and vim.api.nvim_win_is_valid(state.win)
        and vim.api.nvim_get_current_buf() == state.buf
    end, 10))
    assert.are.equal(overseer.STATUS.FAILURE, state.task.status)
    assert.are.equal("logs", state.view)
    assert.are.equal("editor", vim.api.nvim_win_get_config(state.win).relative)
    assert.is_truthy(
      table
        .concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
        :find("CONFIGURE-FAILED", 1, true)
    )
    assert.are.equal(source_buf, vim.api.nvim_win_get_buf(source))
    assert.are.same(
      source_size,
      { vim.api.nvim_win_get_width(source), vim.api.nvim_win_get_height(source) }
    )
  end)
  it("renders multiline background config errors as separate log lines", function()
    local response
    vim.system = function(argv, opts, callback)
      if argv[3] == "describe" then
        response = callback
        return {}
      end
      return system(argv, opts, callback)
    end
    panel_key("3")
    experiment.open(root, true)
    vim.system = system
    response({ code = 1, stdout = "first error\nsecond error\n", stderr = "extra detail\n" })
    assert.is_true(vim.wait(3000, function()
      return state.status == "CONFIG ERROR"
    end, 10))
    local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
    assert.is_true(vim.tbl_contains(lines, "first error"))
    assert.is_true(vim.tbl_contains(lines, "second error"))
    assert.is_true(vim.tbl_contains(lines, "extra detail"))
    assert.is_false(vim.bo[state.buf].modifiable)
  end)
end)
