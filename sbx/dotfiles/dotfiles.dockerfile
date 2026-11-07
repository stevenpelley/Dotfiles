# syntax=docker/dockerfile:1.7
###############################################################################
# dotfiles — content recipe for the dotfiles mixin Kit (descriptor:
# dotfiles.yaml). The Kit frontend finds this file by its stem.
#
# Runs `install.sh all` at image build instead of at every sandbox create:
# sbx builds a Kit once and caches it by source hash, while install hooks
# re-run (nvim, tree-sitter, zellij, lefthook, gh, LSPs, pipx tools,
# oh-my-bash: minutes of downloads) on every recreate.
#
# The installer runs in a stage on the Ubuntu sandbox template, the same
# family the workloads use, and the overlay is the agent's home plus the two
# system paths the installer writes outside it:
#   /home/agent                 ~/Dotfiles (a git clone), ~/.local (nvim,
#                               tree-sitter, zellij, lefthook, pipx venvs,
#                               gh extensions), ~/.oh-my-bash, ~/.terminfo
#                               and the config symlinks
#   /usr/local/share/npm-global pyright, vtsls, typescript (the template's
#                               NPM_CONFIG_PREFIX)
#   /usr/local/bin/gh           gh from GitHub's apt repo (newer than the
#                               template's /usr/bin/gh, and first on PATH)
# No dpkg state: a mixin's /var/lib/dpkg would replace the workload's. The
# pipx venvs point at the stage's /usr/bin/python3; the descriptor's install
# hook falls back to `install.sh install` when that python is not on the
# workload (a different base), so the overlay never leaves broken tools.
###############################################################################

FROM docker/sandbox-templates:shell AS build

USER agent
ENV HOME=/home/agent
WORKDIR /home/agent

# The repository itself, at the ref the Kit's `ref` arg names. A clone, not
# the build context: the context is only sbx/dotfiles/, and the config
# symlinks need the whole tree. origin and the branch are set so an in-
# sandbox `git pull` (the startup hook) works.
ARG DOTFILES_REF
ADD --keep-git-dir=true --chown=1000:1000 \
    "https://github.com/stevenpelley/Dotfiles.git#${DOTFILES_REF}" /home/agent/Dotfiles
RUN { git -C ~/Dotfiles remote remove origin 2> /dev/null || true; } \
    && git -C ~/Dotfiles remote add origin https://github.com/stevenpelley/Dotfiles \
    && git -C ~/Dotfiles fetch -q origin "${DOTFILES_REF}" \
    && git -C ~/Dotfiles checkout -q -B "${DOTFILES_REF}" FETCH_HEAD \
    && git -C ~/Dotfiles branch -q -u "origin/${DOTFILES_REF}"

# The installer, as the kit hook ran it. It uses sudo for apt (passwordless
# on the template). Each tool step prints its version, so a failed download
# shows in the build log; the checks after it fail the build instead of
# shipping a half-installed overlay.
RUN bash ~/Dotfiles/install.sh all \
    && tic -x ~/Dotfiles/files/home/xterm-ghostty.terminfo \
    && for t in nvim tree-sitter zellij lefthook jc jello jellex ruff; do \
         command -v "$t" > /dev/null || { echo "missing: $t" >&2; exit 1; }; \
       done \
    && test -d ~/.local/share/gh/extensions/gh-stack

# Drop what is per-sandbox or belongs to other kits: caches, the installer's
# backups of the template's own dotfiles, and harness dirs (the runtime and
# the agent kits own those; the startup hook links into them at boot).
RUN rm -rf ~/.cache ~/.npm ~/Dotfiles_old ~/Config_old \
           ~/.claude ~/.claude.json ~/.omp ~/.pi ~/.kiro ~/.codex \
           ~/.config/opencode ~/workspace

USER root
RUN mkdir -p /out/home /out/usr/local/bin /out/usr/local/share \
    && cp -a /home/agent /out/home/agent \
    && cp -a /usr/local/share/npm-global /out/usr/local/share/npm-global \
    && install -m 0755 /usr/bin/gh /out/usr/local/bin/gh \
    && chown 0:0 /out /out/home /out/usr /out/usr/local /out/usr/local/bin /out/usr/local/share \
    && chown -R 1000:1000 /out/home/agent /out/usr/local/share/npm-global

FROM scratch
COPY --from=build /out /
