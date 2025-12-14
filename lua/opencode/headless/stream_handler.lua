-- lua/opencode/headless/stream_handler.lua
-- Handles streaming responses for headless API

local Promise = require('opencode.promise')

---@class StreamHandle
---@field private session_id string
---@field private message_id string|nil
---@field private event_manager EventManager
---@field private api_client OpencodeApiClient
---@field private callbacks StreamCallbacks
---@field private partial_text string
---@field private is_completed boolean
---@field private is_aborted boolean
---@field private cleanup_handlers function[]
local StreamHandle = {}
StreamHandle.__index = StreamHandle

---@class StreamCallbacks
---@field on_data fun(chunk: MessageChunk): nil
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
---@param callbacks StreamCallbacks
---@return StreamHandle
function StreamHandle.new(session_id, event_manager, api_client, callbacks)
  local self = setmetatable({
    session_id = session_id,
    message_id = nil,
    event_manager = event_manager,
    api_client = api_client,
    callbacks = callbacks,
    partial_text = '',
    is_completed = false,
    is_aborted = false,
    cleanup_handlers = {},
  }, StreamHandle)

  self:_setup_listeners()

  return self
end

---Internal: Setup event listeners
function StreamHandle:_setup_listeners()
  -- Forward declare to avoid undefined references
  local on_message_updated, on_part_updated, on_session_idle, on_session_error

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

    -- Filter by session and message
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

    -- Extract text from part
    local text = nil
    if part.type == 'text' and part.text then
      text = part.text
      self.partial_text = self.partial_text .. text
    end

    -- Call user callback
    if self.callbacks.on_data then
      vim.schedule(function()
        self.callbacks.on_data({
          type = part.type,
          text = text,
          part = part,
        })
      end)
    end
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
  self.event_manager:subscribe('session.idle', on_session_idle)
  self.event_manager:subscribe('session.error', on_session_error)

  -- Store cleanup handlers
  table.insert(self.cleanup_handlers, function()
    self.event_manager:unsubscribe('message.updated', on_message_updated)
    self.event_manager:unsubscribe('message.part.updated', on_part_updated)
    self.event_manager:unsubscribe('session.idle', on_session_idle)
    self.event_manager:unsubscribe('session.error', on_session_error)
  end)
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

return StreamHandle
