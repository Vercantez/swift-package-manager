/*
 This source file is part of the Swift.org open source project

 Copyright 2016 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import struct PackageDescription.Version

/// An identifier which unambiguously references a package container.
///
/// This identifier is used to abstractly refer to another container when
/// encoding dependencies across packages.
public protocol PackageContainerIdentifier: Hashable { }

/// A container of packages.
///
/// This is the top-level unit of package resolution, i.e. the unit at which
/// versions are associated.
///
/// It represents a package container (e.g., a source repository) which can be
/// identified unambiguously and which contains a set of available package
/// versions and the ability to retrieve the dependency constraints for each of
/// those versions.
///
/// We use the "container" terminology here to differentiate between two
/// conceptual notions of what the package is: (1) informally, the repository
/// containing the package, but from which a package cannot be loaded by itself
/// and (2) the repository at a particular version, at which point the package
/// can be loaded and dependencies enumerated.
///
/// This is also designed in such a way to extend naturally to multiple packages
/// being contained within a single repository, should we choose to support that
/// later.
public protocol PackageContainer {
    /// The type of packages contained.
    associatedtype Identifier: PackageContainerIdentifier

    /// Get the list of versions which are available for the package.
    ///
    /// The list will be returned in sorted order, with the latest version last.
    //
    // FIXME: It is possible this protocol could one day be more efficient if it
    // returned versions more lazily, e.g., if we could fetch them iteratively
    // from the server. This might mean we wouldn't need to pull down as much
    // content.
    var versions: [Version] { get }

    /// Fetch the declared dependencies for a particular version.
    ///
    /// - precondition: `versions.contains(version)`
    func getDependencies(at version: Version) -> [DependencyConstraint<Identifier>]
}

/// An interface for resolving package containers.
public protocol PackageContainerProvider {
    associatedtype Container: PackageContainer

    /// Get the container for a particular identifier.
    ///
    /// - Throws: If the package container could not be resolved or loaded.
    func getContainer(for identifier: Container.Identifier) throws -> Container
}

/// An individual dependency constraint for a package.
public struct DependencyConstraint<T> where T: PackageContainerIdentifier {
    public typealias Identifier = T
    public typealias VersionRequirement = Range<Version>

    /// The identifier for the package container the constraint is on.
    public let container: Identifier

    /// The version requirements.
    public let versionRequirement: VersionRequirement

    /// Create a dependency requiring the given `container` satisfying the
    /// `versionRequirement`.
    public init(container: Identifier, versionRequirement: VersionRequirement) {
        self.container = container
        self.versionRequirement = versionRequirement
    }
}

/// Delegate interface for dependency resoler status.
public protocol DependencyResolverDelegate {
    associatedtype Identifier: PackageContainerIdentifier
}

/// A general purpose package dependency resolver.
///
/// This is a general purpose solver for the problem of:
///
/// Given an input list of constraints, where each constraint identifies a
/// container and version requirements, and, where each container supplies a
/// list of additional constraints ("dependencies") for an individual version,
/// then, choose an assignment of containers to versions such that:
///
/// 1. The assignment is complete: there exists an assignment for each container
/// listed in the union of the input constraint list and the dependency list for
/// every container in the assignment at the assigned version.
///
/// 2. The assignment is correct: the assigned version satisfies each constraint
/// referencing its matching container.
///
/// 3. The assignment is maximal: there is no other assignment satisfying #1 and
/// #2 such that all assigned version are greater than or equal to the versions
/// assigned in the result.
///
/// NOTE: It does not follow from #3 that this solver attempts to give an
/// "optimal" result. There may be many possible solutions satisfying #1, #2,
/// and #3, and optimality requires additional information (e.g. a
/// prioritization among packages).
///
/// As described, this problem is NP-complete (*). However, this solver does
/// *not* currently attempt to solve the full NP-complete problem, rather it
/// proceeds by first always attempting to choose the latest version of each
/// container under consideration. However, if this version is unavailable due
/// to the current choice of assignments, it will be rejected and no longer
/// considered.
///
/// This algorithm is sound (a valid solution satisfies the assignment
/// guarantees above), but *incomplete*; it may fail to find a valid solution to
/// a satisfiable input.
///
/// (*) Via reduction from 3-SAT: Introduce a package for each variable, with
/// two versions representing true and false. For each clause `C_n`, introduce a
/// package `P(C_n)` representing the clause, with three versions; one for each
/// satisfying assignment of values to a literal with the corresponding precise
/// constraint on the input packages. Finally, construct an input constraint
/// list including a dependency on each clause package `P(C_n)` and an
/// open-ended version constraint. The given input is satisfiable iff the input
/// 3-SAT instance is.
public class DependencyResolver<
    P: PackageContainerProvider,
    D: DependencyResolverDelegate
> where P.Container.Identifier == D.Identifier
{
    public typealias Provider = P
    public typealias Delegate = D
    public typealias Container = Provider.Container
    public typealias Identifier = Container.Identifier

    /// The initial constraints.
    let constraints: [DependencyConstraint<Identifier>]

    /// The container provider used to load package containers.
    let provider: Provider

    /// The resolver's delegate.
    let delegate: Delegate

    public init(
        constraints: [DependencyConstraint<Identifier>],
        provider: Provider,
        delegate: Delegate)
    {
        self.constraints = constraints
        self.provider = provider
        self.delegate = delegate
    }

    /// Execute the resolution algorithm to find a valid assignment of versions.
    public func resolve() throws -> [(container: Identifier, version: Version)] {
        // For now, we just load the transitive closure of the dependencies at
        // the latest version, and ignore the version requirements.

        var containers: [Identifier: Container] = [:]
        func visit(_ identifier: Identifier) throws {
            // If we already have this identifier, skip it.
            if containers.keys.contains(identifier) {
                return
            }

            // Otherwise, load the container and visit its dependencies.
            let container = try provider.getContainer(for: identifier)
            containers[identifier] =  container

            // Visit the dependencies at the latest version.
            //
            // FIXME: What if this dependency has no versions? We should
            // consider it unavailable.
            //
            // FIXME: We should assert (somewhere) that we got the versions in
            // order.
            let latestVersion = container.versions.last!
            let constraints = container.getDependencies(at: latestVersion)

            for constraint in constraints {
                try visit(constraint.container)
            }
        }
        for constraint in constraints {
            try visit(constraint.container)
        }

        return containers.map { (identifier, container) in
            return (container: identifier, version: container.versions.last!)
        }
    }
}
