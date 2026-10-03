import Foundation

/// A read-only projection of persisted indexed work. Never turns an unknown
/// dispatch into a retry or treats an admitted run as provider completion.
struct MeetingMinutesExecutionProgress {
    let completedIndices: Set<Int>
    let activeIndices: Set<Int>
    let failedIndices: Set<Int>
    let admissionRejectedIndices: Set<Int>
    let total: Int
    let awaitingAdmission: Bool

    init(ledger: MeetingMinutesExecutionState) {
        total = ledger.parts.count
        completedIndices = Set(ledger.parts.filter { $0.status == .completed }.map(\.index))
        activeIndices = Set(ledger.parts.filter { $0.status == .submitting || $0.status == .running }.map(\.index))
        failedIndices = Set(ledger.parts.filter { $0.status == .failed }.map(\.index))
        admissionRejectedIndices = Set(ledger.parts.filter { $0.status == .admissionRejected }.map(\.index))
        awaitingAdmission = ledger.parts.contains { $0.status == .submitting }
    }

    var phaseLabel: String {
        if !admissionRejectedIndices.isEmpty { return Self.admissionRejectedMessage }
        if !failedIndices.isEmpty { return "停止したパートを確認してください。完成分は保存されています" }
        if awaitingAdmission { return "受付・復旧確認待ち（自動で再送はしません）" }
        if !activeIndices.isEmpty { return "AIの結果待ち（\(activeIndices.count)パート）" }
        if completedIndices.count == total { return "生成結果が揃いました。議事録の保存待ちです" }
        return "専用実行の開始待ち"
    }

    static let admissionRejectedMessage = "生成前に受付を拒否されました。接続条件の確認が必要です。完成分と送信記録は保持し、再送していません。"

    static func load(store: MeetingStore, id: String, job: MeetingMinutesJob) throws -> Self? {
        try MeetingMinutesExecutionState.load(store: store, id: id, job: job).map(Self.init)
    }
}
