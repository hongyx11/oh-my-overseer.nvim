local config = require("overseer.config")
vim.opt.rtp:append(vim.fn.getcwd())
local overseer = require("overseer")
local results = require("overseer.results")

describe("results interface", function()
  local cwd, root, source, source_buf, notify, notifications, tasks
  local function settle()
    vim.wait(50, function()
      return false
    end, 5)
  end
  local function make(name, extra)
    local task = overseer.new_task(vim.tbl_extend("force", {
      name = name,
      cmd = "test",
      cwd = root,
      strategy = "test",
    }, extra or {}))
    table.insert(tasks, task)
    return task
  end
  before_each(function()
    cwd = vim.fn.getcwd()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.cmd.cd(root)
    source = vim.api.nvim_get_current_win()
    source_buf = vim.api.nvim_get_current_buf()
    tasks, notifications = {}, {}
    notify = vim.notify
    vim.notify = function(message)
      table.insert(notifications, message)
    end
    overseer.setup({ dap = false, results = { enabled = true }, cmake = { enabled = false } })
  end)
  after_each(function()
    -- The test strategy stores its task only on start; skipped children never start.
    for _, task in ipairs(overseer.list_tasks({ include_ephemeral = true })) do
      if task.strategy.name == "test" and not task.strategy.task then
        task.strategy.task = task
      end
    end
    for _, task in ipairs(tasks) do
      task:dispose(true)
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

  it("keeps successful configure output hidden and sends one completion message", function()
    local task =
      make("Configure", { components = { "default", { "open_output", on_start = "always" } } })
    task:start()
    task.strategy:send_output("Configured")
    task.strategy:send_exit(0)
    settle()
    assert.are.equal(1, #vim.api.nvim_tabpage_list_wins(0))
    assert.are.same({ "Configure succeeded" }, notifications)
    assert.is_false(task:has_component("open_output"))
    assert.is_false(task:has_component("on_complete_dispose"))
  end)

  it(
    "shows live Run output on the right without stealing source focus and reuses the window",
    function()
      local task = make("Run")
      task:start()
      settle()
      local output
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if win ~= source then
          output = win
        end
      end
      assert.are.equal(source, vim.api.nvim_get_current_win())
      assert.are.equal(source_buf, vim.api.nvim_win_get_buf(source))
      assert.are.equal(task:get_bufnr(), vim.api.nvim_win_get_buf(output))
      assert.are.equal(vim.api.nvim_win_get_height(source), vim.api.nvim_win_get_height(output))
      assert.is_true(
        vim.api.nvim_win_get_position(output)[2] > vim.api.nvim_win_get_position(source)[2]
      )
      task.strategy:send_output({ "first", "second", "third", "fourth" })
      settle()
      assert.are.equal(
        vim.api.nvim_buf_line_count(task:get_bufnr()),
        vim.api.nvim_win_get_cursor(output)[1]
      )
      task.strategy:send_exit(0)
      settle()
      local next_task = make("Run")
      next_task:start()
      settle()
      assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
      assert.are.equal(next_task:get_bufnr(), vim.api.nvim_win_get_buf(output))
      vim.api.nvim_set_current_win(output)
      vim.cmd.quit()
      assert.is_true(vim.api.nvim_win_is_valid(source))
      results.toggle()
      assert.are.equal(next_task:get_bufnr(), vim.api.nvim_get_current_buf())
    end
  )

  for _, failed_step in ipairs({ 1, 2, 3 }) do
    it("shows the failed child once at workflow stage " .. failed_step, function()
      local children = {}
      for _, name in ipairs({ "Configure", "Build", "Run" }) do
        table.insert(children, { name = name, cmd = "test", strategy = "test", cwd = root })
      end
      local parent =
        make("Configure, build and run", { strategy = { "orchestrator", tasks = children } })
      parent:start()
      for step = 1, failed_step do
        local child
        for _, candidate in ipairs(overseer.list_tasks({ include_ephemeral = true })) do
          if candidate.parent_id == parent.id and candidate.name == children[step].name then
            child = candidate
          end
        end
        assert.is_not_nil(child)
        child.strategy:send_output("output from " .. child.name)
        child.strategy:send_exit(step == failed_step and 2 or 0)
      end
      settle()
      assert.are.equal(overseer.STATUS.FAILURE, parent.status)
      assert.are.equal(1, #notifications)
      assert.is_truthy(notifications[1]:find(children[failed_step].name .. " failed", 1, true))
      local current_buf = vim.api.nvim_get_current_buf()
      assert.is_truthy(
        table
          .concat(vim.api.nvim_buf_get_lines(current_buf, 0, -1, false), "\n")
          :find("output from " .. children[failed_step].name, 1, true)
      )
      assert.are.equal(source_buf, vim.api.nvim_win_get_buf(source))
      assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
      for _, candidate in ipairs(overseer.list_tasks({ include_ephemeral = true })) do
        if
          children[failed_step + 1]
          and candidate.parent_id == parent.id
          and candidate.name == children[failed_step + 1].name
        then
          assert.is_false(candidate:is_running())
        end
      end
    end)
  end

  it("archives output before restart so history keeps earlier logs", function()
    local task = make("Configure")
    task:start()
    task.strategy:send_output("old output")
    task.strategy:send_exit(0)
    settle()
    task:restart()
    task.strategy:send_output("new output")
    task.strategy:send_exit(0)
    settle()
    local select = vim.ui.select
    local calls = 0
    vim.ui.select = function(items, _, callback)
      calls = calls + 1
      callback(calls == 1 and items[2] or items[1])
    end
    results.history()
    vim.ui.select = select
    assert.is_truthy(
      table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("old output", 1, true)
    )
    assert.is_falsy(
      table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("new output", 1, true)
    )
  end)

  it("keeps the latest workflow visible when an older workflow fails", function()
    local older = make("Run")
    older:start()
    settle()
    local newer = make("Run")
    newer:start()
    settle()
    older.strategy:send_output("old failure")
    older.strategy:send_exit(1)
    settle()
    assert.are.equal(source, vim.api.nvim_get_current_win())
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if win ~= source then
        assert.are.equal(newer:get_bufnr(), vim.api.nvim_win_get_buf(win))
      end
    end
  end)

  it("limits completed history and releases old task resources", function()
    config.setup({ results = { enabled = true, history_limit = 2 } })
    for _ = 1, 3 do
      local task = make("Configure")
      task:start()
      task.strategy:send_exit(0)
      settle()
    end
    local select = vim.ui.select
    local count
    vim.ui.select = function(items)
      count = #items
    end
    results.history()
    vim.ui.select = select
    assert.are.equal(2, count)
    assert.is_true(tasks[1]:is_disposed())
  end)

  it("does not switch tabs or open results in another tab on failure", function()
    local task = make("Configure")
    task:start()
    vim.cmd.tabnew()
    local other = vim.api.nvim_get_current_tabpage()
    task.strategy:send_exit(1)
    settle()
    assert.are.equal(other, vim.api.nvim_get_current_tabpage())
    assert.are.equal(1, #vim.api.nvim_tabpage_list_wins(0))
    vim.cmd.tabclose()
  end)

  it("retains an unseen failure even when earlier live output was viewed", function()
    config.setup({ results = { enabled = true, history_limit = 2 } })
    local failed = make("Run")
    failed:start()
    settle()
    results.toggle()
    vim.cmd.tabnew()
    failed.strategy:send_exit(1)
    settle()
    vim.cmd.tabclose()
    for _ = 1, 3 do
      local task = make("Configure")
      task:start()
      task.strategy:send_exit(0)
      settle()
    end
    assert.is_false(failed:is_disposed())
    local select = vim.ui.select
    local count
    vim.ui.select = function(items)
      count = #items
    end
    results.history()
    vim.ui.select = select
    assert.are.equal(3, count)
  end)

  it("waits for a floating picker to close before showing a failure", function()
    local task = make("Configure")
    task:start()
    local buf = vim.api.nvim_create_buf(false, true)
    local float = vim.api.nvim_open_win(
      buf,
      true,
      { relative = "editor", row = 2, col = 4, width = 20, height = 3, style = "minimal" }
    )
    task.strategy:send_exit(1)
    settle()
    assert.are.equal(float, vim.api.nvim_get_current_win())
    assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
    vim.api.nvim_win_close(float, true)
    settle()
    assert.are.equal(task:get_bufnr(), vim.api.nvim_get_current_buf())
    assert.are.equal(source_buf, vim.api.nvim_win_get_buf(source))
  end)

  it("reports an executable startup failure instead of leaving the workflow running", function()
    local parent = make("Workflow", {
      strategy = {
        "orchestrator",
        tasks = {
          {
            name = "Run",
            cmd = { root .. "/missing-program" },
            cwd = root,
            strategy = { "jobstart", use_terminal = false },
          },
        },
      },
    })
    parent:start()
    settle()
    assert.are.equal(overseer.STATUS.FAILURE, parent.status)
    assert.are.equal(1, #notifications)
    assert.is_truthy(notifications[1]:find("Run failed", 1, true))
    assert.is_truthy(
      table
        .concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
        :find("Could not start Run", 1, true)
    )
    assert.are.equal(source_buf, vim.api.nvim_win_get_buf(source))
  end)
end)
