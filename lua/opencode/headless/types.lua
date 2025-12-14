---@meta

---@class OpencodeHeadlessConfig
---@field model? string Default model to use (e.g., 'anthropic/claude-3-5-sonnet-20241022')
---@field agent? string Default agent to use (e.g., 'plan', 'build')
---@field auto_start_server? boolean Whether to auto-start opencode server (default true)
---@field directory? string Working directory (defaults to current directory)
---@field timeout? number Timeout in milliseconds

---@class ChatOptions
---@field model? string Override default model
---@field agent? string Override default agent
---@field context? OpencodeContextConfig Context configuration
---@field new_session? boolean Whether to create a new session (default true for chat, false for send_message)
---@field session_id? string Use specified session ID

---@class ChatResponse
---@field text string Complete response text
---@field message OpencodeMessage Raw message object
---@field session_id string Session ID

---@class ChatStreamOptions : ChatOptions
---@field on_data fun(chunk: MessageChunk): nil Callback for incremental data
---@field on_done fun(message: OpencodeMessage): nil Callback when done
---@field on_error fun(error: any): nil Callback for errors

---@class MessageChunk
---@field type string Type of the chunk (e.g., 'text', 'tool', etc.)
---@field text? string Text content (if type is 'text')
---@field part OpencodeMessagePart Complete part data

---@class StreamHandle
---@field abort fun(): Promise<boolean> Abort the streaming response
---@field is_done fun(): boolean Check if the stream is done
---@field get_partial_text fun(): string Get accumulated partial text so far

return {}
