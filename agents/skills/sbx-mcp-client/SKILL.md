---
name: sbx-mcp-client
description: >-
  Call MCP servers on the Docker Sandboxes (sbx) MCP gateway from the shell
  with mcpcli, so that only the parts of a response you choose enter your
  context. Use inside an sbx sandbox ($MCP_GATEWAY_URL is set) whenever you
  would otherwise call an MCP tool: listing or describing a server's tools,
  calling a tool, running AWS MCP Server scripts, or CloudWatch Logs Insights
  queries.
compatibility: >-
  Requires bash and python3 (with venv). The first run installs mcp==2.3.0
  from pypi.org into ~/.cache/mcpcli.
---

# sbx MCP gateway client

Inside a Docker sandbox, the servers registered on the host with `sbx mcp add`
(e.g. `aws`, `datadog`) are reachable at `$MCP_GATEWAY_URL`
(`http://mcp-gateway.docker.internal/mcp`). `mcpcli` talks to the gateway over
streamable HTTP from bash, using the official MCP python SDK.

Prefer it to the same servers attached as native MCP tools, and to MCP servers
configured in your own harness. A native tool call puts the whole response
into your context; with `mcpcli` you decide what goes in.

## Commands

`<skill-dir>` is the directory containing this SKILL.md (it is also at
`~/Dotfiles/agents/skills/sbx-mcp-client`).

```bash
M=<skill-dir>/scripts/mcpcli

$M tools [substring]                      # tool names + first line of each description
$M describe <tool>                        # full description and input schema
$M call <tool> '<json-args>'              # any tool; prints its text content
$M py '<python>' | @file.py [--profile P] # aws___run_script; polls aws___get_tasks on handoff
$M logs <minutes> '<query>' --session <id> --group <log-group> [--group ...] [--profile P]
                                          # estimate-gated Logs Insights query
$M spend --session <id>                   # Logs Insights spend from the session ledger
```

- Exit codes: 0 success, 1 failure (message on stderr), 2 usage error or a
  `logs` query that is not `Complete` (refused by a budget, still running, or
  failed).
- `py` and `logs` sign with `--profile`, defaulting to `$MCPCLI_AWS_PROFILE`.
  It is required only when the tools take an `aws_profile` argument; a server
  registered with a fixed profile (`mcp-proxy-for-aws-cli ... --profile P`)
  takes none and rejects it, so `mcpcli` checks the tool schema and drops a
  given profile with a note on stderr. Before `py` or `logs`, load the `aws-mcp` skill
  and follow it: Logs Insights queries cost money, and `logs` enforces the
  budgets described there (`--max-gb`, `--budget-5m`, `--budget-60m`
  override them; use those only when the user says to).
- One gateway session per invocation; initializing takes under a second.

## Keep responses out of your context

- Results go to stdout, progress and timings to stderr. Send results to a
  file, then read only what you need:

  ```bash
  $M call <tool> '<json-args>' > /tmp/mcp-out.json 2> /tmp/mcp-err.log
  jq 'keys' /tmp/mcp-out.json; wc -c /tmp/mcp-out.json; head -c 2000 /tmp/mcp-out.json
  ```

- Start with `tools <substring>`; run `describe` only for the tools you will
  call.
- Ask servers for less: page sizes, field selections, short time ranges.
- Look at stderr when a call fails or is slow; it has elapsed and wall-clock
  times that line up with the sbx daemon log. `--debug` (before the
  subcommand) logs the protocol traffic.

## Gateway behavior the client depends on (confirmed 2026-10-16, sbx v0.48.0)

- **Endpoint and auth.** `$MCP_GATEWAY_URL` with
  `Authorization: Bearer $MCP_SENTINEL_TOKEN_NAME`. The token is a sentinel
  the sandbox proxy swaps for real credentials; the client holds none. The
  hostname resolves only through the sandbox HTTP proxy, so the client honors
  the proxy env vars.
- **Keepalive pings.** The gateway pings the client during a tool call and
  closes the session after one missed ping (about 45s in), seen as an empty
  body and then `session not found`. Hand-rolled `curl` clients don't answer
  pings, so they only work for calls that finish well under 45s. The SDK
  answers them, which is why this client uses it.
- **`event: prime`.** With protocol `2025-11-25` the gateway sends a
  non-standard `prime` SSE event at the start of each stream. It is harmless;
  the client filters the SDK's warning about it.

## Files

- `scripts/mcpcli` — wrapper: creates the venv on first use, runs `mcpcli.py`.
- `scripts/mcpcli.py` — the client.
- `scripts/cwl_guarded_query.py` — the script `logs` sends to
  `aws___run_script`: estimate, refuse if over the cap, run, wait at most 30s
  per call.

Disk: the venv in `~/.cache/mcpcli/` and Logs Insights spend ledgers in
`/tmp/cwl-insights-ledger-<session-id>.jsonl`.
