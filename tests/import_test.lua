local treesitter_implementations = require("cmp_go_deep.treesitter")

local test_cases = {
	{
		name = "No imports exist",
		input = {
			"package main",
			"",
			"func main() {",
			"}",
		},
		import_path = "fmt",
		package_alias = nil,
		expected = {
			"package main",
			"",
			"import (",
			'\t"fmt"',
			")",
			"",
			"func main() {",
			"}",
		},
	},
	{
		name = "Exactly one import exists (single line)",
		input = {
			"package main",
			"",
			'import "os"',
			"",
			"func main() {",
			"}",
		},
		import_path = "fmt",
		package_alias = nil,
		expected = {
			"package main",
			"",
			"import (",
			'\t"os"',
			'\t"fmt"',
			")",
			"func main() {",
			"}",
		},
	},
	{
		name = "Multiple imports exist",
		input = {
			"package main",
			"",
			"import (",
			'\t"os"',
			'\t"fmt"',
			")",
			"",
			"func main() {",
			"}",
		},
		import_path = "io",
		package_alias = nil,
		expected = {
			"package main",
			"",
			"import (",
			'\t"os"',
			'\t"fmt"',
			'\t"io"',
			")",
			"",
			"func main() {",
			"}",
		},
	},
	{
		name = "Import with same suffix exists (no alias)",
		input = {
			"package main",
			"",
			"import (",
			'\t"encoding/json"',
			")",
			"",
			"func main() {",
			"}",
		},
		import_path = "github.com/foo/json",
		package_alias = "json2",
		expected = {
			"package main",
			"",
			"import (",
			'\t"encoding/json"',
			'\tjson2 "github.com/foo/json"',
			")",
			"",
			"func main() {",
			"}",
		},
	},
	{
		name = "Import with same suffix exists (with alias)",
		input = {
			"package main",
			"",
			"import (",
			'\tjson1 "encoding/json"',
			")",
			"",
			"func main() {",
			"}",
		},
		import_path = "github.com/foo/json",
		package_alias = "json2",
		expected = {
			"package main",
			"",
			"import (",
			'\tjson1 "encoding/json"',
			'\tjson2 "github.com/foo/json"',
			")",
			"",
			"func main() {",
			"}",
		},
	},
	{
		name = "Multiple imports with duplicate suffix names",
		input = {
			"package main",
			"",
			"import (",
			'\tjson1 "encoding/json"',
			'\tjson2 "github.com/foo/json"',
			'\t"fmt"',
			")",
			"",
			"func main() {",
			"}",
		},
		import_path = "github.com/bar/json",
		package_alias = "json3",
		expected = {
			"package main",
			"",
			"import (",
			'\tjson1 "encoding/json"',
			'\tjson2 "github.com/foo/json"',
			'\t"fmt"',
			'\tjson3 "github.com/bar/json"',
			")",
			"",
			"func main() {",
			"}",
		},
	},
	{
		name = "Add import with alias when no alias needed",
		input = {
			"package main",
			"",
			"import (",
			'\t"fmt"',
			")",
			"",
			"func main() {",
			"}",
		},
		import_path = "os",
		package_alias = "myos",
		expected = {
			"package main",
			"",
			"import (",
			'\t"fmt"',
			'\tmyos "os"',
			")",
			"",
			"func main() {",
			"}",
		},
	},
}

local function run_test(test)
	print(string.format("Running test: %s", test.name))

	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, test.input)
	vim.bo[bufnr].filetype = "go"

	local opts = { notifications = false }
	treesitter_implementations.add_import_statement(opts, bufnr, test.package_alias, test.import_path)

	local result = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	local success = true
	if #result ~= #test.expected then
		print(string.format("  FAILED: Line count mismatch. Expected %d, got %d", #test.expected, #result))
		success = false
	else
		for i, line in ipairs(result) do
			if line ~= test.expected[i] then
				print(string.format("  FAILED: Line %d mismatch", i))
				print(string.format("    Expected: %s", test.expected[i]))
				print(string.format("    Got:      %s", line))
				success = false
				break
			end
		end
	end

	if success then
		print(string.format("  PASSED"))
	else
		print("  Full output:")
		for i, line in ipairs(result) do
			print(string.format("    %d: %s", i, line))
		end
		print("  Expected:")
		for i, line in ipairs(test.expected) do
			print(string.format("    %d: %s", i, line))
		end
	end

	vim.api.nvim_buf_delete(bufnr, { force = true })
	return success
end

local function test_imports()
	print("Starting import tests...")

	local all_passed = true
	for _, test in ipairs(test_cases) do
		local passed = run_test(test)
		if not passed then
			all_passed = false
		end
	end

	if all_passed then
		print("\nAll import tests passed!")
	else
		error("Some import tests failed!")
	end
end

local ok, err = pcall(test_imports)
if not ok then
	print("Import tests failed: " .. tostring(err))
	vim.cmd("cquit 1")
end
