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
local utils = require("apisix.plugins.ai-rag.utils")

local _M = {}

_M.schema = {
    type = "object",
    properties = {
        endpoint = {
            type = "string",
        },
        api_key = {
            type = "string",
        },
    },
    required = { "endpoint", "api_key" }
}

function _M.get_embeddings(conf, input)
    local headers = {
        ["Content-Type"] = "application/json",
        ["api-key"] = conf.api_key,
    }
    local body = {
        input = input
    }
    return utils.get_openai_embedding(conf.endpoint, headers, body)
end

return _M
