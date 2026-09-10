-- Commit info for the review sidebar.
-- Data layer only (no windows): resolves the revision range from the
-- codediff session, loads commits via git, and formats display lines.
local M = {}

---@class ReviewCommit
---@field hash string full hash
---@field short string short hash
---@field author string
---@field date string
---@field subject string
---@field body string

---@class ReviewCommitContext
---@field git_root string
---@field base string
---@field target string|nil

local FIELD_SEP = "\31"
local RECORD_SEP = "\30"

---@param rev string|nil
---@return boolean
local function is_working_rev(rev)
  return rev == nil or rev == "" or rev == "WORKING"
end

---@param rev string|nil
---@return boolean
local function is_index_rev(rev)
  return rev == ":0"
end

---Classify a (base, target) pair.
---@param base string|nil
---@param target string|nil
---@return "single"|"range"|nil mode nil when no commit pane should show
local function resolve_mode(base, target)
  if not base or base == "" then
    return nil
  end
  if is_index_rev(target) then
    return nil
  end
  if is_working_rev(target) then
    return "single"
  end
  if base == target then
    return "single"
  end
  return "range"
end

---Best-effort git root for the current working directory.
---@return string|nil
local function cwd_git_root()
  local result = vim.fn.systemlist("git rev-parse --show-toplevel")
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return result[1]
end

---Resolve the commit-review context for a tabpage.
---Returns nil for status/staged/dir mode (no commit pane).
---@param tabpage number|nil current tab when nil
---@return ReviewCommitContext|nil
function M.get_context(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()

  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if ok and lifecycle then
    -- Prefer the explorer's revisions: they are the range the file list
    -- itself was built from (see codediff ui/view/panel.lua).
    local explorer_ok, explorer = pcall(lifecycle.get_explorer, tabpage)
    if explorer_ok and explorer and explorer.git_root then
      local mode = resolve_mode(explorer.base_revision, explorer.target_revision)
      if mode then
        return { git_root = explorer.git_root, base = explorer.base_revision, target = explorer.target_revision }
      end
      return nil
    end

    local ctx_ok, ctx = pcall(lifecycle.get_git_context, tabpage)
    if ctx_ok and ctx and ctx.git_root then
      local mode = resolve_mode(ctx.original_revision, ctx.modified_revision)
      if mode then
        return { git_root = ctx.git_root, base = ctx.original_revision, target = ctx.modified_revision }
      end
      return nil
    end
  end

  -- Fallback when codediff is unavailable (e.g. in tests): the raw
  -- revision range review passed to :CodeDiff.
  local storage_ok, storage = pcall(require, "review.storage")
  if storage_ok and storage.get_revisions then
    local revs = storage.get_revisions()
    if revs and revs.rev1 and revs.rev2 then
      local root = cwd_git_root()
      if root then
        return { git_root = root, base = revs.rev1, target = revs.rev2 }
      end
    end
  end

  return nil
end

---Split a raw git log record into a commit.
---@param record string
---@return ReviewCommit|nil
local function parse_record(record)
  -- %b (body) can be empty, so the trailing field may be missing.
  local fields = vim.split(record, FIELD_SEP, { plain = true })
  if #fields < 5 then
    return nil
  end
  return {
    hash = fields[1],
    short = fields[2],
    author = fields[3],
    date = fields[4],
    subject = fields[5],
    body = fields[6] or "",
  }
end

---Run git log and parse the result.
---@param git_root string
---@param args string[] args after `git -C <root> log`
---@return ReviewCommit[]
local function run_log(git_root, args)
  local format = table.concat({ "%H", "%h", "%an", "%ad", "%s", "%b" }, "%x1f") .. "%x1e"
  local cmd = { "git", "-C", git_root, "log", "--date=short", "--format=" .. format }
  vim.list_extend(cmd, args)
  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return {}
  end
  if not result or result == "" then
    return {}
  end

  local commits = {}
  for _, record in ipairs(vim.split(result, RECORD_SEP, { plain = true })) do
    record = record:gsub("^%s+", ""):gsub("%s+$", "")
    if record ~= "" then
      local commit = parse_record(record)
      if commit then
        table.insert(commits, commit)
      end
    end
  end
  return commits
end

---List commits for a revision context.
---@param git_root string
---@param base string
---@param target string|nil
---@return ReviewCommit[]
function M.list_commits(git_root, base, target)
  if not git_root or git_root == "" or not base or base == "" then
    return {}
  end
  local mode = resolve_mode(base, target)
  if mode == "single" then
    return run_log(git_root, { "-n", "1", base })
  elseif mode == "range" and target and target ~= "" then
    ---@diagnostic disable-next-line: param-type-mismatch
    return run_log(git_root, { base .. ".." .. target })
  end
  return {}
end

---Format commits for the sidebar pane.
---Single commit: subject + author/date + body, capped at max_lines.
---Multiple: one `short subject` line per commit.
---@param commits ReviewCommit[]
---@param max_lines number|nil default 10
---@return string[]
function M.format_lines(commits, max_lines)
  max_lines = max_lines or 10
  if #commits == 0 then
    return {}
  end
  if #commits == 1 then
    local c = commits[1]
    local lines = {
      string.format("%s %s", c.short, c.subject),
      string.format("Author: %s  Date: %s", c.author, c.date),
      "",
    }
    if c.body and c.body ~= "" then
      for _, line in ipairs(vim.split(c.body:gsub("%s+$", ""), "\n", { plain = true })) do
        table.insert(lines, line)
      end
    end
    -- Remove trailing blank lines, then cap.
    while #lines > 0 and lines[#lines]:match("^%s*$") do
      table.remove(lines)
    end
    while #lines > max_lines do
      table.remove(lines)
    end
    return lines
  end

  local lines = {}
  for _, c in ipairs(commits) do
    table.insert(lines, string.format("%s %s", c.short, c.subject))
  end
  return lines
end

M._test = {
  resolve_mode = resolve_mode,
  parse_record = parse_record,
}

return M
