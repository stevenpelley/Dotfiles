# Enable the subsequent settings only in interactive sessions
case $- in
  *i*) ;;
    *) return;;
esac

source ~/.config/bash/oh-my-bash
source ~/.config/bash/bashrc
