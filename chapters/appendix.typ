#import "../lib/template.typ": *

= 附录：开卷速查

#chapter-intro[
  考场救命速查：公式、API、易混概念、踩坑清单。建议打印此页置于手边。
]

== 核心公式速查

#table(
  columns: (auto, 1fr),
  table.header([名称], [公式]),
  [加速比], [$S(p) = T_1 \/ T_p$],
  [效率], [$E(p) = S(p) \/ p = T_1 \/ (p T_p)$],
  [阿姆达尔定律], [$S(N) = 1 \/ ((1-p) + p\/N)$，上限 $1\/(1-p)$],
  [古斯塔夫森定律], [$S(N) = N - s(N-1)$],
  [流水线加速比], [$S = (k n) \/ (k + n - 1) -> k$],
  [动态功耗], [$P prop C V^2 f$],
  [Brent 定理], [$T_p <= T_1\/p + T_infinity$],
  [并行度], [$approx T_1 \/ T_infinity$],
  [算术强度], [$I = "FLOP" \/ "Bytes"$],
  [Roofline], [$min("峰值算力", "带宽" times I)$],
  [成本], [$C = p times T_p$（成本最优 ⟺ $C=Theta(T_1)$）],
  [开销], [$T_o = p T_p - T_1$],
  [π 积分], [$pi = integral_0^1 4\/(1+x^2) dif x$],
  [π 蒙卡], [$pi approx 4M\/N$（圆内点数比）],
)

== 易混概念辨析

#table(
  columns: (auto, 1fr, 1fr),
  table.header([维度], [A], [B]),
  [流水线 / 超标量], [时间重叠分阶段], [空间多执行单元、多发射],
  [SIMD / SIMT], [CPU 向量、固定宽度], [GPU 每线程标量、warp 锁步],
  [Amdahl / Gustafson], [强扩展、规模固定], [弱扩展、规模随核增长],
  [Jacobi / Gauss-Seidel], [用旧值、易并行], [用新值、需红黑排序],
  [Reduce / Allreduce], [结果只在 root], [结果分发给所有进程],
  [Gather / Allgather], [收到 root], [所有进程都得到全集],
  [Send / Isend], [阻塞，返回即可重用缓冲], [非阻塞，Wait 前禁动缓冲],
  [single / master], [任意线程 + 末尾 barrier], [主线程 + 无 barrier],
  [critical / atomic], [任意代码块、通用锁], [单条标量读改写、轻量],
  [private / firstprivate], [私有、未初始化], [私有、用进入前值初始化],
  [static / dynamic 调度], [预分配、开销低], [按需领取、负载均衡],
  [signal / broadcast], [唤醒一个等待者], [唤醒所有等待者],
  [join / detach], [等待并回收、取返回值], [自动回收、不可 join],
)

== MPI 常用 API 速查

#table(
  columns: (auto, 1fr),
  table.header([函数], [作用]),
  [`MPI_Init` / `MPI_Finalize`], [初始化 / 收尾],
  [`MPI_Comm_rank` / `_size`], [取本进程号 / 进程总数],
  [`MPI_Send` / `MPI_Recv`], [阻塞点对点],
  [`MPI_Isend` / `MPI_Irecv` / `MPI_Wait`], [非阻塞 + 完成],
  [`MPI_Sendrecv`], [一次同时收发（防死锁）],
  [`MPI_Bcast`], [广播],
  [`MPI_Scatter` / `MPI_Gather`], [散发 / 收集],
  [`MPI_Reduce` / `MPI_Allreduce`], [规约 / 规约并分发],
  [`MPI_Barrier`], [屏障],
  [`MPI_Type_contiguous/vector/indexed/create_struct`], [派生类型],
  [`MPI_Type_commit` / `_free`], [提交 / 释放派生类型],
  [`MPI_Comm_split`], [按 color 分组],
  [`MPI_Cart_create` / `_shift`], [笛卡尔拓扑 / 求邻居],
)

== OpenMP 制导速查

#table(
  columns: (auto, 1fr),
  table.header([制导 / 子句], [作用]),
  [`parallel`], [创建线程组],
  [`for` / `sections` / `single`], [工作分担],
  [`task` / `taskwait`], [显式任务 / 等子任务],
  [`critical` / `atomic`], [临界区 / 原子],
  [`barrier` / `nowait`], [屏障 / 取消隐式屏障],
  [`master` / `ordered` / `flush`], [主线程 / 保序 / 内存栅栏],
  [`private` / `firstprivate` / `lastprivate`], [私有变量族],
  [`shared` / `default`], [共享 / 默认作用域],
  [`reduction(op:var)`], [归约],
  [`schedule(static/dynamic/guided)`], [调度策略],
  [`threadprivate` / `copyin` / `copyprivate`], [线程持久副本 / 拷入 / 广播],
)

== Pthreads API 速查

#table(
  columns: (auto, 1fr),
  table.header([函数], [作用]),
  [`pthread_create` / `_join` / `_detach`], [创建 / 等待 / 分离],
  [`pthread_mutex_lock` / `_unlock` / `_trylock`], [互斥锁],
  [`pthread_cond_wait` / `_signal` / `_broadcast`], [条件变量],
  [`pthread_barrier_wait`], [屏障],
  [`pthread_rwlock_rdlock` / `_wrlock`], [读写锁],
)

== Rust 并行 crate 速查

#table(
  columns: (auto, 1fr),
  table.header([crate / 类型], [用途]),
  [`r
ayon`],
  [数据并行迭代器 `par_iter`、`join`、`scope`（工作窃取）],

  [`crossbeam`], [作用域线程 `scope`、无锁队列、channel],
  [`std::thread`], [原生线程，对应 Pthreads],
  [`std::sync::{Mutex, RwLock, Condvar, Barrier}`], [同步原语],
  [`std::sync::atomic`], [原子类型 + `Ordering`（对应 flush 语义）],
  [`mpi` (rsmpi)], [MPI 的安全封装],
  [`std::simd` (nightly)], [可移植 SIMD],
)

== 踩坑 / 找错清单（开卷找 bug 必看）

#note[
  + 共享内存：循环里用的*外部临时变量*忘标 `private` → 数据竞争。
  + 求和归约用 `atomic`/`critical` 抢同一变量 → 退化串行；应用 `reduction`。
  + 模板计算*原地更新*（未用双缓冲）→ Jacobi 语义被破坏。
  + 时间步之间缺 `barrier` / 误加 `nowait` → 读到未完成数据。
  + MPI 双方都先 `Send` 后 `Recv` → 大消息死锁；用 `Sendrecv` / 非阻塞。
  + MPI 集合通信有进程没调用 → 全体挂起。
  + `Isend` 后 `Wait` 前修改发送缓冲 → 数据损坏。
  + 派生结构类型用累加偏移而非 `offsetof` → 忽略对齐填充、读错。
  + Pthreads 传 `&i`（循环变量地址）给线程 → 悬垂 / 共享，应传值或独立存储。
  + 条件变量用 `if` 而非 `while` 检查条件 → 虚假唤醒导致错误。
  + `lock` 后路径中途 `return` 未 `unlock` → 死锁。
  + 多锁加锁顺序不一致（ABBA）→ 死锁。
  + 多线程共享一个 RNG → 竞争 + 统计相关；应每线程独立 RNG。
]

== 编译运行小抄

#sidebyside(
  left-label: "Rust",
  rustcode[
    ```bash
    # rayon / crossbeam：普通 cargo
    cargo run --release

    # rsmpi：需系统装 OpenMPI
    cargo build --release
    mpirun -np 4 ./target/release/app

    # std::simd 需 nightly
    cargo +nightly run --release
    ```
  ],
  ccode[
    ```bash
    # OpenMP
    gcc -O3 -fopenmp prog.c -o prog
    OMP_NUM_THREADS=4 ./prog

    # MPI
    mpicc -O3 prog.c -o prog
    mpirun -np 4 ./prog

    # Pthreads
    gcc -O3 prog.c -lpthread -o prog
    ```
  ],
)
