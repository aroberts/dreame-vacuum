#!/usr/bin/env bash
set -euo pipefail

# Canonical perpetual-fork sync engine. Vendored verbatim into each fork as
# scripts/sync-upstream.sh (substitute https://github.com/Tasshack/dreame-vacuum below). Keep this file as
# the single source of truth; do not hand-edit per-repo copies — re-vendor instead.

UPSTREAM_URL="https://github.com/Tasshack/dreame-vacuum"
STANDALONE_BRANCH="standalone"

# Which upstream tags this fork builds — the per-fork whitelist (an ERE).
# Default: everything (all version tags, including pre-releases and hotfixes).
# Narrow per fork if a noisy upstream is too chatty:
#   stable + hotfix:  '^v[0-9]+\.[0-9]+\.[0-9]+(-hotfix\.[0-9]+)?$'
#   stable only:      '^v[0-9]+\.[0-9]+\.[0-9]+$'
TAG_FILTER='^v[0-9]+\.'

# The build floor is ALWAYS computed over stable tags only — never TAG_FILTER.
# Load-bearing: `sort -V` orders a pre-release AFTER its final release
# (v1.2.3 < v1.2.3-alpha.1), the inverse of SemVer. If the floor were derived
# from a set that can contain pre-releases, a pre-release could become the floor
# and silently shadow the final release, which then never builds (this dropped
# sure's v0.7.1). A stable-only floor is immune no matter how wide TAG_FILTER is.
STABLE_FILTER='^v[0-9]+\.[0-9]+\.[0-9]+$'

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

ensure_upstream() {
  if ! git remote get-url upstream &>/dev/null; then
    info "Adding upstream remote"
    git remote add upstream "$UPSTREAM_URL"
  fi
}

# List a remote's tags matching an ERE, sorted ascending.
tags_matching() {
  local remote="$1" filter="$2"
  git ls-remote --tags "$remote" 'refs/tags/v*' \
    | awk '{print $2}' \
    | sed 's|refs/tags/||' \
    | grep -v '\^{}' \
    | grep -E "$filter" \
    | sort -V
}

latest_tag() { sort -V | tail -1; }

# True if $1 sorts strictly above $2 under version ordering.
semver_gt() {
  local higher
  higher=$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)
  [[ "$higher" == "$1" && "$1" != "$2" ]]
}

do_publish() {
  local tag="$1"
  git tag -d "$tag" 2>/dev/null || true
  git tag "$tag" || return 1
  git push origin "refs/tags/$tag" || return 1
  info "Pushed tag $tag"
}

# Sync one upstream tag: cherry-pick the standalone diff onto it and publish.
# Returns non-zero on ANY failure (conflict, fetch, push) WITHOUT aborting the
# overall run, so one bad tag never blocks the tags after it.
#
# Every tag is built from the SAME fixed base ($base_sha, dynamic-scoped from
# cmd_sync = the standalone at run start) — never from a previously-built tag.
# Chaining the base through each built tag (the old behaviour) means tag N is
# cherry-picked on top of tag N-1's result; cherry-pick uses that prior tag as the
# 3-way merge base, so if a run spans divergent release lines (e.g. a 1.3.x hotfix
# and a 1.5.x release together) the prior tag is not an ancestor of the next and
# every pick after the first conflicts. A fixed base is an ancestor of all forward
# tags, so each pick is a clean 3-way merge of just the customizations. On success
# the resolved HEAD is recorded in BUILT_SHA; cmd_sync advances the standalone
# branch once, at the end, to the highest successful build.
sync_one_tag() {
  local tag="$1" tag_sha
  BUILT_SHA=""
  tag_sha=$(git ls-remote --tags upstream "refs/tags/$tag" | awk '{print $1}' | head -1)
  [[ -n "$tag_sha" ]] || { echo "  cannot resolve upstream tag $tag" >&2; return 1; }

  git fetch upstream "$tag_sha" || return 1
  git checkout --detach "$tag_sha" || return 1

  if ! git cherry-pick "$base_sha"; then
    git cherry-pick --abort || true
    echo "  CONFLICT cherry-picking standalone onto $tag — skipped" >&2
    return 1
  fi

  do_publish "$tag" || return 1

  BUILT_SHA=$(git rev-parse HEAD) || return 1
}

cmd_sync() {
  ensure_upstream

  # Restore the checkout the workflow started from on ANY exit (success, die, or
  # conflict). The loop below detaches onto upstream tags, which don't contain
  # this script — left there, the workflow's `if: failure()` notify step finds no
  # script and dies with exit 127, so the failure alert never fires.
  SYNC_ORIG_HEAD=$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)
  trap 'git cherry-pick --abort >/dev/null 2>&1 || true; git checkout -q "$SYNC_ORIG_HEAD" || true' EXIT

  info "Fetching tag lists..."
  local upstream_candidates origin_built floor
  upstream_candidates=$(tags_matching upstream "$TAG_FILTER")
  origin_built=$(tags_matching origin "$TAG_FILTER")
  floor=$(tags_matching origin "$STABLE_FILTER" | latest_tag)

  [[ -z "$upstream_candidates" ]] && die "No upstream tags match TAG_FILTER ($TAG_FILTER)"
  [[ -z "$floor" ]] && die "No stable tag on origin to anchor the build floor. Bootstrap first: checkout a tag, cherry-pick standalone, then run: $0 publish <tag>"

  info "Build floor (latest stable on origin): $floor"

  # Build set = matches TAG_FILTER, sorts above the floor, and is not already on
  # origin. This is SET MEMBERSHIP, not a high-water mark: ordering is irrelevant
  # to inclusion, so hotfixes (and any post-floor tag) are never skipped, and a
  # pre-release can't shadow a final. The floor only excludes pre-bootstrap
  # history so we don't try to cherry-pick onto ancient upstream tags.
  local new_tags=""
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    semver_gt "$tag" "$floor" || continue
    grep -qxF -- "$tag" <<< "$origin_built" && continue
    new_tags="${new_tags}${tag}"$'\n'
  done <<< "$upstream_candidates"

  new_tags=$(echo "$new_tags" | sed '/^$/d' | sort -V)

  if [[ -z "$new_tags" ]]; then
    info "No new upstream tags to build (above floor $floor and matching $TAG_FILTER)"
    exit 0
  fi

  info "New upstream tags to process: $(echo "$new_tags" | tr '\n' ' ')"

  git fetch origin "$STANDALONE_BRANCH"
  local base_sha
  base_sha=$(git rev-parse "origin/$STANDALONE_BRANCH")
  info "Standalone base for this run: $base_sha"

  # Guard: a parentless (root) standalone cannot be cherry-picked cleanly — git
  # treats its entire tree as additions, so every file collides with the upstream
  # tag (add/add) and the whole sync drowns in conflicts. Fail fast with the repair
  # instead. This happens when the standalone is bootstrapped as an orphan (e.g.
  # `git checkout --orphan`, or squashed to a root) rather than committed on top of
  # the upstream base. A healthy standalone always has the upstream tag it was built
  # on as its parent, which the publish path (`git branch -f standalone HEAD` after a
  # cherry-pick onto a tag) preserves automatically.
  if ! git rev-parse -q --verify "${base_sha}^" >/dev/null 2>&1; then
    die "standalone ($base_sha) is a parentless root commit — cherry-picking it onto upstream tags will mass-conflict (add/add on every file).
    Repair by reparenting it onto the PURE UPSTREAM tag its tree is based on (the latest tag already published to origin):
      up_sha=\$(git ls-remote upstream 'refs/tags/<latest-published-tag>' | awk '{print \$1}' | head -1)
      new=\$(git commit-tree origin/$STANDALONE_BRANCH^{tree} -p \$up_sha -m \"\$(git log -1 --format=%B origin/$STANDALONE_BRANCH)\")
      git push origin \$new:$STANDALONE_BRANCH --force-with-lease
    Use the PURE upstream SHA from ls-remote, NOT origin's published tag of the same name — origin's tag already contains the customizations, so reparenting onto it would drop them from future syncs."
  fi

  # Process each tag independently, ALL from the same fixed base ($base_sha). A
  # failure (conflict/fetch/push) is recorded and the loop moves on — one bad tag
  # must not block the tags after it. Track the highest successful build so the
  # standalone branch can be advanced to it once, after the loop.
  local failed=() best_tag="" best_sha=""
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    info "Processing tag: $tag"
    if sync_one_tag "$tag"; then
      info "Successfully synced tag: $tag"
      if [[ -z "$best_tag" ]] || semver_gt "$tag" "$best_tag"; then
        best_tag="$tag"; best_sha="$BUILT_SHA"
      fi
    else
      failed+=("$tag")
      echo "==> WARNING: $tag failed; continuing with remaining tags" >&2
    fi
  done <<< "$new_tags"

  # Advance the standalone branch ONCE, to the highest successful build, so the
  # next run builds on the freshest base. Within THIS run every tag was cherry-
  # picked from the fixed run-start base (see sync_one_tag) — the standalone is
  # only moved here, never mid-loop, so tags never chain onto one another.
  if [[ -n "$best_sha" ]]; then
    git branch -f "$STANDALONE_BRANCH" "$best_sha"
    git push origin "$STANDALONE_BRANCH" --force-with-lease
    info "Advanced $STANDALONE_BRANCH to $best_tag ($best_sha)"
  fi

  if (( ${#failed[@]} )); then
    echo "" >&2
    echo "==> ${#failed[@]} tag(s) need manual resolution: ${failed[*]}" >&2
    echo "    For each, resolve the cherry-pick then publish:" >&2
    echo "      git fetch upstream" >&2
    echo "      tag_sha=\$(git ls-remote --tags upstream refs/tags/<tag> | awk '{print \$1}' | head -1)" >&2
    echo "      git checkout --detach \$tag_sha" >&2
    echo "      git cherry-pick origin/standalone" >&2
    echo "      # resolve conflicts, git add, git cherry-pick --continue" >&2
    echo "      ./scripts/sync-upstream.sh publish <tag>" >&2
    die "Sync finished with ${#failed[@]} unresolved tag(s) — successfully synced tags were still published"
  fi

  info "All new tags processed."
}

cmd_publish() {
  local tag="${1:?Usage: $0 publish <tag>}"
  do_publish "$tag"
  git branch -f "$STANDALONE_BRANCH" HEAD
  git push origin "$STANDALONE_BRANCH" --force-with-lease
  info "Updated $STANDALONE_BRANCH branch"
  info "Published $tag successfully."
}

# Page a human when an automated run fails, by opening (or commenting on) a
# Gitea issue assigned to NOTIFY_ASSIGNEE. Invoked from the workflow's
# `if: failure()` step — see the WHY below.
#
# WHY THIS EXISTS — Gitea sends its built-in "workflow run failed" email ONLY to
# the run's *trigger user*. Scheduled (cron) runs are triggered by the synthetic
# `gitea-actions` account, which has no mailbox, so cron failures are silent
# (a stuck sync can fail every 6h for days unnoticed). We page a human ourselves.
#
# CRITICAL — the issue must be authored by an identity OTHER than the assignee.
# Gitea never notifies you about issues you opened yourself, so author==assignee
# silently self-suppresses the alert. The workflow therefore passes a dedicated
# bot token as GITEA_TOKEN — NOT REPO_TOKEN (which authenticates as the human
# owner, so the alert would self-suppress) and NOT the built-in ${{ github.token }}
# (whose issue access depends on the instance's Actions token mode — under the
# "restricted" default it has none). Mint a scoped token for an automation user
# (scope: write:issue) and pass it via secrets; that user must have write access
# to the repo so the assignee sticks.
#
# Reads from the ambient Actions environment:
#   GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_RUN_ID  (auto-set by the runner)
#   GITEA_TOKEN        (declared in the step env from a write:issue bot secret)
#   NOTIFY_ASSIGNEE    (Gitea username to assign/cc; optional but recommended)
cmd_notify_failure() {
  : "${GITHUB_SERVER_URL:?notify-failure needs GITHUB_SERVER_URL (ambient in Actions)}"
  : "${GITHUB_REPOSITORY:?notify-failure needs GITHUB_REPOSITORY (ambient in Actions)}"
  local token="${GITEA_TOKEN:-${GITHUB_TOKEN:-}}"
  : "${token:?notify-failure needs GITEA_TOKEN}"
  local assignee="${NOTIFY_ASSIGNEE:-}"
  local api="${GITHUB_SERVER_URL}/api/v1/repos/${GITHUB_REPOSITORY}"
  local run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-}"
  # Overridable so a second caller (the release build in docker.yml) reports
  # under its own title and dedupes on its own latch instead of piggybacking on
  # an open sync-failure issue.
  local marker="${NOTIFY_MARKER:-perpetual-fork:sync-failure}"  # hidden in body; used to dedupe
  local title="${NOTIFY_TITLE:-🔴 Upstream sync is failing}"
  local subject="${NOTIFY_SUBJECT:-The automated upstream-sync workflow failed.}"

  # node is always present on an Actions runner — use it for JSON build/parse so
  # we depend on nothing beyond curl. An open marker'd issue means "still broken":
  # comment on it rather than opening a new issue every run.
  local existing
  existing=$(curl -fsSL -H "Authorization: token ${token}" \
      "${api}/issues?state=open&type=issues&limit=50" 2>/dev/null \
    | node -e 'let s="";const m=process.argv[1];process.stdin.on("data",d=>s+=d).on("end",()=>{let a;try{a=JSON.parse(s)}catch(e){return};const h=(a||[]).find(i=>(i.body||"").includes(m));if(h)process.stdout.write(String(h.number))})' "$marker" \
    || true)

  local payload
  if [[ -n "$existing" ]]; then
    info "Failure issue #$existing already open — adding a comment"
    payload=$(node -e 'process.stdout.write(JSON.stringify({body:`${process.argv[2]}\n\n${process.argv[1]}`}))' "$run_url" "$subject")
    curl -fsSL -X POST -H "Authorization: token ${token}" -H "Content-Type: application/json" \
      --data "$payload" "${api}/issues/${existing}/comments" >/dev/null
  else
    info "Opening a failure issue${assignee:+ assigned to $assignee}"
    payload=$(node -e '
      const [marker,url,assignee,title,subject]=process.argv.slice(1);
      const o={title:title,
        body:`<!-- ${marker} -->\n${subject}\n\nRun: ${url}\n\nWhile this issue stays open, repeated failures add a comment instead of opening a new issue. Close it once the pipeline is green again.${assignee?`\n\ncc @${assignee}`:""}`};
      if(assignee)o.assignees=[assignee];
      process.stdout.write(JSON.stringify(o))' "$marker" "$run_url" "$assignee" "$title" "$subject")
    curl -fsSL -X POST -H "Authorization: token ${token}" -H "Content-Type: application/json" \
      --data "$payload" "${api}/issues" >/dev/null
  fi
  info "Failure notification delivered."
}

case "${1:-sync}" in
  sync)           cmd_sync ;;
  publish)        shift; cmd_publish "$@" ;;
  notify-failure) cmd_notify_failure ;;
  *)              die "Unknown command: $1. Usage: $0 [sync|publish <tag>|notify-failure]" ;;
esac
