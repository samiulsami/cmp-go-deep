local utils = require("cmp_go_deep.utils")

local is_internal_tests = {
	{ path = "internal", expected = true },
	{ path = "internal/foo", expected = true },
	{ path = "foo/internal", expected = true },
	{ path = "foo/internal/bar", expected = true },
	{ path = "/project/internal/pkg/file.go", expected = true },
	{ path = "/project/pkg/internal/file.go", expected = true },
	{ path = "foo/internalbar", expected = false },
	{ path = "foointernal/bar", expected = false },
	{ path = "foo/bar", expected = false },
	{ path = "/project/pkg/file.go", expected = false },
}

local can_import_tests = {
	-- Same directory as internal parent
	{ symbol = "/project/internal/foo.go", current = "/project/main.go", expected = true },
	-- Subdirectory of internal parent
	{ symbol = "/project/internal/foo.go", current = "/project/cmd/main.go", expected = true },
	{ symbol = "/project/internal/foo.go", current = "/project/cmd/sub/main.go", expected = true },
	-- Nested internal
	{ symbol = "/project/pkg/internal/foo.go", current = "/project/pkg/main.go", expected = true },
	{ symbol = "/project/pkg/internal/foo.go", current = "/project/pkg/sub/main.go", expected = true },
	-- Not in subtree
	{ symbol = "/project/pkg/internal/foo.go", current = "/project/main.go", expected = false },
	{ symbol = "/project/pkg/internal/foo.go", current = "/project/other/main.go", expected = false },
	-- Prefix collision (pkgfoo should not match pkg)
	{ symbol = "/project/pkg/internal/foo.go", current = "/project/pkgfoo/main.go", expected = false },
	-- Non-internal paths
	{ symbol = "/project/pkg/foo.go", current = "/anywhere/main.go", expected = true },
}

local function run_is_internal_tests()
	print("Running is_internal_package tests...")
	local passed = 0
	local failed = 0

	for _, test in ipairs(is_internal_tests) do
		local result = utils.is_internal_package(test.path)
		if (result and true or false) == test.expected then
			passed = passed + 1
		else
			failed = failed + 1
			print(string.format("  FAILED: is_internal_package(%q) = %s, expected %s", test.path, tostring(result), tostring(test.expected)))
		end
	end

	print(string.format("  %d passed, %d failed", passed, failed))
	return failed == 0
end

local function run_can_import_tests()
	print("Running can_import_internal tests...")
	local passed = 0
	local failed = 0

	for _, test in ipairs(can_import_tests) do
		local result = utils.can_import_internal(test.symbol, test.current)
		if result == test.expected then
			passed = passed + 1
		else
			failed = failed + 1
			print(string.format("  FAILED: can_import_internal(%q, %q) = %s, expected %s", test.symbol, test.current, tostring(result), tostring(test.expected)))
		end
	end

	print(string.format("  %d passed, %d failed", passed, failed))
	return failed == 0
end

local function test_internal()
	print("Starting internal package tests...")

	local all_passed = run_is_internal_tests() and run_can_import_tests()

	if all_passed then
		print("\nAll internal package tests passed!")
	else
		error("Some internal package tests failed!")
	end
end

local ok, err = pcall(test_internal)
if not ok then
	print("Internal package tests failed: " .. tostring(err))
	vim.cmd("cquit 1")
end
