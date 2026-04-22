package main

import (
	"encoding/binary"
	"testing"
)

func TestWAVToPCMUFramesResamplesTwentyMillisecondsToSingleFrame(t *testing.T) {
	samples := make([]int16, 480)
	for index := range samples {
		samples[index] = int16((index % 64) * 200)
	}

	audioData := testPCM16WAV(samples, 24_000, 1)
	frames, err := wavToPCMUFrames(audioData)
	if err != nil {
		t.Fatalf("wavToPCMUFrames returned error: %v", err)
	}
	if len(frames) != 1 {
		t.Fatalf("expected 1 frame, got %d", len(frames))
	}
	if len(frames[0]) != webrtcAudioFrameSamples {
		t.Fatalf("expected %d samples in frame, got %d", webrtcAudioFrameSamples, len(frames[0]))
	}
}

func TestDecodePCM16WAVMixesStereoToMono(t *testing.T) {
	audioData := testPCM16WAV([]int16{3000, -3000, 2000, -2000}, 24_000, 2)

	samples, sampleRate, err := decodePCM16WAV(audioData)
	if err != nil {
		t.Fatalf("decodePCM16WAV returned error: %v", err)
	}
	if sampleRate != 24_000 {
		t.Fatalf("expected sample rate 24000, got %d", sampleRate)
	}
	if len(samples) != 2 {
		t.Fatalf("expected 2 mixed samples, got %d", len(samples))
	}
	if samples[0] != 0 || samples[1] != 0 {
		t.Fatalf("expected stereo samples to average to 0, got %v", samples)
	}
}

func testPCM16WAV(samples []int16, sampleRate int, channels int) []byte {
	pcm := make([]byte, len(samples)*2)
	for index, sample := range samples {
		binary.LittleEndian.PutUint16(pcm[index*2:], uint16(sample))
	}

	byteRate := sampleRate * channels * 2
	blockAlign := channels * 2
	riffChunkSize := 36 + len(pcm)

	data := make([]byte, 44+len(pcm))
	copy(data[0:], []byte("RIFF"))
	binary.LittleEndian.PutUint32(data[4:], uint32(riffChunkSize))
	copy(data[8:], []byte("WAVE"))
	copy(data[12:], []byte("fmt "))
	binary.LittleEndian.PutUint32(data[16:], 16)
	binary.LittleEndian.PutUint16(data[20:], 1)
	binary.LittleEndian.PutUint16(data[22:], uint16(channels))
	binary.LittleEndian.PutUint32(data[24:], uint32(sampleRate))
	binary.LittleEndian.PutUint32(data[28:], uint32(byteRate))
	binary.LittleEndian.PutUint16(data[32:], uint16(blockAlign))
	binary.LittleEndian.PutUint16(data[34:], 16)
	copy(data[36:], []byte("data"))
	binary.LittleEndian.PutUint32(data[40:], uint32(len(pcm)))
	copy(data[44:], pcm)
	return data
}
