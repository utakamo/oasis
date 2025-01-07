#!/usr/bin/env lua

local jsonc = require("luci.jsonc")
local uci = require("luci.model.uci").cursor()
local sys = require("luci.sys")

local backup = function(uci_list, id, backup_type)

    local list = {}

    sys.exec("echo hello >> /tmp/oasis-backup.log")

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
                        sys.exec("echo " .. cmd.class.config .. " >> /tmp/oasis-backup.log")
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

    -- sys.exec("echo #list=" .. #list .. " >> /tmp/oasis-backup.log")

    if #list > 0 then
        local uci_list_json = jsonc.stringify(uci_list)
        sys.exec("echo " .. uci_list_json .. " /etc/oasis/backup/uci_list.json")
        uci:set("oasis", "backup", "enable", "1")
        uci:set("oasis", "backup", "src_id", id)
        uci:set_list("oasis", "backup", "targets", list)

        for _, config in ipairs(list) do
            uci:commit(config)
        end

        local uptime = sys.exec("uptime | awk -F'( up | min,)' '{print $2}' | tr -d '\n'")
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
        --     sys.exec("uci import -f /etc/oasis/backup/" .. config)
        -- else
        sys.exec("uci import -f /etc/oasis/backup/" .. config .. " " .. config)
        -- end
    end

    for _, config in ipairs(backup_list) do
        os.remove("/etc/oasis/backup/" .. config)
    end

    uci:delete("oasis", "backup", "targets")

    sys.exec("uci commit")
    sys.exec("reboot")
end

local confirm = function(answer)

    local result = 0

    if answer == "ok" then
        result = sys.exec("touch /tmp/oasis/apply/complete")
    elseif answer == "cancel" then
        result = sys.exec("touch /tmp/oasis/apply/cancel")
    end

    if result == 0 then
        return true
    end

    return false
end

local apply = function(uci_list)

    for key, target_cmd_tbl in pairs(uci_list) do
        -- sys.exec("echo \"" .. key .. "\" >> /tmp/oasis-apply.log")
        if (key == "set") and (type(target_cmd_tbl) == "table") then
            for _, cmd in ipairs(target_cmd_tbl) do
                -- for debug
                local param_log = cmd.class.config
                param_log = param_log .. " " .. cmd.class.section
                param_log = param_log .. " ".. cmd.class.option
                param_log = param_log .. " " .. cmd.class.value
                sys.exec("echo \"" .. param_log ..  "\" >> /tmp/oasis-apply.log")

                uci:set(cmd.class.config, cmd.class.section, cmd.class.option, cmd.class.value)
                uci:commit(cmd.class.config)
            end
        end
    end

    sys.exec("sh /usr/bin/oasis_recovery_timer &")
    sys.exec("/etc/init.d/network restart")
end

return {
    backup = backup,
    apply = apply,
    recovery = recovery,
    confirm = confirm,
}