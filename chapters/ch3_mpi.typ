#import "../lib/template.typ": *

= OpenMPI / 消息传递

#chapter-intro[
  MPI（Message Passing Interface）是分布式内存并行的事实标准，OpenMPI 是其主流开源实现。与共享内存（OpenMP / Pthreads）不同，MPI 进程*不共享地址空间*，一切协作靠"发消息"完成。本章从点对点通信入手，剖析阻塞原语导致的死锁与非阻塞解法，再覆盖集合通信、派生数据类型、通信器与虚拟拓扑。代码以 Rust 的 `rsmpi`（`mpi` crate）为主，对照 C 的原生 MPI API。
]

== 生态简介

#basic[
  / 标准 vs 实现: MPI 是*接口标准*（MPI-1/2/3/4）；OpenMPI、MPICH、Intel MPI 是其*实现*。
  / 运行模型: SPMD —— 同一份可执行程序被启动成 $P$ 个进程，每个进程有唯一的 *rank*（0 .. P-1），靠 rank 走不同逻辑。
  / 启动方式: `mpirun -np 4 ./program` 或 `mpiexec`，启动 4 个进程。
  / 通信器 (communicator): 进程的分组 + 通信上下文。默认 `MPI_COMM_WORLD` 包含所有进程。
  / 核心三元组: 每条消息由 (数据缓冲, 数据类型, 标签 tag) + (源/目的 rank, 通信器) 唯一确定。
]

Rust 生态：`mpi` crate（rsmpi）对原生 MPI 做了安全封装，自动管理生命周期、用类型表达缓冲区。编译需链接系统 MPI 库。

#sidebyside(
  left-label: "Rust (rsmpi) 骨架",
  rustcode[
    ```rust
    use mpi::traits::*;

    fn main() {
        let universe = mpi::initialize().unwrap();
        let world = universe.world();
        let rank = world.rank();   // 本进程编号
        let size = world.size();   // 进程总数
        println!("rank {} / {}", rank, size);
        // universe 析构时自动 MPI_Finalize
    }
    ```
  ],
  ccode[
    ```c
    #include <mpi.h>
    #include <stdio.h>
    int main(int argc, char** argv) {
        MPI_Init(&argc, &argv);
        int rank, size;
        MPI_Comm_rank(MPI_COMM_WORLD, &rank);
        MPI_Comm_size(MPI_COMM_WORLD, &size);
        printf("rank %d / %d\n", rank, size);
        MPI_Finalize();   // 必须手动调用
        return 0;
    }
    ```
  ],
)

#note[
  给 Rust 程序员：C 的 MPI 用*输出参数*（传指针 `&rank` 让函数填值），这是 C 没有多返回值的惯用法。rsmpi 则返回值 + RAII：`universe` 离开作用域自动 `MPI_Finalize`，不会忘。几乎所有 C 的 `MPI_*` 函数都返回错误码（`int`），生产代码应检查，开卷题中通常省略。
]

== 点对点通信

=== 阻塞发送 / 接收

#basic[
  / `MPI_Send(buf, count, type, dest, tag, comm)`: 把数据发给 `dest`。*阻塞*语义：函数返回时，缓冲区 `buf` 可安全重用（数据已被拷走或已送出）。
  / `MPI_Recv(buf, count, type, source, tag, comm, status)`: 从 `source` 接收。阻塞直到收到匹配 (source, tag) 的消息。
  / 匹配规则: 发送的 (dest, tag, comm) 要与接收的 (source, tag, comm) 对应。可用 `MPI_ANY_SOURCE` / `MPI_ANY_TAG` 通配。
]

=== 用点对点通信计算 π（数值积分）

#basic[
  用 $pi = integral_0^1 4 \/ (1 + x^2) dif x$ 的中点矩形法。主从模式：每个进程算一部分区间的局部和，再把局部和发回 rank 0 汇总。
]

#sidebyside(
  left-label: "Rust (rsmpi, 点对点)",
  rustcode[
    ```rust
    use mpi::traits::*;
    fn main() {
        let u = mpi::initialize().unwrap();
        let world = u.world();
        let rank = world.rank();
        let size = world.size();
        let n: u64 = 1_000_000;
        let h = 1.0 / n as f64;

        // 每个进程跨步求局部和
        let mut local = 0.0;
        let mut i = rank as u64;
        while i < n {
            let x = (i as f64 + 0.5) * h;
            local += 4.0 / (1.0 + x * x);
            i += size as u64;
        }
        local *= h;

        if rank == 0 {
            let mut pi = local;
            // 收集其余进程的局部和
            for src in 1..size {
                let (v, _) = world
                    .process_at_rank(src)
                    .receive::<f64>();
                pi += v;
            }
            println!("pi = {}", pi);
        } else {
            world.process_at_rank(0).send(&local);
        }
    }
    ```
  ],
  ccode[
    ```c
    #include <mpi.h>
    #include <stdio.h>
    int main(int argc, char** argv) {
        MPI_Init(&argc, &argv);
        int rank, size;
        MPI_Comm_rank(MPI_COMM_WORLD, &rank);
        MPI_Comm_size(MPI_COMM_WORLD, &size);
        long n = 1000000; double h = 1.0/n;

        double local = 0.0;
        for (long i = rank; i < n; i += size) {
            double x = (i + 0.5) * h;
            local += 4.0 / (1.0 + x*x);
        }
        local *= h;

        if (rank == 0) {
            double pi = local, v;
            MPI_Status st;
            for (int src = 1; src < size; src++) {
                MPI_Recv(&v, 1, MPI_DOUBLE, src, 0,
                         MPI_COMM_WORLD, &st);
                pi += v;
            }
            printf("pi = %.10f\n", pi);
        } else {
            MPI_Send(&local, 1, MPI_DOUBLE, 0, 0,
                     MPI_COMM_WORLD);
        }
        MPI_Finalize();
    }
    ```
  ],
)

#tip[
  实践中上面这种"手动汇总"应直接用 `MPI_Reduce`（见集合通信）一行搞定。考试常要求"用点对点实现规约"以考查对 Send/Recv 的理解，记住模式：从进程 `send` 给 0，进程 0 循环 `recv` 累加。
]

=== 阻塞原语导致的死锁

#note[
  *经典死锁场景*：两个进程互相先发后收。
  ```
  // rank 0:                 // rank 1:
  MPI_Send(-> 1)             MPI_Send(-> 0)
  MPI_Recv(<- 1)             MPI_Recv(<- 0)
  ```
  若 `MPI_Send` 采用*同步语义*（要等对方 `Recv` 就绪才返回），两个进程都卡在 `Send` 等对方先收，谁也走不到 `Recv` —— *死锁*。

  这是否真死锁取决于消息大小与实现：小消息常被 MPI 缓冲（eager 协议），`Send` 立即返回，侥幸不死锁；大消息超过缓冲阈值走 rendezvous 协议则必然死锁。所以"小消息能跑、大消息卡死"是 MPI 程序的典型不可移植 bug。
]

#advanced[
  *四种解法*：
  + *调整顺序*：让一方先收后发（rank 0 先 Send 后 Recv，rank 1 先 Recv 后 Send）。
  + *用 `MPI_Sendrecv`*：一个调用同时发和收，由 MPI 保证不死锁。
  + *用非阻塞 `MPI_Isend`/`MPI_Irecv`*（见下）。
  + *用缓冲发送 `MPI_Bsend`*：显式提供发送缓冲区。
]

#sidebyside(
  left-label: "Rust：Sendrecv 避免死锁",
  rustcode[
    ```rust
    use mpi::traits::*;
    use mpi::point_to_point as p2p;

    // 环形交换：每个进程与左右邻居交换边界值
    let next = (rank + 1) % size;
    let prev = (rank - 1 + size) % size;
    let send_val = rank as f64;
    let mut recv_val = 0.0_f64;

    p2p::send_receive_into(
        &send_val,
        &world.process_at_rank(next), // 发给右邻
        &mut recv_val,
        &world.process_at_rank(prev), // 收自左邻
    );
    ```
  ],
  ccode[
    ```c
    int next = (rank + 1) % size;
    int prev = (rank - 1 + size) % size;
    double send_val = rank, recv_val;

    // 一次调用同时发收，MPI 保证不会死锁
    MPI_Sendrecv(&send_val, 1, MPI_DOUBLE, next, 0,
                 &recv_val, 1, MPI_DOUBLE, prev, 0,
                 MPI_COMM_WORLD, MPI_STATUS_IGNORE);
    ```
  ],
)

=== 非阻塞通信

#basic[
  非阻塞原语*立即返回*一个请求句柄 (request)，通信在后台进行，之后用 `MPI_Wait` / `MPI_Test` 完成。好处：(1) 避免死锁；(2) *通信与计算重叠*，隐藏延迟。

  / `MPI_Isend` / `MPI_Irecv`: `I` = Immediate，发起后立即返回。
  / `MPI_Wait(request, status)`: 阻塞等待该通信完成。
  / `MPI_Test`: 非阻塞查询是否完成。
  / `MPI_Waitall`: 等待一组请求全部完成。
]

#note[
  *非阻塞的铁律*：在 `MPI_Wait` 返回之前，*绝不能修改 `Isend` 的发送缓冲、也不能读取 `Irecv` 的接收缓冲*——数据可能还没传完。这是非阻塞通信最常见的正确性错误。
]

#sidebyside(
  left-label: "Rust：非阻塞交换（scope）",
  rustcode[
    ```rust
    use mpi::traits::*;
    use mpi::request::WaitGuard;

    let msg = vec![rank as f64; 100];
    let mut recv = vec![0.0_f64; 100];

    mpi::request::scope(|scope| {
        // 发起非阻塞收 + 发
        let rreq = world.process_at_rank(prev)
            .immediate_receive_into(scope, &mut recv);
        let sreq = world.process_at_rank(next)
            .immediate_send(scope, &msg[..]);
        // ... 这里可做与通信无关的计算 ...
        // 作用域结束时 WaitGuard 自动 wait
        rreq.wait();
        sreq.wait();
    });
    ```
  ],
  ccode[
    ```c
    double msg[100], recv[100];
    MPI_Request reqs[2];

    // 先挂上非阻塞收，再非阻塞发
    MPI_Irecv(recv, 100, MPI_DOUBLE, prev, 0,
              MPI_COMM_WORLD, &reqs[0]);
    MPI_Isend(msg,  100, MPI_DOUBLE, next, 0,
              MPI_COMM_WORLD, &reqs[1]);

    /* ... 与通信无关的计算可在此重叠进行 ...
       但此时不能读 recv、不能改 msg ! */

    MPI_Waitall(2, reqs, MPI_STATUSES_IGNORE);
    // 现在 recv 才可安全使用
    ```
  ],
)

#tip[
  rsmpi 用*生命周期 + scope*在编译期保证：缓冲区在 `Wait` 之前不会被释放或别名访问，把 MPI 著名的"缓冲区悬空"陷阱挡在编译期。C 里这完全靠程序员自觉。
]

== 集合通信

#basic[
  集合通信涉及通信器内*所有进程*，必须*所有进程都调用*（否则死锁）。常见操作：

  #table(
    columns: (auto, 1fr),
    table.header([操作], [语义]),
    [`Bcast`], [广播：root 的数据发给所有进程],
    [`Scatter`], [散发：root 把数组切块，每进程得一块],
    [`Gather`], [收集：每进程的数据汇到 root（Scatter 逆操作）],
    [`Allgather`], [收集后再广播给所有进程],
    [`Reduce`], [规约：各进程数据按操作（+、max…）合并到 root],
    [`Allreduce`], [规约结果分发给所有进程],
    [`Alltoall`], [全交换：每进程给每进程发不同数据（转置）],
    [`Barrier`], [屏障：所有进程到齐才继续],
    [`Scan`], [前缀规约：rank i 得到 0..i 的规约结果],
  )
]

下图展示几种典型集合通信的数据流：

```text
Bcast:       Scatter:        Gather:         Reduce(+):
 P0:[A]       P0:[ABCD]       P0:[A]          P0:[1]
 P0->P1:[A]   P0->P1:[B]      P1->P0          P1:[2] --> P0:[10]
 P0->P2:[A]   P0->P2:[C]      P2->P0          P2:[3]
 P0->P3:[A]   P0->P3:[D]      P3->P0:[ABCD]   P3:[4]
```

=== 用集合通信重写 π

#sidebyside(
  left-label: "Rust：Bcast + Reduce",
  rustcode[
    ```rust
    use mpi::traits::*;
    use mpi::collective::SystemOperation;

    let root = world.process_at_rank(0);
    // 1) root 广播 n 给所有进程
    let mut n: u64 = if rank == 0 { 1_000_000 } else { 0 };
    root.broadcast_into(&mut n);

    // 2) 各进程算局部和（跨步）
    let h = 1.0 / n as f64;
    let mut local = 0.0;
    let mut i = rank as u64;
    while i < n {
        let x = (i as f64 + 0.5) * h;
        local += 4.0 / (1.0 + x*x);
        i += size as u64;
    }
    local *= h;

    // 3) 规约求和到 root
    if rank == 0 {
        let mut pi = 0.0;
        root.reduce_into_root(&local, &mut pi,
                              SystemOperation::sum());
        println!("pi = {}", pi);
    } else {
        root.reduce_into(&local, SystemOperation::sum());
    }
    ```
  ],
  ccode[
    ```c
    long n;
    if (rank == 0) n = 1000000;
    // 1) 广播 n
    MPI_Bcast(&n, 1, MPI_LONG, 0, MPI_COMM_WORLD);

    // 2) 局部和
    double h = 1.0/n, local = 0.0;
    for (long i = rank; i < n; i += size) {
        double x = (i + 0.5)*h;
        local += 4.0/(1.0 + x*x);
    }
    local *= h;

    // 3) 规约求和到 rank 0
    double pi = 0.0;
    MPI_Reduce(&local, &pi, 1, MPI_DOUBLE,
               MPI_SUM, 0, MPI_COMM_WORLD);
    if (rank == 0) printf("pi = %.10f\n", pi);
    ```
  ],
)

#tip[
  集合通信考点：(1) *所有进程都必须调用*同一个集合操作，漏掉任何一个进程都会挂起；(2) `Reduce` 结果只在 root；要让所有进程都拿到结果用 `Allreduce`；(3) `Scatter`/`Gather` 的 `sendcount` 是*每个进程*的元素数，不是总数。
]

=== Scatter / Gather 实例

#sidebyside(
  left-label: "Rust：Scatter 后各自平方再 Gather",
  rustcode[
    ```rust
    // root 持有 size*chunk 个数，散发后每进程平方
    let chunk = 4;
    let root = world.process_at_rank(0);

    let mut mine = vec![0i32; chunk];
    if rank == 0 {
        let data: Vec<i32> =
            (0..size*chunk).map(|x| x as i32).collect();
        root.scatter_into_root(&data, &mut mine);
    } else {
        root.scatter_into(&mut mine);
    }
    for v in &mut mine { *v *= *v; }   // 本地处理

    if rank == 0 {
        let mut out = vec![0i32; (size as usize)*chunk];
        root.gather_into_root(&mine, &mut out);
        println!("{:?}", out);
    } else {
        root.gather_into(&mine);
    }
    ```
  ],
  ccode[
    ```c
    int chunk = 4;
    int* data = NULL;
    if (rank == 0) {
        data = malloc(size*chunk*sizeof(int));
        for (int i=0;i<size*chunk;i++) data[i]=i;
    }
    int mine[4];
    MPI_Scatter(data, chunk, MPI_INT,
                mine, chunk, MPI_INT,
                0, MPI_COMM_WORLD);
    for (int i=0;i<chunk;i++) mine[i]*=mine[i];

    int* out = NULL;
    if (rank == 0) out = malloc(size*chunk*sizeof(int));
    MPI_Gather(mine, chunk, MPI_INT,
               out, chunk, MPI_INT,
               0, MPI_COMM_WORLD);
    ```
  ],
)

== 派生数据类型

#basic[
  MPI 内建类型只覆盖连续的基本类型。当要发送*非连续 / 结构化*数据（如矩阵的一列、结构体）时，用#term[派生数据类型 (derived datatype)]描述内存布局，避免手动打包。四种构造器：

  / 连续 (contiguous): $n$ 个相同类型紧挨着。
  / 向量 (vector): 等间隔的块（块长 + 跨距 stride）—— 取矩阵的一列 / 子块。
  / 索引 (indexed): 每块长度、位移各不相同 —— 不规则选取。
  / 结构 (struct): 不同类型混合 —— 对应 C 的 struct。

  用前必须 `MPI_Type_commit`，用完 `MPI_Type_free`。
]

=== 连续 (Contiguous)

#ccode[
  ```c
  // 把 100 个 double 打包成一个新类型
  MPI_Datatype row_t;
  MPI_Type_contiguous(100, MPI_DOUBLE, &row_t);
  MPI_Type_commit(&row_t);
  MPI_Send(buf, 1, row_t, dest, 0, MPI_COMM_WORLD); // 发 1 个 = 100 doubles
  MPI_Type_free(&row_t);
  ```
]

=== 向量 (Vector) —— 取矩阵的一列

#basic[
  行主序存储的 $M times N$ 矩阵，*一列*的元素间隔 $N$ 个元素。`MPI_Type_vector(count, blocklen, stride, oldtype, newtype)`：`count` 个块，每块 `blocklen` 个元素，相邻块起点间隔 `stride` 个元素。
]

#sidebyside(
  left-label: "Rust (rsmpi)：列类型",
  rustcode[
    ```rust
    use mpi::datatype::UserDatatype;
    use mpi::traits::*;

    // M 行 N 列，行主序；取一列：
    // count=M 个块, 每块 1 个 f64, stride=N
    let col_t = UserDatatype::vector(
        m as i32,   // count
        1,          // blocklen
        n as i32,   // stride
        &f64::equivalent_datatype(),
    );
    // 之后可用 col_t 作为通信的数据类型发送一整列
    ```
  ],
  ccode[
    ```c
    // M x N 行主序矩阵，发送第 j 列
    MPI_Datatype col_t;
    MPI_Type_vector(M,        /* count */
                    1,        /* blocklen */
                    N,        /* stride */
                    MPI_DOUBLE, &col_t);
    MPI_Type_commit(&col_t);
    // &A[0*N + j] 起，按 col_t 发出整列
    MPI_Send(&A[j], 1, col_t, dest, 0,
             MPI_COMM_WORLD);
    MPI_Type_free(&col_t);
    ```
  ],
)

#tip[
  向量类型最经典的应用就是"发送矩阵的一列"或"halo 交换中的列边界"。务必记牢三参数含义：`count`(块数)、`blocklen`(每块元素数)、`stride`(块间起点间隔，以元素为单位)。
]

=== 索引 (Indexed) —— 不规则选取

#ccode[
  ```c
  // 选取数组中不规则的若干段（如稀疏矩阵的非零块）
  int blocklens[3] = {2, 3, 1};       // 每段长度
  int displs[3]    = {0, 5, 12};      // 每段起始位移（元素）
  MPI_Datatype idx_t;
  MPI_Type_indexed(3, blocklens, displs, MPI_INT, &idx_t);
  MPI_Type_commit(&idx_t);
  // 发送时会取 buf[0..2], buf[5..8], buf[12..13]
  MPI_Send(buf, 1, idx_t, dest, 0, MPI_COMM_WORLD);
  MPI_Type_free(&idx_t);
  ```
]

=== 结构 (Struct) —— 异构数据

#basic[
  对应 C 结构体，可混合不同类型。`MPI_Type_create_struct(count, blocklens, displs, types, newtype)`。位移 `displs` 用 `offsetof` 获得，*务必考虑编译器的内存对齐填充 (padding)*，不能假设字段紧挨。
]

#ccode[
  ```c
  typedef struct { int   id;       // 偏移 0
                   double x, y;     // 偏移 8（对齐到 8）
                   char  tag; } Particle;

  MPI_Datatype ptype;
  int          blens[3]  = {1, 2, 1};
  MPI_Aint     disps[3];
  MPI_Datatype types[3]  = {MPI_INT, MPI_DOUBLE, MPI_CHAR};
  // 用 offsetof 取真实偏移，正确处理对齐填充
  disps[0] = offsetof(Particle, id);
  disps[1] = offsetof(Particle, x);
  disps[2] = offsetof(Particle, tag);
  MPI_Type_create_struct(3, blens, disps, types, &ptype);
  MPI_Type_commit(&ptype);
  MPI_Send(&p, 1, ptype, dest, 0, MPI_COMM_WORLD);
  MPI_Type_free(&ptype);
  ```
]

#note[
  给 Rust 程序员：要安全地用 MPI 发送 Rust 结构体，应给结构体加 `#[repr(C)]` 固定布局，再用 rsmpi 的 `UserDatatype::structured` 描述各字段偏移（可用 `std::mem::offset_of!`）。绝不能直接发送含指针 / `Vec` / `String` 的结构体——发过去的是无效地址。这与 C 一样：MPI 只搬字节，不跟随指针。
]

== 组和通信器管理

#basic[
  / 通信器 (Communicator): 即进程组 (group) 加上通信上下文 (context)。`MPI_COMM_WORLD` 是默认全局通信器。不同通信器的消息互不干扰（即使 tag 相同）。
  / 进程组 (Group): 进程的有序集合，本身不能通信，是构造通信器的"素材"。
  / 为什么要自建通信器: 把进程分成若干子集，让某些集合通信 / 规约只在子集内进行（如按行分组做行内规约）。也可避免库与用户代码的 tag 冲突。
]

=== 用 MPI_Comm_split 分组（最常用）

#basic[
  `MPI_Comm_split(comm, color, key, &newcomm)`：按 `color` 把进程分到不同子通信器（同 color 一组），组内按 `key` 排序定 rank。这是分组最简单的方式。
]

#sidebyside(
  left-label: "Rust：按奇偶 rank 分组",
  rustcode[
    ```rust
    use mpi::traits::*;

    // color = rank % 2 -> 奇偶分两组
    let color = rank % 2;
    let sub = world
        .split_by_color(
          mpi::topology::Color::with_val(color)
        )
        .unwrap();
    println!("world rank {} -> sub rank {}",
             rank, sub.rank());
    // 现在可在 sub 内做独立的 Bcast / Reduce
    ```
  ],
  ccode[
    ```c
    // color=rank%2 分组；key=rank 决定组内次序
    MPI_Comm sub;
    int color = rank % 2;
    MPI_Comm_split(MPI_COMM_WORLD, color, rank, &sub);
    int subrank;
    MPI_Comm_rank(sub, &subrank);
    printf("world %d -> sub %d\n", rank, subrank);
    // 组内集合通信
    MPI_Barrier(sub);
    MPI_Comm_free(&sub);
    ```
  ],
)

#advanced[
  *更细粒度的方式（group API）*：
  ```c
  MPI_Group world_grp, sub_grp;
  MPI_Comm_group(MPI_COMM_WORLD, &world_grp);  // 取世界组
  int ranks[3] = {0, 2, 4};                    // 选若干进程
  MPI_Group_incl(world_grp, 3, ranks, &sub_grp);
  MPI_Comm sub;
  MPI_Comm_create(MPI_COMM_WORLD, sub_grp, &sub);
  ```
  `MPI_Group_incl` / `_excl` / `_union` / `_intersection` 可灵活组合进程。`split` 适合"按规则均匀分组"，group API 适合"精确点名"。
]

== 虚拟拓扑

#basic[
  物理上进程只有线性的 rank，但算法常有天然的几何 / 图结构。#term[虚拟拓扑]让我们给通信器附加一个逻辑结构（如二维网格、环、图），从而：(1) 用坐标而非 rank 寻址，代码更清晰；(2) 让 MPI 实现据此优化进程到物理核的映射。
]

=== 笛卡尔拓扑 (Cartesian)

#basic[
  把进程排成 $N$ 维网格（常用于 2D 模板计算 / 矩阵分块）。关键函数：
  - `MPI_Cart_create(comm, ndims, dims, periods, reorder, &cart)`：建网格，`periods` 指各维是否环绕。
  - `MPI_Cart_coords(cart, rank, ndims, coords)`：rank → 坐标。
  - `MPI_Cart_rank(cart, coords, &rank)`：坐标 → rank。
  - `MPI_Cart_shift(cart, dim, disp, &src, &dest)`：求某维上相邻进程的 rank（halo 交换神器）。
]

#sidebyside(
  left-label: "Rust：2D 笛卡尔网格邻居",
  rustcode[
    ```rust
    use mpi::traits::*;
    use mpi::topology::*;

    // 把进程组织成 2D 网格，非周期
    let dims = [2, 2];
    let periods = [false, false];
    let cart = world
        .create_cartesian_communicator(
            &dims, &periods, true)
        .unwrap();
    let coords = cart.coordinates();   // 本进程坐标
    // 求上 / 下邻居（沿第 0 维移动 1 步）
    let (up, down) =
        cart.shift(0, 1);
    println!("coords {:?}, up {:?} down {:?}",
             coords, up, down);
    ```
  ],
  ccode[
    ```c
    int dims[2] = {2, 2};
    int periods[2] = {0, 0};     // 非周期边界
    MPI_Comm cart;
    MPI_Cart_create(MPI_COMM_WORLD, 2, dims,
                    periods, 1 /*reorder*/, &cart);
    int coords[2], crank;
    MPI_Comm_rank(cart, &crank);
    MPI_Cart_coords(cart, crank, 2, coords);

    // 沿第 0 维 +1 找上下邻居 rank
    int up, down;
    MPI_Cart_shift(cart, 0, 1, &up, &down);
    // up/down 可能为 MPI_PROC_NULL（边界外）
    printf("(%d,%d) up=%d down=%d\n",
           coords[0], coords[1], up, down);
    ```
  ],
)

#tip[
  `MPI_Cart_shift` 返回的邻居若在边界外（非周期），值为 `MPI_PROC_NULL`。妙处：向 `MPI_PROC_NULL` 发送 / 接收是*合法的空操作*，无需写边界特判，halo 交换代码因此非常简洁。这是常考的实用细节。
]

=== 图拓扑 (Graph)

#advanced[
  当进程间通信关系不规则（非网格）时，用图拓扑描述任意邻接关系。现代接口 `MPI_Dist_graph_create_adjacent` 让每个进程声明自己的入边 / 出边邻居。配合*邻居集合通信* `MPI_Neighbor_alltoall`，可只在相邻进程间高效交换数据——适合非结构网格、不规则稀疏问题。
  ```c
  // 简化示意：每进程声明其邻居列表
  MPI_Dist_graph_create_adjacent(
      MPI_COMM_WORLD,
      indegree,  sources,  MPI_UNWEIGHTED,
      outdegree, dests,    MPI_UNWEIGHTED,
      MPI_INFO_NULL, 0 /*reorder*/, &graph_comm);
  MPI_Neighbor_alltoall(sendbuf, 1, MPI_INT,
                        recvbuf, 1, MPI_INT, graph_comm);
  ```
]

== 章末考试预测专区

#exam-section()

#pred(tags: ("死锁", "高频"))[
  下面的代码在两个进程上运行，可能死锁吗？为什么"小数据能跑、大数据卡死"？给出两种修复方法。
  ```c
  MPI_Send(buf, n, MPI_DOUBLE, other, 0, comm);
  MPI_Recv(buf2, n, MPI_DOUBLE, other, 0, comm, &st);
  ```
]
#analysis[
  可能死锁。两个进程都先 `MPI_Send` 再 `MPI_Recv`，彼此都在等对方先接收。
  - *小数据能跑*：MPI 实现对小消息常用 eager 协议，把数据先拷进内部缓冲区，`Send` 立即返回，于是双方都能走到 `Recv`，侥幸不死锁。
  - *大数据卡死*：超过缓冲阈值时改用 rendezvous（会合）协议，`Send` 必须等对方 `Recv` 就绪才能传输并返回，双方互等 → 死锁。
  - *修复*：(1) 让一方先收后发（打破对称）；(2) 改用 `MPI_Sendrecv` 单次调用同时收发；(3) 用非阻塞 `MPI_Isend`/`MPI_Irecv` + `Waitall`。
]

#pred(tags: ("非阻塞", "正确性"))[
  使用 `MPI_Isend(buf,...)` 后，在 `MPI_Wait` 返回之前修改了 `buf` 的内容，会有什么后果？非阻塞通信的两大好处是什么？
]
#analysis[
  后果：*未定义行为 / 数据错误*。`Isend` 只是发起发送，真正的数据传输可能在调用返回后才进行；在 `Wait` 完成前修改 `buf`，传出去的可能是新旧混合的脏数据。同理 `Irecv` 的接收缓冲在 `Wait` 前不可读取。
  两大好处：(1) *避免死锁*——发起即返回，不会相互阻塞等待；(2) *通信与计算重叠*——通信在后台进行，期间 CPU 可做无关计算，隐藏通信延迟，提高效率。
]

#pred(tags: ("集合通信", "辨析"))[
  说明 `MPI_Reduce` 与 `MPI_Allreduce` 的区别；`MPI_Gather` 与 `MPI_Allgather` 的区别。若只有部分进程调用了 `MPI_Bcast` 会怎样？
]
#analysis[
  - `Reduce` vs `Allreduce`：两者都把各进程数据按操作（如求和）合并；`Reduce` 结果*只在 root 进程*，`Allreduce` 把结果*分发给所有进程*（相当于 Reduce + Bcast）。
  - `Gather` vs `Allgather`：`Gather` 把各进程数据收集到 *root 一处*；`Allgather` 让*所有进程*都得到完整收集结果（Gather + Bcast）。
  - 部分进程调用 `Bcast`：集合通信要求通信器内*所有进程都参与*。若有进程未调用，已调用的进程会一直阻塞等待，导致程序*挂起（死锁）*。
]

#pred(tags: ("派生类型", "向量"))[
  一个 $4 times 5$ 的 `double` 矩阵按行主序存储，要发送它的第 2 列。用哪种派生数据类型？写出关键参数 (count, blocklen, stride)。
]
#analysis[
  用*向量类型* `MPI_Type_vector`。第 2 列共有 4 个元素（4 行），每个元素自成一块，相邻元素在内存中相隔一整行即 5 个 `double`。
  参数：`count = 4`（块数 = 行数），`blocklen = 1`（每块 1 个 double），`stride = 5`（块间起点相隔 5 个元素 = 列数 N）。
  ```c
  MPI_Type_vector(4, 1, 5, MPI_DOUBLE, &col_t);
  MPI_Type_commit(&col_t);
  MPI_Send(&A[0*5 + 1], 1, col_t, dst, 0, comm); // 从 A[0][1] 起
  ```
]

#pred(tags: ("结构类型", "对齐"))[
  用 `MPI_Type_create_struct` 发送 C 结构体时，为什么必须用 `offsetof` 计算位移，而不能假设字段紧挨排列？
]
#analysis[
  因为编译器会按*内存对齐 (alignment)* 规则在字段间插入*填充字节 (padding)*，使各字段地址满足其类型的对齐要求（如 `double` 通常对齐到 8 字节）。如果手动假设字段紧挨（按类型大小累加偏移），算出的位移与编译器真实布局不符，MPI 会从错误地址读取，导致数据错乱。`offsetof(struct, field)` 返回编译器实际采用的字段偏移，自动包含填充，因此正确且可移植。
]

#pred(tags: ("拓扑", "halo"))[
  在二维笛卡尔拓扑中，`MPI_Cart_shift` 对网格边界（非周期）上的进程返回什么？这给 halo 交换代码带来什么便利？
]
#analysis[
  对非周期边界外的邻居，`MPI_Cart_shift` 返回 `MPI_PROC_NULL`。
  便利：向 / 从 `MPI_PROC_NULL` 进行的 `Send`/`Recv`/`Sendrecv` 都是*合法的空操作*（立即成功、不传任何数据）。因此 halo（鬼影行/列）交换的代码无需为边界进程写特殊判断——统一对四个方向 `Sendrecv` 即可，边界方向自动变成空操作，大大简化了代码并减少出错。
]

#pred(tags: ("通信器", "分组"))[
  你想把 12 个进程分成 3 组（每组 4 个）分别做组内规约。用哪个函数最方便？给出 color 和 key 的设计。
]
#analysis[
  用 `MPI_Comm_split` 最方便。设计：`color = rank / 4`（0,1,2,3→组0；4,5,6,7→组1；8..11→组2），`key = rank`（组内按原 rank 升序排）。
  ```c
  MPI_Comm sub;
  MPI_Comm_split(MPI_COMM_WORLD, rank / 4, rank, &sub);
  MPI_Reduce(&local, &res, 1, MPI_DOUBLE, MPI_SUM, 0, sub); // 各组内独立规约
  ```
  这样三个子通信器内的 `MPI_Reduce` 互不干扰，各自得到本组 4 个进程的规约结果。
]
