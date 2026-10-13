local experiment = require("overseer.experiment")
local manager = require("overseer.experiment_manager")
local progress = require("overseer.experiment_progress")
local store = require("overseer.experiment_store")

describe("parallel experiment manager", function()
  local root, files, panel, source, tasks, input, select
  local function await(predicate)
    local ok = vim.wait(5000, predicate, 10)
    if not ok then
      for _, state in ipairs(tasks) do
        print(vim.inspect({
          status = state.status,
          logs = state.logs,
          progress = progress.get(root, state.file),
        }))
      end
    end
    assert.is_true(ok)
  end
  before_each(function()
    source = vim.api.nvim_get_current_win()
    root = vim.fn.tempname()
    tasks, files = {}, {}
    vim.fn.mkdir(root, "p")
    local base = {
      version = 2,
      binary = "/bin/sleep",
      args = { "0.6" },
      parameters = {},
      servers = {
        choices = { { id = "local", kind = "local" }, { id = "alternate", kind = "local" } },
        selected = { "local" },
      },
      build = { commands = {}, before_run = false },
      output_dir = "results",
    }
    files[1] = store.create(root, "Experiment A", base)
    files[2] = store.create(root, "Experiment B", base)
    input, select = vim.ui.input, vim.ui.select
  end)
  after_each(function()
    vim.ui.input, vim.ui.select = input, select
    if panel and vim.api.nvim_win_is_valid(panel.win) then
      vim.api.nvim_win_close(panel.win, true)
    end
    for _, state in ipairs(tasks) do
      if state.task and state.task:is_running() then
        experiment.execute_file(root, state.file, "cancel")
      end
    end
    vim.wait(1000, function()
      for _, state in ipairs(tasks) do
        if state.task and state.task:is_running() then
          return false
        end
      end
      return true
    end, 10)
    if vim.api.nvim_win_is_valid(source) then
      vim.api.nvim_set_current_win(source)
    end
    vim.fn.delete(root, "rf")
  end)

  it("runs two experiments concurrently and renders independent stage status", function()
    panel = manager.toggle(root)
    for _, file in ipairs(files) do
      table.insert(tasks, experiment.execute_file(root, file, "run"))
    end
    await(function()
      return progress.stage(progress.get(root, files[1]), "run") == "RUNNING"
        and progress.stage(progress.get(root, files[2]), "run") == "RUNNING"
    end)
    assert.is_true(tasks[1].task:is_running())
    assert.is_true(tasks[2].task:is_running())
    local text = table.concat(vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false), "\n")
    assert.is_truthy(text:find("Experiment A", 1, true))
    assert.is_truthy(text:find("Experiment B", 1, true))
    assert.is_truthy(text:find("↻ Run", 1, true))
    await(function()
      return progress.stage(progress.get(root, files[1]), "run") == "SUCCESS"
        and progress.stage(progress.get(root, files[2]), "run") == "SUCCESS"
    end)
    assert.equals("SUCCESS", store.session(root, files[1]).progress.allocations["local"].stages.run)
    assert.equals("SUCCESS", store.session(root, files[2]).progress.allocations["local"].stages.run)
  end)

  it("cancels one experiment and records the canceled run stage", function()
    local config = store.read(files[1])
    config.args = { "5" }
    store.write(files[1], config)
    panel = manager.toggle(root)
    tasks[1] = experiment.execute_file(root, files[1], "run")
    await(function()
      return progress.stage(progress.get(root, files[1]), "run") == "RUNNING"
    end)
    tasks[1] = experiment.execute_file(root, files[1], "cancel")
    await(function()
      return not tasks[1].task:is_running()
    end)
    local value = progress.get(root, files[1])
    assert.equals("CANCELED", progress.stage(value, "run"))
    assert.equals("CANCELED", value.status)
  end)

  it("clones options onto another server without copying execution handles", function()
    local config = store.read(files[1])
    config.experiment_id = "old-identity"
    store.write(files[1], config)
    store.record_session(root, files[1], root .. "/old-job", "submit")
    panel = manager.toggle(root)
    vim.ui.input = function(_, callback)
      callback("Experiment C")
    end
    vim.ui.select = function(items, _, callback)
      callback(items[2])
    end
    vim.api.nvim_win_set_cursor(panel.win, { 3, 0 })
    vim.fn.maparg("c", "n", false, true).callback()
    local copied = store.list(root)[3].file
    assert.same({ "alternate" }, store.read(copied).servers.selected)
    assert.is_nil(store.read(copied).experiment_id)
    assert.is_nil(store.session(root, copied).folder)
    assert.same({}, progress.get(root, copied).allocations)
    assert.same({ "local" }, store.read(files[1]).servers.selected)
  end)

  it("automatically monitors batch submission while another experiment runs", function()
    local config = store.read(files[1])
    local bin = root .. "/scheduler"
    vim.fn.mkdir(bin, "p")
    local fixture = vim.fn.getcwd() .. "/tests/fake_slurm.py"
    for _, name in ipairs({ "sbatch", "srun", "squeue", "sacct", "scancel" }) do
      vim.fn.writefile(vim.fn.readfile(fixture), bin .. "/" .. name)
      assert(vim.uv.fs_chmod(bin .. "/" .. name, 493))
    end
    config.servers.choices[1].slurm = { cpus_per_task = 1 }
    config.servers.choices[1].setup = {
      "export PATH=" .. vim.fn.shellescape(bin) .. ":$PATH",
      "export OMO_FAKE_SLURM=" .. vim.fn.shellescape(bin .. "/state"),
    }
    store.write(files[1], config)
    panel = manager.toggle(root)
    tasks[1] = experiment.execute_file(root, files[1], "submit")
    await(function()
      return tasks[1].task.metadata.experiment_mode == "reconnect" and tasks[1].task:is_running()
    end)
    -- Simulate an editor restart: detach the old observer and discard its UI states.
    tasks[1].generation = tasks[1].generation + 1
    tasks[1].task:stop()
    await(function()
      return not tasks[1].task:is_running()
    end)
    package.loaded["overseer.experiment"] = nil
    experiment = require("overseer.experiment")
    tasks[1] = experiment.watch_file(root, files[1])
    assert.equals("reconnect", tasks[1].task.metadata.experiment_mode)
    local receipt = store.read(tasks[1].session_folder .. "/session.json")
    local entry = receipt.entries[1]
    local job = entry.state.job_id
    tasks[2] = experiment.execute_file(root, files[2], "run")
    assert.is_true(tasks[2].task:is_running())
    -- Finish the scheduler job and publish its real stage/trial output.
    local output = root .. "/.omo/jobs/" .. entry.job .. "/output.log"
    local result = vim
      .system(
        { "bash", "-c", "(\n" .. entry.request.script .. "\n) >> " .. vim.fn.shellescape(output) },
        { cwd = root }
      )
      :wait()
    assert.equals(0, result.code)
    vim.fn.writefile({ "COMPLETED" }, bin .. "/state/" .. job .. ".state")
    await(function()
      return not tasks[1].task:is_running()
        and progress.stage(progress.get(root, files[1]), "run") == "SUCCESS"
    end)
    assert.equals(
      job,
      store.read(tasks[1].session_folder .. "/session.json").entries[1].state.job_id
    )
    local submitted = 0
    for _, line in ipairs(vim.fn.readfile(bin .. "/state/calls.jsonl")) do
      if vim.json.decode(line).argv[1] == "sbatch" then
        submitted = submitted + 1
      end
    end
    assert.equals(1, submitted)
  end)

  it("marks only the failed stage and leaves later stages unstarted", function()
    progress.event(root, files[1], {
      event = "stage",
      allocation = "local",
      server = "local",
      stage = "resources",
      status = "SUCCESS",
    })
    local config = store.read(files[1])
    config.build.before_run = true
    progress.begin(root, files[1], "run", config)
    progress.event(root, files[1], {
      event = "stage",
      allocation = "local",
      server = "local",
      stage = "resources",
      status = "SUCCESS",
    })
    progress.event(root, files[1], {
      event = "stage",
      allocation = "local",
      server = "local",
      stage = "configure",
      status = "FAILURE",
    })
    progress.event(root, files[1], {
      event = "remote_job",
      allocation = "local",
      server = "local",
      status = "FAILURE",
      terminal = true,
    })
    local value = progress.get(root, files[1])
    assert.equals("SUCCESS", progress.stage(value, "resources"))
    assert.equals("FAILURE", progress.stage(value, "configure"))
    assert.equals("NONE", progress.stage(value, "build"))
    assert.equals("NONE", progress.stage(value, "run"))
  end)

  it("removes obsolete resource groups when a new session starts", function()
    progress.event(root, files[1], {
      event = "stage",
      allocation = "local--002",
      server = "local",
      stage = "build",
      status = "FAILURE",
    })
    progress.event(root, files[1], {
      event = "session",
      allocations = {
        { id = "local", server = "local", stages = { "resources", "configure", "build", "run" } },
      },
    })
    local value = progress.get(root, files[1])
    assert.is_nil(value.allocations["local--002"])
    assert.equals("PENDING", progress.stage(value, "build"))
  end)

  it("aggregates failed and queued resource groups and preserves journal on reload", function()
    progress.event(
      root,
      files[1],
      { event = "stage", allocation = "a", server = "local", stage = "build", status = "FAILURE" }
    )
    progress.event(root, files[1], {
      event = "stage",
      allocation = "b",
      server = "alternate",
      stage = "build",
      status = "SUCCESS",
    })
    progress.event(root, files[1], {
      event = "stage",
      allocation = "b",
      server = "alternate",
      stage = "resources",
      status = "PENDING",
    })
    assert.equals("FAILURE", progress.stage(progress.get(root, files[1]), "build"))
    assert.equals("PENDING", progress.stage(progress.get(root, files[1]), "resources"))
    package.loaded["overseer.experiment_progress"] = nil
    local restored = require("overseer.experiment_progress")
    assert.equals("FAILURE", restored.stage(restored.get(root, files[1]), "build"))
    assert.equals("PENDING", restored.stage(restored.get(root, files[1]), "resources"))
    package.loaded["overseer.experiment_progress"] = progress
  end)
end)
