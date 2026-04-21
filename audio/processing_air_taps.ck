// Breathier taps with a lighter top end.

2.0::second => dur LOOP_DUR;

Gain master => dac;
master => WvOut2 capture => blackhole;
(me.dir() + "processing_air_taps.wav", IO.INT24) => capture.wavFilename;
0.9 => capture.fileGain;
0.18 => master.gain;

fun void tap(float freq, float amp, dur hold, dur releaseTime)
{
    Noise breath => HPF air => Gain pre => ADSR env => BPF color => Gain voice => master;
    SinOsc tone => pre;

    2600 => air.freq;
    freq => tone.freq;

    0.08 => breath.gain;
    0.65 => tone.gain;

    freq * 1.6 => color.freq;
    4.0 => color.Q;

    amp => voice.gain;
    env.set(5::ms, 18::ms, 0.20, releaseTime);
    env.keyOn();
    hold => now;
    env.keyOff();
    releaseTime => now;
}

70::ms => now;
spork ~ tap(880.00, 0.55, 70::ms, 120::ms);
260::ms => now;
spork ~ tap(1046.50, 0.48, 70::ms, 120::ms);
260::ms => now;
spork ~ tap(987.77, 0.44, 65::ms, 120::ms);
280::ms => now;
spork ~ tap(1318.51, 0.50, 70::ms, 130::ms);
1130::ms => now;

capture.closeFile();
