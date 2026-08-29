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

[ "$(wc -l < "$TEST_TMP/dual/tcp-quality.csv")" -eq 61 ]
[ "$(wc -l < "$TEST_TMP/dual/probe-endpoints.csv")" -eq 61 ]
[ "$(grep -c ',正常,' "$TEST_TMP/dual/tcp-quality.csv")" -eq 60 ]
grep -q 'TCP 探测.*100%  60/60.*全部完成' "$TEST_TMP/dual-terminal.txt"

MOCK_NO_IPV6=1 PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --count 5 --parallel 4 --no-color --output "$TEST_TMP/no-ipv6" >/dev/null

[ "$(grep -c '^IPv6,.*,跳过,' "$TEST_TMP/no-ipv6/tcp-quality.csv")" -eq 30 ]
[ "$(grep -c '^IPv4,.*,正常,' "$TEST_TMP/no-ipv6/tcp-quality.csv")" -eq 30 ]

PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --province wh --count 3 --parallel 3 --no-color --output "$TEST_TMP/wuhan" >/dev/null

[ "$(wc -l < "$TEST_TMP/wuhan/tcp-quality.csv")" -eq 7 ]
[ "$(grep -c '^IPv[46],武汉,.*,正常,' "$TEST_TMP/wuhan/tcp-quality.csv")" -eq 6 ]
[ "$(grep -c '^IPv[46],武汉,' "$TEST_TMP/wuhan/probe-endpoints.csv")" -eq 6 ]

MOCK_IPV6_NEEDS_L2=1 PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --province ah --count 3 --parallel 3 --no-color --output "$TEST_TMP/ipv6-l2" >/dev/null

[ "$(grep -c '^IPv6,.*,正常,' "$TEST_TMP/ipv6-l2/tcp-quality.csv")" -eq 3 ]
[ "$(awk -F, 'NR>1 && $12=="正常"{n++}END{print n+0}' "$TEST_TMP/ipv6-l2/tcp-quality.csv")" -eq 6 ]

mkdir -p "$TEST_TMP/drop-once"
MOCK_DROP_ONCE_DIR="$TEST_TMP/drop-once" \
CN_TCP_BANNER=always CN_TCP_BANNER_PAUSE=0 \
PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --province ah -4 --no-color --output "$TEST_TMP/adaptive" > "$TEST_TMP/adaptive-terminal.txt"

[ "$(awk -F, 'NR>1 && $11==60{n++}END{print n+0}' "$TEST_TMP/adaptive/tcp-quality.csv")" -eq 3 ]
[ "$(grep -c ',1.67,' "$TEST_TMP/adaptive/tcp-quality.csv")" -eq 3 ]
grep -q 'CN TCP.*Network Quality Benchmark (V1.12.0)' "$TEST_TMP/adaptive-terminal.txt"
grep -q '██████╗.*███╗.*██╗' "$TEST_TMP/adaptive-terminal.txt"

CN_TCP_SPEEDTEST_BIN="$MOCK_BIN/speedtest-go" \
CN_TCP_SPEEDTEST_SOURCE4="192.0.2.10" \
CN_TCP_SPEEDTEST_SOURCE6="2001:db8::10" \
MOCK_SPEEDTEST_ARGS_FILE="$TEST_TMP/speedtest-args.txt" \
CN_TCP_PROGRESS=always \
PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --province bj --quick --speed --no-color --output "$TEST_TMP/speed-dual" > "$TEST_TMP/speed-terminal.txt"

[ "$(wc -l < "$TEST_TMP/speed-dual/single-thread-speed.csv")" -eq 5 ]
[ "$(grep -c ',OK,' "$TEST_TMP/speed-dual/single-thread-speed.csv")" -eq 4 ]
[ "$(grep -c '^IPv4,' "$TEST_TMP/speed-dual/single-thread-speed.csv")" -eq 3 ]
[ "$(grep -c '^IPv6,最近,端点,.*,OK,Cloudflare近端#' "$TEST_TMP/speed-dual/single-thread-speed.csv")" -eq 1 ]
grep -q '单线程测速.*100%  4/4.*全部完成' "$TEST_TMP/speed-terminal.txt"
grep -q -- '--location=39.9042,116.4074' "$TEST_TMP/speedtest-args.txt"
grep -q -- '--search=China Telecom' "$TEST_TMP/speedtest-args.txt"
grep -q -- '--filter-cc=CN' "$TEST_TMP/speedtest-args.txt"
! grep -q -- '--saving-mode' "$TEST_TMP/speedtest-args.txt"
! grep -q -- '--source=2001:db8::10' "$TEST_TMP/speedtest-args.txt"
grep -q 'speedtest.net#mock(dynamic/go)' "$TEST_TMP/speed-dual/single-thread-speed.csv"

CN_TCP_SPEEDTEST_BIN="$MOCK_BIN/speedtest-go" \
CN_TCP_SPEEDTEST_SOURCE4="192.0.2.10" \
CN_TCP_SPEEDTEST_SOURCE6="2001:db8::10" \
PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --quick --speed --no-color --output "$TEST_TMP/speed-full" >/dev/null

[ "$(wc -l < "$TEST_TMP/speed-full/single-thread-speed.csv")" -eq 32 ]
[ "$(grep -c ',OK,' "$TEST_TMP/speed-full/single-thread-speed.csv")" -eq 31 ]

CN_TCP_SPEEDTEST_BIN="$MOCK_BIN/speedtest-cli.py" \
CN_TCP_SPEEDTEST_ENGINE=cli \
CN_TCP_SPEEDTEST_SOURCE4="192.0.2.10" \
PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --province bj -4 --quick --speed --no-color --output "$TEST_TMP/speed-cli" >/dev/null

[ "$(grep -c ',50.0,100.0,42,OK,' "$TEST_TMP/speed-cli/single-thread-speed.csv")" -eq 3 ]

CN_TCP_SPEEDTEST_BIN="$MOCK_BIN/speedtest-go" \
CN_TCP_SPEEDTEST_SOURCE4="192.0.2.10" \
MOCK_SPEEDTEST_BORDERLINE=1 \
PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --province bj -4 --quick --speed --no-color --output "$TEST_TMP/speed-low" >/dev/null

[ "$(wc -l < "$TEST_TMP/speed-low/single-thread-speed.csv")" -eq 1 ]
[ "$(grep -c ',OK,' "$TEST_TMP/speed-low/single-thread-speed.csv" || true)" -eq 0 ]
grep -q '测速,失败(rc=3)' "$TEST_TMP/speed-low/endpoint-audit.csv"

CN_TCP_SPEEDTEST_BIN="$MOCK_BIN/speedtest-go" \
CN_TCP_SPEEDTEST_SOURCE4="192.0.2.10" \
MOCK_SPEEDTEST_DOWNLOAD_ONLY=1 \
PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --province sd -4 --quick --speed-only --no-color --output "$TEST_TMP/download-only" >/dev/null

[ "$(wc -l < "$TEST_TMP/download-only/single-thread-speed.csv")" -eq 4 ]
[ "$(grep -c '^IPv4,山东,.*,-,-,100.0,50,仅下载可用：上传低于0.2Mbps,' "$TEST_TMP/download-only/single-thread-speed.csv")" -eq 3 ]
[ "$(grep -c ',测速,成功(仅下载)$' "$TEST_TMP/download-only/endpoint-audit.csv")" -eq 3 ]

CN_TCP_SPEEDTEST_BIN="$MOCK_BIN/speedtest-go" \
CN_TCP_SPEEDTEST_SOURCE4="192.0.2.10" \
MOCK_DYNAMIC_FAIL=1 \
PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --province bj -4 --quick --speed --no-color --output "$TEST_TMP/speed-static-fallback" >/dev/null

[ "$(grep -c ',OK,.*(static/go)$' "$TEST_TMP/speed-static-fallback/single-thread-speed.csv")" -eq 3 ]

MOCK_DIRECT_HTTP=1 \
CN_TCP_SPEEDTEST_SOURCE4="192.0.2.10" \
CN_TCP_SPEEDTEST_SOURCE6="2001:db8::10" \
PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --province bj --quick --speed --no-color --output "$TEST_TMP/direct-http-dual" >/dev/null

[ "$(grep -c ',OK,OoklaHTTP#bj-' "$TEST_TMP/direct-http-dual/single-thread-speed.csv")" -eq 3 ]
[ "$(grep -c '^IPv6,最近,端点,.*,OK,Cloudflare近端#' "$TEST_TMP/direct-http-dual/single-thread-speed.csv")" -eq 1 ]

MOCK_SPEEDTEST_CN_ONLY=1 \
MOCK_SPEEDTEST_CN_STRICT=1 \
CN_TCP_SPEEDTEST_SOURCE4="192.0.2.10" \
CN_TCP_SPEEDTEST_SOURCE6="2001:db8::10" \
PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --province bj --quick --speed --no-color --output "$TEST_TMP/speedtest-cn-dual" >/dev/null

[ "$(grep -c ',OK,SpeedtestCN#cn-bj-' "$TEST_TMP/speedtest-cn-dual/single-thread-speed.csv")" -eq 3 ]
[ "$(grep -c '^IPv6,最近,端点,.*,OK,Cloudflare近端#' "$TEST_TMP/speedtest-cn-dual/single-thread-speed.csv")" -eq 1 ]
[ "$(grep -c ',双向,成功(raw)$' "$TEST_TMP/speedtest-cn-dual/endpoint-audit.csv")" -eq 4 ]

MOCK_SPEEDTEST_CN_ONLY=1 \
MOCK_UPLOAD_NO_RESPONSE=1 \
CN_TCP_SPEEDTEST_SOURCE4="192.0.2.10" \
PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --province bj -4 --quick --speed-only --no-color --output "$TEST_TMP/upload-no-response" >/dev/null

[ "$(grep -c '^IPv4,北京,.*,OK,SpeedtestCN#' "$TEST_TMP/upload-no-response/single-thread-speed.csv")" -eq 3 ]
[ "$(grep -c ',双向,成功(raw/no-response)$' "$TEST_TMP/upload-no-response/endpoint-audit.csv")" -eq 3 ]

MOCK_SPEEDTEST_CN_ONLY=1 \
MOCK_IPV4_MAPPED_ONLY=1 \
CN_TCP_SPEEDTEST_SOURCE4="192.0.2.10" \
CN_TCP_SPEEDTEST_SOURCE6="2001:db8::10" \
PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --province bj --quick --speed-only --no-color --output "$TEST_TMP/mapped-v6" > "$TEST_TMP/mapped-v6-terminal.txt"

[ ! -e "$TEST_TMP/mapped-v6/tcp-quality.csv" ]
[ "$(grep -c '^IPv4,.*,OK,SpeedtestCN#' "$TEST_TMP/mapped-v6/single-thread-speed.csv")" -eq 3 ]
[ "$(wc -l < "$TEST_TMP/mapped-v6/single-thread-speed.csv")" -eq 4 ]
grep -q '^IPv6,最近,端点,CloudflareEdge,nearest-v6,speed.cloudflare.com,-,解析,无原生AAAA地址$' "$TEST_TMP/mapped-v6/endpoint-audit.csv"
[ "$(grep -c '^IPv6,.*,::ffff:' "$TEST_TMP/mapped-v6/endpoint-audit.csv" || true)" -eq 0 ]
grep -q '运行模式：仅单线程测速' "$TEST_TMP/mapped-v6-terminal.txt"

CN_TCP_SPEEDTEST_BIN="$MOCK_BIN/speedtest-go" \
CN_TCP_SPEEDTEST_SOURCE4="192.0.2.10" \
MOCK_CATALOG_DISCOVERY=1 \
MOCK_CURL_URLS_FILE="$TEST_TMP/anhui-catalog-urls.txt" \
PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --province ah -4 --quick --speed-only --no-color --output "$TEST_TMP/anhui-speed-enabled" > "$TEST_TMP/anhui-speed-enabled.txt"

[ "$(wc -l < "$TEST_TMP/anhui-speed-enabled/single-thread-speed.csv")" -eq 4 ]
[ "$(grep -c '^IPv4,安徽,.*,OK,' "$TEST_TMP/anhui-speed-enabled/single-thread-speed.csv")" -eq 3 ]
[ "$(grep '/api/js/servers?' "$TEST_TMP/anhui-catalog-urls.txt" | sort -u | wc -l)" -eq 6 ]
[ "$(grep -c 'OoklaHTTP.*neighbor-js' "$TEST_TMP/anhui-speed-enabled/endpoint-audit.csv" || true)" -eq 0 ]

MOCK_SPEEDTEST_NET_ONLY=1 \
CN_TCP_SPEEDTEST_SOURCE4="192.0.2.10" \
PATH="$MOCK_BIN:$PATH" "$ROOT/cn-tcp-quality.sh" \
  --province js -4 --quick --speed-only --no-color --output "$TEST_TMP/speedtest-net-daily" >/dev/null

grep -q '^IPv4,江苏,移动,.*,OK,SpeedtestNetDaily#16204:' "$TEST_TMP/speedtest-net-daily/single-thread-speed.csv"
grep -q '^IPv4,江苏,移动,SpeedtestNetDaily,-,-,-,目录,匹配同省同运营商候选1个$' "$TEST_TMP/speedtest-net-daily/endpoint-audit.csv"
grep -q "江苏\\|移动) printf '16204 40131 32291 34559 17320" "$ROOT/cn-tcp-quality.sh"

echo "TEST PASS: syntax, banner, ten-region dual-stack TCP matrix, runtime Zstatic audit, three-catalog and multi-city discovery, successful-download-only speed output, nearest native IPv6, Cloudflare same-origin headers, download-only retention, upload no-response acceptance, IPv6 L2 fallback, redirected/raw SpeedtestCN, IPv4-mapped rejection, speed-only mode, IPv4 fallback, and 0.1Mbps guard."
