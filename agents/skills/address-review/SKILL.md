---
name: address-review
description: >-
  Find and address code review comments the user recorded in Neovim/diffview
  (stored in the repo's .git/agent-review/comments.jsonl). Use when the user
  says they have reviewed the code or commits and asks you to find, read,
  address, fix or respond to their review comments or feedback, including on
  stacked branches / PR stacks.
compatibility: Requires git and python3. Comments are created by the user's Neovim agent_review module.
---

# Address review comments

The user reviews your commits in Neovim (diffview) and records line-anchored
comments. Each comment knows the reviewed revision, file, line range, the
exact code, the enclosing function/class, and the commit(s) responsible for
those lines. Your job: read them, fix each one with a new commit on the PR branch it
belongs to, restack the branches above it, reply to each comment, and report
back.

## Tool

`scripts/review.py` (next to this file) reads and updates the comment store.
Run it from inside the repository (any worktree; the store is shared):

```bash
python3 <skill-dir>/scripts/review.py list            # open comments, human readable
python3 <skill-dir>/scripts/review.py list --json     # full records
python3 <skill-dir>/scripts/review.py show r1a2b3c
python3 <skill-dir>/scripts/review.py reply   r1a2b3c -m "question or note"     # stays open
python3 <skill-dir>/scripts/review.py resolve r1a2b3c -m "what changed" --commit <fix-sha>
python3 <skill-dir>/scripts/review.py wontfix r1a2b3c -m "why not"
```

`<skill-dir>` is the directory containing this SKILL.md (e.g.
`~/.kiro/skills/address-review`, `~/.omp/agent/skills/address-review`). Do not
edit `comments.jsonl` by hand — always go through the script. IDs accept any
unique prefix.

## Reading a comment

- `rev` is what the user was looking at: a commit SHA, `INDEX` or `WORKTREE`.
  Line numbers refer to that revision's version of `path`, not necessarily the
  current checkout. Locate the code by its `code` snippet and `context` —
  lines move as the stack changes.
- `side: new` → the commented lines exist in `rev`; `commits` (from git blame)
  are the commits that last touched them, each tagged with its PR branch.
- `side: old` → the user commented on removed/replaced lines (left side of the
  diff); `commits` lists commits between `rev` and `other_rev` touching the
  file. Use `git log -L<start>,<end>:<path>` or the diff to pick the one that
  made the change.
- `UNCOMMITTED` → the lines are working-tree changes; just edit the files.
- A commit outside the stack (already on the trunk) means the user commented
  on unchanged context; the fix belongs in the commit of the stack the
  comment is really about — usually the one being reviewed (`rev` or
  `other_rev`). Use judgment and say what you chose.
- `replies` hold the thread. A comment reopened with a user reply is a
  follow-up to your earlier reply or fix — read the whole thread.

## Workflow

1. `review.py list`. If nothing is open, say so and stop.
2. Understand the stack: `git log --oneline --decorate --graph <trunk>..<top>`
   for the top branch of the stack. Check `git status` is clean before
   touching branches; never discard user changes.
3. Triage every comment before editing:
   - clear change request → fix it;
   - question, or ambiguous/contested request → `reply` (comment stays open)
     instead of guessing; do not make a change you are unsure the user wants;
   - you disagree → `reply` with reasoning, or `wontfix` only if the comment
     itself invites that judgment.
4. Decide the **target branch** of each fix, before changing anything (SHAs
   change once you restack; branch names do not):
   - If the comment says where the fix goes ("do this in the next PR", "fix
     in branch X", "separate commit on top"), follow the comment.
   - Otherwise it is the PR branch the commented code belongs to: the
     listing tags each responsible commit `[PR branch: <name>; also in: ...]`
     — the lowest branch of the stack containing that commit. For `side: old`
     pick the commit that made the change first (see above).
   - Commit on the trunk / unchanged context → the PR branch being reviewed
     (the one owning `rev`, or `other_rev` for old-side comments).
   - `UNCOMMITTED` → no branch; edit the working tree and leave it
     uncommitted.
5. Work **bottom-up**, one target branch at a time, starting with the branch
   closest to the trunk (so each fix commit is never rewritten by a later
   restack):
   1. `git switch <target-branch>`.
   2. Make the fix and append it as a **new commit** at the tip of that
      branch — no `--amend`, no `--fixup`/squash. One commit per comment (or
      per tightly related group), following the repo's commit conventions,
      with a body line `Review: <id>[, <id>...]`. Run the project's relevant
      build/tests/linters.
   3. Restack every branch above it onto the new tip, from the top branch:

      ```bash
      git switch <top-branch>
      git rebase --update-refs <target-branch>
      ```

      This replays the commits above the old tip of `<target-branch>` onto its
      new tip, and `--update-refs` moves each intermediate stack branch along.
      Skip if `<target-branch>` is the top. Check afterwards that every stack
      branch moved (`git log --oneline --decorate --graph <trunk>..<top>`) —
      `--update-refs` does not move branches checked out in another worktree;
      report those. On conflicts, resolve only if the resolution is obvious
      and mechanical; otherwise `git rebase --abort` and report.
   4. Rerun tests on the upper branches if the fix could affect them.
6. Reply on every comment you handled: `resolve <id> -m "<what changed, where>"
   --commit <fix-sha>`. Keep replies short and specific — the user reads
   them in Neovim next to the code.
7. Never push unless asked; restacked branches that were already pushed need
   a force-push the user must request. Return to the branch the user had
   checked out.
8. Report: per comment, one line — id, file/context, what you did (fixed in
   `<sha>` on `<branch>`, replied with a question, won't fix), which branches
   were restacked, and test results.

Step 5.3 rewrites the commits of the upper branches. Running this skill is
the user's explicit request to do so; it does not license rewriting any
other history (the fix commits themselves are new, never amended).

## Rules

- Address only what the comments ask; no drive-by refactors.
- Respect the repository's own AGENTS.md/steering rules (tests, commit
  conventions, branch policy) — they take precedence over this workflow.
- If a comment's lines cannot be found any more (code removed or rewritten),
  reply explaining that instead of guessing.
