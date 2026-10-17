# 三、⭐ 坑 2：`passwordEncrypt` 到底是什么

> 这个字段的名字极具误导性。它**不是**"要不要加密密码"的开关，
> 而是**「告诉服务器：我这次发的密码是什么格式」**。

---

## 3.1 字段从哪来

`POST <门户>/eportal/InterFace.do?method=pageInfo` 的返回里：

```json
{
  "passwordEncrypt": "false",
  "publicKeyExponent": "10001",
  "publicKeyModulus": "0123456789abcdef…（256 字符）"
}
```

---

## 3.2 两种取值分别表示什么

| `passwordEncrypt` 的值 | 你要发的 `password` 字段 | 服务器怎么处理 |
|---|---|---|
| **`false`** | ⭐ **明文密码**（如 `mypassword`）| 直接按明文校验 |
| `true` | **RSA 加密后的字符串** | 用私钥解密后校验 |

**⇒ 关键：这个值要**同时**出现在两处：**
1. 你决定 `password` 字段怎么填（明文 or RSA）
2. 请求体里的 `passwordEncrypt` 字段也发同样的值（告诉服务器你的选择）

---

## 3.3 前端源码是怎么实现"两个分支"的

锐捷门户的前端 `AuthInterFace.js` 里有这么一段：

```js
login: function(userId, password, service, queryString,
                 operatorPwd, operatorUserId, validcode, passwordEncrypt, callback) {

    var passwordEncrypt = encodeURIComponent(encodeURIComponent(
        document.getElementById("passwordEncrypt").value));

    if (passwordEncrypt && passwordEncrypt == "true") {
        // 分支 A：真 RSA
        password = encryptedString(key, password);
    } else {
        // 分支 B：反转 + RSA
        password = RSAUtils.encryptedString(key, password.split("").reverse().join(""));
        //                                             ↑↑↑ 注意这里：字符串反转
    }

    var content = "userId=" + userId + "&password=" + password + …;
    post(ePortalUrl + "login", content, callback);
}
```

**看起来**两个分支都调用了 RSA 加密函数。但实际运行时：

- **`passwordEncrypt != "true"` 时，`RSAUtils` 通常是未加载的**
  ⇒ 分支 B 会抛异常 / 走不到
  ⇒ **最终发出去的还是明文**
- 这也是为什么社区项目明确写着：
  > **"不建议将 `passwordEncrypt` 设置为 `false`，这会导致密码以明文方式传输"**
  > —— 反过来说，`false` **就是**明文传输

---

## 3.4 ⚠️ 但我们抓到的真实请求证明：`false` ⇒ 明文

从真实浏览器抓到的成功请求（`passwordEncrypt=false`）：

```
userId=YOUR_ACCOUNT
password=mypassword              ← ⭐ 就是明文！
queryString=wlanuserip%253D…
passwordEncrypt=false
```

**⇒ 与 `pageInfo` 返回的 `false` 完全一致。**

---

## 3.5 ✅ 对路由器端意味着什么（好消息）

**如果 `pageInfo` 返回 `false`，路由器端完全不需要 RSA。**

```
不需要 Python
不需要 openssl
不需要 Node.js
不需要任何大数运算库
```

**⇒ 一个 `curl` + 一段 `sed` 就够了。**

这对嵌入式设备是决定性的 —— 大部分路由器固件根本没有 Python，
而用 busybox 实现教科书的 1024 位 RSA 是不现实的。

---

## 3.6 ⚠️ 如果 `pageInfo` 返回 `true` 怎么办

那就要做 RSA 加密，且注意这是**教科书式 RSA（零填充）**，不是 PKCS#1：

```js
// 经典 security.js 的实现
this.chunkSize = 2 * biHighIndex(this.m);      // 1024 位密钥 => 126 字节
while (a.length % chunkSize != 0) a[i++] = 0;  // 纯零填充，无 PKCS#1 头
block.digits[j] = a[k++] + (a[k++] << 8);      // 小端 16 位一组
crypt = block ^ e mod m;                       // 教科书 RSA
text  = biToHex(crypt);                        // 每 16 位输出 4 个 hex
result = texts.join(" ");                      // 多块用空格分隔
```

**并且密码要先做 `split("").reverse().join("")` —— 字符串反转。**

可选实现路径：

| 方案 | 说明 |
|---|---|
| 路由器上有 `openssl` | 用 `pkeyutl -pkeyopt rsa_padding_mode:none`（**注意需要无填充模式**）|
| 没有 openssl | 把认证逻辑放到 PC/树莓派/旧手机上，用 Python 跑 |
| 纯 shell 硬算 | 可行但很痛苦（busybox 没有 `bc`/`dc`，要靠 `awk` 拼大数）|

**⇒ 大部分情况下，建议先用 `pageInfo` 确认，再决定架构。**

---

## 3.7 本项目中相关代码位置

```
router/campus-login.sh
  ├── 从 pageInfo 读取 passwordEncrypt（可选，仅做记录/校验）
  └── 默认按 false ⇒ 明文发送
```

> 如果你的学校是 `true`，请自行替换 `do_login()` 里的密码处理逻辑。

---

## 3.8 一句话总结

> **`passwordEncrypt=false` = 服务器要明文密码 = 路由器端可以做纯 shell 实现。**
> **但一定要先调 `pageInfo` 确认，不要照抄。**
