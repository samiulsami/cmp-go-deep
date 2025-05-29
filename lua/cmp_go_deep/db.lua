local sqlstmt = require("sqlite.stmt")
---@type sqlite_db
local sqlite = require("sqlite.db")

---@class cmp_go_deep.DB
---@field public setup fun(opts: cmp_go_deep.Options): cmp_go_deep.DB?
---@field public load fun(self, query_string: string): table
---@field public save fun(self, utils: cmp_go_deep.utils, symbol_information: table): nil
---@field public modified boolean
---@field private db sqlite_db
---@field private db_path string
---@field private max_db_size_bytes number
---@field private total_rows number
---@field private notifications boolean
local DB = {}
local SCHEMA_VERSION = "0.0.4"
local MAGIC = 100000

---@param opts cmp_go_deep.Options
---@return cmp_go_deep.DB?
function DB.setup(opts)
	DB.notifications = opts.notifications
	DB.db_path = opts.db_path
	DB.max_db_size_bytes = opts.db_size_limit_bytes
	DB.db = sqlite:open(opts.db_path)

	---TODO: rtfm and fine-tune these
	local result = DB.db:eval("PRAGMA journal_mode = WAL")
	if type(result) == "table" and result[1] and result[1].journal_mode ~= "wal" then
		if DB.notifications then
			vim.notify("Failed to set journal_mode to WAL", vim.log.levels.WARN)
		end
	end
	DB.db:eval("PRAGMA synchronous = NORMAL")
	DB.db:eval("PRAGMA temp_store = MEMORY")
	DB.db:eval("PRAGMA cache_size = -10000")
	DB.db:eval("PRAGMA wal_autocheckpoint = 1000")
	DB.db:eval("PRAGMA page_size = 4096")
	DB.db:eval("PRAGMA auto_vacuum = FULL")
	DB.db:eval("PRAGMA max_page_count = " .. math.ceil(DB.max_db_size_bytes / 4096))

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
		DB.db:eval("PRAGMA wal_checkpoint(FULL)")
		DB.db:eval("VACUUM")
	end

	local tables = {
		[[
		    CREATE TABLE IF NOT EXISTS gosymbols (
		      id INTEGER PRIMARY KEY AUTOINCREMENT,
		      hash TEXT UNIQUE NOT NULL,
		      name TEXT NOT NULL,
		      data TEXT NOT NULL,
		      last_modified INTEGER NOT NULL
		    );
	        ]],

		[[
		    CREATE VIRTUAL TABLE IF NOT EXISTS gosymbols_fts
		    USING fts5(name, id UNINDEXED, tokenize='trigram', detail='none');
		]],
	}

	for _, sql in ipairs(tables) do
		local ok = DB.db:eval(sql)
		if not ok then
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
	DB.total_rows = res[1].count

	DB.db:eval("CREATE INDEX IF NOT EXISTS idx_last_modified ON gosymbols (last_modified DESC);")
	DB.db:eval("CREATE INDEX IF NOT EXISTS idx_hash ON gosymbols (hash DESC);")

	return DB
end

---@param query_string string
---@return table
function DB:load(query_string)
	local res = self.db:eval(
		[[
			SELECT gosymbols.data FROM gosymbols
			JOIN gosymbols_fts ON gosymbols.id = gosymbols_fts.id
			WHERE gosymbols_fts.name LIKE '%' || ? || '%'
			ORDER BY gosymbols.last_modified DESC
			LIMIT 200;
		]],
		{ query_string }
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

---@return nil
function DB:prune()
	if self.total_rows < MAGIC then
		return
	end

	local res = self.db:eval("SELECT COUNT(*) as count FROM gosymbols")
	if type(res) ~= "table" or #res == 0 then
		if self.notifications then
			vim.notify("[sqlite] error reading db row count while pruning", vim.log.levels.ERROR)
		end
		return
	end
	self.total_rows = res[1].count

	if self.total_rows < MAGIC then
		return
	end

	local to_delete = math.floor(self.total_rows * 0.25)
	if to_delete == 0 then
		return
	end

	local delete_lru = sqlstmt:parse(
		self.db.conn,
		[[
			WITH to_delete AS (
			  SELECT id FROM gosymbols ORDER BY last_modified ASC LIMIT ?
			),
			del1 AS (
			  DELETE FROM gosymbols_fts WHERE id IN (SELECT id FROM to_delete)
			)
			DELETE FROM gosymbols WHERE id IN (SELECT id FROM to_delete);
		]]
	)
	delete_lru:bind({ to_delete })

	if not self.db:eval("BEGIN TRANSACTION;") then
		if self.notifications then
			vim.notify("[sqlite] failed to begin transaction", vim.log.levels.ERROR)
		end
		return
	end

	---@param msg string
	local rollback = function(msg)
		self.db:eval("ROLLBACK;")
		if self.notifications then
			vim.notify("[sqlite] " .. msg, vim.log.levels.ERROR)
		end
	end

	if delete_lru:step() ~= sqlite.flags["done"] then
		return rollback("failed to perform deletion")
	end
	if not delete_lru:finalize() then
		return rollback("failed to finalize deletion")
	end

	if not self.db:eval("END TRANSACTION;") then
		return rollback("failed to end transaction")
	end

	if not self.db:eval("PRAGMA wal_checkpoint(TRUNCATE)") then
		if self.notifications then
			vim.notify("[sqlite] failed to checkpoint", vim.log.levels.ERROR)
		end
	end
	if not self.db:eval("VACUUM") then
		if self.notifications then
			vim.notify("[sqlite] failed to vacuum", vim.log.levels.ERROR)
		end
	end

	self.total_rows = self.total_rows - to_delete
end

---@param utils cmp_go_deep.utils
---@param symbol_information table
function DB:save(utils, symbol_information)
	local insert_gosymbols = sqlstmt:parse(
		self.db.conn,
		[[
		    INSERT OR REPLACE INTO gosymbols (name, data, hash, last_modified)
		    VALUES (?, ?, ?, ?);
		]]
	)
	local select_id = sqlstmt:parse(
		self.db.conn,
		[[
		    SELECT id FROM gosymbols WHERE hash = ?;
		]]
	)
	local insert_gosymbols_fts = sqlstmt:parse(
		self.db.conn,
		[[
		    INSERT OR REPLACE INTO gosymbols_fts (name, id )
		    VALUES (?, ?);
		]]
	)

	local last_modified = os.time()
	if not self.db:eval("BEGIN TRANSACTION;") then
		if self.notifications then
			vim.notify("[sqlite] failed to begin transaction", vim.log.levels.ERROR)
		end
		return
	end

	---@param msg string
	local rollback = function(msg)
		self.db:eval("ROLLBACK;")
		if self.notifications then
			vim.notify("[sqlite] " .. msg, vim.log.levels.ERROR)
		end
	end

	for _, symbol in ipairs(symbol_information) do
		local encoded = vim.json.encode(symbol)
		local hash = utils.deterministic_symbol_hash(symbol)

		insert_gosymbols:bind({ symbol.name, encoded, hash, last_modified })
		if insert_gosymbols:step() ~= sqlite.flags["done"] then
			return rollback("failed to insert gosymbols row")
		end
		if insert_gosymbols:reset() ~= sqlite.flags["ok"] then
			return rollback("failed to reset insert_gosymbols")
		end

		select_id:bind({ hash })
		if select_id:step() ~= sqlite.flags["row"] then
			return rollback("failed to select id")
		end
		local id = select_id:val(0)
		if select_id:reset() ~= sqlite.flags["ok"] then
			return rollback("failed to reset select_id")
		end

		insert_gosymbols_fts:bind({ symbol.name, id })
		if insert_gosymbols_fts:step() ~= sqlite.flags["done"] then
			return rollback("failed to insert gosymbols_fts row")
		end
		if insert_gosymbols_fts:reset() ~= sqlite.flags["ok"] then
			return rollback("failed to reset insert_gosymbols_fts")
		end
	end

	if not insert_gosymbols:finalize() then
		return rollback("failed to finalize insert_gosymbols")
	end
	if not select_id:finalize() then
		return rollback("failed to finalize select_id")
	end
	if not insert_gosymbols_fts:finalize() then
		return rollback("failed to finalize insert_gosymbols_fts")
	end

	if not self.db:eval("END TRANSACTION;") then
		return rollback("failed to end transaction")
	end

	self.total_rows = self.total_rows + #symbol_information
	self:prune()
end

return DB
