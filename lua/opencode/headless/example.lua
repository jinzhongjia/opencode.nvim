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
}
