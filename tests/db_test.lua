local DB = require("cmp_go_deep.db")
local utils = require("cmp_go_deep.utils")

local function random_string(length)
	local chars = "abcdefghijklmnopqrstuvwxyz"
	local result = {}
	for _ = 1, length do
		local index = math.random(1, #chars)
		table.insert(result, chars:sub(index, index))
	end
	return table.concat(result)
end

local function generate_fake_symbols(n)
	local symbols = {}
	for i = 1, n do
		local name = "Sym_" .. random_string(math.random(3, 60)) .. tostring(i)
		local symbol = {
			name = name,
			name_lower = string.lower(name),
			kind = math.random(1, 25),
			containerName = "pkg" .. tostring(i % 100),
			location = {
				uri = "file:///fake/path/file" .. tostring(i % 500) .. ".go",
				range = {
					start = { line = 0, character = 0 },
					["end"] = { line = 0, character = 0 },
				},
			},
		}
		table.insert(symbols, symbol)
	end
	return symbols
end

local function test_db()
	print("Starting DB stress test...")
	math.randomseed(os.time())

	local test_db_path = vim.fn.stdpath("data") .. "/cmp_go_deep.sqlite3"

	local opts = {
		db_path = test_db_path,
		notifications = false,
		debug = false,
	}
	local db = DB.setup(opts)

	if not db then
		error("Failed to initialize DB")
	end

	local total = 200000
	local batch_size = 100
	print(string.format("Inserting %d symbols in batches of %d...", total, batch_size))

	for i = 1, total / batch_size do
		local data = generate_fake_symbols(batch_size)
		db:save(utils, data)
		if i % 100 == 0 then
			print(string.format("Progress: %d/%d batches", i, total / batch_size))
		end
	end

	print("Rudimentary db corruption check:")
	local results = db:load("Sym", "fuzzy")
	print(string.format("Loaded %d results for 'Sym'", #results))

	results = db:load("test", "fuzzy")
	print(string.format("Loaded %d results for 'test'", #results))

	print("DB stress test completed successfully!")
end

local ok, err = pcall(test_db)
if not ok then
	print("DB test failed: " .. tostring(err))
	vim.cmd("cquit 1")
else
	print("All DB tests passed!")
end
