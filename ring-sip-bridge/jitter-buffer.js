/**
 * Simple RTP jitter buffer for reordering packets before forwarding to ffmpeg.
 *
 * ring-client-api's RtpSplitter forwards packets immediately via UDP, which
 * causes ffmpeg's SDP demuxer to see sequence-number gaps and drop frames.
 * This buffer holds packets for a configurable window (default 80ms), sorts
 * by RTP sequence number, and flushes in order.
 *
 * Usage:
 *   const jb = new JitterBuffer({ flushIntervalMs: 80, send: (buf) => splitter.send(buf, {port}) });
 *   observable.subscribe(rtp => jb.push(rtp));
 *   // later:
 *   jb.stop();
 */

import { RtpPacket } from 'werift';

export class JitterBuffer {
    constructor({ flushIntervalMs = 80, send }) {
        this._send = send;
        this._buffer = [];
        this._lastSeq = -1;
        this._timer = setInterval(() => this._flush(), flushIntervalMs);
    }

    push(rtpPacket) {
        this._buffer.push(rtpPacket);
    }

    _flush() {
        if (this._buffer.length === 0) return;

        // Sort by sequence number (handle 16-bit wraparound)
        this._buffer.sort((a, b) => {
            const diff = a.header.sequenceNumber - b.header.sequenceNumber;
            // Handle wraparound: if diff is very large negative, a wrapped
            if (diff < -30000) return 1;
            if (diff > 30000) return -1;
            return diff;
        });

        // Send all buffered packets in order
        for (const pkt of this._buffer) {
            try {
                this._send(pkt.serialize());
            } catch {
                // UDP send failure — drop silently, ffmpeg handles gaps
            }
        }
        this._buffer = [];
    }

    stop() {
        if (this._timer) {
            clearInterval(this._timer);
            this._timer = null;
        }
        // Flush remaining
        this._flush();
    }
}
