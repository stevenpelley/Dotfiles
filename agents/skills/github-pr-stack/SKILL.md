---
name: github-pr-stack
description: >-
  GitHub only. Build, update, push, and merge stacked pull requests kept on one
  linear branch using git and the gh stack extension, and control which PRs run
  GitHub Actions CI with `[skip ci]` marker commits and the stack-ci script.
  Use when creating a GitHub PR stack, fixing a lower PR, syncing after a
  merge, or enabling/disabling CI on stack PRs. If the repository has its own
  PR-stack skill or instructions, follow those instead.
compatibility: GitHub repositories only. Requires git (2.38+), python3, gh, and the gh-stack extension (gh extension install github/gh-stack).
---

# GitHub PR stacks

These instructions apply to GitHub (GitHub stacked PRs and GitHub Actions).
For other hosts, or when the repository documents its own stack workflow,
do not use them.

## Rules

- Never push, open, edit, link, or merge PRs without the user's explicit
  instruction. `gh stack submit`, `push`, `sync`, and `merge` all push or
  change GitHub state.
- Every branch must pass the project's full check (as the project's agent
  instructions or CI define it) before it is pushed.
- Never merge a PR whose branch still ends in a CI marker (see below).
- Keep the stack linear: no merge commits.

## Tools

- **git** edits the stack: fixups, autosquash rebases, `--update-refs`.
- **`gh stack`** (`gh extension install github/gh-stack`) creates the GitHub
  stack, pushes, syncs after merges, and merges. Its local tracking
  (`<git-common-dir>/gh-stack`) records branch names, so it keeps working after
  git or `stack-ci` move the branch refs.
- **`stack-ci`** (`scripts/stack-ci` in this skill) adds and removes CI markers.

## Layout

The stack is one linear branch on top of the base (the repo's default branch
unless the user says otherwise). Each PR is a contiguous run of commits, and
its branch ref points at that PR's last commit. You work on the top branch.

- Names: `<slug>--01`, `<slug>--02`, …; the top PR's branch is the working branch.
- PR 1 targets the base; PR *k* targets PR *k*−1's branch.
- PR titles end in `[k/N]`, following the repo's title conventions.

Build it while implementing: after finishing PR *k*, run `git branch <slug>--0k`
and keep committing on the working branch. Rename the working branch to the top
name at the end (`git branch -m <slug>--NN`).

## Creating the GitHub stack

A chain of PRs whose bases point at each other is not a stack; GitHub stacks
are created explicitly (in the browser: "Preview stack" → "Create stack", or
with `gh stack`). A workflow whose `pull_request` trigger filters on
`branches:` may not run for a PR based on another stack branch until that PR
is in a stack whose trunk matches the filter.

```bash
stack-ci disable --all                     # markers on every PR
stack-ci enable --first --last             # or the PRs the user chooses
gh stack init --base <base> <slug>--01 ... <slug>--NN   # local tracking only
git checkout <slug>--NN
gh stack submit --auto                     # on the user's instruction
```

`gh stack init` adopts existing branches and does not push. `gh stack submit
--auto` pushes every branch, opens draft PRs with the right bases, and creates
the stack. Its titles are generated from branch names, so set real titles and
descriptions afterwards with `gh pr edit <pr> --title ... --body ...`. Linking
starts CI on each PR without a marker, so set markers first.

To write the PRs by hand instead, push, open drafts with
`gh pr create --draft --base <previous-branch>`, then
`gh stack link --base <base> <pr1> ... <prN>`. Pass PR numbers: given branch
names, `gh stack link` pushes them.

## Changing the stack

- **Fix to existing commits** (the usual case, including review responses):
  ```bash
  git commit --fixup=<sha-in-PR-k>
  GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash --update-refs <base>
  ```
  `--update-refs` moves every PR branch ref in the same rebase. `gh stack` has
  no fixup or autosquash command.
- **New commit in PR *k*:** commit it on the top branch, then
  `stack-ci move <sha> <branch-or-position>`. It lands just before PR *k*'s
  marker, or at the end of PR *k* when there is no marker.
- **Push:** `gh stack push`. It pushes every branch atomically with
  `--force-with-lease` and skips merged or queued PRs. Without gh-stack
  tracking, `stack-ci push` does the same for branches that differ from the
  remote.

On conflicts, resolve and `git rebase --continue`; if the resolution is not
obvious, `git rebase --abort` and ask.

## Merging

- `gh pr merge` fails on a stacked PR. Use
  `gh stack merge <pr> --yes --<squash|merge|rebase>`: it merges every PR up to
  and including `<pr>` in one all-or-nothing operation. The PRs must not be
  drafts (`gh pr ready <pr>`), and the repo's merge requirements apply with no
  bypass.
- Then `gh stack sync --prune`: it fetches, rebases the remaining PRs onto the
  updated base (dropping the merged commits, including after a squash merge),
  pushes them, and deletes the merged local branches. GitHub retargets the next
  PR to the base by itself. Markers on the remaining PRs are kept.

## CI markers

GitHub skips `push` and `pull_request` workflows when the PR's HEAD commit
message contains `[skip ci]`
([docs](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/skip-workflow-runs)).
A skipped required check stays "Pending" and blocks the merge. Markers affect
GitHub Actions only; GitHub App checks (code scanners and the like) may still
run.

A **marker** is an empty commit `ci: skip checks on <branch> [skip ci]` at the
tip of a PR branch. Rebasing the stack force-pushes every branch, but only
branches without a marker run CI. Markers are separate commits so that turning
CI on or off never rewords real commits, and reviewers can see that CI is
skipped on purpose.

Markers are on by default for every PR in a new stack.

### The `stack-ci` script

`scripts/stack-ci` in this skill directory. It needs only Python 3.9+ and git
(2.38+ for `move`). Run it from the top branch; the base defaults to
`$STACK_CI_BASE`, then `origin/HEAD` (override with `--base`).

| Command | Effect |
|---|---|
| `stack-ci status` | Each branch: position, CI `runs`/`skipped`, remote `in sync`/`differs`/`not pushed` |
| `stack-ci disable <sel>` | Add markers |
| `stack-ci enable <sel>` | Drop markers so the next push runs CI |
| `stack-ci move <sha> <sel>` | Move a commit into a PR, before its marker |
| `stack-ci push [--dry-run]` | `git push --atomic --force-with-lease` of every branch that differs from the remote |

`<sel>` is branch names or 1-based positions, or `--all`, `--first`, `--last`.
`enable` and `disable` only drop or insert empty commits, so trees never change
and no conflicts are possible. They never push; follow them with
`gh stack push` when the user asks.

### Which PRs run CI first

All PRs must pass CI before the stack merges. The choice is only which PRs to
verify and debug first. Use what the user asks for; otherwise use the default.

- **First PR:** a change to it rebases every PR above it, so it is the most
  valuable to verify early.
- **Last PR:** it holds the final state of the whole stack; a failure there
  means the stack as a whole is broken.
- **Default:** first and last.

After the first push, fixes from CI, bot reviews, and human review go in as
fixups. Pushes then rerun CI only on PRs that are already enabled; disable
those again during heavy iteration if the reruns are not wanted.

### Converging before merge

When the user asks:

- **All at once:** `stack-ci enable --all`, then `gh stack push`.
- **Bottom-up:** for *k* = 1…N: `stack-ci enable k`, `gh stack push`,
  `gh pr checks <pr> --watch`, fix failures as fixups, continue.

### Observed behavior and caveats

- A fully marked stack can be submitted, and force-pushed after a rebase,
  without starting Actions runs; with one PR enabled, only that PR runs.
- `gh stack view`, `push`, `sync`, and `merge` keep working after
  `git rebase --update-refs` and `stack-ci` rewrite the branches.
- A push to a stacked PR without a marker sometimes starts two `pull_request`
  `synchronize` runs for the same commit; the trigger is unclear. Cancel the
  duplicate with `gh run cancel <id>` if it matters.
- Squash and rebase merges can carry a marker's message into the base branch
  and skip the base branch's own CI run. Enabling CI before merge prevents this.
- A stack that contains a merged PR cannot be unstacked; it stays on GitHub as
  closed.
