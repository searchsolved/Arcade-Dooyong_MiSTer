#!/usr/bin/env python3
"""M3: level calibration of the core's mono mix against MAME's WAV.

Ours: tb_sys.cpp +wav= (16-bit mono, 48 kHz, raw). MAME: -wavwrite of the
same run from power-on, -samplerate 48000.
The two are aligned by cross-correlation of their envelopes (the sound CPU
runs a constant ~0.5 ms behind MAME's, m3_findings), then compared:
  - overall RMS ratio in dB (the gate: within 1 dB),
  - RMS ratio per 5 s segment with sound in it,
  - correlation of the 20 ms RMS envelopes (does the same thing happen at
    the same time; YM synthesis is not sample-identical between jt51 and
    MAME's ymfm, so waveforms are not compared sample by sample).

Usage: compare_audio.py <ours.raw> <mame.wav> [--skip SECONDS]
"""
import sys
import wave

import numpy as np


def load_raw(p):
    return np.fromfile(p, dtype="<i2").astype(np.float64)


def load_wav(p):
    w = wave.open(p)
    assert w.getnchannels() == 1 and w.getsampwidth() == 2 and w.getframerate() == 48000
    return np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float64)


def env(x, win=960):
    n = len(x) // win
    return np.sqrt((x[:n * win].reshape(n, win) ** 2).mean(axis=1))


def main(argv):
    ours, mame = load_raw(argv[0]), load_wav(argv[1])
    skip = float(argv[argv.index("--skip") + 1]) if "--skip" in argv else 0.0
    # alignment on 1 ms envelopes, +-100 ms search
    eo, em = env(ours, 48), env(mame, 48)
    n = min(len(eo), len(em))
    best = max(range(-100, 101), key=lambda k: np.dot(eo[max(0, k):n + min(0, k)], em[max(0, -k):n - max(0, k)]))
    lag = best * 48                                     # samples, + = ours later
    if lag >= 0:
        o, m = ours[lag:], mame
    else:
        o, m = ours, mame[-lag:]
    n = min(len(o), len(m))
    s0 = int(skip * 48000)
    o, m = o[s0:n], m[s0:n]
    ro, rm = np.sqrt((o ** 2).mean()), np.sqrt((m ** 2).mean())
    db = 20 * np.log10(ro / rm)
    print(f"alignment: ours {lag / 48:.2f} ms {'behind' if lag >= 0 else 'ahead of'} MAME")
    print(f"overall RMS: ours {ro:.1f}, MAME {rm:.1f} -> {db:+.2f} dB over {len(o) / 48000:.1f} s")
    seg = 5 * 48000
    for i in range(0, len(o) - seg + 1, seg):
        a, b = o[i:i + seg], m[i:i + seg]
        rb = np.sqrt((b ** 2).mean())
        if rb < 30:
            continue
        print(f"  {i / 48000 + skip:6.1f}-{(i + seg) / 48000 + skip:6.1f} s: "
              f"{20 * np.log10(np.sqrt((a ** 2).mean()) / rb):+.2f} dB")
    ea, eb = env(o), env(m)
    k = min(len(ea), len(eb))
    c = np.corrcoef(ea[:k], eb[:k])[0, 1]
    print(f"20 ms envelope correlation: {c:.3f}")
    ok = abs(db) <= 1.0
    print("LEVEL " + ("OK (within 1 dB)" if ok else "OUT OF TOLERANCE"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
