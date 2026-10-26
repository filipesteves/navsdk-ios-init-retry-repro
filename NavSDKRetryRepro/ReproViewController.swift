import GoogleNavigation
import UIKit
import os

/// Re-adds the same markers on a timer, the way @googlemaps/react-native-navigation-sdk 0.17.3
/// does when JS calls `addMarker` again with an existing id (NavViewModule.mm addMarker →
/// NavViewController addMarker:visible:result: → ObjectTranslationUtil updateMarker:…icon:):
/// a temporary GMSMarker is built with `[UIImage imageNamed:]`, then its icon is copied onto
/// the existing marker.
///
/// Watch "defaults writes/s". It stays at 0 while idle. Once the SDK's navigation init/quota
/// retry loop starts, it keeps counting (and CPU stays high) after switching back to Off.
///
/// Two switches add what the RN app had around the markers:
/// - Settings forwarding (`-settingsForwarding YES`): RCTSettingsManager's work on each defaults
///   change, synchronously on the posting thread.
/// - Navigation session (`-navSession YES`): terms, `createNavigationSession`, `started = YES`,
///   and the session attached to the map, as NavModule.mm and NavViewController.mm do for the
///   NavigationView that the React Native app's live-ride markers are on.
final class ReproViewController: UIViewController {
  private enum Mode: Int, CaseIterable {
    case off, defaultPin, customIcon

    /// Launch argument, e.g. `-mode customIcon`, to start without tapping.
    static var fromLaunchArguments: Mode {
      switch UserDefaults.standard.string(forKey: "mode") {
      case "defaultPin": .defaultPin
      case "customIcon": .customIcon
      default: .off
      }
    }

    var title: String {
      switch self {
      case .off: "Off"
      case .defaultPin: "Default pin"
      case .customIcon: "Custom icon"
      }
    }
  }

  private static let markerCount = 10
  private static let tickInterval: TimeInterval = 0.25
  private static let iconName = "custom_marker"
  // A neutral spot; any location works.
  private static let center = CLLocationCoordinate2D(latitude: 37.7793, longitude: -122.4193)

  private let log = Logger(subsystem: "navsdk-retry-repro", category: "stats")

  private var mapView: GMSMapView!
  private var markers: [String: GMSMarker] = [:]
  private var mode: Mode = .off
  private var tickTimer: Timer?
  private var statsTimer: Timer?

  private var addMarkerCalls = 0
  private var mapsCreated = 0
  private var navSession: GMSNavigationSession?

  private let defaultsObserver = DefaultsObserver()

  private let modeControl = UISegmentedControl(items: Mode.allCases.map(\.title))
  private let recreateButton = UIButton(configuration: .gray())
  private let settingsSwitch = UISwitch()
  private let sessionSwitch = UISwitch()
  private let statsLabel = UILabel()
  private let panel = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    mode = Mode.fromLaunchArguments
    defaultsObserver.forwardsSettings = UserDefaults.standard.bool(forKey: "settingsForwarding")
    createMap()
    buildPanel()
    // `-resetTerms YES`: forget an earlier acceptance, so the terms dialog shows again.
    if UserDefaults.standard.bool(forKey: "resetTerms") {
      GMSNavigationServices.resetTermsAndConditionsAccepted()
      log.notice("terms reset")
    }
    if UserDefaults.standard.bool(forKey: "navSession") {
      // After the first layout, so the terms dialog has a window to present on.
      DispatchQueue.main.async { self.setNavSessionEnabled(true) }
    }

    tickTimer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) {
      [weak self] _ in self?.tick()
    }
    statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      self?.sampleStats()
    }
  }

  /// Keeps Google's logo and attribution above the panel. Only on a change: every
  /// `setPadding:` logs a map event that writes NSUserDefaults, even with the same value, and
  /// the stats label lays out the view every second.
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let padding = UIEdgeInsets(
      top: 0, left: 0, bottom: view.bounds.maxY - panel.frame.minY, right: 0)
    if mapView.padding != padding { mapView.padding = padding }
  }

  // MARK: - Map

  /// Same construction as NavViewController.mm (a non-navigation MapView).
  private func createMap() {
    mapView?.removeFromSuperview()
    markers.removeAll()

    let options = GMSMapViewOptions()
    options.camera = GMSCameraPosition(target: Self.center, zoom: 14)
    let map = GMSMapView(options: options)
    map.translatesAutoresizingMaskIntoConstraints = false
    view.insertSubview(map, at: 0)
    NSLayoutConstraint.activate([
      map.topAnchor.constraint(equalTo: view.topAnchor),
      map.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      map.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      map.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    mapView = map
    mapsCreated += 1
    attachNavSession()
  }

  // MARK: - Navigation session

  /// NavModule.mm showTermsAndConditionsDialog + initializeNavigationSession / cleanup.
  private func setNavSessionEnabled(_ enabled: Bool) {
    sessionSwitch.isOn = enabled
    guard enabled else {
      guard let session = navSession else { return }
      session.navigator?.clearDestinations()
      session.isStarted = false
      navSession = nil
      log.notice("navSession -> off")
      // A map can't detach its session, so drop it.
      createMap()
      return
    }
    guard navSession == nil else { return }

    // `-skipTermsDialog YES`: call createNavigationSession without showing the dialog first
    // (it returns nil when the terms aren't accepted).
    if UserDefaults.standard.bool(forKey: "skipTermsDialog") {
      let accepted = GMSNavigationServices.areTermsAndConditionsAccepted()
      // `-termsCheckOnly YES`: stop after the check, as the RN wrapper does when not accepted.
      if UserDefaults.standard.bool(forKey: "termsCheckOnly") {
        log.notice("terms check only: termsAccepted=\(accepted, privacy: .public)")
        sessionSwitch.isOn = false
        return
      }
      navSession = GMSNavigationServices.createNavigationSession()
      navSession?.isStarted = true
      log.notice(
        "navSession without dialog: termsAccepted=\(accepted, privacy: .public) session=\(self.navSession != nil, privacy: .public)"
      )
      sessionSwitch.isOn = navSession != nil
      attachNavSession()
      return
    }

    let options = GMSNavigationTermsAndConditionsOptions(companyName: "NavSDK Repro")
    GMSNavigationServices.showTermsAndConditionsDialogIfNeeded(with: options) {
      [weak self] accepted in
      guard let self else { return }
      guard accepted, let session = GMSNavigationServices.createNavigationSession() else {
        self.log.notice("navSession: terms not accepted or no session")
        self.sessionSwitch.isOn = false
        return
      }
      session.isStarted = true
      session.navigator?.stopGuidanceAtArrival = false
      self.navSession = session
      self.log.notice("navSession -> on")
      self.attachNavSession()
    }
  }

  /// NavViewController.mm attachSession: the map becomes a NavigationView's map.
  private func attachNavSession() {
    guard let navSession, let mapView else { return }
    let attached = mapView.enableNavigation(with: navSession)
    log.notice("navSession attached to map: \(attached, privacy: .public)")
  }

  private func tick() {
    guard mode != .off else { return }
    for index in 0..<Self.markerCount {
      addMarker(id: "marker-\(index)", position: position(for: index))
    }
  }

  private func position(for index: Int) -> CLLocationCoordinate2D {
    let angle = Double(index) / Double(Self.markerCount) * 2 * .pi
    return CLLocationCoordinate2D(
      latitude: Self.center.latitude + 0.006 * sin(angle),
      longitude: Self.center.longitude + 0.008 * cos(angle))
  }

  /// Mirrors the wrapper's addMarker for an id that may already exist.
  private func addMarker(id: String, position: CLLocationCoordinate2D) {
    addMarkerCalls += 1
    let icon = mode == .customIcon ? UIImage(named: Self.iconName) : nil

    // Diagnostic (`-skipTemporaryMarker YES`): update the existing marker without first
    // building a temporary GMSMarker, unlike the wrapper.
    if UserDefaults.standard.bool(forKey: "skipTemporaryMarker"), let existing = markers[id] {
      if let icon { existing.icon = icon }
      existing.position = position
      existing.map = mapView
      return
    }

    let candidate = GMSMarker(position: position)
    candidate.groundAnchor = CGPoint(x: 0.5, y: 1.0)
    if let icon { candidate.icon = icon }

    if let existing = markers[id] {
      existing.title = candidate.title
      existing.opacity = candidate.opacity
      existing.groundAnchor = candidate.groundAnchor
      if let icon = candidate.icon { existing.icon = icon }
      existing.position = candidate.position
      existing.map = mapView
      return
    }

    candidate.map = mapView
    markers[id] = candidate
  }

  // MARK: - Stats

  private func sampleStats() {
    let cpu = Self.processCPUPercent()
    let writes = defaultsObserver.takeSample()
    let switches =
      "forwarding=\(defaultsObserver.forwardsSettings ? 1 : 0) session=\(navSession == nil ? 0 : 1)"

    statsLabel.text = """
      CPU (all threads): \(String(format: "%.0f", cpu)) %
      defaults writes/s: \(writes.perSecond)   total: \(writes.total)
      off main: \(writes.offMainTotal)   not standard: \(writes.notStandardTotal)
      addMarker calls: \(addMarkerCalls)   maps created: \(mapsCreated)
      """
    // stdout too, so `devicectl device process launch --console` can record a device run.
    let line =
      "mode=\(mode.title) \(switches) cpu=\(String(format: "%.0f", cpu)) defaultsWritesPerSec=\(writes.perSecond) defaultsWritesTotal=\(writes.total) offMainTotal=\(writes.offMainTotal) notStandardTotal=\(writes.notStandardTotal) addMarkerCalls=\(addMarkerCalls) mapsCreated=\(mapsCreated)"
    print("stats t=\(Int(Date().timeIntervalSince1970)) \(line)")
    log.notice("\(line, privacy: .public)")
  }

  /// Sum of cpu_usage over the process's threads, as Xcode's CPU gauge shows it (100 % = one core).
  private static func processCPUPercent() -> Double {
    var threads: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else {
      return 0
    }
    defer {
      vm_deallocate(
        mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
        vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
    }

    var total = 0.0
    for index in 0..<Int(count) {
      var info = thread_basic_info()
      var infoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
      let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
          thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
        }
      }
      if result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
        total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
      }
    }
    return total
  }

  // MARK: - Panel

  private func buildPanel() {
    modeControl.selectedSegmentIndex = mode.rawValue
    modeControl.addAction(
      UIAction { [weak self] _ in
        guard let self, let mode = Mode(rawValue: self.modeControl.selectedSegmentIndex) else {
          return
        }
        self.mode = mode
        self.log.notice("mode -> \(mode.title, privacy: .public)")
      }, for: .valueChanged)

    recreateButton.configuration?.title = "Recreate map"
    recreateButton.addAction(UIAction { [weak self] _ in self?.createMap() }, for: .touchUpInside)

    settingsSwitch.isOn = defaultsObserver.forwardsSettings
    settingsSwitch.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.defaultsObserver.forwardsSettings = self.settingsSwitch.isOn
        self.log.notice("settingsForwarding -> \(self.settingsSwitch.isOn, privacy: .public)")
      }, for: .valueChanged)
    sessionSwitch.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.setNavSessionEnabled(self.sessionSwitch.isOn)
      }, for: .valueChanged)

    statsLabel.numberOfLines = 0
    statsLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    statsLabel.text = "…"

    let stack = UIStackView(arrangedSubviews: [
      modeControl, recreateButton,
      Self.switchRow("Settings forwarding", settingsSwitch),
      Self.switchRow("Navigation session", sessionSwitch),
      statsLabel,
    ])
    stack.axis = .vertical
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false

    panel.layer.cornerRadius = 14
    panel.clipsToBounds = true
    panel.translatesAutoresizingMaskIntoConstraints = false
    panel.contentView.addSubview(stack)
    view.addSubview(panel)

    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: 14),
      stack.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -14),
      stack.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -14),
      panel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
      panel.trailingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
      panel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
    ])
  }

  private static func switchRow(_ title: String, _ toggle: UISwitch) -> UIView {
    let label = UILabel()
    label.text = title
    let row = UIStackView(arrangedSubviews: [label, toggle])
    row.spacing = 8
    return row
  }
}

/// Counts `NSUserDefaultsDidChangeNotification`s from any thread and, when `forwardsSettings` is
/// on, does what RCTSettingsManager userDefaultsDidChange: does: reads the whole standard
/// defaults dictionary, cleans it for JSON and serialises it, synchronously on the posting thread.
///
/// `-logDefaultsKeys YES` also logs which standard-defaults keys each change added, removed or
/// changed (key names only), to find the source of idle writes.
final class DefaultsObserver: @unchecked Sendable {
  struct Sample {
    var perSecond = 0
    var total = 0
    var offMainTotal = 0
    var notStandardTotal = 0
  }

  private struct State {
    var sample = Sample()
    var forwardsSettings = false
    var lastSnapshot: [String: Any] = [:]
  }

  private let state = OSAllocatedUnfairLock(uncheckedState: State())
  private let logsKeys = UserDefaults.standard.bool(forKey: "logDefaultsKeys")
  private let log = Logger(subsystem: "navsdk-retry-repro", category: "defaults")
  private var token: NSObjectProtocol?

  var forwardsSettings: Bool {
    get { state.withLockUnchecked { $0.forwardsSettings } }
    set { state.withLockUnchecked { $0.forwardsSettings = newValue } }
  }

  init() {
    if logsKeys {
      let snapshot = UserDefaults.standard.dictionaryRepresentation()
      state.withLockUnchecked { $0.lastSnapshot = snapshot }
    }
    // Object nil, to count every NSUserDefaults instance; RCTSettingsManager only observes
    // the standard one.
    token = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: nil
    ) { [weak self] note in self?.defaultsDidChange(note) }
  }

  deinit {
    if let token { NotificationCenter.default.removeObserver(token) }
  }

  /// Writes per second since the last call, plus running totals.
  func takeSample() -> Sample {
    state.withLockUnchecked {
      let sample = $0.sample
      $0.sample.perSecond = 0
      return sample
    }
  }

  private func defaultsDidChange(_ note: Notification) {
    let isStandard = (note.object as? UserDefaults) === UserDefaults.standard
    let forwards = state.withLockUnchecked {
      $0.sample.perSecond += 1
      $0.sample.total += 1
      if !Thread.isMainThread { $0.sample.offMainTotal += 1 }
      if !isStandard { $0.sample.notStandardTotal += 1 }
      return $0.forwardsSettings
    }

    if forwards && isStandard {
      let body = Self.jsonClean(UserDefaults.standard.dictionaryRepresentation())
      _ = try? JSONSerialization.data(withJSONObject: body)
    }
    if logsKeys { logChangedKeys(isStandard: isStandard) }
  }

  private func logChangedKeys(isStandard: Bool) {
    let snapshot = UserDefaults.standard.dictionaryRepresentation()
    let previous = state.withLockUnchecked {
      let previous = $0.lastSnapshot
      $0.lastSnapshot = snapshot
      return previous
    }
    let keys = Set(snapshot.keys).union(previous.keys)
    let changed = keys.filter { key in
      switch (snapshot[key], previous[key]) {
      case (nil, nil): false
      case let (new?, old?): !(new as AnyObject).isEqual(old)
      default: true
      }
    }.sorted()
    let thread = Thread.isMainThread ? "main" : "background"
    log.notice(
      "change standard=\(isStandard, privacy: .public) thread=\(thread, privacy: .public) keys=\(changed.joined(separator: ","), privacy: .public)"
    )
    print("defaults standard=\(isStandard) thread=\(thread) keys=\(changed.joined(separator: ","))")

    // The writer: the frames just below the notification post, on one line, so repeated
    // writers can be counted (the notification is posted synchronously by the write).
    let frames = Thread.callStackSymbols
    if let post = frames.firstIndex(where: { $0.contains("postNotificationName") }) {
      let writer = frames.dropFirst(post + 1).prefix(4).map {
        $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).prefix(2)
          .joined(separator: " ")
      }
      print("defaults writer: " + writer.joined(separator: " <- "))
    }
  }

  /// RCTJSONClean: keeps strings, numbers and nulls, recurses into collections, and turns
  /// anything else (dates, data) into null.
  private static func jsonClean(_ value: Any) -> Any {
    switch value {
    case let dictionary as [String: Any]: dictionary.mapValues(jsonClean)
    case let array as [Any]: array.map(jsonClean)
    case is String, is NSNumber, is NSNull: value
    default: NSNull()
    }
  }
}
