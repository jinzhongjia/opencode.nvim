---@meta

---@class OpencodeHeadlessConfig
---@field model? string Default model to use (e.g., 'anthropic/claude-3-5-sonnet-20241022')
---@field agent? string Default agent to use (e.g., 'plan', 'build')
---@field auto_start_server? boolean Whether to auto-start opencode server (default true)
---@field directory? string Working directory (defaults to current directory)
---@field timeout? number Timeout in milliseconds
---@field retry? RetryConfig|boolean Retry configuration (true for defaults, false to disable)
---@field permission_handler? PermissionHandlerConfig Permission handling configuration

---@class ChatOptions
---@field model? string Override default model
---@field agent? string Override default agent
---@field context? HeadlessContext Context configuration
---@field contexts? HeadlessContext[] Multiple contexts
---@field new_session? boolean Whether to create a new session (default true for chat, false for send_message)
---@field session_id? string Use specified session ID
---@field timeout? number Override default timeout

---@class ChatResponse
---@field text string Complete response text
---@field message OpencodeMessage Raw message object
---@field session_id string Session ID
---@field tool_calls? ToolCallInfo[] Tool calls in this conversation

---@class ChatStreamOptions : ChatOptions
---@field on_data fun(chunk: MessageChunk): nil Callback for incremental data
---@field on_tool_call? fun(tool_call: ToolCallInfo): nil Callback for tool call updates
---@field on_permission? fun(permission: PermissionRequest): PermissionResponse|Promise<PermissionResponse> Callback for permission requests
---@field on_done fun(message: OpencodeMessage): nil Callback when done
---@field on_error fun(error: any): nil Callback for errors
---@field permission_handler? PermissionHandlerConfig Override permission handler for this request

---@class MessageChunk
---@field type string Type of the chunk (e.g., 'text', 'tool', etc.)
---@field text? string Text content (if type is 'text')
---@field part OpencodeMessagePart Complete part data

---@class StreamHandle
---@field abort fun(): Promise<boolean> Abort the streaming response
---@field is_done fun(): boolean Check if the stream is done
---@field get_partial_text fun(): string Get accumulated partial text so far
---@field get_tool_calls fun(): table<string, ToolCallInfo> Get all tool calls
---@field is_ready fun(): boolean Check if handle is ready (session created)

---@class ToolCallInfo
---@field id string Tool call ID
---@field name string Tool name (e.g., 'bash', 'read', 'edit', 'glob', 'grep')
---@field status 'pending'|'running'|'completed'|'failed'|'permission_required' Tool call status
---@field input table Tool input parameters
---@field output? any Tool output result
---@field error? string Error message
---@field permission_id? string Associated permission ID

---@class PermissionRequest
---@field id string Permission ID
---@field session_id string Session ID
---@field message_id string Message ID
---@field tool_name string Tool name (e.g., 'bash', 'edit', 'write')
---@field title string Human-readable title
---@field type string Permission type
---@field pattern table|nil Pattern or arguments

---@alias PermissionResponse 'once'|'always'|'reject'

---@class PermissionRule
---@field pattern string Tool name pattern (supports wildcards like '*')
---@field action PermissionResponse Default action for matching tools
---@field condition? fun(permission: PermissionRequest): boolean Optional condition function

---@class PermissionHandlerConfig
---@field strategy 'auto_approve'|'auto_reject'|'ask'|'callback' Permission handling strategy
---@field rules? PermissionRule[] Permission rules (checked in order)
---@field callback? fun(permission: PermissionRequest): PermissionResponse|Promise<PermissionResponse> Custom callback

---@class RetryConfig
---@field max_attempts? number Maximum number of retry attempts (default: 3)
---@field delay_ms? number Initial delay between retries in ms (default: 1000)
---@field backoff? 'linear'|'exponential' Backoff strategy (default: 'exponential')
---@field max_delay_ms? number Maximum delay between retries (default: 30000)
---@field retryable_errors? string[] Error patterns that trigger retry
---@field on_retry? fun(attempt: number, error: any, delay: number): nil Callback on retry

return {}
