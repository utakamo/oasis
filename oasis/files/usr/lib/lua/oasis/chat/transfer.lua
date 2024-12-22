#!/usr/bin/env lua
local curl = require("cURL.safe")

local post_to_server = function(url, api_key, json, callback)
    local easy = curl.easy()
    easy:setopt_url(url)
    easy:setopt_writefunction(callback)
    if api_key and (type(api_key) == "string") and (#api_key > 0) then
        easy:setopt_httpheader({
            "Content-Type: application/json",
            "Authorization: Bearer " .. api_key
        })
    end
    easy:setopt_httppost(curl.form())
    easy:setopt_postfields(json)
    local success = easy:perform()

    if not success then
        print("\27[31m" .. "Error" .. "\27[0m")
    end

    easy:close()
end

return {
    post_to_server = post_to_server,
}