#!/bin/bash
# 【重启后第一个跑这个】
# 干净启动 → 设参 → 跑 sensevoice → 全程盯着 D 状态，卡住那一刻自动取证
O=/home/greatwall/first_sv.txt
P=/sys/module/phytium_npu/parameters
{
echo "############ 干净启动后的首次 SenseVoice 取证 $(date +%H:%M:%S) ############"
echo "=== 0. 起始状态 ==="
echo "  开机时长: $(cut -d. -f1 /proc/uptime) s"
echo "  残留 npuworker: $(pgrep -x npuworker | tr '\n' ' ')(应为空)"
ps -eo pid,stat,comm | grep -E "npuworker|npusvc" | head -5
grep -iE "^Cma" /proc/meminfo
echo "  全系统 D 状态数: $(ps -eo stat | grep -c '^D')"

echo "=== 1. sysfs 设参（只走我们推送，不跑任何其他模型） ==="
sudo systemctl stop npusvc 2>/dev/null; sleep 3
set_p() { sudo sh -c "echo $2 > $P/$1"; }
set_p vha_sim_mode 0
set_p vha_resp_fix 0
set_p vha_vrsp_skip 1
set_p vha_push_enable 1
set_p vha_rsp_slot 1
set_p vha_rsp_slot_step 0
set_p vha_rsp_slot_max 0
set_p vha_rsp_replay 6
set_p vha_rsp_replay_ms 100
set_p vha_settle_ms 0
echo "  参数: resp_fix=$(cat $P/vha_resp_fix) vrsp_skip=$(cat $P/vha_vrsp_skip) push=$(cat $P/vha_push_enable) replay=$(cat $P/vha_rsp_replay)"

echo "=== 2. 启动服务 + 开跑 sensevoice（后台） ==="
sudo systemctl restart npusvc; sleep 7
sudo dmesg -C
cd /opt/npu/python
NPU_SOCK=/run/npu/npu.sock nohup timeout 180 python3 /tmp/sv_pool.py > /tmp/svfirst_client.txt 2>&1 &
CL=$!
echo "  客户端 pid=$CL"

echo "=== 3. 盯着 D 状态（每 5s 采一次，最多 36 次） ==="
JAMMED=""
for i in $(seq 1 36); do
  sleep 5
  D=$(ps -eo pid,stat,comm | awk '$2 ~ /D/ && $3 ~ /npuworker/ {print $1}' | head -1)
  if [ -n "$D" ]; then
    JAMMED=$D
    echo "  ★ 第 ${i} 次采样发现 D 状态 worker pid=$D  (t≈$((i*5))s)"
    break
  fi
  if ! kill -0 $CL 2>/dev/null; then echo "  客户端已退出（第 ${i} 次采样, t≈$((i*5))s）"; break; fi
done

echo "=== 4. 取证 ==="
if [ -n "$JAMMED" ]; then
  echo "--- 4.1 内核栈 /proc/$JAMMED/stack ---"
  sudo cat /proc/$JAMMED/stack 2>/dev/null | head -14
  echo "--- 4.2 wchan ---"
  sudo cat /proc/$JAMMED/wchan 2>/dev/null; echo
  echo "--- 4.3 正在执行的系统调用 /proc/$JAMMED/syscall ---"
  sudo cat /proc/$JAMMED/syscall 2>/dev/null
  echo "  （第1字段=29 表示 ioctl；第3字段=命令号）"
  echo "--- 4.4 未完成的 VHA 分配（最后 12 条 dmesg） ---"
  sudo dmesg | grep -aE "VHA-ALLOC|VHA-REALFREE|alloc#" | tail -12
  echo "--- 4.5 VHA-ALLOC-DIAG（最后 6 条） ---"
  sudo dmesg | grep -a "VHA-ALLOC-DIAG" | tail -6
  echo "--- 4.6 此刻 CMA ---"
  grep -iE "^Cma" /proc/meminfo
  echo "--- 4.7 全部 D 状态进程 ---"
  ps -eo pid,stat,comm | awk '$2 ~ /D/' | head -12
else
  echo "  未发现 D 状态"
fi

echo "=== 5. 客户端结果 ==="
head -14 /tmp/svfirst_client.txt 2>/dev/null
echo "=== 6. 服务端结果 ==="
sudo journalctl -u npusvc --no-pager -n 6 | tail -6
echo "=== 7. worker 日志（有无 ERROR） ==="
sudo grep -acE "ERROR" /var/log/npuworker.log 2>/dev/null
sudo tail -6 /var/log/npuworker.log 2>/dev/null
kill $CL 2>/dev/null
cd /
} > $O 2>&1
cat $O
