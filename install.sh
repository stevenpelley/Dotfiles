#!/bin/bash
############################
# .make.sh
# This script creates symlinks from the home directory to any desired dotfiles in ~/Dotfiles
############################

link_configs() {
  dir=~/Dotfiles                    # dotfiles directory
  olddir=~/Dotfiles_old             # old dotfiles backup directory
  oldconfigdir=~/Config_old
  files="bashrc vimrc bash_profile"    # list of files/folders to symlink in homedir
  config_dirs="bash fish nvim"

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
    else
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
    else
      mv ~/.config/$configdir $oldconfigdir/
    fi

    echo "Creating symlink to $configdir in ~/.config directory."
    ln -s $dir/config/$configdir ~/.config/$configdir
  done
}

install_commons() {
  # install oh-my-bash
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)" --unattended

  # TODO if have python then install jc, jello, jellox
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
