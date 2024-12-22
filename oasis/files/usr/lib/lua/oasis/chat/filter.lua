#!/usr/bin/env lua

local classify_param = function(classified_param_tbl, param_chunk)

    if type(param_chunk) ~= "string" then
        return
    end

    local config, section, option, value = param_chunk:match("([^%.]+)%.([^%.]+)%.([^=]+)=(.+)")

    if config and section and option and value then
        classified_param_tbl.class = {config = config, section = section, option = option, value = value}
    else
        config, section, value = param_chunk:match("([^%.]+)%.([^=]+)=(.+)")
        if config and section and value then
            classified_param_tbl.class = {config = config, section = section, value = value}
        else
            config, section = param_chunk:match("([^%.]+)%.([^%.]+)")
            if config and section then
                classified_param_tbl.class = {config = config, section = section}
            else
                config = param_chunk:match("([^%.]+)")
                if config then
                    classified_param_tbl.class = {config = config}
                end
            end
        end
    end
end

local extract_code_blocks = function(text)
	local code_blocks = {}
	local pattern = "```(.-)```"

	for code in text:gmatch(pattern) do
		table.insert(code_blocks, code)
	end

	return code_blocks
end

local split_lines = function(code_block)
	local lines = {}
	for line in code_block:gmatch("[^\r\n]+") do
		table.insert(lines, line)
	end

	return lines
end

local check_uci_cmd_candidate = function(lines)

	local uci_list = {
		set      = {},
		add      = {},
		add_list = {},
		commit   = {},
		delete   = {},
		reorder  = {},
	}

	--local pattern = "^uci (set|add|add_list|delete|commit) .+"
	local patterns = {}
	patterns.set = "^uci set (.+)"
	patterns.add = "^uci add (.+)"
	patterns.add_list = "^uci add_list (.+)"
	patterns.commit = "^uci commit (.*)"
	patterns.delete = "^uci delete (.+)"
	patterns.delete = "^uci reorder (.+)"

	for _, line in ipairs(lines) do
		for cmd, pattern in pairs(patterns) do
			local param = line:match(pattern)
			if param then
				param:gsub("%s+", "")
				uci_list[cmd][#uci_list[cmd] + 1] = {
					param = param
				}
				break
			end
		end
	end

	return uci_list
end

local uci_cmd_filter = function(message)

	local uci_list = nil
	local code_blocks = extract_code_blocks(message)

	for _, code in ipairs(code_blocks) do
		local lines = split_lines(code)
		uci_list = check_uci_cmd_candidate(lines)
		for _, target_cmd_list in pairs(uci_list) do
			for _, target in ipairs(target_cmd_list) do
				for _, param in pairs(target) do
					classify_param(target, param)
				end
			end
		end
	end

	return uci_list
end

return {
    uci_cmd_filter = uci_cmd_filter,
}