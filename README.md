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
| `bash install.sh link` | Backs up any existing dotfiles to `~/Dotfiles_old` and `~/Config_old`, then symlinks home files and `~/.config/*` into this repo. Safe to re-run — do it after adding files here. |
| `bash install.sh install` | Installs tooling: [zellij](https://zellij.dev) (brew on macOS; on Linux the static musl binary from GitHub releases into `~/.local/bin`), oh-my-bash, and pipx tools (`jc`, `jello`, `jellex`). |
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
| `config/fish` | fish config (PATH, aliases) |
| `config/nvim` | Neovim config for LSP-based code reading (plain `nvim` uses this). See [config/nvim/README.md](config/nvim/README.md) |
| `config/zellij` | Zellij config (unlock-first keybind preset + Ctrl+G passthrough for agents). See header comment in `config/zellij/config.kdl` |

Adding a new configuration
--------------------------

1. Create `config/<name>` with the config files.
2. Add `<name>` to the `config_dirs` list in `install.sh`.
3. Run `bash install.sh link`.

Notes for machine-specific tooling in `install_commons`: prefer brew on macOS;
on Linux prefer apt, falling back to GitHub release binaries installed into
`~/.local/bin` (which `config/bash/bashrc` puts on PATH).

Docker sandbox kit
------------------

This repo is also a [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/)
**mixin kit** (`spec.yaml`, thin-kit pattern): provisioning the kit clones this
repository into `/home/agent/Dotfiles` and runs `install.sh all`. Nothing is
duplicated — the kit's install command installs from git, so upgrades inside an
existing sandbox stay `git pull && bash install.sh link`.

```bash
# one-time host prerequisite: allowlist this kit's Git source
# (the setting REPLACES the list — keep any existing entries)
sbx settings set kit.allowedSources '["docker.io/","github.com/stevenpelley/"]'

# validate locally, then use via an environment file
sbx kit validate .
sbx env run .sbxenv.yaml dotfiles.sbxenv.yaml
```

`dotfiles.sbxenv.yaml` is a reference/example environment file (merge it after
your own `.sbxenv.yaml`, which supplies `agent` and `workspace`). The hosts in
`permissions.network.allow` in `spec.yaml` must cover everything `install.sh`
downloads at provision time (github.com, api.github.com, both GitHub asset
hosts, raw.githubusercontent.com, pypi.org, files.pythonhosted.org); extend it
when adding install steps. Kit install commands run as **root** — `spec.yaml`
drops to the `agent` user before running the installer.

When editing `install.sh` or adding download steps: every apt-get invocation
must include `-o DPkg::Lock::Timeout=10`, and any new download host must be
added to `spec.yaml`'s network allowlist.

Agent context
-------------

See [AGENTS.md](AGENTS.md) for repository conventions, gotchas, and
verification patterns if you are an agent (or an automation) editing this repo.
