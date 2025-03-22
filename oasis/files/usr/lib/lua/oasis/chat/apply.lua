#!/usr/bin/env lua

local jsonc = require("luci.jsonc")
local util = require("luci.util")
local uci = require("luci.model.uci").cursor()
local sys = require("luci.sys")

local backup = function(uci_list, id, backup_type)

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

        for _, config in ipairs(backup_target_cfg) do
            sys.exec("uci export " .. config .. " > /etc/oasis/backup/" .. config)
            list[#list + 1] = config
        end
    elseif backup_type == "full" then
        sys.exec("uci export > /etc/oasis/backup/full_backup")
        list[#list + 1] = "full_backup"
    else
        return false
    end

    if #list > 0 then
        local uci_list_json = jsonc.stringify(uci_list)
        --sys.exec("echo " .. uci_list_json .. " /etc/oasis/backup/uci_list.json")
        local file = io.open("/etc/oasis/backup/uci_list.json", "w")
        file:write(uci_list_json)
        file:close()

        uci:set("oasis", "backup", "enable", "1")
        uci:set("oasis", "backup", "src_id", id)
        uci:set_list("oasis", "backup", "targets", list)

        for _, config in ipairs(list) do
            uci:commit(config)
        end

        local system_info = util.ubus("system", "info", {})
        local uptime = system_info.uptime
        uci:set("oasis", "backup", "uptime", uptime)
        uci:commit("oasis")

        return true
    end

    return false
end

local recovery = function()

    local is_enable = uci:get("oasis", "backup", "enable")

    if not is_enable then
        sys.exec("echo \"recovery invalid\" >> /tmp/oasis-recovery.log")
        return
    end

    uci:set("oasis", "backup", "enable", "0")

    local backup_list = uci:get_list("oasis", "backup", "targets")

    if #backup_list == 0 then
        sys.exec("echo \"no backup list\" >> /tmp/oasis-recovery.log")
        return
    end

    for _, config in ipairs(backup_list) do
        -- if config == "full_backup" then
        --     sys.exec("uci -f /etc/oasis/backup/full_backup import")
        -- else
        sys.exec("uci -f /etc/oasis/backup/" .. config .. " import " .. config)
        -- end
    end

    for _, config in ipairs(backup_list) do
        os.remove("/etc/oasis/backup/" .. config)
    end

    uci:delete("oasis", "backup", "targets")

    sys.exec("uci commit")
    sys.exec("reboot")
end

local finalize = function()

    local result = sys.exec("touch /tmp/oasis/apply/complete;echo $?")

    if result == 0 then
        return true
    end

    return false
end

local rollback = function()

    local result = sys.exec("touch /tmp/oasis/apply/rollback;echo $?")

    if result == 0 then
        return true
    end

    return false
end

local apply = function(uci_list, commit)

    for key, target_cmd_tbl in pairs(uci_list) do
        -- sys.exec("echo \"" .. key .. "\" >> /tmp/oasis-apply.log")
        if (key == "set") and (type(target_cmd_tbl) == "table") then
            for _, cmd in ipairs(target_cmd_tbl) do
                -- for debug
                -- local param_log = cmd.class.config
                -- param_log = param_log .. " " .. cmd.class.section
                -- param_log = param_log .. " ".. cmd.class.option
                -- param_log = param_log .. " " .. cmd.class.value
                -- sys.exec("echo \"" .. param_log ..  "\" >> /tmp/oasis-apply.log")
                local safe_value = cmd.class.value
                safe_value = safe_value:gsub("'", "")
                -- Double quotation marks \" in the string are treated as allowable by commenting them out.
                --safe_value = safe_value:gsub('\"', "")
                uci:set(cmd.class.config, cmd.class.section, cmd.class.option, safe_value)

                if commit then
                    uci:commit(cmd.class.config)
                end
            end
        end
    end

    sys.exec("lua /usr/bin/oasis_rollback &")
    sys.exec("/etc/init.d/network restart")
end

return {
    backup = backup,
    apply = apply,
    recovery = recovery,
    finalize = finalize,
    rollback = rollback,
}