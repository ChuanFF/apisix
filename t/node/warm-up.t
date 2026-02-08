#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

use t::APISIX 'no_plan';

repeat_each(1);
log_level('warn');
no_root_location();
no_shuffle();

run_tests();

__DATA__

=== TEST 1: create upstream with single node (starts warm-up)
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test

            -- 1. Create Upstream
            local code, body = t('/apisix/admin/upstreams/1',
                 ngx.HTTP_PUT,
                 [[{
                    "id": "1",
                    "type": "roundrobin",
                    "nodes": [
                        {"host": "127.0.0.1", "port": 1980, "weight": 100, "update_time": ]] .. ngx.time() - 5 .. [[}
                    ],
                    "warm_up_conf": {
                        "slow_start_time_seconds": 5,
                        "min_weight": 0.01,
                        "refresh_interval": 1,
                        "aggression": 1.0
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
                ngx.say("upstream failed: ", body)
                return
            end

            -- 2. Create Route using Upstream
            code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "uri": "/server_port",
                    "upstream_id": "1"
                }]]
            )

            if code >= 300 then
                ngx.status = code
                ngx.say("route failed: ", body)
                return
            end
            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 2: add new node (auto-detects as new and warms up)
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            -- We update the upstream with a new node.
            -- The existing node (1980) should preserve its update_time (so it stays fully warmed).
            -- The new node (1981) should get a new update_time (so it starts warming up).
            local code, body = t('/apisix/admin/upstreams/1',
                 ngx.HTTP_PUT,
                 [[{
                    "id": "1",
                    "type": "roundrobin",
                    "nodes": [
                        {"host": "127.0.0.1", "port": 1980, "weight": 100},
                        {"host": "127.0.0.1", "port": 1981, "weight": 100}
                    ],
                    "warm_up_conf": {
                        "slow_start_time_seconds": 5,
                        "min_weight": 0.01,
                        "refresh_interval": 1,
                        "aggression": 1.0
                    }
                }]]
            )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 3: verify warm-up traffic skew (Node 1980 >> Node 1981)
--- timeout: 20
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.http"
            local uri = "http://127.0.0.1:" .. ngx.var.server_port
                        .. "/server_port"

            local ports_count = {}
            -- Node 1980: fully warmed (weight 100)
            -- Node 1981: just started (weight ~1)

            for i = 1, 100 do
                local httpc = http.new()
                local res, err = httpc:request_uri(uri, {method = "GET"})
                if not res then
                    ngx.say(err)
                    return
                end
                ports_count[res.body] = (ports_count[res.body] or 0) + 1
            end

            local count_80 = ports_count["1980"] or 0
            local count_81 = ports_count["1981"] or 0

            ngx.log(ngx.INFO, "Warm-up check: 1980=", count_80, ", 1981=", count_81)

            -- Expect heavy skew to 1980
            if count_80 > 80 and count_81 < 20 then
                ngx.say("passed")
            else
                ngx.say("failed: 1980=" .. count_80 .. ", 1981=" .. count_81)
            end
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 4: wait for warm-up to complete
--- config
    location /t {
        content_by_lua_block {
            local upstream = require("apisix.upstream").get_by_id("1")

            if upstream and upstream.nodes then
                local max_update_time = 0
                for _, node in ipairs(upstream.nodes) do
                    if node.update_time and node.update_time > max_update_time then
                        max_update_time = node.update_time
                    end
                end

                if max_update_time > 0 then
                    local now = ngx.time()
                    local warm_up_duration = upstream.warm_up_conf.slow_start_time_seconds
                    local elapsed = now - max_update_time

                    if elapsed < warm_up_duration then
                        ngx.sleep(warm_up_duration - elapsed + 0.5) -- Add 0.5s buffer
                    end
                end
            else
                ngx.say("cannot find upstream id: 1")
            end

            ngx.say("passed")
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 5: verify balanced traffic after warm-up
--- timeout: 20
--- config
    location /t {
        content_by_lua_block {
            local http = require "resty.http"
            local uri = "http://127.0.0.1:" .. ngx.var.server_port
                        .. "/server_port"

            local ports_count = {}

            for i = 1, 100 do
                local httpc = http.new()
                local res, err = httpc:request_uri(uri, {method = "GET"})
                if not res then
                    ngx.say(err)
                    return
                end
                ports_count[res.body] = (ports_count[res.body] or 0) + 1
            end

            local count_80 = ports_count["1980"] or 0
            local count_81 = ports_count["1981"] or 0

            ngx.log(ngx.INFO, "Balanced check: 1980=", count_80, ", 1981=", count_81)

            -- Expect balanced traffic
            if count_80 > 30 and count_81 > 30 then
                ngx.say("passed")
            else
                ngx.say("failed: 1980=" .. count_80 .. ", 1981=" .. count_81)
            end
        }
    }
--- request
GET /t
--- response_body
passed
