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
| `config/bash` | oh-my-bash bootstrap + interactive bashrc (PATH setup, aliases, `nvtrial` alias) |
| `config/fish` | fish config (PATH, `nvtrial` alias) |
| `config/nvim` | Legacy bridge: makes plain `nvim` behave like the `vimrc` setup. See [config/nvim/README.md](config/nvim/README.md) |
| `config/nvim-trial` | Isolated Neovim config for LSP-based code reading. See [config/nvim-trial/README.md](config/nvim-trial/README.md) |
| `config/zellij` | Zellij config (unlock-first keybind preset + Ctrl+G passthrough for agents). See header comment in `config/zellij/config.kdl` |

Adding a new configuration
--------------------------

1. Create `config/<name>` with the config files.
2. Add `<name>` to the `config_dirs` list in `install.sh`.
3. Run `bash install.sh link`.

Notes for machine-specific tooling in `install_commons`: prefer brew on macOS;
on Linux prefer apt, falling back to GitHub release binaries installed into
`~/.local/bin` (which `config/bash/bashrc` puts on PATH).

Agent context
-------------

See [AGENTS.md](AGENTS.md) for repository conventions, gotchas, and
verification patterns if you are an agent (or an automation) editing this repo.
