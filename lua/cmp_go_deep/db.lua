local sqlstmt = require("sqlite.stmt")
---@type sqlite_db
local sqlite = require("sqlite.db")

---@class cmp_go_deep.DB
---@field public load fun(self, project_path: string, query_string: string): table
---@field public save fun(self, utils: cmp_go_deep.utils, project_path: string, symbol_information: table): nil
---@field private db sqlite_db
---@field private db_path string
---@field private max_db_size_bytes number
local DB = {}

---@param opts cmp_go_deep.Options
---@return cmp_go_deep.DB
function DB.setup(opts)
	DB.db_path = opts.db_path
	DB.max_db_size_bytes = opts.db_size_limit_bytes
	DB.db = sqlite:open(opts.db_path)

	---TODO: rtfm and fine-tune these

	local result = DB.db:eval("PRAGMA journal_mode = WAL")
	if type(result) == "table" and result[1] and result[1].journal_mode ~= "wal" then
		vim.notify("Failed to set journal_mode to WAL", vim.log.levels.WARN)
	end
	DB.db:eval("PRAGMA synchronous = NORMAL")
	DB.db:eval("PRAGMA temp_store = MEMORY")
	DB.db:eval("PRAGMA cache_size = -10000")
	DB.db:eval("PRAGMA page_size = 4096")
	DB.db:eval("PRAGMA auto_vacuum = INCREMENTAL")
	DB.db:eval("PRAGMA max_page_count = " .. math.ceil(DB.max_db_size_bytes / 4096))

	local tables = {
		[[
		    CREATE TABLE IF NOT EXISTS gosymbols (
		      name TEXT,
		      data TEXT,
		      hash TEXT PRIMARY KEY
		    );
	        ]],

		[[
		    CREATE VIRTUAL TABLE IF NOT EXISTS gosymbols_fts
		    USING fts5(name, project_path, hash UNINDEXED);
		]],
	}

	for _, sql in ipairs(tables) do
		local ok = DB.db:eval(sql)
		if not ok then
			vim.notify("[sqlite] failed to create table", vim.log.levels.WARN)
		end
	end

	return DB
end

---@param project_path string
---@param query_string string
---@return table
function DB:load(project_path, query_string)
	res = self.db:eval(
		"SELECT gosymbols.data FROM gosymbols WHERE gosymbols.hash IN "
			.. "(SELECT hash FROM gosymbols_fts WHERE gosymbols_fts MATCH '"
			.. 'project_path:"'
			.. project_path
			.. '" AND name:'
			.. query_string
			.. "*'"
			.. " LIMIT 100)"
	)

	if type(res) ~= "table" or #res == 0 then
		return {}
	end

	local ret = {}
	for _, row in ipairs(res) do
		ret[#ret + 1] = vim.json.decode(row.data)
	end
	return ret
end

---@param utils cmp_go_deep.utils
---@param project_path string
---@param symbol_information table
--TODO: rtfm and optimize memory usage
--TODO: add configurations for manipulating fuzzy search behavior
--TODO: implement custom fuzzy search logic
function DB:save(utils, project_path, symbol_information)
	-- Prepare the statement to insert into gosymbols table
	local insert_gosymbols = sqlstmt:parse(
		self.db.conn,
		[[
		    INSERT OR REPLACE INTO gosymbols (name, data, hash)
		    VALUES (?, ?, ?);
		]]
	)
	local insert_gosymbols_fts = sqlstmt:parse(
		self.db.conn,
		[[
		    INSERT OR REPLACE INTO gosymbols_fts (name, project_path, hash)
		    VALUES (?, ?, ?);
		]]
	)

	self.db:eval("BEGIN TRANSACTION;")
	for _, symbol in ipairs(symbol_information) do
		local encoded = vim.json.encode(symbol)
		local hash = utils.deterministic_symbol_hash(symbol)

		insert_gosymbols:bind({ symbol.name, encoded, hash })
		insert_gosymbols:step()
		insert_gosymbols:reset()

		insert_gosymbols_fts:bind({ symbol.name, project_path, hash })
		insert_gosymbols_fts:step()
		insert_gosymbols_fts:reset()
	end
	self.db:eval("END TRANSACTION;")

	insert_gosymbols:finalize()
	insert_gosymbols_fts:finalize()
end

return DB
