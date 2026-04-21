// A softer phone-like double-ring with a gentle "krrrr" character.

3.2::second => dur LOOP_DUR;

Gain master => LPF soften => Gain dry => dac;
soften => JCRev rev => LPF revTone => Gain wet => dac;
dac => WvOut2 capture => blackhole;
(me.dir() + "output/call_ringing.wav", IO.INT24) => capture.wavFilename;
0.98 => capture.fileGain;
2.20 => master.gain;
1500.0 => soften.freq;
0.92 => dry.gain;
0.08 => wet.gain;
0.05 => rev.mix;
1200.0 => revTone.freq;

fun void strike(float freq, float amp, float pan, dur hold, dur releaseTime)
{
    SawOsc buzzA => Gain blend => ADSR env => LPF tone => Gain voice => Pan2 p => master;
    SqrOsc buzzB => blend;
    Noise grit => HPF gritHPF => LPF gritLPF => ADSR gritEnv => Gain airy => blend;
    SinOsc wobble => blackhole;

    pan => p.pan;
    18.0 => wobble.freq;
    freq => buzzA.freq;
    freq * 1.005 => buzzB.freq;

    0.08 => buzzA.gain;
    0.045 => buzzB.gain;
    500.0 => gritHPF.freq;
    1300.0 => gritLPF.freq;
    0.014 => grit.gain;
    0.05 => airy.gain;

    980.0 => tone.freq;
    amp => voice.gain;

    env.set(6::ms, 34::ms, 0.68, releaseTime);
    gritEnv.set(2::ms, 18::ms, 0.0, releaseTime + 20::ms);
    env.keyOn();
    gritEnv.keyOn();
    12 => int steps;
    hold / steps => dur stepDur;
    for (0 => int i; i < steps; i++)
    {
        freq + (wobble.last() * 3.0) => buzzA.freq;
        (freq * 1.005) + (wobble.last() * 2.2) => buzzB.freq;
        stepDur => now;
    }
    env.keyOff();
    gritEnv.keyOff();
    releaseTime => now;
}

fun void ringPhrase(float panBias)
{
    spork ~ strike(610.0, 0.58, -0.03 * panBias, 150::ms, 185::ms);
    spork ~ strike(560.0, 0.26, 0.02 * panBias, 150::ms, 195::ms);
    210::ms => now;
    spork ~ strike(610.0, 0.54, 0.03 * panBias, 150::ms, 185::ms);
    spork ~ strike(560.0, 0.24, -0.02 * panBias, 150::ms, 195::ms);
    980::ms => now;
}

120::ms => now;
spork ~ ringPhrase(1.0);
1180::ms => now;
spork ~ ringPhrase(-1.0);
1180::ms => now;

capture.closeFile();
