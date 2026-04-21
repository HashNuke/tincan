// A soft but urgent smartphone-style ringtone with a tighter cadence.

3.0::second => dur LOOP_DUR;

Gain master => LPF soften => Gain dry => dac;
soften => JCRev rev => LPF revTone => Gain wet => dac;
dac => WvOut2 capture => blackhole;
(me.dir() + "call_ringing.wav", IO.INT24) => capture.wavFilename;
0.98 => capture.fileGain;
1.34 => master.gain;
2500.0 => soften.freq;
0.88 => dry.gain;
0.12 => wet.gain;
0.08 => rev.mix;
1800.0 => revTone.freq;

fun void strike(float freq, float amp, float pan, dur hold, dur releaseTime)
{
    TriOsc lead => Gain blend => ADSR env => LPF tone => Gain voice => Pan2 p => master;
    SinOsc body => blend;
    SinOsc air => blend;

    pan => p.pan;
    freq => lead.freq;
    freq * 0.5 => body.freq;
    freq * 2.0 => air.freq;

    0.24 => lead.gain;
    0.18 => body.gain;
    0.025 => air.gain;

    2200.0 => tone.freq;
    amp => voice.gain;

    env.set(8::ms, 54::ms, 0.58, releaseTime);
    env.keyOn();
    hold => now;
    env.keyOff();
    releaseTime => now;
}

fun void ringPhrase(float panBias)
{
    spork ~ strike(1318.51, 0.92, -0.08 * panBias, 150::ms, 250::ms);
    spork ~ strike(1046.50, 0.68, 0.06 * panBias, 150::ms, 270::ms);
    210::ms => now;
    spork ~ strike(1318.51, 0.86, 0.08 * panBias, 150::ms, 250::ms);
    spork ~ strike(1046.50, 0.62, -0.06 * panBias, 150::ms, 270::ms);
    760::ms => now;
}

120::ms => now;
spork ~ ringPhrase(1.0);
970::ms => now;
spork ~ ringPhrase(-1.0);
940::ms => now;

capture.closeFile();
