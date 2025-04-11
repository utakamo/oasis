#!/usr/bin/env lua

--local pattern = "^uci (set|add|add_list|del_list|delete|reorder) .+"
local patterns = {}
patterns.set = "^uci set (.+)"
patterns.add = "^uci add (.+)"
patterns.add_list = "^uci add_list (.+)"
patterns.del_list = "^uci del_list (.+)"
-- Since the execution of the uci commit command is mandatory as post-processing,
-- it does not need to be extracted from the AI's response.
-- patterns.commit = "^uci commit (.*)"
patterns.delete = "^uci delete (.+)"
patterns.reorder = "^uci reorder (.+)"

local classify_param = function(cmd, classified_param_tbl, param_chunk)

    if type(param_chunk) ~= "string" then
        return false
    end

	-- os.execute("echo " .. param_chunk .. " >> /tmp/oasis-classify.log")
	-- os.execute("echo " .. cmd .. " >> /tmp/oasis-classify.log")

    local config, section, option, value = param_chunk:match("([^%.]+)%.([^%.]+)%.([^=]+)=(.+)")

	-- uci [set|add_list|del_list] <config>.<section>.<option>=<value>
    if (cmd == "set" or cmd == "add_list" or cmd == "del_list") and (config and section and option and value) then
        classified_param_tbl.class = {config = config, section = section, option = option, value = value}
		return true
	else
		config, section, option = param_chunk:match("([^%.]+)%.([^%.]+)%.([^%.]+)")
		-- uci [delete] <config>.<section>.<option>
		if (cmd == "delete") and (config and section and option) then
			classified_param_tbl.class = {config = config, section = section, option = option}
			return true
		else
			config, section, value = param_chunk:match("([^%.]+)%.([^=]+)=(.+)")
			-- uci [set|reorder] <config>.<section>=<section-type>
			if (cmd == "set" or cmd == "reorder") and (config and section and value) then
				classified_param_tbl.class = {config = config, section = section, value = value}
				return true
			else
				-- uci [delete] <config>.<section>
				config, section = param_chunk:match("([^%.]+)%.([^%.]+)")
				if (cmd == "delete") and (config and section) then
					classified_param_tbl.class = {config = config, section = section}
					return true
				else
					config, section = param_chunk:match("([^%.]+)%s+([^%.]+)")
					-- uci [add] <config> <section-type>
					if (cmd == "add") and (config and section) then
						classified_param_tbl.class = {config = config, section = section}
						return true
					end
					-- else
						-- config = param_chunk:match("([^%.]+)")
						-- if config then
						-- 	classified_param_tbl.class = {config = config}
						-- end
					-- end
				end
			end
		end
	end

	return false
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
		-- os.execute("echo \"" .. line .. "\" >> /tmp/oasis-split.log")
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
		-- Since the execution of the uci commit command is mandatory as post-processing,
		-- it does not need to be extracted from the AI's response.
		-- commit   = {},
		delete   = {},
		reorder  = {},
	}

	for _, line in ipairs(lines) do
		for cmd, pattern in pairs(patterns) do
			local param = line:match(pattern)
			if param then
				if cmd ~= "add" then
					param:gsub("%s+", "")
				end
				uci_list[cmd][#uci_list[cmd] + 1] = {
					param = param
				}
				-- os.execute("echo \"" .. param .. "\" >> /tmp/oasis-check.log")
				break
			end
		end
	end

	return uci_list
end

local trim_line = function(line)
	local maxCount = 3
    local spaceCount = 0
    local pos = 1

	line = line:gsub("^%s+", "")

	if line:match(patterns.add) then
		maxCount = 4
	end

    while spaceCount < maxCount do
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
	for cmd, target_cmd_list in pairs(uci_list) do
		-- os.execute("echo " .. cmd .. " >> /tmp/oasis-filter.log")
		for _, target in ipairs(target_cmd_list) do
			-- os.execute("echo " .. k2 .. " >> /tmp/oasis-filter.log")
			for _, param in pairs(target) do
				-- os.execute("echo " .. k3 .. " >> /tmp/oasis-filter.log")
				local is_classify = classify_param(cmd, target, param)

				if not is_classify then
					target.param = nil
				end
			end
		end
	end

	return uci_list
end

local function check_uci_list_exist(uci_list)

	if not uci_list then
		return false
	end

	for _, params in pairs(uci_list) do
		-- os.execute("echo " .. cmd .. " >> /tmp/oasis-check-list.log")
		-- os.execute("echo " .. #params .. " >> /tmp/oasis-check-list.log")
	  if type(params) == "table" and #params > 0 then
		return true -- exist
	  end
	end
	return false -- empty
  end

return {
    uci_cmd_filter = uci_cmd_filter,
	check_uci_list_exist = check_uci_list_exist,
}