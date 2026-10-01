# Description
When calling `function_calling` from `oasis.tool.edge`, the caller must set the `param` field with a serialized string containing the tool's argument information. The serialization format is as follows:
`<variable name>:<type>:<value>`
Currently, only the `string` type is supported.

# Usage example
```
ubus call oasis.tool.edge function_calling '{"tool":"wifi_scan", "param":"ifname:string:wlan0"}'
```

# Account removal and upgrades

The core package records the managed username in
`oasis.rpc.oasis_rpc_account`. Account creation and renaming update this
registry together with the `rpcd` login; account deletion clears the record.
Passwords and password hashes are stored only in the existing `rpcd` login.

Uninstalling `oasis-tool-edge` deletes a login only when the registry is
nonempty, exactly one `login` has that username, that login has
`oasis_tool_edge=1`, and no other login has the marker. A missing/mismatched
registry, duplicate username, or multiple markers causes a warning/error and
retains the accounts for manual review. A configuration with no managed
account and an empty registry skips account deletion with a warning.

The shared account and General Settings locks serialize writes to both UCI
files. A save failure attempts to restore the selected login and the previous
registry without copying entire configurations or writing credentials to
backup files. Each UCI file has its own commit: a power loss between commits
can leave a mismatch, which subsequent account operations reject.

Oasis `3.2.6-r23` provides the shared account module and
`oasis_tool_edge_account migrate`; Tool Edge `1.0.0-r4` requires that core
version or newer. Installation and `keep-config` restoration migrate a missing
registry from a unique marked login with a unique valid username. Migration
preserves existing credentials and never overwrites a conflicting record.
The removal hook never migrates a missing record to authorize deletion.

Permanent removal also sets `oasis.support.tool_edge=0` and restarts `rpcd` to
reload RPC objects, ACLs, and sessions. Existing LuCI sessions may end.
`oasis.rpc.enable` is preserved. On APK, a successful `apk del` exit status
does not guarantee that its removal hook succeeded; review warnings and the
resulting UCI and RPC state.

Direct IPK and APK upgrades preserve the managed login. The development
helpers `dev_tools/oasis_local_upgrade` and `dev_tools/oasis_local_upgrade_apk`
also preserve it, with or without `keep-config`, while removing and reinstalling
Tool Edge. Both helpers must be updated when deploying this removal hook.
They create a root-owned private marker only around Tool Edge removal, bound
to the helper's PID and kernel start time. Ownership, type, and permissions
are checked with Lua/nixio. The hook requires that process to
be a live ancestor; a stale marker or an unrelated removal does not preserve
the account. Normal completion, errors, and handled signals clear the marker.
An interrupted update may retain the account until Tool Edge is reinstalled
or the administrator removes the account explicitly.
