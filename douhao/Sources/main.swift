import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Progressive Mode

enum ProgressiveMode: String, CaseIterable {
    case halve = "halve"
    case fixed = "fixed"

    var label: String {
        switch self {
        case .halve: return "每次减半"
        case .fixed: return "固定减少"
        }
    }
}

// MARK: - ViewModel

class TimerViewModel: ObservableObject {
    @Published var screenState: ScreenState = .idle
    @Published var intervalMinutes: Int = 60
    @Published var intervalSeconds: Int = 0
    @Published var remainingSeconds: Int = 0
    @Published var customMessage: String = "请休息一下"
    @Published var boundAppBundleID: String?
    @Published var boundAppName: String?
    @Published var todayUsageSeconds: Int = 0
    @Published var todayRestCount: Int = 0
    @Published var flowMode: Bool = false
    @Published var flowAlertThreshold: Int = 3
    @Published var autoResumeEnabled: Bool = true
    @Published var autoRestartOnContinue: Bool = false
    @Published var progressiveReminder: Bool = false
    @Published var progressiveMode: ProgressiveMode = .halve
    @Published var progressiveFixedMin: Int = 5
    @Published var progressiveFixedSec: Int = 0
    @Published var progressiveMinInterval: Int = 10
    @Published var periodMode: Bool = false
    private var consecutiveFlowCount: Int = 0
    var alertTriggeredAt: Date?

    private var timerStartDate: Date?

    init() {
        let defaults = UserDefaults.standard
        // Check day change
        let today = Self.todayKey()
        if let savedDay = defaults.string(forKey: "statDay"), savedDay == today {
            todayUsageSeconds = defaults.integer(forKey: "todayUsageSeconds")
            todayRestCount = defaults.integer(forKey: "todayRestCount")
        } else {
            defaults.set(today, forKey: "statDay")
            defaults.set(0, forKey: "todayUsageSeconds")
            defaults.set(0, forKey: "todayRestCount")
        }
        // Restore saved interval
        let savedMin = defaults.integer(forKey: "intervalMinutes")
        let savedSec = defaults.integer(forKey: "intervalSeconds")
        let savedMsg = defaults.string(forKey: "customMessage")
        if savedMin > 0 || savedSec > 0 {
            intervalMinutes = savedMin
            intervalSeconds = savedSec
        }
        if let msg = savedMsg, !msg.isEmpty {
            customMessage = msg
        }
        // Restore flow mode
        flowMode = defaults.bool(forKey: "flowMode")
        let savedThreshold = defaults.integer(forKey: "flowAlertThreshold")
        if savedThreshold > 0 {
            flowAlertThreshold = savedThreshold
        }
        // Restore auto-resume setting
        if defaults.object(forKey: "autoResumeEnabled") != nil {
            autoResumeEnabled = defaults.bool(forKey: "autoResumeEnabled")
        }
        autoRestartOnContinue = defaults.bool(forKey: "autoRestartOnContinue")
        progressiveReminder = defaults.bool(forKey: "progressiveReminder")
        if let raw = defaults.string(forKey: "progressiveMode"),
           let mode = ProgressiveMode(rawValue: raw) {
            progressiveMode = mode
        }
        let savedFixMin = defaults.integer(forKey: "progressiveFixedMin")
        let savedFixSec = defaults.integer(forKey: "progressiveFixedSec")
        let savedMinInt = defaults.integer(forKey: "progressiveMinInterval")
        if savedFixMin > 0 || savedFixSec > 0 {
            progressiveFixedMin = savedFixMin
            progressiveFixedSec = savedFixSec
        }
        if savedMinInt > 0 {
            progressiveMinInterval = savedMinInt
        }
        // Restore binding
        if let savedID = defaults.string(forKey: "boundAppBundleID"),
           !savedID.isEmpty {
            boundAppBundleID = savedID
            boundAppName = defaults.string(forKey: "boundAppName") ?? "未知"
            // Restore period mode only when binding exists
            periodMode = defaults.bool(forKey: "periodMode")
        } else {
            periodMode = false
            UserDefaults.standard.set(false, forKey: "periodMode")
        }
    }

    private static func todayKey() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func saveStats() {
        let defaults = UserDefaults.standard
        defaults.set(Self.todayKey(), forKey: "statDay")
        defaults.set(todayUsageSeconds, forKey: "todayUsageSeconds")
        defaults.set(todayRestCount, forKey: "todayRestCount")
    }

    /// 当系统日期变更时（午夜跨天），将今日统计清零
    func checkDayChange() {
        let today = Self.todayKey()
        let defaults = UserDefaults.standard
        if let savedDay = defaults.string(forKey: "statDay"), savedDay != today {
            todayUsageSeconds = 0
            todayRestCount = 0
            saveStats()
        }
    }

    private func addElapsedTime() {
        if let start = timerStartDate {
            let elapsed = Int(Date().timeIntervalSince(start))
            if elapsed > 0 {
                todayUsageSeconds += elapsed
                saveStats()
            }
        }
        timerStartDate = nil
    }

    func saveBinding(bundleID: String, name: String) {
        boundAppBundleID = bundleID
        boundAppName = name
        UserDefaults.standard.set(bundleID, forKey: "boundAppBundleID")
        UserDefaults.standard.set(name, forKey: "boundAppName")
    }

    func clearBinding() {
        boundAppBundleID = nil
        boundAppName = nil
        periodMode = false
        UserDefaults.standard.removeObject(forKey: "boundAppBundleID")
        UserDefaults.standard.removeObject(forKey: "boundAppName")
        UserDefaults.standard.set(false, forKey: "periodMode")
    }

    private var timer: Timer?
    private var alertSound: NSSound?
    // Track the running progressive interval
    private var _progressiveBaseSeconds: Int?
    private var hasProgressiveTriggered = false
    private var reachedProgressiveMin = false
    var onStateChange: ((ScreenState) -> Void)?
    var onFlowFlash: (() -> Void)?
    var onAlertDismissed: (() -> Void)?
    var cancelPostDismissFlow: (() -> Void)?

    enum ScreenState {
        case idle
        case running
        case alerting
        case periodAlerting
    }

    func startTimer() {
        cancelPostDismissFlow?()
        stopAlertSound()
        consecutiveFlowCount = 0
        alertTriggeredAt = nil
        let fullInterval = intervalMinutes * 60 + intervalSeconds
        if progressiveReminder && hasProgressiveTriggered {
            hasProgressiveTriggered = false
            if reachedProgressiveMin {
                reachedProgressiveMin = false
                _progressiveBaseSeconds = nil
                remainingSeconds = fullInterval
            } else {
                let base = _progressiveBaseSeconds ?? fullInterval
                _progressiveBaseSeconds = base
                switch progressiveMode {
                case .halve:
                    remainingSeconds = max(progressiveMinInterval, base / 2)
                case .fixed:
                    let reduce = progressiveFixedMin * 60 + progressiveFixedSec
                    remainingSeconds = max(progressiveMinInterval, base - reduce)
                }
                _progressiveBaseSeconds = remainingSeconds
                if remainingSeconds <= progressiveMinInterval {
                    reachedProgressiveMin = true
                }
            }
        } else {
            _progressiveBaseSeconds = nil
            remainingSeconds = fullInterval
        }
        timerStartDate = Date()
        screenState = .running
        onStateChange?(.running)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.remainingSeconds > 0 {
                self.remainingSeconds -= 1
            } else {
                self.triggerAlert()
            }
        }
    }

    func stopTimer() {
        cancelPostDismissFlow?()
        addElapsedTime()
        timer?.invalidate()
        timer = nil
        screenState = .idle
        remainingSeconds = 0
        consecutiveFlowCount = 0
        _progressiveBaseSeconds = nil
        hasProgressiveTriggered = false
        reachedProgressiveMin = false
        onStateChange?(.idle)
    }

    func triggerAlert() {
        addElapsedTime()
        todayRestCount += 1
        saveStats()
        alertTriggeredAt = Date()
        if periodMode {
            timer?.invalidate()
            timer = nil
            _progressiveBaseSeconds = nil
            hasProgressiveTriggered = false
            reachedProgressiveMin = false
            screenState = .periodAlerting
            onStateChange?(.periodAlerting)
            playAlertSound()
            return
        }
        if progressiveReminder {
            hasProgressiveTriggered = true
        }
        if flowMode {
            consecutiveFlowCount += 1
            if consecutiveFlowCount >= flowAlertThreshold {
                consecutiveFlowCount = 0
                _progressiveBaseSeconds = nil
                hasProgressiveTriggered = false
                reachedProgressiveMin = false
                timer?.invalidate()
                timer = nil
                screenState = .alerting
                onStateChange?(.alerting)
                playAlertSound()
                return
            }
            // Reset countdown in-place
            if progressiveReminder {
                let base = _progressiveBaseSeconds ?? (intervalMinutes * 60 + intervalSeconds)
                _progressiveBaseSeconds = base
                switch progressiveMode {
                case .halve:
                    remainingSeconds = max(progressiveMinInterval, base / 2)
                case .fixed:
                    let reduce = progressiveFixedMin * 60 + progressiveFixedSec
                    remainingSeconds = max(progressiveMinInterval, base - reduce)
                }
                _progressiveBaseSeconds = remainingSeconds
                if remainingSeconds <= progressiveMinInterval {
                    reachedProgressiveMin = true
                }
            } else {
                remainingSeconds = intervalMinutes * 60 + intervalSeconds
            }
            timerStartDate = Date()
            onFlowFlash?()
            return
        }
        if !progressiveReminder {
            _progressiveBaseSeconds = nil
        }
        timer?.invalidate()
        timer = nil
        screenState = .alerting
        onStateChange?(.alerting)
        playAlertSound()
    }

    func dismissAlert() {
        screenState = .idle
        remainingSeconds = 0
        alertTriggeredAt = nil
        alertSound?.stop()
        alertSound = nil
        consecutiveFlowCount = 0
        _progressiveBaseSeconds = nil
        reachedProgressiveMin = false
        onStateChange?(.idle)
        onAlertDismissed?()
    }

    func stopAlertSound() {
        alertSound?.stop()
        alertSound = nil
    }

    private func playAlertSound() {
        alertSound = NSSound(named: "Ping")
        alertSound?.loops = true
        alertSound?.play()
    }

    func timeString() -> String {
        let h = remainingSeconds / 3600
        let m = (remainingSeconds % 3600) / 60
        let s = remainingSeconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }

    func usageString() -> String {
        let h = todayUsageSeconds / 3600
        let m = (todayUsageSeconds % 3600) / 60
        if h > 0 {
            return "\(h)h \(m)m"
        } else {
            return "\(m)m"
        }
    }
}

// MARK: - Popover Content

// MARK: - Progressive Settings View

struct ProgressiveSettingsView: View {
    @ObservedObject var vm: TimerViewModel

    var body: some View {
        VStack(spacing: 10) {
            Text("渐进式提醒设置")
                .font(.system(size: 12, weight: .semibold))

            if vm.progressiveReminder {
                Picker("", selection: Binding(
                    get: { vm.progressiveMode },
                    set: { newValue in
                        vm.progressiveMode = newValue
                        UserDefaults.standard.set(newValue.rawValue, forKey: "progressiveMode")
                    }
                )) {
                    ForEach(ProgressiveMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()

                if vm.progressiveMode == .fixed {
                    HStack(spacing: 4) {
                        Text("每次减")
                            .font(.system(size: 11))
                        TextField("", text: Binding(
                            get: { String(vm.progressiveFixedMin) },
                            set: { newValue in
                                let filtered = newValue.filter { $0.isNumber }
                                if let num = Int(filtered), num >= 0 {
                                    vm.progressiveFixedMin = min(num, 999)
                                    UserDefaults.standard.set(vm.progressiveFixedMin, forKey: "progressiveFixedMin")
                                }
                            }
                        ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 30)
                            .font(.system(size: 11))
                            .multilineTextAlignment(.center)
                        Text("分")
                            .font(.system(size: 11))
                        TextField("", text: Binding(
                            get: { String(vm.progressiveFixedSec) },
                            set: { newValue in
                                let filtered = newValue.filter { $0.isNumber }
                                if let num = Int(filtered), num >= 0, num < 60 {
                                    vm.progressiveFixedSec = num
                                    UserDefaults.standard.set(num, forKey: "progressiveFixedSec")
                                }
                            }
                        ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 30)
                            .font(.system(size: 11))
                            .multilineTextAlignment(.center)
                        Text("秒")
                            .font(.system(size: 11))
                    }
                }

                HStack(spacing: 4) {
                    Text("最少间隔")
                        .font(.system(size: 11))
                    TextField("", text: Binding(
                        get: { String(vm.progressiveMinInterval / 60) },
                        set: { newValue in
                            let filtered = newValue.filter { $0.isNumber }
                            if let num = Int(filtered), num >= 0 {
                                let newMin = min(num, 999)
                                vm.progressiveMinInterval = newMin * 60 + (vm.progressiveMinInterval % 60)
                                UserDefaults.standard.set(vm.progressiveMinInterval, forKey: "progressiveMinInterval")
                            }
                        }
                    ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 30)
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                    Text("分")
                        .font(.system(size: 11))
                    TextField("", text: Binding(
                        get: { String(vm.progressiveMinInterval % 60) },
                        set: { newValue in
                            let filtered = newValue.filter { $0.isNumber }
                            if let num = Int(filtered), num >= 0, num < 60 {
                                vm.progressiveMinInterval = (vm.progressiveMinInterval / 60) * 60 + num
                                UserDefaults.standard.set(vm.progressiveMinInterval, forKey: "progressiveMinInterval")
                            }
                        }
                    ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 30)
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                    Text("秒")
                        .font(.system(size: 11))
                }
            }
        }
        .padding(14)
        .frame(width: 170)
        .fixedSize()
    }
}

// MARK: - Popover Content

struct PopoverContent: View {
    @ObservedObject var vm: TimerViewModel
    @State private var intervalText: String = "60"
    @State private var secondsText: String = "0"
    @State private var showProgressiveSettings = false
    @State private var showHelpTip = false

    var body: some View {
        VStack(spacing: 10) {
            switch vm.screenState {
            case .idle:
                idleView
            case .running:
                runningView
            case .alerting:
                alertingView
            case .periodAlerting:
                periodAlertingView
            }
        }
        .padding(14)
        .frame(width: 170)
        .fixedSize()
        .onAppear {
            intervalText = "\(vm.intervalMinutes)"
            secondsText = "\(vm.intervalSeconds)"
        }
    }

    func selectBoundApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.begin { response in
            if response == .OK, let url = panel.url {
                if let bundle = Bundle(url: url),
                   let bundleID = bundle.bundleIdentifier {
                    let name = url.deletingPathExtension().lastPathComponent
                    vm.saveBinding(bundleID: bundleID, name: name)
                }
            }
        }
    }

    var idleView: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                Button(action: { showHelpTip = true }) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showHelpTip, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("功能说明").font(.system(size: 12, weight: .semibold))
                        Divider()
                        Group {
                            Text("心流模式").font(.system(size: 10, weight: .semibold))
                            Text("倒计时到后先闪烁屏幕边缘，闪烁设定次数后才弹窗提醒")
                                .font(.system(size: 10)).lineLimit(nil)
                            Text("渐进式提醒").font(.system(size: 10, weight: .semibold))
                            Text("每次提醒后自动缩短倒计时间隔，让提醒越来越频繁")
                                .font(.system(size: 10)).lineLimit(nil)
                            Text("继续时自动重启计时").font(.system(size: 10, weight: .semibold))
                            Text("点击继续后自动开始新的倒计时")
                                .font(.system(size: 10)).lineLimit(nil)
                            Text("句号模式").font(.system(size: 10, weight: .semibold))
                            Text("倒计时到后弹窗显示5秒倒计时，到时间后自动强制关闭当前正在使用的应用")
                                .font(.system(size: 10)).lineLimit(nil)
                            Text("休息时检测活动").font(.system(size: 10, weight: .semibold))
                            Text("结束10秒后检测活动，闪烁蓝光后再检一次，两次均检测到则自动开始计时")
                                .font(.system(size: 10)).lineLimit(nil)
                        }
                        .foregroundColor(.secondary)
                    }
                    .padding(10)
                    .frame(width: 200)
                }

                Spacer()
                Text("逗号")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }

            HStack(spacing: 4) {
                Text("间隔:")
                    .font(.system(size: 11))
                TextField("分", text: $intervalText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 35)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .onChange(of: intervalText) { newValue in
                        let filtered = newValue.filter { $0.isNumber }
                        if filtered != newValue {
                            intervalText = filtered
                        }
                        if let num = Int(filtered), num >= 0 {
                            vm.intervalMinutes = min(num, 999)
                            UserDefaults.standard.set(vm.intervalMinutes, forKey: "intervalMinutes")
                        } else if filtered.isEmpty {
                            vm.intervalMinutes = 0
                            UserDefaults.standard.set(0, forKey: "intervalMinutes")
                        }
                    }
                Text("分")
                    .font(.system(size: 11))
                TextField("秒", text: $secondsText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 35)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .onChange(of: secondsText) { newValue in
                        let filtered = newValue.filter { $0.isNumber }
                        if filtered != newValue {
                            secondsText = filtered
                        }
                        if let num = Int(filtered), num >= 0, num < 60 {
                            vm.intervalSeconds = num
                            UserDefaults.standard.set(vm.intervalSeconds, forKey: "intervalSeconds")
                        } else if filtered.isEmpty {
                            vm.intervalSeconds = 0
                            UserDefaults.standard.set(0, forKey: "intervalSeconds")
                        }
                    }
                Text("秒")
                    .font(.system(size: 11))
            }

            HStack(spacing: 4) {
                Text("提醒:")
                    .font(.system(size: 11))
                TextField("请休息一下", text: Binding(
                    get: { vm.customMessage },
                    set: { newValue in
                        vm.customMessage = newValue
                        UserDefaults.standard.set(newValue, forKey: "customMessage")
                    }
                ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .font(.system(size: 11))
            }

            VStack(spacing: 3) {
                if let name = vm.boundAppName {
                    Text("绑定: \(name)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    HStack(spacing: 6) {
                        Button(action: selectBoundApp) {
                            Text("更改")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.link)
                        .controlSize(.small)
                        Button(action: { vm.clearBinding() }) {
                            Text("取消绑定")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.link)
                        .controlSize(.small)
                    }
                } else {
                    Button(action: selectBoundApp) {
                        Text("绑定App (自动开始)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 2) {
                Toggle(isOn: Binding(
                    get: { vm.flowMode },
                    set: { newValue in
                        vm.flowMode = newValue
                        UserDefaults.standard.set(newValue, forKey: "flowMode")
                    }
                )) {
                    Text("心流模式")
                        .font(.system(size: 10))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

            }

            if vm.flowMode {
                HStack(spacing: 4) {
                    Text("闪烁")
                        .font(.system(size: 10))
                    TextField("3", text: Binding(
                        get: { String(vm.flowAlertThreshold) },
                        set: { newValue in
                            let filtered = newValue.filter { $0.isNumber }
                            if let num = Int(filtered), num >= 1, num <= 99 {
                                vm.flowAlertThreshold = num
                                UserDefaults.standard.set(num, forKey: "flowAlertThreshold")
                            }
                        }
                    ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 30)
                        .font(.system(size: 10))
                        .multilineTextAlignment(.center)
                    Text("次后提醒")
                        .font(.system(size: 10))

                }
            }

            HStack(spacing: 4) {
                Toggle(isOn: Binding(
                    get: { vm.progressiveReminder },
                    set: { newValue in
                        vm.progressiveReminder = newValue
                        UserDefaults.standard.set(newValue, forKey: "progressiveReminder")
                    }
                )) {
                    Text("渐进式提醒")
                        .font(.system(size: 10))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        showProgressiveSettings.toggle()
                    }
                }) {
                    Image(systemName: showProgressiveSettings ? "gearshape.fill" : "gearshape")
                        .font(.system(size: 9))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

            }

            if showProgressiveSettings {
                ProgressiveSettingsView(vm: vm)
            }

            HStack(spacing: 2) {
                Toggle(isOn: Binding(
                    get: { vm.autoRestartOnContinue },
                    set: { newValue in
                        vm.autoRestartOnContinue = newValue
                        UserDefaults.standard.set(newValue, forKey: "autoRestartOnContinue")
                        if newValue {
                            vm.autoResumeEnabled = false
                            UserDefaults.standard.set(false, forKey: "autoResumeEnabled")
                        }
                    }
                )) {
                    Text("继续时自动重启计时")
                        .font(.system(size: 10))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

            }

            HStack(spacing: 2) {
                Toggle(isOn: Binding(
                    get: { vm.autoResumeEnabled },
                    set: { newValue in
                        vm.autoResumeEnabled = newValue
                        UserDefaults.standard.set(newValue, forKey: "autoResumeEnabled")
                        if newValue {
                            vm.autoRestartOnContinue = false
                            UserDefaults.standard.set(false, forKey: "autoRestartOnContinue")
                        }
                    }
                )) {
                    Text("休息时检测活动")
                        .font(.system(size: 10))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

            }

            Text("今日专注: \(vm.usageString()) | 休息 \(vm.todayRestCount) 次")
                .font(.system(size: 9))
                .foregroundColor(.secondary)

            Button(action: { vm.startTimer() }) {
                Text("▶  开始计时")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            HStack(spacing: 2) {
                Toggle(isOn: Binding(
                    get: { vm.periodMode },
                    set: { newValue in
                        vm.periodMode = newValue
                        UserDefaults.standard.set(newValue, forKey: "periodMode")
                    }
                )) {
                    Text("句号模式")
                        .font(.system(size: 10))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(vm.boundAppBundleID == nil)
            }
            if vm.boundAppBundleID == nil {
                Text("请先绑定App")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }

            Button(action: { NSApp.terminate(nil) }) {
                Text("退出逗号")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    var runningView: some View {
        VStack(spacing: 8) {
            Text("⌛ 倒计时中")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            Text(vm.timeString())
                .font(.system(size: 26, weight: .bold, design: .monospaced))

            Button(action: { vm.stopTimer() }) {
                Text("取消")
                    .font(.system(size: 11))
            }
            .buttonStyle(.link)
            .controlSize(.small)
        }
    }

    var alertingView: some View {
        VStack(spacing: 10) {
            Text("，")
                .font(.system(size: 36))

            Text("时间到！\n\(vm.customMessage)")
                .font(.system(size: 12, weight: .semibold))
                .multilineTextAlignment(.center)

            Button(action: { vm.dismissAlert() }) {
                Text("我知道了")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    var periodAlertingView: some View {
        VStack(spacing: 10) {
            Text("。")
                .font(.system(size: 36))

            Text("句号模式已触发\n即将强制关闭当前应用")
                .font(.system(size: 12, weight: .semibold))
                .multilineTextAlignment(.center)

            Button(action: { vm.dismissAlert() }) {
                Text("取消")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }
}

// MARK: - Alert Window

class AlertWindowController: NSWindowController {

    convenience init(message: String, restStartDate: Date, onAcknowledge: @escaping () -> Void, onContinue: @escaping () -> Void, onStop: @escaping () -> Void) {
        let contentView = AlertContentView(message: message, restStartDate: restStartDate, acknowledgeAction: onAcknowledge, continueAction: onContinue, stopAction: onStop)
        let hostingController = NSHostingController(rootView: contentView)
        let fitted = hostingController.view.fittingSize

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: fitted.width, height: fitted.height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.contentViewController = hostingController
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        // Center on screen
        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            let x = sf.midX - fitted.width / 2
            let y = sf.midY - fitted.height / 2
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.init(window: window)
    }

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct AlertContentView: View {
    let message: String
    let restStartDate: Date
    let acknowledgeAction: () -> Void
    let continueAction: () -> Void
    let stopAction: () -> Void
    @State private var acknowledged = false
    @State private var restSeconds: Int = 0
    let restTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            Text("，")
                .font(.system(size: 68))
                .frame(maxWidth: .infinity)
                .offset(y: -20)

            Text("时间到！\n\(message)")
                .font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.center)

            if !acknowledged {
                Button(action: {
                    acknowledgeAction()
                    acknowledged = true
                    restSeconds = Int(Date().timeIntervalSince(restStartDate))
                }) {
                    Text("我知道了")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                VStack(spacing: 6) {
                    Text("已休息 \(restTimeString())")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .onReceive(restTimer) { _ in
                    restSeconds = Int(Date().timeIntervalSince(restStartDate))
                }

                HStack(spacing: 8) {
                    Button(action: continueAction) {
                        Text("继续")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button(action: stopAction) {
                        Text("结束")
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(18)
        .frame(width: 180)
        .fixedSize()
    }

    func restTimeString() -> String {
        let m = restSeconds / 60
        let s = restSeconds % 60
        return "\(m)分\(s)秒"
    }
}

// MARK: - Period Alert Window

class PeriodAlertWindowController: NSWindowController {
    private var countdownTimer: Timer?
    private var countdownSeconds = 5

    convenience init(onCancel: @escaping () -> Void, onForceQuit: @escaping () -> Void) {
        let contentView = PeriodAlertContentView(
            onCancel: {
                onCancel()
            },
            onForceQuit: {
                onForceQuit()
            }
        )
        let hostingController = NSHostingController(rootView: contentView)
        let fitted = hostingController.view.fittingSize

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: fitted.width, height: fitted.height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.contentViewController = hostingController
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        // Center on screen
        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            let x = sf.midX - fitted.width / 2
            let y = sf.midY - fitted.height / 2
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.init(window: window)
    }

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct PeriodAlertContentView: View {
    let onCancel: () -> Void
    let onForceQuit: () -> Void
    @State private var countdownSeconds: Int = 5
    let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            Text("。")
                .font(.system(size: 68))
                .frame(maxWidth: .infinity)
                .offset(y: -20)

            Text("句号模式")
                .font(.system(size: 14, weight: .semibold))

            Text("即将强制关闭当前应用\n\(countdownSeconds) 秒后执行")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Text("\(countdownSeconds)")
                .font(.system(size: 48, weight: .bold, design: .monospaced))
                .foregroundColor(.red)
                .onReceive(countdownTimer) { _ in
                    if countdownSeconds > 0 {
                        countdownSeconds -= 1
                    }
                    if countdownSeconds <= 0 {
                        onForceQuit()
                    }
                }

            Button(action: { onCancel() }) {
                Text("取消")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(18)
        .frame(width: 200)
        .fixedSize()
    }
}

// MARK: - Status Bar Controller

class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var alertController: AlertWindowController?
    private var periodAlertController: PeriodAlertWindowController?
    let viewModel = TimerViewModel()

    // Comma icon image (loaded from bundle Resources)
    private lazy var commaImage: NSImage? = {
        guard let path = Bundle.main.path(forResource: "icon_comma", ofType: "png") else {
            return nil
        }
        let img = NSImage(contentsOfFile: path)
        // Scale to fit status bar comfortably (status bar is ~22pt tall)
        img?.size = NSSize(width: 18, height: 18)
        return img
    }()

    override init() {
        super.init()
        // Fixed width for icon display
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // Show comma character by default
            button.title = "，"
            button.font = NSFont.systemFont(ofSize: 14)
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Create popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 198, height: 400)
        popover.behavior = .transient
        let contentView = PopoverContent(vm: viewModel)
        popover.contentViewController = NSHostingController(rootView: contentView)

        // Observe state changes for alert
        viewModel.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.updateStatusBar(state: state)
                if state == .alerting {
                    self?.showAlertWindow()
                } else if state == .periodAlerting {
                    self?.showPeriodAlertWindow()
                } else {
                    self?.dismissAlertWindow()
                    self?.dismissPeriodAlertWindow()
                }
            }
        }

        // Flow flash callback
        viewModel.onFlowFlash = { [weak self] in
            self?.showFlowFlash()
        }

        // Watch for bound app launch
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )

        // Listen for system calendar day change (midnight) to reset daily stats
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDayChange(_:)),
            name: NSNotification.Name.NSCalendarDayChanged,
            object: nil
        )

        // Post-dismiss auto-resume: when user dismisses alert, wait 3 min then monitor input
        viewModel.onAlertDismissed = { [weak self] in
            self?.startPostDismissMonitor()
        }
        viewModel.cancelPostDismissFlow = { [weak self] in
            self?.cancelPostDismissMonitors()
        }

        // Listen for screen parameter changes to rebuild glow window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Start a timer to update status bar text while running
        startStatusBarUpdateTimer()
    }

    @objc private func appDidLaunch(_ notification: Notification) {
        guard viewModel.screenState == .idle,
              let boundID = viewModel.boundAppBundleID,
              let userInfo = notification.userInfo,
              let launchedBundleID = userInfo["NSApplicationBundleIdentifier"] as? String,
              launchedBundleID == boundID
        else { return }
        DispatchQueue.main.async { [weak self] in
            self?.viewModel.startTimer()
        }
    }

    @objc private func handleDayChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.viewModel.checkDayChange()
        }
    }

    private var statusUpdateTimer: Timer?
    private var postDismissTimer: Timer?
    private var activityMonitor: Timer?
    private var lastInputTime: TimeInterval?
    private var flashTimer: Timer?
    private var glowWindow: NSWindow?

    // Safe event type to capture any input
    private static let anyEventType = CGEventType(rawValue: UInt32.max)!

    // Factory: create or recreate glow window for current screen
    private func createGlowWindow() -> NSWindow {
        guard let screen = NSScreen.main else {
            return NSWindow()
        }
        let w = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = NSWindow.Level(rawValue: 103)
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.alphaValue = 0
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.contentView?.wantsLayer = true
        // 4 gradient edges: blue at screen edge → transparent inward (40pt wide)
        let frame = screen.frame
        let edgeWidth: CGFloat = 40
        let blue = NSColor.systemBlue.cgColor
        let clear = NSColor.clear.cgColor

        func makeEdgeLayer(rect: CGRect, startX: CGFloat, startY: CGFloat, endX: CGFloat, endY: CGFloat, name: String) -> CAGradientLayer {
            let layer = CAGradientLayer()
            layer.type = .axial
            layer.frame = rect
            layer.colors = [blue, clear]
            layer.locations = [0, 1]
            layer.startPoint = CGPoint(x: startX, y: startY)
            layer.endPoint = CGPoint(x: endX, y: endY)
            layer.name = name
            return layer
        }

        // Top edge
        let topRect = NSRect(x: 0, y: frame.height - edgeWidth, width: frame.width, height: edgeWidth)
        w.contentView?.layer?.addSublayer(makeEdgeLayer(rect: topRect, startX: 0.5, startY: 1, endX: 0.5, endY: 0, name: "edgeTop"))
        // Bottom edge
        let bottomRect = NSRect(x: 0, y: 0, width: frame.width, height: edgeWidth)
        w.contentView?.layer?.addSublayer(makeEdgeLayer(rect: bottomRect, startX: 0.5, startY: 0, endX: 0.5, endY: 1, name: "edgeBottom"))
        // Left edge
        let leftRect = NSRect(x: 0, y: 0, width: edgeWidth, height: frame.height)
        w.contentView?.layer?.addSublayer(makeEdgeLayer(rect: leftRect, startX: 0, startY: 0.5, endX: 1, endY: 0.5, name: "edgeLeft"))
        // Right edge
        let rightRect = NSRect(x: frame.width - edgeWidth, y: 0, width: edgeWidth, height: frame.height)
        w.contentView?.layer?.addSublayer(makeEdgeLayer(rect: rightRect, startX: 1, startY: 0.5, endX: 0, endY: 0.5, name: "edgeRight"))

        return w
    }
    private func ensureGlowWindow() -> NSWindow {
        if let w = glowWindow { return w }
        let w = createGlowWindow()
        glowWindow = w
        return w
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        glowWindow?.orderOut(nil)
        glowWindow = nil
    }

    private func startStatusBarUpdateTimer() {
        guard statusUpdateTimer == nil else { return }
        statusUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.viewModel.screenState == .running {
                self.updateRunningDisplay()
            }
        }
    }

    private func stopStatusBarUpdateTimer() {
        statusUpdateTimer?.invalidate()
        statusUpdateTimer = nil
    }

    private func updateRunningDisplay() {
        guard let button = statusItem.button else { return }
        // Use SF Symbols hourglass + time text
        let funnelImage = NSImage(
            systemSymbolName: "funnel.fill",
            accessibilityDescription: "funnel"
        )
        funnelImage?.size = NSSize(width: 10, height: 11)
        button.image = funnelImage
        button.title = " \(viewModel.timeString())"
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.imagePosition = .imageLeading
    }

    private func updateStatusBar(state: TimerViewModel.ScreenState) {
        guard let button = statusItem.button else { return }
        switch state {
        case .idle:
            button.image = nil
            button.title = "，"
            button.font = NSFont.systemFont(ofSize: 14)
            stopStatusBarUpdateTimer()
        case .running:
            updateRunningDisplay()
            startStatusBarUpdateTimer()
        case .alerting:
            let bellImage = NSImage(
                systemSymbolName: "bell",
                accessibilityDescription: "bell"
            )
            bellImage?.size = NSSize(width: 10, height: 11)
            button.image = bellImage
            button.title = ""
            button.imagePosition = .imageOnly
            stopStatusBarUpdateTimer()
        case .periodAlerting:
            let stopImage = NSImage(
                systemSymbolName: "stop.circle.fill",
                accessibilityDescription: "stop"
            )
            stopImage?.size = NSSize(width: 12, height: 12)
            button.image = stopImage
            button.title = ""
            button.imagePosition = .imageOnly
            stopStatusBarUpdateTimer()
        }
    }

    @objc private func togglePopover() {
        if viewModel.screenState == .alerting || viewModel.screenState == .periodAlerting {
            showAlertWindow()
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            if let button = statusItem.button {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    private func showAlertWindow() {
        popover.performClose(nil)
        dismissAlertWindow()
        alertController = AlertWindowController(
            message: viewModel.customMessage,
            restStartDate: viewModel.alertTriggeredAt ?? Date(),
            onAcknowledge: { [weak self] in
                self?.viewModel.stopAlertSound()
            },
            onContinue: { [weak self] in
                self?.dismissAlertWindow()
                if self?.viewModel.autoRestartOnContinue == true {
                    self?.viewModel.startTimer()
                } else {
                    self?.viewModel.dismissAlert()
                }
            },
            onStop: { [weak self] in
                self?.dismissAlertWindow()
                self?.viewModel.dismissAlert()
            }
        )
        alertController?.showWindow(nil)
        alertController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dismissAlertWindow() {
        alertController?.close()
        alertController = nil
    }

    private func showPeriodAlertWindow() {
        popover.performClose(nil)
        dismissPeriodAlertWindow()
        periodAlertController = PeriodAlertWindowController(
            onCancel: { [weak self] in
                self?.dismissPeriodAlertWindow()
                self?.viewModel.dismissAlert()
            },
            onForceQuit: { [weak self] in
                self?.dismissPeriodAlertWindow()
                // Force quit only the bound application
                if let bundleID = self?.viewModel.boundAppBundleID,
                   let targetApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                    targetApp.forceTerminate()
                }
                self?.viewModel.dismissAlert()
            }
        )
        periodAlertController?.showWindow(nil)
        periodAlertController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dismissPeriodAlertWindow() {
        periodAlertController?.close()
        periodAlertController = nil
    }

    // MARK: - Post-Dismiss Auto-Resume

    private func cancelPostDismissMonitors() {
        postDismissTimer?.invalidate()
        postDismissTimer = nil
        activityMonitor?.invalidate()
        activityMonitor = nil
        lastInputTime = nil
    }

    private func startPostDismissMonitor() {
        guard viewModel.autoResumeEnabled else { return }
        cancelPostDismissMonitors()
        // Wait 10 seconds before first activity check
        postDismissTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self = self, self.viewModel.screenState == .idle else { return }
            self.firstActivityCheck()
        }
    }

    private func firstActivityCheck() {
        activityMonitor?.invalidate()
        lastInputTime = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyEventType)

        activityMonitor = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.viewModel.screenState == .idle else {
                self.cancelPostDismissMonitors()
                return
            }
            let current = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyEventType)
            if let last = self.lastInputTime, current < last {
                // First activity detected — show glow and wait 10s for second check
                self.cancelPostDismissMonitors()
                DispatchQueue.main.async {
                    self.showFlowFlash()
                }
                self.postDismissTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
                    guard let self = self, self.viewModel.screenState == .idle else { return }
                    self.secondActivityCheck()
                }
                return
            }
            self.lastInputTime = current
        }
    }

    private func secondActivityCheck() {
        activityMonitor?.invalidate()
        lastInputTime = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyEventType)

        activityMonitor = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.viewModel.screenState == .idle else {
                self.cancelPostDismissMonitors()
                return
            }
            let current = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyEventType)
            if let last = self.lastInputTime, current < last {
                // Second activity detected — start timer
                self.cancelPostDismissMonitors()
                DispatchQueue.main.async {
                    self.viewModel.startTimer()
                    self.showResumeNotification()
                }
                return
            }
            self.lastInputTime = current
        }
    }

    private func showResumeNotification() {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.title = "▶ 已开始计时"
        button.font = NSFont.systemFont(ofSize: 11)
        button.imagePosition = .imageLeft
        // Revert to normal running display after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, self.viewModel.screenState == .running else { return }
            self.updateRunningDisplay()
        }
    }

    private func showFlowFlash() {
        flashTimer?.invalidate()
        let w = ensureGlowWindow()
        w.alphaValue = 0
        w.orderFront(nil)

        // Smooth sine-wave pulse at 60fps — 3 pulses × 0.8s = 2.4s total
        let startTime = Date()
        let newTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            let elapsed = Date().timeIntervalSince(startTime)
            let totalDuration: TimeInterval = 2.4
            if elapsed >= totalDuration {
                timer.invalidate()
                w.alphaValue = 0
                w.orderOut(nil)
                return
            }
            // Sine wave: 3 full cycles (0→1→0) over 2.4s
            let pulseProgress = (elapsed / 0.8).truncatingRemainder(dividingBy: 1.0)
            let brightness = sin(pulseProgress * .pi)
            w.alphaValue = brightness * 0.50
        }
        newTimer.tolerance = 0
        self.flashTimer = newTimer
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController()
        // Hide from Dock — pure menu bar app
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()