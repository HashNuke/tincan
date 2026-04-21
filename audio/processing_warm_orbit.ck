// A warmer, lower-register loop with slower swells.

2.8::second => dur LOOP_DUR;

Gain master => dac;
master => WvOut2 capture => blackhole;
(me.dir() + "processing_warm_orbit.wav", IO.INT24) => capture.wavFilename;
0.9 => capture.fileGain;
0.20 => master.gain;

fun void swell(float freq, float amp, dur hold, dur releaseTime)
{
    SawOsc body => Gain pre => ADSR env => LPF color => Gain voice => master;
    SinOsc low => pre;
    SinOsc shine => pre;

    freq => body.freq;
    freq / 2.0 => low.freq;
    freq * 2.0 => shine.freq;

    0.32 => body.gain;
    0.40 => low.gain;
    0.08 => shine.gain;

    1500 => color.freq;
    1.1 => color.Q;

    amp => voice.gain;
    env.set(20::ms, 60::ms, 0.40, releaseTime);
    env.keyOn();
    hold => now;
    env.keyOff();
    releaseTime => now;
}

100::ms => now;
spork ~ swell(392.00, 0.62, 180::ms, 220::ms);
420::ms => now;
spork ~ swell(440.00, 0.55, 170::ms, 220::ms);
420::ms => now;
spork ~ swell(523.25, 0.58, 180::ms, 220::ms);
1860::ms => now;

capture.closeFile();
