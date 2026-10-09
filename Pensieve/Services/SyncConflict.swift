import Foundation

enum ConflictSide: Equatable {
    case thisMachine
    case otherMachine
}

enum ConflictKind: Equatable {
    case body
    case overlay
    case category
    case project
}

/// One conflicted path with both sides' blobs. `thisMachine` = git stage 3 (the replayed local
/// commit - THIS machine); `otherMachine` = git stage 2 (origin/main - the OTHER machine).
/// nil without an unavailable receipt = absent, DISTINCT from empty data or an unreadable entry.
struct ConflictItem: Equatable {
    let path: String
    let kind: ConflictKind
    let thisMachine: Data?
    let otherMachine: Data?
    let thisUnavailable: UnavailableConflictSide?
    let otherUnavailable: UnavailableConflictSide?
    let thisMode: String?
    let otherMode: String?
    var retiresGitlink: Bool { thisUnavailable?.mode == "160000" || otherUnavailable?.mode == "160000" }

    init(path: String, kind: ConflictKind, thisMachine: Data?, otherMachine: Data?,
         thisUnavailable: UnavailableConflictSide? = nil, otherUnavailable: UnavailableConflictSide? = nil,
         thisMode: String? = nil, otherMode: String? = nil) {
        self.path = path
        self.kind = kind
        self.thisMachine = thisMachine
        self.otherMachine = otherMachine
        self.thisUnavailable = thisUnavailable
        self.otherUnavailable = otherUnavailable
        self.thisMode = thisMode ?? thisUnavailable?.mode ?? (thisMachine == nil ? nil : "100644")
        self.otherMode = otherMode ?? otherUnavailable?.mode ?? (otherMachine == nil ? nil : "100644")
    }
}

struct ConflictVersion {
    let entry: ConflictEntry?
    var bytes: Data? { entry?.bytes }
    var mode: String? { entry?.mode ?? unavailable?.mode }
    let unavailable: UnavailableConflictSide?

    init(read: () throws -> ConflictEntry?) throws {
        do {
            entry = try read()
            unavailable = nil
        } catch let entry as UnavailableConflictSide {
            self.entry = nil
            unavailable = entry
        }
    }
}

struct ConflictSet: Equatable {
    let items: [ConflictItem]
}

/// The user's choice for one conflicted path, carrying the blobs they SAW so resolve can prove the
/// world didn't move under the choice. Single unified payload type.
struct ResolutionPick: Equatable {
    let side: ConflictSide
    let expectedThis: Data?
    let expectedOther: Data?
    let expectedThisUnavailable: UnavailableConflictSide?
    let expectedOtherUnavailable: UnavailableConflictSide?
    let expectedThisMode: String?
    let expectedOtherMode: String?

    init(side: ConflictSide, expectedThis: Data?, expectedOther: Data?,
         expectedThisUnavailable: UnavailableConflictSide? = nil,
         expectedOtherUnavailable: UnavailableConflictSide? = nil,
         expectedThisMode: String? = nil, expectedOtherMode: String? = nil) {
        self.side = side
        self.expectedThis = expectedThis
        self.expectedOther = expectedOther
        self.expectedThisUnavailable = expectedThisUnavailable
        self.expectedOtherUnavailable = expectedOtherUnavailable
        self.expectedThisMode = expectedThisMode ?? expectedThisUnavailable?.mode ?? (expectedThis == nil ? nil : "100644")
        self.expectedOtherMode = expectedOtherMode ?? expectedOtherUnavailable?.mode ?? (expectedOther == nil ? nil : "100644")
    }
}

/// Result of inspecting: real conflicts to show, or the conflict cleared itself upstream.
enum ConflictInspection: Equatable {
    case conflicts(ConflictSet)
    case cleared(SyncOutcome)
}
