import LucaKit
import UIKit

/// The game's manual pages, full screen: tap the right half (or swipe left) for the next page,
/// the left half for the previous; past the last page, or a two-finger tap, closes it.
final class LucaManualViewController: UIViewController {
    private let game: LucaGame
    private let pages: [Int]
    private let backgroundID: Int?
    private var index = 0
    private let stage = UIView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    private let backgroundView = UIImageView()
    private let pageView = UIImageView()

    init(game: LucaGame, pages: [Int], background: Int?) {
        self.game = game
        self.pages = pages
        backgroundID = background
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        stage.clipsToBounds = true
        view.addSubview(stage)
        backgroundView.frame = stage.bounds
        backgroundView.image = backgroundID.flatMap(picture)
        stage.addSubview(backgroundView)
        stage.addSubview(pageView)
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        let close = UITapGestureRecognizer(target: self, action: #selector(closeManual))
        close.numberOfTouchesRequired = 2
        view.addGestureRecognizer(close)
        let next = UISwipeGestureRecognizer(target: self, action: #selector(nextPage))
        next.direction = .left
        view.addGestureRecognizer(next)
        let back = UISwipeGestureRecognizer(target: self, action: #selector(previousPage))
        back.direction = .right
        view.addGestureRecognizer(back)
        show()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let scale = min(view.bounds.width / 1920, view.bounds.height / 1080)
        stage.layer.anchorPoint = .zero
        stage.transform = CGAffineTransform(scaleX: scale, y: scale)
        stage.layer.position = CGPoint(x: (view.bounds.width - 1920 * scale) / 2, y: (view.bounds.height - 1080 * scale) / 2)
    }

    private func picture(_ id: Int) -> UIImage? {
        game.image(id).flatMap(LucaGameViewController.cgImage).map { UIImage(cgImage: $0) }
    }

    private func show() {
        guard pages.indices.contains(index), let image = game.image(pages[index]) else { return }
        pageView.image = picture(pages[index])
        pageView.frame = CGRect(x: image.offsetX, y: image.offsetY, width: image.width, height: image.height)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        if recognizer.location(in: view).x < view.bounds.midX { previousPage() } else { nextPage() }
    }

    @objc private func nextPage() {
        if index + 1 >= pages.count { closeManual(); return }
        index += 1
        show()
    }

    @objc private func previousPage() {
        guard index > 0 else { return }
        index -= 1
        show()
    }

    @objc private func closeManual() { dismiss(animated: true) }
}
