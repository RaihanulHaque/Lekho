import Cocoa
import InputMethodKit

// Headless integration test: drives the real LekhoInputController with
// synthesized key events against a mock IMKTextInput client.

final class MockClient: NSObject, IMKTextInput {
    var committed = ""
    var marked = ""
    /// Whether the app lets an input method read its text; not all do.
    var readable = true

    func insertText(_ string: Any!, replacementRange: NSRange) {
        if replacementRange.location != NSNotFound {
            committed = (committed as NSString).replacingCharacters(in: replacementRange, with: "")
        }
        committed += (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        marked = ""
    }
    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        if replacementRange.location != NSNotFound {
            committed = (committed as NSString).replacingCharacters(in: replacementRange, with: "")
        }
        marked = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
    }
    func selectedRange() -> NSRange { NSRange(location: committed.utf16.count, length: 0) }
    func markedRange() -> NSRange {
        marked.isEmpty ? NSRange(location: NSNotFound, length: 0)
                       : NSRange(location: committed.utf16.count, length: marked.utf16.count)
    }
    func attributedSubstring(from range: NSRange) -> NSAttributedString! { NSAttributedString(string: "") }
    func length() -> Int { committed.utf16.count + marked.utf16.count }
    func characterIndex(for point: NSPoint, tracking: IMKLocationToOffsetMappingMode,
                        inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { 0 }
    func attributes(forCharacterIndex index: Int,
                    lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! {
        lineRect?.pointee = NSRect(x: 40, y: 40, width: 1, height: 18); return [:]
    }
    func validAttributesForMarkedText() -> [Any]! { [] }
    func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) {}
    func selectMode(_ modeIdentifier: String!) {}
    func supportsUnicode() -> Bool { true }
    func bundleIdentifier() -> String! { "test.client" }
    func windowLevel() -> CGWindowLevel { 0 }
    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
    func uniqueClientIdentifierString() -> String! { "test" }
    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! {
        // The real client writes through this pointer unconditionally; nil crashes it.
        actualRange.pointee = range
        return readable ? (committed as NSString).substring(with: range) : nil
    }
    func firstRect(forCharacterRange aRange: NSRange, actualRange: NSRangePointer!) -> NSRect {
        NSRect(x: 40, y: 40, width: 1, height: 18)
    }
}

var failures = 0
func check(_ name: String, _ got: String, _ want: String) {
    if got == want { print("  ok   \(name): \(got)") }
    else { failures += 1; print("  FAIL \(name): got «\(got)» want «\(want)»") }
}
func checkTrue(_ name: String, _ cond: Bool, _ detail: String = "") {
    if cond { print("  ok   \(name) \(detail)") } else { failures += 1; print("  FAIL \(name) \(detail)") }
}

let SPACE: UInt16 = 49, RET: UInt16 = 36, BKSP: UInt16 = 51, TAB: UInt16 = 48
let DOWN: UInt16 = 125, UP: UInt16 = 126, ESC: UInt16 = 53

struct Rig {
    let controller: LekhoInputController
    let client = MockClient()
    init() { controller = LekhoInputController(server: nil, delegate: nil, client: nil) }

    @discardableResult
    func key(_ code: UInt16, chars: String = "", flags: NSEvent.ModifierFlags = []) -> Bool {
        let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                  windowNumber: 0, context: nil, characters: chars,
                                  charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        let handled = controller.handle(ev, client: client)
        if code == SPACE && !handled { client.committed += " " }  // space passes through to the app
        if code == BKSP && !handled && !client.committed.isEmpty { client.committed.removeLast() }  // so does backspace
        return handled
    }
    func type(_ text: String) {
        for ch in text {
            if ch == " " { key(SPACE, chars: " ") }
            else { key(0, chars: String(ch), flags: ch.isUppercase ? .shift : []) }
        }
    }
    var candidates: [String] { (controller.candidates(client) as? [String]) ?? [] }
    func take() -> String { let s = client.committed; client.committed = ""; return s }
}

func setMode(_ mode: String) {
    UserDefaults.standard.set(mode, forKey: LekhoInputController.typingModeKey)
    NotificationCenter.default.post(name: .lekhoTypingModeChanged, object: nil)
}
func setEmoji(_ on: Bool) {
    UserDefaults.standard.set(on, forKey: LekhoInputController.showEmojiKey)
    NotificationCenter.default.post(name: .lekhoEmojiSettingChanged, object: nil)
}

// --- setup: scratch user dir with a deliberately corrupt riti selections file
let userDir = ProcessInfo.processInfo.environment["LEKHO_USER_DIR"]!
try? FileManager.default.removeItem(atPath: userDir)
try! FileManager.default.createDirectory(atPath: userDir, withIntermediateDirectories: true)
try! "{ this is not json".write(toFile: userDir + "/phonetic-candidate-selection.json", atomically: true, encoding: .utf8)
UserDefaults.standard.set("phoneticFirst", forKey: LekhoInputController.typingModeKey)
UserDefaults.standard.set(true, forKey: LekhoInputController.showEmojiKey)

let a = Rig()

print("== corrupt selections file is quarantined, not fatal")
a.type("ami ")
check("survived + typed", a.take(), "আমি ")
let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: userDir)) ?? []
checkTrue("moved aside", leftovers.contains { $0.contains(".corrupt-") }, "\(leftovers)")

print("== phonetic-first: literal spelling is listed first and committed")
for (typed, want) in [("sonar", "সনার"), ("hasi", "হাসি"), ("academy", "আচাদেম্য"),
                      ("sonargulo", "সনারগুল"), (":)", "ঃ)"), ("ami", "আমি")] {
    a.type(typed)
    check("\(typed) → row 1", a.candidates.first ?? "", want)
    a.type(" ")
    check("\(typed) + space", a.take(), want + " ")
}
a.type("sonar"); checkTrue("suggestions still listed below", a.candidates.contains("সোনার"), "\(a.candidates)")
a.key(ESC); _ = a.take()
// Patched upodesh (engine/vendor): দ্ধ words were missing from the list.
a.type("muktizoddha"); check("dictionary word right below", a.candidates.count > 1 ? a.candidates[1] : "", "মুক্তিযোদ্ধা")
a.key(ESC); _ = a.take()
// Repaired entry (stored with ো as two code points before): কোনো.
a.type("kono"); checkTrue("kono offers \u{995}\u{9cb}\u{9a8}\u{9cb}", a.candidates.contains("\u{995}\u{9cb}\u{9a8}\u{9cb}"), "\(a.candidates)")
a.key(ESC); _ = a.take()
a.type("\"ami\""); check("quoted word selects literal spelling", a.client.marked, "“আমি”")
a.type(" "); check("quoted word commit", a.take(), "“আমি” ")

print("== phonetic-first: deliberate picks are remembered, re-picking phonetic forgets")
a.type("sonar"); a.key(DOWN); a.type(" ")
check("pick via arrow", a.take(), "সোনার ")
a.type("sonar ");  check("remembered next time", a.take(), "সোনার ")
a.type("sonar. "); check("remembered with punctuation", a.take(), "সোনার। ")
a.type("sonar"); check("phonetic still row 1", a.candidates.first ?? "", "সনার")
a.key(UP); a.type(" "); check("re-pick phonetic", a.take(), "সনার ")
a.type("sonar ");  check("forgotten again", a.take(), "সনার ")
// riti itself can never learn a pick of ITS index 0 (হাঁসই for hasi) — ours can.
a.type("hasi"); checkTrue("riti's top word is row 2", a.candidates.count > 1 && a.candidates[1] == "হাঁসই", "\(a.candidates.prefix(3))")
a.key(0, chars: "2"); check("pick by number", a.take(), "হাঁসই")
// A pick leaves a space pending; the next word commits it.
a.type("hasi ");   check("riti-index-0 pick remembered", a.take(), " হাঁসই ")
a.type("love"); let heart = a.candidates.firstIndex { LekhoInputController.containsEmoji($0) }!
a.key(0, chars: String(heart + 1)); _ = a.take()
a.type("love ");   check("emoji pick is NOT remembered", a.take(), " লভে ")
checkTrue("riti selections file untouched in this mode",
          !FileManager.default.fileExists(atPath: userDir + "/phonetic-candidate-selection.json"))

print("== navigation + punctuation keeps the navigated selection")
a.type("bari"); a.key(DOWN); a.key(DOWN); let navigated = a.candidates[2]
a.type(","); check("selection survives ','", a.client.marked, navigated + ",")
a.type(" "); _ = a.take()
a.type("bari"); a.key(DOWN); a.key(BKSP); check("backspace resets to literal", a.client.marked, "বার")
a.key(ESC); checkTrue("escape clears", a.client.marked.isEmpty && a.take().isEmpty)

print("== emoji toggle")
a.type("fire"); checkTrue("emoji shown when on", a.candidates.contains { LekhoInputController.containsEmoji($0) }, "\(a.candidates)")
a.key(ESC); setEmoji(false)
a.type("fire"); checkTrue("emoji hidden when off", !a.candidates.contains { LekhoInputController.containsEmoji($0) }, "\(a.candidates)")
a.key(ESC)
a.type(":)"); checkTrue("emoticon list has no emoji", !a.candidates.contains { LekhoInputController.containsEmoji($0) }, "\(a.candidates)")
a.key(ESC); _ = a.take()

print("== smart mode (emoji off): index mapping + riti learning")
setMode("smart")
a.type("sonar "); check("smart commits top-ranked", a.take(), "সোনার ")
a.type("muktizoddha "); check("smart corrects দ্ধ word", a.take(), "মুক্তিযোদ্ধা ")
a.type("oitijjo "); check("smart finds word-initial ঐ", a.take(), "ঐতিহ্য ")
a.type("onurodh "); check("smart finds a repaired entry", a.take(), "\u{985}\u{9a8}\u{9c1}\u{9b0}\u{9cb}\u{9a7} ")
a.type("fire"); let smartList = a.candidates
checkTrue("no emoji in smart list", !smartList.contains { LekhoInputController.containsEmoji($0) }, "\(smartList)")
a.key(0, chars: "2"); check("number key picks displayed row 2", a.take(), smartList[1])
a.type("fire "); check("riti learned that row (mapped index)", a.take(), " " + smartList[1] + " ")
setEmoji(true)
a.type("boish"); checkTrue("riti ranks an emoji first here", LekhoInputController.containsEmoji(a.candidates[0]), "\(a.candidates.prefix(3))")
a.type(" "); check("…but space never commits an emoji", a.take(), "বিশ ")
a.type(":) "); check("emoticon still gives its emoji", a.take(), "😃 ")
a.type("fire"); checkTrue("emoji back", a.candidates.contains("🔥")); check("learned pick still selected", a.client.marked, smartList[1])
a.key(ESC); _ = a.take()

print("== phonetic-only")
setMode("phoneticOnly")
a.type("sonar"); checkTrue("no candidate list", a.candidates.isEmpty)
a.type(" "); check("inline literal", a.take(), "সনার ")
a.type("ami"); a.key(0, chars: "2"); check("digit commits + bengali digit", a.take(), "আমি২")
a.type("ami"); a.key(TAB); check("tab commits (lonely guard)", a.take(), "আমি")

print("== option+backspace deletes the whole word")
setMode("phoneticFirst")
a.type("sonar"); a.key(BKSP, flags: .option)
checkTrue("word gone", a.client.marked.isEmpty && a.take().isEmpty)
a.type("ami "); check("clean next word", a.take(), "আমি ")
a.key(0, chars: "7"); check("bengali digit outside session", a.take(), "৭")

print("== commitComposition (click elsewhere mid-word)")
a.type("ami"); a.controller.commitComposition(a.client)
check("word committed", a.take(), "আমি")
a.type("t "); check("no stale buffer", a.take(), "ত ")

print("== shared engine: second client takes over mid-word")
let b = Rig()
a.type("ami")
b.type("t ")
check("first client got its word", a.take(), "আমি")
check("second client starts clean", b.take(), "ত ")
a.type("tumi"); b.controller.activateServer(b.client)
check("activate elsewhere commits the old word", a.take(), "তুমি")
a.type("ki"); a.controller.deactivateServer(a.client); check("deactivate commits", a.take(), "কি")

print("== numbers keep their dots and colons; digits are never eaten")
for mode in ["smart", "phoneticFirst", "phoneticOnly"] {
    setMode(mode)
    for (typed, want) in [("06.10.2026 ", "০৬.১০.২০২৬ "), ("3.14 ", "৩.১৪ "), ("10:30 ", "১০:৩০ "),
                          ("25. ", "২৫। "), (".5 ", ".৫ "), ("1.` ", "১. "), ("ami. ", "আমি। ")] {
        a.type(typed); check("\(mode): \(typed)", a.take(), want)
    }
    a.type("25."); a.key(BKSP); a.type("0 "); check("\(mode): backspace drops the pending dot", a.take(), "২৫০ ")
    a.type("25"); a.key(47, chars: ".", flags: .control); a.type(" ")
    check("\(mode): Ctrl+. after a number", a.take(), "২৫. ")
    a.type("ami"); a.key(47, chars: ".", flags: .control)
    check("\(mode): Ctrl+. after a word", a.take(), "আমি.")
    a.type("covid-19 "); let covid = a.take()
    checkTrue("\(mode): digits after a hyphen are typed", covid.hasSuffix("-১৯ "), covid)
}

print("== picking from the list types the space too")
for mode in ["smart", "phoneticFirst"] {
    setMode(mode)
    a.type("ami"); let picked = a.candidates[0]
    a.key(RET); check("\(mode): Return picks", a.take(), picked)
    check("\(mode): a space is pending", a.client.marked, " ")
    a.type("tumi "); check("\(mode): next word commits the space", a.take(), " তুমি ")
    a.type("ami"); a.key(RET); a.type(". ")
    check("\(mode): no space before punctuation", a.take(), picked + "। ")
    a.type("ami"); a.key(RET); a.key(SPACE)
    check("\(mode): Space after a pick gives one space", a.take(), picked + " ")
    a.type("ami"); a.key(RET); let passedOn = !a.key(RET)
    checkTrue("\(mode): second Return reaches the app, no trailing space", passedOn && a.take() == picked)
    a.type("ami"); a.key(RET); a.key(BKSP)
    check("\(mode): Backspace takes the space back", a.take() + a.client.marked, picked)
    a.type("ami"); a.key(RET); let arrowPassed = !a.key(DOWN, chars: "\u{F701}")
    checkTrue("\(mode): an arrow leaves without the space", arrowPassed && a.take() + a.client.marked == picked)
    a.type("ami"); let second = a.candidates[1]; a.controller.candidateClicked(at: 1)
    a.type("ki "); check("\(mode): mouse pick + next word", a.take(), second + " কি ")
}
setMode("phoneticOnly")
a.type("ami"); a.key(RET); check("phonetic-only Return commits without a space", a.take() + a.client.marked, "আমি")

print("== live mode switch mid-word drops the word")
a.type("sonar"); setMode("smart")
checkTrue("dropped", a.client.marked.isEmpty && a.take().isEmpty)
a.type("sonar "); check("new mode active", a.take(), "সোনার ")

print("== next-word prediction learns from typing history")
setMode("phoneticFirst")
let c = Rig()
// An earlier test left a remembered pick for this word; back to its literal spelling.
c.type("ami"); c.key(0, chars: "1"); c.key(ESC); _ = c.take()
WordPredictor.shared.clearHistory()
let OPT2: UInt16 = 19
func click(_ rig: Rig) {
    let ev = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    checkTrue("click goes on to the app", !rig.controller.handle(ev, client: rig.client))
}
func newLine(_ rig: Rig) { rig.key(RET); _ = rig.take() }

c.type("ami "); checkTrue("nothing predicted before any history", c.controller.predictions.isEmpty)
newLine(c)
c.type("ami bhat khai "); newLine(c)
c.type("ami ")
check("seen once → predicted", c.controller.predictions.joined(separator: ","), "ভাত")
_ = c.take()
let tabUsed = c.key(TAB, chars: "\t")
checkTrue("Tab is used up", tabUsed)
check("Tab types the word", c.take(), "ভাত")
check("…with a space pending", c.client.marked, " ")
check("next word chained", c.controller.predictions.joined(separator: ","), "খাই")
c.key(TAB, chars: "\t")
check("chained word gets the pending space", c.take(), " খাই")
newLine(c); c.key(ESC); _ = c.take()

print("== predictions: ranking")
for _ in 0..<2 { c.type("ami tumi "); newLine(c) }
c.type("ami ")
check("most frequent first", c.controller.predictions.first ?? "", "তুমি")
checkTrue("alternatives follow", c.controller.predictions.contains("ভাত"), "\(c.controller.predictions)")
_ = c.take()
let second = c.controller.predictions[1]
c.key(OPT2, chars: "\u{2122}", flags: .option)
check("Option+2 takes the second", c.take(), second)
newLine(c); c.key(ESC); _ = c.take()
// The two-word context outranks the one-word one, even with fewer sightings.
c.type("ke ami khela "); newLine(c)
c.type("ke ami ")
check("two-word context wins", c.controller.predictions.first ?? "", "খেলা")
_ = c.take(); newLine(c)
c.type("ami "); check("one-word context unaffected", c.controller.predictions.first ?? "", "ভাত")

print("== predictions: other keys behave as before")
c.key(ESC); checkTrue("Escape dismisses", c.controller.predictions.isEmpty); _ = c.take()
c.type("ami "); c.key(TAB, chars: "\t"); _ = c.take(); newLine(c); c.key(ESC); _ = c.take()
c.type("ami "); _ = c.take()
c.type("ki "); check("typing goes on as usual", c.take(), "কি ")
newLine(c)
c.type("ami "); _ = c.take(); c.key(0, chars: "5")
check("digit is still a digit", c.take(), "৫")
checkTrue("digit dismisses", c.controller.predictions.isEmpty)
c.type("ami ");  _ = c.take(); let passed = !c.key(TAB, chars: "\u{19}", flags: .shift)
checkTrue("Shift+Tab reaches the app", passed)
c.type("ami");   c.key(RET); check("list pick: word", c.take(), "আমি")
checkTrue("list pick predicts too", !c.controller.predictions.isEmpty)
c.key(SPACE, chars: " "); check("space after a pick", c.take(), " ")
checkTrue("…keeps the predictions", !c.controller.predictions.isEmpty)
newLine(c)

print("== predictions: what isn't learned")
c.type("kothay ");  c.key(BKSP); c.type("gelo "); newLine(c); _ = c.take()
c.type("kothay "); checkTrue("backspaced word start doesn't link", c.controller.predictions.isEmpty, "\(c.controller.predictions)")
newLine(c)
c.type("shuru bhul"); c.type(" "); c.key(BKSP); c.key(BKSP); c.type("thik "); newLine(c)
c.type("shuru "); checkTrue("retracted typo isn't predicted", !c.controller.predictions.contains("ভুল"), "\(c.controller.predictions)")
newLine(c)
c.type("shesh. porer "); newLine(c)
c.type("shesh "); checkTrue("nothing across a sentence end", c.controller.predictions.isEmpty, "\(c.controller.predictions)")
newLine(c)
c.type("dam 25 taka "); newLine(c)
c.type("dam "); checkTrue("no link across a number", c.controller.predictions.isEmpty, "\(c.controller.predictions)")
newLine(c)
c.type("kobe "); c.key(DOWN, chars: "\u{F701}"); c.type("jabo "); newLine(c)
c.type("kobe "); checkTrue("no link across an arrow key", c.controller.predictions.isEmpty, "\(c.controller.predictions)")
newLine(c)
c.type("kotha "); click(c); checkTrue("click dismisses", c.controller.predictions.isEmpty)
c.type("onno "); newLine(c)
c.type("kotha "); checkTrue("no link across a click", c.controller.predictions.isEmpty, "\(c.controller.predictions)")
newLine(c)
c.type("chai "); c.controller.commitComposition(c.client); c.type("na "); newLine(c)
c.type("chai "); checkTrue("no link across commitComposition", c.controller.predictions.isEmpty, "\(c.controller.predictions)")
newLine(c); _ = c.take()

print("== predictions: persisted, private, resilient")
WordPredictor.shared.saveNow(); WordPredictor.shared.waitForDisk()
let historyPath = userDir + "/next-word-history.json"
let historyURL = URL(fileURLWithPath: historyPath)
let perms = (try? FileManager.default.attributesOfItem(atPath: historyPath)[.posixPermissions]) as? Int
checkTrue("only the user can read it", perms == 0o600, "\(String(describing: perms))")
let reloaded = WordPredictor(fileURL: historyURL)
reloaded.didCommit("আমি")
checkTrue("survives a restart", reloaded.predictions().contains("তুমি"), "\(reloaded.predictions())")
let junkURL = URL(fileURLWithPath: userDir + "/junk.json")
try! "not json".write(to: junkURL, atomically: true, encoding: .utf8)
let fromJunk = WordPredictor(fileURL: junkURL)
fromJunk.didCommit("আমি")
checkTrue("corrupt file starts empty", fromJunk.predictions().isEmpty)
checkTrue("corrupt file moved aside", !FileManager.default.fileExists(atPath: junkURL.path))

print("== predictions: settings")
UserDefaults.standard.set(false, forKey: LekhoInputController.predictNextWordKey)
NotificationCenter.default.post(name: .lekhoNextWordSettingChanged, object: nil)
c.type("ami "); checkTrue("off: nothing predicted", c.controller.predictions.isEmpty); _ = c.take()
let tabOff = !c.key(TAB, chars: "\t"); checkTrue("off: Tab reaches the app", tabOff); newLine(c)
UserDefaults.standard.set(true, forKey: LekhoInputController.predictNextWordKey)
NotificationCenter.default.post(name: .lekhoNextWordSettingChanged, object: nil)
c.type("ami "); checkTrue("back on: history kept", !c.controller.predictions.isEmpty); _ = c.take()
setMode("phoneticOnly")
checkTrue("mode switch dismisses", c.controller.predictions.isEmpty)
c.type("ami "); checkTrue("phonetic-only: never", c.controller.predictions.isEmpty); _ = c.take(); newLine(c)
setMode("phoneticFirst")
c.type("ami "); _ = c.take()
NotificationCenter.default.post(name: .lekhoNextWordHistoryCleared, object: nil)
checkTrue("clear dismisses", c.controller.predictions.isEmpty)
WordPredictor.shared.waitForDisk()
checkTrue("clear removes the file", !FileManager.default.fileExists(atPath: historyPath))
newLine(c)
c.type("ami "); checkTrue("clear forgets", c.controller.predictions.isEmpty); newLine(c); _ = c.take()

print("== backspace reopens the word just typed")
WordPredictor.shared.clearHistory()
c.type("ami"); c.key(BKSP); c.type("i"); check("mid-word retype", c.client.marked, "আমি"); c.key(ESC); _ = c.take()
c.type("ami "); c.key(BKSP); check("first backspace takes the space", c.client.committed, "আমি")
c.key(BKSP)
check("second reopens the word", c.client.marked, "আম")
check("…out of the app's text", c.client.committed, "")
c.type("i"); check("retyping gives the same word", c.client.marked, "আমি")
checkTrue("suggestions are back", c.candidates.contains("আমি"), "\(c.candidates.prefix(3))")
c.type(" "); check("commits once", c.take(), "আমি ")
newLine(c)
c.type("ami"); c.key(RET); c.key(BKSP); c.key(BKSP)
check("after a list pick", c.client.marked, "আম"); c.type("i "); check("…same word", c.take(), "আমি "); newLine(c)
c.type("ami "); c.key(BKSP); c.type("r"); check("typing on continues the word", c.client.marked, "আমির")
c.type(" "); check("…as one word", c.take(), "আমির "); newLine(c)
c.type("ami. "); c.key(BKSP); c.key(BKSP); check("reopens past punctuation", c.client.marked, "আমি"); c.key(ESC); _ = c.take()
c.type("t "); c.key(BKSP); c.key(BKSP)
check("one letter word: gone", c.client.committed + c.client.marked, ""); c.type("ki "); check("next word clean", c.take(), "কি "); newLine(c)
// Nothing but the word we typed may be replaced.
c.type("ami "); c.client.committed = "abc "; c.key(BKSP); c.key(BKSP)
check("changed text isn't touched", c.client.marked, ""); check("…plain backspace", c.take(), "ab"); newLine(c)
c.client.readable = false
c.type("ami "); c.key(BKSP); c.key(BKSP); check("unreadable app: plain backspace", c.client.marked, ""); _ = c.take()
c.client.readable = true; newLine(c)
c.type("ami "); click(c); c.key(BKSP); c.key(BKSP); check("not after a click", c.client.marked, ""); _ = c.take(); newLine(c)
c.type("ami "); c.key(DOWN, chars: "\u{F701}"); c.key(BKSP); check("not after an arrow", c.client.marked, ""); _ = c.take(); newLine(c)
print("== reopening keeps the phrase")
c.type("ami bhul "); c.key(BKSP); c.key(BKSP); c.type("l "); newLine(c)
c.type("ami "); check("edited word still follows the one before", c.controller.predictions.joined(separator: ","), "ভুল"); _ = c.take()
newLine(c); c.type("ami bhul ")
c.key(BKSP); c.key(BKSP); c.key(BKSP); c.key(BKSP); c.key(BKSP); c.type("bhat "); newLine(c)
c.type("ami "); checkTrue("replaced word is learned", c.controller.predictions.contains("ভাত"), "\(c.controller.predictions)"); _ = c.take(); newLine(c)
c.type("ami "); c.key(TAB, chars: "\t"); c.key(BKSP); c.key(BKSP)
check("an accepted suggestion reopens too", c.client.marked, "ভা")
c.key(ESC); _ = c.take(); newLine(c)

print("== removing and retyping a letter of আমার")
WordPredictor.shared.clearHistory()
c.type("amar boi "); newLine(c)
c.type("amar"); let fresh = c.candidates; let freshMark = c.client.marked
c.key(BKSP); check("mid-word: letter gone", c.client.marked, "আমা")
c.type("r"); check("mid-word: same word", c.client.marked, freshMark)
check("mid-word: same list", c.candidates.joined(separator: ","), fresh.joined(separator: ","))
c.type(" "); check("mid-word: commits", c.client.committed, "আমার ")
check("mid-word: next word still predicted", c.controller.predictions.joined(separator: ","), "বই")
_ = c.take(); newLine(c)
c.type("amar "); c.key(BKSP); c.key(BKSP); check("committed: reopened", c.client.marked, "আমা")
c.type("r"); check("committed: same word", c.client.marked, freshMark)
check("committed: same list", c.candidates.joined(separator: ","), fresh.joined(separator: ","))
c.type(" "); check("committed: commits", c.client.committed, "আমার ")
check("committed: next word still predicted", c.controller.predictions.joined(separator: ","), "বই")
_ = c.take(); newLine(c)
c.type("amar "); check("still remembered afterwards", c.controller.predictions.joined(separator: ","), "বই")
_ = c.take(); newLine(c)
c.type("amar boi "); c.key(BKSP); c.key(BKSP); c.type("i ");
check("second word edited", c.client.committed, "আমার বই "); _ = c.take(); newLine(c)
c.type("amar "); check("link survives editing the next word", c.controller.predictions.joined(separator: ","), "বই")
_ = c.take(); newLine(c)

print("== remove a letter, Space, Backspace, retype it")
c.type("amar"); c.key(BKSP); c.type(" "); check("word without the letter", c.client.committed, "আমা ")
c.key(BKSP); check("space gone", c.client.committed, "আমা")
c.type("r"); check("typing on continues the word", c.client.marked, "আমার"); check("…out of the text", c.client.committed, "")
checkTrue("…with its suggestions", c.candidates.contains("আমার"), "\(c.candidates.prefix(3))")
c.type(" "); check("…commits as one word", c.take(), "আমার "); newLine(c)
c.type("amar "); c.key(BKSP); c.key(BKSP); c.type(" "); check("reopened, shortened, committed", c.client.committed, "আমা ")
c.key(BKSP); c.type("r"); check("…continues too", c.client.marked, "আমার")
c.type(" "); check("…as one word", c.take(), "আমার "); newLine(c)

print("== English word picked from the list stays in the phrase")
WordPredictor.shared.clearHistory()
func pickEnglish(_ rig: Rig, _ word: String) {
    rig.type(word)
    guard let row = rig.candidates.firstIndex(of: word) else { checkTrue("\(word) is listed", false, "\(rig.candidates)"); return }
    rig.key(0, chars: String(row + 1))
}
c.type("ami "); pickEnglish(c, "vat"); c.type("diyechi ")
let phrase = c.take(); newLine(c)
let lastWord = String(phrase.split(separator: " ").last ?? "")
check("typed as expected", phrase, "আমি vat \(lastWord) ")
c.type("ami "); check("English word predicted after Bangla", c.controller.predictions.joined(separator: ","), "vat")
_ = c.take()
c.key(TAB, chars: "\t"); check("Tab types it", c.take(), "vat")
check("Bangla word predicted after English", c.controller.predictions.joined(separator: ","), lastWord)
c.key(TAB, chars: "\t"); check("…and chains", c.take(), " " + lastWord); newLine(c); c.key(ESC); _ = c.take()
pickEnglish(c, "vat"); c.key(BKSP); c.key(BKSP); checkTrue("picked English word reopens", !c.client.marked.isEmpty, c.client.marked)
c.type("t"); check("retyping gives the English word back", c.client.marked, "vat")
c.key(ESC); _ = c.take(); newLine(c)
c.type("ami "); _ = c.take(); c.key(0, chars: "5"); newLine(c); _ = c.take()
c.type("covid-19 "); checkTrue("digits still break the phrase", c.controller.predictions.isEmpty, "\(c.controller.predictions)"); newLine(c); _ = c.take()

print("== history while typing the next word")
setMode("phoneticFirst")
WordPredictor.shared.clearHistory()
c.type("ami bhat "); newLine(c); _ = c.take()
c.type("ami "); _ = c.take()
c.type("b")
check("first letter: literal stays first", c.candidates.first ?? "", "ব")
check("first letter: usual next word right below", c.candidates.count > 1 ? c.candidates[1] : "", "ভাত")
check("marked text is still the literal", c.client.marked, "ব")
c.type("h"); check("second letter: still listed", c.candidates.count > 1 ? c.candidates[1] : "", "ভাত")
c.type(" "); check("Space commits what was typed", c.take(), "ভ "); newLine(c)
// That taught ভ too; start over so only ভাত follows আমি.
WordPredictor.shared.clearHistory(); c.type("ami bhat "); newLine(c); _ = c.take()
c.type("ami "); _ = c.take(); c.type("k"); checkTrue("different start: not listed", !c.candidates.contains("ভাত"), "\(c.candidates.prefix(3))")
c.key(ESC); _ = c.take(); newLine(c)
c.type("b"); checkTrue("no context: not listed", !c.candidates.contains("ভাত"), "\(c.candidates.prefix(3))"); c.key(ESC); _ = c.take()
c.type("ami "); _ = c.take(); c.type("bhat"); check("whole word: one row", String(c.candidates.filter { $0 == "ভাত" }.count), "1")
check("whole word: first", c.candidates.first ?? "", "ভাত"); c.key(ESC); _ = c.take(); newLine(c)
print("== picking a history row")
c.type("ami "); _ = c.take(); c.type("b"); c.key(DOWN)
check("arrow shows the word", c.client.marked, "ভাত")
c.type(" "); check("Space commits the selected row", c.take(), "ভাত "); newLine(c)
c.type("ami "); _ = c.take(); c.type("b"); check("not remembered as the spelling of b", c.client.marked, "ব")
c.key(0, chars: "2"); check("number picks the row", c.client.committed, "ভাত"); check("…leaving a space", c.client.marked, " ")
c.key(BKSP); c.key(BKSP); check("reopens with its real spelling", c.client.marked, "ভা"); c.key(ESC); _ = c.take(); newLine(c)
c.type("ami "); _ = c.take(); c.type("b"); c.controller.candidateClicked(at: 1); check("click picks the row", c.take(), "ভাত"); newLine(c); c.key(ESC); _ = c.take()
c.type("b"); c.key(ESC); _ = c.take()
print("== words already in the list move up")
c.type("sonar"); c.key(DOWN); c.type(" "); check("teach a picked spelling", c.take(), "সোনার "); newLine(c)
c.type("ami "); _ = c.take(); c.type("sonar"); c.key(0, chars: "1"); _ = c.take(); newLine(c)
c.type("ami sonar"); _ = c.take()
checkTrue("listed", c.candidates.contains("সোনার"), "\(c.candidates.prefix(3))"); c.key(ESC); _ = c.take(); newLine(c)
WordPredictor.shared.clearHistory()
c.type("amar"); let plainList = c.candidates; c.key(ESC); _ = c.take()
checkTrue("আম্মার starts lower down", plainList.firstIndex(of: "আম্মার") ?? 0 > 1, "\(plainList)")
c.type("ami "); _ = c.take(); c.type("amar"); c.key(0, chars: String(plainList.firstIndex(of: "আম্মার")! + 1)); _ = c.take(); newLine(c)
c.type("ami "); _ = c.take(); c.type("amar")
check("listed word moves right below the first", c.candidates[1], "আম্মার")
check("first row unchanged", c.candidates[0], plainList[0])
check("no duplicate", String(c.candidates.filter { $0 == "আম্মার" }.count), "1")
c.key(0, chars: "1"); _ = c.take(); newLine(c); c.key(ESC); _ = c.take()
print("== other modes and settings")
setMode("smart")
WordPredictor.shared.clearHistory()
c.type("ami bhat "); let smartPhrase = c.take().split(separator: " ").map(String.init); newLine(c)
c.type("ami "); _ = c.take(); c.type("b")
let smartDefault = c.client.marked
checkTrue("smart: listed", c.candidates.contains(smartPhrase[1]), "\(c.candidates.prefix(3))")
checkTrue("smart: not the default", smartDefault != smartPhrase[1], smartDefault)
c.type(" "); check("smart: Space keeps its default", c.take(), smartDefault + " "); newLine(c)
setMode("phoneticFirst")
WordPredictor.shared.clearHistory(); c.type("ami bhat "); newLine(c); _ = c.take()
UserDefaults.standard.set(false, forKey: LekhoInputController.predictNextWordKey)
NotificationCenter.default.post(name: .lekhoNextWordSettingChanged, object: nil)
c.type("ami "); _ = c.take(); c.type("b"); checkTrue("off: not listed", !c.candidates.contains("ভাত"), "\(c.candidates.prefix(3))"); c.key(ESC); _ = c.take(); newLine(c)
UserDefaults.standard.set(true, forKey: LekhoInputController.predictNextWordKey)
NotificationCenter.default.post(name: .lekhoNextWordSettingChanged, object: nil)
print("== spelling survives a restart; old history still loads")
c.key(ESC); WordPredictor.shared.endContext(); WordPredictor.shared.saveNow(); WordPredictor.shared.waitForDisk()
let again = WordPredictor(fileURL: URL(fileURLWithPath: userDir + "/next-word-history.json"))
again.didCommit("আমি")
checkTrue("spelling kept", again.completions(forTyped: "b").contains { $0.word == "ভাত" && $0.matchesTyped })
let oldURL = URL(fileURLWithPath: userDir + "/old-history.json")
try! #"{"version":1,"clock":1,"next":{"আমি":{"ভাত":{"count":2,"lastUsed":1}}}}"#.write(to: oldURL, atomically: true, encoding: .utf8)
let old = WordPredictor(fileURL: oldURL)
old.didCommit("আমি")
check("old file: prediction kept", old.predictions().joined(), "ভাত")
checkTrue("old file: no spelling yet", old.completions(forTyped: "b").first?.matchesTyped == false)

UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
