# Build notes

> App is in Swift, why not build the server too in Swift?
I did. Then I found out that there is no WebRTC server in Swift. One of the popular WebRTC server implementations is in Golang.

> Why not build the server fully in Golang?
Because we have to run CoreML or MLX models. And the most reliable way is in Swift.

> Why not Expo or Tauri or React Native for the app?
Safari on iOS doesn't play webrtc audio. I already tried a webpage in the golang server and tried it on Safari on iOS. Embedded webview would be no different.
