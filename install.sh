#!/bin/bash
########################
# Dotfiles installer
#
#   bash install.sh link     # symlink home files and ~/.config/* into this repo,
#                            # plus agents/skills/* and agents/instructions.md
#                            # into each detected agent harness (kiro,
#                            # oh-my-pi, pi, claude, codex, opencode)
#                            # and the Claude Code status line
#   bash install.sh skills   # only the agent-skill links
#   bash install.sh instructions  # only the agent-instructions links
#   bash install.sh scripts  # only bin/* (copied to ~/.local/share/dotfiles/bin,
#                            # linked from ~/.local/bin); link also does this
#   bash install.sh install  # install missing tooling (gh + gh-stack extension, pinned nvim + tree-sitter CLI,
#                            # LSPs, Python tools, zellij, lefthook, oh-my-bash, nvim plugins + parsers)
#   bash install.sh upgrade  # move the unpinned tools (brew formulas, uv tools, LSP npm packages,
#                            # gh extensions) to their latest releases
#   bash install.sh all      # install, link, then the nvim plugins (order matters: oh-my-bash
#                            # replaces ~/.bashrc, so linking must come after)
#
# install and all only install what is missing or not at its pinned version.
# When everything is there they make no network calls, so they are cheap to
# run at every sandbox create (the sbx kit image already has it all).
#
# link moves any pre-existing files to ~/Dotfiles_old / ~/Config_old, then
# creates symlinks. Safe to re-run.
########################

# Stop at the first failed step, so its error is the last thing in the log. A
# step that may fail without stopping the install has to say so with `||`.
# Not pipefail: `... | head -1` and the like would count as failures.
set -e

# Tools land in ~/.local/bin, and harness detection (agent_targets) looks for
# CLIs there (omp, claude). The user's PATH setup (config/bash/env) is not
# linked yet on a first run, and a sandbox kit hook's `su -l` shell starts
# with the system PATH only, so put it on PATH here.
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac

# Print a URL's content, retrying transient failures (GitHub answers 5xx now
# and then). Through a file because a retry after a partial transfer would
# repeat the data on stdout; curl truncates a file before retrying.
fetch() {
  local tmp status=0
  tmp=$(mktemp)
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 -o "$tmp" "$1" && cat "$tmp" || status=$?
  rm -f "$tmp"
  return $status
}

link_configs() {
  dir=~/Dotfiles                    # dotfiles directory
  olddir=~/Dotfiles_old             # old dotfiles backup directory
  oldconfigdir=~/Config_old
  files="bashrc vimrc bash_profile profile sbxenv.yaml"    # list of files/folders to symlink in homedir
  config_dirs="bash nvim zellij ghostty herdr-app"

  ##########

  # create dotfiles_old in homedir
  echo "Creating $olddir for backup of any existing dotfiles in ~"
  mkdir -p $olddir
  echo "...done"

  echo "Creating $oldconfigdir for backup of any existing dotfiles in ~"
  mkdir -p $oldconfigdir
  echo "...done"

  echo "Making sure ~/.config exists"
  mkdir -p ~/.config
  echo "...done"

  # change to the dotfiles directory
  echo "Changing to the $dir directory"
  cd $dir
  echo "...done"

  # move any existing dotfiles in homedir to dotfiles_old directory, then create symlinks
  for file in $files; do
    if [ -L ~/.$file ]
    then
      rm ~/.$file
    elif [ -e ~/.$file ]
    then
      mv ~/.$file $olddir/
    fi

    echo "Creating symlink to $file in home directory."
    ln -s $dir/$file ~/.$file
  done

  # change to the .config directory
  echo "Changing to the $dir/config directory"
  cd $dir/config
  echo "...done"

  for configdir in $config_dirs; do
    if [ -L ~/.config/$configdir ]
    then
      rm ~/.config/$configdir
    elif [ -e ~/.config/$configdir ]
    then
      # The Herdr app keeps its own state in its folder too (window spot,
      # layout clicks, shared mod state); the repo tracks only an allowlist.
      # Carry over what the repo doesn't have before backing the folder up.
      # Quit Herdr first: it writes there while running.
      if [ "$configdir" = herdr-app ]; then
        rsync -a --ignore-existing --exclude /.git --exclude /herdr-app.sock \
          ~/.config/$configdir/ $dir/config/$configdir/
      fi
      mv ~/.config/$configdir $oldconfigdir/
    fi

    echo "Creating symlink to $configdir in ~/.config directory."
    ln -s $dir/config/$configdir ~/.config/$configdir
  done

  link_agent_skills
  link_agent_instructions
  link_claude_statusline
  install_scripts
}

# Scripts ----------------------------------------------------------------------
# bin/<name> is copied to ~/.local/share/dotfiles/bin/<name> and linked as
# ~/.local/bin/<name>. A copy, not a link into this repo: some are run by
# other programs with the user's credentials (e.g. aws-mcp-proxy by the sbx
# MCP gateway), so a change takes effect only when this is re-run.
install_scripts() {
  local dir=~/Dotfiles
  local share=~/.local/share/dotfiles/bin
  local script name
  mkdir -p "$share" ~/.local/bin
  for script in "$dir"/bin/*; do
    [ -f "$script" ] || continue
    name=$(basename "$script")
    echo "Installing script $name to $share"
    install -m755 "$script" "$share/$name"
    ln -sfn "$share/$name" ~/.local/bin/"$name"
  done
}

# Claude Code status line ------------------------------------------------------
# agents/claude/statusline.sh is linked as ~/.claude/statusline-command.sh and
# registered under "statusLine" in ~/.claude/settings.json. settings.json is
# merged with jq rather than symlinked: Claude Code writes to it itself
# (/config, theme, permissions), and those per-machine settings don't belong
# in this repo. Only the statusLine key is touched.
link_claude_statusline() {
  local dir=~/Dotfiles
  local olddir=~/Dotfiles_old
  local claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  if ! command -v claude > /dev/null && [ ! -d "$claude_home" ]; then
    echo "Claude Code not detected; no status line linked"
    return 0
  fi
  mkdir -p "$claude_home"

  local script="$claude_home/statusline-command.sh"
  if [ -L "$script" ]; then
    rm "$script"
  elif [ -e "$script" ]; then
    mkdir -p "$olddir"
    mv "$script" "$olddir/claude-statusline-command.sh"
  fi
  echo "Linking Claude Code status line to $script"
  ln -s "$dir/agents/claude/statusline.sh" "$script"

  if ! command -v jq > /dev/null; then
    echo "claude statusline: jq not found; statusLine not added to settings.json"
    return 1
  fi
  local settings="$claude_home/settings.json"
  [ -s "$settings" ] || echo '{}' > "$settings"
  if jq --arg cmd "bash $script" '.statusLine = {type: "command", command: $cmd}' \
    "$settings" > "$settings.tmp"; then
    # write through rather than mv, preserving a symlinked settings.json
    cat "$settings.tmp" > "$settings" && rm "$settings.tmp"
  else
    rm -f "$settings.tmp"
    echo "claude statusline: could not parse $settings; statusLine not added"
    return 1
  fi
}

# Agent skills and instructions -----------------------------------------------
# Skills live in agents/skills/<name>/SKILL.md (the cross-harness Agent Skills
# format). Each one is symlinked into the user-level skills directory of every
# coding-agent harness detected on this machine (its CLI on PATH, or its config
# dir already present). Only the individual skill directories are linked, so
# skills installed by other means are left alone. Some harnesses also read
# other harnesses' dirs (omp reads ~/.claude and ~/.agents, opencode reads
# ~/.claude); they de-duplicate skills by name.
#
# agents/instructions.md holds user-level instructions, linked into the same
# harnesses. Kiro (global steering) and Claude Code (user rules) load every
# .md in a directory, so there it is one more file next to the user's own.
# The others read a single user-level AGENTS.md; a pre-existing one is moved
# to ~/Dotfiles_old/instructions-<harness>/, like the other dotfiles.

# prints "<harness> <user skills dir> <user instructions file>" for each
# detected harness
agent_targets() {
  local kiro_home="${KIRO_HOME:-$HOME/.kiro}"
  if command -v kiro-cli > /dev/null || [ -d "$kiro_home" ]; then
    echo "kiro $kiro_home/skills $kiro_home/steering/dotfiles.md"
  fi
  # oh-my-pi; named profiles (~/.omp/profiles/<name>) are not handled. A
  # global rule (~/.omp/agent/rules/, always applied via the frontmatter in
  # agents/instructions.md), not the single user AGENTS.md: in a Docker
  # sandbox the runtime writes its kit guidance into that AGENTS.md.
  if command -v omp > /dev/null || [ -d "$HOME/.omp" ]; then
    echo "oh-my-pi $HOME/.omp/agent/skills $HOME/.omp/agent/rules/dotfiles.md"
  fi
  if command -v pi > /dev/null || [ -d "$HOME/.pi" ]; then
    echo "pi $HOME/.pi/agent/skills $HOME/.pi/agent/AGENTS.md"
  fi
  local claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  if command -v claude > /dev/null || [ -d "$claude_home" ]; then
    echo "claude $claude_home/skills $claude_home/rules/dotfiles.md"
  fi
  # Codex reads user skills from the shared ~/.agents/skills
  local codex_home="${CODEX_HOME:-$HOME/.codex}"
  if command -v codex > /dev/null || [ -d "$codex_home" ]; then
    echo "codex $HOME/.agents/skills $codex_home/AGENTS.md"
  fi
  if command -v opencode > /dev/null || [ -d "$HOME/.config/opencode" ]; then
    echo "opencode $HOME/.config/opencode/skills $HOME/.config/opencode/AGENTS.md"
  fi
}

link_agent_instructions() {
  local dir=~/Dotfiles
  local olddir=~/Dotfiles_old
  local harness skills target found=""
  while read -r harness skills target; do
    found=1
    mkdir -p "$(dirname "$target")"
    if [ -L "$target" ]; then
      rm "$target"
    elif [ -e "$target" ]; then
      mkdir -p "$olddir/instructions-$harness"
      echo "Moving existing $target to $olddir/instructions-$harness/"
      mv "$target" "$olddir/instructions-$harness/"
    fi
    echo "Linking agent instructions for $harness ($target)"
    ln -s "$dir/agents/instructions.md" "$target"
  done < <(agent_targets)
  [ -n "$found" ] || echo "No coding-agent harnesses detected; no instructions linked"

  # oh-my-pi used to get ~/.omp/agent/AGENTS.md -> instructions.md; drop that
  # link and restore the file it displaced (in a sandbox, the kit guidance)
  local omp_old="$HOME/.omp/agent/AGENTS.md"
  if [ -L "$omp_old" ] && case "$(readlink "$omp_old")" in */agents/instructions.md) true ;; *) false ;; esac; then
    echo "Removing old oh-my-pi instructions link $omp_old"
    rm "$omp_old"
    if [ -f "$olddir/instructions-oh-my-pi/AGENTS.md" ]; then
      echo "Restoring $omp_old from $olddir/instructions-oh-my-pi/"
      mv "$olddir/instructions-oh-my-pi/AGENTS.md" "$omp_old"
    fi
  fi
}

# Claude Code gets the skills as a plugin where it can't take the links: agents/
# is the plugin's root, read in place, so a git pull updates it. The skills are
# then named dotfiles:<skill>. Both commands are safe to re-run. stdin is the
# caller's read loop, and claude would consume it.
link_claude_plugin() {
  echo "Registering the skills as a Claude Code plugin"
  { claude plugin marketplace add ~/Dotfiles --scope user \
    && claude plugin install dotfiles@dotfiles --scope user; } < /dev/null \
    || echo "Could not register the Claude Code plugin; continuing"
}

link_agent_skills() {
  local dir=~/Dotfiles
  local olddir=~/Dotfiles_old
  local harness target instructions skill name link found=""
  while read -r harness target instructions; do
    found=1
    mkdir -p "$target"
    # the sbx Claude kit mounts the host's ~/.claude/skills read-only; under
    # set -e a failed ln there would stop the rest of link
    if [ ! -w "$target" ]; then
      echo "Skipping skills for $harness: $target is not writable"
      [ "$harness" != claude ] || link_claude_plugin
      continue
    fi
    # drop links to skills that were removed from this repo
    for link in "$target"/*; do
      if [ -L "$link" ] && [ ! -e "$link" ]; then
        case "$(readlink "$link")" in
          "$dir"/agents/skills/*) echo "Removing stale skill link $link"; rm "$link" ;;
        esac
      fi
    done
    for skill in "$dir"/agents/skills/*/; do
      [ -f "$skill/SKILL.md" ] || continue
      name=$(basename "$skill")
      if [ -L "$target/$name" ]; then
        rm "$target/$name"
      elif [ -e "$target/$name" ]; then
        mkdir -p "$olddir/skills-$harness"
        mv "$target/$name" "$olddir/skills-$harness/"
      fi
      echo "Linking skill $name for $harness ($target)"
      ln -s "$dir/agents/skills/$name" "$target/$name"
    done
  done < <(agent_targets)
  [ -n "$found" ] || echo "No coding-agent harnesses detected; no skills linked"
}

# Neovim is pinned to one exact release and installed the same way on macOS and
# Linux: the official GitHub release tarball, unpacked into
# ~/.local/opt/nvim-<version> with ~/.local/bin/nvim symlinked to it. brew and
# apt are deliberately not used (brew floats to the newest release, apt lags
# far behind), so every machine runs the identical build.
# Bump NVIM_VERSION together with the nvim-treesitter commit in
# config/nvim/lazy-lock.json — nvim-treesitter's main branch only supports the
# latest stable nvim.
NVIM_VERSION=v0.12.5
# tree-sitter CLI, required by nvim-treesitter (main) to build parsers.
# Official release binary (glibc on Linux); not npm, which nvim-treesitter
# does not support.
TREE_SITTER_VERSION=v0.27.0
# zellij and lefthook, where they come from GitHub release binaries (brew has
# its own version). Pinned rather than looked up in GitHub's releases API: one
# 5xx from the API used to fail a whole kit image build.
ZELLIJ_VERSION=v0.45.1
LEFTHOOK_VERSION=v2.2.2
# gh from its GitHub release tarball where there is no brew (gh-stack needs a
# recent gh; distro packages lag far behind).
GH_VERSION=v2.104.0
# Where there is no brew, the Python tools and the Node.js language servers
# run on a private uv and node under ~/.local/opt, not on whatever python3 or
# node the machine has: a Docker sandbox kit image built with one base must
# keep working on any workload, and those differ in both. They are not put on
# PATH; the tools they install are.
UV_VERSION=0.13.9
UV_TOOLS_PYTHON=3.13
NODE_VERSION=v26.13.1
PYTHON_TOOLS="jc jello jellex ruff"
LSP_NPM_PACKAGES="pyright @vtsls/language-server typescript"
LSP_BINS="pyright pyright-langserver vtsls"
LSP_PREFIX=~/.local/share/dotfiles/lsp

# release-asset OS name, shared by the neovim and tree-sitter release naming
release_os() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux)  echo linux ;;
    *)      return 1 ;;
  esac
}

# Release-asset architecture: x64 or arm64 (nvim and uv name them otherwise and
# map it themselves).
release_arch() {
  case "$(uname -m)" in
    x86_64)          echo x64 ;;
    aarch64 | arm64) echo arm64 ;;
    *)               return 1 ;;
  esac
}

nvim_pinned_ok() {
  [ -x ~/.local/bin/nvim ] &&
    [ "$(~/.local/bin/nvim --version | sed -n '1s/^NVIM //p')" = "$NVIM_VERSION" ]
}

# Remove every Neovim that isn't the pinned ~/.local one, so there is exactly
# one nvim on the machine. brew and apt installs are uninstalled automatically;
# anything else (snap, AppImage, hand-built, ...) is reported with manual
# removal instructions and makes this return non-zero.
remove_other_nvims() {
  local status=0 p
  if command -v brew > /dev/null && brew list --formula neovim > /dev/null 2>&1; then
    echo "nvim: uninstalling Homebrew neovim (replaced by pinned ${NVIM_VERSION})"
    if ! brew uninstall --formula neovim; then
      echo "nvim: 'brew uninstall neovim' failed; run it manually (see output above)"
      status=1
    fi
  fi
  if command -v dpkg > /dev/null && dpkg -s neovim 2> /dev/null | grep -q '^Status: install ok installed'; then
    local sudo=""
    [ "$(id -u)" = "0" ] || sudo="sudo"
    if [ -z "$sudo" ] || sudo -n true 2> /dev/null; then
      echo "nvim: removing apt neovim (replaced by pinned ${NVIM_VERSION})"
      $sudo apt-get remove -y -o DPkg::Lock::Timeout=10 neovim || status=1
    else
      echo "nvim: apt neovim is installed; remove it with: sudo apt-get remove neovim"
      status=1
    fi
  fi
  hash -r
  while read -r p; do
    [ -n "$p" ] || continue
    [ "$p" = "$HOME/.local/bin/nvim" ] && continue
    echo "nvim: found an unmanaged nvim at $p (-> $(realpath "$p" 2> /dev/null || echo "$p"))"
    echo "      remove it manually (e.g. 'snap remove nvim', or delete the file/AppImage),"
    echo "      then re-run 'bash install.sh install'"
    status=1
  done < <(type -ap nvim)
  return $status
}

install_nvim() {
  local status=0
  remove_other_nvims || status=1
  if ! nvim_pinned_ok; then
    local os arch dest
    os=$(release_os) || { echo "nvim: unsupported OS $(uname -s), skipping"; return 1; }
    case "$(uname -m)" in
      x86_64)          arch="x86_64" ;;
      aarch64 | arm64) arch="arm64" ;;
      *)
        echo "nvim: unsupported arch $(uname -m), skipping"
        return 1
        ;;
    esac
    dest=~/.local/opt/nvim-${NVIM_VERSION}
    mkdir -p "$dest" ~/.local/bin
    if ! fetch "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-${os}-${arch}.tar.gz" |
      tar xz -C "$dest" --strip-components=1; then
      echo "nvim: download/extract of ${NVIM_VERSION} failed"
      return 1
    fi
    ln -sfn "$dest/bin/nvim" ~/.local/bin/nvim
  fi
  ~/.local/bin/nvim --version | head -1
  # previous ~/.local installs are left in place (not deleted automatically)
  local old
  for old in ~/.local/opt/nvim ~/.local/opt/nvim-v*; do
    [ -d "$old" ] && [ "$old" != ~/.local/opt/nvim-${NVIM_VERSION} ] &&
      echo "nvim: old install $old is unused; remove it with: rm -r '$old'"
  done
  return $status
}

install_tree_sitter() {
  if [ -x ~/.local/bin/tree-sitter ] &&
    [ "$(~/.local/bin/tree-sitter --version | awk '{print $2}')" = "${TREE_SITTER_VERSION#v}" ]; then
    return 0
  fi
  local os arch
  os=$(release_os) || { echo "tree-sitter: unsupported OS $(uname -s), skipping"; return 1; }
  case "$(uname -m)" in
    x86_64)          arch="x64" ;;
    aarch64 | arm64) arch="arm64" ;;
    *)
      echo "tree-sitter: unsupported arch $(uname -m), skipping"
      return 1
      ;;
  esac
  mkdir -p ~/.local/bin
  if ! fetch "https://github.com/tree-sitter/tree-sitter/releases/download/${TREE_SITTER_VERSION}/tree-sitter-${os}-${arch}.gz" |
    gunzip > ~/.local/bin/tree-sitter.partial; then
    echo "tree-sitter: download of ${TREE_SITTER_VERSION} failed"
    return 1
  fi
  chmod 755 ~/.local/bin/tree-sitter.partial
  mv ~/.local/bin/tree-sitter.partial ~/.local/bin/tree-sitter
  ~/.local/bin/tree-sitter --version
}

# Private uv and node (see UV_VERSION, NODE_VERSION) ---------------------------
UV_DIR=~/.local/opt/uv-${UV_VERSION}
NODE_DIR=~/.local/opt/node-${NODE_VERSION}

install_uv() {
  if [ -x "$UV_DIR/uv" ] && [ "$("$UV_DIR/uv" --version | awk '{print $2}')" = "$UV_VERSION" ]; then
    return 0
  fi
  local os arch
  case "$(uname -s)" in
    Linux)  os=unknown-linux-gnu ;;
    Darwin) os=apple-darwin ;;
    *) echo "uv: unsupported OS $(uname -s), skipping"; return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64)          arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) echo "uv: unsupported arch $(uname -m), skipping"; return 1 ;;
  esac
  mkdir -p "$UV_DIR"
  if ! fetch "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${arch}-${os}.tar.gz" |
    tar xz -C "$UV_DIR" --strip-components=1; then
    echo "uv: download/extract of ${UV_VERSION} failed"
    return 1
  fi
  "$UV_DIR/uv" --version
}

install_node() {
  if [ -x "$NODE_DIR/bin/node" ] && [ "$("$NODE_DIR/bin/node" --version 2> /dev/null)" = "$NODE_VERSION" ]; then
    return 0
  fi
  local os arch
  case "$(uname -s)" in
    Linux)  os=linux ;;
    Darwin) os=darwin ;;
    *) echo "node: unsupported OS $(uname -s), skipping"; return 1 ;;
  esac
  arch=$(release_arch) || { echo "node: unsupported arch $(uname -m), skipping"; return 1; }
  mkdir -p "$NODE_DIR"
  # bin/ and lib/ (npm) only: include/ (headers node-gyp fetches on demand)
  # and share/ (docs) are most of the tarball
  local top="node-${NODE_VERSION}-${os}-${arch}"
  if ! fetch "https://nodejs.org/dist/${NODE_VERSION}/${top}.tar.gz" |
    tar xz -C "$NODE_DIR" --strip-components=1 "$top/bin" "$top/lib"; then
    echo "node: download/extract of ${NODE_VERSION} failed"
    return 1
  fi
  # arm64 Linux builds link libatomic.so.1, which minimal images lack (the
  # sbx kit image ships one next to node; see sbx/dotfiles/dotfiles.dockerfile)
  "$NODE_DIR/bin/node" --version ||
    { echo "node: ${NODE_VERSION} does not run here (arm64 Linux needs libatomic.so.1)"; return 1; }
}

# Python CLI tools (PYTHON_TOOLS): pipx from brew, else uv tools on a
# uv-managed Python, so the tools do not depend on the machine's python3. A
# tool counts as installed when its entry point exists and its venv's python
# runs (a venv left by pipx, or built against another python3, gets replaced).
install_python_tools() {
  local t missing=""
  if command -v brew > /dev/null; then
    for t in $PYTHON_TOOLS; do
      command -v "$t" > /dev/null || missing="$missing $t"
    done
    [ -n "$missing" ] || return 0
    command -v pipx > /dev/null || brew install pipx
    pipx install $missing
    return
  fi
  install_uv
  local uv="$UV_DIR/uv" tools bin
  tools=$("$uv" tool dir)
  bin=$("$uv" tool dir --bin)
  for t in $PYTHON_TOOLS; do
    if [ -x "$bin/$t" ] && "$tools/$t/bin/python" -c '' 2> /dev/null; then
      continue
    fi
    echo "python tools: installing $t (uv, Python ${UV_TOOLS_PYTHON})"
    "$uv" tool uninstall "$t" > /dev/null 2>&1 || true
    "$uv" tool install --force --managed-python --python "$UV_TOOLS_PYTHON" "$t"
  done
}

# The nvim config needs pyright, vtsls (+ typescript) and ruff (a Python tool)
# on PATH. With brew: brew's pyright, vtsls from any npm. Otherwise the npm
# packages go into LSP_PREFIX with the private node, and each of LSP_BINS gets
# a ~/.local/bin wrapper that runs it on that node (their #!/usr/bin/env node
# would pick whatever node is on PATH, if any).
lsp_wrapper() {
  printf '#!/bin/sh\n# Written by ~/Dotfiles/install.sh (install_lsps)\nexec %s %s "$@"\n' \
    "'$NODE_DIR/bin/node'" "'$LSP_PREFIX/node_modules/.bin/$1'"
}

install_lsps() {
  if command -v brew > /dev/null; then
    command -v pyright-langserver > /dev/null || brew install pyright
    if ! command -v vtsls > /dev/null && command -v npm > /dev/null; then
      npm install -g @vtsls/language-server typescript
    fi
    return
  fi
  install_node
  local b
  for b in $LSP_BINS; do
    if [ ! -e "$LSP_PREFIX/node_modules/.bin/$b" ]; then
      echo "lsps: installing $LSP_NPM_PACKAGES into $LSP_PREFIX"
      mkdir -p "$LSP_PREFIX"
      PATH="$NODE_DIR/bin:$PATH" npm --prefix "$LSP_PREFIX" install --no-fund --no-audit $LSP_NPM_PACKAGES
      break
    fi
  done
  mkdir -p ~/.local/bin
  for b in $LSP_BINS; do
    if [ "$(cat ~/.local/bin/"$b" 2> /dev/null)" != "$(lsp_wrapper "$b")" ]; then
      echo "lsps: writing wrapper ~/.local/bin/$b"
      rm -f ~/.local/bin/"$b"
      lsp_wrapper "$b" > ~/.local/bin/"$b"
      chmod 755 ~/.local/bin/"$b"
    fi
  done
}

install_zellij() {
  if which zellij > /dev/null; then
    return
  fi
  if which brew > /dev/null; then
    brew install zellij
    return
  fi
  # Linux: static binary from GitHub releases (not in apt)
  case "$(uname -m)" in
    x86_64)          zj_arch="x86_64" ;;
    aarch64 | arm64) zj_arch="aarch64" ;;
    *)
      echo "zellij: unsupported arch $(uname -m), skipping"
      return 1
      ;;
  esac
  url="https://github.com/zellij-org/zellij/releases/download/${ZELLIJ_VERSION}/zellij-${zj_arch}-unknown-linux-musl.tar.gz"
  tmpdir=$(mktemp -d)
  fetch "$url" | tar xz -C "$tmpdir"
  mkdir -p ~/.local/bin
  install -m755 "$tmpdir/zellij" ~/.local/bin/zellij
  rm -rf "$tmpdir"
  ~/.local/bin/zellij --version
}
install_lefthook() {
  if which lefthook > /dev/null; then
    return
  fi
  if which brew > /dev/null; then
    brew install lefthook
    return
  fi
  # static binary from GitHub releases (not in apt; no brew on this host)
  case "$(uname -s)" in
    Darwin)
      case "$(uname -m)" in
        arm64)  lh_target="MacOS_arm64" ;;
        x86_64) lh_target="MacOS_x86_64" ;;
        *) echo "lefthook: unsupported arch $(uname -m), skipping"; return 1 ;;
      esac
      ;;
    Linux)
      case "$(uname -m)" in
        x86_64)          lh_target="Linux_x86_64" ;;
        aarch64 | arm64) lh_target="Linux_aarch64" ;;
        *) echo "lefthook: unsupported arch $(uname -m), skipping"; return 1 ;;
      esac
      ;;
    *) echo "lefthook: unsupported OS $(uname -s), skipping"; return 1 ;;
  esac
  url="https://github.com/evilmartians/lefthook/releases/download/${LEFTHOOK_VERSION}/lefthook_${LEFTHOOK_VERSION#v}_${lh_target}"
  tmpfile=$(mktemp)
  fetch "$url" > "$tmpfile"
  mkdir -p ~/.local/bin
  install -m755 "$tmpfile" ~/.local/bin/lefthook
  rm -f "$tmpfile"
  ~/.local/bin/lefthook version
}
# Installs the apt package for each command that is missing. Arguments are
# <command> or <command>:<package>. Best effort: without apt or root/sudo it
# reports and returns. Every apt call waits for the package lock instead of
# failing.
ensure_apt_commands() {
  command -v apt-get > /dev/null || return 0
  local spec missing="" sudo=""
  for spec in "$@"; do
    command -v "${spec%%:*}" > /dev/null || missing="$missing ${spec#*:}"
  done
  [ -n "$missing" ] || return 0
  if [ "$(id -u)" != "0" ]; then
    if sudo -n true 2> /dev/null; then
      sudo="sudo"
    else
      echo "apt: no privileges to install$missing; skipping"
      return 0
    fi
  fi
  { $sudo apt-get update -o DPkg::Lock::Timeout=10 &&
    $sudo apt-get install -y -o DPkg::Lock::Timeout=10 $missing; } ||
    echo "apt: could not install$missing; continuing"
}

# GitHub CLI: brew's where there is brew, otherwise the release tarball pinned
# by GH_VERSION into ~/.local/opt/gh-<version>, linked as ~/.local/bin/gh
# (which comes first on PATH, ahead of a distro or image gh).
gh_pinned_ok() {
  [ -x ~/.local/bin/gh ] &&
    [ "$(~/.local/bin/gh --version | sed -n '1s/^gh version \([^ ]*\).*/\1/p')" = "${GH_VERSION#v}" ]
}

install_gh() {
  if command -v brew > /dev/null; then
    brew list --formula gh > /dev/null 2>&1 || brew install gh
    return
  fi
  if ! gh_pinned_ok; then
    local arch dest
    [ "$(uname -s)" = Linux ] || { echo "gh: no brew and not Linux; install it manually"; return 1; }
    case "$(uname -m)" in
      x86_64)          arch=amd64 ;;
      aarch64 | arm64) arch=arm64 ;;
      *) echo "gh: unsupported arch $(uname -m), skipping"; return 1 ;;
    esac
    dest=~/.local/opt/gh-${GH_VERSION}
    mkdir -p "$dest" ~/.local/bin
    if ! fetch "https://github.com/cli/cli/releases/download/${GH_VERSION}/gh_${GH_VERSION#v}_linux_${arch}.tar.gz" |
      tar xz -C "$dest" --strip-components=1; then
      echo "gh: download/extract of ${GH_VERSION} failed"
      return 1
    fi
    ln -sfn "$dest/bin/gh" ~/.local/bin/gh
  fi
  ~/.local/bin/gh --version | head -1
}

# Official gh extensions, installed when missing (detected on disk: `gh
# extension install` fails when the extension is already installed, and `list`
# needs auth). Upgrades are `install.sh upgrade`.
GH_EXTENSIONS="github/gh-stack"
gh_extensions_dir() { echo "${XDG_DATA_HOME:-$HOME/.local/share}/gh/extensions"; }

install_gh_extensions() {
  command -v gh > /dev/null || { echo "gh extensions: gh not installed, skipping"; return 1; }
  local ext
  for ext in $GH_EXTENSIONS; do
    [ -d "$(gh_extensions_dir)/${ext#*/}" ] ||
      gh extension install "$ext" || echo "gh extensions: could not install $ext"
  done
}

# Neovim plugins and treesitter parsers --------------------------------------
# Plugins at the commits in config/nvim/lazy-lock.json and a parser for each
# language in config/nvim/treesitter-languages, so the first nvim start needs
# no network and no C compiler (sandbox workloads have none; the kit image
# builds them). Restoring checks the plugins out at the lockfile's commits.
NVIM_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/nvim"

treesitter_languages() {
  grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' ~/.config/nvim/treesitter-languages
}

nvim_plugins_ok() {
  local lock=~/.config/nvim/lazy-lock.json name commit lang
  [ -f "$lock" ] && command -v jq > /dev/null || return 1
  while read -r name commit; do
    [ "$(git -C "$NVIM_DATA/lazy/$name" rev-parse HEAD 2> /dev/null)" = "$commit" ] || return 1
  done < <(jq -r 'to_entries[] | "\(.key) \(.value.commit)"' "$lock")
  while read -r lang; do
    [ -f "$NVIM_DATA/site/parser/$lang.so" ] || return 1
  done < <(treesitter_languages)
}

install_nvim_plugins() {
  if [ ! -f ~/.config/nvim/init.lua ]; then
    echo "nvim plugins: ~/.config/nvim is not linked yet; skipping (run 'bash install.sh all')"
    return 0
  fi
  nvim_plugins_ok && return 0
  ensure_apt_commands cc:build-essential
  command -v cc > /dev/null || echo "nvim plugins: no C compiler; treesitter parsers cannot be built"
  # DOTFILES_TS_INSTALL (read by config/nvim/init.lua): skip the parser install
  # while restoring, then wait for it in a second run
  echo "nvim: restoring plugins from lazy-lock.json"
  DOTFILES_TS_INSTALL=skip ~/.local/bin/nvim --headless "+Lazy! restore" +qa
  echo "nvim: installing treesitter parsers"
  DOTFILES_TS_INSTALL=wait ~/.local/bin/nvim --headless +qa
  if ! nvim_plugins_ok; then
    echo "nvim plugins: plugins or parsers still missing after install"
    return 1
  fi
}

install_commons() {
  ensure_apt_commands git curl jq
  install_gh
  install_gh_extensions
  install_nvim
  install_tree_sitter
  install_python_tools
  install_lsps
  install_zellij
  install_lefthook

  # install oh-my-bash; its installer fails if it is already there. An
  # assignment first, or set -e would not see a failed download.
  if [ ! -d ~/.oh-my-bash ]; then
    local omb_installer
    omb_installer=$(fetch https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)
    bash -c "$omb_installer" --unattended
  fi
}

# Moves the unpinned tools to their latest releases. The pinned ones (nvim,
# tree-sitter, zellij and lefthook from GitHub, gh, uv, node) change only with
# their *_VERSION above, and nvim plugins only with lazy-lock.json.
upgrade_tools() {
  local f ext
  if command -v brew > /dev/null; then
    for f in gh pyright zellij lefthook pipx; do
      ! brew list --formula "$f" > /dev/null 2>&1 || brew upgrade "$f"
    done
    ! command -v pipx > /dev/null || pipx upgrade-all
  else
    if [ -x "$UV_DIR/uv" ]; then
      "$UV_DIR/uv" tool upgrade --all
    fi
    if [ -x "$NODE_DIR/bin/node" ] && [ -d "$LSP_PREFIX" ]; then
      # shellcheck disable=SC2046 # one word per package
      PATH="$NODE_DIR/bin:$PATH" npm --prefix "$LSP_PREFIX" install --no-fund --no-audit \
        $(printf '%s@latest ' $LSP_NPM_PACKAGES)
    fi
  fi
  if command -v gh > /dev/null; then
    if gh auth status > /dev/null 2>&1; then
      for ext in $GH_EXTENSIONS; do
        [ ! -d "$(gh_extensions_dir)/${ext#*/}" ] ||
          gh extension upgrade "${ext#*/gh-}" || echo "gh extensions: could not upgrade $ext"
      done
    else
      echo "gh extensions: not authenticated, skipping upgrade"
    fi
  fi
}

case "$1" in
  link)
    link_configs
    ;;
  skills)
    link_agent_skills
    ;;
  instructions)
    link_agent_instructions
    ;;
  scripts)
    install_scripts
    ;;
  install)
    install_commons
    install_nvim_plugins
    ;;
  upgrade)
    upgrade_tools
    ;;
  all)
    # must install oh-my-bash before bashrc so that my bashrc overwrites the
    # oh-my-bash one; nvim plugins need the linked config
    install_commons
    link_configs
    install_nvim_plugins
    ;;
esac
