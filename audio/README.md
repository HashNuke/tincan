# Audio Assets

This directory contains two kinds of audio assets:

1. Downloaded/source audio files that we keep directly in `audio/`
2. Procedural sound programs written in ChucK (`.ck`) that generate rendered audio into `audio/output/`

The goal is to keep hand-picked/downloaded assets separate from generated renders while still keeping all audio work in one place.

## Layout

- `*.ck`: ChucK source programs for generated sounds
- `output/`: rendered `.wav` files generated from the ChucK programs
- standalone `.wav` files in `audio/`: downloaded/source assets that we keep intentionally

## Usage

Audition a generated sound live:

```bash
chuck audio/processing_soft_pulse.ck
```

Render every ChucK program to `audio/output/`:

```bash
./audio/render_all.sh
```

The generated sketches are generally designed to loop cleanly by leaving enough decay and silence near the file boundary so repeated playback does not cut off a tail abruptly.

## Downloaded Assets

- `phone-ring-out-call-end-tone.wav`

## Generated Programs

- `call_disconnect.ck`
- `call_ringing.ck`
- `processing_air_taps.ck`
- `processing_click_echo.ck`
- `processing_signal_chime.ck`
- `processing_soft_pulse.ck`
- `processing_soft_rhyme.ck`
- `processing_warm_orbit.ck`

## Attributions

- `phone-ring-out-call-end-tone.wav` by [kalhan on Freesound](https://freesound.org/s/677458/) — License: Creative Commons 0

## More sounds I like

* [Mandolin Plucks - 130bpm - C#min by by nnaudio](https://freesound.org/people/nnaudio/sounds/518197/) - License: Attribution 4.0
* [koto and shamisen loop](https://freesound.org/people/zagi2/sounds/222655/)
* [Best RnB Analog Keys - 125bpm - F#min](https://freesound.org/people/nnaudio/sounds/570286/)
