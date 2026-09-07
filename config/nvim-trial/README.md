# nvim-trial

An isolated Neovim configuration optimized for **reading and reviewing code**
with full LSP features — the "VSCode inspection" surface (go-to-definition,
references, call hierarchy, diffs) without the IDE. It runs beside your
existing setup without touching it.

## Launch

```bash
nvtrial            # alias: NVIM_APPNAME=nvim-trial nvim
```

Everything is namespaced under `NVIM_APPNAME=nvim-trial`:

| Path | Contents |
|---|---|
| `~/.config/nvim-trial` | this config (symlinked from `~/Dotfiles/config/nvim-trial`) |
| `~/.local/share/nvim-trial` | plugins (lazy.nvim), treesitter parsers |
| `~/.local/state/nvim-trial` | shada, undo, logs |

Full reset (config survives, it lives in Dotfiles):

```bash
rm -rf ~/.local/share/nvim-trial ~/.local/state/nvim-trial ~/.cache/nvim-trial
```

## Requirements

- Neovim **>= 0.11** (uses native `vim.lsp.config`/`vim.lsp.enable`).
  `install.sh` installs a pinned nvim 0.11 release into `~/.local` on Linux
  (apt ships < 0.11 on many distros); brew on macOS.
- `pyright` + `ruff` (Python), `vtsls` (TypeScript/JS) on PATH — installed
  automatically by `install.sh` (npm / pipx / brew).
- `git` and a C compiler (treesitter compiles parsers on first run)
- `lazygit` (optional, for `<leader>gg`)

## Python and TypeScript environments

- **pyright** prefers the project's own interpreter: `<project root>/.venv/bin/python`
  if present (or `$VIRTUAL_ENV`), so imports resolve against the venv's
  dependencies. Without either, pyright falls back to its default python.
- **vtsls** is the TypeScript analogue and needs no configuration: tsserver
  automatically loads the workspace's own `node_modules/typescript` when
  present, falling back to the globally installed one.

## Plugins

| Plugin | Role |
|---|---|
| lazy.nvim | plugin manager; plugins declared in `init.lua`, pinned by `lazy-lock.json` |
| nvim-treesitter (pinned v0.10.0) | syntax highlighting + structural navigation. Main branch needs nvim 0.12+ — do not unpin on 0.11 |
| nvim-lspconfig | server configs; enables `pyright`, `ruff`, `vtsls` |
| blink.cmp | completion (pure-Lua fuzzy, no native build) |
| telescope.nvim | pickers: files, grep, symbols, references, calls, help, keymaps, commands |
| gitsigns.nvim | gutter marks + hunk staging |
| diffview.nvim | commit/history/change-set diff review (`:DiffviewOpen`, `:DiffviewFileHistory`) |
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
| `<leader>fe` | floating file explorer (netrw) |
| `<leader>gg` | floating lazygit |
| `<leader>hp` / `hb` | preview hunk / blame line |
| `<leader>hs` / `hr` / `hd` / `hD` | stage / reset hunk, diff file vs index / vs `HEAD~` |
| `]h` / `[h` | next / previous hunk |
| `gd` / `gD` / `K` | definition / declaration / hover (buffer-local, on LSP attach) |
| `gci` / `gco` | incoming / outgoing calls (buffer-local, on LSP attach) |
| `grr` `gri` `grt` `grn` `gra` `gO` `Ctrl-S` | nvim 0.11 built-in LSP defaults (references, implementation, type definition, rename, code action, document symbols, signature help) |

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
- LSP `gd/gD/K` are mapped on `LspAttach`, so buffers without a language
  server keep vim's built-in `gd`/`K` behavior.

The `init.lua` comments explain each section; `lazy-lock.json` pins exact
plugin versions for reproducibility.
