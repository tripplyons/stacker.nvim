local M = {}

local default_opts = {
	max_buffers = 10,
	separator = "  ",
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

local add_bufnr_to_history

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

local function upsert_buffer_history(buffer)
	if buffer == nil then
		return
	end
	local index = -1
	for i = 1, #M.buffer_history do
		if buffer.index == M.buffer_history[i].index then
			index = i
			break
		end
	end
	if index ~= -1 then
		table.remove(M.buffer_history, index)
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

	M.save_storage()

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
	local index = -1

	for i = 1, #M.buffer_history do
		if bufnr == M.buffer_history[i].index then
			index = i
			break
		end
	end

	if index ~= -1 then
		table.remove(M.buffer_history, index)
	end
end

M.navigate = function(index)
	M.filter()
	if index > #M.buffer_history + 1 then
		print("index out of range")
		return
	end
	local buffer = M.buffer_history[#M.buffer_history - index]
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
	local contents = file:read("*all")
	if contents == "" then
		return {}
	end
	file:close()
	return vim.json.decode(contents)
end

local function normalize_path(path)
	if path == nil or path == "" then
		return ""
	end
	return vim.fn.fnamemodify(path, ":p")
end

local function load_file_buffer(path)
	local normalized = normalize_path(path)
	if normalized == "" then
		return nil
	end
	local bufnr = vim.fn.bufadd(normalized)
	vim.fn.bufload(bufnr)
	return bufnr
end

local function load_startup_files_from_argv()
	local argv = vim.fn.argv()
	if #argv == 0 then
		return false
	end
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
	return loaded_any
end

M.load_storage = function()
	-- If nvim was launched with explicit file arguments, honor that set first
	-- and avoid replacing the startup layout with storage restores.
	if load_startup_files_from_argv() then
		M.argv_session = true
		M.loaded = true
		return
	end

	if not M.opts.use_storage then
		M.loaded = true
		return
	end

	local contents = M.load_storage_contents()
	local items = contents[vim.fn.getcwd()]
	if items == nil or #items == 0 then
		M.loaded = true
		M.on_enter()
		return
	end
	M.buffer_history = {}
	for i = 1, #items do
		local item = items[i]
		if item["name"] ~= nil and item["name"] ~= "" then
			local bufnr = load_file_buffer(item["name"])
			if bufnr ~= nil then
				add_bufnr_to_history(bufnr)
				if i == #items then
					vim.api.nvim_set_current_buf(bufnr)
					add_bufnr_to_history(bufnr)
				end
			end
		end
		if M.opts.load_cursor_position then
			local line = item["line"]
			local max_line = tonumber(vim.fn.system({ "wc", "-l", vim.fn.expand("%") }):match("%d+"))
			if line > max_line then
				line = max_line
			end
			vim.cmd("normal! " .. line .. "gg0")
		end
	end

	M.loaded = true
	vim.cmd("redrawtabline")
end

M.save_storage = function()
	M.filter()
	if M.argv_session then
		return
	end
	if not M.opts.use_storage then
		return
	end
	if not M.loaded then
		return
	end
	local contents = M.load_storage_contents()
	local session = {}
	for i = 1, #M.buffer_history do
		local item = M.buffer_history[i]
		if item.kind == "file" and item.name ~= "" then
			local row = {}
			row["name"] = item.name
			row["line"] = vim.api.nvim__buf_stats(item.index).current_lnum or 0
			table.insert(session, row)
		end
	end
	contents[vim.fn.getcwd()] = session
	local file = io.open(M.opts.storage_path, "w+")
	if file == nil then
		return
	end
	local result = file:write(vim.json.encode(contents))
	if result == nil then
		return
	end
	file:close()
end

M.on_buffer_write = function()
	local buffer = M.get_buffer()
	if buffer == nil then
		return
	end
	-- update buffer name if it has changed
	if #M.buffer_history == 0 or buffer.name ~= M.buffer_history[#M.buffer_history].name then
		M.on_enter()
		vim.cmd("redrawtabline")
	end
end

M.setup = function(options)
	M.opts = vim.tbl_extend("force", default_opts, options or {})

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
		callback = M.load_storage,
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
	local buffer_list = {}
	-- figure out which buffers are unnamed
	local no_name_indices = {}
	for i = 1, #M.buffer_history do
		local buffer = M.buffer_history[i]
		if buffer.name == "" then
			table.insert(no_name_indices, buffer.index)
		end
	end
	for i = 1, #M.buffer_history do
		local buffer = M.buffer_history[i]
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
