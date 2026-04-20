package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/pion/interceptor"
	"github.com/pion/webrtc/v4"
)

type server struct {
	mu        sync.Mutex
	sessions  map[string]*sessionState
	api       *webrtc.API
	config    webrtc.Configuration
	inference *inferenceClient
}

type sessionState struct {
	peerConnection *webrtc.PeerConnection
	pushToTalk     bool
}

type webRTCOfferRequest struct {
	SDP  string `json:"sdp"`
	Type string `json:"type"`
}

type webRTCAnswerResponse struct {
	SessionID string `json:"session_id"`
	SDP       string `json:"sdp"`
	Type      string `json:"type"`
}

type inferenceEnvelope struct {
	Kind        string `json:"kind"`
	RequestID   string `json:"request_id"`
	Action      string `json:"action"`
	Model       string `json:"model"`
	ContentType string `json:"content_type"`
	BodyLength  int    `json:"body_length"`
	SampleRate  int    `json:"sample_rate,omitempty"`
	Channels    int    `json:"channels,omitempty"`
	Voice       string `json:"voice,omitempty"`
	TextFormat  string `json:"text_format,omitempty"`
	Message     string `json:"message,omitempty"`
}

type inferenceMessage struct {
	Header inferenceEnvelope
	Body   []byte
}

type sttResult struct {
	Text string `json:"text"`
}

type inferenceClient struct {
	socketPath string
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8004"
	}

	srv := newServer()
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", srv.handleHealth)
	mux.HandleFunc("/speak", srv.handleSpeakPage)
	mux.HandleFunc("/session/", srv.handleSessionControl)
	mux.HandleFunc("/webrtc/offer", srv.handleOffer)

	addr := "0.0.0.0:" + port
	log.Printf("tincan-server listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("server failed: %v", err)
	}
}

func newServer() *server {
	mediaEngine := &webrtc.MediaEngine{}
	if err := mediaEngine.RegisterDefaultCodecs(); err != nil {
		log.Fatalf("register codecs: %v", err)
	}

	interceptorRegistry := &interceptor.Registry{}
	if err := webrtc.RegisterDefaultInterceptors(mediaEngine, interceptorRegistry); err != nil {
		log.Fatalf("register interceptors: %v", err)
	}

	api := webrtc.NewAPI(
		webrtc.WithMediaEngine(mediaEngine),
		webrtc.WithInterceptorRegistry(interceptorRegistry),
	)

	return &server{
		sessions:  make(map[string]*sessionState),
		api:       api,
		inference: &inferenceClient{socketPath: inferenceSocketPath()},
		config: webrtc.Configuration{
			ICEServers: []webrtc.ICEServer{
				{URLs: []string{"stun:stun.l.google.com:19302"}},
			},
		},
	}
}

func (s *server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"status": "ok",
	})
}

func (s *server) handleSpeakPage(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte(speakPageHTML))
}

func (s *server) handleSessionControl(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	path := strings.TrimPrefix(r.URL.Path, "/session/")
	parts := strings.Split(path, "/")
	if len(parts) == 2 && parts[1] == "utterance" {
		s.handleUtteranceUpload(w, r, parts[0])
		return
	}

	if len(parts) != 3 || parts[1] != "push-to-talk" {
		http.NotFound(w, r)
		return
	}

	sessionID := parts[0]
	action := parts[2]

	s.mu.Lock()
	session, ok := s.sessions[sessionID]
	if ok {
		switch action {
		case "start":
			session.pushToTalk = true
		case "stop":
			session.pushToTalk = false
		default:
			s.mu.Unlock()
			http.NotFound(w, r)
			return
		}
	}
	s.mu.Unlock()

	if !ok {
		http.Error(w, "unknown session", http.StatusNotFound)
		return
	}

	log.Printf("peer %s push-to-talk %s", sessionID, action)
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) handleUtteranceUpload(w http.ResponseWriter, r *http.Request, sessionID string) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	s.mu.Lock()
	_, ok := s.sessions[sessionID]
	s.mu.Unlock()
	if !ok {
		http.Error(w, "unknown session", http.StatusNotFound)
		return
	}

	defer r.Body.Close()
	audioData, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "failed to read utterance body", http.StatusBadRequest)
		return
	}
	if len(audioData) == 0 {
		http.Error(w, "expected non-empty utterance audio", http.StatusBadRequest)
		return
	}

	contentType := r.Header.Get("Content-Type")
	if contentType == "" {
		contentType = "audio/wav"
	}

	transcript, err := s.inference.transcribe(audioData, contentType)
	if err != nil {
		log.Printf("peer %s transcription failed: %v", sessionID, err)
		http.Error(w, fmt.Sprintf("transcription failed: %v", err), http.StatusBadGateway)
		return
	}

	log.Printf("peer %s transcript: %s", sessionID, transcript)
	writeJSON(w, http.StatusOK, map[string]any{"text": transcript})
}

func (s *server) handleOffer(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	defer r.Body.Close()

	var offer webRTCOfferRequest
	if err := json.NewDecoder(r.Body).Decode(&offer); err != nil {
		http.Error(w, "invalid json body", http.StatusBadRequest)
		return
	}

	if offer.Type != "offer" || offer.SDP == "" {
		http.Error(w, "expected offer with non-empty sdp", http.StatusBadRequest)
		return
	}

	peerConnection, err := s.api.NewPeerConnection(s.config)
	if err != nil {
		log.Printf("new peer connection failed: %v", err)
		http.Error(w, "failed to create peer connection", http.StatusInternalServerError)
		return
	}

	sessionID := newSessionID()
	s.storePeer(sessionID, peerConnection)
	s.attachPeerLogging(sessionID, peerConnection)

	if _, err = peerConnection.AddTransceiverFromKind(
		webrtc.RTPCodecTypeAudio,
		webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionRecvonly},
	); err != nil {
		s.closeAndDeletePeer(sessionID)
		log.Printf("add audio transceiver failed: %v", err)
		http.Error(w, "failed to add audio transceiver", http.StatusInternalServerError)
		return
	}

	remoteDescription := webrtc.SessionDescription{
		Type: webrtc.SDPTypeOffer,
		SDP:  offer.SDP,
	}
	if err = peerConnection.SetRemoteDescription(remoteDescription); err != nil {
		s.closeAndDeletePeer(sessionID)
		log.Printf("set remote description failed: %v", err)
		http.Error(w, "failed to set remote description", http.StatusBadRequest)
		return
	}

	answer, err := peerConnection.CreateAnswer(nil)
	if err != nil {
		s.closeAndDeletePeer(sessionID)
		log.Printf("create answer failed: %v", err)
		http.Error(w, "failed to create answer", http.StatusInternalServerError)
		return
	}

	gatherComplete := webrtc.GatheringCompletePromise(peerConnection)
	if err = peerConnection.SetLocalDescription(answer); err != nil {
		s.closeAndDeletePeer(sessionID)
		log.Printf("set local description failed: %v", err)
		http.Error(w, "failed to set local description", http.StatusInternalServerError)
		return
	}

	<-gatherComplete

	localDescription := peerConnection.LocalDescription()
	if localDescription == nil {
		s.closeAndDeletePeer(sessionID)
		http.Error(w, "missing local description", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, webRTCAnswerResponse{
		SessionID: sessionID,
		SDP:       localDescription.SDP,
		Type:      localDescription.Type.String(),
	})
}

func (s *server) attachPeerLogging(sessionID string, peerConnection *webrtc.PeerConnection) {
	peerConnection.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		log.Printf("peer %s connection state: %s", sessionID, state.String())
		if state == webrtc.PeerConnectionStateFailed ||
			state == webrtc.PeerConnectionStateClosed ||
			state == webrtc.PeerConnectionStateDisconnected {
			s.closeAndDeletePeer(sessionID)
		}
	})

	peerConnection.OnTrack(func(track *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		log.Printf("peer %s received %s track with codec %s; ignoring media for now", sessionID, track.Kind().String(), track.Codec().MimeType)
		go func() {
			for {
				packet, _, err := track.ReadRTP()
				if err != nil {
					log.Printf("peer %s track reader stopped: %v", sessionID, err)
					return
				}
				log.Printf(
					"peer %s audio packet: ssrc=%d payload_type=%d sequence=%d timestamp=%d marker=%t payload_bytes=%d",
					sessionID,
					packet.SSRC,
					packet.PayloadType,
					packet.SequenceNumber,
					packet.Timestamp,
					packet.Marker,
					len(packet.Payload),
				)
			}
		}()
	})
	peerConnection.OnDataChannel(func(dataChannel *webrtc.DataChannel) {
		log.Printf("peer %s opened data channel %q; ignoring messages for now", sessionID, dataChannel.Label())
	})
}

func (s *server) storePeer(sessionID string, peerConnection *webrtc.PeerConnection) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sessions[sessionID] = &sessionState{peerConnection: peerConnection}
}

func (s *server) closeAndDeletePeer(sessionID string) {
	s.mu.Lock()
	session, ok := s.sessions[sessionID]
	if ok {
		delete(s.sessions, sessionID)
	}
	s.mu.Unlock()

	if ok {
		_ = session.peerConnection.Close()
	}
}

func newSessionID() string {
	return time.Now().UTC().Format("20060102T150405.000000000")
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		log.Printf("write json failed: %v", err)
	}
}

func (c *inferenceClient) transcribe(audioData []byte, contentType string) (string, error) {
	conn, err := net.Dial("unix", c.socketPath)
	if err != nil {
		return "", err
	}
	defer conn.Close()

	requestID := uuid.NewString()
	request := inferenceMessage{
		Header: inferenceEnvelope{
			Kind:        "request",
			RequestID:   requestID,
			Action:      "stt",
			Model:       "nvidia-parakeet",
			ContentType: contentType,
			BodyLength:  len(audioData),
		},
		Body: audioData,
	}

	if err := writeInferenceMessage(conn, request); err != nil {
		return "", err
	}

	response, err := readInferenceMessage(conn)
	if err != nil {
		return "", err
	}

	if response.Header.Kind == "error" {
		return "", fmt.Errorf(response.Header.Message)
	}

	if response.Header.Kind != "result" || response.Header.Action != "stt" {
		return "", fmt.Errorf("unexpected inference response: %+v", response.Header)
	}

	var result sttResult
	if err := json.Unmarshal(response.Body, &result); err != nil {
		return "", err
	}
	return result.Text, nil
}

func writeInferenceMessage(writer io.Writer, message inferenceMessage) error {
	headerBytes, err := json.Marshal(message.Header)
	if err != nil {
		return err
	}

	var headerLength [4]byte
	binary.BigEndian.PutUint32(headerLength[:], uint32(len(headerBytes)))
	if _, err := writer.Write(headerLength[:]); err != nil {
		return err
	}
	if _, err := writer.Write(headerBytes); err != nil {
		return err
	}
	if len(message.Body) > 0 {
		if _, err := writer.Write(message.Body); err != nil {
			return err
		}
	}
	return nil
}

func readInferenceMessage(reader io.Reader) (inferenceMessage, error) {
	var headerLengthBytes [4]byte
	if _, err := io.ReadFull(reader, headerLengthBytes[:]); err != nil {
		return inferenceMessage{}, err
	}

	headerLength := binary.BigEndian.Uint32(headerLengthBytes[:])
	headerBytes := make([]byte, int(headerLength))
	if _, err := io.ReadFull(reader, headerBytes); err != nil {
		return inferenceMessage{}, err
	}

	var header inferenceEnvelope
	if err := json.Unmarshal(headerBytes, &header); err != nil {
		return inferenceMessage{}, err
	}

	body := make([]byte, header.BodyLength)
	if header.BodyLength > 0 {
		if _, err := io.ReadFull(reader, body); err != nil {
			return inferenceMessage{}, err
		}
	}

	return inferenceMessage{Header: header, Body: body}, nil
}

func inferenceSocketPath() string {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return homeDir + "/Library/Application Support/tincan/run/inference.sock"
}

const speakPageHTML = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Tincan Speak</title>
  <style>
    :root { color-scheme: dark; }
    body {
      font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      background: #0a0d14;
      color: #edf2ff;
    }
    main {
      width: min(680px, calc(100vw - 32px));
      padding: 28px;
      border-radius: 20px;
      background: linear-gradient(180deg, rgba(31, 42, 68, 0.95), rgba(16, 22, 37, 0.98));
      box-shadow: 0 24px 60px rgba(0, 0, 0, 0.35);
    }
    h1 { margin: 0 0 8px; font-size: 28px; }
    p { margin: 0 0 18px; color: #b9c4df; line-height: 1.5; }
    .row { display: flex; gap: 12px; flex-wrap: wrap; margin-bottom: 18px; }
    button {
      border: 0;
      border-radius: 12px;
      padding: 12px 16px;
      background: #4f7cff;
      color: white;
      font: inherit;
      cursor: pointer;
    }
    button:disabled { opacity: 0.55; cursor: default; }
    .status {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 10px 12px;
      border-radius: 999px;
      background: rgba(255, 255, 255, 0.08);
      color: #dfe8ff;
      font-size: 14px;
      margin-bottom: 16px;
    }
    .status::before {
      content: "";
      width: 10px;
      height: 10px;
      border-radius: 999px;
      background: #8794b5;
      box-shadow: 0 0 0 6px rgba(135, 148, 181, 0.15);
    }
    .status.live::before { background: #3ddc97; box-shadow: 0 0 0 6px rgba(61, 220, 151, 0.16); }
    .status.talking::before { background: #ffb648; box-shadow: 0 0 0 6px rgba(255, 182, 72, 0.18); }
    .meta {
      font-size: 13px;
      color: #93a2c8;
      margin-top: 12px;
      white-space: pre-wrap;
    }
    code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
  </style>
</head>
<body>
  <main>
    <h1>Speak Test</h1>
    <p>Connects to the local Go WebRTC endpoint. Hold <code>Z</code> to send microphone audio, release to stop sending.</p>
    <div id="status" class="status">Disconnected</div>
    <div class="row">
      <button id="connectButton">Connect</button>
      <button id="disconnectButton" disabled>Disconnect</button>
    </div>
    <div class="meta" id="meta">Waiting to connect.</div>
  </main>
  <script>
    const connectButton = document.getElementById('connectButton')
    const disconnectButton = document.getElementById('disconnectButton')
    const statusEl = document.getElementById('status')
    const metaEl = document.getElementById('meta')

    let peerConnection = null
    let localStream = null
    let audioTrack = null
    let audioSender = null
    let isHoldingPushToTalk = false
    let sessionID = null
    let captureContext = null
    let captureSource = null
    let captureProcessor = null
    let capturedChunks = []
    let captureSampleRate = 48000

    function setStatus(text, klass = '') {
      statusEl.textContent = text
      statusEl.className = ('status ' + klass).trim()
    }

    function setMeta(text) {
      metaEl.textContent = text
    }

    async function connect() {
      if (peerConnection) return

      setStatus('Requesting microphone…')
      setMeta('Browser microphone permission is still required, even on localhost.')

      localStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false })
      audioTrack = localStream.getAudioTracks()[0]
      audioTrack.enabled = false
      setStatus('Microphone ready')
      setMeta('Microphone granted. Creating WebRTC peer connection…')

      peerConnection = new RTCPeerConnection({
        iceServers: [{ urls: ['stun:stun.l.google.com:19302'] }],
      })

      for (const track of localStream.getTracks()) {
        const sender = peerConnection.addTrack(track, localStream)
        if (track.kind === 'audio') {
          audioSender = sender
        }
      }

      if (audioSender) {
        await audioSender.replaceTrack(null)
      }

      peerConnection.onicegatheringstatechange = () => {
        if (!peerConnection) return
        const state = peerConnection.iceGatheringState
        if (state === 'gathering') {
          setStatus('Gathering ICE…')
          setMeta('Preparing local network candidates for the WebRTC connection…')
        }
      }

      peerConnection.onconnectionstatechange = () => {
        const state = peerConnection?.connectionState || 'closed'
        if (state === 'connected') {
          setStatus(isHoldingPushToTalk ? 'Connected, sending audio' : 'Connected', isHoldingPushToTalk ? 'talking' : 'live')
        } else {
          setStatus('Connection: ' + state)
        }
        setMeta('WebRTC state: ' + state)
      }

      const offer = await peerConnection.createOffer()
      await peerConnection.setLocalDescription(offer)

      setStatus('Connecting…')
      setMeta('Sending WebRTC offer to the local Go server…')

      await waitForIceGathering(peerConnection, 3000)

      const response = await fetch('/webrtc/offer', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          sdp: peerConnection.localDescription.sdp,
          type: peerConnection.localDescription.type,
        }),
      })

      if (!response.ok) {
        throw new Error('Offer request failed with ' + response.status)
      }

      const answer = await response.json()
      await peerConnection.setRemoteDescription({ type: answer.type, sdp: answer.sdp })
      sessionID = answer.session_id

      connectButton.disabled = true
      disconnectButton.disabled = false
      setStatus('Connected', 'live')
      setMeta('Connected. Session: ' + answer.session_id + '\nHold Z to transmit audio.')
    }

    async function disconnect() {
      isHoldingPushToTalk = false
      if (audioTrack) {
        audioTrack.enabled = false
      }
      if (peerConnection) {
        peerConnection.close()
        peerConnection = null
      }
      if (localStream) {
        for (const track of localStream.getTracks()) {
          track.stop()
        }
        localStream = null
      }
      audioTrack = null
      sessionID = null
      if (captureProcessor) {
        captureProcessor.disconnect()
      }
      if (captureSource) {
        captureSource.disconnect()
      }
      if (captureContext) {
        await captureContext.close()
      }
      connectButton.disabled = false
      disconnectButton.disabled = true
      setStatus('Disconnected')
      setMeta('Disconnected.')
    }

    function updatePushToTalk(active) {
      isHoldingPushToTalk = active
      if (!audioTrack || !audioSender) return

      const applyTrack = async () => {
        try {
          if (!sessionID) {
            throw new Error('Missing session ID')
          }

          const controlResponse = await fetch('/session/' + encodeURIComponent(sessionID) + '/push-to-talk/' + (active ? 'start' : 'stop'), {
            method: 'POST',
          })
          if (!controlResponse.ok) {
            throw new Error('Push-to-talk control failed with ' + controlResponse.status)
          }

          if (active) {
            startCapture()
          }

          await audioSender.replaceTrack(active ? audioTrack : null)
          if (!active) {
            await stopCaptureAndUpload()
          }
          if (!peerConnection || peerConnection.connectionState !== 'connected') return
          setStatus(active ? 'Connected, sending audio' : 'Connected', active ? 'talking' : 'live')
          setMeta(active ? 'Transmitting microphone audio while Z is held.' : 'Microphone connected but muted. Hold Z to transmit audio.')
        } catch (error) {
          console.error(error)
          setMeta('Push-to-talk toggle failed: ' + (error instanceof Error ? error.message : String(error)))
        }
      }

      void applyTrack()
    }

    function startCapture() {
      capturedChunks.length = 0
      if (!localStream) return

      if (!captureContext) {
        const AudioContextCtor = window.AudioContext || window.webkitAudioContext
        captureContext = new AudioContextCtor({ sampleRate: captureSampleRate })
        captureSource = captureContext.createMediaStreamSource(localStream)
        captureProcessor = captureContext.createScriptProcessor(4096, 1, 1)
        captureProcessor.onaudioprocess = (event) => {
          if (!isHoldingPushToTalk) return
          const channel = event.inputBuffer.getChannelData(0)
          capturedChunks.push(new Float32Array(channel))
        }
        captureSource.connect(captureProcessor)
        captureProcessor.connect(captureContext.destination)
      }
    }

    async function stopCaptureAndUpload() {
      if (!sessionID || capturedChunks.length === 0) return

      const wavBytes = encodeWav(capturedChunks, captureSampleRate)
      capturedChunks.length = 0

      const response = await fetch('/session/' + encodeURIComponent(sessionID) + '/utterance', {
        method: 'POST',
        headers: {
          'content-type': 'audio/wav',
        },
        body: wavBytes,
      })

      if (!response.ok) {
        throw new Error('Utterance upload failed with ' + response.status)
      }

      const payload = await response.json()
      setMeta('Transcript: ' + (payload.text || '(empty)'))
    }

    function encodeWav(chunks, sampleRate) {
      const totalSamples = chunks.reduce((sum, chunk) => sum + chunk.length, 0)
      const bytesPerSample = 2
      const dataSize = totalSamples * bytesPerSample
      const buffer = new ArrayBuffer(44 + dataSize)
      const view = new DataView(buffer)

      writeAscii(view, 0, 'RIFF')
      view.setUint32(4, 36 + dataSize, true)
      writeAscii(view, 8, 'WAVE')
      writeAscii(view, 12, 'fmt ')
      view.setUint32(16, 16, true)
      view.setUint16(20, 1, true)
      view.setUint16(22, 1, true)
      view.setUint32(24, sampleRate, true)
      view.setUint32(28, sampleRate * bytesPerSample, true)
      view.setUint16(32, bytesPerSample, true)
      view.setUint16(34, 16, true)
      writeAscii(view, 36, 'data')
      view.setUint32(40, dataSize, true)

      let offset = 44
      for (const chunk of chunks) {
        for (let i = 0; i < chunk.length; i += 1) {
          const sample = Math.max(-1, Math.min(1, chunk[i]))
          view.setInt16(offset, sample < 0 ? sample * 0x8000 : sample * 0x7fff, true)
          offset += 2
        }
      }

      return buffer
    }

    function writeAscii(view, offset, value) {
      for (let i = 0; i < value.length; i += 1) {
        view.setUint8(offset + i, value.charCodeAt(i))
      }
    }

    function waitForIceGathering(pc, timeoutMs) {
      if (pc.iceGatheringState === 'complete') return Promise.resolve()
      return new Promise((resolve) => {
        const timeout = window.setTimeout(() => {
          pc.removeEventListener('icegatheringstatechange', checkState)
          resolve()
        }, timeoutMs)

        function checkState() {
          if (pc.iceGatheringState === 'complete') {
            window.clearTimeout(timeout)
            pc.removeEventListener('icegatheringstatechange', checkState)
            resolve()
          }
        }
        pc.addEventListener('icegatheringstatechange', checkState)
      })
    }

    connectButton.addEventListener('click', async () => {
      connectButton.disabled = true
      try {
        await connect()
      } catch (error) {
        console.error(error)
        await disconnect()
        setMeta('Connect failed: ' + (error instanceof Error ? error.message : String(error)))
      }
    })

    disconnectButton.addEventListener('click', async () => {
      await disconnect()
    })

    window.addEventListener('keydown', (event) => {
      if (event.repeat) return
      if (event.key.toLowerCase() !== 'z') return
      if (!peerConnection) return
      updatePushToTalk(true)
    })

    window.addEventListener('keyup', (event) => {
      if (event.key.toLowerCase() !== 'z') return
      updatePushToTalk(false)
    })
  </script>
</body>
</html>
`
