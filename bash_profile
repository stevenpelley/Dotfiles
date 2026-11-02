# Login shells: environment first (PATH etc., also for non-interactive login
# shells such as `su -l agent -c ...` in sandbox kit hooks), then the
# interactive config, which returns early when the shell is not interactive.
if [ -r ~/.config/bash/env ]; then
  source ~/.config/bash/env
fi

if [ -r ~/.bashrc ]; then
   source ~/.bashrc
fi
# Added by Kiro CLI
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="${PATH:+$PATH:}$HOME/.local/bin" ;; esac
