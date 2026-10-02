#!/bin/bash
########################
# Dotfiles installer
#
#   bash install.sh link     # symlink home files and ~/.config/* into this repo,
#                            # plus agents/skills/* into each detected agent
#                            # harness (kiro, oh-my-pi, pi, claude, codex, opencode)
#   bash install.sh skills   # only the agent-skill links
#   bash install.sh install  # install tooling (pinned nvim + tree-sitter CLI, LSPs,
#                            # zellij, lefthook, oh-my-bash, pipx tools)
#   bash install.sh all      # install then link (order matters: oh-my-bash
#                            # replaces ~/.bashrc, so linking must come after)
#
# link moves any pre-existing files to ~/Dotfiles_old / ~/Config_old, then
# creates symlinks. Safe to re-run.
########################

link_configs() {
  dir=~/Dotfiles                    # dotfiles directory
  olddir=~/Dotfiles_old             # old dotfiles backup directory
  oldconfigdir=~/Config_old
  files="bashrc vimrc bash_profile sbxenv.yaml"    # list of files/folders to symlink in homedir
  config_dirs="bash nvim zellij ghostty"

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
      mv ~/.config/$configdir $oldconfigdir/
    fi

    echo "Creating symlink to $configdir in ~/.config directory."
    ln -s $dir/config/$configdir ~/.config/$configdir
  done

  link_agent_skills
}

# Agent skills ----------------------------------------------------------------
# Skills live in agents/skills/<name>/SKILL.md (the cross-harness Agent Skills
# format). Each one is symlinked into the user-level skills directory of every
# coding-agent harness detected on this machine (its CLI on PATH, or its config
# dir already present). Only the individual skill directories are linked, so
# skills installed by other means are left alone. Some harnesses also read
# other harnesses' dirs (omp reads ~/.claude and ~/.agents, opencode reads
# ~/.claude); they de-duplicate skills by name.

# prints "<harness> <user skills dir>" for each detected harness
agent_skill_targets() {
  local kiro_home="${KIRO_HOME:-$HOME/.kiro}"
  if command -v kiro-cli > /dev/null || [ -d "$kiro_home" ]; then
    echo "kiro $kiro_home/skills"
  fi
  # oh-my-pi; named profiles (~/.omp/profiles/<name>) are not handled
  if command -v omp > /dev/null || [ -d "$HOME/.omp" ]; then
    echo "oh-my-pi $HOME/.omp/agent/skills"
  fi
  if command -v pi > /dev/null || [ -d "$HOME/.pi" ]; then
    echo "pi $HOME/.pi/agent/skills"
  fi
  local claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  if command -v claude > /dev/null || [ -d "$claude_home" ]; then
    echo "claude $claude_home/skills"
  fi
  # Codex reads user skills from the shared ~/.agents/skills
  if command -v codex > /dev/null || [ -d "${CODEX_HOME:-$HOME/.codex}" ]; then
    echo "codex $HOME/.agents/skills"
  fi
  if command -v opencode > /dev/null || [ -d "$HOME/.config/opencode" ]; then
    echo "opencode $HOME/.config/opencode/skills"
  fi
}

link_agent_skills() {
  local dir=~/Dotfiles
  local olddir=~/Dotfiles_old
  local harness target skill name link found=""
  while read -r harness target; do
    found=1
    mkdir -p "$target"
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
  done < <(agent_skill_targets)
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

# release-asset OS name, shared by the neovim and tree-sitter release naming
release_os() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux)  echo linux ;;
    *)      return 1 ;;
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
    if ! curl -fsSL "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-${os}-${arch}.tar.gz" |
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
  if ! curl -fsSL "https://github.com/tree-sitter/tree-sitter/releases/download/${TREE_SITTER_VERSION}/tree-sitter-${os}-${arch}.gz" |
    gunzip > ~/.local/bin/tree-sitter.partial; then
    echo "tree-sitter: download of ${TREE_SITTER_VERSION} failed"
    return 1
  fi
  chmod 755 ~/.local/bin/tree-sitter.partial
  mv ~/.local/bin/tree-sitter.partial ~/.local/bin/tree-sitter
  ~/.local/bin/tree-sitter --version
}

install_lsps() {
  # the nvim config needs pyright, vtsls (+ typescript) and ruff on PATH
  if ! which pyright-langserver > /dev/null; then
    if which brew > /dev/null; then
      brew install pyright
    elif which npm > /dev/null; then
      npm install -g pyright
    else
      echo "install_lsps: no brew/npm; cannot install pyright"
    fi
  fi
  if ! which vtsls > /dev/null && which npm > /dev/null; then
    npm install -g @vtsls/language-server typescript
  fi
  if ! which ruff > /dev/null && which pipx > /dev/null; then
    pipx install ruff
  fi
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
  version=$(curl -fsSL https://api.github.com/repos/zellij-org/zellij/releases/latest |
    grep -m1 '"tag_name"' | cut -d'"' -f4)
  if [ -z "$version" ]; then
    echo "zellij: could not determine latest release, skipping"
    return 1
  fi
  url="https://github.com/zellij-org/zellij/releases/download/${version}/zellij-${zj_arch}-unknown-linux-musl.tar.gz"
  tmpdir=$(mktemp -d)
  curl -fsSL "$url" | tar xz -C "$tmpdir"
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
  version=$(curl -fsSL https://api.github.com/repos/evilmartians/lefthook/releases/latest |
    grep -m1 '"tag_name"' | cut -d'"' -f4)
  if [ -z "$version" ]; then
    echo "lefthook: could not determine latest release, skipping"
    return 1
  fi
  url="https://github.com/evilmartians/lefthook/releases/download/${version}/lefthook_${version#v}_${lh_target}"
  tmpfile=$(mktemp)
  curl -fsSL "$url" -o "$tmpfile"
  mkdir -p ~/.local/bin
  install -m755 "$tmpfile" ~/.local/bin/lefthook
  rm -f "$tmpfile"
  ~/.local/bin/lefthook version
}
ensure_linux_tooling() {
  # best-effort bootstrap for fresh sandboxes; every apt call waits for the
  # package lock instead of failing
  command -v apt-get > /dev/null || return 0
  if [ "$(id -u)" = "0" ]; then
    SUDO=""
  elif command -v sudo > /dev/null; then
    SUDO="sudo"
  else
    echo "linux tooling: no apt privileges, skipping"
    return 0
  fi
  local missing=""
  local pkg
  for pkg in pipx git curl build-essential; do
    command -v "$pkg" > /dev/null || missing="$missing $pkg"
  done
  [ -z "$missing" ] && return 0
  $SUDO apt-get update -o DPkg::Lock::Timeout=10 && \
    $SUDO apt-get install -y -o DPkg::Lock::Timeout=10 $missing
}

install_commons() {
  ensure_linux_tooling
  install_nvim
  install_tree_sitter
  install_lsps
  install_zellij
  install_lefthook

  # install oh-my-bash
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)" --unattended

  # if have python then install jc, jello, jellex
  if which python3 > /dev/null && which brew > /dev/null; then
    brew install pipx
    pipx install jc jello jellex ruff
  elif which pip3 > /dev/null; then
    pipx install jc jello jellex ruff
  fi
}

case "$1" in
  link)
    link_configs
    ;;
  skills)
    link_agent_skills
    ;;
  install)
    install_commons
    ;;
  all)
    # must install oh-my-bash before bashrc so that my bashrc overwrites the
    # oh-my-bash one
    install_commons
    link_configs
    ;;
esac
