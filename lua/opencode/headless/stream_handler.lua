-- lua/opencode/headless/stream_handler.lua
-- Handles streaming responses for headless API

local Promise = require('opencode.promise')

---@class ToolCallInfo
---@field id string Tool call ID
---@field name string Tool name (e.g., 'bash', 'read', 'edit')
---@field status string Status: 'pending', 'running', 'completed', 'failed'
---@field input table Tool input parameters
---@field output? string Tool output
---@field error? string Error message
---@field permission_id? string Associated permission ID

---@class StreamHandle
---@field private session_id string
---@field private message_id string|nil
---@field private event_manager EventManager
---@field private api_client OpencodeApiClient
---@field private callbacks StreamCallbacksExtended
---@field private permission_handler? PermissionHandler
---@field private partial_text string
---@field private is_completed boolean
---@field private is_aborted boolean
---@field private cleanup_handlers function[]
---@field private tool_calls table<string, ToolCallInfo>
---@field private pending_permissions table<string, boolean>
local StreamHandle = {}
StreamHandle.__index = StreamHandle

---@class StreamCallbacksExtended
---@field on_data fun(chunk: MessageChunk): nil
---@field on_tool_call? fun(tool_call: ToolCallInfo): nil
---@field on_permission? fun(permission: PermissionRequest): PermissionResponse|Promise<PermissionResponse>
---@field on_done fun(message: OpencodeMessage): nil
---@field on_error fun(error: any): nil

---@class MessageChunk
---@field type string
---@field text? string
---@field part OpencodeMessagePart

---Create a new stream handle
---@param session_id string
---@param event_manager EventManager
---@param api_client OpencodeApiClient
---@param callbacks StreamCallbacksExtended
---@param permission_handler? PermissionHandler
---@return StreamHandle
function StreamHandle.new(session_id, event_manager, api_client, callbacks, permission_handler)
  local self = setmetatable({
    session_id = session_id,
    message_id = nil,
    event_manager = event_manager,
    api_client = api_client,
    callbacks = callbacks,
    permission_handler = permission_handler,
    partial_text = '',
    is_completed = false,
    is_aborted = false,
    cleanup_handlers = {},
    tool_calls = {},
    pending_permissions = {},
  }, StreamHandle)

  self:_setup_listeners()

  return self
end

---Internal: Setup event listeners
function StreamHandle:_setup_listeners()
  -- Forward declare to avoid undefined references
  local on_message_updated, on_part_updated, on_session_idle, on_session_error
  local on_permission_updated, on_permission_replied

  -- Listen for the initial message creation (to get message_id)
  on_message_updated = function(data)
    if data.sessionID == self.session_id and data.role == 'assistant' then
      if not self.message_id then
        self.message_id = data.id
      end
    end
  end

  -- Listen for streaming part updates
  on_part_updated = function(data)
    if self.is_completed or self.is_aborted then
      return
    end

    -- Filter by session
    if data.sessionID ~= self.session_id then
      return
    end
    if self.message_id and data.messageID ~= self.message_id then
      return
    end

    local part = data.part
    if not part then
      return
    end

    -- Handle text parts
    if part.type == 'text' and part.text then
      self.partial_text = self.partial_text .. part.text

      -- Call user callback for text data
      if self.callbacks.on_data then
        vim.schedule(function()
          self.callbacks.on_data({
            type = part.type,
            text = part.text,
            part = part,
          })
        end)
      end
    end

    -- Handle tool call parts
    if part.type == 'tool' and part.tool then
      self:_handle_tool_call(part)
    end
  end

  -- Listen for permission requests
  on_permission_updated = function(data)
    if data.sessionID ~= self.session_id then
      return
    end
    if self.is_completed or self.is_aborted then
      return
    end

    -- Mark permission as pending
    self.pending_permissions[data.permissionID] = true

    -- Build permission request object
    local permission_request = {
      id = data.permissionID,
      session_id = self.session_id,
      message_id = data.messageID or self.message_id,
      tool_name = data.type or 'unknown',
      title = data.title or 'Permission Required',
      type = data.type or 'tool',
      pattern = data.pattern,
    }

    -- Handle permission
    self:_handle_permission(permission_request)
  end

  -- Listen for permission replies
  on_permission_replied = function(data)
    if data.sessionID ~= self.session_id then
      return
    end

    -- Remove from pending
    self.pending_permissions[data.permissionID] = nil
  end

  -- Listen for session idle (response complete)
  on_session_idle = function(data)
    if data.sessionID == self.session_id and not self.is_completed and not self.is_aborted then
      self.is_completed = true
      self:_cleanup()

      -- Fetch the final complete message
      if self.message_id then
        self.api_client
          :get_message(self.session_id, self.message_id)
          :and_then(function(message)
            if self.callbacks.on_done then
              vim.schedule(function()
                self.callbacks.on_done(message)
              end)
            end
          end)
          :catch(function(err)
            if self.callbacks.on_error then
              vim.schedule(function()
                self.callbacks.on_error(err)
              end)
            end
          end)
      else
        -- No message received, just call on_done with empty message
        if self.callbacks.on_done then
          vim.schedule(function()
            self.callbacks.on_done({
              parts = {},
              info = { role = 'assistant' },
            })
          end)
        end
      end
    end
  end

  -- Listen for errors
  on_session_error = function(data)
    if data.sessionID == self.session_id and not self.is_completed and not self.is_aborted then
      self.is_completed = true
      self:_cleanup()

      if self.callbacks.on_error then
        vim.schedule(function()
          self.callbacks.on_error(data.error or 'Unknown error')
        end)
      end
    end
  end

  -- Subscribe to events
  self.event_manager:subscribe('message.updated', on_message_updated)
  self.event_manager:subscribe('message.part.updated', on_part_updated)
  self.event_manager:subscribe('permission.updated', on_permission_updated)
  self.event_manager:subscribe('permission.replied', on_permission_replied)
  self.event_manager:subscribe('session.idle', on_session_idle)
  self.event_manager:subscribe('session.error', on_session_error)

  -- Store cleanup handlers
  table.insert(self.cleanup_handlers, function()
    self.event_manager:unsubscribe('message.updated', on_message_updated)
    self.event_manager:unsubscribe('message.part.updated', on_part_updated)
    self.event_manager:unsubscribe('permission.updated', on_permission_updated)
    self.event_manager:unsubscribe('permission.replied', on_permission_replied)
    self.event_manager:unsubscribe('session.idle', on_session_idle)
    self.event_manager:unsubscribe('session.error', on_session_error)
  end)
end

---Internal: Handle tool call updates
---@param part OpencodeMessagePart
function StreamHandle:_handle_tool_call(part)
  local tool_id = part.id or part.callID or 'unknown'
  local tool_name = part.tool or part.name or 'unknown'
  local state = part.state or {}

  -- Build tool call info
  local tool_call = {
    id = tool_id,
    name = tool_name,
    status = state.status or 'unknown',
    input = state.input or {},
    output = state.output,
    error = state.error,
  }

  -- Store/update tool call
  self.tool_calls[tool_id] = tool_call

  -- Call user callback
  if self.callbacks.on_tool_call then
    vim.schedule(function()
      self.callbacks.on_tool_call(tool_call)
    end)
  end
end

---Internal: Handle permission request
---@param permission PermissionRequest
function StreamHandle:_handle_permission(permission)
  -- Try permission handler first
  if self.permission_handler then
    self.permission_handler:handle(permission):and_then(function(response)
      self:_respond_to_permission(permission.id, response)
    end)
    return
  end

  -- Try user callback
  if self.callbacks.on_permission then
    local result = self.callbacks.on_permission(permission)

    -- Handle sync or async response
    if type(result) == 'string' then
      self:_respond_to_permission(permission.id, result)
    elseif type(result) == 'table' and result.and_then then
      -- It's a Promise
      result:and_then(function(response)
        self:_respond_to_permission(permission.id, response)
      end)
    else
      -- Unknown, default to reject
      self:_respond_to_permission(permission.id, 'reject')
    end
    return
  end

  -- No handler, auto-reject
  self:_respond_to_permission(permission.id, 'reject')
end

---Internal: Respond to permission
---@param permission_id string
---@param response PermissionResponse
function StreamHandle:_respond_to_permission(permission_id, response)
  -- Map response to API format
  local approval = response
  if response == 'once' then
    approval = 'allow'
  elseif response == 'always' then
    approval = 'always'
  elseif response == 'reject' then
    approval = 'deny'
  end

  self.api_client:respond_to_permission(self.session_id, permission_id, { approval = approval })
end

---Internal: Cleanup event listeners
function StreamHandle:_cleanup()
  for _, cleanup in ipairs(self.cleanup_handlers) do
    cleanup()
  end
  self.cleanup_handlers = {}
end

---Abort the streaming response
---@return Promise<boolean>
function StreamHandle:abort()
  if self.is_completed or self.is_aborted then
    local p = Promise.new()
    p:resolve(false)
    return p
  end

  self.is_aborted = true
  self:_cleanup()

  return self.api_client:abort_session(self.session_id):and_then(function()
    return true
  end)
end

---Check if the stream is done
---@return boolean
function StreamHandle:is_done()
  return self.is_completed or self.is_aborted
end

---Get the accumulated partial text so far
---@return string
function StreamHandle:get_partial_text()
  return self.partial_text
end

---Get all tool calls so far
---@return table<string, ToolCallInfo>
function StreamHandle:get_tool_calls()
  return self.tool_calls
end

return StreamHandle
