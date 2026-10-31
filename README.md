# dsh-cookie-gc
这个插件解决 DSH 桌面版的一个问题：每次启动端口都变，登录 cookie 越攒越多，约 72 条后请求头超过 Node 的 16KB 上限，登录报 `Web authentication failed`（HTTP 431）。  它会在每次启动后的第一批请求里，把「不是本次端口」的 `dsh-auth-*` cookie 删掉，只留当前那一条。
