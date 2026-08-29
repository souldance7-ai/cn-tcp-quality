#!/usr/bin/env bash

# CN TCP Quality V1
# Five-province, three-carrier, dual-stack TCP quality probe.
# SPDX-License-Identifier: MIT

set -uo pipefail

VERSION="1.10.2"
NODE_API="${CN_TCP_NODE_API:-https://tcpquality.ibsgss.uk/getNodes?format=tsv}"
SPEEDTEST_CN_CATALOG_URL="${CN_TCP_SPEEDTEST_CN_CATALOG_URL:-https://raw.githubusercontent.com/spiritLHLS/speedtest.cn-CN-ID/main/CN.csv}"
COUNT=30
COUNT_EXPLICIT=0
AUTO_RECHECK_COUNT=60
PARALLEL=6
RUN_SPEED=0
SPEED_ONLY=0
SPEED_EXECUTED=0
SPEED_SECONDS=8
SPEED_BYTES=$((1024 * 1024 * 1024))
SPEEDTEST_GO_VERSION="${CN_TCP_SPEEDTEST_GO_VERSION:-1.8.2}"
SPEEDTEST_BIN="${CN_TCP_SPEEDTEST_BIN:-}"
SPEEDTEST_ENGINE="${CN_TCP_SPEEDTEST_ENGINE:-go}"
SPEEDTEST_INSTALL_TRIED=0
SPEEDTEST_INSTALL_ERROR=""
SOURCE_IPV4="${CN_TCP_SPEEDTEST_SOURCE4:-}"
SOURCE_IPV6="${CN_TCP_SPEEDTEST_SOURCE6:-}"
PROGRESS_MODE="${CN_TCP_PROGRESS:-auto}"
BANNER_MODE="${CN_TCP_BANNER:-auto}"
BANNER_PAUSE="${CN_TCP_BANNER_PAUSE:-0.8}"
ONLY_FAMILY=""
NO_COLOR=0
QUICK=0
SELF_TEST=0
OUTPUT_DIR=""
SELECTED_PROVINCES=""
SCRIPT_NAME="CN TCP Quality"
HTTP_USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 CN-TCP-Quality/${VERSION}"

if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  CYAN=$'\033[36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
  GOLD_WHITE=$'\033[38;5;231m'; GOLD_LIGHT=$'\033[38;5;228m'
  GOLD_BRIGHT=$'\033[38;5;220m'; GOLD_AMBER=$'\033[38;5;214m'
  GOLD_WARM=$'\033[38;5;178m'; GOLD_DARK=$'\033[38;5;136m'
  GOLD_SHADOW=$'\033[38;5;94m'; TEXT_GRAY=$'\033[38;5;248m'
else
  RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; DIM=""; NC=""
  GOLD_WHITE=""; GOLD_LIGHT=""; GOLD_BRIGHT=""; GOLD_AMBER=""
  GOLD_WARM=""; GOLD_DARK=""; GOLD_SHADOW=""; TEXT_GRAY=""
fi

usage() {
  cat <<'EOF'
CN TCP Quality V1

用法：
  bash cn-tcp-quality.sh [选项]

选项：
  --speed             追加北上广 IPv4 三网＋IPv6 最近端点单线程测速（流量较大）
  --speed-only        仅执行单线程测速，跳过 TCP 品质表
  --quick             快速模式：每节点 10 包，测速时间缩短（不限制 Mbps）
  -c, --count N       每个 TCP 节点发包数，默认 30，范围 3-100
  -p, --parallel N    并行节点数，默认 6，范围 1-15
  --province CODE     仅测指定省份，可重复：bj/sh/gd/ah/js
  -4, --ipv4          仅测 IPv4
  -6, --ipv6          仅测 IPv6
  --output DIR        指定结果目录
  --no-color          关闭终端颜色
  -h, --help          显示帮助

完整综合体验：
  bash cn-tcp-quality.sh --speed

说明：
  双栈 TCP 主表覆盖北京、上海、广东、安徽、江苏三网。
  单线程吞吐测试北上广 IPv4 三网 9 组，并另测 1 个 IPv6 最近端点。
  IPv6 强制原生 AAAA 与 curl -6，不套用省份或运营商标签。
  下载不设置速率上限；仅以测试时长和最大流量保护 VPS 配额。
  TCP 探测与单线程测速均显示动态进度、百分比及完成数量。
  不上传报告，不采集公网 IP，不参与排行榜。
EOF
}

province_name() {
  case "${1,,}" in
    bj|北京) printf '北京' ;;
    sh|上海) printf '上海' ;;
    gd|广东) printf '广东' ;;
    ah|安徽) printf '安徽' ;;
    js|江苏) printf '江苏' ;;
    *) return 1 ;;
  esac
}

add_province() {
  local name
  name=$(province_name "$1") || return 1
  case "|$SELECTED_PROVINCES|" in
    *"|$name|"*) ;;
    *) SELECTED_PROVINCES="${SELECTED_PROVINCES:+$SELECTED_PROVINCES|}$name" ;;
  esac
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --speed) RUN_SPEED=1; shift ;;
      --speed-only) RUN_SPEED=1; SPEED_ONLY=1; shift ;;
      --quick) QUICK=1; shift ;;
      -4|--ipv4) ONLY_FAMILY=4; shift ;;
      -6|--ipv6) ONLY_FAMILY=6; shift ;;
      --no-color) NO_COLOR=1; shift ;;
      --self-test) SELF_TEST=1; shift ;;
      -c|--count)
        [ "${2:-}" != "" ] && [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge 3 ] && [ "$2" -le 100 ] || {
          echo "发包数必须为 3-100。" >&2; exit 2;
        }
        COUNT="$2"; COUNT_EXPLICIT=1; shift 2 ;;
      -p|--parallel)
        [ "${2:-}" != "" ] && [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge 1 ] && [ "$2" -le 15 ] || {
          echo "并行数必须为 1-15。" >&2; exit 2;
        }
        PARALLEL="$2"; shift 2 ;;
      --province)
        [ "${2:-}" != "" ] && add_province "$2" || {
          echo "省份仅支持 bj/sh/gd/ah/js。" >&2; exit 2;
        }
        shift 2 ;;
      --output)
        [ "${2:-}" != "" ] || { echo "--output 缺少目录。" >&2; exit 2; }
        OUTPUT_DIR="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
    esac
  done

  [ "$QUICK" -eq 0 ] || {
    [ "$COUNT_EXPLICIT" -eq 1 ] || COUNT=10
    SPEED_SECONDS=3
    SPEED_BYTES=$((256 * 1024 * 1024))
  }
  [ "$NO_COLOR" -eq 0 ] || {
    RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; DIM=""; NC=""
    GOLD_WHITE=""; GOLD_LIGHT=""; GOLD_BRIGHT=""; GOLD_AMBER=""
    GOLD_WARM=""; GOLD_DARK=""; GOLD_SHADOW=""; TEXT_GRAY=""
  }
  [ -n "$SELECTED_PROVINCES" ] || SELECTED_PROVINCES="北京|上海|广东|安徽|江苏"
}

banner_enabled() {
  case "$BANNER_MODE" in
    always|1|true) return 0 ;;
    never|0|false) return 1 ;;
    *) [ -t 1 ] ;;
  esac
}

show_banner() {
  banner_enabled || return 0
  printf '\n'
  printf '%b♣  CN TCP  ▓▓  %bNetwork Quality Benchmark (V%s)%b  ▓▓%b\n' \
    "$GOLD_BRIGHT$BOLD" "$TEXT_GRAY" "$VERSION" "$GOLD_BRIGHT" "$NC"
  printf '%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n' \
    "$GOLD_BRIGHT" "$NC"
  printf '%b  ██████╗ ███╗   ██╗    ████████╗ ██████╗██████╗ %b\n' "$GOLD_WHITE" "$NC"
  printf '%b ██╔════╝ ████╗  ██║    ╚══██╔══╝██╔════╝██╔══██╗%b\n' "$GOLD_LIGHT" "$NC"
  printf '%b ██║      ██╔██╗ ██║       ██║   ██║     ██████╔╝%b\n' "$GOLD_BRIGHT" "$NC"
  printf '%b ██║      ██║╚██╗██║       ██║   ██║     ██╔═══╝ %b\n' "$GOLD_AMBER" "$NC"
  printf '%b ╚██████╗ ██║ ╚████║       ██║   ╚██████╗██║     %b\n' "$GOLD_WARM" "$NC"
  printf '%b  ╚═════╝ ╚═╝  ╚═══╝       ╚═╝    ╚═════╝╚═╝     %b\n' "$GOLD_DARK" "$NC"
  printf '%b     ░▒▓██████████████████████████████████████▓▒░%b\n' "$GOLD_SHADOW" "$NC"
  printf '%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n' \
    "$GOLD_BRIGHT" "$NC"
  printf '%b♣  [ 五省三网双栈 TCP 品质 · 北上广 IPv4／IPv6 近端测速 ]%b\n' \
    "$GOLD_BRIGHT$BOLD" "$NC"
  printf '%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n' \
    "$GOLD_BRIGHT" "$NC"
  printf '%b• 隐私承诺：%b本地独立测速分析 · 绝不上报结果 · 绝不采集公网 IP%b\n' \
    "$GOLD_LIGHT$BOLD" "$TEXT_GRAY" "$NC"
  printf '%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n\n' \
    "$GOLD_BRIGHT" "$NC"
  case "$BANNER_PAUSE" in
    0|0.0|'') ;;
    *) sleep "$BANNER_PAUSE" 2>/dev/null || true ;;
  esac
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "需要 root 权限发送原始 TCP SYN 包。请切换 root 后运行。" >&2
    exit 1
  fi
}

install_dependencies() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v nping >/dev/null 2>&1 || missing+=(nping)
  command -v ip >/dev/null 2>&1 || missing+=(ip)
  command -v ss >/dev/null 2>&1 || missing+=(ss)
  command -v timeout >/dev/null 2>&1 || missing+=(timeout)
  if [ "$RUN_SPEED" -eq 1 ]; then
    command -v python3 >/dev/null 2>&1 || missing+=(python3)
    command -v getent >/dev/null 2>&1 || missing+=(getent)
  fi
  [ "${#missing[@]}" -eq 0 ] && return 0

  echo -e "${YELLOW}[!] 缺少依赖：${missing[*]}，正在安装……${NC}"
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl nmap iproute2 coreutils python3 libc-bin >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q curl nmap iproute coreutils python3 glibc-common >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q curl nmap iproute coreutils python3 glibc-common >/dev/null 2>&1
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl nmap-nping iproute2 coreutils python3 musl-utils >/dev/null 2>&1
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm curl nmap iproute2 coreutils python glibc >/dev/null 2>&1
  else
    echo "无法识别包管理器，请手动安装 curl、nmap/nping、iproute2、coreutils。" >&2
    exit 1
  fi

  for cmd in curl nping ip ss timeout; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "依赖安装失败：$cmd" >&2; exit 1; }
  done
  if [ "$RUN_SPEED" -eq 1 ]; then
    for cmd in python3 getent; do
      command -v "$cmd" >/dev/null 2>&1 || { echo "测速依赖安装失败：$cmd" >&2; exit 1; }
    done
  fi
}

write_builtin_nodes() {
  cat > "$1" <<'EOF'
type	family	prov	isp	host	ip	port	target
cdn	4	北京	电信	bj-ct-v4.ibsgss.uk	106.37.68.13	80	bj-ct-v4.ip.zstaticcdn.com
cdn	4	北京	联通	bj-cu-v4.ibsgss.uk	221.222.185.232	80	bj-cu-v4.ip.zstaticcdn.com
cdn	4	北京	移动	bj-cm-v4.ibsgss.uk	211.136.25.153	80	bj-cm-v4.ip.zstaticcdn.com
cdn	6	北京	电信	bj-ct-v6.ibsgss.uk	240e:910:e000:201:8000:0:b00:99	80	bj-ct-v6.ip.zstaticcdn.com
cdn	6	北京	联通	bj-cu-v6.ibsgss.uk	2408:8706:0:dd80::b00:95	80	bj-cu-v6.ip.zstaticcdn.com
cdn	6	北京	移动	bj-cm-v6.ibsgss.uk	2409:8c10:c00:1b:8000:0:b00:181	80	bj-cm-v6.ip.zstaticcdn.com
cdn	4	上海	电信	sh-ct-v4.ibsgss.uk	101.226.101.195	80	sh-ct-v4.ip.zstaticcdn.com
cdn	4	上海	联通	sh-cu-v4.ibsgss.uk	58.246.163.108	80	sh-cu-v4.ip.zstaticcdn.com
cdn	4	上海	移动	sh-cm-v4.ibsgss.uk	117.185.117.117	80	sh-cm-v4.ip.zstaticcdn.com
cdn	6	上海	电信	sh-ct-v6.ibsgss.uk	240e:96c:6000:d80::b00:40	80	sh-ct-v6.ip.zstaticcdn.com
cdn	6	上海	联通	sh-cu-v6.ibsgss.uk	2408:873c:6810:5:8000:0:b00:221	80	sh-cu-v6.ip.zstaticcdn.com
cdn	6	上海	移动	sh-cm-v6.ibsgss.uk	2409:8c1e:75b0:2003:8000:0:b00:62	80	sh-cm-v6.ip.zstaticcdn.com
cdn	4	广东	电信	gd-ct-v4.ibsgss.uk	14.22.119.35	80	gd-ct-v4.ip.zstaticcdn.com
cdn	4	广东	联通	gd-cu-v4.ibsgss.uk	122.13.24.8	80	gd-cu-v4.ip.zstaticcdn.com
cdn	4	广东	移动	gd-cm-v4.ibsgss.uk	211.139.145.129	80	gd-cm-v4.ip.zstaticcdn.com
cdn	6	广东	电信	gd-ct-v6.ibsgss.uk	240e:97c:39:f80::b00:228	80	gd-ct-v6.ip.zstaticcdn.com
cdn	6	广东	联通	gd-cu-v6.ibsgss.uk	2408:8756:dcff:e001:8000:0:b00:98	80	gd-cu-v6.ip.zstaticcdn.com
cdn	6	广东	移动	gd-cm-v6.ibsgss.uk	2409:8c54:2010:700:8000:0:b00:52	80	gd-cm-v6.ip.zstaticcdn.com
cdn	4	安徽	电信	ah-ct-v4.ibsgss.uk	117.68.20.181	80	ah-ct-v4.ip.zstaticcdn.com
cdn	4	安徽	联通	ah-cu-v4.ibsgss.uk	112.132.39.247	80	ah-cu-v4.ip.zstaticcdn.com
cdn	4	安徽	移动	ah-cm-v4.ibsgss.uk	39.145.24.48	80	ah-cm-v4.ip.zstaticcdn.com
cdn	6	安徽	电信	ah-ct-v6.ibsgss.uk	240e:958:2300:212:8000:0:b00:94	80	ah-ct-v6.ip.zstaticcdn.com
cdn	6	安徽	联通	ah-cu-v6.ibsgss.uk	2406:8880:0:4:8000:0:b00:90	80	ah-cu-v6.ip.zstaticcdn.com
cdn	6	安徽	移动	ah-cm-v6.ibsgss.uk	2409:8c30:1000:1a01:8000:0:b00:224	80	ah-cm-v6.ip.zstaticcdn.com
cdn	4	江苏	电信	js-ct-v4.ibsgss.uk	180.102.49.150	80	js-ct-v4.ip.zstaticcdn.com
cdn	4	江苏	联通	js-cu-v4.ibsgss.uk	112.86.231.205	80	js-cu-v4.ip.zstaticcdn.com
cdn	4	江苏	移动	js-cm-v4.ibsgss.uk	36.155.201.50	80	js-cm-v4.ip.zstaticcdn.com
cdn	6	江苏	电信	js-ct-v6.ibsgss.uk	240e:979:9509:180::b00:84	80	js-ct-v6.ip.zstaticcdn.com
cdn	6	江苏	联通	js-cu-v6.ibsgss.uk	2408:8719:3100:7:8000:0:b00:7	80	js-cu-v6.ip.zstaticcdn.com
cdn	6	江苏	移动	js-cm-v6.ibsgss.uk	2409:8c20:6ed1:10c:8000:0:b00:138	80	js-cm-v6.ip.zstaticcdn.com
tos	4	北京	电信	tos-bj-ct-v4.ibsgss.uk	42.81.80.87	443	tos-cn-beijing.volces.com
tos	4	北京	联通	tos-bj-cu-v4.ibsgss.uk	119.250.10.102	443	tos-cn-beijing.volces.com
tos	4	北京	移动	tos-bj-cm-v4.ibsgss.uk	120.255.0.180	443	tos-cn-beijing.volces.com
tos	4	上海	电信	tos-sh-ct-v4.ibsgss.uk	180.97.50.130	443	tos-cn-shanghai.volces.com
tos	4	上海	联通	tos-sh-cu-v4.ibsgss.uk	116.147.21.130	443	tos-cn-shanghai.volces.com
tos	4	上海	移动	tos-sh-cm-v4.ibsgss.uk	36.151.164.132	443	tos-cn-shanghai.volces.com
tos	4	广东	电信	tos-gd-ct-v4.ibsgss.uk	14.119.66.1	443	tos-cn-guangzhou.volces.com
tos	4	广东	联通	tos-gd-cu-v4.ibsgss.uk	157.255.228.134	443	tos-cn-guangzhou.volces.com
tos	4	广东	移动	tos-gd-cm-v4.ibsgss.uk	183.232.151.141	443	tos-cn-guangzhou.volces.com
EOF
}

normalize_remote_nodes() {
  local src="$1" dst="$2"
  awk -F '\t' 'BEGIN{OFS="\t"}
    NR==1 { next }
    {
      gsub(/\r/, "")
      if (($1=="cdn" || $1=="tos") && ($2=="4" || $2=="6") && $3!="" && $4!="" && $6!="")
        print $1,$2,$3,$4,$5,$6,($7==""?80:$7),$8
    }' "$src" > "$dst"
}

load_nodes() {
  local remote="$WORK_DIR/nodes.remote.tsv" normalized="$WORK_DIR/nodes.normalized.tsv"
  local tos_remote="$WORK_DIR/nodes.tos.remote.tsv" tos_normalized="$WORK_DIR/nodes.tos.normalized.tsv"
  local builtin="$WORK_DIR/nodes.builtin.tsv" builtin_normalized="$WORK_DIR/nodes.builtin.normalized.tsv"
  NODE_SOURCE="builtin-fallback"
  if [ "$SELF_TEST" -eq 0 ] && curl -fsSL --retry 2 --connect-timeout 6 --max-time 25 "$NODE_API" -o "$remote" 2>/dev/null; then
    normalize_remote_nodes "$remote" "$normalized"
    if [ "$(awk -F '\t' '$1=="cdn"{n++} END{print n+0}' "$normalized")" -ge 30 ]; then
      cp "$normalized" "$NODE_FILE"
      if curl -fsSL --retry 2 --connect-timeout 6 --max-time 25 \
          "${NODE_API%%\?*}?format=tsv&scope=tos" -o "$tos_remote" 2>/dev/null; then
        normalize_remote_nodes "$tos_remote" "$tos_normalized"
        awk -F '\t' '$1=="tos"' "$tos_normalized" >> "$NODE_FILE"
      fi
      if [ "$(awk -F '\t' '$1=="tos"&&$2=="4"{n++}END{print n+0}' "$NODE_FILE")" -lt 9 ]; then
        write_builtin_nodes "$builtin"
        normalize_remote_nodes "$builtin" "$builtin_normalized"
        awk -F '\t' '$1=="tos"' "$builtin_normalized" >> "$NODE_FILE"
      fi
      NODE_SOURCE="dynamic-api"
      return 0
    fi
  fi
  write_builtin_nodes "$remote"
  normalize_remote_nodes "$remote" "$NODE_FILE"
}

selected_province() {
  [[ "|$SELECTED_PROVINCES|" == *"|$1|"* ]]
}

prepare_probe_plan() {
  local family prov isp line idx=0
  : > "$PLAN_FILE"
  for family in 4 6; do
    [ -z "$ONLY_FAMILY" ] || [ "$ONLY_FAMILY" = "$family" ] || continue
    for prov in 北京 上海 广东 安徽 江苏; do
      selected_province "$prov" || continue
      for isp in 电信 联通 移动; do
        line=$(awk -F '\t' -v f="$family" -v p="$prov" -v i="$isp" '$1=="cdn" && $2==f && $3==p && $4==i {print; exit}' "$NODE_FILE")
        idx=$((idx + 1))
        if [ -n "$line" ]; then
          printf '%02d\t%s\n' "$idx" "$line" >> "$PLAN_FILE"
        else
          printf '%02d\tcdn\t%s\t%s\t%s\t-\t-\t80\t-\n' "$idx" "$family" "$prov" "$isp" >> "$PLAN_FILE"
        fi
      done
    done
  done
}

ipv6_route_available() {
  local ip6
  ip6=$(awk -F '\t' '$3=="6" && $7!="-" {print $7; exit}' "$PLAN_FILE")
  [ -n "$ip6" ] && ip -6 route get "$ip6" >/dev/null 2>&1
}

calc_metrics() {
  local values="$1" count="$2" received="${3:-}" samples avg jitter min max p95 loss sorted idx
  [ -n "$received" ] || received=$(wc -l < "$values" | tr -d ' ')
  samples=$(wc -l < "$values" | tr -d ' ')
  loss=$(awk -v sent="$count" -v recv="$received" 'BEGIN{printf "%.2f", (sent-recv)*100/sent}')
  if [ "$samples" -eq 0 ]; then
    printf '%s\t-\t-\t-\t-\t-\t0' "$loss"
    return
  fi
  avg=$(awk '{s+=$1} END{printf "%.2f", s/NR}' "$values")
  jitter=$(awk 'NR==1{p=$1;next}{d=$1-p;if(d<0)d=-d;s+=d;p=$1} END{if(NR<2)printf "0.00";else printf "%.2f",s/(NR-1)}' "$values")
  min=$(awk 'NR==1{m=$1}$1<m{m=$1}END{printf "%.2f",m}' "$values")
  max=$(awk 'NR==1{m=$1}$1>m{m=$1}END{printf "%.2f",m}' "$values")
  sorted="${values}.sorted"; sort -n "$values" > "$sorted"
  idx=$(( (samples * 95 + 99) / 100 ))
  p95=$(awk -v n="$idx" 'NR==n{printf "%.2f",$1;exit}' "$sorted")
  [ -n "$p95" ] || p95='-'
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$loss" "$avg" "$jitter" "$p95" "$min" "$max" "$samples"
}

write_skip_result() {
  local idx="$1" family="$2" prov="$3" isp="$4" host="$5" ipaddr="$6" reason="$7"
  printf '%s\t%s\t%s\t-\t-\t-\t-\t-\t-\t0\t%s\t%s\t%s\t%s\n' \
    "$family" "$prov" "$isp" "$reason" "$host" "$ipaddr" "$COUNT" > "$RESULT_DIR/$idx.tsv"
}

nping_random_source_port() {
  printf '%s' $((20000 + RANDOM % 40000))
}

nping_random_sequence() {
  printf '%s' $((((RANDOM << 16) ^ RANDOM) & 0x7ffffffe))
}

nping_rtt_from_file() {
  local file="$1" rtt sent_time received_time
  rtt=$(grep -oE 'rtt[=:][[:space:]]*[0-9]+([.][0-9]+)?ms' "$file" 2>/dev/null |
    sed -nE 's/.*[=:][[:space:]]*([0-9.]+)ms/\1/p' | head -1)
  if [[ "$rtt" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s' "$rtt"
    return 0
  fi
  sent_time=$(sed -nE 's/^SENT \(([0-9.]+)s\).*/\1/p' "$file" | head -1)
  received_time=$(sed -nE 's/^RCVD \(([0-9.]+)s\).*/\1/p' "$file" | head -1)
  if [[ "$sent_time" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
     [[ "$received_time" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    awk -v s="$sent_time" -v r="$received_time" 'BEGIN{
      value=(r-s)*1000; if(value>=0){printf "%.3f",value; exit 0} exit 1
    }'
    return
  fi
  return 1
}

get_ipv6_l2_route() {
  local target="$1" route_info iface source_ip next_hop source_mac dest_mac
  route_info=$(ip -6 route get "$target" 2>/dev/null | head -1)
  iface=$(printf '%s\n' "$route_info" | awk '{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
  source_ip=$(printf '%s\n' "$route_info" | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')
  next_hop=$(printf '%s\n' "$route_info" | awk '{for(i=1;i<=NF;i++)if($i=="via"){print $(i+1);exit}}')
  [ -n "$iface" ] || return 1
  if [ -z "$source_ip" ]; then
    source_ip=$(ip -6 addr show dev "$iface" scope global 2>/dev/null |
      awk '/inet6 /{sub(/\/.*/,"",$2);print $2;exit}')
  fi
  next_hop=${next_hop:-$target}
  source_mac=$(ip link show dev "$iface" 2>/dev/null | awk '/link\/ether/{print $2;exit}')
  dest_mac=$(ip -6 neigh show "$next_hop" dev "$iface" 2>/dev/null |
    awk '/lladdr/{for(i=1;i<=NF;i++)if($i=="lladdr"){print $(i+1);exit}}')
  if [ -z "$dest_mac" ] && command -v ping >/dev/null 2>&1; then
    ping -6 -c 1 -W 1 -I "$iface" "$next_hop" >/dev/null 2>&1 || true
    dest_mac=$(ip -6 neigh show "$next_hop" dev "$iface" 2>/dev/null |
      awk '/lladdr/{for(i=1;i<=NF;i++)if($i=="lladdr"){print $(i+1);exit}}')
  fi
  source_ip=${source_ip%%\%*}
  [[ "$source_ip" == *:* ]] || return 1
  [[ "$source_mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || return 1
  [[ "$dest_mac" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || return 1
  printf '%s|%s|%s|%s' "$iface" "$source_ip" "$source_mac" "$dest_mac"
}

probe_node() {
  local idx="$1" family="$2" prov="$3" isp="$4" host="$5" ipaddr="$6" port="$7"
  local raw="$WORK_DIR/nping.$idx.log" values="$WORK_DIR/rtt.$idx" metrics status sent received loss
  local i attempt max_attempts packet_log one_received one_rtt source_port sequence rc timeouts=0
  local target_count initial_count
  local l2_route iface source_ip source_mac dest_mac l2_ready=0 l2_preferred=0 use_l2
  local -a args
  : > "$values"; : > "$raw"
  if [ "$ipaddr" = "-" ]; then
    write_skip_result "$idx" "$family" "$prov" "$isp" "$host" "$ipaddr" "无节点"
    return
  fi
  if [ "$family" = "6" ] && [ "$IPV6_OK" -ne 1 ]; then
    write_skip_result "$idx" "$family" "$prov" "$isp" "$host" "$ipaddr" "跳过"
    return
  fi
  sent=0; received=0; initial_count="$COUNT"; target_count="$COUNT"; i=1
  while [ "$i" -le "$target_count" ]; do
    max_attempts=1
    [ "$family" = "6" ] && [ "$l2_preferred" -eq 0 ] && max_attempts=2
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
      use_l2=0
      if [ "$family" = "6" ] && { [ "$l2_preferred" -eq 1 ] || [ "$attempt" -eq 2 ]; }; then
        if [ "$l2_ready" -eq 0 ]; then
          l2_route=$(get_ipv6_l2_route "$ipaddr" 2>/dev/null || true)
          if [ -n "$l2_route" ]; then
            IFS='|' read -r iface source_ip source_mac dest_mac <<< "$l2_route"
            l2_ready=1
          fi
        fi
        [ "$l2_ready" -eq 1 ] || break
        use_l2=1
      fi
      source_port=$(nping_random_source_port)
      sequence=$(nping_random_sequence)
      args=(--tcp --flags syn -p "$port" -g "$source_port" --seq "$sequence" -c 1)
      [ "$family" = "6" ] && args=(-6 "${args[@]}")
      if [ "$use_l2" -eq 1 ]; then
        args=(-6 -e "$iface" -S "$source_ip" --source-mac "$source_mac" --dest-mac "$dest_mac" --tcp --flags syn -p "$port" -g "$source_port" --seq "$sequence" -c 1)
      fi
      packet_log="$WORK_DIR/nping.${idx}.${i}.${attempt}.log"
      rc=0
      timeout 6 nping "${args[@]}" "$ipaddr" > "$packet_log" 2>&1 || rc=$?
      printf '\n===== packet %s attempt %s l2=%s rc=%s =====\n' "$i" "$attempt" "$use_l2" "$rc" >> "$raw"
      cat "$packet_log" >> "$raw"
      [ "$rc" -eq 124 ] && timeouts=$((timeouts + 1))
      one_received=$(sed -nE 's/.*Rcvd:[[:space:]]*([0-9]+).*/\1/p' "$packet_log" | tail -1)
      one_rtt=$(nping_rtt_from_file "$packet_log" 2>/dev/null || true)
      if [[ "$one_received" =~ ^[0-9]+$ ]] && [ "$one_received" -gt 0 ] &&
         [[ "$one_rtt" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        printf '%s\n' "$one_rtt" >> "$values"
        received=$((received + 1))
        [ "$use_l2" -eq 0 ] || l2_preferred=1
        break
      fi
    done
    sent=$((sent + 1))
    if [ "$i" -eq "$initial_count" ] && [ "$QUICK" -eq 0 ] &&
       [ "$COUNT_EXPLICIT" -eq 0 ] && [ "$received" -gt 0 ] &&
       [ "$received" -lt "$sent" ] && [ "$AUTO_RECHECK_COUNT" -gt "$initial_count" ]; then
      target_count="$AUTO_RECHECK_COUNT"
    fi
    i=$((i + 1))
  done
  metrics=$(calc_metrics "$values" "$sent" "$received")
  loss=${metrics%%$'\t'*}
  status="正常"
  [ "$received" -gt 0 ] || status="不可达"
  if [ "$received" -gt 0 ]; then
    awk -v v="$loss" 'BEGIN{exit !(v>20)}' && status="严重丢包"
    if [ "$status" = "正常" ]; then
      awk -v v="$loss" 'BEGIN{exit !(v>3)}' && status="丢包"
    fi
  fi
  [ "$received" -eq 0 ] && [ "$timeouts" -gt 0 ] && status="超时"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$family" "$prov" "$isp" "$metrics" "$status" "$host" "$ipaddr" "$sent" > "$RESULT_DIR/$idx.tsv"
}

run_tcp_probes() {
  local idx type family prov isp host ipaddr port target active=0 completed=0 total current
  total=$(wc -l < "$PLAN_FILE" | tr -d ' ')
  render_progress "TCP 探测" 0 "$total" "准备节点"
  while IFS=$'\t' read -r idx type family prov isp host ipaddr port target; do
    current="IPv${family} ${prov}${isp}"
    probe_node "$idx" "$family" "$prov" "$isp" "$host" "$ipaddr" "$port" &
    active=$((active + 1))
    if [ "$active" -ge "$PARALLEL" ]; then
      wait -n 2>/dev/null || true
      active=$((active - 1))
      completed=$((completed + 1))
      render_progress "TCP 探测" "$completed" "$total" "$current"
    fi
  done < "$PLAN_FILE"
  while [ "$active" -gt 0 ]; do
    wait -n 2>/dev/null || true
    active=$((active - 1))
    completed=$((completed + 1))
    render_progress "TCP 探测" "$completed" "$total" "收尾节点"
  done
  finish_progress "TCP 探测" "$total" "全部完成"
}

display_width() {
  local text="$1" bytes chars
  bytes=$(printf '%s' "$text" | wc -c | tr -d ' ')
  chars=$(printf '%s' "$text" | wc -m | tr -d ' ')
  printf '%s' $((chars + (bytes - chars) / 2))
}

pad_left() {
  local width="$1" text="$2" used spaces
  used=$(display_width "$text"); spaces=$((width-used)); [ "$spaces" -lt 0 ] && spaces=0
  printf '%*s%s' "$spaces" '' "$text"
}

progress_enabled() {
  case "$PROGRESS_MODE" in
    always|1|true) return 0 ;;
    never|0|false) return 1 ;;
    *) [ -t 1 ] ;;
  esac
}

clear_progress() {
  progress_enabled || return 0
  printf '\r\033[K'
}

render_progress() {
  local stage="$1" done="$2" total="$3" detail="$4"
  local width=30 percent filled i position red green blue
  progress_enabled || return 0
  [ "$total" -gt 0 ] || total=1
  percent=$((done * 100 / total))
  [ "$percent" -le 100 ] || percent=100
  filled=$((done * width / total))
  [ "$filled" -le "$width" ] || filled="$width"
  printf '\r\033[K  %-12s [' "$stage"
  for ((i=0; i<width; i++)); do
    if [ "$i" -lt "$filled" ]; then
      if [ -n "$CYAN" ]; then
        position=$((i * 100 / (width - 1)))
        if [ "$position" -lt 50 ]; then
          red=255; green=$((position * 510 / 100)); blue=0
        else
          red=$((255 - (position - 50) * 510 / 100)); green=255; blue=0
        fi
        printf '\033[38;2;%d;%d;%dm█' "$red" "$green" "$blue"
      else
        printf '#'
      fi
    else
      if [ -n "$DIM" ]; then printf '%b░%b' "$DIM" "$NC"; else printf '-'; fi
    fi
  done
  printf '%b] %3d%%  %d/%d  当前：%s' "$NC" "$percent" "$done" "$total" "$detail"
}

finish_progress() {
  local stage="$1" total="$2" detail="$3"
  progress_enabled || return 0
  render_progress "$stage" "$total" "$total" "$detail"
  printf '\n'
}

metric_text() {
  local value="$1" suffix="$2"
  case "$value" in
    ""|-|failed) printf '%s' "${value:--}" ;;
    *) printf '%s%s' "$value" "$suffix" ;;
  esac
}

loss_color() {
  local value="$1"
  [ "$value" = "-" ] && { printf '%s' "$DIM"; return; }
  awk -v v="$value" 'BEGIN{exit !(v==0)}' && { printf '%s' "$GREEN"; return; }
  awk -v v="$value" 'BEGIN{exit !(v<=3)}' && { printf '%s' "$YELLOW"; return; }
  printf '%s' "$RED"
}

latency_color() {
  local value="$1"
  [ "$value" = "-" ] && { printf '%s' "$DIM"; return; }
  awk -v v="$value" 'BEGIN{exit !(v<=120)}' && { printf '%s' "$GREEN"; return; }
  awk -v v="$value" 'BEGIN{exit !(v<=220)}' && { printf '%s' "$YELLOW"; return; }
  printf '%s' "$RED"
}

show_tcp_results() {
  local file family prov isp loss avg jitter p95 min max received status host ipaddr sent lc ac line
  TCP_CSV="$OUTPUT_DIR/tcp-quality.csv"
  printf '\xEF\xBB\xBF协议,省份,运营商,丢包率(%%),平均延迟(ms),抖动(ms),P95(ms),最低延迟(ms),最高延迟(ms),接收,发送,状态,域名,IP\n' > "$TCP_CSV"
  echo -e "${BOLD}${CYAN}五省三网 TCP 品质（双栈）${NC}"
  echo
  printf '  '; pad_left 6 '协议'; printf '  '; pad_left 12 '地区线路'; printf '  '; pad_left 10 '丢包率'; printf '  '; pad_left 11 '平均延迟'; printf '  '; pad_left 9 '抖动'; printf '  '; pad_left 9 'P95'; printf '  '; pad_left 17 '最低／最高'; printf '  '; pad_left 8 '状态'; printf '\n'
  for file in "$RESULT_DIR"/*.tsv; do
    IFS=$'\t' read -r family prov isp loss avg jitter p95 min max received status host ipaddr sent < "$file"
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "IPv$family" "$prov" "$isp" "$loss" "$avg" "$jitter" "$p95" "$min" "$max" "$received" "$sent" "$status" "$host" "$ipaddr" >> "$TCP_CSV"
    lc=$(loss_color "$loss"); ac=$(latency_color "$avg")
    printf '  '; printf '%b' "$CYAN"; pad_left 6 "IPv$family"; printf '%b' "$NC"
    printf '  '; printf '%b' "$CYAN"; pad_left 12 "$prov$isp"; printf '%b' "$NC"
    printf '  '; printf '%b' "$lc"; pad_left 10 "$(metric_text "$loss" '%')"; printf '%b' "$NC"
    printf '  '; printf '%b' "$ac"; pad_left 11 "$(metric_text "$avg" 'ms')"; printf '%b' "$NC"
    printf '  '; printf '%b' "$ac"; pad_left 9 "$(metric_text "$jitter" 'ms')"; printf '%b' "$NC"
    printf '  '; printf '%b' "$ac"; pad_left 9 "$(metric_text "$p95" 'ms')"; printf '%b' "$NC"
    if [ "$min" = "-" ]; then line="-"; else line="${min}/${max}ms"; fi
    printf '  '; printf '%b' "$ac"; pad_left 17 "$line"; printf '%b' "$NC"
    printf '  '; [ "$status" = "正常" ] && printf '%b' "$GREEN" || printf '%b' "$YELLOW"; pad_left 8 "$status"; printf '%b\n' "$NC"
  done
  echo
}

tos_region() {
  case "$1" in
    北京) printf 'cn-beijing' ;;
    上海) printf 'cn-shanghai' ;;
    广东) printf 'cn-guangzhou' ;;
    *) return 1 ;;
  esac
}

tos_bucket_host() {
  case "$1" in
    cn-beijing) printf 'probe-bucket-beijing.tos-cn-beijing.volces.com' ;;
    cn-shanghai) printf 'probe-bucket-shanghai.tos-cn-shanghai.volces.com' ;;
    cn-guangzhou) printf 'probe-bucket-guangzhou.tos-cn-guangzhou.volces.com' ;;
    *) return 1 ;;
  esac
}

monitor_ss() {
  local pid="$1" ipaddr="$2" out="$3"
  : > "$out"
  while kill -0 "$pid" 2>/dev/null; do
    ss -tin dst "$ipaddr" 2>/dev/null >> "$out" || true
    sleep 0.05
  done
}

retrans_percent_from_ss() {
  local file="$1" retrans segs
  retrans=$(grep -oE 'retrans:[0-9]+/[0-9]+' "$file" 2>/dev/null | awk -F/ '$2>m{m=$2}END{print m+0}')
  segs=$(grep -oE 'data_segs_out:[0-9]+' "$file" 2>/dev/null | awk -F: '$2>m{m=$2}END{print m+0}')
  if [ "$segs" -gt 0 ]; then
    awk -v r="$retrans" -v s="$segs" 'BEGIN{printf "%.2f",r*100/s}'
  else
    printf '-'
  fi
}

curl_probe() {
  local direction="$1" host="$2" ipaddr="$3" work="$4"
  local meta="$work.$direction.meta" err="$work.$direction.err" sslog="$work.$direction.ss"
  local pid monitor_pid rc=0 key
  if [ "$direction" = "upload" ]; then
    key="upload/cn-tcp-quality-$(date +%s)-$RANDOM"
    (
      head -c "$SPEED_BYTES" /dev/zero 2>/dev/null | curl -4 --noproxy '*' --http1.1 -sS \
        --connect-timeout 5 --max-time "$SPEED_SECONDS" --resolve "$host:443:$ipaddr" \
        -X PUT -H "Content-Length: $SPEED_BYTES" --upload-file - -o /dev/null \
        -w '%{http_code}|%{size_download}|%{speed_download}|%{size_upload}|%{speed_upload}|%{time_connect}|%{time_appconnect}|%{time_total}' \
        "https://$host/$key" > "$meta" 2> "$err"
    ) & pid=$!
  else
    curl -4 --noproxy '*' --http1.1 -sS \
      --connect-timeout 5 --max-time "$SPEED_SECONDS" --resolve "$host:443:$ipaddr" \
      --range "0-$((SPEED_BYTES-1))" -o /dev/null \
      -w '%{http_code}|%{size_download}|%{speed_download}|%{size_upload}|%{speed_upload}|%{time_connect}|%{time_appconnect}|%{time_total}' \
      "https://$host/download/test" > "$meta" 2> "$err" & pid=$!
  fi
  monitor_ss "$pid" "$ipaddr" "$sslog" & monitor_pid=$!
  wait "$pid" || rc=$?
  wait "$monitor_pid" 2>/dev/null || true
  printf '%s|%s|%s' "$rc" "$meta" "$sslog"
}

parse_curl_metric() {
  local direction="$1" rc="$2" meta_file="$3" ss_file="$4"
  local http bytes_down speed_down bytes_up speed_up connect tls total bytes bps mbps latency retrans status
  IFS='|' read -r http bytes_down speed_down bytes_up speed_up connect tls total < "$meta_file" 2>/dev/null || true
  if [ "$direction" = "upload" ]; then bytes="${bytes_up:-0}"; bps="${speed_up:-0}"; else bytes="${bytes_down:-0}"; bps="${speed_down:-0}"; fi
  status="OK"
  if ! [[ "${http:-}" =~ ^(200|201|204|206)$ ]] && [ "$rc" -ne 28 ]; then status="FAIL"; fi
  [ "${bytes:-0}" -ge 1048576 ] 2>/dev/null || status="FAIL"
  if [ "$status" = "OK" ]; then
    mbps=$(awk -v b="${bps:-0}" 'BEGIN{printf "%.1f",b*8/1000000}')
    latency=$(awk -v s="${connect:-0}" 'BEGIN{printf "%d",s*1000+0.5}')
  else
    mbps="failed"; latency="failed"
  fi
  retrans="-"; [ "$direction" = "upload" ] && retrans=$(retrans_percent_from_ss "$ss_file")
  printf '%s|%s|%s|%s' "$mbps" "$latency" "$retrans" "$status"
}

speedtest_catalog_file() {
  case "$1" in
    北京) printf '%s/catalog-bj.json' "$WORK_DIR" ;;
    上海) printf '%s/catalog-sh.json' "$WORK_DIR" ;;
    广东) printf '%s/catalog-gd.json' "$WORK_DIR" ;;
    安徽) printf '%s/catalog-ah.json' "$WORK_DIR" ;;
    江苏) printf '%s/catalog-js.json' "$WORK_DIR" ;;
    *) return 1 ;;
  esac
}

ensure_speedtest_catalog() {
  local prov="$1" location lat lon file url
  file=$(speedtest_catalog_file "$prov") || return 1
  if [ -s "$file" ] && python3 - "$file" <<'PY' >/dev/null 2>&1
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(0 if isinstance(data, list) and data else 1)
PY
  then
    printf '%s' "$file"
    return 0
  fi
  location=$(speedtest_location "$prov") || return 1
  lat=${location%%,*}; lon=${location#*,}
  # 不加 https_functional 过滤：部分营运商双栈端点只公布 HTTP URL，
  # 过滤后反而会把可用的 IPv6 候选排除。
  url="https://www.speedtest.net/api/js/servers?engine=js&limit=200&lat=${lat}&lon=${lon}"
  curl -fsSL --retry 2 --connect-timeout 8 --max-time 30 \
    -A "$HTTP_USER_AGENT" "$url" -o "$file" 2>/dev/null || return 1
  python3 - "$file" <<'PY' >/dev/null 2>&1
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
raise SystemExit(0 if isinstance(data, list) and data else 1)
PY
  printf '%s' "$file"
}

speedtest_http_candidates() {
  local prov="$1" isp="$2" file
  file=$(ensure_speedtest_catalog "$prov") || return 1
  python3 - "$file" "$prov" "$isp" <<'PY'
import json, math, sys
from urllib.parse import urlsplit

path, province, isp = sys.argv[1:]
coords = {
    "北京": (39.9042, 116.4074), "上海": (31.2304, 121.4737),
    "广东": (23.1291, 113.2644), "安徽": (31.8206, 117.2272),
    "江苏": (32.0603, 118.7969),
}
aliases = {
    "电信": ("china telecom", "telecom", "chinanet", "ctgnet", "中国电信", "电信", "189.cn", "ah163"),
    "联通": ("china unicom", "unicom", "china169", "中国联通", "联通"),
    "移动": ("china mobile", "cmcc", "中国移动", "移动", "139site", "10086"),
}

def distance(a, b):
    r = 6371.0
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = math.radians(b[0]-a[0]), math.radians(b[1]-a[1])
    x = math.sin(dp/2)**2 + math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
    return 2*r*math.asin(math.sqrt(x))

try:
    rows = json.load(open(path, encoding="utf-8"))
except Exception:
    raise SystemExit(1)

found = []
for row in rows if isinstance(rows, list) else []:
    text = " ".join(str(row.get(k, "")) for k in ("sponsor", "name", "host", "url")).lower()
    if not any(alias.lower() in text for alias in aliases.get(isp, ())):
        continue
    if str(row.get("cc", "CN")).upper() not in ("", "CN"):
        continue
    try:
        d = distance(coords[province], (float(row["lat"]), float(row["lon"])))
        parts = urlsplit(str(row["url"]))
        host = parts.hostname
        if not host:
            continue
        port = parts.port or (443 if parts.scheme == "https" else 80)
        origin = f"{parts.scheme}://{host}:{port}"
        base = str(row["url"]).rsplit("/", 1)[0]
    except Exception:
        continue
    if d > 450:
        continue
    fields = [str(row.get("id", "-")), str(row.get("sponsor", "-")),
              str(row.get("name", "-")), str(row["url"]), host,
              str(port), origin, base, f"{d:.1f}", "-", "OoklaHTTP"]
    found.append((d, fields))

for _, fields in sorted(found, key=lambda item: item[0])[:8]:
    print("\t".join(value.replace("\t", " ").replace("\n", " ") for value in fields))
PY
}

ensure_speedtest_cn_catalog() {
  local file="$WORK_DIR/speedtest-cn.csv"
  if [ -s "$file" ] && head -1 "$file" 2>/dev/null | grep -q '^id,active,https,'; then
    printf '%s' "$file"
    return 0
  fi
  curl -fsSL --retry 2 --connect-timeout 8 --max-time 30 \
    -A "$HTTP_USER_AGENT" "$SPEEDTEST_CN_CATALOG_URL" -o "$file" 2>/dev/null || return 1
  head -1 "$file" 2>/dev/null | grep -q '^id,active,https,' || return 1
  printf '%s' "$file"
}

speedtest_cn_http_candidates() {
  local prov="$1" isp="$2" file
  file=$(ensure_speedtest_cn_catalog) || return 1
  python3 - "$file" "$prov" "$isp" <<'PY'
import csv, sys
from urllib.parse import urlsplit

path, province, isp = sys.argv[1:]
seen = set()
found = []
try:
    stream = open(path, newline="", encoding="utf-8-sig", errors="replace")
except OSError:
    raise SystemExit(1)
with stream:
    for row in csv.DictReader(stream):
        if row.get("province", "").strip() != province:
            continue
        if row.get("operator", "").strip() != isp:
            continue
        upload = row.get("uploadUrl", "").strip()
        download = row.get("downloadUrl", "").strip()
        try:
            parts = urlsplit(upload)
            host = parts.hostname
            if not host or not download:
                continue
            port = parts.port or (443 if parts.scheme == "https" else 80)
            origin = f"{parts.scheme}://{host}:{port}"
            base = upload.rsplit("/", 1)[0]
        except Exception:
            continue
        key = (host, port, upload, download)
        if key in seen:
            continue
        seen.add(key)
        preferred = row.get("preferred", "0").strip() == "1"
        high_speed = row.get("high_speed", "0").strip() == "1"
        fields = [row.get("id", "-"), row.get("sponsor", "speedtest.cn"),
                  row.get("city", "-"), upload, host, str(port), origin,
                  base, row.get("distance", "-"), download, "SpeedtestCN"]
        found.append((not preferred, not high_speed, fields))
for _, _, fields in sorted(found)[:10]:
    print("\t".join((value or "-").replace("\t", " ").replace("\n", " ") for value in fields))
PY
}

# 合肥三网端点曾长期公开在 Ookla 服务器目录中，但目前的动态目录偶尔
# 不再返回安徽。这里保留已知主机和两套常见目录结构，实际测速前仍会
# 分别解析 A／AAAA 并验证下载、上传，无法连接时不会生成速度值。
known_direct_http_candidates() {
  local prov="$1" isp="$2"
  [ "$prov" = "安徽" ] || return 0
  case "$isp" in
    电信)
      printf '%s\n' \
        $'17145-ccspt11-8080\t中国电信安徽分公司\t合肥\thttp://speedtest1.ah163.com:8080/ccspt11/upload.php\tspeedtest1.ah163.com\t8080\thttp://speedtest1.ah163.com:8080\thttp://speedtest1.ah163.com:8080/ccspt11\t0\thttp://speedtest1.ah163.com:8080/ccspt11/random4000x4000.jpg\tKnownHefei' \
        $'17145-speedtest-8080\t中国电信安徽分公司\t合肥\thttp://speedtest1.ah163.com:8080/speedtest/upload.php\tspeedtest1.ah163.com\t8080\thttp://speedtest1.ah163.com:8080\thttp://speedtest1.ah163.com:8080/speedtest\t0\thttp://speedtest1.ah163.com:8080/speedtest/random4000x4000.jpg\tKnownHefei' \
        $'17145-ccspt11-80\t中国电信安徽分公司\t合肥\thttp://speedtest1.ah163.com/ccspt11/upload.php\tspeedtest1.ah163.com\t80\thttp://speedtest1.ah163.com:80\thttp://speedtest1.ah163.com/ccspt11\t0\thttp://speedtest1.ah163.com/ccspt11/random4000x4000.jpg\tKnownHefei' \
        $'17145-ip-8080\t中国电信安徽分公司\t合肥\thttp://61.191.111.11:8080/speedtest/upload.php\t61.191.111.11\t8080\thttp://61.191.111.11:8080\thttp://61.191.111.11:8080/speedtest\t0\thttp://61.191.111.11:8080/speedtest/random4000x4000.jpg\tKnownHefeiIP' \
        $'17145-ip-80\t中国电信安徽分公司\t合肥\thttp://61.191.111.11/ccspt11/upload.php\t61.191.111.11\t80\thttp://61.191.111.11:80\thttp://61.191.111.11/ccspt11\t0\thttp://61.191.111.11/ccspt11/random4000x4000.jpg\tKnownHefeiIP'
      ;;
    联通)
      printf '%s\n' \
        $'5724-speedtest-8080\t中国联通安徽分公司\t合肥\thttp://112.122.10.26:8080/speedtest/upload.php\t112.122.10.26\t8080\thttp://112.122.10.26:8080\thttp://112.122.10.26:8080/speedtest\t0\thttp://112.122.10.26:8080/speedtest/random4000x4000.jpg\tKnownHefei'
      ;;
    移动)
      printf '%s\n' \
        $'34035-huainan-8080\t中国移动安徽分公司\t淮南\thttp://speedtest1.ah.chinamobile.com:8080/speedtest/upload.php\tspeedtest1.ah.chinamobile.com\t8080\thttp://speedtest1.ah.chinamobile.com:8080\thttp://speedtest1.ah.chinamobile.com:8080/speedtest\t0\thttp://speedtest1.ah.chinamobile.com:8080/speedtest/random4000x4000.jpg\tKnownAnhui' \
        $'26404-speedtest-8080\t中国移动安徽分公司\t合肥\thttp://speedtest2.ah.chinamobile.com:8080/speedtest/upload.php\tspeedtest2.ah.chinamobile.com\t8080\thttp://speedtest2.ah.chinamobile.com:8080\thttp://speedtest2.ah.chinamobile.com:8080/speedtest\t0\thttp://speedtest2.ah.chinamobile.com:8080/speedtest/random4000x4000.jpg\tKnownHefei' \
        $'26404-ip-8080\t中国移动安徽分公司\t合肥\thttp://112.29.5.6:8080/speedtest/upload.php\t112.29.5.6\t8080\thttp://112.29.5.6:8080\thttp://112.29.5.6:8080/speedtest\t0\thttp://112.29.5.6:8080/speedtest/random4000x4000.jpg\tKnownHefeiIP' \
        $'ahcm-alt-ip-8080\t中国移动安徽分公司\t合肥\thttp://112.29.5.58:8080/speedtest/upload.php\t112.29.5.58\t8080\thttp://112.29.5.58:8080\thttp://112.29.5.58:8080/speedtest\t0\thttp://112.29.5.58:8080/speedtest/random4000x4000.jpg\tKnownHefeiIP' \
        $'4377-speedtest-8080\t中国移动安徽分公司\t合肥\thttp://4gtest.ahydnet.com:8080/speedtest/upload.php\t4gtest.ahydnet.com\t8080\thttp://4gtest.ahydnet.com:8080\thttp://4gtest.ahydnet.com:8080/speedtest\t0\thttp://4gtest.ahydnet.com:8080/speedtest/random4000x4000.jpg\tKnownHefei' \
        $'4377-speedtest-80\t中国移动安徽分公司\t合肥\thttp://4gtest.ahydnet.com/speedtest/upload.php\t4gtest.ahydnet.com\t80\thttp://4gtest.ahydnet.com:80\thttp://4gtest.ahydnet.com/speedtest\t0\thttp://4gtest.ahydnet.com/speedtest/random4000x4000.jpg\tKnownHefei'
      ;;
  esac
}

# Ookla 为部分旧测速站保留 prod.hosts.ooklaserver.net 代理名。原运营商
# 域名失效或对境外来源丢包时，代理名可能仍可解析／连接；若代理名具有
# 原生 AAAA，也可用于 IPv6。测速仍逐项验证真实下载和上传，不凭目录造数。
known_ookla_alias_candidates() {
  local prov="$1" isp="$2"
  [ "$prov" = "安徽" ] || return 0
  case "$isp" in
    电信)
      printf '%s\n' \
        $'17145-ookla-id\t中国电信安徽分公司\t合肥\thttps://server-17145.prod.hosts.ooklaserver.net:8080/upload\tserver-17145.prod.hosts.ooklaserver.net\t8080\thttps://server-17145.prod.hosts.ooklaserver.net:8080\thttps://server-17145.prod.hosts.ooklaserver.net:8080\t0\thttps://server-17145.prod.hosts.ooklaserver.net:8080/download\tOoklaAlias' \
        $'17145-ookla-host\t中国电信安徽分公司\t合肥\thttps://speedtest1.ah163.com.prod.hosts.ooklaserver.net:8080/upload\tspeedtest1.ah163.com.prod.hosts.ooklaserver.net\t8080\thttps://speedtest1.ah163.com.prod.hosts.ooklaserver.net:8080\thttps://speedtest1.ah163.com.prod.hosts.ooklaserver.net:8080\t0\thttps://speedtest1.ah163.com.prod.hosts.ooklaserver.net:8080/download\tOoklaAlias'
      ;;
    联通)
      printf '%s\n' \
        $'5724-ookla-id\t中国联通安徽分公司\t合肥\thttps://server-5724.prod.hosts.ooklaserver.net:8080/upload\tserver-5724.prod.hosts.ooklaserver.net\t8080\thttps://server-5724.prod.hosts.ooklaserver.net:8080\thttps://server-5724.prod.hosts.ooklaserver.net:8080\t0\thttps://server-5724.prod.hosts.ooklaserver.net:8080/download\tOoklaAlias'
      ;;
    移动)
      printf '%s\n' \
        $'26404-ookla-id\t中国移动安徽分公司\t合肥\thttps://server-26404.prod.hosts.ooklaserver.net:8080/upload\tserver-26404.prod.hosts.ooklaserver.net\t8080\thttps://server-26404.prod.hosts.ooklaserver.net:8080\thttps://server-26404.prod.hosts.ooklaserver.net:8080\t0\thttps://server-26404.prod.hosts.ooklaserver.net:8080/download\tOoklaAlias' \
        $'34035-ookla-id\t中国移动安徽分公司\t淮南\thttps://server-34035.prod.hosts.ooklaserver.net:8080/upload\tserver-34035.prod.hosts.ooklaserver.net\t8080\thttps://server-34035.prod.hosts.ooklaserver.net:8080\thttps://server-34035.prod.hosts.ooklaserver.net:8080\t0\thttps://server-34035.prod.hosts.ooklaserver.net:8080/download\tOoklaAlias' \
        $'34035-ookla-host\t中国移动安徽分公司\t淮南\thttps://speedtest1.ah.chinamobile.com.prod.hosts.ooklaserver.net:8080/upload\tspeedtest1.ah.chinamobile.com.prod.hosts.ooklaserver.net\t8080\thttps://speedtest1.ah.chinamobile.com.prod.hosts.ooklaserver.net:8080\thttps://speedtest1.ah.chinamobile.com.prod.hosts.ooklaserver.net:8080\t0\thttps://speedtest1.ah.chinamobile.com.prod.hosts.ooklaserver.net:8080/download\tOoklaAlias'
      ;;
  esac
}

all_direct_http_candidates() {
  known_ookla_alias_candidates "$1" "$2" 2>/dev/null || true
  known_direct_http_candidates "$1" "$2" 2>/dev/null || true
  speedtest_http_candidates "$1" "$2" 2>/dev/null || true
  speedtest_cn_http_candidates "$1" "$2" 2>/dev/null || true
}

resolve_speedtest_host() {
  local family="$1" host="$2"
  if [ "$family" = "4" ]; then
    [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { printf '%s' "$host"; return; }
    getent ahostsv4 "$host" 2>/dev/null | awk '$1 !~ /:/&&!seen[$1]++{print $1;exit}'
  else
    [[ "$host" == *:* ]] && { printf '%s' "${host#[}" | sed 's/]$//'; return; }
    # glibc 可能把仅有 A 记录的主机合成为 ::ffff:x.x.x.x。那是 IPv4-mapped
    # 地址，不代表端点具有原生 IPv6，不能交给 curl -6 冒充 AAAA。
    getent ahostsv6 "$host" 2>/dev/null |
      awk 'tolower($1) !~ /^::ffff:/ && $1 ~ /:/ && !seen[$1]++ {print $1;exit}'
  fi
}

direct_http_download() {
  local family="$1" source="$2" host="$3" port="$4" ipaddr="$5" url="$6" work="$7"
  local meta="$work.download.meta" err="$work.download.err" sslog="$work.download.ss"
  local resolve_ip="$ipaddr" pid monitor_pid rc=0
  [ "$family" = "4" ] || resolve_ip="[$ipaddr]"
  curl "-$family" --interface "$source" --noproxy '*' --http1.1 -k -sS -L \
    -A "$HTTP_USER_AGENT" \
    --connect-timeout 5 --max-time "$SPEED_SECONDS" --resolve "$host:$port:$resolve_ip" \
    -H 'Cache-Control: no-cache' -o /dev/null \
    -w '%{http_code}|%{size_download}|%{speed_download}|%{time_connect}|%{time_total}|%{num_connects}' \
    "$url" > "$meta" 2> "$err" & pid=$!
  monitor_ss "$pid" "$ipaddr" "$sslog" & monitor_pid=$!
  wait "$pid" || rc=$?
  wait "$monitor_pid" 2>/dev/null || true
  printf '%s|%s|%s' "$rc" "$meta" "$sslog"
}

direct_http_upload() {
  local family="$1" source="$2" host="$3" port="$4" ipaddr="$5" url="$6" work="$7" payload_mode="${8:-form}"
  local meta="$work.upload.meta" err="$work.upload.err" sslog="$work.upload.ss"
  local resolve_ip="$ipaddr" pid monitor_pid rc=0 body_bytes="${9:-$SPEED_BYTES}"
  [ "$family" = "4" ] || resolve_ip="[$ipaddr]"
  (
    # curl 是测速结果的权威进程。测试端提早结束时，数据生成器可能收到
    # SIGPIPE；这里明确返回 curl 状态，避免把成功上传误判为失败。
    set +o pipefail
    if [ "$payload_mode" = "raw" ]; then
      head -c "$body_bytes" /dev/zero 2>/dev/null |
        curl "-$family" --interface "$source" --noproxy '*' --http1.1 -k -sS -L \
          -A "$HTTP_USER_AGENT" \
          --connect-timeout 5 --max-time "$SPEED_SECONDS" --resolve "$host:$port:$resolve_ip" \
          -X POST -H "Content-Length: $body_bytes" -H 'Expect:' \
          --data-binary @- -o /dev/null \
          -w '%{http_code}|%{size_upload}|%{speed_upload}|%{time_connect}|%{time_total}|%{num_connects}' \
          "$url" > "$meta" 2> "$err"
      exit "${PIPESTATUS[1]}"
    else
      {
        printf 'content1=' 2>/dev/null || true
        head -c "$((body_bytes - 9))" /dev/zero 2>/dev/null
      } | curl "-$family" --interface "$source" --noproxy '*' --http1.1 -k -sS -L \
          -A "$HTTP_USER_AGENT" \
          --connect-timeout 5 --max-time "$SPEED_SECONDS" --resolve "$host:$port:$resolve_ip" \
          -X POST -H "Content-Length: $body_bytes" -H 'Content-Type: application/x-www-form-urlencoded' -H 'Expect:' \
          --data-binary @- -o /dev/null \
          -w '%{http_code}|%{size_upload}|%{speed_upload}|%{time_connect}|%{time_total}|%{num_connects}' \
          "$url" > "$meta" 2> "$err"
      exit "${PIPESTATUS[1]}"
    fi
  ) & pid=$!
  monitor_ss "$pid" "$ipaddr" "$sslog" & monitor_pid=$!
  wait "$pid" || rc=$?
  wait "$monitor_pid" 2>/dev/null || true
  printf '%s|%s|%s' "$rc" "$meta" "$sslog"
}

direct_failure_detail() {
  local rc="$1" meta_file="$2" err_file="$3" http="-" bytes="-" error="-" rest
  if [ -s "$meta_file" ]; then
    IFS='|' read -r http bytes rest < "$meta_file" 2>/dev/null || true
  fi
  if [ -s "$err_file" ]; then
    error=$(tr ',\r\n' '   ' < "$err_file" | cut -c1-100)
    [ -n "$error" ] || error="-"
  fi
  printf '失败(rc=%s;http=%s;bytes=%s;curl=%s)' "$rc" "${http:--}" "${bytes:--}" "$error"
}

direct_failure_status() {
  local stage="$1" rc="$2" meta_file="$3" http="-" bytes="0" bps="0" rest
  if [ -s "$meta_file" ]; then
    IFS='|' read -r http bytes bps rest < "$meta_file" 2>/dev/null || true
  fi
  case "$rc" in
    6) printf '域名解析失败'; return ;;
    7) printf '端口拒绝或不可达'; return ;;
    28)
      if [ "${bytes:-0}" -lt 1048576 ] 2>/dev/null; then
        if [ "${bytes:-0}" -eq 0 ] 2>/dev/null && [ "${http:-000}" = "000" ]; then
          printf '连接超时'
        else
          printf '%s超时' "$stage"
        fi
        return
      fi
      ;;
  esac
  case "${http:--}" in
    401|403) printf '端点拒绝%s' "$stage"; return ;;
    404) printf '%s路径失效' "$stage"; return ;;
    429) printf '端点限流'; return ;;
    5??) printf '端点服务异常(HTTP %s)' "$http"; return ;;
  esac
  if [ "${bytes:-0}" -lt 1048576 ] 2>/dev/null; then
    printf '%s响应不足1MiB' "$stage"
  elif ! awk -v n="${bps:-0}" 'BEGIN{exit !(n>=12500)}'; then
    printf '%s低于0.1Mbps' "$stage"
  else
    printf '%s失败(rc=%s;HTTP=%s)' "$stage" "$rc" "${http:--}"
  fi
}

compact_speed_status() {
  case "$1" in
    候选端点无IPv4地址) printf '无A记录' ;;
    候选端点无IPv6地址) printf '无AAAA' ;;
    未发现同省同运营商IPv4端点) printf '无同省IPv4端点' ;;
    未发现同省同运营商IPv6端点) printf '无同省IPv6端点' ;;
    连接超时|下载超时|上传超时) printf '超时' ;;
    端点不可用或不支持该IP族) printf '核心失败' ;;
    测速低于0.1Mbps) printf '核心低于0.1Mbps' ;;
    仅下载可用：*) printf '仅下载/上传失败' ;;
    *) printf '%s' "$1" ;;
  esac
}

parse_direct_http_metric() {
  local direction="$1" rc="$2" meta_file="$3" ss_file="$4"
  local http bytes bps connect total connections mbps latency retrans status
  IFS='|' read -r http bytes bps connect total connections < "$meta_file" 2>/dev/null || true
  status="OK"
  [[ "${http:-}" =~ ^(200|201|202|204|206)$ ]] || status="FAIL"
  [ "$rc" -eq 0 ] || [ "$rc" -eq 28 ] || status="FAIL"
  [ "${bytes:-0}" -ge 1048576 ] 2>/dev/null || status="FAIL"
  awk -v n="${bps:-0}" 'BEGIN{exit !(n>=12500)}' || status="FAIL"
  [ "${connections:-0}" -le 1 ] 2>/dev/null || status="FAIL"
  if [ "$status" = "OK" ]; then
    mbps=$(awk -v n="$bps" 'BEGIN{printf "%.1f",n*8/1000000}')
    latency=$(awk -v n="${connect:-0}" 'BEGIN{printf "%.0f",n*1000}')
  else
    mbps="-"; latency="-"
  fi
  retrans="-"; [ "$direction" = "upload" ] && retrans=$(retrans_percent_from_ss "$ss_file")
  printf '%s|%s|%s|%s' "$mbps" "$latency" "$retrans" "$status"
}

run_nearest_ipv6_speed_row() {
  local host="speed.cloudflare.com" port="443" source="$SOURCE_IPV6" ipaddr work
  local download_bytes="$SPEED_BYTES" upload_bytes="$SPEED_BYTES"
  local download_url upload_url drc dmeta dss down dlat dummy dstatus
  local urc umeta uss up ulat retrans ustatus failure status
  ipaddr=$(resolve_speedtest_host 6 "$host" 2>/dev/null || true)
  if [ -z "$ipaddr" ]; then
    printf 'IPv6,最近,端点,CloudflareEdge,nearest-v6,%s,-,解析,无原生AAAA地址\n' \
      "$host" >> "$SPEED_AUDIT_CSV"
    printf '%s' '-|-|-|-|近端测速服务无原生AAAA|Cloudflare近端'
    return
  fi
  if [ -z "$source" ]; then
    source=$(ip -6 route get "$ipaddr" 2>/dev/null |
      sed -nE 's/.*[[:space:]]src[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
    SOURCE_IPV6="$source"
  fi
  if [ -z "$source" ]; then
    printf 'IPv6,最近,端点,CloudflareEdge,nearest-v6,%s,%s,路由,无可用IPv6来源地址\n' \
      "$host" "$ipaddr" >> "$SPEED_AUDIT_CSV"
    printf '%s' '-|-|-|-|本机无IPv6来源地址|Cloudflare近端'
    return
  fi

  # Cloudflare 官方测速序列的单次请求上限分别为 250 MB 下载与 50 MB 上传。
  # 这是端点接受的 payload 大小，不是 Mbps 限速；curl 仍按线路全速传输。
  [ "$download_bytes" -le 250000000 ] || download_bytes=250000000
  [ "$upload_bytes" -le 50000000 ] || upload_bytes=50000000
  work="$WORK_DIR/nearest-ipv6-cloudflare"
  # 严格对齐 Cloudflare 官方 BandwidthEngine：下载与上传都只携带 bytes
  # 查询参数。不要附加自定义 measId；部分边缘会拒绝非官方请求格式。
  download_url="https://${host}/__down?bytes=${download_bytes}"
  upload_url="https://${host}/__up?bytes=${upload_bytes}"
  IFS='|' read -r drc dmeta dss <<<"$(direct_http_download 6 "$source" "$host" "$port" "$ipaddr" "$download_url" "$work")"
  IFS='|' read -r down dlat dummy dstatus <<<"$(parse_direct_http_metric download "$drc" "$dmeta" "$dss")"
  if [ "$dstatus" != "OK" ]; then
    failure=$(direct_failure_detail "${drc:-1}" "${dmeta:-/dev/null}" "$work.download.err")
    status=$(direct_failure_status "下载" "${drc:-1}" "${dmeta:-/dev/null}")
    printf 'IPv6,最近,端点,CloudflareEdge,nearest-v6,%s,%s,下载,%s\n' \
      "$host" "$ipaddr" "$failure" >> "$SPEED_AUDIT_CSV"
    printf '%s' "-|-|-|-|${status}|Cloudflare近端#${ipaddr}"
    return
  fi

  IFS='|' read -r urc umeta uss <<<"$(direct_http_upload 6 "$source" "$host" "$port" "$ipaddr" "$upload_url" "$work" raw "$upload_bytes")"
  IFS='|' read -r up ulat retrans ustatus <<<"$(parse_direct_http_metric upload "$urc" "$umeta" "$uss")"
  if [ "$ustatus" != "OK" ]; then
    failure=$(direct_failure_detail "${urc:-1}" "${umeta:-/dev/null}" "$work.upload.err")
    status=$(direct_failure_status "上传" "${urc:-1}" "${umeta:-/dev/null}")
    printf 'IPv6,最近,端点,CloudflareEdge,nearest-v6,%s,%s,上传,%s\n' \
      "$host" "$ipaddr" "$failure" >> "$SPEED_AUDIT_CSV"
    printf '%s' "-|-|${down}|${dlat}|仅下载可用：${status}|Cloudflare近端#${ipaddr}"
    return
  fi

  printf 'IPv6,最近,端点,CloudflareEdge,nearest-v6,%s,%s,双向,成功(raw)\n' \
    "$host" "$ipaddr" >> "$SPEED_AUDIT_CSV"
  printf '%s|%s|%s|%s/%s|OK|Cloudflare近端#%s' \
    "$retrans" "$up" "$down" "$ulat" "$dlat" "$ipaddr"
}

run_direct_http_speed_row() {
  local family="$1" prov="$2" isp="$3" source
  local id sponsor city upload_url host port origin base distance download_hint catalog_source
  local ipaddr candidate_seen=0 resolve_seen=0 tested=0
  local work drc dmeta dss down dlat dummy dstatus urc umeta uss up ulat retrans ustatus
  local download_url download_hint_url upload_test_url upload_mode upload_modes failure status latency
  local last_status='' saved_down='' saved_dlat='' saved_engine=''
  if [ "$family" = "4" ]; then source="$SOURCE_IPV4"; else source="$SOURCE_IPV6"; fi
  [ -n "$source" ] || { printf '%s' "-|-|-|-|无本地IPv${family}|direct-http"; return; }
  while IFS=$'\t' read -r id sponsor city upload_url host port origin base distance download_hint catalog_source; do
    [ -n "$host" ] || continue
    candidate_seen=$((candidate_seen + 1))
    ipaddr=$(resolve_speedtest_host "$family" "$host" 2>/dev/null || true)
    if [ -z "$ipaddr" ]; then
      printf 'IPv%s,%s,%s,%s,%s,%s,-,解析,无对应地址族\n' \
        "$family" "$prov" "$isp" "${catalog_source:--}" "$id" "$host" >> "$SPEED_AUDIT_CSV"
      continue
    fi
    resolve_seen=$((resolve_seen + 1))
    work="$WORK_DIR/direct-${family}-${prov}-${isp}-${id}"
    dstatus="FAIL"
    download_hint_url=""
    if [ "${download_hint:--}" != "-" ]; then
      case "$download_hint" in
        *\?*) download_hint_url="${download_hint}&guid=cn-tcp-$RANDOM" ;;
        *) download_hint_url="${download_hint}?guid=cn-tcp-$RANDOM" ;;
      esac
    fi
    for download_url in \
      "$download_hint_url" \
      "${origin}/download?size=${SPEED_BYTES}&guid=cn-tcp-$RANDOM" \
      "${base}/random4000x4000.jpg?x=$(date +%s)$RANDOM"; do
      [ -n "$download_url" ] || continue
      IFS='|' read -r drc dmeta dss <<<"$(direct_http_download "$family" "$source" "$host" "$port" "$ipaddr" "$download_url" "$work")"
      IFS='|' read -r down dlat dummy dstatus <<<"$(parse_direct_http_metric download "$drc" "$dmeta" "$dss")"
      [ "$dstatus" = "OK" ] && break
    done
    if [ "$dstatus" != "OK" ]; then
      failure=$(direct_failure_detail "${drc:-1}" "${dmeta:-/dev/null}" "$work.download.err")
      last_status=$(direct_failure_status "下载" "${drc:-1}" "${dmeta:-/dev/null}")
      printf 'IPv%s,%s,%s,%s,%s,%s,%s,下载,%s\n' \
        "$family" "$prov" "$isp" "${catalog_source:--}" "$id" "$host" "$ipaddr" "$failure" >> "$SPEED_AUDIT_CSV"
      continue
    fi
    tested=$((tested + 1))
    saved_down="$down"; saved_dlat="$dlat"; saved_engine="${catalog_source:-DirectHTTP}#${id}:${host}"
    if [ "$catalog_source" = "SpeedtestCN" ]; then upload_modes="raw form"; else upload_modes="form raw"; fi
    for upload_test_url in "$upload_url" "${origin}/upload?guid=cn-tcp-$RANDOM"; do
      for upload_mode in $upload_modes; do
        IFS='|' read -r urc umeta uss <<<"$(direct_http_upload "$family" "$source" "$host" "$port" "$ipaddr" "$upload_test_url" "$work" "$upload_mode")"
        IFS='|' read -r up ulat retrans ustatus <<<"$(parse_direct_http_metric upload "$urc" "$umeta" "$uss")"
        if [ "$ustatus" = "OK" ]; then
          latency="${ulat}/${dlat}"
          printf 'IPv%s,%s,%s,%s,%s,%s,%s,双向,成功(%s)\n' \
            "$family" "$prov" "$isp" "${catalog_source:--}" "$id" "$host" "$ipaddr" "$upload_mode" >> "$SPEED_AUDIT_CSV"
          printf '%s|%s|%s|%s|OK|%s' "$retrans" "$up" "$down" "$latency" "$saved_engine"
          return
        fi
      done
    done
    failure=$(direct_failure_detail "${urc:-1}" "${umeta:-/dev/null}" "$work.upload.err")
    last_status=$(direct_failure_status "上传" "${urc:-1}" "${umeta:-/dev/null}")
    printf 'IPv%s,%s,%s,%s,%s,%s,%s,上传,%s\n' \
      "$family" "$prov" "$isp" "${catalog_source:--}" "$id" "$host" "$ipaddr" "$failure" >> "$SPEED_AUDIT_CSV"
  done < <(all_direct_http_candidates "$prov" "$isp")
  if [ -n "$saved_down" ]; then
    printf '%s' "-|-|${saved_down}|${saved_dlat}|仅下载可用：${last_status:-上传失败}|${saved_engine}"
  elif [ "$candidate_seen" -eq 0 ]; then
    printf '%s' "-|-|-|-|未发现同省同运营商IPv${family}端点|direct-http"
  elif [ "$resolve_seen" -eq 0 ]; then
    printf '%s' "-|-|-|-|候选端点无IPv${family}地址|direct-http"
  elif [ "$tested" -eq 0 ]; then
    printf '%s' "-|-|-|-|${last_status:-IPv${family}候选端点拒绝下载}|direct-http"
  else
    printf '%s' "-|-|-|-|${last_status:-IPv${family}端点测速失败}|direct-http"
  fi
}

speedtest_server_ids() {
  case "$1|$2" in
    北京\|电信) printf '27377 4751' ;;
    北京\|联通) printf '43752 5145 5505 18462' ;;
    北京\|移动) printf '25858 4713' ;;
    上海\|电信) printf '3633 28139' ;;
    上海\|联通) printf '24447 21005 5083' ;;
    上海\|移动) printf '25637 30154 4665 16719 16803' ;;
    广东\|电信) printf '27594 9151 10775 17251 5081' ;;
    广东\|联通) printf '26678 3891 16192 10201' ;;
    广东\|移动) printf '4515 6611 31520' ;;
    安徽\|电信) printf '17145' ;;
    安徽\|联通) printf '5724' ;;
    安徽\|移动) printf '26404 34035 4377' ;;
    江苏\|电信) printf '5396 36663 26352 5316 5324 5317' ;;
    江苏\|联通) printf '13704 5446' ;;
    江苏\|移动) printf '16204 27249 21590 21530 21722 21845 26850' ;;
    *) return 1 ;;
  esac
}

speedtest_location() {
  case "$1" in
    北京) printf '39.9042,116.4074' ;;
    上海) printf '31.2304,121.4737' ;;
    广东) printf '23.1291,113.2644' ;;
    安徽) printf '31.8206,117.2272' ;;
    江苏) printf '32.0603,118.7969' ;;
    *) return 1 ;;
  esac
}

speedtest_search_keyword() {
  case "$1" in
    电信) printf 'China Telecom' ;;
    联通) printf 'China Unicom' ;;
    移动) printf 'China Mobile' ;;
    *) return 1 ;;
  esac
}

discover_speedtest_sources() {
  local target4 target6
  target4=$(awk -F '\t' '$3=="4"&&$7!="-"{print $7;exit}' "$PLAN_FILE")
  target6=$(awk -F '\t' '$3=="6"&&$7!="-"{print $7;exit}' "$PLAN_FILE")
  if [ -z "$SOURCE_IPV4" ] && [ -n "$target4" ]; then
    SOURCE_IPV4=$(ip -4 route get "$target4" 2>/dev/null | sed -nE 's/.*[[:space:]]src[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
  fi
  if [ -z "$SOURCE_IPV6" ] && [ -n "$target6" ]; then
    SOURCE_IPV6=$(ip -6 route get "$target6" 2>/dev/null | sed -nE 's/.*[[:space:]]src[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
  fi
}

install_speedtest_engine() {
  local machine arch asset base archive checksums expected actual extracted fallback
  if [ -n "$SPEEDTEST_BIN" ] && [ -x "$SPEEDTEST_BIN" ]; then return 0; fi
  if command -v speedtest-go >/dev/null 2>&1; then
    SPEEDTEST_BIN=$(command -v speedtest-go); SPEEDTEST_ENGINE=go; return 0
  fi
  if command -v speedtest-cli >/dev/null 2>&1; then
    SPEEDTEST_BIN=$(command -v speedtest-cli); SPEEDTEST_ENGINE=cli; return 0
  fi
  [ "$SPEEDTEST_INSTALL_TRIED" -eq 0 ] || return 1
  SPEEDTEST_INSTALL_TRIED=1
  machine=$(uname -m)
  case "$machine" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7|armv7l) arch="armv7" ;;
    i386|i486|i586|i686) arch="i386" ;;
    s390x|riscv64|ppc64|ppc64le|loong64) arch="$machine" ;;
    *) arch="" ;;
  esac
  if [ -n "$arch" ] && command -v tar >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1; then
    asset="speedtest-go_${SPEEDTEST_GO_VERSION}_Linux_${arch}.tar.gz"
    base="https://github.com/showwin/speedtest-go/releases/download/v${SPEEDTEST_GO_VERSION}"
    archive="$WORK_DIR/$asset"; checksums="$WORK_DIR/speedtest-go-checksums.txt"
    if curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 "$base/$asset" -o "$archive" &&
       curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 "$base/checksums.txt" -o "$checksums"; then
      expected=$(awk -v f="$asset" '{name=$2;sub(/^\*/,"",name);if(name==f){print $1;exit}}' "$checksums")
      actual=$(sha256sum "$archive" | awk '{print $1}')
      if [ -n "$expected" ] && [ "$actual" = "$expected" ]; then
        mkdir -p "$WORK_DIR/speedtest-go"
        if tar -xzf "$archive" -C "$WORK_DIR/speedtest-go"; then
          extracted=$(find "$WORK_DIR/speedtest-go" -maxdepth 3 -type f \
            \( -name speedtest -o -name speedtest-go \) -print | head -1)
          if [ -n "$extracted" ]; then
            chmod +x "$extracted"
            SPEEDTEST_BIN="$extracted"; SPEEDTEST_ENGINE=go
            return 0
          fi
        fi
      fi
    fi
  fi

  fallback="$WORK_DIR/speedtest-cli.py"
  if command -v python3 >/dev/null 2>&1 &&
     curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 \
       "https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py" -o "$fallback" &&
     grep -q 'Speedtest' "$fallback"; then
    chmod +x "$fallback"
    SPEEDTEST_BIN="$fallback"; SPEEDTEST_ENGINE=cli
    return 0
  fi
  SPEEDTEST_INSTALL_ERROR="speedtest-go 与 speedtest-cli 均无法安装"
  return 1
}

monitor_speedtest_pid() {
  local pid="$1" out="$2"
  : > "$out"
  while kill -0 "$pid" 2>/dev/null; do
    ss -tinp 2>/dev/null | awk -v needle="pid=$pid," '
      /^[^[:space:]]/ {keep=index($0,needle)>0; next}
      keep {print}
    ' >> "$out" || true
    sleep 0.1
  done
}

json_number() {
  local key="$1" file="$2"
  grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*[-+0-9.eE]+" "$file" 2>/dev/null |
    head -1 | sed -E 's/.*:[[:space:]]*//'
}

json_string() {
  local key="$1" file="$2"
  grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null |
    head -1 | sed -E 's/^[^:]*:[[:space:]]*"//;s/"$//'
}

execute_speedtest_candidate() {
  local family="$1" tag="$2" label="$3"
  shift 3
  local json="$WORK_DIR/speedtest-${family}-${tag}.json"
  local sslog="$WORK_DIR/speedtest-${family}-${tag}.ss"
  local pid monitor_pid rc=0 dl up latency retrans endpoint_id
  timeout 120 "$@" > "$json" 2>/dev/null & pid=$!
  monitor_speedtest_pid "$pid" "$sslog" & monitor_pid=$!
  wait "$pid" || rc=$?
  wait "$monitor_pid" 2>/dev/null || true
  [ "$rc" -eq 0 ] || return 1
  if [ "$SPEEDTEST_ENGINE" = "cli" ]; then
    dl=$(json_number download "$json"); up=$(json_number upload "$json"); latency=$(json_number ping "$json")
    [[ "$dl" =~ ^[-+0-9.eE]+$ ]] && [[ "$up" =~ ^[-+0-9.eE]+$ ]] || return 1
    awk -v d="$dl" -v u="$up" 'BEGIN{exit !(d>=100000&&u>=100000)}' || return 3
    dl=$(awk -v n="$dl" 'BEGIN{printf "%.1f",n/1000000}')
    up=$(awk -v n="$up" 'BEGIN{printf "%.1f",n/1000000}')
    if [[ "$latency" =~ ^[-+0-9.eE]+$ ]]; then latency=$(awk -v n="$latency" 'BEGIN{printf "%.0f",n}'); else latency="-"; fi
  else
    dl=$(json_number dl_speed "$json"); up=$(json_number ul_speed "$json"); latency=$(json_number latency "$json")
    [[ "$dl" =~ ^[-+0-9.eE]+$ ]] && [[ "$up" =~ ^[-+0-9.eE]+$ ]] || return 1
    # speedtest-go 输出字节／秒；12500 B/s 等于 0.1 Mbps，低于此值不标记为 OK。
    awk -v d="$dl" -v u="$up" 'BEGIN{exit !(d>=12500&&u>=12500)}' || return 3
    dl=$(awk -v n="$dl" 'BEGIN{printf "%.1f",n*8/1000000}')
    up=$(awk -v n="$up" 'BEGIN{printf "%.1f",n*8/1000000}')
    if [[ "$latency" =~ ^[-+0-9.eE]+$ ]]; then latency=$(awk -v n="$latency" 'BEGIN{printf "%.0f",n/1000000}'); else latency="-"; fi
  fi
  endpoint_id=$(json_string id "$json" 2>/dev/null || true)
  [ -n "$endpoint_id" ] || endpoint_id=$(json_number id "$json" 2>/dev/null || true)
  retrans=$(retrans_percent_from_ss "$sslog")
  printf '%s|%s|%s|%s|OK|speedtest.net#%s(%s)' \
    "$retrans" "$up" "$dl" "$latency" "${endpoint_id:-unknown}" "$label"
}

run_speedtest_row() {
  local family="$1" prov="$2" isp="$3" source ids id location keyword result rc low_speed=0
  local -a args=()
  [ "$family" = "4" ] || {
    printf '%s' '-|-|-|-|IPv6不使用Speedtest核心|speedtest'
    return
  }
  if [ "$family" = "4" ]; then source="$SOURCE_IPV4"; else source="$SOURCE_IPV6"; fi
  [ -n "$source" ] || {
    printf '%s' "-|-|-|-|无本地IPv${family}|speedtest-go"
    return
  }
  install_speedtest_engine || {
    printf '%s' "-|-|-|-|${SPEEDTEST_INSTALL_ERROR:-测速核心安装失败}|speedtest"
    return
  }
  # 不传 --saving-mode，也不使用 curl --limit-rate；单线程按线路能力运行。
  if [ "$SPEEDTEST_ENGINE" = "go" ]; then
    location=$(speedtest_location "$prov" 2>/dev/null || true)
    keyword=$(speedtest_search_keyword "$isp" 2>/dev/null || true)
    if [ -n "$location" ] && [ -n "$keyword" ]; then
      result=$(execute_speedtest_candidate "$family" "dynamic-${prov}-${isp}" "dynamic/go" \
        "$SPEEDTEST_BIN" --location="$location" --search="$keyword" --filter-cc=CN \
        --source="$source" --thread=1 --json "${args[@]}")
      rc=$?
      if [ "$rc" -eq 0 ]; then
        printf 'IPv%s,%s,%s,SpeedtestCore,dynamic,-,-,测速,成功\n' \
          "$family" "$prov" "$isp" >> "$SPEED_AUDIT_CSV"
        printf '%s' "$result"; return
      fi
      printf 'IPv%s,%s,%s,SpeedtestCore,dynamic,-,-,测速,失败(rc=%s)\n' \
        "$family" "$prov" "$isp" "$rc" >> "$SPEED_AUDIT_CSV"
      [ "$rc" -ne 3 ] || low_speed=1
    fi
  fi
  ids=$(speedtest_server_ids "$prov" "$isp" 2>/dev/null || true)
  [ -n "$ids" ] || { printf '%s' '-|-|-|-|无候选端点|speedtest-go'; return; }
  for id in $ids; do
    if [ "$SPEEDTEST_ENGINE" = "cli" ]; then
      result=$(execute_speedtest_candidate "$family" "${prov}-${isp}-${id}" "static/cli" \
        python3 "$SPEEDTEST_BIN" --server "$id" --source "$source" --single --secure --json)
    else
      result=$(execute_speedtest_candidate "$family" "${prov}-${isp}-${id}" "static/go" \
        "$SPEEDTEST_BIN" --server="$id" --source="$source" --thread=1 --json "${args[@]}")
    fi
    rc=$?
    if [ "$rc" -eq 0 ]; then
      printf 'IPv%s,%s,%s,SpeedtestCore,%s,-,-,测速,成功\n' \
        "$family" "$prov" "$isp" "$id" >> "$SPEED_AUDIT_CSV"
      printf '%s' "$result"; return
    fi
    printf 'IPv%s,%s,%s,SpeedtestCore,%s,-,-,测速,失败(rc=%s)\n' \
      "$family" "$prov" "$isp" "$id" "$rc" >> "$SPEED_AUDIT_CSV"
    [ "$rc" -ne 3 ] || low_speed=1
  done
  [ "$low_speed" -eq 0 ] || { printf '%s' '-|-|-|-|测速低于0.1Mbps|speedtest'; return; }
  printf '%s' '-|-|-|-|端点不可用或不支持该IP族|speedtest-go'
}

run_tos_speed_row() {
  local prov="$1" isp="$2" type family node_prov node_isp host ipaddr port target
  local region bucket work urc umeta uss drc dmeta dss candidate=0
  local up ulat retrans ustatus down dlat dummy dstatus latency
  region=$(tos_region "$prov"); bucket=$(tos_bucket_host "$region")
  while IFS=$'\t' read -r type family node_prov node_isp host ipaddr port target; do
    candidate=$((candidate + 1))
    work="$WORK_DIR/tos-${prov}-${isp}-${candidate}"
    IFS='|' read -r urc umeta uss <<<"$(curl_probe upload "$bucket" "$ipaddr" "$work")"
    IFS='|' read -r up ulat retrans ustatus <<<"$(parse_curl_metric upload "$urc" "$umeta" "$uss")"
    IFS='|' read -r drc dmeta dss <<<"$(curl_probe download "$bucket" "$ipaddr" "$work")"
    IFS='|' read -r down dlat dummy dstatus <<<"$(parse_curl_metric download "$drc" "$dmeta" "$dss")"
    if [ "$ustatus" = "OK" ] && [ "$dstatus" = "OK" ]; then
      latency="${ulat}/${dlat}"
      printf '%s|%s|%s|%s|OK|TOS:%s' "$retrans" "$up" "$down" "$latency" "$ipaddr"
      return
    fi
  done < <(awk -F '\t' -v p="$prov" -v i="$isp" '$1=="tos"&&$2=="4"&&$3==p&&$4==i' "$NODE_FILE")
  if [ "$candidate" -eq 0 ]; then
    printf '%s' '-|-|-|-|无TOS端点|TOS'
  else
    printf '%s' '-|-|-|-|全部TOS候选失败|TOS'
  fi
}

print_speed_result_row() {
  local family="$1" prov="$2" isp="$3" retrans="$4" up="$5" down="$6" latency="$7" status="$8" engine="$9"
  local color="$GREEN" display_status
  [ "$status" = "OK" ] || color="$YELLOW"
  display_status=$(compact_speed_status "$status")
  printf '  '; printf '%b' "$CYAN"; pad_left 5 "IPv$family"; printf '%b' "$NC"
  printf '  '; printf '%b' "$CYAN"; pad_left 10 "$prov$isp"; printf '%b' "$NC"
  printf '  '; printf '%b' "$color"; pad_left 9 "$(metric_text "$retrans" '%')"; printf '%b' "$NC"
  printf '  '; printf '%b' "$color"; pad_left 10 "$(metric_text "$up" 'Mbps')"; printf '%b' "$NC"
  printf '  '; printf '%b' "$color"; pad_left 10 "$(metric_text "$down" 'Mbps')"; printf '%b' "$NC"
  printf '  '; printf '%b' "$color"; pad_left 11 "$(metric_text "$latency" 'ms')"; printf '%b' "$NC"
  printf '  '; printf '%b' "$color"; pad_left 18 "$display_status"; printf '%b\n' "$NC"
  printf 'IPv%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$family" "$prov" "$isp" "$retrans" "$up" "$down" "$latency" "$status" "$engine" >> "$SPEED_CSV"
}

run_speedtests() {
  local family prov isp result retrans up down latency status engine current
  local direct_status direct_engine fallback_status fallback_engine direct_short fallback_short
  local completed=0 total
  SPEED_CSV="$OUTPUT_DIR/single-thread-speed.csv"
  SPEED_AUDIT_CSV="$OUTPUT_DIR/endpoint-audit.csv"
  SPEED_EXECUTED=1
  printf '\xEF\xBB\xBF协议,省份,运营商,回程重传(%%),回程速度(Mbps),去程速度(Mbps),节点延迟(ms),状态,测速端点\n' > "$SPEED_CSV"
  printf '\xEF\xBB\xBF协议,省份,运营商,目录来源,端点ID,域名,解析地址,阶段,结果\n' > "$SPEED_AUDIT_CSV"
  total=0
  if [ -z "$ONLY_FAMILY" ] || [ "$ONLY_FAMILY" = "4" ]; then
    for prov in 北京 上海 广东; do
      selected_province "$prov" || continue
      total=$((total + 3))
    done
  fi
  if [ -z "$ONLY_FAMILY" ] || [ "$ONLY_FAMILY" = "6" ]; then
    total=$((total + 1))
  fi
  echo -e "${BOLD}${CYAN}北上广 IPv4 三网＋IPv6 最近端点单线程测速${NC}"
  echo -e "${DIM}IPv4 保留北上广 9 组；IPv6 强制 curl -6 自动连接最近边缘；单连接、不限制 Mbps。${NC}"
  if [ "$total" -eq 0 ]; then
    echo -e "${YELLOW}IPv4 所选范围不含北京、上海、广东，本次不执行吞吐测速。${NC}"
    echo
    return
  fi
  discover_speedtest_sources
  echo
  printf '  '; pad_left 5 '协议'; printf '  '; pad_left 10 '地区线路'; printf '  '; pad_left 9 '回程重传'; printf '  '; pad_left 10 '回程速度'; printf '  '; pad_left 10 '去程速度'; printf '  '; pad_left 11 '节点延迟'; printf '  '; pad_left 18 '状态'; printf '\n'
  if [ -z "$ONLY_FAMILY" ] || [ "$ONLY_FAMILY" = "4" ]; then
    family=4
    for prov in 北京 上海 广东; do
      selected_province "$prov" || continue
      for isp in 电信 联通 移动; do
        current="IPv${family} ${prov}${isp}"
        render_progress "单线程测速" "$completed" "$total" "$current"
        result=$(run_tos_speed_row "$prov" "$isp")
        IFS='|' read -r retrans up down latency status engine <<< "$result"
        [ "$status" = "OK" ] || result=""
        if [ -z "$result" ]; then
          result=$(run_direct_http_speed_row 4 "$prov" "$isp")
          IFS='|' read -r retrans up down latency status engine <<< "$result"
          if [ "$status" != "OK" ] && [[ "$status" != 仅下载可用* ]]; then
            direct_status="$status"; direct_engine="$engine"
            result=$(run_speedtest_row 4 "$prov" "$isp")
            IFS='|' read -r retrans up down latency fallback_status fallback_engine <<< "$result"
            if [ "$fallback_status" != "OK" ]; then
              direct_short=$(compact_speed_status "$direct_status")
              fallback_short=$(compact_speed_status "$fallback_status")
              status="直连${direct_short}；${fallback_short}"
              engine="${direct_engine}+${fallback_engine}"
              result="-|-|-|-|${status}|${engine}"
            fi
          fi
        fi
        IFS='|' read -r retrans up down latency status engine <<< "$result"
        clear_progress
        print_speed_result_row "$family" "$prov" "$isp" "$retrans" "$up" "$down" "$latency" "$status" "$engine"
        completed=$((completed + 1))
        render_progress "单线程测速" "$completed" "$total" "完成 ${current}"
      done
    done
  fi
  if [ -z "$ONLY_FAMILY" ] || [ "$ONLY_FAMILY" = "6" ]; then
    current="IPv6 最近端点"
    render_progress "单线程测速" "$completed" "$total" "$current"
    if [ "$IPV6_OK" -ne 1 ]; then
      retrans='-'; up='-'; down='-'; latency='-'; status='本机无IPv6，跳过'; engine='-'
    else
      result=$(run_nearest_ipv6_speed_row)
      IFS='|' read -r retrans up down latency status engine <<< "$result"
    fi
    clear_progress
    print_speed_result_row 6 "最近" "端点" "$retrans" "$up" "$down" "$latency" "$status" "$engine"
    completed=$((completed + 1))
    render_progress "单线程测速" "$completed" "$total" "完成 ${current}"
  fi
  finish_progress "单线程测速" "$total" "全部完成"
  echo
}

write_summary() {
  local report="$OUTPUT_DIR/README.txt" total normal skipped unreachable
  if find "$RESULT_DIR" -name '*.tsv' -type f -print -quit | grep -q .; then
    total=$(find "$RESULT_DIR" -name '*.tsv' -type f | wc -l | tr -d ' ')
    normal=$(awk -F '\t' '$11=="正常"{n++}END{print n+0}' "$RESULT_DIR"/*.tsv)
    skipped=$(awk -F '\t' '$11=="跳过"{n++}END{print n+0}' "$RESULT_DIR"/*.tsv)
  else
    total=0; normal=0; skipped=0
  fi
  unreachable=$((total-normal-skipped))
  {
    echo "$SCRIPT_NAME V$VERSION"
    echo "报告时间：$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S CST（北京时间）')"
    echo "节点来源：$NODE_SOURCE"
    echo "测试范围：$SELECTED_PROVINCES"
    echo "TCP 节点：$total；正常：$normal；跳过：$skipped；异常：$unreachable"
    echo "IPv6：$([ "$IPV6_OK" -eq 1 ] && echo 可用 || echo 无可用默认路由，已跳过)"
    echo "单线程测速：$([ "$SPEED_EXECUTED" -eq 1 ] && echo 已执行 || echo 未执行，可使用 --speed)"
    echo
    echo "文件："
    [ "$total" -gt 0 ] && echo "  tcp-quality.csv"
    [ "$SPEED_EXECUTED" -eq 1 ] && echo "  single-thread-speed.csv"
    [ "$SPEED_EXECUTED" -eq 1 ] && echo "  endpoint-audit.csv"
  } > "$report"
}

self_test() {
  local cdn4 cdn6 tos plan
  cdn4=$(awk -F '\t' '$1=="cdn"&&$2=="4"{n++}END{print n+0}' "$NODE_FILE")
  cdn6=$(awk -F '\t' '$1=="cdn"&&$2=="6"{n++}END{print n+0}' "$NODE_FILE")
  tos=$(awk -F '\t' '$1=="tos"&&$2=="4"{n++}END{print n+0}' "$NODE_FILE")
  plan=$(wc -l < "$PLAN_FILE" | tr -d ' ')
  [ "$cdn4" -eq 15 ] && [ "$cdn6" -eq 15 ] && [ "$tos" -eq 9 ] && [ "$plan" -eq 30 ] || {
    echo "SELF-TEST FAIL: cdn4=$cdn4 cdn6=$cdn6 tos=$tos plan=$plan" >&2; exit 1;
  }
  echo "SELF-TEST PASS: 15 IPv4 + 15 IPv6 TCP nodes, 9 IPv4 TOS endpoints."
}

main() {
  parse_args "$@"
  if [ -z "$OUTPUT_DIR" ]; then
    if [ "$(id -u)" -eq 0 ]; then OUTPUT_DIR="/root/CN_TCP_QUALITY_$(date +%Y%m%d_%H%M%S)"; else OUTPUT_DIR="$PWD/CN_TCP_QUALITY_$(date +%Y%m%d_%H%M%S)"; fi
  fi
  mkdir -p "$OUTPUT_DIR"
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cn-tcp-quality.XXXXXX")
  RESULT_DIR="$WORK_DIR/results"; mkdir -p "$RESULT_DIR"
  NODE_FILE="$WORK_DIR/nodes.tsv"; PLAN_FILE="$WORK_DIR/plan.tsv"
  trap 'rm -rf -- "$WORK_DIR"' EXIT INT TERM
  [ "$SELF_TEST" -eq 1 ] || show_banner
  load_nodes
  prepare_probe_plan
  [ "$SELF_TEST" -eq 0 ] || { self_test; exit 0; }
  need_root
  install_dependencies
  IPV6_OK=0; ipv6_route_available && IPV6_OK=1

  echo "报告时间：$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S CST（北京时间）')"
  echo "节点来源：$NODE_SOURCE"
  echo "测试范围：$SELECTED_PROVINCES"
  echo "IPv6 状态：$([ "$IPV6_OK" -eq 1 ] && echo 可用 || echo 无可用默认路由，将自动跳过)"
  if [ "$SPEED_ONLY" -eq 1 ]; then
    echo "运行模式：仅单线程测速（已跳过 TCP 品质探测）"
  elif [ "$QUICK" -eq 0 ] && [ "$COUNT_EXPLICIT" -eq 0 ]; then
    echo "丢包采样：每节点 30 包；部分丢包自动补测至 60 包"
  else
    echo "丢包采样：每节点 $COUNT 包"
  fi
  if [ "$SPEED_ONLY" -eq 0 ]; then
    echo
    echo -e "${DIM}正在探测 $(wc -l < "$PLAN_FILE") 个节点，请稍候……${NC}"
    run_tcp_probes
    echo
    show_tcp_results
  fi
  if [ "$RUN_SPEED" -eq 1 ]; then
    run_speedtests
  fi
  write_summary
  echo -e "${DIM}注：TCP 品质覆盖五省 30 组；吞吐测北上广 IPv4 9 组＋IPv6 最近端点 1 组，单线程不限制 Mbps。${NC}"
  echo -e "${GREEN}结果已保存：$OUTPUT_DIR${NC}"
}

main "$@"
