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
        --table.insert(code_blocks, code:match("^%s*(.-)%s*$"))
		table.insert(code_blocks, code)
    end

	-- debug log
	-- for idx, code_block in ipairs(code_blocks) do
	--	os.execute("echo \"[" .. idx .. "] " .. code_block .. "\" >> /tmp/oasis-code.log")
	-- end

    return code_blocks
end

local split_lines = function(code_block)
	local lines = {}
	for line in code_block:gmatch("[^\r\n]+") do
		table.insert(lines, line)
	end

	-- debug long
	-- for idx, line in ipairs(lines) do
	--	os.execute("echo \"[" .. idx .. "] " .. line .. "\" >> /tmp/oasis-split.log")
	-- end

	return lines
end

local check_uci_cmd_candidate = function(lines)

	local uci_list = {
		set      = {},
		add      = {},
		add_list = {},
		del_list = {},
		commit   = {},
		delete   = {},
		reorder  = {},
	}

	--local pattern = "^uci (set|add|add_list|delete|commit) .+"
	local patterns = {}
	patterns.set = "^uci set (.+)"
	patterns.add = "^uci add (.+)"
	patterns.add_list = "^uci add_list (.+)"
	patterns.del_list = "^uci del_list (.+)"
	patterns.commit = "^uci commit (.*)"
	patterns.delete = "^uci delete (.+)"
	patterns.reorder = "^uci reorder (.+)"

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

local trim_line = function(line)
    local spaceCount = 0
    local pos = 1

	line = line:gsub("^%s+", "")

    while spaceCount < 3 do
        local start, finish = line:find("%s", pos)
        if not start then
            return line
        end
        spaceCount = spaceCount + 1
        pos = finish + 1
    end

    local trimmed = line:sub(1, pos - 2)

    return trimmed
end


local uci_cmd_filter = function(message)

	local code_blocks = extract_code_blocks(message)
	local all_lines = {}

	for _, code in ipairs(code_blocks) do
		local lines = split_lines(code)
		for _, line in ipairs(lines) do
			--os.execute("echo \"" .. line:gsub("^%s+", "") .. "\" >> /tmp/oasis-filter2.log")
			local trimmed_line = trim_line(line)
			table.insert(all_lines, trimmed_line)
		end
	end

	-- debug log
	-- for idx, line in ipairs(all_lines) do
	-- 	os.execute("echo \"[" .. idx .. "] " .. line .. "\" >> /tmp/oasis-filter.log")
	-- end

	local uci_list = check_uci_cmd_candidate(all_lines)
	for _, target_cmd_list in pairs(uci_list) do
		-- os.execute("echo " .. k1 .. " >> /tmp/oasis-filter.log")
		for _, target in ipairs(target_cmd_list) do
			-- os.execute("echo " .. k2 .. " >> /tmp/oasis-filter.log")
			for _, param in pairs(target) do
				-- os.execute("echo " .. k3 .. " >> /tmp/oasis-filter.log")
				classify_param(target, param)
			end
		end
	end

	return uci_list
end

local function check_uci_list_exist(data)

	if not data.uci_list then
		return false
	end

	for _, value in pairs(data.uci_list) do
	  if type(value) == "table" and #value > 0 then
		return true -- exist
	  end
	end
	return false -- empty
  end

return {
    uci_cmd_filter = uci_cmd_filter,
	check_uci_list_exist = check_uci_list_exist,
}