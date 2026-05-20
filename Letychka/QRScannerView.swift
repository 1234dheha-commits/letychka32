import SwiftUI
import VisionKit

/// Thin SwiftUI wrapper around iOS 17's DataScannerViewController for
/// QR codes. Fires `onFound(text)` the first time it sees a QR payload,
/// then stops scanning. The caller can show this as a sheet.
struct QRScannerView: UIViewControllerRepresentable {
    var onFound: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController,
                                context: Context) {
        try? vc.startScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFound: onFound)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (String) -> Void
        var fired = false

        init(onFound: @escaping (String) -> Void) {
            self.onFound = onFound
        }

        func dataScanner(_ ds: DataScannerViewController,
                         didAdd items: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !fired else { return }
            for case let .barcode(b) in items {
                if let s = b.payloadStringValue, !s.isEmpty {
                    fired = true
                    ds.stopScanning()
                    onFound(s)
                    return
                }
            }
        }
    }
}

/// Lets the host SwiftUI tell whether the device can even run the
/// scanner (DataScannerViewController requires an Apple Neural Engine
/// device and iOS 16+). Used to hide the button on unsupported hardware
/// instead of crashing on instantiation.
enum QRScanner {
    static var isSupported: Bool {
        DataScannerViewController.isSupported
            && DataScannerViewController.isAvailable
    }
}
