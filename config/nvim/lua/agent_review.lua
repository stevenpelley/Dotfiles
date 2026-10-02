-- Review comments for coding-agent feedback loops.
--
-- Record line-anchored review comments while reading diffs in diffview.nvim
-- (or any file buffer); a coding agent then reads and resolves them with the
-- `address-review` skill (~/Dotfiles/agents/skills/address-review).
--
-- Each comment captures what you would otherwise type by hand: the revision
-- being viewed (full commit SHA, INDEX or WORKTREE), which side of the diff,
-- the repo-relative path, the line range, the code on those lines, the
-- enclosing function/class (treesitter), and the commit(s) that introduced
-- those lines (git blame) — so comments made while reviewing a whole stack
-- still point at the commit that needs fixing.
--
-- Storage: <git-common-dir>/agent-review/comments.jsonl, one JSON object per
-- line. Inside .git it can never be committed, and the common dir is shared
-- by every worktree of the repository. The skill's scripts/review.py reads
-- and updates the same file; keep the two in sync when changing the schema.
--
-- Schema (all optional fields are omitted rather than null):
--   id          "r" + 6 hex chars
--   status      "open" | "resolved" | "wontfix"
--   created     ISO-8601 UTC
--   repo        worktree toplevel the comment was made in
--   head        branch (or detached SHA) checked out at review time
--   rev         viewed revision: 40-char SHA | "INDEX" | "WORKTREE"
--   side        "old" | "new" (left / right side of the diff)
--   other_rev   revision on the other side of the diff, if any
--   path        repo-relative path at `rev`; other_path at `other_rev`
--   line_start, line_end   1-based inclusive line numbers in `rev`'s file
--   code        the commented lines, verbatim (re-anchor when lines move)
--   context     enclosing symbols, e.g. "MyClass > my_method"
--   commits     new side: commits that last touched the lines (git blame;
--               "UNCOMMITTED" for working-tree changes). old side: commits
--               between rev and other_rev touching the file.
--   body        the comment text
--   replies     [{ by = "user" | "agent", body, at, commit? }]
--
-- Signs/virtual text mark commented lines in diff and file buffers. Line
-- numbers are those of the reviewed revision; WORKTREE comments do not follow
-- later edits.

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("agent_review")

local STORE_DIR = "agent-review"
local STORE_FILE = "comments.jsonl"
local SHA_PATTERN = "^(" .. ("%x"):rep(40) .. ") %d+ %d+"
local ZERO_SHA = ("0"):rep(40)

-- git ------------------------------------------------------------------------

---@return string? stdout, string? stderr
local function git(args, opts)
  opts = opts or {}
  local cmd = { "git" }
  if opts.cwd then
    vim.list_extend(cmd, { "-C", opts.cwd })
  end
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { text = true, stdin = opts.stdin }):wait()
  if res.code ~= 0 then
    return nil, vim.trim(res.stderr or "")
  end
  return res.stdout or ""
end

local toplevel_cache = {}
local function toplevel_for(dir)
  if toplevel_cache[dir] == nil then
    local out = git({ "rev-parse", "--show-toplevel" }, { cwd = dir })
    toplevel_cache[dir] = out and vim.trim(out) or false
  end
  return toplevel_cache[dir] or nil
end

local store_cache = {}
local function store_for(top)
  if not store_cache[top] then
    local out = git({ "rev-parse", "--path-format=absolute", "--git-common-dir" }, { cwd = top })
    if not out then
      return nil
    end
    store_cache[top] = vim.trim(out) .. "/" .. STORE_DIR .. "/" .. STORE_FILE
  end
  return store_cache[top]
end

local sha_cache = {}
local function full_sha(rev, top)
  if not rev or #rev == 40 then
    return rev
  end
  if not sha_cache[rev] then
    local out = git({ "rev-parse", "--verify", rev .. "^{commit}" }, { cwd = top })
    sha_cache[rev] = out and vim.trim(out) or rev
  end
  return sha_cache[rev]
end

local function short(rev)
  if rev and rev:match("^%x+$") and #rev == 40 then
    return rev:sub(1, 8)
  end
  return rev or "?"
end

-- store ----------------------------------------------------------------------

local function load(path)
  local f = path and io.open(path, "r")
  if not f then
    return {}
  end
  local items = {}
  for line in f:lines() do
    if line:match("%S") then
      local ok, obj = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
      if ok and type(obj) == "table" then
        table.insert(items, obj)
      end
    end
  end
  f:close()
  return items
end

-- empty Lua tables are ambiguous in JSON; omit empty lists entirely
local function encode(c)
  for _, k in ipairs({ "replies", "commits", "code" }) do
    if type(c[k]) == "table" and #c[k] == 0 then
      c[k] = nil
    end
  end
  return vim.json.encode(c)
end

local function save(path, items)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local tmp = path .. ".tmp." .. vim.uv.os_getpid()
  local f = assert(io.open(tmp, "w"))
  for _, c in ipairs(items) do
    f:write(encode(c), "\n")
  end
  f:close()
  assert(os.rename(tmp, path))
end

local function append(path, c)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "a"))
  f:write(encode(c), "\n")
  f:close()
end

-- load-modify-save so edits made by the agent in between are preserved
local function update(path, id, fn)
  local items = load(path)
  for i, c in ipairs(items) do
    if c.id == id then
      if fn(c) == false then
        table.remove(items, i)
      end
      save(path, items)
      return true
    end
  end
  vim.notify("review: comment " .. id .. " no longer exists", vim.log.levels.WARN)
  return false
end

local function now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function new_id()
  return "r" .. vim.fn.sha256(tostring(vim.uv.hrtime()) .. tostring(math.random())):sub(1, 6)
end

-- location of a window: which repo/rev/path its buffer shows -----------------

local function rev_id(rev, top)
  local ok, revmod = pcall(require, "diffview.vcs.rev")
  if not ok or not rev then
    return nil
  end
  local RevType = revmod.RevType
  if rev.type == RevType.LOCAL then
    return "WORKTREE"
  elseif rev.type == RevType.STAGE then
    return "INDEX"
  elseif rev.type == RevType.COMMIT then
    return full_sha(rev.commit, top)
  end
end

---@class AgentReviewLoc
---@field buf integer
---@field top string
---@field path string
---@field rev string
---@field side "old"|"new"
---@field other_rev? string
---@field other_path? string

---@return AgentReviewLoc?
local function locate(winid)
  winid = winid or api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(winid)

  local ok, lib = pcall(require, "diffview.lib")
  local view = ok and lib.get_current_view() or nil
  if view and view.cur_layout and view.adapter then
    local top = view.adapter.ctx.toplevel
    for _, w in ipairs(view.cur_layout.windows) do
      if w.id == winid then
        local file = w.file
        if not file or file.nulled or not file.rev then
          return nil
        end
        local loc = {
          buf = file.bufnr or buf,
          top = top,
          path = file.path,
          rev = rev_id(file.rev, top),
          side = file.symbol == "a" and "old" or "new",
        }
        for _, o in ipairs(view.cur_layout.windows) do
          if o ~= w and o.file and o.file.rev and not o.file.nulled then
            loc.other_rev = rev_id(o.file.rev, top)
            loc.other_path = o.file.path
            break
          end
        end
        return loc.rev and loc or nil
      end
    end
  end

  -- plain file buffer: the working tree version
  if vim.bo[buf].buftype ~= "" then
    return nil
  end
  local name = api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end
  local real = vim.uv.fs_realpath(name) or name
  local top = toplevel_for(vim.fs.dirname(real))
  if not top then
    return nil
  end
  local rtop = vim.uv.fs_realpath(top) or top
  if real:sub(1, #rtop + 1) ~= rtop .. "/" then
    return nil
  end
  return { buf = buf, top = top, path = real:sub(#rtop + 2), rev = "WORKTREE", side = "new" }
end

-- commits responsible for the commented lines --------------------------------

local function blame_commits(loc, s, e)
  local args = { "blame", "--porcelain", "-L", s .. "," .. e }
  local stdin
  if loc.rev == "WORKTREE" or loc.rev == "INDEX" then
    -- blame the buffer contents as shown (unsaved edits / staged version)
    vim.list_extend(args, { "--contents", "-" })
    stdin = table.concat(api.nvim_buf_get_lines(loc.buf, 0, -1, false), "\n") .. "\n"
  else
    table.insert(args, loc.rev)
  end
  vim.list_extend(args, { "--", loc.path })
  local out = git(args, { cwd = loc.top, stdin = stdin })
  local seen, list = {}, {}
  for line in (out or ""):gmatch("[^\n]+") do
    local sha = line:match(SHA_PATTERN)
    if sha then
      sha = sha == ZERO_SHA and "UNCOMMITTED" or sha
      if not seen[sha] then
        seen[sha] = true
        table.insert(list, sha)
      end
    end
  end
  return list
end

local function commits_for(loc, s, e)
  if loc.side == "new" then
    return blame_commits(loc, s, e)
  end
  -- old side: the change happened somewhere between this rev and the other
  -- side; list the commits in that range that touched the file
  if not loc.other_rev or loc.rev:match("[^%x]") then
    return {}
  end
  local to = loc.other_rev:match("^%x+$") and loc.other_rev or "HEAD"
  local paths = { loc.path }
  if loc.other_path and loc.other_path ~= loc.path then
    table.insert(paths, loc.other_path)
  end
  local args = { "log", "--format=%H", loc.rev .. ".." .. to, "--" }
  vim.list_extend(args, paths)
  local out = git(args, { cwd = loc.top })
  local list = vim.split(vim.trim(out or ""), "\n", { trimempty = true })
  if loc.other_rev == "WORKTREE" or loc.other_rev == "INDEX" then
    table.insert(list, 1, "UNCOMMITTED")
  end
  return list
end

-- enclosing function/class names via treesitter ------------------------------

local CONTAINERS = { "function", "method", "class", "struct", "impl", "interface", "module", "enum", "trait", "namespace" }

local function ts_context(buf, row)
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return nil
  end
  pcall(function() parser:parse() end)
  local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local col = math.max((line:find("%S") or 1) - 1, 0)
  local ok2, node = pcall(vim.treesitter.get_node, { bufnr = buf, pos = { row, col } })
  if not ok2 or not node then
    return nil
  end
  local parts = {}
  while node do
    local t = node:type()
    if not t:find("call", 1, true) then
      for _, k in ipairs(CONTAINERS) do
        if t:find(k, 1, true) then
          local name = node:field("name")[1]
          if name then
            table.insert(parts, 1, (vim.treesitter.get_node_text(name, buf):gsub("\n.*", "")))
          end
          break
        end
      end
    end
    node = node:parent()
  end
  return #parts > 0 and table.concat(parts, " > ") or nil
end

-- UI ---------------------------------------------------------------------------

-- Floating markdown buffer for multi-line input. <C-s> saves; q/<Esc> cancel.
local function input(title, initial, on_submit)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  api.nvim_buf_set_lines(buf, 0, -1, false, initial or {})
  local width = math.min(100, math.floor(vim.o.columns * 0.7))
  local height = math.min(14, math.floor(vim.o.lines * 0.4))
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    style = "minimal",
    title = " " .. title .. " ",
    title_pos = "center",
    footer = " <C-s> save · q / <Esc> cancel ",
    footer_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true

  local done = false
  local function close()
    done = true
    vim.cmd("stopinsert")
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end
  local function submit()
    if done then
      return
    end
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    close()
    local text = vim.trim(table.concat(lines, "\n"))
    if text == "" then
      vim.notify("review: empty text, nothing saved")
      return
    end
    on_submit(text)
  end
  vim.keymap.set({ "n", "i" }, "<C-s>", submit, { buffer = buf, desc = "Save" })
  vim.keymap.set("n", "q", close, { buffer = buf, desc = "Cancel" })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, desc = "Cancel" })
  if not initial or #initial == 0 then
    vim.cmd("startinsert")
  end
end

local function first_line(s)
  return (s or ""):match("[^\n]*")
end

local function place(buf, c)
  local n = api.nvim_buf_line_count(buf)
  local s = math.min(c.line_start or 1, n) - 1
  local e = math.min(c.line_end or c.line_start or 1, n) - 1
  local open = c.status == "open"
  local hl = open and "DiagnosticWarn" or "Comment"
  for row = s, e do
    pcall(api.nvim_buf_set_extmark, buf, ns, row, 0, {
      sign_text = row == s and (open and "◆" or "◇") or "│",
      sign_hl_group = hl,
      priority = 20,
    })
  end
  local tag = ""
  local last = c.replies and c.replies[#c.replies]
  if not open then
    tag = "[" .. (c.status or "?") .. "] "
  elseif last and last.by == "agent" then
    tag = "[agent replied] "
  end
  pcall(api.nvim_buf_set_extmark, buf, ns, s, 0, {
    virt_text = { { "  " .. tag .. first_line(c.body), hl } },
    virt_text_pos = "eol",
    hl_mode = "combine",
  })
end

--- Redraw signs for every window in the current tabpage.
function M.refresh()
  local loaded = {}
  for _, winid in ipairs(api.nvim_tabpage_list_wins(0)) do
    local ok, loc = pcall(locate, winid)
    if ok and loc and api.nvim_buf_is_valid(loc.buf) then
      api.nvim_buf_clear_namespace(loc.buf, ns, 0, -1)
      local store = store_for(loc.top)
      if store then
        loaded[store] = loaded[store] or load(store)
        for _, c in ipairs(loaded[store]) do
          if c.rev == loc.rev and c.path == loc.path then
            place(loc.buf, c)
          end
        end
      end
    end
  end
end

local function current_loc()
  local loc = locate()
  if not loc then
    vim.notify("review: not a diffview diff window or a file inside a git repo", vim.log.levels.WARN)
    return nil
  end
  local store = store_for(loc.top)
  if not store then
    vim.notify("review: cannot resolve the git dir for " .. loc.top, vim.log.levels.ERROR)
    return nil
  end
  return loc, store
end

-- Calls fn(comment, store) for the comment under the cursor (asks if several).
local function with_comment_at_cursor(fn)
  local loc, store = current_loc()
  if not loc then
    return
  end
  local line = api.nvim_win_get_cursor(0)[1]
  local hits = {}
  for _, c in ipairs(load(store)) do
    if c.rev == loc.rev and c.path == loc.path and line >= (c.line_start or 0) and line <= (c.line_end or 0) then
      table.insert(hits, c)
    end
  end
  if #hits == 0 then
    vim.notify("review: no comment on this line")
  elseif #hits == 1 then
    fn(hits[1], store)
  else
    vim.ui.select(hits, {
      prompt = "Comment",
      format_item = function(c)
        return string.format("%s [%s] %s", c.id, c.status, first_line(c.body))
      end,
    }, function(c)
      if c then
        fn(c, store)
      end
    end)
  end
end

-- actions ----------------------------------------------------------------------

--- Add a comment on lines s..e (1-based, inclusive) of the current window.
function M.add(s, e)
  local loc, store = current_loc()
  if not loc then
    return
  end
  s, e = math.min(s, e), math.max(s, e)
  local code = api.nvim_buf_get_lines(loc.buf, s - 1, e, false)
  local context = ts_context(loc.buf, s - 1)
  local commits = commits_for(loc, s, e)
  local head = git({ "rev-parse", "--abbrev-ref", "HEAD" }, { cwd = loc.top })
  head = head and vim.trim(head)
  if head == "HEAD" then
    head = vim.trim(git({ "rev-parse", "HEAD" }, { cwd = loc.top }) or "")
  end
  local title = string.format("%s %s:%d-%d", short(loc.rev), loc.path, s, e)
  input("Review " .. title, nil, function(body)
    local c = {
      id = new_id(),
      status = "open",
      created = now(),
      repo = loc.top,
      head = head,
      rev = loc.rev,
      side = loc.side,
      other_rev = loc.other_rev,
      path = loc.path,
      other_path = loc.other_path ~= loc.path and loc.other_path or nil,
      line_start = s,
      line_end = e,
      code = code,
      context = context,
      commits = commits,
      body = body,
    }
    append(store, c)
    vim.notify(string.format("review: %s saved (%s)", c.id, title))
    M.refresh()
  end)
end

function M.edit()
  with_comment_at_cursor(function(c, store)
    input("Edit " .. c.id, vim.split(c.body or "", "\n"), function(body)
      update(store, c.id, function(x) x.body = body end)
      M.refresh()
    end)
  end)
end

--- Reply to a comment (e.g. answering an agent's question); reopens it.
function M.reply()
  with_comment_at_cursor(function(c, store)
    input("Reply to " .. c.id, nil, function(body)
      update(store, c.id, function(x)
        x.replies = x.replies or {}
        table.insert(x.replies, { by = "user", body = body, at = now() })
        x.status = "open"
      end)
      M.refresh()
    end)
  end)
end

function M.toggle_resolved()
  with_comment_at_cursor(function(c, store)
    update(store, c.id, function(x)
      x.status = x.status == "open" and "resolved" or "open"
    end)
    M.refresh()
  end)
end

function M.delete()
  with_comment_at_cursor(function(c, store)
    if vim.fn.confirm("Delete review comment " .. c.id .. "?", "&Yes\n&No", 2) == 1 then
      update(store, c.id, function() return false end)
      M.refresh()
    end
  end)
end

function M.show()
  with_comment_at_cursor(function(c)
    local lines = {
      string.format("**%s** · %s · %s %s:%d-%d", c.id, c.status, short(c.rev), c.path, c.line_start, c.line_end),
    }
    if c.context then
      table.insert(lines, "in `" .. c.context .. "`")
    end
    if c.commits and #c.commits > 0 then
      table.insert(lines, "commits: " .. table.concat(vim.tbl_map(short, c.commits), ", "))
    end
    table.insert(lines, "")
    vim.list_extend(lines, vim.split(c.body or "", "\n"))
    for _, r in ipairs(c.replies or {}) do
      table.insert(lines, "")
      table.insert(lines, string.format("**%s** (%s)%s:", r.by or "?", r.at or "", r.commit and (" fixed in " .. short(r.commit)) or ""))
      vim.list_extend(lines, vim.split(r.body or "", "\n"))
    end
    vim.lsp.util.open_floating_preview(lines, "markdown", { border = "rounded", focus_id = "agent_review", max_width = 100 })
  end)
end

--- Quickfix list of comments (open only unless all). Entries jump to the
--- working-tree file, which may differ from the reviewed revision.
function M.list(all)
  local loc = locate()
  local top = loc and loc.top or toplevel_for(vim.fn.getcwd())
  local store = top and store_for(top)
  if not store then
    vim.notify("review: not inside a git repo", vim.log.levels.WARN)
    return
  end
  local items = {}
  for _, c in ipairs(load(store)) do
    if all or c.status == "open" then
      table.insert(items, {
        filename = top .. "/" .. c.path,
        lnum = c.line_start or 1,
        end_lnum = c.line_end,
        text = string.format("%s %s%s%s: %s",
          c.id,
          short(c.rev),
          c.status ~= "open" and (" [" .. c.status .. "]") or "",
          c.context and (" " .. c.context) or "",
          first_line(c.body)),
      })
    end
  end
  vim.fn.setqflist({}, " ", { title = "Review comments (" .. store .. ")", items = items })
  if #items == 0 then
    vim.notify("review: no " .. (all and "" or "open ") .. "comments")
  else
    vim.cmd("copen")
  end
end

-- setup ------------------------------------------------------------------------

function M.setup()
  local cmd = api.nvim_create_user_command
  cmd("ReviewComment", function(o) M.add(o.line1, o.line2) end, { range = true, desc = "Add review comment" })
  cmd("ReviewEdit", M.edit, { desc = "Edit review comment under cursor" })
  cmd("ReviewReply", M.reply, { desc = "Reply to review comment under cursor (reopens it)" })
  cmd("ReviewToggle", M.toggle_resolved, { desc = "Toggle resolved on review comment under cursor" })
  cmd("ReviewDelete", M.delete, { desc = "Delete review comment under cursor" })
  cmd("ReviewShow", M.show, { desc = "Show review comment thread under cursor" })
  cmd("ReviewList", function(o) M.list(o.bang) end, { bang = true, desc = "Quickfix list of open (! = all) review comments" })

  local map = vim.keymap.set
  map("n", "<leader>rc", "<Cmd>ReviewComment<CR>", { desc = "Review: comment on line" })
  map("x", "<leader>rc", ":ReviewComment<CR>", { desc = "Review: comment on selection" })
  map("n", "<leader>re", M.edit, { desc = "Review: edit comment" })
  map("n", "<leader>rr", M.reply, { desc = "Review: reply (reopens)" })
  map("n", "<leader>rt", M.toggle_resolved, { desc = "Review: toggle resolved" })
  map("n", "<leader>rd", M.delete, { desc = "Review: delete comment" })
  map("n", "<leader>rs", M.show, { desc = "Review: show thread" })
  map("n", "<leader>rl", function() M.list(false) end, { desc = "Review: list open comments" })
  map("n", "<leader>rL", function() M.list(true) end, { desc = "Review: list all comments" })
  -- discovery next to the other <leader>f pickers: every review keymap
  -- (descs all start with "Review:"); <CR> runs the selected one
  map("n", "<leader>fR", function()
    require("telescope.builtin").keymaps({ modes = { "n", "x" }, default_text = "Review: " })
  end, { desc = "Review keymaps (comments for agents)" })
  local ok, wk = pcall(require, "which-key")
  if ok and wk.add then
    wk.add({ { "<leader>r", group = "review" } })
  end

  local group = api.nvim_create_augroup("agent-review", { clear = true })
  local refresh = function() vim.schedule(function() pcall(M.refresh) end) end
  api.nvim_create_autocmd("User", { group = group, pattern = "DiffviewDiffBufWinEnter", callback = refresh })
  -- FocusGained: pick up comments the agent resolved/replied to meanwhile
  api.nvim_create_autocmd({ "BufWinEnter", "FocusGained" }, { group = group, callback = refresh })
end

return M
