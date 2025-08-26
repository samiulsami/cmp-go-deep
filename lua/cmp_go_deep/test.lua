--TODO: add this to ci

local DB = require("cmp_go_deep.db")
local utils = require("cmp_go_deep.utils")
local math = math
local os = os

-- Random string generator
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
			kind = math.random(1, 25), -- LSP SymbolKind (1–25)
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

-- Main population script
local function populate()
	math.randomseed(os.time())

	local opts = {
		db_path = vim.fn.stdpath("data") .. "/cmp_go_deep.sqlite3",
		db_size_limit_bytes = 100 * 1024 * 1024,
	}
	local db = DB.setup(opts)

	local total = 100000
	for _ = 1, total / 100 do
		local total2 = 100
		local data = generate_fake_symbols(total2)
		db:save(utils, data)
	end
	vim.notify("[populate] Done! Inserted " .. total .. " symbols.", vim.log.levels.INFO)
end

populate()
