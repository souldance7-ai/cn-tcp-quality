# CN TCP Quality

面向中国大陆线路的五省三网双栈 TCP 质量检测脚本。

## 覆盖范围

- 北京、上海、广东、安徽、江苏
- 中国电信、中国联通、中国移动
- IPv4 与 IPv6，共 30 个 TCP 探测组合
- 丢包率、平均延迟、相邻样本抖动、P95、最低／最高延迟
- 标准模式每节点 30 个独立样本；检测到部分丢包时自动补测至 60 个样本，丢包率精度由 3.33% 提升至 1.67%
- 本机无 IPv6 默认路由时自动跳过 IPv6，不使用 IPv4 结果代替
- 五省三网 IPv4／IPv6 共 30 组单线程上下行测速尝试
- 北京／上海／广东 IPv4 优先使用真实 TOS 端点；其余组合先按省会坐标＋运营商＋CN 国别动态选择测速端点，再回退静态候选
- TOS 主端点失败时自动轮询同省同运营商备用 IP，再回退双引擎测速
- TCP 探测和单线程测速均显示动态渐层进度条、百分比、完成数／总数及当前线路
- 运行后先显示内建金色 `CN TCP` 开场画面，再进入节点获取和测试，不依赖额外字体工具
- 每个 TCP 样本独立随机来源端口与 sequence；IPv6 普通发包失败时自动尝试网卡／来源地址／下一跳 MAC 二层回退

测速脚本会为 30 个组合逐项发起测试，并绑定本机对应的 IPv4 或 IPv6 源地址。动态测速使用省会坐标和 `China Telecom`、`China Unicom`、`China Mobile` 关键词选取附近的对应运营商节点；若候选端点离线或不支持该 IP 族，会在该行明确显示原因，不用 IPv4 冒充 IPv6，也不生成假 Mbps。任一方向低于 0.1 Mbps 时不会误标为 `OK`。

## 一键运行

完整综合体验命令：

```bash
bash <(curl -fsSL --retry 3 "https://raw.githubusercontent.com/souldance7-ai/cn-tcp-quality/main/cn-tcp-quality.sh") --speed
```

只测双栈 TCP 品质，不进行大流量测速：

```bash
bash <(curl -fsSL --retry 3 "https://raw.githubusercontent.com/souldance7-ai/cn-tcp-quality/main/cn-tcp-quality.sh")
```

快速测试：

```bash
bash <(curl -fsSL --retry 3 "https://raw.githubusercontent.com/souldance7-ai/cn-tcp-quality/main/cn-tcp-quality.sh") --quick --speed
```

## 参数

```text
--speed             追加五省三网 IPv4／IPv6 单线程上下行测速
--quick             每节点 10 包，测速使用节流模式
-c, --count N       每个节点发包数，默认 30
-p, --parallel N    并行节点数，默认 6
--province CODE     仅测指定省份，可重复：bj/sh/gd/ah/js
-4, --ipv4          仅测 IPv4
-6, --ipv6          仅测 IPv6
--output DIR        指定结果目录
--no-color          关闭终端颜色
```

示例：

```bash
# 只测安徽、江苏双栈
bash cn-tcp-quality.sh --province ah --province js

# 只测五省 IPv6
bash cn-tcp-quality.sh -6

# 完整测速并增加样本数
bash cn-tcp-quality.sh --speed --count 30
```

## 输出文件

- `tcp-quality.csv`：五省三网双栈 TCP 指标
- `single-thread-speed.csv`：五省三网双栈单线程吞吐指标，使用 `--speed` 时生成
- `README.txt`：本次测试摘要

CSV 使用 UTF-8 BOM，可直接用 Excel 打开。

## 运行进度

交互式终端会持续刷新单行进度，不会长时间只显示“请稍候”：

```text
TCP 探测     [###############---------------]  50%  15/30  当前：IPv4 江苏移动
单线程测速   [########----------------------]  26%   8/30  当前：IPv4 广东联通
```

彩色终端使用红→黄→绿动态渐层；`--no-color` 时改用纯文本进度条。重定向到日志文件时默认不输出动态进度，可设置 `CN_TCP_PROGRESS=always` 强制保留。

## 数据口径

- TCP 主表使用 `nping` 发送 TCP SYN，并从匹配响应中提取 RTT。
- 每个 TCP SYN 样本独立执行并随机来源端口与 sequence，避免 CDN 对重复四元组限速造成固定高丢包。
- 标准模式先发送 30 个样本；若结果为部分丢包（并非 0% 或 100%），自动继续至 60 个样本。`--quick` 或显式 `--count N` 时严格采用指定数量。
- 丢包率 = 未收到匹配 TCP 响应的样本数 ÷ 总发送数。
- 抖动 = 相邻成功 RTT 样本绝对差的平均值。
- P95 = 成功 RTT 样本的第 95 百分位。
- 回程速度 = 测试机向中国大陆端点上传的单线程速度。
- 去程速度 = 测试机从中国大陆端点下载的单线程速度。
- 回程重传只统计测试机发送连接可观察到的 TCP 重传；无法获得连接级数据时显示 `-`。

## 流量提醒

默认不执行吞吐测速。`--speed` 会对五省三网 IPv4／IPv6 共 30 个组合逐项执行单线程下载与上传。北上广 IPv4 的 TOS 标准模式每方向最多 256MiB、快速模式每方向最多 64MiB；其余组合由单线程测速核心控制流量。请确认 VPS 流量配额后使用。

## 节点来源与第三方说明

脚本优先读取 TcpQuality 对外提供的动态 TCP 探测节点接口，并带有 2026-08-28 的五省三网回退快照。单线程测速优先使用 showwin/speedtest-go（MIT），下载后校验官方 SHA-256；其官方 `--location`、`--search`、`--filter-cc` 与 `--source` 参数用于动态选点和绑定 IP 族。失败时回退 sivel/speedtest-cli（Apache-2.0），两者均强制单连接。节点域名、IP、Zstatic CDN、火山引擎 TOS 与第三方测速服务均属于各自权利人，不包含在本项目 MIT 授权范围内，也不代表相关服务方为本项目背书。

本项目不上传测试报告、不采集公网 IP、不参与排行榜。

## 开源许可

本项目自行编写的脚本代码采用 MIT License。第三方节点、服务与数据不包含在该授权中。
