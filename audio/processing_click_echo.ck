// A dry click followed by decaying repeats.

2.6::second => dur LOOP_DUR;

Gain master => dac;
master => WvOut2 capture => blackhole;
(me.dir() + "processing_click_echo.wav", IO.INT24) => capture.wavFilename;
1.0 => capture.fileGain;
1.90 => master.gain;

fun void click(float amp, float edgeCutoff, float airCutoff, dur hold, dur releaseTime)
{
    Impulse hit => Gain hitTrim => HPF edgeHPF => LPF edgeLPF => Gain hitVoice => master;
    Noise grit => HPF gritHPF => LPF gritLPF => ADSR gritEnv => Gain gritVoice => master;

    1.10 => hitTrim.gain;
    1800.0 => edgeHPF.freq;
    edgeCutoff => edgeLPF.freq;
    amp * 1.35 => hitVoice.gain;

    2400.0 => gritHPF.freq;
    airCutoff => gritLPF.freq;
    0.22 => grit.gain;
    amp * 0.95 => gritVoice.gain;

    gritEnv.set(0::ms, 2::ms, 0.0, releaseTime);

    1.0 => hit.next;
    gritEnv.keyOn();
    hold => now;
    gritEnv.keyOff();
    releaseTime => now;
}

fun void echoTrain()
{
    0.95 => float amp;
    5200.0 => float edgeCutoff;
    9000.0 => float airCutoff;
    210::ms => dur gap;

    spork ~ click(amp, edgeCutoff, airCutoff, 2::ms, 28::ms);

    repeat(7)
    {
        gap => now;
        amp * 0.68 => amp;
        edgeCutoff * 0.97 => edgeCutoff;
        airCutoff * 0.96 => airCutoff;
        spork ~ click(amp, edgeCutoff, airCutoff, 2::ms, 30::ms);
    }
}

80::ms => now;
spork ~ echoTrain();
840::ms => now;
spork ~ echoTrain();
1680::ms => now;

capture.closeFile();
