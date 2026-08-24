#!/bin/sh
# docs/runbooks/2026-08-24-qmt-nas-expose.sh
#
# 管理 P12–P16 的「对外暴露窗口」。在 NAS 上执行。
#
# 为什么需要它（codex plan-R6 high）：`tailscale serve --bg` 是**持久**配置，
# 与开它的那个 ssh 会话无关。而本 API **零认证** —— spec §11-R8「本次不加认证」
# 这个决定的四个成立前提里，第四条就是「暴露窗口仅限验收期间、用完即关」。
# 原来的写法把关闭（P16）交给一条人工嘱咐：断线、临时有事、中途某步失败，
# 端点就会一直开着。一句嘱咐撑不起那个前提。
#
# ⚠️ 评审建议的「把开端点和整个验收流程包进带 EXIT/INT/TERM 陷阱的脚本」在本场景
#    **不可实现**：P13/P14 是人在手机上肉眼验收的步骤，可能持续几十分钟到几天；
#    脚本一退出陷阱就触发，会在正用着的时候把端点关掉。
#    可实现的等价保护 = **超时自动关闭的看门狗**：装不上就拒绝开端点；到点自动关；
#    提前做完就由 close 提前关（幂等）。
#
# ⚠️ 看门狗**不靠「被 kill」来撤销**（2026-08-24 实测的教训）：早先那版是
#    `sleep N; reset`，撤销靠 kill 那个进程 —— 实测发现脚本直接跑时 kill 有效，
#    被接进管道（`... | tail -2`）跑时**同一份代码却杀不掉，看门狗照样到点触发**。
#    与其追查 shell 交互细节，不如换掉机制：现在看门狗**轮询状态文件**，
#    撤销 = 删掉那个文件（原子，且删完能直接验证）。
#    误触发的方向本来就是安全的（提前关、不会漏关），但陈旧看门狗会在下一个窗口
#    里乱关，所以必须能可靠撤销。
#
# 用法：
#   expose.sh open <秒>   先装看门狗，装不上就拒绝开；装上了再开端点
#   expose.sh status      看端点状态与看门狗剩余时间
#   expose.sh renew <秒>  验收超时前续期
#   expose.sh close       关端点 + 撤看门狗（幂等，任何路径都该跑）
#
# ⚠️ 已知残留：NAS **重启**会杀掉看门狗进程，而 tailscale 的 serve 配置是持久的
#    → 重启后端点会自己回来、却没有看门狗看着。status 会把这种「状态文件在但进程
#    没了」的情况显式报出来。NAS 一旦重启，立刻跑一次 status；不在验收期间就 close。

set -u

TS_CTR=tailscale
STATE=/tmp/kline-trainer-expose.deadline
LOG=/tmp/kline-trainer-expose.log
PIDFILE=/tmp/kline-trainer-expose.pid
UPSTREAM=http://127.0.0.1:8010
POLL=5

# ⚠️ 必须带超时 + </dev/null（2026-08-24 实测）：tailnet 没开 Serve 功能时，
#    `tailscale serve` **不会快速失败**，它会打印一个开通链接然后**一直等交互**。
#    没有超时的话整条命令会挂死，而挂死期间到底开没开出端点是看不出来的。
ts() { timeout 30 docker exec -i "$TS_CTR" tailscale "$@" </dev/null; }

now() { date +%s; }

# ⚠️ 刻意**不用** `pgrep -f <路径>` 判断看门狗是否活着（2026-08-24 踩到）：
#    `pgrep -f` 会把**调用它的那条命令行自己**也匹配上（命令行里含同样的字符串），
#    于是「看门狗已死」会被报成「还活着」—— 正是不安全的那个方向。
#    （同一个自匹配陷阱还让 `pkill -f "kline-trainer-expose"` 把 ssh 自身杀掉，
#     使清场命令只跑了第一行，一连几次观测因此全部失真。）
#    改成看门狗自己写 PID 文件，这里按 PID 判活，不会自匹配。
watchdog_running() {
    [ -f "$PIDFILE" ] || return 1
    _wp=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$_wp" ] && kill -0 "$_wp" 2>/dev/null
}

# 撤销 = 删状态文件。看门狗下一次轮询（≤POLL 秒）发现文件没了就自行退出、不执行关闭。
disarm() {
    rm -f "$STATE"
    if [ -f "$STATE" ]; then
        echo "DISARM_FAILED: 删不掉 $STATE"
        return 1
    fi
    return 0
}

arm() {
    _secs=$1
    disarm || return 1
    printf '%s\n' "$(( $(now) + _secs ))" > "$STATE"
    [ -f "$STATE" ] || { echo "ARM_FAILED: 写不了 $STATE"; return 1; }

    nohup sh -c '
        STATE="$1"; LOG="$2"; CTR="$3"; POLL="$4"; PIDFILE="$5"
        echo $$ > "$PIDFILE"
        trap "rm -f \"$PIDFILE\"" EXIT
        while [ -f "$STATE" ]; do
            _d=$(cat "$STATE" 2>/dev/null)
            [ -n "$_d" ] || break
            if [ "$(date +%s)" -ge "$_d" ]; then
                docker exec "$CTR" tailscale serve reset >>"$LOG" 2>&1
                echo "$(date "+%Y-%m-%d %H:%M:%S") WATCHDOG_FIRED: serve reset executed" >>"$LOG"
                rm -f "$STATE"
                exit 0
            fi
            sleep "$POLL"
        done
        echo "$(date "+%Y-%m-%d %H:%M:%S") WATCHDOG_DISARMED: 状态文件已移除，未执行关闭" >>"$LOG"
    ' _ "$STATE" "$LOG" "$TS_CTR" "$POLL" "$PIDFILE" >/dev/null 2>&1 &

    sleep 1
    # 自证两条都成立才算装上：状态文件在 + 看门狗进程真的起来了
    if [ ! -f "$STATE" ]; then echo "ARM_FAILED: 状态文件不见了"; return 1; fi
    if ! watchdog_running; then echo "ARM_FAILED: 看门狗进程没起来"; disarm; return 1; fi
    echo "WATCHDOG_ARMED 到期时刻=$(date -d "@$(cat "$STATE")" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || cat "$STATE")"
    return 0
}

case "${1:-}" in
open)
    _secs=${2:-}
    case "$_secs" in ''|*[!0-9]*) echo "USAGE: expose.sh open <秒>"; exit 2 ;; esac
    # ⚠️ 次序是判据的一部分：**先**装看门狗，装不上就绝不开端点。
    arm "$_secs" || { echo "REFUSING_TO_OPEN: 看门狗没装上，不开端点"; exit 1; }
    _out=$(ts serve --bg --https=443 "$UPSTREAM" 2>&1); _rc=$?
    if [ $_rc -ne 0 ]; then
        printf '%s\n' "$_out"
        # 实测过的两种前置缺失，报错文字不同，分开提示便于定位
        if printf '%s' "$_out" | grep -qi 'Serve is not enabled'; then
            echo "SERVE_FAILED: tailnet 还没开启 **Serve 功能**（与 HTTPS 证书是两个开关）"
        elif printf '%s' "$_out" | grep -qi 'cert\|HTTPS'; then
            echo "SERVE_FAILED: tailnet 还没开启 **HTTPS 证书**"
        else
            echo "SERVE_FAILED: 端点没开成（rc=$_rc）"
        fi
        if disarm; then echo "已撤掉看门狗，未开出任何端点"; else echo "⚠️ 看门狗未撤干净，请手动跑 expose.sh close"; fi
        exit 1
    fi
    # ⛔ funnel 硬禁令（spec §4-D1）：serve 只对本 tailnet 内部暴露，funnel 会暴露到公网。
    if ts serve status 2>&1 | grep -qi funnel; then
        echo "FUNNEL_DETECTED: 立刻关闭并中止"
        ts serve reset >/dev/null 2>&1
        disarm
        exit 1
    fi
    echo "EXPOSE_OK"
    ;;
status)
    echo "--- serve status ---"
    ts serve status 2>&1
    echo "--- watchdog ---"
    if [ -f "$STATE" ]; then
        echo "WATCHDOG_ARMED 剩余秒数=$(( $(cat "$STATE") - $(now) ))"
        if watchdog_running; then
            echo "WATCHDOG_PROCESS_ALIVE"
        else
            echo "WATCHDOG_PROCESS_MISSING: 状态文件在但进程没了（NAS 重启过？）—— 立刻跑 expose.sh close"
        fi
    else
        echo "WATCHDOG_ABSENT"
    fi
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
    _dis=0
    disarm || _dis=1
    ts serve reset >/dev/null 2>&1 || true
    _s=$(ts serve status 2>&1)
    printf '%s\n' "$_s"
    if [ "$_dis" -ne 0 ]; then
        echo "CLOSE_FAILED: 端点可能已关，但看门狗状态文件没删掉（见上面的 DISARM_FAILED）"
        exit 1
    fi
    if printf '%s' "$_s" | grep -q 'No serve config'; then
        echo "CLOSE_OK"
    else
        echo "CLOSE_FAILED: serve 配置没有回到 No serve config"
        exit 1
    fi
    ;;
*)
    echo "USAGE: expose.sh {open <秒>|status|renew <秒>|close}"
    exit 2
    ;;
esac
