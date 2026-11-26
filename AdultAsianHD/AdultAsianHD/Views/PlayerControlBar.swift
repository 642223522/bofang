import SwiftUI

/// 画质选项（一行一个档）：label 显示用，line 切线用（直链才有；嵌入页没有画质入口）。
struct QualityOption: Identifiable, Hashable {
    /// 用 line.url 做 id（同一条线只出现一次）。
    let id: String
    /// 显示的档位，如 "1080p"、"720p"、"快速线"。
    let label: String
    let line: PlayLine
}

/// 从一条线路推导画质标签：名字/描述里找 4K/2160/1080/720/480/360/原画/超清/高清/标清，
/// 找不到就用线路名（如“快速线”）。
func qualityLabel(for line: PlayLine) -> String {
    let text = (line.name + " " + line.description).lowercased()
    if text.contains("4k") || text.contains("2160") { return "4K" }
    if text.contains("1080") { return "1080p" }
    if text.contains("720") { return "720p" }
    if text.contains("480") { return "480p" }
    if text.contains("360") { return "360p" }
    if text.contains("原画") { return "原画" }
    if text.contains("超清") { return "超清" }
    if text.contains("高清") { return "高清" }
    if text.contains("标清") { return "标清" }
    return line.name
}

/// 时间格式化：mm:ss，超 1 小时用 h:mm:ss；非法值显示 --:--。
func formatPlayerTime(_ seconds: Double) -> String {
    guard seconds.isFinite && seconds >= 0 else { return "--:--" }
    let total = Int(seconds)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}

// MARK: - 进度条

/// 自定义进度条：已播（白）/已缓冲（浅灰）/未播（深灰），圆点手柄；拖动跟手、点按可跳。
/// 拖动时只改本地显示位置（onScrub 只更新 UI 时间，不发 AVPlayer.seek），
/// 松手时 onScrubEnd 发唯一一次精确 seek；零时长时不启动拖动、不丢 onScrubEnd。
struct PlayerProgressSlider: View {
    var currentTime: Double
    var duration: Double
    var bufferedEnd: Double
    var onScrubStart: () -> Void
    var onScrub: (Double) -> Void
    var onScrubEnd: (Double) -> Void

    @State private var dragTime: Double? = nil
    @State private var isDragging = false
    /// 手势是否正在进行（SwiftUI 保证：手势被系统打断/取消时自动归 false，
    /// .onEnded 不触发也能兜底收尾，不再卡住 isDragging）。
    @GestureState private var gestureActive = false

    private var displayedTime: Double { dragTime ?? currentTime }
    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(displayedTime / duration, 0), 1)
    }
    private var bufferedProgress: Double {
        guard duration > 0 else { return 0 }
        return min(max(bufferedEnd / duration, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // 未播轨道
                Capsule().fill(Color.white.opacity(0.35)).frame(height: 4)
                // 已缓冲
                if bufferedProgress > 0 {
                    Capsule().fill(Color.white.opacity(0.55))
                        .frame(width: max(geo.size.width * bufferedProgress, 4), height: 4)
                }
                // 已播
                Capsule().fill(Color.white)
                    .frame(width: max(geo.size.width * progress, progress > 0 ? 4 : 0), height: 4)
                // 手柄
                Circle().fill(Color.white)
                    .frame(width: 12, height: 12)
                    .offset(x: geo.size.width * progress - 6)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .updating($gestureActive) { _, state, _ in
                        state = true
                    }
                    .onChanged { value in
                        guard duration > 0, geo.size.width > 0 else { return }
                        if !isDragging {
                            isDragging = true
                            dragTime = displayedTime
                            onScrubStart()
                        }
                        let ratio = min(max(value.location.x / geo.size.width, 0), 1)
                        let t = ratio * duration
                        dragTime = t
                        onScrub(t)
                    }
                    .onEnded { value in
                        guard isDragging else { return }
                        let t: Double
                        if duration > 0, geo.size.width > 0 {
                            let ratio = min(max(value.location.x / geo.size.width, 0), 1)
                            t = ratio * duration
                        } else {
                            t = dragTime ?? currentTime
                        }
                        dragTime = nil
                        isDragging = false
                        onScrubEnd(t)
                    }
            )
            // 系统打断拖动（来电/控制中心/旋转/视图消失）时 .onEnded 不触发，
            // @GestureState 会自动归 false，在此兜底收尾，防止播放器卡死在拖动态。
            .onChange(of: gestureActive) { _, active in
                if !active && isDragging {
                    let t = dragTime ?? currentTime
                    dragTime = nil
                    isDragging = false
                    onScrubEnd(t)
                }
            }
            .onDisappear {
                if isDragging {
                    let t = dragTime ?? currentTime
                    dragTime = nil
                    isDragging = false
                    onScrubEnd(t)
                }
            }
        }
        .frame(height: 28)
    }
}

// MARK: - 共用底条

/// 共用播放器底条（直链自定义播放器 + WebView 嵌入播放器同一套外观）：
/// 深色半透明底条；上行全宽进度条（已播/已缓冲），下行一排控制：
/// 播放/暂停、当前时间/总时间、（画质）、全屏、（关闭）。
/// 播放/暂停图标由调用方给的真实状态驱动（isPlaying=true 才显示“暂停”）。
struct PlayerControlBar: View {
    // 播放状态（真实状态驱动，不要用本地旗子猜）
    var isPlaying: Bool
    /// 正在缓冲（等数据）：区别于用户点的暂停；为 true 时不显示 ▶，改显示转圈 +“缓冲中”。
    /// 默认 false，WebView 播放器不传（它有自己的 statusText），直链播放器传 controller.isLoading。
    var isBuffering: Bool = false
    // 进度（showsProgress=false 时不显示进度条与时间，改显示 statusText）
    var currentTime: Double
    var duration: Double
    var bufferedEnd: Double
    var showsProgress: Bool
    // 画质（qualityLabel=nil 或选项少于 2 个时不显示画质按钮）
    var qualityLabel: String?
    var qualityOptions: [QualityOption]
    var onQualitySelected: ((QualityOption) -> Void)?
    // 全屏 / 关闭
    var isFullscreen: Bool
    var onFullscreen: () -> Void
    var onClose: (() -> Void)?
    // 状态文案（WebView 没探到 video 时显示，如“嵌入播放中”）
    var statusText: String?
    // 回调
    var onPlayPause: () -> Void
    var onScrubStart: () -> Void
    var onScrub: (Double) -> Void
    var onScrubEnd: (Double) -> Void

    var body: some View {
        VStack(spacing: 2) {
            if showsProgress {
                PlayerProgressSlider(
                    currentTime: currentTime,
                    duration: duration,
                    bufferedEnd: bufferedEnd,
                    onScrubStart: onScrubStart,
                    onScrub: onScrub,
                    onScrubEnd: onScrubEnd
                )
            }
            HStack(spacing: 12) {
                if showsProgress {
                    if isBuffering {
                        // 缓冲中：不要冒充暂停（▶ 会让人以为播停了、反复点播放）。
                        // 转圈 +“缓冲中”才是真实状态；数据到了会自动续播。
                        ProgressView()
                            .tint(.white)
                            .frame(width: 32, height: 32)
                    } else {
                        Button(action: onPlayPause) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.white)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if showsProgress {
                    Text(timeText)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(.white)
                    if isBuffering {
                        Text("缓冲中…")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.85))
                    }
                } else if let statusText {
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                }

                Spacer()

                if let qualityLabel, qualityOptions.count >= 2 {
                    Menu {
                        ForEach(qualityOptions) { opt in
                            Button {
                                onQualitySelected?(opt)
                            } label: {
                                HStack {
                                    Text(opt.label)
                                    if opt.label == qualityLabel {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Text(qualityLabel)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }

                Button(action: onFullscreen) {
                    Image(systemName: isFullscreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.6))
    }

    private var timeText: String {
        if duration > 0 {
            return "\(formatPlayerTime(currentTime)) / \(formatPlayerTime(duration))"
        }
        return formatPlayerTime(currentTime)
    }
}
