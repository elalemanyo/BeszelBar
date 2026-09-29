import SwiftUI
import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var observationTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "BeszelBar")
            button.image?.size = NSSize(width: 18, height: 18)
        }

        item.menu = MenuBuilder.build(appState: AppState.shared)
        self.statusItem = item

        AppState.shared.loadSystems()
        RefreshService.shared.start()
        startObserving()

        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        RefreshService.shared.stop()
        observationTask?.cancel()
    }

    private func startObserving() {
        observationTask = Task { @MainActor in
            while !Task.isCancelled {
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = AppState.shared.instances
                        _ = AppState.shared.selectedInstance
                        _ = AppState.shared.selectedInstanceSystems
                        _ = AppState.shared.isLoading
                        _ = AppState.shared.activeAlerts
                        _ = AppState.shared.systemDetails
                        _ = AppState.shared.containers
                        _ = AppState.shared.pinnedSystem
                    } onChange: {
                        continuation.resume()
                    }
                }
                refreshMenu()
            }
        }

        // Menu bar stats settings live in UserDefaults, which Observation doesn't track.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                AppState.shared.loadPinnedSystem()
                self?.updateStatusButton()
            }
            .store(in: &cancellables)
    }

    private func refreshMenu() {
        updateStatusButton()
        statusItem?.menu = MenuBuilder.build(appState: AppState.shared)
    }

    private func updateStatusButton() {
        guard let button = statusItem?.button else { return }
        let appState = AppState.shared

        let alertCount = appState.activeAlerts.count
        let symbolName = alertCount > 0 ? "server.rack.fill" : "server.rack"
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "BeszelBar")
        button.image?.size = NSSize(width: 18, height: 18)

        let font = NSFont.menuBarFont(ofSize: 0)
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let title = NSMutableAttributedString()

        if alertCount > 0 {
            title.append(NSAttributedString(string: " \(alertCount)", attributes: plain))
        }

        if let settings = MenuBarStatsSettings.current(),
           let system = appState.menuBarSystem,
           let stats = MenuBarStatsFormatter.attributedString(for: system, settings: settings, font: font) {
            title.append(NSAttributedString(string: alertCount > 0 ? " · " : " ", attributes: plain))
            title.append(stats)
        }

        button.attributedTitle = title
    }
}

@MainActor
enum MenuBarStatsFormatter {
    private static let barLevels = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    private struct Metric {
        let label: String
        let value: Double
        let text: String
        let warning: Double
        let critical: Double
    }

    /// Returns nil when there is nothing to show (no metrics enabled or available).
    static func attributedString(for system: SystemRecord, settings: MenuBarStatsSettings, font: NSFont) -> NSAttributedString? {
        let digitsFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
        let plain: [NSAttributedString.Key: Any] = [.font: digitsFont, .foregroundColor: NSColor.labelColor]
        let result = NSMutableAttributedString()

        guard system.isOnline else {
            result.append(NSAttributedString(string: "●", attributes: [.font: digitsFont, .foregroundColor: NSColor.systemRed]))
            result.append(NSAttributedString(string: " Offline", attributes: plain))
            return result
        }

        var metrics: [Metric] = []
        if settings.showCPU, let cpu = system.cpuPercentage {
            metrics.append(Metric(label: "CPU", value: cpu, text: "\(Int(cpu))%", warning: 70, critical: 90))
        }
        if settings.showMemory, let mem = system.memoryPercentage {
            metrics.append(Metric(label: "MEM", value: mem, text: "\(Int(mem))%", warning: 70, critical: 90))
        }
        if settings.showDisk, let disk = system.diskPercentage {
            metrics.append(Metric(label: "DSK", value: disk, text: "\(Int(disk))%", warning: 70, critical: 90))
        }
        if settings.showTemperature, let temp = system.temperature {
            metrics.append(Metric(label: "TMP", value: temp, text: String(format: "%.0f°C", temp), warning: 60, critical: 80))
        }

        guard !metrics.isEmpty else { return nil }

        for (index, metric) in metrics.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "  ", attributes: plain))
            }

            var valueAttributes = plain
            if settings.colorThresholds, let color = thresholdColor(for: metric) {
                valueAttributes[.foregroundColor] = color
            }

            switch settings.style {
            case .text:
                result.append(NSAttributedString(string: "\(metric.label) ", attributes: plain))
                result.append(NSAttributedString(string: metric.text, attributes: valueAttributes))
            case .bars:
                result.append(NSAttributedString(string: String(metric.label.prefix(1)), attributes: plain))
                result.append(NSAttributedString(string: bar(for: metric.value), attributes: valueAttributes))
            }
        }

        return result
    }

    /// Temperatures are drawn on a 0–100 °C scale, like percentages.
    private static func bar(for value: Double) -> String {
        let clamped = min(max(value, 0), 100)
        let index = min(Int(clamped / 100 * Double(barLevels.count)), barLevels.count - 1)
        return barLevels[index]
    }

    private static func thresholdColor(for metric: Metric) -> NSColor? {
        if metric.value >= metric.critical { return .systemRed }
        if metric.value >= metric.warning { return .systemOrange }
        return nil
    }
}
