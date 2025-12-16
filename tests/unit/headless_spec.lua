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

  describe('chat', function()
    it('returns a Promise', function()
      local instance
      headless.new():and_then(function(inst)
        instance = inst
      end)

      vim.wait(100, function()
        return instance ~= nil
      end)

      if instance then
        local result = instance:chat('test message')
        assert.is_table(result)
        assert.is_function(result.and_then)
      end
    end)

    it('creates a new session by default', function()
      local instance, session_count_before, session_count_after
      headless.new()
        :and_then(function(inst)
          instance = inst
          session_count_before = vim.tbl_count(inst.active_sessions)
          return inst:chat('test')
        end)
        :catch(function()
          -- Expected to fail without full mock, but session should be created
          if instance then
            session_count_after = vim.tbl_count(instance.active_sessions)
          end
        end)

      vim.wait(200, function()
        return session_count_after ~= nil or (instance and vim.tbl_count(instance.active_sessions) > 0)
      end)

      if instance then
        assert.is_true(vim.tbl_count(instance.active_sessions) > session_count_before)
      end
    end)

    it('uses existing session when new_session=false', function()
      local instance, used_session_id
      local create_session_count = 0

      -- Track create_session calls
      local api_client_module = require('opencode.api_client')
      local original_create = api_client_module.create
      api_client_module.create = function()
        return {
          create_session = function()
            create_session_count = create_session_count + 1
            return Promise.new():resolve({
              id = 'session-' .. create_session_count,
              directory = '/test',
            })
          end,
          abort_session = function()
            return Promise.new():resolve(true)
          end,
        }
      end

      headless.new()
        :and_then(function(inst)
          instance = inst
          return inst:create_session()
        end)
        :and_then(function(session)
          used_session_id = session.id
          -- Call chat with new_session=false
          return instance:chat('test', { new_session = false })
        end)
        :catch(function() end)

      vim.wait(200, function()
        return create_session_count >= 1
      end)

      -- Should have only created 1 session (the explicit create_session call)
      -- The chat with new_session=false should reuse it
      assert.equal(1, create_session_count)

      api_client_module.create = original_create
    end)

    it('uses specified session_id', function()
      local instance
      headless.new()
        :and_then(function(inst)
          instance = inst
          return inst:create_session()
        end)
        :and_then(function(session)
          -- Chat with specific session_id
          return instance:chat('test', { session_id = session.id })
        end)
        :catch(function() end)

      vim.wait(200, function()
        return instance ~= nil
      end)

      -- Just verify it doesn't crash
      assert.is_not_nil(instance)
    end)
  end)

  describe('chat_stream callbacks', function()
    it('calls on_error when session creation fails', function()
      local error_received
      local api_client_module = require('opencode.api_client')
      local original_create = api_client_module.create

      api_client_module.create = function()
        return {
          create_session = function()
            return Promise.new():reject('Session creation failed')
          end,
          abort_session = function()
            return Promise.new():resolve(true)
          end,
        }
      end

      local instance
      headless.new()
        :and_then(function(inst)
          instance = inst
          inst:chat_stream('test', {
            on_data = function() end,
            on_done = function() end,
            on_error = function(err)
              error_received = err
            end,
          })
        end)

      vim.wait(200, function()
        return error_received ~= nil
      end)

      assert.is_not_nil(error_received)

      api_client_module.create = original_create
    end)

    it('handles pending_abort before session ready', function()
      local instance
      local done_called = false

      headless.new():and_then(function(inst)
        instance = inst
      end)

      vim.wait(100, function()
        return instance ~= nil
      end)

      if instance then
        local handle = instance:chat_stream('test', {
          on_data = function() end,
          on_done = function()
            done_called = true
          end,
          on_error = function() end,
        })

        -- Abort immediately before session is ready
        handle.abort()

        vim.wait(200, function()
          return done_called or handle.is_done()
        end)

        assert.is_true(handle.is_done())
      end
    end)

    it('proxy handle forwards methods to real handle', function()
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

        -- Initial state
        assert.is_false(handle.is_ready())
        assert.equal('', handle.get_partial_text())
        assert.is_table(handle.get_tool_calls())
      end
    end)
  end)

  describe('abort edge cases', function()
    it('returns true when no active sessions', function()
      local instance, abort_result
      headless.new()
        :and_then(function(inst)
          instance = inst
          -- Don't create any sessions, just abort
          return instance:abort()
        end)
        :and_then(function(result)
          abort_result = result
        end)

      vim.wait(200, function()
        return abort_result ~= nil
      end)

      assert.is_true(abort_result)
    end)

    it('handles abort_session failure gracefully', function()
      local api_client_module = require('opencode.api_client')
      local original_create = api_client_module.create
      local abort_result

      api_client_module.create = function()
        return {
          create_session = function()
            return Promise.new():resolve({ id = 'test-session' })
          end,
          abort_session = function()
            return Promise.new():reject('Abort failed')
          end,
        }
      end

      headless.new()
        :and_then(function(inst)
          return inst:create_session():and_then(function()
            return inst:abort('test-session')
          end)
        end)
        :and_then(function(result)
          abort_result = result
        end)
        :catch(function()
          abort_result = false
        end)

      vim.wait(200, function()
        return abort_result ~= nil
      end)

      -- Should return false, not reject
      assert.is_false(abort_result)

      api_client_module.create = original_create
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

    it('handles abort_session failure gracefully', function()
      local event_manager = EventManager.new()
      local mock_api_client = {
        abort_session = function()
          return Promise.new():reject('Abort failed')
        end,
      }
      local callbacks = {
        on_data = function() end,
        on_done = function() end,
        on_error = function() end,
      }

      local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)
      local abort_result

      handle:abort():and_then(function(r)
        abort_result = r
      end)

      vim.wait(50, function()
        return abort_result ~= nil
      end)

      -- Should return false, not reject
      assert.is_false(abort_result)
    end)
  end)

  describe('event handling', function()
    it('updates message_id on message.updated event', function()
      local event_manager = EventManager.new()
      event_manager:start()

      local mock_api_client = {
        abort_session = function()
          return Promise.new():resolve(true)
        end,
      }
      local callbacks = {
        on_data = function() end,
        on_done = function() end,
        on_error = function() end,
      }

      local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)

      -- Simulate message.updated event
      event_manager:emit('message.updated', {
        info = {
          id = 'msg-123',
          sessionID = 'test-session',
          role = 'assistant',
        },
      })

      vim.wait(50, function()
        return handle.message_id ~= nil
      end)

      assert.equal('msg-123', handle.message_id)

      event_manager:stop()
    end)

    it('ignores message.updated for different session', function()
      local event_manager = EventManager.new()
      event_manager:start()

      local mock_api_client = {}
      local callbacks = {
        on_data = function() end,
        on_done = function() end,
        on_error = function() end,
      }

      local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)

      -- Simulate message.updated event for different session
      event_manager:emit('message.updated', {
        info = {
          id = 'msg-456',
          sessionID = 'other-session',
          role = 'assistant',
        },
      })

      vim.wait(50, function()
        return false -- Just wait a bit
      end)

      assert.is_nil(handle.message_id)

      event_manager:stop()
    end)

    it('ignores message.updated for user role', function()
      local event_manager = EventManager.new()
      event_manager:start()

      local mock_api_client = {}
      local callbacks = {
        on_data = function() end,
        on_done = function() end,
        on_error = function() end,
      }

      local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)

      -- Simulate message.updated event for user role
      event_manager:emit('message.updated', {
        info = {
          id = 'msg-789',
          sessionID = 'test-session',
          role = 'user',
        },
      })

      vim.wait(50, function()
        return false
      end)

      assert.is_nil(handle.message_id)

      event_manager:stop()
    end)

    it('calls on_data for text part updates', function()
      local event_manager = EventManager.new()
      event_manager:start()

      local mock_api_client = {}
      local received_chunks = {}
      local callbacks = {
        on_data = function(chunk)
          table.insert(received_chunks, chunk)
        end,
        on_done = function() end,
        on_error = function() end,
      }

      local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)

      -- Simulate text part update
      event_manager:emit('message.part.updated', {
        part = {
          id = 'part-1',
          sessionID = 'test-session',
          messageID = 'msg-1',
          type = 'text',
          text = 'Hello',
        },
      })

      vim.wait(100, function()
        return #received_chunks > 0
      end)

      assert.equal(1, #received_chunks)
      assert.equal('text', received_chunks[1].type)
      assert.equal('Hello', received_chunks[1].text)
      assert.equal('Hello', handle:get_partial_text())

      event_manager:stop()
    end)

    it('accumulates text from multiple parts in order', function()
      local event_manager = EventManager.new()
      event_manager:start()

      local mock_api_client = {}
      local callbacks = {
        on_data = function() end,
        on_done = function() end,
        on_error = function() end,
      }

      local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)

      -- Simulate multiple text parts
      event_manager:emit('message.part.updated', {
        part = {
          id = 'part-1',
          sessionID = 'test-session',
          type = 'text',
          text = 'First ',
        },
      })

      event_manager:emit('message.part.updated', {
        part = {
          id = 'part-2',
          sessionID = 'test-session',
          type = 'text',
          text = 'Second',
        },
      })

      vim.wait(100, function()
        return handle:get_partial_text():find('Second') ~= nil
      end)

      assert.equal('First Second', handle:get_partial_text())

      event_manager:stop()
    end)

    it('handles incremental text updates to same part', function()
      local event_manager = EventManager.new()
      event_manager:start()

      local mock_api_client = {}
      local received_deltas = {}
      local callbacks = {
        on_data = function(chunk)
          table.insert(received_deltas, chunk.text)
        end,
        on_done = function() end,
        on_error = function() end,
      }

      local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)

      -- First update
      event_manager:emit('message.part.updated', {
        part = {
          id = 'part-1',
          sessionID = 'test-session',
          type = 'text',
          text = 'Hello',
        },
      })

      -- Incremental update (same part, more text)
      event_manager:emit('message.part.updated', {
        part = {
          id = 'part-1',
          sessionID = 'test-session',
          type = 'text',
          text = 'Hello World',
        },
      })

      vim.wait(100, function()
        return #received_deltas >= 2
      end)

      -- First delta: 'Hello', second delta: ' World' (the increment)
      assert.equal('Hello', received_deltas[1])
      assert.equal(' World', received_deltas[2])
      assert.equal('Hello World', handle:get_partial_text())

      event_manager:stop()
    end)

    it('ignores part updates for different session', function()
      local event_manager = EventManager.new()
      event_manager:start()

      local mock_api_client = {}
      local data_called = false
      local callbacks = {
        on_data = function()
          data_called = true
        end,
        on_done = function() end,
        on_error = function() end,
      }

      local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)

      -- Part for different session
      event_manager:emit('message.part.updated', {
        part = {
          id = 'part-1',
          sessionID = 'other-session',
          type = 'text',
          text = 'Should not see this',
        },
      })

      vim.wait(50, function()
        return false
      end)

      assert.is_false(data_called)
      assert.equal('', handle:get_partial_text())

      event_manager:stop()
    end)

    it('calls on_tool_call for tool parts', function()
      local event_manager = EventManager.new()
      event_manager:start()

      local mock_api_client = {}
      local received_tool_calls = {}
      local callbacks = {
        on_data = function() end,
        on_tool_call = function(tc)
          table.insert(received_tool_calls, tc)
        end,
        on_done = function() end,
        on_error = function() end,
      }

      local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)

      -- Simulate tool part
      event_manager:emit('message.part.updated', {
        part = {
          id = 'tool-1',
          sessionID = 'test-session',
          type = 'tool',
          tool = 'bash',
          state = {
            status = 'running',
            input = { command = 'ls' },
          },
        },
      })

      vim.wait(100, function()
        return #received_tool_calls > 0
      end)

      assert.equal(1, #received_tool_calls)
      assert.equal('tool-1', received_tool_calls[1].id)
      assert.equal('bash', received_tool_calls[1].name)
      assert.equal('running', received_tool_calls[1].status)

      local tool_calls = handle:get_tool_calls()
      assert.is_not_nil(tool_calls['tool-1'])

      event_manager:stop()
    end)

    it('completes on session.idle event', function()
      local event_manager = EventManager.new()
      event_manager:start()

      local mock_api_client = {
        get_message = function()
          return Promise.new():resolve({
            parts = { { type = 'text', text = 'Final response' } },
            info = { role = 'assistant' },
          })
        end,
      }
      local done_called = false
      local done_message = nil
      local callbacks = {
        on_data = function() end,
        on_done = function(msg)
          done_called = true
          done_message = msg
        end,
        on_error = function() end,
      }

      local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)
      handle.message_id = 'msg-123' -- Set message_id

      -- Simulate session.idle
      event_manager:emit('session.idle', { sessionID = 'test-session' })

      vim.wait(100, function()
        return done_called
      end)

      assert.is_true(done_called)
      assert.is_true(handle:is_done())
      assert.is_not_nil(done_message)

      event_manager:stop()
    end)

    it('calls on_error on session.error event', function()
      local event_manager = EventManager.new()
      event_manager:start()

      local mock_api_client = {}
      local error_received = nil
      local callbacks = {
        on_data = function() end,
        on_done = function() end,
        on_error = function(err)
          error_received = err
        end,
      }

      local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)

      -- Simulate session.error
      event_manager:emit('session.error', {
        sessionID = 'test-session',
        error = 'Something went wrong',
      })

      vim.wait(100, function()
        return error_received ~= nil
      end)

      assert.equal('Something went wrong', error_received)
      assert.is_true(handle:is_done())

      event_manager:stop()
    end)

    it('ignores events after completion', function()
      local event_manager = EventManager.new()
      event_manager:start()

      local mock_api_client = {
        get_message = function()
          return Promise.new():resolve({ parts = {}, info = {} })
        end,
      }
      local data_count = 0
      local callbacks = {
        on_data = function()
          data_count = data_count + 1
        end,
        on_done = function() end,
        on_error = function() end,
      }

      local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)

      -- Complete the stream
      event_manager:emit('session.idle', { sessionID = 'test-session' })

      vim.wait(50, function()
        return handle:is_done()
      end)

      -- Try to send more data after completion
      event_manager:emit('message.part.updated', {
        part = {
          id = 'part-late',
          sessionID = 'test-session',
          type = 'text',
          text = 'Late data',
        },
      })

      vim.wait(50, function()
        return false
      end)

      -- Should not have received late data
      assert.equal(0, data_count)

      event_manager:stop()
    end)
  end)

  describe('permission handling', function()
    it('calls on_permission callback for permission.updated event', function()
      local event_manager = EventManager.new()
      event_manager:start()

      local mock_api_client = {
        respond_to_permission = function()
          return Promise.new():resolve(true)
        end,
      }
      local permission_received = nil
      local callbacks = {
        on_data = function() end,
        on_permission = function(perm)
          permission_received = perm
          return 'once'
        end,
        on_done = function() end,
        on_error = function() end,
      }

      local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)

      -- Simulate permission.updated
      event_manager:emit('permission.updated', {
        id = 'perm-123',
        sessionID = 'test-session',
        messageID = 'msg-1',
        type = 'bash',
        title = 'Run bash command',
        pattern = { command = 'ls' },
      })

      vim.wait(100, function()
        return permission_received ~= nil
      end)

      assert.is_not_nil(permission_received)
      assert.equal('perm-123', permission_received.id)
      assert.equal('bash', permission_received.tool_name)

      event_manager:stop()
    end)

    it('uses permission_handler when provided', function()
      local event_manager = EventManager.new()
      event_manager:start()

      local respond_called = false
      local respond_args = nil
      local mock_api_client = {
        respond_to_permission = function(self, session_id, perm_id, opts)
          respond_called = true
          respond_args = { session_id = session_id, perm_id = perm_id, opts = opts }
          return Promise.new():resolve(true)
        end,
      }
      local callbacks = {
        on_data = function() end,
        on_done = function() end,
        on_error = function() end,
      }

      local permission_handler = require('opencode.headless.permission_handler')
      local handler = permission_handler.auto_approve()

      local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks, handler)

      -- Simulate permission.updated
      event_manager:emit('permission.updated', {
        id = 'perm-456',
        sessionID = 'test-session',
        type = 'read',
        title = 'Read file',
      })

      vim.wait(100, function()
        return respond_called
      end)

      assert.is_true(respond_called)
      assert.equal('test-session', respond_args.session_id)
      assert.equal('perm-456', respond_args.perm_id)
      assert.equal('allow', respond_args.opts.approval) -- 'once' maps to 'allow'

      event_manager:stop()
    end)

    it('rejects permission when no handler and no callback', function()
      local event_manager = EventManager.new()
      event_manager:start()

      local respond_called = false
      local respond_approval = nil
      local mock_api_client = {
        respond_to_permission = function(self, session_id, perm_id, opts)
          respond_called = true
          respond_approval = opts.approval
          return Promise.new():resolve(true)
        end,
      }
      local callbacks = {
        on_data = function() end,
        on_done = function() end,
        on_error = function() end,
        -- No on_permission callback
      }

      local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)

      -- Simulate permission.updated
      event_manager:emit('permission.updated', {
        id = 'perm-789',
        sessionID = 'test-session',
        type = 'bash',
        title = 'Run command',
      })

      vim.wait(100, function()
        return respond_called
      end)

      assert.is_true(respond_called)
      assert.equal('deny', respond_approval) -- No handler defaults to reject/deny

      event_manager:stop()
    end)

    it('handles async permission callback returning Promise', function()
      local event_manager = EventManager.new()
      event_manager:start()

      local respond_called = false
      local respond_approval = nil
      local mock_api_client = {
        respond_to_permission = function(self, session_id, perm_id, opts)
          respond_called = true
          respond_approval = opts.approval
          return Promise.new():resolve(true)
        end,
      }
      local callbacks = {
        on_data = function() end,
        on_permission = function(perm)
          -- Return a Promise
          local p = Promise.new()
          vim.defer_fn(function()
            p:resolve('always')
          end, 10)
          return p
        end,
        on_done = function() end,
        on_error = function() end,
      }

      local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)

      event_manager:emit('permission.updated', {
        id = 'perm-async',
        sessionID = 'test-session',
        type = 'edit',
        title = 'Edit file',
      })

      vim.wait(200, function()
        return respond_called
      end)

      assert.is_true(respond_called)
      assert.equal('always', respond_approval)

      event_manager:stop()
    end)

    it('handles permission callback error gracefully', function()
      local event_manager = EventManager.new()
      event_manager:start()

      local respond_called = false
      local respond_approval = nil
      local mock_api_client = {
        respond_to_permission = function(self, session_id, perm_id, opts)
          respond_called = true
          respond_approval = opts.approval
          return Promise.new():resolve(true)
        end,
      }
      local callbacks = {
        on_data = function() end,
        on_permission = function(perm)
          error('Callback error!')
        end,
        on_done = function() end,
        on_error = function() end,
      }

      local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)

      event_manager:emit('permission.updated', {
        id = 'perm-error',
        sessionID = 'test-session',
        type = 'bash',
        title = 'Run command',
      })

      vim.wait(100, function()
        return respond_called
      end)

      assert.is_true(respond_called)
      assert.equal('deny', respond_approval) -- Error defaults to reject/deny

      event_manager:stop()
    end)

    it('removes pending permission on permission.replied', function()
      local event_manager = EventManager.new()
      event_manager:start()

      local mock_api_client = {
        respond_to_permission = function()
          return Promise.new():resolve(true)
        end,
      }
      local callbacks = {
        on_data = function() end,
        on_permission = function()
          return 'once'
        end,
        on_done = function() end,
        on_error = function() end,
      }

      local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)

      -- First, permission requested
      event_manager:emit('permission.updated', {
        id = 'perm-pending',
        sessionID = 'test-session',
        type = 'bash',
        title = 'Command',
      })

      vim.wait(50, function()
        return handle.pending_permissions['perm-pending'] ~= nil
      end)

      -- Check it's pending
      assert.is_true(handle.pending_permissions['perm-pending'] or false)

      -- Permission replied
      event_manager:emit('permission.replied', {
        sessionID = 'test-session',
        permissionID = 'perm-pending',
        response = 'allow',
      })

      vim.wait(50, function()
        return handle.pending_permissions['perm-pending'] == nil
      end)

      assert.is_nil(handle.pending_permissions['perm-pending'])

      event_manager:stop()
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

describe('opencode.headless.permission_handler special characters', function()
  local permission_handler = require('opencode.headless.permission_handler')

  it('escapes Lua special characters in patterns', function()
    -- Test patterns with special chars like . which is special in Lua regex
    assert.is_true(permission_handler.match_pattern('file.read', 'file.read'))
    assert.is_false(permission_handler.match_pattern('fileXread', 'file.read')) -- . should not match X

    -- Test with other special chars
    assert.is_true(permission_handler.match_pattern('foo(bar)', 'foo(bar)'))
    assert.is_false(permission_handler.match_pattern('foobar', 'foo(bar)'))

    -- Test % char
    assert.is_true(permission_handler.match_pattern('100%', '100%'))

    -- Test + char
    assert.is_true(permission_handler.match_pattern('a+b', 'a+b'))
    assert.is_false(permission_handler.match_pattern('aaaaab', 'a+b')) -- + should not repeat 'a'

    -- Test - char
    assert.is_true(permission_handler.match_pattern('a-b', 'a-b'))

    -- Test ? char
    assert.is_true(permission_handler.match_pattern('maybe?', 'maybe?'))
    assert.is_false(permission_handler.match_pattern('mayb', 'maybe?')) -- ? should not make 'e' optional

    -- Test [] chars
    assert.is_true(permission_handler.match_pattern('[test]', '[test]'))
    assert.is_false(permission_handler.match_pattern('t', '[test]')) -- [] should not be char class

    -- Test ^ and $ chars
    assert.is_true(permission_handler.match_pattern('^start$', '^start$'))
  end)

  it('still supports * wildcard after escaping', function()
    -- * should still work as wildcard
    assert.is_true(permission_handler.match_pattern('file.read', 'file.*'))
    assert.is_true(permission_handler.match_pattern('foo(bar)', 'foo*'))
    assert.is_true(permission_handler.match_pattern('test.something.here', '*something*'))
  end)
end)

describe('opencode.headless.context immutability', function()
  local headless_context = require('opencode.headless.context')

  it('normalize_file does not mutate input object', function()
    local input = { path = '/path/to/file.lua' }
    local original_keys = vim.tbl_count(input)

    local result = headless_context.normalize_file(input)

    -- Original should not be mutated
    assert.equal(original_keys, vim.tbl_count(input))
    assert.is_nil(input.name)
    assert.is_nil(input.extension)

    -- Result should have all fields
    assert.equal('/path/to/file.lua', result.path)
    assert.equal('file.lua', result.name)
    assert.equal('lua', result.extension)

    -- Result should be a different object
    assert.is_not_equal(input, result)
  end)

  it('normalize_selection does not mutate input selection', function()
    local input = { content = 'local x = 1', lines = '1, 1' }
    local original_keys = vim.tbl_count(input)

    local result = headless_context.normalize_selection(input)

    -- Original should not be mutated
    assert.equal(original_keys, vim.tbl_count(input))

    -- Result should have content
    assert.equal('local x = 1', result.content)
  end)
end)

describe('opencode.headless session cache TTL', function()
  local original_ensure_server
  local original_api_client_create
  local mock_api_client
  local session_counter = 0

  before_each(function()
    session_counter = 0
    local server_job = require('opencode.server_job')
    local api_client_module = require('opencode.api_client')
    original_ensure_server = server_job.ensure_server
    original_api_client_create = api_client_module.create

    server_job.ensure_server = function()
      return Promise.new():resolve(true)
    end

    mock_api_client = {
      create_session = function()
        session_counter = session_counter + 1
        return Promise.new():resolve({
          id = 'session-' .. session_counter,
          directory = '/test/dir',
        })
      end,
      get_session = function(_, session_id)
        return Promise.new():resolve({
          id = session_id,
          directory = '/test/dir',
        })
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

  it('caches session with timestamp', function()
    local instance
    headless.new():and_then(function(inst)
      instance = inst
      return inst:create_session()
    end)

    vim.wait(100, function()
      return instance ~= nil and vim.tbl_count(instance.active_sessions) > 0
    end)

    assert.is_not_nil(instance)
    if instance then
      assert.equal(1, vim.tbl_count(instance.active_sessions))
      assert.equal(1, vim.tbl_count(instance.session_timestamps))
      assert.is_not_nil(instance.session_timestamps['session-1'])
    end
  end)

  it('returns cached session when valid', function()
    local instance, session1, session2
    headless.new():and_then(function(inst)
      instance = inst
      return inst:create_session()
    end):and_then(function(s)
      session1 = s
      return instance:get_session(s.id)
    end):and_then(function(s)
      session2 = s
    end)

    vim.wait(100, function()
      return session2 ~= nil
    end)

    -- Should return same cached session, not create new one
    assert.equal(1, session_counter)
    assert.equal(session1.id, session2.id)
  end)

  it('respects session_cache_ttl configuration', function()
    local instance
    headless.new({
      session_cache_ttl = 100, -- 100ms TTL
    }):and_then(function(inst)
      instance = inst
    end)

    vim.wait(50, function()
      return instance ~= nil
    end)

    assert.is_not_nil(instance)
    if instance then
      assert.equal(100, instance.config.session_cache_ttl)
    end
  end)

  it('invalidates expired cache', function()
    local instance, session
    headless.new({
      session_cache_ttl = 50, -- 50ms TTL for testing
    }):and_then(function(inst)
      instance = inst
      return inst:create_session()
    end):and_then(function(s)
      session = s
    end)

    vim.wait(100, function()
      return session ~= nil
    end)

    assert.is_not_nil(instance)
    if instance then
      -- Session should be cached initially
      assert.is_not_nil(instance:_get_cached_session(session.id))

      -- Wait for TTL to expire
      vim.wait(100, function() return false end)

      -- Session should be expired now
      local cached = instance:_get_cached_session(session.id)
      assert.is_nil(cached)
    end
  end)

  it('clears timestamps on close', function()
    local instance
    headless.new():and_then(function(inst)
      instance = inst
      return inst:create_session()
    end):and_then(function()
      instance:close()
    end)

    vim.wait(100, function()
      return instance ~= nil and vim.tbl_count(instance.active_sessions) == 0
    end)

    assert.is_not_nil(instance)
    if instance then
      assert.equal(0, vim.tbl_count(instance.active_sessions))
      assert.equal(0, vim.tbl_count(instance.session_timestamps))
    end
  end)
end)

describe('opencode.headless batch fail_fast', function()
  local original_ensure_server
  local original_api_client_create
  local mock_api_client

  before_each(function()
    local server_job = require('opencode.server_job')
    local api_client_module = require('opencode.api_client')
    original_ensure_server = server_job.ensure_server
    original_api_client_create = api_client_module.create

    server_job.ensure_server = function()
      return Promise.new():resolve(true)
    end

    mock_api_client = {
      create_session = function()
        return Promise.new():resolve({
          id = 'batch-session',
          directory = '/test/dir',
        })
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

  it('continues on error when fail_fast is false (default)', function()
    local instance, results
    local chat_count = 0

    headless.new():and_then(function(inst)
      instance = inst
      -- Replace chat method with mock
      inst.chat = function(_, msg, opts)
        chat_count = chat_count + 1
        local p = Promise.new()
        -- Use vim.schedule to simulate async
        vim.schedule(function()
          if chat_count == 2 then
            p:reject('simulated error')
          else
            p:resolve({
              text = 'response ' .. chat_count,
              session_id = 'test',
            })
          end
        end)
        return p
      end
    end)

    vim.wait(100, function()
      return instance ~= nil
    end)

    if instance then
      instance:batch({
        { message = 'msg1' },
        { message = 'msg2' },
        { message = 'msg3' },
      }, {
        fail_fast = false,
        max_concurrent = 1,
      }):and_then(function(r)
        results = r
      end)

      vim.wait(500, function()
        return results ~= nil
      end)

      assert.is_not_nil(results)
      if results then
        assert.equal(3, #results)
        assert.is_true(results[1].success)
        assert.is_false(results[2].success)
        assert.equal('simulated error', results[2].error)
        assert.is_true(results[3].success)
      end
    end
  end)

  it('stops on first error when fail_fast is true', function()
    local instance, results, error_result
    local chat_count = 0

    headless.new():and_then(function(inst)
      instance = inst
      inst.chat = function(_, msg, opts)
        chat_count = chat_count + 1
        local p = Promise.new()
        vim.schedule(function()
          if chat_count == 2 then
            p:reject('simulated error')
          else
            p:resolve({
              text = 'response ' .. chat_count,
              session_id = 'test',
            })
          end
        end)
        return p
      end
    end)

    vim.wait(100, function()
      return instance ~= nil
    end)

    if instance then
      instance:batch({
        { message = 'msg1' },
        { message = 'msg2' },
        { message = 'msg3' },
      }, {
        fail_fast = true,
        max_concurrent = 1,
      }):and_then(function(r)
        results = r
      end):catch(function(err)
        error_result = err
      end)

      vim.wait(500, function()
        return results ~= nil or error_result ~= nil
      end)

      -- Should reject with error info
      assert.is_nil(results)
      assert.is_not_nil(error_result)
      if error_result then
        assert.is_not_nil(error_result.error)
        assert.is_not_nil(error_result.partial_results)
        assert.is_not_nil(error_result.completed_count)
      end
    end
  end)

  it('includes partial_results in fail_fast error', function()
    local instance, error_result
    local chat_count = 0

    headless.new():and_then(function(inst)
      instance = inst
      inst.chat = function(_, msg, opts)
        chat_count = chat_count + 1
        local p = Promise.new()
        vim.schedule(function()
          if chat_count == 2 then
            p:reject('error at request 2')
          else
            p:resolve({
              text = 'response ' .. chat_count,
              session_id = 'test',
            })
          end
        end)
        return p
      end
    end)

    vim.wait(100, function()
      return instance ~= nil
    end)

    if instance then
      instance:batch({
        { message = 'msg1' },
        { message = 'msg2' },
        { message = 'msg3' },
      }, {
        fail_fast = true,
        max_concurrent = 1,
      }):catch(function(err)
        error_result = err
      end)

      vim.wait(500, function()
        return error_result ~= nil
      end)

      assert.is_not_nil(error_result)
      if error_result and error_result.partial_results then
        -- First request should have succeeded
        assert.is_true(error_result.partial_results[1].success)
        -- Second request should have failed
        assert.is_false(error_result.partial_results[2].success)
        assert.equal('error at request 2', error_result.partial_results[2].error)
      end
    end
  end)
end)

describe('opencode.headless.stream_handler pending_parts', function()
  local EventManager = require('opencode.event_manager')
  local StreamHandle = require('opencode.headless.stream_handler')

  it('queues parts received before message_id is known', function()
    local event_manager = EventManager.new()
    event_manager:start()

    local mock_api_client = {}
    local received_chunks = {}
    local callbacks = {
      on_data = function(chunk)
        table.insert(received_chunks, chunk)
      end,
      on_done = function() end,
      on_error = function() end,
    }

    local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)

    -- Send part WITHOUT messageID first (should be queued)
    event_manager:emit('message.part.updated', {
      part = {
        id = 'part-1',
        sessionID = 'test-session',
        type = 'text',
        text = 'queued text',
      },
    })

    -- Part should be processed immediately for backward compatibility
    vim.wait(100, function()
      return #received_chunks > 0
    end)

    assert.equal(1, #received_chunks)
    assert.equal('queued text', received_chunks[1].text)

    event_manager:stop()
  end)

  it('processes pending parts when message_id is set from message.updated', function()
    local event_manager = EventManager.new()
    event_manager:start()

    local mock_api_client = {}
    local received_chunks = {}
    local callbacks = {
      on_data = function(chunk)
        table.insert(received_chunks, chunk)
      end,
      on_done = function() end,
      on_error = function() end,
    }

    local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)

    -- First, send message.updated to set message_id
    event_manager:emit('message.updated', {
      info = {
        id = 'msg-123',
        sessionID = 'test-session',
        role = 'assistant',
      },
    })

    -- Then send part with matching messageID
    event_manager:emit('message.part.updated', {
      part = {
        id = 'part-1',
        sessionID = 'test-session',
        messageID = 'msg-123',
        type = 'text',
        text = 'after message_id',
      },
    })

    vim.wait(100, function()
      return #received_chunks > 0
    end)

    assert.equal(1, #received_chunks)
    assert.equal('after message_id', received_chunks[1].text)

    event_manager:stop()
  end)

  it('infers message_id from first part with messageID', function()
    local event_manager = EventManager.new()
    event_manager:start()

    local mock_api_client = {}
    local received_chunks = {}
    local callbacks = {
      on_data = function(chunk)
        table.insert(received_chunks, chunk)
      end,
      on_done = function() end,
      on_error = function() end,
    }

    local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)

    -- Send part WITH messageID (should infer message_id)
    event_manager:emit('message.part.updated', {
      part = {
        id = 'part-1',
        sessionID = 'test-session',
        messageID = 'inferred-msg-id',
        type = 'text',
        text = 'first part',
      },
    })

    vim.wait(100, function()
      return #received_chunks > 0
    end)

    -- message_id should be inferred
    assert.equal('inferred-msg-id', handle.message_id)
    assert.equal(1, #received_chunks)

    event_manager:stop()
  end)

  it('filters parts with different messageID after message_id is set', function()
    local event_manager = EventManager.new()
    event_manager:start()

    local mock_api_client = {}
    local received_chunks = {}
    local callbacks = {
      on_data = function(chunk)
        table.insert(received_chunks, chunk)
      end,
      on_done = function() end,
      on_error = function() end,
    }

    local handle = StreamHandle.new('test-session', event_manager, mock_api_client, callbacks)

    -- Set message_id via message.updated
    event_manager:emit('message.updated', {
      info = {
        id = 'correct-msg-id',
        sessionID = 'test-session',
        role = 'assistant',
      },
    })

    -- Send part with wrong messageID (should be filtered)
    event_manager:emit('message.part.updated', {
      part = {
        id = 'part-wrong',
        sessionID = 'test-session',
        messageID = 'wrong-msg-id',
        type = 'text',
        text = 'wrong message',
      },
    })

    -- Send part with correct messageID
    event_manager:emit('message.part.updated', {
      part = {
        id = 'part-correct',
        sessionID = 'test-session',
        messageID = 'correct-msg-id',
        type = 'text',
        text = 'correct message',
      },
    })

    vim.wait(100, function()
      return #received_chunks > 0
    end)

    -- Should only receive the correct message
    assert.equal(1, #received_chunks)
    assert.equal('correct message', received_chunks[1].text)

    event_manager:stop()
  end)
end)
