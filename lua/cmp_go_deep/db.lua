local sqlstmt = require("sqlite.stmt")
---@type sqlite_db
local sqlite = require("sqlite.db")
local math = require("math")

---@class cmp_go_deep.DB
---@field public setup fun(opts: cmp_go_deep.Options): cmp_go_deep.DB?
---@field public load fun(self, query_string: string, match_strategy: string | "fuzzy" | "name" | "name_lower"): table
---@field public save fun(self, utils: cmp_go_deep.utils, symbol_information: table): nil
---@field private load_by_name_stmt sqlstmt
---@field private load_by_name_lower_stmt sqlstmt
---@field private load_by_fuzzy_text_stmt sqlstmt
---@field private insert_gosymbols_stmt sqlstmt
---@field private insert_gosymbols_fts_stmt sqlstmt
---@field private last_insert_rowid_stmt sqlstmt
---@field private delete_fts_stmt sqlstmt
---@field private delete_gosymbols_stmt sqlstmt
---@field private db sqlite_db
---@field private db_path string
---@field private notifications boolean
---@field private MAX_DB_SIZE_BYTES number
---@field private PRUNE_PERCENTAGE_THRESHOLD number
local DB = {
	MAX_DB_SIZE_BYTES = 100 * 1024 * 1024,
	PRUNE_PERCENTAGE_THRESHOLD = 0.8,
}
local SCHEMA_VERSION = "0.0.12"

---@param opts cmp_go_deep.Options
---@return cmp_go_deep.DB?
function DB.setup(opts)
	DB.notifications = opts.notifications
	DB.db_path = opts.db_path
	DB.db = sqlite:open(opts.db_path)

	local result = DB.db:eval("PRAGMA journal_mode = WAL")
	if type(result) == "table" and result[1] and result[1].journal_mode ~= "wal" then
		if DB.notifications then
			vim.notify("Failed to set journal_mode to WAL", vim.log.levels.WARN)
		end
	end
	DB.db:eval("PRAGMA page_size = 8192")
	DB.db:eval("PRAGMA synchronous = NORMAL")
	DB.db:eval("PRAGMA temp_store = MEMORY")
	DB.db:eval("PRAGMA cache_size = -100000")
	DB.db:eval("PRAGMA mmap_size = 268435456")
	DB.db:eval("PRAGMA wal_autocheckpoint = 2000")
	DB.db:eval("PRAGMA busy_timeout = 5000")
	DB.db:eval("PRAGMA auto_vacuum = incremental")

	DB.db:eval([[
		    CREATE TABLE IF NOT EXISTS meta (
			version TEXT PRIMARY KEY
	  	    );
		]])

	local res = DB.db:eval("SELECT version FROM meta;")
	if type(res) ~= "table" or #res == 0 or res[1].version ~= SCHEMA_VERSION then
		DB.db:eval("DELETE FROM meta")
		DB.db:eval("INSERT INTO meta (version) VALUES ('" .. SCHEMA_VERSION .. "')")
		DB.db:eval("DROP TABLE IF EXISTS gosymbols")
		DB.db:eval("DROP TABLE IF EXISTS gosymbols_fts")
		DB.db:eval("DROP TABLE IF EXISTS gosymbol_cache")
		DB.db:eval("VACUUM;")
		DB.db:eval("PRAGMA wal_checkpoint(TRUNCATE);")
	end

	local tables = {
		[[
		    CREATE TABLE IF NOT EXISTS gosymbols (
		      id INTEGER PRIMARY KEY AUTOINCREMENT,
		      hash TEXT UNIQUE NOT NULL,
		      data TEXT NOT NULL,
		      last_modified INTEGER NOT NULL
		    );
	        ]],

		[[
		    CREATE VIRTUAL TABLE IF NOT EXISTS gosymbols_fts
		    USING fts5(name, name_lower, fuzzy_text, id, tokenize='trigram');
		]],
	}

	for _, sql in ipairs(tables) do
		if not DB.db:eval(sql) then
			if DB.notifications then
				vim.notify("[sqlite] failed to create table", vim.log.levels.ERROR)
			end
			return nil
		end
	end

	res = DB.db:eval("SELECT COUNT(*) as count FROM gosymbols")
	if type(res) ~= "table" or #res == 0 then
		if DB.notifications then
			vim.notify("[sqlite] error reading db row count", vim.log.levels.ERROR)
		end
		return nil
	end

	DB.db:eval("CREATE INDEX IF NOT EXISTS idx_last_modified ON gosymbols (last_modified DESC);")
	DB.db:eval("CREATE INDEX IF NOT EXISTS idx_hash ON gosymbols (hash DESC);")

	DB.load_by_fuzzy_text_stmt = sqlstmt:parse(
		DB.db.conn,
		[[
			SELECT gosymbols.data FROM gosymbols
			JOIN gosymbols_fts ON gosymbols.id = gosymbols_fts.id
			WHERE gosymbols_fts.fuzzy_text LIKE '%' || ? || '%'
			ORDER BY gosymbols.last_modified DESC
			LIMIT 100;
	]]
	)

	DB.load_by_name_stmt = sqlstmt:parse(
		DB.db.conn,
		[[
			SELECT gosymbols.data FROM gosymbols
			JOIN gosymbols_fts ON gosymbols.id = gosymbols_fts.id
			WHERE gosymbols_fts.name LIKE '%' || ? || '%'
			ORDER BY gosymbols.last_modified DESC
			LIMIT 100;
	]]
	)

	DB.load_by_name_lower_stmt = sqlstmt:parse(
		DB.db.conn,
		[[
			SELECT gosymbols.data FROM gosymbols
			JOIN gosymbols_fts ON gosymbols.id = gosymbols_fts.id
			WHERE gosymbols_fts.name_lower LIKE '%' || ? || '%'
			ORDER BY gosymbols.last_modified DESC
			LIMIT 100;
	]]
	)

	DB.insert_gosymbols_stmt = sqlstmt:parse(
		DB.db.conn,
		[[
		    INSERT OR REPLACE INTO gosymbols (data, hash, last_modified)
		    VALUES (?, ?, ?);
		]]
	)

	DB.last_insert_rowid_stmt = sqlstmt:parse(
		DB.db.conn,
		[[
		    SELECT last_insert_rowid();
		]]
	)

	DB.insert_gosymbols_fts_stmt = sqlstmt:parse(
		DB.db.conn,
		[[
		    INSERT OR REPLACE INTO gosymbols_fts (name, name_lower, fuzzy_text, id)
		    VALUES (?, ?, ?, ?);
		]]
	)

	DB.delete_gosymbols_stmt = sqlstmt:parse(
		DB.db.conn,
		[[
		    DELETE FROM gosymbols
		    WHERE id IN (
			    SELECT id FROM gosymbols ORDER BY last_modified ASC LIMIT ?
		    );
		]]
	)

	DB.delete_fts_stmt = sqlstmt:parse(
		DB.db.conn,
		[[
		    DELETE FROM gosymbols_fts
		    WHERE id IN (
			    SELECT id FROM gosymbols ORDER BY last_modified ASC LIMIT ?
		    );
		]]
	)

	return DB
end

---@param query_string string
---@param match_strategy string | "fuzzy" | "name" | "name_lower"
---@return table
function DB:load(query_string, match_strategy)
	local stmt = self.load_by_fuzzy_text_stmt
	if match_strategy == "name" then
		stmt = self.load_by_name_stmt
	elseif match_strategy == "name_lower" then
		stmt = self.load_by_name_lower_stmt
	end
	stmt:bind({ query_string })

	local ret = {}
	stmt:kvrows(function(kv)
		ret[#ret + 1] = vim.json.decode(kv.data)
	end)
	stmt:reset()

	return ret
end

---@return nil
function DB:prune()
	local res = self.db:eval("SELECT page_count * page_size as size FROM pragma_page_count(), pragma_page_size();")
	if type(res) ~= "table" or #res == 0 then
		if self.notifications then
			vim.notify("[sqlite] error reading db size while pruning", vim.log.levels.ERROR)
		end
		return
	end

	local current_db_size = res[1].size
	local prune_threshold = self.MAX_DB_SIZE_BYTES * self.PRUNE_PERCENTAGE_THRESHOLD
	if current_db_size <= prune_threshold then
		return
	end

	local target_db_size = prune_threshold * 0.9
	local bytes_to_free = current_db_size - target_db_size
	if bytes_to_free <= 0 then
		return
	end

	res = self.db:eval("SELECT COUNT(*) as count FROM gosymbols")
	if type(res) ~= "table" or #res == 0 then
		if self.notifications then
			vim.notify("[sqlite] error reading db row count during pruning", vim.log.levels.ERROR)
		end
		return
	end

	local row_count = res[1].count
	local bytes_per_row = current_db_size / row_count
	local rows_to_delete = math.min(row_count, math.ceil(bytes_to_free / bytes_per_row))

	if rows_to_delete <= 0 then
		return
	end

	self.delete_gosymbols_stmt:bind({ rows_to_delete })
	self.delete_fts_stmt:bind({ rows_to_delete })

	if not self.db:eval("BEGIN TRANSACTION;") then
		if self.notifications then
			vim.notify("[sqlite] failed to begin transaction", vim.log.levels.ERROR)
		end
		return
	end

	---@param msg string
	local rollback = function(msg)
		if self.notifications then
			vim.notify("[sqlite] " .. msg, vim.log.levels.ERROR)
		end
		self.db:eval("PRAGMA wal_checkpoint(RESTART);")
		self.db:eval("ROLLBACK;")
	end

	if self.delete_fts_stmt:step() ~= sqlite.flags["done"] then
		return rollback("failed to perform deletion of gosymbols_fts")
	end
	if not self.delete_fts_stmt:reset() then
		return rollback("failed to reset delete gosymbols_fts")
	end

	if self.delete_gosymbols_stmt:step() ~= sqlite.flags["done"] then
		return rollback("failed to perform deletion of gosymbols")
	end
	if not self.delete_gosymbols_stmt:reset() then
		return rollback("failed to reset delete gosymbols")
	end

	if not self.db:eval("END TRANSACTION;") then
		return rollback("failed to end transaction")
	end

	self.db:eval("PRAGMA wal_checkpoint(TRUNCATE);")
	self.db:eval("PRAGMA incremental_vacuum;")
end

---@param utils cmp_go_deep.utils
---@param symbol_information table
function DB:save(utils, symbol_information) --- assumes that gopls doesn't return more than 100 workspace symbols
	local last_modified = os.time()
	if not self.db:eval("BEGIN TRANSACTION;") then
		if self.notifications then
			vim.notify("[sqlite] failed to begin transaction", vim.log.levels.ERROR)
		end
		return
	end

	---@param msg string
	local rollback = function(msg)
		if self.notifications then
			vim.notify("[sqlite] " .. msg, vim.log.levels.ERROR)
		end
		self.db:eval("PRAGMA wal_checkpoint(RESTART);")
		self.db:eval("PRAGMA incremental_vacuum;")
		self.db:eval("ROLLBACK;")
	end

	for _, symbol in ipairs(symbol_information) do
		local encoded = vim.json.encode(symbol)
		local hash = utils.deterministic_symbol_hash(symbol)

		self.insert_gosymbols_stmt:bind({ encoded, hash, last_modified })
		if self.insert_gosymbols_stmt:step() ~= sqlite.flags["done"] then
			return rollback("failed to insert gosymbols row")
		end
		if self.insert_gosymbols_stmt:reset() ~= sqlite.flags["ok"] then
			return rollback("failed to reset insert_gosymbols")
		end

		if self.last_insert_rowid_stmt:step() ~= sqlite.flags["row"] then
			return rollback("failed to select id")
		end
		local id = self.last_insert_rowid_stmt:val(0)
		if self.last_insert_rowid_stmt:reset() ~= sqlite.flags["ok"] then
			return rollback("failed to reset last_insert_rowid_stmt")
		end

		self.insert_gosymbols_fts_stmt:bind({
			symbol.name,
			symbol.name_lower,
			(symbol.fuzzy_text or "") .. symbol.name_lower,
			id,
		})
		if self.insert_gosymbols_fts_stmt:step() ~= sqlite.flags["done"] then
			return rollback("failed to insert gosymbols_fts row")
		end
		if self.insert_gosymbols_fts_stmt:reset() ~= sqlite.flags["ok"] then
			return rollback("failed to reset insert_gosymbols_fts")
		end
	end

	if not self.db:eval("END TRANSACTION;") then
		return rollback("failed to end transaction")
	end

	vim.schedule(function()
		self:prune()
	end)
end

return DB
