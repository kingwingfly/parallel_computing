#import "../lib/template.typ": *

= Pthreads Programming

#chapter-intro[
  Pthreads（POSIX threads）是 Unix/Linux 下最底层的线程 API，OpenMP / rayon 等高层抽象的"地基"。它把线程的创建、同步、销毁全部交给程序员手动管理，因此既灵活又危险。本章覆盖三大主题：线程管理（创建 / join / 分离）、互斥锁 Mutex、条件变量 Condition Variable，并用 Rust 的 `std::thread` + `std::sync` 做对照——你会看到 Rust 把 Pthreads 中无数"靠纪律避免"的坑直接编译期消灭。
]

== 线程管理

#basic[
  核心 API（均返回错误码，`0` 表示成功）：
  / `pthread_create(&tid, attr, start_routine, arg)`: 创建线程，从 `start_routine(arg)` 开始执行。`attr` 为 `NULL` 用默认属性。
  / `pthread_join(tid, &retval)`: 阻塞等待线程结束，回收资源，取其返回值。
  / `pthread_exit(retval)`: 线程主动退出并返回值。
  / `pthread_detach(tid)`: 分离线程，结束后自动回收（不能再 join）。
  / `pthread_self()`: 取当前线程 ID。

  线程函数签名固定为 `void* func(void* arg)`：通过 `void*` 传任意参数 / 返回任意结果（C 的"泛型"手段）。
]

#sidebyside(
  left-label: "C：创建并 join 线程",
  ccode[
    ```c
    #include <pthread.h>
    #include <stdio.h>

    void* worker(void* arg) {
        long id = (long)arg;          // 解出参数
        printf("thread %ld running\n", id);
        return (void*)(id * id);      // 返回平方
    }

    int main(void) {
        pthread_t t[4];
        for (long i = 0; i < 4; i++)
            pthread_create(&t[i], NULL,
                           worker, (void*)i);
        for (int i = 0; i < 4; i++) {
            void* r;
            pthread_join(t[i], &r);   // 等待 + 取返回值
            printf("thread %d -> %ld\n", i, (long)r);
        }
        return 0;
    }
    ```
  ],
  rustcode[
    ```rust
    use std::thread;

    fn main() {
        let mut handles = vec![];
        for i in 0..4i64 {
            // move 闭包安全捕获 i（无需 void* 强转）
            handles.push(thread::spawn(move || {
                println!("thread {} running", i);
                i * i               // 返回值有类型
            }));
        }
        for (i, h) in handles.into_iter()
                             .enumerate() {
            let r = h.join().unwrap();  // 取回 i64
            println!("thread {} -> {}", i, r);
        }
    }
    ```
  ],
)

#note[
  给 Rust 程序员的关键对照：
  - C 用 `void*` 传参/返回，类型完全丢失，需手动强制转换 (`(long)arg`)，传错类型编译器不报错、运行崩溃。Rust 的 `spawn` 闭包带完整类型，`join()` 返回 `Result<T>`。
  - *最危险的经典 bug*：循环中 `pthread_create(..., (void*)&i)` 传*局部变量地址*，所有线程共享同一个 `i`，等线程读时 `i` 早已变化甚至失效。Rust 的 `move` + 借用检查从根本上杜绝这类悬垂引用。
  - C 必须 `join` 或 `detach`，否则资源泄漏；Rust 的 `JoinHandle` 不 join 也不会 UB（线程可继续运行或在 drop 时分离）。
]

== Mutex（互斥锁）

#basic[
  互斥锁保护临界区，保证对共享数据的串行访问。
  / 初始化: `pthread_mutex_init(&m, attr)` 或静态 `PTHREAD_MUTEX_INITIALIZER`。
  / `pthread_mutex_lock(&m)`: 加锁（已被占用则阻塞）。
  / `pthread_mutex_trylock(&m)`: 尝试加锁，失败立即返回不阻塞。
  / `pthread_mutex_unlock(&m)`: 解锁。
  / `pthread_mutex_destroy(&m)`: 销毁。

  *铁律*：`lock` 与 `unlock` 必须配对；持锁期间尽量短；多把锁要按固定全局顺序获取以防死锁。
]

#sidebyside(
  left-label: "C：mutex 保护计数器",
  ccode[
    ```c
    #include <pthread.h>
    pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    long counter = 0;

    void* worker(void* arg) {
        for (int i = 0; i < 100000; i++) {
            pthread_mutex_lock(&lock);
            counter++;            // 临界区
            pthread_mutex_unlock(&lock);
        }
        return NULL;
    }
    // 4 个线程后 counter == 400000（无竞争）
    ```
  ],
  rustcode[
    ```rust
    use std::sync::{Arc, Mutex};
    use std::thread;

    let counter = Arc::new(Mutex::new(0i64));
    let mut hs = vec![];
    for _ in 0..4 {
        let c = Arc::clone(&counter);
        hs.push(thread::spawn(move || {
            for _ in 0..100_000 {
                // 锁与数据绑定，离开作用域自动解锁
                *c.lock().unwrap() += 1;
            }
        }));
    }
    for h in hs { h.join().unwrap(); }
    assert_eq!(*counter.lock().unwrap(), 400_000);
    ```
  ],
)

#tip[
  Rust 把"被保护的数据"放进 `Mutex<T>` 内部，*不锁就拿不到数据*（`lock()` 返回 guard 才能访问），从类型上杜绝了"忘加锁直接访问共享变量"。C 的 mutex 和它保护的数据没有语法关联，全靠程序员自觉——考试中常出"漏加锁 / 加错锁 / 忘解锁"的找错题。
]

#note[
  *Pthreads 死锁的三种典型成因*（考点）：
  + *忘记解锁*：临界区中途 `return` / `break` / 出错跳出，未 `unlock`。
  + *重复加锁*：同一线程对*非递归*锁再次 `lock`（自锁）。
  + *锁顺序不一致*：线程 A 先锁 X 再锁 Y，线程 B 先锁 Y 再锁 X，相互等待（经典 ABBA 死锁）。
  防治：固定全局加锁顺序、用 `trylock` 退避、缩小临界区。
]

== Condition Variable（条件变量）

#basic[
  条件变量用于线程间*等待某个条件成立*的同步（而非互斥）。它*必须与一把 mutex 配合*使用。
  / `pthread_cond_wait(&cond, &mutex)`: *原子地*释放 `mutex` 并阻塞等待；被唤醒时*重新获得* `mutex` 再返回。
  / `pthread_cond_signal(&cond)`: 唤醒*至少一个*等待者。
  / `pthread_cond_broadcast(&cond)`: 唤醒*所有*等待者。
]

#note[
  *为什么 `wait` 必须放在 `while` 循环里检查条件，而不是 `if`*？两个原因：
  + *虚假唤醒 (spurious wakeup)*：`wait` 可能在没有 signal 的情况下返回（POSIX 允许）。
  + *唤醒后条件可能又被改变*：被唤醒到重新拿到锁之间，其他线程可能已改变条件。
  所以唤醒后必须*重新检查条件*，不满足就继续 `wait`。这是条件变量的头号考点。
]

=== 生产者-消费者（有界缓冲区）

#sidebyside(
  left-label: "C：条件变量实现",
  ccode[
    ```c
    #include <pthread.h>
    #define CAP 16
    int buf[CAP], count = 0, head = 0, tail = 0;
    pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
    pthread_cond_t not_full  = PTHREAD_COND_INITIALIZER;
    pthread_cond_t not_empty = PTHREAD_COND_INITIALIZER;

    void produce(int item) {
        pthread_mutex_lock(&m);
        while (count == CAP)          // while! 防虚假唤醒
            pthread_cond_wait(&not_full, &m);
        buf[tail] = item;
        tail = (tail + 1) % CAP;
        count++;
        pthread_cond_signal(&not_empty); // 唤醒消费者
        pthread_mutex_unlock(&m);
    }

    int consume(void) {
        pthread_mutex_lock(&m);
        while (count == 0)            // while!
            pthread_cond_wait(&not_empty, &m);
        int item = buf[head];
        head = (head + 1) % CAP;
        count--;
        pthread_cond_signal(&not_full);  // 唤醒生产者
        pthread_mutex_unlock(&m);
        return item;
    }
    ```
  ],
  rustcode[
    ```rust
    use std::sync::{Arc, Mutex, Condvar};

    struct Buffer { q: Vec<i32>, cap: usize }
    // (Mutex<Buffer>, not_full, not_empty)
    type Shared = Arc<(Mutex<Buffer>, Condvar, Condvar)>;

    fn produce(s: &Shared, item: i32) {
        let (m, not_full, not_empty) = &**s;
        let mut b = m.lock().unwrap();
        // wait_while 自动循环检查条件，免写 while
        b = not_full
            .wait_while(b, |b| b.q.len() == b.cap)
            .unwrap();
        b.q.push(item);
        not_empty.notify_one();
    }

    fn consume(s: &Shared) -> i32 {
        let (m, not_full, not_empty) = &**s;
        let mut b = m.lock().unwrap();
        b = not_empty
            .wait_while(b, |b| b.q.is_empty())
            .unwrap();
        let item = b.q.remove(0);
        not_full.notify_one();
        item
    }
    ```
  ],
)

#tip[
  考点：(1) `pthread_cond_wait` 的*原子"解锁-等待"*语义——若不原子，会在"解锁后、等待前"的缝隙里错过 signal（lost wakeup）。(2) `signal` 唤醒一个、`broadcast` 唤醒全部：当条件变化可能让多个等待者都能继续（或等待者等待不同条件）时，用 `broadcast` 更安全。(3) 上例用了*两个*条件变量分别表示"非满 / 非空"，避免无谓唤醒。
]

#advanced[
  *Rust 的安全增益*：`Condvar::wait_while` 内置了"循环检查条件"，从 API 层面避免了忘写 `while` 的虚假唤醒 bug；`MutexGuard` 的所有权在 `wait` 期间被移交又返还，借用检查保证你不会在未持锁时访问数据。C 的条件变量则把这些不变量全部交给程序员，是并发 bug 的重灾区。
]

== Pthreads 其它同步原语（速览）

#advanced[
  / 读写锁 `pthread_rwlock_t`: 区分读锁（可多个并发）与写锁（独占）。读多写少时优于 mutex。Rust 对应 `RwLock<T>`。
  / 屏障 `pthread_barrier_t`: `pthread_barrier_init(&b, NULL, n)` + `pthread_barrier_wait(&b)`，n 个线程到齐才放行（第二章已用）。
  / 自旋锁 `pthread_spinlock_t`: 忙等待而非睡眠，适合临界区极短、持锁时间小于一次上下文切换的场景。
  / 信号量 (POSIX `sem_t`): `sem_wait`(P) / `sem_post`(V)，可计数，适合资源池 / 限流。Rust 标准库无信号量，可用 channel 或第三方 crate。
]

== 章末考试预测专区

#exam-section()

#pred(tags: ("线程传参", "经典 bug"))[
  指出下面代码的 bug，说明后果并修复：
  ```c
  for (long i = 0; i < N; i++)
      pthread_create(&t[i], NULL, worker, (void*)&i);
  ```
]
#analysis[
  Bug：把*循环变量 `i` 的地址* `&i` 传给所有线程。所有线程共享同一个 `i`，而主线程的 `i` 在不断自增、循环结束后还会越界 / 失效。线程读 `*(long*)arg` 时拿到的是*某个不确定的、可能已变化的* `i` 值（数据竞争 + 悬垂），导致线程拿到重复或错误的编号。
  修复方案：
  + *按值传递*：`(void*)i`（把值本身塞进指针大小的整数），线程内 `(long)arg` 取回。
  + *每线程独立存储*：为每个线程准备稳定地址，例如：
    ```c
    long* args = malloc(N * sizeof(long));
    args[i] = i;
    pthread_create(&t[i], NULL, worker, &args[i]);
    ```
    保证每个线程拿到独立、稳定的地址。
]

#pred(tags: ("条件变量", "高频"))[
  为什么 `pthread_cond_wait` 必须放在 `while` 循环中而不是 `if`？为什么它需要传入一个已锁定的 mutex？
]
#analysis[
  - *while 而非 if*：(1) 存在*虚假唤醒*——POSIX 允许 `wait` 在无人 signal 时返回；(2) 从被唤醒到重新获得锁之间，其他线程可能再次改变条件使其重新不满足。用 `while` 在每次醒来后*重新检查条件*，不满足则继续等待；用 `if` 则会在条件实际不成立时错误地继续执行。
  - *需要持锁的 mutex*：条件的检查和等待必须原子。`pthread_cond_wait` 会*原子地释放 mutex 并进入等待*，被唤醒时*重新加锁*再返回。这把锁保护了"条件判断 + 进入等待"这段临界操作，避免在"判断条件为假"和"开始等待"之间被其他线程修改条件并 signal，从而丢失唤醒 (lost wakeup)。
]

#pred(tags: ("死锁", "锁顺序"))[
  两个线程、两把锁，给出一个会死锁的加锁序列，并说明如何避免。
]
#analysis[
  死锁序列（ABBA）：
  ```
  线程1: lock(A); lock(B); ...     线程2: lock(B); lock(A); ...
  ```
  若线程1 拿到 A、线程2 拿到 B，然后线程1 等 B、线程2 等 A，互相持有对方所需的锁且都不释放 → 死锁。
  避免方法：(1) *统一全局加锁顺序*——规定所有线程都先锁 A 再锁 B（按地址 / id 排序），破坏循环等待条件；(2) 用 `pthread_mutex_trylock`，拿不到第二把锁就释放已持有的锁并重试（退避）；(3) 用单一粗粒度锁；(4) 缩小临界区，尽量不嵌套持锁。
]

#pred(tags: ("signal vs broadcast", "辨析"))[
  `pthread_cond_signal` 与 `pthread_cond_broadcast` 有何区别？在什么情况下用 `signal` 会导致 bug 而必须用 `broadcast`？
]
#analysis[
  - 区别：`signal` 唤醒*至少一个*（通常恰一个）等待该条件的线程；`broadcast` 唤醒*所有*等待者。
  - 必须用 `broadcast` 的情形：当多个线程在*同一个*条件变量上等待*不同的*谓词条件，或一次状态变化可能让*多个*等待者都满足继续条件时。例如一次性放入
  多个资源、或唤醒后不同线程检查不同条件——若只 `signal` 一个，可能唤醒的恰是条件仍不满足的那个线程，它重新 `wait`，而真正能继续的线程没被唤醒，造成*停滞 (lost wakeup)*。此时必须 `broadcast` 让所有等待者重新检查各自条件。
  - 代价：`broadcast` 会引发"惊群"——大量线程醒来争锁，多数又重新睡下，有性能开销。能精确 `signal` 时优先 `signal`。
]

#pred(tags: ("join/detach", "资源"))[
  `pthread_join` 与 `pthread_detach` 有什么区别？如果创建线程后既不 join 也不 detach 会怎样？
]
#analysis[
  - `pthread_join`：调用者*阻塞等待*目标线程结束，回收其资源并可取得返回值。一个线程只能被 join 一次。
  - `pthread_detach`：把线程标记为*分离态*，它结束后*由系统自动回收*资源，不能再被 join、也拿不到返回值。适合"发后即忘"的后台线程。
  - 既不 join 也不 detach：线程结束后其资源（线程描述符、退出状态等）*不会被回收*，造成*资源/内存泄漏*（类似僵尸进程）。长期运行的程序会逐渐耗尽线程资源。正确做法：要么 join 等待并回收，要么一开始就 detach。
]

#pred(tags: ("rwlock", "选型"))[
  某共享数据被频繁读取、极少修改。用普通 mutex 还是读写锁？说明理由及读写锁的潜在问题。
]
#analysis[
  应用*读写锁* (`pthread_rwlock_t`)。理由：普通 mutex 即使是两个只读访问也会互相排斥、串行化；读写锁允许*多个读者同时持有读锁*并发读取，仅在写时独占。读多写少场景下并发度大幅提升。
  潜在问题：(1) *写者饥饿*——若读者源源不断，写者可能长时间拿不到写锁（取决于实现的公平策略）；(2) 读写锁本身开销比 mutex 大，若临界区极短或读写比例不高，未必更快；(3) 仍需防止持锁期间的死锁。Rust 对应类型为 `RwLock<T>`，同样需注意写者饥饿。
]
