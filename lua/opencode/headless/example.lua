-- Example usage of the headless API
-- This file demonstrates how to use the headless API for testing

local headless = require('opencode.headless')

-- Example 1: Simple single-turn chat
local function example_simple_chat()
  print('=== Example 1: Simple Chat ===')

  headless.new():and_then(function(client)
    print('Headless client created successfully')

    return client:chat('Hello, what is Lua?'):and_then(function(response)
      print('Response:', response.text)
      print('Session ID:', response.session_id)

      -- Cleanup
      client:close()
    end)
  end):catch(function(err)
    print('Error:', vim.inspect(err))
  end)
end

-- Example 2: Multi-turn conversation
local function example_multi_turn()
  print('=== Example 2: Multi-turn Conversation ===')

  headless.new():and_then(function(client)
    print('Headless client created')

    return client:create_session():and_then(function(session)
      print('Session created:', session.id)

      -- First message
      return client:send_message(session.id, 'What is Neovim?'):and_then(function(response1)
        print('Response 1:', response1.text:sub(1, 100))

        -- Second message
        return client:send_message(session.id, 'Can you give me an example?'):and_then(function(response2)
          print('Response 2:', response2.text:sub(1, 100))

          -- Cleanup
          client:close()
        end)
      end)
    end)
  end):catch(function(err)
    print('Error:', vim.inspect(err))
  end)
end

-- Example 3: Using specific model and agent
local function example_with_options()
  print('=== Example 3: With Options ===')

  headless.new({
    model = 'anthropic/claude-3-5-sonnet-20241022',
    agent = 'plan',
  }):and_then(function(client)
    print('Headless client created with custom config')

    return client:chat('Explain the difference between vim and neovim'):and_then(function(response)
      print('Response:', response.text:sub(1, 100))

      -- Cleanup
      client:close()
    end)
  end):catch(function(err)
    print('Error:', vim.inspect(err))
  end)
end

-- Example 4: Using Promise.spawn for sequential operations
local function example_with_spawn()
  print('=== Example 4: Using Promise.spawn ===')

  local Promise = require('opencode.promise')

  Promise.spawn(function()
    local client = headless.new():await()
    print('Client created')

    local session = client:create_session():await()
    print('Session created:', session.id)

    local response1 = client:send_message(session.id, 'What is Lua?'):await()
    print('Response 1:', response1.text:sub(1, 50))

    local response2 = client:send_message(session.id, 'Give me an example'):await()
    print('Response 2:', response2.text:sub(1, 50))

    client:close()
    print('Done!')
  end):catch(function(err)
    print('Error:', vim.inspect(err))
  end)
end

---Example 5: Streaming response
local function example_streaming()
  local headless = require('opencode.headless')

  headless.new():and_then(function(client)
    print('Starting streaming chat...')

    local partial_text = ''
    local handle = client:chat_stream('Tell me a short story', {
      on_data = function(chunk)
        if chunk.text then
          partial_text = partial_text .. chunk.text
          -- Print each chunk as it arrives
          io.write(chunk.text)
          io.flush()
        end
      end,
      on_done = function(message)
        print('\n\n=== Streaming complete ===')
        print('Total text length:', #partial_text)
        print('Message parts:', #(message.parts or {}))
        client:close()
      end,
      on_error = function(err)
        print('\nError:', vim.inspect(err))
        client:close()
      end,
    })

    print('Stream handle created')
    print('Is done?', handle.is_done())
  end):catch(function(err)
    print('Failed to create client:', vim.inspect(err))
  end)
end

---Example 6: Tool calls with auto-approval
local function example_tool_calls_auto()
  local headless = require('opencode.headless')
  local permission_handler = require('opencode.headless.permission_handler')

  headless.new():and_then(function(client)
    print('Starting chat with tool calls (auto-approve)...')

    local tool_call_count = 0
    local handle = client:chat_stream('Read the contents of README.md', {
      -- Auto-approve all tool calls
      permission_handler = permission_handler.auto_approve(),

      on_data = function(chunk)
        if chunk.text then
          io.write(chunk.text)
          io.flush()
        end
      end,

      on_tool_call = function(tool_call)
        tool_call_count = tool_call_count + 1
        print(string.format(
          '\n[Tool Call #%d] %s: %s',
          tool_call_count,
          tool_call.name,
          tool_call.status
        ))
        if tool_call.status == 'completed' and tool_call.output then
          print(string.format('  Output: %s...', tool_call.output:sub(1, 50)))
        end
      end,

      on_done = function(message)
        print('\n\n=== Done ===')
        print('Tool calls:', tool_call_count)
        local all_tool_calls = handle:get_tool_calls()
        print('Tracked tool calls:', vim.tbl_count(all_tool_calls))
        client:close()
      end,

      on_error = function(err)
        print('\nError:', vim.inspect(err))
        client:close()
      end,
    })

    print('Stream handle created')
  end):catch(function(err)
    print('Failed to create client:', vim.inspect(err))
  end)
end

---Example 7: Tool calls with safe defaults (auto-approve read, ask for write)
local function example_tool_calls_safe()
  local headless = require('opencode.headless')
  local permission_handler = require('opencode.headless.permission_handler')

  headless.new():and_then(function(client)
    print('Starting chat with tool calls (safe defaults)...')

    local _ = client:chat_stream('List files in the current directory', {
      -- Use safe defaults: read operations auto-approved, write operations need approval
      permission_handler = permission_handler.safe_defaults(),

      on_data = function(chunk)
        if chunk.text then
          io.write(chunk.text)
          io.flush()
        end
      end,

      on_tool_call = function(tool_call)
        print(string.format('\n[%s] %s', tool_call.name, tool_call.status))
      end,

      on_done = function()
        print('\n\n=== Done ===')
        client:close()
      end,

      on_error = function(err)
        print('\nError:', vim.inspect(err))
        client:close()
      end,
    })

    print('Stream handle created')
    print('Note: read/glob/grep/list will be auto-approved')
    print('Note: bash/edit/write will be approved once per call')
    print('Note: unknown tools will be rejected')
  end):catch(function(err)
    print('Failed to create client:', vim.inspect(err))
  end)
end

---Example 8: Tool calls with custom permission callback
local function example_tool_calls_custom()
  local headless = require('opencode.headless')
  local Promise = require('opencode.promise')

  headless.new():and_then(function(client)
    print('Starting chat with tool calls (custom callback)...')

    local _ = client:chat_stream('Create a file called test.txt with hello world', {
      on_data = function(chunk)
        if chunk.text then
          io.write(chunk.text)
          io.flush()
        end
      end,

      -- Custom permission callback
      on_permission = function(permission)
        print(string.format(
          '\n[Permission Request] Tool: %s, Title: %s',
          permission.tool_name,
          permission.title
        ))

        -- Example: simulate async user confirmation
        -- In a real scenario, you might show a UI prompt
        local promise = Promise.new()

        vim.defer_fn(function()
          -- Approve all read operations, reject write operations
          if permission.tool_name == 'read' or permission.tool_name == 'glob' then
            print('  -> Auto-approved (read operation)')
            promise:resolve('always')
          elseif permission.tool_name == 'write' then
            print('  -> Rejected (write operation)')
            promise:resolve('reject')
          else
            print('  -> Approved once')
            promise:resolve('once')
          end
        end, 100) -- Simulate 100ms delay

        return promise
      end,

      on_tool_call = function(tool_call)
        print(string.format('\n[Tool] %s: %s', tool_call.name, tool_call.status))
      end,

      on_done = function()
        print('\n\n=== Done ===')
        client:close()
      end,

      on_error = function(err)
        print('\nError:', vim.inspect(err))
        client:close()
      end,
    })

    print('Stream handle created')
  end):catch(function(err)
    print('Failed to create client:', vim.inspect(err))
  end)
end

---Example 9: Tool calls with rule-based permissions
local function example_tool_calls_rules()
  local headless = require('opencode.headless')
  local permission_handler = require('opencode.headless.permission_handler')

  -- Create a custom permission handler with specific rules
  local handler = permission_handler.new({
    strategy = 'auto_reject', -- Default: reject unknown tools
    rules = {
      -- Always allow read operations
      { pattern = 'read', action = 'always' },
      { pattern = 'glob', action = 'always' },
      { pattern = 'grep', action = 'always' },
      { pattern = 'list', action = 'always' },

      -- Allow bash commands that start with 'echo' or 'cat'
      {
        pattern = 'bash',
        action = 'once',
        condition = function(perm)
          local input = perm.pattern or {}
          local command = input.command or ''
          return command:match('^echo') or command:match('^cat')
        end,
      },

      -- Reject all other bash commands
      { pattern = 'bash', action = 'reject' },

      -- Allow editing files in /tmp only
      {
        pattern = 'edit',
        action = 'once',
        condition = function(perm)
          local input = perm.pattern or {}
          local file_path = input.filePath or ''
          return file_path:match('^/tmp/')
        end,
      },
    },
  })

  headless.new():and_then(function(client)
    print('Starting chat with rule-based permissions...')

    local _ = client:chat_stream('Run echo hello and then try to delete a file', {
      permission_handler = handler,

      on_data = function(chunk)
        if chunk.text then
          io.write(chunk.text)
          io.flush()
        end
      end,

      on_tool_call = function(tool_call)
        print(string.format('\n[%s] %s', tool_call.name, tool_call.status))
      end,

      on_done = function()
        print('\n\n=== Done ===')
        client:close()
      end,

      on_error = function(err)
        print('\nError:', vim.inspect(err))
        client:close()
      end,
    })

    print('Stream handle created')
    print('Rules:')
    print('  - read/glob/grep/list: always allowed')
    print('  - bash (echo/cat): allowed once per call')
    print('  - bash (other): rejected')
    print('  - edit (/tmp/*): allowed once')
    print('  - edit (other): rejected')
  end):catch(function(err)
    print('Failed to create client:', vim.inspect(err))
  end)
end

---Example 10: Chat with single context (file + selection)
local function example_context_single()
  local headless = require('opencode.headless')

  headless.new():and_then(function(client)
    print('Starting chat with context...')

    return client:chat('Explain this code and suggest improvements', {
      context = {
        -- Current file being edited
        current_file = vim.fn.expand('%:p'),
        -- Additional files to include
        mentioned_files = {
          vim.fn.getcwd() .. '/README.md',
        },
        -- Code selection to analyze
        selections = {
          {
            content = [[
local function calculate(x, y)
  return x + y
end
]],
            lines = '10, 13',
          },
        },
        -- Diagnostics from LSP
        diagnostics = {
          { message = 'Unused parameter y', severity = 2, lnum = 10, col = 28 },
        },
      },
    })
  end):and_then(function(response)
    print('\n=== Response ===')
    print(response.text)
  end):catch(function(err)
    print('Error:', vim.inspect(err))
  end)
end

---Example 11: Chat with multiple contexts (batch file review)
local function example_context_multiple()
  local headless = require('opencode.headless')

  headless.new():and_then(function(client)
    print('Starting batch file review...')

    return client:chat('Compare these files and explain how they interact', {
      -- Multiple contexts for different files
      contexts = {
        {
          current_file = '/path/to/api/handler.lua',
          selections = {
            {
              content = 'function M.handle_request(req)\n  -- handler code\nend',
              lines = '1, 10',
            },
          },
        },
        {
          current_file = '/path/to/services/user.lua',
          selections = {
            {
              content = 'function M.get_user(id)\n  -- service code\nend',
              lines = '20, 30',
            },
          },
        },
        {
          current_file = '/path/to/models/user.lua',
          diagnostics = {
            { message = 'Field may be nil', severity = 2, lnum = 5, col = 10 },
          },
        },
      },
    })
  end):and_then(function(response)
    print('\n=== Response ===')
    print(response.text)
  end):catch(function(err)
    print('Error:', vim.inspect(err))
  end)
end

---Example 12: Streaming with context
local function example_context_streaming()
  local headless = require('opencode.headless')
  local permission_handler = require('opencode.headless.permission_handler')

  headless.new():and_then(function(client)
    print('Starting streaming chat with context...')

    local _ = client:chat_stream('Review this file for bugs and fix them', {
      context = {
        current_file = vim.fn.expand('%:p'),
        diagnostics = vim.diagnostic.get(0), -- Get diagnostics from current buffer
      },
      permission_handler = permission_handler.safe_defaults(),

      on_data = function(chunk)
        if chunk.text then
          io.write(chunk.text)
          io.flush()
        end
      end,

      on_tool_call = function(tool_call)
        print(string.format('\n[Tool] %s: %s', tool_call.name, tool_call.status))
      end,

      on_done = function()
        print('\n\n=== Review complete ===')
        client:close()
      end,

      on_error = function(err)
        print('\nError:', vim.inspect(err))
        client:close()
      end,
    })
  end):catch(function(err)
    print('Failed to create client:', vim.inspect(err))
  end)
end

---Example 13: Chat with base64 images
local function example_with_images()
  local headless = require('opencode.headless')

  -- Example: Read an image file and convert to base64
  -- In practice, you might get this from clipboard, screenshot, etc.
  local function read_image_as_base64(path)
    local file = io.open(path, 'rb')
    if not file then
      return nil
    end
    local data = file:read('*all')
    file:close()
    -- Encode to base64 using vim's built-in function
    return vim.base64.encode(data)
  end

  headless.new():and_then(function(client)
    print('Starting chat with image...')

    -- Example with a hardcoded tiny 1x1 red PNG (base64 encoded)
    -- In practice, you'd read an actual image file
    local tiny_red_png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=='

    return client:chat('What do you see in this image?', {
      context = {
        images = {
          { data = tiny_red_png, format = 'png' },
        },
      },
    })
  end):and_then(function(response)
    print('\n=== Response ===')
    print(response.text)
  end):catch(function(err)
    print('Error:', vim.inspect(err))
  end)
end

---Example 14: Chat with multiple images and context
local function example_with_multiple_images()
  local headless = require('opencode.headless')

  headless.new():and_then(function(client)
    print('Starting chat with multiple images...')

    -- Example: Compare two screenshots
    local screenshot1 = 'base64_encoded_image_data_1'
    local screenshot2 = 'base64_encoded_image_data_2'

    return client:chat('Compare these two UI screenshots and identify the differences', {
      context = {
        -- Include related code file for context
        current_file = '/path/to/ui/component.tsx',
        -- Multiple images to compare
        images = {
          { data = screenshot1, format = 'png' },
          { data = screenshot2, format = 'png' },
        },
      },
    })
  end):and_then(function(response)
    print('\n=== Response ===')
    print(response.text)
  end):catch(function(err)
    print('Error:', vim.inspect(err))
  end)
end

---Example 15: Streaming with image context
local function example_image_streaming()
  local headless = require('opencode.headless')
  local permission_handler = require('opencode.headless.permission_handler')

  headless.new():and_then(function(client)
    print('Starting streaming chat with image...')

    -- Example: Analyze an error screenshot and fix the code
    local error_screenshot = 'base64_encoded_error_screenshot'

    local _ = client:chat_stream('Fix the error shown in this screenshot', {
      context = {
        current_file = vim.fn.expand('%:p'),
        images = {
          { data = error_screenshot, format = 'png' },
        },
      },
      permission_handler = permission_handler.safe_defaults(),

      on_data = function(chunk)
        if chunk.text then
          io.write(chunk.text)
          io.flush()
        end
      end,

      on_tool_call = function(tool_call)
        print(string.format('\n[Tool] %s: %s', tool_call.name, tool_call.status))
      end,

      on_done = function()
        print('\n\n=== Done ===')
        client:close()
      end,

      on_error = function(err)
        print('\nError:', vim.inspect(err))
        client:close()
      end,
    })
  end):catch(function(err)
    print('Failed to create client:', vim.inspect(err))
  end)
end

---Example 16: Chat with retry configuration
local function example_with_retry()
  local headless = require('opencode.headless')

  headless.new({
    retry = {
      max_attempts = 3,
      delay_ms = 1000,
      backoff = 'exponential',
      jitter = true,
      on_retry = function(attempt, err, delay)
        print(string.format('[Retry] Attempt %d failed: %s. Retrying in %dms...', attempt, tostring(err), delay))
      end,
    },
  }):and_then(function(client)
    print('Client created with retry config')
    print('Retry settings: max_attempts=3, backoff=exponential')

    return client:chat('What is Neovim?'):and_then(function(response)
      print('\n=== Response ===')
      print(response.text:sub(1, 200))
      client:close()
    end)
  end):catch(function(err)
    print('Error:', vim.inspect(err))
  end)
end

---Example 17: Chat with timeout
local function example_with_timeout()
  local headless = require('opencode.headless')

  headless.new({
    timeout = 30000, -- 30 second global timeout
  }):and_then(function(client)
    print('Client created with 30s timeout')

    -- Can also override timeout per-request
    return client:chat('Write a haiku about programming', {
      timeout = 10000, -- 10 second timeout for this request
    }):and_then(function(response)
      print('\n=== Response ===')
      print(response.text)
      client:close()
    end)
  end):catch(function(err)
    if tostring(err):match('timeout') then
      print('Request timed out!')
    else
      print('Error:', vim.inspect(err))
    end
  end)
end

---Example 18: Batch requests
local function example_batch_requests()
  local headless = require('opencode.headless')
  local Promise = require('opencode.promise')

  Promise.spawn(function()
    local client = headless.new():await()
    print('Starting batch requests...')

    -- Execute multiple requests in parallel
    local results = client:batch({
      { message = 'What is Lua?' },
      { message = 'What is Neovim?' },
      { message = 'What is Vim?' },
    }, {
      max_concurrent = 2, -- Limit to 2 concurrent requests
    }):await()

    print('\n=== Batch Results ===')
    for i, result in ipairs(results) do
      if result.success then
        print(string.format('[%d] Success: %s...', i, result.response.text:sub(1, 50)))
      else
        print(string.format('[%d] Failed: %s', i, tostring(result.error)))
      end
    end

    client:close()
    print('\nDone!')
  end):catch(function(err)
    print('Error:', vim.inspect(err))
  end)
end

---Example 19: Map files for parallel review
local function example_map_files()
  local headless = require('opencode.headless')
  local Promise = require('opencode.promise')

  Promise.spawn(function()
    local client = headless.new():await()
    print('Starting parallel file review...')

    -- Files to review
    local files = {
      'lua/opencode/init.lua',
      'lua/opencode/config.lua',
      'lua/opencode/util.lua',
    }

    -- Map each file to a review request
    local results = client:map(files, function(file)
      return {
        message = 'Briefly describe what this file does (1 sentence)',
        context = {
          mentioned_files = { file },
        },
      }
    end, {
      max_concurrent = 3,
    }):await()

    print('\n=== File Reviews ===')
    for i, result in ipairs(results) do
      print(string.format('\n[%s]', files[i]))
      if result.success then
        print(result.response.text:sub(1, 150))
      else
        print('Error:', tostring(result.error))
      end
    end

    client:close()
    print('\nDone!')
  end):catch(function(err)
    print('Error:', vim.inspect(err))
  end)
end

-- Return examples for manual testing
return {
  simple_chat = example_simple_chat,
  multi_turn = example_multi_turn,
  with_options = example_with_options,
  with_spawn = example_with_spawn,
  streaming = example_streaming,
  tool_calls_auto = example_tool_calls_auto,
  tool_calls_safe = example_tool_calls_safe,
  tool_calls_custom = example_tool_calls_custom,
  tool_calls_rules = example_tool_calls_rules,
  context_single = example_context_single,
  context_multiple = example_context_multiple,
  context_streaming = example_context_streaming,
  with_images = example_with_images,
  with_multiple_images = example_with_multiple_images,
  image_streaming = example_image_streaming,
  with_retry = example_with_retry,
  with_timeout = example_with_timeout,
  batch_requests = example_batch_requests,
  map_files = example_map_files,
}
