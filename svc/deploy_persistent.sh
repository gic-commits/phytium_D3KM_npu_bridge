#!/bin/bash
# 正式部署：二进制/模型搬到持久盘 /opt/npu，更新 unit（开机可用 + 空闲让出设备），
# 并加一个定期冒烟自检 timer。
# 用法: bash deploy_persistent.sh [--enable|--no-enable]   默认 --enable（开机自启）
set -e
WANT_ENABLE=1
[ "$1" = "--no-enable" ] && WANT_ENABLE=0
SRC=/dev/shm/nputest
DST=/opt/npu

echo "===== 1) 建目录与拷贝（${SRC} → ${DST}）"
sudo mkdir -p "$DST/bin" "$DST/model" "$DST/testdata" "$DST/doc"
# ⚠️ 源文件权限可能是 0700（cp 会继承）⇒ 非 root 用户读不了测试图/模型，症状是客户端报 -5（BADARG）
#    这里统一放开读权限：目录 a+X（可进入）、文件 a+r
sudo cp -f "$SRC/svc/npusvc_pool" "$SRC/svc/npuworker" "$SRC/svc/npu_cli" "$SRC/svc/npusvc" "$DST/bin/"
sudo cp -f "$SRC/svc/libnpuclient.a" "$DST/bin/" 2>/dev/null || true
sudo cp -f "$SRC/model/"*.json "$SRC/model/"*.params "$SRC/model/"*.so "$SRC/model/"*.tar "$SRC/model/"*.meta.txt "$DST/model/"
sudo cp -f "$SRC/20210828122250_3b289.jpg" "$DST/testdata/" 2>/dev/null || true
sudo cp -f "$SRC/svc/svc_smoke.sh" "$DST/bin/"
sudo cp -f "$SRC/svc/npusvc.service" "$SRC/svc/npusvc-smoke.service" "$SRC/svc/npusvc-smoke.timer" "$DST/doc/" 2>/dev/null || true
sudo chmod 0755 "$DST/bin/"*
sudo chown -R root:root "$DST"
sudo chmod -R a+rX "$DST"
echo "  bin: $(ls "$DST/bin" | tr '\n' ' ')"
echo "  model: $(ls "$DST/model" | wc -l) 个文件, $(du -sh "$DST/model" | cut -f1)"
echo "  testdata: $(ls "$DST/testdata" | tr '\n' ' ')"

echo "===== 2) 安装/更新 unit（路径已指向 /opt/npu）"
sudo cp -f "$SRC/svc/npusvc.service" /etc/systemd/system/npusvc.service
sudo cp -f "$SRC/svc/npusvc-smoke.service" /etc/systemd/system/ 2>/dev/null || true
sudo cp -f "$SRC/svc/npusvc-smoke.timer"   /etc/systemd/system/ 2>/dev/null || true
sudo systemctl daemon-reload
systemctl cat npusvc | grep -E "ExecStart|ExecStartPre|idle-kill|models|Environment" | sed 's/^/  /'

echo "===== 3) 停旧的（若有）并启动新部署"
sudo systemctl stop npusvc 2>/dev/null || true
pkill -x npusvc_pool 2>/dev/null || true; pkill -x npuworker 2>/dev/null || true; sleep 1
sudo systemctl start npusvc
sleep 3
echo "  is-active: $(systemctl is-active npusvc)"
systemctl status npusvc --no-pager | head -8 | sed 's/^/  /'

echo "===== 4) 冒烟（走 systemd socket，用持久盘的测试图）"
export NPU_SOCK=/run/npu/npu.sock NPU_SMOKE_IMG=/opt/npu/testdata/20210828122250_3b289.jpg
smoke_out=$(bash "$DST/bin/svc_smoke.sh" 2>&1); smoke_rc=$?
echo "$smoke_out" | sed 's/^/  /'
echo "  冒烟退出码=$smoke_rc（0=健康）"

echo "===== 5) 冒烟 timer（每 15 分钟一次，日志入 journal）"
if [ -f /etc/systemd/system/npusvc-smoke.timer ]; then
  sudo systemctl daemon-reload
  sudo systemctl enable --now npusvc-smoke.timer >/dev/null 2>&1 || true
  systemctl list-timers npusvc-smoke.timer --no-pager 2>/dev/null | head -3 | sed 's/^/  /'
fi

echo "===== 6) 开机自启设置"
if [ "$WANT_ENABLE" = 1 ]; then
  sudo systemctl enable npusvc >/dev/null 2>&1
  echo "  已 enable（下次开机自动起；启动前会把 sim 切成 0）"
else
  echo "  保持 disabled（手动 systemctl start npusvc）"
fi
echo "  is-enabled: $(systemctl is-enabled npusvc 2>&1)"

echo "===== 7) 空闲让出设备的验证（--idle-kill-ms 120000 ⇒ 2 分钟后回收 worker）"
echo "  worker now: $(pgrep -x npuworker | tr '\n' ' ')"
echo "  （等 2 分钟后 worker 应自动消失、/dev/npu0 让出；用 watch 或稍后复查）"
echo "===== oops=$(dmesg | grep -E 'oops|BUG:|general protection' | grep -vc ramoops)"
