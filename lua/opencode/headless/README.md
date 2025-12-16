# OpenCode Headless API

The OpenCode Headless API provides a fully non-blocking, UI-independent programming interface that allows you to interact with OpenCode AI directly from Lua code.

## Features

✅ **Phase 1 (Implemented)**:
- ✅ Basic single-turn chat (`chat()`)
- ✅ Multi-turn session management (`create_session()`, `send_message()`)
- ✅ Fully non-blocking Promise API
- ✅ Automatic server lifecycle management
- ✅ Event-driven message updates

✅ **Phase 2 (Implemented)**:
- ✅ Streaming responses (`chat_stream()`)
- ✅ StreamHandle with abort/is_done/get_partial_text support

✅ **Phase 3 (Implemented)**:
- ✅ Tool Call support (`on_tool_call` callback)
- ✅ Permission management (`PermissionHandler`)
- ✅ Support for auto_approve/auto_reject/callback strategies
- ✅ Rule-based permission control
- ✅ Safe default configuration (`safe_defaults()`)

✅ **Phase 4 (Implemented)**:
- ✅ Context support (single/multiple)
- ✅ File context (`current_file`, `mentioned_files`)
- ✅ Code selections (`selections`)
- ✅ Diagnostics (`diagnostics`)
- ✅ Subagents (`subagents`)
- ✅ Base64 image support (`images`)

✅ **Phase 5 (Implemented)**:
- ✅ Timeout mechanism (`timeout`)
- ✅ Retry mechanism (`retry`)
- ✅ Batch operations (`batch()`, `map()`)

## Quick Start

### Example 1: Simple Chat

```lua
local headless = require('opencode.headless')

-- Async approach
headless.new():and_then(function(client)
  return client:chat('What is Lua?')
end):and_then(function(response)
  print('Response:', response.text)
end):catch(function(err)
  print('Error:', vim.inspect(err))
end)
```

### Example 2: Multi-turn Conversation

```lua
local headless = require('opencode.headless')
local Promise = require('opencode.promise')

Promise.spawn(function()
  local client = headless.new():await()
  local session = client:create_session():await()
  
  local response1 = client:send_message(session.id, 'What is Neovim?'):await()
  print('Response 1:', response1.text)
  
  local response2 = client:send_message(session.id, 'Can you explain more?'):await()
  print('Response 2:', response2.text)
  
  client:close()
end)
```

### Example 3: Custom Configuration

```lua
local headless = require('opencode.headless')

headless.new({
  model = 'anthropic/claude-3-5-sonnet-20241022',
  agent = 'plan',
  auto_start_server = true,
}):and_then(function(client)
  return client:chat('Help me understand this code')
end):and_then(function(response)
  print(response.text)
end)
```

## API Documentation

### `headless.new(opts?)`

Creates a new headless client instance.

**Parameters:**
- `opts` (optional): Configuration options
  - `model` (string): Default model (e.g., `'anthropic/claude-3-5-sonnet-20241022'`)
  - `agent` (string): Default agent (e.g., `'plan'`, `'build'`)
  - `auto_start_server` (boolean): Whether to auto-start the server (default: `true`)
  - `directory` (string): Working directory (default: current directory)
  - `timeout` (number): Timeout in milliseconds (default: `120000`)
  - `retry` (RetryConfig): Retry configuration (see below)
  - `permission_handler` (PermissionHandlerConfig): Default permission handling configuration
  - `session_cache_ttl` (number): Session cache TTL in milliseconds (default: `300000`, 5 minutes)

**Returns:** `Promise<OpencodeHeadless>`

### `client:chat(message, opts?)`

Sends a single-turn chat message.

**Parameters:**
- `message` (string): The message to send
- `opts` (optional): Chat options
  - `model` (string): Override default model
  - `agent` (string): Override default agent
  - `session_id` (string): Use specified session ID
  - `new_session` (boolean): Whether to create a new session (default: `true`)

**Returns:** `Promise<ChatResponse>`

Response object contains:
- `text` (string): Complete response text
- `message` (OpencodeMessage): Raw message object
- `session_id` (string): Session ID

### `client:create_session(opts?)`

Creates a new session.

**Parameters:**
- `opts` (optional): Session options
  - `title` (string): Session title
  - `model` (string): Model
  - `agent` (string): Agent

**Returns:** `Promise<HeadlessSession>`

### `client:send_message(session_id, message, opts?)`

Sends a message to a specified session.

**Parameters:**
- `session_id` (string): Session ID
- `message` (string): The message to send
- `opts` (optional): Same options as `chat()`

**Returns:** `Promise<ChatResponse>`

### `client:get_session(session_id)`

Gets a specified session.

**Parameters:**
- `session_id` (string): Session ID

**Returns:** `Promise<HeadlessSession|nil>`

### `client:list_sessions()`

Lists all active sessions.

**Returns:** `Promise<HeadlessSession[]>`

### `client:abort(session_id?)`

Aborts a session.

**Parameters:**
- `session_id` (optional): Session ID (if not provided, aborts all sessions)

**Returns:** `Promise<boolean>`

### `client:chat_stream(message, opts)`

Sends a message and receives streaming response.

**Parameters:**
- `message` (string): The message to send
- `opts` (ChatStreamOptions): Streaming options
  - `on_data` (function): Callback for incremental data `fun(chunk: MessageChunk): nil`
  - `on_tool_call` (function, optional): Callback for tool call updates `fun(tool_call: ToolCallInfo): nil`
  - `on_permission` (function, optional): Callback for permission requests `fun(permission: PermissionRequest): PermissionResponse|Promise`
  - `on_done` (function): Completion callback `fun(message: OpencodeMessage): nil`
  - `on_error` (function): Error callback `fun(error: any): nil`
  - `permission_handler` (PermissionHandlerConfig, optional): Override default permission handler
  - Other options same as `chat()`

**Returns:** `StreamHandle`

StreamHandle object contains:
- `abort()`: Abort streaming response, returns `Promise<boolean>`
- `is_done()`: Check if complete, returns `boolean`
- `is_ready()`: Check if handle is ready (session created, streaming started), returns `boolean`
- `get_partial_text()`: Get current accumulated text, returns `string`
- `get_tool_calls()`: Get all tool calls so far, returns `table<string, ToolCallInfo>`

**Example:**
```lua
local handle = client:chat_stream('Write a story', {
  on_data = function(chunk)
    if chunk.text then
      io.write(chunk.text)  -- Real-time output
    end
  end,
  on_done = function(message)
    print('Done!')
  end,
  on_error = function(err)
    print('Error:', err)
  end,
})

-- Can cancel midway
handle:abort()
```

### `client:close()`

Closes the client and cleans up resources. Note: This does not close the server, as it may be used by other clients.

## Tool Call Support

### Tool Call Callback

Use the `on_tool_call` callback in `chat_stream()` to receive tool call status updates:

```lua
local handle = client:chat_stream('Read README.md', {
  on_data = function(chunk) ... end,
  on_tool_call = function(tool_call)
    -- tool_call contains:
    -- - id: Tool call ID
    -- - name: Tool name (e.g., 'bash', 'read', 'edit')
    -- - status: Status ('pending', 'running', 'completed', 'failed')
    -- - input: Input parameters
    -- - output: Output result (after completion)
    -- - error: Error message (on failure)
    print(tool_call.name, tool_call.status)
  end,
  on_done = function(message) ... end,
  on_error = function(err) ... end,
})

-- Get all tool calls
local all_tool_calls = handle:get_tool_calls()
```

### Permission Handling

When AI needs to execute tools, permission requests must be handled. There are three approaches:

#### 1. Using PermissionHandler

```lua
local permission_handler = require('opencode.headless.permission_handler')

-- Auto-approve all tool calls
local handle = client:chat_stream('message', {
  permission_handler = permission_handler.auto_approve(),
  ...
})

-- Auto-reject all tool calls
local handle = client:chat_stream('message', {
  permission_handler = permission_handler.auto_reject(),
  ...
})

-- Use safe defaults
-- read/glob/grep/list: always allowed
-- bash/edit/write: requires approval per call
-- unknown tools: rejected
local handle = client:chat_stream('message', {
  permission_handler = permission_handler.safe_defaults(),
  ...
})
```

#### 2. Custom Rules

```lua
local handler = permission_handler.new({
  strategy = 'auto_reject',  -- Default strategy
  rules = {
    -- Always allow read operations
    { pattern = 'read', action = 'always' },
    { pattern = 'glob', action = 'always' },
    
    -- Only allow specific bash commands
    {
      pattern = 'bash',
      action = 'once',
      condition = function(perm)
        local cmd = perm.pattern and perm.pattern.command or ''
        return cmd:match('^echo') or cmd:match('^cat')
      end,
    },
    
    -- Reject other bash commands
    { pattern = 'bash', action = 'reject' },
  },
})
```

#### 3. Using on_permission Callback

```lua
local Promise = require('opencode.promise')

local handle = client:chat_stream('message', {
  on_permission = function(permission)
    -- permission contains:
    -- - id: Permission request ID
    -- - tool_name: Tool name
    -- - title: Human-readable title
    -- - pattern: Tool parameters
    
    -- Synchronous return
    if permission.tool_name == 'read' then
      return 'always'  -- Always allow
    end
    
    -- Asynchronous return (e.g., show UI prompt)
    local promise = Promise.new()
    vim.defer_fn(function()
      -- 'once': Allow this time
      -- 'always': Always allow
      -- 'reject': Reject
      promise:resolve('once')
    end, 100)
    return promise
  end,
  ...
})
```

### PermissionResponse Types

- `'once'`: Allow this call
- `'always'`: Always allow this tool
- `'reject'`: Reject this call

## Context Support

The Headless API supports explicitly passing context information, including files, code selections, diagnostics, etc.

### Single Context

```lua
headless:chat('explain this code', {
  context = {
    -- Current file (string or HeadlessFileInfo)
    current_file = '/path/to/main.lua',
    
    -- Additional mentioned files
    mentioned_files = {
      '/path/to/utils.lua',
      '/path/to/config.lua',
    },
    
    -- Code selections
    selections = {
      {
        content = 'local x = 1\nlocal y = 2',
        lines = '10, 11',
        file = '/path/to/file.lua', -- Optional, defaults to current_file
      },
    },
    
    -- Diagnostics
    diagnostics = {
      { message = 'unused variable', severity = 2, lnum = 10, col = 5 },
    },
    
    -- Subagents
    subagents = { 'plan' },
  },
})
```

### Multiple Contexts

For scenarios requiring analysis of multiple files, use the `contexts` array:

```lua
headless:chat('compare these implementations', {
  contexts = {
    {
      current_file = '/path/to/impl_a.lua',
      selections = {
        { content = 'function foo() ... end', lines = '1, 10' },
      },
    },
    {
      current_file = '/path/to/impl_b.lua',
      selections = {
        { content = 'function foo() ... end', lines = '1, 15' },
      },
    },
  },
})
```

### Combined with Streaming

```lua
local handle = client:chat_stream('review and fix', {
  context = {
    current_file = vim.fn.expand('%:p'),
    diagnostics = vim.diagnostic.get(0),
  },
  permission_handler = permission_handler.safe_defaults(),
  on_data = function(chunk) ... end,
  on_done = function(message) ... end,
})
```

### Image Support

Supports passing Base64-encoded images to AI for analysis:

```lua
-- Single image
headless:chat('describe this image', {
  context = {
    images = {
      { data = 'base64_encoded_image_data', format = 'png' },
    },
  },
})

-- Multiple images + code context
headless:chat('compare screenshots and fix the UI bug', {
  context = {
    current_file = '/path/to/component.tsx',
    images = {
      { data = 'before_screenshot_base64', format = 'png' },
      { data = 'after_screenshot_base64', format = 'png' },
    },
  },
})
```

**Reading image files and converting to Base64:**

```lua
local function read_image_as_base64(path)
  local file = io.open(path, 'rb')
  if not file then return nil end
  local data = file:read('*all')
  file:close()
  return vim.base64.encode(data)
end

local image_data = read_image_as_base64('/path/to/screenshot.png')
```

### Context Type Definitions

```lua
---@class HeadlessContext
---@field current_file? string|HeadlessFileInfo Current file
---@field mentioned_files? string[] Mentioned file paths
---@field selections? HeadlessSelection[] Code selections
---@field diagnostics? HeadlessDiagnostic[] Diagnostics
---@field subagents? string[] Subagents
---@field images? HeadlessImage[] Base64-encoded images

---@class HeadlessFileInfo
---@field path string Full file path
---@field name? string File name (auto-inferred)
---@field extension? string Extension (auto-inferred)

---@class HeadlessSelection
---@field content string Code content
---@field lines? string Line range "start, end"
---@field file? string|HeadlessFileInfo Associated file

---@class HeadlessDiagnostic
---@field message string Diagnostic message
---@field severity? number Severity level
---@field lnum? number Line number (0-based)
---@field col? number Column number (0-based)

---@class HeadlessImage
---@field data string Base64-encoded image data
---@field format? string Image format: 'png'|'jpeg'|'gif'|'webp' (default: 'png')
```

## Timeout and Retry

### Timeout Mechanism

Timeout can be set globally when creating the client, or overridden per request:

```lua
-- Global timeout setting
local client = headless.new({
  timeout = 60000,  -- 60 seconds
}):await()

-- Per-request timeout
client:chat('message', {
  timeout = 30000,  -- 30 seconds
})
```

### Retry Mechanism

The Headless API supports automatic retry for failed requests. Configurable with exponential or linear backoff:

```lua
local client = headless.new({
  retry = {
    max_attempts = 3,         -- Maximum retry attempts (default: 3)
    delay_ms = 1000,          -- Initial delay in milliseconds (default: 1000)
    backoff = 'exponential',  -- Backoff strategy: 'exponential' | 'linear' (default: 'exponential')
    max_delay_ms = 30000,     -- Maximum delay in milliseconds (default: 30000)
    jitter = true,            -- Whether to add random jitter (default: true)
    retryable_errors = {      -- Retryable error patterns
      'timeout', 'ETIMEDOUT', 'ECONNRESET',
      'rate_limit', '429', '502', '503', '504',
    },
    on_retry = function(attempt, err, delay)
      print(string.format('Retry #%d after %dms: %s', attempt, delay, err))
    end,
  },
}):await()
```

### RetryConfig Type

```lua
---@class RetryConfig
---@field max_attempts? number Maximum retry attempts (default: 3)
---@field delay_ms? number Initial delay in milliseconds (default: 1000)
---@field backoff? 'exponential'|'linear' Backoff strategy (default: 'exponential')
---@field max_delay_ms? number Maximum delay in milliseconds (default: 30000)
---@field jitter? boolean Whether to add random jitter (default: true)
---@field retryable_errors? string[] Retryable error patterns
---@field on_retry? fun(attempt: number, err: any, delay: number) Retry callback
```

## Batch Operations

### `client:batch(requests, opts?)`

Execute multiple chat requests in parallel:

```lua
local results = client:batch({
  { message = 'Review file1.lua', context = { mentioned_files = {'file1.lua'} } },
  { message = 'Review file2.lua', context = { mentioned_files = {'file2.lua'} } },
  { message = 'Review file3.lua', context = { mentioned_files = {'file3.lua'} } },
}, {
  max_concurrent = 3,  -- Maximum concurrency (default: 5)
  fail_fast = false,   -- Stop on first error (default: false)
}):await()

for i, result in ipairs(results) do
  if result.success then
    print('Request', i, 'succeeded:', result.response.text:sub(1, 50))
  else
    print('Request', i, 'failed:', result.error)
  end
end
```

**With `fail_fast = true`:**

```lua
client:batch(requests, { fail_fast = true })
  :and_then(function(results)
    print('All succeeded!')
  end)
  :catch(function(err)
    -- err contains: { error, partial_results, completed_count }
    print('Failed at request', err.completed_count, ':', err.error)
  end)
```

### `client:map(items, fn, opts?)`

Execute requests in parallel for each item in an array:

```lua
local files = { 'a.lua', 'b.lua', 'c.lua' }

local results = client:map(files, function(file)
  return {
    message = 'Review this file for bugs',
    context = { mentioned_files = { file } },
  }
end, {
  max_concurrent = 2,
}):await()

for i, result in ipairs(results) do
  print(files[i], ':', result.success and 'OK' or result.error)
end
```

### BatchResult Type

```lua
---@class BatchResult
---@field success boolean Whether successful
---@field response? ChatResponse Response on success
---@field error? any Error on failure
---@field index number Original request index
```

## Example File

See `lua/opencode/headless/example.lua` for more usage examples:

```lua
-- Run examples in Neovim:
:lua require('opencode.headless.example').simple_chat()
:lua require('opencode.headless.example').multi_turn()
:lua require('opencode.headless.example').with_options()
:lua require('opencode.headless.example').with_spawn()
:lua require('opencode.headless.example').streaming()
:lua require('opencode.headless.example').tool_calls_auto()
:lua require('opencode.headless.example').tool_calls_safe()
:lua require('opencode.headless.example').tool_calls_custom()
:lua require('opencode.headless.example').tool_calls_rules()
:lua require('opencode.headless.example').context_single()
:lua require('opencode.headless.example').context_multiple()
:lua require('opencode.headless.example').context_streaming()
:lua require('opencode.headless.example').with_images()
:lua require('opencode.headless.example').with_multiple_images()
:lua require('opencode.headless.example').image_streaming()
:lua require('opencode.headless.example').with_retry()
:lua require('opencode.headless.example').with_timeout()
:lua require('opencode.headless.example').batch_requests()
:lua require('opencode.headless.example').map_files()
```

## Design Principles

1. **Fully Non-blocking**: All APIs return Promises, never blocking the Neovim main loop
2. **Event-driven**: Reactive updates based on EventManager
3. **Code Reuse**: Leverages existing api_client, promise, event_manager, session (utility functions) modules
4. **UI Independent**: Does not depend on any UI components, can be used in any Lua script
5. **Minimize Duplication**: Uses utility functions from the existing `opencode.session` module instead of reimplementing

## Implementation Status

**Phase 1 (✅ Completed):**
- ✅ Single-turn chat (`chat()`)
- ✅ Multi-turn sessions (`create_session()`, `send_message()`)
- ✅ Non-blocking Promise API
- ✅ Session management
- ✅ Event subscription

**Phase 2 (✅ Completed):**
- ✅ Streaming responses (`chat_stream()`)
- ✅ StreamHandle (abort/is_done/get_partial_text)
- ✅ Real-time incremental data reception

**Phase 3 (✅ Completed):**
- ✅ Tool Call support (`on_tool_call` callback)
- ✅ PermissionHandler (auto_approve/auto_reject/callback)
- ✅ Rule-based permission control
- ✅ Safe default configuration (`safe_defaults()`)

**Phase 4 (✅ Completed):**
- ✅ Context support (single/multiple)
- ✅ File, selection, diagnostics, subagent context
- ✅ Base64 image support

**Phase 5 (✅ Completed):**
- ✅ Timeout mechanism (`timeout`)
- ✅ Retry mechanism (`retry`)
- ✅ Batch operations (`batch()`, `map()`)

## Important Notes

1. **Non-blocking Requirement**: Do not use `:wait()` to synchronously wait for results, as this will block Neovim
2. **Use Promise.spawn**: If you need to execute multiple async operations sequentially, use `Promise.spawn` with `:await()`
3. **Resource Cleanup**: Call `client:close()` to clean up resources when done
4. **Server Management**: The Headless API will auto-start the server but will not auto-close it

## Troubleshooting

If you encounter issues:

1. Ensure the OpenCode server is running properly
2. Check `:messages` for error messages
3. Enable debug mode for detailed logs
4. Refer to example code in example.lua

## Contributing

Contributions welcome! Please refer to the main project's AGENTS.md for code standards and testing requirements.
