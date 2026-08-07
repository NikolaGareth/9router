# 9Router 云主机直接更新实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 提供一套可在 Ubuntu 云主机上手动执行的直接更新工具，将生产服务安全更新到 GitHub `master` 最新提交。

**架构：** 更新脚本在 `/opt/9router-build` 完成浅克隆、依赖安装、构建和生产运行目录组装，全部成功后才短暂停止 systemd 服务并替换 `/opt/9router`。systemd 从 `.runtime/custom-server.js` 启动，与项目 Dockerfile 的生产入口一致；持久化数据固定留在 `/root/.9router`。

**技术栈：** Bash、Git、npm、Node.js、Next.js standalone、systemd、curl

---

## 文件结构

- 创建：`deploy/linux/9router-update` —— 带锁、预构建、目录切换、健康检查和清理的生产更新命令。
- 创建：`deploy/linux/9router.service` —— 从固定运行目录启动 9Router 的 systemd 单元。
- 创建：`deploy/linux/install.sh` —— 首次安装更新命令和服务单元，并执行首次部署。
- 创建：`deploy/linux/test-9router-update.sh` —— 使用临时目录及伪造外部命令验证成功、构建失败和健康检查失败路径。
- 修改：`README.md` —— 增加云主机直接部署、更新、日志查看和故障恢复说明。

### 任务 1：为更新脚本建立失败测试

**文件：**
- 创建：`deploy/linux/test-9router-update.sh`
- 测试：`deploy/linux/test-9router-update.sh`

- [ ] **步骤 1：编写测试夹具和成功路径测试**

测试脚本使用 `mktemp -d` 创建隔离目录，并生成 fake `git`、`npm`、`systemctl`、`curl`。fake `git clone` 创建最小仓库树；fake `npm run build` 创建 `.next/standalone/server.js`、`custom-server.js`、`open-sse`、`src/mitm`、`node_modules/node-forge` 和 `node_modules/next`。执行更新器时通过以下专用测试变量重定向路径和命令：

```bash
NINEROUTER_ROOT="$TMP/opt/9router" \
NINEROUTER_BUILD_DIR="$TMP/opt/9router-build" \
NINEROUTER_PREVIOUS_DIR="$TMP/opt/9router.previous" \
NINEROUTER_LOCK_FILE="$TMP/run/9router-update.lock" \
NINEROUTER_GIT="$TMP/bin/git" \
NINEROUTER_NPM="$TMP/bin/npm" \
NINEROUTER_SYSTEMCTL="$TMP/bin/systemctl" \
NINEROUTER_CURL="$TMP/bin/curl" \
NINEROUTER_NODE="$(command -v node)" \
bash deploy/linux/9router-update
```

断言：

```bash
test -f "$TMP/opt/9router/.runtime/custom-server.js"
test -f "$TMP/opt/9router/.runtime/server.js"
test -d "$TMP/opt/9router/.runtime/open-sse"
test -d "$TMP/opt/9router/.runtime/src/mitm"
test ! -e "$TMP/opt/9router.previous"
grep -q '^stop 9router$' "$TMP/systemctl.log"
grep -q '^start 9router$' "$TMP/systemctl.log"
```

- [ ] **步骤 2：编写构建失败不停止线上服务的测试**

让 fake npm 在 `run build` 时退出 42，预先创建 `$TMP/opt/9router/current-marker`，执行后断言：

```bash
test "$status" -ne 0
test -f "$TMP/opt/9router/current-marker"
! grep -q '^stop 9router$' "$TMP/systemctl.log"
```

- [ ] **步骤 3：编写健康检查失败不误报成功的测试**

让 fake curl 始终失败，断言更新器返回非零、已尝试启动新服务、保留 `$TMP/opt/9router.previous`，且输出包含人工恢复命令提示。

- [ ] **步骤 4：运行测试验证失败**

运行：

```bash
bash deploy/linux/test-9router-update.sh
```

预期：FAIL，提示 `deploy/linux/9router-update` 不存在。

- [ ] **步骤 5：提交测试**

```bash
git add -f deploy/linux/test-9router-update.sh
git commit -m "test: 添加云主机更新流程测试"
```

### 任务 2：实现安全更新命令

**文件：**
- 创建：`deploy/linux/9router-update`
- 测试：`deploy/linux/test-9router-update.sh`

- [ ] **步骤 1：实现固定配置、命令覆盖和文件锁**

脚本必须使用以下开头；`NINEROUTER_*` 覆盖仅用于测试与受控迁移，默认值固定为生产路径：

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${NINEROUTER_ROOT:-/opt/9router}"
BUILD_DIR="${NINEROUTER_BUILD_DIR:-/opt/9router-build}"
PREVIOUS_DIR="${NINEROUTER_PREVIOUS_DIR:-/opt/9router.previous}"
LOCK_FILE="${NINEROUTER_LOCK_FILE:-/run/9router-update.lock}"
GIT="${NINEROUTER_GIT:-/usr/bin/git}"
NPM="${NINEROUTER_NPM:-/opt/node-v24.15.0-npm/node/bin/npm}"
NODE="${NINEROUTER_NODE:-/opt/node-v24.15.0-npm/node/bin/node}"
SYSTEMCTL="${NINEROUTER_SYSTEMCTL:-/usr/bin/systemctl}"
CURL="${NINEROUTER_CURL:-/usr/bin/curl}"
REPOSITORY="https://github.com/NikolaGareth/9router.git"
BRANCH="master"

mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "已有 9Router 更新正在执行" >&2; exit 1; }

for path in "$ROOT" "$BUILD_DIR" "$PREVIOUS_DIR"; do
  [[ "$path" == /* ]] || { echo "部署路径必须是绝对路径：$path" >&2; exit 1; }
  case "$path" in
    /|/opt|/root) echo "拒绝危险部署路径：$path" >&2; exit 1 ;;
  esac
done
[[ "$ROOT" != "$BUILD_DIR" && "$ROOT" != "$PREVIOUS_DIR" && "$BUILD_DIR" != "$PREVIOUS_DIR" ]] || {
  echo "部署目录必须互不相同" >&2
  exit 1
}
```

- [ ] **步骤 2：实现停服前的克隆、依赖安装和构建**

```bash
rm -rf -- "$BUILD_DIR"
"$GIT" clone --depth 1 --branch "$BRANCH" "$REPOSITORY" "$BUILD_DIR"
(
  cd "$BUILD_DIR"
  NEXT_TELEMETRY_DISABLED=1 "$NPM" ci
  NEXT_TELEMETRY_DISABLED=1 "$NPM" run build
)
test -f "$BUILD_DIR/.next/standalone/server.js"
test -f "$BUILD_DIR/custom-server.js"
```

任何命令失败都由 `set -e` 终止，此时不得调用 `systemctl stop`。

- [ ] **步骤 3：按 Dockerfile 生产布局组装 `.runtime`**

```bash
cp -a "$BUILD_DIR/.next/standalone" "$BUILD_DIR/.runtime"
cp "$BUILD_DIR/custom-server.js" "$BUILD_DIR/.runtime/custom-server.js"
cp -a "$BUILD_DIR/open-sse" "$BUILD_DIR/.runtime/open-sse"
mkdir -p "$BUILD_DIR/.runtime/src"
cp -a "$BUILD_DIR/src/mitm" "$BUILD_DIR/.runtime/src/mitm"
mkdir -p "$BUILD_DIR/.runtime/node_modules"
cp -a "$BUILD_DIR/node_modules/node-forge" "$BUILD_DIR/.runtime/node_modules/node-forge"
cp -a "$BUILD_DIR/node_modules/next" "$BUILD_DIR/.runtime/node_modules/next"
"$NODE" --check "$BUILD_DIR/.runtime/custom-server.js"
"$NODE" --check "$BUILD_DIR/.runtime/server.js"
```

- [ ] **步骤 4：实现短停服目录切换**

先清理上次成功部署遗留的 previous，停止服务后将现目录暂存为 previous，再将新目录移动到正式位置：

```bash
rm -rf -- "$PREVIOUS_DIR"
"$SYSTEMCTL" stop 9router 2>/dev/null || true
if [[ -e "$ROOT" ]]; then mv "$ROOT" "$PREVIOUS_DIR"; fi
mv "$BUILD_DIR" "$ROOT"
"$SYSTEMCTL" start 9router
```

使用 `swapped=1` 标记，避免退出 trap 删除已成为正式目录的构建结果。

- [ ] **步骤 5：实现有界健康检查和成功清理**

最多检查 30 次，每次间隔 1 秒：

```bash
healthy=0
for _ in {1..30}; do
  if "$CURL" -fsS --connect-timeout 2 --max-time 3 \
      -o /dev/null http://127.0.0.1/dashboard; then
    healthy=1
    break
  fi
  sleep 1
done
```

健康时读取 `git -C "$ROOT" rev-parse --short HEAD`，删除 previous 并输出成功。失败时不得删除 previous，输出：

```text
新版本健康检查失败。旧目录保留在 /opt/9router.previous。
检查：journalctl -u 9router -n 100 --no-pager
人工恢复：systemctl stop 9router && rm -rf /opt/9router && mv /opt/9router.previous /opt/9router && systemctl start 9router
```

随后返回非零。脚本不自动回滚，符合已确认设计。

- [ ] **步骤 6：运行测试和静态语法检查**

```bash
bash -n deploy/linux/9router-update
bash deploy/linux/test-9router-update.sh
```

预期：语法检查退出 0，测试输出 3 个场景全部 PASS。

- [ ] **步骤 7：提交更新器**

```bash
git add -f deploy/linux/9router-update
git commit -m "feat: 添加 9Router 云主机安全更新器"
```

### 任务 3：添加 systemd 单元与首次安装器

**文件：**
- 创建：`deploy/linux/9router.service`
- 创建：`deploy/linux/install.sh`
- 测试：`deploy/linux/test-9router-update.sh`

- [ ] **步骤 1：编写 systemd 单元**

`deploy/linux/9router.service` 使用：

```ini
[Unit]
Description=9Router Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/9router/.runtime
Environment=NODE_ENV=production
Environment=HOSTNAME=0.0.0.0
Environment=PORT=80
Environment=DATA_DIR=/root/.9router
Environment=NEXT_TELEMETRY_DISABLED=1
ExecStart=/opt/node-v24.15.0-npm/node/bin/node /opt/9router/.runtime/custom-server.js
Restart=on-failure
RestartSec=3
TimeoutStopSec=30
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
```

- [ ] **步骤 2：编写首次安装器**

`deploy/linux/install.sh` 必须验证以 root 执行、Node/npm/git/curl/flock 可用，然后：

```bash
install -m 0755 deploy/linux/9router-update /usr/local/sbin/9router-update
install -m 0644 deploy/linux/9router.service /etc/systemd/system/9router.service
mkdir -p /root/.9router
systemctl daemon-reload
systemctl enable 9router
/usr/local/sbin/9router-update
```

不得删除 `/root/.9router`，不得读取或修改 Dashboard 密码和 API Key。

- [ ] **步骤 3：增加服务配置断言**

在测试脚本中增加：

```bash
grep -q '^ExecStart=/opt/node-v24.15.0-npm/node/bin/node /opt/9router/.runtime/custom-server.js$' deploy/linux/9router.service
grep -q '^Environment=DATA_DIR=/root/.9router$' deploy/linux/9router.service
! grep -Eqi 'password|api[_-]?key|token|secret' deploy/linux/9router.service
```

- [ ] **步骤 4：运行全部脚本检查**

```bash
bash -n deploy/linux/9router-update
bash -n deploy/linux/install.sh
bash deploy/linux/test-9router-update.sh
```

预期：全部退出 0。

- [ ] **步骤 5：提交 systemd 与安装器**

```bash
git add -f deploy/linux/9router.service deploy/linux/install.sh deploy/linux/test-9router-update.sh
git commit -m "feat: 添加 9Router systemd 安装配置"
```

### 任务 4：补充直接部署与故障恢复文档

**文件：**
- 修改：`README.md`

- [ ] **步骤 1：添加首次部署命令**

README 增加“Ubuntu 直接部署”小节，明确先将仓库克隆到临时管理目录，再执行：

```bash
sudo bash deploy/linux/install.sh
```

列出前置条件：Ubuntu、Git、curl、`flock`、固定 Node.js 路径 `/opt/node-v24.15.0-npm/node/bin/node`，以及 80 端口未被其他程序占用。

- [ ] **步骤 2：添加日常手动更新和验证命令**

```bash
sudo 9router-update
systemctl status 9router --no-pager
curl -I http://127.0.0.1/dashboard
journalctl -u 9router -n 100 --no-pager
```

说明只有 `9router-update` 成功退出后，旧临时目录才会删除；持久化数据位于 `/root/.9router`。

- [ ] **步骤 3：添加健康检查失败的人工恢复命令**

```bash
test -d /opt/9router.previous
sudo systemctl stop 9router
sudo rm -rf /opt/9router
sudo mv /opt/9router.previous /opt/9router
sudo systemctl start 9router
```

明确只有更新脚本提示 previous 已保留时才能执行；执行前必须确认 previous 目录存在，避免误删。

- [ ] **步骤 4：运行文档与仓库验证**

```bash
git diff --check
rg -n '9router-update|/opt/9router|journalctl -u 9router' README.md
bash deploy/linux/test-9router-update.sh
```

预期：无空白错误，README 包含部署、更新和故障恢复命令，测试继续通过。

- [ ] **步骤 5：提交文档**

```bash
git add README.md
git commit -m "docs: 补充云主机直接部署与更新说明"
```

### 任务 5：最终验证

**文件：**
- 验证：`deploy/linux/9router-update`
- 验证：`deploy/linux/9router.service`
- 验证：`deploy/linux/install.sh`
- 验证：`deploy/linux/test-9router-update.sh`
- 验证：`README.md`

- [ ] **步骤 1：执行完整本地验证**

```bash
bash -n deploy/linux/9router-update
bash -n deploy/linux/install.sh
bash deploy/linux/test-9router-update.sh
git diff --check
```

预期：全部退出 0。

- [ ] **步骤 2：执行安全负向检查**

```bash
if rg -n -i '(sk-[A-Za-z0-9_-]{12,}|password\s*=|api[_-]?key\s*=|access[_-]?token\s*=|refresh[_-]?token\s*=)' deploy/linux; then
  echo "发现疑似秘密或硬编码凭据" >&2
  exit 1
fi
```

预期：无匹配。

- [ ] **步骤 3：确认仅包含计划内文件**

```bash
git status --short
git log --oneline -5
```

预期：工作树干净，最近提交仅涉及更新器、systemd、测试和 README。

- [ ] **步骤 4：在云主机首次部署后做生产验证**

```bash
systemctl is-enabled 9router
systemctl is-active 9router
curl -I --connect-timeout 5 http://127.0.0.1/dashboard
git -C /opt/9router rev-parse HEAD
git ls-remote https://github.com/NikolaGareth/9router.git refs/heads/master
test -f /root/.9router/db/data.sqlite
```

预期：服务 enabled/active，HTTP 返回成功或登录重定向，本地与远端 commit 相同，数据库文件仍存在。
