# syntax=docker/dockerfile:1.7
###############################################################################
# dotfiles — content recipe for the dotfiles mixin Kit (descriptor:
# dotfiles.yaml). The Kit frontend finds this file by its stem.
#
# Runs `install.sh all` at image build instead of at every sandbox create:
# sbx builds a Kit once and caches it by source hash, while install hooks
# re-run on every recreate. The descriptor's install hook still runs
# `install.sh all` in the sandbox, and finds everything already installed.
#
# The overlay is /home/agent only: ~/Dotfiles (a git clone), the config
# symlinks, ~/.oh-my-bash, ~/.terminfo, and ~/.local with every tool as a
# release binary (nvim, tree-sitter, gh + gh-stack, zellij, lefthook), a
# private uv and node (~/.local/opt), the Python tools as uv tools on a
# uv-managed Python, the LSPs on the private node, and the nvim plugins and
# treesitter parsers at the commits in config/nvim/lazy-lock.json.
#
# Workload-neutral: it is built on plain Ubuntu, not on any agent's image, and
# uses nothing from the workload but a glibc and the `agent` user. Contract
# with the workload:
#   - Linux amd64 or arm64, glibc >= the build base's (Ubuntu 24.04: 2.39,
#     which the tree-sitter CLI release needs; the DHI agent images have 2.41)
#   - user `agent`, uid/gid 1000, HOME=/home/agent (the uv tool venvs and the
#     LSP wrappers hold absolute paths under it)
#   - bash, git, curl and jq at runtime (install.sh and nvim's plugin manager)
# The parsers are compiled here, on the oldest glibc of the supported
# workloads, because the workloads have no C compiler. Packages installed
# below (cc, patchelf, ...) are build-only and stay out of the overlay.
###############################################################################

FROM ubuntu:24.04 AS build

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends \
         bash build-essential ca-certificates curl git jq libatomic1 ncurses-bin \
         patchelf \
    && rm -rf /var/lib/apt/lists/* \
    && { userdel -r ubuntu 2> /dev/null || true; } \
    && groupadd -g 1000 agent \
    && useradd -m -u 1000 -g 1000 -s /bin/bash agent

USER agent
ENV HOME=/home/agent
WORKDIR /home/agent

# The repository itself, at the ref the Kit's `ref` arg names. A clone, not
# the build context: the context is only sbx/dotfiles/, and the config
# symlinks need the whole tree. origin and the branch are set so an in-
# sandbox `git pull` (the startup hook) works. ADD leaves a local tag named
# after the ref, which makes a plain `git push origin main` ambiguous.
ARG DOTFILES_REF
ADD --keep-git-dir=true --chown=1000:1000 \
    "https://github.com/stevenpelley/Dotfiles.git#${DOTFILES_REF}" /home/agent/Dotfiles
RUN { git -C ~/Dotfiles remote remove origin 2> /dev/null || true; } \
    && { git -C ~/Dotfiles tag -d "${DOTFILES_REF}" > /dev/null 2>&1 || true; } \
    && git -C ~/Dotfiles remote add origin https://github.com/stevenpelley/Dotfiles \
    && git -C ~/Dotfiles fetch -q origin "${DOTFILES_REF}" \
    && git -C ~/Dotfiles checkout -q -B "${DOTFILES_REF}" FETCH_HEAD \
    && git -C ~/Dotfiles branch -q -u "origin/${DOTFILES_REF}"

# The installer, as in a sandbox. Each tool step prints its version, so a
# failed download shows in the build log.
RUN bash ~/Dotfiles/install.sh all \
    && tic -x ~/Dotfiles/files/home/xterm-ghostty.terminfo

# node's arm64 build links libatomic.so.1, which the workloads do not ship:
# put the build base's copy next to node and point node's rpath at it.
USER root
RUN set -eu; \
    node=$(echo /home/agent/.local/opt/node-*/bin/node); \
    if ldd "$node" | grep -q 'libatomic\.so\.1 => /'; then \
      install -o 1000 -g 1000 -m 0644 \
        "$(ldd "$node" | sed -n 's/.*libatomic\.so\.1 => \([^ ]*\).*/\1/p')" \
        "${node%/bin/node}/lib/libatomic.so.1"; \
      patchelf --set-rpath '$ORIGIN/../lib' "$node"; \
    fi; \
    "$node" --version
USER agent

# Drop what is per-sandbox or belongs to other kits: caches, the installer's
# backups of the base's own dotfiles, and harness dirs (the runtime and the
# agent kits own those; the startup hook links into them at boot).
RUN rm -rf ~/.cache ~/.npm ~/Dotfiles_old ~/Config_old \
           ~/.claude ~/.claude.json ~/.omp ~/.pi ~/.kiro ~/.codex ~/.agents \
           ~/.config/opencode ~/.local/state/nvim/lazy

# The installer must now find everything in place: with no network, its
# checks alone have to pass (this is what keeps the sandbox's install hook
# fast). Then every tool must run without the build-only packages: libatomic
# and the compiler are hidden for this check.
USER root
RUN --network=none set -eu; \
    su -l agent -c 'bash ~/Dotfiles/install.sh install' > /tmp/install.log 2>&1 \
      || { cat /tmp/install.log; echo "install.sh install is not a no-op in the image" >&2; exit 1; }; \
    for f in $(find / -xdev -name 'libatomic.so.1*' -not -path '/home/*'); do mv "$f" "$f.hidden"; done; \
    mv /usr/bin/cc /usr/bin/cc.hidden; \
    su -l agent -c 'set -e; \
      for t in nvim tree-sitter gh zellij jc ruff pyright vtsls; do "$t" --version > /dev/null; done; \
      lefthook version > /dev/null; \
      for t in jello jellex; do test -x ~/.local/bin/$t; ~/.local/share/uv/tools/$t/bin/python -c "import $t"; done; \
      nvim --headless "+lua for _, l in ipairs({\"python\",\"lua\",\"bash\"}) do assert(vim.treesitter.language.add(l), l) end" +qa'; \
    mv /usr/bin/cc.hidden /usr/bin/cc; \
    for f in $(find / -xdev -name 'libatomic.so.1*.hidden'); do mv "$f" "${f%.hidden}"; done

RUN mkdir -p /out/home \
    && cp -a /home/agent /out/home/agent \
    && chown 0:0 /out /out/home

FROM scratch
COPY --from=build /out /
