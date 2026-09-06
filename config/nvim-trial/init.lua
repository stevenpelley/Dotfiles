-- nvim-trial: a minimal Neovim config for *reading* code with LSP features.
-- Loaded only when launched as `NVIM_APPNAME=nvim-trial nvim` (alias: nvtrial).
-- Targets Neovim >= 0.11 (uses native vim.lsp.config/enable).

vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- Options -------------------------------------------------------------------
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.termguicolors = true
vim.opt.signcolumn = "yes" -- stable gutter; no layout shift from diagnostics
vim.opt.updatetime = 250
vim.opt.scrolloff = 5
vim.opt.undofile = true
vim.opt.breakindent = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
-- colorful variant of the default scheme; keeps the terminal background
vim.cmd.colorscheme("vim")

-- Bootstrap lazy.nvim --------------------------------------------------------
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  vim.system({
    "git", "clone", "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", lazypath,
  }):wait()
end
vim.opt.rtp:prepend(lazypath)

-- Plugins --------------------------------------------------------------------
require("lazy").setup({
  -- Syntax highlighting / structural navigation
  {
    "nvim-treesitter/nvim-treesitter",
    -- final release of the pre-rewrite codebase; the main branch now needs
    -- Neovim 0.12+, while apt/brew still ship 0.11
    version = "v0.10.0",
    build = ":TSUpdate",
    config = function()
      local ts_langs = { "python", "typescript", "tsx", "javascript", "lua", "vim", "vimdoc", "markdown", "bash" }
      local legacy_ok = pcall(function()
        require("nvim-treesitter.configs").setup({
          ensure_installed = ts_langs,
          highlight = { enable = true },
        })
      end)
      if not legacy_ok then
        -- current (main-branch) API
        require("nvim-treesitter").install(ts_langs)
        vim.api.nvim_create_autocmd("FileType", {
          group = vim.api.nvim_create_augroup("nvim-trial-treesitter", { clear = true }),
          callback = function(args)
            pcall(vim.treesitter.start, args.buf)
          end,
        })
      end
    end,
  },
  { "nvim-treesitter/nvim-treesitter-context", opts = {} },

  -- LSP (server configs; servers are system-installed: pyright, vtsls, ruff)
  {
    "neovim/nvim-lspconfig",
    config = function()
      vim.lsp.enable({ "pyright", "ruff", "vtsls" })
    end,
  },

  -- Completion (pure-Lua fuzzy matching; no native build required)
  {
    "saghen/blink.cmp",
    version = "1.*",
    opts = {
      fuzzy = { implementation = "lua" },
      completion = { documentation = { auto_show = true } },
    },
  },

  -- Pickers: files, grep, symbols, references, call hierarchy
  {
    "nvim-telescope/telescope.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    keys = {
      { "<leader>ff", function() require("telescope.builtin").find_files() end, desc = "Find files" },
      { "<leader>fg", function() require("telescope.builtin").live_grep() end, desc = "Live grep" },
      { "<leader>fs", function() require("telescope.builtin").lsp_document_symbols() end, desc = "Document symbols" },
      { "<leader>fS", function() require("telescope.builtin").lsp_dynamic_workspace_symbols() end, desc = "Workspace symbols" },
      { "<leader>fr", function() require("telescope.builtin").lsp_references() end, desc = "References" },
      { "<leader>fc", function() require("telescope.builtin").lsp_incoming_calls() end, desc = "Incoming calls" },
      { "<leader>fC", function() require("telescope.builtin").lsp_outgoing_calls() end, desc = "Outgoing calls" },
      { "<leader>fd", function() require("telescope.builtin").diagnostics() end, desc = "Diagnostics" },
      { "<leader>fh", function() require("telescope.builtin").help_tags() end, desc = "Search help" },
      { "<leader>fk", function() require("telescope.builtin").keymaps() end, desc = "Search keymaps" },
    },
  },
  -- Git: inline hunk markers + commit/history diff review
  -- Discoverability: popup menus of available keymaps while you wait mid-keypress
  { "folke/which-key.nvim", opts = {} },
  {
    "lewis6991/gitsigns.nvim",
    opts = {
      on_attach = function(bufnr)
        local gs = package.loaded.gitsigns
        local map = function(lhs, rhs, desc)
          vim.keymap.set("n", lhs, rhs, { buffer = bufnr, desc = desc })
        end
        map("]h", function() gs.nav_hunk("next") end, "Next hunk")
        map("[h", function() gs.nav_hunk("prev") end, "Prev hunk")
        map("<leader>hp", gs.preview_hunk, "Preview hunk")
        map("<leader>hb", gs.blame_line, "Blame line")
        map("<leader>hs", gs.stage_hunk, "Stage hunk")
        map("<leader>hr", gs.reset_hunk, "Reset hunk")
        map("<leader>hd", gs.diffthis, "Diff file vs index")
        map("<leader>hD", function() gs.diffthis("~") end, "Diff file vs HEAD~")
      end,
    },
  },
  -- NOT lazy-loaded: its doc/ must stay on runtimepath for :help to resolve
  -- its tags (telescope help_tags lists docs from unloaded plugins, but
  -- :help can't open them until the plugin loads -> E661)
  { "sindrets/diffview.nvim" },
}, {
  -- everything lives under the nvim-trial data dir; nuke it to reset
  install = { missing = true },
  checker = { enabled = false },
})

-- LSP keymaps beyond nvim 0.11's defaults (grn/gra/grr/gri/grt/gO). Mapped
-- buffer-locally on LspAttach so non-LSP buffers keep vim's built-in gd/K.
local lsp_augroup = vim.api.nvim_create_augroup("nvim-trial-lsp-maps", { clear = true })
vim.api.nvim_create_autocmd("LspAttach", {
  group = lsp_augroup,
  callback = function(args)
    local map = function(lhs, rhs, desc)
      vim.keymap.set("n", lhs, rhs, { buffer = args.buf, desc = desc })
    end
    map("gd", vim.lsp.buf.definition, "LSP: go to definition")
    map("gD", vim.lsp.buf.declaration, "LSP: go to declaration")
    map("K", vim.lsp.buf.hover, "LSP: hover")
    map("gci", vim.lsp.buf.incoming_calls, "LSP: incoming calls")
    map("gco", vim.lsp.buf.outgoing_calls, "LSP: outgoing calls")
  end,
})

-- Floating lazygit -----------------------------------------------------------
local lazygit_win = nil
local function lazygit_toggle()
  if lazygit_win and vim.api.nvim_win_is_valid(lazygit_win) then
    vim.api.nvim_win_close(lazygit_win, true)
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  local width = math.floor(vim.o.columns * 0.9)
  local height = math.floor(vim.o.lines * 0.9)
  lazygit_win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    border = "rounded",
    style = "minimal",
  })
  vim.fn.jobstart({ "lazygit" }, {
    term = true,
    on_exit = function()
      if lazygit_win and vim.api.nvim_win_is_valid(lazygit_win) then
        vim.api.nvim_win_close(lazygit_win, true)
      end
    end,
  })
  vim.cmd("startinsert")
end
vim.keymap.set("n", "<leader>gg", lazygit_toggle, { desc = "Toggle lazygit" })

-- LSP hover border (cosmetic) ------------------------------------------------
vim.lsp.handlers["textDocument/hover"] = vim.lsp.with(vim.lsp.handlers.hover, { border = "rounded" })
