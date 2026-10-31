#requires -version 5.1
<#
  dsh-cookie-gc installer / uninstaller

  用法：
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Profile "C:\Users\you\.dsh\profiles\desktop"
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall

  做什么：
    1. 把插件目录复制到 %USERPROFILE%\.dsh\addons\dsh-cookie-gc
    2. 在 profile 的 node_modules 下建目录 junction（普通用户即可，不需要管理员）
    3. 在 profile 的 package.json 里补 dependencies 与 dsh.profile.bundles
    修改前自动备份 package.json。

  安全：任何一步失败都会还原 package.json 备份并报错退出，不会留下半装状态。

  ★ 输出用英文是故意的：Windows 控制台默认 GBK，中文在这里会变成乱码。
#>
[CmdletBinding()]
param(
  [string]$Profile = '',
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

function Say($text) { Write-Host $text }
function Fail($text) { Write-Host "FAIL: $text" -ForegroundColor Red; exit 1 }

$here = Split-Path -Parent $PSCommandPath
$dshHome = Join-Path $env:USERPROFILE '.dsh'
$addonsRoot = Join-Path $dshHome 'addons'
$target = Join-Path $addonsRoot 'dsh-cookie-gc'
$profilesRoot = Join-Path $dshHome 'profiles'

if (-not (Test-Path -LiteralPath $profilesRoot)) { Fail "Not found: $profilesRoot  (has DSH been installed?)" }

# ---- locate profile ----
if (-not $Profile) {
  $withPkg = @(Get-ChildItem -LiteralPath $profilesRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'package.json') })
  if ($withPkg.Count -eq 1) {
    $Profile = $withPkg[0].FullName
  } elseif (Test-Path -LiteralPath (Join-Path $profilesRoot 'desktop\package.json')) {
    $Profile = Join-Path $profilesRoot 'desktop'
  } else {
    Fail "Found $($withPkg.Count) profiles, cannot choose automatically. Use -Profile to name one."
  }
}
if (-not (Test-Path -LiteralPath $Profile)) { Fail "Profile does not exist: $Profile" }
$pkgPath = Join-Path $Profile 'package.json'
if (-not (Test-Path -LiteralPath $pkgPath)) { Fail "Missing $pkgPath" }
$linkPath = Join-Path $Profile 'node_modules\dsh-cookie-gc'
$bakPath = "$pkgPath.bak-before-cookie-gc"
Say "profile: $Profile"

function Read-Pkg {
  Get-Content -LiteralPath $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
function Write-Pkg($pkg) {
  $pkg | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $pkgPath -Encoding UTF8
}

# ---- uninstall ----
if ($Uninstall) {
  if (Test-Path -LiteralPath $linkPath) {
    (Get-Item -LiteralPath $linkPath -Force).Delete()
    Say 'removed node_modules\dsh-cookie-gc'
  }
  if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
  Copy-Item -LiteralPath $pkgPath -Destination $bakPath -Force
  $pkg = Read-Pkg
  if ($pkg.dependencies -and $pkg.dependencies.PSObject.Properties.Name -contains 'dsh-cookie-gc') {
    $pkg.dependencies.PSObject.Properties.Remove('dsh-cookie-gc')
  }
  $pkg.dsh.profile.bundles = @($pkg.dsh.profile.bundles | Where-Object { $_ -ne 'dsh-cookie-gc' })
  Write-Pkg $pkg
  Say 'OK uninstalled. Restart DSH to take effect.'
  exit 0
}

# ---- install ----
if (-not (Test-Path -LiteralPath (Join-Path $here 'index.js'))) { Fail 'Run this script from the folder that contains index.js.' }

New-Item -ItemType Directory -Path $addonsRoot -Force | Out-Null
if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
New-Item -ItemType Directory -Path $target -Force | Out-Null
Copy-Item -Path (Join-Path $here '*') -Destination $target -Recurse -Force
Say "plugin copied to $target"

# directory junction: works without admin rights
if (Test-Path -LiteralPath $linkPath) {
  $item = Get-Item -LiteralPath $linkPath -Force
  if ($item.LinkType) { $item.Delete() } else { Remove-Item -LiteralPath $linkPath -Recurse -Force }
}
New-Item -ItemType Junction -Path $linkPath -Target $target | Out-Null
Say 'node_modules junction created'

# package.json: backup first, restore on any failure
Copy-Item -LiteralPath $pkgPath -Destination $bakPath -Force
Say "backup: $bakPath"

try {
  $pkg = Read-Pkg
  if (-not $pkg.dependencies) {
    $pkg | Add-Member -MemberType NoteProperty -Name dependencies -Value ([pscustomobject]@{})
  }
  $depValue = 'link:' + ($target -replace '\\', '/')
  if ($pkg.dependencies.PSObject.Properties.Name -contains 'dsh-cookie-gc') {
    $pkg.dependencies.'dsh-cookie-gc' = $depValue
  } else {
    $pkg.dependencies | Add-Member -MemberType NoteProperty -Name 'dsh-cookie-gc' -Value $depValue
  }
  $bundles = @($pkg.dsh.profile.bundles)
  if ($bundles -notcontains 'dsh-cookie-gc') { $pkg.dsh.profile.bundles = @($bundles + 'dsh-cookie-gc') }
  Write-Pkg $pkg
  $check = Read-Pkg
  if (@($check.dsh.profile.bundles) -notcontains 'dsh-cookie-gc') { throw 'bundles verification failed' }
  if (-not $check.dependencies.'dsh-cookie-gc') { throw 'dependencies verification failed' }
} catch {
  Copy-Item -LiteralPath $bakPath -Destination $pkgPath -Force
  Fail "package.json write failed, backup restored: $($_.Exception.Message)"
}

Say ''
Say 'OK installed.'
Say 'Next: fully quit DSH (tray icon too), then start it again.'
Say 'Check: open http://127.0.0.1:<current-port>/_dsh-cookie-gc'
Say 'Log:   %USERPROFILE%\.dsh\logs\dsh-cookie-gc.log'
