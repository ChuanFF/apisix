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

local http     = require("resty.http")
local core     = require("apisix.core")

local azure_openai_embeddings = require("apisix.plugins.ai-rag.embeddings.azure_openai").schema
local openai_embeddings = require("apisix.plugins.ai-rag.embeddings.openai").schema
local azure_ai_search_schema = require("apisix.plugins.ai-rag.vector-search.azure_ai_search").schema

local HTTP_INTERNAL_SERVER_ERROR = ngx.HTTP_INTERNAL_SERVER_ERROR
local HTTP_BAD_REQUEST = ngx.HTTP_BAD_REQUEST

local schema = {
    type = "object",
    properties = {
        embeddings_provider = {
            type = "object",
            properties = {
                azure_openai = azure_openai_embeddings,
                openai = openai_embeddings
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
        rag_config = {
            type = "object",
            properties = {
                input_strategy = {
                    type = "string",
                    enum = { "last", "all" },
                    default = "last"
                },
                k = {
                    type = "integer",
                    minimum = 1,
                    default = 5
                },
                rerank = {
                    type = "object",
                    properties = {
                        enabled = { type = "boolean", default = false },
                        endpoint = { type = "string" },
                        api_key = { type = "string" },
                        model = { type = "string" },
                        top_n = { type = "integer", minimum = 1 }
                    },
                    required = { "enabled" }
                }
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

    if strategy == "last" then
        for i = #messages, 1, -1 do
            if messages[i].role == "user" then
                return messages[i].content
            end
        end
    elseif strategy == "all" then
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

local function rerank_docs(conf, docs, query, httpc)
    if not conf.enabled then
        return docs
    end

    if not docs or #docs == 0 then
        return docs
    end

    local top_n = conf.top_n or 3
    if #docs <= top_n then
        return docs
    end

    -- Construct prompt for rerank
    local doc_list_str = ""
    for i, doc in ipairs(docs) do
        -- Assuming doc is a table with 'content' or just a string?
        -- Azure Search returns table with content?
        -- azure_ai_search.lua returns res_tab.value which is a list of objects.
        -- Each object usually has 'content' field or similar.
        -- But we don't know the field name for sure.
        -- But let's assume it's JSON serialization of the doc.
        local doc_content = doc.content or core.json.encode(doc)
        doc_list_str = doc_list_str .. string.format("%d. %s\n", i, doc_content)
    end

    local prompt = string.format([[
Query: %s

Documents:
%s

Please rank the documents by relevance to the query. Return the indices of the top %d documents as a JSON array of integers, e.g. [1, 3]. Do not return any other text.
]], query, doc_list_str, top_n)

    local body = {
        messages = {
            { role = "user", content = prompt }
        },
        model = conf.model,
        temperature = 0
    }

    local body_str, err = core.json.encode(body)
    if not body_str then
        core.log.error("failed to encode rerank body: ", err)
        return docs -- fallback
    end

    local res, err = httpc:request_uri(conf.endpoint, {
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer " .. conf.api_key
        },
        body = body_str
    })

    if not res or res.status ~= 200 then
        core.log.error("rerank failed: ", err or (res and res.status))
        return docs -- fallback
    end

    local res_body = core.json.decode(res.body)
    if not res_body or not res_body.choices or #res_body.choices == 0 then
        return docs
    end

    local content = res_body.choices[1].message.content
    local indices = core.json.decode(content)
    if not indices or type(indices) ~= "table" then
        -- Try to find array in text
        local s, e = string.find(content, "%[.*%]")
        if s then
            indices = core.json.decode(string.sub(content, s, e))
        end
    end

    if not indices or type(indices) ~= "table" then
        core.log.error("failed to parse rerank indices: ", content)
        return docs
    end

    local new_docs = {}
    for _, idx in ipairs(indices) do
        local doc = docs[tonumber(idx)]
        if doc then
            core.table.insert(new_docs, doc)
        end
    end

    return new_docs
end


function _M.access(conf, ctx)
    local httpc = http.new()
    local body_tab, err = core.request.get_json_request_body_table()
    if not body_tab then
        return HTTP_BAD_REQUEST, err
    end

    -- We now assume request body is standard OpenAI chat completion body
    -- so we don't look for ai_rag field anymore.

    local embeddings_provider = next(conf.embeddings_provider)
    local embeddings_provider_conf = conf.embeddings_provider[embeddings_provider]
    local embeddings_driver = require("apisix.plugins.ai-rag.embeddings." .. embeddings_provider)

    local vector_search_provider = next(conf.vector_search_provider)
    local vector_search_provider_conf = conf.vector_search_provider[vector_search_provider]
    local vector_search_driver = require("apisix.plugins.ai-rag.vector-search." ..
                                        vector_search_provider)

    -- 1. Extract Input
    local rag_conf = conf.rag_config or {}
    local input_strategy = rag_conf.input_strategy or "last"
    local input_text = get_input_text(body_tab.messages, input_strategy)

    if not input_text then
        core.log.warn("no user input found for embedding")
        return
    end

    -- 2. Get Embeddings
    local embeddings, status, err = embeddings_driver.get_embeddings(embeddings_provider_conf,
                                                        input_text, httpc)
    if not embeddings then
        core.log.error("could not get embeddings: ", err)
        return status, err
    end

    -- 3. Vector Search
    local search_body = {
        embeddings = embeddings,
        k = rag_conf.k -- Pass k from config
    }
    -- fields is now in vector_search_provider_conf

    local docs, status, err = vector_search_driver.search(vector_search_provider_conf,
                                                        search_body, httpc)
    if not docs then
        core.log.error("could not get vector_search result: ", err)
        return status, err
    end

    -- 4. Rerank
    if rag_conf.rerank and rag_conf.rerank.enabled then
        docs = rerank_docs(rag_conf.rerank, docs, input_text, httpc)
    end

    -- 5. Inject Context
    if not body_tab.messages then
        body_tab.messages = {}
    end

    -- Format docs
    local context_str = ""
    for i, doc in ipairs(docs) do
        local content = doc.content or core.json.encode(doc)
        context_str = context_str .. content .. "\n\n"
    end

    if context_str ~= "" then
        local augment = {
            role = "user",
            content = "Context:\n" .. context_str
        }
        if #body_tab.messages > 0 then
            core.table.insert(body_tab.messages, #body_tab.messages, augment)
        else
            core.table.insert_tail(body_tab.messages, augment)
        end
    end

    local req_body_json, err = core.json.encode(body_tab)
    if not req_body_json then
        return HTTP_INTERNAL_SERVER_ERROR, err
    end

    ngx_req.set_body_data(req_body_json)
end


return _M
