package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"log"
	"math"
	"sync"
	"time"

	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
)

const (
	webrtcAudioSampleRate    = 8000
	webrtcAudioChannels      = 1
	webrtcAudioFrameDuration = 20 * time.Millisecond
	webrtcAudioFrameSamples  = webrtcAudioSampleRate / 50
	webrtcAudioQueueCapacity = 8
)

type sessionAudioWriter struct {
	sessionID string
	track     *webrtc.TrackLocalStaticSample
	queue     chan []byte
	stop      chan struct{}
	done      chan struct{}

	mu     sync.Mutex
	closed bool
}

func newSessionAudioWriter(sessionID string, track *webrtc.TrackLocalStaticSample) *sessionAudioWriter {
	writer := &sessionAudioWriter{
		sessionID: sessionID,
		track:     track,
		queue:     make(chan []byte, webrtcAudioQueueCapacity),
		stop:      make(chan struct{}),
		done:      make(chan struct{}),
	}
	go writer.run()
	return writer
}

func (w *sessionAudioWriter) Enqueue(audioData []byte) error {
	if len(audioData) == 0 {
		return nil
	}

	w.mu.Lock()
	defer w.mu.Unlock()
	if w.closed {
		return errors.New("session audio writer is closed")
	}

	copied := append([]byte(nil), audioData...)
	select {
	case w.queue <- copied:
		return nil
	default:
		return errors.New("session audio queue is full")
	}
}

func (w *sessionAudioWriter) Close() {
	w.mu.Lock()
	if w.closed {
		w.mu.Unlock()
		return
	}
	w.closed = true
	close(w.stop)
	close(w.queue)
	w.mu.Unlock()

	<-w.done
}

func (w *sessionAudioWriter) run() {
	defer close(w.done)

	for {
		select {
		case <-w.stop:
			return
		case audioData, ok := <-w.queue:
			if !ok {
				return
			}
			if err := w.writeWAV(audioData); err != nil {
				log.Printf("webrtc: failed to play session %s audio: %v", w.sessionID, err)
			}
		}
	}
}

func (w *sessionAudioWriter) writeWAV(audioData []byte) error {
	frames, err := wavToPCMUFrames(audioData)
	if err != nil {
		return err
	}

	for index, frame := range frames {
		select {
		case <-w.stop:
			return nil
		default:
		}

		if err := w.track.WriteSample(media.Sample{
			Data:     frame,
			Duration: webrtcAudioFrameDuration,
		}); err != nil {
			return err
		}

		if index == len(frames)-1 {
			continue
		}

		timer := time.NewTimer(webrtcAudioFrameDuration)
		select {
		case <-timer.C:
		case <-w.stop:
			if !timer.Stop() {
				<-timer.C
			}
			return nil
		}
	}

	return nil
}

func wavToPCMUFrames(audioData []byte) ([][]byte, error) {
	samples, sampleRate, err := decodePCM16WAV(audioData)
	if err != nil {
		return nil, err
	}
	if len(samples) == 0 {
		return nil, nil
	}

	resampled := resamplePCM16(samples, sampleRate, webrtcAudioSampleRate)
	if len(resampled) == 0 {
		return nil, nil
	}

	frameCount := (len(resampled) + webrtcAudioFrameSamples - 1) / webrtcAudioFrameSamples
	frames := make([][]byte, 0, frameCount)
	for start := 0; start < len(resampled); start += webrtcAudioFrameSamples {
		frame := make([]byte, webrtcAudioFrameSamples)
		for index := 0; index < webrtcAudioFrameSamples; index++ {
			sampleIndex := start + index
			if sampleIndex < len(resampled) {
				frame[index] = linearToMuLaw(resampled[sampleIndex])
			} else {
				frame[index] = linearToMuLaw(0)
			}
		}
		frames = append(frames, frame)
	}

	return frames, nil
}

func decodePCM16WAV(audioData []byte) ([]int16, int, error) {
	if len(audioData) < 12 {
		return nil, 0, errors.New("wav payload is too short")
	}
	if string(audioData[:4]) != "RIFF" || string(audioData[8:12]) != "WAVE" {
		return nil, 0, errors.New("wav payload is missing RIFF/WAVE header")
	}

	var (
		audioFormat   uint16
		channelCount  uint16
		sampleRate    uint32
		bitsPerSample uint16
		pcmData       []byte
	)

	for offset := 12; offset+8 <= len(audioData); {
		chunkID := string(audioData[offset : offset+4])
		chunkSize := int(binary.LittleEndian.Uint32(audioData[offset+4 : offset+8]))
		chunkStart := offset + 8
		chunkEnd := chunkStart + chunkSize
		if chunkEnd > len(audioData) {
			return nil, 0, fmt.Errorf("wav chunk %q exceeds payload length", chunkID)
		}

		switch chunkID {
		case "fmt ":
			if chunkSize < 16 {
				return nil, 0, errors.New("wav fmt chunk is too short")
			}
			audioFormat = binary.LittleEndian.Uint16(audioData[chunkStart : chunkStart+2])
			channelCount = binary.LittleEndian.Uint16(audioData[chunkStart+2 : chunkStart+4])
			sampleRate = binary.LittleEndian.Uint32(audioData[chunkStart+4 : chunkStart+8])
			bitsPerSample = binary.LittleEndian.Uint16(audioData[chunkStart+14 : chunkStart+16])
		case "data":
			pcmData = audioData[chunkStart:chunkEnd]
		}

		offset = chunkEnd
		if chunkSize%2 == 1 {
			offset += 1
		}
	}

	if audioFormat != 1 {
		return nil, 0, fmt.Errorf("unsupported wav audio format %d", audioFormat)
	}
	if channelCount == 0 {
		return nil, 0, errors.New("wav channel count is invalid")
	}
	if sampleRate == 0 {
		return nil, 0, errors.New("wav sample rate is invalid")
	}
	if bitsPerSample != 16 {
		return nil, 0, fmt.Errorf("unsupported wav bit depth %d", bitsPerSample)
	}
	if len(pcmData)%2 != 0 {
		return nil, 0, errors.New("wav pcm data is truncated")
	}

	totalSamples := len(pcmData) / 2
	if totalSamples == 0 {
		return nil, int(sampleRate), nil
	}

	samples := make([]int16, totalSamples/int(channelCount))
	for frameIndex := range samples {
		var mixed int32
		for channel := 0; channel < int(channelCount); channel++ {
			sampleOffset := (frameIndex*int(channelCount) + channel) * 2
			mixed += int32(int16(binary.LittleEndian.Uint16(pcmData[sampleOffset : sampleOffset+2])))
		}
		samples[frameIndex] = int16(mixed / int32(channelCount))
	}

	return samples, int(sampleRate), nil
}

func resamplePCM16(samples []int16, sourceRate int, targetRate int) []int16 {
	if len(samples) == 0 || sourceRate <= 0 || targetRate <= 0 {
		return nil
	}
	if sourceRate == targetRate {
		return append([]int16(nil), samples...)
	}

	outputLength := int(math.Round(float64(len(samples)) * float64(targetRate) / float64(sourceRate)))
	if outputLength < 1 {
		outputLength = 1
	}

	output := make([]int16, outputLength)
	ratio := float64(sourceRate) / float64(targetRate)
	for index := 0; index < outputLength; index++ {
		position := float64(index) * ratio
		lower := int(position)
		if lower >= len(samples)-1 {
			output[index] = samples[len(samples)-1]
			continue
		}

		upper := lower + 1
		weight := position - float64(lower)
		sample := float64(samples[lower])*(1-weight) + float64(samples[upper])*weight
		output[index] = int16(math.Round(sample))
	}

	return output
}

func linearToMuLaw(sample int16) byte {
	const (
		muLawBias = 0x84
		muLawClip = 32635
	)

	value := int(sample)
	sign := (value >> 8) & 0x80
	if sign != 0 {
		value = -value
	}
	if value > muLawClip {
		value = muLawClip
	}
	value += muLawBias

	exponent := 7
	for expMask := 0x4000; (value&expMask) == 0 && exponent > 0; expMask >>= 1 {
		exponent--
	}
	mantissa := (value >> (exponent + 3)) & 0x0f

	return byte(^(sign | (exponent << 4) | mantissa))
}
