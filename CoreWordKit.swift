// CoreWordKit.swift
// 共享的核心词提取库：N-gram + NPMI + 左右信息熵 + 停用词 / 长词优先。
// 由 ExtractCoreWords.swift（CLI）与 ClusterBooks.swift（批量聚类）共同编译引用。
// 纯 Foundation，零第三方依赖。
//
// 内存设计：汉字映射 UInt16 ID 压成单条流，N-gram 打包成 16 字节 GramKey；
// 左右邻居用扁平计数 + Σc·log2c 累加求熵，避免每个候选一个小字典；
// 熵阈值 >0 时跳过频次 1 的 gram（该侧熵必为 0），结果不变但大幅提速。
// ---------------------------------------------------------------------------

import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

let textSuffixes: Set<String> = ["txt", "md", "markdown", "text"]
let sentinelID: UInt16 = 0      // 片段分隔符 / BOS / EOS 共用的哨兵

// MARK: - 数据模型

struct CoreWord: Codable, Equatable {
    let word: String
    let freq: Int
    let pmi: Double
    let npmi: Double
    let leftEntropy: Double
    let rightEntropy: Double

    enum CodingKeys: String, CodingKey {
        case word, freq, pmi, npmi
        case leftEntropy = "left_entropy"
        case rightEntropy = "right_entropy"
    }
}

struct ExtractOptions: Codable {
    var top: Int = 500
    var ngramMin: Int = 2
    var ngramMax: Int = 5
    var minNPMI: Double = 0.3
    var minLeftEntropy: Double = 1.0
    var minRightEntropy: Double = 1.0
    var minFreq: Int = 1
    var boundary: BoundaryMode = .count
    var keepASCII: Bool = false
    var maxChars: Int = 0

    // 新增：文本过滤与长词优先
    var useStopwords: Bool = true
    var useBoundaryFilter: Bool = true
    var useSubstringFilter: Bool = true
    var substringRatio: Double = 0.5
    var stopwordsPath: String = ""
    var lengthBonus: Double = 0

    enum BoundaryMode: String, Codable {
        case count
        case ignore
    }

    enum CodingKeys: String, CodingKey {
        case top
        case ngramMin = "ngram_min"
        case ngramMax = "ngram_max"
        case minNPMI = "min_npmi"
        case minLeftEntropy = "min_left_entropy"
        case minRightEntropy = "min_right_entropy"
        case minFreq = "min_freq"
        case boundary, keepASCII = "keep_ascii", maxChars = "max_chars"
        case useStopwords = "use_stopwords"
        case useBoundaryFilter = "use_boundary_filter"
        case useSubstringFilter = "use_substring_filter"
        case substringRatio = "substring_ratio"
        case stopwordsPath = "stopwords_path"
        case lengthBonus = "length_bonus"
    }
}

struct ExtractionResult: Codable {
    let words: [CoreWord]
    let stats: Stats
    let params: ExtractOptions

    struct Stats: Codable {
        let totalChars: Int
        let totalSegments: Int
        let ngramTypes: Int
        let npmiSurvivors: Int
        let entropySurvivors: Int
        let stopwordRemoved: Int
        let boundaryRemoved: Int
        let substringRemoved: Int
        let returned: Int

        enum CodingKeys: String, CodingKey {
            case totalChars = "total_chars"
            case totalSegments = "total_segments"
            case ngramTypes = "ngram_types"
            case npmiSurvivors = "npmi_survivors"
            case entropySurvivors = "entropy_survivors"
            case stopwordRemoved = "stopword_removed"
            case boundaryRemoved = "boundary_removed"
            case substringRemoved = "substring_removed"
            case returned
        }
    }
}

// MARK: - Gram 键与字符编码

/// 16 字节紧凑键：a 存前 4 个 UInt16 字符 ID，b 低 16 位存第 5 个、高位存长度。
struct GramKey: Hashable {
    let a: UInt64
    let b: UInt32

    var length: Int { Int((b >> 16) & 0x7) }

    @inline(__always)
    func ids() -> [UInt16] {
        let n = length
        var out: [UInt16] = []
        out.reserveCapacity(n)
        for k in 0..<min(n, 4) {
            out.append(UInt16((a >> UInt64(16 * k)) & 0xFFFF))
        }
        if n == 5 { out.append(UInt16(b & 0xFFFF)) }
        return out
    }

    @inline(__always)
    static func make(_ stream: [UInt16], _ i: Int, _ n: Int) -> GramKey {
        var a: UInt64 = 0
        for k in 0..<min(n, 4) {
            a |= UInt64(stream[i + k]) << UInt64(16 * k)
        }
        var b = UInt32(n) << 16
        if n == 5 { b |= UInt32(stream[i + 4]) }
        return GramKey(a: a, b: b)
    }

    @inline(__always)
    static func make(_ ids: [UInt16]) -> GramKey {
        var a: UInt64 = 0
        for k in 0..<min(ids.count, 4) {
            a |= UInt64(ids[k]) << UInt64(16 * k)
        }
        var b = UInt32(ids.count) << 16
        if ids.count == 5 { b |= UInt32(ids[4]) }
        return GramKey(a: a, b: b)
    }
}

/// 汉字 ⇄ UInt16 ID 双向表（ID 0 保留给哨兵）。
struct GramCodec {
    private(set) var chars: [Character] = ["\u{0}"]
    private var ids: [Character: UInt16] = [:]

    mutating func id(for ch: Character) -> UInt16 {
        if let existing = ids[ch] { return existing }
        guard chars.count < Int(UInt16.max) else { return sentinelID }
        let newID = UInt16(chars.count)
        ids[ch] = newID
        chars.append(ch)
        return newID
    }

    func character(_ id: UInt16) -> Character {
        Int(id) < chars.count ? chars[Int(id)] : "\u{0}"
    }

    func key(_ word: String) -> GramKey {
        GramKey.make(word.map { ids[$0] ?? sentinelID })
    }

    func word(_ key: GramKey) -> String {
        String(key.ids().map { character($0) })
    }
}

// MARK: - 停用词与碎片规则

enum WordFilters {
    /// 功能性虚词、极高频通用词。刻意保留「研究 / 发展 / 社会 / 中国」等
    /// 可能是主题词的实词，需要更激进时可用 --stopwords 追加。
    static let builtinStopwords: Set<String> = Set("""
我们 你们 他们 它们 咱们 自己 这个 那个 这些 那些 这种 那种 什么 怎么 怎样 为何 哪里
因为 所以 但是 然而 虽然 如果 假如 即使 尽管 而且 并且 或者 还是 以及 于是 因此 由于
关于 对于 通过 根据 按照 为了 除了 由于 关于 并且 况且 何况 与其 不如 不过 只是
可以 能够 应该 必须 需要 可能 似乎 其实 基本 主要 一般 一定 非常 十分 相当 比较
更加 逐渐 一直 已经 正在 曾经 仍然 依然 忽然 突然 显然 当然 自然 确实 实际上
进行 成为 作为 出现 存在 发生 产生 具有 包括 使用 采用 提供 实现 表示 认为 发现
一个 一种 一些 一次 一下 一点 一时 第一 第二 第三 这样 那样 如此 其中 之后 之前
以后 以前 现在 当时 同时 目前 开始 左右 上下 方面 情况 问题 时候 时间 地方 部分
没有 不是 就是 还有 也是 都是 一种 是一样的 为主 可见 看出 体现 甚至 改变 更多
先生 太太 小姐 地说 地说 起来 一样 到了 到了这种 到了那个 知道 我们 他们 什么
这一 那一 之一 之一 之中 之间 之内 之外 一般 一切 一切 所有 任何 每个 各个
这是一种 是一种 就可以了 就可以了 的时候 就是说 也就是说 事实上 实际上 总的 来说
""".split(whereSeparator: \.isWhitespace).map(String.init))

    /// 出现在词首/词尾时，几乎必然是跨词边界的碎片（「的意」「是一种」「为主」）。
    static let weakBoundaryChars: Set<Character> = Set("的 了 着 过 得 地 是 在 和 与 或 也 就 都 而 之 以 于 其 这 那 一 不 很 更 最 可 能 会 要 将 被 把 从 对 为 所 由 并 且 但 则 者 矣 焉 乎 哉 又 再 还 才 只 已 曾 就 也 很 更 最 其 之 而 且 但 则 乃 若 即 便 却 竟 偏".filter { !$0.isWhitespace })

    static func loadExtra(_ path: String) -> Set<String> {
        guard !path.isEmpty,
              let text = try? String(contentsOfFile: (path as NSString).expandingTildeInPath,
                                     encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map(String.init).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }

    /// 词首/词尾是虚字 → 跨词片段。仅对 ≥2 字词生效，避免误伤单字术语。
    static func hasWeakBoundary(_ word: String) -> Bool {
        guard let first = word.first, let last = word.last else { return false }
        return weakBoundaryChars.contains(first) || weakBoundaryChars.contains(last)
    }
}

// MARK: - 长词优先（子串碎片抑制）

/// 单个候选词参与子串判定的最小指标集。抽成纯函数便于单测构造样本。
struct WordMetric {
    let word: String
    let freq: Int
    let npmi: Double
    let hl: Double
    let hr: Double
}

enum SubstringFilter {
    /// 返回应被剔除的下标集合。以下信号全部满足才判为碎片：
    ///   (a) 长度：短词 ≥ 3 字、长词 ≥ 4 字。2 字是中文基本词汇单位，天然
    ///       常作复合词前后缀（商业银行 / 小额贷款），不能因「可扩展」判碎片；
    ///   (b) 覆盖：长词频次 ≥ 短词频次 × ratio；
    ///   (c) 凝固度：短词 NPMI < npmiCeiling 且低于长词
    ///       —— 区分「第三方/股权/余额」(≈0.8，真词) 与
    ///          「业的发展/速增长/款利率」(≈0.3~0.5，切错边界)；
    ///   (d) 边界：短词被粘住那侧熵 < gluedCeiling（邻居几乎固定），
    ///       且 < 长词同侧 × gluedRatio（相对也更受限）。
    static func indicesToRemove(_ items: [WordMetric], ratio: Double,
                                npmiCeiling: Double = 0.6,
                                gluedCeiling: Double = 1.8,
                                gluedRatio: Double = 0.8) -> Set<Int> {
        var byWord: [String: Int] = [:]
        for (pos, item) in items.enumerated() { byWord[item.word] = pos }
        var removed = Set<Int>()
        for item in items {
            let chars = Array(item.word)
            guard chars.count >= 4 else { continue }
            for len in 3..<chars.count {
                for start in 0...(chars.count - len) {
                    let sub = String(chars[start..<(start + len)])
                    guard let pos = byWord[sub], sub != item.word else { continue }
                    let short = items[pos]
                    guard Double(item.freq) >= Double(short.freq) * ratio else { continue }
                    guard short.npmi < npmiCeiling, short.npmi < item.npmi else { continue }

                    let isPrefix = start == 0
                    let isSuffix = start + len == chars.count
                    // 后缀 → 左邻被长词前一字固定；前缀 → 右邻被后续字固定；
                    // 中间 → 两侧都被固定。
                    let glued: Double
                    let longSameSide: Double
                    if isPrefix && !isSuffix {
                        glued = short.hr
                        longSameSide = item.hr
                    } else if isSuffix && !isPrefix {
                        glued = short.hl
                        longSameSide = item.hl
                    } else {
                        glued = min(short.hl, short.hr)
                        longSameSide = min(item.hl, item.hr)
                    }
                    if glued < gluedCeiling && glued < longSameSide * gluedRatio {
                        removed.insert(pos)
                    }
                }
            }
        }
        return removed
    }
}

// MARK: - 提取器

enum ExtractError: Error, CustomStringConvertible {
    case invalidRange(String)
    case missingInput(String)

    var description: String {
        switch self {
        case .invalidRange(let msg), .missingInput(let msg): return msg
        }
    }
}

struct Candidate {
    let key: GramKey
    let count: Int
    let pmi: Double
    let npmi: Double
}

enum CoreWordExtractor {

    static func isHan(_ ch: Character) -> Bool {
        guard ch.unicodeScalars.count == 1, let v = ch.unicodeScalars.first?.value else {
            return false
        }
        return (v >= 0x4E00 && v <= 0x9FFF)
            || (v >= 0x3400 && v <= 0x4DBF)
            || (v >= 0x20000 && v <= 0x2A6DF)
            || (v >= 0xF900 && v <= 0xFAFF)
            || (v >= 0x2F800 && v <= 0x2FA1F)
    }

    static func isASCIINumOrLetter(_ ch: Character) -> Bool {
        guard ch.unicodeScalars.count == 1, let v = ch.unicodeScalars.first?.value else {
            return false
        }
        return (v >= 0x30 && v <= 0x39)
            || (v >= 0x41 && v <= 0x5A)
            || (v >= 0x61 && v <= 0x7A)
    }

    /// 便于自检/外部阅读：把正文切成连续汉字字符串片段。
    static func segments(_ text: String, keepASCII: Bool = false) -> [String] {
        var result: [String] = []
        var buf: [Character] = []
        for ch in text {
            if isHan(ch) || (keepASCII && isASCIINumOrLetter(ch)) {
                buf.append(ch)
            } else if !buf.isEmpty {
                result.append(String(buf))
                buf.removeAll(keepingCapacity: true)
            }
        }
        if !buf.isEmpty { result.append(String(buf)) }
        return result
    }

    /// 把全文编码成单条 [UInt16] 流：真实字符 ID ≥ 1，0 表示片段边界。
    static func encode(_ text: String, keepASCII: Bool, maxChars: Int,
                       codec: inout GramCodec) -> (stream: [UInt16], totalChars: Int, segments: Int) {
        var stream: [UInt16] = []
        let cap = min(text.count, maxChars > 0 ? maxChars + 1 : 20_000_000)
        stream.reserveCapacity(cap)
        var total = 0
        var segCount = 0
        var inSegment = false
        for ch in text {
            if isHan(ch) || (keepASCII && isASCIINumOrLetter(ch)) {
                if maxChars > 0 && total >= maxChars { break }
                stream.append(codec.id(for: ch))
                total += 1
                if !inSegment { segCount += 1; inSegment = true }
            } else if inSegment {
                stream.append(sentinelID)
                inSegment = false
            }
        }
        if inSegment { stream.append(sentinelID) }
        return (stream, total, segCount)
    }

    /// 每个位置起连续非 0 字符数（上限 maxN），用于避免跨片段构词。
    static func runLengths(_ stream: [UInt16], maxN: Int) -> [UInt8] {
        var runs = [UInt8](repeating: 0, count: stream.count)
        var run = 0
        for i in stride(from: stream.count - 1, through: 0, by: -1) {
            if stream[i] == sentinelID {
                run = 0
            } else {
                run = min(maxN, run + 1)
            }
            runs[i] = UInt8(run)
        }
        return runs
    }

    /// 频次表：UInt32 计数（单本书不会超 40 亿次），比 Int 字典省一半 value 空间。
    static func countNgrams(_ stream: [UInt16], runs: [UInt8], maxN: Int)
        -> [GramKey: UInt32] {
        var freq: [GramKey: UInt32] = [:]
        for i in 0..<stream.count {
            let nMax = Int(runs[i])
            if nMax == 0 { continue }
            for n in 1...nMax {
                let key = GramKey.make(stream, i, n)
                freq[key, default: 0] += 1
            }
        }
        return freq
    }

    /// NPMI：所有二分切分点取最小 PMI，再除以 -log p(w)。
    static func wordNPMI(_ key: GramKey, freq: [GramKey: UInt32], total: Int)
        -> (pmi: Double, npmi: Double) {
        guard total > 0 else { return (0.0, -Double.infinity) }
        let ids = key.ids()
        let n = ids.count
        guard n >= 2, let c32 = freq[key] else { return (0.0, -Double.infinity) }
        let c = Double(c32)
        let pw = c / Double(total)
        guard pw > 0, pw < 1 else { return (0.0, -Double.infinity) }

        var minPMI = Double.infinity
        for k in 1..<n {
            let left = GramKey.make(Array(ids[0..<k]))
            let right = GramKey.make(Array(ids[k..<n]))
            guard let lp = freq[left], let rp = freq[right] else {
                return (0.0, -Double.infinity)
            }
            let pl = Double(lp) / Double(total)
            let pr = Double(rp) / Double(total)
            guard pl > 0, pr > 0 else { return (0.0, -Double.infinity) }
            minPMI = min(minPMI, log(pw / (pl * pr)))
        }
        guard minPMI.isFinite else { return (0.0, -Double.infinity) }
        return (minPMI, minPMI / (-log(pw)))
    }

    /// H = log2 T - Σ(c·log2 c)/T，只需两个累加量，无需保存邻居分布。
    @inline(__always)
    static func entropy(total: Int, sumCLogC: Double) -> Double {
        guard total > 0 else { return 0.0 }
        let t = Double(total)
        return max(0.0, log2(t) - sumCLogC / t)
    }

    /// 第二遍：扁平记录 (candID, 左/右邻字 ID) → 次数。
    static func countNeighbors(
        _ stream: [UInt16], runs: [UInt8], candidateIndex: [GramKey: Int32],
        ngramMin: Int, ngramMax: Int, boundary: ExtractOptions.BoundaryMode
    ) -> (left: [UInt64: Int32], right: [UInt64: Int32]) {
        var left: [UInt64: Int32] = [:]
        var right: [UInt64: Int32] = [:]
        let size = stream.count
        for i in 0..<size {
            let nMax = min(ngramMax, Int(runs[i]))
            if nMax < ngramMin { continue }
            for n in ngramMin...nMax {
                let key = GramKey.make(stream, i, n)
                guard let cidValue = candidateIndex[key] else { continue }
                let cid = UInt64(cidValue) << 16

                if i > 0 {
                    let ch = stream[i - 1]
                    if ch != sentinelID || boundary == .count {
                        let k = cid | UInt64(ch)
                        left[k, default: 0] += 1
                    }
                } else if boundary == .count {
                    left[cid, default: 0] += 1
                }

                if i + n < size {
                    let ch = stream[i + n]
                    if ch != sentinelID || boundary == .count {
                        let k = cid | UInt64(ch)
                        right[k, default: 0] += 1
                    }
                } else if boundary == .count {
                    right[cid, default: 0] += 1
                }
            }
        }
        return (left, right)
    }

    static func extract(text: String, options: ExtractOptions) throws -> ExtractionResult {
        guard options.ngramMin >= 2, options.ngramMax >= options.ngramMin,
              options.ngramMax <= 5 else {
            throw ExtractError.invalidRange("需满足 2 <= --ngram-min <= --ngram-max <= 5")
        }

        var codec = GramCodec()
        let encoded = encode(text, keepASCII: options.keepASCII,
                             maxChars: options.maxChars, codec: &codec)
        let stream = encoded.stream
        let total = encoded.totalChars
        let runs = runLengths(stream, maxN: options.ngramMax)
        let freq = countNgrams(stream, runs: runs, maxN: options.ngramMax)

        // 等价剪枝：任一熵阈值 > 0 时，频次 1 的 gram 该侧熵必为 0 → 必被淘汰。
        let entropyActive = options.minLeftEntropy > 0 || options.minRightEntropy > 0
        let effectiveMinFreq = max(options.minFreq, entropyActive ? 2 : 1)

        var candidates: [Candidate] = []
        var candidateIndex: [GramKey: Int32] = [:]
        var ngramTypes = 0
        for (key, c32) in freq {
            let length = key.length
            guard length >= options.ngramMin, length <= options.ngramMax else { continue }
            ngramTypes += 1
            let c = Int(c32)
            guard c >= effectiveMinFreq else { continue }
            let (pmi, npmi) = wordNPMI(key, freq: freq, total: total)
            guard npmi >= options.minNPMI else { continue }
            let cid = candidates.count
            candidates.append(Candidate(key: key, count: c, pmi: pmi, npmi: npmi))
            candidateIndex[key] = Int32(cid)
        }

        let (leftFlat, rightFlat) = countNeighbors(
            stream, runs: runs, candidateIndex: candidateIndex, ngramMin: options.ngramMin,
            ngramMax: options.ngramMax, boundary: options.boundary)

        // 把扁平计数聚合到每个候选的 Σc·log2c 与 T。
        var leftTotal = [Int](repeating: 0, count: candidates.count)
        var rightTotal = [Int](repeating: 0, count: candidates.count)
        var leftSum = [Double](repeating: 0, count: candidates.count)
        var rightSum = [Double](repeating: 0, count: candidates.count)
        for (key, c) in leftFlat {
            let cid = Int(key >> 16)
            guard cid >= 0, cid < candidates.count else { continue }
            leftTotal[cid] += Int(c)
            leftSum[cid] += Double(c) * log2(Double(c))
        }
        for (key, c) in rightFlat {
            let cid = Int(key >> 16)
            guard cid >= 0, cid < candidates.count else { continue }
            rightTotal[cid] += Int(c)
            rightSum[cid] += Double(c) * log2(Double(c))
        }

        struct Survived {
            let index: Int
            let word: String
            let freq: Int
            let pmi: Double
            let npmi: Double
            let hl: Double
            let hr: Double
        }
        var survived: [Survived] = []
        for (idx, cand) in candidates.enumerated() {
            let hl = entropy(total: leftTotal[idx], sumCLogC: leftSum[idx])
            let hr = entropy(total: rightTotal[idx], sumCLogC: rightSum[idx])
            guard hl >= options.minLeftEntropy, hr >= options.minRightEntropy else { continue }
            survived.append(Survived(index: idx, word: codec.word(cand.key), freq: cand.count,
                                     pmi: cand.pmi, npmi: cand.npmi, hl: hl, hr: hr))
        }

        // 停用词 + 首尾虚字碎片。
        var stopwords = options.useStopwords ? WordFilters.builtinStopwords : []
        if options.useStopwords { stopwords.formUnion(WordFilters.loadExtra(options.stopwordsPath)) }
        var stopwordRemoved = 0
        var boundaryRemoved = 0
        var kept: [Survived] = []
        for item in survived {
            if options.useStopwords && stopwords.contains(item.word) {
                stopwordRemoved += 1
                continue
            }
            if options.useBoundaryFilter && WordFilters.hasWeakBoundary(item.word) {
                boundaryRemoved += 1
                continue
            }
            kept.append(item)
        }

        // 长词优先：抑制被更长词覆盖、内部松散、边界被粘住的子串碎片。
        var substringRemoved = 0
        if options.useSubstringFilter {
            let metrics = kept.map {
                WordMetric(word: $0.word, freq: $0.freq, npmi: $0.npmi, hl: $0.hl, hr: $0.hr)
            }
            let removed = SubstringFilter.indicesToRemove(metrics, ratio: options.substringRatio)
            substringRemoved = removed.count
            kept = kept.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        }

        let bonus = options.lengthBonus
        let words: [CoreWord] = kept
            .map { item in
                (item: item,
                 score: Double(item.freq) * (1 + bonus * Double(item.word.count - 2)))
            }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                if a.item.word.count != b.item.word.count {
                    return a.item.word.count > b.item.word.count
                }
                if a.item.npmi != b.item.npmi { return a.item.npmi > b.item.npmi }
                return a.item.word < b.item.word
            }
            .prefix(max(0, options.top))
            .map { CoreWord(word: $0.item.word, freq: $0.item.freq, pmi: $0.item.pmi,
                            npmi: $0.item.npmi, leftEntropy: $0.item.hl,
                            rightEntropy: $0.item.hr) }

        let stats = ExtractionResult.Stats(
            totalChars: total,
            totalSegments: encoded.segments,
            ngramTypes: ngramTypes,
            npmiSurvivors: candidates.count,
            entropySurvivors: survived.count,
            stopwordRemoved: stopwordRemoved,
            boundaryRemoved: boundaryRemoved,
            substringRemoved: substringRemoved,
            returned: words.count)
        return ExtractionResult(words: words, stats: stats, params: options)
    }
}

// MARK: - 输出

enum OutputFormat: String {
    case table, words, json
}

enum ResultFormatter {
    static func render(_ result: ExtractionResult, format: OutputFormat) throws -> String {
        switch format {
        case .words:
            return result.words.map(\.word).joined(separator: "\n")
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(result)
            return String(data: data, encoding: .utf8) ?? "{}"
        case .table:
            var lines = ["rank\tword\tfreq\tnpmi\tpmi\tH_left(bit)\tH_right(bit)"]
            for (rank, c) in result.words.enumerated() {
                lines.append(String(
                    format: "%d\t%@\t%d\t%.4f\t%.4f\t%.4f\t%.4f",
                    rank + 1, c.word, c.freq, c.npmi, c.pmi, c.leftEntropy, c.rightEntropy))
            }
            return lines.joined(separator: "\n")
        }
    }

    static func statsLine(_ result: ExtractionResult) -> String {
        let s = result.stats
        return "[core-words] 字数=\(s.totalChars) 片段=\(s.totalSegments) "
            + "N-gram种类=\(s.ngramTypes) NPMI通过=\(s.npmiSurvivors) "
            + "熵通过=\(s.entropySurvivors) 停用词剔除=\(s.stopwordRemoved) "
            + "虚字碎片=\(s.boundaryRemoved) 子串碎片=\(s.substringRemoved) "
            + "输出=\(s.returned)"
    }
}

// MARK: - 语料加载

enum CorpusLoader {
    static func read(_ path: URL, encoding: String) throws -> String {
        let data = try Data(contentsOf: path)
        if encoding != "auto", let enc = encodingByName(encoding) {
            return String(data: data, encoding: enc)
                ?? String(decoding: data, as: UTF8.self)
        }
        for enc in [String.Encoding.utf8, gb18030, String.Encoding.isoLatin1] {
            if var text = String(data: data, encoding: enc) {
                if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
                return text
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func encodingByName(_ name: String) -> String.Encoding? {
        switch name.lowercased() {
        case "utf-8", "utf8": return .utf8
        case "gb18030", "gbk", "gb2312": return gb18030
        case "latin1", "iso-8859-1": return .isoLatin1
        default: return nil
        }
    }

    static var gb18030: String.Encoding {
        #if canImport(CoreFoundation)
        let cf = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        #else
        return .utf8
        #endif
    }

    static func load(_ source: String, encoding: String) throws -> String {
        if source == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            for enc in [String.Encoding.utf8, gb18030, .isoLatin1] {
                if let text = String(data: data, encoding: enc) { return text }
            }
            return String(decoding: data, as: UTF8.self)
        }
        let path = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir) else {
            throw ExtractError.missingInput("输入不存在: \(source)")
        }
        if !isDir.boolValue { return try read(path, encoding: encoding) }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: path, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return "" }
        var files: [URL] = []
        for case let url as URL in enumerator where textSuffixes.contains(url.pathExtension.lowercased()) {
            files.append(url)
        }
        files.sort { $0.path < $1.path }
        return try files.map { try read($0, encoding: encoding) }.joined(separator: "\n")
    }
}

