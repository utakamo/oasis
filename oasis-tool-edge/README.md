# Description
When calling `function_calling` from `oasis.tool.edge`, the caller must set the `param` field with a serialized string containing the tool's argument information. The serialization format is as follows:
`<variable name>:<type>:<value>`
Currently, only the `string` type is supported.

# Usage example
```
ubus call oasis.tool.edge function_calling '{"tool":"wifi_scan", "param":"ifname:string:wlan0"}'
```
