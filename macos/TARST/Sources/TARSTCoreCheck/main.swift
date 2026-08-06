import Foundation
import TARSTCore

let ringBuffer = PCM16RingBuffer(sampleRate: 10, seconds: 1)
ringBuffer.append([1, 2, 3, 4, 5, 6][...])
ringBuffer.append([7, 8, 9, 10, 11][...])
precondition(ringBuffer.sampleCount == 10, "ring buffer must retain only 1.5 seconds of audio")
ringBuffer.clear()
precondition(ringBuffer.sampleCount == 0, "ring buffer must clear all in-memory audio")
print("TARST core checks passed")
