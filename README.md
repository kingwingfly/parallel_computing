[PDF](main.pdf)

提示词：
帮我编写一份有关并行计算的参考手册，用于知识总结，以及开卷考试应试。
使用 typst 排版，便于打印后查看。

每一个节应当包含基础知识、进阶知识、例题、考试题目预测、题目解析和参考答案。

代码需要 Rust 和 C 两个版本对比。C语言你自由发挥，Rust语言的 crate 选择 openmpi、rayon、crossbeam ...

- 第一章：并行计算绪论
    - 硬件体系：至少包含 超标量、分支预测、旁路转发、指令级并行、指令流水等等
    - 软件体系：至少包含 CUDA、SIMD
    - 评价指标：至少包含 加速比
    - 其他：至少包含阿姆达尔定律、带宽相关的局限等等
- 第二章：并行计算基础：讲解如何分析问题、将问题形式化为可并行的问题
    - 对数组每个元素进行函数计算
    - \pi 计算（蒙卡模拟【随机掷点】）
    - 热力学（二维数组，有限元，随时间步迭代，每个元下一刻状态取决于上下左右相邻元此刻状态）
    - 一维波动方程（A(i, t+1)取决于A(i, t) A(i, t-1) A(i-1, t) A(i+1, t)）
    - 高斯-塞德尔迭代简单例子
    - 锁、屏障的简单应用
    - 调度、编排、依赖关系分析
- 第三章：OpenMPI
    - 生态简介
    - 点对点通信，利用它们计算 \pi，并分析阻塞原语可能导致的死锁，并讲解非阻塞原语
    - 集合通信（Send、Recv、Bcast、Reduce、Scatter、Gather等等）、MPI 中的同步原语
    - 派生数据类型（连续、向量、索引、结构）：每种要有实例，要能做到能选会用
    - 组和通信器管理（不是重点，我没听课，由你自由发挥，但要让我看了能学会）
    - 虚拟拓扑（笛卡尔拓扑、图拓扑）（不是重点，我没听课，由你自由发挥，但要让我看了能学会）
- 第四章：OpenMP（较重点，我没听课，由你自由发挥，但要让我看了能学会，重点放在程序编写上，不用太难，但至少包含DO/for, sections, workshare, 并行区域、任务构造、同步构造、master、critical、barrier、taskwait、atomic、flush、orderd、threadprivate制导, private、shared、default、firstprivate、lastprivate、copyin、copyprivate、reduction子句）
- 第五章：Pthreads Programming
    - 线程管理
    - Mutex
    - Condition Var

- 你必须至少包含以上内容
- 使用 typst 排版，并且易于打印后查看
- 代码以 Rust 为主，并可以通过 Rust 类比讲解 C 语言，你需要考虑到，读者是资深的 Rust 程序员，但对C只知道简单语法
