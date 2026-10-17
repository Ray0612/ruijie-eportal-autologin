---
name: ruijie-eportal-autologin
description: >
  在 OpenWrt 类固件（或任何有 curl+sed 的嵌入式设备）上，为「锐捷 ePortal 网页认证」
  构建并部署一套纯 Shell 的自动登录守护进程。适用于这样的场景：路由器不会弹网页认证，
  需要它自己完成认证、并在掉线后自动重连。本技能包含完整的发现流程、三大已知陷阱、
  部署步骤与验证方法。
version: 1.0.0
license: MIT
---

# 技能：锐捷 ePortal 路由器端自动认证

你正在帮助用户在一台**路由器或其它嵌入式设备**上，实现「自动登录锐捷 ePortal 网页认证」。

---

## 0. 先读这一段：三条铁律

在动手之前，请把这三条记住。它们来自真实的踩坑，违反任何一条都会导致失败或事故。

### 铁律 1：必须先抓一次真实成功的请求

**不要凭经验或网上教程拼参数。** 门户的报错信息高度误导
（例如参数格式错误会报成 `设备未注册`）。

**正确顺序**：
```
先抓包 → 看清真实请求 → 再写脚本
```

绝不能反过来（先写脚本再猜为什么失败）。

### 铁律 2：轮询间隔必须 ≥ 120 秒，建议 300 秒

**秒级轮询会把小路由器压到卡死 → 硬件看门狗静默复位**
（症状：每隔几分钟重启一次，日志里没有任何关机过程）。

如果你的方案需要秒级轮询，**停下来重新设计**。

### 铁律 3：绝不把凭据写进任何会被提交的文件

账号、密码、抓包令牌、真实门户 IP、设备 MAC —— **全部只能出现在本地配置文件里**，
并且配置文件必须在 `.gitignore` 中。

---

## 1. 前置条件检查

在开始之前，依次确认：

### 1.1 设备可访问

```bash
# 能否 SSH / Telnet 进去？
ssh <user>@<router-ip> "echo ok"
```

**如果路由器是小米/Redmi 的官方固件，SSH 可能是关闭的。**
需要先用 [XMiR-Patcher](https://github.com/openwrt-xiaomi/xmir-patcher) 开启（见 `docs/09`）。

> ⚠️ 刷机/打补丁有风险，会失去保修，操作不当可能变砖。
> **务必先向用户确认，并提醒他备份。**

### 1.2 有 curl

```bash
ssh <user>@<router-ip> "command -v curl && curl --version | head -1"
```

没有的话：
```bash
opkg update && opkg install curl
```

### 1.3 确认持久分区

```bash
ssh <user>@<router-ip> "mount | grep -E 'storage|data|jffs|overlay'"
```

常见：`/etc/storage`、`/data`、`/jffs`、`/overlay`。
**脚本和配置必须放在持久分区**，否则重启即失。

### 1.4 确认 WAN 接口名

```bash
ssh <user>@<router-ip> "ip route | grep default; ip -4 addr"
```

记下默认路由走的接口名（如 `eth0` / `eth3` / `eth4` / `wan`）。

---

## 2. 发现阶段：抓一次真实请求

**这是全流程最关键的一步。不要跳过。**

### 2.1 让设备处于"未认证"状态

```bash
# 可选：如果知道门户的下线接口，可以先主动下线
curl -s -X POST -d "userId=<url-encoded-account>" \
  "http://<portal>/eportal/InterFace.do?method=logout"
```

或者让用户手动在浏览器里点"下线"。

### 2.2 用本项目的抓包代理

```bash
# 在用户的电脑上
python3 tools/capture-proxy.py
# 然后用带代理的浏览器登录
chrome --proxy-server="127.0.0.1:8899" --user-data-dir=/tmp/capture
```

Windows 用户直接双击 `tools/capture-login.bat`。

### 2.3 从抓包结果里提取这四样东西

拿到 `captured-requests.txt` 后，定位 `POST ... method=login` 那一段，提取：

| 要提取的 | 用在哪里 | 说明 |
|---|---|---|
| **`queryString` 的值** | 登录请求 | ⭐ 最重要。必须是**整串令牌**，不是 IP |
| **`password` 的值** | 登录请求 | 判断是明文还是 RSA |
| **`passwordEncrypt`** | 登录请求 | `false` / `true` |
| **`Host` 请求头** | 请求头 | 确认大小写 |

### 2.4 关键判断：`queryString` 长什么样

**✅ 正确形态**（一整串令牌）：
```
wlanuserip=a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6&wlanacname=0123456789abcdef&
ssid=fedcba9876543210&nasip=abcdef0123456789abcdef0123456789&
mac=00112233445566778899aabbccddeeff&t=wireless-v2
```

**❌ 错误形态**（只有 IP）：
```
wlanuserip=10.0.0.100
```

**如果你的抓包里是错误形态**，说明：
- 要么抓包时机不对（当时设备已在线）
- 要么门户版本较老，真的用 IP

**判断方法**：`wlanuserip` 的值是 32 位十六进制 ⇒ 是令牌；是点分十进制 ⇒ 是 IP。

### 2.5 关键判断：密码格式

```
passwordEncrypt = false  ⇒  发【明文】密码
passwordEncrypt = true   ⇒  发 RSA 加密后的字符串（且要先反转）
```

**⚠️ 如果 `passwordEncrypt = true`，本项目的纯 shell 实现不适用** ——
你需要额外的 RSA 能力。请停下来告知用户，让他选择：
1. 把认证放到有 Python 的机器上做
2. 在路由器上安装 openssl 并用无填充模式

---

## 3. 构建阶段

### 3.1 生成配置

```bash
# 在路由器上
mkdir -p /etc/storage/campus
cat > /etc/storage/campus/campus-login.conf <<EOF
PORTAL_IP="<门户IP>"
ACCOUNT="<账号>"
PASSWORD="<密码>"
WAN_IF="<WAN接口>"
INTERVAL=300
EOF
chmod 600 /etc/storage/campus/campus-login.conf
```

### 3.2 部署脚本

```bash
# 从本地推到路由器（用 stdin 方式，避开引号和换行符问题）
cat router/campus-login.sh | ssh <user>@<router-ip> "cat > /etc/storage/campus/campus-login.sh"
cat router/start.sh        | ssh <user>@<router-ip> "cat > /etc/storage/campus/start.sh"
ssh <user>@<router-ip> "chmod +x /etc/storage/campus/*.sh"
```

### 3.3 如果抓包得到的格式和脚本默认的不一致

按以下情况修改 `campus-login.sh` 的 `do_login()`：

| 情况 | 怎么改 |
|---|---|
| `queryString` 需要带额外字段 | 脚本已经整段照抓，通常不用改 |
| 账号需要前缀 | 在 `ACCOUNT` 里直接写完整值 |
| 账号需要额外后缀 | 同上 |
| `passwordEncrypt=true` | ⚠️ 停止，见 2.5 |
| 需要 `service` 字段 | 在 `--data-raw` 里补 `service=<值>` |

---

## 4. 验证阶段（必做）

### 4.1 单次手工验证（先别急着上守护进程）

```bash
# 在路由器上，用抓到的真实参数手工跑一次
QS='<抓到的完整 queryString，双重编码后>'
UID='<账号，双重编码后>'
curl -s -X POST \
  -H "Host: <门户IP>" \
  -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
  --data-raw "userId=$UID&password=<密码>&service=&queryString=$QS&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=false" \
  "http://<门户IP>/eportal/InterFace.do?method=login"
```

**期望返回**：
```json
{"userIndex":"...","result":"success","message":""}
```

**如果返回 `设备未注册`** ⇒ 回到 2.4，你的 `queryString` 格式一定不对。

### 4.2 端到端验证（掉线自愈）

```bash
# 1) 启动守护进程
/etc/storage/campus/start.sh
sleep 3
pgrep -f campus-login.sh            # 应该有 PID

# 2) 主动踢下线
curl -s -X POST -d "userId=<编码后账号>" \
  "http://<门户IP>/eportal/InterFace.do?method=logout"

# 3) 等一个轮询周期（INTERVAL 秒），然后检查
curl -s -o /dev/null -w '%{http_code}\n' \
  http://connectivitycheck.platform.hicloud.com/generate_204
# 期望 204

# 4) 看日志
tail -10 /tmp/campus-login.log
# 期望看到：
#   offline -> authenticate
#   LOGIN OK
#   verified online after login
```

### 4.3 稳定性验证（至少观察 20 分钟）

```bash
# 记录 boot_id，观察它会不会变（变了 = 重启了）
cat /proc/sys/kernel/random/boot_id
cat /proc/uptime

# 如果没装诊断脚本，先装：
echo '*/1 * * * * /etc/storage/diag/reboot-watch.sh >/dev/null 2>&1' >> /etc/crontabs/root
/etc/init.d/cron restart

# 20 分钟后再看
tail -20 /etc/storage/diag/reboots.log
```

**如果 boot_id 变了** ⇒ 设备重启了 ⇒ **立即把 `INTERVAL` 调大**（见铁律 2）。

---

## 5. 故障决策树

按现象快速定位：

```
症状：返回 "设备未注册"
  ├─ 你的 queryString 是 "wlanuserip=<IP>" 吗？
  │    └─ 是 ⇒ ⭐ 改：从门户拦截页整段抓（docs/02）
  ├─ 你的 wlanuserip 值被截断了（比 32 位短）？
  │    └─ 是 ⇒ ⭐ 你的提取正则只认数字和点 ⇒ 改（docs/02）
  └─ 参数看起来完全正确？
       └─ 校园侧的"设备注册状态"可能失效
            ⇒ 让用户在浏览器里手工认证一次，再试

症状：返回 "用户名不能为空"
  └─ 请求体没拼对 ⇒ 用 curl -v 看实际发出的 body

症状：返回 "用户名或密码错误"
  ├─ passwordEncrypt 与 password 格式不匹配 ⇒ 重新确认（docs/03）
  └─ 账号需要后缀/前缀 ⇒ 看 pageInfo 的 prefixName/prefixValue

症状：响应里出现非空的 validCodeUrl
  └─ ⚠️ 门户开了图形验证码（通常是失败次数过多触发）
       ⇒ 停手 10~30 分钟
       ⇒ 纯自动方案基本走不通，告知用户

症状：TCP 直接被断，没有 HTTP 响应
  └─ Host 请求头是小写 ⇒ 改成大写 "Host:"

症状：设备每隔几分钟重启，日志无关机过程
  └─ ⭐ 轮询太频繁 ⇒ INTERVAL 改到 300（docs/04）

症状：脚本起来了但立刻退出
  ├─ 行尾是 CRLF ⇒ dos2unix
  └─ 有中文注释导致乱码 ⇒ 改成纯 ASCII

症状：改了脚本但没生效
  └─ 忘了重启守护进程 ⇒ kill 旧进程 + 重新 start.sh
```

---

## 6. 交付前自查清单

```
□ queryString 是从抓包整段拿的（不是自己拼的）
□ queryString 里 wlanuserip 的值是 32 位十六进制（不是 IP）
□ userId / queryString 做了【双重】URL 编码
□ Host 首字母大写
□ passwordEncrypt 是从 pageInfo 读的
□ INTERVAL ≥ 120（建议 300）
□ 脚本是纯 ASCII + LF 行尾
□ 脚本和配置在【持久分区】
□ cron 里加了 start.sh（每分钟兜底）
□ 配置文件权限 600
□ 单次手工登录已验证成功
□ 端到端掉线自愈已验证
□ 观察 20 分钟无异常重启
□ 没有任何凭据进入版本控制
```

---

## 7. 与用户沟通的要点

**请主动告知用户这些**：

1. **学校政策**：让用户确认学校是否允许此类自动化行为
2. **风险**：刷机/打补丁可能失去保修
3. **局限**：如果学校开了图形验证码，纯自动方案走不通
4. **兜底**：如果自动登录失败，用户仍可在浏览器里手工认证一次
5. **代价**：认证掉线后最多 `INTERVAL` 秒（默认 5 分钟）才恢复

**不要在用户不知情的情况下**：
- 修改路由器的网络配置
- 重启路由器
- 关闭任何服务

**任何会导致断网的操作，先征得同意。**

---

## 8. 参考资料

本技能对应的完整文档在仓库 `docs/` 目录：

| 文档 | 内容 |
|---|---|
| `docs/01-认证流程详解.md` | 完整端点表、请求格式、userIndex 结构 |
| `docs/02-queryString令牌陷阱.md` | ⭐ 陷阱 1（最常见的失败原因）|
| `docs/03-passwordEncrypt语义.md` | ⭐ 陷阱 2 |
| `docs/04-嵌入式设备轮询陷阱.md` | ⭐ 陷阱 3 + 诊断方法 |
| `docs/05-在线判定与ICMP陷阱.md` | 为什么不能靠 ping |
| `docs/06-抓包方法.md` | 三种抓包方式 |
| `docs/07-故障排查.md` | 报错对照表 |
| `docs/08-门户前端源码分析.md` | 从门户 JS 反推的结论 |
| `docs/09-前置条件与固件准备.md` | SSH 开启、固件相关 |
