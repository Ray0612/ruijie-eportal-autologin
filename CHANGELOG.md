# 更新日志

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

---

## [1.0.0] — 2026-10-16

首个可用版本。来自一次真实的、**改了 6 个版本才成功**的排查过程。

### 新增

**核心实现**
- `router/campus-login.sh` —— 纯 shell 自动认证守护进程
  - 零流量前置判断（纯读 `/sys` 与 `/proc`）
  - 在线判定：`HTTP 204 + 空响应体`
  - 从门户拦截页整段抓取 `queryString` 令牌
  - 双重 URL 编码（`enc2()`）
  - 明文密码支持（对应 `passwordEncrypt=false`）
  - 300 秒轮询间隔 + 在线时静默
- `router/start.sh` —— 看门狗启动器（解决 busybox 无 `setsid`/`nohup`、cron 无 `@reboot`）
- `router/install.sh` —— 一键安装 + 自动校验 ASCII/LF/语法
- `router/diag/reboot-watch.sh` —— 极简重启诊断（`boot_id` 计数 + 每分钟心跳）

**工具**
- `tools/capture-proxy.py` —— 一键抓包代理（明文 HTTP，无需安装证书）
- `tools/capture-login.bat` —— Windows 双击启动器
- `tools/curl2router.py` —— 把浏览器的 `Copy as cURL` 直接转成路由器脚本

**文档**
- `docs/01-认证流程详解.md` —— 完整端点表 + 请求格式 + `userIndex` 结构
- `docs/02-queryString令牌陷阱.md` —— ⭐ 坑 1
- `docs/03-passwordEncrypt语义.md` —— ⭐ 坑 2
- `docs/04-嵌入式设备轮询陷阱.md` —— ⭐ 坑 3（含可复用的诊断方法）
- `docs/05-在线判定与ICMP陷阱.md`
- `docs/06-抓包方法.md`
- `docs/07-故障排查.md`
- `docs/08-门户前端源码分析.md` —— 从门户自己的 JS 反推出的 5 条结论
- `docs/09-前置条件与固件准备.md` —— SSH 怎么开、环境怎么验、以及把认证放到别的设备上的替代方案
- `skills/ruijie-eportal-autologin/SKILL.md` —— 🤖 给 AI Agent 用的构建指南
  （含三条铁律、发现流程、故障决策树、交付自查清单）
  （**只引用必要代码片段，不包含厂商原始文件**）

---

### 这篇记录的重点：三个坑

#### 坑 1：`queryString` 是不透明令牌，不是 IP

老写法 `queryString=wlanuserip%253D<真实IP>` 现在会失败。
门户返回的 `wlanuserip` 是 **32 位十六进制令牌**，而且必须连带
`wlanacname` / `ssid` / `nasip` / `mac` / `t` 一起发。

**踩过的两种错法**：
```
错法 A：正则按"IP 地址"写（只认数字和点）
        ⇒ 遇到令牌里的字母就截断 ⇒ 提取出垃圾 ⇒ 失败
错法 B：提取不到就兜底用 WAN 接口真实 IP
        ⇒ 门户早已不认真实 IP ⇒ 失败
```

**✅ 正确做法**：从门户拦截页**整段抓取**，不要自己拼。

#### 坑 2：`passwordEncrypt=false` 表示"服务器要明文"

不是"不用管密码"。两个取值：
- `false` ⇒ 服务器期望**明文**
- `true` ⇒ 服务器期望 **RSA**（且要先做字符串反转）

**⇒ 好消息**：`false` 时路由器端**完全不需要 RSA**，`curl` + `sed` 就够。

#### 坑 3：秒级轮询会压垮嵌入式设备

```
INTERVAL=30  ⇒ 1440 次/小时的 HTTP 探测
             ⇒ 路由器卡死 ⇒ 硬件看门狗静默复位
             ⇒ 症状：每 6.5 分钟重启一次，日志里没有任何关机过程
```

**⇒ 修复**：间隔改到 **300 秒** + 零流量前置判断 + 在线时不写日志。

---

### 已知限制

- **未在开启图形验证码的校园网上验证过**。
  如果 `pageInfo` 返回的 `validCodeUrl` 非空，纯自动方案基本走不通。
- **`passwordEncrypt=true`（RSA）分支未实现**。
  当前版本只覆盖 `false`（明文）的情况。如果你是 `true`，需要自行补 RSA 逻辑
  （见 `docs/03` 第 3.6 节的建议）。
- **"设备注册状态"是校园侧变量**。
  个别情况下参数完全正确也会被拒，需要在浏览器里手工认证一次重新激活。
  这一点没能做隔离实验，属于**观察到的现象**，不是严格结论。
- **只在一种固件上实测过**（OpenWrt 类、IPQ 系列 SoC、busybox ash）。
  其它固件的持久分区路径、cron 特性可能不同。

---

### 致谢

调研阶段参考了这些同厂商的开源实现（均已在 README 中列出）：

- [LFWQSP2641/scu_net_auto_login](https://github.com/lfwqsp2641/scu_net_auto_login)
- [Redlnn/Ruijie-ePorta-Tool](https://github.com/Redlnn/Ruijie-ePorta-Tool)
- [evin546/SCUNETAssistant](https://github.com/evin546/SCUNETAssistant)
- [Aurorp1g/Auto_Connect](https://github.com/Aurorp1g/Auto_Connect)
