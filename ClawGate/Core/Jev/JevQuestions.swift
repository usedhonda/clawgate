import Foundation

/// The fixed set of `noul` questions asked of one ambient window.
///
/// Each question is phrased so a HIGH value always means "yes" — mixing
/// polarity across questions would make every downstream threshold a
/// per-question lookup instead of a single constant — and each explicitly
/// tells Jev to answer near 0.5 when the window has no material for it,
/// because without that instruction a model asked a yes/no-shaped question
/// tends to guess low rather than admit "not applicable," which would read
/// as a confident "no" instead of an honest "can't tell."
enum JevQuestions {
    /// Bumped whenever a question's meaning changes (not just its wording) —
    /// stored in the ledger alongside each window so a later re-read of old
    /// answers knows which definition produced them.
    static let version = 1

    /// The transcript convention lines follow: `[HH:mm] ご主人様: …` for this
    /// Mac's owner, `[HH:mm] 相手: …` for anyone else. Only the two questions
    /// that need to tell the speakers apart mention it.
    private static let speakerLabelNote =
        "会話は「[HH:mm] ご主人様: 発言」「[HH:mm] 相手: 発言」の形式で渡されます。"

    static let ambientWindow: [String: JevQuestion] = [
        "my_promise": .noul(
            speakerLabelNote + "ご主人様自身が、これから何かをすると相手に対して約束したかどうかを判定してください。"
                + "高い値（1に近い）は「約束した」、低い値（0に近い）は「約束していない」を意味します。"
                + "会話にそのような約束の材料が全く含まれない場合は、0.5に近い値を返してください。",
            yes: "ご主人様が「明日までにやっておくね」のように、自分の今後の行動を相手に約束している",
            no: "ご主人様は何も約束していない、または約束しているのは相手の方である"
        ),
        "their_promise": .noul(
            speakerLabelNote + "相手が、ご主人様に対して何かをすると約束したかどうかを判定してください。"
                + "高い値は「相手が約束した」、低い値は「約束していない」を意味します。"
                + "会話にそのような約束の材料が全く含まれない場合は、0.5に近い値を返してください。",
            yes: "相手が「私が明日連絡します」のように、自分の今後の行動を約束している",
            no: "相手は何も約束していない、または約束しているのはご主人様の方である"
        ),
        "task_for_me": .noul(
            "この会話の中で、ご主人様がやるべき新しい作業や頼まれごとが生まれたかどうかを判定してください。"
                + "高い値は「新しい作業が生まれた」、低い値は「生まれていない」を意味します。"
                + "該当する材料が会話に全く無い場合は、0.5に近い値を返してください。",
            yes: "「これ調べておいて」「あとで直しておいて」のように、新しい依頼や作業がこの会話で出てきた",
            no: "新しい作業や頼まれごとの話は出ていない"
        ),
        "appointment": .noul(
            "日時を伴う予定（会う約束や打ち合わせなど）が、この会話の中で決まった、または提案されたかどうかを判定してください。"
                + "高い値は「予定が決まった、または提案された」、低い値は「そのような予定の話は出ていない」を意味します。"
                + "該当する材料が会話に全く無い場合は、0.5に近い値を返してください。",
            yes: "「来週火曜の14時に会いましょう」のように、日時を伴う予定が話題になった",
            no: "日時を伴う予定の話は出ていない"
        ),
        "belonging": .noul(
            "持っていく物・用意する物についての話がこの会話に出たかどうかを判定してください。"
                + "高い値は「持ち物や準備する物の話が出た」、低い値は「出ていない」を意味します。"
                + "該当する材料が会話に全く無い場合は、0.5に近い値を返してください。",
            yes: "「傘を持ってきて」「資料を用意しておいて」のように、持参・準備する物の話が出た",
            no: "持ち物や準備する物についての話は出ていない"
        ),
        "decision": .noul(
            "この会話の中で何かがはっきり決まったか（保留や検討中ではなく確定したか）を判定してください。"
                + "高い値は「はっきり決まった」、低い値は「決まっていない、または保留・検討中」を意味します。"
                + "該当する材料が会話に全く無い場合は、0.5に近い値を返してください。",
            yes: "「それで行こう」「これに決定」のように、結論がはっきり出た",
            no: "「検討します」のようにまだ決まっていない、または決めるべき話題自体が出ていない"
        ),
        "is_media": .noul(
            "目の前の人との会話ではなく、テレビ・動画・ポッドキャストなどの再生音であるかどうかを判定してください。"
                + "高い値は「再生音である」、低い値は「その場にいる相手との会話である」を意味します。"
                + "判断できる材料が会話に全く無い場合は、0.5に近い値を返してください。",
            yes: "ナレーション、CM、司会進行など、テレビ・動画・ポッドキャスト特有の一方向的な話し方が続いている",
            no: "その場にいる相手との、双方向の自然な会話になっている"
        ),
        "is_meeting": .noul(
            "複数人が議題を持って話し合っている場（雑談・独り言・作業音ではなく）であるかどうかを判定してください。"
                + "高い値は「会議である」、低い値は「会議ではない」を意味します。"
                + "判断できる材料が会話に全く無い場合は、0.5に近い値を返してください。",
            yes: "議題に沿って複数人が意見を出し合い、話し合いを進めている",
            no: "雑談、独り言、あるいは作業中の物音だけであり、議題を持った話し合いではない"
        ),
    ]
}
