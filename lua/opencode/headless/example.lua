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

-- Return examples for manual testing
return {
  simple_chat = example_simple_chat,
  multi_turn = example_multi_turn,
  with_options = example_with_options,
  with_spawn = example_with_spawn,
}
