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
---@field private text_parts table<string, string> Track text content by part ID
---@field private text_parts_order string[] Track order of text parts
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
    text_parts = {},
    text_parts_order = {},
    pending_parts = {}, -- Queue for parts received before message_id is known
  }, StreamHandle)

  self:_setup_listeners()

  return self
end

---Internal: Process a single part update
---@param part OpencodeMessagePart
---@private
function StreamHandle:_process_part(part)
  -- Handle text parts
  if part.type == 'text' and part.text then
    -- Track text by part ID to handle updates correctly
    -- Events send complete part content, not incremental deltas
    local part_id = part.id or 'default_text'
    local prev_text = self.text_parts[part_id] or ''
    local is_new_part = (prev_text == '')

    self.text_parts[part_id] = part.text

    -- Track order of parts (only add if new)
    if is_new_part then
      table.insert(self.text_parts_order, part_id)
    end

    -- Calculate the delta (new text that was added)
    local delta_text = ''
    if #part.text > #prev_text then
      delta_text = part.text:sub(#prev_text + 1)
    elseif part.text ~= prev_text then
      -- Text was replaced entirely, use the full new text
      delta_text = part.text
    end

    -- Update partial_text by reconstructing from all text parts (in order)
    self.partial_text = ''
    for _, pid in ipairs(self.text_parts_order) do
      self.partial_text = self.partial_text .. (self.text_parts[pid] or '')
    end

    -- Call user callback for text data (with delta)
    if self.callbacks.on_data and delta_text ~= '' then
      vim.schedule(function()
        self.callbacks.on_data({
          type = part.type,
          text = delta_text,
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

---Internal: Process all pending parts that match our message_id
---@private
function StreamHandle:_process_pending_parts()
  if not self.message_id then
    return
  end

  local remaining = {}
  for _, part in ipairs(self.pending_parts) do
    if part.messageID == self.message_id then
      self:_process_part(part)
    else
      -- Keep parts that don't match (shouldn't happen, but be safe)
      table.insert(remaining, part)
    end
  end
  self.pending_parts = remaining
end

---Internal: Setup event listeners
function StreamHandle:_setup_listeners()
  -- Forward declare to avoid undefined references
  local on_message_updated, on_part_updated, on_session_idle, on_session_error
  local on_permission_updated, on_permission_replied

  -- Listen for the initial message creation (to get message_id)
  on_message_updated = function(data)
    -- data is EventMessageUpdated.properties = {info: MessageInfo}
    if data.info and data.info.sessionID == self.session_id and data.info.role == 'assistant' then
      if not self.message_id then
        self.message_id = data.info.id
        -- Process any parts that were queued while waiting for message_id
        self:_process_pending_parts()
      end
    end
  end

  -- Listen for streaming part updates
  on_part_updated = function(data)
    if self.is_completed or self.is_aborted then
      return
    end

    -- data is EventMessagePartUpdated.properties = {part: OpencodeMessagePart}
    local part = data.part
    if not part then
      return
    end

    -- Filter by session
    if part.sessionID ~= self.session_id then
      return
    end

    -- If we don't know our message_id yet, try to infer it from the part
    if not self.message_id then
      if part.messageID then
        -- Use the first part's messageID as our message_id
        self.message_id = part.messageID
        -- Process any pending parts now that we know the message_id
        self:_process_pending_parts()
      end
      -- Even if messageID is nil, process the part (for backward compatibility)
      -- This handles cases where parts don't have messageID set
    elseif part.messageID and part.messageID ~= self.message_id then
      -- If we have a message_id and part has a different one, skip it
      return
    end

    -- Process the part
    self:_process_part(part)
  end

  -- Listen for permission requests
  -- data is EventPermissionUpdated.properties = OpencodePermission
  on_permission_updated = function(data)
    if data.sessionID ~= self.session_id then
      return
    end
    if self.is_completed or self.is_aborted then
      return
    end

    -- Mark permission as pending (OpencodePermission uses 'id' field)
    self.pending_permissions[data.id] = true

    -- Build permission request object
    local permission_request = {
      id = data.id,
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
    self.permission_handler:handle(permission)
      :and_then(function(response)
        self:_respond_to_permission(permission.id, response)
      end)
      :catch(function()
        -- On error, default to reject
        self:_respond_to_permission(permission.id, 'reject')
      end)
    return
  end

  -- Try user callback
  if self.callbacks.on_permission then
    local ok, result = pcall(self.callbacks.on_permission, permission)

    if not ok then
      -- Callback threw an error, default to reject
      self:_respond_to_permission(permission.id, 'reject')
      return
    end

    -- Handle sync or async response
    if type(result) == 'string' then
      self:_respond_to_permission(permission.id, result)
    elseif type(result) == 'table' and result.and_then then
      -- It's a Promise
      result
        :and_then(function(response)
          self:_respond_to_permission(permission.id, response)
        end)
        :catch(function()
          -- On error, default to reject
          self:_respond_to_permission(permission.id, 'reject')
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
    return Promise.new():resolve(false)
  end

  self.is_aborted = true
  self:_cleanup()

  return self.api_client:abort_session(self.session_id)
    :and_then(function()
      return true
    end)
    :catch(function()
      -- Abort failed, but we've already cleaned up locally
      return false
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
