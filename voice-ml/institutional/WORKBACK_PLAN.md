# Voiceprint Accuracy Workback Plan

This is the execution order to drive the system to production-grade accuracy using real pipeline audio.

## Success Criteria (must all pass)

- Deepfake false-accept rate (clone accepted as human): `<= 1.0%`
- Identity false-accept rate (wrong speaker accepted): `<= 1.0%`
- Identity true-positive rate on clean speech: `>= 95%`
- Median decision latency (human + identity result): `< 3 seconds`
- P95 decision latency: `< 6 seconds`

## Phase 0: Freeze a Baseline

1. Keep current tuning/config as baseline.
2. Run labeled evaluation on current config.
3. Save report as `baseline_eval.json`.

Command:

```bash
python3 voice-ml/institutional/evaluate_config.py \
  --manifest ./datasets/manifest_labeled.csv \
  --config ./datasets/current_prod_config.json \
  --output ./datasets/baseline_eval.json
```

Pass gate:

- Baseline metrics captured and archived.

## Phase 1: Capture Real Pipeline Failures

1. Run calls across different carriers/Wi-Fi combinations.
2. Capture sessions from both phones.
3. Pull `Documents/VerificationDataset` from each device.
4. Merge all sessions into one dataset root.

Pass gate:

- Data includes successful calls and failure cases (false accepts + false rejects).

## Phase 2: Label and Build Training Assets

1. Build manifest from captured data.
2. Label `label_human` and `label_identity_match`.
3. Build retraining manifests (train/val/test split by call/session grouping).

Commands:

```bash
python3 voice-ml/institutional/build_manifest.py \
  --dataset-root ./datasets \
  --output ./datasets/manifest_unlabeled.csv

python3 voice-ml/institutional/prepare_retraining_dataset.py \
  --manifest ./datasets/manifest_labeled.csv \
  --output-dir ./datasets/retrain \
  --require-audio-files
```

Pass gate:

- At least:
  - `>= 300` genuine human chunks
  - `>= 150` clone/replay chunks
  - `>= 150` impostor-human identity chunks

## Phase 3: Threshold Calibration First (fastest gain)

1. Calibrate thresholds from labeled data.
2. Evaluate calibrated config against baseline.
3. If improved and stable, deploy as canary config.

Commands:

```bash
python3 voice-ml/institutional/calibrate_thresholds.py \
  --manifest ./datasets/manifest_labeled.csv \
  --output ./datasets/tuning_recommendation.json

python3 voice-ml/institutional/evaluate_config.py \
  --manifest ./datasets/manifest_labeled.csv \
  --config ./datasets/tuning_recommendation.json \
  --output ./datasets/eval_recommendation.json
```

Pass gate:

- FAR/F RR improve vs baseline and no latency regression in live canary tests.

## Phase 4: Model Retraining Trigger

Only enter this phase if Phase 3 cannot hit success criteria.

1. Use `./datasets/retrain/deepfake_retrain_manifest.csv` to retrain anti-spoof model on pipeline audio.
2. Use `./datasets/retrain/identity_retrain_manifest.csv` to refine identity acceptance behavior.
3. Re-export model/config and re-run evaluation.

Pass gate:

- Retrained model beats calibrated-threshold-only config on holdout set.

## Phase 5: Deploy, Canary, Rollback Safety

1. Export Fly secrets command from winning config.
2. Deploy to canary users first.
3. Monitor FAR/F RR and latency in live traffic.
4. Roll back immediately if either FAR or latency degrades.

Command:

```bash
python3 voice-ml/institutional/export_fly_secret.py \
  --config ./datasets/tuning_recommendation.json \
  --app <your-fly-app-name>
```

Pass gate:

- Canary stable for at least 24 hours across mixed networks before broad rollout.

## Definition of Done

- All success criteria pass on holdout + canary.
- Tunings/versioned config are deployed via backend endpoint.
- Dataset/reports archived for reproducibility.
