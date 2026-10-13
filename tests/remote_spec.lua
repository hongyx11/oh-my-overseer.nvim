local remote = require("overseer.remote")

describe("saved source publication", function()
  local root, buf, system, notify, calls
  local function settle(milliseconds)
    vim.wait(milliseconds, function()
      return false
    end, 5)
  end
  local function save_event()
    vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf })
  end
  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/.overseer", "p")
    vim.fn.writefile(
      { vim.json.encode({ version = 2, sync = { on_save = true } }) },
      root .. "/.overseer/experiment.json"
    )
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = ""
    vim.api.nvim_buf_set_name(buf, root .. "/source.txt")
    system, notify, calls = vim.system, vim.notify, {}
    vim.notify = function() end
    vim.system = function(argv, opts, callback)
      table.insert(calls, { argv = argv, opts = opts, complete = callback })
      return {}
    end
    remote.setup()
  end)
  after_each(function()
    for _, call in ipairs(calls) do
      if call.complete then
        call.complete({ code = 0, stdout = "", stderr = "" })
        call.complete = nil
      end
    end
    settle(20)
    vim.system, vim.notify = system, notify
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(root, "rf")
  end)
  it("coalesces saves and only invokes the source synchronization operation", function()
    save_event()
    save_event()
    save_event()
    settle(350)
    assert.are.equal(1, #calls)
    assert.are.equal("sync", calls[1].argv[3])
    assert.are.equal(root, calls[1].opts.cwd)
  end)
  it("queues another publication without replacing the active operation", function()
    remote.sync(root, false)
    remote.sync(root, false)
    remote.sync(root, true)
    assert.are.equal(1, #calls)
    calls[1].complete({ code = 0, stdout = "", stderr = "" })
    calls[1].complete = nil
    settle(20)
    assert.are.equal(2, #calls)
  end)
  it("requires opt-in for automatic publication while keeping manual sync available", function()
    vim.fn.writefile(
      { vim.json.encode({ version = 2, sync = { on_save = false } }) },
      root .. "/.overseer/experiment.json"
    )
    save_event()
    settle(350)
    assert.are.equal(0, #calls)
    remote.sync(root, true)
    assert.are.equal(1, #calls)
  end)
  it("does not retry failed publication until another save or manual request", function()
    remote.sync(root, false)
    calls[1].complete({ code = 1, stdout = "", stderr = "unavailable" })
    calls[1].complete = nil
    settle(20)
    assert.are.equal(1, #calls)
    remote.sync(root, false)
    assert.are.equal(2, #calls)
  end)
end)
