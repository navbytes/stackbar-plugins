import Foundation
import XCTest
@testable import Plugin_PRCockpit

/// Why pull requests go missing from GitHub's search, and the repositories
/// PR Cockpit reads by name instead. Nothing here reaches GitHub.
final class PRCockpitCoverageTests: XCTestCase {
    private func pull(_ json: String) throws -> PRCockpit.WatchedPull {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PRCockpit.WatchedPull.self, from: Data(json.utf8))
    }

    private func pullJSON(author: String, reviewers: [String]) -> String {
        #"{"number":7,"title":"Fix login","url":"https://github.com/o/w/pull/7","isDraft":false,"updatedAt":"2026-11-01T00:00:00Z","#
            + #""repository":{"nameWithOwner":"o/w"},"author":{"login":"\#(author)"},"headRefName":"fix-login","#
            + #""reviewRequests":{"nodes":["# + reviewers.map { #"{"requestedReviewer":\#($0)}"# }.joined(separator: ",") + "]}}"
    }

    func testTheSingleSignOnHeaderNamesTheHiddenOrganizations() {
        XCTAssertEqual(PRCockpit.ssoHiddenOrganizations("partial-results; organizations=21955855,20582480"), [21955855, 20582480])
        XCTAssertEqual(PRCockpit.ssoHiddenOrganizations("required; url=https://github.com/orgs/o/sso?authorization_request=x"), [])
        XCTAssertEqual(PRCockpit.ssoHiddenOrganizations(nil), [])
        XCTAssertEqual(PRCockpit.header("x-github-sso", in: ["X-GitHub-SSO": "a"]), "a")
    }

    func testARepositoryCanBeTypedAsANameOrALink() {
        XCTAssertEqual(PRCockpit.repoName("navbytes/stackbar"), "navbytes/stackbar")
        XCTAssertEqual(PRCockpit.repoName(" https://github.com/navbytes/stackbar/pull/12 "), "navbytes/stackbar")
        XCTAssertEqual(PRCockpit.repoName("github.com/o/my.repo.git"), "o/my.repo")
        XCTAssertEqual(PRCockpit.repoName("o/w#12"), "o/w")
        XCTAssertNil(PRCockpit.repoName("stackbar"))
        XCTAssertNil(PRCockpit.repoName("o/w\") { x }"))
    }

    func testAWatchedPullRequestGoesOnTheRightList() throws {
        let teams: Set<String> = ["o/web"]
        XCTAssertEqual(PRCockpit.place(try pull(pullJSON(author: "Me", reviewers: [])), viewer: "me", teams: teams, includeTeams: true), .mine)
        XCTAssertEqual(PRCockpit.place(try pull(pullJSON(author: "a", reviewers: [#"{"login":"ME"}"#])), viewer: "me", teams: teams, includeTeams: true), .review)
        let team = try pull(pullJSON(author: "a", reviewers: [#"{"combinedSlug":"O/web"}"#]))
        XCTAssertEqual(PRCockpit.place(team, viewer: "me", teams: teams, includeTeams: true), .review)
        XCTAssertNil(PRCockpit.place(team, viewer: "me", teams: teams, includeTeams: false), "team requests are a setting")
        XCTAssertNil(PRCockpit.place(try pull(pullJSON(author: "a", reviewers: [#"{"login":"someone"}"#, "{}"])), viewer: "me", teams: teams, includeTeams: true))
    }

    func testTheWatchedQueryAsksForEachRepositoryByName() {
        let query = PRCockpit.watchedQuery(["o/w", "acme/api"])
        XCTAssertTrue(query.contains(#"r0: repository(owner: "o", name: "w")"#), query)
        XCTAssertTrue(query.contains(#"r1: repository(owner: "acme", name: "api")"#), query)
        XCTAssertTrue(query.contains("viewer { login }"))
        XCTAssertTrue(query.contains("fragment pr on PullRequest"))
    }

    func testARefusedRepositoryKeepsItsReason() throws {
        let json = #"{"data":{"viewer":{"login":"me"},"r0":{"pullRequests":{"nodes":[]}},"r1":null},"#
            + #""errors":[{"type":"FORBIDDEN","path":["r1"],"locations":[{"line":1,"column":2}],"message":"Although you appear to have the correct authorization credentials, the `acme` organization has enabled OAuth App access restrictions"}]}"#
        let reply = try JSONDecoder().decode(PRCockpit.WatchedReply.self, from: Data(json.utf8))
        XCTAssertEqual(reply.viewer, "me")
        XCTAssertEqual(Set(reply.repositories.keys), ["r0"])
        XCTAssertEqual(reply.errors.first?.alias, "r1")
        let why = PRCockpit.watchedProblem(reply.errors[0].message, org: "acme", gh: true)
        XCTAssertTrue(why.contains("hasn't approved the GitHub CLI app"), why)
        XCTAssertTrue(PRCockpit.watchedProblem("Resource protected by organization SAML enforcement.", org: "acme", gh: false).contains("Configure SSO"))
        XCTAssertTrue(PRCockpit.watchedProblem("Could not resolve to a Repository with the name 'acme/api'.", org: "acme", gh: false).contains("resource owner"))
    }

    func testTheTokenKindComesFromItsPrefix() {
        XCTAssertEqual(PRCockpit.tokenKind("github_pat_11AB"), "fine-grained")
        XCTAssertEqual(PRCockpit.tokenKind("ghp_x"), "classic")
        XCTAssertEqual(PRCockpit.tokenKind("gho_x"), "oauth")
    }

    func testPaletteSearchMatchesEveryWordAcrossTitleRepositoryAndBranch() throws {
        let pr = try pull(pullJSON(author: "dana", reviewers: [])).pr
        XCTAssertTrue(PRCockpit.matches(pr, "login o/w"))
        XCTAssertTrue(PRCockpit.matches(pr, "#7"))
        XCTAssertTrue(PRCockpit.matches(pr, "fix-login dana"))
        XCTAssertFalse(PRCockpit.matches(pr, "login signup"))
        XCTAssertEqual(PRCockpit.merged([pr], [pr]).count, 1)
    }

    func testATabIsFoundByItsName() {
        let tabs: [PRCockpit.Tab] = [.review, .mine, .issues]
        XCTAssertEqual(PRCockpit.tab(for: "Mine", in: tabs), .mine)
        XCTAssertEqual(PRCockpit.tab(for: "Issues", in: tabs), .issues)
        XCTAssertNil(PRCockpit.tab(for: "Inbox", in: tabs), "not shown without the inbox")
    }

    func testAFailedRequestSaysWhatHappensNext() {
        struct Failure: Error, CustomStringConvertible { let description: String }
        XCTAssertTrue(PRCockpit.explained(Failure(description: "The request timed out."), what: "your issues").contains("didn't send your issues within 20 seconds"))
        XCTAssertTrue(PRCockpit.explained(Failure(description: "The Internet connection appears to be offline."), what: "x").contains("looks offline"))
        XCTAssertEqual(PRCockpit.explained(Failure(description: "GitHub answered 502"), what: "x"), "GitHub answered 502")
        XCTAssertEqual(PRCockpit.listed(["pull requests", "issues", "inbox"]), "pull requests, issues and inbox")
        XCTAssertEqual(PRCockpit.listed(["issues"]), "issues")
    }
}
