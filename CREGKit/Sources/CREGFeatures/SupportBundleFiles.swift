import Foundation
import ComposableArchitecture

struct SupportBundleFilesClient: Sendable {
  var cleanAbandoned: @Sendable (Set<URL>) async -> Void
}

extension SupportBundleFilesClient: DependencyKey {
  static let liveValue: Self = {
    let files = SupportBundleFiles()
    return Self(cleanAbandoned: { await files.cleanAbandoned(protected: $0) })
  }()
  static let testValue = Self(cleanAbandoned: { _ in })
}

extension DependencyValues {
  var supportBundleFiles: SupportBundleFilesClient {
    get { self[SupportBundleFilesClient.self] }
    set { self[SupportBundleFilesClient.self] = newValue }
  }
}

/// Serializes the launch sweep with the first support build. A sheet's
/// retained artifact is protected when an existing store first appears.
actor SupportBundleFiles {
  private var didClean = false

  func cleanAbandoned(
    protected: Set<URL>, directory: URL = FileManager.default.temporaryDirectory
  ) {
    guard !didClean else { return }
    didClean = true
    let manager = FileManager.default
    let excluded = Set(protected.map { $0.resolvingSymlinksInPath().standardizedFileURL })
    let files = (try? manager.contentsOfDirectory(at: directory,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])) ?? []
    for url in files {
      let name = url.lastPathComponent
      guard Self.eligible(url, directory: directory),
        !excluded.contains(url.resolvingSymlinksInPath().standardizedFileURL),
        !excluded.contains(where: { $0.deletingLastPathComponent() == url.resolvingSymlinksInPath().standardizedFileURL })
      else { continue }
      if Self.isBundleDirectory(name) || name == "creg-support-bundle"
        || name == "creg-support-bundle.zip"
      {
        try? manager.removeItem(at: url)
      }
    }
  }

  nonisolated private static func isBundleDirectory(_ name: String) -> Bool {
    let prefix = "creg-support-bundle-"
    return name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
  }

  nonisolated private static func eligible(_ url: URL, directory: URL) -> Bool {
    let file = url.standardizedFileURL
    guard file.deletingLastPathComponent().resolvingSymlinksInPath()
      == directory.resolvingSymlinksInPath().standardizedFileURL,
      let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]),
      values.isSymbolicLink == false
    else { return false }
    if file.lastPathComponent == "creg-support-bundle.zip" { return values.isRegularFile == true }
    return values.isDirectory == true
  }

  nonisolated static func remove(
    _ url: URL, directory: URL = FileManager.default.temporaryDirectory
  ) {
    let folder = url.standardizedFileURL.deletingLastPathComponent()
    guard url.lastPathComponent == "creg-support-bundle.zip",
      isBundleDirectory(folder.lastPathComponent), eligible(folder, directory: directory),
      (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
    else { return }
    try? FileManager.default.removeItem(at: folder)
  }
}
