package main

import (
	"net/url"
	"os"
	"strings"

	"github.com/pion/webrtc/v4"
)

type webrtcICEConfigResponse struct {
	ICEServers []webrtcICEServerResponse `json:"ice_servers"`
}

type webrtcICEServerResponse struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}

func serverPeerConnectionConfiguration() webrtc.Configuration {
	return webrtc.Configuration{
		ICEServers: configuredICEServers(),
	}
}

func currentWebRTCConfigResponse() webrtcICEConfigResponse {
	iceServers := configuredICEServers()
	response := webrtcICEConfigResponse{
		ICEServers: make([]webrtcICEServerResponse, 0, len(iceServers)),
	}
	for _, server := range iceServers {
		credential, _ := server.Credential.(string)
		response.ICEServers = append(response.ICEServers, webrtcICEServerResponse{
			URLs:       append([]string(nil), server.URLs...),
			Username:   server.Username,
			Credential: credential,
		})
	}
	return response
}

func configuredICEServers() []webrtc.ICEServer {
	urls := parseICEURLs(os.Getenv("TINCAN_WEBRTC_ICE_URLS"))
	if len(urls) == 0 {
		return nil
	}

	return []webrtc.ICEServer{
		{
			URLs:       urls,
			Username:   strings.TrimSpace(os.Getenv("TINCAN_WEBRTC_ICE_USERNAME")),
			Credential: strings.TrimSpace(os.Getenv("TINCAN_WEBRTC_ICE_CREDENTIAL")),
		},
	}
}

func parseICEURLs(raw string) []string {
	fields := strings.FieldsFunc(raw, func(r rune) bool {
		return r == ',' || r == '\n'
	})
	urls := make([]string, 0, len(fields))
	for _, field := range fields {
		candidate := strings.TrimSpace(field)
		if candidate == "" {
			continue
		}
		if _, err := url.Parse(candidate); err != nil {
			continue
		}
		urls = append(urls, candidate)
	}
	return urls
}
