--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local core = require("apisix.core")
local http = require("resty.http")

local HTTP_INTERNAL_SERVER_ERROR = ngx.HTTP_INTERNAL_SERVER_ERROR
local HTTP_OK = ngx.HTTP_OK

local _M = {}


function _M.get_openai_embedding(endpoint, headers, body_tab)
    local body_str, err = core.json.encode(body_tab)
    if not body_str then
        return nil, HTTP_INTERNAL_SERVER_ERROR, err
    end

    local httpc = http.new()
    local res, err = httpc:request_uri(endpoint, {
        method = "POST",
        headers = headers,
        body = body_str
    })

    if not res then
        return nil, HTTP_INTERNAL_SERVER_ERROR, err
    end

    if res.status ~= HTTP_OK then
        return nil, res.status, res.body
    end

    local res_tab, err = core.json.decode(res.body)
    if not res_tab then
        return nil, HTTP_INTERNAL_SERVER_ERROR, err
    end

    if not res_tab.data or not res_tab.data[1] or not res_tab.data[1].embedding then
        return nil, HTTP_INTERNAL_SERVER_ERROR, "invalid response format"
    end

    return res_tab.data[1].embedding
end

return _M
