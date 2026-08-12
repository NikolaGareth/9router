# Task 5 final verification report

Status: **DONE_WITH_CONCERNS**

Scope: local, read-only validation on `master`. No cloud host was contacted or changed, and nothing was pushed.

## Fresh command results

| Command / check | Result | Evidence |
| --- | --- | --- |
| `bash -n deploy/linux/9router-update` | PASS (exit 0) | Syntax accepted. |
| `bash -n deploy/linux/install.sh` | PASS (exit 0) | Syntax accepted. |
| `bash -n deploy/linux/test-9router-update.sh` | PASS (exit 0) | Syntax accepted. |
| `bash deploy/linux/test-9router-update.sh` | PASS (exit 0) | Full local updater/installer regression suite completed successfully. |
| `git diff --check` | PASS (exit 0) | No whitespace errors. |
| Secret negative scan over `deploy/linux` | PASS (no hits) | No concrete `sk-…` value or assignment of password/API-key/access-token/refresh-token was found. README terminology was deliberately out of scope. |
| Manifest-lock consistency | PASS (exit 0) | `package-lock.json` v3 root name/version match `package.json`; dependencies, devDependencies, optionalDependencies, and peerDependencies match exactly. |
| `npm ci --dry-run --ignore-scripts` | PASS (exit 0) | npm resolved the lock and reported 77 packages would be added; no lifecycle scripts were run. |
| Pre-report `git status --short` | PASS | Empty: the worktree was clean before this report was created. |

## History / intended file scope

`git log --oneline -5` begins at `94c9be73 docs: 明确恢复脚本需要 root 执行`, followed by the README deployment clarification and installer/update work. Across `31435af6..HEAD`, the changed paths are only:

- `README.md`
- `package-lock.json`
- `deploy/linux/9router-update`
- `deploy/linux/9router.service`
- `deploy/linux/install.sh`
- `deploy/linux/test-9router-update.sh`

The newly created `.superpowers/sdd/task-5-report.md` is a verification artifact only and was not staged or committed.

## Task 3 minor re-check: generator write-failure propagation

**Concern remains real.** The joint-recovery generator writes the generated script with:

```bash
if ! {
  printf ...
  printf ...
  # more printf calls
  while ...; do printf ...; done
} >"$RECOVERY_SCRIPT_TEMP"; then
  ...
fi
```

at `deploy/linux/install.sh:422-452`; the first-install cleanup generator repeats the pattern at `:985-1011`. In Bash, commands whose compound list is used as an `if` condition do not get `errexit` propagation. Consequently, an intermediate `printf` failure may be followed by successful writes, leaving the compound list with a zero status. The existing state-machine checks validate the recovery script *after it has been generated/used*; they do not check each generator write's return status. The local regression suite contains recovery/resume coverage but no fault injection for an intermediate generator `printf` failure.

A minimal fresh Bash control-flow reproduction confirmed the behavior: a deliberately failing second `printf` inside `if ! { printf; printf; printf; }; then` was followed by the third write and the compound list returned zero. Thus this is not resolved by the later state machine. A safe remediation would make each emission fail-fast (for example, `printf ... && printf ... && ...`, or explicit status checks) and add a corresponding generator failure-injection test.

This report does not modify the implementation; the concern is recorded for the parent final review.

## Follow-up: generator concern resolved

Status: **RESOLVED**

The previously recorded compound-list concern was reproduced first with a controlled failure on the fifth generated-script write:

```text
FAIL: did not expect path: .../run/9router-install-recover
```

Both generators now route every emitted fragment through `script_printf` and explicitly accumulate every failed write before returning the compound-list status. A failed intermediate write invokes the existing generation cleanup: no fixed 0700 script, step, or work copy is published, while immutable recovery materials and the retained new entrypoints remain unchanged. The existing explicit `bash -n`, `chmod 0700`, and atomic `mv` checks continue to use the same cleanup path.

The regression separately injects joint-recovery and first-install-cleanup generation failures, then verifies uninjected fresh attempts publish complete private executable scripts. After the fix, the full integration suite exited 0 and printed:

```text
PASS: 9router Linux updater tests
```

The parent task will record the final three syntax checks and `git diff --check` alongside the commit evidence.

## 2026-08-11 直接部署运行时闭包

固定 Node 直接执行 npm CLI，lifecycle PATH 仅含固定 Node、`/usr/bin`、`/bin`；运行时新增 `src/shared/constants/mitmToolHosts.js` 并在切换前对 DNS 配置执行隔离 require smoke。健康检查绕过环境代理，previous 采用 retired 两阶段清理。完整 Linux 集成 PASS，npm dry-run 通过。

## 2026-08-12 安装入口恢复矩阵最终验证

状态：**DONE**。独立只读审查发现的 absent-unit 调和 P1 已按 RED→GREEN 修复；复核结论为 `No findings（P0/P1/P2）`。

| 验证 | 结果 |
| --- | --- |
| `bash -n deploy/linux/9router-update deploy/linux/install.sh deploy/linux/test-9router-update.sh` | PASS，exit 0 |
| `NINEROUTER_TEST_FOCUS_INSTALLER_RECOVERY=1 bash deploy/linux/test-9router-update.sh` | PASS，直接打印 focused PASS，exit 0 |
| `bash deploy/linux/test-9router-update.sh` | PASS，直接打印完整套件 PASS，exit 0 |
| `npm ci --dry-run --ignore-scripts` | PASS，exit 0，报告 would add 77 packages |
| `git diff --check` | PASS，exit 0 |

聚焦测试真实执行 A 的 SIGKILL/重启调和、B 的四个存在性象限及恢复脚本终态、C 的生成期 fixed 和执行期 fixed/work 同 inode 篡改拒绝；不是仅对生成文本做 grep。完整测试保持默认行为，显式聚焦环境变量未设置时不会跳过其他集成场景。

独立审查首次指出 originally absent unit 会在删除后重复执行 `disable`，导致恢复状态永久残留。新增 updater/unit 两个 SIGKILL 回归先在旧实现上稳定失败；修复将 enable-link 清理前移到 unit 仍存在时。修复后的聚焦套件、完整套件和独立复核全部通过，无已知功能缺陷。
