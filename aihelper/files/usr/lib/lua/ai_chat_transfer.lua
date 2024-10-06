#!/usr/bin/env lua
local curl = require("cURL")

local post_to_server = function(url, json, callback)
    curl.easy()
    :setopt_url(url)
    :setopt_writefunction(callback)
    :setopt_httppost(curl.form())
    :setopt_postfields(json)
    :perform()
    :close()
end

return {
    post_to_server = post_to_server,
}