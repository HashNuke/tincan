# Audio Turn Pipeline Thread Safety

**Status:** DONE

**Problem:**
The `AudioTurnPipeline` class had a severe thread-safety issue (data race). The `AVAudioEngine` tap block (`handleTapBuffer`) runs continuously on a high-priority, real-time background audio thread, but it was reading and mutating several diagnostic counters and states (like `tapCallbackCount`, `digitalSilenceDuration`, `didLogInputSignal`, `isRecoveringEngine`, etc.) that were concurrently accessed by other non-synchronized `Task` closures and methods called from arbitrary threads. This would eventually cause crashes, race conditions, or dropped buffers due to lack of synchronization.

**Solution:**
We introduced a thread-safe state container named `AudioTurnPipelineTapState` utilizing `NSLock` to encapsulate all the diagnostic counters and flags modified by the tap closure. This isolates the mutable properties and ensures that both the audio thread and the asynchronous task threads can safely read and write to the diagnostic variables without risking data races. The lock guarantees thread safety while allowing `handleTapBuffer` to remain synchronous and non-blocking, ensuring real-time constraints are preserved as much as possible for `AVAudioEngine` tap blocks.
