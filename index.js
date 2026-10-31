// dsh-cookie-gc · 宿主半
//
// 背景（2026-10-31 在本机核实）：
//   桌面版每次启动都让 Host 用随机端口（--port 0）。登录 cookie 的名字是
//   "dsh-auth-" + base64url(sha256(authority))，authority 含端口；浏览器 Cookie
//   不区分端口，于是每次启动都多一条，所有 dsh-auth-* 都会随每个请求发出去。
//   约 72 条后请求头超过 Node 默认的 16KB 上限 → HTTP 431 → 登录永远失败。
//
// 这个插件不碰磁盘上的 Cookies 库（DSH 运行时 Chromium 独占锁着，碰不了），
// 而是在每个已认证 HTTP 请求的响应里，给「不是本次端口那一份」的 dsh-auth-*
// 追加一条删除指令（Max-Age=0）。浏览器收到就删，下一次请求只带当前那一条。
//
// 效果：每次启动只看得到「上次的一条 + 本次新签发的一条」，页面一加载就砍回一条，
// 永远到不了 72。首次安装若已经爆到 431，仍需先用外部脚本清一次（那是锁的问题，
// 插件在 431 之前拿不到请求）。
//
// 为什么不直接读 cookie 值：一是不需要，二是凭据不该被插件读出。

import { createHash } from 'node:crypto'
import { appendFileSync, mkdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

export const name = 'dsh-cookie-gc'

/** 只用事件（connection/request），不依赖服务；路由注册用 webServer。 */
export const inject = ['webServer']

/** 与 @deepseek-ai/dsh-client-connection 的 browser-auth 完全一致。 */
const COOKIE_PREFIX = 'dsh-auth-'

/**
 * 单次响应最多删这么多条。
 * 每条 Set-Cookie 约 110 字节，24 条 ≈ 2.6KB；Node 响应头默认上限 16KB，
 * 留足余量给其他响应头。超出的部分下一次请求继续删。
 */
const MAX_DELETE_PER_RESPONSE = 24

/** cookie 名 = 前缀 + base64url(sha256(authority))，authority 为 Host 头的规范化值。 */
export function cookieName(authority) {
  return COOKIE_PREFIX + createHash('sha256').update(authority).digest('base64url')
}

/** 从 Cookie 请求头里取出所有 dsh-auth-* 的名字（去重，顺序按出现顺序）。 */
export function parseAuthNames(cookieHeader) {
  if (typeof cookieHeader !== 'string' || cookieHeader.length === 0) return []
  const seen = new Set()
  const out = []
  for (const part of cookieHeader.split(';')) {
    const eq = part.indexOf('=')
    if (eq === -1) continue
    const n = part.slice(0, eq).trim()
    if (n.startsWith(COOKIE_PREFIX) && !seen.has(n)) {
      seen.add(n)
      out.push(n)
    }
  }
  return out
}

/**
 * 算出这次请求该删哪些。
 * @returns {{ current: string | undefined, authNames: string[], stale: string[] }}
 *   current 缺失（没有 Host 头 / Host 不合法）时 stale 为空 —— 宁可不删，也不能把当前会话删掉。
 */
export function planGc(host, cookieHeader) {
  const authNames = parseAuthNames(cookieHeader)
  let current
  if (typeof host === 'string' && host.length > 0) {
    try {
      current = cookieName(new URL(`http://${host}`).host)
    } catch {
      current = undefined
    }
  }
  if (current === undefined) return { current: undefined, authNames, stale: [] }
  return { current, authNames, stale: authNames.filter((n) => n !== current) }
}

/** 删除指令。属性与 Host 签发时一致；删除只看 name + Path + host，多带属性无害。 */
export function deletionHeader(cookie) {
  return `${cookie}=; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/; HttpOnly; SameSite=Strict`
}

function logFile() {
  const home = process.env.DSH_HOME && process.env.DSH_HOME.trim() !== ''
    ? process.env.DSH_HOME
    : join(homedir(), '.dsh')
  return join(home, 'logs', 'dsh-cookie-gc.log')
}

function appendLog(line) {
  try {
    const file = logFile()
    mkdirSync(join(file, '..'), { recursive: true })
    appendFileSync(file, `${new Date().toISOString()} ${line}\n`, 'utf8')
  } catch {
    // 记日志失败绝不能影响请求
  }
}

export function apply(ctx) {
  appendLog('plugin activated')
  // waterfall：在响应发出之前追加删除指令，再交给后面的处理者写响应。
  ctx.on('connection/request', async (request, response, next) => {
    try {
      const { current, authNames, stale } = planGc(request.headers.host, request.headers.cookie)
      if (stale.length > 0) {
        const batch = stale.slice(0, MAX_DELETE_PER_RESPONSE)
        const existing = response.getHeader('set-cookie')
        const values = Array.isArray(existing) ? [...existing] : existing === undefined ? [] : [String(existing)]
        for (const cookie of batch) values.push(deletionHeader(cookie))
        response.setHeader('set-cookie', values)
        appendLog(
          `host=${request.headers.host} current=${current === undefined ? '?' : 'present'} ` +
          `auth=${authNames.length} cleared=${batch.length} deferred=${stale.length - batch.length}`,
        )
      }
    } catch {
      // 清理失败绝不能让请求本身失败
    }
    await next()
  })

  // 体检入口：浏览器打开 http://127.0.0.1:<端口>/_dsh-cookie-gc 就能看到当前端口下
  // 会带上几条 dsh-auth-*。只报数量，不碰值。
  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: '/_dsh-cookie-gc',
    handler: (request, response) => {
      const { current, authNames, stale } = planGc(request.headers.host, request.headers.cookie)
      const body = JSON.stringify({
        host: request.headers.host ?? null,
        currentCounterpart: current ?? null,
        authCookieCount: authNames.length,
        staleCount: stale.length,
        estimateHeaderBytes: authNames.length * 224 + 8,
        nodeHeaderLimit: 16384,
        note: '浏览器每次请求都会带上全部 dsh-auth-*；本插件在响应里删掉旧的那些。',
      }, null, 2)
      response.writeHead(200, {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'no-store',
      })
      response.end(body)
    },
  }), 'dsh-cookie-gc: inspect route')
}
