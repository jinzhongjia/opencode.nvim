-- lua/opencode/headless/retry.lua
-- Retry mechanism for headless API

local Promise = require('opencode.promise')

local M = {}

---@class RetryConfig
---@field max_attempts? number Maximum number of attempts (default: 3)
---@field delay_ms? number Initial delay between retries in milliseconds (default: 1000)
---@field backoff? 'linear'|'exponential' Backoff strategy (default: 'exponential')
---@field max_delay_ms? number Maximum delay between retries (default: 30000)
---@field retryable_errors? string[] List of error patterns that should trigger retry
---@field on_retry? fun(attempt: number, error: any, delay: number): nil Callback on retry

-- Default retryable error patterns
local DEFAULT_RETRYABLE_ERRORS = {
  'timeout',
  'ETIMEDOUT',
  'ECONNRESET',
  'ECONNREFUSED',
  'rate.limit',
  'rate_limit',
  '429',
  '502',
  '503',
  '504',
}

---Check if an error is retryable
---@param error any The error to check
---@param patterns string[] Error patterns to match
---@return boolean
function M.is_retryable(error, patterns)
  if not error then
    return false
  end

  local error_str = type(error) == 'string' and error or vim.inspect(error)
  error_str = error_str:lower()

  for _, pattern in ipairs(patterns) do
    if error_str:find(pattern:lower(), 1, true) then
      return true
    end
  end

  return false
end

---Calculate delay for next retry
---@param attempt number Current attempt number (1-based)
---@param config RetryConfig Retry configuration
---@return number Delay in milliseconds
function M.calculate_delay(attempt, config)
  local base_delay = config.delay_ms or 1000
  local max_delay = config.max_delay_ms or 30000
  local backoff = config.backoff or 'exponential'

  local delay
  if backoff == 'exponential' then
    -- Exponential backoff: delay * 2^(attempt-1)
    delay = base_delay * math.pow(2, attempt - 1)
  else
    -- Linear backoff: delay * attempt
    delay = base_delay * attempt
  end

  -- Add jitter (±10%)
  local jitter = delay * 0.1 * (math.random() * 2 - 1)
  delay = delay + jitter

  -- Cap at max delay
  return math.min(delay, max_delay)
end

---Execute a function with retry logic
---@param fn fun(): Promise<any> Function that returns a Promise
---@param config? RetryConfig Retry configuration
---@return Promise<any>
function M.with_retry(fn, config)
  config = config or {}
  local max_attempts = config.max_attempts or 3
  local retryable_errors = config.retryable_errors or DEFAULT_RETRYABLE_ERRORS

  local function attempt(attempt_num)
    return fn():catch(function(err)
      -- Check if we should retry
      if attempt_num >= max_attempts then
        return Promise.reject(err)
      end

      if not M.is_retryable(err, retryable_errors) then
        return Promise.reject(err)
      end

      -- Calculate delay
      local delay = M.calculate_delay(attempt_num, config)

      -- Call on_retry callback if provided
      if config.on_retry then
        pcall(config.on_retry, attempt_num, err, delay)
      end

      -- Wait and retry
      local retry_promise = Promise.new()
      vim.defer_fn(function()
        attempt(attempt_num + 1)
          :and_then(function(result)
            retry_promise:resolve(result)
          end)
          :catch(function(final_err)
            retry_promise:reject(final_err)
          end)
      end, delay)

      return retry_promise
    end)
  end

  return attempt(1)
end

---Create a retry wrapper for a function
---@param config? RetryConfig Retry configuration
---@return fun(fn: fun(): Promise<any>): Promise<any>
function M.create_wrapper(config)
  return function(fn)
    return M.with_retry(fn, config)
  end
end

return M
