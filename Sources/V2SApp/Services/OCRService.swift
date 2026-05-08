import CoreImage
import Vision

enum OCRService {
    static func recognizeText(from pngData: Data) async -> String? {
        guard let ciImage = CIImage(data: pngData) else { return nil }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation]
                else {
                    continuation.resume(returning: nil)
                    return
                }

                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text.isEmpty ? nil : text)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            do {
                try VNImageRequestHandler(ciImage: ciImage, options: [:]).perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}
