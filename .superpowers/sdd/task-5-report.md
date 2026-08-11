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
