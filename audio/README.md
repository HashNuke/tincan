# Processing Sounds

This directory holds procedural loading and "thinking" sounds for call processing states.

The `.ck` files are the source sketches.
Generated `.wav` renders are ignored by git.

## Usage

Audition a single sketch live:

```bash
chuck audio/processing_soft_pulse.ck
```

Render every sketch to WAV:

```bash
./audio/render_all.sh
```

The current sketches are intentionally loop-safe by leaving enough decay and silence before the file boundary, so repeating the exported file does not chop off a tail mid-phrase.
