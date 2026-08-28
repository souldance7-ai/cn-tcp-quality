#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MOCK_BIN="$ROOT/tests/mock-bin"
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/cn-tcp-quality-test.XXXXXX")
trap 'rm -rf -- "$TEST_TMP"' EXIT

chmod +x "$ROOT/cn-tcp-quality.sh" "$MOCK_BIN"/*
bash -n "$ROOT/cn-tcp-quality.sh"
"$ROOT/cn-tcp-quality.sh" --self-test --no-color

PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --count 5 --parallel 4 --no-color --output "$TEST_TMP/dual" >/dev/null

[ "$(wc -l < "$TEST_TMP/dual/tcp-quality.csv")" -eq 31 ]
[ "$(grep -c ',正常,' "$TEST_TMP/dual/tcp-quality.csv")" -eq 30 ]

MOCK_NO_IPV6=1 PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --count 5 --parallel 4 --no-color --output "$TEST_TMP/no-ipv6" >/dev/null

[ "$(grep -c '^IPv6,.*,跳过,' "$TEST_TMP/no-ipv6/tcp-quality.csv")" -eq 15 ]
[ "$(grep -c '^IPv4,.*,正常,' "$TEST_TMP/no-ipv6/tcp-quality.csv")" -eq 15 ]

PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --province bj --quick --speed --no-color --output "$TEST_TMP/speed-failure" >/dev/null

[ "$(wc -l < "$TEST_TMP/speed-failure/single-thread-speed.csv")" -eq 4 ]
[ "$(grep -c ',部分失败,' "$TEST_TMP/speed-failure/single-thread-speed.csv")" -eq 3 ]

echo "TEST PASS: syntax, node matrix, dual-stack metrics, IPv6 auto-skip, speed failure handling."
