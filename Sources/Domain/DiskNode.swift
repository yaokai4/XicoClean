import Foundation

/// 空间透镜的磁盘树节点。
///
/// **并发不变式（`@unchecked Sendable` 的安全前提）——单写者、分相拥有：**
///
/// 1. **扫描构建相（后台）**：树自底向上由 `DiskTreeScanner` 构建，每个 `DiskNode` 的
///    `size`/`children` 只在 `init` 时一次性写定、此后构建相内不再改动。顶部若干层用
///    `withTaskGroup` 并发，但每个节点只由**唯一一个**任务构造；父节点在 `for await`
///    收齐全部子任务结果**之后**才 `aggregate` 组装——任务组的完成点建立 happens-before，
///    父读子造之间无数据竞争。`collapse` 亦是纯函数：自底向上返回**全新**的排序裁剪树，
///    不就地改动任何既有节点。`scan(_:)` 返回即代表构建相结束，此后**不再有任何后台任务**触碰该树。
///
/// 2. **展示/交互相（主线程）**：树交给 UI 后仅在**主线程/主 actor**上被读取；唯一的后续写入是
///    删除某文件成功后 `SpaceLensView.prune` 就地剪除对应子树并回收占用（`DiskNode` 为引用类型，
///    共享实例需就地更新）。该写入串行发生在主 actor 上，与后台构建相在时间上不重叠。
///
/// 因此不存在跨线程并发写：构建相单写者、展示相主 actor 单写者，两相首尾相接。
/// 之所以**不**加「构建后即冻结」的断言，正是因为第 2 相存在合法的主线程就地剪枝——
/// 冻结会误伤该功能；不变式靠「分相拥有」而非运行期冻结来保证。
///
/// **两相的机械化收口**：`size`/`children` 声明为 `public private(set)`——跨模块（Infrastructure/
/// Features）**无法**写入，杜绝任何越界就地改动。构建相只经 `init` 一次性写定（结构性单写，见上）；
/// 展示相唯一的合法后续写入（删除成功后的剪枝）由下方 `@MainActor func pruneSubtree(removingID:)`
/// 承载——编译器强制它只能从主 actor 调用，使「展示相写入 = 主 actor 单写」由类型系统而非注释保证。
/// 两条写入路径都被类型系统收口，`@unchecked Sendable` 的前提由此从「靠注释自律」升级为「靠编译器强制」。
public final class DiskNode: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public private(set) var size: Int64
    public private(set) var children: [DiskNode]
    /// 合成聚合桶标记（「其他」/「其他文件」等把众多小项归并展示的虚拟节点）。
    /// 这类节点**复用父目录的 URL**（并非某个真实文件/目录），因此**绝不可**参与删除/移废纸篓
    /// ——否则会以父目录 URL 误删整个当前文件夹（审计 P0：wrong-target deletion）。
    /// UI 据此隐藏其删除入口，`SpaceLensModel.trash` 亦据此兜底拒绝。
    public let isAggregate: Bool
    /// 特殊账本节点标记（P0-d 隐藏空间拆账）：purgeable / 本地快照 / 无权限读取区。
    /// 快照节点走独立的 tmutil 删除通道（二次确认），其余仅解释不可操作。nil = 普通节点。
    public let ledgerKind: LedgerKind?

    public enum LedgerKind: String, Sendable {
        case purgeable    // macOS 自管可清除空间——只解释不代删
        case snapshots    // Time Machine 本地快照——可经 tmutil 独立通道删除
        case unreadable   // 无权限读取区——引导开启完全磁盘访问
    }

    public init(url: URL, name: String, isDirectory: Bool, size: Int64,
                children: [DiskNode] = [], isAggregate: Bool = false, ledgerKind: LedgerKind? = nil) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.children = children
        self.isAggregate = isAggregate
        self.ledgerKind = ledgerKind
    }

    /// 展示相就地嫁接：深层「粒度边界」目录被钻取时，把现场子扫描的结果挂到本节点
    ///（children 全量替换、size 以新扫描为准），返回尺寸差值供祖先链回填——
    /// 空间透镜由此可无限钻取到每一个文件夹/文件（DaisyDisk 口径），而首扫内存仍有界。
    /// `@MainActor` 隔离：与 pruneSubtree/adjustSize 同为展示相主 actor 单写的合法写路径。
    @MainActor
    @discardableResult
    public func adoptChildren(from scanned: DiskNode) -> Int64 {
        let delta = scanned.size - size
        children = scanned.children
        size = scanned.size
        return delta
    }

    /// 展示相祖先链回填：嫁接引起的尺寸差沿祖先链同步，保持「各层 children 之和 ≤ size」。
    @MainActor
    public func adjustSize(by delta: Int64) {
        size = max(0, size + delta)
    }

    /// 展示相就地回接（撤销恢复用，KILLER-2）：把此前剪除的子节点接回本节点并回收其占用。
    /// 与 pruneSubtree 同为展示相主 actor 单写的合法写路径。
    @MainActor
    public func graftChild(_ child: DiskNode) {
        children.append(child)
        size += child.size
    }

    /// 展示相就地剪枝：从本子树中移除 `id` 匹配的节点，并把其占用沿祖先链回收，返回释放字节。
    /// `@MainActor` 隔离——与 adoptChildren/adjustSize 并列的展示相合法写路径，编译器保证仅在
    /// 主 actor 上发生，与后台构建相时间不重叠。删除某项成功后由 SpaceLens 调用（引用类型就地更新）。
    @MainActor
    @discardableResult
    public func pruneSubtree(removingID id: UUID) -> Int64 {
        var removed: Int64 = 0
        children.removeAll { child in
            if child.id == id { removed += child.size; return true }
            return false
        }
        for child in children {
            removed += child.pruneSubtree(removingID: id)
        }
        size = max(0, size - removed)
        return removed
    }

    /// 展示相就地剪枝（按路径兜底）：细化嫁接（adoptChildren）会**全量换新**子节点实例
    ///（UUID 全新），若删除动作持有的是嫁接前的旧实例，按 id 剪枝会空转——文件已进废纸篓
    /// 而环上留下「幽灵」条目（2026-07 终审 P1）。按 URL 路径精确匹配兜底；聚合桶复用父目录
    /// URL，一律不作为匹配对象（只可透传递归）。
    @MainActor
    @discardableResult
    public func pruneSubtree(removingPath path: String) -> Int64 {
        var removed: Int64 = 0
        children.removeAll { child in
            if !child.isAggregate && child.url.path == path { removed += child.size; return true }
            return false
        }
        if removed == 0 {
            for child in children {
                removed = child.pruneSubtree(removingPath: path)
                if removed > 0 { break }
            }
        }
        size = max(0, size - removed)
        return removed
    }
}
