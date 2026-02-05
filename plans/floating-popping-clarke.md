# ClawGate: 汎用セレクタシステム再設計

## 三者議論の結論

ChatGPT・Gemini・Claude の三者議論で得られた合意:
- 現行の title/description テキストマッチングは **Qt/Electron アプリでは機能しない**
- **4層セレクタパイプライン** + **確信度スコアリング** が正解
- 構造パスを「骨格」、能力ベースを「筋肉」として組み合わせる
- Vision/OCR はフォールバック層として実用的（Screen Recording 権限が必要）
- バックグラウンド操作は `AXFocused` 属性設定 → ダメならマイクロ前面化

---

## Phase 1: AXQuery 拡張（能力列挙 + hit-test + 幾何学）

### 1a. AXNode に属性を追加

**ファイル:** `ClawGate/Automation/AX/AXQuery.swift`

```swift
struct AXNode {
    let element: AXUIElement
    let role: String?
    let subrole: String?
    let title: String?
    let description: String?
    let identifier: String?          // NEW: AXIdentifier
    let roleDescription: String?     // NEW: AXRoleDescription (Qt hints)
    let frame: CGRect?               // NEW: AXFrame (geometry)
    let actions: [String]            // NEW: AXUIElementCopyActionNames
    let settableAttributes: Set<String>  // NEW: settable attrs
    let value: String?               // NEW: AXValue (for text inputs)
}
```

### 1b. traverse() で全属性を列挙

```swift
// 既存 traverse() に追加:
let identifier = copyStringAttribute(element, attribute: "AXIdentifier")
let roleDescription = copyStringAttribute(element, attribute: kAXRoleDescriptionAttribute)
let frame = copyFrameAttribute(element)
let actions = copyActionNames(element)
let settable = copySettableAttributes(element)
let value = copyStringAttribute(element, attribute: kAXValueAttribute)
```

新規ヘルパー関数:
- `copyFrameAttribute(_ element:) -> CGRect?` — AXFrame/AXPosition+AXSize
- `copyActionNames(_ element:) -> [String]` — `AXUIElementCopyActionNames`
- `copySettableAttributes(_ element:) -> Set<String>` — 全属性を列挙し `IsAttributeSettable` でフィルタ

### 1c. hit-test 関数追加

```swift
static func elementAtPosition(x: CGFloat, y: CGFloat) -> AXUIElement? {
    let systemWide = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    AXUIElementCopyElementAtPosition(systemWide, Float(x), Float(y), &element)
    return element
}
```

---

## Phase 2: UniversalSelector 設計

**ファイル:** `ClawGate/Automation/Selectors/UniversalSelector.swift` (新規)

### セレクタパイプライン（4層）

| 層 | 方式 | 速度 | 信頼度 |
|----|------|------|--------|
| L1 | Direct Match (identifier, title, description) | 最速 | 高（あれば） |
| L2 | Path Match (anchor + relative path) | 速い | 中〜高 |
| L3 | Capability Search (role + actions + geometry) | 中 | 中 |
| L4 | Visual Fallback (OCR + hit-test) | 遅い | フォールバック |

### コア型定義

```swift
struct SelectorCandidate {
    let node: AXNode
    let confidence: Double   // 0.0 - 1.0
    let matchedLayer: Int    // 1-4
}

struct UniversalSelector {
    let role: String?
    let subrole: String?
    let identifier: String?
    let textHints: [String]             // title/description/value に含まれるテキスト
    let requiredActions: [String]       // e.g. ["AXPress", "AXConfirm"]
    let mustBeSettable: [String]        // e.g. ["AXValue"]
    let geometryHint: GeometryHint?     // ウィンドウ相対位置
    let neighborHint: NeighborHint?     // 隣接要素の特徴
}

struct GeometryHint {
    let regionX: ClosedRange<Double>    // 0.0-1.0 (ウィンドウ幅に対する割合)
    let regionY: ClosedRange<Double>    // 0.0-1.0 (ウィンドウ高さに対する割合)
    let minWidth: Double?               // ウィンドウ幅に対する最小割合
}

struct NeighborHint {
    let adjacentRole: String            // 隣接要素の role
    let direction: Direction            // .left, .right, .above, .below
}
```

### SelectorResolver

```swift
enum SelectorResolver {
    static func resolve(
        selector: UniversalSelector,
        in nodes: [AXNode],
        windowFrame: CGRect
    ) -> SelectorCandidate? {
        // L1: Direct Match
        // L2: Path Match (TODO: Phase 3 で実装)
        // L3: Capability + Geometry Search
        // L4: Visual Fallback (TODO: Phase 4 で実装)
    }
}
```

---

## Phase 3: LineSelectors を UniversalSelector に移行

**ファイル:** `ClawGate/Adapters/LINE/LineSelectors.swift`

```swift
enum LineSelectors {
    static let messageInput = UniversalSelector(
        role: "AXTextArea",
        subrole: nil,
        identifier: nil,
        textHints: [],                  // LINE は空なので不要
        requiredActions: [],
        mustBeSettable: ["AXValue"],    // 書き込み可能な AXTextArea
        geometryHint: GeometryHint(
            regionX: 0.2...1.0,         // 右ペイン（左はサイドバー）
            regionY: 0.7...1.0,         // ウィンドウ下部
            minWidth: 0.3
        ),
        neighborHint: nil
    )

    static let searchField = UniversalSelector(
        role: "AXTextField",
        subrole: nil,
        identifier: nil,
        textHints: ["search", "検索"],
        requiredActions: [],
        mustBeSettable: ["AXValue"],
        geometryHint: GeometryHint(
            regionX: 0.0...0.4,         // 左ペイン上部
            regionY: 0.0...0.15,
            minWidth: nil
        ),
        neighborHint: nil
    )

    // 送信ボタンは AX に存在しない → Enter キー送信
    // sendButton は定義しない
}
```

---

## Phase 4: マイクロ前面化 + AXFocused

**ファイル:** `ClawGate/Automation/AX/AXActions.swift`

```swift
// 1. まず AXFocused 属性設定を試行（ウィンドウ前面化なし）
// 2. ダメなら micro-foreground:
//    a. 現在のフロントアプリを記録
//    b. ターゲットアプリを activate
//    c. アクション実行
//    d. 元のアプリを restore
```

---

## 変更対象ファイル

| Phase | ファイル | 操作 |
|-------|----------|------|
| 1 | `ClawGate/Automation/AX/AXQuery.swift` | AXNode 拡張、hit-test、能力列挙 |
| 1 | `ClawGate/Automation/AX/AXDump.swift` | AXDumpNode に新フィールド反映 |
| 2 | `ClawGate/Automation/Selectors/UniversalSelector.swift` | **新規** |
| 2 | `ClawGate/Automation/Selectors/SelectorResolver.swift` | **新規** |
| 2 | `ClawGate/Automation/Selectors/GeometryHint.swift` | **新規** |
| 3 | `ClawGate/Adapters/LINE/LineSelectors.swift` | UniversalSelector に移行 |
| 3 | `ClawGate/Adapters/LINE/LINEAdapter.swift` | SelectorResolver 使用に変更 |
| 4 | `ClawGate/Automation/AX/AXActions.swift` | micro-foreground 追加 |
| T | `Tests/UnitTests/SelectorResolverTests.swift` | **新規** |

## 実装しないもの（将来）

- L2 Path Match（anchor-based path）→ Phase 2 の後に必要に応じて追加
- L4 Visual Fallback (Vision/OCR) → Screen Recording 権限が必要、別フェーズ
- Teach Mode → MVP 後に検討

## 検証

1. `swift build` が通ること
2. `swift test` が全パスすること
3. ClawGate 起動 → `/v1/axdump` で新フィールド (frame, actions, settable, value) が返ること
4. LINE 前面化 → messageInput が能力+幾何学ベースで特定できること
5. AXFocused 設定 → Enter キー送信がフォアグラウンドなしで機能するか確認
