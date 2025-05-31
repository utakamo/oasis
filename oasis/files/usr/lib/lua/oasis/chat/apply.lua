#!/usr/bin/env lua

local jsonc     = require("luci.jsonc")
local util      = require("luci.util")
local uci       = require("luci.model.uci").cursor()
local sys       = require("luci.sys")
local common    = require("oasis.common")
local misc      = require("oasis.chat.misc")
local debug     = require("oasis.chat.debug")

local enqueue_rollback_data = function(data)

    debug:log("oasis.log", "\n--- [apply.lua][enqueue_rollback_data] ---")

    misc.write_file(common.rollback.dir .. common.rollback.uci_cmd_json, data)

    debug:log("oasis.log", "write: " .. common.rollback.dir .. common.rollback.uci_cmd_json)
    debug:log("oasis.log", "data: " .. data)

    local target_uci_list = uci:get_list(common.db.uci.cfg, common.db.uci.sect.rollback, "targets")
    local rollback_list = uci:get_list(common.db.uci.cfg, common.db.uci.sect.rollback, "list")

    debug:log("oasis.log", "<target uci list>")
    debug:dump("oasis.log", target_uci_list)
    debug:log("oasis.log", "<rollback list>")
    debug:dump("oasis.log", rollback_list)

    local index = #rollback_list + 1

    if (index < 10) then
        debug:log("oasis.log", "First enqueue!!")
        rollback_list[index] = common.rollback.list_item_name .. index

        for _, config in ipairs(target_uci_list) do
            local src = common.rollback.dir .. config
            local dest = common.rollback.dir .. rollback_list[index] .. "/" .. config
            debug:log("oasis.log", "[Copy File 1] src: " .. src .. ", dest: " .. dest)
            misc.copy_file(src, dest)
        end

        local src = common.rollback.dir .. common.rollback.uci_cmd_json
        local dest = common.rollback.dir .. rollback_list[index] .. "/" .. common.rollback.uci_cmd_json
        debug:log("oasis.log", "[Copy File 2] src: " .. src .. ", dest: " .. dest)
        misc.copy_file(src, dest)

        local backup_uci_list = jsonc.stringify(target_uci_list)
        local filename = common.rollback.dir .. rollback_list[index] .. "/" .. common.rollback.backup_uci_list
        debug:log("oasis.log", "backup_uci_list: " .. backup_uci_list)
        debug:log("oasis.log", "filename: " .. filename)
        misc.write_file(filename, backup_uci_list)

        uci:set_list(common.db.uci.cfg, common.db.uci.sect.rollback, "list", rollback_list)
        uci:commit(common.db.uci.cfg)
    else
        for i = 1, 10 do
            if i == 1 then
                local list = misc.read_file(common.rollback.dir .. rollback_list[i] .. common.rollback.backup_uci_list)
                debug:log("oasis.log", "list: " .. list)
                local delete_uci_list = jsonc.parse(list)
                for _, cfg in ipairs(delete_uci_list) do
                    os.remove(common.rollback.dir .. rollback_list[i] .. "/" .. cfg)
                end
                os.remove(common.rollback.dir .. rollback_list[i] .. common.rollback.backup_uci_list)
                os.remove(common.rollback.dir .. rollback_list[i] .. common.rollback.uci_cmd_json)
            else
                local src = common.rollback.dir .. rollback_list[i] .. "/" .. common.rollback.uci_cmd_json
                local dest = common.rollback.dir .. rollback_list[i - 1] .. "/" .. common.rollback.uci_cmd_json
                debug:log("oasis.log", "[Copy File 3] src: " .. src .. ", dest: " .. dest)
                misc.copy_file(src, dest)

                src = common.rollback.dir .. rollback_list[i] .. "/" .. common.rollback.backup_uci_list
                dest = common.rollback.dir .. rollback_list[i - 1] .. "/" .. common.rollback.backup_uci_list
                debug:log("oasis.log", "[Copy File 4] src: " .. src .. ", dest: " .. dest)
                misc.copy_file(src, dest)

                local backup_list = misc.read_file(src)
                for _, cfg in ipairs(backup_list) do
                    src = common.rollback.dir .. rollback_list[i] .. "/" .. cfg
                    dest = common.rollback.dir .. rollback_list[i - 1] .. "/" ..cfg
                    debug:log("oasis.log", "[Copy File 5] src: " .. src .. ", dest: " .. dest)
                    misc.copy_file(src, dest)
                end
            end
        end
    end
end

local rollback_target_data = function(index)

    debug:log("oasis.log", "\n--- [apply.lua][rollback_target_data] ---")
    debug:log("oasis.log", "index: " .. index)

    local rollback_list = uci:get_list(common.db.uci.cfg, common.db.uci.sect.rollback, "list")
    local restored_list = {}

    debug:dump("oasis.log", rollback_list)

    -- Rollback data (core process)
    for i = index, #rollback_list do
        debug:log("oasis.log", "i = " .. i)
        debug:log("oasis.log", "#rollback_list = " .. #rollback_list)
        local file = common.rollback.dir .. rollback_list[i] .. "/" .. common.rollback.backup_uci_list
        debug:log("oasis.log", "file: " .. file)
        local rollback_target_json = misc.read_file(file)
        debug:log("oasis.log", "rollback_target_json: " .. rollback_target_json)
        local rollback_target_tbl = jsonc.parse(rollback_target_json)
        debug:dump("oasis.log", rollback_target_tbl)
        for _, cfg in ipairs(rollback_target_tbl) do

            local is_restored = false
            for _, restored_cfg in ipairs(restored_list) do
                if cfg == restored_cfg then
                    debug:log("oasis.log", "The following setting has been rolled back: " .. cfg)
                    is_restored = true
                    break
                end
            end

            if not is_restored then
                -- rollback uci config
                sys.exec("uci -f " .. common.rollback.dir .. rollback_list[i] .. "/" .. cfg .. " import " .. cfg)
                debug:log("oasis.log", "rollback ---> " .. cfg)
                restored_list[#restored_list + 1] = cfg
            end
        end
    end

    -- Delete unnecessary rollback data (/etc/oasis/backup/list*)
    for i = index, #rollback_list do
        debug:log("oasis.log", "Delete unnecessary settings for rollback.")
        local delete_uci_list_file = common.rollback.dir .. rollback_list[i] .. "/" .. common.rollback.backup_uci_list
        local delete_uci_list_json = misc.read_file(delete_uci_list_file)
        local delete_uci_list_tbl = jsonc.parse(delete_uci_list_json)
        local delete_uci_cmd_json = common.rollback.dir .. rollback_list[i] .. "/" .. common.rollback.uci_cmd_json
        for _, cfg in ipairs(delete_uci_list_tbl) do
            os.remove(common.rollback.dir .. rollback_list[i] .. "/" .. cfg)
            debug:log("oasis.log", "Delete ---> " .. common.rollback.dir .. rollback_list[i] .. "/" .. cfg)
        end
        os.remove(delete_uci_list_file)
        os.remove(delete_uci_cmd_json)
        debug:log("oasis.log", "Delete ---> " .. delete_uci_list_file)
        debug:log("oasis.log", "Delete ---> " .. delete_uci_cmd_json)
    end

    -- Update uci config
    local update_rollback_dir_list = {}

    for i = 1, (index - 1) do
        update_rollback_dir_list[#update_rollback_dir_list + 1] = common.rollback.list_item_name .. i
        debug:log("oasis.log", "update_rollback_dir_list[" .. (#update_rollback_dir_list + 1) .. "] = " .. common.rollback.list_item_name .. i)
    end

    uci:set_list(common.db.uci.cfg, common.db.uci.sect.rollback, "list", update_rollback_dir_list)
    uci:commit(common.db.uci.cfg)

    return true
end

local get_rollback_data_list = function()

    debug:log("oasis.log", "\n--- [apply.lua][get_rollback_data_list] ---")
    local rollback_child_dirs = uci:get_list(common.db.uci.cfg, common.db.uci.sect.rollback, "list")
    local is_rollback_confirm = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.rollback, "confirm")
    local rollback_data_list = {}

    for i = 1, #rollback_child_dirs do

        if (i == #rollback_child_dirs) and (is_rollback_confirm) then
            debug:log("oasis.log", "User is confirming the settings. Latest rollback data is excluded from the list.")
            break
        end

        local base_path = common.rollback.dir .. rollback_child_dirs[i] .. "/"
        local uci_file = base_path .. common.rollback.uci_cmd_json
        local backup_uci_list = base_path .. common.rollback.backup_uci_list

        debug:log("oasis.log", "uci_file: " .. uci_file)
        debug:log("oasis.log", "backup_uci_list: " .. backup_uci_list)

        local uci_stat = io.open(uci_file, "r")
        local backup_stat = io.open(backup_uci_list, "r")

        if uci_stat and backup_stat then
            uci_stat:close()
            backup_stat:close()

            local rollback_data_json = misc.read_file(uci_file)
            local rollback_data_tbl = jsonc.parse(rollback_data_json)

            rollback_data_list[#rollback_data_list + 1] = rollback_data_tbl
        else
            if uci_stat then uci_stat:close() end
            if backup_stat then backup_stat:close() end
        end
    end

    return rollback_data_list
end

local create_new_backup_data = function(uci_list, id, backup_type)

    local list = {}

    if backup_type == "normal" then
        local backup_target_cfg = {}
        for _, target_cmd_tbl in pairs(uci_list) do
            -- for debug
            -- sys.exec("echo " .. key .. " >> /tmp/oasis-backup.log")
            -- sys.exec("echo " .. #target_cmd_tbl .. " >> /tmp/oasis-backup.log")
            -- sys.exec("echo " .. type(target_cmd_tbl) .. " >> /tmp/oasis-backup.log")
            if (type(target_cmd_tbl) == "table") and (#target_cmd_tbl > 0) then
                -- sys.exec("echo table >> /tmp/oasis-backup.log")
                for _, cmd in ipairs(target_cmd_tbl) do
                    local is_exist = false
                    for _, config in ipairs(backup_target_cfg) do
                        -- sys.exec("echo " .. cmd.class.config .. " >> /tmp/oasis-backup.log")
                        if cmd.class.config == config then
                            is_exist = true
                        end
                    end

                    if not is_exist then
                        backup_target_cfg[#backup_target_cfg + 1] = cmd.class.config
                    end
                end
            end
        end

        local app = util.ubus("uci", "configs", {})
        for _, config in ipairs(backup_target_cfg) do
            for _, config_in_list in ipairs(app.configs) do
                -- Verify whether the target config name matches the actual OpenWrt config name
                if config_in_list == config then
                    sys.exec("uci export " .. config .. " > /etc/oasis/backup/" .. config)
                    list[#list + 1] = config
                end
            end
        end
    elseif backup_type == "full" then
        sys.exec("uci export > /etc/oasis/backup/full_backup")
        list[#list + 1] = "full_backup"
    else
        return false
    end

    if #list > 0 then
        uci:set(common.db.uci.cfg, common.db.uci.sect.rollback, "confirm", "1")
        uci:set(common.db.uci.cfg, common.db.uci.sect.rollback, "src_id", id)
        uci:set_list(common.db.uci.cfg, common.db.uci.sect.rollback, "targets", list)

        local uci_list_json = jsonc.stringify(uci_list)
        enqueue_rollback_data(uci_list_json)

        for _, config in ipairs(list) do
            uci:commit(config)
        end

        local system_info = util.ubus("system", "info", {})
        local uptime = system_info.uptime
        uci:set(common.db.uci.cfg, common.db.uci.sect.rollback, "uptime", uptime)
        uci:commit(common.db.uci.cfg)

        return true
    end

    return false
end

local complete = function()
    uci:set(common.db.uci.cfg, common.db.uci.sect.rollback, "confirm", "0")
    uci:commit(common.db.uci.cfg)
end

local rollback = function()

    debug:log("oasis.log", "\n--- [apply.lua][rollback] ---")

    local is_rollback_confirm = uci:get(common.db.uci.cfg, common.db.uci.sect.rollback, "confirm")

    if not is_rollback_confirm then
        debug:log("oasis.log", "rollback invalid")
        return
    end

    uci:set(common.db.uci.cfg, common.db.uci.sect.rollback, "confirm", "0")

    local target_uci_list = uci:get_list(common.db.uci.cfg, common.db.uci.sect.rollback, "targets")

    if #target_uci_list == 0 then
        debug:log("oasis.log", "No Backup List")
        return
    end

    -- [Delete Target Rollback Data]
    -- Rollback ---> /etc/backup/<previous uci configs>
    for _, cfg in ipairs(target_uci_list) do
        local rollback = "uci -f " .. common.rollback.dir .. cfg .. " import " .. cfg
        debug:log("oasis.log", "uci cmd: " .. rollback)
        sys.exec(rollback)
    end

    -- Delete unnecessary current rollback data (/etc/backup/<previous uci configs>)
    for _, cfg in ipairs(target_uci_list) do
        debug:log("oasis.log", "Remove: " .. common.rollback.dir .. cfg)
        os.remove(common.rollback.dir .. cfg)
    end

    -- Delete unnecessary current rollback data (/etc/backup/<uci_cmd_json>)
    debug:log("oasis.log", "Remove: " .. common.rollback.dir .. common.rollback.uci_cmd_json)
    os.remove(common.rollback.dir .. common.rollback.uci_cmd_json)

    uci:delete(common.db.uci.cfg, common.db.uci.sect.rollback, "targets")

    -- Delete unnecessary rollback data in list (/etc/backup/list*/~)
    local rollback_list = uci:get_list(common.db.uci.cfg, common.db.uci.sect.rollback, "list")
    local rollback_data_dir = common.rollback.dir .. rollback_list[#rollback_list] .."/"
    local rollback_data_file = rollback_data_dir .. common.rollback.backup_uci_list
    debug:log("oasis.log", "Read: " .. rollback_data_file)

    local rollback_data_json = misc.read_file(rollback_data_file)
    local rollback_data_tbl = jsonc.parse(rollback_data_json)

    debug:dump("oasis.log", rollback_data_tbl)

    for _, cfg in ipairs(rollback_data_tbl) do
        debug:log("oasis.log", "Remove: " .. rollback_data_dir .. cfg)
        os.remove(rollback_data_dir .. cfg)
    end

    debug:log("oasis.log", "Remove: " .. rollback_data_dir .. common.rollback.uci_cmd_json)
    os.remove(rollback_data_dir .. common.rollback.uci_cmd_json)

    debug:log("oasis.log", "[1][rollback_list]")
    debug:dump("oasis.log", rollback_list)
    table.remove(rollback_list, #rollback_list)
    uci:set_list(common.db.uci.cfg, common.db.uci.sect.rollback, "list", rollback_list)
    uci:commit(common.db.uci.cfg)
    debug:log("oasis.log", "[2][rollback_list]")
    debug:dump("oasis.log", rollback_list)
    sys.exec("reboot")
end

local finalize = function()

    local result = sys.exec("touch /tmp/oasis/apply/complete;echo $?")

    if result == 0 then
        return true
    end

    return false
end

local apply = function(uci_list, commit)

    debug:log("oasis.log", "\n--- [apply.lua][apply] ---")

    -- uci add command
    for _, cmd in ipairs(uci_list.add) do
        -- create unnamed section
        -- uci add <config> <section-type>
        -- Note: cmd.class.section ---> <section-type>
        if (cmd.class.config) and (cmd.class.section) then
            debug:log("oasis.log", "uci add <config> <section-type>")
            debug:log("oasis.log", "--->" .. cmd.class.config .. " " .. cmd.class.section)
            uci:add(cmd.class.config, cmd.class.section)

            if commit then
                uci:commit(cmd.class.config)
            end
        end
    end

    -- set command
    for _, cmd in ipairs(uci_list.set) do

        -- create option
        -- uci set <config>.<section>.<option>=<value>
        if (cmd.class.config) and (cmd.class.section) and (cmd.class.option) and (cmd.class.value) then
            debug:log("oasis.log", "uci set <config>.<section>.<option>=<value>")
            debug:log("oasis.log", "--->" .. cmd.class.config .. "." .. cmd.class.section .. "." .. cmd.class.option .. "=" .. cmd.class.value)
            local safe_value = cmd.class.value
            safe_value = safe_value:gsub("'", "")
            safe_value = safe_value:gsub('\"', "")

            uci:set(cmd.class.config, cmd.class.section, cmd.class.option, safe_value)

            if commit then
                uci:commit(cmd.class.config)
            end

        -- create named section
        -- uci set <config>.<section>=<section-type>
        -- Note: safe_value ---> section-type
        elseif (cmd.class.config) and (cmd.class.section) and (cmd.class.value) then
            debug:log("oasis.log", "uci set <config>.<section>=<section-type>")
            debug:log("oasis.log", "--->" .. cmd.class.config .. "." .. cmd.class.section .. "=" .. cmd.class.value)
            local safe_value = cmd.class.value
            safe_value = safe_value:gsub("'", "")
            safe_value = safe_value:gsub('\"', "")

            uci:section(cmd.class.config, safe_value, cmd.class.section, nil)
            if commit then
                uci:commit(cmd.class.config)
            end
        end
    end

    -- uci add_list command
    local add_list = {}
    for _, cmd in ipairs(uci_list.add_list) do
        -- create list value
        -- uci add_list <config>.<section>.<option>=<value>
        if (cmd.class.config) and (cmd.class.section) and (cmd.class.option) and (cmd.class.value) then
            debug:log("oasis.log", "uci add_list command")
            debug:log("oasis.log", "--->" .. cmd.class.config .. "." .. cmd.class.section .. "." .. cmd.class.option .. "=" .. cmd.class.value)
            local safe_value = cmd.class.value
            safe_value = safe_value:gsub("'", "")
            safe_value = safe_value:gsub('\"', "")

            local is_config_search = false

            for config, _ in pairs(add_list) do
                if config == cmd.class.config then
                    is_config_search = true
                    break
                end
            end

            local is_section_search = false

            if is_config_search then
                for section, _ in pairs(add_list[cmd.class.config]) do
                    if section == cmd.class.section then
                        is_section_search = true
                        break
                    end
                end
            end

            local is_option_search = false

            if is_section_search then
                for option, _ in pairs(add_list[cmd.class.config][cmd.class.section]) do
                    if option == cmd.class.option then
                        is_option_search = true
                        break
                    end
                end
            end

            if (not is_config_search) and (not is_section_search) and (not is_option_search) then
                add_list[cmd.class.config] = {}
                add_list[cmd.class.config][cmd.class.section] = {}
                add_list[cmd.class.config][cmd.class.section][cmd.class.option] = {}
            elseif (not is_section_search) and (not is_option_search) then
                add_list[cmd.class.config][cmd.class.section] = {}
                add_list[cmd.class.config][cmd.class.section][cmd.class.option] = {}
            elseif (not is_option_search) then
                add_list[cmd.class.config][cmd.class.section][cmd.class.option] = {}
            end
            local items = #add_list[cmd.class.config][cmd.class.section][cmd.class.option] + 1
            add_list[cmd.class.config][cmd.class.section][cmd.class.option][items] = safe_value
        end
    end

    for config, sect_op_val_tbl in pairs(add_list) do
        for section, op_val_tbl in pairs(sect_op_val_tbl) do
            for option, val_tbl in pairs(op_val_tbl) do
                debug:log("oasis.log", "<add list>")
                debug:dump("oasis.log", val_tbl)
                uci:set_list(config, section, option, val_tbl)
            end
        end

        if commit then
            uci:commit(config)
        end
    end

    -- uci del_list command
    for _, cmd in ipairs(uci_list.del_list) do
        -- delete target list value
        -- uci del_list <config>.<section>.<option>=<value>
        if (cmd.class.config) and (cmd.class.section) and (cmd.class.option) and (cmd.class.value) then
            debug:log("oasis.log", "uci del_list command")
            debug:log("oasis.log", "--->" .. cmd.class.config .. "." .. cmd.class.section .. "." .. cmd.class.option .. "=" .. cmd.class.value)
            local safe_value = cmd.class.value
            safe_value = safe_value:gsub("'", "")
            safe_value = safe_value:gsub('\"', "")

            local list = uci:get_list(cmd.class.config, cmd.class.section, cmd.class.option)

            for index, value in ipairs(list) do
                if value == safe_value then
                    table.remove(list, index)
                end
            end

            uci:set_list(cmd.class.config, cmd.class.section, cmd.class.option, {})
            uci:set_list(cmd.class.config, cmd.class.section, cmd.class.option, list)

            if commit then
                uci:commit(cmd.class.config)
            end
        end
    end

    -- uci reorder command (create named section)
    -- Note: safe_value ---> position index
    for _, cmd in ipairs(uci_list.reorder) do
        -- uci reorder <config>.<section>=<position index>
        if (cmd.class.config) and (cmd.class.section) and (cmd.class.value) then
            debug:log("oasis.log", "uci reorder command (create named section)")
            debug:log("oasis.log", "--->" .. cmd.class.config .. "." .. cmd.class.section .. "." .. cmd.class.option .. "=" .. cmd.class.value)
            local safe_value = cmd.class.value
            safe_value = safe_value:gsub("'", "")
            safe_value = safe_value:gsub('\"', "")

            if tonumber(safe_value) then
                uci:reorder(cmd.class.config, cmd.class.section, safe_value)

                if commit then
                    uci:commit(cmd.class.config)
                end
            end
        end
    end

    -- uci delete command
    for _, cmd in ipairs(uci_list.delete) do
        -- uci delete <config>.<section>.<option>
        if (cmd.class.config) and (cmd.class.section) and (cmd.class.option) then
            uci:delete(cmd.class.config, cmd.class.section, cmd.class.option)

            if commit then
                uci:commit(cmd.class.config)
            end
        -- uci delete <config>.<section>
        elseif (cmd.class.config) and (cmd.class.section) then
            uci:delete(cmd.class.config, cmd.class.section)

            if commit then
                uci:commit(cmd.class.config)
            end
        end
    end

    sys.exec("lua /usr/bin/oasisd &")

    debug:log("oasis.log", "Check ---> /etc/init.d/xxxx")
    debug:log("oasis.log", "<uci list>")
    debug:dump("oasis.log", uci_list)
    for key, target_cmd_tbl in pairs(uci_list) do
        if (key == "set") and (type(target_cmd_tbl) == "table") then
            debug:log("oasis.log", "<target_cmd_tbl>")
            debug:dump("oasis.log", target_cmd_tbl)
            for _, cmd in ipairs(target_cmd_tbl) do
                if (cmd.class.config == "network") or (cmd.class.config == "wireless") then
                    local is_init_script = misc.check_file_exist("/etc/init.d/network")
                    if is_init_script then
                        debug:log("oasis.log", "[1] trigger config: " .. cmd.class.config)
                        sys.exec("/etc/init.d/network restart")
                        break
                    end
                end
            end

            for _, cmd in ipairs(target_cmd_tbl) do
                if (cmd.class.config ~= "network") and (cmd.class.config ~= "wireless") then
                    local init_script = "/etc/init.d/" .. cmd.class.config
                    local is_file_exist = misc.check_file_exist(init_script)
                    if is_file_exist then
                        debug.log("oasis.log", "[2] trigger config: " .. cmd.class.config)
                        sys.exec(init_script .. " restart")
                    end
                end
            end
        end
    end
end

return {
    create_new_backup_data = create_new_backup_data,
    apply = apply,
    complete = complete,
    rollback = rollback,
    finalize = finalize,
    rollback_target_data = rollback_target_data,
    get_rollback_data_list = get_rollback_data_list,
}