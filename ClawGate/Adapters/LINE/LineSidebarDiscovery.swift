import ApplicationServices
import Foundation

enum LineSidebarDiscovery {
    enum Source: String {
        case ax
        case ocr
    }

    struct SidebarListCandidate {
        let node: AXNode
        let frame: CGRect
        let visibleRows: [SidebarRowCandidate]
    }

    struct SidebarRowCandidate {
        let element: AXUIElement
        let frame: CGRect
        let yOrder: Int
    }

    struct SidebarConversationCandidate {
        let name: String
        let frame: CGRect
        let yOrder: Int
        let source: Source
    }

    static func findSidebarList(
        in nodes: [AXNode],
        windowFrame: CGRect,
        rowCountProvider: ((AXNode, CGRect) -> Int)? = nil
    ) -> SidebarListCandidate? {
        let candidates: [(node: AXNode, frame: CGRect, visibleRowCount: Int)] = nodes.compactMap { node in
            guard node.role == "AXList", let frame = node.frame else { return nil }
            guard isLikelySidebarListFrame(frame, windowFrame: windowFrame) else { return nil }
            let visibleRowCount = rowCountProvider?(node, frame) ?? visibleRows(in: node.element, listFrame: frame).count
            guard visibleRowCount > 0 else { return nil }
            return (node, frame, visibleRowCount)
        }

        guard let best = candidates.max(by: { lhs, rhs in
            if lhs.visibleRowCount != rhs.visibleRowCount {
                return lhs.visibleRowCount < rhs.visibleRowCount
            }
            if lhs.frame.height != rhs.frame.height {
                return lhs.frame.height < rhs.frame.height
            }
            return lhs.frame.minX > rhs.frame.minX
        }) else {
            return nil
        }

        return SidebarListCandidate(
            node: best.node,
            frame: best.frame,
            visibleRows: visibleRows(in: best.node.element, listFrame: best.frame)
        )
    }

    static func isLikelySidebarListFrame(_ frame: CGRect, windowFrame: CGRect) -> Bool {
        guard windowFrame.width > 0, windowFrame.height > 0 else { return false }
        guard frame.width > 0, frame.height > 0 else { return false }
        let relMinX = Double(frame.minX - windowFrame.minX) / Double(windowFrame.width)
        let relMidX = Double(frame.midX - windowFrame.minX) / Double(windowFrame.width)
        let relWidth = Double(frame.width) / Double(windowFrame.width)
        let relHeight = Double(frame.height) / Double(windowFrame.height)
        return relMinX <= 0.18
            && relMidX <= 0.30
            && relWidth >= 0.18
            && relWidth <= 0.35
            && relHeight >= 0.50
    }

    static func visibleRows(in listElement: AXUIElement, listFrame: CGRect) -> [SidebarRowCandidate] {
        let rowNodes: [AXNode] = AXQuery.children(of: listElement).compactMap { child in
            guard AXQuery.copyStringAttribute(child, attribute: kAXRoleAttribute as String) == "AXRow" else {
                return nil
            }
            return AXNode(
                element: child,
                role: "AXRow",
                subrole: AXQuery.copyStringAttribute(child, attribute: kAXSubroleAttribute as String),
                title: AXQuery.copyStringAttribute(child, attribute: kAXTitleAttribute as String),
                description: AXQuery.copyStringAttribute(child, attribute: kAXDescriptionAttribute as String),
                identifier: AXQuery.copyStringAttribute(child, attribute: "AXIdentifier"),
                roleDescription: AXQuery.copyStringAttribute(child, attribute: kAXRoleDescriptionAttribute as String),
                frame: AXQuery.copyFrameAttribute(child),
                actions: AXQuery.copyActionNames(child),
                settableAttributes: AXQuery.copySettableAttributes(child),
                value: AXQuery.copyStringAttribute(child, attribute: kAXValueAttribute as String)
            )
        }
        return visibleRows(from: rowNodes, listFrame: listFrame)
    }

    static func visibleRows(from rowNodes: [AXNode], listFrame: CGRect) -> [SidebarRowCandidate] {
        var rows = rowNodes.compactMap { node -> SidebarRowCandidate? in
            guard node.role == "AXRow", let frame = node.frame else { return nil }
            guard frame.width > 0, frame.height > 0 else { return nil }
            guard frame.intersects(listFrame) else { return nil }
            return SidebarRowCandidate(element: node.element, frame: frame, yOrder: 0)
        }.sorted { lhs, rhs in
            if lhs.frame.minY != rhs.frame.minY {
                return lhs.frame.minY < rhs.frame.minY
            }
            return lhs.frame.minX < rhs.frame.minX
        }

        if shouldDropHeaderRow(rows, listFrame: listFrame) {
            rows.removeFirst()
        }

        return rows.enumerated().map { index, row in
            SidebarRowCandidate(element: row.element, frame: row.frame, yOrder: index)
        }
    }

    static func shouldDropHeaderRow(_ rows: [SidebarRowCandidate], listFrame: CGRect) -> Bool {
        guard rows.count >= 2 else { return false }
        let first = rows[0]
        return first.frame.minY <= listFrame.minY + 4
            && first.frame.height < 40
            && rows[1].frame.maxY > first.frame.maxY
    }

    static func extractAXConversationCandidates(
        from rows: [SidebarRowCandidate],
        nodes: [AXNode],
        windowTitle: String?
    ) -> [SidebarConversationCandidate] {
        rows.compactMap { row in
            let textCandidates: [(text: String, frame: CGRect)] = nodes.compactMap { node in
                guard let frame = node.frame else { return nil }
                guard frame.width > 0, frame.height > 0 else { return nil }
                guard frame.intersects(row.frame) else { return nil }
                guard let text = normalizedText(from: node, windowTitle: windowTitle) else { return nil }
                return (text, frame)
            }

            guard let best = textCandidates.sorted(by: preferredTextOrder).first else {
                return nil
            }

            return SidebarConversationCandidate(
                name: best.text,
                frame: row.frame,
                yOrder: row.yOrder,
                source: .ax
            )
        }
    }

    static func extractUnreadIndicatorFrames(
        from nodes: [AXNode],
        sidebarFrame: CGRect
    ) -> [CGRect] {
        nodes.compactMap { node in
            guard let frame = node.frame else { return nil }
            guard frame.width > 0, frame.height > 0 else { return nil }
            guard frame.intersects(sidebarFrame) else { return nil }
            let text = (node.value ?? node.title ?? node.description ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.allSatisfy(\.isNumber) else { return nil }
            return frame
        }
    }

    static func extractOCRConversationCandidates(
        from rows: [SidebarRowCandidate],
        windowID: CGWindowID,
        config: VisionOCR.OCRConfig,
        windowTitle: String?
    ) -> [SidebarConversationCandidate] {
        rows.compactMap { row in
            if let titleName = ocrConversationName(
                in: sidebarTitleOCRRect(for: row.frame),
                windowID: windowID,
                config: config,
                windowTitle: windowTitle,
                preferFirstLine: true
            ) {
                return SidebarConversationCandidate(
                    name: titleName,
                    frame: row.frame,
                    yOrder: row.yOrder,
                    source: .ocr
                )
            }

            let crop = sidebarOCRRect(for: row.frame)
            guard let name = ocrConversationName(
                in: crop,
                windowID: windowID,
                config: config,
                windowTitle: windowTitle,
                preferFirstLine: false
            ) else {
                return nil
            }

            return SidebarConversationCandidate(
                name: name,
                frame: row.frame,
                yOrder: row.yOrder,
                source: .ocr
            )
        }
    }

    static func buildConversationEntries(
        axCandidates: [SidebarConversationCandidate],
        ocrCandidates: [SidebarConversationCandidate],
        unreadFrames: [CGRect],
        limit: Int
    ) -> [ConversationEntry] {
        var preferredByRow: [Int: SidebarConversationCandidate] = [:]

        for candidate in axCandidates.sorted(by: candidateRowOrder) {
            preferredByRow[candidate.yOrder] = candidate
        }
        for candidate in ocrCandidates.sorted(by: candidateRowOrder) {
            if preferredByRow[candidate.yOrder] == nil {
                preferredByRow[candidate.yOrder] = candidate
            }
        }

        var seenNames = Set<String>()
        var entries: [ConversationEntry] = []

        for candidate in preferredByRow.values.sorted(by: candidateRowOrder) {
            let key = normalizeConversationKey(candidate.name)
            guard !seenNames.contains(key) else { continue }
            seenNames.insert(key)
            let hasUnread = unreadFrames.contains { frame in
                frame.minX > candidate.frame.minX && abs(frame.midY - candidate.frame.midY) < 15
            }
            entries.append(
                ConversationEntry(name: candidate.name, yOrder: entries.count, hasUnread: hasUnread)
            )
            if entries.count >= limit {
                break
            }
        }

        return entries
    }

    static func findConversationRow(
        named conversationName: String,
        in sidebar: SidebarListCandidate,
        nodes: [AXNode],
        windowTitle: String?,
        windowID: CGWindowID?,
        ocrConfig: VisionOCR.OCRConfig = .default
    ) -> SidebarRowCandidate? {
        let targetKey = normalizeConversationKey(conversationName)
        guard !targetKey.isEmpty else { return nil }

        let rowsByOrder = Dictionary(uniqueKeysWithValues: sidebar.visibleRows.map { ($0.yOrder, $0) })

        let axMatch = extractAXConversationCandidates(
            from: sidebar.visibleRows,
            nodes: nodes,
            windowTitle: windowTitle
        ).first { normalizeConversationKey($0.name) == targetKey }
        if let axMatch, let row = rowsByOrder[axMatch.yOrder] {
            return row
        }

        guard let windowID else { return nil }
        let ocrMatch = extractOCRConversationCandidates(
            from: sidebar.visibleRows,
            windowID: windowID,
            config: ocrConfig,
            windowTitle: windowTitle
        ).first { normalizeConversationKey($0.name) == targetKey }
        guard let ocrMatch else { return nil }
        return rowsByOrder[ocrMatch.yOrder]
    }

    static func defaultConversationSearchResultRows(
        in sidebar: SidebarListCandidate,
        searchFieldFrame: CGRect
    ) -> [SidebarRowCandidate] {
        // Measured on macmini LINE window:
        // - search field: x=134 y=78 w=264 h=38
        // - search-state header row: y=116 h=34
        // - first actual result row: y=150 h=57
        // Screenshot evidence can show two visual results, but Host A AX search-state
        // currently exposes a single actual result row beneath the header. Keep the
        // filter loose enough to include that row while still excluding the header.
        let minResultY = searchFieldFrame.maxY + 24
        return sidebar.visibleRows.filter { row in
            row.frame.minY >= minResultY && row.frame.height >= 48
        }
    }

    static func defaultConversationTargetResultRow(
        in sidebar: SidebarListCandidate,
        searchFieldFrame: CGRect
    ) -> SidebarRowCandidate? {
        let rows = defaultConversationSearchResultRows(
            in: sidebar,
            searchFieldFrame: searchFieldFrame
        )
        guard !rows.isEmpty else { return nil }
        // Preferred behavior remains "second actual result row" when the search surface
        // exposes both LINE and the person entry. On Host A's real AX tree, only one
        // actual result row is often exposed after the header, and that row is the
        // selectable conversation. Fall back to the first actual result row in that case.
        return rows.count >= 2 ? rows[1] : rows[0]
    }

    static func sidebarOCRRect(for rowFrame: CGRect) -> CGRect {
        CGRect(
            x: rowFrame.minX + rowFrame.width * 0.20,
            y: rowFrame.minY + rowFrame.height * 0.18,
            width: rowFrame.width * 0.58,
            height: rowFrame.height * 0.64
        ).integral
    }

    static func sidebarTitleOCRRect(for rowFrame: CGRect) -> CGRect {
        CGRect(
            x: rowFrame.minX + rowFrame.width * 0.22,
            y: rowFrame.minY + rowFrame.height * 0.06,
            width: rowFrame.width * 0.62,
            height: max(22, rowFrame.height * 0.36)
        ).integral
    }

    private static func preferredTextOrder(
        _ lhs: (text: String, frame: CGRect),
        _ rhs: (text: String, frame: CGRect)
    ) -> Bool {
        if abs(lhs.frame.minY - rhs.frame.minY) > 4 {
            return lhs.frame.minY < rhs.frame.minY
        }
        if lhs.text.count != rhs.text.count {
            return lhs.text.count > rhs.text.count
        }
        return lhs.frame.minX < rhs.frame.minX
    }

    private static func candidateRowOrder(
        _ lhs: SidebarConversationCandidate,
        _ rhs: SidebarConversationCandidate
    ) -> Bool {
        if lhs.yOrder != rhs.yOrder {
            return lhs.yOrder < rhs.yOrder
        }
        return lhs.source.rawValue < rhs.source.rawValue
    }

    private static func normalizedText(from node: AXNode, windowTitle: String?) -> String? {
        let raw = node.value ?? node.title ?? node.description ?? ""
        return normalizeConversationName(raw, windowTitle: windowTitle)
    }

    private static func ocrConversationName(
        in crop: CGRect,
        windowID: CGWindowID,
        config: VisionOCR.OCRConfig,
        windowTitle: String?,
        preferFirstLine: Bool
    ) -> String? {
        guard crop.width >= 40, crop.height >= 18 else { return nil }
        guard let raw = VisionOCR.extractText(from: crop, windowID: windowID, config: config) else {
            return nil
        }
        return normalizedOCRText(raw, windowTitle: windowTitle, preferFirstLine: preferFirstLine)
    }

    private static func normalizedOCRText(
        _ raw: String,
        windowTitle: String?,
        preferFirstLine: Bool
    ) -> String? {
        let lines = raw
            .split(whereSeparator: \.isNewline)
            .map { normalizeWhitespace(String($0)) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            return nil
        }

        if preferFirstLine {
            for line in lines {
                if let normalized = normalizeConversationName(line, windowTitle: windowTitle) {
                    return normalized
                }
            }
        }

        for line in lines.sorted(by: { $0.count > $1.count }) {
            if let normalized = normalizeConversationName(line, windowTitle: windowTitle) {
                return normalized
            }
        }

        return nil
    }

    private static func normalizeConversationName(_ raw: String, windowTitle: String?) -> String? {
        let text = normalizeWhitespace(raw)
        guard !text.isEmpty else { return nil }
        guard !LINEAdapter.isUIChrome(text, windowTitle: windowTitle) else { return nil }
        return text
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeConversationKey(_ text: String) -> String {
        normalizeWhitespace(text).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
