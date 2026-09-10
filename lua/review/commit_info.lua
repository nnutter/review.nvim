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

-- ============================================================================
-- Sidebar pane (window stacked above the codediff explorer)
-- ============================================================================

---@type number|nil scratch buffer for the pane
local info_bufnr = nil
---@type number|nil window id for the pane
local info_winid = nil
---@type number|nil tabpage the pane belongs to
local info_tabpage = nil

local ns_commit = vim.api.nvim_create_namespace("review_commit_info")

---@return number|nil explorer window or nil when hidden/absent
local function explorer_winid(tabpage)
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok or not lifecycle.get_explorer then
    return nil
  end
  local ok2, explorer = pcall(lifecycle.get_explorer, tabpage)
  if not ok2 or not explorer then
    return nil
  end
  if explorer.is_hidden then
    return nil
  end
  local win = explorer.split and explorer.split.winid or explorer.winid
  if win and vim.api.nvim_win_is_valid(win) then
    return win
  end
  if explorer.winid and vim.api.nvim_win_is_valid(explorer.winid) then
    return explorer.winid
  end
  return nil
end

local function ensure_buffer()
  if info_bufnr and vim.api.nvim_buf_is_valid(info_bufnr) then
    return info_bufnr
  end
  info_bufnr = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, info_bufnr, "review://commit-info")
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = info_bufnr })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = info_bufnr })
  vim.api.nvim_set_option_value("swapfile", false, { buf = info_bufnr })
  vim.api.nvim_set_option_value("modifiable", false, { buf = info_bufnr })
  vim.api.nvim_set_option_value("filetype", "review-commit-info", { buf = info_bufnr })
  return info_bufnr
end

---Highlight commit hashes and the author/date meta line.
---Single-commit layout: hash on row 1 only, meta on row 2, body plain.
---Multi-commit layout: leading hash on every row.
---@param bufnr number
---@param lines string[]
---@param is_single boolean
local function apply_highlights(bufnr, lines, is_single)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_commit, 0, -1)
  for row, line in ipairs(lines) do
    if is_single then
      if row == 1 then
        local hash = line:match("^(%S+)")
        if hash then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_commit, row - 1, 0, {
            end_col = #hash,
            hl_group = "ReviewCommitHash",
            priority = 200,
          })
        end
      elseif row == 2 then
        -- Author/Date meta line for the single-commit layout.
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_commit, row - 1, 0, {
          end_col = #line,
          hl_group = "ReviewCommitMeta",
          priority = 200,
        })
      end
    else
      local hash = line:match("^(%S+)")
      if hash then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_commit, row - 1, 0, {
          end_col = #hash,
          hl_group = "ReviewCommitHash",
          priority = 200,
        })
      end
    end
  end
end

---@return boolean visible
function M.is_visible()
  return info_winid ~= nil and vim.api.nvim_win_is_valid(info_winid)
end

---Show (or refresh) the commit-info pane for a tabpage.
---No-op when disabled, non-commit mode, or the explorer is hidden.
---@param tabpage number|nil current tab when nil
---@return boolean shown
function M.show(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local cfg_ok, cfg = pcall(require, "review.config")
  local commit_cfg = (cfg_ok and cfg.get and cfg.get().commit_info) or { enabled = true, height = 10 }
  if commit_cfg.enabled == false then
    M.hide()
    return false
  end
  local max_lines = commit_cfg.height or 10

  local ctx = M.get_context(tabpage)
  if not ctx then
    M.hide()
    return false
  end
  local commits = M.list_commits(ctx.git_root, ctx.base, ctx.target)
  if #commits == 0 then
    M.hide()
    return false
  end
  local lines = M.format_lines(commits, max_lines)
  if #lines == 0 then
    M.hide()
    return false
  end

  local exp_win = explorer_winid(tabpage)
  if not exp_win then
    M.hide()
    return false
  end

  local buf = ensure_buffer()
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  apply_highlights(buf, lines, #commits == 1)

  local height = max_lines
  if M.is_visible() and info_tabpage == tabpage then
    pcall(vim.api.nvim_win_set_height, info_winid, height)
    return true
  end

  M.hide()
  local ok, win = pcall(vim.api.nvim_open_win, buf, false, {
    split = "above",
    win = exp_win,
    height = height,
  })
  if not ok or not win then
    return false
  end
  info_winid = win
  info_tabpage = tabpage
  pcall(vim.api.nvim_set_option_value, "number", false, { win = win })
  pcall(vim.api.nvim_set_option_value, "relativenumber", false, { win = win })
  pcall(vim.api.nvim_set_option_value, "cursorline", false, { win = win })
  pcall(vim.api.nvim_set_option_value, "wrap", true, { win = win })
  pcall(vim.api.nvim_set_option_value, "signcolumn", "no", { win = win })
  pcall(vim.api.nvim_set_option_value, "winfixheight", true, { win = win })
  return true
end

function M.hide()
  if info_winid and vim.api.nvim_win_is_valid(info_winid) then
    pcall(vim.api.nvim_win_hide, info_winid)
  end
  info_winid = nil
  info_tabpage = nil
end

---Toggle the pane to match the explorer after `f` flips visibility.
---Call after codediff's toggle_visibility has run.
---@param tabpage number|nil
function M.sync_with_explorer(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  if explorer_winid(tabpage) then
    M.show(tabpage)
  else
    M.hide()
  end
end

M._test = {
  resolve_mode = resolve_mode,
  parse_record = parse_record,
  apply_highlights = apply_highlights,
  _state = function()
    return { buf = info_bufnr, win = info_winid, tab = info_tabpage }
  end,
  _reset = function()
    info_bufnr = nil
    info_winid = nil
    info_tabpage = nil
  end,
}

return M
