local hooks = require("review.hooks")

describe("CodeDiff path compatibility", function()
  it("accepts string paths from older CodeDiff versions", function()
    assert.equals("src/file.lua", hooks._test.path_string("src/file.lua"))
  end)

  it("uses an absolute path from newer CodeDiff path references", function()
    assert.equals("/repo/src/file.lua", hooks._test.path_string({
      absolute = "/repo/src/file.lua",
      relative = "src/file.lua",
    }))
  end)

  it("falls back to a relative path when absolute is empty", function()
    assert.equals("src/file.lua", hooks._test.path_string({
      absolute = "",
      relative = "src/file.lua",
    }))
  end)
end)
