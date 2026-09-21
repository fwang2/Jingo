# Speaker profile benchmark

The benchmark replays labeled speaker embeddings in chronological order and compares:

- **Legacy average:** every confirmed sample is merged into one rolling-average embedding.
- **Representative bank:** diverse samples are retained, duplicates are ignored, and distant meeting samples require corroboration.

The prediction for an observation is recorded before that observation is allowed to update either profile. This prevents evaluation data from leaking into the profile being tested.

## Run it

Generate the workspace, build the tool, and run the included synthetic example:

```sh
mise exec -- tuist generate --no-open
xcodebuild -quiet \
  -workspace Jingo.xcworkspace \
  -scheme SpeakerProfileBenchmark \
  -configuration Debug \
  -derivedDataPath .build/SpeakerProfileBenchmark \
  build
.build/SpeakerProfileBenchmark/Build/Products/Debug/SpeakerProfileBenchmark \
  TestResources/SpeakerProfileBenchmark/example.json
```

To save the complete report as JSON:

```sh
.build/SpeakerProfileBenchmark/Build/Products/Debug/SpeakerProfileBenchmark \
  path/to/labeled-embeddings.json \
  --thresholds 0.70,0.75,0.80,0.82,0.85,0.90 \
  --margin 0.05 \
  --json-output benchmark-report.json
```

The Markdown summary is written to standard output. The optional JSON report is suitable for plotting or comparing in CI.

### Import confirmed speakers from Jingo

The tool can read an explicitly supplied Jingo recording index. It uses only manually assigned speaker names and their embeddings. It replaces names, recording IDs, and meeting IDs with sequential pseudonyms; transcripts and audio paths are never included.

```sh
.build/SpeakerProfileBenchmark/Build/Products/Debug/SpeakerProfileBenchmark \
  --recordings-index "$HOME/Library/Application Support/Jingo/Recordings/recordings.json" \
  --export-dataset /private/tmp/jingo-speaker-benchmark.json
```

The original recording index is read-only. `--export-dataset` is optional and writes the sanitized input used by the replay. Recordings without a manually confirmed speaker name and matching embedding are ignored.

Although names and transcripts are removed, voice embeddings are biometric-derived data. Keep exported datasets private, restrict access, and delete them according to the same retention policy as recordings.

## Dataset format

Only embeddings and pseudonymous labels are required. Do not put names, transcript text, or raw audio in the dataset.

```json
{
  "schemaVersion": 1,
  "observations": [
    {
      "id": "speaker-17-enrollment",
      "sequence": 1,
      "speakerID": "speaker-17",
      "meetingID": "enrollment-17",
      "mode": "enrollment",
      "embedding": [0.12, -0.03, 0.44],
      "conditions": {
        "device": "laptop",
        "setting": "quiet"
      }
    },
    {
      "id": "meeting-42-speaker-17",
      "sequence": 2,
      "speakerID": "speaker-17",
      "meetingID": "meeting-42",
      "mode": "confirmedMeeting",
      "embedding": [0.09, -0.01, 0.48],
      "candidateEmbeddings": [
        [0.09, -0.01, 0.48],
        [0.11, -0.02, 0.45]
      ],
      "conditions": {
        "device": "phone",
        "setting": "noisy"
      }
    }
  ]
}
```

Every embedding in one dataset must have the same dimension.

### Observation modes

- `enrollment`: update profiles without scoring a prediction. Use for a dedicated voice sample collected before meetings.
- `confirmedMeeting`: score first, then update both profiles using the ground-truth correction.
- `evaluationOnly`: score without updating. Use for held-out meetings or speakers who should remain unknown.

`embedding` is the representative stored if the observation is learned. `candidateEmbeddings` is optional and represents the candidates available while identifying the speaker. When omitted, `embedding` is also used for matching.

## Collecting a useful corpus

Use at least five separate sessions per speaker and include different devices, rooms, distances, and noise levels. Preserve chronological order with `sequence`. Never split chunks from one meeting across enrollment and evaluation: the entire meeting must stay on one side of the timeline.

Include people who never enroll and mark their observations `evaluationOnly`. They measure false acceptance—incorrectly assigning a known name to an unknown speaker.

The included example is synthetic and only verifies the benchmark machinery. It is not evidence of real-world improvement.

## Reading the report

The primary comparison is **known ID** at the same false-accept and wrong-name rates. Prefer the representative bank only when it improves correct identification without increasing incorrect names.

- **Known ID:** known-speaker observations assigned the correct identity.
- **Wrong name:** all evaluated observations given an incorrect identity.
- **False rejection:** known speakers left unidentified.
- **False acceptance:** unknown speakers assigned any known identity.

Condition slices reveal whether an overall gain hides regressions for a particular device or environment. Small slices should be treated as directional until the corpus grows.
