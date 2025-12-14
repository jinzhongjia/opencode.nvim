-- lua/opencode/headless/context.lua
-- Context handling for headless API (independent of vim buffer/window APIs)

local M = {}

---@class HeadlessFileInfo
---@field path string File full path
---@field name? string File name (optional, auto-inferred)
---@field extension? string Extension (optional, auto-inferred)

---@class HeadlessSelection
---@field file? string|HeadlessFileInfo File the selection belongs to (optional)
---@field content string Code content
---@field lines? string Line range "start, end"

---@class HeadlessDiagnostic
---@field message string Diagnostic message
---@field severity? number Severity level (vim.diagnostic.severity)
---@field lnum? number Line number (0-based)
---@field col? number Column number (0-based)

---@class HeadlessImage
---@field data string Base64 encoded image data
---@field format? string Image format: 'png'|'jpeg'|'gif'|'webp' (default: 'png')

---@class HeadlessContext
---@field current_file? string|HeadlessFileInfo Current file
---@field mentioned_files? string[] Mentioned file paths
---@field selections? HeadlessSelection[] Code selections
---@field diagnostics? HeadlessDiagnostic[] Diagnostics
---@field subagents? string[] Subagents
---@field images? HeadlessImage[] Base64 encoded images

-- MIME type mapping for common file extensions
local MIME_TYPES = {
  png = 'image/png',
  jpg = 'image/jpeg',
  jpeg = 'image/jpeg',
  gif = 'image/gif',
  webp = 'image/webp',
}

---Normalize a file input to HeadlessFileInfo
---@param file string|HeadlessFileInfo
---@return HeadlessFileInfo
function M.normalize_file(file)
  if type(file) == 'string' then
    local path = vim.fn.fnamemodify(file, ':p')
    return {
      path = path,
      name = vim.fn.fnamemodify(path, ':t'),
      extension = vim.fn.fnamemodify(path, ':e'),
    }
  end

  -- Already HeadlessFileInfo, create a new object with filled in fields
  -- Don't mutate the input object
  local path = file.path
  return {
    path = path,
    name = file.name or vim.fn.fnamemodify(path, ':t'),
    extension = file.extension or vim.fn.fnamemodify(path, ':e'),
  }
end

---Normalize a selection input
---@param selection HeadlessSelection
---@param default_file? HeadlessFileInfo Default file if selection.file is nil
---@return HeadlessSelection
function M.normalize_selection(selection, default_file)
  local result = {
    content = selection.content,
    lines = selection.lines,
  }

  if selection.file then
    result.file = M.normalize_file(selection.file)
  elseif default_file then
    result.file = default_file
  end

  return result
end

---Normalize contexts input (supports both single context and multiple contexts)
---@param opts { context?: HeadlessContext, contexts?: HeadlessContext[] }
---@return HeadlessContext[]
function M.normalize_contexts(opts)
  if opts.contexts and #opts.contexts > 0 then
    return opts.contexts
  elseif opts.context then
    return { opts.context }
  end
  return {}
end

---Get MIME type for a file
---@param file HeadlessFileInfo
---@return string
local function get_mime_type(file)
  local ext = (file.extension or ''):lower()
  return MIME_TYPES[ext] or 'text/plain'
end

---Indent code block content (normalize indentation)
---@param content string
---@return string
local function indent_code_block(content)
  if not content or content == '' then
    return content
  end

  local lines = vim.split(content, '\n', { plain = true })
  local min_indent = math.huge

  -- Find minimum indentation (ignoring empty lines)
  for _, line in ipairs(lines) do
    if line:match('%S') then
      local indent = line:match('^(%s*)')
      min_indent = math.min(min_indent, #indent)
    end
  end

  if min_indent == math.huge or min_indent == 0 then
    return content
  end

  -- Remove minimum indentation from all lines
  local result = {}
  for _, line in ipairs(lines) do
    if line:match('%S') then
      table.insert(result, line:sub(min_indent + 1))
    else
      table.insert(result, line)
    end
  end

  return table.concat(result, '\n')
end

---Get markdown language identifier from filename
---@param filename string
---@return string
local function get_markdown_lang(filename)
  local ext = vim.fn.fnamemodify(filename, ':e'):lower()
  local lang_map = {
    lua = 'lua',
    py = 'python',
    js = 'javascript',
    ts = 'typescript',
    tsx = 'tsx',
    jsx = 'jsx',
    rb = 'ruby',
    go = 'go',
    rs = 'rust',
    c = 'c',
    cpp = 'cpp',
    h = 'c',
    hpp = 'cpp',
    java = 'java',
    kt = 'kotlin',
    swift = 'swift',
    sh = 'bash',
    bash = 'bash',
    zsh = 'zsh',
    fish = 'fish',
    ps1 = 'powershell',
    sql = 'sql',
    json = 'json',
    yaml = 'yaml',
    yml = 'yaml',
    toml = 'toml',
    xml = 'xml',
    html = 'html',
    css = 'css',
    scss = 'scss',
    less = 'less',
    md = 'markdown',
    vim = 'vim',
    el = 'elisp',
    clj = 'clojure',
    ex = 'elixir',
    exs = 'elixir',
    erl = 'erlang',
    hs = 'haskell',
    ml = 'ocaml',
    fs = 'fsharp',
    r = 'r',
    jl = 'julia',
    php = 'php',
    pl = 'perl',
    scala = 'scala',
    dart = 'dart',
    zig = 'zig',
    nim = 'nim',
    v = 'v',
    vue = 'vue',
    svelte = 'svelte',
  }
  return lang_map[ext] or ''
end

---Format a file as a message part
---@param file HeadlessFileInfo
---@param prompt? string Optional prompt to find mention position
---@return OpencodeMessagePart
function M.format_file_part(file, prompt)
  local rel_path = vim.fn.fnamemodify(file.path, ':~:.')
  local mention = '@' .. rel_path
  local pos = prompt and prompt:find(mention, 1, true)
  pos = pos and pos - 1 or 0 -- convert to 0-based index

  local file_part = {
    type = 'file',
    filename = rel_path,
    mime = get_mime_type(file),
    url = 'file://' .. file.path,
  }

  if prompt and prompt:find(mention, 1, true) then
    file_part.source = {
      path = file.path,
      type = 'file',
      text = { start = pos, value = mention, ['end'] = pos + #mention },
    }
  end

  return file_part
end

---Format a selection as a message part
---@param selection HeadlessSelection
---@return OpencodeMessagePart
function M.format_selection_part(selection)
  local lang = ''
  if selection.file then
    lang = get_markdown_lang(selection.file.name or '')
  end

  local content = indent_code_block(selection.content)

  return {
    type = 'text',
    text = vim.json.encode({
      context_type = 'selection',
      file = selection.file,
      content = string.format('`````%s\n%s\n`````', lang, content),
      lines = selection.lines,
    }),
    synthetic = true,
  }
end

---Format diagnostics as a message part
---@param diagnostics HeadlessDiagnostic[]
---@return OpencodeMessagePart
function M.format_diagnostics_part(diagnostics)
  local diag_list = {}
  for _, diag in ipairs(diagnostics) do
    local short_msg = diag.message:gsub('%s+', ' '):gsub('^%s', ''):gsub('%s$', '')
    table.insert(diag_list, {
      msg = short_msg,
      severity = diag.severity,
      pos = 'l' .. (diag.lnum or 0) + 1 .. ':c' .. (diag.col or 0) + 1,
    })
  end

  return {
    type = 'text',
    text = vim.json.encode({ context_type = 'diagnostics', content = diag_list }),
    synthetic = true,
  }
end

---Format a subagent as a message part
---@param agent string
---@param prompt string
---@return OpencodeMessagePart
function M.format_subagent_part(agent, prompt)
  local mention = '@' .. agent
  local pos = prompt:find(mention, 1, true)
  pos = pos and pos - 1 or 0 -- convert to 0-based index

  return {
    type = 'agent',
    name = agent,
    source = { value = mention, start = pos, ['end'] = pos + #mention },
  }
end

-- Image format to MIME type mapping
local IMAGE_MIME_TYPES = {
  png = 'image/png',
  jpeg = 'image/jpeg',
  jpg = 'image/jpeg',
  gif = 'image/gif',
  webp = 'image/webp',
}

---Format a base64 image as a message part
---@param image HeadlessImage
---@param index? number Optional index for generating unique filename
---@return OpencodeMessagePart
function M.format_image_part(image, index)
  local format = (image.format or 'png'):lower()
  local mime = IMAGE_MIME_TYPES[format] or 'image/png'
  local filename = string.format('image_%d.%s', index or 1, format)

  return {
    type = 'file',
    filename = filename,
    mime = mime,
    url = string.format('data:%s;base64,%s', mime, image.data),
  }
end

---Format prompt and contexts into message parts
---@param prompt string The user prompt
---@param opts { context?: HeadlessContext, contexts?: HeadlessContext[] }
---@return OpencodeMessagePart[]
function M.format_parts(prompt, opts)
  local contexts = M.normalize_contexts(opts)

  -- Start with the prompt
  local parts = { { type = 'text', text = prompt } }

  -- Track files already added to avoid duplicates
  local added_files = {}

  -- Process each context
  for _, ctx in ipairs(contexts) do
    local current_file = nil
    if ctx.current_file then
      current_file = M.normalize_file(ctx.current_file)
    end

    -- Add mentioned files
    for _, file_path in ipairs(ctx.mentioned_files or {}) do
      local file = M.normalize_file(file_path)
      -- Skip if already added or same as current_file
      if not added_files[file.path] then
        if not current_file or file.path ~= current_file.path then
          table.insert(parts, M.format_file_part(file, prompt))
          added_files[file.path] = true
        end
      end
    end

    -- Add selections
    for _, sel in ipairs(ctx.selections or {}) do
      local normalized_sel = M.normalize_selection(sel, current_file)
      table.insert(parts, M.format_selection_part(normalized_sel))
    end

    -- Add subagents
    for _, agent in ipairs(ctx.subagents or {}) do
      table.insert(parts, M.format_subagent_part(agent, prompt))
    end

    -- Add current file (at the end, after mentioned files)
    if current_file and not added_files[current_file.path] then
      table.insert(parts, M.format_file_part(current_file))
      added_files[current_file.path] = true
    end

    -- Add diagnostics
    if ctx.diagnostics and #ctx.diagnostics > 0 then
      table.insert(parts, M.format_diagnostics_part(ctx.diagnostics))
    end

    -- Add base64 images
    for i, image in ipairs(ctx.images or {}) do
      table.insert(parts, M.format_image_part(image, i))
    end
  end

  return parts
end

return M
