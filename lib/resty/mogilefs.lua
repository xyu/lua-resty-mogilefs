local http = require "resty.http"

local _M = {
    _VERSION = '0.0.1'
}

local mt = { __index = _M }

function _M.new(self)
    local sock, err = ngx.socket.tcp()
    if not sock then
        return nil, 'TCP: ' .. err
    end

    return setmetatable({
        sock = sock,
        http = http.new(),
    }, mt)
end

--
-- Misc util methods
--

local function _split(inputstr, sep)
    if sep == nil then
        sep = "%s"
    end
    local t = {}
    for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
        table.insert(t, str)
    end
    return t
end

local function _mog_request(sock, action, opts)
    if not sock then
        return nil, 'TCP: not initialized'
    end

    local bytes, err = sock:send(string.format(
        "%s&%s\n",
        action,
        ngx.encode_args(opts)
    ))
    if not bytes then
        return nil, 'TCP: ' .. err
    end

    local line, err = sock:receive()
    if not line then
        if err == "timeout" then
            sock:close()
        end
        return nil, 'TCP: ' .. err
    end

    local words = _split(line);
    if words[1] == 'ERR' then
        return nil, 'MOG: ' .. line
    end

    -- Just eat any errors, this is best effort only
    local payload, err = ngx.decode_args((words[2] or ''), 0)

    return {
        status = words[1],
        payload = payload,
    }
end

--
-- Wrap cosocket util methods
--

function _M.connect(self, ...)
    if not self.sock then
        return nil, 'TCP: not initialized'
    end

    local ok, err = self.sock:connect(...)
    if not ok then
        return nil, 'TCP: ' .. err
    end

    return ok
end

function _M.set_timeouts(self, ...)
    if not self.sock then
        return nil, 'TCP: not initialized'
    end

    self.sock:settimeouts(...)
    return 1
end

function _M.set_keepalive(self, ...)
    if not self.sock then
        return nil, 'TCP: not initialized'
    end

    local ok, err = self.sock:setkeepalive(...)
    if not ok then
        return nil, 'TCP: ' .. err
    end
    return ok
end

function _M.get_reused_times(self)
    if not self.sock then
        return nil, 'TCP: not initialized'
    end

    local count, err = self.sock:getreusedtimes()
    if not count then
        return nil, 'TCP: ' .. err
    end
    return count
end

function _M.close(self)
    if not self.sock then
        return nil, 'TCP: not initialized'
    end

    local ok, err = self.sock:close()
    if not ok then
        return nil, 'TCP: ' .. err
    end
    return ok
end

--
-- MogileFS gateway methods
--

function _M.get(self, domain, key, tries)
    -- Mog will not return less then 2 paths to try
    if not tries or tries < 2 then
        tries = 2
    end

    local res, err = _mog_request(self.sock, 'GET_PATHS', {
        domain = domain,
        key = key,
        pathcount = tries,
        noverify = 1,
    })
    if not res then
        return nil, err
    end

    if not res.payload['path1'] then
        return nil, 'MOG: no paths found for key'
    end

    -- Iterate over mogstored instances until we can fetch the file
    for i = 1, tries, 1
    do
        if res.payload['path' .. i] then
            local stored, err = self.http:request_uri(res.payload['path' .. i])
            if stored and stored.status == ngx.HTTP_OK then
                return stored
            else
                return nil, err
            end
        end
    end

    return nil, 'MOG: no more paths to fetch'
end

function _M.rename(self, domain, oldkey, newkey)
    local res, err = _mog_request(self.sock, 'RENAME', {
        domain = domain,
        from_key = oldkey,
        to_key = newkey,
    })
    if not res then
        return nil, err
    end

    return res.status
end

function _M.delete(self, domain, key)
    local res, err = _mog_request(self.sock, 'DELETE', {
        domain = domain,
        key = key,
    })
    if not res then
        return nil, err
    end

    return res.status
end

function _M.put(self, domain, key, payload)
    local res_open, err = _mog_request(self.sock, 'CREATE_OPEN', {
        domain = domain,
        key = key,
        fid = 0,            -- auto generate a new fid
        multi_dest = 0,     -- TODO: maybe upload to multiple devices in future
    })
    if not res_open then
        return nil, err
    end

    -- Upload file to stored backend
    local payload_size = string.len(payload)
    local stored, err = self.http:request_uri(
        res_open.payload['path'],
        {
            method = 'PUT',
            body = payload,
            headers = {
                ["Content-Type"] = "application/x-www-form-urlencoded",
                ["Content-Length"] = payload_size,
            },
        }
    )
    if not stored then
        return nil, err
    end

    if stored.status == ngx.HTTP_CREATED then
        return _mog_request(self.sock, 'CREATE_CLOSE', {
            domain = domain,
            key = key,
            size = payload_size,
            fid = res_open.payload['fid'],
            devid = res_open.payload['devid'],
            path = res_open.payload['path'],
        })
    end

    return nil, 'MOG: failed to upload to backend'
end

return _M
