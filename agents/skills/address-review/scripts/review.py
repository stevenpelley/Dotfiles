#!/usr/bin/env python3
"""Read and update review comments recorded in Neovim (config/nvim/lua/agent_review.lua).

Store: <git-common-dir>/agent-review/comments.jsonl, one JSON object per line,
shared by all worktrees of the repository. See agent_review.lua for the schema;
keep the two in sync.

    review.py path                       print the store path
    review.py list [--all|--status S] [--json]
    review.py show ID
    review.py reply ID -m TEXT           answer/ask without changing status
    review.py resolve ID -m TEXT [--commit SHA]
    review.py wontfix ID -m TEXT
    review.py reopen ID [-m TEXT]
    review.py prune                      drop resolved/wontfix comments

IDs may be abbreviated to any unique prefix. Run inside the repository (or
pass --repo DIR).
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import subprocess
import sys
import tempfile

STORE_DIR = "agent-review"
STORE_FILE = "comments.jsonl"
STATUSES = ("open", "resolved", "wontfix")


def git(*args: str, cwd: str | None = None) -> str | None:
    res = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    return res.stdout.strip() if res.returncode == 0 else None


def store_path(repo: str | None) -> str:
    common = git("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=repo)
    if not common:
        sys.exit("review.py: not inside a git repository")
    return os.path.join(common, STORE_DIR, STORE_FILE)


def load(path: str) -> list[dict]:
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


def save(path: str, items: list[dict]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".comments.")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        for c in items:
            f.write(json.dumps(c, ensure_ascii=False) + "\n")
    os.replace(tmp, path)


def find(items: list[dict], ident: str) -> dict:
    hits = [c for c in items if c.get("id") == ident] or [
        c for c in items if c.get("id", "").startswith(ident)
    ]
    if len(hits) != 1:
        sys.exit(f"review.py: {'no' if not hits else 'ambiguous'} comment matching {ident!r}")
    return hits[0]


def now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def is_sha(rev: str | None) -> bool:
    return bool(rev) and len(rev) == 40 and all(ch in "0123456789abcdef" for ch in rev)


_commit_cache: dict[str, str] = {}
_pr_branch_cache: dict[str, tuple[str | None, list[str]]] = {}


def trunk_names(repo: str | None) -> set[str]:
    names = {"main", "master"}
    head = git("symbolic-ref", "--short", "refs/remotes/origin/HEAD", cwd=repo)
    if head:
        names.add(head.split("/", 1)[-1])
    return names


def pr_branch(sha: str, repo: str | None) -> tuple[str | None, list[str]]:
    """(owning branch, all local branches containing sha).

    The owning ("PR") branch is the lowest branch of the stack that contains
    the commit: every other branch containing it also contains that branch's
    tip. None if the commit is on the trunk or the branches fork.
    """
    if sha not in _pr_branch_cache:
        out = git("branch", "--contains", sha, "--format=%(refname:short)", cwd=repo)
        names = out.split() if out else []
        owner = None
        if not set(names) & trunk_names(repo):
            for b in names:
                if all(
                    o == b
                    or subprocess.run(
                        ["git", "merge-base", "--is-ancestor", b, o], cwd=repo, capture_output=True
                    ).returncode
                    == 0
                    for o in names
                ):
                    owner = b
                    break
        _pr_branch_cache[sha] = (owner, names)
    return _pr_branch_cache[sha]


def describe_commit(sha: str, repo: str | None) -> str:
    """'abc12345 subject  [PR branch: x; also in: y]' (or the marker itself, e.g. UNCOMMITTED)."""
    if not is_sha(sha):
        return sha
    if sha not in _commit_cache:
        subject = git("log", "-1", "--format=%h %s", sha, cwd=repo) or f"{sha[:8]} (unknown commit)"
        owner, names = pr_branch(sha, repo)
        if owner:
            others = [n for n in names if n != owner]
            tag = f"PR branch: {owner}" + (f"; also in: {', '.join(others)}" if others else "")
        elif set(names) & trunk_names(repo):
            tag = "on trunk: " + ", ".join(sorted(set(names) & trunk_names(repo)))
        else:
            tag = "branches: " + (", ".join(names) or "none")
        _commit_cache[sha] = f"{subject}  [{tag}]"
    return _commit_cache[sha]


def short(rev: str | None) -> str:
    return rev[:8] if is_sha(rev) else (rev or "?")


def render(c: dict, repo: str | None) -> str:
    out = [
        f"## {c['id']} [{c.get('status', '?')}] {c.get('path')}:{c.get('line_start')}-{c.get('line_end')}"
        + (f"  ({c['context']})" if c.get("context") else "")
    ]
    side = c.get("side", "new")
    viewed = f"viewed: {short(c.get('rev'))} ({side} side"
    if c.get("other_rev"):
        viewed += f", diffed against {short(c['other_rev'])}"
    viewed += ")"
    if c.get("head"):
        viewed += f"; HEAD at review: {c['head']}"
    out.append(viewed)
    if c.get("other_path"):
        out.append(f"other side path: {c['other_path']}")
    commits = c.get("commits") or []
    label = "lines last touched by" if side == "new" else "changed (deleted/replaced) by one of"
    if commits:
        out.append(f"{label}:")
        out.extend(f"  - {describe_commit(s, repo)}" for s in commits)
    if c.get("code"):
        out.append("code:")
        out.extend(f"  | {line}" for line in c["code"])
    out.append("comment:")
    out.extend(f"  {line}" for line in (c.get("body") or "").splitlines())
    for r in c.get("replies") or []:
        fixed = f", fix {short(r['commit'])}" if r.get("commit") else ""
        out.append(f"reply from {r.get('by', '?')} ({r.get('at', '')}{fixed}):")
        out.extend(f"  {line}" for line in (r.get("body") or "").splitlines())
    return "\n".join(out)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--repo", help="repository directory (default: cwd)")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("path")
    ls = sub.add_parser("list")
    ls.add_argument("--all", action="store_true")
    ls.add_argument("--status", choices=STATUSES)
    ls.add_argument("--json", action="store_true")
    show = sub.add_parser("show")
    show.add_argument("id")
    for name in ("reply", "resolve", "wontfix", "reopen"):
        sp = sub.add_parser(name)
        sp.add_argument("id")
        sp.add_argument("-m", "--message", required=name != "reopen")
        sp.add_argument("--by", default="agent")
        if name in ("reply", "resolve"):
            sp.add_argument("--commit", help="commit containing the fix")
    sub.add_parser("prune")
    args = p.parse_args()

    path = store_path(args.repo)
    items = load(path)

    if args.cmd == "path":
        print(path)
    elif args.cmd == "list":
        wanted = None if args.all else (args.status or "open")
        sel = [c for c in items if wanted is None or c.get("status") == wanted]
        if args.json:
            print(json.dumps(sel, indent=2, ensure_ascii=False))
        elif not sel:
            print(f"no {wanted or ''} review comments ({path})".replace("  ", " "))
        else:
            print("\n\n".join(render(c, args.repo) for c in sel))
    elif args.cmd == "show":
        print(render(find(items, args.id), args.repo))
    elif args.cmd == "prune":
        kept = [c for c in items if c.get("status") == "open"]
        save(path, kept)
        print(f"pruned {len(items) - len(kept)} closed comment(s); {len(kept)} open remain")
    else:
        c = find(items, args.id)
        if args.message:
            reply = {"by": args.by, "body": args.message, "at": now()}
            commit = getattr(args, "commit", None)
            if commit:
                reply["commit"] = git("rev-parse", "--verify", f"{commit}^{{commit}}", cwd=args.repo) or commit
            c.setdefault("replies", []).append(reply)
        if args.cmd in ("resolve", "wontfix"):
            c["status"] = "resolved" if args.cmd == "resolve" else "wontfix"
        elif args.cmd == "reopen":
            c["status"] = "open"
        save(path, items)
        print(f"{c['id']}: {c['status']}")


if __name__ == "__main__":
    main()
