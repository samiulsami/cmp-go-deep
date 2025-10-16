local tmp_dir = vim.fn.stdpath("data") .. "/cmp-go-deep-test"
vim.fn.mkdir(tmp_dir, "p")

local plugin_dir = vim.fn.getcwd()

vim.opt.runtimepath:prepend(plugin_dir)
vim.opt.packpath:prepend(plugin_dir)

local plugins_dir = tmp_dir .. "/plugins"
vim.fn.mkdir(plugins_dir, "p")

local function clone_plugin(repo, name)
	local path = plugins_dir .. "/" .. name
	if vim.fn.isdirectory(path) == 0 then
		vim.fn.system({ "git", "clone", "--depth=1", "https://github.com/" .. repo, path })
	end
	vim.opt.runtimepath:prepend(path)
end

clone_plugin("kkharji/sqlite.lua", "sqlite.lua")
clone_plugin("hrsh7th/nvim-cmp", "nvim-cmp")
clone_plugin("Saghen/blink.cmp", "blink.cmp")
clone_plugin("neovim/nvim-lspconfig", "nvim-lspconfig")
clone_plugin("nvim-treesitter/nvim-treesitter", "nvim-treesitter")
