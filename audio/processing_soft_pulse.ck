// Rounded, upward pings with a long silent tail for safe looping.

2.4::second => dur LOOP_DUR;

Gain master => dac;
master => WvOut2 capture => blackhole;
(me.dir() + "processing_soft_pulse.wav", IO.INT24) => capture.wavFilename;
0.9 => capture.fileGain;
0.22 => master.gain;

fun void ping(float freq, float amp, float shimmer, dur hold, dur releaseTime)
{
    SinOsc body => Gain pre => ADSR env => LPF color => Gain voice => master;
    SinOsc low => pre;
    TriOsc air => pre;

    freq => body.freq;
    freq / 2.0 => low.freq;
    freq * 2.0 => air.freq;

    0.75 => body.gain;
    0.20 => low.gain;
    shimmer => air.gain;

    2400 => color.freq;
    1.4 => color.Q;

    amp => voice.gain;
    env.set(12::ms, 35::ms, 0.35, releaseTime);
    env.keyOn();
    hold => now;
    env.keyOff();
    releaseTime => now;
}

80::ms => now;
spork ~ ping(587.33, 0.70, 0.18, 120::ms, 160::ms);
320::ms => now;
spork ~ ping(698.46, 0.62, 0.16, 110::ms, 150::ms);
320::ms => now;
spork ~ ping(783.99, 0.68, 0.20, 130::ms, 170::ms);
1680::ms => now;

capture.closeFile();
