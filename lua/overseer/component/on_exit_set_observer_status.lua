local STATUS = require("overseer.constants").STATUS

---@type overseer.ComponentFileDefinition
return {
  desc = "Classify an OMO observer exit separately from its remote job lifetime",
  constructor = function(_params)
    return {
      on_exit = function(_, task, code)
        local canceled = code == 130 or code == 3
        task:finalize(
          code == 0 and STATUS.SUCCESS or (canceled and STATUS.CANCELED or STATUS.FAILURE)
        )
      end,
    }
  end,
}
