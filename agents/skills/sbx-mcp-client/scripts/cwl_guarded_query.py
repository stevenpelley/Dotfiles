# Guarded CloudWatch Logs Insights query. Runs INSIDE the AWS MCP `aws___run_script` sandbox
# (top-level await; `call_boto3` and `time` are provided by the sandbox). Not runnable locally.
#
# mcpcli.py (same directory) fills the __PLACEHOLDERS__ with repr() literals. To use it from a native MCP
# tool call instead, substitute the values by hand and pass the whole file as `code`.
#
# New query (QUERY_ID is None):
#   1. Run `<query> | estimate` (free) and refuse if the estimate exceeds MAX_BYTES.
#   2. StartQuery and wait for it to finish.
# Resume (QUERY_ID set): wait for that query to finish.
# Waiting is capped at WINDOW seconds per call, far below the ~90s point where run_script turns
# into a background task. If the query is still running, the result has its query_id and the
# caller calls again to resume. Data scanned is not monitored while the query runs; the estimate
# is the only cost gate. Finished results report the actual bytes scanned and cost.
import asyncio

GROUPS, QUERY, MINUTES = __GROUPS__, __QUERY__, __MINUTES__
QUERY_ID = __QUERY_ID__            # None = start a new query; else resume waiting on this one
MAX_BYTES = __MAX_BYTES__          # refuse if the estimate is larger than this
LIMIT_LABEL = __LIMIT_LABEL__      # which budget MAX_BYTES came from, for the refusal message
MAX_ROWS = __MAX_ROWS__            # GetQueryResults maxItems; also prevents boto3 auto-paging
WINDOW = 30                        # seconds to wait within one run_script call
REGION = "us-east-1"
PRICE_PER_GB = 0.005


async def logs(op, **params):
    return await call_boto3(service_name="logs", operation_name=op, region_name=REGION, params=params)


async def wait(query_id, **params):
    """Poll until the query leaves Scheduled/Running or WINDOW elapses; return the last response."""
    while (r := await logs("GetQueryResults", queryId=query_id, **params))["status"] in ("Scheduled", "Running") \
            and time.time() - t0 < WINDOW:
        await asyncio.sleep(1)
    return r


def cost(b):
    return round((b or 0) / 1e9 * PRICE_PER_GB, 4)


t0 = time.time()
result = {"query_id": QUERY_ID}
if QUERY_ID is None:
    end = int(time.time())
    rng = {"logGroupNames": GROUPS, "startTime": end - MINUTES * 60, "endTime": end}
    e = await wait((await logs("StartQuery", queryString=QUERY + " | estimate", **rng))["queryId"])
    est = int(e["results"][0][0]["value"]) if e.get("results") else None
    result.update(estimated_bytes=est, estimated_cost_usd=cost(est))
    if est is None:
        result.update(status="Refused", reason=f"estimate unavailable (estimate query {e['status']})")
    elif est > MAX_BYTES:
        result.update(status="Refused", reason=f"estimate {est / 1e9:.3f} GB > {LIMIT_LABEL} "
                      f"({MAX_BYTES / 1e9:.3f} GB)")
    else:
        result["query_id"] = (await logs("StartQuery", queryString=QUERY, **rng))["queryId"]

if result["query_id"] is not None:
    r = await wait(result["query_id"], maxItems=MAX_ROWS)
    result["status"] = r["status"]
    if r["status"] not in ("Scheduled", "Running"):
        st = r.get("statistics", {})
        result.update(rows_returned=len(r.get("results", [])), records_matched=st.get("recordsMatched"),
                      records_scanned=st.get("recordsScanned"), bytes_scanned=st.get("bytesScanned"),
                      gb_scanned=round((st.get("bytesScanned") or 0) / 1e9, 3),
                      cost_usd=cost(st.get("bytesScanned")),
                      rows=[{f["field"]: f["value"] for f in row if f["field"] != "@ptr"}
                            for row in r.get("results", [])])
result
