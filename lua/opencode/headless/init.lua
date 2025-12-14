local Promise = require('opencode.promise')
local api_client_module = require('opencode.api_client')
local EventManager = require('opencode.event_manager')
local session_utils = require('opencode.session')
local server_job = require('opencode.server_job')

---@class OpencodeHeadless
---@field private config OpencodeHeadlessConfig
---@field private api_client OpencodeApiClient
---@field private event_manager EventManager
---@field private active_sessions table<string, Session>
---@field private server OpencodeServer|nil
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
  }

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

      local instance = setmetatable({
        config = config,
        api_client = api_client,
        event_manager = event_manager,
        active_sessions = {}, -- Track sessions we're using
        server = server,
      }, OpencodeHeadless)

      promise:resolve(instance)
    end)
    :catch(function(err)
      promise:reject('Failed to start headless client: ' .. vim.inspect(err))
    end)

  return promise
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
    self.active_sessions[session.id] = session
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
    local session = self.active_sessions[opts.session_id]
    if session then
      session_promise = Promise.new():resolve(session)
    else
      -- Try to get from API
      session_promise = self.api_client:get_session(opts.session_id):and_then(function(s)
        self.active_sessions[opts.session_id] = s
        return s
      end)
    end
  elseif opts.new_session == false then
    -- Try to use an existing active session
    local session_id = next(self.active_sessions)
    if session_id then
      session_promise = Promise.new():resolve(self.active_sessions[session_id])
    else
      -- No existing session, create new one
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

  -- Get the session (from cache or API)
  local session = self.active_sessions[session_id]
  if not session then
    return Promise.new():reject('Session not found: ' .. session_id)
  end

  -- Build message parts
  local parts = {}

  -- Add context if provided
  if opts.context then
    -- TODO: Use context.format_message from context.lua
    -- For now, just add the message as text
    table.insert(parts, {
      type = 'text',
      text = message,
    })
  else
    table.insert(parts, {
      type = 'text',
      text = message,
    })
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

  -- Send the message and wait for response
  return self:_send_and_wait_for_response(session_id, message_data)
end

---Internal: Send message and wait for response
---@param session_id string
---@param message_data table
---@return Promise<ChatResponse>
function OpencodeHeadless:_send_and_wait_for_response(session_id, message_data)
  local promise = Promise.new()
  local assistant_message_id = nil

  -- Forward declare handlers to avoid undefined references
  local on_message_updated, on_session_idle, on_session_error

  -- Define error handler
  on_session_error = function(data)
    if data.sessionID == session_id then
      -- Unsubscribe from events
      self.event_manager:unsubscribe('message.updated', on_message_updated)
      self.event_manager:unsubscribe('session.idle', on_session_idle)
      self.event_manager:unsubscribe('session.error', on_session_error)

      promise:reject(data.error)
    end
  end

  -- Listen for message updates for this session
  on_message_updated = function(data)
    if data.info.sessionID == session_id and data.info.role == 'assistant' then
      -- Store the assistant message ID
      assistant_message_id = data.info.id
    end
  end

  -- Listen for session idle (means response is complete)
  on_session_idle = function(data)
    if data.sessionID == session_id then
      -- Unsubscribe from events
      self.event_manager:unsubscribe('message.updated', on_message_updated)
      self.event_manager:unsubscribe('session.idle', on_session_idle)
      self.event_manager:unsubscribe('session.error', on_session_error)

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
    -- Unsubscribe from events on error
    self.event_manager:unsubscribe('message.updated', on_message_updated)
    self.event_manager:unsubscribe('session.idle', on_session_idle)
    self.event_manager:unsubscribe('session.error', on_session_error)

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
    self.active_sessions[session.id] = session
    return session
  end)
end

---Get a session by ID
---@param session_id string
---@return Promise<Session|nil>
function OpencodeHeadless:get_session(session_id)
  -- Check cache first
  local session = self.active_sessions[session_id]
  if session then
    return Promise.new():resolve(session)
  end

  -- Fetch from API using existing session utilities
  return session_utils.get_by_id(session_id):and_then(function(s)
    if s then
      self.active_sessions[session_id] = s
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
  else
    -- Abort all active sessions
    local promises = {}
    for sid, _ in pairs(self.active_sessions) do
      table.insert(promises, self.api_client:abort_session(sid))
    end
    return Promise.new():resolve(true) -- For now, just resolve
  end
end

---Send a streaming chat message
---@param message string The message to send
---@param opts ChatStreamOptions Stream options with callbacks
---@return StreamHandle
function OpencodeHeadless:chat_stream(message, opts)
  local StreamHandle = require('opencode.headless.stream_handler')
  
  opts = opts or {}
  
  -- Use existing session or create new one
  local session_promise
  if opts.session_id then
    local session = self.active_sessions[opts.session_id]
    if session then
      session_promise = Promise.new():resolve(session)
    else
      -- Try to get from API
      session_promise = self.api_client:get_session(opts.session_id):and_then(function(s)
        self.active_sessions[opts.session_id] = s
        return s
      end)
    end
  elseif opts.new_session == false then
    -- Try to use an existing active session
    local session_id = next(self.active_sessions)
    if session_id then
      session_promise = Promise.new():resolve(self.active_sessions[session_id])
    else
      -- No existing session, create new one
      session_promise = self:_create_new_session(opts.model or self.config.model, opts.agent or self.config.agent)
    end
  else
    -- Create new session (default behavior)
    session_promise = self:_create_new_session(opts.model or self.config.model, opts.agent or self.config.agent)
  end
  
  -- Create stream handle first (to return immediately)
  local stream_handle = nil
  
  -- Start the streaming process
  session_promise
    :and_then(function(session)
      -- Create callbacks wrapper
      local callbacks = {
        on_data = opts.on_data or function() end,
        on_done = opts.on_done or function() end,
        on_error = opts.on_error or function() end,
      }
      
      -- Create stream handle
      stream_handle = StreamHandle.new(session.id, self.event_manager, self.api_client, callbacks)
      
      -- Build message parts
      local parts = {}
      if opts.context then
        -- TODO: Use context.format_message from context.lua
        table.insert(parts, {
          type = 'text',
          text = message,
        })
      else
        table.insert(parts, {
          type = 'text',
          text = message,
        })
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
      -- If stream handle exists, call error callback
      if stream_handle and opts.on_error then
        vim.schedule(function()
          opts.on_error(err)
        end)
      end
    end)
  
  -- Return a placeholder stream handle that will be replaced
  -- We need to return something immediately, so we create a dummy handle
  local dummy_handle = {
    abort = function()
      return Promise.new():resolve(false)
    end,
    is_done = function()
      return true
    end,
    get_partial_text = function()
      return ''
    end,
    get_tool_calls = function()
      return {}
    end,
  }

  -- Replace with real handle once created
  session_promise:and_then(function()
    if stream_handle then
      dummy_handle.abort = function()
        return stream_handle:abort()
      end
      dummy_handle.is_done = function()
        return stream_handle:is_done()
      end
      dummy_handle.get_partial_text = function()
        return stream_handle:get_partial_text()
      end
      dummy_handle.get_tool_calls = function()
        return stream_handle:get_tool_calls()
      end
    end
  end)
  
  return dummy_handle
end

---Close the headless client and cleanup resources
function OpencodeHeadless:close()
  -- Stop event manager
  if self.event_manager then
    self.event_manager:stop()
  end

  -- Clear active sessions cache
  self.active_sessions = {}

  -- Note: We don't shutdown the server here as it might be used by other clients
  -- If you want to shutdown the server, call server:shutdown() explicitly
end

return {
  new = OpencodeHeadless.new,
}
