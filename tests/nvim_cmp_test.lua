local function test_nvim_cmp()
	print("Testing nvim-cmp integration...")

	local cmp = require("cmp")
	local source = require("cmp_go_deep")

	cmp.setup({
		sources = {
			{ name = "cmp_go_deep" },
		},
	})

	cmp.register_source("cmp_go_deep", source.new())

	local test_file = vim.fn.tempname() .. ".go"
	vim.fn.writefile({
		"package main",
		"",
		"import \"fmt\"",
		"",
		"func main() {",
		"	fmt.",
		"}",
	}, test_file)

	vim.cmd("edit " .. test_file)
	vim.bo.filetype = "go"

	local source_instance = source.new()

	if not source_instance.is_available() then
		print("Source not available (gopls not running), skipping...")
		vim.fn.delete(test_file)
		return
	end

	print("Testing complete callback...")
	local completed = false
	source_instance.complete(nil, {
		option = {},
		context = {
			cursor = { row = 6, col = 6 },
		},
	}, function(result)
		completed = true
		print(string.format("Received %d items", #(result.items or {})))
	end)

	vim.wait(5000, function()
		return completed
	end)

	if not completed then
		error("Complete callback never called")
	end

	vim.fn.delete(test_file)
	print("nvim-cmp integration test passed!")
end

local ok, err = pcall(test_nvim_cmp)
if not ok then
	print("nvim-cmp test failed: " .. tostring(err))
	vim.cmd("cquit 1")
else
	print("All nvim-cmp tests passed!")
end
