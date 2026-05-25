import UIKit

/// Translucent preview that lifts off a PDF anchor and follows the finger
/// while dragging toward the canvas. Shaped like a future scrap card so the
/// user can see what they're about to drop before they let go.
final class ScrapDragPreviewView: UIView {
    init(kind: ScrapKind, text: String?, image: UIImage?, size: CGSize) {
        super.init(frame: CGRect(origin: .zero, size: size))
        backgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        layer.borderColor = UIColor.separator.withAlphaComponent(0.6).cgColor
        layer.borderWidth = 0.5
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowOffset = CGSize(width: 0, height: 8)
        layer.shadowRadius = 14
        alpha = 0.7

        switch kind {
        case .text:
            installTextBody(text ?? "")
        case .image:
            installImageBody(image)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    private func installTextBody(_ text: String) {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .label
        label.numberOfLines = 0
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12)
        ])
    }

    private func installImageBody(_ image: UIImage?) {
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 10
        imageView.layer.cornerCurve = .continuous
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
        ])
    }
}
