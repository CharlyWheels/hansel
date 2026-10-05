import XCTest
@testable import TimeTracker

/// Covers the short-id scheme that lets the model link an entry to a todo.
/// Pure logic over un-inserted @Model objects, same style as RuleEngineTests.
final class TodoLinkingTests: XCTestCase {

    // MARK: - flattenTodos

    func test_flatten_assignsDepthFirstIds() {
        let root = Todo(title: "Nedap rollout")
        let a = Todo(title: "Prepare data model", parent: root)
        let b = Todo(title: "Write migration", parent: root)
        root.subtasks = [a, b]

        let flat = PromptBuilder.flattenTodos(roots: [root])

        XCTAssertEqual(flat.map(\.key), ["T1", "T2", "T3"])
        XCTAssertEqual(flat.map(\.todo.title), ["Nedap rollout", "Prepare data model", "Write migration"])
        XCTAssertEqual(flat.map(\.depth), [0, 1, 1])
    }

    func test_flatten_skipsCompletedSubtreesEntirely() {
        let root = Todo(title: "Root")
        let done = Todo(title: "Done", isCompleted: true, parent: root)
        let doneChild = Todo(title: "Child of done", parent: done)
        done.subtasks = [doneChild]
        let open = Todo(title: "Open", parent: root)
        root.subtasks = [done, open]

        let flat = PromptBuilder.flattenTodos(roots: [root])

        // A completed parent takes its children with it — they are not offered.
        XCTAssertEqual(flat.map(\.todo.title), ["Root", "Open"])
    }

    func test_flatten_respectsCap() {
        let roots = (1...10).map { Todo(title: "Todo \($0)") }
        let flat = PromptBuilder.flattenTodos(roots: roots, cap: 4)
        XCTAssertEqual(flat.count, 4)
        XCTAssertEqual(flat.last?.key, "T4")
    }

    // MARK: - Resolution through DraftParser

    func test_resolvesShortId() throws {
        let root = Todo(title: "Nedap rollout")
        let child = Todo(title: "Prepare data model", parent: root)
        root.subtasks = [child]

        let draft = try parse(#"{"title":"Modelling","todo":"T2"}"#, todos: [root])
        XCTAssertEqual(draft.todo?.title, "Prepare data model")
    }

    func test_resolvesShortIdCaseInsensitively() throws {
        let root = Todo(title: "Q3 report")
        let draft = try parse(#"{"title":"Writing","todo":"t1"}"#, todos: [root])
        XCTAssertEqual(draft.todo?.title, "Q3 report")
    }

    func test_resolvesByBreadcrumbWhenModelEchoesText() throws {
        let root = Todo(title: "Nedap rollout")
        let child = Todo(title: "Prepare data model", parent: root)
        root.subtasks = [child]

        let draft = try parse(
            #"{"title":"Modelling","todo":"Nedap rollout › Prepare data model"}"#,
            todos: [root]
        )
        XCTAssertEqual(draft.todo?.title, "Prepare data model")
    }

    func test_ambiguousTitleResolvesToNil() throws {
        // Two different parents, same leaf title — a guess here would silently misfile.
        let r1 = Todo(title: "Acme")
        let c1 = Todo(title: "Kickoff", parent: r1)
        r1.subtasks = [c1]
        let r2 = Todo(title: "Globex")
        let c2 = Todo(title: "Kickoff", parent: r2)
        r2.subtasks = [c2]

        let draft = try parse(#"{"title":"Meeting","todo":"Kickoff"}"#, todos: [r1, r2])
        XCTAssertNil(draft.todo)
    }

    func test_unknownIdResolvesToNil() throws {
        let root = Todo(title: "Only one")
        let draft = try parse(#"{"title":"x","todo":"T99"}"#, todos: [root])
        XCTAssertNil(draft.todo)
    }

    func test_nullAndOmittedAndBlankResolveToNil() throws {
        let root = Todo(title: "Only one")
        for body in [
            #"{"title":"x","todo":null}"#,
            #"{"title":"x"}"#,
            #"{"title":"x","todo":""}"#,
            #"{"title":"x","todo":"  "}"#,
            #"{"title":"x","todo":"null"}"#,
        ] {
            let draft = try parse(body, todos: [root])
            XCTAssertNil(draft.todo, "expected nil for \(body)")
        }
    }

    func test_todoIdsInPromptMatchWhatParserResolves() throws {
        // The prompt's rendered ids and the parser's resolution must never drift apart.
        let root = Todo(title: "Root")
        let child = Todo(title: "Child", parent: root)
        root.subtasks = [child]
        let ctx = context(todos: [root])

        let (_, user) = PromptBuilder.build(context: ctx)
        XCTAssertTrue(user.contains("[T1] Root"), user)
        XCTAssertTrue(user.contains("[T2] Root › Child"), user)

        let draft = try DraftParser.parse(#"{"title":"x","todo":"T2"}"#, context: ctx, providerLabel: "test")
        XCTAssertEqual(draft.todo?.title, "Child")
    }

    // MARK: - Helpers

    private func parse(_ json: String, todos: [Todo]) throws -> EntryDraft {
        try DraftParser.parse(json, context: context(todos: todos), providerLabel: "test")
    }

    private func context(todos: [Todo]) -> SuggestionContext {
        SuggestionContext(
            windowStart: Date().addingTimeInterval(-600),
            windowEnd: Date(),
            samples: [],
            idleIntervals: [],
            recentEntries: [],
            projects: [],
            customers: [],
            roles: [],
            calendarEventTitle: nil,
            fields: ContextFieldSelection(),
            ruleHints: RuleEngine.Hints(),
            activeTodos: todos
        )
    }
}
