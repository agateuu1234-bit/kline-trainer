#!/bin/sh
# docs/runbooks/2026-08-24-qmt-nas-expose.sh
#
# 管理 P12–P16 的「对外暴露窗口」。在 NAS 上执行。
#
# 为什么需要它（codex plan-R6 high）：`tailscale serve --bg` 是**持久**配置，
# 与开它的那个 ssh 会话无关。而本 API **零认证** —— spec §11-R8「本次不加认证」
# 这个决定的四个成立前提里，第四条就是「暴露窗口仅限验收期间、用完即关」。
# 把关闭交给一条人工嘱咐，等于断线/临时有事/某步失败就一直开着。
#
# ⚠️ 评审建议的「把开端点和整个验收流程包进带 EXIT/INT/TERM 陷阱的脚本」在本场景
#    **不可实现**：P13/P14 是人在手机上肉眼验收，可能持续几十分钟到几天；
#    脚本一退出陷阱就触发，会在正用着的时候把端点关掉。
#    可实现的等价保护 = 两道独立的关闭保证：
#      ① **超时看门狗**（进程级）：到点自动关，且**关到确认为止**；
#      ② **开机守卫**（/etc/cron.d 里的 @reboot 独立文件）：NAS 一重启就无条件关闭。
#    两道都必须先装好，`open` 才肯开端点。
#
# 设计要点（每一条都对应一次实测踩到的坑）：
# - 看门狗**不靠被 kill 撤销**，而是轮询状态文件；撤销 = 删文件（原子、可验证）。
#   起因：早先那版靠 kill，脚本直接跑时有效、被接进管道跑时同一份代码却杀不掉。
# - 判活**不用** `pgrep -f <字符串>`：它会匹配到**调用它的那条命令行自己**，
#   于是「已死」会被报成「还活着」（不安全方向）；同一个陷阱还让
#   `pkill -f` 把 ssh 自身杀掉。改为看门狗自写 PID 文件、按 PID 判活。
# - 所有 `docker exec` 一律 `timeout` + `</dev/null`：Serve 功能没启用时
#   `tailscale serve` **不快速失败而是等交互**，没超时会整条挂死。
# - 读状态一律**分开取输出与退出码**：`... | grep -q funnel` 在命令失败时
#   「没匹配到」会被当成「没有 funnel」，那是把失败读成成功（codex plan-R7）。
# - **「关闭」只有一份实现**（codex plan-R8）：早先看门狗到期那条路径是「关到确认为止」，
#   而 open 的失败路径和开机守卫却各写了一份「试一次就算」的关闭 —— 同一件事三份
#   能力不同的实现，弱的那两份就是失败开放的入口。现在全部走 `close-loop`：
#   反复 reset 并读 status，**只有确认 `No serve config` 才算关上**，确认前不撤看门狗。
#   open 的失败路径不再自己关，而是把到期时间设成「现在」，**把关闭交还给看门狗**。
#
# 用法：
#   expose.sh boot-guard-status        查开机守卫在不在（open 的前置）
#   expose.sh show-boot-guard-install  打印「装守卫」要 user 跑的那条命令
#   expose.sh show-boot-guard-remove   打印「卸守卫」要 user 跑的那条命令
#   expose.sh open <秒>            两道保证都在才开端点；否则拒绝
#   expose.sh status               端点状态 + 看门狗 + 开机守卫
#   expose.sh renew <秒>           验收超时前续期
#   expose.sh close                关端点 + 撤看门狗（幂等，任何路径都该跑）
#   expose.sh selftest             判据自检（不碰真实端点）
#   expose.sh close-loop <秒>      内部：反复关闭直到确认（0=不限时）
#   expose.sh boot-close           内部：开机守卫用，先等 docker/tailscale 就绪再 close-loop

set -u

TS_CTR=tailscale
STATE=/tmp/kline-trainer-expose.deadline
PIDFILE=/tmp/kline-trainer-expose.pid
LOG=/tmp/kline-trainer-expose.log
UPSTREAM_HOST=127.0.0.1
UPSTREAM_PORT=8010
UPSTREAM="http://${UPSTREAM_HOST}:${UPSTREAM_PORT}"
POLL=5
# ⚠️ 最短窗口（codex plan-R9 F1）：`open 0` 或极短窗口会让看门狗在 `serve --bg`
#    真正落配置**之前**就到期 —— 它此刻读到的确实是 `No serve config`，于是「确认关闭
#    成功」、删掉状态文件、退出；随后端点才被开出来，却已经没有看门狗看着它了。
MIN_SECS=300
BOOT_GUARD_FILE=/etc/cron.d/kline-trainer-boot-guard
# ⚠️ 所有会改动「端点状态 / 看门狗状态」的子命令都必须**串行化**（codex plan-R11）：
#    close_loop 确认「No serve config」之后才去删状态文件，这中间若有并发的 open
#    装好新看门狗并开出端点，那一删就把新守卫拆了；若开的那一方随后被打断
#    （Ctrl-C / ssh 断），端点就留在开着、没人看管的状态。
LOCKFILE=/tmp/kline-trainer-expose.lock
LOCK_WAIT=120

SELF=$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")

ts() { timeout 30 docker exec -i "$TS_CTR" tailscale "$@" </dev/null; }
now() { date +%s; }
stamp() { date '+%Y-%m-%d %H:%M:%S'; }

# ── 归属令牌（codex plan-R9 F2）──────────────────────────────────────────
# 早先 STATE 只存到期时间、PIDFILE 只存 PID，新旧两代看门狗**共用同一个 PIDFILE**，
# 而每一代退出时都无条件 `rm -f PIDFILE` → 旧的退出会删掉**新的** PID 文件，
# 于是续期后的存活检查失败 → arm 认为装失败 → disarm 删掉刚续上的状态 →
# 新看门狗也退出，最终「端点开着、一个看门狗都没有」。
# 现在：STATE = "<到期时间> <令牌>"，PIDFILE = "<PID> <令牌>"。
# 看门狗只在「STATE 里的令牌 == 自己的令牌」时行动；退出时也只在令牌仍是自己的
# 情况下才删 PIDFILE。续期**不再重启进程**，只原子替换到期时间、令牌不变。
new_token() { printf '%s-%s' "$(date +%s%N)" "$$"; }
state_deadline() { [ -f "$STATE" ] && cut -d' ' -f1 "$STATE" 2>/dev/null || echo ""; }
state_token()    { [ -f "$STATE" ] && cut -d' ' -f2 "$STATE" 2>/dev/null || echo ""; }
pid_of()         { [ -f "$PIDFILE" ] && cut -d' ' -f1 "$PIDFILE" 2>/dev/null || echo ""; }
pid_token()      { [ -f "$PIDFILE" ] && cut -d' ' -f2 "$PIDFILE" 2>/dev/null || echo ""; }

write_state() {   # <到期时间> <令牌>  —— 原子替换（先写临时文件再 mv）
    printf '%s %s\n' "$1" "$2" > "${STATE}.tmp" && mv -f "${STATE}.tmp" "$STATE"
}

# 「当前确实有一个活着的看门狗，且它就是当前状态的归属者」
watchdog_owns_state() {
    _p=$(pid_of); _pt=$(pid_token); _st=$(state_token)
    [ -n "$_p" ] && [ -n "$_pt" ] && [ -n "$_st" ] || return 1
    [ "$_pt" = "$_st" ] || return 1
    kill -0 "$_p" 2>/dev/null
}

# ── 判据（抽成函数，selftest 直接喂合成文本，无需碰真实端点）────────────────
# 返回 0 = 这份 serve 状态是「我们要的、且安全的」
serve_status_is_expected() {
    _txt=$1
    # ⛔ funnel 硬禁令（spec §4-D1）：serve 只对本 tailnet 内部暴露，funnel 会暴露到公网
    if printf '%s' "$_txt" | grep -qi 'funnel'; then echo "FUNNEL_DETECTED"; return 1; fi
    # 正向验证：必须看得到我们期望的反代目标端口，而不是「没看到坏东西」就算过
    if ! printf '%s' "$_txt" | grep -q "${UPSTREAM_PORT}"; then
        echo "SERVE_TARGET_UNCONFIRMED"; return 1
    fi
    return 0
}

# ⚠️ 开机守卫**不再动用户的 crontab**（codex plan-R13/R14/R15 连提三轮）。
#    早先是「整表读—改—写」：`crontab -l | 改 | crontab -`。两个层次的问题 ——
#    ① 读失败时空输出会覆盖整张表，把无关定时任务全删掉（R13，当时修了）；
#    ② 更根本的是**丢失更新关不掉**（R14/R15）：本脚本的锁只串行化自己，
#       别的管理员或自动化任务在「读」与「写」之间的改动会被整表替换抹掉，
#       而且**「我覆盖了别人」这个方向从本侧无法检测**（已实测确认）。
#       我一度把它记成「接受的残留 + 操作时别同时改」——**那个处置站不住**：
#       口头约束挡不住自动化任务，而 NAS 上丢掉的很可能是备份任务。
#    现在改用 **/etc/cron.d 下的独立文件**：创建/删除互不影响，不读也不改任何
#    共享表，那一整类竞态**根本不存在**（不是把窗口缩小，是消灭）。
#    代价：写 /etc/cron.d 需要 root，本机 agate1234 无免密 sudo →
#    装/卸变成**由 user 跑一条命令**（与 P1/P5 同类），脚本负责生成命令并核验。
# 守卫文件的**完整期望内容**（两行）。检测与安装都以它为唯一真相。
# ⚠️ 自带 PATH 行（与同目录 /etc/cron.d/sysstat 的惯例一致）：cron 跑任务时环境是
#    受限的。本机实测 docker 在 /usr/bin、且 /etc/crontab 的 PATH 覆盖得到，
#    但那是**当前**的巧合 —— 把 PATH 写进守卫文件，才不依赖系统默认值。
BOOT_GUARD_PATH='/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin'

# ⚠️ cron 行里的路径**不能带空白**：cron 按空白切字段，带空格的路径会被切碎，
#    而且是**静默**坏掉（守卫看着装上了，开机时却跑不起来）。部署目录
#    /vol1/1000/agate1234/kline-trainer 不带空格；这里加一道硬检查免得将来踩。
assert_self_path_sane() {
    case "$SELF" in
        *[[:space:]]*)
            printf '%s\n' "BAD_SCRIPT_PATH: 脚本路径含空白，cron 会把它切碎 —— 请把脚本放到不带空格的目录：$SELF"
            return 1 ;;
    esac
    return 0
}

boot_guard_line() {
    printf '@reboot %s %s boot-close >>%s 2>&1' "$(id -un)" "$SELF" "$LOG"
}

boot_guard_content() {
    printf 'PATH=%s\n%s\n' "$BOOT_GUARD_PATH" "$(boot_guard_line)"
}

# ⚠️ 必须**逐字精确匹配**，不能只找子串（codex plan-R16）。
#    早先写的是「文件存在 且 内容含 boot-close」—— 一行**注释** `# boot-close`、
#    一条写坏的 cron 行、路径或用户名不对、甚至别的命令里恰好带这几个字，
#    统统都能骗过去；open 于是认为「重启守卫在」而把零认证端点开出来，
#    重启后端点回来却没人关。
#    现在：剥掉空行与注释后剩下的**活动行**，必须与期望内容**完全一致**
#    （含定时表达式、以哪个用户跑、脚本绝对路径、参数、重定向、PATH 行）。
boot_guard_installed() {
    [ -f "$BOOT_GUARD_FILE" ] || return 1
    _active=$(grep -vE '^[[:space:]]*(#|$)' "$BOOT_GUARD_FILE" 2>/dev/null)
    _want=$(boot_guard_content | grep -vE '^[[:space:]]*(#|$)')
    [ "$_active" = "$_want" ]
}

# ⚠️ 这两个函数一律用 printf 输出，**不用 echo**（本机 /bin/sh 是 dash，
#    dash 的 echo 会解释 \n 之类的转义 —— 实测把给 user 的那条安装命令
#    从中间打断成了两行，粘贴过去是坏的）。
# ⚠️ 远程命令先装进变量、再用 printf 的 %s 占位符打出来，**不要**把它拼进
#    另一层引号里 —— 实测那样会把 \n 打成 \\n、把 && 打成 \&\&，粘过去同样是坏的。
print_boot_guard_install() {
    _remote="printf 'PATH=%s\n%s\n' '$BOOT_GUARD_PATH' '$(boot_guard_line)' | sudo tee $BOOT_GUARD_FILE >/dev/null && sudo chmod 644 $BOOT_GUARD_FILE && echo INSTALLED"
    printf '%s\n' "开机守卫要写到：$BOOT_GUARD_FILE"
    printf '%s\n' "这个文件属于 root，所以**这一步得你自己跑**（会问 NAS 密码）。"
    printf '\n'
    printf '%s\n' "在你自己的终端里，把下面这一整行粘贴进去（把 <NAS地址> 换成 NAS 的 IP）："
    printf '\n'
    printf '  ssh %s@<NAS地址> "%s"\n' "$(id -un)" "$_remote"
    printf '\n'
    printf '%s\n' "看到 INSTALLED 之后，回来跑：$SELF boot-guard-status"
}

print_boot_guard_remove() {
    _remote="sudo rm -f $BOOT_GUARD_FILE && echo REMOVED"
    printf '%s\n' "在你自己的终端里跑（会问 NAS 密码，把 <NAS地址> 换成 NAS 的 IP）："
    printf '\n'
    printf '  ssh %s@<NAS地址> "%s"\n' "$(id -un)" "$_remote"
}

# 等 docker 与 tailscale 容器就绪（开机时 cron 可能跑在它们起来之前）。
wait_ready() {
    _limit=$1; _t=0
    while [ "$_t" -lt "$_limit" ]; do
        if timeout 15 docker exec -i "$TS_CTR" tailscale version </dev/null >/dev/null 2>&1; then
            return 0
        fi
        sleep 10; _t=$((_t + 10))
    done
    return 1
}

# ⭐ **唯一**的关闭实现（codex plan-R8）：反复 reset 并读 status，
#    只有确认 `No serve config` 才返回 0。`$1` = 最长秒数，0 表示不限时。
close_loop() {
    _limit=$1; _t=0; _try=0
    _tok0=$(state_token)   # 进入时的归属，删状态文件前要比对（codex plan-R11）
    while : ; do
        _try=$((_try + 1))
        timeout 30 docker exec -i "$TS_CTR" tailscale serve reset </dev/null >>"$LOG" 2>&1
        _s=$(timeout 30 docker exec -i "$TS_CTR" tailscale serve status </dev/null 2>&1); _rc=$?
        if [ "$_rc" -eq 0 ] && printf '%s' "$_s" | grep -q 'No serve config'; then
            _tok1=$(state_token)
            if [ "$_tok1" != "$_tok0" ]; then
                # 归属在本次关闭期间变了 = 有并发方开了新窗口。**绝不删新一代的状态**，
                # 也不谎称关闭成功（此刻端点很可能已经被对方重新开出来了）。
                echo "$(stamp) CLOSE_ABORTED_OWNERSHIP_CHANGED: 归属从 [${_tok0}] 变成 [${_tok1}]，不删状态、不宣告成功" >>"$LOG"
                return 1
            fi
            echo "$(stamp) CLOSE_CONFIRMED: No serve config（第 ${_try} 次尝试）" >>"$LOG"
            rm -f "$STATE"
            return 0
        fi
        echo "$(stamp) CLOSE_RETRY: 第 ${_try} 次未确认（rc=${_rc}）—— 保持 armed 继续重试" >>"$LOG"
        _back=$((_try * 10)); [ "$_back" -gt 60 ] && _back=60
        if [ "$_limit" -ne 0 ]; then
            _t=$((_t + _back))
            if [ "$_t" -ge "$_limit" ]; then
                echo "$(stamp) CLOSE_GIVE_UP: ${_limit} 秒内未能确认关闭 —— 端点可能仍开着，需人工处理" >>"$LOG"
                return 1
            fi
        fi
        sleep "$_back"
    done
}

# 把当前窗口**立即到期**，交给看门狗去「关到确认为止」。
# ⚠️ 必须**保留归属令牌**（codex plan-R10，且这是 R9 修法自己长出来的回归）：
#    STATE 的格式是 "<到期时间> <令牌>"。三条失败路径原先只写时间戳 ——
#    看门狗读到的令牌对不上（`cut` 在没有分隔符时会把整行当第 2 字段返回，
#    于是令牌 == 时间戳），它判定「已被新一代接管」→ **安静退出、什么都不关**，
#    而脚本还在告诉人「已把关闭交还看门狗」。
#    写不成或写完归属对不上 → **同步关闭**，绝不假装交出去了。
expire_to_watchdog() {
    _tok=$(state_token)
    if [ -n "$_tok" ] && write_state "$(now)" "$_tok" && watchdog_owns_state; then
        echo "已把关闭交还看门狗（归属令牌已保留；它会重试直到确认 No serve config）"
        return 0
    fi
    echo "EXPIRE_FAILED: 交不出去（令牌缺失或归属对不上）—— 改为同步关闭"
    if close_loop 120; then echo "已确认关闭"; return 0; fi
    echo "⚠️ 未能确认关闭，请立刻查 $LOG 并手动跑 expose.sh close"
    return 1
}

disarm() {
    rm -f "$STATE"
    if [ -f "$STATE" ]; then echo "DISARM_FAILED: 删不掉 $STATE"; return 1; fi
    return 0
}

# 装一个**新一代**看门狗（只有 open 用；renew 不走这里）
arm() {
    _secs=$1
    _tok=$(new_token)
    write_state "$(( $(now) + _secs ))" "$_tok" || { echo "ARM_FAILED: 写不了 $STATE"; return 1; }

    nohup sh -c '
        STATE="$1"; LOG="$2"; POLL="$3"; PIDFILE="$4"; SELF="$5"; MYTOK="$6"
        printf "%s %s\n" "$$" "$MYTOK" > "$PIDFILE"
        # 只在 PID 文件仍归自己时才删（否则会删掉新一代的）
        trap "[ \"$(cut -d\" \" -f2 \"$PIDFILE\" 2>/dev/null)\" = \"$MYTOK\" ] && rm -f \"$PIDFILE\"" EXIT
        while [ -f "$STATE" ]; do
            _d=$(cut -d" " -f1 "$STATE" 2>/dev/null)
            _t=$(cut -d" " -f2 "$STATE" 2>/dev/null)
            [ -n "$_d" ] || break
            # 状态已归别人（有更新一代接管）→ 安静退出，不关任何东西
            [ "$_t" = "$MYTOK" ] || {
                echo "$(date "+%Y-%m-%d %H:%M:%S") WATCHDOG_SUPERSEDED: 状态已归新一代，本代退出" >>"$LOG"
                exit 0
            }
            if [ "$(date +%s)" -ge "$_d" ]; then
                # ⚠️ 只有**确认关闭成功**才退出（codex plan-R12）。
                #    close-loop 外面包着 flock 等待，并发的 close 完全可能持锁超过
                #    LOCK_WAIT（它每轮 reset 30 秒 + status 30 秒，而限时只算退避）。
                #    早先写成 `exit $?` —— 拿不到锁就退出、EXIT 陷阱顺手清掉 PID 文件，
                #    于是「状态还 armed、端点可能还开着，却没有看门狗再去重试」，
                #    正好推翻手册里「关闭失败时看门狗仍在重试」那句话。
                #    现在：任何非 0 都不退出，只要 STATE 还在且归属仍是自己就继续重试
                #    （循环条件与令牌检查负责真正的退出）。
                "$SELF" close-loop 0
                _rc=$?
                [ "$_rc" -eq 0 ] && exit 0
                echo "$(date "+%Y-%m-%d %H:%M:%S") WATCHDOG_KEEPS_TRYING: close-loop rc=${_rc}（锁被占或归属有变）—— 仍持有归属，不退出" >>"$LOG"
                sleep "$POLL"
                continue
            fi
            sleep "$POLL"
        done
        echo "$(date "+%Y-%m-%d %H:%M:%S") WATCHDOG_DISARMED: 状态文件已移除，未执行关闭" >>"$LOG"
    ' _ "$STATE" "$LOG" "$POLL" "$PIDFILE" "$SELF" "$_tok" >/dev/null 2>&1 &

    sleep 1
    if ! watchdog_owns_state; then
        echo "ARM_FAILED: 看门狗没起来或归属对不上"
        disarm
        return 1
    fi
    echo "WATCHDOG_ARMED 到期时刻=$(date -d "@$(state_deadline)" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || state_deadline)"
    return 0
}

# 需要串行化的子命令：若还没持锁，就先拿锁再把自己重跑一遍。
# EXPOSE_LOCK_HELD 由持锁的那一层设置，避免自己等自己（重入死锁）。
case "${1:-}" in
open|renew|close|close-loop|boot-close)
    if [ "${EXPOSE_LOCK_HELD:-0}" != "1" ]; then
        # ⚠️ 不要写成 `if ! cmd; then _rc=$?` —— 在 `!` 取反之后 `$?` 是**取反的结果**（0），
        #    不是命令本身的退出码。锁超时会因此被吞成 exit 0（又一次「把失败读成成功」，
        #    自测时抓到的）。故：先无条件跑、立刻取 $?、再判断。
        # `-E 99` 让「没拿到锁」有一个**专属**退出码，不与子命令自身的 1 混淆。
        EXPOSE_LOCK_HELD=1 flock -w "$LOCK_WAIT" -E 99 "$LOCKFILE" "$SELF" "$@"
        _rc=$?
        if [ "$_rc" -eq 99 ]; then
            echo "LOCK_TIMEOUT: ${LOCK_WAIT} 秒内没拿到互斥锁（另有一个 open/close/boot-close 在跑）—— 本次什么都没做"
        fi
        exit "$_rc"
    fi
    ;;
esac

case "${1:-}" in
boot-guard-status)
    assert_self_path_sane || exit 1
    # ⚠️ 为什么必须有开机守卫（codex plan-R7 F2）：超时看门狗是 /tmp 里的状态文件
    #    加一个进程，而 tailscale 的 serve 配置是**持久**的。NAS 一重启，守卫没了、
    #    端点却回来了 —— 正好回到「零认证端点无人看管地一直开着」这个本要防的状态。
    #    这条 @reboot 让开机时**无条件关闭**：真在验收中途重启，重跑一次 open 即可。
    if boot_guard_installed; then
        echo "守卫文件: $BOOT_GUARD_FILE"
        sed 's/^/  /' "$BOOT_GUARD_FILE"
        echo "BOOT_GUARD_OK"
    else
        echo "BOOT_GUARD_MISSING: $BOOT_GUARD_FILE 不存在，或内容里没有 boot-close"
        echo
        print_boot_guard_install
        exit 1
    fi
    ;;
show-boot-guard-install)
    assert_self_path_sane || exit 1
    print_boot_guard_install
    ;;
show-boot-guard-remove)
    print_boot_guard_remove
    ;;

open)
    _secs=${2:-}
    case "$_secs" in ''|*[!0-9]*) echo "USAGE: expose.sh open <秒>"; exit 2 ;; esac
    # ⚠️ 拒绝 0 与过短窗口（codex plan-R9 F1）：看门狗会在 serve 真正落配置**之前**
    #    就到期，此刻读到的确实是 No serve config → 它「确认关闭成功」、删状态、退出；
    #    随后端点才被开出来，却已经没有看门狗看着。
    if [ "$_secs" -lt "$MIN_SECS" ]; then
        echo "REFUSING_TO_OPEN: 窗口至少 ${MIN_SECS} 秒（给的是 ${_secs}）"
        exit 2
    fi
    # ⚠️ 次序是判据的一部分：两道关闭保证都装好，才允许开端点。
    if ! boot_guard_installed; then
        echo "REFUSING_TO_OPEN: 开机守卫没装 —— 先跑 '$SELF show-boot-guard-install' 按提示装好再来"
        exit 1
    fi
    arm "$_secs" || { echo "REFUSING_TO_OPEN: 看门狗没装上，不开端点"; exit 1; }

    _out=$(ts serve --bg --https=443 "$UPSTREAM" 2>&1); _rc=$?
    if [ "$_rc" -ne 0 ]; then
        printf '%s\n' "$_out"
        if printf '%s' "$_out" | grep -qi 'Serve is not enabled'; then
            echo "SERVE_FAILED: tailnet 还没开启 **Serve 功能**（与 HTTPS 证书是两个开关）"
        elif printf '%s' "$_out" | grep -qi 'cert\|HTTPS'; then
            echo "SERVE_FAILED: tailnet 还没开启 **HTTPS 证书**"
        else
            echo "SERVE_FAILED: 端点没开成（rc=$_rc）"
        fi
        # ⚠️ **绝不在这里直接 disarm**（codex plan-R8 F1）：`serve --bg` 有可能
        #    **先落了配置再超时/非零退出** —— 此刻端点是否存在并不确定。
        #    正确做法是把到期时间设成「现在」，让看门狗接手「关到确认为止」。
        expire_to_watchdog
        echo "请随后跑 expose.sh status 复核"
        exit 1
    fi

    # ⚠️ 分开取输出与退出码（codex plan-R7 F3）：原来是 `ts serve status | grep -qi funnel`，
    #    status 命令本身失败时「没匹配到 funnel」会被当成「没有 funnel」，于是一路走到
    #    EXPOSE_OK —— 把失败读成了成功。零认证的端点上这尤其危险。
    _st=$(ts serve status 2>&1); _strc=$?
    if [ "$_strc" -ne 0 ]; then
        echo "STATUS_UNVERIFIABLE: 开完之后读不到 serve 状态（rc=$_strc）—— 失败关闭"
        printf '%s\n' "$_st"
        expire_to_watchdog
        echo "请随后跑 expose.sh status 复核"
        exit 1
    fi
    if ! _why=$(serve_status_is_expected "$_st"); then
        echo "$_why: serve 配置不是预期形态 —— 失败关闭"
        printf '%s\n' "$_st"
        expire_to_watchdog
        echo "请随后跑 expose.sh status 复核"
        exit 1
    fi
    printf '%s\n' "$_st"
    # ⚠️ 打印成功之前**再复核一次归属**（codex plan-R9 F1）：端点已经开出来了，
    #    此刻必须证明「确实有一个活着的看门狗，且它就是当前状态的归属者」。
    if ! watchdog_owns_state; then
        echo "WATCHDOG_LOST: 端点已开但看门狗不在（或归属对不上）—— 立即关闭"
        if close_loop 120; then
            echo "已确认关闭；请重跑 open"
        else
            echo "⚠️ 未能确认关闭，请立刻查 $LOG 并手动跑 expose.sh close"
        fi
        exit 1
    fi
    echo "EXPOSE_OK"
    ;;
status)
    echo "--- serve status ---"
    _st=$(ts serve status 2>&1); _strc=$?
    printf '%s\n' "$_st"
    [ "$_strc" -ne 0 ] && echo "⚠️ STATUS_UNVERIFIABLE: 读不到 serve 状态（rc=$_strc）—— 别当成「没开」"
    echo "--- watchdog ---"
    if [ -f "$STATE" ]; then
        echo "WATCHDOG_ARMED 剩余秒数=$(( $(state_deadline) - $(now) ))"
        if watchdog_owns_state; then
            echo "WATCHDOG_OWNS_STATE pid=$(pid_of)"
        else
            echo "WATCHDOG_OWNERSHIP_LOST: 状态文件在但没有归属明确的活看门狗 —— 立刻跑 expose.sh close"
        fi
    else
        echo "WATCHDOG_ABSENT"
    fi
    echo "--- boot guard ---"
    if boot_guard_installed; then echo "BOOT_GUARD_INSTALLED ($BOOT_GUARD_FILE)"; else echo "BOOT_GUARD_MISSING: 跑 show-boot-guard-install 看怎么装"; fi
    echo "--- 日志 ---"
    if [ -f "$LOG" ]; then tail -3 "$LOG"; else echo "(无)"; fi
    echo "STATUS_DONE"
    ;;
renew)
    _secs=${2:-}
    case "$_secs" in ''|*[!0-9]*) echo "USAGE: expose.sh renew <秒>"; exit 2 ;; esac
    if [ "$_secs" -lt "$MIN_SECS" ]; then echo "RENEW_REFUSED: 窗口至少 ${MIN_SECS} 秒"; exit 2; fi
    # ⚠️ 续期**不重启看门狗**（codex plan-R9 F2）：早先 renew 走 arm —— 删状态 + 起新进程，
    #    新旧两代共用一个 PID 文件且各自无条件删它，旧的退出会删掉新的，
    #    连锁导致「端点开着、一个看门狗都没有」。
    #    现在只**原子替换到期时间**，令牌不变，进程不动。
    if watchdog_owns_state; then
        _tok=$(state_token)
        write_state "$(( $(now) + _secs ))" "$_tok" || { echo "RENEW_FAILED: 写不了状态"; exit 1; }
        if watchdog_owns_state; then
            echo "RENEW_OK 新到期时刻=$(date -d "@$(state_deadline)" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || state_deadline)"
        else
            echo "RENEW_FAILED: 写完之后归属对不上"; exit 1
        fi
    else
        # 证明不了归属 = 端点可能开着却没人管 → **同步关闭**，不能只报个失败就走
        echo "RENEW_FAILED: 当前没有归属明确的看门狗 —— 立即关闭以免端点无人看管"
        if close_loop 120; then echo "已确认关闭；要继续验收请重跑 open"; else echo "⚠️ 未能确认关闭，请查 $LOG"; fi
        exit 1
    fi
    ;;
close)
    # 走**唯一**的关闭实现：最多重试 120 秒，只有确认 No serve config 才算成功。
    # ⚠️ 刻意不再「先 disarm 再关」—— 确认关上之前撤掉看门狗，就是把最后一道保证
    #    在最需要它的时候拆掉（codex plan-R8）。close_loop 确认成功时才删状态文件。
    if close_loop 120; then
        echo "CLOSE_OK"
    else
        echo "CLOSE_FAILED: 120 秒内未能确认 No serve config —— 看门狗仍 armed 并继续重试；请查 $LOG"
        exit 1
    fi
    ;;
close-loop)
    _lim=${2:-0}
    case "$_lim" in ''|*[!0-9]*) echo "USAGE: expose.sh close-loop <秒|0>"; exit 2 ;; esac
    if close_loop "$_lim"; then echo "CLOSE_CONFIRMED"; else echo "CLOSE_UNCONFIRMED"; exit 1; fi
    ;;
boot-close)
    # ⚠️ 开机守卫不能「跑一次 close 就完事」（codex plan-R8 F2）：cron 的 @reboot
    #    可能跑在 docker / tailscale 容器起来**之前**，那次必然失败而 serve 配置是持久的，
    #    端点随后就自己回来了、却已经没人管。
    #    故：先等就绪（最多 15 分钟），再走 close_loop（最多 24 小时，退避封顶 60 秒）。
    echo "$(stamp) BOOT_GUARD: 开机守卫启动，等待 docker/tailscale 就绪" >>"$LOG"
    if wait_ready 900; then
        echo "$(stamp) BOOT_GUARD: 依赖已就绪，开始关闭" >>"$LOG"
    else
        echo "$(stamp) BOOT_GUARD: 等待 15 分钟仍未就绪，仍然进入关闭重试" >>"$LOG"
    fi
    if close_loop 86400; then
        echo "$(stamp) BOOT_GUARD_DONE: 已确认 No serve config" >>"$LOG"
    else
        echo "$(stamp) BOOT_GUARD_FAILED: 24 小时内未能确认关闭 —— 需人工处理" >>"$LOG"
        exit 1
    fi
    ;;
selftest)
    # 判据自检：喂合成文本，证明 serve_status_is_expected 两个方向都有判别力。
    # 不碰真实端点，可随时跑。
    _fail=0
    _chk() { # 期望结果 描述 文本
        _want=$1; _desc=$2; _txt=$3
        if _got=$(serve_status_is_expected "$_txt"); then _got=OK; fi
        if [ "$_got" = "$_want" ]; then echo "  pass  $_desc"; else echo "  FAIL  $_desc（期望 $_want，实际 $_got）"; _fail=1; fi
    }
    echo "serve_status_is_expected 自检："
    _chk OK                        "正常 serve 配置（含 8010）" \
        "https://fnos.tail9dc815.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8010"
    _chk FUNNEL_DETECTED           "出现 funnel（必须拒）" \
        "https://fnos.tail9dc815.ts.net (Funnel on)
|-- / proxy http://127.0.0.1:8010"
    _chk SERVE_TARGET_UNCONFIRMED  "空输出（命令失败的典型形态，必须拒）" ""
    _chk SERVE_TARGET_UNCONFIRMED  "反代到了别的端口（必须拒）" \
        "https://fnos.tail9dc815.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:9999"
    _chk SERVE_TARGET_UNCONFIRMED  "No serve config（还没开，必须拒）" "No serve config"
    echo "状态文件读写自检（守住 R10 那个令牌丢失回归）："
    (
        STATE=/tmp/kline-trainer-expose.selftest.$$
        _tok="TOKEN-XYZ"
        write_state 1234567890 "$_tok" || true
        _d1=$(state_deadline); _t1=$(state_token)
        # 模拟「立即到期」那一步：必须把令牌原样带过去
        write_state 999 "$(state_token)" || true
        _d2=$(state_deadline); _t2=$(state_token)
        rm -f "$STATE" "${STATE}.tmp"
        _ok=1
        [ "$_d1" = "1234567890" ] && [ "$_t1" = "$_tok" ] || _ok=0
        [ "$_d2" = "999" ] && [ "$_t2" = "$_tok" ] || _ok=0
        if [ "$_ok" -eq 1 ]; then echo "  pass  写入/读回两字段，且立即到期后令牌不丢"; else
            echo "  FAIL  两字段读写不正确（d1=$_d1 t1=$_t1 d2=$_d2 t2=$_t2）"; exit 1; fi
    ) || _fail=1
    echo "cut 陷阱自检："
    (
        STATE=/tmp/kline-trainer-expose.selftest2.$$
        printf '%s\n' "1234567890" > "$STATE"       # 只写一个字段（就是那个 bug 的形状）
        _t=$(state_token); rm -f "$STATE"
        if [ "$_t" = "1234567890" ]; then
            echo "  pass  确认 cut 在无分隔符时返回整行 —— 所以「只写时间戳」会让令牌变成时间戳"
        else
            echo "  FAIL  cut 行为与预期不符（拿到 [$_t]）"; exit 1
        fi
    ) || _fail=1
    if [ "$_fail" -eq 0 ]; then echo "SELFTEST_PASS"; else echo "SELFTEST_FAIL"; exit 1; fi
    ;;
*)
    echo "USAGE: expose.sh {boot-guard-status|show-boot-guard-install|show-boot-guard-remove|open <秒>|status|renew <秒>|close|selftest|close-loop <秒>|boot-close}"
    exit 2
    ;;
esac
