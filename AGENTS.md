# AGENTS.md

Context for coding agents working in this repository.

## What this repo is

Symlink-based dotfiles (`install.sh`). The symlinks point from `$HOME` into
this repo, so **edits here are live** in the user's shells/editors/zellij as
soon as files exist (new files additionally need `bash install.sh link`).
Environments: macOS host, and the `omp-playground` sandbox (arm64 Linux, PID 1
is `tini`, sudo available, no systemd/logind — background processes survive
ssh disconnects but not VM restarts).

## Layout

- `bashrc`, `bash_profile`, `vimrc` — linked into `$HOME`
- `install.sh` — `link` (symlinks), `install` (tooling: zellij, oh-my-bash, pipx tools), `all`
- `config/bash`, `config/fish` — shell setup; `nvtrial` alias defined here
- `config/nvim` — legacy bridge (`init.vim` sources `~/.vimrc`); do not extend it
- `config/nvim-trial` — experimental Neovim config, isolated via
  `NVIM_APPNAME=nvim-trial`; see its README and the comments in `init.lua`
- `config/zellij` — Zellij config

## Commands and verification

- `bash install.sh link` — re-run after adding files; moves pre-existing files
  to `~/Dotfiles_old` / `~/Config_old`
- `bash install.sh install` — tooling; idempotent-ish (zellij install is
  skipped if already on PATH)
- Verify before committing:
  - shells: `bash -n install.sh` (syntax) and `bash -i -c 'echo ok'` (sources cleanly)
  - nvim-trial: `NVIM_APPNAME=nvim-trial nvim --headless +qa` (config loads)
  - zellij: `zellij setup --check`

## Gotchas (all learned the hard way — see git log)

- `install.sh link` **moves** pre-existing files into the backup dirs; it is
  also killed by SIGPIPE if piped into `head` — capture output to a file.
- The oh-my-bash installer **replaces the `~/.bashrc` symlink** with a real
  file. Always re-run `link` after running `install` (this is why `all` exists).
- The agent's shell often runs **inside the user's zellij session**
  (`ZELLIJ_SESSION_NAME` etc. are set). Unset those vars when launching zellij
  in tests, otherwise CLI invocations route into the user's live session
  (e.g. `zellij --layout X` becomes "add tab to current session").
- `config/nvim-trial/init.lua` pins `nvim-treesitter` to `v0.10.0` because the
  plugin's main branch requires Neovim 0.12 while apt/brew ship 0.11. Don't
  remove the pin unless the target nvim is ≥ 0.12; the config has a fallback
  path for the modern treesitter API.
- `config/zellij/config.kdl` is the upstream `unlock-first` keybind preset
  (zellij v0.45.1, `default-plugins/configuration/src/presets.rs`) materialized
  verbatim. The only intentional customization is in `normal` mode:
  `Alt+g` → `Write 7` (passes Ctrl+G to the focused pane so coding agents can
  open their prompt editor). It is deliberately **not** bound in `locked` mode.
- nvim 0.11's default LSP maps are `grn/gra/grr/gri/grt/gO/Ctrl-S` only;
  `gd`/`gD`/`K`/`gci`/`gco` are mapped buffer-locally on `LspAttach` in the
  trial config. which-key only lists mappings — built-in vim commands never
  appear in its menus.

## Conventions

- Commits: short imperative subjects, prefixed by the config when relevant
  (e.g. `nvim-trial: ...`, `zellij: ...`).
- Commit to `master`; push only when the user asks.
- The user reviews diffs and tests interactively — keep changes minimal and
  verifiable, and prefer headless verification over launching UIs.
