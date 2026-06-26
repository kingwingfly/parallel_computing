// ============================================================
//  并行计算参考手册 —— 公共排版模板 (Typst)
//  设计目标：便于打印、层次清晰、中英代码对照
// ============================================================

// ---------- 颜色方案（打印友好，低饱和度）----------
#let c-primary = rgb("#1f3a5f")  // 深蓝：标题
#let c-accent = rgb("#2c6e49")  // 墨绿：强调
#let c-rust = rgb("#b7410e")  // Rust 锈红
#let c-c-lang = rgb("#283593")  // C 蓝
#let c-warn = rgb("#a3361b")  // 警示红棕
#let c-bg-soft = rgb("#f5f6f8")  // 浅灰底
#let c-bg-rust = rgb("#fbf1ec")
#let c-bg-c = rgb("#eef0fa")
#let c-rule = rgb("#c9ced6")

// ---------- 字体 ----------
#let font-serif = ("Times New Roman", "Songti SC", "STSong")
#let font-sans = ("Helvetica Neue", "PingFang SC", "Heiti SC")
#let font-mono = ("Menlo", "Fira Code", "DejaVu Sans Mono")

// ============================================================
//  主样式入口
// ============================================================
#let manual(
  title: "并行计算参考手册",
  author: "复习笔记",
  body,
) = {
  set document(title: title, author: author)

  set page(
    paper: "a4",
    margin: (top: 2.4cm, bottom: 2.2cm, left: 2.2cm, right: 2.2cm),
    header: context {
      let page-num = counter(page).get().first()
      // 在每章首页（state 标记）隐藏页眉
      let elems = query(heading.where(level: 1))
      set text(size: 8.5pt, fill: rgb("#6b7280"), font: font-sans)
      let cur = query(selector(heading.where(level: 1)).before(here()))
      let chap = if cur.len() > 0 {
        let h = cur.last()
        [第 #numbering("1", ..counter(heading).at(h.location())) 章 · #h.body]
      } else { title }
      if page-num > 1 {
        grid(
          columns: (1fr, auto),
          align: (left, right),
          chap, title,
        )
        v(-6pt)
        line(length: 100%, stroke: 0.5pt + c-rule)
      }
    },
    footer: context {
      set text(size: 9pt, fill: rgb("#6b7280"), font: font-sans)
      align(center)[#counter(page).display("1")]
    },
  )

  // ---------- 全局文本 ----------
  set text(
    font: font-serif,
    lang: "zh",
    region: "cn",
    size: 10.5pt,
    fill: rgb("#1a1a1a"),
  )
  set par(justify: true, leading: 0.78em, spacing: 1.0em, first-line-indent: 0pt)

  // ---------- 标题样式 ----------
  set heading(numbering: "1.1.1")
  show heading: it => {
    set text(font: font-sans, fill: c-primary)
    let lv = it.level
    if lv == 1 {
      set text(size: 17pt, weight: "bold")
      block(above: 1.4em, below: 0.9em)[
        #block(spacing: 0.3em)[
          #counter(heading).display() #h(0.4em) #it.body
        ]
        #v(-4pt)
        #line(length: 100%, stroke: 1.2pt + c-primary)
      ]
    } else if lv == 2 {
      set text(size: 13.5pt, weight: "bold", fill: c-accent)
      block(above: 1.2em, below: 0.6em)[
        #counter(heading).display() #h(0.35em) #it.body
      ]
    } else {
      set text(size: 11.5pt, weight: "bold")
      block(above: 0.9em, below: 0.45em)[
        #counter(heading).display() #h(0.3em) #it.body
      ]
    }
  }

  // ---------- 列表 ----------
  set list(indent: 0.6em, body-indent: 0.5em, marker: ([•], [‣], [·]))
  set enum(indent: 0.6em, body-indent: 0.5em)

  // ---------- 行内代码 ----------
  show raw.where(block: false): it => box(
    fill: c-bg-soft,
    inset: (x: 3pt, y: 0pt),
    outset: (y: 3pt),
    radius: 2pt,
    text(font: font-mono, size: 0.92em, fill: rgb("#9a3412"), it),
  )

  // ---------- 代码块 ----------
  show raw.where(block: true): it => block(
    fill: c-bg-soft,
    inset: (x: 10pt, y: 9pt),
    radius: 4pt,
    width: 100%,
    stroke: 0.5pt + c-rule,
    text(font: font-mono, size: 8.8pt, it),
  )
  set raw(tab-size: 4)

  // ---------- 表格 ----------
  set table(
    stroke: 0.5pt + c-rule,
    inset: 6pt,
  )
  show table.cell.where(y: 0): set text(weight: "bold", fill: white)
  set table(fill: (_, y) => if y == 0 { c-primary } else { none })

  // ---------- 链接 ----------
  show link: set text(fill: c-c-lang)

  body
}

// ============================================================
//  封面页
// ============================================================
#let titlepage(title: "并行计算参考手册", subtitle: none, info: ()) = {
  set page(header: none, footer: none)
  v(1fr)
  align(center)[
    #text(font: font-sans, size: 13pt, fill: c-accent, weight: "bold", tracking: 2pt)[
      PARALLEL COMPUTING
    ]
    #v(0.4cm)
    #line(length: 60%, stroke: 1.5pt + c-primary)
    #v(0.6cm)
    #text(font: font-sans, size: 32pt, weight: "bold", fill: c-primary)[#title]
    #if subtitle != none {
      v(0.4cm)
      text(font: font-sans, size: 14pt, fill: rgb("#475569"))[#subtitle]
    }
    #v(0.4cm)
    #line(length: 60%, stroke: 0.8pt + c-rule)
  ]
  v(0.6fr)
  align(center)[
    #for (k, val) in info {
      text(font: font-sans, size: 10.5pt, fill: rgb("#475569"))[#k ：#val]
      linebreak()
    }
  ]
  v(1fr)
  pagebreak()
}

// 章首分隔（可选，在 level-1 标题之前使用）
#let chapter-intro(body) = block(
  width: 100%,
  fill: c-bg-soft,
  inset: (x: 12pt, y: 10pt),
  radius: 4pt,
  above: 0.6em,
  below: 1.0em,
)[
  #text(font: font-sans, size: 9.5pt, fill: rgb("#475569"), style: "italic")[#body]
]

// ============================================================
//  内容块组件
// ============================================================

// 通用提示框
#let _callout(title, icon, fill, stroke, body) = block(
  width: 100%,
  fill: fill,
  inset: (x: 11pt, y: 9pt),
  radius: 4pt,
  stroke: (left: 3pt + stroke),
  above: 0.9em,
  below: 0.9em,
)[
  #text(font: font-sans, weight: "bold", fill: stroke, size: 10pt)[#icon #h(0.3em) #title]
  #v(-0.3em)
  #body
]

// 基础知识
#let basic(body) = _callout("基础知识", "▍", rgb("#eef4fb"), c-primary, body)

// 进阶知识
#let advanced(body) = _callout("进阶知识", "▍", rgb("#eef6f0"), c-accent, body)

// 重点提示 / 注意
#let note(body) = _callout("注意", "！", rgb("#fdf3ef"), c-warn, body)

// 易错点 / 考点提示
#let tip(body) = _callout("考点提示", "★", rgb("#fdfbe9"), rgb("#92740a"), body)

// ---------- 例题 ----------
#let example-counter = counter("example")
#let example(title: none, body) = {
  example-counter.step()
  block(
    width: 100%,
    inset: (left: 10pt, rest: 0pt),
    stroke: (left: 2.5pt + c-accent),
    above: 1.0em,
    below: 1.0em,
  )[
    #text(font: font-sans, weight: "bold", fill: c-accent)[
      例题 #context example-counter.display()
      #if title != none [ #h(0.3em) · #title ]
    ]
    #v(0.1em)
    #body
  ]
}

// ---------- 解答（折叠式视觉块）----------
#let solution(body) = block(
  width: 100%,
  fill: rgb("#fafafa"),
  inset: (x: 10pt, y: 8pt),
  radius: 3pt,
  stroke: (dash: "dashed", paint: c-rule, thickness: 0.6pt),
  above: 0.5em,
  below: 0.9em,
)[
  #text(font: font-sans, weight: "bold", fill: rgb("#475569"), size: 9.5pt)[解答 / 参考答案]
  #v(0.1em)
  #body
]

// ============================================================
//  考试题目预测专区
// ============================================================
#let pred-counter = counter("prediction")

// 预测题区块标题
#let exam-section() = {
  pred-counter.update(0)
  block(
    width: 100%,
    fill: c-primary,
    inset: (x: 12pt, y: 7pt),
    radius: 4pt,
    above: 1.4em,
    below: 0.9em,
  )[
    #text(font: font-sans, weight: "bold", fill: white, size: 12pt)[
      🎯 考试题目预测与解析
    ]
  ]
}

// 单道预测题：题面
#let pred(tags: (), body) = {
  pred-counter.step()
  block(above: 1.0em, below: 0.4em)[
    #text(font: font-sans, weight: "bold", fill: c-warn)[
      预测题 #context pred-counter.display()
    ]
    #if tags.len() > 0 {
      h(0.4em)
      for t in tags {
        box(
          fill: rgb("#fdf3ef"),
          inset: (x: 5pt, y: 1pt),
          radius: 2pt,
          outset: (y: 2pt),
          text(font: font-sans, size: 8pt, fill: c-warn)[#t],
        )
        h(0.2em)
      }
    }
    #v(0.15em)
    #body
  ]
}

// 解析
#let analysis(body) = block(
  width: 100%,
  fill: rgb("#f3f7f4"),
  inset: (x: 10pt, y: 8pt),
  radius: 3pt,
  stroke: (left: 2.5pt + c-accent),
  above: 0.4em,
  below: 1.1em,
)[
  #text(font: font-sans, weight: "bold", fill: c-accent, size: 9.5pt)[题目解析 · 参考答案]
  #v(0.1em)
  #body
]

// ============================================================
//  Rust / C 代码对照
// ============================================================

// 语言标签条
#let _lang-tag(name, fill) = box(
  fill: fill,
  inset: (x: 7pt, y: 2pt),
  radius: (top-left: 4pt, top-right: 4pt),
  text(font: font-mono, size: 8.5pt, weight: "bold", fill: white)[#name],
)

// 单语言代码（带标签）
#let rustcode(label: "Rust", body) = block(above: 0.7em, below: 0.7em)[
  #_lang-tag(label, c-rust)
  #v(-0.55em)
  #body
]

#let ccode(label: "C", body) = block(above: 0.7em, below: 0.7em)[
  #_lang-tag(label, c-c-lang)
  #v(-0.55em)
  #body
]

// 并排对照：左右两个内容本身已由 rustcode/ccode 包装（含语言标签），
// 此函数只负责并排布局。left-label 仅作兼容保留，不再重复渲染。
#let sidebyside(left-label: none, right-label: none, left, right) = {
  grid(
    columns: (1fr, 1fr),
    gutter: 8pt,
    block(breakable: false)[#left], block(breakable: false)[#right],
  )
}

// 术语强调
#let term(t) = text(weight: "bold", fill: c-accent)[#t]
#let en(t) = text(font: font-sans, style: "italic", fill: rgb("#475569"))[#t]
