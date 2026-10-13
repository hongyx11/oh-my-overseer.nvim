local cmake = require("overseer.cmake")
local config = require("overseer.config")
local overseer = require("overseer")
vim.opt.rtp:append(vim.fn.getcwd())

describe("CMake preset selection", function()
  local root, cwd, select, notify, created, source, source_buf
  local function write(path, data)
    vim.fn.writefile(type(data) == "table" and data or { data }, root .. "/" .. path)
  end
  local function choose(name)
    local done, selection = false, nil
    vim.ui.select = function(items, _, callback)
      for _, item in ipairs(items) do
        if item.name == name then
          callback(item)
          return
        end
      end
      callback(nil)
    end
    cmake.select(function(value)
      selection = value
      done = true
    end, root)
    assert.is_true(vim.wait(5000, function()
      return done
    end, 10))
    assert.is_not_nil(selection)
    return selection
  end
  before_each(function()
    cwd, select, notify = vim.fn.getcwd(), vim.ui.select, vim.notify
    root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/.vscode", "p")
    vim.cmd.cd(root)
    source, source_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    created = {}
    vim.notify = function(message, level)
      if level == vim.log.levels.ERROR then
        print(message)
      end
    end
    overseer.setup({ dap = false, results = { enabled = true }, cmake = { enabled = true } })
    write(
      "CMakePresets.json",
      vim.json.encode({
        version = 4,
        include = { "base-presets.json" },
        configurePresets = {
          { name = "red", inherits = "base" },
          { name = "blue", inherits = "base" },
          {
            name = "unavailable",
            inherits = "base",
            condition = { type = "equals", lhs = "${hostSystemName}", rhs = "__other__" },
          },
        },
      })
    )
    write(
      "base-presets.json",
      vim.json.encode({
        version = 4,
        configurePresets = {
          {
            name = "base",
            hidden = true,
            generator = "Unix Makefiles",
            binaryDir = "$env{BUILD_OUTPUT}/${presetName}",
            environment = { BUILD_OUTPUT = "${sourceDir}/build" },
          },
        },
      })
    )
    local task = {
      version = "2.0.0",
      options = { cwd = "${workspaceFolder}" },
      tasks = {
        { label = "Configure", type = "process", command = "cmake", args = { "--preset", "red" } },
        {
          label = "Build",
          type = "process",
          command = "cmake",
          args = { "--build", "build/red", "--target", "hello", "--parallel" },
        },
        {
          label = "Run",
          type = "process",
          command = "${workspaceFolder}/build/red/bin/hello",
          presentation = { reveal = "always" },
        },
        {
          label = "Configure, build and run",
          dependsOn = { "Configure", "Build", "Run" },
          dependsOrder = "sequence",
        },
      },
    }
    write(".vscode/tasks.json", vim.json.encode(task))
    write("CMakeLists.txt", {
      "cmake_minimum_required(VERSION 3.21)",
      "project(results_fixture C)",
      'set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/programs")',
      "add_executable(hello main.c)",
    })
    write(
      "main.c",
      { "#include <stdio.h>", 'int main(void) { puts("program output"); return 0; }' }
    )
  end)
  after_each(function()
    vim.wait(50, function()
      return false
    end, 5)
    for _, task in ipairs(created) do
      task:dispose(true)
    end
    vim.api.nvim_set_current_win(source)
    vim.api.nvim_win_set_buf(source, source_buf)
    vim.cmd.only({ bang = true })
    vim.ui.select, vim.notify = select, notify
    vim.cmd.cd(cwd)
    vim.fn.delete(root, "rf")
    config.setup({ cmake = { enabled = false }, results = { enabled = false } })
  end)

  it(
    "asks CMake for available presets and resolves included inherited directories and environment macros",
    function()
      local seen
      vim.ui.select = function(items, _, callback)
        seen = items
        callback(items[2])
      end
      local done, selection
      cmake.select(function(value)
        selection = value
        done = true
      end, root)
      assert.is_true(vim.wait(5000, function()
        return done
      end, 10))
      assert.are.same(
        { "red", "blue" },
        vim.tbl_map(function(item)
          return item.name
        end, seen)
      )
      assert.are.equal(root .. "/build/blue", selection.binary_dir)
      assert.are.equal("blue", cmake.get(root).name)
    end
  )

  it("does not run a workflow when initial preset selection is canceled", function()
    vim.ui.select = function(_, _, callback)
      callback(nil)
    end
    local ready
    cmake.ensure(function(value)
      ready = value
    end)
    assert.is_true(vim.wait(5000, function()
      return ready ~= nil
    end, 10))
    assert.is_false(ready)
    assert.is_nil(cmake.get(root))
  end)

  it("freezes a parent's preset even when the selection changes during the workflow", function()
    choose("blue")
    local parent =
      overseer.new_task({ name = "Workflow", cmd = "test", strategy = "test", cwd = root })
    table.insert(created, parent)
    parent:start()
    choose("red")
    local child = overseer.new_task({
      name = "Build",
      cmd = { "cmake", "--build", "build/red", "--target", "hello" },
      cwd = root,
      parent_id = parent.id,
      strategy = "test",
    })
    table.insert(created, child)
    child:start()
    assert.are.equal(root .. "/build/blue", child.cmd[3])
  end)

  it(
    "configures, builds and runs the selected preset using CMake's actual executable artifact",
    function()
      choose("blue")
      local parent
      overseer.run_task(
        { name = "Configure, build and run", search_params = { dir = root } },
        function(task)
          parent = task
        end
      )
      local complete = vim.wait(20000, function()
        return parent and parent:is_complete()
      end, 20)
      if not complete then
        for _, task in ipairs(overseer.list_tasks({ include_ephemeral = true })) do
          local buf = task:get_bufnr()
          print(
            task.name,
            task.status,
            vim.inspect(task.cmd),
            buf and table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
          )
        end
      end
      assert.is_true(complete)
      table.insert(created, parent)
      assert.are.equal(overseer.STATUS.SUCCESS, parent.status)
      assert.is_not_nil(vim.uv.fs_stat(root .. "/build/blue/CMakeCache.txt"))
      assert.is_nil(vim.uv.fs_stat(root .. "/build/red/CMakeCache.txt"))
      local run
      for _, task in ipairs(overseer.list_tasks({ include_ephemeral = true })) do
        if task.parent_id == parent.id and task.name == "Run" then
          run = task
        end
      end
      assert.is_not_nil(run)
      assert.are.equal(root .. "/build/blue/programs/hello", run.cmd[1])
      assert.is_truthy(
        table
          .concat(vim.api.nvim_buf_get_lines(run:get_bufnr(), 0, -1, false), "\n")
          :find("program output", 1, true)
      )
      vim.wait(50, function()
        return false
      end, 5)
      assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
      assert.are.equal(source, vim.api.nvim_get_current_win())
      assert.are.equal(source_buf, vim.api.nvim_win_get_buf(source))
    end
  )
end)
