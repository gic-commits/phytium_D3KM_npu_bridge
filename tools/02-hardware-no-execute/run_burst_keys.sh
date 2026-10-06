#!/bin/bash
# 每次提交推一串键（1..N），覆盖库可能等待的任意键
O=/home/greatwall/burst_keys.txt
P=/sys/module/phytium_npu/parameters
{
echo "########## BURST-KEYS $(date +%H:%M:%S) ##########"
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory'
echo 1  | sudo tee $P/vha_slot_reset_on_sync >/dev/null     # 每段复位 ⇒ 每串从 1 开始
echo 1  | sudo tee $P/vha_rsp_slot >/dev/null
echo 1  | sudo tee $P/vha_rsp_slot_step >/dev/null
echo 60 | sudo tee $P/vha_rsp_delay_ms >/dev/null            # 走延迟路径（replay 才生效）
echo 12 | sudo tee $P/vha_rsp_replay >/dev/null
echo 5  | sudo tee $P/vha_rsp_replay_ms >/dev/null
echo 0  | sudo tee $P/vha_replay_keep_slot >/dev/null        # 重放时键递增
echo 0  | sudo tee $P/vha_rsp_on_read >/dev/null
echo 1  | sudo tee $P/vha_slot_reset_on_open >/dev/null
sudo dmesg -n 1
sudo systemctl restart npusvc; sleep 5
sudo sh -c ': > /var/log/npuworker.log'
sudo dmesg -C
cd /opt/npu/python
echo "--- sensevoice（每段推 1..13）---"
MB_MODEL=sensevoice MB_SHAPE=1,200,560 MB_MODE=both MB_TAG=sv NPU_SOCK=/run/npu/npu.sock \
    timeout 200 python3 -u /tmp/mb_client.py 2>&1 | grep -aE "load ->|推理|infer" | head -4
cd /
echo "  提交=$(sudo dmesg | grep -ac 'VHA-TD-A] before:')  推送=$(sudo dmesg | grep -ac 'VHA-PUSHRSP')  库读=$(sudo dmesg | grep -ac 'VHA-READ')"
echo "  键序列: $(sudo dmesg | grep -a 'VHA-PUSHRSP' | sed 's/.*slot=/slot=/' | grep -a '^slot=' | head -30 | tr '\n' ' ')"
echo "  库读走的响应数=$(sudo dmesg | grep -ac 'VHA-READ')"
echo "  worker错误=$(sudo grep -acE 'ERROR|FATAL' /var/log/npuworker.log)  成功=$(sudo grep -ac 'INFER sensevoice ok' /var/log/npuworker.log)"
} > $O 2>&1
cat $O
