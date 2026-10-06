#!/bin/bash
# 验证 CMA 碎片化假设：gfp_tune（允许规整/重试）+ 关闭超配
O=/home/greatwall/cmadefrag.txt
P=/sys/module/phytium_npu/parameters
{
echo "########## CMA-DEFRAG $(date +%H:%M:%S) ##########"
echo "=== 当前相关参数 ==="
for K in vha_gfp_tune vha_overalloc_mul vha_overalloc_min vha_overalloc_exact vha_overalloc_report; do
  printf "  %-24s = %s\n" $K "$(cat $P/$K 2>/dev/null || echo '(无)')"
done
run_case () {
  echo "-------------------- $1 --------------------"
  sudo dmesg -n 1
  sudo systemctl restart npusvc; sleep 5
  sudo dmesg -C
  cd /opt/npu/python
  MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=sv NPU_SOCK=/run/npu/npu.sock \
      timeout 120 python3 -u /tmp/mb_client.py 2>&1 | grep -aE "load ->|infer" | head -3
  cd /
  A=$(sudo dmesg | grep -ac "cmd=0xc0207102")
  E=$(sudo grep -ac "Cannot allocate vha memory for TEMPORARY" /var/log/npuworker.log)
  echo "    ALLOC次数=$A   TEMPORARY失败(累计)=$E"
  echo "    CMA: $(grep -E 'CmaFree' /proc/meminfo | tr -d ' ')"
  echo "    提交=$(sudo dmesg | grep -ac 'VHA-TD-A] before:')"
}
echo 0 | sudo tee $P/vha_gfp_tune >/dev/null; echo 1 | sudo tee $P/vha_overalloc_mul >/dev/null
sudo sh -c ': > /var/log/npuworker.log'
run_case "基线：gfp_tune=0 无超配"
echo 1 | sudo tee $P/vha_gfp_tune >/dev/null
run_case "gfp_tune=1 (RETRY_MAYFAIL 允许规整)"
echo 2 | sudo tee $P/vha_gfp_tune >/dev/null
run_case "gfp_tune=2 (RETRY_MAYFAIL|NORETRY)"
} > $O 2>&1
cat $O
