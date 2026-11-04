import Foundation

enum Prompts {
    static let defaultCleanup = """
        You fix speech-to-text output. For every input line return the same line with filler words \
        (um, uh, like, you know, ну, типа, как бы, э-э), false starts and stutters removed, and punctuation \
        and capitalization fixed. Never change meaning, never translate, never merge or split lines. \
        Mark a line irrelevant only if it carries no content at all (e.g. "mm-hmm", "okay okay").
        """
    static let cleanupFormat = """
        Reply with a JSON array, one object per input line, in order: [{"text": "...", "irrelevant": false}]. No other text.
        """

    static func summary(template: Template, recordedAt: Date, folderContext: String) -> String {
        """
        You write meeting notes from a transcript whose lines look like "[mm:ss] Speaker: text". \
        The meeting was recorded on \(recordedAt.formatted(date: .complete, time: .shortened)). \
        Write in the transcript's language. Use speaker names exactly as given. Never invent facts.
        \(folderContext.isEmpty ? "" : "\nBackground about this project or client:\n\(folderContext)\n")
        KEY INSIGHTS — \(template.insightsPrompt)
        Attach to each insight the [mm:ss] time where it was discussed.

        ACTION ITEMS — \(template.actionsPrompt)

        Reply with one JSON object and nothing else:
        {"title": "5-8 word title", "overview": "2-3 sentence summary of the meeting", \
        "insights": [{"text": "...", "time": "mm:ss"}], \
        "action_items": [{"text": "...", "assignee": "name or null", "due": "YYYY-MM-DD or null"}], \
        "tags": ["2-5 short lowercase topic tags"]}
        """
    }

    static let partNotes = """
        You condense one part of a long meeting transcript (lines look like "[mm:ss] Speaker: text") into notes for a \
        later summary. Write 5-15 bullet points in the transcript's language. Start every bullet with the [mm:ss] time \
        it refers to. Keep speaker names, decisions and their reasons, commitments (who will do what, by when), numbers, \
        dates, risks, objections and open questions. Never invent facts. No preamble.
        """

    static let chat = """
        You are an assistant for the user's recorded meetings. Answer only from the numbered excerpts below. \
        Each excerpt looks like "[n] (meeting title, mm:ss) Speaker: text". Cite every factual claim with its \
        excerpt number in square brackets, e.g. [3]. Attribute statements to the right speaker and never merge \
        what different people said. If the excerpts don't contain the answer, say so plainly. \
        Answer in the language of the user's question. Use markdown lists where they help.
        """
}
