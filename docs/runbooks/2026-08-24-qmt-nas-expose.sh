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
#      ② **开机守卫**（crontab @reboot）：NAS 一重启就无条件关闭。
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
#   expose.sh install-boot-guard   装开机守卫（幂等），open 的前置
#   expose.sh remove-boot-guard    卸开机守卫
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
BOOT_TAG="kline-trainer-boot-guard"

SELF=$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")

ts() { timeout 30 docker exec -i "$TS_CTR" tailscale "$@" </dev/null; }
now() { date +%s; }

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

watchdog_running() {
    [ -f "$PIDFILE" ] || return 1
    _wp=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$_wp" ] && kill -0 "$_wp" 2>/dev/null
}

boot_guard_installed() { crontab -l 2>/dev/null | grep -q "$BOOT_TAG"; }

stamp() { date '+%Y-%m-%d %H:%M:%S'; }

# 等 docker 与 tailscale 容器就绪（开机时 cron 可能跑在它们起来之前）。
# 返回 0 = 就绪；非 0 = 等到超时仍不就绪。
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
#    确认成功时顺手删掉看门狗状态文件（此时才算真的可以撤）。
close_loop() {
    _limit=$1; _t=0; _try=0
    while : ; do
        _try=$((_try + 1))
        timeout 30 docker exec -i "$TS_CTR" tailscale serve reset </dev/null >>"$LOG" 2>&1
        _s=$(timeout 30 docker exec -i "$TS_CTR" tailscale serve status </dev/null 2>&1); _rc=$?
        if [ "$_rc" -eq 0 ] && printf '%s' "$_s" | grep -q 'No serve config'; then
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

disarm() {
    rm -f "$STATE"
    if [ -f "$STATE" ]; then echo "DISARM_FAILED: 删不掉 $STATE"; return 1; fi
    return 0
}

arm() {
    _secs=$1
    disarm || return 1
    printf '%s\n' "$(( $(now) + _secs ))" > "$STATE"
    [ -f "$STATE" ] || { echo "ARM_FAILED: 写不了 $STATE"; return 1; }

    # ⚠️ 到点后**关到确认为止**（codex plan-R7 F1）：原来是「跑一次 reset 就宣告成功、
    #    删状态文件、退出」——若 docker/tailscale 当时不可用、reset 非零退出、或命令挂住，
    #    端点仍开着而看门狗已经没了。现在：带超时地重试，退避，**只有 status 确认
    #    `No serve config` 才算数**；确认前绝不删状态文件、绝不退出。
    nohup sh -c '
        STATE="$1"; LOG="$2"; POLL="$3"; PIDFILE="$4"; SELF="$5"
        echo $$ > "$PIDFILE"
        trap "rm -f \"$PIDFILE\"" EXIT
        while [ -f "$STATE" ]; do
            _d=$(cat "$STATE" 2>/dev/null)
            [ -n "$_d" ] || break
            if [ "$(date +%s)" -ge "$_d" ]; then
                # 到期 → 交给**唯一**的关闭实现，不限时、关到确认为止。
                # 它确认成功时会自己删掉状态文件，本循环随即退出。
                "$SELF" close-loop 0
                exit $?
            fi
            sleep "$POLL"
        done
        echo "$(date "+%Y-%m-%d %H:%M:%S") WATCHDOG_DISARMED: 状态文件已移除，未执行关闭" >>"$LOG"
    ' _ "$STATE" "$LOG" "$POLL" "$PIDFILE" "$SELF" >/dev/null 2>&1 &

    sleep 1
    if [ ! -f "$STATE" ]; then echo "ARM_FAILED: 状态文件不见了"; return 1; fi
    if ! watchdog_running; then echo "ARM_FAILED: 看门狗进程没起来"; disarm; return 1; fi
    echo "WATCHDOG_ARMED 到期时刻=$(date -d "@$(cat "$STATE")" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || cat "$STATE")"
    return 0
}

case "${1:-}" in
install-boot-guard)
    # ⚠️ 为什么必须有它（codex plan-R7 F2）：看门狗是 /tmp 里的状态文件 + 一个进程，
    #    而 tailscale 的 serve 配置是**持久**的。NAS 一重启，守卫没了、端点却回来了 ——
    #    正好回到「零认证端点无人看管地一直开着」这个本要防的状态。
    #    这条 @reboot 让开机时**无条件关闭**（失败关闭）：真在验收中途重启，
    #    重新跑一次 open 即可。
    if boot_guard_installed; then
        echo "BOOT_GUARD_ALREADY_INSTALLED"
    else
        ( crontab -l 2>/dev/null; printf '@reboot %s boot-close >>%s 2>&1 &  # %s\n' "$SELF" "$LOG" "$BOOT_TAG" ) | crontab -
    fi
    if boot_guard_installed; then
        crontab -l 2>/dev/null | grep "$BOOT_TAG"
        echo "BOOT_GUARD_OK"
    else
        echo "BOOT_GUARD_INSTALL_FAILED"
        exit 1
    fi
    ;;
remove-boot-guard)
    crontab -l 2>/dev/null | grep -v "$BOOT_TAG" | crontab - 2>/dev/null || crontab -r 2>/dev/null || true
    if boot_guard_installed; then echo "BOOT_GUARD_REMOVE_FAILED"; exit 1; fi
    echo "BOOT_GUARD_REMOVED"
    ;;
open)
    _secs=${2:-}
    case "$_secs" in ''|*[!0-9]*) echo "USAGE: expose.sh open <秒>"; exit 2 ;; esac
    # ⚠️ 次序是判据的一部分：两道关闭保证都装好，才允许开端点。
    if ! boot_guard_installed; then
        echo "REFUSING_TO_OPEN: 开机守卫没装（先跑 install-boot-guard）"
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
        printf '%s\n' "$(now)" > "$STATE"
        echo "已把关闭交还看门狗（它会重试直到确认 No serve config）；请随后跑 expose.sh status 复核"
        exit 1
    fi

    # ⚠️ 分开取输出与退出码（codex plan-R7 F3）：原来是 `ts serve status | grep -qi funnel`，
    #    status 命令本身失败时「没匹配到 funnel」会被当成「没有 funnel」，于是一路走到
    #    EXPOSE_OK —— 把失败读成了成功。零认证的端点上这尤其危险。
    _st=$(ts serve status 2>&1); _strc=$?
    if [ "$_strc" -ne 0 ]; then
        echo "STATUS_UNVERIFIABLE: 开完之后读不到 serve 状态（rc=$_strc）—— 失败关闭"
        printf '%s\n' "$_st"
        printf '%s\n' "$(now)" > "$STATE"
        echo "已把关闭交还看门狗（关到确认为止）；请随后跑 expose.sh status 复核"
        exit 1
    fi
    if ! _why=$(serve_status_is_expected "$_st"); then
        echo "$_why: serve 配置不是预期形态 —— 失败关闭"
        printf '%s\n' "$_st"
        printf '%s\n' "$(now)" > "$STATE"
        echo "已把关闭交还看门狗（关到确认为止）；请随后跑 expose.sh status 复核"
        exit 1
    fi
    printf '%s\n' "$_st"
    echo "EXPOSE_OK"
    ;;
status)
    echo "--- serve status ---"
    _st=$(ts serve status 2>&1); _strc=$?
    printf '%s\n' "$_st"
    [ "$_strc" -ne 0 ] && echo "⚠️ STATUS_UNVERIFIABLE: 读不到 serve 状态（rc=$_strc）—— 别当成「没开」"
    echo "--- watchdog ---"
    if [ -f "$STATE" ]; then
        echo "WATCHDOG_ARMED 剩余秒数=$(( $(cat "$STATE") - $(now) ))"
        if watchdog_running; then
            echo "WATCHDOG_PROCESS_ALIVE"
        else
            echo "WATCHDOG_PROCESS_MISSING: 状态文件在但进程没了 —— 立刻跑 expose.sh close"
        fi
    else
        echo "WATCHDOG_ABSENT"
    fi
    echo "--- boot guard ---"
    if boot_guard_installed; then echo "BOOT_GUARD_INSTALLED"; else echo "BOOT_GUARD_MISSING"; fi
    echo "--- 日志 ---"
    if [ -f "$LOG" ]; then tail -3 "$LOG"; else echo "(无)"; fi
    echo "STATUS_DONE"
    ;;
renew)
    _secs=${2:-}
    case "$_secs" in ''|*[!0-9]*) echo "USAGE: expose.sh renew <秒>"; exit 2 ;; esac
    arm "$_secs" || { echo "RENEW_FAILED"; exit 1; }
    echo "RENEW_OK"
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
    if [ "$_fail" -eq 0 ]; then echo "SELFTEST_PASS"; else echo "SELFTEST_FAIL"; exit 1; fi
    ;;
*)
    echo "USAGE: expose.sh {install-boot-guard|remove-boot-guard|open <秒>|status|renew <秒>|close|selftest|close-loop <秒>|boot-close}"
    exit 2
    ;;
esac
