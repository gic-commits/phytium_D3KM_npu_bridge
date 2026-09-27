#!/bin/bash
# npu 服务冒烟自检（可 cron / 手工）：判活 + 真推理一帧 + 判数值 + 清残留
# 退出码：0=健康 1=服务没起 2=推理失败 3=数值不对
SOCK=/tmp/npu.sock
G=/dev/shm/nputest/20210828122250_3b289.jpg
CLI=/dev/shm/nputest/svc/npu_cli
[ -x "$CLI" ] || CLI=npu_cli
m=$(date '+%F %T')
pgrep -x npusvc_pool >/dev/null || { echo "$m FAIL 服务未运行"; exit 1; }
st=$(timeout 20 "$CLI" status 2>&1 | tr '\n' ' ')
echo "$m STATUS $st" | cut -c1-160
out=$(timeout 60 "$CLI" face yunet_npu "$G" 112 112 0 2>&1 | tail -2 | tr '\n' ' ')
echo "$m FACE $out" | cut -c1-160
echo "$out" | grep -q "检出 1 张脸" || { echo "$m FAIL 推理结果异常"; exit 2; }
echo "$out" | grep -qE "score=0\.9[0-9]{3}" || { echo "$m FAIL 置信度异常"; exit 3; }
w=$(timeout 20 "$CLI" status 2>&1 | grep -E "WORKER_TIMEOUTS|ERRS" | tr '\n' ' ')
echo "$m OK  $w"
exit 0
