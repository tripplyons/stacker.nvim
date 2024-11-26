local M = {}

local default_opts = {
  max_buffers = 10,
  separator = '  ',
  show_tabline = true,
  storage_path = vim.fn.stdpath('data') .. '/stacker.json',
  load_cursor_position = false,
  use_storage = false,
}

-- buffer management
M.buffer_history = {}
M.opts = {}

M.filter = function()
  local all_bufs = vim.api.nvim_list_bufs()
  local open_bufs = {}
  for i = 1, #all_bufs do
    if vim.api.nvim_buf_is_loaded(all_bufs[i]) then
      local name = vim.api.nvim_buf_get_name(all_bufs[i])
      -- only include files and new buffers
      if #name > 0 and name:sub(1, 1) == '/' then
        table.insert(open_bufs, all_bufs[i])
      elseif #name == 0 then
        table.insert(open_bufs, all_bufs[i])
      end
    end
  end

  local filtered = {}
  for i = 1, #M.buffer_history do
    local buffer = M.buffer_history[i]
    if vim.tbl_contains(open_bufs, buffer.index) then
      table.insert(filtered, buffer)
    end
  end
  M.buffer_history = filtered
end

M.get_buffer = function()
  local buffer_type = vim.api.nvim_buf_get_option(0, 'buftype')
  if buffer_type ~= '' then
    return nil
  end
  local index = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(index)
  if name == nil then
    name = ''
  end
  return {
    index = index,
    name = name,
  }
end

M.on_enter = function()
  local buffer = M.get_buffer()
  if buffer == nil then
    return
  end
  -- find if any buffers have a matching name
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

  M.save()
end

M.clear_history = function()
  -- M.buffer_history = {}
  while #M.buffer_history > 0 do
    vim.cmd('bdelete ' .. M.buffer_history[1].index)
    table.remove(M.buffer_history, 1)
  end
  M.on_enter()
  vim.cmd('redrawtabline')
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

  M.save()
end

M.navigate = function(index)
  if index > #M.buffer_history + 1 then
    return
  end
  local buffer = M.buffer_history[#M.buffer_history - index]
  if not buffer then
    return
  end
  vim.cmd('buffer ' .. buffer.index)

  M.save()
end

M.load_all = function()
  local file = io.open(M.opts.storage_path, 'r')
  if file == nil then
    return {}
  end
  local contents = file:read('*all')
  if contents == '' then
    return {}
  end
  file:close()
  return vim.fn.json_decode(contents)
end

M.load = function()
  if not M.opts.use_storage then
    return
  end

  local current_buffer = M.get_buffer()

  local contents = M.load_all()
  local items = contents[vim.fn.getcwd()]
  if items == nil then
    return
  end
  for i = 1, #items do
    local item = items[i]
    vim.cmd('edit ' .. item["name"])
    if M.opts.load_cursor_position then
      local line = item["line"]
      local max_line = tonumber(vim.fn.system({ 'wc', '-l', vim.fn.expand('%') }):match('%d+'))
      if line > max_line then
        line = max_line
      end
      vim.api.nvim_win_set_cursor(0, {line, 0})
    end
  end

  if current_buffer then
    vim.cmd('buffer ' .. current_buffer.index)
  end
end

M.save = function()
  M.filter()
  if not M.opts.use_storage then
    return
  end
  local contents = M.load_all()
  local session = {}
  for i = 1, #M.buffer_history do
    local item = M.buffer_history[i]
    if item.name ~= "" then
      local row = {}
      row["name"] = item.name
      row["line"] = vim.api.nvim__buf_stats(item.index).current_lnum or 0
      table.insert(session, row)
    end
  end
  contents[vim.fn.getcwd()] = session
  local file = io.open(M.opts.storage_path, 'w+')
  if file == nil then
    return
  end
  local result = file:write(vim.fn.json_encode(contents))
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
    vim.cmd('redrawtabline')
  end
end

M.setup = function(options)
  M.opts = vim.tbl_extend('force', default_opts, options or {})

  -- autocmds

  -- create autocmd group
  vim.api.nvim_create_augroup('stacker', {
    -- clear the group before adding autocommands
    clear = true,
  })

  -- on open
  vim.api.nvim_create_autocmd('BufEnter', {
    group = 'stacker',
    pattern = '*',
    callback = M.on_enter,
  })

  -- on close
  vim.api.nvim_create_autocmd('BufDelete', {
    group = 'stacker',
    pattern = '*',
    callback = M.on_delete,
  })

  -- on vim leave
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = 'stacker',
    pattern = '*',
    callback = M.save,
  })

  -- on buffer write
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = 'stacker',
    pattern = '*',
    callback = M.on_buffer_write
  })

  -- on buffer leave
  vim.api.nvim_create_autocmd('BufLeave', {
    group = 'stacker',
    pattern = '*',
    callback = M.save
  })

  -- on cursor hold
  vim.api.nvim_create_autocmd('CursorHold', {
    group = 'stacker',
    pattern = '*',
    callback = M.save
  })

  if M.opts.show_tabline then
    vim.opt.showtabline = 2
    vim.o.tabline = '%!v:lua.require\'stacker\'.status()'
  end

  M.load()
end

M.list_buffers = function()
  local buffer_list = {}
  -- figure out which buffers are unnamed
  local no_name_indices = {}
  for i = 1, #M.buffer_history do
    local buffer = M.buffer_history[i]
    if buffer.name == '' then
      table.insert(no_name_indices, buffer.index)
    end
  end
  for i = 1, #M.buffer_history do
    local buffer = M.buffer_history[i]
    local name = buffer.name
    if name ~= '' then
      table.insert(buffer_list, name)
    else
      local no_name_count = 1
      for j = 1, #no_name_indices do
        if buffer.index > no_name_indices[j] then
          no_name_count = no_name_count + 1
        end
      end
      table.insert(buffer_list, '/Unnamed (' .. no_name_count .. ')')
    end
  end
  return buffer_list
end

M.get_filenames = function()
  local paths = M.list_buffers()

  local split = function (s, delimiter)
      local result = {}
      for match in (s..delimiter):gmatch("(.-)"..delimiter) do
          table.insert(result, match)
      end
      return result
  end

  local split_paths = {}
  for i = 1, #paths do
    local path = paths[i]
    local split_path = split(path, '/')
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
    _groups[path[#path]] = add_to_groups(_groups[path[#path]], {unpack(path, 1, #path - 1)})
    return _groups
  end

  for i = 1, #split_paths do
    local split_path = split_paths[i]
    groups = add_to_groups(groups, split_path)
  end

  local filenames = {}

  for i = 1, #split_paths do
    local split_path = split_paths[i]
    local filename = ''
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
        filename = part .. '/' .. filename
      else
        filename = part .. '/' .. filename
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
    return ''
  end

  local statusline = '%#StackerActive#' .. filenames[#filenames]

  for i = 1, #filenames do
    local index = #filenames - i
    if index < 1 then
      break
    end
    statusline = statusline .. '%#StackerSeparator#' .. M.opts.separator .. '%#StackerNumber#' .. i .. ' %#StackerInactive#' .. filenames[index]
  end

  return statusline
end

return M
