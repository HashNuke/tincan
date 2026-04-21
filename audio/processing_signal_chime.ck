// Slightly more digital but still restrained.

2.2::second => dur LOOP_DUR;

Gain master => dac;
master => WvOut2 capture => blackhole;
(me.dir() + "output/processing_signal_chime.wav", IO.INT24) => capture.wavFilename;
1.0 => capture.fileGain;
1.90 => master.gain;

fun void blip(float freq, float amp, dur hold, dur releaseTime)
{
    SinOsc body => Gain pre => ADSR env => BPF color => Gain voice => master;
    SinOsc detune => pre;

    freq => body.freq;
    freq * 1.01 => detune.freq;

    0.70 => body.gain;
    0.35 => detune.gain;

    freq * 1.8 => color.freq;
    3.2 => color.Q;

    amp * 1.65 => voice.gain;
    env.set(4::ms, 12::ms, 0.18, releaseTime);
    env.keyOn();
    hold => now;
    env.keyOff();
    releaseTime => now;
}

60::ms => now;
spork ~ blip(739.99, 0.62, 60::ms, 100::ms);
240::ms => now;
spork ~ blip(622.25, 0.56, 55::ms, 100::ms);
240::ms => now;
spork ~ blip(830.61, 0.60, 60::ms, 100::ms);
240::ms => now;
spork ~ blip(932.33, 0.54, 60::ms, 100::ms);
1420::ms => now;

capture.closeFile();
