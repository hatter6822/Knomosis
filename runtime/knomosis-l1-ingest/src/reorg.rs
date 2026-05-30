// SPDX-License-Identifier: GPL-3.0-or-later
// Knomosis  - A Societal Kernel
// Copyright (C) 2026  Adam Hall
// This program comes with ABSOLUTELY NO WARRANTY.
// This is free software, and you are welcome to redistribute it
// under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE

//! Sliding-window block-hash tracker for L1 re-org detection.
//!
//! ## What this module does
//!
//! Tracks the most recent `WINDOW` block headers (number + hash +
//! parent hash) so the watcher can detect re-orgs by walking
//! backwards from a newly-seen block until it finds a parent-hash
//! match.  Shallow re-orgs (depth ≤ window) are absorbed; deeper
//! re-orgs surface a typed error so the daemon can halt with an
//! operator alert.
//!
//! ## Why this isn't a stack
//!
//! Re-orgs may rewrite arbitrary depths within the window; a pure
//! stack pattern only handles "single-fork" re-orgs.  A
//! `VecDeque<BlockHeader>` indexed by block number gives us
//! `O(1)` extend/truncate operations plus `O(window)` re-org
//! walks — the right shape for the workload.
//!
//! ## Shared-with-RH-G note
//!
//! The plan §RH-B.4 / §RH-G.2 explicitly recommends sharing this
//! module across RH-B (L1 ingestor) and RH-G (fault-proof
//! observer).  The data structure is intentionally generic over
//! the consumer; future RH-G work will dev-dep on this crate (or
//! `knomosis-cli-common` if we choose to move the module there in a
//! follow-up).

use std::collections::VecDeque;

use crate::events::TopicHash;

/// A minimal block header: number, hash, parent hash.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub struct BlockHeader {
    /// L1 block number.
    pub number: u64,
    /// 32-byte block hash.
    pub hash: TopicHash,
    /// The parent block's 32-byte hash.
    pub parent_hash: TopicHash,
}

/// Errors surfaced by the [`ReorgWindow`].
#[derive(Debug, Eq, PartialEq, thiserror::Error)]
pub enum ReorgError {
    /// The window saw a block whose number is lower than the
    /// oldest cached block number.  Means a re-org deeper than
    /// the window occurred; the daemon must halt and the
    /// operator must intervene.
    #[error(
        "deep re-org detected: incoming block {incoming_number} predates window floor \
         {window_floor}"
    )]
    DeepReorg {
        /// The number of the incoming block.
        incoming_number: u64,
        /// The oldest block number still in the window.
        window_floor: u64,
    },
    /// The window saw a block whose parent hash doesn't match
    /// any cached block in the window.  Synthesises the same
    /// failure mode as `DeepReorg`: the operator must intervene.
    #[error(
        "deep re-org: incoming block {incoming_number} parent hash does not match any \
         cached block"
    )]
    OrphanedParent {
        /// The number of the incoming block.
        incoming_number: u64,
    },
    /// Non-monotone block numbers (a gap).  Means the upstream
    /// L1 source skipped blocks; the watcher must back off and
    /// retry.
    #[error("incoming block {incoming_number} is non-monotone w.r.t. last seen {last_seen}")]
    NonMonotone {
        /// The incoming block number.
        incoming_number: u64,
        /// The last seen block number.
        last_seen: u64,
    },
}

/// Outcome of feeding a block into the window.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AdvanceOutcome {
    /// The block linearly extended the window (parent of
    /// incoming = hash of last cached).  No re-org; the watcher
    /// advances normally.
    Advanced,
    /// A re-org happened.  The window dropped the last
    /// `dropped_count` blocks (and replaced the head with
    /// `incoming`).  The watcher must re-process events from
    /// `dropped_from_number` forward, or discard them if they
    /// haven't been forwarded yet (confirmation_depth window).
    Reorged {
        /// How many cached blocks were dropped from the tail.
        dropped_count: usize,
        /// The first block number that was dropped.  Events from
        /// this number onward in the old chain are no longer
        /// canonical.
        dropped_from_number: u64,
    },
}

/// A bounded sliding window of recent block headers.  Width is
/// fixed at construction time; we recommend setting it to at
/// least `confirmation_depth + 1` so the watcher can detect
/// re-orgs up to its forwarding horizon.
///
/// ## Invariants
///
///   * The `buffer` is in ascending block-number order.
///   * `buffer[i+1].parent_hash == buffer[i].hash` for every
///     adjacent pair (the "linearity" invariant).
///   * `buffer.len() <= capacity`.
///
/// ## Operations
///
///   * [`Self::seed`] — initialise the window from a chain tip;
///     bypasses the linearity check (used at startup).
///   * [`Self::advance`] — feed an incoming block; returns
///     `AdvanceOutcome` or `ReorgError`.
///   * [`Self::head`] — peek at the current head (highest block).
///   * [`Self::contains_hash`] — check whether `hash` is in the
///     window.
#[derive(Clone, Debug)]
pub struct ReorgWindow {
    capacity: usize,
    buffer: VecDeque<BlockHeader>,
}

impl ReorgWindow {
    /// Construct an empty window with the given capacity.  A
    /// capacity of 0 is rejected at runtime via `assert!` since
    /// a zero-width window cannot detect re-orgs.
    #[must_use]
    pub fn new(capacity: usize) -> Self {
        assert!(capacity > 0, "ReorgWindow capacity must be > 0");
        Self {
            capacity,
            buffer: VecDeque::with_capacity(capacity),
        }
    }

    /// Configured window capacity.
    #[must_use]
    pub fn capacity(&self) -> usize {
        self.capacity
    }

    /// Current number of cached headers.
    #[must_use]
    pub fn len(&self) -> usize {
        self.buffer.len()
    }

    /// `true` iff no headers are cached.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.buffer.is_empty()
    }

    /// Clear all cached headers.  Used by the `--start-block`
    /// override path (audit-pass-4-round-5 fix) where the
    /// operator-supplied cursor jumps the watcher to a new
    /// chain position; the persisted reorg window would
    /// otherwise be stale and cause spurious `OrphanedParent`
    /// errors on the next iteration.
    pub fn clear(&mut self) {
        self.buffer.clear();
    }

    /// Initialise the window from a sequence of headers.  Used at
    /// startup when the daemon resumes from a previous run; the
    /// caller is expected to have read the headers from storage
    /// in ascending order.  Replaces any existing window content.
    pub fn seed(&mut self, headers: impl IntoIterator<Item = BlockHeader>) {
        self.buffer.clear();
        for h in headers {
            if self.buffer.len() == self.capacity {
                self.buffer.pop_front();
            }
            self.buffer.push_back(h);
        }
    }

    /// Peek at the current head (highest block) of the window.
    /// Returns `None` if the window is empty.
    #[must_use]
    pub fn head(&self) -> Option<BlockHeader> {
        self.buffer.back().copied()
    }

    /// Peek at the tail (oldest block) of the window.  Returns
    /// `None` if the window is empty.
    #[must_use]
    pub fn tail(&self) -> Option<BlockHeader> {
        self.buffer.front().copied()
    }

    /// `true` iff `hash` matches any cached block's hash.
    #[must_use]
    pub fn contains_hash(&self, hash: &TopicHash) -> bool {
        self.buffer.iter().any(|h| &h.hash == hash)
    }

    /// Iterate the window's headers in ascending block-number
    /// order (tail-to-head).  Used by downstream consumers
    /// (e.g., the knomosis-faultproof-observer's persistence
    /// layer) to snapshot the window for restart-time
    /// resume.  Available since knomosis-l1-ingest v0.2.4.
    pub fn iter(&self) -> impl Iterator<Item = &BlockHeader> {
        self.buffer.iter()
    }

    /// Collect the window into a `Vec<BlockHeader>` for
    /// serialisation / snapshotting.  Convenience over
    /// `iter().copied().collect()`.
    #[must_use]
    pub fn to_vec(&self) -> Vec<BlockHeader> {
        self.buffer.iter().copied().collect()
    }

    /// Feed an incoming block.  Returns:
    ///
    ///   * `Ok(AdvanceOutcome::Advanced)` if the block linearly
    ///     extends the window.
    ///   * `Ok(AdvanceOutcome::Reorged { ... })` if the block
    ///     forks the chain at some depth within the window.
    ///   * `Err(ReorgError::DeepReorg)` if the block's number is
    ///     lower than the window's oldest cached block.
    ///   * `Err(ReorgError::OrphanedParent)` if the block's
    ///     parent hash doesn't match any cached block.
    ///   * `Err(ReorgError::NonMonotone)` if there's a gap
    ///     between `last_seen + 1` and the incoming block number.
    ///
    /// On a re-org, the window is updated to truncate the
    /// orphaned blocks and append the incoming block as the new
    /// head.
    ///
    /// # Errors
    ///
    /// See above.  Each variant is a typed `ReorgError`.
    pub fn advance(&mut self, incoming: BlockHeader) -> Result<AdvanceOutcome, ReorgError> {
        let last = match self.head() {
            None => {
                // First-ever block: just push.
                self.buffer.push_back(incoming);
                return Ok(AdvanceOutcome::Advanced);
            }
            Some(h) => h,
        };
        let window_floor = self.tail().map_or(last.number, |h| h.number);
        // Reject re-orgs that go below or to the floor of the
        // window: those can never be resolved by the walk-back
        // search (there's no in-window parent to find).  Both
        // "below floor" and "at floor" surface as `DeepReorg`
        // — semantically a re-org that the window cannot
        // accommodate.
        if incoming.number <= window_floor {
            return Err(ReorgError::DeepReorg {
                incoming_number: incoming.number,
                window_floor,
            });
        }
        if incoming.number == last.number + 1 && incoming.parent_hash == last.hash {
            // Linear extension.
            if self.buffer.len() == self.capacity {
                self.buffer.pop_front();
            }
            self.buffer.push_back(incoming);
            return Ok(AdvanceOutcome::Advanced);
        }
        if incoming.number <= last.number {
            // Re-org case: incoming block claims to be at a
            // height we've already seen.  Walk back through the
            // window looking for a block whose hash matches the
            // incoming parent (which means incoming is a sibling
            // of that-block-plus-one in the new chain).
            // We need parent_match_index = i such that buffer[i].hash == incoming.parent_hash.
            // We will drop everything from i+1 onward and append the new block.
            let mut found_at: Option<usize> = None;
            for (i, h) in self.buffer.iter().enumerate().rev() {
                if h.hash == incoming.parent_hash && h.number + 1 == incoming.number {
                    found_at = Some(i);
                    break;
                }
            }
            let i = found_at.ok_or(ReorgError::OrphanedParent {
                incoming_number: incoming.number,
            })?;
            let dropped_count = self.buffer.len().saturating_sub(i + 1);
            let dropped_from_number = self.buffer.get(i + 1).map_or(incoming.number, |h| h.number);
            self.buffer.truncate(i + 1);
            self.buffer.push_back(incoming);
            return Ok(AdvanceOutcome::Reorged {
                dropped_count,
                dropped_from_number,
            });
        }
        // incoming.number > last.number + 1: gap.
        if incoming.number > last.number + 1 {
            return Err(ReorgError::NonMonotone {
                incoming_number: incoming.number,
                last_seen: last.number,
            });
        }
        // incoming.number == last.number + 1 but parent_hash
        // doesn't match: a 1-block re-org where the parent we
        // expected isn't current.  Walk back to find the parent.
        let mut found_at: Option<usize> = None;
        for (i, h) in self.buffer.iter().enumerate().rev() {
            if h.hash == incoming.parent_hash && h.number + 1 == incoming.number {
                found_at = Some(i);
                break;
            }
        }
        let i = found_at.ok_or(ReorgError::OrphanedParent {
            incoming_number: incoming.number,
        })?;
        let dropped_count = self.buffer.len().saturating_sub(i + 1);
        let dropped_from_number = self.buffer.get(i + 1).map_or(incoming.number, |h| h.number);
        self.buffer.truncate(i + 1);
        self.buffer.push_back(incoming);
        Ok(AdvanceOutcome::Reorged {
            dropped_count,
            dropped_from_number,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{AdvanceOutcome, BlockHeader, ReorgError, ReorgWindow};

    /// Build a chain of `count` linearly-linked headers starting at
    /// block number `start`.  Each header's hash is `[start_byte;
    /// 32]` and the parent hash is its predecessor's hash (or
    /// zero for the first block).  Useful for synthesising
    /// fixtures.
    fn linear_chain(count: usize, start: u64, hash_seed: u8) -> Vec<BlockHeader> {
        let mut out = Vec::with_capacity(count);
        let mut last_hash = [0u8; 32];
        for i in 0..count {
            let mut hash = [0u8; 32];
            hash[0] = hash_seed.wrapping_add(i as u8);
            hash[31] = (start as u8).wrapping_add(i as u8);
            let h = BlockHeader {
                number: start + i as u64,
                hash,
                parent_hash: last_hash,
            };
            last_hash = hash;
            out.push(h);
        }
        out
    }

    /// A fresh window is empty.
    #[test]
    fn new_window_is_empty() {
        let w = ReorgWindow::new(12);
        assert_eq!(w.len(), 0);
        assert!(w.is_empty());
        assert_eq!(w.capacity(), 12);
        assert!(w.head().is_none());
        assert!(w.tail().is_none());
    }

    /// Window capacity 0 panics at construction.
    #[test]
    #[should_panic(expected = "ReorgWindow capacity must be > 0")]
    fn new_window_zero_capacity_panics() {
        let _ = ReorgWindow::new(0);
    }

    /// Linear advance extends the window.
    #[test]
    fn linear_advance() {
        let mut w = ReorgWindow::new(4);
        let chain = linear_chain(3, 100, 1);
        for h in &chain {
            let outcome = w.advance(*h).unwrap();
            assert_eq!(outcome, AdvanceOutcome::Advanced);
        }
        assert_eq!(w.len(), 3);
        assert_eq!(w.head().unwrap().number, 102);
        assert_eq!(w.tail().unwrap().number, 100);
    }

    /// Linear advance trims the tail when at capacity.
    #[test]
    fn capacity_trims_tail() {
        let mut w = ReorgWindow::new(2);
        let chain = linear_chain(4, 100, 1);
        for h in &chain {
            w.advance(*h).unwrap();
        }
        assert_eq!(w.len(), 2);
        // Window now holds blocks 102 and 103.
        assert_eq!(w.tail().unwrap().number, 102);
        assert_eq!(w.head().unwrap().number, 103);
    }

    /// `contains_hash` finds cached headers.
    #[test]
    fn contains_hash() {
        let mut w = ReorgWindow::new(4);
        let chain = linear_chain(3, 100, 1);
        for h in &chain {
            w.advance(*h).unwrap();
        }
        assert!(w.contains_hash(&chain[1].hash));
        assert!(!w.contains_hash(&[0xff; 32]));
    }

    /// A gap in block numbers returns `NonMonotone`.
    #[test]
    fn gap_returns_non_monotone() {
        let mut w = ReorgWindow::new(4);
        let initial = linear_chain(1, 100, 1);
        w.advance(initial[0]).unwrap();
        // Skip block 101: try to advance with block 102.
        let mut h = BlockHeader {
            number: 102,
            hash: [0xaa; 32],
            parent_hash: initial[0].hash,
        };
        h.hash[31] = 0xaa;
        let err = w.advance(h).unwrap_err();
        assert!(matches!(err, ReorgError::NonMonotone { .. }));
    }

    /// Shallow re-org: drop the head, replace with a sibling.
    #[test]
    fn shallow_reorg_single_block() {
        let mut w = ReorgWindow::new(4);
        let chain = linear_chain(3, 100, 1);
        for h in &chain {
            w.advance(*h).unwrap();
        }
        // The canonical chain forks at block 102 with a sibling.
        let sibling = BlockHeader {
            number: 102,
            hash: [0xff; 32],
            // Parent is block 101 (the second-to-last cached).
            parent_hash: chain[1].hash,
        };
        let outcome = w.advance(sibling).unwrap();
        match outcome {
            AdvanceOutcome::Reorged {
                dropped_count,
                dropped_from_number,
            } => {
                assert_eq!(dropped_count, 1, "dropped exactly 1 block (the old head)");
                assert_eq!(
                    dropped_from_number, 102,
                    "dropped from block 102 (the orphaned head)"
                );
            }
            other => panic!("expected Reorged outcome, got {other:?}"),
        }
        // After re-org, head is the sibling.
        assert_eq!(w.head().unwrap().hash, sibling.hash);
        assert_eq!(w.head().unwrap().number, 102);
    }

    /// 2-block shallow re-org.
    #[test]
    fn shallow_reorg_two_blocks() {
        let mut w = ReorgWindow::new(8);
        let chain = linear_chain(4, 100, 1);
        for h in &chain {
            w.advance(*h).unwrap();
        }
        // New chain forks at block 102 (parent = block 101).
        let new_102 = BlockHeader {
            number: 102,
            hash: [0xee; 32],
            parent_hash: chain[1].hash,
        };
        let outcome = w.advance(new_102).unwrap();
        match outcome {
            AdvanceOutcome::Reorged {
                dropped_count,
                dropped_from_number,
            } => {
                // Old head was block 103; we dropped blocks 102 and 103.
                assert_eq!(dropped_count, 2);
                assert_eq!(dropped_from_number, 102);
            }
            other => panic!("expected Reorged, got {other:?}"),
        }
        assert_eq!(w.head().unwrap().number, 102);
    }

    /// A re-org attempting to insert a block whose number is AT
    /// or BELOW the window floor returns `DeepReorg`.
    #[test]
    fn block_at_window_floor_returns_deep_reorg() {
        let mut w = ReorgWindow::new(2);
        let chain = linear_chain(2, 100, 1);
        for h in &chain {
            w.advance(*h).unwrap();
        }
        // Window now holds blocks 100 and 101.  An "at floor"
        // incoming block (number 100) cannot have its parent in
        // the window (parent would be at number 99, outside the
        // window).  Return DeepReorg.
        let orphan = BlockHeader {
            number: 100,
            hash: [0xff; 32],
            parent_hash: [0xee; 32],
        };
        let err = w.advance(orphan).unwrap_err();
        match err {
            ReorgError::DeepReorg {
                incoming_number,
                window_floor,
            } => {
                assert_eq!(incoming_number, 100);
                assert_eq!(window_floor, 100);
            }
            other => panic!("expected DeepReorg, got {other:?}"),
        }
    }

    /// `OrphanedParent` is reserved for the case where the
    /// incoming block is within the window's number range but
    /// no in-window block has the expected parent hash.
    #[test]
    fn unknown_parent_within_range_returns_orphaned_parent() {
        let mut w = ReorgWindow::new(8);
        let chain = linear_chain(4, 100, 1);
        for h in &chain {
            w.advance(*h).unwrap();
        }
        // Window: 100, 101, 102, 103.  Incoming claims to be
        // block 102 with parent_hash that doesn't match block 101
        // (or any other in-window block).  Block 102 > floor 100,
        // so this is `OrphanedParent`, not `DeepReorg`.
        let orphan = BlockHeader {
            number: 102,
            hash: [0xff; 32],
            parent_hash: [0xee; 32], // does not match any cached block
        };
        let err = w.advance(orphan).unwrap_err();
        match err {
            ReorgError::OrphanedParent { incoming_number } => {
                assert_eq!(incoming_number, 102);
            }
            other => panic!("expected OrphanedParent, got {other:?}"),
        }
    }

    /// Seeding clears any prior state.
    #[test]
    fn seed_replaces_state() {
        let mut w = ReorgWindow::new(4);
        let chain1 = linear_chain(3, 100, 1);
        for h in &chain1 {
            w.advance(*h).unwrap();
        }
        // Seed with a different chain.
        let chain2 = linear_chain(2, 200, 9);
        w.seed(chain2.iter().copied());
        assert_eq!(w.len(), 2);
        assert_eq!(w.tail().unwrap().number, 200);
        assert_eq!(w.head().unwrap().number, 201);
    }

    /// Seeding more than capacity drops oldest entries.
    #[test]
    fn seed_respects_capacity() {
        let mut w = ReorgWindow::new(3);
        let chain = linear_chain(5, 100, 1);
        w.seed(chain.iter().copied());
        assert_eq!(w.len(), 3);
        // The 3 most recent: blocks 102, 103, 104.
        assert_eq!(w.tail().unwrap().number, 102);
        assert_eq!(w.head().unwrap().number, 104);
    }

    /// A re-org followed by linear advance from the new head.
    #[test]
    fn reorg_then_advance() {
        let mut w = ReorgWindow::new(8);
        let chain = linear_chain(4, 100, 1);
        for h in &chain {
            w.advance(*h).unwrap();
        }
        // Re-org at block 102.
        let new_102 = BlockHeader {
            number: 102,
            hash: [0xee; 32],
            parent_hash: chain[1].hash,
        };
        w.advance(new_102).unwrap();
        // Then linear extension from new_102.
        let new_103 = BlockHeader {
            number: 103,
            hash: [0xdd; 32],
            parent_hash: new_102.hash,
        };
        let outcome = w.advance(new_103).unwrap();
        assert_eq!(outcome, AdvanceOutcome::Advanced);
        assert_eq!(w.head().unwrap().number, 103);
    }

    /// Sequential reorgs are correctly tracked.
    #[test]
    fn multiple_reorgs_sequence() {
        let mut w = ReorgWindow::new(8);
        let initial = linear_chain(3, 100, 1);
        for h in &initial {
            w.advance(*h).unwrap();
        }
        // First reorg: drop block 102.
        let sibling1 = BlockHeader {
            number: 102,
            hash: [0xee; 32],
            parent_hash: initial[1].hash,
        };
        w.advance(sibling1).unwrap();
        // Second reorg: drop sibling1.
        let sibling2 = BlockHeader {
            number: 102,
            hash: [0xff; 32],
            parent_hash: initial[1].hash,
        };
        let outcome = w.advance(sibling2).unwrap();
        match outcome {
            AdvanceOutcome::Reorged { dropped_count, .. } => assert_eq!(dropped_count, 1),
            _ => panic!("expected Reorged"),
        }
        assert_eq!(w.head().unwrap().hash, sibling2.hash);
    }

    /// Capacity-1 window: only remembers the most recent block.
    /// Linear extensions work; any re-org attempt fails with
    /// `DeepReorg` (no slot to walk back into).
    #[test]
    fn capacity_1_window_linear_then_reorg_rejected() {
        let mut w = ReorgWindow::new(1);
        let chain = linear_chain(3, 100, 1);
        for h in &chain {
            let outcome = w.advance(*h).unwrap();
            assert_eq!(outcome, AdvanceOutcome::Advanced);
        }
        // Window now holds only block 102.
        assert_eq!(w.len(), 1);
        assert_eq!(w.head().unwrap().number, 102);
        // A 1-block re-org of block 102 needs to walk back to
        // block 101's hash, but block 101 is no longer in the
        // window.  Therefore: DeepReorg (at-floor) since
        // `incoming.number (102) <= window_floor (102)`.
        let sibling = BlockHeader {
            number: 102,
            hash: [0xff; 32],
            parent_hash: chain[1].hash, // hash of block 101
        };
        let err = w.advance(sibling).unwrap_err();
        match err {
            ReorgError::DeepReorg {
                incoming_number,
                window_floor,
            } => {
                assert_eq!(incoming_number, 102);
                assert_eq!(window_floor, 102);
            }
            other => panic!("expected DeepReorg, got {other:?}"),
        }
    }

    /// REGRESSION: when the window is at capacity and we
    /// advance linearly, the OLDEST block is dropped — NOT the
    /// newest.  Subsequent re-orgs against the dropped block
    /// fail correctly.
    #[test]
    fn capacity_drops_oldest_on_linear_advance() {
        let mut w = ReorgWindow::new(3);
        let chain = linear_chain(5, 100, 1);
        for h in &chain {
            w.advance(*h).unwrap();
        }
        assert_eq!(w.len(), 3);
        // After 5 linear advances with capacity 3: window holds 102, 103, 104.
        assert_eq!(w.tail().unwrap().number, 102);
        assert_eq!(w.head().unwrap().number, 104);
        // A re-org targeting block 101 (which was dropped from
        // the window) fails: `incoming.number (101) <
        // window_floor (102)` → DeepReorg.
        let orphan = BlockHeader {
            number: 101,
            hash: [0xee; 32],
            parent_hash: chain[0].hash,
        };
        let err = w.advance(orphan).unwrap_err();
        assert!(matches!(err, ReorgError::DeepReorg { .. }));
    }

    /// `iter()` returns headers in ascending block-number order.
    #[test]
    fn iter_returns_ascending_order() {
        let mut w = ReorgWindow::new(4);
        let chain = linear_chain(3, 100, 1);
        for h in &chain {
            w.advance(*h).unwrap();
        }
        let collected: Vec<u64> = w.iter().map(|h| h.number).collect();
        assert_eq!(collected, vec![100, 101, 102]);
    }

    /// `to_vec()` produces the same ordering as `iter()`.
    #[test]
    fn to_vec_matches_iter() {
        let mut w = ReorgWindow::new(4);
        let chain = linear_chain(3, 100, 1);
        for h in &chain {
            w.advance(*h).unwrap();
        }
        let v = w.to_vec();
        let i: Vec<BlockHeader> = w.iter().copied().collect();
        assert_eq!(v, i);
    }

    /// `to_vec()` on an empty window returns an empty `Vec`.
    #[test]
    fn to_vec_empty_window() {
        let w = ReorgWindow::new(4);
        assert!(w.to_vec().is_empty());
    }
}
