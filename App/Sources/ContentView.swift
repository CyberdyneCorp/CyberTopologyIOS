import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.3x3.topleft.filled")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("CyberTopology")
                .font(.largeTitle.bold())
            Text("Retopology · UV · Baking")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("launch-placeholder")
    }
}

#Preview {
    ContentView()
}
