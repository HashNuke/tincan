# tincan app

The goal of this app is to be an app where I can talk to it on call (like how whatsapp calls, Messenger calls, etc happen on phone or desktop). And it should help with orchestrating my coding agent.

This is a multiplatform app. So it'll work on both ipad and iphone and mac. We'll add Apple Watch features later.

Primary functionality
* I should be able to start on call on the app.
* The app sends the audio to the server/endpoint it runs (on the backend)
* The backend uses a speech-to-text model (nvidia parakeet) via mlx-audio-swift library to understand what I'm saying.
* And then execute it with one of the coding agents running. It could be sending a message to an existing session, or creating a new session.
