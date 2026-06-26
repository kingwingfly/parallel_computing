#import "../lib/template.typ": *

= 并行计算基础

#chapter-intro[
  本章是方法论核心：如何把一个问题"看穿"成可并行的结构。我们围绕几类经典问题展开——逐元素映射、蒙特卡洛求 π、二维热传导、一维波动方程、高斯-塞德尔迭代——逐步引出"数据并行 vs 任务并行""依赖关系分析""锁与屏障""调度与编排"等通用工具。掌握本章，后续 MPI / OpenMP / Pthreads 不过是它的不同实现外壳。
]

== 如何分析一个问题能否并行

#basic[
  并行化的通用流程（Foster 的 PCAM 方法论）：

  / 划分 (Partition): 把计算和数据拆成尽可能多的小任务，暴露并行性。又分*数据划分*（分数据）与*功能划分*（分任务）。
  / 通信 (Communication): 分析任务之间需要交换哪些数据、依赖关系如何。
  / 聚合 (Agglomeration): 把过细的小任务合并，平衡"并行度"与"通信/调度开销"。
  / 映射 (Mapping): 把聚合后的任务分配到具体的处理器上，追求负载均衡且通信最小。
]

#basic[
  判断并行性的关键是看 #term[依赖关系 (dependency)]。三类数据依赖（"冒险"的软件视角）：

  / 流依赖 (RAW, 真依赖): 后者读前者写的值，*不可消除*，是并行的真正障碍。
  / 反依赖 (WAR): 后者写、前者读同一地址，可通过*重命名 / 用新存储*消除。
  / 输出依赖 (WAW): 两者都写同一地址，同样可通过重命名消除。

  只有真依赖会强制顺序。没有真依赖的迭代 / 任务即可并行。
]

#tip[
  考试判断"循环能否并行"的口诀：检查是否存在 *循环携带的真依赖 (loop-carried RAW dependency)*。如果第 `i` 次迭代要用到第 `i-1` 次迭代写的值，就不能直接并行（如前缀和、递推）；如果每次迭代只读写自己的数据，则天然可并行。
]

=== 并行模式分类

#table(
  columns: (auto, 1fr, 1fr),
  table.header([模式], [特征], [本章例子]),
  [数据并行], [同一操作作用于数据的不同部分], [数组映射、热传导、波动],
  [任务并行], [不同任务并发执行], [流水线、分治],
  [规约 (reduce)], [多个值聚合成一个], [求和、求 π、求最大],
  [流水线 (pipeline)], [数据流经多个阶段], [图像处理流水],
  [分治 (divide & conquer)], [递归拆分后合并], [并行归并排序],
)

== 例一：对数组每个元素做函数计算（embarrassingly parallel）

#basic[
  计算 $b[i] = f(a[i])$。每个元素独立，*无任何依赖*，是"易并行 (embarrassingly parallel)"的典范，加速比可接近线性。这是数据并行的最简形式。
]

#sidebyside(
  left-label: "Rust (rayon)",
  rustcode[
    ```rust
    use rayon::prelude::*;

    fn apply<F>(a: &[f64], f: F) -> Vec<f64>
    where F: Fn(f64) -> f64 + Sync {
        // par_iter 自动把区间切块、分发到线程池
        a.par_iter().map(|&x| f(x)).collect()
    }

    fn main() {
        let a: Vec<f64> = (0..1_000_000)
            .map(|i| i as f64).collect();
        let b = apply(&a, |x| x.sqrt() * 2.0);
        println!("{}", b[42]);
    }
    ```
  ],
  ccode[
    ```c
    #include <omp.h>
    #include <math.h>

    void apply(const double* a, double* b, int n) {
        // 每次迭代独立 -> 直接并行 for
        #pragma omp parallel for
        for (int i = 0; i < n; i++) {
            b[i] = sqrt(a[i]) * 2.0;
        }
    }
    ```
  ],
)

#note[
  给 Rust 程序员的对照说明：
  - rayon 的 `par_iter()` 在 API 上几乎等价于 `iter()`，背后是*工作窃取 (work-stealing)* 线程池，自动负载均衡。Rust 的 `Sync`/`Send` 约束在编译期保证闭包跨线程安全。
  - C 这边靠 OpenMP 的 `#pragma omp parallel for` 编译制导，运行时把循环迭代分给各线程。C 没有借用检查，是否存在数据竞争完全靠程序员自己保证——这正是并行 C 代码 bug 的高发区。
]

== 例二：蒙特卡洛求 π（随机掷点 + 规约）

#basic[
  在 $[0,1] times [0,1]$ 单位正方形内随机撒 $N$ 个点，落入四分之一单位圆 ($x^2 + y^2 <= 1$) 内的点数为 $M$。由面积比：
  $ pi / 4 approx M / N => pi approx 4 M / N $

  这是*数据并行 + 规约*的代表：每个线程独立掷一批点并各自计数（局部规约），最后把所有局部计数加起来（全局规约）。
]

#advanced[
  并行随机数的*坑*：绝不能让多个线程共享同一个随机数生成器 (RNG) 状态——既有数据竞争，又会破坏统计独立性。正确做法是*每个线程持有独立的 RNG*，并用不同种子（如线程号）初始化。
]

#sidebyside(
  left-label: "Rust (rayon + rand)",
  rustcode[
    ```rust
    use rayon::prelude::*;
    use rand::{Rng, SeedableRng};
    use rand::rngs::StdRng;

    fn estimate_pi(n: usize) -> f64 {
        let hits: usize = (0..n)
            .into_par_iter()
            // 每块用独立 RNG（map_init 懒初始化）
            .map_init(
                || StdRng::from_entropy(),
                |rng, _| {
                    let x: f64 = rng.gen();
                    let y: f64 = rng.gen();
                    (x*x + y*y <= 1.0) as usize
                })
            .sum();              // 并行规约求和
        4.0 * hits as f64 / n as f64
    }
    ```
  ],
  ccode[
    ```c
    #include <omp.h>
    #include <stdlib.h>

    double estimate_pi(long n) {
        long hits = 0;
        #pragma omp parallel
        {
            // 每线程独立种子，避免共享 RNG
            unsigned seed = 12345u +
                            omp_get_thread_num();
            long local = 0;
            #pragma omp for
            for (long i = 0; i < n; i++) {
                double x = (double)rand_r(&seed)
                           / RAND_MAX;
                double y = (double)rand_r(&seed)
                           / RAND_MAX;
                if (x*x + y*y <= 1.0) local++;
            }
            // reduction 子句也可自动完成此步
            #pragma omp atomic
            hits += local;
        }
        return 4.0 * hits / n;
    }
    ```
  ],
)

#tip[
  规约 (reduction) 是高频考点。手写规约的两要点：(1) 每线程先在*线程本地变量*上累加（避免争用）；(2) 最后用原子操作 / 临界区 / `reduction` 子句把局部结果合并。直接对共享变量 `hits++` 会产生数据竞争，结果偏小且不确定。
]

== 例三：二维热传导（有限差分 / 模板计算）

#basic[
  二维热传导方程的显式差分格式：新温度 = 上下左右四邻居当前温度的平均（带系数）。这是典型的 #term[模板计算 (stencil)]：
  $ u_(i,j)^(t+1) = u_(i,j)^t + alpha (u_(i+1,j)^t + u_(i-1,j)^t + u_(i,j+1)^t + u_(i,j-1)^t - 4 u_(i,j)^t) $

  关键性质：第 $t+1$ 步的值*只依赖第 $t$ 步*的值。因此同一时间步内所有网格点*互不依赖*，可完全并行；步与步之间则必须串行（时间方向有真依赖）。
]

#note[
  *双缓冲 (double buffering / ping-pong) 是正确性的关键*：必须用两块数组 `cur` 和 `next`，从 `cur` 读、向 `next` 写，一步算完再交换。若*原地更新*（边读边写同一数组），某些邻居已被本步更新、某些还是上一步，结果错误——这是 Jacobi 迭代与 Gauss-Seidel 迭代的本质区别（见例五）。
]

#sidebyside(
  left-label: "Rust (rayon, 双缓冲)",
  rustcode[
    ```rust
    use rayon::prelude::*;

    // cur/next 为 (h x w) 行主序，边界固定
    fn step(cur: &[f64], next: &mut [f64],
            h: usize, w: usize, a: f64) {
        // 按"行"并行：每行独立写 next
        next.par_chunks_mut(w)
            .enumerate()
            .for_each(|(i, row)| {
                if i == 0 || i == h-1 { return; }
                for j in 1..w-1 {
                    let c = cur[i*w + j];
                    row[j] = c + a * (
                        cur[(i+1)*w + j] +
                        cur[(i-1)*w + j] +
                        cur[i*w + j+1] +
                        cur[i*w + j-1] - 4.0*c);
                }
            });
    }
    // 主循环: for _ in 0..steps { step(..);
    //          std::mem::swap(&mut cur, &mut next); }
    ```
  ],
  ccode[
    ```c
    #include <omp.h>
    // cur/next: h*w 行主序，边界固定
    void step(const double* cur, double* next,
              int h, int w, double a) {
        // 对行循环并行；每个 (i,j) 只读 cur、写 next
        #pragma omp parallel for collapse(2)
        for (int i = 1; i < h-1; i++) {
            for (int j = 1; j < w-1; j++) {
                double c = cur[i*w + j];
                next[i*w + j] = c + a * (
                    cur[(i+1)*w + j] +
                    cur[(i-1)*w + j] +
                    cur[i*w + j+1] +
                    cur[i*w + j-1] - 4.0*c);
            }
        }
    }
    // 主循环里每步后交换 cur/next 指针
    ```
  ],
)

#advanced[
  *分布式版本的"鬼影 / 光晕交换 (halo / ghost exchange)"*：若把网格按行块分给多个 MPI 进程，每个进程算自己那几行时需要相邻进程边界行的值。于是每步开始前，相邻进程要交换边界行（ghost rows）。这是 MPI 中模板计算的标准模式，第三章会用到。`collapse(2)` 把两层循环合并成一个更大的迭代空间以改善负载均衡。
]

== 例四：一维波动方程（三时间层依赖）

#basic[
  一维波动方程的差分格式，新位移依赖*当前层左右邻居*与*前一层自身*：
  $ A_i^(t+1) = 2 A_i^t - A_i^(t-1) + C (A_(i+1)^t - 2 A_i^t + A_(i-1)^t) $
  其中 $C = (c Delta t \/ Delta x)^2$ 是 Courant 数的平方。

  依赖分析：$A_i^(t+1)$ 用到 $A_i^t, A_(i-1)^t, A_(i+1)^t, A_i^(t-1)$。所以需要保存*三个时间层*（`prev`、`cur`、`next`）。同一时间步内各点仍互不依赖，可并行；时间步之间串行。
]

#sidebyside(
  left-label: "Rust (rayon, 三缓冲)",
  rustcode[
    ```rust
    use rayon::prelude::*;

    fn step(prev: &[f64], cur: &[f64],
            next: &mut [f64], c: f64) {
        let n = cur.len();
        next.par_iter_mut().enumerate()
            .for_each(|(i, out)| {
                if i == 0 || i == n-1 {
                    *out = 0.0;      // 固定边界
                } else {
                    *out = 2.0*cur[i] - prev[i]
                        + c*(cur[i+1] - 2.0*cur[i]
                             + cur[i-1]);
                }
            });
    }
    // 每步后轮转: prev <- cur <- next <- prev
    ```
  ],
  ccode[
    ```c
    #include <omp.h>
    void step(const double* prev, const double* cur,
              double* next, int n, double c) {
        #pragma omp parallel for
        for (int i = 1; i < n-1; i++) {
            next[i] = 2.0*cur[i] - prev[i]
                    + c*(cur[i+1] - 2.0*cur[i]
                         + cur[i-1]);
        }
        next[0] = next[n-1] = 0.0;  // 固定边界
    }
    // 每步后轮转三个缓冲区指针
    ```
  ],
)

#tip[
  热传导 vs 波动方程的考点对比：热传导是*两时间层*（一阶时间导数），波动是*三时间层*（二阶时间导数，需保存 `prev`）。两者都是空间上可完全并行、时间上严格串行的模板计算。
]

== 例五：高斯-塞德尔迭代与依赖

#basic[
  解线性方程组（或更新网格）时：
  / 雅可比 (Jacobi): 全部用*上一轮*的旧值更新（例三即此）。各点独立 → 完全可并行，但收敛慢。
  / 高斯-塞德尔 (Gauss-Seidel): 更新某点时，*已更新过的邻居用新值*。收敛更快，但引入了*循环携带依赖*，不能像 Jacobi 那样直接并行。
]

一维示例，更新 `x[i]` 用到刚算好的 `x[i-1]`：

#rustcode[
  ```rust
  // 串行 Gauss-Seidel：x[i] 依赖刚更新的 x[i-1]（真依赖！）
  fn gauss_seidel(x: &mut [f64], b: &[f64], iters: usize) {
      let n = x.len();
      for _ in 0..iters {
          for i in 1..n-1 {
              // 用到本轮已更新的 x[i-1] 和本轮尚未更新的 x[i+1]
              x[i] = 0.5 * (x[i-1] + x[i+1] + b[i]);
          }
      }
  }
  ```
]

#advanced[
  *如何并行化 Gauss-Seidel —— 红黑排序 (Red-Black Ordering)*：

  把网格像棋盘一样染成红黑两色（按 $(i+j)$ 的奇偶）。模板计算中每个点只依赖异色邻居，于是：
  + *先并行更新所有红点*（它们只依赖黑点，互不依赖）；
  + *再并行更新所有黑点*（此时用上一阶段刚更新的红点新值）。

  这样既保留了 Gauss-Seidel "用新值"的快速收敛，又在每个颜色阶段内获得完全并行性。这是并行求解 PDE 的经典技巧。
]

#ccode[
  ```c
  // 红黑高斯-塞德尔（二维），每步两个并行 phase
  void rb_gauss_seidel(double* u, const double* f,
                       int h, int w) {
      for (int color = 0; color < 2; color++) {     // 0=红, 1=黑
          #pragma omp parallel for collapse(2)
          for (int i = 1; i < h-1; i++)
              for (int j = 1; j < w-1; j++)
                  if (((i + j) & 1) == color)        // 只更新本色
                      u[i*w+j] = 0.25 * (u[(i-1)*w+j] + u[(i+1)*w+j]
                                       + u[i*w+j-1] + u[i*w+j+1]
                                       - f[i*w+j]);
      }
  }
  ```
]

== 锁与屏障的简单应用

#basic[
  并行的两大同步原语：

  / 锁 / 互斥 (Mutex): 保证同一时刻只有一个线程进入*临界区 (critical section)*，用于保护共享可变状态。
  / 屏障 (Barrier): 所有线程必须都到达屏障点后，才能一起继续。用于*阶段同步*——如模板计算中"所有线程算完本时间步，才能进入下一步"。
]

#sidebyside(
  left-label: "Rust (Mutex / Barrier)",
  rustcode[
    ```rust
    use std::sync::{Arc, Mutex, Barrier};
    use std::thread;

    fn main() {
        let counter = Arc::new(Mutex::new(0));
        let barrier = Arc::new(Barrier::new(4));
        let mut hs = vec![];
        for _ in 0..4 {
            let c = Arc::clone(&counter);
            let b = Arc::clone(&barrier);
            hs.push(thread::spawn(move || {
                {   // 临界区：锁自动随作用域释放
                    let mut g = c.lock().unwrap();
                    *g += 1;
                }
                b.wait();  // 屏障：等齐 4 个线程
            }));
        }
        for h in hs { h.join().unwrap(); }
        println!("{}", *counter.lock().unwrap());
    }
    ```
  ],
  ccode[
    ```c
    #include <pthread.h>
    pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    pthread_barrier_t bar;
    int counter = 0;

    void* worker(void* arg) {
        pthread_mutex_lock(&lock);   // 进入临界区
        counter++;
        pthread_mutex_unlock(&lock); // 离开（必须手动）
        pthread_barrier_wait(&bar);  // 屏障同步
        return NULL;
    }
    int main(void) {
        pthread_t t[4];
        pthread_barrier_init(&bar, NULL, 4);
        for (int i=0;i<4;i++)
            pthread_create(&t[i],NULL,worker,NULL);
        for (int i=0;i<4;i++) pthread_join(t[i],NULL);
        pthread_barrier_destroy(&bar);
    }
    ```
  ],
)

#note[
  Rust 用 RAII（`MutexGuard` 离开作用域自动 `unlock`）杜绝"忘记解锁"；而 C 必须手动配对 `lock`/`unlock`，一旦在临界区里 `return` 或出错提前退出就会*死锁*。这是 C 并行编程的经典陷阱，开卷时要特别留意题目中是否存在"加锁后未解锁"的路径。
]

== 调度、编排与依赖关系分析

#basic[
  / 静态调度 (static): 任务在运行前就划分好分给各线程（如 OpenMP `schedule(static)`）。开销低，适合每次迭代工作量均匀的场景。
  / 动态调度 (dynamic): 线程做完一块再领下一块（`schedule(dynamic)`）。负载均衡好，适合迭代耗时不均（如不同 `i` 计算量差异大）。
  / 引导调度 (guided): 块大小先大后小，兼顾开销与均衡。
  / 工作窃取 (work-stealing): 空闲线程从忙线程的队列尾部"偷"任务。rayon、Cilk 采用此策略，是动态负载均衡的高级形式。
]

#advanced[
  *任务图 (DAG) 与编排*：把计算建模成有向无环图，节点是任务、边是依赖。可并行性由图的结构决定：

  - *关键路径 (critical path)*：图中最长的依赖链，其长度 $T_infinity$ 决定了*无论多少处理器*的最短完成时间下界。
  - *工作量 $T_1$*：所有任务串行执行的总时间。
  - *并行度* $approx T_1 \/ T_infinity$。

  Brent 定理给出 $p$ 个处理器的运行时间界：$T_p <= T_1 \/ p + T_infinity$。这是衡量任务并行程序可扩展性的理论工具。
]

#example(title: "依赖关系判断")[
  下面两个循环，哪个可以直接并行？为什么？

  ```
  // 循环 A
  for i in 1..n { a[i] = a[i] + b[i]; }
  // 循环 B
  for i in 1..n { a[i] = a[i-1] + b[i]; }
  ```

  #solution[
    - *循环 A 可并行*：第 `i` 次迭代只读写自己的 `a[i]`、读 `b[i]`，迭代之间无依赖（无循环携带依赖）。
    - *循环 B 不可直接并行*：`a[i]` 依赖*本循环上一次迭代刚写的* `a[i-1]`，存在循环携带的真依赖（RAW），本质是前缀和 (prefix sum)。需用专门的*并行扫描 (parallel scan)* 算法（如 Blelloch 扫描，$O(log n)$ 步）才能并行。
  ]
]

== 章末考试预测专区

#exam-section()

#pred(tags: ("依赖分析", "高频"))[
  给定循环 `for (i=2; i<n; i++) a[i] = a[i-2] + c;`。它能否并行？若能，说明如何划分；若部分能，请给出方案。
]
#analysis[
  存在循环携带依赖，但*跨度为 2*：`a[i]` 只依赖 `a[i-2]`。因此偶数下标构成一条独立链、奇数下标构成另一条独立链，两条链之间无依赖。
  方案：把奇、偶下标分成*两组分别并行执行*（组间并行，组内仍是顺序前缀递推）。或更一般地，这是步长为 2 的递推，可拆成 2 个独立子序列。注意：每个子序列内部仍是串行前缀依赖，需用并行扫描才能进一步并行。
]

#pred(tags: ("Jacobi vs GS", "PDE"))[
  比较雅可比迭代与高斯-塞德尔迭代在并行化上的难易，并说明红黑排序如何让 Gauss-Seidel 可并行。
]
#analysis[
  - *Jacobi*：所有点都用上一轮旧值更新，同一轮内各点完全独立，天然可并行（只需双缓冲），但收敛慢。
  - *Gauss-Seidel*：更新时使用本轮已更新邻居的新值，引入循环携带依赖，按自然序无法直接并行，但收敛快。
  - *红黑排序*：按 $(i+j)$ 奇偶把网格染成红、黑两色。在五点模板下每个点只依赖异色邻居。于是先并行更新全部红点（仅依赖黑点旧值），再并行更新全部黑点（依赖红点新值）。每个颜色阶段内部完全独立可并行，整体保留了"用新值"的快速收敛，两阶段之间用屏障隔开。
]

#pred(tags: ("并行 RNG", "蒙特卡洛"))[
  用多线程做蒙特卡洛求 π 时，若所有线程共享同一个随机数生成器会有什么问题？正确做法是什么？
]
#analysis[
  两个问题：(1) *数据竞争*——多个线程同时读写 RNG 内部状态，未加锁则行为未定义、结果不可复现；若加锁则 RNG 成为串行瓶颈，几乎抵消并行收益。(2) *统计相关性*——即便加锁，线程交错取数也可能破坏序列的独立性，影响估计质量。
  正确做法：每个线程持有*独立的 RNG 实例*，用互不相同的种子（如基于线程号、或使用专门的可分流 RNG 如 counter-based RNG / `SplitMix`）初始化，使各线程生成统计独立的随机流。最后对各线程的局部命中计数做规约求和。
]

#pred(tags: ("屏障", "正确性"))[
  在二维热传导的并行实现中，如果忘记在每个时间步之间放置屏障（barrier），会发生什么？为什么必须用双缓冲？
]
#analysis[
  - *缺少屏障*：某些线程可能已经进入第 $t+1$ 步的计算，而另一些线程还在算第 $t$ 步。快线程会读到部分被更新、部分未更新的邻居值，导致*时间层错乱*，结果错误且不可复现。屏障保证"全员算完本步才进入下一步"。
  - *必须双缓冲*：每个点的新值依赖四邻居的*本步旧值*。若原地更新（读写同一数组），先算的点会覆盖邻居的旧值，后算的点就读到新值而非旧值，破坏 Jacobi 语义。用 `cur`(读) / `next`(写) 两块缓冲，算完再交换指针即可保证全部读到一致的旧值。
]

#pred(tags: ("调度", "负载均衡"))[
  某并行循环各次迭代的计算量差异很大（有的快有的慢）。用 `schedule(static)` 还是 `schedule(dynamic)`？为什么？静态调度的优点是什么？
]
#analysis[
  应优先用 `schedule(dynamic)`（或 `guided`）。原因：迭代耗时不均时，静态调度把固定迭代块预先分给线程，可能某线程分到一堆"慢"迭代而其他线程早早闲置，造成*负载不均*、整体被最慢线程拖累。动态调度让线程做完一块再领新块，自动趋于均衡。
  静态调度的优点：*调度开销极低*（无运行时任务分发）、内存访问可预测、无锁争用；当各迭代工作量均匀时，静态调度通常最快。可用 `dynamic, chunk` 调整块大小在"均衡"和"开销"间折中。
]

#pred(tags: ("任务图", "关键路径"))[
  某并行程序总工作量 $T_1 = 100$，关键路径长度 $T_infinity = 10$。(1) 它的最大并行度约为多少？(2) 用 5 个处理器时，根据 Brent 定理运行时间的上界是多少？(3) 无论多少处理器，最快能到多少？
]
#analysis[
  - (1) 并行度 $approx T_1 \/ T_infinity = 100 \/ 10 = 10$。即超过约 10 个处理器后收益递减。
  - (2) Brent 定理：$T_p <= T_1 \/ p + T_infinity = 100 \/ 5 + 10 = 20 + 10 = 30$。
  - (3) 关键路径是下界：$T_infinity = 10$，无论多少处理器都不可能快于关键路径，故最快约为 10。
]
