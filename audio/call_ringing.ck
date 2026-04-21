// A softer phone-like double-ring with a gentle "krrrr" character.

3.2::second => dur LOOP_DUR;

Gain master => LPF soften => Gain dry => dac;
soften => JCRev rev => LPF revTone => Gain wet => dac;
dac => WvOut2 capture => blackhole;
(me.dir() + "output/call_ringing.wav", IO.INT24) => capture.wavFilename;
0.94 => capture.fileGain;
1.20 => master.gain;
1900.0 => soften.freq;
0.86 => dry.gain;
0.14 => wet.gain;
0.08 => rev.mix;
1500.0 => revTone.freq;

fun void strike(float freq, float amp, float pan, dur hold, dur releaseTime)
{
    SawOsc buzzA => Gain blend => ADSR env => LPF tone => Gain voice => Pan2 p => master;
    SqrOsc buzzB => blend;
    Noise grit => HPF gritHPF => LPF gritLPF => Gain airy => blend;
    SinOsc wobble => blackhole;

    pan => p.pan;
    22.0 => wobble.freq;
    freq => buzzA.freq;
    freq * 1.005 => buzzB.freq;

    0.11 => buzzA.gain;
    0.06 => buzzB.gain;
    700.0 => gritHPF.freq;
    1800.0 => gritLPF.freq;
    0.012 => grit.gain;
    0.03 => airy.gain;

    1200.0 => tone.freq;
    amp => voice.gain;

    env.set(3::ms, 24::ms, 0.74, releaseTime);
    env.keyOn();
    12 => int steps;
    hold / steps => dur stepDur;
    for (0 => int i; i < steps; i++)
    {
        freq + (wobble.last() * 5.0) => buzzA.freq;
        (freq * 1.005) + (wobble.last() * 3.5) => buzzB.freq;
        stepDur => now;
    }
    env.keyOff();
    releaseTime => now;
}

fun void ringPhrase(float panBias)
{
    spork ~ strike(760.0, 0.74, -0.08 * panBias, 135::ms, 165::ms);
    spork ~ strike(640.0, 0.38, 0.05 * panBias, 135::ms, 175::ms);
    210::ms => now;
    spork ~ strike(760.0, 0.68, 0.08 * panBias, 135::ms, 165::ms);
    spork ~ strike(640.0, 0.34, -0.05 * panBias, 135::ms, 175::ms);
    980::ms => now;
}

120::ms => now;
spork ~ ringPhrase(1.0);
1180::ms => now;
spork ~ ringPhrase(-1.0);
1180::ms => now;

capture.closeFile();
