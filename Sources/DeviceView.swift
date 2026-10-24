import SwiftUI
import AppKit

/// The whole window, drawn as one device: screen and controls on the left, the four big keys on the right.
struct DeviceView: View {
    @StateObject private var model = AppModel()
    @State private var deleting = false
    private let logo = Bundled.image("touchwood-logo-light")
    private let grille = Bundled.image("touchwood-mark", template: true)
    private let caps: [Cap] = [.white, .grey, .dark, .white]

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            header
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 26) {
                    ScreenFrame(glow: model.ack != nil) { screen }
                    controls
                }
                .frame(width: 540)
                Spacer(minLength: 0)
                LazyVGrid(columns: [GridItem(.fixed(132), spacing: 32), GridItem(.fixed(132))], spacing: 28) {
                    ForEach(Array(keySpecs.enumerated()), id: \.offset) { item in DeviceKey(spec: item.element) }
                }
                .frame(width: 296)
            }
            Spacer(minLength: 0)
            footer
        }
        // The hidden title bar still takes 32 points above this; together the window is 1040 × 700.
        .padding(.horizontal, 52).padding(.top, 8).padding(.bottom, 32)
        .frame(width: 1040, height: 668)
        .background(Palette.body.ignoresSafeArea())
        .overlay(alignment: .topTrailing) { Screw(angle: -20).padding(.trailing, 20).offset(y: -12) }
        .overlay(alignment: .bottomLeading) { Screw(angle: 70).padding(20) }
        .overlay(alignment: .bottomTrailing) { Screw(angle: 10).padding(20) }
        .environment(\.colorScheme, .light)
        .onAppear { model.loadShortcuts() }
        .onDisappear { model.stop() }
        .confirmationDialog("Delete \(model.setup.name)?", isPresented: $deleting) {
            Button("Delete", role: .destructive) { model.deletePreset() }
        } message: {
            Text("Its buttons, actions and teaching are removed. This can't be undone.")
        }
    }

    // MARK: Body

    private var header: some View {
        HStack {
            if let logo {
                Image(nsImage: logo).resizable().aspectRatio(contentMode: .fit).frame(height: 22).accessibilityLabel("touchwood")
            } else {
                Text("touchwood").font(mono(17, .medium))
            }
            Spacer()
            HStack(spacing: 18) {
                Text(status.name).foregroundStyle(Palette.muted)
                HStack(spacing: 8) {
                    LED(state: status.led)
                    Text(status.word)
                }
            }
            .font(mono(12)).foregroundStyle(Palette.ink)
        }
        .frame(height: 24)
    }

    private var status: (name: String, led: LEDState, word: String) {
        let name = model.setup.name.lowercased()
        switch model.screen {
        case .welcome: return (model.hasSaved ? "no preset loaded" : "first run", .off, "mic off")
        case .home: return (name, model.listening ? .on : .off, model.listening ? "live" : "off")
        case .assign, .buttons: return (name, .blink, "editing")
        case .teach, .noise: return (name, .on, "teaching")
        case .check: return (name, .on, "checking")
        case .done: return (name, .on, "ready to save")
        }
    }

    private var controls: some View {
        HStack(alignment: .bottom) {
            HStack(spacing: 10) {
                ForEach(Array(fnSpecs.enumerated()), id: \.offset) { item in FunctionKey(spec: item.element) }
            }
            Spacer(minLength: 0)
            dial
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 14) {
                SlideSwitch(title: "press", left: "1x", right: "2x", isRight: model.setup.doubleTap,
                            enabled: [.home, .assign, .buttons].contains(model.screen)) {
                    if model.screen == .buttons { model.setup.doubleTap.toggle() } else { model.setGesture(double: !model.setup.doubleTap) }
                }
                SlideSwitch(title: "actions", left: "off", right: "on", isRight: model.actionsOn,
                            enabled: [.home, .assign].contains(model.screen)) {
                    model.actionsOn.toggle()
                }
            }
            // Out of the way while teaching and checking; the dial stays, since it moves the meter's line.
            .opacity(prompting ? 0.4 : 1)
        }
    }

    private var prompting: Bool { [.teach, .noise, .check].contains(model.screen) }

    @ViewBuilder private var dial: some View {
        if model.screen == .assign, let id = model.assigning {
            let kind = model.setup.buttons.first { $0.id == id }?.action?.kind ?? .nothing
            let index = Action.Kind.allCases.firstIndex(of: kind) ?? 0
            Dial(label: "dial", value: Double(index) / 5, readout: "\(index + 1)") { value, _ in model.dialKind(value) }
        } else {
            Dial(label: "sens", value: model.setup.sensitivity, readout: "\(Int((model.setup.sensitivity * 10).rounded()))",
                 enabled: model.screen != .welcome && model.screen != .done) { value, final in
                model.setSensitivity(value, final: final)
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .bottom) {
            Text(model.error ?? "touchwood · desk buttons · on-device · audio never saved")
                .font(mono(10)).foregroundStyle(model.error == nil ? Palette.muted : Palette.error)
                .lineLimit(2)
            Spacer()
            if let grille {
                Image(nsImage: grille).renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
                    .frame(height: 44).foregroundStyle(Palette.ink.opacity(0.4)).accessibilityHidden(true)
            }
        }
    }

    // MARK: Keys

    private var keySpecs: [KeySpec] {
        switch model.screen {
        case .welcome: return welcomeKeys
        case .done:
            return [
                KeySpec(label: "save", glyph: "✓", sub: "keep \(model.setup.name.lowercased())", cap: .orange, led: .on, action: model.save),
                KeySpec(label: "check", glyph: "↺", sub: "again", cap: .grey, action: model.startCheck),
                KeySpec(label: "retrain", glyph: "↻", sub: "teach again", cap: .white, action: model.startTeaching),
                KeySpec(label: "discard", glyph: "×", sub: "keep the old one", cap: .dark, action: model.cancel),
            ]
        default: return buttonKeys
        }
    }

    private var welcomeKeys: [KeySpec] {
        guard model.hasSaved else {
            return [KeySpec(label: "start", glyph: "▶", sub: "set up a desk", cap: .orange, led: .on, action: model.newPreset), KeySpec(), KeySpec(), KeySpec()]
        }
        let presets = model.library.presets
        let at = presets.firstIndex { $0.id == model.pickedPreset?.id } ?? 0
        let next = presets[(at + 1) % presets.count].name.lowercased()
        return [
            KeySpec(label: "use", glyph: "▶", sub: model.pickedPreset?.name.lowercased() ?? "", cap: .orange, led: .on, action: model.usePicked),
            KeySpec(label: "retrain", glyph: "↻", sub: "same buttons", cap: .grey, action: model.retrainPicked),
            KeySpec(label: "new", glyph: "+", sub: "preset", cap: .white, action: model.newPreset),
            KeySpec(label: "next", glyph: "↓", sub: presets.count > 1 ? "to \(next)" : "only one", cap: .dark, action: presets.count > 1 ? model.nextPreset : nil),
        ]
    }

    /// One key per desk button; the first free key adds one where that makes sense.
    private var buttonKeys: [KeySpec] {
        let buttons = model.setup.buttons
        return (0..<4).map { i in
            guard i < buttons.count else {
                guard i == buttons.count, model.screen == .home || model.screen == .buttons,
                      let next = Setup.defaults.first(where: { d in !buttons.contains { $0.id == d.id } }) else { return KeySpec() }
                return KeySpec(label: "add", glyph: "+", sub: "button \(next.id.lowercased())", cap: .empty, help: "add a button; it needs teaching",
                               action: model.screen == .home ? model.addFromHome : model.addButton)
            }
            let button = buttons[i], id = button.id
            var spec = KeySpec(label: button.name.lowercased(), glyph: id.lowercased(), cap: caps[i])
            spec.down = model.lit == id
            switch model.screen {
            case .home:
                spec.sub = button.action?.short ?? "lights only"
                spec.led = model.lit == id ? .on : model.armed == id ? .blink : .off
                spec.help = "set what \(button.name) does"
                spec.action = { model.assign(id) }
            case .assign:
                spec.sub = button.action?.short ?? "lights only"
                spec.led = model.assigning == id ? .blink : model.lit == id ? .on : .off
                spec.action = { model.assigning == id ? model.finishAssign() : model.assign(id) }
            case .buttons:
                spec.sub = model.selected == id ? "selected" : "select"
                spec.led = model.selected == id ? .on : .off
                spec.down = false
                spec.action = { model.selected = id }
            case .teach:
                // The screen alone says where to tap; a key only lights when its spot counts.
                spec.sub = "\(model.taught[id] ?? 0) / \(AppModel.tapsPerButton)"
                spec.led = model.lit == id ? .on : .off
            case .check:
                spec.sub = button.action?.short ?? ""
                spec.led = model.lit == id ? .on : .off
            default:
                break
            }
            return spec
        }
    }

    private var fnSpecs: [FnSpec] {
        switch model.screen {
        case .welcome:
            let any = model.hasSaved
            return [
                FnSpec(label: "next", action: model.library.presets.count > 1 ? model.nextPreset : nil),
                FnSpec(label: "teach", action: any ? model.retrainPicked : nil),
                FnSpec(label: "check", action: any ? model.checkPicked : nil),
                FnSpec(label: "edit", action: any ? model.editPicked : nil),
            ]
        case .home:
            return [FnSpec(label: "preset", action: model.toWelcome), FnSpec(label: "teach", action: model.startTeaching),
                    FnSpec(label: "check", action: model.startCheck), FnSpec(label: "edit", action: model.editButtons)]
        case .assign:
            return [FnSpec(label: "back", action: model.finishAssign), FnSpec(label: "teach"), FnSpec(label: "check"),
                    FnSpec(label: "edit", led: .on, action: model.finishAssign)]
        case .buttons:
            return [FnSpec(label: "back", action: model.cancel), FnSpec(label: "teach", led: model.canSaveEdits ? .off : .blink, action: model.startTeaching),
                    FnSpec(label: "check"), FnSpec(label: "edit", led: .on)]
        case .teach, .noise:
            return [FnSpec(label: "back", action: model.cancel), FnSpec(label: "teach", led: .on), FnSpec(label: "check"), FnSpec(label: "edit")]
        case .check:
            return [FnSpec(label: "back", action: model.cancel), FnSpec(label: "teach"), FnSpec(label: "check", led: .on), FnSpec(label: "edit")]
        case .done:
            return [FnSpec(label: "back"), FnSpec(label: "teach"), FnSpec(label: "check", led: .on), FnSpec(label: "edit")]
        }
    }

    // MARK: Screen

    @ViewBuilder private var screen: some View {
        switch model.screen {
        case .welcome: welcomeScreen
        case .home: liveScreen
        case .assign: assignScreen
        case .buttons: buttonsScreen
        case .teach: teachScreen
        case .noise: noiseScreen
        case .check: checkScreen
        case .done: doneScreen
        }
    }

    private func topLine(_ left: String, _ right: String) -> some View {
        HStack {
            Text(left)
            Spacer()
            Text(right)
        }
        .font(mono(11)).foregroundStyle(Palette.lcdDim)
    }

    private func legend(_ items: [String]) -> some View {
        HStack(spacing: 20) { ForEach(items, id: \.self) { Text($0) } }
            .font(mono(11)).foregroundStyle(Palette.lcdDim)
    }

    private var welcomeScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom) {
                DotText(text: "hello.", pitch: 6.3)
                Spacer()
                Text(model.hasSaved ? "\(model.library.presets.count) preset\(model.library.presets.count == 1 ? "" : "s") on this mac" : "no presets yet")
                    .font(mono(11)).foregroundStyle(Palette.lcdDim)
            }
            if model.hasSaved {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(model.library.presets.enumerated()), id: \.element.id) { item in presetRow(item.offset, item.element) }
                    }
                }
                .frame(maxHeight: 128)
                Spacer(minLength: 0)
                if let preset = model.pickedPreset, !preset.input.isEmpty, preset.input != model.micName {
                    Text("▲ \(preset.name.lowercased()) was taught on \(preset.input.lowercased()). retrain first.")
                        .font(mono(11)).foregroundStyle(Palette.warn).lineLimit(2)
                }
                legend(["a use", "b retrain", "c new", "d next"])
            } else {
                Text("turn spots on your desk into buttons.\nsetup takes about two minutes.")
                    .font(mono(13)).foregroundStyle(Palette.lcdMid).lineSpacing(4)
                Spacer(minLength: 0)
                legend(["a start"])
            }
        }
    }

    private func presetRow(_ index: Int, _ preset: Setup) -> some View {
        let on = preset.id == model.pickedPreset?.id
        let mismatch = !preset.input.isEmpty && preset.input != model.micName
        return Button { model.picked = preset.id } label: {
            HStack(spacing: 16) {
                Text("\(index + 1)")
                Text(preset.name.lowercased()).lineLimit(1)
                Spacer()
                if mismatch { Text("▲ mic").foregroundStyle(on ? Color(hex: 0xB34F00) : Palette.warn) }
                Text("\(preset.buttons.count) btn · \(preset.doubleTap ? "2x" : "1x")")
            }
            .font(mono(14))
            .foregroundStyle(on ? Palette.screen : Palette.lcd)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(on ? Palette.lcd : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var liveScreen: some View {
        let mismatch = !model.setup.input.isEmpty && model.setup.input != model.micName
        let headline = model.headline ?? (model.requesting ? "wait" : !model.listening ? "off" : !model.warm ? "quiet" : "ready")
        let idle = model.requesting ? "allow the microphone"
            : !model.listening ? "not listening. press preset to pick a desk."
            : !model.warm ? "measuring room noise. keep quiet."
            : mismatch ? "taught on \(model.setup.input.lowercased()). retrain for best results."
            : "\(model.setup.doubleTap ? "double tap" : "tap") a spot. click a key to set what it does."
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(model.setup.name.lowercased())
                Spacer()
                Text("\(model.listening ? "live" : "off") · \(model.setup.doubleTap ? "2x" : "1x")")
                MicBars(level: model.level)
            }
            .font(mono(11)).foregroundStyle(Palette.lcdDim)
            DeskMap(buttons: model.setup.buttons, lit: model.lit, armed: model.armed)
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    DotText(text: String(headline.prefix(16)), pitch: 4.8)
                    Text(model.message ?? idle).font(mono(12))
                        .foregroundStyle(model.message == nil && mismatch ? Palette.warn : Palette.lcdMid).lineLimit(2)
                }
                Spacer()
                if let at = model.lastPress {
                    Text(at, format: .dateTime.hour().minute()).font(mono(11)).foregroundStyle(Palette.lcdDim)
                }
            }
        }
    }

    @ViewBuilder private var assignScreen: some View {
        if let id = model.assigning, let index = model.setup.buttons.firstIndex(where: { $0.id == id }) {
            let button = model.setup.buttons[index]
            let kind = button.action?.kind ?? .nothing
            VStack(alignment: .leading, spacing: 14) {
                topLine("edit · button \(id.lowercased())", "turn the dial · press \(id.lowercased()) to finish")
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        DotText(text: id, pitch: 13, color: Palette.orange)
                        Text(button.name.lowercased()).font(mono(14)).foregroundStyle(Palette.lcd).lineLimit(1)
                    }
                    .frame(width: 110, alignment: .leading)
                    VStack(spacing: 3) {
                        ForEach(Action.Kind.allCases) { option in
                            Button {
                                guard option != kind else { return }
                                model.setAction(id, Action.blank(option))
                                if option == .app || option == .file { DispatchQueue.main.async { model.choose(option, for: id) } }
                            } label: {
                                HStack {
                                    Text(option.label)
                                    Spacer()
                                    if option == kind { Text("◀") }
                                }
                                .font(mono(13))
                                .foregroundStyle(option == kind ? Palette.screen : Palette.lcd)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(option == kind ? Palette.lcd : .clear, in: RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    actionDetail(id, button.action)
                    Spacer(minLength: 0)
                    if button.action != nil {
                        Button("try") { model.runAction(of: id) }.buttonStyle(ScreenPill())
                    }
                }
            }
        }
    }

    @ViewBuilder private func actionDetail(_ id: String, _ action: Action?) -> some View {
        let label: (String) -> Text = { Text($0).font(mono(12)).foregroundStyle(Palette.lcdDim) }
        switch action {
        case nil:
            label("the key only lights")
        case .screenshot(let mode):
            label("save to")
            ForEach(Action.Screenshot.allCases, id: \.self) { option in
                Button(option.title.lowercased()) { model.setAction(id, .screenshot(option)) }.buttonStyle(ScreenPill(on: option == mode))
            }
        case .app(let path), .file(let path):
            label(action?.kind == .app ? "app" : "file")
            Text(path.isEmpty ? "nothing chosen" : Action.displayName(path).lowercased()).font(mono(13)).foregroundStyle(Palette.lcd).lineLimit(1)
            Button("choose…") { model.choose(action!.kind, for: id) }.buttonStyle(ScreenPill())
        case .website(let url):
            label("address")
            TextField("example.com", text: Binding(get: { url }, set: { model.setAction(id, .website(url: $0)) }))
                .textFieldStyle(.plain).font(mono(13)).foregroundStyle(Palette.lcd).frame(width: 250)
                .overlay(alignment: .bottom) { Rectangle().fill(Palette.lcdFaint).frame(height: 1).offset(y: 4) }
        case .shortcut(let name):
            label("shortcut")
            if model.shortcutNames.isEmpty && name.isEmpty {
                Text("none found in shortcuts").font(mono(13)).foregroundStyle(Palette.lcdMid)
            } else {
                Menu {
                    ForEach(model.shortcutNames, id: \.self) { option in Button(option) { model.setAction(id, .shortcut(name: option)) } }
                } label: {
                    Text(name.isEmpty ? "choose…" : name.lowercased()).font(mono(13))
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
    }

    @ViewBuilder private var buttonsScreen: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("edit ·").foregroundStyle(Palette.lcdDim)
                TextField("preset name", text: $model.setup.name).textFieldStyle(.plain).foregroundStyle(Palette.lcd).frame(width: 200)
                Spacer()
                Text("drag the spots").foregroundStyle(Palette.lcdDim)
            }
            .font(mono(11))
            DeskMap(buttons: model.setup.buttons, selected: model.selected, move: model.move, select: { model.selected = $0 })
            Spacer(minLength: 0)
            if let i = model.setup.buttons.firstIndex(where: { $0.id == model.selected }) {
                HStack(spacing: 12) {
                    Text(model.setup.buttons[i].id.lowercased()).font(mono(13, .medium)).foregroundStyle(Palette.orange)
                    TextField("name", text: $model.setup.buttons[i].name).textFieldStyle(.plain).font(mono(13)).foregroundStyle(Palette.lcd).frame(width: 200)
                        .overlay(alignment: .bottom) { Rectangle().fill(Palette.lcdFaint).frame(height: 1).offset(y: 4) }
                    Spacer()
                    if model.setup.buttons.count > 2 {
                        Button("remove") { model.removeButton(model.setup.buttons[i].id) }.buttonStyle(ScreenPill())
                    }
                }
            }
            HStack {
                legend(["keys select", model.canSaveEdits ? "save keeps the teaching" : "teach to continue"])
                Spacer()
                if model.library.presets.contains(where: { $0.id == model.setup.id }) {
                    Button("delete preset") { deleting = true }.buttonStyle(ScreenPill())
                }
                if model.canSaveEdits {
                    Button("save") { model.saveEdits() }.buttonStyle(ScreenPill(on: true))
                }
            }
        }
    }

    // MARK: Teaching and checking

    // Instructions on these screens are plain sentences in the system font, larger than the device's labels.
    private func sentence(_ size: CGFloat) -> Font { .system(size: size, weight: size > 20 ? .semibold : .regular) }

    private var teachScreen: some View {
        promptScreen(left: "teach · \(model.setup.name.lowercased())", right: "\(model.done) of \(model.total)", verb: "Tap",
                     hint: model.done < 2 ? "One tap, then wait for the next spot." : "Move a little each time. Mix soft and firm taps.")
    }

    private var checkScreen: some View {
        let r = model.result
        return promptScreen(left: "check · \(min(r.right + r.wrong + 1, AppModel.checkPrompts)) of \(AppModel.checkPrompts)",
                            right: "right \(r.right) · wrong \(r.wrong) · missed \(r.unrecognized)",
                            verb: model.setup.doubleTap ? "Double tap" : "Tap",
                            hint: model.setup.doubleTap ? "Two quick taps, the way you'll use it." : "One tap, the way you'll use it.")
    }

    /// The desk with the spot to tap, one instruction under it, and the microphone level.
    private func promptScreen(left: String, right: String, verb: String, hint: String) -> some View {
        let line = subline(hint)
        return VStack(alignment: .leading, spacing: 6) {
            topLine(left, right)
            DeskMap(buttons: model.setup.buttons, lit: model.ack?.id, target: model.ack == nil ? model.prompt : nil, names: true)
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    instruction(verb)
                    Text(line.text).font(sentence(14)).foregroundStyle(line.warn ? Palette.warn : Palette.lcdMid)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                TapMeter(level: model.level, threshold: model.threshold).padding(.bottom, 5)
            }
        }
    }

    private func instruction(_ verb: String) -> some View {
        let text: Text
        if let ack = model.ack {
            text = Text(ack.text).foregroundStyle(ack.good ? Palette.lcd : Palette.warn)
        } else if let id = model.prompt {
            text = Text("\(verb) \(Text(model.name(id).lowercased()).foregroundStyle(Palette.orange))")
        } else {
            text = Text(model.requesting ? "Allow the microphone" : model.listening ? "Stay quiet" : "Not listening")
        }
        return text.font(sentence(28)).foregroundStyle(Palette.lcd).lineLimit(1).minimumScaleFactor(0.6)
    }

    private func subline(_ hint: String) -> (text: String, warn: Bool) {
        if model.ack != nil {
            return (model.prompt.map { "Next: \(model.name($0).lowercased())" } ?? "", false)
        }
        guard model.prompt != nil else {
            if model.requesting { return ("macOS is asking for access.", false) }
            if !model.listening { return (model.error ?? "", true) }
            let left = max(1, Int(ceil(3 - model.elapsed)))
            return ("Measuring the room. \(left) more second\(left == 1 ? "" : "s").", false)
        }
        if let message = model.message { return (message, true) }
        return (hint, false)
    }

    private var noiseScreen: some View {
        VStack(alignment: .leading, spacing: 6) {
            topLine("everyday noise", "\(model.noiseHeard) sound\(model.noiseHeard == 1 ? "" : "s") heard")
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Work as usual").font(sentence(28)).foregroundStyle(Palette.lcd)
                    Text("Type, click, set your mug down. Don't tap your buttons. Touchwood learns these sounds aren't presses.")
                        .font(sentence(14)).foregroundStyle(Palette.lcdMid).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 6) {
                    DotText(text: "\(Int(ceil(model.noiseLeft)))", pitch: 10)
                    Text("s").font(mono(14)).foregroundStyle(Palette.lcdDim)
                }
            }
            .padding(.top, 8)
            Spacer(minLength: 0)
            HStack(alignment: .center) {
                HStack(spacing: 4) {
                    ForEach(0..<Int(AppModel.noiseSeconds), id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Double(i) < AppModel.noiseSeconds - model.noiseLeft ? Palette.lcd : Palette.lcdOff)
                            .frame(width: 12, height: 12)
                    }
                }
                .accessibilityHidden(true)
                Spacer(minLength: 0)
                TapMeter(level: model.level, threshold: model.threshold)
            }
        }
    }

    private var doneScreen: some View {
        let check = model.setup.check ?? Setup.Check()
        let apart = model.report.map { "\(Int(($0.shapeScore * 100).rounded()))" } ?? "-"
        return VStack(alignment: .leading, spacing: 18) {
            topLine("check done", model.setup.name.lowercased())
            HStack(alignment: .top, spacing: 36) {
                stat("\(check.right)/\(check.right + check.wrong)", "right button", Palette.orange)
                stat("\(model.setup.falsePresses)", "false presses", Palette.lcd)
                stat(apart, "% apart", Palette.lcd)
            }
            Text(doneNote).font(mono(12)).foregroundStyle(Palette.lcdMid).lineSpacing(4)
            Spacer(minLength: 0)
            legend(["a save", "b check again", "c retrain", "d discard"])
        }
    }

    private func stat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DotText(text: value, pitch: 8.5, color: color)
            Text(label).font(mono(11)).foregroundStyle(Palette.lcdDim)
        }
    }

    private var doneNote: String {
        let check = model.setup.check ?? Setup.Check()
        let first: String
        switch model.report?.verdict {
        case .clear: first = "your buttons sound clearly different here."
        case .partial: first = "some taps get mixed up. move buttons apart."
        case .notSeparable: first = "these spots sound alike. try other surfaces."
        case .unclear: first = "loudness tells them apart too. retrain, soft and firm."
        case nil: first = ""
        }
        let second = model.setup.falsePresses > 0 ? "\(model.setup.falsePresses) everyday sounds would press a button."
            : check.unrecognized > check.right / 2 ? "\(check.unrecognized) taps weren't recognized. tap like you taught."
            : "none of your everyday sounds pressed a button."
        return first + "\n" + second
    }
}
