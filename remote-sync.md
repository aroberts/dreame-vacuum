# Upstream Tag Sync

This fork automatically tracks upstream releases from [Tasshack/dreame-vacuum](https://github.com/Tasshack/dreame-vacuum) and overlays the standalone changes on top of each new tag. The changes themselves are documented in [FORK.md](FORK.md).

## How it works

- The `sync-upstream.yml` Gitea workflow runs every 6 hours (and can be triggered manually)
- It builds the set of upstream tags that match `TAG_FILTER`, sort above the latest stable tag on origin, and are not on origin yet. `TAG_FILTER` is the canonical default `^v[0-9]+\.`, so upstream betas (`v2.0.0b25` style) are built as well as stable `vX.Y.Z` releases
- For each new tag, it cherry-picks the single squashed commit from the `standalone` branch
- On success: pushes the tag to origin
- On a cherry-pick conflict for a tag: that tag is skipped and reported, the remaining tags still build, and the run exits non-zero at the end (which fires the failure notification below)

There is no Docker build. This is a Home Assistant custom integration, installed through HACS from GitHub (see **GitHub mirror and HACS releases**).

## GitHub mirror and HACS releases

HACS only installs from GitHub, and it offers updates from GitHub Releases, not bare tags. Two pieces connect the Gitea sync to HACS:

1. **Push mirror.** `forks/dreame-vacuum` push-mirrors to [github.com/aroberts/dreame-vacuum](https://github.com/aroberts/dreame-vacuum) on every push (Settings → Repository → Mirror). A push mirror runs `git push --mirror`, so GitHub holds exactly the Gitea refs. Never push to GitHub directly: the next mirror run overwrites it. The mirror's GitHub token needs Contents write and the `workflow` scope, because the pushed refs contain `.github/workflows` files.
2. **Release workflow.** `.github/workflows/release.yml` (in `standalone`, so on every synced tag) runs on GitHub when a `v*` tag arrives and creates a Release for it. Tags matching `[0-9](a|b|rc)[0-9]+$` become prereleases, which HACS hides unless beta versions are enabled for the repository.

GitHub creates no tag events when a single push carries more than three tags. A mirror push after a sync that published several tags at once can therefore miss Releases. Create a missed one by hand:

```bash
gh release create <tag> --repo aroberts/dreame-vacuum --verify-tag --title <tag> \
  --notes "Upstream <tag> with this fork's changes applied. See FORK.md."
```

or run the workflow manually with the tag as input: `gh workflow run release.yml --repo aroberts/dreame-vacuum -f tag=<tag>`.

The GitHub default branch is `ar-master`, matching Gitea. HACS reads `hacs.json` from the default branch.

Upstream's own `.github/workflows` (hassfest, HACS validation) run on GitHub for every pushed ref. Gitea ignores them on every branch that contains `.gitea/workflows`, so on Gitea they only run for pushes to `master`.

## Failure notifications

When a sync run fails, the workflow opens a Gitea issue (titled "🔴 Upstream sync is failing") and assigns it to the maintainer, who is watching the repo — so the failure lands as a real notification + email. While that issue stays open it acts as a dedupe latch: subsequent failures add a comment rather than opening a new issue every 6 hours. Close the issue once the sync is green again; the next failure will open a fresh one.

**Why this is a separate step and not Gitea's built-in alerting.** Gitea emails its built-in "workflow run failed" notice only to the run's *trigger user*. Scheduled (cron) runs are triggered by the synthetic `gitea-actions` account, which has no mailbox, so cron failures notify no one — they are silent by default. The workflow therefore pages a human itself.

Two non-obvious constraints shape how it does that:

- **The issue must be authored by someone other than the assignee.** Gitea never notifies you about issues you opened yourself, so if the author and assignee are the same user the alert is silently self-suppressed. The notify step authenticates as a dedicated bot (`secrets.ISSUE_TOKEN`, a forks-bot token scoped `write:issue`) — deliberately *not* `REPO_TOKEN`, which authenticates as the human owner.
- **The built-in `${{ github.token }}` is not used.** Its access depends on the instance's Actions token mode; under the "restricted" default it has no issue scope and cannot open the issue at all. A dedicated scoped token sidesteps that entirely. The bot user needs write access to the repo for the assignee to stick (forks-bot is on the org `Owners` team).

`GITHUB_SERVER_URL`, `GITHUB_REPOSITORY`, and `GITHUB_RUN_ID` are read from the ambient Actions environment; only `GITEA_TOKEN` (= `ISSUE_TOKEN`) and `NOTIFY_ASSIGNEE` are passed explicitly in the step.

## Branch layout

| Branch | Purpose |
|---|---|
| `ar-master` | Working branch (default on Gitea and GitHub). Contains all standalone changes, workflows, and scripts. |
| `standalone` | Single squashed commit of all standalone changes. The sync script cherry-picks this onto new upstream tags, then updates the branch with the freshest diff. |
| `master` | Tracks upstream. Not modified by automation. |

## Scripts

### Full sync (automated)

```bash
./scripts/sync-upstream.sh sync
```

Fetches upstream, finds new tags, cherry-picks standalone onto each, tags, and pushes.

### Publish (manual recovery)

```bash
./scripts/sync-upstream.sh publish <tag>
```

Tags the current HEAD and pushes. Also updates the `standalone` branch.

`publish` pushes the tag without force. If origin already has a tag of that name (for example the pure upstream tag, which the initial setup pushed for every upstream release), delete it first: `git push origin :refs/tags/<tag>`.

## Recovering from a conflict

When the automated sync fails due to a cherry-pick conflict:

```bash
git fetch upstream
tag_sha=$(git ls-remote --tags upstream refs/tags/<tag> | awk '{print $1}' | head -1)
git checkout --detach $tag_sha
git cherry-pick origin/standalone
# resolve conflicts, git add, git cherry-pick --continue
./scripts/sync-upstream.sh publish <tag>
```

Several upstream files use CRLF line endings (`dreame/device.py`, `dreame/map.py`, `dreame/types.py`, `dreame/__init__.py`, `select.py`, `vacuum.py`, `const.py`, `hacs.json`). Keep them CRLF when resolving, or the next sync conflicts again. FORK.md's **Maintaining** section lists what else to check after an upstream release.

## Repairing a root-commit standalone

If the sync fails immediately with `standalone (...) is a parentless root commit`,
the `standalone` branch was bootstrapped as an orphan (no parent). Such a commit
can't be cherry-picked onto an upstream tag — git treats its entire tree as
additions and every file collides. The fix is to give it the upstream tag its tree
is built on as a parent, *without changing the tree*:

```bash
# The latest tag already published to origin is the base the standalone sits on.
latest=$(git ls-remote --tags origin 'refs/tags/v*' | awk '{print $2}' \
  | sed 's|refs/tags/||' | grep -v '\^{}' | sort -V | tail -1)

# IMPORTANT: resolve that tag against UPSTREAM, not origin. origin's tag of the
# same name already contains the fork customizations; reparenting onto it would
# make the cherry-pick diff empty-ish and silently drop customizations on the next
# sync. You want the pure upstream commit.
up_sha=$(git ls-remote upstream "refs/tags/$latest" | awk '{print $1}' | head -1)

new=$(git commit-tree origin/standalone^{tree} -p "$up_sha" \
  -m "$(git log -1 --format=%B origin/standalone)")

# Sanity-check: the diff should be exactly the fork's customization set, and a
# cherry-pick onto the base must apply cleanly.
git diff --name-only "$up_sha" "$new"
git push origin "$new":standalone --force-with-lease
```

Going forward the sync's publish path keeps the parent intact, so this is a
one-time repair per fork.

## Secrets

The Gitea secrets live at the org level (`forks`), so no per-repo setup is required.

| Secret | Purpose |
|---|---|
| `REPO_TOKEN` | Allows forks-bot to push tags and branches back to origin |
| `ISSUE_TOKEN` | forks-bot token scoped `write:issue`; lets the sync workflow open the failure-notification issue as a non-owner author (see **Failure notifications**) |

`PACKAGE_TOKEN` is also provided by the org but unused here, since nothing is pushed to the container registry. The GitHub release workflow uses GitHub's built-in `github.token`. The push mirror's GitHub token is stored in the mirror settings, not as a secret.

## Adding new standalone changes

1. Make changes on `ar-master`
2. Recreate the `standalone` branch with a fresh squash:
   ```bash
   git checkout master
   git branch -D standalone
   git checkout -b standalone
   git merge --squash ar-master
   git commit -m "<concise description of customizations>"
   git push origin standalone --force-with-lease
   ```
3. The next sync run will use the updated commit
