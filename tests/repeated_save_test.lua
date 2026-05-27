local DB = require("cmp_go_deep.db")
local utils = require("cmp_go_deep.utils")

---@param db cmp_go_deep.DB
---@param sql string
---@return integer
local function scalar_count(db, sql)
	local rows = db.db:eval(sql)
	if type(rows) ~= "table" or #rows == 0 then
		return 0
	end

	local row = rows[1]
	for _, value in pairs(row) do
		return tonumber(value) or 0
	end

	return 0
end

---@param index integer
---@return lsp.SymbolInformation
local function make_symbol(index)
	local basename = "CacheCandidate" .. tostring(index)
	return {
		name = basename,
		name_lower = string.lower(basename),
		fuzzy_text = "cache" .. string.lower(basename),
		kind = 12,
		containerName = "pkg" .. tostring(index % 4),
		location = {
			uri = "file:///workspace/file" .. tostring(index % 8) .. ".go",
			range = {
				start = { line = index, character = 1 },
				["end"] = { line = index, character = 6 },
			},
		},
	}
end

---@param total integer
---@return lsp.SymbolInformation[]
local function build_batch(total)
	---@type lsp.SymbolInformation[]
	local batch = {}
	for i = 1, total do
		batch[i] = make_symbol(i)
	end
	return batch
end

---@param actual integer
---@param expected integer
---@param label string
---@return nil
local function expect_equal(actual, expected, label)
	if actual == expected then
		return
	end

	error(string.format("%s mismatch: got %d expected %d", label, actual, expected))
end

---@return string
local function fresh_db_path()
	local base = vim.fn.stdpath("data") .. "/cmp_go_deep_repeated_save_test.sqlite3"
	for _, ext in ipairs({ "", "-shm", "-wal" }) do
		vim.fn.delete(base .. ext)
	end
	return base
end

local function run_test()
	print("Checking repeated-save FTS behavior...")

	---@type cmp_go_deep.Options
	local opts = {
		db_path = fresh_db_path(),
		notifications = false,
		debug = false,
	}

	local db = DB.setup(opts)
	if not db then
		error("database setup failed")
	end

	local unique_symbol_count = 40
	local save_rounds = 25
	local symbols = build_batch(unique_symbol_count)

	for _ = 1, save_rounds do
		db:save(utils, symbols)
	end

	local symbol_rows = scalar_count(db, "SELECT COUNT(*) AS count FROM gosymbols")
	local fts_rows = scalar_count(db, "SELECT COUNT(*) AS count FROM gosymbols_fts")

	expect_equal(symbol_rows, unique_symbol_count, "gosymbol rows")
	expect_equal(fts_rows, unique_symbol_count, "fts rows")

	local matches = db:load("cachecandidate", "name_lower")
	if #matches == 0 then
		error("expected repeated-save data to remain searchable")
	end

	print(string.format(
		"Repeated-save check passed: %d symbols, %d FTS rows, %d save rounds",
		symbol_rows,
		fts_rows,
		save_rounds
	))
end

local ok, err = pcall(run_test)
if not ok then
	print("Repeated-save test failed: " .. tostring(err))
	vim.cmd("cquit 1")
	return
end

print("Repeated-save test passed!")
