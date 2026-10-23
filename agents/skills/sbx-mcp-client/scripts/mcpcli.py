#!/usr/bin/env python3
"""MCP client for the sbx MCP gateway, built on the official MCP python-sdk.

Run it through the `mcpcli` wrapper next to this file, which creates a venv with the pinned
SDK (mcp==2.3.0) on first use.

The SDK handles the streamable-HTTP protocol: session IDs, the server->client GET stream,
and replying to the gateway's keepalive pings (which the sbx gateway uses to decide whether
to close a session mid tool call).

Usage:
  mcpcli.py tools [substring]                     list tools
  mcpcli.py describe <tool>                       tool description and input schema
  mcpcli.py call <tool> '<json-args>'             call any tool, print its text content
  mcpcli.py py '<python>'|@file.py [--profile P]  aws___run_script; print return_value
  mcpcli.py logs <minutes> '<query>' --session ID --group G [--group G2 ...] [--profile P]
                                                  estimate-gated Logs Insights query
  mcpcli.py spend --session ID                    Logs Insights spend from the session's ledger

All timing and protocol events go to stderr with elapsed seconds and wall-clock time, to
line up against the sbx daemon log.
"""
import argparse, asyncio, json, logging, os, re, sys, time
from datetime import datetime
from pathlib import Path

import httpx2
from mcp.client.session import ClientSession
from mcp.client.streamable_http import streamable_http_client

URL = os.environ.get("MCP_GATEWAY_URL", "http://mcp-gateway.docker.internal/mcp")
# Sentinel value; the sandbox proxy swaps it for real credentials. Not a secret.
TOKEN = os.environ.get("MCP_SENTINEL_TOKEN_NAME", "proxy-managed")
# Default aws_profile for `py` and `logs`; --profile overrides. No built-in default: profile names
# come from the host's AWS MCP registration, which differs per user and project.
PROFILE = os.environ.get("MCPCLI_AWS_PROFILE")
GUARD = (Path(__file__).parent / "cwl_guarded_query.py").read_text()
# Logs Insights spend ledger: one per agent session (--session), one JSON line per query that ran.
# Best effort, to catch mistakes: concurrent sessions don't see each other's spend.
LEDGER_DIR = Path("/tmp")
LEDGER = None  # set from --session in main()
PRICE_PER_GB = 0.005  # USD per GB scanned, us-east-1 Standard log class
T0 = time.time()


def log(msg):
    print(f"[{time.time() - T0:6.1f}s {datetime.now():%H:%M:%S}] {msg}", file=sys.stderr, flush=True)


class Gateway:
    """One MCP session for the lifetime of the `async with` block."""

    async def __aenter__(self):
        self._http = httpx2.AsyncClient(
            headers={"Authorization": f"Bearer {TOKEN}"},
            # Long read timeout: tool calls can hold the response stream open for minutes.
            timeout=httpx2.Timeout(30.0, read=600.0),
            trust_env=True,  # mcp-gateway.docker.internal resolves only via the sandbox proxy
        )
        await self._http.__aenter__()
        self._transport = streamable_http_client(URL, http_client=self._http)
        read, write = await self._transport.__aenter__()
        self.session = ClientSession(read, write)
        await self.session.__aenter__()
        await self.session.initialize()
        log("session initialized")
        return self

    async def __aexit__(self, *exc):
        for cm in (self.session, self._transport, self._http):
            try:
                await cm.__aexit__(*exc)
            except Exception as e:  # cleanup must not mask the real error
                log(f"cleanup error: {e!r}")

    async def call(self, name, args, timeout=600):
        t = time.time()
        log(f"call {name} ...")
        res = await self.session.call_tool(name, args, read_timeout_seconds=timeout)
        text = "\n".join(getattr(c, "text", "") for c in res.content)
        is_error = getattr(res, "is_error", getattr(res, "isError", False))
        log(f"call {name} done in {time.time() - t:.1f}s (is_error={is_error})")
        if is_error:
            raise RuntimeError(f"{name} error: {text[:1000]}")
        return text

    async def py(self, code, profile=PROFILE, task_wait=300):
        text = await self.call("aws___run_script", {"code": code, "aws_profile": profile})
        out = self._parse(text)
        # Calls longer than ~90s come back as {"status": "working", "task_id": ...}; poll get_tasks.
        poll, t = 1, time.time()
        while out.get("status") == "working" and out.get("task_id"):
            if time.time() - t > task_wait:
                raise RuntimeError(f"task {out['task_id']} still working after {task_wait}s")
            log(f"task {out['task_id']} working; polling get_tasks (#{poll})")
            await asyncio.sleep(5)
            text = await self.call("aws___get_tasks", {"task_ids": [out["task_id"]], "poll_iteration": poll,
                                                       "aws_profile": profile})
            out = self._unwrap_task(self._parse(text), out["task_id"])
            poll += 1
        if out.get("status") != "success":
            raise RuntimeError(f"run_script {out.get('status')}: {out.get('error') or out.get('stderr') or out}")
        return out["return_value"]

    @staticmethod
    def _parse(text):
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            raise RuntimeError(f"non-JSON tool result: {text[:1000]}")

    @staticmethod
    def _unwrap_task(resp, task_id):
        """Return this task's run_script result, or {"status": "working"} while it is still running.

        Observed shape: {"tasks": [{"task_id", "status": "working"|"completed",
        "result": {"content": [...], "structured_content": {<run_script result>}}}], "required_action"}.
        """
        for item in resp.get("tasks") or []:
            if item.get("task_id") != task_id:
                continue
            if item.get("status") == "working":
                return {"status": "working", "task_id": task_id}
            res = item.get("result") or {}
            if isinstance(res.get("structured_content"), dict):
                return res["structured_content"]
            texts = [c.get("text", "") for c in res.get("content") or []]
            return Gateway._parse("\n".join(texts)) if texts else item
        raise RuntimeError(f"task {task_id} missing from get_tasks response: {json.dumps(resp)[:600]}")


def guard_code(groups, minutes, query, max_bytes, limit_label, max_rows, query_id=None):
    """Fill the cwl_guarded_query.py placeholders with Python literals (repr), never raw strings."""
    subs = {"__GROUPS__": groups, "__QUERY__": query, "__MINUTES__": minutes, "__QUERY_ID__": query_id,
            "__MAX_BYTES__": max_bytes, "__LIMIT_LABEL__": limit_label, "__MAX_ROWS__": max_rows}
    code = GUARD
    for k, v in subs.items():
        code = code.replace(k, repr(v))
    return code


def ledger_path(session):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}", session):
        raise ValueError("--session must be 1-64 chars of letters, digits, '_', '.', '-'")
    return LEDGER_DIR / f"cwl-insights-ledger-{session}.jsonl"


def ledger_read():
    entries = []
    try:
        lines = LEDGER.read_text().splitlines()
    except FileNotFoundError:
        return entries
    for line in lines:
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            log(f"skipping unreadable ledger line: {line[:80]!r}")
    return entries


def spend(entries):
    now = time.time()
    return {"last_5m_usd": round(sum(e["cost_usd"] for e in entries if e["ts"] >= now - 300), 4),
            "last_60m_usd": round(sum(e["cost_usd"] for e in entries if e["ts"] >= now - 3600), 4),
            "total_usd": round(sum(e["cost_usd"] for e in entries), 4),
            "queries": len(entries), "ledger": str(LEDGER)}


async def logs_query(gw, groups, minutes, query, max_gb, budget_5m, budget_60m, max_rows, max_wait,
                     profile=PROFILE):
    """Estimate-gated query. The cap on the estimate is the smallest of --max-gb and what is left of the
    rolling 5-minute and 60-minute budgets. Every query that ran is appended to the ledger."""
    entries = ledger_read()
    s = spend(entries)
    max_bytes, label = min(
        (max_gb * 1e9, f"per-query limit {max_gb} GB"),
        ((budget_5m - s["last_5m_usd"]) / PRICE_PER_GB * 1e9,
         f"remaining 5-min budget (${budget_5m}, ${s['last_5m_usd']} spent)"),
        ((budget_60m - s["last_60m_usd"]) / PRICE_PER_GB * 1e9,
         f"remaining 60-min budget (${budget_60m}, ${s['last_60m_usd']} spent)"))
    args = dict(groups=groups, minutes=minutes, query=query, max_bytes=max(int(max_bytes), 0),
                limit_label=label, max_rows=max_rows)
    r = await gw.py(guard_code(**args), profile)
    t = time.time()
    while r["status"] in ("Scheduled", "Running") and time.time() - t < max_wait:
        log(f"{r['status']}; waiting on {r['query_id']}")
        r = await gw.py(guard_code(**args, query_id=r["query_id"]), profile)
    if r["status"] != "Refused":
        # Without final statistics (still running, failed), charge the estimate.
        actual = r.get("bytes_scanned") is not None
        b = r["bytes_scanned"] if actual else r["estimated_bytes"]
        entry = {"ts": round(time.time(), 1), "query_id": r["query_id"], "status": r["status"],
                 "profile": profile, "groups": groups, "minutes": minutes, "bytes": b,
                 "bytes_source": "actual" if actual else "estimate", "cost_usd": round(b / 1e9 * PRICE_PER_GB, 6)}
        with LEDGER.open("a") as f:
            f.write(json.dumps(entry) + "\n")
        entries.append(entry)
    r["spend"] = spend(entries)
    log(f"{r['status']}: estimated {r.get('estimated_bytes')} B, scanned {r.get('bytes_scanned')} B "
        f"(${r.get('cost_usd')}), {r.get('rows_returned')} rows; "
        f"spend 5m ${r['spend']['last_5m_usd']} / 60m ${r['spend']['last_60m_usd']}")
    return r


async def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--debug", action="store_true", help="SDK debug logging (protocol traffic)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("tools"); p.add_argument("filter", nargs="?", default="")
    p = sub.add_parser("describe"); p.add_argument("tool")
    p = sub.add_parser("call"); p.add_argument("tool"); p.add_argument("args", nargs="?", default="{}")
    p = sub.add_parser("py"); p.add_argument("code", help="Python source, or @path to read it from a file")
    profile_help = "aws_profile to sign with (default: $MCPCLI_AWS_PROFILE; required if that is unset)"
    p.add_argument("--profile", default=PROFILE, required=PROFILE is None, help=profile_help)
    p = sub.add_parser("logs"); p.add_argument("minutes", type=int); p.add_argument("query")
    p.add_argument("--group", action="append", required=True, help="log group name; repeatable")
    p.add_argument("--max-gb", type=float, default=20.0, help="per-query cap on the estimate (20 GB = $0.10)")
    p.add_argument("--budget-5m", type=float, default=1.0, help="rolling 5-minute spend budget, USD")
    p.add_argument("--budget-60m", type=float, default=5.0, help="rolling 60-minute spend budget, USD")
    p.add_argument("--max-rows", type=int, default=1000, help="GetQueryResults maxItems (<= 10000)")
    p.add_argument("--max-wait", type=int, default=300, help="stop waiting after this; the query keeps running")
    p.add_argument("--profile", default=PROFILE, required=PROFILE is None, help=profile_help)
    session_help = "agent session ID; picks the spend ledger /tmp/cwl-insights-ledger-<ID>.jsonl"
    p.add_argument("--session", required=True, help=session_help)
    p = sub.add_parser("spend"); p.add_argument("--session", required=True, help=session_help)
    a = ap.parse_args()
    logging.basicConfig(level=logging.DEBUG if a.debug else logging.WARNING, stream=sys.stderr,
                        format="%(asctime)s %(name)s %(levelname)s %(message)s")
    # The sbx gateway sends a non-standard "prime" SSE event at stream start; harmless.
    logging.getLogger("mcp.client.streamable_http").addFilter(
        lambda r: "Unknown SSE event: prime" not in r.getMessage())

    global LEDGER
    if a.cmd in ("logs", "spend"):
        LEDGER = ledger_path(a.session)
    if a.cmd == "spend":
        print(json.dumps(spend(ledger_read()), indent=1))
        return 0
    async with Gateway() as gw:
        if a.cmd == "tools":
            for t in (await gw.session.list_tools()).tools:
                if a.filter.lower() in t.name.lower():
                    print(f"{t.name} - {(t.description or '').splitlines()[0][:120] if t.description else ''}")
        elif a.cmd == "describe":
            t = next((t for t in (await gw.session.list_tools()).tools if t.name == a.tool), None)
            if t is None:
                log(f"no tool named {a.tool}")
                return 1
            print(t.description)
            print(json.dumps(getattr(t, "input_schema", None) or getattr(t, "inputSchema", None), indent=1))
        elif a.cmd == "call":
            print(await gw.call(a.tool, json.loads(a.args)))
        elif a.cmd == "py":
            code = Path(a.code[1:]).read_text() if a.code.startswith("@") else a.code
            print(json.dumps(await gw.py(code, a.profile), indent=1, default=str))
        elif a.cmd == "logs":
            r = await logs_query(gw, a.group, a.minutes, a.query, a.max_gb, a.budget_5m, a.budget_60m,
                                 a.max_rows, a.max_wait, a.profile)
            print(json.dumps(r, indent=1))
            if r["status"] != "Complete":
                return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except Exception as e:
        log(f"FAILED: {type(e).__name__}: {e}")
        sys.exit(1)
