return {
  desc = "Resolve the selected CMake executable when its Run task starts",
  constructor = function()
    return {
      on_pre_start = function(_, task)
        require("overseer.cmake").refresh_run(task)
      end,
    }
  end,
}
