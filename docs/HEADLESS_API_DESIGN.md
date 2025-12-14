# Headless API Design Document

> Complete Headless API design document for the opencode.nvim project

## Table of Contents

- [1. Core Design Philosophy](#1-core-design-philosophy)
- [2. Module Naming](#2-module-naming)
- [3. Architecture Design](#3-architecture-design)
- [4. Detailed API Design](#4-detailed-api-design)
- [5. Tool Call Support](#5-tool-call-support)
- [6. Non-blocking Design](#6-non-blocking-design)
- [7. Implementation Notes](#7-implementation-notes)
- [8. Usage Scenarios](#8-usage-scenarios)
- [9. Relationship with Existing Architecture](#9-relationship-with-existing-architecture)
- [10. Implementation Priority](#10-implementation-priority)
- [11. Potential Challenges and Solutions](#11-potential-challenges-and-solutions)
- [12. Summary](#12-summary)

---

## 1. Core Design Philosophy

Based on analysis of the existing code, the current project is a highly integrated Neovim UI plugin. The core approach for designing the headless API is:

1. **Decouple UI from Core Logic**: Extract business logic from the existing `core.lua`
2. **Maintain Event-driven Architecture**: Continue using `EventManager` and `state` event subscription mechanisms
3. **Unified API Client**: Reuse the existing `api_client.lua`, which already encapsulates communication with the opencode server
4. **Support Multiple Usage Modes**: Single-turn chat, multi-turn sessions, streaming responses
5. **Fully Non-blocking**: All API calls must be asynchronous, never blocking the Neovim main loop
6. **Tool Call Support**: Support for tool calls and permission management

---

## 2. Module Naming

### Recommended: `opencode.headless`

**Rationale:**
- `headless` clearly expresses the "no UI" characteristic
- `client` follows common programming conventions (similar to LSP client)
- Better distinguishes from the existing UI mode

---

## 3. Architecture Design

### File Structure

```
lua/opencode/headless/
├── init.lua              -- Main entry point, provides unified API
├── session_manager.lua   -- Session management (supports multi-turn conversations)
├── chat.lua              -- Chat interface (single-turn, multi-turn)
├── stream_handler.lua    -- Streaming response handling
├── tool_handler.lua      -- Tool call handling and permission management
└── types.lua             -- Type definitions
```

### Module Responsibilities

| Module | Responsibility |
|--------|----------------|
| `init.lua` | Provides public API, initializes headless instance |
| `session_manager.lua` | Manages session lifecycle, tracks message history |
| `chat.lua` | Encapsulates chat logic, handles requests and responses |
| `stream_handler.lua` | Handles streaming responses, event filtering and dispatch |
| `tool_handler.lua` | Handles tool calls, permission requests and responses |
| `types.lua` | LuaCATS type definitions |

---

## 4. Detailed API Design

### 4.1 Core Interface (`lua/opencode/headless/init.lua`)

```lua
---@class OpencodeHeadless
---@field new fun(opts?: OpencodeHeadlessConfig): OpencodeHeadless
---@field chat fun(self: OpencodeHeadless, message: string, opts?: ChatOptions): Promise<ChatResponse>
---@field chat_stream fun(self: OpencodeHeadless, message: string, opts?: ChatStreamOptions): StreamHandle
---@field create_session fun(self: OpencodeHeadless, opts?: SessionOptions): Promise<Session>
---@field send_message fun(self: OpencodeHeadless, session_id: string, message: string, opts?: MessageOptions): Promise<OpencodeMessage>
---@field get_session fun(self: OpencodeHeadless, session_id: string): Promise<Session>
---@field list_sessions fun(self: OpencodeHeadless): Promise<Session[]>
---@field abort fun(self: OpencodeHeadless, session_id?: string): Promise<boolean>
---@field close fun(self: OpencodeHeadless): void
```

#### Usage Example

```lua
local headless = require('opencode.headless').new({
  model = 'anthropic/claude-3-5-sonnet-20241022',
  agent = 'plan',
})

-- Single-turn chat (async, non-blocking)
headless:chat('explain this code'):and_then(function(response)
  print(response.text)
end)

-- Multi-turn conversation
headless:create_session():and_then(function(session)
  return headless:send_message(session.id, 'what is lua?')
end):and_then(function(response)
  print(response.text)
end)

-- Streaming response (fully non-blocking)
local handle = headless:chat_stream('write a hello world', {
  on_data = function(chunk)
    print(chunk.text)
  end,
  on_tool_call = function(tool_call)
    print('Tool called:', tool_call.name)
  end,
  on_permission = function(permission)
    -- Auto-handle or notify user
    return 'once' -- 'once' | 'always' | 'reject'
  end,
  on_done = function(final_message)
    print('Done!')
  end,
  on_error = function(err)
    print('Error:', err)
  end
})
```

### 4.2 Configuration Options

```lua
---@class OpencodeHeadlessConfig
---@field model? string Default model (e.g., 'anthropic/claude-3-5-sonnet-20241022')
---@field agent? string Default agent (e.g., 'plan', 'build')
---@field auto_start_server? boolean Whether to auto-start opencode server (default true)
---@field directory? string Working directory (default: current directory)
---@field timeout? number Timeout in milliseconds
---@field permission_handler? PermissionHandler Permission handling strategy
---@field tool_config? ToolConfig Tool configuration

---@class ChatOptions
---@field model? string Override default model
---@field agent? string Override default agent
---@field context? OpencodeContextConfig Context configuration
---@field new_session? boolean Whether to create new session (default true for chat, false for send_message)
---@field session_id? string Use specified session ID
---@field tools? table<string, boolean> Enable/disable specific tools

---@class ChatStreamOptions : ChatOptions
---@field on_data fun(chunk: MessageChunk): void Receive incremental data
---@field on_tool_call? fun(tool_call: ToolCallInfo): void Tool call callback
---@field on_permission? fun(permission: OpencodePermission): PermissionResponse Permission request callback
---@field on_done fun(message: OpencodeMessage): void Completion callback
---@field on_error fun(error: any): void Error callback

---@alias PermissionResponse 'once'|'always'|'reject'

---@class MessageChunk
---@field type string 'text'|'tool'|'patch' etc.
---@field text? string Text content
---@field part OpencodeMessagePart Complete part data

---@class ChatResponse
---@field text string Complete response text
---@field message OpencodeMessage Raw message object
---@field session_id string Session ID
---@field tool_calls? ToolCallInfo[] Tool calls in this conversation
```

### 4.3 Session Management (`lua/opencode/headless/session_manager.lua`)

```lua
---@class HeadlessSessionManager
---@field private api_client OpencodeApiClient
---@field private event_manager EventManager
---@field private sessions table<string, HeadlessSession>

---@class HeadlessSession
---@field id string
---@field messages OpencodeMessage[]
---@field model string|nil
---@field agent string|nil
---@field listeners table<string, function[]>
---@field pending_permissions table<string, OpencodePermission>
```

**Core Features:**
- Manage all active sessions
- Listen to server events and update session state
- Provide message history queries
- Auto-cleanup expired sessions

### 4.4 Streaming Handler (`lua/opencode/headless/stream_handler.lua`)

```lua
---@class StreamHandle
---@field abort fun(): Promise<boolean> Abort streaming response (async)
---@field is_done fun(): boolean Check if complete
---@field get_partial_text fun(): string Get current accumulated text
---@field on fun(self: StreamHandle, event: string, callback: function): StreamHandle Add event listener
```

**Implementation Approach:**
1. Subscribe to `EventManager`'s `message.part.updated` event
2. Filter relevant events by `session_id` and `message_id`
3. Pass incremental updates to user via callbacks
4. Support cancellation midway (call `api_client:abort_session`)

---

## 5. Tool Call Support

### 5.1 Tool Call Type Definitions

```lua
---@class ToolCallInfo
---@field id string Tool call ID
---@field name string Tool name (e.g., 'bash', 'read', 'edit', 'glob', 'grep')
---@field status 'pending'|'running'|'completed'|'failed'|'permission_required'
---@field input table Tool input parameters
---@field output? any Tool output result
---@field error? string Error message
---@field permission? OpencodePermission Associated permission request

---@class ToolConfig
---@field enabled? table<string, boolean> Enable/disable specific tools
---@field auto_approve? string[] Auto-approved tool list
---@field auto_reject? string[] Auto-rejected tool list
---@field timeout? number Tool execution timeout (milliseconds)
```

### 5.2 Permission Handling (`lua/opencode/headless/tool_handler.lua`)

```lua
---@class PermissionHandler
---@field strategy 'auto_approve'|'auto_reject'|'ask'|'callback' Permission handling strategy
---@field callback? fun(permission: OpencodePermission): Promise<PermissionResponse> Custom callback
---@field rules? PermissionRule[] Permission rules

---@class PermissionRule
---@field pattern string Tool name or pattern (supports wildcards)
---@field action PermissionResponse Default action
---@field condition? fun(permission: OpencodePermission): boolean Optional condition function
```

#### Permission Handling Strategy Examples

```lua
-- Strategy 1: Full auto-approve (dangerous, testing only)
local headless = require('opencode.headless').new({
  permission_handler = {
    strategy = 'auto_approve'
  }
})

-- Strategy 2: Rule-based auto-handling
local headless = require('opencode.headless').new({
  permission_handler = {
    strategy = 'callback',
    rules = {
      { pattern = 'read', action = 'always' },      -- Read operations always allowed
      { pattern = 'glob', action = 'always' },      -- File search always allowed
      { pattern = 'grep', action = 'always' },      -- Content search always allowed
      { pattern = 'bash', action = 'once' },        -- bash needs per-call confirmation
      { pattern = 'edit', action = 'once' },        -- Edit needs per-call confirmation
      { pattern = 'write', action = 'reject' },     -- Write defaults to reject
    },
    callback = function(permission)
      -- Callback when rules don't match
      return require('opencode.promise').new():resolve('reject')
    end
  }
})

-- Strategy 3: Fully custom handling
local headless = require('opencode.headless').new({
  permission_handler = {
    strategy = 'callback',
    callback = function(permission)
      -- Async handling, e.g., prompt user via UI
      return some_ui_prompt(permission):and_then(function(user_choice)
        return user_choice
      end)
    end
  }
})
```

### 5.3 Tool Call Event Flow

```lua
-- Monitor complete tool call lifecycle
local handle = headless:chat_stream('create a new file', {
  on_tool_call = function(tool_call)
    -- Triggered on tool call status change
    if tool_call.status == 'pending' then
      print('Tool pending:', tool_call.name)
    elseif tool_call.status == 'running' then
      print('Tool running:', tool_call.name)
    elseif tool_call.status == 'completed' then
      print('Tool completed:', tool_call.name, tool_call.output)
    elseif tool_call.status == 'failed' then
      print('Tool failed:', tool_call.name, tool_call.error)
    elseif tool_call.status == 'permission_required' then
      print('Tool needs permission:', tool_call.name)
    end
  end,
  
  on_permission = function(permission)
    -- Return Promise to support async decisions
    print('Permission requested for:', permission.title)
    print('Tool type:', permission.type)
    print('Pattern:', vim.inspect(permission.pattern))
    
    -- Synchronous return
    return 'once'
    
    -- Or async return
    -- return Promise.new():resolve('once')
  end,
  
  on_done = function(message)
    -- Can extract all tool call results from message
    for _, part in ipairs(message.parts or {}) do
      if part.type == 'tool-call' then
        print('Final tool result:', part.name, part.state)
      end
    end
  end
})
```

### 5.4 Advanced Tool Call Use Cases

#### Get Tool List

```lua
-- Get available tools list
headless:list_tools():and_then(function(tools)
  for _, tool in ipairs(tools) do
    print(tool.id, tool.description)
  end
end)
```

#### Disable Specific Tools

```lua
-- Disable dangerous tools
headless:chat('help me organize files', {
  tools = {
    bash = false,     -- Disable bash
    write = false,    -- Disable file writing
    edit = true,      -- Allow editing
    read = true,      -- Allow reading
  }
})
```

#### Track Tool Execution Results

```lua
local tool_results = {}

local handle = headless:chat_stream('refactor this code', {
  on_tool_call = function(tool_call)
    if tool_call.status == 'completed' then
      table.insert(tool_results, {
        name = tool_call.name,
        input = tool_call.input,
        output = tool_call.output,
        timestamp = vim.uv.now()
      })
    end
  end,
  on_done = function(message)
    print('Total tool calls:', #tool_results)
    for i, result in ipairs(tool_results) do
      print(i, result.name, result.timestamp)
    end
  end
})
```

---

## 6. Non-blocking Design

### 6.1 Core Principles

**All APIs must be non-blocking**, cannot call `:wait()` to synchronously wait for results. This is because:

1. Neovim is single-threaded, blocking makes the entire editor unresponsive
2. User experience requires the interface to always remain responsive
3. Long AI responses should not freeze the editor

### 6.2 Async Patterns

#### Pattern 1: Promise Chaining (Recommended)

```lua
local headless = require('opencode.headless').new()

-- Chained calls, fully non-blocking
headless:chat('hello')
  :and_then(function(response)
    print('Got response:', response.text)
    -- Can continue chaining
    return headless:chat('follow up question')
  end)
  :and_then(function(response)
    print('Follow up response:', response.text)
  end)
  :catch(function(err)
    print('Error:', err)
  end)
```

#### Pattern 2: Callback Pattern

```lua
headless:chat_stream('long task', {
  on_data = function(chunk)
    -- Called each time data is received
    vim.schedule(function()
      -- Safely update UI
      update_status_line(chunk.text)
    end)
  end,
  on_done = function(message)
    vim.schedule(function()
      vim.notify('Task completed!')
    end)
  end
})
```

#### Pattern 3: Coroutine Pattern (Use within Promise.async)

```lua
local Promise = require('opencode.promise')

-- Wrap with Promise.async, can use :await() internally
-- But overall is still non-blocking
Promise.spawn(function()
  local headless = require('opencode.headless').new()
  
  -- Can use await inside coroutine, but doesn't block Neovim
  local session = headless:create_session():await()
  local response1 = headless:send_message(session.id, 'question 1'):await()
  local response2 = headless:send_message(session.id, 'question 2'):await()
  
  print('Conversation done')
end)
```

### 6.3 Forbidden Patterns

```lua
-- ❌ Wrong: This blocks Neovim
local response = headless:chat('hello'):wait()

-- ❌ Wrong: Synchronous wait
local session = headless:create_session():wait()

-- ❌ Wrong: Blocking loop in main thread
while not handle:is_done() do
  vim.wait(100)  -- This still blocks
end
```

### 6.4 API Design Enforces Non-blocking

```lua
---@class OpencodeHeadless
-- Note: chat returns Promise, no synchronous version
---@field chat fun(self: OpencodeHeadless, message: string, opts?: ChatOptions): Promise<ChatResponse>

-- If user really needs to "wait", must use Promise.spawn
-- This allows using await inside coroutine without blocking main thread
```

### 6.5 Timeout and Cancellation

```lua
local headless = require('opencode.headless').new({
  timeout = 60000  -- 60 second timeout
})

-- Cancel ongoing request
local promise = headless:chat('very long task')

-- Cancel after 5 seconds
vim.defer_fn(function()
  headless:abort():and_then(function()
    print('Request cancelled')
  end)
end, 5000)
```

### 6.6 Concurrency Control

```lua
local headless = require('opencode.headless').new()
local Promise = require('opencode.promise')

-- Execute multiple requests concurrently (non-blocking)
local promises = {
  headless:chat('question 1'),
  headless:chat('question 2'),
  headless:chat('question 3'),
}

Promise.all(promises):and_then(function(results)
  for i, result in ipairs(results) do
    print('Result', i, ':', result.text)
  end
end)

-- Or use Promise.race for fastest response
Promise.race(promises):and_then(function(first_result)
  print('First response:', first_result.text)
end)
```

---

## 7. Implementation Notes

### 7.1 Integration with Existing Code

#### Reused Modules

| Module | Purpose | Needs Modification |
|--------|---------|-------------------|
| `api_client.lua` | HTTP API encapsulation | ❌ No modification needed |
| `event_manager.lua` | Event-driven architecture | ⚠️ May need scheduler adaptation |
| `server_job.lua` | Server management | ❌ No modification needed |
| `promise.lua` | Async handling | ❌ No modification needed |
| `session.lua` | Session utility functions | ❌ No modification needed |

#### Independent Modules

- **Not dependent on `core.lua`**: `core.lua` is highly coupled to UI (`state.windows`, `ui.xxx` calls)
- **Not dependent on `ui/` directory**: All UI-related rendering logic
- **Selectively use `context.lua`**: Can reuse context formatting logic, but not auto-collect vim buffer info

### 7.2 State Management Strategy

#### Independent headless_state (Recommended)

```lua
local headless_state = {
  active_sessions = {}, -- session_id -> HeadlessSession
  api_client = nil,
  event_manager = nil,
  server = nil,
  default_config = {},
  pending_permissions = {}, -- permission_id -> callback
}
```

### 7.3 Context Handling

Context in headless mode needs to be explicitly passed:

```lua
-- User can explicitly pass context
headless:chat('fix this bug', {
  context = {
    current_file = { path = '/path/to/file.lua' },
    mentioned_files = { '/path/to/another.lua' },
    selections = {
      { file = {...}, content = 'code snippet', lines = '10, 20' }
    },
  }
})
```

### 7.4 Server Lifecycle

```lua
-- Option 1: Auto-managed (default)
local headless = require('opencode.headless').new({
  auto_start_server = true  -- Auto start and shutdown
})

-- Option 2: Manual management
local headless = require('opencode.headless').new({
  auto_start_server = false
})
-- User must ensure opencode server is running

-- Cleanup
headless:close()  -- Cleanup resources, but don't close server (if UI still using it)
```

---

## 8. Usage Scenarios

### Scenario 1: Single-turn Q&A (Fully Async)

```lua
local headless = require('opencode.headless').new()

-- Async approach (recommended)
headless:chat('what is vim?'):and_then(function(response)
  print(response.text)
end)

-- Coroutine approach (in async context)
Promise.spawn(function()
  local response = headless:chat('what is vim?'):await()
  print(response.text)
end)
```

### Scenario 2: Multi-turn Conversation

```lua
local headless = require('opencode.headless').new()

headless:create_session():and_then(function(session)
  -- First turn
  return headless:send_message(session.id, 'I want to write a lua plugin')
    :and_then(function()
      -- Second turn
      return headless:send_message(session.id, 'How do I setup keymaps?')
    end)
    :and_then(function(response)
      print(response.text)
    end)
end)
```

### Scenario 3: Streaming Response

```lua
local headless = require('opencode.headless').new()

local full_text = ''
local handle = headless:chat_stream('write a long story', {
  on_data = function(chunk)
    if chunk.text then
      full_text = full_text .. chunk.text
      -- Use vim.schedule to safely update UI
      vim.schedule(function()
        -- Update a buffer or status line
      end)
    end
  end,
  on_done = function(message)
    vim.schedule(function()
      vim.notify('Story completed!')
    end)
  end,
  on_error = function(err)
    vim.schedule(function()
      vim.notify('Error: ' .. vim.inspect(err), vim.log.levels.ERROR)
    end)
  end,
})

-- Can cancel midway
vim.defer_fn(function()
  handle:abort()
end, 5000)
```

### Scenario 4: Task with Tool Calls

```lua
local headless = require('opencode.headless').new({
  permission_handler = {
    strategy = 'callback',
    rules = {
      { pattern = 'read', action = 'always' },
      { pattern = 'glob', action = 'always' },
      { pattern = 'grep', action = 'always' },
    },
    callback = function(permission)
      -- For permissions not matching rules, ask user
      return Promise.new(function(resolve)
        vim.schedule(function()
          vim.ui.select({ 'Allow Once', 'Always Allow', 'Reject' }, {
            prompt = 'Permission: ' .. permission.title
          }, function(choice)
            if choice == 'Allow Once' then
              resolve('once')
            elseif choice == 'Always Allow' then
              resolve('always')
            else
              resolve('reject')
            end
          end)
        end)
      end)
    end
  }
})

headless:chat_stream('refactor the user module', {
  on_tool_call = function(tool_call)
    vim.schedule(function()
      vim.notify(string.format('Tool %s: %s', tool_call.status, tool_call.name))
    end)
  end,
  on_done = function(message)
    vim.schedule(function()
      vim.notify('Refactoring completed!')
    end)
  end
})
```

### Scenario 5: Batch Processing

```lua
local headless = require('opencode.headless').new()
local Promise = require('opencode.promise')

-- Process multiple files concurrently (non-blocking)
local files = { 'a.lua', 'b.lua', 'c.lua' }
local promises = {}

for _, file in ipairs(files) do
  local promise = headless:chat('review this file', {
    context = {
      mentioned_files = { file }
    }
  })
  table.insert(promises, promise)
end

Promise.all(promises):and_then(function(results)
  for i, result in ipairs(results) do
    print(string.format('%s: %s', files[i], result.text))
  end
end)
```

### Scenario 6: Code Review Tool

```lua
local headless = require('opencode.headless').new({
  agent = 'plan',
  model = 'anthropic/claude-3-5-sonnet-20241022'
})

local function review_file(filepath)
  return headless:chat('Review this file for potential bugs and improvements', {
    context = {
      mentioned_files = { filepath }
    }
  })
end

local function review_directory(dir, callback)
  local files = vim.fn.globpath(dir, '**/*.lua', false, true)
  local promises = {}
  
  for _, file in ipairs(files) do
    table.insert(promises, review_file(file):and_then(function(response)
      return { file = file, review = response.text }
    end))
  end
  
  Promise.all(promises):and_then(function(reviews)
    callback(reviews)
  end)
end

-- Usage
review_directory('./lua', function(reviews)
  for _, r in ipairs(reviews) do
    print(r.file, ':', r.review)
  end
end)
```

### Scenario 7: Automation Workflow

```lua
local headless = require('opencode.headless').new({
  permission_handler = {
    strategy = 'callback',
    rules = {
      { pattern = '*', action = 'once' },  -- All tools need one-time confirmation
    }
  }
})

-- Create an automated code fix workflow
local function auto_fix_lsp_errors()
  local diagnostics = vim.diagnostic.get(0)
  if #diagnostics == 0 then
    vim.notify('No diagnostics found')
    return
  end
  
  local file = vim.api.nvim_buf_get_name(0)
  local prompt = string.format(
    'Fix the following LSP errors in %s:\n%s',
    file,
    vim.inspect(diagnostics)
  )
  
  headless:chat_stream(prompt, {
    context = { mentioned_files = { file } },
    on_tool_call = function(tool_call)
      if tool_call.status == 'completed' and tool_call.name == 'edit' then
        -- Reload file after edit completes
        vim.schedule(function()
          vim.cmd('checktime')
        end)
      end
    end,
    on_done = function()
      vim.schedule(function()
        vim.notify('Auto-fix completed!')
      end)
    end
  })
end
```

---

## 9. Relationship with Existing Architecture

```
┌─────────────────────────────────────────────────────┐
│                   User Interface                     │
├────────────────┬────────────────────────────────────┤
│  UI Mode       │         Headless Mode              │
│  (opencode.lua)│    (opencode.headless.lua)         │
├────────────────┴────────────────────────────────────┤
│             Common Layer                             │
│  ┌──────────────────┬──────────────────────────┐   │
│  │ api_client.lua   │  event_manager.lua       │   │
│  │ server_job.lua   │  promise.lua             │   │
│  │ session.lua      │  context.lua (optional)  │   │
│  └──────────────────┴──────────────────────────┘   │
├─────────────────────────────────────────────────────┤
│              OpenCode Server (CLI)                   │
└─────────────────────────────────────────────────────┘
```

### Module Dependency Graph

```
headless/init.lua
  ├─> headless/session_manager.lua
  │     ├─> api_client.lua
  │     ├─> event_manager.lua
  │     └─> session.lua
  │
  ├─> headless/chat.lua
  │     ├─> api_client.lua
  │     └─> context.lua (format only)
  │
  ├─> headless/stream_handler.lua
  │     ├─> event_manager.lua
  │     └─> promise.lua
  │
  └─> headless/tool_handler.lua
        ├─> api_client.lua
        └─> event_manager.lua
```

---

## 10. Implementation Priority

### Phase 1: Basic Functionality (MVP)

**Goal:** Implement basic single-turn chat functionality (non-blocking)

- [ ] `headless/init.lua` - Basic `chat()` interface
- [ ] `headless/session_manager.lua` - Simple session management
- [ ] Ensure server can start in headless mode
- [ ] Basic unit tests

**Acceptance Criteria:**
```lua
local headless = require('opencode.headless').new()
headless:chat('hello'):and_then(function(response)
  assert(response.text ~= nil)
end)
```

### Phase 2: Multi-turn Conversation

**Goal:** Support stateful multi-turn sessions

- [ ] Complete `session_manager`
- [ ] Implement `send_message()`
- [ ] Implement `create_session()`, `get_session()`
- [ ] Message history management
- [ ] Session persistence (optional)

**Acceptance Criteria:**
```lua
headless:create_session():and_then(function(session)
  return headless:send_message(session.id, 'first message')
end):and_then(function()
  return headless:get_session(session.id)
end):and_then(function(session)
  assert(#session.messages >= 2)
end)
```

### Phase 3: Streaming Response

**Goal:** Support real-time incremental response reception

- [ ] `headless/stream_handler.lua`
- [ ] Implement `chat_stream()`
- [ ] Event filtering and dispatch
- [ ] Abort mechanism

**Acceptance Criteria:**
```lua
local chunks = {}
local handle = headless:chat_stream('test', {
  on_data = function(chunk) table.insert(chunks, chunk) end,
  on_done = function() assert(#chunks > 0) end
})
```

### Phase 4: Tool Call Support

**Goal:** Support tool calls and permission management

- [ ] `headless/tool_handler.lua`
- [ ] Implement `on_tool_call` callback
- [ ] Implement `on_permission` callback
- [ ] Permission rules engine
- [ ] Tool enable/disable configuration

**Acceptance Criteria:**
```lua
local tool_calls = {}
headless:chat_stream('read file.lua', {
  permission_handler = { strategy = 'auto_approve' },
  on_tool_call = function(tc) table.insert(tool_calls, tc) end,
  on_done = function()
    assert(#tool_calls > 0)
    assert(tool_calls[1].name == 'read')
  end
})
```

### Phase 5: Advanced Features

**Goal:** Complete production-ready functionality

- [ ] Context support
- [ ] Batch operation helper functions
- [ ] Error retry mechanism
- [ ] Complete documentation and examples
- [ ] Performance optimization

---

## 11. Potential Challenges and Solutions

| Challenge | Solution |
|-----------|----------|
| **EventManager depends on `vim.schedule`** | Keep using `vim.schedule`, this is the correct non-blocking approach |
| **Context highly dependent on vim buffer/window** | Provide explicit context parameter, don't auto-collect; reuse `context.format_message` formatting logic |
| **Server lifecycle management** | Provide `auto_start_server` option, or require user to pre-start; reference counting to manage server instances |
| **Error handling and timeout** | All Promises should have timeout mechanism, provide unified error handling; support custom timeout |
| **Coexistence with UI mode** | Use independent state, detect conflicts and error or auto-switch; share server instance but independently manage sessions |
| **Message ordering and concurrency** | Use queue to manage concurrent requests in same session; provide `wait_for_previous` option |
| **Memory leak (long sessions)** | Implement session expiration mechanism; provide manual cleanup interface; limit message history size |
| **Testing environment** | Provide mock server or use real server; headless mode naturally suitable for CI/CD |
| **Tool Call permission management** | Provide flexible permission strategies, support rule matching and custom callbacks |
| **Async permission decisions** | Permission callback returns Promise, supports async UI interaction |

### Detailed Solutions

#### 1. Non-blocking API Design

```lua
-- All APIs return Promise, no synchronous version provided
---@return Promise<ChatResponse>
function M:chat(message, opts)
  return Promise.new(function(resolve, reject)
    -- Async implementation
  end)
end

-- User must use async pattern
headless:chat('hello'):and_then(function(response)
  -- handle response
end)
```

#### 2. Tool Call Permission Handling

```lua
-- tool_handler.lua
local M = {}

function M.handle_permission(permission, handler)
  -- Check rules
  for _, rule in ipairs(handler.rules or {}) do
    if M.match_pattern(permission.type, rule.pattern) then
      if rule.condition and not rule.condition(permission) then
        goto continue
      end
      return Promise.resolve(rule.action)
    end
    ::continue::
  end
  
  -- Use callback
  if handler.callback then
    local result = handler.callback(permission)
    -- Support sync and async return
    if type(result) == 'string' then
      return Promise.resolve(result)
    end
    return result -- Already a Promise
  end
  
  -- Default strategy
  if handler.strategy == 'auto_approve' then
    return Promise.resolve('once')
  elseif handler.strategy == 'auto_reject' then
    return Promise.resolve('reject')
  end
  
  return Promise.resolve('reject')
end

return M
```

#### 3. Server Reference Counting

```lua
local server_refs = 0

function M.new(opts)
  return Promise.new(function(resolve)
    local ensure_server = function()
      if not state.server then
        return server_job.ensure_server()
      end
      return Promise.resolve(state.server)
    end
    
    ensure_server():and_then(function(server)
      state.server = server
      server_refs = server_refs + 1
      
      local instance = setmetatable({...}, M)
      resolve(instance)
    end)
  end)
end

function M:close()
  server_refs = server_refs - 1
  -- Cleanup session subscriptions and other resources
  self:_cleanup()
  
  if server_refs == 0 and self.opts.auto_shutdown then
    state.server:shutdown()
  end
end
```

---

## 12. Summary

### Core Advantages

1. **Fully Non-blocking**: All APIs are async, never blocking the Neovim main loop
2. **Progressive Integration**: Can be implemented incrementally without affecting existing UI functionality
3. **Code Reuse**: Leverages mature modules like `api_client`, `event_manager`, `promise`
4. **High Flexibility**: Supports single-turn, multi-turn, streaming, and other usage modes
5. **Tool Call Support**: Complete tool call and permission management
6. **Type Safety**: Complete LuaCATS type annotations
7. **Easy to Test**: Headless mode naturally suitable for automated testing
8. **Backward Compatible**: Does not break existing API
9. **Production Ready**: Considers error handling, timeout, resource cleanup and other production requirements

### API Design Principles

- **Non-blocking First**: All APIs return Promise, no synchronous version provided
- **Simplicity**: Most common functionality with minimal code
- **Consistency**: Maintains style consistency with existing `api_client` and `core`
- **Extensibility**: Extension points reserved, easy to add new features
- **Safety**: Clear error handling, prevents resource leaks

### Next Steps

1. **Review Design**: Discuss with team, collect feedback
2. **Create PoC**: Implement Phase 1 MVP, validate architecture feasibility
3. **Write Tests**: Write tests first, then implement (TDD)
4. **Documentation First**: Write API documentation and usage examples
5. **Iterative Development**: Implement incrementally following Phase 1-5

### References

- Existing code analysis:
  - `lua/opencode/core.lua:135` - `send_message` implementation
  - `lua/opencode/api_client.lua:241` - `create_message` API
  - `lua/opencode/api_client.lua:295` - `respond_to_permission` API
  - `lua/opencode/event_manager.lua:295` - Event subscription mechanism
  - `lua/opencode/event_manager.lua:109` - permission.updated event
  - `lua/opencode/ui/renderer.lua:118` - Streaming response handling

---
