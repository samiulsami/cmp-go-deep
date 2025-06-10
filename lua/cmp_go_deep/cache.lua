local sqlstmt = require("sqlite.stmt")
---@type sqlite_db
local sqlite = require("sqlite.db")
local math = require("math")

---@class cmp_go_deep.cache
---@field public setup fun(opts: cmp_go_deep.Options): cmp_go_deep.cache?
---@field public load fun(self, query_string: string, match_name: boolean?): table
---@field public save fun(self, utils: cmp_go_deep.utils, symbol_information: table): nil
---@field public save_in_memory fun(self, utils: cmp_go_deep.utils, symbol_information: table): nil
---@field private load_by_name_stmt sqlstmt
---@field private load_by_fuzzy_text_stmt sqlstmt
---@field private insert_gosymbols_stmt sqlstmt
---@field private insert_gosymbols_fts_stmt sqlstmt
---@field private last_insert_rowid_stmt sqlstmt
---@field private delete_fts_stmt sqlstmt
---@field private delete_gosymbols_stmt sqlstmt
---@field private db sqlite_db
---@field private db_path string
---@field private max_db_size_bytes number
---@field private total_rows_estimate number -- pessimistic overestimation
---@field private notifications boolean
---@field private MAX_ROWS_THRESHOLD number
local cache = {}
local SCHEMA_VERSION = "0.0.8"

---@param opts cmp_go_deep.Options
---@return cmp_go_deep.cache?
function cache.setup(opts)
	cache.notifications = opts.notifications
	cache.db_path = opts.db_path
	cache.max_db_size_bytes = opts.db_size_limit_bytes
	cache.db = sqlite:open(opts.db_path)
	cache.MAX_ROWS_THRESHOLD = math.min(100000, math.floor(opts.db_size_limit_bytes / 1024))
	cache.MAX_ROWS_THRESHOLD = math.max(cache.MAX_ROWS_THRESHOLD, 10000)

	---TODO: rtfm and fine-tune these
	local result = cache.db:eval("PRAGMA journal_mode = WAL")
	if type(result) == "table" and result[1] and result[1].journal_mode ~= "wal" then
		if cache.notifications then
			vim.notify("Failed to set journal_mode to WAL", vim.log.levels.WARN)
		end
	end
	cache.db:eval("PRAGMA synchronous = NORMAL")
	cache.db:eval("PRAGMA temp_store = MEMORY")
	cache.db:eval("PRAGMA cache_size = -10000")
	cache.db:eval("PRAGMA wal_autocheckpoint = 1000")
	cache.db:eval("PRAGMA page_size = 4096")
	cache.db:eval("PRAGMA auto_vacuum = incremental")
	cache.db:eval("PRAGMA max_page_count = " .. math.ceil(cache.max_db_size_bytes / 4096))

	cache.db:eval([[
		    CREATE TABLE IF NOT EXISTS meta (
			schema_version TEXT PRIMARY KEY
	  	    );
		]])

	local res = cache.db:eval("SELECT schema_version FROM meta;")
	if type(res) ~= "table" or #res == 0 or res[1].schema_version ~= SCHEMA_VERSION then
		cache.db:eval("DELETE FROM meta")
		cache.db:eval("INSERT INTO meta (schema_version) VALUES ('" .. SCHEMA_VERSION .. "')")
		cache.db:eval("DROP TABLE IF EXISTS gosymbols")
		cache.db:eval("DROP TABLE IF EXISTS gosymbols_fts")
		cache.db:eval("DROP TABLE IF EXISTS gosymbol_cache")
		cache.db:eval("PRAGMA wal_checkpoint(TRUNCATE);")
		cache.db:eval("VACUUM;")
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
		    USING fts5(name, fuzzy_text, id, tokenize='porter trigram');
		]],
	}

	for _, sql in ipairs(tables) do
		if not cache.db:eval(sql) then
			if cache.notifications then
				vim.notify("[sqlite] failed to create table", vim.log.levels.ERROR)
			end
			return nil
		end
	end

	res = cache.db:eval("SELECT COUNT(*) as count FROM gosymbols")
	if type(res) ~= "table" or #res == 0 then
		if cache.notifications then
			vim.notify("[sqlite] error reading db row count", vim.log.levels.ERROR)
		end
		return nil
	end
	cache.total_rows_estimate = res[1].count

	if opts.debug then
		vim.notify("[sqlite] db row count: " .. cache.total_rows_estimate, vim.log.levels.INFO)
	end

	cache.db:eval("CREATE INDEX IF NOT EXISTS idx_last_modified ON gosymbols (last_modified DESC);")
	cache.db:eval("CREATE INDEX IF NOT EXISTS idx_hash ON gosymbols (hash DESC);")

	vim.schedule(function()
		cache.db:eval("PRAGMA wal_checkpoint(RESTART);")
		cache.db:eval("ANALYZE;")
	end)

	cache.load_by_fuzzy_text_stmt = sqlstmt:parse(
		cache.db.conn,
		[[
			SELECT gosymbols.data FROM gosymbols
			JOIN gosymbols_fts ON gosymbols.id = gosymbols_fts.id
			WHERE gosymbols_fts.fuzzy_text LIKE '%' || ? || '%'
			ORDER BY gosymbols.last_modified DESC
			LIMIT 100;
	]]
	)

	cache.load_by_name_stmt = sqlstmt:parse(
		cache.db.conn,
		[[
			SELECT gosymbols.data FROM gosymbols
			JOIN gosymbols_fts ON gosymbols.id = gosymbols_fts.id
			WHERE gosymbols_fts.name LIKE '%' || ? || '%'
			ORDER BY gosymbols.last_modified DESC
			LIMIT 100;
	]]
	)

	cache.insert_gosymbols_stmt = sqlstmt:parse(
		cache.db.conn,
		[[
		    INSERT OR REPLACE INTO gosymbols (data, hash, last_modified)
		    VALUES (?, ?, ?);
		]]
	)

	cache.last_insert_rowid_stmt = sqlstmt:parse(
		cache.db.conn,
		[[
		    SELECT last_insert_rowid();
		]]
	)

	cache.insert_gosymbols_fts_stmt = sqlstmt:parse(
		cache.db.conn,
		[[
		    INSERT OR REPLACE INTO gosymbols_fts (name, fuzzy_text, id)
		    VALUES (?, ?, ?);
		]]
	)

	cache.delete_gosymbols_stmt = sqlstmt:parse(
		cache.db.conn,
		[[
		    DELETE FROM gosymbols
		    WHERE id IN (
			    SELECT id FROM gosymbols ORDER BY last_modified ASC LIMIT ?
		    );
		]]
	)

	cache.delete_fts_stmt = sqlstmt:parse(
		cache.db.conn,
		[[
		    DELETE FROM gosymbols_fts
		    WHERE id IN (
			    SELECT id FROM gosymbols ORDER BY last_modified ASC LIMIT ?
		    );
		]]
	)

	return cache
end

---@param query_string string
---@param match_name boolean?
---@return table
function cache:load(query_string, match_name)
	local stmt = self.load_by_fuzzy_text_stmt
	if match_name then
		stmt = self.load_by_name_stmt
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
function cache:prune()
	local res = self.db:eval("SELECT COUNT(*) as count FROM gosymbols")
	if type(res) ~= "table" or #res == 0 then
		if self.notifications then
			vim.notify("[sqlite] error reading db row count while pruning", vim.log.levels.ERROR)
		end
		return
	end
	self.total_rows_estimate = res[1].count

	local to_delete = math.floor(self.total_rows_estimate * 0.2)
	to_delete = math.min(to_delete, 5000)

	if to_delete <= 0 then
		return
	end

	self.delete_gosymbols_stmt:bind({ to_delete })
	self.delete_fts_stmt:bind({ to_delete })

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

	self.total_rows_estimate = self.total_rows_estimate - to_delete

	self.db:eval("PRAGMA wal_checkpoint(PASSIVE);")
	self.db:eval("PRAGMA incremental_vacuum;")
end

---@param utils cmp_go_deep.utils
---@param symbol_information table
function cache:save(utils, symbol_information) --- assumes that gopls doesn't return more than 100 workspace symbols
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

		self.insert_gosymbols_fts_stmt:bind({ symbol.name, (symbol.fuzzy_text or "") .. symbol.name, id })
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

	self.total_rows_estimate = self.total_rows_estimate + #symbol_information

	if self.total_rows_estimate > 0.8 * self.MAX_ROWS_THRESHOLD then
		vim.schedule(function()
			self:prune()
		end)
	end
end

---@param symbol_information table
function cache:save_in_memory(symbol_information)
	cache.data = vim.tbl_extend("force", cache.data, symbol_information)
end

return cache
