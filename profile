# Login shells other than bash (bash reads ~/.bash_profile and never this file).
#
# The Docker sbx shell kit (docker.io/docker/sbx-kit-shell) opens `ssh <name>.sbx`
# sessions as `/bin/sh -l` with SHELL=/bin/sh, ignoring the passwd shell that the
# sbx/dotfiles kit sets to bash. Hand interactive sessions to a bash login shell,
# so ~/.bash_profile and ~/.bashrc apply. Non-interactive `sh -l -c ...` keeps
# running under sh, with the environment from config/bash/env (POSIX-compatible).
case $- in
  *i*)
    if [ -z "$BASH_VERSION" ] && command -v bash > /dev/null 2>&1; then
      SHELL=$(command -v bash)
      export SHELL
      exec "$SHELL" -l
    fi
    ;;
esac

if [ -r "$HOME/.config/bash/env" ]; then
  . "$HOME/.config/bash/env"
fi
