import AVFoundation
import ODKWebEngine
import PhotosUI
import SwiftUI

/// `binary` questions with an `image/*` accept type: take a photo with the camera, or
/// choose one from the library. Either way the picked image is reported as a JPEG
/// attachment, with the model value set to that filename.
struct ImageAttachmentInputView: View {
    let question: Question
    @Binding var value: String
    let onCapturedAttachment: (String, Data) -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var previewImage: Image?
    @State private var isShowingCamera = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let previewImage {
                previewImage
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .cornerRadius(8)
            } else if !value.isEmpty {
                Text(value).foregroundStyle(.secondary)
            }

            HStack {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button {
                        isShowingCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                    }
                    .buttonStyle(.bordered)
                }

                PhotosPicker("Choose Photo", selection: $pickerItem, matching: .images)
                    .buttonStyle(.bordered)
            }
        }
        .onChange(of: pickerItem) { newItem in
            guard let newItem else { return }
            Task {
                guard let data = try? await newItem.loadTransferable(type: Data.self) else { return }
                store(data)
            }
        }
        .sheet(isPresented: $isShowingCamera) {
            CameraCaptureView { data in
                if let data { store(data) }
            }
        }
    }

    private func store(_ data: Data) {
        let filename = "photo-\(question.uid.replacingOccurrences(of: "/", with: "_"))-\(UUID().uuidString).jpg"
        onCapturedAttachment(filename, data)
        value = filename
        if let uiImage = UIImage(data: data) {
            previewImage = Image(uiImage: uiImage)
        }
    }
}

/// `binary` questions with an `audio/*` accept type: record with the microphone.
struct AudioAttachmentInputView: View {
    let question: Question
    @Binding var value: String
    let onCapturedAttachment: (String, Data) -> Void

    @StateObject private var recorder = AudioRecorderService()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !value.isEmpty {
                Label(value, systemImage: "waveform")
                    .foregroundStyle(.secondary)
            }
            Button {
                if recorder.isRecording {
                    recorder.stopRecording()
                } else {
                    recorder.startRecording()
                }
            } label: {
                Label(
                    recorder.isRecording ? "Stop Recording" : "Record Audio",
                    systemImage: recorder.isRecording ? "stop.circle.fill" : "mic.circle"
                )
            }
            .buttonStyle(.bordered)

            if let error = recorder.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .onChange(of: recorder.recordedData) { data in
            guard let data else { return }
            let filename = "audio-\(question.uid.replacingOccurrences(of: "/", with: "_"))-\(UUID().uuidString).m4a"
            onCapturedAttachment(filename, data)
            value = filename
        }
    }
}

/// `binary` questions for video or arbitrary files: hand off to the Files app, which
/// also exposes the Photos library's videos via its own picker.
struct FileAttachmentInputView: View {
    let question: Question
    @Binding var value: String
    let onCapturedAttachment: (String, Data) -> Void

    @State private var isPresented = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !value.isEmpty {
                Text(value).foregroundStyle(.secondary)
            }
            Button("Choose File") { isPresented = true }
                .buttonStyle(.bordered)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .fileImporter(isPresented: $isPresented, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                store(url)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private func store(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "Couldn't access the selected file."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Couldn't read the selected file."
            return
        }
        onCapturedAttachment(url.lastPathComponent, data)
        value = url.lastPathComponent
    }
}

/// Records audio to a temporary file via `AVAudioRecorder`, then loads the result back
/// into memory as `recordedData` once stopped.
final class AudioRecorderService: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var recordedData: Data?
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?

    func startRecording() {
        errorMessage = nil
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: .defaultToSpeaker)
            try session.setActive(true)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.record()
            fileURL = url
            isRecording = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording() {
        recorder?.stop()
        isRecording = false
        guard let fileURL else { return }
        recordedData = try? Data(contentsOf: fileURL)
    }
}

/// Thin `UIImagePickerController` wrapper for live camera capture (PhotosPicker only
/// covers the library).
private struct CameraCaptureView: UIViewControllerRepresentable {
    let onCapture: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (Data?) -> Void

        init(onCapture: @escaping (Data?) -> Void) {
            self.onCapture = onCapture
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            onCapture(image?.jpegData(compressionQuality: 0.9))
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
            picker.dismiss(animated: true)
        }
    }
}
