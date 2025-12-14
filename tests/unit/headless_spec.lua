-- tests/unit/headless_spec.lua
-- Basic smoke tests for the headless API module

local headless = require('opencode.headless')
local assert = require('luassert')
local Promise = require('opencode.promise')
local state = require('opencode.state')

describe('opencode.headless', function()
  local original_ensure_server
  local original_api_client_create
  local mock_api_client

  before_each(function()
    -- Save originals
    local server_job = require('opencode.server_job')
    local api_client_module = require('opencode.api_client')
    original_ensure_server = server_job.ensure_server
    original_api_client_create = api_client_module.create

    -- Mock server_job.ensure_server to return immediately
    server_job.ensure_server = function()
      local p = Promise.new()
      p:resolve(true)
      return p
    end

    -- Create mock api_client
    mock_api_client = {
      create_session = function(self, params)
        local _ = self -- suppress unused warning
        local _ = params -- suppress unused warning
        local p = Promise.new()
        p:resolve({
          id = 'test-session-1',
          directory = '/test/dir',
          created_at = os.time(),
        })
        return p
      end,
      abort_session = function(self, session_id)
        local _ = self -- suppress unused warning
        local _ = session_id -- suppress unused warning
        local p = Promise.new()
        p:resolve(true)
        return p
      end,
    }

    -- Mock api_client.create to return our mock
    api_client_module.create = function()
      return mock_api_client
    end
  end)

  after_each(function()
    -- Restore originals
    local server_job = require('opencode.server_job')
    local api_client_module = require('opencode.api_client')
    if original_ensure_server then
      server_job.ensure_server = original_ensure_server
    end
    if original_api_client_create then
      api_client_module.create = original_api_client_create
    end
  end)

  describe('new', function()
    it('returns a Promise', function()
      local promise = headless.new()
      assert.is_table(promise)
      assert.is_function(promise.and_then)
    end)

    it('creates a headless instance with expected methods', function()
      local result
      headless.new():and_then(function(instance)
        result = instance
      end)

      vim.wait(200, function()
        return result ~= nil
      end)

      assert.is_not_nil(result)
      if result then
        assert.is_function(result.chat)
        assert.is_function(result.create_session)
        assert.is_function(result.send_message)
        assert.is_function(result.get_session)
        assert.is_function(result.list_sessions)
        assert.is_function(result.abort)
        assert.is_function(result.close)
        assert.is_table(result.active_sessions)
      end
    end)
  end)

  describe('create_session', function()
    it('creates a new session and caches it', function()
      local instance, session, error_msg
      headless.new()
        :and_then(function(inst)
          instance = inst
          return instance:create_session()
        end)
        :and_then(function(sess)
          session = sess
        end)
        :catch(function(err)
          error_msg = err
        end)

      vim.wait(300, function()
        return session ~= nil or error_msg ~= nil
      end)

      if error_msg then
        error('Promise rejected: ' .. tostring(error_msg))
      end

      assert.is_not_nil(session, 'Session should not be nil')
      if session and instance then
        assert.equal('test-session-1', session.id)
        assert.is_not_nil(instance.active_sessions['test-session-1'])
      end
    end)
  end)

  describe('close', function()
    it('cleans up active sessions', function()
      local instance
      headless.new():and_then(function(inst)
        instance = inst
        return instance:create_session()
      end):and_then(function()
        instance:close()
      end)

      vim.wait(200, function()
        return instance ~= nil
      end)

      if instance then
        assert.equal(0, vim.tbl_count(instance.active_sessions))
      end
    end)
  end)

  describe('chat_stream', function()
    it('returns a StreamHandle', function()
      local instance
      headless.new():and_then(function(inst)
        instance = inst
      end)

      vim.wait(100, function()
        return instance ~= nil
      end)

      if instance then
        local handle = instance:chat_stream('test', {
          on_data = function() end,
          on_done = function() end,
          on_error = function() end,
        })

        assert.is_not_nil(handle)
        assert.is_function(handle.abort)
        assert.is_function(handle.is_done)
        assert.is_function(handle.get_partial_text)
      end
    end)

    it('returns a StreamHandle with tool call methods', function()
      local instance
      headless.new():and_then(function(inst)
        instance = inst
      end)

      vim.wait(100, function()
        return instance ~= nil
      end)

      if instance then
        local handle = instance:chat_stream('test', {
          on_data = function() end,
          on_tool_call = function() end,
          on_done = function() end,
          on_error = function() end,
        })

        assert.is_not_nil(handle)
        assert.is_function(handle.get_tool_calls)
        assert.is_table(handle:get_tool_calls())
      end
    end)
  end)

  describe('abort', function()
    it('aborts a specific session', function()
      local instance, abort_result
      headless.new()
        :and_then(function(inst)
          instance = inst
          return instance:create_session()
        end)
        :and_then(function(session)
          return instance:abort(session.id)
        end)
        :and_then(function(result)
          abort_result = result
        end)

      vim.wait(200, function()
        return abort_result ~= nil
      end)

      assert.is_true(abort_result)
    end)

    it('aborts all sessions when no session_id provided', function()
      local instance, abort_result
      headless.new()
        :and_then(function(inst)
          instance = inst
          return instance:create_session()
        end)
        :and_then(function()
          return instance:abort() -- no session_id
        end)
        :and_then(function(result)
          abort_result = result
        end)

      vim.wait(200, function()
        return abort_result ~= nil
      end)

      assert.is_true(abort_result)
    end)
  end)

  describe('get_session', function()
    it('returns cached session', function()
      local instance, session, retrieved_session
      headless.new()
        :and_then(function(inst)
          instance = inst
          return instance:create_session()
        end)
        :and_then(function(sess)
          session = sess
          return instance:get_session(sess.id)
        end)
        :and_then(function(sess)
          retrieved_session = sess
        end)

      vim.wait(200, function()
        return retrieved_session ~= nil
      end)

      assert.is_not_nil(retrieved_session)
      assert.equal(session.id, retrieved_session.id)
    end)
  end)

  describe('list_sessions', function()
    it('returns a Promise', function()
      local instance
      headless.new():and_then(function(inst)
        instance = inst
      end)

      vim.wait(100, function()
        return instance ~= nil
      end)

      if instance then
        local promise = instance:list_sessions()
        assert.is_table(promise)
        assert.is_function(promise.and_then)
      end
    end)
  end)

  describe('send_message', function()
    it('rejects when session not found', function()
      local instance, error_msg
      headless.new()
        :and_then(function(inst)
          instance = inst
          return instance:send_message('non-existent-session', 'test')
        end)
        :catch(function(err)
          error_msg = err
        end)

      vim.wait(200, function()
        return error_msg ~= nil
      end)

      assert.is_not_nil(error_msg)
      assert.is_truthy(error_msg:match('Session not found'))
    end)
  end)
end)

describe('opencode.headless.permission_handler', function()
  local permission_handler = require('opencode.headless.permission_handler')

  describe('new', function()
    it('creates a permission handler with defaults', function()
      local handler = permission_handler.new()
      assert.is_not_nil(handler)
      assert.is_function(handler.handle)
    end)

    it('creates a handler with auto_approve strategy', function()
      local handler = permission_handler.new({ strategy = 'auto_approve' })
      assert.is_not_nil(handler)
    end)

    it('creates a handler with rules', function()
      local handler = permission_handler.new({
        strategy = 'callback',
        rules = {
          { pattern = 'read', action = 'always' },
          { pattern = 'bash', action = 'once' },
        },
      })
      assert.is_not_nil(handler)
    end)
  end)

  describe('match_pattern', function()
    it('matches exact tool names', function()
      assert.is_true(permission_handler.match_pattern('bash', 'bash'))
      assert.is_true(permission_handler.match_pattern('read', 'read'))
      assert.is_false(permission_handler.match_pattern('bash', 'read'))
    end)

    it('matches wildcard patterns', function()
      assert.is_true(permission_handler.match_pattern('bash', '*'))
      assert.is_true(permission_handler.match_pattern('read', '*'))
      assert.is_true(permission_handler.match_pattern('anything', '*'))
    end)

    it('matches partial wildcards', function()
      assert.is_true(permission_handler.match_pattern('read_file', 'read*'))
      assert.is_true(permission_handler.match_pattern('readonly', 'read*'))
      assert.is_false(permission_handler.match_pattern('bash', 'read*'))
    end)
  end)

  describe('handle', function()
    it('auto_approve returns once', function()
      local handler = permission_handler.auto_approve()
      local result

      handler:handle({ tool_name = 'bash' }):and_then(function(r)
        result = r
      end)

      vim.wait(50, function()
        return result ~= nil
      end)

      assert.equal('once', result)
    end)

    it('auto_reject returns reject', function()
      local handler = permission_handler.auto_reject()
      local result

      handler:handle({ tool_name = 'bash' }):and_then(function(r)
        result = r
      end)

      vim.wait(50, function()
        return result ~= nil
      end)

      assert.equal('reject', result)
    end)

    it('applies rules in order', function()
      local handler = permission_handler.new({
        strategy = 'auto_reject',
        rules = {
          { pattern = 'read', action = 'always' },
          { pattern = 'bash', action = 'once' },
        },
      })

      local read_result, bash_result, other_result

      handler:handle({ tool_name = 'read' }):and_then(function(r)
        read_result = r
      end)
      handler:handle({ tool_name = 'bash' }):and_then(function(r)
        bash_result = r
      end)
      handler:handle({ tool_name = 'unknown' }):and_then(function(r)
        other_result = r
      end)

      vim.wait(50, function()
        return read_result ~= nil and bash_result ~= nil and other_result ~= nil
      end)

      assert.equal('always', read_result)
      assert.equal('once', bash_result)
      assert.equal('reject', other_result)
    end)

    it('applies rule conditions', function()
      local handler = permission_handler.new({
        strategy = 'auto_reject',
        rules = {
          {
            pattern = 'bash',
            action = 'always',
            condition = function(perm)
              return perm.safe == true
            end,
          },
          { pattern = 'bash', action = 'once' },
        },
      })

      local safe_result, unsafe_result

      handler:handle({ tool_name = 'bash', safe = true }):and_then(function(r)
        safe_result = r
      end)
      handler:handle({ tool_name = 'bash', safe = false }):and_then(function(r)
        unsafe_result = r
      end)

      vim.wait(50, function()
        return safe_result ~= nil and unsafe_result ~= nil
      end)

      assert.equal('always', safe_result)
      assert.equal('once', unsafe_result)
    end)
  end)

  describe('safe_defaults', function()
    it('creates a handler with safe default rules', function()
      local handler = permission_handler.safe_defaults()
      assert.is_not_nil(handler)

      local read_result, bash_result, unknown_result

      handler:handle({ tool_name = 'read' }):and_then(function(r)
        read_result = r
      end)
      handler:handle({ tool_name = 'bash' }):and_then(function(r)
        bash_result = r
      end)
      handler:handle({ tool_name = 'dangerous_unknown' }):and_then(function(r)
        unknown_result = r
      end)

      vim.wait(50, function()
        return read_result ~= nil and bash_result ~= nil and unknown_result ~= nil
      end)

      -- read is always allowed
      assert.equal('always', read_result)
      -- bash needs per-call approval
      assert.equal('once', bash_result)
      -- unknown tools are rejected
      assert.equal('reject', unknown_result)
    end)

    it('allows custom rules to override defaults', function()
      local handler = permission_handler.safe_defaults({
        { pattern = 'bash', action = 'always' }, -- Override bash to always allow
      })

      local bash_result

      handler:handle({ tool_name = 'bash' }):and_then(function(r)
        bash_result = r
      end)

      vim.wait(50, function()
        return bash_result ~= nil
      end)

      -- Custom rule takes precedence
      assert.equal('always', bash_result)
    end)
  end)
end)

describe('opencode.headless.stream_handler', function()
  local StreamHandle = require('opencode.headless.stream_handler')
  local EventManager = require('opencode.event_manager')

  describe('new', function()
    it('creates a stream handle with required fields', function()
      local event_manager = EventManager.new()
      local mock_api_client = {
        abort_session = function()
          local p = Promise.new()
          p:resolve(true)
          return p
        end,
      }
      local callbacks = {
        on_data = function() end,
        on_done = function() end,
        on_error = function() end,
      }

      local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)

      assert.is_not_nil(handle)
      assert.is_function(handle.abort)
      assert.is_function(handle.is_done)
      assert.is_function(handle.get_partial_text)
      assert.is_function(handle.get_tool_calls)
    end)
  end)

  describe('is_done', function()
    it('returns false initially', function()
      local event_manager = EventManager.new()
      local mock_api_client = {}
      local callbacks = {
        on_data = function() end,
        on_done = function() end,
        on_error = function() end,
      }

      local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)
      assert.is_false(handle:is_done())
    end)
  end)

  describe('get_partial_text', function()
    it('returns empty string initially', function()
      local event_manager = EventManager.new()
      local mock_api_client = {}
      local callbacks = {
        on_data = function() end,
        on_done = function() end,
        on_error = function() end,
      }

      local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)
      assert.equal('', handle:get_partial_text())
    end)
  end)

  describe('get_tool_calls', function()
    it('returns empty table initially', function()
      local event_manager = EventManager.new()
      local mock_api_client = {}
      local callbacks = {
        on_data = function() end,
        on_done = function() end,
        on_error = function() end,
      }

      local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)
      local tool_calls = handle:get_tool_calls()
      assert.is_table(tool_calls)
      assert.equal(0, vim.tbl_count(tool_calls))
    end)
  end)

  describe('abort', function()
    it('returns a Promise', function()
      local event_manager = EventManager.new()
      local mock_api_client = {
        abort_session = function()
          local p = Promise.new()
          p:resolve(true)
          return p
        end,
      }
      local callbacks = {
        on_data = function() end,
        on_done = function() end,
        on_error = function() end,
      }

      local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)
      local result = handle:abort()
      assert.is_table(result)
      assert.is_function(result.and_then)
    end)

    it('returns false when already aborted', function()
      local event_manager = EventManager.new()
      local mock_api_client = {
        abort_session = function()
          local p = Promise.new()
          p:resolve(true)
          return p
        end,
      }
      local callbacks = {
        on_data = function() end,
        on_done = function() end,
        on_error = function() end,
      }

      local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)

      -- First abort
      handle:abort()

      -- Second abort should return false
      local second_result
      handle:abort():and_then(function(r)
        second_result = r
      end)

      vim.wait(50, function()
        return second_result ~= nil
      end)

      assert.is_false(second_result)
    end)
  end)
end)

describe('opencode.headless.context', function()
  local headless_context = require('opencode.headless.context')

  describe('normalize_file', function()
    it('normalizes string path to HeadlessFileInfo', function()
      local file = headless_context.normalize_file('/path/to/file.lua')
      assert.equal('/path/to/file.lua', file.path)
      assert.equal('file.lua', file.name)
      assert.equal('lua', file.extension)
    end)

    it('fills missing fields in HeadlessFileInfo', function()
      local file = headless_context.normalize_file({ path = '/path/to/script.py' })
      assert.equal('/path/to/script.py', file.path)
      assert.equal('script.py', file.name)
      assert.equal('py', file.extension)
    end)

    it('preserves existing fields in HeadlessFileInfo', function()
      local file = headless_context.normalize_file({
        path = '/path/to/file.lua',
        name = 'custom_name.lua',
        extension = 'custom',
      })
      assert.equal('custom_name.lua', file.name)
      assert.equal('custom', file.extension)
    end)
  end)

  describe('normalize_contexts', function()
    it('returns empty array when no context provided', function()
      local contexts = headless_context.normalize_contexts({})
      assert.equal(0, #contexts)
    end)

    it('wraps single context in array', function()
      local contexts = headless_context.normalize_contexts({
        context = { current_file = '/path/to/file.lua' },
      })
      assert.equal(1, #contexts)
      assert.equal('/path/to/file.lua', contexts[1].current_file)
    end)

    it('returns contexts array as-is', function()
      local contexts = headless_context.normalize_contexts({
        contexts = {
          { current_file = '/path/to/a.lua' },
          { current_file = '/path/to/b.lua' },
        },
      })
      assert.equal(2, #contexts)
    end)

    it('prefers contexts over context', function()
      local contexts = headless_context.normalize_contexts({
        context = { current_file = '/single.lua' },
        contexts = {
          { current_file = '/a.lua' },
          { current_file = '/b.lua' },
        },
      })
      assert.equal(2, #contexts)
      assert.equal('/a.lua', contexts[1].current_file)
    end)
  end)

  describe('normalize_selection', function()
    it('normalizes selection with file', function()
      local selection = { content = 'local x = 1', lines = '1, 1', file = '/path/to/file.lua' }
      local result = headless_context.normalize_selection(selection)

      assert.equal('local x = 1', result.content)
      assert.equal('1, 1', result.lines)
      assert.is_table(result.file)
      assert.equal('/path/to/file.lua', result.file.path)
    end)

    it('uses default_file when selection.file is nil', function()
      local selection = { content = 'local x = 1', lines = '1, 1' }
      local default_file = { path = '/default/file.lua', name = 'file.lua', extension = 'lua' }
      local result = headless_context.normalize_selection(selection, default_file)

      assert.equal(default_file, result.file)
    end)

    it('returns nil file when no file provided', function()
      local selection = { content = 'local x = 1', lines = '1, 1' }
      local result = headless_context.normalize_selection(selection)

      assert.is_nil(result.file)
    end)
  end)

  describe('format_file_part', function()
    it('formats file as message part', function()
      local file = { path = '/home/user/project/src/main.lua', name = 'main.lua', extension = 'lua' }
      local part = headless_context.format_file_part(file)

      assert.equal('file', part.type)
      assert.is_string(part.filename)
      assert.equal('text/plain', part.mime)
      assert.is_not_nil(part.url:match('^file://'))
    end)

    it('detects image MIME types', function()
      local png_file = { path = '/path/to/image.png', name = 'image.png', extension = 'png' }
      local part = headless_context.format_file_part(png_file)
      assert.equal('image/png', part.mime)

      local jpg_file = { path = '/path/to/photo.jpg', name = 'photo.jpg', extension = 'jpg' }
      local jpg_part = headless_context.format_file_part(jpg_file)
      assert.equal('image/jpeg', jpg_part.mime)
    end)

    it('includes source when mention found in prompt', function()
      local file = { path = '/path/to/file.lua', name = 'file.lua', extension = 'lua' }
      local rel_path = vim.fn.fnamemodify(file.path, ':~:.')
      local prompt = 'review @' .. rel_path .. ' please'
      local part = headless_context.format_file_part(file, prompt)

      assert.is_not_nil(part.source)
      assert.equal('file', part.source.type)
    end)
  end)

  describe('format_subagent_part', function()
    it('formats subagent as agent part', function()
      local part = headless_context.format_subagent_part('plan', 'use @plan to help')

      assert.equal('agent', part.type)
      assert.equal('plan', part.name)
      assert.is_not_nil(part.source)
      assert.equal('@plan', part.source.value)
    end)

    it('calculates correct position when mention found', function()
      local part = headless_context.format_subagent_part('build', 'please @build this')

      assert.equal(7, part.source.start) -- 0-based index of '@build'
      assert.equal(13, part.source['end']) -- start + length of '@build'
    end)

    it('uses position 0 when mention not found', function()
      local part = headless_context.format_subagent_part('plan', 'no mention here')

      assert.equal(0, part.source.start)
    end)
  end)

  describe('format_selection_part', function()
    it('formats selection as synthetic text part', function()
      local selection = {
        file = { path = '/path/to/file.lua', name = 'file.lua', extension = 'lua' },
        content = 'local x = 1',
        lines = '10, 12',
      }
      local part = headless_context.format_selection_part(selection)

      assert.equal('text', part.type)
      assert.is_true(part.synthetic)
      assert.is_string(part.text)

      local decoded = vim.json.decode(part.text)
      assert.equal('selection', decoded.context_type)
      assert.equal('10, 12', decoded.lines)
    end)
  end)

  describe('format_diagnostics_part', function()
    it('formats diagnostics as synthetic text part', function()
      local diagnostics = {
        { message = 'unused variable x', severity = 2, lnum = 10, col = 5 },
        { message = 'missing return', severity = 1, lnum = 20, col = 1 },
      }
      local part = headless_context.format_diagnostics_part(diagnostics)

      assert.equal('text', part.type)
      assert.is_true(part.synthetic)

      local decoded = vim.json.decode(part.text)
      assert.equal('diagnostics', decoded.context_type)
      assert.equal(2, #decoded.content)
    end)
  end)

  describe('format_parts', function()
    it('returns prompt-only parts when no context', function()
      local parts = headless_context.format_parts('hello world', {})
      assert.equal(1, #parts)
      assert.equal('text', parts[1].type)
      assert.equal('hello world', parts[1].text)
    end)

    it('includes mentioned files', function()
      local parts = headless_context.format_parts('review this', {
        context = {
          mentioned_files = { '/path/to/file.lua' },
        },
      })

      assert.is_true(#parts >= 2)
      assert.equal('text', parts[1].type)

      local has_file_part = false
      for _, part in ipairs(parts) do
        if part.type == 'file' then
          has_file_part = true
          break
        end
      end
      assert.is_true(has_file_part)
    end)

    it('includes current file', function()
      local parts = headless_context.format_parts('fix this', {
        context = {
          current_file = '/path/to/main.lua',
        },
      })

      local has_file_part = false
      for _, part in ipairs(parts) do
        if part.type == 'file' then
          has_file_part = true
          break
        end
      end
      assert.is_true(has_file_part)
    end)

    it('includes selections', function()
      local parts = headless_context.format_parts('explain this', {
        context = {
          selections = {
            { content = 'local x = 1', lines = '1, 1' },
          },
        },
      })

      local has_selection = false
      for _, part in ipairs(parts) do
        if part.synthetic and part.text then
          local ok, decoded = pcall(vim.json.decode, part.text)
          if ok and decoded.context_type == 'selection' then
            has_selection = true
            break
          end
        end
      end
      assert.is_true(has_selection)
    end)

    it('includes diagnostics', function()
      local parts = headless_context.format_parts('fix errors', {
        context = {
          diagnostics = {
            { message = 'error here', lnum = 1, col = 1 },
          },
        },
      })

      local has_diagnostics = false
      for _, part in ipairs(parts) do
        if part.synthetic and part.text then
          local ok, decoded = pcall(vim.json.decode, part.text)
          if ok and decoded.context_type == 'diagnostics' then
            has_diagnostics = true
            break
          end
        end
      end
      assert.is_true(has_diagnostics)
    end)

    it('handles multiple contexts (flat merge)', function()
      local parts = headless_context.format_parts('review all', {
        contexts = {
          { current_file = '/path/to/a.lua' },
          { current_file = '/path/to/b.lua' },
        },
      })

      local file_count = 0
      for _, part in ipairs(parts) do
        if part.type == 'file' then
          file_count = file_count + 1
        end
      end
      assert.equal(2, file_count)
    end)

    it('avoids duplicate files', function()
      local parts = headless_context.format_parts('review', {
        contexts = {
          { mentioned_files = { '/path/to/file.lua' } },
          { mentioned_files = { '/path/to/file.lua' } },
        },
      })

      local file_count = 0
      for _, part in ipairs(parts) do
        if part.type == 'file' then
          file_count = file_count + 1
        end
      end
      assert.equal(1, file_count)
    end)

    it('does not duplicate current_file in mentioned_files', function()
      local parts = headless_context.format_parts('review', {
        context = {
          current_file = '/path/to/main.lua',
          mentioned_files = { '/path/to/main.lua', '/path/to/other.lua' },
        },
      })

      local file_count = 0
      for _, part in ipairs(parts) do
        if part.type == 'file' then
          file_count = file_count + 1
        end
      end
      -- Should have other.lua + main.lua (current_file), but main.lua only once
      assert.equal(2, file_count)
    end)
  end)

  describe('format_image_part', function()
    it('formats base64 image with default png format', function()
      local image = { data = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==' }
      local part = headless_context.format_image_part(image)

      assert.equal('file', part.type)
      assert.equal('image_1.png', part.filename)
      assert.equal('image/png', part.mime)
      assert.is_not_nil(part.url:match('^data:image/png;base64,'))
    end)

    it('formats base64 image with specified format', function()
      local image = { data = 'fakebase64data', format = 'jpeg' }
      local part = headless_context.format_image_part(image)

      assert.equal('file', part.type)
      assert.equal('image_1.jpeg', part.filename)
      assert.equal('image/jpeg', part.mime)
      assert.is_not_nil(part.url:match('^data:image/jpeg;base64,'))
    end)

    it('uses index for unique filenames', function()
      local image = { data = 'fakedata', format = 'webp' }
      local part = headless_context.format_image_part(image, 3)

      assert.equal('image_3.webp', part.filename)
    end)

    it('normalizes format to lowercase', function()
      local image = { data = 'fakedata', format = 'PNG' }
      local part = headless_context.format_image_part(image)

      assert.equal('image/png', part.mime)
      assert.equal('image_1.png', part.filename)
    end)

    it('handles gif format', function()
      local image = { data = 'fakegif', format = 'gif' }
      local part = headless_context.format_image_part(image)

      assert.equal('image/gif', part.mime)
    end)
  end)

  describe('format_parts with images', function()
    it('includes images in parts', function()
      local parts = headless_context.format_parts('describe this image', {
        context = {
          images = {
            { data = 'base64imagedata', format = 'png' },
          },
        },
      })

      local has_image = false
      for _, part in ipairs(parts) do
        if part.type == 'file' and part.mime == 'image/png' then
          has_image = true
          break
        end
      end
      assert.is_true(has_image)
    end)

    it('includes multiple images with unique indices', function()
      local parts = headless_context.format_parts('compare these images', {
        context = {
          images = {
            { data = 'image1data', format = 'png' },
            { data = 'image2data', format = 'jpeg' },
          },
        },
      })

      local image_parts = {}
      for _, part in ipairs(parts) do
        if part.type == 'file' and part.mime:match('^image/') then
          table.insert(image_parts, part)
        end
      end
      assert.equal(2, #image_parts)
      assert.equal('image_1.png', image_parts[1].filename)
      assert.equal('image_2.jpeg', image_parts[2].filename)
    end)

    it('includes images alongside other context', function()
      local parts = headless_context.format_parts('analyze code and image', {
        context = {
          current_file = '/path/to/code.lua',
          images = {
            { data = 'screenshotdata', format = 'png' },
          },
        },
      })

      local has_file = false
      local has_image = false
      for _, part in ipairs(parts) do
        if part.type == 'file' then
          if part.mime == 'text/plain' then
            has_file = true
          elseif part.mime == 'image/png' then
            has_image = true
          end
        end
      end
      assert.is_true(has_file)
      assert.is_true(has_image)
    end)
  end)
end)

describe('opencode.headless.retry', function()
  local retry = require('opencode.headless.retry')

  describe('is_retryable', function()
    it('returns false for nil error', function()
      assert.is_false(retry.is_retryable(nil, { 'timeout' }))
    end)

    it('matches string errors', function()
      assert.is_true(retry.is_retryable('connection timeout', { 'timeout' }))
      assert.is_true(retry.is_retryable('rate_limit exceeded', { 'rate_limit' }))
      assert.is_false(retry.is_retryable('unknown error', { 'timeout' }))
    end)

    it('matches case-insensitively', function()
      assert.is_true(retry.is_retryable('TIMEOUT error', { 'timeout' }))
      assert.is_true(retry.is_retryable('Timeout Error', { 'TIMEOUT' }))
    end)

    it('matches table errors via inspect', function()
      local err = { code = 'ETIMEDOUT', message = 'connection failed' }
      assert.is_true(retry.is_retryable(err, { 'ETIMEDOUT' }))
    end)
  end)

  describe('calculate_delay', function()
    it('calculates exponential backoff', function()
      local config = { delay_ms = 1000, backoff = 'exponential', max_delay_ms = 30000 }
      local delay1 = retry.calculate_delay(1, config)
      local delay2 = retry.calculate_delay(2, config)
      local delay3 = retry.calculate_delay(3, config)

      -- With jitter, roughly: 1000, 2000, 4000
      assert.is_true(delay1 >= 900 and delay1 <= 1100)
      assert.is_true(delay2 >= 1800 and delay2 <= 2200)
      assert.is_true(delay3 >= 3600 and delay3 <= 4400)
    end)

    it('calculates linear backoff', function()
      local config = { delay_ms = 1000, backoff = 'linear', max_delay_ms = 30000 }
      local delay1 = retry.calculate_delay(1, config)
      local delay2 = retry.calculate_delay(2, config)
      local delay3 = retry.calculate_delay(3, config)

      -- With jitter, roughly: 1000, 2000, 3000
      assert.is_true(delay1 >= 900 and delay1 <= 1100)
      assert.is_true(delay2 >= 1800 and delay2 <= 2200)
      assert.is_true(delay3 >= 2700 and delay3 <= 3300)
    end)

    it('caps at max_delay_ms', function()
      local config = { delay_ms = 10000, backoff = 'exponential', max_delay_ms = 5000 }
      local delay = retry.calculate_delay(5, config)
      assert.is_true(delay <= 5000)
    end)
  end)

  describe('with_retry', function()
    it('returns result on success', function()
      local result
      local fn = function()
        return Promise.new():resolve('success')
      end

      retry.with_retry(fn):and_then(function(r)
        result = r
      end)

      vim.wait(50, function()
        return result ~= nil
      end)

      assert.equal('success', result)
    end)

    it('retries on retryable error', function()
      local attempts = 0
      local result

      local fn = function()
        attempts = attempts + 1
        if attempts < 2 then
          return Promise.new():reject('timeout error')
        end
        return Promise.new():resolve('success after retry')
      end

      retry.with_retry(fn, { delay_ms = 10 }):and_then(function(r)
        result = r
      end)

      vim.wait(200, function()
        return result ~= nil
      end)

      assert.equal(2, attempts)
      assert.equal('success after retry', result)
    end)

    it('does not retry on non-retryable error', function()
      local attempts = 0
      local error_result

      local fn = function()
        attempts = attempts + 1
        return Promise.new():reject('some random error')
      end

      retry.with_retry(fn, { retryable_errors = { 'timeout' } }):catch(function(err)
        error_result = err
      end)

      vim.wait(100, function()
        return error_result ~= nil
      end)

      assert.equal(1, attempts)
      assert.is_not_nil(error_result)
    end)

    it('respects max_attempts', function()
      local attempts = 0
      local error_result

      local fn = function()
        attempts = attempts + 1
        return Promise.new():reject('timeout')
      end

      retry.with_retry(fn, { max_attempts = 3, delay_ms = 10 }):catch(function(err)
        error_result = err
      end)

      vim.wait(300, function()
        return error_result ~= nil
      end)

      assert.equal(3, attempts)
      assert.is_not_nil(error_result)
    end)

    it('calls on_retry callback', function()
      local retry_calls = {}
      local fn = function()
        return Promise.new():reject('timeout')
      end

      retry.with_retry(fn, {
        max_attempts = 2,
        delay_ms = 10,
        on_retry = function(attempt, err, delay)
          table.insert(retry_calls, { attempt = attempt, err = err, delay = delay })
        end,
      }):catch(function() end)

      vim.wait(200, function()
        return #retry_calls >= 1
      end)

      assert.equal(1, #retry_calls)
      assert.equal(1, retry_calls[1].attempt)
    end)
  end)

  describe('create_wrapper', function()
    it('creates a reusable retry wrapper', function()
      local wrapper = retry.create_wrapper({ max_attempts = 2, delay_ms = 10 })
      local result

      local fn = function()
        return Promise.new():resolve('wrapped result')
      end

      wrapper(fn):and_then(function(r)
        result = r
      end)

      vim.wait(50, function()
        return result ~= nil
      end)

      assert.equal('wrapped result', result)
    end)
  end)
end)

describe('opencode.headless batch operations', function()
  local original_ensure_server
  local original_api_client_create
  local mock_api_client

  before_each(function()
    local server_job = require('opencode.server_job')
    local api_client_module = require('opencode.api_client')
    original_ensure_server = server_job.ensure_server
    original_api_client_create = api_client_module.create

    server_job.ensure_server = function()
      local p = Promise.new()
      p:resolve(true)
      return p
    end

    mock_api_client = {
      create_session = function()
        local p = Promise.new()
        p:resolve({ id = 'batch-session-' .. math.random(1000, 9999) })
        return p
      end,
      abort_session = function()
        return Promise.new():resolve(true)
      end,
    }

    api_client_module.create = function()
      return mock_api_client
    end
  end)

  after_each(function()
    local server_job = require('opencode.server_job')
    local api_client_module = require('opencode.api_client')
    if original_ensure_server then
      server_job.ensure_server = original_ensure_server
    end
    if original_api_client_create then
      api_client_module.create = original_api_client_create
    end
  end)

  describe('batch', function()
    it('returns a Promise', function()
      local instance
      headless.new():and_then(function(inst)
        instance = inst
      end)

      vim.wait(100, function()
        return instance ~= nil
      end)

      if instance then
        local result = instance:batch({})
        assert.is_table(result)
        assert.is_function(result.and_then)
      end
    end)

    it('returns empty array for empty requests', function()
      local instance, results
      headless.new():and_then(function(inst)
        instance = inst
        return instance:batch({})
      end):and_then(function(r)
        results = r
      end)

      vim.wait(100, function()
        return results ~= nil
      end)

      assert.is_table(results)
      assert.equal(0, #results)
    end)
  end)

  describe('map', function()
    it('returns a Promise', function()
      local instance
      headless.new():and_then(function(inst)
        instance = inst
      end)

      vim.wait(100, function()
        return instance ~= nil
      end)

      if instance then
        local result = instance:map({}, function() return { message = 'test' } end)
        assert.is_table(result)
        assert.is_function(result.and_then)
      end
    end)
  end)
end)
