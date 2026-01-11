//
//  BubbleGameView.swift
//  Chaotic Bubble Burst
//
//  Echo Bubble Pop–style shooter version for Chaotic Bubble Burst.
//
//  • Level-based progression (level goes up only when you win)
//  • Sweeping aimer at bottom, tap ANYWHERE to fire along the aim line
//  • 3+ of the same color (4-way) pop, floating clusters fall
//  • Bomb crates (💣+1) in the grid give bombs when popped or dropped
//  • Bomb toggle: turn current shot into a bomb that explodes 3×3
//  • Board slowly drops after a number of shots (faster on higher levels)
//  • HUD adds: Coins, Time, optional AI score for .vsAI mode
//

import SwiftUI
import Combine

// MARK: - Modes

enum GameMode {
    case soloTimed
    case vsAI
}

// MARK: - Internal Bubble Types (unique names so they don’t clash with Echo code)

private enum CBBBubbleKind: CaseIterable, Equatable {
    case red, blue, green, yellow, purple, orange
    case bombCrate      // special bubble that gives bombs when popped or dropped

    var color: Color {
        switch self {
        case .red:    return Color(red: 0.95, green: 0.15, blue: 0.25)
        case .blue:   return Color(red: 0.20, green: 0.55, blue: 1.00)
        case .green:  return Color(red: 0.10, green: 0.80, blue: 0.45)
        case .yellow: return Color(red: 1.00, green: 0.90, blue: 0.10)
        case .purple: return Color(red: 0.65, green: 0.35, blue: 0.90)
        case .orange: return Color(red: 1.00, green: 0.55, blue: 0.00)
        case .bombCrate:
            return Color(red: 0.1, green: 0.1, blue: 0.1)
        }
    }

    static var allColors: [CBBBubbleKind] {
        [.red, .blue, .green, .yellow, .purple, .orange]
    }

    static func randomColor() -> CBBBubbleKind {
        allColors.randomElement() ?? .blue
    }

    static func randomWithRareCrate(probability: Double) -> CBBBubbleKind {
        if Double.random(in: 0..<1) < probability {
            return .bombCrate
        } else {
            return randomColor()
        }
    }
}

private struct CBBShotBubble {
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var kind: CBBBubbleKind
    var isBomb: Bool
}

// MARK: - Shooter Engine (basically your EchoBubblePop engine, renamed)

private final class CBBBubbleShooterEngine: ObservableObject {

    let rows: Int = 10
    let columns: Int = 8

    @Published var grid: [[CBBBubbleKind?]]

    @Published var aimAngle: Double = 0.0
    private var aimDirection: Double = 1.0

    @Published var activeShot: CBBShotBubble?

    @Published var currentKind: CBBBubbleKind
    @Published var nextKind: CBBBubbleKind

    @Published var score: Int = 0
    @Published var shotsFired: Int = 0
    @Published var isGameOver: Bool = false
    @Published var isBoardCleared: Bool = false

    @Published var level: Int = 1
    @Published var comboMultiplier: Int = 1
    @Published var lastPopCount: Int = 0

    @Published var bombsRemaining: Int = 5
    @Published var isBombMode: Bool = false

    let maxBombs: Int = 10

    var shooterOriginX: Double {
        Double(columns) / 2.0
    }
    var shooterOriginY: Double {
        Double(rows) + 0.3
    }

    // scoring / tuning
    private let basePopScore = 10
    private let floatingScore = 15

    private let baseRowDropInterval = 16
    private var shotsSinceLastRowDrop: Int = 0

    // crate chance (can be tuned if you want an external booster later)
    private var crateProbability: Double { 0.04 }

    init() {
        grid = Array(
            repeating: Array(repeating: nil, count: columns),
            count: rows
        )
        currentKind = .randomColor()
        nextKind = .randomColor()
        restartCurrentLevel()
    }

    // MARK: - Level & Reset

    func restartCurrentLevel() {
        isGameOver = false
        isBoardCleared = false
        score = 0
        shotsFired = 0
        comboMultiplier = 1
        lastPopCount = 0
        shotsSinceLastRowDrop = 0
        isBombMode = false

        grid = makeInitialGrid(for: level)
        bombsRemaining = 5

        currentKind = .randomColor()
        nextKind = .randomColor()
    }

    func advanceToNextLevel() {
        level += 1
        restartCurrentLevel()
    }

    private func makeInitialGrid(for level: Int) -> [[CBBBubbleKind?]] {
        var newGrid: [[CBBBubbleKind?]] = Array(
            repeating: Array(repeating: nil, count: columns),
            count: rows
        )

        let filledRows = min(3 + (level - 1), rows - 3)

        if filledRows > 0 {
            for r in 0..<filledRows {
                for c in 0..<columns {
                    newGrid[r][c] = CBBBubbleKind.randomWithRareCrate(probability: crateProbability)
                }
            }
        }

        return newGrid
    }

    // MARK: - Public API (called by view)

    func fireIfPossible() {
        guard !isGameOver, !isBoardCleared else { return }
        guard activeShot == nil else { return }

        let speed: Double = 0.35
        let radians = aimAngle * .pi / 180.0

        let dx = sin(radians)
        let dy = -cos(radians)

        let shotKind = currentKind
        let isBombShot = isBombMode && bombsRemaining > 0

        if isBombShot {
            bombsRemaining -= 1
            if bombsRemaining <= 0 {
                bombsRemaining = 0
                isBombMode = false
            }
        }

        let shot = CBBShotBubble(
            x: shooterOriginX,
            y: shooterOriginY,
            vx: dx * speed,
            vy: dy * speed,
            kind: shotKind,
            isBomb: isBombShot
        )

        activeShot = shot
        shotsFired += 1
        shotsSinceLastRowDrop += 1

        currentKind = nextKind
        nextKind = .randomColor()
    }

    func tick() {
        guard !isGameOver, !isBoardCleared else { return }

        updateAimAngle()

        if activeShot != nil {
            updateShot()
        }
    }

    // MARK: - Aimer

    private func updateAimAngle() {
        guard activeShot == nil else { return }

        let minAngle: Double = -60
        let maxAngle: Double = 60
        let step: Double = 1.2

        aimAngle += step * aimDirection

        if aimAngle >= maxAngle {
            aimAngle = maxAngle
            aimDirection = -1
        } else if aimAngle <= minAngle {
            aimAngle = minAngle
            aimDirection = 1
        }
    }

    // MARK: - Shot physics / collision

    private func updateShot() {
        guard var shot = activeShot else { return }

        let bubbleRadius: Double = 0.5
        let maxY: Double = Double(rows) + 1.0

        // move
        shot.x += shot.vx
        shot.y += shot.vy

        // walls
        if shot.x <= bubbleRadius {
            shot.x = bubbleRadius
            shot.vx = abs(shot.vx)
        } else if shot.x >= Double(columns) - bubbleRadius {
            shot.x = Double(columns) - bubbleRadius
            shot.vx = -abs(shot.vx)
        }

        // miss
        if shot.y > maxY {
            activeShot = nil
            comboMultiplier = 1
            lastPopCount = 0
            return
        }

        // top
        if shot.y <= bubbleRadius {
            if shot.isBomb {
                explodeAtPosition(x: shot.x, y: shot.y)
            } else {
                attachShot(shot, collidedWithRow: nil, col: nil)
            }
            return
        }

        // collision with bubbles
        let minDist: Double = bubbleRadius * 2.0 * 0.98

        for r in 0..<rows {
            for c in 0..<columns {
                guard grid[r][c] != nil else { continue }

                let cx = Double(c) + 0.5
                let cy = Double(r) + 0.5
                let dx = shot.x - cx
                let dy = shot.y - cy
                let distSquared = dx * dx + dy * dy

                if distSquared <= minDist * minDist {
                    if shot.isBomb {
                        explodeAround(row: r, col: c)
                    } else {
                        attachShot(shot, collidedWithRow: r, col: c)
                    }
                    return
                }
            }
        }

        activeShot = shot
    }

    private func rowDropIntervalForCurrentLevel() -> Int {
        let base = baseRowDropInterval
        let reduced = base - (level - 1) * 2
        return max(6, reduced)
    }

    private func attachShot(_ shot: CBBShotBubble, collidedWithRow hitRow: Int?, col hitCol: Int?) {
        if let hr = hitRow, let hc = hitCol {
            if let (row, col) = nearestNeighborEmptyCell(aroundRow: hr, col: hc, forShotX: shot.x, y: shot.y) {
                placeShot(shot, atRow: row, col: col)
                return
            }
        }

        if let (row, col) = nearestEmptyCell(forX: shot.x, y: shot.y) {
            placeShot(shot, atRow: row, col: col)
        } else {
            activeShot = nil
            isGameOver = true
        }
    }

    private func placeShot(_ shot: CBBShotBubble, atRow row: Int, col: Int) {
        grid[row][col] = shot.kind
        activeShot = nil

        let poppedCount = resolveMatches(fromRow: row, col: col)
        updateComboAndScore(withPoppedCount: poppedCount)
        dropFloatingClusters()
        maybeAddRow()
        checkBoardStatus()
    }

    private func nearestNeighborEmptyCell(aroundRow row: Int, col: Int, forShotX x: Double, y: Double) -> (Int, Int)? {
        let deltas = [(-1, 0), (1, 0), (0, -1), (0, 1)]

        var best: (Int, Int)?
        var bestDistance = Double.greatestFiniteMagnitude

        for (dr, dc) in deltas {
            let nr = row + dr
            let nc = col + dc
            guard nr >= 0, nr < rows, nc >= 0, nc < columns else { continue }
            guard grid[nr][nc] == nil else { continue }

            let cx = Double(nc) + 0.5
            let cy = Double(nr) + 0.5
            let dx = x - cx
            let dy = y - cy
            let dist = sqrt(dx * dx + dy * dy)

            if dist < bestDistance {
                bestDistance = dist
                best = (nr, nc)
            }
        }

        return best
    }

    private func nearestEmptyCell(forX x: Double, y: Double) -> (Int, Int)? {
        var baseRow = Int(round(y - 0.5))
        var baseCol = Int(round(x - 0.5))

        baseRow = max(0, min(rows - 1, baseRow))
        baseCol = max(0, min(columns - 1, baseCol))

        if grid[baseRow][baseCol] == nil {
            return (baseRow, baseCol)
        }

        var best: (Int, Int)?
        var bestDistance = Double.greatestFiniteMagnitude

        for r in max(0, baseRow - 2)...min(rows - 1, baseRow + 2) {
            for c in max(0, baseCol - 2)...min(columns - 1, baseCol + 2) {
                guard grid[r][c] == nil else { continue }
                let cx = Double(c) + 0.5
                let cy = Double(r) + 0.5
                let dx = x - cx
                let dy = y - cy
                let dist = sqrt(dx * dx + dy * dy)
                if dist < bestDistance {
                    bestDistance = dist
                    best = (r, c)
                }
            }
        }

        return best
    }

    // MARK: - Matching / scoring

    private struct CellIndex: Hashable {
        let row: Int
        let col: Int
    }

    private func neighborsOf(row: Int, col: Int) -> [CellIndex] {
        var result: [CellIndex] = []
        let deltas = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        for (dr, dc) in deltas {
            let nr = row + dr
            let nc = col + dc
            if nr >= 0, nr < rows, nc >= 0, nc < columns {
                result.append(CellIndex(row: nr, col: nc))
            }
        }
        return result
    }

    private func resolveMatches(fromRow row: Int, col: Int) -> Int {
        guard row >= 0, row < rows, col >= 0, col < columns else { return 0 }
        guard let color = grid[row][col] else { return 0 }

        var visited: Set<CellIndex> = []
        var stack: [CellIndex] = [CellIndex(row: row, col: col)]

        while let current = stack.popLast() {
            if visited.contains(current) { continue }
            visited.insert(current)

            let neighbors = neighborsOf(row: current.row, col: current.col)
            for n in neighbors {
                if let c = grid[n.row][n.col], c == color, !visited.contains(n) {
                    stack.append(n)
                }
            }
        }

        guard visited.count >= 3 else { return 0 }

        var crateCount = 0
        for cell in visited {
            if case .bombCrate? = grid[cell.row][cell.col] {
                crateCount += 1
            }
        }

        for cell in visited {
            grid[cell.row][cell.col] = nil
        }

        if crateCount > 0 {
            bombsRemaining = min(maxBombs, bombsRemaining + crateCount)
        }

        return visited.count
    }

    private func updateComboAndScore(withPoppedCount popped: Int) {
        guard popped > 0 else {
            comboMultiplier = 1
            lastPopCount = 0
            return
        }

        if lastPopCount >= 3 {
            comboMultiplier += 1
        } else {
            comboMultiplier = 1
        }

        lastPopCount = popped
        let basePoints = popped * basePopScore
        score += basePoints * comboMultiplier
    }

    // MARK: - Bomb explosions

    private func explodeAtPosition(x: Double, y: Double) {
        activeShot = nil

        var row = Int(round(y - 0.5))
        var col = Int(round(x - 0.5))
        row = max(0, min(rows - 1, row))
        col = max(0, min(columns - 1, col))

        explodeAround(row: row, col: col)
    }

    private func explodeAround(row centerRow: Int, col centerCol: Int) {
        activeShot = nil

        var removedCells: [CellIndex] = []

        for r in max(0, centerRow - 1)...min(rows - 1, centerRow + 1) {
            for c in max(0, centerCol - 1)...min(columns - 1, centerCol + 1) {
                if grid[r][c] != nil {
                    removedCells.append(CellIndex(row: r, col: c))
                }
            }
        }

        guard !removedCells.isEmpty else {
            comboMultiplier = 1
            lastPopCount = 0
            return
        }

        var crateCount = 0
        for cell in removedCells {
            if case .bombCrate? = grid[cell.row][cell.col] {
                crateCount += 1
            }
        }

        for cell in removedCells {
            grid[cell.row][cell.col] = nil
        }

        if crateCount > 0 {
            bombsRemaining = min(maxBombs, bombsRemaining + crateCount)
        }

        let poppedCount = removedCells.count
        updateComboAndScore(withPoppedCount: poppedCount)
        dropFloatingClusters()
        maybeAddRow()
        checkBoardStatus()
    }

    // MARK: - Floating clusters

    private func dropFloatingClusters() {
        var visited = Array(
            repeating: Array(repeating: false, count: columns),
            count: rows
        )

        var stack: [CellIndex] = []

        if rows > 0 {
            for c in 0..<columns {
                if grid[0][c] != nil {
                    let idx = CellIndex(row: 0, col: c)
                    stack.append(idx)
                    visited[0][c] = true
                }
            }
        }

        while let current = stack.popLast() {
            let neighbors = neighborsOf(row: current.row, col: current.col)
            for n in neighbors {
                if !visited[n.row][n.col], grid[n.row][n.col] != nil {
                    visited[n.row][n.col] = true
                    stack.append(n)
                }
            }
        }

        var droppedCount = 0
        var crateCount = 0

        for r in 0..<rows {
            for c in 0..<columns {
                if let bubble = grid[r][c], !visited[r][c] {
                    if case .bombCrate = bubble {
                        crateCount += 1
                    }
                    grid[r][c] = nil
                    droppedCount += 1
                }
            }
        }

        if crateCount > 0 {
            bombsRemaining = min(maxBombs, bombsRemaining + crateCount)
        }

        if droppedCount > 0 {
            score += droppedCount * floatingScore
        }
    }

    // MARK: - Row drop + board status

    private func maybeAddRow() {
        guard !isGameOver, !isBoardCleared else { return }

        let currentInterval = rowDropIntervalForCurrentLevel()
        guard shotsSinceLastRowDrop >= currentInterval else { return }

        shotsSinceLastRowDrop = 0

        var newGrid: [[CBBBubbleKind?]] = Array(
            repeating: Array(repeating: nil, count: columns),
            count: rows
        )

        for r in stride(from: rows - 1, through: 1, by: -1) {
            for c in 0..<columns {
                newGrid[r][c] = grid[r - 1][c]
            }
        }

        for c in 0..<columns {
            newGrid[0][c] = CBBBubbleKind.randomWithRareCrate(probability: crateProbability)
        }

        grid = newGrid
    }

    private func checkBoardStatus() {
        for c in 0..<columns {
            if grid[rows - 1][c] != nil {
                isGameOver = true
                return
            }
        }

        let anyBubble = grid.contains { row in
            row.contains { $0 != nil }
        }
        if !anyBubble {
            isBoardCleared = true
        }
    }
}

// MARK: - BubbleGameView (Echo-style shooter + coins / AI / time HUD)

struct BubbleGameView: View {
    let mode: GameMode
    let startingCoins: Int
    let betAmount: Int

    @StateObject private var engine = CBBBubbleShooterEngine()
    private let ticker = Timer.publish(every: 0.02, on: .main, in: .common).autoconnect()
    private let secondTicker = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    @AppStorage("CBB_BestScore") private var bestScore: Int = 0

    @State private var coins: Int = 0
    @State private var timeRemaining: Int = 60
    @State private var aiScore: Int = 0

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.blue.opacity(0.8), .purple.opacity(0.9)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 12) {
                headerHUD

                GeometryReader { geo in
                    let width = geo.size.width
                    let bubbleSize = width / CGFloat(engine.columns)
                    let boardHeight = bubbleSize * CGFloat(engine.rows)

                    ZStack(alignment: .topLeading) {
                        // grid
                        ForEach(0..<engine.rows, id: \.self) { r in
                            ForEach(0..<engine.columns, id: \.self) { c in
                                if let kind = engine.grid[r][c] {
                                    if kind == .bombCrate {
                                        Circle()
                                            .fill(kind.color)
                                            .frame(width: bubbleSize * 0.9,
                                                   height: bubbleSize * 0.9)
                                            .overlay(
                                                Circle()
                                                    .strokeBorder(Color.yellow, lineWidth: 2)
                                            )
                                            .overlay(
                                                VStack(spacing: 0) {
                                                    Text("💣")
                                                    Text("+1")
                                                        .font(.caption2.bold())
                                                        .foregroundStyle(.yellow)
                                                }
                                            )
                                            .position(
                                                x: (CGFloat(c) + 0.5) * bubbleSize,
                                                y: (CGFloat(r) + 0.5) * bubbleSize
                                            )
                                            .shadow(radius: 4)
                                    } else {
                                        Circle()
                                            .fill(kind.color)
                                            .frame(width: bubbleSize * 0.9,
                                                   height: bubbleSize * 0.9)
                                            .overlay(
                                                Circle()
                                                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.6)
                                            )
                                            .position(
                                                x: (CGFloat(c) + 0.5) * bubbleSize,
                                                y: (CGFloat(r) + 0.5) * bubbleSize
                                            )
                                            .shadow(radius: 3)
                                    }
                                }
                            }
                        }

                        // flying shot
                        if let shot = engine.activeShot {
                            if shot.isBomb {
                                Circle()
                                    .fill(Color.black)
                                    .frame(width: bubbleSize,
                                           height: bubbleSize)
                                    .overlay(
                                        Circle().strokeBorder(Color.red, lineWidth: 2)
                                    )
                                    .overlay(Text("💣").font(.title3))
                                    .position(
                                        x: CGFloat(shot.x) * bubbleSize,
                                        y: CGFloat(shot.y) * bubbleSize
                                    )
                                    .shadow(radius: 5)
                            } else {
                                Circle()
                                    .fill(shot.kind.color)
                                    .frame(width: bubbleSize * 0.9,
                                           height: bubbleSize * 0.9)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.6)
                                    )
                                    .position(
                                        x: CGFloat(shot.x) * bubbleSize,
                                        y: CGFloat(shot.y) * bubbleSize
                                    )
                                    .shadow(radius: 4)
                            }
                        }

                        aimerLayer(bubbleSize: bubbleSize, boardHeight: boardHeight)
                    }
                    .frame(height: boardHeight * 1.2, alignment: .top)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        engine.fireIfPossible()
                    }
                }

                bottomControls
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            // overlay win/lose
            if engine.isGameOver || engine.isBoardCleared {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                VStack(spacing: 16) {
                    if engine.isGameOver {
                        Text("Level \(engine.level) Failed")
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)
                        Text("Bubbles reached the bottom or time ran out.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.8))
                        Button {
                            resetForReplay()
                        } label: {
                            Text("Retry Level \(engine.level)")
                                .font(.headline)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 10)
                                .background(.white)
                                .foregroundStyle(.black)
                                .clipShape(Capsule())
                        }
                    } else {
                        Text("Level \(engine.level) Cleared! 🎉")
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)
                        Text("Nice job. Ready for Level \(engine.level + 1)?")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.8))
                        HStack(spacing: 16) {
                            Button {
                                resetForReplay()
                            } label: {
                                Text("Replay Level \(engine.level)")
                                    .font(.headline)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .background(.white.opacity(0.9))
                                    .foregroundStyle(.black)
                                    .clipShape(Capsule())
                            }
                            Button {
                                engine.advanceToNextLevel()
                                timeRemaining = 60
                                aiScore = 0
                            } label: {
                                Text("Next Level →")
                                    .font(.headline)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .background(Color.yellow)
                                    .foregroundStyle(.black)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            coins = startingCoins - betAmount
            timeRemaining = 60
            aiScore = 0
        }
        .onReceive(ticker) { _ in
            engine.tick()
        }
        .onReceive(secondTicker) { _ in
            tickSecond()
        }
        .onChange(of: engine.score) { oldScore, newScore in
            if newScore > bestScore {
                bestScore = newScore
            }
            // simple coin drip based on score
            let bonus = newScore / 20
            coins = max(0, startingCoins - betAmount + bonus)
        }
    }

    // MARK: - HUD / controls

    private var headerHUD: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chaotic Bubble Burst")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(mode == .soloTimed ? "Solo Chaos Rush" : "Race the AI")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                }
                Spacer()
                Text("Lvl \(engine.level)")
                    .font(.headline.bold())
                    .foregroundColor(.yellow)
            }

            HStack(spacing: 16) {
                statBlock(title: "Combo", value: "x\(engine.comboMultiplier)")
                statBlock(title: "Score", value: "\(engine.score)")
                statBlock(title: "Best", value: "\(bestScore)")
                statBlock(title: "Shots", value: "\(engine.shotsFired)")
            }

            HStack {
                Text("Coins: \(coins)")
                    .foregroundColor(.yellow)
                    .bold()

                if mode == .vsAI {
                    Spacer()
                    Text("AI: \(aiScore)")
                        .foregroundColor(.white.opacity(0.9))
                }

                Spacer()
                Text("Time: \(timeRemaining)s")
                    .font(.headline)
                    .foregroundColor(timeRemaining <= 10 ? .red : .white)
            }
        }
    }

    private func statBlock(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
            Text(value)
                .font(.subheadline.bold())
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
    }

    private func aimerLayer(bubbleSize: CGFloat, boardHeight: CGFloat) -> some View {
        let originX = CGFloat(engine.shooterOriginX) * bubbleSize
        let originY = CGFloat(engine.shooterOriginY) * bubbleSize

        let angle = engine.aimAngle * .pi / 180.0
        let lineLength = boardHeight

        let targetX = originX + CGFloat(sin(angle)) * lineLength
        let targetY = originY + CGFloat(-cos(angle)) * lineLength

        return ZStack {
            Path { path in
                path.move(to: CGPoint(x: originX, y: originY))
                path.addLine(to: CGPoint(x: targetX, y: targetY))
            }
            .stroke(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .foregroundStyle(.white.opacity(0.5))

            Circle()
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                .background(
                    Circle()
                        .fill(engine.currentKind.color.opacity(0.95))
                )
                .frame(width: bubbleSize * 0.9, height: bubbleSize * 0.9)
                .position(x: originX, y: originY)
                .shadow(radius: 4)
        }
    }

    private var bottomControls: some View {
        HStack(spacing: 16) {
            HStack(spacing: 14) {
                VStack(spacing: 4) {
                    Text("Shooter")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                    Circle()
                        .fill(engine.currentKind.color)
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                        )
                }
                VStack(spacing: 4) {
                    Text("Next")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                    Circle()
                        .fill(engine.nextKind.color)
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(0.8), lineWidth: 1.3)
                        )
                }
            }

            Spacer()

            Button {
                if engine.bombsRemaining > 0 {
                    engine.isBombMode.toggle()
                } else {
                    engine.isBombMode = false
                }
            } label: {
                HStack(spacing: 6) {
                    Text("💣")
                    Text("x\(engine.bombsRemaining)")
                        .font(.caption.bold())
                    Text(engine.isBombMode ? "READY" : "Tap to load bomb")
                        .font(.caption2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(engine.bombsRemaining > 0 && engine.isBombMode
                            ? Color.red.opacity(0.7)
                            : Color.white.opacity(0.18))
                .foregroundStyle(engine.bombsRemaining > 0 ? .white : .gray)
                .clipShape(Capsule())
            }
            .disabled(engine.bombsRemaining == 0)

            Button {
                resetForReplay()
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Restart L\(engine.level)")
                }
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.white.opacity(0.18))
                .clipShape(Capsule())
            }
        }
        .padding(.bottom, 12)
    }

    // MARK: - Timer logic & helpers

    private func tickSecond() {
        guard !engine.isGameOver, !engine.isBoardCleared else { return }

        if timeRemaining > 0 {
            timeRemaining -= 1
        }

        if mode == .vsAI {
            // simple fake AI progress
            aiScore += Int.random(in: 8...18)
        }

        if timeRemaining == 0 {
            engine.isGameOver = true
        }
    }

    private func resetForReplay() {
        engine.restartCurrentLevel()
        timeRemaining = 60
        aiScore = 0
        coins = startingCoins - betAmount
    }
}

// MARK: - Preview

struct BubbleGameView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            BubbleGameView(
                mode: .soloTimed,
                startingCoins: 100,
                betAmount: 10
            )
        }
    }
}
