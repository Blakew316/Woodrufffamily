import UIKit
import AVFoundation
import AVKit
import WoodruffKit

/// The picture: a view whose layer is the display layer the app's own player decodes into.
final class FilmPictureView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var display: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

/// What the film's screen says about it in words.
struct FilmCard {
    /// A film's name; an episode's show.
    var title: String
    /// Over the title: a film's year; an episode's season, number and name.
    var line: String?
    /// In Info, under the title: the year and the genres.
    var facts: String?
    var story: String?
}

/// Where everything on the film's screen sits, measured from Apple's player on an Apple TV (1920 × 1080 points):
/// the title's and the line's baselines, the bar's middle and the pills, each from the bottom edge.
private enum Place {
    static let side: CGFloat = 80
    static let pillBottom: CGFloat = 60
    static let pillHeight: CGFloat = 64
    static let barMiddle: CGFloat = 178
    static let titleBaseline: CGFloat = 232
    static let lineBaseline: CGFloat = 310
    static let round: CGFloat = 68
    static let roundGap: CGFloat = 22
    static let titleFont = UIFont.systemFont(ofSize: 57, weight: .bold)
    static let lineFont = UIFont.systemFont(ofSize: 29, weight: .semibold)
    static let pillFont = UIFont.systemFont(ofSize: 26, weight: .semibold)
    static let timeFont = UIFont.monospacedDigitSystemFont(ofSize: 29, weight: .semibold)
}

/// The film's bar: how far it has played, the playhead, the time under it and the time left at its end.
///
/// It holds the remote's focus whenever the focus isn't on a button, also while the controls are out of sight (it
/// draws nothing then): the remote's presses come to whatever has the focus.
final class FilmBar: UIView {
    /// The film's length and where it is, in seconds; where the playhead has been moved to and not yet gone to.
    var length = 0.0
    var time = 0.0
    var moved: Double?
    var paused = false
    /// The controls are out of sight.
    var quiet = true { didSet { if quiet != oldValue { alphaAll(quiet ? 0 : 1) } } }

    private let track = UIView()
    private let fill = UIView()
    private let head = UIView()
    private let now = UILabel()
    private let left = UILabel()
    private let mark = UIImageView()
    private var emphasised = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        track.backgroundColor = UIColor(white: 1, alpha: 0.28)
        fill.backgroundColor = UIColor(white: 1, alpha: 0.82)
        head.backgroundColor = .white
        head.layer.cornerRadius = 1.5
        track.clipsToBounds = true
        track.addSubview(fill)
        addSubview(track)
        addSubview(head)
        for label in [now, left] {
            label.font = Place.timeFont
            label.textColor = .white
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.55
            label.layer.shadowRadius = 5
            label.layer.shadowOffset = CGSize(width: 0, height: 1)
            addSubview(label)
        }
        left.textAlignment = .right
        mark.image = UIImage(systemName: "pause.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold))
        mark.tintColor = .white
        mark.contentMode = .center
        addSubview(mark)
        alphaAll(0)
    }

    required init?(coder: NSCoder) { fatalError("not made from a storyboard") }

    override var canBecomeFocused: Bool { !isHidden }

    private func alphaAll(_ a: CGFloat) {
        for v in [track, head, now, left, mark] as [UIView] { v.alpha = a }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        emphasised = context.nextFocusedView === self
        setNeedsLayout()
        coordinator.addCoordinatedAnimations({ self.layoutIfNeeded() }, completion: nil)
    }

    /// Where the playhead shows: where it has been moved to, else where the film is.
    var shown: Double { moved ?? time }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width
        // The bar's middle is 30 points down this view; a little thicker while it has the focus.
        let thick: CGFloat = emphasised ? 12 : 10
        track.frame = CGRect(x: 0, y: 30 - thick / 2, width: w, height: thick)
        track.layer.cornerRadius = thick / 2
        let part = length > 0 ? CGFloat(min(1, max(0, shown / length))) : 0
        fill.frame = CGRect(x: 0, y: 0, width: w * part, height: thick)
        let x = w * part
        let tall: CGFloat = emphasised ? 34 : 26
        head.frame = CGRect(x: min(max(0, x - 1.5), w - 3), y: 30 - tall / 2, width: 3, height: tall)

        let hours = length >= 3600
        now.text = FilmText.clock(shown, hours: hours)
        left.text = length > 0 ? "-" + FilmText.clock(max(0, length - shown), hours: hours) : ""
        let lineHeight = Place.timeFont.lineHeight
        let top = 69 - Place.timeFont.ascender
        let nowWidth = ceil(now.intrinsicContentSize.width)
        let leftWidth = ceil(left.intrinsicContentSize.width)
        // The time sits under the playhead, kept on the bar and clear of the time left at its end.
        let markWidth: CGFloat = paused ? 46 : 0
        var nowX = x - nowWidth / 2
        nowX = max(0, min(nowX, w - leftWidth - 40 - nowWidth - markWidth))
        now.frame = CGRect(x: nowX, y: top, width: nowWidth, height: lineHeight)
        mark.isHidden = !paused
        mark.frame = CGRect(x: nowX + nowWidth + 10, y: top, width: 36, height: lineHeight)
        left.frame = CGRect(x: w - leftWidth, y: top, width: leftWidth, height: lineHeight)
    }
}

/// The film on screen, played by the app's own player (`FilmPlayer`), with controls laid out as Apple's player has
/// them on Apple TV: the film's name with a line over it, the bar with the time under the playhead and the time
/// left at its end, round glass buttons at the right (Start Over, Subtitles, Audio, whose menus are the system's
/// own), and Info and Chapters under the bar.
///
/// The remote: the middle of the clickpad or Play/Pause stops and starts it; left and right skip ten seconds; a
/// swipe along the clickpad while it's stopped moves the playhead, and a click goes there; up and down reach the
/// buttons; Back puts the controls away, then closes the film.
final class FilmScreen: UIViewController, UIGestureRecognizerDelegate {
    /// The screen has gone (Back, the film's end, or closed by the app).
    var onGone: (() -> Void)?
    /// Next Episode was chosen.
    var onNext: (() -> Void)?
    /// Play or Pause was pressed on the remote (for the session's own note of it).
    var onPlayPause: (() -> Void)?

    let picture = FilmPictureView()
    private(set) var player: FilmPlayer?

    var card = FilmCard(title: "") { didSet { if isViewLoaded { showCard() } } }

    private let poster = UIImageView()
    private var posterImage: UIImage?
    private let words = UILabel()
    private let shade = UIView()
    private let shadeLayer = CAGradientLayer()
    /// Everything that comes and goes with the controls, except the bar (which keeps the focus).
    private let controls = UIView()
    private let line = UILabel()
    private let name = UILabel()
    private let bar = FilmBar()
    private var startOver: UIButton!
    private var subtitles: UIButton!
    private var sound: UIButton!
    private var info: UIButton!
    private var chapters: UIButton!
    private var nextEpisode: UIButton!
    private let spinner = UIActivityIndicatorView(style: .large)

    private enum Panel { case info, chapters }
    private var panel: UIView?
    private var panelKind: Panel?

    private var shownControls = false
    private var hideWork: Task<Void, Never>?
    private var refresher: Timer?
    private var focusNext: UIView?
    private var offering = false
    /// A skip asked for and not yet gone to (several presses are one move).
    private var skipWork: Task<Void, Never>?
    private var panBase = 0.0
    private var spinnerWork: Task<Void, Never>?
    /// The TV's picture mode was asked for through this (it's asked to go back when the film closes).
    private weak var display: AVDisplayManager?
    private var lastState = FilmPlayer.State.idle
    private var hasPlayed = false
    private var gone = false

    // MARK: Making it

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        picture.frame = view.bounds
        picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        picture.backgroundColor = .black
        picture.display.videoGravity = .resizeAspect
        view.addSubview(picture)

        poster.frame = view.bounds
        poster.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        poster.contentMode = .scaleAspectFill
        poster.clipsToBounds = true
        poster.alpha = 0.6
        poster.image = posterImage
        view.addSubview(poster)

        words.numberOfLines = 0
        words.textAlignment = .center
        words.layer.shadowColor = UIColor.black.cgColor
        words.layer.shadowOpacity = 0.8
        words.layer.shadowRadius = 6
        words.layer.shadowOffset = CGSize(width: 0, height: 2)
        view.addSubview(words)

        // Under the controls: the picture darkens towards the bottom, so white words read on a bright scene.
        shadeLayer.colors = [UIColor(white: 0, alpha: 0).cgColor, UIColor(white: 0, alpha: 0.62).cgColor]
        shadeLayer.locations = [0, 1]
        shade.layer.addSublayer(shadeLayer)
        shade.isUserInteractionEnabled = false
        shade.alpha = 0
        view.addSubview(shade)

        controls.alpha = 0
        view.addSubview(controls)
        for label in [line, name] {
            label.textColor = .white
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.55
            label.layer.shadowRadius = 6
            label.layer.shadowOffset = CGSize(width: 0, height: 2)
            controls.addSubview(label)
        }
        line.font = Place.lineFont
        name.font = Place.titleFont
        name.adjustsFontSizeToFitWidth = true
        name.minimumScaleFactor = 0.6

        startOver = roundButton("arrow.counterclockwise", "Start Over")
        startOver.addAction(UIAction { [weak self] _ in self?.fromBeginning() }, for: .primaryActionTriggered)
        subtitles = roundButton("captions.bubble", "Subtitles")
        subtitles.showsMenuAsPrimaryAction = true
        subtitles.menu = UIMenu(title: "Subtitles", children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.subtitleItems() ?? [])
        }])
        sound = roundButton("waveform", "Audio")
        sound.showsMenuAsPrimaryAction = true
        sound.menu = UIMenu(title: "Audio", children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.soundItems() ?? [])
        }])
        info = pill("Info")
        info.addAction(UIAction { [weak self] _ in self?.toggle(.info) }, for: .primaryActionTriggered)
        chapters = pill("Chapters")
        chapters.addAction(UIAction { [weak self] _ in self?.toggle(.chapters) }, for: .primaryActionTriggered)
        chapters.isHidden = true
        for button in [startOver!, subtitles!, sound!, info!, chapters!] { controls.addSubview(button) }

        view.addSubview(bar)

        nextEpisode = pill("Next Episode", prominent: true)
        nextEpisode.addAction(UIAction { [weak self] _ in self?.onNext?() }, for: .primaryActionTriggered)
        nextEpisode.isHidden = true
        view.addSubview(nextEpisode)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)
        spinner.startAnimating()

        // Back: the controls go first, then the film.
        let back = UITapGestureRecognizer(target: self, action: #selector(backPressed))
        back.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        back.allowedTouchTypes = []
        view.addGestureRecognizer(back)
        // A touch on the clickpad (not a click) brings the controls.
        let touch = UITapGestureRecognizer(target: self, action: #selector(touched))
        touch.allowedPressTypes = []
        touch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        touch.delegate = self
        view.addGestureRecognizer(touch)
        for way in [UISwipeGestureRecognizer.Direction.up, .down] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(touched))
            swipe.direction = way
            swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            swipe.delegate = self
            view.addGestureRecognizer(swipe)
        }
        // A swipe along the clickpad moves the playhead while the film is stopped.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        pan.delegate = self
        view.addGestureRecognizer(pan)

        showCard()
        showControls()
    }

    private func roundButton(_ symbol: String, _ label: String) -> UIButton {
        var c = UIButton.Configuration.glass()
        c.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 27, weight: .semibold))
        c.cornerStyle = .capsule
        c.contentInsets = .zero
        let b = UIButton(configuration: c)
        b.accessibilityLabel = label
        return b
    }

    private func pill(_ title: String, prominent: Bool = false) -> UIButton {
        var c = prominent ? UIButton.Configuration.prominentGlass() : UIButton.Configuration.glass()
        var text = AttributedString(title)
        text.font = Place.pillFont
        c.attributedTitle = text
        c.cornerStyle = .capsule
        c.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 32, bottom: 0, trailing: 32)
        return UIButton(configuration: c)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = view.bounds.width, h = view.bounds.height
        controls.frame = view.bounds
        shade.frame = CGRect(x: 0, y: h - 520, width: w, height: 520)
        shadeLayer.frame = shade.bounds

        // The round buttons, at the right, level with the title.
        let rounds = [startOver, subtitles, sound].compactMap { $0 }
        var x = w - Place.side - Place.round
        let roundY = h - Place.titleBaseline - 20 - Place.round / 2
        for button in rounds.reversed() {
            button.frame = CGRect(x: x, y: roundY, width: Place.round, height: Place.round)
            x -= Place.round + Place.roundGap
        }
        let textWidth = max(200, x + Place.round - Place.side - 40)
        line.frame = CGRect(x: Place.side, y: h - Place.lineBaseline - Place.lineFont.ascender, width: textWidth, height: Place.lineFont.lineHeight)
        name.frame = CGRect(x: Place.side, y: h - Place.titleBaseline - Place.titleFont.ascender, width: textWidth, height: Place.titleFont.lineHeight)

        bar.frame = CGRect(x: Place.side, y: h - Place.barMiddle - 30, width: w - 2 * Place.side, height: 84)

        let pillY = h - Place.pillBottom - Place.pillHeight
        var pillX = Place.side
        for button in [info, chapters].compactMap({ $0 }) where !button.isHidden {
            let width = ceil(button.intrinsicContentSize.width)
            button.frame = CGRect(x: pillX, y: pillY, width: width, height: Place.pillHeight)
            pillX += width + 26
        }
        let nextWidth = ceil(nextEpisode.intrinsicContentSize.width)
        nextEpisode.frame = CGRect(x: w - Place.side - nextWidth, y: pillY, width: nextWidth, height: Place.pillHeight)

        spinner.center = CGPoint(x: w / 2, y: h / 2)
        layoutWords()
        layoutPanel()
    }

    private func showCard() {
        name.text = card.title
        line.text = card.line
        line.isHidden = (card.line ?? "").isEmpty
    }

    /// The film's picture behind the spinner until its first frame shows.
    func setPoster(_ image: UIImage?) {
        posterImage = image
        if isViewLoaded, !hasPlayed { poster.image = image }
    }

    // MARK: The player

    /// The film's player, once it's open: its picture comes here, and what it says is shown.
    func attach(_ player: FilmPlayer) {
        self.player = player
        loadViewIfNeeded()
        player.show(on: picture.display.sampleBufferRenderer)
        player.onChange = { [weak self] in self?.changed() }
        player.onWords = { [weak self] line in self?.say(line) }
        refresher?.invalidate()
        refresher = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        changed()
    }

    /// Asks the TV for the film's frame rate and dynamic range (Match Content) and waits for it to switch: the
    /// seconds that took, nil when it didn't switch (it was in that mode, or matching is off).
    func matchDisplay(to picture: FilmPlayer.Picture?) async -> Double? {
        // On screen first: the window is what's asked.
        for _ in 0..<60 where view.window == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
        guard let picture, let display = view.window?.avDisplayManager, display.isDisplayCriteriaMatchingEnabled else { return nil }
        self.display = display
        let rate = picture.framesASecond > 0 ? picture.framesASecond : 24
        display.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: rate, formatDescription: picture.format)
        var took: Double?
        for _ in 0..<2 {
            var looks = 0
            while !display.isDisplayModeSwitchInProgress, looks < 10 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                looks += 1
            }
            guard display.isDisplayModeSwitchInProgress else { break }
            let began = Date()
            looks = 0
            while display.isDisplayModeSwitchInProgress, looks < 200 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                looks += 1
            }
            took = (took ?? 0) + Date().timeIntervalSince(began)
        }
        // A moment more for the TV to show a picture again.
        if took != nil { try? await Task.sleep(nanoseconds: 300_000_000) }
        return took
    }

    /// Whether the Apple TV matches the film's picture mode (for the Macs' log), nil when it can't be told.
    var matchesContent: Bool? { viewIfLoaded?.window?.avDisplayManager.isDisplayCriteriaMatchingEnabled }

    /// The TV goes back to the mode it was in.
    private func releaseDisplay() {
        display?.preferredDisplayCriteria = nil
        display = nil
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed { releaseDisplay() }
    }

    private func changed() {
        guard let player, isViewLoaded else { return }
        let state = player.state
        bar.length = player.length
        bar.paused = state == .paused
        if state == .playing, !hasPlayed {
            hasPlayed = true
            UIView.animate(withDuration: 0.3, animations: { self.poster.alpha = 0 }, completion: { _ in self.poster.isHidden = true })
        }
        // The spinner: until the film first plays, and after that while it waits for the film (after a moment: a
        // short wait shows nothing).
        let busy = state == .waiting || state == .idle || (!hasPlayed && state == .paused)
        spinnerWork?.cancel()
        if busy {
            let after: UInt64 = hasPlayed ? 600_000_000 : 0
            spinnerWork = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: after)
                guard !Task.isCancelled else { return }
                self?.spinner.startAnimating()
            }
        } else {
            spinner.stopAnimating()
        }
        UIApplication.shared.isIdleTimerDisabled = state == .playing || state == .waiting
        if state != lastState {
            lastState = state
            if state == .paused { showControls() } else if state == .playing { restartHiding() }
        }
        chapters.isHidden = player.film.chapters.isEmpty
        view.setNeedsLayout()
        refresh()
    }

    private func refresh() {
        guard let player else { return }
        bar.time = player.time
        if shownControls { bar.setNeedsLayout() }
    }

    // MARK: Subtitles

    private func say(_ text: String?) {
        guard let text, !text.isEmpty else {
            words.attributedText = nil
            return
        }
        words.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 48, weight: .semibold),
            .foregroundColor: UIColor.white,
            .strokeColor: UIColor.black,
            .strokeWidth: -2.5,
        ])
        layoutWords()
    }

    /// Subtitles sit near the bottom, and above the controls while those are showing.
    private func layoutWords() {
        let w = view.bounds.width, h = view.bounds.height
        let size = words.sizeThatFits(CGSize(width: w - 400, height: 400))
        let bottom = shownControls || panel != nil ? h - 360 : h - 80
        words.frame = CGRect(x: (w - size.width) / 2, y: bottom - size.height, width: size.width, height: size.height)
    }

    // MARK: Controls coming and going

    private var barFocused: Bool { bar.isFocused }

    private func showControls() {
        guard isViewLoaded else { return }
        if !shownControls {
            shownControls = true
            bar.quiet = panel != nil
            refresh()
            bar.setNeedsLayout()
            UIView.animate(withDuration: 0.25) {
                self.controls.alpha = 1
                self.shade.alpha = 1
                self.layoutWords()
            }
        }
        restartHiding()
    }

    private func hideControls() {
        guard shownControls, panel == nil else { return }
        shownControls = false
        hideWork?.cancel()
        // The focus goes to Next Episode when it's offered (one click starts it), else back to the bar (a button
        // out of sight can't keep it).
        if offering {
            focus(nextEpisode!)
        } else if !barFocused {
            focus(bar)
        }
        UIView.animate(withDuration: 0.35) {
            self.controls.alpha = 0
            self.shade.alpha = 0
            self.bar.quiet = true
            self.layoutWords()
        }
    }

    /// The controls go away by themselves a few seconds after the last press, while the film plays and nothing is
    /// open over them.
    private func restartHiding() {
        hideWork?.cancel()
        hideWork = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.hideIfIdle()
        }
    }

    private func hideIfIdle() {
        guard shownControls, let player, player.state == .playing, panel == nil, bar.moved == nil else { return }
        // A menu is open (the focus is in it, not here): looked at again later.
        if let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView, !focused.isDescendant(of: view) {
            restartHiding()
            return
        }
        hideControls()
    }

    // MARK: Focus

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let wanted = focusNext, wanted.window != nil, !wanted.isHidden { return [wanted] }
        if panel == nil { return [bar] }
        return super.preferredFocusEnvironments
    }

    private func focus(_ target: UIView) {
        focusNext = target
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        focusNext = nil
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if shownControls { restartHiding() }
    }

    // MARK: The remote

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var mine = false
        for press in presses {
            switch press.type {
            case .playPause:
                playPause()
                mine = true
            case .select:
                if barFocused {
                    selectOnBar()
                    mine = true
                }
            case .leftArrow:
                if barFocused {
                    skip(-10)
                    mine = true
                }
            case .rightArrow:
                if barFocused {
                    skip(10)
                    mine = true
                }
            case .upArrow, .downArrow:
                // Out of sight: the first press brings the controls; the next one moves to a button.
                if barFocused, !shownControls {
                    showControls()
                    mine = true
                }
            default:
                break
            }
        }
        if !mine { super.pressesBegan(presses, with: event) }
    }

    private func playPause() {
        guard let player else { return }
        onPlayPause?()
        if let to = bar.moved {
            // The playhead was moved: Play goes there and plays.
            go(to)
            player.play()
        } else if player.state == .paused || player.state == .ended {
            player.play()
        } else if player.state == .playing || player.state == .waiting {
            player.pause()
        }
        showControls()
    }

    /// Play and Pause from outside the remote (Siri, the iPhone's remote).
    func remote(play: Bool) {
        guard let player else { return }
        if play { player.play() } else { player.pause() }
    }

    private func selectOnBar() {
        if let to = bar.moved, skipWork == nil {
            go(to)
            showControls()
            return
        }
        playPause()
    }

    /// Ten seconds back or on. Several presses make one move, gone to a moment after the last.
    private func skip(_ seconds: Double) {
        guard let player, player.length > 0 else { return }
        let from = bar.moved ?? player.time
        let to = max(0, min(player.length - 1, from + seconds))
        bar.moved = to
        bar.setNeedsLayout()
        showControls()
        skipWork?.cancel()
        skipWork = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            self.skipWork = nil
            self.go(to)
        }
    }

    /// Goes to [seconds] in the film.
    func go(_ seconds: Double) {
        guard let player else { return }
        skipWork?.cancel()
        skipWork = nil
        player.seek(to: seconds)
        bar.time = seconds
        bar.moved = nil
        bar.setNeedsLayout()
    }

    private func fromBeginning() {
        guard let player else { return }
        closePanel()
        go(0)
        player.play()
        showControls()
    }

    @objc private func touched() {
        showControls()
    }

    @objc private func backPressed() {
        if panel != nil {
            closePanel()
        } else if bar.moved != nil {
            // The playhead goes back to where the film is.
            skipWork?.cancel()
            skipWork = nil
            bar.moved = nil
            bar.setNeedsLayout()
        } else if shownControls, player?.state == .playing {
            hideControls()
        } else {
            close()
        }
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard let player, player.length > 0 else { return }
        switch pan.state {
        case .began:
            panBase = bar.moved ?? player.time
        case .changed, .ended:
            // The clickpad's whole width is a third of the film (five minutes at least).
            let span = min(player.length, max(300, player.length / 3))
            let to = panBase + Double(pan.translation(in: view).x / max(1, view.bounds.width)) * span
            bar.moved = max(0, min(player.length - 1, to))
            bar.setNeedsLayout()
            showControls()
        default:
            break
        }
    }

    /// The playhead moves with a swipe only while the film is stopped with the controls showing and the focus on
    /// the bar: never while a swipe is moving the focus between buttons, or by a brush of the clickpad while it plays.
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer is UIPanGestureRecognizer else { return true }
        return barFocused && shownControls && panel == nil && player?.state == .paused
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: Menus

    private static func language(_ code: String?) -> String? {
        guard let code, !code.isEmpty, code != "und" else { return nil }
        return Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
    }

    /// A sound track's name in the Audio menu: its language, and how many speakers it's mixed for.
    private static func soundName(_ s: FilmPlayer.Sound, number: Int) -> String {
        let mix: String
        switch s.channels {
        case 1: mix = "Mono"
        case 2: mix = "Stereo"
        case 6: mix = "5.1"
        case 8: mix = "7.1"
        default: mix = s.channels > 0 ? "\(s.channels) Channels" : ""
        }
        let name = language(s.language) ?? "Track \(number)"
        return mix.isEmpty ? name : "\(name) · \(mix)"
    }

    private func soundItems() -> [UIMenuElement] {
        guard let player else { return [] }
        let film = player.film
        var items: [UIMenuElement] = []
        for (i, s) in film.sounds.enumerated() {
            let item = UIAction(title: Self.soundName(s, number: i + 1), state: s.id == film.sound ? .on : .off) { [weak self] _ in
                self?.player?.choose(sound: s.id)
            }
            if !s.playable { item.attributes = .disabled }
            items.append(item)
        }
        if items.isEmpty { items.append(UIAction(title: "No Sound in This Film", attributes: .disabled) { _ in }) }
        return items
    }

    private func subtitleItems() -> [UIMenuElement] {
        guard let player else { return [] }
        let film = player.film
        guard !film.words.isEmpty else {
            return [UIAction(title: "None in This Film", attributes: .disabled) { _ in }]
        }
        let remembered = film.showing ?? lastWords ?? film.words.first?.id
        let on = UIAction(title: "On", state: film.showing != nil ? .on : .off) { [weak self] _ in
            self?.chooseWords(remembered)
        }
        let off = UIAction(title: "Off", state: film.showing == nil ? .on : .off) { [weak self] _ in
            self?.chooseWords(nil)
        }
        var items: [UIMenuElement] = [UIMenu(title: "", options: .displayInline, children: [on, off])]
        let tracks = film.words.enumerated().map { i, track in
            UIAction(title: Self.language(track.language) ?? "Track \(i + 1)", state: track.id == remembered ? .on : .off) { [weak self] _ in
                self?.chooseWords(track.id)
            }
        }
        let current = film.words.first { $0.id == remembered }
        items.append(UIMenu(title: "Language", subtitle: Self.language(current?.language), children: tracks))
        return items
    }

    /// The subtitle track last shown, for On.
    private var lastWords: CMPersistentTrackID?

    private func chooseWords(_ id: CMPersistentTrackID?) {
        if let id { lastWords = id }
        player?.choose(words: id)
        if id == nil { say(nil) }
    }

    // MARK: Info and Chapters

    private func toggle(_ kind: Panel) {
        if panelKind == kind {
            closePanel()
            return
        }
        open(kind)
    }

    private func open(_ kind: Panel) {
        panel?.removeFromSuperview()
        let made = kind == .info ? infoPanel() : chaptersPanel()
        made.alpha = 0
        view.insertSubview(made, belowSubview: controls)
        panel = made
        panelKind = kind
        layoutPanel()
        // The title, the bar and the round buttons step back while it's open.
        bar.isHidden = true
        UIView.animate(withDuration: 0.25) {
            made.alpha = 1
            for v in [self.line, self.name, self.startOver!, self.subtitles!, self.sound!] as [UIView] { v.alpha = 0 }
            self.layoutWords()
        }
        hideWork?.cancel()
        if let first = made.viewWithTag(1) { focus(first) }
    }

    private func closePanel() {
        guard let old = panel else { return }
        let back: UIView = panelKind == .chapters ? chapters! : info!
        panel = nil
        panelKind = nil
        bar.isHidden = false
        focus(back)
        UIView.animate(withDuration: 0.2, animations: {
            old.alpha = 0
            for v in [self.line, self.name, self.startOver!, self.subtitles!, self.sound!] as [UIView] { v.alpha = 1 }
            self.layoutWords()
        }, completion: { _ in old.removeFromSuperview() })
        restartHiding()
    }

    private func layoutPanel() {
        guard let panel else { return }
        let w = view.bounds.width, h = view.bounds.height
        let height: CGFloat = panelKind == .info ? 340 : 190
        panel.frame = CGRect(x: Place.side, y: h - Place.pillBottom - Place.pillHeight - 30 - height, width: w - 2 * Place.side, height: height)
    }

    /// Info: the film's picture, its name, its year and genres, its story, and From Beginning.
    private func infoPanel() -> UIView {
        let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        glass.layer.cornerRadius = 44
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        let inside = glass.contentView
        let width = view.bounds.width - 2 * Place.side
        var x: CGFloat = 40
        if let image = posterImage {
            let art = UIImageView(image: image)
            art.contentMode = .scaleAspectFill
            art.clipsToBounds = true
            art.layer.cornerRadius = 16
            art.layer.cornerCurve = .continuous
            let artWidth: CGFloat = image.size.width >= image.size.height ? 462 : 174
            art.frame = CGRect(x: x, y: 40, width: artWidth, height: 260)
            inside.addSubview(art)
            x += artWidth + 40
        }
        let title = UILabel()
        title.text = card.title
        title.font = .systemFont(ofSize: 38, weight: .bold)
        title.textColor = .white
        title.frame = CGRect(x: x, y: 36, width: width - x - 40, height: 46)
        inside.addSubview(title)
        var y: CGFloat = 88
        let said = [card.line, card.facts].compactMap { $0 }.filter { !$0.isEmpty }
        if !said.isEmpty {
            let facts = UILabel()
            facts.text = said.joined(separator: " · ")
            facts.font = .systemFont(ofSize: 26, weight: .medium)
            facts.textColor = UIColor(white: 1, alpha: 0.72)
            facts.frame = CGRect(x: x, y: y, width: width - x - 40, height: 32)
            inside.addSubview(facts)
            y += 42
        }
        let from = UIButton(configuration: {
            var c = UIButton.Configuration.gray()
            var text = AttributedString("From Beginning")
            text.font = Place.pillFont
            c.attributedTitle = text
            c.cornerStyle = .capsule
            c.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 30, bottom: 0, trailing: 30)
            return c
        }())
        from.tag = 1
        from.addAction(UIAction { [weak self] _ in self?.fromBeginning() }, for: .primaryActionTriggered)
        let fromWidth = ceil(from.intrinsicContentSize.width)
        from.frame = CGRect(x: x, y: 340 - 40 - 60, width: fromWidth, height: 60)
        inside.addSubview(from)
        if let text = card.story, !text.isEmpty {
            let story = UILabel()
            story.text = text
            story.font = .systemFont(ofSize: 27, weight: .regular)
            story.textColor = .white
            story.numberOfLines = 0
            story.lineBreakMode = .byTruncatingTail
            story.frame = CGRect(x: x, y: y, width: width - x - 40, height: max(0, 340 - 40 - 60 - 16 - y))
            inside.addSubview(story)
        }
        return glass
    }

    /// Chapters: a row of glass tiles, each a chapter's name and where it starts; the one playing stands out.
    private func chaptersPanel() -> UIView {
        let scroll = UIScrollView()
        scroll.clipsToBounds = false
        scroll.showsHorizontalScrollIndicator = false
        guard let player else { return scroll }
        let all = player.film.chapters
        let now = player.time
        let playing = all.lastIndex { $0.start <= now + 0.5 } ?? 0
        let hours = player.length >= 3600
        var x: CGFloat = 0
        for (i, chapter) in all.enumerated() {
            var c = i == playing ? UIButton.Configuration.prominentGlass() : UIButton.Configuration.glass()
            var title = AttributedString(chapter.title.isEmpty ? "Chapter \(i + 1)" : chapter.title)
            title.font = Place.pillFont
            c.attributedTitle = title
            var time = AttributedString(FilmText.clock(chapter.start, hours: hours))
            time.font = UIFont.monospacedDigitSystemFont(ofSize: 23, weight: .medium)
            c.attributedSubtitle = time
            c.titleAlignment = .leading
            c.titleLineBreakMode = .byTruncatingTail
            c.cornerStyle = .large
            c.contentInsets = NSDirectionalEdgeInsets(top: 20, leading: 26, bottom: 20, trailing: 26)
            let tile = UIButton(configuration: c)
            tile.contentHorizontalAlignment = .leading
            tile.tag = i == playing ? 1 : 0
            tile.addAction(UIAction { [weak self] _ in
                self?.closePanel()
                self?.go(chapter.start)
                self?.showControls()
            }, for: .primaryActionTriggered)
            tile.frame = CGRect(x: x, y: 20, width: 340, height: 150)
            scroll.addSubview(tile)
            x += 340 + 26
        }
        scroll.contentSize = CGSize(width: max(0, x - 26), height: 190)
        return scroll
    }

    // MARK: Next Episode

    /// Next Episode shows over the picture (also with the controls out of sight), with the focus on it.
    func offerNext(_ on: Bool) {
        guard isViewLoaded, on != offering else { return }
        offering = on
        nextEpisode.isHidden = !on
        view.setNeedsLayout()
        if on {
            if barFocused, !shownControls { focus(nextEpisode!) }
        } else if nextEpisode.isFocused {
            focus(bar)
        }
    }

    // MARK: Saying why not, and closing

    /// Says why it can't play, over the picture; OK closes the film.
    func fail(_ title: String, _ message: String) {
        guard presentedViewController == nil, !gone else { return }
        spinner.stopAnimating()
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in self?.close() })
        present(alert, animated: true)
    }

    /// Closes the film's screen.
    func close(animated: Bool = true) {
        guard !gone else { return }
        if presentingViewController != nil {
            dismiss(animated: animated)
        } else {
            wentAway()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { wentAway() }
    }

    private func wentAway() {
        guard !gone else { return }
        gone = true
        refresher?.invalidate()
        refresher = nil
        hideWork?.cancel()
        skipWork?.cancel()
        spinnerWork?.cancel()
        UIApplication.shared.isIdleTimerDisabled = false
        releaseDisplay()
        onGone?()
    }
}
