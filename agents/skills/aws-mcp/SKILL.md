---
name: aws-mcp
description: >-
  Rules for querying AWS through the AWS MCP Server (aws___* tools such as
  aws___run_script and aws___get_tasks): avoiding timeouts and background-task
  handoffs, and keeping CloudWatch Logs Insights costs within budget. Use
  before reading CloudWatch logs, running a Logs Insights query, or calling
  any aws___ tool, natively or through the sbx MCP gateway client (mcpcli).
---

# Using the AWS MCP Server

Confirmed 2026-10-16 (sbx v0.48.0, `mcp-proxy-for-aws-cli` 1.7.0) unless marked
otherwise. The AWS MCP Server is hosted by AWS and changes without notice, so
re-check timings and limits if behavior looks different.

Inside a Docker sandbox, call it with the `sbx-mcp-client` skill's `mcpcli`
(`py` for scripts, `logs` for Logs Insights) rather than as native tools.

## 1. Access

- Tools are named `aws___*`. How the host registered the server decides
  whether calls take an `aws_profile`: a multi-profile registration requires
  it on every call; one started with `--profile P` (confirmed 2026-10-28)
  has no such argument, rejects it, and always signs as `P`. Check the
  schema with `mcpcli describe aws___run_script`. Profiles are named by the
  host's registration, so they differ per user and project: take them from
  the project's docs or ask the user. Use the profile for the account that
  owns the resource. Region is usually
  `us-east-1`.
- Never run the AWS CLI or SDK from bash. If a CLI comparison would help,
  give the user the command and let them run it with their own credentials.

## 2. `aws___run_script`

- **Shape.** Runs Python in a hosted sandbox. Use top-level
  `await call_boto3(service_name=..., operation_name=..., region_name=...,
  params={...})`; the last expression is the return value. `time` is
  predefined and `import asyncio` works. The result is
  `{"status": "success"|"error", "return_value", "error", "stdout",
  "api_calls"}`. Check `status`, not just the MCP `is_error` flag: script
  errors come back with `is_error: false`.
- **`call_boto3` auto-paginates.** Always pass a page-size parameter
  (`maxItems`, `MaxResults`, `limit`, ...) sized to what you need, and check
  `api_calls[].n_items` to see how much was really fetched. An unbounded
  `GetQueryResults` fetched 10,000 rows and failed with "Code execution
  timeout" after about 5 minutes; with `maxItems` the same call took 2s.
- **`DescribeLogGroups` takes `limit`,** not `maxItems` (which fails with
  "Unknown parameter").
- **Keep each call well under 90s.** At about 90s, `run_script` returns
  `{"status": "working", "task_id": ...}` and keeps running in the
  background. Poll `aws___get_tasks` with
  `{"task_ids": [...], "poll_iteration": n}`. Each poll takes about 1s, so
  polling every 5s is fine even though the `required_action` text says to
  sleep 30–90s. Tasks expire 5 minutes after they start. A handoff usually
  means the script fetches too much or sleeps too long. (`mcpcli py` polls
  for you.)
- **One `run_script` at a time per MCP session.** Concurrent calls fail with
  "sandbox is busy". Don't use long in-sandbox sleep or poll loops; keep
  each script short and poll again in a later call.
- **Typical timings.** A trivial script takes 2–8s, `StartQuery` 2–5s, and
  a bounded `GetQueryResults` about 2s.

## 3. Permissions observed (read-only MCP roles)

- `logs:StartQuery`, `GetQueryResults`, `DescribeQueries` and `StopQuery`
  worked; on the roles tested they came from an inline policy, not from the
  `ViewOnlyAccess` managed policy.
- `StopQuery` cancels a query started by mistake; assume what it scanned
  before the stop is still billed (not verified).
- `logs:FilterLogEvents` was denied, so log reads go through Logs Insights.

## 4. CloudWatch Logs Insights

### 4.1 Rules

- **Cost is bytes scanned.** $0.005/GB in us-east-1 for the Standard log
  class. The scan is set by the log groups and the time range. `limit`,
  `filter` and `sort` change only the rows returned, not the bytes scanned:
  a `limit 10` query scanned the same 131 MB as a full `stats` query over
  the same window. StartQuery has no scan-limit parameter. Only
  `filterIndex` on indexed fields lowers the scan (`estimatedBytesSkipped`).
- **Estimate every query first.** Appending `| estimate` returns
  `@estimatedBytesScanned` without running the query, at no cost. The
  estimate is the only cost gate: don't try to watch or stop a query while
  it runs. Queries are fast (12.4 GB scanned in 3.1s), so a running query
  usually finishes before a poll could stop it.
- **Per-query cap: 20 GB ($0.10).** Don't run a query whose estimate is over
  the cap unless the user explicitly allows it, and say what the estimate
  was. A small time range and a single log group are the main ways to stay
  under the cap.
- **Spend budgets: at most $1.00 in any 5 minutes and $5.00 in any 60
  minutes** per agent session, across all Logs Insights queries. Before each
  query, check that spend in each window plus the estimate stays within
  budget. Exceed a budget only when the user says to, and only for that
  request.
- **Estimates run low.** They came in 1–31% *under* the actual scan (worst
  on short windows), so leave headroom near a limit.
- **Track spend per session in a ledger** (§4.3).
- **Report the cost numbers.** With every result, show the rows returned,
  records scanned, bytes scanned, cost, and the session's spend so far.
- **Sample before aggregating.** First run
  `fields @timestamp, @message | sort @timestamp desc | limit 3` over a short
  window to learn the message shape and field names. Don't get them from
  source code. JSON fields are auto-discovered, e.g. `message`,
  `extra.status_code`.

### 4.2 Procedure

**With mcpcli** (in a sandbox), one command does steps 1–5 below:

```bash
<sbx-mcp-client-skill-dir>/scripts/mcpcli logs 15 '<query>' \
  --session <id> --group <log-group> --profile <profile> > /tmp/cwl-out.json
jq '{status, reason, estimated_bytes, rows_returned, records_scanned, gb_scanned, cost_usd, spend}' /tmp/cwl-out.json
```

It exits 2 when the estimate exceeds the per-query cap or what is left of
either budget, records every query that ran in the session ledger, and
returns `query_id` if the query is still running after `--max-wait`. Read
the rows (`jq '.rows[:20]'`) only after checking their count.

**Natively**, one `aws___run_script` call per step, with the `aws_profile` for
the account that owns the log group (if the schema takes one):

1. **Estimate.** Fix the time range once and reuse it in step 3 so the
   estimate matches the query:

   ```python
   end = int(time.time()); start = end - 15 * 60
   q = await call_boto3(service_name="logs", operation_name="StartQuery", region_name="us-east-1",
       params={"logGroupNames": ["<log-group>"], "startTime": start, "endTime": end,
               "queryString": "<query> | estimate"})
   result = {"query_id": q["queryId"], "start": start, "end": end}
   result
   ```

2. **Read the estimate** with the step 4 script. When the status is
   `Complete`, the single row is `@estimatedBytesScanned`. Check it against
   the per-query cap and the remaining budgets.
3. **Start the query** with the same `start`/`end` and the query string
   without `| estimate`. Return `q["queryId"]`.
4. **Poll for results.** Always set `maxItems`. Call again every few seconds
   while the status is `Scheduled` or `Running`:

   ```python
   r = await call_boto3(service_name="logs", operation_name="GetQueryResults", region_name="us-east-1",
       params={"queryId": "<query-id>", "maxItems": 1000})
   result = {"status": r["status"], "statistics": r.get("statistics"),
             "rows": [{f["field"]: f["value"] for f in row if f["field"] != "@ptr"}
                      for row in r.get("results", [])]}
   result
   ```

5. **Record** the query in the ledger and report results with cost.

`<sbx-mcp-client-skill-dir>/scripts/cwl_guarded_query.py` implements steps
1–4 in one script; to use it natively, substitute its `__PLACEHOLDERS__` with
Python literals and pass the whole file as `code`.

### 4.3 Session spend ledger

At the start of a session, pick a session ID: your agent session ID if you
know it, otherwise something like `20261016-1102-k7q2` (date, time, 4 random
characters; letters, digits, `_`, `.`, `-`). Write it in your working notes
so it survives context compaction, and never switch IDs to get around a
budget.

`mcpcli logs` appends to the ledger itself. When querying natively, append one
JSON line per query that ran to `/tmp/cwl-insights-ledger-<session-id>.jsonl`
(same format, so both can share one ledger):

```json
{"ts": 1792148814, "query_id": "...", "status": "Complete", "groups": ["..."], "minutes": 15,
 "bytes": 139446253, "bytes_source": "actual", "cost_usd": 0.000697}
```

`bytes` is `statistics.bytesScanned`; if the query didn't finish, use the
estimate and set `bytes_source` to `"estimate"`. `cost_usd` is
`bytes / 1e9 * 0.005`. Sum spend with `mcpcli spend --session <id>`, or:

```bash
jq -s --argjson now "$(date +%s)" '{last_5m_usd: (map(select(.ts >= $now - 300).cost_usd) | add // 0),
    last_60m_usd: (map(select(.ts >= $now - 3600).cost_usd) | add // 0),
    total_usd: (map(.cost_usd) | add // 0)}' /tmp/cwl-insights-ledger-<session-id>.jsonl
```

This guards against mistakes; it is not accounting. Other sessions' queries
aren't counted, and a new session starts at $0.

## 5. Troubleshooting

- **A call hangs, then returns `working`:** the script is fetching too much
  (usually an unbounded page size) or sleeping. See §2.
- **Every `aws___*` call fails for one profile** (`Unknown tool` or `Failed to
  create connection for profile ...`) while listing tools works: most likely
  the user's source (e.g. Okta) session for that profile has expired. Ask the
  user to log in again; the proxy picks up refreshed credentials without a
  restart.
- **Proxy logs** (sbx): the gateway runs the proxy as a host stdio server, so
  its logs come from the sbx daemon (`sbx diagnose`, on the host).

## Sources (checked 2026-10-16)

- [StartQuery](https://docs.aws.amazon.com/AmazonCloudWatchLogs/latest/APIReference/API_StartQuery.html):
  `limit` caps returned events; no scan-limit parameter; queries time out
  after 60 minutes.
- [GetQueryResults](https://docs.aws.amazon.com/AmazonCloudWatchLogs/latest/APIReference/API_GetQueryResults.html):
  `maxItems` up to 10,000 per page.
- [`estimate` command](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/CWL_QuerySyntax-Estimate.html):
  approximate bytes scanned, no query charges, must be the last command.
- Price $0.005/GB scanned comes from 2026 third-party summaries; not yet
  confirmed on the AWS pricing page.
