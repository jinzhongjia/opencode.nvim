local Promise = require('opencode.promise')
local api_client_module = require('opencode.api_client')
local EventManager = require('opencode.event_manager')
local session_utils = require('opencode.session')
local server_job = require('opencode.server_job')
local retry_module = require('opencode.headless.retry')
local permission_handler_module = require('opencode.headless.permission_handler')

---@class RetryConfig
---@field max_attempts? number Maximum number of retry attempts (default: 3)
---@field delay_ms? number Initial delay between retries in ms (default: 1000)
---@field backoff? 'linear'|'exponential' Backoff strategy (default: 'exponential')
---@field max_delay_ms? number Maximum delay between retries (default: 30000)
---@field retryable_errors? string[] Error patterns that trigger retry
---@field on_retry? fun(attempt: number, error: any, delay: number): nil

---@class OpencodeHeadlessConfig
---@field model? string Default model (e.g., 'anthropic/claude-3-5-sonnet-20241022')
---@field agent? string Default agent (e.g., 'plan', 'build')
---@field auto_start_server? boolean Whether to auto-start server (default: true)
---@field directory? string Working directory (default: cwd)
---@field timeout? number Timeout in milliseconds (default: 120000)
---@field retry? RetryConfig|boolean Retry configuration (true for defaults, false to disable)
---@field permission_handler? PermissionHandlerConfig Permission handling configuration
---@field session_cache_ttl? number Session cache TTL in milliseconds (default: 300000, 5 minutes)

---@class OpencodeHeadless
---@field private config OpencodeHeadlessConfig
---@field private api_client OpencodeApiClient
---@field private event_manager EventManager
---@field private active_sessions table<string, Session>
---@field private session_timestamps table<string, number> Cache timestamps for sessions
---@field private server OpencodeServer|nil
---@field private retry_config RetryConfig|nil
---@field private permission_handler PermissionHandler|nil
local OpencodeHeadless = {}
OpencodeHeadless.__index = OpencodeHeadless

---Create a new headless client instance
---@param opts? OpencodeHeadlessConfig
---@return Promise<OpencodeHeadless>
function OpencodeHeadless.new(opts)
  opts = opts or {}

  -- Set defaults
  local config = {
    model = opts.model,
    agent = opts.agent,
    auto_start_server = opts.auto_start_server ~= false, -- default true
    directory = opts.directory or vim.fn.getcwd(),
    timeout = opts.timeout or 120000, -- 2 minutes default
    retry = opts.retry,
    session_cache_ttl = opts.session_cache_ttl or 300000, -- 5 minutes default
  }

  -- Normalize retry config
  local retry_config = nil
  if config.retry == true then
    retry_config = {} -- use defaults
  elseif type(config.retry) == 'table' then
    retry_config = config.retry
  end

  local promise = Promise.new()

  -- Ensure server is running
  local ensure_server_promise
  if config.auto_start_server then
    ensure_server_promise = server_job.ensure_server()
  else
    ensure_server_promise = Promise.new():resolve(nil)
  end

  ensure_server_promise
    :and_then(function(server)
      -- Create API client
      local api_client = api_client_module.create()

      -- Create event manager
      local event_manager = EventManager.new()
      event_manager:start()

      -- Create permission handler if configured
      local permission_handler = nil
      if opts.permission_handler then
        permission_handler = permission_handler_module.new(opts.permission_handler)
      end

      local instance = setmetatable({
        config = config,
        api_client = api_client,
        event_manager = event_manager,
        active_sessions = {}, -- Track sessions we're using
        session_timestamps = {}, -- Track when sessions were cached
        server = server,
        retry_config = retry_config,
        permission_handler = permission_handler,
      }, OpencodeHeadless)

      promise:resolve(instance)
    end)
    :catch(function(err)
      promise:reject('Failed to start headless client: ' .. vim.inspect(err))
    end)

  return promise
end

---Internal: Cache a session with timestamp
---@param session Session
---@private
function OpencodeHeadless:_cache_session(session)
  self.active_sessions[session.id] = session
  self.session_timestamps[session.id] = vim.loop.now()
end

---Internal: Check if a cached session is still valid (not expired)
---@param session_id string
---@return boolean
---@private
function OpencodeHeadless:_is_session_cache_valid(session_id)
  local timestamp = self.session_timestamps[session_id]
  if not timestamp then
    return false
  end
  local age = vim.loop.now() - timestamp
  return age < self.config.session_cache_ttl
end

---Internal: Get a cached session if valid, otherwise nil
---@param session_id string
---@return Session|nil
---@private
function OpencodeHeadless:_get_cached_session(session_id)
  if self:_is_session_cache_valid(session_id) then
    return self.active_sessions[session_id]
  end
  -- Cache expired, remove it
  self.active_sessions[session_id] = nil
  self.session_timestamps[session_id] = nil
  return nil
end

---Internal: Invalidate a cached session
---@param session_id string
---@private
function OpencodeHeadless:_invalidate_session_cache(session_id)
  self.active_sessions[session_id] = nil
  self.session_timestamps[session_id] = nil
end

---Internal: Create a new session
---@param model? string
---@param agent? string
---@return Promise<Session>
function OpencodeHeadless:_create_new_session(model, agent)
  -- Note: model and agent parameters are reserved for future use
  -- Currently they are not passed to create_session
  _ = model -- silence unused warning
  _ = agent -- silence unused warning
  return self.api_client:create_session():and_then(function(session)
    self:_cache_session(session)
    return session
  end)
end

---Send a chat message (single-turn conversation)
---@param message string The message to send
---@param opts? ChatOptions Chat options
---@return Promise<ChatResponse>
function OpencodeHeadless:chat(message, opts)
  opts = opts or {}

  -- Use existing session or create new one
  local session_promise
  if opts.session_id then
    local session = self:_get_cached_session(opts.session_id)
    if session then
      session_promise = Promise.new():resolve(session)
    else
      -- Try to get from API (cache expired or not found)
      session_promise = self.api_client:get_session(opts.session_id):and_then(function(s)
        self:_cache_session(s)
        return s
      end)
    end
  elseif opts.new_session == false then
    -- Try to use an existing active session (that hasn't expired)
    local valid_session = nil
    for session_id, _ in pairs(self.active_sessions) do
      if self:_is_session_cache_valid(session_id) then
        valid_session = self.active_sessions[session_id]
        break
      end
    end
    if valid_session then
      session_promise = Promise.new():resolve(valid_session)
    else
      -- No valid session, create new one
      session_promise = self:_create_new_session(opts.model or self.config.model, opts.agent or self.config.agent)
    end
  else
    -- Create new session (default behavior)
    session_promise = self:_create_new_session(opts.model or self.config.model, opts.agent or self.config.agent)
  end

  return session_promise:and_then(function(session)
    return self:send_message(session.id, message, opts)
  end)
end

---Send a message to a specific session
---@param session_id string The session ID
---@param message string The message to send
---@param opts? ChatOptions Chat options
---@return Promise<ChatResponse>
function OpencodeHeadless:send_message(session_id, message, opts)
  opts = opts or {}

  -- Get the session (from cache, must be valid)
  local session = self:_get_cached_session(session_id)
  if not session then
    return Promise.new():reject('Session not found or cache expired: ' .. session_id)
  end

  -- Refresh cache timestamp on use
  self.session_timestamps[session_id] = vim.loop.now()

  -- Build message parts using context if provided
  local parts
  if opts.context or opts.contexts then
    local headless_context = require('opencode.headless.context')
    parts = headless_context.format_parts(message, opts)
  else
    parts = { { type = 'text', text = message } }
  end

  -- Build message data
  local message_data = {
    parts = parts,
  }

  -- Add model if specified
  local model = opts.model or self.config.model
  if model then
    local provider, model_id = model:match('^(.-)/(.+)$')
    if provider and model_id then
      message_data.model = {
        providerID = provider,
        modelID = model_id,
      }
    end
  end

  -- Add agent if specified
  local agent = opts.agent or self.config.agent
  if agent then
    message_data.agent = agent
  end

  -- Send the message and wait for response (with optional retry)
  local send_fn = function()
    return self:_send_and_wait_for_response(session_id, message_data, opts.timeout)
  end

  if self.retry_config then
    return retry_module.with_retry(send_fn, self.retry_config)
  end

  return send_fn()
end

---Internal: Send message and wait for response
---@param session_id string
---@param message_data table
---@param timeout? number Optional timeout override
---@return Promise<ChatResponse>
function OpencodeHeadless:_send_and_wait_for_response(session_id, message_data, timeout)
  local promise = Promise.new()
  local assistant_message_id = nil
  local is_completed = false
  local timeout_timer = nil

  -- Forward declare handlers to avoid undefined references
  local on_message_updated, on_session_idle, on_session_error

  -- Cleanup function
  local function cleanup()
    if is_completed then
      return
    end
    is_completed = true

    -- Cancel timeout timer
    if timeout_timer then
      vim.fn.timer_stop(timeout_timer)
      timeout_timer = nil
    end

    -- Unsubscribe from events
    self.event_manager:unsubscribe('message.updated', on_message_updated)
    self.event_manager:unsubscribe('session.idle', on_session_idle)
    self.event_manager:unsubscribe('session.error', on_session_error)
  end

  -- Setup timeout
  local timeout_ms = timeout or self.config.timeout
  if timeout_ms and timeout_ms > 0 then
    timeout_timer = vim.fn.timer_start(timeout_ms, function()
      if not is_completed then
        cleanup()
        promise:reject('Request timed out after ' .. timeout_ms .. 'ms')
      end
    end)
  end

  -- Define error handler
  on_session_error = function(data)
    if data.sessionID == session_id then
      cleanup()
      promise:reject(data.error)
    end
  end

  -- Listen for message updates for this session
  on_message_updated = function(data)
    if data.info and data.info.sessionID == session_id and data.info.role == 'assistant' then
      -- Store the assistant message ID
      assistant_message_id = data.info.id
    end
  end

  -- Listen for session idle (means response is complete)
  on_session_idle = function(data)
    if data.sessionID == session_id then
      cleanup()

      if assistant_message_id then
        -- Fetch the complete message with parts
        self.api_client
          :get_message(session_id, assistant_message_id)
          :and_then(function(full_message)
            -- Extract text from message parts
            local response_text = ''
            for _, part in ipairs(full_message.parts or {}) do
              if part.type == 'text' and part.text then
                response_text = response_text .. part.text
              end
            end

            promise:resolve({
              text = response_text,
              message = full_message,
              session_id = session_id,
            })
          end)
          :catch(function(err)
            promise:reject('Failed to fetch complete message: ' .. vim.inspect(err))
          end)
      else
        promise:reject('No assistant response received')
      end
    end
  end

  -- Subscribe to events
  self.event_manager:subscribe('message.updated', on_message_updated)
  self.event_manager:subscribe('session.idle', on_session_idle)
  self.event_manager:subscribe('session.error', on_session_error)

  -- Send the message
  self.api_client:create_message(session_id, message_data):catch(function(err)
    -- Clean up on error (also cancels timeout timer)
    cleanup()
    promise:reject(err)
  end)

  return promise
end

---Create a new session
---@param opts? {title?: string, model?: string, agent?: string}
---@return Promise<Session>
function OpencodeHeadless:create_session(opts)
  opts = opts or {}
  return self.api_client:create_session({ title = opts.title }):and_then(function(session)
    self:_cache_session(session)
    return session
  end)
end

---Get a session by ID
---@param session_id string
---@return Promise<Session|nil>
function OpencodeHeadless:get_session(session_id)
  -- Check cache first (with TTL check)
  local session = self:_get_cached_session(session_id)
  if session then
    return Promise.new():resolve(session)
  end

  -- Fetch from API using existing session utilities
  return session_utils.get_by_id(session_id):and_then(function(s)
    if s then
      self:_cache_session(s)
    end
    return s
  end)
end

---List all sessions
---@return Promise<Session[]>
function OpencodeHeadless:list_sessions()
  -- Use existing session utilities to get all workspace sessions
  return session_utils.get_all_workspace_sessions()
end

---Abort a session
---@param session_id? string Session ID (if nil, aborts all active sessions)
---@return Promise<boolean>
function OpencodeHeadless:abort(session_id)
  if session_id then
    return self.api_client:abort_session(session_id)
      :and_then(function()
        return true
      end)
      :catch(function()
        return false
      end)
  else
    -- Abort all active sessions
    local session_ids = {}
    for sid, _ in pairs(self.active_sessions) do
      table.insert(session_ids, sid)
    end

    if #session_ids == 0 then
      return Promise.new():resolve(true)
    end

    -- Chain abort calls sequentially and track results
    local result_promise = Promise.new()
    local all_success = true
    local completed = 0
    local total = #session_ids

    for _, sid in ipairs(session_ids) do
      self.api_client:abort_session(sid)
        :and_then(function()
          completed = completed + 1
          if completed == total then
            result_promise:resolve(all_success)
          end
        end)
        :catch(function()
          all_success = false
          completed = completed + 1
          if completed == total then
            result_promise:resolve(all_success)
          end
        end)
    end

    return result_promise
  end
end

---Send a streaming chat message
---@param message string The message to send
---@param opts ChatStreamOptions Stream options with callbacks
---@return StreamHandle
function OpencodeHeadless:chat_stream(message, opts)
  local StreamHandle = require('opencode.headless.stream_handler')

  opts = opts or {}

  -- Create a proxy handle that forwards to the real handle once ready
  -- This allows returning immediately while the session is being created
  local proxy_state = {
    real_handle = nil,
    pending_abort = false,
    is_ready = false,
  }

  -- Default values when real_handle is not ready
  local proxy_defaults = {
    get_partial_text = '',
    get_tool_calls = {},
  }

  local proxy_handle = setmetatable({}, {
    __index = function(_, key)
      -- Special cases that need custom logic
      if key == 'abort' then
        return function()
          if proxy_state.real_handle then
            return proxy_state.real_handle:abort()
          end
          proxy_state.pending_abort = true
          return Promise.new():resolve(true)
        end
      elseif key == 'is_done' then
        return function()
          if proxy_state.real_handle then
            return proxy_state.real_handle:is_done()
          end
          return proxy_state.pending_abort
        end
      elseif key == 'is_ready' then
        return function()
          return proxy_state.is_ready
        end
      end

      -- Delegate to real_handle if ready, otherwise return default
      if proxy_state.real_handle then
        local method = proxy_state.real_handle[key]
        if type(method) == 'function' then
          return function(...)
            return method(proxy_state.real_handle, ...)
          end
        end
        return method
      end

      -- Return default value for known methods
      if proxy_defaults[key] ~= nil then
        return function()
          return proxy_defaults[key]
        end
      end

      return nil
    end,
  })

  -- Use existing session or create new one
  local session_promise
  if opts.session_id then
    local session = self:_get_cached_session(opts.session_id)
    if session then
      session_promise = Promise.new():resolve(session)
    else
      -- Try to get from API (cache expired or not found)
      session_promise = self.api_client:get_session(opts.session_id):and_then(function(s)
        self:_cache_session(s)
        return s
      end)
    end
  elseif opts.new_session == false then
    -- Try to use an existing active session (that hasn't expired)
    local valid_session = nil
    for session_id, _ in pairs(self.active_sessions) do
      if self:_is_session_cache_valid(session_id) then
        valid_session = self.active_sessions[session_id]
        break
      end
    end
    if valid_session then
      session_promise = Promise.new():resolve(valid_session)
    else
      -- No valid session, create new one
      session_promise = self:_create_new_session(opts.model or self.config.model, opts.agent or self.config.agent)
    end
  else
    -- Create new session (default behavior)
    session_promise = self:_create_new_session(opts.model or self.config.model, opts.agent or self.config.agent)
  end

  -- Start the streaming process
  session_promise
    :and_then(function(session)
      -- Check if abort was requested before we got the session
      if proxy_state.pending_abort then
        if opts.on_done then
          vim.schedule(function()
            opts.on_done({ parts = {}, info = { role = 'assistant' } })
          end)
        end
        return
      end

      -- Create callbacks wrapper with all callbacks
      local callbacks = {
        on_data = opts.on_data or function() end,
        on_tool_call = opts.on_tool_call,
        on_permission = opts.on_permission,
        on_done = opts.on_done or function() end,
        on_error = opts.on_error or function() end,
      }

      -- Determine which permission handler to use
      -- Priority: opts.permission_handler > self.permission_handler
      local permission_handler = nil
      if opts.permission_handler then
        permission_handler = permission_handler_module.new(opts.permission_handler)
      else
        permission_handler = self.permission_handler
      end

      -- Create stream handle with all callbacks and permission handler
      proxy_state.real_handle = StreamHandle.new(
        session.id,
        self.event_manager,
        self.api_client,
        callbacks,
        permission_handler
      )
      proxy_state.is_ready = true

      -- Build message parts using context if provided
      local parts
      if opts.context or opts.contexts then
        local headless_context = require('opencode.headless.context')
        parts = headless_context.format_parts(message, opts)
      else
        parts = { { type = 'text', text = message } }
      end

      -- Build message data
      local message_data = {
        parts = parts,
      }

      -- Add model if specified
      local model = opts.model or self.config.model
      if model then
        local provider, model_id = model:match('^(.-)/(.+)$')
        if provider and model_id then
          message_data.model = {
            providerID = provider,
            modelID = model_id,
          }
        end
      end

      -- Add agent if specified
      local agent = opts.agent or self.config.agent
      if agent then
        message_data.agent = agent
      end

      -- Send the message (this will trigger streaming events)
      return self.api_client:create_message(session.id, message_data)
    end)
    :catch(function(err)
      -- Call error callback
      if opts.on_error then
        vim.schedule(function()
          opts.on_error(err)
        end)
      end
    end)

  return proxy_handle
end

---Close the headless client and cleanup resources
function OpencodeHeadless:close()
  -- Stop event manager
  if self.event_manager then
    self.event_manager:stop()
  end

  -- Clear active sessions cache and timestamps
  self.active_sessions = {}
  self.session_timestamps = {}

  -- Note: We don't shutdown the server here as it might be used by other clients
  -- If you want to shutdown the server, call server:shutdown() explicitly
end

---@class BatchRequest
---@field message string The message to send
---@field context? HeadlessContext Context for this request
---@field contexts? HeadlessContext[] Multiple contexts
---@field model? string Override model
---@field agent? string Override agent

---@class BatchResult
---@field success boolean Whether the request succeeded
---@field response? ChatResponse The response (if success)
---@field error? any The error (if failed)
---@field index number Original index in the batch

---@class BatchOptions
---@field max_concurrent? number Maximum concurrent requests (default: 5)
---@field fail_fast? boolean Stop on first error (default: false)

---Execute multiple chat requests in parallel
---@param requests BatchRequest[] Array of chat requests
---@param opts? BatchOptions Batch options
---@return Promise<BatchResult[]>
function OpencodeHeadless:batch(requests, opts)
  opts = opts or {}
  local max_concurrent = opts.max_concurrent or 5
  local fail_fast = opts.fail_fast or false

  -- Create promises for all requests
  local results = {}
  for i = 1, #requests do
    results[i] = { success = false, index = i }
  end

  -- Track if we should abort due to fail_fast
  local should_abort = false
  local first_error = nil

  -- Process in batches
  local function process_batch(start_idx)
    -- Check if we should abort
    if should_abort then
      local promise = Promise.new()
      promise:reject(first_error)
      return promise
    end

    local batch_promises = {}
    local end_idx = math.min(start_idx + max_concurrent - 1, #requests)

    for i = start_idx, end_idx do
      local req = requests[i]
      local idx = i

      local request_promise = self:chat(req.message, {
        context = req.context,
        contexts = req.contexts,
        model = req.model,
        agent = req.agent,
      })
        :and_then(function(response)
          results[idx] = { success = true, response = response, index = idx }
          return results[idx]
        end)
        :catch(function(err)
          results[idx] = { success = false, error = err, index = idx }
          -- If fail_fast, mark for abort
          if fail_fast and not should_abort then
            should_abort = true
            first_error = err
          end
          return results[idx]
        end)

      table.insert(batch_promises, request_promise)
    end

    -- Wait for all promises in this batch to complete
    local batch_result_promise = Promise.new()
    local completed_count = 0
    local batch_size = #batch_promises

    local function check_batch_complete()
      completed_count = completed_count + 1
      if completed_count >= batch_size then
        -- Check if we should abort after this batch
        if should_abort then
          batch_result_promise:reject({
            error = first_error,
            partial_results = results,
            completed_count = end_idx,
          })
        else
          -- Process next batch if there are more requests
          if end_idx < #requests then
            process_batch(end_idx + 1)
              :and_then(function(r)
                batch_result_promise:resolve(r)
              end)
              :catch(function(err)
                batch_result_promise:reject(err)
              end)
          else
            batch_result_promise:resolve(results)
          end
        end
      end
    end

    for _, p in ipairs(batch_promises) do
      p:and_then(function()
        check_batch_complete()
      end):catch(function()
        check_batch_complete()
      end)
    end

    return batch_result_promise
  end

  if #requests == 0 then
    return Promise.new():resolve(results)
  end

  return process_batch(1)
end

---Map a function over items and execute in parallel
---@generic T
---@param items T[] Array of items to process
---@param fn fun(item: T, index: number): BatchRequest Function to create request from item
---@param opts? BatchOptions Batch options
---@return Promise<BatchResult[]>
function OpencodeHeadless:map(items, fn, opts)
  local requests = {}
  for i, item in ipairs(items) do
    requests[i] = fn(item, i)
  end
  return self:batch(requests, opts)
end

return {
  new = OpencodeHeadless.new,
}
