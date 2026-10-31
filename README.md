# dsh-cookie-gc

自动清理 DSH 桌面版累计的 `dsh-auth-*` 登录 cookie，防止请求头超过 16KB 后登录报 `Web authentication failed`（HTTP 431）。

## 问题

DSH 桌面版每次启动让 Host 用随机端口（`--port 0`）。登录 cookie 的名字是：

```
dsh-auth- + base64url(sha256(authority))
```

`authority` 含端口，所以每次启动都是一个新名字。浏览器 Cookie 不区分端口，于是所有历史的 `dsh-auth-*` 都会随每个请求一起发出去。每条约 224 字节，约 72 条后请求头超过 Node 默认的 16384 字节上限，Host 直接 431。

## 机制

不碰磁盘上的 Cookies 库（DSH 运行时被 Chromium 独占锁着）。插件在 Host 的 `connection/request` waterfall 里，对每个已认证 HTTP 请求的响应追加删除指令：

- 从请求的 `Cookie` 头里取出所有 `dsh-auth-*` 名字；
- 用和 Host 相同的算法算出当前端口对应的那一个名字，保留；
- 其余全部返回 `Set-Cookie: <name>=; Max-Age=0; Path=/; HttpOnly; SameSite=Strict`。

常态是：启动 → 页面带着「上次的一条 + 本次新的一条」加载 → 第一批 API 请求把旧的那条删掉 → 之后只带一条。永远到不了 72。

## 安装

Windows，PowerShell，不需要管理员权限。

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

然后完全退出 DSH（托盘也要退）再重新打开。

脚本会：把插件复制到 `%USERPROFILE%\.dsh\addons\dsh-cookie-gc`，在 profile 的 `node_modules` 建目录 junction，并在 profile 的 `package.json` 里补 `dependencies` 与 `dsh.profile.bundles`；改之前自动备份，写失败自动还原。

卸载：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

## 验证

打开 `http://127.0.0.1:<当前端口>/_dsh-cookie-gc`，返回：

```json
{
  "host": "127.0.0.1:59767",
  "currentCounterpart": "dsh-auth-...",
  "authCookieCount": 2,
  "staleCount": 1,
  "estimateHeaderBytes": 456,
  "nodeHeaderLimit": 16384
}
```

日志：`%USERPROFILE%\.dsh\logs\dsh-cookie-gc.log`，每次清理一行 `auth=N cleared=M`。

## 限制

- **已经爆到 431 时它救不了。** 431 发生在 HTTP 解析层，请求进不了插件。先用 `INSTALL.md` 里的方法清一次，之后交给插件防复发。
- 单次响应最多删 24 条，超出的下一次请求继续删（避免响应头自己超过 16KB）。
- 只处理 `dsh-auth-` 前缀，不碰其他站点 cookie。
- 不读 cookie 值，只用名字判断。

## License

MIT
