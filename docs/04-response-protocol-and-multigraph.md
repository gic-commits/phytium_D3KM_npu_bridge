# 提交/响应线格式、`sid` 匹配机制、以及"同进程多图必挂"的真因

> 这篇解决一个非常容易误判的故障：**服务里跑一个模型一切正常，换成第二个模型就永久挂死**。
> 如果你正在做闭源加速器库的服务化，先读这篇再动手，能省掉数轮"以为引擎/驱动有问题"的弯路。

## 一、实测的 VHA 命令序列（一次完整推理）

以 yunet 为例（`fd` = 设备 fd，`type=0x71` 即字符 `'q'`）：

| 顺序 | cmd | 载荷 | 含义 |
|---|---|---|---|
| 1 | `nr=2 sz=32` | `{size, page, name[8], page}` | 分配缓冲（**名字**为 `INT-3`/`CMDS-8`/`TMP-7` 等，是识别缓冲用途的关键线索）|
| 2 | `nr=7 sz=16` | `{iova, page\|flags}` | 映射（`flags&4 = INFERENCE`）|
| 3 | `nr=9 sz=16` | `{page, state, -1, -1}` | `SET_BUF`（`state=1` 表示库已写完）|
| 4 | `nr=9 sz=16` | 同上，逐个缓冲 | 输出缓冲最后一批置 1（= `OUTPUT_SYNC` 语义）|
| 5 | **`write(fd, 272 字节)`** | 见下表 | **提交**：`npu_excute_stream` + 缓冲列表 |
| 6 | `nr=10 sz=80` | `{cnt, num, pages…}` | 提交相关的同步/收尾 |
| 7 | `read(fd, 32)` | 响应 | **库用独立线程 poll + read 消费** |

**272 字节提交描述符头部（实测）**：

```c
struct npu_excute_stream {   /* 80 字节，其后是 stream_* 与本库特有的列表布局 */
    u16 sflags;   /* +0x00  例 0x0001 / 0x0003 */
    u16 stype;    /* +0x02  例 0x0001 / 0x0002 */
    u32 sid;      /* +0x04  ★ 见下节：本库恒为 0x10101 */
    u8  sp1;      /* +0x08  优先级 */
    u8  sp2;      /* +0x09  padding */
    u8  all;      /* +0x0a  缓冲总数（例 7）*/
    u8  in;       /* +0x0b  输入个数（例 3）*/
    u32 t;        /* +0x0c  页号（本库中对应官方的 stream_fd 位）*/
    u32 fd[16];   /* +0x10  这里的每一项是**设备页号**，不是 dma-buf fd */
};
```
⚠️ 描述符长度**不是常数**（本库见到 272 与 328 两种），且**短写即致命**——库要求 `write()` 返回值精确等于写入长度。

## 二、响应格式（唯一能标识"哪条流"的字段是 `sid`）

内核 → 库的响应结构（官方 `phytium_npu_uapi.h`）：

```c
struct npu_user_rsp {
    u64 rsp_err_flags;   /* +0x00  bit16 起是"事件类型"，本例 1 */
    u32 sid;             /* +0x08  ← "arbitrary id to identify stream" */
    u32 err_no;          /* +0x0c */
    u32 session_id;      /* +0x10 */
};
```

实测库每次 `read()` **32 字节**（`npu_user_rsp` 24B + `last_proc_us` 8B）。
我们抓到的两条响应（**两次不同模型的请求**）**逐字节完全相同**：

```
00000100 00000000 01010100 00000000 1e000000 00000000 00000000 00000000
└─err_flags=0x10000  └─sid=0x10101  └─session_id
```

⇒ **响应内容无法区分两次请求**；库只能靠 `sid` 分辨"这是哪个任务"。

## 三、根因：`sid` 撞车（同进程多图必挂）

| 现象 | 事实 |
|---|---|
| 同一模型连跑 13 次 | **全绿**（任务对象复用，不存在两个同 `sid` 的任务）|
| 换第二个模型 | **必挂**（永久阻塞，只能 kill）|
| 两次提交的 `sid` | **都是 `0x10101`**（同一进程内不同图也不变）|

**gdb 直接看到匹配错位**（断在库内部符号上，须 `set breakpoint pending on`，库是 dlopen 懒加载）：

```
yunet(通):   SETKEY seg=0 key=13 → SETKEY seg=1 key=14 → RESP a1=1 → WAIT id=0(this=A) → 完成
yolov5s(挂): SETKEY seg=0 key=25 → WAIT id=0(this=B) → RESP a1=2 → 再无事件
                            ★ RESP 唤醒的是另一个 notify 对象(A)，等待中的 B 永远等不到
```

`gdb thread apply all bt` 给出卡死点：`npu_phydnnWaitForEvent → npu::VhaNotifyImp::WaitForCompletion(int)
→ std::condition_variable::wait`（**condvar 无超时**，所以是永久挂死，不是超时失败）。

## 四、诊断三件套（零内核风险，按性价比排序）

```bash
# ① strace：看提交线程是否长时间阻塞、响应线程何时把响应读走
strace -f -tt -o /tmp/s.strace ./your_service
#    本例：write(fd, 272B) 阻塞 469 ms（我们自己的 settle/诊断耗时），期间库的
#    GetVhaResponse 线程已完成 ppoll→read(32B)；write 返回后 futex(FUTEX_WAIT) 再无返回

# ② gdb 全线程栈：直接给出库内函数名，不必反汇编
sudo gdb -p <pid> -batch -ex 'thread apply all bt 12'

# ③ LD_PRELOAD 探针：把两次请求的 ioctl/描述符/响应字节并排对照（本仓库 svc/libvha_tap.c）
gcc -shared -fPIC -O1 -o libvha_tap.so svc/libvha_tap.c -ldl
LD_PRELOAD=./libvha_tap.so VHA_TAP_LOG=/tmp/tap.log ./your_service
#    本例：两次请求唯一差异只在 desc[0:2]=1↔3、desc[2:4]=1↔2；sid 两处相同；
#    两次读到的响应字节完全相同 ⇒ 一眼定位"匹配靠 sid，而 sid 重复"
```

**库内断点要点**：内部符号只有 `nm`（**不带 `-D`**）才有；断点用 **mangled 名**，
例如 `_ZN3npu12VhaNotifyImp17WaitForCompletionEi`、`_ZN3npu11VhaObserver14HandleResponseEiSt8functionIFvPvEEi`。

## 五、修复路径（含一条被实测否掉的方案）

| 方案 | 结果 |
|---|---|
| 切模型时**析构旧 `phyAIEngine`**（让库注销旧任务）| ❌ **实测无效**：日志确实出现"淘汰模型"，紧接着建新图仍然挂死 ⇒ 映射**活在进程级** |
| **进程池**：每个模型一个子进程，串行持有设备 | ✅ **实测通过**（见 `docs/05`）|
| 让库支持多图 | 不可行（闭源二进制；且两个 sid 相同时无法消歧）|

## 六、可迁移的判据

1. **"同一模型连跑 N 次全绿、换模型就挂"** ⇒ 第一嫌疑是**任务/响应匹配按某个可重复标识**，
   先抓两次提交的该字段是否相同（本例 `sid`），不要从"引擎/时序"起步；
2. **挂死 ≠ 超时失败**：挂死说明"响应被静默丢弃或投递错位"，此时**库不会有任何错误日志**
   （"库没报错"不能证明匹配正确）；
3. 服务化前的**第一件事**：确认库是否支持**同进程多图/多模型并存**（用两个不同模型的请求序列验一次，
   几分钟即可判定），否则服务里会埋一个"偶发挂死"；
4. 验收用例**必须包含跨模型轮换**——只跑同一模型会完全掩盖这类缺陷。
