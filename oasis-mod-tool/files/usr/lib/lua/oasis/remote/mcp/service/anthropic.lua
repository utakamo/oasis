--[[
curl https://api.anthropic.com/v1/messages \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "anthropic-beta: mcp-client-2025-04-04" \
  -d '{
    "model": "claude-sonnet-4-20250514",
    "max_tokens": 1000,
    "messages": [{"role": "user", "content": "What tools do you have available?"}],
    "mcp_servers": [
      {
        "type": "url",
        "url": "https://example-server.modelcontextprotocol.io/sse",
        "name": "example-mcp",
        "authorization_token": "YOUR_TOKEN"
      }
    ]
  }'
​]]

--[[
[uci config sample for tools meta information]
config remote_mcp_server 'deepwiki'
    option type 'mcp'
    option server_label 'deepwiki'
    option server_url 'https://mcp.deepwiki.com/mcp'
    option require_approval 'never'
    list allowed_tools 'ask_question'

config remote_mcp_server 'another'
    option type 'mcp'
    option server_label 'another'
    option server_url 'https://another.example.com/mcp'
    option require_approval 'manual'
    list allowed_tools 'foo'
    list allowed_tools 'bar'
]]
