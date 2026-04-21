// A dry click followed by decaying repeats.

2.6::second => dur LOOP_DUR;

Gain master => dac;
master => WvOut2 capture => blackhole;
(me.dir() + "processing_click_echo.wav", IO.INT24) => capture.wavFilename;
0.9 => capture.fileGain;
0.20 => master.gain;

fun void click(float amp, float freq, float airCutoff, dur hold, dur releaseTime)
{
    Noise snap => HPF air => Gain pre => ADSR env => LPF color => Gain voice => master;
    SinOsc tone => pre;

    airCutoff => air.freq;
    freq => tone.freq;

    0.28 => snap.gain;
    0.55 => tone.gain;

    freq * 2.2 => color.freq;
    1.2 => color.Q;

    amp => voice.gain;
    env.set(0::ms, 8::ms, 0.0, releaseTime);
    env.keyOn();
    hold => now;
    env.keyOff();
    releaseTime => now;
}

fun void echoTrain()
{
    0.85 => float amp;
    1900.0 => float airCutoff;
    210::ms => dur gap;

    spork ~ click(amp, 1800.0, airCutoff, 5::ms, 70::ms);

    repeat(7)
    {
        gap => now;
        amp * 0.68 => amp;
        airCutoff * 0.90 => airCutoff;
        spork ~ click(amp, 1600.0, airCutoff, 5::ms, 80::ms);
    }
}

80::ms => now;
spork ~ echoTrain();
840::ms => now;
spork ~ echoTrain();
1680::ms => now;

capture.closeFile();
