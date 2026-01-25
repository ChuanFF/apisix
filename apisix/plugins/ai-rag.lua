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
local next    = next
local require = require
local ngx_req = ngx.req
local table   = table
local string  = string
local ipairs  = ipairs

local core     = require("apisix.core")

local openai_embeddings_schema = require("apisix.plugins.ai-rag.embeddings.openai").schema
local azure_ai_search_schema = require("apisix.plugins.ai-rag.vector-search.azure_ai_search").schema
local cohere_rerank_schema = require("apisix.plugins.ai-rag.rerank.cohere").schema

local HTTP_INTERNAL_SERVER_ERROR = ngx.HTTP_INTERNAL_SERVER_ERROR
local HTTP_BAD_REQUEST = ngx.HTTP_BAD_REQUEST

local embeddings_drivers = {}
local vector_search_drivers = {}
local rerank_drivers = {}

local input_strategy = {
    last = "last",
    all = "all"
}

local schema = {
    type = "object",
    properties = {
        embeddings_provider = {
            type = "object",
            properties = {
                openai = openai_embeddings_schema
            },
            maxProperties = 1,
            minProperties = 1,
        },
        vector_search_provider = {
            type = "object",
            properties = {
                azure_ai_search = azure_ai_search_schema
            },
            maxProperties = 1,
            minProperties = 1,
        },
        rerank_provider = {
            type = "object",
            properties = {
                cohere = cohere_rerank_schema
            },
            minProperties = 1,
            maxProperties = 1,
        },
        rag_config = {
            type = "object",
            properties = {
                input_strategy = {
                    type = "string",
                    enum = { input_strategy.last, input_strategy.all },
                    default = input_strategy.last
                },
                k = {
                    type = "integer",
                    minimum = 1,
                    default = 5
                },
            },
            default = {}
        }
    },
    required = { "embeddings_provider", "vector_search_provider" }
}

local _M = {
    version = 0.1,
    priority = 1060,
    name = "ai-rag",
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


local function get_input_text(messages, strategy)
    if not messages or #messages == 0 then
        return nil
    end

    if strategy == input_strategy.last then
        for i = #messages, 1, -1 do
            if messages[i].role == "user" then
                return messages[i].content
            end
        end
    elseif strategy == input_strategy.all then
        local contents = {}
        for _, msg in ipairs(messages) do
            if msg.role == "user" then
                core.table.insert(contents, msg.content)
            end
        end
        if #contents > 0 then
            return table.concat(contents, "\n")
        end
    end
    return nil
end


local function load_driver(category, name, cache)
    local driver = cache[name]
    if driver then
        return driver
    end

    local pkg_path = "apisix.plugins.ai-rag." .. category .. "." .. name
    local ok, mod = pcall(require, pkg_path)
    if not ok then
        return nil, "failed to load module " .. pkg_path .. ", err: " .. tostring(mod)
    end

    cache[name] = mod
    return mod
end


local function inject_context_into_messages(messages, docs)
    local context_str = ""
    for _, doc in ipairs(docs) do
        local content = doc.content or core.json.encode(doc)
        context_str = context_str .. content .. "\n\n"
    end

    if context_str == "" then
        return
    end

    local augment = {
        role = "user",
        content = "Context:\n" .. context_str
    }

    if #messages > 0 then
        -- Insert context before the last message (which is typically the user's latest query)
        -- to ensure the LLM considers the context relevant to the immediate question.
        core.table.insert(messages, #messages, augment)
    else
        core.table.insert_tail(messages, augment)
    end
end


function _M.access(conf, ctx)
    local body_tab, err = core.request.get_json_request_body_table()
    if not body_tab then
        return HTTP_BAD_REQUEST, err
    end

    -- 1. Extract Input
    local rag_conf = conf.rag_config or {}
    local input_strategy = rag_conf.input_strategy or "last"
    local input_text = get_input_text(body_tab.messages, input_strategy)

    if not input_text then
        core.log.warn("no user input found for embedding")
        return
    end

    -- 2. Load Drivers
    local embeddings_provider_name = next(conf.embeddings_provider)
    local embeddings_conf = conf.embeddings_provider[embeddings_provider_name]
    local embeddings_driver, err = load_driver("embeddings", embeddings_provider_name,
            embeddings_drivers)
    if not embeddings_driver then
        core.log.error("failed to load embeddings driver: ", err)
        return HTTP_INTERNAL_SERVER_ERROR, "failed to load embeddings driver"
    end

    local vector_search_provider_name = next(conf.vector_search_provider)
    local vector_search_conf = conf.vector_search_provider[vector_search_provider_name]
    local vector_search_driver, err = load_driver("vector-search", vector_search_provider_name,
            vector_search_drivers)
    if not vector_search_driver then
        core.log.error("failed to load vector search driver: ", err)
        return HTTP_INTERNAL_SERVER_ERROR, "failed to load vector search driver"
    end

    -- 3. Get Embeddings
    local embeddings, status, err = embeddings_driver.get_embeddings(embeddings_conf, input_text)
    if not embeddings then
        core.log.error("could not get embeddings: ", err)
        return status, err
    end

    -- 4. Vector Search
    local search_body = {
        embeddings = embeddings,
        k = rag_conf.k
    }

    local docs, status, err = vector_search_driver.search(vector_search_conf, search_body)
    if not docs then
        core.log.error("could not get vector_search result: ", err)
        return status, err
    end

    -- 5. Rerank
    if conf.rerank_provider then
        local rerank_provider_name = next(conf.rerank_provider)
        local rerank_conf = conf.rerank_provider[rerank_provider_name]
        local rerank_driver, err = load_driver("rerank", rerank_provider_name, rerank_drivers)

        if not rerank_driver then
            core.log.error("failed to load rerank driver: ", err)
            -- If rerank fails to load, should we fail or proceed with original docs?
            -- Assuming fail for safety, or we could log error and skip rerank.
            -- Let's return error to be explicit.
            return HTTP_INTERNAL_SERVER_ERROR, "failed to load rerank driver"
        end

        local reranked_docs, err = rerank_driver.rerank(rerank_conf, docs, input_text)
        if reranked_docs then
            docs = reranked_docs
        else
             core.log.error("rerank failed: ", err)
             -- If rerank execution fails, we might want to fallback to original docs
             -- or return error. Let's return error for now as configured rerank failed.
             return HTTP_INTERNAL_SERVER_ERROR, "rerank failed"
        end
    end

    -- 6. Inject Context
    inject_context_into_messages(body_tab.messages, docs)

    local req_body_json, err = core.json.encode(body_tab)
    if not req_body_json then
        return HTTP_INTERNAL_SERVER_ERROR, err
    end

    ngx_req.set_body_data(req_body_json)
end


return _M
