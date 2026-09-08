---
name: firstmate-fork-rebase
description: Agent-only procedure for updating a firstmate home whose default branch carries its own commits on top of upstream, published to a fork. Use before updating firstmate in such a home, and whenever /updatefirstmate or a fleet-sync check reports this home skipped as diverged or behind with local commits it must keep.
user-invocable: false
metadata:
  internal: true
---

# firstmate-fork-rebase

`/updatefirstmate` is fast-forward only by design: it never forces, never stashes, and skips a diverged home rather than touching its work.
That is correct, and it is also why it can never update a home that keeps its own commits on top of upstream.
Such a home updates by rebasing those commits onto the fetched upstream and republishing them to its fork.

Read `git remote -v` for this home rather than assuming remote names.
The upstream is the remote the default branch tracks; the fork is the remote this home publishes its own commits to.
`data/learnings.md` records this home's concrete remotes and what its own commits are for.

## The update

```
git fetch <upstream>
git rebase <upstream>/<branch>
git push --force-with-lease <fork> <branch>
```

Use `git fetch` and not `git pull`: on a diverged branch `pull` merges by default, and a merge commit means the next update inherits both histories.
`--force-with-lease` and not `--force`, so a fork someone else advanced refuses instead of being overwritten.
A rebase that goes wrong needs no backup branch: `git rebase --abort` restores the branch mid-rebase, and `git reset --hard ORIG_HEAD` restores it afterwards.

Two things around those three commands do catch something:

- **Before**: no task may be in flight, because the rebase rewrites the tracked scripts and instructions a live worker is executing.
- **After the rebase, before the push**: run `bin/fm-lint.sh` and the tests covering the rebased commits.
  A local commit that patches a script upstream has since rewritten is where a silent semantic conflict hides, and rebase reports nothing.
  Re-run `git cherry -v <upstream>/<branch> <branch>` too: a commit whose change already landed upstream rebases to empty and should be dropped, not forced back in.

## Converging the fork back to upstream

The fork is a holding pattern, not a destination.
The goal is zero local commits, so the home drops the fork entirely and lives on upstream with plain `/updatefirstmate`.
Every rebase is the occasion to move toward that, which makes the supersession check part of the update rather than an optional extra.

A conflict is the signal, because it usually means upstream has since touched the same code for the same reason.
At each one, establish whether upstream has reached feature parity with the local commit before resolving anything:

- Read what upstream's version of the conflicting region now does, not just the diff.
- Grep upstream for the identifiers, markers, and knobs the local commit introduced - `git show <upstream>/<branch>:<path> | grep -c <symbol>` - since a parity implementation rarely reuses the local naming.
- Weigh scope, not just presence: upstream having a broader version of the same guarantee is parity, and upstream having a narrower one is not.

Then bring it to the captain with that evidence and a recommendation.
On parity, the local commit is dropped with `git rebase --skip`, and the tests it carried go with it once upstream covers the same path.
When it is not parity, the local commit is merged into upstream's structure rather than replacing it, and the reason it still exists is worth stating in `data/learnings.md`.
Report the local commit count after every rebase, because the number falling is the progress that matters.

Convergence happens by WAITING for upstream to land its own equivalent, never by upstreaming the fork's commits.
Do not open an upstream pull request for a local commit, and do not offer to.
The captain ruled this out 2026-09-08 after trying it once: the review cycle cost more tokens than the fix was worth to him, and he would rather wait for the fixes to arrive from upstream on their own.
So a local commit is carried until upstream reaches parity by its own route, and then dropped.

## Boundaries

- The push rewrites published history, so it needs the captain to authorize that concrete push.
- Never resolve a rebase conflict by discarding one of the home's own commits.
  Which of them still earns its place is the captain's call, informed by whether upstream has since covered it.
- Re-read `AGENTS.md` after the rebase, then run `/updatefirstmate` for any registered secondmate, which is now an ordinary fast-forward for each of them.
