import SwiftUI

/// 찾기 결과만 보여 줍니다. 빈 목록은 빈 목록으로 둡니다.
struct GoProFindSheet: View {
    @EnvironmentObject private var studio: Studio
    @Environment(\.dismiss) private var dismiss
    @StateObject private var finder = GoProFinder()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(finder.note)
                        .font(.caption)
                        .foregroundStyle(StagePalette.ink)
                    if finder.searching && finder.found.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                Section("찾은 고프로") {
                    if finder.found.isEmpty {
                        Text("찾은 고프로가 없습니다.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(finder.found) { item in
                        row(item)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(StagePalette.paper)
            .navigationTitle("고프로 찾기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(StagePalette.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                Button("닫기") {
                    finder.stop()
                    dismiss()
                }
            }
        }
        .background(StagePalette.paper)
        .foregroundStyle(StagePalette.ink)
        .preferredColorScheme(.light)
        .onAppear { finder.start() }
        .onDisappear { finder.stop() }
    }

    private func row(_ item: FoundGoPro) -> some View {
        let taken = studio.profile.devices.contains {
            $0.kind == .gopro && $0.host == item.host && $0.port == item.port
        }
        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.headline)
                Text("고프로 · 와이파이")
                    .font(.caption.weight(.semibold))
                Text("\(item.host):\(item.port)")
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
    }
}
