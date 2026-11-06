---
# oh-my-pi reads this as a global rule (~/.omp/agent/rules/dotfiles.md) and
# loads it every session only with alwaysApply. Claude Code and Kiro ignore
# the key; single-AGENTS.md harnesses (pi, Codex, OpenCode) see it as text.
alwaysApply: true
description: User-level instructions from ~/Dotfiles
---
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

## Sub-agent cost check

Sub-agents start with an empty context: they do not inherit the parent's
conversation or prompt cache, so every sub-agent pays again for the context
it shares with the others. Before delegating a sequence of tasks, estimate
the shared context S each sub-agent is likely to load:

- files the prompt tells it to read;
- `AGENTS.md` and steering files it will very likely read;
- source, test and other files it will very likely read.

Estimate tokens as file bytes ÷ 4. For N sub-agents, the duplicated cost is
(N − 1) × S.

- If (N − 1) × S exceeds ~100k tokens, first use **fewer** sub-agents: group
  tasks that share context (for example, all the steps that use one design
  file) into one sub-agent, and recompute. Prefer fewer sub-agents to no
  sub-agents.
- If the cost still exceeds ~100k tokens with the fewest sensible groups, do
  the tasks in series in the main session, compacting at ~300k tokens.
- Files the main session has already loaded favor working in series: there
  they are already paid for.
- When delegating, pass the relevant sections rather than whole files.

## Stacked pull requests (GitHub only)

For stacked PRs in a GitHub repository, follow the `github-pr-stack` skill
(`~/Dotfiles/agents/skills/github-pr-stack/`), unless the repository has its
own PR-stack skill or instructions; those take precedence. It does not apply
to other hosts.
