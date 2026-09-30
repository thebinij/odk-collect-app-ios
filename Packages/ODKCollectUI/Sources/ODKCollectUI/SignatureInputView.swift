import ODKWebEngine
import PencilKit
import SwiftUI

/// A finger/Pencil signature pad for `binary` questions with a `draw`/`signature`/
/// `annotate` appearance. Every stroke re-renders the drawing to a PNG and reports it
/// as an attachment named after this question's `ref`, with the model value set to
/// that filename (the OpenRosa convention for `<upload>` fields).
struct SignatureInputView: View {
    let question: Question
    @Binding var value: String
    let onCapturedAttachment: (String, Data) -> Void

    @State private var canvasView = PKCanvasView()

    private var filename: String {
        value.isEmpty ? "signature-\(question.uid.replacingOccurrences(of: "/", with: "_")).png" : value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SignatureCanvasRepresentable(canvasView: $canvasView, onDrawingChanged: commitDrawing)
                .frame(height: 220)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)

            Button("Clear") {
                canvasView.drawing = PKDrawing()
                value = ""
            }
            .buttonStyle(.bordered)
        }
    }

    private func commitDrawing() {
        guard !canvasView.drawing.strokes.isEmpty else { return }
        let bounds = canvasView.drawing.bounds.isEmpty ? canvasView.bounds : canvasView.drawing.bounds
        let image = canvasView.drawing.image(from: bounds, scale: UIScreen.main.scale)
        guard let data = image.pngData() else { return }
        onCapturedAttachment(filename, data)
        value = filename
    }
}

private struct SignatureCanvasRepresentable: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    let onDrawingChanged: () -> Void

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.drawingPolicy = .anyInput
        canvasView.tool = PKInkingTool(.pen, color: .black, width: 3)
        canvasView.backgroundColor = .clear
        canvasView.delegate = context.coordinator
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDrawingChanged: onDrawingChanged)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let onDrawingChanged: () -> Void

        init(onDrawingChanged: @escaping () -> Void) {
            self.onDrawingChanged = onDrawingChanged
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            onDrawingChanged()
        }
    }
}
