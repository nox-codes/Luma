//
//  LumaWhisperEngine.swift
//  leanring-buddy
//
//  On-device Whisper Tiny encoder via Core ML.
//
//  Loads whisper-tiny.mlmodelc, computes a log-mel spectrogram from AVAudioPCMBuffer
//  input using Accelerate/vDSP, and runs the Whisper encoder via CoreML.
//
//  NOTE: whisper-tiny.mlmodelc is encoder-only. It produces audio embeddings
//  [1, 1500, 384], not text. A decoder is required to convert embeddings to words.
//  Until a decoder is bundled, transcribe() returns nil and the app falls back to
//  the configured STT provider (Apple Speech).
//
//  TO ADD FULL ON-DEVICE STT:
//    Add WhisperKit (encoder + decoder) via SPM:
//    https://github.com/argmaxinc/WhisperKit
//

import Accelerate
import AVFoundation
import CoreML
import Foundation

// MARK: - LumaWhisperEngine

/// On-device Whisper Tiny encoder via Core ML.
/// Preprocesses audio into a log-mel spectrogram and runs encoder inference.
/// Returns nil from transcribe() — a decoder is required for text output.
final class LumaWhisperEngine {
    static let shared = LumaWhisperEngine()

    /// True if whisper-tiny.mlmodelc loaded successfully from the app bundle.
    private(set) var isModelAvailable: Bool = false

    /// The loaded Core ML encoder model.
    private var encoderModel: MLModel?

    /// Mel filterbank matrix [80 × 257], built once and cached.
    private var cachedMelFilterbank: [[Float]]?

    // Whisper audio constants
    private let whisperSampleRate: Double = 16000
    private let whisperMelBinCount: Int = 80
    private let whisperTimeFrameCount: Int = 3000   // 30 s ÷ 10 ms hop

    // FFT constants — Hann window is fftWindowSize samples, zero-padded to fftSize
    private let fftWindowSize: Int = 400            // 25 ms at 16 kHz
    private let fftHopLength: Int = 160             // 10 ms at 16 kHz
    private let fftSize: Int = 512                  // Next power-of-2 above 400 for vDSP

    /// Audio RMS below this is treated as silence; encoder is not invoked.
    private let silencePowerThreshold: Float = 0.01

    private init() { loadEncoderModel() }

    // MARK: - Model Loading

    private func loadEncoderModel() {
        guard let modelURL = Bundle.main.url(forResource: "whisper-tiny", withExtension: "mlmodelc") else {
            LumaLogger.log("[LumaWhisper] whisper-tiny.mlmodelc not in bundle — using configured STT provider.")
            return
        }
        do {
            let config = MLModelConfiguration()
            // Prefer Neural Engine + CPU to keep GPU memory available for other tasks.
            config.computeUnits = .cpuAndNeuralEngine
            encoderModel = try MLModel(contentsOf: modelURL, configuration: config)
            isModelAvailable = true
            LumaLogger.log("[LumaWhisper] Whisper Tiny encoder loaded.")
        } catch {
            LumaLogger.log("[LumaWhisper] Failed to load Whisper encoder: \(error)")
        }
    }

    // MARK: - Transcription

    /// Runs mel spectrogram preprocessing and encoder inference on the given buffer.
    /// Always returns nil — the encoder produces embeddings, not text.
    /// Callers should fall back to Apple Speech for transcribed text.
    func transcribe(_ audioBuffer: AVAudioPCMBuffer) async -> String? {
        guard isModelAvailable, let model = encoderModel else { return nil }
        guard !isSilent(audioBuffer) else { return nil }

        guard let monoSamples = resampleToWhisperFormat(audioBuffer) else {
            LumaLogger.log("[LumaWhisper] Audio conversion failed.")
            return nil
        }

        guard let melInput = buildMelSpectrogramInput(monoSamples) else {
            LumaLogger.log("[LumaWhisper] Mel spectrogram failed.")
            return nil
        }

        do {
            let embeddings = try runEncoderInference(melInput: melInput, model: model)
            // Encoder produced audio embeddings — a decoder is needed to convert to text.
            LumaLogger.log("[LumaWhisper] Encoder ran (\(embeddings.count) values). Decoder not bundled — falling back to STT provider.")
        } catch {
            LumaLogger.log("[LumaWhisper] Encoder inference error: \(error)")
        }

        return nil
    }

    // MARK: - Audio Preprocessing

    /// Converts an AVAudioPCMBuffer (any sample rate, any channel count) to
    /// 16 kHz mono Float32, padded or trimmed to exactly 30 seconds.
    private func resampleToWhisperFormat(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }

        // Mix down to mono
        let channelCount = Int(buffer.format.channelCount)
        let channelWeight = 1.0 / Float(channelCount)
        var monoSamples = [Float](repeating: 0, count: frameCount)
        for channelIndex in 0..<channelCount {
            for sampleIndex in 0..<frameCount {
                monoSamples[sampleIndex] += channelData[channelIndex][sampleIndex] * channelWeight
            }
        }

        // Resample to 16 kHz if needed
        if abs(buffer.format.sampleRate - whisperSampleRate) > 1 {
            monoSamples = linearInterpolationResample(
                monoSamples,
                fromRate: buffer.format.sampleRate,
                toRate: whisperSampleRate
            )
        }

        // Pad with silence or trim to exactly 30 seconds
        let targetSampleCount = Int(whisperSampleRate * 30.0)
        if monoSamples.count < targetSampleCount {
            monoSamples += [Float](repeating: 0, count: targetSampleCount - monoSamples.count)
        } else if monoSamples.count > targetSampleCount {
            monoSamples = Array(monoSamples.prefix(targetSampleCount))
        }
        return monoSamples
    }

    /// Resamples a Float32 audio array from one sample rate to another via linear interpolation.
    private func linearInterpolationResample(_ samples: [Float], fromRate: Double, toRate: Double) -> [Float] {
        guard samples.count > 1, fromRate > 0, toRate > 0 else { return samples }
        let outputCount = Int(Double(samples.count) * toRate / fromRate)
        guard outputCount > 0 else { return [] }
        var output = [Float](repeating: 0, count: outputCount)
        let positionScale = Double(samples.count - 1) / Double(max(outputCount - 1, 1))
        for outputIndex in 0..<outputCount {
            let inputPosition = Double(outputIndex) * positionScale
            let lowerIndex = Int(inputPosition)
            let upperIndex = min(lowerIndex + 1, samples.count - 1)
            let interpolationFraction = Float(inputPosition - Double(lowerIndex))
            output[outputIndex] = samples[lowerIndex] * (1.0 - interpolationFraction)
                + samples[upperIndex] * interpolationFraction
        }
        return output
    }

    // MARK: - Log-Mel Spectrogram

    /// Computes a log-mel spectrogram from 16 kHz mono samples and returns it as
    /// an MLMultiArray with shape [1, 80, 3000] — the Whisper encoder's expected input.
    private func buildMelSpectrogramInput(_ monoSamples: [Float]) -> MLMultiArray? {
        let halfBinCount = fftSize / 2 + 1  // 257 frequency bins

        if cachedMelFilterbank == nil {
            cachedMelFilterbank = buildMelFilterbank(halfBinCount: halfBinCount)
        }
        guard let filterbank = cachedMelFilterbank else { return nil }

        let log2N = vDSP_Length(log2f(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2N, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var hannWindow = [Float](repeating: 0, count: fftWindowSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftWindowSize), Int32(vDSP_HANN_DENORM))

        // Output buffer: mel-major layout [melBin × timeFrame] for CoreML shape [1, 80, 3000]
        var logMelData = [Float](repeating: 0, count: whisperMelBinCount * whisperTimeFrameCount)

        for frameIndex in 0..<whisperTimeFrameCount {
            let sampleStart = frameIndex * fftHopLength

            // Build a Hann-windowed frame zero-padded to fftSize
            var windowedFrame = [Float](repeating: 0, count: fftSize)
            let availableCount = max(0, min(fftWindowSize, monoSamples.count - sampleStart))
            if availableCount > 0 {
                var rawFrame = [Float](repeating: 0, count: fftWindowSize)
                rawFrame.withUnsafeMutableBufferPointer { dst in
                    monoSamples.withUnsafeBufferPointer { src in
                        dst.baseAddress!.initialize(
                            from: src.baseAddress! + sampleStart,
                            count: availableCount
                        )
                    }
                }
                // Apply Hann window; result stored in first fftWindowSize elements of windowedFrame
                vDSP_vmul(rawFrame, 1, hannWindow, 1, &windowedFrame, 1, vDSP_Length(fftWindowSize))
            }

            // Power spectrum via real FFT
            let powerSpectrum = computeRealFFTPowerSpectrum(
                windowedFrame,
                fftSetup: fftSetup,
                log2N: log2N
            )

            // Apply mel filterbank and log10-scale each mel bin
            for melBin in 0..<whisperMelBinCount {
                var energy: Float = 0
                vDSP_dotpr(
                    powerSpectrum, 1,
                    filterbank[melBin], 1,
                    &energy,
                    vDSP_Length(halfBinCount)
                )
                // Clamp before log10 to avoid -inf; 1e-10 matches Whisper's reference
                logMelData[melBin * whisperTimeFrameCount + frameIndex] = log10(max(energy, 1e-10))
            }
        }

        // Normalize to [-1, 1]: clamp to [max-8, max], then apply (x + 4) / 4
        var maxLogMelValue: Float = 0
        vDSP_maxv(logMelData, 1, &maxLogMelValue, vDSP_Length(logMelData.count))

        let clampFloor = maxLogMelValue - 8.0
        let clampFloorVector = [Float](repeating: clampFloor, count: logMelData.count)
        var clampedLogMel = [Float](repeating: 0, count: logMelData.count)
        // vDSP_vmax does NOT support in-place, so use separate source and dest arrays
        vDSP_vmax(logMelData, 1, clampFloorVector, 1, &clampedLogMel, 1, vDSP_Length(logMelData.count))

        // (x + 4) / 4  ≡  x * 0.25 + 1.0  — computed in one pass via vDSP_vsmsa
        var scaleQuarter: Float = 0.25
        var offsetOne: Float = 1.0
        var normalized = [Float](repeating: 0, count: clampedLogMel.count)
        vDSP_vsmsa(clampedLogMel, 1, &scaleQuarter, &offsetOne, &normalized, 1, vDSP_Length(clampedLogMel.count))

        // Pack into MLMultiArray [1, 80, 3000]
        guard let melArray = try? MLMultiArray(
            shape: [1, 80, 3000],
            dataType: .float32
        ) else { return nil }

        let totalElements = whisperMelBinCount * whisperTimeFrameCount
        let destPointer = melArray.dataPointer.bindMemory(to: Float.self, capacity: totalElements)
        normalized.withUnsafeBufferPointer { srcBuffer in
            destPointer.initialize(from: srcBuffer.baseAddress!, count: totalElements)
        }

        return melArray
    }

    /// Computes the power spectrum |X[k]|² for a real windowed frame using vDSP's real FFT.
    /// Returns an array of (fftSize/2 + 1) power values.
    private func computeRealFFTPowerSpectrum(
        _ windowedFrame: [Float],
        fftSetup: FFTSetup,
        log2N: vDSP_Length
    ) -> [Float] {
        let halfN = fftSize / 2  // 256

        // For vDSP_fft_zrip: pack the real signal into split-complex format by
        // treating pairs of consecutive float values as (real, imaginary) components.
        // Even-indexed samples → realp, odd-indexed samples → imagp.
        var realPart = [Float](repeating: 0, count: halfN)
        var imagPart = [Float](repeating: 0, count: halfN)

        windowedFrame.withUnsafeBytes { frameBytes in
            realPart.withUnsafeMutableBufferPointer { realBuffer in
                imagPart.withUnsafeMutableBufferPointer { imagBuffer in
                    var splitComplex = DSPSplitComplex(
                        realp: realBuffer.baseAddress!,
                        imagp: imagBuffer.baseAddress!
                    )
                    // Stride-1 DSPComplex view of the float array (pair = one complex value)
                    let complexPtr = frameBytes.baseAddress!.assumingMemoryBound(to: DSPComplex.self)
                    vDSP_ctoz(complexPtr, 1, &splitComplex, 1, vDSP_Length(halfN))
                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2N, FFTDirection(FFT_FORWARD))
                }
            }
        }

        // Build power spectrum for frequencies k = 0 .. fftSize/2
        // After vDSP_fft_zrip:
        //   realPart[0] = DC component
        //   imagPart[0] = Nyquist component
        //   realPart[k], imagPart[k] for k=1..halfN-1 = positive frequency bins
        var powerSpectrum = [Float](repeating: 0, count: halfN + 1)
        powerSpectrum[0] = realPart[0] * realPart[0]         // DC
        powerSpectrum[halfN] = imagPart[0] * imagPart[0]     // Nyquist
        for k in 1..<halfN {
            powerSpectrum[k] = realPart[k] * realPart[k] + imagPart[k] * imagPart[k]
        }
        return powerSpectrum
    }

    // MARK: - Mel Filterbank

    /// Builds a triangular mel filterbank matrix [whisperMelBinCount × halfBinCount].
    /// Each row contains the weights for one triangular mel filter.
    private func buildMelFilterbank(halfBinCount: Int) -> [[Float]] {
        let sampleRate = Float(whisperSampleRate)
        let nyquistHz = sampleRate / 2.0
        let minMel = hertzToMel(0)
        let maxMel = hertzToMel(nyquistHz)

        // whisperMelBinCount + 2 evenly spaced mel points define the filter boundaries
        let totalMelPoints = whisperMelBinCount + 2
        let melPoints = (0..<totalMelPoints).map { pointIndex -> Float in
            minMel + (maxMel - minMel) * Float(pointIndex) / Float(totalMelPoints - 1)
        }
        let hzPoints = melPoints.map { melToHertz($0) }
        let fftBinFrequencies = (0..<halfBinCount).map { Float($0) * sampleRate / Float(fftSize) }

        var filterbank = [[Float]](
            repeating: [Float](repeating: 0, count: halfBinCount),
            count: whisperMelBinCount
        )
        for filterIndex in 0..<whisperMelBinCount {
            let lowerHz = hzPoints[filterIndex]
            let centerHz = hzPoints[filterIndex + 1]
            let upperHz = hzPoints[filterIndex + 2]
            guard centerHz > lowerHz, upperHz > centerHz else { continue }

            for binIndex in 0..<halfBinCount {
                let freq = fftBinFrequencies[binIndex]
                if freq >= lowerHz, freq <= centerHz {
                    filterbank[filterIndex][binIndex] = (freq - lowerHz) / (centerHz - lowerHz)
                } else if freq > centerHz, freq <= upperHz {
                    filterbank[filterIndex][binIndex] = (upperHz - freq) / (upperHz - centerHz)
                }
            }
        }
        return filterbank
    }

    private func hertzToMel(_ hz: Float) -> Float {
        return 2595.0 * log10(1.0 + hz / 700.0)
    }

    private func melToHertz(_ mel: Float) -> Float {
        return 700.0 * (pow(10.0, mel / 2595.0) - 1.0)
    }

    // MARK: - CoreML Encoder Inference

    /// Feeds the mel spectrogram MLMultiArray [1, 80, 3000] into the Whisper encoder.
    /// Returns audio embeddings as MLMultiArray with shape [1, 1500, 384].
    private func runEncoderInference(melInput: MLMultiArray, model: MLModel) throws -> MLMultiArray {
        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: ["logmel_data": melInput])
        let outputFeatures = try model.prediction(from: inputFeatures)
        guard let audioEmbeddings = outputFeatures.featureValue(for: "output")?.multiArrayValue else {
            throw NSError(
                domain: "LumaWhisper",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Encoder output 'output' key missing from prediction result"]
            )
        }
        return audioEmbeddings
    }

    // MARK: - Silence Detection

    /// Returns true if the buffer's RMS power is below the silence threshold.
    private func isSilent(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channelData = buffer.floatChannelData else { return true }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return true }
        let channelSamples = channelData[0]
        let sumOfSquares = (0..<frameCount).reduce(0.0) { runningSum, sampleIndex in
            runningSum + Double(channelSamples[sampleIndex] * channelSamples[sampleIndex])
        }
        let rms = Float(sqrt(sumOfSquares / Double(frameCount)))
        return rms < silencePowerThreshold
    }
}
