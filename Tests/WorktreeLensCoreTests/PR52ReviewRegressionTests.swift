import XCTest
@testable import WorktreeLensCore

final class PR52ReviewRegressionTests: XCTestCase {
    func testAutomaticRefreshDiscoversNewPRWithoutLocalSHAChange() async throws {
        let transport = DisplayScriptTransport { request, count in
            if request.url?.path != "/graphql" {
                return GitHubHTTPResponse(data: Data(#"{"total_count":0,"workflow_runs":[]}"#.utf8), status: 200)
            }
            let query = try displayQuery(request)
            if query.contains("pullRequests(") {
                var opened = displayPR(number: 201)
                opened["state"] = "OPEN"
                opened["mergedAt"] = NSNull()
                return try displayResponse(["b0": displayRepo(["pullRequests": displayPage(count == 1 ? [] : [opened])])])
            }
            var detailed = displayPR(number: 201)
            detailed["closingIssuesReferences"] = displayPage([])
            return try displayResponse([
                "i0": displayRepo(["pullRequest": detailed]),
                "ci": displayRepo(["object": ["oid": "local-sha", "statusCheckRollup": ["contexts": displayPage([])]]])
            ])
        }
        let github = GitHubService(api: displayAPI(transport, stateStore: GitHubStateStore()),
            resolver: GitHubRepositoryResolver(runner: DisplayConfigRunner(config: "remote.origin.url=https://github.com/example/repo.git")))
        let branch = displayBranch()
        let summaries = await github.summariesAsync(repositoryPath: "/fixture", branches: [branch])
        let summary = try XCTUnwrap(summaries[branch.id])
        XCTAssertTrue(summary.pullRequests.isEmpty)

        let refreshed = await github.refreshStatusAsync(repositoryPath: "/fixture", branchInfo: branch.withGitHubStatus(summary))
        XCTAssertEqual(refreshed.pullRequests.map(\.number), [201], "Automatic polling must discover a newly opened PR at the same SHA")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4)
    }

    func testSameSHAReplacementPRMustBeRediscovered() async throws {
        let transport = DisplayScriptTransport { request, _ in
            let query = try displayQuery(request)
            if query.contains("pullRequest(number: 201)") {
                var old = displayPR()
                old["state"] = "CLOSED"; old["mergedAt"] = NSNull()
                return try displayResponse(["k0": displayRepo(["pullRequest": old])])
            }
            return try displayResponse(["b0": displayRepo(["pullRequests": displayPage([displayPR(number: 202)])])])
        }
        let result = await GitHubDisplayService(api: displayAPI(transport)).summaries(targets: [displayTarget(known: [201])])
        let status = try XCTUnwrap(result["feature"])
        let requests = await transport.requests
        XCTAssertTrue(status.pullRequests.contains { $0.number == 202 }, "A closed old PR with identical SHA must not suppress discovery of its replacement")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(status.pullRequests.map(\.number), [201, 202])
        XCTAssertTrue(status.pullRequestFetch.isComplete)
        XCTAssertEqual(status.verifiedMergedPullRequest(defaultBranch: "main", branchName: "feature", localSHA: "local-sha")?.number, 202)
    }
    func testNullableConnectionNodesPreserveOtherAliasSuccess() async throws {
        let transport = DisplayScriptTransport { _, _ in
            try displayResponse([
                "b0": displayRepo(["pullRequests": displayPage([displayPR()])]),
                "b1": displayRepo(["pullRequests": ["nodes": NSNull(), "pageInfo": ["hasNextPage": false, "endCursor": NSNull()]]])
            ], errors: [["type": "INTERNAL", "path": ["b1", "pullRequests", "nodes"]]])
        }
        let result = await GitHubDisplayService(api: displayAPI(transport)).summaries(targets: [displayTarget(), displayTarget("other")])
        let good = try XCTUnwrap(result["feature"])
        XCTAssertEqual(good.pullRequests.map(\.number), [201], "Nullable nodes on a failed alias must not discard another alias's valid data")
        XCTAssertTrue(good.pullRequestFetch.isComplete)
        let incomplete = try XCTUnwrap(result["other"])
        XCTAssertEqual(incomplete.pullRequestFetch.phase, .incomplete)
        XCTAssertFalse(incomplete.mergeEvidenceLoaded)
        XCTAssertNotNil(incomplete.pullRequestFetch.error)
    }

    func testNullableIssueNodesKeepPRMetadataAndSuccessfulChecks() async throws {
        try await assertNullableDetailConnection(issuesNull: true)
    }

    func testNullableCheckNodesKeepPRMetadataAndSuccessfulIssues() async throws {
        try await assertNullableDetailConnection(issuesNull: false)
    }

    private func assertNullableDetailConnection(issuesNull: Bool) async throws {
        let transport = DisplayScriptTransport { request, index in
            if index == 1 {
                return try displayResponse(["b0": displayRepo(["pullRequests": displayPage([displayPR()])])])
            }
            if request.url?.path != "/graphql" {
                return try GitHubHTTPResponse(data: JSONSerialization.data(withJSONObject: ["total_count": 0, "workflow_runs": []]), status: 200)
            }
            let nullPage: [String: Any] = ["nodes": NSNull(), "pageInfo": ["hasNextPage": false, "endCursor": NSNull()]]
            let issue: [String: Any] = ["id": "issue-7", "number": 7, "title": "Linked", "state": "OPEN", "url": "https://github.com/example/repo/issues/7", "repository": ["id": "BASE", "nameWithOwner": "example/repo"]]
            let check: [String: Any] = ["__typename": "CheckRun", "id": "check", "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS"]
            var pr = displayPR()
            pr["mergeStateStatus"] = "CLEAN"
            pr["closingIssuesReferences"] = issuesNull ? nullPage : displayPage([issue])
            let checkPage = issuesNull ? displayPage([check]) : nullPage
            let path = issuesNull ? ["i0", "pullRequest", "closingIssuesReferences", "nodes"] : ["ci", "object", "statusCheckRollup", "contexts", "nodes"]
            return try displayResponse(["i0": displayRepo(["pullRequest": pr]), "ci": displayRepo(["object": ["oid": "local-sha", "statusCheckRollup": ["contexts": checkPage]]])], errors: [["type": "INTERNAL", "path": path]])
        }
        let service = GitHubDisplayService(api: displayAPI(transport))
        let summaries = await service.summaries(targets: [displayTarget()])
        let status = await service.details(target: displayTarget(), summary: try XCTUnwrap(summaries["feature"]))
        XCTAssertEqual(status.pullRequests.map(\.number), [201])
        XCTAssertEqual(status.pullRequests.first?.mergeStateStatus, "CLEAN")
        XCTAssertTrue(status.pullRequestFetch.isComplete)
        XCTAssertTrue(status.actionFetch.isComplete)
        XCTAssertEqual(status.issueFetch.phase, issuesNull ? .incomplete : .loaded)
        XCTAssertEqual(status.checkFetch.phase, issuesNull ? .loaded : .incomplete)
        XCTAssertEqual(status.issues.count, issuesNull ? 0 : 1)
        XCTAssertEqual(status.checks.count, issuesNull ? 1 : 0)
    }

    func testClosedSameSHADiscoveryCutoffRemainsIncomplete() async throws {
        let transport = DisplayScriptTransport { _, _ in
            var old = displayPR(); old["state"] = "CLOSED"; old["mergedAt"] = NSNull()
            return try displayResponse(["k0": displayRepo(["pullRequest": old])])
        }
        var limits = GitHubDisplayLimits(); limits.maxRequests = 1
        let result = await GitHubDisplayService(api: displayAPI(transport), limits: limits).summaries(targets: [displayTarget(known: [201])])
        let status = try XCTUnwrap(result["feature"])
        XCTAssertEqual(status.pullRequests.map(\.number), [201])
        XCTAssertEqual(status.pullRequestFetch.phase, .incomplete)
        XCTAssertFalse(status.mergeEvidenceLoaded)
    }

    func testRediscoveredSameSHAPRIncludesReplacementClosingIssues() async throws {
        let transport = DisplayScriptTransport { request, index in
            if index == 1 {
                var old = displayPR(); old["state"] = "CLOSED"; old["mergedAt"] = NSNull()
                return try displayResponse(["k0": displayRepo(["pullRequest": old])])
            }
            if index == 2 { return try displayResponse(["b0": displayRepo(["pullRequests": displayPage([displayPR(number: 202)])])]) }
            if request.url?.path != "/graphql" {
                return try GitHubHTTPResponse(data: JSONSerialization.data(withJSONObject: ["total_count": 0, "workflow_runs": []]), status: 200)
            }
            XCTAssertTrue(try displayQuery(request).contains("pullRequest(number: 202)"))
            var old = displayPR(); old["state"] = "CLOSED"; old["mergedAt"] = NSNull(); old["closingIssuesReferences"] = displayPage([])
            var replacement = displayPR(number: 202)
            replacement["state"] = "OPEN"; replacement["mergedAt"] = NSNull()
            let issue: [String: Any] = ["id": "replacement-issue", "number": 8, "title": "Replacement", "state": "OPEN", "url": "https://github.com/example/repo/issues/8", "repository": ["id": "BASE", "nameWithOwner": "example/repo"]]
            replacement["closingIssuesReferences"] = displayPage([issue])
            return try displayResponse(["i0": displayRepo(["pullRequest": old]), "i1": displayRepo(["pullRequest": replacement]), "ci": displayRepo(["object": ["oid": "local-sha", "statusCheckRollup": NSNull()]])])
        }
        let service = GitHubDisplayService(api: displayAPI(transport))
        let summaries = await service.summaries(targets: [displayTarget(known: [201])])
        let status = await service.details(target: displayTarget(known: [201]), summary: try XCTUnwrap(summaries["feature"]))
        XCTAssertEqual(status.pullRequests.map(\.number), [201, 202])
        XCTAssertEqual(status.issues.map(\.number), [8])
        XCTAssertTrue(status.issueFetch.isComplete)
    }


    func testNullNodesWithoutGraphQLErrorRemainIncomplete() async throws {
        let transport = DisplayScriptTransport { _, _ in
            try displayResponse([
                "b0": displayRepo(["pullRequests": displayPage([displayPR()])]),
                "b1": displayRepo(["pullRequests": ["nodes": NSNull(), "pageInfo": ["hasNextPage": false, "endCursor": NSNull()]]])
            ])
        }
        let result = await GitHubDisplayService(api: displayAPI(transport)).summaries(targets: [displayTarget(), displayTarget("other")])
        XCTAssertTrue(try XCTUnwrap(result["feature"]).pullRequestFetch.isComplete)
        XCTAssertEqual(result["other"]?.pullRequestFetch.phase, .incomplete)
        XCTAssertFalse(try XCTUnwrap(result["other"]).mergeEvidenceLoaded)
    }

}
