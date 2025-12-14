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
  end)
end)
