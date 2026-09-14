#!/bin/sh
# Credential guard. One implementation, two callers: the pre-commit hook scans
# STAGED content, CI scans a COMMIT RANGE. They must never drift, which is why
# there is only this file.
#
#   secret-guard.sh                  scan staged changes (pre-commit)
#   secret-guard.sh --range A...B    scan added lines in a range (CI)
#
# Why it exists: .run/CaseApplication.run.xml was committed on 2026-02-21 with a
# live AWS_ACCESS_KEY_ID and secret. It went unnoticed for seven months, cost a
# git-filter-repo rewrite plus a force-push of every branch on 2026-09-14, and
# the blobs REMAIN reachable through refs/pull/* which no client can delete.
# The only real remedy was rotating the key. Prevention is cheaper.
#
# Two tiers, deliberately:
#   BLOCK — patterns that are almost certainly a real credential.
#   WARN  — secret-SHAPED text. Measured over 900 real commits in six repos, a
#           blocking version fired 46 times and was wrong every time (k8s
#           `existingSecret:` references, `auth_token: "integration-token"` test
#           fixtures, and `token: 'serviceaccount'` in an ontology synonym
#           table). Blocking on those teaches people to use --no-verify, which
#           costs more than the rule catches.
#
# POSIX sh. No dependencies, no network.

RANGE=""
[ "$1" = "--range" ] && { RANGE="$2"; [ -n "$RANGE" ] || { echo "--range needs a revision range" >&2; exit 2; }; }

RC=0
hit() {
  [ "$RC" -eq 0 ] && { echo ""; echo "  CREDENTIAL GUARD FAILED"; echo ""; }
  RC=1
  printf '    %s\n' "$1"
}

if [ -n "$RANGE" ]; then
  FILES=$(git diff --name-only --diff-filter=ACM "$RANGE")
  ADDED=$(git diff --diff-filter=ACM -U0 "$RANGE" | grep '^+' | grep -v '^+++')
else
  FILES=$(git diff --cached --name-only --diff-filter=ACM)
  ADDED=$(git diff --cached --diff-filter=ACM -U0 | grep '^+' | grep -v '^+++')
fi

# ── Tier 0: paths that must never be committed ────────────────────────────────
# Path-matched, so an obfuscated or empty file is caught just the same.
for f in $FILES; do
  case "$f" in
    .run/*.run.xml|*/.run/*.run.xml)
      hit "$f — IDE run config; these carry env blocks with live credentials" ;;
    *.pem|*.p12|*.pfx|*.jks|*.keystore|id_rsa|*/id_rsa|id_ed25519|*/id_ed25519)
      hit "$f — private key / keystore material" ;;
    .env|*/.env|.env.local|*/.env.local|.env.prod|*/.env.prod|.env.prod-local|*/.env.prod-local)
      hit "$f — real env file (commit a .env.example instead)" ;;
  esac
done

# Allowlisted lines and AWS's own documentation values are dropped before scanning.
SCAN=$(printf '%s\n' "$ADDED" \
  | grep -v 'pragma: allowlist secret' \
  | grep -v 'AKIAIOSFODNN7EXAMPLE' \
  | grep -v 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY')

# `hit` must be called from THIS shell, never inside a pipeline: a `... | while
# read` loop runs in a subshell, so RC=1 is set in a child and discarded. That
# bug shipped in the first cut of this file and made the ENTIRE pattern tier a
# no-op while still reporting success. Only a mutation test caught it.
check() {
  m=$(printf '%s\n' "$SCAN" | grep -nEi "$1" | head -3)
  if [ -n "$m" ]; then
    hit "$2"
    printf '%s\n' "$m" | cut -c1-110 | sed 's/^/      /'
  fi
}

# ── Tier 1: BLOCK ─────────────────────────────────────────────────────────────
check '(A3T[A-Z0-9]|AKIA|ASIA|ABIA|ACCA)[A-Z0-9]{16}' 'AWS access key id'
check 'aws_secret_access_key["'"'"' ]*[:=][ ]*["'"'"']?[A-Za-z0-9/+=]{40}' 'AWS secret access key'
check 'BEGIN [A-Z ]*PRIVATE KEY'                      'private key block'
check 'gh[pousr]_[A-Za-z0-9]{36}'                     'GitHub token'
check 'github_pat_[A-Za-z0-9_]{60,}'                  'GitHub fine-grained PAT'
check 'xox[baprs]-[A-Za-z0-9-]{10,}'                  'Slack token'
check 'AIza[0-9A-Za-z_-]{35}'                         'Google API key'
check 'sk_live_[0-9a-zA-Z]{20,}'                      'Stripe live secret key'
check 'glpat-[0-9A-Za-z_-]{20,}'                      'GitLab PAT'

# ── Tier 2: WARN ──────────────────────────────────────────────────────────────
WARN=$(printf '%s\n' "$SCAN" \
  | grep -Ei '["'"'"']?(password|passwd|secret|api_?key|token)["'"'"']?[ ]*[:=][ ]*["'"'"'][^"'"'"'${}]{12,}["'"'"']' \
  | grep -vEi '(existing|k8s|kube)?secret(name|ref|key_?ref)?[ ]*[:=]' \
  | grep -vEi '(example|dummy|fake|sample|placeholder|changeme|test|fixture|localhost)' \
  | head -3)
if [ -n "$WARN" ]; then
  echo ""
  echo "  NOTE — secret-shaped assignment (not blocking; confirm it is not real):"
  printf '%s\n' "$WARN" | cut -c1-110 | sed 's/^/      /'
  echo ""
fi

if [ "$RC" -ne 0 ]; then
  cat <<'MSG'

  If this is a false positive, append to the offending line:
      pragma: allowlist secret

  That keeps the exception in the diff, where a reviewer sees it.
  Do NOT use --no-verify: CI runs this same script on the pull request.

MSG
fi
exit $RC
