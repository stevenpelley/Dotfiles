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
- `config/bash/env` — PATH and other exports, sourced by `bash_profile` (every
  login shell, interactive or not: `su -l`, `bash -l -c`) and by
  `config/bash/bashrc`; idempotent. `bashrc` keeps its interactive guard, so
  anything a script or kit hook needs belongs in `env`, not `bashrc`
- `install.sh` — `link` (symlinks), `install` (tooling: zellij, lefthook, oh-my-bash, pipx tools), `all`
- `sbx/dotfiles/dotfiles.yaml` — Docker Sandboxes **v3** mixin kit
  (thin-kit pattern, declaration-only): its install hook clones this repo
  into `/home/agent/Dotfiles` and runs `install.sh all` as the `agent` user;
  a startup hook re-runs `install.sh link` every boot (log:
  `~/.cache/dotfiles-link.log`).
  No files are duplicated — the repo stays the single source of truth.
  `sbxenv.yaml` is the user-home env file for Docker Sandboxes, linked as
  `~/.sbxenv.yaml` (the sandbox only reads the dot-prefixed name — it is not
  picked up as `~/sbxenv.yaml`); it references the kit as
  `git+https://github.com/stevenpelley/Dotfiles#ref=main&dir=sbx/dotfiles`.
- The kit follows the [v3 spec](https://github.com/docker/sandbox-kit-spec).
  v3 kits compose only with a v3 workload (e.g. `docker.io/docker/sbx-kit-kiro`)
  and v3 mixins — not with built-in agent shortcuts like `kiro`. Validate with
  `docker buildx build sbx/dotfiles -f sbx/dotfiles/dotfiles.yaml --output
  type=cacheonly` (`sbx kit validate` does not accept v3 source kits; use
  `sbx kit inspect ./sbx/dotfiles` host-side).
- `config/nvim` — Neovim config for LSP-based code reading; plain `nvim`
  uses it (this used to be the `config/nvim-trial` experiment). See its
  README and the comments in `init.lua`
- `config/nvim/lua/agent_review.lua` — review comments recorded in
  diffview, stored in `<git-common-dir>/agent-review/comments.jsonl`; its
  schema is shared with `agents/skills/address-review/scripts/review.py`
  — change both together
- `agents/skills/<name>/` — Agent Skills, symlinked per skill by
  `install.sh link`/`skills` into each detected harness (`agent_targets`)
- `agents/instructions.md` — user-level agent instructions, linked by
  `install.sh link`/`instructions` into the same harnesses
  (`link_agent_instructions`): a file in Kiro's global steering dir and
  Claude's `~/.claude/rules/` and omp's `~/.omp/agent/rules/` (always
  applied via the file's frontmatter), otherwise the harness's single user
  `AGENTS.md`. Never link omp's `~/.omp/agent/AGENTS.md`: in a Docker sandbox
  the runtime writes the kit guidance there
- `agents/skills/sbx-mcp-client/scripts/mcpcli` — MCP client for the sbx MCP
  gateway (python SDK `mcp==2.3.0`, venv created on first run in
  `~/.cache/mcpcli`); `aws-mcp` skill holds the AWS MCP / Logs Insights cost
  rules that its `logs` subcommand enforces — keep them in sync. Keep
  account IDs and org-specific profile names out (this repo is public)
- `bin/<name>` — scripts, copied by `install.sh link`/`scripts` to
  `~/.local/share/dotfiles/bin/` and linked from `~/.local/bin/`
  (`install_scripts`). Copied, not linked into the repo, because programs
  run some of them with the user's credentials; re-run after editing.
  `bin/aws-mcp-proxy` — `mcp-proxy-for-aws-cli` (uv inline-script deps,
  pinned) that still starts when the AWS profile's SSO login has expired:
  with `--skip-auth`, requests go unsigned until `aws sso login`. It patches
  an internal of the proxy, so re-test before bumping the pin (verify with a
  fake SSO profile and an expired token cache: initialize, tools/list)
- `agents/claude/statusline.sh` — Claude Code status line (oh-my-bash
  `vscode` prompt + model, context, rate limits), linked by `install.sh link`
  as `~/.claude/statusline-command.sh` (`link_claude_statusline`); needs `jq`
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
  - agent_review: script a temp repo + `DiffviewOpen` headless; wait for
    `view.cur_layout:is_files_loaded()` and invoke the float's `<C-S>`
    buffer-map callback to submit (diffview loads asynchronously)
  - skill/instruction links: run `link_agent_skills` and
    `link_agent_instructions` with `HOME` pointed at a temp dir
  - mcpcli: `python3 -m py_compile` and `mcpcli --help` (no gateway needed)
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
  verbatim. Intentional customizations: in `normal` mode,
  `Alt+g` → `Write 7` (passes Ctrl+G to the focused pane so coding agents can
  open their prompt editor), deliberately **not** bound in `locked` mode; and
  nested-session navigation — `Alt+u`/`Alt+m` (`FocusHostSession`/
  `FocusGuestSession`) in `normal`+`locked`, plus `nested_session_handling
  "descend"`. Keep Alt chords on the right hand (the user holds Alt with the
  left); `Alt+n` is taken by `NewPane`.
- nvim (since 0.11) sends LSP `settings` via `workspace/didChangeConfiguration` after
  initialize — mutating initialize params in `before_init` is a no-op. To
  affect server settings (e.g. pyright's `pythonPath`), mutate
  `client.config.settings` in `on_init`.
- nvim 0.12's default LSP maps are `grn/gra/grr/gri/grt/grx/gO/Ctrl-S` only;
  `gd`/`gD`/`K`/`gci`/`gco` are mapped buffer-locally on `LspAttach` in
  `config/nvim`. which-key only lists mappings — built-in vim commands never
  appear in its menus.
- `~/.claude/settings.json` is **not** symlinked: Claude Code rewrites it
  (`/config`, theme, permission approvals), so a linked copy would churn and
  leak per-machine settings. `link_claude_statusline` merges only the
  `statusLine` key with `jq`, preserving everything else.
- Every `apt-get` invocation must include `-o DPkg::Lock::Timeout=10` so apt
  waits for the package lock instead of failing.
- Any new download host used by `install.sh` must be added to **both** the
  `install.allow` and `runtime.allow` lists of the `network-policy@1`
  capability in `sbx/dotfiles/dotfiles.yaml` (currently github.com,
  api.github.com, objects.githubusercontent.com, release-assets.githubusercontent.com,
  codeload.github.com, raw.githubusercontent.com, pypi.org, files.pythonhosted.org,
  registry.npmjs.org, cli.github.com; plus the Ubuntu apt mirrors for install only) or provisioning
  fails on fresh sandboxes. Kit install hooks run as **root** — anything
  that must land in `/home/agent` goes through `su -l agent -c '...'`.

## Conventions

- Commits: short imperative subjects, prefixed by the config when relevant
  (e.g. `nvim: ...`, `zellij: ...`).
- Commit to `main`; push only when the user asks.
- The user reviews diffs and tests interactively — keep changes minimal and
  verifiable, and prefer headless verification over launching UIs.
