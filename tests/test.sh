#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MOCK_BIN="$ROOT/tests/mock-bin"
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/cn-tcp-quality-test.XXXXXX")
trap 'rm -rf -- "$TEST_TMP"' EXIT

chmod +x "$ROOT/cn-tcp-quality.sh" "$MOCK_BIN"/*
bash -n "$ROOT/cn-tcp-quality.sh"
"$ROOT/cn-tcp-quality.sh" --self-test --no-color

CN_TCP_PROGRESS=always PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --count 5 --parallel 4 --no-color --output "$TEST_TMP/dual" > "$TEST_TMP/dual-terminal.txt"

[ "$(wc -l < "$TEST_TMP/dual/tcp-quality.csv")" -eq 31 ]
[ "$(grep -c ',正常,' "$TEST_TMP/dual/tcp-quality.csv")" -eq 30 ]
grep -q 'TCP 探测.*100%  30/30.*全部完成' "$TEST_TMP/dual-terminal.txt"

MOCK_NO_IPV6=1 PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --count 5 --parallel 4 --no-color --output "$TEST_TMP/no-ipv6" >/dev/null

[ "$(grep -c '^IPv6,.*,跳过,' "$TEST_TMP/no-ipv6/tcp-quality.csv")" -eq 15 ]
[ "$(grep -c '^IPv4,.*,正常,' "$TEST_TMP/no-ipv6/tcp-quality.csv")" -eq 15 ]

MOCK_IPV6_NEEDS_L2=1 PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --province ah --count 3 --parallel 3 --no-color --output "$TEST_TMP/ipv6-l2" >/dev/null

[ "$(grep -c '^IPv6,.*,正常,' "$TEST_TMP/ipv6-l2/tcp-quality.csv")" -eq 3 ]
[ "$(awk -F, 'NR>1 && $12=="正常"{n++}END{print n+0}' "$TEST_TMP/ipv6-l2/tcp-quality.csv")" -eq 6 ]

CN_TCP_SPEEDTEST_BIN="$MOCK_BIN/speedtest-go" \
CN_TCP_SPEEDTEST_SOURCE4="192.0.2.10" \
CN_TCP_SPEEDTEST_SOURCE6="2001:db8::10" \
CN_TCP_PROGRESS=always \
PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --province bj --quick --speed --no-color --output "$TEST_TMP/speed-dual" > "$TEST_TMP/speed-terminal.txt"

[ "$(wc -l < "$TEST_TMP/speed-dual/single-thread-speed.csv")" -eq 7 ]
[ "$(grep -c ',OK,' "$TEST_TMP/speed-dual/single-thread-speed.csv")" -eq 6 ]
[ "$(grep -c '^IPv4,' "$TEST_TMP/speed-dual/single-thread-speed.csv")" -eq 3 ]
[ "$(grep -c '^IPv6,' "$TEST_TMP/speed-dual/single-thread-speed.csv")" -eq 3 ]
grep -q '单线程测速.*100%  6/6.*全部完成' "$TEST_TMP/speed-terminal.txt"

CN_TCP_SPEEDTEST_BIN="$MOCK_BIN/speedtest-go" \
CN_TCP_SPEEDTEST_SOURCE4="192.0.2.10" \
CN_TCP_SPEEDTEST_SOURCE6="2001:db8::10" \
PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --quick --speed --no-color --output "$TEST_TMP/speed-full" >/dev/null

[ "$(wc -l < "$TEST_TMP/speed-full/single-thread-speed.csv")" -eq 31 ]
[ "$(grep -c ',OK,' "$TEST_TMP/speed-full/single-thread-speed.csv")" -eq 30 ]

CN_TCP_SPEEDTEST_BIN="$MOCK_BIN/speedtest-cli.py" \
CN_TCP_SPEEDTEST_ENGINE=cli \
CN_TCP_SPEEDTEST_SOURCE4="192.0.2.10" \
PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --province ah -4 --quick --speed --no-color --output "$TEST_TMP/speed-cli" >/dev/null

[ "$(grep -c ',50.0,100.0,42,OK,' "$TEST_TMP/speed-cli/single-thread-speed.csv")" -eq 3 ]

echo "TEST PASS: syntax, node matrix, IPv6 L2 fallback, fixed output fields, dual speed engines, and 30-row speed matrix."
