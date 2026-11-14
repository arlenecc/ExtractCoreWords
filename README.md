# ExtractCoreWords

中文新词/核心词提取 CLI：基于 **N-gram 统计 + NPMI 凝固度 + 左右信息熵** 的无词典发现算法，纯 Foundation 实现，零第三方依赖。

从单文件或整目录（如单本书、语料集）中自动发现「量子纠缠」「第三方支付」这类领域核心词，无需分词器、无需预置词典。

## 特性

- **无词典新词发现**：N-gram（2~5 字）滑窗统计 → NPMI 归一化互信息过滤跨词边界片段 → 左右信息熵约束上下文多样性
- **三层文本过滤**：
  - 内置停用词表（可 `--stopwords` 追加自定义）
  - 词首/词尾虚字碎片过滤（「的意」「是一种」）
  - 长词优先的子串碎片抑制（剔除「快速增长」中切错的「速增长」，同时保护「第三方」这类高凝固度真词）
- **内存友好**：汉字压成 UInt16 ID 流，N-gram 打包为 16 字节紧凑键；熵计算用扁平计数 + Σc·log₂c 累加，候选间不存邻居字典；熵阈值 >0 时自动跳过频次 1 的 gram
- **多编码支持**：UTF-8 / GB18030 / Latin1 自动探测，也可显式指定
- **目录递归**：自动收集目录下 `.txt/.md/.markdown/.text` 文件合并为语料
- **内置自检**：`--self-test` 覆盖切分、编码往返、NPMI/熵公式、过滤开关与端到端提取

## 编译

```bash
swiftc -O -o ecw CoreWordKit.swift ExtractCoreWords.swift
```

## 用法

```bash
# 提取单本书的核心词，输出前 500 个
./ecw book.md --format words --top 500

# 表格输出（含频次 / NPMI / PMI / 左右熵）
./ecw ./books/ --format table

# JSON 输出（含全部指标与过滤统计），写入文件
./ecw corpus.txt --format json --output result.json

# 从 stdin 读取
cat article.md | ./ecw -

# 试跑前 10 万字，追加自定义停用词，长词加权排序
./ecw bigbook.txt --max-chars 100000 --stopwords my-words.txt --length-bonus 0.2

# 内置自检
./ecw --self-test
```

## 常用选项

| 选项 | 说明 | 默认 |
|---|---|---|
| `--top N` | 最终保留词数 | 500 |
| `--min-npmi X` | NPMI 下限（`--min-pmi` 别名） | 0.3 |
| `--min-entropy X` | 左/右信息熵下限（bit） | 1.0 |
| `--min-freq N` | 最低出现次数 | 1 |
| `--ngram-min/max N` | 组合字数范围 | 2 / 5 |
| `--stopwords PATH` | 追加停用词文件（每行一词，`#` 注释） | |
| `--substring-ratio X` | 子串抑制：长词频次 ≥ 短词频次×X 才剔除 | 0.5 |
| `--length-bonus X` | 排序加权 `freq×(1+X×(字数-2))` | 0 |
| `--no-filters` | 一次性关闭停用词/虚字/子串三种过滤 | |
| `--boundary count\|ignore` | 片段首尾是否计入 BOS/EOS 邻居 | count |
| `--keep-ascii` | ASCII 字母/数字也参与构词 | 关 |
| `--max-chars N` | 只取前 N 字试跑 | 0（全量） |

完整选项见 `./ecw --help`。

## 算法流程

```
文本 → 切分为连续汉字片段（标点/空白为边界）
     → 编码为 [UInt16] 流（0 为片段哨兵）
     → N-gram 频次统计（滑窗重叠计数）
     → NPMI 过滤：所有二分切分点取最小 PMI / -log p(w) ≥ min-npmi
     → 信息熵过滤：左/右邻居分布熵 ≥ min-entropy
     → 停用词 / 首尾虚字 / 子串碎片三层过滤
     → 频次降序排序（可选长词加权），取 top N
```

## 输出格式

- `table`：TSV，列为 `rank / word / freq / npmi / pmi / H_left(bit) / H_right(bit)`
- `words`：每行一词的纯词表
- `json`：完整结果（词、各项指标、过滤统计、运行参数），可 `JSONDecoder` 回解码

统计摘要（字数、片段数、各阶段淘汰数等）始终输出到 stderr。

## 文件结构

- `CoreWordKit.swift` — 共享提取库（数据模型、Gram 编码、NPMI/熵计算、过滤规则、语料加载）
- `ExtractCoreWords.swift` — CLI 入口（参数解析、输出格式化、内置自检）
