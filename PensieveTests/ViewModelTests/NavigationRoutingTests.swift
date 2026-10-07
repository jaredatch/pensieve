import XCTest
@testable import Pensieve

final class NavigationRoutingTests: XCTestCase {
    func testContentRouteIsOnePerSection() {
        XCTAssertEqual(
            SidebarSection.allCases.map(contentColumn(for:)),
            [.skillList, .projectList, .categoryList, .tagList, .machineList]
        )
    }

    func testContentRouteForEachSectionIsDistinct() {
        let routes = SidebarSection.allCases.map(contentColumn(for:))

        for (index, route) in routes.enumerated() {
            for otherRoute in routes.dropFirst(index + 1) {
                XCTAssertNotEqual(route, otherRoute)
            }
        }
    }

    func testSidebarSectionAllCasesHasFiveMembers() {
        XCTAssertEqual(SidebarSection.allCases.count, 5)
    }

    func testDetailRouteForMultipleSkillsShowsBulk() {
        XCTAssertEqual(
            detailColumn(for: .skills, entity: nil, selectedSkillCount: 2, skillsEmpty: false),
            .bulk
        )
    }

    func testDetailRouteForSingleSkillShowsSkill() {
        XCTAssertEqual(
            detailColumn(for: .skills, entity: nil, selectedSkillCount: 1, skillsEmpty: false),
            .skill
        )
    }

    func testDetailRouteForEmptyLibraryShowsNoSkills() {
        XCTAssertEqual(
            detailColumn(for: .skills, entity: nil, selectedSkillCount: 0, skillsEmpty: true),
            .emptyNoSkills
        )
    }

    func testDetailRouteForNoSelectionShowsPrompt() {
        XCTAssertEqual(
            detailColumn(for: .skills, entity: nil, selectedSkillCount: 0, skillsEmpty: false),
            .selectSkillPrompt
        )
    }

    func testPrunedEntitySelectionDropsVanishedTag() {
        XCTAssertNil(
            prunedEntitySelection(
                .tag("swift"), projectIDs: [], categoryIDs: [],
                machineIDs: [], tags: [], remoteProjectKeys: []
            )
        )
    }

    func testClearsSkillSelectionWhenLeavingSkills() {
        XCTAssertTrue(clearsSkillSelection(movingFrom: .skills, to: .projects))
    }

    func testDoesNotClearSkillSelectionWhenArrivingAtSkills() {
        XCTAssertFalse(clearsSkillSelection(movingFrom: .projects, to: .skills))
    }

    func testDetailRouteForSkillsSectionMatchesLegacyOrdering() {
        XCTAssertEqual(
            detailColumn(for: .skills, entity: nil, selectedSkillCount: 2, skillsEmpty: true),
            .bulk
        )
        XCTAssertEqual(
            detailColumn(for: .skills, entity: nil, selectedSkillCount: 1, skillsEmpty: true),
            .skill
        )
        XCTAssertEqual(
            detailColumn(for: .skills, entity: nil, selectedSkillCount: 0, skillsEmpty: true),
            .emptyNoSkills
        )
        XCTAssertEqual(
            detailColumn(for: .skills, entity: nil, selectedSkillCount: 0, skillsEmpty: false),
            .selectSkillPrompt
        )
    }

    func testDetailRouteIgnoresEntityFromAnotherSection() {
        XCTAssertEqual(
            detailColumn(
                for: .categories, entity: .project(UUID()),
                selectedSkillCount: 0, skillsEmpty: false
            ),
            .selectEntityPrompt(.categories)
        )
    }

    func testDetailRouteWithNoEntityPromptsForThatSection() {
        XCTAssertEqual(
            detailColumn(for: .tags, entity: nil, selectedSkillCount: 0, skillsEmpty: false),
            .selectEntityPrompt(.tags)
        )
    }

    func testDetailRouteForEachEntitySectionRoutesToItsEntity() {
        let projectID = UUID()
        let categoryID = UUID()

        XCTAssertEqual(
            detailColumn(
                for: .projects, entity: .project(projectID),
                selectedSkillCount: 0, skillsEmpty: false
            ),
            .project(projectID)
        )
        XCTAssertEqual(
            detailColumn(
                for: .categories, entity: .category(categoryID),
                selectedSkillCount: 0, skillsEmpty: false
            ),
            .category(categoryID)
        )
        XCTAssertEqual(
            detailColumn(
                for: .machines, entity: .machine("mac-mini"),
                selectedSkillCount: 0, skillsEmpty: false
            ),
            .machine("mac-mini")
        )
        XCTAssertEqual(
            detailColumn(
                for: .tags, entity: .tag("swift"),
                selectedSkillCount: 0, skillsEmpty: false
            ),
            .tag("swift")
        )
    }

    func testSkillsSectionIgnoresStaleEntitySelection() {
        XCTAssertEqual(
            detailColumn(
                for: .skills, entity: .project(UUID()),
                selectedSkillCount: 1, skillsEmpty: false
            ),
            .skill
        )
    }

    func testEntitySectionIgnoresStaleSkillMultiSelect() {
        let id = UUID()

        XCTAssertEqual(
            detailColumn(
                for: .projects, entity: .project(id),
                selectedSkillCount: 3, skillsEmpty: false
            ),
            .project(id)
        )
    }

    func testEntitySelectionSectionMappingIsTotal() {
        let selections: [EntitySelection] = [
            .project(UUID()), .category(UUID()),
            .machine("mac-mini"), .tag("swift")
        ]
        let mappedSections = Set(selections.map(\.section))

        for section in SidebarSection.allCases where section != .skills {
            XCTAssertTrue(mappedSections.contains(section))
        }
    }

    func testPrunedEntitySelectionDropsDeletedEntity() {
        let selections: [EntitySelection] = [
            .project(UUID()), .category(UUID()),
            .machine("mac-mini"), .tag("swift")
        ]

        for selection in selections {
            XCTAssertNil(
                prunedEntitySelection(
                    selection, projectIDs: [], categoryIDs: [],
                    machineIDs: [], tags: [], remoteProjectKeys: []
                )
            )
        }
    }

    func testPrunedEntitySelectionKeepsLiveEntity() {
        let projectID = UUID()
        let categoryID = UUID()
        let selections: [EntitySelection] = [
            .project(projectID), .category(categoryID),
            .machine("mac-mini"), .tag("swift")
        ]

        for selection in selections {
            XCTAssertEqual(
                prunedEntitySelection(
                    selection, projectIDs: [projectID], categoryIDs: [categoryID],
                    machineIDs: ["mac-mini"], tags: ["swift"], remoteProjectKeys: []
                ),
                selection
            )
        }
    }

    func testSelectionAfterCreatingSelectsMatchingEntityAndClearsSearch() {
        let created: [(SidebarSection, EntitySelection)] = [
            (.projects, .project(UUID())),
            (.categories, .category(UUID()))
        ]

        for (section, selection) in created {
            var current: EntitySelection? = .tag("previous")
            var searchText = "Old"

            selectionAfterCreating(
                selection, in: section, entity: &current, searchText: &searchText
            )

            XCTAssertEqual(current, selection)
            XCTAssertTrue(searchText.isEmpty)
        }
    }

    func testSelectionAfterCreatingKeepsSelectionAndSearchForSectionMismatch() {
        let original = EntitySelection.category(UUID())
        var current: EntitySelection? = original
        var searchText = "Old"

        selectionAfterCreating(
            .project(UUID()), in: .skills, entity: &current, searchText: &searchText
        )

        XCTAssertEqual(current, original)
        XCTAssertEqual(searchText, "Old")
    }

    func testSelectionAfterCreatingKeepsSelectionAndSearchWithoutCreatedEntity() {
        let original = EntitySelection.category(UUID())
        var current: EntitySelection? = original
        var searchText = "Old"

        selectionAfterCreating(
            nil, in: .categories, entity: &current, searchText: &searchText
        )

        XCTAssertEqual(current, original)
        XCTAssertEqual(searchText, "Old")
    }

    func testAvailableSectionFallsBackWhenMachinesHidden() {
        XCTAssertEqual(availableSection(.machines, showsMachines: false), .skills)
    }

    func testAvailableSectionKeepsMachinesWhenShown() {
        XCTAssertEqual(availableSection(.machines, showsMachines: true), .machines)
    }
}

extension NavigationRoutingTests {
    func testRemoteProjectRoutesByIdentityKeyOnlyInProjects() {
        let selection = EntitySelection.remoteProject(RemoteProjectTestSupport.key)
        XCTAssertEqual(detailColumn(for: .projects, entity: selection, selectedSkillCount: 0, skillsEmpty: false),
                       .remoteProject(RemoteProjectTestSupport.key))
        XCTAssertEqual(detailColumn(for: .categories, entity: selection, selectedSkillCount: 0, skillsEmpty: false),
                       .selectEntityPrompt(.categories))
    }

    func testRemoteSelectionPrunesAfterUnpublishOrLocalRegistration() {
        let key = RemoteProjectTestSupport.key
        let first = RemoteProjectTestSupport.machine()
        let second = RemoteProjectTestSupport.machine(id: "second")
        let local = Project(name: "Registered now", path: "/local")
        local.identityKey = key
        let cases: [(([MachineState], [Project]), EntitySelection?)] = [
            (([first, second], []), .remoteProject(key)),
            (([second], []), .remoteProject(key)),
            (([], []), nil),
            (([first, second], [local]), nil)
        ]
        for ((states, projects), expected) in cases {
            let remote = RemoteProjectModel.onlyOnOtherMacs(
                states: states, localProjectIdentityKeys: Set(projects.compactMap(\.identityKey)),
                localMachineID: InertMachineIdentity.value
            )
            let selection = prunedEntitySelection(
                .remoteProject(key), projectIDs: Set(projects.map(\.id)), categoryIDs: [], machineIDs: [], tags: [],
                remoteProjectKeys: Set(remote.map(\.identityKey))
            )
            XCTAssertEqual(selection, expected)
            if expected == nil {
                XCTAssertEqual(detailColumn(for: .projects, entity: selection, selectedSkillCount: 0, skillsEmpty: false),
                               .selectEntityPrompt(.projects))
            }
        }
    }

    func testRevealSkillSwitchesToSkillsSection() {
        let skill = Skill(name: "Reveal", directoryName: "reveal")
        var section = SidebarSection.projects
        var entity: EntitySelection? = .project(UUID())
        var selectedSkills: Set<Skill> = []
        var filter = SkillListFilter()
        var searchText = ""

        revealSkill(
            skill, section: &section, entity: &entity,
            selectedSkills: &selectedSkills, filter: &filter, searchText: &searchText
        )

        XCTAssertEqual(section, .skills)
    }

    func testRevealSkillClearsEntitySelection() {
        let skill = Skill(name: "Reveal", directoryName: "reveal")
        var section = SidebarSection.categories
        var entity: EntitySelection? = .category(UUID())
        var selectedSkills: Set<Skill> = []
        var filter = SkillListFilter()
        var searchText = ""

        revealSkill(
            skill, section: &section, entity: &entity,
            selectedSkills: &selectedSkills, filter: &filter, searchText: &searchText
        )

        XCTAssertNil(entity)
    }

    func testRevealSkillReplacesMultiSelectionWithOneSkill() {
        let skill = Skill(name: "Reveal", directoryName: "reveal")
        let other = Skill(name: "Other", directoryName: "other")
        var section = SidebarSection.tags
        var entity: EntitySelection? = .tag("swift")
        var selectedSkills: Set<Skill> = [other, skill]
        var filter = SkillListFilter()
        var searchText = ""

        revealSkill(
            skill, section: &section, entity: &entity,
            selectedSkills: &selectedSkills, filter: &filter, searchText: &searchText
        )

        XCTAssertEqual(selectedSkills, [skill])
    }

    func testRevealSkillSurvivesTheSectionChangeClearingRule() {
        let skill = Skill(name: "Reveal", directoryName: "reveal")
        let oldSection = SidebarSection.categories
        var section = oldSection
        var entity: EntitySelection? = .category(UUID())
        var selectedSkills: Set<Skill> = []
        var filter = SkillListFilter()
        var searchText = ""

        revealSkill(
            skill, section: &section, entity: &entity,
            selectedSkills: &selectedSkills, filter: &filter, searchText: &searchText
        )
        if clearsSkillSelection(movingFrom: oldSection, to: section) {
            selectedSkills = []
        }

        XCTAssertEqual(selectedSkills, [skill])
    }

    func testRevealSkillClearsListFilterSoTheSkillIsListed() {
        let skill = Skill(name: "Reveal", directoryName: "reveal")
        var section = SidebarSection.machines
        var entity: EntitySelection? = .machine("mac-mini")
        var selectedSkills: Set<Skill> = []
        var filter = SkillListFilter(source: .gitHub, tags: ["x"])
        var searchText = "zzz"

        revealSkill(
            skill, section: &section, entity: &entity,
            selectedSkills: &selectedSkills, filter: &filter, searchText: &searchText
        )

        XCTAssertEqual(filter, SkillListFilter())
        XCTAssertFalse(filter.isActive)
        XCTAssertTrue(searchText.isEmpty)
    }
}
