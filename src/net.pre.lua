local json = require('json')
local mime = require('mime')
local socket = require('socket')

local errors = require('./errors')
local util = require('./util')

-- Import some names to this namespace for convienience
local is_instance = util.is_instance
local class = util.class

local Connection, Cursor

function bytes_to_int(str)
  local t = {str:byte(1,-1)}
  local n = 0
  for k=1,#t do
    n = n + t[k] * 2 ^ ((k - 1) * 8)
  end
  return n
end

function div_mod(num, den)
  return math.floor(num / den), math.fmod(num, den)
end

function int_to_bytes(num, bytes)
  local res = {}
  local mul = 0
  for k=bytes,1,-1 do
    res[k], num = div_mod(num, 2 ^ (8 * (k - 1)))
  end
  return string.char(unpack(res))
end

function convert_pseudotype(obj, opts)
  -- An R_OBJECT may be a regular object or a 'pseudo-type' so we need a
  -- second layer of type switching here on the obfuscated field '$reql_type$'
  local _exp_0 = obj['$reql_type$']
  if 'TIME' == _exp_0 then
    local _exp_1 = opts.time_format
    if 'native' == _exp_1 or not _exp_1 then
      if not (obj['epoch_time']) then
        error(err.ReQLDriverError('pseudo-type TIME ' .. tostring(obj) .. ' object missing expected field `epoch_time`.'))
      end

      -- We ignore the timezone field of the pseudo-type TIME object. JS dates do not support timezones.
      -- By converting to a native date object we are intentionally throwing out timezone information.

      -- field 'epoch_time' is in seconds but the Date constructor expects milliseconds
      return (Date(obj['epoch_time'] * 1000))
    elseif 'raw' == _exp_1 then
      -- Just return the raw (`{'$reql_type$'...}`) object
      return obj
    else
      error(err.ReQLDriverError('Unknown time_format run option ' .. tostring(opts.time_format) .. '.'))
    end
  elseif 'GROUPED_DATA' == _exp_0 then
    local _exp_1 = opts.group_format
    if 'native' == _exp_1 or not _exp_1 then
      -- Don't convert the data into a map, because the keys could be objects which doesn't work in JS
      -- Instead, we have the following format:
      -- [ { 'group': <group>, 'reduction': <value(s)> } }, ... ]
      res = {}
      j = 1
      for i, v in ipairs(obj['data']) do
        res[j] = {
          group = i,
          reduction = v
        }
        j = j + 1
      end
      obj = res
    elseif 'raw' == _exp_1 then
      return obj
    else
      error(err.ReQLDriverError('Unknown group_format run option ' .. tostring(opts.group_format) .. '.'))
    end
  elseif 'BINARY' == _exp_0 then
    local _exp_1 = opts.binary_format
    if 'native' == _exp_1 or not _exp_1 then
      if not obj.data then
        error(err.ReQLDriverError('pseudo-type BINARY object missing expected field `data`.'))
      end
      return (mime.unb64(obj.data))
    elseif 'raw' == _exp_1 then
      return obj
    else
      error(err.ReQLDriverError('Unknown binary_format run option ' .. tostring(opts.binary_format) .. '.'))
    end
  else
    -- Regular object or unknown pseudo type
    return obj
  end
end

function recursively_convert_pseudotype(obj, opts)
  if type(obj) == 'table' then
    for key, value in pairs(obj) do
      obj[key] = recursively_convert_pseudotype(value, opts)
    end
    obj = convert_pseudotype(obj, opts)
  end
  return obj
end

Cursor = class(
  'Cursor',
  {
    __init = function(self, conn, token, opts, root)
      self._conn = conn
      self._token = token
      self._opts = opts
      self._root = root -- current query
      self._responses = { }
      self._response_index = 1
      self._cont_flag = true
    end,
    _add_response = function(self, response)
      local t = response.t
      if not self._type then self._type = t end
      if response.r[1] or --[[Response.WAIT_COMPLETE]] == t then
        table.insert(self._responses, response)
      end
      if --[[Response.SUCCESS_PARTIAL]] ~= t and --[[Response.SUCCESS_FEED]] ~= t then
        -- We got an error, SUCCESS_SEQUENCE, WAIT_COMPLETE, or a SUCCESS_ATOM
        self._end_flag = true
      end
      self._cont_flag = false
    end,
    _prompt_cont = function(self)
      if self._end_flag then return end
      -- Let's ask the server for more data if we haven't already
      if not self._cont_flag then
        self._cont_flag = true
        self._conn:_continue_query(self._token)
      end
      self._conn:_get_response(self._token)
    end,
    -- Implement IterableResult
    next = function(self, cb)
      -- Try to get a row out of the responses
      while not self._responses[1] do
        if self._end_flag then
          return cb(errors.ReQLDriverError('No more rows in the cursor.'))
        end
        self:_prompt_cont()
      end
      local response = self._responses[1]
      -- Behavior varies considerably based on response type
      -- Error responses are not discarded, and the error will be sent to all future callbacks
      local t = response.t
      if --[[Response.SUCCESS_ATOM]] == t or --[[Response.SUCCESS_PARTIAL]] == t or --[[Response.SUCCESS_FEED]] == t or --[[Response.SUCCESS_SEQUENCE]] == t then
        local row = recursively_convert_pseudotype(response.r[self._response_index], self._opts)
        self._response_index = self._response_index + 1

        -- If we're done with this response, discard it
        if not response.r[self._response_index] then
          table.remove(self._responses, 1)
          self._response_index = 1
        end
        return cb(nil, row)
      elseif --[[Response.COMPILE_ERROR]] == t then
        return cb(errors.ReQLCompileError(response.r[1], self._root, response.b))
      elseif --[[Response.CLIENT_ERROR]] == t then
        return cb(errors.ReQLClientError(response.r[1], self._root, response.b))
      elseif --[[Response.RUNTIME_ERROR]] == t then
        return cb(errors.ReQLRuntimeError(response.r[1], self._root, response.b))
      elseif --[[Response.WAIT_COMPLETE]] == t then
        return cb(nil, nil)
      end
      return cb(errors.ReQLDriverError('Unknown response type ' .. t))
    end,
    close = function(self, cb)
      if not self._end_flag then
        self._conn:_end_query(self._token)
      end
      if cb then return cb() end
    end,
    each = function(self, cb, on_finished)
      if type(cb) ~= 'function' then
        error(errors.ReQLDriverError('First argument to each must be a function.'))
      end
      if on_finished and type(on_finished) ~= 'function' then
        error(errors.ReQLDriverError('Optional second argument to each must be a function.'))
      end
      function next_cb(err, data)
        if err then
          if err.message ~= 'ReQLDriverError No more rows in the cursor.' then
            return cb(err)
          end
          if on_finished then
            return on_finished()
          end
        else
          cb(nil, data)
          return self:next(next_cb)
        end
      end
      return self:next(next_cb)
    end,
    to_array = function(self, cb)
      if not self._type then self:_prompt_cont() end
      if self._type == --[[Response.SUCCESS_FEED]] then
        return cb(errors.ReQLDriverError('`to_array` is not available for feeds.'))
      end
      local arr = {}
      return self:each(
        function(err, row)
          if err then
            return cb(err)
          end
          table.insert(arr, row)
        end,
        function()
          return cb(nil, arr)
        end
      )
    end,
  }
)

Connection = class(
  'Connection',
  {
    __init = function(self, host, callback)
      if not (host) then
        host = { }
      else
        if type(host) == 'string' then
          host = {
            host = host
          }
        end
      end
      self.host = host.host or self.DEFAULT_HOST
      self.port = host.port or self.DEFAULT_PORT
      self.db = host.db -- left nil if this is not set
      self.auth_key = host.auth_key or self.DEFAULT_AUTH_KEY
      self.timeout = host.timeout or self.DEFAULT_TIMEOUT
      self.outstanding_callbacks = { }
      self.next_token = 1
      self.open = false
      self.buffer = ''
      self._events = self._events or { }
      local err_callback = function(self, e)
        self:remove_listener('connect', con_callback)
        if is_instance(errors.ReQLDriverError, e) then
          return callback(e)
        else
          return callback(errors.ReQLDriverError('Could not connect to ' .. tostring(self.host) .. ':' .. tostring(self.port) .. '.\n' .. tostring(e.message)))
        end
      end
      if self.raw_socket then
        self:close({
          noreply_wait = false
        })
      end
      self.raw_socket = socket.tcp()
      self.raw_socket:settimeout(self.timeout)
      local status, err = self.raw_socket:connect(self.host, self.port)
      if status then
        -- Initialize connection with magic number to validate version
        self.raw_socket:send(
          int_to_bytes(--[[Version.V0_3]], 4) ..
          int_to_bytes(self.auth_key:len(), 4) ..
          self.auth_key ..
          int_to_bytes(--[[Protocol.JSON]], 4)
        )

        -- Now we have to wait for a response from the server
        -- acknowledging the connection
        while 1 do
          buf, err, partial = self.raw_socket:receive(8)
          buf = buf or partial
          if buf then
            self.buffer = self.buffer .. buf
          else
            return callback(errors.ReQLDriverError('Could not connect to ' .. tostring(self.host) .. ':' .. tostring(self.port) .. '.\n' .. tostring(e)))
          end
          i, j = buf:find('\0')
          if i then
            local status_str = self.buffer:sub(1, i - 1)
            self.buffer = self.buffer:sub(i + 1)
            if status_str == 'SUCCESS' then
              -- We're good, finish setting up the connection
              self.open = true
              local res = callback(nil, self)
              self:close({noreply_wait = false})
              return res
            else
              return callback(errors.ReQLDriverError('Server dropped connection with message: \'' + status_str + '\''))
            end
          end
        end
      end
    end,
    DEFAULT_HOST = 'localhost',
    DEFAULT_PORT = 28015,
    DEFAULT_AUTH_KEY = '',
    DEFAULT_TIMEOUT = 20, -- In seconds
    _get_response = function(self, reqest_token)
      local response_length = 0
      local token = 0
      local buf, err, partial
      -- Buffer data, execute return results if need be
      while true do
        buf, err, partial = self.raw_socket:receive(1024)
        buf = buf or partial
        if (not buf) and err then
          error(errors.ReQLDriverError('connection returned: ' .. err))
        end
        self.buffer = self.buffer .. buf
        if response_length > 0 then
          if string.len(self.buffer) >= response_length then
            local response_buffer = string.sub(self.buffer, 1, response_length)
            self.buffer = string.sub(self.buffer, response_length + 1)
            response_length = 0
            self:_process_response(json.decode(response_buffer), token)
            if token == reqest_token then return end
          end
        else
          if string.len(self.buffer) >= 12 then
            token = bytes_to_int(self.buffer:sub(1, 8))
            response_length = bytes_to_int(self.buffer:sub(9, 12))
            self.buffer = self.buffer:sub(13)
          end
        end
      end
    end,
    _del_query = function(self, token)
      -- This query is done, delete this cursor
      self.outstanding_callbacks[token] = {}
    end,
    _process_response = function(self, response, token)
      local profile = response.p
      if self.outstanding_callbacks[token] then
        local root, cursor, opts
        do
          local _obj_0 = self.outstanding_callbacks[token]
          root, cursor, opts = _obj_0.root, _obj_0.cursor, _obj_0.opts
        end
        if cursor then
          cursor:_add_response(response)
          if cursor._end_flag and cursor._outstanding_requests == 0 then
            return self:_del_query(token)
          end
        end
      else
        -- Unexpected token
        return error(errors.ReQLDriverError('Unexpected token ' .. token .. '.'))
      end
    end,
    close = function(self, opts_or_callback, callback)
      local opts = {}
      local cb
      if callback then
        if type(opts_or_callback) ~= 'table' then
          error(errors.ReQLDriverError('First argument to two-argument `close` must be an object.'))
        end
        opts = opts_or_callback
        cb = callback
      else
        if type(opts_or_callback) == 'table' then
          opts = opts_or_callback
        else
          if type(opts_or_callback) == 'function' then
            cb = opts_or_callback
          end
        end
      end

      if cb and type(cb) ~= 'function' then
        error(errors.ReQLDriverError('First argument to two-argument `close` must be an object.'))
      end

      local wrapped_cb = function(...)
        self.open = false
        self.raw_socket:shutdown()
        self.raw_socket:close()
        if cb then
          return cb(...)
        end
      end

      local noreply_wait = opts.noreply_wait and self.open

      if noreply_wait then
        return self:noreply_wait(wrapped_cb)
      end
      return wrapped_cb()
    end,
    noreply_wait = function(self, cb)
      function callback(err, cur)
        if cur then
          return cur.next(function(err) return cb(err) end)
        end
        if type(cb) == 'function' then return cb(err) end
      end
      if not self.open then
        return callback(errors.ReQLDriverError('Connection is closed.'))
      end

      -- Assign token
      local token = self.next_token
      self.next_token = self.next_token + 1

      -- Construct query
      local query = { }
      query.type = --[[Query.NOREPLY_WAIT]]
      query.token = token

      -- Save callback
      local cursor = Cursor(self, token, query.global_optargs, term)

      -- Save callback
      do
        local callback = {
          cursor = cursor
        }
        self.outstanding_callbacks[token] = callback
      end
      self:_send_query(query)

      if type(cb) == 'function' then
        local res = cb(nil, cursor)
        cursor:close()
        return res
      end
      self.outstanding_callbacks[token] = {
        cb = callback,
        root = nil,
        opts = nil
      }
      return self:_send_query(query)
    end,
    _write_query = function(self, token, data)
      self.raw_socket:send(
        int_to_bytes(token, 8) ..
        int_to_bytes(#data, 4) ..
        data
      )
    end,
    cancel = function(self)
      self.raw_socket.destroy()
      self.outstanding_callbacks = { }
    end,
    reconnect = function(self, opts_or_callback, callback)
      if callback then
        local opts = opts_or_callback
        local cb = callback
      else
        if type(opts_or_callback) == 'function' then
          local opts = { }
          local cb = opts_or_callback
        else
          if opts_or_callback then
            local opts = opts_or_callback
          else
            local opts = { }
          end
          local cb = callback
        end
      end
      local close_cb = function(self, err)
        if err then
          return cb(err)
        else
          local construct_cb = function(self)
            return Connection({
              host = self.host,
              port = self.port,
              db = self.db,
              auth_key = self.auth_key,
              timeout = self.timeout
            }, cb)
          end
          return set_timeout(construct_cb, 0)
        end
      end
      return self:close(opts, close_cb)
    end,
    use = function(self, db)
      self.db = db
    end,
    _start = function(self, term, cb, opts)
      if not (self.open) then
        cb(errors.ReQLDriverError('Connection is closed.'))
      end

      -- Assign token
      local token = self.next_token
      self.next_token = self.next_token + 1

      -- Construct query
      local query = { }
      query.global_optargs = opts
      query.type = --[[Query.START]]
      query.query = term:build()
      query.token = token
      -- Set global options
      if self.db then
        query.global_optargs.db = {--[[Term.DB]], {self.db}}
      end

      local cursor = Cursor(self, token, query.global_optargs, term)

      -- Save callback
      self.outstanding_callbacks[token] = {
      root = term,
        opts = opts,
        cursor = cursor
      }
      self:_send_query(query)
      if type(cb) == 'function' and not opts.noreply then
        local res = cb(nil, cursor)
        cursor:close()
        return res
      end
    end,
    _continue_query = function(self, token)
      return self:_write_query(token, json.encode({--[[Query.CONTINUE]]}))
    end,
    _end_query = function(self, token)
      return self:_write_query(token, json.encode({--[[Query.STOP]]}))
    end,
    _send_query = function(self, query)
      -- Serialize query to JSON
      local data = {query.type}
      if query.query then
        data[2] = query.query
        if #query.global_optargs > 0 then
          data[3] = query.global_optargs
        end
      end
      self:_write_query(query.token, json.encode(data))
    end
  }
)

return {
  is_connection = function(connection)
    return is_instance(Connection, connection)
  end,

  -- The main function of this module
  connect = function(host_or_callback, callback)
    local host = {}
    if type(host_or_callback) == 'function' then
      callback = host_or_callback
    else
      host = host_or_callback
    end
    return Connection(host, callback)
  end
}