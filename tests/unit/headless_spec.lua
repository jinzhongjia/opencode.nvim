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
