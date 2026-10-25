Dotfiles
========

Personal dotfiles installed as symlinks. Deployed on the macOS host and in the
`omp-playground` sandbox (arm64 Linux); edits in this repo take effect in the
linked environments directly.

Usage
-----

```bash
git clone https://github.com/stevenpelley/Dotfiles ~/Dotfiles
bash ~/Dotfiles/install.sh all
```

| Command | What it does |
|---|---|
| `bash install.sh link` | Backs up any existing dotfiles to `~/Dotfiles_old` and `~/Config_old`, then symlinks home files and `~/.config/*` into this repo, and links agent skills and instructions (below). Safe to re-run — do it after adding files here. |
| `bash install.sh skills` | Only the agent-skill links. |
| `bash install.sh instructions` | Only the agent-instructions links. |
| `bash install.sh install` | Installs tooling: Neovim pinned to an exact release (`NVIM_VERSION`) plus the tree-sitter CLI, installed identically on macOS and Linux from GitHub release tarballs into `~/.local` (any brew/apt nvim is uninstalled; see [config/nvim/README.md](config/nvim/README.md)), the LSP servers, [zellij](https://zellij.dev) (brew on macOS; on Linux the static musl binary from GitHub releases into `~/.local/bin`), lefthook, oh-my-bash, and pipx tools (`jc`, `jello`, `jellex`). |
| `bash install.sh all` | `install` then `link`, in that order. |

Order matters: the oh-my-bash installer replaces `~/.bashrc` with its own file,
so `link` must run *after* it — which is why `all` exists. Re-run `link`
any time the installer or a tool has clobbered a symlink.

What gets linked
----------------

Home files (as `~/.<name>`):

- `bashrc` — entry point; sources `~/.config/bash/oh-my-bash` and `~/.config/bash/bashrc`
- `bash_profile` — sources `~/.bashrc` for login shells
- `vimrc` — the long-standing plain-vim setup

`~/.config` directories (each symlinked from `config/`):

| Directory | Purpose |
|---|---|
| `config/bash` | oh-my-bash bootstrap + interactive bashrc (PATH setup, aliases) |
| `config/nvim` | Neovim config for LSP-based code reading (plain `nvim` uses this). See [config/nvim/README.md](config/nvim/README.md) |
| `config/zellij` | Zellij config (unlock-first keybind preset + Ctrl+G passthrough for agents + Alt+u/Alt+m nested-session ascend/descend). See header comment in `config/zellij/config.kdl` |

Agent skills
------------

`agents/skills/<name>/SKILL.md` are [Agent Skills](https://agentskills.io)
shared by every coding-agent harness. `link` symlinks each skill directory into
the user-level skills dir of each harness it detects (CLI on PATH or config dir
present): Kiro `~/.kiro/skills` (`$KIRO_HOME`), oh-my-pi `~/.omp/agent/skills`,
pi `~/.pi/agent/skills`, Claude Code `~/.claude/skills`, Codex
`~/.agents/skills`, OpenCode `~/.config/opencode/skills`. Only per-skill links
are managed; other installed skills are untouched, a pre-existing directory of
the same name is moved to `~/Dotfiles_old/skills-<harness>/`. Install a new
harness, then re-run `bash install.sh skills`. Agents pick up new skills in new
sessions.

| Skill | Purpose |
|---|---|
| `address-review` | Address review comments recorded in Neovim/diffview (see [config/nvim/README.md](config/nvim/README.md#review-comments-for-coding-agents)) |
| `sbx-mcp-client` | `mcpcli`: call MCP servers on the Docker Sandboxes MCP gateway from the shell, so the agent controls how much of each response enters its context |
| `aws-mcp` | Rules for the AWS MCP Server: avoiding `run_script` timeouts, and estimate-gated, budgeted CloudWatch Logs Insights queries |

Agent instructions
------------------

`agents/instructions.md` holds user-level instructions for every harness
(currently: inside a Docker sandbox, prefer `mcpcli` against the sbx MCP
gateway to native or agent-attached MCP tools). `link` (or
`bash install.sh instructions`) symlinks it into each detected harness: Kiro
`~/.kiro/steering/dotfiles.md` and Claude Code `~/.claude/rules/dotfiles.md`
(directories of instruction files, so the user's own files stay), and
`AGENTS.md` for the harnesses with a single user-level file: oh-my-pi
`~/.omp/agent/`, pi `~/.pi/agent/`, Codex `~/.codex/` (`$CODEX_HOME`), OpenCode
`~/.config/opencode/`. A pre-existing file there is moved to
`~/Dotfiles_old/instructions-<harness>/` — merge anything you want to keep into
`agents/instructions.md`.

Adding a new configuration
--------------------------

1. Create `config/<name>` with the config files.
2. Add `<name>` to the `config_dirs` list in `install.sh`.
3. Run `bash install.sh link`.

Notes for machine-specific tooling in `install_commons`: prefer brew on macOS;
on Linux prefer apt, falling back to GitHub release binaries installed into
`~/.local/bin` (which `config/bash/bashrc` puts on PATH). Exception: tools
whose version must match across machines (Neovim, tree-sitter) are pinned and
installed from GitHub releases on both platforms.

Docker sandbox kit
------------------

This repo is also a [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/)
**v3 mixin kit** (`sbx/dotfiles/dotfiles.yaml`, thin-kit pattern): provisioning
the kit clones this repository into `/home/agent/Dotfiles` and runs
`install.sh all`. Nothing is duplicated — the kit's install hook installs from
git, so upgrades inside an existing sandbox stay
`git pull && bash install.sh link`.

```bash
# one-time host prerequisite: allowlist this kit's Git source
# (the setting REPLACES the list — keep any existing entries)
sbx settings set kit.allowedSources '["docker.io/","github.com/stevenpelley/"]'

# validate locally (sbx kit validate does not accept v3 source kits)
docker buildx build sbx/dotfiles -f sbx/dotfiles/dotfiles.yaml --output type=cacheonly
sbx kit inspect ./sbx/dotfiles
```

`sbxenv.yaml` is linked as `~/.sbxenv.yaml`, which sbx merges into every
environment file, adding the kit as
`git+https://github.com/stevenpelley/Dotfiles#ref=main&dir=sbx/dotfiles`.
v3 kits compose only with v3 kits, so those environments must use a v3
workload (e.g. `docker.io/docker/sbx-kit-kiro` with `agent: sbx-kit-kiro`)
rather than a built-in agent shortcut like `kiro`.

The kit's `network-policy@1` hosts must cover everything `install.sh`
downloads, in both the `install` phase (provisioning) and the `runtime` phase
(in-sandbox upgrades): github.com, api.github.com, both GitHub asset hosts,
codeload.github.com, raw.githubusercontent.com, pypi.org,
files.pythonhosted.org, registry.npmjs.org, plus the Ubuntu apt mirrors for
install. Kit install hooks run as **root** — the descriptor drops to the
`agent` user before running the installer.

When editing `install.sh` or adding download steps: every apt-get invocation
must include `-o DPkg::Lock::Timeout=10`, and any new download host must be
added to the kit's network allowlist.

Agent context
-------------

See [AGENTS.md](AGENTS.md) for repository conventions, gotchas, and
verification patterns if you are an agent (or an automation) editing this repo.
