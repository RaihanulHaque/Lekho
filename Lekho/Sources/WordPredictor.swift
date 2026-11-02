import Foundation

/// Learns which Bangla word the user types after which, and predicts the next
/// word from that history. Everything stays in one local file in the user dir.
///
/// A word is only learned once the next thing typed confirms it: backspacing
/// right after a word retracts it, so typos don't end up in the history. Only
/// whole Bangla words are stored, never digits, English, or emoji, and any of
/// those (or punctuation) ends the phrase being tracked.
///
/// Main thread only, like the controllers that call it.
final class WordPredictor {
    static let shared = WordPredictor(fileURL: URL(fileURLWithPath: LekhoEngine.userDataDir())
        .appendingPathComponent("next-word-history.json"))

    static let maxPredictions = 3
    private static let maxNextWordsPerContext = 12
    private static let maxContexts = 20_000
    private static let maxWordLength = 40
    private static let saveDelay: TimeInterval = 2

    private struct Entry: Codable {
        var count: Int
        /// Value of `Store.clock` when last typed; breaks ties in favor of recent words.
        var lastUsed: Int
    }

    private struct Store: Codable {
        var version = 1
        var clock = 0
        /// Context ("B", or "A B" for the two words before) → next word → stats.
        var next: [String: [String: Entry]] = [:]
    }

    private struct Observation {
        let context: [String]
        let word: String
    }

    private var store = Store()
    /// The last words typed in this stretch of text, oldest first (at most two).
    private var context: [String] = []
    /// The latest word, waiting for the next key to confirm it.
    private var unconfirmed: Observation?
    /// How recently accepted words were typed, so one can be reopened for editing.
    private var typedKeysByWord: [String: [LekhoEngine.TypedKey]] = [:]

    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "com.lekho.inputmethod.nextword", qos: .utility)
    private var pendingSave: DispatchWorkItem?

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: Typing events

    /// `text` was committed as a word, possibly with punctuation around it.
    func didCommit(_ text: String) {
        confirm()
        let word = PhoneticFirstPicks.core(text)
        guard Self.isLearnable(word) else {
            context = []
            return
        }
        if !text.hasPrefix(word) { context = [] }
        unconfirmed = Observation(context: context, word: word)
        context = Array((context + [word]).suffix(2))
        // Punctuation after the word ends the phrase.
        if !text.hasSuffix(word) { endContext() }
    }

    /// The cursor moved or the text changed: what comes next doesn't follow the
    /// words typed so far.
    func endContext() {
        confirm()
        context = []
    }

    /// The user went back to edit the latest word; don't learn it.
    func retractLastWord() {
        unconfirmed = nil
        context = []
    }

    /// The words the next one will follow.
    var currentContext: [String] { context }

    /// A committed word is being edited again: it follows these words, as before.
    func resume(context: [String]) {
        unconfirmed = nil
        self.context = context
    }

    /// Remember the keys that produced `word`; a suggestion accepted later comes
    /// with no keys of its own.
    func noteKeys(_ keys: [LekhoEngine.TypedKey], for word: String) {
        if typedKeysByWord.count >= 500 { typedKeysByWord.removeAll() }
        typedKeysByWord[word] = keys
    }

    func keys(for word: String) -> [LekhoEngine.TypedKey]? {
        return typedKeysByWord[word]
    }

    /// Best next words for the current context: those seen after the last two
    /// words come first, then those seen after the last word.
    func predictions() -> [String] {
        guard let last = context.last else { return [] }
        var result = context.count == 2 ? ranked(context.joined(separator: " ")) : []
        for word in ranked(last) where !result.contains(word) {
            result.append(word)
        }
        return Array(result.prefix(Self.maxPredictions))
    }

    private func ranked(_ key: String) -> [String] {
        guard let next = store.next[key] else { return [] }
        return next.sorted {
            ($0.value.count, $0.value.lastUsed) > ($1.value.count, $1.value.lastUsed)
        }.map { $0.key }
    }

    // MARK: Learning

    private static func isLearnable(_ word: String) -> Bool {
        guard !word.isEmpty, word.count <= maxWordLength else { return false }
        return word.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x09E6...0x09EF: return false              // Bengali digits
            case 0x0980...0x09FF, 0x200C, 0x200D: return true  // Bengali, ZWNJ, ZWJ
            default: return false
            }
        }
    }

    private func confirm() {
        guard let observation = unconfirmed else { return }
        unconfirmed = nil
        guard let last = observation.context.last else { return }
        learn(observation.word, after: last)
        if observation.context.count == 2 {
            learn(observation.word, after: observation.context.joined(separator: " "))
        }
        prune()
        scheduleSave()
    }

    private func learn(_ word: String, after key: String) {
        store.clock += 1
        var next = store.next[key] ?? [:]
        next[word, default: Entry(count: 0, lastUsed: 0)].count += 1
        next[word]?.lastUsed = store.clock
        if next.count > Self.maxNextWordsPerContext,
           let stalest = next.min(by: { ($0.value.count, $0.value.lastUsed) < ($1.value.count, $1.value.lastUsed) }) {
            next.removeValue(forKey: stalest.key)
        }
        store.next[key] = next
    }

    /// Past the size limit, forget the least recently used tenth of the contexts.
    private func prune() {
        guard store.next.count > Self.maxContexts else { return }
        let byAge = store.next.map { (key: $0.key, used: $0.value.values.map { $0.lastUsed }.max() ?? 0) }
            .sorted { $0.used < $1.used }
        for item in byAge.prefix(Self.maxContexts / 10) {
            store.next.removeValue(forKey: item.key)
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let stored = try? JSONDecoder().decode(Store.self, from: data) {
            store = stored
            return
        }
        let aside = fileURL.path + ".corrupt-\(Int(Date().timeIntervalSince1970))"
        NSLog("Lekho: %@ is unreadable, moving it to %@", fileURL.path, aside)
        try? FileManager.default.moveItem(atPath: fileURL.path, toPath: aside)
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    /// Write out everything learned so far, without waiting for the save delay.
    func saveNow() {
        confirm()
        guard pendingSave != nil else { return }
        save()
    }

    /// Encoding and writing happen off the main thread, away from the typing path.
    /// The file holds typing history, so only this user may read it.
    private func save() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = store
        let url = fileURL
        ioQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// Forget all history, on disk too.
    func clearHistory() {
        pendingSave?.cancel()
        pendingSave = nil
        store = Store()
        context = []
        unconfirmed = nil
        let url = fileURL
        ioQueue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Block until queued file operations are done (for tests).
    func waitForDisk() {
        ioQueue.sync {}
    }
}
