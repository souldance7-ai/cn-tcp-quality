#!/usr/bin/env bash

# CN TCP Quality V1
# Five-province, three-carrier, dual-stack TCP quality probe.
# SPDX-License-Identifier: MIT

set -uo pipefail

VERSION="1.0.0"
NODE_API="${CN_TCP_NODE_API:-https://tcpquality.ibsgss.uk/getNodes?format=tsv}"
COUNT=20
PARALLEL=6
DELAY_MS=120
RUN_SPEED=0
SPEED_EXECUTED=0
SPEED_SECONDS=8
SPEED_BYTES=$((256 * 1024 * 1024))
ONLY_FAMILY=""
NO_COLOR=0
QUICK=0
SELF_TEST=0
OUTPUT_DIR=""
SELECTED_PROVINCES=""
SCRIPT_NAME="CN TCP Quality"

if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  CYAN=$'\033[36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; DIM=""; NC=""
fi

usage() {
  cat <<'EOF'
CN TCP Quality V1

用法：
  bash cn-tcp-quality.sh [选项]

选项：
  --speed             追加真实 TOS 单线程上下行测速（流量较大）
  --quick             快速模式：每节点 8 包，测速 3 秒／64MiB
  -c, --count N       每个 TCP 节点发包数，默认 20，范围 3-100
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
  单线程吞吐仅对存在真实上传／下载端点的线路显示结果。
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
      --quick) QUICK=1; shift ;;
      -4|--ipv4) ONLY_FAMILY=4; shift ;;
      -6|--ipv6) ONLY_FAMILY=6; shift ;;
      --no-color) NO_COLOR=1; shift ;;
      --self-test) SELF_TEST=1; shift ;;
      -c|--count)
        [ "${2:-}" != "" ] && [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge 3 ] && [ "$2" -le 100 ] || {
          echo "发包数必须为 3-100。" >&2; exit 2;
        }
        COUNT="$2"; shift 2 ;;
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
    COUNT=8
    SPEED_SECONDS=3
    SPEED_BYTES=$((64 * 1024 * 1024))
  }
  [ "$NO_COLOR" -eq 0 ] || RED="" GREEN="" YELLOW="" CYAN="" BOLD="" DIM="" NC=""
  [ -n "$SELECTED_PROVINCES" ] || SELECTED_PROVINCES="北京|上海|广东|安徽|江苏"
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
  [ "${#missing[@]}" -eq 0 ] && return 0

  echo -e "${YELLOW}[!] 缺少依赖：${missing[*]}，正在安装……${NC}"
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl nmap iproute2 coreutils >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q curl nmap iproute coreutils >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q curl nmap iproute coreutils >/dev/null 2>&1
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl nmap-nping iproute2 coreutils >/dev/null 2>&1
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm curl nmap iproute2 coreutils >/dev/null 2>&1
  else
    echo "无法识别包管理器，请手动安装 curl、nmap/nping、iproute2、coreutils。" >&2
    exit 1
  fi

  for cmd in curl nping ip ss timeout; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "依赖安装失败：$cmd" >&2; exit 1; }
  done
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
  NODE_SOURCE="builtin-fallback"
  if [ "$SELF_TEST" -eq 0 ] && curl -fsSL --retry 2 --connect-timeout 6 --max-time 25 "$NODE_API" -o "$remote" 2>/dev/null; then
    normalize_remote_nodes "$remote" "$normalized"
    if [ "$(awk -F '\t' '$1=="cdn"{n++} END{print n+0}' "$normalized")" -ge 30 ]; then
      cp "$normalized" "$NODE_FILE"
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
  ip6=$(awk -F '\t' '$3=="6" && $8!="-" {print $8; exit}' "$PLAN_FILE")
  [ -n "$ip6" ] && ip -6 route get "$ip6" >/dev/null 2>&1
}

calc_metrics() {
  local values="$1" count="$2" received avg jitter min max p95 loss sorted idx
  received=$(wc -l < "$values" | tr -d ' ')
  loss=$(awk -v sent="$count" -v recv="$received" 'BEGIN{printf "%.2f", (sent-recv)*100/sent}')
  if [ "$received" -eq 0 ]; then
    printf '%s\t-\t-\t-\t-\t-\t0' "$loss"
    return
  fi
  avg=$(awk '{s+=$1} END{printf "%.2f", s/NR}' "$values")
  jitter=$(awk 'NR==1{p=$1;next}{d=$1-p;if(d<0)d=-d;s+=d;p=$1} END{if(NR<2)printf "0.00";else printf "%.2f",s/(NR-1)}' "$values")
  min=$(awk 'NR==1{m=$1}$1<m{m=$1}END{printf "%.2f",m}' "$values")
  max=$(awk 'NR==1{m=$1}$1>m{m=$1}END{printf "%.2f",m}' "$values")
  sorted="${values}.sorted"; sort -n "$values" > "$sorted"
  idx=$(( (received * 95 + 99) / 100 ))
  p95=$(awk -v n="$idx" 'NR==n{printf "%.2f",$1;exit}' "$sorted")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$loss" "$avg" "$jitter" "$p95" "$min" "$max" "$received"
}

write_skip_result() {
  local idx="$1" family="$2" prov="$3" isp="$4" host="$5" ipaddr="$6" reason="$7"
  printf '%s\t%s\t%s\t-\t-\t-\t-\t-\t-\t0\t%s\t%s\t%s\t%s\n' \
    "$family" "$prov" "$isp" "$reason" "$host" "$ipaddr" "$COUNT" > "$RESULT_DIR/$idx.tsv"
}

probe_node() {
  local idx="$1" family="$2" prov="$3" isp="$4" host="$5" ipaddr="$6" port="$7"
  local raw="$WORK_DIR/nping.$idx.log" values="$WORK_DIR/rtt.$idx" metrics status rc=0
  : > "$values"
  if [ "$ipaddr" = "-" ]; then
    write_skip_result "$idx" "$family" "$prov" "$isp" "$host" "$ipaddr" "无节点"
    return
  fi
  if [ "$family" = "6" ] && [ "$IPV6_OK" -ne 1 ]; then
    write_skip_result "$idx" "$family" "$prov" "$isp" "$host" "$ipaddr" "跳过"
    return
  fi
  if [ "$family" = "6" ]; then
    timeout "$((COUNT * 2 + 10))" nping -6 --tcp --flags syn -p "$port" -c "$COUNT" --delay "${DELAY_MS}ms" "$ipaddr" > "$raw" 2>&1 || rc=$?
  else
    timeout "$((COUNT * 2 + 10))" nping --tcp --flags syn -p "$port" -c "$COUNT" --delay "${DELAY_MS}ms" "$ipaddr" > "$raw" 2>&1 || rc=$?
  fi
  grep -oE 'rtt[=:][[:space:]]*[0-9]+([.][0-9]+)?ms' "$raw" 2>/dev/null | sed -E 's/.*[=:][[:space:]]*([0-9.]+)ms/\1/' > "$values" || true
  metrics=$(calc_metrics "$values" "$COUNT")
  status="正常"
  [ "$(wc -l < "$values")" -gt 0 ] || status="不可达"
  [ "$rc" -eq 124 ] && status="超时"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$family" "$prov" "$isp" "$metrics" "$status" "$host" "$ipaddr" "$COUNT" > "$RESULT_DIR/$idx.tsv"
}

run_tcp_probes() {
  local idx type family prov isp host ipaddr port target active=0
  while IFS=$'\t' read -r idx type family prov isp host ipaddr port target; do
    probe_node "$idx" "$family" "$prov" "$isp" "$host" "$ipaddr" "$port" &
    active=$((active + 1))
    if [ "$active" -ge "$PARALLEL" ]; then
      wait -n 2>/dev/null || true
      active=$((active - 1))
    fi
  done < "$PLAN_FILE"
  wait || true
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

run_speedtests() {
  local prov isp line ipaddr region bucket work updesc downdesc urc umeta uss drc dmeta dss
  local up ulat retrans ustatus down dlat dummy dstatus sc rc_color speed_color
  SPEED_CSV="$OUTPUT_DIR/single-thread-speed.csv"
  SPEED_EXECUTED=1
  printf '\xEF\xBB\xBF协议,省份,运营商,回程重传(%%),回程速度(Mbps),去程速度(Mbps),回程连接延迟(ms),去程连接延迟(ms),状态,IP\n' > "$SPEED_CSV"
  echo -e "${BOLD}${CYAN}真实端点单线程测速${NC}"
  echo -e "${DIM}仅显示具备 TOS 上传／下载能力的北京、上海、广东 IPv4；每方向最长 ${SPEED_SECONDS}s。${NC}"
  echo
  printf '  '; pad_left 12 'IPv4'; printf '  '; pad_left 10 '回程重传'; printf '  '; pad_left 12 '回程速度'; printf '  '; pad_left 12 '去程速度'; printf '  '; pad_left 10 '回程延迟'; printf '  '; pad_left 10 '去程延迟'; printf '\n'
  for prov in 北京 上海 广东; do
    selected_province "$prov" || continue
    for isp in 电信 联通 移动; do
      line=$(awk -F '\t' -v p="$prov" -v i="$isp" '$1=="tos" && $2=="4" && $3==p && $4==i {print;exit}' "$NODE_FILE")
      if [ -z "$line" ]; then
        printf 'IPv4,%s,%s,N/A,N/A,N/A,N/A,N/A,无真实端点,-\n' "$prov" "$isp" >> "$SPEED_CSV"
        continue
      fi
      ipaddr=$(printf '%s\n' "$line" | awk -F '\t' '{print $6}')
      region=$(tos_region "$prov"); bucket=$(tos_bucket_host "$region")
      work="$WORK_DIR/speed-${prov}-${isp}"
      IFS='|' read -r urc umeta uss <<<"$(curl_probe upload "$bucket" "$ipaddr" "$work")"
      IFS='|' read -r up ulat retrans ustatus <<<"$(parse_curl_metric upload "$urc" "$umeta" "$uss")"
      IFS='|' read -r drc dmeta dss <<<"$(curl_probe download "$bucket" "$ipaddr" "$work")"
      IFS='|' read -r down dlat dummy dstatus <<<"$(parse_curl_metric download "$drc" "$dmeta" "$dss")"
      sc="OK"; [ "$ustatus" = "OK" ] && [ "$dstatus" = "OK" ] || sc="部分失败"
      printf 'IPv4,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$prov" "$isp" "$retrans" "$up" "$down" "$ulat" "$dlat" "$sc" "$ipaddr" >> "$SPEED_CSV"
      printf '  '; printf '%b' "$CYAN"; pad_left 12 "$prov$isp"; printf '%b' "$NC"
      rc_color=$(loss_color "$retrans"); printf '  '; printf '%b' "$rc_color"; if [ "$retrans" = "-" ]; then pad_left 10 '-'; else pad_left 10 "${retrans}%"; fi; printf '%b' "$NC"
      speed_color="$GREEN"; [ "$up" = "failed" ] && speed_color="$RED"; printf '  '; printf '%b' "$speed_color"; pad_left 12 "$(metric_text "$up" 'Mbps')"; printf '%b' "$NC"
      speed_color="$GREEN"; [ "$down" = "failed" ] && speed_color="$RED"; printf '  '; printf '%b' "$speed_color"; pad_left 12 "$(metric_text "$down" 'Mbps')"; printf '%b' "$NC"
      printf '  '; pad_left 10 "$(metric_text "$ulat" 'ms')"; printf '  '; pad_left 10 "$(metric_text "$dlat" 'ms')"; printf '\n'
    done
    echo
  done
}

write_summary() {
  local report="$OUTPUT_DIR/README.txt" total normal skipped unreachable
  total=$(find "$RESULT_DIR" -name '*.tsv' -type f | wc -l | tr -d ' ')
  normal=$(awk -F '\t' '$11=="正常"{n++}END{print n+0}' "$RESULT_DIR"/*.tsv)
  skipped=$(awk -F '\t' '$11=="跳过"{n++}END{print n+0}' "$RESULT_DIR"/*.tsv)
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
    echo "  tcp-quality.csv"
    [ "$SPEED_EXECUTED" -eq 1 ] && echo "  single-thread-speed.csv"
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
  load_nodes
  prepare_probe_plan
  [ "$SELF_TEST" -eq 0 ] || { self_test; exit 0; }
  need_root
  install_dependencies
  IPV6_OK=0; ipv6_route_available && IPV6_OK=1

  echo -e "${BOLD}${CYAN}============================================================${NC}"
  echo -e "${BOLD} $SCRIPT_NAME V$VERSION${NC}"
  echo " 五省三网双栈 TCP 丢包／延迟／抖动／P95"
  echo " 不上传报告／不采集公网 IP"
  echo -e "${BOLD}${CYAN}============================================================${NC}"
  echo "报告时间：$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S CST（北京时间）')"
  echo "节点来源：$NODE_SOURCE"
  echo "测试范围：$SELECTED_PROVINCES"
  echo "IPv6 状态：$([ "$IPV6_OK" -eq 1 ] && echo 可用 || echo 无可用默认路由，将自动跳过)"
  echo
  echo -e "${DIM}正在探测 $(wc -l < "$PLAN_FILE") 个节点，请稍候……${NC}"
  run_tcp_probes
  echo
  show_tcp_results
  if [ "$RUN_SPEED" -eq 1 ]; then
    if [ "$ONLY_FAMILY" = "6" ]; then
      echo -e "${YELLOW}[!] 已选择仅 IPv6；当前没有可验证的三网 IPv6 吞吐端点，跳过单线程速度。${NC}"
    else
      run_speedtests
    fi
  fi
  write_summary
  echo -e "${DIM}注：吞吐速度只对真实上传／下载端点输出；N/A 不代表线路故障。${NC}"
  echo -e "${GREEN}结果已保存：$OUTPUT_DIR${NC}"
}

main "$@"
