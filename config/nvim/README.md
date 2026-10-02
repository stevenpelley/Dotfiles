# nvim

Neovim configuration optimized for **reading and reviewing code** with full LSP
features — the "VSCode inspection" surface (go-to-definition, references, call
hierarchy, diffs) without the IDE. Plain `nvim` uses this config.

## Requirements

- Neovim **0.12.5**, exactly. `install.sh` pins it (`NVIM_VERSION`) and installs
  the official GitHub release tarball the same way on macOS and Linux —
  `~/.local/opt/nvim-<version>`, symlinked as `~/.local/bin/nvim`. brew/apt
  are not used (brew floats to the newest release, apt lags far behind), and
  any brew/apt nvim is uninstalled so only the pinned one remains.
- `tree-sitter` CLI (pinned `TREE_SITTER_VERSION`, installed by `install.sh`
  into `~/.local/bin`), `curl`, `tar` and a C compiler — nvim-treesitter's
  main branch uses them to build parsers on first run.
- `pyright` + `ruff` (Python), `vtsls` (TypeScript/JS) on PATH — installed
  automatically by `install.sh` (npm / pipx / brew).
- `git` (lazy.nvim clones plugins)
- `lazygit` (optional, for `<leader>gg`)

## Upgrading Neovim

nvim-treesitter's main branch only supports the latest stable Neovim, so bump
both together:

1. Set `NVIM_VERSION` in `install.sh`, run `bash install.sh install`.
2. `nvim --headless "+Lazy! update nvim-treesitter" +qa` (updates
   `lazy-lock.json`; the `:TSUpdate` build hook rebuilds parsers).
3. Verify: `nvim --headless "+checkhealth nvim-treesitter" +qa` shows no
   errors; commit `install.sh` + `lazy-lock.json` together.

The installer leaves the previous `~/.local/opt/nvim-*` directory in place and
prints the `rm -r` command to delete it.

Moving an existing machine off the old pinned `v0.10.0` nvim-treesitter (the
pre-rewrite `master` codebase) leaves its compiled parsers in the plugin
checkout; delete them so only the main-branch parsers in
`~/.local/share/nvim/site/parser` are on the runtimepath:

```bash
rm -r ~/.local/share/nvim/lazy/nvim-treesitter/parser ~/.local/share/nvim/lazy/nvim-treesitter/parser-info
```

## Data paths

| Path | Contents |
|---|---|
| `~/.config/nvim` | this config (symlinked from `~/Dotfiles/config/nvim`) |
| `~/.local/share/nvim` | plugins (`lazy/`), treesitter parsers + queries (`site/`) |
| `~/.local/opt/nvim-<version>` | the pinned Neovim itself (`~/.local/bin/nvim` links here) |
| `~/.local/state/nvim` | shada, undo, logs |

Full reset (config survives, it lives in Dotfiles):

```bash
rm -rf ~/.local/share/nvim ~/.local/state/nvim ~/.cache/nvim
```

## Python and TypeScript environments

- **pyright** prefers the project's own interpreter: `<project root>/.venv/bin/python`
  if present (or `$VIRTUAL_ENV`), so imports resolve against the venv's
  dependencies. Without either, pyright falls back to its default python.
- **vtsls** is the TypeScript analogue and needs no configuration: tsserver
  automatically loads the workspace's own `node_modules/typescript` when
  present, falling back to the globally installed one.
- **ruff** uses the project's own binary when the venv has one
  (`<project root>/.venv/bin/ruff`, version >= 0.5.3), falling back to the
  globally installed ruff. Note the Rust ruff server has no interpreter
  setting — the venv preference is implemented by launching the venv's ruff.
  Ruff itself doesn't resolve imports (that's pyright's job), so this only
  controls which ruff version and configuration engine runs.

## Plugins

| Plugin | Role |
|---|---|
| lazy.nvim | plugin manager; plugins declared in `init.lua`, pinned by `lazy-lock.json` |
| nvim-treesitter (`main` branch, commit pinned in `lazy-lock.json`) | installs parsers/queries; highlighting itself is Neovim's (`vim.treesitter.start` on `FileType`). Supports only the latest stable nvim — bump with `NVIM_VERSION` |
| nvim-lspconfig | server configs; enables `pyright`, `ruff`, `vtsls` |
| blink.cmp | completion (pure-Lua fuzzy, no native build) |
| telescope.nvim | pickers: files, grep, symbols, references, calls, help, keymaps, commands |
| gitsigns.nvim | gutter marks + hunk staging |
| diffview.nvim | commit/history/change-set diff review (`:DiffviewOpen`, `:DiffviewFileHistory`) |
| neo-tree.nvim (`v3.x`) | file-explorer sidebar with git status + diagnostics; follows the current file, watches the filesystem, and replaces netrw for directories (`nvim .`). Deps: nui.nvim, nvim-web-devicons (icons need a Nerd Font — Ghostty's default font includes the glyphs) |
| nvim-window-picker (`2.*`) | in neo-tree, `w` opens the file in a window you pick: each candidate window shows a big floating letter (`F`, `J`, `D`, ...); press it, or `Esc` to cancel. With only one candidate it is used without asking |
| treesitter-context | sticky function/class header |
| which-key.nvim | press `<leader>` (or `g`, `[`, `]`, `<C-w>`) and wait — popup of available bindings |

## Keybindings

`<leader>` is space; press it and pause for the which-key menu.

| Keys | Action |
|---|---|
| `<leader>ff` / `fg` | find files / live grep |
| `<leader>fs` / `fS` | document / workspace symbols |
| `<leader>fr` | references (under cursor) |
| `<leader>fc` / `fC` | incoming / outgoing calls (call hierarchy) |
| `<leader>fd` | diagnostics |
| `<leader>fh` / `fk` / `ft` | search help / keymaps / all commands ("tools") |
| `<leader>fe` | toggle file-explorer sidebar (neo-tree), revealing the current file; `?` inside it lists its keys |
| `<leader>fR` | list the review-comment keymaps (see [below](#review-comments-for-coding-agents)) |
| `<leader>gg` | floating lazygit |
| `<leader>hp` / `hb` | preview hunk / blame line |
| `<leader>hs` / `hr` / `hd` / `hD` | stage / reset hunk, diff file vs index / vs `HEAD~` |
| `]h` / `[h` | next / previous hunk |
| `gd` / `gD` / `K` | definition / declaration / hover (buffer-local, on LSP attach) |
| `gci` / `gco` | incoming / outgoing calls (buffer-local, on LSP attach) |
| `grr` `gri` `grt` `grn` `gra` `grx` `gO` `Ctrl-S` | nvim built-in LSP defaults (references, implementation, type definition, rename, code action, run codelens, document symbols, signature help) |

## Review comments for coding agents

`lua/agent_review.lua` (not a plugin; loaded from `init.lua`) records
line-anchored review comments while you read a diff in diffview (either side,
any revision: `:DiffviewOpen main..HEAD`, `:DiffviewFileHistory`, working
tree) or a plain file buffer. Each comment stores the full commit SHA being
viewed, side, path, line range, the code itself, the enclosing
function/class (treesitter) and the commits that introduced those lines (git
blame), so a whole PR stack can be reviewed in one diff. Then tell the agent
"I've reviewed, address the comments" — the `address-review` skill
(`~/Dotfiles/agents/skills`) reads them, adds a fix commit to the PR branch
each comment belongs to (unless the comment says otherwise), restacks the
branches above it, and replies to each comment.

| Keys / command | Action |
|---|---|
| `<leader>rc` (normal / visual) · `:ReviewComment` | comment on line / selection; float editor, `<C-s>` saves |
| `<leader>rs` · `:ReviewShow` | show the thread (incl. agent replies) |
| `<leader>rr` · `:ReviewReply` | reply (reopens the comment) |
| `<leader>re` / `rt` / `rd` | edit / toggle resolved / delete |
| `<leader>rl` / `rL` · `:ReviewList[!]` | quickfix list of open / all comments |
| `<leader>fR` | discover: telescope list of all review keymaps (`<CR>` runs one); also `<leader>r` + pause for the which-key menu, `<leader>ft` → "Review" for the commands |

Commented lines get a `◆` sign (`◇` once resolved) and the first line of the
comment as virtual text; `[agent replied]` marks open comments the agent
answered with a question. Comments live in `<git-common-dir>/agent-review/comments.jsonl`
— never committed, shared by all worktrees. Line numbers belong to the
reviewed revision, so signs appear when that same revision is shown again.

Workflows worth knowing: run the agent (omp/kiro) in a tmux/zellij pane beside
nvim, then review its changes with `:DiffviewOpen` (or `<leader>gg` in
lazygit). `:Inspect` with the cursor on a token shows exactly what is coloring
it and why. `:h index` lists every built-in key; plugins document themselves
under `:h <plugin>`.

## Deliberate decisions

- `colorscheme vim` — colorful but keeps the terminal's background.
- `diffview.nvim` is eager-loaded so its `:help` tags resolve (telescope lists
  docs from lazy-loaded plugins, but `:help` can't open them until load).
- Absolute line numbers (no `relativenumber`).
- File explorer is a neo-tree **sidebar**, not a float (preference). netrw
  stays installed but is hijacked for directory buffers; `:Ex` still works as
  a fallback during the neo-tree trial.
- LSP `gd/gD/K` are mapped on `LspAttach`, so buffers without a language
  server keep vim's built-in `gd`/`K` behavior.

The `init.lua` comments explain each section; `lazy-lock.json` pins exact
plugin versions for reproducibility.
