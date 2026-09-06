# nvim (legacy bridge)

`init.vim` prepends `~/.vim` to the runtimepath and sources `~/.vimrc`, so
plain `nvim` behaves like the long-standing `vimrc` setup (2-space indent,
`clipboard=unnamedplus`, line numbers, dark background).

This is intentionally a thin bridge. The experimental, LSP-focused Neovim
configuration lives in [`../nvim-trial`](../nvim-trial/README.md) — isolated
under `NVIM_APPNAME=nvim-trial` and launched with the `nvtrial` alias.
