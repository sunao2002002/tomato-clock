import Combine
import AppKit
import SwiftUI
import UserNotifications

struct FocusSessionRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let completedAt: Date
    let duration: TimeInterval

    init(id: UUID = UUID(), completedAt: Date, duration: TimeInterval = 15 * 60) {
        self.id = id
        self.completedAt = completedAt
        self.duration = duration
    }
}

enum HistoryScope: String, CaseIterable, Identifiable {
    case week = "周视图"
    case month = "月视图"

    var id: String { rawValue }
}

struct HistoryDaySummary: Identifiable {
    var id: String { dateKey }

    let date: Date
    let dateKey: String
    let dayLabel: String
    let count: Int
}

@MainActor
final class ClockViewModel: ObservableObject {
    private static let sessionsBeforeLongBreak = 4
    private static let completedPomodoroKey = "completedPomodoroCount"
    private static let completedTodayPomodoroKey = "completedTodayPomodoroCount"
    private static let pomodoroStatsDateKey = "pomodoroStatsDate"
    private static let focusHistoryKey = "focusHistoryRecords"
    private static let menuBarOnlyModeKey = "menuBarOnlyModeEnabled"

    enum PomodoroPhase {
        case focus
        case shortBreak
        case longBreak

        var title: String {
            switch self {
            case .focus:
                return "番茄时钟"
            case .shortBreak:
                return "短休息"
            case .longBreak:
                return "长休息"
            }
        }

        var actionTitle: String {
            switch self {
            case .focus:
                return "开始专注"
            case .shortBreak:
                return "开始短休息"
            case .longBreak:
                return "开始长休息"
            }
        }

        var duration: TimeInterval {
            switch self {
            case .focus:
                return 15 * 60
            case .shortBreak:
                return 5 * 60
            case .longBreak:
                return 15 * 60
            }
        }
    }

    @Published var displayText: String = "--"
    @Published var statusText: String = "同步中..."
    @Published var pomodoroDisplayText: String = "15:00"
    @Published var pomodoroStatusText: String = "准备开始 15 分钟专注"
    @Published var completedPomodoroCount: Int
    @Published var completedTodayPomodoroCount: Int
    @Published var isPomodoroRunning: Bool = false
    @Published var isAlertVisible: Bool = false
    @Published var pomodoroPhase: PomodoroPhase = .focus
    @Published var isMenuBarOnlyModeEnabled: Bool
    @Published private(set) var focusHistory: [FocusSessionRecord]

    private let formatter: DateFormatter
    private let client: SNTPClient
    private let notificationsAvailable: Bool
    private var timerCancellable: AnyCancellable?
    private var offset: TimeInterval = 0
    private var remainingPomodoroDuration: TimeInterval = PomodoroPhase.focus.duration
    private var pomodoroEndDate: Date?
    private var completedFocusSessionsInCycle: Int = 0

    init(client: SNTPClient = SNTPClient()) {
        self.client = client
        self.completedPomodoroCount = UserDefaults.standard.integer(forKey: Self.completedPomodoroKey)
        self.completedTodayPomodoroCount = UserDefaults.standard.integer(forKey: Self.completedTodayPomodoroKey)
        self.isMenuBarOnlyModeEnabled = UserDefaults.standard.bool(forKey: Self.menuBarOnlyModeKey)
        self.focusHistory = Self.loadFocusHistory()
        self.notificationsAvailable = Bundle.main.bundleURL.pathExtension == "app"

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        self.formatter = formatter

        synchronizeDailyStatsIfNeeded()
        requestNotificationAuthorization()
        refreshDisplay()
        refreshPomodoroDisplay()
        startTimer()
    }

    var menuBarLabel: String {
        switch pomodoroPhase {
        case .focus:
            return isPomodoroRunning ? "专注 \(pomodoroDisplayText)" : "番茄钟"
        case .shortBreak:
            return isPomodoroRunning ? "休息 \(pomodoroDisplayText)" : "短休息"
        case .longBreak:
            return isPomodoroRunning ? "长休 \(pomodoroDisplayText)" : "长休息"
        }
    }

    var menuBarSymbolName: String {
        isPomodoroRunning ? "timer" : "clock"
    }

    var windowTitle: String {
        if isPomodoroRunning {
            return "\(pomodoroPhase.title) · \(pomodoroDisplayText)"
        }

        return "番茄时钟 · \(pomodoroDisplayText)"
    }

    var dockBadgeLabel: String? {
        isPomodoroRunning ? pomodoroDisplayText : nil
    }

    var latestHistoryPreview: [FocusSessionRecord] {
        Array(focusHistory.prefix(5))
    }

    func historyPeriodTitle(for scope: HistoryScope, anchorDate: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")

        switch scope {
        case .week:
            let interval = historyInterval(for: scope, anchorDate: anchorDate)
            formatter.dateFormat = "MM.dd"
            let start = formatter.string(from: interval.start)
            let end = formatter.string(from: calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start)
            return "\(start) - \(end)"
        case .month:
            formatter.dateFormat = "yyyy年MM月"
            return formatter.string(from: anchorDate)
        }
    }

    func shiftedHistoryAnchor(from anchorDate: Date, scope: HistoryScope, offset: Int) -> Date {
        switch scope {
        case .week:
            return calendar.date(byAdding: .day, value: 7 * offset, to: anchorDate) ?? anchorDate
        case .month:
            return calendar.date(byAdding: .month, value: offset, to: anchorDate) ?? anchorDate
        }
    }

    func historySections(for scope: HistoryScope, anchorDate: Date) -> [(day: String, date: Date, records: [FocusSessionRecord])] {
        let interval = historyInterval(for: scope, anchorDate: anchorDate)
        let filtered = focusHistory.filter { interval.contains($0.completedAt) }
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.completedAt) }

        return grouped
            .map { day, records in
                (
                    day: dayString(for: day),
                    date: day,
                    records: records.sorted { $0.completedAt > $1.completedAt }
                )
            }
            .sorted { $0.date > $1.date }
    }

    func historySummaries(for scope: HistoryScope, anchorDate: Date) -> [HistoryDaySummary] {
        let interval = historyInterval(for: scope, anchorDate: anchorDate)
        let filtered = focusHistory.filter { interval.contains($0.completedAt) }
        let counts = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.completedAt) }
            .mapValues(\.count)

        var summaries: [HistoryDaySummary] = []
        var current = interval.start
        while current < interval.end {
            summaries.append(
                HistoryDaySummary(
                    date: current,
                    dateKey: storageDayString(for: current),
                    dayLabel: compactDayString(for: current, scope: scope),
                    count: counts[calendar.startOfDay(for: current)] ?? 0
                )
            )
            current = calendar.date(byAdding: .day, value: 1, to: current) ?? interval.end
        }

        return summaries
    }

    func bootstrap() {
        Task {
            do {
                let ntpDate = try await client.fetchCurrentDate()
                offset = ntpDate.timeIntervalSinceNow
                statusText = "已同步 (time.apple.com)"
            } catch {
                offset = 0
                statusText = "同步失败（使用本地时间）"
            }

            refreshDisplay()
        }
    }

    private func startTimer() {
        timerCancellable = Timer
            .publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshDisplay()
                self?.updatePomodoroIfNeeded()
            }
    }

    private func refreshDisplay() {
        displayText = formatter.string(from: Date().addingTimeInterval(offset))
    }

    func startPomodoro() {
        guard !isPomodoroRunning else {
            return
        }

        pomodoroEndDate = Date().addingTimeInterval(remainingPomodoroDuration)
        isPomodoroRunning = true
        pomodoroStatusText = runningStatusText(for: pomodoroPhase)
        refreshPomodoroDisplay()
    }

    func pausePomodoro() {
        guard isPomodoroRunning else {
            return
        }

        if let pomodoroEndDate {
            remainingPomodoroDuration = max(0, pomodoroEndDate.timeIntervalSinceNow)
        }

        self.pomodoroEndDate = nil
        isPomodoroRunning = false
        pomodoroStatusText = pausedStatusText(for: pomodoroPhase)
        refreshPomodoroDisplay()
    }

    func resetPomodoro() {
        pomodoroEndDate = nil
        pomodoroPhase = .focus
        remainingPomodoroDuration = pomodoroPhase.duration
        isPomodoroRunning = false
        isAlertVisible = false
        completedFocusSessionsInCycle = 0
        pomodoroStatusText = "准备开始 15 分钟专注"
        refreshPomodoroDisplay()
    }

    func clearStats() {
        completedPomodoroCount = 0
        completedTodayPomodoroCount = 0
        completedFocusSessionsInCycle = 0
        focusHistory = []
        UserDefaults.standard.set(0, forKey: Self.completedPomodoroKey)
        UserDefaults.standard.set(0, forKey: Self.completedTodayPomodoroKey)
        UserDefaults.standard.set(todayStatsMarker(), forKey: Self.pomodoroStatsDateKey)
        persistFocusHistory()

        if !isPomodoroRunning {
            pomodoroStatusText = readyStatusText(for: pomodoroPhase)
        }
    }

    func setMenuBarOnlyMode(_ enabled: Bool) {
        isMenuBarOnlyModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.menuBarOnlyModeKey)
    }

    private func updatePomodoroIfNeeded() {
        synchronizeDailyStatsIfNeeded()

        guard isPomodoroRunning, let pomodoroEndDate else {
            return
        }

        let remaining = pomodoroEndDate.timeIntervalSinceNow
        if remaining <= 0 {
            completePomodoro()
            return
        }

        remainingPomodoroDuration = remaining
        refreshPomodoroDisplay()
    }

    private func completePomodoro() {
        pomodoroEndDate = nil
        isPomodoroRunning = false
        synchronizeDailyStatsIfNeeded()

        let alertTitle: String
        let alertBody: String

        switch pomodoroPhase {
        case .focus:
            completedPomodoroCount += 1
            completedTodayPomodoroCount += 1
            completedFocusSessionsInCycle += 1
            appendFocusHistoryRecord(at: Date())
            UserDefaults.standard.set(completedPomodoroCount, forKey: Self.completedPomodoroKey)
            UserDefaults.standard.set(completedTodayPomodoroCount, forKey: Self.completedTodayPomodoroKey)
            UserDefaults.standard.set(todayStatsMarker(), forKey: Self.pomodoroStatsDateKey)

            let nextPhase: PomodoroPhase = completedFocusSessionsInCycle.isMultiple(of: Self.sessionsBeforeLongBreak) ? .longBreak : .shortBreak
            pomodoroPhase = nextPhase
            remainingPomodoroDuration = nextPhase.duration
            pomodoroStatusText = nextPhase == .longBreak ? "已完成第 \(completedPomodoroCount) 个番茄钟，开始长休息前请放松一下" : "已完成第 \(completedPomodoroCount) 个番茄钟，准备进入 5 分钟休息"
            alertTitle = "番茄钟完成"
            alertBody = nextPhase == .longBreak ? "完成 4 个专注周期，接下来是 15 分钟长休息。" : "15 分钟专注已完成，接下来是 5 分钟短休息。"
        case .shortBreak, .longBreak:
            pomodoroPhase = .focus
            remainingPomodoroDuration = pomodoroPhase.duration
            pomodoroStatusText = "休息结束，准备开始下一轮 15 分钟专注"
            alertTitle = "休息结束"
            alertBody = "休息阶段已完成，可以开始下一轮专注。"
        }

        refreshPomodoroDisplay()
        playAlert()
        triggerFlashAlert()
        deliverNotification(title: alertTitle, body: alertBody)
    }

    private func refreshPomodoroDisplay() {
        let totalSeconds = max(0, Int(remainingPomodoroDuration.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        pomodoroDisplayText = String(format: "%02d:%02d", minutes, seconds)
        updateDockBadge()
    }

    private func playAlert() {
        NSSound.beep()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSSound.beep()
        }
    }

    private func triggerFlashAlert() {
        let flashSteps = 6
        for step in 0..<flashSteps {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(step) * 0.22)) { [weak self] in
                guard let self else {
                    return
                }

                withAnimation(.easeInOut(duration: 0.16)) {
                    self.isAlertVisible = step.isMultiple(of: 2)
                }

                if step == flashSteps - 1 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        self.isAlertVisible = false
                    }
                }
            }
        }
    }

    private func synchronizeDailyStatsIfNeeded() {
        let today = todayStatsMarker()
        let lastRecordedDate = UserDefaults.standard.string(forKey: Self.pomodoroStatsDateKey)
        if lastRecordedDate != today {
            completedTodayPomodoroCount = 0
            UserDefaults.standard.set(0, forKey: Self.completedTodayPomodoroKey)
            UserDefaults.standard.set(today, forKey: Self.pomodoroStatsDateKey)
        }
    }

    private func todayStatsMarker() -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private func readyStatusText(for phase: PomodoroPhase) -> String {
        switch phase {
        case .focus:
            return "准备开始 15 分钟专注"
        case .shortBreak:
            return "准备开始 5 分钟短休息"
        case .longBreak:
            return "准备开始 15 分钟长休息"
        }
    }

    private func pausedStatusText(for phase: PomodoroPhase) -> String {
        switch phase {
        case .focus:
            return "专注已暂停"
        case .shortBreak:
            return "短休息已暂停"
        case .longBreak:
            return "长休息已暂停"
        }
    }

    private func runningStatusText(for phase: PomodoroPhase) -> String {
        switch phase {
        case .focus:
            return "专注中"
        case .shortBreak:
            return "短休息中"
        case .longBreak:
            return "长休息中"
        }
    }

    private func requestNotificationAuthorization() {
        guard notificationsAvailable else {
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func deliverNotification(title: String, body: String) {
        guard notificationsAvailable else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    private func updateDockBadge() {
        NSApp.dockTile.badgeLabel = dockBadgeLabel
    }

    private func appendFocusHistoryRecord(at date: Date) {
        focusHistory.insert(FocusSessionRecord(completedAt: date), at: 0)
        persistFocusHistory()
    }

    private func persistFocusHistory() {
        guard let data = try? JSONEncoder().encode(focusHistory) else {
            return
        }

        UserDefaults.standard.set(data, forKey: Self.focusHistoryKey)
    }

    private static func loadFocusHistory() -> [FocusSessionRecord] {
        guard let data = UserDefaults.standard.data(forKey: focusHistoryKey),
              let records = try? JSONDecoder().decode([FocusSessionRecord].self, from: data) else {
            return []
        }

        return records.sorted { $0.completedAt > $1.completedAt }
    }

    private var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.firstWeekday = 2
        return calendar
    }

    private func historyInterval(for scope: HistoryScope, anchorDate: Date) -> DateInterval {
        switch scope {
        case .week:
            let weekInterval = calendar.dateInterval(of: .weekOfYear, for: anchorDate)
            return weekInterval ?? DateInterval(start: calendar.startOfDay(for: anchorDate), duration: 7 * 24 * 60 * 60)
        case .month:
            let monthInterval = calendar.dateInterval(of: .month, for: anchorDate)
            return monthInterval ?? DateInterval(start: calendar.startOfDay(for: anchorDate), duration: 31 * 24 * 60 * 60)
        }
    }

    private func storageDayString(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private func compactDayString(for date: Date, scope: HistoryScope) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = scope == .week ? "E\nd" : "MM/dd"
        return formatter.string(from: date)
    }

    func dayString(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    func timeString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

struct ClockView: View {
    @ObservedObject var viewModel: ClockViewModel
    @State private var historyScope: HistoryScope = .week
    @State private var historyAnchorDate: Date = Date()

    var body: some View {
        GeometryReader { proxy in
            let scale = layoutScale(for: proxy.size)
            let panelWidth = min(max(proxy.size.width * 0.74, 420), 980)

            VStack(spacing: 24 * scale) {
                VStack(spacing: 10 * scale) {
                    Text(viewModel.displayText)
                        .font(.system(size: 68 * scale, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.97, green: 0.99, blue: 1.0))
                        .shadow(color: Color.black.opacity(0.35), radius: 10 * scale, x: 0, y: 4 * scale)
                        .textSelection(.enabled)

                    Text(viewModel.statusText)
                        .font(.system(size: 18 * scale, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.76, green: 0.90, blue: 1.0))
                }

                VStack(spacing: 16 * scale) {
                    Text(viewModel.pomodoroPhase.title)
                        .font(.system(size: 20 * scale, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.92))

                    Text(viewModel.pomodoroDisplayText)
                        .font(.system(size: 52 * scale, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 1.0, green: 0.89, blue: 0.62))

                    Text(viewModel.pomodoroStatusText)
                        .font(.system(size: 16 * scale, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.84))

                    HStack(spacing: 14 * scale) {
                        statCard(title: "今日完成", value: "\(viewModel.completedTodayPomodoroCount)", scale: scale)
                        statCard(title: "累计完成", value: "\(viewModel.completedPomodoroCount)", scale: scale)
                    }

                    HStack(spacing: 12 * scale) {
                        Button(viewModel.isPomodoroRunning ? "进行中" : viewModel.pomodoroPhase.actionTitle) {
                            viewModel.startPomodoro()
                        }
                        .buttonStyle(PomodoroButtonStyle(fillColor: Color(red: 0.27, green: 0.74, blue: 0.52), isDisabled: viewModel.isPomodoroRunning, scale: scale))
                        .disabled(viewModel.isPomodoroRunning)

                        Button("暂停") {
                            viewModel.pausePomodoro()
                        }
                        .buttonStyle(PomodoroButtonStyle(fillColor: Color(red: 0.93, green: 0.66, blue: 0.23), isDisabled: !viewModel.isPomodoroRunning, scale: scale))
                        .disabled(!viewModel.isPomodoroRunning)

                        Button("重置") {
                            viewModel.resetPomodoro()
                        }
                        .buttonStyle(PomodoroButtonStyle(fillColor: Color(red: 0.83, green: 0.34, blue: 0.37), isDisabled: false, scale: scale))
                    }

                    Button("清零统计") {
                        viewModel.clearStats()
                    }
                    .buttonStyle(PomodoroButtonStyle(fillColor: Color(red: 0.45, green: 0.53, blue: 0.73), isDisabled: false, scale: scale))
                }
                .padding(.horizontal, 26 * scale)
                .padding(.vertical, 22 * scale)
                .frame(width: panelWidth)
                .background(
                    RoundedRectangle(cornerRadius: 28 * scale, style: .continuous)
                        .fill(Color.black.opacity(0.22))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28 * scale, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: max(1, scale))
                )

                historyPanel(scale: scale, panelWidth: panelWidth)
            }
            .padding(.horizontal, 32 * scale)
            .padding(.vertical, 28 * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.08, green: 0.12, blue: 0.20),
                            Color(red: 0.10, green: 0.25, blue: 0.39),
                            Color(red: 0.04, green: 0.08, blue: 0.15)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    RadialGradient(
                        colors: [
                            Color(red: 0.22, green: 0.55, blue: 0.78).opacity(0.45),
                            .clear
                        ],
                        center: .topTrailing,
                        startRadius: 40 * scale,
                        endRadius: 280 * scale
                    )

                    if viewModel.isAlertVisible {
                        Color.white.opacity(0.88)
                            .ignoresSafeArea()
                            .transition(.opacity)
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: max(1, scale))
                    .padding(14 * scale)
            }
            .onAppear {
                viewModel.bootstrap()
            }
        }
    }

    private func statCard(title: String, value: String, scale: CGFloat) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.64))
            Text(value)
                .font(.system(size: 26 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.69, green: 0.94, blue: 0.85))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14 * scale)
        .background(
            RoundedRectangle(cornerRadius: 20 * scale, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private func historyPanel(scale: CGFloat, panelWidth: CGFloat) -> some View {
        let summaries = viewModel.historySummaries(for: historyScope, anchorDate: historyAnchorDate)
        let sections = viewModel.historySections(for: historyScope, anchorDate: historyAnchorDate)
        let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 10 * scale), count: historyScope == .week ? 7 : 4)

        return VStack(alignment: .leading, spacing: 14 * scale) {
            historyHeader(scale: scale)
            historyNavigation(scale: scale)
            historySummaryGrid(scale: scale, summaries: summaries, gridColumns: gridColumns)

            if sections.isEmpty {
                Text("当前范围内还没有完成记录，开始一个番茄钟后会在这里按周或按月回顾。")
                    .font(.system(size: 15 * scale, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.7))
            } else {
                historySectionList(scale: scale, sections: sections)
            }
        }
        .onChange(of: historyScope) { _ in
            historyAnchorDate = Date()
        }
        .padding(.horizontal, 22 * scale)
        .padding(.vertical, 20 * scale)
        .frame(width: panelWidth)
        .background(
            RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                .fill(Color.black.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24 * scale, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: max(1, scale))
        )
    }

    private func historyHeader(scale: CGFloat) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6 * scale) {
                Text("专注历史")
                    .font(.system(size: 20 * scale, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.92))

                Text(viewModel.historyPeriodTitle(for: historyScope, anchorDate: historyAnchorDate))
                    .font(.system(size: 14 * scale, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.64))
            }

            Spacer()

            Picker("历史范围", selection: $historyScope) {
                ForEach(HistoryScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 170 * scale)
        }
    }

    private func historyNavigation(scale: CGFloat) -> some View {
        HStack(spacing: 10 * scale) {
            Button {
                historyAnchorDate = viewModel.shiftedHistoryAnchor(from: historyAnchorDate, scope: historyScope, offset: -1)
            } label: {
                Label("上一段", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)

            Button {
                historyAnchorDate = Date()
            } label: {
                Text(historyScope == .week ? "回到本周" : "回到本月")
            }
            .buttonStyle(.borderless)

            Button {
                historyAnchorDate = viewModel.shiftedHistoryAnchor(from: historyAnchorDate, scope: historyScope, offset: 1)
            } label: {
                Label("下一段", systemImage: "chevron.right")
            }
            .buttonStyle(.borderless)
        }
        .font(.system(size: 13 * scale, weight: .medium, design: .rounded))
        .foregroundStyle(Color.white.opacity(0.82))
    }

    private func historySummaryGrid(scale: CGFloat, summaries: [HistoryDaySummary], gridColumns: [GridItem]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: 10 * scale) {
            ForEach(summaries) { summary in
                historySummaryCard(scale: scale, summary: summary)
            }
        }
    }

    private func historySummaryCard(scale: CGFloat, summary: HistoryDaySummary) -> some View {
        VStack(spacing: 8 * scale) {
            Text(summary.dayLabel)
                .font(.system(size: 12 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.68))
                .multilineTextAlignment(.center)

            Text("\(summary.count)")
                .font(.system(size: 20 * scale, weight: .bold, design: .rounded))
                .foregroundStyle(summary.count > 0 ? Color(red: 0.98, green: 0.89, blue: 0.64) : Color.white.opacity(0.42))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12 * scale)
        .background(
            RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                .fill(summary.count > 0 ? Color.white.opacity(0.10) : Color.white.opacity(0.04))
        )
    }

    private func historySectionList(scale: CGFloat, sections: [(day: String, date: Date, records: [FocusSessionRecord])]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16 * scale) {
                ForEach(sections, id: \.day) { section in
                    VStack(alignment: .leading, spacing: 10 * scale) {
                        HStack {
                            Text(section.day)
                                .font(.system(size: 16 * scale, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(red: 0.98, green: 0.89, blue: 0.64))
                            Spacer()
                            Text("\(section.records.count) 次")
                                .font(.system(size: 13 * scale, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.white.opacity(0.6))
                        }

                        ForEach(section.records) { record in
                            HStack {
                                Text(viewModel.timeString(for: record.completedAt))
                                    .font(.system(size: 14 * scale, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.white.opacity(0.85))
                                Spacer()
                                Text("15 分钟专注")
                                    .font(.system(size: 13 * scale, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color(red: 0.69, green: 0.94, blue: 0.85))
                            }
                            .padding(.horizontal, 14 * scale)
                            .padding(.vertical, 10 * scale)
                            .background(
                                RoundedRectangle(cornerRadius: 16 * scale, style: .continuous)
                                    .fill(Color.white.opacity(0.05))
                            )
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 220 * scale)
    }

    private func layoutScale(for size: CGSize) -> CGFloat {
        let widthScale = size.width / 640
        let heightScale = size.height / 420
        return min(max(min(widthScale, heightScale), 0.85), 1.65)
    }
}

struct MenuBarClockView: View {
    @ObservedObject var viewModel: ClockViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(viewModel.pomodoroPhase.title)
                .font(.system(size: 16, weight: .semibold, design: .rounded))

            Text(viewModel.pomodoroDisplayText)
                .font(.system(size: 32, weight: .bold, design: .monospaced))

            Text(viewModel.pomodoroStatusText)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button(viewModel.isPomodoroRunning ? "进行中" : viewModel.pomodoroPhase.actionTitle) {
                    viewModel.startPomodoro()
                }
                .disabled(viewModel.isPomodoroRunning)

                Button("暂停") {
                    viewModel.pausePomodoro()
                }
                .disabled(!viewModel.isPomodoroRunning)

                Button("重置") {
                    viewModel.resetPomodoro()
                }
            }

            Toggle("仅菜单栏运行", isOn: Binding(
                get: { viewModel.isMenuBarOnlyModeEnabled },
                set: { enabled in
                    viewModel.setMenuBarOnlyMode(enabled)
                    if enabled {
                        MainWindowController.hideMainWindow()
                    } else {
                        MainWindowController.showMainWindow(using: openWindow)
                    }
                }
            ))

            Button(viewModel.isMenuBarOnlyModeEnabled ? "显示主窗口" : "隐藏主窗口") {
                if viewModel.isMenuBarOnlyModeEnabled {
                    viewModel.setMenuBarOnlyMode(false)
                    MainWindowController.showMainWindow(using: openWindow)
                } else {
                    MainWindowController.hideMainWindow()
                }
            }

            Divider()

            Text("今日完成 \(viewModel.completedTodayPomodoroCount) 次")
                .font(.system(size: 13, weight: .medium, design: .rounded))

            if viewModel.latestHistoryPreview.isEmpty {
                Text("暂无专注记录")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.latestHistoryPreview) { record in
                    HStack {
                        Text(viewModel.timeString(for: record.completedAt))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                        Spacer()
                        Text("专注完成")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

private struct PomodoroButtonStyle: ButtonStyle {
    let fillColor: Color
    let isDisabled: Bool
    let scale: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16 * scale, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(isDisabled ? 0.55 : 0.96))
            .frame(minWidth: 84 * scale)
            .padding(.horizontal, 18 * scale)
            .padding(.vertical, 12 * scale)
            .background(
                Capsule(style: .continuous)
                    .fill(fillColor.opacity(isDisabled ? 0.35 : (configuration.isPressed ? 0.72 : 1.0)))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}