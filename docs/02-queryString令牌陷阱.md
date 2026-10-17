# 二、⭐ 坑 1：`queryString` 是**不透明令牌**，不是 IP

> 这是本项目**最核心的一篇**。如果你正在被
> `设备未注册,请在ePortal上添加认证设备` 困扰，先看这里。

---

## 2.1 老教程 vs 现实

### 老教程（很多仍被广泛引用）

```sh
# ❌ 这样写现在会失败
queryString=wlanuserip%253D<你的真实IP>
```

背后的假设是：`wlanuserip` 这个字段的值 = 你的 IP 地址。

### 现实

门户在你的设备未认证时，会把 HTTP 请求**劫持**，返回这样一个页面：

```html
<script>top.self.location.href='http://<门户IP>/eportal/index.jsp?
  wlanuserip=a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6&
  wlanacname=0123456789abcdef&
  ssid=fedcba9876543210&
  nasip=abcdef0123456789abcdef0123456789&
  mac=00112233445566778899aabbccddeeff&
  t=wireless-v2&
  url=deadbeefdeadbeefdeadbeefdeadbeef'</script>
```

**关键观察**：

| 字段 | 值的样子 | 说明 |
|---|---|---|
| `wlanuserip` | `a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6` | ⭐ **32 位十六进制，不是 IP！** |
| `wlanacname` | `0123456789abcdef` | AC 名称令牌 |
| `ssid` | `fedcba9876543210` | SSID 令牌 |
| `nasip` | `abcdef0123456789abcdef0123456789` | NAS IP 令牌 |
| `mac` | `00112233445566778899aabbccddeeff` | 客户端 MAC 令牌 |
| `t` | `wireless-v2` | 门户模板版本 |
| `url` | 一长串 hex | **你当时想访问的网址** |

**⇒ 这些都是一次性/连接相关的「不透明令牌」，不是明文信息。**

---

## 2.2 两种典型的错法（都真实踩过）

### 错法 A：正则按"IP 地址"写

```sh
# ❌ 这个正则只认【数字和点】
ip=$(printf '%s' "$page" | sed -n 's/.*wlanuserip=\([0-9][0-9.]*\).*/\1/p' | head -1)
```

**后果**：遇到令牌里的字母（`f` / `c` / `e` …）就停止匹配。

```
页面里是：  wlanuserip=a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6
正则提取到：a1b2                      ← 只有前 4 位！
```

然后拿着 `a1b2` 去登录 ⇒ 门户回：

```json
{"result":"fail","message":"设备未注册,请在ePortal上添加认证设备"}
```

### 错法 B：提取不到就"兜底"用真实 IP

```sh
# ❌ 匹配不上时，退而求其次用 WAN 接口的真实 IP
if [ -z "$ip" ]; then
    ip=$(ip -4 addr show "$WAN_IF" | awk '/inet /{print $2}' | cut -d/ -f1)
fi
# ⇒ queryString=wlanuserip%253D10.0.0.100     ← 门户早已不认真实 IP
```

**后果**：同样回 `设备未注册`。

---

## 2.3 ✅ 正确做法：整段抓下来，不要自己拼

```sh
get_query_string() {
    # 发一个会被拦截的请求，拿到门户的跳转页
    page=$(curl -s -m 15 "http://<探测地址>")

    # 从 JS 跳转里抽出 index.jsp? 之后、单引号之前的整段
    qs=$(printf '%s' "$page" | sed -n "s|.*index\.jsp?\([^'\"]*\).*|\1|p" | head -1)

    # 兜底：直接找 wlanuserip= 开头的那一段
    [ -z "$qs" ] && qs=$(printf '%s' "$page" |
        sed -n 's/.*\(wlanuserip=[^"'"'"' <>]*\).*/\1/p' | head -1)

    printf '%s' "$qs"
}
```

**要点**：

1. **不要过滤字符集** —— 令牌是任意十六进制，甚至可能是 base64
2. **不要只取 `wlanuserip`** —— 必须**整段**（含 `wlanacname`/`ssid`/`nasip`/`mac`/`t`）
3. **`url=` 那个令牌可以带上，也可以不带**（实测两种都成功）

---

## 2.4 `url=` 令牌要不要带？

它表示"你当时想访问的网址"。理论上是**一次性**的。

**实测结论（本案例）**：

| queryString 内容 | 结果 |
|---|---|
| 带 `url=` | ✅ 成功 |
| 不带 `url=` | ✅ 成功 |

**⇒ 带不带都行。** 但如果你遇到莫名其妙失败，**可以试试去掉它**。

---

## 2.5 双重编码：为什么必须做两次

门户前端 JS 是这么写的：

```js
var queryString = encodeURIComponent(encodeURIComponent(getQueryString()));
```

**⇒ 两次编码。** 所以在脚本里也要做两次：

```sh
_enc1() {
    sed -e 's/%/%25/g' -e 's/@/%40/g' -e 's/&/%26/g' -e 's/=/%3D/g' \
        -e 's/?/%3F/g' -e 's/+/%2B/g' -e 's/ /%20/g'
}
enc2() { printf '%s' "$1" | _enc1 | _enc1; }
```

### ⚠️ 顺序陷阱

**`%` 必须最先转义。** 否则会把「上一轮刚生成的 `%XX`」二次破坏。

```
正确：  &  → %26   （第一遍）  →  %2526  （第二遍）
错误：  先转 & 再转 %          →  %26 被破坏成 %2526? 不一定，看实现
```

**实践口诀：同一套 sed 跑两遍，每遍内部 `%` 排第一。**

---

## 2.6 验证你的编码是否正确

拿门户自己的 JS 结果对照：

```js
// 在浏览器控制台里执行
encodeURIComponent(encodeURIComponent(
  "wlanuserip=0123456789abcdef0123456789abcdef&wlanacname=x"
))
```

然后用同样的输入跑你的 `enc2()`，**两者必须逐字节一致**。

```sh
QS_RAW='wlanuserip=0123456789abcdef0123456789abcdef&wlanacname=x'
echo "期望: $(printf '%s' "$QS_RAW" | sed 's/%/%25/g; s/&/%26/g; s/=/%3D/g')"   # 单次
echo "实际: $(enc2 "$QS_RAW")"
```

---

## 2.7 为什么这个坑特别难查

```
① 字段名还叫 wlanuserip —— 天然让人以为它是 IP
② 门户的报错是「设备未注册,请在ePortal上添加认证设备」
   ⇒ 听起来是"学校没给你注册设备"，实际是"我解析不了你的请求"
③ 厂商官方文档对这句话的解释，全是「AC 与 ePortal 的配置问题」
   ⇒ 完全没有提到参数格式
④ 自助服务平台的「我的设备」列表里，可能真的能看到你的设备 MAC
   ⇒ 让人更坚信"设备已注册，是别的地方出问题"
```

**⇒ 结果：一路往"设备注册"方向查，越查越偏。**

**✅ 唯一可靠的破局方法：抓一次浏览器真实成功的请求，逐字段对照。**
见 [06-抓包方法.md](06-抓包方法.md)。

---

## 2.8 一句话总结

> **不要自己拼 `queryString`，把门户拦截页里的那段整串抓下来，双重编码，原样发回去。**
