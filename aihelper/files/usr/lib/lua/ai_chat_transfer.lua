#!/usr/bin/env lua
local curl = require("cURL.safe")

local post_to_server = function(url, json, callback)
    local easy = curl.easy()
    easy:setopt_url(url)
    easy:setopt_writefunction(callback)
    easy:setopt_httppost(curl.form())
    easy:setopt_postfields(json)
    local success = easy:perform()

    if not success then
        print("Error")
        return
    end

    easy:close()
end

return {
    post_to_server = post_to_server,
}