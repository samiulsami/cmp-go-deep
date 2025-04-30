---@type sqlite_db
local sqlite = require("sqlite.db")

---@class cmp_go_deep.DB
---@field public load fun(self, project_path: string, query_string: string): table|nil
---@field public save fun(self, project_path: string, query_string: string, symbol_information: table): nil
---@field private under_size_limit fun(self): boolean
---@field private prune fun(self): nil
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

	local ok = DB.db:eval([[
		  CREATE TABLE IF NOT EXISTS gosymbol_cache (
		    project_path TEXT,
		    query_string TEXT,
		    json_data TEXT,
		    last_accessed_at INTEGER,
		    PRIMARY KEY (project_path, query_string)
		  )
	]])
	if not ok then
		vim.notify("[sqlite] failed to create table", vim.log.levels.WARN)
	end

	DB.db:eval("CREATE INDEX IF NOT EXISTS idx_project_path ON gosymbol_cache(project_path)")

	return DB
end

---@param project_path string
---@param query_string string
---@return table|nil
function DB:load(project_path, query_string)
	local res = self.db:eval(
		[[
			SELECT json_data FROM gosymbol_cache
			WHERE project_path = ?
			  AND query_string LIKE '%' || ? || '%' COLLATE NOCASE
			ORDER BY LENGTH(query_string) ASC
			LIMIT 1
		]],
		{ project_path, query_string }
	)

	if type(res) == "table" and #res > 0 then
		self.db:eval(
			[[
				UPDATE gosymbol_cache
				SET last_accessed_at = ?
				WHERE project_path = ?
				AND query_string = ?
			]],
			{ os.time(), project_path, res[1].query_string }
		)
		return vim.json.decode(res[1].json_data)
	end
	return nil
end

function DB:prune()
	local page_count = self.db:eval("PRAGMA page_count")[1]["page_count"]
	local max_pages = self.db:eval("PRAGMA max_page_count")[1]["max_page_count"]

	if page_count < max_pages then
		return
	end

	local total_rows = self.db:eval("SELECT COUNT(*) as count FROM gosymbol_cache")[1]["count"]
	local to_delete = math.floor(total_rows * 0.25)

	if to_delete > 0 then
		local ok = self.db:eval(
			[[
				DELETE FROM gosymbol_cache
				WHERE rowid IN (
					SELECT rowid FROM gosymbol_cache
					ORDER BY last_accessed_at ASC
					LIMIT ?
				)
			]],
			{ to_delete }
		)

		if not ok then
			vim.notify("[sqlite] failed to prune rows", vim.log.levels.WARN)
		else
			self.db:eval("PRAGMA wal_checkpoint(TRUNCATE)")
			self.db:eval("PRAGMA incremental_vacuum")
		end
	end
end

---@param project_path string
---@param query_string string
---@param symbol_information table
--TODO: rtfm and optimize memory usage
--TODO: add configurations for manipulating fuzzy search behavior
--TODO: implement custom fuzzy search logic
function DB:save(project_path, query_string, symbol_information)
	self:prune()
	if
		not self.db:eval(
			[[
			INSERT OR REPLACE INTO gosymbol_cache (project_path, query_string, json_data, last_accessed_at) VALUES (?, ?, ?, ?) 
			]],
			{ project_path, query_string, vim.json.encode(symbol_information), os.time() }
		)
	then
		vim.notify("[sqlite] failed to save to db", vim.log.levels.WARN)
	end
end

return DB
