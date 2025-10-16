---@brief
---
--- https://github.com/golang/tools/tree/master/gopls
---
--- Google's lsp server for golang.

--- @class go_dir_custom_args
---
--- @field envvar_id string
---
--- @field custom_subdir string?

local mod_cache = nil
local std_lib = nil

---@param custom_args go_dir_custom_args
---@param on_complete fun(dir: string | nil)
local function identify_go_dir(custom_args, on_complete)
	local cmd = { "go", "env", custom_args.envvar_id }
	vim.system(cmd, { text = true }, function(output)
		local res = vim.trim(output.stdout or "")
		if output.code == 0 and res ~= "" then
			if custom_args.custom_subdir and custom_args.custom_subdir ~= "" then
				res = res .. custom_args.custom_subdir
			end
			on_complete(res)
		else
			vim.schedule(function()
				vim.notify(
					("[gopls] identify " .. custom_args.envvar_id .. " dir cmd failed with code %d: %s\n%s"):format(
						output.code,
						vim.inspect(cmd),
						output.stderr
					)
				)
			end)
			on_complete(nil)
		end
	end)
end

---@return string?
local function get_std_lib_dir()
	if std_lib and std_lib ~= "" then
		return std_lib
	end

	identify_go_dir({ envvar_id = "GOROOT", custom_subdir = "/src" }, function(dir)
		if dir then
			std_lib = dir
		end
	end)
	return std_lib
end

---@return string?
local function get_mod_cache_dir()
	if mod_cache and mod_cache ~= "" then
		return mod_cache
	end

	identify_go_dir({ envvar_id = "GOMODCACHE" }, function(dir)
		if dir then
			mod_cache = dir
		end
	end)
	return mod_cache
end

---@param fname string
---@return string?
local function get_root_dir(fname)
	if mod_cache and fname:sub(1, #mod_cache) == mod_cache then
		local clients = vim.lsp.get_clients({ name = "gopls" })
		if #clients > 0 then
			return clients[#clients].config.root_dir
		end
	end
	if std_lib and fname:sub(1, #std_lib) == std_lib then
		local clients = vim.lsp.get_clients({ name = "gopls" })
		if #clients > 0 then
			return clients[#clients].config.root_dir
		end
	end
	return vim.fs.root(fname, "go.work") or vim.fs.root(fname, "go.mod") or vim.fs.root(fname, ".git")
end

local test_project = vim.fn.getcwd() .. "/test_project"
local test_file = test_project .. "/main.go"

local function test_completion_source()
	print("Testing completions...")

	local go_mod = test_project .. "/go.mod"
	vim.fn.delete(test_project, "rf")
	vim.fn.mkdir(test_project, "p")

	vim.fn.writefile({ "module testproject", "", "go 1.25.1" }, go_mod)

	local helper_dir = test_project .. "/helper"
	vim.fn.mkdir(helper_dir, "p")
	local helper_file = helper_dir .. "/types.go"
	vim.fn.writefile({
		"package helper",
		"",
		"type CustomHelper struct {",
		"\tValue string",
		"}",
		"",
		"type AnotherType struct {",
		"\tID int",
		"}",
		"",
		"func NewCustomHelper() *CustomHelper {",
		"\treturn &CustomHelper{}",
		"}",
	}, helper_file)

	vim.fn.writefile({
		"package main",
		"",
		'import "fmt"',
		"",
		"func main() {",
		"        // Test specific unimported package completions",
		"printf ",
		"customhel ",
		"}",
	}, test_file)

	vim.cmd("edit " .. test_file)
	vim.bo.filetype = "go"

	vim.lsp.start({
		cmd = { "gopls" },
		filetypes = { "go", "gomod", "gowork", "gotmpl" },
		root_dir = function(bufnr, on_dir)
			local fname = vim.api.nvim_buf_get_name(bufnr)
			get_mod_cache_dir()
			get_std_lib_dir()
			-- see: https://github.com/neovim/nvim-lspconfig/issues/804
			on_dir(get_root_dir(fname))
		end,
		settings = {
			gopls = { completeUnimported = true },
		},
	})

	vim.wait(10000, function()
		return #vim.lsp.get_clients({ name = "gopls" }) > 0
	end)

	local gopls_client = vim.lsp.get_clients({ name = "gopls" })[1]
	if gopls_client then
		local ready = false
		gopls_client:request("workspace/symbol", { query = "" }, function()
			ready = true
		end, 0)
		vim.wait(10000, function()
			return ready
		end)
	end

	local source = require("cmp_go_deep")
	local source_instance = source.new()

	if not source_instance.is_available() then
		vim.fn.delete(test_file)
		return
	end

	local triggers = source_instance.get_trigger_characters()
	assert(type(triggers) == "table", "get_trigger_characters should return a table")

	local test_cases = {
		{ row = 7, col = 1, full_prefix = "printf", expected = "fmt.Sprintf" },
		{ row = 8, col = 1, full_prefix = "customhel", expected = "helper.CustomHelper" },
	}
	local tests_done = false
	local test_failures = {}

	coroutine.wrap(function()
		for idx, test_case in ipairs(test_cases) do
			print(string.format("Test case %d: looking for '%s'", idx, test_case.expected))
			local found_expected = false

			for i = 1, #test_case.full_prefix do
				local cursor_col = test_case.col + i - 1

				vim.api.nvim_win_set_cursor(0, { test_case.row, cursor_col })

				local co = coroutine.running()
				source_instance.complete(nil, {}, function(result)
					local items = result.items or {}

					for _, item in ipairs(items) do
						if item.label == test_case.expected then
							found_expected = true
							print(string.format("    ✓ Found: %s", item.label))
							break
						end
					end
					coroutine.resume(co)
				end)
				coroutine.yield()

				if found_expected then
					break
				end

				vim.wait(1500)
			end

			if not found_expected then
				table.insert(
					test_failures,
					string.format(
						"Test case %d failed: could not find expected completion '%s'",
						idx,
						test_case.expected
					)
				)
			end
		end

		tests_done = true
	end)()

	vim.wait(15000, function()
		return tests_done
	end)

	if #test_failures > 0 then
		error(table.concat(test_failures, "\n"))
	end

	local gopls_clients = vim.lsp.get_clients({ name = "gopls" })
	for _, client in ipairs(gopls_clients) do
		client:stop()
	end
	vim.wait(2000, function()
		return #vim.lsp.get_clients({ name = "gopls" }) == 0
	end)
	vim.fn.delete(test_file)
end

if test_project == "" then
	print("Could not determine test project path")
	return vim.cmd("cquit 1")
end

local ok, err = pcall(test_completion_source)

vim.fn.delete(test_project, "rf")

if not ok then
	print("Completion test failed: " .. err)
	return vim.cmd("cquit 1")
end

print("All completion tests passed!")
