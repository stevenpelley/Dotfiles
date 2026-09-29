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

- `bashrc`, `bash_profile`, `vimrc`, `sbxenv.yaml` — linked into `$HOME`
- `install.sh` — `link` (symlinks), `install` (tooling: zellij, lefthook, oh-my-bash, pipx tools), `all`
- `spec.yaml` — Docker Sandboxes mixin kit (thin-kit pattern): its install
  command clones this repo into `/home/agent/Dotfiles` and runs `install.sh
  all` as the `agent` user. No files are duplicated — the repo stays the
  single source of truth. `sbxenv.yaml` is the user-home env file for
  Docker Sandboxes, linked as `~/.sbxenv.yaml` (the sandbox only reads
  the dot-prefixed name — it is not picked up as `~/sbxenv.yaml`).
- Docker's kit-reference and kit-examples doc pages are 404s; the working
  schema came from `docker/sbx-kits-contrib` on GitHub (`schemaVersion: "2"`,
  `kind: mixin`, ...). Validate with `sbx kit validate .` (host-side).
- `config/nvim` — Neovim config for LSP-based code reading; plain `nvim`
  uses it (this used to be the `config/nvim-trial` experiment). See its
  README and the comments in `init.lua`
- `config/zellij` — Zellij config
- `config/ghostty` — Ghostty terminal config

## Commands and verification

- `bash install.sh link` — re-run after adding files; moves pre-existing files
  to `~/Dotfiles_old` / `~/Config_old`
- `bash install.sh install` — tooling; idempotent-ish (zellij install is
  skipped if already on PATH)
- Verify before committing:
  - shells: `bash -n install.sh` (syntax) and `bash -i -c 'echo ok'` (sources cleanly)
  - nvim: `nvim --headless +qa` (config loads)
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
- Neovim is pinned to one exact release (`NVIM_VERSION` in `install.sh`,
  currently v0.12.5) and installed **identically on macOS and Linux** from the
  official GitHub release tarball into `~/.local/opt/nvim-<version>`, with
  `~/.local/bin/nvim` symlinked to it. brew/apt are deliberately not used:
  brew floats to the newest release (this caused a macOS-only
  `vim.lsp.with() is deprecated` warning while Linux was pinned to 0.11.6) and
  apt ships ancient versions. `remove_other_nvims` uninstalls brew/apt nvim
  automatically and prints manual instructions for anything else (snap,
  AppImage, ...); old `~/.local/opt/nvim*` dirs are reported, not deleted.
- `config/nvim` tracks nvim-treesitter's `main` branch (the rewrite), pinned
  by commit in `lazy-lock.json`. It supports only the latest stable nvim, so
  bump `NVIM_VERSION` and that commit **together** (`Lazy! update
  nvim-treesitter`, then `checkhealth nvim-treesitter`). It needs the
  tree-sitter CLI (`TREE_SITTER_VERSION` in `install.sh`, official release
  binary — nvim-treesitter does not support the npm package), curl, tar and a
  C compiler, and downloads parser sources from `codeload.github.com`.
  Machines coming from the old `v0.10.0` pin keep stale parsers in the plugin
  checkout (`lazy/nvim-treesitter/parser{,-info}`) — delete them.
- `config/zellij/config.kdl` is the upstream `unlock-first` keybind preset
  (zellij v0.45.1, `default-plugins/configuration/src/presets.rs`) materialized
  verbatim. The only intentional customization is in `normal` mode:
  `Alt+g` → `Write 7` (passes Ctrl+G to the focused pane so coding agents can
  open their prompt editor). It is deliberately **not** bound in `locked` mode.
- nvim (since 0.11) sends LSP `settings` via `workspace/didChangeConfiguration` after
  initialize — mutating initialize params in `before_init` is a no-op. To
  affect server settings (e.g. pyright's `pythonPath`), mutate
  `client.config.settings` in `on_init`.
- nvim 0.12's default LSP maps are `grn/gra/grr/gri/grt/grx/gO/Ctrl-S` only;
  `gd`/`gD`/`K`/`gci`/`gco` are mapped buffer-locally on `LspAttach` in
  `config/nvim`. which-key only lists mappings — built-in vim commands never
  appear in its menus.
- Every `apt-get` invocation must include `-o DPkg::Lock::Timeout=10` so apt
  waits for the package lock instead of failing.
- Any new download host used by `install.sh` must be added to the
  `permissions.network.allow` list in `spec.yaml` (currently github.com,
  api.github.com, objects.githubusercontent.com, release-assets.githubusercontent.com,
  codeload.github.com, raw.githubusercontent.com, pypi.org, files.pythonhosted.org,
  registry.npmjs.org) or provisioning
  fails on fresh sandboxes. Kit install commands run as **root** — anything
  that must land in `/home/agent` goes through `su -l agent -c '...'`.

## Conventions

- Commits: short imperative subjects, prefixed by the config when relevant
  (e.g. `nvim: ...`, `zellij: ...`).
- Commit to `main`; push only when the user asks.
- The user reviews diffs and tests interactively — keep changes minimal and
  verifiable, and prefer headless verification over launching UIs.
