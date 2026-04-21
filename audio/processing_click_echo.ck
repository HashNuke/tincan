// A soft bead-like click followed by decaying repeats.

2.6::second => dur LOOP_DUR;

Gain master => LPF round => LPF soften => dac;
dac => WvOut2 capture => blackhole;
(me.dir() + "processing_click_echo.wav", IO.INT24) => capture.wavFilename;
1.0 => capture.fileGain;
8.20 => master.gain;
1650.0 => round.freq;
1200.0 => soften.freq;

fun void bead(float amp, float pan, float distance, float edgeCutoff, float airCutoff, float bodyCutoff, dur hold, dur releaseTime)
{
    Gain sum;
    Impulse hit => Gain hitTrim => HPF edgeHPF => LPF edgeLPF => Gain hitVoice => sum;
    Noise grit => HPF gritHPF => LPF gritLPF => ADSR gritEnv => Gain gritVoice => sum;
    Noise body => HPF bodyHPF => LPF bodyLPF => ADSR bodyEnv => Gain bodyVoice => sum;
    sum => LPF distanceTone => Gain dry => Pan2 dryPan => master;
    distanceTone => JCRev rev => Gain wet => Pan2 wetPan => master;

    pan * (1.0 - distance * 0.20) => dryPan.pan;
    pan * (0.70 - distance * 0.30) => wetPan.pan;

    1.0 => rev.mix;
    (1.0 - distance * 0.62) => dry.gain;
    (0.16 + distance * 0.30) => wet.gain;
    (1700.0 - distance * 650.0) => distanceTone.freq;

    0.24 => hitTrim.gain;
    140.0 => edgeHPF.freq;
    edgeCutoff * (1.0 - distance * 0.22) => edgeLPF.freq;
    amp * 0.44 => hitVoice.gain;

    450.0 => gritHPF.freq;
    airCutoff * (1.0 - distance * 0.30) => gritLPF.freq;
    0.02 => grit.gain;
    amp * 0.10 => gritVoice.gain;

    60.0 => bodyHPF.freq;
    bodyCutoff * (1.0 - distance * 0.18) => bodyLPF.freq;
    0.12 => body.gain;
    amp * 0.82 => bodyVoice.gain;

    gritEnv.set(2::ms, 12::ms, 0.0, releaseTime + 18::ms);
    bodyEnv.set(4::ms, 18::ms, 0.0, releaseTime + 40::ms);

    1.0 => hit.next;
    gritEnv.keyOn();
    bodyEnv.keyOn();
    hold => now;
    gritEnv.keyOff();
    bodyEnv.keyOff();
    releaseTime => now;
}

fun void click(float amp, float width, float distance, float edgeCutoff, float airCutoff, float bodyCutoff)
{
    spork ~ bead(amp * 1.00, -0.32 * width, distance, edgeCutoff, airCutoff, bodyCutoff, 6::ms, 58::ms);
    7::ms => now;
    spork ~ bead(amp * 0.78, 0.34 * width, distance + 0.04, edgeCutoff * 0.90, airCutoff * 0.92, bodyCutoff * 0.95, 6::ms, 62::ms);
    10::ms => now;
    spork ~ bead(amp * 0.58, -0.08 * width, distance + 0.08, edgeCutoff * 0.82, airCutoff * 0.86, bodyCutoff * 0.90, 6::ms, 68::ms);
}

fun void echoTrain()
{
    0.92 => float amp;
    0.92 => float width;
    0.34 => float distance;
    1350.0 => float edgeCutoff;
    1900.0 => float airCutoff;
    660.0 => float bodyCutoff;
    210::ms => dur gap;

    spork ~ click(amp, width, distance, edgeCutoff, airCutoff, bodyCutoff);

    repeat(7)
    {
        gap => now;
        amp * 0.72 => amp;
        width * 0.94 => width;
        edgeCutoff * 0.90 => edgeCutoff;
        airCutoff * 0.88 => airCutoff;
        bodyCutoff * 0.93 => bodyCutoff;
        distance + 0.09 => distance;
        if( distance > 0.88 ) 0.88 => distance;
        spork ~ click(amp, width, distance, edgeCutoff, airCutoff, bodyCutoff);
    }
}

80::ms => now;
spork ~ echoTrain();
840::ms => now;
spork ~ echoTrain();
1680::ms => now;

capture.closeFile();
