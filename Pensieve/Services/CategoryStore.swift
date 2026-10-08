import Foundation
import os
import SwiftData

// MARK: - Protocol

/// Pure CRUD over `Category` rules and the `SkillProjectAssignment` ledger. Category mutations also
/// regenerate the manifest overlay; platform fan-out remains the reconciler's job.
protocol CategoryStoreProtocol {
    var notifier: SyncStateNotifying { get }
    func create(name: String, context: ModelContext, notifier: SyncStateNotifying) -> Category?
    func rename(_ category: Category, to name: String, context: ModelContext, notifier: SyncStateNotifying)
    func delete(_ category: Category, context: ModelContext, notifier: SyncStateNotifying)
    @discardableResult
    func delete(_ category: Category, reconciler: CategoryReconcilerProtocol, context: ModelContext,
                notifier: SyncStateNotifying) -> BatchResult
    func setProject(_ project: Project, inCategory category: Category, member: Bool, context: ModelContext,
                    notifier: SyncStateNotifying)
    @discardableResult
    func setProject(_ project: Project, inCategory category: Category, member: Bool,
                    reconciler: CategoryReconcilerProtocol, context: ModelContext,
                    notifier: SyncStateNotifying) -> BatchResult
    func setSkill(_ skill: Skill, inCategory category: Category, assigned: Bool, context: ModelContext,
                  notifier: SyncStateNotifying)
    @discardableResult
    func setSkill(_ skill: Skill, inCategory category: Category, assigned: Bool,
                  reconciler: CategoryReconcilerProtocol, context: ModelContext,
                  notifier: SyncStateNotifying) -> BatchResult
    func categories(containingProjectKey key: String, context: ModelContext) -> [Category]
    func categories(containingSkillSlug slug: String, context: ModelContext) -> [Category]

}

extension CategoryStoreProtocol {
    var notifier: SyncStateNotifying { SyncStateNotifier.suppressed }
    func create(name: String, context: ModelContext) -> Category? {
        create(name: name, context: context, notifier: notifier)
    }
    func rename(_ category: Category, to name: String, context: ModelContext) {
        rename(category, to: name, context: context, notifier: notifier)
    }
    func delete(_ category: Category, context: ModelContext) {
        delete(category, context: context, notifier: notifier)
    }
    func delete(_ category: Category, reconciler: CategoryReconcilerProtocol,
                context: ModelContext) -> BatchResult {
        delete(category, reconciler: reconciler, context: context, notifier: notifier)
    }
    func setProject(_ project: Project, inCategory category: Category, member: Bool, context: ModelContext) {
        setProject(project, inCategory: category, member: member, context: context, notifier: notifier)
    }
    func setProject(_ project: Project, inCategory category: Category, member: Bool,
                    reconciler: CategoryReconcilerProtocol, context: ModelContext) -> BatchResult {
        setProject(project, inCategory: category, member: member, reconciler: reconciler,
                   context: context, notifier: notifier)
    }
    func setSkill(_ skill: Skill, inCategory category: Category, assigned: Bool, context: ModelContext) {
        setSkill(skill, inCategory: category, assigned: assigned, context: context, notifier: notifier)
    }
    func setSkill(_ skill: Skill, inCategory category: Category, assigned: Bool,
                  reconciler: CategoryReconcilerProtocol, context: ModelContext) -> BatchResult {
        setSkill(skill, inCategory: category, assigned: assigned, reconciler: reconciler,
                 context: context, notifier: notifier)
    }

}

// MARK: - Implementation

struct CategoryStore: CategoryStoreProtocol {
    private let manifestService: ManifestSnapshotting?
    private let manifestRoot: String
    let notifier: SyncStateNotifying

    init(manifestService: ManifestSnapshotting? = nil, manifestRoot: String,
         notifier: @escaping SyncStateNotifying = SyncStateNotifier.suppressed) {
        self.manifestService = manifestService
        self.manifestRoot = manifestRoot
        self.notifier = notifier
    }

    func create(name: String, context: ModelContext, notifier: SyncStateNotifying) -> Category? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let category = Category(name: trimmed)
        context.insert(category)
        try? context.save()
        regenerateManifest(context: context)
        notifier()
        return category
    }

    func rename(_ category: Category, to name: String, context: ModelContext, notifier: SyncStateNotifying) {
        category.name = name
        try? context.save()
        regenerateManifest(context: context)
        notifier()
    }

    func delete(_ category: Category, context: ModelContext, notifier: SyncStateNotifying) {
        context.delete(category)
        try? context.save()
        regenerateManifest(context: context)
        notifier()
    }

    /// DESTRUCTIVE category delete: remove the record, THEN reconcile — its managed tuples no longer
    /// contribute to `desired`, so any not covered by another category are unlinked off disk. (PLAN-06 / 06.3)
    @discardableResult
    func delete(_ category: Category, reconciler: CategoryReconcilerProtocol, context: ModelContext,
                notifier: SyncStateNotifying) -> BatchResult {
        delete(category, context: context, notifier: SyncStateNotifier.suppressed)
        let result = reconciler.reconcile(context: context)
        notifier()
        return result
    }

    func setProject(_ project: Project, inCategory category: Category, member: Bool, context: ModelContext,
                    notifier: SyncStateNotifying) {
        guard let key = project.identityKey else { return }

        if member {
            if !category.projectKeys.contains(key) {
                category.projectKeys.append(key)
            }
        } else {
            category.projectKeys.removeAll { $0 == key }
        }
        try? context.save()
        regenerateManifest(context: context)
        notifier()
    }

    /// Toggle a project's membership, then reconcile the delta. Returns the reconcile result. (PLAN-06 / 06.3)
    @discardableResult
    func setProject(_ project: Project, inCategory category: Category, member: Bool,
                    reconciler: CategoryReconcilerProtocol, context: ModelContext,
                    notifier: SyncStateNotifying) -> BatchResult {
        setProject(project, inCategory: category, member: member, context: context,
                   notifier: SyncStateNotifier.suppressed)
        let result = reconciler.reconcile(context: context)
        notifier()
        return result
    }

    func setSkill(_ skill: Skill, inCategory category: Category, assigned: Bool, context: ModelContext,
                  notifier: SyncStateNotifying) {
        let slug = skill.directoryName

        if assigned {
            if !category.skillSlugs.contains(slug) {
                category.skillSlugs.append(slug)
            }
        } else {
            category.skillSlugs.removeAll { $0 == slug }
        }
        try? context.save()
        regenerateManifest(context: context)
        notifier()
    }

    /// Toggle a skill's assignment, then reconcile the delta. Returns the reconcile result. (PLAN-06 / 06.3)
    @discardableResult
    func setSkill(_ skill: Skill, inCategory category: Category, assigned: Bool,
                  reconciler: CategoryReconcilerProtocol, context: ModelContext,
                  notifier: SyncStateNotifying) -> BatchResult {
        setSkill(skill, inCategory: category, assigned: assigned, context: context,
                 notifier: SyncStateNotifier.suppressed)
        let result = reconciler.reconcile(context: context)
        notifier()
        return result
    }

    func categories(containingProjectKey key: String, context: ModelContext) -> [Category] {
        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        return categories.filter { $0.projectKeys.contains(key) }
    }

    func categories(containingSkillSlug slug: String, context: ModelContext) -> [Category] {
        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        return categories.filter { $0.skillSlugs.contains(slug) }
    }

    /// Best-effort manifest regeneration after a category mutation. No-op without a wired service
    /// (tests). A failure is logged (this struct has no error channel) — never a silent `try?`.
    private func regenerateManifest(context: ModelContext) {
        guard let manifestService else { return }
        do {
            try manifestService.write(manifestService.snapshot(from: context), toRoot: manifestRoot)
        } catch {
            Logger(subsystem: "com.jaredatch.pensieve", category: "manifest")
                .warning(
                    "Category mutation saved, but manifest regeneration failed: \(error.localizedDescription, privacy: .public)"
                )
        }
    }
}
