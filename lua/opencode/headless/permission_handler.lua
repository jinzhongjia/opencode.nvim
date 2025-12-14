-- lua/opencode/headless/permission_handler.lua
-- Handles permission requests for tool calls in headless mode

local Promise = require('opencode.promise')

local M = {}

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

---@class PermissionHandler
---@field private config PermissionHandlerConfig
local PermissionHandler = {}
PermissionHandler.__index = PermissionHandler

---Create a new permission handler
---@param config? PermissionHandlerConfig
---@return PermissionHandler
function M.new(config)
  config = config or {}
  config.strategy = config.strategy or 'auto_reject'
  config.rules = config.rules or {}

  local self = setmetatable({
    config = config,
  }, PermissionHandler)

  return self
end

---Match a tool name against a pattern
---@param name string Tool name
---@param pattern string Pattern (supports '*' wildcard)
---@return boolean
function M.match_pattern(name, pattern)
  if pattern == '*' then
    return true
  end

  -- Escape all Lua pattern special characters except '*'
  -- Special chars: ( ) . % + - * ? [ ] ^ $
  local lua_pattern = pattern
    :gsub('([%(%)%.%%%+%-%?%[%]%^%$])', '%%%1') -- Escape special chars
    :gsub('%*', '.*') -- Convert glob '*' to Lua '.*'

  return name:match('^' .. lua_pattern .. '$') ~= nil
end

---Handle a permission request
---@param permission PermissionRequest
---@return Promise<PermissionResponse>
function PermissionHandler:handle(permission)
  local promise = Promise.new()

  -- Check rules first (in order)
  for _, rule in ipairs(self.config.rules) do
    if M.match_pattern(permission.tool_name, rule.pattern) then
      -- Check optional condition
      if not rule.condition or rule.condition(permission) then
        promise:resolve(rule.action)
        return promise
      end
    end
  end

  -- Apply strategy
  if self.config.strategy == 'auto_approve' then
    promise:resolve('once')
  elseif self.config.strategy == 'auto_reject' then
    promise:resolve('reject')
  elseif self.config.callback then
    -- Use custom callback
    local result = self.config.callback(permission)

    -- Handle both sync and async responses
    if type(result) == 'string' then
      promise:resolve(result)
    elseif type(result) == 'table' and result.and_then then
      -- It's a Promise
      result:and_then(function(response)
        promise:resolve(response)
      end):catch(function()
        -- On error, default to reject
        promise:resolve('reject')
      end)
    else
      -- Unknown return type, default to reject
      promise:resolve('reject')
    end
  else
    -- Default: reject
    promise:resolve('reject')
  end

  return promise
end

---Create a simple auto-approve handler
---@return PermissionHandler
function M.auto_approve()
  return M.new({ strategy = 'auto_approve' })
end

---Create a simple auto-reject handler
---@return PermissionHandler
function M.auto_reject()
  return M.new({ strategy = 'auto_reject' })
end

---Create a rule-based handler with common safe defaults
---@param custom_rules? PermissionRule[] Additional rules
---@return PermissionHandler
function M.safe_defaults(custom_rules)
  local rules = {
    -- Safe read-only operations always allowed
    { pattern = 'read', action = 'always' },
    { pattern = 'glob', action = 'always' },
    { pattern = 'grep', action = 'always' },
    { pattern = 'list', action = 'always' },
    { pattern = 'todoread', action = 'always' },

    -- Potentially dangerous operations need approval each time
    { pattern = 'bash', action = 'once' },
    { pattern = 'edit', action = 'once' },
    { pattern = 'write', action = 'once' },
    { pattern = 'todowrite', action = 'once' },
    { pattern = 'webfetch', action = 'once' },
    { pattern = 'task', action = 'once' },
  }

  -- Add custom rules at the beginning (higher priority)
  if custom_rules then
    for i = #custom_rules, 1, -1 do
      table.insert(rules, 1, custom_rules[i])
    end
  end

  return M.new({
    strategy = 'callback',
    rules = rules,
    callback = function()
      -- Default for unmatched tools: reject
      return 'reject'
    end,
  })
end

return M
