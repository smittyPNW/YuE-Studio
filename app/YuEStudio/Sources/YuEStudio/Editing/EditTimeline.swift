import SwiftUI

struct EditTimeline: View {
    @Bindable var model: EditController
    @State private var samples: [[Float]] = []
    @State private var dragStart: Int64?
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("\(time(model.viewStart)) – \(time(min(model.frames, model.viewStart + model.viewFrames)))").font(.caption).monospacedDigit().foregroundStyle(StudioTheme.muted)
                Spacer()
                Button("Zoom in", systemImage: "plus.magnifyingglass") { model.zoom(0.5) }.labelStyle(.iconOnly)
                Button("Zoom out", systemImage: "minus.magnifyingglass") { model.zoom(2) }.labelStyle(.iconOnly)
                Button("Selection") { model.zoomSelection() }.disabled(model.selection.isEmpty)
                Button("Fit") { model.fit() }
            }.controlSize(.small)
            GeometryReader { geometry in
                Canvas { context, size in draw(context: context, size: size) }
                    .background(StudioTheme.editor, in: .rect(cornerRadius: 10))
                    .contentShape(.rect)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let frame = at(value.location.x, width: geometry.size.width)
                        if dragStart == nil { dragStart = at(value.startLocation.x, width: geometry.size.width); model.transport.pause(); model.selectedClip = nil }
                        model.selectionStart = dragStart ?? frame; model.selectionEnd = frame
                    }.onEnded { value in
                        let frame = at(value.location.x, width: geometry.size.width)
                        model.transport.seek(abs(value.translation.width) < 3 ? frame : model.selection.lowerBound)
                        if abs(value.translation.width) < 3 { model.selectionStart = frame; model.selectionEnd = frame }
                        dragStart = nil
                    })
                    .accessibilityLabel("\(model.document?.channels == 2 ? "Stereo" : "Mono") waveform. Use the selection start and end fields for precise sample positions.")
                    .accessibilityValue("Selection \(model.selection.lowerBound) to \(model.selection.upperBound) samples")
            }
            if model.frames > model.viewFrames {
                Slider(value: Binding(get: { Double(model.viewStart) }, set: { model.viewStart = Int64($0) }), in: 0...Double(max(1, model.frames - model.viewFrames)))
                    .accessibilityLabel("Scroll waveform").controlSize(.mini)
            }
        }
        .disabled(model.busy)
        .task(id: "\(model.preview?.path ?? ""):\(model.viewStart):\(model.viewFrames)") {
            samples = []
            guard let url = model.preview, model.viewFrames <= 16384, model.frames > 0 else { return }
            let range = model.viewStart..<min(model.frames, model.viewStart + model.viewFrames)
            do {
                let result = try await Task.detached(priority: .utility) { try EditWaveform.samples(url, range: range) }.value
                guard !Task.isCancelled else { return }; samples = result
            } catch { if !Task.isCancelled { model.error = "Could not read waveform detail: \(error.localizedDescription)" } }
        }
    }
    private func at(_ x: CGFloat, width: CGFloat) -> Int64 {
        min(model.frames, max(0, model.viewStart + Int64((min(max(0, x), width) / max(1, width)) * Double(model.viewFrames))))
    }
    private func x(_ frame: Int64, width: CGFloat) -> CGFloat { CGFloat(frame - model.viewStart) / CGFloat(max(1, model.viewFrames)) * width }
    private func time(_ frame: Int64) -> String { String(format: "%.3f s", Double(frame) / model.rate) }
    private func draw(context: GraphicsContext, size: CGSize) {
        let channels = Int(model.document?.channels ?? 2), laneHeight = (size.height - 26) / CGFloat(channels)
        for tick in 0...8 {
            let px = size.width * CGFloat(tick) / 8
            var line = Path(); line.move(to: CGPoint(x: px, y: 24)); line.addLine(to: CGPoint(x: px, y: size.height))
            context.stroke(line, with: .color(StudioTheme.muted.opacity(0.12)), lineWidth: 1)
            if tick < 8 {
                let value = model.viewStart + model.viewFrames * Int64(tick) / 8
                context.draw(Text(time(value)).font(.caption2).foregroundStyle(StudioTheme.muted), at: CGPoint(x: px + 5, y: 11), anchor: .leading)
            }
        }
        for channel in 0..<channels {
            let mid = 26 + laneHeight * (CGFloat(channel) + 0.5), scale = laneHeight * 0.41
            var baseline = Path(); baseline.move(to: CGPoint(x: 0, y: mid)); baseline.addLine(to: CGPoint(x: size.width, y: mid))
            context.stroke(baseline, with: .color(StudioTheme.muted.opacity(0.25)), lineWidth: 1)
            var wave = Path()
            if samples.indices.contains(channel), !samples[channel].isEmpty {
                let values = samples[channel]
                for i in values.indices {
                    let point = CGPoint(x: CGFloat(i) / CGFloat(max(1, model.viewFrames)) * size.width, y: mid - CGFloat(values[i]) * scale)
                    if i == 0 { wave.move(to: point) } else { wave.addLine(to: point) }
                }
            } else if let waveform = model.waveform {
                let peaks = waveform.peaks(start: model.viewStart, end: min(model.frames, model.viewStart + model.viewFrames), pixels: max(1, Int(size.width)), channel: channel)
                for (i, peak) in peaks.enumerated() {
                    wave.move(to: CGPoint(x: CGFloat(i), y: mid - CGFloat(peak.high) * scale))
                    wave.addLine(to: CGPoint(x: CGFloat(i), y: mid - CGFloat(peak.low) * scale + 0.5))
                }
            }
            context.stroke(wave, with: .color(StudioTheme.highlight.opacity(0.9)), lineWidth: 1)
            context.draw(Text(channels == 1 ? "MONO" : (channel == 0 ? "L" : "R")).font(.caption2).bold().foregroundStyle(StudioTheme.muted), at: CGPoint(x: 10, y: mid - scale), anchor: .topLeading)
        }
        if !model.selection.isEmpty {
            let left = max(0, x(model.selection.lowerBound, width: size.width)), right = min(size.width, x(model.selection.upperBound, width: size.width))
            if right > left {
                let rect = CGRect(x: left, y: 25, width: right - left, height: size.height - 25)
                context.fill(Path(rect), with: .color(StudioTheme.accent.opacity(0.2)))
                context.stroke(Path(rect), with: .color(StudioTheme.highlight), lineWidth: 1)
            }
        }
        for marker in model.document?.markers ?? [] {
            let px = x(marker.frame, width: size.width)
            guard px >= 0 && px <= size.width else { continue }
            var line = Path(); line.move(to: CGPoint(x: px, y: 25)); line.addLine(to: CGPoint(x: px, y: size.height))
            context.stroke(line, with: .color(StudioTheme.muted), style: StrokeStyle(lineWidth: 1, dash: [3,3]))
            context.draw(Text(marker.name).font(.caption2).foregroundStyle(StudioTheme.ink), at: CGPoint(x: px + 4, y: 29), anchor: .topLeading)
        }
        let head = x(model.transport.frame, width: size.width)
        if head >= 0, head <= size.width {
            var line = Path(); line.move(to: CGPoint(x: head, y: 25)); line.addLine(to: CGPoint(x: head, y: size.height))
            context.stroke(line, with: .color(StudioTheme.ink), lineWidth: 1.5)
        }
    }
}

struct EditTransportBar: View {
    @Bindable var model: EditController
    var body: some View {
        HStack(spacing: 18) {
            Button(model.transport.playing ? "Pause" : "Play selection or song", systemImage: model.transport.playing ? "pause.fill" : "play.fill") { model.transport.toggle(selection: model.selection) }
                .labelStyle(.iconOnly).font(.title2).buttonStyle(.plain).frame(width: 48, height: 48)
                .background(StudioTheme.accent, in: .circle).foregroundStyle(.white).disabled(model.busy || model.frames == 0)
            Button("Go to start", systemImage: "backward.end") { model.transport.seek(0) }.labelStyle(.iconOnly).disabled(model.busy)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(model.transport.playing && !model.selection.isEmpty ? "Auditioning selection" : "Edited recording").font(.headline)
                    Spacer()
                    Text("\(String(format: "%.3f", Double(model.transport.frame) / model.rate)) / \(String(format: "%.3f", Double(model.frames) / model.rate)) s").font(.caption).monospacedDigit()
                }
                Slider(value: Binding(get: { Double(model.transport.frame) }, set: { model.transport.seek(Int64($0)) }), in: 0...Double(max(1, model.frames)))
                    .accessibilityLabel("Editor playhead").disabled(model.busy || model.frames == 0)
            }
            Toggle(isOn: $model.transport.loop) { Label("Loop", systemImage: "repeat") }.toggleStyle(.button).help("Repeat the current audition range")
            Slider(value: $model.transport.volume, in: 0...1).frame(width: 80).accessibilityLabel("Editor listening volume")
        }.padding(.horizontal, 24).padding(.vertical, 14).background(StudioTheme.sidebar)
    }
}
