--[[
[CONNECT REMOTE MCP SERVER FORMAT (sample)]

curl https://api.openai.com/v1/responses \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d '{
  "model": "gpt-4.1",
  "tools": [
    {
      "type": "mcp",
      "server_label": "deepwiki",
      "server_url": "https://mcp.deepwiki.com/mcp",
      "require_approval": "never",
      "allowed_tools": ["ask_question"]
    }
  ],
  "input": "What transport protocols does the 2025-03-26 version of the MCP spec (modelcontextprotocol/modelcontextprotocol) support?"
}'

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

