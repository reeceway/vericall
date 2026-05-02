# Institutional Accuracy Workflow

This workflow is designed to improve verification quality using **audio captured from the real VeriCall production path**, then calibrate and deploy thresholds without rebuilding the iOS app.

## 1) Capture production-path chunks on iPhone

The app now saves verification chunks and metrics to:

- `Documents/VerificationDataset/session_<timestamp>_<callid>/`

Each chunk has:

- `chunk_XXXX.wav` (16kHz mono Float32 PCM)
- `chunk_XXXX.json` (speech metrics, model scores, debug feature map)

Capture is controlled by:

- `Constants.enableVerificationDatasetCapture`

## 2) Pull datasets from devices via CLI

Use `devicectl` (replace UDID and output folder):

```bash
xcrun devicectl device copy from \
  --device 00008120-0006681A3401A01E \
  --domain-type appDataContainer \
  --domain-identifier com.vericall.app \
  --source Documents/VerificationDataset \
  --destination ./datasets/phone1
```

Do this for each phone, then merge under one root folder if desired.

## 3) Build a labeling manifest

```bash
python3 voice-ml/institutional/build_manifest.py \
  --dataset-root ./datasets \
  --output ./datasets/manifest_unlabeled.csv
```

Fill in:

- `label_human` (`1` real human, `0` clone/spoof/replay)
- `label_identity_match` (`1` correct enrolled speaker, `0` wrong speaker)
- `label_notes` (optional)

Save as `manifest_labeled.csv`.

## 4) Calibrate thresholds from real data

```bash
python3 voice-ml/institutional/calibrate_thresholds.py \
  --manifest ./datasets/manifest_labeled.csv \
  --output ./datasets/tuning_recommendation.json
```

This optimizes:

- L2 primary/secondary anti-spoof thresholds
- L3 identity similarity threshold
- identity speech gating thresholds
- minimum human-confidence threshold for identity acceptance

## 5) Evaluate recommended config

```bash
python3 voice-ml/institutional/evaluate_config.py \
  --manifest ./datasets/manifest_labeled.csv \
  --config ./datasets/tuning_recommendation.json \
  --output ./datasets/eval_recommendation.json
```

This gives call-path and service-path FAR/FRR/TPR and top failing call IDs.

## 6) Prepare retraining manifests (pipeline-conditioned)

If threshold tuning is not enough, prepare deterministic train/val/test manifests from the same captured pipeline audio:

```bash
python3 voice-ml/institutional/prepare_retraining_dataset.py \
  --manifest ./datasets/manifest_labeled.csv \
  --output-dir ./datasets/retrain \
  --require-audio-files
```

Outputs:

- `deepfake_retrain_manifest.csv`
- `identity_retrain_manifest.csv`
- `retrain_summary.json`

Use these manifests to fine-tune your deepfake and speaker models with no train/test leakage by call/session grouping.

## 7) Deploy tuning to production backend

```bash
python3 voice-ml/institutional/export_fly_secret.py \
  --config ./datasets/tuning_recommendation.json \
  --app <your-fly-app-name>
```

Then run the emitted `fly secrets set ...` command.

The app fetches tuning from:

- `GET /ml/verification-config`

controlled by:

- `Constants.enableRuntimeVerificationTuningFetch`

## Workback Loop (repeat until stable)

1. Capture new failures from production-like calls (different carriers/networks).
2. Label and re-run calibration + evaluation.
3. If FAR/FRR still outside target, rebuild retraining manifests and fine-tune model(s).
4. Re-deploy config/model to staging, then canary in production.
5. Roll back immediately if FAR or latency regresses.

## Recommended data targets before lock-in

- >= 300 genuine chunks across networks/devices/environments
- >= 150 impostor-human chunks
- >= 150 clone/replay chunks
- Separate holdout set from different days/devices

Do not finalize thresholds from same-day-only captures.

Detailed execution order with pass/fail gates:

- `voice-ml/institutional/WORKBACK_PLAN.md`

Massive dataset sourcing references:

- `voice-ml/institutional/DATASET_SHOPPING.md`

Bulk synthetic-clone generation:

```bash
python3 voice-ml/institutional/generate_tts_fake_dataset.py \
  --output-dir ./datasets/raw/tts-fake \
  --count 2500 \
  --english-only
```

Build a pipeline-shaped supervised corpus from mixed real/fake sources:

```bash
python3 voice-ml/institutional/build_supervised_audio_corpus.py \
  --real-dir ./datasets/raw/fsdd/recordings \
  --real-dir ./datasets/raw/LibriSpeech/test-clean \
  --real-dir ./datasets/raw/LibriSpeech/train-clean-100 \
  --real-dir ./datasets/raw/hf-deepfake-audio/real \
  --fake-dir ./datasets/raw/tts-fake/audio \
  --fake-dir ./datasets/raw/hf-deepfake-audio/fake \
  --fake-dir ./model-eval/test_audio/fake \
  --output-dir ./datasets/pipeline_supervised_corpus
```

Build a massive virtual manifest (hundreds of thousands of pipeline-shaped samples):

```bash
python3 voice-ml/institutional/build_virtual_pipeline_manifest.py \
  --real-dir ./datasets/raw/fsdd/recordings \
  --real-dir ./datasets/raw/LibriSpeech/test-clean \
  --real-dir ./datasets/raw/LibriSpeech/train-clean-100 \
  --real-dir ./datasets/raw/hf-deepfake-audio/real \
  --fake-dir ./datasets/raw/tts-fake/audio \
  --fake-dir ./datasets/raw/hf-deepfake-audio/fake \
  --fake-dir ./model-eval/test_audio/fake \
  --target-sources-per-class 4500 \
  --virtual-samples-per-source 80 \
  --output ./datasets/pipeline_virtual_manifest.csv
```
