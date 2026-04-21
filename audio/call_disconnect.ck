// A soft descending disconnect cue.

1.8::second => dur LOOP_DUR;

Gain master => LPF soften => Gain dry => dac;
soften => JCRev rev => LPF revTone => Gain wet => dac;
dac => WvOut2 capture => blackhole;
(me.dir() + "output/call_disconnect.wav", IO.INT24) => capture.wavFilename;
0.98 => capture.fileGain;
1.50 => master.gain;
2100.0 => soften.freq;
0.88 => dry.gain;
0.12 => wet.gain;
0.08 => rev.mix;
1500.0 => revTone.freq;

fun void toneDrop(float startFreq, float endFreq, float amp, float pan, dur total)
{
    TriOsc lead => Gain blend => ADSR env => LPF tone => Gain voice => Pan2 p => master;
    SinOsc body => blend;

    pan => p.pan;
    0.22 => lead.gain;
    0.15 => body.gain;
    1800.0 => tone.freq;
    amp => voice.gain;

    env.set(8::ms, 40::ms, 0.45, 190::ms);
    env.keyOn();

    24 => int steps;
    total / steps => dur stepDur;

    for (0 => int i; i < steps; i++)
    {
        i $ float / (steps - 1) => float t;
        startFreq + ((endFreq - startFreq) * t) => float f;
        f => lead.freq;
        f * 0.5 => body.freq;
        stepDur => now;
    }

    env.keyOff();
    220::ms => now;
}

100::ms => now;
spork ~ toneDrop(620.0, 420.0, 0.95, -0.04, 210::ms);
180::ms => now;
spork ~ toneDrop(520.0, 320.0, 0.82, 0.06, 240::ms);
1060::ms => now;

capture.closeFile();
