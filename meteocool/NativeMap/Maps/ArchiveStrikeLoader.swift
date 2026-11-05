//
//  ArchiveStrikeLoader.swift
//  meteocool
//
//  The strikes of a past window, from `/v3/lightning/strikes`.
//

import Foundation

/// Fetches and keeps the three-hour chunks of strikes a past window's steps
/// need (`ArchiveStrikes`), so scrubbing and playing ask each chunk once.
@MainActor
final class ArchiveStrikeLoader {
    /// Chunks kept: two days of strikes, more than any window shows.
    private static let kept = 16

    private weak var map: NativeMapContext?
    private var chunks: [ArchiveStrikes.Chunk: [LightningRules.Strike]] = [:]
    private var order: [ArchiveStrikes.Chunk] = []
    private var asked = Set<ArchiveStrikes.Chunk>()
    private var generation = 0
    /// A chunk came in: the step on screen may draw more now.
    var onLoad: (() -> Void)?

    init(map: NativeMapContext?) {
        self.map = map
    }

    /// The strikes shown at `step`: the half hour before it, from what is
    /// held; the chunks missing are asked for, and `onLoad` says when.
    func strikes(at step: Int) -> [LightningRules.Strike] {
        let now = Int(Date().timeIntervalSince1970)
        var shown: [LightningRules.Strike] = []
        for chunk in ArchiveStrikes.chunks(at: step, now: now) {
            if let held = chunks[chunk] {
                shown += held.filter { ArchiveStrikes.shown($0.milliseconds, at: step) }
            } else {
                ask(chunk)
            }
        }
        return shown
    }

    /// Forgets everything: another window, or live.
    func clear() {
        generation += 1
        chunks = [:]
        order = []
        asked = []
    }

    private func ask(_ chunk: ArchiveStrikes.Chunk) {
        guard let map, !asked.contains(chunk) else { return }
        asked.insert(chunk)
        let generation = generation
        map.fetch(map.endpoints.strikes(since: chunk.since, until: chunk.until)) { [weak self] data, _ in
            guard let self, generation == self.generation else { return }
            guard let strikes = data.flatMap(LightningRules.backfill) else {
                // Asked again on the next step that needs it.
                self.asked.remove(chunk)
                return
            }
            self.chunks[chunk] = strikes
            self.order.append(chunk)
            if self.order.count > Self.kept {
                let dropped = self.order.removeFirst()
                self.chunks[dropped] = nil
                self.asked.remove(dropped)
            }
            self.onLoad?()
        }
    }
}
