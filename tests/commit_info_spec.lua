local commit_info = require("review.commit_info")

describe("review.commit_info", function()
  describe("resolve_mode", function()
    local resolve_mode = commit_info._test.resolve_mode

    it("returns nil when base is missing (status mode)", function()
      assert.is_nil(resolve_mode(nil, nil))
      assert.is_nil(resolve_mode("", nil))
    end)

    it("returns nil for staged mode", function()
      assert.is_nil(resolve_mode("abc123", ":0"))
    end)

    it("returns single for working-tree target", function()
      assert.equals("single", resolve_mode("abc123", "WORKING"))
      assert.equals("single", resolve_mode("abc123", nil))
    end)

    it("returns single when base equals target", function()
      assert.equals("single", resolve_mode("abc123", "abc123"))
    end)

    it("returns range for two revisions", function()
      assert.equals("range", resolve_mode("abc123", "def456"))
    end)
  end)

  describe("format_lines", function()
    it("formats a single commit with subject and body", function()
      local lines = commit_info.format_lines({
        { short = "abc1234", subject = "Fix bug", author = "Ada", date = "2026-09-10", body = "Details here" },
      }, 10)
      assert.equals("abc1234 Fix bug", lines[1])
      assert.matches("Ada", lines[2])
      assert.matches("Details here", lines[4])
    end)

    it("caps single commit output at max_lines", function()
      local body = table.concat({ "l1", "l2", "l3", "l4", "l5", "l6", "l7", "l8", "l9" }, "\n")
      local lines = commit_info.format_lines({
        { short = "abc1234", subject = "Subj", author = "A", date = "2026-09-10", body = body },
      }, 10)
      assert.is_true(#lines <= 10)
      assert.equals("abc1234 Subj", lines[1])
    end)

    it("formats multiple commits as short plus subject", function()
      local lines = commit_info.format_lines({
        { short = "def4567", subject = "Newest", author = "A", date = "d", body = "" },
        { short = "abc1234", subject = "Oldest", author = "A", date = "d", body = "" },
      }, 10)
      assert.equals(2, #lines)
      assert.equals("def4567 Newest", lines[1])
      assert.equals("abc1234 Oldest", lines[2])
    end)

    it("returns empty for no commits", function()
      assert.same({}, commit_info.format_lines({}, 10))
    end)
  end)

  describe("list_commits", function()
    it("returns empty for missing args", function()
      assert.same({}, commit_info.list_commits("", "abc", "def"))
      assert.same({}, commit_info.list_commits("/tmp", "", "def"))
    end)

    it("lists a single commit from the test repo", function()
      local root = vim.fn.systemlist("git rev-parse --show-toplevel")[1]
      local head = vim.fn.systemlist("git -C " .. vim.fn.shellescape(root) .. " rev-parse HEAD")[1]
      local commits = commit_info.list_commits(root, head, nil)
      assert.equals(1, #commits)
      assert.equals(head:sub(1, 7), commits[1].short)
      assert.is_true(commits[1].subject ~= "")
    end)

    it("lists a range from the test repo", function()
      local root = vim.fn.systemlist("git rev-parse --show-toplevel")[1]
      local head = vim.fn.systemlist("git -C " .. vim.fn.shellescape(root) .. " rev-parse HEAD")[1]
      local parent = vim.fn.systemlist("git -C " .. vim.fn.shellescape(root) .. " rev-parse HEAD~1")[1]
      if vim.v.shell_error ~= 0 or not parent or parent == "" then
        pending("needs at least 2 commits in history")
        return
      end
      local commits = commit_info.list_commits(root, parent, head)
      assert.is_true(#commits >= 1)
      assert.equals(head:sub(1, 7), commits[1].short)
    end)
  end)
end)
