#import "../lib/template.typ": *

= OpenMP

#chapter-intro[
  OpenMP 是共享内存并行的事实标准，以*编译制导 (pragma)* 的方式"标注"现有串行代码即可并行，学习曲线平缓但内涵丰富。本章系统覆盖：并行区域、工作分担构造（for / sections / single / workshare）、任务构造（task / taskwait）、同步构造（master / critical / barrier / atomic / flush / ordered）、数据环境子句（private / shared / firstprivate / lastprivate / reduction / copyin / copyprivate / default）以及 threadprivate。OpenMP 原生是 C/C++/Fortran 的；Rust 没有官方 OpenMP，本章用 rayon / crossbeam 给出等价思路对照，帮你用 Rust 直觉理解每个构造。
]

== 执行模型与编译

#basic[
  / Fork-Join 模型: 程序以单线程（主线程）运行，遇到 `#pragma omp parallel` 时*派生 (fork)* 出一组线程并行执行，区域结束时*汇合 (join)* 回单线程。
  / 制导格式: `#pragma omp <construct> [clause...]`，作用于其后的*结构化块*（一条语句或 `{...}`）。
  / 编译: `gcc -fopenmp prog.c`。线程数由 `OMP_NUM_THREADS` 环境变量或 `omp_set_num_threads()` 控制。
  / 运行时函数: `omp_get_thread_num()`（线程号）、`omp_get_num_threads()`（线程数）。
]

#sidebyside(
  left-label: "C：最小并行区域",
  ccode[
    ```c
    #include <omp.h>
    #include <stdio.h>
    int main(void) {
        #pragma omp parallel
        {
            int id = omp_get_thread_num();
            int np = omp_get_num_threads();
            printf("hello from %d/%d\n", id, np);
        }   // 隐式 barrier + join
        return 0;
    }
    ```
  ],
  rustcode[
    ```rust
    // Rust 无 OpenMP；用 rayon 作用域线程类比
    use rayon::prelude::*;
    fn main() {
        // 让线程池中每个线程各打印一次（示意）
        let n = rayon::current_num_threads();
        (0..n).into_par_iter().for_each(|_| {
            let id = rayon::current_thread_index()
                         .unwrap();
            println!("hello from {}/{}", id, n);
        });
    }
    ```
  ],
)

#note[
  类比给 Rust 程序员：OpenMP 的 `parallel` 区域 ≈ rayon 的"在线程池上跑一段并行工作"。但 OpenMP 是*命令式标注*——同一段代码被所有线程执行，靠线程号分流；rayon 是*数据并行迭代器*。理解 OpenMP 时请想象"这段花括号被 N 个线程同时各跑一遍"。
]

== 并行区域 (parallel)

#basic[
  `#pragma omp parallel` 是一切的起点：它*只负责创建线程组*，让块内代码被每个线程执行一遍。真正"分工"要靠内部的工作分担构造（for / sections）。常见误区：单独的 `parallel { for... }` 中那个普通 `for` 会被*每个线程完整跑一遍*（重复计算），必须配合 `omp for` 才能分摊迭代。
]

#ccode[
  ```c
  // 错误意图：以为循环被分摊，其实每个线程都跑了完整 0..N
  #pragma omp parallel
  {
      for (int i = 0; i < N; i++) work(i);   // 重复 N*线程数 次！
  }

  // 正确：parallel 建线程组，for 分摊迭代
  #pragma omp parallel
  {
      #pragma omp for
      for (int i = 0; i < N; i++) work(i);   // 迭代被瓜分
  }

  // 合并写法（最常用）
  #pragma omp parallel for
  for (int i = 0; i < N; i++) work(i);
  ```
]

== 工作分担构造

=== for / DO 构造

#basic[
  `#pragma omp for` 把紧随的 `for` 循环迭代分配给线程组（Fortran 中为 `!$omp do`）。要求循环是*规范形式*（计数可知、无 break）。子句 `schedule` 控制分配策略：
  - `static[,chunk]`：迭代静态轮流分块，开销低，适合均匀负载。
  - `dynamic[,chunk]`：线程做完一块领下一块，适合不均负载。
  - `guided`：块大小递减。
  - `runtime`：由 `OMP_SCHEDULE` 决定。

  `for` 末尾有*隐式 barrier*，可用 `nowait` 取消。
]

#sidebyside(
  left-label: "C：带 schedule 的 for",
  ccode[
    ```c
    #pragma omp parallel for schedule(dynamic, 16)
    for (int i = 0; i < N; i++) {
        result[i] = heavy_uneven_work(i);
    }
    ```
  ],
  rustcode[
    ```rust
    use rayon::prelude::*;
    // rayon 自动用工作窃取做动态负载均衡
    result.par_iter_mut().enumerate()
        .for_each(|(i, r)| {
            *r = heavy_uneven_work(i);
        });
    ```
  ],
)

=== sections 构造（任务并行）

#basic[
  `#pragma omp sections` 把*不同的代码块*分给不同线程并行执行（功能并行，而非数据并行）。每个 `#pragma omp section` 是一个独立任务，由某个线程执行一次。适合"几个互相独立的步骤同时做"。
]

#sidebyside(
  left-label: "C：sections",
  ccode[
    ```c
    #pragma omp parallel sections
    {
        #pragma omp section
        { compute_part_A(); }   // 线程 1

        #pragma omp section
        { compute_part_B(); }   // 线程 2

        #pragma omp section
        { compute_part_C(); }   // 线程 3
    }   // 隐式 barrier
    ```
  ],
  rustcode[
    ```rust
    // rayon::join 做两路；多路用嵌套或 scope
    rayon::scope(|s| {
        s.spawn(|_| compute_part_a());
        s.spawn(|_| compute_part_b());
        s.spawn(|_| compute_part_c());
    });  // scope 结束等所有 spawn 完成
    ```
  ],
)

=== single 与 master

#basic[
  / `#pragma omp single`: 块内代码*只由一个（任意）线程*执行，其余线程在末尾 barrier 等待（除非 `nowait`）。常用于并行区域内只需做一次的事（如读输入、打印）。可带 `copyprivate` 把该线程算出的值广播给其他线程。
  / `#pragma omp master`: 块内代码*只由主线程 (id 0)* 执行，*无隐式 barrier*。其它线程直接跳过继续。
  区别：`single` = 任意一个线程 + 末尾屏障；`master` = 必须主线程 + 无屏障。
]

=== workshare（Fortran）

#advanced[
  `#pragma omp workshare`（仅 Fortran）把块内的*数组赋值、`FORALL`、`WHERE` 等数组语句*的工作分摊给线程。例如 Fortran 的 `A = B + C`（整数组运算）放在 `workshare` 中会被并行化。C/C++ 没有此构造（因为 C 没有原生整数组运算语义），对应需求在 C 中用 `omp for` 手写循环实现。考试若问"workshare 用于哪种语言"，答 Fortran。
]

== 任务构造 (task / taskwait)

#basic[
  `#pragma omp task` 创建一个*显式任务*（一段可被任意线程延迟执行的代码 + 其数据环境），放入任务池，由线程组中的空闲线程取出执行。适合*不规则 / 递归 / 数量未知*的并行（如遍历链表、树、递归分治），弥补 `for`（需预知迭代次数）的不足。

  / `#pragma omp taskwait`: 等待*当前任务直接产生的子任务*全部完成（不含孙任务）。
  / 数据作用域: 任务的数据默认是 `firstprivate`（按值捕获创建时的值）。
]

#sidebyside(
  left-label: "C：task 递归斐波那契",
  ccode[
    ```c
    int fib(int n) {
        if (n < 2) return n;
        int x, y;
        #pragma omp task shared(x)
        x = fib(n - 1);
        #pragma omp task shared(y)
        y = fib(n - 2);
        #pragma omp taskwait      // 等两个子任务
        return x + y;
    }
    // 调用处：
    // #pragma omp parallel
    // #pragma omp single
    //     printf("%d", fib(30));
    ```
  ],
  rustcode[
    ```rust
    // rayon::join 是 fork-join 任务并行的直接对应
    fn fib(n: u64) -> u64 {
        if n < 2 { return n; }
        let (x, y) = rayon::join(
            || fib(n - 1),
            || fib(n - 2),
        );          // 自动等两个子任务完成
        x + y
    }
    ```
  ],
)

#tip[
  常考"为什么 task 区域外面要套 `parallel` + `single`"：`parallel` 先创建线程组（提供执行任务的线程），`single` 保证递归*只由一个线程发起*（否则每个线程都从头跑一遍 fib，重复且爆炸）；发起后，池中其他线程才来分担 `task` 池里的任务。
]

== 同步构造

=== critical（临界区）

#basic[
  `#pragma omp critical [(name)]`：保证同一时刻只有一个线程进入该块，保护共享数据。匿名 critical 全局互斥；带名字的 critical 只与同名的互斥（可减少不相关临界区的争用）。开销比 `atomic` 大（是通用互斥锁）。
]

=== atomic（原子操作）

#basic[
  `#pragma omp atomic`：对*单条* `读-改-写`内存操作（如 `x += v`、`x++`）做硬件级原子保护，比 `critical` 轻量得多。仅适用于简单标量更新，不能保护任意代码块。
]

#sidebyside(
  left-label: "C：atomic vs critical",
  ccode[
    ```c
    long sum = 0;
    #pragma omp parallel for
    for (int i = 0; i < N; i++) {
        // 轻量：单个加法原子化
        #pragma omp atomic
        sum += a[i];
    }

    // 复合更新需要 critical
    #pragma omp parallel for
    for (int i = 0; i < N; i++) {
        #pragma omp critical
        { update_histogram(hist, a[i]); }  // 多步操作
    }
    ```
  ],
  rustcode[
    ```rust
    use std::sync::atomic::{AtomicI64, Ordering};
    use rayon::prelude::*;

    let sum = AtomicI64::new(0);
    a.par_iter().for_each(|&x| {
        // 原子加，等价于 #pragma omp atomic
        sum.fetch_add(x, Ordering::Relaxed);
    });
    // 复合更新则用 Mutex<...> 包裹（≈ critical）
    ```
  ],
)

#note[
  但求和的*正确做法是 `reduction`*（见下），而非 atomic/critical——后者让所有线程争抢一个变量，退化成串行。考点：能区分"需要原子的少量更新"和"应该用 reduction 的归约"。
]

=== barrier

#basic[
  `#pragma omp barrier`：显式屏障，线程组所有线程到齐才继续。`for`/`sections`/`single` 末尾本就有*隐式 barrier*。`barrier` 必须被所有线程都遇到，*不能放在 `single`/`master`/分支里只让部分线程执行*，否则死锁。
]

=== ordered

#basic[
  `#pragma omp ordered`：在并行 `for`（需声明 `ordered` 子句）中，强制其内部代码块*按迭代原始顺序*执行。用于并行计算、但输出 / 某步骤必须保持串行次序的场景。
]

#ccode[
  ```c
  #pragma omp parallel for ordered schedule(static)
  for (int i = 0; i < N; i++) {
      int r = heavy_compute(i);   // 这部分并行
      #pragma omp ordered
      printf("%d: %d\n", i, r);   // 这部分严格按 i 升序输出
  }
  ```
]

=== atomic 的 flush 内存语义

#advanced[
  `#pragma omp flush[(list)]`：强制把线程的*寄存器/缓存中的值与主存同步*，建立内存一致性的"栅栏 (memory fence)"。OpenMP 采用宽松内存模型，线程可能缓存共享变量；`flush` 保证此点之前的写对其他线程可见、之后的读取到最新值。
  - 多数同步构造（barrier、critical 进出、atomic、任务调度点）*隐含 flush*，故通常无需手写。
  - 只有在用裸共享标志位做自旋等待这类"手工同步"时才需显式 `flush`。这与 Rust 的 `std::sync::atomic::fence` / `Ordering` 是同一回事。
]

#ccode[
  ```c
  // 手工"生产者-消费者就绪标志"必须 flush，否则可能死循环
  int flag = 0, data = 0;
  // 生产者：
  data = 42;
  #pragma omp flush          // 确保 data 写出，再设标志
  flag = 1;
  #pragma omp flush(flag)
  // 消费者：
  while (1) {
      #pragma omp flush(flag)
      if (flag) break;
  }
  #pragma omp flush          // 确保读到最新 data
  use(data);
  ```
]

== 数据环境子句

#basic[
  并行区域里，变量是"共享"还是"每线程私有一份"由数据子句决定，这是 OpenMP *正确性*的核心。

  #table(
    columns: (auto, 1fr),
    table.header([子句], [语义]),
    [`shared(x)`], [所有线程共享同一个 `x`（需自己防竞争）],
    [`private(x)`], [每线程一份私有 `x`，*未初始化*，区域结束丢弃],
    [`firstprivate(x)`], [私有，且*用进入前的值初始化*],
    [`lastprivate(x)`], [私有，循环*最后一次迭代*的值写回原变量],
    [`default(none\|shared)`], [设默认作用域；`none` 强制显式声明每个变量（推荐）],
    [`reduction(op:x)`], [每线程私有副本，结束按 `op` 合并回 `x`],
    [`copyin(x)`], [把主线程的 threadprivate 值拷给各线程],
    [`copyprivate(x)`], [`single` 中把该线程的值广播给其它线程],
  )
]

=== private / firstprivate / lastprivate

#sidebyside(
  left-label: "C：三种 private 对比",
  ccode[
    ```c
    int x = 5;
    #pragma omp parallel for \
        private(tmp) firstprivate(x) lastprivate(last)
    for (int i = 0; i < N; i++) {
        int tmp;          // private: 每线程独有, 初值未定义
        tmp = x + i;      // x: firstprivate, 各线程初值=5
        last = tmp;       // lastprivate: 写回 i==N-1 的值
        out[i] = tmp;
    }
    // 循环后: last == (5 + (N-1))，x 仍为 5
    ```
  ],
  rustcode[
    ```rust
    // Rust 中"私有"是默认：闭包内局部变量天然每线程独立
    use rayon::prelude::*;
    let x = 5;                 // 被各闭包按值捕获 ≈ firstprivate
    out.par_iter_mut().enumerate()
       .for_each(|(i, o)| {
           let tmp = x + i as i32;  // 局部 ≈ private
           *o = tmp;
       });
    // lastprivate 无直接对应：需单独取最后一个元素的结果
    ```
  ],
)

#tip[
  高频陷阱：在 `parallel for` 中，*循环计数变量自动是 private*，但循环内声明/使用的临时变量若在外部声明且未标 `private`，会被默认 `shared`，引发数据竞争。考试看到"循环里用到一个外部临时变量"就要警惕是否漏了 `private`。
]

=== reduction（归约）

#basic[
  `reduction(op : var)` 是并行求和/求积/求极值的标准武器。每个线程获得 `var` 的*私有副本*（按 `op` 初始化：`+`→0，`*`→1，`max`→最小值…），各自累加，区域结束时 OpenMP 自动用 `op` 把所有副本合并回原 `var`。无竞争、无需手写 atomic。
]

#sidebyside(
  left-label: "C：reduction 求和（π 积分）",
  ccode[
    ```c
    long n = 1000000; double h = 1.0/n, sum = 0.0;
    #pragma omp parallel for reduction(+:sum)
    for (long i = 0; i < n; i++) {
        double x = (i + 0.5) * h;
        sum += 4.0 / (1.0 + x*x);   // 各线程私有 sum
    }
    double pi = sum * h;   // 自动合并后乘 h
    ```
  ],
  rustcode[
    ```rust
    use rayon::prelude::*;
    let n = 1_000_000u64; let h = 1.0 / n as f64;
    // map + sum 即并行归约，语义同 reduction(+)
    let sum: f64 = (0..n).into_par_iter().map(|i| {
        let x = (i as f64 + 0.5) * h;
        4.0 / (1.0 + x * x)
    }).sum();
    let pi = sum * h;
    ```
  ],
)

=== threadprivate / copyin / copyprivate

#basic[
  / `#pragma omp threadprivate(var)`: 把*全局/静态*变量声明为*每线程一份持久副本*，跨多个并行区域保持各自的值（不像 `private` 那样区域结束就丢）。类似线程本地存储 (TLS)。
  / `copyin(var)`: 进入并行区域时，把*主线程*的 threadprivate 值*拷贝*到各线程的副本，做统一初始化。
  / `copyprivate(var)`: 仅用于 `single`，把执行 single 的那个线程算出的私有值*广播*给组内其它线程（常用于"一个线程读配置，分发给全体"）。
]

#ccode[
  ```c
  static int counter = 0;
  #pragma omp threadprivate(counter)   // 每线程独立的 counter

  void demo(void) {
      #pragma omp parallel copyin(counter)  // 各线程从主线程值起步
      {
          counter++;       // 互不干扰，各自累加
      }
  }

  // copyprivate：single 线程读到的 cfg 广播给所有线程
  int cfg;
  #pragma omp parallel
  {
      #pragma omp single copyprivate(cfg)
      { cfg = read_config(); }   // 仅一个线程读
      use_config(cfg);           // 所有线程都拿到同一值
  }
  ```
]

#note[
  Rust 对照：`threadprivate` ≈ `thread_local!` 宏定义的线程本地变量。`copyin` / `copyprivate` 没有直接语法对应，需手动用 channel / 共享只读数据 (`Arc`) 分发。OpenMP 的这些子句本质都是在"共享内存"模型下精细控制变量的可见范围和初值。
]

== 综合示例：并行数组归约 + 阶段同步

#example(title: "两阶段：并行求和后归一化")[
  先并行求数组总和（reduction），再用该和并行归一化每个元素。两阶段之间需要同步。
  #ccode[
    ```c
    double sum = 0.0;
    #pragma omp parallel
    {
        // 阶段1：归约求和（隐式 barrier 在 for 末尾）
        #pragma omp for reduction(+:sum)
        for (int i = 0; i < N; i++) sum += a[i];

        // 此处 sum 已对所有线程可见（reduction + barrier）
        // 阶段2：归一化
        #pragma omp for
        for (int i = 0; i < N; i++) a[i] /= sum;
    }
    ```
  ]
  #solution[
    关键点：第一个 `omp for` 末尾的*隐式 barrier* 保证所有线程都完成累加、`sum` 完成合并后，才进入第二个 `for`。若给第一个 `for` 加了 `nowait`，则可能有线程拿着未完成的 `sum` 提前做除法 → 错误。这体现了"隐式 barrier 是正确性的一部分"。
  ]
]

== 章末考试预测专区

#exam-section()

#pred(tags: ("数据子句", "高频"))[
  下列代码有什么 bug？如何修复？
  ```c
  int tmp;
  #pragma omp parallel for
  for (int i = 0; i < N; i++) {
      tmp = a[i] * 2;
      b[i] = tmp + 1;
  }
  ```
]
#analysis[
  Bug：`tmp` 在并行区域外声明，默认是 *shared*。多个线程同时写同一个 `tmp`，产生*数据竞争*：某线程算出 `tmp` 后、用它之前，可能被另一线程覆盖，导致 `b[i]` 错误且结果不确定。
  修复：把 `tmp` 声明为私有——`#pragma omp parallel for private(tmp)`，或更好地*在循环体内声明* `int tmp = a[i]*2;`（C99 起，块内变量自动私有）。推荐配合 `default(none)` 强制显式声明所有变量作用域以暴露此类问题。
]

#pred(tags: ("reduction", "对比"))[
  用 OpenMP 对数组求和，比较 (a) `#pragma omp atomic` 累加到共享变量、(b) `reduction(+:sum)` 两种写法的性能差异，并说明原因。
]
#analysis[
  - (a) atomic：每次迭代所有线程都对*同一个共享 `sum`* 做原子加。虽无错误，但所有线程在同一内存地址上串行化（且引发缓存行争用 / false sharing），并行几乎失效，可能比串行还慢。
  - (b) reduction：每个线程在*私有副本*上独立累加（无争用、缓存友好），仅在区域结束时做一次 $O(log P)$ 或 $O(P)$ 的合并。几乎线性加速。
  结论：归约务必用 `reduction` 子句；atomic 只适合"偶尔更新一个共享计数"的低频场景。
]

#pred(tags: ("task", "执行模型"))[
  为什么用 `#pragma omp task` 做递归并行时，通常要写成
  `#pragma omp parallel` → `#pragma omp single` → 递归函数？去掉 `single` 会怎样？
]
#analysis[
  - `parallel` 创建线程组，为任务提供可执行的工作线程（没有它，task 没人执行 / 串行执行）。
  - `single` 保证递归*只由一个线程发起一次*。任务被放入共享任务池，组内*其他空闲线程*再来窃取执行这些 task，实现并行。
  - 去掉 `single`：`parallel` 区域内的代码被*每个线程各执行一遍*，于是每个线程都从头调用一次递归函数，产生重复的、成倍的任务，结果错误且性能崩溃。所以必须用 `single`（或 `master`）限定只发起一次。
]

#pred(tags: ("同步", "辨析"))[
  辨析 `single` 与 `master` 的区别；`critical` 与 `atomic` 的区别；并说明 `barrier` 为什么不能放在 `if` 分支里。
]
#analysis[
  - *single vs master*：`single` 由*任意一个*线程执行，末尾*有隐式 barrier*（其他线程等待）；`master` 必须由*主线程(0)*执行，*无隐式 barrier*（其他线程直接跳过继续）。
  - *critical vs atomic*：`critical` 是通用互斥锁，可保护*任意代码块*，开销较大；`atomic` 只对*单条读-改-写标量操作*做硬件级原子保护，开销小但适用面窄。
  - *barrier 不能放分支*：`barrier` 要求线程组*所有*线程都到达。若放在 `if` 里只有部分线程执行到它，到达的线程会永远等待没来的线程 → *死锁*。同理不能放在 `single`/某线程独占的代码里。
]

#pred(tags: ("firstprivate/lastprivate", "语义"))[
  说明 `firstprivate` 和 `lastprivate` 各自的含义。一个变量能否同时是二者？下面循环结束后 `x` 的值是多少？
  ```c
  int x = 100;
  #pragma omp parallel for firstprivate(x) lastprivate(x)
  for (int i = 0; i < 10; i++) x = x + i;
  ```
]
#analysis[
  - `firstprivate(x)`：每线程的私有 `x` 用*进入前的原值*（100）初始化。
  - `lastprivate(x)`：循环*逻辑上最后一次迭代*（`i==9`）所在线程的私有 `x` 值在循环后*写回*全局 `x`。
  - 一个变量*可以*同时是 firstprivate 和 lastprivate（先用原值初始化，最后回写末迭代值）。
  - 求值：负责 `i==9` 的线程，其私有 `x` 初始为 100，但只执行*分给它的那些迭代*。`lastprivate` 取的是"串行意义下最后一次迭代 i=9"那个线程私有副本的最终值。若该线程恰好只执行了 i=9 一次（如 static 调度分到末块），则 `x = 100 + 9 = 109`；一般而言取决于调度，但标准保证回写的是"最后一次迭代所属线程"的副本值。考点在于理解 lastprivate 写回的是*逻辑末迭代*的值，而非全局累加（各线程私有，不共享累加）。
]

#pred(tags: ("flush", "内存模型"))[
  OpenMP 采用宽松内存模型。在什么情况下必须显式使用 `#pragma omp flush`？哪些构造隐含了 flush？
]
#analysis[
  必须显式 `flush` 的情况：当用*裸共享变量*做手工同步（如自旋等待一个 `ready` 标志位）时。宽松模型下线程可能把共享变量缓存在寄存器/本地缓存，不 flush 则一个线程的写可能长时间对其他线程不可见，导致自旋循环永不退出或读到陈旧数据。需在写后、读前插入 `flush` 建立内存栅栏。
  隐含 flush 的构造：`barrier`、`critical` 的进入与退出、`atomic`（对该变量）、`parallel`/`for`/`sections` 等的隐式 barrier、`ordered`、任务调度点。因此使用标准同步构造时通常*无需*手写 flush——这也是推荐优先用高层构造而非手工标志位的原因。
]

#pred(tags: ("调度", "代码"))[
  一个并行 `for` 循环中各迭代计算量差异极大（如对不同大小的子问题求解）。给出合适的 `schedule` 选择并解释；再说明 `nowait` 的作用与风险。
]
#analysis[
  - *schedule 选择*：用 `schedule(dynamic, chunk)`（或 `guided`）。因为负载不均时 `static` 会让某些线程分到大量重活而其他线程闲置，整体被最慢线程拖累；`dynamic` 让线程做完一块再领新块，自动均衡。`chunk` 太小则调度开销大、太大则均衡差，需折中。
  - *nowait*：放在工作分担构造上可*取消其末尾的隐式 barrier*，让先做完的线程不必等待、直接进入后续代码，减少空等、提升重叠。
  - *风险*：若后续代码依赖该循环*全部完成*的结果（如先求和再用和），加 `nowait` 会让线程读到未完成的数据，造成竞争和错误。只有在确认后续工作与本循环结果无依赖时才可用 `nowait`。
]
