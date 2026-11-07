import Foundation
import os

/// Lock-protected SPSC ring buffer for non-interleaved stereo Float32 audio. The tap thread
/// writes; the HAL Output render callback reads. An os_unfair_lock is used because pure atomic
/// ordering for a wrap-around index pair in Swift requires more ceremony than the latency
/// difference is worth at typical audio buffer sizes (~5 ms).
final class StereoFloatRingBuffer {
    private var left: UnsafeMutablePointer<Float>
    private var right: UnsafeMutablePointer<Float>
    let capacity: Int
    private var writeIdx: Int = 0
    private var readIdx: Int = 0
    private var lock = os_unfair_lock()

    // Per-read gain envelope. The reader (HAL render callback) multiplies each
    // sample by `currentGain`, which linearly ramps toward `targetGain` over
    // `rampFramesRemaining` more *actually-consumed* frames. The ramp only
    // advances on real reads — padding zeros don't move it — so that a fade-in
    // armed during the engine restart waits for fresh samples to land in the
    // ring before scaling them, rather than burning the ramp on the empty
    // post-teardown window.
    private var currentGain: Float = 1.0
    private var targetGain: Float = 1.0
    private var rampStep: Float = 0
    private var rampFramesRemaining: Int = 0

    /// Diagnostic counter — incremented every time `read()` is short of
    /// frames (writer fell behind, reader hit the empty/wrap edge of the
    /// buffer and got zero-padded). Cleared by `resetUnderrunCount()`.
    /// Read from the main thread; written from the audio thread under the
    /// existing lock.
    private(set) var underrunReads: Int = 0
    /// Diagnostic: the smallest non-zero amount by which a `read()` fell
    /// short, in frames. Tells us "how bad was the worst underrun" so we
    /// can tell a single-frame edge case apart from a real drain.
    private(set) var worstUnderrunShortfall: Int = 0

    init(capacityFrames: Int) {
        let validCapacity = max(1024, capacityFrames)
        self.capacity = validCapacity
        left = .allocate(capacity: validCapacity)
        right = .allocate(capacity: validCapacity)
        left.initialize(repeating: 0, count: validCapacity)
        right.initialize(repeating: 0, count: validCapacity)
    }

    deinit {
        left.deinitialize(count: capacity)
        right.deinitialize(count: capacity)
        left.deallocate()
        right.deallocate()
    }

    @discardableResult
    func write(left lsrc: UnsafePointer<Float>, right rsrc: UnsafePointer<Float>, frames: Int) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let available = capacity - (writeIdx - readIdx)
        let n = min(available, frames)
        if n <= 0 { return 0 }

        let w = writeIdx % capacity
        let byteCount = n * MemoryLayout<Float>.stride
        if w + n <= capacity {
            memcpy(left.advanced(by: w), lsrc, byteCount)
            memcpy(right.advanced(by: w), rsrc, byteCount)
        } else {
            let first = capacity - w
            let firstBytes = first * MemoryLayout<Float>.stride
            let remBytes = (n - first) * MemoryLayout<Float>.stride
            memcpy(left.advanced(by: w), lsrc, firstBytes)
            memcpy(right.advanced(by: w), rsrc, firstBytes)
            memcpy(left, lsrc.advanced(by: first), remBytes)
            memcpy(right, rsrc.advanced(by: first), remBytes)
        }
        writeIdx += n
        return n
    }

    /// Reads up to `frames` frames into `ldst` / `rdst`. If the buffer is short, the tail is
    /// zero-padded so the consumer gets a full frames-worth of audio (a brief glitch is better
    /// than passing garbage uninitialized memory to the audio output).
    @discardableResult
    func read(left ldst: UnsafeMutablePointer<Float>, right rdst: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let available = max(0, writeIdx - readIdx)
        let n = max(0, min(available, frames))

        if n > 0 {
            let r = readIdx % capacity
            let byteCount = n * MemoryLayout<Float>.stride
            if r + n <= capacity {
                memcpy(ldst, left.advanced(by: r), byteCount)
                memcpy(rdst, right.advanced(by: r), byteCount)
            } else {
                let first = capacity - r
                let firstBytes = first * MemoryLayout<Float>.stride
                let remBytes = (n - first) * MemoryLayout<Float>.stride
                memcpy(ldst, left.advanced(by: r), firstBytes)
                memcpy(rdst, right.advanced(by: r), firstBytes)
                memcpy(ldst.advanced(by: first), left, remBytes)
                memcpy(rdst.advanced(by: first), right, remBytes)
            }
            readIdx += n
            applyGainEnvelope(left: ldst, right: rdst, frames: n)
        }

        if n < frames {
            let shortfall = frames - n
            let zeroBytes = shortfall * MemoryLayout<Float>.stride
            memset(ldst.advanced(by: n), 0, zeroBytes)
            memset(rdst.advanced(by: n), 0, zeroBytes)
            underrunReads &+= 1
            if shortfall > worstUnderrunShortfall {
                worstUnderrunShortfall = shortfall
            }
        }
        return n
    }

    /// Clear the underrun counters without blocking real-time audio threads. Main thread.
    func resetUnderrunCount() {
        if os_unfair_lock_trylock(&lock) {
            underrunReads = 0
            worstUnderrunShortfall = 0
            os_unfair_lock_unlock(&lock)
        }
    }

    /// Snapshot `(reads, worstShortfallFrames, availableFrames)` for
    /// periodic diagnostic logging. Non-blocking trylock so main-thread logging
    /// never causes priority inversion or misses audio deadlines. Main thread.
    func underrunSnapshot() -> (reads: Int, worstShortfall: Int, available: Int) {
        if os_unfair_lock_trylock(&lock) {
            defer { os_unfair_lock_unlock(&lock) }
            return (underrunReads, worstUnderrunShortfall, writeIdx - readIdx)
        }
        return (underrunReads, worstUnderrunShortfall, max(0, writeIdx - readIdx))
    }

    /// Schedule a linear gain ramp toward `target` over the next `rampFrames`
    /// frames actually read out of the buffer. Use `target = 0` to fade out
    /// before a teardown, `target = 1` to fade back in after a restart. A
    /// ramp of 0 frames snaps the gain immediately. Safe to call from any
    /// thread.
    func setOutputGain(_ target: Float, rampFrames: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        targetGain = target
        if currentGain == target {
            rampStep = 0
            rampFramesRemaining = 0
            return
        }
        let frames = max(0, rampFrames)
        if frames == 0 {
            currentGain = target
            rampStep = 0
            rampFramesRemaining = 0
        } else {
            rampStep = (target - currentGain) / Float(frames)
            rampFramesRemaining = frames
        }
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        writeIdx = 0
        readIdx = 0
    }

    // Called with `lock` held. Advances the gain ramp across the `n` real
    // samples just copied into the destination buffers and scales them in
    // place. Padding zeros (n < frames case) are skipped — see the field
    // comment above for why.
    private func applyGainEnvelope(left ldst: UnsafeMutablePointer<Float>,
                                   right rdst: UnsafeMutablePointer<Float>,
                                   frames n: Int) {
        var g = currentGain
        let step = rampStep
        let target = targetGain
        var remaining = rampFramesRemaining
        if remaining == 0 && g == 1.0 { return } // unity passthrough fast path
        for i in 0..<n {
            ldst[i] *= g
            rdst[i] *= g
            if remaining > 0 {
                g += step
                remaining -= 1
                if remaining == 0 { g = target }
            }
        }
        currentGain = g
        rampFramesRemaining = remaining
    }

    var availableFrames: Int {
        if os_unfair_lock_trylock(&lock) {
            defer { os_unfair_lock_unlock(&lock) }
            return max(0, writeIdx - readIdx)
        }
        return max(0, writeIdx - readIdx)
    }
}
