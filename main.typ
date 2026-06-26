#import "lib/template.typ": *

#show: manual.with(
  title: "并行计算参考手册",
  author: "复习笔记",
)

// ============================== 封面 ==============================
#titlepage(
  title: "并行计算参考手册",
  subtitle: "知识总结 · 开卷应试 · Rust / C 双语对照",
  info: (
    ("适用", "并行计算课程复习与开卷考试"),
    ("排版", "Typst"),
    ("代码", "Rust（rayon / crossbeam / MPI）为主，C 对照"),
  ),
)

// ============================== 目录 ==============================
#{
  set page(header: none)
  text(font: ("Helvetica Neue", "PingFang SC", "Heiti SC"), size: 18pt, weight: "bold", fill: c-primary)[目录]
  v(0.3cm)
  line(length: 100%, stroke: 1pt + c-primary)
  v(0.2cm)
  set text(size: 10.5pt)
  show outline.entry.where(level: 1): it => {
    v(6pt, weak: true)
    set text(font: ("Helvetica Neue", "PingFang SC", "Heiti SC"), weight: "bold", fill: c-primary)
    it
  }
  outline(title: none, indent: 1.2em, depth: 2)
  pagebreak()
}

// ============================== 正文 ==============================
#include "chapters/ch1_intro.typ"
#pagebreak()
#include "chapters/ch2_basics.typ"
#pagebreak()
#include "chapters/ch3_mpi.typ"
#pagebreak()
#include "chapters/ch4_openmp.typ"
#pagebreak()
#include "chapters/ch5_pthreads.typ"
#pagebreak()
#include "chapters/appendix.typ"
