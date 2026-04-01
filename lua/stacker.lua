local M = {}

local default_opts = {
	max_buffers = 10,
	separator = "  ",
	sort_buffers = true,
	show_tabline = true,
	storage_path = vim.fn.stdpath("data") .. "/stacker.json",
	load_cursor_position = false,
	use_storage = true,
}

-- buffer management
M.loaded = false
M.buffer_history = {}
M.current_buffer = nil
M.opts = {}
M.argv_session = false
M.loading_storage = false

local add_bufnr_to_history
local argv_startup_handled = false

local function get_buffer_kind(bufnr)
	if bufnr == nil or not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end
	local buftype = vim.api.nvim_buf_get_option(bufnr, "buftype")
	if buftype == "" then
		return "file"
	end
	if buftype == "terminal" then
		return "terminal"
	end
	return nil
end

local function is_trackable_buffer(bufnr)
	return get_buffer_kind(bufnr) ~= nil
end

local function get_buffer_name(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == nil then
		return ""
	end
	return name
end

local function normalize_path(path)
	if path == nil or path == "" then
		return ""
	end
	return vim.fn.fnamemodify(path, ":p")
end

local function normalize_project_key(path)
	local normalized = normalize_path(path)
	if normalized == "" then
		return ""
	end
	if normalized ~= "/" then
		normalized = normalized:gsub("/+$", "")
	end
	return normalized
end

local function get_project_key_variants()
	local cwd = vim.fn.getcwd()
	local normalized = normalize_project_key(cwd)
	if normalized == "" or normalized == cwd then
		return { cwd }
	end
	return { normalized, cwd }
end

local function get_project_key()
	return normalize_project_key(vim.fn.getcwd())
end

local function is_path_in_current_project(path, project_key)
	local normalized = normalize_path(path)
	if normalized == "" or project_key == "" then
		return false
	end
	if project_key == "/" then
		return normalized:sub(1, 1) == "/"
	end
	if normalized == project_key then
		return true
	end
	return normalized:sub(1, #project_key + 1) == project_key .. "/"
end

local function ensure_parent_dir(path)
	local dir = vim.fn.fnamemodify(path, ":h")
	if dir ~= nil and dir ~= "" then
		pcall(vim.fn.mkdir, dir, "p")
	end
end

local function cleanup_temp_file(path, file)
	if file ~= nil then
		pcall(function()
			file:close()
		end)
	end
	if path ~= nil and path ~= "" then
		pcall(os.remove, path)
	end
end

local function write_file_atomic(path, data)
	local temp_path = path .. "." .. tostring(vim.loop.hrtime()) .. ".tmp"
	local file, open_err = io.open(temp_path, "w")
	if file == nil then
		return false, open_err
	end

	local ok, write_err = file:write(data)
	if ok == nil then
		cleanup_temp_file(temp_path, file)
		return false, write_err
	end

	local close_ok, close_err = file:close()
	if not close_ok then
		cleanup_temp_file(temp_path)
		return false, close_err
	end

	local rename_ok, rename_err = os.rename(temp_path, path)
	if not rename_ok then
		cleanup_temp_file(temp_path)
		return false, rename_err
	end

	return true
end

local function clamp(value, min_value, max_value)
	if value == nil then
		return min_value
	end
	if value < min_value then
		return min_value
	end
	if value > max_value then
		return max_value
	end
	return value
end

local function get_buffer_context(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end

	local row, col = 1, 0
	if bufnr == vim.api.nvim_get_current_buf() then
		local cursor = vim.api.nvim_win_get_cursor(0)
		row = cursor[1] or 1
		col = cursor[2] or 0
	else
		local ok, mark = pcall(vim.api.nvim_buf_get_mark, bufnr, '"')
		if ok and type(mark) == "table" and mark[1] ~= nil and mark[1] > 0 then
			row = mark[1]
			col = mark[2] or 0
		end
	end

	local line_count = vim.api.nvim_buf_line_count(bufnr)
	if line_count < 1 then
		line_count = 1
	end
	row = clamp(row, 1, line_count)

	local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
	col = clamp(col, 0, #line)

	return {
		row = row,
		col = col,
	}
end

local function normalize_session_item(item)
	if type(item) ~= "table" then
		return nil
	end

	local value = item.value
	if type(value) ~= "string" or value == "" then
		value = item.name
	end
	if type(value) ~= "string" or value == "" then
		return nil
	end

	local context = item.context
	if type(context) ~= "table" then
		local line = tonumber(item.line) or 1
		context = {
			row = line,
			col = 0,
		}
	end

	return {
		value = normalize_path(value),
		context = {
			row = tonumber(context.row or context.line) or 1,
			col = tonumber(context.col) or 0,
		},
	}
end

local function get_storage_session(contents)
	if type(contents) ~= "table" then
		return {}
	end

	local variants = get_project_key_variants()
	for i = 1, #variants do
		local session = contents[variants[i]]
		if type(session) == "table" then
			return session
		end
	end

	return {}
end

local function restore_cursor_position(bufnr, context)
	if not M.opts.load_cursor_position or type(context) ~= "table" then
		return
	end
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local row = tonumber(context.row) or 1
	local col = tonumber(context.col) or 0
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	if line_count < 1 then
		line_count = 1
	end
	row = clamp(row, 1, line_count)
	local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
	col = clamp(col, 0, #line)

	vim.api.nvim_win_set_cursor(0, { row, col })
end

local function make_buffer_current(bufnr)
	if vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_set_current_buf(bufnr)
	end
end

local function get_buffer_label(buffer)
	if buffer.kind == "terminal" then
		local pid, command = buffer.name:match("//(%d+):(.*)$")
		local label = vim.trim(command or "")
		if label ~= "" then
			label = vim.fn.fnamemodify(label, ":t")
		else
			label = "Terminal"
		end
		if pid ~= nil and pid ~= "" then
			return "/Terminal/" .. label .. " (" .. pid .. ")"
		end
		return "/Terminal/" .. label .. " (" .. buffer.index .. ")"
	end

	return buffer.name
end

local function list_trackable_buffers()
	local all_bufs = vim.api.nvim_list_bufs()
	local tracked_bufs = {}
	for i = 1, #all_bufs do
		if vim.api.nvim_buf_is_valid(all_bufs[i]) and vim.fn.buflisted(all_bufs[i]) == 1 then
			local kind = get_buffer_kind(all_bufs[i])
			local name = get_buffer_name(all_bufs[i])
			if kind == "file" then
				if #name > 0 and name:sub(1, 1) == "/" then
					table.insert(tracked_bufs, all_bufs[i])
				elseif #name == 0 then
					table.insert(tracked_bufs, all_bufs[i])
				end
			elseif kind == "terminal" then
				table.insert(tracked_bufs, all_bufs[i])
			end
		end
	end
	return tracked_bufs
end

local function ensure_terminal_fallback(buffer)
	if buffer == nil or buffer.kind ~= "terminal" then
		return
	end
	local tracked_bufs = list_trackable_buffers()
	if #tracked_bufs ~= 1 or tracked_bufs[1] ~= buffer.index then
		return
	end
	local bufnr = vim.api.nvim_create_buf(true, false)
	if bufnr == 0 then
		return
	end
	add_bufnr_to_history(bufnr)
end

local function get_buffer_history_index(bufnr)
	for i = 1, #M.buffer_history do
		if bufnr == M.buffer_history[i].index then
			return i
		end
	end
	return nil
end

local function upsert_buffer_history(buffer)
	if buffer == nil then
		return
	end

	local index = get_buffer_history_index(buffer.index)
	if index ~= nil then
		if M.opts.sort_buffers then
			table.remove(M.buffer_history, index)
			table.insert(M.buffer_history, buffer)
		else
			M.buffer_history[index] = buffer
		end
		return
	end

	table.insert(M.buffer_history, buffer)
	if #M.buffer_history > M.opts.max_buffers then
		table.remove(M.buffer_history, 1)
	end
end

add_bufnr_to_history = function(bufnr)
	if not is_trackable_buffer(bufnr) then
		return
	end
	M.current_buffer = bufnr
	upsert_buffer_history({
		index = bufnr,
		kind = get_buffer_kind(bufnr),
		name = get_buffer_name(bufnr),
	})
end

M.filter = function()
	local tracked_bufs = list_trackable_buffers()

	local filtered = {}
	for i = 1, #M.buffer_history do
		local buffer = M.buffer_history[i]
		if vim.tbl_contains(tracked_bufs, buffer.index) then
			table.insert(filtered, buffer)
		end
	end
	M.buffer_history = filtered
end

M.get_buffer = function()
	local index = vim.api.nvim_get_current_buf()
	local kind = get_buffer_kind(index)
	if kind == nil then
		return nil
	end
	M.current_buffer = index
	return {
		index = index,
		kind = kind,
		name = get_buffer_name(index),
	}
end

M.on_enter = function()
	M.filter()
	local buffer = M.get_buffer()
	if buffer == nil then
		return
	end
	ensure_terminal_fallback(buffer)
	upsert_buffer_history(buffer)

	M.save_storage({ from_enter = true })

	vim.cmd("redrawtabline")
end

M.clear_history = function()
	for _ = 1, #M.buffer_history do
		vim.api.nvim_buf_delete(M.buffer_history[1].index, {})
	end

	vim.cmd("redrawtabline")
end

M.on_delete = function(buffer)
	local bufnr = buffer.buf
	local index = get_buffer_history_index(bufnr)
	if index ~= nil then
		table.remove(M.buffer_history, index)
	end
	if bufnr == M.current_buffer then
		M.current_buffer = nil
	end
end

M.navigate = function(index)
	M.filter()
	local buffer_history = M.buffer_history
	if M.opts.sort_buffers then
		if index > #buffer_history + 1 then
			print("index out of range")
			return
		end
		local buffer = buffer_history[#buffer_history - index]
		if not buffer then
			print("buffer not found")
			return
		end
		vim.cmd("buffer " .. buffer.index)
		M.save_storage()
		return
	end
	if index > #buffer_history then
		print("index out of range")
		return
	end
	local buffer = buffer_history[index]
	if not buffer then
		print("buffer not found")
		return
	end
	vim.cmd("buffer " .. buffer.index)

	M.save_storage()
end

M.load_storage_contents = function()
	local file = io.open(M.opts.storage_path, "r")
	if file == nil then
		return {}
	end
	local ok, contents = pcall(function()
		local data = file:read("*all")
		if data == nil or data == "" then
			return {}
		end
		local decoded = vim.json.decode(data)
		if type(decoded) ~= "table" then
			return {}
		end
		return decoded
	end)
	file:close()
	if not ok or type(contents) ~= "table" then
		return {}
	end
	return contents
end

local function load_file_buffer(path)
	local normalized = normalize_path(path)
	if normalized == "" then
		return nil
	end
	if vim.fn.filereadable(normalized) ~= 1 then
		return nil
	end
	local ok, bufnr = pcall(vim.fn.bufadd, normalized)
	if not ok then
		return nil
	end
	if not pcall(vim.fn.bufload, bufnr) then
		return nil
	end
	pcall(vim.api.nvim_buf_set_option, bufnr, "buflisted", true)
	return bufnr
end

local function load_startup_files_from_argv()
	if argv_startup_handled then
		return false
	end
	local argv = vim.fn.argv()
	if #argv == 0 then
		return false
	end
	local had_argv = true
	local loaded_any = false
	local loaded_bufs = {}
	for i = 1, #argv do
		local arg = argv[i]
		if arg ~= nil and arg ~= "" then
			local bufnr = load_file_buffer(arg)
			if bufnr ~= nil then
				table.insert(loaded_bufs, bufnr)
				loaded_any = true
			end
		end
	end
	if loaded_any then
		M.filter()
		for i = 1, #loaded_bufs do
			add_bufnr_to_history(loaded_bufs[i])
		end
		-- Keep the currently visible startup buffer as most-recent.
		add_bufnr_to_history(vim.api.nvim_get_current_buf())
		vim.cmd("redrawtabline")
	end
	argv_startup_handled = true
	M.argv_session = true
	return had_argv
end

M.load_storage = function(options)
	if M.loading_storage then
		return
	end
	local from_dir_changed = type(options) == "table" and options.from_dir_changed == true
	M.loading_storage = true
	local function finish_loading()
		M.loading_storage = false
	end
	-- If nvim was launched with explicit file arguments, honor that set first
	-- and avoid replacing the startup layout with storage restores.
	if not M.loaded and load_startup_files_from_argv() then
		M.argv_session = true
		M.loaded = true
		finish_loading()
		return
	end

	if not M.opts.use_storage then
		M.loaded = true
		finish_loading()
		return
	end

	local contents = M.load_storage_contents()
	local items = get_storage_session(contents)
	if items == nil or #items == 0 then
		M.loaded = true
		if from_dir_changed then
			M.buffer_history = {}
			M.current_buffer = nil
			finish_loading()
			vim.cmd("redrawtabline")
			return
		end
		finish_loading()
		M.on_enter()
		return
	end
	M.buffer_history = {}
	M.current_buffer = nil
	local last_loaded = nil
	local last_context = nil
	for i = 1, #items do
		local item = normalize_session_item(items[i])
		if item ~= nil then
			local bufnr = load_file_buffer(item.value)
			if bufnr ~= nil then
				add_bufnr_to_history(bufnr)
				last_loaded = bufnr
				last_context = item.context
			end
		end
	end
	if last_loaded ~= nil then
		make_buffer_current(last_loaded)
		restore_cursor_position(last_loaded, last_context)
	end

	M.loaded = true
	finish_loading()
	vim.cmd("redrawtabline")
end

local function build_session_item(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil
	end

	local path = normalize_path(get_buffer_name(bufnr))
	if path == "" then
		return nil
	end

	local context = get_buffer_context(bufnr)
	if context == nil then
		context = {
			row = 1,
			col = 0,
		}
	end

	return {
		value = path,
		context = context,
	}
end

M.save_storage = function(options)
	local from_enter = type(options) == "table" and options.from_enter == true
	M.filter()
	if not M.opts.use_storage then
		return
	end
	if M.loading_storage then
		return
	end
	if from_enter and not M.loaded then
		return
	end
	local contents = M.load_storage_contents()
	local session = {}
	local project_key = get_project_key()
	for i = 1, #M.buffer_history do
		local item = M.buffer_history[i]
		if item.kind == "file" then
			local session_item = build_session_item(item.index)
			if session_item ~= nil and is_path_in_current_project(session_item.value, project_key) then
				table.insert(session, session_item)
			end
		end
	end
	contents[project_key] = session
	local ok, encoded = pcall(vim.json.encode, contents)
	if not ok then
		return
	end
	ensure_parent_dir(M.opts.storage_path)
	write_file_atomic(M.opts.storage_path, encoded)
end

M.on_buffer_write = function()
	local buffer = M.get_buffer()
	if buffer == nil then
		return
	end
	-- update buffer name if it has changed
	local index = get_buffer_history_index(buffer.index)
	if index == nil or buffer.name ~= M.buffer_history[index].name then
		M.on_enter()
		vim.cmd("redrawtabline")
	end
end

M.setup = function(options)
	M.opts = vim.tbl_extend("force", default_opts, options or {})
	M.argv_session = #vim.fn.argv() > 0

	-- autocmds

	-- create autocmd group
	vim.api.nvim_create_augroup("stacker", {
		-- clear the group before adding autocommands
		clear = true,
	})

	-- on open
	vim.api.nvim_create_autocmd("BufEnter", {
		group = "stacker",
		pattern = "*",
		callback = M.on_enter,
	})

	-- terminal buffers do not always trigger the same enter flow as file buffers
	vim.api.nvim_create_autocmd({ "TermOpen", "TermEnter" }, {
		group = "stacker",
		pattern = "*",
		callback = M.on_enter,
	})

	-- on close
	vim.api.nvim_create_autocmd("BufDelete", {
		group = "stacker",
		pattern = "*",
		callback = M.on_delete,
	})

	-- on vim leave
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = "stacker",
		pattern = "*",
		callback = M.save_storage,
	})

	-- on buffer write
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = "stacker",
		pattern = "*",
		callback = M.on_buffer_write,
	})

	-- on buffer leave
	vim.api.nvim_create_autocmd("BufLeave", {
		group = "stacker",
		pattern = "*",
		callback = M.save_storage,
	})

	-- on cursor hold
	vim.api.nvim_create_autocmd("CursorHold", {
		group = "stacker",
		pattern = "*",
		callback = M.save_storage,
	})

	-- on directory change
	vim.api.nvim_create_autocmd("DirChanged", {
		group = "stacker",
		pattern = "*",
		callback = function()
			M.load_storage({ from_dir_changed = true })
		end,
	})

	if M.opts.show_tabline then
		vim.opt.showtabline = 2
		vim.o.tabline = "%!v:lua.require'stacker'.status()"
	end

	M.on_enter()

	vim.defer_fn(M.load_storage, 0)
end

M.list_buffers = function()
	M.filter()
	local buffer_history = M.buffer_history
	local buffer_list = {}
	-- figure out which buffers are unnamed
	local no_name_indices = {}
	for i = 1, #buffer_history do
		local buffer = buffer_history[i]
		if buffer.name == "" then
			table.insert(no_name_indices, buffer.index)
		end
	end
	for i = 1, #buffer_history do
		local buffer = buffer_history[i]
		local name = get_buffer_label(buffer)
		if name ~= "" then
			table.insert(buffer_list, name)
		else
			local no_name_count = 1
			for j = 1, #no_name_indices do
				if buffer.index > no_name_indices[j] then
					no_name_count = no_name_count + 1
				end
			end
			table.insert(buffer_list, "/Unnamed (" .. no_name_count .. ")")
		end
	end
	return buffer_list
end

M.get_filenames = function()
	local paths = M.list_buffers()

	local split = function(s, delimiter)
		local result = {}
		for match in (s .. delimiter):gmatch("(.-)" .. delimiter) do
			table.insert(result, match)
		end
		return result
	end

	local split_paths = {}
	for i = 1, #paths do
		local path = paths[i]
		local split_path = split(path, "/")
		table.insert(split_paths, split_path)
	end

	-- group paths by common suffixes, and only show the minimal unique suffix
	local groups = {}

	local function add_to_groups(_groups, path)
		if #path == 1 then
			_groups[path[1]] = true
			return _groups
		end
		if _groups[path[#path]] == nil then
			_groups[path[#path]] = {}
		end
		_groups[path[#path]] = add_to_groups(_groups[path[#path]], { unpack(path, 1, #path - 1) })
		return _groups
	end

	for i = 1, #split_paths do
		local split_path = split_paths[i]
		groups = add_to_groups(groups, split_path)
	end

	local filenames = {}

	for i = 1, #split_paths do
		local split_path = split_paths[i]
		local filename = ""
		local group = groups

		for j = 1, #split_path do
			local part = split_path[#split_path - j + 1]
			group = group[part]

			if group == true then
				break
			end

			-- count how many items are in the group
			local count = 0

			for _ in pairs(group) do
				count = count + 1
			end

			if count > 1 then
				filename = part .. "/" .. filename
			else
				filename = part .. "/" .. filename
				break
			end
		end

		-- remove trailing slash
		filename = filename:sub(1, -2)
		filenames[i] = filename
	end

	return filenames
end

M.status = function()
	local filenames = M.get_filenames()

	if #filenames == 0 then
		return ""
	end

	if not M.opts.sort_buffers then
		local statusline = ""
		for i = 1, #filenames do
			if i > 1 then
				statusline = statusline .. "%#StackerSeparator#" .. M.opts.separator
			end
			statusline = statusline .. "%#StackerNumber#" .. i .. " "
			if M.buffer_history[i] ~= nil and M.buffer_history[i].index == M.current_buffer then
				statusline = statusline .. "%#StackerActive#"
			else
				statusline = statusline .. "%#StackerInactive#"
			end
			statusline = statusline .. filenames[i]
		end
		return statusline
	end

	local statusline = "%#StackerActive#" .. filenames[#filenames]

	for i = 1, #filenames do
		local index = #filenames - i
		if index < 1 then
			break
		end
		statusline = statusline
			.. "%#StackerSeparator#"
			.. M.opts.separator
			.. "%#StackerNumber#"
			.. i
			.. " %#StackerInactive#"
			.. filenames[index]
	end

	return statusline
end

return M
