#!/usr/bin/env python3
"""VolaTTM inference sidecar for the OCaml portfolio engine.

Input  (--in):  {"model", "revision", "channels", "assets": [{"symbol", "features": 512 x 12}]}
Output (--out): {"model", "revision", "forecasts": [{"symbol", "log_variance_path": [22 floats]}]}

Features are built in OCaml (src/features.ml) with the transformations of
volatility_fm.volare_data.make_volare_features. The output is log 5-minute
realized variance for the next 22 sessions; OCaml converts it to volatility.
"""

import argparse
import json
import sys

EXPECTED_CHANNELS = [
    "log_rv5", "log_rv5_ss", "log_rk", "log_bv5", "jump_share", "downside_share",
    "log_rq5", "intraday_return", "overnight_return", "log_range", "log_volume", "log_trades",
]
CONTEXT, HORIZON, FREQ_TOKEN = 512, 22, 8


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inp", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    def fail(msg: str) -> int:
        with open(args.out, "w") as f:
            json.dump({"error": msg}, f)
        print(f"[sidecar] {msg}", file=sys.stderr)
        return 0  # the error is reported through the JSON; OCaml falls back

    with open(args.inp) as f:
        req = json.load(f)
    if req.get("channels", EXPECTED_CHANNELS) != EXPECTED_CHANNELS:
        return fail("channel order does not match VolaTTM feature_spec.json")

    try:
        import numpy as np
        import torch
        from tsfm_public.models.tinytimemixer import TinyTimeMixerForPrediction
    except ImportError as e:
        return fail(f"missing dependency: {e}. pip install 'granite-tsfm==0.3.6' 'torch>=2.10,<2.11'")

    assets = req.get("assets", [])
    if not assets:
        with open(args.out, "w") as f:
            json.dump({"forecasts": []}, f)
        return 0

    x = np.asarray([a["features"] for a in assets], dtype=np.float32)
    if x.shape[1:] != (CONTEXT, len(EXPECTED_CHANNELS)):
        return fail(f"expected (batch, {CONTEXT}, 12) features, got {x.shape}")
    if not np.isfinite(x).all():
        return fail("non-finite feature values")

    model_id = req.get("model", "AurelPx/VolaTTM")
    revision = req.get("revision") or None
    print(f"[sidecar] loading {model_id}@{(revision or 'main')[:8]} for {len(assets)} assets", file=sys.stderr)
    model = TinyTimeMixerForPrediction.from_pretrained(model_id, revision=revision)
    model.eval()

    with torch.inference_mode():
        past = torch.from_numpy(x)
        freq = torch.full((past.shape[0],), FREQ_TOKEN, dtype=torch.long)
        out = model(past_values=past, freq_token=freq, return_loss=False).prediction_outputs[..., 0]
    paths = out[:, :HORIZON].cpu().numpy().astype(float)

    with open(args.out, "w") as f:
        json.dump(
            {
                "model": model_id,
                "revision": revision,
                "forecasts": [
                    {"symbol": a["symbol"], "log_variance_path": p.tolist()} for a, p in zip(assets, paths)
                ],
            },
            f,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
