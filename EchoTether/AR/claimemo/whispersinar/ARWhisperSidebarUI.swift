//
//  ARWhisperSidebarUI.swift
//  EchoTether
//
//  Created by Bobby Smith on 1/30/26.
//

//
//  ARWhisperSidebarUI.swift
//  EchoTether
//
//  SIDEBAR UI FILE (UIKit)
//  - SidebarItem model
//  - SidebarView panel + rows
//  - Shared button styling
//

import UIKit

// MARK: - Sidebar Item (used by Coordinator)

struct SidebarItem: Hashable {
    let id: String
    let title: String
    var subtitle: String
    var canDelete: Bool
}

// MARK: - Sidebar View

final class SidebarView: UIView {
    var trailingConstraint: NSLayoutConstraint?
    var isShown: Bool = false

    var onOpen: ((String) -> Void)?
    var onInfo: ((String) -> Void)?
    var onDelete: ((String) -> Void)?

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let stack = UIStackView()
    private var rows: [String: SidebarRow] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.masksToBounds = true

        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let title = UILabel()
        title.text = "Media Nearby"
        title.font = .boldSystemFont(ofSize: 17)
        title.textColor = .white
        title.translatesAutoresizingMaskIntoConstraints = false

        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroller = UIScrollView()
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(stack)

        blur.contentView.addSubview(title)
        blur.contentView.addSubview(scroller)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -14),
            title.topAnchor.constraint(equalTo: blur.contentView.safeAreaLayoutGuide.topAnchor, constant: 10),

            scroller.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor),
            scroller.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor),
            scroller.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroller.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scroller.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: scroller.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: scroller.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scroller.bottomAnchor, constant: -12),
            stack.widthAnchor.constraint(equalTo: scroller.widthAnchor, constant: -20)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(items: [SidebarItem]) {
        let existing = Set(rows.keys)
        let next = Set(items.map { $0.id })

        for id in existing.subtracting(next) {
            rows[id]?.removeFromSuperview()
            rows.removeValue(forKey: id)
        }

        for item in items {
            if let row = rows[item.id] {
                row.configure(title: item.title, subtitle: item.subtitle, canDelete: item.canDelete)
            } else {
                let row = SidebarRow()
                row.configure(title: item.title, subtitle: item.subtitle, canDelete: item.canDelete)

                row.onOpen = { [weak self] in self?.onOpen?(item.id) }
                row.onInfo = { [weak self] in self?.onInfo?(item.id) }
                row.onDelete = { [weak self] in self?.onDelete?(item.id) }

                rows[item.id] = row
                stack.addArrangedSubview(row)
            }
        }
    }

    func updateItem(id: String, subtitle: String, canDelete: Bool) {
        rows[id]?.configure(
            title: rows[id]?.titleText ?? "Whisper",
            subtitle: subtitle,
            canDelete: canDelete
        )
    }
}

// MARK: - Sidebar Row

final class SidebarRow: UIView {
    var onOpen: (() -> Void)?
    var onInfo: (() -> Void)?
    var onDelete: (() -> Void)?

    private let title = UILabel()
    private let subtitle = UILabel()
    private let openBtn = UIButton(type: .system)
    private let infoBtn = UIButton(type: .system)
    private let delBtn  = UIButton(type: .system)

    var titleText: String { title.text ?? "" }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 12
        backgroundColor = UIColor.white.withAlphaComponent(0.08)

        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white

        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = UIColor.white.withAlphaComponent(0.9)
        subtitle.numberOfLines = 1

        styleActionButton(openBtn, title: "Open")
        styleActionButton(infoBtn, title: "Info")
        styleActionButton(delBtn,  title: "Delete")

        openBtn.addTarget(self, action: #selector(tOpen), for: .touchUpInside)
        infoBtn.addTarget(self, action: #selector(tInfo), for: .touchUpInside)
        delBtn.addTarget(self,  action: #selector(tDelete), for: .touchUpInside)

        let vstack = UIStackView(arrangedSubviews: [title, subtitle])
        vstack.axis = .vertical
        vstack.spacing = 2
        vstack.translatesAutoresizingMaskIntoConstraints = false

        let hstack = UIStackView(arrangedSubviews: [openBtn, infoBtn, delBtn])
        hstack.axis = .horizontal
        hstack.spacing = 8
        hstack.distribution = .fillProportionally
        hstack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(vstack)
        addSubview(hstack)

        NSLayoutConstraint.activate([
            vstack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            vstack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            vstack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            hstack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            hstack.topAnchor.constraint(equalTo: vstack.bottomAnchor, constant: 8),
            hstack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, subtitle: String, canDelete: Bool) {
        self.title.text = title
        self.subtitle.text = subtitle
        delBtn.isHidden = !canDelete
    }

    @objc private func tOpen()   { onOpen?() }
    @objc private func tInfo()   { onInfo?() }
    @objc private func tDelete() { onDelete?() }
}

// MARK: - Shared modern button styling

func styleActionButton(_ button: UIButton, title: String) {
    button.translatesAutoresizingMaskIntoConstraints = false
    if #available(iOS 15.0, *) {
        var conf = UIButton.Configuration.plain()
        conf.title = title
        conf.baseForegroundColor = .white
        conf.background.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        conf.background.cornerRadius = 8
        conf.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        button.configuration = conf
    } else {
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        button.layer.cornerRadius = 8
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
    }
}
