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

    init(path: String, kind: ConflictKind, thisMachine: Data?, otherMachine: Data?,
         thisUnavailable: UnavailableConflictSide? = nil, otherUnavailable: UnavailableConflictSide? = nil) {
        self.path = path
        self.kind = kind
        self.thisMachine = thisMachine
        self.otherMachine = otherMachine
        self.thisUnavailable = thisUnavailable
        self.otherUnavailable = otherUnavailable
    }
}

struct ConflictVersion {
    let bytes: Data?
    let unavailable: UnavailableConflictSide?

    init(read: () throws -> Data?) throws {
        do {
            bytes = try read()
            unavailable = nil
        } catch let entry as UnavailableConflictSide {
            bytes = nil
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

    init(side: ConflictSide, expectedThis: Data?, expectedOther: Data?,
         expectedThisUnavailable: UnavailableConflictSide? = nil,
         expectedOtherUnavailable: UnavailableConflictSide? = nil) {
        self.side = side
        self.expectedThis = expectedThis
        self.expectedOther = expectedOther
        self.expectedThisUnavailable = expectedThisUnavailable
        self.expectedOtherUnavailable = expectedOtherUnavailable
    }
}

/// Result of inspecting: real conflicts to show, or the conflict cleared itself upstream.
enum ConflictInspection: Equatable {
    case conflicts(ConflictSet)
    case cleared(SyncOutcome)
}
