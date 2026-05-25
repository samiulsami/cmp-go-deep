local test_project = vim.fn.getcwd() .. "/test_project"
local test_file = test_project .. "/main.go"
local test_db = test_project .. "/cmp_go_deep.sqlite3"

local function write_file(path, lines)
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	vim.fn.writefile(lines, path)
end

local function setup_project()
	vim.fn.delete(test_project, "rf")
	vim.fn.mkdir(test_project, "p")

	write_file(test_project .. "/go.mod", {
		"module testproject",
		"",
		"go 1.25.1",
	})

	write_file(test_project .. "/helper/types.go", {
		"package helper",
		"",
		"type ZzDeepTestCustomHelper struct {",
		"\tValue string",
		"}",
	})

	write_file(test_file, {
		"package main",
		"",
		"func main() {",
		"\tzzdeeptestcust",
		"}",
	})
end

local function start_gopls()
	vim.cmd.edit(test_file)
	vim.bo.filetype = "go"

	vim.lsp.start({
		cmd = { "gopls" },
		name = "gopls",
		root_dir = test_project,
		filetypes = { "go", "gomod", "gowork" },
		settings = { gopls = { completeUnimported = true } },
	})

	vim.wait(10000, function()
		return #vim.lsp.get_clients({ name = "gopls" }) > 0
	end)

	local client = vim.lsp.get_clients({ name = "gopls" })[1]
	assert(client, "gopls did not start")
	return client
end

local function poll_completion(prefix, expected_label)
	local found = false
	local items = {}
	require("cmp_go_deep").attach_to_buffer(0)
	vim.api.nvim_exec_autocmds("TextChangedI", { buffer = 0 })

	vim.wait(15000, function()
		items = require("cmp_go_deep").completefunc(0, prefix).words or {}
		for _, item in ipairs(items) do
			if item.word == expected_label then
				found = true
				return true
			end
		end
		return false
	end, 100)

	assert(found, "expected completion not found: " .. expected_label .. " from " .. vim.inspect(items))
end

local function test_completion()
	setup_project()
	start_gopls()

	require("cmp_go_deep").setup({
		notifications = false,
		debounce_gopls_requests_ms = 25,
		native_min_keyword_length = 2,
		native_max_items = 20,
		db_path = test_db,
	})
	require("cmp_go_deep").attach_to_buffer(0)

	vim.api.nvim_win_set_cursor(0, { 4, 10 })
	poll_completion("zzdeeptestcust", "helper.ZzDeepTestCustomHelper")

	vim.v.completed_item = {
		user_data = vim.json.encode({
			cmp_go_deep = {
				import_path = "testproject/helper",
				package_alias = "helper",
			},
		}),
	}
	require("cmp_go_deep").on_complete_done(0)

	vim.wait(1000, function()
		local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
		return vim.tbl_contains(lines, '\thelper "testproject/helper"')
	end)

	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	assert(vim.tbl_contains(lines, '\thelper "testproject/helper"'), "import insertion failed")
end

local ok, err = pcall(test_completion)

for _, client in ipairs(vim.lsp.get_clients({ name = "gopls" })) do
	client:stop()
end
vim.cmd("silent! bwipeout!")
vim.fn.delete(test_project, "rf")

if not ok then
	print("Completion test failed: " .. tostring(err))
	vim.cmd.cquit(1)
end

print("All completion tests passed!")
