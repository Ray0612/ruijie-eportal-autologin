# 校园网自动认证 · 锐捷 ePortal 自动认证（路由器端 · 纯 Shell）

> 实现路由作为**终端**并且自动接入校园网，突破校园网接入终端数量
> 
> 让路由器在**断线后自动完成锐捷 ePortal 网页认证** —— 不需要 Python、不需要 RSA 库、
> 不需要 Node.js。一个 `curl` + 一段 `sed`，就能在 OpenWrt 类固件 / 嵌入式设备上跑起来。

> 如果你不愿意看枯燥的技术文档也可以直接把仓库给智能体，然后说"按 skills/ruijie-eportal-autologin/SKILL.md，帮我在这台路由器上部署校园网自动登录"


[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-busybox--compatible-blue.svg)](#兼容性)
[![Platform](https://img.shields.io/badge/Platform-OpenWrt%20%7C%20IPQ%20%7C%20MTK-lightgrey.svg)](#兼容性)

---

## 目录

- [为什么需要这个项目](#为什么需要这个项目)
- [⭐ 三个最容易踩的坑（本项目的核心价值）](#-三个最容易踩的坑本项目的核心价值)
- [快速开始](#快速开始)
- [工作原理](#工作原理)
- [关键结论速查](#关键结论速查)
- [目录结构](#目录结构)
- [兼容性](#兼容性)
- [故障排查](#故障排查)
- [免责声明](#免责声明)
- [License](#license)

---

## 为什么需要这个项目

锐捷 ePortal 的网页认证是**面向浏览器**设计的：你连上网络 → 打开任意网页 → 被劫持到认证页 → 输入账号密码。

但如果你想让**路由器**替你完成这件事（这样全寝室设备都能上网），就会遇到现实困难：

| 困难 | 说明 |
|---|---|
| 路由器固件不会弹认证页 | 它没有浏览器，也没有人点 |
| 路由器上没有 Python | 大部分嵌入式固件只有 busybox |
| 很多教程假设你有 RSA 库 | 但锐捷的密码加密方式**不一定需要 RSA**（见坑 2）|
| 认证会过期 | 断了要能自动重连，还得**不能把路由器搞挂**（见坑 3）|

这个仓库给出的是一套**在路由器上跑通了**的方案，以及一路上踩到的坑。

---

## ⭐ 三个最容易踩的坑（本项目的核心价值）

### 坑 1：`queryString` 是**不透明令牌**，不是 IP

这是最致命的一个。很多老教程（包括一些还在被广泛引用的）都是这么写的：

```sh
# ❌ 老格式 —— 现在会失败
queryString=wlanuserip%253D<你的真实IP>
```

**但门户早就改版了。** 现在它在拦截你的时候，会返回一个 JS 跳转页，里面带着**一整串不透明令牌**：

```html
<script>top.self.location.href='http://<门户IP>/eportal/index.jsp?
  wlanuserip=a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6&
  wlanacname=0123456789abcdef&
  ssid=fedcba9876543210&
  nasip=abcdef0123456789abcdef0123456789&
  mac=00112233445566778899aabbccddeeff&
  t=wireless-v2'</script>
```

**特征**：
- `wlanuserip` 的值是 **32 位十六进制**（像 MD5），**不是 IP**
- 光发 `wlanuserip` 不够，**必须连带 `wlanacname` / `ssid` / `nasip` / `mac` / `t` 全发**
- 整串还要做 **URL 双重编码**

**✅ 正确做法：不要自己拼，直接从门户的拦截页里把整段抓下来。**

```sh
page=$(curl -s "http://<探测地址>")
qs=$(printf '%s' "$page" | sed -n "s|.*index\.jsp?\([^'\"]*\).*|\1|p" | head -1)
```

> 📖 详细分析见 [docs/02-queryString令牌陷阱.md](docs/02-queryString令牌陷阱.md)

---

### 坑 2：`passwordEncrypt=false` **不是**"不用管密码"，而是"我要明文"

这个字段在 `pageInfo` 接口里返回，很容易被误解成"关掉密码加密"。

**它真实的含义是：告诉服务器「我这次发的密码是什么格式」。**

| `passwordEncrypt` | 服务器期望的 `password` 字段 |
|---|---|
| **`false`** | ⭐ **明文密码**（直接发明文）|
| `true` | RSA 加密（门户前端用 `RSAUtils.encryptedString`，且**要先做字符串反转**）|

**⇒ 这是个好消息**：如果 `pageInfo` 返回 `false`，**路由器端完全不需要 RSA** ——
`curl` + `sed` 就够了，不用装 Python、不用编译 openssl 绑定。

> ⚠️ 但也别想当然：**不同学校配置不同**。务必先调一次 `pageInfo` 看返回什么。

> 📖 详细分析见 [docs/03-passwordEncrypt语义.md](docs/03-passwordEncrypt语义.md)

---

### 坑 3：**秒级轮询会把嵌入式设备搞挂**

这个坑害我们花了一整天 —— 而且**它的症状极具误导性**。

**现象**：
```
路由器每隔约 6~7 分钟就重启一次
日志里没有任何关机过程（不是 reboot，是硬件看门狗静默复位）
SSH 密码刚输完就断线
```

**根因**：
```sh
# ❌ 定时器写成秒级
INTERVAL=30        # 每 30 秒发一次外网 HTTP 探测
                   # = 1440 次/小时
```

在一台 ~190MB 内存、几百个进程的嵌入式设备上，
**高频的小请求比低频的大请求危险得多**（每次 TCP 连接都要建 NAT 会话、进 conntrack；
再加上门户拦截页的解析），最终把系统压到卡死 ⇒ 硬件看门狗超时 ⇒ **静默复位，不写任何日志**。

**✅ 正确做法**：
```sh
INTERVAL=300                       # 分钟级，不是秒级

# 而且先做【零流量前置判断】，不满足就一个包都不发
link_ready() {
    st=$(cat "/sys/class/net/$WAN_IF/operstate" 2>/dev/null)
    [ "$st" = "up" ] || return 1
    grep -q "$WAN_IF" /proc/net/route 2>/dev/null || return 1
}
```

**⇒ 在线时的开销降到「每 5 分钟一对 ICMP 包」，几乎为零。**

> 📖 详细的排查方法（如何证明是它）见 [docs/04-嵌入式设备轮询陷阱.md](docs/04-嵌入式设备轮询陷阱.md)

---

## 快速开始

### 前提

1. 你的路由器设备能跑 shell（OpenWrt / busybox 类固件）
2. 有 `curl`（大部分 OpenWrt 固件自带；没有就 `opkg install curl`）
3. 你有 `ssh` 或 `telnet` 能进路由器

### 第一步：先手工抓一次真实请求（**强烈推荐**）

**不要跳过这一步。** 你学校的参数格式可能和本文不同，先确认再写脚本。

三种抓法，选一种：

| 方法 | 操作 |
|---|---|
| ⭐ **本项目自带的抓包代理** | 见 [docs/06-抓包方法.md](docs/06-抓包方法.md)，双击即用 |
| **保存全部 HAR** | 浏览器 F12 → Network → 列表里右键 → "Save all as HAR with content" |
| **Copy as cURL** | F12 → Network → 找到 `method=login` → 右键 → Copy as cURL (bash) |

**⚠️ 抓包时机**：要在**设备真的掉线时**抓，才能拿到"真正登录"那一次 POST。
在线时抓到的只是"重复登录"，参考价值有限。

### 第二步：填配置

复制配置模板并填入你自己的信息：

```bash
cp examples/campus-login.conf.example campus-login.conf
vi campus-login.conf
```

```ini
# 认证门户地址（不带 http://）
PORTAL_IP="10.0.0.1"

# 你的账号
ACCOUNT="YOUR_ACCOUNT"

# 你的密码
PASSWORD="YOUR_PASSWORD"

# WAN 接口名（用 `ip addr` 或 `ifconfig` 查）
WAN_IF="eth0"

# 探测间隔（秒）—— ⚠️ 不要低于 120，强烈建议 300
INTERVAL=300
```

### 第三步：部署

```bash
# 上传脚本（注意用 stdin 方式，可以彻底避开引号和换行符问题）
cat router/campus-login.sh | ssh root@192.168.1.1 "cat > /etc/storage/campus/campus-login.sh"

# 单独跑一次看看效果
ssh root@192.168.1.1 "sh /etc/storage/campus/campus-login.sh"
# （会一直循环，Ctrl+C 退出）
```

### 第四步：设开机自启

```bash
ssh root@192.168.1.1
mkdir -p /etc/storage/campus
# 上传 start.sh 后：
echo '* * * * * /etc/storage/campus/start.sh' >> /etc/crontabs/root
/etc/init.d/cron restart
/etc/storage/campus/start.sh
```

> ⚠️ 这里的 `/etc/storage` 是**持久分区**（不同固件路径不同，请先确认你的路由器把配置存在哪）。
> 常见位置：`/etc/storage`、`/data`、`/jffs`、`/overlay`。

---

## 工作原理

```
┌─────────────────────────────────────────────────────────────┐
│ 每 300 秒循环一次                                            │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ① 零流量前置判断（纯读 /sys 和 /proc，一个包都不发）         │
│     接口 up？默认路由在？                                     │
│        │ 不满足 → 判定离线 → 去登录                          │
│        │ 满足   ↓                                            │
│  ② HTTP 探测 generate_204                                    │
│        │                                                     │
│        ├─ 204 + 响应体为空  → 真在线 → 什么都不做 ✅          │
│        │                                                     │
│        └─ 200 + HTML 页面   → 被门户拦截 → 去登录            │
│                    │                                         │
│  ③ 从拦截页里抓整段令牌串                                     │
│  ④ 双重 URL 编码                                             │
│  ⑤ POST 登录（明文密码 + 大写 Host）                          │
│  ⑥ 5 秒后再探测一次确认                                       │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**⭐ 核心设计原则：在线时几乎不产生开销。**

---

## 关键结论速查

| 问题 | 结论 |
|---|---|
| `queryString` 怎么填？ | **从门户拦截页整段抓**，别自己拼 |
| `wlanuserip` 是什么？ | 32 位十六进制**令牌**，不是 IP |
| 密码要加密吗？ | 看 `pageInfo` 返回的 `passwordEncrypt`：`false`=明文，`true`=RSA |
| 需要 RSA 库吗？ | **`false` 时不需要** —— 纯 shell 就够 |
| 哪些字段要双重编码？ | `userId` / `queryString` / `service` / `passwordEncrypt` |
| `Host` 大小写要紧吗？ | **要紧**，部分实现必须首字母大写（`Host:`），小写会被断连 |
| 怎么判断"真的在线"？ | **HTTP `204` + 响应体为空**；只看状态码会误判 |
| 能靠 ping 判断在线吗？ | ⚠️ **不能**。有些网络未认证时也放行 ICMP，会导致永远不登录 |
| 探测间隔设多少？ | **≥ 120 秒，建议 300**。秒级会压垮嵌入式设备 |
| 脚本能用中文注释吗？ | ⚠️ 不能。busybox 无 locale，**必须纯 ASCII** |
| 脚本行尾？ | **LF**。CRLF 会让 `#!/bin/sh\r` 失效 |

---

## 目录结构

```
.
├── README.md                          ← 你在这里
├── LICENSE
├── .gitignore
├── docs/
│   ├── 01-认证流程详解.md              ← 完整端点表 + 请求格式
│   ├── 02-queryString令牌陷阱.md       ← ⭐ 坑 1
│   ├── 03-passwordEncrypt语义.md       ← ⭐ 坑 2
│   ├── 04-嵌入式设备轮询陷阱.md        ← ⭐ 坑 3（含诊断方法）
│   ├── 05-在线判定与ICMP陷阱.md
│   ├── 06-抓包方法.md                  ← 怎么拿到真实请求
│   ├── 07-故障排查.md                  ← 报错 → 原因 → 处理
│   ├── 08-门户前端源码分析.md          ← 从门户自己的 JS 里挖出来的结论
│   └── 09-前置条件与固件准备.md        ← SSH 怎么开、环境怎么验
│
├── skills/
│   └── ruijie-eportal-autologin/
│       └── SKILL.md                    ← 🤖 给 AI Agent 用的构建指南
├── router/
│   ├── campus-login.sh                ← 守护进程（纯 shell，ASCII）
│   ├── start.sh                       ← 看门狗启动器（cron 每分钟兜底）
│   └── install.sh                     ← 一键安装
├── tools/
│   ├── capture-proxy.py               ← 一键抓包代理（明文 HTTP，无需证书）
│   ├── capture-login.bat              ← Windows 双击启动器
│   └── curl2router.py                 ← 把浏览器 cURL 转成路由器脚本
└── examples/
    └── campus-login.conf.example
```

---

## 兼容性

**已在以下环境实测**：

| 项目 | 环境 |
|---|---|
| 固件 | OpenWrt 类固件（IPQ 系列 SoC，内核 4.4，busybox）|
| 内存 | ~190 MB |
| shell | busybox `ash` |
| curl | 自带 |

**理论上适用于**：
- 任何有 `curl` + `sed` 的 Linux / OpenWrt / DD-WRT / Merlin
- 任何使用锐捷 ePortal 网页认证的网络

**需要额外注意的**：
- ⚠️ 部分固件没有 `setsid` / `nohup`，后台化要用 `&` 或看门狗方式
- ⚠️ 部分固件的 cron **不支持 `@reboot`**，只能靠"每分钟检查一次"的兜底方案

---

## 故障排查

常见报错与处理，见 [docs/07-故障排查.md](docs/07-故障排查.md)。

**几个最典型的**：

| 报错 | 真实原因 | 处理 |
|---|---|---|
| `设备未注册,请在ePortal上添加认证设备` | ⭐ **90% 是 `queryString` 格式不对** | 改成从拦截页整段抓 |
| `用户名不能为空` | 请求体没拼对 / 为空 | 检查 `--data-raw` 和编码 |
| `用户名或密码错误` | 密码格式不符（该明文时发了 RSA，或反过来）| 核对 `pageInfo` 的 `passwordEncrypt` |
| 突然出现图形验证码 | 失败次数过多触发风控 | 停手，隔一段时间再试 |
| TCP 直接被断连 | `Host` 写成了小写 | 改成大写 |

---

## 免责声明

```
⚠️ 请在使用前确认：你的学校/单位是否允许此类自动化行为。

本项目：
  ✅ 只做一件事：用【你自己的账号】完成【你自己的】网页认证
  ❌ 不提供任何绕过、破解、伪造身份的功能
  ❌ 不涉及任何认证机制的对抗
  ❌ 不包含任何真实账号、密码、令牌或网络地址

作者不对使用本项目造成的任何后果承担责任。
请遵守你所在网络的使用规范和相关法律法规。
```

---

## 致谢

### 前置工具

- **[XMiR-Patcher](https://github.com/openwrt-xiaomi/xmir-patcher)** —— 为小米 / Redmi 官方固件开启 SSH 的成熟工具。
  本项目假设你已经能以 root 登录路由器；如果 SSH 还没开，先用它。
  **⚠️ 修改固件会失去保修，操作不当可能变砖，请自行评估风险后再决定。**
  详细说明见 [docs/09-前置条件与固件准备.md](docs/09-前置条件与固件准备.md)。

### 同厂商的开源实现（调研阶段参考）

- [LFWQSP2641/scu_net_auto_login](https://github.com/lfwqsp2641/scu_net_auto_login) —— 明确了 **RSA 零填充** 与 **`passwordEncrypt=false` = 明文**，以及 **`Host` 大小写陷阱**
- [Redlnn/Ruijie-ePorta-Tool](https://github.com/Redlnn/Ruijie-ePorta-Tool) —— 明确了**抓浏览器请求重放**是社区标准做法，以及验证码/封禁风险
- [evin546/SCUNETAssistant](https://github.com/evin546/SCUNETAssistant) —— 干净的 Python 实现参考
- [Aurorp1g/Auto_Connect](https://github.com/Aurorp1g/Auto_Connect) —— 带 GUI/托盘的重连工具

### 文档

- 锐捷官方文档对 `设备未注册` 等报错的说明（全部指向校园侧配置），
  帮助我们排除了"客户端参数之外"的可能性

---

## 🤖 用 AI Agent 一键构建

本仓库内置了一个 **Agent Skill**：可以**直接把整个项目交给智能体**，
让它按步骤完成环境检查、抓包分析、构建、部署与验证。

```
skills/ruijie-eportal-autologin/SKILL.md
```

**用法**：把仓库给智能体，然后说

> "按 `skills/ruijie-eportal-autologin/SKILL.md`，帮我在这台路由器上部署校园网自动登录"

**Skill 里包含**：

| 章节 | 内容 |
|---|---|
| 0. 三条铁律 | 抓包先行 / 轮询间隔 / 凭据管理 |
| 1. 前置条件 | 能否 SSH、有没有 curl、持久分区、WAN 接口名 |
| 2. 发现阶段 | 怎么抓、抓什么、**怎么判断 `queryString` 是否合法** |
| 3. 构建阶段 | 配置文件、部署命令、按抓包结果微调 |
| 4. 验证阶段 | 单次验证 → 端到端掉线自愈 → 稳定性观察 |
| 5. 故障决策树 | **按症状直接定位**（设备未注册 / 用户名不能为空 / 验证码 / 重启 / …）|
| 6. 交付自查 | 14 项检查清单 |
| 7. 沟通要点 | 必须主动告知用户的风险与局限 |

> ⚠️ Skill 里明确要求智能体：**任何会导致断网的操作，必须先征得用户同意。**

---

## License

[MIT](LICENSE)
