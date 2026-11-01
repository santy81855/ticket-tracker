import Foundation
import TrackerCore
import UserNotifications

@MainActor
final class ReminderManager: NSObject, UNUserNotificationCenterDelegate {
  let center = UNUserNotificationCenter.current()
  var onSelect: ((String) -> Void)?

  override init() {
    super.init()
    center.delegate = self
  }

  func reconcile(_ snapshots: [ItemSnapshot]) async throws {
    let settings = await center.notificationSettings()
    guard
      settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    else { return }
    let upcoming = snapshots.filter { !$0.item.isDone && $0.item.followUpAt != nil }
    let desired = Dictionary(uniqueKeysWithValues: upcoming.map { (notificationID($0), $0) })
    let pending = await center.pendingNotificationRequests()
    let obsolete = pending.map(\.identifier).filter {
      $0.hasPrefix("tracker-") && desired[$0] == nil
    }
    center.removePendingNotificationRequests(withIdentifiers: obsolete)
    let delivered = await center.deliveredNotifications()
    center.removeDeliveredNotifications(
      withIdentifiers: delivered.map(\.request.identifier)
        .filter { $0.hasPrefix("tracker-") && desired[$0] == nil })
    let scheduled = Set(pending.map(\.identifier))
    var known =
      UserDefaults.standard.dictionary(forKey: "scheduledFollowUps") as? [String: Bool] ?? [:]
    for (id, snapshot) in desired where !scheduled.contains(id) && known[id] != true {
      guard let date = snapshot.item.followUpAt else { continue }
      let content = UNMutableNotificationContent()
      content.title =
        snapshot.item.kind == .ticket
        ? "Follow up on \(snapshot.item.jiraKey)" : "Personal follow-up"
      content.body = snapshot.item.title
      content.sound = .default
      content.userInfo = ["item_id": snapshot.id]
      let trigger = UNTimeIntervalNotificationTrigger(
        timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
      try await center.add(
        UNNotificationRequest(identifier: id, content: content, trigger: trigger))
      known[id] = true
    }
    let relevant = Set(desired.keys)
    UserDefaults.standard.set(
      known.filter { relevant.contains($0.key) }, forKey: "scheduledFollowUps")
  }

  private func notificationID(_ snapshot: ItemSnapshot) -> String {
    "tracker-\(snapshot.id)-\(Int(snapshot.item.followUpAt?.timeIntervalSince1970 ?? 0))"
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let identifier = response.notification.request.content.userInfo["item_id"] as? String
    Task { @MainActor [weak self] in if let identifier { self?.onSelect?(identifier) } }
    completionHandler()
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }
}
