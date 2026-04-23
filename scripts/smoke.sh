#!/usr/bin/env bash
# End-to-end smoke test: Phoenix HTTP → BoltexNif library → full mix test suite.
#
# Env (all have sane defaults):
#   NEO4J_URI, NEO4J_USER, NEO4J_PASSWORD — database credentials.
#   PHX_URL         — Phoenix base URL (default http://localhost:4000).
#   SKIP_PHX=1      — skip Phase 1 (Phoenix HTTP checks).
#   SKIP_MIX_TEST=1 — skip Phase 3 (full `mix test --include live`).
#
# Example:
#   NEO4J_URI=bolt://mybox:7687 NEO4J_PASSWORD=secret ./scripts/smoke.sh
set -euo pipefail

# Repo root (one level above this script).
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

NEO4J_URI="${NEO4J_URI:-bolt://neo4j-y1jklcomcab53zd7naxy8fqx.globi.cl:7687}"
NEO4J_USER="${NEO4J_USER:-neo4j}"
NEO4J_PASSWORD="${NEO4J_PASSWORD:-estaesunapruebadepass}"
PHX_URL="${PHX_URL:-http://localhost:4000}"
SKIP_PHX="${SKIP_PHX:-0}"
SKIP_MIX_TEST="${SKIP_MIX_TEST:-0}"

export NEO4J_URI NEO4J_USER NEO4J_PASSWORD

if [ -t 1 ]; then
  G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'
else
  G=''; R=''; Y=''; B=''; N=''
fi

step() { printf "\n${B}▶ %s${N}\n" "$1"; }
ok()   { printf "  ${G}✓${N} %s\n" "$1"; }
warn() { printf "  ${Y}⚠${N} %s\n" "$1"; }
die()  { printf "  ${R}✗${N} %s\n" "$1" >&2; exit 1; }

TMP_COOKIE="$(mktemp)"
TMP_PAGE="$(mktemp)"
trap 'rm -f "$TMP_COOKIE" "$TMP_PAGE"' EXIT

# ============================================================================
# Phase 1 — Phoenix HTTP
# ============================================================================

if [ "$SKIP_PHX" != "1" ]; then
  step "Phase 1: Phoenix HTTP ($PHX_URL)"

  if ! curl -sf -o /dev/null --max-time 3 "$PHX_URL/"; then
    die "Phoenix not reachable at $PHX_URL. Start it with 'cd phoenix_neo4j && mix phx.server', or pass SKIP_PHX=1."
  fi
  ok "GET / reachable"

  code=$(curl -s -o /dev/null -w "%{http_code}" "$PHX_URL/neo4j")
  [ "$code" = "200" ] && ok "GET /neo4j → $code" || die "GET /neo4j → $code"

  # Pick up session + CSRF token.
  curl -sc "$TMP_COOKIE" "$PHX_URL/neo4j" -o "$TMP_PAGE"
  TOKEN=$(grep -oE 'name="_csrf_token" value="[^"]+"' "$TMP_PAGE" | head -1 | sed 's/.*value="//;s/"$//')
  [ -n "${TOKEN:-}" ] || die "could not extract CSRF token from /neo4j"
  ok "CSRF token extracted (${#TOKEN} bytes)"

  for name in Ada Grace Linus; do
    code=$(curl -sb "$TMP_COOKIE" -X POST "$PHX_URL/neo4j/greeter" \
      --data-urlencode "_csrf_token=$TOKEN" \
      --data-urlencode "greeter[name]=$name" \
      -o /dev/null -w "%{http_code}")
    [ "$code" = "302" ] && ok "POST greeter=$name → $code" || die "POST greeter=$name → $code"
  done

  cnt=$(curl -s "$PHX_URL/neo4j" | grep -oE 'Greeters <span[^>]*>[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
  cnt="${cnt:-0}"
  if [ "$cnt" -ge 3 ]; then
    ok "listing reports $cnt greeters (expected ≥3)"
  else
    die "listing reports $cnt greeters; expected ≥3"
  fi

  code=$(curl -sb "$TMP_COOKIE" -X POST "$PHX_URL/neo4j/greeter" \
    --data-urlencode "_csrf_token=$TOKEN" \
    --data-urlencode "_method=delete" \
    -o /dev/null -w "%{http_code}")
  [ "$code" = "302" ] && ok "DELETE all → $code" || die "DELETE all → $code"

  cnt=$(curl -s "$PHX_URL/neo4j" | grep -oE 'Greeters <span[^>]*>[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
  cnt="${cnt:-?}"
  [ "$cnt" = "0" ] && ok "listing cleared" || warn "expected 0 greeters after delete, got $cnt"
else
  step "Phase 1: Phoenix HTTP (skipped: SKIP_PHX=1)"
fi

# ============================================================================
# Phase 2 — BoltexNif library (runs scripts/smoke.exs)
# ============================================================================

step "Phase 2: BoltexNif library"
mix run scripts/smoke.exs

# ============================================================================
# Phase 3 — mix test --include live
# ============================================================================

if [ "$SKIP_MIX_TEST" != "1" ]; then
  step "Phase 3: mix test --include live"
  mix test --include live
  ok "full test suite passed"
else
  step "Phase 3: mix test (skipped: SKIP_MIX_TEST=1)"
fi

printf "\n${G}══ smoke passed ══${N}\n"
