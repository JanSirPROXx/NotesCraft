#if os(macOS)
  import AppKit

  @MainActor final class AppLifecycle: NSObject, NSApplicationDelegate {
    private final class Registration {
      weak var vault: VaultController?
      init(_ vault: VaultController) { self.vault = vault }
    }
    private static var registrations: [Registration] = []
    static func register(_ vault: VaultController) {
      registrations.removeAll { $0.vault == nil }
      if !registrations.contains(where: { $0.vault === vault }) {
        registrations.append(Registration(vault))
      }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      let vaults = Self.registrations.compactMap(\.vault)
      guard vaults.contains(where: { $0.sessions.contains(where: \.dirty) }) else {
        return .terminateNow
      }
      Task {
        for vault in vaults {
          for session in vault.sessions where session.dirty { await vault.save(session) }
        }
        sender.reply(
          toApplicationShouldTerminate: !vaults.contains { $0.sessions.contains(where: \.dirty) })
      }
      return .terminateLater
    }
  }
#endif
