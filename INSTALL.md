# dsh-cookie-gc 安装说明（给朋友）

这个插件解决 DSH 桌面版的一个问题：每次启动端口都变，登录 cookie 越攒越多，约 72 条后请求头超过 Node 的 16KB 上限，登录报 `Web authentication failed`（HTTP 431）。

它会在每次启动后的第一批请求里，把「不是本次端口」的 `dsh-auth-*` cookie 删掉，只留当前那一条。

## 需要什么

- Windows + DSH 桌面版（DeepSeek Harness）
- PowerShell（系统自带）
- 不需要管理员权限

## 安装

1. 把压缩包解压到任意位置（比如桌面上的 `dsh-cookie-gc` 文件夹）。
2. 右键 `install.ps1` →「使用 PowerShell 运行」。
   或者在 PowerShell 里执行：

   ```powershell
   pwsh -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
   ```

3. 看到 `OK` 后，**完全退出 DSH**（托盘图标也要退出），再重新打开。
4. 打开 `http://127.0.0.1:<当前端口>/_dsh-cookie-gc`，能看到 `authCookieCount` 和 `staleCount` 就说明装好了。

> DSH 每次启动端口不同，端口在 DSH 窗口地址栏里能看到。

## 它做了什么

- 把插件复制到 `%USERPROFILE%\.dsh\addons\dsh-cookie-gc`
- 在 `<profile>\node_modules` 下建一个目录 junction（不是复制，改一处即生效；junction 不需要管理员权限）
- 在 profile 的 `package.json` 里：
  - `dependencies` 加一条 `link:` 指向上面那个目录
  - `dsh.profile.bundles` 加一条 `dsh-cookie-gc`
- 改之前自动备份：`package.json.bak-before-cookie-gc`

## 卸载

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

## 如果已经爆到打不开（431）

插件救不了已经发生的 431（431 发生在 HTTP 解析层，请求进不到插件）。先彻底退出 DSH，然后二选一：

**A. 只删 DSH 的登录 cookie（推荐，需要 Python）**

```powershell
python -c "import sqlite3,os; p=os.path.join(os.environ['APPDATA'],'@deepseek-ai','dsh-desktop','Network','Cookies'); c=sqlite3.connect(p); c.execute(\"delete from cookies where name like 'dsh-auth-%'\"); c.commit(); c.close(); print('done')"
```

**B. 没有 Python 的粗暴办法**

删掉 `%APPDATA%\@deepseek-ai\dsh-desktop\Network\Cookies` 这个文件。

⚠️ 这会把**所有网站**在这个 DSH 里的登录状态一起清掉（不只是 DSH 自己），但 DSH 下次启动会重新签发。能接受再用 B。

清完再启动 DSH，然后把插件装上，之后就不会再爆。

## 常见问题

**装完没反应？**
先确认 DSH 是**完全退出后重开**的，不是只关窗口。然后看 `%USERPROFILE%\.dsh\logs\dsh-cookie-gc.log` 有没有 `plugin activated`。

**日志里 `auth=2 cleared=1` 是什么意思？**
这次请求带了 2 条 dsh-auth-*，插件删掉 1 条旧的，留下当前端口那条。这是正常且正确的状态。

**会不会误删别的网站登录？**
不会。只处理 `dsh-auth-` 前缀的 cookie。
