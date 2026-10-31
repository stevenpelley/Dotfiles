# Login shells: environment first (PATH etc., also for non-interactive login
# shells such as `su -l agent -c ...` in sandbox kit hooks), then the
# interactive config, which returns early when the shell is not interactive.
if [ -r ~/.config/bash/env ]; then
  source ~/.config/bash/env
fi

# The following lines were added by Docker Desktop to add commands to your PATH.
export PATH="$PATH:/Users/stevenpelley/.docker/bin"
# End of Docker Desktop section.

if [ -r ~/.bashrc ]; then
   source ~/.bashrc
fi
