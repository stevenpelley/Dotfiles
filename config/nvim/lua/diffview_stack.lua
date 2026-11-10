-- :DiffviewStack — review a stack of branches (one PR each) the way GitHub
-- shows them: one diffview tab per branch, each diffing the branch against
-- the branch below it (`parent...branch`, i.e. against their merge-base), so
-- every tab is the collapsed diff of that PR. gt / gT move between PRs.
--
--   :DiffviewStack [--create-envs] [base] [top]
--   :DiffviewStackClean[!]
--
-- base defaults to main (or master), top to HEAD. The stack is every local
-- branch whose tip lies on base..top, ordered bottom to top; a top that is
-- not itself a branch tip (detached HEAD, commits above the last branch)
-- gets its own final tab.
--
-- LSP only attaches to working-tree buffers, never to diffview's revision
-- buffers. So every PR gets a working tree of its own and its tab is opened
-- with --imply-local, making the right side real files:
--   * the PR checked out in the current worktree uses that worktree;
--   * every other PR gets a review worktree at a *detached* HEAD in
--     <stdpath("cache")>/diffview-stack/<repo>/<branch>. Detached, so the
--     branches stay free to be checked out elsewhere and
--     `git rebase --update-refs` still moves them. Re-running :DiffviewStack
--     moves each review worktree to its branch's current tip (worktrees with
--     uncommitted changes to tracked files are left alone, with a warning).
--
-- Dependencies: by default the current worktree's venv (UV_PROJECT_ENVIRONMENT,
-- else .venv) and node_modules are symlinked into each review worktree. A PR
-- that changes dependencies then resolves against the wrong versions;
-- --create-envs instead installs them per worktree from that PR's lockfile
-- (uv sync --frozen; npm ci / pnpm / yarn --frozen-lockfile), replacing the
-- symlinks. Installs are re-run only when the lockfile changed.
--
-- :DiffviewStackClean closes the stack's tabs, stops their LSP clients and
-- removes every review worktree of the repository (asks first if one has
-- uncommitted changes; ! skips the question).

local M = {}

local api = vim.api
local STAMP = ".diffview-stack-lock"

local function git(cwd, args)
  local cmd = { "git" }
  if cwd then
    vim.list_extend(cmd, { "-C", cwd })
  end
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { text = true }):wait()
  if res.code ~= 0 then
    return nil, vim.trim(res.stderr or "")
  end
  return vim.trim(res.stdout or "")
end

local function lines(s)
  return vim.split(s or "", "\n", { trimempty = true })
end

local function warn(msg)
  vim.notify("DiffviewStack: " .. msg, vim.log.levels.WARN)
end

local function real(p)
  return vim.uv.fs_realpath(p) or p
end

local function under(path, root)
  path, root = real(path), real(root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

-- repository and review-worktree locations -------------------------------------

local function repo_info()
  local top = git(nil, { "-C", vim.fn.getcwd(), "rev-parse", "--show-toplevel" })
  if not top then
    return nil
  end
  local common = git(top, { "rev-parse", "--path-format=absolute", "--git-common-dir" })
  -- name the cache dir after the main worktree (".../repo/.git" -> "repo"),
  -- plus a hash so equally named repositories do not collide
  local name = vim.fs.basename(common) == ".git" and vim.fs.basename(vim.fs.dirname(common))
    or vim.fs.basename(common)
  local root = vim.fn.stdpath("cache") .. "/diffview-stack/" .. name .. "-" .. vim.fn.sha256(common):sub(1, 8)
  return { top = top, root = root }
end

-- dependency environments --------------------------------------------------------

local function venv_name()
  local e = vim.env.UV_PROJECT_ENVIRONMENT
  if e and e:sub(1, 1) == "/" then
    return nil -- one shared absolute venv: nothing per worktree
  end
  return ((e or ".venv"):gsub("^%./", ""))
end

-- marker: only environments of projects that have it are linked/created
local function env_specs()
  local specs = {
    {
      dir = "node_modules",
      marker = "package.json",
      installers = {
        { lock = "package-lock.json", cmd = { "npm", "ci", "--no-audit", "--no-fund" } },
        { lock = "pnpm-lock.yaml", cmd = { "pnpm", "install", "--frozen-lockfile" } },
        { lock = "yarn.lock", cmd = { "yarn", "install", "--frozen-lockfile" } },
      },
    },
  }
  local venv = venv_name()
  if venv then
    table.insert(specs, 1, {
      dir = venv,
      marker = "pyproject.toml",
      installers = { { lock = "uv.lock", cmd = { "uv", "sync", "--frozen" } } },
    })
  end
  return specs
end

local function read_file(p)
  local f = io.open(p, "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function link_env(top, wt, spec)
  local src, dst = top .. "/" .. spec.dir, wt .. "/" .. spec.dir
  if vim.uv.fs_lstat(dst) or not vim.uv.fs_stat(src) then
    return -- keep whatever is there (symlink or an env created earlier)
  end
  local ok, err = vim.uv.fs_symlink(src, dst)
  if not ok then
    warn(("cannot link %s: %s"):format(dst, err))
  end
end

local function create_env(top, wt, spec, label)
  local inst
  for _, i in ipairs(spec.installers) do
    if vim.uv.fs_stat(wt .. "/" .. i.lock) then
      inst = i
      break
    end
  end
  if not inst then
    warn(("%s: no lockfile for %s; linked instead"):format(label, spec.dir))
    return link_env(top, wt, spec)
  end
  if vim.fn.executable(inst.cmd[1]) == 0 then
    warn(("%s: %s not found; %s linked instead"):format(label, inst.cmd[1], spec.dir))
    return link_env(top, wt, spec)
  end
  local dst = wt .. "/" .. spec.dir
  local st = vim.uv.fs_lstat(dst)
  if st and st.type == "link" then
    vim.uv.fs_unlink(dst) -- the link only, never its target
  end
  local stamp = (git(wt, { "hash-object", inst.lock }) or "") .. " " .. table.concat(inst.cmd, " ")
  if read_file(dst .. "/" .. STAMP) == stamp then
    return
  end
  vim.notify(("DiffviewStack: %s: %s ..."):format(label, table.concat(inst.cmd, " ")))
  vim.cmd.redraw()
  local res = vim.system(inst.cmd, { cwd = wt, text = true }):wait()
  if res.code ~= 0 then
    local err = vim.trim((res.stderr or "") ~= "" and res.stderr or res.stdout or "")
    warn(("%s: %s failed:\n%s"):format(label, table.concat(inst.cmd, " "), err:sub(-800)))
    return
  end
  if vim.uv.fs_stat(dst) then
    local f = io.open(dst .. "/" .. STAMP, "w")
    if f then
      f:write(stamp)
      f:close()
    end
  end
end

local function prepare_envs(top, wt, create, label)
  for _, spec in ipairs(env_specs()) do
    if vim.uv.fs_stat(wt .. "/" .. spec.marker) then
      if create then
        create_env(top, wt, spec, label)
      else
        link_env(top, wt, spec)
      end
    end
  end
end

-- review worktrees -----------------------------------------------------------------

---@return string? path, string? err
local function prepare_worktree(repo, b, create_envs)
  local path = repo.root .. "/" .. (b.name:gsub("/", "%%"))
  if vim.uv.fs_stat(path) then
    local wt_top = git(path, { "rev-parse", "--show-toplevel" })
    if not wt_top or real(wt_top) ~= real(path) then
      return nil, path .. " exists but is not a git worktree"
    end
    local cur = git(path, { "rev-parse", "HEAD" })
    if cur ~= b.sha then
      -- untracked files are ignored: the env symlinks are always untracked
      local dirty = git(path, { "status", "--porcelain", "--untracked-files=no" })
      if dirty ~= "" then
        return nil, ("%s has uncommitted changes; left at %s"):format(path, (cur or "?"):sub(1, 8))
      end
      local _, err = git(path, { "checkout", "--quiet", "--detach", b.sha })
      if err then
        return nil, err
      end
    end
  else
    git(repo.top, { "worktree", "prune" }) -- forget worktrees deleted by hand
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local _, err = git(repo.top, { "worktree", "add", "--quiet", "--detach", path, b.sha })
    if err then
      return nil, err
    end
  end
  prepare_envs(repo.top, path, create_envs, b.name)
  return path
end

-- the stack ------------------------------------------------------------------------

-- diffview's synchronous git calls sometimes lose their stdout when other
-- jobs are running (the process-exit callback closes the pipe before the
-- output is read), so creating a view intermittently fails with e.g. "Could
-- not find the Git directory!". Retry, showing only the last attempt's error.
local function open_view(lib, args)
  local utils = require("diffview.utils")
  local err = utils.err
  for attempt = 1, 4 do
    if attempt < 4 then
      utils.err = function() end
    end
    local ok, view = pcall(lib.diffview_open, args)
    utils.err = err
    if ok and view then
      return view
    end
    vim.wait(50 * attempt)
  end
end

local function default_base(top)
  for _, b in ipairs({ "main", "master" }) do
    if git(top, { "rev-parse", "--verify", "--quiet", "refs/heads/" .. b }) then
      return b
    end
  end
end

---@return { name: string, sha: string }[]? stack bottom to top
---@return string? err
function M.branches(top, base, tip)
  local range, err = git(top, { "rev-list", "--topo-order", "--reverse", base .. ".." .. tip })
  if not range then
    return nil, err
  end
  local commits = lines(range)
  if #commits == 0 then
    return nil, ("no commits in %s..%s"):format(base, tip)
  end

  local current = git(top, { "symbolic-ref", "--quiet", "--short", "HEAD" })
  local at = {} -- sha -> branch names
  for _, l in ipairs(lines(git(top, { "for-each-ref", "--format=%(objectname) %(refname:short)", "refs/heads" }))) do
    local sha, name = l:match("^(%x+) (.+)$")
    if sha then
      at[sha] = at[sha] or {}
      table.insert(at[sha], name)
    end
  end

  local stack, dupes = {}, {}
  for _, sha in ipairs(commits) do
    local names = at[sha]
    if names then
      table.sort(names)
      -- several branches on one commit: prefer the checked-out one
      local pick = vim.tbl_contains(names, current) and current or names[1]
      if #names > 1 then
        table.insert(dupes, table.concat(names, "/") .. " -> " .. pick)
      end
      table.insert(stack, { name = pick, sha = sha })
    end
  end
  local tip_sha = commits[#commits]
  if #stack == 0 or stack[#stack].sha ~= tip_sha then
    table.insert(stack, { name = tip, sha = tip_sha })
  end
  if #dupes > 0 then
    warn("branches sharing a commit: " .. table.concat(dupes, ", "))
  end
  return stack
end

---@param opts { base?: string, tip?: string, create_envs?: boolean }
function M.open(opts)
  opts = opts or {}
  local repo = repo_info()
  if not repo then
    vim.notify("DiffviewStack: not inside a git repository", vim.log.levels.ERROR)
    return
  end
  local base = opts.base or default_base(repo.top)
  if not base then
    vim.notify("DiffviewStack: no main/master branch; pass the base explicitly", vim.log.levels.ERROR)
    return
  end
  local tip = opts.tip or "HEAD"
  local stack, err = M.branches(repo.top, base, tip)
  if not stack then
    vim.notify("DiffviewStack: " .. err, vim.log.levels.ERROR)
    return
  end

  local head = git(repo.top, { "rev-parse", "HEAD" })
  local lib = require("diffview.lib")
  local first, labels = nil, {}
  local parent = base
  for i, b in ipairs(stack) do
    local label = ("%d %s...%s"):format(i, parent, b.name)
    local args = { parent .. "..." .. b.name }
    if b.sha == head then
      vim.list_extend(args, { "-C" .. repo.top, "--imply-local" })
      label = label .. " (this worktree)"
    else
      local wt, werr = prepare_worktree(repo, b, opts.create_envs)
      if wt then
        -- untracked: the env symlinks are not matched by `.venv/`-style ignores
        vim.list_extend(args, { "-C" .. wt, "--imply-local", "--untracked-files=no" })
      else
        warn(("%s: %s; tab opened without LSP"):format(b.name, werr))
        table.insert(args, "-C" .. repo.top)
        label = label .. " (no LSP)"
      end
    end
    local view = open_view(lib, args)
    if not view then
      label = label .. " (FAILED to open)"
    else
      view:open()
      first = first or view.tabpage
      -- let this view's first file update finish before starting the next
      vim.wait(10000, function() return view.initialized end, 10)
    end
    table.insert(labels, label)
    parent = b.name
  end
  if first then
    api.nvim_set_current_tabpage(first)
  end
  vim.notify("DiffviewStack (gt / gT between PRs):\n" .. table.concat(labels, "\n"))
end

-- cleanup ----------------------------------------------------------------------------

function M.clean(force)
  local repo = repo_info()
  if not repo then
    vim.notify("DiffviewStack: not inside a git repository", vim.log.levels.ERROR)
    return
  end
  local wts = {}
  for _, l in ipairs(lines(git(repo.top, { "worktree", "list", "--porcelain" }))) do
    local p = l:match("^worktree (.+)$")
    if p and under(p, repo.root) then
      table.insert(wts, p)
    end
  end

  local dirty = vim.tbl_filter(function(p)
    local s = git(p, { "status", "--porcelain", "--untracked-files=no" })
    return s ~= nil and s ~= ""
  end, wts)
  if #dirty > 0 and not force then
    local msg = "Review worktrees with uncommitted changes will be lost:\n" .. table.concat(dirty, "\n") .. "\nRemove anyway?"
    if vim.fn.confirm(msg, "&Yes\n&No", 2) ~= 1 then
      return
    end
  end

  -- close the diffview tabs, buffers and LSP clients that use the worktrees
  local lib = require("diffview.lib")
  for _, view in ipairs(vim.list_slice(lib.views)) do
    local t = view.adapter and view.adapter.ctx.toplevel
    if t and under(t, repo.root) then
      view:close()
      lib.dispose_view(view)
    end
  end
  for _, client in ipairs(vim.lsp.get_clients()) do
    if client.root_dir and under(client.root_dir, repo.root) then
      client:stop(true)
    end
  end
  for _, buf in ipairs(api.nvim_list_bufs()) do
    local name = api.nvim_buf_get_name(buf)
    if name ~= "" and name:sub(1, 1) == "/" and under(name, repo.root) then
      if not pcall(api.nvim_buf_delete, buf, {}) then
        warn("kept modified buffer " .. name)
      end
    end
  end

  local removed = 0
  for _, p in ipairs(wts) do
    local _, err = git(repo.top, { "worktree", "remove", "--force", p })
    if err then
      warn(("cannot remove %s: %s"):format(p, err))
    else
      removed = removed + 1
    end
  end
  git(repo.top, { "worktree", "prune" })
  vim.fn.delete(repo.root, "d") -- only if empty
  vim.notify(("DiffviewStack: removed %d review worktree(s)"):format(removed))
end

function M.setup()
  vim.api.nvim_create_user_command("DiffviewStack", function(o)
    local opts, pos = {}, {}
    for _, a in ipairs(o.fargs) do
      if a == "--create-envs" then
        opts.create_envs = true
      elseif a:sub(1, 2) == "--" then
        vim.notify("DiffviewStack: unknown option " .. a, vim.log.levels.ERROR)
        return
      else
        table.insert(pos, a)
      end
    end
    opts.base, opts.tip = pos[1], pos[2]
    M.open(opts)
  end, {
    nargs = "*",
    complete = function(lead)
      local items = { "--create-envs" }
      vim.list_extend(items, vim.fn.systemlist({ "git", "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes" }))
      return vim.tbl_filter(function(b) return b:find(lead, 1, true) == 1 end, items)
    end,
    desc = "Diffview tab per PR of the stack, each with its own worktree: [--create-envs] [base] [top]",
  })
  vim.api.nvim_create_user_command("DiffviewStackClean", function(o)
    M.clean(o.bang)
  end, { bang = true, desc = "Remove the DiffviewStack review worktrees (! = even with uncommitted changes)" })
end

return M
