import Foundation

/// Turns an arbitrary byte stream into whole 188-byte transport packets.
///
/// A socket can die in the middle of a packet and a reconnect starts wherever the provider's
/// buffer happens to be, so framing is only trusted after three sync bytes line up 188 bytes
/// apart. Bytes that can't be framed are counted and dropped rather than fed to the demuxer.
nonisolated struct TSPacketAligner {
    private var buffer: [UInt8] = []
    private var readIndex = 0
    private var isSynced = false

    /// Bytes discarded while searching for sync, including torn packets dropped by `reset`.
    private(set) var discardedBytes = 0
    /// Times framing was lost after having been established.
    private(set) var syncLosses = 0

    /// Forgets any partial packet. Call when the connection changes: the tail of the old
    /// connection must never be glued onto the head of the new one.
    mutating func reset() {
        discardedBytes += buffer.count - readIndex
        buffer.removeAll(keepingCapacity: true)
        readIndex = 0
        isSynced = false
    }

    /// Appends bytes and returns every complete packet now available.
    mutating func push<D: DataProtocol>(_ data: D) -> [TSPacket] {
        buffer.append(contentsOf: data)
        var packets: [TSPacket] = []
        packets.reserveCapacity((buffer.count - readIndex) / MPEGTS.packetSize)
        let size = MPEGTS.packetSize

        while true {
            if !isSynced {
                guard let start = findSync() else { break }
                discardedBytes += start - readIndex
                readIndex = start
                isSynced = true
            }
            guard buffer.count - readIndex >= size else { break }
            guard buffer[readIndex] == MPEGTS.syncByte else {
                isSynced = false
                syncLosses += 1
                readIndex += 1
                discardedBytes += 1
                continue
            }
            packets.append(TSPacket(bytes: Array(buffer[readIndex..<(readIndex + size)])))
            readIndex += size
        }
        compact()
        return packets
    }

    /// First offset where three sync bytes line up; keeps scanning state bounded when none is found.
    private mutating func findSync() -> Int? {
        let size = MPEGTS.packetSize
        let lastCandidate = buffer.count - (2 * size + 1)
        if lastCandidate >= readIndex {
            let found: Int? = buffer.withUnsafeBufferPointer { bytes in
                var index = readIndex
                while index <= lastCandidate {
                    if bytes[index] == MPEGTS.syncByte,
                       bytes[index + size] == MPEGTS.syncByte,
                       bytes[index + 2 * size] == MPEGTS.syncByte {
                        return index
                    }
                    index += 1
                }
                return nil
            }
            if let found { return found }
            // Nothing lines up yet; everything before the last two packets' worth can't start a run.
            discardedBytes += lastCandidate + 1 - readIndex
            readIndex = lastCandidate + 1
        }
        return nil
    }

    private mutating func compact() {
        guard readIndex > 0 else { return }
        if readIndex >= buffer.count {
            buffer.removeAll(keepingCapacity: true)
        } else if readIndex > 64 * 1024 || readIndex * 2 > buffer.count {
            buffer.removeSubrange(0..<readIndex)
        } else {
            return
        }
        readIndex = 0
    }

    /// Bytes waiting for the rest of their packet.
    var pendingByteCount: Int { buffer.count - readIndex }
}
