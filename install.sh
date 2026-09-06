#!/bin/bash
########################
# Dotfiles installer
#
#   bash install.sh link     # symlink home files and ~/.config/* into this repo
#   bash install.sh install  # install tooling (zellij, oh-my-bash, pipx tools)
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
  files="bashrc vimrc bash_profile"    # list of files/folders to symlink in homedir
  config_dirs="bash fish nvim nvim-trial zellij"

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
ensure_pipx_linux() {
  command -v pipx > /dev/null && return 0
  command -v apt-get > /dev/null || return 0
  if [ "$(id -u)" = "0" ]; then
    SUDO=""
  elif command -v sudo > /dev/null; then
    SUDO="sudo"
  else
    echo "pipx: no apt privileges to install it, skipping"
    return 0
  fi
  # DPkg::Lock::Timeout makes apt wait for the package lock instead of failing
  $SUDO apt-get update -o DPkg::Lock::Timeout=10 && \
    $SUDO apt-get install -y -o DPkg::Lock::Timeout=10 pipx
}

install_commons() {
  install_zellij

  # install oh-my-bash
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)" --unattended

  # if have python then install jc, jello, jellex
  if which python3 > /dev/null && which brew > /dev/null; then
    brew install pipx
    pipx install jc jello jellex
  elif which pip3 > /dev/null; then
    pipx install jc jello jellex
  fi
}

case "$1" in
  link)
    link_configs
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
