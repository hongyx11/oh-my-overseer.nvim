local files = require("overseer.experiment_files")

describe("experiment file folders", function()
  local root, notify, input, messages
  local function write(path)
    vim.fn.mkdir(vim.fs.dirname(root .. "/" .. path), "p")
    vim.fn.writefile({ "test matrix" }, root .. "/" .. path)
  end
  local function paths(choices)
    local result = {}
    for _, choice in ipairs(choices) do
      result[choice.path] = choice.id
    end
    return result
  end
  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    root = vim.uv.fs_realpath(root)
    notify, input, messages = vim.notify, vim.ui.input, {}
    vim.notify = function(message)
      messages[#messages + 1] = message
    end
  end)
  after_each(function()
    vim.notify, vim.ui.input = notify, input
    vim.fn.delete(root, "rf")
  end)

  it("discovers root and nested matrices while preserving explicit inputs and IDs", function()
    write("datasets/root.mtx")
    write("datasets/output/nested.mtx")
    write("smoke.mtx")
    local choices = files.scan(root, {
      source = { directory = "datasets", pattern = "*.mtx" },
      choices = {
        { id = "root-id", path = "datasets/root.mtx" },
        { id = "bundled", path = "smoke.mtx" },
        { id = "deleted", path = "datasets/deleted.mtx" },
      },
    })
    assert.same({
      ["datasets/root.mtx"] = "root-id",
      ["datasets/output/nested.mtx"] = "output/nested",
      ["smoke.mtx"] = "bundled",
    }, paths(choices))
  end)

  it("deduplicates overlapping folders and gives colliding filenames stable IDs", function()
    write("datasets/same.mtx")
    write("datasets/output/second.mtx")
    write("other/same.mtx")
    local definition = {
      source = {
        directory = "datasets",
        directories = { "datasets/output", "other" },
        pattern = "*.mtx",
      },
      choices = {},
    }
    local first = files.scan(root, definition)
    assert.are.equal(3, #first)
    assert.are_not.equal(paths(first)["datasets/same.mtx"], paths(first)["other/same.mtx"])
    definition.choices = first
    assert.same(first, files.scan(root, definition))
  end)

  it("handles folder names containing commas, spaces and glob characters", function()
    write("matrices [x], user's/sample.mtx")
    local choices =
      files.scan(root, { source = { directory = "matrices [x], user's", pattern = "*.mtx" } })
    assert.same({ ["matrices [x], user's/sample.mtx"] = "sample" }, paths(choices))
  end)

  it("adds and saves a folder with completion while keeping the selected matrices", function()
    write("datasets/first.mtx")
    write("extra matrices/second.mtx")
    local option = {
      id = "dataset",
      source = { directory = "datasets", pattern = "*.mtx" },
      choices = { { id = "first", path = "datasets/first.mtx" } },
      selected = { "first" },
    }
    local state = {
      root = root,
      config = { parameters = { option } },
      resolved = { parameters = { vim.deepcopy(option) } },
    }
    local committed, completed = false, false
    vim.ui.input = function(opts, callback)
      assert.are.equal("dir", opts.completion)
      callback("extra matrices")
    end
    files.add_folder(state, 1, { "first" }, function()
      require("overseer.experiment_store").write(root .. "/experiment.json", state.config)
      committed = true
    end, function()
      completed = true
    end)
    assert.is_true(committed and completed)
    local saved =
      require("overseer.experiment_store").read(root .. "/experiment.json").parameters[1]
    assert.same({ "extra matrices" }, saved.source.directories)
    assert.same({ "first" }, saved.selected)
    assert.are.equal("second", paths(saved.choices)["extra matrices/second.mtx"])
    assert.is_nil(state.resolved.parameters[1].source.directories)
  end)

  it(
    "keeps configuration unchanged when adding a cancelled, missing or duplicate folder",
    function()
      write("datasets/first.mtx")
      local option = {
        id = "dataset",
        source = { directory = "datasets", pattern = "*.mtx" },
        choices = {},
        selected = {},
      }
      local state = {
        root = root,
        config = { parameters = { option } },
        resolved = { parameters = { vim.deepcopy(option) } },
      }
      local original = vim.deepcopy(state.config)
      for _, value in ipairs({ false, "missing", "datasets/../datasets" }) do
        local completed = false
        vim.ui.input = function(_, callback)
          callback(value or nil)
        end
        files.add_folder(state, 1, {}, function()
          error("Unexpected save")
        end, function()
          completed = true
        end)
        assert.is_true(completed)
        assert.same(original, state.config)
      end
    end
  )

  it("reports an empty folder and keeps the bundled matrix available", function()
    write("smoke.mtx")
    vim.fn.mkdir(root .. "/datasets", "p")
    local choices = files.scan(root, {
      source = { directory = "datasets", pattern = "*.mtx" },
      choices = { { id = "smoke", path = "smoke.mtx" } },
    })
    assert.are.equal(1, #choices)
    assert.is_truthy(messages[1]:find("No *.mtx files found under datasets", 1, true))
    assert.is_truthy(messages[1]:find("Add folder", 1, true))
  end)
end)
