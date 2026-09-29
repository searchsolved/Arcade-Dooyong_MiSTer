#!/usr/bin/env python3
"""Fit the YM2203 mix gains (dy_snd FM_GAIN, SSG_GAIN) against MAME's WAV.

Ours: tb_sys +opnwav= file, int32 pairs (FM sum of both chips, SSG sum of
both chips) at 48 kHz. MAME: -wavwrite output (16-bit, 48 kHz; the mono
speaker is written to both channels).

FM phases do not line up sample for sample between two emulators, so the
fit works on 20 ms window power (as the M3 level check does): the
recordings are aligned by envelope cross-correlation, then MAME power =
alpha * FM power + beta * SSG power is solved by least squares (FM and SSG
are uncorrelated), and the gains are sqrt(alpha), sqrt(beta), printed in
dy_snd's x/256 units. Use a window where the sound streams still match.

Usage: fit_opn.py <opn.raw> <mame.wav> [--from S] [--to S]
"""
import sys
import wave

import numpy as np


def main(argv):
    ours = np.fromfile(argv[0], dtype="<i4").reshape(-1, 2).astype(np.float64)
    with wave.open(argv[1]) as w:
        nch = w.getnchannels()
        m = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float64)
    m = m.reshape(-1, nch).mean(axis=1)
    t0 = float(argv[argv.index("--from") + 1]) if "--from" in argv else 1.0
    t1 = float(argv[argv.index("--to") + 1]) if "--to" in argv else 8.0
    W = 960                                           # 20 ms windows
    fm, ssg = ours[:, 0], ours[:, 1]

    def power(x):
        n = len(x) // W
        return x[:n * W].reshape(n, W).var(axis=1)    # per-window AC power
    pf, ps, pm = power(fm), power(ssg), power(m)
    a, b = int(t0 * 50), int(t1 * 50)
    # align the envelopes (+-2 s)
    ours_env = np.sqrt(pf + 64 * ps)
    best = None
    for lag in range(-100, 101):
        if a + lag < 0 or b + lag > len(pm):
            continue
        x, y = np.sqrt(ours_env[a:b]), np.sqrt(np.sqrt(pm[a + lag:b + lag]))
        c = np.corrcoef(x, y)[0, 1]
        if best is None or c > best[0]:
            best = (c, lag)
    lag = best[1]
    X = np.stack([pf[a:b], ps[a:b]], axis=1)
    y = pm[a + lag:b + lag]
    coef, *_ = np.linalg.lstsq(X, y, rcond=None)
    ga, gb = np.sqrt(max(coef[0], 0)), np.sqrt(max(coef[1], 0))
    pred = X @ coef
    lvl = 10 * np.log10(pred.sum() / y.sum())
    envc = np.corrcoef(np.sqrt(pred), np.sqrt(y))[0, 1]
    print(f"envelope lag {lag * 20} ms, envelope correlation {best[0]:.3f} (fit {envc:.3f})")
    print(f"power fit: MAME = {coef[0]:.5f} * P_FM + {coef[1]:.3f} * P_SSG")
    print(f"FM_GAIN {ga * 256:.1f}/256, SSG_GAIN {gb * 256:.1f}/256 over {t0}-{t1} s "
          f"(level of the fit vs MAME {lvl:+.2f} dB)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
