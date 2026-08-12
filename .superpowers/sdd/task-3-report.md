# 任务 3 实施报告：systemd 单元与首次安装器

## 交付内容

- `deploy/linux/9router.service`：固定使用 `/opt/9router`、`/root/.9router` 和 `/opt/node-v24.15.0-npm/node/bin/node`，不包含凭据字段。
- `deploy/linux/install.sh`：仅 root 可执行；生产模式拒绝环境覆盖，验证固定 Node/npm 与 git/curl/flock 后安装更新器和单元，创建（不删除、不读取）数据目录，依序 daemon-reload、enable、调用更新器。
- `deploy/linux/test-9router-update.sh`：增加单元、凭据和安装器安全断言；root CI 下增加完全位于 `/tmp` 的安装器集成测试，使用 fake `systemctl`，不访问真实 `/etc/systemd` 或 `/opt`。

## 红绿证据

### 红灯

先扩展测试并运行：

```text
$ bash deploy/linux/test-9router-update.sh
FAIL: expected file: /Users/zhangchenyang1/Github/9router/deploy/linux/9router.service
```

失败原因是任务要求的 systemd 单元尚不存在。

### 绿灯

实现及小幅清理后重新运行：

```text
$ bash -n deploy/linux/9router-update
$ bash -n deploy/linux/install.sh
$ bash deploy/linux/test-9router-update.sh
PASS: 9router Linux updater tests
$ git diff --check
```

全部命令退出 0。

另验证非 root 调用在任何安装动作前拒绝：

```text
install.sh 必须以 root 身份运行
```

## 自审

- 单元的 `ExecStart`、`DATA_DIR`、启动顺序、重启及停止策略逐项与任务书一致。
- 安装器生产路径固定，生产 root 模式会拒绝所有 `NINEROUTER_*` 覆盖；测试模式要求显式隔离根目录并验证每一个会产生副作用的路径均在其中。
- 安装顺序先替换 unit 并 `daemon-reload`，再 `enable`，最后调用更新器；更新器只有在构建成功后才会停止/启动服务，避免安装器提前中断现有服务。
- 安装器不含 `rm`、`cat`、`read`，对数据目录仅执行 `mkdir -p`，不会删除、覆盖或读取其中的密码/API Key。
- 仅任务指定的三个交付文件将被暂存提交；本报告按要求保留在 `.superpowers/sdd/`，不纳入该提交。

## 疑虑

当前执行账户 EUID 为 502。隔离测试模式会在严格验证测试根及全部副作用路径后运行，以便非 root CI 也能覆盖安装器事务；生产模式仍强制要求 root 并拒绝覆盖变量。测试中所有副作用均位于 `/private/tmp` fake 环境，不触碰真实 systemd 或 `/opt`。除下述外层 SIGTERM 采集限制外，没有已知功能疑虑。

## 审查修复追加

### 事务性 unit 迁移

- 现有 unit 会先在同一 systemd 目录以 `cp -a` 备份，保留原始字节与权限；新 unit 先写入同目录临时文件，再以 `mv -fT` 原子替换。
- 自首次新 unit 写入起，任何 `daemon-reload`、`enable` 或更新器失败都会触发 EXIT trap：已有 unit 使用同目录备份原子恢复；首次安装删除新 unit；两种情形均重新执行 `daemon-reload`。
- 成功路径最后删除备份。安装器从不删除、覆盖或读取 `/root/.9router`；该目录仍仅经 `mkdir -p` 保证存在。

### 新增回归覆盖

- 在任意 cwd（测试从 `/` 执行）验证安装、daemon-reload、enable、更新器的完整调用序列。
- 覆盖已有 unit 下的 unit 安装、首次 daemon-reload、enable、更新器构建失败，逐项断言原 unit 字节/0600 权限恢复、临时入口与备份均被清理。
- 覆盖首次安装更新器失败时新 unit 被移除并 daemon-reload。
- 隔离测试根只允许规范化后的 `/tmp/*`、`/private/tmp/*` 或仓库 `.superpowers/*`；`/opt`、`/etc`、`/run` 被拒绝且没有 fake 命令事件。

### 本轮验证

```text
$ bash -n deploy/linux/9router-update
$ bash -n deploy/linux/install.sh
$ bash -n deploy/linux/test-9router-update.sh
$ bash -x deploy/linux/test-9router-update.sh > /private/tmp/9router-test-trace.out 2>&1
$ rg '^PASS: 9router Linux updater tests$' /private/tmp/9router-test-trace.out
PASS: 9router Linux updater tests
$ git diff --check
```

本机的既有 SIGTERM 回归场景会终止外层命令采集器，因此完整测试输出重定向到临时文件后读取 PASS 标记；测试本身运行至末尾并执行清理。该临时证据文件未纳入提交。

### 失败边界

若备份复制、临时 unit 写入或原子恢复本身失败，安装器会以失败退出；trap 会尽力清理已写入的临时文件并执行 daemon-reload，但不会删除或修改数据目录。若原子恢复或回滚后的 daemon-reload 也失败，会向 stderr 明确报告，保留可供人工恢复的备份路径（若仍存在）。

## 第二轮审查修复

- 安装前记录 `systemctl is-enabled 9router` 的明确状态；切换前失败会恢复 unit、更新器和 enabled/disabled/masked/not-found 状态。首次安装失败先 disable 以清理 wants 链接，再移除 unit。
- 更新器与 unit 都采用备份及同目录原子切换。更新器已开始后，若发现 previous，或首次安装的部署根从不存在变为存在，则判定为已完成目录切换：保留新 unit、更新器、服务与 previous/日志现场，不回滚入口。
- 更新器成功返回时立即提交事务；其后备份清理为非致命告警。
- fake systemctl 现覆盖 is-enabled、enable、disable、mask 与 wants-link 状态。新增已有安装健康失败回归，断言新 unit/new updater/new runtime 被保留；首次构建失败断言 disable 后不存在 unit/link。
- SIGTERM 回归由测试主进程后台启动更新器，记录实际子进程 PID，定向 kill 后 wait；fake 不再依据动态 PPID 发信号。

## 第三轮审查修复：固定事务协议与联合恢复

### 协议实现

- 更新器使用固定的 `/run/9router-update.phase`；测试模式使用测试根内的对应路径。每次状态通过同目录 `mktemp`、0600 临时文件和 `mv -fT` 原子发布，内容严格限定为 `preparing`、`building`、`stopping`、`old_moved`、`new_moved`、`started`、`healthy`、`health_failed`，不包含路径、凭据或其他秘密。
- `old_moved` 与 `new_moved` 是不可逆目录移动前的持久屏障。安装器清除旧 phase 后，在共享部署锁内启动更新器；失败时仅根据 phase 判断 pre/post switch，不再根据 `previous` 或正式目录是否存在猜测。
- 安装器和独立更新器共享 `/run/9router-update.lock`。安装器持有 FD 8 覆盖完整事务，child updater 校验继承 FD 与锁文件的设备/inode 一致后复用该锁，避免并发 installer/updater 串读 phase 或覆盖固定恢复材料。
- unit/updater 备份只有在 `cp -a` 完成、材料类型验证通过并原子发布后才设置 `*_BACKUP_READY=1`。复制失败只清理未 READY 临时文件，绝不会用空文件或残缺文件覆盖原入口。
- unit 恢复材料只接受普通文件或真实 mask 形态（指向 `/dev/null` 的 symlink）；updater 恢复材料只接受普通文件。其他 symlink 在任何入口写入前拒绝，并清理本事务已生成的安全材料。
- 固定恢复材料为 `/run/9router-install-recovery.unit`、`/run/9router-install-recovery.updater`、`/run/9router-install-recovery.enable-state`。post-switch 失败不自动回滚，保留新 unit、新 updater、新 runtime、phase、previous 与固定恢复材料，并输出包含 runtime、unit、updater、daemon-reload、enable 状态、原 active 状态及材料清理的联合人工恢复命令。
- pre-switch 失败恢复旧 unit/updater、原 enable 状态和原 active 状态。旧服务在 stop 后因 previous 竞态失败时会在旧入口恢复后重新启动；原本 inactive 的服务不会被擅自启动。
- `systemctl is-enabled` 只接受 `enabled/0`、`disabled/1`、`masked/1`、`not-found/1|4`；未知文本、空输出、查询异常以及“错误退出码但伪造 enabled 输出”均在入口写入前拒绝。
- `healthy` 在清理 previous 之前持久化；若 healthy 状态落盘失败，旧 runtime 仍保留，避免最终阶段写失败却提前丢失恢复目录。

### TDD 红灯证据

新增回归均先在旧实现或对应未修复实现上观察到预期失败，包括：

```text
FAIL: installer did not restore the original updater bytes
FAIL: installer accepted an unrecognized is-enabled state
FAIL: updater did not atomically record every success phase in order
FAIL: installer did not restore the original unit bytes
FAIL: expected file: .../opt/9router.previous/current-marker
FAIL: lock-contended installer cleared another updater phase
FAIL: stop-race failure left the previously active legacy service stopped
FAIL: installer accepted a non-mask unit symlink
FAIL: installer accepted an updater symlink
```

其中第一条由 fake `cp` 在备份文件中写入 `partial-updater-backup` 后退出，直接复现了残缺备份覆盖旧入口；healthy 红灯证明旧实现会在 phase 落盘前删除 previous。symlink 用例修正了测试模式早期一概拒绝 entrypoint symlink 的假绿，使 `/dev/null` mask 和非法 symlink 都真实经过备份事务。

### 新增回归覆盖

- unit 与 updater 两类备份 `cp` 失败，断言原字节和权限不变、残缺材料不参与恢复。
- 完整 success/health-failed phase 顺序、0600 最终 phase、healthy 写失败时 previous 保留。
- 预存 previous 为 `preparing`，恢复旧入口且不输出破坏性 runtime 恢复命令。
- old-directory 移动后的失败竞态已由 `old_moved` 屏障分类为 post-switch，保留新入口和固定恢复材料。
- legacy unit + legacy updater + old runtime 的联合恢复演练；恢复后实际执行旧 `ExecStart` 并得到 `legacy-entrypoint-ok`。
- 首次安装 post-switch 失败没有旧 unit/updater 时不生成无效联合恢复命令，并明确提示材料不足。
- `is-enabled` 未知状态、无输出查询错误、错误退出码配合法定文本三类写前拒绝。
- masked `/dev/null` unit 的 pre-switch 恢复；非 mask unit symlink 和 updater symlink 的写前拒绝。
- installer/updater 共享锁竞争时不清 phase、不写 unit/updater、不生成恢复材料。
- stop 后 previous 竞态的旧入口、旧 updater、active 状态与运行目录恢复。
- phase/recovery 路径越出测试根或为 symlink 时写前拒绝；生产 `/opt`、`/etc`、`/run` 仍不能作为测试根。

### 最终新鲜验证

在最后一次代码改动及独立复核后执行：

```text
$ bash -n deploy/linux/9router-update
$ bash -n deploy/linux/install.sh
$ bash -n deploy/linux/test-9router-update.sh
$ bash deploy/linux/test-9router-update.sh
PASS: 9router Linux updater tests
$ git diff --check
```

整组命令退出码为 0；完整集成测试为直接执行并直接打印 PASS，没有通过重定向或筛选掩盖退出状态。独立只读审查经过两轮 P1 修复复核，最终结论为 `No findings`（无剩余 P0/P1）。

### 最终自审

- 安装器 pre/post switch 分类只读取受共享锁保护的固定 phase；目录存在性仅用于生成与实际现场相符的人工命令，不参与事务分类。
- 所有 READY 材料均在复制成功、类型验证和原子发布后置位；restore 与 post-switch report 会再次验证 unit/updater 材料类型。
- 新 unit/updater 使用各自目标目录内临时文件与 `mv -fT` 替换；post-switch 失败不执行自动 runtime 回滚。
- 联合恢复命令会消费 unit/updater/enable-state 恢复材料，避免恢复后固定材料阻塞下一次安装。
- 对 `/root/.9router` 仍只有 `mkdir -p`；测试覆盖既有数据哨兵，脚本未读取、删除或打印该目录中的任何内容。
- phase 与 enable-state 只包含固定白名单值，systemd unit 仍通过凭据关键词负向断言。

### 最终疑虑

- 本机执行账户不是生产 root/systemd 环境；集成测试使用隔离测试根和行为更真实的 fake systemctl/cp/mv 验证事务，没有在真实 `/etc/systemd/system`、`/opt`、`/run` 或 `/root/.9router` 上做破坏性演练。
- `/run` 通常为易失文件系统；post-switch 失败后应在重启前按输出处理固定 unit/updater/enable-state 恢复材料。该位置符合本轮固定安全运行时协议要求，但恢复材料不会承诺跨重启持久化。

## 正式审查后修复：intent/committed 与可重入恢复

本节取代上文“`old_moved`/`new_moved` 是移动前屏障”和“联合人工恢复命令”等旧描述。正式审查指出旧协议会把移动前失败误判为 post-switch，且线性恢复脚本在“动作已完成但命令返回失败”后不能安全重跑。本轮按审查要求重新设计并实现。

### 协议与实现

- 更新器在移动前分别原子写入 `old_move_intent`、`new_move_intent`；`mv` 返回后先严格验证源已不存在、目标为安全目录，再原子提交 `old_moved`、`new_moved`。安装器只把 committed 及以后阶段当作 post-switch。
- `old_move_intent` 只有在 ROOT 的设备/inode 仍等于安装开始时记录值、BUILD 安全存在且 previous 不存在时，才证明目录未修改并执行 pre-switch 入口恢复。首次安装的 `new_move_intent` 只有 ROOT/previous 仍不存在且 BUILD 安全存在时才恢复；已有版本已经提交 old move 的现场保留并给出明确诊断，不猜测目录恢复顺序。
- 初始 `masked` 且 `active` 的组合在备份、入口写入和停服前拒绝，并提示先 `unmask` 后重新确认状态。
- 联合恢复不再输出内联 `systemctl/mv/rm` 命令。安装器生成固定 0700 的恢复脚本、固定 0600 的 step 文件和 unit/updater work 副本，只输出运行该脚本的单一命令。脚本获取同一共享锁，复验固定锁路径与 FD inode、恢复材料、step token、ROOT/previous/BUILD 和入口 inode 后才执行。
- 联合恢复采用 `prepared -> root_restored -> unit_restored -> updater_restored -> systemd_restored` 状态机。每次破坏性动作前确认服务已明确为 `inactive` 或 `failed`；新 ROOT 原子转存为固定 `.failed` 目录而不删除。若 ROOT、previous、unit 或 updater 的移动已经生效但命令报错，下次执行会根据严格 inode 现场对账续跑。旧 unit/updater 的固定原件直到 systemd 状态恢复成功后才幂等清理。
- 首次安装收尾采用独立的 `prepared -> unit_removed -> updater_removed -> systemd_reloaded` 状态机，同样持共享锁并验证 inode。unit/updater 删除或 daemon-reload 在部分成功后报错均可重试；收尾只清本次新入口、phase 和 enable marker，保留失败代码目录及数据目录，完成后允许再次安装。
- 两个生成函数显式检查临时文件写入、0600/0700 权限、原子发布和生成脚本自身的 `bash -n`；即使函数位于 shell `if` 条件中，也不会依赖被抑制的 `set -e`。
- 测试 fake `flock` 现在记录真实持锁进程并以存活 PID 实现互斥/继承锁语义；fake `stat` 返回真实设备/inode，不再使用常量。并发回归让真实后台 updater 持锁，再验证恢复脚本拒绝运行。

### TDD 红灯证据

新增测试先在未修复实现上得到以下红灯：

```text
FAIL: replaced ROOT was misclassified as an unchanged pre-switch scene
FAIL: expected file: .../opt/9router.failed/.runtime/custom-server.js
```

第一条证明仅凭路径存在性会把 `old_move_intent` 中被替换的 ROOT 错当作“未修改”；加入初始 ROOT inode 绑定后转绿。第二条证明旧线性联合恢复会删除失败的新 ROOT；改为固定 `.failed` 转存和 step 状态机后转绿。部分变更注入还逐步覆盖 ROOT 转存、previous 恢复、unit 恢复、updater 恢复、daemon-reload、首次安装 unit/updater 删除和 daemon-reload，每次先要求当前调用失败，再要求后续调用从严格现场继续并最终完成。

### 新增回归覆盖

- old/new `mv` 在修改前失败，以及 old `mv` 修改后报错、意图阶段 ROOT inode 被替换。
- active+masked 在入口写入前拒绝。
- 恢复脚本遇到 stop 后仍 active 时不修改 ROOT/入口；ROOT、previous、unit、updater 和 daemon-reload 每一处部分成功均可续跑。
- 联合恢复保留失败新代码到 `.failed`，恢复 legacy unit/updater/runtime 后实际执行旧 `ExecStart` 得到 `legacy-entrypoint-ok`。
- 固定锁 inode 被替换时拒绝；后台 updater 持有共享锁时恢复拒绝且材料/previous 不变。
- 首次安装收尾的 unit/updater 删除与 daemon-reload 部分失败续跑；最终保留失败代码和数据哨兵，并成功重试 install。

### 本轮新鲜验证

最后一次实现代码改动并移除旧线性函数后，直接执行：

```text
$ bash -n deploy/linux/9router-update
$ bash -n deploy/linux/install.sh
$ bash -n deploy/linux/test-9router-update.sh
$ bash deploy/linux/test-9router-update.sh
PASS: 9router Linux updater tests
$ git diff --check
```

三份语法检查、完整集成测试和 `git diff --check` 均退出 0；完整测试没有重定向或筛选 PASS。完整集成在状态机初次落地后及移除旧实现后各运行一次，均直接打印 PASS。

### 自审与疑虑

- post-switch 路径从不自动回滚；只有操作者显式运行固定脚本才会恢复，并且整个动作持共享锁。
- 固定 phase、step 与恢复脚本不含凭据；任何路径诊断均为固定部署路径。`/root/.9router` 仍仅由安装器执行 `mkdir -p`，恢复/收尾脚本既不嵌入也不触碰它。
- `.failed` 目录刻意保留供检查；若该固定路径已有内容，联合恢复脚本不会覆盖它，而是拒绝生成并要求人工核对。
- 仍未在真实 root/systemd 生产主机执行破坏性故障注入；验证使用隔离测试根和更真实的 fake systemctl/flock/stat/mv/rm。`/run` 中恢复协议材料仍具有易失性，需在重启前处理。

## 终局边界修复（取代上节未完成的复核结论）

最后一次只读复核又指出四个恢复边界及一个测试质量缺口；按父任务要求修复后不再派生内部审查，交由正式任务复核。

### 新增 TDD 红灯

先加入 `.failed` 再安装、坏 step、终态 systemd 漂移、真实 missing-unit systemd、重复健康失败等回归。当前实现首先稳定复现：

```text
FAIL: installer accepted a retained failed-code directory before writing entrypoints
```

未修复实现还会把 symlink step 当作“缺失”并删除恢复脚本；首次收尾在 unit 已被删除后会再次要求 `stop/disable` 成功；第一次 cleanup 后的第二次健康失败不会生成任何收尾脚本。对应断言均先写入测试，再实施下述修复。

### 边界修复

- 联合恢复保留固定 `.failed` 后，后续 install 会在备份、入口写入和停服前明确拒绝，并提示先检查、移走或清理失败代码目录，避免第二次失败时恢复路径碰撞。
- 联合恢复的 `systemd_restored` 和严格 step-missing 终态会重新执行幂等 daemon-reload/enable 状态恢复/运行状态恢复，再严格复验 `is-enabled` 与 `is-active`，通过后才消费材料或删除脚本；服务在阶段提交后退出时不会被误报为完整恢复。
- 两个脚本的 `read_stage` 仅在路径真正不存在时返回“缺失”。symlink、目录、坏内容或错误 transaction ID 一律保留脚本和现场并失败，不能借终态文件系统绕过 step 安全检查。
- 首次收尾增加 `disabled` committed 阶段：unit 仍存在时先 stop、disable 并验证；阶段落盘后才移除 unit。unit 删除已生效但命令报错时，重跑只通过 `is-active/is-enabled` 验证继续，不再要求对不存在的 unit 重复执行 stop/disable。
- fake systemd 在 unit 缺失时会让 stop/disable 失败，并让查询返回真实的 `not-found/unknown`；该用例证明状态机没有依赖假 unit 继续存在。
- 首次 cleanup 后若 retry 再次 post-switch 失败，固定收尾脚本会在锁内把 previous 原子转存到当前失败 ROOT 的 `.previous-release-inspection` 子目录，保留两次失败现场且清空固定 previous 路径；随后再次 install 可正常进行。
- fake flock 在取得锁时记录真实设备/inode 快照；fake stat 的 FD 查询读取该独立快照，不再把 FD 直接映射为当前锁路径。恢复脚本和继承 updater 在 path/FD 对比后再次读取固定路径，覆盖固定锁在两次检查之间被替换的负向场景。

### 最终新鲜证据

终局代码和测试修改完成后直接执行：

```text
$ bash -n deploy/linux/9router-update
$ bash -n deploy/linux/install.sh
$ bash -n deploy/linux/test-9router-update.sh
$ bash deploy/linux/test-9router-update.sh
PASS: 9router Linux updater tests
$ git diff --check
```

三份语法检查、完整集成和 diff 检查均退出 0。完整集成包含两次健康失败后的两次 cleanup、第三次成功 install、step symlink 拒绝、终态 systemd 状态恢复、unit 缺失真实查询、锁 path/FD 竞态、所有部分变更续跑，并直接打印 PASS。

### 最终自审与剩余疑虑

- 所有自动 EXIT 处理仍只在证明目录未切换时恢复入口；post-switch、intent 不确定和恢复材料异常均不自动回滚。
- `.previous-release-inspection` 是显式运行收尾脚本后写入失败 ROOT 的检查子目录，不读取、不输出也不触碰 `/root/.9router`；下一次健康更新会随旧 ROOT 一并清理，因此操作者应在重试前完成检查或另行归档。
- 固定 `/run` 协议和 `.failed` 检查目录依旧不承诺跨重启持久化；生产环境仍需在重启前处理恢复指令。未在真实 systemd 主机执行破坏性故障注入，这是唯一已知验证限制。

## 恢复脚本完整写入校验

最终验证指出两个生成器仍使用 `if ! { printf ...; }; then`，Bash 会以 compound list 的最后一个命令决定状态，中间写入失败可能被后续成功覆盖。本轮作最小 TDD 修复，不改变事务状态机。

### 红灯

先加入第 5 次脚本片段写入失败注入，当前实现错误发布了残缺联合恢复脚本：

```text
FAIL: did not expect path: .../run/9router-install-recover
```

同一回归分别覆盖联合恢复生成器和首次 cleanup 生成器；失败时要求固定 0700 脚本、step、work 副本均不存在，旧 unit/updater 或 enable/phase 材料保持原样，新入口现场不变。无注入的新鲜场景随后必须正常发布完整 0700 脚本。

### 修复与自审

- 新增统一 `script_printf`，测试模式可在指定第 N 次调用返回失败；生产路径直接传播 builtin `printf` 的真实返回值。
- 两个生成器的每一次头部变量写入和 heredoc 逐行写入都显式执行 `|| script_write_failed=1`；compound list 最后以该累计状态返回，任何中间写失败都进入既有 cleanup 分支。
- 写失败会删除脚本临时文件、固定脚本、step 和 joint work 副本，但不会消费固定旧 unit/updater、enable-state 或 phase 材料。
- 临时脚本后续的 `bash -n`、`chmod 0700`、`mv -fT` 仍各自位于显式失败链中；任一步失败均执行同一安全清理，残缺脚本不会被发布。

### 验证

```text
$ bash -n deploy/linux/install.sh
$ bash -n deploy/linux/test-9router-update.sh
$ bash deploy/linux/test-9router-update.sh
PASS: 9router Linux updater tests
```

本轮完整集成退出 0 并直接打印 PASS。最终提交前还会重新执行任务要求的三个 `bash -n`、完整集成和 `git diff --check`。

## 2026-08-11 生产安全加固

- systemd unit 改为强制读取 `/etc/9router/9router.env`；安装器仅校验元数据，首次安装以 `/dev/urandom` 生成三个 256-bit 随机值，0600 原子发布且不回显。
- 旧 unit 若含内联秘密即在入口改写前拒绝，并给出迁移说明；旧 unit/updater 的 owner 与可写位也在备份前校验。
- 更新器按真实 active 状态停服，不再依赖 ROOT 是否存在；health curl 显式 `--noproxy '*'`。
- npm CLI 在生产通过固定 Node 执行并限制 lifecycle PATH；runtime 补入 MITM 共享常量并执行隔离 require smoke。
- previous 清理增加 cleanup intent、原子 retired rename、retired durable 阶段与可重试清理；提供持同一锁的显式 `--recover`。
- 安装入口部署标志在原子 mv 前建立，使 TERM/失败 trap 能覆盖“mv 已发生但下一条赋值尚未执行”的窗口。

验证：三脚本 `bash -n`；完整 `bash deploy/linux/test-9router-update.sh` 退出 0 并打印 PASS；`npm exec -- eslint src/app/api/auth/login/route.js`；`npm ci --dry-run --ignore-scripts`；`git diff --check`，均通过。

## 2026-08-12 安装入口恢复矩阵收口

本轮仅收口安装入口恢复协议的 A/B/C，不扩大直接部署范围。

### A：入口移动 intent/committed

- updater 与 unit 均在移动前原子持久化 `*_intent`，移动、SHA-256/元数据现场核验后再持久化 `*_committed`。
- 状态文件绑定 `unit_existed`、`updater_existed`，以及 staged/target/backup 的 inode、类型、SHA-256、owner、mode；启动时只对严格匹配的现场恢复或提交。
- SIGKILL 后重启调和、命令返回失败但移动已发生、SIGTERM 三类回归均实际恢复旧入口并清理固定材料。

### B：四象限联合恢复

- `both`、`unit-only`、`updater-only`、`neither` 四种 `UNIT_EXISTED`/`UPDATER_EXISTED` 组合均先制造 post-switch 健康失败，再要求生成可执行固定恢复脚本。
- 每个象限都实际运行脚本至终态：旧 runtime 恢复，新失败代码转存到 `.failed`；原本存在的 unit/updater 恢复原字节并可执行，原本不存在的入口被移除。
- 最终 readback 覆盖 enabled/disabled/not-found 与 active/inactive/unknown 语义，并断言 unit、updater、work、enable-state、phase、step、script 全部按状态机消费。

### C：不可变恢复材料

- 生成期分别对固定 unit/updater 恢复材料做同 inode 内容篡改；SHA-256 复验拒绝生成 script/step，篡改材料与新入口均保留。
- 执行期分别篡改 fixed-unit、fixed-updater、work-unit、work-updater；恢复脚本在任何 runtime 或入口破坏性动作前复验 inode、类型、SHA-256、owner、mode，失败后脚本和被篡改材料均保持不变。
- work 副本生成后先与固定材料摘要/类型/owner/mode 对账，生成脚本前再次复验 fixed 材料，消除 copy 与发布之间的静默内容变化。

### 接管与验证证据

本次接管保留前一执行者留下的两个未提交文件。接管时实现与新增回归已经存在，因此不把首次执行的绿灯虚构为本轮 RED；历史 RED 证据仍以上文各轮记录为准。本轮增加显式聚焦入口并取得新鲜证据：

```text
$ NINEROUTER_TEST_FOCUS_INSTALLER_RECOVERY=1 bash deploy/linux/test-9router-update.sh
PASS: focused installer recovery tests

$ bash deploy/linux/test-9router-update.sh
PASS: 9router Linux updater tests
```

两条命令均直接退出 0；默认完整套件未重定向或筛选 PASS。测试输出中的四条 `Killed: 9` 来自 A 的预期 SIGKILL 故障注入，套件随后继续并到达 PASS。

### absent-unit 调和 P1 修复

独立审查发现 A 原先只用 unit/updater 都存在的 legacy 现场：原 unit 不存在时，调和先删除新 unit，随后 `not-found` 分支仍对缺失 unit 执行 `systemctl disable`。真实 missing-unit 语义会让该命令失败并保留 entrypoint/enable 状态，后续安装永久重复失败。

先增加 `neither` 现场下 updater/unit 两个入口移动后 SIGKILL 的回归，并用 realistic missing-unit 重启安装器。旧实现稳定红灯：

```text
未能安全调和上一次安装入口事务；拒绝执行新的安装
FAIL: installer could not reconcile originally absent entrypoints and retry
```

最小修复在新 unit 仍存在时先清理 enable 链接，再按记录删除入口；若 unit 已 absent，则只可能是尚未安装或上一次已完成前置清理，`not-found` 终态不再向缺失 unit 重发 disable。两条回归均要求第二次安装不仅完成调和，还完整成功安装、比对新 unit/updater，并清空所有固定材料。

修复后聚焦套件与完整套件均 exit 0；原审查者再次只读复核，结论为 `No findings（P0/P1/P2）`，确认该回归不是假绿。

## 2026-08-12 终审 Important 恢复闭环

本轮严格只修终审确认的四项 Important：

- fake systemd 的 missing-unit `is-active` 改为与真实 systemd 一致：非 quiet 输出 `inactive` 且退出 4；installer 不再把 `is-enabled=not-found` 当作跳过 active 查询的条件，四种入口存在性现场均独立记录旧服务运行状态。
- updater 在切换前把 `active`、`reloading`、`activating`、`deactivating` 全部视为必须 stop 的运行/过渡态；stop 后只接受明确的 `inactive` 或 `failed`，已 inactive 的旧进程现场保持 no-op。
- `9router-update --recover` 新增同锁保护的 0600 原子持久阶段，支持规范 `old_moved`（ROOT absent、previous 与 BUILD present）；stop、ROOT 退役/恢复、start、retired/phase 清理均使用 intent/commit，并绑定 phase、ROOT、BUILD、previous 的 inode 与现场形态。命令已经改变现场但返回失败时先提交观测到的阶段，再要求重跑。
- 正常更新启动时调和 `previous_cleanup_intent`：retired 已存在则续删；retired 不存在且 previous 完整时确认 move 未发生，再原子移动到 retired 后续删；其他阶段（包括 `preparing`）不被覆盖。

严格 TDD 的首个红灯分别为：

```text
FAIL: installer skipped the active query when is-enabled returned not-found
FAIL: updater did not stop initial activating service
恢复现场不完整，拒绝操作
FAIL: updater --recover rejected canonical old_moved with absent ROOT
FAIL: updater could not reconcile previous_cleanup_intent after failure
```

对应四个聚焦入口随后均直接退出 0：

```text
PASS: focused installer systemd semantics tests
PASS: focused updater systemd semantics tests
PASS: focused updater recovery tests
PASS: focused previous cleanup reconciliation tests
```

恢复回归实际注入了 previous→ROOT 和 start “已生效但命令返回失败”：前者持久提交 `stage=root_restored`，后者持久提交 `stage=started`；再次执行 `--recover` 均完成终态，且 start 总调用次数保持为 1。previous 收尾回归同时覆盖 intent 后 move 前普通失败和 SIGKILL，重跑后均完成退役清理；`preparing` 现场仍被保留并拒绝猜测。
