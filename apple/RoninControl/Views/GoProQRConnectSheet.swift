import AVFoundation
import CoreImage.CIFilterBuiltins
import SwiftUI

/// 랩스 연결 QR을 보여 주거나 읽고, 그 다음 망에 들어온 고프로만 등록합니다.
struct GoProQRConnectSheet: View {
    @EnvironmentObject private var studio: Studio
    @Environment(\.dismiss) private var dismiss
    @StateObject private var finder = GoProFinder()
    @State private var ssid = ""
    @State private var password = ""
    @State private var storeCommand = ""
    @State private var showJoin = false
    @State private var typedHost = ""
    @State private var problem = ""
    @State private var armed = false
    @State private var known: Set<String> = []
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("비밀번호는 이 폰에 저장하지 않습니다. 저장 코드를 먼저 확인하고, 그 다음 접속 코드를 확인합니다.")
                        .font(.caption)
                        .foregroundStyle(StagePalette.ink)
                    TextField("와이파이 이름", text: $ssid)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("와이파이 비밀번호", text: $password)
                        .textFieldStyle(.roundedBorder)
                    Button("1단계 저장 QR") { makeStoreFromFields() }
                        .buttonStyle(.borderedProminent)
                    #if os(iOS)
                    Button("다른 저장 QR 읽기") { openScanner() }
                        .buttonStyle(.bordered)
                    #endif
                    if !problem.isEmpty {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if !storeCommand.isEmpty, let image = LabsQRImage.make(storeCommand) {
                        Text("1단계. 이 코드는 이름만 저장합니다. 아직 와이파이에 붙지 않습니다. 렌즈를 대고, 명령이 보이면 셔터로 확인합니다. 세 번 누르라는 안내가 나오면 세 번 누릅니다.")
                            .font(.caption)
                            .foregroundStyle(StagePalette.ink)
                        Text(GoProLabsJoin.masked(storeCommand))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(StagePalette.ink)
                        qrImage(image, label: "고프로 랩스 저장 QR")
                        Text("이 코드에는 와이파이 비밀번호가 들어 있습니다. 화면을 사진으로 남기지 마세요.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button("저장을 확인했습니다") { revealJoin() }
                            .buttonStyle(.borderedProminent)
                    }
                    if showJoin, let image = LabsQRImage.make(GoProLabsJoin.joinCommand) {
                        Text("2단계. 이 접속 코드를 렌즈에 보여 주고 셔터로 확인합니다. 카메라 메뉴는 열지 않습니다. 화면에 joining network 가 끝나면, 바로 아래 주소 코드를 보여 줍니다. 초를 세지 않습니다.")
                            .font(.caption)
                            .foregroundStyle(StagePalette.ink)
                        Text(GoProLabsJoin.joinCommand)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(StagePalette.ink)
                        qrImage(image, label: "고프로 랩스 접속 QR")
                        if let addressImage = LabsQRImage.make(GoProLabsJoin.addressCommand) {
                            Text("주소 코드. 접속 글자가 끝난 직후에 보여 줍니다. 카메라 화면에 숫자 주소가 나옵니다. 그 숫자를 아래에 적습니다.")
                                .font(.caption)
                                .foregroundStyle(StagePalette.ink)
                            Text(GoProLabsJoin.addressCommand)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(StagePalette.ink)
                            qrImage(addressImage, label: "고프로 주소 QR")
                        }
                        Button("바로 확인") { reportJoinNow() }
                            .buttonStyle(.borderedProminent)
                        TextField("카메라 화면에 나온 주소", text: $typedHost)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("이 주소 확인") { Task { await checkTypedAddress() } }
                            .buttonStyle(.bordered)
                    }
                    Text(finder.note)
                        .font(.caption)
                        .foregroundStyle(StagePalette.ink)
                    if finder.searching && finder.found.isEmpty {
                        ProgressView()
                    }
                    ForEach(finder.found) { item in
                        foundRow(item)
                    }
                }
                .padding(16)
            }
            .background(StagePalette.paper)
            .navigationTitle("고프로 QR 연결")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(StagePalette.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                Button("닫기") {
                    clearSecrets()
                    finder.stop()
                    dismiss()
                }
            }
        }
        .background(StagePalette.paper)
        .foregroundStyle(StagePalette.ink)
        .preferredColorScheme(.light)
        .onAppear { finder.start() }
        .onDisappear {
            clearSecrets()
            finder.stop()
        }
        .onChange(of: finder.found) { _, items in
            guard armed else { return }
            var joined = false
            for item in items where !known.contains(item.service) {
                known.insert(item.service)
                joined = true
                let already = studio.profile.devices.contains {
                    $0.kind == .gopro && $0.host == item.host && $0.port == item.port
                }
                guard !already else { continue }
                studio.addDiscoveredGoPro(name: item.name, host: item.host, port: item.port)
            }
            if joined { problem = "" }
        }
        #if os(iOS)
        .sheet(isPresented: $scanning) {
            LabsQRScanner { text in
                scanning = false
                if let command = GoProLabsJoin.storedCommand(from: text) {
                    makeStore(command)
                } else {
                    problem = "이 QR은 고프로 랩스 저장 명령이 아닙니다."
                }
            }
        }
        #endif
    }

    private func openScanner() {
        #if os(iOS)
        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async {
                if ok {
                    scanning = true
                } else {
                    problem = "QR을 읽으려면 카메라 권한이 필요합니다. 설정에서 허용해 주세요."
                }
            }
        }
        #endif
    }

    private func qrImage(_ image: CGImage, label: String) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.none)
            .scaledToFit()
            .padding(16)
            .background(Color.white)
            .frame(maxWidth: 320)
            .accessibilityLabel(label)
    }

    private func clearSecrets() {
        password = ""
        storeCommand = ""
    }

    private func makeStoreFromFields() {
        if GoProLabsJoin.passwordMessage(password) != nil {
            problem = "비밀번호가 틀렸습니다."
            storeCommand = ""
            showJoin = false
            armed = false
            return
        }
        makeStore(GoProLabsJoin.storeCommand(ssid: ssid, password: password))
    }

    private func makeStore(_ command: String?) {
        guard let command else {
            problem = "와이파이 이름이 있어야 합니다. 이름에는 콜론, 따옴표, 역슬래시를 넣지 않습니다."
            showJoin = false
            armed = false
            return
        }
        problem = ""
        storeCommand = command
        showJoin = false
        armed = false
    }

    /// 초를 세지 않습니다. 지금 고프로가 안 보이면 바로 실패를 말합니다.
    private func reportJoinNow() {
        problem = finder.found.isEmpty ? "카메라가 망에 붙지 않았습니다." : ""
    }

    private func revealJoin() {
        showJoin = true
        known = Set(finder.found.map(\.service))
        armed = true
        problem = ""
    }

    /// 카메라가 화면에 보여 준 주소만 확인합니다. 응답이 없으면 등록하지 않습니다.
    private func checkTypedAddress() async {
        guard let host = GoProLabsJoin.hostAddress(from: typedHost) else {
            problem = "카메라 화면에 나온 숫자 주소를 적습니다. 예: 192.168.0.20"
            return
        }
        for port in [8080, 80] {
            guard let url = LocalHTTP.url(host: host, port: port, path: "/gopro/version") else { continue }
            if let (_, text) = try? await LocalHTTP.get(url, timeout: 2), text.contains("\"version\"") {
                studio.addDiscoveredGoPro(name: host, host: host, port: port)
                problem = ""
                return
            }
        }
        problem = "카메라가 망에 붙지 않았습니다."
    }

    private func foundRow(_ item: FoundGoPro) -> some View {
        let taken = studio.profile.devices.contains {
            $0.kind == .gopro && $0.host == item.host && $0.port == item.port
        }
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.headline)
                Text("고프로 · 와이파이  \(item.host):\(item.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(taken ? "등록됨" : "등록") {
                studio.addDiscoveredGoPro(name: item.name, host: item.host, port: item.port)
            }
            .buttonStyle(.bordered)
            .disabled(taken || studio.profile.devices.count >= StudioProfile.maxDevices)
        }
        .padding(10)
        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
    }
}

enum LabsQRImage {
    static func make(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}

#if os(iOS)
import VisionKit

/// 이미 있는 랩스 QR만 읽습니다. 읽은 글이 JOIN 명령이 아니면 카메라를 만들지 않습니다.
struct LabsQRScanner: View {
    var onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var missing = ""

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    LabsQRScannerView(onCode: onCode)
                } else {
                    Text(missing.isEmpty ? "이 폰에서는 QR 카메라를 열 수 없습니다. 만든 QR을 고프로에 보여 주세요." : missing)
                        .font(.caption)
                        .foregroundStyle(StagePalette.ink)
                        .padding()
                }
            }
            .background(StagePalette.paper)
            .navigationTitle("랩스 QR 읽기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("닫기") { dismiss() }
            }
        }
        .preferredColorScheme(.light)
    }
}

private struct LabsQRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !scanner.isScanning else { return }
        try? scanner.startScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        private var sent = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !sent else { return }
            for item in addedItems {
                guard case .barcode(let code) = item, let text = code.payloadStringValue else { continue }
                sent = true
                onCode(text)
                return
            }
        }
    }
}
#endif
