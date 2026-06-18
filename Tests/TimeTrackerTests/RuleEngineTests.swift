import XCTest
@testable import TimeTracker

final class RuleEngineTests: XCTestCase {

    private let now = Date()

    // MARK: - Matching

    func test_appBundleID_match() {
        let samples = [sample(bundleId: "com.apple.Safari", appName: "Safari")]
        let role = Role(name: "SE")
        let rule = ClassificationRule(
            name: "Safari means SE",
            targetRole: role,
            appBundleID: "com.apple.Safari"
        )
        XCTAssertTrue(RuleEngine.matches(rule: rule, samples: samples, calendarEventTitle: nil))
    }

    func test_appBundleID_noMatch() {
        let samples = [sample(bundleId: "com.microsoft.VSCode", appName: "Code")]
        let role = Role(name: "SE")
        let rule = ClassificationRule(
            name: "PowerBI",
            targetRole: role,
            appBundleID: "com.microsoft.powerbi.desktop"
        )
        XCTAssertFalse(RuleEngine.matches(rule: rule, samples: samples, calendarEventTitle: nil))
    }

    func test_appNameContains_caseInsensitive() {
        let samples = [sample(bundleId: "x", appName: "Microsoft POWERBI Desktop")]
        let role = Role(name: "DA")
        let rule = ClassificationRule(
            name: "powerbi",
            targetRole: role,
            appNameContains: "powerbi"
        )
        XCTAssertTrue(RuleEngine.matches(rule: rule, samples: samples, calendarEventTitle: nil))
    }

    func test_urlContains_match() {
        let samples = [sample(bundleId: "com.apple.Safari", appName: "Safari", url: "https://acme.com/dashboard")]
        let customer = Customer(name: "Acme")
        let rule = ClassificationRule(
            name: "Acme URL",
            targetCustomer: customer,
            urlContains: "acme.com"
        )
        XCTAssertTrue(RuleEngine.matches(rule: rule, samples: samples, calendarEventTitle: nil))
    }

    func test_urlContains_noURLOnSample() {
        let samples = [sample(bundleId: "com.google.Chrome", appName: "Chrome", url: nil)]
        let customer = Customer(name: "Acme")
        let rule = ClassificationRule(name: "acme", targetCustomer: customer, urlContains: "acme")
        XCTAssertFalse(RuleEngine.matches(rule: rule, samples: samples, calendarEventTitle: nil))
    }

    func test_windowTitleContains_match() {
        let samples = [sample(bundleId: "com.microsoft.VSCode", appName: "Code", windowTitle: "project-X dashboard.py")]
        let project = Project(name: "Project X")
        let rule = ClassificationRule(
            name: "X windows",
            targetProject: project,
            windowTitleContains: "project-x"
        )
        XCTAssertTrue(RuleEngine.matches(rule: rule, samples: samples, calendarEventTitle: nil))
    }

    func test_calendarTitle_matchAndMiss() {
        let role = Role(name: "Meetings")
        let rule = ClassificationRule(
            name: "standups",
            targetRole: role,
            calendarTitleContains: "standup"
        )
        XCTAssertTrue(RuleEngine.matches(rule: rule, samples: [], calendarEventTitle: "Team standup"))
        XCTAssertFalse(RuleEngine.matches(rule: rule, samples: [], calendarEventTitle: nil))
        XCTAssertFalse(RuleEngine.matches(rule: rule, samples: [], calendarEventTitle: "Pilot sync"))
    }

    func test_ANDsemantics_requiresAllConditions() {
        let samples = [sample(bundleId: "com.apple.Safari", appName: "Safari", url: "https://beta.com")]
        let customer = Customer(name: "Acme")
        let rule = ClassificationRule(
            name: "Safari + acme",
            targetCustomer: customer,
            appBundleID: "com.apple.Safari",
            urlContains: "acme.com"
        )
        XCTAssertFalse(
            RuleEngine.matches(rule: rule, samples: samples, calendarEventTitle: nil),
            "Browser matches but URL doesn't — rule must NOT match"
        )
    }

    func test_emptyRule_neverMatches() {
        let role = Role(name: "SE")
        let rule = ClassificationRule(name: "empty", targetRole: role)
        XCTAssertFalse(
            RuleEngine.matches(rule: rule, samples: [sample(bundleId: "x", appName: "x")], calendarEventTitle: "hi")
        )
    }

    // MARK: - Evaluation & priority

    func test_firstMatchPerFieldWins_priorityDesc() {
        let se = Role(name: "SE")
        let da = Role(name: "Data Analyst")
        let ruleLow = ClassificationRule(
            name: "any Safari -> SE", priority: 1,
            targetRole: se,
            appBundleID: "com.apple.Safari"
        )
        let ruleHigh = ClassificationRule(
            name: "Safari + powerbi.com -> DA", priority: 10,
            targetRole: da,
            appBundleID: "com.apple.Safari",
            urlContains: "powerbi.com"
        )
        let samples = [
            sample(bundleId: "com.apple.Safari", appName: "Safari", url: "https://powerbi.com")
        ]
        let hints = RuleEngine.evaluate(
            rules: [ruleLow, ruleHigh],
            samples: samples,
            calendarEventTitle: nil
        )
        XCTAssertIdentical(hints.role, da, "Higher-priority rule should win")
    }

    func test_rulesCoverIndependentFields() {
        let da = Role(name: "DA")
        let acme = Customer(name: "Acme")
        let roleRule = ClassificationRule(name: "pbi", targetRole: da, appNameContains: "powerbi")
        let customerRule = ClassificationRule(name: "acme", targetCustomer: acme, urlContains: "acme")
        let samples = [
            sample(bundleId: "x", appName: "Microsoft PowerBI", url: "https://acme.com")
        ]
        let hints = RuleEngine.evaluate(
            rules: [roleRule, customerRule],
            samples: samples,
            calendarEventTitle: nil
        )
        XCTAssertIdentical(hints.role, da)
        XCTAssertIdentical(hints.customer, acme)
        XCTAssertNil(hints.project)
    }

    func test_disabledRuleIgnored() {
        let role = Role(name: "SE")
        let rule = ClassificationRule(
            name: "disabled",
            isEnabled: false,
            targetRole: role,
            appBundleID: "com.apple.Safari"
        )
        let samples = [sample(bundleId: "com.apple.Safari", appName: "Safari")]
        let hints = RuleEngine.evaluate(rules: [rule], samples: samples, calendarEventTitle: nil)
        XCTAssertNil(hints.role)
    }

    // MARK: - Helpers

    private func sample(
        bundleId: String,
        appName: String,
        windowTitle: String? = nil,
        url: String? = nil
    ) -> ActivitySample {
        ActivitySample(
            timestamp: now,
            bundleId: bundleId,
            appName: appName,
            windowTitle: windowTitle,
            url: url
        )
    }
}
