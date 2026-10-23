# User-level instructions

<!-- Source: ~/Dotfiles/agents/instructions.md, linked into each coding-agent
harness's user-level instructions by `bash install.sh link` (or
`instructions`). Edit it there. -->

## MCP servers inside a Docker sandbox (sbx)

You are in a Docker sandbox when `$MCP_GATEWAY_URL` is set. There:

- Call MCP servers from the shell through the sbx MCP gateway with `mcpcli`
  from the `sbx-mcp-client` skill
  (`~/Dotfiles/agents/skills/sbx-mcp-client/scripts/mcpcli`). Prefer it to
  the gateway's servers attached as native MCP tools and to MCP servers
  configured in your harness. A native tool call puts the whole response
  into your context; with `mcpcli` you choose what enters it (redirect to a
  file, then read only what you need with `jq`, `head`, `grep`).
- If a server you need is not on the gateway (`mcpcli tools` doesn't list
  it), say so and ask before using an agent-attached MCP server instead.
- Before calling the AWS MCP Server (`aws___*` tools), in particular for
  CloudWatch logs and Logs Insights, which cost money per query, load the
  `aws-mcp` skill and follow it.
