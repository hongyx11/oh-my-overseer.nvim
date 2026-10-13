local config = require("overseer.config")
local experiment = require("overseer.experiment")
local overseer = require("overseer")
vim.opt.rtp:append(vim.fn.getcwd())

describe("experiment panel", function()
  local cwd, root, source, source_buf, state, notify, system, source_size, ui_select, ui_input
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
  local function panel_option(id)
    for row, item in pairs(state.rows) do
      if item.kind == "parameter" and item.id == id then
        vim.api.nvim_win_set_cursor(state.win, { row, 0 })
        panel_key("<CR>")
        return
      end
    end
    error("Missing option row: " .. id)
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
  local function row_for(id)
    for row, item in pairs(state.rows) do
      if item.kind == "parameter" and item.id == id then
        vim.api.nvim_set_current_win(state.win)
        vim.api.nvim_win_set_cursor(state.win, { row, 0 })
        return item.index
      end
    end
    error("Missing option row " .. id)
  end
  local function dialogs(inputs, selections)
    vim.ui.input = function(_, callback)
      callback(table.remove(inputs, 1))
    end
    vim.ui.select = function(items, opts, callback)
      local answer = table.remove(selections, 1)
      for index, item in ipairs(items) do
        local label = opts.format_item and opts.format_item(item) or tostring(item)
        if label == answer then
          callback(item, index)
          return
        end
      end
      error("Missing dialog selection: " .. tostring(answer))
    end
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
      version = 2,
      name = "Panel test",
      project = "..",
      preset = "",
      target = "",
      binary = "probe.sh",
      args = { "${dataset}", "${threads}", "${method}", "${result}" },
      parameters = {
        {
          id = "dataset",
          label = "Datasets",
          source = { directory = "dataset/output", pattern = "*.mtx" },
          choices = {
            { id = "d1", path = "dataset/output/d1.mtx" },
            { id = "d2", path = "dataset/output/d2.mtx" },
          },
          selected = { "d1" },
        },
        {
          id = "threads",
          choices = { 1, 2, 4 },
          selected = { 1, 2 },
          requirements = { cpus = "${value}" },
        },
        {
          id = "method",
          choices = {
            { id = "a", value = "algorithm-a" },
            { id = "b", value = "algorithm-b" },
            { id = "c", value = "algorithm-c" },
          },
          selected = { "a" },
        },
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
    ui_select, ui_input = vim.ui.select, vim.ui.input
    vim.notify = function() end
    overseer.setup({
      dap = false,
      results = { enabled = true },
      cmake = { enabled = false },
      experiment = { library = root .. "/option-library.json" },
    })
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
    vim.ui.select, vim.ui.input = ui_select, ui_input
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
    panel_option("dataset")
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
      return #state.config.parameters[1].selected == 2
    end, 10))
    assert.are.same({ "d1", "d2" }, state.config.parameters[1].selected)
    local saved = require("overseer.files").load_json_file(state.file)
    assert.are.same({ "d1", "d2" }, saved.parameters[1].selected)
  end)

  it("selects all methods by stable IDs rather than their command-line values", function()
    panel_option("method")
    local current = picker()
    vim.fn.maparg("<C-a>", "i", false, true).callback()
    settle()
    require("telescope.actions").select_default(current.prompt_bufnr)
    assert.is_true(vim.wait(3000, function()
      return #state.config.parameters[3].selected == 3
    end, 10))
    assert.are.same({ "a", "b", "c" }, state.config.parameters[3].selected)
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
    assert.are.same({ "a" }, snapshot.parameters[3].selected)
    state.config.parameters[3].selected = { "b" }
    panel_key("w")
    assert.are.same(
      { "a" },
      require("overseer.files").load_json_file(state.task.metadata.experiment_config).parameters[3].selected
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
      require("overseer.files").load_json_file(state.folder .. "/experiment.json").parameters[3].selected
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
  it("creates named experiments and reuses a shared option with independent selections", function()
    local original = state.file
    dialogs({ "SpGEMM study" }, { "Start empty" })
    panel_key("N")
    state = experiment.open(root, true)
    assert.is_not.equal(original, state.file)
    assert.are.equal("SpGEMM study", state.config.name)
    assert.are.equal(0, #state.config.parameters)
    dialogs({}, { "Threads", "development" })
    panel_key("a")
    assert.are.equal("threads", state.config.parameters[1].template)
    assert.are.same({ 1, 2, 4 }, state.resolved.parameters[1].selected)
    local first = state.file
    dialogs({ "SpMV study" }, { "Copy current settings" })
    panel_key("N")
    state = experiment.open(root, true)
    assert.is_not.equal(first, state.file)
    assert.are.equal("threads", state.config.parameters[1].template)
    vim.ui.select, vim.ui.input = ui_select, ui_input
    panel_option("threads")
    local current = picker()
    vim.fn.maparg("<C-u>", "i", false, true).callback()
    current:set_prompt("4")
    assert.is_true(vim.wait(3000, function()
      local entry = require("telescope.actions.state").get_selected_entry()
      return entry and entry.value.id == "4"
    end, 10))
    vim.fn.maparg("<Tab>", "i", false, true).callback()
    settle()
    require("telescope.actions").select_default(current.prompt_bufnr)
    assert.is_true(vim.wait(3000, function()
      return state.config.parameters[1].selected ~= nil
    end, 10))
    assert.are.same({ "4" }, state.config.parameters[1].selected)
    local saved = require("overseer.experiment_store").read(first)
    assert.are.equal("development", saved.parameters[1].preset)
    assert.is_nil(saved.parameters[1].selected)
    dialogs({}, { "SpGEMM study" })
    panel_key("O")
    state = experiment.open(root, true)
    assert.are.equal(first, state.file)
    assert.are.same({ 1, 2, 4 }, state.resolved.parameters[1].selected)
    assert.are.equal(first, require("overseer.experiment_store").active(root))
  end)

  it("creates an arbitrary flag option from dialogs and edits it by its row", function()
    dialogs(
      { "Block size", "8,16,32", "--block-size" },
      { "Create a new option…", "Append a command-line flag" }
    )
    panel_key("a")
    local option = state.config.parameters[4]
    assert.are.equal("block_size", option.id)
    assert.are.same({ 8, 16, 32 }, option.choices)
    assert.are.same({ "--block-size", "${value}" }, option.args)
    assert.are.same({ "8", "16", "32" }, option.selected)
    vim.ui.select, vim.ui.input = ui_select, ui_input
    row_for("block_size")
    panel_key("m")
    assert.is_truthy(picker().prompt_title:find("Block size", 1, true))
    require("telescope.actions").close(vim.api.nvim_get_current_buf())
    assert.is_nil(next(vim.fn.maparg("d", "n", false, true)))
    assert.is_nil(next(vim.fn.maparg("t", "n", false, true)))
  end)

  it("adds the reserved Slurm node option and chooses its saved preset", function()
    dialogs({}, { "Slurm nodes", "scaling" })
    panel_key("a")
    assert.are.equal("nodes", state.config.parameters[4].id)
    assert.are.equal("nodes", state.config.parameters[4].template)
    assert.are.same({ 2, 4, 16 }, state.resolved.parameters[4].selected)
    assert.are.same({ nodes = "${value}" }, state.resolved.parameters[4].slurm)
    row_for("nodes")
    dialogs({}, { "Choose selection preset", "small" })
    panel_key("s")
    assert.are.same({ 2 }, state.resolved.parameters[4].selected)
  end)

  it("saves a shared selection preset without replacing experiment-specific bindings", function()
    state.config.parameters[2] =
      { id = "threads", template = "threads", args = {}, selected = { 1, 4 } }
    panel_key("w")
    panel_key("R")
    row_for("threads")
    dialogs({ "my-laptop" }, { "Save selection as preset" })
    panel_key("s")
    local library = require("overseer.experiment_store").library()
    assert.are.same({ 1, 4 }, library.options.threads.presets["my-laptop"])
    assert.are.same({ "--threads", "${value}" }, library.options.threads.args)
    assert.are.same({}, state.resolved.parameters[2].args)
    assert.are.equal("my-laptop", state.config.parameters[2].preset)
  end)

  it("publishes a custom option so it can be attached to another experiment", function()
    dialogs(
      { "Tile size", "8,16" },
      { "Create a new option…", "Use a placeholder in experiment arguments" }
    )
    panel_key("a")
    row_for("tile_size")
    dialogs({ "tile_sizes" }, { "Save option to shared library" })
    panel_key("s")
    assert.are.equal("tile_sizes", state.config.parameters[4].template)
    dialogs({ "Another kernel" }, { "Start empty" })
    panel_key("N")
    state = experiment.open(root, true)
    dialogs({}, { "Tile size", "All choices" })
    panel_key("a")
    assert.are.equal("tile_sizes", state.config.parameters[1].template)
    assert.are.same(
      { 8, 16 },
      vim.tbl_map(function(choice)
        return choice.value
      end, state.resolved.parameters[1].choices)
    )
  end)
  it("round-trips stored strings and retains experiment selection when recording jobs", function()
    local store = require("overseer.experiment_store")
    local value = {
      text = 'quoted "text" with \\ slash and\nnewline {braces} · UTF-8',
      list = { "a", "b" },
      empty = vim.empty_dict(),
    }
    local file = root .. "/strings.json"
    store.write(file, value)
    assert.are.same(value, store.read(file))
    store.activate(root, state.file)
    store.record_jobs(root, state.file, root .. "/submitted")
    assert.are.equal(state.file, store.active(root))
    assert.are.equal(root .. "/submitted", store.session(root, state.file).jobs_folder)
    local another = store.create(root, "Another", state.config)
    store.record_jobs(root, state.file, root .. "/more-jobs")
    assert.are.equal(another, store.active(root))
    assert.are.equal(root .. "/more-jobs", store.session(root, state.file).jobs_folder)
    store.activate(root, state.file)
  end)
  it("edits program arguments with quoting and preserves placeholders", function()
    dialogs({ '--label "two words" --count ${threads}' }, {})
    for row, item in pairs(state.rows) do
      if item.kind == "arguments" then
        vim.api.nvim_win_set_cursor(state.win, { row, 0 })
      end
    end
    panel_key("m")
    assert.are.same({ "--label", "two words", "--count", "${threads}" }, state.config.args)
  end)

  it("keeps a previous experiment's live output separate after switching configurations", function()
    local gate, script = root .. "/release-old", root .. "/old.sh"
    vim.fn.writefile({
      "echo BEFORE-SWITCH",
      'while [ ! -e "$1" ]; do sleep 0.02; done',
      "echo AFTER-SWITCH",
    }, script)
    state.config.build.commands = { { "bash", script, gate } }
    panel_key("w")
    panel_key("C")
    local previous = state
    assert.is_true(vim.wait(3000, function()
      return table.concat(previous.logs, "\n"):find("BEFORE-SWITCH", 1, true) ~= nil
    end, 10))
    dialogs({ "New study" }, { "Copy current settings" })
    panel_key("N")
    state = experiment.open(root, true)
    assert.is_not.equal(previous.file, state.file)
    panel_key("3")
    vim.fn.writefile({}, gate)
    assert.is_true(vim.wait(3000, function()
      return previous.task:is_complete()
    end, 10))
    settle()
    assert.are.equal("New study", state.config.name)
    assert.is_truthy(table.concat(previous.logs, "\n"):find("AFTER-SWITCH", 1, true))
    assert.is_falsy(
      table
        .concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
        :find("AFTER-SWITCH", 1, true)
    )
  end)
  it(
    "makes editable option labels, selected values, and choice counts visible with semantic highlights",
    function()
      row_for("threads")
      local row = vim.api.nvim_win_get_cursor(state.win)[1] - 1
      local line = vim.api.nvim_buf_get_lines(state.buf, row, row + 1, false)[1]
      assert.is_truthy(line:find("[2/3 selected]", 1, true))
      local groups = {}
      for _, mark in
        ipairs(vim.api.nvim_buf_get_extmarks(state.buf, state.ns, 0, -1, { details = true }))
      do
        if mark[2] == row then
          groups[mark[4].hl_group] = true
        end
      end
      assert.is_true(groups.OverseerExperimentLabel)
      assert.is_true(groups.OverseerExperimentValue)
      assert.is_true(groups.OverseerExperimentNumber)
      assert.is_true(groups.OverseerExperimentMuted)
      local original = vim.api.nvim_get_hl(0, { name = "Identifier", link = true })
      vim.api.nvim_set_hl(0, "Identifier", { fg = 0x13579b })
      local linked = vim.api.nvim_get_hl(0, { name = "OverseerExperimentLabel", link = false })
      vim.api.nvim_set_hl(0, "Identifier", original)
      assert.are.equal(0x13579b, linked.fg)
    end
  )

  it("distinguishes errors, warnings, and configure completion in the live log view", function()
    state.logs = {
      "CMake Error: missing dependency",
      "file.cpp:9: warning: unused variable",
      "-- Configuring done",
    }
    panel_key("3")
    local highlights = {}
    local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
    for _, mark in
      ipairs(vim.api.nvim_buf_get_extmarks(state.buf, state.ns, 0, -1, { details = true }))
    do
      highlights[lines[mark[2] + 1]] = mark[4].hl_group
    end
    assert.are.equal("OverseerExperimentError", highlights[state.logs[1]])
    assert.are.equal("OverseerExperimentWarning", highlights[state.logs[2]])
    assert.are.equal("OverseerExperimentSuccess", highlights[state.logs[3]])
  end)
end)
